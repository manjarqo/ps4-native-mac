# Bloodborne: Game of the Year Edition (CUSA03173 v01.09) Bring-up Implementation Plan

> 0.5.0 publication scope: this is the development design/plan, not independent proof that every acceptance criterion passed. See README, CHANGELOG and docs/performance-0.5.0.json for audited measurement scope. The local Bloodborne 60 FPS modification is not distributed; unsafe compute-clear substitution was removed, write/upgrade ordering corrected, and STD remains unsupported. No new controlled gameplay benchmark of those final safety changes is claimed.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Bloodborne: Game of the Year Edition (`CUSA03173` v01.09) to an excellently playable state on Apple Silicon Mac using our native AOT x86-64 → ARM64 recompiler and HLE runtime, adapting all applicable GPL-2.0 findings from `Wooloomooloo2/bloodborne_mac_port` (`mac-v0.5.12`) while guaranteeing zero regression on The Last of Us Remastered (`CUSA00557`).

**Architecture:** We follow our proven multi-phase bring-up workflow:
1. Sync the analyzer/lifter opcode table and implement the remaining x86-64 instructions (`VMASKMOVDQU`, `RDTSCP`, `ADCX`, `VFNMADD213SS`, `VPMULHUW`, `FSTCW`) + filter unreferenced companion PRX middleware modules (`libSceFace`, `libSceHand`, `libSceHeadTracker`, `libSceS3DConversion`, `libSceSmart`).
2. Implement and refine all required Kernel, Sync (64-bit semaphore wire ABI), SaveData v1, DiscMap, Rtc, Np, and 7.1 AudioOut downmix HLE behaviours.
3. Implement `libSceGnmDriver` packet-builder fixes (`sceGnmUnmapComputeQueue`, `sceGnmSetLsShader`, `sceGnmComputeWaitOnAddress`, `sceGnmSetPsShader(NULL)`, `PatchFlipRequest` flip labels + EOP interrupt events, atomic 64-bit GPU labels, `header == 0` step, attachmentless `16x16` render pass clamp).
4. Port `3rdparty/gcn-recompiler` stability, visual, and performance fixes (null descriptor guard in `info.h`, IEEE-754 bit-pattern NaN/Inf clamping in `emit_spirv_floating_point.cpp` & `vector_alu.cpp`, and `NoContraction` → `Invariant` `output_position` + `preserveInvariance = YES`) and rebuild `libgcn_recompiler.a`.
5. Implement `libSceAvPlayer` (`pkg/runtime/modules/libSceAvPlayer/ps4_avplayer.c`) using `ps4_vfs`, `recomp_call_guest` for `memory_replacement`/`file_replacement`, and `ps4_h264_vt` (`VideoToolbox`) hardware MP4 H.264 decoding with synchronous stop/drain before freeing guest buffers.
6. Implement Tessellation (`LS → HS → ES → VS`) and Geometry Shader (`ES → GS → Copy VS`) pipelines in `gcn_msl.cpp` and `ps4_gnm_draw.mm`.
7. Build, run, and verify Bloodborne (`CUSA03173` v01.09) through intro movies, title screen, character creation, 1st Floor Sickroom, Hunter's Dream, and Central Yharnam gameplay, and register `CUSA03173` in `pkg/compat/compat.json`.

**Mandatory TLOU (`CUSA00557`) Non-Regression Rule:** Every single task and phase in this plan MUST verify that The Last of Us Remastered (`CUSA00557`) does not break or regress, using `go test ./...`, `bash tests/host/run_host_tests.sh`, and the 120-second TLOU courtyard route (`tools/metal4_route.sh`) with `fatal 0`, `gpu_err 0`, `watchdog 0`, and FPS within noise of baseline.

**Tech Stack:** Go (`cmd/`, `pkg/lifter/`, `pkg/elfloader/`, `pkg/compat/`), C / C++ / Objective-C++ HLE runtime (`pkg/runtime/`), Metal 3 & Metal 4 renderer (`pkg/runtime/modules/libSceGnmDriver/`), `gcn-recompiler` (`3rdparty/gcn-recompiler`), host tests (`tests/host/run_host_tests.sh`), `tools/heavy_lock.sh`, `tools/metal4_route.sh`.

**Spec:** `docs/superpowers/specs/2026-10-31-bloodborne-bringup-design.md`

---

## Global Constraints & Shared Commands

- `$W` = `/Users/manjarqo/ps4recomp-work`
- `$R` = `/Users/manjarqo/ps4recomp-work/publication-20261031`
- `$BB` = `"/Users/manjarqo/Library/Application Support/PS4Native/games/CUSA03173/content"`
- `$TLOU` = `"/Volumes/ssd/The Last of Us Remastered Repack1/CUSA00557"`
- `$REF` = `/Users/manjarqo/ps4recomp-work/bloodborne_mac_port`

