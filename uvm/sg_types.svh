// ---------------------------------------------------------------------------------------------
// Data classes: fault items, fault list, transactions, March reference model, BIRA model.
// ---------------------------------------------------------------------------------------------

// fault types of the SRAM model (same numbering as sg_sram ftype_e)
typedef enum int {
  FT_NONE = 0, FT_SAF, FT_TF, FT_AF, FT_CFIN, FT_CFID, FT_CFST, FT_IRF, FT_RDF, FT_DRDF, FT_WDF, FT_SOFT
} sg_ftype_e;

// 19 sub-models used by the power-on campaign (spec 4.2 with polarity variants)
localparam int SG_NSUB = 19;
function automatic string sg_sub_name(int k);
  string n [SG_NSUB] = '{"SAF0","SAF1","TFup","TFdn","AF","CFin-up","CFin-dn","CFid-u0","CFid-u1","CFid-d0",
                         "CFid-d1","CFst-00","CFst-01","CFst-10","CFst-11","IRF","RDF","DRDF","WDF"};
  return n[k];
endfunction
function automatic string sg_alg_name(int a);
  string n [4] = '{"MATS+","March C-","March LR","March SS"};
  return n[a];
endfunction

class sg_fault_item extends uvm_object;
  `uvm_object_utils(sg_fault_item)
  sg_ftype_e ftype;
  int        vr, vc, vb;        // victim row (physical), column (word select), bit (physical IO)
  int        ar, ac, ab;        // aggressor / alias
  bit        pol, val;
  longint    act_rel;           // activate this many cycles after injection
  int        handle = -1;       // index in the SRAM model fault list
  int        sub = -1;          // power-on sub-model index, if built from one

  function new(string name = "sg_fault_item"); super.new(name); endfunction

  function bit two_cell();
    return ftype inside {FT_AF, FT_CFIN, FT_CFID, FT_CFST};
  endfunction

  // build one of the 19 sub-models
  static function sg_fault_item from_sub(int k, int vr, vc, vb, ar, ac, ab);
    sg_fault_item f = new();
    f.vr = vr; f.vc = vc; f.vb = vb; f.ar = ar; f.ac = ac; f.ab = ab; f.sub = k;
    case (k)
      0:  begin f.ftype = FT_SAF;  f.val = 0; end
      1:  begin f.ftype = FT_SAF;  f.val = 1; end
      2:  begin f.ftype = FT_TF;   f.pol = 1; end
      3:  begin f.ftype = FT_TF;   f.pol = 0; end
      4:  begin f.ftype = FT_AF; end
      5:  begin f.ftype = FT_CFIN; f.pol = 1; end
      6:  begin f.ftype = FT_CFIN; f.pol = 0; end
      7:  begin f.ftype = FT_CFID; f.pol = 1; f.val = 0; end
      8:  begin f.ftype = FT_CFID; f.pol = 1; f.val = 1; end
      9:  begin f.ftype = FT_CFID; f.pol = 0; f.val = 0; end
      10: begin f.ftype = FT_CFID; f.pol = 0; f.val = 1; end
      11: begin f.ftype = FT_CFST; f.pol = 0; f.val = 0; end
      12: begin f.ftype = FT_CFST; f.pol = 0; f.val = 1; end
      13: begin f.ftype = FT_CFST; f.pol = 1; f.val = 0; end
      14: begin f.ftype = FT_CFST; f.pol = 1; f.val = 1; end
      15: f.ftype = FT_IRF;
      16: f.ftype = FT_RDF;
      17: f.ftype = FT_DRDF;
      default: f.ftype = FT_WDF;
    endcase
    return f;
  endfunction

  function string convert2string();
    return $sformatf("%s v(r%0d c%0d b%0d) a(r%0d c%0d b%0d) pol=%0b val=%0b act+%0d",
                     ftype.name(), vr, vc, vb, ar, ac, ab, pol, val, act_rel);
  endfunction
endclass

// fault list handed to the fault controller through uvm_config_db (spec 4.3)
class sg_fault_list extends uvm_object;
  `uvm_object_utils(sg_fault_list)
  sg_fault_item items[$];
  function new(string name = "sg_fault_list"); super.new(name); endfunction
endclass

