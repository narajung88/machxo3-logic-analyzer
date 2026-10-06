//==============================================================================
// la_core.v -- 16-channel SUMP-compatible logic analyzer
//------------------------------------------------------------------------------
//                 ┌────────────┐   config   ┌─────────────────────────────┐
//  PC ─► uart_rx ─► sump_cmd   ├───────────►│ la_capture                  │◄── 16 probes
//                 └─┬───┬──────┘   arm/rst  │ rate gen, trigger, 16 KB RAM │
//                   │id │meta               └──────────────┬──────────────┘
//                 ┌─▼───▼──────┐                           │ samples
//                 │ sump_resp  │──────────┐  ┌─────────────┘
//                 └────────────┘          ▼  ▼
//  PC ◄────────────────────────────── uart_tx (byte mux)
//
// Works with sigrok / PulseView ("Openbench Logic Sniffer & SUMP compatibles"
// driver). Everything runs from one clock (CLK_HZ); see la_capture.v for how
// the SUMP 100 MHz-based sample rate is derived from it.
//==============================================================================
module la_core #(
    parameter integer CLK_HZ = 12_000_000,
    parameter integer BAUD   = 921_600,
    parameter integer RATE_P = 25,        // 100 MHz / CLK_HZ = RATE_P / RATE_Q
    parameter integer RATE_Q = 3
) (
    input  wire        i_clk,
    input  wire        i_uart_rx,
    output wire        o_uart_tx,
    input  wire [15:0] i_probe,
    output wire [3:0]  o_test,            // demo signals (test_gen.v)
    output wire        o_armed,           // status for LEDs
    output wire        o_post,
    output wire        o_sending
);
    wire clk = i_clk;

    //--------------------------------------------------------------------------
    // Commands from the PC
    //--------------------------------------------------------------------------
    wire [7:0] rx_byte;
    wire       rx_valid, rx_ferr;

    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .i_clk(clk), .i_rst(1'b0), .i_rx(i_uart_rx),
        .o_data(rx_byte), .o_valid(rx_valid), .o_ferr(rx_ferr)
    );

    wire        c_reset, c_arm, c_id, c_meta;
    wire [23:0] divider;
    wire [15:0] read_cnt, delay_cnt, flags, trig_mask, trig_value;

    sump_cmd u_cmd (
        .i_clk(clk), .i_byte(rx_byte), .i_valid(rx_valid),
        .o_reset(c_reset), .o_arm(c_arm), .o_id(c_id), .o_meta(c_meta),
        .o_divider(divider), .o_read_cnt(read_cnt), .o_delay_cnt(delay_cnt),
        .o_flags(flags), .o_trig_mask(trig_mask), .o_trig_value(trig_value)
    );

    //--------------------------------------------------------------------------
    // Capture engine
    //--------------------------------------------------------------------------
    wire [7:0] cap_data;
    wire       cap_valid, cap_ready;

    la_capture #(.RATE_P(RATE_P), .RATE_Q(RATE_Q)) u_cap (
        .i_clk(clk), .i_reset(c_reset), .i_arm(c_arm),
        .i_divider(divider), .i_read_cnt(read_cnt), .i_delay_cnt(delay_cnt),
        .i_flags(flags), .i_trig_mask(trig_mask), .i_trig_value(trig_value),
        .i_probe(i_probe),
        .o_tx_data(cap_data), .o_tx_valid(cap_valid), .i_tx_ready(cap_ready),
        .o_armed(o_armed), .o_post(o_post), .o_sending(o_sending)
    );

    //--------------------------------------------------------------------------
    // ID / metadata replies
    //--------------------------------------------------------------------------
    wire [7:0] resp_data;
    wire       resp_valid, resp_ready;

    sump_resp #(.CLK_HZ(CLK_HZ)) u_resp (
        .i_clk(clk), .i_abort(c_reset), .i_id(c_id), .i_meta(c_meta),
        .o_tx_data(resp_data), .o_tx_valid(resp_valid), .i_tx_ready(resp_ready)
    );

    //--------------------------------------------------------------------------
    // Transmit: replies have priority over sample data. Only the source whose
    // byte is on the bus sees `ready`, so a byte is never consumed twice.
    //--------------------------------------------------------------------------
    wire tx_ready;
    assign resp_ready = tx_ready &&  resp_valid;
    assign cap_ready  = tx_ready && !resp_valid;

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .i_clk(clk), .i_rst(1'b0),
        .i_data (resp_valid ? resp_data : cap_data),
        .i_valid(resp_valid | cap_valid),
        .o_ready(tx_ready),
        .o_tx(o_uart_tx)
    );

    //--------------------------------------------------------------------------
    // Demo signals
    //--------------------------------------------------------------------------
    test_gen #(.CLK_HZ(CLK_HZ)) u_test (.i_clk(clk), .o_sig(o_test));
endmodule
