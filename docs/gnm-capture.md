# GNM frame capture and pass replay

Debugging tools for the Metal GNM renderer. A capture records every draw and dispatch of one
frame; a pass of it can be replayed on the host through the renderer itself and compared with
the captured output byte for byte. Captures can be large and hold game data: keep them outside
the repository.

## Capturing

```
PS4_GNM_SYNC_ENCODE=1 PS4_GNM_CAPTURE_FRAME=<present index> PS4_GNM_CAPTURE_DIR=<dir> ./ps4_app
```

| variable | meaning |
|---|---|
| `PS4_GNM_CAPTURE_FRAME` | present index of the frame (the frame `PS4_GNM_TRACE=p<n>:1` traces); unset: no capture and no cost |
| `PS4_GNM_CAPTURE_DIR` | output directory (default `./gnm_captures`); the frame goes to `<dir>/frame_<n>` |
| `PS4_GNM_CAPTURE_REPLAY` | `<a>-<b>[,<c>-<d>...]` or `all`: passes stored replayable (guest inputs, raw texture contents before and after); default none |
| `PS4_GNM_CAPTURE_REPLAY_SHADER` | `<entry>[,<entry>...]`, each a shader code address (hex `0x...` or decimal, as `stages[].code_addr` in the manifest) or `pgm:<hash>` (a program hash, as `stages[].pgm_hash`): also stored replayable are every pass with a stage at one of these addresses or with one of these program hashes, and the passes of the same frame that produced what those passes read (see below) |
| `PS4_GNM_CAPTURE_RAW_MB` | budget for the raw texture files `tex/*.raw` (default 8192); a texture that does not fit is recorded without its raw file and with `"readback": "budget"`, but still gets its view PNG. Guest memory blobs and PNGs are not counted |
| `PS4_GNM_CAPTURE_THUMB` | width of the view PNGs of passes that are not replayable (default 480) |
| `PS4_GNM_SYNC_ENCODE=1` | required: the CP and encoder sides of a pass must run back to back |

Every captured pass commits the command buffer and waits for the GPU before and after it, so the
captured frame takes seconds to minutes and has one render pass per draw.

### Selecting passes by shader

Pass indices drift between runs (by about a hundred in a busy game frame), so a pass range found in
one capture misses the pass in the next. `PS4_GNM_CAPTURE_REPLAY_SHADER` selects passes by the
code address of one of their shader stages instead, together with their producers: the earlier
passes of the frame that may have written a byte the selected pass reads (guest memory it reads,
the sampled and storage textures it does not write). How exact that is depends on what a pass
declares it writes:

- a guest memory dispatch's probed writes are exact: a pass whose bytes such writes replaced
  entirely is not a producer;
- a written render target, storage image or bound V# range is a write that may cover only part of
  the range (the pixels a draw covers, the fields a shader stores): it makes the pass a producer
  but hides no earlier writer, so every earlier pass that may have written those bytes is
  selected too (over-selection rather than a missed producer; a texture sampled after hundreds
  of draws into it selects all of them, and `PS4_GNM_CAPTURE_RAW_MB` limits the raw files).

The selected pass's own render and depth targets are not followed: their contents before the pass
are its `pre` contents. Producers are not transitive: a producer's own inputs are only followed
when its shader is selected too, so a chain of compute passes needs an entry for each stage.

Code addresses of shaders that the game loads into its own heaps (U4's compute shaders at
`0x13...`) change between runs; their program hashes do not. A hash from one capture's manifest
selects the same shader in the next run (`pgm:0x4c7184e1f5d449ec`).

