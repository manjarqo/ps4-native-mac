package lifter

import (
	"strings"
	"testing"

	"ps4-recomp/pkg/disasm"

	"golang.org/x/arch/x86/x86asm"
)

func TestSsse3VexOpsLifting(t *testing.T) {
	l := NewLifter(nil)
	fn := &disasm.Function{EntryAddr: 0x1000, Blocks: make(map[uint64]*disasm.BasicBlock)}

	testCases := []struct {
		op       x86asm.Op
		args     x86asm.Args
		contains string
	}{
		{x86asm.VPMULHRSW, x86asm.Args{x86asm.X0, x86asm.X1, x86asm.X2}, ">> 14) + 1) >> 1"},
		{x86asm.VPSIGNB, x86asm.Args{x86asm.X0, x86asm.X1, x86asm.X2}, "res.u8[15]"},
		{x86asm.VPSIGNW, x86asm.Args{x86asm.X0, x86asm.X1, x86asm.Mem{Base: x86asm.RAX}}, "res.u16[7]"},
		{x86asm.VPSIGND, x86asm.Args{x86asm.X3, x86asm.X4, x86asm.X5}, "res.u32[3]"},
		{x86asm.VLDDQU, x86asm.Args{x86asm.X0, x86asm.Mem{Base: x86asm.RSI}}, "ctx->xmm[0], ctx->mem_base"},
	}

	for _, tc := range testCases {
		if !IsOpcodeSupported(tc.op) {
			t.Errorf("%v: not reported as supported", tc.op)
		}
		inst := disasm.Instruction{Address: 0x1000, Inst: x86asm.Inst{Op: tc.op, Args: tc.args, Len: 5}}
		lines, err := l.LiftInstruction(inst, 0x1005, fn)
		if err != nil {
			t.Fatalf("%v: lift failed: %v", tc.op, err)
		}
		code := strings.Join(lines, "\n")
		if !strings.Contains(code, tc.contains) {
			t.Errorf("%v: expected %q in:\n%s", tc.op, tc.contains, code)
		}
		if testing.Verbose() {
			t.Logf("%v:\n%s", tc.op, code)
		}
	}
}
