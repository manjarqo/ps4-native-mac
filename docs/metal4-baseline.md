# Metal 4 backend: baseline numbers (Metal 3)

Recorded by Task 0.4 of docs/superpowers/plans/2026-10-22-metal4-backend.md on commit 3f6c0cc (the
tree has no Task 1.1: this is Metal 3 as on main), Apple M1 Pro, macOS 27.0.1. Every phase gate
appends its own section below.

Notes that apply to every number here:

- The allocation count of `gnm_replay --allocs` is process-wide inside the armed window (between
  the renderer's Draw/Dispatch and its Flush(true)): worker threads and completion handlers count
  too, the minimum of N replays absorbs unrelated threads, and allocations after Flush(true) are
  not counted. (This sentence belongs in docs/metal4-backend.md, which this tree does not contain;
  the controller carries it over at merge.)
- The route has no resolution setting: TLOU renders at its native 1920x1080 with PS4_PRO=0 and
  PS4_UPSCALE=0 (the 720p limit could not be applied).
- The machine was shared with other agents' builds during the runs: the 1-minute load of the kept
  runs is 9.4-10.8, and every kept run had at most one monitor sample with other processes above
  150 % CPU. The two warm-up runs (not counted) are in the same log directory.

## Phase 0 (Metal 3, before the seam)

- TLOU route: courtyard walk (tools/metal4_route.sh, data_ch1 copy, 300 s, PS4_PRO=0,
  PS4_UPSCALE=0, scratch data and cache dirs), via tools/metal4_perf_ab.sh with both sides the
  same Metal 3 build (N=3). Six kept runs (A2-A4, B3, B4 and B6; A1, B1, B2 and B5 were dropped by the
  load / other-process rule and repeated):

| run | fps | encoder ms/frame | CP ms/frame | commits/frame | skipped draws (cumulative) | load |
|---|---|---|---|---|---|---|
| p0_route_A2 | 83.4 | 11.6 | 7.6 | 49.2 | 27080 | 9.5 |
| p0_route_A3 | 83.4 | 11.5 | 7.6 | 48.8 | 27986 | 9.4 |
| p0_route_A4 | 83.4 | 11.5 | 7.6 | 48.8 | 28059 | 10.8 |
| p0_route_B3 | 83.8 | 11.5 | 7.6 | 49.1 | 27521 | 10.2 |
| p0_route_B4 | 83.3 | 11.5 | 7.5 | 48.9 | 27932 | 9.8 |
| p0_route_B6 | 83.1 | 11.6 | 7.7 | 49.2 | 26563 | 9.6 |

  Median fps 83.4, spread 83.1-83.8 (A side median 83.4, B side 83.3). Median encoder ms 11.5,
  CP ms 7.6, commits per frame 49.0. No FATAL, GPU error or watchdog line in any run. Reports:
  ~/ps4recomp-work/metal4_research/runs/p0_route_*.log, the A/B output in ab_p0_route.txt, the
  summary over the kept logs (tools/metal4_perf_ab.sh with SUMMARY_ONLY=1, Metal 3 against Metal 3)
  in ab_p0_route_summary.txt.
- Capture set (TLOU build p0, PS4_GNM_SYNC_ENCODE=1 PS4_GNM_CAPTURE_REPLAY=all
  PS4_GNM_CAPTURE_RAW_MB=4096, frame 3600 of the route from each save; a shot of the route
  confirms the run is in gameplay, the courtyard capture shows the player in the alley):
  courtyard (data_ch1) 587 passes, 1.3 GB; spores (data_user1441) 1259 passes, 4.0 GB. The
  spores frame is the save's dark spore sequence (particle passes over black), not a menu or a
  loading screen; the later frames of the run are a room with the player.
- Replay pass set, Metal 3 hash lists in metal4_research/replay/p0_m3_{courtyard,spores}.txt:
  courtyard frame 3600: 570 passes replayed (569 byte-exact vs the capture), 17 not replayed
  (renderer-skipped clears, copies and decompress passes, and one texture over the capture
  budget); spores frame 3600: 267 passes replayed (266 byte-exact vs the capture), 992 not
  replayed (988 of them because a t0_color0 output exceeded the 4096 MB raw budget of the
  capture, so the pass is not stored replayable). A larger PS4_GNM_CAPTURE_RAW_MB would
  widen the spores set, at the cost of disk.
  Non-deterministic passes (differ between two Metal 3 runs): none. A second replay of each
  frame (p0b_m3_*.txt) compares `different: 0; missing: 0` with the first.
- Allocations per replayed pass (courtyard frame 3600, min of 5 per run, lowest of 3 runs, process-wide
  as noted above): draw pass 1: 120 (121, 121, 120); dispatch pass 0: 30 (30, 30, 30); output in metal4_research/replay/p0_allocs.txt.
- Host suite: green (host=0, 0 FAIL lines; log metal4_research/host_p0.log).

## Phase 1 (seam, Metal 3 behind it), commit 14f7e82

- Replay: byte-identical to Phase 0 on both frames (courtyard 570 passes, 571 outputs; spores
  267 passes, 267 outputs; `different: 0; missing: 0`). Hash lists:
  metal4_research/replay/p1_m3_{courtyard,spores}.txt.
- `PS4_GNM_METAL=4` stops at startup with "the Metal 4 backend is not implemented in this build"
  (exit 2). `PS4_GNM_METAL=7` stops with "PS4_GNM_METAL must be 3 or 4".
- Allocations per replayed pass (courtyard frame 3600, min of 5 per run, lowest of 3 runs):
  draw pass 1: 119 (119, 120, 120; Phase 0 120); dispatch pass 0: 29 (29, 29, 29; Phase 0 30).
  Output in metal4_research/replay/p1_allocs.txt.
- TLOU route A/B (tools/metal4_perf_ab.sh, A = Phase 0 build tlou_build_p0, B = Phase 1 build
  tlou_build_p1, both Metal 3, 300 s each, alternating A1 B1 ... A6 B6 after one warm-up per
  side):
  - The script kept 1 run per side and stopped, because of its other-process rule (other
    processes above 150 % CPU in more than one monitor sample). With the exclusive lock held, the
    background of this session is about 115 % CPU with no game running (WindowServer about 48 %,
    the Claude app about 40 %). A game run lifts it to 150–170 %, so almost every run trips the
    rule, on both sides alike.
  - Every one of the 12 counted runs ended with load 8.8–10.9 (≤ 15) and had fatal 0, gpu_err 0
    and watchdog 0. The summary over all 12 under the load rule (SUMMARY_ONLY=1, N=6;
    ab_p1_summary_load15.txt):

| run | fps | skipped | load | run | fps | skipped | load |
|---|---|---|---|---|---|---|---|
| A1 | 82.9 | 27189 | 10.0 | B1 | 82.3 | 28581 | 10.8 |
| A2 | 83.9 | 26964 | 9.8 | B2 | 83.3 | 26930 | 9.7 |
| A3 | 83.6 | 27046 | 9.0 | B3 | 84.0 | 26922 | 9.7 |
| A4 | 84.2 | 26886 | 10.8 | B4 | 84.0 | 27640 | 10.9 |
| A5 | 84.3 | 27297 | 8.8 | B5 | 83.7 | 27425 | 10.3 |
| A6 | 84.0 | 28001 | 9.6 | B6 | 83.4 | 27192 | 10.8 |

  - Medians: A 84.0 fps, B 83.5 fps. A spread 82.9–84.3.
  - |B − A| = 0.5 ≤ max(1.0, 1.4): within noise. B's median of 83.5 also lies inside the
    Phase 0 A/A spread (83.1–83.8).
  - Encoder ms 11.5 / 11.6, CP ms 7.6 / 7.6.
  - Skipped draws (cumulative per run): median A 27118, median B 27308. B is 0.7 % higher, but
    that is inside A's own range of 26886–28001 and the Phase 0 A/A range of 26563–28059.
  - Logs: metal4_research/runs/p1_ab_*.log. Script output: ab_p1.txt and ab_p1.err.
- Host suite green (host=0, 90 PASS, 0 FAIL; metal4_research/host_p1.log).
- Go: go vet clean, go test ./pkg/... clean. gofmt -l lists six files, none of them changed by
  this plan: they are the same at 3f6c0cc. They are pkg/analyzer/analyzer_test.go,
  pkg/disasm/bounds_test.go, pkg/disasm/bytedispatch_test.go, pkg/elfloader/modules_test.go,
  pkg/elfloader/nid.go and pkg/elfloader/nid_test.go.

## Phase 2 (Metal 4 queue, command buffers, clears, present), commit 9de2fdf

Measured on a `git archive 9de2fdf` tree.

- Host suite green (host=0, 108 PASS, 0 FAIL). gnm_backend_present_test is equal on metal3 and
  metal4 (two PASS lines). gnm_crash_exit_test passes on both backends.
- TLOU, PS4_GNM_METAL=4 PS4_GNM_MTL4_ONLY_CLEARS=1, 300 s (exclusive lock): 18601 flips,
  fatal 0, gpu_err 0, watchdog 0, 63.8 fps (encoder 14.0 ms, CP 13.5 ms per frame).
  - Allocators: 5 throughout. One stats line per 300 frames, 62 lines.
  - Frame 1500 (line 5): 19962 KiB allocator memory, resident 43 (176 MiB, 41 textures).
  - Steps after frame 1500, all in frames 1800–3900:
    - line 6: allocator memory 20346 KiB;
    - line 7: resident 44 (184 MiB, 42 textures);
    - line 12: allocator memory 20442 KiB, resident 47 (186 MiB, 45 textures);
    - line 13: allocator memory 20634 KiB.
  - From frame 3900 to the end (frame 18600, 14700 frames): constant, at 20634 KiB and resident 47
    (186 MiB, 45 textures).
  - The 2eacdfe build showed the same shape: steps through line 13, then constant at 20346 KiB
    and 186 MiB.
- Metal 3 A/B vs Phase 0 (tlou_build_p0 vs tlou_build_p2, both Metal 3, 300 s, alternating
  A1 B1 ... A6 B6 after one warm-up per side):
  - The script's other-process rule kept 0 / 1 runs (miscalibrated, ruled for 6.2).
  - Under the load ≤ 15 rule, B1 is dropped (load 24.6).
  - A5 and B6 are dropped, because each had one command buffer "Discarded (victim of GPU
    error/recovery)" (InnocentVictim): a GPU fault of another process, one on each side, the
    Phase 0 build included.
  - Kept: A1–A4 and A6 (82.1–83.5), B2–B5 (82.2–82.9). Medians 83.1 / 82.8 fps: |B − A| = 0.3
    ≤ max(1.0, 1.4), within noise.
  - Encoder 11.6 / 11.8 ms, CP 7.6 / 7.6 ms. The kept runs have fatal 0, gpu_err 0 and
    watchdog 0.
