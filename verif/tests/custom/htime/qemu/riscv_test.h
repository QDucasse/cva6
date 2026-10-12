// Copyright 2026 CentraleSupélec
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
//
// riscv-tests "p" env for QEMU virt, used by verif/regress/htime_qemu.sh (this
// directory goes before env/p on the include path). virt has no HTIF, so
// RVTEST_PASS/RVTEST_FAIL write the result to the SiFive test device instead of
// tohost, and QEMU exits with status TESTNUM (0 = pass). The default trap handler
// still writes tohost: an unexpected exception shows up as a timeout.

#ifndef _HTIME_QEMU_RISCV_TEST_H
#define _HTIME_QEMU_RISCV_TEST_H

#include_next "riscv_test.h"

#define VIRT_TEST       0x100000
#define VIRT_TEST_PASS  0x5555
#define VIRT_TEST_FAIL  0x3333

#undef RVTEST_PASS
#define RVTEST_PASS                                                     \
        fence;                                                          \
        li t5, VIRT_TEST;                                               \
        li t6, VIRT_TEST_PASS;                                          \
        sw t6, 0(t5);                                                   \
42:     j 42b

// (TESTNUM << 16) | 0x3333 = fail, QEMU exit status TESTNUM.
#undef RVTEST_FAIL
#define RVTEST_FAIL                                                     \
        fence;                                                          \
1:      beqz TESTNUM, 1b;                                               \
        slli t6, TESTNUM, 16;                                           \
        li t5, VIRT_TEST_FAIL;                                          \
        or t6, t6, t5;                                                  \
        li t5, VIRT_TEST;                                               \
        sw t6, 0(t5);                                                   \
42:     j 42b

#endif
