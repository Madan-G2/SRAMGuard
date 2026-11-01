// SRAMGuard UVM environment (spec 10.2): agents, golden memory, scoreboard, fault controller,
// March reference model, IRQ monitor, coverage, tests.
package sg_uvm_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import sg_pkg::*;
  import sg_ecc_ref_pkg::*;

  `include "sg_types.svh"
  `include "sg_agents.svh"
  `include "sg_env.svh"
  `include "sg_seqs.svh"
  `include "sg_tests.svh"
  `include "sg_corner_tests.svh"
endpackage
