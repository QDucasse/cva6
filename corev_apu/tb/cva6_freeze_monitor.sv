// Copyright 2026 CentraleSupélec
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
//
// Hidden-freeze state monitor, simulation only.
//
// While the core is frozen (csr_regfile freeze_o), the caches, TLBs and predictors must not
// change. The monitor flags any change, cycle by cycle, which is stricter than comparing a
// snapshot at the freeze start with the state at the return:
//   - cache tag/valid SRAMs: any write;
//   - registers (LFSRs, TLB arrays and PLRU trees, BHT, BTB, RAS): any change of the register.
// Cache data is not checked (store hits update it). A guest data-cache miss accepted before the
// exit may still fill while frozen: data-cache checks start at the first frozen cycle with no
// cacheable miss in the MSHR. A frozen AMO invalidates the way its line hits in: that is allowed
// (one way, valid cleared), and listed as "allowed dcache-amo-inv@<cycle>".
//
// One line per freeze window:
//   [freeze-mon] window <n> cycles <first>-<last> end=<xret|hfrz0> clean
//   [freeze-mon] window <n> cycles <first>-<last> end=<xret|hfrz0> CHANGED <struct>@<cycle> ...
// end=xret: the return to the guest ended the freeze; end=hfrz0: HFRZ was written 0.
// A change in a checked structure is fatal at the end of its window.
//
// Plusargs:
//   +freeze_mon_mask=<hex>  structures checked (bit = index in the table below), default all;
//                           unchecked changes are still reported, as "(unchecked)"
//   +freeze_mon_warn        report changes without failing

