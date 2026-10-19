package lifter

import (
	"fmt"
	"strings"

	"golang.org/x/arch/x86/x86asm"
	"ps4-recomp/pkg/disasm"
)

// liftMov handles MOV operations.
func (l *Arm64Lifter) liftMov(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	// Reg <- Reg
	if dstReg, ok := dst.(x86asm.Reg); ok {
		if srcReg, okSrc := src.(x86asm.Reg); okSrc {
			loadCode, okLoad := readRegTo(srcReg, "x16", "w16")
			storeCode, okStore := writeRegFrom(dstReg, "x16", "w16")
			if okLoad && okStore {
				descDst := arm64RegMap[dstReg]
				descSrc := arm64RegMap[srcReg]
				// Fast path: direct register move when no byte masking needed
				if !descDst.IsHigh8 && !descSrc.IsHigh8 {
					if descDst.Size == 4 && descSrc.Size == 4 {
						lines = append(lines, fmt.Sprintf("    mov %s, %s", descDst.W, descSrc.W))
						return lines, nil
					}
					if descDst.Size == 8 && descSrc.Size == 8 {
						lines = append(lines, fmt.Sprintf("    mov %s, %s", descDst.X, descSrc.X))
						return lines, nil
					}
				}
				lines = append(lines, loadCode...)
				lines = append(lines, storeCode...)
				return lines, nil
			}
		}

		// Reg <- Imm
		if imm, okImm := src.(x86asm.Imm); okImm {
			immCode, ok := loadImmToReg(dstReg, uint64(imm))
			if ok {
				lines = append(lines, immCode...)
				return lines, nil
			}
		}

		// Reg <- Mem
		if mem, okMem := src.(x86asm.Mem); okMem {
			descDst, okDst := arm64RegMap[dstReg]
			if okDst {
				lines = append(lines, readMemTo(mem, nextPC, descDst.Size, "x16", "w16")...)
				storeCode, _ := writeRegFrom(dstReg, "x16", "w16")
				lines = append(lines, storeCode...)
				return lines, nil
			}
		}
	}

	// Mem <- Reg
	if mem, okMem := dst.(x86asm.Mem); okMem {
		if srcReg, okSrc := src.(x86asm.Reg); okSrc {
			descSrc, okDesc := arm64RegMap[srcReg]
			if okDesc {
				loadCode, _ := readRegTo(srcReg, "x17", "w17")
				lines = append(lines, loadCode...)
				lines = append(lines, writeMemFrom(mem, nextPC, descSrc.Size, "x17", "w17")...)
				return lines, nil
			}
		}

		// Mem <- Imm
		if imm, okImm := src.(x86asm.Imm); okImm {
			sz := defMemSz(inst)
			if sz == 8 {
				lines = append(lines, loadImm64("x17", uint64(imm))...)
			} else {
				lines = append(lines, loadImm32("w17", uint32(imm))...)
			}
			lines = append(lines, writeMemFrom(mem, nextPC, sz, "x17", "w17")...)
			return lines, nil
		}
	}

	// Segment register support (CS, DS, ES, SS, FS, GS in x86-64 long mode)
	if dstReg, ok := dst.(x86asm.Reg); ok && isSegmentReg(dstReg) {
		if dstReg == x86asm.FS {
			if srcReg, okSrc := src.(x86asm.Reg); okSrc {
				loadCode, okLoad := readRegTo(srcReg, "x27", "w27")
				if okLoad {
					lines = append(lines, loadCode...)
					return lines, nil
				}
			} else if mem, okMem := src.(x86asm.Mem); okMem {
				lines = append(lines, readMemTo(mem, nextPC, 8, "x27", "w27")...)
				return lines, nil
			}
		}
		// In 64-bit flat mode, CS/DS/ES/SS writes are ignored
		if mem, okMem := src.(x86asm.Mem); okMem {
			lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		}
		return lines, nil
	}
	if srcReg, ok := src.(x86asm.Reg); ok && isSegmentReg(srcReg) {
		if srcReg == x86asm.FS {
			if dstReg, okDst := dst.(x86asm.Reg); okDst {
				storeCode, okStore := writeRegFrom(dstReg, "x27", "w27")
				if okStore {
					lines = append(lines, storeCode...)
					return lines, nil
				}
			} else if mem, okMem := dst.(x86asm.Mem); okMem {
				lines = append(lines, writeMemFrom(mem, nextPC, 8, "x27", "w27")...)
				return lines, nil
			}
		}
		// CS, DS, ES, SS reads return 0
		if dstReg, okDst := dst.(x86asm.Reg); okDst {
			lines = append(lines, loadImm32("w16", 0)...)
			storeCode, okStore := writeRegFrom(dstReg, "x16", "w16")
			if okStore {
				lines = append(lines, storeCode...)
				return lines, nil
			}
		} else if mem, okMem := dst.(x86asm.Mem); okMem {
			lines = append(lines, writeMemFrom(mem, nextPC, 2, "xzr", "wzr")...)
			return lines, nil
		}
	}

	lines = append(lines, "    brk #0 // unsupported mov")
	return lines, nil
}

// liftMovzx handles MOVZX.
func (l *Arm64Lifter) liftMovzx(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	dstReg, okDst := dst.(x86asm.Reg)
	descDst, okDescDst := arm64RegMap[dstReg]
	if !okDst || !okDescDst {
		lines = append(lines, "    brk #0 // unsupported movzx dst")
		return lines, nil
	}

	if srcReg, okSrc := src.(x86asm.Reg); okSrc {
		descSrc, okDescSrc := arm64RegMap[srcReg]
		if okDescSrc {
			if descSrc.IsHigh8 {
				lines = append(lines, fmt.Sprintf("    ubfx %s, %s, #8, #8", descDst.W, descSrc.W))
			} else if descSrc.Size == 1 {
				lines = append(lines, fmt.Sprintf("    uxtb %s, %s", descDst.W, descSrc.W))
			} else {
				lines = append(lines, fmt.Sprintf("    uxth %s, %s", descDst.W, descSrc.W))
			}
			return lines, nil
		}
	}

	if mem, okMem := src.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		sz := defMemSz(inst)
		switch sz {
		case 2:
			lines = append(lines, fmt.Sprintf("    ldrh %s, [x28, x16]", descDst.W))
		case 4:
			lines = append(lines, fmt.Sprintf("    ldr %s, [x28, x16]", descDst.W))
		default:
			lines = append(lines, fmt.Sprintf("    ldrb %s, [x28, x16]", descDst.W))
		}
		return lines, nil
	}

	lines = append(lines, "    brk #0 // unsupported movzx")
	return lines, nil
}

// liftMovsx handles MOVSX and MOVSXD.
func (l *Arm64Lifter) liftMovsx(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	dstReg, okDst := dst.(x86asm.Reg)
	descDst, okDescDst := arm64RegMap[dstReg]
	if !okDst || !okDescDst {
		lines = append(lines, "    brk #0 // unsupported movsx dst")
		return lines, nil
	}

	if srcReg, okSrc := src.(x86asm.Reg); okSrc {
		descSrc, okDescSrc := arm64RegMap[srcReg]
		if okDescSrc {
			if descSrc.Size == 1 {
				if descDst.Size == 8 {
					lines = append(lines, fmt.Sprintf("    sxtb %s, %s", descDst.X, descSrc.W))
				} else {
					lines = append(lines, fmt.Sprintf("    sxtb %s, %s", descDst.W, descSrc.W))
				}
			} else if descSrc.Size == 2 {
				if descDst.Size == 8 {
					lines = append(lines, fmt.Sprintf("    sxth %s, %s", descDst.X, descSrc.W))
				} else {
					lines = append(lines, fmt.Sprintf("    sxth %s, %s", descDst.W, descSrc.W))
				}
			} else if descSrc.Size == 4 {
				lines = append(lines, fmt.Sprintf("    sxtw %s, %s", descDst.X, descSrc.W))
			}
			return lines, nil
		}
	}

	if mem, okMem := src.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		sz := defMemSz(inst)
		if inst.Inst.Op == x86asm.MOVSXD || sz == 4 {
			lines = append(lines, fmt.Sprintf("    ldrsw %s, [x28, x16]", descDst.X))
		} else if sz == 2 {
			if descDst.Size == 8 {
				lines = append(lines, fmt.Sprintf("    ldrsh %s, [x28, x16]", descDst.X))
			} else {
				lines = append(lines, fmt.Sprintf("    ldrsh %s, [x28, x16]", descDst.W))
			}
		} else {
			if descDst.Size == 8 {
				lines = append(lines, fmt.Sprintf("    ldrsb %s, [x28, x16]", descDst.X))
			} else {
				lines = append(lines, fmt.Sprintf("    ldrsb %s, [x28, x16]", descDst.W))
			}
		}
		return lines, nil
	}

	lines = append(lines, "    brk #0 // unsupported movsx")
	return lines, nil
}

// liftAlu handles ADD, SUB, AND, OR, XOR.
func (l *Arm64Lifter) liftAlu(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	return l.liftArith(inst, nextPC, lines)
}

// liftCmpTest handles CMP and TEST.
func (l *Arm64Lifter) liftCmpTest(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	return l.liftArith(inst, nextPC, lines)
}

// arithOperand puts a source operand of an ALU instruction in a register: the pinned register
// itself for 32/64-bit registers, else xT/wT (8/16-bit values zero-extended; a memory operand's
// address goes through x16). An immediate add/sub operand that fits ARM's 12-bit form is
// returned as "#imm".
func arithOperand(arg x86asm.Arg, size int, nextPC uint64, xT, wT string, immOK bool) ([]string, string, bool) {
	switch v := arg.(type) {
	case x86asm.Reg:
		d, ok := arm64RegMap[v]
		if !ok {
			return nil, "", false
		}
		if size == 8 {
			return nil, d.X, true
		}
		if size == 4 {
			return nil, d.W, true
		}
		rc, _ := readRegTo(v, xT, wT)
		return rc, wT, true
	case x86asm.Imm:
		val := uint64(int64(v))
		switch size {
		case 1:
			val &= 0xff
		case 2:
			val &= 0xffff
		case 4:
			val &= 0xffffffff
		}
		if immOK && size >= 4 && val <= 4095 {
			return nil, fmt.Sprintf("#%d", val), true
		}
		if size == 8 {
			return loadImm64(xT, val), xT, true
		}
		return loadImm32(wT, uint32(val)), wT, true
	case x86asm.Mem:
		rd := readMemTo(v, nextPC, size, xT, wT)
		if size == 8 {
			return rd, xT, true
		}
		return rd, wT, true
	}
	return nil, "", false
}

// liftArith lowers ADD, SUB, AND, OR, XOR, CMP and TEST with x86 flags for every operand size.
// 8/16-bit add/sub/cmp run on top-aligned operands (value << (32 - size)) so N, Z, C and V
// come from the narrow result. The carry sense afterwards is carryAdd for ADD, carrySub for
// SUB/CMP and carryClear for the logical operations (ARM ANDS/TST clear C and V).
func (l *Arm64Lifter) liftArith(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]
	flags := !inst.SkipFlags
	compareOnly := op == x86asm.CMP || op == x86asm.TEST
	if compareOnly && !flags {
		return lines, nil // nothing observable
	}

	size := 0
	dstReg, dstIsReg := dst.(x86asm.Reg)
	dstMem, dstIsMem := dst.(x86asm.Mem)
	var desc Arm64RegDesc
	if dstIsReg {
		d, ok := arm64RegMap[dstReg]
		if !ok {
			lines = append(lines, l.emitUnsupported(inst, "unmapped alu dst")...)
			return lines, nil
		}
		desc, size = d, d.Size
	} else if dstIsMem {
		size = defMemSz(inst)
	} else {
		lines = append(lines, l.emitUnsupported(inst, "unsupported alu dst")...)
		return lines, nil
	}

	// a: the destination value (pinned register for 32/64-bit registers, else x17/w17; x16
	// holds a memory destination's address). b: the source (x0/w0 or the pinned register).
	a := ""
	if dstIsMem {
		lines = append(lines, readMemTo(dstMem, nextPC, size, "x17", "w17")...)
		a = "w17"
		if size == 8 {
			a = "x17"
		}
	} else if size >= 4 {
		a = desc.W
		if size == 8 {
			a = desc.X
		}
	} else {
		rc, _ := readRegTo(dstReg, "x17", "w17")
		lines = append(lines, rc...)
		a = "w17"
	}
	isAddSub := op == x86asm.ADD || op == x86asm.SUB || op == x86asm.CMP
	if _, srcIsMem := src.(x86asm.Mem); srcIsMem && dstIsMem {
		lines = append(lines, l.emitUnsupported(inst, "alu mem, mem")...)
		return lines, nil
	}
	bx, bw := "x0", "w0"
	if dstIsReg {
		bx, bw = "x16", "w16" // no address to keep
	}
	rb, b, ok := arithOperand(src, size, nextPC, bx, bw, isAddSub)
	if !ok {
		lines = append(lines, l.emitUnsupported(inst, "unsupported alu src")...)
		return lines, nil
	}
	lines = append(lines, rb...)

	armOp := map[x86asm.Op]string{x86asm.ADD: "add", x86asm.SUB: "sub", x86asm.CMP: "sub",
		x86asm.AND: "and", x86asm.TEST: "and", x86asm.OR: "orr", x86asm.XOR: "eor"}[op]
	logical := !isAddSub

	// res: where the result is computed ("" for CMP/TEST).
	res := a
	if !dstIsMem && size >= 4 {
		res = a
	} else if size < 4 {
		res = "w17"
	}
	if compareOnly {
		res = "wzr"
		if size == 8 {
			res = "xzr"
		}
	}

	if size >= 4 {
		switch {
		case !flags:
			lines = append(lines, fmt.Sprintf("    %s %s, %s, %s", armOp, res, a, b))
		case compareOnly && armOp == "and":
			lines = append(lines, fmt.Sprintf("    tst %s, %s", a, b))
		case compareOnly:
			lines = append(lines, fmt.Sprintf("    cmp %s, %s", a, b))
		case armOp == "and":
			lines = append(lines, fmt.Sprintf("    ands %s, %s, %s", res, a, b))
		case logical: // ORR/EOR have no flag-setting form
			lines = append(lines, fmt.Sprintf("    %s %s, %s, %s", armOp, res, a, b),
				fmt.Sprintf("    tst %s, %s", res, res))
		default:
			lines = append(lines, fmt.Sprintf("    %ss %s, %s, %s", armOp, res, a, b))
		}
	} else {
		sh := 32 - 8*size
		if flags {
			// Top-align both operands: the flags of the 32-bit operation are those of the
			// narrow one; the result is shifted back down.
			lines = append(lines, fmt.Sprintf("    lsl w17, %s, #%d", a, sh))
			if logical {
				if armOp == "and" {
					lines = append(lines, fmt.Sprintf("    ands w17, w17, %s, lsl #%d", b, sh))
				} else {
					lines = append(lines, fmt.Sprintf("    %s w17, w17, %s, lsl #%d", armOp, b, sh),
						"    tst w17, w17")
				}
			} else {
				lines = append(lines, fmt.Sprintf("    %ss w17, w17, %s, lsl #%d", armOp, b, sh))
			}
			if !compareOnly {
				lines = append(lines, fmt.Sprintf("    lsr w17, w17, #%d", sh))
			}
		} else {
			lines = append(lines, fmt.Sprintf("    %s w17, %s, %s", armOp, a, b))
		}
	}
	if flags {
		switch {
		case logical:
			l.cpol = carryClear
		case op == x86asm.ADD:
			l.cpol = carryAdd
		default:
			l.cpol = carrySub
		}
	}
	if compareOnly {
		return lines, nil
	}

	if dstIsMem {
		switch size {
		case 1:
			lines = append(lines, "    strb w17, [x28, x16]")
		case 2:
			lines = append(lines, "    strh w17, [x28, x16]")
		case 4:
			lines = append(lines, "    str w17, [x28, x16]")
		default:
			lines = append(lines, "    str x17, [x28, x16]")
		}
	} else if size < 4 {
		wc, _ := writeRegFrom(dstReg, "x17", "w17")
		lines = append(lines, wc...)
	}
	return lines, nil
}

