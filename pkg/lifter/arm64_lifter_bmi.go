package lifter

import (
	"fmt"
	"golang.org/x/arch/x86/x86asm"
	"ps4-recomp/pkg/disasm"
)

// liftBmi handles BMI1 and BMI2 instructions:
// BLSI, BLSR, BLSMSK, BZHI, SHLX, SHRX, SARX, RORX, MULX.
func (l *Arm64Lifter) liftBmi(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	args := inst.Inst.Args

	switch op {
	case x86asm.BLSI, x86asm.BLSR, x86asm.BLSMSK:
		dstReg, okDst := args[0].(x86asm.Reg)
		descDst, okDD := arm64RegMap[dstReg]
		if !okDst || !okDD {
			lines = append(lines, l.emitUnsupported(inst, "unsupported bmi dst")...)
			return lines, nil
		}

		sz := descDst.Size
		if sz == 0 {
			sz = 4
		}

		// Load src into x16 / w16
		if sReg, okS := args[1].(x86asm.Reg); okS {
			rc, _ := readRegTo(sReg, "x16", "w16")
			lines = append(lines, rc...)
		} else if mem, okMem := args[1].(x86asm.Mem); okMem {
			lines = append(lines, readMemTo(mem, nextPC, sz, "x16", "w16")...)
		} else {
			lines = append(lines, l.emitUnsupported(inst, "unsupported bmi src")...)
			return lines, nil
		}

		if sz == 8 {
			switch op {
			case x86asm.BLSI:
				// dst = (-src) & src
				// CF = (src != 0) -> ARM C = (src == 0)
				// ZF = (dst == 0)
				lines = append(lines,
					"    neg x17, x16",
					fmt.Sprintf("    and %s, x16, x17", descDst.X),
					fmt.Sprintf("    cmp %s, #0", descDst.X),
					"    cset w17, eq",
					"    cmp x16, #0",
					"    cset w18, eq",
					"    add w17, w18, w17, lsl #1",
					"    lsl w17, w17, #29",
					"    msr nzcv, x17",
				)
			case x86asm.BLSR:
				// dst = (src - 1) & src
				// CF = (src == 0) -> ARM C = (src != 0)
				// ZF = (dst == 0)
				lines = append(lines,
					"    sub x17, x16, #1",
					fmt.Sprintf("    and %s, x16, x17", descDst.X),
					fmt.Sprintf("    cmp %s, #0", descDst.X),
					"    cset w17, eq",
					"    cmp x16, #0",
					"    cset w18, ne",
					"    add w17, w18, w17, lsl #1",
					"    lsl w17, w17, #29",
					"    msr nzcv, x17",
				)
			case x86asm.BLSMSK:
				// dst = (src - 1) ^ src
				// CF = (src == 0) -> ARM C = (src != 0)
				// ZF = 0
				lines = append(lines,
					"    sub x17, x16, #1",
					fmt.Sprintf("    eor %s, x16, x17", descDst.X),
					"    cmp x16, #0",
					"    cset w18, ne",
					"    lsl w18, w18, #29",
					"    msr nzcv, x18",
				)
			}
		} else {
			switch op {
			case x86asm.BLSI:
				lines = append(lines,
					"    neg w17, w16",
					fmt.Sprintf("    and %s, w16, w17", descDst.W),
					fmt.Sprintf("    cmp %s, #0", descDst.W),
					"    cset w17, eq",
					"    cmp w16, #0",
					"    cset w18, eq",
					"    add w17, w18, w17, lsl #1",
					"    lsl w17, w17, #29",
					"    msr nzcv, x17",
				)
			case x86asm.BLSR:
				lines = append(lines,
					"    sub w17, w16, #1",
					fmt.Sprintf("    and %s, w16, w17", descDst.W),
					fmt.Sprintf("    cmp %s, #0", descDst.W),
					"    cset w17, eq",
					"    cmp w16, #0",
					"    cset w18, ne",
					"    add w17, w18, w17, lsl #1",
					"    lsl w17, w17, #29",
					"    msr nzcv, x17",
				)
			case x86asm.BLSMSK:
				lines = append(lines,
					"    sub w17, w16, #1",
					fmt.Sprintf("    eor %s, w16, w17", descDst.W),
					"    cmp w16, #0",
					"    cset w18, ne",
					"    lsl w18, w18, #29",
					"    msr nzcv, x18",
				)
			}
		}
		return lines, nil

	case x86asm.BZHI:
		// BZHI dst, src, index
		dstReg, okDst := args[0].(x86asm.Reg)
		idxReg, okIdx := args[2].(x86asm.Reg)
		descDst, okDD := arm64RegMap[dstReg]
		descIdx, okIdxD := arm64RegMap[idxReg]
		if !okDst || !okIdx || !okDD || !okIdxD {
			lines = append(lines, l.emitUnsupported(inst, "unsupported bzhi operands")...)
			return lines, nil
		}

		sz := descDst.Size
		if sz == 0 {
			sz = 4
		}

		// Load src into x17 / w17
		if sReg, okS := args[1].(x86asm.Reg); okS {
			rc, _ := readRegTo(sReg, "x17", "w17")
			lines = append(lines, rc...)
		} else if mem, okMem := args[1].(x86asm.Mem); okMem {
			lines = append(lines, readMemTo(mem, nextPC, sz, "x17", "w17")...)
		} else {
			lines = append(lines, l.emitUnsupported(inst, "unsupported bzhi src")...)
			return lines, nil
		}

		l.labelCounter++
		lblPass := fmt.Sprintf("L_bzhi_pass_%d", l.labelCounter)
		lblDone := fmt.Sprintf("L_bzhi_done_%d", l.labelCounter)

		if sz == 8 {
			lines = append(lines,
				fmt.Sprintf("    and w16, %s, #0xff", descIdx.W),
				"    cmp w16, #64",
				fmt.Sprintf("    b.hs %s", lblPass),
				"    mov x18, #1",
				"    lsl x18, x18, x16",
				"    sub x18, x18, #1",
				fmt.Sprintf("    and %s, x17, x18", descDst.X),
				fmt.Sprintf("    b %s", lblDone),
				fmt.Sprintf("%s:", lblPass),
				fmt.Sprintf("    mov %s, x17", descDst.X),
				fmt.Sprintf("%s:", lblDone),
				fmt.Sprintf("    cmp %s, #0", descDst.X),
			)
		} else {
			lines = append(lines,
				fmt.Sprintf("    and w16, %s, #0xff", descIdx.W),
				"    cmp w16, #32",
				fmt.Sprintf("    b.hs %s", lblPass),
				"    mov w18, #1",
				"    lsl w18, w18, w16",
				"    sub w18, w18, #1",
				fmt.Sprintf("    and %s, w17, w18", descDst.W),
				fmt.Sprintf("    b %s", lblDone),
				fmt.Sprintf("%s:", lblPass),
				fmt.Sprintf("    mov %s, w17", descDst.W),
				fmt.Sprintf("%s:", lblDone),
				fmt.Sprintf("    cmp %s, #0", descDst.W),
			)
		}
		return lines, nil

	case x86asm.SHLX, x86asm.SHRX, x86asm.SARX:
		// SHLX/SHRX/SARX dst, src, cnt (does not modify flags!)
		dstReg, okDst := args[0].(x86asm.Reg)
		cntReg, okCnt := args[2].(x86asm.Reg)
		descDst, okDD := arm64RegMap[dstReg]
		descCnt, okCD := arm64RegMap[cntReg]
		if !okDst || !okCnt || !okDD || !okCD {
			lines = append(lines, l.emitUnsupported(inst, "unsupported bmi shift operands")...)
			return lines, nil
		}

		sz := descDst.Size
		if sz == 0 {
			sz = 4
		}

		// Load src into x16 / w16
		if sReg, okS := args[1].(x86asm.Reg); okS {
			rc, _ := readRegTo(sReg, "x16", "w16")
			lines = append(lines, rc...)
		} else if mem, okMem := args[1].(x86asm.Mem); okMem {
			lines = append(lines, readMemTo(mem, nextPC, sz, "x16", "w16")...)
		} else {
			lines = append(lines, l.emitUnsupported(inst, "unsupported bmi shift src")...)
			return lines, nil
		}

		shiftOp := "lsl"
		switch op {
		case x86asm.SHRX:
			shiftOp = "lsr"
		case x86asm.SARX:
			shiftOp = "asr"
		}

		if sz == 8 {
			lines = append(lines,
				fmt.Sprintf("    and x17, %s, #63", descCnt.X),
				fmt.Sprintf("    %s %s, x16, x17", shiftOp, descDst.X),
			)
		} else {
			lines = append(lines,
				fmt.Sprintf("    and w17, %s, #31", descCnt.W),
				fmt.Sprintf("    %s %s, w16, w17", shiftOp, descDst.W),
			)
		}
		return lines, nil

	case x86asm.RORX:
		// RORX dst, src, imm8 (does not modify flags!)
		dstReg, okDst := args[0].(x86asm.Reg)
		imm, okImm := args[2].(x86asm.Imm)
		descDst, okDD := arm64RegMap[dstReg]
		if !okDst || !okImm || !okDD {
			lines = append(lines, l.emitUnsupported(inst, "unsupported rorx operands")...)
			return lines, nil
		}

		sz := descDst.Size
		if sz == 0 {
			sz = 4
		}

		if sReg, okS := args[1].(x86asm.Reg); okS {
			rc, _ := readRegTo(sReg, "x16", "w16")
			lines = append(lines, rc...)
		} else if mem, okMem := args[1].(x86asm.Mem); okMem {
			lines = append(lines, readMemTo(mem, nextPC, sz, "x16", "w16")...)
		} else {
			lines = append(lines, l.emitUnsupported(inst, "unsupported rorx src")...)
			return lines, nil
		}

		rotVal := uint64(imm)
		if sz == 8 {
			rotVal &= 63
			if rotVal == 0 {
				lines = append(lines, fmt.Sprintf("    mov %s, x16", descDst.X))
			} else {
				lines = append(lines, fmt.Sprintf("    ror %s, x16, #%d", descDst.X, rotVal))
			}
		} else {
			rotVal &= 31
			if rotVal == 0 {
				lines = append(lines, fmt.Sprintf("    mov %s, w16", descDst.W))
			} else {
				lines = append(lines, fmt.Sprintf("    ror %s, w16, #%d", descDst.W, rotVal))
			}
		}
		return lines, nil

	case x86asm.MULX:
		// MULX dst_hi, dst_lo, src (unsigned multiply RDX by src without flags)
		dstHiReg, okHi := args[0].(x86asm.Reg)
		dstLoReg, okLo := args[1].(x86asm.Reg)
		descHi, okHiD := arm64RegMap[dstHiReg]
		descLo, okLoD := arm64RegMap[dstLoReg]
		if !okHi || !okLo || !okHiD || !okLoD {
			lines = append(lines, l.emitUnsupported(inst, "unsupported mulx dst")...)
			return lines, nil
		}

		sz := descHi.Size
		if sz == 0 {
			sz = 4
		}

		if sReg, okS := args[2].(x86asm.Reg); okS {
			rc, _ := readRegTo(sReg, "x16", "w16")
			lines = append(lines, rc...)
		} else if mem, okMem := args[2].(x86asm.Mem); okMem {
			lines = append(lines, readMemTo(mem, nextPC, sz, "x16", "w16")...)
		} else {
			lines = append(lines, l.emitUnsupported(inst, "unsupported mulx src")...)
			return lines, nil
		}

		if sz == 8 {
			// RDX is x22
			lines = append(lines,
				fmt.Sprintf("    mul %s, x22, x16", descLo.X),
				fmt.Sprintf("    umulh %s, x22, x16", descHi.X),
			)
		} else {
			lines = append(lines,
				"    umull x17, w22, w16",
				fmt.Sprintf("    mov %s, w17", descLo.W),
				fmt.Sprintf("    lsr %s, x17, #32", descHi.X),
			)
		}
		return lines, nil
	}

	lines = append(lines, l.emitUnsupported(inst, "unsupported bmi op")...)
	return lines, nil
}
