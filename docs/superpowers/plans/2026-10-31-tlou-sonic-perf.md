# TLOU & Sonic Texture Submission Performance Implementation Plan

> Publication note (0.4.3): this document records the original design/plan, not a completed benchmark report. The shipped implementation fully hashes only readable spans of at most 4 KiB; larger spans use 64 sampled cache lines for single-level uncompressed surfaces and 16 for other surfaces, plus the final eight bytes. Stable compressed/mipmapped entries are polled every 64 submissions after four unchanged checks. These are heuristics: an ordinary CPU write outside the sampled bytes can be missed, and the document's original full-scan/single-pixel guarantee does not apply. Explicit targeted invalidations still force refreshes. The FPS values below are historical observations and targets, not a new controlled benchmark of the final release.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore The Last of Us Remastered (`CUSA00557`) 1080p performance from ~25 FPS (`36.0 ms` encoder CPU/frame) back to ~83+ FPS (`~6–7 ms` encoder CPU/frame) by eliminating redundant per-submission CPU/GPU texture re-uploads of unchanged guest memory, while preserving Sonic Origins Plus (`CUSA30448`) CPU framebuffer updates and ~55 FPS performance.

**Architecture:** Replace the unconditional O(N) full-cache `e->dirty = true` invalidation on every `OnSubmit()` with an O(1) submission epoch counter (`cpu_submit_epoch_`) and lazy per-entry 64-bit guest-memory digest verification (`ComputeGuestDigestLocked`) guarded by a one-time `mach_vm_region` readable-span check. Check the digest before both CPU uploads (`UploadLocked`) and bind-time GPU uploads (`GetTextureForGpuRefresh`), while keeping targeted GPU/DMA/Videodec write invalidations unconditional (`cpu_digest_valid = false`) and deferring `ComputeSurfaceLayout` in `GetTextureImpl` until needed.

**Tech Stack:** Objective-C++17, Metal 3 / Metal 4 (`libSceGnmDriver`), Mach VM (`mach_vm_region`), Go 1.27.1 (`ps4-recomp`).

---

## File Structure

- **Modify:** `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.h`
  - Add `cpu_uploads_skipped` to `TextureCache::MemStats`.
  - Add `ComputeGuestDigestLocked(Entry* e, uint64_t* out)` private helper declaration and `std::atomic<uint64_t> cpu_submit_epoch_{1}`, `std::atomic<uint64_t> cpu_uploads_skipped_{0}` members on `TextureCache`.
- **Modify:** `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.mm`
  - Add `cpu_digest`, `cpu_check_epoch`, `readable_bytes`, `cpu_digest_valid`, `readable_known` to `TextureCache::Entry`.
  - Implement `ReadablePrefixBytes` (using `mach_vm_region` on macOS) and `TextureCache::ComputeGuestDigestLocked`.
  - Update `UploadLocked`, `UploadLockedImpl`, `MarkStale`, `DebugCpuUploadInto`, `GetTextureImpl`, `InvalidateRange`, and `InvalidateWrites` to skip unchanged CPU-backed sampled texture uploads across submissions while forcing uploads on targeted GPU/CPU writes.
  - Defer `ComputeSurfaceLayout` in `GetTextureImpl` until an `Entry::Color` alias check or `Entry::Sampled` cache miss requires it.
- **Modify:** `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm`
  - Log `cpu_uploads_skipped` in the periodic `[gnm-mem] texture cache` telemetry line when non-zero.
- **Modify:** `tests/host/tex_evict_test.mm`
  - Expand `test_cpu_submission` to test:
    1. Skipping redundant CPU (`GetTexture`) and GPU (`GetTextureForGpuRefresh`) uploads after `InvalidateRange(0, g.size, false)` when guest bytes are unchanged.
    2. Uploading when guest bytes change (including single-pixel changes).
    3. Invalidating the digest on `GetTextureForGpuUpload`, `MarkStale`, and targeted `InvalidateRange(addr, size)`.
    4. Readable-span safety when a surface's padded layout borders a `PROT_NONE` page.

---

### Task 1: Add Failing Host Tests for Unchanged Submission Invalidation and Digest Invalidation

