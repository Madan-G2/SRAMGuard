#!/usr/bin/bash
# E6 step 1: dump RTL SAIF (measured phase only) for B1 and B4.  usage: run_e6_sim.sh <outdir>
# Needs vcs -lca; the power -report path of ucli is the one that produces a populated SAIF.
source /apps/set_license.sh
R=$(cd "$(dirname "$0")/../.." && pwd); O=$(realpath "$1"); mkdir -p $O; cd $O
cat > sim.do <<'DO'
power -gate_level rtl_on mda sv
power tb_e6.dut
run
power -enable
run
power -disable
power -report ACT.saif 1e-9 tb_e6.dut
quit
DO
for d in B4 B1; do
  vcs -sverilog -full64 -lca -debug_access+all -timescale=1ns/1ps +define+SG_SIM +define+E6_$d +define+E6_UCLI \
      $(sed "s#\.\./rtl#$R/rtl#" $R/sim/files.f) $R/syn/builds/sg_b1.sv $R/syn/builds/tb_e4.sv $R/syn/builds/tb_e6.sv \
      -top tb_e6 -o simv_$d -l comp_$d.log >/dev/null 2>&1 || { echo compile $d failed; exit 1; }
done
for cfg in "B4 50 0 b4_i50" "B1 50 0 b1_i50" "B4 0 16 b4_i0" "B1 0 0 b1_i0"; do set -- $cfg
  sed "s/ACT/$4/" sim.do > $4.do
  ./simv_$1 +IDLE=$2 +BW=$3 -ucli -do $4.do > $4.log 2>&1
  grep -E "E6 done" $4.log; ls -la $4.saif
done
