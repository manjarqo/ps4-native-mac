# Restoring TLOU Performance After Sonic Origins Plus Integration

> Publication note (0.4.3): this document records the original design/plan, not a completed benchmark report. The shipped implementation fully hashes only readable spans of at most 4 KiB; larger spans use 64 sampled cache lines for single-level uncompressed surfaces and 16 for other surfaces, plus the final eight bytes. Stable compressed/mipmapped entries are polled every 64 submissions after four unchanged checks. These are heuristics: an ordinary CPU write outside the sampled bytes can be missed, and the document's original full-scan/single-pixel guarantee does not apply. Explicit targeted invalidations still force refreshes. The FPS values below are historical observations and targets, not a new controlled benchmark of the final release.

## Goal

Restore steady-state gameplay performance in **The Last of Us Remastered (`CUSA00557`)** at `1920x1080` from the post-Sonic regression (~19.5–27.5 FPS; `36.0–44.9 ms` encoder CPU per frame) back to its pre-Sonic level (~83+ FPS; `~6–7 ms` encoder CPU per frame), while preserving all **Sonic Origins Plus (`CUSA30448`)** rendering fixes (including CPU-rendered Retro Engine framebuffers) and its ~55 FPS performance.

---

## Root Cause Analysis (Measured Evidence)

Comparing the TLOU `1920x1080` renderer telemetry before (`2026-10-28_13-28-50-run.log`) and after (`2026-10-31_18-54-46-run.log`, `2026-10-31_18-56-43-run.log`) the Sonic Origins Plus changes isolates the exact regression:

| Metric (per frame, 300-present window) | Pre-Sonic (`2026-10-28`) | Post-Sonic (`2026-10-31`) | Delta |
|---|---:|---:|---:|
| **FPS** | **83.9 – 88.7 fps** | **19.5 – 27.5 fps** | **-60 fps (-70%)** |
| **Commits (`OnSubmit`)** | 10.0 – 10.1 | 8.4 – 9.1 | ~same |
| **CP (CPU)** | 4.6 – 5.2 ms | 7.0 – 7.9 ms | +2.4 ms |
| **Encoder (CPU)** | **6.1 – 6.8 ms** | **36.0 – 44.9 ms** | **+30 – 38 ms** |
| **GPU busy** | 11.3 – 12.2 ms | 14.8 – 31.5 ms | +3.5 – 19 ms |
| **CPU texture uploads (`UploadLocked`)** | **0** (0.0 ms) | **426** (21.2 – 24.2 ms) | **+426 uploads/frame** |
| **GPU bind texture uploads (`EncodeGpuUpload`)** | **0** | **265** | **+265 GPU uploads/frame** |
| **Access fences** | 76.5 | 563.2 | +486.7 fences/frame |

### Primary Mechanism: Unconditional Full-Memory Invalidation on Every `OnSubmit()`

To support Sonic Origins Plus's Retro Engine (`424x240` BGRA8 software framebuffer updated by ordinary CPU stores between submissions without a GPU write), `ps4draw::OnSubmit()` in `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm` added:

```cpp
void OnSubmit() {
    S.submit_idx++;
    encq::Defer([] {
        if (S.tex && S.ctx) S.tex->InvalidateRange(0, S.ctx->mem_size, false);
    });
}
```

In `TextureCache::InvalidateRange(uint64_t addr, uint64_t size, bool include_rts, uint64_t write_epoch)`:
1. The default argument in `ps4_gnm_resources.h` is `write_epoch = ~0ull`.
2. In `ps4_gnm_resources.mm:3750`:
   ```cpp
   if (e->kind == Entry::Sampled) {
       if (e->gpu_upload_epoch > write_epoch) continue; // write_epoch is ~0ull -> NEVER true
       e->dirty = true;
       stats.invalidations++;
   }
   ```
