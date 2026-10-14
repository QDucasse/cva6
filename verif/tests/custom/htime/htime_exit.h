// Copyright 2026 CentraleSupélec
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
//
// Shared harness for the hidden-time exit tests (latch, accumulate, vtime/vcycle).
//
// The guest (VS) reads time/cycle, takes an exit with ecall, and reads them again.
// The exit goes V->HS->V (medeleg[10]=1), V->M->V (medeleg[10]=0), or V->HS->M->HS->V
// (HS takes an illegal instruction to M). Each handler spins SPIN_CYCLES cycles.
//
// Exit handler contract (HS and M), on a VS ecall:
//   in : a5 = action run before returning (ACT_*), a7 != 0 -> HS detours through M
//        s9 = offset for ACT_ADD_HIDDEN / ACT_SUB_EXIT
//   out: a0 = hexit_time, a1 = hhidden_time, a2 = hexit_cycle, a3 = hhidden_cycle (at entry)
//        a4 = hexit_time after the M detour (nested exits only)
//   clobbers t5, t6, s11
//
// Tests run HTIME_EXIT_INIT first and place HTIME_EXIT_HANDLERS after TEST_PASSFAIL.

#ifndef HTIME_EXIT_H
#define HTIME_EXIT_H

#include "htime_macros.h"

#ifndef MTIME_DIV
#define MTIME_DIV     4
#endif
#ifndef SPIN_CYCLES
#define SPIN_CYCLES   20000
#endif
// Guest-visible delta across a warm hidden exit: B ticks, 2*B cycles.
#ifndef BOUND_TICKS
#define BOUND_TICKS   8
#endif
#ifndef BOUND_CYCLES
#define BOUND_CYCLES  (2 * BOUND_TICKS)
#endif

#define DELTA         0x0000100000000000
#ifndef OFFSET
#define OFFSET        (1 << 24)
#endif

#define COUNTEREN_CY  (1 << 0)
#define CAUSE_VS_ECALL 10

#define ACT_NONE        0
#define ACT_SET_HHAE    1
#define ACT_CLEAR_HHAE  2
#define ACT_ADD_HIDDEN  3   // hhidden_* += s9
#define ACT_SUB_EXIT    4   // hexit_*   -= s9
#define ACT_CLEAR_HFRZ  5
#define ACT_SET_HFRZ    6

#define ROUTE_M   0
#define ROUTE_HS  1

#define MODE_HS   MSTATUS_MPP_S
#define MODE_VS   (MSTATUS_MPP_S | MSTATUS_MPV)

// From M: one warm-up exit, then a measured one.
//   s2/s4 = guest time before/after, s3/s5 = guest cycle before/after.
#define MEASURE(route, hhae, action, nest)                              \
  li   t0, (1 << CAUSE_VS_ECALL);                                       \
  .if route;                                                            \
  csrs medeleg, t0;                                                     \
  .else;                                                                \
  csrc medeleg, t0;                                                     \
  .endif;                                                               \
  li   t0, hhae;                                                        \
  csrw CSR_HTIMECTL_NUM, t0;                                            \
  li   a7, nest;                                                        \
  li   s9, OFFSET;                                                      \
  ENTER_MODE(MODE_VS);                                                  \
  li   a5, ACT_NONE;                                                    \
  ecall;                                                                \
  li   a5, action;                                                      \
  csrr s2, time;                                                        \
  csrr s3, cycle;                                                       \
  ecall;                                                                \
  csrr s5, cycle;                                                       \
  csrr s4, time;                                                        \
  EXIT_TO_M;                                                            \
  csrw CSR_HTIMECTL_NUM, zero

// Exit was hidden: guest deltas within the bounds.
#define EXPECT_HIDDEN                                                   \
  sub  t0, s4, s2;                                                      \
  li   t1, BOUND_TICKS;                                                 \
  bltu t1, t0, fail;                                                    \
  sub  t0, s5, s3;                                                      \
  li   t1, BOUND_CYCLES;                                                \
  bltu t1, t0, fail

