#!/bin/bash
# Builds programs that link the GNM renderer for pass replay: the renderer's sources (compiled
# once into <out_dir>/obj) plus tools/gnm_replay/gnm_replay_lib.mm, and one program per main
# source, named after it (<out_dir>/<basename without extension>).
# usage: tools/gnm_replay/build.sh <out_dir> <main source>...
#   tools/gnm_replay/build.sh /tmp/r tools/gnm_replay/gnm_replay.mm      -> /tmp/r/gnm_replay
#   (tests/host/run_host_tests.sh builds tests/host/gnm_replay_test.mm and the fix tests this way)
# Needs 3rdparty/gcn-recompiler/libgcn_recompiler.a (README: build gcn-recompiler first).
# GNM_REPLAY_SANITIZE=thread|address: every object and program built with that sanitizer.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$1
shift
G="$R/pkg/runtime/modules/libSceGnmDriver"
GR="$R/3rdparty/gcn-recompiler"
mkdir -p "$OUT/obj"
INC=(-I "$R/tools/gnm_replay" -I "$R/tests/host" -I "$GR/include")
while IFS= read -r d; do INC+=(-I "$d"); done < <(find "$R/pkg/runtime" -type d)
SAN=()
[ -n "${GNM_REPLAY_SANITIZE:-}" ] && SAN=(-fsanitize="$GNM_REPLAY_SANITIZE")
MM=(-x objective-c++ -std=c++20 -fobjc-arc -O1 -g -Wall -Wno-deprecated-declarations -Wno-unused-function "-DPS4_REPO_ROOT=\"$R\"" ${SAN[@]+"${SAN[@]}"})
for f in "$G/ps4_gnm_draw.mm" "$G/ps4_gnm_resources.mm" "$G/ps4_gnm_shader_cache.mm" "$G/ps4_gnm_library_store.mm" \
         "$G/ps4_gnm_pipeline_archive.mm" "$G/ps4_gnm_kernel_compile.mm" "$G/ps4_gnm_backend.mm" \
         "$G/ps4_gnm_backend_metal3.mm" "$G/ps4_gnm_backend_metal4.mm" "$G/ps4_gnm_residency.mm" \
         "$G/ps4_gnm_util_passes.mm" \
         "$R/tools/gnm_replay/gnm_replay_lib.mm"; do
  clang++ "${MM[@]}" "${INC[@]}" -c "$f" -o "$OUT/obj/$(basename "$f").o"
done
clang++ -std=c++17 -O1 -g -Wall -Werror ${SAN[@]+"${SAN[@]}"} "${INC[@]}" -c "$G/ps4_gnm_capture.cpp" -o "$OUT/obj/ps4_gnm_capture.o"
clang -std=gnu11 -O1 -g -Wall -Werror ${SAN[@]+"${SAN[@]}"} "${INC[@]}" -c "$G/ps4_gnm_membudget.c" -o "$OUT/obj/membudget.o"
clang -std=gnu11 -O1 -g -Wall -Werror ${SAN[@]+"${SAN[@]}"} "${INC[@]}" -c "$R/pkg/runtime/core/recomp_runtime.c" -o "$OUT/obj/recomp_runtime.o"
clang -std=gnu11 -O1 -g -Wall -Werror ${SAN[@]+"${SAN[@]}"} "${INC[@]}" -c "$R/tools/gnm_replay/replay_links.c" -o "$OUT/obj/replay_links.o"
clang -std=gnu11 -O1 -g -Wall -Werror -dynamiclib "$R/tools/gnm_replay/alloc_count.c" -o "$OUT/alloc_count.dylib"
for MAIN in "$@"; do
  NAME=$(basename "$MAIN"); NAME=${NAME%.*}
  mkdir -p "$OUT/main_$NAME"
  clang++ "${MM[@]}" "${INC[@]}" -c "$MAIN" -o "$OUT/main_$NAME/main.o"
  clang++ "$OUT"/obj/*.o "$OUT/main_$NAME/main.o" "$GR/libgcn_recompiler.a" "$R/3rdparty/spirv-cross/libspirv-cross.a" \
    ${SAN[@]+"${SAN[@]}"} -lz -framework Metal -framework Foundation -framework CoreGraphics -framework ImageIO -framework QuartzCore \
    -o "$OUT/$NAME" 2>&1 | { grep -v "ignoring duplicate libraries" || true; }
  test -x "$OUT/$NAME"
done
