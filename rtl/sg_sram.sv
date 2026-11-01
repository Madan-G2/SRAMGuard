// SRAM array wrapper (spec section 4).
//   514 rows (512 + 2 spare) x 8 column-mux positions x 74 IOs, 1-cycle read latency.
//   Physical column of bit b of word c is 8*b + c (bit-interleaved).
// With `SG_SIM a behavioral array carries a fault list (SAF, TF, AF, CFin, CFid, CFst,
// IRF, RDF, DRDF, WDF, soft flip).  Otherwise a plain array stands in for the macro.
module sg_sram
  import sg_pkg::*;
(
  input  logic            clk,
  input  logic            en,
  input  logic            we,
  input  logic [9:0]      row,
  input  logic [2:0]      col,
  input  logic [PIO-1:0]  wdata,
  output logic [PIO-1:0]  rdata
);

`ifdef SG_SIM
  localparam int NF = 64;

  typedef enum int {
    F_NONE = 0, F_SAF, F_TF, F_AF, F_CFIN, F_CFID, F_CFST, F_IRF, F_RDF, F_DRDF, F_WDF, F_SOFT
  } ftype_e;

  logic [PIO-1:0] mem [0:PROWS-1][0:COL_MUX-1];

  // fault list: {type, victim(row,col,bit), aggressor(row,col,bit), polarity, activate_cycle}
  int      f_type [NF];
  int      f_vr [NF], f_vc [NF], f_vb [NF];
  int      f_ar [NF], f_ac [NF], f_ab [NF];
  bit      f_pol [NF];     // SAF: n/a;  TF: 1 = cannot rise;  CFin/CFid: aggressor edge (1 = rising);  CFst: aggressor level
  bit      f_val [NF];     // SAF value, CFid/CFst forced value
  longint  f_act [NF];
  bit      f_fired [NF];   // fault effect actually altered a value (activated)
  bit      f_done [NF];    // soft error already applied
  int      nf;
  longint  cyc;
  longint  n_access_on_fault;

  initial begin
    nf = 0; cyc = 0;
    for (int r = 0; r < PROWS; r++)
      for (int c = 0; c < COL_MUX; c++)
        mem[r][c] = {$urandom, $urandom, $urandom};   // power-up garbage, not X
  end

  function automatic bit f_on(input int i);
    return (f_type[i] != F_NONE) && (cyc >= f_act[i]);
  endfunction

  // ---- test-bench API ------------------------------------------------------
  function automatic int inject(input int t, input int vr, vc, vb,
                                input int ar, ac, ab,
                                input bit pol, input bit val, input longint act);
    int i;
    i = nf;
    f_type[i] = t;  f_vr[i] = vr; f_vc[i] = vc; f_vb[i] = vb;
    f_ar[i] = ar;   f_ac[i] = ac; f_ab[i] = ab;
    f_pol[i] = pol; f_val[i] = val; f_act[i] = act;
    f_fired[i] = 0; f_done[i] = 0;
    nf = nf + 1;
    return i;
  endfunction

  function automatic void clear_faults();
    for (int i = 0; i < NF; i++) begin f_type[i] = F_NONE; f_fired[i] = 0; f_done[i] = 0; end
    nf = 0;
  endfunction

  function automatic bit fault_fired(input int i);
    return f_fired[i];
  endfunction

  function automatic logic [PIO-1:0] bd_read(input int r, input int c);
    return mem[r][c];
  endfunction

  function automatic void bd_write(input int r, input int c, input logic [PIO-1:0] d);
    mem[r][c] = d;
  endfunction

  function automatic longint now_cycle();
    return cyc;
  endfunction

  // ---- access model --------------------------------------------------------
  task automatic do_write(input int r, input int c, input logic [PIO-1:0] wd);
    logic [PIO-1:0] old, nw;
    int b;
    old = mem[r][c];
    nw  = wd;
    for (int i = 0; i < nf; i++) if (f_on(i) && f_vr[i] == r && f_vc[i] == c) begin
      b = f_vb[i];
      case (f_type[i])
        F_SAF: if (nw[b] !== f_val[i]) begin nw[b] = f_val[i]; f_fired[i] = 1; end
        F_TF:  begin
          if (!old[b] && wd[b] && f_pol[i])  begin nw[b] = 1'b0; f_fired[i] = 1; end
          if ( old[b] && !wd[b] && !f_pol[i]) begin nw[b] = 1'b1; f_fired[i] = 1; end
        end
        F_WDF: if (old[b] === wd[b]) begin nw[b] = ~old[b]; f_fired[i] = 1; end
        default: ;
      endcase
    end
    mem[r][c] = nw;
    // address-decoder fault: writing the victim word also writes the alias word
    for (int i = 0; i < nf; i++)
      if (f_on(i) && f_type[i] == F_AF && f_vr[i] == r && f_vc[i] == c) begin
        mem[f_ar[i]][f_ac[i]] = nw; f_fired[i] = 1;
      end
    // dynamic coupling: aggressor transition acts on the victim
    for (int i = 0; i < nf; i++)
      if (f_on(i) && (f_type[i] == F_CFIN || f_type[i] == F_CFID) && f_ar[i] == r && f_ac[i] == c) begin
        b = f_ab[i];
        if (old[b] !== nw[b] && nw[b] === f_pol[i]) begin
          if (f_type[i] == F_CFIN) mem[f_vr[i]][f_vc[i]][f_vb[i]] = ~mem[f_vr[i]][f_vc[i]][f_vb[i]];
          else                     mem[f_vr[i]][f_vc[i]][f_vb[i]] = f_val[i];
          f_fired[i] = 1;
        end
      end
    // state coupling: victim held while the aggressor sits at the trigger level
    for (int i = 0; i < nf; i++)
      if (f_on(i) && f_type[i] == F_CFST && mem[f_ar[i]][f_ac[i]][f_ab[i]] === f_pol[i]) begin
        if (mem[f_vr[i]][f_vc[i]][f_vb[i]] !== f_val[i]) f_fired[i] = 1;
        mem[f_vr[i]][f_vc[i]][f_vb[i]] = f_val[i];
      end
  endtask

  task automatic do_read(input int r, input int c, output logic [PIO-1:0] rd);
    int b;
    rd = mem[r][c];
    for (int i = 0; i < nf; i++) if (f_on(i) && f_vr[i] == r && f_vc[i] == c) begin
      b = f_vb[i];
      case (f_type[i])
        F_SAF:  if (rd[b] !== f_val[i]) begin rd[b] = f_val[i]; mem[r][c][b] = f_val[i]; f_fired[i] = 1; end
        F_IRF:  begin rd[b] = ~rd[b]; f_fired[i] = 1; end
        F_RDF:  begin mem[r][c][b] = ~mem[r][c][b]; rd[b] = mem[r][c][b]; f_fired[i] = 1; end
        F_DRDF: begin mem[r][c][b] = ~mem[r][c][b]; f_fired[i] = 1; end
        F_CFST: if (mem[f_ar[i]][f_ac[i]][f_ab[i]] === f_pol[i]) begin
                  if (rd[b] !== f_val[i]) f_fired[i] = 1;
                  rd[b] = f_val[i];
                end
        default: ;
      endcase
    end
  endtask

  always @(posedge clk) begin
    logic [PIO-1:0] rd;
    cyc <= cyc + 1;
    // soft errors strike at their chosen cycle
    for (int i = 0; i < nf; i++)
      if (f_type[i] == F_SOFT && !f_done[i] && cyc >= f_act[i]) begin
        mem[f_vr[i]][f_vc[i]][f_vb[i]] = ~mem[f_vr[i]][f_vc[i]][f_vb[i]];
        f_done[i] = 1; f_fired[i] = 1;
      end
    if (en) begin
      if (we) do_write(row, col, wdata);
      else begin
        do_read(row, col, rd);
        rdata <= rd;
      end
    end
  end

`else
  // Synthesis: the array is a compiled macro (514 x 592 bits, 74 IOs x 8-way column mux).
  // sg_sram_macro.sv is a behavioral stand-in; replace it with the memory-compiler / OpenRAM
  // view and keep it out of the Design Compiler read list.
  sg_sram_macro u_macro (.clk(clk), .en(en), .we(we), .row(row), .col(col), .wdata(wdata), .rdata(rdata));
`endif
endmodule
