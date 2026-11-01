// Bitmap-dump FIFO (spec 5.5): every failing {row, col, fail_vector} of a destructive March
// is queued here for offline analysis through the CSR window (simulation and debug).
// Drop-on-full with a sticky overflow flag; `clr` flushes it at the start of a test.
module sg_bmap
  import sg_pkg::*;
(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                clr,
  input  logic                push,
  input  logic [PIO+12:0]     din,        // {row[9:0], col[2:0], vec[PIO-1:0]}
  input  logic                pop,
  output logic [PIO+12:0]     dout,       // head entry (don't care when empty)
  output logic [$clog2(BM_DEPTH):0] count,
  output logic                ovf
);
  localparam logic [$clog2(BM_DEPTH):0] FULL = BM_DEPTH;
  logic [PIO+12:0] mem [BM_DEPTH];
  logic [$clog2(BM_DEPTH)-1:0] rp, wp;

  assign dout = mem[rp];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rp <= '0; wp <= '0; count <= '0; ovf <= 1'b0;
    end else if (clr) begin
      rp <= '0; wp <= '0; count <= '0; ovf <= 1'b0;
    end else begin
      if (push && count == FULL) ovf <= 1'b1;
      else if (push) begin
        mem[wp] <= din; wp <= wp + 1'b1;
      end
      if (pop && count != 0) rp <= rp + 1'b1;
      case ({push && count != FULL, pop && count != 0})
        2'b10:   count <= count + 1'b1;
        2'b01:   count <= count - 1'b1;
        default: ;
      endcase
    end
  end
endmodule
