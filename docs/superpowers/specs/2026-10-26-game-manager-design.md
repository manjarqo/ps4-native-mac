# PS4 Native: a game manager for macOS

Date: 2026-10-26. Status: approved by the owner (design sections 1–4, library layout A).

## Goal

A native macOS app, **PS4 Native**, in which a user adds a PS4 game as a PKG or as a dumped folder, gets told whether it is supported, builds the native version with one click, and then manages and plays it. The layout follows Steam Desktop. Managing a game here means: install (import and build), uninstall, saves, settings and launch. In this spec, "game mode" means exactly that set of management functions; it is not a full-screen mode.

Out of scope for this spec:
- a full-screen controller-driven mode (Big Picture style);
- online updates of the compatibility database;
- cover art from the internet;
- Apple notarization;
- retail-encrypted PKGs.

## Inputs the manager accepts

- **Fake-signed PKG (fpkg):** a base game (`CATEGORY gd`), a patch (`gp`), or additional content / DLC (`ac`). A patch and its base can arrive in either order.
- **A dumped game folder:** `eboot.bin`, `sce_sys/param.sfo`, `sce_module/`.
- **Retail PKGs** are encrypted with console keys. They are detected and rejected with this message: "this PKG is encrypted with console keys; use a dump of your own console or an fpkg". The manager never tries to decrypt them.

## Architecture

Approach A (approved): a SwiftUI app plus the `ps4-recomp` engine in a separate process.

- **`PS4 Native.app`** (SwiftUI, macOS 26+, dark appearance). It bundles:
  - the build kit from the release (`ps4-recomp`, `pkg/runtime`, `3rdparty/` with the prebuilt libraries);
  - its own `ninja` and `freetype`, so Homebrew is not needed.
- **Engine.** `ps4-recomp` gets new subcommands. Each one, with `--json`, writes one JSON event per line to stdout: `{"event":"progress"|"warning"|"error"|"done", ...}`. The exit code is 0 on success. An engine crash never takes the UI down: the UI shows the last event and the full log.
  - `inspect <pkg|folder>`: reads the PKG header and entries in well under a second. It reports:
    - the kind (game / patch / DLC) and the signing (fake / retail);
    - `TITLE_ID`, `CONTENT_ID`, `APP_VER`, `VERSION`, `CATEGORY` and the title;
    - icon0 extracted to a temp path;
    - packed size and unpacked size.
  - `import <pkg|folder> --library <dir>`:
    - It extracts the PFS image of an fpkg, including PFSC-compressed images, into the library.
    - A patch is applied over its base game: patch files replace base files, and `APP_VER` is updated.
    - DLC is extracted into `content/addcont/<entitlement>`, the directory the runtime already scans (`libSceAppContent`).
    - A dumped folder is cloned (APFS clone when it is on the same volume) or referenced in place, as the user chooses.
    - Progress is reported in bytes and files.
    - The import can be cancelled and resumed. Work goes to `content.partial/` and is renamed only on success. On resume, files whose size and hash match are skipped.
  - `analyze-game <content dir>`:
    - It reads param.sfo with a new Go reader.
    - It runs the existing analysis of `eboot.bin` and the modules, which reports unresolved HLE imports and the like.
    - It looks the game up in `compat.json` and returns a status (below), the recommended settings and the known issues.
  - `build <content dir> -o <build dir>`: today's pipeline, plus:
    - JSON progress for stages 1–4 (load, CFG, emit, compile with per-file counts);
    - an `Info.plist` from the SFO (display name = TITLE, version = APP_VER, bundle id `org.ps4native.<TITLE_ID>`);
    - automatic ad-hoc `codesign` with verification;
    - the app baked to its content dir, so it needs no `--app-dir` at run time.
- **`compat.json`** is bundled in the app and updated with each release. It maps TITLE_ID → name, tested versions, status, recommended settings (for example `pro=0` for U4) and known issues. It starts with TLOU CUSA00557 (playable) and U4 CUSA04529 v1.32 (in progress).

### Support statuses

