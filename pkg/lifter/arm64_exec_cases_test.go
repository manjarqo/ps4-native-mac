package lifter

import (
	"fmt"
	"testing"

	"golang.org/x/arch/x86/x86asm"
)

// Shifts and rotates by CL and by an immediate: the count is masked to 5 bits (6 for 64-bit
// operands), a masked count of 0 leaves every flag unchanged (and still zero-extends a 32-bit
// register), CF is the last bit shifted out, OF is defined for a count of 1. Flags x86 leaves
// undefined are not compared: OF for counts above 1, and CF of 8/16-bit operations whose count
// exceeds the operand width.
func TestExecShifts(t *testing.T) {
	type form struct {
		name  string
		width int
		cl    string // encoding of OP reg, cl
		imm   string // encoding of OP reg, imm8 (count appended)
	}
	var forms []form
	for _, op := range []struct {
		name  string
		modrm string
	}{{"shl", "e0"}, {"shr", "e8"}, {"sar", "f8"}, {"rol", "c0"}, {"ror", "c8"}, {"rcl", "d0"}, {"rcr", "d8"}} {
		forms = append(forms,
			form{op.name + " al", 8, "d2" + op.modrm, "c0" + op.modrm},
			form{op.name + " ax", 16, "66d3" + op.modrm, "66c1" + op.modrm},
			form{op.name + " eax", 32, "d3" + op.modrm, "c1" + op.modrm},
			form{op.name + " rax", 64, "48d3" + op.modrm, "48c1" + op.modrm},
		)
	}
	values := []uint64{0x8000000180000001, 0x4000000040004041, 0xfffffffffffffffe, 1}
	var cases []execCase
	for _, f := range forms {
		for _, count := range []uint64{0, 1, 2, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 0xff} {
			mask := uint64(0x1f)
			if f.width == 64 {
				mask = 0x3f
			}
			mc := count & mask
			cmp := uint64(readMask)
			if mc != 0 {
				if mc != 1 {
					cmp &^= fOF
				}
				if mc > uint64(f.width) {
					cmp &^= fCF
				}
			}
			for vi, v := range values {
				for _, fl := range []uint64{0, fCF | fZF | fSF | fOF} {
					for _, enc := range []string{f.cl, f.imm + fmt.Sprintf("%02x", count)} {
						kind := "cl"
						if enc != f.cl {
							kind = "imm"
						}
						cases = append(cases, execCase{
							name:     fmt.Sprintf("%s, %s=%d v%d flags=%#x", f.name, kind, count, vi, fl),
							code:     []string{enc},
							regs:     map[x86asm.Reg]uint64{x86asm.RAX: v, x86asm.RCX: 0xabcd00 | count},
							flags:    fl,
							cmpFlags: cmp,
						})
					}
				}
			}
		}
	}
	runExecCases(t, cases)
}
