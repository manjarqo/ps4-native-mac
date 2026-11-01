# Bloodborne: Game of the Year Edition (CUSA03173 v01.09) bring-up — design

> 0.5.0 publication scope: this is the development design/plan, not independent proof that every acceptance criterion passed. See README, CHANGELOG and docs/performance-0.5.0.json for audited measurement scope. The local Bloodborne 60 FPS modification is not distributed; unsafe compute-clear substitution was removed, write/upgrade ordering corrected, and STD remains unsupported. No new controlled gameplay benchmark of those final safety changes is claimed.

Date: 2026-10-31. Branch `bloodborne-bringup` from `main` `28c6679` (`v0.4.3`, `/Users/manjarqo/ps4recomp-work/publication-20261031`).
The Last of Us Remastered (`CUSA00557`) plays on this codebase at ~90–99 fps (Metal 3). Uncharted 4 (`CUSA00917`) and inFAMOUS Second Son (`CUSA00004`) reach gameplay. This spec brings Bloodborne: Game of the Year Edition (`CUSA03173` v01.09) to the TLOU bar using our native AOT x86-64 → ARM64 recompiler and HLE runtime, adapting all applicable GPL-2.0 findings from `Wooloomooloo2/bloodborne_mac_port` (`mac-v0.5.12`) to our architecture while guaranteeing zero regression on The Last of Us Remastered (`CUSA00557`).

## Goal

Offline single-player Bloodborne (`CUSA03173` v01.09 `eboot.bin`) is playable on Apple Silicon Mac to the TLOU bar:

- boots cleanly through splash logos (`FDPrs_Sprj_Logo.mp4`) and reaches the title screen (`Sprj_Title.mp4`) and main menu;
- character creation renders and functions properly;
- a new game runs through the opening cutscene, 1st Floor Sickroom, Hunter's Dream, and Central Yharnam combat;
- MP4 movies (`libSceAvPlayer`), background music, 7.1-downmixed speech (center channel), and SFX are audible;
- saves (`libSceSaveData` v1 API + SaveDataMemory) are written and load back across restarts;
- 30+ fps at 1920x1080 in base mode (`PS4_PRO=0`) on Metal 3;
- the image has no obvious visual artefacts (no Cainhurst NaN/Inf red flashes, no missing geometry/terrain from tessellation or geometry shaders, no vertex explosion);
- a 30-minute soak in Central Yharnam has `fatal 0` and no hang;
- quitting via window close and `Cmd+Q` works cleanly;
- **The Last of Us Remastered (`CUSA00557`) non-regression**: every single change introduced for Bloodborne is verified against the host test suite and the 120-second TLOU courtyard route (`tools/metal4_route.sh`) with `fatal 0`, `gpu_err 0`, `watchdog 0`, and FPS within noise of baseline.

Out of scope: online PSN multiplayer/chalice dungeons (`libSceNp*` stays offline with real signed-out console behaviour), PlayStation Camera / Move / 3D display accessories.

## Starting point

Evidence from reconnaissance of `/Users/manjarqo/Library/Application Support/PS4Native/games/CUSA03173/content` and comparison against `/Users/manjarqo/ps4recomp-work/bloodborne_mac_port` (`mac-v0.5.12`):

- **Binary & Companion Modules (`CUSA03173` v01.09)**:
  - `eboot.bin`: 93.8 MB decrypted ELF (`code_size = 56,574,108` bytes, `7,671,032` instructions, `167,838` discovered functions).
  - `sce_module/` contains 7 PRXs: `libc.prx` and `libSceFios2.prx` (`206` exports imported by `eboot.bin`) plus 5 PlayStation Camera / AR / 3D middleware PRXs (`libSceFace.prx`, `libSceHand.prx`, `libSceHeadTracker.prx`, `libSceS3DConversion.prx`, `libSceSmart.prx`) that export **zero** symbols imported by `eboot.bin` and are not listed in `ReferencedModuleNames(eboot)`.
