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
# a half fetch. Interrupt 24 stops it every Q guest ticks plus a jitter, so exits land all over
# the loop; HS records where (sepc) and returns at once, hidden. Checks, per loop:
#   - ROUNDS exits were taken, all inside the loop, at MIN_POS or more of its instructions;
#   - every step after the first WARM equals the first of them: no exit shows.
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
#   s6 : loop start     s7 : current deadline (guest ticks)

#include "htime_macros.h"

#define MODE_VS   (MSTATUS_MPP_S | MSTATUS_MPV)

#define COUNTEREN_CY    (1 << 0)
#define DELTA           0x0000100000000000
#define IRQ_HVTI_CAUSE  ((1 << 63) | IRQ_HVTI)

#define ITERS           2048
#define WARM            4
#define Q               37
#define ROUNDS          64
#define LOOP_INSTRS     9
#define MIN_POS         6

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

# From M: first deadline Q guest ticks from now, no exit taken or position hit yet.
.macro ARM
  li   s4, 0
  li   s5, 0
  csrr s7, time
  li   t0, DELTA + Q
  add  s7, s7, t0
  csrr t0, CSR_HHIDDEN_TIME_NUM
  sub  s7, s7, t0
  csrw CSR_HVTIMECMP_NUM, s7
.endm

# From M, after a loop: the exits and positions, then every step from WARM on equals the first.
.macro CHECK buf
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
  la   t0, \buf + WARM
  la   t1, \buf + ITERS
  lbu  t2, 0(t0)
5:
  lbu  t3, 0(t0)
  bne  t3, t2, fail
  addi t0, t0, 1
  bltu t0, t1, 5b
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
  ARM
  ENTER_MODE(MODE_VS)
  .balign 4
  GAP_LOOP steps_aligned
  EXIT_TO_M
  CHECK steps_aligned

  # 2. 2-byte-aligned loop: a compressed nop in front of it.
  li   TESTNUM, 2
  ARM
  ENTER_MODE(MODE_VS)
  .balign 4
  .option push
  .option rvc
  c.nop
  .option pop
  GAP_LOOP steps_unaligned
  EXIT_TO_M
  CHECK steps_unaligned

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
  li   a2, LOOP_INSTRS * 4
  bgeu a1, a2, fail
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
  # Next deadline: Q guest ticks later, plus 0-3 so the phase walks across the loop.
1:
  andi a3, s4, 3
  addi s7, s7, Q
  add  s7, s7, a3
  csrw CSR_HVTIMECMP_NUM, s7
  sret

  # M: ebreak -> return to M after it; anything else fails.
  .align 2
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

RVTEST_DATA_END