- U4 smoke on Metal 4 (clears only, 120 s, empty data dir, scratch cache):
  `fps 48.9 enc_ms 3.4 cp_ms 7.9 commits 6.6 split 0.0 skipped 808793 fatal 0 gpu_err 0
  watchdog 0 flips 5101 load 8.5 asserts 0`.
  - The frames are black (draws skipped), so reaching the title screen is not visible.
  - The run presented to frame 5100 at 1920x1080 with no crash or hang, and WindowServer RSS
    stayed flat.
  - Metal 4 at the end: allocators 6 (30752 KiB), resident 70 (315 MiB, 68 textures).
- Go: go vet, gofmt -l and go test ./pkg/... clean (go=0).

## Phase 3 (compute), commit f735f33

Measured on a `git archive f735f33` tree.

- Replay, Metal 3 vs Phase 0 (all passes):
  - courtyard: same 570 passes, 571 outputs; different 0; missing 0.
  - spores: same 267 / 267; different 0; missing 0.
- Replay, Metal 4 (PS4_GNM_MTL4_ONLY_CLEARS=1) vs Metal 3, dispatch passes:
  - courtyard: same 509 passes, 510 outputs; different 0; missing 0. 521 dispatch passes, of
    which 509 are replayed on both backends; the same 12 are not replayable on either.
  - spores: same 1 pass, 1 output; different 0; missing 0. 4 dispatch passes, of which 1 is
    replayable; most of the spores set is draws over the raw capture budget.
