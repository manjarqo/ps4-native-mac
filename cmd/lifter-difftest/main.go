// lifter-difftest: differential testing of the x86-64 lifter against real hardware semantics.
//
// It samples instruction encodings from a guest image (addresses listed in a linear
// disassembly), keeps one representative per (opcode, operand shape, immediate) signature, and
// generates two programs that execute every sampled instruction from identical random register
// and memory states:
//
//   - native.s:  the raw instruction bytes wrapped in x86-64 load/store stubs (run under Rosetta 2)
//   - lifted.c:  the lifter's C translation of the same instruction (run natively on arm64)
//
// The final states (GPRs, YMM, arithmetic flags, scratch memory) are then compared by
// run.sh/compare.py next to this file. Memory operands are redirected into a scratch area that is
// mapped at the same fixed address in both programs; the lifted side uses mem_base = 0.
//
// Usage: lifter-difftest -image guest_image.bin -dis eboot_full_dis.txt -out DIR [-max-per-op N]
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"ps4-recomp/pkg/disasm"
	"ps4-recomp/pkg/lifter"

	"golang.org/x/arch/x86/x86asm"
)

const (
	scratchBase = 0x800000000
	scratchSize = 0x100000
	memTarget   = scratchBase + 0x80000
	indexValue  = 0x40
)

// GPR index in GuestContext order.
var gprIndex = map[x86asm.Reg]int{}

func init() {
	fam := [][]x86asm.Reg{
		{x86asm.RAX, x86asm.EAX, x86asm.AX, x86asm.AL, x86asm.AH},
		{x86asm.RCX, x86asm.ECX, x86asm.CX, x86asm.CL, x86asm.CH},
		{x86asm.RDX, x86asm.EDX, x86asm.DX, x86asm.DL, x86asm.DH},
		{x86asm.RBX, x86asm.EBX, x86asm.BX, x86asm.BL, x86asm.BH},
		{x86asm.RSP, x86asm.ESP, x86asm.SP, x86asm.SPB},
		{x86asm.RBP, x86asm.EBP, x86asm.BP, x86asm.BPB},
		{x86asm.RSI, x86asm.ESI, x86asm.SI, x86asm.SIB},
		{x86asm.RDI, x86asm.EDI, x86asm.DI, x86asm.DIB},
		{x86asm.R8, x86asm.R8L, x86asm.R8W, x86asm.R8B},
		{x86asm.R9, x86asm.R9L, x86asm.R9W, x86asm.R9B},
		{x86asm.R10, x86asm.R10L, x86asm.R10W, x86asm.R10B},
		{x86asm.R11, x86asm.R11L, x86asm.R11W, x86asm.R11B},
		{x86asm.R12, x86asm.R12L, x86asm.R12W, x86asm.R12B},
		{x86asm.R13, x86asm.R13L, x86asm.R13W, x86asm.R13B},
		{x86asm.R14, x86asm.R14L, x86asm.R14W, x86asm.R14B},
		{x86asm.R15, x86asm.R15L, x86asm.R15W, x86asm.R15B},
	}
	for i, f := range fam {
		for _, r := range f {
			gprIndex[r] = i
		}
	}
}

func regClass(r x86asm.Reg) string {
	switch {
	case r >= x86asm.AL && r <= x86asm.R15B:
		return "r8"
	case r >= x86asm.AX && r <= x86asm.R15W:
		return "r16"
	case r >= x86asm.EAX && r <= x86asm.R15L:
		return "r32"
	case r >= x86asm.RAX && r <= x86asm.R15:
		return "r64"
	case r >= x86asm.X0 && r <= x86asm.X15:
		return "x"
	case r >= x86asm.Y0 && r <= x86asm.Y15:
		return "y"
	case r >= x86asm.M0 && r <= x86asm.M7:
		return "mm"
	case r >= x86asm.F0 && r <= x86asm.F7:
		return "st"
	}
	return "other:" + r.String()
}

type test struct {
	addr     uint64
	bytes    []byte
	text     string
	sig      string
	setRegs  map[int]uint64 // GPR overrides for memory addressing
	lifted   []string
	hasFlags bool
}

