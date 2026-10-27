# PS4 Native app

PS4 Native is the macOS app that manages a library of your own PS4 games and drives the
`ps4-recomp` engine for them: add, import, analyse, build, play, saves and settings. It is a
SwiftUI app in `app/PS4Native`. The protocol it speaks to the engine and the library layout it
shares with it are in [game-manager-engine.md](game-manager-engine.md).

## Layout of the package

`app/PS4Native` is a Swift package (Swift 6, macOS 26) with three targets:

| Target | Holds |
|---|---|
| `PS4NativeKit` | Everything that is not a view: the engine client (`ProcessEngine`, and `FakeEngine` that replays recorded streams), the library store and its lock, settings, saves, the launcher, the operation queue, the toolchain check, the view model (`AppModel`) and the smoke runner. |
| `PS4NativeUI` | The SwiftUI views: sidebar, game page and its tabs, add sheet, queue, first run, app settings. |
| `PS4Native` | The executable: the `App`, and `--smoke` mode. |

The tests (`Tests/PS4NativeKitTests`) cover the kit and render the views offscreen.

## Building and testing

```sh
swift build --package-path app/PS4Native
swift test  --package-path app/PS4Native
```

The tests need no engine and no game. They run the model on `FakeEngine`, which replays the
recorded `--json` streams in `Tests/PS4NativeKitTests/Fixtures/`, in temp libraries and data dirs.
`RenderTests` draws the views with ImageRenderer into `$PS4NATIVE_RENDER_DIR` (the temp dir by
default). `WindowCaptureTests` opens real windows and captures them with `screencapture`, so it
is opt-in: `PS4NATIVE_RENDER_WINDOWS=1 swift test --package-path app/PS4Native --filter WindowCaptureTests`.

To run the app from source, point it at a built engine (an engine kit or the repository root
with a built `ps4-recomp`):

```sh
PS4NATIVE_ENGINE=/path/to/engine-kit-or-repo-root swift run --package-path app/PS4Native
```

### Recording the fixtures

`app/PS4Native/scripts/record-fixtures.sh` re-records the fixtures from the real engine. It builds
`ps4-recomp` and `tools/gmfixtures`, writes a synthetic content folder and fake PKGs into a scratch
directory, runs each command with `--json` and replaces the scratch paths with the placeholders
`FakeEngine` substitutes (`$LIB`, `$SRC`, `$TMP`). It needs `hello_world.elf` in the repository
root, and the build step is a real recompilation that takes a few minutes. Re-record after a change
to the engine's events or results.

## Packaging

```sh
app/PS4Native/scripts/package.sh [--version X]
```

The outputs go to `$PS4NATIVE_DIST`, by default `ps4native-dist` next to the repository. It must
lie outside the repository, because the engine kit script refuses an out dir inside it. The script:

1. builds the engine kit into `<dist>/engine` with `tools/make_engine_kit.sh`. The kit holds
   `ps4-recomp`, the runtime sources, the 3rdparty static libraries, ninja and FreeType, and ends
   with a self-check: a build of `hello_world.elf` with no Homebrew in `PATH`, whose binary must
   not link anything under `/opt/homebrew`;
