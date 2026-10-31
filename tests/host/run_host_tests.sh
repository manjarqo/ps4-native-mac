#!/bin/bash
# Builds and runs the host-side unit tests of runtime pieces that do not need the game.
#
# A few cases translate or run shaders dumped from a game. Those dumps are game data and are not
# in the repository: each developer makes them from their own copy of the game and puts them in
# tests/host/data/game/ (git-ignored), or in the directory named by PS4_HOST_GAME_FIXTURES. Without
# them these cases print "SKIP: <case>: needs local fixture <path> (game data, not distributed)"
# and are not counted as passed. How to regenerate them: tests/host/README.md.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
FIX="${PS4_HOST_GAME_FIXTURES:-$R/tests/host/data/game}"
# Output of the tests with fixture cases, for the SKIP count at the end.
: > "$T/fixture_cases.txt"
# Every test that runs Metal work runs under a hard timeout: a kernel that never ends (a GPU
# hang) fails the run instead of holding the GPU for other work. A stopped test exits with 124
# (timeout) or 142 (SIGALRM, the fallback without coreutils), and set -e ends the run.
GPU_TIMEOUT=${GPU_TIMEOUT:-120}
gpu() {
  local rc=0
  if command -v timeout > /dev/null; then
    timeout -k 10 "$GPU_TIMEOUT" "$@" || rc=$?
  else
    perl -e 'alarm shift; exec @ARGV or die "exec $ARGV[0]: $!"' "$GPU_TIMEOUT" "$@" || rc=$?
  fi
  if [ $rc -eq 124 ] || [ $rc -eq 137 ] || [ $rc -eq 142 ]; then
    echo "$(basename "$1"): TIMEOUT, stopped after ${GPU_TIMEOUT} s (a GPU hang?)" >&2
  fi
  return $rc
}
# A renderer-level test on backend $1 (3 or 4); the rest is its command line. Metal 4 runs with
# the bind-time residency check (PS4_GNM_RESIDENCY_CHECK=1): a resource reported not resident fails
# the run, as does a run without the renderer's "backend metal$1" line (it did not start, or
# started on the other backend). Shows the test's PASS / SKIP / FAIL lines tagged with the
# backend; on a failure, its output without the translator's lines.
rtest() {
  local m=$1 rc=0
  shift
  local out="$T/rtest_$(basename "$1").txt"
  ( export PS4_GNM_METAL=$m; [ "$m" = 4 ] && export PS4_GNM_RESIDENCY_CHECK=1; gpu "$@" ) > "$out" 2>&1 || rc=$?
  if [ $rc -ne 0 ]; then
    grep -v "^\[gcn " "$out" | tail -60; echo "$(basename "$1") $* on Metal $m: FAIL (rc=$rc)"; exit 1
  fi
  if grep "gnm-residency\] ASSERT" "$out"; then echo "$(basename "$1") on Metal $m: resources not resident"; exit 1; fi
  if ! grep -q "^\[gnm-draw\] backend metal$m" "$out"; then
    grep "^\[gnm-draw\] backend" "$out"; echo "$(basename "$1") on Metal $m: the renderer did not start on Metal $m"; exit 1
  fi
  grep -E ": (PASS|SKIP|FAIL)|^(PASS|SKIP|FAIL)" "$out" | sed "s/\$/ [metal$m]/" || true
}
# A test that drives a backend directly, on backend $1 (3 or 4), with Metal API validation when $2
# is 1; the rest is its command line. Metal 4 runs with PS4_GNM_RESIDENCY_CHECK=1 (the backend reads
# it in Init) and fails on a resource reported not resident.
btest() {
  local m=$1 dbg=$2 rc=0
  shift 2
  local out="$T/btest_$(basename "$1").txt"
  ( export PS4_GNM_METAL=$m; [ "$m" = 4 ] && export PS4_GNM_RESIDENCY_CHECK=1; [ "$dbg" = 1 ] && export MTL_DEBUG_LAYER=1
    gpu "$@" ) > "$out" 2>&1 || rc=$?
  grep -v "Metal API Validation Enabled\|^\[gcn [WID]\]" "$out" || true
  [ $rc -eq 0 ] || { echo "$(basename "$1") on Metal $m: FAIL (rc=$rc)"; exit 1; }
  if grep -q "gnm-residency\] ASSERT" "$out"; then echo "$(basename "$1") on Metal $m: resources not resident"; exit 1; fi
}
"$R/tests/host/runtime_link_check.sh"
clang -std=gnu11 -Wall -Werror -I "$R/pkg/runtime/kernel/threading" "$R/tests/host/stall_profile_test.c" \
  "$R/pkg/runtime/kernel/threading/ps4_stall_profile.c" -o "$T/stall_profile_test"
"$T/stall_profile_test"
# Per-game file names: settings key by TITLE_ID, save directory found by its " [TITLE_ID]" suffix.
# The same key names the shader cache dir (TITLE_ID from param.sfo, else the app dir name), and the
# settings file keeps the lines it does not own (core/ps4_settings_file.h).
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined -I "$R/pkg/runtime/core" -I "$R/pkg/runtime/kernel/vfs" \
  "$R/tests/host/settings_savedir_test.c" "$R/pkg/runtime/core/ps4_game_key.c" "$R/pkg/runtime/core/ps4_game_key_current.c" \
  "$R/pkg/runtime/core/ps4_sfo.c" "$R/pkg/runtime/core/ps4_settings_file.c" "$R/pkg/runtime/kernel/vfs/ps4_vfs.c" \
  -o "$T/settings_savedir_test"
"$T/settings_savedir_test" | grep -v '^\[ps4-vfs\]'

# The renderer's index of pending GPU writes (ps4_gnm_pending_writes.h) against the scan it replaces.
clang++ -std=c++17 -Wall -Werror -g -O1 -fsanitize=address,undefined -I "$R/pkg/runtime/modules/libSceGnmDriver" \
  "$R/tests/host/gnm_pending_writes_test.cc" -o "$T/gnm_pending_writes_test"
"$T/gnm_pending_writes_test"
# The PS4_SCREENSHOT_EVERY_SEC cadence: one shot at the first flip after each multiple of the period.
clang -std=gnu11 -Wall -Werror -I "$R/pkg/runtime/modules/libSceVideoOut" "$R/tests/host/screenshot_cadence_test.c" \
  -o "$T/screenshot_cadence_test"
# sceVideoOutAdjustColor output gamma: identity at 1.0, < 1 darkens, > 1 brightens, monotonic.
clang -std=gnu11 -Wall -Werror -I "$R/pkg/runtime/modules/libSceVideoOut" "$R/tests/host/output_gamma_test.c" \
  -lm -o "$T/output_gamma_test"
"$T/output_gamma_test"
"$T/screenshot_cadence_test"
# libSceAudio3d on the real libSceAudioOut (headless device): panner, attribute validation, queue
# levels and device-clock pacing, bed plus object mixed to a known output.
A3="$R/pkg/runtime/modules/libSceAudio3d"
AO="$R/pkg/runtime/modules/libSceAudioOut"
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined -I "$R/pkg/runtime/core" -I "$AO" -I "$A3" \
  "$R/tests/host/audio3d_test.c" "$A3/ps4_audio3d.c" "$A3/ps4_audio3d_mix.c" "$AO/ps4_audioout.c" \
  -framework AudioToolbox -o "$T/audio3d_test"
"$T/audio3d_test" 2> "$T/audio3d.txt" || { cat "$T/audio3d.txt"; exit 1; }
grep "^audio3d_test" "$T/audio3d.txt"
# libSceAudioOut 8-channel -> stereo fold (centre / surrounds at -3 dB, LFE dropped) on the headless device.
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined -I "$R/pkg/runtime/core" -I "$AO" \
  "$R/tests/host/audioout_downmix_test.c" "$AO/ps4_audioout.c" -framework AudioToolbox -o "$T/audioout_downmix_test"
"$T/audioout_downmix_test" 2> "$T/downmix.txt" || { cat "$T/downmix.txt"; exit 1; }
grep "^audioout_downmix_test" "$T/downmix.txt"
# libSceAudioOut port timing counters (gaps, late outputs, underrun frames, the first sound) and the
# final-mix dump on the CLOCK_MONOTONIC timeline, on the headless device.
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined -I "$R/pkg/runtime/core" -I "$AO" \
  "$R/tests/host/audioout_timing_test.c" "$AO/ps4_audioout.c" -framework AudioToolbox -o "$T/audioout_timing_test"
PS4_AUDIO_NULL=1 PS4_AUDIO_LOG=1 PS4_AUDIO_DUMP="$T/timing.wav" "$T/audioout_timing_test" 2> "$T/timing.txt" ||
  { cat "$T/timing.txt"; exit 1; }
grep "^audioout_timing_test" "$T/timing.txt"
rm -f "$T/timing.wav"
# The dump on the headless device across a 500 ms SIGSTOP (no re-based clock), an unwritable
# path, a write error, and the final header at a normal exit; one child process per case.
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined -I "$R/pkg/runtime/core" -I "$AO" \
  "$R/tests/host/audioout_dump_test.c" "$AO/ps4_audioout.c" -framework AudioToolbox -o "$T/audioout_dump_test"
