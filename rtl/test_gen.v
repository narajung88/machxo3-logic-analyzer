//==============================================================================
// test_gen.v -- demo signals to probe with the logic analyzer
//------------------------------------------------------------------------------
// Wire these pins to probe channels with jumper wires to try the analyzer
// without any other hardware:
//
//   o_sig[0]  1 MHz square wave
//   o_sig[1]  100 kHz square wave
//   o_sig[2]  UART, 115200 8N1: "Hello from MachXO3!\r\n" every 10 ms
//             (try PulseView's UART decoder on it)
//   o_sig[3]  1 kHz PWM whose duty cycle steps 0..100 % in 10 % steps
//             every 100 ms
//
// All periods are derived from CLK_HZ, which must be a multiple of 2 MHz.
//==============================================================================
module test_gen #(
    parameter integer CLK_HZ = 12_000_000
) (
    input  wire       i_clk,
    output reg  [3:0] o_sig = 4'b0100    // UART line idles high
);
    //--------------------------------------------------------------------------
    // Square waves: toggle every half period
    //--------------------------------------------------------------------------
    localparam integer HALF_1M   = CLK_HZ / 2_000_000;
    localparam integer HALF_100K = CLK_HZ / 200_000;

    reg [15:0] c1m = 16'd0, c100k = 16'd0;
    always @(posedge i_clk) begin
        if (c1m == HALF_1M - 1)     begin c1m   <= 16'd0; o_sig[0] <= ~o_sig[0]; end
        else                               c1m   <= c1m + 1'b1;
        if (c100k == HALF_100K - 1) begin c100k <= 16'd0; o_sig[1] <= ~o_sig[1]; end
        else                               c100k <= c100k + 1'b1;
    end

    //--------------------------------------------------------------------------
    // UART message every 10 ms
    //--------------------------------------------------------------------------
    localparam integer TICK_10MS = CLK_HZ / 100;
    localparam [4:0]   MSG_LEN   = 5'd21;

    // "Hello from MachXO3!\r\n", loaded into a shift register and sent one
    // byte at a time (a case-table ROM here came out as zeros under LSE).
    localparam [8*21-1:0] MSG = {
        8'h48, 8'h65, 8'h6C, 8'h6C, 8'h6F, 8'h20, 8'h66, 8'h72, 8'h6F, 8'h6D,   // "Hello from"
        8'h20, 8'h4D, 8'h61, 8'h63, 8'h68, 8'h58, 8'h4F, 8'h33, 8'h21,          // " MachXO3!"
        8'h0D, 8'h0A };

    reg [23:0]     t10  = 24'd0;
    reg            t10_start = 1'b1;              // registered "t10 == 0" (timing)
    reg [8*21-1:0] sh   = {(8*21){1'b0}};
    reg [4:0]      left = 5'd0;                       // bytes still to send
    wire           u_ready, u_tx;

    always @(posedge i_clk) begin
        if (t10 == TICK_10MS - 1) t10 <= 24'd0;
        else                      t10 <= t10 + 1'b1;
        t10_start <= (t10 == TICK_10MS - 1);        // true while t10 == 0

        if (left == 5'd0) begin
            if (t10_start) begin sh <= MSG; left <= MSG_LEN; end
        end else if (u_ready) begin                   // byte accepted
            sh   <= {sh[8*21-9:0], 8'h00};
            left <= left - 1'b1;
        end
    end

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(115_200)) u_msg (
        .i_clk(i_clk), .i_rst(1'b0),
        .i_data(sh[8*21-1 -: 8]), .i_valid(left != 5'd0), .o_ready(u_ready), .o_tx(u_tx)
    );

    always @(posedge i_clk) o_sig[2] <= u_tx;

    //--------------------------------------------------------------------------
    // 1 kHz PWM, duty steps every 100 ms
    //--------------------------------------------------------------------------
    localparam integer PWM_STEP = CLK_HZ / 10_000;   // 1/10 of a 1 kHz period

    reg [15:0] pc   = 16'd0;                          // clock within a step
    reg [3:0]  slot = 4'd0;                           // 0..9 slot within a period
    reg [3:0]  duty = 4'd0;                           // 0..10 slots high
    reg [6:0]  per  = 7'd0;                           // periods (100 = 100 ms)

    always @(posedge i_clk) begin
        if (pc == PWM_STEP - 1) begin
            pc <= 16'd0;
            if (slot == 4'd9) begin
                slot <= 4'd0;
                if (per == 7'd99) begin
                    per  <= 7'd0;
                    duty <= (duty == 4'd10) ? 4'd0 : duty + 1'b1;
                end else
                    per <= per + 1'b1;
            end else
                slot <= slot + 1'b1;
        end else
            pc <= pc + 1'b1;
        o_sig[3] <= (slot < duty);
    end
endmodule
