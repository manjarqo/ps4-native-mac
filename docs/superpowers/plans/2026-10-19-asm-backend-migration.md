# Migration to the upstream ARM64 assembly backend: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TLOU built with upstream's ARM64 assembly backend works at least as well as our current C-backend build. That build is the base for Uncharted 4.

**Architecture:**
- Merge `origin/main` into branch `asm-migration`, taking upstream's lifter and emitter and keeping our runtime.
- Make the assembly lifter correct for the defects we already fixed on the C backend. Test first: memory ordering, LOCK fences, x87 80-bit, flags, `rep movs`, rsp operands, jump tables.
- Audit every runtime place that touches pinned guest registers outside a shim.
- Bring TLOU up on the new build in a separate build directory.
- Verify against `tlou_build/ps4_app_ff` and install.

**Tech Stack:** Go (lifter, emitter, CLI), ARM64 assembly (`.s` chunks), C/ObjC/ObjC++ runtime, Metal, ninja, clang.

**Spec:** `docs/superpowers/specs/2026-10-19-asm-backend-migration-design.md`

## Global Constraints

- Comments, README and docs in English only. No fake tests, no stubs (AGENTS.md).
- Automated game runs never use the owner's live saves: copies in their own data directories (`PS4RECOMP_DATA_DIR`) only.
- Installs into `tlou_build/eboot.app` only via temp file + `mv` + `codesign`, after `pgrep -fl MacOS/eboot`.
- `~/ps4recomp-work` is an APFS image on the SSD. Check `mount | grep ps4recomp-work` before building or running.
- The asm build lives in `~/ps4recomp-work/tlou_build_asm`. `tlou_build` stays the C build until Task 10.
- Reference binary: `tlou_build/ps4_app_ff` (C backend, commit 49c0b65).
- Perf runs:
  - alternate the builds;
  - log loadavg and extload;
  - discard runs with load > 15 unless the game itself causes it;
  - report ranges.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- Acceptance (spec):
  - fatal 0 in 2 walks per route and a 30-min soak;
  - FPS no lower than the C build beyond ±3;
  - no more frames over 100 ms than the C build;
  - screenshots identical within noise;
  - exit 3/3 + 3/3 with no crash report;
  - host tests and `go test ./pkg/...` pass.

---

### Task 0: Workspace and ledger
- [ ] Create the SDD workspace: `scripts/sdd-workspace` on this plan. Write the ledger and `common.md` (Global Constraints plus the conventions below).
- [ ] Conventions for `common.md`:
  - Go tests: `cd ~/ps4recomp-work/PS4Recomp && go test ./pkg/...`
  - Build the recompiler: `go build -o ps4-recomp ./cmd/ps4-recomp`
  - Generate TLOU: `./ps4-recomp "/Volumes/ssd/The Last of Us Remastered Repack/CUSA00557/eboot.bin" --app-dir "/Volumes/ssd/The Last of Us Remastered Repack/CUSA00557" -o ../tlou_build_asm -c`
  - Rebuild after a runtime-only change: `cd ~/ps4recomp-work/tlou_build_asm && ninja`
  - Host tests: `bash tests/host/run_host_tests.sh`

### Task 1: Merge `origin/main`

**Files:** everything the merge touches. Conflicts are expected in:
- `pkg/cli/cli.go`;
- `pkg/emitter/c_emitter.go` and `pkg/lifter/{alu,fpu,lifter,memory,simd,simd_avx,simd_avx_ext,missing_ops_test,reg_test}.go` (deleted upstream, modified ours);
- `pkg/runtime/core/recomp_runtime.c`;
- `pkg/runtime/kernel/sync/ps4_sync.c`;
- `pkg/runtime/kernel/threading/ps4_threading.h`;
- `pkg/runtime/modules/libSceVideoOut/ps4_videoout.c`.

