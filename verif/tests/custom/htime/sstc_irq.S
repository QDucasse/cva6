# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden-time: Sstc timer interrupts. STIP is taken in HS, VSTIP in VS, a guest
# WFI wakes on VSTIP, and VSTIP stays clear during a hidden (HHAE=1) exit.
#
# The last case is the §8.1 hazard: a guest WFI trapped to HS (hstatus.VTW) with
# HHAE=1 never sees its timer fire while HS waits. HS polls hip.VSTIP for
# SPIN_CYCLES instead of executing WFI, so the test does not hang.
#
# Registers:
#   s6 : time read by the interrupt handler (HS: host time, VS: guest time)
#   s7 : set by the HS handler when it sees hip.VSTIP while handling a trapped WFI
#   s8 : set by the interrupt handlers

#include "htime_macros.h"

#define MODE_HS   MSTATUS_MPP_S
#define MODE_VS   (MSTATUS_MPP_S | MSTATUS_MPV)

#define COUNTEREN_CY  (1 << 0)
#define DELTA         0x0000100000000000
#ifndef SPIN_CYCLES
#define SPIN_CYCLES   20000
#endif
#define SSTATUS_SIE_BIT 2
#define IRQ_TIMER_CAUSE ((1 << 63) | 5)

# Deadlines relative to the current time (ticks).
#ifdef HTIME_QEMU
#define NEAR          1000
#define FAR           10000
#define TIMEOUT       40000
#else
#define NEAR          100
#define FAR           1000
#define TIMEOUT       4000
#endif

# In HS or VS: arm stimecmp at time + dt, enable SIE, wait for the interrupt handler.
#   s2 = time when armed
#define TAKE_TIMER_IRQ(dt)                                              \
  li   s8, 0;                                                           \
  li   t0, MIP_STIP;                                                    \
  csrs sie, t0;                                                         \
  csrr s2, time;                                                        \
  li   t1, dt;                                                          \
  add  t1, s2, t1;                                                      \
  csrw CSR_STIMECMP_NUM, t1;                                            \
  csrsi sstatus, SSTATUS_SIE_BIT;                                       \
1:                                                                      \
  bnez s8, 2f;                                                          \
  csrr t0, time;                                                        \
  sub  t0, t0, s2;                                                      \
  li   t1, TIMEOUT;                                                     \
  bltu t0, t1, 1b;                                                      \
  j    fail;                                                            \
2:                                                                      \
  csrci sstatus, SSTATUS_SIE_BIT;                                       \
  li   t0, MIP_STIP;                                                    \
  csrc sie, t0;                                                         \
  sub  t0, s6, s2;                                                      \
  li   t1, dt;                                                          \
  bltu t0, t1, fail

# From M: the guest arms its timer at time + FAR and executes WFI, which traps to HS
# (hstatus.VTW). HS polls hip.VSTIP (result in s7) and returns.
#   s2 = guest time when armed, s4 = guest sip just after the return
#   s3 = guest time when VSTIP is finally seen
#   s5 = guest time at the WFI
#define TRAPPED_WFI(hhae)                                               \
  li   t0, hhae;                                                        \
  csrw CSR_HTIMECTL_NUM, t0;                                            \
  li   t0, HSTATUS_VTW_BIT;                                             \
  csrs hstatus, t0;                                                     \
  li   s7, 0;                                                           \
  ENTER_MODE(MODE_VS);                                                  \
  li   t0, MIP_STIP;                                                    \
  csrs sie, t0;                                                         \
  csrr s2, time;                                                        \
  li   t1, FAR;                                                         \
  add  t1, s2, t1;                                                      \
  csrw CSR_STIMECMP_NUM, t1;                                            \
  csrr s5, time;                                                        \
  .option push;                                                         \
  .option norvc;                                                        \
  wfi;                                                                  \
  .option pop;                                                          \
  csrr s4, sip;                                                         \
1:                                                                      \
  csrr t0, sip;                                                         \
  andi t0, t0, MIP_STIP;                                                \
  bnez t0, 2f;                                                          \
  csrr t0, time;                                                        \
  sub  t0, t0, s2;                                                      \
  li   t1, TIMEOUT;                                                     \
  bltu t0, t1, 1b;                                                      \
  j    fail;                                                            \
2:                                                                      \
  csrr s3, time;                                                        \
  li   t0, -1;                                                          \
  csrw CSR_STIMECMP_NUM, t0;                                            \
  li   t0, MIP_STIP;                                                    \
  csrc sie, t0;                                                         \
  EXIT_TO_M;                                                            \
  li   t0, HSTATUS_VTW_BIT;                                             \
  csrc hstatus, t0;                                                     \
  csrw CSR_HTIMECTL_NUM, zero

