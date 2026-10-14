# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden freeze, branch predictors. The guest runs a loop with a
# conditional branch, an indirect jump (BTB) and a call/return (RAS), then exits to HS with
# HFRZ armed. Upstream CVA6 clears the BHT, BTB and RAS on every trap and xRET; while frozen that
# flush is skipped and the predictors are off. The frozen HS handler runs its own loop of
# branches, indirect jumps and calls, and must compute the right result without predictions. The
# guest then runs its loop again. The testbench freeze monitor checks that the caches, TLBs and
# predictors didn't change while frozen (freeze_mon_mask in testlist_htime.yaml).
#
# Expected windows: xret (the ecall exit), hfrz0 (the final ebreak to M, ended in M).

#include "htime_macros.h"

#define CAUSE_VS_ECALL  10
#define MODE_VS         (MSTATUS_MPP_S | MSTATUS_MPV)
#define ITERS           16

# a0 = sum over ITERS iterations of: +1 by a call, +2 by an indirect jump, +4 by a taken branch
# on odd iterations. Expected: ITERS * 3 + (ITERS / 2) * 4. Clobbers t0-t3, ra, s1.
.macro BRANCHY_LOOP fn, tgt
  li   a0, 0
  li   s1, ITERS
1:
  jal  \fn
  la   t0, \tgt
  jalr t1, t0
  andi t2, s1, 1
  beqz t2, 2f
  addi a0, a0, 4
2:
  addi s1, s1, -1
  bnez s1, 1b
  li   t3, ITERS * 3 + (ITERS / 2) * 4
  bne  a0, t3, fail
.endm

RVTEST_RV64M
RVTEST_CODE_BEGIN

  li   TESTNUM, 1
  csrw medeleg, zero
  li   t0, (1 << CAUSE_VS_ECALL)
  csrs medeleg, t0
  la   t0, stvec_handler
  csrw stvec, t0

  li   t0, HTIMECTL_HFRZ
  csrw CSR_HTIMECTL_NUM, t0
  ENTER_MODE(MODE_VS)

  # Guest: train the predictors, exit, run again.
  BRANCHY_LOOP guest_fn, guest_tgt
  li   TESTNUM, 2
  ecall
  li   TESTNUM, 3
  BRANCHY_LOOP guest_fn, guest_tgt

  EXIT_TO_M
  csrw CSR_HTIMECTL_NUM, zero

  j pass

guest_fn:
  addi a0, a0, 1
  ret
guest_tgt:
  addi a0, a0, 2
  jr   t1

  TEST_PASSFAIL

  # HS exit handler (frozen): the same kind of loop, at other addresses.
  .align 2
stvec_handler:
  csrr t5, scause
  li   t6, CAUSE_VS_ECALL
  bne  t5, t6, fail
  mv   s2, ra
  BRANCHY_LOOP hv_fn, hv_tgt
  mv   ra, s2
  csrr t6, sepc
  addi t6, t6, 4
  csrw sepc, t6
  sret

hv_fn:
  addi a0, a0, 1
  ret
hv_tgt:
  addi a0, a0, 2
  jr   t1

  HTIME_MTVEC_HANDLER

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
