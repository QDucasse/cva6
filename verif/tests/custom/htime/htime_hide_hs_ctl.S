# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden-time: HS control during an exit: HHAE sampled at the return, and HS
# writes to hhidden_* / hexit_* shifting the guest clocks. See htime_exit.h.

#include "htime_exit.h"

RVTEST_RV64M
RVTEST_CODE_BEGIN

  HTIME_EXIT_INIT

  # 1. HHAE is sampled at the return: set in HS -> hidden; cleared in HS -> visible.
  li   TESTNUM, 1
  MEASURE(ROUTE_HS, 0, ACT_SET_HHAE, 0)
  EXPECT_HIDDEN
  MEASURE(ROUTE_HS, HTIMECTL_HHAE, ACT_CLEAR_HHAE, 0)
  EXPECT_VISIBLE
  MEASURE(ROUTE_M, 0, ACT_SET_HHAE, 0)
  EXPECT_HIDDEN
  MEASURE(ROUTE_M, HTIMECTL_HHAE, ACT_CLEAR_HHAE, 0)
  EXPECT_VISIBLE

  # 2. HS adds OFFSET to hhidden_* (HHAE=0): guest time and cycle drop by OFFSET.
  li   TESTNUM, 2
  MEASURE(ROUTE_HS, 0, ACT_ADD_HIDDEN, 0)
  li   t0, OFFSET
  add  s4, s4, t0
  add  s5, s5, t0
  EXPECT_VISIBLE
  li   t1, OFFSET
  sub  t0, s4, s2
  bgeu t0, t1, fail
  sub  t0, s5, s3
  bgeu t0, t1, fail

  # 3. HS subtracts OFFSET from hexit_* (HHAE=1): OFFSET more is hidden.
  li   TESTNUM, 3
  MEASURE(ROUTE_HS, HTIMECTL_HHAE, ACT_SUB_EXIT, 0)
  li   t0, OFFSET
  add  s4, s4, t0
  add  s5, s5, t0
  EXPECT_HIDDEN

  j pass

  TEST_PASSFAIL

  HTIME_EXIT_HANDLERS

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
