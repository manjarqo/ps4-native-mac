# PS4 Native app (plan 2 of 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS SwiftUI app, **PS4 Native**, laid out like Steam Desktop (layout A). In it a user:
- adds a PS4 game (fpkg or dumped folder, several at once, drag and drop);
- sees whether it is supported;
- builds the native version with one click;
- manages the game: settings, saves, DLC and updates, uninstall;
- plays it.

The app drives the `ps4-recomp` engine from plan 1 and ships as an ad-hoc-signed `.dmg` that contains everything except Apple's Command Line Tools.

**Architecture.** A Swift package `app/PS4Native/` with two targets:
- a library, `PS4NativeKit`, holding everything that is not a view: the engine client, library store, settings, saves, launcher, operation queue and the `AppModel` view model. It is tested with Swift Testing against a fake engine that replays recorded event streams;
- an executable, `PS4Native`, with the SwiftUI app and views only.

The engine runs as a child process (`ps4-recomp … --json`), one per operation; the app reads its JSON-lines stdout. Two prerequisite tasks change the engine and runtime:
- the runtime keys settings and saves by TITLE_ID;
- the engine finds the bundled `ninja` and FreeType and reports its version.

A packaging script assembles `PS4 Native.app` with the engine kit inside, signs it and makes the `.dmg`.

**Tech Stack:**
- Swift 6.4 (Xcode 27.1 toolchain, swift-tools-version 6.2), SwiftUI, Swift Testing, macOS 26+, arm64.
- Go 1.27.1 for the engine prerequisites, C/Objective-C for the runtime prerequisites.
- `codesign` and `hdiutil` for packaging.

**Spec:** `docs/superpowers/specs/2026-10-26-game-manager-design.md`, which includes the 2026-10-27 addendum. **Protocol:** `docs/game-manager-engine.md` (binding for every engine interaction).

## Task order and parallelism

Tasks 1, 2 and 4 are independent (runtime C, engine Go, Swift package) and can run in parallel. Task 3 needs 2. Task 5 needs 4. Task 7 needs 4 and can run in parallel with 5. Task 6 needs 5, because it edits `EngineResults.swift`. Task 8 needs 5. Task 9 needs 6, 7 and 8. Task 10 needs 9. Task 11 needs 3 and 10.

## Global Constraints

**Platform, toolchain and dependencies**
- macOS 26+, Apple Silicon only. Dark appearance (`.preferredColorScheme(.dark)` on the window).
- The app is a Swift package at `app/PS4Native/`, with no Xcode project and no third-party Swift dependencies. Build with `swift build --package-path app/PS4Native`; test with `swift test --package-path app/PS4Native`.

**Engine protocol**
- Every engine command runs as its own process with `--json`.
- The app trusts only the last event: `done` means success, `error` means failure, and anything else is a crash. A crash shows the last event and the log.
- Non-JSON stdout lines are a protocol violation: skip them, and count them in the log.
- Engine stderr goes to a log file.

**Storage**
- The library root is `~/Library/Application Support/PS4Native/`. Tests and smoke runs use `PS4NATIVE_LIBRARY` instead.
- The runtime data dir is `~/Library/Application Support/PS4Recomp/` (saves and settings). Tests and smoke runs use `PS4RECOMP_DATA_DIR` instead, and never the owner's real saves.

**Library lock**
- Every read-modify-write of `library.json` holds `flock(2) LOCK_EX` on `<root>/.lock`, as `docs/game-manager-engine.md` "Lock contract" requires.
- Re-read under the lock, write a temp file in `<root>`, `fsync`, then `rename`.
- Unknown JSON fields at the top level and per game are kept, and a `version` > 1 is refused.
- The lock is taken by polling `LOCK_EX|LOCK_NB` every 100 ms from async code, never blocking the main actor, and it honours task cancellation.

**Launching**
- A game started from the manager gets `PS4_NO_DIALOGS=1`, plus `PS4_GNM_METAL=3|4` when the game's `metal` setting is set.
- Stop sends SIGTERM, then SIGKILL after 10 s.

**Queue**
- Builds run one at a time.
- Imports also run one at a time: the engine serialises them by the lock anyway.
- Cancel sends SIGINT to the engine process.

**Safety of the owner's data**
- Deleting a save slot moves it to the Trash (`FileManager.trashItem`).
- Restoring a save always backs up the current state first.
- Uninstall removes only `games/<TITLE_ID>/` (and `pending/<TITLE_ID>*`), and saves only when the user turns "Keep saves" off; those go to the Trash too.
- The app never writes inside a referenced game folder.

**Testing and project rules**
- No game data in the repository. Fixtures are recorded from the real engine on synthetic inputs (`hello_world.elf` plus a synthetic param.sfo and fpkg), with machine paths replaced by placeholders.
- AGENTS.md:
  - no hacks, stubs or fake tests; general solutions only;
  - English in code and docs; UI strings in English;
  - Go/C/ObjC analysis tools clean; keep allocations low;
  - ask the owner before downloading anything.
- Worktree `~/ps4recomp-work/PS4Recomp-gm`, branch `game-manager`:
  - use explicit `git add` paths; never `git stash` or `git add -A`;
  - `go build -buildvcs=false`;
  - commits end with `Co-Authored-By: <the model that wrote the commit> <noreply@anthropic.com>`;
  - no push or merge without the owner.
- Never launch a real game from automated steps; the owner does the final play test. Game builds go through `~/ps4recomp-work/tools/heavy_lock.sh timeout -k 30 1800 …`.

## File Structure

