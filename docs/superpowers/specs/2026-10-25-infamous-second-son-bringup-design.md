# inFAMOUS Second Son (CUSA00004 v01.00) bring-up — design

Date: 2026-10-25. Branch `infamous-bringup` from main dd4437b (worktree `PS4Recomp-infamous`).
The Last of Us Remastered plays on this code at about 99 fps (Metal 3). Uncharted 4 reaches
gameplay. This spec takes a third game to the TLOU bar with the same method.

## Goal

Single-player inFAMOUS Second Son (`eboot.bin` v01.00) is playable on an M1 Pro Mac, to the TLOU
bar:

- a new game runs through the prologue and the first missions in open-world Seattle;
- movies play, and music, speech and effects are audible;
- saves are written and load back;
- 30+ fps at 1920x1080 in base mode (`PS4_PRO=0`); v01.00 has no PS4 Pro mode;
- the image has no obvious artefacts against PS4 reference footage of the same scenes;
- a 30-minute soak has no fatal error and no hang;
- quitting works.

Out of scope: PSN features (Np stays signed out; trophies behave as they do for TLOU),
photo mode sharing, PS4 Pro mode, and any game other than this version.

## Starting point

Evidence: `~/ps4recomp-work/infamous_research/infamous-boot-recon.md`, `analyze.log`,
`gen_probe.log`, `build_probe/hle_report.txt` and `runs/r1/`.

- **The build already works unchanged.** The eboot and modules are fSELF, the same as TLOU and U4.
  - Generation finds 35,336 functions; the emitted assembly has no `UNSUPPORTED` instruction.
    441 files take 15.6 s.
  - The clang build takes 52 s and links.
  - `sce_module/` holds the same two game PRX as TLOU: `libc.prx` and `libSceFios2.prx`.
- **Imports.** 1,272 unique. Only 5 are unresolved, each bound to the abort stub, which names it if
  it is called:
  - `sceNpSetNpTitleId` and `sceNpRegisterGamePresenceCallbackA` (libSceNpManager);
  - `scePlayGoSetToDoList` (libScePlayGo);
  - `sigfillset` and `sigreturn` (exported under the libSceSysmodule NID library).
- **The first launch stops after 6 s, before any frame.**
  - The game's own malloc replacement (`SceLibcMallocReplace.init`) maps 1152 MB of direct memory
    with no fixed address. We place it at 0x8270000, right after libc.prx.
  - libc.prx code then dereferences a non-canonical value (0x5ec0000000000008) next to that mapping.
  - Whether the cause is the mapping's address, its contents or a lifted instruction is not known
    yet.
- **The data.** 26 GB in `art/` (`cache`, `movies`, `ui`); PlayGo files (`playgo.pgm`,
  `playgo-chunk.dat`) sit next to the eboot.

## Approach

The bring-up method that worked for TLOU and Uncharted 4: run, find the first failure, find its
root cause, fix it there with a test, repeat. Work is ordered by what gates progress. Each phase
ends with a gate (see Acceptance per phase).

All fixes are correct console behaviour for any game, never a path for one title (AGENTS.md: the
project does not fit one binary). New HLE functions are real implementations:

- **Real behaviour** where the game needs it.
- **The console's error code** where the feature is absent offline.
- **A documented no-op** only where the console itself does nothing observable.

Tools, used in this order of preference:

- **Logs, the stall watchdog and the crash report.** The guest RIP, the registers, the guest stack
  and the code addresses on it.
- **`cmd/lifter-difftest-asm`.** The differential harness for a suspected lifter bug: the guest
  function run on our lifted code against a reference x86 execution.
- **Frame capture, `gnm_replay`, the pass overview and the reference comparison.** For every
  rendering problem: localise the first wrong pass, then fix the translator or renderer.
- **The PC port github.com/HayatoG/iss_pc** (x86-64 Linux/Windows, CUSA00223 v1.07, no license).
  It is a source of facts about what the game needs; its code is never copied. Notes:
  `~/ps4recomp-work/infamous_research/iss_pc_notes/FINDINGS.md`.
  - Our v01.00 code matches 1.07 where checked: the 13 F16C sites at 0x612da8–0x61300e are at the
    same addresses.
  - Its findings that shape this plan:
    - new threads inherit the creator's MXCSR (FTZ), or fire, smoke and headlights break;
    - 96 SSE4A sites;
    - occlusion counts (ZPASS_DONE pairs) size light flares;
    - GPU readbacks are needed for particles;
    - compute copies of render-target memory are sampled in another format.
- **REA, only for targeted questions** about what the game's own code does: a crash or hang inside
  it, a CPU hot spot, an HLE call used in an unexpected way, or shader input data a capture cannot
  explain. No broad reverse engineering of the binary.

### Phase 1: boot on the CPU side

1. **The malloc-replacement crash.**
   - Find out what libc.prx expects from `sceKernelMapDirectMemory(addr=0)`: the address range a
     PS4 returns, the alignment, and the initial contents.
   - Find out what it reads at the fault.
   - Fix the root cause: the VM placement policy, direct memory semantics or the lifter, with a test.
   - A change of the placement policy must keep TLOU and U4 working, since their allocators run on
     it too.