2. builds the app with `swift build -c release`;
3. assembles `<dist>/PS4 Native.app`: the executable, `Info.plist` (`org.ps4native.manager`, the
   version from `--version` or the engine's `version`, macOS 26.0 minimum), `AppIcon.icns` drawn
   by `scripts/make-icon.swift` (a generic gamepad on a dark rounded square, CoreGraphics only)
   and the kit in `Contents/Resources/engine`;
4. signs it ad hoc (`codesign --force --deep --sign -`) and verifies it with `--deep --strict`.
   The app is not notarized, so on another Mac Gatekeeper blocks the first launch of a
   downloaded copy; allow it in System Settings, Privacy & Security, "Open Anyway";
5. makes `<dist>/PS4Native-<version>.dmg`, with the app and a link to `/Applications`;
6. prints the sizes and the disk image's SHA-256.

## The smoke test

```sh
app/PS4Native/scripts/smoke.sh [--version X]
```

`smoke.sh` runs `package.sh`, then tests the package:

1. It runs `"PS4 Native.app/Contents/MacOS/PS4Native" --smoke <fixtures> --out <dist>/smoke`
   with `PS4NATIVE_LIBRARY` and `PS4RECOMP_DATA_DIR` on scratch directories, under
   `timeout -k 10 300`. In `--smoke` mode the app runs its model on `FakeEngine` over the
   fixtures, and on a launcher that runs `/bin/sleep 1` in place of the game, so neither the
   bundled engine nor any game runs. `SmokeRunner` then drives the model as a user would: add
   `game.pkg`, confirm, wait for the import and the analysis, build, play, wait for the exit and
   check that at least one second of play time was recorded. The app refuses `--smoke` unless
   both directories are overridden, so a smoke run never touches the real library or saves.
2. It checks that the app exited 0 and wrote `window.png` and `smoke.json` to `<dist>/smoke`.
   `smoke.json` lists each step with pass or fail, its duration and a detail. `window.png` is the
   game page the run ends on, drawn in an offscreen window. It is the page rather than the whole
   window because the sidebar's vibrancy does not draw offscreen.
3. It mounts the disk image read-only, checks the `/Applications` link and verifies the app's
   signature inside it, then detaches it and removes the scratch directories.

## Environment overrides

| Variable | Default | Effect |
|---|---|---|
| `PS4NATIVE_ENGINE` | `PS4 Native.app/Contents/Resources/engine` | The directory that holds `ps4-recomp`: an engine kit, or the repository root for a development run. |
| `PS4NATIVE_LIBRARY` | `~/Library/Application Support/PS4Native` | The library root. It must be on APFS (or another volume with extended attributes); see the note below. |
| `PS4RECOMP_DATA_DIR` | `~/Library/Application Support/PS4Recomp` | The runtime's data dir: saves and per-game settings. The game inherits it. |
| `PS4_SAVEDATA_DIR` | `<data dir>/saves` | The saves directory alone, as the runtime reads it. |

Use the overrides for every automated run, so it never touches the owner's library or saves.

**The library must be on APFS**, or another volume that has extended attributes. On exFAT or FAT
(a typical external drive), macOS writes a `._<name>` AppleDouble sidecar next to every file with
an extended attribute. The engine's `xattr -cr` and the code signing of `eboot.app` then fail, so
every build fails after the compile. The default library is on the internal disk, so this only
matters when `PS4NATIVE_LIBRARY` moves it. A game folder used in place may stay on any volume:
only `build/` has to be on APFS.

## Where everything lives

| What | Where |
|---|---|
| The app | `/Applications/PS4 Native.app`, copied from the disk image. |
| The engine | `PS4 Native.app/Contents/Resources/engine` (`ps4-recomp`, `pkg/runtime`, `3rdparty`, `bin/ninja`, `licenses`). |
| The library | On APFS only (see the note under the overrides). `~/Library/Application Support/PS4Native/`: `library.json`, `games/<TITLE_ID>/` with `content/` (a symlink for a folder used in place), `build/` (the built `.app`), `logs/` (build, run and analysis logs) and `analysis.json`. Import logs are in `logs/`, save backups in `backups/`. |
| Saves | `~/Library/Application Support/PS4Recomp/saves/`, where the runtime keeps them. An uninstall moves them to the Trash only when asked to. |
| Per-game settings | `~/Library/Application Support/PS4Recomp/settings/<TITLE_ID>.cfg`: `lang`, `pro`, `upscale`, `hud` and `metal`, read by the runtime when the game starts, however it is started (`metal` becomes `PS4_GNM_METAL` when the environment has none). Lines the app does not know are kept, by the app and by the runtime's own settings window. |
| App preferences | The defaults domain `org.ps4native.manager` (the first-run flag). |
| Shortcuts | "Add to Applications" puts a symlink to the built game in `/Applications`; uninstall removes it. A game started from the shortcut (or the Dock) uses its settings file, but the app does not see the session: its play time is not recorded, and the runtime's settings window opens when Option is held. |

## Bundled tools and their licences

The engine kit bundles everything a game build needs apart from Apple's Command Line Tools. Each
licence text ships in the kit.

| Component | Licence | Text in the kit |
|---|---|---|
| ps4-recomp and its runtime | GPL-2.0-or-later | `LICENSE` |
| gcn-recompiler | GPL-2.0 | `3rdparty/gcn-recompiler/LICENSE` |
| Boost (in gcn-recompiler) | BSL-1.0 | `licenses/gcn-recompiler/boost-LICENSE_1_0.txt` |
| fmt (in gcn-recompiler) | MIT | `licenses/gcn-recompiler/fmt-LICENSE` |
| magic_enum (in gcn-recompiler) | MIT | `licenses/gcn-recompiler/magic_enum-LICENSE` |
| sirit (in gcn-recompiler) | BSD-3-Clause | `licenses/gcn-recompiler/sirit-LICENSE.txt` |
| SPIRV-Headers (in sirit) | MIT-style (Khronos) | `licenses/gcn-recompiler/SPIRV-Headers-LICENSE` |
| SPIRV-Cross | Apache-2.0 (with MIT and Khronos parts) | `3rdparty/spirv-cross/LICENSE`, `licenses/spirv-cross/` |
| LibAtrac9 | MIT | `3rdparty/libatrac9/LICENSE` |
| minimp3 | CC0-1.0 | `3rdparty/minimp3/LICENSE` |
| FreeType 2 (static) | FTL or GPLv2; used under GPLv2 | `3rdparty/freetype/LICENSE.TXT`, `3rdparty/freetype/NOTICE` |
| libpng (static, for FreeType) | libpng License v2 | `licenses/libpng-LICENSE` |
| ninja | Apache-2.0 | `licenses/ninja-COPYING` |

## Play test checklist

The packaged app's real path (a real engine, a real game) is the owner's play test:

1. Open the disk image, drag **PS4 Native** to Applications and open it.
2. First run: the toolchain check passes (or offers the Command Line Tools), and the library is
   empty.
3. **Add the TLOU folder** (`CUSA00557`) with "Use in place". The card shows the title, the
   version and the space needed. After the import and the analysis, the game shows its support
   badge, and `games/CUSA00557/content` is a symlink to the folder, which is left untouched.
4. **Build.** The queue shows the stages and the compile progress; the build log tab shows the log.
   The game page then offers PLAY.
5. **Play.** The game starts and runs. On quit, Last played and Play time update.
6. **Saves visible.** The Saves tab lists the existing TLOU saves; a backup appears in the list.
7. **Settings honoured.** Change the language or PS4 Pro mode, or turn the FPS counter (HUD) on or
   off, then start the game: it uses the new values.
8. **Metal 4 choice honoured.** Set the renderer to Metal 4 and start the game: the run log
   (Build log tab, **Run**) has the line `[gnm-draw] backend metal4 (...)`. Set it back to Automatic or Metal 3 afterwards.
