#!/usr/bin/python3
"""Render gtkwave screenshots of uvm/wave/sg_hard.vcd (headless, Xvfb).
usage: python3 make_shots.py      -> wave_*.png next to this script
The VCD comes from: uvm/run_uvm.sh sg_hard_test +DUMP_VCD=wave/sg_hard.vcd +DUMP_END_NS=1900000
"""
import os, subprocess as sp

HERE = os.path.dirname(os.path.abspath(__file__))
VCD = os.path.join(HERE, "sg_hard.vcd")
D = "tb_uvm_top.dut."

# translate filters (gtkwave shows hex values; map them to state names)
FILTERS = {
    "f_mode.txt": ["RESET_TEST", "ONLINE", "MAINT", "BYPASS"],
    "f_ctl.txt":  ["C_BOOT", "C_CLR", "C_START", "C_TEST", "C_DRAIN", "C_BIRA", "C_BIRAW", "C_ZERO", "C_ONLINE", "C_WAITQ"],
    "f_win.txt":  ["W_IDLE", "W_CAP", "W_CAPWAIT", "W_SCRUBWB", "W_MSTART", "W_MARCH", "W_DRAIN", "W_CLASS", "W_LOG",
                   "W_REP_COPY", "W_REP_VER", "W_REP_SW", "W_REL", "W_RS_WR", "W_RS_RD"],
}
for fn, names in FILTERS.items():
    with open(os.path.join(HERE, fn), "w") as f:
        for i, n in enumerate(names):
            f.write(f"{i:x} {n}\n")
            if len(names) <= 4: f.write(f"{i:02x} {n}\n")

# (signal, filter-or-None)
SIGS = [
    ("tb_uvm_top.clk", None), (D + "rst_n", None),
    (D + "mode[1:0]", "f_mode.txt"), (D + "u_ctl.st[3:0]", "f_ctl.txt"), (D + "u_win.st[3:0]", "f_win.txt"),
    (D + "win_open", None), (D + "win_base[8:0]", None),
    (D + "mb_op_valid", None), (D + "mb_op_rw", None), (D + "mb_op_row[9:0]", None),
    (D + "req_valid", None), (D + "req_ready", None), (D + "req_we", None), (D + "req_addr[11:0]", None),
    (D + "rsp_valid", None), (D + "rsp_rdata[63:0]", None), (D + "rsp_ce", None), (D + "rsp_ue", None),
    (D + "cap_v", None), (D + "cap_ce", None), (D + "stall_run[1:0]", None),
    (D + "rm_v[1:0]", None), (D + "rm_row0[8:0]", None),
    (D + "psel", None), (D + "pwrite", None), (D + "paddr[7:0]", None),
    (D + "irq_done", None), (D + "irq_hard", None), (D + "irq_repair", None), (D + "irq_ue", None),
]

# name, start ps, end ps, marker ps
VIEWS = [
    ("wave_1_overview",       0,             1_900_000_000, 452_775_000),
    ("wave_2_poweron_done",   452_600_000,   453_400_000,   452_775_000),
    ("wave_3_online_traffic", 1_200_000_000, 1_200_800_000, None),
    ("wave_4_hard_repair",    1_866_550_000, 1_867_100_000, 1_866_685_000),
]

def tcl_for(png, t0, t1, mark):
    lines = []
    for s, flt in SIGS:
        lines.append(f'gtkwave::addSignalsFromList [list {{{s}}}]')
        if flt:
            lines.append(f'gtkwave::highlightSignalsFromList [list {{{s}}}]')
            lines.append(f'set fi [gtkwave::setCurrentTranslateFile {os.path.join(HERE, flt)}]')
            lines.append('gtkwave::installFileFilter $fi')
            lines.append(f'gtkwave::unhighlightSignalsFromList [list {{{s}}}]')
    lines.append(f"gtkwave::setZoomRangeTimes {t0} {t1}")
    if mark is not None:
        lines.append(f"gtkwave::setMarker {mark}")
    lines += ["update", f"exec import -window root {png}", "gtkwave::/File/Quit"]
    return "\n".join(lines) + "\n"

for name, t0, t1, mark in VIEWS:
    png = os.path.join(HERE, name + ".png")
    tcl = os.path.join(HERE, name + ".tcl")
    with open(tcl, "w") as f:
        f.write(tcl_for(png, t0, t1, mark))
    if os.path.exists(png): os.remove(png)
    r = sp.run(["timeout", "120", "xvfb-run", "-a", "-s", "-screen 0 1800x1000x24",
                "gtkwave", "--rcvar", "splash_disable on", "--rcvar", "do_initial_zoom_fit off",
                "--rcvar", "hide_sst on", "--rcvar", "initial_window_x 1780", "--rcvar", "initial_window_y 900",
                "--rcvar", "initial_signal_window_width 260",
                "-S", tcl, VCD], stdout=sp.PIPE, stderr=sp.STDOUT, encoding="utf-8", errors="replace")
    ok = os.path.exists(png)
    if ok: sp.run(["convert", png, "-trim", "+repage", png])     # drop the empty Xvfb background
    print(name, "ok" if ok else "FAILED")
    if not ok: print(r.stdout[-2000:])
