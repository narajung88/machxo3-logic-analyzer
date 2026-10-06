//==============================================================================
// tb_la_100.v -- checks the 100 MHz build (la_top_100) with a simulated PLL
//------------------------------------------------------------------------------
//   iverilog -g2005 -o tb100 sim/tb_la_100.v sim/pll_100_sim.v rtl/la_top_100.v \
//            rtl/la_core.v rtl/la_capture.v rtl/sump_cmd.v rtl/sump_resp.v \
//            rtl/test_gen.v rtl/uart_rx.v rtl/uart_tx.v
//   vvp tb100
//==============================================================================
`timescale 1ns/1ps
module tb_la_100;
    localparam real BIT_NS = 1.0e9 / 921_600;
    reg clk12 = 1'b0;
    always #41.667 clk12 = ~clk12;

    reg         host_tx = 1'b1;
    wire        fpga_tx;
    reg  [15:0] pcnt = 16'd0;                    // counts the 100 MHz clock
    reg         pcnt_clr = 1'b0;
    wire [3:0]  test;
    wire [7:0]  led_n;
    always @(posedge dut.clk) pcnt <= pcnt_clr ? 16'd0 : pcnt + 1'b1;

    la_top_100 dut (.i_clk_12m(clk12), .i_uart_rx(host_tx), .o_uart_tx(fpga_tx),
                    .i_probe(pcnt), .o_test(test), .o_led_n(led_n));

    integer errors = 0;
    task check(input cond, input [8*64-1:0] name);
        begin
            if (cond) $display("PASS  %0s", name);
            else begin $display("FAIL  %0s", name); errors = errors + 1; end
        end
    endtask

    task send_byte(input [7:0] b);
        integer i;
        begin
            host_tx = 1'b0; #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin host_tx = b[i]; #(BIT_NS); end
            host_tx = 1'b1; #(BIT_NS);
        end
    endtask
    task send_long(input [7:0] op, input [31:0] d);
        begin send_byte(op); send_byte(d[7:0]); send_byte(d[15:8]); send_byte(d[23:16]); send_byte(d[31:24]); end
    endtask

    reg [7:0] rxq [0:65535];
    integer   rx_n = 0;
    reg [7:0] rb;
    integer   k;
    always @(negedge fpga_tx) begin
        #(BIT_NS * 1.5);
        for (k = 0; k < 8; k = k + 1) begin rb[k] = fpga_tx; #(BIT_NS); end
        rxq[rx_n] = rb; rx_n = rx_n + 1;
    end
    task wait_done(input integer n);
        integer last, q, t;
        begin
            t = 0; while (rx_n < n && t < 400000) begin #(1000); t = t + 1; end
            q = 0; last = rx_n;
            while (q < 40) begin #(BIT_NS); if (rx_n != last) begin last = rx_n; q = 0; end else q = q + 1; end
        end
    endtask
    function [15:0] s16(input integer i); s16 = {rxq[2*i+1], rxq[2*i]}; endfunction

    task capture(input [23:0] div, input [15:0] rd, input [15:0] dl, input [31:0] flags,
                 input [15:0] mask, input [15:0] value, input integer nbytes);
        integer i;
        begin
            for (i = 0; i < 5; i = i + 1) send_byte(8'h00);
            send_long(8'hC0, {16'd0, mask}); send_long(8'hC1, {16'd0, value});
            send_long(8'hC2, 32'h0800_0000);
            send_long(8'h80, {8'd0, div}); send_long(8'h81, {dl, rd}); send_long(8'h82, flags);
            rx_n = 0;
            @(negedge dut.clk); pcnt_clr = 1'b1; @(negedge dut.clk); pcnt_clr = 1'b0;
            send_byte(8'h01);
            wait_done(nbytes);
        end
    endtask

    integer i, bad;
    reg [31:0] rate;
    reg [15:0] a, b;
    initial begin
        #(20_000);
        check(led_n[6] == 1'b0, "P1 PLL lock shown on D3");

        for (i = 0; i < 5; i = i + 1) send_byte(8'h00);
        rx_n = 0; send_byte(8'h04); wait_done(38);
        rate = {rxq[28], rxq[29], rxq[30], rxq[31]};   // token 0x23 at index 27
        check(rxq[27] == 8'h23 && rate == 100_000_000, "P2 metadata reports 100 MHz max rate");

        // 1 MHz: exactly 100 clocks per sample
        capture(24'd99, 16'd255, 16'd255, 32'h0032, 16'h0, 16'h0, 2048);
        bad = 0; for (i = 1; i < 1024; i = i + 1) if (s16(i-1) - s16(i) != 16'd100) bad = bad + 1;
        check(rx_n == 2048 && bad == 0, "P3 1 MHz: every sample exactly 100 clocks apart");

        // 100 MHz: every clock
        capture(24'd0, 16'd255, 16'd255, 32'h0032, 16'h0, 16'h0, 2048);
        bad = 0; for (i = 1; i < 1024; i = i + 1) if (s16(i-1) - s16(i) != 16'd1) bad = bad + 1;
        check(rx_n == 2048 && bad == 0, "P4 100 MHz: a sample every clock");

        // 25 MHz with a 50 % pre-trigger, trigger on bits 15:12 == 3
        capture(24'd3, 16'd255, 16'd127, 32'h0032, 16'hF000, 16'h3000, 2048);
        a = s16(1023 - 512); b = s16(1023 - 511);
        bad = 0; for (i = 1; i < 1024; i = i + 1) if (s16(i-1) - s16(i) != 16'd4) bad = bad + 1;
        $display("      trigger sample 0x%h, previous 0x%h", a, b);
        check(bad == 0 && a[15:12] == 4'h3 && b[15:12] == 4'h2, "P5 25 MHz, trigger at sample 512 of 1024");

        $display("");
        if (errors == 0) $display("ALL TESTS PASSED"); else $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule
