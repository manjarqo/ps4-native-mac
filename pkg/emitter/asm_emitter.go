package emitter

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"ps4-recomp/pkg/disasm"
	"ps4-recomp/pkg/elfloader"
	"ps4-recomp/pkg/lifter"
)

// AsmEmitter emits Apple Silicon ARM64 assembly (.s) files from disassembled functions.
type AsmEmitter struct {
	elf          *elfloader.LoadedELF
	disasm       *disasm.Disassembler
	lifter       *lifter.Arm64Lifter
	shimMap      map[uint64]string
	AppDir       string
	Modules      []GuestModule
	ChunkSize    int
	Funcs        []disasm.ReachableFunc
	HLE          *HLEReport
	linesBuf     []string
	knownFuncSet map[uint64]bool
}

// NewAsmEmitter creates a new ARM64 assembly emitter.
func NewAsmEmitter(loaded *elfloader.LoadedELF, d *disasm.Disassembler, l *lifter.Arm64Lifter) *AsmEmitter {
	shimMap := make(map[uint64]string)
	bindAddr := func(name string, addr uint64) {
		if name == "" || addr == 0 {
			return
		}
		if shim, ok := LookupShim(name); ok {
			shimMap[addr] = shim
		}
	}
	for _, rel := range loaded.Relocations {
		if rel.Type == elfloader.R_X86_64_JUMP_SLOT && rel.Offset+8 <= uint64(len(loaded.MemoryImage)) {
			if rel.SymName != "" {
				if shim, ok := LookupShim(rel.SymName); ok {
					if rel.PltAddr != 0 {
						shimMap[rel.PltAddr] = shim
					}
					shimMap[rel.Offset] = shim
					binary.LittleEndian.PutUint64(loaded.MemoryImage[rel.Offset:rel.Offset+8], rel.Offset)
					continue
				}
			}
			continue
		}
		if rel.SymName == "" {
			continue
		}
		shim, ok := LookupShim(rel.SymName)
		if !ok {
			continue
		}
		if rel.PltAddr != 0 {
			shimMap[rel.PltAddr] = shim
		}
		shimMap[rel.Offset] = shim
	}
	for _, sym := range loaded.Symbols {
		bindAddr(sym.Name, sym.Address)
	}
	for _, sym := range loaded.DynSymbols {
		bindAddr(sym.Name, sym.Address)
	}

	return &AsmEmitter{
		elf:     loaded,
		disasm:  d,
		lifter:  l,
		shimMap: shimMap,
	}
}

// ResolveEntryAddress dynamically resolves the primary guest entry point.
func (e *AsmEmitter) ResolveEntryAddress() (uint64, string, error) {
	if e.elf.EntryPoint != 0 {
		return e.elf.EntryPoint, "_start", nil
	}
	if mainSym, ok := e.elf.SymbolByName["main"]; ok && mainSym.Address != 0 {
		return mainSym.Address, "main", nil
	}
	return 0, "", fmt.Errorf("ELF has no entry point and no main symbol")
}

// EmitAll generates all .s assembly files and runtime C files in outDir.
func (e *AsmEmitter) EmitAll(outDir string) ([]string, error) {
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return nil, err
	}

	var buildFiles []string

	mainPath := filepath.Join(outDir, "main.c")
	if err := e.EmitMainRunner(mainPath); err != nil {
		return nil, fmt.Errorf("failed to emit main.c: %w", err)
	}
	buildFiles = append(buildFiles, mainPath)

	binPath := filepath.Join(outDir, "guest_image.bin")
	if err := e.EmitGuestImage(binPath); err != nil {
		return nil, fmt.Errorf("failed to emit guest_image.bin: %w", err)
	}

	trampPath := filepath.Join(outDir, "trampoline_arm64.s")
	if err := e.EmitTrampoline(trampPath); err != nil {
		return nil, fmt.Errorf("failed to emit trampoline_arm64.s: %w", err)
	}
	buildFiles = append(buildFiles, trampPath)

	codeFiles, err := e.EmitChunkedAsm(outDir, 15000)
	if err != nil {
		return nil, fmt.Errorf("failed to emit chunked assembly: %w", err)
	}
	buildFiles = append(buildFiles, codeFiles...)

	modPath := filepath.Join(outDir, "guest_modules.c")
	if err := e.EmitGuestModules(modPath); err != nil {
		return nil, fmt.Errorf("failed to emit guest_modules.c: %w", err)
	}
	buildFiles = append(buildFiles, modPath)
	synthPath := strings.TrimSuffix(modPath, ".c") + "_synth.s"
	if _, err := os.Stat(synthPath); err == nil {
		buildFiles = append(buildFiles, synthPath)
	}

	return buildFiles, nil
}