mkdir -p "$T/dump"
"$T/audioout_dump_test" "$T/dump" 2> "$T/dump.txt" || { cat "$T/dump.txt"; exit 1; }
grep "^audioout_dump_test: " "$T/dump.txt"
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
  "$R/pkg/runtime/kernel/memory/ps4_direct_mem.c" "$R/pkg/runtime/kernel/syscalls/ps4_syscalls.c" \
  "$R/pkg/runtime/kernel/vfs/ps4_vfs.c" -o "$T/kernel_batchmap_test"
"$T/kernel_batchmap_test" | grep -v '^\[ps4'
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/kernel_vmfree_test.c" "$R/pkg/runtime/core/recomp_runtime.c" \
  -o "$T/kernel_vmfree_test"
"$T/kernel_vmfree_test" | grep -v '^\[ps4'
# Sonic Origins' HLE calls: libSceLoginDialog's state machine, sceRtcCheckValid,
# sceKernelCheckReachability through the /app0 mount, sceUserServiceGetEvent's NO_EVENT code and
# libSceNpWebApi2 without a PSN sign-in.
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/sonic_hle_test.c" "$R/pkg/runtime/core/recomp_runtime.c" \
  "$R/pkg/runtime/kernel/memory/ps4_direct_mem.c" "$R/pkg/runtime/kernel/syscalls/ps4_syscalls.c" \
  "$R/pkg/runtime/kernel/vfs/ps4_vfs.c" "$M/libSceRtc/ps4_rtc.c" "$M/libSceRtc/ps4_rtc_extras.c" \
  "$M/libSceLoginDialog/ps4_login_dialog.c" "$M/libSceUserService/ps4_user_service.c" \
  "$M/libSceNpWebApi2/ps4_np_webapi2.c" -o "$T/sonic_hle_test"
"$T/sonic_hle_test" | grep -v '^\[ps4\|^\[libSceLoginDialog'
# New thread contexts inherit the creator's MXCSR and x87 control word (FreeBSD cpu_copy_thread).
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/thread_fpstate_test.c" "$R/pkg/runtime/core/recomp_runtime.c" \
  -o "$T/thread_fpstate_test"
"$T/thread_fpstate_test" | grep -v '^\[ps4'
# The crash handler names its host thread and tells a fault of that thread from a signal sent
# to the process.
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/crash_source_test.c" "$R/pkg/runtime/core/recomp_runtime.c" \
  -o "$T/crash_source_test"
"$T/crash_source_test"
# Guard-size attributes protect guest stacks and release the protection before reuse.
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/pthread_guard_test.c" \
  "$R/pkg/runtime/kernel/threading/ps4_threading.c" "$R/pkg/runtime/kernel/threading/ps4_stall_profile.c" \
  "$R/pkg/runtime/core/recomp_runtime.c" -o "$T/pthread_guard_test"
"$T/pthread_guard_test" | grep -v '^\[ps4'
# Static TLS per module (eboot, libSceFios2, libc): blocks laid out as FreeBSD's rtld does, .tdata
# copied for the main thread and new threads, __tls_get_addr by module index.
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/tls_modules_test.c" \
  "$R/pkg/runtime/kernel/threading/ps4_threading.c" "$R/pkg/runtime/kernel/threading/ps4_stall_profile.c" \
  "$R/pkg/runtime/core/recomp_runtime.c" -o "$T/tls_modules_test"
"$T/tls_modules_test" | grep -v '^\[ps4'
# The stall watchdog arms at sceVideoOutOpen, before any frame is presented.
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/stall_watchdog_test.c" \
  "$R/pkg/runtime/kernel/threading/ps4_threading.c" "$R/pkg/runtime/kernel/threading/ps4_stall_profile.c" \
  "$R/pkg/runtime/core/recomp_runtime.c" -o "$T/stall_watchdog_test"
"$T/stall_watchdog_test"
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/sem_timedwait_test.c" "$R/pkg/runtime/kernel/sync/ps4_semaphore.c" \
  -o "$T/sem_timedwait_test"
# libkernel semaphores: SignalSema hands tokens to the waiters at once (two signals to a
# max_count 1 semaphore with a waiter both succeed), need_count order, timeout, Delete, Cancel.
clang -std=gnu11 -Wall -Werror -g -fsanitize=thread "${RT[@]}" "$R/tests/host/kernel_sema_test.c" \
  "$R/pkg/runtime/kernel/sync/ps4_semaphore.c" -o "$T/kernel_sema_test"
"$T/kernel_sema_test"
# libkernel event flags: PollEventFlag reports the pattern on EBUSY (Sonic Origins' job-group
# wait reads it), AND / OR, CLEAR_PAT / CLEAR_ALL, timeout, wake-up from another thread.
clang -std=gnu11 -Wall -Werror -g -fsanitize=thread "${RT[@]}" "$R/tests/host/kernel_evf_test.c" \
  "$R/pkg/runtime/kernel/sync/ps4_event_flag.c" -o "$T/kernel_evf_test"
"$T/kernel_evf_test"

# libSceJson2 on guest memory from the runtime's VM: parse, accessors, building, serialize,
# deep copies, malformed documents, and no node leak over 20000 parse / destroy rounds.
clang -std=gnu11 -Wall -Werror -g -fsanitize=address,undefined "${RT[@]}" "$R/tests/host/json2_test.c" \
  "$M/libSceJson2/ps4_json2.c" "$R/pkg/runtime/core/recomp_runtime.c" -o "$T/json2_test"
"$T/json2_test" | grep -v '^\[ps4'

# Sync objects in guest memory (ps4_sync_objects.c) under the mutex, cond and rwlock shims.
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/sync_objects_test.c" "$R/pkg/runtime/kernel/sync/ps4_sync.c" \
  "$R/pkg/runtime/kernel/sync/ps4_sync_objects.c" "$R/pkg/runtime/core/recomp_runtime.c" -o "$T/sync_objects_test"
"$T/sync_objects_test" | grep -v '^\[ps4'
"$T/sem_timedwait_test"
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/rtc_test.c" "$M/libSceRtc/ps4_rtc.c" "$M/libSceRtc/ps4_rtc_extras.c" \
  -o "$T/rtc_test"
"$T/rtc_test"
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/boot_hle_test.c" "$M/libSceNp/ps4_np.c" "$M/libSceNp/ps4_np_party.c" \
  "$M/libSceNp/ps4_np_extras.c" "$M/libSceNpProfileDialog/ps4_np_profile_dialog.c" "$M/libSceNet/ps4_net.c" \
  "$M/libSceNetCtl/ps4_netctl.c" "$M/libSceHttp/ps4_http.c" "$M/libSceNoopStubs/ps4_noop_stubs.c" -o "$T/boot_hle_test"
"$T/boot_hle_test" 2>/dev/null
# sceNetEpoll* over kqueue with real sockets: ADD/MOD/DEL, readable/writable reports, timeouts,
# error codes, Abort and Destroy waking a blocked Wait. Under AddressSanitizer.
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined "${RT[@]}" "$R/tests/host/net_epoll_test.c" "$M/libSceNet/ps4_net.c" \
  -o "$T/net_epoll_test"
"$T/net_epoll_test"
# sigfillset and scePlayGoSetToDoList through the guest ABI (inFAMOUS boot imports).
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/playgo_sigset_test.c" "$M/libScePlayGo/ps4_playgo.c" \
  "$R/pkg/runtime/kernel/syscalls/ps4_sigset.c" -o "$T/playgo_sigset_test"
"$T/playgo_sigset_test"
# The DLC scan of libSceAppContent: <app>/addcont, then PS4_ADDCONT_DIR (games/<TITLE_ID>/addcont of
# a game used in place), one entry per label, mounted at the scanned directory; and without the
# variable only <app>/addcont.
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined "${RT[@]}" "$R/tests/host/app_content_addcont_test.c" \
  "$M/libSceAppContent/ps4_app_content.c" "$R/pkg/runtime/core/ps4_sfo.c" "$R/pkg/runtime/kernel/vfs/ps4_vfs.c" \
  -o "$T/app_content_addcont_test"
"$T/app_content_addcont_test" "$T" 2>/dev/null | grep -v '^\[ps4-vfs\]'
"$T/app_content_addcont_test" "$T" noenv 2>/dev/null | grep -v '^\[ps4-vfs\]'
# Save directories (Mount2 / SetParam / Umount) and the save data dialog's automatic list answers
# (PS4_SAVEDATA_DIALOG=auto) through the guest ABI: a load list loads the save the game focused, and
# a PS4_SAVEDATA_DIALOG_PICK sequence answers successive lists (its own process).
clang -std=gnu11 -fobjc-arc -Wall -Werror -g -O1 -fsanitize=address,undefined "${RT[@]}" "$R/tests/host/savedata_dialog_test.m" \
  "$M/libSceSaveDataDialog/ps4_savedata_dialog.m" "$M/libSceSaveData/ps4_savedata.c" "$R/pkg/runtime/core/ps4_sfo.c" "$R/pkg/runtime/core/ps4_game_key.c" \
  "$R/pkg/runtime/kernel/vfs/ps4_vfs.c" -framework Cocoa -o "$T/savedata_dialog_test"
