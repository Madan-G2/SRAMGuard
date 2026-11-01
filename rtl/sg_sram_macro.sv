// Behavioral stand-in for the SRAM macro (non-SG_SIM builds).  Synchronous write,
// 1-cycle registered read -- the same timing contract as the memory-compiler view.
module sg_sram_macro
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
  logic [PIO-1:0] mem [0:PROWS-1][0:COL_MUX-1];
  always_ff @(posedge clk)
    if (en) begin
      if (we) mem[row][col] <= wdata;
      else    rdata <= mem[row][col];
    end
endmodule
