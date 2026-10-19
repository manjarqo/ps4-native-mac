# Migration to the upstream ARM64 assembly backend: design

Date: 2026-10-19. Project: PS4Recomp. Reference game: The Last of Us Remastered (CUSA00557), M1 Pro, 16 GB.

This is sub-project 1 of the Uncharted 4 effort:
1. This spec: move our work onto the upstream ARM64 assembly backend, with TLOU as the regression game.
2. Uncharted 4 (CUSA04529) bring-up to gameplay. Own spec.
3. Uncharted 4 performance and hitches, plus the TLOU artifacts and colours. Own specs.

## Problem

Our `main` (49c0b65) holds the full TLOU work on the C backend: the lifter emits C, and clang compiles it. Upstream `main` (ba6bc6a, 11 commits after our base 63510f6) replaced that backend.
- The lifter now translates AMD64 straight into ARM64 assembly (`pkg/lifter/arm64_lifter*.go`). The emitter writes `.s` chunks (`pkg/emitter/asm_emitter.go`). `c_emitter.go` and the C lifter files are gone.
- About 10 runtime files changed:
  - `core/recomp_context.h`, `core/recomp_runtime.{c,h}`: guest entry via `recomp_enter_guest`, PT_TLS layout;
  - `kernel/sync/ps4_sync.c` (+644);
  - `kernel/threading/ps4_threading.{c,h}`;
  - `libkernel/ps4_kernel_sys.{c,h}`, `libkernel/ps4_sysmodule.{c,h}`;
  - `libSceGnmDriver/ps4_gnmdriver.{c,h}`;
  - `libSceVideoOut/ps4_videoout.c`;
  - `elfloader/{loader,modules}.go`, `emitter/shims.go`, `cli/cli.go`.

A plain merge conflicts in 15 files. The owner chose to move to the upstream backend before starting Uncharted 4 (approach A: merge, take the upstream lifter and emitter, keep our runtime).

### What the new backend does differently (facts that drive this design)

- **Pinned guest registers.**
  - x86 GPRs live in ARM64 registers for the whole time guest code runs: RAX..RDI → x19–x25, R8–R15 → x8–x15, RSP → x26, FS base → x27, memory base → x28.
  - XMM registers map to vector registers.
  - `recomp_dispatch` enters guest code through `recomp_enter_guest(ctx, fn)`.
  - Guest state is therefore in `GuestContext` only at shim boundaries. Any runtime code that reads or switches guest state elsewhere must be checked:
    - our coroutine fibers (`ps4_fiber.c`);
    - exception unwinding (`recomp_unwind_to`);
    - `setjmp`/`longjmp` shims;
    - the crash handler;
    - the stall profiler, which walks the host x29 frame chain.
- **No x86 memory-ordering model.** `pkg/lifter` on upstream contains no `ldar`/`stlr`/`ldapr`. Plain guest loads and stores are plain ARM64 accesses. LOCK-prefixed operations use `ldaxr`/`stlxr` loops.
  - On our C backend, acquire/release for non-stack accesses (x86 TSO on arm64) removed lost wake-ups in Naughty Dog's job system. Uncharted 4 uses the same engine.
- **x87 80-bit.** There is no `m80`/long-double handling to be found. Our C backend has `fpu_core.go`: m80 load/store, fstp/fist, compares.
- **Our other lifter and disassembler fixes:**
  - shift flags;
  - overlapping `rep movs`;
  - operand-before-rsp for `call/push [rsp+X]`, `push rsp`, `pop rsp`;
  - jump-table bounds (`disasm/jumptable.go`);
  - SELF segments without data (`elfloader/self.go`).

  Each must be checked on the new lifter. Several may already be correct there.

## Goal and acceptance criteria