"$T/savedata_dialog_test" 2>/dev/null
"$T/savedata_dialog_test" sequence 2>/dev/null
# SaveDataMemory2 persistence: in-session repeated SetupSaveDataMemory2 and cross-restart
# persistence both with and without sceSaveDataSyncSaveDataMemory (Sonic Origins pattern),
# immediate disk contents, child exit without Terminate, and failed buffered flush recovery.
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined "${RT[@]}" "$R/tests/savedata_test/main.c" \
  "$M/libSceSaveData/ps4_savedata.c" "$R/pkg/runtime/core/ps4_sfo.c" "$R/pkg/runtime/core/ps4_game_key.c" \
  "$R/pkg/runtime/kernel/vfs/ps4_vfs.c" -o "$T/savedata_test"
"$T/savedata_test"
# /app0 is read-only (EROFS for writes, creates, truncation, removal, renames, attribute changes)
# through the file shims; /temp0 stays writable.
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/vfs_readonly_test.c" \
  "$R/pkg/runtime/kernel/syscalls/ps4_syscalls.c" "$R/pkg/runtime/kernel/vfs/ps4_vfs.c" "$R/pkg/runtime/core/recomp_runtime.c" \
  "$R/pkg/runtime/kernel/memory/ps4_direct_mem.c" -o "$T/vfs_readonly_test"
"$T/vfs_readonly_test" | grep -v '^\[ps4'
# The direct memory size from the process's SceProcParam / SceKernelMemParam (the kernel's rule,
# not a fixed size), set up by recomp_init_process_param before the game's malloc init runs.
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/direct_mem_size_test.c" \
  "$R/pkg/runtime/kernel/memory/ps4_direct_mem.c" "$R/pkg/runtime/core/recomp_runtime.c" -o "$T/direct_mem_size_test"
"$T/direct_mem_size_test" | grep -v '^\[ps4'
# PS4 Pro (Neo) mode only for titles that declare Pro support in their application param.sfo
# (ATTRIBUTE bit 23); an add-on's param.sfo or none leaves the host setting in charge.
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined "${RT[@]}" "$R/tests/host/neo_mode_test.c" \
  "$R/pkg/runtime/core/ps4_neo.c" "$R/pkg/runtime/core/ps4_sfo.c" "$R/pkg/runtime/kernel/vfs/ps4_vfs.c" -o "$T/neo_mode_test"
"$T/neo_mode_test"
# libScePad: controller information as Uncharted 4 reads it, and PS4_PAD_CTL command order.
clang -std=gnu11 -fobjc-arc -Wall -Werror -g "${RT[@]}" "$R/tests/host/pad_test.m" "$M/libScePad/ps4_pad.m" \
  -framework Foundation -framework GameController -framework Cocoa -o "$T/pad_test"
"$T/pad_test"
"$T/pad_test" clock

# H.264 through libSceVdecsw, libSceVideodec and libSceVideodec2 on the shared VideoToolbox core: a stream made
# by VideoToolbox's encoder (with B-frames) must come out complete, in display order, with the
# right OutputInfo / picture-info fields. Also the access-unit census, libSceVideodec's
# per-decoder counts, and, when the local game-data fixture is present (git-ignored, not
# distributed), inFAMOUS's splash movie through libSceVideodec.
V="$R/pkg/runtime/modules/libSceVideodec"
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address -I "$R/pkg/runtime/core" -I "$V" "$R/tests/host/vdecsw_test.c" \
  "$R/pkg/runtime/modules/libSceVdecsw/ps4_vdecsw.c" "$V/ps4_videodec.c" "$V/ps4_videodec2.c" "$V/ps4_h264_vt.c" -framework VideoToolbox \
  -framework CoreMedia -framework CoreVideo -framework CoreFoundation -o "$T/vdecsw_test"
"$T/vdecsw_test" "$R/tests/host/data/game/infamous/splash_europe.bsf"
# AAC through libSceAudiodec on AudioToolbox: streams made by AudioToolbox's encoder and a stored
# FFmpeg-encoded stream, fed with U4's ctrl layout, must decode to the source signal (frame count, delay, SNR, checksum).
AD="$R/pkg/runtime/modules/libSceAudiodec"
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined -I "$R/pkg/runtime/core" -I "$AD" \
  "$R/tests/host/audiodec_test.c" "$AD/ps4_audiodec.c" -framework AudioToolbox -o "$T/audiodec_test"
"$T/audiodec_test" "$R/tests/host/data/audiodec_chirp_ffmpeg.aac" 2> "$T/audiodec.txt" || { cat "$T/audiodec.txt"; exit 1; }
# libSceAjm batch error record (sceAjmBatchWait / StartBuffer fill SceAjmBatchError for the first
# failing job), sceAjmBatchErrorDump and sceAjmDecAt9ParseConfigData, on a fake guest memory.
AJ="$R/pkg/runtime/modules/libSceAjm"
A9=$(dirname "$(find -L "$R/3rdparty" -name libatrac9.h | head -1)")
MP=$(dirname "$(find -L "$R/3rdparty" -name minimp3.h | head -1)")
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined "${RT[@]}" -I "$A9" -I "$MP" \
  "$R/tests/host/ajm_test.c" "$AJ/ps4_ajm.c" "$R/3rdparty/libatrac9/libatrac9.a" -o "$T/ajm_test"
"$T/ajm_test" 2> "$T/ajm.txt" || { cat "$T/ajm.txt"; exit 1; }
# Presenter statistics: display intervals from presented times, drops, drawable waits, bursts.
VO="$R/pkg/runtime/modules/libSceVideoOut"
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined -I "$VO" "$R/tests/host/present_stats_test.c" \
  "$VO/ps4_present_stats.c" -o "$T/present_stats_test"
"$T/present_stats_test"
# Presenter frame queue (FIFO / mailbox slots, blocking and timeouts) and the vsync pacing policy.
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined -I "$VO" "$R/tests/host/present_queue_test.c" \
  "$VO/ps4_present_queue.c" -o "$T/present_queue_test"
"$T/present_queue_test"
# sceGnmSubmitAndFlipCommandBuffers with the display behind (u4_research/crash_0x1ceb9d0.md),
# through the whole runtime, with PS4_GNM_SYNC_ENCODE and with the encoder thread: the call (and
# draining the encoder) returns at once, the EOP label is written, the flip stays pending until
# the display takes the frame; the 1 s and 3-frame drops; a CPU-written display buffer; the flip
# labels and sceGnmInsertWaitFlipDone (a frame waits until its buffer has left the screen).
"$R/tests/host/build_runtime_test.sh" "$T/rt_test" "$R/tests/host/gnm_submit_flip_nonblocking_test.mm" \
  > "$T/rt_test_build.txt" 2>&1 || { cat "$T/rt_test_build.txt"; exit 1; }
for m in 3 4; do
  for mode in sync async nohooks; do rtest $m "$T/rt_test/gnm_submit_flip_nonblocking_test" $mode; done
done
# The present producer's failure rule (ps4_metal_screen_present_failed): a failed command buffer's
# present event is raised to its value only while that value is the newest of its event.
"$R/tests/host/build_runtime_test.sh" "$T/rt_test" "$R/tests/host/present_fail_test.mm" \
  > "$T/rt_test_build2.txt" 2>&1 || { cat "$T/rt_test_build2.txt"; exit 1; }
"$T/rt_test/present_fail_test" > "$T/present_fail.txt" 2>&1 || { cat "$T/present_fail.txt"; exit 1; }
grep "^present_fail_test" "$T/present_fail.txt"
G="$R/pkg/runtime/modules/libSceGnmDriver"
# Frame capture store (ps4_gnm_capture.cpp): snapshot dedup, register file and manifest round trip,
# raw texture layout sizes, the documented per-format view mapping, thumbnails. No Metal.
clang++ -std=c++17 -Wall -Werror -g -O1 -fsanitize=address,undefined -I "$G" "$R/tests/host/gnm_capture_test.cc" \
  "$G/ps4_gnm_capture.cpp" -lz -o "$T/gnm_capture_test"
"$T/gnm_capture_test"
# PM4 INDIRECT_BUFFER chaining: chained chunks run to the end, calls return, deep calls stop.
clang++ -std=c++17 -Wall -Werror -g -fsanitize=address,undefined -I "$G" "$R/tests/host/gnm_ib_chain_test.cc" \
  -o "$T/gnm_ib_chain_test"
# Compute queues stop at an unsatisfied WAIT_REG_MEM and continue there later.
clang++ -std=c++17 -Wall -Werror -g -fsanitize=address,undefined -I "$G" "$R/tests/host/gnm_compute_wait_test.cc" \
  -o "$T/gnm_compute_wait_test"
"$T/gnm_compute_wait_test" > "$T/gnm_compute_wait.txt" || { cat "$T/gnm_compute_wait.txt"; exit 1; }
echo "gnm_compute_wait_test: PASS"
"$T/gnm_ib_chain_test"
# GPU windows over guest memory work with the guest NULL page guard on; the GPU reads guest bytes
# through them on each backend (Metal 4 with the windows resident, and the residency check).
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" -I "$R/tests/host" "$R/tests/host/guest_window_test.mm" \
  "$G/ps4_gnm_backend.mm" "$G/ps4_gnm_backend_metal3.mm" "$G/ps4_gnm_backend_metal4.mm" "$G/ps4_gnm_residency.mm" \
  "$G/ps4_gnm_util_passes.mm" -framework Metal -framework Foundation -o "$T/guest_window_test"
