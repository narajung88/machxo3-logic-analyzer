//==============================================================================
// uart_rx.v -- 8N1 UART receiver
//------------------------------------------------------------------------------
// Receives asynchronous serial data (1 start bit, 8 data bits LSB first,
// no parity, 1 stop bit) and presents each byte as a one-cycle pulse.
//
// FEATURES
//   * Built-in 2-flop synchronizer on `rx` -- connect the pin directly.
//   * Start bit is re-checked at its midpoint, so short glitches are rejected.
//   * Each data/stop bit is sampled once, at the middle of the bit period.
//   * Bad start or stop bit pulses `o_ferr` and the byte is dropped.
//
// INTERFACE
//   i_clk     system clock (CLK_HZ)
//   i_rst     synchronous reset, active high. Optional: tie to 1'b0 if unused.
//   i_rx      serial input line (idles high)
//   o_data    received byte, valid when o_valid = 1 (held until next byte)
//   o_valid   1-cycle pulse: a good byte is on o_data
//   o_ferr    1-cycle pulse: framing error (bad start/stop bit), byte dropped
//
//   There is no backpressure: a UART cannot be paused, so the consumer must
//   take o_data in the cycle o_valid is high (or within one byte time,
//   ~10 bit periods, since o_data is held until the next byte completes).
//
// PARAMETERS
//   CLK_HZ   clock frequency in Hz            (default 12_000_000)
//   BAUD     baud rate in bits per second     (default 115_200)
//   CLKS_PER_BIT is derived and rounded to the nearest integer. Keep the
//   rounding error under ~2 %; see README for a table of good combinations.
//
// LATTICE LSE NOTES (why the code looks like this)
//   * No `case`-based state machine. LSE re-encodes FSMs (often one-hot); if
//     the reset is optimized away, the all-zeros power-up value is an illegal
//     one-hot state and the FSM never recovers. Here, all-zeros == idle.
//   * Every register has an initial value. On the MachXO3 every flip-flop is
//     forced to its initial value when the device configures, so the module
//     works correctly even with i_rst tied low.
//==============================================================================
module uart_rx #(
    parameter integer CLK_HZ = 12_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       i_clk,
    input  wire       i_rst,
    input  wire       i_rx,
    output reg  [7:0] o_data  = 8'd0,
    output reg        o_valid = 1'b0,
    output reg        o_ferr  = 1'b0
);
    // Clock cycles per bit, rounded to nearest.
    localparam integer CLKS_PER_BIT = (CLK_HZ + BAUD/2) / BAUD;
    localparam integer HALF_BIT     = CLKS_PER_BIT / 2;

    //--------------------------------------------------------------------------
    // Input synchronizer (protects against metastability on the async pin).
    // Initialized to 1 (line idle) so power-up doesn't look like a start bit.
    //--------------------------------------------------------------------------
    reg [1:0] sync = 2'b11;
    always @(posedge i_clk) sync <= {sync[0], i_rx};
    wire rx = sync[1];

    //--------------------------------------------------------------------------
    // Receiver
    //   busy = 0           : idle, waiting for a falling edge
    //   busy = 1, bitn = 0 : in start bit, waiting for its midpoint
    //   busy = 1, bitn 1-8 : sampling data bits 0..7 at their midpoints
    //   busy = 1, bitn = 9 : sampling the stop bit
    //--------------------------------------------------------------------------
    reg        busy = 1'b0;
    reg [3:0]  bitn = 4'd0;
    reg [15:0] cnt  = 16'd0;              // supports CLKS_PER_BIT up to 65535
    reg [7:0]  sh   = 8'd0;               // shift register, LSB arrives first

    always @(posedge i_clk) begin
        o_valid <= 1'b0;                  // default: pulses last one cycle
        o_ferr  <= 1'b0;

        if (i_rst) begin
            busy <= 1'b0;

        end else if (!busy) begin
            // Idle: a low level means a start bit has begun.
            if (!rx) begin
                busy <= 1'b1;
                bitn <= 4'd0;
                cnt  <= 16'd0;
            end

        end else if (bitn == 4'd0) begin
            // Start bit: wait half a bit, then confirm the line is still low.
            if (cnt == HALF_BIT - 1) begin
                cnt <= 16'd0;
                if (rx) begin             // went high again: just a glitch
                    busy   <= 1'b0;
                    o_ferr <= 1'b1;
                end else
                    bitn <= 4'd1;         // genuine start bit
            end else
                cnt <= cnt + 1'b1;

        end else if (cnt == CLKS_PER_BIT - 1) begin
            // One full bit period later we are at the middle of the next bit.
            cnt <= 16'd0;
            if (bitn == 4'd9) begin
                // Stop bit must be high.
                busy <= 1'b0;
                if (rx) begin
                    o_data  <= sh;
                    o_valid <= 1'b1;
                end else
                    o_ferr  <= 1'b1;      // framing error: drop the byte
            end else begin
                sh   <= {rx, sh[7:1]};    // shift in from the top, LSB first
                bitn <= bitn + 1'b1;
            end

        end else
            cnt <= cnt + 1'b1;
    end
endmodule