- Host suite green (host=0, 115 PASS, 0 FAIL):
  - gcn_wave_exec_test: PASS on metal3 and metal4.
  - gnm_guest_memory_test: PASS in every mode (fast, default, hang-cp, hang-throttle,
    hang-fast-throttle) on Metal 3, and on Metal 4 with ONLY_CLEARS.
  - gnm_residency_test: PASS, its negative control included (a window in no residency set gets
    0 of 4096 dwords).
- Residency completeness on read paths is unverified until the bind-time
  PS4_GNM_RESIDENCY_CHECK of Task 5.1 lands. That check is moved forward, before draws are
  enabled.
- TLOU, PS4_GNM_METAL=4 PS4_GNM_MTL4_ONLY_CLEARS=1, 300 s (exclusive lock; dispatches, DMA and
  GPU uploads on Metal 4):
  `fps 93.4 enc_ms 4.2 cp_ms 7.0 commits 42.7 split 0.0 skipped 541517 fatal 0 gpu_err 0
  watchdog 0 flips 27301 load 11.2 asserts 0`.
  - Allocator memory, one stats line per 300 frames, 91 lines:
    - menu (lines 1–13): 14–15 allocators, 66058–73648 KiB;
    - gameplay start (lines 14–16, frames 4200–4800, dispatches per frame 140 → 1600, commits
      per frame 11.7 → 49.3): 22 → 46 → 52 allocators, 105845 → 424725 KiB;
    - lines 17–46: 52 allocators, creeping 431317 → 440085 KiB;
    - line 46 (frame 13800) to the end (frame 27300): flat at **52 allocators, 440085 KiB
      (about 430 MiB)**.
    - Phase 2 (clears only, no dispatches): 5 allocators, 20634 KiB.
  - Resident at the end: 136 (2207 MiB, 78 textures); the peak is 142 (2782 MiB).
  - WindowServer RSS 56 → 85 MB.