for m in 3 4; do btest $m 0 "$T/guest_window_test"; done
# Shader translator (3rdparty/gcn-recompiler) scalar reads on Metal: SRT reads at offsets only the
# shader knows, s_buffer_load past num_records, and a compute shader dumped from Uncharted 4.
GR="$R/3rdparty/gcn-recompiler"
clang++ -std=c++20 -fobjc-arc -Wall -Werror -I "$GR/include" "$R/tests/host/gcn_scalar_reads_test.mm" \
  "$GR/libgcn_recompiler.a" "$R/3rdparty/spirv-cross/libspirv-cross.a" -framework Metal -framework Foundation \
  -o "$T/gcn_scalar_reads_test" 2>&1 | { grep -v "ignoring duplicate libraries" || true; }
gpu "$T/gcn_scalar_reads_test" "$FIX" | tee -a "$T/fixture_cases.txt"
# GPU memory accounting and budget decisions, the hole check against real mappings, and the Metal
# facts the accounting rests on (no-copy lengths in currentAllocatedSize, GPU use wires the range).
clang -std=gnu11 -Wall -Werror -g -O1 -fsanitize=address,undefined -I "$G" -c "$G/ps4_gnm_membudget.c" -o "$T/membudget.o"
clang++ -std=c++17 -fobjc-arc -Wall -Werror -g -O1 -fsanitize=address,undefined -I "$G" "$R/tests/host/gpu_membudget_test.mm" \
  "$T/membudget.o" -framework Metal -framework Foundation -o "$T/gpu_membudget_test"
gpu "$T/gpu_membudget_test" > "$T/gpu_membudget.txt" || { cat "$T/gpu_membudget.txt"; exit 1; }
tail -1 "$T/gpu_membudget.txt"
# Backend sources for tests that drive a backend directly (tests/host/test_backend.h).
BE=("$G/ps4_gnm_backend.mm" "$G/ps4_gnm_backend_metal3.mm" "$G/ps4_gnm_backend_metal4.mm" "$G/ps4_gnm_residency.mm"
    "$G/ps4_gnm_util_passes.mm")
# Texture cache eviction: the policy and the real TextureCache on Metal (lifetime of textures used
# by command buffers in flight, re-upload after eviction, GPU-write invalidation, GPU-owned surfaces),
# on each backend: the backend's side queue and residency (no cache texture left resident on Metal 4).
clang++ -std=c++17 -fobjc-arc -Wall -Werror -Wno-deprecated-declarations -g -O1 -fsanitize=address,undefined \
  -I "$G" -I "$R/pkg/runtime/core" -I "$R/tests/host" "$R/tests/host/tex_evict_test.mm" "$G/ps4_gnm_resources.mm" \
  "$G/ps4_gnm_capture.cpp" "$T/membudget.o" "${BE[@]}" -framework Metal -framework Foundation -lz -o "$T/tex_evict_test"
for m in 3 4; do
  ( export PS4_GNM_METAL=$m; gpu "$T/tex_evict_test" ) > "$T/tex_evict.txt" 2>&1 || { cat "$T/tex_evict.txt"; exit 1; }
  tail -1 "$T/tex_evict.txt"
done
# CPU microtile detiling against the per-element address oracle, including clipped edges.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -Wno-deprecated-declarations -g -O1 -fsanitize=address,undefined \
  -I "$G" -I "$R/pkg/runtime/core" "$R/tests/host/gnm_cpu_detile_test.mm" "$G/ps4_gnm_resources.mm" \
  "$G/ps4_gnm_capture.cpp" "$T/membudget.o" "${BE[@]}" -framework Metal -framework Foundation -lz -o "$T/gnm_cpu_detile_test"
"$T/gnm_cpu_detile_test"
# Storage volumes retain their depth through GPU writes and sampled aliases.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -Wno-deprecated-declarations -g -O1 -fsanitize=address,undefined \
  -I "$G" -I "$R/pkg/runtime/core" -I "$R/tests/host" "$R/tests/host/gnm_storage_3d_test.mm" "$G/ps4_gnm_resources.mm" \
  "$G/ps4_gnm_capture.cpp" "$T/membudget.o" "${BE[@]}" -framework Metal -framework Foundation -lz -o "$T/gnm_storage_3d_test"
for m in 3 4; do
  ( export PS4_GNM_METAL=$m; gpu "$T/gnm_storage_3d_test" ) > "$T/storage_3d.txt" 2>&1 || { cat "$T/storage_3d.txt"; exit 1; }
  tail -1 "$T/storage_3d.txt"
done
# Array slices of POW2PAD T#s: the texture holds the image's slices (depth + 1, 6 per cube), the
# guest layout keeps the padded count (inFAMOUS Second Son's 256-cube BC6 cube array, laid out as
# 2048 faces, is a 256-cube Metal cube array; level 1 read after the padded slices of level 0).
clang++ -std=c++17 -fobjc-arc -Wall -Werror -Wno-deprecated-declarations -g -O1 -fsanitize=address,undefined \
  -I "$G" -I "$R/pkg/runtime/core" -I "$R/tests/host" "$R/tests/host/gnm_tex_layers_test.mm" "$G/ps4_gnm_resources.mm" \
  "$G/ps4_gnm_capture.cpp" "$T/membudget.o" "${BE[@]}" -framework Metal -framework Foundation -lz -o "$T/gnm_tex_layers_test"
for m in 3 4; do
  ( export PS4_GNM_METAL=$m; gpu "$T/gnm_tex_layers_test" ) > "$T/tex_layers.txt" 2>&1 || { cat "$T/tex_layers.txt"; exit 1; }
  tail -1 "$T/tex_layers.txt"
done
# Several GPU-owned surfaces at one address: sampling, storage binds and lookups take the last
# written surface of those that cover the image (inFAMOUS Second Son's half-resolution motion blur
# sampled the corner of the full-resolution target at the same address: a ghost image).
clang++ -std=c++17 -fobjc-arc -Wall -Werror -Wno-deprecated-declarations -g -O1 -fsanitize=address,undefined \
  -I "$G" -I "$R/pkg/runtime/core" -I "$R/tests/host" "$R/tests/host/gnm_rt_last_written_test.mm" "$G/ps4_gnm_resources.mm" \
  "$G/ps4_gnm_capture.cpp" "$T/membudget.o" "${BE[@]}" -framework Metal -framework Foundation -lz -o "$T/gnm_rt_last_written_test"
for m in 3 4; do
  ( export PS4_GNM_METAL=$m; gpu "$T/gnm_rt_last_written_test" ) > "$T/rt_last_written.txt" 2>&1 || { cat "$T/rt_last_written.txt"; exit 1; }
  tail -1 "$T/rt_last_written.txt"
done
# Every texture the cache makes goes through TextureCache::NewTextureLocked, which reports it to the
# residency hooks (Metal 4): no other texture creation (newTexture..., except views, which count as
# their parent) in ps4_gnm_resources.mm.
bad=$(awk '/^[A-Za-z].*[{] *$/ { fn = $0 } /^}/ { fn = "" } /newTexture/ && !/newTextureView/ && fn !~ /TextureCache::NewTextureLocked\(/ { print FILENAME ":" FNR ": " $0 }' "$G/ps4_gnm_resources.mm")
[ -z "$bad" ] || { echo "texture creation outside TextureCache::NewTextureLocked (not reported to the residency hooks):"; echo "$bad"; exit 1; }
# Frame capture on the TextureCache: entry identities, an entry re-created from its identity,
# and the raw layout of ReadRaw / WriteRaw (levels, slices, depth and stencil planes).
clang++ -std=c++17 -fobjc-arc -Wall -Werror -Wno-deprecated-declarations -g -O1 -fsanitize=address,undefined \
  -I "$G" -I "$R/pkg/runtime/core" -I "$R/tests/host" "$R/tests/host/gnm_capture_tex_test.mm" "$G/ps4_gnm_resources.mm" \
  "$G/ps4_gnm_capture.cpp" "$T/membudget.o" "${BE[@]}" -framework Metal -framework Foundation -lz -o "$T/gnm_capture_tex_test"
for m in 3 4; do
  ( export PS4_GNM_METAL=$m; gpu "$T/gnm_capture_tex_test" ) > "$T/gnm_capture_tex.txt" 2>&1 ||
    { cat "$T/gnm_capture_tex.txt"; exit 1; }
  tail -1 "$T/gnm_capture_tex.txt"
