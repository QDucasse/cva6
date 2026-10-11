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
# Hidden-time extension regression: htime tests on the htime config, feature-off
# checks and existing H tests on both configs.
# Set HTIME_QUICK=1 to skip the riscv-tests p/v suites.

set -eo pipefail

if [[ -z "${RISCV:-}" ]]; then
  echo "Error: RISCV variable undefined" >&2
  exit 1
fi

source verif/sim/setup-env.sh
set -u

# Self-checking tests; Spike's mtime does not follow the testbench rtc_i timebase.
unset SPIKE_TANDEM

readonly htime_target="cv64a6_imafdch_sv39_htime"
readonly base_target="cv64a6_imafdch_sv39"
readonly linker="../../config/gen_from_riscv_config/linker/link.ld"

cd verif/sim

run() {
  local testlist="$1"
  local target="$2"
  shift 2

  python3 cva6.py \
    --testlist="../tests/${testlist}" \
    --target="${target}" \
    --iss_yaml=cva6.yaml \
    --iss=veri-testharness \
    --linker="${linker}" \
    --issrun_opts=+debug_disable=1 \
    "$@"
}

for target in "${htime_target}" "${base_target}"; do
  # The generated model does not track configuration changes.
  make -C ../.. clean

  if [[ "${target}" == "${htime_target}" ]]; then
    run testlist_htime.yaml "${target}" --test=rv64h-p-htime-time-mtime
    run testlist_htime.yaml "${target}" --test=rv64h-p-htime-time-counteren
    run testlist_htime.yaml "${target}" --test=rv64h-p-htime-time-vs
    run testlist_htime.yaml "${target}" --test=rv64h-p-htime-csrs
    run testlist_htime.yaml "${target}" --test=rv64h-p-htime-hide-routes
    run testlist_htime.yaml "${target}" --test=rv64h-p-htime-hide-hs-ctl
    run testlist_htime.yaml "${target}" --test=rv64h-p-htime-hide-view
  else
    run testlist_htime.yaml "${target}" --test=rv64h-p-htime-time-off
  fi

  run testlist_hlvx_gstage.yaml "${target}"
  run testlist_hgatp_warl.yaml "${target}"

  if [[ -z "${HTIME_QUICK:-}" ]]; then
    run testlist_riscv-tests-cv64a6_imafdc_sv39-p.yaml "${target}"
    run testlist_riscv-tests-cv64a6_imafdc_sv39-v.yaml "${target}"
  fi
done
