//==============================================================================
// la_top.v -- logic analyzer top level, 12 MHz build (no PLL)
//------------------------------------------------------------------------------
// Lattice MachXO3 Starter Kit. Runs straight from the 12 MHz crystal:
// sample rates up to 12 MHz. For 100 MHz sampling use la_top_100.v instead
// (add only ONE of the two top files to the Diamond project).
//
// Pins: constraints/la.lpf
//   probes 0-7  : J4 pins 13-20       probes 8-15 : J4 pins 23-30
//   test signals: J4 pins 33-36       GND         : J4 pins 11, 12, 21, 22, 31, 32
//   PC link     : FTDI channel B, 921600 baud
//   LEDs        : D9 armed, D8 capturing, D7 sending, D2 heartbeat
//==============================================================================
module la_top (
    input  wire        i_clk_12m,
    input  wire        i_uart_rx,
    output wire        o_uart_tx,
    input  wire [15:0] i_probe,
    output wire [3:0]  o_test,
    output wire [7:0]  o_led_n            // active low
);
    localparam integer CLK_HZ = 12_000_000;

    wire armed, post, sending;

    la_core #(
        .CLK_HZ(CLK_HZ), .BAUD(921_600),
        .RATE_P(25), .RATE_Q(3)           // 100 MHz / 12 MHz = 25 / 3
    ) u_core (
        .i_clk(i_clk_12m),
        .i_uart_rx(i_uart_rx), .o_uart_tx(o_uart_tx),
        .i_probe(i_probe), .o_test(o_test),
        .o_armed(armed), .o_post(post), .o_sending(sending)
    );

    // heartbeat: ~1 Hz blink shows the design is running
    reg [23:0] hb = 24'd0;
    always @(posedge i_clk_12m) hb <= hb + 1'b1;

    assign o_led_n = ~{hb[23], 4'b0000, sending, post, armed};
endmodule