**Files:**
- Modify: `tests/host/tex_evict_test.mm:800-835`
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.h:940-948`

- [ ] **Step 1: Add `cpu_uploads_skipped` field to `TextureCache::MemStats` in `ps4_gnm_resources.h`**

```cpp
    struct MemStats {
        uint64_t sampled_count = 0, sampled_bytes = 0; // detiled from guest memory (re-creatable)
        uint64_t gpu_count = 0, gpu_bytes = 0;         // render targets, depth, storage (GPU-owned)
        uint64_t cpu_uploads_skipped = 0;              // unchanged sampled binds skipped after submission invalidation
    };
```

- [ ] **Step 2: Extend `test_cpu_submission` in `tests/host/tex_evict_test.mm` with tests for unchanged CPU/GPU refreshes, hazard/MarkStale invalidation, and `PROT_NONE` readable-span guard**

```cpp
        const uint64_t uploads = tc.stats.uploads;
        check(tc.GetTexture(Tsharp(0x10000, 64, 64)) == sampled && tc.stats.uploads == uploads,
              "CPU submission: repeated binds do not upload again");
        // Whole-memory submission invalidation with unchanged guest bytes must skip both CPU and GPU refresh.
        tc.InvalidateRange(0, g.size, false);
        check(tc.GetTexture(Tsharp(0x10000, 64, 64)) == sampled && tc.stats.uploads == uploads &&
                  tc.GetMemStats().cpu_uploads_skipped == 1,
              "CPU submission: unchanged guest bytes skip CPU upload after whole-memory invalidation");
        tc.InvalidateRange(0, g.size, false);
        TextureCache::GpuUpload up;
        check(tc.GetTextureForGpuRefresh(Tsharp(0x10000, 64, 64), 5, 1024, &up) == sampled && up.tex == nil &&
                  tc.stats.uploads == uploads && tc.GetMemStats().cpu_uploads_skipped == 2,
              "CPU submission: unchanged guest bytes skip GPU refresh upload after whole-memory invalidation");
        // Modifying guest bytes must trigger a GPU refresh when >= min_bytes.
        Fill(g, 0x10000, 64 * 64 * 4, 0x44);
        tc.InvalidateRange(0, g.size, false);
        check(tc.GetTextureForGpuRefresh(Tsharp(0x10000, 64, 64), 6, 1024, &up) == sampled && up.tex == sampled &&
                  tc.stats.uploads == uploads + 1,
              "CPU submission: changed guest bytes trigger GPU refresh upload");
        // MarkStale (aborted GPU refresh) must force the immediate CPU fallback GetTexture to upload.
        tc.MarkStale(0x10000, sampled);
        check(tc.GetTexture(Tsharp(0x10000, 64, 64)) == sampled && FirstByte(sampled) == 0x44 &&
                  tc.stats.uploads == uploads + 2,
              "CPU submission: MarkStale forces CPU fallback upload");
        // Hazard GPU upload (GetTextureForGpuUpload) invalidates the CPU digest so a later CPU invalidation reloads guest bytes.
        Fill(g, 0x10000, 64 * 64 * 4, 0x22);
        tc.InvalidateRange(0, g.size, false);
        tc.GetTexture(Tsharp(0x10000, 64, 64));
        const uint64_t after_22 = tc.stats.uploads;
        tc.GetTextureForGpuUpload(Tsharp(0x10000, 64, 64), 0, 10, &up);
        check(up.tex == sampled, "CPU submission: GPU hazard upload hands out texture");
        std::vector<uint8_t> gpu_pixels(64 * 64 * 4, 0x88);
        [sampled replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0
                     withBytes:gpu_pixels.data() bytesPerRow:64 * 4];
        tc.InvalidateRange(0, g.size, false);
        check(tc.GetTexture(Tsharp(0x10000, 64, 64)) == sampled && FirstByte(sampled) == 0x22 &&
                  tc.stats.uploads == after_22 + 2,
              "CPU submission: GPU hazard upload invalidates prior CPU digest");
        // Reference upload (DebugCpuUploadInto) is never skipped by digest equality.
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                      width:64 height:64 mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> reference = [dev newTextureWithDescriptor:td];
        check(tc.DebugCpuUploadInto(Tsharp(0x10000, 64, 64), reference) && FirstByte(reference) == 0x22,
              "CPU submission: reference uploads are never skipped by digest equality");
