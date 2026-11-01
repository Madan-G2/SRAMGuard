// Smoke test for the B0 / B1 synthesis wrappers: full writes, partial writes, reads, in-order
// responses with latency 2 (+ stalls on RMW), against a simple memory model.
module tb_b01;
  import sg_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic req_valid, req_we; logic [11:0] req_addr; logic [63:0] req_wdata; logic [7:0] req_be;
  logic r0_ready, r1_ready, r0_v, r1_v, r0_ce, r0_ue, r1_ce, r1_ue;
  logic [63:0] r0_d, r1_d;
  logic [63:0] model [4096];
  bit          written [4096];

  // each DUT gets its own request copy (B1 can stall, B0 never does); drive B1's ready for both
  sg_b0 u0 (.clk, .rst_n, .req_valid(req_valid && r1_ready), .req_ready(r0_ready), .req_we, .req_addr, .req_wdata,
            .req_be(8'hFF), .rsp_valid(r0_v), .rsp_rdata(r0_d), .rsp_ce(r0_ce), .rsp_ue(r0_ue));
  sg_b1 u1 (.clk, .rst_n, .req_valid, .req_ready(r1_ready), .req_we, .req_addr, .req_wdata, .req_be,
            .rsp_valid(r1_v), .rsp_rdata(r1_d), .rsp_ce(r1_ce), .rsp_ue(r1_ue));

  // expected-response queue for B1 (B0 is only checked on full writes + reads)
  typedef struct { bit is_rd; logic [63:0] d; } exp_t;
  exp_t q[$];
  int errs = 0, nrd = 0, nstall = 0, nreq = 0;

  always @(posedge clk) if (rst_n) begin
    if (r1_v) begin
      exp_t e;
      if (q.size() == 0) begin errs++; $display("B1 unexpected response"); end
      else begin
        e = q.pop_front();
        if (e.is_rd) begin
          nrd++;
          if (r1_d !== e.d || r1_ce || r1_ue) begin errs++; $display("B1 rd mismatch got %h exp %h ce=%b ue=%b", r1_d, e.d, r1_ce, r1_ue); end
        end
      end
    end
  end

  // req_ready depends only on state that changes at posedge, so its value at the negedge is the
  // value the DUT samples at the next posedge.
  task automatic issue(input bit we, input [11:0] a, input [63:0] d, input [7:0] be);
    int w = 0;
    @(negedge clk);
    req_valid = 1; req_we = we; req_addr = a; req_wdata = d; req_be = be;
    while (!r1_ready) begin w++; @(negedge clk); end
    @(posedge clk);                                   // accepted here
    nstall += w; nreq++;
    if (we) begin
      for (int i = 0; i < 8; i++) if (be[i]) model[a][8*i +: 8] = d[8*i +: 8];
      written[a] = 1; q.push_back('{0, 64'h0});
    end else q.push_back('{1, model[a]});
  endtask

  initial begin
    req_valid = 0; req_we = 0; req_addr = 0; req_wdata = 0; req_be = 8'hFF;
    $display("start"); $fflush; repeat (4) @(posedge clk); rst_n = 1; $display("reset released t=%0t", $time); $fflush; repeat (2) @(posedge clk);
    // initialise a region with full writes
    for (int a = 0; a < 256; a++) issue(1, 12'(a*13), {$urandom, $urandom}, 8'hFF);
    // mixed random traffic over that region
    for (int n = 0; n < 4000; n++) begin
      int a = ($urandom_range(0, 255)) * 13;
      case ($urandom_range(0, 3))
        0: issue(0, 12'(a), 64'h0, 8'hFF);
        1: issue(1, 12'(a), {$urandom, $urandom}, 8'hFF);
        2: issue(1, 12'(a), {$urandom, $urandom}, 8'($urandom_range(1, 254)));   // partial
        3: begin issue(1, 12'(a), {$urandom, $urandom}, 8'($urandom_range(1, 254))); issue(0, 12'(a), 64'h0, 8'hFF); end
      endcase
    end
    @(negedge clk); req_valid = 0;
    repeat (10) @(posedge clk);
    if (q.size() != 0) begin errs++; $display("%0d responses missing", q.size()); end
    $display("B1 smoke: %0d requests, %0d reads checked, %0d stall cycles, %0d errors -> %s", nreq, nrd, nstall, errs, errs ? "FAIL" : "PASS");
    $finish;
  end
endmodule