### 1. Go Verification Suite (Run after every Go change)
```bash
cd "$R" && go vet ./... && test -z "$(gofmt -l cmd pkg)" && go test ./...
```

### 2. Host C/C++/ObjC++ Verification Suite (Run after every runtime/renderer/shader change)
```bash
cd "$R" && "$W/tools/heavy_lock.sh" bash tests/host/run_host_tests.sh
```
Expected: ends with `host tests: PASS`.

### 3. Mandatory TLOU (`CUSA00557`) 120s Non-Regression Check (Run at the end of every Task & Phase)
```bash
mkdir -p "$W/bb_research/runs"
cd "$R" && go build -buildvcs=false -o ps4-recomp ./cmd/ps4-recomp
"$W/tools/heavy_lock.sh" ./ps4-recomp "$TLOU/eboot.bin" \
  --app-dir "$TLOU" -o "$W/bb_research/tlou_check" -c -j 6 > "$W/bb_research/tlou_gen.log" 2>&1
cd "$R" && HEAVY_EXCLUSIVE=1 "$W/tools/heavy_lock.sh" \
  env BUILD="$W/bb_research/tlou_check" TAG="bb_tlou_<task>" SECS=120 EVERY=0 \
  OUT="$W/bb_research/runs" tools/metal4_route.sh
python3 "$R/tools/metal4_route_report.py" "$W/bb_research/runs/bb_tlou_<task>.log"
```
Expected: `fatal 0`, `gpu_err 0`, `watchdog 0`, and courtyard steady-state FPS within ±3 fps of baseline.

---

## Phase 1: Lifter, Companion PRX Filtering & CPU/HLE Boot

### Task 1: Lifter Opcode Sync, Remaining x86-64 Instructions & Companion PRX Filtering

**Context:**
1. `pkg/lifter/opcodes.go` (`IsOpcodeSupported`) is missing ~104 opcodes that are already implemented in `pkg/lifter/arm64_lifter.go`. Syncing `opcodes.go` and implementing the remaining instructions (`VMASKMOVDQU`, `RDTSCP`, `ADCX`, `VFNMADD213SS`, `VPMULHUW`, `FSTCW`) brings Bloodborne `eboot.bin`, `libc.prx`, and `libSceFios2.prx` instruction support to ~100%.
2. `pkg/elfloader/modules.go` (`DiscoverCompanionModules`) currently loads all 7 `sce_module/*.prx` files in `CUSA03173/content/sce_module/`, even though 5 of them (`libSceFace.prx`, `libSceHand.prx`, `libSceHeadTracker.prx`, `libSceS3DConversion.prx`, `libSceSmart.prx`) are unused PS Camera / AR middleware that export zero symbols imported by `eboot.bin` and are not listed in `ReferencedModuleNames(eboot)`. Filtering out unreferenced companion PRXs that satisfy zero unresolved imports avoids lifting 3.4 MB of dead code.

**Files:**
- Modify: `pkg/lifter/opcodes.go`
- Modify: `pkg/lifter/arm64_lifter.go`
- Modify: `pkg/lifter/lifter_test.go`
- Modify: `pkg/elfloader/modules.go`
- Modify: `pkg/elfloader/modules_test.go` (or add test in `pkg/elfloader/`)

- [x] **Step 1: Write failing tests in `pkg/lifter/lifter_test.go` and `pkg/elfloader/`**
  - Add unit tests in `pkg/lifter/lifter_test.go` verifying:
    - Every opcode handled in `pkg/lifter/arm64_lifter.go` returns `true` from `IsOpcodeSupported(op)`.
    - `VMASKMOVDQU xmm1, xmm2` (stores bytes of `xmm1` where byte MSB of `xmm2` is 1 to `[rdi]`), `RDTSCP` (reads cycle counter into `EAX:EDX` and sets `RCX = 0`), `ADCX r64, r/m64` (unsigned add with `CF`), `VFNMADD213SS`, `VPMULHUW`, and `FSTCW` lift cleanly without `UNSUPPORTED`.
  - Add a unit test in `pkg/elfloader/` verifying that `DiscoverCompanionModules` keeps PRXs that either match `ReferencedModuleNames(eboot)` or export at least one symbol imported by `eboot.bin` (or transitive kept PRXs), and skips unreferenced PRXs with zero matching exports.

