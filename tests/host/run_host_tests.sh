#!/bin/bash
# Builds and runs the host-side unit tests of runtime pieces that do not need the game.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
"$R/tests/host/runtime_link_check.sh"
clang -std=gnu11 -Wall -Werror -I "$R/pkg/runtime/kernel/threading" "$R/tests/host/stall_profile_test.c" \
  "$R/pkg/runtime/kernel/threading/ps4_stall_profile.c" -o "$T/stall_profile_test"
"$T/stall_profile_test"
# libSceAudio3d on the real libSceAudioOut (headless device): panner, attribute validation, queue
# levels and device-clock pacing, bed plus object mixed to a known output.
A3="$R/pkg/runtime/modules/libSceAudio3d"
AO="$R/pkg/runtime/modules/libSceAudioOut"
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined -I "$R/pkg/runtime/core" -I "$AO" -I "$A3" \
  "$R/tests/host/audio3d_test.c" "$A3/ps4_audio3d.c" "$A3/ps4_audio3d_mix.c" "$AO/ps4_audioout.c" \
  -framework AudioToolbox -o "$T/audio3d_test"
"$T/audio3d_test" 2> "$T/audio3d.txt" || { cat "$T/audio3d.txt"; exit 1; }
grep "^audio3d_test" "$T/audio3d.txt"
# Asynchronous stdout/stderr: nothing is lost on abort() or exit(), with one shared file and with two.
clang -std=gnu11 -Wall -Werror -I "$R/pkg/runtime/core" "$R/tests/host/log_abort_test.c" "$R/pkg/runtime/core/ps4_log.c" \
  -o "$T/log_abort_test"
clang -std=gnu11 -Wall -Werror -DPS4_LOG_TEST -I "$R/pkg/runtime/core" "$R/tests/host/log_abort_test.c" "$R/pkg/runtime/core/ps4_log.c" \
  -o "$T/log_abort_test_hook"
for mode in abort exit; do
  for n in $(seq 20); do
    { "$T/log_abort_test" $mode > "$T/log1.txt" 2>&1 || true; } 2>/dev/null
    [ "$(wc -l < "$T/log1.txt")" -eq 201 ] || { echo "log_abort_test $mode (one file) run $n: $(wc -l < "$T/log1.txt") lines"; exit 1; }
    { "$T/log_abort_test" $mode > "$T/log_out.txt" 2> "$T/log_err.txt" || true; } 2>/dev/null
    [ "$(cat "$T/log_out.txt" "$T/log_err.txt" | wc -l)" -eq 201 ] || { echo "log_abort_test $mode (two files) run $n lost lines"; exit 1; }
    grep -q "FATAL last line" "$T/log1.txt" || { echo "log_abort_test $mode run $n: FATAL line missing"; exit 1; }
  done
done
# Slow consumer, ~20,000 lines (far over the 64 KB pipe): abort() must not lose any. Without the
# SIGABRT handler the same run must lose lines, which proves the test can fail.
for n in 1 2 3; do
  { "$T/log_abort_test" drive abort 20000 "$T/slow.txt" || true; } 2>/dev/null
  [ "$(wc -l < "$T/slow.txt")" -eq 20001 ] || { echo "log_abort_test slow consumer run $n: $(wc -l < "$T/slow.txt") of 20001 lines"; exit 1; }
  { PS4_LOG_TEST_NO_ABORT_HANDLER=1 "$T/log_abort_test_hook" drive abort 20000 "$T/slow_nohandler.txt" || true; } 2>/dev/null
  [ "$(wc -l < "$T/slow_nohandler.txt")" -lt 20001 ] || { echo "log_abort_test: lines were not lost without the SIGABRT handler; the test has no teeth"; exit 1; }
done
echo "log_abort_test: PASS"
# Fiber endpoint lookups from signal handlers while guest threads exit and fibers are finalized,
# under AddressSanitizer: no lookup may read a freed worker or fiber. Both fiber modes.
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address -I "$R/pkg/runtime/core" -I "$R/pkg/runtime/kernel/threading" \
  -I "$R/pkg/runtime/modules/libSceFiber" "$R/tests/host/fiber_lookup_test.c" "$R/pkg/runtime/modules/libSceFiber/ps4_fiber.c" \
  -o "$T/fiber_lookup_test"
for n in 1 2; do
  "$T/fiber_lookup_test" 60
  PS4_FIBER_THREADS=1 "$T/fiber_lookup_test" 60
done
# Uncharted 4 boot-path HLE: kernel memory (BatchMap/Mtypeprotect against the real VM extents),
# sem_timedwait, Rtc, and the state/formatting libraries. All runtime directories are on the path.
RT=()
while IFS= read -r d; do RT+=(-I "$d"); done < <(find "$R/pkg/runtime" -type d)
M="$R/pkg/runtime/modules"
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/kernel_batchmap_test.c" "$R/pkg/runtime/core/recomp_runtime.c" \
  "$R/pkg/runtime/kernel/memory/ps4_direct_mem.c" -o "$T/kernel_batchmap_test"
"$T/kernel_batchmap_test" | grep -v '^\[ps4'
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/kernel_vmfree_test.c" "$R/pkg/runtime/core/recomp_runtime.c" \
  -o "$T/kernel_vmfree_test"
"$T/kernel_vmfree_test" | grep -v '^\[ps4'
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/sem_timedwait_test.c" "$R/pkg/runtime/kernel/sync/ps4_semaphore.c" \
  -o "$T/sem_timedwait_test"
