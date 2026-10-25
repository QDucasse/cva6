# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden freeze, scratch structures. The HS handler runs with Sv39 (identity map of the
# first 2 MiB of DRAM, 4 KiB pages); the guest runs with G-stage and VS-stage translation off.
# The guest reads its buffer, then exits twice to HS with HFRZ armed.
#
# First exit (frozen), on the hypervisor's own pages, which no one loaded before:
#   - loads a line twice: the first fills the data-cache scratch, the second hits it;
#   - stores to it and loads it back: a store hit updates the scratch line;
#   - alternates two lines 4 KiB apart (same index): they evict each other in the scratch way;
#   - amoadd on a scratch line, then reloads it: the refill sees the result;
#   - LR/SC on a scratch line: the SC's value is seen;
#   - loads one word in each of HV_PAGES pages, twice: more pages than TLB scratch entries;
#   - runs a block of straight-line code twice: the second run doesn't miss;
#   - stores to a guest line, which the guest then reads.
# Second exit (frozen): times a loop over the guest's (warm) buffer, writes HFRZ=0 and at once
# loads an uncached line (its fill may still be in flight when the freeze ends, and must then be
# killed), then times the same loop unfrozen.
#
# With -DSCRATCH_TIMING (cv64a6_imafdch_sv39_htime only), the cycle counts are checked too: a
# scratch hit is faster than the miss before it, the second run of the code block takes less than
# the first, and the frozen loop takes at most twice the unfrozen one. The noscratch config,
# Spike and QEMU run the test without them: values only. (Spike has no htimectl: the M handler
# skips the CSR accesses, and the test runs without any freeze.) The testbench freeze monitor
# checks the frozen state and the scratch wipe.
#
# Expected windows: xret (first exit), hfrz0 (second exit).

#include "htime_macros.h"

#define CAUSE_VS_ECALL  10
#define MODE_VS         (MSTATUS_MPP_S | MSTATUS_MPV)
#define PAGE            4096
#define LINE            16          // one load per 16 bytes: every line, whatever its size
#define HV_PAGES        6
#define HV_MAGIC        0x5a5a0000
#define LINE_OFF        64          // the line used in each page, away from the page magic
#define STORE_VAL       0x1122334455667788
#define AMO_ADD         5
#define SC_VAL          0x77
#define GUEST_SIZE      1024
#define GUEST_MAGIC     0x0123456789abcdef
#define GUARD_PASSES    4
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

# Fail unless the word at \off(\base) is \val (clobbers t3, t4).
.macro CHECK_LD base, off, val
  ld   t3, \off(\base)
  li   t4, \val
  bne  t3, t4, fail
.endm

# Fail unless hv_pages[i * PAGE] == HV_MAGIC + i for the HV_PAGES pages.
.macro CHECK_PAGES
  la   t0, hv_pages
  li   t1, HV_PAGES
  li   t2, HV_MAGIC
1:
  ld   t3, 0(t0)
  bne  t3, t2, fail
  li   t4, PAGE
  add  t0, t0, t4
  addi t2, t2, 1
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
  li   t0, -1
  csrw mcounteren, t0

  # Pages: hv_pages[i * PAGE] = HV_MAGIC + i, and the line at LINE_OFF of pages 0 and 1 holds
  # its page number. Stores don't allocate in the write-through data cache, so none of this is
  # cached before the exit.
  la   t0, hv_pages
  li   t1, HV_PAGES
  li   t2, HV_MAGIC
  li   t3, 0
1:
  sd   t2, 0(t0)
  sd   t3, LINE_OFF(t0)
  li   t4, PAGE
  add  t0, t0, t4
  addi t2, t2, 1
  addi t3, t3, 1
  addi t1, t1, -1
  bnez t1, 1b

  IDMAP_L0 s_l0, S_LEAF
  LINK s_l1, ((DRAM_BASE >> 21) & 0x1ff), s_l0
  LINK s_root, ((DRAM_BASE >> 30) & 0x1ff), s_l1
  la   t0, s_root
  srli t0, t0, 12
  li   t1, SATP_MODE_SV39 << 60
  or   t0, t0, t1
  csrw satp, t0
  sfence.vma

  li   t0, HTIMECTL_HFRZ
  csrw CSR_HTIMECTL_NUM, t0
  ENTER_MODE(MODE_VS)

  # Guest: bring its buffer into the cache, exit twice, then see the handler's store.
  la   t0, guest_buf
  li   t1, GUEST_SIZE / LINE
1:
  ld   zero, 0(t0)
  addi t0, t0, LINE
  addi t1, t1, -1
  bnez t1, 1b
  li   TESTNUM, 2
  ecall
  li   TESTNUM, 3
  la   t0, guest_buf
  CHECK_LD t0, 8, GUEST_MAGIC
  li   TESTNUM, 4
  ecall
  li   TESTNUM, 5

  EXIT_TO_M
  csrw CSR_HTIMECTL_NUM, zero
  csrw satp, zero

  j pass

  TEST_PASSFAIL

  # HS exit handler (Sv39 translated): s11 counts the exits.
  .align 2