| Status | Rule | UI |
|---|---|---|
| Playable | TITLE_ID and APP_VER in compat.json as playable | Green badge; build allowed |
| In progress | TITLE_ID/APP_VER listed as in progress | Yellow badge; known issues shown; build allowed |
| Other version | TITLE_ID known, APP_VER not | Shows the tested versions; build allowed with a warning |
| Experimental | TITLE_ID unknown | Purple badge; "Build anyway" shows the analysis report first |
| Unsupported input | retail PKG, broken PKG, no eboot.bin | Error; no build |

## Storage

Root: `~/Library/Application Support/PS4Native/`.
- `library.json` is the game list, with status, version, sizes, last played and play time.
- `games/<TITLE_ID>/` contains:
  - `content/`: the extracted game with patches applied, and DLC in `content/addcont/`;
  - `build/`: the build dir with the signed `.app`;
  - `logs/`: build logs and game run logs by date.
- Saves and per-game settings stay where the runtime keeps them today: `~/Library/Application Support/PS4Recomp/saves/…` and `settings/<game>.cfg`. Existing saves therefore keep working.
- Writes of `library.json` and `.cfg` files are atomic (a temp file, then `mv`).

## UI (layout A: Steam Desktop style)

- **Window.**
  - The left sidebar lists the games, each with an icon, its name and a status badge (OK / WIP / EXP). Below them come the manager sections: *Builds & imports*, *Saves*, *Settings*.
  - The right pane is the selected game's page:
    - a hero image (`pic0/pic1` from sce_sys, falling back to a blurred icon0) with the title, TITLE_ID, version and status;
    - a large **▶ PLAY** button (or **Build** / **Rebuild**), plus Settings, Saves and ⋯;
    - the tabs *Overview*, *Settings*, *Saves*, *DLC & updates*, *Build log*.
  - **＋ Add game** sits in the toolbar. Drag and drop of PKGs or folders onto the window works too, several at once.
- **Add flow:**
  1. `inspect`.
  2. A confirmation card shows the cover, title, version, kind and the disk space needed (unpacked size plus about 1 GB for the build). It warns before starting if space is short.
  3. `import` with a progress bar.
  4. `analyze-game`, and the status badge appears.
  5. The **Build** button.
- **Builds & imports:** a queue. Builds run one at a time, because a build is about two minutes of full CPU load. Each entry shows its stage and percent, with Cancel and Show log.
- **Rebuild offers.**
  - The manager offers a rebuild when the bundled recompiler is newer than the one that built the game ("Rebuild available: v0.3.0 → v0.4.0").
  - It also offers one after a patch is applied.
- **Settings tab:**
  - language, Pro mode, MetalFX, HUD and the Metal 3/4 backend;
  - all written to the runtime's `settings/<game>.cfg`;
  - recommended values from compat.json are marked.

  The game's own launch dialog is suppressed (`PS4_NO_DIALOGS=1`) when it is started from the manager.
- **Saves tab:**
  - slots with title, subtitle (chapter), date and size, read from each slot's `sce_sys/param.sfo`;
  - backup, restore, export to and import from zip, and delete slot;
  - restore always backs up the current state first.
- **DLC & updates tab:** the installed version, the applied patches, the DLC list and an Add button.
- **Uninstall:** removes `games/<TITLE_ID>/` and shows how many GB that frees. "Keep saves" is on by default.
- **Launch.**
  - ▶ PLAY opens the `.app` with the manager's environment. While it runs, the page shows "Running", the session time and **Stop**: a polite close, then terminate after a timeout.
  - Play time and last played go to `library.json`.
  - Output goes to `logs/<date>.log`. After a crash the page offers to open the log.
- **Shortcut:** an optional "Add to Applications" copies or links the built `.app` into `/Applications`, with the SFO title and icon.
- **First run:**
  - Check Xcode Command Line Tools (clang 17+ with the macOS 26 SDK). If they are missing, offer "Install" (`xcode-select --install`).
  - Check free disk space.
  - Offer to import existing game folders that the old `PS4Recomp` setup used.

## Error handling

- Every engine operation is a separate process. A crash, a non-zero exit or a lost event stream shows the last event and the log, and the operation's partial output is removed.
- A broken PKG, an unknown format, a retail PKG or a full disk each give a clear message, and partial extraction is deleted.
- Deletion touches only `games/<TITLE_ID>/`. Saves are deleted only when the user explicitly asks.
- A running game blocks Rebuild and Uninstall for that game.

