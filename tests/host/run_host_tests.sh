#!/bin/bash
# Builds and runs the host-side unit tests of runtime pieces that do not need the game.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
clang -std=gnu11 -Wall -Werror -I "$R/pkg/runtime/kernel/threading" "$R/tests/host/stall_profile_test.c" \
  "$R/pkg/runtime/kernel/threading/ps4_stall_profile.c" -o "$T/stall_profile_test"
"$T/stall_profile_test"
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
