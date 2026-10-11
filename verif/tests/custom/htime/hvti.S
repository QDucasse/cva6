# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden-time: hypervisor virtual-time interrupt (hvtimecmp, interrupt 24).
# mideleg[24] reads 1, hideleg[24] reads 0, mie[24]/sie[24] are writable and mip[24] is
# read-only. The interrupt is only pending in V=1, is taken in HS even with
# vsstatus.SIE=0, ranks above VS and below HS interrupts, and follows vtime_eff, so
# hidden (HHAE=1) exit time does not bring the deadline closer.
#
# Registers:
#   s3 : guest time just after entering VS
#   s5 : s8 as seen by the first guest instruction (1 = interrupt taken on entry)
#   s6 : last guest time read before the interrupt
#   s7 : hstatus seen by the HS handler on interrupt 24
#   s8 : set by the HS handler on interrupt 24
#   s9 : interrupt log, one nibble per interrupt (1 = HVTI, 2 = VSSI, 3 = STI)

#include "htime_macros.h"

#define MODE_HS   MSTATUS_MPP_S
#define MODE_VS   (MSTATUS_MPP_S | MSTATUS_MPV)

#define COUNTEREN_CY    (1 << 0)
#define DELTA           0x0000100000000000
#define SPIN_CYCLES     20000
#define SSTATUS_SIE_BIT 2
#define HSTATUS_SPV     (1 << 7)
#define IRQ_HVTI_CAUSE  ((1 << 63) | IRQ_HVTI)
#define IRQ_STI_CAUSE   ((1 << 63) | 5)
#define IRQ_SSI_CAUSE   ((1 << 63) | 1)

# Deadline relative to the current guest time (ticks), and the guest-charged bound.
#define NEAR            200
#define B               8
#define TIMEOUT         4000

# In VS: s5 = s8 on entry, s3 = guest time; read time into s6 until s8 is set.
#define GUEST_WAIT_HVTI                                                 \
  mv   s5, s8;                                                          \
  csrr s3, time;                                                        \
1:                                                                      \
  csrr s6, time;                                                        \
  bnez s8, 2f;                                                          \
  sub  t0, s6, s3;                                                      \
  li   t1, TIMEOUT;                                                     \
  bltu t0, t1, 1b;                                                      \
  j    fail;                                                            \
2:

# From M: guest exits to M with HHAE=hhae (after a warm-up exit). M arms hvtimecmp at
# the guest's frozen time + NEAR, spins SPIN_CYCLES and returns.
#   s2 = guest time just before the measured exit
#define HIDDEN_DEADLINE(hhae)                                           \
  li   t0, hhae;                                                        \
  csrw CSR_HTIMECTL_NUM, t0;                                            \
  ENTER_MODE(MODE_VS);                                                  \
  EXIT_TO_M;                                                            \
  ENTER_MODE(MODE_VS);                                                  \
  csrr s2, time;                                                        \
  EXIT_TO_M;                                                            \
  csrr t0, CSR_HEXIT_TIME_NUM;                                          \
  csrr t1, CSR_HTIMEDELTA_NUM;                                          \
  add  t0, t0, t1;                                                      \
  csrr t1, CSR_HHIDDEN_TIME_NUM;                                        \
  sub  t0, t0, t1;                                                      \
  addi t0, t0, NEAR;                                                    \
  csrw CSR_HVTIMECMP_NUM, t0;                                           \
  li   s8, 0;                                                           \
  csrr t0, mcycle;                                                      \
3:                                                                      \
  csrr t1, mcycle;                                                      \
  sub  t1, t1, t0;                                                      \
  li   t2, SPIN_CYCLES;                                                 \
  bltu t1, t2, 3b;                                                      \
  ENTER_MODE(MODE_VS);                                                  \
  GUEST_WAIT_HVTI;                                                      \
  EXIT_TO_M;                                                            \
  csrw CSR_HTIMECTL_NUM, zero

RVTEST_RV64M
RVTEST_CODE_BEGIN

  # ebreak to M; nothing delegated except what each case sets up.
  csrw medeleg, zero
  csrw mideleg, zero
  csrw hideleg, zero
  csrw hvip, zero
  csrw mie, zero
  la   t0, stvec_handler
  csrw stvec, t0
  la   t0, vstvec_handler
  csrw vstvec, t0
  li   t0, COUNTEREN_TM | COUNTEREN_CY
  csrw mcounteren, t0
  csrw hcounteren, t0
  csrw scounteren, t0
  li   t0, DELTA
  csrw CSR_HTIMEDELTA_NUM, t0
  csrw CSR_HTIMECTL_NUM, zero
  li   t0, -1
  csrw CSR_HVTIMECMP_NUM, t0
  li   s9, 0

  # 1. Masks: mideleg[24] stays 1, hideleg[24] stays 0, mie[24] is writable but not
  #    visible in hie, mip[24] ignores writes.
  li   TESTNUM, 1
  li   s1, MIP_HVTIP
  csrr t0, mideleg
  and  t0, t0, s1
  beqz t0, fail
  csrs hideleg, s1
  csrr t0, hideleg
  and  t0, t0, s1
  bnez t0, fail
  csrs mie, s1
  csrr t0, mie
  and  t0, t0, s1
  beqz t0, fail
  csrr t0, hie
  and  t0, t0, s1
  bnez t0, fail
  csrc mie, s1
  csrs mip, s1
  csrr t0, mip
  and  t0, t0, s1
  bnez t0, fail

  # 2. HS: sie[24] is writable; with the deadline crossed and SIE=1, nothing is pending
  #    or taken in HS, nor seen by M.
  li   TESTNUM, 2
  csrw CSR_HVTIMECMP_NUM, zero
  li   s8, 0
  ENTER_MODE(MODE_HS)
  li   t0, MIP_HVTIP
  csrs sie, t0
  csrr t1, sie
  and  t1, t1, t0
  beqz t1, fail
  csrsi sstatus, SSTATUS_SIE_BIT
  csrr t2, cycle
