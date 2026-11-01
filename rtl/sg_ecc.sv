// Hsiao SECDED (72,64): combinational encoder + decoder (spec section 7).
// Codeword layout: cw[63:0] data, cw[71:64] check.  The optional output register
// (ECC_PIPE) lives in sg_arb so the tag pipeline stays in one place.
module sg_ecc
  import sg_ecc_pkg::*;
(
  input  logic [63:0] enc_data,
  output logic [71:0] enc_cw,
  input  logic [71:0] dec_cw,
  output logic [63:0] dec_data,   // corrected data (as received when UE)
  output logic [71:0] dec_fix,    // corrected codeword
  output logic        dec_ce,
  output logic        dec_ue
);
  assign enc_cw = {ecc_enc(enc_data), enc_data};

  logic [7:0]  syn;
  logic [71:0] match;

  always_comb begin
    syn = ecc_syn(dec_cw);
    for (int i = 0; i < 72; i++) match[i] = (syn == H_COL[i]);
    // odd weight + column match = single error; any other non-zero syndrome = uncorrectable
    dec_ce   = (syn != 8'h00) && (^syn) && (|match);
    dec_ue   = (syn != 8'h00) && !dec_ce;
    dec_fix  = dec_cw ^ (dec_ce ? match : 72'h0);
    dec_data = dec_fix[63:0];
  end
endmodule
