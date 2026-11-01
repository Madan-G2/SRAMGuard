// Signal-level interface of SRAMGuard (functional port, APB, interrupts, saved repair signature).
interface sg_if (input logic clk);
  logic         rst_n;
  logic         req_valid, req_we, req_ready;
  logic [11:0]  req_addr;
  logic [63:0]  req_wdata;
  logic [7:0]   req_be;
  logic         rsp_valid, rsp_ce, rsp_ue;
  logic [63:0]  rsp_rdata;
  logic         psel, penable, pwrite, pready, pslverr;
  logic [7:0]   paddr;
  logic [31:0]  pwdata, prdata;
  logic         fuse_vld;
  logic [37:0]  fuse_sig, repair_sig_o;
  logic         irq_ue, irq_hard, irq_repair, irq_done;
  // functional port is open (ONLINE): stalls only count while it is
  function automatic bit mode_fn_open(); return tb_uvm_top.dut.fn_en; endfunction
endinterface

// Simulation-only back door: fault injection into the SRAM model (spec 4.3), array and
// internal-state probes.  Nothing in the RTL changes for fault injection; the UVM
// sg_fault_ctrl owns the fault list and drives it through these functions.
interface sg_bd_if;
  import sg_pkg::*;
  import sg_ecc_ref_pkg::*;

  // ---- fault model
  function automatic int inject(input int t, input int vr, vc, vb, input int ar, ac, ab,
                                input bit pol, input bit val, input longint act);
    return tb_uvm_top.dut.u_sram.inject(t, vr, vc, vb, ar, ac, ab, pol, val, act);
  endfunction
  function automatic void clear_faults();  tb_uvm_top.dut.u_sram.clear_faults(); endfunction
  function automatic bit  fired(input int i); return tb_uvm_top.dut.u_sram.fault_fired(i); endfunction
  function automatic longint now(); return tb_uvm_top.dut.u_sram.now_cycle(); endfunction
  function automatic int  nfaults(); return tb_uvm_top.dut.u_sram.nf; endfunction

  // ---- state probes
  function automatic int  mode();      return int'(tb_uvm_top.dut.mode); endfunction
  function automatic bit  win_open();  return tb_uvm_top.dut.win_open; endfunction
  function automatic int  win_base();  return int'(tb_uvm_top.dut.win_base); endfunction
  function automatic int  win_state(); return int'(tb_uvm_top.dut.u_win.st); endfunction
  function automatic int  sc_base();   return int'(tb_uvm_top.dut.sc_base); endfunction
  function automatic bit  win_done();  return tb_uvm_top.dut.ev_win_done; endfunction
  function automatic bit  ue_seen();   return tb_uvm_top.dut.u_win.ue_seen || tb_uvm_top.dut.u_win.df_seen; endfunction
  function automatic bit  rmw_busy();  return tb_uvm_top.dut.u_arb.rmw_busy; endfunction
  function automatic int  cnt(input int id); return int'(tb_uvm_top.dut.u_csr.cnt[id]); endfunction
  function automatic bit  f_valid();   return tb_uvm_top.dut.f_valid; endfunction
  function automatic bit  f_pend();    return tb_uvm_top.dut.f_pend; endfunction
  function automatic bit  f_pol();     return tb_uvm_top.dut.f_pol; endfunction
  function automatic bit  rd_act();    return tb_uvm_top.dut.rd_act; endfunction
  function automatic bit  cap_v();     return tb_uvm_top.dut.cap_v; endfunction
  function automatic bit  cap_ce();    return tb_uvm_top.dut.cap_ce; endfunction
  function automatic bit  cap_ue();    return tb_uvm_top.dut.cap_ue; endfunction
  function automatic bit  ev_df();     return tb_uvm_top.dut.ev_df; endfunction
  function automatic bit  mbist_fail();   return tb_uvm_top.dut.mbist_fail; endfunction
  function automatic bit  repair_ok();    return tb_uvm_top.dut.repair_ok; endfunction
  function automatic bit  repair_fail();  return tb_uvm_top.dut.repair_fail; endfunction
  function automatic logic [37:0] rm_sig(); return tb_uvm_top.dut.rm_sig; endfunction
  function automatic logic [1:0]  rm_v();   return tb_uvm_top.dut.rm_v; endfunction
  function automatic bit rm_valid(input int k); return tb_uvm_top.dut.rm_v[k]; endfunction
  function automatic int rm_row(input int k); return k ? int'(tb_uvm_top.dut.rm_row1) : int'(tb_uvm_top.dut.rm_row0); endfunction
  // causes of the interrupt lines (one-cycle pulses) and the CSR write that clears them
  function automatic logic [3:0] irq_cause();
    return {tb_uvm_top.dut.irq_done_p,
            tb_uvm_top.dut.ev_repair | tb_uvm_top.dut.ev_repair_fail,
            tb_uvm_top.dut.ev_hard   | tb_uvm_top.dut.ev_hard_off,
            tb_uvm_top.dut.ev_rsp_ue | tb_uvm_top.dut.ev_ue_w | tb_uvm_top.dut.ev_df};
  endfunction
  function automatic logic [3:0] irq_w1c();
    return (tb_uvm_top.dut.u_csr.wr && tb_uvm_top.dut.u_csr.paddr == 8'hC0)
           ? tb_uvm_top.dut.u_csr.pwdata[3:0] : 4'h0;
  endfunction

  // ---- fault log
  function automatic bit flog_has(input int row, input int bit_no);
    for (int e = 0; e < FLOG_DEPTH; e++)
      if (tb_uvm_top.dut.fl_v[e] && tb_uvm_top.dut.fl_row[e] == row &&
          (bit_no < 0 || tb_uvm_top.dut.fl_mask[e][bit_no])) return 1;
    return 0;
  endfunction
  // drive one fault-log insert directly (test only; the design is quiet when this is used)
  logic [9:0] fi_row; logic [73:0] fi_mask; bit fi_onl;
  task flog_ins(input int row, input logic [73:0] mask, input bit onl);
    fi_row = 10'(row); fi_mask = mask; fi_onl = onl;
    @(negedge tb_uvm_top.clk);
    force tb_uvm_top.dut.u_flog.ins_v = 1'b1;   force tb_uvm_top.dut.u_flog.ins_row = fi_row;
    force tb_uvm_top.dut.u_flog.ins_mask = fi_mask; force tb_uvm_top.dut.u_flog.ins_onl = fi_onl;
    @(negedge tb_uvm_top.clk);
    release tb_uvm_top.dut.u_flog.ins_v; release tb_uvm_top.dut.u_flog.ins_row;
    release tb_uvm_top.dut.u_flog.ins_mask; release tb_uvm_top.dut.u_flog.ins_onl;
  endtask
  // ---- scheduler / sequencer stimulus (test only, used while the window engine is switched off)
  bit sd_ce, sd_wd, sd_rep; logic [8:0] sd_cer, sd_repr;
  task scrub_drive(input bit ce, input int cer, input bit wd, input bit rep, input int repr);
    sd_ce = ce; sd_cer = 9'(cer); sd_wd = wd; sd_rep = rep; sd_repr = 9'(repr);
    @(negedge tb_uvm_top.clk);
    force tb_uvm_top.dut.u_scrub.ce_evt = sd_ce;   force tb_uvm_top.dut.u_scrub.ce_row = sd_cer;
    force tb_uvm_top.dut.u_scrub.win_done = sd_wd; force tb_uvm_top.dut.u_scrub.rep_evt = sd_rep;
    force tb_uvm_top.dut.u_scrub.rep_row = sd_repr;
    @(negedge tb_uvm_top.clk);
    release tb_uvm_top.dut.u_scrub.ce_evt; release tb_uvm_top.dut.u_scrub.ce_row;
    release tb_uvm_top.dut.u_scrub.win_done; release tb_uvm_top.dut.u_scrub.rep_evt;
    release tb_uvm_top.dut.u_scrub.rep_row;
  endtask
  task scrub_tmr_max();
    force tb_uvm_top.dut.u_scrub.tmr = 32'hFFFF_FFFF;
    @(negedge tb_uvm_top.clk);
    release tb_uvm_top.dut.u_scrub.tmr;
  endtask
  task mb_idle_stop();
    @(negedge tb_uvm_top.clk); force tb_uvm_top.dut.u_mbist.stop = 1'b1;
    @(negedge tb_uvm_top.clk); release tb_uvm_top.dut.u_mbist.stop;
  endtask
  task mb_idle_ack();
    @(negedge tb_uvm_top.clk); force tb_uvm_top.dut.u_mbist.op_ack = 1'b1;
    @(negedge tb_uvm_top.clk); release tb_uvm_top.dut.u_mbist.op_ack;
  endtask
  function automatic bit mb_busy(); return tb_uvm_top.dut.u_mbist.run; endfunction
  function automatic int flog_n();
    int n = 0;
    for (int e = 0; e < FLOG_DEPTH; e++) if (tb_uvm_top.dut.fl_v[e]) n++;
    return n;
  endfunction

  // ---- array back door: logical word as stored, IO shift undone with the repair signature
  function automatic logic [71:0] logical(input int a);
    logic [37:0] s;
    logic [9:0]  prow;
    logic [73:0] p;
    logic [71:0] w;
    int f1, f2, v1, v2, row, m;
    s = tb_uvm_top.dut.u_remap.sig;
    row = a >> 3;
    prow = row;
    if (s[9]  && s[8:0]   == row) prow = 512;
    else if (s[19] && s[18:10] == row) prow = 513;
    p = tb_uvm_top.dut.u_sram.bd_read(prow, a & 7);
    v1 = s[27]; f1 = s[26:20]; v2 = s[35]; f2 = s[34:28];
    for (int i = 0; i < 72; i++) begin
      m = i + ((v1 != 0 && i >= f1) ? 1 : 0) + ((v2 != 0 && i >= f2 - 1) ? 1 : 0);
      w[i] = p[m];
    end
    return w;
  endfunction

  // does the stored word still decode to `gold`?
  function automatic bit holds(input int a, input logic [63:0] gold);
    logic [71:0] cw, t;
    cw = logical(a);
    if (ref_syn(cw) == 0) return cw[63:0] === gold;
    for (int i = 0; i < 72; i++) begin
      t = cw ^ (72'h1 << i);
      if (ref_syn(t) == 0) return t[63:0] === gold;
    end
    return 0;
  endfunction
endinterface
