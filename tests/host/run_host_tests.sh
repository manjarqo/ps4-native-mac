#!/bin/bash
# Builds and runs the host-side unit tests of runtime pieces that do not need the game.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
clang -std=gnu11 -Wall -Werror -I "$R/pkg/runtime/kernel/threading" "$R/tests/host/stall_profile_test.c" \
  "$R/pkg/runtime/kernel/threading/ps4_stall_profile.c" -o "$T/stall_profile_test"
"$T/stall_profile_test"
# Asynchronous stdout/stderr: nothing is lost on abort() or exit(), with one shared file and with two.
clang -std=gnu11 -Wall -Werror -I "$R/pkg/runtime/core" "$R/tests/host/log_abort_test.c" "$R/pkg/runtime/core/ps4_log.c" \
  -o "$T/log_abort_test"
for mode in abort exit; do
  for n in $(seq 20); do
    { "$T/log_abort_test" $mode > "$T/log1.txt" 2>&1 || true; } 2>/dev/null
    [ "$(wc -l < "$T/log1.txt")" -eq 201 ] || { echo "log_abort_test $mode (one file) run $n: $(wc -l < "$T/log1.txt") lines"; exit 1; }
    { "$T/log_abort_test" $mode > "$T/log_out.txt" 2> "$T/log_err.txt" || true; } 2>/dev/null
    [ "$(cat "$T/log_out.txt" "$T/log_err.txt" | wc -l)" -eq 201 ] || { echo "log_abort_test $mode (two files) run $n lost lines"; exit 1; }
    grep -q "FATAL last line" "$T/log1.txt" || { echo "log_abort_test $mode run $n: FATAL line missing"; exit 1; }
  done
done
echo "log_abort_test: PASS"
G="$R/pkg/runtime/modules/libSceGnmDriver"
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" "$R/tests/host/pso_archive_test.mm" "$G/ps4_gnm_pipeline_archive.mm" \
  -framework Metal -framework Foundation -o "$T/pso_archive_test"
A="$T/archive"; mkdir -p "$A"
# A fresh shader per suite run (nonce) keeps pipeline caches of earlier runs from satisfying it.
NONCE=$(( $(date +%s) % 100000 * 10 + RANDOM % 10 ))
"$T/pso_archive_test" write "$A" $NONCE
"$T/pso_archive_test" read "$A" $NONCE
"$T/pso_archive_test" append "$A" $NONCE
"$T/pso_archive_test" read2 "$A" $NONCE
"$T/pso_archive_test" stale "$A" $NONCE
"$T/pso_archive_test" write "$A" $NONCE
"$T/pso_archive_test" budget "$A" $NONCE
"$T/pso_archive_test" write "$A" $NONCE
"$T/pso_archive_test" corrupt "$A" $NONCE
# eviction: 6 one-pipeline files, then a cap of 4 files
E="$T/evict"; mkdir -p "$E"
for k in 0 1 2 3 4 5; do "$T/pso_archive_test" add$k "$E" $NONCE; done
PS4_GNM_PSO_ARCHIVE_MAX_FILES=4 "$T/pso_archive_test" evict "$E" $NONCE
"$T/pso_archive_test" evicted "$E" $NONCE
B="$T/budgetstop"; mkdir -p "$B"
"$T/pso_archive_test" budgetstop "$B" $NONCE
rm -rf "$T"