- [x] **Step 2: Implement the changes in `pkg/lifter/opcodes.go`, `pkg/lifter/arm64_lifter.go`, and `pkg/elfloader/modules.go`**
  - Update `IsOpcodeSupported` in `pkg/lifter/opcodes.go` to include all opcodes handled in `pkg/lifter/arm64_lifter.go`.
  - Implement `VMASKMOVDQU`, `RDTSCP`, `ADCX`, `VFNMADD213SS`, `VPMULHUW`, and `FSTCW` in `pkg/lifter/arm64_lifter.go`.
  - Update `DiscoverCompanionModules` in `pkg/elfloader/modules.go` so candidate `.prx` files in `sce_module/` that are neither referenced by module name nor export any symbol imported by `eboot` (or another kept companion module) are excluded.

- [x] **Step 3: Verify Go tests, Bloodborne `analyze`, and TLOU non-regression**
  - Run `cd "$R" && go vet ./... && test -z "$(gofmt -l cmd pkg)" && go test ./...`
  - Run `./ps4-recomp analyze "$BB/eboot.bin"` and verify ~100% instruction coverage.
  - Run the **Mandatory TLOU 120s Non-Regression Check** (`TAG=bb_tlou_task1`).

---

### Task 2: Kernel, 64-bit Semaphore Wire ABI, SaveData v1, DiscMap, Rtc, Np & Audio 7.1 Downmix HLE

**Context:**
Implement all non-GNM, non-AvPlayer HLE symbols required by Bloodborne (`eboot.bin`, `libc.prx`, `libSceFios2.prx`) and port the general Orbis kernel/audio fixes from `Wooloomooloo2/bloodborne_mac_port`:
1. **Direct Memory (`pkg/runtime/kernel/memory/ps4_direct_mem.c`)**:
   - Implement `sceKernelGetDirectMemoryType(uint64_t start, int *memType, uint64_t *regionStartOut, uint64_t *regionEndOut)` (`NID: BC+OG5m9+bw`): look up `start` in `g_dmem_allocs[]`, write `*memType`, `*regionStartOut`, `*regionEndOut`, return `0` (or `SCE_KERNEL_ERROR_ENOENT` / `0x80020002` if unallocated, `0x80020016` if `memType == NULL`).
   - In `sceKernelReleaseDirectMemory`, also unmap any virtual mappings in `g_vmem_maps[]` whose physical range overlaps `[phys_addr, phys_addr + len)`.
2. **64-bit Semaphore Wire ABI (`pkg/runtime/kernel/sync/ps4_semaphore.c`)**:
   - In `sceKernelCreateSema`: validate `pOptParam != NULL -> return 0x80020016` first, then `pSema == NULL || name == NULL || initCount < 0 || maxCount <= 0 || initCount > maxCount -> return 0x80020016`.
   - Allocate monotonic non-reused IDs (`s_next_id++`) and write a full 64-bit value `*(int64_t *)pSema = (int64_t)id` (and on error if `pSema != NULL`, `*(int64_t *)pSema = 0`).
   - In `Wait`/`Poll`/`Signal`/`Cancel`/`Delete`: read full 64-bit `ctx->rdi` (`int64_t sema_id = (int64_t)ctx->rdi`) and reject any handle where `sema_id <= 0 || sema_id >= MAX_SEMAS || !g_semas[sema_id].in_use` with `0x80020003` (`SCE_KERNEL_ERROR_ESRCH`).
3. **Posix & Threading (`pkg/runtime/kernel/sync/ps4_sync.c`, `pkg/runtime/kernel/threading/ps4_threading.c`, `pkg/runtime/kernel/posix/ps4_posix_misc.c`)**:
   - `scePthreadRwlockTimedrdlock` (`iPtZRWICjrM`) and `scePthreadRwlockTimedwrlock` (`adh--6nIqTk`) in `ps4_sync.c`.
   - `sleep` (`0wu33hunNdE`) and `pthread_attr_setschedparam` (`euKRgm0Vn2M`) in `ps4_threading.c`.
   - `sysctl`, `sceKernelGettimezone`, `__Ux86_64_setcontext`, `sigreturn` in `ps4_posix_misc.c` / `ps4_signals.c` (with exports registered in `module_exports.go` for both `libkernel` and `libScePosix`).
4. **`libSceDiscMap` (`pkg/runtime/modules/libSceDiscMap/ps4_discmap.c`)**:
   - Implement `sceDiscMapIsRequestOnHDD` (`ioKMruft1ek`) and `sceDiscMap_8A828CAEE7EDD5E9` (`ioKMruft5ek`) returning `0` (all game data is on HDD).
5. **`libSceRtc` (`pkg/runtime/modules/libSceRtc/ps4_rtc.c`)**:
   - Implement `sceRtcConvertUtcToLocalTime` (`M1TvFst-jrM`), `sceRtcConvertLocalTimeToUtc` (`8Yr143yEnRo`), and `sceRtcFormatRFC2822LocalTime` (`AxHBk3eat04`).