3. Because `e->gpu_upload_epoch > ~0ull` is always false, **every `OnSubmit()` (8–10 times per frame in TLOU) locks the texture cache, walks all ~700 cached `Entry::Sampled` textures (`360 MiB`), and marks every single one `e->dirty = true`**.
4. When those static textures are bound in subsequent submissions:
   - **426 small textures (`< 256 KiB`)** per frame take `UploadLocked(e)` on the CPU: allocating a temporary linear buffer, running `DetileSurface`, and calling `[MTLTexture replaceRegion:...]`, costing **21.2–24.2 ms of encoder CPU time every frame**.
   - **265 large textures (`>= 256 KiB`, totaling ~340 MiB)** per frame take `GetTextureForGpuRefresh` -> `gpu_upload(e)` -> `EncodeGpuUpload` on the `Upload` command buffer: opening/closing compute and blit encoders, dispatching `detile_pso`, blitting all mip levels, and emitting 486 extra access fences per frame, costing **~10–15 ms of encoder CPU time** and **+3.5–19 ms of GPU busy time every frame**.

### Secondary Mechanism: Unconditional `ComputeSurfaceLayout` on Every `GetTextureImpl` Call

In `TextureCache::GetTextureImpl` (`ps4_gnm_resources.mm:3385`), `ComputeSurfaceLayout(sd, &image_layout)` was moved before the cache lookup so `texel_fits` could compare `c->size >= image_layout.total_size` when aliasing a GPU render target (`Entry::Color`). Because `GetTextureImpl` is called thousands of times per frame and >95% of binds in 3D games hit an existing `Entry::Sampled` (often block-compressed, where `Entry::Color` aliasing is not even checked), computing full mip/tile surface layouts up front wastes CPU cycles on every cache hit.

---

## Why Prior Sonic Experiment 2 ("Exact 8 MiB Byte Snapshots") Was Insufficient

During earlier Sonic optimization (`sonic-origins/performance/STATUS.md`, Candidate 2):
1. It checked snapshots only inside `UploadLockedImpl` (the CPU upload path), which is bypassed by `GetTextureForGpuRefresh` (`gpu_upload(e)`) for all textures `>= 256 KiB` — including both Sonic's `424x240` framebuffer (`407,040 B = 397.5 KiB >= 256 KiB`) and TLOU's 265 large textures (`~340 MiB`).
2. It allocated a full `std::vector<uint8_t>` copy per texture and ran `memcpy`/`memcmp` over every byte on every submission. Reading `360 MiB` of guest memory on the CPU on every frame (or `3.6 GiB` across 10 submits/frame) would itself consume 10–100 ms/frame of memory bandwidth in TLOU.
3. It lacked a readable-span guard against `PROT_NONE` guard pages or unmapped holes following visible texels inside macro-tile padding.

---

## Architecture & Design

### 1. Separating Targeted Write Invalidations from Submission Polling

`TextureCache` distinguishes two invalidation sources for `Entry::Sampled`:

1. **Known Targeted Writes (`InvalidateWrites`, `GetTextureForGpuUpload`, `MarkStale`, and sub-range `InvalidateRange(addr, size)` where `addr > 0 || size < mem_size_`)**:
   - The runtime knows that GPU work, CP DMA (`WRITE_DATA`), or a CPU producer (`ps4_gnm_notify_cpu_write`) wrote to `[addr, addr + size)`.
   - Sets `e->dirty = true` and `e->cpu_digest_valid = false`.
   - The next bind unconditionally uploads the texture (CPU or GPU) and refreshes its digest.

2. **Whole-Memory Submission Polling (`InvalidateRange(0, mem_size_, false)` from `OnSubmit()`)**:
   - Instead of locking `mutex_`, iterating over all 700+ entries, and setting `e->dirty = true` 10 times per frame, `InvalidateRange(0, mem_size_, false)` (when `!include_rts && write_epoch == ~0ull`) performs an `O(1)` atomic increment of `cpu_submit_epoch_` (`NoteCpuSubmission()`).
   - Each `Entry::Sampled` tracks `uint64_t cpu_check_epoch = 0`, `uint64_t cpu_digest = 0`, and `bool cpu_digest_valid = false`.
   - When a cached `Entry::Sampled` is bound in `GetTexture` or `GetTextureForGpuRefresh`:
     - If `!e->dirty && e->cpu_check_epoch == cur_submit_epoch`: fast cache hit; return `e->tex` immediately without even computing a digest (so a texture bound 50 times in the same submission is checked at most once per submission).
     - If `e->dirty || e->cpu_check_epoch != cur_submit_epoch`:
       - If `e->cpu_digest_valid` is true, compute `ComputeGuestDigestLocked(e, &dig)`.
       - If `dig == e->cpu_digest`: the guest bytes backing `e` have **not** changed since the last upload. Clear `e->dirty = false`, set `e->cpu_check_epoch = cur_submit_epoch`, increment `cpu_uploads_skipped_`, and **skip both `UploadLocked(e)` and `gpu_upload(e)`**.
       - If `!e->cpu_digest_valid` or `dig != e->cpu_digest`: the guest bytes **have** changed (or were invalidated by a targeted write). Execute the upload (`gpu_upload(e)` for `>= refresh_min_bytes` in `GetTextureForGpuRefresh`, or `UploadLocked(e)` otherwise), record `e->cpu_digest = dig; e->cpu_digest_valid = true; e->cpu_check_epoch = cur_submit_epoch;`.