Producers are only known once their readers have run, so the frame before the captured one is a
learning frame: its passes are recorded as usual but nothing is written, committed or waited for;
at its present the log reports how many passes used the shaders and how many producers were
found. In the captured frame a pass is matched by its key: the code addresses of its first two
stages (vs and ps for a draw, cs for a dispatch) and how many earlier passes of the frame had the
same ones. This matches as long as the two frames draw the same passes in the same order (a
static or slowly changing scene); a pass whose key the learning frame did not have is selected
only if it uses one of the shaders, and the log counts such passes at the captured frame's present
(a sign that the frames differ and producers may be missing or wrong). A quit during the learning
frame writes nothing. Producers in earlier frames (a cubemap rendered once, last
frame's history buffer) are not selected; their output is the selected pass's `pre` contents.
Frame 0 has no learning frame. `PS4_GNM_CAPTURE_REPLAY` ranges still apply in addition.

The manifest is written when the frame presents. If the game quits through the normal quit path
before that (window close, the guest's exit, `PS4_GNM_QUIT_AFTER_S`), the passes recorded so far
are written at the quit (the log says "did not present"); a killed process writes no manifest. Guest memory snapshots cover only readable pages: estimated ranges (fetch
shaders, image sizes) that reach into unmapped or PROT_NONE pages are cut there.

## Layout of `frame_<n>/`

| path | contents |
|---|---|
| `manifest.json` | the frame (schema below) |
| `blobs/<addr>_<size>_<hash>.bin` | guest memory a pass reads, before the pass, in 16 KiB pages; stored once per address, size and FNV-1a 64 content hash |
| `regs/<hash>.bin` | a pass's register file: `(index, value)` uint32 pairs of its non-zero dwords |
| `tex/p<pass>_<role>_<pre/post>.raw` | GPU-owned texture contents: for each mip level, each array slice (cube: 6 per element), each depth slice, tight rows of texels; Depth32Float_Stencil8 appends the stencil plane (1 byte per texel) in the same order |
| `png/p<pass>_<role>.png` | view of a written texture after the pass (level 0, slice 0) |
| `index.html` | written by `tools/gnm_capture_view.py` |

## manifest.json

Addresses and hashes are hex strings (`"0x13100b0000"`), other numbers are JSON numbers.

- Frame: `version` (1), `frame`, `mem_size`, `neo`, `gcn_cache_id`, `passes`.
- Pass: `index`, `replayable`, `type` (`draw` / `dispatch`), `queue`, `name`, `skipped` (non-empty:
  the renderer encoded nothing, with the reason; see "Skip reasons" below), `regs_hash`, `regs_file`; draw arguments
  `indexed`, `index_base`, `index_type`, `index_offset`, `count`, `max_index`, `num_instances`,
  `base_vertex_ud`, `start_instance_ud`, `cb_extent[8]`, `db_extent`; dispatch `dim[3]`; both
  `indirect_addr`, `indirect_args[5]` (the argument dwords when the pass was encoded);
  `stages`, `buffers`, `images`, `samplers`, `textures`, `meta_cleared`, `unstable`, `inputs`, `outputs`, `state`.
  `unstable` (replayable passes): strings naming the stored inputs (`input 0x<addr>+0x<size>`, `texture <role>`)
  that were no longer the same after the pass completed (a guest thread rewrote them, or other GPU work wrote
  a sampled texture); `gnm_replay` prints them as notes, since a mismatch may then come from the capture.
- Stage: `stage` (`vs`/`ps`/`cs`), `code_addr`, `code_size`, `pgm_hash`, `msl_hash`, `user_data[16]`.
- Buffer: `stage`, `index`, `addr` (bound base), `size` (bound bytes), `stride`, `written`, `vsharp[4]`.
- Image: `stage`, `index`, `addr`, `tsharp[8]`, `dfmt`, `nfmt`, `width`, `height`, `depth`, `levels`,
  `layers`, `type`, `tile_mode`, `storage`, `depth_image`, `table` and `entry` (optional),
  `textures` (indices of the GPU-owned textures at `addr`; empty: read from guest memory), `guest_bytes`.
  `table` / `entry`: the image is entry `entry` of T# table `table` of its stage (a table the shader
  indexes at run time, `gcn_image_table`; its T# is the one the CP copied from the table for this
  pass). Absent: not a table entry (a T# from user data or a fixed SRT location). A hand-written
  manifest leaves both out for plain images.
- Sampler: `stage`, `index`, `ssharp[4]`.
- Texture: `role` (`t<k>_color<i>`, `t<k>_depth`, `t<k>_storage`, `t<k>_sampled`), `written`, `id`
  (the texture-cache entry: `kind` 1 color/storage or 2 depth, `address`, `size`, `mtl_format`
  (the texture's MTLPixelFormat), `entry_format`, `tex_type`, `width`, `height`, `depth`,
  `levels`, `layers`, `samples`, `dfmt`, `nfmt`, `swizzle[4]`, `cb_swizzle[4]`, `mtl_type`,
  `mtl_width`, `mtl_height`, `mtl_depth`, `mtl_levels`, `mtl_array`, `mtl_samples`, `usage`,
  `storage_mode`, `surface` (SurfaceDesc and SurfaceLayout, `PackSurface`)), `pre_file`,
  `post_file`, `png_file`, `png_mode`, `pre_hash`, `post_hash`, `readback` (non-empty: why the
  contents were not read: `msaa`, `format`, `budget`, ...). With `budget` and a `pre_file`, only the
  contents after the pass were left out: the pass still replays and that output is not compared.
  GDS (the 64 KiB global data share) is not captured: a pass whose shaders read it (`ds_*` with
  `gds`) replays with GDS zeroed and may not match.
- Blob (`inputs`, `outputs`): `addr`, `size`, `hash`, `file` (empty: over the 256 MiB snapshot limit).
  A compute dispatch that reads or writes guest memory through V#s it loads at run time
  (`gcn_shader_info.uses_guest_memory`) has no bound buffer for those accesses: its inputs are
  stored after its probe pass (before it runs) and include the 1 MiB pages it accesses; the pages
  it writes are `outputs` without a matching buffer, which the replay compares as well.
- State (draws): `prim`, `color_mode`, `blend_enable[8]`, `blend_raw[8]`, `write_mask[8]`,
  `depth_test`, `depth_write`, `depth_compare`, `stencil_test`, `stencil_ref_front`,
  `stencil_ref_back`, `viewport[6]` (x, y, width, height, znear, zfar), `scissor[4]`.


### Skip reasons

`skipped` holds one of these (the first reason set for the pass):

- `not encoded (see the [gnm-draw] log)`: the renderer returned before encoding without a reason of
  its own (a shader that did not translate, an unsupported format, ...).
- `fast-clear elimination / FMASK decompress (renderer operation, not a shader pass)`,
  `MSAA resolve (renderer operation, not a shader pass)`: CB operations the renderer does itself.
- `surface copy (compute copy shader): a blit, not a shader pass`, `stencil / metadata copy (skipped
  by the renderer)`, `CMASK/HTILE clear by a compute shader (tracked, not run)`: compute passes the
  renderer replaces or tracks.
- `indirect draw replaced by a direct draw (next pass)`: the indirect draw is drawn as the next pass.
- `T# tables written by pending GPU work no longer fit the permutation`: a table the pass's shader
  indexes at run time overlapped GPU work that had not completed when the CP copied the table; the
  table was read again after that work, and it no longer fits the specialization the shader was
  chosen for, so the pass was skipped (`ImageTableStats::hazard_skips`). This can happen in a
  captured frame too: the drain at the start of a captured pass does not make the CP's earlier copy
  current.

## View PNGs

| format | mapping |
|---|---|
| RGBA8 / BGRA8 unorm, R8, RG8 | stored bytes |
| sRGB 8-bit | stored bytes (not linearised) |
| snorm | (v + 1) / 2 |
| unorm 16, RGB10A2 | v / max |
| float (16F, 32F, RG11B10F, RGB9E5F) | x / (1 + x) per channel, x < 0 as 0; NaN magenta, +Inf white |
| integer | per channel, linear from the image's minimum to its maximum |
| depth | grey, linear from the image's minimum to its maximum |
| stencil | value as grey |

One- and two-channel formats show R (and G). Multisampled textures have no view.

## Tools

- `tools/gnm_capture_view.py <frame_dir>`: `index.html` with every pass, its shaders, bindings,
  state and output views.
- `tools/gnm_replay/build.sh <out> tools/gnm_replay/gnm_replay.mm`, then
  `<out>/gnm_replay <frame_dir> <pass> [--out <dir>]`: replays a replayable pass through
  ps4draw::Draw / Dispatch and prints MATCH / DIFF per output. Exit status 0: every output is
  byte-exact; 1: a mismatch; 2: not replayed (the reason is printed: not stored replayable,
  contents over the raw budget, skipped by the renderer, ...) or nothing to compare (the capture
  records no output of the pass: it may still write memory the renderer does not track, and the
  notes on stderr list the store instructions in its shaders' GCN code). `--out <dir>` writes the replayed outputs (`.raw`, `.png`,
  `.bin`). The replay runs the renderer with `PS4_GNM_SYNC_ENCODE`, `PS4_GNM_SYNC_COMPILE` and no
  shader cache, PSO archive or library store, so it reads and writes nothing outside its process.
- `tools/gnm_capture_extract.py <frame_dir> <pass> <out> [--max-bytes N] [--drop-input 0xADDR]
  [--dim X,Y,Z] [--keep-outputs]`: one replayable pass, renumbered 0, as a minimal frame for a
  host test. A pass extracted from a game's capture holds that game's shaders and data: it is a
  local fixture (`tests/host/data/game/replay/<issue>/`, git-ignored, or under
  `PS4_HOST_GAME_FIXTURES`), never committed; see [tests/host/README.md](../tests/host/README.md).
  Only passes of synthetic captures (written by the tests themselves) belong in the repository.
  Exit status 0: written; 1: over the size limit
  (default 4 MiB: drop inputs the property does not need, shrink a dispatch, or build a synthetic
  pass); 2: bad input (no such pass, not replayable, unknown input address, output exists). By
  default the captured outputs after the pass are dropped, because a fixture locks a fix by
  asserting a property of the replayed output (`tests/host/replay_props.h`), not by comparing with
  the output of the old code; `gnm_replay` then reports `NOT CAPTURED` for the written textures.
  `--keep-outputs` keeps them (the fixture replays `BYTE-EXACT`); `--dim` drops them, because a
  shrunk dispatch writes less.
- `tools/refcompare.py <frame.png> <reference.png>`: 4x4-region mean colour and luminance and a
  luminance histogram against a reference frame.
