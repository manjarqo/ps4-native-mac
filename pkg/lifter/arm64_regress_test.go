package lifter

// Regression tests for the instruction classes that the lifter-difftest-asm harness
// (cmd/lifter-difftest-asm, which runs the lifted code against x86-64 under Rosetta 2) found
// lowered wrongly. Each test checks the property of the lowering that its fix introduced; the
// harness checks the behavior end to end.

import (
	"encoding/hex"
	"strconv"
	"strings"
	"testing"

	"ps4-recomp/pkg/disasm"

	"golang.org/x/arch/x86/x86asm"
)

// liftBlock lifts the hex-encoded x86 instructions as one block of a function (flags are
// treated as live everywhere, the conservative default) and returns the lowering of each.
func liftBlock(t *testing.T, insts ...string) [][]string {
	t.Helper()
	l := NewArm64Lifter(nil)
	fn := &disasm.Function{
		EntryAddr: 0x1000,
		EndAddr:   0x9000,
		Blocks:    map[uint64]*disasm.BasicBlock{0x1000: {StartAddr: 0x1000}},
	}
	pc := uint64(0x1000)
	var out [][]string
	for _, h := range insts {
		b, err := hex.DecodeString(h)
		if err != nil {
			t.Fatalf("bad hex %q: %v", h, err)
		}
		inst, err := x86asm.Decode(b, 64)
		if err != nil {
			t.Fatalf("decode %s: %v", h, err)
		}
		next := pc + uint64(inst.Len)
		lines, err := l.LiftInstructionToBuf(disasm.Instruction{Address: pc, Inst: inst}, next, fn, nil)
		if err != nil {
			t.Fatalf("lift %s: %v", inst, err)
		}
		out = append(out, lines)
		pc = next
	}
	return out
}

// code returns the instruction text of a lowering line: no indentation, no trailing comment.
func code(line string) string {
	if i := strings.Index(line, "//"); i >= 0 {
		line = line[:i]
	}
	return strings.Join(strings.Fields(line), " ")
}

// lineMatches compares a lowering line with want; a want ending in "..." is a prefix.
func lineMatches(line, want string) bool {
	c := code(line)
	if p, ok := strings.CutSuffix(want, "..."); ok {
		return strings.HasPrefix(c, p)
	}
	return c == want
}

// requireInOrder fails unless lines contain each of want, in this order.
func requireInOrder(t *testing.T, what string, lines []string, want ...string) {
	t.Helper()
	i := 0
	for _, ln := range lines {
		if i < len(want) && lineMatches(ln, want[i]) {
			i++
		}
	}
	if i < len(want) {
		t.Errorf("%s: expected %q (in order %q), got:\n%s", what, want[i], want, strings.Join(lines, "\n"))
	}
}

// forbid fails if a line of lines matches one of bad.
func forbid(t *testing.T, what string, lines []string, bad ...string) {
	t.Helper()
	for _, ln := range lines {
		for _, b := range bad {
			if lineMatches(ln, b) {
				t.Errorf("%s: unexpected %q, got:\n%s", what, code(ln), strings.Join(lines, "\n"))
			}
		}
	}
}

// writesVecReg reports whether a line of lines has vector register n (v/q/d/s/h/b) as its
// destination, i.e. its first operand; stores and compares have no register destination.
func writesVecReg(lines []string, n int) bool {
	for _, ln := range lines {
		f := strings.Fields(strings.ReplaceAll(code(ln), ",", " "))
		if len(f) < 2 {
			continue
		}
		switch f[0] {
		case "str", "stp", "stur", "st1", "cmp", "fcmp", "tst", "cmn":
			continue
		}
		d := f[1]
		if i := strings.IndexAny(d, ".["); i >= 0 {
			d = d[:i]
		}
		if len(d) > 1 && strings.ContainsRune("vqdshb", rune(d[0])) && d[1:] == strconv.Itoa(n) {
			return true
		}
	}
	return false
}

