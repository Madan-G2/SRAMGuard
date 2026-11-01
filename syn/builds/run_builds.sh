#!/bin/bash
# Usage: run_builds.sh [build ...]   (default: all)   Env: PERIODS (default "10.0 2.0")
# 10 ns = area comparison (same constraint as the B4 baseline); 2 ns = push for the fmax limit.
# Each run gets its own directory, so the runs go in parallel.
cd "$(dirname "$0")"
python3 gen_builds.py || exit 1
builds=("$@"); [ ${#builds[@]} -eq 0 ] && builds=(b0 b1 b2 b3 b4)
periods=${PERIODS:-"10.0 2.0"}
for b in "${builds[@]}"; do
  for p in $periods; do
    d=$PWD/out/${b}_${p}
    mkdir -p "$d/work"
    csh -c "source /apps/design_environment.csh; cd $d/work; setenv BUILD $b; setenv CLKPERIOD $p; setenv OUTDIR $d; setenv RTLDIR $PWD/../../rtl; setenv BUILDDIR $PWD; dc_shell -f $PWD/synth_build.tcl > $d/dc.log" &
  done
done
wait
echo ALL_DONE
