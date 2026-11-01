// UVM top: DUT, clock, interfaces, REQ-OT-1 invariant checker.
`timescale 1ns/1ps
module tb_uvm_top;
  import uvm_pkg::*;
  import sg_pkg::*;
  import sg_uvm_pkg::*;

  logic clk = 0;
  always #5 clk = ~clk;

  sg_if    vif (clk);
  sg_bd_if bd ();

  sg_top dut (
    .clk(clk), .rst_n(vif.rst_n),
    .req_valid(vif.req_valid), .req_ready(vif.req_ready), .req_we(vif.req_we), .req_addr(vif.req_addr),
    .req_wdata(vif.req_wdata), .req_be(vif.req_be),
    .rsp_valid(vif.rsp_valid), .rsp_rdata(vif.rsp_rdata), .rsp_ce(vif.rsp_ce), .rsp_ue(vif.rsp_ue),
    .psel(vif.psel), .penable(vif.penable), .pwrite(vif.pwrite), .paddr(vif.paddr), .pwdata(vif.pwdata),
    .prdata(vif.prdata), .pready(vif.pready), .pslverr(vif.pslverr),
    .fuse_vld(vif.fuse_vld), .fuse_sig(vif.fuse_sig), .repair_sig_o(vif.repair_sig_o),
    .irq_ue(vif.irq_ue), .irq_hard(vif.irq_hard), .irq_repair(vif.irq_repair), .irq_done(vif.irq_done)
  );

  // REQ-OT-1 (spec 6.2): for every valid word of the window, array content == ref ^ {72{pol}}
  // in a fault-free memory.  Skipped while faults or ECC injection exist, and while a row is
  // migrating (its old row is intentionally left stale).
  int inv_checks = 0;
  always @(negedge clk) begin
    if (vif.rst_n && dut.win_open && bd.nfaults() == 0 && dut.u_csr.inj_mask == '0 && !dut.rd_act) begin
      for (int i = 0; i < SEG_WORDS; i++) begin
        if (dut.u_win.u_seg.st[i] == 2'd2) begin
          logic [71:0] exp;
          int a;
          a = (int'(dut.win_base) << 3) + i;
          exp = dut.u_win.u_seg.ref_q[i] ^ {72{dut.u_win.u_seg.pol_q[i]}};
          inv_checks++;
          if (bd.logical(a) !== exp)
            uvm_pkg::uvm_report_error("REQ-OT-1", $sformatf("word %03h: array %018h != ref^pol %018h", a, bd.logical(a), exp), UVM_NONE);
        end
      end
    end
  end
  final $display("REQ-OT-1 invariant evaluated %0d times", inv_checks);

  initial begin
    vif.rst_n = 0; vif.req_valid = 0; vif.req_we = 0; vif.req_addr = 0; vif.req_wdata = 0; vif.req_be = 8'hFF;
    vif.psel = 0; vif.penable = 0; vif.pwrite = 0; vif.paddr = 0; vif.pwdata = 0;
    vif.fuse_vld = 0; vif.fuse_sig = 0;
    uvm_config_db#(virtual sg_if)::set(null, "*", "vif", vif);
    uvm_config_db#(virtual sg_bd_if)::set(null, "*", "bd", bd);
    run_test();
  end

  // VCS coverage off
  // optional waveform: +DUMP_VCD[=file] [+DUMP_END_NS=<ns>]  (off by default; key signals only)
  initial begin
    string fn;
    longint unsigned end_ns;
    if ($value$plusargs("DUMP_VCD=%s", fn) || $test$plusargs("DUMP_VCD")) begin
      if (fn == "") fn = "sg_wave.vcd";
      $dumpfile(fn);
      $dumpvars(0, clk);
      $dumpvars(0, dut.rst_n, dut.mode, dut.u_ctl.st, dut.u_win.st);
      $dumpvars(0, dut.req_valid, dut.req_ready, dut.req_we, dut.req_addr, dut.req_wdata);
      $dumpvars(0, dut.rsp_valid, dut.rsp_rdata, dut.rsp_ce, dut.rsp_ue);
      $dumpvars(0, dut.psel, dut.penable, dut.pwrite, dut.paddr, dut.pwdata, dut.prdata);
      $dumpvars(0, dut.win_open, dut.win_base, dut.mb_op_valid, dut.mb_op_rw, dut.mb_op_row, dut.mb_op_col);
      $dumpvars(0, dut.cap_v, dut.cap_ce, dut.stall_run, dut.rm_v, dut.rm_row0, dut.rm_row1);
      $dumpvars(0, dut.irq_ue, dut.irq_hard, dut.irq_repair, dut.irq_done);
      if ($value$plusargs("DUMP_END_NS=%d", end_ns)) begin
        #(end_ns * 1ns);
        $dumpoff;
      end
    end
  end
  // VCS coverage on

  initial begin
    #40000000000;
    uvm_pkg::uvm_report_fatal("WATCHDOG", "simulation timeout", UVM_NONE);
  end
endmodule
