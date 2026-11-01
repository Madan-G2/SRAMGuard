// ---------------------------------------------------------------------------------------------
// Corner-case tests aimed at the cover points and FSM arcs the regression did not reach.
// ---------------------------------------------------------------------------------------------

// ---- window aborts: uncorrectable capture (spec 6.3 step 1) and decoder-fault pattern (spec 6.6),
//      and a partial write whose read-modify-write hits an uncorrectable word (REQ-ECC-2)
class sg_capture_abort_test extends sg_base_test;
  `uvm_component_utils(sg_capture_abort_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  // let the sweep reach a row ahead of the current window, then return that row
  task row_ahead(output int r);
    while (bd.sc_base() > 380) env.wait_cycles(50);
    r = bd.sc_base() + 40;
  endtask

  task body();
    int r, ue0, df0, hard0, tr0, w0;
    env.bring_up();
    sg_vseq_lib::fill(env.func);
    hard0 = bd.cnt(C_HARD); tr0 = bd.cnt(C_TRANS);

    // 1. two flips in one word of an upcoming window: no trusted reference, window aborts
    row_ahead(r);
    begin
      bit [11:0] a = 12'(r * 8 + 5);
      ue0 = bd.cnt(C_UE); w0 = bd.cnt(C_WIN);
      env.apb.write(8'hC0, 32'hF);
      void'(env.fc.add(FT_SOFT, r, 5, 4,  .act_rel(2)));
      void'(env.fc.add(FT_SOFT, r, 5, 37, .act_rel(2)));
      env.sb.allow_ue(a);
      env.wait_windows(60);
      if (bd.cnt(C_UE) == ue0) `uvm_error("ABORT", "uncorrectable capture was not reported")
      if (!vif.irq_ue) `uvm_error("IRQ", "irq_ue missing for an uncorrectable capture")
      if (bd.cnt(C_WIN) <= w0) `uvm_error("ABORT", "windows stopped after an aborted capture")
      fread(a); drain(8);                                   // the word stays uncorrectable: flagged, never silent
      // 2. partial write to that word: the read-modify-write must refuse to merge garbage
      fwrite(a, 64'hAAAA_BBBB_CCCC_DDDD, 8'h0F); drain(8);
      fread(a); drain(8);
      fwrite(a, 64'h1234, 8'hFF); fread(a); drain(8);       // a full write heals it
    end

    // 3. DF_TH distinct correctable positions in one row: decoder-fault pattern, window aborts
    row_ahead(r);
    df0 = bd.cnt(C_DF);
    env.apb.write(8'hC0, 32'hF);
    for (int k = 0; k < DF_TH; k++) void'(env.fc.add(FT_SOFT, r, k, 2 + 11 * k, .act_rel(2)));
    env.wait_windows(60);
    if (bd.cnt(C_DF) == df0) `uvm_error("ABORT", "decoder-fault pattern did not abort the window")
    if (!vif.irq_ue) `uvm_error("IRQ", "irq_ue missing for an aborted window")
    for (int k = 0; k < DF_TH; k++) fread(12'(r * 8 + k));
    drain(8);

    // 4. a stuck IO is one position, not a decoder fault: it must still be tested and repaired
    row_ahead(r);
    df0 = bd.cnt(C_DF);
    begin
      int rep0 = bd.cnt(C_REPAIR);
      for (int c = 0; c < 8; c++) begin
        bit [63:0] d = {$urandom, $urandom};
        d[21] = 1'b0;
        fwrite(12'(r * 8 + c), d);
      end
      void'(env.fc.add(FT_SAF, r, 0, 21, .val(1), .act_rel(2)));
      void'(env.fc.add(FT_SAF, r, 3, 21, .val(1), .act_rel(2)));
      void'(env.fc.add(FT_SAF, r, 6, 21, .val(1), .act_rel(2)));
      env.wait_windows(120);
      if (bd.cnt(C_DF) != df0) `uvm_error("ABORT", "a single stuck IO was mistaken for a decoder fault")
      if (bd.cnt(C_REPAIR) == rep0) `uvm_error("ABORT", "row with a stuck IO was not repaired")
    end
    sg_vseq_lib::read_all(env.func, 0, 600 * 8 - 1);
    drain();
    env.sb.en = 0;                                           // poisoned words remain by design
  endtask
endclass

// ---- scrub-only mode (spec 7.3): TEST_EN = 0 writes back only the words with a corrected error
class sg_scrub_only_test extends sg_base_test;
  `uvm_component_utils(sg_scrub_only_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    int ce0, tc0;
    bit used [int];
    env.bring_up();
    sg_vseq_lib::fill(env.func);
    env.set_ctrl(32'h1E);                                    // TEST_EN = 0
    for (int n = 0; n < 12;) begin
      int r = $urandom_range(40, 500), c = $urandom_range(0, 7);
      if (used.exists(r * 8 + c)) continue;
      used[r * 8 + c] = 1; n++;
      void'(env.fc.add(FT_SOFT, r, c, $urandom_range(0, 71), .act_rel(5)));
    end
    ce0 = bd.cnt(C_CE);
    env.wait_windows(520);
    if (bd.cnt(C_CE) - ce0 < 12) `uvm_error("SCRUB", "scrub-only sweep did not correct every flipped word")
    foreach (used[k])
      if (bd.logical(k) !== sg_ecc_ref_pkg::ref_encode(env.gold.mem[k]))
        `uvm_error("SCRUB", $sformatf("word %03h still holds a flipped bit after the sweep", k))
    if (bd.cnt(C_HARD) != 0 || bd.cnt(C_TRANS) != 0) `uvm_error("SCRUB", "scrub-only mode ran a March test")
    env.set_ctrl(32'h1F);
    // scrub off too: nothing runs
    env.set_ctrl(32'h1C);
    env.wait_cycles(600);                                    // let a window already in flight finish
    tc0 = bd.cnt(C_WIN);
    env.wait_cycles(5000);
    if (bd.cnt(C_WIN) != tc0) `uvm_error("SCRUB", "windows ran with TEST_EN = 0 and SCRUB_EN = 0")
    env.set_ctrl(32'h1F);
    sg_vseq_lib::read_all(env.func);
    drain();
  endtask
endclass

// ---- online repair when the spare row turns out to be bad: verify fails, bounded retries, fail event
class sg_bad_spare_test extends sg_base_test;
  `uvm_component_utils(sg_bad_spare_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    int rep0, w0, vr = 200, t = 0;
    env.bring_up();
    sg_vseq_lib::fill(env.func);
    // spare row 0 develops a stuck cell after power-on; row vr has a hard fault of its own
    for (int c = 0; c < 8; c++) begin
      bit [63:0] d = {$urandom, $urandom};
      d[9] = 1'b0;                                            // stuck-at-1 on bit 9 disagrees with the data
      fwrite(12'(vr * 8 + c), d);
    end
    void'(env.fc.add(FT_SAF, 512, 2, 9, .val(1)));
    void'(env.fc.add(FT_SAF, vr, 4, 33, .val(1)));
    rep0 = bd.cnt(C_REPAIR);
    env.apb.write(8'hC0, 32'hF);
    // no functional traffic: the data of the row stays put, so the verify read must see the stuck cell
    while (!vif.irq_repair && t < 1500000) begin @(posedge vif.clk); t++; end
    if (t >= 1500000) `uvm_error("REP", "no repair-fail interrupt for a bad spare row")
    if (bd.cnt(C_REPAIR) != rep0) `uvm_error("REP", "a repair into a bad spare was counted as successful")
    if (bd.rm_valid(0) && bd.rm_row(0) == vr) `uvm_error("REP", "remap switched to a spare that failed verification")
    `uvm_info("BADSPARE", $sformatf("repair refused after %0d cycles; row %0d stays on ECC", t, vr), UVM_LOW)
    // the failed attempt must not have touched user data
    sg_vseq_lib::read_all(env.func, 0, 400 * 8 - 1);
    drain();
  endtask
endclass

// ---- interrupt events racing the W1C clear (an event in the clearing cycle must survive)
class sg_irq_race_test extends sg_base_test;
  `uvm_component_utils(sg_irq_race_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    bit [11:0] w = 12'h3C1;
    bit stop = 0;
    bit [31:0] d;
    env.bring_up();
    fwrite(w, 64'h5555_AAAA_5555_AAAA);
    void'(env.fc.add(FT_SOFT, w >> 3, w & 7, 3,  .act_rel(2)));
    void'(env.fc.add(FT_SOFT, w >> 3, w & 7, 40, .act_rel(2)));
    env.sb.allow_ue(w);
    env.wait_cycles(10);
    fork
      begin for (int i = 0; i < 600; i++) begin fread(w); if (i % 3 == 0) env.wait_cycles(1); end end
      begin for (int i = 0; i < 900; i++) env.apb.write(8'hC0, 32'h1); end
    join
    // last event with nobody clearing: the line must be up
    env.apb.write(8'hC0, 32'hF);
    env.wait_cycles(4);
    fread(w); drain(10);
    if (!vif.irq_ue) `uvm_error("IRQ", "irq_ue lost: an event arrived after the last clear")
    env.apb.read(8'hC0, d);
    if (!d[0]) `uvm_error("IRQ", "IRQ_STAT.ue not set")
  endtask
endclass

// ---- diagnosis modes (spec 5.5): go/no-go stops early, bitmap dump streams every failure
class sg_diag_test extends sg_base_test;
  `uvm_component_utils(sg_diag_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    bit [31:0] d, d0, d1, d2;
    int n, t0, full_t, gng_t, good = 0, bad = 0;
    env.bring_up();
    void'(env.fc.add(FT_SAF, 100, 3, 17, .val(1)));
    t0 = $time / 10000;
    env.run_maint(1, 0, 1);                                   // collect
    full_t = $time / 10000 - t0;
    t0 = $time / 10000;
    env.run_maint(1, 0, 0);                                   // go / no-go
    gng_t = $time / 10000 - t0;
    `uvm_info("DIAG", $sformatf("collect %0d cycles, go/no-go %0d cycles", full_t, gng_t), UVM_LOW)
    if (!bd.mbist_fail()) `uvm_error("DIAG", "MBIST_FAIL not set by go/no-go")
    if (gng_t >= full_t) `uvm_error("DIAG", "go/no-go did not stop early")
    if (bd.repair_ok()) `uvm_error("DIAG", "go/no-go must not run the repair analysis")
    // bitmap dump: March C- reads 0 three times at the stuck cell
    env.run_maint(1, 0, 2);
    env.apb.read(8'hD0, d); n = d[7:0];
    if (n != 3) `uvm_error("DIAG", $sformatf("bitmap holds %0d entries, expected 3", n))
    while (n > 0) begin
      bit [86:0] e;
      env.apb.read(8'hD4, d0); env.apb.read(8'hD8, d1); env.apb.read(8'hDC, d2);
      e = {d2[22:0], d1, d0};
      if (e[86:77] == 10'd100 && e[76:74] == 3'd3 && e[73:0] == (74'h1 << 17)) good++; else bad++;
      env.apb.write(8'hD0, 1);
      env.apb.read(8'hD0, d);
      if (d[7:0] != n - 1) `uvm_error("DIAG", "pop did not retire exactly one entry")
      n = d[7:0];
    end
    if (good != 3 || bad != 0) `uvm_error("DIAG", $sformatf("bitmap entries: %0d good %0d bad", good, bad))
    // overflow: 14 failing words give 42 entries
    env.fc.clear();
    for (int i = 0; i < 14; i++) void'(env.fc.add(FT_SAF, 20 + 7 * i, i % 8, 5 + i, .val(1)));
    env.run_maint(1, 0, 2);
    env.apb.read(8'hD0, d);
    if (!d[8] || d[7:0] != BM_DEPTH) `uvm_error("DIAG", "bitmap FIFO overflow not flagged")
    env.run_maint(1, 0, 1);
    env.apb.read(8'hD0, d);
    if (d[8:0] != 0) `uvm_error("DIAG", "bitmap FIFO not flushed by the next test")
    env.fc.clear();
    env.run_maint(1, 0, 1);
    env.sb.expect_no_ce = 1;
    sg_vseq_lib::read_all(env.func);
    drain();
  endtask
endclass

// ---- reset in the middle of every kind of activity, then a clean restart (no stale state)
class sg_reset_midflight_test extends sg_base_test;
  `uvm_component_utils(sg_reset_midflight_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  task wait_state(int st, int timeout = 200000);
    int t = 0;
    while (bd.win_state() != st && t < timeout) begin @(posedge vif.clk); t++; end
  endtask

  task body();
    int targets [8] = '{1, 3, 5, 6, 7, 9, 12, 14};     // CAP SCRUBWB MARCH DRAIN CLASS REP_COPY REL RS_WR
    for (int i = 0; i < 8; i++) begin
      env.bring_up();
      sg_vseq_lib::fill(env.func);
      if (targets[i] == 9 || targets[i] == 14 || targets[i] == 7) begin
        // a hard fault makes the window re-run, restore and repair
        void'(env.fc.add(FT_SAF, bd.sc_base() + 6, 1, 40, .val(1), .act_rel(2)));
      end
      if (targets[i] == 3) env.set_ctrl(32'h1E);                     // scrub-only reaches SCRUBWB
      if (targets[i] == 3) void'(env.fc.add(FT_SOFT, bd.sc_base() + 4, 2, 12, .act_rel(2)));
      start_traffic(60, 40, 30);
      wait_state(targets[i]);
      env.reset_dut();                                                // asynchronous reset mid-activity
      env.ctrl_val = 32'h1F;
      env.fc.clear();
      env.release_reset();
      stop_traffic();               // the request held across the reset completes once the port reopens
      env.wait_online();
      if (bd.flog_n() != 0 || bd.rm_sig() !== 38'h0) `uvm_error("RST", "stale fault log / remap after reset")
      if (bd.win_state() > 2) `uvm_error("RST", "window engine did not restart from idle")
      sg_vseq_lib::read_all(env.func, 0, 255);
      env.wait_windows(4);
      drain();
    end
    // reset during RESET_TEST and during MAINT
    env.reset_dut(); env.fc.clear(); env.release_reset();
    env.wait_cycles(5000);
    env.reset_dut(); env.release_reset(); env.wait_online();
    env.apb.write(8'h00, env.ctrl_val | 32'h40);
    while (bd.mode() != int'(MODE_MAINT)) @(posedge vif.clk);
    env.wait_cycles(3000);
    env.reset_dut(); env.release_reset(); env.wait_online();
    sg_vseq_lib::read_all(env.func, 0, 255);
    drain();
  endtask
endclass

// ---- register-level coverage: every CSR address, unmapped addresses, APB phase corners, fault-log merge/saturation
class sg_csr_regs_test extends sg_base_test;
  `uvm_component_utils(sg_csr_regs_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  task chk(bit [7:0] a, bit [31:0] exp, string what);
    bit [31:0] d;
    env.apb.read(a, d);
    if (d !== exp) `uvm_error("CSR", $sformatf("%s: 0x%02h read 0x%08h, expected 0x%08h", what, a, d, exp))
  endtask

  task body();
    bit [31:0] d;
    env.bring_up();
    // configuration registers, written then read back
    env.apb.write(8'h04, 32'h0000_0A25);  chk(8'h04, 32'h0000_0A25, "ALG");
    env.apb.write(8'h04, 32'h0000_0000);  chk(8'h04, 32'h0, "ALG");
    env.apb.write(8'h04, 32'h0000_0401);  chk(8'h04, 32'h0000_0401, "ALG");
    chk(8'h00, 32'h1F, "CTRL");
    env.apb.write(8'h00, 32'h1F | 32'h80); chk(8'h00, 32'h9F, "CTRL freeze");
    env.apb.write(8'h00, 32'h1F);
    // test-only microcode and signature staging registers (design is reset afterwards)
    env.apb.write(8'h30, 32'h5);          chk(8'h30, 32'h5, "UC_IDX");
    env.apb.write(8'h34, 32'h0001_5A5A);
    env.apb.write(8'h18, 32'h0);          env.apb.write(8'h1C, 32'h0);
    chk(8'h18, 32'h0, "REPAIR_SIG lo"); chk(8'h1C, 32'h0, "REPAIR_SIG hi");
    // ECC injection registers
    env.apb.write(8'h40, 32'hA5A5_0001);  chk(8'h40, 32'hA5A5_0001, "INJ0");
    env.apb.write(8'h44, 32'h8000_0002);  chk(8'h44, 32'h8000_0002, "INJ1");
    env.apb.write(8'h48, 32'h0000_00C3);  chk(8'h48, 32'h0000_00C3, "INJ2");
    env.apb.write(8'h4C, 32'h1);          chk(8'h4C, 32'h1, "INJ_ARM");
    env.apb.write(8'h4C, 32'h0);          chk(8'h4C, 32'h0, "INJ_ARM");
    env.apb.write(8'h40, 0); env.apb.write(8'h44, 0); env.apb.write(8'h48, 0);
    // fault-log window: select every entry
    for (int i = 0; i < FLOG_DEPTH; i++) begin
      env.apb.write(8'h60, i);  chk(8'h60, i, "FLOG_SEL");
      env.apb.read(8'h64, d); env.apb.read(8'h68, d); env.apb.read(8'h6C, d); env.apb.read(8'h70, d);
    end
    env.apb.read(8'h74, d);
    // every counter, the first address past them, unmapped low and high addresses
    for (int a = 8'h80; a < 8'h80 + 4 * N_CNT; a += 4) env.apb.read(8'(a), d);
    env.apb.read(8'(8'h80 + 4 * N_CNT), d);   if (d !== 0) `uvm_error("CSR", "address past the counters is not zero")
    env.apb.read(8'h20, d);  if (d !== 0) `uvm_error("CSR", "unmapped 0x20 not zero")
    env.apb.read(8'hE0, d);  if (d !== 0) `uvm_error("CSR", "unmapped 0xE0 not zero")
    env.apb.read(8'hFC, d);  if (d !== 0) `uvm_error("CSR", "unmapped 0xFC not zero")
    env.apb.write(8'h20, 32'hFFFF_FFFF); env.apb.write(8'hE8, 32'hFFFF_FFFF);
    chk(8'h00, 32'h1F, "CTRL after unmapped writes");
    // APB corner: PENABLE with PSEL low must not write
    @(negedge vif.clk);
    vif.psel = 0; vif.penable = 1; vif.pwrite = 1; vif.paddr = 8'h0C; vif.pwdata = 32'h77;
    @(negedge vif.clk); vif.penable = 0; vif.pwrite = 0;
    chk(8'h0C, 32'h0, "write with PSEL low");

    // fault log, quiet design: no test, no scrub, no traffic
    env.apb.write(8'h00, 32'h0);
    env.wait_cycles(2000);
    bd.flog_ins(77, 74'h1, 0);                  // new offline entry
    bd.flog_ins(77, 74'h2, 1);                  // merge: offline -> online
    bd.flog_ins(77, 74'h4, 0);                  // merge: online stays online
    bd.flog_ins(78, 74'h8, 1);                  // new online entry
    bd.flog_ins(78, 74'h10, 0);
    env.apb.write(8'h60, 0);
    env.apb.read(8'h64, d);
    if (d[9:0] !== 10'd77 || !d[10] || !d[11] || d[31:16] !== 16'd3) `uvm_error("FLOG", $sformatf("entry 0 read 0x%08h", d))
    env.apb.read(8'h68, d); if (d !== 32'h7) `uvm_error("FLOG", "merged mask wrong")
    env.apb.write(8'h60, 1);
    env.apb.read(8'h64, d);
    if (d[9:0] !== 10'd78 || !d[11] || d[31:16] !== 16'd2) `uvm_error("FLOG", $sformatf("entry 1 read 0x%08h", d))
    // counter saturation (65,535 + overshoot) and overflow with all eight entries used
    repeat (65540) bd.flog_ins(77, 74'h0, 0);
    env.apb.write(8'h60, 0);
    env.apb.read(8'h64, d);
    if (d[31:16] !== 16'hFFFF) `uvm_error("FLOG", "hit counter did not saturate at 0xFFFF")
    for (int r = 100; r < 100 + FLOG_DEPTH; r++) bd.flog_ins(r, 74'h1, 0);
    env.apb.read(8'h74, d); if (!d[0]) `uvm_error("FLOG", "overflow flag not set with a ninth distinct row")
    env.apb.write(8'h60, 7);
    env.apb.read(8'h64, d); env.apb.read(8'h68, d); env.apb.read(8'h6C, d); env.apb.read(8'h70, d);

    // restore: reset clears the log, the staged microcode word and everything above
    env.fc.clear();
    env.reset_dut(); env.ctrl_val = 32'h1F; env.release_reset(); env.wait_online();
    if (bd.flog_n() != 0) `uvm_error("FLOG", "log not empty after reset")
    sg_vseq_lib::read_all(env.func, 0, 255);
    env.wait_windows(2);
  endtask
endclass

// ---- scheduler and sequencer corners: custom microcode, idle stop/ack, CE table, sweep pacing
class sg_sched_mbist_test extends sg_base_test;
  `uvm_component_utils(sg_sched_mbist_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  task body();
    int guard;
    env.bring_up();
    // custom algorithm in the microcode RAM: c(w0) then seven ascending r0 elements; the
    // eighth RAM element ends the program by position (no 'last' bit set anywhere)
    env.apb.write(8'h30, 0); env.apb.write(8'h34, 32'h0002_0004);
    for (int i = 1; i < 8; i++) begin env.apb.write(8'h30, i); env.apb.write(8'h34, 32'h0000_2000); end
    env.run_maint(int'(ALG_CUSTOM));
    if (bd.flog_n() != 0) `uvm_error("MB", "custom r0 program logged faults on a clean array")
    // a second, short custom program that ends on its 'last' bit
    env.apb.write(8'h30, 1); env.apb.write(8'h34, 32'h0000_2001);
    env.run_maint(int'(ALG_CUSTOM));
    if (bd.flog_n() != 0) `uvm_error("MB", "short custom program logged faults")

    // everything idle: stop and ack with the sequencer not running must be ignored
    env.set_ctrl(32'h0);
    env.wait_cycles(3000);
    if (bd.mb_busy()) `uvm_error("MB", "sequencer busy with the engine off")
    bd.mb_idle_stop(); bd.mb_idle_ack(); bd.mb_idle_stop();
    env.wait_cycles(10);
    if (bd.mb_busy()) `uvm_error("MB", "idle stop/ack started the sequencer")

    // repeat-CE table and sweep pacing, driven at the scheduler pins
    env.apb.write(8'h14, 0);                                   // threshold 0: tracking off
    bd.scrub_drive(1, 5, 0, 0, 0);
    env.apb.write(8'h14, 2);
    guard = 0; while (bd.sc_base() != 0 && guard++ < 600) bd.scrub_drive(0, 0, 1, 0, 0);
    bd.scrub_drive(1, 5, 0, 0, 0);                             // row 5 seen in sweep 1
    for (int sw = 0; sw < 20; sw++) begin
      if (sw < 18) bd.scrub_drive(1, 6, 0, 0, 0);              // row 6 repeats every sweep: counter saturates at 15
      guard = 0;
      do bd.scrub_drive(0, 0, 1, 0, 0); while (bd.sc_base() != 0 && guard++ < 600);
    end                                                        // row 5 missed a sweep: dropped
    bd.scrub_drive(0, 0, 0, 1, 6);                             // repair forgets row 6
    bd.scrub_drive(0, 0, 0, 1, 77);                            // repair of an untracked row
    // pacing: a long period holds the next sweep back; changing it mid-sweep
    env.apb.write(8'h10, 32'h00FF_FFF0);
    bd.scrub_drive(0, 0, 1, 0, 0);                             // sweep in progress, timer far below the period
    env.apb.write(8'h10, 32'h0);
    guard = 0; while (bd.sc_base() != 0 && guard++ < 600) bd.scrub_drive(0, 0, 1, 0, 0);
    env.apb.write(8'h10, 32'h00FF_FFF0);
    env.wait_cycles(20);                                       // sweep over, timer below the period: no go
    bd.scrub_tmr_max();                                        // free-running timer saturates, does not wrap
    env.wait_cycles(10);
    env.apb.write(8'h10, 32'h0);

    // back to normal operation
    env.fc.clear();
    env.reset_dut(); env.ctrl_val = 32'h1F; env.release_reset(); env.wait_online();
    sg_vseq_lib::read_all(env.func, 0, 255);
    env.wait_windows(3);
    drain();
  endtask
endclass
