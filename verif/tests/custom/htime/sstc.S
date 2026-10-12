# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden-time: Sstc access rules (menvcfg/henvcfg.STCE, counteren.TM) and the
# STIP/VSTIP pending view. VSTIP compares vstimecmp against vtime_eff.

#include "htime_macros.h"

#define MODE_HS   MSTATUS_MPP_S
#define MODE_VS   (MSTATUS_MPP_S | MSTATUS_MPV)

# From M: set menvcfg.STCE, henvcfg.STCE and the TM counter-enables.
#define SSTC_CFG(mstce, hstce, mtm, htm)                                \
  li   t0, ENVCFG_STCE;                                                 \
  csrc menvcfg, t0;                                                     \
  csrc henvcfg, t0;                                                     \
  .if mstce;                                                            \
  csrs menvcfg, t0;                                                     \
  .endif;                                                               \
  .if hstce;                                                            \
  csrs henvcfg, t0;                                                     \
  .endif;                                                               \
  li   t0, mtm;                                                         \
  csrw mcounteren, t0;                                                  \
  li   t0, htm;                                                         \
  csrw hcounteren, t0

# From M: enter the mode, probe a read of csr, come back.
#define PROBE_IN(mode, csr)                                             \
  ENTER_MODE(mode);                                                     \
  PROBE(csrr a1, csr);                                                  \
  EXIT_TO_M

# Wait a few cycles for the registered comparators to follow a CSR write.
#define SETTLE                                                          \
  nop; nop; nop; nop; nop; nop; nop; nop

# mip bit set / clear (from M).
#define EXPECT_MIP_SET(bit)                                             \
  SETTLE;                                                               \
  csrr t0, mip;                                                         \
  li   t1, bit;                                                         \
  and  t0, t0, t1;                                                      \
  beqz t0, fail

#define EXPECT_MIP_CLEAR(bit)                                           \
  SETTLE;                                                               \
  csrr t0, mip;                                                         \
  li   t1, bit;                                                         \
  and  t0, t0, t1;                                                      \
  bnez t0, fail

RVTEST_RV64M
RVTEST_CODE_BEGIN

  # The p env delegates ebreak to S; EXIT_TO_M needs it in M.
  csrw medeleg, zero
  csrw mideleg, zero
  csrw hideleg, zero
  csrw hvip, zero
  li   t0, COUNTEREN_TM
  csrw scounteren, t0

  # 1. menvcfg.STCE is R/W from M; henvcfg.STCE reads 0 while menvcfg.STCE=0.
  li   TESTNUM, 1
  SSTC_CFG(0, 1, 0, 0)
  csrr t0, henvcfg
  bltz t0, fail
  csrr t0, menvcfg
  bltz t0, fail
  SSTC_CFG(1, 1, 0, 0)
  csrr t0, menvcfg
  bgez t0, fail
  csrr t0, henvcfg
  bgez t0, fail

  # 2. stimecmp/vstimecmp reset to all ones (QEMU: 0) and are R/W from M regardless of STCE and TM.
  li   TESTNUM, 2
  SSTC_CFG(0, 0, 0, 0)
#ifndef HTIME_QEMU
  li   t0, -1
  csrr a1, CSR_STIMECMP_NUM
  bne  a1, t0, fail
  csrr a1, CSR_VSTIMECMP_NUM
  bne  a1, t0, fail
