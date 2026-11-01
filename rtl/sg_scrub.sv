// Scrub scheduler (spec sections 6.5, 7.3, 7.4): picks the next online window, paces sweeps
// with SCRUB_PERIOD, and tracks rows whose correctable errors repeat across sweeps.
module sg_scrub
  import sg_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        seg_overlap,
  input  logic [31:0] period,
  input  logic [3:0]  ce_th,
  input  logic        win_done,        // pulse: current window finished
  input  logic        ce_evt,          // pulse: capture found a correctable error
  input  logic [8:0]  ce_row,
  input  logic        rep_evt,         // pulse: row repaired -> forget its history
  input  logic [8:0]  rep_row,
  output logic [8:0]  base,
  output logic        go,              // a window may start now
  output logic        sweep_done,      // pulse
  output logic        ovr              // window needs the March SS confirmation
);
  localparam logic [8:0] LAST_BASE = 9'(ROWS - SEG_ROWS);   // 510

  logic [31:0] tmr;
  logic        sweep_started;          // base != 0 or a window already ran in this sweep

  // repeat-CE table
  logic [CE_TAB-1:0]       t_v, t_hit;
  logic [8:0]              t_row [CE_TAB];
  logic [3:0]              t_cnt [CE_TAB];
  logic                    t_found, t_free;
  int                      t_fi, t_ei;

  always_comb begin
    t_found = 1'b0; t_free = 1'b0; t_fi = 0; t_ei = 0;
    for (int i = CE_TAB - 1; i >= 0; i--) begin
      if (t_v[i] && t_row[i] == ce_row) begin t_found = 1'b1; t_fi = i; end
      if (!t_v[i]) begin t_free = 1'b1; t_ei = i; end
    end
  end

  always_comb begin
    ovr = 1'b0;
    if (ce_th != 4'd0)
      for (int i = 0; i < CE_TAB; i++)
        if (t_v[i] && t_cnt[i] >= ce_th && (t_row[i] == base || t_row[i] == base + 9'd1)) ovr = 1'b1;
  end

  assign go = sweep_started || (tmr >= period);
  assign sweep_done = win_done && (base == LAST_BASE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      base <= '0; tmr <= '0; sweep_started <= 1'b0;
      t_v <= '0; t_hit <= '0;
      for (int i = 0; i < CE_TAB; i++) begin t_row[i] <= '0; t_cnt[i] <= '0; end
    end else begin
      if (tmr != 32'hFFFF_FFFF) tmr <= tmr + 32'd1;

      if (win_done) begin
        sweep_started <= 1'b1;
        if (base == LAST_BASE) begin
          base <= '0; sweep_started <= 1'b0; tmr <= '0;
          for (int i = 0; i < CE_TAB; i++) begin
            // a row must repeat in consecutive sweeps to stay a candidate
            if (t_v[i] && !t_hit[i]) t_v[i] <= 1'b0;
            t_hit[i] <= 1'b0;
          end
        end else base <= base + (seg_overlap ? 9'd1 : 9'd2);
      end

      if (ce_evt && ce_th != 4'd0) begin
        if (t_found) begin
          if (!t_hit[t_fi]) begin
            t_hit[t_fi] <= 1'b1;
            if (t_cnt[t_fi] != 4'hF) t_cnt[t_fi] <= t_cnt[t_fi] + 4'd1;
          end
        end else if (t_free) begin
          t_v[t_ei] <= 1'b1; t_row[t_ei] <= ce_row; t_cnt[t_ei] <= 4'd1; t_hit[t_ei] <= 1'b1;
        end
      end

      if (rep_evt)
        for (int i = 0; i < CE_TAB; i++)
          if (t_v[i] && t_row[i] == rep_row) begin t_v[i] <= 1'b0; t_cnt[i] <= '0; end
    end
  end
endmodule