// EmitGuestImage writes the raw loaded guest memory image.
func (e *AsmEmitter) EmitGuestImage(path string) error {
	return writeFileIfChanged(path, e.elf.MemoryImage)
}

func (e *AsmEmitter) functionAddrs() []uint64 {
	if len(e.Funcs) > 0 {
		addrs := make([]uint64, len(e.Funcs))
		for i, f := range e.Funcs {
			addrs[i] = f.Addr
		}
		return addrs
	}
	if e.disasm == nil {
		return nil
	}
	addrs := make([]uint64, 0, len(e.disasm.Functions))
	for addr := range e.disasm.Functions {
		addrs = append(addrs, addr)
	}
	slices.Sort(addrs)
	return addrs
}

func (e *AsmEmitter) instCountByAddr() map[uint64]int {
	if len(e.Funcs) > 0 {
		m := make(map[uint64]int, len(e.Funcs))
		for _, f := range e.Funcs {
			m[f.Addr] = f.Insts
		}
		return m
	}
	if e.disasm == nil {
		return nil
	}
	m := make(map[uint64]int, len(e.disasm.Functions))
	for addr, fn := range e.disasm.Functions {
		count := 0
		if fn != nil {
			for _, b := range fn.Blocks {
				count += len(b.Insts)
			}
		}
		m[addr] = count
	}
	return m
}

func (e *AsmEmitter) loadFunction(addr uint64) (*disasm.Function, error) {
	if e.disasm.Functions != nil {
		if fn := e.disasm.Functions[addr]; fn != nil {
			return fn, nil
		}
	}
	fn, _, err := e.disasm.DisasmFunction(addr)
	return fn, err
}

// EmitChunkedAsm partitions recompiled functions across .s assembly files.
func (e *AsmEmitter) EmitChunkedAsm(outDir string, targetBudget int) ([]string, error) {
	fnAddrs := e.functionAddrs()

	if targetBudget <= 0 {
		targetBudget = 15000
	}
	maxFuncsPerChunk := e.ChunkSize
	if maxFuncsPerChunk <= 0 {
		maxFuncsPerChunk = 250
	}

	var chunks [][]uint64
	var currentChunk []uint64
	currentInsts := 0

	insts := e.instCountByAddr()
	for _, addr := range fnAddrs {
		nInsts := insts[addr]
		if len(currentChunk) > 0 && (currentInsts+nInsts > targetBudget || len(currentChunk) >= maxFuncsPerChunk) {
			chunks = append(chunks, currentChunk)
			currentChunk = nil
			currentInsts = 0
		}
		currentChunk = append(currentChunk, addr)
		currentInsts += nInsts
	}
	if len(currentChunk) > 0 {
		chunks = append(chunks, currentChunk)
	}
	if len(chunks) == 0 {
		chunks = append(chunks, []uint64{})
	}

	var generatedFiles []string

	for chunkIdx, chunkAddrs := range chunks {
		chunkFileName := fmt.Sprintf("code_%03d.s", chunkIdx)
		chunkPath := filepath.Join(outDir, chunkFileName)
		regPath := filepath.Join(outDir, fmt.Sprintf("code_%03d_reg.c", chunkIdx))
		if err := e.emitSingleAsmChunk(chunkPath, chunkIdx, chunkAddrs); err != nil {
			return nil, fmt.Errorf("failed to emit %s: %w", chunkFileName, err)
		}
		generatedFiles = append(generatedFiles, chunkPath, regPath)
	}

	dispatchPath := filepath.Join(outDir, "dispatch.c")
	if err := e.EmitDispatch(dispatchPath, len(chunks)); err != nil {
		return nil, fmt.Errorf("failed to emit dispatch.c: %w", err)
	}
	generatedFiles = append(generatedFiles, dispatchPath)

	return generatedFiles, nil
}

