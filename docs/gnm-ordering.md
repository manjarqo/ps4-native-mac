# GPU ordering in the GNM renderer

This document covers what orders GPU work in the GNM renderer (`pkg/runtime/modules/libSceGnmDriver`)
on each backend, and the known places where nothing does. The code cites its sections.

## Metal 3: hazard tracking plus explicit sites

### Hazard tracking

- Every buffer and texture the renderer creates uses the default hazard-tracking mode. There is no
  untracked resource and no heap, so all of them are **tracked**. Metal then orders two encoders of
  one queue, inside a command buffer or across command buffers, when:
  - both touch the same object, and one of them writes it;
  - the encoder knows about the object: bound buffers and textures, attachments, blit operands, and
    `useResource:usage:`. The renderer calls `useResource:usage:` for every argument-table buffer
    and every page-table window.
- The wait is for that producer only, not for all earlier work. Apple GPUs also wait only at the
  consumer's stage that uses the object.
- Nothing is tracked between queues: the guest-memory re-run queue, and on Metal 4 the side
  queue the texture cache uses (`SideQueue()`; on Metal 3 that is the renderer's own queue). Nothing is tracked between the CPU and the GPU either: `replaceRegion`, and CPU writes to
  shared buffers.

### Explicit ordering

| mechanism | where | orders |
|---|---|---|
| Concurrent compute encoders | `BeginCompute`, unless serial | Dispatches inside one encoder are not ordered by tracking. |
| `memoryBarrierWithScope:` / `Barrier` | `ComputeBarrierImpl`, from the CP's sync packets; the guest-memory protocol; the detile after the writing dispatches | Dispatch → dispatch inside an encoder, at guest waits, cache flushes and CP DMA. EOP, EOS and RELEASE_MEM alone do not order dispatches (GCN semantics). |
| Render-stage barrier | `ps4_gnm_rectlist.h` | The rect-list expansion's vertex shader reads what the capture vertex shader wrote. |
| Shared events on the queue | `GmCloseChain`, `GmWaitForCommitted`, the present ops, `DebugGpuWait` | Guest-memory chains against the re-run queue, the screen's queue, test stalls. |
| CPU waits | `WaitAll`, the readbacks | CPU-side readbacks and the CP's sync points. |

### What it adds up to

In TLOU about 96% of encoders depend on an encoder of the last 5–20 seqs. About 27% do not depend
on the encoder just before them, and Metal 3 lets those overlap it. This was measured by object
identity over 45,904 encoders of a 100 s Metal 3 route.

## Metal 4: barriers at encoder starts

- A Metal 4 command buffer tracks nothing and retains nothing. Every render, compute and copy
  encoder starts with `barrierAfterQueueStages:` over all stages (Vertex, Fragment, Dispatch,
  Blit), before its own stages. That is a superset of what Metal 3's tracking orders between
  encoders.
- Inside one compute encoder, copies and dispatches are separated by encoder barriers
  (`BeforeCopy` and `BeforeDispatch`). The guest's sync packets become encoder barriers, as on
  Metal 3.
- A queue-level event splits the seq into separate commits (`Metal4Backend::Split`): a signal
  follows the work recorded before it, and recorded work never waits behind a wait. Upload work is
  committed before Main's, as on Metal 3.
- Visibility is `Device | ResourceAlias` everywhere, because guest windows alias each other and
  texture views alias their parents.
- Lifetime is handled separately: every buffer is in a residency set, and textures used by an
  encoder are kept by its command buffer's part (`ps4_gnm_backend.h`).
- Narrower barrier models were measured and not adopted. A tracker that orders by object can skip
  at most about 4% of the start barriers, because the dependency structure above leaves little to
  skip. A sound per-encoder fence model saved about 1 ms of GPU time per TLOU frame and cost
  2–3 ms of encoder CPU.

## Aliasing guest windows

**The risk.**
- `GuestBuffer` gives guest memory to the GPU through no-copy buffers over 64 MiB-aligned windows.
- A range crossing a 64 MiB boundary gets a buffer spanning several windows. A range inside one of
  those windows gets another buffer over the same memory.
- Idle windows are released and made again, and remapped ranges are dropped.
- So two different buffer objects can cover the same guest bytes. Object tracking does not order a
  write through one with a read through the other.
- In TLOU, about one compute encoder per frame depends on an earlier one only through such an
  alias, counted at 64 MiB granularity.

**Metal 3: per-encoder access fences.**
- `GnmBackend::AccessFence` and `WaitAccessFence`, driven by `FlushAliasOrders` in
  `ps4_gnm_draw.mm`, before each command.
- Every window keeps the accesses through it that may still run:
  - the last writer's fence and the hull of the bytes it wrote;
  - the readers since that write.
- A use waits for overlapping accesses made through other windows over its 64 MiB slots:
  - a read waits for writes (RAW);
  - a write waits for writes and reads (WAW, WAR).
- An encoder updates its fence at its end: after the vertex and fragment stages for a render
  encoder, plainly for compute and blit encoders. A wait is skipped when:
  - the fence is the encoder's own, or was already waited for;
  - its seq has completed;
  - it is an upload command buffer's wait for the open main command buffer. Uploads run first, as
    they do for a single object.

**Metal 4.** The encoder-start barriers order these accesses. Metal4Backend's `AccessFence` and
`WaitAccessFence` do nothing, and say why. A barrier model that narrows or skips start barriers
must still order an access through one window after in-flight accesses to the same bytes through
another. `gnm_backend_alias_test` and `gnm_alias_dma_test` check this on both backends.

**Not covered.**
- The re-run queue's raw encoders, which the queue events order.
- Accesses inside one encoder, which the renderer's barriers order.

## Asynchronous compute (`PS4_GNM_ASYNC_COMPUTE=1`)

On GCN the compute (ASC) rings run beside the graphics ring. A guest job on a compute ring that
does not wait for graphics finishes while the graphics frame runs. With every GNM queue on one
Metal queue, such a job first waits for the graphics command buffers committed before it. In
inFAMOUS Second Son that is about 36 ms per frame, which the render thread spends polling the job's
label (Task 10.2.1).

With the switch on, compute-ring work goes to a second Metal queue (`GnmCmdTarget::AsyncCompute`)
when it is **eligible**. Otherwise it **joins** the main queue.

- **Eligible:** a dispatch that is not a guest-memory dispatch, binds no image, and whose
  preparation encoded nothing on Main or Upload; and a compute-ring DMA. Anything else runs on Main.
  So does every job of a submission after a wait met by graphics work. Two more cases also run on
  Main:
  - **main-held:** the open main command buffer already holds compute-ring work. The rings run in
    order, so the next job would wait for it anyway.
  - **gfx-consumed:** a ring whose label a graphics wait met. It stays on Main for the next 120
    presents. Graphics consumes its results, so running it on the other queue would only add a
    join per frame. Other rings are not affected.
- **Seqs:** both queues commit seqs of one numbering. `completed_seq` is the longest completed
  prefix, whatever the queue. What is released "after seq N" (arena chunks, alias accesses, fences,
  pending writes) is released after its own command buffer's seq, stamped at that commit.
- **Fences:** fence actions belong to their GNM queue. A compute ring's label needs the compute
  work on both targets, a graphics label only Main's. Actions of one GNM queue run in issue order;
  actions of the two run in issue order among the ready ones.

| what orders | how |
|---|---|
| A graphics wait met only by a pending compute label (`JoinQueues`) | Main waits on the GPU for the compute queue's work committed so far: an event wait in the main command buffer, after the compute queue's open work is committed. That work's writes stay pending writes until it completes. Texture refreshes from that memory are therefore encoded on Main, behind the wait. Bind-time uploads in the upload command buffer skip memory with pending writes, so that buffer needs no wait. |
| A compute wait met only by a pending graphics label, the "earlier work" fallback, a timed-out wait | The rest of that compute submission runs on Main, behind graphics. |
| One compute ring's work on both targets | Events (`main_ev`, `async_ev`, signalled with each target's generation at commit). Main waits before compute work it takes over; AsyncCompute waits for the compute work Main holds. The signaller is committed before the wait is encoded. |
| Async buffer stores that mark a GPU surface guest-newer | The refresh copy on Main is encoded behind a GPU wait for the async queue. |
| Alias windows | Accesses are recorded per target. An access recorded by the other queue is not waited for: a fence orders one queue, and accesses of two GNM queues are ordered only through the joins above (`alias waits across queues left out` on the counters line). |

