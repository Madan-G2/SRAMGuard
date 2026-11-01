#!/usr/bin/bash
# E6 step 2: DC report_power with the SAIF files from run_e6_sim.sh.  usage: run_e6_dc.sh <saifdir>
S=$(realpath "$1"); cd "$(dirname "$0")"; H=$PWD
for cfg in "b4 b4_i50" "b1 b1_i50" "b4 b4_i0" "b1 b1_i0"; do set -- $cfg
  d=$H/out/e6_$2; mkdir -p $d/work
  csh -c "source /apps/design_environment.csh; cd $d/work; setenv BUILD $1; setenv CLKPERIOD 10.0; setenv OUTDIR $d; setenv RTLDIR $H/../../rtl; setenv BUILDDIR $H; setenv SAIF $S/$2.saif; setenv SAIFINST tb_e6/dut; dc_shell -f $H/synth_build.tcl > $d/dc.log" &
done
wait; echo ALL_DONE