- Metal 3 A/B vs Phase 0 (tlou_build_p0 vs tlou_build_p3, 300 s, alternating, load ≤ 15
  rule; A2 dropped at load 20.8):
  - Kept: A1, A3–A6 (83.1–86.9) and B1–B6 (82.3–85.5).
  - Medians 83.6 / 82.9 fps: |B − A| = 0.7 ≤ max(1.0, 3.8), within noise.
  - Encoder 11.5 / 11.7 ms, CP 7.6 / 7.6 ms; fatal, gpu_err and watchdog 0 in every run.
  - B is below A in 4 of 5 pairs.
- U4 smoke on Metal 4 (clears only, 120 s, empty data dir):
  `fps 31.2 enc_ms 10.7 cp_ms 12.4 commits 10.4 split 0.0 skipped 5357 fatal 0 gpu_err 0
  watchdog 0 flips 3301 load 10.2 asserts 0`.
  - At the end: allocators 9 (61904 KiB), resident 435 (2854 MiB, 369 textures).
  - No crash or hang. The frames are black (draws skipped).
- Go: go vet, gofmt and go test ./pkg/... clean (go=0).


## Phase 4 (graphics on Metal 4), commit f267bba (gate passed; flags: flaky 5.4 churn test, Metal 3 encoder +0.2 ms)

Replay and host tree from `git archive f267bba`. TLOU build tlou_build_m4to (game code
identical to f267bba, with the 5.4 allocator trim).

- **Replay:** every pass of both frames is byte-identical. Metal 3 vs Phase 0, Metal 4 (with
  PS4_GNM_RESIDENCY_CHECK=1) vs Metal 3, and Metal 4 vs Phase 0 all give courtyard 570 passes /
  571 outputs and spores 267 / 267, with `different: 0; missing: 0`. 0 residency asserts. No
  known differences.
- **TLOU, Metal 4 with draws and the residency check, 300 s, exclusive:**
  - m4a: 66.1 fps, flips 21001, fatal, gpu_err and watchdog 0, res_assert 0.
  - m4b: 58.9 fps, flips 19201, same zeros.
  - The gate's first run (at 026145d) hit two MTL4CommandQueueErrorTimeout command buffers in
    the menu, an intermittent GPU event seen once (m4-timeout-analysis.md).
