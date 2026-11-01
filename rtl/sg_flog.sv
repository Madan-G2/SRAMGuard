// Fault logger (spec section 3): distinct failing rows with a merged IO fail mask.
// Entry row is physical for RESET_TEST/MAINT and logical for online hard faults.
module sg_flog
  import sg_pkg::*;
(
  input  logic                                 clk,
  input  logic                                 rst_n,
  input  logic                                 clr,
  input  logic                                 ins_v,
  input  logic [9:0]                           ins_row,
  input  logic [PIO-1:0]                       ins_mask,
  input  logic                                 ins_onl,
  output logic [FLOG_DEPTH-1:0]                e_v,
  output logic [FLOG_DEPTH-1:0][9:0]           e_row,
  output logic [FLOG_DEPTH-1:0][PIO-1:0]       e_mask,
  output logic [FLOG_DEPTH-1:0]                e_onl,
  output logic [FLOG_DEPTH-1:0][15:0]          e_cnt,
  output logic                                 ovf
);
  logic hit, free;
  int   hit_i, free_i;

  always_comb begin
    hit = 1'b0; free = 1'b0; hit_i = 0; free_i = 0;
    for (int i = FLOG_DEPTH - 1; i >= 0; i--) begin
      if (e_v[i] && e_row[i] == ins_row) begin hit = 1'b1; hit_i = i; end
      if (!e_v[i]) begin free = 1'b1; free_i = i; end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      e_v <= '0; e_row <= '0; e_mask <= '0; e_onl <= '0; e_cnt <= '0; ovf <= 1'b0;
    end else if (clr) begin
      e_v <= '0; e_row <= '0; e_mask <= '0; e_onl <= '0; e_cnt <= '0; ovf <= 1'b0;
    end else if (ins_v) begin
      if (hit) begin
        e_mask[hit_i] <= e_mask[hit_i] | ins_mask;
        e_onl[hit_i]  <= e_onl[hit_i] | ins_onl;
        if (e_cnt[hit_i] != 16'hFFFF) e_cnt[hit_i] <= e_cnt[hit_i] + 16'd1;
      end else if (free) begin
        e_v[free_i] <= 1'b1; e_row[free_i] <= ins_row; e_mask[free_i] <= ins_mask;
        e_onl[free_i] <= ins_onl; e_cnt[free_i] <= 16'd1;
      end else ovf <= 1'b1;
    end
  end
endmodule