// unaryOperand loads the operand of a one-operand integer instruction: the pinned register for
// 32/64-bit registers, else x17/w17 (8/16-bit values zero-extended; x16 keeps a memory
// operand's address). store writes a result register back.
func unaryOperand(inst disasm.Instruction, nextPC uint64) (load []string, val string, size int,
	store func(res string) []string, ok bool) {
	switch v := inst.Inst.Args[0].(type) {
	case x86asm.Reg:
		d, okD := arm64RegMap[v]
		if !okD {
			return nil, "", 0, nil, false
		}
		size = d.Size
		if size >= 4 {
			val = d.W
			if size == 8 {
				val = d.X
			}
			return nil, val, size, func(res string) []string {
				if res == val {
					return nil
				}
				return []string{fmt.Sprintf("    mov %s, %s", val, res)}
			}, true
		}
		load, _ = readRegTo(v, "x17", "w17")
		return load, "w17", size, func(res string) []string {
			wc, _ := writeRegFrom(v, "x"+res[1:], res)
			return wc
		}, true
	case x86asm.Mem:
		size = defMemSz(inst)
		load = readMemTo(v, nextPC, size, "x17", "w17")
		val = "w17"
		if size == 8 {
			val = "x17"
		}
		return load, val, size, func(res string) []string {
			switch size {
			case 1:
				return []string{fmt.Sprintf("    strb %s, [x28, x16]", res)}
			case 2:
				return []string{fmt.Sprintf("    strh %s, [x28, x16]", res)}
			}
			return []string{fmt.Sprintf("    str %s, [x28, x16]", res)}
		}, true
	}
	return nil, "", 0, nil, false
}

// liftIncDec handles INC and DEC. They do not change CF: 8/16-bit results set N/Z/V with
// SETF8/SETF16 (which keep C); 32/64-bit ADDS/SUBS are followed by restoring C when CF is live.
func (l *Arm64Lifter) liftIncDec(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	load, val, size, store, ok := unaryOperand(inst, nextPC)
	if !ok {
		lines = append(lines, l.emitUnsupported(inst, "unsupported inc/dec operand")...)
		return lines, nil
	}
	lines = append(lines, load...)
	arith := "add"
	if inst.Inst.Op == x86asm.DEC {
		arith = "sub"
	}
	flags := !inst.SkipFlags
	switch {
	case !flags:
		lines = append(lines, fmt.Sprintf("    %s %s, %s, #1", arith, val, val))
		lines = append(lines, store(val)...)
	case size < 4:
		ext, setf := "sxtb", "setf8"
		if size == 2 {
			ext, setf = "sxth", "setf16"
		}
		lines = append(lines,
			fmt.Sprintf("    %s w3, %s", ext, val),
			fmt.Sprintf("    %s w3, w3, #1", arith),
			fmt.Sprintf("    %s w3", setf))
		lines = append(lines, store("w3")...)
	default:
		keepC := !inst.CarryDead
		if keepC {
			lines = append(lines, "    cset w2, cs")
		}
		lines = append(lines, fmt.Sprintf("    %ss %s, %s, #1", arith, val, val))
		if keepC {
			lines = append(lines, "    rmif x2, #63, #2") // C = bit 0 of x2
		}
		lines = append(lines, store(val)...)
	}
	return lines, nil
}

// liftNegNot handles NEG and NOT. NEGS leaves C = (x == 0) = !CF (carrySub); 8/16-bit NEG runs
// on the top-aligned value so N/Z/C/V are those of the narrow result.
func (l *Arm64Lifter) liftNegNot(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	load, val, size, store, ok := unaryOperand(inst, nextPC)
	if !ok {
		lines = append(lines, l.emitUnsupported(inst, "unsupported neg/not operand")...)
		return lines, nil
	}
	lines = append(lines, load...)
	if inst.Inst.Op == x86asm.NOT {
		lines = append(lines, fmt.Sprintf("    mvn %s, %s", val, val))
		lines = append(lines, store(val)...)
		return lines, nil
	}
	if inst.SkipFlags {
		lines = append(lines, fmt.Sprintf("    neg %s, %s", val, val))
		lines = append(lines, store(val)...)
		return lines, nil
	}
	if size < 4 {
		sh := 32 - 8*size
		lines = append(lines,
			fmt.Sprintf("    lsl w3, %s, #%d", val, sh),
			"    negs w3, w3",
			fmt.Sprintf("    lsr w3, w3, #%d", sh))
		lines = append(lines, store("w3")...)
	} else {
		lines = append(lines, fmt.Sprintf("    negs %s, %s", val, val))
		lines = append(lines, store(val)...)
	}
	l.cpol = carrySub
	return lines, nil
}

// liftShift handles SHL, SHR, SAR, ROL, ROR.
func (l *Arm64Lifter) liftShift(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	dst := inst.Inst.Args[0]
	shiftArg := inst.Inst.Args[1]

	armOp := ""
	switch op {
	case x86asm.SHL:
		armOp = "lsl"
	case x86asm.SHR:
		armOp = "lsr"
	case x86asm.SAR:
		armOp = "asr"
	case x86asm.ROR:
		armOp = "ror"
	case x86asm.ROL:
		// Rotate left can be implemented as ROR with (size - N)
		armOp = "ror"
	}

	updateFlags := !inst.SkipFlags && (op == x86asm.SHL || op == x86asm.SHR || op == x86asm.SAR)

	if reg, ok := dst.(x86asm.Reg); ok {
		if desc, okDesc := arm64RegMap[reg]; okDesc {
			if imm, okImm := shiftArg.(x86asm.Imm); okImm {
				shiftVal := int(imm)
				if desc.Size == 8 {
					shiftVal &= 63
					if op == x86asm.ROL {
						shiftVal = (64 - shiftVal) & 63
					}
					if shiftVal > 0 {
						lines = append(lines, fmt.Sprintf("    %s %s, %s, #%d", armOp, desc.X, desc.X, shiftVal))
						if updateFlags {
							lines = append(lines, fmt.Sprintf("    tst %s, %s", desc.X, desc.X))
						}
					}
					return lines, nil
				} else if desc.Size == 4 {
					shiftVal &= 31
					if op == x86asm.ROL {
						shiftVal = (32 - shiftVal) & 31
					}
					if shiftVal > 0 {
						lines = append(lines, fmt.Sprintf("    %s %s, %s, #%d", armOp, desc.W, desc.W, shiftVal))
						if updateFlags {
							lines = append(lines, fmt.Sprintf("    tst %s, %s", desc.W, desc.W))
						}
					}
					return lines, nil
				} else if desc.Size == 2 && (op == x86asm.ROL || op == x86asm.ROR) {
					shiftVal &= 15
					if op == x86asm.ROL {
						shiftVal = (16 - shiftVal) & 15
					}
					if shiftVal > 0 {
						rc, _ := readRegTo(reg, "x16", "w16")
						lines = append(lines, rc...)
						lines = append(lines, "    orr w16, w16, w16, lsl #16")
						lines = append(lines, fmt.Sprintf("    ror w16, w16, #%d", shiftVal))
						lines = append(lines, "    uxth w16, w16")
						wc, _ := writeRegFrom(reg, "x16", "w16")
						lines = append(lines, wc...)
					}
					return lines, nil
				} else if desc.Size == 1 && (op == x86asm.ROL || op == x86asm.ROR) {
					shiftVal &= 7
					if op == x86asm.ROL {
						shiftVal = (8 - shiftVal) & 7
					}
					if shiftVal > 0 {
						rc, _ := readRegTo(reg, "x16", "w16")
						lines = append(lines, rc...)
						lines = append(lines, "    orr w16, w16, w16, lsl #8")
						lines = append(lines, "    orr w16, w16, w16, lsl #16")
						lines = append(lines, fmt.Sprintf("    ror w16, w16, #%d", shiftVal))
						lines = append(lines, "    uxtb w16, w16")
						wc, _ := writeRegFrom(reg, "x16", "w16")
						lines = append(lines, wc...)
					}
					return lines, nil
				} else {
					// 8-bit or 16-bit SHL/SHR/SAR
					shiftVal &= 31
					rc, _ := readRegTo(reg, "x16", "w16")
					lines = append(lines, rc...)
					if op == x86asm.SAR {
						if desc.Size == 1 {
							lines = append(lines, "    sxtb w16, w16")
						} else if desc.Size == 2 {
							lines = append(lines, "    sxth w16, w16")
						}
					}
					if shiftVal > 0 {
						lines = append(lines, fmt.Sprintf("    %s w16, w16, #%d", armOp, shiftVal))
						if updateFlags {
							if desc.Size == 1 {
								lines = append(lines, "    sxtb w17, w16", "    tst w17, w17")
							} else {
								lines = append(lines, "    sxth w17, w16", "    tst w17, w17")
							}
						}
					}
					wc, _ := writeRegFrom(reg, "x16", "w16")
					lines = append(lines, wc...)
					return lines, nil
				}
			}
			// Variable shift (CL in x21 / w21)
			if desc.Size == 8 {
				if op == x86asm.ROL {
					lines = append(lines, "    neg x16, x21")
					lines = append(lines, fmt.Sprintf("    ror %s, %s, x16", desc.X, desc.X))
				} else {
					lines = append(lines, fmt.Sprintf("    %s %s, %s, x21", armOp, desc.X, desc.X))
					if updateFlags {
						lines = append(lines, fmt.Sprintf("    tst %s, %s", desc.X, desc.X))
					}
				}
			} else if desc.Size == 4 {
				if op == x86asm.ROL {
					lines = append(lines, "    neg w16, w21")
					lines = append(lines, fmt.Sprintf("    ror %s, %s, w16", desc.W, desc.W))
				} else {
					lines = append(lines, fmt.Sprintf("    %s %s, %s, w21", armOp, desc.W, desc.W))
					if updateFlags {
						lines = append(lines, fmt.Sprintf("    tst %s, %s", desc.W, desc.W))
					}
				}
			} else if desc.Size == 2 && (op == x86asm.ROL || op == x86asm.ROR) {
				rc, _ := readRegTo(reg, "x16", "w16")
				lines = append(lines, rc...)
				if op == x86asm.ROL {
					lines = append(lines, "    neg w17, w21")
					lines = append(lines, "    and w17, w17, #15")
				} else {
					lines = append(lines, "    and w17, w21, #15")
				}
				lines = append(lines, "    orr w16, w16, w16, lsl #16")
				lines = append(lines, "    ror w16, w16, w17")
				lines = append(lines, "    uxth w16, w16")
				wc, _ := writeRegFrom(reg, "x16", "w16")
				lines = append(lines, wc...)
			} else if desc.Size == 1 && (op == x86asm.ROL || op == x86asm.ROR) {
				rc, _ := readRegTo(reg, "x16", "w16")
				lines = append(lines, rc...)
				if op == x86asm.ROL {
					lines = append(lines, "    neg w17, w21")
					lines = append(lines, "    and w17, w17, #7")
				} else {
					lines = append(lines, "    and w17, w21, #7")
				}
				lines = append(lines, "    orr w16, w16, w16, lsl #8")
				lines = append(lines, "    orr w16, w16, w16, lsl #16")
				lines = append(lines, "    ror w16, w16, w17")
				lines = append(lines, "    uxtb w16, w16")
				wc, _ := writeRegFrom(reg, "x16", "w16")
				lines = append(lines, wc...)
			} else {
				rc, _ := readRegTo(reg, "x16", "w16")
				lines = append(lines, rc...)
				if op == x86asm.SAR {
					if desc.Size == 1 {
						lines = append(lines, "    sxtb w16, w16")
					} else if desc.Size == 2 {
						lines = append(lines, "    sxth w16, w16")
					}
				}
				lines = append(lines, fmt.Sprintf("    %s w16, w16, w21", armOp))
				if updateFlags {
					if desc.Size == 1 {
						lines = append(lines, "    sxtb w17, w16", "    tst w17, w17")
					} else {
						lines = append(lines, "    sxth w17, w16", "    tst w17, w17")
					}
				}
				wc, _ := writeRegFrom(reg, "x16", "w16")
				lines = append(lines, wc...)
			}
			return lines, nil
		}
	}

	if mem, okMem := dst.(x86asm.Mem); okMem {
		sz := defMemSz(inst)
		lines = append(lines, readMemTo(mem, nextPC, sz, "x17", "w17")...)
		if imm, okImm := shiftArg.(x86asm.Imm); okImm {
			shiftVal := int(imm)
			if sz == 8 {
				shiftVal &= 63
				if op == x86asm.ROL {
					shiftVal = (64 - shiftVal) & 63
				}
				if shiftVal > 0 {
					lines = append(lines, fmt.Sprintf("    %s x17, x17, #%d", armOp, shiftVal))
					if updateFlags {
						lines = append(lines, "    tst x17, x17")
					}
				}
			} else if sz == 4 {
				shiftVal &= 31
				if op == x86asm.ROL {
					shiftVal = (32 - shiftVal) & 31
				}
				if shiftVal > 0 {
					lines = append(lines, fmt.Sprintf("    %s w17, w17, #%d", armOp, shiftVal))
					if updateFlags {
						lines = append(lines, "    tst w17, w17")
					}
				}
			} else if sz == 2 && (op == x86asm.ROL || op == x86asm.ROR) {
				shiftVal &= 15
				if op == x86asm.ROL {
					shiftVal = (16 - shiftVal) & 15
				}
				if shiftVal > 0 {
					lines = append(lines, "    orr w17, w17, w17, lsl #16")
					lines = append(lines, fmt.Sprintf("    ror w17, w17, #%d", shiftVal))
					lines = append(lines, "    uxth w17, w17")
				}
			} else if sz == 1 && (op == x86asm.ROL || op == x86asm.ROR) {
				shiftVal &= 7
				if op == x86asm.ROL {
					shiftVal = (8 - shiftVal) & 7
				}
				if shiftVal > 0 {
					lines = append(lines, "    orr w17, w17, w17, lsl #8")
					lines = append(lines, "    orr w17, w17, w17, lsl #16")
					lines = append(lines, fmt.Sprintf("    ror w17, w17, #%d", shiftVal))
					lines = append(lines, "    uxtb w17, w17")
				}
			} else {
				shiftVal &= 31
				if op == x86asm.SAR {
					if sz == 1 {
						lines = append(lines, "    sxtb w17, w17")
					} else if sz == 2 {
						lines = append(lines, "    sxth w17, w17")
					}
				}
				if shiftVal > 0 {
					lines = append(lines, fmt.Sprintf("    %s w17, w17, #%d", armOp, shiftVal))
					if updateFlags {
						if sz == 1 {
							lines = append(lines, "    sxtb w0, w17", "    tst w0, w0")
						} else {
							lines = append(lines, "    sxth w0, w17", "    tst w0, w0")
						}
					}
				}
			}
		} else {
			// Variable shift (CL in x21 / w21)
			if sz == 8 {
				if op == x86asm.ROL {
					lines = append(lines, "    neg x16, x21")
					lines = append(lines, "    ror x17, x17, x16")
				} else {
					lines = append(lines, fmt.Sprintf("    %s x17, x17, x21", armOp))
					if updateFlags {
						lines = append(lines, "    tst x17, x17")
					}
				}
			} else if sz == 4 {
				if op == x86asm.ROL {
					lines = append(lines, "    neg w16, w21")
					lines = append(lines, "    ror w17, w17, w16")
				} else {
					lines = append(lines, fmt.Sprintf("    %s w17, w17, w21", armOp))
					if updateFlags {
						lines = append(lines, "    tst w17, w17")
					}
				}
			} else if sz == 2 && (op == x86asm.ROL || op == x86asm.ROR) {
				if op == x86asm.ROL {
					lines = append(lines, "    neg w16, w21")
					lines = append(lines, "    and w16, w16, #15")
				} else {
					lines = append(lines, "    and w16, w21, #15")
				}
				lines = append(lines, "    orr w17, w17, w17, lsl #16")
				lines = append(lines, "    ror w17, w17, w16")
				lines = append(lines, "    uxth w17, w17")
			} else if sz == 1 && (op == x86asm.ROL || op == x86asm.ROR) {
				if op == x86asm.ROL {
					lines = append(lines, "    neg w16, w21")
					lines = append(lines, "    and w16, w16, #7")
				} else {
					lines = append(lines, "    and w16, w21, #7")
				}
				lines = append(lines, "    orr w17, w17, w17, lsl #8")
				lines = append(lines, "    orr w17, w17, w17, lsl #16")
				lines = append(lines, "    ror w17, w17, w16")
				lines = append(lines, "    uxtb w17, w17")
			} else {
				if op == x86asm.SAR {
					if sz == 1 {
						lines = append(lines, "    sxtb w17, w17")
					} else if sz == 2 {
						lines = append(lines, "    sxth w17, w17")
					}
				}
				lines = append(lines, fmt.Sprintf("    %s w17, w17, w21", armOp))
				if updateFlags {
					if sz == 1 {
						lines = append(lines, "    sxtb w0, w17", "    tst w0, w0")
					} else {
						lines = append(lines, "    sxth w0, w17", "    tst w0, w0")
					}
				}
			}
		}
		lines = append(lines, writeMemFrom(mem, nextPC, sz, "x17", "w17")...)
		return lines, nil
	}

	lines = append(lines, l.emitUnsupported(inst, fmt.Sprintf("unsupported %s", strings.ToLower(op.String())))...)
	return lines, nil
}

