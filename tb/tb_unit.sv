// Unit-level checks: sg_ecc (exhaustive single, sampled double), sg_remap (all IO pairs,
// row CAM), sg_bira (random fault maps vs. an independent brute-force allocator).
`timescale 1ns/1ps
module tb_unit;
  import sg_pkg::*;
  import sg_ecc_ref_pkg::*;

  int errors = 0;
  task automatic err(input string m);
    errors++; if (errors < 20) $display("ERROR: %s", m);
  endtask

  // ------------------------------------------------------------------ ECC
  logic [63:0] enc_d; logic [71:0] enc_cw, dec_cw, dec_fix; logic [63:0] dec_d; logic dec_ce, dec_ue;
  sg_ecc u_ecc (.enc_data(enc_d), .enc_cw(enc_cw), .dec_cw(dec_cw), .dec_data(dec_d),
                .dec_fix(dec_fix), .dec_ce(dec_ce), .dec_ue(dec_ue));

  task automatic test_ecc();
    logic [63:0] d; logic [71:0] cw;
    int n1 = 0, n2 = 0;
    for (int t = 0; t < 200; t++) begin
      d = {$urandom, $urandom};
      enc_d = d; #1;
      if (enc_cw !== ref_encode(d)) err("ecc: encoder differs from reference model");
      cw = enc_cw;
      dec_cw = cw; #1;
      if (dec_ce || dec_ue || dec_d !== d) err("ecc: clean word flagged");
      for (int i = 0; i < 72; i++) begin
        dec_cw = cw ^ (72'h1 << i); #1; n1++;
        if (!dec_ce || dec_ue || dec_d !== d || dec_fix !== cw) err($sformatf("ecc: single error bit %0d not corrected", i));
      end
      for (int k = 0; k < 200; k++) begin
        int i, j;
        i = $urandom_range(71); j = $urandom_range(71);
        if (i == j) continue;
        dec_cw = cw ^ (72'h1 << i) ^ (72'h1 << j); #1; n2++;
        if (dec_ce || !dec_ue) err($sformatf("ecc: double error (%0d,%0d) not detected", i, j));
      end
    end
    $display("ECC  : %0d single-error, %0d double-error decodes checked", n1, n2);
  endtask

  // ------------------------------------------------------------------ remap
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic        rm_clr, rm_load, rm_set, rm_setk;
  logic [37:0] rm_lsig, rm_sig;
  logic [8:0]  rm_setrow, rm_lrow;
  logic [9:0]  rm_prow;
  logic        rm_hit;
  logic [71:0] rm_wd72, rm_rd72;
  logic [73:0] rm_wd74;
  logic [1:0]  rm_ev, rm_sb;
  logic [8:0]  rm_r0, rm_r1;
  sg_remap u_rm (.clk(clk), .rst_n(rst_n), .clr(rm_clr), .load_en(rm_load), .load_sig(rm_lsig),
                 .set_en(rm_set), .set_k(rm_setk), .set_row(rm_setrow), .sig(rm_sig),
                 .ent_v(rm_ev), .ent_row0(rm_r0), .ent_row1(rm_r1), .spare_bad(rm_sb),
                 .lrow(rm_lrow), .prow(rm_prow), .rhit(rm_hit),
                 .wd72(rm_wd72), .wd74(rm_wd74), .rd74(rm_wd74), .rd72(rm_rd72));

  task automatic load_sig(input logic [37:0] s);
    @(negedge clk); rm_load = 1; rm_lsig = s; @(negedge clk); rm_load = 0;
  endtask

  task automatic test_remap();
    int pairs = 0;
    logic [71:0] w;
    rm_clr = 0; rm_load = 0; rm_set = 0; rm_setk = 0; rm_setrow = 0; rm_lsig = 0; rm_lrow = 0; rm_wd72 = 0;
    #20 rst_n = 1;
    // single bad IO and no bad IO
    for (int f1 = 0; f1 < 74; f1++) begin
      load_sig({2'b00, 8'h00, 1'b1, 7'(f1), 20'h0});
      w = {$urandom, $urandom, $urandom}; rm_wd72 = w; #1;
      if (rm_rd72 !== w) err($sformatf("remap: roundtrip failed, single bad IO %0d", f1));
      if (rm_wd74[f1] !== 1'b0) err("remap: bad IO position was written");
    end
    // every (f1,f2) pair
    for (int f1 = 0; f1 < 74; f1++)
      for (int f2 = f1 + 1; f2 < 74; f2++) begin
        load_sig({2'b00, 1'b1, 7'(f2), 1'b1, 7'(f1), 20'h0});
        w = {$urandom, $urandom, $urandom}; rm_wd72 = w; #1; pairs++;
        if (rm_rd72 !== w) err($sformatf("remap: roundtrip failed for (%0d,%0d)", f1, f2));
        if (rm_wd74[f1] !== 1'b0 || rm_wd74[f2] !== 1'b0) err("remap: bad IO position was written");
        // spec equation for logical->physical
        for (int i = 0; i < 72; i += 7) begin
          int m;
          m = i + (i >= f1) + (i >= f2 - 1);
          if (rm_wd74[m] !== w[i]) err($sformatf("remap: logical %0d not at physical %0d for (%0d,%0d)", i, m, f1, f2));
        end
      end
    // row CAM
    load_sig({2'b00, 8'h00, 8'h00, 1'b1, 9'd37, 1'b1, 9'd400});
    for (int r = 0; r < 512; r++) begin
      rm_lrow = r; #1;
      if (r == 400 && rm_prow !== 10'd512) err("remap: row 400 should hit spare 0");
      else if (r == 37 && rm_prow !== 10'd513) err("remap: row 37 should hit spare 1");
      else if (r != 400 && r != 37 && rm_prow !== r) err("remap: unmapped row moved");
    end
    $display("REMAP: %0d IO pairs + 74 singles + row CAM checked", pairs);
  endtask

  // ------------------------------------------------------------------ BIRA
  logic bira_start, bira_busy, bira_done, bira_ok, bira_fail, bira_prog;
  logic [37:0] bira_sig;
  logic [FLOG_DEPTH-1:0] e_v;
  logic [FLOG_DEPTH-1:0][9:0] e_row;
  logic [FLOG_DEPTH-1:0][PIO-1:0] e_mask;
  logic ovf;
  sg_bira u_bira (.clk(clk), .rst_n(rst_n), .start(bira_start), .e_v(e_v), .e_row(e_row), .e_mask(e_mask),
                  .ovf(ovf), .busy(bira_busy), .done(bira_done), .ok(bira_ok), .fail(bira_fail),
                  .prog_en(bira_prog), .prog_sig(bira_sig));

  // independent brute force: returns min spare count, or -1 if unrepairable
  function automatic int brute(input logic [FLOG_DEPTH-1:0] v, input logic [FLOG_DEPTH-1:0][9:0] row,
                               input logic [FLOG_DEPTH-1:0][PIO-1:0] mask);
    int good, best, cost, nrow, nio;
    logic [PIO-1:0] left;
    bit sb0, sb1;
    sb0 = 0; sb1 = 0;
    for (int e = 0; e < FLOG_DEPTH; e++) begin
      if (v[e] && row[e] == 512) sb0 = 1;
      if (v[e] && row[e] == 513) sb1 = 1;
    end
    good = (!sb0) + (!sb1);
    best = -1;
    // choose any subset of the 8 entries as spare-row users (bitmask), at most 2 of them
    for (int s = 0; s < 256; s++) begin
      nrow = 0; left = '0;
      for (int e = 0; e < FLOG_DEPTH; e++) begin
        if (!(v[e] && row[e] < 512)) continue;
        if (s[e]) nrow++; else left |= mask[e];
      end
      for (int e = 0; e < FLOG_DEPTH; e++) if (s[e] && !(v[e] && row[e] < 512)) nrow = 99;
      nio = $countones(left);
      if (nrow <= 2 && nrow <= good && nio <= 2) begin
        cost = nrow + nio;
        if (best < 0 || cost < best) best = cost;
      end
    end
    return best;
  endfunction

  task automatic test_bira();
    int ok_cnt = 0, fail_cnt = 0, edge_cnt = 0;
    for (int t = 0; t < 4000; t++) begin
      int nrows, bestc, got;
      logic [37:0] s;
      bit covered;
      e_v = '0; e_row = '0; e_mask = '0; ovf = 0;
      nrows = $urandom_range(0, 6);
      for (int k = 0; k < nrows; k++) begin
        int nb;
        e_v[k] = 1;
        e_row[k] = ($urandom_range(0, 19) == 0) ? 10'(512 + $urandom_range(0, 1)) : 10'($urandom_range(0, 511));
        nb = $urandom_range(1, 3);
        // bias toward shared IOs so column repair and must-repair cases show up
        for (int b = 0; b < nb; b++) e_mask[k][($urandom_range(0, 1)) ? $urandom_range(0, 3) * 20 : $urandom_range(0, 73)] = 1;
      end
      // avoid duplicate rows (the logger merges them)
      for (int a = 0; a < FLOG_DEPTH; a++)
        for (int b = a + 1; b < FLOG_DEPTH; b++)
          if (e_v[a] && e_v[b] && e_row[a] == e_row[b]) e_v[b] = 0;
      bestc = brute(e_v, e_row, e_mask);
      @(negedge clk); bira_start = 1; @(negedge clk); bira_start = 0;
      s = 'x;
      fork begin
        forever begin @(posedge clk); if (bira_prog) begin s = bira_sig; end if (bira_done) break; end
      end join
      @(posedge clk);
      if (bestc < 0) begin
        fail_cnt++;
        if (!bira_fail && bira_ok) err($sformatf("bira: reported ok but brute force says unrepairable (t=%0d)", t));
      end else begin
        ok_cnt++;
        if (!bira_ok) err($sformatf("bira: reported fail but brute force found cost %0d (t=%0d)", bestc, t));
        else begin
          // programmed solution must cover every failing cell and use the optimal number of spares
          got = s[9] + s[19] + s[27] + s[35];
          if (got != bestc) err($sformatf("bira: used %0d spares, optimum is %0d (t=%0d)", got, bestc, t));
          for (int e = 0; e < FLOG_DEPTH; e++) if (e_v[e] && e_row[e] < 512) begin
            covered = (s[9] && s[8:0] == e_row[e][8:0]) || (s[19] && s[18:10] == e_row[e][8:0]);
            if (!covered)
              for (int j = 0; j < PIO; j++)
                if (e_mask[e][j] && !((s[27] && s[26:20] == j) || (s[35] && s[34:28] == j)))
                  err($sformatf("bira: cell (row %0d, IO %0d) left uncovered (t=%0d)", e_row[e], j, t));
          end
          if (s[37:36] !== {(|(e_v & (e_row == 513))), (|(e_v & (e_row == 512)))} && 0) err("bira: spare_bad");
        end
      end
      if (bestc == 3 || bestc == 4) edge_cnt++;
    end
    $display("BIRA : %0d repairable, %0d unrepairable maps vs brute force (%0d at the spare limit)", ok_cnt, fail_cnt, edge_cnt);
  endtask

  initial begin
    bira_start = 0; e_v = '0; e_row = '0; e_mask = '0; ovf = 0;
    rm_clr = 0; rm_load = 0; rm_set = 0; rm_setk = 0; rm_setrow = 0; rm_lsig = 0; rm_lrow = 0; rm_wd72 = 0;
    test_ecc();
    test_remap();
    test_bira();
    if (errors == 0) $display("TB_UNIT PASS"); else $display("TB_UNIT FAIL (%0d errors)", errors);
    $finish;
  end
endmodule
