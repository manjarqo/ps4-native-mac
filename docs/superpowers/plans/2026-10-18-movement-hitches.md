# Movement Hitches and Crash on Exit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** No frame longer than 33 ms while walking in The Last of Us Remastered (from the second run after an update), and no crash report when the game is quit.

**Architecture:** First measure (long-frame log, walking benchmark, stall profiler, per-frame counters), then remove synchronous work from the frame: a persistent Metal binary archive for pipelines, shader preparation without file system calls, large texture uploads on the GPU. Hitches without renderer work get a spec addendum from the profiler data before any fix. Exit goes through `_exit` after saving the archive.

**Tech Stack:** C / C++17 / Objective-C++ (ARC), Metal (MTLBinaryArchive), Mach thread APIs, ninja, bash/awk.

**Spec:** `docs/superpowers/specs/2026-10-18-movement-hitches-design.md`

## Global Constraints

- Comments, README and documentation in English only (AGENTS.md). Reports to the owner are in Russian, outside the repository.
- No fake tests, no stubs that return 0, no temporary solutions (AGENTS.md).
- Automated game runs never use the owner's live saves: always `PS4RECOMP_DATA_DIR` pointing to a copy.
- Install builds into `tlou_build/eboot.app` only via temp file + `mv` + `codesign`, after `pgrep -fl MacOS/eboot` (the owner may be playing).
- Regenerate `/Volumes/ssd/The Last of Us Remastered Repack/ps4recomp-work/all-fixes.patch` under `bash -c` (zsh silently drops untracked files); check ~1.1 MB and ~88+ `diff --git` entries.
- Discard benchmark runs with outside load: loadavg after the run and `extload.txt` (other processes' CPU). The game alone keeps loadavg ~11–15.
- Every new behaviour has an environment switch: `PS4_GNM_NO_PSO_ARCHIVE=1`, `PS4_GNM_GPU_UPLOAD_MIN_KB=-1`.
- Thresholds: walking target 33 ms; pipeline archive budget 384 MB (`PS4_GNM_PSO_ARCHIVE_MB`); periodic archive save 300 s; GPU upload threshold 256 KB (`PS4_GNM_GPU_UPLOAD_MIN_KB`); profiler sampling period 1 ms, 8 frames deep, top 6 functions.

## Conventions used by every task

Paths:
- Repository: `~/ps4recomp-work/PS4Recomp` (branch `tlou-hitches`). Runtime sources: `pkg/runtime/...`.
- Build tree: `~/ps4recomp-work/tlou_build` (its `runtime/` is a copy of `pkg/runtime/`, plus objects).
- Test saves: `~/ps4recomp-work/data_user1441` (spore corridor, copy of the owner's SAVEDATA04), `~/ps4recomp-work/data_ch1` (chapter 1 courtyard).

Build (after any runtime change):

```bash
rsync -a --include='*/' --include='*.c' --include='*.h' --include='*.m' --include='*.mm' --include='*.cpp' --exclude='*' ~/ps4recomp-work/PS4Recomp/pkg/runtime/ ~/ps4recomp-work/tlou_build/runtime/
cd ~/ps4recomp-work/tlou_build && ninja 2>&1 | grep -E "error|FAILED" -A3 | head -40; ls -la ps4_app
```

Expected: no `error`/`FAILED` lines, `ps4_app` has a fresh timestamp. Do not build while a benchmark runs (it distorts the measurement).

New translation units are not in `build.ninja` until the project is regenerated. Add them with this command (replace `REL` with the path under `runtime/`, `RULE` with `compile_c` or `compile_mm`, `AFTER` with an existing object of the same directory):

```bash
cd ~/ps4recomp-work/tlou_build && python3 - <<'EOF'
REL, RULE, AFTER = 'kernel/threading/ps4_stall_profile.c', 'compile_c', 'kernel/threading/ps4_threading'
p = 'build.ninja'; s = open(p).read()
obj = 'runtime/' + REL.rsplit('.', 1)[0] + '.o'
if obj not in s:
    anchor_obj = 'runtime/' + AFTER + '.o'
    line_start = s.index('build ' + anchor_obj + ':')
    line_end = s.index('\n', line_start) + 1
    s = s[:line_end] + f'build {obj}: {RULE} runtime/{REL}\n' + s[line_end:]
    s = s.replace(' ' + anchor_obj + ' ', ' ' + anchor_obj + ' ' + obj + ' ', 1)
    open(p, 'w').write(s)
print(obj, 'in build.ninja:', obj in open(p).read())
EOF
```

Benchmark binaries: copy `tlou_build/ps4_app` to `tlou_build/ps4_app_<label>` before running, and pass `ps4_app_<label>` to the scripts.

---

### Task 0: Snapshot of the current work

The working tree holds the uncommitted work of earlier sessions (renderer threads, fibers, mutexes...). Commit it once so every task below is a clean diff.

**Files:** none changed.

- [ ] **Step 1: Commit the snapshot**

```bash
cd ~/ps4recomp-work/PS4Recomp
git switch tlou-hitches
git add -A -- . ':!3rdparty' ':!*.orig' ':!*.rej' ':!*.a' ':!difftest/lifter-difftest'
git commit -q -m "Snapshot of TLOU work before the movement hitch fixes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git status --short | grep -v '^ ?' | grep -v '^??' | head
```

Expected: the last command prints nothing (only untracked 3rdparty/orig/binary entries remain).

---

### Task 1: Log markers for the walking benchmark

**Files:**
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm` (frame-time block in `PresentImpl`, the one starting with the comment `// Frame-time distribution (present-to-present on the submitting thread)`)
- Modify: `pkg/runtime/modules/libScePad/ps4_pad.m` (PS4_PAD_SCRIPT stepping in `scePadReadState`)

**Interfaces:**
- Produces log lines used by Task 2: `[gnm-draw] long frame <ms> ms (present <n>)` and `[pad] script started at <ms> ms`.

- [ ] **Step 1: Run the game and confirm neither line exists yet**

```bash
cd ~/ps4recomp-work && rm -rf data_tmp_t1 && cp -R data_ch1 data_tmp_t1
BIN=ps4_app PS4RECOMP_DATA_DIR=$PWD/data_tmp_t1 LOG=$PWD/run_t1.log EVERY=1000000 ./run_perf.sh $PWD/shots/t1 120 PS4_PRO=0 PS4_GNM_LOG_LONG_FRAMES=20 PS4_PAD_AUTOPRESS_UNTIL=90000 PS4_PAD_SCRIPT="95000:0:5000:128:0" >/dev/null 2>&1
grep -c "long frame\|script started" run_t1.log
```

Expected: `0`.

- [ ] **Step 2: Add the long-frame line**

In `ps4_gnm_draw.mm`, replace

```cpp
            if (last_present > 0) {
                const double dt = (now_t - last_present) * 1000.0;
                intervals.push_back((float)dt);
```

with

```cpp
            if (last_present > 0) {
                const double dt = (now_t - last_present) * 1000.0;
                intervals.push_back((float)dt);
                // PS4_GNM_LOG_LONG_FRAMES=<ms>: one line per frame longer than <ms> (walking
                // benchmark: counts long frames inside its own time window)
                static const double long_ms = [] {
                    const char* v = getenv("PS4_GNM_LOG_LONG_FRAMES");
                    return v ? atof(v) : 0.0;
                }();
                if (long_ms > 0 && dt > long_ms)
                    fprintf(stderr, "[gnm-draw] long frame %.1f ms (present %llu)\n", dt,
                            (unsigned long long)S.present_idx + 1);
```

- [ ] **Step 3: Add the script start marker**

In `ps4_pad.m`, replace

```c
    if (nsteps > 0) {
      struct timespec now;
      clock_gettime(CLOCK_MONOTONIC, &now);
      long ms = (now.tv_sec - t0.tv_sec) * 1000 + (now.tv_nsec - t0.tv_nsec) / 1000000;
      if (pad_clock_frames) ms = (long)(g_ps4_videoout_flip_count * 1000 / 30);
```

with

```c
    if (nsteps > 0) {
      struct timespec now;
      clock_gettime(CLOCK_MONOTONIC, &now);
      long ms = (now.tv_sec - t0.tv_sec) * 1000 + (now.tv_nsec - t0.tv_nsec) / 1000000;
      if (pad_clock_frames) ms = (long)(g_ps4_videoout_flip_count * 1000 / 30);
      // marks the start of the scripted part of a run (the walking benchmark measures after it)
      static int announced = 0;
      if (!announced && ms >= steps[0].t) {
        announced = 1;
        fprintf(stderr, "[pad] script started at %ld ms\n", ms);
      }
```

- [ ] **Step 4: Build and rerun Step 1**

Build (see Conventions), then rerun the commands of Step 1 with `grep -c "long frame"` and `grep -c "script started"` separately.

Expected: `long frame` count > 0 (loading frames exceed 20 ms), `script started` count = 1, and `grep "long frame" run_t1.log | head -2` shows the exact format `[gnm-draw] long frame 41.3 ms (present 12)`.

- [ ] **Step 5: Commit**

```bash
cd ~/ps4recomp-work/PS4Recomp
git add pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm pkg/runtime/modules/libScePad/ps4_pad.m
git commit -q -m "Log long frames and the pad script start for benchmarks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Walking benchmark

**Files (outside the repository, the owner's tool directory):**
- Create: `~/ps4recomp-work/tools/walk_bench.sh`
- Create: `~/ps4recomp-work/tools/walk_bench_report.awk`
- Create: `~/ps4recomp-work/tools/test_walk_bench.sh`

**Interfaces:**
- Consumes: the log lines of Task 1; `hitch` lines (extended in Task 5); `[stall-profile]` lines (Task 4).
- Produces: `walk_bench.sh <spores|courtyard> <binary> <label>` → `~/ps4recomp-work/walk_bench/<label>-<route>/{run.log,report.txt,extload.txt,load.txt}`; first report line `frames >33ms N, >100ms N, max X ms, p99 Y ms, avg fps Z (W frames)`.

- [ ] **Step 1: Write the report test with a fixture**

`~/ps4recomp-work/tools/test_walk_bench.sh`:

```bash
#!/bin/bash
# Checks walk_bench_report.awk on a fixed log.
set -euo pipefail
D=$(mktemp -d)
cat > "$D/run.log" <<'EOF'
[gnm-draw] long frame 250.0 ms (present 10)
[pad] script started at 100004 ms
[gnm-draw] perf: 60.0 fps over last 300 presents; per frame: x
[gnm-draw] long frame 40.0 ms (present 400)
[gnm-draw] hitch: frame 120.0 ms; shaders 0
[gnm-draw] long frame 120.0 ms (present 401)
[gnm-draw] perf: 50.0 fps over last 300 presents; per frame: x
[stall-profile] stall 120 ms, 70 samples
EOF
cat > "$D/expected.txt" <<'EOF'
frames >33ms 2, >100ms 1, max 120.0 ms, p99 <=33 ms, avg fps 55.0 (600 frames)
[gnm-draw] hitch: frame 120.0 ms; shaders 0
[stall-profile] stall 120 ms, 70 samples
EOF
awk -f "$(dirname "$0")/walk_bench_report.awk" "$D/run.log" > "$D/out.txt"
diff -u "$D/expected.txt" "$D/out.txt" && echo "test_walk_bench: PASS"
rm -rf "$D"
```

What the fixture checks: the long frame before the marker (250 ms, loading) does not count; the window has 2 perf lines = 600 frames; p99 is the k-th largest frame time with k = ceil(frames × 0.01) = 6, and only 2 frames were logged above 33 ms, so p99 is printed as `<=33`.

Append a second case to the same script (before the final `rm -rf "$D"`): 8 of 600 frames are long, so p99 is the 6th largest of 41..34 = 36.0:

```bash
{
  echo "[pad] script started at 100000 ms"
  echo "[gnm-draw] perf: 60.0 fps over last 300 presents; per frame: x"
  for ms in 34 41 35 40 36 39 37 38; do echo "[gnm-draw] long frame $ms.0 ms (present 1)"; done
  echo "[gnm-draw] perf: 60.0 fps over last 300 presents; per frame: x"
} > "$D/run2.log"
echo "frames >33ms 8, >100ms 0, max 41.0 ms, p99 36.0 ms, avg fps 60.0 (600 frames)" > "$D/expected2.txt"
awk -f "$(dirname "$0")/walk_bench_report.awk" "$D/run2.log" > "$D/out2.txt"
diff -u "$D/expected2.txt" "$D/out2.txt" && echo "test_walk_bench p99: PASS"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash ~/ps4recomp-work/tools/test_walk_bench.sh`
Expected: FAIL (awk: can't open file walk_bench_report.awk).

- [ ] **Step 3: Write the report script**

`~/ps4recomp-work/tools/walk_bench_report.awk`:

```awk
# Summarises a walking-benchmark log: only lines after "[pad] script started" count.
# p99 = k-th largest frame time, k = ceil(frames * 0.01); "<=33" when fewer than k frames
# were longer than the 33 ms logging threshold.
/\[pad\] script started/ { walking = 1; next }
!walking { next }
/\[gnm-draw\] long frame/ {
  ms = $4 + 0
  n33++
  if (ms > 100) n100++
  if (ms > max) max = ms
  # insertion sort, descending
  i = n33
  while (i > 1 && lf[i - 1] < ms) { lf[i] = lf[i - 1]; i-- }
  lf[i] = ms
  next
}
/\[gnm-draw\] perf:/ { fps_sum += $3; fps_n++; next }
/\[gnm-draw\] hitch:/ { out[++no] = $0; next }
/\[stall-profile\]/ { out[++no] = $0; next }
END {
  if (!walking) { print "walk_bench: no '[pad] script started' marker"; exit 1 }
  frames = fps_n * 300
  k = int(frames * 0.01); if (k < frames * 0.01) k++
  if (k < 1) k = 1
  p99 = (n33 >= k) ? sprintf("%.1f", lf[k]) : "<=33"
  printf "frames >33ms %d, >100ms %d, max %.1f ms, p99 %s ms, avg fps %.1f (%d frames)\n", n33, n100, max, p99, fps_n ? fps_sum / fps_n : 0, frames
  for (i = 1; i <= no; i++) print out[i]
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash ~/ps4recomp-work/tools/test_walk_bench.sh`
Expected: `test_walk_bench: PASS` and `test_walk_bench p99: PASS`

- [ ] **Step 5: Write the benchmark runner**

`~/ps4recomp-work/tools/walk_bench.sh`:

```bash
#!/bin/bash
# Walking benchmark: plays walk_script.txt from a copy of a save and reports long frames.
# usage: walk_bench.sh <spores|courtyard> <binary in tlou_build> <label>
# env: PROFILE_MS (stall profiler threshold, default 50; 0 = off), EXTRA (more env, "A=1 B=2")
set -euo pipefail
ROUTE=$1; BIN=$2; LABEL=$3
W=$HOME/ps4recomp-work
case "$ROUTE" in
  spores) SAVE=$W/data_user1441 ;;
  courtyard) SAVE=$W/data_ch1 ;;
  *) echo "walk_bench: unknown route $ROUTE" >&2; exit 2 ;;
