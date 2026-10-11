# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden-time: htimedelta and the time CSR in V=1 (time = mtime + htimedelta).

#include "htime_macros.h"

#define DELTA_POS   0x0000100000000000
#define DELTA_NEG   0xffffff0000000000

# In the current mode, check time - delta brackets two MMIO reads of mtime.
#define CHECK_TIME(delta)                                               \
  li   s0, CLINT_MTIME;                                                 \
  li   s1, delta;                                                       \
  ld   t0, 0(s0);                                                       \
  csrr t1, time;                                                        \
  ld   t2, 0(s0);                                                       \
  sub  t1, t1, s1;                                                      \
  bltu t1, t0, fail;                                                    \
  bltu t2, t1, fail

# From M: set htimedelta, enter the mode, check time, come back.
#define CHECK_TIME_IN(mode, delta)                                      \
  li   t0, delta;                                                       \
  csrw CSR_HTIMEDELTA_NUM, t0;                                          \
  ENTER_MODE(mode);                                                     \
  CHECK_TIME(delta);                                                    \
  EXIT_TO_M

# From M: set the counter-enables, enter the mode, probe time, come back.
#define PROBE_TIME_IN(mode, mcen, hcen, scen)                           \
  li   t0, mcen;                                                        \
  csrw mcounteren, t0;                                                  \
  li   t0, hcen;                                                        \
  csrw hcounteren, t0;                                                  \
  li   t0, scen;                                                        \
  csrw scounteren, t0;                                                  \
  ENTER_MODE(mode);                                                     \
  PROBE(csrr a1, time);                                                 \
  EXIT_TO_M

# From M: enter the mode, probe an htimedelta read, come back.
#define PROBE_DELTA_IN(mode)                                            \
  ENTER_MODE(mode);                                                     \
  PROBE(csrr a1, CSR_HTIMEDELTA_NUM);                                   \
  EXIT_TO_M

#define MODE_HS   MSTATUS_MPP_S
#define MODE_U    MSTATUS_MPP_U
#define MODE_VS   (MSTATUS_MPP_S | MSTATUS_MPV)
#define MODE_VU   (MSTATUS_MPP_U | MSTATUS_MPV)

RVTEST_RV64M
RVTEST_CODE_BEGIN

  # 1. htimedelta resets to 0 and is R/W from M (all 64 bits).
  li   TESTNUM, 1
  csrr a1, CSR_HTIMEDELTA_NUM
  bnez a1, fail
  li   t1, 0xa5a5a5a55a5a5a5a
  csrw CSR_HTIMEDELTA_NUM, t1
  csrr a1, CSR_HTIMEDELTA_NUM
  bne  a1, t1, fail

  # 2. htimedelta is R/W from HS.
  li   TESTNUM, 2
  ENTER_MODE(MODE_HS)
  li   t1, 0x123456789abcdef0
  PROBE(csrw CSR_HTIMEDELTA_NUM, t1)
  EXPECT_NO_FAULT
  PROBE(csrr a1, CSR_HTIMEDELTA_NUM)
  EXPECT_NO_FAULT
  bne  a1, t1, fail
  EXIT_TO_M

  # 3. htimedelta from U -> illegal; from VS/VU -> virtual instruction.
  li   TESTNUM, 3
  PROBE_DELTA_IN(MODE_U)
  EXPECT_ILLEGAL
  PROBE_DELTA_IN(MODE_VS)
  EXPECT_VIRTUAL
  PROBE_DELTA_IN(MODE_VU)
  EXPECT_VIRTUAL

  # 4. htimedeltah does not exist on RV64.
  li   TESTNUM, 4
  PROBE(csrr a1, CSR_HTIMEDELTAH_NUM)
  EXPECT_ILLEGAL

  # Enable time everywhere for the value checks.
  li   t0, COUNTEREN_TM
  csrw mcounteren, t0
  csrw hcounteren, t0
  csrw scounteren, t0

  # 5. V=0 ignores htimedelta (M and HS).
  li   TESTNUM, 5
  li   t0, DELTA_POS
  csrw CSR_HTIMEDELTA_NUM, t0
  CHECK_TIME(0)
  ENTER_MODE(MODE_HS)
  CHECK_TIME(0)
  EXIT_TO_M

  # 6. VS: time = mtime + htimedelta, for delta = 0, positive, negative (wraps).
  li   TESTNUM, 6
  CHECK_TIME_IN(MODE_VS, 0)
  CHECK_TIME_IN(MODE_VS, DELTA_POS)
  CHECK_TIME_IN(MODE_VS, DELTA_NEG)

  # 7. VU: same.
  li   TESTNUM, 7
  CHECK_TIME_IN(MODE_VU, 0)
  CHECK_TIME_IN(MODE_VU, DELTA_POS)
  CHECK_TIME_IN(MODE_VU, DELTA_NEG)

  # 8. VS gating: mcounteren.TM=0 -> illegal; hcounteren.TM=0 -> virtual.
  li   TESTNUM, 8
  PROBE_TIME_IN(MODE_VS, 0, COUNTEREN_TM, COUNTEREN_TM)
  EXPECT_ILLEGAL
  PROBE_TIME_IN(MODE_VS, COUNTEREN_TM, 0, COUNTEREN_TM)
  EXPECT_VIRTUAL
  PROBE_TIME_IN(MODE_VS, COUNTEREN_TM, COUNTEREN_TM, 0)
  EXPECT_NO_FAULT

  # 9. VU gating: mcounteren.TM=0 -> illegal; hcounteren.TM=0 or scounteren.TM=0 -> virtual.
  li   TESTNUM, 9
  PROBE_TIME_IN(MODE_VU, 0, COUNTEREN_TM, COUNTEREN_TM)
  EXPECT_ILLEGAL
  PROBE_TIME_IN(MODE_VU, COUNTEREN_TM, 0, COUNTEREN_TM)
  EXPECT_VIRTUAL
  PROBE_TIME_IN(MODE_VU, COUNTEREN_TM, COUNTEREN_TM, 0)
  EXPECT_VIRTUAL
  PROBE_TIME_IN(MODE_VU, COUNTEREN_TM, COUNTEREN_TM, COUNTEREN_TM)
  EXPECT_NO_FAULT

  j pass

  TEST_PASSFAIL

  HTIME_MTVEC_HANDLER

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
