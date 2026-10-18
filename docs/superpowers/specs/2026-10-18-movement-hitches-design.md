# Movement hitches and crash on exit — design

Date: 2026-10-18. Project: PS4Recomp, The Last of Us Remastered (CUSA00557), Metal on an M1 Pro Mac.
Sub-project 1 of 3. Rendering artifacts (2) and wrong colors (3) get their own specs.

## Problem

The owner plays the installed build `tlou_build/eboot.app` (two-thread renderer, coroutine fibers, atomic mutexes). While moving through a level, every 10–50 s a frame freezes: the overlay shows 4 FPS, 241 ms, max 1163 ms. Standing still, there are no freezes. Quitting the game makes macOS show a crash report.

### Data (2026-10-18)

Walking run from a copy of the owner's save (SAVEDATA04, spore-filled corridor) with the pad script `walk_script.txt` and `PS4_STALL_WATCHDOG=80`:

1. ~120 ms frames exactly every 300 frames come from the test harness screenshot (`PS4_SCREENSHOT_EVERY=300`). They do not exist in normal play and must not affect measurements.
2. Real hitches when entering new places, 200–964 ms, of two kinds:
   - Metal pipeline builds inside the frame. Examples from `hitch` lines: 2 pipelines in 345.6 ms; 27 in 322.8 ms; 11 in 229.7 ms; 1 in 200.5 ms. These pipelines are known from earlier sessions (`pipelines.bin`). They are built synchronously on the assumption that the system Metal cache returns them in well under a millisecond, and that cache missed. It is most likely keyed to the executable, so every rebuild of the game invalidates it. The same frames also contain cached shaders (30 in 134 ms, ~4.5 ms each, on the game thread) and texture uploads (33 in 82 ms, ~2.5 ms each, on the encoder thread).
   - Hitches without renderer work: 250, 431, 706, 761, 964 ms with 0 shaders, 0 pipelines, 0 texture uploads, 0 GPU waits. The single watchdog snapshot shows the "Frame Submission" thread waiting on a game condvar or sleeping in `sceKernelUsleep`, while the NdJob worker threads execute game code. The cause is unknown.
3. Crash on exit (`~/Library/Logs/DiagnosticReports/eboot-2026-10-18-144159.ips`):
   - the main thread is in `exit()` → static destructors (`ps4draw::State::~State`);
   - at the same time a Metal command buffer completion handler runs an EOP fence (`HandleEventWriteEop` → `RunFences`) and locks an already destroyed mutex → `std::system_error` → `abort`.
   - Every exit path (`windowShouldClose`, `windowWillClose`, `applicationShouldTerminate*`, Cmd+Q and the hidden-window check in `metal_screen_pump_events_main`) calls `exit(0)` while all threads keep running. There are no `atexit` handlers and the pipeline list is appended immediately, so nothing needs saving on exit except the new pipeline archive.

## Goal and acceptance criteria

