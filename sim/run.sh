#!/usr/bin/bash
# usage: sim/run.sh <tests>   e.g. sim/run.sh clean,traffic
source /apps/set_license.sh
cd "$(dirname "$0")"
vcs -sverilog -full64 -timescale=1ns/1ps +define+SG_SIM -f files.f ../tb/sg_ecc_ref_pkg.sv ../tb/tb_sg_top.sv \
    -top tb_sg_top -o simv_sys -l sys_comp.log > /dev/null 2>&1
grep -E "^Error-" -A6 sys_comp.log | head -60
[ -x simv_sys ] || { echo "COMPILE FAILED"; exit 1; }
./simv_sys +T="$1" $3 -l sys_run.log > /dev/null 2>&1
grep -v -E "^(Chronologic|Contains|Compiler version|[[:space:]]*$|[[:space:]]+V C S|Time:|CPU Time|[$]finish)" sys_run.log | head -${2:-80}
