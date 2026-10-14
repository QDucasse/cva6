# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden freeze, data cache. The guest loads GUEST_SIZE bytes,
# then exits to HS with HFRZ armed. The frozen HS handler loads HV_SIZE bytes (more than the
# cache, so without the freeze every guest line is evicted and the LFSR moves), checks the
# values it loaded, stores to its own buffer (store miss) and to a guest line (store hit), and
# runs AMOs: amoadd on a guest line (cached: only its way is invalidated) and on its own buffer
# (not cached: nothing invalidated), LR/SC on a guest line. Back in the guest, every value
# written must be seen. The testbench freeze monitor checks that the data-cache tags and LFSR
# didn't change while frozen, apart from the AMOs' way invalidations (freeze_mon_mask in
# testlist_htime.yaml).
#
# Expected windows: xret (the ecall exit), hfrz0 (the final ebreak to M, ended in M).

#include "htime_macros.h"

#define CAUSE_VS_ECALL  10
#define MODE_VS         (MSTATUS_MPP_S | MSTATUS_MPV)
#define LINE            16          // one load per 16 bytes: every line, whatever its size
#define GUEST_SIZE      4096
#define HV_SIZE         (48 * 1024)
#define HV_MAGIC        0x5a5a0000
#define GUEST_MAGIC     0x0123456789abcdef
#define AMO_ADD         5
#define SC_VAL          7

RVTEST_RV64M
RVTEST_CODE_BEGIN

  li   TESTNUM, 1
  csrw medeleg, zero
  li   t0, (1 << CAUSE_VS_ECALL)
  csrs medeleg, t0
  la   t0, stvec_handler
  csrw stvec, t0

  # hv_buf[i] = HV_MAGIC + i every LINE bytes, before any of it is cached
  # (stores don't allocate in the write-through data cache)
  la   t0, hv_buf
  li   t1, HV_SIZE / LINE
  li   t2, HV_MAGIC
1:
  sd   t2, 0(t0)
  addi t0, t0, LINE
  addi t2, t2, 1
  addi t1, t1, -1
  bnez t1, 1b

  li   t0, HTIMECTL_HFRZ
  csrw CSR_HTIMECTL_NUM, t0
  ENTER_MODE(MODE_VS)

  # Guest: bring its buffer into the cache, exit, then see the handler's store.
  la   t0, guest_buf
  li   t1, GUEST_SIZE / LINE
1:
  ld   zero, 0(t0)
  addi t0, t0, LINE
  addi t1, t1, -1
  bnez t1, 1b
  li   TESTNUM, 2
  ecall
  li   TESTNUM, 3
  la   t0, guest_buf
  ld   t1, 8(t0)
  li   t2, GUEST_MAGIC
  bne  t1, t2, fail
  ld   t1, 64(t0)
  li   t2, AMO_ADD
  bne  t1, t2, fail
  ld   t1, 128(t0)
  li   t2, SC_VAL
  bne  t1, t2, fail

  EXIT_TO_M
  csrw CSR_HTIMECTL_NUM, zero

  j pass

  TEST_PASSFAIL

  # HS exit handler (frozen): read the hypervisor buffer, store a miss and a hit.
  .align 2
stvec_handler:
  csrr t5, scause
  li   t6, CAUSE_VS_ECALL
  bne  t5, t6, fail
  la   t0, hv_buf
  li   t1, HV_SIZE / LINE
  li   t2, HV_MAGIC
1:
  ld   t3, 0(t0)
  bne  t3, t2, fail
  addi t0, t0, LINE
  addi t2, t2, 1
  addi t1, t1, -1
  bnez t1, 1b
  la   t0, hv_buf
  sd   t2, 0(t0)
  la   t0, guest_buf
  li   t1, GUEST_MAGIC
  sd   t1, 8(t0)
  # AMOs: guest line (cached), own buffer (not cached), LR/SC on a guest line
  li   t1, AMO_ADD
  addi t2, t0, 64
  amoadd.d t3, t1, (t2)
  bnez t3, fail
  la   t2, hv_buf + LINE
  amoadd.d t3, t1, (t2)
  li   t4, HV_MAGIC + 1
  bne  t3, t4, fail
  addi t2, t0, 128
  li   t1, SC_VAL
1:
  lr.d t3, (t2)
  bnez t3, fail
  sc.d t4, t1, (t2)
  bnez t4, 1b
  csrr t6, sepc
  addi t6, t6, 4
  csrw sepc, t6
  sret

  HTIME_MTVEC_HANDLER

RVTEST_CODE_END

RVTEST_DATA_BEGIN
  TEST_DATA
  .align 12
guest_buf:
  .skip GUEST_SIZE
hv_buf:
  .skip HV_SIZE
RVTEST_DATA_END
