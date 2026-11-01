// RESET_TEST / MAINT controller (spec sections 3 "Operating modes", 5.4, 5.5, 8.2).
//   BOOT -> CLR -> TEST -> DRAIN -> BIRA -> ZERO -> ONLINE      (ONLINE -> WAITQ -> CLR for MAINT)
// TEST: destructive March over all 514 physical rows x 74 IOs through the raw array path,
//       pipeline T0 issue / T1 array / T2 compare / T3 log.
// ZERO: write a zero codeword to all 4096 logical words through the programmed remap.
module sg_ctl
  import sg_pkg::*;
(
  input  logic          clk,
  input  logic          rst_n,
  input  cfg_t          cfg,
  input  logic          maint_req,        // pulse from CSR
  input  logic          fuse_vld,         // saved repair signature present at reset
  input  logic [37:0]   fuse_sig,

  // coordination with the online side
  input  logic          win_idle,
  input  logic          arb_quiet,
  output logic          maint_pending,
  output logic [1:0]    mode,
  output logic          fn_en,

  // sequencer
  output logic          mb_start,
  output logic [2:0]    mb_alg,
  output logic [10:0]   mb_nrows,
  output logic          mb_stop,
  output logic          mb_ack,
  input  logic          mb_done,
  input  logic          mb_op_valid,
  input  logic [9:0]    mb_op_row,
  input  logic [2:0]    mb_op_col,
  input  logic          mb_op_rw,
  input  logic          mb_op_pol,

  // raw array master
  output arr_cmd_t      x_cmd,
  input  logic [PIO-1:0] rd74,

  // fault log / BIRA
  output logic          flog_clr,
  output logic          ins_v,
  output logic [9:0]    ins_row,
  output logic [PIO-1:0] ins_mask,
  input  logic [FLOG_DEPTH-1:0]            fl_v,
  input  logic [FLOG_DEPTH-1:0][9:0]       fl_row,
  input  logic [FLOG_DEPTH-1:0][PIO-1:0]   fl_mask,
  input  logic          fl_ovf,

  // remap programming
  output logic          remap_clr,
  output logic          remap_load_en,
  output logic [37:0]   remap_load_sig,

  // status / events
  output logic          mbist_fail,
  output logic          repair_ok,
  output logic          repair_fail,
  output logic          irq_done,
  output logic          ev_testcy,
  output logic          ev_hard_off,     // pulse: a destructive test finished with logged faults
  output logic          bm_push,         // bitmap-dump entry
  output logic [PIO+12:0] bm_data
);

  typedef enum logic [3:0] {C_BOOT, C_CLR, C_START, C_TEST, C_DRAIN, C_BIRA, C_BIRAW, C_ZERO, C_ONLINE, C_WAITQ} cstate_e;
  cstate_e st;
  logic [1:0] mode_q;
  logic [12:0] z_cnt;
  logic [2:0]  dr_cnt;
  logic [3:0]  q_cnt;
  logic        from_maint;

  // ---- BIRA
  logic bira_start, bira_busy, bira_done, bira_ok, bira_fail, bira_prog_en;
  logic [37:0] bira_sig;
  sg_bira u_bira (
    .clk(clk), .rst_n(rst_n), .start(bira_start),
    .e_v(fl_v), .e_row(fl_row), .e_mask(fl_mask), .ovf(fl_ovf),
    .busy(bira_busy), .done(bira_done), .ok(bira_ok), .fail(bira_fail),
    .prog_en(bira_prog_en), .prog_sig(bira_sig)
  );

  // ---- raw test op issue (always granted in TEST)
  logic in_test;
  assign in_test = (st == C_TEST);
  logic [PIO-1:0] bgv;
  assign bgv = bg_data(cfg.bg, mb_op_row, mb_op_col);

  assign mb_ack   = in_test && mb_op_valid;
  assign mb_alg   = cfg.alg_poweron;
  assign mb_nrows = 11'(PROWS);
  assign mb_start = (st == C_START);

  assign ev_testcy = mb_ack;

  always_comb begin
    x_cmd = '0;
    if (in_test && mb_op_valid) begin
      x_cmd.en = 1'b1; x_cmd.we = mb_op_rw; x_cmd.rowraw = 1'b1; x_cmd.ioraw = 1'b1;
      x_cmd.addr = {mb_op_row, mb_op_col};
      x_cmd.wdata = bgv ^ {PIO{mb_op_pol}};
    end else if (st == C_ZERO) begin
      x_cmd.en = 1'b1; x_cmd.we = 1'b1;
      x_cmd.addr = {1'b0, z_cnt[11:0]};
      x_cmd.wdata = '0;
    end
  end

  // ---- compare pipeline T1/T2/T3
  logic            c1_v;
  logic [9:0]      c1_row;
  logic [2:0]      c1_col, c2_col;
  logic [PIO-1:0]  c1_exp;
  logic            c2_v;
  logic [9:0]      c2_row;
  logic [PIO-1:0]  c2_vec;
  logic [PIO-1:0]  fail_vec;
  assign fail_vec = rd74 ^ c1_exp;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c1_v <= 1'b0; c1_row <= '0; c1_col <= '0; c2_col <= '0; c1_exp <= '0; c2_v <= 1'b0; c2_row <= '0; c2_vec <= '0;
    end else begin
      c1_v <= mb_ack && !mb_op_rw;
      c1_row <= mb_op_row; c1_col <= mb_op_col; c2_col <= c1_col; c1_exp <= bgv ^ {PIO{mb_op_pol}};
      c2_v <= c1_v && (fail_vec != '0);
      c2_row <= c1_row; c2_vec <= fail_vec;
    end
  end

  assign bm_push = c2_v && (cfg.diag == DIAG_BITMAP);
  assign bm_data = {c2_row, c2_col, c2_vec};

  assign ins_v = c2_v;
  assign ins_row = c2_row;
  assign ins_mask = c2_vec;

  assign mb_stop = c2_v && (cfg.diag == DIAG_GONOGO) && in_test;

  // ---- quiet detector before MAINT starts
  logic [3:0] idle_q;
  assign maint_pending = (st == C_WAITQ);

  assign fn_en = (mode_q == MODE_ONLINE);
  assign mode  = mode_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= C_BOOT; mode_q <= MODE_RESET_TEST; z_cnt <= '0; dr_cnt <= '0; q_cnt <= '0;
      mbist_fail <= 1'b0; repair_ok <= 1'b0; repair_fail <= 1'b0; irq_done <= 1'b0; ev_hard_off <= 1'b0;
      flog_clr <= 1'b0; remap_clr <= 1'b0; remap_load_en <= 1'b0; remap_load_sig <= '0;
      bira_start <= 1'b0; from_maint <= 1'b0;
    end else begin
      irq_done <= 1'b0; ev_hard_off <= 1'b0; flog_clr <= 1'b0; remap_clr <= 1'b0; remap_load_en <= 1'b0; bira_start <= 1'b0;

      if (c2_v) mbist_fail <= 1'b1;

      case (st)
        C_BOOT: begin
          if (fuse_vld) begin
            remap_load_en <= 1'b1; remap_load_sig <= fuse_sig;
            repair_ok <= 1'b1; z_cnt <= '0; st <= C_ZERO;
          end else if (BYPASS_RESET) begin
            z_cnt <= '0; st <= C_ZERO;
          end else st <= C_CLR;
        end

        C_CLR: begin
          flog_clr <= 1'b1; remap_clr <= 1'b1;
          mbist_fail <= 1'b0; repair_ok <= 1'b0; repair_fail <= 1'b0;
          st <= C_START;
        end

        C_START: st <= C_TEST;                            // mb_start pulses this cycle

        C_TEST: if (mb_done) begin dr_cnt <= '0; st <= C_DRAIN; end

        C_DRAIN: begin
          dr_cnt <= dr_cnt + 3'd1;
          if (dr_cnt == 3'd3) begin
            ev_hard_off <= (|fl_v) || mbist_fail;
            if (cfg.diag == DIAG_GONOGO || !cfg.repair_en) begin z_cnt <= '0; st <= C_ZERO; end
            else begin bira_start <= 1'b1; st <= C_BIRA; end
          end
        end

        C_BIRA: st <= C_BIRAW;

        C_BIRAW: if (bira_done) begin
          repair_ok <= bira_ok; repair_fail <= bira_fail;
          remap_load_en <= bira_prog_en; remap_load_sig <= bira_sig;
          z_cnt <= '0; st <= C_ZERO;
        end

        C_ZERO: begin
          z_cnt <= z_cnt + 13'd1;
          if (z_cnt == 13'(DEPTH - 1)) begin
            mode_q <= MODE_ONLINE; irq_done <= 1'b1; st <= C_ONLINE;
          end
        end

        C_ONLINE: if (maint_req) begin q_cnt <= '0; st <= C_WAITQ; end

        C_WAITQ: begin
          if (win_idle && arb_quiet) begin
            if (q_cnt == 4'd6) begin mode_q <= MODE_MAINT; st <= C_CLR; end
            else q_cnt <= q_cnt + 4'd1;
          end else q_cnt <= '0;
        end

        default: st <= C_BOOT;
      endcase
    end
  end
endmodule