"$T/sem_timedwait_test"
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/rtc_test.c" "$M/libSceRtc/ps4_rtc.c" "$M/libSceRtc/ps4_rtc_extras.c" \
  -o "$T/rtc_test"
"$T/rtc_test"
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/boot_hle_test.c" "$M/libSceNp/ps4_np.c" "$M/libSceNp/ps4_np_party.c" \
  "$M/libSceNp/ps4_np_extras.c" "$M/libSceNpProfileDialog/ps4_np_profile_dialog.c" "$M/libSceNet/ps4_net.c" \
  "$M/libSceNetCtl/ps4_netctl.c" "$M/libSceHttp/ps4_http.c" "$M/libSceNoopStubs/ps4_noop_stubs.c" -o "$T/boot_hle_test"
"$T/boot_hle_test" 2>/dev/null

# H.264 through libSceVdecsw and libSceVideodec on the shared VideoToolbox core: a stream made
# by VideoToolbox's encoder (with B-frames) must come out complete, in display order, with the
# right OutputInfo / picture-info fields.
V="$R/pkg/runtime/modules/libSceVideodec"
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address -I "$R/pkg/runtime/core" -I "$V" "$R/tests/host/vdecsw_test.c" \
  "$R/pkg/runtime/modules/libSceVdecsw/ps4_vdecsw.c" "$V/ps4_videodec.c" "$V/ps4_h264_vt.c" -framework VideoToolbox \
  -framework CoreMedia -framework CoreVideo -framework CoreFoundation -o "$T/vdecsw_test"
"$T/vdecsw_test"
# AAC through libSceAudiodec on AudioToolbox: streams made by AudioToolbox's encoder and a stored
# FFmpeg-encoded stream, fed with U4's ctrl layout, must decode to the source signal (frame count, delay, SNR, checksum).
AD="$R/pkg/runtime/modules/libSceAudiodec"
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined -I "$R/pkg/runtime/core" -I "$AD" \
  "$R/tests/host/audiodec_test.c" "$AD/ps4_audiodec.c" -framework AudioToolbox -o "$T/audiodec_test"
"$T/audiodec_test" "$R/tests/host/data/audiodec_chirp_ffmpeg.aac" 2> "$T/audiodec.txt" || { cat "$T/audiodec.txt"; exit 1; }
G="$R/pkg/runtime/modules/libSceGnmDriver"
# GPU windows over guest memory work with the guest NULL page guard on.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" "$R/tests/host/guest_window_test.mm" -framework Metal \
  -framework Foundation -o "$T/guest_window_test"
"$T/guest_window_test"
# GPU memory accounting and budget decisions, the hole check against real mappings, and the Metal
# facts the accounting rests on (no-copy lengths in currentAllocatedSize, GPU use wires the range).
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined -I "$G" -c "$G/ps4_gnm_membudget.c" -o "$T/membudget.o"
clang++ -std=c++17 -fobjc-arc -Wall -Werror -g -O1 -fsanitize=address,undefined -I "$G" "$R/tests/host/gpu_membudget_test.mm" \
  "$T/membudget.o" -framework Metal -framework Foundation -o "$T/gpu_membudget_test"
"$T/gpu_membudget_test" > "$T/gpu_membudget.txt" || { cat "$T/gpu_membudget.txt"; exit 1; }
tail -1 "$T/gpu_membudget.txt"
# Texture cache eviction: the policy and the real TextureCache on Metal (lifetime of textures used
# by command buffers in flight, re-upload after eviction, GPU-write invalidation, GPU-owned surfaces).
clang++ -std=c++17 -fobjc-arc -Wall -Werror -Wno-deprecated-declarations -g -O1 -fsanitize=address,undefined \
  -I "$G" -I "$R/pkg/runtime/core" "$R/tests/host/tex_evict_test.mm" "$G/ps4_gnm_resources.mm" "$T/membudget.o" \
  -framework Metal -framework Foundation -o "$T/tex_evict_test"
"$T/tex_evict_test" > "$T/tex_evict.txt" 2>&1 || { cat "$T/tex_evict.txt"; exit 1; }
tail -1 "$T/tex_evict.txt"
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
# Two processes on one directory: hold owns it, lookup (meanwhile) must change nothing; once
# hold is gone, read owns it again.
L="$T/shared"; mkdir -p "$L"
"$T/pso_archive_test" write "$L" $NONCE
"$T/pso_archive_test" hold "$L" $NONCE > "$T/hold.txt" &
HOLD=$!
for n in $(seq 300); do grep -q holding "$T/hold.txt" && break; sleep 0.1; done
grep -q holding "$T/hold.txt" || { echo "pso_archive_test: hold did not start"; kill $HOLD; exit 1; }
"$T/pso_archive_test" lookup "$L" $NONCE || { kill $HOLD; exit 1; }
kill $HOLD; wait $HOLD 2>/dev/null || true
"$T/pso_archive_test" read "$L" $NONCE
# eviction: 6 one-pipeline files, then a cap of 4 files
E="$T/evict"; mkdir -p "$E"
for k in 0 1 2 3 4 5; do "$T/pso_archive_test" add$k "$E" $NONCE; done
PS4_GNM_PSO_ARCHIVE_MAX_FILES=4 "$T/pso_archive_test" evict "$E" $NONCE
"$T/pso_archive_test" evicted "$E" $NONCE
B="$T/budgetstop"; mkdir -p "$B"
"$T/pso_archive_test" budgetstop "$B" $NONCE
rm -rf "$T"