- No frame longer than 33 ms on the walking routes, loading screens excluded. Two routes: the spore corridor (owner's save) and the chapter 1 courtyard (`data_ch1`).
- Checked from the second run after updating the build. The first run fills the pipeline archive and may hitch where it does today. Places that are entirely new to the machine (shaders and pipelines never built) keep the existing path: background build, draw skipped until ready.
- Average FPS in the usual A/B (courtyard, Sarah's house) does not drop.
- The picture does not change (screenshot comparison).
- Quitting via the window close button and Cmd+Q leaves no crash report.

Out of scope: artifacts, colors, GPU performance, loading screens.

## Components

### 1. Walking benchmark — `~/ps4recomp-work/tools/walk_bench.sh`

- Arguments: route (`spores` | `courtyard`), binary, run label.
- Copies the save into its own data directory (`PS4RECOMP_DATA_DIR`), runs the game through `run_perf.sh` with `PS4_PAD_SCRIPT="$(cat walk_script.txt)"` and `PS4_PAD_AUTOPRESS_UNTIL=90000`. Screenshots are disabled during the walk (a screenshot directory exists, the interval is longer than the run).
- After the run it prints, for the walking window (first script command to the end of the run): the number of frames over 33/100 ms, max, p99, average FPS, and the `hitch` breakdown of every long frame. Also loadavg and the CPU share of other processes (`mutex_perf/extload.sh`).
- Frame times come from a new per-frame log of long frames: `PS4_GNM_LOG_LONG_FRAMES=<ms>` writes one line `[gnm-draw] long frame <ms> at <s since start> (frame <n>)` for every frame longer than the threshold. The benchmark uses 33 and counts lines inside the walking window; the frame count of the window comes from the present counter. The existing `frame times over 600 frames` lines do not fit (their windows do not match the walking window), and `hitch` lines are only written for frames over ~50 ms.

### 2. Stall profiler — `PS4_STALL_PROFILE=<ms>` (kernel/threading)

- Extends the existing `PS4_STALL_WATCHDOG`. When no frame has been presented for longer than the threshold, the watchdog thread samples every guest thread every 1 ms until the next frame (`thread_suspend` → `thread_get_state` → `thread_resume`). It records the PC and up to 8 return addresses along the host frame-pointer chain (x29); stack reads go through `vm_read_overwrite`, so a bad frame pointer cannot crash the process.
- On the next frame it prints the stall length, the number of samples and, for every thread that was busy, up to 6 most frequent functions (dladdr, without offsets) with their share of samples. For waiting threads it prints the wait function and the nearest guest function above it (`fn_0x…`).
- The watchdog does not hold `g_threads_mutex` while a thread is suspended: the thread list is copied under the lock, then the lock is released.
- Zero cost without stalls (the watchdog sleeps until the threshold).

### 3. Counters in the long-frame breakdown (`[gnm-draw] hitch`)

New fields, ms per frame: `io` (file reads, including AIO), `vm` (mmap/munmap/mprotect/direct memory mapping), `mtlbuf` (Metal buffer creation in `GuestBuffer`), `texlock` (waiting for the texture cache lock), `shader_fs` (file operations while preparing a shader). Atomic counters, updated only around these calls.

### 4. Pipeline archive — `ps4_gnm_pipeline_archive.{h,mm}` (libSceGnmDriver)

```
namespace ps4gnm_pso_archive {
bool Open(id<MTLDevice> dev, const std::string& dir, uint64_t budget_bytes); // at Init, next to the MSL cache
bool Enabled();
void Attach(MTLRenderPipelineDescriptor* d);              // d.binaryArchives = @[archive]
void Attach(MTLComputePipelineDescriptor* d);
bool Contains(uint64_t stable_key);                       // is the pipeline in the archive
void Add(uint64_t stable_key, MTLRenderPipelineDescriptor* d);    // after a build, if missing
void Add(uint64_t stable_key, MTLComputePipelineDescriptor* d);
bool SaveNow(double timeout_s);                           // synchronous (exit)
}
```

- File `~/Library/Caches/PS4Recomp/CUSA00557/msl/pipelines.metalar` and index `pipelines_archived.bin` (stable pipeline keys, 8 bytes each). The stable key is the one `RememberPipeline` writes to `pipelines.bin` (MSL hashes of the shaders + state); for compute pipelines it is the shader's MSL hash and the workgroup size.
- If the archive cannot be opened, is corrupt or incompatible with the OS/GPU, its file and index are deleted and a new one is created. Pipelines are built as without an archive.
- Saving: `serializeToURL:` into a temporary file, then `rename`. Saved on exit and every 5 minutes when something was added, on a background queue. If measurements show that saving affects frames, only the exit save remains.
- Budget: 384 MB (`PS4_GNM_PSO_ARCHIVE_MB`). If the file is larger, the next start begins a new archive. `PS4_GNM_NO_PSO_ARCHIVE=1` disables the module.
- Hooked into: `GetGfxPipeline` and the compute pipeline build in `DispatchEncode`, including the background build of new pipelines (its result is added too). Internal pipelines (present, detile, depth copies) are not touched.

Pipeline build order:

| Pipeline | Action |
|---|---|
| never seen (not in `pipelines.bin`) | background build, draw skipped until ready (as today), then `Add` |
| known, in the archive | synchronous with the archive (~1 ms) |
| known, not in the archive | synchronous, then `Add` (once per machine) |

### 5. Cached shaders without file operations in the frame

The MSL disk cache check (`access()` in `StoreMslInDiskCache`) is replaced by a set of known MSL hashes in memory, filled at startup from the cache directory listing that the shader warm-up already reads. Writing a new MSL file moves to a background serial queue. Then sub-timers show how much remains in the compatibility check and the shader clone; if that is more than ~0.5 ms per shader, it is decided separately from the data.

### 6. Texture uploads on the GPU

Sampled textures larger than 256 KB that need an upload from guest memory are copied on the GPU (compute detile + blit) in a separate upload command buffer that is committed right before the current one, so the open render pass is not split and the texture cache is looked up once per bind. The CPU path stays for textures below the threshold and for layouts the GPU path does not support (it reports failure and the texture is marked stale again, so the CPU path uploads it at bind time). The threshold is `PS4_GNM_GPU_UPLOAD_MIN_KB` (0: everything on the GPU, -1: off). The GPU reads guest memory when it executes, as on the PS4. A debug mode `PS4_GNM_VERIFY_GPU_UPLOAD=1` compares the GPU result byte by byte with a CPU upload of the same memory into a scratch texture.

### 7. Hitches without renderer work

No fix is defined yet. After the profiler data (components 2–3) an "Addendum: cause of hitches without renderer work" section is added to this file with the cause and the fix. The owner approves it before implementation.

### 8. Exit without a crash

One function `ps4_host_quit(int code)` (core/recomp_runtime.c):
1. save the pipeline archive (limit 2 s);
2. `fflush(NULL)`;
3. `_exit(code)`.

All exit paths in `ps4_metal_screen.m` call it instead of `exit(0)`. Static destructors no longer run on exit; the OS releases everything. Game saves are written synchronously by game threads; quitting in the middle of a save stays as it is today (not worse).

## Order of work

1. Walking benchmark, profiler, counters. Baseline: 2 routes × 2 runs on the current build.
2. Exit without a crash.
3. Pipeline archive → measurement.
4. Shaders without file operations → measurement.
5. Texture uploads on the GPU → measurement, screenshot comparison.
6. Addendum on hitches without renderer work → approval → fix → measurement.
7. Final measurement, FPS A/B, install, all-fixes.patch, progress.md.

Every step can be turned off with an environment variable. The previous build (`tlou_build/ps4_app_inst`) is kept for comparison.

## Verification

- Walking benchmark: both routes, 2 runs before and after each step. Runs with outside load are discarded (memory rule: loadavg and other processes' CPU).
- FPS A/B: courtyard and Sarah's house, 2 rounds, alternating with the build before the change.
- Picture: screenshots at the same frames of runs before and after, compared pairwise; for step 5 also the byte-by-byte verify mode on several runs.
- Exit: start, quit via Cmd+Q (`[NSApp terminate:]`) and via the window close button (`performClose:`), check that no new report appears in DiagnosticReports.
- No automated runs on the owner's live saves: only copies in their own data directories.

## Addendum: cause of hitches without renderer work (2026-10-18)

Scope: every stall ≥ 100 ms whose `hitch` line has 0 shaders, 0 pipelines, 0 texture uploads (io/vm/mtlbuf ≈ 0, texlock ≤ 1.4 ms in all of them). Data: the baseline (base1/base2 × spores/courtyard), the task 10/11 runs, and 8 task 12 runs on the 671e610 build with temporary diagnostics (not committed; patch and scripts in `~/ps4recomp-work/walk_bench/t12-diag/`): full call chains per thread, per-thread CPU time while sampled, CPU per process, per-frame GPU timing (commit → GPU start → done), per-frame VM statistics, and the duration of the `sceNpCheckCallback` log write.

### What the job workers do

`fn_0xc87c10` is the NdJob worker's idle loop: it polls the 8 job queues, executes `pause` (`RECOMP_SPIN_PAUSE`, an ISB) and, on workers 0–3, reads the TSC every round to run expired timers (0xc87df3). `__udivmodti4`/`__udivti3` are the 128-bit division in `recomp_rdtsc`. The workers sleep only when the job manager flag at `+0x59` is set; it is not, so idle workers spin. "All workers busy 85–100 % in `fn_0xc87c10`" therefore means *no job is runnable*: the frame waits for one job that is blocked, or for a thread outside the job system.

The game's frame ring (32 slots at 0x1700c30, 0xa20 bytes each) has two stamps: `+0x9d0` (written by Frame Submission after it submitted the frame, 0xb49fa3) and `+0x9d8` (written by the "GPU Interrupts Handler" thread on the frame's EOP, 0xb29b34). `fn_0xb3d750` waits for a frame: first a 1 ms `sceKernelUsleep` loop until `+0x9d0` is set (waits for the CP), then a 250 ms timed condvar wait until `+0x9d8` is set (waits for the GPU). `fn_0x102e0` and Frame Submission's own loop in `fn_0xb49f60` (frame N-3) poll `+0x9d8` with 1 ms sleeps. Frame Submission waiting in `__psynch_cvwait in fn_0xc81c40` (called from `fn_0xb49f60`) is waiting for the game to queue the next frame.

### Groups

Counts are stalls ≥ 100 ms without renderer work. "Old runs" = 4 baseline + 8 task 10/11 runs.

| Group | Signature | Old runs | Task 12 runs |
|---|---|---|---|
| 1. Log write on a job | one worker 85–98 % in `__write_nocancel`, the others spin | 10 (2555 ms) | 9 (2074 ms) |
| 2. CP thread starved | Frame Submission "busy" ≥ 50 %, or a worker in the 1 ms loop of `fn_0xb3d750` (waiting for the submission) | 52 (7511 ms) | 27 (4369 ms) |
| 3. Job workers starved | workers busy with real jobs and partly spinning, Frame Submission waits for the frame | 19 (2827 ms) | 19 (3070 ms) |
| 4. GPU completion late | a job in the condvar wait of `fn_0xb3d750`, or Frame Submission in the `fn_0xb49f60` sleep loop | 8 (2248 ms, incl. the 1132 ms stall of t10b) | 4 (687 ms) |

Baseline alone: group 1: 3 (689 ms), 2: 19 (2415 ms), 3: 7 (1017 ms), 4: 1 (124 ms).

#### Group 1: `printf` in the `sceNpCheckCallback` stub

- Chain (t12diag): `__write_nocancel ← __swrite ← __sfvwrite ← puts ← shim_sceNpCheckCallback ← fn_0x9a6f40 ← job fn_0x2600 ← fn_0xc87c10`. The game calls `sceNpCheckCallback` once per frame from a job the frame depends on; the stub (`modules/libSceNp/ps4_np.c`, `NP_LOG`) prints a line to stdout on every call. With stdout redirected to a file, libc flushes ~4 KB every ~140 calls. Measured duration of that `printf` (t12diag2/3): up to 303.6, 226.0, 149.4 ms; 21 calls over 5 ms in one run. Every such stall contains it.
- A/B: the same binary with the log suppressed (t12q): 0 stalls of this group (1–5 per run otherwise).
- Why a 4 KB write to `run.log` blocks for 100–300 ms is not proven. Likely: the internal disk is 98 % full and the system swaps 1–12 k pages per 5 s to the same disk during the run.
- Who is affected: every benchmark and every launch from a terminal. A launch from Finder has stdout on `/dev/null`, so the owner's normal play does not have this group. It distorts every measurement, though.
- Confidence: high (mechanism, A/B), medium (why the write blocks).

#### Group 2: the CP thread does not get the CPU

- In these stalls Frame Submission processes draws: inclusive shares (t12d6) `ps4draw::Draw` 82–96 %, `GetShader` 37–52 % (`BuildFlat`, `gcn_shader_find_compatible_flat`, `Shader::Info` copies), `encq::Defer` 12–45 % (`notify_one` into the encoder), `DecodeStageImages` 7–25 %. The guest job waits in `fn_0xb3d750` for the submission stamp.
- But the thread hardly runs. CPU time of Frame Submission inside the sampled window: 6.2, 12.0, 8.6 ms in windows of 124, 152, 101 ms where it was "busy" in 56, 84, 87 % of the samples (t12d6, load 10). Same in t12d4: 3.6–13.5 ms in 43–172 ms windows. The profiler's "busy" counts a runnable thread that is not running. The workers got 0–30 % of a core in the same windows.
- Where the CPU went (t12d6, all 3 stalls without renderer work): the game process got 145–275 ms of CPU in those windows, "Claude Helper (Renderer)" 571–642 ms (4–5 cores). Guest threads run at default priority (31); the GNM encoder, Metal threads and other apps' UI threads run at 37–47.
- A/B (same diagnostics, log suppressed, load 11): Frame Submission at `QOS_CLASS_USER_INTERACTIVE` (t12d4ui) vs default (t12q): group 2 stalls 0 vs 7 (1004 ms); frames > 100 ms 4 vs 6; max 135 vs 368 ms; FPS 101.9 vs 102.1.
- Why only while moving: in new areas the CP's per-draw work grows (new draws, shader permutations resolved by `GetShader`), so it needs more CPU exactly when the jobs stream and our background compile threads run. A short CPU shortage then costs one or more frames.
- Benchmark conditions make it worse: the game window is an accessory window behind everything (`PS4_BACKGROUND_WINDOW`), the process does not opt out of App Nap or timer coalescing, and the Claude app is in front.
- Confidence: high for the mechanism (CPU time vs samples) and for the effect of the CP's QoS. One A/B pair only. The share of outside load versus the game's own threads is not measured for the owner's play.

#### Group 3: job workers do not get the CPU

- With the CP raised (t12d4ui) the 5 remaining stalls (598 ms) are this group: workers "busy" 51–100 % of the samples but on the CPU only 0–62 % of the window (mostly 10–35 %). Their CPU went to the same competitors as in group 2, now with the CP ahead of them.
- The older runs have no CPU time, so there it cannot be told whether a stall of this group is starvation or genuine serial job work.
- Confidence: medium.

#### Group 4: GPU completion late

- t12diag3, 297 ms: the job waits in the condvar of `fn_0xb3d750` for the frame's EOP. A command buffer of that frame waited 290.9 ms between commit and GPU start. In the same frame the system swapped: swap-ins 2785, swap-outs 3216, decompressions 49425 pages. Free memory stayed at 50–180 MB for the whole run. Swap use was 8.5 of 9.2 GB, with a Virtualization VM (2.2 GB) and the Claude app (2.6 GB) resident next to the game (3.1 GB).
- In all other stalls the GPU side was fast: encoder 5–27 ms per frame, commit → done ≤ 8 ms.
- The 1132 ms stall of t10b (Frame Submission in the `fn_0xb49f60` loop waiting for frame N-3 on the GPU) belongs here. It had no GPU timing, so its cause is not proven.
- Confidence: low–medium. Probably environmental (memory pressure on a 16 GB machine).

#### Hypotheses that were tested and rejected

- Atomic mutexes and coroutine fibers: with `PS4_MUTEX_LEGACY=1 PS4_FIBER_THREADS=1` (t12qlegacy vs t12q): 9 stalls (1536 ms) vs 7 (1004 ms), FPS 68.0 vs 102.1, frames > 33 ms 36 vs 27. The new primitives do not cause the stalls; the legacy ones are worse.
- TSC: the 128-bit division is the conversion in `recomp_rdtsc`, executed by idle workers. The guest computes its timeouts from the same counter (`sceKernelGetTscFrequency` = 2.13 GHz), so the timeouts are not wrong.
- Sleep granularity: the guest's sleep loops sleep 1 ms (`usleep(1000)`). That adds at most 1–2 ms per wait.
- Timeout units: `shim_scePthreadCondTimedwait` takes µs and converts them correctly.
- No hidden producer: no I/O, streaming or GPU-interrupt thread was busy or blocked in these stalls (all sampled, including host threads).

### Proposed fixes

1. **NP stub logging** (group 1). Component: `modules/libSceNp/ps4_np.c`. Each NP stub logs its first call only and counts the rest. A summary of the counts goes into the periodic perf output. `PS4_NP_LOG_ALL=1` restores logging of every call. The implementation plan also lists the other shims that print on every call from guest threads, and gives them the same treatment.
2. **CP thread priority** (group 2). Component: libSceGnmDriver (`ps4_gnm_metal.mm`, the entry of `sceGnmSubmitCommandBuffers` / `sceGnmSubmitAndFlipCommandBuffers`). The guest thread that submits command buffers sets itself to `QOS_CLASS_USER_INTERACTIVE` once, at its first submit. That is the same class as the GNM encoder, and the thread only runs when it has work. Off: `PS4_GNM_CP_QOS=0`.
3. **No App Nap, no timer coalescing** (groups 2, 3). Component: `modules/libSceVideoOut/ps4_metal_screen.m` at startup. Call `[[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical reason:...]` and keep the activity for the lifetime of the process. Off: `PS4_NO_LATENCY_ACTIVITY=1`.
4. **Job worker priority** (group 3). Decided by measurement, not yet proposed as a change. Candidate: NdJob worker threads at `QOS_CLASS_USER_INITIATED`, above other apps' default work and below the CP, the encoder and audio. They should not go to USER_INTERACTIVE, because idle workers spin. Switch: `PS4_GUEST_WORKER_QOS=<default|utility|initiated|interactive>`, default unchanged until measured. Cheapest experiment that settles it: one A/B pair with fixes 2+3 on, `PS4_GUEST_WORKER_QOS=initiated` vs default, both under the controlled load described below.
5. **Profiler: CPU time per thread** (diagnostics). Component 2 gets the per-thread CPU time of the sampled window and the CPU of other processes, as in the temporary patch. "Busy" alone cannot tell work from starvation. Off: part of `PS4_STALL_PROFILE`.
6. **Group 4.** No runtime change yet. Cheapest experiment: two walking runs with the VM stopped, comparing GPU commit → start delays and VM statistics per frame. If the delays stay, measure how much memory Metal wires in guest-memory windows (`S.guest_bufs`: 64 MiB windows, never released) and propose bounding it.

### Verification

- Walking benchmark, both routes, 2 runs per arm, the builds alternating (fix on/off through the switches). Runs with load > 15 are discarded. Reported per run: frames > 33/100 ms, max, and the stalls without renderer work by group. The classification script goes into `tools/` and uses the profiler's CPU time (fix 5).
- Controlled load: the same pairs with a fixed CPU load next to the game, for example 8 × `yes > /dev/null`, plus one run with the Claude app in front as today. This reproduces groups 2 and 3 on purpose. Target: no stall over 100 ms from groups 1–3.
- Group 1: one run with stdout to a file and logging at the default: no `__write_nocancel` stalls.
- FPS A/B, courtyard and Sarah's house, 2 rounds alternating. The QoS changes must not lower the average FPS.
- Screenshots of the same frames before and after: identical, because nothing in rendering changes.