1:
  csrr t1, cycle
  sub  t1, t1, t2
  li   t3, SPIN_CYCLES
  bltu t1, t3, 1b
  csrci sstatus, SSTATUS_SIE_BIT
  csrr t1, sip
  and  t1, t1, t0
  bnez t1, fail
  EXIT_TO_M
  bnez s8, fail
  csrr t0, mip
  and  t0, t0, s1
  bnez t0, fail
  csrr t0, mie
  and  t0, t0, s1
  beqz t0, fail

  # 3. VS with vsstatus.SIE=0: the crossed deadline traps to HS on the first guest
  #    instruction, with hstatus.SPV=1.
  li   TESTNUM, 3
  csrci vsstatus, SSTATUS_SIE_BIT
  ENTER_MODE(MODE_VS)
  mv   s5, s8
  EXIT_TO_M
  beqz s5, fail
  li   t0, HSTATUS_SPV
  and  t0, t0, s7
  beqz t0, fail
  li   t0, 0x1
  bne  s9, t0, fail

  # 4. Priority over VS: VSSI (hvip.VSSIP, enabled in the guest) and interrupt 24 both
  #    pending on entry -> interrupt 24 first, in HS, then VSSI in VS.
  li   TESTNUM, 4
  li   s9, 0
  li   s8, 0
  li   t0, MIP_VSSIP_BIT
  csrw hideleg, t0
  csrw hvip, t0
  li   t0, MIP_SSIP
  csrw vsie, t0
  csrsi vsstatus, SSTATUS_SIE_BIT
  csrw CSR_HVTIMECMP_NUM, zero
  ENTER_MODE(MODE_VS)
1:
  srli t0, s9, 4
  beqz t0, 1b
  EXIT_TO_M
  li   t0, 0x12
  bne  s9, t0, fail
  csrci vsstatus, SSTATUS_SIE_BIT
  csrw hvip, zero
  csrw hideleg, zero
  csrw vsie, zero

  # 5. Below HS: STI (mip.STIP, delegated to HS) and interrupt 24 both pending on entry
  #    -> STI first, then interrupt 24.
  li   TESTNUM, 5
  li   s9, 0
  li   s8, 0
  li   t0, MIP_STIP
  csrs mideleg, t0
  csrs mie, t0
  csrs mip, t0
  csrw CSR_HVTIMECMP_NUM, zero
  ENTER_MODE(MODE_VS)
1:
  srli t0, s9, 4
  beqz t0, 1b
  EXIT_TO_M
  li   t0, 0x31
  bne  s9, t0, fail
  li   t0, MIP_STIP
  csrc mip, t0
  csrc mie, t0
  csrc mideleg, t0

  # 6. mie[24]=0 masks it: the guest runs past a crossed deadline.
  li   TESTNUM, 6
  li   s8, 0
  csrc mie, s1
  csrw CSR_HVTIMECMP_NUM, zero
  ENTER_MODE(MODE_VS)
  csrr s3, time
1:
  csrr t0, time
  sub  t0, t0, s3
  li   t1, NEAR
  bltu t0, t1, 1b
  EXIT_TO_M
  bnez s8, fail
  csrs mie, s1

  # 7. Hidden exit (HHAE=1): a deadline armed at the guest's frozen time + NEAR is
  #    not crossed by the hidden M stay. The guest waits about NEAR of its own time.
  li   TESTNUM, 7
  HIDDEN_DEADLINE(HTIMECTL_HHAE)
  bnez s5, fail
  sub  t0, s6, s3
  li   t1, NEAR - 2 * B
  bltu t0, t1, fail
  sub  t0, s6, s2
  li   t1, NEAR + 2 * B
  bgeu t0, t1, fail

  # 8. Visible exit (HHAE=0): the M stay crosses the deadline, so the interrupt is
  #    taken on the first guest instruction.
  li   TESTNUM, 8
  HIDDEN_DEADLINE(0)
  beqz s5, fail

  j pass

  TEST_PASSFAIL

  # HS: interrupt 24 -> log 1, record hstatus, disarm; STI -> log 3, disable STIE.
  .align 2
stvec_handler:
  csrr t5, scause
  li   t6, IRQ_HVTI_CAUSE
  bne  t5, t6, 1f
  csrr s7, hstatus
  slli s9, s9, 4
  addi s9, s9, 1
  li   s8, 1
  li   t6, -1
  csrw CSR_HVTIMECMP_NUM, t6
  sret
1:
  li   t6, IRQ_STI_CAUSE
  bne  t5, t6, fail
  slli s9, s9, 4
  addi s9, s9, 3
  li   t6, MIP_STIP
  csrc sie, t6
  sret

  # VS: VSSI (seen as SSI) -> log 2, disable it.
  .align 2
vstvec_handler:
  csrr t5, scause
  li   t6, IRQ_SSI_CAUSE
  bne  t5, t6, fail
  slli s9, s9, 4
  addi s9, s9, 2
  li   t6, MIP_SSIP
  csrc sie, t6
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
