//==============================================================================
// la_capture.v -- sampling, trigger, sample memory and readout
//------------------------------------------------------------------------------
// One capture, as driven by sigrok:
//
//   ARM ──► armed: sample continuously into a ring buffer; once enough
//           pre-trigger samples are stored, check each sample against the
//           trigger (mask/value). No trigger set (mask = 0) = fire at once.
//       ──► post:  keep sampling until DELAY samples (including the trigger
//           sample) have been stored after the trigger.
//       ──► send:  send READ samples back to the PC, NEWEST FIRST (that is
//           what the SUMP protocol and sigrok expect).
//
//   READ  = (read_cnt  + 1) * 4 samples, clamped to the memory depth
//   DELAY = (delay_cnt + 1) * 4 samples, clamped to READ
//   pre-trigger samples = READ - DELAY
//
// SAMPLE RATE. SUMP defines rate = 100 MHz / (divider + 1). This module may
// run from any clock: in effect each clock adds RATE_P to an accumulator, and
// a sample is taken whenever it reaches (divider + 1) * RATE_Q, where
// 100 MHz / CLK_HZ = RATE_P / RATE_Q. At 100 MHz (P = Q = 1) this is an exact
// divide-by-(divider+1). At 12 MHz (P = 25, Q = 3) the average rate is exact
// and each sample lands on the nearest clock edge (up to 83 ns of jitter
// unless 12 MHz / rate is a whole number).
//
// MEMORY. 16 KB as two 8K x 8 banks (`lo`, `hi`), inferred as block RAM.
//   16 channels (groups 0 and 1 on): sample n -> lo[n] = ch 7:0, hi[n] = ch 15:8
//                                    -> 8192 samples
//    8 channels (one group on):      sample n -> bank n[0], address n >> 1
//                                    -> 16384 samples
// Each sample is sent as 1 or 2 bytes (enabled groups only, group 0 first).
//
// LSE NOTE: the phase of a capture is held in separate flags (armed, post,
// sending) rather than an encoded state machine, and every register has an
// initial value.
//==============================================================================
module la_capture #(
    parameter integer RATE_P = 25,        // 100 MHz / CLK_HZ = RATE_P / RATE_Q
    parameter integer RATE_Q = 3
) (
    input  wire        i_clk,

    // commands
    input  wire        i_reset,           // abort everything
    input  wire        i_arm,             // start a capture

    // configuration (from sump_cmd)
    input  wire [23:0] i_divider,
    input  wire [15:0] i_read_cnt,
    input  wire [15:0] i_delay_cnt,
    input  wire [15:0] i_flags,
    input  wire [15:0] i_trig_mask,
    input  wire [15:0] i_trig_value,

    // probes (asynchronous)
    input  wire [15:0] i_probe,

    // readout byte stream (to uart_tx)
    output wire [7:0]  o_tx_data,
    output wire        o_tx_valid,
    input  wire        i_tx_ready,

    // status
    output reg         o_armed   = 1'b0,  // waiting for the trigger
    output reg         o_post    = 1'b0,  // triggered, capturing
    output reg         o_sending = 1'b0   // sending samples to the PC
);
    //--------------------------------------------------------------------------
    // Flags and memory geometry
    //--------------------------------------------------------------------------
    wire g0_on     = ~i_flags[2];
    wire g1_on     = ~i_flags[3];
    wire test_mode =  i_flags[11];
    wire wide      =  g0_on & g1_on;              // 16-bit samples
    wire [13:0] idx_mask = wide ? 14'h1FFF : 14'h3FFF;
    wire [14:0] depth    = wide ? 15'd8192 : 15'd16384;

    //--------------------------------------------------------------------------
    // Probe synchronizer and test pattern
    //--------------------------------------------------------------------------
    reg [15:0] p_s1 = 16'd0, p_s2 = 16'd0;
    always @(posedge i_clk) begin
        p_s1 <= i_probe;
        p_s2 <= p_s1;
    end

    reg  [15:0] test_cnt = 16'd0;                 // +1 per sample in test mode
    wire [15:0] s_now    = test_mode ? test_cnt : p_s2;

    //--------------------------------------------------------------------------
    // Sample-rate accumulator
    //--------------------------------------------------------------------------
    wire running = o_armed | o_post;

    // Written so each clock does exactly ONE add (timing at 100 MHz):
    //
    //   thr  = (divider + 1) * RATE_Q      units per sample
    //   step = thr - RATE_P
    //   c    = (units left before the next sample) - RATE_P - 1, signed.
    //          Each clock c -= RATE_P; a sample is due when c < 0, i.e. its
    //          sign bit -- a plain flip-flop, no comparator. After a sample
    //          c += step. (Same timing as "accumulate RATE_P until >= thr".)
    //
    // Configuration only changes between captures, so the derived values
    // are computed in pipelined registers that settle within a few clocks.
    localparam [27:0] P28 = RATE_P;
    reg  [27:0] div1      = 28'd100;
    reg  [27:0] thr       = 28'd300;
    reg  [27:0] step      = 28'd275;
    reg  [27:0] c_init    = 28'd274;              // thr - RATE_P - 1
    reg         every_clk = 1'b0;                 // rate >= clock: sample every clock
    reg  [27:0] c         = 28'd0;

    // thr <= RATE_P, as the borrow of a subtraction (fast carry chain)
    wire [28:0] p_minus_thr = {1'b0, P28} - {1'b0, thr};

    always @(posedge i_clk) begin
        div1      <= {4'd0, i_divider} + 28'd1;
        thr       <= div1 * RATE_Q;
        step      <= thr - RATE_P;
        c_init    <= thr - RATE_P - 1;
        every_clk <= ~p_minus_thr[28];
    end

    wire hit = every_clk | c[27];                 // c < 0

    reg        s_valid = 1'b0;                    // a sample is in s
    reg [15:0] s       = 16'd0;

    always @(posedge i_clk) begin
        s_valid <= 1'b0;
        if (!running || i_arm) begin
            c <= c_init;
        end else if (hit) begin
            s        <= s_now;
            s_valid  <= 1'b1;
            test_cnt <= test_cnt + 1'b1;
            c        <= c + step;
        end else
            c <= c - P28;
    end

    //--------------------------------------------------------------------------
    // Capture
    //--------------------------------------------------------------------------
    reg [13:0] wp        = 14'd0;                 // next write index (samples)
    reg [13:0] last_idx  = 14'd0;                 // newest sample of the capture
    reg [14:0] pre_left  = 15'd0;                 // pre-trigger samples still needed
    reg [14:0] post_left = 15'd0;                 // samples still to store after trigger
    reg [14:0] rd_total  = 15'd0;                 // READ   (clamped)
    reg [14:0] dl_total  = 15'd0;                 // DELAY  (clamped)

    // READ/DELAY clamped to memory -- pipelined, computed in units of 4
    // samples (the unit SUMP uses), one simple operation per stage:
    //   stage 1: +1, "too big for memory" (a power of two: just check the
    //            high bits), and delay > read (borrow of a subtraction)
    //   stage 2: clamp: read = min(read, depth); delay = min(delay, read)
    //   stage 3: pre-trigger = read - delay
    wire [12:0] depth_u     = wide ? 13'd2048 : 13'd4096;
    wire [16:0] rd_minus_dl = {1'b0, i_read_cnt} - {1'b0, i_delay_cnt};

    reg [16:0] rd_u = 17'd256, dl_u = 17'd256;    // count + 1
    reg        rd_big = 1'b0, dl_big = 1'b0, dl_gt_rd = 1'b0;
    reg [12:0] rd_cu = 13'd256, dl_cu = 13'd256;  // clamped
    reg [12:0] pre_u = 13'd0;

    always @(posedge i_clk) begin
        rd_u     <= {1'b0, i_read_cnt}  + 17'd1;
        dl_u     <= {1'b0, i_delay_cnt} + 17'd1;
        rd_big   <= wide ? (|i_read_cnt[15:11])  : (|i_read_cnt[15:12]);
        dl_big   <= wide ? (|i_delay_cnt[15:11]) : (|i_delay_cnt[15:12]);
        dl_gt_rd <= rd_minus_dl[16];

        rd_cu    <= rd_big ? depth_u : rd_u[12:0];
        dl_cu    <= (dl_gt_rd || dl_big) ? (rd_big ? depth_u : rd_u[12:0]) : dl_u[12:0];

        pre_u    <= rd_cu - dl_cu;
    end

    wire [14:0] rd_clmp  = {rd_cu, 2'b00};        // samples
    wire [14:0] dl_clmp  = {dl_cu, 2'b00};
    wire [14:0] pre_need = {pre_u, 2'b00};

    wire trig_hit = ((s ^ i_trig_value) & i_trig_mask) == 16'd0;

    // memory write port
    wire [7:0]  nbyte = g0_on ? s[7:0] : s[15:8];     // 8-channel mode byte
    wire [12:0] waddr = wide ? wp[12:0] : wp[13:1];
    wire        we_lo = s_valid && running && (wide || !wp[0]);
    wire        we_hi = s_valid && running && (wide ||  wp[0]);
    wire [7:0]  wd_lo = wide ? s[7:0]  : nbyte;
    wire [7:0]  wd_hi = wide ? s[15:8] : nbyte;

    //--------------------------------------------------------------------------
    // Readout (timed by the UART, so a few extra clocks per sample are free)
    //   ph 0: address of sample rp presented to the RAM
    //   ph 1: RAM output (rd_lo/rd_hi) valid
    //   ph 2: pipeline register (rd_lo_q/rd_hi_q) valid
    //         -- block RAM reads are slow (4.7 ns) on this chip; reading,
    //            choosing among the 8 RAM blocks and picking the byte in a
    //            single 10 ns clock missed timing at 100 MHz
    //   ph 3: latch the byte(s) to send
    //   ph 4: send first byte (group 0, or the only byte)
    //   ph 5: send second byte (group 1, 16-channel mode only)
    //--------------------------------------------------------------------------
    reg [13:0] rp      = 14'd0;
    reg [14:0] rd_left = 15'd0;
    reg [2:0]  ph      = 3'd0;
    reg [7:0]  b0 = 8'd0, b1 = 8'd0;

    wire [12:0] raddr = wide ? rp[12:0] : rp[13:1];
    reg  [7:0]  rd_lo = 8'd0, rd_hi = 8'd0;
    reg  [7:0]  rd_lo_q = 8'd0, rd_hi_q = 8'd0;

    always @(posedge i_clk) begin
        rd_lo_q <= rd_lo;
        rd_hi_q <= rd_hi;
    end

    assign o_tx_valid = o_sending && (ph == 3'd4 || ph == 3'd5);
    assign o_tx_data  = (ph == 3'd5) ? b1 : b0;

    //--------------------------------------------------------------------------
    // Sample memory: two 8K x 8 simple dual-port RAMs (block RAM)
    //--------------------------------------------------------------------------
    reg [7:0] mem_lo [0:8191];
    reg [7:0] mem_hi [0:8191];

    always @(posedge i_clk) begin
        if (we_lo) mem_lo[waddr] <= wd_lo;
        rd_lo <= mem_lo[raddr];
    end
    always @(posedge i_clk) begin
        if (we_hi) mem_hi[waddr] <= wd_hi;
        rd_hi <= mem_hi[raddr];
    end

    //--------------------------------------------------------------------------
    // Control
    //--------------------------------------------------------------------------
    always @(posedge i_clk) begin
        if (i_reset) begin
            o_armed   <= 1'b0;
            o_post    <= 1'b0;
            o_sending <= 1'b0;
            ph        <= 3'd0;

        end else if (i_arm && !o_sending) begin
            o_armed  <= 1'b1;
            o_post   <= 1'b0;
            pre_left <= pre_need;
            rd_total <= rd_clmp;
            dl_total <= dl_clmp;

        end else if (running && s_valid) begin
            // store this sample (memory write happens via we_lo/we_hi)
            wp <= (wp + 1'b1) & idx_mask;

            if (o_armed) begin
                if (pre_left == 15'd0 && trig_hit) begin
                    // trigger: this sample is the first of DELAY post samples
                    o_armed   <= 1'b0;
                    o_post    <= 1'b1;
                    post_left <= dl_total - 1'b1;
                end
                if (pre_left != 15'd0) pre_left <= pre_left - 1'b1;
            end else begin
                if (post_left == 15'd1) begin
                    // last sample stored: start sending, newest first
                    o_post    <= 1'b0;
                    o_sending <= 1'b1;
                    rp        <= wp;
                    rd_left   <= rd_total;
                    ph        <= 3'd0;
                end
                post_left <= post_left - 1'b1;
            end

        end else if (o_sending) begin
            if (ph == 3'd0 || ph == 3'd1) begin
                ph <= ph + 1'b1;                          // wait for RAM + pipeline
            end else if (ph == 3'd2) begin
                b0 <= wide ? rd_lo_q : (rp[0] ? rd_hi_q : rd_lo_q);
                b1 <= rd_hi_q;
                ph <= 3'd4;
            end else if (ph == 3'd4 || ph == 3'd5) begin
                if (i_tx_ready) begin                     // byte accepted
                    if (ph == 3'd4 && wide) begin
                        ph <= 3'd5;
                    end else if (rd_left == 15'd1) begin
                        o_sending <= 1'b0;                // all sent
                        ph        <= 3'd0;
                    end else begin
                        rd_left <= rd_left - 1'b1;
                        rp      <= (rp - 1'b1) & idx_mask;  // next older sample
                        ph      <= 3'd0;
                    end
                end
            end else begin
                ph <= 3'd0;                               // 3, 6, 7: not used
            end
        end
    end
endmodule