func (e *AsmEmitter) emitSingleAsmChunk(path string, chunkIdx int, chunkAddrs []uint64) error {
	var buf bytes.Buffer
	w := bufio.NewWriter(&buf)

	if _, err := fmt.Fprintf(w, "// Chunk %d (%d functions)\n.text\n.p2align 2\n\n", chunkIdx, len(chunkAddrs)); err != nil {
		return err
	}

	for _, addr := range chunkAddrs {
		if shim, isShimmed := e.shimMap[addr]; isShimmed {
			// Forward directly to host shim via bridge
			fmt.Fprintf(w, ".globl _fn_0x%x\n_fn_0x%x:\n", addr, addr)
			fmt.Fprintf(w, "    adrp x0, _%s@PAGE\n", shim)
			fmt.Fprintf(w, "    add  x0, x0, _%s@PAGEOFF\n", shim)
			fmt.Fprintf(w, "    b    _recomp_call_shim\n\n")
			continue
		}

		fn, err := e.loadFunction(addr)
		if err != nil {
			return fmt.Errorf("0x%x: %w", addr, err)
		}
		if fn == nil {
			continue
		}

		fmt.Fprintf(w, ".globl _fn_0x%x\n_fn_0x%x:\n", addr, addr)
		fmt.Fprintf(w, "    str x30, [sp, #-16]!\n")

		for _, blockAddr := range fn.BlockOrder {
			block := fn.Blocks[blockAddr]
			if block == nil {
				continue
			}

			fmt.Fprintf(w, "\nL_fn_0x%x_loc_0x%x:\n", addr, blockAddr)
			e.lifter.ResetFlags()

			for _, inst := range block.Insts {
				nextPC := inst.Address + uint64(inst.Inst.Len)
				lines, err := e.lifter.LiftInstructionToBuf(inst, nextPC, fn, e.linesBuf[:0])
				if err != nil {
					fmt.Fprintf(w, "    // 0x%x: %s [UNSUPPORTED: %v]\n    brk #0\n", inst.Address, inst.Inst.String(), err)
				} else {
					e.linesBuf = lines
					for _, line := range lines {
						w.WriteString(line)
						w.WriteByte('\n')
					}
				}
			}
		}
		w.WriteString("    ldr x30, [sp], #16\n    ret\n\n")
	}

	// Chunk registration function in C (for dispatch table)
	regFileName := strings.TrimSuffix(path, ".s") + "_reg.c"
	if err := e.emitChunkRegistration(regFileName, chunkIdx, chunkAddrs); err != nil {
		return err
	}

	if err := w.Flush(); err != nil {
		return err
	}
	return writeFileIfChanged(path, buf.Bytes())
}

func (e *AsmEmitter) emitChunkRegistration(path string, chunkIdx int, chunkAddrs []uint64) error {
	var buf bytes.Buffer
	w := bufio.NewWriter(&buf)

	fmt.Fprintf(w, "#include \"recomp_runtime.h\"\n\n")

	for _, addr := range chunkAddrs {
		fmt.Fprintf(w, "extern void fn_0x%x(GuestContext *ctx);\n", addr)
	}

	fmt.Fprintf(w, "\nvoid recomp_init_dispatch_chunk_%d(void) {\n", chunkIdx)
	for _, addr := range chunkAddrs {
		fmt.Fprintf(w, "    recomp_register_fn(0x%xULL, fn_0x%x);\n", addr, addr)
	}
	fmt.Fprintf(w, "}\n")

	if err := w.Flush(); err != nil {
		return err
	}
	return writeFileIfChanged(path, buf.Bytes())
}

