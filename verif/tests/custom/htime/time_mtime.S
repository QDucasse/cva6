# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden-time: the time CSR reflects the CLINT mtime and ticks at clk/MTIME_DIV.

#include "htime_macros.h"

#define SPIN_ITERS    1000
# Cycles per mtime tick: ariane_tb.cpp toggles rtc_i every 2 cycles (clk/4);
# the FPGA top toggles it every cycle (clk/2).
#ifndef MTIME_DIV
#define MTIME_DIV     4
#endif
# |MTIME_DIV*dtime - dcycle| bound, in cycles: +-1 tick of quantization plus slack.
#define RATE_SLACK    (2 * MTIME_DIV)

RVTEST_RV64M
RVTEST_CODE_BEGIN

  # 1. time CSR brackets an MMIO read of mtime: t0 <= mtime <= t1.
  li   TESTNUM, 1
  li   s0, CLINT_MTIME
  csrr t0, time
  ld   t1, 0(s0)
  csrr t2, time
  bltu t1, t0, fail
  bltu t2, t1, fail

  # 2. time advances.
  li   TESTNUM, 2
  bgeu t0, t2, fail

  # 3. time ticks at clk/MTIME_DIV: MTIME_DIV*dtime ~= dcycle.
  li   TESTNUM, 3
  csrr t0, time
  csrr t1, mcycle
  li   t2, SPIN_ITERS
1:
  addi t2, t2, -1
  bnez t2, 1b
  csrr t3, time
  csrr t4, mcycle
  sub  t3, t3, t0          # dtime
  sub  t4, t4, t1          # dcycle
  beqz t3, fail
  li   t5, MTIME_DIV
  mul  t3, t3, t5
  sub  t5, t3, t4          # MTIME_DIV*dtime - dcycle
  bgez t5, 2f
  neg  t5, t5
2:
  li   t6, RATE_SLACK
  bgtu t5, t6, fail

  j pass

  TEST_PASSFAIL

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
