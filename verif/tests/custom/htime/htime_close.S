# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden-time: the hidden window closes at the first V=1 event after the xRET, a commit or a
# trap, and hexit_charge is what the guest is told passed.
#
# Every exit is a VS ecall to HS with HHAE=1, emulated (sepc += 4). The HS handler writes
# hexit_charge = s9 before returning. Each case runs twice in VS (warm-up, then measured):
#   - the warm emulated ecall shows the guest 1 + charge cycles and 1 + charge instructions,
#     so {instret 1, cycles 2} makes it look like a nop;
#   - a clock read as the first guest instruction sees the stopped value (the bypass), one
#     cycle before a read that follows a nop;
#   - vstimecmp = guest time at the exit + 1 does not raise VSTIP before the first guest event;
#   - an interrupt injected into VS before the first guest commit closes the window at the trap:
#     the VS handler's first read sees the same as after a native VS trap;
#   - an interrupt back to HS before the first guest commit closes the window and latches the
#     new exit in the same cycle: the guest sees only the first exit's charge;
#   - hexit_charge is R/W from M and HS, denied in U and VS, and cleared at every exit latch.
#
# QEMU (-DHTIME_QEMU): there is no refill and mcycle/minstret follow host ticks, so the exact
# cycle and instret checks become bounds, and the VSTIP check is left out.

#include "htime_macros.h"

#define CSR_HEXIT_CHARGE_NUM  0x6c8

#define DELTA           0x0000100000000000
#define COUNTEREN_CY    (1 << 0)
#define COUNTEREN_IR    (1 << 2)
#define CAUSE_VS_ECALL  10
#define IRQ_HVTI_CAUSE  ((1 << 63) | IRQ_HVTI)
#define MIP_VSSIP       (1 << 2)
#define MIP_VSTIP       (1 << 6)
#define SIE_SSIE        (1 << 1)
#define SIE_STIE        (1 << 5)
#define IRQ_S_SOFT      1
#define IRQ_S_TIMER     5

#define CHARGE(ir, cy)  (((ir) << 48) | (cy))
#define CHARGE_NOP      CHARGE(1, 2)

#define MODE_HS   MSTATUS_MPP_S
#define MODE_U    MSTATUS_MPP_U
#define MODE_VS   (MSTATUS_MPP_S | MSTATUS_MPV)

# HS action on the exit, in a6.
#define ACT_NONE        0
#define ACT_INJECT_VS   1   /* hvip.VSSIP: trap to VS before the first guest commit */
#define ACT_HVTI_NOW    2   /* hvtimecmp = 0: interrupt 24 back to HS before it */
#define ACT_VSTIMER     3   /* vstimecmp = guest time at the exit + 1 */

# From M: enter VS, run the body twice (warm-up, measured), return to M.
#define IN_VS_TWICE(...)                                                \
  ENTER_MODE(MODE_VS);                                                  \
  li   s1, 2;                                                           \
88:                                                                     \
  __VA_ARGS__;                                                          \
  addi s1, s1, -1;                                                      \
  bnez s1, 88b;                                                         \
  EXIT_TO_M

# Exact on CVA6; on QEMU only bounded by BOUND_CYCLES (or BOUND_TICKS for time).
#ifdef HTIME_QEMU
#define EXPECT_EQ(reg, val)                                             \
  li   t1, BOUND_CYCLES;                                                \
  bltu t1, reg, fail
#define EXPECT_EQ_REG(reg, ref)  EXPECT_EQ(reg, 0)
#define EXPECT_TIME(reg)                                                \
  li   t1, BOUND_TICKS;                                                 \
  bltu t1, reg, fail
#else
#define EXPECT_EQ(reg, val)                                             \
  li   t1, val;                                                         \
  bne  reg, t1, fail
#define EXPECT_EQ_REG(reg, ref)                                         \
  bne  reg, ref, fail
#define EXPECT_TIME(reg)                                                \
  li   t1, 1;                                                           \
  bltu t1, reg, fail
#endif

