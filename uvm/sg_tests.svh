// ---------------------------------------------------------------------------------------------
// Tests.  Run one with +UVM_TESTNAME=<name>; uvm/run_uvm.sh runs the whole list.
// ---------------------------------------------------------------------------------------------
class sg_base_test extends uvm_test;
  `uvm_component_utils(sg_base_test)
  sg_env        env;
  sg_fault_list flist;
  virtual sg_if    vif;
  virtual sg_bd_if bd;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    flist = sg_fault_list::type_id::create("flist");
    uvm_config_db#(sg_fault_list)::set(this, "env.fc", "fault_list", flist);
    env = sg_env::type_id::create("env", this);
    if (!uvm_config_db#(virtual sg_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "sg_if not set")
    if (!uvm_config_db#(virtual sg_bd_if)::get(this, "", "bd", bd)) `uvm_fatal("NOBD", "sg_bd_if not set")
  endfunction
  function void end_of_elaboration_phase(uvm_phase phase);
    if ($test$plusargs("PRINT_TOPO")) uvm_top.print_topology();
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    body();
    phase.drop_objection(this);
  endtask
  virtual task body(); endtask

  function int plus(string n, int d);
    int v;
    string f;
    f = {n, "=%d"};
    if ($value$plusargs(f, v)) return v;
    return d;
  endfunction

  // ---- background traffic
  sg_traffic_seq tr;
  task start_traffic(int idle, int wr = 40, int part = 30, int lo = 0, int hi = DEPTH - 1, int follow = 0);
    tr = sg_traffic_seq::type_id::create("tr");
    tr.n_items = 1 << 30; tr.idle_pct = idle; tr.wr_pct = wr; tr.part_pct = part;
    tr.lo = lo; tr.hi = hi; tr.follow_win_pct = follow;
    fork tr.start(env.func.sqr); join_none
  endtask
  task stop_traffic();
    if (tr == null) return;
    tr.stop_req = 1;
    tr.wait_for_sequence_state(UVM_FINISHED);
    repeat (12) @(posedge vif.clk);
    tr = null;
  endtask

  // directed accesses
  task fwrite(bit [11:0] a, bit [63:0] d, bit [7:0] be = 8'hFF); sg_vseq_lib::one(env.func, 1, a, d, be); endtask
  task fread(bit [11:0] a);                                       sg_vseq_lib::one(env.func, 0, a); endtask
  task drain(int n = 12); repeat (n) @(posedge vif.clk); endtask

  function void report_phase(uvm_phase phase);
    uvm_report_server rs = uvm_report_server::get_server();
    if (rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL) == 0)
      `uvm_info("RESULT", "TEST PASS", UVM_NONE)
    else
      `uvm_info("RESULT", $sformatf("TEST FAIL (%0d errors)", rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL)), UVM_NONE)
  endfunction
endclass