- **Allocator memory, Metal 4 with draws** (the first 5.4 trim, 5c49437, is in this build):
  - m4a: 49 allocators, 315589–317413 KiB, with no creations or releases in steady state;
  - m4b: 45–46 allocators, 186864–191845 KiB, with about 650 creations and releases per
    300 frames.
  - These two regimes, and the flaky churn check below, belong to the first trim. The final trim
    (c6676b6 + 8ff6133) runs 53 allocators at 113–116 MiB, flat, in two 300 s routes.
- **Screenshots by time** (8a33e89, PS4_SCREENSHOT_EVERY_SEC=20, 300 s; 2 Metal 3 runs and 2
  Metal 4 runs with the residency check; `--dirs --baseline --require-all`, 16 of 16 seconds
  paired):
  - t = 0 and 20 s: identical on all four runs.
  - t = 40–300 s (gameplay): Metal 3 run to run differs by 71–98 % of pixels, max channel diff
    103–163. Metal 4 vs Metal 3 differs by the same share. Over the per-second Metal 3 maximum
    there are 0 pixels at most seconds, and at most 1–36 pixels at a few. The control (Metal 3
    vs Metal 3 judged by the Metal 4 pair) also has 1–6 pixels over.
  - Named effect: camera position and sway (an edge shift on high-contrast detail; m4b at 100 s
    is the wall-mounted security camera), plus NPC and animation positions.
  - First flips 1.842–1.907 s after start in all runs, with no backend offset.
  - The two Metal 4 runs: p4c_shots_m4a 63.3 fps, p4c_shots_m4b 62.9 fps, both with 0 errors
    and 0 residency asserts.
  - Result: within Metal 3 noise.
  - The earlier frame-indexed comparison was not decidable, because Metal 4's lower frame rate
    reached the time-paced intro at other frames; it is superseded.
- **Skipped draws:**
  - Metal 4 25041–25110 vs Metal 3 29055–29088 (same build, 300 s; 1.085 vs 1.088 per frame).
  - This build's Metal 3, 29062–29073, is ≤ the Phase 0 build's in the same session
    (29363–32057; this session runs at about 87 fps).
- **Metal 3 A/B vs Phase 0** (300 s, alternating):
  - The script kept A1, A3, A4 / B2, B3, B5: medians 87.7 / 86.6, −1.1 (noise ±1.0), encoder
    11.0 / 11.2 ms.
  - Under the load rule, without the cold-cache B1: 87.6 / 86.7, −0.9, within noise.
  - Encoder ms has been +0.2 over Phase 0 since Phase 2.
- **Metal 4 vs Metal 3** (same build, no residency check, 3 runs each): 73.3 / 86.5 fps,
  encoder 13.2 / 11.3 ms, CP 7.2 / 7.3 ms. Recorded; the decision is 6.2's.
- **U4 on Metal 4 with draws, 120 s:** `fps 20.7 enc_ms 52.0 cp_ms 52.2 commits 9.8 skipped
  8890 fatal 0 gpu_err 0 watchdog 0 flips 1801`. It reaches the first-boot settings screen,
  rendered correctly; res_assert 0.
- **Host suite:** host=0, 126 PASS, on the second run. The first run failed on the flaky 5.4
  churn check in gnm_backend_cmd_test (2/5 standalone).
- **Go:** go vet, gofmt and go test clean.

## Phase 5 (residency hardening), commit 7995846 (gate passed)

Game builds and the host tree are from `git archive d1e4552` (TLOU tlou_build_p5, U4 u4_build_p5).
The gate found one problem, in the residency check itself, fixed by 7995846:
- the bind-time check took a view's `parentTexture` as its base;
- a view of a view has the inner view there, which is in no set, so the check reported it although
  its root was resident;
- U4's title binds such views.
- The U4 smoke and the host suite were rerun at 7995846.
- The fix only changes the check's lookup, so the TLOU runs at d1e4552, which had 0 asserts, stand.

Every game run used `tools/metal4_route.sh` under heavy_lock with HEAVY_EXCLUSIVE=1, with scratch
data and cache directories. The saves were copied in (DATASRC). Load at the stops was 6.8–11.0.