// liftImul handles IMUL.
func (l *Arm64Lifter) liftImul(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	args := inst.Inst.Args
	// 2-operand form: IMUL dst, src
	if args[0] != nil && args[1] != nil && args[2] == nil {
		dstReg, okDst := args[0].(x86asm.Reg)
		descDst, okDescDst := arm64RegMap[dstReg]
		if okDst && okDescDst {
			if srcReg, okSrc := args[1].(x86asm.Reg); okSrc {
				if descSrc, okDescSrc := arm64RegMap[srcReg]; okDescSrc {
					if descDst.Size == 4 {
						lines = append(lines, fmt.Sprintf("    mul %s, %s, %s", descDst.W, descDst.W, descSrc.W))
					} else {
						lines = append(lines, fmt.Sprintf("    mul %s, %s, %s", descDst.X, descDst.X, descSrc.X))
					}
					return lines, nil
				}
			}
			if mem, okMem := args[1].(x86asm.Mem); okMem {
				lines = append(lines, readMemTo(mem, nextPC, descDst.Size, "x16", "w16")...)
				if descDst.Size == 4 {
					lines = append(lines, fmt.Sprintf("    mul %s, %s, w16", descDst.W, descDst.W))
				} else {
					lines = append(lines, fmt.Sprintf("    mul %s, %s, x16", descDst.X, descDst.X))
				}
				return lines, nil
			}
		}
	}
	// 3-operand form: IMUL dst, src, imm
	if args[0] != nil && args[1] != nil && args[2] != nil {
		dstReg, okDst := args[0].(x86asm.Reg)
		imm, okImm := args[2].(x86asm.Imm)
		descDst, okDescDst := arm64RegMap[dstReg]
		if okDst && okImm && okDescDst {
			if srcReg, okSrc := args[1].(x86asm.Reg); okSrc {
				if descSrc, okDescSrc := arm64RegMap[srcReg]; okDescSrc {
					lines = append(lines, loadImm32("w16", uint32(imm))...)
					if descDst.Size == 4 {
						lines = append(lines, fmt.Sprintf("    mul %s, %s, w16", descDst.W, descSrc.W))
					} else {
						lines = append(lines, fmt.Sprintf("    mul %s, %s, x16", descDst.X, descSrc.X))
					}
					return lines, nil
				}
			} else if mem, okMem := args[1].(x86asm.Mem); okMem {
				lines = append(lines, readMemTo(mem, nextPC, descDst.Size, "x17", "w17")...)
				lines = append(lines, loadImm32("w16", uint32(imm))...)
				if descDst.Size == 4 {
					lines = append(lines, fmt.Sprintf("    mul %s, w17, w16", descDst.W))
				} else {
					lines = append(lines, fmt.Sprintf("    mul %s, x17, x16", descDst.X))
				}
				return lines, nil
			}
		}
	}
	// 1-operand form: IMUL src (RAX * src -> RDX:RAX)
	if args[0] != nil && args[1] == nil {
		if reg, ok := args[0].(x86asm.Reg); ok {
			if desc, okDesc := arm64RegMap[reg]; okDesc {
				switch desc.Size {
				case 1:
					rc, _ := readRegTo(reg, "x16", "w16")
					lines = append(lines, rc...)
					lines = append(lines, "    sxtb w16, w16")
					lines = append(lines, "    sxtb w17, w19")
					lines = append(lines, "    mul w16, w17, w16")
					lines = append(lines, "    bfi x19, x16, #0, #16")
				case 2:
					rc, _ := readRegTo(reg, "x16", "w16")
					lines = append(lines, rc...)
					lines = append(lines, "    sxth w16, w16")
					lines = append(lines, "    sxth w17, w19")
					lines = append(lines, "    mul w16, w17, w16")
					lines = append(lines, "    bfi x19, x16, #0, #16")
					lines = append(lines, "    lsr w17, w16, #16")
					lines = append(lines, "    bfi x22, x17, #0, #16")
				case 4:
					lines = append(lines, fmt.Sprintf("    smull x16, w19, %s", desc.W))
					lines = append(lines, "    mov w19, w16")
					lines = append(lines, "    lsr x22, x16, #32")
				default: // 8
					lines = append(lines, fmt.Sprintf("    mul x16, x19, %s", desc.X))
					lines = append(lines, fmt.Sprintf("    smulh x22, x19, %s", desc.X))
					lines = append(lines, "    mov x19, x16")
				}
				return lines, nil
			}
		} else if mem, ok := args[0].(x86asm.Mem); ok {
			sz := defMemSz(inst)
			lines = append(lines, readMemTo(mem, nextPC, sz, "x17", "w17")...)
			switch sz {
			case 1:
				lines = append(lines, "    sxtb w17, w17")
				lines = append(lines, "    sxtb w16, w19")
				lines = append(lines, "    mul w16, w16, w17")
				lines = append(lines, "    bfi x19, x16, #0, #16")
			case 2:
				lines = append(lines, "    sxth w17, w17")
				lines = append(lines, "    sxth w16, w19")
				lines = append(lines, "    mul w16, w16, w17")
				lines = append(lines, "    bfi x19, x16, #0, #16")
				lines = append(lines, "    lsr w17, w16, #16")
				lines = append(lines, "    bfi x22, x17, #0, #16")
			case 4:
				lines = append(lines, "    smull x16, w19, w17")
				lines = append(lines, "    mov w19, w16")
				lines = append(lines, "    lsr x22, x16, #32")
			default: // 8
				lines = append(lines, "    mul x16, x19, x17")
				lines = append(lines, "    smulh x22, x19, x17")
				lines = append(lines, "    mov x19, x16")
			}
			return lines, nil
		}
	}

	lines = append(lines, "    brk #0 // unsupported imul")
	return lines, nil
}

// liftMul handles unsigned MUL.
func (l *Arm64Lifter) liftMul(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	if reg, ok := inst.Inst.Args[0].(x86asm.Reg); ok {
		if desc, okDesc := arm64RegMap[reg]; okDesc {
			switch desc.Size {
			case 1:
				rc, _ := readRegTo(reg, "x16", "w16")
				lines = append(lines, rc...)
				lines = append(lines, "    and w17, w19, #0xff")
				lines = append(lines, "    mul w16, w17, w16")
				lines = append(lines, "    bfi x19, x16, #0, #16")
			case 2:
				rc, _ := readRegTo(reg, "x16", "w16")
				lines = append(lines, rc...)
				lines = append(lines, "    and w17, w19, #0xffff")
				lines = append(lines, "    mul w16, w17, w16")
				lines = append(lines, "    bfi x19, x16, #0, #16")
				lines = append(lines, "    lsr w17, w16, #16")
				lines = append(lines, "    bfi x22, x17, #0, #16")
			case 4:
				lines = append(lines, fmt.Sprintf("    umull x16, w19, %s", desc.W))
				lines = append(lines, "    mov w19, w16")
				lines = append(lines, "    lsr x22, x16, #32")
			default: // 8
				lines = append(lines, fmt.Sprintf("    mul x16, x19, %s", desc.X))
				lines = append(lines, fmt.Sprintf("    umulh x22, x19, %s", desc.X))
				lines = append(lines, "    mov x19, x16")
			}
			return lines, nil
		}
	} else if mem, ok := inst.Inst.Args[0].(x86asm.Mem); ok {
		sz := defMemSz(inst)
		lines = append(lines, readMemTo(mem, nextPC, sz, "x17", "w17")...)
		switch sz {
		case 1:
			lines = append(lines, "    and w16, w19, #0xff")
			lines = append(lines, "    mul w16, w16, w17")
			lines = append(lines, "    bfi x19, x16, #0, #16")
		case 2:
			lines = append(lines, "    and w16, w19, #0xffff")
			lines = append(lines, "    mul w16, w16, w17")
			lines = append(lines, "    bfi x19, x16, #0, #16")
			lines = append(lines, "    lsr w17, w16, #16")
			lines = append(lines, "    bfi x22, x17, #0, #16")
		case 4:
			lines = append(lines, "    umull x16, w19, w17")
			lines = append(lines, "    mov w19, w16")
			lines = append(lines, "    lsr x22, x16, #32")
		default: // 8
			lines = append(lines, "    mul x16, x19, x17")
			lines = append(lines, "    umulh x22, x19, x17")
			lines = append(lines, "    mov x19, x16")
		}
		return lines, nil
	}
	lines = append(lines, "    brk #0 // unsupported mul")
	return lines, nil
}