6. **`libSceSaveData` v1 Wrappers (`pkg/runtime/modules/libSceSaveData/ps4_savedata.c`)**:
   - `sceSaveDataMount` (`32HQAQdwM2o`): translate `SceSaveDataMount` v1 layout (`userId` at `+0x00`, `dirName` at `+0x08`, `fingerprint` at `+0x10`, `blocks` at `+0x18`, `mountMode` at `+0x20`) to our internal `SceSaveDataMount2` handler.
   - `sceSaveDataSetupSaveDataMemory` (`v7AAAMo0Lz4`), `sceSaveDataGetSaveDataMemory` (`7Bt5pBC-Aco`), `sceSaveDataSetSaveDataMemory` (`h3YURzXGSVQ`): translate v1 structs to our existing `SaveDataMemory2` (slot 0) implementation.
7. **`libSceNp*` (50 symbols in `ps4_np.c`), `libSceNpTrophy` (2 symbols in `ps4_nptrophy.c`), `scePlayGoGetChunkId` (`ps4_playgo.c`), `sceSystemServiceLaunchWebBrowser` (`ps4_systemservice.c`), `sceVoiceDisconnectIPortFromOPort` (`ps4_voice.c`)**:
   - Implement offline signed-out console semantics and register all NIDs in `pkg/runtime/module_exports.go`.
8. **7.1 Audio Downmix (`pkg/runtime/modules/libSceAudioOut/ps4_audioout.c`)**:
   - In the float (`ch == 8`) and int16 (`ch == 8`) downmix loops, mix `0.7071f * FC` (`ch[2]`) into both `L` and `R`, `0.5f * (SL + BL)` (`ch[4] + ch[6]`) into `L`, and `0.5f * (SR + BR)` (`ch[5] + ch[7]`) into `R`, clamping to `[-1.0f, 1.0f]` / `[-32768, 32767]`.

**Files:**
- Modify: `pkg/runtime/module_exports.go`
- Modify: `pkg/runtime/kernel/memory/ps4_direct_mem.c`
- Modify: `pkg/runtime/kernel/sync/ps4_semaphore.c`
- Modify: `pkg/runtime/kernel/sync/ps4_sync.c`
- Modify: `pkg/runtime/kernel/threading/ps4_threading.c`
- Modify: `pkg/runtime/kernel/posix/ps4_posix_misc.c`
- Create: `pkg/runtime/modules/libSceDiscMap/ps4_discmap.c`
- Modify: `pkg/runtime/modules/libSceRtc/ps4_rtc.c`
- Modify: `pkg/runtime/modules/libSceSaveData/ps4_savedata.c`
- Modify: `pkg/runtime/modules/libSceNp/ps4_np.c`
- Modify: `pkg/runtime/modules/libSceNpTrophy/ps4_nptrophy.c`
- Modify: `pkg/runtime/modules/libScePlayGo/ps4_playgo.c`
- Modify: `pkg/runtime/modules/libSceSystemService/ps4_systemservice.c`
- Modify: `pkg/runtime/modules/libSceVoice/ps4_voice.c`
- Modify: `pkg/runtime/modules/libSceAudioOut/ps4_audioout.c`
- Modify/Create: host tests in `tests/host/` (`semaphore_test.c`, `savedata_test.c`, `direct_mem_test.c`, `rtc_test.c`, `run_host_tests.sh`)

- [x] **Step 1: Write failing host tests in `tests/host/`**
  - Test 64-bit `SceKernelSema` wire ABI (garbage in upper 32 bits of `*pSema` is overwritten on `CreateSema`; corrupting upper 32 bits causes `WaitSema` to return `0x80020003`; `pOptParam != NULL` returns `0x80020016` even if `maxCount == 0`).
  - Test `sceKernelGetDirectMemoryType` and virtual unmap on `sceKernelReleaseDirectMemory`.
  - Test `sceSaveDataMount` v1 struct layout (`blocks` at `+0x18`, `mountMode` at `+0x20`) and `SaveDataMemory` v1 round-trip (`Setup`, `Set`, `Get`).
  - Test `sceRtcConvertUtcToLocalTime`, `sceRtcConvertLocalTimeToUtc`, and `sceRtcFormatRFC2822LocalTime`.

- [x] **Step 2: Implement the HLE functions and register NIDs in `pkg/runtime/module_exports.go`**

- [x] **Step 3: Verify Go tests, host tests, and TLOU 120s non-regression**
  - Run `cd "$R" && go vet ./... && test -z "$(gofmt -l cmd pkg)" && go test ./...`
  - Run `cd "$R" && "$W/tools/heavy_lock.sh" bash tests/host/run_host_tests.sh`
  - Run the **Mandatory TLOU 120s Non-Regression Check** (`TAG=bb_tlou_task2`).

