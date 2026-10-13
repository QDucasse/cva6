// Copyright 2026 CentraleSupélec
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
//
// Shared helpers for the hidden-time extension tests.
// Tests start in M mode (RVTEST_RV64M) with the riscv-tests "p" environment.
//
// Register conventions:
//   s10 : mcause of the last fault recorded by mtvec_handler (0 = none)
//   t5, t6 : clobbered by the trap path

#ifndef HTIME_MACROS_H
#define HTIME_MACROS_H

#include "riscv_test.h"
#include "test_macros.h"

// QEMU virt (-DHTIME_QEMU): time is a 10 MHz clock, mcycle the host TSC and an exit
// costs microseconds of host time. MTIME_DIV is then only an upper bound on cycles
// per tick (TSC <= 10 GHz); spins and bounds are scaled to match. Checks that rely
// on the CVA6 timing or reset values are left out.
#ifdef HTIME_QEMU
#define MTIME_DIV     1000
#define SPIN_CYCLES   20000000
#define BOUND_TICKS   1000
#define BOUND_CYCLES  1000000
#define OFFSET        0x100000000
#endif

#define CLINT_MTIME     0x0200bff8

#define COUNTEREN_TM    (1 << 1)
#define MSTATUS_MPP_U   (0 << 11)
#define MSTATUS_MPP_S   (1 << 11)
#define MSTATUS_MPV     (1 << 39)
#define CAUSE_VIRTUAL_INSTRUCTION 22

#define CSR_HTIMEDELTA_NUM  0x605
#define CSR_HTIMEDELTAH_NUM 0x615
#define CSR_HTIMECTL_NUM      0x6c0
#define CSR_HEXIT_TIME_NUM    0x6c1
#define CSR_HHIDDEN_TIME_NUM  0x6c2
#define CSR_HVTIMECMP_NUM     0x6c3
#define CSR_HEXIT_CYCLE_NUM   0x6c4
#define CSR_HHIDDEN_CYCLE_NUM 0x6c5
#define CSR_HEXIT_INSTRET_NUM   0x6c6
#define CSR_HHIDDEN_INSTRET_NUM 0x6c7

#define HTIMECTL_HHAE   (1 << 0)

// Sstc
#define CSR_STIMECMP_NUM    0x14d
#define CSR_VSTIMECMP_NUM   0x24d
#define ENVCFG_STCE         (1 << 63)
#define MIP_VSSIP_BIT       (1 << 2)
#define MIP_VSTIP_BIT       (1 << 6)
#define HSTATUS_VTW_BIT     (1 << 21)

// Interrupt 24: hypervisor virtual-time interrupt (hvtimecmp)
#define IRQ_HVTI            24
#define MIP_HVTIP           (1 << IRQ_HVTI)

// Drop from M to the mode given by mpp_val (MSTATUS_MPP_*), continuing at the next instruction.
// Set MSTATUS_MPV in mpp_val to enter VS/VU instead of HS/U.
#define ENTER_MODE(mpp_val)                                             \
  li   t0, MSTATUS_MPP | MSTATUS_MPV;                                   \
  csrc mstatus, t0;                                                     \
  li   t0, (mpp_val);                                                   \
  csrs mstatus, t0;                                                     \
  la   t0, 1f;                                                          \
  csrw mepc, t0;                                                        \
  mret;                                                                 \
1:

// Return to M from any mode (handled by mtvec_handler via ebreak).
#define EXIT_TO_M                                                       \
  .option push;                                                         \
  .option norvc;                                                        \
  ebreak;                                                               \
  .option pop

// Run one 4-byte instruction, recording any trap cause in s10.
#define PROBE(...)                                                      \
  li s10, 0;                                                            \
  __VA_ARGS__

#define EXPECT_NO_FAULT   bnez s10, fail
#define EXPECT_ILLEGAL    li t0, CAUSE_ILLEGAL_INSTRUCTION; bne s10, t0, fail
#define EXPECT_VIRTUAL    li t0, CAUSE_VIRTUAL_INSTRUCTION; bne s10, t0, fail

// M-mode handler:
//   ebreak            -> return to M after the ebreak
//   illegal / virtual -> record mcause in s10 and skip the faulting instruction
//   anything else     -> fail
#define HTIME_MTVEC_HANDLER                                             \
  .align 2;                                                             \
  .global mtvec_handler;                                                \
mtvec_handler:                                                          \
  csrr t5, mcause;                                                      \
  li   t6, CAUSE_BREAKPOINT;                                            \
  bne  t5, t6, 1f;                                                      \
  li   t6, MSTATUS_MPP;                                                 \
  csrs mstatus, t6;                                                     \
  j    2f;                                                              \
1:                                                                      \
  li   t6, CAUSE_ILLEGAL_INSTRUCTION;                                   \
  beq  t5, t6, 3f;                                                      \
  li   t6, CAUSE_VIRTUAL_INSTRUCTION;                                \
  bne  t5, t6, fail;                                                    \
3:                                                                      \
  mv   s10, t5;                                                         \
2:                                                                      \
  csrr t6, mepc;                                                        \
  addi t6, t6, 4;                                                       \
  csrw mepc, t6;                                                        \
  mret

#endif
