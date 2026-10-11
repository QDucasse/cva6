# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden-time: latch and accumulate on each exit route (V->HS->V, V->M->V,
# V->HS->M->HS->V), with HHAE=0 (visible) and HHAE=1 (hidden). See htime_exit.h.

#include "htime_exit.h"

RVTEST_RV64M
RVTEST_CODE_BEGIN

  HTIME_EXIT_INIT

  # 1. V->HS->V, HHAE=0: hexit_* latched, nothing accumulated, the exit is visible.
  li   TESTNUM, 1
  MEASURE(ROUTE_HS, 0, ACT_NONE, 0)
  EXPECT_LATCH
  EXPECT_NO_ACCUMULATE
  EXPECT_VISIBLE

  # 2. V->HS->V, HHAE=1: hexit_* latched, hidden interval accumulated, the exit is hidden.
  li   TESTNUM, 2
  MEASURE(ROUTE_HS, HTIMECTL_HHAE, ACT_NONE, 0)
  EXPECT_LATCH
  EXPECT_ACCUMULATE
  EXPECT_HIDDEN

  # 3. V->M->V, HHAE=0 then 1.
  li   TESTNUM, 3
  MEASURE(ROUTE_M, 0, ACT_NONE, 0)
  EXPECT_LATCH
  EXPECT_NO_ACCUMULATE
  EXPECT_VISIBLE
  MEASURE(ROUTE_M, HTIMECTL_HHAE, ACT_NONE, 0)
  EXPECT_LATCH
  EXPECT_ACCUMULATE
  EXPECT_HIDDEN

  # 4. V->HS->M->HS->V: latched once (the HS->M trap does not relatch), accumulated once.
  li   TESTNUM, 4
  MEASURE(ROUTE_HS, 0, ACT_NONE, 1)
  bne  a4, a0, fail
  EXPECT_LATCH
  EXPECT_NO_ACCUMULATE
  EXPECT_VISIBLE
  MEASURE(ROUTE_HS, HTIMECTL_HHAE, ACT_NONE, 1)
  bne  a4, a0, fail
  EXPECT_LATCH
  EXPECT_ACCUMULATE
  EXPECT_HIDDEN

  j pass

  TEST_PASSFAIL

  HTIME_EXIT_HANDLERS

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
