# Game manager engine

The PS4 Native app drives `ps4-recomp` as a separate process. This document is the contract between them: the commands, the event stream, the result objects, the error codes, and the on-disk library. The design rationale is in `docs/superpowers/specs/2026-10-26-game-manager-design.md`.

Each command is one process. With `--json` it writes one JSON object per line to stdout and nothing else; logs go to stderr. Without `--json` it writes plain text. The exit code is 0 on success and 1 on failure. A failure always ends the stream with an `error` event, so a consumer can rely on the last event: `done` means success, `error` means failure. (`build --json --run` emits `done` only after the run step succeeded.) If the process dies without either, the stream was cut off and the operation did not finish.

## Commands

| Command | Purpose |
|---|---|
| `ps4-recomp inspect <pkg \| folder> [--json]` | Read identity, kind, signing and sizes without writing anything to a library. |
| `ps4-recomp import <pkg \| folder> --library <dir> [--mode copy\|reference] [--json]` | Add a game, patch or DLC to the library. |
| `ps4-recomp analyze-game <content dir> [--json]` | Analyse `eboot.bin` and return a support verdict. |
| `ps4-recomp version [--json]` | Print the engine version; with `--json` one `done` event with `{"version","go"}`. |
| `ps4-recomp build <eboot.bin> -o <build dir> [flags] --json` | Recompile and produce a signed `.app`. |

Flags of the first three may come before or after the positional argument. `--mode` defaults to `copy`; `reference` applies to folders only. A flag error is reported as a `bad_input` error event. `build` takes the usual recompiler flags (`-j`, `-O`, `-app-dir`, `-copy-resources`, ...; see `ps4-recomp -h`); only `--json` matters for the protocol.

### Bundled tools

A build needs ninja and FreeType. The engine looks for ninja at `<exeDir>/bin/ninja`, then `<exeDir>/../bin/ninja`, then on `PATH`; without it, it falls back to compiling with clang directly. FreeType is taken from `<exeDir>/3rdparty/freetype` (or `../3rdparty/freetype`) when it holds `include/freetype2/ft2build.h` and `lib/libfreetype.a` (linked statically with `libpng16.a` if present, plus `-lz -lbz2`), then from `pkg-config freetype2`, then from Homebrew (`/opt/homebrew/opt/freetype`).

## Events

```
{"event":"progress","op":"import","stage":"copy","done":1048576,"total":49707468402,"unit":"bytes","message":"..."}
{"event":"warning","op":"import","message":"..."}
{"event":"error","op":"import","code":"bad_pkg","message":"..."}
{"event":"done","op":"import","result":{...}}
```

| Field | Present on | Meaning |
|---|---|---|
| `event` | all | `progress`, `warning`, `error` or `done` |
| `op` | all | `inspect`, `import`, `analyze-game` or `build` |
| `stage` | progress | stage name (see below) |
| `done`, `total`, `unit` | progress | counters; `unit` is `bytes`, `files` or `stages` |
| `message` | progress, warning, error | human-readable text |
| `code` | error | machine-readable reason (see Error codes) |
| `result` | done | the result object of the command |

Stages: `import` reports `lock` once (0 of 1 stages, message `waiting for library lock`) when another process holds the library lock, then `extract` (PKG) or `copy` (folder), in bytes; `analyze-game` reports `analyze` (0 of 1 stages); `build` reports `load` (1/4), `cfg` (2/4) and `emit` (3/4) in stages, then `compile` in files (`done` is the count of finished translation units, as read from ninja). Progress for a large copy is throttled to about one event per 32 MiB. `warning` never ends an operation.

### Example streams

`inspect` of a dumped folder:

```
{"event":"done","op":"inspect","result":{"kind":"folder","signing":"none","title_id":"CUSA00557",...}}
```

`import --mode reference` of a folder whose param.sfo has a CATEGORY other than `gd`:

```
{"event":"warning","op":"import","message":"param.sfo CATEGORY is \"ac\"; importing as a game because eboot.bin is present"}
{"event":"done","op":"import","result":{"title_id":"CUSA00557","kind":"game","game":{...},"pending":false}}
```

`import` of a PKG (copy mode shown by `copy`/`extract` stage):

```
{"event":"progress","op":"import","stage":"extract","done":33554432,"total":9100000000,"unit":"bytes","message":"..."}
...
{"event":"done","op":"import","result":{"title_id":"CUSA04529","kind":"game","game":{...},"pending":false}}
```