RVTEST_RV64M
RVTEST_CODE_BEGIN

  # ebreak to M; virtual instruction (trapped WFI) to HS; STIP to HS; VSTIP to VS.
  csrw medeleg, zero
  li   t0, (1 << CAUSE_VIRTUAL_INSTRUCTION)
  csrs medeleg, t0
  li   t0, MIP_STIP
  csrw mideleg, t0
  li   t0, MIP_VSTIP_BIT
  csrw hideleg, t0
  csrw hvip, zero
  la   t0, stvec_handler
  csrw stvec, t0
  la   t0, vstvec_handler
  csrw vstvec, t0
  li   t0, COUNTEREN_TM | COUNTEREN_CY
  csrw mcounteren, t0
  csrw hcounteren, t0
  csrw scounteren, t0
  li   t0, ENVCFG_STCE
  csrs menvcfg, t0
  csrs henvcfg, t0
  li   t0, DELTA
  csrw CSR_HTIMEDELTA_NUM, t0
  csrw CSR_HTIMECTL_NUM, zero

  # 1. HS: stimecmp raises STIP, taken in HS no earlier than the deadline.
  li   TESTNUM, 1
  ENTER_MODE(MODE_HS)
  TAKE_TIMER_IRQ(NEAR)
  EXIT_TO_M

  # 2. VS: stimecmp (= vstimecmp) raises VSTIP, taken in VS no earlier than the
  #    deadline in guest time.
  li   TESTNUM, 2
  ENTER_MODE(MODE_VS)
  TAKE_TIMER_IRQ(NEAR)
  EXIT_TO_M
  csrr t0, CSR_VSTIMECMP_NUM
  li   t1, -1
  bne  t0, t1, fail

  # 3. VS: a guest WFI (not trapped) wakes on VSTIP, with interrupts disabled.
  li   TESTNUM, 3
  ENTER_MODE(MODE_VS)
  li   t0, MIP_STIP
  csrs sie, t0
  csrr s2, time
  li   t1, FAR
  add  t1, s2, t1
  csrw CSR_STIMECMP_NUM, t1
  wfi
  csrr s3, time
  csrr s4, sip
  li   t0, -1
  csrw CSR_STIMECMP_NUM, t0
  li   t0, MIP_STIP
  csrc sie, t0
  EXIT_TO_M
  sub  t0, s3, s2
  li   t1, FAR
  bltu t0, t1, fail
  andi t0, s4, MIP_STIP
  beqz t0, fail

  # 4. Trapped WFI, HHAE=0: guest time runs while HS waits, HS sees VSTIP.
  li   TESTNUM, 4
  TRAPPED_WFI(0)
  beqz s7, fail
  andi t0, s4, MIP_STIP
  beqz t0, fail

  # 5. Trapped WFI, HHAE=1: guest time is frozen while HS waits, so HS never sees
  #    VSTIP (the §8.1 hang) and the guest finds it clear on return. The guest then
  #    waits the rest of its deadline in its own time.
  li   TESTNUM, 5
  TRAPPED_WFI(HTIMECTL_HHAE)
  bnez s7, fail
  andi t0, s4, MIP_STIP
  bnez t0, fail
  sub  t0, s3, s2
  li   t1, FAR
  bltu t0, t1, fail

  j pass

  TEST_PASSFAIL

  # HS: STIP -> record and disarm; trapped guest WFI -> poll hip.VSTIP, skip the WFI.
  .align 2
stvec_handler:
  csrr t5, scause
  li   t6, IRQ_TIMER_CAUSE
  bne  t5, t6, 1f
  csrr s6, time
  li   s8, 1
  li   t6, -1
  csrw CSR_STIMECMP_NUM, t6
  sret
1:
  li   t6, CAUSE_VIRTUAL_INSTRUCTION
  bne  t5, t6, fail
  csrr t5, cycle
2:
  csrr t6, hip
  andi t6, t6, MIP_VSTIP_BIT
  bnez t6, 3f
  csrr t6, cycle
  sub  t6, t6, t5
  li   s11, SPIN_CYCLES
  bltu t6, s11, 2b
  j    4f
3:
  li   s7, 1
4:
  csrr t6, sepc
  addi t6, t6, 4
  csrw sepc, t6
  sret

  # VS: VSTIP (seen as STIP) -> record and disarm.
  .align 2
vstvec_handler:
  csrr t5, scause
  li   t6, IRQ_TIMER_CAUSE
  bne  t5, t6, fail
  csrr s6, time
  li   s8, 1
  li   t6, -1
  csrw CSR_STIMECMP_NUM, t6
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
RVTEST_DATA_END
