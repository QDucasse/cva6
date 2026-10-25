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
//   - cache tag/valid SRAMs of the main ways: any write;
//   - registers (LFSRs, TLB arrays and PLRU trees, BHT, BTB, RAS): any change of the register.
//     The scratch ways of the caches and the TLBs' scratch entries are not checked: they hold
//     what the frozen misses and walks fetch.
// Cache data is not checked (store hits update it). A guest data-cache miss accepted before the
// exit may still fill while frozen: data-cache checks start at the first frozen cycle with no
// cacheable main-way miss in the MSHR.
// Allowed changes, listed as "allowed <what>@<cycle>" but not failing:
//   - dcache-amo-inv: a frozen AMO invalidating the way its line hits in (one way, valid cleared);
//   - dcache-fence, icache-fence: a cache flush (fence.i, or fence with DcacheFlushOnFence);
//   - itlb-fence, dtlb-fence: a TLB flush (sfence.vma, hfence.vvma, hfence.gvma).
//
// One line per freeze window:
//   [freeze-mon] window <n> cycles <first>-<last> end=<xret|hfrz0> clean [allowed ...]
//   [freeze-mon] window <n> cycles <first>-<last> end=<xret|hfrz0> CHANGED <struct>@<cycle> ...
// end=xret: the return to the guest ended the freeze; end=hfrz0: HFRZ was written 0.
// A change in a checked structure is fatal at the end of its window.
//
// Scratch structures, checked outside the windows, fatal at once:
//   - wipe: from the second cycle after a window ends until the next one starts, no scratch entry
//     is valid (the wipe clears them at the end of the first unfrozen cycle);
//   - no unfrozen hit: a lookup never hits a scratch entry while not frozen.
//   [freeze-mon] scratch <struct> valid while not frozen @<cycle>
//   [freeze-mon] scratch <struct> hit while not frozen @<cycle>
//
// Each window also gives a token: its end reason, then "+<what>" for each allowed change, in the
// order above (e.g. "xret+itlb-fence+dtlb-fence"). With +freeze_mon_expect, a test that passes
// (tohost = 1) fails unless its windows' tokens are exactly the expected ones, so a test whose
// freeze never happened, ended the wrong way or had other allowed changes can't pass.
//
// Plusargs:
//   +freeze_mon_mask=<hex>       structures checked (bit = index in the table below), default
//                                all; unchecked changes are still reported, as "(unchecked)"
//   +freeze_mon_warn             report changes without failing
//   +freeze_mon_expect=<tokens>  expected windows, comma-separated tokens

