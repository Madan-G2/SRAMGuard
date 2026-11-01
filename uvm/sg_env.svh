// ---------------------------------------------------------------------------------------------
// sg_golden_mem: shadow of the logical contents, updated on every accepted write (spec 10.2).
// ---------------------------------------------------------------------------------------------
class sg_golden_mem extends uvm_component;
  `uvm_component_utils(sg_golden_mem)
  bit [63:0] mem [0:DEPTH-1];
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void clear();
    for (int i = 0; i < DEPTH; i++) mem[i] = '0;      // RESET_TEST / MAINT end with a zero fill
  endfunction
  static function bit [63:0] merge(bit [63:0] o, bit [63:0] n, bit [7:0] be);
    bit [63:0] r;
    for (int i = 0; i < 8; i++) r[8*i +: 8] = be[i] ? n[8*i +: 8] : o[8*i +: 8];
    return r;
  endfunction
endclass

// ---------------------------------------------------------------------------------------------
// sg_scoreboard: CHK-1 data integrity, CHK-2 no silent corruption, CHK-5 transparency.
// ---------------------------------------------------------------------------------------------
`uvm_analysis_imp_decl(_acc)
`uvm_analysis_imp_decl(_rsp)

class sg_scoreboard extends uvm_component;
  `uvm_component_utils(sg_scoreboard)
  uvm_analysis_imp_acc #(sg_func_txn, sg_scoreboard) acc_imp;
  uvm_analysis_imp_rsp #(sg_func_txn, sg_scoreboard) rsp_imp;
  sg_golden_mem    gold;
  virtual sg_if    vif;
  virtual sg_bd_if bd;

  typedef struct { bit we; bit part; bit [11:0] addr; bit [63:0] exp; bit [63:0] old; bit [63:0] nw; } pend_t;
  pend_t q [$];
  bit    ue_ok [bit [11:0]];          // words that are truly uncorrectable (injected double errors)
  bit    en = 1;
  bit    expect_no_ce = 0;
  bit    chk5_en = 1;
  int    n_rd, n_wr, n_ce, n_ue, n_chk5, n_chk5_fail;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    acc_imp = new("acc_imp", this); rsp_imp = new("rsp_imp", this);
    if (!uvm_config_db#(virtual sg_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "sg_if not set")
    if (!uvm_config_db#(virtual sg_bd_if)::get(this, "", "bd", bd)) `uvm_fatal("NOBD", "sg_bd_if not set")
  endfunction

  function void allow_ue(bit [11:0] a); ue_ok[a] = 1; endfunction
  function void flush(); q.delete(); endfunction

  function void write_acc(sg_func_txn t);
    pend_t p;
    p.we = t.we; p.part = t.partial(); p.addr = t.addr;
    p.old = gold.mem[t.addr];
    if (!t.we) begin
      p.exp = gold.mem[t.addr]; n_rd++;
    end else begin
      p.nw = sg_golden_mem::merge(gold.mem[t.addr], t.data, t.be);
      gold.mem[t.addr] = p.nw; p.exp = p.nw; n_wr++;
      if (!t.partial()) ue_ok.delete(t.addr);          // a full write replaces a poisoned word
    end
    q.push_back(p);
  endfunction

  function void write_rsp(sg_func_txn r);
    pend_t p;
    if (!en) return;
    if (q.size() == 0) begin `uvm_error("SB", "response without a request") return; end
    p = q.pop_front();
    if (r.ce) n_ce++;
    if (r.ue) n_ue++;
    if (r.ce && r.ue) `uvm_error("SB", $sformatf("CE and UE both set at %03h", p.addr))
    if (expect_no_ce && r.ce) `uvm_error("SB", $sformatf("unexpected rsp_ce at %03h", p.addr))
    if (!p.we) begin
      if (r.ue) begin
        if (!ue_ok.exists(p.addr))
          `uvm_error("CHK-1", $sformatf("rsp_ue at %03h without a truly uncorrectable word", p.addr))
      end else if (r.rdata !== p.exp)
        `uvm_error(r.ce ? "CHK-1" : "CHK-2",
                   $sformatf("read %03h returned %016h expected %016h (ce=%0b ue=%0b)%s", p.addr, r.rdata, p.exp,
                             r.ce, r.ue, r.ce ? "" : "  SILENT CORRUPTION"))
    end else if (p.part) begin
      if (r.ue) begin
        // the RMW refused to merge with garbage: nothing was written (REQ-ECC-2)
        if (!ue_ok.exists(p.addr))
          `uvm_error("CHK-1", $sformatf("partial write %03h flagged UE on a healthy word", p.addr))
        if (gold.mem[p.addr] === p.nw) gold.mem[p.addr] = p.old;
      end
    end else if (r.ue || r.ce)
      `uvm_error("SB", $sformatf("full write %03h answered with ce=%0b ue=%0b", p.addr, r.ce, r.ue))
  endfunction

  // CHK-5: after every online window the 16 words of that window read back as golden
  task run_phase(uvm_phase phase);
    forever begin
      @(negedge vif.clk);
      if (vif.rst_n && chk5_en && bd.win_done() && !bd.rmw_busy() && bd.mode() == int'(MODE_ONLINE)) begin
        n_chk5++;
        for (int w = 0; w < 16; w++) begin
          int a;
          a = (bd.win_base() << 3) + w;
          if (ue_ok.exists(12'(a))) continue;
          if (!bd.holds(a, gold.mem[a]) && !bd.ue_seen()) begin
            n_chk5_fail++;
            `uvm_error("CHK-5", $sformatf("array word %03h differs from golden after window at row %0d", a, bd.win_base()))
          end
        end
      end
    end
  endtask

  function void check_phase(uvm_phase phase);
    if (q.size() != 0) `uvm_warning("SB", $sformatf("%0d requests still waiting for a response at end of test", q.size()))
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf("reads %0d writes %0d ce %0d ue %0d | CHK-5 windows %0d failures %0d",
                              n_rd, n_wr, n_ce, n_ue, n_chk5, n_chk5_fail), UVM_LOW)
  endfunction
endclass

// ---------------------------------------------------------------------------------------------
// sg_irq_monitor: every interrupt must follow a real event, and may only fall after a W1C write.
// ---------------------------------------------------------------------------------------------
class sg_irq_monitor extends uvm_component;
  `uvm_component_utils(sg_irq_monitor)
  virtual sg_if    vif;
  virtual sg_bd_if bd;
  int n_rise [4];
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual sg_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "sg_if not set")
    if (!uvm_config_db#(virtual sg_bd_if)::get(this, "", "bd", bd)) `uvm_fatal("NOBD", "sg_bd_if not set")
  endfunction
  task run_phase(uvm_phase phase);
    logic [3:0] prev = '0, cur;
    logic [3:0] cause_h [4];          // cause history (this cycle and the three before)
    logic [3:0] w1c_h   [4];
    string nm [4] = '{"irq_ue", "irq_hard", "irq_repair", "irq_done"};
    foreach (cause_h[i]) begin cause_h[i] = '0; w1c_h[i] = '0; end
    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) begin prev = '0; continue; end
      for (int i = 3; i > 0; i--) begin cause_h[i] = cause_h[i-1]; w1c_h[i] = w1c_h[i-1]; end
      cause_h[0] = bd.irq_cause(); w1c_h[0] = bd.irq_w1c();
      cur = {vif.irq_done, vif.irq_repair, vif.irq_hard, vif.irq_ue};
      for (int i = 0; i < 4; i++) begin
        if (cur[i] && !prev[i]) begin
          n_rise[i]++;
          if (!(cause_h[0][i] | cause_h[1][i] | cause_h[2][i] | cause_h[3][i]))
            `uvm_error("IRQ", $sformatf("%s rose without a cause", nm[i]))
        end
        if (!cur[i] && prev[i] && !(w1c_h[0][i] | w1c_h[1][i] | w1c_h[2][i]))
          `uvm_error("IRQ", $sformatf("%s fell without a W1C write", nm[i]))
      end
      prev = cur;
    end
  endtask
endclass

// ---------------------------------------------------------------------------------------------
// sg_fault_ctrl: owns the fault list of the SRAM model (spec 4.3, 10.2).
// ---------------------------------------------------------------------------------------------
class sg_fault_ctrl extends uvm_component;
  `uvm_component_utils(sg_fault_ctrl)
  virtual sg_bd_if bd;
  sg_fault_list    list;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual sg_bd_if)::get(this, "", "bd", bd)) `uvm_fatal("NOBD", "sg_bd_if not set")
    if (!uvm_config_db#(sg_fault_list)::get(this, "", "fault_list", list)) list = sg_fault_list::type_id::create("fl");
  endfunction

  function void apply(sg_fault_item f);
    f.handle = bd.inject(int'(f.ftype), f.vr, f.vc, f.vb, f.ar, f.ac, f.ab, f.pol, f.val, bd.now() + f.act_rel);
    list.items.push_back(f);
  endfunction

  function sg_fault_item add(sg_ftype_e t, int vr, vc, vb, int ar = 0, ac = 0, ab = 0,
                             bit pol = 0, bit val = 0, longint act_rel = 0);
    sg_fault_item f = sg_fault_item::type_id::create("f");
    f.ftype = t; f.vr = vr; f.vc = vc; f.vb = vb; f.ar = ar; f.ac = ac; f.ab = ab;
    f.pol = pol; f.val = val; f.act_rel = act_rel;
    apply(f);
    return f;
  endfunction

  function void clear();
    bd.clear_faults();
    list.items.delete();
  endfunction

  function bit activated(sg_fault_item f); return f.handle >= 0 && bd.fired(f.handle); endfunction
endclass

// ---------------------------------------------------------------------------------------------
// sg_coverage: functional coverage (spec 10.5).
// ---------------------------------------------------------------------------------------------
class sg_coverage extends uvm_component;
  `uvm_component_utils(sg_coverage)
  uvm_analysis_imp_acc #(sg_func_txn, sg_coverage) acc_imp;
  uvm_analysis_imp_rsp #(sg_func_txn, sg_coverage) rsp_imp;
  virtual sg_if    vif;
  virtual sg_bd_if bd;

  int c_type, c_ws, c_stall, c_src, c_out, c_sub, c_alg, c_mode, c_rowc, c_iog, c_bira;

  covergroup cg_access;
    cp_type: coverpoint c_type { bins rd = {0}; bins wr_full = {1}; bins wr_part = {2}; }
    cp_ws:   coverpoint c_ws   { bins outside = {WS_OUT}; bins pol0 = {WS_POL0}; bins pol1 = {WS_POL1};
                                 bins repair_copy = {WS_REPAIR}; bins capture_pending = {WS_PEND}; }
    x_acc:   cross cp_type, cp_ws;
  endgroup

  covergroup cg_ecc;
    cp_src: coverpoint c_src { bins functional = {0}; bins capture = {1}; }
    cp_out: coverpoint c_out { bins none = {0}; bins ce = {1}; bins ue = {2}; }
    x_ecc:  cross cp_src, cp_out;
  endgroup

  covergroup cg_stall;
    cp_s: coverpoint c_stall { bins s0 = {0}; bins s1 = {1}; bins s2 = {2}; illegal_bins over = {[3:$]}; }
  endgroup

  covergroup cg_fault;
    cp_sub:  coverpoint c_sub  { bins m[] = {[0:SG_NSUB-1]}; }
    cp_alg:  coverpoint c_alg  { bins a[] = {[0:3]}; }
    cp_mode: coverpoint c_mode { bins poweron = {0}; bins online = {1}; }
    x_fault: cross cp_sub, cp_alg, cp_mode;
  endgroup

  covergroup cg_loc;
    cp_row: coverpoint c_rowc { bins regular = {0}; bins edge_row = {1}; bins window_boundary = {2}; bins spare = {3}; }
    cp_io:  coverpoint c_iog  { bins data0 = {0}; bins data1 = {1}; bins data2 = {2}; bins data3 = {3};
                                bins ecc = {4}; bins spare_io = {5}; }
    x_loc:  cross cp_row, cp_io;
  endgroup

  covergroup cg_bira;
    cp_b: coverpoint c_bira { bins rows_only = {0}; bins ios_only = {1}; bins mixed = {2};
                              bins must_repair = {3}; bins fail = {4}; }
  endgroup

  function new(string name, uvm_component parent);
    super.new(name, parent);
    cg_access = new(); cg_ecc = new(); cg_stall = new(); cg_fault = new(); cg_loc = new(); cg_bira = new();
  endfunction
  function void build_phase(uvm_phase phase);
    acc_imp = new("acc_imp", this); rsp_imp = new("rsp_imp", this);
    if (!uvm_config_db#(virtual sg_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "sg_if not set")
    if (!uvm_config_db#(virtual sg_bd_if)::get(this, "", "bd", bd)) `uvm_fatal("NOBD", "sg_bd_if not set")
  endfunction

  function void write_acc(sg_func_txn t);
    c_type = !t.we ? 0 : (t.partial() ? 2 : 1);
    c_ws = int'(t.wstate);
    c_stall = t.stall;
    cg_access.sample(); cg_stall.sample();
  endfunction
  function void write_rsp(sg_func_txn r);
    c_src = 0; c_out = r.ue ? 2 : (r.ce ? 1 : 0);
    cg_ecc.sample();
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.clk);
      if (vif.rst_n && bd.cap_v()) begin
        c_src = 1; c_out = bd.cap_ue() ? 2 : (bd.cap_ce() ? 1 : 0);
        cg_ecc.sample();
      end
    end
  endtask

  function void sample_fault(int sub, int alg, int online);
    c_sub = sub; c_alg = alg; c_mode = online;
    cg_fault.sample();
  endfunction
  function void sample_loc(int vr, int vb);
    c_rowc = (vr >= 512) ? 3 : (vr == 0 || vr == 511) ? 1 : (vr == 1 || vr == 510) ? 2 : 0;
    c_iog  = (vb >= 72) ? 5 : (vb >= 64) ? 4 : vb / 16;
    cg_loc.sample();
  endfunction
  function void sample_bira(int kind);
    c_bira = kind; cg_bira.sample();
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf("access %.1f%% ecc %.1f%% stall %.1f%% fault %.1f%% loc %.1f%% bira %.1f%%",
              cg_access.get_coverage(), cg_ecc.get_coverage(), cg_stall.get_coverage(),
              cg_fault.get_coverage(), cg_loc.get_coverage(), cg_bira.get_coverage()), UVM_LOW)
  endfunction
endclass

// ---------------------------------------------------------------------------------------------
// sg_env
// ---------------------------------------------------------------------------------------------
class sg_env extends uvm_env;
  `uvm_component_utils(sg_env)
  sg_func_agent   func;
  sg_apb_agent    apb;
  sg_golden_mem   gold;
  sg_scoreboard   sb;
  sg_irq_monitor  irqm;
  sg_fault_ctrl   fc;
  sg_coverage     cov;
  sg_march_model  march;
  sg_bira_model   bira;
  virtual sg_if    vif;
  virtual sg_bd_if bd;

  bit [31:0] ctrl_val = 32'h1F;        // TEST SCRUB REPAIR ONLINE_REPAIR SEG_OVERLAP

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function void build_phase(uvm_phase phase);
    func = sg_func_agent::type_id::create("func", this);
    apb  = sg_apb_agent::type_id::create("apb", this);
    gold = sg_golden_mem::type_id::create("gold", this);
    sb   = sg_scoreboard::type_id::create("sb", this);
    irqm = sg_irq_monitor::type_id::create("irqm", this);
    fc   = sg_fault_ctrl::type_id::create("fc", this);
    cov  = sg_coverage::type_id::create("cov", this);
    march = sg_march_model::type_id::create("march");
    bira  = sg_bira_model::type_id::create("bira");
    if (!uvm_config_db#(virtual sg_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "sg_if not set")
    if (!uvm_config_db#(virtual sg_bd_if)::get(this, "", "bd", bd)) `uvm_fatal("NOBD", "sg_bd_if not set")
  endfunction

  function void connect_phase(uvm_phase phase);
    sb.gold = gold;
    func.mon.acc_ap.connect(sb.acc_imp);
    func.mon.rsp_ap.connect(sb.rsp_imp);
    func.mon.acc_ap.connect(cov.acc_imp);
    func.mon.rsp_ap.connect(cov.rsp_imp);
  endfunction

  // ---- bring-up helpers shared by the tests
  task reset_dut(bit fv = 0, bit [37:0] fs = '0);
    @(negedge vif.clk);
    vif.rst_n = 0; vif.fuse_vld = fv; vif.fuse_sig = fs;
    sb.flush(); sb.ue_ok.delete();
    gold.clear();
    repeat (6) @(posedge vif.clk);
  endtask
  task release_reset();
    @(negedge vif.clk); vif.rst_n = 1;
  endtask
  task wait_online(int timeout = 400000);
    int t = 0;
    while (bd.mode() != int'(MODE_ONLINE) && t < timeout) begin @(posedge vif.clk); t++; end
    if (t >= timeout) `uvm_error("ENV", "timeout waiting for ONLINE")
    repeat (4) @(posedge vif.clk);
  endtask
  task wait_cycles(int n); repeat (n) @(posedge vif.clk); endtask
  task wait_windows(int n, int timeout = 3000000);
    int start, t = 0;
    start = bd.cnt(C_WIN);
    while (bd.cnt(C_WIN) < start + n && t < timeout) begin @(posedge vif.clk); t++; end
    if (t >= timeout) `uvm_error("ENV", $sformatf("timeout waiting for %0d windows", n))
  endtask

  task set_ctrl(bit [31:0] v); ctrl_val = v; apb.write(8'h00, v); endtask
  task set_alg(int online, int poweron, int bg = 0, int diag = 1);
    apb.write(8'h04, (diag << 10) | (bg << 8) | (poweron << 4) | online);
  endtask

  // software-requested destructive March (spec modes: MAINT), ends with a zero fill
  task run_maint(int alg, int bg = 0, int diag = 1);
    int t = 0;
    set_alg(1, alg, bg, diag);
    apb.write(8'h00, ctrl_val | 32'h40);
    while (bd.mode() != int'(MODE_MAINT) && t < 200000) begin @(posedge vif.clk); t++; end
    if (t >= 200000) `uvm_error("ENV", "MAINT never started")
    t = 0;
    while (bd.mode() != int'(MODE_ONLINE) && t < 400000) begin @(posedge vif.clk); t++; end
    if (t >= 400000) `uvm_error("ENV", "MAINT never finished")
    gold.clear(); sb.flush();
    repeat (4) @(posedge vif.clk);
  endtask

  // clean bring-up: reset, power-on test, ONLINE
  task bring_up(bit clear_faults = 1, bit fv = 0, bit [37:0] fs = '0);
    reset_dut(fv, fs);
    if (clear_faults) fc.clear();
    release_reset();
    wait_online();
  endtask
endclass
