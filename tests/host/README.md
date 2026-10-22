# Host tests

`tests/host/run_host_tests.sh` builds and runs the host-side unit tests of the runtime, the
renderer and the shader translator. They need no game, except for the few cases below.

Before the first run, build `3rdparty/gcn-recompiler/libgcn_recompiler.a` and
`3rdparty/spirv-cross/libspirv-cross.a` as described in the top-level README.

## Local game fixtures

Some cases translate or run shaders dumped from Uncharted 4. These dumps are game data, so they
are **not in the repository** and must not be committed or shared. Each developer makes them
from their own copy of the game. The runner looks for them in `tests/host/data/game/`, which is
git-ignored, or in the directory named by `PS4_HOST_GAME_FIXTURES`.

When a fixture is absent, its case prints

```text
SKIP: <case>: needs local fixture <path> (game data, not distributed)
```

and is not counted as passed. The runner ends with the number of skipped cases. A fixture that is
present but unreadable, or is not the expected shader, fails the test.

| Fixture | Used by | What it is |
| --- | --- | --- |
| `u4_cs_execlo.bin/.txt` | `gcn_u4_cs_test` | compute shader at `0x1300124f00`, chapter 1 (async compute queue); writes one EXEC half |
| `u4_cs_spill.bin/.txt` | `gcn_u4_cs_test` | compute shader at `0x130015c400`, chapter 1 (async compute queue); sharps spilled to VGPR lanes, wave64 ballots |
| `u4_vs_fullscreen.bin/.txt` | `gcn_u4_cs_test` | vertex shader at `0x1300000300` (first seen at a `DRAW_INDEX_OFFSET_2` draw) |
| `u4_cs_blur.bin/.txt` | `gcn_scalar_reads_test` (case 4) | compute shader at `0x130014f600` (first seen at a `DISPATCH_DIRECT`); a blur that reads its weights through `s[0:1] + 72 + 4 * i` |
| `u4_cs_lighting.bin/.txt`, `u4_cs_lighting_srt.bin`, `u4_cs_lighting_cb.bin` | `gcn_scalar_reads_test` (case 5) | the tiled lighting compute shader at `0x130006eb00` (title screen, 1930 dwords) and the guest memory its SRT walk reads: 16 KiB at `0x1901048000` (SRT) and 16 KiB at `0x19010e0000` (holds the light records at `0x19010e0940`) |
| `u4_cs_probe.bin/.txt`, `u4_cs_probe_srt.bin`, `u4_cs_probe_cb.bin`, `u4_cs_probe_tsharps.bin` | `gcn_scalar_reads_test` (case 6) | the reflection-probe culling compute shader at `0x130013aa00` (title screen, 1209 dwords) and its guest memory: 16 KiB at `0x1807630000` (SRT), 160 KiB at `0x1807600000` (the CB of 1024 records of 160 bytes), 4 KiB at `0x1807628000` (the probe T# array) |
| `u4_cs_copy.bin/.txt` | `gnm_guest_memory_test` (every case that dispatches the copy shader: copy, steady_state, miss_rerun, store_range_check, unsupported_format, null_destination, cp_waits_for_fast_dispatch, compute_queue_visibility, new_shader_after_fast_copy, mispredicted_write_is_ordered, rerun_without_further_work, and the `default`, `hang-cp`, `hang-throttle` and `hang-fast-throttle` runs) | the GPU copy shader at `0x1300142c00` (title screen), 248 bytes: 38 dwords of code followed by the bytes up to the end of its `OrbShdr` footer |

The addresses are where the shaders were found in the runs that made the original fixtures. They
come from the game's own allocations, so check them against your own dump.

### File format

- `<name>.bin`: the program's dwords as they are in guest memory, starting at the program
  address.
- `<name>.txt`: a first line `# <stage> program at 0x<addr>, ...`; the tests read the program
  address from it. Then one `<register index hex> <value hex>` line per non-zero SH, context and
  uconfig register at the draw or dispatch. Lines that start with `#` are comments.
- `mem <addr hex> <file>` lines (`u4_cs_lighting.txt`, `u4_cs_probe.txt`): guest memory the
  shader's translation reads (its SRT walk), as the raw bytes of `<file>` (in the same directory)
  at `<addr>`. The tests expect exactly the regions listed in the table, in that order.

### Regenerating them from your own game

Use a recompiled build of your own dump (see the top-level README) and a separate data directory,
so your saves are not touched:

1. Dump the shaders the game runs:

   ```bash
   mkdir -p /path/to/shader_dump
   PS4RECOMP_DATA_DIR=/path/to/test_data PS4_DUMP_SHADERS=/path/to/shader_dump \
     /path/to/build/eboot.app/Contents/MacOS/eboot
   ```

   The renderer writes each distinct VS/PS/CS program it sees as `<stage>_<addr>.bin` and
   `<stage>_<addr>.txt` (register file at that moment) in that format. Play into chapter 1 (the
   boat): `u4_cs_execlo` and `u4_cs_spill` are dispatched there.
2. Copy the files of each address in the table to `tests/host/data/game/` under the fixture's
   name, for example `cs_130014f600.bin` to `u4_cs_blur.bin` and `cs_130014f600.txt` to
   `u4_cs_blur.txt`.
3. `u4_cs_copy.bin` must also hold the `OrbShdr` footer, which `PS4_DUMP_SHADERS` does not write
   (it stops at the end of the code, as the footer gives it). Take it from a frame capture of
   the title screen instead
   (`PS4_GNM_CAPTURE_FRAME`, [docs/gnm-capture.md](../../docs/gnm-capture.md)): in the pass that
   runs CS `0x1300142c00`, the 248 bytes at the program address are in the guest memory blob
   (`blobs/<addr>_<size>_<hash>.bin`) that covers that address. The `regs/<hash>.bin` file of the
   same pass holds its registers as `(index, value)` uint32 pairs: write them as text lines. The
   test checks `2e07` (64 threads) and `2e13` (`0x84`) to make sure it has the right shader.
4. `u4_cs_lighting` and `u4_cs_probe` come from a frame capture of the title screen as well
   (frame 2341 of the original runs; passes 935 and 947 there): select the two shaders with
   `PS4_GNM_CAPTURE_REPLAY_SHADER` (by code address or by `pgm:<hash>` from the manifest, see
   [docs/gnm-capture.md](../../docs/gnm-capture.md)) so their passes are stored replayable. For
   each pass, write the program's dwords from the blob that covers its code address as `.bin`
   (1930 and 1209 dwords), its `regs/<hash>.bin` as text lines, and cut the listed memory
   regions out of the pass's input blobs (`inputs` in the manifest) into the `_srt`, `_cb` and
   `_tsharps` files; add the `mem` lines to the `.txt`. Case 5 then gives two of the light
   records valid T#s itself; case 6 checks the shader as captured (more than 8 indices: a counted
   gap) and then rewrites the CB and T# array.
5. Run `tests/host/run_host_tests.sh`. The cases run instead of printing SKIP.

## Fixtures extracted from a capture

`tools/gnm_capture_extract.py` cuts one pass out of a frame capture as a minimal frame for a host
test. A pass from a game's capture holds that game's shaders and data, so it is a local fixture
as well: put it under `tests/host/data/game/replay/<issue>/` (or under `PS4_HOST_GAME_FIXTURES`)
and make the test that reads it print the SKIP line above when it is absent. Only captures the
tests write themselves (`ps4gnm_capture::Writer`, as in `gnm_replay_test`) are committed.

## Running with fixtures elsewhere

```bash
PS4_HOST_GAME_FIXTURES=/path/to/my_fixtures tests/host/run_host_tests.sh
```

The last line of the run reports how many cases were skipped, or that the fixtures were present.

`3rdparty/gcn-recompiler/tools/gcn_test` and `gcn_dis` read the same `.bin`/`.txt` pairs, which
helps to check a dump before using it as a fixture.