`analyze-game`:

```
{"event":"progress","op":"analyze-game","stage":"analyze","done":0,"total":1,"unit":"stages","message":"analysing eboot.bin"}
{"event":"done","op":"analyze-game","result":{"title_id":"CUSA00557","verdict":{"status":"playable",...},"coverage":99.1,...}}
```

`build`:

```
{"event":"progress","op":"build","stage":"load","done":1,"total":4,"unit":"stages","message":"loading the ELF"}
{"event":"progress","op":"build","stage":"cfg","done":2,"total":4,"unit":"stages","message":"analyzing the control flow"}
{"event":"progress","op":"build","stage":"emit","done":3,"total":4,"unit":"stages","message":"emitting C sources"}
{"event":"progress","op":"build","stage":"compile","done":0,"total":N,"unit":"files","message":"compiling"}
{"event":"progress","op":"build","stage":"compile","done":N,"total":N,"unit":"files","message":"compiling"}
{"event":"done","op":"build","result":{"app":".../build/eboot.app","title_id":"CUSA00557","built_with":"0.3.0"}}
```

A failed command:

```
{"event":"error","op":"analyze-game","code":"bad_input","message":"open .../sce_sys/param.sfo: no such file or directory"}
```

### Error codes

Codes are `bad_input`, `bad_pkg`, `retail_pkg`, `no_space`, `cancelled`, `io` and `build_failed`. Which command can return which:

| Code | Command | Cause |
|---|---|---|
| `bad_input` | all | Wrong usage or flags; the path does not exist. |
| `bad_input` | inspect | A folder without `sce_sys/param.sfo` (the only file `inspect` needs). |
| `bad_input` | import | Unknown `--mode`; `reference` with a PKG; a folder without `eboot.bin` or `sce_sys/param.sfo`, an unreadable folder param.sfo, or a folder TITLE_ID that is not four letters and five digits; the folder and the library contain each other; a patch or DLC for a game imported by reference; DLC for a game that is not in the library; a patch whose APP_VER is older than the installed version or than the pending patch (see the pending-patch rule). |
| `bad_input` | analyze-game | The argument is not a directory, or `param.sfo` / `eboot.bin` is missing. |
| `bad_input` | build | The input or app directory does not exist (`ErrNotExist`). |
| `bad_pkg` | inspect | A PKG that cannot be read, a CATEGORY other than `gd`/`gp`/`ac`, or a malformed `param.sfo` in a folder. |
| `bad_pkg` | import | A malformed PKG; a PFS layout the extractor cannot follow (a file stored non-contiguously is refused); a PKG TITLE_ID that is not four letters and five digits; an unsupported CATEGORY; a DLC whose CONTENT_ID has no valid entitlement label (`[A-Za-z0-9_]`, 1 to 16 characters). |
| `retail_pkg` | import | The PKG is retail-encrypted. (`inspect` reports it as `signing: "retail"` instead of failing.) |
| `no_space` | import | The volume lacks room (the import keeps 1 GiB of margin on top of the bytes it writes), or a write hit ENOSPC. |
| `cancelled` | import | SIGINT/SIGTERM (also while waiting for the library lock), or the caller closed its cancel channel. The resumable scratch is kept (see Scratch names). |
| `cancelled` | build | SIGINT/SIGTERM. The ninja or clang children are stopped (see build). |
| `io` | inspect, import, analyze-game | Any other filesystem failure, including a library lock that cannot be taken and a `library.json` whose `version` is newer than the engine supports. |
| `build_failed` | build | Any build failure other than `ErrNotExist`; the message holds the cause. A failed ad-hoc signature or signature verification and a failed `--run` step are also `build_failed`. |

DLC is never pending: DLC for a game that is not in the library is an error (`bad_input`), unlike a patch, which is kept (see the pending-patch rule).

## Results

### inspect

```
kind          "game" | "patch" | "dlc" | "folder"
signing       "fake" | "retail" | "none"   (none for folders)
title_id, content_id, title
app_ver       APP_VER, falling back to VERSION
version       VERSION
category      CATEGORY from param.sfo
icon_path     icon0.png extracted to the temp directory, "" when there is none
packed_size   PKG file size, or the sum of the folder's regular files
unpacked_size extracted size; for a retail PKG 0 (the PFS cannot be read)
```

A PKG kind comes from CATEGORY: `gd` game, `gp` patch, `ac` DLC. `inspect` accepts retail PKGs and reports `signing: "retail"`; `import` rejects them.