# In the current mode, write val to hexit_charge and read it back.
#define CHECK_RW(val)                                                   \
  li   t1, val;                                                         \
  PROBE(csrw CSR_HEXIT_CHARGE_NUM, t1);                                 \
  EXPECT_NO_FAULT;                                                      \
  PROBE(csrr a1, CSR_HEXIT_CHARGE_NUM);                                 \
  EXPECT_NO_FAULT;                                                      \
  bne  a1, t1, fail

# In the current mode, reads and writes of hexit_charge trap with the given mcause.
#define CHECK_DENIED(cause)                                             \
  li   s11, cause;                                                      \
  PROBE(csrr a1, CSR_HEXIT_CHARGE_NUM);                                 \
  bne  s10, s11, fail;                                                  \
  PROBE(csrw CSR_HEXIT_CHARGE_NUM, zero);                               \
  bne  s10, s11, fail

RVTEST_RV64M
RVTEST_CODE_BEGIN

  csrw medeleg, zero
  csrw mideleg, zero
  csrw hedeleg, zero
  csrw hideleg, zero
  csrw hvip, zero
  csrw mie, zero
  la   t0, stvec_handler
  csrw stvec, t0
  la   t0, vstvec_handler
  csrw vstvec, t0
  li   t0, COUNTEREN_TM | COUNTEREN_CY | COUNTEREN_IR
  csrw mcounteren, t0
  csrw hcounteren, t0
  csrw scounteren, t0
  li   t0, DELTA
  csrw CSR_HTIMEDELTA_NUM, t0

  # 1. hexit_charge: reset 0, R/W from M and HS, illegal in U, virtual in VS, cleared by the
  #    exit latch (here the ebreak back to M).
  li   TESTNUM, 1
#ifndef HTIME_QEMU
  csrr a1, CSR_HEXIT_CHARGE_NUM
  bnez a1, fail
#endif
  CHECK_RW(0xa5a5a5a55a5a5a5a)
  CHECK_RW(-1)
  ENTER_MODE(MODE_HS)
  CHECK_RW(0x123456789abcdef0)
  EXIT_TO_M
  ENTER_MODE(MODE_U)
  CHECK_DENIED(CAUSE_ILLEGAL_INSTRUCTION)
  EXIT_TO_M
  ENTER_MODE(MODE_VS)
  CHECK_DENIED(CAUSE_VIRTUAL_INSTRUCTION)
  EXIT_TO_M
  csrr a1, CSR_HEXIT_CHARGE_NUM
  bnez a1, fail

  # From here on: VS ecalls go to HS, hidden. Illegal instructions in VS go to VS (the native
  # trap of case 5), VS software and timer interrupts to VS, interrupt 24 to HS.
  li   t0, (1 << CAUSE_VS_ECALL) | (1 << CAUSE_ILLEGAL_INSTRUCTION)
  csrw medeleg, t0
  li   t0, (1 << CAUSE_ILLEGAL_INSTRUCTION)
  csrw hedeleg, t0
  li   t0, MIP_VSSIP | MIP_VSTIP
  csrw hideleg, t0
  li   t0, MIP_VSSIP | MIP_VSTIP | MIP_HVTIP
  csrs mie, t0
  li   t0, SSTATUS_SIE
  csrs vsstatus, t0
  csrw vsie, zero
  li   t0, ENVCFG_STCE
  csrs menvcfg, t0
  csrs henvcfg, t0
  li   t0, -1
  csrw CSR_VSTIMECMP_NUM, t0
  csrw CSR_HVTIMECMP_NUM, t0
  li   t0, HTIMECTL_HHAE
  csrw CSR_HTIMECTL_NUM, t0
  li   a6, ACT_NONE

  # 2. Native references: s0 = cycles over a nop, s8 = between two back-to-back reads, a5 =
  #    instructions over a nop.
  li   TESTNUM, 2
  IN_VS_TWICE(csrr s3, cycle; nop; csrr s5, cycle)
  sub  s0, s5, s3
  IN_VS_TWICE(csrr s3, cycle; csrr s5, cycle)
  sub  s8, s5, s3
  IN_VS_TWICE(csrr s3, instret; nop; csrr s5, instret)
  sub  a5, s5, s3
#ifndef HTIME_QEMU
  EXPECT_EQ(a5, 2)