#endif
  li   t1, 0x1111222233334444
  csrw CSR_STIMECMP_NUM, t1
  csrr a1, CSR_STIMECMP_NUM
  bne  a1, t1, fail
  li   t2, 0x5555666677778888
  csrw CSR_VSTIMECMP_NUM, t2
  csrr a1, CSR_VSTIMECMP_NUM
  bne  a1, t2, fail

  # 3. menvcfg.STCE=0 -> illegal from HS (both CSRs) and VS.
  li   TESTNUM, 3
  SSTC_CFG(0, 1, COUNTEREN_TM, COUNTEREN_TM)
  PROBE_IN(MODE_HS, CSR_STIMECMP_NUM)
  EXPECT_ILLEGAL
  PROBE_IN(MODE_HS, CSR_VSTIMECMP_NUM)
  EXPECT_ILLEGAL
  PROBE_IN(MODE_VS, CSR_STIMECMP_NUM)
  EXPECT_ILLEGAL

  # 4. mcounteren.TM=0 -> illegal from HS (both CSRs) and VS.
  li   TESTNUM, 4
  SSTC_CFG(1, 1, 0, COUNTEREN_TM)
  PROBE_IN(MODE_HS, CSR_STIMECMP_NUM)
  EXPECT_ILLEGAL
  PROBE_IN(MODE_HS, CSR_VSTIMECMP_NUM)
  EXPECT_ILLEGAL
  PROBE_IN(MODE_VS, CSR_STIMECMP_NUM)
  EXPECT_ILLEGAL

  # 5. henvcfg.STCE=0 or hcounteren.TM=0 -> VS stimecmp is a virtual instruction;
  #    HS access is unaffected.
  li   TESTNUM, 5
  SSTC_CFG(1, 0, COUNTEREN_TM, COUNTEREN_TM)
  PROBE_IN(MODE_VS, CSR_STIMECMP_NUM)
  EXPECT_VIRTUAL
  PROBE_IN(MODE_HS, CSR_STIMECMP_NUM)
  EXPECT_NO_FAULT
  PROBE_IN(MODE_HS, CSR_VSTIMECMP_NUM)
  EXPECT_NO_FAULT
  SSTC_CFG(1, 1, COUNTEREN_TM, 0)
  PROBE_IN(MODE_VS, CSR_STIMECMP_NUM)
  EXPECT_VIRTUAL
  # vstimecmp itself from VS -> virtual instruction (HS-level CSR).
  SSTC_CFG(1, 1, COUNTEREN_TM, COUNTEREN_TM)
  PROBE_IN(MODE_VS, CSR_VSTIMECMP_NUM)
  EXPECT_VIRTUAL

  # 6. All enabled: stimecmp in VS is vstimecmp; in HS it is stimecmp.
  li   TESTNUM, 6
  li   t0, -1
  csrw CSR_STIMECMP_NUM, t0
  csrw CSR_VSTIMECMP_NUM, t0
  ENTER_MODE(MODE_VS)
  li   t1, 0x0123456789abcdef
  PROBE(csrw CSR_STIMECMP_NUM, t1)
  EXPECT_NO_FAULT
  PROBE(csrr a1, CSR_STIMECMP_NUM)
  EXPECT_NO_FAULT
  bne  a1, t1, fail
  EXIT_TO_M
  csrr a1, CSR_VSTIMECMP_NUM
  bne  a1, t1, fail
  csrr a1, CSR_STIMECMP_NUM
  li   t0, -1
  bne  a1, t0, fail
  ENTER_MODE(MODE_HS)
  li   t1, 0x7edcba9876543210
  PROBE(csrw CSR_STIMECMP_NUM, t1)
  EXPECT_NO_FAULT
  EXIT_TO_M
  csrr a1, CSR_STIMECMP_NUM
  bne  a1, t1, fail
  csrr a1, CSR_VSTIMECMP_NUM
  li   t0, 0x0123456789abcdef
  bne  a1, t0, fail

  # 7. STIP follows mtime >= stimecmp and ignores mip writes while menvcfg.STCE=1.
  li   TESTNUM, 7
  li   t0, -1
  csrw CSR_STIMECMP_NUM, t0
  EXPECT_MIP_CLEAR(MIP_STIP)
  li   t0, MIP_STIP
  csrs mip, t0
  EXPECT_MIP_CLEAR(MIP_STIP)
  csrw CSR_STIMECMP_NUM, zero
  EXPECT_MIP_SET(MIP_STIP)
  li   t0, MIP_STIP
  csrc mip, t0
  EXPECT_MIP_SET(MIP_STIP)
  # mtime + 1000 ticks: not yet pending.
  li   t0, CLINT_MTIME
  ld   t1, 0(t0)
  addi t1, t1, 1000
  csrw CSR_STIMECMP_NUM, t1
  EXPECT_MIP_CLEAR(MIP_STIP)

  # 8. menvcfg.STCE=0: STIP is software-writable again (legacy SBI timer).
  li   TESTNUM, 8
  csrw CSR_STIMECMP_NUM, zero
  SSTC_CFG(0, 0, COUNTEREN_TM, COUNTEREN_TM)
  EXPECT_MIP_CLEAR(MIP_STIP)
  li   t0, MIP_STIP
  csrs mip, t0
  EXPECT_MIP_SET(MIP_STIP)
  csrc mip, t0
  EXPECT_MIP_CLEAR(MIP_STIP)
  SSTC_CFG(1, 1, COUNTEREN_TM, COUNTEREN_TM)

  # 9. VSTIP = hvip.VSTIP | (vtime_eff >= vstimecmp), only with henvcfg.STCE=1;
  #    hvip shows the software bit only.
  li   TESTNUM, 9
  csrw CSR_HTIMEDELTA_NUM, zero
  csrw CSR_HHIDDEN_TIME_NUM, zero
  csrw CSR_HTIMECTL_NUM, zero
  li   t0, -1
  csrw CSR_VSTIMECMP_NUM, t0
  EXPECT_MIP_CLEAR(MIP_VSTIP_BIT)
  csrw CSR_VSTIMECMP_NUM, zero
  EXPECT_MIP_SET(MIP_VSTIP_BIT)
  csrr t0, hvip