- **TLOU, Metal 4 with PS4_GNM_RESIDENCY_CHECK=1:** six 300 s runs, 30 minutes, alternating the
  saves.

| run | save | window release | fps | flips | fatal / gpu_err / watchdog | asserts | last res_assert | windows released |
|---|---|---|---|---|---|---|---|---|
| p5_check1 | data_ch1 | default | 78.5 | 24301 | 0 / 0 / 0 | 0 | 0 | idle, (x16) |
| p5_check2 | data_user1441 | default | 75.1 | 22801 | 0 / 0 / 0 | 0 | 0 | idle, (x16) |
| p5_check3 | data_ch1 | default | 78.0 | 24001 | 0 / 0 / 0 | 0 | 0 | idle, (x16) |
| p5_check4 | data_user1441 | IDLE_S=1, BUDGET_MB=2048 | 76.8 | 23701 | 0 / 0 / 0 | 0 | 0 | over budget, (x64) |
| p5_check5 | data_ch1 | IDLE_S=1, BUDGET_MB=2048 | 77.3 | 24001 | 0 / 0 / 0 | 0 | 0 | over budget, (x256) |
| p5_check6 | data_user1441 | IDLE_S=1, BUDGET_MB=2048 | 77.3 | 24001 | 0 / 0 / 0 | 0 | 0 | over budget, (x64) |

  - The knobs bite: in runs 4–6 the `released ... guest window buffers` line reaches the over-budget
    sweep, with rate-limit counts of 64–256, against at most 16 idle releases in runs 1–3.
  - No gpuEvent .ips report in any run.
  - At the end, the residency sets hold 1067–1072 allocations (3888–3896 MiB) on data_ch1 and
    411–768 (1853–2477 MiB) on data_user1441.
- **Window sweep/remap stress:**
  - host tests guest_window_test and gnm_guest_memory_test, all six modes on both backends, the
    remap mode included;
  - they pass in both host suite runs.
- **Memory, Metal 3 against Metal 4** (same build, default save, 300 s): the charged total is
  2706 MiB on both, +0.0% (limit 10%).
  - Device memory 3922 MiB on both, with no-copy 3008 MiB.
  - Footprint: 3270 against 3345 MiB (+2.3%).
  - Wired: 5686 against 5394 MiB.
  - Peak charged: 3413 against 3341 MiB.
  - Metal 4 at the end: 13 allocators (85829 KiB); residency sets 1061 allocations (3883 MiB, 964
    textures).
- **Metal 3 A/B against Phase 0** (tlou_build_p0 against tlou_build_p5, N=3, 300 s, alternating, no
  pair dropped):
  - fps 85.6 against 97.9 (+12.3, noise ±1.8);
  - encoder 11.2 against 8.2 ms (−3.0);
  - CP 7.4 against 7.1 ms;
  - verdict B ≥ A.
  - The gain is the batched compute commits (1c4db33): commits per frame went from 48.8 to 9.1.
- **U4 on Metal 4 with PS4_GNM_RESIDENCY_CHECK=1** (120 s, empty data dir):
  - at d1e4552: `fps 23.0 enc_ms 35.5 cp_ms 35.4 commits 10.1 ... fatal 0 gpu_err 0 watchdog 0
    flips 2401`, with **979 asserts**;
    - all of them are `bind texture` of 256x256 R8Unorm 2D-array views;
    - a diagnostic build showed each one is a view of a view whose root is in the Texture set;
  - at 7995846: the same numbers, 0 asserts, `res_assert=0`.
  - It reaches the first-boot settings screen.
- **Host suite:** host=0 at d1e4552 and at the fix (140 PASS lines each).
  - gnm_residency_test covers a view of a view of a resident texture (0 asserts) and of a
    non-resident one (1).
  - With the one-level lookup it fails.
- **Go:** go vet, gofmt and go test clean (go=0).

## Phase 6: performance, Metal 4 against Metal 3, commit 8bdffe7