```

- [ ] **Step 3: Compile and run `tex_evict_test` to confirm it fails before the implementation**

Run:
```bash
cd /Users/manjarqo/ps4recomp-work/PS4Recomp && ./tests/host/run_host_tests.sh tex_evict_test
```
Expected: FAIL on `"CPU submission: unchanged guest bytes skip CPU upload after whole-memory invalidation"`.

---

### Task 2: Implement Submission Epoch, Guest-Memory Digest, and Lazy Layout in `TextureCache`

**Files:**
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.h`
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.mm`
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm`

- [ ] **Step 1: Add digest and submission epoch members to `TextureCache` and `TextureCache::Entry`**

In `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.h`:
- Declare `bool ComputeGuestDigestLocked(Entry* e, uint64_t* out);`
- Add `std::atomic<uint64_t> cpu_submit_epoch_{1}, cpu_uploads_skipped_{0};`

In `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.mm` (`struct TextureCache::Entry`):
- Add:
  ```cpp
  uint64_t cpu_digest = 0;
  uint64_t cpu_check_epoch = 0;
  uint64_t readable_bytes = 0;
  bool cpu_digest_valid = false;
  bool readable_known = false;
  ```

- [ ] **Step 2: Implement `ReadablePrefixBytes` and `TextureCache::ComputeGuestDigestLocked` in `ps4_gnm_resources.mm`**

Include `<mach/mach.h>` and `<mach/mach_vm.h>` under `#if defined(__APPLE__)`, implement `ReadablePrefixBytes`, and implement `ComputeGuestDigestLocked` with full 8-byte word hashing for `(!e->surf.is_block && e->levels == 1 && n <= 512 * 1024) || n <= 16 * 1024` and 64 strided 64-byte cache-line probes (`4 KiB`) plus tail word for larger/compressed surfaces.

- [ ] **Step 3: Wire digest checks and invalidation rules into `UploadLockedImpl`, `GetTextureImpl`, `MarkStale`, `DebugCpuUploadInto`, `InvalidateRange`, and `InvalidateWrites`**

1. In `UploadLocked`: only call `ps4_gnm_hitch_note_upload` when `stats.uploads` incremented (or `!ok`).
2. In `UploadLockedImpl`: track `bool complete = true;` (set `false` if any mip fails the bounds check); at the end, if `e->kind == Entry::Sampled && complete`:
   ```cpp
   e->cpu_digest_valid = ComputeGuestDigestLocked(e, &e->cpu_digest);
   e->cpu_check_epoch = cpu_submit_epoch_.load(std::memory_order_relaxed);
   ```
   Otherwise `e->cpu_digest_valid = false;`.
3. In `MarkStale`: set `it->second->cpu_digest_valid = false;`.
4. In `DebugCpuUploadInto`: set `tmp.cpu_digest_valid = false;`.
5. In `GetTextureImpl`:
   - Replace eager `ComputeSurfaceLayout(sd, &image_layout)` with lazy `ensure_image_layout()` called only inside `texel_fits` (when an `Entry::Color` is tested) and in `3) create`.
   - In `2) cached sampled texture with identical identity`:
     - Let `const uint64_t sub_epoch = cpu_submit_epoch_.load(std::memory_order_relaxed);`
     - Let `const bool need_cpu_check = e->dirty || e->cpu_check_epoch != sub_epoch;`
     - In `refresh_min_bytes` mode (`GetTextureForGpuRefresh`):
       If `need_cpu_check`:
       ```cpp
       uint64_t dig = 0;
       const bool dig_ok = ComputeGuestDigestLocked(e, &dig);
       if (e->cpu_digest_valid && dig_ok && dig == e->cpu_digest) {
           e->dirty = false;
           e->cpu_check_epoch = sub_epoch;
           cpu_uploads_skipped_.fetch_add(1, std::memory_order_relaxed);
       } else if (e->samples <= 1 && e->layout.total_size >= refresh_min_bytes) {
           gpu_upload(e);
           e->cpu_digest = dig;
           e->cpu_digest_valid = dig_ok;
           e->cpu_check_epoch = sub_epoch;
       } else {
           UploadLocked(e);
       }
       ```
     - In `gpu_epochs` hazard mode (`GetTextureForGpuUpload`, `refresh_min_bytes == 0`):
       If `(e->dirty || e->gpu_upload_epoch <= gpu_epochs[0]) && e->samples <= 1`:
       `gpu_upload(e); e->cpu_digest_valid = false;`
     - In `GetTexture` mode (`!gpu_epochs && !refresh_min_bytes`):
       If `need_cpu_check`:
       ```cpp
       uint64_t dig = 0;
       if (e->cpu_digest_valid && ComputeGuestDigestLocked(e, &dig) && dig == e->cpu_digest) {
           e->dirty = false;
           e->cpu_check_epoch = sub_epoch;
           cpu_uploads_skipped_.fetch_add(1, std::memory_order_relaxed);
       } else {
           UploadLocked(e);
       }
       ```
   - In `3) create`:
     When `gpu_upload(e)` is taken on creation:
     If `refresh_min_bytes > 0`, record `e->cpu_digest_valid = ComputeGuestDigestLocked(e, &e->cpu_digest); e->cpu_check_epoch = cpu_submit_epoch_.load(std::memory_order_relaxed);`.
     If `refresh_min_bytes == 0` (hazard path), set `e->cpu_digest_valid = false;`.