#endif

  # 3. Emulated ecall, charge {0, 0}: the guest sees 1 cycle (the one before the trap) and
  #    1 instruction (its own first read).
  li   TESTNUM, 3
  li   s9, 0
  IN_VS_TWICE(csrr s3, cycle; ecall; csrr s5, cycle)
  sub  t0, s5, s3
  EXPECT_EQ(t0, 1)
  IN_VS_TWICE(csrr s3, instret; ecall; csrr s5, instret)
  sub  t0, s5, s3
  EXPECT_EQ(t0, 1)
  # hexit_charge was cleared by the latch (a4 is its value at the handler's entry).
  bnez a4, fail

  # 4. Charge {1, 2}: the ecall looks like a nop, in cycles and instructions; the charge
  #    written by the previous exit was cleared by this one's latch.
  li   TESTNUM, 4
  li   s9, CHARGE_NOP
  IN_VS_TWICE(csrr s3, cycle; ecall; csrr s5, cycle)
  sub  t0, s5, s3
  EXPECT_EQ(t0, 3)
  EXPECT_EQ_REG(t0, s0)
  bnez a4, fail
  IN_VS_TWICE(csrr s3, instret; ecall; csrr s5, instret)
  sub  t0, s5, s3
  EXPECT_EQ(t0, 2)
  EXPECT_EQ_REG(t0, a5)
  bnez a4, fail

  # 5. The bypass: a read that is the first guest commit sees the stopped value, one native
  #    nop-to-read step (s0 - s8) before a read that follows a nop. time: within one tick.
  li   TESTNUM, 5
  li   s9, 0
  IN_VS_TWICE(csrr s3, cycle; ecall; nop; csrr s5, cycle)
  sub  t0, s5, s3
  sub  t2, s0, s8
  addi t2, t2, 1
  EXPECT_EQ_REG(t0, t2)
  IN_VS_TWICE(csrr s2, time; ecall; csrr s4, time)
  sub  t0, s4, s2
  EXPECT_TIME(t0)

  # 6. vstimecmp one tick after the guest time at the exit: no VSTIP before the first guest
  #    event. The VS handler sets s7 = s6 + 1, so 2 means the first instruction ran first.
  li   TESTNUM, 6
#ifndef HTIME_QEMU
  li   a6, ACT_VSTIMER
  IN_VS_TWICE(li s6, 0; li s7, 0; ecall; li s6, 1; 1: beqz s7, 1b)
  li   t0, 2
  bne  s7, t0, fail
  li   t0, -1
  csrw CSR_VSTIMECMP_NUM, t0
  li   a6, ACT_NONE
#endif

  # 7. Trap to VS before the first guest commit: the trap entry, from the trap to the VS
  #    handler's first read (s5), is what the guest sees after a native VS trap. Native: an
  #    illegal instruction delegated to VS (csrw to the read-only cycle), which commits a
  #    CSR step (s8) after the read before it; the exit's ecall traps 1 cycle after it.
  li   TESTNUM, 7
  IN_VS_TWICE(csrr s3, cycle; csrw cycle, zero)
  sub  s11, s5, s3
  sub  s11, s11, s8
  li   a6, ACT_INJECT_VS
  IN_VS_TWICE(csrr s3, cycle; ecall; nop)
  li   a6, ACT_NONE
  csrw hvip, zero
  sub  t0, s5, s3
  addi t0, t0, -1
  EXPECT_EQ_REG(t0, s11)

  # 8. Interrupt 24 back to HS before the first guest commit, after an exit with charge
  #    {1, 2}. At the second entry (handler outputs a0 = hexit_cycle, a1 = hhidden_cycle,
  #    a7 = hexit_charge; the first entry's a2, a3): the first window minus the charge was
  #    accumulated in the cycle of the new latch, and the charge was cleared. The guest sees
  #    only the first exit's charge.
  li   TESTNUM, 8
  li   s9, CHARGE_NOP
  li   a6, ACT_HVTI_NOW
  IN_VS_TWICE(csrr s3, cycle; ecall; csrr s5, cycle)
  li   a6, ACT_NONE
  sub  t0, s5, s3
  EXPECT_EQ(t0, 3)
  bnez a7, fail
  sub  t0, a1, a3
  sub  t1, a0, a2
  addi t1, t1, -2
