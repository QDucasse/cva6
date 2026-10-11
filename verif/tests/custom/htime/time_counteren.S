# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden-time: access rules for the time CSR (V=0).

#include "htime_macros.h"

RVTEST_RV64M
RVTEST_CODE_BEGIN

  # 1. M reads time regardless of mcounteren.
  li   TESTNUM, 1
  csrw mcounteren, zero
  PROBE(csrr a1, time)
  EXPECT_NO_FAULT
  beqz a1, fail

  # 2. time is read-only.
  li   TESTNUM, 2
  PROBE(csrw time, zero)
  EXPECT_ILLEGAL

  # 3. S with mcounteren.TM=0 -> illegal.
  li   TESTNUM, 3
  csrw mcounteren, zero
  ENTER_MODE(MSTATUS_MPP_S)
  PROBE(csrr a1, time)
  EXIT_TO_M
  EXPECT_ILLEGAL

  # 4. S with mcounteren.TM=1 -> reads mtime.
  li   TESTNUM, 4
  csrwi mcounteren, COUNTEREN_TM
  li   s0, CLINT_MTIME
  ld   s1, 0(s0)
  ENTER_MODE(MSTATUS_MPP_S)
  PROBE(csrr a1, time)
  EXIT_TO_M
  EXPECT_NO_FAULT
  bltu a1, s1, fail

  # 5. U with mcounteren.TM=1, scounteren.TM=0 -> illegal.
  li   TESTNUM, 5
  csrwi mcounteren, COUNTEREN_TM
  csrw  scounteren, zero
  ENTER_MODE(MSTATUS_MPP_U)
  PROBE(csrr a1, time)
  EXIT_TO_M
  EXPECT_ILLEGAL

  # 6. U with mcounteren.TM=0, scounteren.TM=1 -> illegal.
  li   TESTNUM, 6
  csrw  mcounteren, zero
  csrwi scounteren, COUNTEREN_TM
  ENTER_MODE(MSTATUS_MPP_U)
  PROBE(csrr a1, time)
  EXIT_TO_M
  EXPECT_ILLEGAL

  # 7. U with both TM=1 -> reads mtime.
  li   TESTNUM, 7
  csrwi mcounteren, COUNTEREN_TM
  csrwi scounteren, COUNTEREN_TM
  ld   s1, 0(s0)
  ENTER_MODE(MSTATUS_MPP_U)
  PROBE(csrr a1, time)
  EXIT_TO_M
  EXPECT_NO_FAULT
  bltu a1, s1, fail

  j pass

  TEST_PASSFAIL

  HTIME_MTVEC_HANDLER

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
