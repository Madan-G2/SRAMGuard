// APB register block (spec section 9.4).  Offsets are byte addresses.
//   0x00 CTRL        [0]TEST_EN [1]SCRUB_EN [2]REPAIR_EN [3]ONLINE_REPAIR_EN [4]SEG_OVERLAP
//                    [5]BYPASS [6]MAINT_START (self-clearing) [7]FREEZE
//   0x04 ALG         [2:0] online alg  [6:4] power-on alg  [9:8] background  [11:10] diagnosis
//   0x08 STATUS      [1:0]mode [4]MBIST_FAIL [5]REPAIR_OK [6]REPAIR_FAIL [7]DEGRADED_IO
//                    [9:8]spares used [10]FLOG overflow [11]window open [24:16]window row
//   0x0C TEST_MIN_BW 0x10 SCRUB_PERIOD  0x14 CE_REPEAT_TH
//   0x18/0x1C REPAIR_SIG (read = export, write word1 = reload)
//   0x30 UC_IDX  0x34 UC_DATA (write commits)
//   0x40..0x48 ECC_INJ mask   0x4C ARM
//   0x60 FLOG_SEL 0x64 {count,online,valid,row} 0x68..0x70 IO mask  0x74 {ovf,n}
//   0x80+4k counters (see sg_pkg C_*)       0xC0 IRQ_STAT (write 1 to clear)
//   0xD0 BM_STAT {ovf,count} (write = pop)  0xD4/D8 fail vector [63:0]  0xDC {row[9:0],col[2:0],vec[73:64]}
module sg_csr
  import sg_pkg::*;
