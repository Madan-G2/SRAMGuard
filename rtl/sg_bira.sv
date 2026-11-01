// Built-in redundancy analysis (spec section 8.2): exhaustive search over
// {0, 1 or 2 of the logged rows} as spare rows, leftover failing IOs must fit the spare IOs.
// Minimises (spare rows + spare IOs) used.  Rows >= ROWS in the log are failed spare rows
// and are marked unusable.  One candidate is evaluated per clock.
module sg_bira
  import sg_pkg::*;
(
  input  logic                                clk,
  input  logic                                rst_n,
  input  logic                                start,
  input  logic [FLOG_DEPTH-1:0]               e_v,
  input  logic [FLOG_DEPTH-1:0][9:0]          e_row,
  input  logic [FLOG_DEPTH-1:0][PIO-1:0]      e_mask,
  input  logic                                ovf,
  output logic                                busy,
  output logic                                done,      // pulse
  output logic                                ok,        // sticky until next start
  output logic                                fail,
  output logic                                prog_en,   // pulse, prog_sig valid
  output logic [37:0]                         prog_sig
);
  typedef enum logic [1:0] {B_IDLE, B_ITER, B_PROG} bstate_e;
  bstate_e st;

  logic [3:0] a, b;                      // candidate: rows e_a, e_b (8 = none)
  logic [3:0] best_cost, best_a, best_b;
  logic [PIO-1:0] best_left;

  logic [FLOG_DEPTH-1:0] needs;
  logic [1:0] sb;
  logic [1:0] good;

  always_comb begin
    needs = '0; sb = '0;
    for (int e = 0; e < FLOG_DEPTH; e++) begin
      needs[e] = e_v[e] && (e_row[e] < 10'(ROWS));
      for (int k = 0; k < SPARE_ROWS; k++)
        if (e_v[e] && e_row[e] == 10'(ROWS + k)) sb[k] = 1'b1;
    end
    good = {~sb[1], ~sb[0]};
  end

  // ---- candidate evaluation
  logic            cand_ok, cand_fit;
  logic [3:0]      rows_used, io_cnt, cost;
  logic [PIO-1:0]  left;

  always_comb begin
    cand_ok = 1'b0;
    if (a == 4'd8 && b == 4'd8) cand_ok = 1'b1;
    else if (a < 4'd8 && b == 4'd8) cand_ok = needs[a[2:0]];
    else if (a < b && b < 4'd8) cand_ok = needs[a[2:0]] && needs[b[2:0]];
    rows_used = (a < 4'd8 ? 4'd1 : 4'd0) + (b < 4'd8 ? 4'd1 : 4'd0);
    left = '0;
    for (int e = 0; e < FLOG_DEPTH; e++)
      if (needs[e] && e != int'(a) && e != int'(b)) left |= e_mask[e];
    io_cnt = '0;
    for (int j = 0; j < PIO; j++) io_cnt = io_cnt + 4'(left[j] && io_cnt < 4'd8);
    cost = rows_used + io_cnt;
    cand_fit = cand_ok && (rows_used <= 4'(good[0]) + 4'(good[1])) && (io_cnt <= 4'(SPARE_IOS));
  end

  // ---- programming word for the winning candidate
  logic [9:0]  rowA, rowB;
  logic [37:0] sig;
  logic        s_first_is1;
  always_comb begin
    int nf;
    logic [6:0] f1, f2;
    logic       v1, v2;
    rowA = '0; rowB = '0;
    if (best_a < 4'd8) rowA = e_row[best_a[2:0]];
    if (best_b < 4'd8) rowB = e_row[best_b[2:0]];
    // first good spare takes row A, the other (if any) takes row B
    s_first_is1 = sb[0];
    nf = 0; f1 = '0; f2 = '0; v1 = 1'b0; v2 = 1'b0;
    for (int j = 0; j < PIO; j++)
      if (best_left[j]) begin
        if (nf == 0) begin f1 = 7'(j); v1 = 1'b1; end
        if (nf == 1) begin f2 = 7'(j); v2 = 1'b1; end
        nf++;
      end
    sig = '0;
    sig[37:36] = sb;
    sig[35:28] = {v2, f2};
    sig[27:20] = {v1, f1};
    if (best_a < 4'd8) begin
      if (!s_first_is1) sig[9:0]   = {1'b1, rowA[8:0]};
      else              sig[19:10] = {1'b1, rowA[8:0]};
    end
    if (best_b < 4'd8) begin
      if (!s_first_is1) sig[19:10] = {1'b1, rowB[8:0]};
      else              sig[9:0]   = {1'b1, rowB[8:0]};
    end
  end

  assign busy = (st != B_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= B_IDLE; a <= '0; b <= '0; best_cost <= 4'hF; best_a <= 4'd8; best_b <= 4'd8;
      best_left <= '0; done <= 1'b0; ok <= 1'b0; fail <= 1'b0; prog_en <= 1'b0; prog_sig <= '0;
    end else begin
      done <= 1'b0; prog_en <= 1'b0;
      case (st)
        B_IDLE: if (start) begin
          st <= B_ITER; a <= 4'd0; b <= 4'd1; best_cost <= 4'hF; best_a <= 4'd8; best_b <= 4'd8;
          best_left <= '0; ok <= 1'b0; fail <= 1'b0;
        end
        B_ITER: begin
          if (cand_fit && cost < best_cost) begin
            best_cost <= cost; best_a <= a; best_b <= b; best_left <= left;
          end
          if (a == 4'd8) st <= B_PROG;           // (8,8) is the last candidate
          else if (b == 4'd8) begin a <= a + 4'd1; b <= a + 4'd1; end
          else b <= b + 4'd1;
        end
        B_PROG: begin
          st <= B_IDLE; done <= 1'b1;
          if (best_cost != 4'hF && !ovf) begin
            ok <= 1'b1; prog_en <= 1'b1; prog_sig <= sig;
          end else begin
            fail <= 1'b1;
            prog_en <= 1'b1;                      // still export which spares are bad
            prog_sig <= {sb, 36'h0};
          end
        end
        default: st <= B_IDLE;
      endcase
    end
  end
endmodule