## Testing

- **Go engine.**
  - PKG and PFS parsing is tested on small synthetic fpkgs produced by a test generator: a known file tree, with and without PFSC compression.
  - Also tested: rejection of retail-style packages, the SFO reader, patch overlay, DLC layout, compat lookup and every status, and the JSON event format.
  - No game data is in the repository.
- **Swift app.**
  - Models and storage are tested against a fake engine that replays recorded JSON event streams.
  - XCUITest covers add → build → play with the fake engine.
- **Manual acceptance on real games:**
  - TLOU, from the owner's fpkg or dump folder, goes from import to gameplay.
  - U4 v1.32 is imported as a base PKG plus a patch PKG.

## Delivery

One spec, two plans, in order:
1. **Engine (Go):**
   - `inspect`, `import` (fpkg/PFS/PFSC, patch, DLC), `analyze-game` and `build --json`;
   - the `Info.plist` from SFO, auto codesign, `compat.json` and the Go SFO reader.

   Usable from the command line on its own.
2. **App (SwiftUI):** layout A, the add flow, the build queue, management (settings, saves, DLC, uninstall), launch, first run, and the bundled ninja/freetype. It ships in the release as a `.dmg`, ad-hoc signed like today's builds; notarization is out of scope.

## Sources and licences

- There is no PKG or PFS extraction code in the project today.
- shadPS4 (GPL-2.0-or-later, compatible with this project's GPL-2.0) had a PKG/PFS extractor for fake-signed PKGs in older releases. The local clone no longer contains it.
- The engine port will be based on that code and keep its attribution. Fetching the older shadPS4 release needs the owner's consent, per AGENTS.md ("If you need to download something, ask the user").

## Addendum (2026-10-27): findings for the app (plan 2)

Plan 1 (the engine) is done; its protocol is `docs/game-manager-engine.md`, which the app follows exactly (events, error codes, the library lock contract, `library.json` schema with unknown fields kept). Real data changed four points of the app design:

- **Settings are keyed by TITLE_ID.** The runtime names `settings/<name>.cfg` after the app directory's base name. In the library every game's directory is `games/<TITLE_ID>/content`, so all games would share `content.cfg`. The runtime switches to the `TITLE_ID` from the game's `param.sfo`, falling back to the directory name when there is none; existing `CUSA00557.cfg`/`CUSA04529.cfg` keep working because those dumps' directories are named after their TITLE_ID.
- **Saves are found by TITLE_ID.** The runtime names a game's save directory `"<TITLE> [<TITLE_ID>]"`. Some dumps carry another package's `param.sfo` (the TLOU dump's is a DLC's), so an fpkg import of the same game would open a new, empty save directory. The runtime first reuses an existing directory ending in `[<TITLE_ID>]`, and creates the composed name only when there is none. The app's Saves tab finds slots the same way.
- **The Metal backend is an app setting.** The runtime chooses Metal 3/4 from `PS4_GNM_METAL`, not from the `.cfg`. The app stores the choice as `metal=3|4` in the game's `.cfg` (the runtime ignores unknown keys, and with `PS4_NO_DIALOGS=1` it never rewrites the file) and passes `PS4_GNM_METAL` when it launches the game.
- **Bundled ninja and FreeType.** The engine looks for `ninja` and FreeType next to itself (`bin/ninja`, `3rdparty/freetype/{include,lib}`) before PATH, pkg-config and Homebrew. The app bundles Homebrew's arm64 `ninja` (Apache-2.0, links only system libraries) and the static `libfreetype.a` plus `libpng16.a` (FTL and libpng licences; zlib and bzip2 come from macOS), with their licence files.

Testing change: the app is a Swift package (no Xcode project), so XCUITest is replaced by view-model tests that drive the add → build → play flows against the fake engine, plus a scripted smoke run of the packaged app with the fake engine that checks the window appears and the flows complete (screenshot for the report). The engine version the app bundles comes from a new `ps4-recomp version --json`.
