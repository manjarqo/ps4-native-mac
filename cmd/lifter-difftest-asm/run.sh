#!/bin/bash
# Differential test of the ARM64 assembly lifter against x86-64 under Rosetta 2.
#
# Usage: run.sh <build dir | guest_image.bin> <listing | -> <workdir> [compare.py flags]
#
# With a build directory (the output of ps4-recomp), the guest image is <dir>/guest_image.bin and,
# when the listing argument is "-", the listing is taken from the recompiler's own disassembly:
# the "// 0xADDR: INST" comment that precedes every lifted instruction in <dir>/code_*.s. That is
# exactly the set of instructions the recompiler lifts for the eboot.
#
# Environment: MAX_PER_OP (default 40), SPECIAL=1 adds special FP values (inf/nan/denormals).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC=$1; DIS=$2; OUT=$3; shift 3
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
if [ -d "$SRC" ]; then
  IMG="$SRC/guest_image.bin"
  if [ "$DIS" = "-" ]; then
    DIS="$OUT/listing.txt"
    find "$SRC" -maxdepth 1 -name 'code_*.s' -print0 | sort -z | xargs -0 grep -h '^    // 0x' |
      sed -E 's|^    // 0x([0-9a-f]+): |\1: |' > "$DIS"
  fi
else
  IMG="$SRC"
fi
arch -x86_64 /usr/bin/true || { echo "Rosetta 2 is not installed" >&2; exit 1; }
(cd "$ROOT" && go build -o "$OUT/lifter-difftest-asm" ./cmd/lifter-difftest-asm)
"$OUT/lifter-difftest-asm" -image "$IMG" -dis "$DIS" -out "$OUT" -max-per-op ${MAX_PER_OP:-40}
H="$HERE/harness"
clang -arch x86_64 -O1 -I"$H" "$H/native_main.c" "$OUT/native_tests.s" -o "$OUT/native_dt"
clang -arch arm64 -O1 -w -I"$H" -I"$ROOT/pkg/runtime/core" "$H/asm_main.c" "$OUT/asm_tests.s" -o "$OUT/asm_dt"
"$OUT/native_dt" "$OUT/native.bin" ${SPECIAL:-0}
"$OUT/asm_dt" "$OUT/asm.bin" ${SPECIAL:-0} 2>/dev/null
python3 "$H/compare.py" "$OUT/native.bin" "$OUT/asm.bin" "$OUT/tests.txt" --summary "$OUT/summary.md" "$@"
