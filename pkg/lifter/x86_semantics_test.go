package lifter

import (
	"strings"
	"testing"

	"ps4-recomp/pkg/disasm"

	"golang.org/x/arch/x86/x86asm"
)

// Regression tests for semantic bugs found by cmd/lifter-difftest (native vs lifted).
func TestX86SemanticsRegressions(t *testing.T) {
	l := NewLifter(nil)
	fn := &disasm.Function{EntryAddr: 0x1000, Blocks: make(map[uint64]*disasm.BasicBlock)}
	cases := []struct {
		name     string
		op       x86asm.Op
		args     x86asm.Args
		contains []string
		order    []string // must appear in this order
	}{
		{"vmovhlps operand order", x86asm.VMOVHLPS, x86asm.Args{x86asm.X0, x86asm.X3, x86asm.X4},
			[]string{"uint64_t lo = ctx->xmm[4].u64[1]; uint64_t hi = ctx->xmm[3].u64[1];"}, nil},
		{"vcmpss dst aliases src2", x86asm.VCMPSS, x86asm.Args{x86asm.X1, x86asm.X0, x86asm.X1, x86asm.Imm(1)},
			nil, []string{"xmm_reg_t s2 = ctx->xmm[1];", "ctx->xmm[1] = ctx->xmm[0];"}},
		{"cmov r32 zero-extends", x86asm.CMOVNE, x86asm.Args{x86asm.EAX, x86asm.ECX},
			[]string{"} else { ctx->rax = (uint32_t)ctx->rax; }"}, nil},
		{"vex.128 clears upper ymm", x86asm.VSHUFPS, x86asm.Args{x86asm.X2, x86asm.X2, x86asm.X3, x86asm.Imm(0x1b)},
			[]string{"ctx->ymmh[2].u64[0] = 0; ctx->ymmh[2].u64[1] = 0;"}, nil},
		{"maxss returns src2 on NaN", x86asm.VMAXSS, x86asm.Args{x86asm.X0, x86asm.X1, x86asm.X2},
			[]string{"(s1 > s2) ? s1 : s2"}, nil},
		{"cvttss2si indefinite", x86asm.VCVTTSS2SI, x86asm.Args{x86asm.EAX, x86asm.X0},
			[]string{"x86_cvtt_f32_i32("}, nil},
		{"vpsrlq full 64-bit count", x86asm.VPSRLQ, x86asm.Args{x86asm.X6, x86asm.X12, x86asm.X2},
			[]string{"uint64_t shift = (uint64_t)(ctx->xmm[2].u64[0])"}, nil},
	}
	for _, tc := range cases {
		inst := disasm.Instruction{Address: 0x1000, Inst: x86asm.Inst{Op: tc.op, Args: tc.args, Len: 5}}
		lines, err := l.LiftInstruction(inst, 0x1005, fn)
		if err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		code := strings.Join(lines, "\n")
		for _, c := range tc.contains {
			if !strings.Contains(code, c) {
				t.Errorf("%s: expected %q in:\n%s", tc.name, c, code)
			}
		}
		pos := 0
		for _, c := range tc.order {
			i := strings.Index(code[pos:], c)
			if i < 0 {
				t.Errorf("%s: expected %q (in order) in:\n%s", tc.name, c, code)
				break
			}
			pos += i + len(c)
		}
	}
}
