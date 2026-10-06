//==============================================================================
// pll_100_sim.v -- SIMULATION-ONLY stand-in for the Diamond-generated pll_100
// Produces a free-running 100 MHz clock and asserts LOCK after 1 us.
// Do NOT add this file to the Diamond project.
//==============================================================================
`timescale 1ns/1ps
module pll_100 (input wire CLKI, output reg CLKOP = 1'b0, output reg LOCK = 1'b0);
    always #5 CLKOP = ~CLKOP;
    initial #1000 LOCK = 1'b1;
endmodule