func skipOp(op x86asm.Op) bool {
	s := op.String()
	switch op {
	case x86asm.CALL, x86asm.RET, x86asm.JMP, x86asm.PUSH, x86asm.POP, x86asm.PUSHFQ, x86asm.POPFQ,
		x86asm.INT, x86asm.UD2, x86asm.HLT, x86asm.CPUID, x86asm.RDTSC, x86asm.RDTSCP, x86asm.XGETBV,
		x86asm.SYSCALL, x86asm.LEAVE, x86asm.ENTER, x86asm.PAUSE, x86asm.FWAIT, x86asm.LDMXCSR,
		x86asm.STMXCSR, x86asm.VLDMXCSR, x86asm.VSTMXCSR, x86asm.FXSAVE, x86asm.FXRSTOR, x86asm.XSAVE,
		x86asm.XRSTOR, x86asm.LFENCE, x86asm.MFENCE, x86asm.SFENCE, x86asm.EMMS, x86asm.VZEROUPPER,
		x86asm.VZEROALL, x86asm.DIV, x86asm.IDIV:
		return true
	}
	switch op {
	case x86asm.MOVSB, x86asm.MOVSW, x86asm.MOVSD, x86asm.MOVSQ, x86asm.STOSB, x86asm.STOSW, x86asm.STOSD,
		x86asm.STOSQ, x86asm.LODSB, x86asm.LODSW, x86asm.LODSD, x86asm.LODSQ, x86asm.SCASB, x86asm.SCASW,
		x86asm.SCASD, x86asm.SCASQ, x86asm.CMPSB, x86asm.CMPSW, x86asm.CMPSD, x86asm.CMPSQ, x86asm.INSB,
		x86asm.INSW, x86asm.INSD, x86asm.OUTSB, x86asm.OUTSW, x86asm.OUTSD, x86asm.XLATB:
		return true
	}
	if strings.HasPrefix(s, "J") || strings.HasPrefix(s, "LOOP") || strings.HasPrefix(s, "PREFETCH") ||
		(strings.HasPrefix(s, "F") && !strings.HasPrefix(s, "FX")) {
		return true
	}
	return false
}

