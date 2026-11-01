// Build B1 (spec 11.2): B0 + SECDED ECC.  Partial (byte-enable) writes use a read-modify-write.
// Same functional port as sg_top.  Read latency 2 (array 1 + registered decode), one request in
// flight during an RMW (the port stalls for the two RMW cycles).  No test, scrub or repair.
module sg_b1
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
  typedef enum logic [1:0] {T_NONE, T_RD, T_WR, T_RMW} tk_e;

  logic [PIO-1:0]    rd74;
  logic [WORD_W-1:0] enc_cw, dec_fix;
  logic [DATA_W-1:0] enc_data, dec_data;
  logic              dec_ce, dec_ue;

  sg_ecc u_ecc (.enc_data(enc_data), .enc_cw(enc_cw),
                .dec_cw(rd74[WORD_W-1:0]), .dec_data(dec_data), .dec_fix(dec_fix),
                .dec_ce(dec_ce), .dec_ue(dec_ue));

  // return pipeline: tag at issue, array data one cycle later, registered decode after that
  tk_e               tag_q, ds_tag, tag_issue;
  logic              ds_v, ds_ce, ds_ue;
  logic [DATA_W-1:0] ds_data;

  // read-modify-write context
  logic              rmw_v;
  logic [11:0]       rmw_addr;
  logic [DATA_W-1:0] rmw_wdata;
  logic [7:0]        rmw_be;
  logic              rmw_wr_now, is_partial;
  logic [DATA_W-1:0] merged;

  assign rmw_wr_now = ds_v && (ds_tag == T_RMW);
  assign is_partial = req_we && (req_be != 8'hFF);
  assign req_ready  = !rmw_v;

  always_comb for (int i = 0; i < 8; i++)
    merged[8*i +: 8] = rmw_be[i] ? rmw_wdata[8*i +: 8] : ds_data[8*i +: 8];

  assign enc_data = rmw_wr_now ? merged : req_wdata;

  logic          a_en, a_we;
  logic [11:0]   a_addr;
  logic [PIO-1:0] a_wdata;

  always_comb begin
    a_en = 1'b0; a_we = 1'b0; a_addr = req_addr; a_wdata = '0; tag_issue = T_NONE;
    if (rmw_wr_now) begin
      if (!ds_ue) begin
        a_en = 1'b1; a_we = 1'b1; a_addr = rmw_addr; a_wdata = {{(PIO-WORD_W){1'b0}}, enc_cw};
      end
    end else if (req_valid && req_ready) begin
      a_en = 1'b1;
      if (!req_we)         tag_issue = T_RD;
      else if (is_partial) tag_issue = T_RMW;          // read half of the RMW
      else begin
        a_we = 1'b1; a_wdata = {{(PIO-WORD_W){1'b0}}, enc_cw}; tag_issue = T_WR;
      end
    end
  end

  sg_sram u_sram (
    .clk(clk), .en(a_en), .we(a_we), .row({1'b0, a_addr[11:3]}), .col(a_addr[2:0]),
    .wdata(a_wdata), .rdata(rd74)
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tag_q <= T_NONE; ds_tag <= T_NONE; ds_v <= 1'b0; ds_data <= '0; ds_ce <= 1'b0; ds_ue <= 1'b0;
      rmw_v <= 1'b0; rmw_addr <= '0; rmw_wdata <= '0; rmw_be <= '0;
    end else begin
      tag_q  <= tag_issue;
      ds_v   <= (tag_q != T_NONE);
      ds_tag <= tag_q;
      ds_data <= dec_data; ds_ce <= dec_ce; ds_ue <= dec_ue;
      if (req_valid && req_ready && is_partial) begin
        rmw_v <= 1'b1; rmw_addr <= req_addr; rmw_wdata <= req_wdata; rmw_be <= req_be;
      end else if (rmw_wr_now) rmw_v <= 1'b0;
    end
  end

  always_comb begin
    rsp_valid = 1'b0; rsp_rdata = '0; rsp_ce = 1'b0; rsp_ue = 1'b0;
    if (ds_v) begin
      case (ds_tag)
        T_RD:  begin rsp_valid = 1'b1; rsp_rdata = ds_data; rsp_ce = ds_ce; rsp_ue = ds_ue; end
        T_WR:  rsp_valid = 1'b1;
        T_RMW: begin rsp_valid = 1'b1; rsp_ce = ds_ce; rsp_ue = ds_ue; end
        default: ;
      endcase
    end
  end
endmodule
