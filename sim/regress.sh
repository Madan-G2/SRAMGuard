#!/usr/bin/bash
# Full regression: unit tests, then every system test (the coverage matrix is the long one).
#   sim/regress.sh          quick set (about a minute)
#   sim/regress.sh full     adds the 19x4 power-on coverage matrix and the no-false-alarm sweep
source /apps/set_license.sh
cd "$(dirname "$0")"
vcs -sverilog -full64 -timescale=1ns/1ps +define+SG_SIM -f files.f ../tb/sg_ecc_ref_pkg.sv ../tb/tb_unit.sv \
    -top tb_unit -o simv_unit -l unit.log > /dev/null 2>&1 && ./simv_unit | grep -E "ECC|REMAP|BIRA|TB_UNIT"
T=clean,traffic,traffic90,repair,fuse,hard,soft,eccinj,scrub,minbw,custom,hammer
[ "$1" = full ] && T=$T,nofalse,cov,sweeplat
./run.sh $T 200