- [ ] **Step 1:** `git fetch origin && git merge origin/main` on `asm-migration`.
- [ ] **Step 2: Resolve conflicts with these rules.**
  - `pkg/lifter/*`, `pkg/emitter/asm_emitter.go`: take upstream.
  - Our C-backend-only lifter files and `c_emitter.go`: delete them, accepting upstream's deletion. Before deleting, copy our versions to `~/ps4recomp-work/c_backend_reference/` (outside the repo) as the reference for Tasks 3–6. That includes `locked.go`, `fpu_core.go`, `fpu_core_test.go`, `memory.go`, `x86_semantics_test.go` and `ssse3_avx_test.go`.
  - `pkg/emitter/shims.go`, `pkg/elfloader/*`, `pkg/disasm/*`, `pkg/cli/cli.go`: keep both sides.
    - Ours: the shim list, SELF loader fixes, jump tables, and the ninja generation for `.m`/`.mm`/gcn-recompiler.
    - Upstream: the `.s` rule, `RECOMP_ARM64_ASM`, and its loader/module additions.
  - Runtime files: keep both behaviours.
    - Where both implement the same function (sync, threading), keep ours unless upstream's change is required by `recomp_enter_guest`, the pinned-register entry or PT_TLS.
    - Record every such choice in the merge commit message: one line per file.
  - `recomp_context.h`: upstream's PT_TLS fields and the `RECOMP_ARM64_ASM` dispatch path, plus our `MEM_*` macros. The macros stay for the C runtime helpers that use them.
- [ ] **Step 3:** `go build ./... && go test ./pkg/...`. Expected: build OK. Tests that test removed C-backend code are deleted with that code. Everything else passes, or is listed in the report with its failure.
- [ ] **Step 4:** Build the recompiler, then generate and compile TLOU into `../tlou_build_asm` (common.md command). Expected: the `.s` chunks assemble and the runtime compiles; link errors are fixed. Report the build time.
- [ ] **Step 5:** `bash tests/host/run_host_tests.sh` passes. The host tests build runtime files directly, so they must still compile.
- [ ] **Step 6:** Commit the merge (message: the resolution choices).

### Task 2: Tools take a build directory; first run
**Files:** `~/ps4recomp-work/run_perf.sh`, `tools/walk_bench.sh`, `tools/exit_test.sh`, `mutex_perf/run_one.sh` (all outside the repo).
- [ ] **Step 1:** Each script uses `${BUILD_DIR:-$HOME/ps4recomp-work/tlou_build}` wherever it now hard-codes `tlou_build`. `run_perf.sh` already reads `BUILD_DIR`; check the others. `exit_test.sh` copies its binary from and runs it in that directory.
- [ ] **Step 2:** Run `bash tools/test_walk_bench.sh`. It still passes.
- [ ] **Step 3:** First headless run of the asm build: `BUILD_DIR=$HOME/ps4recomp-work/tlou_build_asm` run_perf for 120 s on a copy of `data_ch1`. Record in the ledger:
  - how far it gets (menu, intro, gameplay);
  - the first `FATAL`, crash or hang, with its log tail;
  - the crash report's top frames, if any.

  This is the input for Tasks 7–8. No fix in this task.

### Task 2b: Differential test harness for the assembly lifter (inserted 2026-10-19)

Why: the first asm run of TLOU hangs in early init because of a lifter bug. In `ANDN rdx, rax, [mem]` the src1 value in x16 is overwritten by the address computation. Bugs of this kind, where a scratch register is reused while a memory operand is computed, can only be found reliably by comparing against real x86.

**Files:** new `cmd/lifter-difftest-asm/` (port of `~/ps4recomp-work/c_backend_reference/cmd/lifter-difftest/`): `main.go`, `run.sh`, `harness/{native_main.c, asm_main.c, harness.h, compare.py}`.

- [ ] **Step 1: Port the generator.**
  - Keep the sampling: instruction encodings from the guest image at addresses in a linear disassembly, one representative per (opcode, operand shape, immediate) signature, `-max-per-op`.
  - Keep the native side: raw bytes in x86-64 stubs, run under Rosetta 2, unchanged.
  - New lifted side, which emits an arm64 `.s` per test:
    1. a prologue that saves the host callee-saved registers;
    2. loads the pinned registers from a `GuestContext`-shaped state block (x19–x25, x8–x15, x26 = RSP, x27 = FS, x28 = mem_base = 0, vector registers, and NZCV from the stored flags);
    3. the instruction as lifted by `Arm64Lifter`;
    4. an epilogue that stores the pinned registers, vectors and flags back into the block.
  - Use the same scratch-memory mapping as the C version (fixed address, memory operands redirected).
  - Instructions that call runtime helpers or shims are skipped and listed: that includes calls, jumps, syscalls and x87 if it uses helpers.