esac
OUT=$W/walk_bench/$LABEL-$ROUTE
rm -rf "$OUT"; mkdir -p "$OUT"
cp -R "$SAVE" "$OUT/data"
"$W/mutex_perf/extload.sh" > "$OUT/extload.txt" 2>&1 &
EXT=$!
cd "$W"
# shellcheck disable=SC2086
BIN=$BIN PS4RECOMP_DATA_DIR="$OUT/data" LOG="$OUT/run.log" EVERY=1000000 ./run_perf.sh "$OUT/shots" 330 PS4_PRO=0 \
  PS4_PAD_AUTOPRESS_UNTIL=90000 PS4_PAD_SCRIPT="$(cat walk_script.txt)" PS4_GNM_LOG_LONG_FRAMES=33 \
  PS4_STALL_PROFILE=${PROFILE_MS:-50} ${EXTRA:-} >/dev/null 2>&1 || true
kill $EXT 2>/dev/null || true
echo "load $(sysctl -n vm.loadavg) fatal $(grep -c FATAL "$OUT/run.log" || true)" > "$OUT/load.txt"
awk -f "$W/tools/walk_bench_report.awk" "$OUT/run.log" > "$OUT/report.txt" || true
rm -rf "$OUT/data"
echo "== $LABEL $ROUTE: $(cat "$OUT/load.txt")"
head -1 "$OUT/report.txt"
```

`chmod +x` all three scripts. `PS4_STALL_PROFILE` is ignored by binaries before Task 4.

- [ ] **Step 6: Smoke run on the Task 1 build**

```bash
cp ~/ps4recomp-work/tlou_build/ps4_app ~/ps4recomp-work/tlou_build/ps4_app_t1
~/ps4recomp-work/tools/walk_bench.sh spores ps4_app_t1 t1
```

Expected: `== t1 spores: load {...} fatal 0` and a first report line with `frames >33ms` > 0 (the hitches of the spec are still there) and `avg fps` around 80–100.

(Nothing to commit: the tool directory is outside the repository.)

---

### Task 3: Stall profile aggregation (pure C, host-tested)

**Files:**
- Create: `pkg/runtime/kernel/threading/ps4_stall_profile.h`
- Create: `pkg/runtime/kernel/threading/ps4_stall_profile.c`
- Test: `tests/host/stall_profile_test.c`, `tests/host/run_host_tests.sh`

**Interfaces:**
- Produces (used by Task 4):

```c
typedef int (*stall_symbolize_fn)(uint64_t pc, uint64_t *func_start, const char **name);
typedef struct StallProfile StallProfile;
StallProfile *stall_profile_create(stall_symbolize_fn sym);
void stall_profile_destroy(StallProfile *p);
void stall_profile_reset(StallProfile *p);
void stall_profile_add(StallProfile *p, int slot, const char *thread_name, const uint64_t *pcs, int n);
void stall_profile_report(const StallProfile *p, FILE *out, double stall_ms, int top);
#define STALL_PROFILE_MAX_THREADS 64
#define STALL_PROFILE_DEPTH 8
```

- [ ] **Step 1: Write the failing test**

`tests/host/stall_profile_test.c`:

```c
// Host test for the stall profile aggregation (kernel/threading/ps4_stall_profile.c).
#include "ps4_stall_profile.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Fixed address map standing in for dladdr: [start, start + 0x1000) -> name.
static int fake_symbolize(uint64_t pc, uint64_t *start, const char **name) {
  static const struct { uint64_t start; const char *name; } map[] = {
      {0x1000, "fn_0x1000"}, {0x2000, "__psynch_cvwait"}, {0x3000, "fn_0x3000"}, {0x4000, "memcpy"}};
  for (size_t i = 0; i < sizeof map / sizeof map[0]; i++)
    if (pc >= map[i].start && pc < map[i].start + 0x1000) {
      *start = map[i].start;
      *name = map[i].name;
      return 1;
    }
  return 0;
}

int main(void) {
  StallProfile *p = stall_profile_create(fake_symbolize);
  const uint64_t busy[] = {0x1010, 0x3010};
  const uint64_t copy[] = {0x4010, 0x1020};
  const uint64_t wait[] = {0x2010, 0x2014, 0x3040};
  for (int i = 0; i < 6; i++) stall_profile_add(p, 0, "NdJobWorkerThread 0", busy, 2);
  for (int i = 0; i < 3; i++) stall_profile_add(p, 0, "NdJobWorkerThread 0", copy, 2);
  stall_profile_add(p, 0, "NdJobWorkerThread 0", wait, 3);
  for (int i = 0; i < 10; i++) stall_profile_add(p, 1, "Frame Submission", wait, 3);
  for (int i = 0; i < 10; i++) stall_profile_add(p, 2, "SceFiosIO", wait, 3); // idle, not printed

  char *buf = NULL;
  size_t len = 0;
  FILE *out = open_memstream(&buf, &len);
  stall_profile_report(p, out, 250.0, 6);
  fclose(out);
  const char *expected =
      "[stall-profile] stall 250 ms, 10 samples\n"
      "[stall-profile]   NdJobWorkerThread 0: busy 90%: fn_0x1000 60%, memcpy 30%, __psynch_cvwait in fn_0x3000 10%\n"
      "[stall-profile]   Frame Submission: busy 0%: __psynch_cvwait in fn_0x3000 100%\n";
  int ok = strcmp(buf, expected) == 0;
  if (!ok) printf("expected:\n%sgot:\n%s", expected, buf);

  stall_profile_reset(p);
  free(buf);
  buf = NULL;
  out = open_memstream(&buf, &len);
  stall_profile_report(p, out, 10.0, 6);
  fclose(out);
  if (strcmp(buf, "[stall-profile] stall 10 ms, 0 samples\n") != 0) {
    printf("after reset got:\n%s", buf);
    ok = 0;
  }
  free(buf);
  stall_profile_destroy(p);
  printf("stall_profile_test: %s\n", ok ? "PASS" : "FAIL");
  return ok ? 0 : 1;
}
```

Rules the test encodes: a sample is *waiting* when its leaf function is a kernel wait (`__psynch_*`, `__semwait_signal`, `__ulock_wait*`, `mach_msg*`, `kevent*`, `__workq_kernreturn`, `__select`, `semaphore_*wait*`); a waiting sample is keyed "<leaf> in <first frame whose name starts with fn_0x>". Threads are printed when busy ≥ 5 % or the thread is "Frame Submission". "N samples" is the largest per-thread sample count. Percentages are rounded to the nearest integer.

`tests/host/run_host_tests.sh`:

```bash
#!/bin/bash
# Builds and runs the host-side unit tests of runtime pieces that do not need the game.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
clang -std=gnu11 -Wall -Werror -I "$R/pkg/runtime/kernel/threading" "$R/tests/host/stall_profile_test.c" \
  "$R/pkg/runtime/kernel/threading/ps4_stall_profile.c" -o "$T/stall_profile_test"
"$T/stall_profile_test"
rm -rf "$T"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash ~/ps4recomp-work/PS4Recomp/tests/host/run_host_tests.sh`
Expected: FAIL — `ps4_stall_profile.h: file not found`.

- [ ] **Step 3: Write the header**

`pkg/runtime/kernel/threading/ps4_stall_profile.h`:

```c
// Aggregation of thread samples taken during a frame stall (PS4_STALL_PROFILE): counts the
// leaf host function of every sample per thread and reports the most frequent ones.
#pragma once
#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

#define STALL_PROFILE_MAX_THREADS 64
#define STALL_PROFILE_DEPTH 8

// Resolves pc to the start address and name of its function; returns 0 when unknown.
typedef int (*stall_symbolize_fn)(uint64_t pc, uint64_t *func_start, const char **name);

typedef struct StallProfile StallProfile;

StallProfile *stall_profile_create(stall_symbolize_fn sym);
void stall_profile_destroy(StallProfile *p);
void stall_profile_reset(StallProfile *p);
// One sample of thread `slot`: pcs[0] is the PC, pcs[1..n-1] the return addresses (innermost
// first). Symbolizes on the calling thread; never allocates.
void stall_profile_add(StallProfile *p, int slot, const char *thread_name, const uint64_t *pcs, int n);
// Prints "[stall-profile]" lines: the stall, then every thread that was busy for at least 5 %
// of its samples (and "Frame Submission" always) with its `top` most frequent functions.
void stall_profile_report(const StallProfile *p, FILE *out, double stall_ms, int top);

#ifdef __cplusplus
}
#endif
```

- [ ] **Step 4: Write the implementation**

`pkg/runtime/kernel/threading/ps4_stall_profile.c`:

```c
#include "ps4_stall_profile.h"
#include <stdlib.h>
#include <string.h>

#define STALL_PROFILE_MAX_FUNCS 128

typedef struct {
  uint64_t leaf, guest; // function starts (guest: 0 for busy samples)
  const char *leaf_name, *guest_name;
  uint32_t count;
  int waiting;
} StallFunc;

typedef struct {
  char name[32];
  uint32_t samples, busy, nfuncs;
  StallFunc funcs[STALL_PROFILE_MAX_FUNCS];
} StallThread;

struct StallProfile {
  stall_symbolize_fn sym;
  StallThread threads[STALL_PROFILE_MAX_THREADS];
};

static int is_wait_function(const char *n) {
  static const char *const prefixes[] = {"__psynch_", "__semwait_signal", "__ulock_wait", "mach_msg",
                                         "kevent", "__workq_kernreturn", "__select", "semaphore_"};
  for (size_t i = 0; i < sizeof prefixes / sizeof prefixes[0]; i++)
    if (strncmp(n, prefixes[i], strlen(prefixes[i])) == 0) {
      if (strncmp(n, "semaphore_", 10) == 0 && !strstr(n, "wait")) return 0;
      return 1;
    }
  return 0;
}

StallProfile *stall_profile_create(stall_symbolize_fn sym) {
  StallProfile *p = (StallProfile *)calloc(1, sizeof(StallProfile));
  if (p) p->sym = sym;
  return p;
}

void stall_profile_destroy(StallProfile *p) { free(p); }

void stall_profile_reset(StallProfile *p) {
  stall_symbolize_fn sym = p->sym;
  memset(p, 0, sizeof(*p));
  p->sym = sym;
}

void stall_profile_add(StallProfile *p, int slot, const char *thread_name, const uint64_t *pcs, int n) {
  if (!p || slot < 0 || slot >= STALL_PROFILE_MAX_THREADS || n <= 0) return;
  StallThread *t = &p->threads[slot];
  if (!t->name[0]) {
    strncpy(t->name, thread_name ? thread_name : "unnamed", sizeof(t->name) - 1);
  }
  t->samples++;
  uint64_t leaf = 0, guest = 0;
  const char *leaf_name = "?", *guest_name = NULL;
  if (!p->sym(pcs[0], &leaf, &leaf_name)) {
    leaf = pcs[0];
    leaf_name = "?";
  }
  const int waiting = is_wait_function(leaf_name);
  if (waiting) {
    for (int i = 1; i < n && i < STALL_PROFILE_DEPTH; i++) {
      uint64_t s;
      const char *nm;
      if (p->sym(pcs[i], &s, &nm) && strncmp(nm, "fn_0x", 5) == 0) {
        guest = s;
        guest_name = nm;
        break;
      }
    }
  } else {
    t->busy++;
  }
  for (uint32_t i = 0; i < t->nfuncs; i++) {
    StallFunc *f = &t->funcs[i];
    if (f->leaf == leaf && f->guest == guest) {
      f->count++;
      return;
    }
  }
  if (t->nfuncs == STALL_PROFILE_MAX_FUNCS) return; // table full: the sample still counts in totals
  StallFunc *f = &t->funcs[t->nfuncs++];
  f->leaf = leaf;
  f->guest = guest;
  f->leaf_name = leaf_name;
  f->guest_name = guest_name;
  f->count = 1;
  f->waiting = waiting;
}

static uint32_t pct(uint32_t part, uint32_t total) { return total ? (part * 100 + total / 2) / total : 0; }