// ---- functional transactions
class sg_func_item extends uvm_sequence_item;
  rand bit          we;
  rand bit [11:0]   addr;
  rand bit [63:0]   data;
  rand bit [7:0]    be;
  int               gap;       // idle cycles before the request
  `uvm_object_utils(sg_func_item)
  function new(string name = "sg_func_item"); super.new(name); endfunction
  function bit partial(); return we && be != 8'hFF; endfunction
  function string convert2string();
    return $sformatf("%s a=%03h d=%016h be=%02h gap=%0d", we ? "WR" : "RD", addr, data, be, gap);
  endfunction
endclass

// window state seen by an accepted request (functional coverage, spec 10.5)
typedef enum int { WS_OUT = 0, WS_POL0, WS_POL1, WS_REPAIR, WS_PEND } sg_wstate_e;

class sg_func_txn extends uvm_object;
  `uvm_object_utils(sg_func_txn)
  bit          we;
  bit [11:0]   addr;
  bit [63:0]   data;
  bit [7:0]    be;
  int          stall;
  sg_wstate_e  wstate;
  // response
  bit [63:0]   rdata;
  bit          ce, ue;
  function new(string name = "sg_func_txn"); super.new(name); endfunction
  function bit partial(); return we && be != 8'hFF; endfunction
endclass

