# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden-time: introspection loop. HS gives the guest a quantum of Q ticks of guest time
# with hvtimecmp, the guest works (fills a buffer, counts iterations), interrupt 24
# stops it, HS inspects the guest buffer, spins SPIN_CYCLES and resumes it, ROUNDS times.
# Every exit is hidden (HHAE=1) except round VIS_ROUND, which is visible (HHAE=0).
#
# The HS handler shares the register file with the guest: it reads and resets the
# guest's largest time/cycle step and checks the buffer against the guest's counter.
# Checks, once the guest is done:
#   - each interrupt is taken within DL ticks of its deadline;
#   - after a hidden exit: the next deadline is Q guest ticks later, the guest gets a
#     full quantum of work, its largest time/cycle step stays within the bound of the
#     no-exit baseline, and hhidden_time grew by at least the spin;
#   - after the visible exit: the guest sees the spin and hhidden_time does not move;
#   - hhidden_cycle and hhidden_time agree (CVA6 only).
#
# Registers, guest:
#   a0 : iteration counter          t0, t1 : previous time, cycle
#   t2, t3 : current time, cycle    t4 : work_buf    s2 : scratch
#   s5, s6 : largest time, cycle step since the last interrupt (reset by HS)
# Registers, HS handler:
#   a1-a6 : scratch    s4 : round    s7 : current deadline    s8 : set when done

#include "htime_macros.h"

#define MODE_VS   (MSTATUS_MPP_S | MSTATUS_MPV)

#define COUNTEREN_CY    (1 << 0)
#define DELTA           0x0000100000000000
#ifndef MTIME_DIV
#define MTIME_DIV       4
#endif
#ifndef SPIN_CYCLES
#define SPIN_CYCLES     20000
#endif
#define HSTATUS_SPV     (1 << 7)
#define IRQ_HVTI_CAUSE  ((1 << 63) | IRQ_HVTI)

#define ROUNDS          8
#define VIS_ROUND       2
#define BUF_WORDS       64
#define BUF_MASK        (BUF_WORDS - 1)
#define BUF_BYTES       (BUF_WORDS * 8)

# Quantum (guest ticks), guest-charged bound per exit (ticks, cycles), bound on the
# delay from deadline to interrupt (ticks; QEMU delivers it from a host timer).
#ifdef HTIME_QEMU
#define Q               50000
#define B               BOUND_TICKS
#define CB              BOUND_CYCLES
#define DL              (10 * BOUND_TICKS)
#else
#define Q               500
#define B               8
#define CB              (2 * B)
#define DL              B
#endif

# One record per round, written by the HS handler.
#define REC_GAP_T       0     /* largest guest time step in the quantum before it */
#define REC_GAP_C       8     /* same for cycle */
#define REC_GEXIT       16    /* guest time at the exit (frozen value) */
#define REC_DEADLINE    24    /* hvtimecmp that fired */
#define REC_HIDDEN      32    /* hhidden_time before this exit is accumulated */
#define REC_ITER        40    /* guest counter read from memory */
#define REC_SIZE        64

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
  csrw CSR_HTIMECTL_NUM, zero
  csrw CSR_HEXIT_TIME_NUM, zero
  csrw CSR_HHIDDEN_TIME_NUM, zero
  csrw CSR_HEXIT_CYCLE_NUM, zero
  csrw CSR_HHIDDEN_CYCLE_NUM, zero
  li   t0, MIP_HVTIP
  csrs mie, t0

  # 1. Run: first deadline Q ticks of guest time from now (hhidden_time = 0). Inspection
  #    failures in the HS handler report this number.
  li   TESTNUM, 1
  li   s4, 0
  li   s8, 0
  li   s5, 0
  li   s6, 0
  csrr s7, time
  li   t0, DELTA + Q
  add  s7, s7, t0
  csrw CSR_HVTIMECMP_NUM, s7

  ENTER_MODE(MODE_VS)
  li   a0, 0
  la   t4, work_buf
  csrr t0, time
  csrr t1, cycle
1:
  csrr t2, time
  csrr t3, cycle
  sub  s2, t2, t0
  bgeu s5, s2, 2f
  mv   s5, s2
2:
  sub  s2, t3, t1
  bgeu s6, s2, 3f
  mv   s6, s2
3:
  mv   t0, t2
  mv   t1, t3
  addi a0, a0, 1
  andi s2, a0, BUF_MASK
  slli s2, s2, 3
  add  s2, s2, t4
  sd   a0, 0(s2)
  sd   a0, BUF_BYTES(t4)
  beqz s8, 1b
  EXIT_TO_M

  li   t0, ROUNDS
  bne  s4, t0, fail

  # 2. Every interrupt is taken within DL ticks of its deadline.
  li   TESTNUM, 2
  la   a1, rounds
  li   s1, 0
1:
  ld   t0, REC_GEXIT(a1)
  ld   t1, REC_DEADLINE(a1)
  sub  t0, t0, t1
  li   t1, DL + 1
  bgeu t0, t1, fail
  addi a1, a1, REC_SIZE
  addi s1, s1, 1
  li   t0, ROUNDS
  bne  s1, t0, 1b

  # 3. Each exit, seen from the quantum after it (record i covers exit i-1). Baseline:
  #    record 0 (no exit before it). Minimum work: half of the first quantum's.
  li   TESTNUM, 3
  la   a1, rounds
  ld   s3, REC_GAP_T(a1)
  ld   s11, REC_GAP_C(a1)
  ld   s2, REC_ITER(a1)
  srli s2, s2, 1
  addi a1, a1, REC_SIZE
  li   s1, 1
