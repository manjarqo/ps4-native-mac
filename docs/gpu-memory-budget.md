# GPU memory budget

Code: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_membudget.{h,c}` (policy, accounting), `GuestBuffer` /
`SweepGuestWindows` / `StartGpuMemSampler` in `ps4_gnm_draw.mm`. Test: `tests/host/gpu_membudget_test.mm`.

## Why

Guest memory is one 512 GiB anonymous mapping. Metal sees it through no-copy `MTLBuffer`s over 64 MiB aligned
windows (`ps4_gnm_guest_window.h`); a range crossing windows gets a buffer over all windows it touches. On Apple
silicon, measured by the host test:

- `MTLDevice.currentAllocatedSize` counts the full length of every no-copy buffer, and counts overlapping
  buffers again.
- The first command buffer that uses such a buffer **wires every page of its range**, including pages the
  guest never touched, until the buffer is released. Wired pages do not show in the process footprint.

Nothing released windows before (only a kernel remap dropped them), so the wired guest memory only grew. On a
16 GB machine, a port with the same design (MacNativeGames) hit GPU-driver panics at about 15 GB wired.

## Accounting

A sampler thread (`gnm-mem`) takes a sample once a second. It runs apart from the renderer, so it keeps
reporting while the GPU or the encoder thread is stuck. A sample holds:

- system wired memory (`host_statistics64`), the process `phys_footprint`, and `currentAllocatedSize`;
- the live no-copy buffers: their count, summed length, and the distinct guest memory they cover (per-window
  reference counts).

**Charged** = (`currentAllocatedSize` − summed no-copy length) + distinct no-copy coverage. The first term is
the device's own allocations (textures, private and shared buffers). The second is the guest memory pinned for
the GPU, each window counted once. The system-wide wired count is logged, not charged, because other processes
move it.

`[gnm-mem]` lines are printed every `PS4_GNM_MEM_LOG` seconds (default 10, 0 = off) and whenever wired,
footprint, device or coverage grew by 256 MiB.

## Budget policy

- Budget: 40% of `hw.memsize` (`PS4_GNM_GPU_BUDGET_PCT`, clamped to 5–90; `PS4_GNM_GPU_BUDGET_MB` overrides
  it). The state has hysteresis: it is over above the budget and back under only below 90% of it.
- **Lazy residency**: a window becomes a buffer, and is wired, only when a draw or dispatch first binds it.
  Each bind stamps its last use with the current time. Windows not bound for 30 s (`PS4_GNM_GPU_WINDOW_IDLE_S`, 0 = never) are
  released at the next commit (checked once a second).
- **Over budget**: at the next commit, windows not bound in the last 250 ms are released, and the transient
  caches are purged (detile staging buffers and maps, the upload arena's free list). The first time, a warning
  is logged; later transitions and the recovery are logged rate-limited. Rendering continues: needed windows are
  created again, so the budget bounds idle and transient memory but never refuses work the frame needs.
  Purging backs off once 10 purges in a row did not lower the charged total: the memory over budget is then the
  device's own (textures), which purging cannot reach. Purging resumes when the total drops or the state
  recovers.
- **Size limits**: a span longer than 1 GiB is still created, with a rate-limited warning, because it pins and
  wires all of itself. Such spans were bound before the budget existed, and no copy could stand in for them, so
  refusing them would turn working bindings into dummies. A span longer than 2 GiB is refused, as before. The
  size is checked before the hole walk.
- **Holes**: a span with a page that is unmapped or not readable (`mach_vm_region` walk) gets no no-copy buffer.
  That is exactly what Metal rejects; read-only pages are accepted. Host guest memory is always read-write today:
  guest `mprotect` only changes bookkeeping.
- **Refused spans**: every binding says whether the GPU writes it (`GuestAccess::Read` or `::Write`).
  - A **read** of a refused span with holes gets a copy of the bound range, at most 64 MiB, in upload memory,
    with holes read as zero. It is made once per range and command buffer.
  - A **GPU-written** binding never gets a copy, because its writes would not reach guest memory. It stays
    unbound, as before: the shader gets the dummy buffer and no GPU write is noted, or the DMA fails with its
    log line.
  - Refused spans are remembered, so later binds neither walk the VM regions again nor retry. The memory is
    cleared on remaps and every 30 s.

## Residency and GPU hangs

Resources are made resident by Metal per command buffer: directly bound buffers implicitly, and buffers reached
through argument buffers through `useResource`. No `MTLResidencySet` is used. Command buffers retain what they
reference, so a released window stays alive, and stays wired, until every command buffer in flight that uses it
has completed. The next bind creates it again.

A hung or very long GPU command buffer (for example a shader looping on an out-of-bounds read) therefore pins
its windows for as long as it runs. Releasing windows cannot reclaim that memory, and the sweep runs on the
encoder thread, which may itself be waiting for the GPU. The sampler keeps logging, so the wired and charged
numbers before and during a hang stay visible.

Accounting of released windows: a released window leaves `guest_bufs` at once, but its length and coverage stay
counted until every command buffer that may use it has completed, because it is alive and wired until then. A
commit in the middle of a draw can still release a window that the draw is about to bind. The next bind then
creates a second buffer over the same range, and for that short time both are counted; this is correct
accounting, not a leak.

## Texture cache eviction

Code: `ps4_texcache_*` in `ps4_gnm_membudget.c` (policy), `TextureCache::EvictSampled` / `SetUse` in
`ps4_gnm_resources.mm`, `EvictTextures` in `ps4_gnm_draw.mm`. Test: `tests/host/tex_evict_test.mm`.

The cache holds two kinds of textures. **Sampled** textures are detiled copies of guest memory: an evicted one
is created and uploaded again (CPU or GPU detile, as for a first use) the next time a T# needs it. **GPU-owned**
surfaces (render targets, depth, storage images and their copies) hold the only copy of what the GPU wrote and
are never evicted. The `[gnm-mem] texture cache:` line reports both (count, `allocatedSize` bytes), the peak of
the sampled bytes, the cache budget and the evictions so far.

- **Last use**: at every commit the renderer tells the cache the sequence number of the command buffer that
  work encoded from now on belongs to, and the commit time (`SetUse`). Every lookup that returns a texture
  stamps its entry with both. That is one store pair on the hit path.
- **In flight**: an entry is a candidate only once its command buffer has completed (`completed_seq` from the
  completion handlers, as for released windows), so a texture bound in the open command buffer, in the texture
  upload command buffer or in one in flight is never evicted. A candidate must also have been idle for at least
  100 ms, so a texture looked up for a draw but not yet bound (a commit can fall in between) is never one either.
  Command buffers retain what they use, so the Metal object of an evicted texture lives until they are done.
- **Cache budget**: sampled textures may use a twelfth of the GPU budget (546 MiB on 16 GB;
  `PS4_GNM_TEX_CACHE_MB`, 0 = no cache budget). Above it, at most every 100 ms at a commit, the least recently
  used candidates not used for 2 s (`PS4_GNM_TEX_KEEP_MS`) are evicted until the sampled bytes are at 90% of the
  budget. A working set larger than the budget therefore stays: the cache does not thrash. Measured: without a
  budget, U4 chapter 1 grows its sampled textures from 240 MiB to 1.5 GiB in 5 minutes and keeps growing; at
  512 MiB it holds about 470 MiB with no fps cost; at 256 MiB re-uploads of still-used textures cost long frames.
  TLOU's courtyard needs about 400 MiB in all.
- **Not evicted: GPU-owned surfaces.** They grow too (U4 chapter 1: 300 MiB to 1.2 GiB in 4 minutes). The
  `[gnm-mem] GPU-owned surfaces:` line reports how many overlap a surface created after them (the game reused
  their memory) and how many were not looked up for 10 s. Evicting them needs the renderer's caches that are
  keyed by texture pointer (depth companions, EQAA twins) to drop their entries first.
- **GPU budget pressure**: when the over-budget sweep purges the transient caches (with its back-off), every
  candidate not used for 250 ms is evicted as well.
- **GPU writes**: an evicted entry takes its GPU-upload epoch with it. A re-created texture is uploaded from guest
  memory at its first use; when GPU work that writes that memory is still pending, the hazard path
  (`ResolveTextureHazards`) copies it on the GPU behind that work, as for any new texture. A write retired after
  the re-creation marks the new entry stale once (one extra upload, never stale contents).
- The GPU-owned range index (`OverlapsGpuTexture`) is rebuilt when a GPU-owned entry was added, removed or
  resized (a version counter); the entry count no longer works as that signal once entries are evicted.
- A re-created texture reads the guest memory as it is now. The cache does not see every CPU write to guest
  memory (only the notified ones), so a texture the game rewrote without such a notification can show its new
  contents after an eviction where the never-evicting cache kept showing the old ones.