#ifdef HTIME_QEMU
  bltu t1, t0, fail
#else
  bne  t0, t1, fail
#endif

  csrw CSR_HTIMECTL_NUM, zero
  j pass

  TEST_PASSFAIL

  # HS: VS ecall -> emulate it (spin, write the charge, action a6, sepc += 4).
  #     Interrupt 24 -> record a0, a1, a7, disarm hvtimecmp, re-execute.
  .align 2
stvec_handler:
  csrr t5, scause
  bltz t5, 5f
  li   t6, CAUSE_VS_ECALL
  bne  t5, t6, fail
  csrr a2, CSR_HEXIT_CYCLE_NUM
  csrr a3, CSR_HHIDDEN_CYCLE_NUM
  csrr a4, CSR_HEXIT_CHARGE_NUM
  li   t5, 64
1:
  addi t5, t5, -1
  bnez t5, 1b
  csrw CSR_HEXIT_CHARGE_NUM, s9
  li   t5, ACT_INJECT_VS
  bne  a6, t5, 2f
  li   t6, MIP_VSSIP
  csrs hvip, t6
  li   t6, SIE_SSIE
  csrs vsie, t6
2:
  li   t5, ACT_HVTI_NOW
  bne  a6, t5, 3f
  csrw CSR_HVTIMECMP_NUM, zero
3:
  li   t5, ACT_VSTIMER
  bne  a6, t5, 4f
  csrr t6, CSR_HEXIT_TIME_NUM
  li   t5, DELTA + 1
  add  t6, t6, t5
  csrr t5, CSR_HHIDDEN_TIME_NUM
  sub  t6, t6, t5
  csrw CSR_VSTIMECMP_NUM, t6
  li   t6, SIE_STIE
  csrs vsie, t6
4:
  csrr t6, sepc
  addi t6, t6, 4
  csrw sepc, t6
  sret
5:
  li   t6, IRQ_HVTI_CAUSE
  bne  t5, t6, fail
  csrr a0, CSR_HEXIT_CYCLE_NUM
  csrr a1, CSR_HHIDDEN_CYCLE_NUM
  csrr a7, CSR_HEXIT_CHARGE_NUM
  li   t6, -1
  csrw CSR_HVTIMECMP_NUM, t6
  sret

  # VS: the first instruction reads cycle into s5.
  #     Software interrupt -> clear and mask it. Timer -> s7 = s6 + 1, mask it.
  #     Illegal instruction -> skip it.
  .align 2
vstvec_handler:
  csrr s5, cycle
  csrr t5, scause
  bgez t5, 2f
  slli t5, t5, 1
  srli t5, t5, 1
  li   t6, IRQ_S_SOFT
  bne  t5, t6, 1f
  li   t6, SIE_SSIE
  csrc sip, t6
  csrc sie, t6
  sret
1:
  li   t6, IRQ_S_TIMER
  bne  t5, t6, fail
  addi s7, s6, 1
  li   t6, SIE_STIE
  csrc sie, t6
  sret
2:
  li   t6, CAUSE_ILLEGAL_INSTRUCTION
  bne  t5, t6, fail
  csrr t6, sepc
  addi t6, t6, 4
  csrw sepc, t6
  sret

  # M: ebreak -> return to M after it; illegal / virtual -> record mcause in s10, skip it.
  .align 2
  .global mtvec_handler
mtvec_handler:
  csrr t5, mcause
  li   t6, CAUSE_BREAKPOINT
  bne  t5, t6, 1f
  li   t6, MSTATUS_MPV
  csrc mstatus, t6
  li   t6, MSTATUS_MPP
  csrs mstatus, t6
  j    3f
1:
  li   t6, CAUSE_ILLEGAL_INSTRUCTION
  beq  t5, t6, 2f
  li   t6, CAUSE_VIRTUAL_INSTRUCTION
  bne  t5, t6, fail
2:
  mv   s10, t5
3:
  csrr t6, mepc
  addi t6, t6, 4
  csrw mepc, t6
  mret

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
