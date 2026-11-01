// Concurrent assertions and cover points for SRAMGuard, bound into sg_top.
// Written to be formal-friendly (no $urandom, no testbench state) so the same file can be taken
// to a formal tool; in simulation a failure is also reported through the UVM report server.
`define SG_ASSERT(NAME, PROP) \
  NAME: assert property (PROP) else uvm_pkg::uvm_report_error("SVA", `"NAME failed`", uvm_pkg::UVM_NONE);
`define SG_COVER(NAME, PROP) \
  NAME: cover property (PROP);

module sg_sva
  import sg_pkg::*;
(
  input logic          clk,
  input logic          rst_n,
  // functional port
  input logic          fn_en,
  input logic          req_valid, req_ready, req_we,
  input logic [11:0]   req_addr,
  input logic [63:0]   req_wdata,
  input logic [7:0]    req_be,
  input logic          rsp_valid, rsp_ce, rsp_ue,
  input logic [1:0]    stall_run,
  // arbiter internals
  input logic          f_uses_arr, rmw_v, rmw_wr_now, ds_ue, haz_rmw, haz_pend, forced_block,
  input logic [11:0]   rmw_addr,
  input logic          f_valid, f_pend, f_pol, cap_hit,
  // window engine
  input logic          w_valid, w_gnt,
  input logic [3:0]    wst,
  input logic [SEG_WORDS-1:0] pol_q,
  input logic          win_open,
  input logic [8:0]    win_base,
  input logic          ev_win_done, ev_df, rd_act,
  input logic [7:0]    rep_need,
  input logic          ver_ok,
  // repair
  input logic          sw_req, sw_go, remap_set_en,
  input arr_cmd_t      a_cmd,
  input logic [9:0]    phys_row,
  input logic [1:0]    rm_v,
  input logic [8:0]    rm_row0, rm_row1,
  // control / csr
  input logic [1:0]    mode,
  input logic          freeze,
  input logic [15:0]   test_min_bw,
  input logic [31:0]   cnt_cyc,
  input logic [3:0]    irq, irq_set,
  input logic [3:0]    irq_w1c,
  input logic          inj_arm, inj_clr,
  input logic          flog_clr,
  input logic [FLOG_DEPTH-1:0] fl_v,
  input logic          mb_busy, mb_done, mb_op_valid
);
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  localparam int K_MAX = 16;

  // ---------------------------------------------------------------- port protocol
  // CHK-6: a request is never held off for more than MAX_STALL cycles while the port is open
  sequence s_stall; fn_en && req_valid && !req_ready; endsequence
  `SG_ASSERT(a_stall_bound, not (s_stall [* (MAX_STALL + 1)]))

  // the port is closed in RESET_TEST and MAINT
  `SG_ASSERT(a_port_closed, !fn_en |-> !req_ready)

  // driver protocol: a request is held stable until it is accepted
  `SG_ASSERT(a_req_stable, (req_valid && !req_ready) |=>
             (req_valid && $stable(req_we) && $stable(req_addr) && $stable(req_wdata) && $stable(req_be)))

  // one response per accepted request, exactly LAT cycles later, none otherwise
  `SG_ASSERT(a_rsp_latency, (req_valid && req_ready) |-> ##(LAT) rsp_valid)
  `SG_ASSERT(a_rsp_has_req, rsp_valid |-> $past(req_valid && req_ready, LAT))

  `SG_ASSERT(a_ce_ue_excl, !(rsp_valid && rsp_ce && rsp_ue))

  // hazards: a write to a word whose capture is pending waits for the result (and is taken on the
  // cycle the result returns), and any access to the word of an RMW in flight must wait
  `SG_ASSERT(a_pend_wait, (fn_en && req_valid && req_we && f_pend && !cap_hit) |-> !req_ready)
  `SG_ASSERT(a_rmw_wait,  (fn_en && rmw_v && req_valid && req_addr == rmw_addr) |-> !req_ready)

  // ---------------------------------------------------------------- arbitration
  // the array has one owner per cycle
  `SG_ASSERT(a_one_owner, !(w_gnt && (f_uses_arr || rmw_wr_now || rmw_v)))

  // REQ-ECC-2: a read-modify-write whose read was uncorrectable writes nothing
  `SG_ASSERT(a_rmw_no_garbage, (rmw_wr_now && ds_ue) |-> !a_cmd.en)

  // progress guarantee (spec 6.5): with TEST_MIN_BW = K > 0 a pending window operation is
  // granted within K + 8 cycles
  sequence s_wait; fn_en && w_valid && !w_gnt && test_min_bw != 0 && test_min_bw <= K_MAX; endsequence
  `SG_ASSERT(a_min_bw_progress, not (s_wait [* (K_MAX + 9)]))

  // ---------------------------------------------------------------- online window
  `SG_ASSERT(a_win_range, win_open |-> win_base <= 9'(ROWS - SEG_ROWS))
  // windows only exist in ONLINE
  `SG_ASSERT(a_win_online, (mode != 2'(MODE_ONLINE)) |-> wst == 4'd0)
  // spec 6.3 step 4: every word is back in polarity 0 when the window is released
  `SG_ASSERT(a_pol_clear_on_release, (wst == 4'd12) |-> pol_q == '0)

  // ---------------------------------------------------------------- online repair
  `SG_ASSERT(a_sw_idle,     sw_go |-> (!rmw_v && stall_run == 2'd0))
  `SG_ASSERT(a_switch_safe, remap_set_en |-> (sw_go && rep_need == 8'h00 && ver_ok))
  // CHK-7: in ONLINE the array is reached only through the remap, except raw spare-row accesses
  `SG_ASSERT(a_online_raw_spare, (mode == 2'(MODE_ONLINE) && a_cmd.en && a_cmd.rowraw) |-> a_cmd.addr[12:3] >= 10'(ROWS))
  `SG_ASSERT(a_repaired_row_dead,
             (mode == 2'(MODE_ONLINE) && a_cmd.en && !a_cmd.rowraw) |->
             !((rm_v[0] && phys_row == {1'b0, rm_row0}) || (rm_v[1] && phys_row == {1'b0, rm_row1})))

  // ---------------------------------------------------------------- control, csr, interrupts
  // mode graph: RESET_TEST -> ONLINE -> MAINT -> ONLINE
  `SG_ASSERT(a_mode_graph, $changed(mode) |->
             ($past(mode) == 2'(MODE_RESET_TEST) && mode == 2'(MODE_ONLINE)) ||
             ($past(mode) == 2'(MODE_ONLINE)     && mode == 2'(MODE_MAINT))  ||
             ($past(mode) == 2'(MODE_MAINT)      && mode == 2'(MODE_ONLINE)))

  // an interrupt event is never lost, not even in the cycle of a W1C clear
  generate for (genvar i = 0; i < 4; i++) begin : g_irq
    `SG_ASSERT(a_irq_no_loss, irq_set[i] |=> irq[i])
    `SG_ASSERT(a_irq_sticky,  (irq[i] && !irq_w1c[i] && !$past(irq_w1c[i] && !irq_set[i])) |=> irq[i])
  end endgenerate

  `SG_ASSERT(a_cnt_freeze, (freeze && $past(freeze)) |-> $stable(cnt_cyc))

  // the fault log only forgets on an explicit clear
  generate for (genvar j = 0; j < FLOG_DEPTH; j++) begin : g_flog
    `SG_ASSERT(a_flog_keeps, (fl_v[j] && !flog_clr) |=> fl_v[j])
  end endgenerate

  // sequencer
  `SG_ASSERT(a_mb_done_after_run, mb_done |-> $past(mb_busy))
  `SG_ASSERT(a_mb_valid_busy,     mb_op_valid |-> mb_busy)

  // ---------------------------------------------------------------- corner-case cover points
  `SG_COVER(c_stall1,        fn_en && req_valid && !req_ready ##1 fn_en && req_valid && req_ready)
  `SG_COVER(c_stall2,        fn_en && req_valid && !req_ready ##1 fn_en && req_valid && !req_ready ##1 req_valid && req_ready)
  `SG_COVER(c_forced_slot,   forced_block)
  `SG_COVER(c_rmw_hazard,    haz_rmw)
  `SG_COVER(c_pend_hazard,   haz_pend)
  `SG_COVER(c_pend_bypass_write, req_valid && req_ready && req_we && f_pend && cap_hit)
  `SG_COVER(c_read_in_win_pol1, req_valid && req_ready && !req_we && f_valid && f_pol)
  `SG_COVER(c_write_in_win_pol1, req_valid && req_ready && req_we && f_valid && f_pol)
  `SG_COVER(c_write_during_repair, req_valid && req_ready && req_we && f_valid && rd_act)
  `SG_COVER(c_capture_ue_abort, wst == 4'd2 ##1 wst == 4'd12)
  `SG_COVER(c_decoder_abort, ev_df)
  `SG_COVER(c_rerun,         wst == 4'd7 ##1 wst == 4'd4)
  `SG_COVER(c_scrub_writeback, wst == 4'd3)
  `SG_COVER(c_repair_retry,  wst == 4'd10 ##1 wst == 4'd9)
  `SG_COVER(c_repair_switch, remap_set_en)
  `SG_COVER(c_irq_event_in_clear, (|irq_set) && (|(irq_set & irq_w1c)))
  `SG_COVER(c_ue_response,   rsp_valid && rsp_ue)
  `SG_COVER(c_ce_response,   rsp_valid && rsp_ce)
  `SG_COVER(c_inj_used,      inj_clr)
endmodule

bind sg_top sg_sva u_sva (
  .clk(clk), .rst_n(rst_n),
  .fn_en(fn_en), .req_valid(req_valid), .req_ready(req_ready), .req_we(req_we), .req_addr(req_addr),
  .req_wdata(req_wdata), .req_be(req_be), .rsp_valid(rsp_valid), .rsp_ce(rsp_ce), .rsp_ue(rsp_ue),
  .stall_run(stall_run),
  .f_uses_arr(u_arb.f_uses_arr), .rmw_v(u_arb.rmw_v), .rmw_wr_now(u_arb.rmw_wr_now), .ds_ue(u_arb.ds_ue),
  .haz_rmw(u_arb.haz_rmw), .haz_pend(u_arb.haz_pend), .forced_block(u_arb.forced_block),
  .rmw_addr(u_arb.rmw_addr), .f_valid(f_valid), .f_pend(f_pend), .f_pol(f_pol), .cap_hit(u_arb.cap_hit),
  .w_valid(w_valid), .w_gnt(w_gnt), .wst(u_win.st), .pol_q(u_win.u_seg.pol_q),
  .win_open(win_open), .win_base(win_base), .ev_win_done(ev_win_done), .ev_df(ev_df), .rd_act(rd_act),
  .rep_need(u_win.rep_need), .ver_ok(u_win.ver_ok),
  .sw_req(sw_req), .sw_go(sw_go), .remap_set_en(remap_set_en), .a_cmd(a_cmd), .phys_row(phys_row),
  .rm_v(rm_v), .rm_row0(rm_row0), .rm_row1(rm_row1),
  .mode(mode), .freeze(cfg.freeze), .test_min_bw(cfg.test_min_bw), .cnt_cyc(u_csr.cnt[C_CYC]),
  .irq(irq), .irq_set(irq_set),
  .irq_w1c((u_csr.wr && u_csr.paddr == 8'hC0) ? u_csr.pwdata[3:0] : 4'h0),
  .inj_arm(inj_arm), .inj_clr(inj_clr), .flog_clr(flog_clr), .fl_v(fl_v),
  .mb_busy(mb_busy), .mb_done(mb_done), .mb_op_valid(mb_op_valid)
);
