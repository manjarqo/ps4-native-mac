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

Sampled textures larger than 256 KB that need an upload from guest memory go through the existing GPU path (compute detile + blit) before the render pass or compute encoder starts, not only when a GPU write conflicts. The CPU path stays for textures below the threshold and for layouts the GPU path does not support (it reports failure and the texture is marked stale again, so the CPU path uploads it at bind time). The threshold is `PS4_GNM_GPU_UPLOAD_MIN_KB` (0: everything on the GPU, -1: off). The GPU reads guest memory when it executes, as on the PS4. A debug mode `PS4_GNM_VERIFY_GPU_UPLOAD=1` compares the GPU result byte by byte with a CPU upload of the same memory into a scratch texture.

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
