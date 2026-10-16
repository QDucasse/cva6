#!/bin/sh
# Build and run dom_check_tb under Verilator (5.x, with --timing) for several
# numbers of domains and keys. Build trees go to $OUT (default work-dom-check-tb).
set -e
root=$(cd "$(dirname "$0")/../../.." && pwd)
out=${OUT:-$root/work-dom-check-tb}
verilator=${VERILATOR:-verilator}
for dk in "8 8" "4 4" "2 2" "8 2" "2 8"; do
  set -- $dk
  mkdir -p "$out/d$1k$2"
  $verilator --binary --timing -j ${JOBS:-8} -Wno-fatal -Wno-lint -Wno-style \
    -GNrDomains=$1 -GNrKeys=$2 --top-module dom_check_tb --Mdir "$out/d$1k$2" \
    +incdir+"$root/core/include" \
    "$root/core/cvfpu/src/fpnew_pkg.sv" \
    "$root/core/include/config_pkg.sv" \
    "$root/core/include/cv64a6_imafdc_sv39_config_pkg.sv" \
    "$root/core/include/riscv_pkg.sv" \
    "$root/core/include/ariane_pkg.sv" \
    "$root/core/include/build_config_pkg.sv" \
    "$root/core/pmp/src/dom_check.sv" \
    "$root/core/pmp/tb/dom_check_tb.sv" >"$out.log" 2>&1 || { cat "$out.log"; exit 1; }
  "$out/d$1k$2/Vdom_check_tb"
done
