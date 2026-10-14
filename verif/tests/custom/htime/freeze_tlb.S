# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden freeze, TLBs and page walker. Two identity maps of the first
# 2 MiB of DRAM with 4 KiB pages: G-stage (hgatp Sv39x4) for the guest, which runs with vsatp
# bare, and Sv39 (satp) for the HS handler. The guest loads one word in each of GUEST_PAGES
# pages, then exits to HS with HFRZ armed. The frozen HS handler, translated by satp, loads one
# word in each of HV_PAGES pages (more than the DTLB, so without the freeze every guest
# translation is evicted, and the handler's code fetches install ITLB entries). Every frozen
# walk result goes to a TLB scratch entry. The guest then loads its pages again. The
# testbench freeze monitor checks that the caches and TLBs (arrays and PLRU trees) didn't
# change while frozen.
#
# Expected windows: xret (the ecall exit), hfrz0 (the final ebreak to M, ended in M).

#include "htime_macros.h"

#define CAUSE_VS_ECALL  10
#define MODE_VS         (MSTATUS_MPP_S | MSTATUS_MPV)
#define CSR_HGATP_NUM   0x680
#define HGATP_SV39X4    (8 << 60)
#define PAGE            4096
#define GUEST_PAGES     12
#define HV_PAGES        20
#define G_LEAF          (PTE_V | PTE_R | PTE_W | PTE_X | PTE_U | PTE_A | PTE_D)
#define S_LEAF          (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)

# \l0[i] = identity leaf for DRAM_BASE + i * 4 KiB with \perm, for the 512 pages of 2 MiB.
.macro IDMAP_L0 l0, perm
  la   a4, \l0
  li   a5, (DRAM_BASE >> 12) << 10
  li   a6, 512
  li   t1, \perm
1:
  or   t0, a5, t1
  sd   t0, 0(a4)
  addi a4, a4, 8
  li   t0, 1 << 10
  add  a5, a5, t0
  addi a6, a6, -1
  bnez a6, 1b
.endm

# \tbl[\idx] = pointer to \next.
.macro LINK tbl, idx, next
  la   t0, \next
  srli t0, t0, 12
  slli t0, t0, 10
  ori  t0, t0, PTE_V
  la   t1, \tbl
  sd   t0, ((\idx) * 8)(t1)
.endm

# Load one word in each of \n pages starting at \buf.
.macro TOUCH buf, n
  la   t0, \buf
  li   t1, \n
1:
  ld   zero, 0(t0)
  li   t2, PAGE
  add  t0, t0, t2
  addi t1, t1, -1
  bnez t1, 1b
.endm

RVTEST_RV64M
RVTEST_CODE_BEGIN

  li   TESTNUM, 1
  csrw medeleg, zero
  li   t0, (1 << CAUSE_VS_ECALL)
  csrs medeleg, t0
  la   t0, stvec_handler
  csrw stvec, t0

  IDMAP_L0 g_l0, G_LEAF
  LINK g_l1, ((DRAM_BASE >> 21) & 0x1ff), g_l0
  LINK g_root, (DRAM_BASE >> 30), g_l1
  IDMAP_L0 s_l0, S_LEAF
  LINK s_l1, ((DRAM_BASE >> 21) & 0x1ff), s_l0
  LINK s_root, ((DRAM_BASE >> 30) & 0x1ff), s_l1

  la   t0, g_root
  srli t0, t0, 12
  li   t1, HGATP_SV39X4
  or   t0, t0, t1
  csrw CSR_HGATP_NUM, t0
  la   t0, s_root
  srli t0, t0, 12
  li   t1, SATP_MODE_SV39 << 60
  or   t0, t0, t1
  csrw satp, t0
  sfence.vma
  hfence.gvma

  li   t0, HTIMECTL_HFRZ
  csrw CSR_HTIMECTL_NUM, t0
  ENTER_MODE(MODE_VS)

  # Guest (G-stage translated): touch its pages, exit, touch them again.
  TOUCH guest_pages, GUEST_PAGES
  li   TESTNUM, 2
  ecall
  li   TESTNUM, 3
  TOUCH guest_pages, GUEST_PAGES

  EXIT_TO_M
  csrw CSR_HTIMECTL_NUM, zero
  csrw satp, zero
  csrw CSR_HGATP_NUM, zero

  j pass

  TEST_PASSFAIL

  # HS exit handler (frozen, Sv39 translated): touch the hypervisor's pages.
  .align 2
stvec_handler:
  csrr t5, scause
  li   t6, CAUSE_VS_ECALL
  bne  t5, t6, fail
  TOUCH hv_pages, HV_PAGES
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
s_root:  .fill 512, 8, 0
s_l1:    .fill 512, 8, 0
s_l0:    .fill 512, 8, 0
guest_pages:
  .fill GUEST_PAGES * PAGE / 8, 8, 0
hv_pages:
  .fill HV_PAGES * PAGE / 8, 8, 0
RVTEST_DATA_END