- [ ] **Step 2: Compare** GPRs, the low 128 bits of XMM (and YMM if the lifter supports AVX-256), the arithmetic flags (CF, PF, AF, ZF, SF, OF, comparing only flags the instruction defines) and scratch memory. Reuse `compare.py`.
- [ ] **Step 3: Self-test.** The harness must catch a planted bug: temporarily break one lowering, for example swap the operands of one `sub`, and check that it reports a mismatch. Record the result; do not commit the planted bug.
- [ ] **Step 4: Run on both eboots.**
  - TLOU: `guest_image.bin` from `tlou_build_asm`.
  - Uncharted 4: `/Volumes/ssd/Uncharted 4 v1.32 by MorpheusGames/CUSA04529/eboot.bin`, generated with `ps4-recomp` into `~/ps4recomp-work/u4_build_asm`; generation only, no link needed.
  - Produce the linear disassemblies the generator needs.
  - Report the mismatches grouped by opcode, with one example each.
- [ ] **Step 5: Fix every mismatch** in the assembly lifter.
  - Write one Go regression test per bug class in `pkg/lifter/arm64_regress_test.go`, asserting the corrected emitted pattern; each must fail before its fix.
  - Re-run the harness until both eboots show 0 mismatches, or only mismatches in undefined flags.
  - Fix the `ANDN` bug and the suspicious `BLSI` flags found in the first run.
  - Add the AVX ops TLOU uses that are unsupported (VPMULHRSW, VPSIGNW, VLDDQU) with harness coverage.
- [ ] **Step 6:** Commit the harness, then the fixes (one commit per bug class).
- Order: this task runs before Task 3. Tasks 3, 4 and 6 then extend the harness where it applies: Task 3 checks that ordering does not change results; Task 4 adds LOCK ops; Task 6 overlaps the shift and `rep movs` checks.

### Task 3: Memory ordering (x86 TSO) in the assembly lifter
**Files:** `pkg/lifter/arm64_lifter*.go` (the guest memory load/store emission helpers), a new `pkg/lifter/arm64_tso_test.go`, and the `ps4-recomp` flag in `pkg/cli/cli.go`.

**Rule (from our C backend):**
- Guest memory accesses whose address is not RSP- or RBP-relative use acquire loads and release stores.
- RSP/RBP-relative accesses stay plain.
- This covers scalar loads and stores of 1, 2, 4 and 8 bytes, including the memory operand of ALU instructions (`add [rdi], eax` loads with acquire and stores with release).
- Vector and SIMD loads and stores stay plain. x86 TSO technically covers them, but the C backend did not order them and TLOU was correct without it.

- [ ] **Step 1: Write the failing test** `pkg/lifter/arm64_tso_test.go`:

