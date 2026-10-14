# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden freeze: when the freeze starts and ends.
# The freeze isn't architecturally visible: the testbench's freeze monitor prints one line per
# freeze window with how it ended, and the runner checks the sequence (freeze_windows in
# testlist_htime.yaml). Each MEASURE runs two guest ecalls, then leaves the guest with an ebreak
# to M (a V 1->0 trap too) and clears htimectl in M. See htime_exit.h.
#
# Expected windows, in order:
#   1. armed, exits to HS:            xret xret hfrz0  (ebreak to M, ended by the htimectl clear)
#   2. armed, exits to M:             xret xret hfrz0
#   3. armed, HS -> M -> HS detour:   xret xret hfrz0  (nested traps don't end the freeze)
#   4. armed, HS clears HFRZ:         xret hfrz0       (then disarmed: the ebreak doesn't freeze)
#   5. not armed, HS sets HFRZ:       hfrz0            (arming during an exit takes effect at the
#                                                       next exit, the ebreak)
#   6. not armed:                     (none)
#   7. armed, HS traps to M (V=0):    (none)

#define SPIN_CYCLES 200
#include "htime_exit.h"

RVTEST_RV64M
RVTEST_CODE_BEGIN

  HTIME_EXIT_INIT

  li   TESTNUM, 1
  MEASURE(ROUTE_HS, HTIMECTL_HFRZ, ACT_NONE, 0)

  li   TESTNUM, 2
  MEASURE(ROUTE_M, HTIMECTL_HFRZ, ACT_NONE, 0)

  li   TESTNUM, 3
  MEASURE(ROUTE_HS, HTIMECTL_HFRZ, ACT_NONE, 1)

  li   TESTNUM, 4
  MEASURE(ROUTE_HS, HTIMECTL_HFRZ, ACT_CLEAR_HFRZ, 0)

  li   TESTNUM, 5
  MEASURE(ROUTE_HS, 0, ACT_SET_HFRZ, 0)

  li   TESTNUM, 6
  MEASURE(ROUTE_HS, 0, ACT_NONE, 0)

  li   TESTNUM, 7
  li   t0, HTIMECTL_HFRZ
  csrw CSR_HTIMECTL_NUM, t0
  ENTER_MODE(MODE_HS)
  EXIT_TO_M
  csrr t0, CSR_HTIMECTL_NUM
  li   t1, HTIMECTL_HFRZ
  bne  t0, t1, fail
  csrw CSR_HTIMECTL_NUM, zero

  j pass

  TEST_PASSFAIL

  HTIME_EXIT_HANDLERS

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