(
  input  logic          clk,
  input  logic          rst_n,
  input  logic          psel,
  input  logic          penable,
  input  logic          pwrite,
  input  logic [7:0]    paddr,
  input  logic [31:0]   pwdata,
  output logic [31:0]   prdata,
  output logic          pready,
  output logic          pslverr,

  output cfg_t          cfg,
  output logic          maint_req,
  output logic          uc_we,
  output logic [2:0]    uc_idx,
  output logic [17:0]   uc_data,
  output logic          inj_arm,
  output logic [WORD_W-1:0] inj_mask,
  input  logic          inj_clr,
  output logic          sig_load_en,
  output logic [37:0]   sig_load,
  input  logic [37:0]   sig_cur,

  input  logic [1:0]    st_mode,
  input  logic          st_mbist_fail,
  input  logic          st_repair_ok,
  input  logic          st_repair_fail,
  input  logic          st_degraded_io,
  input  logic [1:0]    st_spares,
  input  logic          st_flog_ovf,
  input  logic          st_win_open,
  input  logic [8:0]    st_win_row,

  input  logic [FLOG_DEPTH-1:0]            fl_v,
  input  logic [FLOG_DEPTH-1:0][9:0]       fl_row,
  input  logic [FLOG_DEPTH-1:0][PIO-1:0]   fl_mask,
  input  logic [FLOG_DEPTH-1:0]            fl_onl,
  input  logic [FLOG_DEPTH-1:0][15:0]      fl_cnt,

  input  logic [N_CNT-1:0] cnt_inc,
  input  logic [3:0]    irq_set,          // {done, repair, hard, ue}
  output logic [3:0]    irq,

  // bitmap-dump FIFO (spec 5.5)
  input  logic [7:0]    bm_cnt,
  input  logic          bm_ovf,
  input  logic [PIO+12:0] bm_head,
  output logic          bm_pop
);
  assign pready  = 1'b1;
  assign pslverr = 1'b0;

  logic wr, rd;
  assign wr = psel && penable && pwrite;
  assign rd = psel && !pwrite;

  logic [31:0] cnt [N_CNT];
  logic [3:0]  irq_stat;
  logic [2:0]  flog_sel;
  logic [2:0]  uc_idx_q;
  logic [31:0] sig_hi;

  assign irq = irq_stat;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cfg <= '0;
      cfg.test_en <= 1'b1; cfg.scrub_en <= 1'b1; cfg.repair_en <= 1'b1;
      cfg.online_repair_en <= 1'b1; cfg.seg_overlap <= 1'b1;
      cfg.alg_online <= 3'(ALG_MARCHC); cfg.alg_poweron <= 3'(ALG_MARCHC);
      cfg.diag <= 2'(DIAG_COLLECT); cfg.ce_th <= 4'd2;
      maint_req <= 1'b0; bm_pop <= 1'b0; uc_we <= 1'b0; uc_idx_q <= '0; uc_data <= '0;
      inj_arm <= 1'b0; inj_mask <= '0; sig_load_en <= 1'b0; sig_load <= '0;
      flog_sel <= '0; irq_stat <= '0; sig_hi <= '0;
      for (int i = 0; i < N_CNT; i++) cnt[i] <= '0;
    end else begin
      maint_req <= 1'b0; uc_we <= 1'b0; sig_load_en <= 1'b0; bm_pop <= 1'b0;
      if (inj_clr) inj_arm <= 1'b0;

      if (!cfg.freeze)
        for (int i = 0; i < N_CNT; i++) if (cnt_inc[i]) cnt[i] <= cnt[i] + 32'd1;
      irq_stat <= irq_stat | irq_set;

      if (wr) begin
        case (paddr)
          8'h00: begin
            cfg.test_en <= pwdata[0]; cfg.scrub_en <= pwdata[1]; cfg.repair_en <= pwdata[2];
            cfg.online_repair_en <= pwdata[3]; cfg.seg_overlap <= pwdata[4];
            cfg.bypass <= pwdata[5]; maint_req <= pwdata[6]; cfg.freeze <= pwdata[7];
          end
          8'h04: begin
            cfg.alg_online <= pwdata[2:0]; cfg.alg_poweron <= pwdata[6:4];
            cfg.bg <= pwdata[9:8]; cfg.diag <= pwdata[11:10];
          end
          8'h0C: cfg.test_min_bw <= pwdata[15:0];
          8'h10: cfg.scrub_period <= pwdata;
          8'h14: cfg.ce_th <= pwdata[3:0];
          8'h18: sig_hi[31:0] <= pwdata;                       // staged low word
          8'h1C: begin sig_load <= {pwdata[5:0], sig_hi}; sig_load_en <= 1'b1; end
          8'h30: uc_idx_q <= pwdata[2:0];
          8'h34: begin uc_data <= pwdata[17:0]; uc_we <= 1'b1; end
          8'h40: inj_mask[31:0]  <= pwdata;
          8'h44: inj_mask[63:32] <= pwdata;
          8'h48: inj_mask[71:64] <= pwdata[7:0];
          8'h4C: inj_arm <= pwdata[0];
          8'h60: flog_sel <= pwdata[2:0];
          8'hD0: bm_pop <= 1'b1;                                // pop the bitmap head
          8'hC0: irq_stat <= (irq_stat & ~pwdata[3:0]) | irq_set;       // an event in the clearing cycle survives
          default: ;
        endcase
      end
    end
  end
  assign uc_idx = uc_idx_q;

  always_comb begin
    prdata = '0;
    if (rd) begin
      case (paddr)
        8'h00: prdata = {24'h0, cfg.freeze, 1'b0, cfg.bypass, cfg.seg_overlap, cfg.online_repair_en,
                         cfg.repair_en, cfg.scrub_en, cfg.test_en};
        8'h04: prdata = {20'h0, cfg.diag, cfg.bg, 1'b0, cfg.alg_poweron, 1'b0, cfg.alg_online};
        8'h08: prdata = {7'h0, st_win_row, 4'h0, st_win_open, st_flog_ovf, st_spares,
                         st_degraded_io, st_repair_fail, st_repair_ok, st_mbist_fail, 1'b0, 1'b0, st_mode};
        8'h0C: prdata = {16'h0, cfg.test_min_bw};
        8'h10: prdata = cfg.scrub_period;
        8'h14: prdata = {28'h0, cfg.ce_th};
        8'h18: prdata = sig_cur[31:0];
        8'h1C: prdata = {26'h0, sig_cur[37:32]};
        8'h30: prdata = {29'h0, uc_idx_q};
        8'h40: prdata = inj_mask[31:0];
        8'h44: prdata = inj_mask[63:32];
        8'h48: prdata = {24'h0, inj_mask[71:64]};
        8'h4C: prdata = {31'h0, inj_arm};
        8'h60: prdata = {29'h0, flog_sel};
        8'h64: prdata = {fl_cnt[flog_sel], 4'h0, fl_onl[flog_sel], fl_v[flog_sel], fl_row[flog_sel]};
        8'h68: prdata = fl_mask[flog_sel][31:0];
        8'h6C: prdata = fl_mask[flog_sel][63:32];
        8'h70: prdata = {22'h0, fl_mask[flog_sel][73:64]};
        8'h74: prdata = {31'h0, st_flog_ovf};
        8'hC0: prdata = {28'h0, irq_stat};
        8'hD0: prdata = {23'h0, bm_ovf, bm_cnt};
        8'hD4: prdata = bm_head[31:0];
        8'hD8: prdata = bm_head[63:32];
        8'hDC: prdata = {9'h0, bm_head[PIO+12:64]};
        default: begin
          if (paddr >= 8'h80 && paddr < 8'(8'h80 + 4*N_CNT)) prdata = cnt[(paddr - 8'h80) >> 2];
        end
      endcase
    end
  end
endmodule