done
# Pass replay through the real renderer (tools/gnm_replay): a synthetic captured dispatch is
# translated, bound and encoded by ps4draw::Dispatch and matches its capture byte for byte; an
# altered capture is reported at the altered byte; seeded GPU-owned textures keep their contents.
"$R/tools/gnm_replay/build.sh" "$T/replay" "$R/tests/host/gnm_replay_test.mm" "$R/tests/host/gnm_guest_memory_test.mm" \
  "$R/tests/host/gnm_buffer_over_target_test.mm" "$R/tests/host/gnm_tsharp_table_test.mm" \
  "$R/tests/host/gnm_upload_bind_test.mm" "$R/tests/host/gnm_before_init_test.mm" "$R/tools/gnm_replay/gnm_replay.mm" \
  "$R/tests/host/gnm_exit_test.mm" "$R/tests/host/gnm_crash_exit_test.mm" "$R/tests/host/gnm_alias_dma_test.mm" \
  "$R/tests/host/gnm_compute_batch_test.mm" "$R/tests/host/gnm_detile_order_test.mm" \
  "$R/tests/host/gnm_addr64_test.mm" "$R/tests/host/gnm_htile_slices_test.mm" \
  "$R/tests/host/gnm_tex1d_test.mm" "$R/tests/host/gnm_cube_view_test.mm" \
  "$R/tests/host/gnm_indirect_quad_test.mm" "$R/tests/host/gnm_occlusion_query_test.mm" \
  "$R/tests/host/gnm_async_compute_test.mm" "$R/tests/host/gnm_replay_time_test.mm" \
  > "$T/replay_build.txt" 2>&1 || { cat "$T/replay_build.txt"; exit 1; }
# Each case on both backends, Metal 4 with the residency check.
for m in 3 4; do rtest $m "$T/replay/gnm_replay_test"; done
for m in 3 4; do rtest $m "$T/replay/gnm_replay_test" cpu-texture; done
# Guest windows that alias, through the renderer: GPU DMAs through a two-window and a one-window
# buffer over the same memory; on Metal 3 a copy of bytes written through the other window waits
# for that write once (not for other bytes, not after its seq completed) and reads what it wrote;
# a fill after a copy of its bytes through the other window waits for the copy (write after
# read); a job with two encoders orders its uses in each.
# "async-compute": the windows across the two queues (a compute-ring fill, the graphics join and
# copy: the copy's alias wait is left out and the join orders it).
for m in 3 4; do
  rtest $m "$T/replay/gnm_alias_dma_test"
  rtest $m "$T/replay/gnm_alias_dma_test" async-compute
done
# MUBUF ADDR64 loads (TLOU's hair and foliage shadow cascades): the address is the V# base plus
# the 64-bit VGPR pointer (with carry past 4 GiB) plus soffset and inst_offset, not range checked.
# Also in a pixel shader: the draw path binds the page table and the draws' fault slot; a page a
# draw met unmapped is mapped for the next draw.
for m in 3 4; do rtest $m "$T/replay/gnm_addr64_test"; done
# A compute HTILE clear of a depth array covers each slice it wrote (TLOU's 3-slice sun shadow
# array, the capture's registers and V#): every slice's first draw after it clears that slice;
# a clear of one slice's HTILE leaves the other slices as they were; a clear that arrives before the
# Metal array has grown still covers slices 1..n; HTILE slice sizes for 2, 8 and 16 pipes and linear
# HTILE (addrlib), and none for a Neo depth target (one-slice clears there).
for m in 3 4; do rtest $m "$T/replay/gnm_htile_slices_test"; done
# Batched compute commits (ps4draw::FlushCompute): while 2 seqs are in flight the end of a
# compute submission is held; two submissions share one compute encoder, a guest wait between them
# is a barrier in it; a Flush commits held work at once, the release thread within the bound
# (0.5 ms) or when the backlog drains, and the fence actions after it run. Encoder thread and
# PS4_GNM_SYNC_ENCODE, both backends; "off": PS4_GNM_COMPUTE_BATCH=0 commits every submission at once.
for m in 3 4; do
  for mode in sync async off; do rtest $m "$T/replay/gnm_compute_batch_test" $mode; done
done
# Asynchronous compute (PS4_GNM_ASYNC_COMPUTE=1): with the main queue held at a gate, an eligible
# compute-ring copy, its DMA and their labels complete, the labels in order; a graphics wait met by
# a pending compute label (JoinQueues) sees the compute results, and a compute wait met by a
# pending graphics label runs the rest of its submission behind graphics; a texture sampled over
# memory a compute copy rewrites reads the new texels after the join (also with every bind-time
# upload on the GPU: gpu-upload); a ring whose label graphics consumed runs on Main while another
# ring runs beside it; Flush(true) after both queues. Both backends ("off": every queue on the
# main one).
for m in 3 4; do
  for mode in sync async off; do
    rtest $m "$T/replay/gnm_async_compute_test" $mode
    rtest $m "$T/replay/gnm_async_compute_test" $mode gpu-upload
  done
done
# PS4_GNM_MTL4_ONLY_CLEARS=1 (debug): a draw is skipped once its render pass began, the pass's
# clear happens, and the draw is counted as skipped by the mode.
( export PS4_GNM_MTL4_ONLY_CLEARS=1; rtest 4 "$T/replay/gnm_replay_test" only-clears )
# The game's background compiles (no PS4_GNM_SYNC_COMPILE): the first draw of a program is deferred
# until its shaders and pipeline are ready and counted as pending, not as lost; a draw the renderer
# cannot do is counted as skipped only.
( export PS4_GNM_REPLAY_ASYNC_COMPILE=1; rtest 4 "$T/replay/gnm_replay_test" pending-compile )
# PS4_GNM_METAL=4 through the whole renderer starts without the debug mode now that the Metal 4
# backend has every capability; with PS4_GNM_MTL4_ONLY_CLEARS=1 (draws skipped) it still replays the
# dispatch byte for byte.
"$T/replay/gnm_replay_test" write-capture "$T/m4cap" > "$T/m4cap.txt" 2>&1 || { cat "$T/m4cap.txt"; exit 1; }
for oc in 0 1; do
  rc=0; ( export PS4_GNM_METAL=4; [ $oc = 1 ] && export PS4_GNM_MTL4_ONLY_CLEARS=1
          "$T/replay/gnm_replay" "$T/m4cap/frame_1" 0 ) > "$T/m4_$oc.txt" 2>&1 || rc=$?
  grep -q "backend metal4" "$T/m4_$oc.txt" && grep -q "^MATCH buffer" "$T/m4_$oc.txt" && [ $rc -eq 0 ] ||
    { echo "Metal 4 (only clears $oc) did not replay the dispatch (rc=$rc)"; cat "$T/m4_$oc.txt"; exit 1; }
done
# gnm_replay --settle on the stable dispatch: judged on the second replay, never UNSTABLE-FIRST,
# single pass (exit status and verdict) and range (no U line, the settled hash on the O line).
for m in 3 4; do
  rc=0; ( export PS4_GNM_METAL=$m; gpu "$T/replay/gnm_replay" "$T/m4cap/frame_1" 0 --settle ) > "$T/settle_$m.txt" 2>&1 || rc=$?
  ( export PS4_GNM_METAL=$m; gpu "$T/replay/gnm_replay" "$T/m4cap/frame_1" all --sha --settle ) > "$T/settle_r$m.txt" 2>&1 || rc=$?
  [ $rc -eq 0 ] && grep -q "^pass 0: BYTE-EXACT" "$T/settle_$m.txt" && ! grep -q "UNSTABLE-FIRST" "$T/settle_$m.txt" &&
    grep -q "^O 0 buffer_0x" "$T/settle_r$m.txt" && ! grep -q "^U " "$T/settle_r$m.txt" ||
    { echo "gnm_replay --settle (Metal $m, rc=$rc)"; cat "$T/settle_$m.txt" "$T/settle_r$m.txt"; exit 1; }
done
# gnm_replay --time: TimePasses times a 1-group and a 256-group dispatch (the larger one takes
# longer), and the command line prints one line per timed pass, the total for a range, and refuses
# to combine with --allocs, --settle and --sha (exit 2).
for m in 3 4; do rtest $m "$T/replay/gnm_replay_time_test"; done
"$T/replay/gnm_replay_time_test" write-capture "$T/timecap" > "$T/timecap.txt" 2>&1 || { cat "$T/timecap.txt"; exit 1; }
rc=0; ( export PS4_GNM_METAL=3; gpu "$T/replay/gnm_replay" "$T/timecap/frame_1" all --time 3 ) > "$T/time_cli.txt" 2>"$T/time_cli_err.txt" || rc=$?
line='median_ms [0-9]+\.[0-9]{3} min_ms [0-9]+\.[0-9]{3} runs 3$'
[ $rc -eq 0 ] && grep -Eq "^pass 0 dispatch 0x100000 $line" "$T/time_cli.txt" &&
  grep -Eq "^pass 1 dispatch 0x100000 $line" "$T/time_cli.txt" && grep -Eq '^total median_ms [0-9]+\.[0-9]{3}$' "$T/time_cli.txt" &&
  [ "$(wc -l < "$T/time_cli.txt")" -eq 3 ] && grep -q "pass 2 not timed: .*meta clear" "$T/time_cli_err.txt" ||
  { echo "gnm_replay --time output (rc=$rc)"; cat "$T/time_cli.txt" "$T/time_cli_err.txt"; exit 1; }
rc=0; ( export PS4_GNM_METAL=3; gpu "$T/replay/gnm_replay" "$T/timecap/frame_1" 1 --time 3 ) > "$T/time_one.txt" 2>&1 || rc=$?
[ $rc -eq 0 ] && grep -Eq "^pass 1 dispatch 0x100000 $line" "$T/time_one.txt" && ! grep -q "^total" "$T/time_one.txt" ||
  { echo "gnm_replay --time, one pass (rc=$rc)"; cat "$T/time_one.txt"; exit 1; }