TLOU game build tlou_build_p6 (`git archive 8bdffe7`), one build on both backends.
`tools/metal4_perf_ab.sh` ran with N=5, 300 s, alternating A (Metal 3) and B (Metal 4), under
HEAVY_EXCLUSIVE, with no screenshots (EVERY=0) and scratch data and cache directories.
- The load was 6.9 before the start.
- At the run stops the load was 7.6–14.6, so no run was over 15, and none was dropped (5 + 5 kept).
- other_cpu medians were 48–57.
- fatal, gpu_err and watchdog were 0 in every run.

| | Metal 3 (A) | Metal 4 (B) | B − A |
|---|---|---|---|
| fps, median (range) | 98.9 (98.2..99.4) | 85.5 (85.3..87.0) | **−13.4** (noise ±1.3) |
| encoder ms, median | 8.1 (8.0..8.1) | 7.8 (7.8..7.9) | −0.3 (noise ±0.1) |
| CP ms, median | 7.1 (7.0..7.1) | 7.0 (7.0..7.1) | −0.0 (noise ±0.1) |
| footprint, last `[gnm-mem]` (MiB) | 3391..3400 | 3421..3457 | about +1% |

**Verdict: Metal 4 < Metal 3.** Its fps is lower beyond the noise. Encoder and CP ms are lower or
equal, so those two measures pass the rule.

**Where the loss is:** the `[gnm-draw] perf:` breakdown, as medians over the runs of each run's mean
after its first 13 perf lines:

| per frame | Metal 3 | Metal 4 |
|---|---|---|
| commits | 9.08 | 9.10 |
| waits / ms waiting | 0.00 / 0.00 | 0.00 / 0.00 |
| ms GPU busy | 9.31 (per run 9.3..9.4) | 11.39 (11.2..11.4) |
| ms CP (CPU) | 7.07 | 7.05 |
| ms encoder (wall) / encoder CPU | 8.10 / 8.00 | 7.79 / 7.71 |
| blocked: throttle / in-flight / opening | 0.00 / 0.00 / 0.10 | 0.00 / 0.00 / 0.10 |

The loss is on the GPU, not in encoding or waiting:
- Metal 4 spends 2.1 ms more GPU time per frame.
- Its frame, 11.7 ms at 85.5 fps, is about its GPU busy time.
- Metal 3's frame is 10.1 ms with 9.3 ms of GPU busy.

The measured reasons (docs/gnm-ordering.md, docs/compute-batching.md):
- **The barrier at every Metal 4 encoder start.** It orders each encoder after all earlier work.
  - Removing all of them took TLOU's GPU busy from about 13 to 8.6–9.3 ms per frame (before 1c4db33).
  - Per-encoder fences with narrowed stages save 0.9–1.2 ms of GPU per frame, but cost 2.3–2.8 ms
    of encoder CPU. TLOU is then encoder-bound, so fps does not change.
- **Batched compute commits (1c4db33)** cut commits from 49 to 9 per frame on both backends.
  - On Metal 4 GPU busy went from 12.8 to 11.6 ms and fps rose by about 10.
  - Metal 3 gained as much. There, a batched command buffer runs alongside the next one: 72% of seqs
    overlap the previous one, against 0% on Metal 4, whose seqs stay strictly serial.
- So Metal 3's hazard tracking still lets the GPU overlap work that Metal 4's start barriers
  serialise. That is the remaining gap.

## Phase 6: gate, commit 7662b58

Host tree, replay tool and game builds come from `git archive 7662b58`: TLOU tlou_build_final, U4
u4_build_final. Builds and runs went through heavy_lock (routes and A/Bs HEAVY_EXCLUSIVE), with
scratch data and cache directories.

- **Checks:**
  - no `NotYet` or "not implemented yet" in ps4_gnm_backend_metal4.mm;
  - no `M3Legacy` or `Legacy` in the renderer sources;
  - 106 commits in `main..metal4-backend`.
- **Host suite:** host=0, 144 PASS lines. Both backends run in it.
- **Go:** go vet, gofmt and go test clean (go=0).
- **Replay against Phase 4** (p4_m3 hash lists, `gnm_replay <frame> all --sha`):