// Exit was visible: guest deltas cover at least the handler spin.
#define EXPECT_VISIBLE                                                  \
  sub  t0, s4, s2;                                                      \
  li   t1, SPIN_CYCLES / MTIME_DIV;                                     \
  bltu t0, t1, fail;                                                    \
  sub  t0, s5, s3;                                                      \
  li   t1, SPIN_CYCLES;                                                 \
  bltu t0, t1, fail

// hexit_* were latched just after the guest's last reads:
//   0 <= hexit_time  - (s2 - DELTA + hhidden_time)  <= BOUND_TICKS
//   0 <= hexit_cycle - (s3 + hhidden_cycle)         <= BOUND_CYCLES
#define EXPECT_LATCH                                                    \
  li   t1, DELTA;                                                       \
  sub  t0, s2, t1;                                                      \
  add  t0, t0, a1;                                                      \
  sub  t0, a0, t0;                                                      \
  li   t1, BOUND_TICKS;                                                 \
  bltu t1, t0, fail;                                                    \
  add  t0, s3, a3;                                                      \
  sub  t0, a2, t0;                                                      \
  li   t1, BOUND_CYCLES;                                                \
  bltu t1, t0, fail

// hhidden_* did not change across the measured exit.
#define EXPECT_NO_ACCUMULATE                                            \
  csrr t0, CSR_HHIDDEN_TIME_NUM;                                        \
  bne  t0, a1, fail;                                                    \
  csrr t0, CSR_HHIDDEN_CYCLE_NUM;                                       \
  bne  t0, a3, fail

// hhidden_* grew by at least the handler spin across the measured exit.
#define EXPECT_ACCUMULATE                                               \
  csrr t0, CSR_HHIDDEN_TIME_NUM;                                        \
  sub  t0, t0, a1;                                                      \
  li   t1, SPIN_CYCLES / MTIME_DIV;                                     \
  bltu t0, t1, fail;                                                    \
  csrr t0, CSR_HHIDDEN_CYCLE_NUM;                                       \
  sub  t0, t0, a3;                                                      \
  li   t1, SPIN_CYCLES;                                                 \
  bltu t0, t1, fail

// Spin for SPIN_CYCLES using the given cycle counter CSR.
#define SPIN(cnt)                                                       \
  csrr t5, cnt;                                                         \
9:                                                                      \
  csrr t6, cnt;                                                         \
  sub  t6, t6, t5;                                                      \
  li   s11, SPIN_CYCLES;                                                \
  bltu t6, s11, 9b

// Common part of the HS and M exit handlers.
#define EXIT_HANDLER_HEAD(cnt)                                          \
  csrr a0, CSR_HEXIT_TIME_NUM;                                          \
  csrr a1, CSR_HHIDDEN_TIME_NUM;                                        \
  csrr a2, CSR_HEXIT_CYCLE_NUM;                                         \
  csrr a3, CSR_HHIDDEN_CYCLE_NUM;                                       \
  SPIN(cnt)

#define EXIT_HANDLER_ACTION                                             \
  li   t5, ACT_SET_HHAE;                                                \
  bne  a5, t5, 1f;                                                      \
  csrsi CSR_HTIMECTL_NUM, HTIMECTL_HHAE;                                \
1:                                                                      \
  li   t5, ACT_CLEAR_HHAE;                                              \
  bne  a5, t5, 2f;                                                      \
  csrci CSR_HTIMECTL_NUM, HTIMECTL_HHAE;                                \
2:                                                                      \
  li   t5, ACT_ADD_HIDDEN;                                              \
  bne  a5, t5, 3f;                                                      \
  csrr t6, CSR_HHIDDEN_TIME_NUM;                                        \
  add  t6, t6, s9;                                                      \
  csrw CSR_HHIDDEN_TIME_NUM, t6;                                        \
  csrr t6, CSR_HHIDDEN_CYCLE_NUM;                                       \
  add  t6, t6, s9;                                                      \
  csrw CSR_HHIDDEN_CYCLE_NUM, t6;                                       \