TLOU built with the assembly backend is at least as good as the current C build (`tlou_build/ps4_app_ff` = 49c0b65):
- Boots through the menus and the intro to gameplay. Loads the owner's save copy (spore corridor) and the chapter 1 courtyard.
- No `FATAL`, crash or hang in two walking benchmarks per route, plus a 30-minute soak run.
- Average FPS in the usual A/B (courtyard, Sarah's house) is no lower than the C build beyond noise (±3 fps). CP and encoder ms are reported too.
- Walking benchmark: frames over 100 ms are no more frequent than on the C build. The noise rules of the earlier work apply.
- Screenshots at the same frames are identical within noise.
- Exit through the close button and Cmd+Q: no crash report, 3/3 each.
- Host tests pass (`tests/host/run_host_tests.sh`), and so do the lifter's unit tests (`go test ./pkg/...`).
- Build time is reported, not a criterion.

Out of scope:
- keeping the C backend as an option;
- Uncharted 4;
- new performance work, except where the memory-ordering fix costs speed (see component 3).

## Components

### 1. Merge (branch `asm-migration`, from `main`)
- Merge `origin/main`. Resolution rules:
  - `pkg/lifter`, `pkg/emitter/asm_emitter.go`: take upstream.
  - Our C-only files (`c_emitter.go`, `locked.go`, `fpu_core.go`, `memory.go` …) are removed from the build. Their logic is the reference for component 3.
  - `emitter/shims.go`, `elfloader`, `disasm`, `cli`: combine. Keep our shim list, loader fixes and build features (ObjC++ runtime files, gcn-recompiler link, host-test layout) and upstream's `.s` rule and `RECOMP_ARM64_ASM`.
  - Runtime files changed on both sides: keep both behaviours. Where they implement the same thing twice (sync, threading), keep ours unless upstream's is required by the asm entry path. Record each choice in the merge commit message.
- Output goes to a separate build directory, `~/ps4recomp-work/tlou_build_asm`, so `tlou_build` and the owner's `eboot.app` stay untouched until the final install.

### 2. Guest-state boundary audit and fixes (runtime)
For each place that touches guest register state outside a shim call, determine what the asm backend guarantees: which registers are spilled into `GuestContext` on shim entry, and which are reloaded on return. Then fix the runtime side:
- **Fibers** (`libSceFiber/ps4_fiber.c`, coroutine mode and `PS4_FIBER_THREADS=1`): a fiber switch from a shim must save and restore the pinned registers through the context the asm entry uses.
- **Unwinding** (`recomp_unwind_to`), and the `setjmp`/`longjmp`/`sigsetjmp` shims.
- **Thread start** (`recomp_host_thread_runner`, `recomp_enter_guest`) and guest TLS, including upstream's new PT_TLS fields versus our TLS handling.
- **Crash handler and stall profiler.** Check whether the emitted code keeps a valid x29 frame chain. If not, the profiler falls back to PC-only samples, and the report says so.

Each fix gets a host or game-level test that fails without it.

### 3. Lifter correctness on the new backend
A test-first pass over our known lifter defects, using `pkg/lifter/arm64_lifter_test.go` style tests (assembly snippets executed on the host):
- **Memory ordering.** Emit acquire loads (`ldapr`/`ldar`) and release stores (`stlr`) for guest memory accesses that are not RSP- or RBP-relative. This is the rule our C backend used. Decide `ldapr` (LRCPC, available on M1) versus `ldar` by measurement.
  - Switch: `PS4_RECOMP_TSO=0` at build time (a `ps4-recomp` flag), not runtime, since it changes the emitted code.
  - Measure the cost with the FPS A/B. If it costs more than 3 fps, try narrowing it (for example only 4- and 8-byte accesses, as the job system's flags are) before accepting.
- **LOCK RMW and `xchg mem,reg`:** confirm atomicity and full-barrier semantics. LOCK ops on x86 are full fences, so `ldaxr`/`stlxr` alone is not enough: a `dmb ish` or `casal`/`ldaddal` forms are needed.
- **x87 80-bit:** port `fpu_core.go` behaviour: m80 ↔ double conversion, fstp/fist, compares and FPU tag/stack.
- **The other fixes:**
  - shift flags (CF/OF, mask, count 0);
  - overlapping `rep movs`;
  - `call/push [rsp+X]`, `push rsp`, `pop rsp`;
  - jump tables (our `disasm/jumptable.go` merged with upstream's `disasm` change).
- Each item: a failing test first, then the fix in the assembly lifter. An item that already passes gets the test only.
- `cmd/lifter-difftest` (ours, built for the C backend): port it to run lifted assembly, if that is cheaper than writing the same cases by hand. Otherwise retire it.

### 4. Build and tooling
- `ps4-recomp` on TLOU produces `tlou_build_asm` with `.s` chunks plus our runtime (C, ObjC, ObjC++). `ninja` builds it. `ps4_app` runs.
- Tools (`run_perf.sh`, `walk_bench.sh`, `exit_test.sh`, `mutex_perf/run_one.sh`) take the build directory from `BUILD_DIR`, defaulting to `tlou_build`. No other changes.

### 5. Verification on TLOU
- **Bring-up loop:** build, run 120 s headless, fix the first failure, repeat. Every failure gets a ledger line: symptom, cause, fix.
- **Final checks**, the acceptance criteria above:
  - walking benchmark, 2 runs × 2 routes;
  - FPS A/B against `ps4_app_ff`, 2 rounds × 2 scenes;
  - screenshot comparison at the same frames;
  - exit tests;
  - 30-minute soak;
  - host tests and `go test`.
- **Install:** `tlou_build_asm/ps4_app` goes into `tlou_build/eboot.app`, but only when every criterion holds. Use the atomic install procedure; `ps4_app_ff` is kept for rollback.

## Order of work
1. Merge (component 1). Make the build compile.
2. Lifter tests for the known defects (component 3), with the fixes the tests prove necessary. Memory ordering comes first.
3. Bring-up of TLOU on the asm build (component 5 loop), with boundary fixes (component 2) as they appear or as the audit finds them.
4. Final verification, install, `all-fixes.patch`, `progress.md`.

## Risks
- **The upstream asm lifter may have defects that TLOU exercises and their test titles do not.** Mitigation: the bring-up loop and the stall and crash diagnostics we already have.
- **Memory-ordering barriers may cost noticeable speed on the hot guest code.** Mitigation: measure, then narrow the rule, keeping correctness first.
- **Our fiber coroutines depend on the C backend's call structure.** If they cannot be made correct on pinned registers in reasonable time, fall back to `PS4_FIBER_THREADS=1`, which is correct but slower. Record that as a ruling with its cost.

## Verification rules
These carry over from the earlier work:
- automated runs use copies of saves in their own data directories, never the owner's live saves;
- installs are atomic;
- perf runs alternate builds and log the load;
- every new feature has an off switch where it changes behaviour.