for bad in "--allocs 2" "--settle" "--sha"; do
  rc=0; "$T/replay/gnm_replay" "$T/timecap/frame_1" 0 --time 3 $bad > "$T/time_bad.txt" 2>&1 || rc=$?
  [ $rc -eq 2 ] && grep -q "do not apply" "$T/time_bad.txt" ||
    { echo "gnm_replay --time $bad was not refused with exit 2 (rc=$rc)"; cat "$T/time_bad.txt"; exit 1; }
done
# The renderer's exit order: a program returning from main with GPU work in flight completes it
# and destroys the backend before the renderer's static objects (gnm_exit_test.mm).
for m in 3 4; do
  for sync in 0 1; do
    rc=0; ( export PS4_GNM_METAL=$m; [ $m = 4 ] && export PS4_GNM_RESIDENCY_CHECK=1
            [ $sync = 1 ] && export PS4_GNM_SYNC_ENCODE=1
            gpu "$T/replay/gnm_exit_test" ) > "$T/exit_$m.txt" 2>&1 || rc=$?
    grep -q "^gnm_exit_test: PASS" "$T/exit_$m.txt" && grep -q "backend metal$m" "$T/exit_$m.txt" && [ $rc -eq 0 ] &&
      ! grep -q "gnm-residency\] ASSERT" "$T/exit_$m.txt" ||
      { echo "gnm_exit_test on Metal $m (sync encode $sync): FAIL (rc=$rc)"; cat "$T/exit_$m.txt"; exit 1; }
    echo "$(grep "^gnm_exit_test" "$T/exit_$m.txt") [metal$m, sync encode $sync]"
  done
done
# A crash with the GPU stalled ends at once (gnm_crash_exit_test.mm): the renderer's exit handler
# does nothing after the crash handler's exit(1).
for m in 3 4; do
  rc=0; ( export PS4_GNM_METAL=$m; [ $m = 4 ] && export PS4_GNM_RESIDENCY_CHECK=1
          gpu "$T/replay/gnm_crash_exit_test" ) > "$T/crash_$m.txt" 2>&1 || rc=$?
  end=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  at=$(sed -n 's/^gnm_crash_exit_test: crashing at //p' "$T/crash_$m.txt")
  took=$(awk -v a="$at" -v b="$end" 'BEGIN { if (a == "") print "none"; else printf "%.2f", b - a }')
  grep -q "FATAL: Signal 11" "$T/crash_$m.txt" && [ $rc -eq 1 ] && [ "$took" != none ] && awk -v t="$took" 'BEGIN { exit !(t < 2) }' &&
    ! grep -q "gnm-residency\] ASSERT" "$T/crash_$m.txt" ||
    { echo "gnm_crash_exit_test on Metal $m: FAIL (rc=$rc, exit took ${took} s after the crash)"; cat "$T/crash_$m.txt"; exit 1; }
  echo "gnm_crash_exit_test: PASS [metal$m: exit ${took} s after the crash]"
done
# The allocation counter of gnm_replay --allocs: counts this thread's calls only, and the
# program refuses to report without the interposer (exit 3).
clang -std=gnu11 -Wall -Werror "$R/tests/host/alloc_count_test.c" -o "$T/alloc_count_test"
DYLD_INSERT_LIBRARIES="$T/replay/alloc_count.dylib" "$T/alloc_count_test"
rc=0; "$T/alloc_count_test" > /dev/null || rc=$?
[ $rc -eq 3 ] || { echo "alloc_count_test: without the interposer it did not refuse (rc=$rc)"; exit 1; }
# Buffer stores over a GPU-owned surface, replayed pass by pass: a store covering the whole surface
# makes the GPU copy guest memory into its texture before it is next sampled; a partial store
# keeps the GPU-only contents; a storage write after the store survives (the copy runs first).
for m in 3 4; do rtest $m "$T/replay/gnm_buffer_over_target_test"; done
# A texture uploaded on the GPU while a draw is being bound (upload command buffer): the draw's
# encoder serial is unchanged (it is per target), so it is drawn, not skipped.
for m in 3 4; do rtest $m "$T/replay/gnm_upload_bind_test"; done
# Indirect quad-list draws on the GPU path (no CPU drain to read their arguments): indexed with a
# record a dispatch writes just before, non-indexed from a start vertex, the last quad of
# max_index, a count past max_index (indices past it read 0); the pixels of the direct draws, no
# CPU wait while they are drawn; an indirect fan is still refused and counted by reason.
for m in 3 4; do
  for mode in "" async; do rtest $m "$T/replay/gnm_indirect_quad_test" $mode; done
done
# The guest detile dispatch of a texture copied on the GPU behind pending writes (GpuUploadTexture),
# in one seq: after the dispatch that wrote the tiled source (its barrier in that encoder), and two
# detiles reusing the staging buffer of one size class, each after the earlier copy from it read it;
# 2048x2048 surfaces, a slow producer writing the detile's first bytes last, 6 iterations with a new
# pattern each, byte-exact. It fails with the detile's barrier removed or misplaced (both backends),
# with untracked staging (Metal 3) and with PS4_GNM_MTL4_NO_BARRIERS=1 (Metal 4).
for m in 3 4; do rtest $m "$T/replay/gnm_detile_order_test"; done
# The entry points the command processor reaches before the renderer starts (compute barriers,
# flushes, fence actions) do nothing and do not reach for the backend.
gpu "$T/replay/gnm_before_init_test"
# Buffer loads and stores through V#s a compute shader loads at run time (Uncharted 4's GPU copy
# shader, capture r13c pass 21) through the renderer: probe, guest page table, dispatch; each
# destination gets its source's dwords, GCN's range check on loads and stores, an unimplemented
# V# format skips the dispatch. The fast path (no CPU wait) gives the same results; a probe that
# meets a new page re-runs the dispatch without a second effect; after a barrier the CP waits for
# such dispatches before it reads guest memory (also where a pass wrote outside its prediction:
# a resource table, a cached texture), per queue; a miss is re-run without further work.
# A result that never becomes final (hang-*): the CP's wait and the command buffer throttle give up
# on the GPU after the GPU timeout (separate runs: the renderer is hung afterwards). default: the
# fast path not requested, every guest memory dispatch is waited for. remap: windows dropped by
# remaps (also while a seq that used them waits behind a gate) and released by the idle sweep, and
# re-created under dispatches; on Metal 4 every bound resource must be resident (the bind-time
# check, rtest) and dropped windows leave the guest residency set once their seqs completed. Every
# mode on both backends.
for m in 3 4; do
  for mode in "" default hang-cp hang-throttle hang-fast-throttle remap; do
    rtest $m "$T/replay/gnm_guest_memory_test" "$FIX" $mode | tee -a "$T/fixture_cases.txt"
  done
done
# T# tables a compute shader indexes at run time (light records behind a V#, a table behind an
# SRT pointer indexed through a buffer, a loop over N records), sampled and image_load_mip'd
# through the renderer: each workgroup gets the texture its index selects, 0 past the table and
# for a record holding no T# (not created); the loop's entry count is part of the specialization;
# a table record written by a pending dispatch is copied after draining the GPU. Pending is judged
# at the CP's copy of the tables, not at encoding: a draw's VS and PS both read again after one
# drain; a CP DMA pending at the copy in a captured frame (whose passes start encoding with the
# GPU drained); with the encoder thread, a second reader encoded after the first one's drain; with
# the writer on the asynchronous compute queue, the reader after the join.
for m in 3 4; do
  for mode in "" capture async async-compute; do rtest $m "$T/replay/gnm_tsharp_table_test" $mode; done
done
# Every 1D texture is a 2D texture of height 1 (a 2D array for Color1DArray): BC1, mipmapped,
# plain RGBA8 and BC1 array Color1D T#s read through image_load_mip, image_sample_lz/_lz_o/_l/_d
# and image_get_resinfo give their texels, levels, slices and 1D sizes; the translation binds them
# as Color2D(Array) and keeps their specialization apart from 2D T#s'; the inFAMOUS 1x1 BC1 T#
# decodes as a valid 2D texture. Uploads on the CPU and on the GPU.
for m in 3 4; do
  for mode in "" gpu-upload; do rtest $m "$T/replay/gnm_tex1d_test" $mode; done
done
# Cube T#s are bound as the 2D arrays of faces the translator declares: image_sample_lz of faces
# of a cube (and of a POW2PAD cube) gives their texels, with Metal API validation on.
for m in 3 4; do ( export MTL_DEBUG_LAYER=1; rtest $m "$T/replay/gnm_cube_view_test" ) || exit 1; done
# Occlusion queries (ZPASS_DONE): the samples that pass the depth/stencil tests between a query's
# begin and end events, from Metal visibility results, in the guest's per-backend counter pairs
# (bit 63 valid); a draw behind the depth counts 0, a 16x16 one in front 256, one with the depth
# test off all its samples, and a query over two render passes both. Metal API validation on.
for m in 3 4; do ( export MTL_DEBUG_LAYER=1; rtest $m "$T/replay/gnm_occlusion_query_test" ) || exit 1; done
# RectList draws: a translated vertex shader drawn as rectangles (capture, barrier, expansion);
# the colours at all 4 corners of each rectangle, with Metal API validation on, on each backend.
clang++ -std=c++20 -fobjc-arc -Wall -Werror -I "$GR/include" -I "$G" -I "$R/tests/host" "$R/tests/host/gnm_rectlist_test.mm" \
  "$G/ps4_gnm_backend.mm" "$G/ps4_gnm_backend_metal3.mm" "$G/ps4_gnm_backend_metal4.mm" "$G/ps4_gnm_residency.mm" \
  "$GR/libgcn_recompiler.a" "$R/3rdparty/spirv-cross/libspirv-cross.a" -framework Metal -framework Foundation \
  -o "$T/gnm_rectlist_test" 2>&1 | { grep -v "ignoring duplicate libraries" || true; }
