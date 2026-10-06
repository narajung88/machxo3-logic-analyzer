//==============================================================================
// tb_la.v -- self-checking testbench for the logic analyzer (la_top, 12 MHz)
//------------------------------------------------------------------------------
// Plays the part of sigrok's OLS driver over the UART: reset, ID, metadata,
// configure, arm, receive samples. Probe inputs are driven by the testbench
// (constants or a counter that increments every clock), so every received
// sample can be checked exactly.
//
// Run from the la/ folder:
//   iverilog -g2005 -o tb sim/tb_la.v rtl/*.v
//   vvp tb
// (la_top_100.v needs the Diamond PLL and is not simulated; exclude it:
//   iverilog -g2005 -o tb sim/tb_la.v rtl/la_top.v rtl/la_core.v rtl/la_capture.v \
//            rtl/sump_cmd.v rtl/sump_resp.v rtl/test_gen.v rtl/uart_rx.v rtl/uart_tx.v)
//==============================================================================
`timescale 1ns/1ps
module tb_la;
    localparam real CLK_NS = 1.0e9 / 12_000_000;
    localparam real BIT_NS = 1.0e9 / 921_600;

    // flag bits
    localparam [31:0] F_NOISE = 32'h0002, F_G0_OFF = 32'h0004, F_G1_OFF = 32'h0008,
                      F_G23_OFF = 32'h0030, F_TEST = 32'h0800;

    reg clk = 1'b0;
    always #(CLK_NS / 2.0) clk = ~clk;

    //--------------------------------------------------------------------------
    // DUT and probe stimulus
    //--------------------------------------------------------------------------
    reg         host_tx = 1'b1;
    wire        fpga_tx;
    reg  [15:0] probe_const = 16'h0000;
    reg         probe_count = 1'b0;           // 1: probes = clock counter
    reg  [15:0] pcnt = 16'd0;
    wire [15:0] probe = probe_count ? pcnt : probe_const;
    wire [3:0]  test;
    wire [7:0]  led_n;

    reg pcnt_clr = 1'b0;
    always @(posedge clk) pcnt <= pcnt_clr ? 16'd0 : pcnt + 1'b1;

    la_top dut (
        .i_clk_12m(clk), .i_uart_rx(host_tx), .o_uart_tx(fpga_tx),
        .i_probe(probe), .o_test(test), .o_led_n(led_n)
    );

    integer errors = 0;

    task check(input cond, input [8*64-1:0] name);
        begin
            if (cond) $display("PASS  %0s", name);
            else begin $display("FAIL  %0s", name); errors = errors + 1; end
        end
    endtask

    //--------------------------------------------------------------------------
    // Host side of the UART
    //--------------------------------------------------------------------------
    task send_byte(input [7:0] b);
        integer i;
        begin
            host_tx = 1'b0; #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin host_tx = b[i]; #(BIT_NS); end
            host_tx = 1'b1; #(BIT_NS);
        end
    endtask

    task send_long(input [7:0] op, input [31:0] d);      // little-endian
        begin
            send_byte(op);
            send_byte(d[7:0]);  send_byte(d[15:8]);
            send_byte(d[23:16]); send_byte(d[31:24]);
        end
    endtask

    task send_reset5;
        integer i;
        begin for (i = 0; i < 5; i = i + 1) send_byte(8'h00); end
    endtask

    // receive queue
    reg [7:0] rxq [0:65535];
    integer   rx_n = 0, rx_ferr = 0;
    reg [7:0] rb;
    integer   k;
    always @(negedge fpga_tx) begin
        #(BIT_NS * 1.5);
        for (k = 0; k < 8; k = k + 1) begin rb[k] = fpga_tx; #(BIT_NS); end
        if (fpga_tx !== 1'b1) rx_ferr = rx_ferr + 1;
        rxq[rx_n] = rb;
        rx_n = rx_n + 1;
    end

    // wait until the line has been quiet for `quiet_bits` bit times
    task wait_quiet(input integer quiet_bits);
        integer last, q;
        begin
            q = 0; last = rx_n;
            while (q < quiet_bits) begin
                #(BIT_NS);
                if (rx_n != last) begin last = rx_n; q = 0; end
                else q = q + 1;
            end
        end
    endtask

    // wait for at least n bytes (or a timeout in ms), then for silence
    task wait_bytes(input integer n, input integer timeout_ms);
        integer t;
        begin
            t = 0;
            while (rx_n < n && t < timeout_ms * 1000) begin #(1000); t = t + 1; end
            wait_quiet(40);
        end
    endtask

    //--------------------------------------------------------------------------
    // One capture, sigrok style
    //--------------------------------------------------------------------------
    task capture(input [23:0] div, input [15:0] rd, input [15:0] dl,
                 input [31:0] flags, input [15:0] mask, input [15:0] value,
                 input count_from_arm, input integer expect_bytes);
        begin
            send_reset5;
            send_long(8'hC0, {16'd0, mask});
            send_long(8'hC1, {16'd0, value});
            send_long(8'hC2, 32'h0800_0000);          // stage 0, start
            send_long(8'h80, {8'd0, div});
            send_long(8'h81, {dl, rd});
            send_long(8'h82, flags);
            rx_n = 0;
            if (count_from_arm) begin                 // restart the probe counter
                @(negedge clk); pcnt_clr = 1'b1;      // just before ARM is sent
                @(negedge clk); pcnt_clr = 1'b0;
            end
            send_byte(8'h01);                         // ARM
            wait_bytes(expect_bytes, 400);
        end
    endtask

    // sample i as sent (newest first), 16-channel mode
    function [15:0] s16(input integer i);
        s16 = {rxq[2*i+1], rxq[2*i]};
    endfunction

    //--------------------------------------------------------------------------
    // Demo-signal monitor: decode the UART test output from time 0
    //--------------------------------------------------------------------------
    localparam real BIT115 = 1.0e9 / 115_200;
    reg [8*32-1:0] demo_str = 0;
    integer        demo_n = 0;
    reg [7:0]      db;
    integer        j;
    always @(negedge test[2]) begin
        #(BIT115 * 1.5);
        for (j = 0; j < 8; j = j + 1) begin db[j] = test[2]; #(BIT115); end
        if (demo_n < 21) begin demo_str = {demo_str[8*31-1:0], db}; demo_n = demo_n + 1; end
    end

    //--------------------------------------------------------------------------
    // Tests
    //--------------------------------------------------------------------------
    integer i, n, bad, span, pos, tmp;
    reg [15:0] a, b;
    reg [8*16-1:0] name;
    reg [31:0] v32;
    integer t0, t1;
    reg ok;

    initial begin
        #(20_000);

        //----------------------------------------------------------------------
        // T1 identification
        //----------------------------------------------------------------------
        send_reset5;
        rx_n = 0;
        send_byte(8'h02);
        wait_bytes(4, 5);
        check(rx_n == 4 && rxq[0] == "1" && rxq[1] == "A" && rxq[2] == "L" && rxq[3] == "S",
              "T1 ID command replies \"1ALS\"");

        //----------------------------------------------------------------------
        // T2 metadata, parsed the way sigrok does
        //----------------------------------------------------------------------
        rx_n = 0;
        send_byte(8'h04);
        wait_bytes(38, 5);
        ok = 1; i = 0; name = 0;
        while (i < rx_n && rxq[i] != 8'h00) begin
            if (rxq[i] < 8'h20) begin                     // string token
                tmp = rxq[i]; i = i + 1;
                if (tmp == 1) name = 0;
                while (rxq[i] != 8'h00) begin
                    if (tmp == 1) name = {name[8*15-1:0], rxq[i]};
                    i = i + 1;
                end
                i = i + 1;
            end else if (rxq[i] < 8'h40) begin            // 32-bit BE
                tmp = rxq[i];
                v32 = {rxq[i+1], rxq[i+2], rxq[i+3], rxq[i+4]};
                if (tmp == 8'h20 && v32 != 16)       ok = 0;
                if (tmp == 8'h21 && v32 != 16384)    ok = 0;
                if (tmp == 8'h23 && v32 != 12000000) ok = 0;
                if (tmp == 8'h24 && v32 != 2)        ok = 0;
                i = i + 5;
            end else i = i + 2;                           // 8-bit token
        end
        check(ok && name[8*10-1:0] == "MachXO3 LA" && rxq[rx_n-1] == 8'h00 && rx_n == 38,
              "T2 metadata: name, 16 ch, 16384 B, 12 MHz max, proto 2");

        //----------------------------------------------------------------------
        // T3 internal test pattern, 16 channels, 1024 samples, no trigger
        //----------------------------------------------------------------------
        capture(24'd99, 16'd255, 16'd255, F_TEST | F_NOISE | F_G23_OFF, 16'h0, 16'h0, 0, 2048);
        bad = 0;
        for (i = 1; i < 1024; i = i + 1) if (s16(i) != s16(i-1) - 16'd1) bad = bad + 1;
        check(rx_n == 2048 && bad == 0,
              "T3 test pattern: 1024 samples, newest first, consecutive");

        //----------------------------------------------------------------------
        // T4 sample rate 1 MHz: probes = clock counter, spacing must be 12 clocks
        //----------------------------------------------------------------------
        probe_count = 1;
        capture(24'd99, 16'd255, 16'd255, F_NOISE | F_G23_OFF, 16'h0, 16'h0, 0, 2048);
        bad = 0;
        for (i = 1; i < 1024; i = i + 1) if (s16(i-1) - s16(i) != 16'd12) bad = bad + 1;
        check(rx_n == 2048 && bad == 0, "T4 1 MHz: every sample exactly 12 clocks apart");

        //----------------------------------------------------------------------
        // T5 sample rate 10 MHz from a 12 MHz clock: 1-2 clocks, 1.2 average
        //----------------------------------------------------------------------
        capture(24'd9, 16'd255, 16'd255, F_NOISE | F_G23_OFF, 16'h0, 16'h0, 0, 2048);
        bad = 0;
        for (i = 1; i < 1024; i = i + 1) begin
            tmp = (s16(i-1) - s16(i)) & 16'hFFFF;
            if (tmp != 1 && tmp != 2) bad = bad + 1;
        end
        span = (s16(0) - s16(1023)) & 16'hFFFF;
        $display("      10 MHz: 1023 intervals span %0d clocks (ideal 1227.6)", span);
        check(bad == 0 && span >= 1226 && span <= 1229, "T5 10 MHz: average rate exact, jitter <= 1 clock");

        //----------------------------------------------------------------------
        // T6 trigger + 25 % pre-trigger: fire on probes[15:12] == 5
        //----------------------------------------------------------------------
        // read 1024 samples, delay 768 -> 256 pre-trigger samples
        capture(24'd99, 16'd255, 16'd191, F_NOISE | F_G23_OFF, 16'hF000, 16'h5000, 1, 2048);
        // oldest-first index p = 1023 - i
        pos = 1023 - 256;                                  // newest-first index of oldest+256
        a = s16(pos); b = s16(pos + 1);
        bad = 0;
        for (i = 1; i < 1024; i = i + 1) if (s16(i-1) - s16(i) != 16'd12) bad = bad + 1;
        $display("      trigger sample (index 256 from oldest) = 0x%h, previous = 0x%h", a, b);
        check(rx_n == 2048 && a[15:12] == 4'h5 && b[15:12] == 4'h4 && bad == 0,
              "T6 trigger lands at sample 256 of 1024 (25 % pre-trigger)");

        //----------------------------------------------------------------------
        // T7 trigger condition already true at ARM: must still collect 256
        //    valid pre-trigger samples first (no stale data in the buffer)
        //----------------------------------------------------------------------
        capture(24'd99, 16'd255, 16'd191, F_NOISE | F_G23_OFF, 16'hF000, 16'h0000, 1, 2048);
        a = s16(1023);                                     // oldest
        b = s16(1023 - 256);                               // trigger sample
        bad = 0;
        for (i = 1; i < 1024; i = i + 1) if (s16(i-1) - s16(i) != 16'd12) bad = bad + 1;
        $display("      oldest sample 0x%h, trigger sample 0x%h", a, b);
        check(bad == 0 && a < 16'd400 && b - a == 16'd3072,
              "T7 pre-trigger buffer is filled before the trigger is accepted");

        //----------------------------------------------------------------------
        // T8 8-channel mode (group 0 only): 16384 samples, 1 byte each
        //----------------------------------------------------------------------
        capture(24'd24, 16'd4095, 16'd4095, F_TEST | F_NOISE | F_G1_OFF | F_G23_OFF,
                16'h0, 16'h0, 0, 16384);
        bad = 0;
        for (i = 1; i < 16384; i = i + 1) if (rxq[i] != ((rxq[i-1] - 8'd1) & 8'hFF)) bad = bad + 1;
        check(rx_n == 16384 && bad == 0, "T8 8-channel mode: 16384 samples, 1 byte each");

        //----------------------------------------------------------------------
        // T9 group 1 only (channels 8-15)
        //----------------------------------------------------------------------
        probe_count = 0; probe_const = 16'hA55A;
        capture(24'd99, 16'd63, 16'd63, F_NOISE | F_G0_OFF | F_G23_OFF, 16'h0, 16'h0, 0, 256);
        bad = 0;
        for (i = 0; i < 256; i = i + 1) if (rxq[i] != 8'hA5) bad = bad + 1;
        check(rx_n == 256 && bad == 0, "T9 channels 8-15 only: sends the high byte");

        //----------------------------------------------------------------------
        // T10 request larger than memory is clamped (16 ch: 8192 samples)
        //----------------------------------------------------------------------
        capture(24'd24, 16'd4095, 16'd4095, F_TEST | F_NOISE | F_G23_OFF, 16'h0, 16'h0, 0, 16384);
        check(rx_n == 16384, "T10 16-ch request for 16384 samples clamps to 8192");

        //----------------------------------------------------------------------
        // T11 RESET aborts a capture that is waiting for its trigger
        //----------------------------------------------------------------------
        probe_const = 16'h0000;
        send_reset5;
        send_long(8'hC0, 32'h0000_FFFF);
        send_long(8'hC1, 32'h0000_DEAD);                   // never matches
        send_long(8'h81, {16'd255, 16'd255});
        send_long(8'h82, F_NOISE | F_G23_OFF);
        rx_n = 0;
        send_byte(8'h01);
        #(200_000);
        ok = (led_n[0] == 1'b0);                           // D9 = armed
        send_reset5;
        #(5_000);
        check(ok && led_n[0] == 1'b1 && rx_n == 0, "T11 RESET aborts a waiting capture, nothing sent");
        rx_n = 0;
        send_byte(8'h02);
        wait_bytes(4, 5);
        check(rx_n == 4 && rxq[0] == "1", "T12 device responds normally afterwards");

        //----------------------------------------------------------------------
        // Demo signals
        //----------------------------------------------------------------------
        @(posedge test[0]); t0 = $time; @(posedge test[0]); t1 = $time;
        check(t1 - t0 > 990 && t1 - t0 < 1010, "T13 test signal 0 is 1 MHz");
        @(posedge test[1]); t0 = $time; @(posedge test[1]); t1 = $time;
        check(t1 - t0 > 9990 && t1 - t0 < 10010, "T14 test signal 1 is 100 kHz");
        $display("      test signal 2 decoded: \"%0s\"", demo_str[8*21-1:16]);
        check(demo_n >= 21 && demo_str[8*21-1:16] == "Hello from MachXO3!",
              "T15 test signal 2 sends \"Hello from MachXO3!\" at 115200");

        check(rx_ferr == 0, "T16 every byte to the PC had a valid stop bit");

        $display("");
        if (errors == 0) $display("ALL TESTS PASSED");
        else             $display("%0d TEST(S) FAILED", errors);
        $finish;
    end
endmodule
