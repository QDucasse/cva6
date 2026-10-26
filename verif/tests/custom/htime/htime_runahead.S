# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden-time: the resume hold. After a hidden exit, the guest's first commit waits until the
# pipeline holds as many instructions ahead of commit as it did at the exit, with fetch at the
# same address. The guest's commits then keep their native timing, wherever in a loop the exit
# landed; this test checks that.
#
# The guest runs a gap loop (one cycle read per iteration, one step byte stored), once
# 4-byte aligned and once 2-byte aligned, as on the board, where every taken branch also costs
# a half fetch, then a branch-free step kernel (case 3). Interrupt 24 stops it every Q guest ticks plus a jitter, so exits land all over
# the loop; HS records where (sepc) and returns at once, hidden. Checks, per loop:
#   - ROUNDS exits were taken, all inside the loop, at MIN_POS or more of its 9 instructions,
#     including the sub right after the read (it stalls on the read's value);
#   - every step after the first WARM equals the first of them: no exit shows.
# The first exit comes FIRST ticks in: in the loop's first ~100 iterations the pipeline's lead is
# still settling (7-10 instructions, then 4-6), and the hold does not restore that transient
# exactly (Verilator: up to 3 cycles fast).
# Without the hold this fails on the 2-byte-aligned loop (board: +1 to +3 cycles, depending on
# the instruction the exit landed on).
#
# CVA6 only: QEMU has no pipeline, and its steps follow host time.
#
# Registers, guest loop:
#   s0 : previous read    s1 : iteration    s2 : last iteration    s3 : 255
#   t0 : current read     t1 : step         t3 : next step byte
# Registers, HS handler (shares the register file with the guest):
#   a1-a3 : scratch    s4 : exits taken    s5 : positions hit (bit i: instruction i of the loop)
#   s6 : loop start     s7 : current deadline (guest ticks)    s8 : loop length (bytes)

#include "htime_macros.h"

#define MODE_VS   (MSTATUS_MPP_S | MSTATUS_MPV)

#define COUNTEREN_CY    (1 << 0)
#define DELTA           0x0000100000000000
#define IRQ_HVTI_CAUSE  ((1 << 63) | IRQ_HVTI)

#define ITERS           4096
#define WARM            4
#define Q               37
#define FIRST           512     /* first deadline (ticks): past the loop's start-up transient */
#define ROUNDS          128
#define LOOP_INSTRS     9       /* gap loop */
#define PILL_INSTRS     11      /* step kernel */
#define MIN_POS         5

# The gap loop, LOOP_INSTRS instructions from 10: (s6), steps into buf. No compressed
# instructions from here on, so the loop keeps the alignment the macro starts at.
.macro GAP_LOOP buf
  .option push
  .option norvc
  la   t3, \buf
  li   s2, ITERS
  li   s3, 255
  li   s1, 0
  la   s6, 10f
  li   s8, LOOP_INSTRS * 4
  csrr s0, cycle
10:
  addi s1, s1, 1
  csrr t0, cycle
  sub  t1, t0, s0
  mv   s0, t0
  bgeu t1, s3, 2f
  sb   t1, 0(t3)
1:
  addi t3, t3, 1
  beq  s1, s2, 3f
  j    10b
2:
  sb   s3, 0(t3)
  j    1b
3:
  .option pop
.endm

# The step kernel, PILL_INSTRS instructions from 10: (s6): one cycle read per iteration, the
# step saturated at 255 without branches and stored. A branch-free chain where most
# instructions wait for the one before.
.macro PILL_LOOP buf
  .option push
  .option norvc
  la   s1, \buf
  li   s2, ITERS
  add  s2, s2, s1
  li   s3, 255
  la   s6, 10f
  li   s8, PILL_INSTRS * 4
  csrr s0, cycle
10:
  csrr t0, cycle
  sub  t3, t0, s0
  mv   s0, t0
  sltu t4, s3, t3
  neg  t4, t4
  xor  t5, t3, s3
  and  t5, t5, t4
  xor  t3, t3, t5
  sb   t3, 0(s1)
  addi s1, s1, 1
  bne  s1, s2, 10b
  .option pop
.endm

# From M: first deadline FIRST guest ticks from the guest's now, no exit taken or position hit
# yet. clock is time, or hexit_time after a VS loop: the ebreak back to M was a hidden exit, so
# the guest clock has stood still since.
.macro ARM clock
  li   s4, 0
  li   s5, 0
  csrr s7, \clock
  li   t0, DELTA + FIRST
  add  s7, s7, t0
  csrr t0, CSR_HHIDDEN_TIME_NUM
  sub  s7, s7, t0
  csrw CSR_HVTIMECMP_NUM, s7