for m in 3 4; do
  btest $m 1 "$T/gnm_rectlist_test"
done
# Shader permutations with another SRT program are found (not re-translated per draw up to the
# cap), and the push constants bound cover the translated shaders' MSL struct.
clang++ -std=c++20 -fobjc-arc -Wall -Werror -I "$GR/include" -I "$G" "$R/tests/host/gnm_shader_perm_test.mm" \
  "$GR/libgcn_recompiler.a" "$R/3rdparty/spirv-cross/libspirv-cross.a" -framework Metal -framework Foundation \
  -o "$T/gnm_shader_perm_test" 2>&1 | { grep -v "ignoring duplicate libraries" || true; }
gpu "$T/gnm_shader_perm_test"
# Misaligned guest buffer bases: the shader reads the guest's bytes from the dword below.
clang++ -std=c++20 -fobjc-arc -Wall -Werror -I "$GR/include" "$R/tests/host/gcn_buffer_align_test.mm" \
  "$GR/libgcn_recompiler.a" "$R/3rdparty/spirv-cross/libspirv-cross.a" -framework Metal -framework Foundation \
  -o "$T/gcn_buffer_align_test" 2>&1 | { grep -v "ignoring duplicate libraries" || true; }
gpu "$T/gcn_buffer_align_test"
# The translator's output does not depend on the caller's FPCR.FZ (guest threads translate with
# the guest's flush to zero): integer constants that are denormal floats keep their bits.
clang++ -std=c++20 -fobjc-arc -Wall -Werror -I "$GR/include" "$R/tests/host/gcn_caller_fpenv_test.mm" \
  "$GR/libgcn_recompiler.a" "$R/3rdparty/spirv-cross/libspirv-cross.a" -framework Metal -framework Foundation \
  -o "$T/gcn_caller_fpenv_test" 2>&1 | { grep -v "ignoring duplicate libraries" || true; }
gpu "$T/gcn_caller_fpenv_test"
# Uncharted 4 chapter 1 compute shaders the translator rejected (EXEC half writes, sharps
# spilled to VGPR lanes, wave64 ballots through workgroup memory): translated and Metal-accepted.
clang++ -std=c++20 -fobjc-arc -Wall -Werror -I "$GR/include" "$R/tests/host/gcn_u4_cs_test.mm" \
  "$GR/libgcn_recompiler.a" "$R/3rdparty/spirv-cross/libspirv-cross.a" -framework Metal -framework Foundation \
  -o "$T/gcn_u4_cs_test" 2>&1 | { grep -v "ignoring duplicate libraries" || true; }
gpu "$T/gcn_u4_cs_test" "$FIX" 2>&1 | { grep -v "^\[gcn [WID]\]" || true; } | tee -a "$T/fixture_cases.txt"
# T#s / S#s not read from the resource tables as they are: loaded through a run-time V# (null
# image, counted, also after the shader cache; the S# cannot be fetched) or computed in the
# shader (the translation fails, naming the instruction).
clang++ -std=c++20 -fobjc-arc -Wall -Werror -I "$GR/include" "$R/tests/host/gcn_runtime_sharp_test.mm" \
  "$GR/libgcn_recompiler.a" "$R/3rdparty/spirv-cross/libspirv-cross.a" -framework Metal -framework Foundation \
  -o "$T/gcn_runtime_sharp_test" 2>&1 | { grep -v "ignoring duplicate libraries" || true; }
gpu "$T/gcn_runtime_sharp_test" 2>&1 | { grep -v "^\[gcn [WIDEC]\]\|^ImageRead at\|^ImageSampleRaw at" || true; }
# Mapping a compute queue drops its waiting submissions before the new mapping is published.
RT_INC=$(find "$R/pkg/runtime" -type d | sed 's/^/-I/' | tr '\n' ' ')
# shellcheck disable=SC2086
clang -std=gnu11 -Wall -Werror -g -fsanitize=address,undefined $RT_INC "$R/tests/host/gnm_compute_map_test.c" \
  "$G/ps4_gnmdriver.c" -o "$T/gnm_compute_map_test"
"$T/gnm_compute_map_test" > "$T/gnm_compute_map.txt" 2>&1 || { cat "$T/gnm_compute_map.txt"; exit 1; }
echo "gnm_compute_map_test: PASS"
# Fast-clear colours of integer/snorm targets, cleared by each backend's render pass.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" -I "$R/tests/host" "$R/tests/host/gnm_clear_color_test.mm" "${BE[@]}" \
  -framework Metal -framework Foundation -o "$T/gnm_clear_color_test"
for m in 3 4; do btest $m 0 "$T/gnm_clear_color_test"; done
# Backend selection (ps4_gnm_backend.h): default, explicit choices, every refusal of "4" says why.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" "$R/tests/host/gnm_backend_select_test.mm" "$G/ps4_gnm_backend.mm" \
  "$G/ps4_gnm_backend_metal4.mm" "$G/ps4_gnm_residency.mm" -framework Metal -framework Foundation \
  -o "$T/gnm_backend_select_test"
"$T/gnm_backend_select_test"
# Wave-level instructions executed on Metal through the backend, on both backends: EXEC half writes
# in a wave64, V# dwords spilled to VGPR lanes, a wave64 compare read from both halves.
clang++ -std=c++20 -fobjc-arc -Wall -Werror -I "$GR/include" -I "$G" -I "$R/tests/host" "$R/tests/host/gcn_wave_exec_test.mm" \
  "${BE[@]}" "$GR/libgcn_recompiler.a" "$R/3rdparty/spirv-cross/libspirv-cross.a" -framework Metal -framework Foundation \
  -o "$T/gcn_wave_exec_test" 2>&1 | { grep -v "ignoring duplicate libraries" || true; }
for m in 3 4; do
  btest $m 0 "$T/gcn_wave_exec_test"
done
# Residency sets of the Metal 4 backend (ps4_gnm_residency.h): deferred removal in seq order,
# cancellation, strong references, views, aborting misuse, and three threads at once (built with
# ThreadSanitizer, which fails the run on a data race); Metal 4 GPU writes into a no-copy window
# with and without a set (the negative control). The set-logic cases ignore PS4_GNM_METAL.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -g -fsanitize=thread -I "$G" -I "$R/tests/host" \
  "$R/tests/host/gnm_residency_test.mm" "${BE[@]}" -framework Metal -framework Foundation -o "$T/gnm_residency_test"
PS4_GNM_METAL=4 gpu "$T/gnm_residency_test"
# Command buffers and the seq timeline on each backend: per-target encoder state, event order,
# the seq split at events between render passes, compute dispatches, barriers and bindings,
# destruction with work in flight; Metal 4 allocator reuse after completion, bounded allocator
# memory, WaitForRoom on a stalled GPU.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" -I "$R/tests/host" "$R/tests/host/gnm_backend_cmd_test.mm" "${BE[@]}" \
  -framework Metal -framework Foundation -o "$T/gnm_backend_cmd_test"
for m in 3 4; do btest $m 0 "$T/gnm_backend_cmd_test"; done
# Any other PS4_GNM_METAL value must not run (and report PASS for) a backend it did not name.
if PS4_GNM_METAL=metal4 "$T/gnm_backend_cmd_test" > "$T/gnm_backend_cmd_bad_env.txt" 2>&1; then
  echo "gnm_backend_cmd_test: FAIL: PS4_GNM_METAL=metal4 ran a backend"; exit 1
fi
grep -q "FATAL: PS4_GNM_METAL=metal4" "$T/gnm_backend_cmd_bad_env.txt" || { cat "$T/gnm_backend_cmd_bad_env.txt"; exit 1; }
# A clear presented and read back (clear, present conversion, slot copy, ready signal) and the
# render bindings of a draw (bytes past one Metal 4 arena chunk, buffer, buffer offset), equal on
# both backends.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" -I "$R/tests/host" "$R/tests/host/gnm_backend_present_test.mm" "${BE[@]}" \
  -framework Metal -framework Foundation -o "$T/gnm_backend_present_test"
for m in 3 4; do btest $m 0 "$T/gnm_backend_present_test"; done
# Every copy and fill on each backend (Metal 4 output compared with Metal 3's), dependent copies
# in one copy group, the upload command buffer ordered before the main one.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" -I "$R/tests/host" "$R/tests/host/gnm_backend_copy_test.mm" "${BE[@]}" \
  -framework Metal -framework Foundation -o "$T/gnm_backend_copy_test"
for m in 3 4; do btest $m 0 "$T/gnm_backend_copy_test"; done
# Every draw kind, SetFixed, depth/stencil, MSAA resolve with sample positions, array slices and an
# indirect dispatch on each backend (Metal 4 output compared with Metal 3's).
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" -I "$R/tests/host" "$R/tests/host/gnm_backend_draw_test.mm" "${BE[@]}" \
  -framework Metal -framework Foundation -o "$T/gnm_backend_draw_test"
