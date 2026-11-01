// Online window engine (spec sections 6, 7.3, 8.3).
//
//   IDLE -> CAP -> CAPWAIT -+-> MSTART -> MARCH -> DRAIN -> CLASS -+-> REL
//                           |                         ^            |
//                           |                         +-rerun------+
//                           +-> SCRUBWB -> REL          CLASS -> LOG -> REP_COPY <-> REP_VER -> REP_SW -> REL
//
//   REL -> RS_WR <-> RS_RD -> REL   restore pass after a window that saw a mismatch
//
// Capture reads the 16 words of the window through ECC into the segment buffer.  The
// transparent March then writes `ref ^ pol` and compares every read exactly against
// `ref ^ pol`.  A mismatch re-runs the window once; a repeat at the same IO is a hard fault.
// A hard fault in a regular row can be migrated into a spare row while the window keeps
// the row locked in the buffer.
module sg_win
  import sg_pkg::*;
(
  input  logic          clk,
  input  logic          rst_n,
  input  logic          online_en,       // ONLINE mode, not bypassed, no maintenance pending
  input  logic          test_en,
  input  logic          scrub_en,
  input  logic          repair_en,
  input  logic          orepair_en,
  input  logic [2:0]    alg_sel,
  input  logic [8:0]    sc_base,
  input  logic          sc_go,
  input  logic          sc_ovr,
  output logic          idle,

  // March sequencer
  output logic          mb_start,
  output logic [2:0]    mb_alg,
  output logic          mb_ack,
  input  logic          mb_done,
  input  logic          mb_op_valid,
  input  logic [9:0]    mb_op_row,
  input  logic [2:0]    mb_op_col,
  input  logic          mb_op_rw,
  input  logic          mb_op_pol,

  // array master
  output logic          w_valid,
  output arr_cmd_t      w_cmd,
  output tag_t          w_tag,
  input  logic          w_gnt,
  input  logic [WORD_W-1:0] rd72,

  // decoded capture return
  input  logic          ds_cap_v,
  input  logic [3:0]    ds_cap_idx,
  input  logic [WORD_W-1:0] ds_cw,
  input  logic [WORD_W-1:0] ds_flip,
  input  logic          ds_ce,
  input  logic          ds_ue,

  // functional lookup into the buffer
  input  logic [11:0]   f_addr,
  output logic          f_valid,
  output logic          f_pend,
  output logic [3:0]    f_idx,
  output logic [WORD_W-1:0] f_ref,
  output logic          f_pol,
  input  logic          fwr_en,
  input  logic [3:0]    fwr_idx,
  input  logic [WORD_W-1:0] fwr_cw,

  // remap view / control
  input  logic [1:0]    rm_v,
  input  logic [8:0]    rm_row0,
  input  logic [8:0]    rm_row1,
  input  logic [1:0]    rm_bad,
  output logic          remap_set_en,
  output logic          remap_set_k,
  output logic [8:0]    remap_set_row,

  // fault log
  output logic          ins_v,
  output logic [9:0]    ins_row,
  output logic [PIO-1:0] ins_mask,

  // repair switch handshake with the arbiter
  output logic          sw_req,
  input  logic          sw_go,
  // while a row is migrating, functional writes to it are steered into the spare row
  output logic          rd_act,
  output logic [8:0]    rd_row,
  output logic          rd_k,

  // events
  output logic          ev_ce,
  output logic [8:0]    ev_ce_row,
  output logic          ev_ue,
  output logic          ev_df,           // window aborted: capture looks like a decoder fault
  output logic          ev_hard,
  output logic          ev_trans,
  output logic          ev_win_done,
  output logic          ev_repair,
  output logic [8:0]    ev_rep_row,
  output logic          ev_repair_fail,
  output logic          win_open,
  output logic [8:0]    win_base
);

  typedef enum logic [3:0] {
    W_IDLE, W_CAP, W_CAPWAIT, W_SCRUBWB, W_MSTART, W_MARCH, W_DRAIN, W_CLASS, W_LOG,
    W_REP_COPY, W_REP_VER, W_REP_SW, W_REL, W_RS_WR, W_RS_RD
  } wstate_e;

  wstate_e st;

  // ---- segment buffer
  logic        seg_open, seg_close;
  logic        cap_issue_en;
  logic [3:0]  cap_issue_idx;
  logic        pol_set_en;
  logic [3:0]  pol_set_idx;
  logic        pol_set_val;
  logic [3:0]  t_idx;
  logic [WORD_W-1:0] t_ref;
  logic [SEG_WORDS-1:0] all_pol, all_valid;

  sg_segbuf u_seg (
    .clk(clk), .rst_n(rst_n),
    .open(seg_open), .open_base(sc_base), .close(seg_close),
    .win_open(win_open), .base(win_base),
    .f_addr(f_addr), .f_valid(f_valid), .f_pend(f_pend), .f_idx(f_idx), .f_ref(f_ref), .f_pol(f_pol),
    .cap_issue_en(cap_issue_en), .cap_issue_idx(cap_issue_idx),
    .cap_load_en(ds_cap_v), .cap_load_idx(ds_cap_idx), .cap_load_cw(ds_cw), .cap_load_ue(ds_ue),
    .fwr_en(fwr_en), .fwr_idx(fwr_idx), .fwr_cw(fwr_cw),
    .pol_set_en(pol_set_en), .pol_set_idx(pol_set_idx), .pol_set_val(pol_set_val),
    .t_idx(t_idx), .t_ref(t_ref), .all_pol(all_pol), .all_valid(all_valid)
  );

  // ---- registers
  logic [4:0]  cap_cnt;                 // capture reads issued
  logic [4:0]  cap_ret;                 // capture results returned
  logic [SEG_WORDS-1:0] ce_word;
  logic        ue_seen;
  logic        df_seen;                 // decoder-fault pattern seen in the capture (spec 6.6)
  logic [WORD_W-1:0] df_union;          // union of corrected bit positions seen in this capture
  logic [6:0]  df_n;                    // number of distinct positions
  logic        used_ovr;
  logic        second;                  // second (confirmation) run
  logic [WORD_W-1:0] cur [SEG_ROWS];
  logic [WORD_W-1:0] m1  [SEG_ROWS];
  logic [WORD_W-1:0] hardm [SEG_ROWS];
  logic [4:0]  wb_cnt;
  logic        log_k;
  logic [7:0] rep_need;
  logic        rep_off;                 // which window row is being repaired
  logic        rep_k;                   // chosen spare
  logic [3:0]  ver_cnt;
  logic        ver_ok;
  logic [2:0]  retries;
  logic        trans_pend;
  // restore pass (transparency after a window that saw a mismatch): a decoder fault can make the
  // test's own writes to one word clobber another word of the window, which neither the
  // fault log nor the repair would put right.
  logic        rst_need;
  logic [SEG_WORDS-1:0] rs_sel, rs_bad;
  logic [4:0]  rs_cnt;
  logic [1:0]  rs_iter;
  logic        cmp_rs;

  // compare pipeline (array result arrives one cycle after the grant)
  logic        cmp_v, cmp_is_ver;
  logic [3:0]  cmp_idx;
  logic [WORD_W-1:0] cmp_exp;

  assign idle = (st == W_IDLE);

  function automatic logic [8:0] row_of(input logic [8:0] b, input logic off);
    return b + {8'd0, off};
  endfunction

  // ---- combinational request generation
  logic [3:0] cp_w;                     // lowest word still to copy
  logic       cp_any;
  always_comb begin
    cp_any = 1'b0; cp_w = '0;
    for (int i = 7; i >= 0; i--) if (rep_need[i]) begin cp_any = 1'b1; cp_w = 4'(i); end
  end

  always_comb begin
    w_valid = 1'b0; w_cmd = '0; w_tag = '0;
    t_idx = '0; cap_issue_en = 1'b0; cap_issue_idx = cap_cnt[3:0];
    pol_set_en = 1'b0; pol_set_idx = '0; pol_set_val = 1'b0;
    mb_ack = 1'b0;
    case (st)
      W_CAP: begin
        w_valid = 1'b1;
        w_cmd.en = 1'b1;
        w_cmd.addr = {1'b0, row_of(win_base, cap_cnt[3]), cap_cnt[2:0]};
        w_tag = '{kind: K_CAP, idx: cap_cnt[3:0]};
        cap_issue_en = w_gnt;
      end
      W_SCRUBWB: if (wb_cnt < 5'd16 && ce_word[wb_cnt[3:0]]) begin
        t_idx = wb_cnt[3:0];
        w_valid = 1'b1;
        w_cmd.en = 1'b1; w_cmd.we = 1'b1;
        w_cmd.addr = {1'b0, row_of(win_base, wb_cnt[3]), wb_cnt[2:0]};
        w_cmd.wdata = {{PIO-WORD_W{1'b0}}, t_ref};
      end
      W_MARCH: begin
        t_idx = {mb_op_row[0], mb_op_col};
        w_valid = mb_op_valid;
        w_cmd.en = 1'b1; w_cmd.we = mb_op_rw;
        w_cmd.addr = {1'b0, row_of(win_base, mb_op_row[0]), mb_op_col};
        w_cmd.wdata = {{PIO-WORD_W{1'b0}}, t_ref ^ {WORD_W{mb_op_pol}}};
        mb_ack = w_gnt;
        pol_set_en = w_gnt && mb_op_rw;
        pol_set_idx = t_idx;
        pol_set_val = mb_op_pol;
      end
      W_REP_COPY: if (cp_any) begin
        t_idx = {rep_off, cp_w[2:0]};
        w_valid = 1'b1;
        w_cmd.en = 1'b1; w_cmd.we = 1'b1; w_cmd.rowraw = 1'b1;
        w_cmd.addr = {10'(ROWS) + 10'(rep_k), cp_w[2:0]};
        w_cmd.wdata = {{PIO-WORD_W{1'b0}}, t_ref};
      end
      W_REP_VER: if (ver_cnt < 4'd8) begin
        t_idx = {rep_off, ver_cnt[2:0]};
        w_valid = 1'b1;
        w_cmd.en = 1'b1; w_cmd.rowraw = 1'b1;
        w_cmd.addr = {10'(ROWS) + 10'(rep_k), ver_cnt[2:0]};
      end
      W_RS_WR: if (rs_cnt < 5'd16 && rs_sel[rs_cnt[3:0]]) begin
        t_idx = rs_cnt[3:0];
        w_valid = 1'b1;
        w_cmd.en = 1'b1; w_cmd.we = 1'b1;
        w_cmd.addr = {1'b0, row_of(win_base, rs_cnt[3]), rs_cnt[2:0]};
        w_cmd.wdata = {{PIO-WORD_W{1'b0}}, t_ref};
      end
      W_RS_RD: if (rs_cnt < 5'd16) begin
        t_idx = rs_cnt[3:0];
        w_valid = 1'b1;
        w_cmd.en = 1'b1;
        w_cmd.addr = {1'b0, row_of(win_base, rs_cnt[3]), rs_cnt[2:0]};
      end
      default: ;
    endcase
  end

  // ---- spare availability / hard-fault bookkeeping
  logic [8:0] hrow;
  logic       h_any, h_k;
  logic       row_remapped, spare_free, spare_pick;
  assign h_k   = (hardm[0] == '0);                 // 1 -> row 1 is the first faulty row
  assign h_any = (hardm[0] != '0) || (hardm[1] != '0);
  assign hrow  = row_of(win_base, h_k);
  assign row_remapped = (rm_v[0] && rm_row0 == hrow) || (rm_v[1] && rm_row1 == hrow);
  always_comb begin
    spare_free = 1'b0; spare_pick = 1'b0;
    if (!rm_v[0] && !rm_bad[0]) begin spare_free = 1'b1; spare_pick = 1'b0; end
    else if (!rm_v[1] && !rm_bad[1]) begin spare_free = 1'b1; spare_pick = 1'b1; end
  end

  // ---- fault-log and remap outputs
  always_comb begin
    ins_v = 1'b0; ins_row = '0; ins_mask = '0;
    ev_hard = 1'b0;
    if (st == W_LOG && hardm[log_k] != '0) begin
      ins_v = 1'b1; ins_row = {1'b0, row_of(win_base, log_k)};
      ins_mask = {{PIO-WORD_W{1'b0}}, hardm[log_k]};
      ev_hard = 1'b1;
    end
    rd_act = (st == W_REP_COPY) || (st == W_REP_VER) || (st == W_REP_SW);
    rd_row = row_of(win_base, rep_off);
    rd_k   = rep_k;
    sw_req = (st == W_REP_SW) && (rep_need == 8'h00);
    remap_set_en = sw_req && sw_go;
    remap_set_k = rep_k;
    remap_set_row = row_of(win_base, rep_off);
    ev_rep_row = remap_set_row;
    ev_repair = remap_set_en;
  end

  // ---- control
  assign seg_open  = (st == W_IDLE) && online_en && (test_en || scrub_en) && sc_go && !win_open;
  assign seg_close = (st == W_REL) && !rst_need;

  assign mb_start = (st == W_MSTART);
  assign mb_alg   = used_ovr ? 3'(ALG_MARCHSS) : alg_sel;

  logic cap_ret_done;
  assign cap_ret_done = (cap_ret == 5'd16);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= W_IDLE; cap_cnt <= '0; cap_ret <= '0; ce_word <= '0; ue_seen <= 1'b0;
      df_seen <= 1'b0; df_union <= '0; df_n <= '0; ev_df <= 1'b0;
      used_ovr <= 1'b0; second <= 1'b0; wb_cnt <= '0; log_k <= 1'b0; rep_need <= '0;
      rep_off <= 1'b0; rep_k <= 1'b0; ver_cnt <= '0; ver_ok <= 1'b1; retries <= '0;
      trans_pend <= 1'b0; rst_need <= 1'b0; rs_sel <= '0; rs_bad <= '0; rs_cnt <= '0; rs_iter <= '0; cmp_rs <= 1'b0;
      cmp_v <= 1'b0; cmp_is_ver <= 1'b0; cmp_idx <= '0; cmp_exp <= '0;
      for (int i = 0; i < SEG_ROWS; i++) begin cur[i] <= '0; m1[i] <= '0; hardm[i] <= '0; end
      ev_ce <= 1'b0; ev_ce_row <= '0; ev_ue <= 1'b0; ev_trans <= 1'b0; ev_win_done <= 1'b0;
      ev_repair_fail <= 1'b0;
    end else begin
      ev_ce <= 1'b0; ev_ue <= 1'b0; ev_df <= 1'b0; ev_trans <= 1'b0; ev_win_done <= 1'b0; ev_repair_fail <= 1'b0;
      cmp_v <= 1'b0; cmp_rs <= 1'b0;

      // capture results (any time after the first capture read)
      if (ds_cap_v) begin
        cap_ret <= cap_ret + 5'd1;
        if (ds_ue) begin ue_seen <= 1'b1; ev_ue <= 1'b1; end
        else if (ds_ce) begin
          ce_word[ds_cap_idx] <= 1'b1; ev_ce <= 1'b1;
          ev_ce_row <= row_of(win_base, ds_cap_idx[3]);
          if ((ds_flip & ~df_union) != '0) begin
            df_union <= df_union | ds_flip;
            df_n <= df_n + 7'd1;
            if (df_n + 7'd1 == 7'(DF_TH)) begin df_seen <= 1'b1; ev_df <= 1'b1; end
          end
        end
      end

      // compare pipeline: result of the read granted in the previous cycle
      if (cmp_v) begin
        if (cmp_rs) begin
          if (rd72 != cmp_exp) rs_bad[cmp_idx] <= 1'b1;
        end else if (cmp_is_ver) begin
          if (rd72 != cmp_exp) begin rep_need[cmp_idx[2:0]] <= 1'b1; ver_ok <= 1'b0; end
        end else begin
          cur[cmp_idx[3]] <= cur[cmp_idx[3]] | (rd72 ^ cmp_exp);
        end
      end

      case (st)
        W_IDLE: if (seg_open) begin
          st <= W_CAP; cap_cnt <= '0; cap_ret <= '0; ce_word <= '0; ue_seen <= 1'b0;
          df_seen <= 1'b0; df_union <= '0; df_n <= '0;
          used_ovr <= sc_ovr; second <= 1'b0; trans_pend <= 1'b0; retries <= '0; rst_need <= 1'b0;
          for (int i = 0; i < SEG_ROWS; i++) begin cur[i] <= '0; m1[i] <= '0; hardm[i] <= '0; end
        end

        W_CAP: if (w_gnt) begin
          cap_cnt <= cap_cnt + 5'd1;
          if (cap_cnt == 5'd15) st <= W_CAPWAIT;
        end

        W_CAPWAIT: if (cap_ret_done) begin
          if (ue_seen || df_seen) st <= W_REL;             // no trusted reference / decoder fault: abort window
          else if (test_en || used_ovr) st <= W_MSTART;
          else begin st <= W_SCRUBWB; wb_cnt <= '0; end
        end

        W_SCRUBWB: begin
          if (wb_cnt == 5'd16) st <= W_REL;
          else if (!ce_word[wb_cnt[3:0]]) wb_cnt <= wb_cnt + 5'd1;
          else if (w_gnt) wb_cnt <= wb_cnt + 5'd1;
        end

        W_MSTART: st <= W_MARCH;

        W_MARCH: begin
          if (w_gnt && !mb_op_rw) begin
            cmp_v <= 1'b1; cmp_is_ver <= 1'b0; cmp_idx <= t_idx;
            cmp_exp <= t_ref ^ {WORD_W{mb_op_pol}};
          end
          if (mb_done) st <= W_DRAIN;
        end

        W_DRAIN: st <= W_CLASS;

        W_CLASS: begin
          if (!second) begin
            if (cur[0] != '0 || cur[1] != '0) begin
              rst_need <= 1'b1;
              m1[0] <= cur[0]; m1[1] <= cur[1];
              cur[0] <= '0; cur[1] <= '0;
              second <= 1'b1; st <= W_MSTART;
            end else st <= W_REL;
          end else begin
            for (int k = 0; k < SEG_ROWS; k++) hardm[k] <= m1[k] & cur[k];
            if (((m1[0] & ~cur[0]) != '0) || ((m1[1] & ~cur[1]) != '0) ||
                ((cur[0] & ~m1[0]) != '0) || ((cur[1] & ~m1[1]) != '0))
              ev_trans <= 1'b1;
            if ((m1[0] & cur[0]) != '0 || (m1[1] & cur[1]) != '0) begin st <= W_LOG; log_k <= 1'b0; end
            else st <= W_REL;
          end
        end

        W_LOG: begin
          if (log_k == 1'b0) log_k <= 1'b1;
          else begin
            // decide on online row repair for the first faulty row
            if (repair_en && orepair_en) begin
              if (!row_remapped && spare_free) begin
                rep_off <= h_k; rep_k <= spare_pick; rep_need <= 8'hFF;
                ver_ok <= 1'b1; retries <= '0; st <= W_REP_COPY;
              end else begin
                ev_repair_fail <= 1'b1; st <= W_REL;
              end
            end else st <= W_REL;
          end
        end

        W_REP_COPY: begin
          if (w_gnt) rep_need[cp_w[2:0]] <= 1'b0;
          if (!cp_any) begin ver_cnt <= '0; ver_ok <= 1'b1; st <= W_REP_VER; end
        end

        W_REP_VER: begin
          if (w_gnt) begin
            ver_cnt <= ver_cnt + 4'd1;
            cmp_v <= 1'b1; cmp_is_ver <= 1'b1; cmp_idx <= t_idx; cmp_exp <= t_ref;
          end
          if (ver_cnt == 4'd8 && !cmp_v) begin
            if (rep_need == 8'h00 && ver_ok) st <= W_REP_SW;
            else if (retries == 3'd3) begin ev_repair_fail <= 1'b1; st <= W_REL; end
            else begin retries <= retries + 3'd1; rep_need <= rep_need | 8'hFF; st <= W_REP_COPY; end
          end
        end

        W_REP_SW: begin
          if (rep_need != 8'h00) st <= W_REP_COPY;        // verify found a mismatch
          else if (sw_go) st <= W_REL;
        end

        W_REL: begin
          if (rst_need) begin
            rst_need <= 1'b0; rs_sel <= '1; rs_cnt <= '0; rs_iter <= '0; st <= W_RS_WR;
          end else begin
            ev_win_done <= 1'b1; st <= W_IDLE;
          end
        end

        // restore: write every word back from the buffer, read all back, rewrite what differs
        W_RS_WR: begin
          if (rs_cnt == 5'd16) begin rs_cnt <= '0; rs_bad <= '0; st <= W_RS_RD; end
          else if (!rs_sel[rs_cnt[3:0]] || w_gnt) rs_cnt <= rs_cnt + 5'd1;
        end

        W_RS_RD: begin
          if (rs_cnt < 5'd16) begin
            if (w_gnt) begin
              rs_cnt <= rs_cnt + 5'd1;
              cmp_v <= 1'b1; cmp_rs <= 1'b1; cmp_idx <= t_idx; cmp_exp <= t_ref;
            end
          end else if (!cmp_v) begin
            if (rs_bad != '0 && rs_iter != 2'd2) begin
              rs_sel <= rs_bad; rs_iter <= rs_iter + 2'd1; rs_cnt <= '0; st <= W_RS_WR;
            end else st <= W_REL;
          end
        end

        default: st <= W_IDLE;
      endcase
    end
  end
endmodule
