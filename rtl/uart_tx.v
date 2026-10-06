//==============================================================================
// uart_tx.v -- 8N1 UART transmitter
//------------------------------------------------------------------------------
// Sends one byte per transfer as 1 start bit, 8 data bits LSB first,
// no parity, 1 stop bit.
//
// INTERFACE (valid/ready handshake)
//   i_clk     system clock (CLK_HZ)
//   i_rst     synchronous reset, active high. Optional: tie to 1'b0 if unused.
//   i_data    byte to send
//   i_valid   caller has a byte on i_data
//   o_ready   transmitter is idle and can accept a byte
//   o_tx      serial output line (idles high) -- connect directly to the pin
//
//   A byte is accepted on any clock edge where i_valid && o_ready.
//   i_data is copied internally at that moment, so it may change afterwards.
//   o_ready drops the cycle after acceptance and returns high when the stop
//   bit has finished, i.e. one byte takes 10 * CLKS_PER_BIT clocks.
//
//   Simple use: hold i_valid high with the byte on i_data until you see
//   o_ready high on the same clock edge -- that byte is then sent.
//
// PARAMETERS
//   CLK_HZ   clock frequency in Hz            (default 12_000_000)
//   BAUD     baud rate in bits per second     (default 115_200)
//
// LATTICE LSE NOTES
//   No `case` state machine and every register has an initial value, so the
//   module starts idle (line high) straight out of configuration, with or
//   without i_rst. See uart_rx.v for the full explanation.
//==============================================================================
module uart_tx #(
    parameter integer CLK_HZ = 12_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       i_clk,
    input  wire       i_rst,
    input  wire [7:0] i_data,
    input  wire       i_valid,
    output wire       o_ready,
    output reg        o_tx = 1'b1
);
    localparam integer CLKS_PER_BIT = (CLK_HZ + BAUD/2) / BAUD;

    //--------------------------------------------------------------------------
    // frame = {stop, d7..d0, start}; bit index `bitn` is the bit on the line.
    //--------------------------------------------------------------------------
    reg [9:0]  frame  = 10'h3FF;
    reg [3:0]  bitn   = 4'd0;
    reg [15:0] cnt    = 16'd0;
    reg        active = 1'b0;

    assign o_ready = ~active;

    always @(posedge i_clk) begin
        if (i_rst) begin
            active <= 1'b0;
            o_tx   <= 1'b1;

        end else if (!active) begin
            o_tx <= 1'b1;                         // idle level
            if (i_valid) begin                    // accept (o_ready is high)
                frame  <= {1'b1, i_data, 1'b0};
                active <= 1'b1;
                bitn   <= 4'd0;
                cnt    <= 16'd0;
                o_tx   <= 1'b0;                   // start bit goes out now
            end

        end else if (cnt == CLKS_PER_BIT - 1) begin
            // End of the current bit period.
            cnt <= 16'd0;
            if (bitn == 4'd9) begin               // stop bit done
                active <= 1'b0;
                o_tx   <= 1'b1;
            end else begin
                bitn <= bitn + 1'b1;
                o_tx <= frame[bitn + 1'b1];
            end

        end else
            cnt <= cnt + 1'b1;
    end
endmodule