6. In `InvalidateRange(uint64_t addr, uint64_t size, bool include_rts, uint64_t write_epoch)`:
   - Fast path for full-memory submission polling:
     ```cpp
     if (addr == 0 && size >= mem_size_ && !include_rts && write_epoch == ~0ull) {
         cpu_submit_epoch_.fetch_add(1, std::memory_order_relaxed);
         return;
     }
     ```
   - For targeted range invalidations (`addr > 0 || size < mem_size_` or `include_rts` or `write_epoch != ~0ull`):
     When invalidating `e->kind == Entry::Sampled`, set `e->dirty = true; e->cpu_digest_valid = false; e->readable_known = false; stats.invalidations++;`.
7. In `InvalidateWrites`:
   - When invalidating `e->kind == Entry::Sampled`, set `e->dirty = true; e->cpu_digest_valid = false; stats.invalidations++;`.

- [ ] **Step 4: Run `tex_evict_test`, `gnm_replay_test`, and `gnm_upload_bind_test` on Metal 3 and Metal 4**

Run:
```bash
cd /Users/manjarqo/ps4recomp-work/PS4Recomp && ./tests/host/run_host_tests.sh
```
Expected: All host tests PASS on both Metal 3 and Metal 4.

---

### Task 3: Run Go Tests, Vet, and Sync Engine Sources

**Files:**
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.h`
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.mm`
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm`
- Modify: `tests/host/tex_evict_test.mm`

- [ ] **Step 1: Run Go unit tests and `go vet`**

Run:
```bash
cd /Users/manjarqo/ps4recomp-work/PS4Recomp && go test ./pkg/... ./cmd/... && go vet ./pkg/... ./cmd/...
```
Expected: PASS with zero warnings or errors.

- [ ] **Step 2: Rebuild `ps4-recomp` binary and sync runtime files into active builds**

Rebuild the `ps4-recomp` binary in `PS4Recomp` (and copy updated `libSceGnmDriver` sources into `/Users/manjarqo/ps4recomp-work/publication-20261031` if kept in sync), then rebuild:
1. TLOU in `/Users/manjarqo/Library/Application Support/PS4Native/games/CUSA00557/build` (and `/Users/manjarqo/ps4recomp-work/tlou_build` if used for automated route testing).
2. Sonic Origins Plus via `/Users/manjarqo/ps4recomp-work/sonic-origins/rebuild.command`.

---

### Task 4: Benchmark and Verify TLOU (`CUSA00557`) and Sonic Origins Plus (`CUSA30448`)

- [ ] **Step 1: Verify TLOU 1920x1080 performance**

Run TLOU benchmark/test route (isolated with `heavy_lock.sh` / no concurrent GPU work) and inspect `[gnm-draw] perf:` and `[gnm-mem]` telemetry:
- Confirm steady-state `texture uploads` and `gpu uploads` drop from `426` and `265` per frame to `0` per frame.
- Confirm `encoder CPU` drops from `~36.0 ms` back to `~6–7 ms` per frame and FPS returns to `~83+ FPS`.

- [ ] **Step 2: Verify Sonic Origins Plus performance and rendering**

Run `./sonic-origins/performance/run-benchmark.command` (or controlled Green Hill benchmark run) with no concurrent builds/tests:
- Confirm Green Hill steady-state FPS remains `~55 FPS` (`p50 ~18.3 ms`).
- Confirm CPU-updated Retro Engine framebuffer renders properly (non-black level title / gameplay / HUD).
