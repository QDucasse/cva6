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
# Hidden-time: boot stock OpenSBI (fw_payload, generic platform) with an
# S-mode payload on the Verilator testharness, on both configs.
#   htime config: rdtime in hardware, Sstc enabled by OpenSBI
#   base config:  rdtime emulated by OpenSBI, no Sstc (payload built -DEXPECT_EMUL)
#
# OpenSBI comes from install-opensbi.sh (tools/opensbi, pinned to v1.7; set
# OPENSBI_DIR to use another checkout). Also needs the riscv64-linux-gnu-
# toolchain (OpenSBI links a PIE, which riscv64-unknown-elf ld cannot do), dtc,
# and the Verilator models in work-ver-<target> (built by htime.sh).
# Each run takes ~6 M cycles (~8 minutes); both run in parallel.

set -euo pipefail

readonly root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly opensbi="${OPENSBI_DIR:-${root}/tools/opensbi}"
readonly cross="${CROSS_COMPILE:-riscv64-linux-gnu-}"
readonly src="${root}/verif/tests/custom/htime/opensbi"
readonly out="${root}/verif/sim/out_htime_opensbi"
readonly htime_target="cv64a6_imafdch_sv39_htime"
readonly base_target="cv64a6_imafdch_sv39"

if [[ ! -d "${opensbi}" ]]; then
  (cd "${root}" && OPENSBI_DIR="${opensbi}" bash verif/regress/install-opensbi.sh)
fi

# build <target> <riscv,isa> <payload cflags...>: leaves ${out}/<target>/fw.elf
# OpenSBI trusts the DT ISA string, so it must match the core: an Sstc entry on
# the feature-off core makes set_timer write stimecmp and trap in M.
build() {
  local target="$1"
  local isa="$2"
  shift 2
  local dir="${out}/${target}"
  rm -rf "${dir}"
  mkdir -p "${dir}"
  sed "s/riscv,isa = \".*\"/riscv,isa = \"${isa}\"/" "${src}/htime_sim.dts" > "${dir}/sim.dts"
  dtc -q -I dts -O dtb -o "${dir}/sim.dtb" "${dir}/sim.dts"
  "${cross}gcc" -march=rv64gch_zicntr -mabi=lp64d -mcmodel=medany -fno-pic -no-pie -nostdlib -nostartfiles -static \
    -T "${src}/payload.ld" "$@" "${src}/payload.S" -o "${dir}/payload.elf"
  "${cross}objcopy" -O binary "${dir}/payload.elf" "${dir}/payload.bin"
  make -s -C "${opensbi}" O="${dir}/opensbi" PLATFORM=generic \
    CROSS_COMPILE="${cross}" FW_TEXT_START=0x80000000 \
    FW_PAYLOAD_PATH="${dir}/payload.bin" FW_PAYLOAD_OFFSET=0x200000 \
    FW_FDT_PATH="${dir}/sim.dtb" -j"$(( $(nproc) > 32 ? 32 : $(nproc) ))" > "${dir}/opensbi.log" 2>&1
  # fw_payload.elf holds the payload as a blob: re-export its tohost/fromhost.
  local sym args=()
  for sym in tohost fromhost; do
    args+=(--add-symbol "${sym}=0x$("${cross}nm" "${dir}/payload.elf" | awk -v s="${sym}" '$3 == s {print $1}'),global")
  done
  "${cross}objcopy" "${args[@]}" "${dir}/opensbi/platform/generic/firmware/fw_payload.elf" \
    "${dir}/fw.elf"
}

# run <target>: simulate ${out}/<target>/fw.elf, log to sim.log
run() {
  local target="$1"
  local dir="${out}/${target}"
  local binary="${root}/work-ver-${target}/Variane_testharness"
  local tohost
  tohost="$("${cross}nm" "${dir}/fw.elf" | awk '$3 == "tohost" {print $1}')"
  (cd "${dir}" && timeout 1800 "${binary}" "${dir}/fw.elf" +debug_disable=1 \
    ++"${dir}/fw.elf" +elf_file="${dir}/fw.elf" +core_name="${target}" \
    +tohost_addr="${tohost}" +time_out=20000000 > sim.log 2>&1) || true
}

# check <target> <regex...>: every regex must match sim.log
check() {
  local target="$1"
  shift
  local log="${out}/${target}/sim.log" re ok=1
  for re in '\*\*\* SUCCESS \*\*\*' 'htime-opensbi: PASS' "$@"; do
    if ! grep -Eq "${re}" "${log}"; then
      echo "[${target}] missing: ${re}"
      ok=0
    fi
  done
  grep -E 'htime-opensbi|Timer Device|ISA Extensions' "${log}" | sed "s/^/[${target}] /"
  if ((ok)); then
    echo "[${target}] PASS"
  else
    echo "[${target}] FAIL (${log})"
  fi
  ((ok))
}

for t in "${htime_target}" "${base_target}"; do
  if [[ ! -x "${root}/work-ver-${t}/Variane_testharness" ]]; then
    echo "Error: work-ver-${t}/Variane_testharness missing (run htime.sh first)" >&2
    exit 1
  fi
done

build "${htime_target}" rv64imafdch_zicntr_zicsr_zifencei_zihpm_sstc
build "${base_target}" rv64imafdch_zicsr_zifencei_zihpm -DEXPECT_EMUL
run "${htime_target}" &
run "${base_target}" &
wait

rc=0
check "${htime_target}" 'ISA Extensions +: .*sstc' 'ISA Extensions +: .*zicntr' \
  'Timer Device +: aclint-mtimer @ 12500000Hz' || rc=1
check "${base_target}" 'Timer Device +: aclint-mtimer @ 12500000Hz' || rc=1
if grep -Eq 'ISA Extensions +: .*sstc' "${out}/${base_target}/sim.log"; then
  echo "[${base_target}] FAIL: sstc reported on the feature-off config"
  rc=1
fi
exit "${rc}"
