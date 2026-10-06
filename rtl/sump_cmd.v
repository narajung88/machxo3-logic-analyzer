//==============================================================================
// sump_cmd.v -- SUMP / Openbench Logic Sniffer command decoder
//------------------------------------------------------------------------------
// Decodes the byte stream from the PC (sigrok/PulseView "ols" driver).
//
// Short commands (1 byte, bit 7 = 0):
//   0x00 RESET     abort capture / readout
//   0x01 ARM       start a capture
//   0x02 ID        reply "1ALS"
//   0x04 METADATA  reply with device description
//   (0x11 XON, 0x13 XOFF and anything else: ignored)
//
// Long commands (bit 7 = 1): opcode + 4 data bytes, little-endian.
//   0x80 DIVIDER   bits 23:0  sample rate = 100 MHz / (divider + 1)
//   0x81 SIZE      bits 15:0  read count  = samples to send / 4 - 1
//                  bits 31:16 delay count = samples after trigger / 4 - 1
//   0x82 FLAGS     bit 2/3 = disable channel group 0/1 (channels 0-7 / 8-15)
//                  bit 11  = internal test pattern
//   0xC0 TRIGGER MASK  (stage 0)  channels that take part in the trigger
//   0xC1 TRIGGER VALUE (stage 0)  level each masked channel must have
//   (other long commands, e.g. stages 1-3 and their config: ignored)
//
// sigrok sends 0x00 five times before talking to the device, which brings
// this decoder back to "expect an opcode" whatever state it was in.
//
// LSE NOTE: `n` is a plain counter (0 = expecting an opcode), not an encoded
// state machine; every register has an initial value.
//==============================================================================
module sump_cmd (
    input  wire        i_clk,
    input  wire [7:0]  i_byte,
    input  wire        i_valid,

    output reg         o_reset = 1'b0,    // 1-clock pulses
    output reg         o_arm   = 1'b0,
    output reg         o_id    = 1'b0,
    output reg         o_meta  = 1'b0,

    output reg  [23:0] o_divider    = 24'd99,     // 1 MHz
    output reg  [15:0] o_read_cnt   = 16'd255,    // 1024 samples
    output reg  [15:0] o_delay_cnt  = 16'd255,
    output reg  [15:0] o_flags      = 16'h0030,   // groups 2,3 off
    output reg  [15:0] o_trig_mask  = 16'd0,
    output reg  [15:0] o_trig_value = 16'd0
);
    reg [2:0]  n  = 3'd0;                 // data bytes received (0 = idle)
    reg [7:0]  op = 8'd0;
    reg [23:0] d  = 24'd0;                // first three data bytes

    wire [31:0] data = {i_byte, d};       // complete argument on the 4th byte

    always @(posedge i_clk) begin
        o_reset <= 1'b0;
        o_arm   <= 1'b0;
        o_id    <= 1'b0;
        o_meta  <= 1'b0;

        if (i_valid) begin
            if (n == 3'd0) begin
                if (i_byte[7]) begin                  // long command opcode
                    op <= i_byte;
                    n  <= 3'd1;
                end else begin                        // short command
                    if (i_byte == 8'h00) o_reset <= 1'b1;
                    if (i_byte == 8'h01) o_arm   <= 1'b1;
                    if (i_byte == 8'h02) o_id    <= 1'b1;
                    if (i_byte == 8'h04) o_meta  <= 1'b1;
                end
            end else if (n == 3'd4) begin             // last data byte
                n <= 3'd0;
                if (op == 8'h80) o_divider    <= data[23:0];
                if (op == 8'h81) begin
                    o_read_cnt  <= data[15:0];
                    o_delay_cnt <= data[31:16];
                end
                if (op == 8'h82) o_flags      <= data[15:0];
                if (op == 8'hC0) o_trig_mask  <= data[15:0];
                if (op == 8'hC1) o_trig_value <= data[15:0];
            end else begin                            // data bytes 1..3
                d <= {i_byte, d[23:8]};               // little-endian
                n <= n + 1'b1;
            end
        end
    end
endmodule