- **ARM64 Lifter Coverage (`pkg/lifter/`)**:
  - `ps4-recomp analyze` initially reported `98.89%` (`108` missing opcodes across `85,381` instructions) because `pkg/lifter/opcodes.go` (`IsOpcodeSupported`) was out of sync with `pkg/lifter/arm64_lifter.go`.
  - **104 of those 108 opcodes (`85,328` instructions) are already implemented in `pkg/lifter/arm64_lifter.go`** (`VPSHUFD`, `VDPPS`, `VMOVHLPS`, `VANDNPS`, `VMOVLHPS`, `BEXTR`, `RDTSC`, `VPADDD`, `VPCMPEQD`, `VRCPPS`, `VXORPD`, `VPADDQ`, `VPALIGNR`, `VPEXTRD`, `VEXTRACTPS`, `VPSHUFB`, `VPEXTRQ`, `VPTEST`, `VPMAXSD`, `VPSRLQ`, `VPSLLDQ`, `VPMINSD`, `VADDPD`, `VPCMPGTD`, `ANDN`, `VUNPCKHPD`, `VCMPSS`, `VUNPCKLPD`, `VPUNPCKLQDQ`, `VMULPD`, `VSUBPD`, `VPSLLQ`, `VPSUBD`, `VLDDQU`, `VROUNDPS`, `VPEXTRB`, `VSHUFPD`, `VPUNPCKHQDQ`, `VMOVHPD`, `VPCMPEQQ`, `VMOVLPD`, `VPMOVZXDQ`, `VANDPD`, `VSQRTPS`, `VPMOVZXBD`, `VCMPSD`, `VPADDB`, `VPSUBQ`, `VPHADDD`, `MFENCE`, `VPMULUDQ`, `BLSR`, `VPMINUD`, `VPMOVSXDQ`, `VDIVPD`, `VPEXTRW`, `VPSADBW`, `VORPD`, `BLSI`, `VPMOVSXBD`, `VPMAXUD`, `VMAXSD`, `VMINSD`, `VBLENDVPD`, `VPCMPGTQ`, `VCVTTPD2DQ`, `VPSRLDQ`, `VPCMPEQB`, `VPCMPEQW`, `VPABSD`, `VPINSRQ`, `VPSUBB`, `LOOPNE`, `VPBLENDW`, `VPMOVZXWQ`, `CLD`, `STC`, `VBLENDPD`, `VPADDUSW`, `VPCMPGTW`, `VPMOVZXBQ`, `VPMOVZXBW`, `VANDNPD`, `VPMAXSW`, `VPMINSW`, `LEAVE`, `VCMPPD`, `VMAXPD`, `VMOVMSKPD`, `VMOVNTDQA`, `CLC`, `CMC`, `ENTER`, `FCMOVB`, `FILD`, `ICEBP`, `LOOP`, `SFENCE`, `VLDMXCSR`, `VMINPD`, `VPMOVSXWQ`, `VSTMXCSR`, `VZEROUPPER`, `XLATB`).
  - Only **4 opcodes in `eboot.bin` (`53` sites out of `7,671,032`)** and **4 opcodes in `libc.prx`/`libSceFios2.prx`** need new lowering in `pkg/lifter/arm64_lifter.go`:
    1. `VMASKMOVDQU` (`48` sites in `eboot.bin` + `11` in `libc.prx`) — masked byte store from `XMM` to `[rdi]`.
    2. `RDTSCP` (`1` site in `eboot.bin`) — same as `RDTSC` + `RCX = 0`.
    3. `ADCX` (`8` sites in `libSceFios2.prx`) — unsigned add with carry flag (`CF`).
    4. `VFNMADD213SS`, `VPMULHUW`, `FSTCW` (in `libc.prx`).
