# Uncharted 4 Bring-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Single-player Uncharted 4 (CUSA04529 v1.32) plays on the ARM64 assembly backend to the TLOU bar.

**Architecture:** Bring-up loop on the existing runtime:
- real HLE implementations for missing imports;
- root-cause fixes in the lifter, runtime or renderer, each with a test;
- the differential harness for lifter suspects.

**Tech Stack:** Go (recompiler, lifter, emitter), C/Objective-C++ runtime, Metal renderer, VideoToolbox, AudioToolbox.

**Spec:** `docs/superpowers/specs/2026-10-20-uncharted4-bringup-design.md`

## Global Constraints

- Comments and docs in English. No fake tests, no stubs (AGENTS.md).
- Automated runs use a fresh copy in their own `PS4RECOMP_DATA_DIR`. Never real saves.
- Do not touch `~/ps4recomp-work/tlou_build`; the owner plays from it.
- One game process at a time. Every build, generation, harness or game run goes through `~/ps4recomp-work/tools/heavy_lock.sh`. `ninja -j6`. Kill leftovers. Report peak memory.
- Run `mount | grep ps4recomp-work` before builds and runs.
- Generate U4: `./ps4-recomp "/Volumes/ssd/Uncharted 4 v1.32 by MorpheusGames/CUSA04529/eboot.bin" --app-dir "/Volumes/ssd/Uncharted 4 v1.32 by MorpheusGames/CUSA04529" -o ../u4_build_asm -c`
- U4 runs:
  - env `PS4_RECOMP_HEADLESS=1 PS4_NO_DIALOGS=1 PS4_BACKGROUND_WINDOW=1 PS4_PAD_AUTOPRESS=4000`;
  - screenshots through `PS4_SCREENSHOT_DIR`/`PS4_SCREENSHOT_EVERY`;
  - fresh data dir `~/ps4recomp-work/u4_research/data_tmp`;
  - see `~/ps4recomp-work/u4_research/run.sh`.
- TLOU must not regress. After any lifter or runtime change, run 120 s on a copy of `data_ch1` with `tlou_build_asm`: fatal 0, gameplay frames.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- Acceptance is in the spec.

---

### Task 1: Boot-path HLE set (23 functions)
**Files:** the modules listed in recon §4: `libSceGnmDriver`, `libkernel` (`kernel/memory/ps4_direct_mem.c`, `kernel/sync/ps4_semaphore.c`), `libSceHttp`, `libSceCoredump` or `libSceNoopStubs`, `libSceRtc`, `libSceNet`, `libSceNetCtl`, `libSceNp*`. The shim table is in `pkg/emitter/shims.go` (or wherever upstream registers shims). Host tests go in `tests/host/`.
- [ ] For each function, implement the class recon §4 gives:
  - R: real behaviour;
  - E: the console's offline error code;
  - N: a documented no-op.

  Cite the evidence in a comment: a disassembled call-site check, shadPS4, or SDK documentation.
- [ ] Host tests:
  - `sceKernelBatchMap`: the map, unmap, mprotect and mtypeprotect ops, and the count of entries processed on partial failure;
  - `sem_timedwait`: a timeout returns ETIMEDOUT within tolerance, and a post wakes it;
  - Rtc formatting round-trips;
  - NpParty states.
- [ ] U4 runs further than the first missing import, to the Iggy stall (Task 2). Log the next unresolved abort, if any, and implement it here too when it is small.
- [ ] TLOU regression check. Commit per library.

### Task 2: Root-cause the Iggy-time stall
- [ ] Reproduce it. Identify the hash table's owner:
  - callers of `fn_0xeba30`;
  - globals written at `0xe937b`-`0xe93a4`;
  - the type byte 0x12 objects.
- [ ] Dump the table at the stall. Explain why the key is absent and why the probe never reaches an empty slot.
- [ ] Explain the `Script load symbol failed` and `ScriptManager::BindValue: Duplicate symbol` errors: which data was loaded, from which archive and offset, and what was expected.
- [ ] Bisect suspects:
  - run the harness over the script loader, hashing and RNG functions (`fn_0xe9540`, `fn_0x1f9b0`) and their callers;
  - compare I/O results for large archive offsets;
  - check memcpy/memmove shim edge cases.
- [ ] Fix the root cause with a test that fails without it. Add a ledger line per iteration. Commit.
- [ ] Stop condition: U4 renders past the loading phase, with no stall in 120 s.

### Task 3: First menu on screen
- [ ] **Present of compute-written display buffers.** Look at the PresentImpl fallback in `ps4_gnm_draw.mm` ("display buffer … is not a GPU target"). Track compute writes to a display buffer so the present uses the GPU image. Test: a renderer host test or a scripted capture showing a non-black frame where the game draws.
- [ ] **GCN translator errors** (`flatten_extended_userdata_pass`, ReadFirstLane/Phi SRT walker). Compare with current shadPS4 and port the fix with attribution. Test: the failing shader binary dumped from U4, used as a translator test.
- [ ] **Skipped draws and dispatches.** Get the reasons via `PS4_GNM_STATS`, then fix them.
- [ ] Stop condition: the title or main menu is visible in screenshots. Commit each fix. Run the TLOU regression check plus a TLOU screenshot comparison, since this is renderer work.

### Task 4: libSceVdecsw on VideoToolbox
- [ ] **Shared H.264 core.** Factor the VideoToolbox H.264 decode out of `libSceVideodec/ps4_videodec.c` into a shared core used by both modules. TLOU movies must still play.
- [ ] **The 13 Vdecsw functions:** the async in/out queues and the 0x78-byte picture-info trailer. Use the guest call sequence observed from U4 as the reference.
- [ ] **Tests:**
  - a host test decoding a short H.264 elementary stream through the Vdecsw API;
  - U4 intro logos or a cinematic visible in screenshots.
- [ ] Commit.

### Task 5: libSceAudiodec
- [ ] Log the first `sceAudiodecCreateDecoder` call: codec type and struct contents. Identify codec 3 from the stream header bytes.
- [ ] Implement it, for example AAC on AudioToolbox, with the documented structs. Test: a host test decoding a known stream to PCM, checking sample count and checksum tolerance.
- [ ] Commit.

### Task 6: libSceAudio3d
- [ ] **Internal C API on `libSceAudioOut`** (open port, push float frames, pacing) that Audio3d can use.
- [ ] **The 15 Audio3d functions:**
  - ports, objects and beds;
  - attributes (position and gain; spatialisation can start as a stereo or 7.1 downmix by position);
  - PortAdvance, PortPush and GetQueueLevel pacing.
- [ ] **Tests:**
  - host tests for queue levels and mixing of a bed plus an object;
  - U4 sound audible in a recorded run (non-silent output buffer statistics).
- [ ] Commit.

### Task 7: Gameplay, perf and soak
- [ ] **New game to the first playable chapter.** Script the pad if needed (`PS4_PAD_SCRIPT`).
  - Prove reads above 4 GiB in the big psarc files.
  - A save is written and loads back.
- [ ] **Perf.**
  - Average fps of at least 30 at default settings: Pro mode, or base mode if Pro cannot reach it (ruling).
  - Memory peak recorded; must stay below swap thrash on 16 GB.
- [ ] **30-minute soak** at fatal 0.
- [ ] **Exit tests:** 3/3 with the close button and 3/3 with Cmd+Q, no crash report.
- [ ] **TLOU regression:** both walk routes at fatal 0.
- [ ] **Install:** copy the U4 build into its own app bundle, `~/ps4recomp-work/u4_build/eboot.app`, by temp file + mv + codesign. Add a Russian how-to-run section to the ledger.
