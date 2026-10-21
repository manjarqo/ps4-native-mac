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
| `PS4_GNM_CAPTURE_RAW_MB` | budget for the raw texture files `tex/*.raw` (default 8192); a texture that does not fit is recorded without its raw file and with `"readback": "budget"`, but still gets its view PNG. Guest memory blobs and PNGs are not counted |
| `PS4_GNM_CAPTURE_THUMB` | width of the view PNGs of passes that are not replayable (default 480) |
| `PS4_GNM_SYNC_ENCODE=1` | required: the CP and encoder sides of a pass must run back to back |

Every captured pass commits the command buffer and waits for the GPU before and after it, so the
captured frame takes seconds to minutes and has one render pass per draw.

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
  the renderer encoded nothing, with the reason), `regs_hash`, `regs_file`; draw arguments
  `indexed`, `index_base`, `index_type`, `index_offset`, `count`, `max_index`, `num_instances`,
  `base_vertex_ud`, `start_instance_ud`, `cb_extent[8]`, `db_extent`; dispatch `dim[3]`; both
  `indirect_addr`, `indirect_args[5]` (the argument dwords when the pass was encoded);
  `stages`, `buffers`, `images`, `samplers`, `textures`, `meta_cleared`, `inputs`, `outputs`, `state`.
- Stage: `stage` (`vs`/`ps`/`cs`), `code_addr`, `code_size`, `pgm_hash`, `msl_hash`, `user_data[16]`.
- Buffer: `stage`, `index`, `addr` (bound base), `size` (bound bytes), `stride`, `written`, `vsharp[4]`.
- Image: `stage`, `index`, `addr`, `tsharp[8]`, `dfmt`, `nfmt`, `width`, `height`, `depth`, `levels`,
  `layers`, `type`, `tile_mode`, `storage`, `depth_image`, `textures` (indices of the GPU-owned
  textures at `addr`; empty: read from guest memory), `guest_bytes`.
- Sampler: `stage`, `index`, `ssharp[4]`.
- Texture: `role` (`t<k>_color<i>`, `t<k>_depth`, `t<k>_storage`, `t<k>_sampled`), `written`, `id`
  (the texture-cache entry: `kind` 1 color/storage or 2 depth, `address`, `size`, `mtl_format`
  (the texture's MTLPixelFormat), `entry_format`, `tex_type`, `width`, `height`, `depth`,
  `levels`, `layers`, `samples`, `dfmt`, `nfmt`, `swizzle[4]`, `cb_swizzle[4]`, `mtl_type`,
  `mtl_width`, `mtl_height`, `mtl_depth`, `mtl_levels`, `mtl_array`, `mtl_samples`, `usage`,
  `storage_mode`, `surface` (SurfaceDesc and SurfaceLayout, `PackSurface`)), `pre_file`,
  `post_file`, `png_file`, `png_mode`, `pre_hash`, `post_hash`, `readback` (non-empty: why the
  contents were not read: `msaa`, `format`, `budget`, ...).
- Blob (`inputs`, `outputs`): `addr`, `size`, `hash`, `file` (empty: over the 256 MiB snapshot limit).
- State (draws): `prim`, `color_mode`, `blend_enable[8]`, `blend_raw[8]`, `write_mask[8]`,
  `depth_test`, `depth_write`, `depth_compare`, `stencil_test`, `stencil_ref_front`,
  `stencil_ref_back`, `viewport[6]` (x, y, width, height, znear, zfar), `scissor[4]`.

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
  records no output the pass writes). `--out <dir>` writes the replayed outputs (`.raw`, `.png`,
  `.bin`). The replay runs the renderer with `PS4_GNM_SYNC_ENCODE`, `PS4_GNM_SYNC_COMPILE` and no
  shader cache, PSO archive or library store, so it reads and writes nothing outside its process.
- `tools/gnm_capture_extract.py <frame_dir> <pass> <out>`: one pass as a minimal frame for a
  host test (`tests/host/data/replay/`), at most 4 MiB.
- `tools/refcompare.py <frame.png> <reference.png>`: 4x4-region mean colour and luminance and a
  luminance histogram against a reference frame.