// Carry sense: x86 CF is held in ARM C either inverted (after SUBS/CMP, C = !CF) or directly
// (after ADDS, and C = 0 = CF after logical operations). The lifter used one fixed sense per
// condition, so CF-reading conditions after logical operations, A/BE after additions and the
// flags of 8/16-bit arithmetic were wrong, and INC/DEC clobbered CF.
func TestRegressCarrySense(t *testing.T) {
	// and eax, ebx; jb: after AND, C = 0 = CF; the branch brings C into the block-boundary
	// sense (C = !CF) before testing it.
	l := liftBlock(t, "21d8", "720e")
	requireInOrder(t, "jb after and", l[1], "cfinv", "b.cs ...")

	// add rax, rbx; ja: ARM HI needs C = !CF, so C is inverted first.
	l = liftBlock(t, "4801d8", "770e")
	requireInOrder(t, "ja after add", l[1], "cfinv", "b.ls ...")

	// add al, bl: 8-bit flags come from the operands shifted to the top of a W register.
	l = liftBlock(t, "00d8")
	requireInOrder(t, "add al, bl", l[0], "adds w17, w17, w16, lsl #24", "bfi x19, x17, #0, #8")

	// cmp rax, rbx; inc ecx: INC keeps CF.
	l = liftBlock(t, "4839d8", "ffc1")
	requireInOrder(t, "inc after cmp", l[1], "cset w2, cs", "adds w21, w21, #1", "rmif x2, #63, #2")

	// adc r12d, 0 at a block start: C = !CF there, ADCS needs C = CF.
	l = liftBlock(t, "4183d400")
	requireInOrder(t, "adc", l[0], "cfinv", "adcs w12, w12, wzr")
}

// Shifts and rotates: a count of 0 leaves the flags unchanged, CF is the last bit shifted out,
// OF is defined for counts of 1, and rotates set CF/OF. The lifter set only SF/ZF (TST).
func TestRegressShiftFlags(t *testing.T) {
	// cmp rax, rbx; shl eax, cl: flags only change for a non-zero count.
	l := liftBlock(t, "4839d8", "d3e0")
	requireInOrder(t, "shl eax, cl", l[1], "and w1, w21, #31", "cbz w1, ...", "rmif x2, #0, #3", "L_shift_...", "mov w19, w0")

	// rol eax, 1: CF = bit 0 of the result, OF = CF ^ MSB.
	l = liftBlock(t, "d1c0")
	requireInOrder(t, "rol eax, 1", l[0], "ror w0, w4, #31", "and x2, x0, #1", "rmif x2, #0, #3")

	// shr rdx, 0x20: CF = bit 31, OF = the original MSB.
	l = liftBlock(t, "48c1ea20")
	requireInOrder(t, "shr rdx, 0x20", l[0], "ubfx x2, x22, #31, #1", "ubfx x3, x22, #63, #1", "rmif x2, #0, #3")

	// rcl eax, 1 at a block start: CF is read in the block-boundary sense (CF = !C).
	l = liftBlock(t, "d1d0")
	requireInOrder(t, "rcl eax, 1", l[0], "cset w2, cc", "rmif x4, #0, #3")
}

// MUL/IMUL set CF = OF = (the result does not fit the destination); the lifter left them.
func TestRegressMulFlags(t *testing.T) {
	l := liftBlock(t, "410fafc6") // imul eax, r14d
	requireInOrder(t, "imul eax, r14d", l[0], "smull x0, w19, w14", "cmp x0, w0, sxtw", "cset w2, ne", "mov w19, w0", "rmif x2, #0, #3")

	l = liftBlock(t, "48f7e1") // mul rcx
	requireInOrder(t, "mul rcx", l[0], "umulh x22, x19, x21", "cmp x2, #0", "rmif x2, #0, #3")
}

