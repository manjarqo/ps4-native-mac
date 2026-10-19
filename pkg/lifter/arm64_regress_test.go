package lifter

// Regression tests for the instruction classes that the lifter-difftest-asm harness
// (cmd/lifter-difftest-asm, which runs the lifted code against x86-64 under Rosetta 2) found
// lowered wrongly. Each test checks the property of the lowering that its fix introduced; the
// harness checks the behavior end to end.

import (
	"encoding/hex"
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
