// SRAMGuard parameter package -- every tunable lives here (spec section 1).
package sg_pkg;

  // ---- geometry (spec section 3, "Parameters")
  localparam int DATA_W     = 64;
  localparam int ECC_W      = 8;
  localparam int WORD_W     = DATA_W + ECC_W;       // 72
  localparam int DEPTH      = 4096;
  localparam int COL_MUX    = 8;
  localparam int ROWS       = 512;
  localparam int SPARE_ROWS = 2;
  localparam int SPARE_IOS  = 2;
  localparam int PROWS      = ROWS + SPARE_ROWS;    // 514 physical rows
  localparam int PIO        = WORD_W + SPARE_IOS;   // 74 physical IOs
  localparam int SEG_ROWS   = 2;
  localparam int SEG_WORDS  = SEG_ROWS * COL_MUX;   // 16
  localparam int FLOG_DEPTH = 8;
  localparam int CE_TAB     = 4;                    // repeat-CE table entries
  localparam int MAX_STALL  = 2;
  // spec 6.6: a capture that shows correctable errors at this many *different* bit positions is
  // not a soft error or a stuck IO (one or two positions), it looks like a decoder fault
  localparam int DF_TH      = 4;
  localparam int BM_DEPTH   = 32;                   // bitmap-dump FIFO entries (spec 5.5)

  // 1 = registered ECC decode output (read latency 2); 0 = combinational (latency 1)
  localparam int ECC_PIPE   = 1;
  localparam int LAT        = 1 + ECC_PIPE;

  // 1 = after reset skip the destructive test and only zero-fill (BYPASS baseline)
  localparam bit BYPASS_RESET = 1'b0;

  // ---- enums
  typedef enum logic [2:0] {
    ALG_MATS = 3'd0, ALG_MARCHC = 3'd1, ALG_MARCHLR = 3'd2, ALG_MARCHSS = 3'd3, ALG_CUSTOM = 3'd4
  } alg_e;

  typedef enum logic [1:0] {
    MODE_RESET_TEST = 2'd0, MODE_ONLINE = 2'd1, MODE_MAINT = 2'd2, MODE_BYPASS = 2'd3
  } mode_e;

  typedef enum logic [1:0] {
    BG_SOLID = 2'd0, BG_CHECKER = 2'd1, BG_ROWSTRIPE = 2'd2, BG_COLSTRIPE = 2'd3
  } bg_e;

  typedef enum logic [1:0] {
    DIAG_GONOGO = 2'd0, DIAG_COLLECT = 2'd1, DIAG_BITMAP = 2'd2
  } diag_e;

  // ---- CSR-driven configuration
  typedef struct packed {
    logic        test_en;
    logic        scrub_en;
    logic        repair_en;
    logic        online_repair_en;
    logic        seg_overlap;
    logic        bypass;
    logic        freeze;
    logic [2:0]  alg_online;
    logic [2:0]  alg_poweron;
    logic [1:0]  bg;
    logic [1:0]  diag;
    logic [15:0] test_min_bw;
    logic [31:0] scrub_period;
    logic [3:0]  ce_th;
  } cfg_t;

  // ---- one array access (after arbitration, before remap)
  //   rowraw : addr[12:3] is a physical row, skip the row-remap CAM
  //   ioraw  : wdata/rdata are the 74-bit physical word, skip the IO shift muxes
  //   logical access: addr[11:0] is the word address, wdata[71:0] the codeword
  typedef struct packed {
    logic           en;
    logic           we;
    logic           rowraw;
    logic           ioraw;
    logic [12:0]    addr;
    logic [PIO-1:0] wdata;
  } arr_cmd_t;

  // ---- tag that follows a read through the return/decode pipeline
  typedef enum logic [2:0] {
    K_NONE = 3'd0, K_FRD = 3'd1, K_FBYP = 3'd2, K_FWR = 3'd3, K_RMW = 3'd4, K_CAP = 3'd5
  } kind_e;

  typedef struct packed {
    kind_e      kind;
    logic [3:0] idx;
  } tag_t;

  // ---- counter ids (CSR 0x80 + 4*id)
  localparam int N_CNT    = 14;
  localparam int C_CE     = 0;
  localparam int C_UE     = 1;
  localparam int C_HARD   = 2;
  localparam int C_TRANS  = 3;
  localparam int C_WIN    = 4;
  localparam int C_SWEEP  = 5;
  localparam int C_STALL  = 6;
  localparam int C_TESTCY = 7;
  localparam int C_REPAIR = 8;
  localparam int C_REQ    = 9;
  localparam int C_ARRCY  = 10;
  localparam int C_IDLE   = 11;
  localparam int C_CYC    = 12;
  localparam int C_DF     = 13;   // windows aborted on a decoder-fault capture pattern

  // ---- data background D(r,c,b), spec 5.3.  (8b + c) mod 2 == c[0], so the value is the
  // same for every bit of the word; it is replicated across the 74 physical IOs.
  function automatic logic [PIO-1:0] bg_data(input logic [1:0] bg,
                                             input logic [9:0] r,
                                             input logic [2:0] c);
    logic v;
    case (bg)
      BG_CHECKER:   v = r[0] ^ c[0];
      BG_ROWSTRIPE: v = r[0];
      BG_COLSTRIPE: v = c[0];
      default:      v = 1'b0;
    endcase
    return {PIO{v}};
  endfunction

endpackage
