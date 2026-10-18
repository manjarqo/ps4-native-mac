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
"$T/pso_archive_test" write "$A"
"$T/pso_archive_test" read "$A"
"$T/pso_archive_test" budget "$A"
"$T/pso_archive_test" write "$A"
"$T/pso_archive_test" corrupt "$A"
rm -rf "$T"
