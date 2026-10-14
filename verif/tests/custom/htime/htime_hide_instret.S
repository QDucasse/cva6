# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden-time: instret (vinstret = minstret - hhidden_instret in V=1), on each exit route
# with HHAE=0 and 1. See htime_exit.h for the exit handlers.
#
# instret checks are exact: the exit ecall does not retire, so across
#   csrr s3, instret; ecall; csrr s5, instret
# a hidden exit gives s5 - s3 = 1 (the first csrr). Back in M after EXIT_TO_M (an ebreak,
# which also does not retire), hexit_instret holds minstret at that exit, so
#   hexit_instret - hhidden_instret = s5 + 1.
#
# QEMU (-DHTIME_QEMU): minstret follows host ticks like mcycle (instructions only with
# -icount, and even then not per instruction), so the exact checks become the cycle bounds.

#include "htime_exit.h"

#define COUNTEREN_IR  (1 << 2)

# From M: s6 = hhidden_instret before, one warm-up exit, then the measured one.
#   s3/s5 = guest instret before/after.
#define MEASURE_IR(route, hhae, nest)                                   \
  li   t0, (1 << CAUSE_VS_ECALL);                                       \
  .if route;                                                            \
  csrs medeleg, t0;                                                     \
  .else;                                                                \
  csrc medeleg, t0;                                                     \
  .endif;                                                               \
  li   t0, hhae;                                                        \
  csrw CSR_HTIMECTL_NUM, t0;                                            \
  li   a7, nest;                                                        \
  li   a5, ACT_NONE;                                                    \
  csrr s6, CSR_HHIDDEN_INSTRET_NUM;                                     \
  ENTER_MODE(MODE_VS);                                                  \
  ecall;                                                                \
  csrr s3, instret;                                                     \
  ecall;                                                                \
  csrr s5, instret;                                                     \
  EXIT_TO_M;                                                            \
  csrw CSR_HTIMECTL_NUM, zero

# Fail unless lo <= t0 <= hi (unsigned).
#define EXPECT_T0_IN(lo, hi)                                            \
  li   t1, lo;                                                          \
  bltu t0, t1, fail;                                                    \
  li   t1, hi;                                                          \
  bltu t1, t0, fail

# IR_ONE_*: what instret moves by over one instruction; IR_VISIBLE_MIN: over a visible exit.
#ifdef HTIME_QEMU
#define IR_ONE_MIN      0
#define IR_ONE_MAX      BOUND_CYCLES
#define IR_VISIBLE_MIN  SPIN_CYCLES
#else
#define IR_ONE_MIN      1
#define IR_ONE_MAX      1
#define IR_VISIBLE_MIN  2
#endif

# hexit_instret latched at the EXIT_TO_M ebreak, in the guest's count.
#define EXPECT_LATCH_IR                                                 \
  csrr t0, CSR_HEXIT_INSTRET_NUM;                                       \
  csrr t1, CSR_HHIDDEN_INSTRET_NUM;                                     \
  sub  t0, t0, t1;                                                      \
  sub  t0, t0, s5;                                                      \
  EXPECT_T0_IN(IR_ONE_MIN, IR_ONE_MAX)

# Hidden: the guest saw only its own csrr, and hhidden_instret grew.
#define EXPECT_HIDDEN_IR                                                \
  sub  t0, s5, s3;                                                      \
  EXPECT_T0_IN(IR_ONE_MIN, IR_ONE_MAX);                                 \
  csrr t0, CSR_HHIDDEN_INSTRET_NUM;                                     \
  bgeu s6, t0, fail

# Visible: the guest also saw the handler's instructions, and hhidden_instret is unchanged.
#define EXPECT_VISIBLE_IR                                               \
  sub  t0, s5, s3;                                                      \
  EXPECT_T0_IN(IR_VISIBLE_MIN, -1);                                     \
  csrr t0, CSR_HHIDDEN_INSTRET_NUM;                                     \
  bne  t0, s6, fail

RVTEST_RV64M
RVTEST_CODE_BEGIN

  HTIME_EXIT_INIT
  li   t0, COUNTEREN_IR
  csrs mcounteren, t0
  csrs hcounteren, t0
  csrs scounteren, t0

  # 1. V->HS->V, HHAE=0 then 1.
  li   TESTNUM, 1
  MEASURE_IR(ROUTE_HS, 0, 0)
  EXPECT_LATCH_IR
  EXPECT_VISIBLE_IR
  MEASURE_IR(ROUTE_HS, HTIMECTL_HHAE, 0)
  EXPECT_LATCH_IR
  EXPECT_HIDDEN_IR

  # 2. V->M->V, HHAE=0 then 1.
  li   TESTNUM, 2
  MEASURE_IR(ROUTE_M, 0, 0)
  EXPECT_LATCH_IR
  EXPECT_VISIBLE_IR
  MEASURE_IR(ROUTE_M, HTIMECTL_HHAE, 0)
  EXPECT_LATCH_IR
  EXPECT_HIDDEN_IR

  # 3. V->HS->M->HS->V: the M detour is hidden too.
  li   TESTNUM, 3
  MEASURE_IR(ROUTE_HS, 0, 1)
  EXPECT_LATCH_IR
  EXPECT_VISIBLE_IR
  MEASURE_IR(ROUTE_HS, HTIMECTL_HHAE, 1)
  EXPECT_LATCH_IR
  EXPECT_HIDDEN_IR

  # 4. A software-written hhidden_instret is what VS subtracts.
  li   TESTNUM, 4
  li   t0, OFFSET
  csrw CSR_HHIDDEN_INSTRET_NUM, t0
  ENTER_MODE(MODE_VS)
  csrr s5, instret
  EXIT_TO_M
  EXPECT_LATCH_IR
  csrr t0, CSR_HHIDDEN_INSTRET_NUM
  li   t1, OFFSET
  bne  t0, t1, fail

  # 5. V=0 ignores hhidden_instret: instret = minstret in M and HS.
  li   TESTNUM, 5
  csrr t1, minstret
  csrr t0, instret
  sub  t0, t0, t1
  EXPECT_T0_IN(IR_ONE_MIN, IR_ONE_MAX)
  csrr s6, minstret
  ENTER_MODE(MODE_HS)
  csrr s7, instret
  EXIT_TO_M
  csrr s8, minstret
  bgeu s6, s7, fail
  bgeu s7, s8, fail

  j pass

  TEST_PASSFAIL

  HTIME_EXIT_HANDLERS

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
