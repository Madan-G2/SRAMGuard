#!/usr/bin/bash
# E4: B4 vs B1 latency / stall comparison. usage: syn/builds/run_e4.sh  (writes syn/builds/e4_results.txt)
source /apps/set_license.sh
R=$(cd "$(dirname "$0")/../.." && pwd); W=$(mktemp -d)
cd $W && vcs -sverilog -full64 -timescale=1ns/1ps +define+SG_SIM $(sed "s#\.\./rtl#$R/rtl#" $R/sim/files.f) $R/syn/builds/sg_b1.sv $R/syn/builds/tb_e4.sv -top tb_e4 -o simv_e4 -l comp.log >/dev/null 2>&1 || exit 1
: > $R/syn/builds/e4_results.txt
for a in "0 0" "0 16" "50 0" "90 0"; do set -- $a; echo "== idle=$1% TEST_MIN_BW=$2" >> $R/syn/builds/e4_results.txt
  ./simv_e4 +IDLE=$1 +BW=$2 2>&1 | grep -E "B1 |B4 |hist|windows" >> $R/syn/builds/e4_results.txt; done
