# B0-B4 synthesis results (Design Compiler, FreePDK45 gscl45nm, compile_ultra)

SRAM array is a black box in every build: numbers are the logic around it.

## E5: area at 10 ns (same constraint as the B4 baseline)

| Build | Cell area (um^2) | vs B0 | step | Cells | Flip-flops | Comb | Seq |
|---|---|---|---|---|---|---|---|
| B0 bare + valid/ready | 1,304 | x1.00 |  | 330 | 67 | 612 | 692 |
| B1 + SECDED ECC | 5,635 | x4.32 | +4,332 | 1,710 | 156 | 4,025 | 1,611 |
| B2 + power-on MBIST/BIRA/repair | 99,306 | x76.17 | +93,670 | 27,590 | 4,863 | 55,968 | 43,338 |
| B3 + scrub-only online | 157,845 | x121.07 | +58,540 | 43,464 | 7,248 | 89,883 | 67,962 |
| B4 full SRAMGuard | 160,458 | x123.08 | +2,613 | 44,254 | 7,320 | 91,753 | 68,706 |

## E8: timing, pushed to a 2 ns clock (area here is inflated by speed-up)

| Build | Critical path (ns) | Slack at 2 ns | Est. fmax (MHz) | Met 2 ns? | Limiting path | Area (um^2) |
|---|---|---|---|---|---|---|
| B0 bare + valid/ready | 1.30 | 0.63 | 730 | yes | `rd_q_reg -> rsp_rdata_reg[0]` | 1,304 |
| B1 + SECDED ECC | 1.63 | 0.29 | 585 | yes | `rmw_v_reg -> rmw_addr_reg[0]` | 5,635 |
| B2 + power-on MBIST/BIRA/repair | 6.46 | -4.53 | 153 | no | `u_ctl/u_bira/b_reg[3] -> u_ctl/u_bira/best_b_reg[2]` | 109,558 |
| B3 + scrub-only online | 6.39 | -4.47 | 155 | no | `u_ctl/u_bira/best_left_reg[1] -> u_ctl/u_bira/prog_sig_reg[30]` | 168,356 |
| B4 full SRAMGuard | 6.57 | -4.64 | 151 | no | `u_ctl/u_bira/a_reg[2] -> u_ctl/u_bira/best_left_reg[27]` | 170,992 |