void stall_profile_report(const StallProfile *p, FILE *out, double stall_ms, int top) {
  uint32_t rounds = 0;
  for (int s = 0; s < STALL_PROFILE_MAX_THREADS; s++)
    if (p->threads[s].samples > rounds) rounds = p->threads[s].samples;
  fprintf(out, "[stall-profile] stall %.0f ms, %u samples\n", stall_ms, rounds);
  for (int s = 0; s < STALL_PROFILE_MAX_THREADS; s++) {
    const StallThread *t = &p->threads[s];
    if (!t->samples) continue;
    const uint32_t busy = pct(t->busy, t->samples);
    if (busy < 5 && strcmp(t->name, "Frame Submission") != 0) continue;
    // order of the funcs by count (descending), stable for equal counts
    uint32_t order[STALL_PROFILE_MAX_FUNCS];
    for (uint32_t i = 0; i < t->nfuncs; i++) order[i] = i;
    for (uint32_t i = 1; i < t->nfuncs; i++) {
      uint32_t v = order[i], j = i;
      while (j > 0 && t->funcs[order[j - 1]].count < t->funcs[v].count) {
        order[j] = order[j - 1];
        j--;
      }
      order[j] = v;
    }
    fprintf(out, "[stall-profile]   %s: busy %u%%:", t->name, busy);
    for (uint32_t i = 0; i < t->nfuncs && (int)i < top; i++) {
      const StallFunc *f = &t->funcs[order[i]];
      fprintf(out, "%s %s", i ? "," : "", f->leaf_name);
      if (f->waiting && f->guest_name) fprintf(out, " in %s", f->guest_name);
      fprintf(out, " %u%%", pct(f->count, t->samples));
    }
    fprintf(out, "\n");
  }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash ~/ps4recomp-work/PS4Recomp/tests/host/run_host_tests.sh`
Expected: `stall_profile_test: PASS`

- [ ] **Step 6: Commit**

```bash
cd ~/ps4recomp-work/PS4Recomp
git add pkg/runtime/kernel/threading/ps4_stall_profile.h pkg/runtime/kernel/threading/ps4_stall_profile.c tests/host
git commit -q -m "Add stall profile aggregation with a host test

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Stall profiler sampling (PS4_STALL_PROFILE)

**Files:**
- Modify: `pkg/runtime/kernel/threading/ps4_threading.c` (section `// ---- Frame stall watchdog (diagnostics)`)
- Modify: `tlou_build/build.ninja` (new object, see Conventions: `REL='kernel/threading/ps4_stall_profile.c'`, `RULE='compile_c'`, `AFTER='kernel/threading/ps4_threading'`)

**Interfaces:**
- Consumes: Task 3 API.
- Produces: env `PS4_STALL_PROFILE=<ms>`; `[stall-profile]` lines at the end of every stall longer than `<ms>`.

- [ ] **Step 1: Replace the watchdog loop and start-up**

In `ps4_threading.c`, after `#include <time.h>` of the watchdog section add:

```c
#include <mach/mach_vm.h>
#include "ps4_stall_profile.h"

static StallProfile *g_stall_prof;
static uint64_t g_prof_for; // present time of the stall being profiled (0: none)

static int stall_symbolize(uint64_t pc, uint64_t *start, const char **name) {
  Dl_info di;
  if (!dladdr((void *)pc, &di) || !di.dli_sname) return 0;
  *start = (uint64_t)(uintptr_t)di.dli_saddr;
  *name = di.dli_sname;
  return 1;
}

// One sample of every guest thread: PC, LR and the saved return addresses along the
// frame-pointer chain. Threads are suspended only while their registers and stack are read;
// nothing that can take a lock (malloc, dladdr) runs while one is suspended.
static void stall_profile_sample_all(void) {
  struct {
    pthread_t th;
    char name[32];
  } list[STALL_PROFILE_MAX_THREADS];
  int n = 0;
  pthread_mutex_lock(&g_threads_mutex);
  for (RecompThread *t = g_threads; t && n < STALL_PROFILE_MAX_THREADS; t = t->next) {
    if (t->finished || !t->ctx) continue;
    list[n].th = t->host_thread;
    snprintf(list[n].name, sizeof(list[n].name), "%s", t->name[0] ? t->name : "unnamed");
    n++;
  }
  pthread_mutex_unlock(&g_threads_mutex);
  for (int i = 0; i < n; i++) {
    const mach_port_t port = pthread_mach_thread_np(list[i].th);
    if (port == MACH_PORT_NULL || thread_suspend(port) != KERN_SUCCESS) continue;
    uint64_t pcs[STALL_PROFILE_DEPTH];
    int np = 0;
    arm_thread_state64_t st;
    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(port, ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) == KERN_SUCCESS) {
      pcs[np++] = (uint64_t)arm_thread_state64_get_pc(st);
      pcs[np++] = (uint64_t)arm_thread_state64_get_lr(st);
      uint64_t fp = (uint64_t)arm_thread_state64_get_fp(st);
      while (np < STALL_PROFILE_DEPTH && fp && !(fp & 15)) {
        uint64_t frame[2];
        mach_vm_size_t got = 0;
        if (mach_vm_read_overwrite(mach_task_self(), fp, sizeof(frame), (mach_vm_address_t)(uintptr_t)frame,
                                   &got) != KERN_SUCCESS || got != sizeof(frame) || !frame[1])
          break;
        pcs[np++] = frame[1];
        if (frame[0] <= fp) break; // the chain grows toward the stack base
        fp = frame[0];
      }
    }
    thread_resume(port);
    if (np) stall_profile_add(g_stall_prof, i, list[i].name, pcs, np);
  }
}
```

Replace the whole `stall_watchdog_main` function and the start-up code in `ps4_stall_watchdog_note_present` with:

```c
static long g_stall_dump_ms, g_stall_prof_ms;

static void *stall_watchdog_main(void *arg) {
  (void)arg;
  const uint64_t dump_ns = (uint64_t)g_stall_dump_ms * 1000000ull;
  const uint64_t prof_ns = (uint64_t)g_stall_prof_ms * 1000000ull;
  uint64_t reported_for = 0;
  for (;;) {
    usleep(prof_ns ? 1000 : 5000);
    const uint64_t last = g_last_present_ns;
    if (!last) continue;
    const uint64_t now = stall_now_ns();
    if (dump_ns && now - last > dump_ns && reported_for != last) {
      reported_for = last;
      stall_dump_threads((double)(now - last) / 1e6);
    }
    if (!prof_ns) continue;
    if (g_prof_for && g_prof_for != last) { // a frame ended the stall being profiled
      stall_profile_report(g_stall_prof, stderr, (double)(last - g_prof_for) / 1e6, 6);
      g_prof_for = 0;
    }
    if (now - last > prof_ns) {
      if (g_prof_for != last) {
        stall_profile_reset(g_stall_prof);
        g_prof_for = last;
      }
      stall_profile_sample_all();
    }
  }
  return NULL;
}

void ps4_stall_watchdog_note_present(void) {
  static int started = 0;
  g_last_present_ns = stall_now_ns();
  if (!started) {
    started = 1;
    const char *e = getenv("PS4_STALL_WATCHDOG");
    const char *p = getenv("PS4_STALL_PROFILE");
    g_stall_dump_ms = e ? atol(e) : 0;
    g_stall_prof_ms = p ? atol(p) : 0;
    if (g_stall_prof_ms > 0) g_stall_prof = stall_profile_create(stall_symbolize);
    if (g_stall_prof_ms > 0 && !g_stall_prof) g_stall_prof_ms = 0;
    if (g_stall_dump_ms > 0 || g_stall_prof_ms > 0) {
      pthread_t th;
      pthread_create(&th, NULL, stall_watchdog_main, NULL);
      pthread_detach(th);
    }
  }
}
```

Also update the section comment above `#include <dlfcn.h>`:

```c
// ---- Frame stall watchdog (diagnostics) -----------------------------------------------
// PS4_STALL_WATCHDOG=<ms>: when no frame has been presented for <ms> milliseconds, print what
// every guest thread is executing (guest block address and host function), so long frames can
// be attributed to a thread and a guest function.
// PS4_STALL_PROFILE=<ms>: from <ms> into a stall until the next frame, sample every guest
// thread every millisecond and print the most frequent functions per thread at its end.
```

- [ ] **Step 2: Add the object to build.ninja and build**

Run the Conventions snippet with `REL, RULE, AFTER = 'kernel/threading/ps4_stall_profile.c', 'compile_c', 'kernel/threading/ps4_threading'`, then build.
Expected: `runtime/kernel/threading/ps4_stall_profile.o in build.ninja: True`, build without errors.

- [ ] **Step 3: Verify on the walking benchmark**

```bash
cp ~/ps4recomp-work/tlou_build/ps4_app ~/ps4recomp-work/tlou_build/ps4_app_t4
~/ps4recomp-work/tools/walk_bench.sh spores ps4_app_t4 t4
grep -c "^\[stall-profile\] stall" ~/ps4recomp-work/walk_bench/t4-spores/run.log
grep -A4 "^\[stall-profile\] stall [0-9]\{3\}" ~/ps4recomp-work/walk_bench/t4-spores/run.log | head -20
```

Expected: `fatal 0`; count > 0; every `stall N ms` header is followed by at least one thread line, and `N samples` is roughly `N ms − 50` (one sample per ms after the threshold). `avg fps` within ±5 % of the Task 2 smoke run (profiling only runs during stalls).

- [ ] **Step 4: Commit**

```bash
cd ~/ps4recomp-work/PS4Recomp
git add pkg/runtime/kernel/threading/ps4_threading.c
git commit -q -m "Sample guest threads during frame stalls (PS4_STALL_PROFILE)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Long-frame counters (io, vm, mtlbuf, texlock, shader_fs)

**Files:**
- Create: `pkg/runtime/core/ps4_hitch.h`
- Modify: `pkg/runtime/core/recomp_runtime.c` (definitions, end of file)
- Modify: `pkg/runtime/kernel/syscalls/ps4_syscalls.c` (every `pread(`/`read(` into guest memory: lines with `ssize_t nread = pread(`, `ssize_t ret = read(`, `ssize_t ret = pread(`)
- Modify: `pkg/runtime/kernel/aio/ps4_aio.c` (`execute_read_request`)
- Modify: `pkg/runtime/kernel/memory/ps4_direct_mem.c` (`dm_alias`, `ps4_direct_mem_on_unmap`)
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm` (`GuestBuffer`, `DropRemappedWindows`, `StoreMslInDiskCache`, hitch line)
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.mm` (all 16 `std::lock_guard<std::mutex> lk(mutex_);`)

**Interfaces:**
- Produces (used by Tasks 10, 11):

```c
enum { PS4_HITCH_IO = 0, PS4_HITCH_VM, PS4_HITCH_MTLBUF, PS4_HITCH_TEXLOCK, PS4_HITCH_SHADER_FS, PS4_HITCH_KINDS };
uint64_t ps4_hitch_now_ns(void);
void ps4_hitch_add_ns(int kind, uint64_t ns);
uint64_t ps4_hitch_take_ns(int kind); // returns the sum since the last take and clears it
```

- Hitch line gains `; io X, vm X, mtlbuf X, texlock X, shader_fs X ms` (sums over all threads since the previous present).

- [ ] **Step 1: Header**

`pkg/runtime/core/ps4_hitch.h`:

```c
// Host time spent in calls that can stall a frame, summed over all threads between two
// presents and printed in the long-frame breakdown ("[gnm-draw] hitch").
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { PS4_HITCH_IO = 0, PS4_HITCH_VM, PS4_HITCH_MTLBUF, PS4_HITCH_TEXLOCK, PS4_HITCH_SHADER_FS, PS4_HITCH_KINDS };

uint64_t ps4_hitch_now_ns(void);
void ps4_hitch_add_ns(int kind, uint64_t ns);
uint64_t ps4_hitch_take_ns(int kind);

// Runs one statement and adds its duration to a counter, e.g.
//   ssize_t ret; PS4_HITCH_TIMED(PS4_HITCH_IO, ret = pread(fd, buf, n, off));
#define PS4_HITCH_TIMED(kind, stmt)                                  \
  do {                                                               \
    const uint64_t ps4_hitch_t0_ = ps4_hitch_now_ns();               \
    stmt;                                                            \
    ps4_hitch_add_ns((kind), ps4_hitch_now_ns() - ps4_hitch_t0_);    \
  } while (0)

#ifdef __cplusplus
}
#endif
```

- [ ] **Step 2: Definitions**

Append to `pkg/runtime/core/recomp_runtime.c`:

```c
// ---- Long-frame counters (ps4_hitch.h) ---------------------------------------------------
#include "ps4_hitch.h"
#include <stdatomic.h>

static _Atomic uint64_t g_hitch_ns[PS4_HITCH_KINDS];

uint64_t ps4_hitch_now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

void ps4_hitch_add_ns(int kind, uint64_t ns) {
  if ((unsigned)kind < PS4_HITCH_KINDS) atomic_fetch_add_explicit(&g_hitch_ns[kind], ns, memory_order_relaxed);
}

uint64_t ps4_hitch_take_ns(int kind) {
  return (unsigned)kind < PS4_HITCH_KINDS ? atomic_exchange_explicit(&g_hitch_ns[kind], 0, memory_order_relaxed) : 0;
}
```

- [ ] **Step 3: io**

`ps4_syscalls.c` and `ps4_aio.c`: add `#include "ps4_hitch.h"` after the first include. Every file read of the form `ssize_t <var> = pread|read|preadv(fd, ...);` becomes a declaration plus a timed assignment:

```bash
cd ~/ps4recomp-work/PS4Recomp/pkg/runtime/kernel
perl -pi -e 's/^(\s*)ssize_t (\w+) = (pread|read|preadv)\((fd, .*)\);$/$1ssize_t $2;\n$1PS4_HITCH_TIMED(PS4_HITCH_IO, $2 = $3($4));/' syscalls/ps4_syscalls.c aio/ps4_aio.c
grep -c "PS4_HITCH_TIMED(PS4_HITCH_IO" syscalls/ps4_syscalls.c aio/ps4_aio.c
```

Expected: `syscalls/ps4_syscalls.c:6` (the two `nread = pread`, the two `ret = read`, `ret = pread` in `shim_sceKernelPread`, `ret = preadv` in `shim_sceKernelPreadv`) and `aio/ps4_aio.c:1` (`execute_read_request`). Example result:

```c
  ssize_t ret;
  PS4_HITCH_TIMED(PS4_HITCH_IO, ret = pread(fd, ctx->mem_base + buf_addr, nbytes, offset));
```

- [ ] **Step 4: vm**

`ps4_direct_mem.c`: add `#include "ps4_hitch.h"` after `#include "ps4_direct_mem.h"`. In `dm_alias` replace

```c
    kern_return_t kr = mach_vm_remap(mach_task_self(), &target, len, 0,
                                     VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
                                     (mach_vm_address_t)(uintptr_t)(g_phys_base + phys), FALSE,
                                     &cur, &max, VM_INHERIT_SHARE);
```

with

```c
    kern_return_t kr;
    PS4_HITCH_TIMED(PS4_HITCH_VM, kr = mach_vm_remap(mach_task_self(), &target, len, 0,
                                                     VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
                                                     (mach_vm_address_t)(uintptr_t)(g_phys_base + phys), FALSE,
                                                     &cur, &max, VM_INHERIT_SHARE));
```

and in `ps4_direct_mem_on_unmap` replace

```c
        mmap(proc->mem_base + ostart, oend - ostart, PROT_READ | PROT_WRITE,
             MAP_FIXED | MAP_ANON | MAP_PRIVATE, -1, 0);
```

with

```c
        PS4_HITCH_TIMED(PS4_HITCH_VM, mmap(proc->mem_base + ostart, oend - ostart, PROT_READ | PROT_WRITE,
                                           MAP_FIXED | MAP_ANON | MAP_PRIVATE, -1, 0));
```

- [ ] **Step 5: mtlbuf, shader_fs, texlock**

`ps4_gnm_draw.mm`: add `#include "ps4_hitch.h"` after `#include "ps4_metal_screen.h"`.

In `GuestBuffer`, wrap the creation:

```cpp
        const uint64_t mb_t0 = ps4_hitch_now_ns();
        b = [S.dev newBufferWithBytesNoCopy:ctx->mem_base + base
                                     length:end - base
                                    options:MTLResourceStorageModeShared
                                deallocator:nil];
        ps4_hitch_add_ns(PS4_HITCH_MTLBUF, ps4_hitch_now_ns() - mb_t0);
```

In `DropRemappedWindows()` (it has no early returns) replace

```cpp
void DropRemappedWindows() {
    std::vector<std::pair<uint64_t, uint64_t>> ranges;
```

with

```cpp
void DropRemappedWindows() {
    const uint64_t mb_t0 = ps4_hitch_now_ns();
    std::vector<std::pair<uint64_t, uint64_t>> ranges;
```

and replace its last statement

```cpp
    for (auto& m : g_guest_buf_mru) m = GuestBufMru{};
}
```

with

```cpp
    for (auto& m : g_guest_buf_mru) m = GuestBufMru{};
    ps4_hitch_add_ns(PS4_HITCH_MTLBUF, ps4_hitch_now_ns() - mb_t0);
}
```

In `StoreMslInDiskCache` add `const uint64_t fs_t0 = ps4_hitch_now_ns();` after the `msl_cache_dir.empty()` check and `ps4_hitch_add_ns(PS4_HITCH_SHADER_FS, ps4_hitch_now_ns() - fs_t0);` before each of its two remaining `return`s.

`ps4_gnm_resources.mm`: add `#include "ps4_hitch.h"` after `#include "ps4_gnm_resources.h"` and, right after the line `namespace ps4gnm {` (line ~25, before any `TextureCache::` method), add:

```cpp
namespace {
// The texture cache lock; time spent waiting for it goes to the long-frame breakdown (texlock).
struct TimedLock {
    std::mutex& m;
    explicit TimedLock(std::mutex& mu) : m(mu) {
        if (m.try_lock()) return;
        const uint64_t t0 = ps4_hitch_now_ns();
        m.lock();
        ps4_hitch_add_ns(PS4_HITCH_TEXLOCK, ps4_hitch_now_ns() - t0);
    }
    ~TimedLock() { m.unlock(); }
    TimedLock(const TimedLock&) = delete;
    TimedLock& operator=(const TimedLock&) = delete;
};
} // namespace
```

Then:

```bash
cd ~/ps4recomp-work/PS4Recomp/pkg/runtime/modules/libSceGnmDriver
sed -i '' 's/std::lock_guard<std::mutex> lk(mutex_);/TimedLock lk(mutex_);/' ps4_gnm_resources.mm
grep -c "TimedLock lk(mutex_);" ps4_gnm_resources.mm
```

Expected: `16`.

- [ ] **Step 6: Print the counters**

In `ps4_gnm_draw.mm`, in the frame-time block, replace

```cpp
                if (dt > 50.0)
                    fprintf(stderr, "[gnm-draw] hitch: frame %.1f ms; shaders %u (%.1f ms: gcn %.1f, metal %.1f), pipelines %u (%.1f ms), "
                                    "texture uploads %u (%.1f ms), gpu waits %.1f ms, draws waiting for shaders %u\n",
                            dt, g_hitch.shaders, g_hitch.shader_ms, g_hitch.gcn_ms, g_hitch.mtl_ms, g_hitch.psos, g_hitch.pso_ms, g_hitch.uploads,
                            g_hitch.upload_ms, g_hitch.wait_ms, g_hitch.pending_draws);
            }
            last_present = now_t;
```

with

```cpp
                double host_ms[PS4_HITCH_KINDS];
                for (int k = 0; k < PS4_HITCH_KINDS; ++k) host_ms[k] = ps4_hitch_take_ns(k) / 1e6;
                if (dt > 50.0)
                    fprintf(stderr, "[gnm-draw] hitch: frame %.1f ms; shaders %u (%.1f ms: gcn %.1f, metal %.1f), pipelines %u (%.1f ms), "
                                    "texture uploads %u (%.1f ms), gpu waits %.1f ms, draws waiting for shaders %u; "
                                    "io %.1f, vm %.1f, mtlbuf %.1f, texlock %.1f, shader_fs %.1f ms\n",
                            dt, g_hitch.shaders, g_hitch.shader_ms, g_hitch.gcn_ms, g_hitch.mtl_ms, g_hitch.psos, g_hitch.pso_ms, g_hitch.uploads,
                            g_hitch.upload_ms, g_hitch.wait_ms, g_hitch.pending_draws, host_ms[PS4_HITCH_IO], host_ms[PS4_HITCH_VM],
                            host_ms[PS4_HITCH_MTLBUF], host_ms[PS4_HITCH_TEXLOCK], host_ms[PS4_HITCH_SHADER_FS]);
            } else {
                for (int k = 0; k < PS4_HITCH_KINDS; ++k) ps4_hitch_take_ns(k);
            }
            last_present = now_t;
```

- [ ] **Step 7: Build and verify**

Build, then:

```bash
cp ~/ps4recomp-work/tlou_build/ps4_app ~/ps4recomp-work/tlou_build/ps4_app_t5
~/ps4recomp-work/tools/walk_bench.sh spores ps4_app_t5 t5
grep "hitch:" ~/ps4recomp-work/walk_bench/t5-spores/run.log | head -3
```

Expected: `fatal 0`; hitch lines end with `; io X, vm X, mtlbuf X, texlock X, shader_fs X ms`; at least one of these is non-zero somewhere in the run (`grep -c "io [1-9]" ...` > 0 during loading). `avg fps` within ±5 % of t4.

- [ ] **Step 8: Commit**

```bash
cd ~/ps4recomp-work/PS4Recomp
git add pkg/runtime/core/ps4_hitch.h pkg/runtime/core/recomp_runtime.c pkg/runtime/kernel/syscalls/ps4_syscalls.c \
  pkg/runtime/kernel/aio/ps4_aio.c pkg/runtime/kernel/memory/ps4_direct_mem.c \
  pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.mm
git commit -q -m "Add io/vm/mtlbuf/texlock/shader_fs counters to the hitch breakdown

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Baseline measurement

**Files:**
- Create: `~/ps4recomp-work/walk_bench/baseline.txt` (outside the repository)

- [ ] **Step 1: Run both routes twice on the Task 5 build**

```bash
cd ~/ps4recomp-work
for r in 1 2; do for route in spores courtyard; do tools/walk_bench.sh $route ps4_app_t5 base$r; done; done 2>&1 | tee walk_bench/baseline.txt
```

Expected: 4 blocks `== baseN route: load {...} fatal 0` + a report line. Discard and rerun any run whose `extload.txt` shows `other` > 150 % for more than one sample.

- [ ] **Step 2: Summarise the profiles**

```bash
cd ~/ps4recomp-work/walk_bench
for d in base1-spores base2-spores base1-courtyard base2-courtyard; do echo "== $d"; grep -A12 "^\[stall-profile\] stall [1-9][0-9][0-9]" $d/run.log | head -60; done >> baseline.txt
```

Expected: profiles of every stall ≥ 100 ms are in `baseline.txt`. This file is the input of Task 12.

---

### Task 7: Exit without a crash

**Files:**
- Modify: `pkg/runtime/core/recomp_runtime.h` (declaration), `pkg/runtime/core/recomp_runtime.c` (definition)
- Modify: `pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.m` (all `exit(0);`), `pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.h`
- Modify: `pkg/runtime/modules/libScePad/ps4_pad.m` (control file commands `close`, `terminate`)
- Create: `~/ps4recomp-work/tools/exit_test.sh`

**Interfaces:**
- Produces: `void ps4_host_quit(int code) __attribute__((noreturn));` and the weak hook `void ps4_gnm_pso_archive_save_for_quit(double timeout_s);` (defined in Task 9).
- Produces: `void ps4_metal_screen_request_close(void); void ps4_metal_screen_request_terminate(void);`

- [ ] **Step 1: Write the exit test**

`~/ps4recomp-work/tools/exit_test.sh`:

```bash
#!/bin/bash
# Starts the game from a copy of a save, quits it through a real exit path and checks that no
# crash report was written. usage: exit_test.sh <binary in tlou_build> <close|terminate>
set -euo pipefail
BIN=$1; HOW=$2
W=$HOME/ps4recomp-work
D=$(mktemp -d)
cp -R "$W/data_ch1" "$D/data"
CTL="$D/pad.ctl"; : > "$CTL"
NAME=exit_test_$$
cp "$W/tlou_build/$BIN" "$W/tlou_build/$NAME"
touch "$D/start"
cd "$W/tlou_build"
PS4RECOMP_DATA_DIR="$D/data" PS4_LANG=ru PS4_RECOMP_HEADLESS=1 PS4_BACKGROUND_WINDOW=1 PS4_PAD_AUTOPRESS=4000 \
  PS4_PAD_CTL="$CTL" ./$NAME > "$D/run.log" 2>&1 &
PID=$!
sleep 90
echo "$HOW" >> "$CTL"
for i in $(seq 1 30); do kill -0 $PID 2>/dev/null || break; sleep 1; done
if kill -0 $PID 2>/dev/null; then echo "exit_test: FAIL (still running)"; kill -9 $PID; rm -f "$NAME"; exit 1; fi
wait $PID || true
sleep 5 # ReportCrash writes asynchronously
rm -f "$NAME"
NEW=$(find ~/Library/Logs/DiagnosticReports -name "$NAME*" -newer "$D/start" | head -1)
if [ -n "$NEW" ]; then echo "exit_test: FAIL (crash report $NEW)"; exit 1; fi
echo "exit_test: PASS ($HOW)"
rm -rf "$D"
```

`PS4_RECOMP_HEADLESS` only turns system dialogs into log lines; the game window is a real (background, closable) window, so `close` goes through `windowShouldClose:` and `terminate` through `applicationShouldTerminate:` exactly like a click on the close button and Cmd+Q.

- [ ] **Step 2: Run against the current build**

Run: `bash ~/ps4recomp-work/tools/exit_test.sh ps4_app_t5 terminate`
Expected: `exit_test: FAIL (still running)` — the control file has no `terminate` command yet. (The crash itself is a race and does not reproduce on every quit, which is why the test needs the real exit path rather than waiting for a crash.)

- [ ] **Step 3: Implement ps4_host_quit**

`recomp_runtime.h`, after `void ps4_host_run_main_loop(void);`:

```c
// Ends the process from an exit path (window close, Cmd+Q) without running static
// destructors: game threads and Metal completion handlers still use global state.
void ps4_host_quit(int code) __attribute__((noreturn));
```

Append to `recomp_runtime.c`:

```c
// ---- Quit --------------------------------------------------------------------------------
// exit() would run static destructors while game threads and Metal completion handlers keep
// using the objects being destroyed (crash in RunFences on a destroyed mutex). Nothing needs to
// be written on exit except the pipeline archive; stdio buffers are flushed.
void ps4_gnm_pso_archive_save_for_quit(double timeout_s) __attribute__((weak));

void ps4_host_quit(int code) {
  if (ps4_gnm_pso_archive_save_for_quit) ps4_gnm_pso_archive_save_for_quit(2.0);
  fflush(NULL);
  _exit(code);
}
```

Add `#include <unistd.h>` to `recomp_runtime.c` if it is not included yet (`grep -n "unistd.h" pkg/runtime/core/recomp_runtime.c`).

- [ ] **Step 4: Use it on every exit path and add the test hooks**

```bash
cd ~/ps4recomp-work/PS4Recomp/pkg/runtime/modules/libSceVideoOut
sed -i '' 's/exit(0);/ps4_host_quit(0);/' ps4_metal_screen.m
grep -c "ps4_host_quit(0);" ps4_metal_screen.m; grep -c "[^_]exit(0);" ps4_metal_screen.m
```

Expected: `6` and `0`.

Append to `ps4_metal_screen.m`:

```objc
// Debug hooks for exit tests (PS4_PAD_CTL "close" / "terminate"): the same paths as a click on
// the window's close button and Cmd+Q / the app menu's Quit.
void ps4_metal_screen_request_close(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_window) [g_window performClose:nil];
    });
}

void ps4_metal_screen_request_terminate(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp terminate:nil];
    });
}
```

Declare both in `ps4_metal_screen.h` (inside its C linkage block, next to the other `ps4_metal_screen_*` functions).

In `ps4_pad.m`, in the control-file parser, before `} else if (line[0] == 'w') {` add:

```c
    } else if (strncmp(line, "close", 5) == 0) {
      extern void ps4_metal_screen_request_close(void);
      ps4_metal_screen_request_close();
      continue;
    } else if (strncmp(line, "terminate", 9) == 0) {
      extern void ps4_metal_screen_request_terminate(void);
      ps4_metal_screen_request_terminate();
      continue;
```

Also add both commands to the comment block that documents `PS4_PAD_CTL` above the parser:

```c
//   close / terminate                            quit through the window close button / Cmd+Q
```

- [ ] **Step 5: Build and run the test both ways**

Build, then:

```bash
cp ~/ps4recomp-work/tlou_build/ps4_app ~/ps4recomp-work/tlou_build/ps4_app_t7
bash ~/ps4recomp-work/tools/exit_test.sh ps4_app_t7 terminate
bash ~/ps4recomp-work/tools/exit_test.sh ps4_app_t7 close
```

Expected: `exit_test: PASS (terminate)` and `exit_test: PASS (close)`. Repeat each 3 times (the old crash was a race); all must pass.

- [ ] **Step 6: Commit**

```bash
cd ~/ps4recomp-work/PS4Recomp
git add pkg/runtime/core/recomp_runtime.h pkg/runtime/core/recomp_runtime.c pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.m \
  pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.h pkg/runtime/modules/libScePad/ps4_pad.m
git commit -q -m "Quit through _exit so teardown cannot race game threads

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Pipeline archive module (host-tested)

**Files:**
- Create: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_pipeline_archive.h`
- Create: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_pipeline_archive.mm`
- Test: `tests/host/pso_archive_test.mm`; Modify: `tests/host/run_host_tests.sh`

**Interfaces:**
- Produces (used by Task 9):

```cpp
namespace ps4gnm_pso_archive {
bool Open(id<MTLDevice> dev, const std::string& dir, uint64_t budget_bytes);
bool Enabled();
void Attach(MTLRenderPipelineDescriptor* d);
void Attach(MTLComputePipelineDescriptor* d);
bool Contains(uint64_t stable_key);
void Add(uint64_t stable_key, MTLRenderPipelineDescriptor* d);
void Add(uint64_t stable_key, MTLComputePipelineDescriptor* d);
bool SaveNow(double timeout_s);
void StartPeriodicSave(double period_s);
}
extern "C" void ps4_gnm_pso_archive_save_for_quit(double timeout_s);
```

- [ ] **Step 1: Write the failing test**

`tests/host/pso_archive_test.mm`:

```objc
// Host test of the pipeline archive (ps4_gnm_pipeline_archive.mm) on the real Metal device.
// Runs as separate processes: write → read must find both pipelines in the archive without
// compiling (MTLPipelineOptionFailOnBinaryArchiveMiss); budget and corrupt start anew.
#import <Metal/Metal.h>
#include "ps4_gnm_pipeline_archive.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <sys/stat.h>

static const char* kSrc =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 vmain(uint vid [[vertex_id]]) { return float4(float(vid & 1), float(vid >> 1), 0, 1); }\n"
    "fragment float4 fmain() { return float4(1, 0.5, 0.25, 1); }\n"
    "kernel void cmain(device float* o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = float(i) * 2.0; }\n";

static int Fail(const char* what) {
    printf("pso_archive_test: FAIL (%s)\n", what);
    return 1;
}

int main(int argc, char** argv) {
    if (argc != 3) return Fail("usage: pso_archive_test <write|read|budget|corrupt> <dir>");
    const std::string mode = argv[1], dir = argv[2];
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError* e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(kSrc) options:nil error:&e];
        if (!lib) return Fail("library");
        MTLRenderPipelineDescriptor* rd = [MTLRenderPipelineDescriptor new];
        rd.vertexFunction = [lib newFunctionWithName:@"vmain"];
        rd.fragmentFunction = [lib newFunctionWithName:@"fmain"];
        rd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        MTLComputePipelineDescriptor* cd = [MTLComputePipelineDescriptor new];
        cd.computeFunction = [lib newFunctionWithName:@"cmain"];
        const std::string archive = dir + "/pipelines.metalar";

        if (mode == "corrupt") {
            FILE* f = fopen(archive.c_str(), "wb");
            fputs("not an archive", f);
            fclose(f);
        }
        const uint64_t budget = mode == "budget" ? 1 : (64ull << 20);
        if (!ps4gnm_pso_archive::Open(dev, dir, budget)) return Fail("open");
        if (mode == "write") {
            if (ps4gnm_pso_archive::Contains(1) || ps4gnm_pso_archive::Contains(2)) return Fail("fresh archive has keys");
            ps4gnm_pso_archive::Attach(rd);
            ps4gnm_pso_archive::Attach(cd);
            if (![dev newRenderPipelineStateWithDescriptor:rd error:&e]) return Fail("render build");
            if (![dev newComputePipelineStateWithDescriptor:cd options:MTLPipelineOptionNone reflection:nil error:&e])
                return Fail("compute build");
            ps4gnm_pso_archive::Add(1, rd);
            ps4gnm_pso_archive::Add(2, cd);
            if (!ps4gnm_pso_archive::SaveNow(30)) return Fail("save");
            struct stat st;
            if (stat(archive.c_str(), &st) != 0 || st.st_size == 0) return Fail("archive file");
        } else if (mode == "read") {
            if (!ps4gnm_pso_archive::Contains(1) || !ps4gnm_pso_archive::Contains(2)) return Fail("index lost keys");
            ps4gnm_pso_archive::Attach(rd);
            ps4gnm_pso_archive::Attach(cd);
            if (![dev newRenderPipelineStateWithDescriptor:rd options:MTLPipelineOptionFailOnBinaryArchiveMiss
                                                reflection:nil error:&e])
                return Fail("render pipeline not served from the archive");
            if (![dev newComputePipelineStateWithDescriptor:cd options:MTLPipelineOptionFailOnBinaryArchiveMiss
                                                 reflection:nil error:&e])
                return Fail("compute pipeline not served from the archive");
        } else if (mode == "budget" || mode == "corrupt") {
            if (ps4gnm_pso_archive::Contains(1)) return Fail("old index survived");
            ps4gnm_pso_archive::Attach(rd);
            if (![dev newRenderPipelineStateWithDescriptor:rd error:&e]) return Fail("build after restart");
        } else {
            return Fail("unknown mode");
        }
    }
    printf("pso_archive_test: PASS (%s)\n", mode.c_str());
    return 0;
}
```

Append to `tests/host/run_host_tests.sh` (before `rm -rf "$T"`):

```bash
G="$R/pkg/runtime/modules/libSceGnmDriver"
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" "$R/tests/host/pso_archive_test.mm" "$G/ps4_gnm_pipeline_archive.mm" \
  -framework Metal -framework Foundation -o "$T/pso_archive_test"
A="$T/archive"; mkdir -p "$A"
"$T/pso_archive_test" write "$A"
"$T/pso_archive_test" read "$A"
"$T/pso_archive_test" budget "$A"
"$T/pso_archive_test" write "$A"
"$T/pso_archive_test" corrupt "$A"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash ~/ps4recomp-work/PS4Recomp/tests/host/run_host_tests.sh`
Expected: `stall_profile_test: PASS`, then FAIL — `ps4_gnm_pipeline_archive.h: file not found`.

- [ ] **Step 3: Write the header**

`pkg/runtime/modules/libSceGnmDriver/ps4_gnm_pipeline_archive.h`:

```cpp
// Persistent Metal binary archive of the game's pipelines (their GPU code), so a pipeline built
// in an earlier session loads in about a millisecond even when the system Metal cache no
// longer has it (that cache is tied to the executable; every rebuild of the game drops it).
#pragma once
#import <Metal/Metal.h>
#include <cstdint>
#include <string>

namespace ps4gnm_pso_archive {
// Opens or creates <dir>/pipelines.metalar and its key index <dir>/pipelines_archived.bin. A
// file larger than budget_bytes, unreadable, or incompatible with this OS/GPU is deleted and a
// new archive started. Returns false (archive disabled) only when Metal cannot create one, or
// with PS4_GNM_NO_PSO_ARCHIVE=1.
bool Open(id<MTLDevice> dev, const std::string& dir, uint64_t budget_bytes);
bool Enabled();
// Makes pipeline creation look in the archive first (descriptor.binaryArchives).
void Attach(MTLRenderPipelineDescriptor* d);
void Attach(MTLComputePipelineDescriptor* d);
// True if the pipeline with this stable key is in the archive or queued for it.
bool Contains(uint64_t stable_key);
// Adds the pipeline's GPU code to the archive on its queue (the descriptor is copied).
void Add(uint64_t stable_key, MTLRenderPipelineDescriptor* d);
void Add(uint64_t stable_key, MTLComputePipelineDescriptor* d);
// Writes the archive (temporary file + rename) after the queued additions; waits at most
// timeout_s. Returns false on error or timeout.
bool SaveNow(double timeout_s);
// Saves every period_s seconds while there are unsaved additions.
void StartPeriodicSave(double period_s);
} // namespace ps4gnm_pso_archive

// Called by ps4_host_quit (core/recomp_runtime.c, weak reference).
extern "C" void ps4_gnm_pso_archive_save_for_quit(double timeout_s);
```

- [ ] **Step 4: Write the implementation**

`pkg/runtime/modules/libSceGnmDriver/ps4_gnm_pipeline_archive.mm`:

```objc
#include "ps4_gnm_pipeline_archive.h"
#import <Foundation/Foundation.h>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_set>
#include <vector>

namespace ps4gnm_pso_archive {
namespace {
struct ArchiveState {
    id<MTLBinaryArchive> archive = nil;
    NSArray<id<MTLBinaryArchive>>* list = nil;
    std::string path, index_path;
    dispatch_queue_t q = nil;          // additions and saves, in order
    dispatch_source_t timer = nil;     // periodic save
    std::mutex mu;                     // keys, unsaved
    std::unordered_set<uint64_t> keys; // in the archive or queued for it
    std::vector<uint64_t> unsaved;     // added since the last save (appended to the index then)
    bool dirty = false;                // q only
};
ArchiveState A;

id<MTLBinaryArchive> NewArchive(id<MTLDevice> dev, NSURL* url, NSError** err) {
    MTLBinaryArchiveDescriptor* ad = [MTLBinaryArchiveDescriptor new];
    ad.url = url; // nil: a new, empty archive
    return [dev newBinaryArchiveWithDescriptor:ad error:err];
}

void DropFiles() {
    unlink(A.path.c_str());
    unlink(A.index_path.c_str());
}

void LoadIndex() {
    FILE* f = fopen(A.index_path.c_str(), "rb");
    if (!f) return;
    uint64_t k;
    while (fread(&k, sizeof(k), 1, f) == 1) A.keys.insert(k);
    fclose(f);
}

// Runs on A.q.
bool SaveOnQueue() {
    if (!A.dirty) return true;
    NSString* tmp = [NSString stringWithFormat:@"%s.tmp%d", A.path.c_str(), (int)getpid()];
    NSError* e = nil;
    if (![A.archive serializeToURL:[NSURL fileURLWithPath:tmp] error:&e]) {
        fprintf(stderr, "[gnm-pso-archive] save failed: %s\n", e.localizedDescription.UTF8String);
        unlink(tmp.UTF8String);
        return false;
    }
    if (rename(tmp.UTF8String, A.path.c_str()) != 0) {
        unlink(tmp.UTF8String);
        return false;
    }
    std::vector<uint64_t> saved;
    {
        std::lock_guard<std::mutex> lk(A.mu);
        saved.swap(A.unsaved);
    }
    if (FILE* f = fopen(A.index_path.c_str(), "ab")) {
        fwrite(saved.data(), sizeof(uint64_t), saved.size(), f);
        fclose(f);
    }
    A.dirty = false;
    return true;
}

template <class Desc, class AddFn>
void AddImpl(uint64_t key, Desc* d, AddFn add) {
    if (!A.archive || !d) return;
    {
        std::lock_guard<std::mutex> lk(A.mu);
        if (!A.keys.insert(key).second) return;
    }
    Desc* copy = [d copy];
    dispatch_async(A.q, ^{
        NSError* e = nil;
        if (add(copy, &e)) {
            std::lock_guard<std::mutex> lk(A.mu);
            A.unsaved.push_back(key);
            A.dirty = true;
        } else {
            fprintf(stderr, "[gnm-pso-archive] add failed: %s\n", e.localizedDescription.UTF8String);
            std::lock_guard<std::mutex> lk(A.mu);
            A.keys.erase(key);
        }
    });
}
} // namespace

bool Open(id<MTLDevice> dev, const std::string& dir, uint64_t budget_bytes) {
    if (getenv("PS4_GNM_NO_PSO_ARCHIVE")) return false;
    A.path = dir + "/pipelines.metalar";
    A.index_path = dir + "/pipelines_archived.bin";
    A.q = dispatch_queue_create("ps4.gnm.pso_archive", DISPATCH_QUEUE_SERIAL);
    struct stat st;
    if (stat(A.path.c_str(), &st) == 0 && (uint64_t)st.st_size > budget_bytes) {
        fprintf(stderr, "[gnm-pso-archive] %s is %lld MB (budget %llu MB): starting a new archive\n", A.path.c_str(),
                (long long)(st.st_size >> 20), (unsigned long long)(budget_bytes >> 20));
        DropFiles();
    }
    NSError* e = nil;
    if (stat(A.path.c_str(), &st) == 0) {
        A.archive = NewArchive(dev, [NSURL fileURLWithPath:@(A.path.c_str())], &e);
        if (A.archive) {
            LoadIndex();
        } else {
            fprintf(stderr, "[gnm-pso-archive] cannot open %s (%s): starting a new archive\n", A.path.c_str(),
                    e.localizedDescription.UTF8String);
            DropFiles();
        }
    } else {
        unlink(A.index_path.c_str()); // an index without its archive describes nothing
    }
    if (!A.archive) A.archive = NewArchive(dev, nil, &e);
    if (!A.archive) {
        fprintf(stderr, "[gnm-pso-archive] disabled: %s\n", e.localizedDescription.UTF8String);
        return false;
    }
    A.list = @[ A.archive ];
    fprintf(stderr, "[gnm-pso-archive] %s: %zu pipelines\n", A.path.c_str(), A.keys.size());
    return true;
}

bool Enabled() {
    return A.archive != nil;
}

void Attach(MTLRenderPipelineDescriptor* d) {
    if (A.list) d.binaryArchives = A.list;
}

void Attach(MTLComputePipelineDescriptor* d) {
    if (A.list) d.binaryArchives = A.list;
}

bool Contains(uint64_t key) {
    std::lock_guard<std::mutex> lk(A.mu);
    return A.keys.count(key) != 0;
}

void Add(uint64_t key, MTLRenderPipelineDescriptor* d) {
    AddImpl(key, d, ^bool(MTLRenderPipelineDescriptor* c, NSError** e) {
        return [A.archive addRenderPipelineFunctionsWithDescriptor:c error:e];
    });
}

void Add(uint64_t key, MTLComputePipelineDescriptor* d) {
    AddImpl(key, d, ^bool(MTLComputePipelineDescriptor* c, NSError** e) {
        return [A.archive addComputePipelineFunctionsWithDescriptor:c error:e];
    });
}

bool SaveNow(double timeout_s) {
    if (!A.archive) return true;
    __block bool ok = false;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(A.q, ^{
        ok = SaveOnQueue();
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout_s * NSEC_PER_SEC))) != 0)
        return false;
    return ok;
}

void StartPeriodicSave(double period_s) {
    if (!A.archive || A.timer) return;
    A.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, A.q);
    const uint64_t ns = (uint64_t)(period_s * NSEC_PER_SEC);
    dispatch_source_set_timer(A.timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)ns), ns, NSEC_PER_SEC);
    dispatch_source_set_event_handler(A.timer, ^{
        SaveOnQueue();
    });
    dispatch_resume(A.timer);
}
} // namespace ps4gnm_pso_archive