2. **The 5 unresolved imports.**
   - `sigfillset`: the POSIX function.
   - `sigreturn`: whatever the game uses it for; first find out whether it is reached.
   - `sceNpSetNpTitleId` and `sceNpRegisterGamePresenceCallbackA`: real Np behaviour for a
     signed-out user.
   - `scePlayGoSetToDoList`: PlayGo, with every chunk reported as installed.
   - Each one is implemented only when its behaviour on a console is known; a host test where it
     is testable.
3. **Then the loop**: each next crash, hang or missing import up to the first presented frame.

Gate 1: the game runs 120 s without a fatal error, with every reached import implemented.

### Phase 2: first frame, menus

- VideoOut and GNM bring-up for this game's command streams.
- Its shaders through gcn-recompiler; translation gaps are counted and logged. This covers:
  - the shader cache;
  - file I/O of the `art/` archives (sizes, reads above 4 GiB if any);
  - SaveData, UserService, SystemService;
  - Np signed out.
- The title and main menu appear, and the menus respond to the pad.

Gate 2: the main menu renders and is navigable; a save directory is created in the test data dir.

### Phase 3: movies, audio, new game

- The movie path the game uses (Videodec, Vdecsw or its own decoder) and its audio (Ajm codecs,
  AudioOut, Audio3d if used).
- A new game from the menu runs through the prologue's first minutes.

Gate 3: the intro movie plays with sound; the prologue is controllable; a save is written and
loads back.

### Phase 4: graphics fidelity

- Compare scenes of the prologue and the first Seattle district with PS4 reference footage.
- For each difference: capture, replay and compare passes to localise it, then fix the translator
  or the renderer.
- Gaps that this game's shaders hit (wave64 predication, T# tables, guest memory dispatches) use the
  mechanisms built for Uncharted 4. They are extended where the game needs it, never special-cased.

Gate 4: the reference scenes have no obvious artefact (lighting, shadows, particles, UI).

### Phase 5: performance and stability

- A fixed scripted route in the first open-world district, in the style of `tools/metal4_route.sh`,
  with alternating A/B runs for every performance change.
- CPU profiles of the hot guest functions, and the GPU breakdown from the renderer's perf lines.
- The memory footprint is measured early: 1152 MB of direct memory is mapped at boot.
- A 30-minute soak, then exit tests.

Gate 5 is the Acceptance list below.

The plan details Phase 1 fully. Phases 2–5 have their gates and methods. Their tasks are written
when the previous gate's findings are known, recorded in the plan's ledger as rulings, as was done
for Uncharted 4 (Tasks 2.x appeared as the work went).

## Constraints

- English in the repository; no fake tests, no stubs that return 0, no game-specific code paths.
- Every change is checked with `go vet`, `gofmt` and `go test` (Go), and the host test suite
  (runtime and renderer).
- Game data stays out of the repository: shader dumps, captures and memory snapshots of inFAMOUS
  are local fixtures (`tests/host/data/game/`) and tests skip without them.
- Automated runs:
  - use their own `PS4RECOMP_DATA_DIR` and cache dir;
  - never touch real saves or the owner's build folders (`tlou_build`, `u4_build`);
  - are time-bounded with the game killed by PID;
  - never start while the owner's game (`eboot`) runs.
- The inFAMOUS build lives in `~/ps4recomp-work/infamous_build`. The app dir is
  `<your-inFAMOUS-dump>/CUSA00004`.
- Memory budget:
  - one game at a time;
  - heavy jobs serialised with `tools/heavy_lock.sh`;
  - WindowServer's memory is watched during every run, which stops when it grows by more than
    300 MB (the U4 hang of 2026-10-20).
- No regression:
  - every runtime or lifter change re-runs a 120 s TLOU route (fatal 0, fps within noise of the
    last number);
  - every phase gate also runs a 120 s Uncharted 4 boot (fatal 0);
  - Metal 3 stays the default backend, and Metal 4 is checked at each phase gate.
- Downloads (reference footage, tools) are asked for first.

## Acceptance

- A new game reaches open-world Seattle. Its first missions play for 30 minutes with fatal 0 and
  no hang.
- The intro and story movies play; music, speech and effects are audible.
- A save is written and loads back after a restart.
- Average fps on the fixed route is at least 30 at 1920x1080, `PS4_PRO=0`, on Metal 3.
- The reference scenes show no obvious artefact against PS4 footage, checked by eye from
  time-matched screenshots.
- Exit through the close button and Cmd+Q works 3/3 each, with no crash report.
- TLOU still passes its route at fatal 0 within noise of its last fps, and Uncharted 4 still boots
  to its menu.
- `go test ./...`, `go vet`, `gofmt` and the host test suite pass.

## Risks

- **The malloc crash may be a lifter bug only this libc.prx path exposes.** It is TLOU's module
  name, but a different build of it. Until it is explained, later phases are estimates.
- **Open-world streaming** reads many large archives at once. File I/O and memory pressure on a
  16 GB Mac are likely bottlenecks; measure early.
- **Particle-heavy effects** (smoke, neon, the powers) run in compute shaders. Translator and
  renderer gaps there are likely, as with Uncharted 4.
- **The game's own movie or audio formats** may need a codec we do not have yet. Identify them from
  the first call before any design.
- **Reference footage** has to come from public recordings of the same scenes; downloads need the
  owner's consent.
