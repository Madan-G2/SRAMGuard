// ---------------------------------------------------------------------------------------------
// Functional-port sequences.  Knobs mirror the agent description in spec 10.2: load (idle
// fraction), address locality, hot rows.
// ---------------------------------------------------------------------------------------------
class sg_traffic_seq extends uvm_sequence #(sg_func_item);
  `uvm_object_utils(sg_traffic_seq)
  int          n_items   = 1000;
  int          idle_pct  = 50;           // % of cycles without a request
  int          wr_pct    = 40;
  int          part_pct  = 30;           // % of writes that are partial
  int          lo = 0, hi = DEPTH - 1;   // address range (locality)
  int          hot_pct   = 0;            // % of requests aimed at the hot set
  int          hot_lo = 0, hot_hi = 0;
  int          follow_win_pct = 0;       // % aimed at the 16 words of the window under test
  bit          stop_req  = 0;
  virtual sg_bd_if bd;

  function new(string name = "sg_traffic_seq"); super.new(name); endfunction

  function int pick_gap();
    int g = 0;
    while (idle_pct > 0 && $urandom_range(99) < idle_pct && g < 200) g++;
    return g;
  endfunction

  virtual function bit [11:0] pick_addr();
    if (follow_win_pct > 0 && bd != null && bd.win_open() && $urandom_range(99) < follow_win_pct)
      return {9'(bd.win_base() + $urandom_range(0, 1)), 3'($urandom_range(0, 7))};
    if (hot_pct > 0 && $urandom_range(99) < hot_pct) return 12'($urandom_range(hot_lo, hot_hi));
    return 12'($urandom_range(lo, hi));
  endfunction

  task body();
    if (!uvm_config_db#(virtual sg_bd_if)::get(null, "*", "bd", bd)) bd = null;
    for (int i = 0; i < n_items && !stop_req; i++) begin
      req = sg_func_item::type_id::create("req");
      start_item(req);
      req.we   = ($urandom_range(99) < wr_pct);
      req.addr = pick_addr();
      req.data = {$urandom, $urandom};
      req.be   = (req.we && $urandom_range(99) < part_pct) ? 8'($urandom_range(1, 254)) : 8'hFF;
      req.gap  = pick_gap();
      finish_item(req);
    end
  endtask
endclass

// one write of random data to every word (live content for the online test)
class sg_fill_seq extends uvm_sequence #(sg_func_item);
  `uvm_object_utils(sg_fill_seq)
  function new(string name = "sg_fill_seq"); super.new(name); endfunction
  task body();
    for (int a = 0; a < DEPTH; a++) begin
      req = sg_func_item::type_id::create("req");
      start_item(req);
      req.we = 1; req.addr = 12'(a); req.data = {$urandom, $urandom}; req.be = 8'hFF; req.gap = 0;
      finish_item(req);
    end
  endtask
endclass

class sg_read_all_seq extends uvm_sequence #(sg_func_item);
  `uvm_object_utils(sg_read_all_seq)
  int lo = 0, hi = DEPTH - 1;
  function new(string name = "sg_read_all_seq"); super.new(name); endfunction
  task body();
    for (int a = lo; a <= hi; a++) begin
      req = sg_func_item::type_id::create("req");
      start_item(req);
      req.we = 0; req.addr = 12'(a); req.data = 0; req.be = 8'hFF; req.gap = 0;
      finish_item(req);
    end
  endtask
endclass

// a single directed access
class sg_one_seq extends uvm_sequence #(sg_func_item);
  `uvm_object_utils(sg_one_seq)
  bit we; bit [11:0] addr; bit [63:0] data; bit [7:0] be = 8'hFF; int gap = 0;
  function new(string name = "sg_one_seq"); super.new(name); endfunction
  task body();
    req = sg_func_item::type_id::create("req");
    start_item(req);
    req.we = we; req.addr = addr; req.data = data; req.be = be; req.gap = gap;
    finish_item(req);
  endtask
endclass

// hammer one word with back-to-back accesses (worst case for the capture-pending and RMW hazards)
class sg_hot_word_seq extends uvm_sequence #(sg_func_item);
  `uvm_object_utils(sg_hot_word_seq)
  bit [11:0] addr; int n_items = 2000; int wr_pct = 50; int part_pct = 50;
  bit stop_req = 0;
  function new(string name = "sg_hot_word_seq"); super.new(name); endfunction
  task body();
    for (int i = 0; i < n_items && !stop_req; i++) begin
      req = sg_func_item::type_id::create("req");
      start_item(req);
      req.we = ($urandom_range(99) < wr_pct); req.addr = addr; req.data = {$urandom, $urandom};
      req.be = (req.we && $urandom_range(99) < part_pct) ? 8'($urandom_range(1, 254)) : 8'hFF;
      req.gap = 0;
      finish_item(req);
    end
  endtask
endclass

// ---------------------------------------------------------------------------------------------
// Convenience wrappers used by the tests
// ---------------------------------------------------------------------------------------------
class sg_vseq_lib;
  static task fill(sg_func_agent a);
    sg_fill_seq s = sg_fill_seq::type_id::create("fill");
    s.start(a.sqr);
  endtask
  static task read_all(sg_func_agent a, int lo = 0, int hi = DEPTH - 1);
    sg_read_all_seq s = sg_read_all_seq::type_id::create("rall");
    s.lo = lo; s.hi = hi;
    s.start(a.sqr);
  endtask
  static task one(sg_func_agent a, bit we, bit [11:0] ad, bit [63:0] d = 0, bit [7:0] be = 8'hFF);
    sg_one_seq s = sg_one_seq::type_id::create("one");
    s.we = we; s.addr = ad; s.data = d; s.be = be;
    s.start(a.sqr);
  endtask
endclass