---

## Phase 2: GNM Packet Builders, Flip Labels, Shader Recompiler Fixes & First Frame

### Task 3: `libSceGnmDriver` Packet Builders, `PatchFlipRequest`, Atomic GPU Labels & Attachmentless Clamp

**Context:**
Bloodborne's rendering thread builds PM4 command buffers via `libSceGnmDriver` and paces frames using `sceGnmPrepareFlipWithEopInterrupt` + polling on its user GPU flip label. Comparing our `libSceGnmDriver` against `Wooloomooloo2/bloodborne_mac_port` (`hle/libraries/libSceGnmDriver.c`) identified exact packet-builder and flip-label fixes:
1. **`sceGnmUnmapComputeQueue` (`pkg/runtime/modules/libSceGnmDriver/ps4_gnmdriver.h/.c`)**:
   - Change signature from `(uint32_t pipe_id, uint32_t queue_id)` to `(uint32_t vqueue_id)` (1 argument in `ctx->rdi`).
2. **`sceGnmSetLsShader` (`ps4_gnmdriver.c`)**:
   - Emit the missing 3-dword `SET_SH_REG(0x14b, ls_regs[3])` (`SPI_SHADER_PGM_RSRC2_LS`) packet so `sceGnmSetLsShader` writes all `0x17` (`23`) dwords.
3. **`sceGnmComputeWaitOnAddress` (`ps4_gnmdriver.c`)**:
   - Emit the 14-dword (`0x0e`) `NOP(3) + WAIT_REG_MEM(7) + NOP(4)` packet and return `0x0e`.
4. **`sceGnmSetPsShader` (`ps4_gnmdriver.c`)**:
   - When `ps_regs == NULL`, do not write `CB_SHADER_MASK = 0xf` (keep that only in `sceGnmSetPsShader350`).
5. **`PatchFlipRequest` (`0xabcdef10..0xabcdef13`) & Atomic GPU Labels (`ps4_gnmdriver.c`, `ps4_gnm_metal.mm`)**:
   - In `sceGnmPrepareFlip`, `sceGnmPrepareFlipWithEopInterrupt`, and `sceGnmPrepareFlipWithEopInterruptRequeued`, write the `PatchFlipRequest` sentinel (`0xabcdef10..0xabcdef13`) with the target `label_addr`, `value`, and interrupt parameters into `dcb`, and process it in `PatchFlipRequest` during `sceGnmSubmitAndFlipCommandBuffers*` / `ps4_gnm_metal.mm` so user flip labels are updated (`__atomic_store_n((uint64_t *)label, val, __ATOMIC_RELEASE)`) and EOP kernel events (`EVFILT_GRAPHICS_CORE` / `SceVideoOut` flip events) fire.
   - Use `__atomic_store_n(..., __ATOMIC_RELEASE)` for all 64-bit GPU label writes in `ps4_gnm_metal.mm`.
6. **`ps4_gnm_metal.mm` PM4 `header == 0` step**:
   - Advance `pc += 1` (not `pc += 2`) when `header == 0`.
7. **4 Missing `libSceGnmDriver` Exports**:
   - `sceGnmValidateCommandBuffers` (`NID: g3ab1269s9I`) returning `0x80D11001` (`SCE_GNM_ERROR_VALIDATION_NOT_ENABLED`).
   - `sceRazorCaptureCommandBuffersOnlyImmediate` (`V31V0139gfU`), `sceRazorCaptureCommandBuffersOnlySinceLastFlip` (`f2733772-sI`), `sceRazorCaptureImmediate` (`c5723889-dE`) returning `0`.
8. **Attachmentless Render Pass `16x16` Clamp (`ps4_gnm_draw.mm`)**:
   - When `!any_attachment && !ps_enabled`, clamp `renderPassWidth = 16; renderPassHeight = 16;` instead of `16384x16384` so Apple Silicon's TBDR tiler does not bin 262,144 tiles on vertex-only passes.

**Files:**
- Modify: `pkg/runtime/module_exports.go`
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnmdriver.h`
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnmdriver.c`
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_metal.mm`
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm`
- Modify/Create: host tests in `tests/host/`

- [x] **Step 1: Write failing host tests in `tests/host/`**
  - Verify `sceGnmSetLsShader` writes 23 dwords including `SET_SH_REG(0x14b, ...)`.
  - Verify `sceGnmComputeWaitOnAddress` writes 14 dwords and returns `0x0e`.
  - Verify `sceGnmPrepareFlipWithEopInterrupt` + `sceGnmSubmitAndFlipCommandBuffers` updates the user flip label and triggers EOP completion.

- [x] **Step 2: Implement the `libSceGnmDriver` and `ps4_gnm_metal.mm` / `ps4_gnm_draw.mm` changes**

