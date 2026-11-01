# Elaboration-only synthesizability check (no technology library needed).
# The SRAM array is a black box (sg_sram_macro is not read).
set rtl ../rtl
analyze -format sverilog [list $rtl/sg_pkg.sv $rtl/sg_ecc_pkg.sv $rtl/sg_ecc.sv $rtl/sg_sram.sv \
    $rtl/sg_remap.sv $rtl/sg_mbist.sv $rtl/sg_flog.sv $rtl/sg_bmap.sv $rtl/sg_bira.sv $rtl/sg_segbuf.sv \
    $rtl/sg_scrub.sv $rtl/sg_win.sv $rtl/sg_arb.sv $rtl/sg_ctl.sv $rtl/sg_csr.sv $rtl/sg_top.sv]
elaborate sg_top
current_design sg_top
link
check_design
report_hierarchy
exit
