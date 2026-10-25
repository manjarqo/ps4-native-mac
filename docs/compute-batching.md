# Batched compute commits

`ps4draw::FlushCompute` (`ps4_gnm_draw.mm`) is used on both backends. It holds back the commit at
the end of a guest compute submission while the GPU is behind, so that back-to-back submissions
share one command buffer and one compute encoder. `PS4_GNM_COMPUTE_BATCH=0` turns it off.

## Why

- The CP ends every compute submission with a flush (`ps4_gnm_metal.mm`, after `RunComputeQueue`).
- TLOU submits about 44 async-compute batches per frame, in about 3 bursts. Each one became its own
  seq: about 49 commits per frame, each with its own command buffer and seq gap, plus, on Metal 4,
  its own encoder-start barrier.
- The flush is there for latency, not ordering. Every compute RELEASE_MEM asks for an interrupt
  (about 1,480 per frame in TLOU). Labels are written and interrupts raised in `AfterGpu`, only when
  the seq holding them completes. About 1,100 of them per frame have no CP waiter: the guest CPU
  reads them through the interrupt, or by polling the label.
- Deferring to the next graphics submission or CPU sync would add a mean of 2.9–3.3 ms to those
  waits, and up to 6.7–9.2 ms. That is not acceptable.
- But at about 42–44 of the 44 compute-submit flushes per frame, 3 or more seqs are already
  committed and not complete. A commit held while the GPU still has queued work therefore starts
  on the GPU no later than it would have.

## The rule

- At the end of a compute submission:
  - with fewer than 2 seqs in flight, or no main command buffer open, the work is committed at once;
  - otherwise the commit is held, and the next submissions record into the same command buffer and
    compute encoder.
- Held work is committed by the first of:
  - any Commit: a graphics submission, a CPU sync (`SyncGpu`, `Flush(true)`), a CP wait or a
    present;
  - the release thread ("GNM Compute Hold"), 0.5 ms after the work was first held. Later
    submissions do not move this bound;
  - the release thread, as soon as fewer than 2 seqs are in flight. A completion wakes it.
- A compute queue that suspends on a wait commits at once (`Flush(false)`), so the CP never waits
  on uncommitted work.
- Guest sync packets inside the merged encoder still become barriers (`ComputeBarrierImpl`).

**Guest-visible effect.**
- A label or interrupt of held work comes later by at most the bound, plus the release thread's
  wake-up, plus the encoder jobs queued before the release. `gnm_compute_batch_test` measured
  0.63–0.86 ms.
- In play the GPU queue ahead of the work dominates the latency, and that queue gets shorter (see
  below).

## Accepted assumption

Two submissions merged into one encoder are ordered only by the guest's own sync packets between
them, as on GCN.

**What a merged boundary carries.** In TLOU, per frame:
- 41 back-to-back submissions to different compute queues;
- 1 across a graphics submission;
- 1 with a DMA_DATA. Its barrier is kept, as an encoder barrier.

No WAIT_REG_MEM, ACQUIRE_MEM or EVENT_WRITE falls on a merged boundary.

**Same-queue submissions.** These also merge without a barrier, about 0.03 per frame in TLOU.
- On GCN, consecutive dispatches of one queue are not ordered without a sync packet either. So a
  guest that depends on the boundary of a submission alone is racing on hardware too.
- The host tests check that no barrier is added at such a boundary. No test proves that a dependent
  pair of same-queue submissions without a guest barrier gives the right result.
- `PS4_GNM_COMPUTE_BATCH=0` rules the merging out when a title is suspected of depending on it.

## Measured effect

**A/B of the hold on TLOU.** Pairwise, alternating, HEAVY_EXCLUSIVE, before and after the hold.

| backend | fps | encoder | GPU busy | commits per frame |
|---|---|---|---|---|
| Metal 3 | about 82 → 92 (+10.0) | −2.6 ms | 10.5 → 9.5 ms | 49 → 9 |
| Metal 4 | +9.6 | −2.4 ms | 12.8 → 11.6 ms | 49 → 9 |

**Interrupt latency in play.** This is the time from the CP handling a compute RELEASE_MEM to its
`AfterGpu`, on 120 s TLOU routes, in four windows of 100,000 events each.

| backend | before | with the hold |
|---|---|---|
| Metal 3, mean | 6.60–6.83 ms | 5.22–5.55 ms |
| Metal 4, mean | 8.85–9.33 ms | 6.76–7.11 ms |
| max | 11.9–13.1 ms | 11.3–12.7 ms |

The latency goes down rather than up. With 9 commits per frame instead of 49, there are 3.0
(Metal 3) or 4.5 (Metal 4) seqs in flight instead of 19 or 28, so the work reaches the GPU sooner.

**Holds in play.**
- TLOU: 2.6–3.0 holds per frame. About 61% are released by the bound, and the rest by the next
  commit. The backlog release almost never fires.
- Uncharted 4, menus and cutscene: 0.8–0.9 holds per frame, 83–90% released by the bound.

**Metal 3 overlap.** With the hold, 72% of Metal 3 seqs start before the previous one ends, against
16% before. The 300 s TLOU time screenshots stayed within the Metal 3 run-to-run noise, on both
backends.

## Switch

| `PS4_GNM_COMPUTE_BATCH` | behaviour |
|---|---|
| unset or `1` (default) | The hold described above. |
| `0` | Every compute submission is committed at its end, as before the hold. |
| anything else | FATAL at renderer start. |

It is read once, in `ps4draw::Init`. `gnm_compute_batch_test off` checks that with the switch off,
every submission is committed at its end and none is held, even with the GPU behind.
