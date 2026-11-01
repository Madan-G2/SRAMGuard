// Build B0 (spec 11.2): bare SRAM macro + valid/ready wrapper.  No ECC, no test, no repair.
// Same functional port as sg_top (without the APB side) so area/timing compare like for like.
// Byte enables are assumed to be handled inside the macro (not modelled), req_ready is always 1.
// Read latency 2: array read (1) + output register (1), same as sg_top with ECC_PIPE = 1.
module sg_b0
  import sg_pkg::*;
(
  input  logic              clk,
  input  logic              rst_n,
  input  logic              req_valid,
  output logic              req_ready,
  input  logic              req_we,
  input  logic [11:0]       req_addr,
  input  logic [DATA_W-1:0] req_wdata,
  input  logic [7:0]        req_be,
  output logic              rsp_valid,
  output logic [DATA_W-1:0] rsp_rdata,
  output logic              rsp_ce,
  output logic              rsp_ue
);
  logic [PIO-1:0] rd74;
  logic           rd_q, wr_q, vld_q;
  logic           unused;
  assign unused = &{1'b0, req_be};

  sg_sram u_sram (
    .clk(clk), .en(req_valid), .we(req_we), .row({1'b0, req_addr[11:3]}), .col(req_addr[2:0]),
    .wdata({{(PIO-DATA_W){1'b0}}, req_wdata}), .rdata(rd74)
  );

  assign req_ready = 1'b1;
  assign rsp_ce = 1'b0;
  assign rsp_ue = 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rd_q <= 1'b0; vld_q <= 1'b0; rsp_valid <= 1'b0; rsp_rdata <= '0; end
    else begin
      rd_q <= req_valid && !req_we;
      vld_q <= req_valid;
      rsp_valid <= vld_q;
      if (rd_q) rsp_rdata <= rd74[DATA_W-1:0];
    end
  end
endmodule