// EmitTrampoline generates the ARM64 assembly bridge between host C and guest assembly.
func (e *AsmEmitter) EmitTrampoline(path string) error {
	content := `// ARM64 Assembly Bridge between host C runtime and guest assembly
.text
.p2align 2

// Global pointer to active GuestContext
// void recomp_enter_guest(GuestContext *ctx, uint64_t target_fn)
// x0 = ctx, x1 = target_fn
.globl _recomp_enter_guest
_recomp_enter_guest:
    // 1. Save host callee-saved registers, frame pointer, and ctx on host stack
    stp x29, x30, [sp, #-112]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    str x0,       [sp, #96]

    // 2. Load guest registers from GuestContext (x0)
    ldr x19, [x0, #0x0]   // rax
    ldr x21, [x0, #0x8]   // rcx
    ldr x22, [x0, #0x10]  // rdx
    ldr x20, [x0, #0x18]  // rbx
    ldr x26, [x0, #0x20]  // rsp
    ldr x25, [x0, #0x28]  // rbp
    ldr x23, [x0, #0x30]  // rsi
    ldr x24, [x0, #0x38]  // rdi
    ldr x8,  [x0, #0x40]  // r8
    ldr x9,  [x0, #0x48]  // r9
    ldr x10, [x0, #0x50]  // r10
    ldr x11, [x0, #0x58]  // r11
    ldr x12, [x0, #0x60]  // r12
    ldr x13, [x0, #0x68]  // r13
    ldr x14, [x0, #0x70]  // r14
    ldr x15, [x0, #0x78]  // r15
    ldr x27, [x0, #0x88]  // fs_base
    ldr x28, [x0, #0x330] // mem_base (offset 816 in GuestContext)

    // 3. Jump to target guest function (x1)
    blr x1

    // 4. On return: save guest registers back to GuestContext (from thread host stack)
    ldr  x0, [sp, #96]
    str x19, [x0, #0x0]   // rax
    str x21, [x0, #0x8]   // rcx
    str x22, [x0, #0x10]  // rdx
    str x20, [x0, #0x18]  // rbx
    str x26, [x0, #0x20]  // rsp
    str x25, [x0, #0x28]  // rbp
    str x23, [x0, #0x30]  // rsi
    str x24, [x0, #0x38]  // rdi
    str x8,  [x0, #0x40]  // r8
    str x9,  [x0, #0x48]  // r9
    str x10, [x0, #0x50]  // r10
    str x11, [x0, #0x58]  // r11
    str x12, [x0, #0x60]  // r12
    str x13, [x0, #0x68]  // r13
    str x14, [x0, #0x70]  // r14
    str x15, [x0, #0x78]  // r15

    // 5. Restore host callee-saved registers
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x23, x24, [sp, #48]
    ldp x25, x26, [sp, #64]
    ldp x27, x28, [sp, #80]
    ldp x29, x30, [sp], #112
    ret

// _recomp_call_shim: calls a host C shim from guest assembly
// x0 = host shim function pointer
.globl _recomp_call_shim
_recomp_call_shim:
    // Save LR and allocate frame (160 bytes: 32 for fp/lr/x0 + 128 for q0-q7)
    stp x29, x30, [sp, #-160]!
    mov x29, sp
    str x0, [sp, #16]
    stp q0, q1, [sp, #32]
    stp q2, q3, [sp, #64]
    stp q4, q5, [sp, #96]
    stp q6, q7, [sp, #128]

    // Load active thread ctx into x1 from [x28, x27 + 0x70] (thread-local TCB)
    add  x1, x27, #0x70
    ldr  x1, [x28, x1]

    // Sync registers to ctx before calling shim
    str x19, [x1, #0x0]   // rax
    str x21, [x1, #0x8]   // rcx
    str x22, [x1, #0x10]  // rdx
    str x20, [x1, #0x18]  // rbx
    str x26, [x1, #0x20]  // rsp
    str x25, [x1, #0x28]  // rbp
    str x23, [x1, #0x30]  // rsi
    str x24, [x1, #0x38]  // rdi
    str x8,  [x1, #0x40]  // r8
    str x9,  [x1, #0x48]  // r9
    str x10, [x1, #0x50]  // r10
    str x11, [x1, #0x58]  // r11
    str x12, [x1, #0x60]  // r12
    str x13, [x1, #0x68]  // r13
    str x14, [x1, #0x70]  // r14
    str x15, [x1, #0x78]  // r15

    // Call shim: shim(GuestContext *ctx)
    mov x0, x1
    ldr x2, [sp, #16]
    blr x2

    // Reload active thread ctx from [x28, x27 + 0x70]
    add  x1, x27, #0x70
    ldr  x1, [x28, x1]

    // Reload return value (rax, rdx) and caller-saved registers
    ldr x19, [x1, #0x0]   // rax
    ldr x22, [x1, #0x10]  // rdx
    ldr x26, [x1, #0x20]  // rsp
    ldr x8,  [x1, #0x40]  // r8
    ldr x9,  [x1, #0x48]  // r9
    ldr x10, [x1, #0x50]  // r10
    ldr x11, [x1, #0x58]  // r11
    ldr x12, [x1, #0x60]  // r12
    ldr x13, [x1, #0x68]  // r13
    ldr x14, [x1, #0x70]  // r14
    ldr x15, [x1, #0x78]  // r15
    ldr x27, [x1, #0x88]  // fs_base
    ldr x28, [x1, #0x330] // mem_base

    ldp q0, q1, [sp, #32]
    ldp q2, q3, [sp, #64]
    ldp q4, q5, [sp, #96]
    ldp q6, q7, [sp, #128]
    ldp x29, x30, [sp], #160
    ret

// _recomp_indirect_call: calls a guest function via dispatch
// x0 = guest target RIP
.globl _recomp_indirect_call
_recomp_indirect_call:
    adrp x16, _g_dispatch_l1@PAGE
    add  x16, x16, _g_dispatch_l1@PAGEOFF
    lsr  x17, x0, #32
    and  x17, x17, #0xffff
    ldr  x16, [x16, x17, lsl #3]
    cbz  x16, 99f
    lsr  x17, x0, #16
    and  x17, x17, #0xffff
    ldr  x16, [x16, x17, lsl #3]
    cbz  x16, 99f
    and  x17, x0, #0xffff
    ldr  x16, [x16, x17, lsl #3]
    cbz  x16, 99f
    br   x16
99:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x0, [sp, #16]
    add x2, x27, #0x70
    ldr x2, [x28, x2]
    cbz  x2, 98f
    str x19, [x2, #0x0]   // rax
    str x21, [x2, #0x8]   // rcx
    str x22, [x2, #0x10]  // rdx
    str x20, [x2, #0x18]  // rbx
    str x26, [x2, #0x20]  // rsp
    str x25, [x2, #0x28]  // rbp
    str x23, [x2, #0x30]  // rsi
    str x24, [x2, #0x38]  // rdi
    str x8,  [x2, #0x40]  // r8
    str x9,  [x2, #0x48]  // r9
    str x10, [x2, #0x50]  // r10
    str x11, [x2, #0x58]  // r11
    str x12, [x2, #0x60]  // r12
    str x13, [x2, #0x68]  // r13
    str x14, [x2, #0x70]  // r14
    str x15, [x2, #0x78]  // r15

98:
    ldr x1, [sp, #16]
    mov x0, x2
    bl   _recomp_dispatch_external

    add x0, x27, #0x70
    ldr x0, [x28, x0]
    cbz  x0, 97f
    ldr x19, [x0, #0x0]   // rax
    ldr x21, [x0, #0x8]   // rcx
    ldr x22, [x0, #0x10]  // rdx
    ldr x20, [x0, #0x18]  // rbx
    ldr x26, [x0, #0x20]  // rsp
    ldr x25, [x0, #0x28]  // rbp
    ldr x23, [x0, #0x30]  // rsi
    ldr x24, [x0, #0x38]  // rdi
    ldr x8,  [x0, #0x40]  // r8
    ldr x9,  [x0, #0x48]  // r9
    ldr x10, [x0, #0x50]  // r10
    ldr x11, [x0, #0x58]  // r11
    ldr x12, [x0, #0x60]  // r12
    ldr x13, [x0, #0x68]  // r13
    ldr x14, [x0, #0x70]  // r14
    ldr x15, [x0, #0x78]  // r15
    ldr x27, [x0, #0x88]  // fs_base
    ldr x28, [x0, #0x330] // mem_base

97:
    ldp x29, x30, [sp], #32
    ret

// _recomp_indirect_jump: jumps to a guest function via dispatch
// x0 = guest target RIP
.globl _recomp_indirect_jump
_recomp_indirect_jump:
    adrp x16, _g_dispatch_l1@PAGE
    add  x16, x16, _g_dispatch_l1@PAGEOFF
    lsr  x17, x0, #32
    and  x17, x17, #0xffff
    ldr  x16, [x16, x17, lsl #3]
    cbz  x16, 99f
    lsr  x17, x0, #16
    and  x17, x17, #0xffff
    ldr  x16, [x16, x17, lsl #3]
    cbz  x16, 99f
    and  x17, x0, #0xffff
    ldr  x16, [x16, x17, lsl #3]
    cbz  x16, 99f
    br   x16
99:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x0, [sp, #16]
    add x2, x27, #0x70
    ldr x2, [x28, x2]
    cbz  x2, 98f
    str x19, [x2, #0x0]   // rax
    str x21, [x2, #0x8]   // rcx
    str x22, [x2, #0x10]  // rdx
    str x20, [x2, #0x18]  // rbx
    str x26, [x2, #0x20]  // rsp
    str x25, [x2, #0x28]  // rbp
    str x23, [x2, #0x30]  // rsi
    str x24, [x2, #0x38]  // rdi
    str x8,  [x2, #0x40]  // r8
    str x9,  [x2, #0x48]  // r9
    str x10, [x2, #0x50]  // r10
    str x11, [x2, #0x58]  // r11
    str x12, [x2, #0x60]  // r12
    str x13, [x2, #0x68]  // r13
    str x14, [x2, #0x70]  // r14
    str x15, [x2, #0x78]  // r15

98:
    ldr x1, [sp, #16]
    mov x0, x2
    bl   _recomp_dispatch_external

    add x0, x27, #0x70
    ldr x0, [x28, x0]
    cbz  x0, 97f
    ldr x19, [x0, #0x0]   // rax
    ldr x21, [x0, #0x8]   // rcx
    ldr x22, [x0, #0x10]  // rdx
    ldr x20, [x0, #0x18]  // rbx
    ldr x26, [x0, #0x20]  // rsp
    ldr x25, [x0, #0x28]  // rbp
    ldr x23, [x0, #0x30]  // rsi
    ldr x24, [x0, #0x38]  // rdi
    ldr x8,  [x0, #0x40]  // r8
    ldr x9,  [x0, #0x48]  // r9
    ldr x10, [x0, #0x50]  // r10
    ldr x11, [x0, #0x58]  // r11
    ldr x12, [x0, #0x60]  // r12
    ldr x13, [x0, #0x68]  // r13
    ldr x14, [x0, #0x70]  // r14
    ldr x15, [x0, #0x78]  // r15
    ldr x27, [x0, #0x88]  // fs_base
    ldr x28, [x0, #0x330] // mem_base

97:
    ldp x29, x30, [sp], #32
    ret
`
	return writeFileIfChanged(path, []byte(content))
}