// liftDiv handles IDIV and DIV.
func (l *Arm64Lifter) liftDiv(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	isSigned := inst.Inst.Op == x86asm.IDIV
	divOp := "udiv"
	if isSigned {
		divOp = "sdiv"
	}

	if reg, ok := inst.Inst.Args[0].(x86asm.Reg); ok {
		if desc, okDesc := arm64RegMap[reg]; okDesc {
			switch desc.Size {
			case 1:
				rc, _ := readRegTo(reg, "x17", "w17")
				lines = append(lines, rc...)
				if isSigned {
					lines = append(lines, "    sxth w16, w19")
					lines = append(lines, "    sxtb w17, w17")
				} else {
					lines = append(lines, "    uxth w16, w19")
				}
				lines = append(lines, fmt.Sprintf("    %s w0, w16, w17", divOp))
				lines = append(lines, "    msub w1, w0, w17, w16")
				lines = append(lines, "    bfi x19, x0, #0, #8")
				lines = append(lines, "    bfi x19, x1, #8, #8")
			case 2:
				rc, _ := readRegTo(reg, "x17", "w17")
				lines = append(lines, rc...)
				lines = append(lines, "    and w16, w19, #0xffff")
				lines = append(lines, "    bfi w16, w22, #16, #16")
				if isSigned {
					lines = append(lines, "    sxth w17, w17")
				}
				lines = append(lines, fmt.Sprintf("    %s w0, w16, w17", divOp))
				lines = append(lines, "    msub w1, w0, w17, w16")
				lines = append(lines, "    bfi x19, x0, #0, #16")
				lines = append(lines, "    bfi x22, x1, #0, #16")
			case 4:
				lines = append(lines, fmt.Sprintf("    %s w16, w19, %s", divOp, desc.W))
				lines = append(lines, fmt.Sprintf("    msub w22, w16, %s, w19", desc.W))
				lines = append(lines, "    mov w19, w16")
			default: // 8
				lines = append(lines, fmt.Sprintf("    %s x16, x19, %s", divOp, desc.X))
				lines = append(lines, fmt.Sprintf("    msub x22, x16, %s, x19", desc.X))
				lines = append(lines, "    mov x19, x16")
			}
			return lines, nil
		}
	} else if mem, ok := inst.Inst.Args[0].(x86asm.Mem); ok {
		sz := defMemSz(inst)
		lines = append(lines, readMemTo(mem, nextPC, sz, "x17", "w17")...)
		switch sz {
		case 1:
			if isSigned {
				lines = append(lines, "    sxth w16, w19")
				lines = append(lines, "    sxtb w17, w17")
			} else {
				lines = append(lines, "    uxth w16, w19")
			}
			lines = append(lines, fmt.Sprintf("    %s w0, w16, w17", divOp))
			lines = append(lines, "    msub w1, w0, w17, w16")
			lines = append(lines, "    bfi x19, x0, #0, #8")
			lines = append(lines, "    bfi x19, x1, #8, #8")
		case 2:
			lines = append(lines, "    and w16, w19, #0xffff")
			lines = append(lines, "    bfi w16, w22, #16, #16")
			if isSigned {
				lines = append(lines, "    sxth w17, w17")
			}
			lines = append(lines, fmt.Sprintf("    %s w0, w16, w17", divOp))
			lines = append(lines, "    msub w1, w0, w17, w16")
			lines = append(lines, "    bfi x19, x0, #0, #16")
			lines = append(lines, "    bfi x22, x1, #0, #16")
		case 4:
			lines = append(lines, fmt.Sprintf("    %s w16, w19, w17", divOp))
			lines = append(lines, "    msub w22, w16, w17, w19")
			lines = append(lines, "    mov w19, w16")
		default: // 8
			lines = append(lines, fmt.Sprintf("    %s x16, x19, x17", divOp))
			lines = append(lines, "    msub x22, x16, x17, x19")
			lines = append(lines, "    mov x19, x16")
		}
		return lines, nil
	}
	lines = append(lines, "    brk #0 // unsupported div")
	return lines, nil
}

// liftXadd handles atomic/non-atomic XADD instruction.
func (l *Arm64Lifter) liftXadd(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]
	sz := defMemSz(inst)

	srcReg, okSrc := src.(x86asm.Reg)
	if !okSrc {
		lines = append(lines, "    brk #0 // unsupported xadd src")
		return lines, nil
	}
	srcDesc, okSrcDesc := arm64RegMap[srcReg]
	if !okSrcDesc {
		lines = append(lines, "    brk #0 // unmapped xadd src")
		return lines, nil
	}
	if srcDesc.Size > 0 {
		sz = srcDesc.Size
	}

	l.labelCounter++
	if mem, okMem := dst.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		lines = append(lines, "    add x16, x28, x16")
		loopLbl := fmt.Sprintf("L_xadd_loop_%d", l.labelCounter)

		lines = append(lines, fmt.Sprintf("%s:", loopLbl))
		switch sz {
		case 1:
			lines = append(lines, "    ldaxrb w17, [x16]")
			lines = append(lines, fmt.Sprintf("    add w0, w17, %s", srcDesc.W))
			lines = append(lines, "    stlxrb w1, w0, [x16]")
			lines = append(lines, fmt.Sprintf("    cbnz w1, %s", loopLbl))
			lines = append(lines, fmt.Sprintf("    adds w0, w17, %s", srcDesc.W))
			lines = append(lines, fmt.Sprintf("    bfi %s, x17, #0, #8", srcDesc.X))
		case 2:
			lines = append(lines, "    ldaxrh w17, [x16]")
			lines = append(lines, fmt.Sprintf("    add w0, w17, %s", srcDesc.W))
			lines = append(lines, "    stlxrh w1, w0, [x16]")
			lines = append(lines, fmt.Sprintf("    cbnz w1, %s", loopLbl))
			lines = append(lines, fmt.Sprintf("    adds w0, w17, %s", srcDesc.W))
			lines = append(lines, fmt.Sprintf("    bfi %s, x17, #0, #16", srcDesc.X))
		case 4:
			lines = append(lines, "    ldaxr w17, [x16]")
			lines = append(lines, fmt.Sprintf("    add w0, w17, %s", srcDesc.W))
			lines = append(lines, "    stlxr w1, w0, [x16]")
			lines = append(lines, fmt.Sprintf("    cbnz w1, %s", loopLbl))
			lines = append(lines, fmt.Sprintf("    adds w0, w17, %s", srcDesc.W))
			lines = append(lines, fmt.Sprintf("    mov %s, w17", srcDesc.W))
		default: // 8
			lines = append(lines, "    ldaxr x17, [x16]")
			lines = append(lines, fmt.Sprintf("    add x0, x17, %s", srcDesc.X))
			lines = append(lines, "    stlxr w1, x0, [x16]")
			lines = append(lines, fmt.Sprintf("    cbnz w1, %s", loopLbl))
			lines = append(lines, fmt.Sprintf("    adds x0, x17, %s", srcDesc.X))
			lines = append(lines, fmt.Sprintf("    mov %s, x17", srcDesc.X))
		}
		return lines, nil
	}

	if dstReg, okDst := dst.(x86asm.Reg); okDst {
		if dstDesc, okDstDesc := arm64RegMap[dstReg]; okDstDesc {
			switch sz {
			case 1:
				lines = append(lines, fmt.Sprintf("    add w0, %s, %s", dstDesc.W, srcDesc.W))
				lines = append(lines, fmt.Sprintf("    adds w1, %s, %s", dstDesc.W, srcDesc.W))
				lines = append(lines, fmt.Sprintf("    mov w16, %s", dstDesc.W))
				lines = append(lines, fmt.Sprintf("    bfi %s, x16, #0, #8", srcDesc.X))
				lines = append(lines, fmt.Sprintf("    bfi %s, x0, #0, #8", dstDesc.X))
			case 2:
				lines = append(lines, fmt.Sprintf("    add w0, %s, %s", dstDesc.W, srcDesc.W))
				lines = append(lines, fmt.Sprintf("    adds w1, %s, %s", dstDesc.W, srcDesc.W))
				lines = append(lines, fmt.Sprintf("    mov w16, %s", dstDesc.W))
				lines = append(lines, fmt.Sprintf("    bfi %s, x16, #0, #16", srcDesc.X))
				lines = append(lines, fmt.Sprintf("    bfi %s, x0, #0, #16", dstDesc.X))
			case 4:
				lines = append(lines, fmt.Sprintf("    add w0, %s, %s", dstDesc.W, srcDesc.W))
				lines = append(lines, fmt.Sprintf("    adds w1, %s, %s", dstDesc.W, srcDesc.W))
				lines = append(lines, fmt.Sprintf("    mov %s, %s", srcDesc.W, dstDesc.W))
				lines = append(lines, fmt.Sprintf("    mov %s, w0", dstDesc.W))
			default:
				lines = append(lines, fmt.Sprintf("    add x0, %s, %s", dstDesc.X, srcDesc.X))
				lines = append(lines, fmt.Sprintf("    adds x1, %s, %s", dstDesc.X, srcDesc.X))
				lines = append(lines, fmt.Sprintf("    mov %s, %s", srcDesc.X, dstDesc.X))
				lines = append(lines, fmt.Sprintf("    mov %s, x0", dstDesc.X))
			}
			return lines, nil
		}
	}

	lines = append(lines, "    brk #0 // unsupported xadd")
	return lines, nil
}

// liftCmpxchg handles CMPXCHG instruction.
func (l *Arm64Lifter) liftCmpxchg(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]
	sz := defMemSz(inst)

	srcReg, okSrc := src.(x86asm.Reg)
	if !okSrc {
		lines = append(lines, "    brk #0 // unsupported cmpxchg src")
		return lines, nil
	}
	srcDesc, okSrcDesc := arm64RegMap[srcReg]
	if !okSrcDesc {
		lines = append(lines, "    brk #0 // unmapped cmpxchg src")
		return lines, nil
	}
	if srcDesc.Size > 0 {
		sz = srcDesc.Size
	}

	l.labelCounter++
	loopLbl := fmt.Sprintf("L_cmpxchg_loop_%d", l.labelCounter)
	failLbl := fmt.Sprintf("L_cmpxchg_fail_%d", l.labelCounter)
	endLbl := fmt.Sprintf("L_cmpxchg_end_%d", l.labelCounter)

	// Accumulator is RAX / EAX / AX / AL (mapped to x19)
	if mem, okMem := dst.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		lines = append(lines, "    add x16, x28, x16")
		lines = append(lines, fmt.Sprintf("%s:", loopLbl))
		switch sz {
		case 1:
			lines = append(lines, "    ldaxrb w17, [x16]")
			lines = append(lines, "    and w0, w19, #0xff")
			lines = append(lines, "    cmp w0, w17")
			lines = append(lines, fmt.Sprintf("    b.ne %s", failLbl))
			lines = append(lines, fmt.Sprintf("    stlxrb w1, %s, [x16]", srcDesc.W))
			lines = append(lines, fmt.Sprintf("    cbnz w1, %s", loopLbl))
			lines = append(lines, fmt.Sprintf("    b %s", endLbl))
			lines = append(lines, fmt.Sprintf("%s:", failLbl))
			lines = append(lines, "    clrex")
			lines = append(lines, "    bfi x19, x17, #0, #8")
			lines = append(lines, fmt.Sprintf("%s:", endLbl))
		case 2:
			lines = append(lines, "    ldaxrh w17, [x16]")
			lines = append(lines, "    and w0, w19, #0xffff")
			lines = append(lines, "    cmp w0, w17")
			lines = append(lines, fmt.Sprintf("    b.ne %s", failLbl))
			lines = append(lines, fmt.Sprintf("    stlxrh w1, %s, [x16]", srcDesc.W))
			lines = append(lines, fmt.Sprintf("    cbnz w1, %s", loopLbl))
			lines = append(lines, fmt.Sprintf("    b %s", endLbl))
			lines = append(lines, fmt.Sprintf("%s:", failLbl))
			lines = append(lines, "    clrex")
			lines = append(lines, "    bfi x19, x17, #0, #16")
			lines = append(lines, fmt.Sprintf("%s:", endLbl))
		case 4:
			lines = append(lines, "    ldaxr w17, [x16]")
			lines = append(lines, "    cmp w19, w17")
			lines = append(lines, fmt.Sprintf("    b.ne %s", failLbl))
			lines = append(lines, fmt.Sprintf("    stlxr w1, %s, [x16]", srcDesc.W))
			lines = append(lines, fmt.Sprintf("    cbnz w1, %s", loopLbl))
			lines = append(lines, fmt.Sprintf("    b %s", endLbl))
			lines = append(lines, fmt.Sprintf("%s:", failLbl))
			lines = append(lines, "    clrex")
			lines = append(lines, "    mov w19, w17")
			lines = append(lines, fmt.Sprintf("%s:", endLbl))
		default: // 8
			lines = append(lines, "    ldaxr x17, [x16]")
			lines = append(lines, "    cmp x19, x17")
			lines = append(lines, fmt.Sprintf("    b.ne %s", failLbl))
			lines = append(lines, fmt.Sprintf("    stlxr w1, %s, [x16]", srcDesc.X))
			lines = append(lines, fmt.Sprintf("    cbnz w1, %s", loopLbl))
			lines = append(lines, fmt.Sprintf("    b %s", endLbl))
			lines = append(lines, fmt.Sprintf("%s:", failLbl))
			lines = append(lines, "    clrex")
			lines = append(lines, "    mov x19, x17")
			lines = append(lines, fmt.Sprintf("%s:", endLbl))
		}
		return lines, nil
	}

	if dstReg, okDst := dst.(x86asm.Reg); okDst {
		if dstDesc, okDstDesc := arm64RegMap[dstReg]; okDstDesc {
			switch sz {
			case 1:
				lines = append(lines, "    and w0, w19, #0xff")
				lines = append(lines, fmt.Sprintf("    and w1, %s, #0xff", dstDesc.W))
				lines = append(lines, "    cmp w0, w1")
				lines = append(lines, fmt.Sprintf("    b.ne %s", failLbl))
				lines = append(lines, fmt.Sprintf("    bfi %s, %s, #0, #8", dstDesc.X, srcDesc.X))
				lines = append(lines, fmt.Sprintf("    b %s", endLbl))
				lines = append(lines, fmt.Sprintf("%s:", failLbl))
				lines = append(lines, fmt.Sprintf("    bfi x19, %s, #0, #8", dstDesc.X))
				lines = append(lines, fmt.Sprintf("%s:", endLbl))
			case 2:
				lines = append(lines, "    and w0, w19, #0xffff")
				lines = append(lines, fmt.Sprintf("    and w1, %s, #0xffff", dstDesc.W))
				lines = append(lines, "    cmp w0, w1")
				lines = append(lines, fmt.Sprintf("    b.ne %s", failLbl))
				lines = append(lines, fmt.Sprintf("    bfi %s, %s, #0, #16", dstDesc.X, srcDesc.X))
				lines = append(lines, fmt.Sprintf("    b %s", endLbl))
				lines = append(lines, fmt.Sprintf("%s:", failLbl))
				lines = append(lines, fmt.Sprintf("    bfi x19, %s, #0, #16", dstDesc.X))
				lines = append(lines, fmt.Sprintf("%s:", endLbl))
			case 4:
				lines = append(lines, fmt.Sprintf("    cmp w19, %s", dstDesc.W))
				lines = append(lines, fmt.Sprintf("    b.ne %s", failLbl))
				lines = append(lines, fmt.Sprintf("    mov %s, %s", dstDesc.W, srcDesc.W))
				lines = append(lines, fmt.Sprintf("    b %s", endLbl))
				lines = append(lines, fmt.Sprintf("%s:", failLbl))
				lines = append(lines, fmt.Sprintf("    mov w19, %s", dstDesc.W))
				lines = append(lines, fmt.Sprintf("%s:", endLbl))
			default:
				lines = append(lines, fmt.Sprintf("    cmp x19, %s", dstDesc.X))
				lines = append(lines, fmt.Sprintf("    b.ne %s", failLbl))
				lines = append(lines, fmt.Sprintf("    mov %s, %s", dstDesc.X, srcDesc.X))
				lines = append(lines, fmt.Sprintf("    b %s", endLbl))
				lines = append(lines, fmt.Sprintf("%s:", failLbl))
				lines = append(lines, fmt.Sprintf("    mov x19, %s", dstDesc.X))
				lines = append(lines, fmt.Sprintf("%s:", endLbl))
			}
			return lines, nil
		}
	}

	lines = append(lines, "    brk #0 // unsupported cmpxchg")
	return lines, nil
}

