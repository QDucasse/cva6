// Copyright 2026 Quentin Ducasse
// SPDX-License-Identifier: SHL-0.51
//
// Description: exhaustive testbench for the JITDomain access check. For every
// privilege level, debug mode, enable, SCHK, PMP lock, access type and kind,
// domain, pending entry, typed target, key and DRS key, it tries all eight
// rights values in the cell the access should use, with every other cell of
// the matrix set to the complement, and compares dom_check with a reference
// model written from the access-check pseudocode.
//
// Run with core/pmp/tb/run_dom_check_tb.sh.

module dom_check_tb
  import ariane_pkg::*;
#(
    parameter int unsigned NrDomains = 8,
    parameter int unsigned NrKeys    = 8
);

  function automatic config_pkg::cva6_cfg_t tb_cfg();
    config_pkg::cva6_cfg_t cfg;
    cfg = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
    cfg.JITDomain = 1'b1;
    cfg.NrDomains = NrDomains;
    cfg.NrKeys = NrKeys;
    return cfg;
  endfunction
  localparam config_pkg::cva6_cfg_t CVA6Cfg = tb_cfg();

  typedef enum int {
    ACC_FETCH,
    ACC_LOAD,
    ACC_STORE,
    ACC_AMO
  } access_e;

  jd_state_t state;
  logic debug_mode;
  riscv::priv_lvl_t priv;
  logic fetch;
  jd_kind_t kind;
  logic [2:0] need;
  logic [2:0] key;
  logic pmp_locked;
  logic allow;

  dom_check #(
      .CVA6Cfg(CVA6Cfg)
  ) dut (
      .state_i     (state),
      .debug_mode_i(debug_mode),
      .priv_lvl_i  (priv),
      .fetch_i     (fetch),
      .kind_i      (kind),
      .need_i      (need),
      .key_i       (key),
      .pmp_locked_i(pmp_locked),
      .allow_o     (allow)
  );

  // drights2:drights1:drights0, entry (e, k) at bits [3*(8*e+k) +: 3] = {X, W, R}
  logic [191:0] drights_flat;

  function automatic logic [2:0] rights_cell(int e, int k);
    return drights_flat[3*(8*e+k)+:3];
  endfunction

  // The access check, as the specification writes it
  function automatic bit ref_allow(access_e acc, jd_kind_t knd);
    int e;
    logic [2:0] want;
    bit drs_access, checked;
    if (!state.en || debug_mode) return 1;
    drs_access = acc != ACC_FETCH && knd == JD_DRS;
    case (acc)
      ACC_FETCH: e = state.dpend.valid ? state.dpend.dom : state.curdom;
      default:   e = knd == JD_TYPED ? state.dtarget[state.curdom] : state.curdom;
    endcase
    case (acc)
      ACC_FETCH: want = 3'b100;
      ACC_LOAD:  want = 3'b001;
      ACC_STORE: want = 3'b010;
      default:   want = 3'b011;
    endcase
    // An implicit DRS access needs a DRS page and nothing else
    if (drs_access) return key == state.drskey;
    checked = priv == riscv::PRIV_LVL_U || (priv == riscv::PRIV_LVL_S && state.schk) ||
              (priv == riscv::PRIV_LVL_M && pmp_locked);
    if (key == state.drskey && priv == riscv::PRIV_LVL_U) return 0;
    // Unimplemented keys have no rights; the matrix itself is legal (zero
    // outside the implemented rows and columns)
    if (checked && (rights_cell(e, key) & want) != want) return 0;
    return 1;
  endfunction

  // Fill the matrix with ~v except cell (e, k) = v, keeping unimplemented
  // rows and columns at zero as the CSR does
  task automatic set_matrix(int e, int k, logic [2:0] v);
    for (int d = 0; d < 8; d++)
    for (int kk = 0; kk < 8; kk++) begin
      logic [2:0] val;
      val = (d == e && kk == k) ? v : ~v;
      if (d >= NrDomains || kk >= NrKeys) val = '0;
      drights_flat[3*(8*d+kk)+:3] = val;
      state.drights[d][kk] = val;
    end
  endtask

  longint unsigned checks = 0, errors = 0;

  initial begin
    riscv::priv_lvl_t privs[3] = '{riscv::PRIV_LVL_U, riscv::PRIV_LVL_S, riscv::PRIV_LVL_M};
    state = '0;
    for (int d = 0; d < 8; d++) state.dtarget[d] = 3'(d % NrDomains);
    foreach (privs[p])
    for (int dbg = 0; dbg < 2; dbg++)
    for (int en = 0; en < 2; en++)
    for (int schk = 0; schk < 2; schk++)
    for (int lck = 0; lck < 2; lck++)
    for (int a = ACC_FETCH; a <= ACC_AMO; a++)
    for (int kd = JD_ORDINARY; kd <= JD_DRS; kd++) begin
      if (a == ACC_FETCH && kd != JD_ORDINARY) continue;
      for (int cur = 0; cur < NrDomains; cur++)
      // pending entry: none, or one for each domain (fetches only)
      for (int pend = -1; pend < (a == ACC_FETCH ? int'(NrDomains) : 0); pend++)
      // typed target of the current domain (typed accesses only)
      for (int tgt = 0; tgt < (kd == JD_TYPED ? int'(NrDomains) : 1); tgt++)
      for (int k = 0; k < 8; k++)
      for (int dk = 0; dk < NrKeys; dk++)
      for (int v = 0; v < 8; v++) begin
        int e;
        priv            = privs[p];
        debug_mode      = 1'(dbg);
        state.en        = 1'(en);
        state.schk      = 1'(schk);
        pmp_locked      = 1'(lck);
        state.curdom    = 3'(cur);
        state.dpend     = '0;
        state.dpend.valid = pend >= 0;
        state.dpend.dom = pend >= 0 ? 3'(pend) : 3'(0);
        state.dpend.label = 9'h1a5;
        state.dtarget[cur] = kd == JD_TYPED ? 3'(tgt) : 3'(cur);
        state.drskey    = 3'(dk);
        key             = 3'(k);
        fetch           = a == ACC_FETCH;
        kind            = jd_kind_t'(kd);
        case (a)
          ACC_FETCH: need = JD_RIGHT_X;
          ACC_LOAD:  need = JD_RIGHT_R;
          ACC_STORE: need = JD_RIGHT_W;
          default:   need = JD_RIGHT_R | JD_RIGHT_W;
        endcase
        e = a == ACC_FETCH ? (pend >= 0 ? pend : cur) : (kd == JD_TYPED ? tgt : cur);
        set_matrix(e, k, 3'(v));
        #1;
        checks++;
        if (allow !== ref_allow(access_e'(a), jd_kind_t'(kd))) begin
          errors++;
          if (errors <= 10)
            $display("MISMATCH priv=%0d dbg=%0d en=%0d schk=%0d locked=%0d access=%0d kind=%0d curdom=%0d pend=%0d target=%0d key=%0d drskey=%0d rights=%03b: dut=%0b ref=%0b",
                     priv, dbg, en, schk, lck, a, kd, cur, pend, tgt, k, dk, v, allow,
                     ref_allow(access_e'(a), jd_kind_t'(kd)));
        end
        state.dtarget[cur] = 3'(cur);
      end
    end
    $display("dom_check_tb D=%0d K=%0d: %0d checks, %0d errors", NrDomains, NrKeys, checks, errors);
    if (errors != 0) $fatal(1, "dom_check_tb failed");
    $finish;
  end
endmodule
