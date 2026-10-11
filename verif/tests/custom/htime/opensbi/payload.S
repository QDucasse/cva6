# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# htime: S-mode payload booted by stock OpenSBI (fw_payload).
#
# With RVHiddenTime, rdtime must not trap to OpenSBI and Sstc must be enabled
# (menvcfg.STCE, mcounteren.TM). Built with -DEXPECT_EMUL for the feature-off
# config, where rdtime is emulated by OpenSBI and Sstc is absent.
#
#  1. rdtime is nonzero and advances
#  2. rdtime cost: < RDTIME_HW_MAX cycles in hardware, > RDTIME_EMUL_MIN when emulated
#  3. SBI set_timer: STIP rises after the deadline, clears on set_timer(-1)
#  4. (htime only) direct stimecmp write from S: STIP rises, clears on stimecmp = -1
#
# Result goes to tohost: 1 on pass, (TESTNUM << 1) | 1 on fail.

#define CSR_STIMECMP   0x14d
#define SIP_STIP       (1 << 5)
#define SBI_EXT_TIME   0x54494D45
#define SBI_EXT_DBCN   0x4442434E
#define RDTIME_HW_MAX   50
#define RDTIME_EMUL_MIN 100
#define TIMER_DELTA     200
#define WAIT_LOOPS      100000

#define TESTNUM s11

  .section .text.init
  .globl _start
_start:
  la    sp, stack_top
  la    a0, msg_hello
  call  puts

  # 1. rdtime nonzero and advancing
  li    TESTNUM, 1
  rdtime s0
  beqz  s0, fail
  li    t0, 1000
1:addi  t0, t0, -1
  bnez  t0, 1b
  rdtime s1
  bleu  s1, s0, fail

  # 2. rdtime cost (second sample, after the first warmed the path)
  li    TESTNUM, 2
  rdtime t0
  rdcycle s0
  rdtime t0
  rdcycle s1
  sub   s2, s1, s0
  la    a0, msg_cost
  call  puts
  mv    a0, s2
  call  puthex
#ifdef EXPECT_EMUL
  li    t0, RDTIME_EMUL_MIN
  bltu  s2, t0, fail
#else
  li    t0, RDTIME_HW_MAX
  bgeu  s2, t0, fail
#endif

  # 3. SBI set_timer
  li    TESTNUM, 3
  csrc  sstatus, 2            # SIE=0: poll, no trap
  li    t0, SIP_STIP
  csrs  sie, t0
  rdtime s0
  addi  a0, s0, TIMER_DELTA
  mv    s1, a0
  li    a7, SBI_EXT_TIME
  li    a6, 0
  ecall
  bnez  a0, fail
  call  wait_stip
  rdtime t0
  bltu  t0, s1, fail          # not before the deadline
  li    a0, -1
  li    a7, SBI_EXT_TIME
  li    a6, 0
  ecall
  csrr  t0, sip
  andi  t0, t0, SIP_STIP
  bnez  t0, fail

#ifndef EXPECT_EMUL
  # 4. direct stimecmp from S (needs menvcfg.STCE and mcounteren.TM)
  li    TESTNUM, 4
  rdtime s0
  addi  s1, s0, TIMER_DELTA
  csrw  CSR_STIMECMP, s1
  call  wait_stip
  rdtime t0
  bltu  t0, s1, fail
  li    t0, -1
  csrw  CSR_STIMECMP, t0
  li    t1, 16
1:csrr  t0, sip
  andi  t0, t0, SIP_STIP
  beqz  t0, 2f
  addi  t1, t1, -1
  bnez  t1, 1b
  j     fail
2:
#endif

  la    a0, msg_time
  call  puts
  rdtime a0
  call  puthex
  la    a0, msg_pass
  call  puts
  li    t0, 1
  j     exit

fail:
  la    a0, msg_fail
  call  puts
  mv    a0, TESTNUM
  call  puthex
  slli  t0, TESTNUM, 1
  ori   t0, t0, 1
exit:
  la    t1, tohost
  sd    t0, 0(t1)
1:j     1b

# Wait for sip.STIP with WFI; fail after WAIT_LOOPS wakeups.
wait_stip:
  li    t1, WAIT_LOOPS
1:csrr  t0, sip
  andi  t0, t0, SIP_STIP
  bnez  t0, 2f
  wfi
  addi  t1, t1, -1
  bnez  t1, 1b
  j     fail
2:ret

# SBI DBCN write_byte for each char of the string at a0.
puts:
  mv    t2, a0
1:lbu   a0, 0(t2)
  beqz  a0, 2f
  li    a7, SBI_EXT_DBCN
  li    a6, 2
  ecall
  addi  t2, t2, 1
  j     1b
2:ret

# Print a0 as 0x + 16 hex digits and a newline.
puthex:
  addi  sp, sp, -32
  sd    ra, 0(sp)
  la    t3, hexbuf + 2
  li    t4, 60
1:srl   t5, a0, t4
  andi  t5, t5, 0xf
  li    t6, 10
  blt   t5, t6, 2f
  addi  t5, t5, 'a' - 10 - '0'
2:addi  t5, t5, '0'
  sb    t5, 0(t3)
  addi  t3, t3, 1
  addi  t4, t4, -4
  bgez  t4, 1b
  la    a0, hexbuf
  call  puts
  ld    ra, 0(sp)
  addi  sp, sp, 32
  ret

  .section .rodata
msg_hello: .asciz "\nhtime-opensbi: S-mode payload\n"
msg_cost:  .asciz "htime-opensbi: rdtime cost (cycles) "
msg_time:  .asciz "htime-opensbi: rdtime "
msg_pass:  .asciz "htime-opensbi: PASS\n"
msg_fail:  .asciz "htime-opensbi: FAIL test "

  .section .tohost, "aw", @progbits
  .align 6
  .globl tohost
tohost:   .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0

  .data
hexbuf: .ascii "0x0000000000000000\n\0"
  .align 4
  .space 4096
stack_top:
