# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden-time: access to the eight hidden-time CSRs (htimectl, hexit_time, hhidden_time,
# hvtimecmp, hexit_cycle, hhidden_cycle, hexit_instret, hhidden_instret). Values are only
# checked before any V=1 entry or within a single HS stay, so hardware latching on V edges
# does not interfere.

#include "htime_macros.h"

#define PATTERN_A   0xa5a5a5a55a5a5a5a
#define PATTERN_B   0x123456789abcdef0

# In the current mode, write val to csr and check it reads back as val.
#define CHECK_RW(csr, val)                                              \
  li   t1, val;                                                         \
  PROBE(csrw csr, t1);                                                  \
  EXPECT_NO_FAULT;                                                      \
  PROBE(csrr a1, csr);                                                  \
  EXPECT_NO_FAULT;                                                      \
  bne  a1, t1, fail

# All 64-bit CSRs: full R/W with two patterns.
#define CHECK_RW_ALL(val)                                               \
  CHECK_RW(CSR_HEXIT_TIME_NUM, val);                                    \
  CHECK_RW(CSR_HHIDDEN_TIME_NUM, val);                                  \
  CHECK_RW(CSR_HVTIMECMP_NUM, val);                                     \
  CHECK_RW(CSR_HEXIT_CYCLE_NUM, val);                                   \
  CHECK_RW(CSR_HHIDDEN_CYCLE_NUM, val);                                 \
  CHECK_RW(CSR_HEXIT_INSTRET_NUM, val);                                 \
  CHECK_RW(CSR_HHIDDEN_INSTRET_NUM, val)

# htimectl: only HHAE is writable, reserved bits read 0.
#define CHECK_HTIMECTL                                                  \
  li   t1, -1;                                                          \
  PROBE(csrw CSR_HTIMECTL_NUM, t1);                                     \
  EXPECT_NO_FAULT;                                                      \
  PROBE(csrr a1, CSR_HTIMECTL_NUM);                                     \
  EXPECT_NO_FAULT;                                                      \
  li   t1, HTIMECTL_HHAE;                                               \
  bne  a1, t1, fail;                                                    \
  li   t1, ~HTIMECTL_HHAE;                                              \
  PROBE(csrw CSR_HTIMECTL_NUM, t1);                                     \
  EXPECT_NO_FAULT;                                                      \
  PROBE(csrr a1, CSR_HTIMECTL_NUM);                                     \
  EXPECT_NO_FAULT;                                                      \
  bnez a1, fail

# In the current mode, check reads and writes of csr trap with the given mcause.
#define CHECK_DENIED(csr, cause)                                        \
  li   s11, cause;                                                      \
  PROBE(csrr a1, csr);                                                  \
  bne  s10, s11, fail;                                                  \
  PROBE(csrw csr, zero);                                                \
  bne  s10, s11, fail;                                                  \
  PROBE(csrs csr, zero);                                                \
  bne  s10, s11, fail

#define CHECK_DENIED_ALL(cause)                                         \
  CHECK_DENIED(CSR_HTIMECTL_NUM, cause);                                \
  CHECK_DENIED(CSR_HEXIT_TIME_NUM, cause);                              \
  CHECK_DENIED(CSR_HHIDDEN_TIME_NUM, cause);                            \
  CHECK_DENIED(CSR_HVTIMECMP_NUM, cause);                               \
  CHECK_DENIED(CSR_HEXIT_CYCLE_NUM, cause);                             \
  CHECK_DENIED(CSR_HHIDDEN_CYCLE_NUM, cause);                           \
  CHECK_DENIED(CSR_HEXIT_INSTRET_NUM, cause);                           \
  CHECK_DENIED(CSR_HHIDDEN_INSTRET_NUM, cause)

#define MODE_HS   MSTATUS_MPP_S
#define MODE_U    MSTATUS_MPP_U
#define MODE_VS   (MSTATUS_MPP_S | MSTATUS_MPV)
#define MODE_VU   (MSTATUS_MPP_U | MSTATUS_MPV)

RVTEST_RV64M
RVTEST_CODE_BEGIN

  # 1. All CSRs reset to 0.
  li   TESTNUM, 1
  csrr a1, CSR_HTIMECTL_NUM
  bnez a1, fail
  csrr a1, CSR_HEXIT_TIME_NUM
  bnez a1, fail
  csrr a1, CSR_HHIDDEN_TIME_NUM
  bnez a1, fail
  csrr a1, CSR_HVTIMECMP_NUM
  bnez a1, fail
  csrr a1, CSR_HEXIT_CYCLE_NUM
  bnez a1, fail
  csrr a1, CSR_HHIDDEN_CYCLE_NUM
  bnez a1, fail
  csrr a1, CSR_HEXIT_INSTRET_NUM
  bnez a1, fail
  csrr a1, CSR_HHIDDEN_INSTRET_NUM
  bnez a1, fail

  # 2. R/W from M (all 64 bits); htimectl reserved bits read 0.
  li   TESTNUM, 2
  CHECK_RW_ALL(PATTERN_A)
  CHECK_RW_ALL(-1)
  CHECK_RW_ALL(0)
  CHECK_HTIMECTL

  # 3. R/W from HS.
  li   TESTNUM, 3
  ENTER_MODE(MODE_HS)
  CHECK_RW_ALL(PATTERN_B)
  CHECK_HTIMECTL
  EXIT_TO_M

  # 4. csrs/csrc update only the targeted bits.
  li   TESTNUM, 4
  li   t1, PATTERN_A
  csrw CSR_HHIDDEN_TIME_NUM, t1
  li   t0, 0xff
  csrs CSR_HHIDDEN_TIME_NUM, t0
  csrc CSR_HHIDDEN_TIME_NUM, t0
  csrr a1, CSR_HHIDDEN_TIME_NUM
  li   t1, (PATTERN_A & ~0xff)
  bne  a1, t1, fail
  csrs CSR_HTIMECTL_NUM, HTIMECTL_HHAE
  csrr a1, CSR_HTIMECTL_NUM
  li   t1, HTIMECTL_HHAE
  bne  a1, t1, fail
  csrc CSR_HTIMECTL_NUM, HTIMECTL_HHAE
  csrr a1, CSR_HTIMECTL_NUM
  bnez a1, fail

  # 5. U -> illegal instruction.
  li   TESTNUM, 5
  ENTER_MODE(MODE_U)
  CHECK_DENIED_ALL(CAUSE_ILLEGAL_INSTRUCTION)
  EXIT_TO_M

  # 6. VS -> virtual instruction.
  li   TESTNUM, 6
  ENTER_MODE(MODE_VS)
  CHECK_DENIED_ALL(CAUSE_VIRTUAL_INSTRUCTION)
  EXIT_TO_M

  # 7. VU -> virtual instruction.
  li   TESTNUM, 7
  ENTER_MODE(MODE_VU)
  CHECK_DENIED_ALL(CAUSE_VIRTUAL_INSTRUCTION)
  EXIT_TO_M

  j pass

  TEST_PASSFAIL

  HTIME_MTVEC_HANDLER

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