// ---- APB
class sg_apb_item extends uvm_sequence_item;
  rand bit        write;
  rand bit [7:0]  addr;
  rand bit [31:0] data;
  bit      [31:0] rdata;
  `uvm_object_utils(sg_apb_item)
  function new(string name = "sg_apb_item"); super.new(name); endfunction
endclass

// ---------------------------------------------------------------------------------------------
// sg_march_model: reference model that predicts, for a fault and an algorithm, whether a March
// test must detect it (spec 10.2).  The algorithms are written from the spec table 5.1, not read
// from the RTL microcode ROM.  Only the cells that take part in the fault matter (victim and
// aggressor/alias), so the model executes the algorithm on those one or two cells in address
// order; the fault semantics mirror the SRAM model of spec 4.2.
// ---------------------------------------------------------------------------------------------
class sg_march_model extends uvm_object;
  `uvm_object_utils(sg_march_model)

  typedef struct { bit down; int n; bit rw[6]; bit pol[6]; } el_t;
  el_t els[$];

  function new(string name = "sg_march_model"); super.new(name); endfunction

  local function void e(bit down, string ops);
    el_t x;
    x.down = down; x.n = 0;
    for (int i = 0; i < ops.len(); i += 2) begin
      x.rw[x.n]  = (ops[i] == "w");
      x.pol[x.n] = (ops[i+1] == "1");
      x.n++;
    end
    els.push_back(x);
  endfunction

  function void load(int alg);
    els.delete();
    case (alg)
      0: begin e(0, "w0"); e(0, "r0w1"); e(1, "r1w0"); end
      1: begin e(0, "w0"); e(0, "r0w1"); e(0, "r1w0"); e(1, "r0w1"); e(1, "r1w0"); e(0, "r0"); end
      2: begin e(0, "w0"); e(1, "r0w1"); e(0, "r1w0r0w1"); e(0, "r1w0"); e(0, "r0w1r1w0"); e(0, "r0"); end
      default: begin
        e(0, "w0"); e(0, "r0r0w0r0w1"); e(0, "r1r1w1r1w0"); e(1, "r0r0w0r0w1"); e(1, "r1r1w1r1w0"); e(0, "r0");
      end
    endcase
  endfunction

  // --- two-cell state: index 0 = victim, 1 = aggressor / alias
  local sg_fault_item f;
  local bit m [2];
  local bit has1;       // second cell influences the victim (state coupling: even when not operated on)
  local bit iter1;      // second cell is operated on by the algorithm (it is inside the window)

  local function void do_write(int i, bit nw);
    bit old, n2;
    old = m[i]; n2 = nw;
    if (i == 0) begin
      case (f.ftype)
        FT_SAF: if (n2 !== f.val) n2 = f.val;
        FT_TF:  begin
          if (!old && nw && f.pol)   n2 = 1'b0;
          if ( old && !nw && !f.pol) n2 = 1'b1;
        end
        FT_WDF: if (old === nw) n2 = ~old;
        default: ;
      endcase
    end
    m[i] = n2;
    if (i == 0 && f.ftype == FT_AF && has1) m[1] = n2;                     // decoder fault: alias written too
    if (i == 1 && has1 && (f.ftype == FT_CFIN || f.ftype == FT_CFID))
      if (old !== m[1] && m[1] === f.pol) begin
        if (f.ftype == FT_CFIN) m[0] = ~m[0]; else m[0] = f.val;
      end
    if (has1 && f.ftype == FT_CFST && m[1] === f.pol) m[0] = f.val;      // state coupling holds the victim
  endfunction

  local function bit do_read(int i);
    bit rd;
    rd = m[i];
    if (i == 0) begin
      case (f.ftype)
        FT_SAF:  if (rd !== f.val) begin rd = f.val; m[0] = f.val; end
        FT_IRF:  rd = ~rd;
        FT_RDF:  begin m[0] = ~m[0]; rd = m[0]; end
        FT_DRDF: m[0] = ~m[0];
        FT_CFST: if (has1 && m[1] === f.pol) rd = f.val;
        default: ;
      endcase
    end
    return rd;
  endfunction

  // One pass of the algorithm over the cells that are present, from the current state m[].
  // d0/d1: data value D of victim / second cell.  Returns 1 if some read mismatches.
  local function bit run_pass(int alg, bit d0, bit d1);
    int order [2];
    int na;
    int a0, a1;
    bit det = 0;
    load(alg);
    a0 = f.vr * 8 + f.vc; a1 = f.ar * 8 + f.ac;
    na = iter1 ? 2 : 1;
    order[0] = 0; order[1] = 1;
    if (iter1 && a1 < a0) begin order[0] = 1; order[1] = 0; end
    foreach (els[x]) begin
      for (int k = 0; k < na; k++) begin
        int ci;
        ci = els[x].down ? order[na - 1 - k] : order[k];
        for (int o = 0; o < els[x].n; o++) begin
          bit d, v;
          d = (ci == 0) ? d0 : d1;
          v = d ^ els[x].pol[o];
          if (els[x].rw[o]) do_write(ci, v);
          else if (do_read(ci) !== v) det = 1;
        end
      end
    end
    return det;
  endfunction

  // Power-on prediction.  Returns 2 = detected for every initial array content, 0 = never,
  // 1 = depends on the (random) power-up content.
  function int predict_poweron(sg_fault_item fi, int alg, int bg);
    int hits = 0, tot = 0;
    bit d0, d1;
    f = fi;
    has1 = f.two_cell(); iter1 = has1;
    d0 = bg_d(bg, fi.vr, fi.vc);
    d1 = bg_d(bg, fi.ar, fi.ac);
    for (int i0 = 0; i0 < 2; i0++)
      for (int i1 = 0; i1 < 2; i1++) begin
        m[0] = i0[0]; m[1] = i1[0];
        tot++; hits += run_pass(alg, d0, d1);
      end
    return (hits == tot) ? 2 : (hits == 0 ? 0 : 1);
  endfunction

  // Online (transparent) prediction on live data; c_v / c_a are the stored bits of the victim and
  // the second cell, D = c because the reference is the ECC-corrected original.  The engine
  //   - sees every row in two overlapping windows per sweep: (v-1, v) then (v, v+1),
  //   - reads each window first (capture: the read itself may disturb the cell),
  //   - runs the algorithm; on a mismatch it runs the window once more and only a repeat is a
  //     hard fault (spec 6.3 step 3),
  //   - leaves the cell as the algorithm left it (a faulty cell may end wrong; ECC repairs it at
  //     the next capture, but the next window starts from the wrong state).
  // The second cell only takes part in a window that contains its row.
  function bit predict_online_seq(sg_fault_item fi, int alg, bit c_v, bit c_a, int first, int nwin);
    bit hard = 0;
    f = fi;
    m[0] = c_v; m[1] = c_a;
    for (int i = 0; i < nwin && !hard; i++) begin
      int w = (first + i) % 2;
      int lo = fi.vr - 1 + w;                       // window rows lo, lo+1
      bit second_in = f.two_cell() && (fi.ar == lo || fi.ar == lo + 1);
      // a state-coupling aggressor outside the window still holds its level (c_a) and forces the victim
      iter1 = second_in;
      has1  = second_in || (f.ftype == FT_CFST);
      // capture reads in address order
      if (iter1 && fi.ar * 8 + fi.ac < fi.vr * 8 + fi.vc) begin void'(do_read(1)); void'(do_read(0)); end
      else begin void'(do_read(0)); if (iter1) void'(do_read(1)); end
      if (run_pass(alg, c_v, c_a)) begin
        if (run_pass(alg, c_v, c_a)) hard = 1;
      end
    end
    return hard;
  endfunction

  // The fault may activate at any point of the sweep, so the first window that sees the victim is
  // (v-1,v) or (v,v+1), and the check polls until the end of the next sweep (3 or 4 windows).
  // all = detected whatever the phase; any = detected for some phase.
  function void predict_online(sg_fault_item fi, int alg, bit c_v, bit c_a, output bit all, output bit any);
    bit a3_0, a3_1, a4_0, a4_1;
    a3_0 = predict_online_seq(fi, alg, c_v, c_a, 0, 3);
    a3_1 = predict_online_seq(fi, alg, c_v, c_a, 1, 3);
    a4_0 = predict_online_seq(fi, alg, c_v, c_a, 0, 4);
    a4_1 = predict_online_seq(fi, alg, c_v, c_a, 1, 4);
    all = a3_0 && a3_1;
    any = a4_0 || a4_1;
  endfunction

  static function bit in_same_window(sg_fault_item fi);
    int dr = fi.vr - fi.ar;
    return (dr >= -1 && dr <= 1);          // overlapping windows pair every two adjacent rows
  endfunction

  // spec 5.3 data background for the (row, word select) of a cell
  static function bit bg_d(int bg, int r, int c);
    case (bg)
      1: return (r[0] ^ c[0]);
      2: return r[0];
      3: return c[0];
      default: return 1'b0;
    endcase
  endfunction

  // literature claim from the spec table 4.2 (hypothesis the regression tests)
  static function bit spec_covers(int ftype_class, int alg);
    case (ftype_class)
      0, 2: return 1;                              // SAF, AF: all four
      1, 3, 4, 5: return alg != 0;                 // TF, CFin, CFid, CFst
      6:    return alg == 1 || alg == 3;           // IRF
      default: return alg == 3;                    // RDF, DRDF, WDF
    endcase
  endfunction
  static function int sub_class(int k);
    if (k <= 1) return 0;
    if (k <= 3) return 1;
    if (k == 4) return 2;
    if (k <= 6) return 3;
    if (k <= 10) return 4;
    if (k <= 14) return 5;
    return 6 + (k - 15);
  endfunction
