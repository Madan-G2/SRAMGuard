// Repair remap (spec section 8.1): 2-entry row CAM + IO shift muxes.
//
// Repair signature (38 bits, also the CSR/fuse export format):
//   [9:0]   entry0 {valid, bad_row[8:0]}  -> physical row 512
//   [19:10] entry1 {valid, bad_row[8:0]}  -> physical row 513
//   [27:20] {v1, f1[6:0]}                 first bad physical IO
//   [35:28] {v2, f2[6:0]}                 second bad physical IO, f1 < f2, v2 implies v1
//   [37:36] spare_bad                     spare row k failed power-on test
//
// IO shift encoding: logical IO i sits at physical i + (v1 & i>=f1) + (v2 & i>=f2-1).
// Equivalent per-physical-position form used below: physical j carries logical
// j - (v1 & j>f1) - (v2 & j>f2); positions f1/f2 are skipped.
module sg_remap
  import sg_pkg::*;
(
  input  logic            clk,
  input  logic            rst_n,
  input  logic            clr,
  input  logic            load_en,
  input  logic [37:0]     load_sig,
  input  logic            set_en,          // online repair: arm one entry
  input  logic            set_k,
  input  logic [8:0]      set_row,
  output logic [37:0]     sig,
  output logic [1:0]      ent_v,
  output logic [8:0]      ent_row0,
  output logic [8:0]      ent_row1,
  output logic [1:0]      spare_bad,

  // row path
  input  logic [8:0]      lrow,
  output logic [9:0]      prow,
  output logic            rhit,

  // IO path
  input  logic [WORD_W-1:0] wd72,
  output logic [PIO-1:0]    wd74,
  input  logic [PIO-1:0]    rd74,
  output logic [WORD_W-1:0] rd72
);
  logic [1:0] v_q;
  logic [8:0] row_q [2];
  logic       v1_q, v2_q;
  logic [6:0] f1_q, f2_q;
  logic [1:0] sbad_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v_q <= '0; row_q[0] <= '0; row_q[1] <= '0;
      v1_q <= 1'b0; v2_q <= 1'b0; f1_q <= '0; f2_q <= '0;
      sbad_q <= '0;
    end else if (clr) begin
      v_q <= '0; row_q[0] <= '0; row_q[1] <= '0;
      v1_q <= 1'b0; v2_q <= 1'b0; f1_q <= '0; f2_q <= '0;
      sbad_q <= '0;
    end else if (load_en) begin
      v_q[0] <= load_sig[9];   row_q[0] <= load_sig[8:0];
      v_q[1] <= load_sig[19];  row_q[1] <= load_sig[18:10];
      v1_q <= load_sig[27];    f1_q <= load_sig[26:20];
      v2_q <= load_sig[35] & load_sig[27]; f2_q <= load_sig[34:28];
      sbad_q <= load_sig[37:36];
    end else if (set_en) begin
      v_q[set_k] <= 1'b1;
      row_q[set_k] <= set_row;
    end
  end

  assign sig = {sbad_q, v2_q, f2_q, v1_q, f1_q, v_q[1], row_q[1], v_q[0], row_q[0]};
  assign ent_v = v_q;
  assign ent_row0 = row_q[0];
  assign ent_row1 = row_q[1];
  assign spare_bad = sbad_q;

  // ---- row CAM (entry 0 wins on a double match)
  logic hit0, hit1;
  assign hit0 = v_q[0] && (row_q[0] == lrow);
  assign hit1 = v_q[1] && (row_q[1] == lrow);
  assign rhit = hit0 | hit1;
  assign prow = hit0 ? 10'(ROWS) : hit1 ? 10'(ROWS + 1) : {1'b0, lrow};

  // ---- IO shift
  always_comb begin
    int s, l, m;
    wd74 = '0;
    for (int j = 0; j < PIO; j++) begin
      s = int'(v1_q && (j > int'(f1_q))) + int'(v2_q && (j > int'(f2_q)));
      l = j - s;
      if (!(v1_q && j == int'(f1_q)) && !(v2_q && j == int'(f2_q)) && l < WORD_W) wd74[j] = wd72[l];
    end
    for (int i = 0; i < WORD_W; i++) begin
      m = i + int'(v1_q && (i >= int'(f1_q))) + int'(v2_q && (i >= int'(f2_q) - 1));
      rd72[i] = rd74[m];
    end
  end
endmodule
