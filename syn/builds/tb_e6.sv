// E6: switching-activity capture (RTL SAIF) for one DUT under the E4 traffic stream.
// Compile with +define+E6_B4 (full SRAMGuard) or +define+E6_B1 (SRAM+ECC).  +IDLE, +BW as in tb_e4.
// SAIF window = the measured request phase only (the 4096-word initialisation and the power-on
// test are excluded).
`timescale 1ns/1ps
module tb_e6;
  import sg_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int idle_pct = 0, bw = 0; logic go = 0;
  logic v, we, rdy, rv, ce, ue; logic [11:0] a; logic [63:0] wd, rd; logic [7:0] be;
  logic psel = 0, penable = 0, pwrite = 0; logic [7:0] paddr = 0; logic [31:0] pwdata = 0, prdata; logic pready, pslverr;
  logic [37:0] rs; logic i1, i2, i3, i4;
`ifdef E6_B4
  sg_top dut (.clk, .rst_n, .req_valid(v), .req_ready(rdy), .req_we(we), .req_addr(a), .req_wdata(wd), .req_be(be),
             .rsp_valid(rv), .rsp_rdata(rd), .rsp_ce(ce), .rsp_ue(ue),
             .psel, .penable, .pwrite, .paddr, .pwdata, .prdata, .pready, .pslverr,
             .fuse_vld(1'b0), .fuse_sig(38'h0), .repair_sig_o(rs), .irq_ue(i1), .irq_hard(i2), .irq_repair(i3), .irq_done(i4));
`else
  sg_b1 dut (.clk, .rst_n, .req_valid(v), .req_ready(rdy), .req_we(we), .req_addr(a), .req_wdata(wd), .req_be(be),
            .rsp_valid(rv), .rsp_rdata(rd), .rsp_ce(ce), .rsp_ue(ue));
`endif
  int lh[0:7], sh[0:7], nm, ml, ms, er; longint tc, sl; bit dn;
  e4_drv drv (.clk, .rst_n, .go, .idle_pct, .req_valid(v), .req_we(we), .req_addr(a), .req_wdata(wd), .req_be(be),
              .req_ready(rdy), .rsp_valid(rv), .rsp_rdata(rd), .rsp_ce(ce), .rsp_ue(ue), .done(dn),
              .lat_h(lh), .stall_h(sh), .n_meas(nm), .max_lat(ml), .max_stall(ms), .tot_cycles(tc), .errs(er), .sum_lat(sl));
  initial begin
    string f;
    if (!$value$plusargs("IDLE=%d", idle_pct)) idle_pct = 0;
    if (!$value$plusargs("SAIF=%s", f)) f = "act.saif";
    repeat (6) @(posedge clk); @(negedge clk); rst_n = 1;
`ifdef E6_B4
    wait (dut.mode == MODE_ONLINE); repeat (4) @(posedge clk);
    if ($value$plusargs("BW=%d", bw) && bw != 0) begin
      @(posedge clk); psel <= 1; pwrite <= 1; paddr <= 8'h0C; pwdata <= bw; penable <= 0;
      @(posedge clk); penable <= 1; @(posedge clk); psel <= 0; penable <= 0; pwrite <= 0;
    end
`endif
    go = 1;
    wait (drv.measuring);
`ifdef E6_UCLI
    $stop;                       // ucli: power -enable here
    wait (dn);
`else
    $set_toggle_region(dut);
    $toggle_start;
    wait (dn);
    $toggle_stop;
    $toggle_report(f, 1.0e-9, "tb_e6.dut");
`endif
    $display("E6 done: reqs=%0d cycles=%0d errs=%0d", nm, tc, er);
`ifdef E6_UCLI
    $stop;
`else
    $finish;
`endif
  end
  initial begin #300ms; $display("TIMEOUT"); $finish; end
endmodule