module cva6_freeze_monitor (
    input logic clk_i,
    input logic rst_ni
);

  localparam int unsigned NumStructs = 9;
  localparam int unsigned DcacheTags = 0;
  localparam int unsigned DcacheLfsr = 1;
  localparam int unsigned IcacheTags = 2;
  localparam int unsigned IcacheLfsr = 3;
  localparam int unsigned Itlb = 4;
  localparam int unsigned Dtlb = 5;
  localparam int unsigned Bht = 6;
  localparam int unsigned Btb = 7;
  localparam int unsigned Ras = 8;

  function automatic string struct_name(int unsigned i);
    case (i)
      DcacheTags: return "dcache-tags";
      DcacheLfsr: return "dcache-lfsr";
      IcacheTags: return "icache-tags";
      IcacheLfsr: return "icache-lfsr";
      Itlb:       return "itlb";
      Dtlb:       return "dtlb";
      Bht:        return "bht";
      Btb:        return "btb";
      Ras:        return "ras";
      default:    return "?";
    endcase
  endfunction

  // Paths into the core (cv64a6_imafdch_sv39_htime: WT caches, private TLBs, ASIC BHT/BTB)
  `define FM_CORE ariane_testharness.i_ariane.i_cva6
  `define FM_DCACHE `FM_CORE.gen_cache_wt.i_cache_subsystem.i_wt_dcache
  `define FM_ICACHE `FM_CORE.gen_cache_wt.i_cache_subsystem.i_cva6_icache
  `define FM_MMU `FM_CORE.ex_stage_i.lsu_i.gen_mmu.i_cva6_mmu
  `define FM_FRONTEND `FM_CORE.i_frontend

  logic freeze, freeze_q;
  assign freeze = `FM_CORE.freeze_csr;

  // Data-cache checks start once no cacheable (guest) miss is outstanding
  logic dc_guest_miss, dc_check, dc_check_q;
  assign dc_guest_miss = `FM_DCACHE.i_wt_dcache_missunit.mshr_vld_q &&
                         !`FM_DCACHE.i_wt_dcache_missunit.mshr_q.nc;
  assign dc_check = freeze && (dc_check_q || !dc_guest_miss);

  // Allowed: a frozen AMO invalidating one way
  logic dc_amo_inv;
  assign dc_amo_inv = `FM_DCACHE.i_wt_dcache_missunit.amo_frz_q &&
                      `FM_DCACHE.i_wt_dcache_mem.vld_we &&
                      $onehot(`FM_DCACHE.i_wt_dcache_mem.vld_req) &&
                      `FM_DCACHE.i_wt_dcache_mem.vld_wdata == '0;

  // Register copies from the previous cycle
  var type (`FM_DCACHE.i_wt_dcache_missunit.i_lfsr_inv.lfsr_q) dc_lfsr_q;
  var type (`FM_ICACHE.i_lfsr.lfsr_q) ic_lfsr_q;
  var type (`FM_MMU.i_itlb.tags_q) itlb_tags_q;
  var type (`FM_MMU.i_itlb.content_q) itlb_content_q;
  var type (`FM_MMU.i_itlb.plru_tree_q) itlb_plru_q;
  var type (`FM_MMU.i_dtlb.tags_q) dtlb_tags_q;
  var type (`FM_MMU.i_dtlb.content_q) dtlb_content_q;
  var type (`FM_MMU.i_dtlb.plru_tree_q) dtlb_plru_q;
  var type (`FM_FRONTEND.bht_gen.i_bht.bht_q) bht_q;
  var type (`FM_FRONTEND.btb_gen.i_btb.gen_asic_btb.btb_q) btb_q;
  var type (`FM_FRONTEND.ras_gen.i_ras.stack_q) ras_q;

  // Changes: SRAM writes in this cycle, register changes made in the previous cycle
  logic [NumStructs-1:0] chg_now, chg_prev;
  always_comb begin
    chg_now = '0;
    chg_now[DcacheTags] = dc_check && `FM_DCACHE.i_wt_dcache_mem.vld_we &&
                          |`FM_DCACHE.i_wt_dcache_mem.vld_req && !dc_amo_inv;
    chg_now[IcacheTags] = freeze && `FM_ICACHE.vld_we && |`FM_ICACHE.vld_req;

    chg_prev = '0;
    chg_prev[DcacheLfsr] = dc_check_q &&
                           dc_lfsr_q != `FM_DCACHE.i_wt_dcache_missunit.i_lfsr_inv.lfsr_q;
    chg_prev[IcacheLfsr] = freeze_q && ic_lfsr_q != `FM_ICACHE.i_lfsr.lfsr_q;
    chg_prev[Itlb] = freeze_q && (itlb_tags_q != `FM_MMU.i_itlb.tags_q ||
                                  itlb_content_q != `FM_MMU.i_itlb.content_q ||
                                  itlb_plru_q != `FM_MMU.i_itlb.plru_tree_q);
    chg_prev[Dtlb] = freeze_q && (dtlb_tags_q != `FM_MMU.i_dtlb.tags_q ||
                                  dtlb_content_q != `FM_MMU.i_dtlb.content_q ||
                                  dtlb_plru_q != `FM_MMU.i_dtlb.plru_tree_q);
    chg_prev[Bht] = freeze_q && bht_q != `FM_FRONTEND.bht_gen.i_bht.bht_q;
    chg_prev[Btb] = freeze_q && btb_q != `FM_FRONTEND.btb_gen.i_btb.gen_asic_btb.btb_q;
    chg_prev[Ras] = freeze_q && ras_q != `FM_FRONTEND.ras_gen.i_ras.stack_q;
  end

  logic [NumStructs-1:0] mask;
  bit warn_only;
  initial begin
    if (!$value$plusargs("freeze_mon_mask=%h", mask)) mask = '1;
    warn_only = $test$plusargs("freeze_mon_warn");
  end

  longint unsigned cycle;
  longint unsigned win_first;
  int unsigned windows;
  logic [NumStructs-1:0] changed;
  longint unsigned first_chg[NumStructs];
  bit amo_inv;
  longint unsigned first_amo_inv;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cycle      <= 0;
      freeze_q   <= 1'b0;
      dc_check_q <= 1'b0;
      windows    <= 0;
      changed    <= '0;
      amo_inv    <= 1'b0;
    end else begin
      automatic logic [NumStructs-1:0] chg = changed;
      automatic string msg;

      cycle      <= cycle + 1;
      freeze_q   <= freeze;
      dc_check_q <= dc_check;

      dc_lfsr_q      <= `FM_DCACHE.i_wt_dcache_missunit.i_lfsr_inv.lfsr_q;
      ic_lfsr_q      <= `FM_ICACHE.i_lfsr.lfsr_q;
      itlb_tags_q    <= `FM_MMU.i_itlb.tags_q;
      itlb_content_q <= `FM_MMU.i_itlb.content_q;
      itlb_plru_q    <= `FM_MMU.i_itlb.plru_tree_q;
      dtlb_tags_q    <= `FM_MMU.i_dtlb.tags_q;
      dtlb_content_q <= `FM_MMU.i_dtlb.content_q;
      dtlb_plru_q    <= `FM_MMU.i_dtlb.plru_tree_q;
      bht_q          <= `FM_FRONTEND.bht_gen.i_bht.bht_q;
      btb_q          <= `FM_FRONTEND.btb_gen.i_btb.gen_asic_btb.btb_q;
      ras_q          <= `FM_FRONTEND.ras_gen.i_ras.stack_q;

      if (freeze && !freeze_q) win_first <= cycle;

      for (int unsigned i = 0; i < NumStructs; i++) begin
        if (chg_prev[i] && !chg[i]) begin
          chg[i] = 1'b1;
          first_chg[i] <= cycle - 1;
        end
        if (chg_now[i] && !chg[i]) begin
          chg[i] = 1'b1;
          first_chg[i] <= cycle;
        end
      end
      changed <= chg;
      if (dc_check && dc_amo_inv && !amo_inv) begin
        amo_inv       <= 1'b1;
        first_amo_inv <= cycle;
      end

      // The window closed in the previous cycle: its last register changes are checked now
      if (freeze_q && !freeze) begin
        msg = $sformatf("[freeze-mon] window %0d cycles %0d-%0d end=", windows, win_first,
                        cycle - 1);
        msg = {msg, `FM_CORE.csr_regfile_i.htimectl_hfrz_q ? "xret" : "hfrz0"};
        if (chg == '0) begin
          msg = {msg, " clean"};
        end else begin
          msg = {msg, " CHANGED"};
          for (int unsigned i = 0; i < NumStructs; i++) begin
            if (chg[i]) begin
              // first_chg is not updated yet for changes found in this cycle
              msg = {msg, $sformatf(" %s@%0d", struct_name(i),
                                    changed[i] ? first_chg[i] : (chg_now[i] ? cycle : cycle - 1))};
              if (!mask[i]) msg = {msg, "(unchecked)"};
            end
          end
        end
        if (amo_inv) msg = {msg, $sformatf(" allowed dcache-amo-inv@%0d", first_amo_inv)};
        $display("%s", msg);
        windows <= windows + 1;
        changed <= '0;
        amo_inv <= 1'b0;
        if ((chg & mask) != '0 && !warn_only) $fatal(1, "[freeze-mon] frozen state changed");
      end
    end
  end

  `undef FM_CORE
  `undef FM_DCACHE
  `undef FM_ICACHE
  `undef FM_MMU
  `undef FM_FRONTEND

endmodule
