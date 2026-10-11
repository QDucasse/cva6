# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden-time: guest view in V=1 (vtime = mtime + htimedelta - hhidden_time,
# vcycle = mcycle - hhidden_cycle) and V=0 unaffected. See htime_exit.h.

#include "htime_exit.h"

RVTEST_RV64M
RVTEST_CODE_BEGIN

  HTIME_EXIT_INIT

  # 1. One hidden exit makes hhidden_* non-zero.
  li   TESTNUM, 1
  MEASURE(ROUTE_HS, HTIMECTL_HHAE, ACT_NONE, 0)
  csrr t0, CSR_HHIDDEN_TIME_NUM
  beqz t0, fail
  csrr t0, CSR_HHIDDEN_CYCLE_NUM
  beqz t0, fail

  # 2. VS: mtime + DELTA - hhidden_time brackets time; cycle + hhidden_cycle brackets
  #    the next hexit_cycle.
  li   TESTNUM, 2
  li   s0, CLINT_MTIME
  li   t0, (1 << CAUSE_VS_ECALL)
  csrs medeleg, t0
  ENTER_MODE(MODE_VS)
  li   a5, ACT_NONE
  li   a7, 0
  ld   s6, 0(s0)
  csrr s7, time
  ld   s8, 0(s0)
  csrr s3, cycle
  ecall
  EXIT_TO_M
  csrr t0, CSR_HHIDDEN_TIME_NUM
  li   t1, DELTA
  sub  t1, t1, t0
  sub  s7, s7, t1
  bltu s7, s6, fail
  bltu s8, s7, fail
  add  t0, s3, a3
  bltu a2, t0, fail

  # 3. V=0 ignores hhidden_*: time = mtime and cycle = mcycle in M and HS.
  li   TESTNUM, 3
  li   s0, CLINT_MTIME
  ld   t0, 0(s0)
  csrr t1, time
  ld   t2, 0(s0)
  bltu t1, t0, fail
  bltu t2, t1, fail
  csrr t0, mcycle
  csrr t1, cycle
  csrr t2, mcycle
  bltu t1, t0, fail
  bltu t2, t1, fail
  ENTER_MODE(MODE_HS)
  ld   s6, 0(s0)
  csrr s7, time
  ld   s8, 0(s0)
  EXIT_TO_M
  bltu s7, s6, fail
  bltu s8, s7, fail

  j pass

  TEST_PASSFAIL

  HTIME_EXIT_HANDLERS

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