**Version rule:** `app_ver` is `APP_VER`, falling back to `VERSION` when `APP_VER` is absent or empty. Real dumps often lack `APP_VER`. The same single rule is used by `inspect`, `import` (the library), `analyze-game` and the `Info.plist`.

**Folder rule:** a folder is a game when it has `eboot.bin` plus `sce_sys/param.sfo`. A CATEGORY other than `gd` only produces a warning event; the folder is still imported as a game. (Some dumps carry the param.sfo of a DLC, for example a pre-order skin.)

### ImportResult

```
title_id
kind      "game" | "patch" | "dlc"
game      the library entry after the import (omitted for a pending patch)
pending   true for a patch stored until its base game arrives
```

The `game` object is a library entry (see library.json below).

### GameAnalysis (analyze-game)

```
title_id, title, app_ver, category
verdict   { status, name, tested_versions[], recommended{}, known_issues[] }
coverage  percent of reachable code the analysis could lift
unresolved   unresolved HLE imports
missing_ops  unique x86 operations the lifter does not handle
modules   *.prx / *.sprx in sce_module/
```

The `tested_versions`, `recommended`, `known_issues` and `modules` values are JSON `null` (not `[]`/`{}`) when empty or unknown: all four for a TITLE_ID missing from the database (`modules` also when there is no `sce_module/`), `recommended` and `known_issues` for a game that lists none. Treat `null` as empty.

`analyze-game` reads `sce_sys/param.sfo` and `eboot.bin` from the content directory. A missing file is `bad_input`. Analysis of a large `eboot.bin` can take minutes.

### build

```
app         path of the signed .app bundle
title_id    TITLE_ID from the content's param.sfo
built_with  recompiler version (stored in library.json by the app)
```

When `--compile=false` the result holds only `built_with`.

The bundle `Info.plist` comes from `sce_sys/param.sfo` in the app directory: bundle id `org.ps4native.<TITLE_ID>` (only letters, digits, `.` and `-` are kept), display name `TITLE`, version `APP_VER` falling back to `VERSION`. Without a param.sfo the generic `org.ps4recomp.<name>` identity is used. The bundle is ad-hoc signed and verified with `codesign --verify --deep --strict`; a signing or verification failure fails the build with `build_failed`. The app directory is the directory that holds `eboot.bin` (auto-detected through `sce_sys`, `assets`, `contentid.txt` or `sce_module`) or the `-app-dir` value, and it is baked into the generated app, so the app needs no `--app-dir` at run time.

**Cancel.** SIGINT or SIGTERM cancels a build. `build` runs ninja and each clang process in a process group of its own; on the signal it sends SIGTERM to those groups, and SIGKILL 5 seconds later to a group still running, so no compiler keeps running after the engine ends. A signal during `load`, `cfg` or `emit`, which run inside the engine, takes effect when that stage ends. The build then ends with an `error` event, code `cancelled`. The signal handler is removed when `build` returns. Signalling the engine process is enough.

## Support statuses

`compat.json` (embedded in the binary) maps TITLE_ID to a name, tested versions with a status, recommended settings and known issues. `analyze-game` looks up the TITLE_ID and the app version (the version rule above):

| Status | Rule |
|---|---|
| `playable` | TITLE_ID and app version are listed as playable |
| `in_progress` | TITLE_ID and app version are listed as in progress |
| `other_version` | TITLE_ID is known, the app version is not; `tested_versions` lists the versions that are |
| `experimental` | TITLE_ID is not in the database |
| `unsupported_input` | Decided by the app, never by the engine: a retail PKG, a broken PKG, or no `eboot.bin`. These arrive as `error` events. |

## Retail PKGs and fpkg

Retail PKGs are rejected. They are encrypted with console keys, and the engine never tries to decrypt them: `import` fails with `retail_pkg` ("this PKG is encrypted with console keys; use a dump of your own console or an fpkg"). Only fake-signed PKGs (fpkg) are supported. `inspect` still reports a retail PKG (`signing: "retail"`) so the app can explain the refusal. A PKG whose PFS stores a file non-contiguously is refused with `bad_pkg`.

## Library

The root is `~/Library/Application Support/PS4Native/` in the app; the engine takes it from `--library`.