| File | Responsibility |
|---|---|
| `pkg/runtime/modules/libSceSystemService/ps4_settings.m` (modify) | settings file named after the TITLE_ID from param.sfo |
| `pkg/runtime/modules/libSceSaveData/ps4_savedata.c` (modify) | reuse an existing `* [TITLE_ID]` save dir |
| `tests/host/settings_savedir_test.c` (new), `tests/host/run_host_tests.sh` (modify) | host tests for both |
| `pkg/cli/toolpaths.go`, `toolpaths_test.go` (new); `pkg/cli/cli.go` (modify) | bundled `bin/ninja` and `3rdparty/freetype` lookup; `version --json` |
| `tools/make_engine_kit.sh` (new) | assembles the engine kit (binary, runtime, 3rdparty, ninja, FreeType, licences) into a directory |
| `app/PS4Native/Package.swift` | the package |
| `app/PS4Native/Sources/PS4NativeKit/Support/JSONValue.swift` | Codable JSON value for unknown fields |
| `.../Support/SFO.swift` | param.sfo reader (and `SaveParam` for save slots' `param.bin`) |
| `.../Support/Paths.swift` | library root, data dir, engine kit location, env overrides |
| `.../Engine/EngineEvent.swift`, `EngineResults.swift` | event and result types (the protocol) |
| `.../Engine/Engine.swift`, `ProcessEngine.swift`, `FakeEngine.swift` | the engine client, the real runner, the replaying fake |
| `.../Library/LibraryFile.swift`, `LibraryStore.swift`, `FileLock.swift` | library.json model with unknown fields, the locked store, uninstall |
| `.../Settings/GameSettings.swift`, `Languages.swift` | `.cfg` read/write, the runtime's language table and availability rule |
| `.../Saves/SaveStore.swift` | slots, backup, restore, zip export/import, delete to Trash |
| `.../Launch/GameLauncher.swift` | run, track, stop, play time, run log |
| `.../Queue/OperationQueue.swift` | queued imports, analyses and builds with progress, cancel and logs (type name `EngineOperationQueue`) |
| `.../Environment/Toolchain.swift` | first-run checks (CLT clang ≥17, SDK ≥26, free space) |
| `.../Model/AppModel.swift`, `AddFlow.swift` | the view model (`@MainActor @Observable`): add flow, build, play, rebuild offers, uninstall |
| `.../Smoke/SmokeRunner.swift` | `--smoke` mode for the packaged app |
| `app/PS4Native/Sources/PS4NativeUI/*.swift` | SwiftUI views: sidebar, game page and tabs, add sheet, queue, first run, settings (a library, so tests can render them) |
| `app/PS4Native/Sources/PS4Native/PS4NativeApp.swift` | the `@main` entry only |
| `app/PS4Native/Tests/PS4NativeKitTests/*.swift`, `Fixtures/` | tests and recorded engine streams |
| `app/PS4Native/scripts/record-fixtures.sh`, `package.sh`, `smoke.sh` | fixture recording, app + dmg packaging, packaged smoke test |
| `docs/game-manager-app.md` (new), `README.md` (modify) | how to build, package and use the app |

---

### Task 0: Toolchain check

**Files:** none.

- [ ] **Step 1:** Run `swift --version` and `xcrun --show-sdk-version`, and check that `xcrun --sdk macosx --show-sdk-path` exists. Expected: Swift 6.4 and SDK 26 or later. Record the values in the ledger.
- [ ] **Step 2:** Check the engine still builds and tests clean at HEAD:

```bash
cd ~/ps4recomp-work/PS4Recomp-gm || exit 1
go build -buildvcs=false -o ps4-recomp ./cmd/ps4-recomp && go vet ./... && go test ./pkg/... 2>&1 | grep -v "no test files" | grep -v "^ok" ; echo done
```

Expected: only `done`.

---

### Task 1: Runtime keys settings and saves by TITLE_ID

**Files:**
- Modify: `pkg/runtime/modules/libSceSystemService/ps4_settings.m` (`settings_path`, about lines 118-125)
- Modify: `pkg/runtime/modules/libSceSaveData/ps4_savedata.c` (`get_game_save_dir`, about lines 113-138)
- Create: `tests/host/settings_savedir_test.c`; Modify: `tests/host/run_host_tests.sh` (add the test)

**Interfaces:**
- Produces two runtime behaviours the app relies on:
  1. **Settings file.** The file is `<settings dir>/<TITLE_ID>.cfg`, where TITLE_ID comes from the game's `param.sfo` through `ps4_sfo_find_and_load` and `ps4_sfo_get_string(&sfo, "TITLE_ID", …)`, the same calls savedata uses. When there is no param.sfo or no TITLE_ID, the old base name of the app root is used. Only letters, digits, `-` and `_` are kept; anything else falls back to the base name.
  2. **Save directory.** Before composing `"<TITLE> [<TITLE_ID>]"`, scan the save base dir for an existing directory whose name ends with `" [<TITLE_ID>]"` and use it. When several match, take the one with the newest modification time, deterministically. Otherwise compose the name as before.
- Both keep working for today's dumps. The `CUSA00557` directory gives TITLE_ID CUSA00557 either way, and the existing `… Preorder Joel Skin [CUSA00557]` save directory is found by its suffix even after the title changes.

- [ ] **Step 1: Read the code first.** Read `ps4_settings.m` (settings_dir/settings_path/load/save, lines 100-165), `ps4_savedata.c` (lines 80-160 and its other `get_game_save_dir` callers), `pkg/runtime/core/ps4_sfo.c`/`.h`, and how `tests/host/run_host_tests.sh` builds a C host test: pick the closest existing pure-C test as the pattern.
- [ ] **Step 2: Refactor for testability.** Factor the two naming decisions into pure functions declared in a small header `pkg/runtime/core/ps4_game_key.h` (create `ps4_game_key.c` next to it):

```c
// SPDX-License-Identifier: GPL-2.0-or-later
// Names the per-game files of the host: the settings file and the save directory.
#pragma once
#include <stddef.h>
#include <stdbool.h>

// Writes the settings key for a game: title_id when it is a valid id (letters, digits, '-', '_',
// 1..31 chars), otherwise fallback (the app root's base name). Returns false when both are empty.
bool ps4_settings_key(const char *title_id, const char *fallback, char *out, size_t out_size);

// Finds an existing directory in base_dir whose name ends with " [<title_id>]" (the newest by
// mtime when several do) and writes its full path to out. Returns false when there is none or
// title_id is empty.
bool ps4_find_save_dir_by_title_id(const char *base_dir, const char *title_id, char *out, size_t out_size);
```

  `settings_path` and `get_game_save_dir` call them. Keep the existing behaviour for every other case.
- [ ] **Step 3: Write the failing host test** `tests/host/settings_savedir_test.c`. It creates a temp dir with `mkdtemp`, then checks:
  - `ps4_settings_key("CUSA00557", "content", …)` gives `"CUSA00557"`;
  - `ps4_settings_key("", "CUSA04529", …)` gives `"CUSA04529"`;
  - `ps4_settings_key("../x", "content", …)` gives `"content"`;
  - with the dirs `A [CUSA00557]` (older mtime set via `utimes`), `B [CUSA00557]` (newer) and `C [CUSA04529]`, `ps4_find_save_dir_by_title_id(dir, "CUSA00557", …)` returns `…/B [CUSA00557]`;
  - `"CUSA99999"` returns false;
  - a regular *file* named `D [CUSA00557]` is ignored.
  Print `settings_savedir_test: PASS` on success, as the other host tests do. Add it to `run_host_tests.sh` following the existing C-test pattern.
- [ ] **Step 4: Run the test and see it fail (it does not compile), then implement `ps4_game_key.c`.** Use `opendir`/`readdir`, `lstat` (directories only, no symlinks), and length-checked suffix comparison; never write past `out_size`. Add `ps4_game_key.c` wherever the runtime's C sources are listed for the game build, if the build collects files explicitly: check how `pkg/cli` gathers runtime sources (`scanRuntimeFiles`/`collect…`). If it globs `pkg/runtime/**.c`, nothing is needed.
- [ ] **Step 5: Run the host test**, then the whole host suite under the lock, and see it pass:

```bash
cd ~/ps4recomp-work/PS4Recomp-gm || exit 1
~/ps4recomp-work/tools/heavy_lock.sh timeout -k 30 2400 bash tests/host/run_host_tests.sh > ~/ps4recomp-work/gm_t1_host.log 2>&1; echo "exit $?"; grep -E "settings_savedir|FAIL" ~/ps4recomp-work/gm_t1_host.log | head
```

  Expected: `exit 0` and `settings_savedir_test: PASS`.
- [ ] **Step 6: Commit.** `git add pkg/runtime/core/ps4_game_key.h pkg/runtime/core/ps4_game_key.c pkg/runtime/modules/libSceSystemService/ps4_settings.m pkg/runtime/modules/libSceSaveData/ps4_savedata.c tests/host/settings_savedir_test.c tests/host/run_host_tests.sh` with the message "runtime: settings and saves keyed by TITLE_ID".

---

### Task 2: Engine finds bundled ninja and FreeType; `version --json`

**Files:**
- Create: `pkg/cli/toolpaths.go`, `pkg/cli/toolpaths_test.go`
- Modify: `pkg/cli/cli.go`: the ninja lookup in `compileParallel` (`exec.LookPath("ninja")`), the FreeType block in `generateNinjaBuild` (about lines 594-604), the clang fallback link flags if they also use `ftLibs`, `Execute` (route `version`), and `usageText`.
- Modify: `docs/game-manager-engine.md` (a `version` row in Commands, and a "Bundled tools" paragraph).

**Interfaces:**
- Produces `func findNinja() string`. It returns the first of these that exists:
  1. `<exeDir>/bin/ninja`;
  2. `<exeDir>/../bin/ninja`;
  3. `exec.LookPath("ninja")`;
  4. otherwise "".
- Produces `func findFreeType() (cflags, libs []string)`, tried in this order:
  1. **Bundled:** `<exeDir>/3rdparty/freetype` (or `../3rdparty/freetype`) holding `include/freetype2/ft2build.h` and `lib/libfreetype.a`. Then cflags are `-I<dir>/include/freetype2` and libs are `<dir>/lib/libfreetype.a`, then `<dir>/lib/libpng16.a` when it exists, then `-lz -lbz2`.
  2. **pkg-config:** what it reports.
  3. **Homebrew:** `/opt/homebrew/opt/freetype`, as today.
  4. **None found:** `nil, nil`.
- Produces `ps4-recomp version [--json]`. With `--json` it emits one `done` event, `{"event":"done","op":"version","result":{"version":"0.3.0","go":"go1.27.1"}}`, using the existing `Version` constant and `runtime.Version()`. Without `--json` it prints `ps4-recomp 0.3.0`.

- [ ] **Step 1: Write failing tests.** In `toolpaths_test.go`, test the lookup functions through a seam: put the search logic in `ninjaIn(dirs []string, lookPath func(string) (string, error)) string` and `freeTypeIn(dirs []string, pkgConfig func(args ...string) ([]byte, error), brewDir string) ([]string, []string)`, with the exported finders calling them with the real exe dirs. Tests:
  - a temp kit dir with `bin/ninja` (an executable file) wins over a fake lookPath;
  - with none, lookPath is used;
  - a temp `3rdparty/freetype` with `include/freetype2/ft2build.h`, `lib/libfreetype.a` and `lib/libpng16.a` gives exactly `[-I…/include/freetype2]` and `[…/libfreetype.a …/libpng16.a -lz -lbz2]`;
  - without libpng16.a, libpng is left out of the list;
  - with no bundled dir, the pkg-config output is used.
  
  Add an engine test: `runJSON(t, "version", "--json")` gives one `done` line with result.version == `Version`.
- [ ] **Step 2: Run them and see them fail.** Run `go test ./pkg/cli/ -run 'Ninja|FreeType|Version'`.
- [ ] **Step 3: Implement**, and replace the two call sites. Keep the existing behaviour when nothing is bundled.
- [ ] **Step 4: Verify.**
  - Run `go test ./pkg/cli/`, `go vet ./...` and `gofmt -l pkg cmd`.
  - Do a manual check with a fake kit: `mkdir -p /tmp/…/kit/bin && cp ps4-recomp /tmp/…/kit/ && ln -s /opt/homebrew/bin/ninja /tmp/…/kit/bin/ninja`.
  - Run the kit's `ps4-recomp version --json`; its output must be pure JSON. Use a scratch dir under the scratchpad, not /tmp.
- [ ] **Step 5: Update the doc and commit.** Add `version` to the Commands table and a short "Bundled tools" paragraph (lookup order) to `docs/game-manager-engine.md`. Commit with "cli: bundled ninja and FreeType lookup; version --json".

---

### Task 3: Engine kit script

**Files:**
- Create: `tools/make_engine_kit.sh`

**Interfaces:**
- Produces `tools/make_engine_kit.sh <out dir>`. It builds `ps4-recomp` (`go build -buildvcs=false -trimpath`) and assembles, mirroring the v0.3.0 release layout (`INSTALL.txt` in the release documents it):

```
<out>/ps4-recomp
<out>/pkg/runtime/...                         (git ls-files pkg/runtime, copied; no build products)
<out>/3rdparty/gcn-recompiler/{include/, libgcn_recompiler.a, LICENSE}
<out>/3rdparty/spirv-cross/{libspirv-cross.a, LICENSE}   (+ headers the runtime includes, if any)
<out>/3rdparty/libatrac9/{libatrac9.a, C/src/*.h, LICENSE}
<out>/3rdparty/minimp3/{minimp3.h, minimp3_ex.h, LICENSE}
<out>/3rdparty/freetype/{include/freetype2/..., lib/libfreetype.a, lib/libpng16.a, LICENSE.TXT, LICENSE-libpng}
<out>/bin/ninja, <out>/licenses/ninja-COPYING
<out>/LICENSE
```

- **Sources:**
  - FreeType: `/opt/homebrew/opt/freetype/{include,lib/libfreetype.a,LICENSE.TXT}`;
  - libpng: `/opt/homebrew/opt/libpng/{lib/libpng16.a,LICENSE}`;
  - ninja: `/opt/homebrew/opt/ninja/{bin/ninja,COPYING}`;
  - the 3rdparty static libraries from the repo's `3rdparty/` (built ones).
- **Copying:** copy the real files (`cp -L`) and never leave symlinks into Homebrew.
- **Missing inputs:** the script fails with a clear message naming the missing input (`brew install freetype libpng ninja` for the Homebrew ones). It never downloads.
- **Self-check at the end:**
  - build `hello_world.elf` with the kit's `ps4-recomp`, from a clean scratch dir with `PATH=/usr/bin:/bin` (no Homebrew), so that the bundled ninja and FreeType are used;
  - check that the result links without Homebrew paths (`otool -L` on the built binary shows no `/opt/homebrew`);
  - remove the scratch build.

- [ ] **Step 1: Read the inputs.** Read how the v0.3.0 kit was laid out (`~/ps4recomp-work/release_v0.3.0/stage/ps4-native-mac-v0.3.0-macos-arm64/`, INSTALL.txt) and which headers the runtime build includes from `3rdparty/` (grep `findSpirvCross`/`findLibAtrac9` and the include dirs in pkg/cli).
- [ ] **Step 2: Write the script** (`set -euo pipefail`, absolute paths, `cd … || exit 1`), running from the repo root.
- [ ] **Step 3: Run it** into the scratchpad. Check the self-check passes and `du -sh` of the kit, then record the file list summary (counts per top-level dir) and the size in the report.
- [ ] **Step 4: Commit** with "tools: engine kit assembly (bundled ninja and FreeType)".

---

### Task 4: Swift package, SFO reader, paths

**Files:**
- Create: `app/PS4Native/Package.swift`, `app/PS4Native/.gitignore` (`.build/`, `*.dmg`, `dist/`)
- Create: `Sources/PS4NativeKit/Support/JSONValue.swift`, `SFO.swift`, `Paths.swift`
- Create: `Sources/PS4Native/PS4NativeApp.swift` (the `@main` entry) and `Sources/PS4NativeUI/RootView.swift`, a minimal public window `Text("PS4 Native")` that Task 10 replaces. This is a temporary view, not a stub of logic.
- Test: `Tests/PS4NativeKitTests/SFOTests.swift`, `Tests/PS4NativeKitTests/Support/SFOBuilder.swift`

**Interfaces:**
- Produces:
  - `JSONValue`: a Codable, Sendable, Equatable enum with the cases `null`, `bool`, `number(Double)`, `string`, `array`, `object([String: JSONValue])`.
  - `SFO`:
    - `init(data:)` and `init(contentsOf:)`;
    - `string(_:) -> String?` and `int(_:) -> UInt32?`;
    - `appVersion: String?`, which is `APP_VER`, falling back to `VERSION` when absent or empty;
    - `title`, `titleID` and `category` accessors.
  - `SFOError`.
  - `SaveParam`: `title`, `subtitle`, `detail` and `modified: Date?`, read from a save slot's `sce_sys/param.bin`. Layout: `title` [128] at 0, `subTitle` [128] at 128, `detail` [1024] at 256, a u32 userParam at 1280, an i64 mtime (Unix seconds) at 1288, 1328 bytes in total; NUL-terminated UTF-8, little-endian.
  - `Paths`:
    - `libraryRoot`: `PS4NATIVE_LIBRARY` or `~/Library/Application Support/PS4Native`;
    - `dataDir`: `PS4RECOMP_DATA_DIR` or `~/Library/Application Support/PS4Recomp`;
    - `savesDir`: `PS4_SAVEDATA_DIR` or `dataDir/saves`;
    - `settingsDir`: `dataDir/settings`;
    - `engineKit`: `PS4NATIVE_ENGINE` or `Bundle.main.resourceURL/engine`;
    - `engineExecutable`: `engineKit/ps4-recomp`.

  Paths is built from an injected environment dictionary (`Paths(environment: ProcessInfo.processInfo.environment, bundle: .main)`), so tests set their own.

`Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PS4Native",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "PS4Native", targets: ["PS4Native"])],
    targets: [
        .target(name: "PS4NativeKit"),
        .target(name: "PS4NativeUI", dependencies: ["PS4NativeKit"]),
        .executableTarget(name: "PS4Native", dependencies: ["PS4NativeUI", "PS4NativeKit"]),
        .testTarget(name: "PS4NativeKitTests", dependencies: ["PS4NativeKit", "PS4NativeUI"], resources: [.copy("Fixtures")]),
    ]
)
```

(Create `Tests/PS4NativeKitTests/Fixtures/.keep` so the resource directory exists.)

`SFO.swift`:

```swift
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum SFOError: Error, Equatable, Sendable {
    case badMagic, truncated, unknownFormat(String)
}

/// A PS4 param.sfo (the PSF key/value format in sce_sys/). See docs/game-manager-engine.md.
public struct SFO: Sendable, Equatable {
    public enum Value: Sendable, Equatable { case string(String), int(UInt32) }
    public let values: [String: Value]

    public init(contentsOf url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    public init(data: Data) throws {
        let b = [UInt8](data)
        guard b.count >= 20, b[0] == 0, b[1] == 0x50, b[2] == 0x53, b[3] == 0x46 else { throw SFOError.badMagic }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        let keyTab = u32(8), dataTab = u32(12), n = u32(16)
        guard 20 + n * 16 <= b.count, keyTab <= b.count, dataTab <= b.count else { throw SFOError.truncated }
        var out: [String: Value] = [:]
        for i in 0..<n {
            let e = 20 + i * 16
            let keyOff = keyTab + u16(e), format = u16(e + 2), len = u32(e + 4), dataOff = dataTab + u32(e + 12)
            guard keyOff < b.count, dataOff + len <= b.count,
                  let end = b[keyOff...].firstIndex(of: 0) else { throw SFOError.truncated }
            let key = String(decoding: b[keyOff..<end], as: UTF8.self)
            switch format {
            case 0x0404:
                guard len >= 4 else { throw SFOError.truncated }
                out[key] = .int(UInt32(u32(dataOff)))
            case 0x0204, 0x0004:
                var s = b[dataOff..<(dataOff + len)]
                while s.last == 0 { s = s.dropLast() }
                out[key] = .string(String(decoding: s, as: UTF8.self))
            default:
                throw SFOError.unknownFormat(key)
            }
        }
        values = out
    }

    public func string(_ key: String) -> String? {
        if case .string(let s)? = values[key] { return s }
        return nil
    }

    public func int(_ key: String) -> UInt32? {
        if case .int(let v)? = values[key] { return v }
        return nil
    }

    public var title: String? { string("TITLE") }
    public var titleID: String? { string("TITLE_ID") }
    public var category: String? { string("CATEGORY") }

    /// APP_VER, falling back to VERSION when APP_VER is absent or empty (the engine's version rule).
    public var appVersion: String? {
        if let v = string("APP_VER"), !v.isEmpty { return v }
        return string("VERSION")
    }
}

/// The metadata of a save slot, sce_sys/param.bin as the runtime writes it (ps4_savedata.c SdParam).
public struct SaveParam: Sendable, Equatable {
    public let title: String
    public let subtitle: String
    public let detail: String
    public let modified: Date?

    public init(data: Data) throws {
        let b = [UInt8](data)
        guard b.count >= 1296 else { throw SFOError.truncated }
        func cstr(_ range: Range<Int>) -> String {
            let s = b[range]
            let end = s.firstIndex(of: 0) ?? range.upperBound
            return String(decoding: b[range.lowerBound..<end], as: UTF8.self)
        }
        title = cstr(0..<128)
        subtitle = cstr(128..<256)
        detail = cstr(256..<1280)
        var t: Int64 = 0
        for i in 0..<8 { t |= Int64(b[1288 + i]) << (8 * i) }
        modified = t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil
    }
}
```

- [ ] **Step 1: Write the failing tests.**
  - The test helper `SFOBuilder.build(_ entries: [(String, SFO.Value)]) -> Data` mirrors the Go `sfo.Build`: entries sorted by key; strings with format 0x0204, length len+1 and max length aligned to 4; ints with format 0x0404.
  - Tests:
    - a round trip of TITLE_ID/TITLE (with `’`)/APP_VER/CATEGORY plus an int key;
    - `appVersion` falls back to VERSION when APP_VER is missing and when it is empty;
    - bad magic and truncation throw;
    - `SaveParam` reads a hand-built 1328-byte buffer (title "Joel", subtitle "Chapter 3", mtime 1_760_000_000);
    - `Paths` uses the env overrides and the defaults (with a fake home given through `environment["HOME"]`).
- [ ] **Step 2: Run them and see them fail.** Run `swift test --package-path ~/ps4recomp-work/PS4Recomp-gm/app/PS4Native`; it should fail to compile.
- [ ] **Step 3: Implement** `JSONValue` and `Paths`, plus the SFO code above.
- [ ] **Step 4: Run the tests and see them pass**, and make sure `swift build` of the app target succeeds.
- [ ] **Step 5: Commit** with "app: Swift package, SFO and save param readers, paths".

---

### Task 5: Engine client: events, results, process runner, fake engine, fixtures

**Files:**
- Create: `Sources/PS4NativeKit/Engine/EngineEvent.swift`, `EngineResults.swift`, `Engine.swift`, `ProcessEngine.swift`, `FakeEngine.swift`
- Create: `app/PS4Native/scripts/record-fixtures.sh`, `tools/gmfixtures/main.go` (writes a synthetic fpkg and content dir using `pkg/fpkg/fpkgtest` and `pkg/sfo`)
- Create: `Tests/PS4NativeKitTests/Fixtures/*.jsonl` (recorded), `EngineTests.swift`

**Interfaces:**
- **Events:**
  - `EngineEvent` is Decodable, Sendable and Equatable. It has `event: Kind` (`progress`/`warning`/`error`/`done`), `op: String`, `stage`, `done`/`total: Int64?`, `unit`, `code` and `message`.
  - The raw line is kept for the `done` event.
- **Results:** Decodable result types with snake_case keys, exactly the fields in `docs/game-manager-engine.md` "Results".
  - `InspectResult`;
  - `ImportResult`, whose `game` is a `GameRecord` from Task 6. Until then, define `GameRecord` here minimally? No: Task 6 owns `GameRecord`, so `ImportResult` decodes `game` as `JSONValue?` and Task 6 adds a typed accessor;
  - `GameAnalysis`, with `Verdict`. Arrays and maps are optional (null means empty);
  - `BuildResult`;
  - `VersionResult`.
- **Engine:**
  - `protocol Engine: Sendable { func run(_ arguments: [String], log: URL?, onEvent: @escaping @Sendable (EngineEvent) -> Void) async throws -> EngineRun }`.
  - `EngineRun` holds `events: [EngineEvent]` and `doneLine: Data`, with `func result<R: Decodable>(_: R.Type) throws -> R`, which decodes `{"result": …}` from `doneLine`.
  - `run` throws `EngineFailure(code: String, message: String)` when the last event is `error`. It throws `EngineFailure(code: "crashed", message: "the engine exited with status N without a result")` when the stream ends without `done`/`error`. When the task is cancelled, the process gets SIGINT; the engine then ends with an `error` event with code `cancelled`, which surfaces as `EngineFailure("cancelled")`.
  - Typed helpers in an extension:
    - `inspect(_ src: URL)`;
    - `importGame(_ src: URL, library: URL, mode: ImportMode, log:, onEvent:)`;
    - `analyze(content: URL, log:, onEvent:)`;
    - `build(content: URL, buildDir: URL, log:, onEvent:)`, which runs `build <content>/eboot.bin -o <buildDir> --json`;
    - `version()`.
- **ProcessEngine:**
  - Uses `Process`, with stdout read line by line through `FileHandle.bytes.lines` and stderr written to `log`.
  - Exit is detected through a `terminationHandler` set before `run()`.
  - Cancellation goes through `withTaskCancellationHandler { … } onCancel: { process.interrupt() }`.
  - Non-JSON lines are counted and written to the log as `[app] non-JSON engine line: …`.
- **FakeEngine:**
  - `init(fixtures: URL, substitutions: [String: String], delay: Duration = .zero)` maps the subcommand (`arguments[0]`) to `<fixtures>/<subcommand>.jsonl`, or to an override set with `func setScript(_ subcommand: String, lines: [String], exitOK: Bool)`.
  - It replays the lines with `$LIB`, `$SRC`, `$TMP` and similar placeholders replaced, sleeping `delay` between lines.
  - It records `calls: [[String]]`.
  - On cancellation it emits `{"event":"error","op":…,"code":"cancelled","message":"cancelled"}`.

- [ ] **Step 1: Record the fixtures.**
  - `tools/gmfixtures/main.go` takes an output dir. It writes:
    - `content/` (`eboot.bin` = a copy of the repo's `hello_world.elf`, and `sce_sys/param.sfo` with TITLE_ID CUSA00557, TITLE "Test Game", APP_VER 01.00, CATEGORY gd);
    - `game.pkg`, a synthetic fake fpkg of the same content made with `fpkgtest.BuildTestPKG`;
    - `patch.pkg` (CATEGORY gp, APP_VER 01.05);
    - `dlc.pkg` (CATEGORY ac, CONTENT_ID label `TESTDLC000000000`);
    - `retail.pkg` (`Opts{Retail: true}`).
  - `record-fixtures.sh` builds the engine, runs gmfixtures into a scratch dir, and runs these commands with `--json`, capturing stdout to `Fixtures/<name>.jsonl`:
    - `inspect` on game.pkg, retail.pkg and the folder;
    - `import` on game.pkg, patch.pkg and dlc.pkg into a scratch library, and an import of retail.pkg (an error stream);
    - `analyze-game` on the content;
    - `build` of the content's eboot.bin (a real small build);
    - `version`.
  - Afterwards the script replaces the scratch paths with `$LIB`, `$SRC` and `$TMP` (sed) and checks with grep that no `/Users/` or `/Volumes/` path remains.
  - Name the fixtures:
    - `inspect.jsonl`, `inspect-retail.jsonl` and `inspect-folder.jsonl`;
    - `import.jsonl`, `import-patch.jsonl`, `import-dlc.jsonl` and `import-retail.jsonl`;
    - `analyze-game.jsonl`, `build.jsonl` and `version.jsonl`.
- [ ] **Step 2: Write the failing tests** (`EngineTests.swift`):

```swift
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import PS4NativeKit

private let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

@Test func decodesEveryRecordedStream() throws {
    for name in ["inspect", "inspect-retail", "inspect-folder", "import", "import-patch", "import-dlc",
                 "import-retail", "analyze-game", "build", "version"] {
        let text = try String(contentsOf: fixtures.appending(path: "\(name).jsonl"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(!lines.isEmpty, "\(name) is empty")
        for line in lines {
            #expect(throws: Never.self) { try JSONDecoder().decode(EngineEvent.self, from: Data(line.utf8)) }
        }
    }
}

@Test func typedResults() async throws {
    let engine = FakeEngine(fixtures: fixtures, substitutions: ["$LIB": "/tmp/lib", "$SRC": "/tmp/src", "$TMP": "/tmp"])
    let inspect = try await engine.inspect(URL(filePath: "/tmp/src/game.pkg"))
    #expect(inspect.kind == "game" && inspect.signing == "fake" && inspect.titleID == "CUSA00557")
    let retail = try await engine.inspect(URL(filePath: "/tmp/src/retail.pkg"), fixture: "inspect-retail")
    #expect(retail.signing == "retail")
    let analysis = try await engine.analyze(content: URL(filePath: "/tmp/lib/games/CUSA00557/content"), log: nil) { _ in }
    #expect(analysis.titleID == "CUSA00557")
    let version = try await engine.version()
    #expect(!version.version.isEmpty)
}

@Test func errorStreamThrowsItsCode() async throws {
    let engine = FakeEngine(fixtures: fixtures, substitutions: [:])
    await #expect(throws: EngineFailure(code: "retail_pkg", message: "this PKG is encrypted with console keys; use a dump of your own console or an fpkg")) {
        _ = try await engine.importGame(URL(filePath: "/x.pkg"), library: URL(filePath: "/lib"), mode: .copy, log: nil, fixture: "import-retail") { _ in }
    }
}

@Test func streamWithoutResultIsACrash() async throws {
    let engine = FakeEngine(fixtures: fixtures, substitutions: [:])
    engine.setScript("analyze-game", lines: [#"{"event":"progress","op":"analyze-game","stage":"analyze","done":0,"total":1,"unit":"stages"}"#], exitOK: false)
    await #expect(throws: EngineFailure.self) { _ = try await engine.analyze(content: URL(filePath: "/c"), log: nil) { _ in } }
}

@Test func cancelEndsWithCancelled() async throws {
    let engine = FakeEngine(fixtures: fixtures, substitutions: [:], delay: .milliseconds(200))
    let task = Task { try await engine.build(content: URL(filePath: "/c"), buildDir: URL(filePath: "/b"), log: nil) { _ in } }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    do { _ = try await task.value; Issue.record("not cancelled") } catch let f as EngineFailure { #expect(f.code == "cancelled") }
}

@Test func processEngineRunsTheRealBinary() async throws {
    // The real engine, when it is built in the repo (CI builds it first); skipped with a recorded reason otherwise.
    let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardized
    let exe = repo.appending(path: "ps4-recomp")
    try #require(FileManager.default.isExecutableFile(atPath: exe.path), "build ps4-recomp in the repo root first")
    let engine = ProcessEngine(executable: exe)
    let v = try await engine.version()
    #expect(!v.version.isEmpty)
    let log = FileManager.default.temporaryDirectory.appending(path: "engine-\(UUID()).log")
    await #expect(throws: EngineFailure.self) { _ = try await engine.analyze(content: URL(filePath: "/nonexistent"), log: log) { _ in } }
}
```

  The `fixture:` parameter on the typed helpers is FakeEngine-only, so put it in a `FakeEngine` extension with the same helper names. Keep the protocol helpers free of it.
- [ ] **Step 3: Run the tests and see them fail**, then implement the five files.
- [ ] **Step 4: Run the tests and see them pass.** Run `go build -buildvcs=false -o ps4-recomp ./cmd/ps4-recomp` in the repo root first, so the ProcessEngine test runs instead of being skipped. Run `go vet ./tools/gmfixtures/`.
- [ ] **Step 5: Commit** the Swift files, the fixtures, `record-fixtures.sh` and `tools/gmfixtures/main.go` with "app: engine client, fake engine and recorded fixtures".

---

### Task 6: Library store: library.json with unknown fields, the lock, uninstall

**Files:**
- Create: `Sources/PS4NativeKit/Library/FileLock.swift`, `LibraryFile.swift`, `LibraryStore.swift`
- Modify: `Sources/PS4NativeKit/Engine/EngineResults.swift` (typed `ImportResult.gameRecord`)
- Test: `Tests/PS4NativeKitTests/LibraryTests.swift`

**Interfaces:**
- **`GameRecord`** is Codable, Sendable, Equatable and Identifiable (id = titleID). It has:
  - `titleID`, `contentID`, `title`, `appVer`, `version`;
  - `patches: [String]` and `dlc: [String]` (null decodes as empty);
  - `contentBytes: Int64`, `status: String`, `builtWith: String`, `lastPlayed: String` (ISO-8601 when set), `playSeconds: Int64`;
  - `extra: [String: JSONValue]` for unknown keys.
  
  Decoding reads every key through a dynamic CodingKey container: the known ones go to the fields and the rest to `extra`. Encoding writes `extra` first, then the known keys, so a known key always wins.
- **`LibraryFile`** has `version: Int` (missing = 1), `games: [GameRecord]` and `extra: [String: JSONValue]`. Decoding a `version` > 1 throws `LibraryError.newerVersion(Int)`.
- **`FileLock`** holds `flock(fd, LOCK_EX | LOCK_NB)`. `static func acquire(_ url: URL) async throws -> FileLock` polls every 100 ms and throws `CancellationError` when the task is cancelled. It creates the file with mode 0644, opens it with `O_CLOEXEC`, and `release()` closes it. `deinit` releases it too.
- **`LibraryStore`** is a Sendable struct with `root: URL`. It has:
  - `func snapshot() throws -> LibraryFile`: a lock-free read for display; a missing file is empty.
  - `func update(_ body: @Sendable (inout LibraryFile) throws -> Void) async throws`: acquire the lock, re-read, apply the body, write the temp file in root, `fsync`, rename, release.
  - `func uninstall(titleID: String) async throws -> Int64`: under the lock, measure and remove `games/<ID>/`, `pending/<ID>` and `pending/<ID>.json`, and remove the record. It returns the bytes freed. When `content` is a symlink, it removes the link, never the target.
  - `func gameDir`, `contentDir`, `buildDir`, `logsDir(titleID:)`, and `appBundle(titleID:) -> URL?`, the first `*.app` in the build dir.
  - TITLE_ID is validated with `^[A-Z]{4}[0-9]{5}$` before any path is built from it (`LibraryError.badTitleID`).

- [ ] **Step 1: Write the failing tests.**
  - **Round trip with unknown fields.** Write a library.json with `{"version":1,"x_top":1,"games":[{"title_id":"CUSA00557",…,"x_game":{"a":[1,2]}}]}`, then `update { $0.games[0].status = "playable" }`. Read it back as raw JSON: `x_top` and `x_game` are unchanged, `status` is updated, and no temp file is left.
  - **Newer version.** A `version: 2` file makes `update` throw `newerVersion(2)` and leaves the file unchanged byte for byte.
  - **null arrays.** `patches: null` decodes to `[]`.
  - **The lock excludes another holder.** Acquire `FileLock` in the test, then start `update` in a Task. It must not finish within 300 ms; it finishes after `release()`. Cancelling a waiting `update` throws `CancellationError`.
  - **Interop with the engine's lock.** Run `ps4-recomp import <synthetic folder> --library <root> --mode reference --json` (the real engine, built in the repo; `#require` it) while the test holds the lock. The engine must report the `lock` stage and finish only after release. Make the synthetic folder with the same param.sfo builder and a copy of `hello_world.elf`.
  - **Uninstall.** Make games/CUSA00557/content as a symlink to a temp folder holding a file, plus a build dir with 1000 bytes. After `uninstall`:
    - the record is gone and games/CUSA00557 is gone;
    - the symlink target folder and its file still exist;
    - the returned bytes are ≥ 1000.
  - **Bad TITLE_ID.** `"../x"` throws `badTitleID`.
- [ ] **Step 2: Run them and see them fail.** Then implement, using `Darwin` (`open`, `flock`, `fsync`, `rename`).
- [ ] **Step 3: Run the tests and see them pass. Commit** with "app: library store with the engine's lock contract".

---

### Task 7: Game settings and saves

**Files:**
- Create: `Sources/PS4NativeKit/Settings/Languages.swift`, `GameSettings.swift`, `Sources/PS4NativeKit/Saves/SaveStore.swift`
- Test: `Tests/PS4NativeKitTests/SettingsTests.swift`, `SavesTests.swift`

**Interfaces:**
- **Language table.** `Language` has `orbis: Int`, `code: String`, `title: String` and `pack: String`. `Languages.all` is the runtime's table, verbatim from `ps4_settings.m` `kLangs`:
  - ja 0 日本語 japanese, en 1 English english, fr 2 Français french, es 3 Español spanish, de 4 Deutsch german;
  - it 5 Italiano italian, nl 6 Nederlands dutch, pt 7 Português portuguese, ru 8 Русский russian, ko 9 한국어 korean;
  - zh 11 中文 chinese, fi 12 Suomi finnish, sv 13 Svenska swedish, da 14 Dansk danish, no 15 Norsk norwegian;
  - pl 16 Polski polish, pt-br 17 "Português (Brasil)" brazilian, tr 19 Türkçe turkish, es-la 20 "Español (Latinoamérica)" latam, ar 21 العربية arabic.
- **Available languages.** `Languages.available(content: URL) -> [Language]` follows the runtime's rule: those with `build/ps4/main/sound1/streams/speech/<pack>-sp.psarc` or a `<pack>` directory under the content dir; English alone when there are none.
- **`GameSettings`** is a Sendable, Equatable struct:
  - `lang: Int?` (nil = system default), `pro: Bool` (default true), `upscale: Bool` (default false), `hud: Bool` (default true), `metal: Int?` (3, 4 or nil = automatic);
  - `extraLines: [String]` keeps unknown `key=value` lines;
  - `static func load(titleID: String, settingsDir: URL) -> GameSettings` reads `<dir>/<TITLE_ID>.cfg`; missing means the defaults;
  - `func save(titleID:settingsDir:) throws` writes atomically: temp, then rename.
  - The format is the runtime's: `lang=%d\npro=%d\nupscale=%d\nhud=%d\n`, then `metal=%d` when set, then the extra lines. A nil `lang` writes no `lang` line.
  - `var launchEnvironment: [String: String]` is `["PS4_NO_DIALOGS": "1"]`, plus `PS4_GNM_METAL` when `metal` is set.
  - Recommended values come from the compat verdict (`recommended["pro"]` and so on); the view marks them. Add `func applying(recommended: [String: Int]) -> GameSettings`, used only when the user presses "Use recommended".
- **`SaveStore`** is a Sendable struct with `savesDir: URL` and `backupsDir: URL` (the library root's `backups/`). It has:
  - `func gameDirs(titleID:) -> [URL]`: directories ending in `" [<TITLE_ID>]"`, the newest first, the same rule as the runtime in Task 1.
  - `func slots(titleID:) -> [SaveSlot]`. A `SaveSlot` has `url`, `user` (the `user_XXXXXXXX` name), `name` (`SAVEDATA00`), `param: SaveParam?` and `bytes: Int64`.
  - `func backup(titleID:) throws -> URL`: `ditto -c -k --keepParent <game dir> <backups>/<TITLE_ID>-<yyyyMMdd-HHmmss>.zip`.
  - `func backups(titleID:) -> [URL]`.
  - `func restore(titleID:, from zip: URL) throws`: first `backup`, then move the current game dir to the Trash, then `ditto -x -k <zip> <savesDir>`.
  - `func export(titleID:, to: URL) throws`, the same as backup but to the chosen URL.
  - `func importZip(_:, titleID:) throws`, the same as restore.
  - `func deleteSlot(_:) throws`, which goes to the Trash.
  - `ditto` runs through `Process` with absolute paths. Its failures throw `SaveError.ditto(status, stderr)`.

- [ ] **Step 1: Write the failing tests.** Use temp dirs; never the real data dir.
  - **Settings round trip** with an unknown line `foo=1` kept; the defaults when there is no file.
  - **Exact file text** for `GameSettings(lang: 8, pro: false, upscale: true, hud: true, metal: 4)`: `"lang=8\npro=0\nupscale=1\nhud=1\nmetal=4\n"`.
  - **`launchEnvironment`** with metal nil and with metal 3.
  - **`available(content:)`** with a fake speech dir holding `russian-sp.psarc` and a `french` dir gives `[fr, ru]` in table order; English only when there is none.
  - **Saves layout.** Build `A [CUSA00557]/user_10000000/SAVEDATA01/sce_sys/param.bin` (1328 bytes, title "Joel") plus `USR-DATA`.
    - `slots` gives 1 slot with `param.title == "Joel"`.
  - **Backup, restore and delete.**
    - `backup` gives a zip.
    - Change USR-DATA, then `restore` from the zip. The content is back, and the backups list has 2 entries, because restore backed up first.
    - `deleteSlot` moves the slot to the Trash. In the test, use a `trash` closure injected into SaveStore that moves into a temp "trash" dir: SaveStore takes `trash: @Sendable (URL) throws -> Void`, defaulting to `FileManager.default.trashItem`.
- [ ] **Step 2: Run them and see them fail. Implement.**
- [ ] **Step 3: Run the tests and see them pass. Commit** with "app: game settings and save slots".

---

### Task 8: Launcher and operation queue

**Files:**
- Create: `Sources/PS4NativeKit/Launch/GameLauncher.swift`, `Sources/PS4NativeKit/Queue/OperationQueue.swift`
- Test: `Tests/PS4NativeKitTests/LauncherTests.swift`, `QueueTests.swift`

**Interfaces:**
- **`GameLauncher`** is `@MainActor @Observable`.
  - `func launch(titleID: String, app: URL, environment: [String: String], log: URL) throws` runs `<app>/Contents/MacOS/<CFBundleExecutable>` (read from the bundle's Info.plist) with the current environment merged with `environment`, and stdout and stderr appended to `log`.
  - `running: [String: RunningGame]`. A `RunningGame` has `pid`, `started: Date` and `titleID`.
  - `func stop(titleID:)` sends SIGTERM, then SIGKILL after `stopTimeout` (10 s by default, injectable for tests).
  - On exit it calls `onExit(titleID, seconds, status: ExitStatus)`. `ExitStatus` is `.normal`, `.code(Int32)` or `.signal(Int32)`; a SIGTERM from `stop` counts as normal.
  - A game is never launched twice.
  - The process launcher is injectable: `GameLauncher(spawn: …)`, defaulting to `Process`. Tests run `/bin/sleep`, a script that ignores SIGTERM, and `/usr/bin/false` through a fake bundle: a temp `.app` whose `Contents/MacOS/x` is a shell script and whose Info.plist names it.
- **`EngineOperationQueue`** is `@MainActor @Observable`.
  - `items: [OperationItem]`. An `OperationItem` is Identifiable, with:
    - `id`, `kind` (`.importGame`, `.analyze` or `.build`), `titleID: String?` and `title: String`;
    - `state`: `.queued`, `.running`, `.done`, `.failed(EngineFailure)` or `.cancelled`;
    - `stage: String`, `fraction: Double?` and `detail: String`;
    - `log: URL` and `created: Date`.
  - `func enqueue(kind:title:titleID:log:work: @escaping @Sendable (_ progress: @escaping @Sendable (EngineEvent) -> Void) async throws -> Void) -> OperationItem.ID` adds an item.
  - Items of kind `.build` run one at a time; `.importGame` and `.analyze` share a second lane that also runs one at a time. So one import and one build can run together, and nothing else.
  - The progress mapping:
    - `stage` is the event's stage;
    - `fraction` is done/total when total > 0, overall for `build` as (stageIndex + fileFraction) / 4: load, cfg and emit are 1/4, 2/4 and 3/4, and compile is 3/4 + files/total/4;
    - `detail` is the event message.
  - `func cancel(_ id:)` cancels the item's Task, which makes the engine get SIGINT. A queued item is removed with state `.cancelled`.
  - `func clearFinished()`.

- [ ] **Step 1: Write the failing tests.**
  - **Launcher:**
    - a launch puts the game in `running`, and a second launch throws;
    - `stop` of a TERM-ignoring script kills it after `stopTimeout` = 0.3 s, and `onExit` reports `.signal(9)`;
    - a normal exit reports `.normal` and seconds ≥ 0;
    - `/usr/bin/false` reports `.code(1)`;
    - the log file holds the script's stdout;
    - the environment reaches the child: the script echoes `$PS4_NO_DIALOGS`.
  - **Queue:**
    - two builds run one after the other, never two at once; track with an actor counter;
    - a build and an import run concurrently;
    - the progress mapping gives the expected fractions for the recorded `build.jsonl` (FakeEngine with delay);
    - cancelling a running build gives `.cancelled` (a FakeEngine cancel ends with the cancelled error, mapped to `.cancelled`, not `.failed`);
    - a failing work gives `.failed` with its code.
- [ ] **Step 2: Run them and see them fail. Implement.**
- [ ] **Step 3: Run the tests and see them pass. Commit** with "app: game launcher and operation queue".

---

### Task 9: AppModel: add flow, build, play, rebuild offers, uninstall, first run

**Files:**
- Create: `Sources/PS4NativeKit/Model/AppModel.swift`, `AddFlow.swift`, `Sources/PS4NativeKit/Environment/Toolchain.swift`
- Test: `Tests/PS4NativeKitTests/AppModelTests.swift`, `ToolchainTests.swift`

**Interfaces:**
- **`Toolchain`:**
  - `struct ToolchainReport { clangVersion: Int?; sdkVersion: Int?; freeBytes: Int64; problems: [String] }`.
  - `static func check(library: URL, run: (String, [String]) throws -> String = Toolchain.shell) -> ToolchainReport`:
    - `xcrun --find clang` and `clang --version`: the major from "Apple clang version N";
    - `xcrun --show-sdk-version`: the major;
    - free space from `URLResourceValues.volumeAvailableCapacityForImportantUsage`.
  - Problems:
    - "Command Line Tools are not installed" (xcrun fails);
    - "clang N is too old (17 or later needed)";
    - "the macOS SDK N is too old (26 or later needed)";
    - "less than 30 GB free on the library volume".
  - `static func installCommandLineTools()` runs `xcode-select --install`, which shows Apple's installer; the user acts in it.
- **`AppModel`** is `@MainActor @Observable`. It is created with `AppModel(paths:, engine: any Engine, launcher:, queue:, library: LibraryStore, saves: SaveStore)`. It has:
  - `games: [GameRecord]`, from `library.snapshot()`, refreshed after every operation and on `refresh()`;
  - `selection: String?` and `engineVersion: String?`, from `engine.version()` at start;
  - `toolchain: ToolchainReport?` and `firstRunNeeded: Bool`. That is true when the library is empty and no `firstRunDone` key is in `UserDefaults`. Inject the defaults so tests use a suite.
- **Add flow** (`AddFlow`):
  - `func add(_ urls: [URL])` calls `inspect` for each URL concurrently, at most 4 at a time. Each one gives an `AddCandidate` with `url` and `inspect: InspectResult`, `error: EngineFailure?` and `neededBytes = unpacked_size + 1 GiB` (folders in reference mode: 0 + 1 GiB). `pendingCandidates: [AddCandidate]` is shown by the add sheet.
  - `func confirm(_ c: AddCandidate, mode: ImportMode)` enqueues `.importGame`. When it succeeds, it enqueues `.analyze` for a game (or for the base game after a patch), unless the import was pending. The analysis result is written into the record's `status` with `library.update`, and kept in `analyses[titleID]` for the page.
  - Retail candidates (`signing == "retail"`) cannot be confirmed: the UI shows the engine's message. An `unsupported_input` status is shown for retail, bad_pkg and an error with no eboot.
  - `spaceShort(_ c:)` is true when `neededBytes` exceeds the free space of the library volume.
- **Build:** `func build(_ titleID:)` enqueues `.build` with the log `logs/<yyyy-MM-dd_HH-mm-ss>-build.log`. When it succeeds, it writes `builtWith` with `library.update`.
- **Play:** `func play(_ titleID:)` uses `GameSettings.load(…).launchEnvironment` and the log `logs/<date>-run.log`. On exit it adds `seconds` to `playSeconds`, sets `lastPlayed` to ISO-8601 now, and saves with `library.update`. A crash exit sets `lastCrashLog[titleID] = log`.
- **Offers:**
  - `func rebuildOffer(_ g: GameRecord) -> String?` returns "Rebuild available: v<built> → v<engine>" when `builtWith` is non-empty and differs from `engineVersion`, and "Rebuild needed after the update" when `status == ""` and a build exists. Otherwise nil.
  - `func primaryAction(_ g:) -> PrimaryAction` returns `.play`, `.build`, `.rebuild` or `.running`.
  - `isBusy(titleID)` blocks Rebuild and Uninstall while the game runs or has a queued or running operation.
- **Uninstall:** `func uninstall(_ titleID:, keepSaves: Bool) async throws -> Int64` calls the library uninstall, and with `keepSaves == false` also moves `saves.gameDirs(titleID)` to the Trash.
- **Shortcut:** `func addToApplications(_ titleID:) throws` creates the symlink `/Applications/<TITLE>.app` → the built `.app`, replacing an existing link of ours and never a real app.
- **First-run import:** `func importExistingFolder(_ url: URL)` is `add([url])` with the reference mode preselected.

- [ ] **Step 1: Write the failing tests** with FakeEngine, a temp library, a temp data dir and a fake launcher. For the add-flow tests, add to `FakeEngine` (Task 5's file) an `afterRun` hook so it creates the library entries it reports: a hook that writes the `game` object of the `done` result into `library.json` through `LibraryStore.update`. This mimics the engine's side effect.
  - add game.pkg, then confirm gives an import followed by an analysis, the record with `status == "playable"` (from the fixture), and the queue items done;
  - a retail candidate cannot be confirmed;
  - add of 3 URLs gives 3 candidates;
  - build then sets `builtWith` from the fixture, and `primaryAction` is `.play`;
  - play, then the fake game exits after 1 s, gives `playSeconds ≥ 1` and `lastPlayed` set;
  - a crash exit sets `lastCrashLog`;
  - `rebuildOffer` with builtWith "0.2.0" and engine "0.3.0" gives the offer text;
  - an empty status after a patch gives "Rebuild needed after the update";
  - uninstall while running throws `AppError.busy`;
  - uninstall with keepSaves false moves the save dir to the injected trash;
  - `Toolchain.check` with a fake `run` returning "Apple clang version 21.0.0" / "27.1" reports no problems; "Apple clang version 16.0.0" / "15.4" reports two problems; a throwing `run` reports the CLT problem.
- [ ] **Step 2: Run them and see them fail. Implement.**
- [ ] **Step 3: Run the tests and see them pass. Commit** with "app: AppModel with add, build, play, offers and first run".

---

### Task 10: SwiftUI views (layout A)

**Files:**
- Modify: `Sources/PS4Native/PS4NativeApp.swift`
- Create, all in `Sources/PS4NativeUI/` as public types: `RootView.swift` (replacing Task 4's), `SidebarView.swift`, `GamePageView.swift`, `GameHeroView.swift`, `OverviewTab.swift`, `SettingsTab.swift`, `SavesTab.swift`, `DLCTab.swift`, `BuildLogTab.swift`, `AddGameSheet.swift`, `QueueView.swift`, `FirstRunView.swift`, `UninstallSheet.swift`, `StatusBadge.swift`

**Interfaces:**
- Consumes `AppModel` and everything in PS4NativeKit. Views hold no logic beyond formatting and calls into the model. Any new logic belongs to the model, with a test there.
- **Window** (`RootView`):
  - a `NavigationSplitView` with a sidebar and a detail pane;
  - a toolbar with **＋ Add game**, which opens an `NSOpenPanel` that allows `.pkg` files and folders, multiple selection; plus a queue indicator (a spinner and a count when items run);
  - `.dropDestination(for: URL.self)` on the whole window calls `model.add(urls)`;
  - `.preferredColorScheme(.dark)`;
  - minimum size 1000×640.
- **Sidebar:**
  - Section "Games": each row has the icon (`content/sce_sys/icon0.png`, falling back to a generic SF Symbol `gamecontroller`), the title and a `StatusBadge`. The badges are OK (playable, green), WIP (in_progress, yellow), VER (other_version, orange), EXP (experimental, purple) and ? (no status yet, grey).
  - Section "Manager": *Builds & imports* (the QueueView), *Saves* (all games' saves, a list grouped by game, reusing SavesTab per game) and *Settings* (app-wide: the library location shown read-only, the engine version, the toolchain report with "Check again" and "Install Command Line Tools").
- **Game page:**
  - **Hero.** The image is `content/sce_sys/pic1.png`, else `pic0.png`, else icon0 scaled up and blurred (`.blur(radius: 30)`), with a dark gradient. Over it: the title, then "TITLE_ID · v<app_ver> · <status name>".
  - **Action bar.**
    - The primary button is the large **▶ PLAY** (green), **Build** or **Rebuild**. While the game runs it shows "Running 12:34" (a `TimelineView` showing the session time) and a **Stop** button.
    - Next to it: **Settings** (selects the tab), **Saves** (selects the tab), and a **⋯** menu with Show in Finder, Open build log, Add to Applications, Analyze again and Uninstall….
    - On the right: "Built · <size of the build dir>" or "Not built".
    - The rebuild offer appears as a banner under the bar when there is one.
    - After a crash, a banner says "The game quit unexpectedly" with "Open log".
  - **Tabs** (a segmented `Picker` with a switch):
    - **Overview:** last played, play time, renderer setting, the known issues and tested versions from the analysis, the coverage and unresolved numbers, and the content size.
    - **Settings:** language (`Languages.available(content:)` plus "System default"), PS4 Pro mode, MetalFX upscaling, FPS counter (Metal HUD), and renderer (Automatic / Metal 3 / Metal 4). Recommended values carry a "recommended" caption and there is a "Use recommended" button. Changes save immediately.
    - **Saves:** a slot list (title, subtitle, date, size) with Backup, Restore… (a list of backups or a file), Export…, Import… and Delete slot (a confirmation dialog, to the Trash). It shows "No saves yet" when there are none.
    - **DLC & updates:** the installed version, the applied patches, the DLC labels, and **Add update or DLC…**, which opens the same add flow.
    - **Build log:** the newest build log in a monospaced, scrollable text view, with "Show in Finder".
- **Add sheet.**
  - For each candidate: the icon, title, version and kind ("Game", "Update", "DLC", "Folder").
  - The signing: retail shows a red "This PKG is encrypted with console keys; use a dump of your own console or an fpkg" message and a disabled Import button.
  - The disk space needed against the free space, with a warning when short.
  - For folders, a picker: "Copy into the library (APFS clone)" or "Use in place".
  - Import buttons, one per candidate and "Import all".
- **Queue view:** a list of items with the kind, title, stage, a `ProgressView(value:)` with the fraction (or indeterminate), the detail, Cancel (while queued or running), Show log, and "Clear finished".
- **First run:** shown as a sheet when `firstRunNeeded`. It shows:
  - the toolchain report, with "Install Command Line Tools" when that is the problem;
  - the free space;
  - "Import existing game folder…", which opens a folder picker and calls `importExistingFolder`;
  - "Done", which stores `firstRunDone`.
- **Uninstall sheet:** "Remove <title>? This frees <GB>.", with a "Keep saves" toggle (on by default), and Remove / Cancel buttons.
- **App entry:** `PS4NativeApp` is `@main`. It builds `AppModel` from the real `Paths`, a `ProcessEngine` on `paths.engineExecutable` and the real stores. When the engine kit is missing, it shows a clear error view naming the expected path.
  - With `--smoke <fixtures dir>` it builds `AppModel` with `FakeEngine` instead and runs `SmokeRunner` (Task 11).

- [ ] **Step 1: Read the model API** (Task 9) and write the views. Keep each file under about 200 lines. Use `@Bindable var model: AppModel`. Use SF Symbols only, no image assets. Format sizes with `ByteCountFormatter` and durations with `Duration.formatted`.
- [ ] **Step 2: Build the app target.** Run `swift build --package-path app/PS4Native`. Fix every warning in the app target: Swift 6 strict concurrency stays on.
- [ ] **Step 3: Write a model-driven render test.** In `Tests/PS4NativeKitTests/RenderTests.swift`, build a model with FakeEngine holding one playable and one experimental game, render `RootView` through `ImageRenderer` at 1200×760, assert that a non-empty `CGImage` is produced, and write it to `$TMPDIR/ps4native-render.png` for the report. Also render `AddGameSheet` with a retail candidate.
  - The test renders `RootView` with one playable game and one experimental game at 1200×760. It asserts that a non-empty `CGImage` is produced, and writes it to `$TMPDIR/ps4native-render.png` for the report.
  - It also renders `AddGameSheet` with a retail candidate.
- [ ] **Step 4: Run all package tests, and commit** with "app: SwiftUI views (Steam-like layout A)".

---

### Task 11: Packaging, smoke run, docs

**Files:**
- Create: `app/PS4Native/scripts/package.sh`, `app/PS4Native/scripts/smoke.sh`, `app/PS4Native/scripts/make-icon.swift`, `Sources/PS4NativeKit/Smoke/SmokeRunner.swift`
- Create: `docs/game-manager-app.md`; Modify: `README.md` (a section "PS4 Native app (preview)" next to the engine section)
- Test: `Tests/PS4NativeKitTests/SmokeRunnerTests.swift`

**Interfaces:**
- **`SmokeRunner`** (in Kit, so it is tested).
  - `func run(model: AppModel, fixturesSource: URL) async -> SmokeReport` drives the model through these steps:
    1. add `game.pkg`;
    2. confirm;
    3. wait for the import and the analysis;
    4. build;
    5. play, with a launcher whose spawn runs `/bin/sleep 1` instead of the game;
    6. wait for the exit;
    7. check `playSeconds ≥ 1`.
  - Each step is recorded with pass/fail and duration in `SmokeReport: Codable`.
  - The app in `--smoke` mode then renders `RootView` through `ImageRenderer` to `<out>/window.png`, writes `<out>/smoke.json`, and exits 0 when every step passed and 1 otherwise.
- **`package.sh [--version X]`:**
  1. Run `tools/make_engine_kit.sh` into `dist/engine`.
  2. Run `swift build -c release --package-path app/PS4Native`.
  3. Assemble `dist/PS4 Native.app`:
     - `Contents/MacOS/PS4Native`;
     - `Contents/Info.plist`: CFBundleIdentifier `org.ps4native.manager`, CFBundleName "PS4 Native", CFBundleShortVersionString from `--version` or the engine `Version`, LSMinimumSystemVersion 26.0, NSHighResolutionCapable, LSApplicationCategoryType `public.app-category.games`;
     - `Contents/Resources/AppIcon.icns`, generated by `make-icon.swift` (CoreGraphics draws a simple gamepad glyph on a dark rounded square at every iconset size, then `iconutil -c icns`);
     - `Contents/Resources/engine/` (the kit).
  4. Sign: `xattr -cr`, `codesign --force --deep --sign - "dist/PS4 Native.app"`, `codesign --verify --deep --strict`.
  5. Make the disk image: `hdiutil create -volname "PS4 Native" -srcfolder <staging with the app and an /Applications symlink> -ov -format UDZO dist/PS4Native-<version>.dmg`.
  6. Print the sizes and the sha256.
- **`smoke.sh`:**
  1. Run `package.sh`.
  2. Run `"dist/PS4 Native.app/Contents/MacOS/PS4Native" --smoke <fixtures> --out <scratch>` with `PS4NATIVE_LIBRARY` and `PS4RECOMP_DATA_DIR` set to scratch dirs, under `timeout -k 10 300`.
  3. Check exit 0 and that `window.png` exists.
  4. Mount the dmg read-only (`hdiutil attach -nobrowse -readonly`), check the app inside verifies with codesign, then detach.
  5. Remove the scratch dirs.

- [ ] **Step 1: Write the `SmokeRunnerTests`** (FakeEngine, temp dirs; all steps pass; a failing build fixture makes the report fail at "build"). See them fail, then implement `SmokeRunner`.
- [ ] **Step 2: Write `make-icon.swift`, `package.sh` and `smoke.sh`** (`set -euo pipefail`, absolute paths, `cd … || exit 1`). Run `smoke.sh` and record its output: the steps, the sizes, the dmg sha256. Look at `window.png` (Read tool) and describe it in the report.
- [ ] **Step 3: Real-engine acceptance, no game launch.**
  - Run the packaged app's engine kit directly, the same commands the app issues, against the owner's TLOU dump folder in reference mode, into a scratch library on the game dump's volume: inspect, import, analyze-game and a build under heavy_lock.
  - Check that the built game links no `/opt/homebrew` path (`otool -L`): this is the point of the bundled FreeType.
  - Then delete the scratch library, after checking that `content` is a symlink.
  - Never launch the game. The owner does the play test from the app.
- [ ] **Step 4: Write the docs.**
  - `docs/game-manager-app.md` covers:
    - building and testing (`swift test`), recording fixtures, packaging (`package.sh`), the smoke test;
    - the env overrides (`PS4NATIVE_ENGINE`, `PS4NATIVE_LIBRARY`, `PS4RECOMP_DATA_DIR`);
    - where everything lives;
    - the bundled tools and their licences;
    - the play test checklist for the owner: add the TLOU folder, build, play, saves visible, settings honoured, the Metal 4 choice honoured.
  - Add a README paragraph.
- [ ] **Step 5: Run everything and commit.**
  - Run `swift test --package-path app/PS4Native`, `go test ./pkg/...`, `go vet ./...` and `gofmt -l pkg cmd tools`.
  - Commit `app/PS4Native/scripts/*`, `SmokeRunner.swift`, its test, `docs/game-manager-app.md` and `README.md` with "app: packaging, smoke run and docs". `dist/` stays untracked (gitignored).