// Bit test, bit counts and BMI: BT changes only CF (it set ZF), TZCNT/LZCNT take CF from the
// source and ZF from the result, BEXTR with a start >= 32 gives 0, ANDN read its first source
// from a register its address computation had overwritten, BLSI/BLSR/BLSMSK set CF in the
// wrong sense.
func TestRegressBitOps(t *testing.T) {
	// cmp rax, rbx; bt qword [rax+0x88], 0x20
	l := liftBlock(t, "4839d8", "480fbaa08800000020")
	requireInOrder(t, "bt", l[1], "ubfx x2, x17, #32, #1", "rmif x2, #63, #2")
	forbid(t, "bt", l[1], "cmp ...", "tst ...", "msr nzcv...")

	l = liftBlock(t, "f30fbcc1") // tzcnt eax, ecx
	requireInOrder(t, "tzcnt", l[0], "rbit w1, w0", "clz w1, w1", "cmp w0, #0", "ccmp w1, #0, #0, ne", "mov w19, w1")

	l = liftBlock(t, "c4e270f780c0000000") // bextr eax, [rax+0xc0], ecx
	requireInOrder(t, "bextr", l[0], "lsr w0, w0, w1", "cmp w1, #32", "csel w0, wzr, w0, hs")

	l = liftBlock(t, "c4e208f208") // andn ecx, r14d, [rax]
	requireInOrder(t, "andn", l[0], "ldr w17, [x28, x16]", "bics w21, w17, w14")

	l = liftBlock(t, "c4e278f3c9") // blsr eax, ecx: CF = (src == 0)
	requireInOrder(t, "blsr", l[0], "cmp w0, #0", "cset w2, eq", "tst w1, w1", "rmif x2, #63, #2", "mov w19, w1")
}

// Narrow operands: 16-bit CMOVcc, CDQ (a 32-bit write clears RDX[63:32]), and XCHG/XADD/CMPXCHG
// on bytes and words (XCHG accessed 8 bytes, XADD/CMPXCHG flags came from 32-bit arithmetic).
func TestRegressNarrowOperands(t *testing.T) {
	l := liftBlock(t, "660f42c1") // cmovb ax, cx
	requireInOrder(t, "cmovb ax, cx", l[0], "csel w16, w21, w19, cc", "bfi x19, x16, #0, #16")

	l = liftBlock(t, "99") // cdq
	requireInOrder(t, "cdq", l[0], "asr w22, w19, #31")

	l = liftBlock(t, "8610") // xchg byte [rax], dl
	requireInOrder(t, "xchg byte", l[0], "and w0, w22, #0xff", "ldaxrb w17, [x16]", "stlxrb w1, w0, [x16]", "bfi x22, x17, #0, #8")

	l = liftBlock(t, "0fc008") // xadd byte [rax], cl
	requireInOrder(t, "xadd byte", l[0], "and w2, w21, #0xff", "ldaxrb w17, [x16]", "lsl w3, w17, #24", "adds w3, w3, w2, lsl #24")

	l = liftBlock(t, "660fb108") // cmpxchg word [rax], cx
	requireInOrder(t, "cmpxchg word", l[0], "ldaxrh w17, [x16]", "lsl w0, w19, #16", "cmp w0, w17, lsl #16")
}

// Compare and test flags: (U)COMIS* and FCOMI give ZF = PF = CF = 1 for unordered and SF = 0
// (the lifter used the raw FCMP NZCV), and PTEST leaves C in the subtract sense.
func TestRegressCompareFlags(t *testing.T) {
	l := liftBlock(t, "c5f82ec0") // vucomiss xmm0, xmm0
	requireInOrder(t, "vucomiss", l[0], "fcmp s0, s0", "cset w2, vs", "axflag", "rmif x2, #0, #1")

	l = liftBlock(t, "dbf1") // fcomi st, st(1)
	requireInOrder(t, "fcomi", l[0], "fcmp d0, d1", "axflag")

	// add rax, rbx; vptest xmm0, xmm1; jb: JB reads the C that PTEST wrote (C = !CF).
	l = liftBlock(t, "4801d8", "c4e27917c1", "720e")
	requireInOrder(t, "jb after vptest", l[2], "b.cs ...")
	forbid(t, "jb after vptest", l[2], "cfinv")
}