```
<root>/
  .lock                       file lock, see below
  library.json                the game list
  games/<TITLE_ID>/
    content/                  the game with patches applied; DLC in content/addcont/<entitlement>;
                              a symlink to the folder in reference mode
    addcont/<entitlement>     the DLC of a game in reference mode (never inside its folder)
    build/                    the build directory with the signed .app
    logs/                     build and run logs (created by the app, not by the engine)
    analysis.json             the last analyze-game result (written by the app, not by the engine)
  pending/<TITLE_ID>/         files of a patch imported before its base game
  pending/<TITLE_ID>.json     {"app_ver": "..."} describing that patch
```

`library.json` is `{"version":1,"games":[...]}`, sorted by TITLE_ID, written atomically (a temp file in the same directory, then a rename). Each game holds `title_id`, `content_id`, `title`, `app_ver`, `version`, `patches[]` (the `APP_VER` of each applied patch), `dlc[]` (entitlement labels), `content_bytes` (the content and, in reference mode, the DLC in `games/<TITLE_ID>/addcont/`), `status` (written by the app from the `analyze-game` verdict, empty until then; the engine clears it when a patch changes the content), `built_with`, `last_played` and `play_seconds`.

**Schema.** `version` is the schema version; this engine writes and reads version 1 (a missing `version` counts as 1). A `library.json` with a higher `version` is refused with `io` ("library version N is newer than this engine supports") and is never overwritten. Fields the engine does not know, at the top level or in a game, are kept: the engine writes them back unchanged when it saves (key order may change), and a reinstalled game keeps its own. So the app may add fields of its own; it should bump `version` only for a change an older engine must not misread.

**Lock contract.** Every read-modify-write of `library.json`, by the engine or by the app, holds the library lock:

1. The lock is `flock(2)` with `LOCK_EX` on `<root>/.lock` (BSD `flock`, not `fcntl`/`lockf` and not `NSFileCoordinator`; create the file with mode 0644 if it is missing). Closing the descriptor releases it.
2. Hold it for the whole read-modify-write: take the lock, read `library.json` again under the lock (never reuse a copy read before), change it, write it to a temp file in `<root>/`, `fsync`, and `rename(2)` the temp file over `library.json`, then release the lock.
3. Uninstall (removing `games/<TITLE_ID>/` and its record) holds the lock too, so it cannot race an import of the same game.
4. `import` holds the lock for its whole run, which can take many minutes for a large game. Imports into one library are therefore serialised: a second import waits, reports `lock` progress once and can be cancelled while waiting. The app must take the lock off the main thread, or poll with `LOCK_EX|LOCK_NB`.
5. In Go, `Library.Update` does all of this. It blocks while an `Import` runs, in another process or in the same process: never call it from a goroutine that must stay responsive.

A writer that skips the lock can lose another writer's change.

**Scratch names.** An import stages its work next to the live tree and commits it by renames, so a crash or a cancel never leaves a half-written `content/`:

| Name | Holds |
|---|---|
| `content.partial` | a PKG extraction or folder copy in progress; resumable |
| `content.next` | a patched copy of the content, staged for the commit |
| `content.old` | the previous tree during the commit |
| `content.ref.partial` | the symlink of a reference-mode import before the commit |
| `patch.partial` | a patch extracted before it is laid over a copy of the content; resumable |
| `games/<TITLE_ID>/dlc-<label>.partial` | DLC being extracted; resumable |
| `games/<TITLE_ID>/dlc-<label>.old` | the previous `content/addcont/<label>` (`games/<TITLE_ID>/addcont/<label>` in reference mode) during the DLC commit |
| `pending/<TITLE_ID>.partial` | a pending patch being extracted; resumable |

The `content.*` and `patch.partial` names sit in `games/<TITLE_ID>/` next to `content/`, and so do the `dlc-<label>.*` names: they are not under `content/`.

A tree moves to `.old`, the staged tree takes its place, `library.json` is saved (or the renames are undone), and only then is `.old` removed. The next import of that game repairs a crash between the two renames.

**Cancel and resume.** A cancelled import (`cancelled`) keeps its resumable scratch directories (marked above) and removes the others; the game directory it created is removed only if it is empty. Any other failure removes all of the import's scratch paths, and the game directory if that import created it. A hard kill (SIGKILL, power loss) leaves everything; the next import of that game resumes or discards it. Each resumable directory holds a resume marker, a file named `\resume`, naming its source: the CONTENT_ID with the PKG's size and modification time, or the CONTENT_ID with the folder's resolved path. The next import of the same source resumes the directory; a directory whose marker differs (another package or version of the same TITLE_ID, or no marker) is discarded first. On resume, a PKG file already extracted under its final name with the right size is skipped, a folder file with the same size and SHA-256 is skipped, and files and directories the source does not contain are removed. The marker is removed before the commit, so it never appears in `content/`.