- **HLE Imports & Runtime Semantics (`pkg/runtime/`)**:
  - `eboot.bin` has `87` unresolved imports (plus `6` in `libc.prx` / `libSceFios2.prx`):
    - `libSceSaveData` (4): `sceSaveDataMount` (`SceSaveDataMount` v1 layout), `sceSaveDataSetupSaveDataMemory`, `sceSaveDataGetSaveDataMemory`, `sceSaveDataSetSaveDataMemory`.
    - `libSceAvPlayer` (16): full movie playback API (`Init`, `PostInit`, `AddSource`, `StreamCount`, `GetStreamInfo`, `EnableStream`, `Start`, `Stop`, `Close`, `Pause`, `Resume`, `SetLooping`, `IsActive`, `GetVideoDataEx`, `GetAudioData`, `CurrentTime`).
    - `libkernel` & `libScePosix` (9): `sceKernelGetDirectMemoryType`, `scePthreadRwlockTimedrdlock`, `scePthreadRwlockTimedwrlock`, `sleep`, `pthread_attr_setschedparam`, plus `sysctl`, `sceKernelGettimezone`, `__Ux86_64_setcontext`, `sigreturn`.
    - `libSceDiscMap` (2): `sceDiscMapIsRequestOnHDD` and `sceDiscMap_8A828CAEE7EDD5E9`.
    - `libSceRtc` (3): `sceRtcConvertUtcToLocalTime`, `sceRtcConvertLocalTimeToUtc`, `sceRtcFormatRFC2822LocalTime`.
    - `libSceGnmDriver` (4): `sceGnmValidateCommandBuffers`, `sceRazorCaptureCommandBuffersOnlyImmediate`, `sceRazorCaptureCommandBuffersOnlySinceLastFlip`, `sceRazorCaptureImmediate`.
    - `libSceNp*` (50), `libSceNpTrophy` (2), `libScePlayGo` (`scePlayGoGetChunkId`), `libSceSystemService` (`sceSystemServiceLaunchWebBrowser`), `libSceVoice` (`sceVoiceDisconnectIPortFromOPort`).
  - **64-bit Semaphore Wire ABI (`ps4_semaphore.c`)**: Orbis `SceKernelSema` is an 8-byte pointer-sized handle (`int64_t`). `sceKernelCreateSema` must check `pOptParam != NULL` first (`0x80020016`), write a full 64-bit value `*(int64_t *)pSema` so upper 32 bits are not left as stack garbage, validate full 64-bit handles in `Wait`/`Poll`/`Signal`/`Cancel`/`Delete`, and never reuse IDs.
  - **Direct Memory Release Unmap (`ps4_direct_mem.c`)**: `sceKernelReleaseDirectMemory` must also unmap overlapping virtual ranges in `g_vmem_maps[]` (matching `Wooloomooloo2/bloodborne_mac_port`), preventing stale virtual mappings when Bloodborne recycles physical pools.
  - **7.1 Audio Downmix (`ps4_audioout.c`)**: Bloodborne outputs 7.1 surround (`8` channels) with dialogue on Center (`ch[2]`) and effects on Side/Back (`ch[4..7]`). Our current downmix copies only `ch[0]` and `ch[1]`; mixing `0.7071f * FC` and `0.5f * (SL + BL)` / `0.5f * (SR + BR)` restores voice and surround SFX.
- **GPU, Shader Recompiler & Metal Renderer (`libSceGnmDriver`, `3rdparty/gcn-recompiler`)**:
  - **`libSceGnmDriver` HLE fixes**:
    - `sceGnmUnmapComputeQueue` takes 1 argument `(uint32_t vqueue_id)`, not 2.
    - `sceGnmSetLsShader` needs the missing 3-dword `SET_SH_REG(0x14b, ls_regs[3])` packet (`23` dwords total).
    - `sceGnmComputeWaitOnAddress` needs the 14-dword `NOP + WAIT_REG_MEM + NOP` packet (`0x0e` return).
    - `sceGnmSetPsShader(dcb, NULL)` must not set `CB_SHADER_MASK = 0xf`.
    - `PatchFlipRequest` (`0xabcdef10..0xabcdef13`) in `sceGnmPrepareFlip*` and `sceGnmSubmitAndFlipCommandBuffers`: Bloodborne uses `sceGnmPrepareFlipWithEopInterrupt` with a user flip label and polls that GPU label to pace frames. Without `PatchFlipRequest` + atomic release stores on 64-bit GPU labels, the render thread hangs waiting on its flip label.
    - `ps4_gnm_metal.mm` PM4 parser: when `header == 0`, advance `pc += 1`, not `pc += 2`.
  - **Shader Recompiler (`3rdparty/gcn-recompiler`)**:
    - Null descriptor guard (`info.h`): zero-init `T data{};` and return early if `base < 0x10000ULL` in `ReadUdReg` and `ReadTessConstantBuffer` (prevents SIGBUS during Ebrietas / Amygdala boss encounters when unused slots have null pointers).
    - Cainhurst NaN/Inf red-flash fix (`emit_spirv_floating_point.cpp`, `vector_alu.cpp`): Apple GPU fast-math optimizes away `isnan()`/`isinf()` checks and `0.0 * NaN`. Using IEEE-754 integer bit-pattern checks (`0x7f800000u`) in `EmitFPSaturate32`, `ClampInf` (`V_LOG_CLAMP_F32`, `V_RCP_CLAMP_F32`, `V_RSQ_CLAMP_F32`, `V_RSQ_LEGACY_F32`), `V_RCP_LEGACY_F32`, and `LegacyMul` eliminates NaN/Inf bloom corruption.
    - `NoContraction` → `Invariant` (`emit_spirv_floating_point.cpp`, `spirv_emit_context.cpp`, `ps4_gnm_draw.mm`): replacing global `NoContraction` on every FP ALU op with `spv::Decoration::Invariant` on `output_position` + `MTLCompileOptions.preserveInvariance = YES` preserves depth prepass invariance while allowing Apple Silicon FMA hardware fusion (+62% GPU speed in `bloodborne_mac_port`).
  - **Metal Renderer (`ps4_gnm_draw.mm`)**:
    - Attachmentless render pass clamp: when `!any_attachment && !ps_enabled`, clamp `renderPassWidth = 16; renderPassHeight = 16;` instead of `16384x16384` so Apple Silicon's TBDR tiler does not bin 262,144 tiles on vertex-only passes (~6 ms/frame saved).
    - Tessellation (`LS → HS → ES → VS`) and Geometry Shader (`ES → GS → Copy VS`) emulation via Metal compute dispatches feeding the vertex stage (adapted from `bloodborne_mac_port/gpu/shadps4/video_core/renderer_metal/mtl_tessellation.mm` and `mtl_geometry.mm`).