extern "C" void ps4_gnm_pso_archive_save_for_quit(double timeout_s) {
    ps4gnm_pso_archive::SaveNow(timeout_s);
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash ~/ps4recomp-work/PS4Recomp/tests/host/run_host_tests.sh`
Expected, in order: `stall_profile_test: PASS`, `pso_archive_test: PASS (write)`, `PASS (read)`, `PASS (budget)`, `PASS (write)`, `PASS (corrupt)`.

- [ ] **Step 6: Commit**

```bash
cd ~/ps4recomp-work/PS4Recomp
git add pkg/runtime/modules/libSceGnmDriver/ps4_gnm_pipeline_archive.h pkg/runtime/modules/libSceGnmDriver/ps4_gnm_pipeline_archive.mm tests/host
git commit -q -m "Add a persistent Metal binary archive for pipelines with a host test

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Use the archive for game pipelines

**Files:**
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm` (`Init` after `StartShaderWarmup();`, `GetGfxPipeline`, compute pipeline creation in `DispatchEncode`)
- Modify: `tlou_build/build.ninja` (`REL='modules/libSceGnmDriver/ps4_gnm_pipeline_archive.mm'`, `RULE='compile_mm'`, `AFTER='modules/libSceGnmDriver/ps4_gnm_shader_cache'`)

**Interfaces:**
- Consumes: Task 8 API; `ps4_host_quit` calls `ps4_gnm_pso_archive_save_for_quit` (Task 7).

- [ ] **Step 1: Open the archive at start-up**

`ps4_gnm_draw.mm`: add `#include "ps4_gnm_pipeline_archive.h"` after `#include "ps4_gnm_shader_cache.h"`. In `Init`, replace `        StartShaderWarmup();` with

```cpp
        StartShaderWarmup();
        if (!S.msl_cache_dir.empty()) {
            const char* mb = getenv("PS4_GNM_PSO_ARCHIVE_MB");
            const uint64_t budget = (uint64_t)(mb ? atoll(mb) : 384) << 20;
            if (ps4gnm_pso_archive::Open(S.dev, S.msl_cache_dir, budget)) ps4gnm_pso_archive::StartPeriodicSave(300);
        }
```

- [ ] **Step 2: Render pipelines**

In `GetGfxPipeline`, replace

```cpp
    if (S.async_compile && !known) {
        // Build a new pipeline in the background; the draw is skipped until it is ready.
        if (S.psos_pending.insert(key).second) {
            const std::string k = key;
            [S.dev newRenderPipelineStateWithDescriptor:d
                                      completionHandler:^(id<MTLRenderPipelineState> ps_, NSError* err) {
                                          if (ps_) RememberPipeline(stable);
```

with

```cpp
    ps4gnm_pso_archive::Attach(d);
    if (S.async_compile && !known) {
        // Build a new pipeline in the background; the draw is skipped until it is ready.
        if (S.psos_pending.insert(key).second) {
            const std::string k = key;
            [S.dev newRenderPipelineStateWithDescriptor:d
                                      completionHandler:^(id<MTLRenderPipelineState> ps_, NSError* err) {
                                          if (ps_) {
                                              RememberPipeline(stable);
                                              ps4gnm_pso_archive::Add(stable, d);
                                          }
```

and replace

```cpp
    if (p && !known) RememberPipeline(stable);
```

with

```cpp
    if (p && !known) RememberPipeline(stable);
    // known pipelines missing from the archive are added once (the next session loads them fast)
    if (p && !ps4gnm_pso_archive::Contains(stable)) ps4gnm_pso_archive::Add(stable, d);
```

- [ ] **Step 3: Compute pipelines**

In `DispatchEncode`, replace

```cpp
            MTLComputePipelineDescriptor* cpd = [MTLComputePipelineDescriptor new];
            cpd.computeFunction = cs->fn;
            if (wg > 0 && wg <= 1024) cpd.maxTotalThreadsPerThreadgroup = (NSUInteger)wg;
            const double cpso_t0 = CFAbsoluteTimeGetCurrent();
            pso = [S.dev newComputePipelineStateWithDescriptor:cpd options:MTLPipelineOptionNone reflection:nil error:&e];
```

with

```cpp
            MTLComputePipelineDescriptor* cpd = [MTLComputePipelineDescriptor new];
            cpd.computeFunction = cs->fn;
            if (wg > 0 && wg <= 1024) cpd.maxTotalThreadsPerThreadgroup = (NSUInteger)wg;
            const uint64_t ck[2] = {cs->msl_hash, wg};
            const uint64_t cstable = Fnv(ck, sizeof(ck), 0x5ca1ab1e5ca1ab1eull);
            ps4gnm_pso_archive::Attach(cpd);
            const double cpso_t0 = CFAbsoluteTimeGetCurrent();
            pso = [S.dev newComputePipelineStateWithDescriptor:cpd options:MTLPipelineOptionNone reflection:nil error:&e];
            if (pso && !ps4gnm_pso_archive::Contains(cstable)) ps4gnm_pso_archive::Add(cstable, cpd);
```

- [ ] **Step 4: Add the object to build.ninja and build**

Run the Conventions snippet with `REL, RULE, AFTER = 'modules/libSceGnmDriver/ps4_gnm_pipeline_archive.mm', 'compile_mm', 'modules/libSceGnmDriver/ps4_gnm_shader_cache'`, then build.
Expected: `... in build.ninja: True`, no errors.

- [ ] **Step 5: Verify that a fresh executable gets archived pipelines**

The system Metal cache is tied to the executable, so each run below uses a new copy name (a cold system cache), and the archive in the user cache directory is the only thing that can make known pipelines fast.

```bash
cd ~/ps4recomp-work/tlou_build
cp ps4_app ps4_app_t9a; cp ps4_app ps4_app_t9b; cp ps4_app ps4_app_t9c
cd ~/ps4recomp-work
tools/walk_bench.sh spores ps4_app_t9a t9fill                                  # fills the archive
EXTRA="PS4_GNM_NO_PSO_ARCHIVE=1" tools/walk_bench.sh spores ps4_app_t9b t9off  # cold, no archive
tools/walk_bench.sh spores ps4_app_t9c t9on                                    # cold, archive
for l in t9off t9on; do echo "== $l"; grep -o "pipelines [0-9]* ([0-9.]* ms)" walk_bench/$l-spores/run.log | awk '{n+=$2; gsub(/[()]/,"",$3); ms+=$3} END {printf "pipelines %d, %.1f ms, %.2f ms each\n", n, ms, n?ms/n:0}'; head -1 walk_bench/$l-spores/report.txt; done
grep "gnm-pso-archive" walk_bench/t9on-spores/run.log | head -3
ls "$(getconf DARWIN_USER_CACHE_DIR)com.apple.metal" | grep ps4_app_t9
```

Expected: the archive line shows a non-zero pipeline count; the last command lists separate Metal cache directories for `ps4_app_t9a`, `ps4_app_t9b` and `ps4_app_t9c` (each copy really started with a cold system cache; if they share one directory, the experiment does not isolate the archive — then repeat t9off/t9on after `rm -rf` of that shared directory before each of the two runs); `t9on` spends at least 5× less per pipeline than `t9off`, and `t9on` has fewer `>33ms` frames than `t9off`. `fatal 0` in all three.

- [ ] **Step 6: Exit saves the archive**

```bash
ls -la ~/Library/Caches/PS4Recomp/CUSA00557/msl/pipelines.metalar
cp ~/ps4recomp-work/tlou_build/ps4_app ~/ps4recomp-work/tlou_build/ps4_app_t9
bash ~/ps4recomp-work/tools/exit_test.sh ps4_app_t9 terminate
ls -la ~/Library/Caches/PS4Recomp/CUSA00557/msl/pipelines.metalar
```

Expected: `exit_test: PASS (terminate)`; the archive's modification time changed if the run added pipelines (otherwise unchanged and no error). The archive size stays below 384 MB.

- [ ] **Step 7: Commit**

```bash
cd ~/ps4recomp-work/PS4Recomp
git add pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm
git commit -q -m "Build game pipelines through the binary archive

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Cached shaders without file operations in the frame

**Files:**
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm` (`State`, `StartShaderWarmup`, `StoreMslInDiskCache`, `HitchStats`, `GetShader` cache lookup, `FinishShader` `newFunctionWithName`, hitch line)

**Interfaces:**
- Consumes: `PS4_HITCH_SHADER_FS` (Task 5).
- Produces: hitch line field `shaders N (X ms: gcn X, metal X, lookup X, fn X)`.

- [ ] **Step 1: Sub-timers first (to see where the 4.5 ms go)**

In `HitchStats` add two fields:

```cpp
struct HitchStats {
    double shader_ms = 0, gcn_ms = 0, mtl_ms = 0, pso_ms = 0, upload_ms = 0, wait_ms = 0;
    double lookup_ms = 0, fn_ms = 0; // translation cache lookup; MTLFunction creation
    uint32_t shaders = 0, psos = 0, uploads = 0, pending_draws = 0;
};
```

In `GetShader`, replace

```cpp
        if (gcn_shader* sh = sc::Lookup(ckey, code_addr, ud, ReadGuest, S.ctx)) {
```

with

```cpp
        gcn_shader* sh = sc::Lookup(ckey, code_addr, ud, ReadGuest, S.ctx);
        g_hitch.lookup_ms += (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        if (sh) {
```

In `FinishShader`, replace

```cpp
    if (lib) s->fn = [lib newFunctionWithName:@"main0"];
```

with

```cpp
    if (lib) {
        const double fn_t0 = CFAbsoluteTimeGetCurrent();
        s->fn = [lib newFunctionWithName:@"main0"];
        g_hitch.fn_ms += (CFAbsoluteTimeGetCurrent() - fn_t0) * 1000.0;
    }
```

In the hitch `fprintf`, change `shaders %u (%.1f ms: gcn %.1f, metal %.1f)` to `shaders %u (%.1f ms: gcn %.1f, metal %.1f, lookup %.1f, fn %.1f)` and add `g_hitch.lookup_ms, g_hitch.fn_ms` after `g_hitch.mtl_ms` in the argument list.

- [ ] **Step 2: Measure before the change**

Build, `cp ps4_app ps4_app_t10a`, run `tools/walk_bench.sh spores ps4_app_t10a t10a`, then:

```bash
grep -o "shaders [0-9]* ([^)]*)" ~/ps4recomp-work/walk_bench/t10a-spores/run.log | head -20
grep -o "shader_fs [0-9.]*" ~/ps4recomp-work/walk_bench/t10a-spores/run.log | sort -k2 -n | tail -3
```

Expected: the numbers show how a frame's shader time splits into lookup, fn, shader_fs and the rest. Record them in the commit message of Step 5.

- [ ] **Step 3: Known MSL from memory, new MSL written in the background**

In `struct State`, after `std::string pso_list_path;`, add:

```cpp
    std::unordered_set<uint64_t> msl_on_disk; // hashes of <msl_cache_dir>/<hash>.metal (CP thread)
```

In `StartShaderWarmup`, replace

```cpp
    for (NSString* f in files)
        if ([f hasSuffix:@".metal"]) paths.push_back(S.msl_cache_dir + "/" + f.UTF8String);
```

with

```cpp
    for (NSString* f in files)
        if ([f hasSuffix:@".metal"]) {
            paths.push_back(S.msl_cache_dir + "/" + f.UTF8String);
            S.msl_on_disk.insert(strtoull(f.UTF8String, nullptr, 16));
        }
```

Replace the whole `StoreMslInDiskCache` function with:

```cpp
bool StoreMslInDiskCache(uint64_t mh, const char* msl) {
    if (S.msl_cache_dir.empty()) return true;
    const uint64_t fs_t0 = ps4_hitch_now_ns();
    char path[1200];
    snprintf(path, sizeof(path), "%s/%016llx.metal", S.msl_cache_dir.c_str(), (unsigned long long)mh);
    const bool is_new = S.msl_on_disk.insert(mh).second;
    if (!is_new) {
        ps4gnm_shader_cache::MarkUsed(path); // asynchronous
    } else {
        // the frame does not wait for the disk
        static dispatch_queue_t writer = dispatch_queue_create("ps4.gnm.msl_cache.writer", DISPATCH_QUEUE_SERIAL);
        auto* job = new std::pair<std::string, std::string>(path, msl);
        dispatch_async(writer, ^{
            char tmp[1300];
            snprintf(tmp, sizeof(tmp), "%s.tmp%d", job->first.c_str(), (int)getpid());
            if (FILE* f = fopen(tmp, "w")) {
                fputs(job->second.c_str(), f);
                fclose(f);
                rename(tmp, job->first.c_str());
            }
            delete job;
        });
    }
    ps4_hitch_add_ns(PS4_HITCH_SHADER_FS, ps4_hitch_now_ns() - fs_t0);
    return is_new;
}
```

(The function keeps its contract: true when the MSL was new. It runs only on the CP thread, like before.)

- [ ] **Step 4: Build and measure**

Build, `cp ps4_app ps4_app_t10b`, run `tools/walk_bench.sh spores ps4_app_t10b t10b`, then rerun the two `grep` commands of Step 2 on `t10b-spores`.

Expected: `shader_fs` ≤ 0.1 ms in every hitch line; the shader time per shader drops by the former shader_fs share; `fatal 0`. If `lookup` + `fn` still exceed 0.5 ms per shader, write the numbers into `walk_bench/baseline.txt` under "Task 10 remainder" for Task 12 (no further change in this task).

- [ ] **Step 5: Commit**

```bash
cd ~/ps4recomp-work/PS4Recomp
git add pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm
git commit -q -m "Keep shader cache file operations out of the frame

Before: <paste Step 2 numbers>. After: <paste Step 4 numbers>.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Large texture uploads on the GPU

Design note: the copies go into a separate upload command buffer that is committed right before the current one. The draw that binds the texture is in the current command buffer, so it runs after the copy (same queue, committed later; Metal's hazard tracking orders the texture write before the read). The open render pass is not split and the texture cache is looked up once per bind, in `BindStage`. Textures whose guest memory is written by pending GPU work keep the existing hazard path (`ResolveTextureHazards` → copy inside the current command buffer behind the writes).

**Files:**
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.h` (TextureCache public API, private `GetTextureImpl` signature)
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.mm` (`GetTextureImpl`, new methods)
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm` (`State`, forward declarations, `GpuUploadTexture` split, new `SampledTexture` and `VerifyGpuUpload`, `BindStage`, `Commit`, `HitchStats`, hitch line)
- Modify: `docs/superpowers/specs/2026-10-18-movement-hitches-design.md` (component 6 wording: upload command buffer)

**Interfaces:**
- Produces:

```cpp
// TextureCache
id<MTLTexture> GetTextureForGpuRefresh(const ImageDesc& img, uint64_t upload_epoch, uint64_t min_bytes, GpuUpload* up);
void MarkStale(id<MTLTexture> tex);
bool DebugCpuUploadInto(const ImageDesc& img, id<MTLTexture> dst);
// ps4_gnm_draw.mm
bool EncodeGpuUpload(const ImageDesc& img, const TextureCache::GpuUpload& up, id<MTLCommandBuffer> side);
id<MTLTexture> SampledTexture(const ImageDesc& img);
```

- [ ] **Step 1: TextureCache API**

`ps4_gnm_resources.h`, after the `GetTextureForGpuUpload` declaration, add:

```cpp
    // Like GetTexture, but a texture that needs an upload from guest memory (new or stale)
    // whose surface is at least min_bytes is not uploaded by the CPU: `up` is filled, the
    // texture is marked current at upload_epoch and the caller encodes the copy on the GPU.
    // Smaller textures are uploaded by the CPU as in GetTexture. up->tex is nil when nothing
    // is left to do.
    id<MTLTexture> GetTextureForGpuRefresh(const ImageDesc& img, uint64_t upload_epoch, uint64_t min_bytes,
                                           GpuUpload* up);
    // A texture handed out for a GPU upload whose copy could not be encoded: stale again, so
    // the next GetTexture uploads it on the CPU.
    void MarkStale(id<MTLTexture> tex);
    // Debug (PS4_GNM_VERIFY_GPU_UPLOAD): CPU upload of the T#'s guest memory into `dst`, which
    // must have the cached texture's descriptor. The cache entries are not changed.
    bool DebugCpuUploadInto(const ImageDesc& img, id<MTLTexture> dst);
```

Change the private declaration of `GetTextureImpl` (`grep -n "GetTextureImpl" ps4_gnm_resources.h`) to

```cpp
    id<MTLTexture> GetTextureImpl(const ImageDesc& img, const uint64_t* gpu_epochs, GpuUpload* up,
                                  uint64_t refresh_min_bytes = 0);
```

- [ ] **Step 2: Refresh mode in GetTextureImpl**

`ps4_gnm_resources.mm`: replace the comment and definition line

```cpp
// gpu_epochs: {write_epoch, upload_epoch} for GetTextureForGpuUpload, nullptr for GetTexture.
id<MTLTexture> TextureCache::GetTextureImpl(const ImageDesc& img, const uint64_t* gpu_epochs, GpuUpload* up) {
```

with

```cpp
// gpu_epochs: {write_epoch, upload_epoch} for GetTextureForGpuUpload / GetTextureForGpuRefresh,
// nullptr for GetTexture. refresh_min_bytes > 0: refresh mode (GetTextureForGpuRefresh).
id<MTLTexture> TextureCache::GetTextureImpl(const ImageDesc& img, const uint64_t* gpu_epochs, GpuUpload* up,
                                            uint64_t refresh_min_bytes) {
```

In step 2) of the function, replace