- [x] **Step 3: Verify Go tests, host tests, and TLOU 120s non-regression**
  - Run `cd "$R" && go vet ./... && test -z "$(gofmt -l cmd pkg)" && go test ./...`
  - Run `cd "$R" && "$W/tools/heavy_lock.sh" bash tests/host/run_host_tests.sh`
  - Run the **Mandatory TLOU 120s Non-Regression Check** (`TAG=bb_tlou_task3`).

---

### Task 4: `3rdparty/gcn-recompiler` Fixes (Null Descriptors, Cainhurst NaN/Inf Clamping, `Invariant` Position)

**Context:**
Port the three critical shader recompiler improvements from `Wooloomooloo2/bloodborne_mac_port/gpu/shadps4/shader_recompiler` into our `3rdparty/gcn-recompiler` and `ps4_gnm_draw.mm`:
1. **Null Descriptor Guard (`3rdparty/gcn-recompiler/src/shader_recompiler/info.h`)**:
   - In `ReadUdReg` and `ReadTessConstantBuffer`, zero-initialize `T data{};` and guard `if (base < 0x10000ULL) { return data; }` before `std::memcpy` so null/uninitialized descriptor slots in user-data tables (e.g., Ebrietas / Amygdala shaders) do not cause `SIGBUS`.
2. **Cainhurst NaN/Inf Red-Flash Fix (`emit_spirv_floating_point.cpp`, `vector_alu.cpp`)**:
   - Under Metal's default fast-math, `isnan()`/`isinf()` intrinsics and `0.0 * NaN` are optimized away, allowing `NaN`/`Inf` from `V_RCP_F32`/`V_RSQ_F32`/`V_LOG_F32` to corrupt Bloodborne's bloom chain (bright red/black flashes).
   - In `emit_spirv_floating_point.cpp`: implement `EmitFPIsNan32` and `EmitFPIsInf32` using integer bitcast + bit-mask checks (`(bits & 0x7f800000u) == 0x7f800000u && (bits & 0x007fffffu) != 0` for NaN; `(bits & 0x7fffffffu) == 0x7f800000u` for Inf), and flush `NaN` to `+0.0f` before `FClamp` in `EmitFPSaturate32`.
   - In `vector_alu.cpp`: update `ClampInf` (`V_LOG_CLAMP_F32`, `V_RCP_CLAMP_F32`, `V_RSQ_CLAMP_F32`, `V_RSQ_LEGACY_F32`) to use bitcast `0x7f800000u` checks, update `V_RCP_LEGACY_F32` to extract sign via bitcast (`0x80000000u`), and update `LegacyMul` to test `(lhs_bits & 0x7fffffffu) == 0 || (rhs_bits & 0x7fffffffu) == 0`.
3. **`NoContraction` → `Invariant` Position (`emit_spirv_floating_point.cpp`, `spirv_emit_context.cpp`, `ps4_gnm_draw.mm`)**:
   - In `emit_spirv_floating_point.cpp`: apply `NoContraction` only when `ctx.stage == Stage::TessellationEval || ctx.stage == Stage::Geometry || ctx.profile.NeedPositionNoContraction(ctx.runtime_info.hw_stage)` (`HwStage::Export`), removing it from Fragment, Compute, and standard Vertex ALU ops so Apple Silicon's hardware FMA unit is used.
   - In `spirv_emit_context.cpp`: decorate `output_position` with `spv::Decoration::Invariant` when `stage == LogicalStage::Vertex`.
   - In `ps4_gnm_draw.mm`: set `opts.preserveInvariance = YES;` on `MTLCompileOptions`.
4. **Rebuild `3rdparty/gcn-recompiler/libgcn_recompiler.a`**.

