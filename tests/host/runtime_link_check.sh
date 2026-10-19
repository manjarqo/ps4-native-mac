#!/bin/bash
# Every C file of the runtime compiles, and no global symbol is defined twice. A duplicate shim
# breaks the link of every generated game, so the objects are merged with ld -r, which reports
# duplicate definitions without needing the frameworks a full link does.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
INC=()
while IFS= read -r d; do INC+=(-I "$d"); done < <(find "$R/pkg/runtime" -type d)
cc_one() {
  local inc_file=$1 out=$2 f=$3
  # shellcheck disable=SC2046
  clang -std=gnu11 -O0 -w -c $(cat "$inc_file") "$f" -o "$out/$(echo "$f" | cksum | cut -d' ' -f1).o"
}
export -f cc_one
# Third-party headers the runtime includes (the game build adds the same paths).
for d in $(find "$R/3rdparty" \( -name libatrac9.h -o -name minimp3.h \) -exec dirname {} \;); do INC+=(-I "$d"); done
if FT=$(pkg-config --cflags freetype2 2>/dev/null); then INC+=($FT); else INC+=(-I /opt/homebrew/opt/freetype/include/freetype2); fi
printf '%s\n' "${INC[@]}" | paste -sd' ' - > "$T/inc.txt"
mkdir -p "$T/objs"
find "$R/pkg/runtime" -name '*.c' -print0 | xargs -0 -n1 -P4 bash -c 'cc_one "$0" "$1" "$2"' "$T/inc.txt" "$T/objs" 2> "$T/cc.err" \
  || { cat "$T/cc.err"; echo "runtime_link_check: compile failed"; exit 1; }
ld -r "$T"/objs/*.o -o "$T/all.o" 2> "$T/ld.err" || { head -20 "$T/ld.err"; echo "runtime_link_check: FAIL"; exit 1; }
echo "runtime_link_check: PASS"
