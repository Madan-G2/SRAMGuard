// Programmable March sequencer (spec section 5).
// Walks a microcode program (ROM: MATS+, March C-, March LR, March SS; RAM: one custom
// algorithm of up to 8 elements) over an address window of `nrows` rows x 8 columns and
// presents one {row, col, rw, pol} operation at a time.  The consumer decides when an
// operation is executed by asserting op_ack, so the same sequencer drives the destructive
// power-on test (ack every cycle) and the transparent online test (ack in idle slots).
//
// 18-bit instruction: [17:16] order (00 up, 01 down, 10 either=up), [15:13] n_ops (1..6),
//                     [12:1] op0..op5 as {rw,pol} pairs, [0] last.
module sg_mbist
  import sg_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,        // 1-cycle pulse, loads alg/nrows
  input  logic [2:0]  alg,
  input  logic [10:0] nrows,
  input  logic        stop,         // abort (go/no-go)
  output logic        busy,
  output logic        done,         // 1-cycle pulse after the last op is acknowledged
  output logic        op_valid,
  output logic [9:0]  op_row,       // row offset inside the window
  output logic [2:0]  op_col,
  output logic        op_rw,        // 1 = write
  output logic        op_pol,       // 0 = D, 1 = ~D
  input  logic        op_ack,
  // custom algorithm RAM
  input  logic        uc_we,
  input  logic [2:0]  uc_idx,
  input  logic [17:0] uc_data
);

  function automatic logic [17:0] mk(input logic [1:0] ord, input int n,
                                     input logic [5:0] rw, input logic [5:0] pl,
                                     input logic last);
    logic [11:0] ops;
    for (int k = 0; k < 6; k++) ops[2*k +: 2] = {rw[k], pl[k]};
    return {ord, 3'(n), ops, last};
  endfunction

  // bit k of rw/pl describes op k: rw=1 write, pl=1 complement
  function automatic logic [17:0] rom(input logic [4:0] i);
    case (i)
      // MATS+  = c(w0); u(r0,w1); d(r1,w0)
      5'd0:  return mk(2'b10, 1, 6'b000001, 6'b000000, 1'b0);
      5'd1:  return mk(2'b00, 2, 6'b000010, 6'b000010, 1'b0);
      5'd2:  return mk(2'b01, 2, 6'b000010, 6'b000001, 1'b1);
      // March C- = c(w0); u(r0,w1); u(r1,w0); d(r0,w1); d(r1,w0); c(r0)
      5'd3:  return mk(2'b10, 1, 6'b000001, 6'b000000, 1'b0);
      5'd4:  return mk(2'b00, 2, 6'b000010, 6'b000010, 1'b0);
      5'd5:  return mk(2'b00, 2, 6'b000010, 6'b000001, 1'b0);
      5'd6:  return mk(2'b01, 2, 6'b000010, 6'b000010, 1'b0);
      5'd7:  return mk(2'b01, 2, 6'b000010, 6'b000001, 1'b0);
      5'd8:  return mk(2'b10, 1, 6'b000000, 6'b000000, 1'b1);
      // March LR = c(w0); d(r0,w1); u(r1,w0,r0,w1); u(r1,w0); u(r0,w1,r1,w0); u(r0)
      5'd9:  return mk(2'b10, 1, 6'b000001, 6'b000000, 1'b0);
      5'd10: return mk(2'b01, 2, 6'b000010, 6'b000010, 1'b0);
      5'd11: return mk(2'b00, 4, 6'b001010, 6'b001001, 1'b0);
      5'd12: return mk(2'b00, 2, 6'b000010, 6'b000001, 1'b0);
      5'd13: return mk(2'b00, 4, 6'b001010, 6'b000110, 1'b0);
      5'd14: return mk(2'b00, 1, 6'b000000, 6'b000000, 1'b1);
      // March SS = c(w0); u(r0,r0,w0,r0,w1); u(r1,r1,w1,r1,w0); d(...); d(...); c(r0)
      5'd15: return mk(2'b10, 1, 6'b000001, 6'b000000, 1'b0);
      5'd16: return mk(2'b00, 5, 6'b010100, 6'b010000, 1'b0);
      5'd17: return mk(2'b00, 5, 6'b010100, 6'b001111, 1'b0);
      5'd18: return mk(2'b01, 5, 6'b010100, 6'b010000, 1'b0);
      5'd19: return mk(2'b01, 5, 6'b010100, 6'b001111, 1'b0);
      5'd20: return mk(2'b10, 1, 6'b000000, 6'b000000, 1'b1);
      default: return mk(2'b10, 1, 6'b000000, 6'b000000, 1'b1);
    endcase
  endfunction

  function automatic logic [5:0] alg_start(input logic [2:0] a);
    case (a)
      ALG_MATS:    return 6'd0;
      ALG_MARCHC:  return 6'd3;
      ALG_MARCHLR: return 6'd9;
      ALG_MARCHSS: return 6'd15;
      default:     return 6'd32;   // custom RAM
    endcase
  endfunction

  logic [17:0] uram [8];
  always_ff @(posedge clk) if (uc_we) uram[uc_idx] <= uc_data;

  logic [5:0]  ep;
  logic [12:0] ai, n_addr;
  logic [2:0]  oi;
  logic        run;

  logic [17:0] ins;
  logic [1:0]  ord;
  logic [2:0]  n_ops;
  logic        last_el;
  logic [12:0] aidx;
  logic [1:0]  cur_op;

  assign ins     = ep[5] ? uram[ep[2:0]] : rom(ep[4:0]);
  assign ord     = ins[17:16];
  assign n_ops   = (ins[15:13] == 3'd0) ? 3'd1 : ins[15:13];
  assign last_el = ins[0] | (ep == 6'd39);        // custom RAM: element 7 always ends
  assign aidx    = (ord == 2'b01) ? (n_addr - 13'd1 - ai) : ai;
  assign cur_op  = ins[1 + 2*oi +: 2];

  assign busy     = run;
  assign op_valid = run;
  assign op_row   = aidx[12:3];
  assign op_col   = aidx[2:0];
  assign op_rw    = cur_op[1];
  assign op_pol   = cur_op[0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      run <= 1'b0; done <= 1'b0; ep <= '0; ai <= '0; oi <= '0; n_addr <= '0;
    end else begin
      done <= 1'b0;
      if (start) begin
        run <= 1'b1; ep <= alg_start(alg); ai <= '0; oi <= '0;
        n_addr <= 13'({nrows, 3'b000});
      end else if (run && stop) begin
        run <= 1'b0; done <= 1'b1;
      end else if (run && op_ack) begin
        if (oi == n_ops - 3'd1) begin
          oi <= '0;
          if (ai == n_addr - 13'd1) begin
            ai <= '0;
            if (last_el) begin run <= 1'b0; done <= 1'b1; end
            else ep <= ep + 6'd1;
          end else ai <= ai + 13'd1;
        end else oi <= oi + 3'd1;
      end
    end
  end
endmodule