endclass

// ---------------------------------------------------------------------------------------------
// BIRA reference: brute-force repairability of a set of failing (row, io) cells with 2 spare rows
// and 2 spare IOs.  Independent of the RTL search.
// ---------------------------------------------------------------------------------------------
class sg_bira_model extends uvm_object;
  `uvm_object_utils(sg_bira_model)
  function new(string name = "sg_bira_model"); super.new(name); endfunction

  // rows[i], ios[i] = one failing cell.  Returns 1 if the cells can be covered.
  // kind: 0 none, 1 rows only, 2 ios only, 3 mixed
  function bit repairable(int rows[$], int ios[$], output int kind);
    int urow[$];
    int best_cost = 99;
    foreach (rows[i]) begin
      bit seen = 0;
      foreach (urow[j]) if (urow[j] == rows[i]) seen = 1;
      if (!seen) urow.push_back(rows[i]);
    end
    kind = 0;
    if (rows.size() == 0) return 1;
    // choose a subset of at most 2 distinct rows to give a spare row; like the RTL, keep the
    // solution that uses the fewest spares (rows + IOs), so `kind` is the minimal repair's kind
    for (int m = 0; m < (1 << urow.size()); m++) begin
      int pc = 0, nio = 0;
      int left[$];
      for (int j = 0; j < urow.size(); j++) if (m[j]) pc++;
      if (pc > 2) continue;
      left.delete();
      foreach (rows[i]) begin
        bit taken = 0;
        for (int j = 0; j < urow.size(); j++) if (m[j] && urow[j] == rows[i]) taken = 1;
        if (!taken) begin
          bit seen = 0;
          foreach (left[k]) if (left[k] == ios[i]) seen = 1;
          if (!seen) left.push_back(ios[i]);
        end
      end
      nio = left.size();
      if (nio <= 2 && pc + nio < best_cost) begin
        best_cost = pc + nio;
        kind = (pc > 0 && nio > 0) ? 3 : (pc > 0 ? 1 : 2);
      end
    end
    return best_cost != 99;
  endfunction
endclass