The counters line, with the perf line:
`[gnm-draw] async compute: eligible N, joined <reasons>, cross waits N, alias waits across queues left out N; GPU busy main X ms, async Y ms per frame`.
`cross waits` counts the GPU waits encoded of one queue for the other, in either direction. A join
with nothing pending on the other queue encodes no wait.

Both backends have the second queue. On Metal 4 it is a second `MTL4CommandQueue` with the same
residency sets and a timeline of its own (docs/metal4-backend.md, "Two queues").

## Known gaps on both backends

None of these is ordered by either backend. Each is safe only for the reason given.

1. **Read-only copies of guest ranges with holes** (`RefusedGuestBuffer` / `GuestCopy`). The CPU
   copies the range at bind time. GPU writes to it that are still in flight are not in the copy.
2. **CPU re-upload in place.** `replaceRegion` writes into a shared cache texture, which committed
   work may still sample. This is safe only because the guest rewrites such memory after its own
   fence for the earlier GPU reads.
3. **Dispatch order inside a concurrent encoder** follows the guest's sync packets. That is GCN
   semantics. A guest that relied on dispatches being ordered by EOP would be unordered.
   `PS4_GNM_STRICT_BARRIERS=1` checks for this.
4. **The re-run queue and the texture cache's own queue.**
   - The re-runs are ordered by events, which holds as long as every main-queue consumer of their
     pages comes after the wait.
   - The cache's own queue commits without waiting. It is used only before the backend exists or
     after it is released.
5. **Merged compute submissions** (docs/compute-batching.md). Two submissions committed together
   share an encoder, and are ordered only by the guest's own sync packets between them, as on GCN.