// liftXchg handles XCHG instruction.
func (l *Arm64Lifter) liftXchg(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]
	sz := defMemSz(inst)

	// Reg <-> Reg
	if dstReg, okDst := dst.(x86asm.Reg); okDst {
		if srcReg, okSrc := src.(x86asm.Reg); okSrc {
			dDesc := arm64RegMap[dstReg]
			sDesc := arm64RegMap[srcReg]
			if dDesc.Size == 4 {
				lines = append(lines, fmt.Sprintf("    mov w16, %s", dDesc.W))
				lines = append(lines, fmt.Sprintf("    mov %s, %s", dDesc.W, sDesc.W))
				lines = append(lines, fmt.Sprintf("    mov %s, w16", sDesc.W))
			} else {
				lines = append(lines, fmt.Sprintf("    mov x16, %s", dDesc.X))
				lines = append(lines, fmt.Sprintf("    mov %s, %s", dDesc.X, sDesc.X))
				lines = append(lines, fmt.Sprintf("    mov %s, x16", sDesc.X))
			}
			return lines, nil
		}
	}

	// Mem <-> Reg
	if mem, okMem := dst.(x86asm.Mem); okMem {
		if srcReg, okSrc := src.(x86asm.Reg); okSrc {
			sDesc := arm64RegMap[srcReg]
			l.labelCounter++
			loopLbl := fmt.Sprintf("L_xchg_loop_%d", l.labelCounter)
			lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
			lines = append(lines, "    add x16, x28, x16")
			lines = append(lines, fmt.Sprintf("%s:", loopLbl))
			if sz == 4 {
				lines = append(lines, "    ldaxr w17, [x16]")
				lines = append(lines, fmt.Sprintf("    stlxr w1, %s, [x16]", sDesc.W))
				lines = append(lines, fmt.Sprintf("    cbnz w1, %s", loopLbl))
				lines = append(lines, fmt.Sprintf("    mov %s, w17", sDesc.W))
			} else {
				lines = append(lines, "    ldaxr x17, [x16]")
				lines = append(lines, fmt.Sprintf("    stlxr w1, %s, [x16]", sDesc.X))
				lines = append(lines, fmt.Sprintf("    cbnz w1, %s", loopLbl))
				lines = append(lines, fmt.Sprintf("    mov %s, x17", sDesc.X))
			}
			return lines, nil
		}
	}

	lines = append(lines, l.emitUnsupported(inst, "unsupported xchg")...)
	return lines, nil
}

// liftAdcSbb handles ADC and SBB.
//
// 32/64-bit: ADCS needs C = CF and SBCS needs C = !CF, so C is inverted first when the tracked
// sense differs; the result sense is then carryAdd (ADC) or carrySub (SBB).
// 8/16-bit: ADCS/SBCS cannot add the carry at the bottom of top-aligned operands, so the
// result and N/Z/V come from sign-extended operands (SETF8/SETF16, which keep C) and CF from
// the zero-extended sum, inserted into C with RMIF.
func (l *Arm64Lifter) liftAdcSbb(inst disasm.Instruction, nextPC uint64, isSbb bool, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]
	flags := !inst.SkipFlags

	size := 0
	dstReg, dstIsReg := dst.(x86asm.Reg)
	dstMem, dstIsMem := dst.(x86asm.Mem)
	if dstIsReg {
		d, ok := arm64RegMap[dstReg]
		if !ok {
			lines = append(lines, l.emitUnsupported(inst, "unmapped adc/sbb dst")...)
			return lines, nil
		}
		size = d.Size
	} else if dstIsMem {
		size = defMemSz(inst)
	} else {
		lines = append(lines, l.emitUnsupported(inst, "unsupported adc/sbb operand")...)
		return lines, nil
	}

	// a: destination value in x17/w17 (zero-extended for 8/16-bit); x16 keeps a memory
	// destination's address. b: source value in x0/w0 (zero-extended for 8/16-bit).
	if dstIsMem {
		lines = append(lines, readMemTo(dstMem, nextPC, size, "x17", "w17")...)
	} else if size < 4 {
		rc, _ := readRegTo(dstReg, "x17", "w17")
		lines = append(lines, rc...)
	}
	bReg := "" // a 32/64-bit source used in place (pinned register or zero register)
	switch v := src.(type) {
	case x86asm.Imm:
		val := uint64(int64(v))
		switch size {
		case 1:
			val &= 0xff
		case 2:
			val &= 0xffff
		case 4:
			val &= 0xffffffff
		}
		if val == 0 && size >= 4 {
			bReg = "zr"
		} else {
			lines = append(lines, loadImm64("x0", val)...)
		}
	case x86asm.Reg:
		if d, ok := arm64RegMap[v]; ok && size >= 4 {
			bReg = d.X[1:]
			break
		}
		rc, ok := readRegTo(v, "x0", "w0")
		if !ok {
			lines = append(lines, l.emitUnsupported(inst, "unmapped adc/sbb src")...)
			return lines, nil
		}
		lines = append(lines, rc...)
	case x86asm.Mem:
		if dstIsMem {
			lines = append(lines, l.emitUnsupported(inst, "adc/sbb mem, mem")...)
			return lines, nil
		}
		lines = append(lines, readMemTo(v, nextPC, size, "x0", "w0")...)
	default:
		lines = append(lines, l.emitUnsupported(inst, "unsupported adc/sbb source")...)
		return lines, nil
	}

	res := "x17"
	if size <= 4 {
		res = "w17"
	}
	if dstIsReg && size >= 4 {
		// Operate on the pinned register directly.
		res = arm64RegMap[dstReg].X
		if size == 4 {
			res = arm64RegMap[dstReg].W
		}
	}
	if size >= 4 && dstIsReg && inst.SkipFlags {
		// Flags dead: the common idioms need no carry inversion.
		d := arm64RegMap[dstReg]
		r := d.X
		if size == 4 {
			r = d.W
		}
		if !isSbb && bReg == "zr" {
			lines = append(lines, fmt.Sprintf("    cinc %s, %s, %s", r, r, l.carryCond(true))) // adc r, 0
			return lines, nil
		}
		if s, isReg := src.(x86asm.Reg); isSbb && isReg && arm64RegMap[s].X == d.X {
			lines = append(lines, fmt.Sprintf("    csetm %s, %s", r, l.carryCond(true))) // sbb r, r = -CF
			return lines, nil
		}
	}
	if size >= 4 {
		if bReg == "" {
			bReg = "0"
		}
		b := "x" + bReg
		if size == 4 {
			b = "w" + bReg
		}
		op := "adc"
		if isSbb {
			op = "sbc"
			if l.cpol != carrySub {
				lines = append(lines, l.normalizeCarry()...)
			}
		} else if l.cpol == carrySub {
			lines = append(lines, "    cfinv")
			l.cpol = carryAdd
		} else {
			l.cpol = carryAdd // carryClear: C = 0 = CF
		}
		if flags {
			op += "s"
		}
		lines = append(lines, fmt.Sprintf("    %s %s, %s, %s", op, res, res, b))
	} else {
		bits := 8 * size
		ext := "sxtb"
		setf := "setf8"
		if size == 2 {
			ext, setf = "sxth", "setf16"
		}
		lines = append(lines, fmt.Sprintf("    cset w2, %s", l.carryCond(true)))
		arith := "add"
		if isSbb {
			arith = "sub"
		}
		if flags {
			lines = append(lines,
				fmt.Sprintf("    %s w3, w17", ext),
				fmt.Sprintf("    %s w4, w0", ext),
				fmt.Sprintf("    %s w3, w3, w4", arith),
				fmt.Sprintf("    %s w3, w3, w2", arith),
				fmt.Sprintf("    %s w3", setf), // N, Z, V of the narrow result; C kept
				fmt.Sprintf("    %s w4, w17, w0", arith),
				fmt.Sprintf("    %s w4, w4, w2", arith),
			)
			if isSbb {
				// borrow = sign of the zero-extended difference; C = !borrow
				lines = append(lines, "    lsr w4, w4, #31", "    eor w4, w4, #1")
				l.cpol = carrySub
			} else {
				lines = append(lines, fmt.Sprintf("    ubfx w4, w4, #%d, #1", bits))
				l.cpol = carryAdd
			}
			lines = append(lines, "    rmif x4, #63, #2") // C = bit 0 of x4
		} else {
			lines = append(lines,
				fmt.Sprintf("    %s w3, w17, w0", arith),
				fmt.Sprintf("    %s w3, w3, w2", arith),
			)
		}
		res = "w3"
	}

	resX := "x" + res[1:]
	if dstIsReg && size >= 4 {
		return lines, nil
	}
	if dstIsMem {
		switch size {
		case 1:
			lines = append(lines, fmt.Sprintf("    strb %s, [x28, x16]", res))
		case 2:
			lines = append(lines, fmt.Sprintf("    strh %s, [x28, x16]", res))
		case 4:
			lines = append(lines, fmt.Sprintf("    str %s, [x28, x16]", res))
		default:
			lines = append(lines, fmt.Sprintf("    str %s, [x28, x16]", resX))
		}
	} else {
		wc, _ := writeRegFrom(dstReg, resX, "w"+res[1:])
		lines = append(lines, wc...)
	}
	return lines, nil
}