stvec_handler:
  csrr t5, scause
  li   t6, CAUSE_VS_ECALL
  bne  t5, t6, fail
  bnez s11, second_exit

  # Data cache: a line loaded twice (the second load hits the scratch)
  li   TESTNUM, 10
  la   s0, hv_pages + LINE_OFF
  ld   zero, -LINE_OFF(s0)          # another line of the page: the timed loads don't walk
  rdcycle a0
  ld   t3, 0(s0)
  rdcycle a1
  ld   t4, 0(s0)
  rdcycle a2
  bnez t3, fail
  bnez t4, fail
#ifdef SCRATCH_TIMING
  sub  a1, a1, a0
  sub  a2, a2, a0
  sub  a2, a2, a1
  bgeu a2, a1, fail
#endif

  # Store hit on the scratch line
  li   TESTNUM, 11
  li   t1, STORE_VAL
  sd   t1, 8(s0)
  CHECK_LD s0, 8, STORE_VAL

  # Two lines with the same index, alternated
  li   TESTNUM, 12
  li   t0, PAGE
  add  s1, s0, t0
  li   t1, 3
1:
  CHECK_LD s0, 0, 0
  CHECK_LD s1, 0, 1
  addi t1, t1, -1
  bnez t1, 1b

  # AMO on a scratch line: the refill sees its result
  li   TESTNUM, 13
  ld   zero, 0(s0)
  li   t1, AMO_ADD
  amoadd.d t3, t1, (s0)
  bnez t3, fail
  CHECK_LD s0, 0, AMO_ADD

  # LR/SC on a scratch line
  li   TESTNUM, 14
  li   t1, SC_VAL
1:
  lr.d t3, (s0)
  li   t4, AMO_ADD
  bne  t3, t4, fail
  sc.d t4, t1, (s0)
  bnez t4, 1b
  CHECK_LD s0, 0, SC_VAL
  CHECK_LD s0, 8, STORE_VAL

  # TLB: more pages than scratch entries, twice
  li   TESTNUM, 15
  CHECK_PAGES
  CHECK_PAGES

  # Instruction cache: the second run of a cold code block doesn't miss
  li   TESTNUM, 16
  rdcycle s2
  jal  ra, code_block
  rdcycle s3
  jal  ra, code_block
  rdcycle s4
#ifdef SCRATCH_TIMING
  sub  s4, s4, s3
  sub  s3, s3, s2
  bgeu s4, s3, fail
#endif

  # Store hit on a guest line, read by the guest after the return
  li   TESTNUM, 17
  la   t0, guest_buf
  li   t1, GUEST_MAGIC
  sd   t1, 8(t0)

  li   s11, 1
  j    handler_ret

second_exit:
  # The loop over the guest's buffer, frozen then unfrozen
  li   TESTNUM, 20
  jal  ra, guard_loop
  mv   s5, a0
  # End the freeze with a load right behind: if its fill comes after the end, it's killed
  la   s0, hv_pages + 2 * PAGE + LINE_OFF
  csrw CSR_HTIMECTL_NUM, zero
  ld   t3, 0(s0)
  li   t4, 2
  bne  t3, t4, fail
  CHECK_LD s0, 0, 2
  jal  ra, guard_loop
  mv   s6, a0
#ifdef SCRATCH_TIMING
  slli s6, s6, 1
  bgtu s5, s6, fail
#endif

handler_ret:
  csrr t6, sepc
  addi t6, t6, 4
  csrw sepc, t6
  sret

  # Loads GUARD_PASSES times every line of the guest's buffer. Returns the cycles in a0.
  .align 6
guard_loop:
  rdcycle a0
  li   t2, GUARD_PASSES
1:
  la   t0, guest_buf
  li   t1, GUEST_SIZE / LINE
2:
  ld   zero, 0(t0)
  addi t0, t0, LINE
  addi t1, t1, -1
  bnez t1, 2b
  addi t2, t2, -1
  bnez t2, 1b
  rdcycle t0
  sub  a0, t0, a0
  ret

  # 64 lines of straight-line code, never run before the first exit.
  .align 6
code_block:
  .option push
  .option norvc
  .rept 256
  addi zero, zero, 0
  .endr
  .option pop
  ret

  HTIME_MTVEC_HANDLER

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
  .align 12
s_root:  .fill 512, 8, 0
s_l1:    .fill 512, 8, 0
s_l0:    .fill 512, 8, 0
guest_buf:
  .fill GUEST_SIZE / 8, 8, 0
  .align 12
hv_pages:
  .fill HV_PAGES * PAGE / 8, 8, 0
RVTEST_DATA_END