#ifdef HTIME_QEMU
  # QEMU's hvip also echoes the non-VS mip bits (MTIP, STIP) while hvien=0.
  andi t0, t0, MIP_VSTIP_BIT
#endif
  bnez t0, fail
  SSTC_CFG(1, 0, COUNTEREN_TM, COUNTEREN_TM)
  EXPECT_MIP_CLEAR(MIP_VSTIP_BIT)
  li   t0, MIP_VSTIP_BIT
  csrs hvip, t0
  EXPECT_MIP_SET(MIP_VSTIP_BIT)
  csrc hvip, t0
  SSTC_CFG(1, 1, COUNTEREN_TM, COUNTEREN_TM)

  # 10. vtime_eff includes htimedelta and hhidden_time (V=0, HHAE=0: live vtime).
  #     Deadline = mtime + 1000 + DELTA: pending once htimedelta = DELTA + 2000,
  #     clear again once hhidden_time = 4000.
  li   TESTNUM, 10
#define DELTA 0x0000100000000000
  li   t0, CLINT_MTIME
  ld   t1, 0(t0)
  li   t2, DELTA + 1000
  add  t1, t1, t2
  csrw CSR_VSTIMECMP_NUM, t1
  li   t0, DELTA
  csrw CSR_HTIMEDELTA_NUM, t0
  EXPECT_MIP_CLEAR(MIP_VSTIP_BIT)
  li   t0, DELTA + 2000
  csrw CSR_HTIMEDELTA_NUM, t0
  EXPECT_MIP_SET(MIP_VSTIP_BIT)
  li   t0, 4000
  csrw CSR_HHIDDEN_TIME_NUM, t0
  EXPECT_MIP_CLEAR(MIP_VSTIP_BIT)

  # 11. V=0 with HHAE=1: vtime_eff is frozen at hexit_time + htimedelta - hhidden_time.
  li   TESTNUM, 11
  csrw CSR_HTIMEDELTA_NUM, zero
  csrw CSR_HHIDDEN_TIME_NUM, zero
  csrw CSR_HEXIT_TIME_NUM, zero
  li   t0, 1
  csrw CSR_VSTIMECMP_NUM, t0
  EXPECT_MIP_SET(MIP_VSTIP_BIT)
  csrwi CSR_HTIMECTL_NUM, HTIMECTL_HHAE
  EXPECT_MIP_CLEAR(MIP_VSTIP_BIT)
  csrwi CSR_HEXIT_TIME_NUM, 1
  EXPECT_MIP_SET(MIP_VSTIP_BIT)
  csrwi CSR_HHIDDEN_TIME_NUM, 1
  EXPECT_MIP_CLEAR(MIP_VSTIP_BIT)
  csrw CSR_HTIMECTL_NUM, zero
  EXPECT_MIP_SET(MIP_VSTIP_BIT)

  j pass

  TEST_PASSFAIL

  HTIME_MTVEC_HANDLER

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