// liftBt handles BT, BTS, BTR, BTC.
func (l *Arm64Lifter) liftBt(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	if dstReg, okDst := dst.(x86asm.Reg); okDst {
		descDst, okDstD := arm64RegMap[dstReg]
		if !okDstD {
			lines = append(lines, l.emitUnsupported(inst, "unmapped bt dst")...)
			return lines, nil
		}

		bitWidth := descDst.Size * 8

		// Immediate bit index
		if imm, okImm := src.(x86asm.Imm); okImm {
			bitIdx := uint64(imm) % uint64(bitWidth)
			if descDst.Size == 8 {
				lines = append(lines, fmt.Sprintf("    ubfx x16, %s, #%d, #1", descDst.X, bitIdx))
				lines = append(lines, "    cmp xzr, x16")
				switch op {
				case x86asm.BTS:
					lines = append(lines, loadImm64("x18", uint64(1)<<bitIdx)...)
					lines = append(lines, fmt.Sprintf("    orr %s, %s, x18", descDst.X, descDst.X))
				case x86asm.BTR:
					lines = append(lines, loadImm64("x18", uint64(1)<<bitIdx)...)
					lines = append(lines, fmt.Sprintf("    bic %s, %s, x18", descDst.X, descDst.X))
				case x86asm.BTC:
					lines = append(lines, loadImm64("x18", uint64(1)<<bitIdx)...)
					lines = append(lines, fmt.Sprintf("    eor %s, %s, x18", descDst.X, descDst.X))
				}
			} else if descDst.Size == 4 {
				lines = append(lines, fmt.Sprintf("    ubfx w16, %s, #%d, #1", descDst.W, bitIdx))
				lines = append(lines, "    cmp wzr, w16")
				switch op {
				case x86asm.BTS:
					lines = append(lines, loadImm32("w18", uint32(1)<<bitIdx)...)
					lines = append(lines, fmt.Sprintf("    orr %s, %s, w18", descDst.W, descDst.W))
				case x86asm.BTR:
					lines = append(lines, loadImm32("w18", uint32(1)<<bitIdx)...)
					lines = append(lines, fmt.Sprintf("    bic %s, %s, w18", descDst.W, descDst.W))
				case x86asm.BTC:
					lines = append(lines, loadImm32("w18", uint32(1)<<bitIdx)...)
					lines = append(lines, fmt.Sprintf("    eor %s, %s, w18", descDst.W, descDst.W))
				}
			} else {
				rc, _ := readRegTo(dstReg, "x17", "w17")
				lines = append(lines, rc...)
				lines = append(lines, fmt.Sprintf("    ubfx w16, w17, #%d, #1", bitIdx))
				lines = append(lines, "    cmp wzr, w16")
				switch op {
				case x86asm.BTS:
					lines = append(lines, fmt.Sprintf("    orr w17, w17, #%d", uint32(1)<<bitIdx))
					wc, _ := writeRegFrom(dstReg, "x17", "w17")
					lines = append(lines, wc...)
				case x86asm.BTR:
					lines = append(lines, fmt.Sprintf("    bic w17, w17, #%d", uint32(1)<<bitIdx))
					wc, _ := writeRegFrom(dstReg, "x17", "w17")
					lines = append(lines, wc...)
				case x86asm.BTC:
					lines = append(lines, fmt.Sprintf("    eor w17, w17, #%d", uint32(1)<<bitIdx))
					wc, _ := writeRegFrom(dstReg, "x17", "w17")
					lines = append(lines, wc...)
				}
			}
			return lines, nil
		}

		// Register bit index
		if srcReg, okSrc := src.(x86asm.Reg); okSrc {
			descSrc, okSrcD := arm64RegMap[srcReg]
			if !okSrcD {
				lines = append(lines, l.emitUnsupported(inst, "unmapped bt src")...)
				return lines, nil
			}
			if descDst.Size == 8 {
				lines = append(lines, fmt.Sprintf("    and x17, %s, #63", descSrc.X))
				lines = append(lines, fmt.Sprintf("    lsr x16, %s, x17", descDst.X))
				lines = append(lines, "    and x16, x16, #1")
				lines = append(lines, "    cmp xzr, x16")
				switch op {
				case x86asm.BTS:
					lines = append(lines, "    mov x18, #1", "    lsl x18, x18, x17")
					lines = append(lines, fmt.Sprintf("    orr %s, %s, x18", descDst.X, descDst.X))
				case x86asm.BTR:
					lines = append(lines, "    mov x18, #1", "    lsl x18, x18, x17")
					lines = append(lines, fmt.Sprintf("    bic %s, %s, x18", descDst.X, descDst.X))
				case x86asm.BTC:
					lines = append(lines, "    mov x18, #1", "    lsl x18, x18, x17")
					lines = append(lines, fmt.Sprintf("    eor %s, %s, x18", descDst.X, descDst.X))
				}
			} else if descDst.Size == 4 {
				lines = append(lines, fmt.Sprintf("    and w17, %s, #31", descSrc.W))
				lines = append(lines, fmt.Sprintf("    lsr w16, %s, w17", descDst.W))
				lines = append(lines, "    and w16, w16, #1")
				lines = append(lines, "    cmp wzr, w16")
				switch op {
				case x86asm.BTS:
					lines = append(lines, "    mov w18, #1", "    lsl w18, w18, w17")
					lines = append(lines, fmt.Sprintf("    orr %s, %s, w18", descDst.W, descDst.W))
				case x86asm.BTR:
					lines = append(lines, "    mov w18, #1", "    lsl w18, w18, w17")
					lines = append(lines, fmt.Sprintf("    bic %s, %s, w18", descDst.W, descDst.W))
				case x86asm.BTC:
					lines = append(lines, "    mov w18, #1", "    lsl w18, w18, w17")
					lines = append(lines, fmt.Sprintf("    eor %s, %s, w18", descDst.W, descDst.W))
				}
			} else {
				rcDst, _ := readRegTo(dstReg, "x16", "w16")
				rcSrc, _ := readRegTo(srcReg, "x17", "w17")
				lines = append(lines, rcDst...)
				lines = append(lines, rcSrc...)
				mask := bitWidth - 1
				lines = append(lines, fmt.Sprintf("    and w17, w17, #%d", mask))
				lines = append(lines, "    lsr w18, w16, w17")
				lines = append(lines, "    and w18, w18, #1")
				lines = append(lines, "    cmp wzr, w18")
				switch op {
				case x86asm.BTS:
					lines = append(lines, "    mov w18, #1", "    lsl w18, w18, w17", "    orr w16, w16, w18")
					wc, _ := writeRegFrom(dstReg, "x16", "w16")
					lines = append(lines, wc...)
				case x86asm.BTR:
					lines = append(lines, "    mov w18, #1", "    lsl w18, w18, w17", "    bic w16, w16, w18")
					wc, _ := writeRegFrom(dstReg, "x16", "w16")
					lines = append(lines, wc...)
				case x86asm.BTC:
					lines = append(lines, "    mov w18, #1", "    lsl w18, w18, w17", "    eor w16, w16, w18")
					wc, _ := writeRegFrom(dstReg, "x16", "w16")
					lines = append(lines, wc...)
				}
			}
			return lines, nil
		}
	} else if mem, okMem := dst.(x86asm.Mem); okMem {
		sz := defMemSz(inst)
		lines = append(lines, readMemTo(mem, nextPC, sz, "x16", "w16")...)
		bitWidth := uint64(sz * 8)

		if imm, okImm := src.(x86asm.Imm); okImm {
			bitIdx := uint64(imm) % bitWidth
			if sz == 8 {
				lines = append(lines, fmt.Sprintf("    ubfx x17, x16, #%d, #1", bitIdx))
				lines = append(lines, "    cmp xzr, x17")
				switch op {
				case x86asm.BTS:
					lines = append(lines, loadImm64("x18", uint64(1)<<bitIdx)...)
					lines = append(lines, "    orr x16, x16, x18")
					lines = append(lines, writeMemFrom(mem, nextPC, sz, "x16", "w16")...)
				case x86asm.BTR:
					lines = append(lines, loadImm64("x18", uint64(1)<<bitIdx)...)
					lines = append(lines, "    bic x16, x16, x18")
					lines = append(lines, writeMemFrom(mem, nextPC, sz, "x16", "w16")...)
				case x86asm.BTC:
					lines = append(lines, loadImm64("x18", uint64(1)<<bitIdx)...)
					lines = append(lines, "    eor x16, x16, x18")
					lines = append(lines, writeMemFrom(mem, nextPC, sz, "x16", "w16")...)
				}
			} else {
				lines = append(lines, fmt.Sprintf("    ubfx w17, w16, #%d, #1", bitIdx))
				lines = append(lines, "    cmp wzr, w17")
				switch op {
				case x86asm.BTS:
					lines = append(lines, loadImm32("w18", uint32(1)<<bitIdx)...)
					lines = append(lines, "    orr w16, w16, w18")
					lines = append(lines, writeMemFrom(mem, nextPC, sz, "x16", "w16")...)
				case x86asm.BTR:
					lines = append(lines, loadImm32("w18", uint32(1)<<bitIdx)...)
					lines = append(lines, "    bic w16, w16, w18")
					lines = append(lines, writeMemFrom(mem, nextPC, sz, "x16", "w16")...)
				case x86asm.BTC:
					lines = append(lines, loadImm32("w18", uint32(1)<<bitIdx)...)
					lines = append(lines, "    eor w16, w16, w18")
					lines = append(lines, writeMemFrom(mem, nextPC, sz, "x16", "w16")...)
				}
			}
			return lines, nil
		}

		if srcReg, okSrc := src.(x86asm.Reg); okSrc {
			descSrc, okSrcD := arm64RegMap[srcReg]
			if !okSrcD {
				lines = append(lines, l.emitUnsupported(inst, "unmapped bt src")...)
				return lines, nil
			}
			if sz == 8 {
				lines = append(lines, fmt.Sprintf("    and x17, %s, #63", descSrc.X))
				lines = append(lines, "    lsr x18, x16, x17")
				lines = append(lines, "    and x18, x18, #1")
				lines = append(lines, "    cmp xzr, x18")
				switch op {
				case x86asm.BTS:
					lines = append(lines, "    mov x18, #1", "    lsl x18, x18, x17", "    orr x16, x16, x18")
					lines = append(lines, writeMemFrom(mem, nextPC, sz, "x16", "w16")...)
				case x86asm.BTR:
					lines = append(lines, "    mov x18, #1", "    lsl x18, x18, x17", "    bic x16, x16, x18")
					lines = append(lines, writeMemFrom(mem, nextPC, sz, "x16", "w16")...)
				case x86asm.BTC:
					lines = append(lines, "    mov x18, #1", "    lsl x18, x18, x17", "    eor x16, x16, x18")
					lines = append(lines, writeMemFrom(mem, nextPC, sz, "x16", "w16")...)
				}
			} else {
				lines = append(lines, fmt.Sprintf("    and w17, %s, #31", descSrc.W))
				lines = append(lines, "    lsr w18, w16, w17")
				lines = append(lines, "    and w18, w18, #1")
				lines = append(lines, "    cmp wzr, w18")
				switch op {
				case x86asm.BTS:
					lines = append(lines, "    mov w18, #1", "    lsl w18, w18, w17", "    orr w16, w16, w18")
					lines = append(lines, writeMemFrom(mem, nextPC, sz, "x16", "w16")...)
				case x86asm.BTR:
					lines = append(lines, "    mov w18, #1", "    lsl w18, w18, w17", "    bic w16, w16, w18")
					lines = append(lines, writeMemFrom(mem, nextPC, sz, "x16", "w16")...)
				case x86asm.BTC:
					lines = append(lines, "    mov w18, #1", "    lsl w18, w18, w17", "    eor w16, w16, w18")
					lines = append(lines, writeMemFrom(mem, nextPC, sz, "x16", "w16")...)
				}
			}
			return lines, nil
		}
	}

	lines = append(lines, l.emitUnsupported(inst, "unsupported bt operand")...)
	return lines, nil
}

// liftMovbe handles MOVBE instruction (move with byte swap).
func (l *Arm64Lifter) liftMovbe(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	// Reg <- Mem (load and swap)
	if dstReg, okDst := dst.(x86asm.Reg); okDst {
		if mem, okMem := src.(x86asm.Mem); okMem {
			descDst, okDesc := arm64RegMap[dstReg]
			if okDesc {
				lines = append(lines, readMemTo(mem, nextPC, descDst.Size, "x16", "w16")...)
				switch descDst.Size {
				case 2:
					lines = append(lines, "    rev16 w16, w16")
				case 4:
					lines = append(lines, "    rev w16, w16")
				default: // 8
					lines = append(lines, "    rev x16, x16")
				}
				storeCode, _ := writeRegFrom(dstReg, "x16", "w16")
				lines = append(lines, storeCode...)
				return lines, nil
			}
		}
	}

	// Mem <- Reg (swap and store)
	if mem, okMem := dst.(x86asm.Mem); okMem {
		if srcReg, okSrc := src.(x86asm.Reg); okSrc {
			descSrc, okDesc := arm64RegMap[srcReg]
			if okDesc {
				loadCode, _ := readRegTo(srcReg, "x17", "w17")
				lines = append(lines, loadCode...)
				switch descSrc.Size {
				case 2:
					lines = append(lines, "    rev16 w17, w17")
				case 4:
					lines = append(lines, "    rev w17, w17")
				default: // 8
					lines = append(lines, "    rev x17, x17")
				}
				lines = append(lines, writeMemFrom(mem, nextPC, descSrc.Size, "x17", "w17")...)
				return lines, nil
			}
		}
	}

	lines = append(lines, l.emitUnsupported(inst, "unsupported movbe operands")...)
	return lines, nil
}

// liftRdtsc handles RDTSC (Read Time-Stamp Counter).
func (l *Arm64Lifter) liftRdtsc(lines []string) []string {
	lines = append(lines, "    mrs x16, cntvct_el0")
	lines = append(lines, "    mov w19, w16")
	lines = append(lines, "    lsr x16, x16, #32")
	lines = append(lines, "    mov w22, w16")
	return lines
}

// liftPopcnt handles POPCNT instruction.
func (l *Arm64Lifter) liftPopcnt(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	dstReg, okDst := dst.(x86asm.Reg)
	if !okDst {
		lines = append(lines, l.emitUnsupported(inst, "unsupported popcnt dst")...)
		return lines, nil
	}
	descDst, okDD := arm64RegMap[dstReg]
	if !okDD {
		lines = append(lines, l.emitUnsupported(inst, "unmapped popcnt dst")...)
		return lines, nil
	}

	sz := descDst.Size
	if sz == 0 {
		sz = 4
	}

	if srcReg, okSrc := src.(x86asm.Reg); okSrc {
		loadCode, _ := readRegTo(srcReg, "x16", "w16")
		lines = append(lines, loadCode...)
	} else if mem, okMem := src.(x86asm.Mem); okMem {
		lines = append(lines, readMemTo(mem, nextPC, sz, "x16", "w16")...)
	} else {
		lines = append(lines, l.emitUnsupported(inst, "unsupported popcnt src")...)
		return lines, nil
	}

	if sz == 8 {
		lines = append(lines, "    fmov d31, x16")
		lines = append(lines, "    cnt v31.8b, v31.8b")
		lines = append(lines, "    uaddlv h31, v31.8b")
		lines = append(lines, "    fmov w16, s31")
		lines = append(lines, "    uxtw x16, w16")
		lines = append(lines, "    cmp x16, #0")
	} else {
		lines = append(lines, "    fmov s31, w16")
		lines = append(lines, "    cnt v31.8b, v31.8b")
		lines = append(lines, "    uaddlv h31, v31.8b")
		lines = append(lines, "    fmov w16, s31")
		lines = append(lines, "    cmp w16, #0")
	}
	storeCode, _ := writeRegFrom(dstReg, "x16", "w16")
	lines = append(lines, storeCode...)
	return lines, nil
}

