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
.globl _g_current_guest_ctx
.data
.p2align 3
_g_current_guest_ctx:
    .quad 0

.text
.p2align 2

// void recomp_enter_guest(GuestContext *ctx, uint64_t target_fn)
// x0 = ctx, x1 = target_fn
.globl _recomp_enter_guest
_recomp_enter_guest:
    // 1. Save host callee-saved registers and frame pointer
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]

    // Save active ctx pointer
    adrp x2, _g_current_guest_ctx@PAGE
    str  x0, [x2, _g_current_guest_ctx@PAGEOFF]

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

    // 4. On return: save guest registers back to GuestContext
    adrp x2, _g_current_guest_ctx@PAGE
    ldr  x0, [x2, _g_current_guest_ctx@PAGEOFF]
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
    ldp x29, x30, [sp], #96
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

    // Load active ctx into x1
    adrp x1, _g_current_guest_ctx@PAGE
    ldr  x1, [x1, _g_current_guest_ctx@PAGEOFF]

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

    // Reload active ctx
    adrp x1, _g_current_guest_ctx@PAGE
    ldr  x1, [x1, _g_current_guest_ctx@PAGEOFF]

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
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x2, _g_current_guest_ctx@PAGE
    ldr  x2, [x2, _g_current_guest_ctx@PAGEOFF]
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
    mov x1, x0
    mov x0, x2
    bl   _recomp_dispatch_external

    adrp x2, _g_current_guest_ctx@PAGE
    ldr  x0, [x2, _g_current_guest_ctx@PAGEOFF]
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
    ldp x29, x30, [sp], #16
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
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    adrp x2, _g_current_guest_ctx@PAGE
    ldr  x2, [x2, _g_current_guest_ctx@PAGEOFF]
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
    mov x1, x0
    mov x0, x2
    bl   _recomp_dispatch_external

    adrp x2, _g_current_guest_ctx@PAGE
    ldr  x0, [x2, _g_current_guest_ctx@PAGEOFF]
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
    ldp x29, x30, [sp], #16
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

    recomp_setup_entry_args(ctx, argc, argv, 0x%xULL);

    printf("[ps4-recomp] Executing %%s (0x%%x) via ARM64 assembly...\n", %q, (unsigned int)0x%xULL);
    extern void fn_0x%x(void);
    recomp_enter_guest(ctx, (uint64_t)fn_0x%x);

    printf("[ps4-recomp] Execution complete.\n");
    recomp_free_runtime(ctx);
    return 0;
}
`, vfsInitArg, e.elf.ProcParamAddr, entryAddr, entryName, entryAddr, entryAddr, entryAddr)

	return writeFileIfChanged(path, []byte(content))
}

// EmitGuestModules writes the runtime export tables used by sceKernelDlsym.
func (e *AsmEmitter) EmitGuestModules(path string) error {
	var buf bytes.Buffer
	w := bufio.NewWriter(&buf)

	fmt.Fprintf(w, "#include \"recomp_runtime.h\"\n#include \"ps4_sysmodule.h\"\n\nvoid recomp_register_guest_modules(void) {\n")
	for _, mod := range e.Modules {
		fmt.Fprintf(w, "    // Module %s\n", mod.FileName)
	}
	fmt.Fprintf(w, "}\n")

	if err := w.Flush(); err != nil {
		return err
	}
	return writeFileIfChanged(path, buf.Bytes())
}