## Mandatory Non-Regression Policy for The Last of Us Remastered (`CUSA00557`)

Every change introduced for Bloodborne must be general, accurate PS4 console behaviour and **must never break or degrade The Last of Us Remastered (`CUSA00557`)**:

1. **No Game-Specific Hacks**: No binary patches or title-ID checks in the lifter, runtime, or renderer.
2. **Automated Verification Gate After Every Task & Phase**:
   - **Go Suite**: `go vet ./... && gofmt -l cmd pkg && go test ./...`
   - **Host C/C++/ObjC++ Suite**: `bash tests/host/run_host_tests.sh` (~75 host tests on Metal 3 and Metal 4 + Python tests).
   - **Live TLOU 120s Route (`tools/metal4_route.sh`)**:
     - Rebuild TLOU into the isolated check directory `/Users/manjarqo/ps4recomp-work/bb_research/tlou_check` (never touching `/Users/manjarqo/ps4recomp-work/tlou_build` or real user saves).
     - Run `tools/metal4_route.sh` for 120 seconds under `tools/heavy_lock.sh`.
     - Verify with `python3 tools/metal4_route_report.py`: **`fatal 0`, `gpu_err 0`, `watchdog 0`, and courtyard steady-state FPS within noise (±3 fps) of baseline**.
   - If any change causes a failure or FPS regression in TLOU, the change is immediately diagnosed and fixed or reverted before proceeding to the next task.

## Architecture & Phase Gates

### Phase 1: Lifter, Companion PRX Filtering, and CPU/HLE Boot
1. **Lifter & Analyzer Sync (`pkg/lifter/`)**:
   - Synchronize `pkg/lifter/opcodes.go` (`IsOpcodeSupported`) with `pkg/lifter/arm64_lifter.go`.
   - Implement `VMASKMOVDQU`, `RDTSCP`, `ADCX`, `VFNMADD213SS`, `VPMULHUW`, and `FSTCW` in `pkg/lifter/arm64_lifter.go` with unit tests in `pkg/lifter/`.
2. **Unreferenced Companion PRX Filtering (`pkg/elfloader/modules.go`)**:
   - Filter `DiscoverCompanionModules` so `sce_module/*.prx` files that are not in `ReferencedModuleNames(eboot)` and export zero symbols imported by `eboot.bin` (or transitive needed modules) are skipped (`libSceFace`, `libSceHand`, `libSceHeadTracker`, `libSceS3DConversion`, `libSceSmart`).
3. **Kernel, Sync, SaveData v1, DiscMap, Rtc, Np & Audio HLE (`pkg/runtime/`)**:
   - Implement `sceKernelGetDirectMemoryType` and virtual unmapping on `sceKernelReleaseDirectMemory`.
   - Upgrade `ps4_semaphore.c` to full 64-bit `SceKernelSema` wire ABI with `pOptParam` validation and monotonic IDs.
   - Implement `scePthreadRwlockTimedrdlock`, `scePthreadRwlockTimedwrlock`, `sleep`, `pthread_attr_setschedparam`, `sysctl`, `sceKernelGettimezone`, `__Ux86_64_setcontext`, `sigreturn`.
   - Implement `libSceDiscMap` (`sceDiscMapIsRequestOnHDD`, `sceDiscMap_8A828CAEE7EDD5E9`).
   - Implement `libSceRtc` local/UTC conversion and RFC2822 formatting.
   - Implement `libSceSaveData` v1 wrappers (`sceSaveDataMount`, `sceSaveDataSetupSaveDataMemory`, `sceSaveDataGetSaveDataMemory`, `sceSaveDataSetSaveDataMemory`).
   - Implement offline console behaviour for the 50 `libSceNp*` symbols, `libSceNpTrophy` (2), `scePlayGoGetChunkId`, `sceSystemServiceLaunchWebBrowser`, and `sceVoiceDisconnectIPortFromOPort`.
   - Upgrade 7.1 → stereo downmix in `ps4_audioout.c` to include Center (`FC`) and Side/Back (`SL/BL`, `SR/BR`) channels.