```cpp
            if (gpu_epochs) {
                // stale unless already copied on the GPU after the pending writes
                if ((e->dirty || e->gpu_upload_epoch <= gpu_epochs[0]) && e->samples <= 1) gpu_upload(e);
            } else if (e->dirty) {
                UploadLocked(e);
            }
```

with

```cpp
            if (refresh_min_bytes) {
                // stale contents: big surfaces are copied on the GPU, small ones by the CPU
                if (e->dirty && e->samples <= 1) {
                    if (e->layout.total_size >= refresh_min_bytes) gpu_upload(e);
                    else UploadLocked(e);
                }
            } else if (gpu_epochs) {
                // stale unless already copied on the GPU after the pending writes
                if ((e->dirty || e->gpu_upload_epoch <= gpu_epochs[0]) && e->samples <= 1) gpu_upload(e);
            } else if (e->dirty) {
                UploadLocked(e);
            }
```

In step 3) (create), replace

```cpp
    if (!msaa) {
        if (gpu_epochs) gpu_upload(e);
        else UploadLocked(e);
    }
```

with

```cpp
    if (!msaa) {
        if (gpu_epochs && (!refresh_min_bytes || e->layout.total_size >= refresh_min_bytes)) gpu_upload(e);
        else UploadLocked(e);
    }
```

