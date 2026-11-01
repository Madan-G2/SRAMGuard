#!/usr/bin/bash
# usage: uvm/run_uvm.sh [-cov] <test> [plusargs...]      e.g. uvm/run_uvm.sh sg_hard_test
#        uvm/run_uvm.sh all                              every test, one log per test in uvm/logs
source /apps/set_license.sh
cd "$(dirname "$0")"
mkdir -p logs
CM=""; EX=""
if [ "$1" = "-cov" ]; then shift; CM="-cm line+cond+fsm+tgl+assert -cm_dir cov.vdb"; fi
vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps +define+SG_SIM +incdir+. -assert enable_diag \
    $CM -f ../sim/files.f ../tb/sg_ecc_ref_pkg.sv sg_if.sv sg_uvm_pkg.sv sg_sva.sv tb_uvm_top.sv \
    -top tb_uvm_top -o simv_uvm -l logs/compile.log > /dev/null 2>&1
grep -E "^(Error|Warning-\[(TFIPC|ICPD)\])" -A6 logs/compile.log | head -80
[ -x simv_uvm ] || { echo "COMPILE FAILED (see uvm/logs/compile.log)"; exit 1; }
T="${1:-sg_clean_test}"; shift
TESTS="$T"
[ "$T" = all ] && TESTS="sg_clean_test sg_traffic_test sg_csr_test sg_soft_test sg_eccinj_test sg_hard_test sg_hammer_test sg_minbw_test sg_repair_test sg_fuse_test sg_poweron_cov_test sg_online_cov_test sg_af_hazard_test sg_af_inwindow_test sg_capture_abort_test sg_scrub_only_test sg_bad_spare_test sg_irq_race_test sg_diag_test sg_reset_midflight_test sg_csr_regs_test sg_sched_mbist_test"
for t in $TESTS; do
  CMOPT=""; [ -n "$CM" ] && CMOPT="-cm line+cond+fsm+tgl+assert -cm_dir cov.vdb -cm_name $t"
  ./simv_uvm +UVM_TESTNAME=$t "$@" +UVM_VERBOSITY=UVM_LOW $CMOPT -l logs/$t.log > /dev/null 2>&1
  printf "%-22s %s\n" "$t" "$(grep -E 'TEST (PASS|FAIL)' logs/$t.log | tail -1 | sed 's/.*RESULT\] //')"
done