// liftBextr handles BMI1 bit field extract (BEXTR).
func (l *Arm64Lifter) liftBextr(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	descDst, okDD := arm64RegMap[dstReg]
	ctrlReg, okCtrl := inst.Inst.Args[2].(x86asm.Reg)
	descCtrl, okDC := arm64RegMap[ctrlReg]
	if !okDst || !okDD || !okCtrl || !okDC {
		lines = append(lines, l.emitUnsupported(inst, "unsupported bextr operands")...)
		return lines, nil
	}

	sz := descDst.Size
	if sz == 0 {
		sz = 4
	}

	src := inst.Inst.Args[1]
	if srcReg, okSrc := src.(x86asm.Reg); okSrc {
		loadCode, _ := readRegTo(srcReg, "x18", "w18")
		lines = append(lines, loadCode...)
	} else if mem, okMem := src.(x86asm.Mem); okMem {
		lines = append(lines, readMemTo(mem, nextPC, sz, "x18", "w18")...)
	} else {
		lines = append(lines, l.emitUnsupported(inst, "unsupported bextr src")...)
		return lines, nil
	}

	l.labelCounter++
	lblAll := fmt.Sprintf("L_bextr_all_%d", l.labelCounter)
	lblDone := fmt.Sprintf("L_bextr_done_%d", l.labelCounter)

	lines = append(lines, fmt.Sprintf("    ubfx w16, %s, #0, #8", descCtrl.W))
	lines = append(lines, fmt.Sprintf("    ubfx w17, %s, #8, #8", descCtrl.W))

	if sz == 8 {
		lines = append(lines, "    lsr x18, x18, x16")
		lines = append(lines, "    cmp w17, #64")
		lines = append(lines, fmt.Sprintf("    b.hs %s", lblAll))
		lines = append(lines, "    mov x16, #1")
		lines = append(lines, "    lsl x16, x16, x17")
		lines = append(lines, "    sub x16, x16, #1")
		lines = append(lines, "    and x18, x18, x16")
		lines = append(lines, fmt.Sprintf("    b %s", lblDone))
		lines = append(lines, fmt.Sprintf("%s:", lblAll))
		lines = append(lines, fmt.Sprintf("%s:", lblDone))
		storeCode, _ := writeRegFrom(dstReg, "x18", "w18")
		lines = append(lines, storeCode...)
		lines = append(lines, fmt.Sprintf("    cmp %s, #0", descDst.X))
	} else {
		lines = append(lines, "    lsr w18, w18, w16")
		lines = append(lines, "    cmp w17, #32")
		lines = append(lines, fmt.Sprintf("    b.hs %s", lblAll))
		lines = append(lines, "    mov w16, #1")
		lines = append(lines, "    lsl w16, w16, w17")
		lines = append(lines, "    sub w16, w16, #1")
		lines = append(lines, "    and w18, w18, w16")
		lines = append(lines, fmt.Sprintf("    b %s", lblDone))
		lines = append(lines, fmt.Sprintf("%s:", lblAll))
		lines = append(lines, fmt.Sprintf("%s:", lblDone))
		storeCode, _ := writeRegFrom(dstReg, "x18", "w18")
		lines = append(lines, storeCode...)
		lines = append(lines, fmt.Sprintf("    cmp %s, #0", descDst.W))
	}

	return lines, nil
}

// liftCpuid handles CPUID instruction.
func (l *Arm64Lifter) liftCpuid(lines []string) []string {
	l.labelCounter++
	id := l.labelCounter
	lblLeaf0 := fmt.Sprintf(".Lcpuid_leaf0_%d", id)
	lblLeaf1 := fmt.Sprintf(".Lcpuid_leaf1_%d", id)
	lblLeaf7 := fmt.Sprintf(".Lcpuid_leaf7_%d", id)
	lblLeaf80 := fmt.Sprintf(".Lcpuid_leaf80_%d", id)
	lblLeaf81 := fmt.Sprintf(".Lcpuid_leaf81_%d", id)
	lblEnd := fmt.Sprintf(".Lcpuid_end_%d", id)

	lines = append(lines,
		"    // cpuid",
		"    mrs x16, nzcv",
		"    str x16, [sp, #-16]!",
		"    mov w16, w19 // save input leaf (eax)",
		"    mov w17, w21 // save input subleaf (ecx)",
		"    mov w19, #0  // eax = 0",
		"    mov w20, #0  // ebx = 0",
		"    mov w21, #0  // ecx = 0",
		"    mov w22, #0  // edx = 0",
		fmt.Sprintf("    cbz w16, %s", lblLeaf0),
		"    cmp w16, #1",
		fmt.Sprintf("    b.eq %s", lblLeaf1),
		"    cmp w16, #7",
		fmt.Sprintf("    b.eq %s", lblLeaf7),
		"    mov w20, #0x80000000",
		"    cmp w16, w20",
		fmt.Sprintf("    b.eq %s", lblLeaf80),
		"    add w20, w20, #1",
		"    cmp w16, w20",
		fmt.Sprintf("    b.eq %s", lblLeaf81),
		fmt.Sprintf("    b %s", lblEnd),
		fmt.Sprintf("%s:", lblLeaf0),
	)
	// Leaf 0: "GenuineIntel"
	lines = append(lines, loadImm32("w19", 0xd)...)
	lines = append(lines, loadImm32("w20", 0x756e6547)...)
	lines = append(lines, loadImm32("w22", 0x49656e69)...)
	lines = append(lines, loadImm32("w21", 0x6c65746e)...)
	lines = append(lines,
		fmt.Sprintf("    b %s", lblEnd),
		fmt.Sprintf("%s:", lblLeaf1),
	)
	// Leaf 1: Family/Model + Features
	lines = append(lines, loadImm32("w19", 0x000306c3)...)
	lines = append(lines, loadImm32("w20", 0x00100800)...)
	lines = append(lines, loadImm32("w21", 0x7ffafbff)...)
	lines = append(lines, loadImm32("w22", 0xbfebfbff)...)
	lines = append(lines,
		fmt.Sprintf("    b %s", lblEnd),
		fmt.Sprintf("%s:", lblLeaf7),
		fmt.Sprintf("    cbnz w17, %s", lblEnd),
	)
	// Leaf 7: AVX2, BMI1, BMI2
	lines = append(lines, loadImm32("w20", 0x00000219)...)
	lines = append(lines,
		fmt.Sprintf("    b %s", lblEnd),
		fmt.Sprintf("%s:", lblLeaf80),
	)
	// Leaf 0x80000000
	lines = append(lines, loadImm32("w19", 0x80000008)...)
	lines = append(lines,
		fmt.Sprintf("    b %s", lblEnd),
		fmt.Sprintf("%s:", lblLeaf81),
	)
	// Leaf 0x80000001
	lines = append(lines, loadImm32("w21", 0x00000021)...)
	lines = append(lines, loadImm32("w22", 0x2c100800)...)
	lines = append(lines,
		fmt.Sprintf("%s:", lblEnd),
		"    ldr x16, [sp], #16",
		"    msr nzcv, x16",
	)
	return lines
}

// liftXgetbv handles XGETBV instruction.
func (l *Arm64Lifter) liftXgetbv(lines []string) []string {
	l.labelCounter++
	id := l.labelCounter
	lblNonZero := fmt.Sprintf(".Lxgetbv_nonzero_%d", id)
	lblEnd := fmt.Sprintf(".Lxgetbv_end_%d", id)

	lines = append(lines,
		"    // xgetbv",
		fmt.Sprintf("    cbnz w21, %s", lblNonZero),
		"    mov x19, #7  // rax = 7 (x87 + SSE + AVX)",
		"    mov x22, #0  // rdx = 0",
		fmt.Sprintf("    b %s", lblEnd),
		fmt.Sprintf("%s:", lblNonZero),
		"    mov x19, #0",
		"    mov x22, #0",
		fmt.Sprintf("%s:", lblEnd),
	)
	return lines
}

// liftAndn handles BMI1 ANDN: dst = (~src1) & src2.
func (l *Arm64Lifter) liftAndn(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	s1Reg, okS1 := inst.Inst.Args[1].(x86asm.Reg)
	src2 := inst.Inst.Args[2]

	descDst, okDD := arm64RegMap[dstReg]
	_, okDS1 := arm64RegMap[s1Reg]
	if !okDst || !okDD || !okS1 || !okDS1 {
		lines = append(lines, l.emitUnsupported(inst, "unsupported andn operands")...)
		return lines, nil
	}

	sz := descDst.Size
	if sz == 0 {
		sz = 4
	}

	loadS1, _ := readRegTo(s1Reg, "x16", "w16")
	lines = append(lines, loadS1...)

	if s2Reg, okS2 := src2.(x86asm.Reg); okS2 {
		loadS2, _ := readRegTo(s2Reg, "x17", "w17")
		lines = append(lines, loadS2...)
	} else if mem, okMem := src2.(x86asm.Mem); okMem {
		lines = append(lines, readMemTo(mem, nextPC, sz, "x17", "w17")...)
	} else {
		lines = append(lines, l.emitUnsupported(inst, "unsupported andn src2")...)
		return lines, nil
	}

	if sz == 8 {
		lines = append(lines, "    bics x18, x17, x16")
	} else {
		lines = append(lines, "    bics w18, w17, w16")
	}

	storeDst, _ := writeRegFrom(dstReg, "x18", "w18")
	lines = append(lines, storeDst...)
	return lines, nil
}

// liftCmpxchg16b handles CMPXCHG16B m128.
// Compares RDX:RAX with m128. If equal, loads RCX:RBX into m128 and sets ZF.
// If unequal, loads m128 into RDX:RAX and clears ZF.
func (l *Arm64Lifter) liftCmpxchg16b(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	mem, okMem := inst.Inst.Args[0].(x86asm.Mem)
	if !okMem {
		lines = append(lines, l.emitUnsupported(inst, "cmpxchg16b operand must be memory")...)
		return lines, nil
	}

	l.labelCounter++
	loopLabel := fmt.Sprintf("L_cas16b_loop_%d", l.labelCounter)
	failLabel := fmt.Sprintf("L_cas16b_fail_%d", l.labelCounter)
	doneLabel := fmt.Sprintf("L_cas16b_done_%d", l.labelCounter)

	lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
	lines = append(lines, "    add x16, x28, x16") // absolute host pointer in x16

	// Desired value is in RCX:RBX (x21:x20)
	// RAX is in x19, RDX is in x22
	// RBX is in x20, RCX is in x21
	lines = append(lines,
		fmt.Sprintf("%s:", loopLabel),
		"    ldaxp x0, x1, [x16]", // x0 = mem_lo, x1 = mem_hi
		"    cmp x0, x19",         // compare mem_lo with RAX
		fmt.Sprintf("    b.ne %s", failLabel),
		"    cmp x1, x22",         // compare mem_hi with RDX
		fmt.Sprintf("    b.ne %s", failLabel),
		// Equal: attempt atomic store of RCX:RBX (x21:x20)
		"    stlxp w2, x20, x21, [x16]",
		fmt.Sprintf("    cbnz w2, %s", loopLabel), // retry if exclusive store failed
		// Success: ZF = 1
		"    cmp xzr, xzr", // sets ZF=1
		fmt.Sprintf("    b %s", doneLabel),
		fmt.Sprintf("%s:", failLabel),
		"    clrex",
		"    mov x19, x0", // RAX = mem_lo
		"    mov x22, x1", // RDX = mem_hi
		"    mov x2, #1",
		"    cmp x2, #0", // sets ZF=0
		fmt.Sprintf("%s:", doneLabel),
	)
	return lines, nil
}

// liftFlagsOp handles CLC, STC, CMC, LAHF, SAHF in terms of the tracked carry sense.
// LAHF stores AF = PF = 0 (not modeled); SAHF keeps OF (V), as x86 does.
func (l *Arm64Lifter) liftFlagsOp(inst disasm.Instruction, lines []string) ([]string, error) {
	switch inst.Inst.Op {
	case x86asm.CLC:
		lines = append(lines, "    rmif xzr, #0, #2") // C = 0: CF = 0 in the carryClear sense
		l.cpol = carryClear
	case x86asm.STC:
		lines = append(lines, "    rmif xzr, #0, #2") // C = 0: CF = 1 in the carrySub sense
		l.cpol = carrySub
	case x86asm.CMC:
		lines = append(lines, "    cfinv") // inverting C inverts CF in either sense
		if l.cpol == carryClear {
			l.cpol = carryAdd
		}
	case x86asm.LAHF:
		// AH = SF:ZF:0:AF:0:PF:1:CF
		lines = append(lines,
			"    cset w0, mi",
			"    cset w1, eq",
			fmt.Sprintf("    cset w2, %s", l.carryCond(true)),
			"    orr w0, w2, w0, lsl #7",
			"    orr w0, w0, w1, lsl #6",
			"    orr w0, w0, #2",
			"    bfi x19, x0, #8, #8")
	case x86asm.SAHF:
		lines = append(lines,
			"    ubfx w0, w19, #8, #8", // AH
			"    rmif x0, #4, #12",     // N = SF (bit 7), Z = ZF (bit 6)
			"    rmif x0, #63, #2")     // C = CF (bit 0)
		l.cpol = carryAdd
	}
	return lines, nil
}

// liftLeave handles LEAVE (equivalent to mov rsp, rbp; pop rbp).
func (l *Arm64Lifter) liftLeave(lines []string) []string {
	// RSP is x26, RBP is x25
	lines = append(lines,
		"    mov x26, x25",           // mov rsp, rbp
		"    ldr x25, [x28, x26]",    // pop rbp
		"    add x26, x26, #8",
	)
	return lines
}