// EmitDispatch ties all chunk registrations together.
func (e *AsmEmitter) EmitDispatch(path string, numChunks int) error {
	var buf bytes.Buffer
	w := bufio.NewWriter(&buf)

	fmt.Fprintf(w, "#include \"recomp_runtime.h\"\n\nvoid recomp_register_guest_modules(void);\n\n")

	for i := range numChunks {
		fmt.Fprintf(w, "void recomp_init_dispatch_chunk_%d(void);\n", i)
	}

	fmt.Fprintf(w, "\nvoid recomp_init_dispatch_table(void) {\n")
	for i := range numChunks {
		fmt.Fprintf(w, "    recomp_init_dispatch_chunk_%d();\n", i)
	}
	fmt.Fprintf(w, "    recomp_register_guest_modules();\n}\n")

	if err := w.Flush(); err != nil {
		return err
	}
	return writeFileIfChanged(path, buf.Bytes())
}

// EmitMainRunner emits the main.c entry point.
func (e *AsmEmitter) EmitMainRunner(path string) error {
	entryAddr, entryName, err := e.ResolveEntryAddress()
	if err != nil {
		return err
	}

	vfsInitArg := "NULL"
	if e.AppDir != "" {
		vfsInitArg = fmt.Sprintf("%q", e.AppDir)
	}

	content := fmt.Sprintf(`#include "recomp_runtime.h"
#include "ps4_vfs.h"

extern void recomp_init_dispatch_table(void);
extern void recomp_enter_guest(GuestContext *ctx, uint64_t target_fn);

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    printf("[ps4-recomp] Initializing runtime (ARM64 Assembly Backend)...\n");
    ps4_vfs_init(%s);
    recomp_init_dispatch_table();

    const char *prog_name = (argc > 0 && argv[0]) ? argv[0] : "/app0/eboot.bin";
    GuestContext *ctx = recomp_init_runtime_file("guest_image.bin", 0, prog_name);
    if (!ctx) {
        fprintf(stderr, "[ps4-recomp] Failed to allocate guest memory or load guest_image.bin\n");
        return 1;
    }

    recomp_init_process_param(ctx, 0x%xULL);

    recomp_init_tls(ctx, 0x%xULL, 0x%xULL, 0x%xULL, 0x%xULL);

    recomp_setup_entry_args(ctx, argc, argv, 0x%xULL);

    printf("[ps4-recomp] Executing %%s (0x%%x) via ARM64 assembly...\n", %q, (unsigned int)0x%xULL);
    extern void fn_0x%x(void);
    recomp_enter_guest(ctx, (uint64_t)fn_0x%x);

    printf("[ps4-recomp] Execution complete.\n");
    recomp_free_runtime(ctx);
    return 0;
}
`, vfsInitArg, e.elf.ProcParamAddr, e.elf.TLSVaddr, e.elf.TLSFilesz, e.elf.TLSMemsz, e.elf.TLSAlign, entryAddr, entryName, entryAddr, entryAddr, entryAddr)

	return writeFileIfChanged(path, []byte(content))
}