**Files:**
- Modify: `3rdparty/gcn-recompiler/src/shader_recompiler/info.h`
- Modify: `3rdparty/gcn-recompiler/src/shader_recompiler/profile.h`
- Modify: `3rdparty/gcn-recompiler/src/shader_recompiler/backend/spirv/emit_spirv_floating_point.cpp`
- Modify: `3rdparty/gcn-recompiler/src/shader_recompiler/backend/spirv/spirv_emit_context.cpp`
- Modify: `3rdparty/gcn-recompiler/src/shader_recompiler/frontend/translate/vector_alu.cpp`
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm`
- Modify/Create: host shader test in `tests/host/`

- [x] **Step 1: Write a host test in `tests/host/` verifying null-descriptor safety, bit-pattern NaN/Inf clamping in generated MSL, and `[[invariant]]` vertex position**
- [x] **Step 2: Apply the changes in `3rdparty/gcn-recompiler`, rebuild `libgcn_recompiler.a`, and set `opts.preserveInvariance = YES` in `ps4_gnm_draw.mm`**
- [x] **Step 3: Verify host tests and TLOU 120s non-regression**
  - Run `cd "$R" && "$W/tools/heavy_lock.sh" bash tests/host/run_host_tests.sh`
  - Run the **Mandatory TLOU 120s Non-Regression Check** (`TAG=bb_tlou_task4`).

---

## Phase 3: `libSceAvPlayer` Movies & Bloodborne Boot-to-Gameplay Bring-Up

### Task 5: Implement `libSceAvPlayer` (`pkg/runtime/modules/libSceAvPlayer/ps4_avplayer.c`)

**Context:**
Bloodborne uses `libSceAvPlayer` (16 symbols) to play `FDPrs_Sprj_Logo.mp4` at boot and `Sprj_Title.mp4` on the title screen. It supplies guest callbacks in `SceAvPlayerInitData`:
- `memory_replacement` (`object_ptr`, `allocate`, `deallocate`, `allocate_texture`, `deallocate_texture`)
- `file_replacement` (`object_ptr`, `open`, `close`, `readOffset`, `size`)
and calls `sceAvPlayerGetVideoDataEx` to receive decoded NV12 frames (`SceAvPlayerFrameInfoEx` with `pData` pointing into guest texture memory allocated via `allocate_texture`).

We can adapt the clean MP4 demuxer + `VideoToolbox` H.264 / AAC decoder architecture from `Wooloomooloo2/bloodborne_mac_port/hle/avplayer_Impl.mm` and `hle/libraries/libSceAvPlayer.c` into `pkg/runtime/modules/libSceAvPlayer/ps4_avplayer.c` (using our `recomp_call_guest` for guest callbacks, `ps4_vfs` when `file_replacement` is null, and our `ps4_h264_vt.h` or `VideoToolbox`/`AudioToolbox` directly), while ensuring `sceAvPlayerStop` and `sceAvPlayerClose` synchronously drain/join any background decode work before calling `deallocate_texture` / `deallocate` (eliminating `bloodborne_mac_port` race `#46/#84`).

**Files:**
- Create: `pkg/runtime/modules/libSceAvPlayer/ps4_avplayer.h`
- Create: `pkg/runtime/modules/libSceAvPlayer/ps4_avplayer.c`
- Modify: `pkg/runtime/module_exports.go`
- Create: `tests/host/avplayer_test.c`
- Modify: `tests/host/run_host_tests.sh`

- [x] **Step 1: Write `tests/host/avplayer_test.c` testing `sceAvPlayerInit`, `AddSource`, `StreamCount`, `GetStreamInfo`, `EnableStream`, `Start`, `GetVideoDataEx`, `GetAudioData`, `IsActive`, `CurrentTime`, `Stop`, and `Close` with mock guest `memory_replacement` callbacks**
- [x] **Step 2: Implement `pkg/runtime/modules/libSceAvPlayer/ps4_avplayer.c` and register all 16 NIDs in `pkg/runtime/module_exports.go`**
- [x] **Step 3: Verify Go tests, host tests, and TLOU 120s non-regression**
  - Run `cd "$R" && go vet ./... && test -z "$(gofmt -l cmd pkg)" && go test ./...`
  - Run `cd "$R" && "$W/tools/heavy_lock.sh" bash tests/host/run_host_tests.sh`
  - Run the **Mandatory TLOU 120s Non-Regression Check** (`TAG=bb_tlou_task5`).

---

### Task 6: First Full Bloodborne Build & Boot-to-Gameplay Bring-Up (`bb_build`)

**Context:**
With 100% instruction coverage and 0 unresolved imports across `eboot.bin`, `libc.prx`, and `libSceFios2.prx`, compile Bloodborne into `/Users/manjarqo/ps4recomp-work/bb_build` and run it time-bounded under `tools/heavy_lock.sh` to verify boot, splash movie (`FDPrs_Sprj_Logo.mp4`), title screen (`Sprj_Title.mp4`), main menu, character creation, SaveData v1 persistence, and entry into 1st Floor Sickroom / Central Yharnam. Diagnose and fix any runtime or shader issue encountered during live execution.

**Files:**
- Create (outside repo): `/Users/manjarqo/ps4recomp-work/bb_research/probe_run.sh`
- Any runtime/lifter/renderer files requiring targeted fixes discovered from live logs

- [x] **Step 1: Recompile and build Bloodborne (`CUSA03173` v01.09) into `/Users/manjarqo/ps4recomp-work/bb_build`**
  ```bash
  cd "$R" && go build -buildvcs=false -o ps4-recomp ./cmd/ps4-recomp
  "$W/tools/heavy_lock.sh" ./ps4-recomp "$BB/eboot.bin" --app-dir "$BB" -o "$W/bb_build" -c -j 6 > "$W/bb_research/bb_gen.log" 2>&1
  ```
