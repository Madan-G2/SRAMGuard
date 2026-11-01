#!/usr/bin/env python3
"""Collect area / timing / power of the B0..B4 runs into results.md."""
import os, re

here = os.path.dirname(os.path.abspath(__file__))
names = {"b0": "B0 bare + valid/ready", "b1": "B1 + SECDED ECC", "b2": "B2 + power-on MBIST/BIRA/repair",
         "b3": "B3 + scrub-only online", "b4": "B4 full SRAMGuard"}


def num(pat, text):
    m = re.search(pat, text)
    return float(m.group(1)) if m else None


def read(b, p):
    d = os.path.join(here, "out", f"{b}_{p}")
    r = {}
    try:
        q = open(os.path.join(d, "qor_report.txt")).read()
        a = open(os.path.join(d, "area_report.txt")).read()
        w = open(os.path.join(d, "power_report.txt")).read()
    except FileNotFoundError:
        return None
    r["area"] = num(r"Cell Area:\s+([\d.]+)", q)
    r["comb"] = num(r"Combinational Area:\s+([\d.]+)", q)
    r["seq"] = num(r"Noncombinational Area:\s+([\d.]+)", q)
    r["cells"] = num(r"Leaf Cell Count:\s+(\d+)", q)
    r["ffs"] = num(r"Sequential Cell Count:\s+(\d+)", q)
    r["len"] = num(r"Critical Path Length:\s+([\d.-]+)", q)
    r["slack"] = num(r"Critical Path Slack:\s+([\d.-]+)", q)
    r["tns"] = num(r"Total Negative Slack:\s+([\d.-]+)", q)
    r["dyn"] = num(r"Total Dynamic Power\s+=\s+([\d.]+)", w)
    r["leak"] = num(r"Cell Leakage Power\s+=\s+([\d.]+)", w)
    m = re.search(r"Startpoint: (\S+).*?Endpoint: (\S+)", open(os.path.join(d, "timing_report.txt")).read(), re.S)
    r["path"] = f"{m.group(1)} -> {m.group(2)}" if m else "?"
    return r


out = ["# B0-B4 synthesis results (Design Compiler, FreePDK45 gscl45nm, compile_ultra)\n",
       "SRAM array is a black box in every build: numbers are the logic around it.\n",
       "## E5: area at 10 ns (same constraint as the B4 baseline)\n",
       "| Build | Cell area (um^2) | vs B0 | step | Cells | Flip-flops | Comb | Seq |", "|---|---|---|---|---|---|---|---|"]
prev = base = None
for b in names:
    r = read(b, "10.0")
    if not r or r["area"] is None:
        out.append(f"| {names[b]} | n/a |||||||"); continue
    base = base or r["area"]
    step = "" if prev is None else f"+{r['area'] - prev:,.0f}"
    out.append(f"| {names[b]} | {r['area']:,.0f} | x{r['area']/base:.2f} | {step} | {r['cells']:,.0f} | {r['ffs']:,.0f} | {r['comb']:,.0f} | {r['seq']:,.0f} |")
    prev = r["area"]
out += ["", "## E8: timing, pushed to a 2 ns clock (area here is inflated by speed-up)\n",
        "| Build | Critical path (ns) | Slack at 2 ns | Est. fmax (MHz) | Met 2 ns? | Limiting path | Area (um^2) |", "|---|---|---|---|---|---|---|"]
for b in names:
    r = read(b, "2.0")
    if not r or r["len"] is None:
        out.append(f"| {names[b]} | n/a ||||||"); continue
    tmin = 2.0 - r["slack"]
    out.append(f"| {names[b]} | {r['len']:.2f} | {r['slack']:.2f} | {1000/tmin:.0f} | {'yes' if r['slack'] >= 0 else 'no'} | `{r['path']}` | {r['area']:,.0f} |")
open(os.path.join(here, "results.md"), "w").write("\n".join(out) + "\n")
print("\n".join(out))
