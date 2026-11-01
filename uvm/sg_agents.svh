// ---------------------------------------------------------------------------------------------
// sg_func_agent: reads, full writes and partial writes on the valid/ready port (spec 10.2).
// ---------------------------------------------------------------------------------------------
class sg_func_sqr extends uvm_sequencer #(sg_func_item);
  `uvm_component_utils(sg_func_sqr)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass

class sg_func_driver extends uvm_driver #(sg_func_item);
  `uvm_component_utils(sg_func_driver)
  virtual sg_if vif;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual sg_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "sg_if not set")
  endfunction

  task run_phase(uvm_phase phase);
    vif.req_valid <= 1'b0;
    forever begin
      seq_item_port.get_next_item(req);
      // the port is closed outside ONLINE; the request simply waits for req_ready
      repeat (req.gap) begin @(posedge vif.clk); vif.req_valid <= 1'b0; end
      vif.req_valid <= 1'b1; vif.req_we <= req.we; vif.req_addr <= req.addr;
      vif.req_wdata <= req.data; vif.req_be <= req.we ? req.be : 8'hFF;
      do @(posedge vif.clk); while (!(vif.rst_n && vif.req_ready));
      vif.req_valid <= 1'b0;
      seq_item_port.item_done();
    end
  endtask
endclass

class sg_func_monitor extends uvm_monitor;
  `uvm_component_utils(sg_func_monitor)
  virtual sg_if    vif;
  virtual sg_bd_if bd;
  uvm_analysis_port #(sg_func_txn) acc_ap;      // accepted requests
  uvm_analysis_port #(sg_func_txn) rsp_ap;      // responses
  int unsigned stall_hist [0:8];
  int          max_stall = 0;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    acc_ap = new("acc_ap", this); rsp_ap = new("rsp_ap", this);
    if (!uvm_config_db#(virtual sg_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "sg_if not set")
    if (!uvm_config_db#(virtual sg_bd_if)::get(this, "", "bd", bd)) `uvm_fatal("NOBD", "sg_bd_if not set")
  endfunction

  task run_phase(uvm_phase phase);
    int srun = 0;
    forever begin
      @(posedge vif.clk);
      if (!vif.rst_n) begin srun = 0; continue; end
      if (vif.req_valid && vif.req_ready) begin
        sg_func_txn t = sg_func_txn::type_id::create("acc");
        t.we = vif.req_we; t.addr = vif.req_addr; t.data = vif.req_wdata; t.be = vif.req_be;
        t.stall = srun;
        if (srun <= 8) stall_hist[srun]++;
        if (srun > max_stall) max_stall = srun;
        t.wstate = WS_OUT;
        if (bd.f_pend())       t.wstate = WS_PEND;
        else if (bd.f_valid()) t.wstate = bd.rd_act() ? WS_REPAIR : (bd.f_pol() ? WS_POL1 : WS_POL0);
        acc_ap.write(t);
        srun = 0;
      end else if (vif.req_valid && vif.mode_fn_open()) srun++;
      else srun = 0;
      if (vif.rsp_valid) begin
        sg_func_txn r = sg_func_txn::type_id::create("rsp");
        r.rdata = vif.rsp_rdata; r.ce = vif.rsp_ce; r.ue = vif.rsp_ue;
        rsp_ap.write(r);
      end
    end
  endtask
endclass

class sg_func_agent extends uvm_agent;
  `uvm_component_utils(sg_func_agent)
  sg_func_sqr     sqr;
  sg_func_driver  drv;
  sg_func_monitor mon;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    sqr = sg_func_sqr::type_id::create("sqr", this);
    drv = sg_func_driver::type_id::create("drv", this);
    mon = sg_func_monitor::type_id::create("mon", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass

// ---------------------------------------------------------------------------------------------
// sg_apb_agent: programs CSRs, polls status, reads the fault log and counters.
// ---------------------------------------------------------------------------------------------
class sg_apb_sqr extends uvm_sequencer #(sg_apb_item);
  `uvm_component_utils(sg_apb_sqr)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
endclass

class sg_apb_driver extends uvm_driver #(sg_apb_item);
  `uvm_component_utils(sg_apb_driver)
  virtual sg_if vif;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual sg_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "sg_if not set")
  endfunction
  task run_phase(uvm_phase phase);
    vif.psel <= 0; vif.penable <= 0; vif.pwrite <= 0;
    forever begin
      seq_item_port.get_next_item(req);
      @(posedge vif.clk); vif.psel <= 1; vif.pwrite <= req.write; vif.paddr <= req.addr;
      vif.pwdata <= req.data; vif.penable <= 0;
      @(posedge vif.clk); vif.penable <= 1;
      @(posedge vif.clk);
      if (!req.write) req.rdata = vif.prdata;
      vif.psel <= 0; vif.penable <= 0; vif.pwrite <= 0;
      seq_item_port.item_done();
    end
  endtask
endclass

class sg_apb_monitor extends uvm_monitor;
  `uvm_component_utils(sg_apb_monitor)
  virtual sg_if vif;
  uvm_analysis_port #(sg_apb_item) ap;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual sg_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", "sg_if not set")
  endfunction
  task run_phase(uvm_phase phase);
    forever begin
      @(posedge vif.clk);
      if (vif.rst_n && vif.psel && vif.penable) begin
        sg_apb_item t = sg_apb_item::type_id::create("apb_t");
        t.write = vif.pwrite; t.addr = vif.paddr; t.data = vif.pwdata; t.rdata = vif.prdata;
        ap.write(t);
      end
    end
  endtask
endclass

class sg_apb_rw_seq extends uvm_sequence #(sg_apb_item);
  `uvm_object_utils(sg_apb_rw_seq)
  bit        write;
  bit [7:0]  addr;
  bit [31:0] data;
  function new(string name = "sg_apb_rw_seq"); super.new(name); endfunction
  task body();
    req = sg_apb_item::type_id::create("req");
    start_item(req);
    req.write = write; req.addr = addr; req.data = data;
    finish_item(req);
    data = req.rdata;
  endtask
endclass

class sg_apb_agent extends uvm_agent;
  `uvm_component_utils(sg_apb_agent)
  sg_apb_sqr     sqr;
  sg_apb_driver  drv;
  sg_apb_monitor mon;
  semaphore      lock = new(1);
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    sqr = sg_apb_sqr::type_id::create("sqr", this);
    drv = sg_apb_driver::type_id::create("drv", this);
    mon = sg_apb_monitor::type_id::create("mon", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction

  task write(bit [7:0] a, bit [31:0] d);
    sg_apb_rw_seq s = sg_apb_rw_seq::type_id::create("w");
    lock.get();
    s.write = 1; s.addr = a; s.data = d;
    s.start(sqr);
    lock.put();
  endtask
  task read(bit [7:0] a, output bit [31:0] d);
    sg_apb_rw_seq s = sg_apb_rw_seq::type_id::create("r");
    lock.get();
    s.write = 0; s.addr = a; s.data = 0;
    s.start(sqr);
    d = s.data;
    lock.put();
  endtask
endclass