```go
package lifter

import (
	"strings"
	"testing"

	"ps4-recomp/pkg/disasm"

	"golang.org/x/arch/x86/x86asm"
)

func liftOne(t *testing.T, l *Arm64Lifter, code []byte) string {
	t.Helper()
	inst, err := x86asm.Decode(code, 64)
	if err != nil {
		t.Fatalf("decode %x: %v", code, err)
	}
	di := disasm.Instruction{Addr: 0x1000, Inst: inst, Len: inst.Len, Bytes: code}
	out, err := l.LiftInstructionToBuf(di, 0x1000+uint64(inst.Len), nil, nil)
	if err != nil {
		t.Fatalf("lift %x: %v", code, err)
	}
	return strings.Join(out, "\n")
}

func TestTsoOrdering(t *testing.T) {
	cases := []struct {
		name    string
		code    []byte
		want    []string // substrings that must appear
		wantNot []string // substrings that must not appear
	}{
		{"load [rdi] is acquire", []byte{0x8b, 0x07}, []string{"ldapr w19, ["}, nil},                       // mov eax,[rdi]
		{"store [rdi] is release", []byte{0x89, 0x07}, []string{"stlr w19, ["}, nil},                      // mov [rdi],eax
		{"64-bit load [rsi+8] is acquire", []byte{0x48, 0x8b, 0x46, 0x08}, []string{"ldapr x19, ["}, nil}, // mov rax,[rsi+8]
		{"byte store [rdi] is release", []byte{0x88, 0x07}, []string{"stlrb w"}, nil},                     // mov [rdi],al
		{"word load [rdi] is acquire", []byte{0x66, 0x8b, 0x07}, []string{"ldaprh w"}, nil},               // mov ax,[rdi]
		{"rmw add [rdi],eax", []byte{0x01, 0x07}, []string{"ldapr w", "stlr w"}, nil},                     // add [rdi],eax
		{"stack load [rsp+8] stays plain", []byte{0x8b, 0x44, 0x24, 0x08}, nil, []string{"ldapr", "ldar"}}, // mov eax,[rsp+8]
		{"frame store [rbp-4] stays plain", []byte{0x89, 0x45, 0xfc}, nil, []string{"stlr"}},               // mov [rbp-4],eax
		{"movups load stays plain", []byte{0x0f, 0x10, 0x07}, nil, []string{"ldapr", "ldar"}},              // movups xmm0,[rdi]
	}
	l := NewArm64Lifter(map[uint64]bool{0x1000: true})
	for _, c := range cases {
		got := liftOne(t, l, c.code)
		for _, w := range c.want {
			if !strings.Contains(got, w) {
				t.Errorf("%s: want %q in\n%s", c.name, w, got)
			}
		}
		for _, w := range c.wantNot {
			if strings.Contains(got, w) {
				t.Errorf("%s: did not want %q in\n%s", c.name, w, got)
			}
		}
	}
	l.SetTSO(false)
	if got := liftOne(t, l, []byte{0x8b, 0x07}); strings.Contains(got, "ldapr") {
		t.Errorf("TSO off: want plain load, got\n%s", got)
	}
}
```

  If upstream's `disasm.Instruction` fields or the `LiftInstructionToBuf` signature differ, adapt `liftOne` and say so. The cases and expectations stay as written.
- [ ] **Step 2:** Run `go test ./pkg/lifter -run TestTsoOrdering`. Expected: FAIL (no `ldapr`, no `SetTSO`).
- [ ] **Step 3: Implement.**
  - `func (l *Arm64Lifter) SetTSO(on bool)`, default on.
  - In the load and store helpers, when TSO is on and the base is not RSP or RBP:
    - compute the full address into a scratch register: `add x16, x28, <offset reg>`, using the scratch convention the lifter already uses;
    - then emit `ldapr{b,h}` / `ldapr` for loads and `stlr{b,h}` / `stlr` for stores, with base-only addressing (these instructions take no offset);
    - for sign-extending loads, use `ldapr` followed by `sxtb`/`sxth`/`sxtw`.
  - `ps4-recomp` flag `-tso` (default true). `-tso=false` disables it. The flag is passed to the lifter and printed in the build summary.
- [ ] **Step 4:** The tests pass. `go test ./pkg/...` passes. `-mcpu=apple-m1` accepts `ldapr` (LRCPC); if the assembler rejects it, add `+rcpc` to the asm flags.
- [ ] **Step 5:** Regenerate `tlou_build_asm` and check that it still builds. Commit: "Assembly lifter: acquire/release for non-stack guest memory (x86 TSO)".

### Task 4: LOCK RMW and xchg as full barriers
**Files:** the lifter's LOCK/XCHG emission; tests in `pkg/lifter/arm64_tso_test.go`.
- [ ] **Step 1: Failing test.** Add to the test file. For each of the following, the lifted code is atomic and fully fenced:
  - `lock add [rdi],eax` (`f0 01 07`), `lock xadd [rdi],eax` (`f0 0f c1 07`), `lock cmpxchg [rdi],ecx` (`f0 0f b1 0f`), `xchg [rdi],eax` (`87 07`), `lock inc dword [rdi]` (`f0 ff 07`), `lock or [rdi],eax` (`f0 09 07`), `lock bts dword [rdi],eax` (`f0 0f ab 07`);
  - "Atomic and fully fenced" means either an LSE atomic with acquire+release (`ldaddal`, `swpal`, `casal`, `ldsetal`, `ldclral`, `ldeoral`), or an exclusive loop using `ldaxr` and `stlxr` followed by `dmb ish`;
  - the test checks with a regex for either form;
  - `xchg` with a memory operand is implicitly locked on x86.