module cva6_freeze_monitor #(
    // TLB arrays (the scratch entries after them are allowed to change while frozen)
    parameter int unsigned ItlbEntries = 16,
    parameter int unsigned DtlbEntries = 16,
    // TLB scratch entries (HiddenFreezeScratchTlb, at least 1)
    parameter int unsigned TlbScratch = 1,
    // cache main ways (the scratch ways after them are allowed to change while frozen)
    parameter int unsigned DcacheWays = 8,
    parameter int unsigned IcacheWays = 4,
    // cache scratch ways (HiddenFreezeScratchWays)
    parameter int unsigned CacheScratch = 0
) (
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

  // Data-cache checks start once no cacheable (guest) miss to the main ways is outstanding
  logic dc_guest_miss, dc_check, dc_check_q;
  assign dc_guest_miss = `FM_DCACHE.i_wt_dcache_missunit.mshr_vld_q &&
                         !`FM_DCACHE.i_wt_dcache_missunit.mshr_q.nc &&
                         `FM_DCACHE.i_wt_dcache_missunit.mshr_q.scratch_oh == '0;
  assign dc_check = freeze && (dc_check_q || !dc_guest_miss);

  // Allowed changes
  localparam int unsigned NumAllowed = 5;
  localparam int unsigned AmoInv = 0;
  localparam int unsigned DcacheFence = 1;
  localparam int unsigned IcacheFence = 2;
  localparam int unsigned ItlbFence = 3;
  localparam int unsigned DtlbFence = 4;

  function automatic string allowed_name(int unsigned i);
    case (i)
      AmoInv:      return "dcache-amo-inv";
      DcacheFence: return "dcache-fence";
      IcacheFence: return "icache-fence";
      ItlbFence:   return "itlb-fence";
      DtlbFence:   return "dtlb-fence";
      default:     return "?";
    endcase
  endfunction

  logic dc_amo_inv, dc_flush, ic_flush, itlb_flush, itlb_flush_q, dtlb_flush, dtlb_flush_q;
  assign dc_amo_inv = `FM_DCACHE.i_wt_dcache_missunit.amo_frz_q &&
                      $onehot(`FM_DCACHE.i_wt_dcache_mem.vld_req[DcacheWays-1:0]) &&
                      `FM_DCACHE.i_wt_dcache_mem.vld_wdata == '0;
  assign dc_flush = `FM_DCACHE.i_wt_dcache_missunit.flush_en;
  assign ic_flush = `FM_ICACHE.flush_en;
  assign itlb_flush = `FM_MMU.i_itlb.flush_i || `FM_MMU.i_itlb.flush_vvma_i ||
                      `FM_MMU.i_itlb.flush_gvma_i;
  assign dtlb_flush = `FM_MMU.i_dtlb.flush_i || `FM_MMU.i_dtlb.flush_vvma_i ||
                      `FM_MMU.i_dtlb.flush_gvma_i;

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

  // Scratch structures: any entry valid, any entry hit by a lookup
  localparam int unsigned NumScratch = 4;
  localparam int unsigned ItlbScratch = 0;
  localparam int unsigned DtlbScratch = 1;
  localparam int unsigned DcacheScratch = 2;
  localparam int unsigned IcacheScratch = 3;

  function automatic string scratch_name(int unsigned i);
    case (i)
      ItlbScratch:   return "itlb";
      DtlbScratch:   return "dtlb";
      DcacheScratch: return "dcache";
      IcacheScratch: return "icache";
      default:       return "?";
    endcase
  endfunction

  logic dc_scr_vld, dc_scr_hit, ic_scr_vld, ic_scr_hit;
  if (CacheScratch > 0) begin : gen_cache_scratch
    assign dc_scr_vld = |`FM_DCACHE.i_wt_dcache_mem.gen_scratch.vld_q;
    assign dc_scr_hit = |(`FM_DCACHE.i_wt_dcache_mem.rd_hit_oh_o >> DcacheWays);
    assign ic_scr_vld = |`FM_ICACHE.gen_scratch.vld_q;
    assign ic_scr_hit = |(`FM_ICACHE.cl_hit >> IcacheWays) && `FM_ICACHE.cmp_en_q;
  end else begin : gen_no_cache_scratch
    assign dc_scr_vld = 1'b0;
    assign dc_scr_hit = 1'b0;
    assign ic_scr_vld = 1'b0;
    assign ic_scr_hit = 1'b0;
  end

  logic [NumScratch-1:0] scr_vld, scr_hit;
  always_comb begin
    scr_vld = '0;
    scr_hit = '0;
    scr_vld[DcacheScratch] = dc_scr_vld;
    scr_hit[DcacheScratch] = dc_scr_hit;
    scr_vld[IcacheScratch] = ic_scr_vld;
    scr_hit[IcacheScratch] = ic_scr_hit;
    for (int unsigned i = ItlbEntries; i < ItlbEntries + TlbScratch; i++) begin
      scr_vld[ItlbScratch] |= `FM_MMU.i_itlb.tags_q[i].valid;
      scr_hit[ItlbScratch] |= `FM_MMU.i_itlb.lu_hit[i] && `FM_MMU.i_itlb.lu_access_i;
    end
    for (int unsigned i = DtlbEntries; i < DtlbEntries + TlbScratch; i++) begin
      scr_vld[DtlbScratch] |= `FM_MMU.i_dtlb.tags_q[i].valid;
      scr_hit[DtlbScratch] |= `FM_MMU.i_dtlb.lu_hit[i] && `FM_MMU.i_dtlb.lu_access_i;
    end
  end

  // Changes: SRAM writes in this cycle, register changes made in the previous cycle. A change
  // with an allowed cause goes to alw_* instead of chg_*.
  logic [NumStructs-1:0] chg_now, chg_prev;
  logic [NumAllowed-1:0] alw_now, alw_prev;
  logic dc_tag_wr, ic_tag_wr, itlb_chg, dtlb_chg;
  always_comb begin
    dc_tag_wr = dc_check && `FM_DCACHE.i_wt_dcache_mem.vld_we &&
                |`FM_DCACHE.i_wt_dcache_mem.vld_req[DcacheWays-1:0];
    ic_tag_wr = freeze && `FM_ICACHE.vld_we && |`FM_ICACHE.vld_req[IcacheWays-1:0];
    itlb_chg = freeze_q &&
        (itlb_tags_q[ItlbEntries-1:0] != `FM_MMU.i_itlb.tags_q[ItlbEntries-1:0] ||
         itlb_content_q[ItlbEntries-1:0] != `FM_MMU.i_itlb.content_q[ItlbEntries-1:0] ||
         itlb_plru_q != `FM_MMU.i_itlb.plru_tree_q);
    dtlb_chg = freeze_q &&
        (dtlb_tags_q[DtlbEntries-1:0] != `FM_MMU.i_dtlb.tags_q[DtlbEntries-1:0] ||
         dtlb_content_q[DtlbEntries-1:0] != `FM_MMU.i_dtlb.content_q[DtlbEntries-1:0] ||
         dtlb_plru_q != `FM_MMU.i_dtlb.plru_tree_q);

    alw_now = '0;
    alw_now[AmoInv] = dc_tag_wr && dc_amo_inv;
    alw_now[DcacheFence] = dc_tag_wr && dc_flush;
    alw_now[IcacheFence] = ic_tag_wr && ic_flush;
    alw_prev = '0;
    alw_prev[ItlbFence] = itlb_chg && itlb_flush_q;
    alw_prev[DtlbFence] = dtlb_chg && dtlb_flush_q;

    chg_now = '0;
    chg_now[DcacheTags] = dc_tag_wr && !dc_amo_inv && !dc_flush;
    chg_now[IcacheTags] = ic_tag_wr && !ic_flush;

    chg_prev = '0;
    chg_prev[DcacheLfsr] = dc_check_q &&
                           dc_lfsr_q != `FM_DCACHE.i_wt_dcache_missunit.i_lfsr_inv.lfsr_q;
    chg_prev[IcacheLfsr] = freeze_q && ic_lfsr_q != `FM_ICACHE.i_lfsr.lfsr_q;
    chg_prev[Itlb] = itlb_chg && !itlb_flush_q;
    chg_prev[Dtlb] = dtlb_chg && !dtlb_flush_q;
    chg_prev[Bht] = freeze_q && bht_q != `FM_FRONTEND.bht_gen.i_bht.bht_q;
    chg_prev[Btb] = freeze_q && btb_q != `FM_FRONTEND.btb_gen.i_btb.gen_asic_btb.btb_q;
    chg_prev[Ras] = freeze_q && ras_q != `FM_FRONTEND.ras_gen.i_ras.stack_q;
  end

  logic [NumStructs-1:0] mask;
  bit warn_only;
  bit check_expect;
  string expect_wins;
  initial begin
    if (!$value$plusargs("freeze_mon_mask=%h", mask)) mask = '1;
    warn_only = $test$plusargs("freeze_mon_warn");
    check_expect = $value$plusargs("freeze_mon_expect=%s", expect_wins);
  end

  longint unsigned cycle;
  longint unsigned win_first;
  int unsigned windows;
  logic [NumStructs-1:0] changed;
  longint unsigned first_chg[NumStructs];
  logic [NumAllowed-1:0] allowed;
  longint unsigned first_alw[NumAllowed];
  string seen_wins;  // tokens of the windows so far, comma-separated
  logic [NumScratch-1:0] scr_vld_seen, scr_hit_seen;  // reported once each (+freeze_mon_warn)

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cycle      <= 0;
      freeze_q   <= 1'b0;
      dc_check_q <= 1'b0;
      windows    <= 0;
      changed    <= '0;
      allowed    <= '0;
      seen_wins  <= "";
      scr_vld_seen <= '0;
      scr_hit_seen <= '0;
    end else begin
      automatic logic [NumStructs-1:0] chg = changed;
      automatic logic [NumAllowed-1:0] alw = allowed;
      automatic string msg;
      automatic string tok;

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
      itlb_flush_q   <= itlb_flush;
      dtlb_flush_q   <= dtlb_flush;

      if (freeze && !freeze_q) win_first <= cycle;

      for (int unsigned i = 0; i < NumScratch; i++) begin
        if (!freeze_q && scr_vld[i] && !scr_vld_seen[i]) begin
          scr_vld_seen[i] <= 1'b1;
          $display("[freeze-mon] scratch %s valid while not frozen @%0d", scratch_name(i), cycle);
          if (!warn_only) $fatal(1, "[freeze-mon] scratch not wiped");
        end
        if (!freeze && scr_hit[i] && !scr_hit_seen[i]) begin
          scr_hit_seen[i] <= 1'b1;
          $display("[freeze-mon] scratch %s hit while not frozen @%0d", scratch_name(i), cycle);
          if (!warn_only) $fatal(1, "[freeze-mon] scratch hit while not frozen");
        end
      end

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
      for (int unsigned i = 0; i < NumAllowed; i++) begin
        if (alw_prev[i] && !alw[i]) begin
          alw[i] = 1'b1;
          first_alw[i] <= cycle - 1;
        end
        if (alw_now[i] && !alw[i]) begin
          alw[i] = 1'b1;
          first_alw[i] <= cycle;
        end
      end
      allowed <= alw;

      // The window closed in the previous cycle: its last register changes are checked now
      if (freeze_q && !freeze) begin
        msg = $sformatf("[freeze-mon] window %0d cycles %0d-%0d end=", windows, win_first,
                        cycle - 1);
        tok = `FM_CORE.csr_regfile_i.htimectl_hfrz_q ? "xret" : "hfrz0";
        msg = {msg, tok};
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
        for (int unsigned i = 0; i < NumAllowed; i++) begin
          if (alw[i]) begin
            msg = {msg, $sformatf(" allowed %s@%0d", allowed_name(i),
                                  allowed[i] ? first_alw[i] : (alw_now[i] ? cycle : cycle - 1))};
            tok = {tok, "+", allowed_name(i)};
          end
        end
        $display("%s", msg);
        seen_wins <= (windows == 0) ? tok : {seen_wins, ",", tok};
        windows <= windows + 1;
        changed <= '0;
        allowed <= '0;
        if ((chg & mask) != '0 && !warn_only) $fatal(1, "[freeze-mon] frozen state changed");
      end
    end
  end

  // End of test (testharness exit_o, bit 0 set, tohost in the upper bits): a passing test must
  // have had the expected windows. A failing test is already reported as such.
  logic test_done;
  assign test_done = ariane_testharness.exit_o[0];
  always @(posedge test_done) begin
    if (check_expect && ariane_testharness.exit_o == 32'd1) begin
      if (seen_wins != expect_wins) begin
        $display("[freeze-mon] windows %s, expected %s", (windows == 0) ? "none" : seen_wins,
                 expect_wins);
        $fatal(1, "[freeze-mon] unexpected freeze windows");
      end
      $display("[freeze-mon] windows as expected: %s", seen_wins);
    end
  end

  `undef FM_CORE
  `undef FM_DCACHE
  `undef FM_ICACHE
  `undef FM_MMU
  `undef FM_FRONTEND

endmodule