Add after `GetTextureForGpuUpload`:

```cpp
id<MTLTexture> TextureCache::GetTextureForGpuRefresh(const ImageDesc& img, uint64_t upload_epoch, uint64_t min_bytes,
                                                     GpuUpload* up) {
    const uint64_t epochs[2] = {0, upload_epoch};
    *up = GpuUpload{};
    return GetTextureImpl(img, epochs, up, std::max<uint64_t>(1, min_bytes));
}

void TextureCache::MarkStale(id<MTLTexture> tex) {
    TimedLock lk(mutex_);
    for (auto& kv : entries_)
        if (kv.second->tex == tex) {
            kv.second->dirty = true;
            kv.second->gpu_upload_epoch = 0;
            return;
        }
}

bool TextureCache::DebugCpuUploadInto(const ImageDesc& img, id<MTLTexture> dst) {
    TimedLock lk(mutex_);
    auto range = entries_.equal_range(img.address);
    for (auto it = range.first; it != range.second; ++it) {
        Entry* e = it->second;
        if (e->kind != Entry::Sampled || !e->tex || e->tex.pixelFormat != dst.pixelFormat ||
            e->tex.width != dst.width || e->tex.height != dst.height || e->tex.mipmapLevelCount != dst.mipmapLevelCount)
            continue;
        Entry tmp = *e; // same surface and layout, other texture
        tmp.tex = dst;
        const bool ok = UploadLockedImpl(&tmp);
        tmp.tex = nil;
        return ok;
    }
    return false;
}
```