**Gate 1**:
- `ps4-recomp analyze` on Bloodborne `eboot.bin` reports ~100% supported instructions (`0` missing in `eboot.bin`) and `0` unresolved imports across `eboot.bin`, `libc.prx`, and `libSceFios2.prx`.
- `go test ./...` and `bash tests/host/run_host_tests.sh` pass.
- **TLOU Gate 1**: 120s TLOU route (`tools/metal4_route.sh`) passes with `fatal 0`, `gpu_err 0`, `watchdog 0`, and FPS within noise.

### Phase 2: GNM Packet Builders, Flip Labels, Shader Recompiler Fixes & First Frame / Main Menu
1. **`libSceGnmDriver` HLE & Flip Request Handling (`ps4_gnmdriver.h/.c`, `ps4_gnm_metal.mm`)**:
   - Fix `sceGnmUnmapComputeQueue` (1-arg signature), `sceGnmSetLsShader` (23 dwords), `sceGnmComputeWaitOnAddress` (14 dwords), and `sceGnmSetPsShader(NULL)`.
   - Implement `PatchFlipRequest` (`0xabcdef10..0xabcdef13`) in `sceGnmPrepareFlip*` and `sceGnmSubmitAndFlipCommandBuffers` / `ps4_gnm_metal.mm`, and use `__atomic_store_n(..., __ATOMIC_RELEASE)` on 64-bit GPU labels.
   - Fix `header == 0` step in `ps4_gnm_metal.mm` (`pc += 1`).
   - Add `sceGnmValidateCommandBuffers` and the 3 `sceRazorCapture*` exports.
   - Clamp attachmentless vertex-only render passes in `ps4_gnm_draw.mm` to `16x16`.
2. **Shader Recompiler (`3rdparty/gcn-recompiler`)**:
   - Add null descriptor guards (`base < 0x10000ULL`) and zero-initialization in `ReadUdReg` and `ReadTessConstantBuffer` (`info.h`).
   - Port IEEE-754 bit-pattern NaN/Inf clamping (`EmitFPSaturate32`, `ClampInf`, `V_RCP_LEGACY_F32`, `LegacyMul`) in `emit_spirv_floating_point.cpp` and `vector_alu.cpp`.
   - Replace `NoContraction` on Fragment/Compute/Vertex ALU ops with `spv::Decoration::Invariant` on `output_position` + `preserveInvariance = YES` in `ps4_gnm_draw.mm`, and rebuild `libgcn_recompiler.a`.

**Gate 2**:
- Bloodborne builds cleanly in `/Users/manjarqo/ps4recomp-work/bb_build`, boots without hanging on flip labels, and reaches the title screen and main menu.
- Host tests pass; **TLOU Gate 2** 120s route passes with `fatal 0`, `gpu_err 0`, `watchdog 0`, and FPS within noise (or improved by `Invariant` + attachmentless clamp).

### Phase 3: `libSceAvPlayer` Movies, Audio, SaveData v1, Character Creation & Gameplay
1. **`libSceAvPlayer` Module (`pkg/runtime/modules/libSceAvPlayer/ps4_avplayer.c`)**:
   - Implement all 16 `libSceAvPlayer` symbols using `ps4_vfs` (or `file_replacement` guest callbacks via `recomp_call_guest`), guest allocator callbacks (`memory_replacement` via `recomp_call_guest`), MP4 demuxing, and hardware H.264 decoding (`ps4_h264_vt.c` `VideoToolbox`) into guest NV12 texture buffers (`SceAvPlayerFrameInfoEx`).
   - Ensure `sceAvPlayerStop` and `sceAvPlayerClose` synchronously drain/join any active decode operations before invoking `deallocate_texture`/`deallocate`.
