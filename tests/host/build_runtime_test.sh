#!/bin/bash
# Builds a host test program against the whole runtime (every C, C++, Objective-C and
# Objective-C++ file under pkg/runtime, with the game build's include paths and frameworks), for tests that
# drive HLE entry points end to end (sceGnmSubmitAndFlipCommandBuffers -> command processor ->
# renderer -> VideoOut -> Metal screen). The runtime objects are compiled once into
# <out_dir>/rt. The generated game code is not linked: the test defines recomp_enter_guest.
# usage: tests/host/build_runtime_test.sh <out_dir> <main source>   -> <out_dir>/<basename>
# Needs 3rdparty/gcn-recompiler/libgcn_recompiler.a and the 3rdparty submodules (README).
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$1
MAIN=$2
mkdir -p "$OUT/rt"
INC=()
while IFS= read -r d; do INC+=(-I "$d"); done < <(find "$R/pkg/runtime" -type d)
for d in $(find -L "$R/3rdparty" \( -name libatrac9.h -o -name minimp3.h -o -name gcn_recompiler.h \) -exec dirname {} \;); do
  INC+=(-I "$d")
done
if FT=$(pkg-config --cflags freetype2 2>/dev/null); then INC+=($FT); else INC+=(-I /opt/homebrew/opt/freetype/include/freetype2); fi
printf '%s\n' "${INC[@]}" | paste -sd' ' - > "$OUT/inc.txt"
cc_one() {
  local inc_file=$1 out=$2 f=$3
  local o
  o="$out/$(echo "$f" | cksum | cut -d' ' -f1).o"
  case "$f" in
    *.mm) set -- clang++ -x objective-c++ -std=c++17 -fobjc-arc ;;
    *.cpp) set -- clang++ -std=c++17 ;;
    *.m) set -- clang -fobjc-arc ;;
    *) set -- clang -std=gnu11 ;;
  esac
  # shellcheck disable=SC2046
  "$@" -O1 -g -w -DRECOMP_ARM64_ASM=1 -ffp-contract=off $(cat "$inc_file") -c "$f" -o "$o"
}
export -f cc_one
find "$R/pkg/runtime" \( -name '*.c' -o -name '*.m' -o -name '*.mm' -o -name '*.cpp' \) -print0 |
  xargs -0 -n1 -P6 bash -c 'cc_one "$0" "$1" "$2"' "$OUT/inc.txt" "$OUT/rt"
NAME=$(basename "$MAIN"); NAME=${NAME%.*}
# shellcheck disable=SC2046
clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -g -Wall -Werror $(cat "$OUT/inc.txt") -c "$MAIN" -o "$OUT/$NAME.o"
FTL=$(pkg-config --libs freetype2 2>/dev/null || echo "-L/opt/homebrew/opt/freetype/lib -lfreetype")
# shellcheck disable=SC2086
clang++ "$OUT/$NAME.o" "$OUT"/rt/*.o "$R/3rdparty/gcn-recompiler/libgcn_recompiler.a" \
  "$R/3rdparty/spirv-cross/libspirv-cross.a" "$R/3rdparty/libatrac9/libatrac9.a" $FTL -lz \
  -framework Metal -framework Cocoa -framework QuartzCore -framework GameController -framework AudioToolbox \
  -framework ImageIO -framework MetalFX -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
  -o "$OUT/$NAME" 2>&1 | { grep -v "ignoring duplicate libraries" || true; }
test -x "$OUT/$NAME"