// YMM upper halves live in v16-v31, which lowerings also use as scratch registers: a scratch
// register must not be the upper half of a source operand.
func TestRegressYmmUpperHalves(t *testing.T) {
	l := liftBlock(t, "c4e37506c220") // vperm2f128 ymm0, ymm1, ymm2, 0x20
	for _, n := range []int{17, 18} { // ymm1, ymm2 upper halves
		if writesVecReg(l[0], n) {
			t.Errorf("vperm2f128 writes v%d (a source's upper half):\n%s", n, strings.Join(l[0], "\n"))
		}
	}
	requireInOrder(t, "vperm2f128", l[0], "mov v16.16b, v19.16b")

	l = liftBlock(t, "c4e27d17c1") // vptest ymm0, ymm1
	for _, n := range []int{16, 17} {
		if writesVecReg(l[0], n) {
			t.Errorf("vptest ymm writes v%d (a source's upper half):\n%s", n, strings.Join(l[0], "\n"))
		}
	}
}

// SSE/AVX semantics: MAX/MIN return the second operand for NaN and signed zeros (ARM FMAX/FMIN
// do not), float->int conversions return 0x80000000 for NaN and out-of-range values, RCPPS needs
// a refinement step for x86 precision, and legacy scalar operations keep the rest of the
// destination register (writing an ARM S/D register clears it).
func TestRegressVectorSemantics(t *testing.T) {
	l := liftBlock(t, "c4c1505ff1") // vmaxps xmm6, xmm5, xmm9
	requireInOrder(t, "vmaxps", l[0], "fcmgt v29.4s, v5.4s, v9.4s", "bsl v29.16b, v5.16b, v9.16b", "mov v6.16b, v29.16b")
	forbid(t, "vmaxps", l[0], "fmax ...")

	l = liftBlock(t, "c5fa2cd0") // vcvttss2si edx, xmm0
	requireInOrder(t, "vcvttss2si", l[0], "fcvtzs w22, s0", "fcmeq s30, s0, s0", "and w2, w2, #0x80000000", "orr w22, w22, w2")

	l = liftBlock(t, "c5f8538de0feffff") // vrcpps xmm1, [rbp-0x120]
	requireInOrder(t, "vrcpps", l[0], "frecpe v27.4s, v24.4s", "frecps v26.4s, v24.4s, v27.4s", "fmul v27.4s, v27.4s, v26.4s")

	l = liftBlock(t, "f30f58c1") // addss xmm0, xmm1
	requireInOrder(t, "addss", l[0], "fadd s31, s0, s1", "mov v0.s[0], v31.s[0]")

	l = liftBlock(t, "f30f5ac1") // cvtss2sd xmm0, xmm1
	requireInOrder(t, "cvtss2sd", l[0], "fcvt d30, s1", "mov v0.d[0], v30.d[0]")
}

// MXCSR lives at GuestContext offset 0x2e8 (0x2ec, which the lifter used, is padding before
// mmx[]), and LDMXCSR/FXRSTOR set the FPCR rounding mode and flush-to-zero bits from it.
func TestRegressMxcsr(t *testing.T) {
	l := liftBlock(t, "0fae55f4") // ldmxcsr [rbp-0xc]
	requireInOrder(t, "ldmxcsr", l[0], "ldr w0, [x28, x16]", "str w0, [x17, #0x2e8]", "mrs x1, fpcr", "ubfx w2, w0, #14, #1", "bfi x1, x2, #22, #1", "msr fpcr, x1")

	l = liftBlock(t, "0fae5df4") // stmxcsr [rbp-0xc]
	requireInOrder(t, "stmxcsr", l[0], "ldr w0, [x17, #0x2e8]", "str w0, [x28, x16]")

	l = liftBlock(t, "0fae08") // fxrstor [rax]
	requireInOrder(t, "fxrstor", l[0], "str w5, [x17, #0x2e8]", "msr fpcr, x1")
}