3:                                                                      \
  li   t5, ACT_SUB_EXIT;                                                \
  bne  a5, t5, 4f;                                                      \
  csrr t6, CSR_HEXIT_TIME_NUM;                                          \
  sub  t6, t6, s9;                                                      \
  csrw CSR_HEXIT_TIME_NUM, t6;                                          \
  csrr t6, CSR_HEXIT_CYCLE_NUM;                                         \
  sub  t6, t6, s9;                                                      \
  csrw CSR_HEXIT_CYCLE_NUM, t6;                                         \
4:                                                                      \
  li   t5, ACT_CLEAR_HFRZ;                                              \
  bne  a5, t5, 15f;                                                     \
  csrci CSR_HTIMECTL_NUM, HTIMECTL_HFRZ;                                \
15:                                                                     \
  li   t5, ACT_SET_HFRZ;                                                \
  bne  a5, t5, 16f;                                                     \
  csrsi CSR_HTIMECTL_NUM, HTIMECTL_HFRZ;                                \
16:

// From M: route traps for the exit handlers, enable time/cycle everywhere, set htimedelta.
// The p env delegates ebreak to S; EXIT_TO_M needs it in M.
#define HTIME_EXIT_INIT                                                 \
  csrw medeleg, zero;                                                   \
  la   t0, stvec_handler;                                               \
  csrw stvec, t0;                                                       \
  li   t0, COUNTEREN_TM | COUNTEREN_CY;                                 \
  csrw mcounteren, t0;                                                  \
  csrw hcounteren, t0;                                                  \
  csrw scounteren, t0;                                                  \
  li   t0, DELTA;                                                       \
  csrw CSR_HTIMEDELTA_NUM, t0

// HS handler: VS ecall exits only; with a7 != 0, detour through M (mcycle is illegal in HS).
// M handler:
//   ebreak          -> return to M after the ebreak
//   VS ecall        -> exit handler, back to VS
//   illegal from HS -> nested detour: spin, back to HS
#define HTIME_EXIT_HANDLERS                                             \
  .align 2;                                                             \
stvec_handler:                                                          \
  csrr t5, scause;                                                      \
  li   t6, CAUSE_VS_ECALL;                                              \
  bne  t5, t6, fail;                                                    \
  EXIT_HANDLER_HEAD(cycle);                                             \
  beqz a7, 5f;                                                          \
  csrr t6, mcycle;                                                      \
  csrr a4, CSR_HEXIT_TIME_NUM;                                          \
5:                                                                      \
  EXIT_HANDLER_ACTION;                                                  \
  csrr t6, sepc;                                                        \
  addi t6, t6, 4;                                                       \
  csrw sepc, t6;                                                        \
  sret;                                                                 \
                                                                        \
  .align 2;                                                             \
  .global mtvec_handler;                                                \
mtvec_handler:                                                          \
  csrr t5, mcause;                                                      \
  li   t6, CAUSE_BREAKPOINT;                                            \
  bne  t5, t6, 6f;                                                      \
  li   t6, MSTATUS_MPV;                                                 \
  csrc mstatus, t6;                                                     \
  li   t6, MSTATUS_MPP;                                                 \
  csrs mstatus, t6;                                                     \
  j    8f;                                                              \
6:                                                                      \
  li   t6, CAUSE_VS_ECALL;                                              \
  bne  t5, t6, 7f;                                                      \
  EXIT_HANDLER_HEAD(mcycle);                                            \
  EXIT_HANDLER_ACTION;                                                  \
  j    8f;                                                              \
7:                                                                      \
  li   t6, CAUSE_ILLEGAL_INSTRUCTION;                                   \
  bne  t5, t6, fail;                                                    \
  SPIN(mcycle);                                                         \
8:                                                                      \
  csrr t6, mepc;                                                        \
  addi t6, t6, 4;                                                       \
  csrw mepc, t6;                                                        \
  mret

#endif