for m in 3 4; do btest $m 1 "$T/gnm_backend_draw_test"; done
# Barrier coverage: a render pass sampling a texture a compute pass just wrote sees every texel,
# on each backend; on Metal 4 without encoder barriers the test sees the race (its teeth).
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" -I "$R/tests/host" "$R/tests/host/gnm_backend_barrier_test.mm" "${BE[@]}" \
  -framework Metal -framework Foundation -o "$T/gnm_backend_barrier_test"
for m in 3 4; do btest $m 0 "$T/gnm_backend_barrier_test"; done
# Guest windows that alias: accesses of the same bytes through a two-window and a one-window
# buffer (same seq, next seq behind a gate), with Metal API validation: compute, blit and vertex
# reads after a slow compute write, compute reads after a slow fragment write and after a large
# blit fill, and a blit fill after a slow compute read (write after read). Ordered by the access
# fences they all are right; unordered on Metal 3 each case goes wrong (the teeth). On Metal 4 the
# encoder-start barriers order them (with PS4_GNM_MTL4_NO_BARRIERS=1 the tries fail).
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" -I "$R/tests/host" "$R/tests/host/gnm_backend_alias_test.mm" "${BE[@]}" \
  -framework Metal -framework Foundation -o "$T/gnm_backend_alias_test"
for m in 3 4; do btest $m 1 "$T/gnm_backend_alias_test"; done
# Metal3Backend (ps4_gnm_backend_metal3.h): seq timeline and completion, upload before main,
# queue event waits, per-target encoder serial.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" "$R/tests/host/gnm_backend_metal3_test.mm" \
  "$G/ps4_gnm_backend_metal3.mm" "$G/ps4_gnm_backend.mm" -framework Metal -framework Foundation \
  -o "$T/gnm_backend_metal3_test"
gpu "$T/gnm_backend_metal3_test"
# A vertex input from a V# with stride 0 (constant step): accepted by Metal and a binary archive,
# and every vertex reads the one element (ps4_gnm_vertex_layout.h).
clang++ -std=c++20 -fobjc-arc -Wall -Werror -I "$G" "$R/tests/host/gnm_vertex_layout_test.mm" \
  -framework Metal -framework Foundation -o "$T/gnm_vertex_layout_test"
gpu "$T/gnm_vertex_layout_test"
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" "$R/tests/host/pso_archive_test.mm" "$G/ps4_gnm_pipeline_archive.mm" \
  "$G/ps4_gnm_library_store.mm" -framework Metal -framework Foundation -o "$T/pso_archive_test"
A="$T/archive"; mkdir -p "$A"
# A fresh shader per suite run (nonce) keeps pipeline caches of earlier runs from satisfying it.
NONCE=$(( $(date +%s) % 100000 * 10 + RANDOM % 10 ))
gpu "$T/pso_archive_test" write "$A" $NONCE
gpu "$T/pso_archive_test" read "$A" $NONCE
gpu "$T/pso_archive_test" append "$A" $NONCE
gpu "$T/pso_archive_test" read2 "$A" $NONCE
gpu "$T/pso_archive_test" stale "$A" $NONCE
gpu "$T/pso_archive_test" write "$A" $NONCE
gpu "$T/pso_archive_test" budget "$A" $NONCE
gpu "$T/pso_archive_test" write "$A" $NONCE
gpu "$T/pso_archive_test" corrupt "$A" $NONCE
# Two processes on one directory: hold owns it, lookup (meanwhile) must change nothing; once
# hold is gone, read owns it again.
L="$T/shared"; mkdir -p "$L"
gpu "$T/pso_archive_test" write "$L" $NONCE
"$T/pso_archive_test" hold "$L" $NONCE > "$T/hold.txt" &
HOLD=$!
for n in $(seq 300); do grep -q holding "$T/hold.txt" && break; sleep 0.1; done
grep -q holding "$T/hold.txt" || { echo "pso_archive_test: hold did not start"; kill $HOLD; exit 1; }
gpu "$T/pso_archive_test" lookup "$L" $NONCE || { kill $HOLD; exit 1; }
kill $HOLD; wait $HOLD 2>/dev/null || true
gpu "$T/pso_archive_test" read "$L" $NONCE
# eviction: 6 one-pipeline files, then a cap of 4 files
E="$T/evict"; mkdir -p "$E"
for k in 0 1 2 3 4 5; do gpu "$T/pso_archive_test" add$k "$E" $NONCE; done
PS4_GNM_PSO_ARCHIVE_MAX_FILES=4 gpu "$T/pso_archive_test" evict "$E" $NONCE
gpu "$T/pso_archive_test" evicted "$E" $NONCE
B="$T/budgetstop"; mkdir -p "$B"
gpu "$T/pso_archive_test" budgetstop "$B" $NONCE
# Shader library store: key and format units, then write / read (new process, no compiler) /
# corrupt / other options, the size budget on a second directory, and the pipeline-failure
# fallback with the session circuit breaker on a third.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" "$R/tests/host/lib_store_test.mm" "$G/ps4_gnm_library_store.mm" \
  -framework Metal -framework Foundation -o "$T/lib_store_test"
gpu "$T/lib_store_test" unit
LS="$T/libstore"; mkdir -p "$LS"
for m in write read corrupt config; do gpu "$T/lib_store_test" $m "$LS" $NONCE; done
LB="$T/libbudget"; mkdir -p "$LB"
gpu "$T/lib_store_test" write "$LB" $NONCE
gpu "$T/lib_store_test" budget "$LB" $NONCE
LK="$T/libbreaker"; mkdir -p "$LK"
gpu "$T/lib_store_test" write "$LK" $NONCE
gpu "$T/lib_store_test" breaker "$LK" $NONCE
# Compute kernels compiled in the background: Start does not block, compiles overlap, an
# encoder-like thread waiting in order gets correct kernels, one job per MSL, failures stick.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" "$R/tests/host/kernel_compile_test.mm" "$G/ps4_gnm_kernel_compile.mm" \
  -framework Metal -framework Foundation -o "$T/kernel_compile_test"
gpu "$T/kernel_compile_test" $NONCE
# GCN translation cache lookups with 3000 permutations of one program: found from memory in the
# session that stored them (files deleted), never waiting for the startup loader of a new
# process, and at a cost that does not grow with the number of permutations.
GC="$R/3rdparty/gcn-recompiler"
clang -std=gnu11 -Wall -Werror -O2 -I "$R/pkg/runtime/core" -I "$R/pkg/runtime/kernel/vfs" -c "$R/pkg/runtime/core/ps4_game_key.c" \
  -o "$T/gcnl_game_key.o"
clang -std=gnu11 -Wall -Werror -O2 -I "$R/pkg/runtime/core" -I "$R/pkg/runtime/kernel/vfs" -c "$R/pkg/runtime/core/ps4_game_key_current.c" \
  -o "$T/gcnl_game_key_current.o"
clang -std=gnu11 -Wall -Werror -O2 -I "$R/pkg/runtime/core" -I "$R/pkg/runtime/kernel/vfs" -c "$R/pkg/runtime/core/ps4_sfo.c" \
  -o "$T/gcnl_sfo.o"
clang++ -std=c++17 -fobjc-arc -O2 -Wall -Werror -I "$G" -I "$GC/include" -I "$R/pkg/runtime/core" "$R/tests/host/gcn_cache_lookup_test.mm" \
  "$G/ps4_gnm_shader_cache.mm" "$T/gcnl_game_key.o" "$T/gcnl_game_key_current.o" "$T/gcnl_sfo.o" \
  "$GC/libgcn_recompiler.a" "$R/3rdparty/spirv-cross/libspirv-cross.a" -framework Foundation -o "$T/gcn_cache_lookup_test"
mkdir -p "$T/gcnl_s" "$T/gcnl_r" "$T/gcnl_o"
"$T/gcn_cache_lookup_test" session "$T/gcnl_s" 3000 2>&1 | grep '^gcn_cache_lookup_test'
"$T/gcn_cache_lookup_test" write "$T/gcnl_r" 3000 2>&1 | grep '^gcn_cache_lookup_test'
"$T/gcn_cache_lookup_test" restart "$T/gcnl_r" 3000 2>&1 | grep '^gcn_cache_lookup_test'
# an entry of another resource layout in the bucket: found through the one-by-one path
"$T/gcn_cache_lookup_test" odd "$T/gcnl_o" 500 2>&1 | grep '^gcn_cache_lookup_test'
# Capture tools (tools/*.py): overview page, fixture extraction, reference comparison.
python3 -m unittest discover -s "$R/tools/tests" -p 'test_*.py' > "$T/tools_tests.txt" 2>&1 || { cat "$T/tools_tests.txt"; exit 1; }
echo "capture tools: PASS ($(grep -o 'Ran [0-9]* tests' "$T/tools_tests.txt"))"
skipped=$(grep -c '^SKIP:' "$T/fixture_cases.txt" || true)
if [ "$skipped" -gt 0 ]; then
  echo "host tests: PASS, $skipped case(s) SKIPPED (local game fixtures absent in $FIX, see tests/host/README.md)"
else
  echo "host tests: PASS (local game fixtures present)"
fi
rm -rf "$T"
