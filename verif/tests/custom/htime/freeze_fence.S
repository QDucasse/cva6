# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden freeze, fences: fences work normally while frozen, and their
# effect is the expected difference. The guest runs with a G-stage identity map of the first
# 2 MiB of DRAM (hgatp Sv39x4, vsatp bare).
#   1. The guest calls patch_fn (returns 1). Frozen exit: HS rewrites patch_fn to return 2 and
#      runs fence.i. The guest must get 2.
#   2. The guest reads page_a (PAGE_A_VAL). Frozen exit: HS points the G-stage leaf of page_a at
#      page_b and runs hfence.gvma. The guest must read PAGE_B_VAL at the same address.
# The testbench freeze monitor checks that nothing changed while frozen apart from the fences:
# it must list icache-fence in the first window, itlb-fence and dtlb-fence in the second.
#
# Expected windows: xret, xret, hfrz0 (the final ebreak to M, ended in M).

#include "htime_macros.h"

#define CAUSE_VS_ECALL  10
#define MODE_VS         (MSTATUS_MPP_S | MSTATUS_MPV)
#define CSR_HGATP_NUM   0x680
#define HGATP_SV39X4    (8 << 60)
#define G_LEAF          (PTE_V | PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D)
#define ADDI_A0_ZERO(imm) (((imm) << 20) | (10 << 7) | 0x13)
#define PAGE_A_VAL      0x1111aaaa
#define PAGE_B_VAL      0x2222bbbb

#define ACT_PATCH       1
#define ACT_REMAP       2

RVTEST_RV64M
RVTEST_CODE_BEGIN

  li   TESTNUM, 1
  csrw medeleg, zero
  li   t0, (1 << CAUSE_VS_ECALL)
  csrs medeleg, t0
  la   t0, stvec_handler
  csrw stvec, t0

  # G-stage identity map of [DRAM_BASE, DRAM_BASE + 2 MiB) with 4 KiB leaves
  la   a4, g_l0
  li   a5, (DRAM_BASE >> 12) << 10
  li   a6, 512
  li   t1, G_LEAF
1:
  or   t0, a5, t1
  sd   t0, 0(a4)
  addi a4, a4, 8
  li   t0, 1 << 10
  add  a5, a5, t0
  addi a6, a6, -1
  bnez a6, 1b
  la   t0, g_l0
  srli t0, t0, 12
  slli t0, t0, 10
  ori  t0, t0, PTE_V
  la   t1, g_l1
  sd   t0, (((DRAM_BASE >> 21) & 0x1ff) * 8)(t1)
  la   t0, g_l1
  srli t0, t0, 12
  slli t0, t0, 10
  ori  t0, t0, PTE_V
  la   t1, g_root
  sd   t0, ((DRAM_BASE >> 30) * 8)(t1)
  la   t0, g_root
  srli t0, t0, 12
  li   t1, HGATP_SV39X4
  or   t0, t0, t1
  csrw CSR_HGATP_NUM, t0
  hfence.gvma

  li   t0, HTIMECTL_HFRZ
  csrw CSR_HTIMECTL_NUM, t0
  ENTER_MODE(MODE_VS)

  # 1. fence.i
  jal  patch_fn
  li   t0, 1
  bne  a0, t0, fail
  li   TESTNUM, 2
  li   a5, ACT_PATCH
  ecall
  li   TESTNUM, 3
  jal  patch_fn
  li   t0, 2
  bne  a0, t0, fail

  # 2. hfence.gvma
  li   TESTNUM, 4
  la   t2, page_a
  lw   t0, 0(t2)
  li   t1, PAGE_A_VAL
  bne  t0, t1, fail
  li   a5, ACT_REMAP
  ecall
  li   TESTNUM, 5
  la   t2, page_a
  lw   t0, 0(t2)
  li   t1, PAGE_B_VAL
  bne  t0, t1, fail

  EXIT_TO_M
  csrw CSR_HTIMECTL_NUM, zero
  csrw CSR_HGATP_NUM, zero
  hfence.gvma

  j pass

  .option push
  .option norvc
  .align 6
patch_fn:
  addi a0, zero, 1
  ret
  .option pop

  TEST_PASSFAIL

  # HS exit handler (frozen, bare): a5 = action.
  .align 2
stvec_handler:
  csrr t5, scause
  li   t6, CAUSE_VS_ECALL
  bne  t5, t6, fail
  li   t5, ACT_PATCH
  bne  a5, t5, 1f
  la   t5, patch_fn
  li   t6, ADDI_A0_ZERO(2)
  sw   t6, 0(t5)
  fence.i
  j    2f
1:
  # g_l0[page_a] = leaf for page_b
  la   t5, page_b
  srli t5, t5, 12
  slli t5, t5, 10
  ori  t5, t5, G_LEAF
  la   t6, page_a
  li   t4, DRAM_BASE
  sub  t6, t6, t4
  srli t6, t6, 12
  slli t6, t6, 3
  la   t4, g_l0
  add  t6, t6, t4
  sd   t5, 0(t6)
  hfence.gvma
2:
  csrr t6, sepc
  addi t6, t6, 4
  csrw sepc, t6
  sret

  HTIME_MTVEC_HANDLER

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
  .align 14
g_root:  .fill 2048, 8, 0           # 16 KiB Sv39x4 root
  .align 12
g_l1:    .fill 512, 8, 0
g_l0:    .fill 512, 8, 0
page_a:
  .word PAGE_A_VAL
  .fill 1023, 4, 0
page_b:
  .word PAGE_B_VAL
  .fill 1023, 4, 0
RVTEST_DATA_END
