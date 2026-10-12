# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden-time feature off (RVHiddenTime=0): time and htimedelta are not implemented,
# nor are the hidden-time and Sstc CSRs: every access is an illegal instruction, even in M.
# Interrupt 24 is not implemented either.
# Run on cv64a6_imafdch_sv39.

#include "htime_macros.h"

RVTEST_RV64M
RVTEST_CODE_BEGIN

#ifndef HTIME_QEMU
  # QEMU always implements time and, with H, htimedelta: steps 1-2 are CVA6 only.
  # 1. M read of time -> illegal.
  li   TESTNUM, 1
  PROBE(csrr a1, time)
  EXPECT_ILLEGAL

  # 2. M read/write of htimedelta -> illegal.
  li   TESTNUM, 2
  PROBE(csrr a1, CSR_HTIMEDELTA_NUM)
  EXPECT_ILLEGAL
  PROBE(csrw CSR_HTIMEDELTA_NUM, zero)
  EXPECT_ILLEGAL
#endif

#define PROBE_OFF(csr)                                                  \
  PROBE(csrr a1, csr);                                                  \
  EXPECT_ILLEGAL;                                                       \
  PROBE(csrw csr, zero);                                                \
  EXPECT_ILLEGAL

  # 3. M read/write of the hidden-time CSRs -> illegal.
  li   TESTNUM, 3
  PROBE_OFF(CSR_HTIMECTL_NUM)
  PROBE_OFF(CSR_HEXIT_TIME_NUM)
  PROBE_OFF(CSR_HHIDDEN_TIME_NUM)
  PROBE_OFF(CSR_HVTIMECMP_NUM)
  PROBE_OFF(CSR_HEXIT_CYCLE_NUM)
  PROBE_OFF(CSR_HHIDDEN_CYCLE_NUM)

  # 4. No Sstc: stimecmp/vstimecmp illegal, menvcfg/henvcfg.STCE read-only zero.
  li   TESTNUM, 4
  PROBE_OFF(CSR_STIMECMP_NUM)
  PROBE_OFF(CSR_VSTIMECMP_NUM)
  li   t0, ENVCFG_STCE
  csrs menvcfg, t0
  csrs henvcfg, t0
  csrr t0, menvcfg
  bltz t0, fail
  csrr t0, henvcfg
  bltz t0, fail

  # 5. No interrupt 24: mideleg[24] reads 0 and mie[24] is not writable.
  li   TESTNUM, 5
  li   t1, MIP_HVTIP
  csrs mideleg, t1
  csrr t0, mideleg
  and  t0, t0, t1
  bnez t0, fail
  csrs mie, t1
  csrr t0, mie
  and  t0, t0, t1
  bnez t0, fail

  j pass

  TEST_PASSFAIL

  HTIME_MTVEC_HANDLER

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