- [ ] **Step 2:** FAIL wherever it is missing. Implement: prefer the LSE forms (M1 has LSE) and fall back to adding `dmb ish` after the loop. Flags after `lock xadd`/`cmpxchg` keep their current semantics; extend the existing upstream tests if they cover flags.
- [ ] **Step 3:** Tests pass; commit "Assembly lifter: LOCK RMW and xchg are full barriers".

### Task 5: x87 80-bit
**Files:** the lifter's x87 code (`arm64_lifter_fpu.go`), plus runtime helpers if needed. Reference: `~/ps4recomp-work/c_backend_reference/fpu_core.go`, `fpu_core_test.go`, and the `recomp_context.h` x87 helpers on `main`.
- [ ] **Step 1:** List every x87 instruction TLOU's eboot uses: `./ps4-recomp analyze` output or a disassembly count. Mark which ones upstream lifts and whether m80 forms (`fld tbyte`, `fstp tbyte`) are handled.
- [ ] **Step 2: Failing tests** (port the cases from `fpu_core_test.go` that apply):
  - an m80 load of a known pattern (1.0 = `0x3fff 8000000000000000`) gives 1.0 in the x87 stack top;
  - `fstp tbyte` writes the 10-byte encoding of 1.5;
  - `fistp qword` truncates or rounds per the FPU control word;
  - `fcomip` sets ZF/CF correctly.

  Use execution if upstream has an execution harness. Otherwise call runtime helpers (`recomp_x87_ld80`/`st80` or upstream's equivalents) from a C host test in `tests/host/` and assert the emitted code calls them.
- [ ] **Step 3:** Implement m80 via runtime helpers callable from assembly: a shim-like call that spills the registers it needs. Follow upstream's existing helper-call convention.
- [ ] **Step 4:** Tests pass; commit "Assembly lifter: x87 80-bit load/store via helpers".

### Task 6: Remaining lifter and disassembler fixes
**Files:** lifter (shifts, string ops, push/call), `pkg/disasm/jumptable.go`, `pkg/elfloader/self.go`; tests.

For each item: a failing pattern test first (or an existing-test check), then the fix. Already-correct items get the test only, and the report says so.
- [ ] **Shifts:**
  - `shl/shr/sar r32, cl` mask the count with 0x1f (0x3f for 64-bit);
  - a count of 0 leaves flags unchanged;
  - CF = the last bit shifted out;
  - OF for count 1.
- [ ] **`rep movsb/movsd`** with overlapping source and destination copies element by element (forward, DF=0), not with a block copy that changes the semantics of overlapping forward copies.
- [ ] **`call qword [rsp+8]`, `push qword [rsp+8]`, `push rsp`, `pop rsp`:** the operand is read before rsp changes. `push rsp` pushes the old value; `pop rsp` loads the new rsp from the old top.
- [ ] **Jump tables:** our `jumptable.go` bounds (register copies `mov ebx,edx; cmp edx,0xe; ja`, `cmp reg,imm; jbe`, truncation at the first target inside a decoded instruction) survived the merge. The tests from `main` pass.
- [ ] **SELF loader:** segments without file data no longer overwrite PT_LOAD. Our fix survived the merge; a test or an analyze of TLOU proves it (ProcParam readable).
- [ ] Commit each fix separately.

### Task 7: Guest-state boundary audit
**Files:**
- `pkg/runtime/modules/libSceFiber/ps4_fiber.c`;
- `pkg/runtime/core/recomp_runtime.c` (`recomp_unwind_to`, `crash_handler`, setjmp shims);
- `pkg/runtime/kernel/threading/ps4_threading.c` (`recomp_host_thread_runner`, the stall profiler);
- the asm entry (`recomp_enter_guest`) and the emitter's shim call sequence.

- [ ] **Step 1: Document the contract** in a comment at `recomp_enter_guest`:
  - which pinned registers are saved into `GuestContext` on shim entry, and which are reloaded on return;
  - how a shim that switches context (fiber switch, longjmp, unwind) makes the asm code resume with the new context.

  Read the emitter's shim-call sequence for this.
- [ ] **Step 2: Check each site against the contract.** Write a test for each:
  - **Fiber switch** in coroutine mode: switching from fiber A to B inside the `sceFiberSwitch` shim must resume B with B's registers.
    - Test (tests/host or a guest-level test): a TLOU walk with fibers, or a host test calling the runtime's switch with two synthetic contexts and the asm entry stub. Choose the cheaper one that fails if registers are not restored.
  - **`recomp_unwind_to`** and `longjmp`: the target context's registers are what the asm code sees after return.
  - **Thread start:** a new guest thread starts with a fresh context, and with TLS at upstream's PT_TLS layout and our FS-base handling in agreement.
  - **Crash handler and stall profiler:** check whether the emitted functions keep x29 frame records (`stp x29, x30` prologue).
    - If they do, the frame-chain walk works unchanged.
    - If not, the profiler records PC only and prints `(no frame chain)` once. The host test still passes.
- [ ] **Step 3:** Fix what fails. If coroutine fibers cannot be made correct, make `PS4_FIBER_THREADS=1` the default for asm builds and record the ruling with its cost.
- [ ] **Step 4:** Commit per site.

### Task 8: TLOU bring-up loop
- [ ] Loop until TLOU reaches gameplay and walks both routes with fatal 0:
  1. Regenerate or rebuild `tlou_build_asm`.
  2. Run 120 s on a copy of `data_ch1`, then on a copy of the owner's save (`data_user1441`), with `BUILD_DIR`.
  3. On the first failure: find the cause using the crash report, the stall profiler and the `[ps4-...]` logs, then fix it in the lifter or runtime with a test, and commit.

  Each iteration gets one ledger line: `bring-up N: <symptom> — <cause> — <fix commit>`.
- [ ] Stop condition: both routes walk with `tools/walk_bench.sh` (`BUILD_DIR` set) at fatal 0. A run that hits more than 10 iterations without progress on the same symptom escalates (controller ruling).

### Task 9: Cost of memory ordering
- [ ] FPS A/B, `tlou_build_asm` with `-tso` (default) against `-tso=false` (a second build directory `tlou_build_asm_notso`), courtyard and Sarah's house, 2 rounds.
- [ ] If TSO costs more than 3 fps, narrow the rule:
  - only 4- and 8-byte accesses;
  - or exclude constant-address loads from `.rodata`.

  Re-measure. Keep correctness first: the narrowed rule must still pass the TLOU walks.
- [ ] Ruling recorded; commit only if the rule changed.

### Task 10: Final verification and install
- [ ] Walking benchmark, `tlou_build_asm`, 2 runs × 2 routes, compared with `walk_bench/final.txt` (C build).
- [ ] FPS A/B against `ps4_app_ff`, 2 rounds × 2 scenes (`mutex_perf/run_one.sh` pattern, output in `~/ps4recomp-work/asm_ab/`).
- [ ] Screenshot comparison at the same frames (run_perf `EVERY=1500`, same scene, pairwise mean absolute difference).
- [ ] 30-minute soak on the courtyard copy: fatal 0, no hang (stall watchdog).
- [ ] Exit tests 3/3 close + 3/3 terminate (`BUILD_DIR`).
- [ ] Host tests and `go test ./pkg/...`.
- [ ] If every acceptance criterion holds:
  - install `tlou_build_asm/ps4_app` into `tlou_build/eboot.app` atomically;
  - regenerate `all-fixes.patch` (diff against upstream `ba6bc6a` plus untracked files, under bash; update the memory note);
  - append a Russian section to the SSD `progress.md`.

  If a criterion fails, list it with its cause and do not install.