(`TextureCache::Entry` is a plain struct defined in `ps4_gnm_resources.mm`; copying it is fine. Only `tmp.tex` differs, and `tmp` is never inserted into `entries_`.)

- [ ] **Step 3: Upload command buffer in State and Commit**

`ps4_gnm_draw.mm`, in `struct State` replace

```cpp
    id<MTLCommandBuffer> cmd = nil;
```

with

```cpp
    id<MTLCommandBuffer> cmd = nil;
    id<MTLCommandBuffer> upload_cmd = nil; // GPU texture uploads for the work in cmd (committed first)
```

In `Commit()`, replace

```cpp
void Commit() {
    EndEncoders();
    if (!S.cmd) return;
```

with

```cpp
void Commit() {
    EndEncoders();
    if (S.upload_cmd) {
        // texture copies used by the work of S.cmd: same queue, committed first
        [S.upload_cmd commit];
        S.upload_cmd = nil;
    }
    if (!S.cmd) return;
```

- [ ] **Step 4: Split GpuUploadTexture into EncodeGpuUpload + hazard wrapper**

Replace the whole `GpuUploadTexture` function with:

```cpp
// Encodes the copy of a texture's guest memory into up.tex on the GPU: compute detile for tiled
// surfaces, then blit. side == nil: into the current command buffer (ends the open encoders;
// a barrier orders the detile after the writing dispatches). side != nil: into that command
// buffer with its own encoders; the current encoders stay open.
bool EncodeGpuUpload(const ImageDesc& img, const TextureCache::GpuUpload& up, id<MTLCommandBuffer> side) {
    if (!S.detile_pso || !up.tex || img.address >= S.ctx->mem_size) return false;
    const SurfaceDesc sd = img.ToSurfaceDesc();
    SurfaceLayout layout;
    if (sd.bpp == 0 || (sd.bpp & 7) || !ComputeSurfaceLayout(sd, &layout) || !layout.total_size) return false;
    const uint64_t avail = std::min<uint64_t>(layout.total_size, S.ctx->mem_size - img.address);
    id<MTLBuffer> gbuf = nil;
    uint64_t goff = 0;
    if (!GuestBuffer(img.address, avail, &gbuf, &goff)) return false;
    const bool tiled = sd.tile_mode != TileMode::DisplayLinearAligned && sd.tile_mode != TileMode::DisplayLinearGeneral;
    const uint32_t bpe = sd.bpp / 8;
    id<MTLTexture> tex = up.tex;
    if (up.surf.bpp != sd.bpp || up.layout.total_size != layout.total_size) {
        RLog("gpu-upload", "texture 0x%llx: cached layout differs from the T#", (unsigned long long)img.address);
    }
    id<MTLBuffer> src = gbuf;
    uint64_t src_base = goff, src_limit = goff + avail;
    if (tiled) {
        const SurfaceDesc& u = up.surf;
        const uint32_t kf[14] = {(uint32_t)u.tile_mode, u.bpp, u.num_samples, u.width, u.height, u.depth, u.pitch,
                                 u.levels, u.layers, (uint32_t)u.is_block | ((uint32_t)u.is_pow2 << 1) |
                                 ((uint32_t)u.alt_tile << 2), u.bank_swizzle, up.levels, (uint32_t)avail,
                                 (uint32_t)(avail >> 32)};
        uint64_t key = Fnv(kf, sizeof(kf));
        id<MTLBuffer> map = nil;
        auto mit = S.detile_maps.find(key);
        if (mit != S.detile_maps.end()) {
            map = mit->second;
        } else {
            std::vector<uint32_t> m;
            if (!BuildDetileMap(up.surf, up.layout, avail, 0, up.levels, &m) || m.empty()) return false;
            if (S.detile_maps.size() >= 64) S.detile_maps.clear();
            map = [S.dev newBufferWithBytes:m.data() length:m.size() * 4 options:MTLResourceStorageModeShared];
            if (!map) return false;
            S.detile_maps[key] = map;
        }
        // one private staging buffer per surface; reuse across frames is ordered by Metal's
        // hazard tracking (same buffer, same queue)
        key ^= img.address * 0x9E3779B97F4A7C15ull;
        id<MTLBuffer> staging = nil;
        auto sit = S.detile_staging.find(key);
        if (sit != S.detile_staging.end() && sit->second.length >= up.layout.total_size) {
            staging = sit->second;
        } else {
            if (S.detile_staging.size() >= 64) S.detile_staging.clear();
            staging = [S.dev newBufferWithLength:up.layout.total_size options:MTLResourceStorageModePrivate];
            if (!staging) return false;
            S.detile_staging[key] = staging;
        }
        const uint32_t count = (uint32_t)(map.length / 4);
        const uint32_t params[4] = {bpe, count, (uint32_t)avail, 0};
        id<MTLComputeCommandEncoder> enc;
        if (side) {
            enc = [side computeCommandEncoder];
        } else {
            enc = ComputeEncoder();
            [enc memoryBarrierWithScope:MTLBarrierScopeBuffers]; // order after the writing dispatches
        }
        [enc setComputePipelineState:S.detile_pso];
        [enc setBuffer:gbuf offset:goff atIndex:0];
        [enc setBuffer:staging offset:0 atIndex:1];
        [enc setBuffer:map offset:0 atIndex:2];
        [enc setBytes:params length:sizeof(params) atIndex:3];
        [enc dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        if (side) [enc endEncoding];
        else g_cstate.Reset(enc); // state set behind the dispatches' back
        src = staging;
        src_base = 0;
        src_limit = up.layout.total_size;
    }
    id<MTLBlitCommandEncoder> bl;
    if (side) {
        bl = [side blitCommandEncoder];
    } else {
        EndEncoders();
        EnsureCmd();
        bl = [S.cmd blitCommandEncoder];
    }
    const bool is3d = up.tex_type == MTLTextureType3D;
    const bool is1d = up.tex_type == MTLTextureType1D || up.tex_type == MTLTextureType1DArray;
    const NSUInteger tex_slices = (tex.textureType == MTLTextureTypeCube || tex.textureType == MTLTextureTypeCubeArray)
                                      ? tex.arrayLength * 6 : tex.arrayLength;
    for (uint32_t m = 0; m < up.levels && m < up.layout.num_mips; ++m) {
        const MipLayout& ml = up.layout.mips[m];
        const uint32_t w = std::max(1u, up.width >> m), h = is1d ? 1u : std::max(1u, up.height >> m);
        const uint64_t row = (uint64_t)ml.pitch * bpe, image = row * ml.height;
        const uint64_t rowbytes = (uint64_t)((w + up.block_width - 1) / up.block_width) * up.bytes_per_block;
        const uint64_t rows = (h + up.block_height - 1) / up.block_height;
        const uint32_t d = is3d ? std::max(1u, up.depth >> m) : 1u;
        const uint32_t slices = is3d ? 1u : std::min<uint32_t>(std::min(up.layers, ml.slices), (uint32_t)tex_slices);
        if (rowbytes > row || !rows) break;
        for (uint32_t sl = 0; sl < slices; ++sl) {
            const uint64_t off = src_base + ml.offset + (uint64_t)sl * image;
            if (off + (uint64_t)(d - 1) * image + (rows - 1) * row + rowbytes > src_limit) break;
            [bl copyFromBuffer:src
                       sourceOffset:off
                  sourceBytesPerRow:row
                sourceBytesPerImage:is3d ? image : 0
                         sourceSize:MTLSizeMake(w, h, d)
                          toTexture:tex
                   destinationSlice:sl
                   destinationLevel:m
                  destinationOrigin:MTLOriginMake(0, 0, 0)];
        }
    }
    [bl endEncoding];
    if (!side) {
        S.pending = true;
        LogWork("GPU texture upload");
    }
    return true;
}

// Hazard path: the texture's guest memory is written by GPU work that has not completed yet,
// so the copy goes into the current command buffer behind that work.
bool GpuUploadTexture(const ImageDesc& img, uint64_t write_epoch) {
    if (!S.detile_pso || img.address >= S.ctx->mem_size) return false;
    TextureCache::GpuUpload up;
    if (!S.tex->GetTextureForGpuUpload(img, write_epoch, S.write_epoch + 1, &up)) return false;
    if (!up.tex) return true; // already current (or a GPU-owned surface)
    if (EncodeGpuUpload(img, up, nil)) return true;
    S.tex->MarkStale(up.tex);
    return false;
}
```