| frame | Metal 3 | Metal 4 (PS4_GNM_RESIDENCY_CHECK=1) |
|---|---|---|
| courtyard | 570 passes, 571 outputs, different 0, missing 0 | the same; 0 residency asserts |
| spores | 267 passes, 267 outputs, different 0, missing 0 | the same; 0 residency asserts |

  None of the known Metal 4 ordering differences (docs/metal4-backend.md, "Metal 4 ordering
  differences") shows on these two frames.
- **Performance A/B** (the Phase 6 section above, tlou_build_p6 from 8bdffe7): Metal 3 98.9 fps,
  Metal 4 85.5 fps (−13.4, noise ±1.3), encoder 8.1 against 7.8 ms, CP 7.1 against 7.0 ms.
  - **Verdict: Metal 4 < Metal 3**, in fps. The loss is GPU busy time: 9.3 against 11.4 ms per
    frame.
- **Cost of the texture keep list on Metal 4** (ad3cde5, which keeps the textures an encoder used
  until its seq completes):
  - tlou_build_p6 (before it) against tlou_build_final, both Metal 4, N=3, 180 s, EVERY=0, all
    pairs kept;
  - fps 85.7 against 85.5 (−0.1, noise ±1.1);
  - encoder 8.1 against 8.2 ms (+0.1, noise ±0.2);
  - CP 7.5 against 7.5 ms.
  - Within noise on every measure. (The tool prints B<A because its fps check is a strict ≥ of the
    medians.)
- **Default:** Metal 3 (`DefaultPrefersMetal4()` returns false; docs/metal4-backend.md,
  "Selection"). With PS4_GNM_METAL unset, the final U4 build and the 6.3 TLOU route both log
  `backend metal3 (default (Metal 3))`.
- **Why Metal 4 is not the default: the start-barrier serialisation** (docs/gnm-ordering.md,
  "Metal 4: barriers at encoder starts"; docs/compute-batching.md):
  - every Metal 4 encoder begins with a barrier after all queue stages, so its seqs never overlap
    on the GPU, while Metal 3's hazard tracking lets a command buffer run alongside the next one;
  - the narrower models measured did not pay. An object tracker could skip at most about 4% of the
    start barriers. A sound per-encoder fence model saved about 1 ms of GPU per TLOU frame and cost
    2–3 ms of encoder CPU.
- **Live smoke of the final build:**
  - TLOU, 300 s, PS4_SCREENSHOT_EVERY_SEC=20:
    - Metal 3: 97.8 fps, flips 30001;
    - Metal 4 with PS4_GNM_RESIDENCY_CHECK=1: 77.5 fps, flips 24001, `res_assert=0` throughout.
  - U4, 120 s, empty data dir:
    - the default backend (Metal 3): 25.2 fps, flips 2401;
    - Metal 4 with the residency check: 23.1 fps, flips 2401, `res_assert=0`.
  - All four runs: fatal, gpu_err and watchdog 0, and no gpuEvent report.
- **Screenshots of the live smoke:**
  - TLOU, Metal 3 against Metal 4: seconds 0 and 20 identical. From 40 s, 70–98% of the pixels
    differ, as between two Metal 3 runs (Phase 4: 71–98%), from animation and camera phase.
  - U4: all six seconds identical between the backends (the first-boot settings screen).
  - Every TLOU second of both backends was opened by eye. There is no corruption:
    - the same scenes, lighting and textures;
    - Metal 4's 40 s frame is the scene's dark first frames after the load, which the Metal 4
      routes of both the batched and the pre-batching build show.
- **Parked review items** (not blocking; from the whole-branch review):
  - m1: the capability scaffolding (`BackendHas`, PS4_GNM_MTL4_ONLY_CLEARS) is kept as a documented
    debug bisect mode;
  - m3: allocations per commit in `Metal4Backend::Submit` (a seq map node, commit options and a
    block): a small fraction of 0.18 ms per frame;
  - m6: the legacy present wrappers, used only by a host test;
  - m7: a quit after a GPU watchdog give-up waits 10 s and aborts. Changing the exit contract is
    the owner's decision;
  - m8: recycling and residency retirement run only when a part is acquired. This costs memory
    only, at idle;
  - n3: the keeps in `CopyTextureRegion`, `CopyBufferToTexture` and the resolve, depth and stencil
    attachments have no test of their own (the same call as the tested cases).
- The branch stays local, with no push. Merging into main is the owner's decision.