func main() {
	imgPath := flag.String("image", "", "guest memory image (file offset == guest address)")
	disPath := flag.String("dis", "", "linear disassembly listing (lines 'ADDR: ...')")
	outDir := flag.String("out", "difftest", "output directory")
	maxPerOp := flag.Int("max-per-op", 24, "max distinct signatures per opcode")
	flag.Parse()

	img, err := os.ReadFile(*imgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	f, err := os.Open(*disPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer f.Close()

	l := lifter.NewLifter(nil)
	fn := &disasm.Function{EntryAddr: 0x1000, Blocks: make(map[uint64]*disasm.BasicBlock)}
	seen := map[string]bool{}
	perOp := map[x86asm.Op]int{}
	var tests []*test
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		c := strings.IndexByte(line, ':')
		if c <= 0 {
			continue
		}
		addr, err := strconv.ParseUint(line[:c], 16, 64)
		if err != nil || addr >= uint64(len(img)) {
			continue
		}
		if img[addr] == 0x62 || img[addr] == 0xf0 || img[addr] == 0x64 || img[addr] == 0x65 { // EVEX, LOCK, FS, GS
			continue
		}
		inst, err := x86asm.Decode(img[addr:], 64)
		if err != nil || inst.Len == 0 || skipOp(inst.Op) || !lifter.IsOpcodeSupported(inst.Op) {
			continue
		}
		// operand signature, reject RIP/RSP use
		var sig []string
		bad := false
		var mem *x86asm.Mem
		for _, a := range inst.Args {
			if a == nil {
				break
			}
			switch v := a.(type) {
			case x86asm.Reg:
				if idx, ok := gprIndex[v]; ok && idx == 4 {
					bad = true
				}
				if v == x86asm.RIP {
					bad = true
				}
				cl := regClass(v)
				if strings.HasPrefix(cl, "other") || cl == "st" || cl == "mm" {
					bad = true
				}
				sig = append(sig, cl)
			case x86asm.Mem:
				if v.Base == x86asm.RIP || v.Segment != 0 || v.Base == x86asm.RSP || v.Base == x86asm.ESP ||
					(v.Base == 0 && v.Index == 0) {
					bad = true
				}
				vv := v
				mem = &vv
				sig = append(sig, fmt.Sprintf("m%d", inst.MemBytes))
			case x86asm.Imm:
				sig = append(sig, fmt.Sprintf("i%x", uint64(v)))
			case x86asm.Rel:
				bad = true
			default:
				bad = true
			}
		}
		if bad || inst.Op == x86asm.LEA && mem == nil {
			continue
		}
		// register aliasing pattern (dest == src2 etc. exercises copy-order bugs)
		var regs []x86asm.Reg
		alias := ""
		for _, a := range inst.Args {
			if r, ok := a.(x86asm.Reg); ok {
				for k, pr := range regs {
					if pr == r || (gprIndex[pr] == gprIndex[r] && regClass(pr)[0] == 'r' && regClass(r)[0] == 'r' && gprIndex[r] != 0) {
						alias += fmt.Sprintf("=%d%d", k, len(regs))
					}
				}
				regs = append(regs, r)
			} else if m, ok := a.(x86asm.Mem); ok {
				for k, pr := range regs {
					if pr == m.Base || pr == m.Index {
						alias += fmt.Sprintf("@%d", k)
					}
				}
			}
		}
		key := inst.Op.String() + " " + strings.Join(sig, ",") + alias
		if seen[key] || perOp[inst.Op] >= *maxPerOp {
			continue
		}
		t := &test{addr: addr, bytes: append([]byte(nil), img[addr:addr+uint64(inst.Len)]...), text: safeText(inst, addr), sig: key,
			setRegs: map[int]uint64{}}
		if mem != nil {
			bi, hasB := gprIndex[mem.Base]
			ii, hasI := gprIndex[mem.Index]
			scale := uint64(mem.Scale)
			if scale == 0 {
				scale = 1
			}
			disp := uint64(mem.Disp)
			if hasB && hasI && bi == ii {
				v := (memTarget - disp) / (1 + scale)
				v &^= 63
				t.setRegs[bi] = v
			} else {
				iv := uint64(0)
				if hasI {
					iv = indexValue
					t.setRegs[ii] = iv
				}
				if hasB {
					t.setRegs[bi] = memTarget - disp - iv*scale
				} else {
					continue
				}
			}
			// 32-bit addressing would truncate
			if mem.Base >= x86asm.EAX && mem.Base <= x86asm.R15L {
				continue
			}
		}
		lines, err := l.LiftInstruction(disasm.Instruction{Address: addr, Inst: inst}, addr+uint64(inst.Len), fn)
		if err != nil {
			continue
		}
		code := strings.Join(lines, "\n")
		if strings.Contains(code, "goto ") || strings.Contains(code, "fn_0x") || strings.Contains(code, "recomp_dispatch") || strings.Contains(code, "recomp_call") ||
			strings.Contains(code, "return") {
			continue
		}
		t.lifted = lines
		seen[key] = true
		perOp[inst.Op]++
		tests = append(tests, t)
		// Synthesized aliasing variants of VEX register forms: src2 = dst, src1 = dst.
		for _, v := range vexAliasVariants(t.bytes) {
			vi, err := x86asm.Decode(v, 64)
			if err != nil || vi.Op != inst.Op || vi.Len != len(v) {
				continue
			}
			vlines, err := l.LiftInstruction(disasm.Instruction{Address: addr, Inst: vi}, addr+uint64(vi.Len), fn)
			if err != nil {
				continue
			}
			vk := "VAR " + safeText(vi, addr)
			if seen[vk] {
				continue
			}
			seen[vk] = true
			tests = append(tests, &test{addr: addr, bytes: v, text: safeText(vi, addr), sig: key + " [synth]",
				setRegs: t.setRegs, lifted: vlines})
		}
	}
	sort.SliceStable(tests, func(i, j int) bool { return tests[i].sig < tests[j].sig })
	if err := os.MkdirAll(*outDir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	writeNative(filepath.Join(*outDir, "native_tests.s"), tests)
	writeLifted(filepath.Join(*outDir, "lifted_tests.c"), tests)
	writeList(filepath.Join(*outDir, "tests.txt"), tests)
	fmt.Printf("%d tests written to %s\n", len(tests), *outDir)
}

func writeList(path string, tests []*test) {
	var b strings.Builder
	for i, t := range tests {
		fmt.Fprintf(&b, "%d\t0x%x\t%s\t%s\n", i, t.addr, t.sig, t.text)
	}
	os.WriteFile(path, []byte(b.String()), 0o644)
}

// State layout (shared with harness.h): u64 gpr[16]; u64 flags; u32 mxcsr; u32 pad; u8 ymm[16][32]
const (
	offGpr   = 0
	offFlags = 128
	offMxcsr = 136
	offYmm   = 144
)

var gprNames = []string{"rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"}

func writeNative(path string, tests []*test) {
	var b strings.Builder
	b.WriteString(".intel_syntax noprefix\n.text\n")
	b.WriteString(".globl _g_state\n.zerofill __DATA,__bss,_g_state,8,3\n")
	b.WriteString(".zerofill __DATA,__bss,_g_saved_rsp,8,3\n.zerofill __DATA,__bss,_g_tmp,8,3\n")
	for i, t := range tests {
		fmt.Fprintf(&b, "\n.globl _nt_%d\n.p2align 4\n_nt_%d:\n", i, i)
		b.WriteString("  push rbx\n  push rbp\n  push r12\n  push r13\n  push r14\n  push r15\n")
		b.WriteString("  mov [rip+_g_saved_rsp], rsp\n  mov [rip+_g_state], rdi\n")
		for r := 0; r < 16; r++ {
			fmt.Fprintf(&b, "  vmovdqu ymm%d, [rdi+%d]\n", r, offYmm+32*r)
		}
		fmt.Fprintf(&b, "  ldmxcsr [rdi+%d]\n", offMxcsr)
		fmt.Fprintf(&b, "  push qword ptr [rdi+%d]\n  popfq\n", offFlags)
		for r := 0; r < 16; r++ {
			if r == 4 || r == 7 {
				continue
			}
			fmt.Fprintf(&b, "  mov %s, [rdi+%d]\n", gprNames[r], offGpr+8*r)
		}
		fmt.Fprintf(&b, "  mov rdi, [rdi+%d]\n", offGpr+8*7)
		b.WriteString("  .byte ")
		for k, by := range t.bytes {
			if k > 0 {
				b.WriteString(",")
			}
			fmt.Fprintf(&b, "0x%02x", by)
		}
		b.WriteString("\n")
		b.WriteString("  mov [rip+_g_tmp], rax\n  pushfq\n  pop rax\n")
		b.WriteString("  push rcx\n  mov rcx, [rip+_g_state]\n")
		fmt.Fprintf(&b, "  mov [rcx+%d], rax\n", offFlags)
		b.WriteString("  pop rax\n") // rax = original rcx
		fmt.Fprintf(&b, "  mov [rcx+%d], rax\n", offGpr+8*1)
		b.WriteString("  mov rax, [rip+_g_tmp]\n")
		fmt.Fprintf(&b, "  mov [rcx+%d], rax\n", offGpr)
		for r := 2; r < 16; r++ {
			if r == 4 {
				continue
			}
			fmt.Fprintf(&b, "  mov [rcx+%d], %s\n", offGpr+8*r, gprNames[r])
		}
		for r := 0; r < 16; r++ {
			fmt.Fprintf(&b, "  vmovdqu [rcx+%d], ymm%d\n", offYmm+32*r, r)
		}
		fmt.Fprintf(&b, "  stmxcsr [rcx+%d]\n", offMxcsr)
		b.WriteString("  mov rsp, [rip+_g_saved_rsp]\n  vzeroupper\n")
		b.WriteString("  pop r15\n  pop r14\n  pop r13\n  pop r12\n  pop rbp\n  pop rbx\n  ret\n")
	}
	fmt.Fprintf(&b, "\n.data\n.globl _nt_count\n_nt_count: .quad %d\n.globl _nt_table\n.p2align 3\n_nt_table:\n", len(tests))
	for i := range tests {
		fmt.Fprintf(&b, "  .quad _nt_%d\n", i)
	}
	b.WriteString(".globl _nt_regsets\n_nt_regsets:\n")
	for _, t := range tests {
		// per test: 16 x (mask bit in first quad, then values)
		var mask uint64
		vals := make([]uint64, 16)
		for r, v := range t.setRegs {
			mask |= 1 << uint(r)
			vals[r] = v
		}
		fmt.Fprintf(&b, "  .quad 0x%x", mask)
		for _, v := range vals {
			fmt.Fprintf(&b, ", 0x%x", v)
		}
		b.WriteString("\n")
	}
	os.WriteFile(path, []byte(b.String()), 0o644)
}

func writeLifted(path string, tests []*test) {
	var b strings.Builder
	b.WriteString("#include \"recomp_context.h\"\n#include <stdint.h>\n")
	for i, t := range tests {
		fmt.Fprintf(&b, "\n/* %s */\nstatic void lt_%d(GuestContext *__restrict__ ctx) {\n", t.text, i)
		for _, ln := range t.lifted {
			b.WriteString(ln)
			b.WriteString("\n")
		}
		b.WriteString("}\n")
	}
	fmt.Fprintf(&b, "\nconst uint64_t lt_count = %d;\nvoid (*const lt_table[])(GuestContext *) = {\n", len(tests))
	for i := range tests {
		fmt.Fprintf(&b, "  lt_%d,\n", i)
	}
	b.WriteString("};\nconst uint64_t lt_regsets[][17] = {\n")
	for _, t := range tests {
		var mask uint64
		vals := make([]uint64, 16)
		for r, v := range t.setRegs {
			mask |= 1 << uint(r)
			vals[r] = v
		}
		fmt.Fprintf(&b, "  {0x%x", mask)
		for _, v := range vals {
			fmt.Fprintf(&b, ", 0x%x", v)
		}
		b.WriteString("},\n")
	}
	b.WriteString("};\n")
	os.WriteFile(path, []byte(b.String()), 0o644)
}

func safeText(inst x86asm.Inst, addr uint64) (out string) {
	defer func() {
		if recover() != nil {
			out = inst.String()
		}
	}()
	return x86asm.IntelSyntax(inst, addr, nil)
}

// vexAliasVariants returns re-encodings of a VEX register-form instruction where the second
// source (ModRM.rm) and/or the first source (VEX.vvvv) name the destination (ModRM.reg).
func vexAliasVariants(b []byte) [][]byte {
	if len(b) < 4 {
		return nil
	}
	var modrmAt int
	var reg, rm int
	switch b[0] {
	case 0xC5:
		modrmAt = 3
		if len(b) <= modrmAt {
			return nil
		}
		reg = int((b[3]>>3)&7) | int((^b[1]>>7)&1)<<3
		rm = int(b[3] & 7)
	case 0xC4:
		if b[1]&0x1f != 1 { // only map 0F (opcode is one byte); 0F38/0F3A have the same layout
			if b[1]&0x1f != 2 && b[1]&0x1f != 3 {
				return nil
			}
		}
		modrmAt = 4
		if len(b) <= modrmAt {
			return nil
		}
		reg = int((b[4]>>3)&7) | int((^b[1]>>7)&1)<<3
		rm = int(b[4]&7) | int((^b[1]>>5)&1)<<3
	default:
		return nil
	}
	if b[modrmAt]>>6 != 3 {
		return nil
	}
	_ = rm
	var out [][]byte
	// src2 = dst
	v := append([]byte(nil), b...)
	v[modrmAt] = (v[modrmAt] &^ 7) | byte(reg&7)
	if b[0] == 0xC4 {
		if reg >= 8 {
			v[1] &^= 0x20 // B = ~1
		} else {
			v[1] |= 0x20
		}
		out = append(out, v)
	} else if reg < 8 {
		out = append(out, v)
	}
	// src1 = dst (vvvv = ~reg)
	w := append([]byte(nil), b...)
	vb := 2
	if b[0] == 0xC5 {
		vb = 1
	}
	if b[0] == 0xC4 {
		vb = 2
	}
	w[vb] = (w[vb] &^ 0x78) | byte((^reg&0xf)<<3)
	out = append(out, w)
	return out
}
