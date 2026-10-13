#!/usr/bin/env bash
# Copyright 2026 CentraleSupélec
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Quentin Ducasse - CentraleSupélec (quentin.ducasse@centralesupelec.fr)
#
# Hidden-time: run the bare-metal htime tests on the QEMU virt machine, as a check
# of the QEMU xcvhtime model (CPU property xcvhtime, from the cva6-sdk patches).
# Tests are built with -DHTIME_QEMU, which scales the timing checks to QEMU's
# 10 MHz time and host-TSC mcycle and drops the CVA6-only ones.
#
# The riscv-tests "p" env reports through tohost (HTIF), which virt lacks:
# custom/htime/qemu/riscv_test.h wraps it to write the result to the SiFive test
# device instead, so QEMU exits with status TESTNUM (0 = pass).
#
#   QEMU=<qemu-system-riscv64>  default: ../cva6-sdk/build64_qemu/host/bin/
#   CC=<riscv gcc>              default: riscv64-unknown-elf-gcc

set -euo pipefail

cd "$(dirname "$0")/../.."
readonly root="$PWD"
readonly qemu="${QEMU:-${root}/../cva6-sdk/build64_qemu/host/bin/qemu-system-riscv64}"
readonly cc="${CC:-riscv64-unknown-elf-gcc}"
readonly tests="${root}/verif/tests"
readonly work="${root}/verif/sim/out_htime_qemu"

readonly cpu_on="rv64,h=true,sstc=true,xcvhtime=true"
readonly cpu_off="rv64,h=true,sstc=false,xcvhtime=false"

readonly tests_on=(time_mtime time_counteren time_vs htime_csrs htime_hide_routes
                   htime_hide_hs_ctl htime_hide_view sstc sstc_irq hvti
                   htime_introspect)
readonly tests_off=(time_off)

mkdir -p "${work}"

failed=0

run() {
  local name="$1" cpu="$2"
  local elf="${work}/${name}.elf"
  local status=0

  "${cc}" -march=rv64gch_zicsr_zifencei -mabi=lp64d -static -mcmodel=medany \
    -fvisibility=hidden -nostdlib -nostartfiles -DHTIME_QEMU \
    -I"${tests}/custom/htime/qemu" -I"${tests}/riscv-tests/env/p" \
    -I"${tests}/riscv-tests/isa/macros/scalar" \
    -T"${root}/config/gen_from_riscv_config/linker/link.ld" \
    "${tests}/custom/htime/${name}.S" -o "${elf}"

  timeout 60 "${qemu}" -M virt -cpu "${cpu}" -m 128M -nographic -bios none \
    -kernel "${elf}" > "${work}/${name}.log" 2>&1 || status=$?

  if [[ ${status} -eq 0 ]]; then
    echo "PASS ${name}"
  else
    echo "FAIL ${name} (status ${status}: TESTNUM, or 124 = timeout)"
    failed=1
  fi
}

for t in "${tests_on[@]}"; do run "$t" "${cpu_on}"; done
for t in "${tests_off[@]}"; do run "$t" "${cpu_off}"; done

exit ${failed}
