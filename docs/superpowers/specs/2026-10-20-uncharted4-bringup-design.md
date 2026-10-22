# Uncharted 4 (CUSA04529 v1.32) bring-up on the assembly backend — design

Date: 2026-10-20. Sub-project 2 of "Uncharted 4 playable like TLOU". Sub-project 1
(`2026-10-19-asm-backend-migration-design.md`) moved our runtime onto upstream's ARM64 assembly
backend and made TLOU play on it.

## Goal

Single-player Uncharted 4 (`eboot.bin`, SDK 0x04008061) is playable on an M1 Pro Mac, to the same bar as TLOU:

- campaign from a new game through the first chapters;
- sound and saves;
- 30+ fps;
- no fatal errors in a 30-minute soak.

Multiplayer (`big4-mp.elf`) and the PSN features are out of scope.

## Starting point (evidence: `~/ps4recomp-work/u4_research/u4-asm-boot-recon.md`, `u4-hle-gaps.md`)

- Generation and link work.
  - The duplicate `shim_sceKernelGetModuleInfo` is fixed.
  - Missing imports now abort with their name instead of spinning.
- **Where the game stops today.** With logging stand-ins for the 56 missing eboot imports (a throwaway copy, never in the repo), U4:
  - mounts every archive, initialises GNM, SaveData and Np (signed out);
  - presents about 700 black loading frames;
  - then stalls deterministically right after `Iggy auto-generated instance index high water = 0`.
- **What the stall looks like.** One NdJob worker probes an open-addressing hash table forever (`fn_0xe9330`). Five `Script load symbol failed` and fifteen `Duplicate symbol` errors come before it.
- **Missing imports.** Only 5 of them are reached before the stall. The 90 NpToolkit.prx imports are unreachable: the module is never started.

## Approach

The same bring-up method that worked for TLOU: run, find the first failure, fix its root cause with a test, repeat. The differential harness (`cmd/lifter-difftest-asm`) is the main tool for suspected lifter bugs.

All new HLE functions are real implementations, as AGENTS.md requires (no stubs):

- **Real behaviour** where the game needs it.
- **The console's error code** where the feature is absent offline, for example NpParty's NOT_IN_PARTY.
- **A documented no-op** only where the console itself does nothing observable, for example the GnmDriver toggle pair.

Work is ordered by what gates progress.

1. **Boot-path HLE:** the 23 small functions (recon §4). Each gets a host test where the behaviour is testable.
2. **The Iggy-time stall** (recon B2): find the table's owner and dump the table at the stall.
   - Explain the script-symbol errors.
   - Bisect with the harness: functions in the script loader and hash code that TLOU never ran.
   - The fix goes where the root cause is (lifter, runtime or I/O) and gets a test.
3. **First menu on screen** (B3):
   - present a compute-written display buffer;
   - fix the GCN translator errors (`flatten_extended_userdata_pass`: Failed to compute offset for SRT walker, ReadFirstLane/Phi);
   - find why ~45 draws and dispatches are skipped.
4. **Movies:** `libSceVdecsw` on VideoToolbox, sharing the H.264 core with our Videodec.
5. **`libSceAudiodec`:** first identify codec type 3 from its first call. If it is AAC, implement it on AudioToolbox.
6. **`libSceAudio3d`:** a mixer of objects and beds on top of an internal AudioOut API, paced by PortAdvance/PortPush.
7. **Gameplay:** new game, the first chapter, reads above 4 GiB in the large psarc files, and saves. Then perf and memory, the soak, and exit tests.

## Constraints

- English in the repo; no fake tests, no stubs.
- Automated runs:
  - use their own `PS4RECOMP_DATA_DIR`;
  - never touch real saves;
  - never touch `tlou_build/eboot.app` except a planned TLOU install.
- Memory budget: one game at a time; heavy jobs serialised with `tools/heavy_lock.sh`; memwatch running.
- TLOU must not regress. Every runtime or lifter change re-runs a 120 s TLOU courtyard check: fatal 0, gameplay frames.
- The U4 build lives in `~/ps4recomp-work/u4_build_asm`. The app dir is `<your-U4-dump>/CUSA04529`.

## Acceptance

- New game reaches gameplay. The first chapter can be played for 30 minutes with fatal 0.
- Movies play; music, speech and effects are audible.
- A save is written and loads back.
- Average fps is at least 30 at the default settings.
- Exit through the close button and Cmd+Q works 3/3 each, with no crash report.
- TLOU still passes its walk routes at fatal 0.
- `go test ./pkg/...` and the host tests pass.

## Risks

- **The stall may be a lifter bug only U4 code exposes.** Until it is explained, later milestones are estimates.
- **Memory:** 2.4 GB at the loading screen with about 5.7 GB of direct memory mapped lazily. Gameplay may push a 16 GB Mac into swap. Measure early.
- **Audiodec codec 3 is unidentified,** and there is no reference implementation.
- **U4 relies more on compute shaders than TLOU,** so renderer gaps there are likely.