### 2. Fast Two-Tier Guest Digest with Readable-Span Guard

`ComputeGuestDigestLocked(Entry* e, uint64_t* out)` computes a 64-bit digest over the readable guest memory of `e`:

1. **Readable-Span Guard (`ReadablePrefixBytes`)**:
   - On the first digest computation for `e` (`!e->readable_known`), queries `mach_vm_region` once on `mem_base_ + e->address` to determine the contiguous `VM_PROT_READ` byte span up to `std::min<uint64_t>(mem_size_ - e->address, e->layout.total_size)` and caches it in `e->readable_bytes`.
   - This prevents any fault if macro-tile layout padding extends onto a `PROT_NONE` guard page or unmapped region.

2. **Two-Tier Hashing**:
   - **Full Scan (`(!e->surf.is_block && e->levels == 1 && n <= 512 KiB) || n <= 16 KiB`)**:
     - Covers all single-level uncompressed surfaces up to `512 KiB` (including Sonic's `424x240` `407,040 B` Retro Engine framebuffer, `gnm_replay_test cpu-texture`'s `512 B` surface, and `tex_evict_test`'s `16 KiB` surface) as well as all small textures `<= 16 KiB`.
     - Hashes **every 8-byte word (100% of readable bytes)** so even a single-pixel CPU store anywhere in the surface is guaranteed to change the digest.
   - **Strided Cache-Line Probe Scan (`n > 16 KiB` compressed/mipmapped, or `n > 512 KiB`)**:
     - Covers the hundreds of megabytes of static BC1–BC7 / mipmapped world textures in 3D games like TLOU (`360 MiB` across 700 textures).
     - Hashes 64 evenly spaced 64-byte cache-line blocks (`4 KiB` total, always including the first 64 bytes, 62 interior blocks across the surface, and the final bytes).
     - Takes `~100 ns` per check (`< 0.1 ms` per frame across all 691 texture binds in TLOU) and requires **zero heap allocations** (only 24 bytes of metadata fields on `Entry`).

### 3. Lazy `ComputeSurfaceLayout` in `GetTextureImpl` & Hazard Short-Circuiting

In `TextureCache::GetTextureImpl`:
- Defer `ComputeSurfaceLayout(sd, &image_layout)` behind a lazy lambda `ensure_image_layout()`.
- Call `ensure_image_layout()` only when:
  1. Checking `texel_fits` against an actual `Entry::Color` candidate at `img.address` (when `!img.pixel.compressed`), or
  2. Creating a new `Entry::Sampled` on a cache miss (`3) create`).
- On normal `Entry::Sampled` cache hits, `e->layout` is already stored in the entry, avoiding thousands of redundant layout computations per frame.
- Track `cpu_unchanged_streak` on `Entry`: single-level uncompressed surfaces (`!e->surf.is_block && e->levels == 1`, such as CPU software-rendered framebuffers) and newly uploaded textures (`cpu_unchanged_streak < 4`) verify their guest digest on every `cpu_submit_epoch_` increment, while block-compressed or mipmapped assets that have remained unchanged across 4+ submissions throttle whole-memory submission polling to once every 64 submissions (while still reacting immediately to any explicit `InvalidateRange`, `InvalidateWrites`, or `MarkStale`).
- In `ResolveTextureHazards` (`ps4_gnm_draw.mm`), check the lock-free `OverlapsPendingWrite(img.address, approx)` before `S.tex->OverlapsGpuTexture(img.address, 1)` on storage images so `S.tex->mutex_` is never acquired when no pending write overlaps the image.

---

## Correctness & Fallback Invariants

1. **Aborted GPU Refresh (`MarkStale`)**:
   - In `SampledTexture` (`ps4_gnm_draw.mm`), if `GetTextureForGpuRefresh` hands out `up.tex` (recording `e->cpu_digest_valid = true`), and then `OverlapsPendingWrite`, `OverlapsGpuTexture`, or `EncodeGpuUpload` failure triggers `S.tex->MarkStale(img.address, up.tex)` followed by `S.tex->GetTexture(img)`, `MarkStale` MUST set `e->cpu_digest_valid = false` in addition to `e->dirty = true; e->gpu_upload_epoch = 0;`. This guarantees the immediate CPU fallback `GetTexture(img)` performs `UploadLocked(e)` instead of skipping it.
2. **GPU Hazard Upload (`GetTextureForGpuUpload`)**:
   - When `GetTextureForGpuUpload` (`refresh_min_bytes == 0, gpu_epochs != nullptr`) schedules a GPU upload behind an in-flight GPU write, it sets `e->cpu_digest_valid = false`, because the texture's new contents come from the GPU pipeline rather than the prior CPU guest snapshot.
3. **Reference Uploads (`DebugCpuUploadInto`)**:
   - `DebugCpuUploadInto` sets `tmp.cpu_digest_valid = false` on its temporary `Entry` copy so `PS4_GNM_VERIFY_GPU_UPLOAD` reference uploads always execute in full.
4. **Render Targets (`Entry::Color` / `Entry::Depth`)**:
   - Untouched by submission polling (`include_rts == false`); GPU-owned render targets are never overwritten by stale guest bytes.

---

## Verification Criteria

1. **Unit & Host Tests (`./tests/host/run_host_tests.sh`)**:
   - Extend `tests/host/tex_evict_test.mm` (`test_cpu_submission`) to verify:
     - Unchanged guest bytes after `InvalidateRange(0, g.size, false)` skip both CPU `GetTexture` uploads (`stats.uploads` unchanged, `GetMemStats().cpu_uploads_skipped` incremented) and GPU `GetTextureForGpuRefresh` uploads (`up.tex == nil`).
     - Modified guest bytes after `InvalidateRange(0, g.size, false)` trigger re-upload on both `GetTexture` and `GetTextureForGpuRefresh`.
     - `GetTextureForGpuUpload` (hazard GPU upload) invalidates `cpu_digest_valid`, so a subsequent `InvalidateRange` + `GetTexture` reloads guest bytes.
     - `MarkStale` invalidates `cpu_digest_valid`, so fallback `GetTexture` uploads guest bytes.
     - Readable-span guard handles a surface whose padded layout borders an unmapped/`PROT_NONE` page without faulting.
   - Run `gnm_replay_test cpu-texture` and `gnm_upload_bind_test` on both Metal 3 and Metal 4.
   - Run full `go test ./pkg/... ./cmd/...` and `go vet ./pkg/... ./cmd/...`.
2. **TLOU (`CUSA00557`) Performance Verification**:
   - Rebuild the TLOU binary in `/Users/manjarqo/Library/Application Support/PS4Native/games/CUSA00557/build` (and benchmark build if used).
   - Verify steady-state `encoder CPU` drops from `~36 ms` back to `~6–7 ms` (`texture uploads 0`, `gpu uploads 0` in steady state) and FPS returns to `~83+ FPS` at `1920x1080`.
3. **Sonic Origins Plus (`CUSA30448`) Performance & Correctness Verification**:
   - Rebuild Sonic Origins Plus via `./sonic-origins/rebuild.command`.
   - Verify Sonic 1 Green Hill benchmark maintains `~55 FPS` (`p50 ~18.3 ms`) and live rendering of CPU-backed surfaces (Marble Zone / Green Hill title and HUD) remains intact.
