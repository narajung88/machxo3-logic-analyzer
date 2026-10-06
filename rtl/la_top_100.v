//==============================================================================
// la_top_100.v -- logic analyzer top level, 100 MHz build (PLL)
//------------------------------------------------------------------------------
//
// Needs a PLL module named `pll_100` generated with Diamond's IPexpress
// (see README: "100 MHz build"):  CLKI = 12 MHz in, CLKOP = 100 MHz out,
// LOCK output enabled.
//
//==============================================================================
module la_top_100 (
    input  wire        i_clk_12m,
    input  wire        i_uart_rx,
    output wire        o_uart_tx,
    input  wire [15:0] i_probe,
    output wire [3:0]  o_test,
    output wire [7:0]  o_led_n            // active low
);
    wire clk, lock;

    pll_100 u_pll (
        .CLKI (i_clk_12m),
        .CLKOP(clk),
        .LOCK (lock)
    );

    wire armed, post, sending;

    la_core #(
        .CLK_HZ(100_000_000), .BAUD(921_600),
        .RATE_P(1), .RATE_Q(1)            // exact divide-by-(divider + 1)
    ) u_core (
        .i_clk(clk),
        .i_uart_rx(i_uart_rx), .o_uart_tx(o_uart_tx),
        .i_probe(i_probe), .o_test(o_test),
        .o_armed(armed), .o_post(post), .o_sending(sending)
    );

    // heartbeat ~1.5 Hz; D3 shows PLL lock
    reg [25:0] hb = 26'd0;
    always @(posedge clk) hb <= hb + 1'b1;

    assign o_led_n = ~{hb[25], lock, 3'b000, sending, post, armed};
endmodule