1:
  ld   t0, REC_ITER(a1)
  ld   t1, REC_ITER - REC_SIZE(a1)
  sub  t0, t0, t1
  bltu t0, s2, fail
  ld   t0, REC_HIDDEN(a1)
  ld   t1, REC_HIDDEN - REC_SIZE(a1)
  sub  t0, t0, t1
  ld   t2, REC_GAP_T(a1)
  ld   t3, REC_GAP_C(a1)
  li   t4, VIS_ROUND + 1
  bne  s1, t4, 2f

  # Visible: nothing accumulated, the guest saw the spin.
  bnez t0, fail
  li   t4, SPIN_CYCLES / MTIME_DIV / 2
  bltu t2, t4, fail
#ifndef HTIME_QEMU
  li   t4, SPIN_CYCLES / 2
  bltu t3, t4, fail
#endif
  j    3f

  # Hidden: the spin was accumulated, the guest's steps stay near the baseline and the
  # deadline moved by Q guest ticks.
2:
  li   t4, SPIN_CYCLES / MTIME_DIV
  bltu t0, t4, fail
  addi t4, s3, B
  bltu t4, t2, fail
  li   t4, CB
  add  t4, t4, s11
  bltu t4, t3, fail
  ld   t0, REC_GEXIT(a1)
  ld   t1, REC_GEXIT - REC_SIZE(a1)
  sub  t0, t0, t1
  li   t1, Q - DL
  bltu t0, t1, fail
  li   t1, Q + DL
  bltu t1, t0, fail
3:
  addi a1, a1, REC_SIZE
  addi s1, s1, 1
  li   t0, ROUNDS
  bne  s1, t0, 1b

  # 4. Totals: ROUNDS - 1 hidden spins; hidden cycles = MTIME_DIV x hidden ticks, within
  #    one tick per exit.
  li   TESTNUM, 4
  csrr t0, CSR_HHIDDEN_TIME_NUM
  li   t1, (ROUNDS - 1) * (SPIN_CYCLES / MTIME_DIV)
  bltu t0, t1, fail
#ifndef HTIME_QEMU
  csrr t1, CSR_HHIDDEN_CYCLE_NUM
  li   t2, MTIME_DIV
  mul  t0, t0, t2
  sub  t1, t1, t0
  li   t2, MTIME_DIV * ROUNDS
  add  t1, t1, t2
  li   t2, 2 * MTIME_DIV * ROUNDS
  bltu t2, t1, fail
#endif

  j pass

  TEST_PASSFAIL

  # HS: interrupt 24 from the guest. Record, inspect, spin, re-arm, return.
  .align 2
stvec_handler:
  csrr t5, scause
  li   t6, IRQ_HVTI_CAUSE
  bne  t5, t6, fail
  csrr t5, hstatus
  andi t5, t5, HSTATUS_SPV
  beqz t5, fail

  # Record the round; hand the guest fresh step maxima.
  slli a1, s4, 6
  la   a2, rounds
  add  a1, a1, a2
  sd   s5, REC_GAP_T(a1)
  sd   s6, REC_GAP_C(a1)
  li   s5, 0
  li   s6, 0
  csrr a2, CSR_HEXIT_TIME_NUM
  li   a3, DELTA
  add  a2, a2, a3
  csrr a3, CSR_HHIDDEN_TIME_NUM
  sub  a2, a2, a3
  sd   a2, REC_GEXIT(a1)
  sd   s7, REC_DEADLINE(a1)
  sd   a3, REC_HIDDEN(a1)

  # Inspect: the stored counter is the guest's a0, or a0 - 1 if the guest stopped
  # before storing it, and the buffer holds it at its slot. Then read the whole buffer.
  la   a2, work_buf
  ld   a3, BUF_BYTES(a2)
  sd   a3, REC_ITER(a1)
  sub  a4, a0, a3
  li   a5, 1
  bltu a5, a4, fail
  andi a4, a3, BUF_MASK
  slli a4, a4, 3
  add  a4, a4, a2
  ld   a4, 0(a4)
  bne  a4, a3, fail
  li   a4, 0
  mv   a5, a2
  addi a6, a2, BUF_BYTES
1:
  ld   t6, 0(a5)
  add  a4, a4, t6
  addi a5, a5, 8
  bltu a5, a6, 1b

  # Hide every exit but VIS_ROUND.
  li   a2, VIS_ROUND
  beq  s4, a2, 2f
  li   t6, HTIMECTL_HHAE
  csrw CSR_HTIMECTL_NUM, t6
  j    3f
2:
  csrw CSR_HTIMECTL_NUM, zero
3:
  csrr a2, cycle
4:
  csrr a3, cycle
  sub  a3, a3, a2
  li   a4, SPIN_CYCLES
  bltu a3, a4, 4b

  # Next deadline: Q guest ticks after this one if hidden; Q ticks from the live guest
  # time if visible (the old schedule has passed).
  li   a2, VIS_ROUND
  bne  s4, a2, 5f
  csrr s7, time
  li   a3, DELTA
  add  s7, s7, a3
  csrr a3, CSR_HHIDDEN_TIME_NUM
  sub  s7, s7, a3
5:
  li   a3, Q
  add  s7, s7, a3
  csrw CSR_HVTIMECMP_NUM, s7

  addi s4, s4, 1
  li   a2, ROUNDS
  bne  s4, a2, 6f
  li   s8, 1
  li   t6, -1
  csrw CSR_HVTIMECMP_NUM, t6
6:
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

  .align 3
work_buf:
  .fill BUF_WORDS + 1, 8, 0
rounds:
  .fill ROUNDS * REC_SIZE / 8, 8, 0

RVTEST_DATA_END
