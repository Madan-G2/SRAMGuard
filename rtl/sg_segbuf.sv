// Segment buffer (spec section 6.2): ECC-corrected reference of the words under online test.
//   state : NONE  - word not part of the window, functional access goes to the array
//           PEND  - capture read issued, reference not loaded yet (functional writes wait)
//           VALID - ref holds the data; array content == ref ^ {72{pol}} (REQ-OT-1)
module sg_segbuf
  import sg_pkg::*;
(
  input  logic          clk,
  input  logic          rst_n,
  input  logic          open,
  input  logic [8:0]    open_base,
  input  logic          close,
  output logic          win_open,
  output logic [8:0]    base,

  // functional-side lookup (combinational)
  input  logic [11:0]   f_addr,
  output logic          f_valid,
  output logic          f_pend,
  output logic [3:0]    f_idx,
  output logic [WORD_W-1:0] f_ref,
  output logic          f_pol,

  // updates
  input  logic          cap_issue_en,
  input  logic [3:0]    cap_issue_idx,
  input  logic          cap_load_en,
  input  logic [3:0]    cap_load_idx,
  input  logic [WORD_W-1:0] cap_load_cw,
  input  logic          cap_load_ue,
  input  logic          fwr_en,
  input  logic [3:0]    fwr_idx,
  input  logic [WORD_W-1:0] fwr_cw,
  input  logic          pol_set_en,
  input  logic [3:0]    pol_set_idx,
  input  logic          pol_set_val,

  // engine-side read port
  input  logic [3:0]    t_idx,
  output logic [WORD_W-1:0] t_ref,
  output logic [SEG_WORDS-1:0] all_pol,
  output logic [SEG_WORDS-1:0] all_valid
);
  typedef enum logic [1:0] {S_NONE = 2'd0, S_PEND = 2'd1, S_VALID = 2'd2} sstate_e;

  sstate_e           st  [SEG_WORDS];
  logic [WORD_W-1:0] ref_q [SEG_WORDS];
  logic [SEG_WORDS-1:0] pol_q;

  logic       in_win;
  logic [8:0] roff;
  assign roff   = f_addr[11:3] - base;
  assign in_win = win_open && (f_addr[11:3] == base || f_addr[11:3] == base + 9'd1);
  assign f_idx  = {roff[0], f_addr[2:0]};
  assign f_valid = in_win && (st[f_idx] == S_VALID);
  assign f_pend  = in_win && (st[f_idx] == S_PEND);
  assign f_ref   = ref_q[f_idx];
  assign f_pol   = pol_q[f_idx];
  assign t_ref   = ref_q[t_idx];
  assign all_pol = pol_q;

  always_comb for (int i = 0; i < SEG_WORDS; i++) all_valid[i] = (st[i] == S_VALID);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      win_open <= 1'b0; base <= '0; pol_q <= '0;
      for (int i = 0; i < SEG_WORDS; i++) begin st[i] <= S_NONE; ref_q[i] <= '0; end
    end else begin
      if (open) begin
        win_open <= 1'b1; base <= open_base; pol_q <= '0;
        for (int i = 0; i < SEG_WORDS; i++) st[i] <= S_NONE;
      end else if (close) begin
        win_open <= 1'b0; pol_q <= '0;
        for (int i = 0; i < SEG_WORDS; i++) st[i] <= S_NONE;
      end else begin
        if (cap_issue_en) st[cap_issue_idx] <= S_PEND;
        if (cap_load_en) begin
          if (cap_load_ue) st[cap_load_idx] <= S_NONE;        // no trusted reference
          else begin
            st[cap_load_idx] <= S_VALID; ref_q[cap_load_idx] <= cap_load_cw; pol_q[cap_load_idx] <= 1'b0;
          end
        end
        if (fwr_en) ref_q[fwr_idx] <= fwr_cw;
        if (pol_set_en) pol_q[pol_set_idx] <= pol_set_val;
      end
    end
  end
endmodule
