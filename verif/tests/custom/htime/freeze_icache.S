# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden freeze, instruction cache. The guest runs a block of
# GUEST_CODE bytes, then exits to HS with HFRZ armed. The frozen HS handler runs HV_CODE bytes of
# straight-line code (twice the cache, so without the freeze every guest line is evicted and the
# LFSR moves), counting the instructions it ran. The guest runs its block again. The testbench
# freeze monitor checks that the caches' tags and LFSRs didn't change while frozen
# (freeze_mon_mask in testlist_htime.yaml).
#
# Expected windows: xret (the ecall exit), hfrz0 (the final ebreak to M, ended in M).

#include "htime_macros.h"

#define CAUSE_VS_ECALL  10
#define MODE_VS         (MSTATUS_MPP_S | MSTATUS_MPV)
#define GUEST_CODE      4096
#define HV_CODE         (32 * 1024)

RVTEST_RV64M
RVTEST_CODE_BEGIN

  li   TESTNUM, 1
  csrw medeleg, zero
  li   t0, (1 << CAUSE_VS_ECALL)
  csrs medeleg, t0
  la   t0, stvec_handler
  csrw stvec, t0

  li   t0, HTIMECTL_HFRZ
  csrw CSR_HTIMECTL_NUM, t0
  ENTER_MODE(MODE_VS)

  # Guest: run its block, exit, run it again.
  li   a0, 0
  jal  guest_block
  li   t0, GUEST_CODE / 4
  bne  a0, t0, fail
  li   TESTNUM, 2
  ecall
  li   TESTNUM, 3
  li   a0, 0
  jal  guest_block
  li   t0, GUEST_CODE / 4
  bne  a0, t0, fail

  EXIT_TO_M
  csrw CSR_HTIMECTL_NUM, zero

  j pass

  TEST_PASSFAIL

  # Straight-line blocks of 4-byte instructions, each adding 1 to a0.
  .option push
  .option norvc
  .align 6
guest_block:
  .rept GUEST_CODE / 4
  addi a0, a0, 1
  .endr
  ret

  # HS exit handler (frozen): run the hypervisor block.
  .align 6
stvec_handler:
  csrr t5, scause
  li   t6, CAUSE_VS_ECALL
  beq  t5, t6, 1f
  j    fail
1:
  li   a0, 0
  .rept HV_CODE / 4
  addi a0, a0, 1
  .endr
  li   t5, HV_CODE / 4
  beq  a0, t5, 1f
  j    fail
1:
  csrr t6, sepc
  addi t6, t6, 4
  csrw sepc, t6
  sret
  .option pop

  HTIME_MTVEC_HANDLER

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
RVTEST_DATA_END
