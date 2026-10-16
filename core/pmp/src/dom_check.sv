// Copyright 2026 Quentin Ducasse
// SPDX-License-Identifier: SHL-0.51
//
// Description: JITDomain access check. Purely combinational, it sits next to
// the PMP check of the same access, so that a denied load never returns data.

module dom_check
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
) (
    // Committed JITDomain state - CSR_REGFILE
    input jd_state_t state_i,
    // Nothing is checked in debug mode - CSR_REGFILE
    input logic debug_mode_i,
    // Effective privilege level of the access
    input riscv::priv_lvl_t priv_lvl_i,
    // Instruction fetch: checked for the pending domain when an entry is pending
    input logic fetch_i,
    // Kind of a data access
    input jd_kind_t kind_i,
    // Rights the access needs, {X, W, R}
    input logic [2:0] need_i,
    // Key of the accessed page or PMP entry
    input logic [2:0] key_i,
    // The access matched a locked PMP entry, which checks M mode too
    input logic pmp_locked_i,
    // The domain check allows the access
    output logic allow_o
);
  logic [2:0] dom;
  logic [2:0] rights;
  logic drs_page;
  logic checked;

  always_comb begin
    // Domain whose rights apply
    if (fetch_i) dom = state_i.dpend.valid ? state_i.dpend.dom : state_i.curdom;
    else if (kind_i == JD_TYPED) dom = state_i.dtarget[state_i.curdom];
    else dom = state_i.curdom;

    // Unimplemented domains and keys have no rights
    rights = (32'(dom) < CVA6Cfg.NrDomains && 32'(key_i) < CVA6Cfg.NrKeys) ?
        state_i.drights[dom][key_i] : 3'b000;

    drs_page = key_i == state_i.drskey;
    checked = priv_lvl_i == riscv::PRIV_LVL_U ||
              (priv_lvl_i == riscv::PRIV_LVL_S && state_i.schk) ||
              (priv_lvl_i == riscv::PRIV_LVL_M && pmp_locked_i);

    allow_o = 1'b1;
    if (CVA6Cfg.JITDomain && state_i.en && !debug_mode_i) begin
      if (!fetch_i && kind_i == JD_DRS) begin
        // Implicit DRS accesses must hit DRS pages
        allow_o = drs_page;
      end else begin
        // Nothing else may touch DRS pages from U mode
        if (drs_page && priv_lvl_i == riscv::PRIV_LVL_U) allow_o = 1'b0;
        if (checked && (rights & need_i) != need_i) allow_o = 1'b0;
      end
    end
  end
endmodule
