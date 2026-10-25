# ps4-native-mac: play PS4 games natively on Apple Silicon Macs

ps4-native-mac lets you play your own PlayStation 4 games on a Mac with Apple Silicon (M1 or
later) as native macOS apps. It is an ahead-of-time (AOT) static recompiler: it translates a PS4
game's x86-64 executables (`eboot.bin` and the PRX modules shipped with the game) into a native
arm64 `.app`. The game code is lifted once, at build time, into ARM64 assembly. It then runs
against a high-level emulation (HLE) runtime of the Orbis OS libraries and a GNM command processor
that renders with Metal. There is no JIT, no interpreter, no Rosetta and no MoltenVK.

**The Last of Us Remastered** is playable on Mac from boot to gameplay, at about 99 fps in 1080p
on a scripted chapter 1 route on an M1 Pro. **Uncharted 4: A Thief's End** is in progress: it boots
and reaches gameplay in chapter 1 at about 20 fps, with visible rendering differences from a PS4
still open. See [Supported games](#supported-games-on-mac) for the exact status.

**Based on:** forked from [PS4Recomp](https://github.com/wie-project/PS4Recomp) by its authors, and
developed independently under the new name since 2026-10. License: GPL-2.0.

**Contents:** [What is this](#what-is-ps4-native-mac) ·
[Supported games](#supported-games-on-mac) · [Known issues](#known-issues) ·
[Requirements](#requirements) · [Quick start](#quick-start-run-a-ps4-game-on-your-mac) ·
[FAQ](#faq) · [Configuration and debugging](#configuration-and-debugging) ·
[How it works](#how-it-works) · [Legal notice](#legal-notice)

---

## What is ps4-native-mac?

- **A recompiler, not an emulator.** The game's CPU code is converted to Apple Silicon machine code
  before you play, so the Mac runs it directly instead of interpreting or JIT-translating x86 code
  while the game runs.
- **A PS4 system layer for macOS.** The PS4 system libraries the game calls (kernel, threads,
  audio, video, saves, pad, network) are reimplemented on top of macOS frameworks such as
  AudioToolbox, VideoToolbox and GameController.
- **A Metal renderer.** The game's GPU commands are processed by a GNM command processor that
  draws with Metal; its GCN shaders are translated to Metal Shading Language and cached on disk.
  Every build contains two renderer backends, Metal 3 (the default) and Metal 4
  (`PS4_GNM_METAL=4`).

Why this approach: native code with pinned registers, x86 memory ordering mapped onto ARM
acquire/release instructions and zero-copy guest memory on unified memory keep the run-time
overhead low. The cost is that each game is built separately, and every game needs its own
bring-up work.

---

## Supported games on Mac

Measured on an Apple M1 Pro (16 GB), macOS 27.0.1. Only measured numbers are listed; "TBD" means
not measured yet.

| Game | Stage | fps | Resolution | Notes |
| --- | --- | --- | --- | --- |
| The Last of Us Remastered (CUSA00557) | Playable: boot, menus, movies, gameplay, saves | Chapter 1 courtyard route (300 s, median of 5 runs): **98.9 fps** on Metal 3 (the default), 85.5 fps on Metal 4. Earlier walking and standing numbers: see below. | 1920x1080 (base PS4 mode, `PS4_PRO=0`), MetalFX off. Pro mode: TBD | 30-minute courtyard soak (commit 8145002): no fatal errors, no hangs, memory footprint flat at ~3.5 GB. Exit: 3/3 by closing the window, 3/3 by terminate, no crash reports. 300 s route on Metal 3 and on Metal 4: no fatal errors, GPU errors or watchdog reports. |
| Uncharted 4: A Thief's End (CUSA04529) | In progress: boots, menus, New Game, chapter 1 (boat cutscene and boat gameplay), saves, audio | Title screen about 21–22 fps, boat gameplay about 20–21 fps (`PS4_PRO=0`, 1080p, measured while other work ran on the machine). Pro mode: not re-measured (TBD) | 1920x1080 (`PS4_PRO=0`); 2560x1440 in Pro mode | Title screen: the scene is lit, but fog and light shafts are missing. Boat cutscene: Drake and Sully are lit and the motion-blur smear is fixed. Gameplay: water colour and foam differ from a PS4 and the sky is too dark. Base mode is recommended. |

How the TLOU numbers were taken:

- Route: `tools/metal4_route.sh` plays a scripted pad route from a copy of a chapter 1 save, with
  `PS4_PRO=0`, separate data and cache directories and no screenshots. `tools/metal4_perf_ab.sh`
  alternated 5 runs of 300 s per backend on one build (commit 8bdffe7) and kept only pairs taken
  under the same machine load. Noise between runs was ±1.3 fps. The full numbers are in
  [docs/metal4-baseline.md](docs/metal4-baseline.md).
- Batched compute commits (9 command buffers per frame instead of 49) raised this route from
  about 82 to 92 fps on Metal 3 in their own A/B
  ([docs/compute-batching.md](docs/compute-batching.md)).
- Earlier measurements, at commit 8145002, with a different route script, so not directly
  comparable: walking (330 s) chapter 1 courtyard 89.7 fps and spore corridor 99.6 fps, no frame
  over 100 ms; standing courtyard 78.5–78.9 fps and Sarah's house 113.7–114.5 fps.
- The frame rate is uncapped. The bench window is in the background, so vsync does not limit it.
  The machine's background load moves these numbers by a few fps between runs.

**Upstream milestones (not verified in this fork):**

- Hollow Knight: Silksong: upstream reported a boot into the Unity runtime with a Metal display.
- Hogwarts Legacy: upstream reported a boot up to a virtual address space allocation failure.

---

## Known issues

- **Uncharted 4.**
  - The title screen has no fog and no light shafts.
  - In gameplay the water colour and foam differ from a PS4, and the sky is too dark.
  - Red streaks seen in boat gameplay look like the game's own damage-direction indicator (a PS4
    video of the same scene shows them too); this is not confirmed.
  - Image descriptor (T#) tables that a shader indexes at run time are bound when a bound visible
    to the CPU gives at most 8 entries. Larger tables, and indices that only the GPU knows (for
    example in the reflection-probe culling shader), read a null image; each case is counted and
    logged once per shader.
  - Decals are not applied (CMASK is not emulated).
  - The shadow cube map is resolved from a 2D target ("texture type mismatch" in the log).
  - Frame rate is below a PS4's 30 fps: about 21–22 fps on the title screen and 20–21 fps in boat
    gameplay in base mode.
  - The faster guest-memory dispatch path (`PS4_GNM_GUEST_MEMORY_FAST=1`, about 3 fps more in boat gameplay) is
    opt-in: in long runs it showed rare anomalies (a stalled dispatch, a GPU memory blow-up, one
    crash) that the default path did not show, not yet explained.
- **Metal 4 is slower than Metal 3.** On the TLOU route it runs at 85.5 fps against 98.9. Each
  Metal 4 encoder starts with a barrier after all earlier work, so its command buffers never
  overlap on the GPU (11.4 against 9.3 ms of GPU time per frame). Metal 3 stays the default until
  Metal 4 at least matches it ([docs/metal4-backend.md](docs/metal4-backend.md),
  [docs/gnm-ordering.md](docs/gnm-ordering.md)).
- **Quit after a GPU hang.** If the command buffer watchdog gave up on the GPU, a normal quit waits
  10 s for the GPU and then stops with a FATAL message.
- **x87.** 80-bit values are kept as doubles, which loses 11 mantissa bits.
- **Misaligned atomics.** A LOCK operation on an operand that crosses a 16-byte boundary raises
  SIGBUS. TLOU has none.
- **NaN sign.** The sign of NaN results from invalid operations differs from x86 (ARM default NaN).
- **Unresolved imports.** Any import without an implementation is bound to a stub that stops the
  game with a log message naming the import. TLOU has 2, in `libSceGnmDriver`; it was never seen
  calling them.
- **Screenshot frames.** With screenshots on, the frames that capture one take ~130–150 ms.
- **Shader cache sharing.** The cache key is the game folder's name, so two games in folders with
  the same name share a cache.
- **Bundle ID.** Bundles get the ID `org.ps4recomp.<executable name>`, so every `eboot.app` has the
  same ID.
- **macOS metadata files.** On exFAT/FAT volumes, AppleDouble `._*` files next to the PRX modules
  produce harmless "Skipping module" messages.

---

## Requirements

| Requirement | Notes |
| --- | --- |
| Apple Silicon Mac | Developed and measured on M1 Pro, 16 GB. Code is built with `-mcpu=apple-m1`. |
| macOS | Tested on macOS 27.0.1. Building a game needs the macOS 26 SDK or later (Xcode or Command Line Tools 26+), because the Metal 4 backend is compiled into every build; the game is linked for the SDK of the Mac it is built on. The bundle declares 12.0 as its minimum, but older versions are untested (TBD). MetalFX upscaling needs macOS 13 or later. The Metal 4 backend also needs a GPU with `MTLGPUFamilyMetal4`. |
| Xcode Command Line Tools | `xcode-select --install`. gcn-recompiler needs Apple clang 17+ (C++23); tested with Apple clang 21. |
| Go | `go.mod` requires Go 1.27.1. An older `go` with `GOTOOLCHAIN=auto` (the default) downloads it. |
| CMake ≥ 3.20 and Ninja | `brew install cmake ninja`. Ninja also drives the parallel game build. |
| FreeType 2 | `brew install freetype pkg-config` |

Intel Macs are not supported: the output is arm64 code for Apple Silicon.

---

## Quick start: run a PS4 game on your Mac

There is no GUI yet: a game is built into a `.app` from the command line. All commands run from
the repository root. `/path/to/CUSA00557` stands for your dumped game folder, which contains
`eboot.bin`, `sce_module/` and `sce_sys/`.

### 1. Clone with the third-party sources

```bash
git clone --recursive https://github.com/manjarqo/ps4-native-mac.git ps4-native-mac
cd ps4-native-mac
# already cloned without --recursive:
git submodule update --init --recursive
```

`3rdparty/gcn-recompiler` is part of this repository (not a submodule); only its build output is
ignored.

### 2. Build the third-party libraries and the recompiler

```bash
# SPIRV-Cross -> 3rdparty/spirv-cross/libspirv-cross.a
(cd 3rdparty/spirv-cross &&
  clang++ -O3 -std=c++17 -c spirv_cross.cpp spirv_cross_parsed_ir.cpp spirv_parser.cpp \
    spirv_glsl.cpp spirv_msl.cpp spirv_cfg.cpp spirv_cross_c.cpp &&
  ar rcs libspirv-cross.a *.o && rm -f *.o)

# LibAtrac9 -> 3rdparty/libatrac9/libatrac9.a
(cd 3rdparty/libatrac9 && clang -O3 -c C/src/*.c && ar rcs libatrac9.a *.o && rm -f *.o)

# gcn-recompiler -> 3rdparty/gcn-recompiler/libgcn_recompiler.a (where ps4-recomp looks for it)
cmake -S 3rdparty/gcn-recompiler -B /path/to/gcn-build -G Ninja
ninja -C /path/to/gcn-build
cp /path/to/gcn-build/libgcn_recompiler.a 3rdparty/gcn-recompiler/

# the recompiler
go build -o ps4-recomp ./cmd/ps4-recomp
```

`ps4-recomp` finds the libraries under `3rdparty/` relative to the current directory or to its own
location. Run it from the repository root, or keep the binary there.

### 3. Dump your own game

The project works only on a **decrypted, extracted** game folder. It does not decrypt or unpack PKG
files, and **no game files are provided**. Dump a game you own legally, using your own console and
the tools of your choice. The upstream project suggests
[ps4-pkg-tools](https://github.com/xXJSONDeruloXx/ps4-pkg-tools) for extracting your own backups.

Optional check of the binary and its modules:

```bash
./ps4-recomp analyze /path/to/CUSA00557/eboot.bin
```

### 4. Recompile the eboot into a .app

```bash
./ps4-recomp /path/to/CUSA00557/eboot.bin --app-dir /path/to/CUSA00557 -o /path/to/build -c
```

The result is `/path/to/build/eboot.app`. `/path/to/build/ps4_app` is the same binary outside the
bundle.

- **Game files.** The bundle holds `guest_image.bin`, `sce_sys` and the icon. At run time the game
  files are read from the `--app-dir` folder given at build time. To change that folder, set
  `PS4_APP_DIR`. `--copy-resources` copies the whole game into `Contents/Resources` instead.
- **Rebuilds.** After a runtime-only change, `ninja -C /path/to/build` relinks without lifting the
  game again. Running the full command again regenerates and rebuilds everything.
- **Build time.** For TLOU, generation takes ~25 s. A full build took ~85 s on the M1 Pro.

| Flag | Meaning | Default |
| --- | --- | --- |
| `-o`, `-out <dir>` | Output directory | `build` |
| `-e`, `-elf <file>` | Input ELF (instead of the positional argument) | — |
| `-c`, `-compile` | Assemble and link with clang | `true` |
| `-j`, `-jobs <n>` | Parallel clang jobs | number of CPUs |
| `-O`, `-opt <level>` | Clang optimization level for the C parts | `2` |
| `-k`, `-chunk-size <n>` | Functions per emitted assembly chunk | `250` |
| `-a`, `-all-symbols` | Also emit unreachable symbols | `false` |
| `-tso` | x86 memory ordering (`-tso=false` disables it, for A/B tests only) | `true` |
| `--app-dir <dir>` | Host folder mapped to `/app0` | auto-detected |
| `--copy-resources` | Copy the game files into the bundle | `false` |
| `--asan` | Build the runtime with AddressSanitizer | `false` |
| `-r`, `-run` / `-t`, `-timeout <s>` | Run after building, with an optional watchdog | `false` / `0` |
| `-v`, `-verbose` | Verbose output and timings | `false` |

### 5. Sign (ad hoc)

```bash
codesign -f -s - /path/to/build/eboot.app
codesign -v /path/to/build/eboot.app
```

Sign again after every rebuild or after replacing the executable inside the bundle.

### 6. Launch

```bash
open /path/to/build/eboot.app
# or, to see the log:
/path/to/build/eboot.app/Contents/MacOS/eboot > run.log 2>&1
```

Controllers that GameController.framework supports (DualShock 4, DualSense and others) act as the
pad.

#### Launch settings (hold Option)

A settings window opens before the game starts:

- on the first launch of a game;
- on any later launch while **Option (⌥)** is held as the app starts.

| Option | What it does | Default |
| --- | --- | --- |
| **Language** | The console system language reported to the game. The list shows only the languages whose speech packs are in your game data, and English if none are found. The first entry selected is the one matching your macOS language. | macOS language |
| **PS4 Pro mode** | The game is told it runs on a PS4 Pro (`sceKernelIsNeoMode`), so it takes its Pro rendering path. The Last of Us Remastered then renders at 3200x1800, the PS4 Pro's "4K" mode, instead of 1920x1080 on a base PS4. This costs more GPU time. | On |
| **MetalFX upscaling** | Scales the presented frame up to the window size with MetalFX spatial upscaling, for example to 3840x2160 in a full-screen window on a 4K display. It needs macOS 13 or later. Combined with PS4 Pro mode it gives 1800p → 4K; with Pro mode off it can bring 1080p up to a large window for less GPU cost. | Off |
| **FPS counter (Metal HUD)** | An on-screen overlay. It shows fps, frame time and the longest frame, the renderer backend (`Metal 3` or `Metal 4`), the mode (PS4 / PS4 Pro), the game's render resolution and, with MetalFX, the output resolution, for example `PS4 Pro 3200x1800 -> 3840x2160 MetalFX`. | On |
| **Remember** | Saves the choices for this game, so the window does not open on later launches unless Option is held. Untick it to use the choices for this launch only. | On |

How the settings are stored and overridden:

- **Storage.** Settings are kept per game folder in
  `~/Library/Application Support/PS4Recomp/settings/<game folder name>.cfg`. With
  `PS4RECOMP_DATA_DIR` set, they are kept under that directory instead.
- **Overrides.** Environment variables override the stored values: `PS4_LANG`, `PS4_PRO=0|1`,
  `PS4_UPSCALE=off|metalfx` and `MTL_HUD_ENABLED=0|1`. `PS4_NO_DIALOGS=1` (or setting `PS4_LANG`)
  never shows the window, which is useful for scripts and test runs. The log prints the resolved
  values at startup (`[ps4-settings] ...`).
- **Language and existing saves.** The language is the console language, which games use as the
  default for a new profile. TLOU stores its text, subtitle and speech language in its save. Once a
  save exists, change the language in the game's own Options menu.

TLOU's fps in PS4 Pro mode has not been measured yet (TBD); its row in the
supported-games table uses base PS4 mode.

---

## FAQ

### Can I play PS4 games on my Mac?

Some, with this project. The Last of Us Remastered is playable from start to gameplay on an Apple
Silicon Mac. Uncharted 4 boots and reaches gameplay but still has rendering issues. Other PS4 games
are not supported yet: each game needs its own bring-up work, so do not expect an arbitrary game to
run. See [Supported games](#supported-games-on-mac).

### Is this a PS4 emulator?

Not in the usual sense. The game's x86-64 CPU code is recompiled ahead of time into native arm64
code, so nothing is interpreted or JIT-compiled while the game runs. The PS4 system libraries are
reimplemented on macOS (high-level emulation, HLE), and the game's GPU commands and shaders are
translated to Metal at run time; translated shaders are cached on disk.

### Which Macs are supported?

Macs with Apple Silicon (M1, M2, M3, M4 and later), on macOS. All measurements so far were taken
on an M1 Pro with 16 GB of memory running macOS 27.0.1; other chips and older macOS versions have
not been tested. Intel Macs are not supported. See [Requirements](#requirements).

### Do I need my own copy of the game?

Yes. The project works only on a decrypted, extracted game folder that you dumped yourself from a
copy you legally own. No game files, PS4 system software, firmware or keys are distributed with it.
See [Dump your own game](#3-dump-your-own-game) and the [Legal notice](#legal-notice).

### Does it use Rosetta, Wine or MoltenVK?

No. The recompiled game is a native arm64 macOS app, and the renderer uses Metal directly.

### Can I use a controller?

Yes. Controllers that GameController.framework supports (DualShock 4, DualSense and others) act as
the PS4 pad.

### Where are my saves?

In `~/Library/Application Support/PS4Recomp/saves` by default. See
[Where saves and caches live](#where-saves-and-caches-live).

### Can I share the built app?

No. The `.app` bundle, `guest_image.bin` and other build outputs contain the game's code. Build
your own from your own game copy.

---

## Configuration and debugging

### Environment variables

| Variable | Effect |
| --- | --- |
| `PS4RECOMP_DATA_DIR=<dir>` | Root for saves (`<dir>/saves`), settings, `download0` and `temp0`. Use a separate directory for test runs. |
| `PS4_SAVEDATA_DIR=<dir>` | Save root only (takes precedence over `PS4RECOMP_DATA_DIR`) |
| `PS4_APP_DIR=<dir>` | Game folder mapped to `/app0` |
| `PS4_PRO=0\|1` | PS4 Pro mode reported to the game (on by default). `0` is the base PS4 mode. |
| `PS4_UPSCALE=off\|metalfx` | MetalFX spatial upscaling to the window size (off by default) |
| `PS4_UPSCALE_FACTOR=<1..4>` | Upscale by a fixed factor instead of to the window size |
| `PS4_LANG=<code>` | System language (`en`, `ru`, `ja`, ... or an Orbis number); skips the dialog |
| `PS4_NO_DIALOGS=1` | Never show the settings dialog |
| `MTL_HUD_ENABLED=0\|1` | Metal performance HUD (its first line ends with the backend in use, `Metal 3` or `Metal 4`) |
| `PS4_GNM_METAL=3\|4` | Renderer backend (default 3). `4` needs a GPU with Metal 4 support; if it cannot start, the game stops with the reason instead of falling back (see [docs/metal4-backend.md](docs/metal4-backend.md)) |
| `PS4_GNM_COMPUTE_BATCH=0` | Commit every compute submission at its end instead of batching them (see [docs/compute-batching.md](docs/compute-batching.md)) |
| `PS4_GNM_RESIDENCY_CHECK=1` | Metal 4 only: check that every resource a command uses is resident and log each one that is not (costs encoder time) |
| `PS4_GNM_NO_SHADER_CACHE=1` | Disable the on-disk shader caches (MSL and GCN) |
| `PS4_GNM_NO_GCN_CACHE=1` | Disable only the GCN -> MSL translation cache |
| `PS4_GNM_SHADER_CACHE_MB=<n>` | Shader cache size budget |
| `PS4_GNM_NO_PSO_ARCHIVE=1` | Disable the Metal pipeline archive |
| `PS4_GNM_PSO_ARCHIVE_MB=<n>` | Pipeline archive budget (default 384) |
| `PS4_SYNC_LOG=1` | Write the log synchronously (default: an asynchronous log that is flushed on abort/exit) |
| `PS4_GNM_LOG_LONG_FRAMES=<ms>` | Log frames longer than `<ms>`, with a hitch breakdown |
| `PS4_STALL_PROFILE=<ms>` | Sample all threads during stalls longer than `<ms>` |
| `PS4_STALL_WATCHDOG=<ms>` | Report what threads do when no frame was presented for `<ms>` |
| `PS4_GNM_STATS=1`, `PS4_AUDIO_LOG=1`, `PS4_NP_LOG_ALL=1` | Command processor, audio and NP logging |
| `PS4_GNM_GPU_TIMEOUT=<ms>` | Command buffer watchdog (default 4000) |
| `PS4_SCREENSHOT_DIR=<dir>`, `PS4_SCREENSHOT_EVERY=<frames>` | Save presented frames as PNG |
| `PS4_SCREENSHOT_EVERY_SEC=<s>` | Save the first frame after every `s` seconds of wall time instead, as `sec_<seconds>.png` (to compare runs at the same moments) |
| `PS4_RECOMP_HEADLESS=1`, `PS4_BACKGROUND_WINDOW=1`, `PS4_PAD_SCRIPT=...` | Automated test runs |
| `PS4_PRESENT_MODE=uncapped\|vsync\|mailbox` | Frame pacing (default `uncapped`; see [docs/present-pacing.md](docs/present-pacing.md)) |
| `PS4_GNM_CAPTURE_FRAME=<n>`, `PS4_GNM_CAPTURE_DIR=<dir>` | Capture frame `n` (see [Debugging the renderer](#debugging-the-renderer)) |
| `PS4_GNM_CAPTURE_REPLAY=<a>-<b>,...`, `PS4_GNM_CAPTURE_REPLAY_SHADER=<addr>\|pgm:<hash>,...` | Store the captured passes in a range, or the passes using a shader and the passes that produced their inputs, replayable (see [docs/gnm-capture.md](docs/gnm-capture.md)) |
| `PS4_GNM_GUEST_MEMORY_FAST=1` | Opt-in fast path for shaders that access guest memory through descriptors they load at run time (no CPU wait per dispatch; see Known issues) |
| `PS4_GNM_SYNC_ENCODE=1`, `PS4_GNM_SYNC_COMPILE=1` | Encode and compile synchronously (captures, debugging) |
| `PS4_DUMP_SHADERS=<dir>` | Write every distinct VS/PS/CS program and its registers (see [Debugging the renderer](#debugging-the-renderer)) |

Host unit tests: `tests/host/run_host_tests.sh`. Some cases need shaders dumped from your own
game (local fixtures in `tests/host/data/game/` or `PS4_HOST_GAME_FIXTURES`, never committed);
without them they are reported as SKIP and the run ends with the number of skipped cases (see
[tests/host/README.md](tests/host/README.md)).
The benchmark scripts behind the TLOU numbers are `tools/metal4_route.sh` (one route run) and
`tools/metal4_perf_ab.sh` (alternating A/B runs). They are written for the developer's workspace
(`~/ps4recomp-work`) and need your own save and pad script, which are not in the repository.

### Debugging the renderer

- **Frame capture.** `PS4_GNM_CAPTURE_FRAME=<n>` records every draw and dispatch of frame `n`:
  a manifest, a PNG and raw bytes of every output, and the guest memory each pass reads.
  See [docs/gnm-capture.md](docs/gnm-capture.md).
- **Overview.** `tools/gnm_capture_view.py <capture>` writes an HTML page listing the passes in
  order with thumbnails, to find the first pass that goes wrong.
- **Replay.** `tools/gnm_replay` runs one captured pass through the same shader translation and
  Metal code as the game and compares the result byte for byte with the capture.
  `PS4_GNM_CAPTURE_REPLAY_SHADER` selects the passes to store replayable by shader, together with
  the passes that produced their inputs, since pass indices drift between runs.
- **Fixtures.** `tools/gnm_capture_extract.py` cuts one replayable pass out of a capture as a
  minimal frame for a host test. A pass from a game's capture is game data: keep it as a local
  fixture (see [tests/host/README.md](tests/host/README.md)).
- **Reference comparison.** `tools/refcompare.py <frame.png> <reference.png>` compares mean colour
  and luminance on a 4x4 grid plus a luminance histogram.
- **Shader dumps.** `PS4_DUMP_SHADERS=<dir>` writes each distinct VS/PS/CS program as
  `<stage>_<addr>.bin` with its registers in `<stage>_<addr>.txt`.
  `3rdparty/gcn-recompiler/tools/gcn_test` translates such dumps and checks the MSL with Metal;
  `gcn_dis` disassembles them.

Captures and shader dumps contain game data: keep them outside the repository and do not share
them.

### Where saves and caches live

| Data | Default location |
| --- | --- |
| Saves | `~/Library/Application Support/PS4Recomp/saves` (or `$PS4RECOMP_DATA_DIR/saves`) |
| Settings | `~/Library/Application Support/PS4Recomp/settings/<game folder name>.cfg` |
| `/download0`, `/temp0` | `~/Library/Application Support/PS4Recomp/{download0,temp0}/<TITLE_ID>` |
| Shader caches, pipeline archive | `~/Library/Caches/PS4Recomp/<game folder name>/` (not under `PS4RECOMP_DATA_DIR`) |

The on-disk names still say `PS4Recomp`; they come from the code and have not been renamed.

---

## How it works

```text
eboot.bin + sce_module/*.prx
  -> ELF/PRX loader, relocations, NID resolution         (pkg/elfloader)
  -> disassembly, CFG, jump tables, function discovery   (pkg/disasm, pkg/analyzer)
  -> x86-64 -> ARM64 assembly lifter                     (pkg/lifter)
  -> chunked .s files + small C glue, build.ninja        (pkg/emitter, pkg/cli)
  -> clang -mcpu=apple-m1, linked with the HLE runtime   (pkg/runtime)
  -> <name>.app bundle (guest_image.bin, sce_sys, Info.plist)
```

### Lifter (Go)

- The `ps4-recomp` tool is written in Go and decodes x86-64 with `golang.org/x/arch`.
- It discovers functions from the entry point, symbol tables, unwind info and relocations. It also
  resolves jump tables and handles overlapping instruction streams.
- It covers integer, BMI, SSE/AVX (128- and 256-bit), MMX, x87 and string instructions.
- Each guest function becomes an ARM64 assembly function. Chunks are assembled in parallel through
  ninja.
- The game's own PRX modules (for example `libc.prx` and `libSceFios2.prx` from `sce_module/`) are
  recompiled and linked statically. System library imports go to host shims.

### ARM64 assembly backend

- **Pinned guest registers.**
  - RAX–RDI map to x19–x25 and R8–R15 to x8–x15.
  - x26 holds the guest RSP, x27 the FS base (TLS) and x28 the guest memory base.
  - The XMM/YMM registers map to the vector register file.
  - Guest memory is reached as `[x28, addr]`.
- **x86 memory ordering (TSO).**
  - Scalar loads and stores to non-stack guest memory use LDAPR (load-acquire, RCpc) and STLR
    (store-release).
  - RSP- and RBP-relative accesses stay plain.
  - Accesses that cross a 16-byte boundary take a fenced fallback.
  - MFENCE lowers to `dmb ish`.
  - This is on by default (`-tso`). It adds ~31% static instructions; the measured cost is under
    1 fps.
- **LOCK prefix.**
  - Locked read-modify-write instructions use ARMv8.1 LSE atomics with acquire-release semantics:
    LDADDAL, LDCLRAL, LDEORAL, LDSETAL, SWPAL, CASAL, CASPAL.
  - Operations without an LSE form use an LDAXR/STLXR loop with DMB ISH.
- **Other.**
  - MXCSR rounding and FZ are kept across host calls.
  - RDTSC is scaled to the PS4's 2.13 GHz TSC.
  - x87 80-bit memory operands are converted to and from double.

### HLE runtime (C / Objective-C)

| Area | Implementation |
| --- | --- |
| Kernel | Guest virtual memory (direct and flexible memory, pools), VFS (`/app0`, `/download0`, `/temp0`), events/equeue, AIO, signals and exceptions, module info |
| Threads | Orbis pthreads on host threads; mutexes with an atomic fast path; `libSceFiber` as coroutines on the calling thread (`PS4_FIBER_THREADS=1` selects one host thread per fiber) |
| Audio | `libSceAudioOut` mixed and played through AudioToolbox; `libSceAjm` decodes ATRAC9 with libatrac9 and MP3 with minimp3 |
| Video | `libSceVideodec` (H.264) on VideoToolbox, with display-order output for B-frame streams |
| Saves | `libSceSaveData` mapped to host directories (see [Where saves and caches live](#where-saves-and-caches-live)) |
| Other | Pad (GameController.framework), user/system service, NP that always reports "signed out", Cocoa dialogs, FreeType, network modules (Net, Http, Ssl) |

The table also covers what Uncharted 4 needs: AAC decoding (`libSceAudiodec`, AudioToolbox),
`libSceVdecsw` (VideoToolbox) and `libSceAudio3d` (object and bed mixing to the 8-channel bus).

### Renderer: GNM on Metal

- The GNM command processor (`pkg/runtime/modules/libSceGnmDriver`) parses the guest's PM4 command
  buffers: the graphics ring, compute queues and indirect buffers.
- It tracks Liverpool register state and records Metal command buffers on a separate encoder
  thread.
- Two backends sit behind one interface (`ps4_gnm_backend.h`); `PS4_GNM_METAL` picks one at
  start and the log says which (`[gnm-draw] backend metal3 (...)`).
  - **Metal 3** (default): `MTLCommandQueue` with Metal's own hazard tracking between encoders.
  - **Metal 4**: `MTL4CommandQueue`, command allocators reused once their work completed, argument
    tables, residency sets for every resource, and a barrier at each encoder start.
  - The command processor, caches, shader translation, capture and replay are shared, and replays
    of captured TLOU frames give byte-identical outputs on both. See
    [docs/metal4-backend.md](docs/metal4-backend.md) and
    [docs/gnm-ordering.md](docs/gnm-ordering.md) for the ordering rules of each backend.
- Compute submissions are batched: while at least two command buffers are in flight, the end of a
  compute submission is held for at most 0.5 ms, so back-to-back submissions share a command
  buffer ([docs/compute-batching.md](docs/compute-batching.md)).
- Guest memory is mapped zero-copy into Metal buffers on unified memory.
- Textures are detiled and cached. GPU writes invalidate the cached copies.
- The frame is presented through `CAMetalLayer`, with optional MetalFX spatial upscaling.
- Compute queues run beside the graphics ring. A compute queue that waits on memory
  (`WAIT_REG_MEM`) is suspended and resumed, so cross-queue ordering follows the guest's own
  synchronisation.
- Buffer accesses through descriptors (V#) that a shader loads at run time read and write guest
  memory directly, through a page table of zero-copy windows. Uncharted 4 builds its per-draw
  matrices this way.
- A compute shader that reads and writes guest memory through descriptors it loads at run time
  is probed first for the guest pages it touches, which are then mapped for it. By default the
  command processor waits for each such dispatch, so later reads of guest memory see its writes.
  With the opt-in fast path (`PS4_GNM_GUEST_MEMORY_FAST=1`) it does not wait; after a barrier it
  waits for such dispatches before it reads guest memory they may have written (resource tables,
  textures), and a dispatch whose probe meets a new page runs again.
- Buffer stores over a texture the GPU owns (a render target or storage image): a store
  that covers the whole surface makes the GPU copy guest memory into the texture before it is next
  sampled; a partial store keeps the GPU-only contents.
- Image descriptor (T#) tables that a shader indexes at run time (light records, texture arrays
  behind an SRT pointer, loops over N records) are bound as separate images when the CPU can
  bound the index to at most 8 entries. A table entry written by GPU work that is still pending
  when the command processor copies the tables is read again after that work.
- GPU texture memory has a budget; unused textures are evicted.
- `sceGnmSubmitAndFlipCommandBuffers` and `sceVideoOutSubmitFlip` do not wait for the display:
  frames the presenter has not taken yet are held (at most `min(3, display buffers - 1)`), and
  their flips complete when they are shown, as on a PS4.
- A separate presenter thread shows the frames. By default (`PS4_PRESENT_MODE=uncapped`) every
  frame is shown at the next display refresh; `vsync` holds each frame for the guest's flip
  interval (`sceVideoOutSetFlipRate`). See [docs/present-pacing.md](docs/present-pacing.md).

### Shaders

```text
GCN bytecode (from guest memory)
  -> gcn-recompiler (shadPS4's shader_recompiler as a static library) -> SPIR-V
  -> SPIRV-Cross -> Metal Shading Language
  -> MTLLibrary / MTLRenderPipelineState
```

- Translated shaders are cached on disk per title: the GCN -> MSL results and the MSL sources.
- Built pipelines are stored in Metal binary archives (the PSO archive) and loaded at the next
  start, so known pipelines do not compile mid-frame.
- New shaders compile in the background.
- GCN runs 64 lanes per wave; Apple GPUs run 32-lane simdgroups, so a wave64 shader runs as two
  simdgroups. Cross-lane operations (`v_readlane`, `v_writelane`, `v_readfirstlane`, ballots,
  64-bit masks such as EXEC) see the whole wave. Code under a per-lane EXEC mask that needs the
  whole wave (cross-lane operations, workgroup memory, barriers) runs predicated on both halves,
  so every thread reaches every barrier.
- The known translation gaps are counted and logged once per shader, also when the shader comes
  from the on-disk cache: image reads of the null image (T#s loaded at run time, T# tables without
  a bound), wave64 regions the predication could not handle (left per 32-lane half), and
  `s_endpgm` in per-lane code that ends only the lanes that reach it.

### Third-party components

| Component | Location | Use | License |
| --- | --- | --- | --- |
| gcn-recompiler (from [shadPS4](https://github.com/shadps4-emu/shadPS4) `32021e4`) | `3rdparty/gcn-recompiler` (in this repository) | GCN -> SPIR-V shader translation | GPL-2.0-or-later |
| [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) | `3rdparty/spirv-cross` (submodule) | SPIR-V -> MSL | Apache-2.0 |
| [LibAtrac9](https://github.com/shadps4-emu/ext-LibAtrac9) | `3rdparty/libatrac9` (submodule) | ATRAC9 audio decoding | MIT |
| [minimp3](https://github.com/lieff/minimp3) | `3rdparty/minimp3` (submodule) | MP3 audio decoding | CC0-1.0 |

FFmpeg is not used: video decoding goes through VideoToolbox.

gcn-recompiler vendors sirit and SPIRV-Headers (BSD-3 / MIT), fmt (MIT), magic_enum (MIT) and a
Boost subset (BSL-1.0). Its README lists every change made to the shadPS4 sources.

---

## Project structure

```text
├── cmd/ps4-recomp/          # CLI entry point
├── cmd/lifter-difftest-asm/ # differential tester for the lifter
├── pkg/
│   ├── cli/                 # build driver, ninja, .app bundling
│   ├── analyzer/            # instruction coverage and CFG analysis
│   ├── disasm/              # disassembly, function discovery, jump tables
│   ├── elfloader/           # ELF64 / PRX loader and relocations
│   ├── lifter/              # x86-64 -> ARM64 assembly lifter
│   ├── emitter/             # chunked assembly emitter, HLE shim table, trampolines
│   └── runtime/             # host runtime
│       ├── core/            # guest context, logging, startup
│       ├── kernel/          # memory, threading, sync, vfs, aio, equeue, syscalls
│       └── modules/         # libSce* HLE modules (GnmDriver, VideoOut, AudioOut, Ajm, ...)
├── tests/                   # host unit tests and runtime test programs
├── tools/                   # capture viewer, pass replay, fixture extraction, reference comparison
├── docs/                    # renderer notes (backends, ordering, compute batching, capture, GPU memory budget, present pacing), plans
└── 3rdparty/                # see "Third-party components"
```

---

## Contributing

- macOS on Apple Silicon is the target. Changes for other platforms are welcome if they do not
  break or slow down macOS.
- AI tools may be used for development, provided the generated code is fully verified and does not
  break recompiled builds.

---

## Credits and acknowledgements

- The **PS4Recomp authors**: this project is a fork of their recompiler, runtime and tooling.
- **[shadPS4](https://github.com/shadps4-emu/shadPS4)**: HLE module architecture and system behaviour
  documentation, and the shader recompiler packaged as gcn-recompiler.
- **[OpenOrbis](https://github.com/OpenOrbis)**: open-source PS4 toolchain and reverse engineering.
- **[ps4libdoc](https://github.com/idc/ps4libdoc)**: symbol dictionaries and NID-to-name mappings.
- The authors of SPIRV-Cross, LibAtrac9 and minimp3.

---

## Legal notice

- **You must own every game you use with this project.** It works only on a game you dumped yourself
  from a copy you legally own.
- This project does not distribute game files, PS4 system software, firmware, encryption keys or
  recompiled game binaries. Do not share the `.app` bundles, `guest_image.bin` or other build
  outputs; they contain the game's code.
- ps4-native-mac is an independent project. It is not affiliated with, endorsed by or sponsored by
  Sony Interactive Entertainment, Naughty Dog or the original PS4Recomp authors.
- "PlayStation", "PlayStation 4", "PS4" and "Orbis OS" are trademarks of Sony Interactive
  Entertainment Inc. All game titles and assets belong to their respective owners.

---

## License

- ps4-native-mac is licensed under the [GNU General Public License v2.0](LICENSE), as was the
  PS4Recomp code it is based on.
- Files changed in this fork carry their change history in git: `git log --follow <file>` shows each
  modification, its date and its author.
- Third-party components keep their own licenses:

| Component | License |
| --- | --- |
| gcn-recompiler (from shadPS4) | GPL-2.0-or-later |
| SPIRV-Cross | Apache-2.0 |
| LibAtrac9 | MIT |
| minimp3 | CC0-1.0 |
| sirit / SPIRV-Headers, fmt, magic_enum, Boost subset (inside gcn-recompiler) | BSD-3 / MIT, MIT, MIT, BSL-1.0 |