// EmitGuestModules writes the runtime export tables, synthetic shims, and unwind registrations.
func (e *AsmEmitter) EmitGuestModules(path string) error {
	var buf bytes.Buffer
	w := bufio.NewWriter(&buf)

	fmt.Fprintf(w, "#include \"recomp_runtime.h\"\n#include \"ps4_sysmodule.h\"\n\n")

	// 1. Sort shimMap keys
	var sortedShimAddrs []uint64
	for addr := range e.shimMap {
		sortedShimAddrs = append(sortedShimAddrs, addr)
	}
	slices.Sort(sortedShimAddrs)

	shimAddr := make(map[string]uint64)
	for _, addr := range sortedShimAddrs {
		shim := e.shimMap[addr]
		for name, target := range CanonicalShims {
			if target == shim {
				if _, exists := shimAddr[name]; !exists {
					shimAddr[name] = addr
				}
			}
		}
	}

	nextSynth := uint64(0x1000)
	if e.elf != nil {
		nextSynth = (e.elf.MaxVAddr + 0xFFF) &^ 0xFFF
		if nextSynth < 0x1000 {
			nextSynth = 0x1000
		}
	}

	type synthEntry struct {
		addr uint64
		shim string
	}
	var synthList []synthEntry
	var synthRegs []string

	shimNames := make([]string, 0, len(CanonicalShims))
	for name := range CanonicalShims {
		shimNames = append(shimNames, name)
	}
	slices.Sort(shimNames)

	for _, name := range shimNames {
		if _, ok := shimAddr[name]; ok {
			continue
		}
		shimAddr[name] = nextSynth
		shimFn := CanonicalShims[name]
		synthList = append(synthList, synthEntry{addr: nextSynth, shim: shimFn})
		synthRegs = append(synthRegs, fmt.Sprintf("    extern void fn_0x%x(GuestContext *ctx);\n    recomp_register_fn(0x%xULL, fn_0x%x);\n", nextSynth, nextSynth, nextSynth))
		nextSynth += 16
	}

	// Forward declarations and weak fallback implementations for host shims
	uniqueShims := make(map[string]bool)
	uniqueShims["shim_unresolved_stub"] = true
	for _, target := range CanonicalShims {
		uniqueShims[target] = true
	}
	sortedShims := make([]string, 0, len(uniqueShims))
	for s := range uniqueShims {
		sortedShims = append(sortedShims, s)
	}
	slices.Sort(sortedShims)

	w.WriteString("// Forward declarations and weak fallback implementations for host shims\n")
	for _, s := range sortedShims {
		fmt.Fprintf(w, "void %s(GuestContext *ctx);\n", s)
	}
	w.WriteString("\n// Weak fallback implementations\n")
	for _, s := range sortedShims {
		if s == "shim_unresolved_stub" {
			continue
		}
		fmt.Fprintf(w, "__attribute__((weak)) void %s(GuestContext *ctx) { recomp_unimplemented_shim(ctx, %q); }\n", s, s)
	}
	w.WriteString("\n")

	w.WriteString("static const RecompModuleExport recomp_host_shim_exports[] = {\n")
	for _, name := range shimNames {
		fmt.Fprintf(w, "    { %q, 0x%xULL },\n", name, shimAddr[name])
	}
	w.WriteString("    { NULL, 0 }\n};\n\n")

	for i, mod := range e.Modules {
		fmt.Fprintf(w, "static const RecompModuleExport recomp_module_exports_%d[] = {\n", i)
		for _, exp := range mod.Exports {
			fmt.Fprintf(w, "    { %q, 0x%xULL },\n", exp.Name, exp.Address)
		}
		w.WriteString("    { NULL, 0 }\n};\n\n")

		if len(mod.Init) > 0 {
			fmt.Fprintf(w, "static const uint64_t recomp_module_init_%d[] = {\n", i)
			for _, addr := range mod.Init {
				fmt.Fprintf(w, "    0x%xULL,\n", addr)
			}
			w.WriteString("};\n\n")
		}
	}

	w.WriteString("void recomp_register_guest_modules(void) {\n")
	for _, line := range synthRegs {
		w.WriteString(line)
	}
	hostNames := []string{"libc.prx", "libSceLibcInternal.prx", "libkernel.prx", "libSceFios2.prx"}
	for _, name := range hostNames {
		fmt.Fprintf(w, "    recomp_module_register(%q, recomp_host_shim_exports);\n", name)
	}

	if e.elf != nil {
		mainName := e.elf.FileName
		if mainName == "" {
			mainName = "eboot.bin"
		}
		startAddr := e.elf.OrigMinVAddr
		endAddr := e.elf.OrigMaxVAddr
		if endAddr == 0 {
			endAddr = e.elf.MaxVAddr
		}
		numSegs := len(e.elf.Segments)
		if numSegs > 4 {
			numSegs = 4
		}
		var segsInit strings.Builder
		for si := 0; si < numSegs; si++ {
			s := e.elf.Segments[si]
			prot := 0
			if s.Flags&1 != 0 {
				prot |= 1
			}
			if s.Flags&2 != 0 {
				prot |= 2
			}
			if s.Flags&4 != 0 {
				prot |= 4
			}
			fmt.Fprintf(&segsInit, "            { .addr = 0x%xULL, .size = 0x%xULL, .prot = %d },\n", s.Vaddr, s.Memsz, prot)
		}
		fmt.Fprintf(w, "    static const RecompModuleUnwindInfo eboot_unwind = {\n"+
			"        .name = %q,\n"+
			"        .start_addr = 0x%xULL,\n"+
			"        .end_addr = 0x%xULL,\n"+
			"        .seg0_addr = 0x%xULL,\n"+
			"        .seg0_size = 0x%xULL,\n"+
			"        .eh_frame_hdr_addr = 0x%xULL,\n"+
			"        .eh_frame_hdr_size = 0x%xULL,\n"+
			"        .eh_frame_addr = 0x%xULL,\n"+
			"        .eh_frame_size = 0x%xULL,\n"+
			"        .num_segments = %d,\n"+
			"        .segments = {\n%s"+
			"        },\n"+
			"    };\n"+
			"    recomp_module_register_unwind_info(&eboot_unwind);\n",
			mainName, startAddr, endAddr, e.elf.Seg0Addr, e.elf.Seg0Size,
			e.elf.EHFrameHdrAddr, e.elf.EHFrameHdrSize, e.elf.EHFrameAddr, e.elf.EHFrameSize,
			numSegs, segsInit.String())
	}

	for i, mod := range e.Modules {
		names := uniqueModuleNames(mod.FileName, mod.Aliases)
		for _, name := range names {
			fmt.Fprintf(w, "    recomp_module_register(%q, recomp_module_exports_%d);\n", name, i)
			if len(mod.Init) > 0 {
				fmt.Fprintf(w, "    recomp_module_register_init(%q, recomp_module_init_%d, %d);\n", name, i, len(mod.Init))
			}
		}
		modNumSegs := len(mod.Segments)
		if modNumSegs > 4 {
			modNumSegs = 4
		}
		var modSegsInit strings.Builder
		for si := 0; si < modNumSegs; si++ {
			s := mod.Segments[si]
			prot := 0
			if s.Flags&1 != 0 {
				prot |= 1
			}
			if s.Flags&2 != 0 {
				prot |= 2
			}
			if s.Flags&4 != 0 {
				prot |= 4
			}
			fmt.Fprintf(&modSegsInit, "            { .addr = 0x%xULL, .size = 0x%xULL, .prot = %d },\n", s.Vaddr, s.Memsz, prot)
		}
		fmt.Fprintf(w, "    static const RecompModuleUnwindInfo mod_%d_unwind = {\n"+
			"        .name = %q,\n"+
			"        .start_addr = 0x%xULL,\n"+
			"        .end_addr = 0x%xULL,\n"+
			"        .seg0_addr = 0x%xULL,\n"+
			"        .seg0_size = 0x%xULL,\n"+
			"        .eh_frame_hdr_addr = 0x%xULL,\n"+
			"        .eh_frame_hdr_size = 0x%xULL,\n"+
			"        .eh_frame_addr = 0x%xULL,\n"+
			"        .eh_frame_size = 0x%xULL,\n"+
			"        .num_segments = %d,\n"+
			"        .segments = {\n%s"+
			"        },\n"+
			"    };\n"+
			"    recomp_module_register_unwind_info(&mod_%d_unwind);\n",
			i, mod.FileName, mod.StartAddr, mod.EndAddr, mod.Seg0Addr, mod.Seg0Size,
			mod.EHFrameHdrAddr, mod.EHFrameHdrSize, mod.EHFrameAddr, mod.EHFrameSize,
			modNumSegs, modSegsInit.String(), i)
	}

	w.WriteString("}\n")
	if err := w.Flush(); err != nil {
		return err
	}
	if err := writeFileIfChanged(path, buf.Bytes()); err != nil {
		return err
	}

	// 2. Write synth_shims.s
	synthPath := strings.TrimSuffix(path, ".c") + "_synth.s"
	var sBuf bytes.Buffer
	sw := bufio.NewWriter(&sBuf)
	sw.WriteString("// Synthetic shims ARM64 bridge\n.text\n.p2align 2\n\n")
	for _, entry := range synthList {
		fmt.Fprintf(sw, ".globl _fn_0x%x\n_fn_0x%x:\n", entry.addr, entry.addr)
		fmt.Fprintf(sw, "    adrp x0, _%s@PAGE\n", entry.shim)
		fmt.Fprintf(sw, "    add  x0, x0, _%s@PAGEOFF\n", entry.shim)
		fmt.Fprintf(sw, "    b    _recomp_call_shim\n\n")
	}
	if err := sw.Flush(); err != nil {
		return err
	}
	return writeFileIfChanged(synthPath, sBuf.Bytes())
}