**PKG contents.** A PKG import writes the files of the PFS image and, as shadPS4 does, the package's own sce_sys entries to `sce_sys/<name>`: `param.sfo`, `icon0.png`, `pic0.png`, `pic1.png`, `changeinfo/changeinfo.xml`, trophies, `playgo-chunk.dat` and every other named entry from id 0x400 on. Real packages carry these files only in the entry table. Left out are the key and digest entries (ids below 0x400), entries without a name and encrypted entries (the NP files `license.dat`, `nptitle.dat` and so on, which nothing in the engine or runtime reads). A PFS file with the same path wins. A patch's entries, its `param.sfo` included, replace the base game's; a DLC's go to `sce_sys/` of its DLC directory (`<addcont>/<label>/sce_sys/`).

**Version order.** App versions are compared field by field as numbers (`01.09` < `01.32`). A patch older than the installed `app_ver` is refused with `bad_input` and changes nothing; the same version again is a reinstall of that patch and is allowed. A pending patch older than the base game it is about to be applied to is kept and not applied, with a warning.

**Pending-patch rule.** A patch (CATEGORY `gp`) for a game that is not in the library is extracted to `pending/<TITLE_ID>/` with `pending/<TITLE_ID>.json`, and the import ends with `pending: true` and a warning. A later patch replaces it (PS4 patches are cumulative) unless it is older than the pending one, which is refused with `bad_input`. When the base game is imported, the pending patch is laid over it in the same staged commit, `patches` and `app_ver` are updated, and the pending files are removed. The `.json` is written last and removed first, so a half-written `pending/<TITLE_ID>/` is ignored. A patch for a game already in the library is applied by cloning `content/` to `content.next`, moving the patch files over the clone and committing; `content/` is untouched until the commit, and the game's `status` is cleared so it is analysed again. A patch is never applied to a referenced game (`bad_input`, naming a copy as the way to update it). Re-importing a base game replaces `content/` with a fresh copy and resets `patches` to empty (a pending patch is applied again if there is one); the installed DLC is kept, linked over from the live `content/addcont/` (or from `games/<TITLE_ID>/addcont/` when the game was referenced, which is removed after the commit), also when the import resumes an earlier run.

**Reference mode.** `--mode reference` makes `content/` a symlink to the source folder (staged as `content.ref.partial`, then renamed). The folder is never written to: no patch and no pending patch is applied to it (a pending patch is kept, with a warning event), its DLC goes to `games/<TITLE_ID>/addcont/` in the library, and the library and the folder must not contain each other. Re-importing in reference mode keeps that DLC; switching a copied game to reference mode hard-links its `content/addcont/` into `games/<TITLE_ID>/addcont/` before the commit. A `games/<TITLE_ID>/addcont/` next to copied content (left by an interrupted switch) is removed by the next import of the game. `copy` clones with APFS clones when the source and the library are on the same volume, and copies otherwise; the free-space check then asks only for the 1 GiB margin, as a clone takes almost no space.

DLC (CATEGORY `ac`) needs its base game in the library; a DLC for a missing game is `bad_input`, and an invalid entitlement label is `bad_pkg`. The entitlement is the label after the last `-` of `CONTENT_ID` (at most 16 characters). The DLC is extracted to `<addcont>/<entitlement>`, where `<addcont>` (`Library.AddcontDir`) is `content/addcont/` for a copied game and `games/<TITLE_ID>/addcont/` for a referenced one; both layouts use the same staging (`dlc-<label>.partial`), `.old` swap and lock, and add the label to `dlc[]`. The runtime scans `content/addcont/` (it is `<app>/addcont` of the game) on its own; for a referenced game the app passes `games/<TITLE_ID>/addcont/` in `PS4_ADDCONT_DIR`, which the runtime scans after it (a label found twice is listed once). Uninstalling a game removes `games/<TITLE_ID>/` and with it the DLC of either layout; the referenced folder is a symlink target and is never removed. There is no per-DLC uninstall.

## Saves and settings

Saves and per-game settings are not part of the library. The runtime keeps them where it always did, in `~/Library/Application Support/PS4Recomp/` (`saves/...` and `settings/<game>.cfg`), so existing saves keep working and an uninstall of a library game does not remove them. `PS4RECOMP_DATA_DIR` moves that directory (used by automated runs).
