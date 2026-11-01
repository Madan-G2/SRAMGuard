// Functional port + arbiter + ECC datapath (spec sections 6.4, 7.2, 9.1, 9.2).
//
// Per-cycle array priority (ONLINE):
//   1. second half of a read-modify-write already in flight
//   2. functional request (reads inside the window are served from the segment buffer and
//      leave the array free)
//   3. window-engine operation (capture, repair copy, test/scrub) in a free cycle
//   5. forced test slot (TEST_MIN_BW) blocks priority 2 once every K cycles
//
// Return pipeline: tag is registered at issue; the array data is valid one cycle later;
// ECC decode is registered when ECC_PIPE = 1, so a functional read answers LAT = 2 cycles
// after acceptance (writes answer after the same delay, which keeps responses in order).
module sg_arb
  import sg_pkg::*;
(
  input  logic          clk,
  input  logic          rst_n,
  input  logic          fn_en,            // ONLINE: functional port open
  input  logic [15:0]   test_min_bw,

  // ECC error injection (spec 7.5)
  input  logic          inj_arm,
  input  logic [WORD_W-1:0] inj_mask,
  output logic          inj_clr,

  // functional port
  input  logic          req_valid,
  output logic          req_ready,
  input  logic          req_we,
  input  logic [11:0]   req_addr,
  input  logic [DATA_W-1:0] req_wdata,
  input  logic [7:0]    req_be,
  output logic          rsp_valid,
  output logic [DATA_W-1:0] rsp_rdata,
  output logic          rsp_ce,
  output logic          rsp_ue,

  // segment buffer lookup / update
  output logic [11:0]   f_addr,
  input  logic          f_valid,
  input  logic          f_pend,
  input  logic [3:0]    f_idx,
  input  logic [WORD_W-1:0] f_ref,
  input  logic          f_pol,
  output logic          fwr_en,
  output logic [3:0]    fwr_idx,
  output logic [WORD_W-1:0] fwr_cw,

  // window engine
  input  logic          w_valid,
  input  arr_cmd_t      w_cmd,
  input  tag_t          w_tag,
  output logic          w_gnt,
  input  logic          sw_req,
  output logic          sw_go,
  input  logic          rd_act,           // row migration: steer writes of rd_row into spare rd_k
  input  logic [8:0]    rd_row,
  input  logic          rd_k,

  // direct master used outside ONLINE (power-on test, zero fill)
  input  arr_cmd_t      x_cmd,

  // array side
  output arr_cmd_t      a_cmd,
  input  logic [WORD_W-1:0] a_rd72,

  // decoded capture return
  output logic          cap_v,
  output logic [3:0]    cap_idx,
  output logic [WORD_W-1:0] cap_cw,
  output logic [WORD_W-1:0] cap_flip,
  output logic          cap_ce,
  output logic          cap_ue,

  // events / status
  output logic          ev_rsp_ce,
  output logic          ev_rsp_ue,
  output logic          ev_stall,         // cycle a request waited because of test/repair
  output logic          ev_req,
  output logic          ev_arr,
  output logic          ev_idle,
  output logic          rmw_busy,
  output logic [1:0]    stall_run
);

  // ------------------------------------------------------------------ ECC unit
  logic [DATA_W-1:0] enc_data;
  logic [WORD_W-1:0] enc_cw;
  logic [WORD_W-1:0] dec_in, dec_fix;
  logic [DATA_W-1:0] dec_data;
  logic              dec_ce, dec_ue;

  sg_ecc u_ecc (
    .enc_data(enc_data), .enc_cw(enc_cw),
    .dec_cw(dec_in), .dec_data(dec_data), .dec_fix(dec_fix), .dec_ce(dec_ce), .dec_ue(dec_ue)
  );

  // ------------------------------------------------------------------ return pipeline
  tag_t              tag_q, tag_issue;
  logic [WORD_W-1:0] byp_q, byp_issue;

  assign dec_in = (tag_q.kind == K_FBYP) ? byp_q : a_rd72;

  logic              ds_v;
  tag_t              ds_tag;
  logic [DATA_W-1:0] ds_data;
  logic [WORD_W-1:0] ds_cw, ds_flip;
  logic              ds_ce, ds_ue;

  generate
    if (ECC_PIPE) begin : g_pipe
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          ds_v <= 1'b0; ds_tag <= '0; ds_data <= '0; ds_cw <= '0; ds_flip <= '0; ds_ce <= 1'b0; ds_ue <= 1'b0;
        end else begin
          ds_v <= (tag_q.kind != K_NONE); ds_tag <= tag_q;
          ds_data <= dec_data; ds_cw <= dec_fix; ds_flip <= dec_in ^ dec_fix; ds_ce <= dec_ce; ds_ue <= dec_ue;
        end
      end
    end else begin : g_nopipe
      assign ds_v = (tag_q.kind != K_NONE);
      assign ds_tag = tag_q;
      assign ds_data = dec_data; assign ds_cw = dec_fix; assign ds_flip = dec_in ^ dec_fix; assign ds_ce = dec_ce; assign ds_ue = dec_ue;
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tag_q <= '0; byp_q <= '0; end
    else begin tag_q <= tag_issue; byp_q <= byp_issue; end
  end

  assign cap_v   = ds_v && (ds_tag.kind == K_CAP);
  assign cap_idx = ds_tag.idx;
  assign cap_cw  = ds_cw;
  assign cap_flip = ds_flip;
  assign cap_ce  = ds_ce;
  assign cap_ue  = ds_ue;

  // ------------------------------------------------------------------ RMW context
  logic              rmw_v;
  logic [11:0]       rmw_addr;
  logic [DATA_W-1:0] rmw_wdata;
  logic [7:0]        rmw_be;
  logic [WORD_W-1:0] rmw_mask;
  logic              rmw_wr_now;
  logic [DATA_W-1:0] rmw_merged;

  assign rmw_busy   = rmw_v;
  assign rmw_wr_now = ds_v && (ds_tag.kind == K_RMW);

  function automatic logic [DATA_W-1:0] merge(input logic [DATA_W-1:0] old_d,
                                              input logic [DATA_W-1:0] new_d,
                                              input logic [7:0] be);
    logic [DATA_W-1:0] r;
    for (int i = 0; i < 8; i++) r[8*i +: 8] = be[i] ? new_d[8*i +: 8] : old_d[8*i +: 8];
    return r;
  endfunction

  assign rmw_merged = merge(ds_data, rmw_wdata, rmw_be);

  // ------------------------------------------------------------------ request acceptance
  logic is_partial, haz_rmw, haz_pend, forced, forced_block, req_fire;
  logic f_buf_read, f_uses_arr;
  logic cap_hit, fw_valid;             // capture result of the addressed word returns this cycle
  logic [WORD_W-1:0] fw_ref;
  logic [15:0] bw_cnt;
  logic [WORD_W-1:0] mask;

  assign f_addr     = req_addr;
  assign is_partial = req_we && (req_be != 8'hFF);
  assign mask       = inj_arm ? inj_mask : '0;

  // A write to a word whose capture read is in flight waits for the result.  On the cycle the
  // result returns it is taken straight from the decoder (cap_cw), so the wait is bounded by the
  // capture latency and a forced test slot plus this wait still fits in MAX_STALL.
  assign cap_hit  = cap_v && f_pend && (cap_idx == f_idx) && !cap_ue;
  assign fw_valid = f_valid || cap_hit;
  assign fw_ref   = cap_hit ? cap_cw : f_ref;

  assign haz_rmw  = rmw_v && ((req_addr == rmw_addr) || (is_partial && !fw_valid));
  assign haz_pend = req_we && f_pend && !cap_hit;
  assign forced   = (test_min_bw != 16'd0) && (bw_cnt >= test_min_bw - 16'd1);
  // The forced slot always wins, even against a request to the very word the window operation
  // needs: otherwise a stream aimed at that word starves the window (spec 6.5).  Its cost is one
  // stall cycle, plus at most the capture wait above.
  assign forced_block = fn_en && forced && w_valid && !rmw_v && (stall_run == 2'd0);
  assign sw_go    = fn_en && sw_req && !rmw_v && (stall_run == 2'd0);

  assign req_ready = fn_en && !rmw_wr_now && !forced_block && !sw_go && !haz_rmw && !haz_pend;
  assign req_fire  = req_valid && req_ready;

  assign f_buf_read = req_fire && !req_we && f_valid;
  assign f_uses_arr = req_fire && !f_buf_read;

  // encoder input: RMW write phase, in-window partial merge, or plain write data
  always_comb begin
    if (rmw_wr_now)                 enc_data = rmw_merged;
    else if (is_partial && fw_valid) enc_data = merge(fw_ref[DATA_W-1:0], req_wdata, req_be);
    else                            enc_data = req_wdata;
  end

  // ------------------------------------------------------------------ array command mux
  always_comb begin
    a_cmd = '0; tag_issue = '0; byp_issue = '0; w_gnt = 1'b0;
    fwr_en = 1'b0; fwr_idx = f_idx; fwr_cw = enc_cw; inj_clr = 1'b0;

    if (!fn_en) begin
      a_cmd = x_cmd;
    end else if (rmw_wr_now) begin
      if (!ds_ue) begin
        a_cmd.en = 1'b1; a_cmd.we = 1'b1; a_cmd.addr = {1'b0, rmw_addr};
        a_cmd.wdata = {{PIO-WORD_W{1'b0}}, enc_cw ^ rmw_mask};
      end
    end else if (req_fire) begin
      if (!req_we) begin
        if (f_valid) begin
          tag_issue = '{kind: K_FBYP, idx: '0}; byp_issue = f_ref;     // served from the buffer
        end else begin
          a_cmd.en = 1'b1; a_cmd.addr = {1'b0, req_addr};
          tag_issue = '{kind: K_FRD, idx: '0};
        end
      end else if (is_partial && !fw_valid) begin
        // read-modify-write, first half
        a_cmd.en = 1'b1; a_cmd.addr = {1'b0, req_addr};
        tag_issue = '{kind: K_RMW, idx: '0};
        inj_clr = inj_arm;
      end else begin
        a_cmd.en = 1'b1; a_cmd.we = 1'b1; a_cmd.addr = {1'b0, req_addr};
        tag_issue = '{kind: K_FWR, idx: '0};
        inj_clr = inj_arm;
        if (fw_valid) begin
          // inside the window: ref takes the new word, array stays ref ^ pol
          fwr_en = 1'b1;
          a_cmd.wdata = {{PIO-WORD_W{1'b0}}, (enc_cw ^ {WORD_W{f_pol}}) ^ mask};
          if (rd_act && req_addr[11:3] == rd_row) begin
            // row being migrated: its reads come from the buffer, so the old row is dead;
            // the write goes to the spare row, which therefore always matches the buffer
            a_cmd.rowraw = 1'b1;
            a_cmd.addr = {10'(ROWS) + 10'(rd_k), req_addr[2:0]};
          end
        end else begin
          a_cmd.wdata = {{PIO-WORD_W{1'b0}}, enc_cw ^ mask};
        end
      end
    end

    // The window engine uses the array only when nothing above did.  A buffer-served read
    // leaves the array free but owns the single ECC decoder in the next cycle, so a window
    // operation that also returns through the decoder (capture) has to wait.
    if (fn_en && !rmw_wr_now && !f_uses_arr && !rmw_v && w_valid &&
        !(f_buf_read && w_tag.kind != K_NONE)) begin
      a_cmd = w_cmd; w_gnt = 1'b1;
      if (w_tag.kind != K_NONE) tag_issue = w_tag;
    end
  end

  // ------------------------------------------------------------------ RMW state, counters
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rmw_v <= 1'b0; rmw_addr <= '0; rmw_wdata <= '0; rmw_be <= '0; rmw_mask <= '0;
      bw_cnt <= '0; stall_run <= '0;
    end else begin
      if (req_fire && req_we && is_partial && !fw_valid) begin
        rmw_v <= 1'b1; rmw_addr <= req_addr; rmw_wdata <= req_wdata; rmw_be <= req_be;
        rmw_mask <= mask;
      end else if (rmw_wr_now) rmw_v <= 1'b0;

      if (w_gnt) bw_cnt <= '0;
      else if (bw_cnt != 16'hFFFF) bw_cnt <= bw_cnt + 16'd1;

      if (req_valid && !req_ready) stall_run <= (stall_run == 2'd3) ? 2'd3 : stall_run + 2'd1;
      else                         stall_run <= 2'd0;
    end
  end

  // ------------------------------------------------------------------ response
  always_comb begin
    rsp_valid = 1'b0; rsp_rdata = '0; rsp_ce = 1'b0; rsp_ue = 1'b0;
    if (ds_v) begin
      case (ds_tag.kind)
        K_FRD, K_FBYP: begin rsp_valid = 1'b1; rsp_rdata = ds_data; rsp_ce = ds_ce; rsp_ue = ds_ue; end
        K_FWR:         begin rsp_valid = 1'b1; end
        K_RMW:         begin rsp_valid = 1'b1; rsp_ce = ds_ce; rsp_ue = ds_ue; end
        default: ;
      endcase
    end
  end

  assign ev_rsp_ce = rsp_valid && rsp_ce;
  assign ev_rsp_ue = rsp_valid && rsp_ue;
  assign ev_stall  = req_valid && fn_en && (forced_block || sw_go || haz_pend);
  assign ev_req    = req_fire;
  assign ev_arr    = a_cmd.en;
  assign ev_idle   = fn_en && !a_cmd.en;

endmodule
