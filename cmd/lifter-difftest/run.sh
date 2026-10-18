#!/bin/bash
# Usage: run.sh <guest_image.bin> <linear disassembly> <workdir> [compare.py flags]
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
IMG=$1; DIS=$2; OUT=$3; shift 3
mkdir -p "$OUT"
(cd "$ROOT" && go build -o "$OUT/lifter-difftest" ./cmd/lifter-difftest)
"$OUT/lifter-difftest" -image "$IMG" -dis "$DIS" -out "$OUT" -max-per-op ${MAX_PER_OP:-40}
H="$HERE/harness"
clang -arch x86_64 -O1 -I"$H" "$H/native_main.c" "$OUT/native_tests.s" -o "$OUT/native_dt"
clang -O1 -ffp-contract=off -w -I"$H" -I"$ROOT/pkg/runtime/core" "$H/lifted_main.c" "$OUT/lifted_tests.c" -o "$OUT/lifted_dt"
"$OUT/native_dt" "$OUT/native.bin" ${SPECIAL:-0}
"$OUT/lifted_dt" "$OUT/lifted.bin" ${SPECIAL:-0} 2>/dev/null
python3 "$H/compare.py" "$OUT/native.bin" "$OUT/lifted.bin" "$OUT/tests.txt" "$@"
