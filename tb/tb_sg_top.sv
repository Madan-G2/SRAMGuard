// System-level testbench for SRAMGuard (directed + constrained-random, no UVM).
//   golden memory scoreboard (CHK-1, CHK-2), stall monitor (CHK-6),
//   transparency check after every online window (CHK-5), fault injection through the
//   SRAM model API, APB register access.
// Select tests with +T=<name>[,<name>...]; default runs the quick regression.
`timescale 1ns/1ps
module tb_sg_top;
  import sg_pkg::*;
  import sg_ecc_ref_pkg::*;

  // ------------------------------------------------------------------ DUT
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic        req_valid = 0, req_ready, req_we = 0;
  logic [11:0] req_addr = 0;
  logic [63:0] req_wdata = 0;
  logic [7:0]  req_be = 8'hFF;
  logic        rsp_valid, rsp_ce, rsp_ue;
  logic [63:0] rsp_rdata;
  logic        psel = 0, penable = 0, pwrite = 0;
  logic [7:0]  paddr = 0;
  logic [31:0] pwdata = 0, prdata;
  logic        pready, pslverr;
  logic        fuse_vld = 0;
  logic [37:0] fuse_sig = 0;
  logic [37:0] repair_sig_o;
  logic        irq_ue, irq_hard, irq_repair, irq_done;

  sg_top dut (.*);

  // ------------------------------------------------------------------ bookkeeping
  int errors = 0;
  int cycle = 0;
  always @(posedge clk) cycle++;

  task automatic err(input string m);
    errors++;
    if (errors <= 25) $display("[%0t] ERROR: %s", $time, m);
  endtask

  // ------------------------------------------------------------------ APB
  task automatic apb_wr(input [7:0] a, input [31:0] d);
    @(posedge clk); psel <= 1; pwrite <= 1; paddr <= a; pwdata <= d; penable <= 0;
    @(posedge clk); penable <= 1;
    @(posedge clk); psel <= 0; penable <= 0; pwrite <= 0;
  endtask

  task automatic apb_rd(input [7:0] a, output [31:0] d);
    @(posedge clk); psel <= 1; pwrite <= 0; paddr <= a; penable <= 0;
    @(posedge clk); penable <= 1;
    @(posedge clk); d = prdata; psel <= 0; penable <= 0;
  endtask

  function automatic int cnt_addr(input int id); return 8'h80 + 4 * id; endfunction

  task automatic read_cnt(input int id, output int v);
    logic [31:0] d;
    apb_rd(8'(cnt_addr(id)), d); v = int'(d);
  endtask

  // ------------------------------------------------------------------ golden memory + scoreboard
  logic [63:0] gold [0:DEPTH-1];
  typedef struct { bit we; bit [11:0] addr; bit [63:0] exp; } exp_t;
  exp_t expq [$];
  bit   sb_en = 1;
  bit   ue_ok = 0;         // allow rsp_ue (tests that create genuinely uncorrectable words)
  int   n_rd = 0, n_wr = 0, n_ce = 0, n_ue = 0;
  bit   expect_no_ce = 0;  // power-on repaired memory must not need ECC

  function automatic [63:0] merge(input [63:0] o, input [63:0] n, input [7:0] be);
    logic [63:0] r;
    for (int i = 0; i < 8; i++) r[8*i +: 8] = be[i] ? n[8*i +: 8] : o[8*i +: 8];
    return r;
  endfunction

  always @(posedge clk) if (rst_n && sb_en) begin
    exp_t e;
    if (req_valid && req_ready) begin
      e.we = req_we; e.addr = req_addr;
      if (req_we) begin gold[req_addr] = merge(gold[req_addr], req_wdata, req_be); n_wr++; end
      else begin e.exp = gold[req_addr]; n_rd++; end
      expq.push_back(e);
    end
    if (rsp_valid) begin
      if (expq.size() == 0) err("response without outstanding request");
      else begin
        e = expq.pop_front();
        if (rsp_ce) n_ce++;
        if (rsp_ue) n_ue++;
        if (!e.we) begin
          if (rsp_ue) begin
            if (!ue_ok) err($sformatf("CHK-1: unexpected rsp_ue at %0h", e.addr));
          end else begin
            if (rsp_rdata !== e.exp)
              err($sformatf("CHK-1/2: read %0h returned %0h, golden %0h (ce=%0b)", e.addr, rsp_rdata, e.exp, rsp_ce));
            if (!rsp_ce && !rsp_ue && rsp_rdata !== e.exp) err("CHK-2: silent corruption");
          end
          if (expect_no_ce && rsp_ce) err($sformatf("CE on repaired memory at %0h", e.addr));
        end
      end
    end
  end

  // optional trace (+TRACE): every accepted request / response with window state
  bit trace = 0;
  initial trace = $test$plusargs("TRACE");
  always @(posedge clk) if (trace && rst_n && dut.fn_en) begin
    if (req_valid && req_ready)
      $display("%0d REQ %s a=%03h be=%02h d=%016h | win st=%0d base=%0d open=%0b fvalid=%0b fpend=%0b pol=%0b",
               cycle, req_we ? "WR" : "RD", req_addr, req_be, req_wdata, dut.u_win.st, dut.win_base, dut.win_open,
               dut.f_valid, dut.f_pend, dut.f_pol);
    if (rsp_valid) $display("%0d RSP d=%016h ce=%0b ue=%0b", cycle, rsp_rdata, rsp_ce, rsp_ue);
  end

  // ------------------------------------------------------------------ stall monitor (CHK-6)
  int srun = 0, max_srun = 0;
  int stall_hist [0:8];
  always @(posedge clk) if (rst_n && dut.fn_en) begin
    if (req_valid && !req_ready) srun++;
    else begin
      if (srun > max_srun) max_srun = srun;
      if (srun <= 8) stall_hist[srun]++;
      srun = 0;
    end
    if (srun > MAX_STALL) begin
      err($sformatf("CHK-6: request stalled %0d cycles (MAX_STALL=%0d)", srun, MAX_STALL));
      srun = 0;
    end
  end

  // ------------------------------------------------------------------ traffic generator
  bit        tr_en = 0;
  int        tr_idle = 50;       // % of cycles without a request
  int        tr_wr = 40;         // % writes
  int        tr_part = 30;       // % of writes that are partial
  int        tr_lo = 0, tr_hi = DEPTH - 1;
  bit        tr_follow_win = 0;  // aim at the rows of the window under test
  int        tr_acc = 0;

  bit        tr_was_en = 0;

  // The generator owns the request port only while tr_en (or while winding down); directed
  // fwrite/fread must run with it off.
  always @(posedge clk) if (rst_n) begin
    if (tr_en) begin
      tr_was_en <= 1;
      if (!(req_valid && !req_ready)) begin
        if ($urandom_range(99) >= tr_idle) begin
          logic [11:0] a;
          if (tr_follow_win && dut.win_open && $urandom_range(1) == 0)
            a = {dut.win_base + 9'($urandom_range(0, 1)), 3'($urandom_range(0, 7))};
          else a = 12'($urandom_range(tr_lo, tr_hi));
          req_valid <= 1; req_addr <= a;
          req_we <= ($urandom_range(99) < tr_wr);
          req_wdata <= {$urandom, $urandom};
          req_be <= ($urandom_range(99) < tr_part) ? 8'($urandom_range(1, 254)) : 8'hFF;
          tr_acc++;
        end else req_valid <= 0;
      end
    end else if (tr_was_en) begin
      // finish the request in flight, then release the port
      if (!(req_valid && !req_ready)) begin req_valid <= 0; tr_was_en <= 0; end
    end
  end

  task automatic traffic_off();
    tr_en = 0;
    while (tr_was_en) @(posedge clk);
    repeat (10) @(posedge clk);       // let responses drain
  endtask

  // directed accesses (traffic must be off)
  task automatic fwrite(input [11:0] a, input [63:0] d, input [7:0] be = 8'hFF);
    @(posedge clk); req_valid <= 1; req_we <= 1; req_addr <= a; req_wdata <= d; req_be <= be;
    @(posedge clk); while (!req_ready) @(posedge clk);
    req_valid <= 0;
  endtask

  task automatic fread(input [11:0] a);
    @(posedge clk); req_valid <= 1; req_we <= 0; req_addr <= a; req_be <= 8'hFF;
    @(posedge clk); while (!req_ready) @(posedge clk);
    req_valid <= 0;
  endtask

  // ------------------------------------------------------------------ backdoor view of the array
  // logical word as stored in the array, IO shift undone with the repair signature (independent code)
  function automatic logic [71:0] bd_logical(input int a);
    logic [37:0] s;
    logic [9:0]  prow;
    logic [73:0] p;
    logic [71:0] w;
    int f1, f2, v1, v2, row, m;
    s = dut.u_remap.sig;
    row = a >> 3;
    prow = row;
    if (s[9]  && s[8:0]   == row) prow = 512;
    else if (s[19] && s[18:10] == row) prow = 513;
    p = dut.u_sram.bd_read(prow, a & 7);
    v1 = s[27]; f1 = s[26:20]; v2 = s[35]; f2 = s[34:28];
    for (int i = 0; i < 72; i++) begin
      m = i + ((v1 != 0 && i >= f1) ? 1 : 0) + ((v2 != 0 && i >= f2 - 1) ? 1 : 0);
      w[i] = p[m];
    end
    return w;
  endfunction

  // decode with the reference model; returns 1 if the stored word still yields the golden data
  function automatic bit bd_ok(input int a);
    logic [71:0] cw;
    logic [7:0] syn;
    cw = bd_logical(a);
    syn = ref_syn(cw);
    if (syn == 0) return cw[63:0] === gold[a];
    for (int i = 0; i < 72; i++) begin
      logic [71:0] t;
      t = cw ^ (72'h1 << i);
      if (ref_syn(t) == 0) return t[63:0] === gold[a];
    end
    return 0;
  endfunction

  // number of words whose raw array content differs from the golden codeword
  function automatic int bd_raw_diff(input int lo, input int hi);
    int n = 0;
    for (int a = lo; a <= hi; a++) if (bd_logical(a) !== ref_encode(gold[a])) n++;
    return n;
  endfunction

  // CHK-5: after each online window, the 16 words of that window must read back as golden
  int win_checks = 0, win_check_fail = 0;
  bit chk5_en = 1;
  always @(negedge clk) if (rst_n && chk5_en && dut.ev_win_done && !dut.u_arb.rmw_busy && dut.mode == MODE_ONLINE) begin
    win_checks++;
    for (int w = 0; w < 16; w++) begin
      int a;
      a = {int'(dut.win_base), 3'b000} + w;
      if (!bd_ok(a) && !(dut.u_win.ue_seen)) begin
        win_check_fail++;
        err($sformatf("CHK-5: array word %0h differs from golden after window at row %0d", a, dut.win_base));
      end
    end
  end

  // ------------------------------------------------------------------ fault helpers
  localparam int F_SAF = 1, F_TF = 2, F_AF = 3, F_CFIN = 4, F_CFID = 5, F_CFST = 6, F_IRF = 7,
                 F_RDF = 8, F_DRDF = 9, F_WDF = 10, F_SOFT = 11;

  function automatic int add_fault(input int t, input int vr, vc, vb, input int ar = 0, ac = 0, ab = 0,
                                   input bit pol = 0, input bit val = 0, input longint act = 0);
    return dut.u_sram.inject(t, vr, vc, vb, ar, ac, ab, pol, val, act);
  endfunction

  // ------------------------------------------------------------------ reset / bring-up
  task automatic do_reset(input bit fv = 0, input logic [37:0] fs = '0);
    tr_en = 0; tr_was_en = 0;
    tr_idle = 50; tr_wr = 40; tr_part = 30; tr_lo = 0; tr_hi = DEPTH - 1; tr_follow_win = 0;   // per-test defaults
    rst_n = 0; req_valid = 0; fuse_vld = fv; fuse_sig = fs;
    expq.delete();
    for (int i = 0; i < DEPTH; i++) gold[i] = '0;
    repeat (6) @(posedge clk);
  endtask

  task automatic release_reset();
    @(negedge clk); rst_n = 1;
  endtask

  task automatic wait_online(input int timeout = 400000);
    int t = 0;
    while (!(dut.mode == MODE_ONLINE) && t < timeout) begin @(posedge clk); t++; end
    if (t >= timeout) err("timeout waiting for ONLINE");
    repeat (4) @(posedge clk);
  endtask

  task automatic wait_cycles(input int n); repeat (n) @(posedge clk); endtask

  // wait until n more windows have completed (or timeout)
  task automatic wait_windows(input int n, input int timeout = 2000000);
    int start, t = 0;
    start = dut.u_csr.cnt[C_WIN];
    while (dut.u_csr.cnt[C_WIN] < start + n && t < timeout) begin @(posedge clk); t++; end
    if (t >= timeout) err($sformatf("timeout waiting for %0d windows", n));
  endtask

  // ------------------------------------------------------------------ common checks
  // The array only equals the golden data when no window is between its first write and its
  // release (a window in March legitimately holds ref ^ pol).  Sample in a quiet window state.
  task automatic final_check_array(input string tag);
    int bad = 0, t = 0;
    @(negedge clk);
    while (!(dut.u_win.st inside {4'd0, 4'd1, 4'd2}) && t < 100000) begin @(negedge clk); t++; end
    for (int a = 0; a < DEPTH; a++) if (!bd_ok(a)) bad++;
    if (bad) err($sformatf("%s: %0d words do not hold their golden data in the array", tag, bad));
  endtask

  task automatic read_all_check(input string tag);
    // functional read of the whole memory, scoreboard compares with golden
    for (int a = 0; a < DEPTH; a++) fread(12'(a));
    repeat (8) @(posedge clk);
  endtask

  // ================================================================== tests
  // T1: power-on test of a fault-free array
  task automatic t_poweron_clean();
    int t0;
    $display("--- T1 power-on, fault-free");
    do_reset(); dut.u_sram.clear_faults(); release_reset();
    t0 = cycle;
    wait_online();
    $display("    RESET_TEST took %0d cycles (March C- on %0d words = %0d)", cycle - t0, PROWS * 8, 10 * PROWS * 8);
    if (dut.mbist_fail) err("MBIST_FAIL set on a clean array");
    if (!dut.repair_ok) err("REPAIR_OK not set on a clean array");
    if (dut.rm_sig[37:0] !== 38'h0) err($sformatf("remap not empty: %h", dut.rm_sig));
    if (dut.fl_v !== '0) err("fault log not empty on a clean array");
    for (int a = 0; a < DEPTH; a += 97) if (!bd_ok(a)) err($sformatf("zero fill missing at %0h", a));
    final_check_array("T1");
    // directed access
    for (int a = 0; a < 64; a++) fwrite(12'(a * 61), {$urandom, $urandom});
    for (int a = 0; a < 64; a++) fread(12'(a * 61));
    fwrite(12'h123, 64'hFFFF_FFFF_FFFF_FFFF);
    fwrite(12'h123, 64'h0000_0000_00AA_0000, 8'b0000_0100);
    fread(12'h123);
    repeat (6) @(posedge clk);
  endtask

  // T2: random traffic while the online engine runs, no faults
  task automatic t_online_traffic(input int idle_pct, input int ncycles);
    int w0, s0, c0;
    $display("--- T2 online traffic, idle=%0d%%, %0d cycles", idle_pct, ncycles);
    do_reset(); dut.u_sram.clear_faults(); release_reset(); wait_online();
    w0 = dut.u_csr.cnt[C_WIN]; s0 = dut.u_csr.cnt[C_SWEEP];
    tr_idle = idle_pct; tr_en = 1; tr_follow_win = 1;
    repeat (ncycles) @(posedge clk);
    traffic_off();
    $display("    requests %0d (rd %0d wr %0d) ce=%0d ue=%0d  windows +%0d sweeps +%0d  max stall %0d",
             n_rd + n_wr, n_rd, n_wr, n_ce, n_ue, dut.u_csr.cnt[C_WIN] - w0, dut.u_csr.cnt[C_SWEEP] - s0, max_srun);
    if (dut.u_csr.cnt[C_HARD] != 0) err("CHK-4: hard fault logged on a fault-free memory");
    if (dut.u_csr.cnt[C_TRANS] != 0) err("CHK-4: transient logged on a fault-free memory");
    if (dut.u_csr.cnt[C_WIN] == w0) err("no online window completed");
    wait_windows(1);
    tr_follow_win = 0;
  endtask


  // ------------------------------------------------------------------ CSR helpers
  logic [31:0] ctrl_val = 32'h1F;          // TEST SCRUB REPAIR ONLINE_REPAIR SEG_OVERLAP
  logic [31:0] alg_val  = 32'h0000_0411;   // online=C-, poweron=C-, collect
  task automatic set_ctrl(input logic [31:0] v); ctrl_val = v; apb_wr(8'h00, v); endtask
  task automatic set_alg(input int online, input int poweron, input int bg = 0, input int diag = 1);
    alg_val = (diag << 10) | (bg << 8) | (poweron << 4) | online;
    apb_wr(8'h04, alg_val);
  endtask

  task automatic run_maint(input int alg, input int bg = 0, input int diag = 1);
    int t = 0;
    set_alg(1, alg, bg, diag);
    apb_wr(8'h00, ctrl_val | 32'h40);
    while (dut.mode != MODE_MAINT && t < 200000) begin @(posedge clk); t++; end
    if (t >= 200000) err("MAINT never started");
    t = 0;
    while (dut.mode != MODE_ONLINE && t < 400000) begin @(posedge clk); t++; end
    if (t >= 400000) err("MAINT never finished");
    for (int i = 0; i < DEPTH; i++) gold[i] = '0;      // destructive test + zero fill
    expq.delete();
    repeat (4) @(posedge clk);
  endtask

  function automatic bit flog_has(input int row, input int bit_no);
    for (int e = 0; e < FLOG_DEPTH; e++)
      if (dut.fl_v[e] && dut.fl_row[e] == row && (bit_no < 0 || dut.fl_mask[e][bit_no])) return 1;
    return 0;
  endfunction

  function automatic int flog_n();
    int n = 0;
    for (int e = 0; e < FLOG_DEPTH; e++) if (dut.fl_v[e]) n++;
    return n;
  endfunction

  // ------------------------------------------------------------------ T3: power-on coverage per fault model
  localparam int NSUB = 19;
  string sub_name [NSUB] = '{"SAF0","SAF1","TFup","TFdn","AF","CFin-up","CFin-dn","CFid-u0","CFid-u1","CFid-d0","CFid-d1",
                             "CFst-00","CFst-01","CFst-10","CFst-11","IRF","RDF","DRDF","WDF"};
  string alg_name [4] = '{"MATS+","March C-","March LR","March SS"};

  // class index: 0 SAF 1 TF 2 AF 3 CFin 4 CFid 5 CFst 6 IRF 7 RDF 8 DRDF 9 WDF
  function automatic int sub_class(input int k);
    case (k)
      0, 1: return 0;  2, 3: return 1;  4: return 2;  5, 6: return 3;
      7, 8, 9, 10: return 4;  11, 12, 13, 14: return 5;
      15: return 6;  16: return 7;  17: return 8;  default: return 9;
    endcase
  endfunction

  // spec table 4.2: which algorithms are specified to cover a class (alg: 0 MATS+, 1 C-, 2 LR, 3 SS)
  function automatic bit spec_covers(input int cls, input int alg);
    case (cls)
      0, 2:       return 1;
      1, 3, 4, 5: return alg >= 1;
      6:          return alg == 1 || alg == 3;
      default:    return alg == 3;     // RDF, DRDF, WDF
    endcase
  endfunction

  int vr_l [4], vb_l [4], ar_l [4];

  task automatic inject_sub(input int k, input int slot, input int vr, input int vc, input int vb,
                            input int ar, input int ac, input int ab);
    case (k)
      0:  void'(add_fault(F_SAF, vr, vc, vb, .val(0)));
      1:  void'(add_fault(F_SAF, vr, vc, vb, .val(1)));
      2:  void'(add_fault(F_TF, vr, vc, vb, .pol(1)));
      3:  void'(add_fault(F_TF, vr, vc, vb, .pol(0)));
      4:  void'(add_fault(F_AF, vr, vc, vb, ar, ac, ab));
      5:  void'(add_fault(F_CFIN, vr, vc, vb, ar, ac, ab, .pol(1)));
      6:  void'(add_fault(F_CFIN, vr, vc, vb, ar, ac, ab, .pol(0)));
      7:  void'(add_fault(F_CFID, vr, vc, vb, ar, ac, ab, .pol(1), .val(0)));
      8:  void'(add_fault(F_CFID, vr, vc, vb, ar, ac, ab, .pol(1), .val(1)));
      9:  void'(add_fault(F_CFID, vr, vc, vb, ar, ac, ab, .pol(0), .val(0)));
      10: void'(add_fault(F_CFID, vr, vc, vb, ar, ac, ab, .pol(0), .val(1)));
      11: void'(add_fault(F_CFST, vr, vc, vb, ar, ac, ab, .pol(0), .val(0)));
      12: void'(add_fault(F_CFST, vr, vc, vb, ar, ac, ab, .pol(0), .val(1)));
      13: void'(add_fault(F_CFST, vr, vc, vb, ar, ac, ab, .pol(1), .val(0)));
      14: void'(add_fault(F_CFST, vr, vc, vb, ar, ac, ab, .pol(1), .val(1)));
      15: void'(add_fault(F_IRF, vr, vc, vb));
      16: void'(add_fault(F_RDF, vr, vc, vb));
      17: void'(add_fault(F_DRDF, vr, vc, vb));
      default: void'(add_fault(F_WDF, vr, vc, vb));
    endcase
  endtask

  int cov_hit [NSUB][4], cov_tot [NSUB][4];

  task automatic t_poweron_coverage(input int per_pair);
    int vr, vc, vb, ar, ac, ab, runs;
    $display("--- T3 power-on coverage per fault model and algorithm (%0d single faults each)", per_pair);
    do_reset(); dut.u_sram.clear_faults(); release_reset(); wait_online();
    runs = (per_pair + 3) / 4;
    for (int k = 0; k < NSUB; k++)
      for (int a = 0; a < 4; a++) begin
        for (int r = 0; r < runs; r++) begin
          int n;
          n = (r == runs - 1 && per_pair % 4 != 0) ? per_pair % 4 : 4;
          dut.u_sram.clear_faults();
          for (int f = 0; f < n; f++) begin
            // victims 100+ rows apart so independent faults cannot interact; aggressors elsewhere
            vr = f * 128 + $urandom_range(0, 100); if (r == 0 && f == 3) vr = 512 + $urandom_range(0, 1);
            vc = $urandom_range(0, 7); vb = $urandom_range(0, 73);
            ar = f * 128 + 110 + $urandom_range(0, 15); ac = $urandom_range(0, 7); ab = $urandom_range(0, 73);
            vr_l[f] = vr; vb_l[f] = vb; ar_l[f] = ar;
            inject_sub(k, f, vr, vc, vb, ar, ac, ab);
          end
          run_maint(a);
          for (int f = 0; f < n; f++) begin
            bit hit;
            hit = flog_has(vr_l[f], -1) || (k == 4 && flog_has(ar_l[f], -1));
            cov_tot[k][a]++; if (hit) cov_hit[k][a]++;
          end
        end
        if (spec_covers(sub_class(k), a) && cov_hit[k][a] != cov_tot[k][a])
          err($sformatf("REQ-SYS-2: %s not fully detected by %s (%0d/%0d)", sub_name[k], alg_name[a], cov_hit[k][a], cov_tot[k][a]));
      end
    dut.u_sram.clear_faults();
    $display("    detected / injected   (* = algorithm specified to cover it)");
    $display("    %-9s %12s %12s %12s %12s", "fault", alg_name[0], alg_name[1], alg_name[2], alg_name[3]);
    for (int k = 0; k < NSUB; k++)
      $display("    %-9s %9d/%-2d%s %9d/%-2d%s %9d/%-2d%s %9d/%-2d%s", sub_name[k],
               cov_hit[k][0], cov_tot[k][0], spec_covers(sub_class(k), 0) ? "*" : " ",
               cov_hit[k][1], cov_tot[k][1], spec_covers(sub_class(k), 1) ? "*" : " ",
               cov_hit[k][2], cov_tot[k][2], spec_covers(sub_class(k), 2) ? "*" : " ",
               cov_hit[k][3], cov_tot[k][3], spec_covers(sub_class(k), 3) ? "*" : " ");
  endtask

  // no false alarms for every algorithm x background on a clean array (CHK-4)
  task automatic t_poweron_nofalse();
    $display("--- T3b no false alarms: all algorithms x backgrounds, clean array");
    do_reset(); dut.u_sram.clear_faults(); release_reset(); wait_online();
    for (int a = 0; a < 4; a++)
      for (int bg = 0; bg < 4; bg++) begin
        run_maint(a, bg);
        if (flog_n() != 0 || dut.mbist_fail) err($sformatf("CHK-4: false alarm, alg %0d bg %0d", a, bg));
      end
  endtask

  // ------------------------------------------------------------------ T4: power-on repair
  task automatic fill_and_check_all(input bit no_ce);
    expect_no_ce = no_ce;
    for (int a = 0; a < DEPTH; a++) fwrite(12'(a), {$urandom, $urandom});
    for (int a = 0; a < DEPTH; a++) fread(12'(a));
    repeat (8) @(posedge clk);
    expect_no_ce = 0;
  endtask

  task automatic repair_case(input string name, input int expect_ok, input int exp_rows, input int exp_ios);
    int nrow, nio;
    logic [37:0] s;
    s = dut.rm_sig;
    nrow = s[9] + s[19]; nio = s[27] + s[35];
    $display("    %-34s ok=%0b fail=%0b rows=%0d ios=%0d sig=%010h", name, dut.repair_ok, dut.repair_fail, nrow, nio, s);
    if (expect_ok && !dut.repair_ok) err({name, ": REPAIR_OK expected"});
    if (!expect_ok && !dut.repair_fail) err({name, ": REPAIR_FAIL expected"});
    if (expect_ok && (nrow != exp_rows || nio != exp_ios))
      err($sformatf("%s: expected %0d row(s) + %0d IO(s), got %0d + %0d", name, exp_rows, exp_ios, nrow, nio));
    if (dut.mode != MODE_ONLINE) err("not ONLINE after RESET_TEST");
    fill_and_check_all(expect_ok);
    if (expect_ok && dut.u_csr.cnt[C_CE] != 0) err($sformatf("%s: ECC corrections on a repaired memory", name));
  endtask

  task automatic t_poweron_repair();
    int r1, r2, r3, r4;
    $display("--- T4 power-on repair (BIRA + remap), memory re-verified end to end");
    // a) two bad rows
    do_reset(); dut.u_sram.clear_faults();
    void'(add_fault(F_SAF, 40, 3, 17, .val(1))); void'(add_fault(F_SAF, 301, 6, 60, .val(0)));
    release_reset(); wait_online();
    repair_case("two bad rows", 1, 2, 0);
    if (!flog_has(40, 17) || !flog_has(301, 60)) err("fault log lacks the injected faults");
    // b) one bad IO across many rows
    do_reset(); dut.u_sram.clear_faults();
    for (int i = 0; i < 4; i++) void'(add_fault(F_SAF, 10 + i * 100, i, 22, .val(i & 1)));
    release_reset(); wait_online();
    repair_case("bad IO in 4 rows", 1, 0, 1);
    if (dut.rm_sig[27] !== 1'b1 || dut.rm_sig[26:20] !== 7'd22) err("spare IO should replace IO 22");
    // c) mixed: bad IO in 3 rows + one extra row
    do_reset(); dut.u_sram.clear_faults();
    for (int i = 0; i < 3; i++) void'(add_fault(F_SAF, 20 + i * 90, 1, 5, .val(1)));
    void'(add_fault(F_SAF, 450, 2, 50, .val(0)));
    release_reset(); wait_online();
    repair_case("bad IO x3 rows + 1 row", 1, 1, 1);
    // d) unrepairable: five rows, five different IOs
    do_reset(); dut.u_sram.clear_faults();
    for (int i = 0; i < 5; i++) void'(add_fault(F_SAF, 30 + i * 70, 0, 3 * i + 1, .val(1)));
    release_reset(); wait_online();
    repair_case("unrepairable", 0, 0, 0);
    // e) a failed spare row is excluded; the other one is used
    do_reset(); dut.u_sram.clear_faults();
    void'(add_fault(F_SAF, 512, 4, 30, .val(1))); void'(add_fault(F_SAF, 77, 2, 9, .val(0)));
    release_reset(); wait_online();
    repair_case("spare row 0 bad", 1, 1, 0);
    if (dut.rm_sig[9] !== 1'b0 || dut.rm_sig[19] !== 1'b1) err("bad spare 0 used, or spare 1 not used");
    // f) two bad rows but one spare row is bad: one row + one IO
    do_reset(); dut.u_sram.clear_faults();
    void'(add_fault(F_SAF, 513, 4, 30, .val(1)));
    void'(add_fault(F_SAF, 90, 2, 9, .val(0))); void'(add_fault(F_SAF, 200, 3, 9, .val(1)));
    release_reset(); wait_online();
    repair_case("row + IO sharing, one spare bad", 1, 0, 1);
    // g) both spare IOs used, one of them the spare position itself
    do_reset(); dut.u_sram.clear_faults();
    for (int i = 0; i < 3; i++) void'(add_fault(F_SAF, 15 + i * 150, 1, 4, .val(1)));
    for (int i = 0; i < 3; i++) void'(add_fault(F_SAF, 25 + i * 150, 5, 73, .val(0)));
    release_reset(); wait_online();
    repair_case("two bad IOs (one is a spare IO)", 1, 0, 2);
  endtask

  // ------------------------------------------------------------------ T5: saved repair signature
  task automatic t_fuse_reload();
    logic [37:0] sig;
    int t0;
    $display("--- T5 repair signature export / reload");
    do_reset(); dut.u_sram.clear_faults();
    void'(add_fault(F_SAF, 61, 3, 12, .val(1))); void'(add_fault(F_SAF, 222, 1, 40, .val(0)));
    release_reset(); wait_online();
    sig = repair_sig_o;
    if (sig[9] + sig[19] != 2) err("expected two rows in signature");
    do_reset(1, sig); release_reset();
    t0 = cycle; wait_online();
    $display("    reload boot took %0d cycles (no destructive test)", cycle - t0);
    if (cycle - t0 > 6000) err("fuse reload still ran the destructive test");
    if (dut.rm_sig !== sig) err("reloaded signature differs");
    fill_and_check_all(1);
    // CSR path: export through APB, reload through APB
    begin
      logic [31:0] w0, w1;
      apb_rd(8'h18, w0); apb_rd(8'h1C, w1);
      if ({w1[5:0], w0} !== sig) err("CSR REPAIR_SIG read does not match export");
    end
  endtask

  // ------------------------------------------------------------------ T6: online hard fault -> detect -> repair
  int chk7_row = -1;
  int chk7_viol = 0;
  always @(posedge clk) if (chk7_row >= 0 && dut.u_sram.en && dut.u_sram.row == chk7_row) chk7_viol++;

  task automatic t_online_hard(input int idle_pct, input bit with_traffic_on_row);
    int vr, w0, hard0, rep0, t;
    int sw0;
    $display("--- T6 online hard fault, idle=%0d%%, traffic on faulty row=%0b", idle_pct, with_traffic_on_row);
    do_reset(); dut.u_sram.clear_faults(); release_reset(); wait_online();
    // fill with data so the test runs on live content
    for (int a = 0; a < DEPTH; a++) fwrite(12'(a), {$urandom, $urandom});
    vr = $urandom_range(20, 480);
    hard0 = dut.u_csr.cnt[C_HARD]; rep0 = dut.u_csr.cnt[C_REPAIR]; sw0 = dut.u_csr.cnt[C_SWEEP];
    void'(add_fault(F_SAF, vr, 2, 33, .val(1), .act(dut.u_sram.now_cycle() + 50)));
    tr_idle = idle_pct; tr_en = 1; tr_follow_win = 0;
    if (with_traffic_on_row) begin tr_lo = vr * 8; tr_hi = vr * 8 + 7; tr_wr = 60; end
    t = 0;
    while (dut.u_csr.cnt[C_REPAIR] == rep0 && t < 1500000) begin @(posedge clk); t++; end
    if (t >= 1500000) err("online repair never completed");
    $display("    fault in row %0d: repaired after %0d cycles (%0d windows, %0d sweeps)", vr, t, dut.u_csr.cnt[C_WIN], dut.u_csr.cnt[C_SWEEP] - sw0);
    if (t > 0 && dut.u_csr.cnt[C_SWEEP] - sw0 > 1) err("REQ-SYS-4: not detected within one sweep");
    if (!flog_has(vr, 33)) err("hard fault not in the fault log");
    if (dut.rm_v == 0 || !((dut.rm_v[0] && dut.rm_row0 == vr) || (dut.rm_v[1] && dut.rm_row1 == vr))) err("row not remapped");
    if (dut.u_csr.cnt[C_HARD] == hard0) err("hard-fault counter did not move");
    if (!irq_hard || !irq_repair) err("interrupts missing");
    chk7_row = vr; chk7_viol = 0;
    tr_lo = 0; tr_hi = DEPTH - 1; tr_wr = 40;
    wait_cycles(30000);
    traffic_off();
    chk7_row = -1;
    if (chk7_viol != 0) err($sformatf("CHK-7: faulty row %0d accessed %0d times after repair", vr, chk7_viol));
    // after the switch, hits on the repaired row must read back clean data
    for (int c = 0; c < 8; c++) fread(12'(vr * 8 + c));
    repeat (6) @(posedge clk);
    wait_windows(2);
    final_check_array("T6");
  endtask

  // ------------------------------------------------------------------ T7: soft errors and classification (CHK-8)
  task automatic t_soft_errors();
    int tr0, hard0;
    $display("--- T7 soft errors: scrubbing, classification, double flips");
    do_reset(); dut.u_sram.clear_faults(); release_reset(); wait_online();
    for (int a = 0; a < DEPTH; a++) fwrite(12'(a), {$urandom, $urandom});
    hard0 = dut.u_csr.cnt[C_HARD];
    // single flips far from the window, spread over the array
    begin
      bit used [int];                       // one flip per word: two in a word would be a real UE
      int r, c, n = 0;
      while (n < 24) begin
        r = $urandom_range(300, 510); c = $urandom_range(0, 7);
        if (used.exists(r * 8 + c)) continue;
        used[r * 8 + c] = 1; n++;
        void'(add_fault(F_SOFT, r, c, $urandom_range(0, 71), .act(dut.u_sram.now_cycle() + 100)));
      end
    end
    tr_idle = 80; tr_en = 1; tr_follow_win = 1; tr_lo = 0; tr_hi = DEPTH - 1;
    wait_windows(520, 3000000);
    traffic_off();
    if (dut.u_csr.cnt[C_HARD] != hard0) err("CHK-8: soft error classified as hard fault");
    if (dut.fl_v != '0) err("CHK-8: soft error reached the fault log");
    $display("    ce=%0d (scrub corrected) transient=%0d hard=%0d", dut.u_csr.cnt[C_CE], dut.u_csr.cnt[C_TRANS], dut.u_csr.cnt[C_HARD] - hard0);
    if (dut.u_csr.cnt[C_CE] == 0) err("soft errors were never corrected");
    // after a full sweep every flip must have been written back
    wait_windows(520, 3000000);
    for (int a = 0; a < DEPTH; a++) if (bd_logical(a) !== ref_encode(gold[a])) begin err("soft error not scrubbed"); break; end
    // flip inside the window under test -> transient
    tr0 = dut.u_csr.cnt[C_TRANS];
    for (int i = 0; i < 14; i++) begin      // a flip just before a write of the same word is erased: use several trials
      int tries = 0;
      while (dut.u_win.st != 4'd5 && tries < 100000) begin @(posedge clk); tries++; end   // W_MARCH
      void'(add_fault(F_SOFT, dut.win_base, $urandom_range(0, 7), $urandom_range(0, 71), .act(dut.u_sram.now_cycle() + 3)));
      wait_windows(2);
    end
    wait_windows(3);
    $display("    in-window flips: transient counter +%0d", dut.u_csr.cnt[C_TRANS] - tr0);
    if (dut.u_csr.cnt[C_TRANS] == tr0) err("in-window soft flips never counted as transient");
    if (dut.u_csr.cnt[C_HARD] != hard0) err("CHK-8: in-window soft error classified as hard");
    // two flips in one word -> genuine UE, reported, never silent
    ue_ok = 1;
    begin
      int a = 12'h5A3 + 8;
      logic [11:0] ad = 12'(a);
      void'(add_fault(F_SOFT, a >> 3, a & 7, 5, .act(dut.u_sram.now_cycle() + 5)));
      void'(add_fault(F_SOFT, a >> 3, a & 7, 41, .act(dut.u_sram.now_cycle() + 5)));
      wait_cycles(20);
      fread(ad);
      repeat (8) @(posedge clk);
      if (!irq_ue) err("UE interrupt missing for a double flip");
    end
    ue_ok = 0; sb_en = 0; repeat (4) @(posedge clk); sb_en = 1; expq.delete();
  endtask

  // ------------------------------------------------------------------ T8: ECC injection CSR
  task automatic t_ecc_inj();
    logic [31:0] d;
    $display("--- T8 ECC_INJ hooks");
    do_reset(); dut.u_sram.clear_faults(); release_reset(); wait_online();
    set_ctrl(32'h00);                        // test logic off: pure ECC behaviour
    // single flip
    apb_wr(8'h40, 32'h0000_0800); apb_wr(8'h44, 0); apb_wr(8'h48, 0); apb_wr(8'h4C, 1);
    fwrite(12'h200, 64'hCAFE_F00D_1234_5678);
    fread(12'h200); repeat (6) @(posedge clk);
    if (n_ce == 0) err("single injected flip not corrected");
    // armed once only
    fwrite(12'h201, 64'h1111_2222_3333_4444); fread(12'h201); repeat (6) @(posedge clk);
    // check bit flip
    apb_wr(8'h40, 0); apb_wr(8'h44, 0); apb_wr(8'h48, 32'h20); apb_wr(8'h4C, 1);
    fwrite(12'h202, 64'h0123_4567_89AB_CDEF); fread(12'h202); repeat (6) @(posedge clk);
    // double flip -> UE
    ue_ok = 1;
    apb_wr(8'h40, 32'h0000_0003); apb_wr(8'h44, 0); apb_wr(8'h48, 0); apb_wr(8'h4C, 1);
    fwrite(12'h203, 64'h5555_AAAA_5555_AAAA); fread(12'h203); repeat (6) @(posedge clk);
    if (n_ue == 0 || !irq_ue) err("double injected flip not reported as UE");
    // partial write to an uncorrectable word must not commit
    begin
      logic [63:0] before_g;
      before_g = gold[12'h203];
      fwrite(12'h203, 64'hFFFF_FFFF_FFFF_FFFF, 8'h01); repeat (8) @(posedge clk);
      gold[12'h203] = before_g;           // write was refused
    end
    ue_ok = 0;
    $display("    ce=%0d ue=%0d", n_ce, n_ue);
    if (n_ce < 2) err("expected two corrected reads");
    // CSR counters
    apb_rd(8'h80, d); if (d == 0) err("CE counter is zero");
    apb_rd(8'h84, d); if (d == 0) err("UE counter is zero");
    sb_en = 0; repeat (4) @(posedge clk); sb_en = 1; expq.delete();
    set_ctrl(32'h1F);
  endtask

  // ------------------------------------------------------------------ T9: scrub-only + repeat-CE hard fault candidate
  task automatic t_scrub_only();
    int rep0, w0;
    $display("--- T9 scrub-only mode and repeating-CE candidates");
    do_reset(); dut.u_sram.clear_faults(); release_reset(); wait_online();
    for (int a = 0; a < DEPTH; a++) fwrite(12'(a), 64'h0);          // all zeros, stuck-at-1 will show as CE
    set_ctrl(32'h1C | 32'h02);                // SCRUB_EN only (+repair enables), TEST_EN = 0
    set_alg(1, 1, 0, 1);
    apb_wr(8'h14, 2);                         // CE_REPEAT_TH
    rep0 = dut.u_csr.cnt[C_REPAIR];
    void'(add_fault(F_SAF, 140, 5, 11, .val(1), .act(dut.u_sram.now_cycle() + 20)));
    // soft errors are fixed by scrub alone
    void'(add_fault(F_SOFT, 400, 1, 3, .act(dut.u_sram.now_cycle() + 20)));
    tr_idle = 90; tr_lo = 1700; tr_hi = DEPTH - 1; tr_en = 1;   // keep the stuck word's data at 0
    w0 = dut.u_csr.cnt[C_WIN];
    wait_windows(3 * 511, 4000000);
    traffic_off();
    tr_lo = 0;
    $display("    after 3 sweeps: ce=%0d hard=%0d repairs=%0d transient=%0d", dut.u_csr.cnt[C_CE], dut.u_csr.cnt[C_HARD],
             dut.u_csr.cnt[C_REPAIR], dut.u_csr.cnt[C_TRANS]);
    if (dut.u_csr.cnt[C_CE] == 0) err("scrub-only saw no CE");
    if (dut.u_csr.cnt[C_HARD] == 0) err("repeating CE never confirmed as hard fault");
    if (dut.u_csr.cnt[C_REPAIR] == rep0) err("hard-fault candidate was not repaired");
    set_ctrl(32'h1F);
  endtask

  // ------------------------------------------------------------------ T10: guaranteed test progress at 100% load
  task automatic t_min_bw();
    int w0, w1;
    $display("--- T10 TEST_MIN_BW progress guarantee at 100%% functional load");
    do_reset(); dut.u_sram.clear_faults(); release_reset(); wait_online();
    tr_idle = 0; tr_wr = 50; tr_en = 1; tr_follow_win = 1;
    w0 = dut.u_csr.cnt[C_WIN];
    wait_cycles(20000);
    w1 = dut.u_csr.cnt[C_WIN];
    $display("    K=0 (off): %0d windows in 20000 cycles at full load", w1 - w0);
    apb_wr(8'h0C, 4);
    w0 = dut.u_csr.cnt[C_WIN];
    wait_cycles(60000);
    w1 = dut.u_csr.cnt[C_WIN];
    $display("    K=4: %0d windows in 60000 cycles at full load, max stall %0d", w1 - w0, max_srun);
    if (w1 - w0 < 10) err("TEST_MIN_BW did not guarantee window progress");
    traffic_off();
    apb_wr(8'h0C, 0);
  endtask

  // ------------------------------------------------------------------ T11: custom microcode + BYPASS
  task automatic t_custom_and_bypass();
    int w0;
    $display("--- T11 custom microcode algorithm (MATS+ re-encoded) and BYPASS");
    do_reset(); dut.u_sram.clear_faults(); release_reset(); wait_online();
    // MATS+: c(w0); u(r0,w1); d(r1,w0)  as 18-bit instructions
    //   {order, n_ops, op5..op0 (rw,pol), last}
    apb_wr(8'h30, 0); apb_wr(8'h34, {2'b10, 3'd1, 12'b000000000010, 1'b0});     // op0 = w0 (rw=1,pol=0)
    apb_wr(8'h30, 1); apb_wr(8'h34, {2'b00, 3'd2, 12'b000000001100, 1'b0});     // op0=r0, op1=w1
    apb_wr(8'h30, 2); apb_wr(8'h34, {2'b01, 3'd2, 12'b000000001001, 1'b1});     // op0=r1, op1=w0, last
    void'(add_fault(F_SAF, 250, 4, 28, .val(1)));
    void'(add_fault(F_SAF, 505, 1, 70, .val(0)));
    run_maint(4);
    if (!flog_has(250, 28) || !flog_has(505, 70)) err("custom algorithm missed a stuck-at fault");
    $display("    custom algorithm found %0d faulty rows", flog_n());
    dut.u_sram.clear_faults();
    // BYPASS: no online activity at all
    set_ctrl(ctrl_val | 32'h20);
    wait_cycles(100);
    while (!dut.u_win.idle) @(posedge clk);          // a window already in flight may finish
    wait_cycles(10);
    w0 = dut.u_csr.cnt[C_WIN];
    tr_idle = 30; tr_en = 1;
    wait_cycles(30000);
    traffic_off();
    if (dut.u_csr.cnt[C_WIN] != w0) err("windows ran in BYPASS");
    if (dut.u_csr.cnt[C_STALL] != 0) err("BYPASS stalled traffic");
    set_ctrl(32'h1F);
  endtask

  // ------------------------------------------------------------------ T12: hammering the window, partial writes included
  task automatic t_hammer();
    $display("--- T12 traffic hammering the window under test (full + partial writes, reads)");
    do_reset(); dut.u_sram.clear_faults(); release_reset(); wait_online();
    tr_idle = 20; tr_wr = 65; tr_part = 50; tr_en = 1; tr_follow_win = 1;
    tr_lo = 0; tr_hi = 63;                      // small footprint, includes the first windows
    wait_cycles(150000);
    traffic_off();
    tr_hi = DEPTH - 1;
    $display("    %0d requests, windows %0d, max stall %0d", n_rd + n_wr, dut.u_csr.cnt[C_WIN], max_srun);
    final_check_array("T12");
  endtask

  // ------------------------------------------------------------------ T13: REQ-SYS-4 / CHK-3 detection latency
  // Worst case for the sliding window: the fault becomes active right after the last window that
  // covers it has closed, so the whole sweep has to elapse before it is seen.  Latency is counted in
  // test cycles (C_TESTCY, load independent) and in wall-clock cycles (scales with 1/idle fraction).
  // Bound = one full sweep measured on a fault-free array + one window of alignment slack.
  localparam int SPEC_SWEEP_TC = 511 * (16 + 160);   // spec 6.5, March C-
  localparam int WIN_TC        = 16 + 160;
  int sweep_tc_meas = 0;
  localparam string SL_NAME [5] = '{"SAF0", "SAF1", "TFup", "TFdn", "CFin"};
  localparam int    SL_TYPE [5] = '{F_SAF, F_SAF, F_TF, F_TF, F_CFIN};
  localparam int    SL_IDLE [4] = '{90, 60, 30, 10};

  task automatic measure_sweep_tc(input int idle_pct);
    int s0, c0, t = 0;
    do_reset(); dut.u_sram.clear_faults(); release_reset(); wait_online();
    tr_idle = idle_pct; tr_en = 1; tr_follow_win = 0; tr_lo = 0; tr_hi = DEPTH - 1;
    s0 = dut.u_csr.cnt[C_SWEEP];
    while (dut.u_csr.cnt[C_SWEEP] == s0 && t < 3000000) begin @(posedge clk); t++; end   // align to a sweep end
    s0 = dut.u_csr.cnt[C_SWEEP]; c0 = dut.u_csr.cnt[C_TESTCY]; t = 0;
    while (dut.u_csr.cnt[C_SWEEP] == s0 && t < 3000000) begin @(posedge clk); t++; end
    if (t >= 3000000) err("sweep never completed");
    sweep_tc_meas = dut.u_csr.cnt[C_TESTCY] - c0;
    traffic_off();
    $display("    fault-free sweep at idle=%0d%%: %0d test cycles, %0d wall cycles (spec 6.5: %0d test cycles)",
             idle_pct, sweep_tc_meas, t, SPEC_SWEEP_TC);
    if (sweep_tc_meas > SPEC_SWEEP_TC + WIN_TC) err("sweep longer than the spec's 511 x 176 test cycles");
  endtask

  task automatic t_sweep_latency(input int idle_pct, input int ftype, input string name);
    int vr, vb, t = 0, tc0, sw0, tc, sw, wall_lim = 3000000;
    bit seen = 0;
    vr = $urandom_range(20, 400); vb = $urandom_range(0, 71);
    do_reset(); dut.u_sram.clear_faults(); release_reset(); wait_online();
    for (int a = 0; a < DEPTH; a++) fwrite(12'(a), {$urandom, $urandom});
    // traffic stays clear of the victim (and aggressor) row so only the test engine can find it
    tr_idle = idle_pct; tr_en = 1; tr_follow_win = 0; tr_wr = 40; tr_lo = (vr + 4) * 8; tr_hi = DEPTH - 1;
    // wait for the window that follows the last one covering row vr (windows vr-1 and vr cover it)
    while (!(dut.win_open && dut.win_base == 9'(vr + 1)) && t < wall_lim) begin @(posedge clk); t++; end
    if (t >= wall_lim) begin err($sformatf("%s: window never reached row %0d", name, vr + 1)); traffic_off(); return; end
    case (ftype)
      F_SAF:  void'(add_fault(F_SAF, vr, 3, vb, .val(name == "SAF1"), .act(dut.u_sram.now_cycle() + 2)));
      F_TF:   void'(add_fault(F_TF,  vr, 3, vb, .pol(name == "TFup"), .act(dut.u_sram.now_cycle() + 2)));
      F_CFIN: void'(add_fault(F_CFIN, vr, 3, vb, vr + 1, 5, vb, .pol(1), .act(dut.u_sram.now_cycle() + 2)));
    endcase
    tc0 = dut.u_csr.cnt[C_TESTCY]; sw0 = dut.u_csr.cnt[C_SWEEP]; t = 0;
    while (!seen && t < wall_lim) begin
      @(posedge clk); t++;
      seen = flog_has(vr, -1);
    end
    tc = dut.u_csr.cnt[C_TESTCY] - tc0; sw = dut.u_csr.cnt[C_SWEEP] - sw0;
    traffic_off();
    $display("    %-5s row %3d bit %2d idle=%2d%%: %s after %6d test cyc, %7d wall cyc, %0d sweep-ends (bound %0d)",
             name, vr, vb, idle_pct, seen ? "detected" : "MISSED  ", tc, t, sw, sweep_tc_meas + WIN_TC);
    if (!seen) err($sformatf("REQ-SYS-4: %s at row %0d never detected", name, vr));
    else begin
      if (tc > sweep_tc_meas + WIN_TC) err($sformatf("REQ-SYS-4: %s detected after %0d test cycles > one sweep (%0d)", name, tc, sweep_tc_meas + WIN_TC));
      if (sw > 1) err($sformatf("REQ-SYS-4: %s needed %0d sweep boundaries", name, sw));
    end
  endtask

  task automatic t_sweep_latency_all();
    $display("--- T13 REQ-SYS-4 detection latency, worst-case fault phase (bound = one full sweep)");
    measure_sweep_tc(50);
    foreach (SL_NAME[i]) t_sweep_latency(50, SL_TYPE[i], SL_NAME[i]);
    foreach (SL_IDLE[j]) begin
      measure_sweep_tc(SL_IDLE[j]);
      t_sweep_latency(SL_IDLE[j], F_SAF, "SAF1");
    end
  endtask


  // ------------------------------------------------------------------ T13: bitmap dump + offline irq_hard
  task automatic t_bitmap_and_irq();
    logic [31:0] d, d0, d1, d2;
    int n, ent_ok, ent_bad, h0;
    $display("--- T13 bitmap-dump FIFO (spec 5.5) and offline irq_hard (spec 9.3)");
    do_reset(); dut.u_sram.clear_faults(); release_reset(); wait_online();
    // a clean destructive test must not raise irq_hard
    apb_wr(8'hC0, 32'hF);
    run_maint(1, 0, 2);
    apb_rd(8'hD0, d);
    if (d[7:0] != 0) err("bitmap FIFO not empty after a fault-free test");
    if (irq_hard) err("irq_hard raised by a fault-free destructive test");
    // one stuck-at-1 cell: March C- reads 0 three times
    void'(add_fault(F_SAF, 100, 3, 17, .val(1)));
    h0 = dut.u_csr.cnt[C_HARD];
    apb_wr(8'hC0, 32'hF);
    run_maint(1, 0, 2);
    if (!irq_hard) err("irq_hard not raised by an offline-detected fault");
    if (dut.u_csr.cnt[C_HARD] != h0 + 1) err("offline fault not counted in the hard-fault counter");
    apb_rd(8'hD0, d); n = d[7:0];
    if (n != 3) err($sformatf("bitmap FIFO holds %0d entries, expected 3 (r0 of three elements)", n));
    ent_ok = 0; ent_bad = 0;
    while (n > 0) begin
      logic [86:0] e;
      apb_rd(8'hD4, d0); apb_rd(8'hD8, d1); apb_rd(8'hDC, d2);
      e = {d2[22:0], d1, d0};
      if (e[86:77] == 10'd100 && e[76:74] == 3'd3 && e[73:0] == (74'h1 << 17)) ent_ok++; else ent_bad++;
      apb_wr(8'hD0, 32'h1);
      apb_rd(8'hD0, d);
      if (d[7:0] != n - 1) err("bitmap pop did not retire exactly one entry");
      n = d[7:0];
    end
    if (ent_ok != 3 || ent_bad != 0) err($sformatf("bitmap entries wrong: %0d good %0d bad", ent_ok, ent_bad));
    // overflow: 14 stuck cells in distinct words give 42 entries > BM_DEPTH
    do_reset(); dut.u_sram.clear_faults();
    for (int i = 0; i < 14; i++) void'(add_fault(F_SAF, 20 + 7 * i, i % 8, 5 + i, .val(1)));
    release_reset(); wait_online();
    run_maint(1, 0, 2);
    apb_rd(8'hD0, d);
    if (!d[8]) err("bitmap overflow flag not set");
    if (d[7:0] != BM_DEPTH) err($sformatf("bitmap count %0d, expected %0d when full", d[7:0], BM_DEPTH));
    // go/no-go and collect modes must not fill the FIFO
    run_maint(1, 0, 1);
    apb_rd(8'hD0, d);
    if (d[7:0] != 0 || d[8]) err("bitmap FIFO not flushed / filled outside bitmap mode");
  endtask

  // ------------------------------------------------------------------ T14: decoder-fault style capture (spec 6.6)
  task automatic t_decoder_abort();
    int df0, ce0, hard0, R;
    $display("--- T14 window abort on a decoder-fault capture pattern (spec 6.6)");
    do_reset(); dut.u_sram.clear_faults(); release_reset(); wait_online();
    for (int a = 0; a < DEPTH; a++) fwrite(12'(a), {$urandom, $urandom});
    wait_cycles(20);
    df0 = dut.u_csr.cnt[C_DF]; hard0 = dut.u_csr.cnt[C_HARD];
    // below the threshold: DF_TH-1 flips at distinct positions in one row -> scrubbed, no abort
    while (dut.sc_base > 380) wait_cycles(50);
    R = dut.sc_base + 40;
    for (int k = 0; k < DF_TH - 1; k++)
      void'(add_fault(F_SOFT, R, k, 3 + 9 * k, .act(dut.u_sram.now_cycle() + 2)));
    ce0 = dut.u_csr.cnt[C_CE];
    wait_windows(60, 3000000);     // no traffic: a functional write would overwrite the injected flips
    if (dut.u_csr.cnt[C_DF] != df0) err("window aborted below the decoder-fault threshold");
    if (dut.u_csr.cnt[C_CE] < ce0 + DF_TH - 1) err("flips below the threshold were not scrubbed");
    // at the threshold: DF_TH distinct positions in one row -> abort, interrupt, nothing tested
    apb_wr(8'hC0, 32'hF);
    while (dut.sc_base > 380) wait_cycles(50);
    R = dut.sc_base + 40;
    for (int k = 0; k < DF_TH; k++)
      void'(add_fault(F_SOFT, R, k, 2 + 11 * k, .act(dut.u_sram.now_cycle() + 2)));
    wait_windows(60, 3000000);
    if (dut.u_csr.cnt[C_DF] == df0) err("decoder-fault pattern did not abort any window");
    if (!irq_ue) err("irq_ue not raised for an aborted window");
    if (dut.u_csr.cnt[C_HARD] != hard0) err("aborted window reported a hard fault");
    // data stays readable through ECC
    for (int k = 0; k < DF_TH; k++) fread(12'(R * 8 + k));
    repeat (8) @(posedge clk);
  endtask

  // ------------------------------------------------------------------ main
  string tests;
  initial begin
    for (int i = 0; i <= 8; i++) stall_hist[i] = 0;
    if (!$value$plusargs("T=%s", tests)) tests = "clean,traffic";
    $display("tests: %s", tests);
    if (has("clean"))    t_poweron_clean();
    if (has("traffic"))  t_online_traffic(50, 60000);
    if (has("traffic90")) t_online_traffic(10, 60000);
    if (has("cov"))      t_poweron_coverage(8);
    if (has("covbig"))   t_poweron_coverage(40);
    if (has("nofalse"))  t_poweron_nofalse();
    if (has("repair"))   t_poweron_repair();
    if (has("fuse"))     t_fuse_reload();
    if (has("hard"))     begin t_online_hard(60, 0); t_online_hard(30, 1); end
    if (has("soft"))     t_soft_errors();
    if (has("eccinj"))   t_ecc_inj();
    if (has("scrub"))    t_scrub_only();
    if (has("minbw"))    t_min_bw();
    if (has("custom"))   t_custom_and_bypass();
    if (has("hammer"))   t_hammer();
    if (has("bitmap"))   t_bitmap_and_irq();
    if (has("decfault")) t_decoder_abort();
    if (has("sweeplat")) t_sweep_latency_all();
    $display("max consecutive stall: %0d, histogram:", max_srun);
    for (int i = 0; i <= 4; i++) $display("   stall %0d: %0d", i, stall_hist[i]);
    $display("CHK-5 window checks: %0d, failures %0d", win_checks, win_check_fail);
    if (errors == 0) $display("TB_SYS PASS"); else $display("TB_SYS FAIL (%0d errors)", errors);
    $finish;
  end

  function automatic bit has(input string n);
    string rest, tok;
    int p;
    rest = tests;
    while (rest.len() > 0) begin
      p = -1;
      for (int i = 0; i < rest.len(); i++) if (rest[i] == ",") begin p = i; break; end
      if (p < 0) begin tok = rest; rest = ""; end
      else begin tok = rest.substr(0, p - 1); rest = rest.substr(p + 1, rest.len() - 1); end
      if (tok == n) return 1;
    end
    return 0;
  endfunction

  // watchdog
  initial begin
    #2000000000;
    $display("WATCHDOG timeout"); $finish;
  end
endmodule