(This is the former body with the encoder acquisition switched on `side`. Behaviour change in the hazard path: an encoding failure after the texture was handed out now marks it stale instead of leaving it marked current with no copy.)

- [ ] **Step 5: SampledTexture, verify mode, BindStage**

Next to the forward declarations near `id<MTLComputeCommandEncoder> ComputeEncoder();` add

```cpp
id<MTLTexture> SampledTexture(const ImageDesc& img);
```

After `GpuUploadTexture` add:

```cpp
const bool g_verify_gpu_upload = getenv("PS4_GNM_VERIFY_GPU_UPLOAD") != nullptr;

// Debug: compares a GPU copy with a CPU upload of the same guest memory once the GPU is done
// (level 0, slice 0). The game rewriting the memory between encoding and execution also shows
// as a difference, so a single report at an address needs a second look.
void VerifyGpuUpload(const ImageDesc& img, id<MTLTexture> tex) {
    MTLTextureDescriptor* td = [MTLTextureDescriptor new];
    td.textureType = tex.textureType;
    td.pixelFormat = tex.pixelFormat;
    td.width = tex.width;
    td.height = tex.height;
    td.depth = tex.depth;
    td.mipmapLevelCount = tex.mipmapLevelCount;
    td.arrayLength = tex.arrayLength;
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> ref = [S.dev newTextureWithDescriptor:td];
    if (!ref || !S.tex->DebugCpuUploadInto(img, ref)) return;
    const uint64_t addr = img.address;
    const uint32_t bpb = img.pixel.bytes_per_block, bw = std::max(1u, img.pixel.block_width),
                   bh = std::max(1u, img.pixel.block_height);
    AfterGpu([tex, ref, addr, bpb, bw, bh] {
        const NSUInteger w = tex.width, h = tex.textureType == MTLTextureType1D ? 1 : tex.height;
        const NSUInteger row = (w + bw - 1) / bw * bpb, rows = (h + bh - 1) / bh;
        std::vector<uint8_t> a(row * rows), b(row * rows);
        const MTLRegion r = MTLRegionMake3D(0, 0, 0, w, h, 1);
        [tex getBytes:a.data() bytesPerRow:row bytesPerImage:row * rows fromRegion:r mipmapLevel:0 slice:0];
        [ref getBytes:b.data() bytesPerRow:row bytesPerImage:row * rows fromRegion:r mipmapLevel:0 slice:0];
        static std::atomic<uint32_t> n_same{0}, n_diff{0};
        if (a == b) {
            n_same++;
        } else {
            n_diff++;
            fprintf(stderr, "[gnm-verify] GPU upload of 0x%llx differs from the CPU upload\n", (unsigned long long)addr);
        }
        if ((n_same + n_diff) % 50 == 0)
            fprintf(stderr, "[gnm-verify] GPU uploads checked: %u equal, %u different\n", n_same.load(), n_diff.load());
    });
}

// Sampled texture for BindStage. A large texture that needs an upload from guest memory is
// copied on the GPU in the upload command buffer (committed before the current one): the CPU
// detile of a big texture costs milliseconds on the encoder thread. Small textures, and copies
// that cannot be encoded, keep the CPU upload. PS4_GNM_GPU_UPLOAD_MIN_KB: threshold (default
// 256; 0: every size; -1: off).
id<MTLTexture> SampledTexture(const ImageDesc& img) {
    static const int64_t min_kb = [] {
        const char* v = getenv("PS4_GNM_GPU_UPLOAD_MIN_KB");
        return v ? (int64_t)atoll(v) : (int64_t)256;
    }();
    if (min_kb < 0 || !S.detile_pso) return S.tex->GetTexture(img);
    TextureCache::GpuUpload up;
    id<MTLTexture> tex =
        S.tex->GetTextureForGpuRefresh(img, S.write_epoch + 1, std::max<uint64_t>(1, (uint64_t)min_kb << 10), &up);
    if (!up.tex) return tex;
    if (!S.upload_cmd) {
        S.upload_cmd = [S.queue commandBuffer];
        S.upload_cmd.label = @"texture uploads";
        [S.upload_cmd addCompletedHandler:^(id<MTLCommandBuffer> done) {
            if (done.status == MTLCommandBufferStatusError)
                fprintf(stderr, "[gnm-draw] texture upload command buffer failed: %s\n",
                        done.error.localizedDescription.UTF8String);
        }];
    }
    if (EncodeGpuUpload(img, up, S.upload_cmd)) {
        g_hitch.gpu_uploads++;
        if (g_verify_gpu_upload) VerifyGpuUpload(img, up.tex);
        return tex;
    }
    S.tex->MarkStale(up.tex);
    return S.tex->GetTexture(img);
}
```

In `BindStage`, replace

```cpp
            } else {
                tex = S.tex->GetTexture(img);
                static const bool texdbg3d = getenv("PS4_GNM_TEXDBG3D") != nullptr;
```

with

```cpp
            } else {
                tex = SampledTexture(img);
                static const bool texdbg3d = getenv("PS4_GNM_TEXDBG3D") != nullptr;
```

Add `uint32_t gpu_uploads = 0;` to `HitchStats` (next to `uploads`) and `, gpu uploads %u` after `texture uploads %u (%.1f ms)` in the hitch line format, with `g_hitch.gpu_uploads` right after `g_hitch.upload_ms` in the arguments.

- [ ] **Step 6: Spec wording**

In the spec, replace the first sentence of component 6 with: "Sampled textures larger than 256 KB that need an upload from guest memory are copied on the GPU (compute detile + blit) in a separate upload command buffer that is committed right before the current one, so the open render pass is not split and the texture cache is looked up once per bind." Leave the rest of the component as it is.

- [ ] **Step 7: Build and verify correctness**

Build, then:

```bash
cp ~/ps4recomp-work/tlou_build/ps4_app ~/ps4recomp-work/tlou_build/ps4_app_t11
cd ~/ps4recomp-work
EXTRA="PS4_GNM_VERIFY_GPU_UPLOAD=1 PS4_GNM_GPU_UPLOAD_MIN_KB=0" tools/walk_bench.sh spores ps4_app_t11 t11verify
grep "GPU uploads checked" walk_bench/t11verify-spores/run.log | tail -1
grep "differs from the CPU upload" walk_bench/t11verify-spores/run.log | awk '{print $6}' | sort | uniq -c | sort -rn | head
```

Expected: `fatal 0`; the last summary shows hundreds of checked uploads; no address differs more than once. An address that differs repeatedly is a real copy bug: stop and fix it before continuing (compare the cached layout with `PS4_GNM_TEXDBG=1` for that address).

- [ ] **Step 8: Measure and compare pictures**

```bash
cd ~/ps4recomp-work
tools/walk_bench.sh spores ps4_app_t11 t11
EXTRA="PS4_GNM_GPU_UPLOAD_MIN_KB=-1" tools/walk_bench.sh spores ps4_app_t11 t11off
for l in t11off t11; do echo "== $l"; head -1 walk_bench/$l-spores/report.txt; grep -o "texture uploads [0-9]* ([0-9.]* ms), gpu uploads [0-9]*" walk_bench/$l-spores/run.log | sort -t'(' -k2 -n | tail -3; done
```

Expected: `t11` has no more `>33ms` frames than `t11off` and its largest per-frame CPU upload times are lower; `gpu uploads` > 0 in `t11`; `avg fps` not lower than `t11off` by more than 3.

Pictures: run each variant 240 s from `data_ch1` with screenshots and compare the same frames:

```bash
cd ~/ps4recomp-work
for v in on off; do rm -rf data_tmp_t11 shots/t11pic_$v; cp -R data_ch1 data_tmp_t11
  X=""; [ $v = off ] && X="PS4_GNM_GPU_UPLOAD_MIN_KB=-1"
  BIN=ps4_app_t11 PS4RECOMP_DATA_DIR=$PWD/data_tmp_t11 LOG=$PWD/run_t11pic_$v.log EVERY=1500 ./run_perf.sh $PWD/shots/t11pic_$v 240 PS4_PRO=0 $X >/dev/null 2>&1; done
rm -rf data_tmp_t11
python3 - <<'PY'
from PIL import Image
import os
H = os.path.expanduser('~/ps4recomp-work/shots')
rows = []
for f in ('frame_009000.png', 'frame_013500.png'):
    a = Image.open(f'{H}/t11pic_on/{f}').convert('RGB').resize((640, 360))
    b = Image.open(f'{H}/t11pic_off/{f}').convert('RGB').resize((640, 360))
    rows.append((a, b))
out = Image.new('RGB', (1280, 360 * len(rows)))
for i, (a, b) in enumerate(rows):
    out.paste(a, (0, 360 * i)); out.paste(b, (640, 360 * i))
out.save(f'{H}/t11pic_compare.png')
PY
```

Expected: in `shots/t11pic_compare.png` the left (GPU uploads) and right (CPU uploads) images show the same textures (the camera may differ slightly between runs).

- [ ] **Step 9: Commit**

```bash
cd ~/ps4recomp-work/PS4Recomp
git add pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.h pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.mm \
  pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm docs/superpowers/specs/2026-10-18-movement-hitches-design.md
git commit -q -m "Copy large sampled textures on the GPU in an upload command buffer

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Spec addendum — hitches without renderer work (approval gate)

**Files:**
- Modify: `docs/superpowers/specs/2026-10-18-movement-hitches-design.md` (new section at the end)

- [ ] **Step 1: Collect the evidence**

From `walk_bench/baseline.txt` and the latest runs (t11, t11off) take every stall ≥ 100 ms whose hitch line has no shader/pipeline/upload time. For each: the busy threads' top functions, what "Frame Submission" waits on, and the io/vm/mtlbuf/texlock values of that frame. Group stalls with the same top function.

- [ ] **Step 2: Write the addendum**

Append a section `## Addendum: cause of hitches without renderer work (YYYY-MM-DD)` with: the grouped evidence (numbers), the cause per group, the proposed fix per group (component, files, switch to turn it off), how it will be verified (walking benchmark, A/B, screenshots). No code yet.

- [ ] **Step 3: Commit and ask the owner**

```bash
cd ~/ps4recomp-work/PS4Recomp
git add docs/superpowers/specs/2026-10-18-movement-hitches-design.md
git commit -q -m "Spec addendum: cause of hitches without renderer work

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Then stop and present the addendum to the owner (in Russian). Implementation of the addendum gets its own plan section after approval (writing-plans again).

---

### Task 13: Final verification and install

**Files:** none in the repository besides the commits above; `/Volumes/ssd/The Last of Us Remastered Repack/ps4recomp-work/{all-fixes.patch,progress.md}`.

- [ ] **Step 1: Walking benchmark, final build, two runs per route**

```bash
cd ~/ps4recomp-work && cp tlou_build/ps4_app tlou_build/ps4_app_final
for r in 1 2; do for route in spores courtyard; do tools/walk_bench.sh $route ps4_app_final final$r; done; done | tee walk_bench/final.txt
```

Expected (acceptance): in the second run of each route, `frames >33ms 0` — or, if not reached, every remaining long frame is listed with its cause in the report to the owner (no claim of success without the numbers).

- [ ] **Step 2: FPS A/B** (courtyard and Sarah's house, 2 rounds, `ps4_app_inst` vs `ps4_app_final`, the commands of the earlier A/B in this project: `run_perf.sh` 240 s / `BENCH=1` 150 s). Expected: average FPS not lower than `ps4_app_inst` beyond the noise (±3 fps).

- [ ] **Step 3: Exit test on the final build, both ways, 3 times each.** Expected: all `PASS`.

- [ ] **Step 4: Install**

```bash
cd ~/ps4recomp-work/tlou_build
pgrep -fl "MacOS/eboot" && echo "RUNNING: ask the owner to quit first" || { cp ps4_app eboot.app/Contents/MacOS/eboot.new && mv -f eboot.app/Contents/MacOS/eboot.new eboot.app/Contents/MacOS/eboot && codesign -f -s - eboot.app && codesign -v eboot.app && echo INSTALLED; }
```

- [ ] **Step 5: Patch and notes**

```bash
cd ~/ps4recomp-work/PS4Recomp; D="/Volumes/ssd/The Last of Us Remastered Repack/ps4recomp-work"
bash -c 'git diff 63510f6 -- . ":!3rdparty"; git ls-files --others --exclude-standard | grep -v -E "^3rdparty/|\.orig$|\.rej$|\.a$" | while read f; do git --no-pager diff --no-index /dev/null "$f"; done; true' > "$D/all-fixes.patch.new" && mv -f "$D/all-fixes.patch.new" "$D/all-fixes.patch"
ls -la "$D/all-fixes.patch"; grep -c "^diff --git" "$D/all-fixes.patch"
```

Expected: ≥ 1.1 MB, ≥ 88 entries (the new files add entries). The diff base is the upstream commit `63510f6`: since Task 0 the work is committed, so a plain `git diff` would be nearly empty. Update the memory note `~/.claude/projects/-Volumes-ssd-The-Last-of-Us-Remastered-Repack/memory/patch-export-under-bash.md` with this command (diff against `63510f6` plus untracked files). Append a Russian section to `$D/progress.md` with the before/after numbers of Steps 1–2.
