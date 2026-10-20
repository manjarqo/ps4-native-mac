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
  Each bind stamps its last use. Windows not bound for 30 s (`PS4_GNM_GPU_WINDOW_IDLE_S`, 0 = never) are
  released at the next commit (checked once a second).
- **Over budget**: at the next commit, windows not bound in the last 250 ms are released, and the transient
  caches are purged (detile staging buffers and maps, the upload arena's free list). The first time, a warning
  is logged; later transitions and the recovery are logged rate-limited. Rendering continues: needed windows are
  created again, so the budget bounds idle and transient memory but never refuses work the frame needs.
- **Refused no-copy ranges**: a range longer than 1 GiB, or one with a hole (a page that is unmapped or not
  read-write, found by walking `mach_vm_region`), gets no no-copy buffer. Instead the bound range (at most
  64 MiB) is copied into upload memory, with holes read as zero. The copy serves reads only, because GPU writes
  to it do not reach guest memory. Larger ranges are not bound and the shader gets the dummy buffer, as it did
  before for ranges over 2 GiB and for failed buffers. Refusals and copies are counted in the `[gnm-mem]` line
  and logged rate-limited.

## Residency and GPU hangs

Resources are made resident by Metal per command buffer: directly bound buffers implicitly, and buffers reached
through argument buffers through `useResource`. No `MTLResidencySet` is used. Command buffers retain what they
reference, so a released window stays alive, and stays wired, until every command buffer in flight that uses it
has completed. The next bind creates it again.

A hung or very long GPU command buffer (for example a shader looping on an out-of-bounds read) therefore pins
its windows for as long as it runs. Releasing windows cannot reclaim that memory, and the sweep runs on the
encoder thread, which may itself be waiting for the GPU. The sampler keeps logging, so the wired and charged
numbers before and during a hang stay visible.

Not covered: the texture cache never evicts (`TextureCache` entries are only added or cleared as a whole). Its
memory is part of the charged total, and over budget it is reported but not reduced.
