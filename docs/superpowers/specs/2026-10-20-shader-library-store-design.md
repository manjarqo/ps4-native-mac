# Shader library store — design note

Date: 2026-10-20. Scope: Metal shader and pipeline caching in libSceGnmDriver (TLOU, Uncharted 4).

## What the data says

Probe (`newLibraryWithSource` on 40 TLOU MSL sources, one thread, M1 Pro, macOS 27):

| case | per library (median) |
|---|---|
| cold system Metal cache | 319 ms (max 1.3 s) |
| warm, same executable directory | 0.0 ms |
| other directory of the **same length** | 0.0 ms (hit) |
| directory one character **longer** | 319 ms (miss) |
| rebuilt binary, same directory | 0.0 ms (hit) |
| bundle with a fixed bundle ID, rebuilt binary | 0.0 ms (hit) |
| same bundle ID, bundle path 5 characters longer | 320 ms (miss) |

So hypothesis (a) holds, and more broadly than stated: the system cache key depends on the length
of the executable's directory, for bundles too (with the bundle ID), and not on the binary. A
rebuild installed at the same path keeps the cache; a new or longer path loses all of it. The
cache is also shared (TLOU and U4 bundles both use `org.ps4recomp.eboot`, all bundle-less
processes share one directory), size-capped and purged by the OS.

In the game this matters because known shaders are compiled synchronously on the CP thread
("cheap thanks to the system cache"), and compute shaders always are. After a path change every
known shader costs ~320 ms inside a frame; the warm-up compiles the whole MSL cache (1873 TLOU
sources, ~2 min of CPU) and loses the race. Our own caches (GCN translations, MSL sources,
pipeline list, `MTLBinaryArchive` of pipelines) are already path-independent; the only missing
piece is the MSL → AIR step.

## Options

1. **Own on-disk store of compiled libraries, keyed by the MSL** — chosen. A serialized
   `MTLBinaryArchive` is a fat metallib with an AIR slice, and `newLibraryWithData` loads it as a
   library in about a millisecond without the compiler. (Verified: a render archive holding a VS
   and a PS both named `main0` loads with one of them renamed, so functions are picked by type;
   pipelines built from such functions still hit the existing pipeline archive.) Rejected
   alternative: dynamic libraries serialized with `serializeToURL` — the compiler service crashed
   (`XPC_ERROR_CONNECTION_INTERRUPTED`) on TLOU compute shaders.
2. **Async/parallel compile with prewarm by first use** — kept as a complement: the warm-up now
   loads store entries first, then compiles MSL without an entry, each group oldest-first (file
   creation time = the order the game first met them: title and menus first). Making known or
   compute shaders asynchronous would skip draws/dispatches the game renders only once (static
   shadow caches, compute-written buffers), so the synchronous path stays and is made cheap.
3. **Prebuilt archives in the .app** — not justified: the store lives next to the other caches,
   survives rebuilds and installs, and the owner plays on one machine. Shipping needs the Metal
   toolchain (not installed) or a copy of the store, and would only help a first run elsewhere.

## Design

`ps4_gnm_library_store.{h,mm}`: `<title cache>/mlib/<config>/<h1>_<h2>.mlib`.

- **Key**: h1 = the renderer's MSL hash (after its post-processing), h2 = an independent 64-bit
  word hash, plus the MSL length. The file header repeats the key and the stage.
- **Entry**: 56-byte header (magic, format version, stage, key, payload size and hash) + the
  serialized archive of the first pipeline built with that function. Written on a utility queue
  after a pipeline builds (temporary file + rename); a render pipeline writes its VS and PS
  entries from one archive.
- **Invalidation**: a changed translator or MSL post-processing changes the MSL, hence the key.
  `<config>` hashes the format version, the compile-options tag and `kern.osversion` (new Metal
  compiler / AIR); other configurations are deleted at startup. A header, size, hash, key or
  stage mismatch, or a library Metal refuses, deletes the entry and falls back to compiling.
  Size budget 256 MB (`PS4_GNM_LIB_STORE_MB`), least recently used first; `PS4_GNM_NO_LIB_STORE=1`.
- **Lookup order in FinishShader**: session map → warm-up result → store (sync, ~1 ms) → MSL
  compile (async for new VS/PS, sync otherwise, as before).
- **Test isolation**: `PS4RECOMP_CACHE_DIR` moves every cache of a run to a scratch root.

Measured (TLOU, 280 s fresh-profile runs, two rounds): after a move to a longer path, compile
hitches 6–7 → 0–1, libraries compiled inside frames 88–91 (20 s) → 0, warm-up 44 s → 1.4–4.7 s;
warm and same-path cases unchanged; fps within noise. Together with the fix that lets a shader
wait for its MSL's background compile, cold-run hitches 20 → 10 (in-frame compiles 241 → 43,
all compute shaders, which stay synchronous).

Tests: `tests/host/lib_store_test.mm` (key, names, format and every refusal, configurations;
write → read in a new process with draw/dispatch results compared to source-compiled functions;
damaged entry; other options; budget).