// ---- T1: power-on of a fault-free array, CHK-4 (no false alarms)
class sg_clean_test extends sg_base_test;
  `uvm_component_utils(sg_clean_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    int t0 = 0;
    env.reset_dut(); env.fc.clear(); env.release_reset();
    env.wait_online();
    if (bd.mbist_fail()) `uvm_error("CHK-4", "MBIST_FAIL set on a clean array")
    if (!bd.repair_ok()) `uvm_error("CHK-4", "REPAIR_OK not set on a clean array")
    if (bd.rm_sig() !== 38'h0) `uvm_error("CHK-4", "remap not empty on a clean array")
    if (bd.flog_n() != 0) `uvm_error("CHK-4", "fault log not empty on a clean array")
    env.sb.expect_no_ce = 1;
    sg_vseq_lib::read_all(env.func);                    // zero fill must read back as zero
    for (int i = 0; i < 64; i++) fwrite(12'(i * 61), {$urandom, $urandom});
    for (int i = 0; i < 64; i++) fread(12'(i * 61));
    fwrite(12'h123, 64'hFFFF_FFFF_FFFF_FFFF);
    fwrite(12'h123, 64'h0000_0000_00AA_0000, 8'b0000_0100);
    fread(12'h123);
    drain();
  endtask
endclass

// ---- T2: online traffic at several idle fractions, no faults
class sg_traffic_test extends sg_base_test;
  `uvm_component_utils(sg_traffic_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    int idles [3] = '{50, 10, 90};
    env.bring_up();
    env.sb.expect_no_ce = 1;
    foreach (idles[i]) begin
      int w0 = bd.cnt(C_WIN);
      start_traffic(idles[i], 40, 30);
      env.wait_cycles(plus("CYCLES", 60000));
      stop_traffic();
      `uvm_info("TRAFFIC", $sformatf("idle %0d%%: windows +%0d", idles[i], bd.cnt(C_WIN) - w0), UVM_LOW)
    end
    if (bd.cnt(C_HARD) != 0 || bd.flog_n() != 0) `uvm_error("CHK-4", "false alarm: fault logged without a fault")
    sg_vseq_lib::read_all(env.func);
    drain();
  endtask
endclass

// ---- T6: hard fault activated mid-run, detected inside one sweep, repaired online
class sg_hard_test extends sg_base_test;
  `uvm_component_utils(sg_hard_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  task one_case(int idle, bit on_row);
    int vr, rep0, hard0, sw0, t = 0, vb;
    sg_fault_item f;
    env.bring_up();
    sg_vseq_lib::fill(env.func);
    vr = $urandom_range(20, 480); vb = $urandom_range(0, 71);
    rep0 = bd.cnt(C_REPAIR); hard0 = bd.cnt(C_HARD); sw0 = bd.cnt(C_SWEEP);
    f = env.fc.add(FT_SAF, vr, $urandom_range(0, 7), vb, .val(1), .act_rel(50));
    env.cov.sample_loc(vr, vb);
    if (on_row) start_traffic(idle, 60, 30, vr * 8, vr * 8 + 7); else start_traffic(idle, 40, 30);
    while (bd.cnt(C_REPAIR) == rep0 && t < 1800000) begin @(posedge vif.clk); t++; end
    if (t >= 1800000) `uvm_error("REP", "online repair never completed")
    `uvm_info("HARD", $sformatf("idle %0d%% on_row=%0b: row %0d repaired after %0d cycles, %0d sweeps", idle, on_row, vr, t,
              bd.cnt(C_SWEEP) - sw0), UVM_LOW)
    if (bd.cnt(C_SWEEP) - sw0 > 1) `uvm_error("REQ-SYS-4", "fault not detected within one sweep")
    if (!bd.flog_has(vr, vb)) `uvm_error("CHK-3", "hard fault missing in the fault log")
    if (!((bd.rm_valid(0) && bd.rm_row(0) == vr) || (bd.rm_valid(1) && bd.rm_row(1) == vr))) `uvm_error("CHK-7", "row not remapped")
    if (bd.cnt(C_HARD) == hard0) `uvm_error("CHK-8", "hard-fault counter did not move")
    if (!vif.irq_hard || !vif.irq_repair) `uvm_error("IRQ", "irq_hard / irq_repair missing after a repair")
    env.wait_cycles(30000);
    stop_traffic();
    for (int c = 0; c < 8; c++) fread(12'(vr * 8 + c));
    env.wait_windows(2);
    drain();
  endtask

  task body();
    one_case(60, 0);
    one_case(30, 1);
    one_case(10, 1);
  endtask
endclass

// ---- T7: soft errors, classification (CHK-8), double flips, hard + soft in one word
class sg_soft_test extends sg_base_test;
  `uvm_component_utils(sg_soft_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    int hard0, tr0, ce0;
    bit used [int];
    env.bring_up();
    sg_vseq_lib::fill(env.func);
    hard0 = bd.cnt(C_HARD); ce0 = bd.cnt(C_CE);
    // single flips spread over the array, one per word
    for (int n = 0; n < 24;) begin
      int r = $urandom_range(300, 510), c = $urandom_range(0, 7);
      if (used.exists(r * 8 + c)) continue;
      used[r * 8 + c] = 1; n++;
      void'(env.fc.add(FT_SOFT, r, c, $urandom_range(0, 71), .act_rel(100)));
    end
    start_traffic(80, 40, 30, 0, DEPTH - 1, 40);
    env.wait_windows(520);
    stop_traffic();
    if (bd.cnt(C_HARD) != hard0) `uvm_error("CHK-8", "soft error classified as hard fault")
    if (bd.flog_n() != 0) `uvm_error("CHK-8", "soft error reached the fault log")
    if (bd.cnt(C_CE) == ce0) `uvm_error("ECC", "soft errors were never corrected")
    // a flip inside the window under test: transient counter moves, never hard
    tr0 = bd.cnt(C_TRANS);
    for (int i = 0; i < 14; i++) begin       // a flip just before a write of the same word is erased: use several trials
      int tries = 0;
      while (bd.win_state() != 5 && tries < 100000) begin @(posedge vif.clk); tries++; end   // W_MARCH
      void'(env.fc.add(FT_SOFT, bd.win_base(), $urandom_range(0, 7), $urandom_range(0, 71), .act_rel(3)));
      env.wait_windows(2);
    end
    env.wait_windows(3);
    if (bd.cnt(C_TRANS) == tr0) `uvm_error("CHK-8", "in-window soft flips never counted as transient")
    if (bd.cnt(C_HARD) != hard0) `uvm_error("CHK-8", "in-window soft error classified as hard")
    // two flips in one word: genuine UE, flagged, never silent
    begin
      bit [11:0] a = 12'h5A3 + 8;
      env.sb.allow_ue(a);
      void'(env.fc.add(FT_SOFT, a >> 3, a & 7, 5,  .act_rel(5)));
      void'(env.fc.add(FT_SOFT, a >> 3, a & 7, 41, .act_rel(5)));
      env.wait_cycles(20);
      fread(a); drain(8);
      if (!vif.irq_ue) `uvm_error("IRQ", "irq_ue missing for a double flip")
    end
    // hard fault followed by a soft error in the same word (risk window, spec 10.4)
    begin
      bit [11:0] a = 12'h1B4;
      bit [63:0] d = {$urandom, $urandom};
      d[7] = 1'b0;                                           // stuck-at-1 disagrees with the data
      fwrite(a, d);
      void'(env.fc.add(FT_SAF, a >> 3, a & 7, 7, .val(1)));
      fread(a); drain(6);                                    // one hard error: corrected
      env.sb.allow_ue(a);
      void'(env.fc.add(FT_SOFT, a >> 3, a & 7, 20, .act_rel(3)));
      env.wait_cycles(10);
      fread(a); drain(6);                                    // hard + soft: uncorrectable but flagged
      d[7] = 1'b1;
      fwrite(a, d); fread(a); drain(6);                      // rewrite with the stuck value: clean again
    end
  endtask
endclass

// ---- T8: ECC_INJ hooks (spec 7.5)
class sg_eccinj_test extends sg_base_test;
  `uvm_component_utils(sg_eccinj_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task inject(bit [71:0] mask);
    env.apb.write(8'h40, mask[31:0]);
    env.apb.write(8'h44, mask[63:32]);
    env.apb.write(8'h48, {24'h0, mask[71:64]});
    env.apb.write(8'h4C, 32'h1);
  endtask
  task body();
    int ce0, ue0;
    env.bring_up();
    ce0 = bd.cnt(C_CE); ue0 = bd.cnt(C_UE);
    for (int i = 0; i < 72; i += 5) begin                  // every kind of single-bit position
      bit [11:0] a = 12'($urandom_range(0, DEPTH - 1));
      inject(72'h1 << i);
      fwrite(a, {$urandom, $urandom});
      fread(a); drain(6);
    end
    if (bd.cnt(C_CE) <= ce0) `uvm_error("ECC", "injected single errors were not corrected / counted")
    // double error -> UE, armed mask is used by exactly one write
    begin
      bit [11:0] a = 12'h777;
      inject((72'h1 << 3) | (72'h1 << 50));
      fwrite(a, 64'hDEAD_BEEF_0123_4567);
      env.sb.allow_ue(a);                                   // the injected write itself created the poisoned word
      fread(a); fread(a); drain(8);
      if (bd.cnt(C_UE) <= ue0) `uvm_error("ECC", "injected double error not reported")
      if (!vif.irq_ue) `uvm_error("IRQ", "irq_ue missing for an injected double error")
      fwrite(a, 64'h1); fread(a); drain(8);                 // full rewrite heals it
    end
    // partial write with an armed mask: the merged word is what gets corrupted
    begin
      bit [11:0] a = 12'h200;
      fwrite(a, 64'h1122_3344_5566_7788);
      inject(72'h1 << 11);
      fwrite(a, 64'hFFFF_FFFF_FFFF_FFFF, 8'h0F);
      fread(a); drain(8);
    end
  endtask
endclass

// ---- T9: traffic hammering the window under test (reads, full writes, partial writes)
class sg_hammer_test extends sg_base_test;
  `uvm_component_utils(sg_hammer_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    int w0;
    env.bring_up();
    sg_vseq_lib::fill(env.func);
    w0 = bd.cnt(C_WIN);
    start_traffic(20, 60, 40, 0, DEPTH - 1, 90);
    env.wait_cycles(plus("CYCLES", 150000));
    stop_traffic();
    `uvm_info("HAMMER", $sformatf("windows completed under fire: %0d", bd.cnt(C_WIN) - w0), UVM_LOW)
    if (bd.cnt(C_WIN) == w0) `uvm_error("PROGRESS", "no window completed")
    sg_vseq_lib::read_all(env.func);
    drain();
  endtask
endclass

// ---- T10: TEST_MIN_BW progress guarantee at full load (spec 6.5), including a hot-word hammer
class sg_minbw_test extends sg_base_test;
  `uvm_component_utils(sg_minbw_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  task windows_in(int cycles, output int n);
    int w0 = bd.cnt(C_WIN);
    env.wait_cycles(cycles);
    n = bd.cnt(C_WIN) - w0;
  endtask

  task body();
    int n, K;
    sg_hot_word_seq hs;
    env.bring_up();
    // K = 0: no guarantee, a fully loaded port may starve the test
    env.apb.write(8'h0C, 0);
    start_traffic(0, 40, 30);
    windows_in(20000, n);
    `uvm_info("MINBW", $sformatf("K=0: %0d windows in 20000 cycles at full load", n), UVM_LOW)
    stop_traffic();
    // K > 0: every window must complete
    K = plus("K", 4);
    env.apb.write(8'h0C, K);
    start_traffic(0, 40, 30);
    windows_in(60000, n);
    `uvm_info("MINBW", $sformatf("K=%0d: %0d windows in 60000 cycles at full load", K, n), UVM_LOW)
    if (n == 0) `uvm_error("PROGRESS", "TEST_MIN_BW > 0 but no window completed at full load")
    stop_traffic();
    // worst case: every cycle is a request to the first word the next window will capture
    hs = sg_hot_word_seq::type_id::create("hs");
    hs.addr = 12'((bd.sc_base() + 1) * 8); hs.n_items = 1 << 30; hs.wr_pct = 50; hs.part_pct = 0;
    fork hs.start(env.func.sqr); join_none
    windows_in(40000, n);
    `uvm_info("MINBW", $sformatf("K=%0d, hot-word hammer: %0d windows in 40000 cycles", K, n), UVM_LOW)
    if (n == 0) `uvm_error("PROGRESS", "hot-word hammer starves the window engine despite TEST_MIN_BW")
    hs.stop_req = 1; hs.wait_for_sequence_state(UVM_FINISHED);
    drain();
  endtask
endclass

// ---- T3 (E1): power-on fault-model campaign against the March reference model
class sg_poweron_cov_test extends sg_base_test;
  `uvm_component_utils(sg_poweron_cov_test)
  int hit [SG_NSUB][4], tot [SG_NSUB][4], disagree;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  task body();
    int per_pair = plus("PER_PAIR", 8);
    int nbg      = plus("NBG", 2);                         // backgrounds 0..nbg-1
    int runs     = (per_pair + 3) / 4;
    sg_fault_item fi [4];
    env.bring_up();
    for (int bg = 0; bg < nbg; bg++)
    for (int k = 0; k < SG_NSUB; k++)
      for (int a = 0; a < 4; a++)
        for (int r = 0; r < runs; r++) begin
          int n = (r == runs - 1 && per_pair % 4 != 0) ? per_pair % 4 : 4;
          env.fc.clear();
          for (int f = 0; f < n; f++) begin
            // victims in disjoint 128-row blocks; aggressor on either side of the victim
            int vr = f * 128 + $urandom_range(20, 100);
            int vc = $urandom_range(0, 7), vb = $urandom_range(0, 73);
            int ar = (f % 2 == 0) ? vr + $urandom_range(10, 18) : vr - $urandom_range(10, 18);
            int ac = $urandom_range(0, 7);
            if (r == 0 && f == 3) vr = 512 + $urandom_range(0, 1);          // spare rows are tested too
            if (vr >= 512) ar = vr ^ 1;
            fi[f] = sg_fault_item::type_id::create("fi");
            fi[f] = sg_fault_item::from_sub(k, vr, vc, vb, ar, ac, (k == 4) ? vb : $urandom_range(0, 73));
            env.fc.apply(fi[f]);
            env.cov.sample_loc(vr, vb);
          end
          env.run_maint(a, bg);
          for (int f = 0; f < n; f++) begin
            int pred;
            bit seen;
            pred = env.march.predict_poweron(fi[f], a, bg);
            seen = bd.flog_has(fi[f].vr, -1) || (k == 4 && bd.flog_has(fi[f].ar, -1));
            tot[k][a]++; if (seen) hit[k][a]++;
            env.cov.sample_fault(k, a, 0);
            if (pred == 2 && !seen)
              `uvm_error("CHK-3", $sformatf("%s / %s bg%0d: model says detected, DUT missed %s", sg_sub_name(k), sg_alg_name(a), bg, fi[f].convert2string()))
            if (pred == 0 && seen) begin
              disagree++;
              `uvm_error("MODEL", $sformatf("%s / %s bg%0d: DUT logged a fault the model says is invisible: %s", sg_sub_name(k), sg_alg_name(a), bg, fi[f].convert2string()))
            end
          end
        end
    env.fc.clear();
    `uvm_info("COVMATRIX", "power-on detected/injected per algorithm (spec 4.2 claim marked *)", UVM_LOW)
    for (int k = 0; k < SG_NSUB; k++)
      `uvm_info("COVMATRIX", $sformatf("%-8s %5d/%-3d%s %5d/%-3d%s %5d/%-3d%s %5d/%-3d%s", sg_sub_name(k),
        hit[k][0], tot[k][0], sg_march_model::spec_covers(sg_march_model::sub_class(k), 0) ? "*" : " ",
        hit[k][1], tot[k][1], sg_march_model::spec_covers(sg_march_model::sub_class(k), 1) ? "*" : " ",
        hit[k][2], tot[k][2], sg_march_model::spec_covers(sg_march_model::sub_class(k), 2) ? "*" : " ",
        hit[k][3], tot[k][3], sg_march_model::spec_covers(sg_march_model::sub_class(k), 3) ? "*" : " "), UVM_LOW)
  endtask
endclass

// ---- E2/CHK-3: online detection of every sub-model within one sweep, predicted from live data
class sg_online_cov_test extends sg_base_test;
  `uvm_component_utils(sg_online_cov_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function bit cw_bit(int row, int col, int b);
    bit [71:0] cw;
    cw = sg_ecc_ref_pkg::ref_encode(env.gold.mem[row * 8 + col]);
    return cw[b];
  endfunction

  task body();
    int algs  = plus("NALG", 4);
    int idle  = plus("IDLE", 100);               // 100 = no functional traffic
    int subs_per = plus("SUBS", SG_NSUB);
    int ok = 0, miss = 0, n_pred_det = 0, escalated = 0;
    int a0 = plus("A0", 0);
    for (int a = a0; a < algs; a++)
      for (int k = 0; k < subs_per; k++) begin
        sg_fault_item f;
        int vr, vc, vb, ar, ac, dr, sw0, t = 0, tmax;
        bit pred, pred_any, seen = 0, cv, ca;
        int ce0;
        env.bring_up();
        env.apb.write(8'h04, (1 << 10) | (1 << 8) | (1 << 4) | a);       // online algorithm = a
        sg_vseq_lib::fill(env.func);
        vr = $urandom_range(50, 440); vc = $urandom_range(0, 7); vb = $urandom_range(0, 71);
        dr = $urandom_range(0, 2) - 1;                                   // aggressor in row vr-1, vr, vr+1
        ar = vr + dr; ac = $urandom_range(0, 7);
        if (ar == vr && ac == vc) ac = (vc + 1) % 8;
        f = sg_fault_item::from_sub(k, vr, vc, vb, ar, ac, vb);
        f.act_rel = 20;
        cv = cw_bit(vr, vc, vb); ca = cw_bit(ar, ac, vb);
        env.march.predict_online(f, a, cv, ca, pred, pred_any);
        sw0 = bd.cnt(C_SWEEP); ce0 = bd.cnt(C_CE);
        env.sb.chk5_en = !(k == 4 && ar != vr);       // alias in the neighbouring row: outside one window (spec 6.6)
        env.fc.apply(f);
        env.cov.sample_loc(vr, vb);
        `uvm_info("ONLINECASE", $sformatf("%s / %s: %s predicted all=%0b any=%0b c_v=%0b c_a=%0b", sg_sub_name(k), sg_alg_name(a), f.convert2string(), pred, pred_any, cv, ca), UVM_MEDIUM)
        if (idle < 100) start_traffic(idle, 0, 0);                        // reads only; read-destructive faults need none
        tmax = 400000 + (90000 * 100) / idle;
        while (t < tmax && bd.cnt(C_SWEEP) - sw0 <= 1) begin
          @(posedge vif.clk); t++;
          if (bd.flog_has(vr, vb) || (k == 4 && bd.flog_has(ar, vb))) begin seen = 1; break; end
        end
        if (idle < 100) stop_traffic();
        env.sb.chk5_en = 1;
        env.cov.sample_fault(k, a, 1);
        if (pred_any) n_pred_det++;
        if (pred && !seen) begin
          miss++;
          `uvm_error("CHK-3", $sformatf("online %s / %s: model predicts detection within one sweep, DUT missed %s (c_v=%0b c_a=%0b)",
                     sg_sub_name(k), sg_alg_name(a), f.convert2string(), cv, ca))
        end else if (!pred_any && seen && bd.cnt(C_CE) > ce0) begin
          // not visible to this algorithm, but the fault keeps producing correctable errors; the
          // repeat-CE table escalates the row to March SS (spec 7.4)
          escalated++;
          `uvm_info("ONLINECOV", $sformatf("%s / %s detected through CE-history escalation (spec 7.4)", sg_sub_name(k), sg_alg_name(a)), UVM_LOW)
        end else if (!pred_any && seen)
          `uvm_error("MODEL", $sformatf("online %s / %s: DUT detected a fault the model says is invisible: %s", sg_sub_name(k), sg_alg_name(a), f.convert2string()))
        else ok++;
        env.fc.clear();
      end
    `uvm_info("ONLINECOV", $sformatf("%0d agree with the model (%0d predicted detectable), %0d CE-escalated, %0d misses", ok, n_pred_det, escalated, miss), UVM_LOW)
  endtask
endclass

// ---- BIRA: random fault maps vs the brute-force model, memory re-verified end to end
class sg_repair_test extends sg_base_test;
  `uvm_component_utils(sg_repair_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    int ncase = plus("CASES", 24);
    for (int c = 0; c < ncase; c++) begin
      int rows_pool [4], ios_pool [4];
      int rows[$], ios[$], kind, ncell;
      bit exp_ok, must = 0;
      int rcnt [int], icnt [int];
      env.reset_dut(); env.fc.clear();
      foreach (rows_pool[i]) begin rows_pool[i] = 30 + 60 * i + $urandom_range(0, 40); ios_pool[i] = $urandom_range(0, 71); end
      ncell = $urandom_range(1, 7);
      // the first four cases are directed so every BIRA outcome and location class is hit:
      //   0 rows only, no must-repair (two rows with two bad IOs each, four distinct IOs:
      //     2 spare rows cost 2, 1 row + 2 IOs costs 3, IOs alone need 4)
      //   1 unrepairable (three rows with three bad IOs each)
      //   2 array edge rows 0 / 511, faults in every IO group incl. the spare IO columns
      //   3 window-boundary rows 1 / 510, same
      //   (cases 2 and 3 put >2 faults in each row so both are row-repaired and the spare-IO
      //    column faults are retired with their row)
      if (c < 4) begin
        int dr [$], dio [$];
        case (c)
          0: begin dr = '{50, 50, 150, 150};  dio = '{3, 10, 20, 30}; end
          1: begin dr = '{60, 60, 60, 160, 160, 160, 260, 260, 260}; dio = '{1, 2, 3, 4, 5, 6, 7, 8, 9}; end
          2: begin dr = '{0, 0, 0, 0, 0, 511, 511, 511};  dio = '{8, 20, 40, 56, 72, 70, 30, 73}; end
          default: begin dr = '{1, 1, 1, 1, 1, 510, 510, 510}; dio = '{20, 8, 50, 66, 72, 40, 60, 73}; end
        endcase
        foreach (dr[j]) begin
          rows.push_back(dr[j]); ios.push_back(dio[j]);
          void'(env.fc.add(FT_SAF, dr[j], j % 8, dio[j], .val(1)));
          env.cov.sample_loc(dr[j], dio[j]);
        end
        ncell = 0;
      end
      for (int i = 0; i < ncell; i++) begin
        int r = rows_pool[$urandom_range(0, 3)], io = ios_pool[$urandom_range(0, 3)];
        bit dup = 0;
        foreach (rows[j]) if (rows[j] == r && ios[j] == io) dup = 1;
        if (dup) continue;
        rows.push_back(r); ios.push_back(io);
        void'(env.fc.add(FT_SAF, r, $urandom_range(0, 7), io, .val(1)));
        env.cov.sample_loc(r, io);
      end
      foreach (rows[i]) begin rcnt[rows[i]] = 0; icnt[ios[i]] = 0; end
      foreach (rows[i]) begin rcnt[rows[i]]++; icnt[ios[i]]++; end
      foreach (rcnt[r]) if (rcnt[r] > 2) must = 1;          // a row with more failing IOs than spare IOs
      foreach (icnt[i]) if (icnt[i] > 2) must = 1;          // an IO failing in more rows than spare rows
      exp_ok = env.bira.repairable(rows, ios, kind);
      env.release_reset(); env.wait_online();
      if (bd.repair_ok() !== exp_ok || bd.repair_fail() !== !exp_ok)
        `uvm_error("BIRA", $sformatf("case %0d: DUT ok=%0b fail=%0b, brute force says repairable=%0b (%0d cells)", c, bd.repair_ok(), bd.repair_fail(), exp_ok, rows.size()))
      env.cov.sample_bira(!exp_ok ? 4 : (must ? 3 : (kind == 1 ? 0 : (kind == 2 ? 1 : 2))));
      if (c == 0) begin
        bit [37:0] s = bd.rm_sig();
        if (!(exp_ok && !must && kind == 1))
          `uvm_error("BIRA", $sformatf("case 0 is meant to be rows-only: model ok=%0b must=%0b kind=%0d", exp_ok, must, kind))
        if (!s[9] || !s[19] || s[27] || s[35])
          `uvm_error("BIRA", $sformatf("case 0: DUT should use both spare rows and no spare IO, sig=%h", s))
      end
      if (exp_ok) begin
        env.sb.expect_no_ce = 1;
        sg_vseq_lib::read_all(env.func);                    // repaired memory needs no ECC help
        for (int i = 0; i < 32; i++) begin
          bit [11:0] a = 12'($urandom_range(0, DEPTH - 1));
          fwrite(a, {$urandom, $urandom}); fread(a);
        end
        drain();
        env.sb.expect_no_ce = 0;
      end
    end
  endtask
endclass

// ---- saved repair signature reloaded at reset (spec 10.4)
class sg_fuse_test extends sg_base_test;
  `uvm_component_utils(sg_fuse_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    bit [31:0] lo, hi;
    bit [37:0] sig;
    int t = 0;
    env.reset_dut(); env.fc.clear();
    void'(env.fc.add(FT_SAF, 77, 1, 12, .val(1)));
    void'(env.fc.add(FT_SAF, 200, 5, 12, .val(0)));
    void'(env.fc.add(FT_SAF, 301, 2, 40, .val(1)));
    env.release_reset(); env.wait_online();
    if (!bd.repair_ok()) `uvm_error("BIRA", "repairable map reported REPAIR_FAIL")
    env.apb.read(8'h18, lo); env.apb.read(8'h1C, hi);
    sig = {hi[5:0], lo};
    if (sig !== bd.rm_sig()) `uvm_error("CSR", "REPAIR_SIG export differs from the remap register")
    // reset with the saved signature: no destructive test, only the zero fill
    env.reset_dut(1, sig);
    env.release_reset();
    while (bd.mode() != int'(MODE_ONLINE) && t < 20000) begin @(posedge vif.clk); t++; end
    if (t >= 20000) `uvm_error("FUSE", "reload boot did not finish quickly")
    `uvm_info("FUSE", $sformatf("reload boot took %0d cycles", t), UVM_LOW)
    env.wait_cycles(4);
    if (bd.rm_sig() !== sig) `uvm_error("FUSE", "signature not reloaded")
    env.sb.expect_no_ce = 1;
    sg_vseq_lib::read_all(env.func);
    drain();
  endtask
endclass

// ---- CSR: counters freeze, register read-back, unused offsets
class sg_csr_test extends sg_base_test;
  `uvm_component_utils(sg_csr_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    bit [31:0] a, b, d;
    env.bring_up();
    env.apb.write(8'h0C, 32'h12);  env.apb.read(8'h0C, d); if (d !== 32'h12) `uvm_error("CSR", "TEST_MIN_BW read-back")
    env.apb.write(8'h10, 32'h40);  env.apb.read(8'h10, d); if (d !== 32'h40) `uvm_error("CSR", "SCRUB_PERIOD read-back")
    env.apb.write(8'h14, 32'h3);   env.apb.read(8'h14, d); if (d !== 32'h3)  `uvm_error("CSR", "CE_REPEAT_TH read-back")
    env.apb.write(8'h0C, 0); env.apb.write(8'h10, 0);
    // FREEZE: counters stop, traffic keeps going
    env.apb.write(8'h00, env.ctrl_val | 32'h80);
    env.apb.read(8'h9C, a);                                // C_CYC
    env.wait_cycles(200);
    env.apb.read(8'h9C, b);
    if (a !== b) `uvm_error("CSR", "counters moved while FREEZE is set")
    env.apb.write(8'h00, env.ctrl_val);
    env.wait_cycles(50);
    env.apb.read(8'h9C, b);
    if (a === b) `uvm_error("CSR", "counters did not resume after FREEZE")
    // IRQ_STAT write-1-clear
    env.apb.read(8'hC0, d);
    env.apb.write(8'hC0, 32'hF);
    env.apb.read(8'hC0, d);
    if (d[2:0] !== 0 && !vif.irq_done) `uvm_error("CSR", "IRQ_STAT W1C did not clear")
    // BYPASS: all test logic idle
    begin
      int w0 = bd.cnt(C_WIN);
      env.apb.write(8'h00, env.ctrl_val | 32'h20);
      env.wait_cycles(300);
      w0 = bd.cnt(C_WIN);
      start_traffic(50, 40, 30);
      env.wait_cycles(3000);
      stop_traffic();
      if (bd.cnt(C_WIN) != w0) `uvm_error("BYPASS", "windows ran in BYPASS mode")
      env.apb.read(8'h08, d);
      if (d[1:0] != int'(MODE_BYPASS)) `uvm_error("BYPASS", "STATUS.mode does not report BYPASS")
      env.apb.write(8'h00, env.ctrl_val);
    end
  endtask
endclass

// ---- spec 6.6 residual risk, measured: a decoder fault whose alias lies outside the window
class sg_af_hazard_test extends sg_base_test;
  `uvm_component_utils(sg_af_hazard_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    int corrupted = 0, n = plus("N", 6);
    env.bring_up();
    sg_vseq_lib::fill(env.func);
    env.sb.chk5_en = 0;
    for (int i = 0; i < n; i++) begin
      int vr = 40 + 50 * i, ar = vr + 200;
      int a = ar * 8 + 3;
      void'(env.fc.add(FT_AF, vr, 2, 9, ar, 3, 9));
      `uvm_info("AFHAZ", $sformatf("decoder fault: row %0d also writes row %0d", vr, ar), UVM_LOW)
    end
    env.wait_windows(520);
    for (int i = 0; i < n; i++) begin
      int a = (40 + 50 * i + 200) * 8 + 3;
      if (!bd.holds(a, env.gold.mem[a])) corrupted++;
    end
    `uvm_info("AFHAZ", $sformatf("%0d of %0d alias words no longer hold their data after one sweep (documented residual risk, spec 6.6)", corrupted, n), UVM_LOW)
    env.fc.clear();
    env.sb.en = 0;
  endtask
endclass

// ---- decoder fault whose alias lies INSIDE the window under test: the window's own ~c writes to
// the victim clobber the alias word.  Data must still be intact once the window is released.
class sg_af_inwindow_test extends sg_base_test;
  `uvm_component_utils(sg_af_inwindow_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    int n = plus("N", 8);
    env.bring_up();
    sg_vseq_lib::fill(env.func);
    for (int i = 0; i < n; i++) begin
      // alias in the victim's own row: it is inside every window that contains the victim.  (An
      // alias in the neighbouring row is outside one of the two windows: spec 6.6 residual risk,
      // measured by sg_af_hazard_test.)
      int vr = 60 + 40 * i, ar, vc = $urandom_range(0, 7), ac = $urandom_range(0, 7);
      ar = vr; if (ac == vc) ac = (vc + 1) % 8;
      void'(env.fc.add(FT_AF, vr, vc, 9, ar, ac, 9));
      `uvm_info("AFWIN", $sformatf("decoder fault: row %0d col %0d also writes row %0d col %0d", vr, vc, ar, ac), UVM_LOW)
    end
    env.wait_windows(1100);                                  // two sweeps with the faults present
    sg_vseq_lib::read_all(env.func);                         // any silently corrupted word fails the scoreboard
    drain();
    `uvm_info("AFWIN", $sformatf("hard faults logged %0d, repairs %0d, spares used %0d", bd.cnt(C_HARD), bd.cnt(C_REPAIR),
              int'(bd.rm_valid(0)) + int'(bd.rm_valid(1))), UVM_LOW)
  endtask
endclass