.endm

# From M, after a loop: the exits and positions, then every step from WARM on equals the first.
# -DRUNAHEAD_NOCHECK skips the checks, so every loop runs (for tracing all of them).
.macro CHECK buf, after_read
#ifndef RUNAHEAD_NOCHECK
  li   t0, ROUNDS
  bne  s4, t0, fail
  li   t0, 0
  mv   t1, s5
4:
  andi t2, t1, 1
  add  t0, t0, t2
  srli t1, t1, 1
  bnez t1, 4b
  li   t1, MIN_POS
  bltu t0, t1, fail
  # The sub right after the read, which waits for its value: an interrupt there must trap when
  # the sub would have committed, not before (the RAW stall it carries).
  andi t0, s5, 1 << \after_read
  beqz t0, fail
  la   t0, \buf + WARM
  la   t1, \buf + ITERS
  lbu  t2, 0(t0)
5:
  lbu  t3, 0(t0)
  bne  t3, t2, fail
  addi t0, t0, 1
  bltu t0, t1, 5b
#endif
.endm

RVTEST_RV64M
RVTEST_CODE_BEGIN

  csrw medeleg, zero
  csrw mideleg, zero
  csrw hideleg, zero
  csrw hvip, zero
  csrw mie, zero
  la   t0, stvec_handler
  csrw stvec, t0
  li   t0, COUNTEREN_TM | COUNTEREN_CY
  csrw mcounteren, t0
  csrw hcounteren, t0
  csrw scounteren, t0
  li   t0, DELTA
  csrw CSR_HTIMEDELTA_NUM, t0
  li   t0, HTIMECTL_HHAE
  csrw CSR_HTIMECTL_NUM, t0
  li   t0, MIP_HVTIP
  csrs mie, t0

  # 1. 4-byte-aligned loop.
  li   TESTNUM, 1
  ARM time
  ENTER_MODE(MODE_VS)
  .balign 4
  GAP_LOOP steps_aligned
  EXIT_TO_M
  CHECK steps_aligned, 2

  # 2. 2-byte-aligned loop: a compressed nop in front of it.
  li   TESTNUM, 2
  ARM CSR_HEXIT_TIME_NUM
  ENTER_MODE(MODE_VS)
  .balign 4
  .option push
  .option rvc
  c.nop
  .option pop
  GAP_LOOP steps_unaligned
  EXIT_TO_M
  CHECK steps_unaligned, 2

  # 3. The pill's own kernel, 4-byte aligned as in the pill.
  li   TESTNUM, 3
  ARM  CSR_HEXIT_TIME_NUM
  ENTER_MODE(MODE_VS)
  .balign 4
  PILL_LOOP steps_pill
  EXIT_TO_M
  CHECK steps_pill, 1

  j pass

  TEST_PASSFAIL

  # HS: interrupt 24 from the guest loop. Record where it landed, re-arm, return at once.
  .align 2
stvec_handler:
  csrr a1, scause
  li   a2, IRQ_HVTI_CAUSE
  bne  a1, a2, fail
  csrr a1, sepc
  sub  a1, a1, s6
  bgeu a1, s8, fail
  srli a1, a1, 2
  li   a2, 1
  sll  a2, a2, a1
  or   s5, s5, a2
  addi s4, s4, 1
  li   a2, ROUNDS
  bltu s4, a2, 1f
  li   a2, -1
  csrw CSR_HVTIMECMP_NUM, a2
  sret
  # Next deadline: Q guest ticks later, plus 0-15 so the phase walks across the loop.
1:
  andi a3, s4, 15
  addi s7, s7, Q
  add  s7, s7, a3
  csrw CSR_HVTIMECMP_NUM, s7
  sret

  # M: ebreak -> return to M after it; anything else fails.
  .align 2
  .global mtvec_handler
mtvec_handler:
  csrr t5, mcause
  li   t6, CAUSE_BREAKPOINT
  bne  t5, t6, fail
  li   t6, MSTATUS_MPV
  csrc mstatus, t6
  li   t6, MSTATUS_MPP
  csrs mstatus, t6
  csrr t6, mepc
  addi t6, t6, 4
  csrw mepc, t6
  mret

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA

steps_aligned:
  .fill ITERS, 1, 0
steps_unaligned:
  .fill ITERS, 1, 0
steps_pill:
  .fill ITERS, 1, 0

RVTEST_DATA_END