2. **Boot-to-Gameplay Bring-Up Loop**:
   - Run Bloodborne through intro logos (`FDPrs_Sprj_Logo.mp4`), title movie (`Sprj_Title.mp4`), main menu, character creation, opening cutscene, 1st Floor Sickroom, Hunter's Dream, and Central Yharnam.
   - Verify SaveData v1 mount + `SaveDataMemory` persistence across restarts.

**Gate 3**:
- Intro and title movies play smoothly; audio (music, speech, SFX) is audible; character creation works; a new game enters 1st Floor Sickroom and Central Yharnam with working controls and save/load persistence.
- **TLOU Gate 3**: 120s TLOU route passes with `fatal 0`, `gpu_err 0`, `watchdog 0`, and FPS within noise.

### Phase 4: Tessellation (LS/HS/ES), Geometry Shaders (ES/GS) & Visual Fidelity / Performance
1. **Tessellation & Geometry Shader Pipeline (`gcn_msl.cpp`, `ps4_gnm_draw.mm`)**:
   - Wire SPIRV-Cross MSL stage support for `TessellationControl` (`HS`), `TessellationEvaluation` (`ES`), and `Geometry` (`GS`) as compute kernels emitting into intermediate device buffers, followed by vertex + fragment draw calls (`ps4_gnm_draw.mm`).
2. **Visual & Performance Verification**:
   - Verify terrain/props in Central Yharnam / Hunter's Dream, NaN/Inf bloom stability, and 30+ fps at 1920x1080 (`PS4_PRO=0`).

**Gate 4**:
- Reference scenes in Hunter's Dream and Central Yharnam render without missing tessellated/geometry-shader meshes or NaN/Inf flashes at 30+ fps.
- **TLOU Gate 4**: 120s TLOU route passes on both Metal 3 and Metal 4 with `fatal 0`, `gpu_err 0`, `watchdog 0`.

### Phase 5: `PS4Native` Launcher Integration (`compat.json`), 30-Minute Soak & Clean Exit
1. **`pkg/compat/compat.json`**:
   - Add `CUSA03173` (`Bloodborne™: Game of the Year Edition`, versions `01.00` and `01.09`) to `pkg/compat/compat.json` and update `pkg/compat/compat_test.go`.
2. **Stability Soak & Clean Exit**:
   - Run a 30-minute soak in Central Yharnam (`fatal 0`, no hang, stable RSS).
   - Verify 3/3 window close and 3/3 `Cmd+Q` exits.
   - Run final **TLOU Gate 5** 120s route and full test suite.

## Constraints

- English in the repository; Russian in progress reports to the user.
- No fake tests, no stubs returning 0 where console behaviour or error codes are required, no game-specific hacks (`AGENTS.md`).
- Heavy jobs (game builds, game runs, host test suite) serialized via `/Users/manjarqo/ps4recomp-work/tools/heavy_lock.sh`.
- Isolated directories:
  - Bloodborne build: `/Users/manjarqo/ps4recomp-work/bb_build`
  - Bloodborne research & runs: `/Users/manjarqo/ps4recomp-work/bb_research`
  - Isolated TLOU regression check build: `/Users/manjarqo/ps4recomp-work/bb_research/tlou_check`
  - Never touch `/Users/manjarqo/ps4recomp-work/tlou_build` or real user save directories.
- WindowServer RSS watched during every automated game run (abort if RSS grows by >300 MB).

## Acceptance

- Bloodborne (`CUSA03173` v01.09) boots through intro movies, title screen, character creation, 1st Floor Sickroom, Hunter's Dream, and Central Yharnam gameplay, and runs for 30 minutes with `fatal 0` and no hang.
- Intro/title movies (`libSceAvPlayer`) play; 7.1-downmixed speech, music, and SFX are audible.
- Saves write and load back across restarts.
- Average FPS in Central Yharnam is at least 30 at 1920x1080 (`PS4_PRO=0`) on Metal 3.
- No obvious visual artefacts (no red/black NaN bloom flashes, no missing tessellated/GS geometry).
- Exit via close button and `Cmd+Q` works 3/3 each.
- `CUSA03173` is listed in `pkg/compat/compat.json` for `PS4Native`.
- **The Last of Us Remastered (`CUSA00557`) passes its 120s route (`tools/metal4_route.sh`) with `fatal 0`, `gpu_err 0`, `watchdog 0`, and FPS within noise of baseline.**
- `go vet ./...`, `gofmt -l cmd pkg`, `go test ./...`, and `bash tests/host/run_host_tests.sh` all pass.
