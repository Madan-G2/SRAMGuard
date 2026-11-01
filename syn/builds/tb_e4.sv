// E4: B4 (full SRAMGuard) vs B1 (SRAM + ECC) under identical request streams.
// Reports per-request accept->response latency and stall (valid && !ready) histograms.
`timescale 1ns/1ps
module e4_drv #(parameter int NREQ = 20000, parameter int NINIT = 4096) (
  input  logic clk, rst_n, go, input int idle_pct,
  output logic req_valid, req_we, output logic [11:0] req_addr, output logic [63:0] req_wdata, output logic [7:0] req_be,
  input  logic req_ready, rsp_valid, input logic [63:0] rsp_rdata, input logic rsp_ce, rsp_ue,
  output bit done,
  output int lat_h [0:7], output int stall_h [0:7], output int n_meas, output int max_lat, output int max_stall,
  output longint tot_cycles, output int errs, output longint sum_lat
);
  function automatic logic [63:0] hash(input longint unsigned x);
    logic [63:0] z = x * 64'h9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) * 64'hBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) * 64'h94D049BB133111EB;
    return z ^ (z >> 31);
  endfunction

  typedef struct { bit rd; logic [63:0] exp; int t; } pend_t;
  pend_t pq[$];
  logic [63:0] model [4096];
  int idx, cyc, stalls;
  bit started, measuring;
  int pend_we;

  // next request, a pure function of idx
  function automatic void nextreq(input int i, output bit we, output logic [11:0] a, output logic [63:0] d, output logic [7:0] be);
    logic [63:0] h = hash(i + 1000);
    logic [63:0] g = hash(i + 7777777);
    if (i < NINIT) begin we = 1; a = 12'(i); d = h; be = 8'hFF; end
    else begin
      a = g[11:0]; d = h;
      case (g[13:12])
        2'd0, 2'd1: begin we = 0; be = 8'hFF; end
        2'd2:       begin we = 1; be = 8'hFF; end
        default:    begin we = 1; be = (g[21:14] == 8'hFF || g[21:14] == 8'h00) ? 8'h0F : g[21:14]; end
      endcase
    end
  endfunction

  function automatic bit idle_now(input int i, input int c);
    logic [63:0] h = hash(64'(i) * 1000003 + c + 99);
    return int'(h[15:0] % 100) < idle_pct;
  endfunction

  bit cur_we; logic [11:0] cur_a; logic [63:0] cur_d; logic [7:0] cur_be;
  bit have;

  initial begin
    req_valid = 0; req_we = 0; req_addr = 0; req_wdata = 0; req_be = 8'hFF; done = 0;
    for (int k = 0; k < 8; k++) begin lat_h[k] = 0; stall_h[k] = 0; end
    n_meas = 0; max_lat = 0; max_stall = 0; tot_cycles = 0; errs = 0; sum_lat = 0;
    idx = 0; cyc = 0; stalls = 0; have = 0; measuring = 0;
    wait (go);
    forever begin
      @(negedge clk);
      if (idx >= NINIT + NREQ) begin req_valid = 0; break; end
      if (!have) begin
        if (idx >= NINIT && idle_now(idx, cyc)) begin req_valid = 0; end
        else begin
          nextreq(idx, cur_we, cur_a, cur_d, cur_be);
          req_valid = 1; req_we = cur_we; req_addr = cur_a; req_wdata = cur_d; req_be = cur_be;
          have = 1; stalls = 0;
        end
      end
      cyc++;
      if (idx == NINIT && !measuring) begin measuring = 1; cyc = 0; end
    end
    // drain
    repeat (20) @(posedge clk);
    tot_cycles = cyc;
    done = 1;
  end

  // accept / response bookkeeping at the posedge (what the DUT sees)
  always @(posedge clk) if (rst_n && go && !done) begin
    if (req_valid && have) begin
      if (req_ready) begin
        pend_t p; p.rd = !req_we; p.t = cyc;
        if (req_we) begin
          for (int i = 0; i < 8; i++) if (req_be[i]) model[req_addr][8*i +: 8] = req_wdata[8*i +: 8];
          p.exp = '0;
        end else p.exp = model[req_addr];
        pq.push_back(p);
        if (idx >= NINIT) begin
          stall_h[stalls > 7 ? 7 : stalls]++;
          if (stalls > max_stall) max_stall = stalls;
        end
        have = 0; idx++;
      end else stalls++;
    end
    if (rsp_valid) begin
      pend_t p;
      if (pq.size() == 0) begin errs++; end
      else begin
        p = pq.pop_front();
        if (p.rd && (rsp_rdata !== p.exp || rsp_ue)) errs++;
        if (idx > NINIT || measuring) begin
          int l;
          l = cyc - p.t;
          if (measuring && p.t >= 0) begin
            lat_h[l > 7 ? 7 : l]++; n_meas++; sum_lat += l;
            if (l > max_lat) max_lat = l;
          end
        end
      end
    end
  end
endmodule

module tb_e4;
  import sg_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int idle_pct = 0, bw = 0; logic go = 0;

  // B4
  logic v4, we4, rdy4, rv4, ce4, ue4; logic [11:0] a4; logic [63:0] wd4, rd4; logic [7:0] be4;
  logic psel = 0, penable = 0, pwrite = 0; logic [7:0] paddr = 0; logic [31:0] pwdata = 0, prdata; logic pready, pslverr;
  logic [37:0] rs; logic i1, i2, i3, i4;
  sg_top u4 (.clk, .rst_n, .req_valid(v4), .req_ready(rdy4), .req_we(we4), .req_addr(a4), .req_wdata(wd4), .req_be(be4),
             .rsp_valid(rv4), .rsp_rdata(rd4), .rsp_ce(ce4), .rsp_ue(ue4),
             .psel, .penable, .pwrite, .paddr, .pwdata, .prdata, .pready, .pslverr,
             .fuse_vld(1'b0), .fuse_sig(38'h0), .repair_sig_o(rs), .irq_ue(i1), .irq_hard(i2), .irq_repair(i3), .irq_done(i4));
  // B1
  logic v1, we1, rdy1, rv1, ce1, ue1; logic [11:0] a1; logic [63:0] wd1, rd1; logic [7:0] be1;
  sg_b1 u1 (.clk, .rst_n, .req_valid(v1), .req_ready(rdy1), .req_we(we1), .req_addr(a1), .req_wdata(wd1), .req_be(be1),
            .rsp_valid(rv1), .rsp_rdata(rd1), .rsp_ce(ce1), .rsp_ue(ue1));

  logic go4 = 0, go1 = 0;
  int lh4[0:7], sh4[0:7], lh1[0:7], sh1[0:7];
  int nm4, ml4, ms4, er4, nm1, ml1, ms1, er1; longint tc4, tc1, sl4, sl1; bit d4, d1;
  e4_drv d4i (.clk, .rst_n, .go(go4), .idle_pct, .req_valid(v4), .req_we(we4), .req_addr(a4), .req_wdata(wd4), .req_be(be4),
              .req_ready(rdy4), .rsp_valid(rv4), .rsp_rdata(rd4), .rsp_ce(ce4), .rsp_ue(ue4), .done(d4),
              .lat_h(lh4), .stall_h(sh4), .n_meas(nm4), .max_lat(ml4), .max_stall(ms4), .tot_cycles(tc4), .errs(er4), .sum_lat(sl4));
  e4_drv d1i (.clk, .rst_n, .go(go1), .idle_pct, .req_valid(v1), .req_we(we1), .req_addr(a1), .req_wdata(wd1), .req_be(be1),
              .req_ready(rdy1), .rsp_valid(rv1), .rsp_rdata(rd1), .rsp_ce(ce1), .rsp_ue(ue1), .done(d1),
              .lat_h(lh1), .stall_h(sh1), .n_meas(nm1), .max_lat(ml1), .max_stall(ms1), .tot_cycles(tc1), .errs(er1), .sum_lat(sl1));

  initial begin
    if (!$value$plusargs("IDLE=%d", idle_pct)) idle_pct = 0;
    repeat (6) @(posedge clk); @(negedge clk); rst_n = 1;
    go1 = 1;
    wait (u4.mode == MODE_ONLINE);
    repeat (4) @(posedge clk);
    if ($value$plusargs("BW=%d", bw) && bw != 0) begin
      @(posedge clk); psel <= 1; pwrite <= 1; paddr <= 8'h0C; pwdata <= bw; penable <= 0;
      @(posedge clk); penable <= 1; @(posedge clk); psel <= 0; penable <= 0; pwrite <= 0;
    end
    go4 = 1;
    wait (d4 && d1);
    $display("RESULT idle=%0d%%", idle_pct);
    $display("  %-3s reqs=%0d cycles=%0d  (req/cyc=%0.3f)  max lat=%0d  stall max=%0d  errs=%0d", "B1", nm1, tc1, real'(nm1)/tc1, ml1, ms1, er1);
    $display("  %-3s reqs=%0d cycles=%0d  (req/cyc=%0.3f)  max lat=%0d  stall max=%0d  errs=%0d", "B4", nm4, tc4, real'(nm4)/tc4, ml4, ms4, er4);
    $display("  lat hist  B1: %p", lh1); $display("  lat hist  B4: %p", lh4);
    $display("  stall hist B1: %p", sh1); $display("  stall hist B4: %p", sh4);
    $display("  B4 windows=%0d sweeps=%0d", u4.u_csr.cnt[C_WIN], u4.u_csr.cnt[C_SWEEP]);
    $finish;
  end
  initial begin #200ms; $display("TIMEOUT"); $finish; end
endmodule
