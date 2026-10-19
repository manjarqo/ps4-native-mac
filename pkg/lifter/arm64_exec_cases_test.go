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

// String instructions (DF = 0): REP MOVS/STOS run element by element forward, so an overlapping
// forward copy replicates the leading elements; REP MOVS/STOS/LODS keep every flag; REPE/REPNE
// CMPS/SCAS compare at the operand width (SF/OF of a byte compare) and with RCX = 0 leave the
// flags of the previous instruction, in whatever carry sense the lifter tracked them.
func TestExecStringOps(t *testing.T) {
	pattern := make([]byte, 0x100)
	for i := range pattern {
		pattern[i] = byte(i*37 + 0x81)
	}
	const (
		addRaxRbx = "4801d8" // add rax, rbx: CF in the add sense
		cmpRaxRbx = "4839d8" // cmp rax, rbx: CF in the sub sense
		testRax   = "4885c0" // test rax, rax: CF = 0
	)
	src, dst := uint64(execMemBase+0x100), uint64(execMemBase+0x400)
	var cases []execCase
	type sop struct {
		name string
		enc  string
		elem int
	}
	movs := []sop{{"rep movsb", "f3a4", 1}, {"rep movsw", "66f3a5", 2}, {"rep movsd", "f3a5", 4}, {"rep movsq", "f348a5", 8}}
	stos := []sop{{"rep stosb", "f3aa", 1}, {"rep stosw", "66f3ab", 2}, {"rep stosd", "f3ab", 4}, {"rep stosq", "f348ab", 8}}
	preludes := []struct {
		name string
		code []string
	}{{"", nil}, {"add;", []string{addRaxRbx}}, {"cmp;", []string{cmpRaxRbx}}, {"test;", []string{testRax}}}
	for _, p := range preludes {
		for _, fl := range []uint64{0, fCF | fZF | fSF | fOF} {
			// RAX/RBX for the prelude: add carries, cmp borrows.
			regsFor := func(extra map[x86asm.Reg]uint64) map[x86asm.Reg]uint64 {
				r := map[x86asm.Reg]uint64{x86asm.RAX: 0x8000000000000001, x86asm.RBX: 0x8000000000000003}
				for k, v := range extra {
					r[k] = v
				}
				return r
			}
			for _, m := range movs {
				for _, n := range []uint64{0, 1, 7, 33} {
					for _, overlap := range []int{0, 1, m.elem, 3 * m.elem} {
						s, d := src, dst
						if overlap > 0 {
							d = src + uint64(overlap) // forward copy into its own source
						}
						cases = append(cases, execCase{
							name:  fmt.Sprintf("%s %s rcx=%d overlap=%d flags=%#x", p.name, m.name, n, overlap, fl),
							code:  append(append([]string{}, p.code...), m.enc),
							regs:  regsFor(map[x86asm.Reg]uint64{x86asm.RSI: s, x86asm.RDI: d, x86asm.RCX: n}),
							flags: fl,
							mem:   map[int][]byte{0x100: pattern},
						})
					}
				}
			}
			for _, m := range stos {
				for _, n := range []uint64{0, 5} {
					cases = append(cases, execCase{
						name:  fmt.Sprintf("%s %s rcx=%d flags=%#x", p.name, m.name, n, fl),
						code:  append(append([]string{}, p.code...), m.enc),
						regs:  regsFor(map[x86asm.Reg]uint64{x86asm.RDI: dst, x86asm.RCX: n, x86asm.RAX: 0x1122334455667788}),
						flags: fl,
					})
				}
			}
			// CMPS/SCAS. Strings: equal for 5 bytes, then 0x80 vs 0x01 (byte compare: SF/OF).
			a := []byte{1, 2, 3, 4, 5, 0x80, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
			b := []byte{1, 2, 3, 4, 5, 0x01, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
			for _, c := range []struct {
				name string
				enc  string
			}{{"repe cmpsb", "f3a6"}, {"repne cmpsb", "f2a6"}, {"repe cmpsq", "f348a7"}, {"repe cmpsw", "66f3a7"},
				{"repe cmpsd", "f3a7"}, {"cmpsb", "a6"}} {
				for _, n := range []uint64{0, 1, 3, 6, 16} {
					for _, swap := range []bool{false, true} {
						x, y := a, b
						if swap {
							x, y = b, a
						}
						cases = append(cases, execCase{
							name:  fmt.Sprintf("%s %s rcx=%d swap=%v flags=%#x", p.name, c.name, n, swap, fl),
							code:  append(append([]string{}, p.code...), c.enc),
							regs:  regsFor(map[x86asm.Reg]uint64{x86asm.RSI: src, x86asm.RDI: dst, x86asm.RCX: n}),
							flags: fl,
							mem:   map[int][]byte{0x100: x, 0x400: y},
						})
					}
				}
			}
			for _, c := range []struct {
				name string
				enc  string
			}{{"repne scasb", "f2ae"}, {"repe scasb", "f3ae"}, {"repne scasq", "f248af"}, {"scasb", "ae"}} {
				for _, n := range []uint64{0, 1, 6, 16} {
					for _, al := range []uint64{0x1234567800000005, 0xffffff80, 0x01} {
						cases = append(cases, execCase{
							name:  fmt.Sprintf("%s %s rcx=%d rax=%#x flags=%#x", p.name, c.name, n, al, fl),
							code:  append(append([]string{}, p.code...), c.enc),
							regs:  map[x86asm.Reg]uint64{x86asm.RDI: dst, x86asm.RCX: n, x86asm.RAX: al, x86asm.RBX: 3},
							flags: fl,
							mem:   map[int][]byte{0x400: a},
						})
					}
				}
			}
			for _, c := range []struct {
				name string
				enc  string
			}{{"lodsb", "ac"}, {"lodsd", "ad"}, {"lodsq", "48ad"}, {"rep lodsb", "f3ac"}} {
				for _, n := range []uint64{0, 3} {
					cases = append(cases, execCase{
						name:  fmt.Sprintf("%s %s rcx=%d flags=%#x", p.name, c.name, n, fl),
						code:  append(append([]string{}, p.code...), c.enc),
						regs:  regsFor(map[x86asm.Reg]uint64{x86asm.RSI: src, x86asm.RCX: n}),
						flags: fl,
						mem:   map[int][]byte{0x100: pattern},
					})
				}
			}
		}
	}
	runExecCases(t, cases)
}
