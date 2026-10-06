//==============================================================================
// sump_resp.v -- replies to the SUMP ID and METADATA commands
//------------------------------------------------------------------------------
// ID       -> "1ALS"
// METADATA -> a list of tokens sigrok reads to learn about the device:
//
//   0x01 "MachXO3 LA\0"   device name
//   0x02 "1.0\0"          firmware version
//   0x20 <u32>            number of channels  (16)
//   0x21 <u32>            sample memory, bytes (16384 = 8192 x 16 ch or 16384 x 8 ch)
//   0x23 <u32>            maximum sample rate, Hz (= CLK_HZ)
//   0x24 <u32>            protocol version (2)
//   0x00                  end
//
// u32 values are big-endian.
//
// HOW: the whole reply is loaded into a shift register and shifted out one
// byte at a time. An earlier version looked the bytes up in a `case` table
// (a ROM); on hardware Lattice LSE turned that table into all zeros, so the
// device answered "\0\0\0\0" to ID. Registers loaded with constants cannot be
// turned into a ROM, so this version is immune to that.
//==============================================================================
module sump_resp #(
    parameter integer CLK_HZ = 12_000_000
) (
    input  wire       i_clk,
    input  wire       i_abort,            // RESET command
    input  wire       i_id,               // send the ID reply
    input  wire       i_meta,             // send the metadata

    output wire [7:0] o_tx_data,
    output wire       o_tx_valid,
    input  wire       i_tx_ready
);
    localparam [31:0] RATE = CLK_HZ;
    localparam integer N   = 38;          // longest reply (metadata), bytes

    localparam [8*4-1:0] ID_MSG = {8'h31, 8'h41, 8'h4C, 8'h53};          // "1ALS"

    localparam [8*N-1:0] META_MSG = {
        8'h01,                                                            // name
        8'h4D, 8'h61, 8'h63, 8'h68, 8'h58, 8'h4F, 8'h33, 8'h20, 8'h4C, 8'h41,   // "MachXO3 LA"
        8'h00,
        8'h02, 8'h31, 8'h2E, 8'h30, 8'h00,                                // version "1.0"
        8'h20, 32'd16,                                                    // channels
        8'h21, 32'd16384,                                                 // memory bytes
        8'h23, RATE,                                                      // max rate
        8'h24, 32'd2,                                                     // protocol
        8'h00                                                             // end
    };

    reg [8*N-1:0] sh   = {(8*N){1'b0}};  // byte to send is in the top 8 bits
    reg [5:0]     left = 6'd0;           // bytes still to send (0 = idle)

    assign o_tx_valid = (left != 6'd0);
    assign o_tx_data  = sh[8*N-1 -: 8];

    always @(posedge i_clk) begin
        if (i_abort) begin
            left <= 6'd0;
        end else if (i_id) begin
            sh   <= {ID_MSG, {(8*(N-4)){1'b0}}};
            left <= 6'd4;
        end else if (i_meta) begin
            sh   <= META_MSG;
            left <= N;
        end else if (o_tx_valid && i_tx_ready) begin     // byte accepted
            sh   <= {sh[8*N-9:0], 8'h00};
            left <= left - 1'b1;
        end
    end
endmodule