- [x] **Step 2: Run Bloodborne through boot, logos, title menu, character creation, and opening gameplay**
  - Inspect logs, screenshots, audio, and SaveData creation.
  - Fix any newly uncovered runtime, lifter, or renderer edge cases with unit/host tests (including `.ctors`/`nounwind` function discovery, `SceSaveDataMount` v1 80-byte layout, native ARM64 `setjmp`/`longjmp`, `shim_sceImeDialogInit` guest pointer translation, dynamic font texture digest, `VGT_SHADER_STAGES_EN` bitfield decoding, `DrawIndirectRecord` non-indexed `startVertex`, `ExecuteCopyShaderHLE`, multi-slice cubemap `ColorTarget` & `MipChainFor`, and `ShaderTextureType` `case 9: return MTLTextureType2D;`).
- [x] **Step 3: Run the Mandatory TLOU 120s Non-Regression Check (`TAG=bb_tlou_task6`)**

---

## Phase 4: Tessellation (LS/HS/ES) & Geometry Shaders (ES/GS) Pipeline Support

### Task 7: Tessellation & Geometry Shader Pipeline in `gcn_msl.cpp` and `ps4_gnm_draw.mm`

**Context:**
Bloodborne uses hardware Tessellation (`LS → HS → ES → VS`) and Geometry Shaders (`ES → GS → Copy VS`) for specific boss/environment meshes and effects. In `3rdparty/gcn-recompiler`, the GCN frontend and SPIR-V backend already emit `TessellationControl`, `TessellationEval`, and `Geometry` shaders as compute-compatible shaders reading/writing storage buffers (`lds_buffer`, `offchip_ring`, `tess_factors`, `gs_ring`). We need to wire:
1. `gcn_msl.cpp`: SPIRV-Cross execution model selection (`spv::ExecutionModelTessellationControl`, `spv::ExecutionModelTessellationEvaluation`, `spv::ExecutionModelGeometry`, or `spv::ExecutionModelGLCompute`) and buffer binding assignments matching `ps4_gnm_draw.mm`.
2. `ps4_gnm_draw.mm`: When `VGT_STAGES` enables Tessellation or Geometry stages, dispatch the compute-emulated `LS+HS` + `ES` (or `ES+GS`) kernels into persistent ring buffers before encoding the downstream vertex + fragment draw call (adapted from `Wooloomooloo2/bloodborne_mac_port/gpu/shadps4/video_core/renderer_metal/mtl_tessellation.mm` and `mtl_geometry.mm`).

**Files:**
- Modify: `3rdparty/gcn-recompiler/src/gcn_msl.cpp`
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm`
- Create/Modify: host test in `tests/host/`

- [x] **Step 1: Write a host test in `tests/host/` verifying LS/HS/ES and ES/GS compilation to MSL and compute+draw dispatch orchestration**
- [x] **Step 2: Implement the Tessellation and Geometry Shader MSL compilation and Metal compute+draw orchestration**
- [x] **Step 3: Verify host tests, Bloodborne rendering in Hunter's Dream / Central Yharnam, and TLOU 120s non-regression (`TAG=bb_tlou_task7`)**

---

## Phase 5: `PS4Native` Launcher Integration (`compat.json`), Soak & Final Verification

### Task 8: Register `CUSA03173` in `pkg/compat/compat.json` & Final Acceptance Verification

**Context:**
Register Bloodborne (`CUSA03173`, versions `01.00` and `01.09`) in `pkg/compat/compat.json` so `PS4Native` recognizes and launches the game out of the box, update `pkg/compat/compat_test.go`, run a stability soak and clean exit test on Bloodborne, and run the final TLOU 120s non-regression check.

**Files:**
- Modify: `pkg/compat/compat.json`
- Modify: `pkg/compat/compat_test.go`

- [x] **Step 1: Add `CUSA03173` (`Bloodborne™: Game of the Year Edition`, versions `01.00` and `01.09`, status `"playable"`) to `pkg/compat/compat.json` and update `pkg/compat/compat_test.go`**
- [x] **Step 2: Run full Go test suite and host test suite**
  ```bash
  cd "$R" && go vet ./... && test -z "$(gofmt -l cmd pkg)" && go test ./...
  cd "$R" && "$W/tools/heavy_lock.sh" bash tests/host/run_host_tests.sh
  ```
- [x] **Step 3: Verify Bloodborne stability, FPS (30+ fps at 1080p), save/load, and clean exit (`Cmd+Q` and window close)**
- [x] **Step 4: Run Final Mandatory TLOU (`CUSA00557`) 120s Non-Regression Check (`TAG=bb_tlou_final_gate`)**