// liftShldShrd handles SHLD and SHRD double shifts.
func (l *Arm64Lifter) liftShldShrd(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]
	cnt := inst.Inst.Args[2]

	dstReg, okDstReg := dst.(x86asm.Reg)
	srcReg, okSrcReg := src.(x86asm.Reg)
	if !okSrcReg {
		lines = append(lines, l.emitUnsupported(inst, "shld/shrd src must be reg")...)
		return lines, nil
	}
	descSrc, okSrcD := arm64RegMap[srcReg]
	if !okSrcD {
		lines = append(lines, l.emitUnsupported(inst, "unmapped shld/shrd src reg")...)
		return lines, nil
	}

	sz := descSrc.Size
	if sz != 4 && sz != 8 {
		sz = 4
	}

	var cntRegStr string
	var immShift int
	isImm := false

	if imm, okImm := cnt.(x86asm.Imm); okImm {
		isImm = true
		mask := 31
		if sz == 8 {
			mask = 63
		}
		immShift = int(imm) & mask
	} else if cReg, okCReg := cnt.(x86asm.Reg); okCReg {
		descCnt, okCntD := arm64RegMap[cReg]
		if !okCntD {
			lines = append(lines, l.emitUnsupported(inst, "unmapped shld/shrd cnt reg")...)
			return lines, nil
		}
		if sz == 8 {
			lines = append(lines, fmt.Sprintf("    and x18, %s, #63", descCnt.X))
			cntRegStr = "x18"
		} else {
			lines = append(lines, fmt.Sprintf("    and w18, %s, #31", descCnt.W))
			cntRegStr = "w18"
		}
	}

	// Load dst into x16 / w16
	if okDstReg {
		loadDst, _ := readRegTo(dstReg, "x16", "w16")
		lines = append(lines, loadDst...)
	} else if mem, okMem := dst.(x86asm.Mem); okMem {
		lines = append(lines, readMemTo(mem, nextPC, sz, "x16", "w16")...)
	} else {
		lines = append(lines, l.emitUnsupported(inst, "unsupported shld/shrd dst")...)
		return lines, nil
	}

	loadSrc, _ := readRegTo(srcReg, "x17", "w17")
	lines = append(lines, loadSrc...)

	if isImm {
		if immShift > 0 {
			if op == x86asm.SHLD {
				// SHLD dst, src, imm: result = (dst << imm) | (src >> (sz*8 - imm))
				if sz == 8 {
					lines = append(lines, fmt.Sprintf("    extr x16, x16, x17, #%d", 64-immShift))
				} else {
					lines = append(lines, fmt.Sprintf("    extr w16, w16, w17, #%d", 32-immShift))
				}
			} else {
				// SHRD dst, src, imm: result = (dst >> imm) | (src << (sz*8 - imm))
				if sz == 8 {
					lines = append(lines, fmt.Sprintf("    extr x16, x17, x16, #%d", immShift))
				} else {
					lines = append(lines, fmt.Sprintf("    extr w16, w17, w16, #%d", immShift))
				}
			}
		}
	} else {
		// Variable count in x18 / w18
		l.labelCounter++
		skipLabel := fmt.Sprintf("L_shld_skip_%d", l.labelCounter)
		if sz == 8 {
			lines = append(lines,
				fmt.Sprintf("    cbz %s, %s", cntRegStr, skipLabel),
				"    sub x0, xzr, x18", // x0 = -count
			)
			if op == x86asm.SHLD {
				lines = append(lines,
					"    lsl x16, x16, x18",
					"    neg x1, x18",
					"    add x1, x1, #64",
					"    lsr x17, x17, x1",
					"    orr x16, x16, x17",
				)
			} else {
				lines = append(lines,
					"    lsr x16, x16, x18",
					"    neg x1, x18",
					"    add x1, x1, #64",
					"    lsl x17, x17, x1",
					"    orr x16, x16, x17",
				)
			}
			lines = append(lines, fmt.Sprintf("%s:", skipLabel))
		} else {
			lines = append(lines,
				fmt.Sprintf("    cbz %s, %s", cntRegStr, skipLabel),
			)
			if op == x86asm.SHLD {
				lines = append(lines,
					"    lsl w16, w16, w18",
					"    neg w1, w18",
					"    add w1, w1, #32",
					"    lsr w17, w17, w1",
					"    orr w16, w16, w17",
				)
			} else {
				lines = append(lines,
					"    lsr w16, w16, w18",
					"    neg w1, w18",
					"    add w1, w1, #32",
					"    lsl w17, w17, w1",
					"    orr w16, w16, w17",
				)
			}
			lines = append(lines, fmt.Sprintf("%s:", skipLabel))
		}
	}

	// Write back result
	if okDstReg {
		storeDst, _ := writeRegFrom(dstReg, "x16", "w16")
		lines = append(lines, storeDst...)
	} else if mem, okMem := dst.(x86asm.Mem); okMem {
		lines = append(lines, writeMemFrom(mem, nextPC, sz, "x16", "w16")...)
	}
	return lines, nil
}

// liftEnter handles ENTER alloc, level.
func (l *Arm64Lifter) liftEnter(inst disasm.Instruction, lines []string) []string {
	alloc := uint64(0)
	if imm, ok := inst.Inst.Args[0].(x86asm.Imm); ok {
		alloc = uint64(uint16(imm))
	}
	level := 0
	if imm, ok := inst.Inst.Args[1].(x86asm.Imm); ok {
		level = int(imm) & 0x1f
	}
	// push rbp:
	lines = append(lines,
		"    sub  x26, x26, #8",
		"    str  x25, [x28, x26]",
	)
	if level == 0 {
		lines = append(lines, "    mov  x25, x26")
	} else {
		lines = append(lines, "    mov  x16, x26") // frame_ptr = rsp
		for i := 1; i < level; i++ {
			lines = append(lines,
				fmt.Sprintf("    sub  x17, x25, #%d", i*8),
				"    ldr  x17, [x28, x17]",
				"    sub  x26, x26, #8",
				"    str  x17, [x28, x26]",
			)
		}
		lines = append(lines,
			"    sub  x26, x26, #8",
			"    str  x16, [x28, x26]",
			"    mov  x25, x16",
		)
	}
	if alloc > 0 {
		if alloc <= 4095 {
			lines = append(lines, fmt.Sprintf("    sub  x26, x26, #%d", alloc))
		} else {
			lines = append(lines,
				fmt.Sprintf("    movz x16, #0x%x", alloc&0xffff),
				fmt.Sprintf("    movk x16, #0x%x, lsl #16", (alloc>>16)&0xffff),
				"    sub  x26, x26, x16",
			)
		}
	}
	return lines
}

// liftRclRcr handles RCL and RCR (rotate through carry).
func (l *Arm64Lifter) liftRclRcr(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	dst := inst.Inst.Args[0]
	shiftArg := inst.Inst.Args[1]

	dstReg, okDstReg := dst.(x86asm.Reg)
	sz := 4
	if okDstReg {
		if dDesc, okDesc := arm64RegMap[dstReg]; okDesc {
			sz = dDesc.Size
		}
	} else {
		sz = defMemSz(inst)
	}
	bitSz := sz * 8

	// Load destination operand into x16
	if okDstReg {
		loadDst, _ := readRegTo(dstReg, "x16", "w16")
		lines = append(lines, loadDst...)
	} else if mem, okMem := dst.(x86asm.Mem); okMem {
		lines = append(lines, readMemTo(mem, nextPC, sz, "x16", "w16")...)
	}

	// Read current carry flag into w19 (0 or 1)
	lines = append(lines,
		"    mrs  x18, nzcv",
		"    ubfx w19, w18, #29, #1", // w19 = old CF
	)

	// Determine shift count
	if imm, okImm := shiftArg.(x86asm.Imm); okImm {
		count := int(imm) % (bitSz + 1)
		if count > 0 {
			for i := 0; i < count; i++ {
				if op == x86asm.RCL {
					lines = append(lines,
						fmt.Sprintf("    lsr  x20, x16, #%d", bitSz-1), // new CF = MSB
						"    and  x20, x20, #1",
						"    lsl  x16, x16, #1",
						"    orr  x16, x16, x19",                      // insert old CF
						"    mov  w19, w20",                            // old CF = new CF
					)
					if bitSz < 64 {
						lines = append(lines, fmt.Sprintf("    and  x16, x16, #0x%x", (uint64(1)<<bitSz)-1))
					}
				} else {
					lines = append(lines,
						"    and  x20, x16, #1",                        // new CF = LSB
						"    lsr  x16, x16, #1",
						fmt.Sprintf("    orr  x16, x16, x19, lsl #%d", bitSz-1), // insert old CF at MSB
						"    mov  w19, w20",
					)
				}
			}
		}
	} else {
		// Variable count from CL (w21)
		loopLabel := fmt.Sprintf("L_rcl_rcr_loop_0x%x", inst.Address)
		endLabel := fmt.Sprintf("L_rcl_rcr_end_0x%x", inst.Address)
		lines = append(lines,
			fmt.Sprintf("    and  w17, w21, #0x%x", bitSz-1),
			fmt.Sprintf("    cbz  w17, %s", endLabel),
			fmt.Sprintf("%s:", loopLabel),
		)
		if op == x86asm.RCL {
			lines = append(lines,
				fmt.Sprintf("    lsr  x20, x16, #%d", bitSz-1),
				"    and  x20, x20, #1",
				"    lsl  x16, x16, #1",
				"    orr  x16, x16, x19",
				"    mov  w19, w20",
			)
			if bitSz < 64 {
				lines = append(lines, fmt.Sprintf("    and  x16, x16, #0x%x", (uint64(1)<<bitSz)-1))
			}
		} else {
			lines = append(lines,
				"    and  x20, x16, #1",
				"    lsr  x16, x16, #1",
				fmt.Sprintf("    orr  x16, x16, x19, lsl #%d", bitSz-1),
				"    mov  w19, w20",
			)
		}
		lines = append(lines,
			"    subs w17, w17, #1",
			fmt.Sprintf("    b.ne %s", loopLabel),
			fmt.Sprintf("%s:", endLabel),
		)
	}

	// Update carry flag in NZCV
	lines = append(lines,
		"    bfi  x18, x19, #29, #1",
		"    msr  nzcv, x18",
	)

	// Write back result
	if okDstReg {
		storeDst, _ := writeRegFrom(dstReg, "x16", "w16")
		lines = append(lines, storeDst...)
	} else if mem, okMem := dst.(x86asm.Mem); okMem {
		lines = append(lines, writeMemFrom(mem, nextPC, sz, "x16", "w16")...)
	}
	return lines, nil
}

// liftCrc32 handles CRC32.
func (l *Arm64Lifter) liftCrc32(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dstReg, okD := inst.Inst.Args[0].(x86asm.Reg)
	if !okD {
		lines = append(lines, l.emitUnsupported(inst, "crc32 invalid dst")...)
		return lines, nil
	}
	dDesc, okDesc := arm64RegMap[dstReg]
	if !okDesc {
		lines = append(lines, l.emitUnsupported(inst, "crc32 unknown dst")...)
		return lines, nil
	}

	src := inst.Inst.Args[1]
	srcSize := 4
	srcRegStr := "w16"
	if sReg, okS := src.(x86asm.Reg); okS {
		if sDesc, okSDesc := arm64RegMap[sReg]; okSDesc {
			srcSize = sDesc.Size
			rc, _ := readRegTo(sReg, "x16", "w16")
			lines = append(lines, rc...)
		}
	} else if mem, okMem := src.(x86asm.Mem); okMem {
		srcSize = defMemSz(inst)
		lines = append(lines, computeEffAddr(mem, nextPC, "x17")...)
		switch srcSize {
		case 1:
			lines = append(lines, "    ldrb w16, [x28, x17]")
		case 2:
			lines = append(lines, "    ldrh w16, [x28, x17]")
		case 4:
			lines = append(lines, "    ldr  w16, [x28, x17]")
		case 8:
			lines = append(lines, "    ldr  x16, [x28, x17]")
		}
	}

	if srcSize == 8 {
		srcRegStr = "x16"
	}

	rc, _ := readRegTo(dstReg, "x17", "w17")
	lines = append(lines, rc...)

	switch srcSize {
	case 1:
		lines = append(lines, fmt.Sprintf("    crc32cb %s, w17, %s", dDesc.W, srcRegStr))
	case 2:
		lines = append(lines, fmt.Sprintf("    crc32ch %s, w17, %s", dDesc.W, srcRegStr))
	case 4:
		lines = append(lines, fmt.Sprintf("    crc32cw %s, w17, %s", dDesc.W, srcRegStr))
	case 8:
		lines = append(lines, fmt.Sprintf("    crc32cx %s, w17, %s", dDesc.W, srcRegStr))
	}
	return lines, nil
}

// liftLar handles LAR (Load Access Rights Byte).
func (l *Arm64Lifter) liftLar(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dstReg, okD := inst.Inst.Args[0].(x86asm.Reg)
	if !okD {
		return lines, nil
	}
	dDesc, okDesc := arm64RegMap[dstReg]
	if !okDesc {
		return lines, nil
	}
	lines = append(lines,
		fmt.Sprintf("    mov  %s, #0x00f30000", dDesc.W),
		"    cmp  wzr, wzr", // sets ZF=1
	)
	return lines, nil
}

// liftStr handles STR (Store Task Register).
func (l *Arm64Lifter) liftStr(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	if reg, okR := dst.(x86asm.Reg); okR {
		if dDesc, okDesc := arm64RegMap[reg]; okDesc {
			lines = append(lines, fmt.Sprintf("    mov  %s, #0x40", dDesc.W))
			return lines, nil
		}
	} else if mem, okMem := dst.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		lines = append(lines,
			"    mov  w17, #0x40",
			"    strh w17, [x28, x16]",
		)
		return lines, nil
	}
	return lines, nil
}

