package lifter

import (
	"fmt"
	"golang.org/x/arch/x86/x86asm"
	"ps4-recomp/pkg/disasm"
)

// liftFpAlu handles single/double precision scalar float arithmetic.
func (l *Arm64Lifter) liftFpAlu(inst disasm.Instruction, nextPC uint64, armOp string, isDouble bool, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	dstReg, okDst := dst.(x86asm.Reg)
	xmmDst, okXD := arm64XmmMap[dstReg]
	if !okDst || !okXD {
		lines = append(lines, "    brk #0 // unsupported fp dst")
		return lines, nil
	}

	if srcReg, okSrc := src.(x86asm.Reg); okSrc {
		if xmmSrc, okXS := arm64XmmMap[srcReg]; okXS {
			if isDouble {
				lines = append(lines, fmt.Sprintf("    %s %s, %s, %s", armOp, xmmDst.D, xmmDst.D, xmmSrc.D))
			} else {
				lines = append(lines, fmt.Sprintf("    %s %s, %s, %s", armOp, xmmDst.S, xmmDst.S, xmmSrc.S))
			}
			return lines, nil
		}
	}

	if mem, okMem := src.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		if isDouble {
			lines = append(lines, "    ldr d16, [x28, x16]")
			lines = append(lines, fmt.Sprintf("    %s %s, %s, d16", armOp, xmmDst.D, xmmDst.D))
		} else {
			lines = append(lines, "    ldr s16, [x28, x16]")
			lines = append(lines, fmt.Sprintf("    %s %s, %s, s16", armOp, xmmDst.S, xmmDst.S))
		}
		return lines, nil
	}

	lines = append(lines, "    brk #0 // unsupported fp alu")
	return lines, nil
}

// liftFpCmp handles UCOMISS, UCOMISD, COMISS, COMISD, VUCOMISS, VUCOMISD, VCOMISS, and VCOMISD.
func (l *Arm64Lifter) liftFpCmp(inst disasm.Instruction, nextPC uint64, isDouble bool, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	dstReg, okDst := dst.(x86asm.Reg)
	_, _, _, _, _, dstLowS, dstLowD, okVD := getVectorDesc(dstReg)
	if !okDst || !okVD {
		lines = append(lines, l.emitUnsupported(inst, "unsupported fp cmp dst")...)
		return lines, nil
	}

	dstElem := dstLowS
	if isDouble {
		dstElem = dstLowD
	}

	if srcReg, okSrc := src.(x86asm.Reg); okSrc {
		if _, _, _, _, _, srcLowS, srcLowD, okVS := getVectorDesc(srcReg); okVS {
			srcElem := srcLowS
			if isDouble {
				srcElem = srcLowD
			}
			lines = append(lines, fmt.Sprintf("    fcmp %s, %s", dstElem, srcElem))
			return lines, nil
		}
	} else if mem, okMem := src.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		if isDouble {
			lines = append(lines, "    ldr d16, [x28, x16]")
			lines = append(lines, fmt.Sprintf("    fcmp %s, d16", dstElem))
		} else {
			lines = append(lines, "    ldr s16, [x28, x16]")
			lines = append(lines, fmt.Sprintf("    fcmp %s, s16", dstElem))
		}
		return lines, nil
	}

	lines = append(lines, l.emitUnsupported(inst, "unsupported fp cmp src")...)
	return lines, nil
}

// liftCvtsi2fp handles CVTSI2SS, CVTSI2SD, VCVTSI2SS, and VCVTSI2SD.
func (l *Arm64Lifter) liftCvtsi2fp(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	_, _, _, dLowV, dHighV, dLowS, dLowD, okD := getVectorDesc(dstReg)
	if !okDst || !okD {
		lines = append(lines, l.emitUnsupported(inst, "unsupported cvtsi2fp dst")...)
		return lines, nil
	}

	isDouble := (inst.Inst.Op == x86asm.CVTSI2SD || inst.Inst.Op == x86asm.VCVTSI2SD)
	isAvx := (inst.Inst.Op == x86asm.VCVTSI2SS || inst.Inst.Op == x86asm.VCVTSI2SD)

	var s1LowV string
	var src2 x86asm.Arg
	if isAvx {
		if src1Reg, okS1 := inst.Inst.Args[1].(x86asm.Reg); okS1 {
			if _, _, _, sLowV, _, _, _, okDesc := getVectorDesc(src1Reg); okDesc {
				s1LowV = sLowV
			}
		}
		src2 = inst.Inst.Args[2]
	} else {
		src2 = inst.Inst.Args[1]
	}

	if srcReg, okSrc := src2.(x86asm.Reg); okSrc {
		if descSrc, okDesc := arm64RegMap[srcReg]; okDesc {
			if isDouble {
				if descSrc.Size == 4 {
					lines = append(lines, fmt.Sprintf("    scvtf d30, %s", descSrc.W))
				} else {
					lines = append(lines, fmt.Sprintf("    scvtf d30, %s", descSrc.X))
				}
			} else {
				if descSrc.Size == 4 {
					lines = append(lines, fmt.Sprintf("    scvtf s30, %s", descSrc.W))
				} else {
					lines = append(lines, fmt.Sprintf("    scvtf s30, %s", descSrc.X))
				}
			}
		} else {
			lines = append(lines, l.emitUnsupported(inst, "unsupported cvtsi2fp src reg")...)
			return lines, nil
		}
	} else if mem, okMem := src2.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		if isDouble {
			lines = append(lines, "    ldr x17, [x28, x16]")
			lines = append(lines, "    scvtf d30, x17")
		} else {
			lines = append(lines, "    ldr w17, [x28, x16]")
			lines = append(lines, "    scvtf s30, w17")
		}
	} else {
		lines = append(lines, l.emitUnsupported(inst, "unsupported cvtsi2fp src")...)
		return lines, nil
	}

	if isAvx {
		if s1LowV != "" && dLowV != s1LowV {
			lines = append(lines, fmt.Sprintf("    mov %s.16b, %s.16b", dLowV, s1LowV))
		}
		if isDouble {
			lines = append(lines, fmt.Sprintf("    mov %s.d[0], v30.d[0]", dLowV))
		} else {
			lines = append(lines, fmt.Sprintf("    mov %s.s[0], v30.s[0]", dLowV))
		}
		lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
	} else {
		if isDouble {
			lines = append(lines, fmt.Sprintf("    fmov %s, d30", dLowD))
		} else {
			lines = append(lines, fmt.Sprintf("    fmov %s, s30", dLowS))
		}
	}
	return lines, nil
}

// liftCvtfp2si handles CVTSS2SI, CVTSD2SI, CVTTSS2SI, CVTTSD2SI, VCVTSS2SI, VCVTSD2SI, VCVTTSS2SI, VCVTTSD2SI.
func (l *Arm64Lifter) liftCvtfp2si(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	descDst, okDesc := arm64RegMap[dstReg]
	isDouble := (inst.Inst.Op == x86asm.CVTSD2SI || inst.Inst.Op == x86asm.CVTTSD2SI ||
		inst.Inst.Op == x86asm.VCVTSD2SI || inst.Inst.Op == x86asm.VCVTTSD2SI)

	if !okDst || !okDesc {
		lines = append(lines, l.emitUnsupported(inst, "unsupported cvtfp2si dst")...)
		return lines, nil
	}

	src := inst.Inst.Args[1]
	if srcReg, okSrc := src.(x86asm.Reg); okSrc {
		if _, _, _, _, _, sLowS, sLowD, okS := getVectorDesc(srcReg); okS {
			if isDouble {
				if descDst.Size == 4 {
					lines = append(lines, fmt.Sprintf("    fcvtzs %s, %s", descDst.W, sLowD))
				} else {
					lines = append(lines, fmt.Sprintf("    fcvtzs %s, %s", descDst.X, sLowD))
				}
			} else {
				if descDst.Size == 4 {
					lines = append(lines, fmt.Sprintf("    fcvtzs %s, %s", descDst.W, sLowS))
				} else {
					lines = append(lines, fmt.Sprintf("    fcvtzs %s, %s", descDst.X, sLowS))
				}
			}
			return lines, nil
		}
	} else if mem, okMem := src.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		if isDouble {
			lines = append(lines, "    ldr d30, [x28, x16]")
			if descDst.Size == 4 {
				lines = append(lines, fmt.Sprintf("    fcvtzs %s, d30", descDst.W))
			} else {
				lines = append(lines, fmt.Sprintf("    fcvtzs %s, d30", descDst.X))
			}
		} else {
			lines = append(lines, "    ldr s30, [x28, x16]")
			if descDst.Size == 4 {
				lines = append(lines, fmt.Sprintf("    fcvtzs %s, s30", descDst.W))
			} else {
				lines = append(lines, fmt.Sprintf("    fcvtzs %s, s30", descDst.X))
			}
		}
		return lines, nil
	}

	lines = append(lines, l.emitUnsupported(inst, "unsupported cvtfp2si src")...)
	return lines, nil
}

// liftFpConvert handles CVTSS2SD, CVTSD2SS, VCVTSS2SD, and VCVTSD2SS.
func (l *Arm64Lifter) liftFpConvert(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	_, _, _, dLowV, dHighV, dLowS, dLowD, okD := getVectorDesc(dstReg)
	if !okDst || !okD {
		lines = append(lines, l.emitUnsupported(inst, "unsupported fp convert dst")...)
		return lines, nil
	}

	isSS2SD := (inst.Inst.Op == x86asm.CVTSS2SD || inst.Inst.Op == x86asm.VCVTSS2SD)
	isAvx := (inst.Inst.Op == x86asm.VCVTSS2SD || inst.Inst.Op == x86asm.VCVTSD2SS)

	var s1LowV string
	var src2 x86asm.Arg
	if isAvx {
		if src1Reg, okS1 := inst.Inst.Args[1].(x86asm.Reg); okS1 {
			if _, _, _, sLowV, _, _, _, okDesc := getVectorDesc(src1Reg); okDesc {
				s1LowV = sLowV
			}
		}
		src2 = inst.Inst.Args[2]
	} else {
		src2 = inst.Inst.Args[1]
	}

	if !isAvx {
		if srcReg, okSrc := src2.(x86asm.Reg); okSrc {
			if _, _, _, _, _, sLowS, sLowD, okXS := getVectorDesc(srcReg); okXS {
				if isSS2SD {
					lines = append(lines, fmt.Sprintf("    fcvt %s, %s", dLowD, sLowS))
				} else {
					lines = append(lines, fmt.Sprintf("    fcvt %s, %s", dLowS, sLowD))
				}
				return lines, nil
			}
		} else if mem, okMem := src2.(x86asm.Mem); okMem {
			lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
			if isSS2SD {
				lines = append(lines, "    ldr s31, [x28, x16]")
				lines = append(lines, fmt.Sprintf("    fcvt %s, s31", dLowD))
			} else {
				lines = append(lines, "    ldr d31, [x28, x16]")
				lines = append(lines, fmt.Sprintf("    fcvt %s, d31", dLowS))
			}
			return lines, nil
		}
		lines = append(lines, l.emitUnsupported(inst, "unsupported fp convert operand")...)
		return lines, nil
	}

	// AVX path
	if srcReg, okSrc := src2.(x86asm.Reg); okSrc {
		if _, _, _, _, _, sLowS, sLowD, okXS := getVectorDesc(srcReg); okXS {
			if isSS2SD {
				lines = append(lines, fmt.Sprintf("    fcvt d30, %s", sLowS))
			} else {
				lines = append(lines, fmt.Sprintf("    fcvt s30, %s", sLowD))
			}
		} else {
			lines = append(lines, l.emitUnsupported(inst, "unsupported fp convert src reg")...)
			return lines, nil
		}
	} else if mem, okMem := src2.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		if isSS2SD {
			lines = append(lines, "    ldr s31, [x28, x16]")
			lines = append(lines, "    fcvt d30, s31")
		} else {
			lines = append(lines, "    ldr d31, [x28, x16]")
			lines = append(lines, "    fcvt s30, d31")
		}
	} else {
		lines = append(lines, l.emitUnsupported(inst, "unsupported fp convert operand")...)
		return lines, nil
	}

	if s1LowV != "" && dLowV != s1LowV {
		lines = append(lines, fmt.Sprintf("    mov %s.16b, %s.16b", dLowV, s1LowV))
	}
	if isSS2SD {
		lines = append(lines, fmt.Sprintf("    mov %s.d[0], v30.d[0]", dLowV))
	} else {
		lines = append(lines, fmt.Sprintf("    mov %s.s[0], v30.s[0]", dLowV))
	}
	lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
	return lines, nil
}

// liftAvxScalarMove handles VMOVSS and VMOVSD.
func (l *Arm64Lifter) liftAvxScalarMove(inst disasm.Instruction, nextPC uint64, isDouble bool, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	// Mem <- Reg
	if mem, okMem := dst.(x86asm.Mem); okMem {
		if srcReg, okSrc := src.(x86asm.Reg); okSrc {
			if _, _, _, _, _, sLowS, sLowD, okS := getVectorDesc(srcReg); okS {
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				if isDouble {
					lines = append(lines, fmt.Sprintf("    str %s, [x28, x16]", sLowD))
				} else {
					lines = append(lines, fmt.Sprintf("    str %s, [x28, x16]", sLowS))
				}
				return lines, nil
			}
		}
	}

	// Reg <- Mem (load scalar and zero upper bits)
	if dstReg, okDst := dst.(x86asm.Reg); okDst {
		if _, _, _, dLowV, dHighV, dLowS, dLowD, okD := getVectorDesc(dstReg); okD {
			if mem, okMem := src.(x86asm.Mem); okMem {
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dLowV))
				if isDouble {
					lines = append(lines, fmt.Sprintf("    ldr %s, [x28, x16]", dLowD))
				} else {
					lines = append(lines, fmt.Sprintf("    ldr %s, [x28, x16]", dLowS))
				}
				lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
				return lines, nil
			}
			// Reg <- Reg, Reg (3 operands: dst = [src1[1..3], src2[0]])
			if len(inst.Inst.Args) >= 3 && inst.Inst.Args[2] != nil {
				src1 := inst.Inst.Args[1]
				src2 := inst.Inst.Args[2]
				if s1Reg, ok1 := src1.(x86asm.Reg); ok1 {
					if s2Reg, ok2 := src2.(x86asm.Reg); ok2 {
						if _, _, _, s1LowV, _, _, _, okS1 := getVectorDesc(s1Reg); okS1 {
							if _, _, _, s2LowV, _, _, _, okS2 := getVectorDesc(s2Reg); okS2 {
								lines = append(lines, fmt.Sprintf("    mov %s.16b, %s.16b", dLowV, s1LowV))
								if isDouble {
									lines = append(lines, fmt.Sprintf("    mov %s.d[0], %s.d[0]", dLowV, s2LowV))
								} else {
									lines = append(lines, fmt.Sprintf("    mov %s.s[0], %s.s[0]", dLowV, s2LowV))
								}
								lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
								return lines, nil
							}
						}
					}
				}
			}
			// Reg <- Reg (2 operands: copy low element)
			if srcReg, okSrc := src.(x86asm.Reg); okSrc {
				if _, _, _, sLowV, _, _, _, okS := getVectorDesc(srcReg); okS {
					lines = append(lines, fmt.Sprintf("    mov %s.16b, %s.16b", dLowV, sLowV))
					lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
					return lines, nil
				}
			}
		}
	}

	lines = append(lines, l.emitUnsupported(inst, "unsupported avx scalar move")...)
	return lines, nil
}

// liftAvxScalarAlu handles 3-operand scalar float ALU (VADDSS, VMULSS, VSUBSS, VDIVSS, VADDSD, VMULSD, VSUBSD, VDIVSD).
func (l *Arm64Lifter) liftAvxScalarAlu(inst disasm.Instruction, nextPC uint64, armOp string, isDouble bool, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	src1Reg, okSrc1 := inst.Inst.Args[1].(x86asm.Reg)
	src2 := inst.Inst.Args[2]

	_, _, _, dLowV, dHighV, dLowS, dLowD, okD := getVectorDesc(dstReg)
	_, _, _, s1LowV, _, s1LowS, s1LowD, okS1 := getVectorDesc(src1Reg)
	if !okDst || !okSrc1 || !okD || !okS1 {
		lines = append(lines, l.emitUnsupported(inst, "unsupported avx scalar alu dst/src1")...)
		return lines, nil
	}

	s2S := "s30"
	s2D := "d30"
	if s2Reg, okSrc2 := src2.(x86asm.Reg); okSrc2 {
		if _, _, _, _, _, rS, rD, okS2 := getVectorDesc(s2Reg); okS2 {
			s2S = rS
			s2D = rD
		}
	} else if mem, okMem := src2.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		if isDouble {
			lines = append(lines, "    ldr d30, [x28, x16]")
		} else {
			lines = append(lines, "    ldr s30, [x28, x16]")
		}
	} else {
		lines = append(lines, l.emitUnsupported(inst, "unsupported avx scalar alu src2")...)
		return lines, nil
	}

	// Copy lanes 1..3 from src1 into dst
	lines = append(lines, fmt.Sprintf("    mov %s.16b, %s.16b", dLowV, s1LowV))
	if isDouble {
		lines = append(lines, fmt.Sprintf("    %s %s, %s, %s", armOp, dLowD, s1LowD, s2D))
	} else {
		lines = append(lines, fmt.Sprintf("    %s %s, %s, %s", armOp, dLowS, s1LowS, s2S))
	}
	lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
	return lines, nil
}

// liftRound handles ROUNDSD, ROUNDSS, VROUNDSD, VROUNDSS, ROUNDPS, ROUNDPD, VROUNDPS, and VROUNDPD.
func (l *Arm64Lifter) liftRound(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	isYmm, _, _, dLowV, dHighV, dLowS, dLowD, okD := getVectorDesc(dstReg)
	if !okDst || !okD {
		lines = append(lines, l.emitUnsupported(inst, "unsupported round dst")...)
		return lines, nil
	}

	isScalar := (op == x86asm.ROUNDSD || op == x86asm.VROUNDSD || op == x86asm.ROUNDSS || op == x86asm.VROUNDSS)
	isDouble := (op == x86asm.ROUNDSD || op == x86asm.VROUNDSD || op == x86asm.ROUNDPD || op == x86asm.VROUNDPD)
	isAvx := (op == x86asm.VROUNDSD || op == x86asm.VROUNDSS || op == x86asm.VROUNDPD || op == x86asm.VROUNDPS)

	var immVal uint8
	if isScalar {
		var s1LowV string
		var src2 x86asm.Arg
		var imm x86asm.Arg
		if isAvx {
			if s1Reg, okS1 := inst.Inst.Args[1].(x86asm.Reg); okS1 {
				if _, _, _, sLow, _, _, _, okDesc := getVectorDesc(s1Reg); okDesc {
					s1LowV = sLow
				}
			}
			src2 = inst.Inst.Args[2]
			imm = inst.Inst.Args[3]
		} else {
			src2 = inst.Inst.Args[1]
			imm = inst.Inst.Args[2]
		}

		immVal = uint8(imm.(x86asm.Imm))
		frintOp := "frintn"
		switch immVal & 3 {
		case 1:
			frintOp = "frintm" // floor
		case 2:
			frintOp = "frintp" // ceil
		case 3:
			frintOp = "frintz" // trunc
		}

		if srcReg, okSrc := src2.(x86asm.Reg); okSrc {
			if _, _, _, _, _, sLowS, sLowD, okDesc := getVectorDesc(srcReg); okDesc {
				if isDouble {
					lines = append(lines, fmt.Sprintf("    %s d30, %s", frintOp, sLowD))
				} else {
					lines = append(lines, fmt.Sprintf("    %s s30, %s", frintOp, sLowS))
				}
			}
		} else if mem, okMem := src2.(x86asm.Mem); okMem {
			lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
			if isDouble {
				lines = append(lines, "    ldr d30, [x28, x16]")
				lines = append(lines, fmt.Sprintf("    %s d30, d30", frintOp))
			} else {
				lines = append(lines, "    ldr s30, [x28, x16]")
				lines = append(lines, fmt.Sprintf("    %s s30, s30", frintOp))
			}
		} else {
			lines = append(lines, l.emitUnsupported(inst, "unsupported round src")...)
			return lines, nil
		}

		if isAvx {
			if s1LowV != "" && dLowV != s1LowV {
				lines = append(lines, fmt.Sprintf("    mov %s.16b, %s.16b", dLowV, s1LowV))
			}
			if isDouble {
				lines = append(lines, fmt.Sprintf("    mov %s.d[0], v30.d[0]", dLowV))
			} else {
				lines = append(lines, fmt.Sprintf("    mov %s.s[0], v30.s[0]", dLowV))
			}
			lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
		} else {
			if isDouble {
				lines = append(lines, fmt.Sprintf("    fmov %s, d30", dLowD))
			} else {
				lines = append(lines, fmt.Sprintf("    fmov %s, s30", dLowS))
			}
		}
		return lines, nil
	}

	// Vector packed ROUNDPS / VROUNDPS / ROUNDPD / VROUNDPD
	src2 := inst.Inst.Args[1]
	imm := inst.Inst.Args[2]
	immVal = uint8(imm.(x86asm.Imm))
	frintOp := "frintn"
	switch immVal & 3 {
	case 1:
		frintOp = "frintm" // floor
	case 2:
		frintOp = "frintp" // ceil
	case 3:
		frintOp = "frintz" // trunc
	}

	lane := ".4s"
	if isDouble {
		lane = ".2d"
	}

	s2LowV := "v30"
	s2HighV := "v31"
	if srcReg, okSrc := src2.(x86asm.Reg); okSrc {
		if _, _, _, rLowV, rHighV, _, _, okDesc := getVectorDesc(srcReg); okDesc {
			s2LowV = rLowV
			s2HighV = rHighV
		}
	} else if mem, okMem := src2.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		lines = append(lines, "    ldr q30, [x28, x16]")
		if isYmm {
			lines = append(lines, "    add x16, x16, #16", "    ldr q31, [x28, x16]")
		}
	} else {
		lines = append(lines, l.emitUnsupported(inst, "unsupported packed round src")...)
		return lines, nil
	}

	lines = append(lines, fmt.Sprintf("    %s %s%s, %s%s", frintOp, dLowV, lane, s2LowV, lane))
	if isYmm {
		lines = append(lines, fmt.Sprintf("    %s %s%s, %s%s", frintOp, dHighV, lane, s2HighV, lane))
	} else if isAvx {
		lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
	}
	return lines, nil
}

// liftVhsub handles HSUBPS, VHSUBPS, HSUBPD, and VHSUBPD.
func (l *Arm64Lifter) liftVhsub(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	isYmm, _, _, dLowV, dHighV, _, _, okD := getVectorDesc(dstReg)
	if !okDst || !okD {
		lines = append(lines, l.emitUnsupported(inst, "unsupported vhsub dst")...)
		return lines, nil
	}

	isDouble := (op == x86asm.HSUBPD || op == x86asm.VHSUBPD)
	isAvx := (op == x86asm.VHSUBPS || op == x86asm.VHSUBPD)

	var s1LowV, s1HighV string
	var src2 x86asm.Arg
	if isAvx {
		if s1Reg, okS1 := inst.Inst.Args[1].(x86asm.Reg); okS1 {
			_, _, _, sLow, sHigh, _, _, _ := getVectorDesc(s1Reg)
			s1LowV = sLow
			s1HighV = sHigh
		}
		src2 = inst.Inst.Args[2]
	} else {
		s1LowV = dLowV
		s1HighV = dHighV
		src2 = inst.Inst.Args[1]
	}

	s2LowV := "v30"
	s2HighV := "v31"
	if s2Reg, okSrc2 := src2.(x86asm.Reg); okSrc2 {
		if _, _, _, rLowV, rHighV, _, _, okS2 := getVectorDesc(s2Reg); okS2 {
			s2LowV = rLowV
			s2HighV = rHighV
		}
	} else if mem, okMem := src2.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		lines = append(lines, "    ldr q30, [x28, x16]")
		if isYmm {
			lines = append(lines, "    add x16, x16, #16", "    ldr q31, [x28, x16]")
		}
	} else {
		lines = append(lines, l.emitUnsupported(inst, "unsupported vhsub src2")...)
		return lines, nil
	}

	lane := ".4s"
	if isDouble {
		lane = ".2d"
	}

	lines = append(lines,
		fmt.Sprintf("    uzp1 v28%s, %s%s, %s%s", lane, s1LowV, lane, s2LowV, lane),
		fmt.Sprintf("    uzp2 v29%s, %s%s, %s%s", lane, s1LowV, lane, s2LowV, lane),
		fmt.Sprintf("    fsub %s%s, v28%s, v29%s", dLowV, lane, lane, lane),
	)
	if isYmm {
		lines = append(lines,
			fmt.Sprintf("    uzp1 v28%s, %s%s, %s%s", lane, s1HighV, lane, s2HighV, lane),
			fmt.Sprintf("    uzp2 v29%s, %s%s, %s%s", lane, s1HighV, lane, s2HighV, lane),
			fmt.Sprintf("    fsub %s%s, v28%s, v29%s", dHighV, lane, lane, lane),
		)
	} else if isAvx {
		lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
	}
	return lines, nil
}

// liftVphadd handles PHADDD, VPHADDD, PHADDW, and VPHADDW.
func (l *Arm64Lifter) liftVphadd(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	isYmm, _, _, dLowV, dHighV, _, _, okD := getVectorDesc(dstReg)
	if !okDst || !okD {
		lines = append(lines, l.emitUnsupported(inst, "unsupported vphadd dst")...)
		return lines, nil
	}

	isWord := (op == x86asm.PHADDW || op == x86asm.VPHADDW)
	isAvx := (op == x86asm.VPHADDD || op == x86asm.VPHADDW)

	var s1LowV, s1HighV string
	var src2 x86asm.Arg
	if isAvx {
		if s1Reg, okS1 := inst.Inst.Args[1].(x86asm.Reg); okS1 {
			_, _, _, sLow, sHigh, _, _, _ := getVectorDesc(s1Reg)
			s1LowV = sLow
			s1HighV = sHigh
		}
		src2 = inst.Inst.Args[2]
	} else {
		s1LowV = dLowV
		s1HighV = dHighV
		src2 = inst.Inst.Args[1]
	}

	s2LowV := "v30"
	s2HighV := "v31"
	if s2Reg, okSrc2 := src2.(x86asm.Reg); okSrc2 {
		if _, _, _, rLowV, rHighV, _, _, okS2 := getVectorDesc(s2Reg); okS2 {
			s2LowV = rLowV
			s2HighV = rHighV
		}
	} else if mem, okMem := src2.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		lines = append(lines, "    ldr q30, [x28, x16]")
		if isYmm {
			lines = append(lines, "    add x16, x16, #16", "    ldr q31, [x28, x16]")
		}
	} else {
		lines = append(lines, l.emitUnsupported(inst, "unsupported vphadd src2")...)
		return lines, nil
	}

	lane := ".4s"
	if isWord {
		lane = ".8h"
	}

	lines = append(lines, fmt.Sprintf("    addp %s%s, %s%s, %s%s", dLowV, lane, s1LowV, lane, s2LowV, lane))
	if isYmm {
		lines = append(lines, fmt.Sprintf("    addp %s%s, %s%s, %s%s", dHighV, lane, s1HighV, lane, s2HighV, lane))
	} else if isAvx {
		lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
	}
	return lines, nil
}

// liftAvxMinMax handles VMAXSD, VMINSD, VMAXSS, and VMINSS.
func (l *Arm64Lifter) liftAvxMinMax(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	s1Reg, okS1 := inst.Inst.Args[1].(x86asm.Reg)
	_, _, _, dLowV, dHighV, _, _, okD := getVectorDesc(dstReg)
	_, _, _, s1LowV, _, s1LowS, s1LowD, okS1D := getVectorDesc(s1Reg)
	if !okDst || !okS1 || !okD || !okS1D {
		lines = append(lines, l.emitUnsupported(inst, "unsupported avx min/max dst/src1")...)
		return lines, nil
	}

	isDouble := (op == x86asm.VMAXSD || op == x86asm.VMINSD)
	isMax := (op == x86asm.VMAXSD || op == x86asm.VMAXSS)
	armOp := "fmin"
	if isMax {
		armOp = "fmax"
	}

	src2 := inst.Inst.Args[2]
	if srcReg, okSrc := src2.(x86asm.Reg); okSrc {
		if _, _, _, _, _, s2LowS, s2LowD, okS2 := getVectorDesc(srcReg); okS2 {
			if isDouble {
				lines = append(lines, fmt.Sprintf("    %s d30, %s, %s", armOp, s1LowD, s2LowD))
			} else {
				lines = append(lines, fmt.Sprintf("    %s s30, %s, %s", armOp, s1LowS, s2LowS))
			}
		}
	} else if mem, okMem := src2.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		if isDouble {
			lines = append(lines, "    ldr d31, [x28, x16]")
			lines = append(lines, fmt.Sprintf("    %s d30, %s, d31", armOp, s1LowD))
		} else {
			lines = append(lines, "    ldr s31, [x28, x16]")
			lines = append(lines, fmt.Sprintf("    %s s30, %s, s31", armOp, s1LowS))
		}
	} else {
		lines = append(lines, l.emitUnsupported(inst, "unsupported avx min/max src2")...)
		return lines, nil
	}

	if dLowV != s1LowV {
		lines = append(lines, fmt.Sprintf("    mov %s.16b, %s.16b", dLowV, s1LowV))
	}
	if isDouble {
		lines = append(lines, fmt.Sprintf("    mov %s.d[0], v30.d[0]", dLowV))
	} else {
		lines = append(lines, fmt.Sprintf("    mov %s.s[0], v30.s[0]", dLowV))
	}
	lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
	return lines, nil
}

// liftAvxDoubleAlu handles VADDPD, VSUBPD, VMULPD, and VDIVPD.
func (l *Arm64Lifter) liftAvxDoubleAlu(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	armOp := "fadd"
	switch inst.Inst.Op {
	case x86asm.SUBPD, x86asm.VSUBPD:
		armOp = "fsub"
	case x86asm.MULPD, x86asm.VMULPD:
		armOp = "fmul"
	case x86asm.DIVPD, x86asm.VDIVPD:
		armOp = "fdiv"
	case x86asm.MAXPD, x86asm.VMAXPD:
		armOp = "fmax"
	case x86asm.MINPD, x86asm.VMINPD:
		armOp = "fmin"
	}

	var dstReg, s1Reg x86asm.Reg
	var src2 x86asm.Arg
	var okDst, okS1 bool
	isVex := false

	if len(inst.Inst.Args) >= 3 && inst.Inst.Args[2] != nil {
		isVex = true
		dstReg, okDst = inst.Inst.Args[0].(x86asm.Reg)
		s1Reg, okS1 = inst.Inst.Args[1].(x86asm.Reg)
		src2 = inst.Inst.Args[2]
	} else {
		dstReg, okDst = inst.Inst.Args[0].(x86asm.Reg)
		s1Reg = dstReg
		okS1 = okDst
		src2 = inst.Inst.Args[1]
	}

	isYmm, _, _, dLowV, dHighV, _, _, okD := getVectorDesc(dstReg)
	_, _, _, s1LowV, s1HighV, _, _, okS1D := getVectorDesc(s1Reg)
	if !okDst || !okS1 || !okD || !okS1D {
		lines = append(lines, l.emitUnsupported(inst, "unsupported avx double alu dst/src1")...)
		return lines, nil
	}

	s2LowV := "v30"
	s2HighV := "v31"
	if s2Reg, okSrc2 := src2.(x86asm.Reg); okSrc2 {
		if _, _, _, rLowV, rHighV, _, _, okS2 := getVectorDesc(s2Reg); okS2 {
			s2LowV = rLowV
			s2HighV = rHighV
		}
	} else if mem, okMem := src2.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		lines = append(lines, "    ldr q30, [x28, x16]")
		if isYmm {
			lines = append(lines, "    add x16, x16, #16")
			lines = append(lines, "    ldr q31, [x28, x16]")
		}
	} else {
		lines = append(lines, l.emitUnsupported(inst, "unsupported avx double alu src2")...)
		return lines, nil
	}

	lines = append(lines, fmt.Sprintf("    %s %s.2d, %s.2d, %s.2d", armOp, dLowV, s1LowV, s2LowV))
	if isYmm {
		lines = append(lines, fmt.Sprintf("    %s %s.2d, %s.2d, %s.2d", armOp, dHighV, s1HighV, s2HighV))
	} else if isVex {
		lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
	}
	return lines, nil
}

// liftVhadd handles VHADDPD and VHADDPS.
func (l *Arm64Lifter) liftVhadd(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	s1Reg, okS1 := inst.Inst.Args[1].(x86asm.Reg)
	src2 := inst.Inst.Args[2]

	isYmm, _, _, dLowV, dHighV, _, _, okD := getVectorDesc(dstReg)
	_, _, _, s1LowV, s1HighV, _, _, okS1D := getVectorDesc(s1Reg)
	if !okDst || !okS1 || !okD || !okS1D {
		lines = append(lines, l.emitUnsupported(inst, "unsupported vhadd dst/src1")...)
		return lines, nil
	}

	lane := ".2d"
	if op == x86asm.VHADDPS {
		lane = ".4s"
	}

	s2LowV := "v30"
	s2HighV := "v31"
	if s2Reg, okSrc2 := src2.(x86asm.Reg); okSrc2 {
		if _, _, _, rLowV, rHighV, _, _, okS2 := getVectorDesc(s2Reg); okS2 {
			s2LowV = rLowV
			s2HighV = rHighV
		}
	} else if mem, okMem := src2.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		lines = append(lines, "    ldr q30, [x28, x16]")
		if isYmm {
			lines = append(lines, "    add x16, x16, #16")
			lines = append(lines, "    ldr q31, [x28, x16]")
		}
	} else {
		lines = append(lines, l.emitUnsupported(inst, "unsupported vhadd src2")...)
		return lines, nil
	}

	lines = append(lines, fmt.Sprintf("    faddp %s%s, %s%s, %s%s", dLowV, lane, s1LowV, lane, s2LowV, lane))
	if isYmm {
		lines = append(lines, fmt.Sprintf("    faddp %s%s, %s%s, %s%s", dHighV, lane, s1HighV, lane, s2HighV, lane))
	} else {
		lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
	}
	return lines, nil
}

// liftSqrt handles scalar and packed square root operations.
func (l *Arm64Lifter) liftSqrt(inst disasm.Instruction, isDouble, isScalar, isRsqrt bool, nextPC uint64, lines []string) ([]string, error) {
	var dstReg, src1Reg x86asm.Reg
	var src2 x86asm.Arg
	isVex := false

	if isScalar {
		if len(inst.Inst.Args) >= 3 && inst.Inst.Args[2] != nil {
			isVex = true
			dstReg, _ = inst.Inst.Args[0].(x86asm.Reg)
			src1Reg, _ = inst.Inst.Args[1].(x86asm.Reg)
			src2 = inst.Inst.Args[2]
		} else {
			dstReg, _ = inst.Inst.Args[0].(x86asm.Reg)
			src1Reg = dstReg
			src2 = inst.Inst.Args[1]
		}

		_, _, _, dLowV, dHighV, _, _, okD := getVectorDesc(dstReg)
		_, _, _, s1LowV, _, _, _, okS1 := getVectorDesc(src1Reg)
		if !okD || !okS1 {
			lines = append(lines, l.emitUnsupported(inst, "sqrt scalar invalid dst")...)
			return lines, nil
		}

		// Read src2 into v16 scalar
		if mem, okMem := src2.(x86asm.Mem); okMem {
			lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
			if isDouble {
				lines = append(lines, "    ldr d16, [x28, x16]")
			} else {
				lines = append(lines, "    ldr s16, [x28, x16]")
			}
		} else if srcReg, okSrc := src2.(x86asm.Reg); okSrc {
			if _, _, _, s2LowV, _, _, _, okS2 := getVectorDesc(srcReg); okS2 {
				if isDouble {
					lines = append(lines, fmt.Sprintf("    mov v16.d[0], %s.d[0]", s2LowV))
				} else {
					lines = append(lines, fmt.Sprintf("    mov v16.s[0], %s.s[0]", s2LowV))
				}
			} else {
				lines = append(lines, l.emitUnsupported(inst, "sqrt invalid src2 reg")...)
				return lines, nil
			}
		}

		// Perform sqrt
		if isDouble {
			lines = append(lines, "    fsqrt d16, d16")
		} else if isRsqrt {
			lines = append(lines, "    frsqrte s16, s16")
		} else {
			lines = append(lines, "    fsqrt s16, s16")
		}

		// Copy s1 to dst if different
		if dLowV != s1LowV {
			lines = append(lines, fmt.Sprintf("    mov %s.16b, %s.16b", dLowV, s1LowV))
		}

		if isDouble {
			lines = append(lines, fmt.Sprintf("    mov %s.d[0], v16.d[0]", dLowV))
		} else {
			lines = append(lines, fmt.Sprintf("    mov %s.s[0], v16.s[0]", dLowV))
		}

		if isVex {
			lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
		}
		return lines, nil
	}

	// Packed SQRT
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	src2 = inst.Inst.Args[1]
	isYmm, _, _, dLowV, dHighV, _, _, okD := getVectorDesc(dstReg)
	if !okDst || !okD {
		lines = append(lines, l.emitUnsupported(inst, "packed sqrt invalid dst")...)
		return lines, nil
	}

	var s2Low, s2High string
	if mem, okMem := src2.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		lines = append(lines, "    ldr q16, [x28, x16]")
		s2Low = "v16"
		if isYmm {
			lines = append(lines, "    add x17, x16, #16")
			lines = append(lines, "    ldr q17, [x28, x17]")
			s2High = "v17"
		}
	} else if srcReg, okSrc := src2.(x86asm.Reg); okSrc {
		if _, _, _, sLowV, sHighV, _, _, okS := getVectorDesc(srcReg); okS {
			s2Low = sLowV
			s2High = sHighV
		} else {
			lines = append(lines, l.emitUnsupported(inst, "packed sqrt invalid src reg")...)
			return lines, nil
		}
	}

	op := "fsqrt"
	if isRsqrt {
		op = "frsqrte"
	}

	suffix := ".4s"
	if isDouble {
		suffix = ".2d"
	}

	lines = append(lines, fmt.Sprintf("    %s %s%s, %s%s", op, dLowV, suffix, s2Low, suffix))
	if isYmm {
		lines = append(lines, fmt.Sprintf("    %s %s%s, %s%s", op, dHighV, suffix, s2High, suffix))
	} else {
		op := inst.Inst.Op
		if op == x86asm.VSQRTPS || op == x86asm.VSQRTPD || op == x86asm.VRSQRTPS {
			lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
		}
	}

	return lines, nil
}

// liftCvtdq handles conversions between float, double, int, and half-precision.
func (l *Arm64Lifter) liftCvtdq(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]
	if len(inst.Inst.Args) >= 3 && inst.Inst.Args[2] != nil && op != x86asm.VCVTPS2PH {
		src = inst.Inst.Args[2]
	}

	isAvx := (op == x86asm.VCVTDQ2PS || op == x86asm.VCVTTPS2DQ || op == x86asm.VCVTPS2DQ || op == x86asm.VCVTPD2PS ||
		op == x86asm.VCVTPS2PD || op == x86asm.VCVTTPD2DQ || op == x86asm.VCVTDQ2PD || op == x86asm.VCVTPH2PS || op == x86asm.VCVTPS2PH)

	// Special handling for VCVTPS2PH mem destination
	if op == x86asm.VCVTPS2PH {
		if memDst, okMem := dst.(x86asm.Mem); okMem {
			sReg, okSrc := src.(x86asm.Reg)
			if isY, _, _, sL, sH, _, _, okS := getVectorDesc(sReg); okSrc && okS {
				lines = append(lines, computeEffAddr(memDst, nextPC, "x16")...)
				if isY {
					lines = append(lines,
						fmt.Sprintf("    fcvtn v28.4h, %s.4s", sL),
						fmt.Sprintf("    fcvtn2 v28.8h, %s.4s", sH),
						"    str q28, [x28, x16]",
					)
				} else {
					lines = append(lines,
						fmt.Sprintf("    fcvtn v28.4h, %s.4s", sL),
						"    str d28, [x28, x16]",
					)
				}
				return lines, nil
			}
		}
	}

	dstReg, okDst := dst.(x86asm.Reg)
	dstYmm, _, _, dLowV, dHighV, _, _, okD := getVectorDesc(dstReg)
	if !okDst || !okD {
		lines = append(lines, l.emitUnsupported(inst, "unsupported cvtdq dst")...)
		return lines, nil
	}

	srcYmm := false
	sLowV := "v30"
	sHighV := "v31"
	if sReg, okSrc := src.(x86asm.Reg); okSrc {
		if ymm, _, _, rLowV, rHighV, _, _, okS := getVectorDesc(sReg); okS {
			srcYmm = ymm
			sLowV = rLowV
			sHighV = rHighV
		}
	} else if mem, okMem := src.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		mem64 := (!dstYmm && (op == x86asm.CVTPS2PD || op == x86asm.VCVTPS2PD ||
			op == x86asm.CVTDQ2PD || op == x86asm.VCVTDQ2PD || op == x86asm.VCVTPH2PS))
		if mem64 {
			lines = append(lines, "    ldr d30, [x28, x16]")
		} else {
			lines = append(lines, "    ldr q30, [x28, x16]")
			if (op == x86asm.CVTTPD2DQ || op == x86asm.VCVTTPD2DQ || op == x86asm.CVTPD2PS || op == x86asm.VCVTPD2PS) {
				// If AVX instruction operating on YMM memory (256-bit to 128-bit)
				// For memory operands, x86asm doesn't have YMM register for src, but we check if dst is YMM or prefix is 256-bit
				// But CVTTPD2DQ destination is XMM! We check if operand has 256-bit attribute or inst is 256-bit
			}
		}
	} else {
		lines = append(lines, l.emitUnsupported(inst, "unsupported cvtdq src")...)
		return lines, nil
	}

	isYmm := dstYmm || srcYmm

	switch op {
	case x86asm.CVTDQ2PS, x86asm.VCVTDQ2PS:
		lines = append(lines, fmt.Sprintf("    scvtf %s.4s, %s.4s", dLowV, sLowV))
		if isYmm {
			lines = append(lines, fmt.Sprintf("    scvtf %s.4s, %s.4s", dHighV, sHighV))
		} else if isAvx {
			lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
		}

	case x86asm.CVTTPS2DQ, x86asm.VCVTTPS2DQ:
		lines = append(lines, fmt.Sprintf("    fcvtzs %s.4s, %s.4s", dLowV, sLowV))
		if isYmm {
			lines = append(lines, fmt.Sprintf("    fcvtzs %s.4s, %s.4s", dHighV, sHighV))
		} else if isAvx {
			lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
		}

	case x86asm.CVTPS2DQ, x86asm.VCVTPS2DQ:
		lines = append(lines, fmt.Sprintf("    frintn v28.4s, %s.4s", sLowV))
		lines = append(lines, fmt.Sprintf("    fcvtzs %s.4s, v28.4s", dLowV))
		if isYmm {
			lines = append(lines, fmt.Sprintf("    frintn v28.4s, %s.4s", sHighV))
			lines = append(lines, fmt.Sprintf("    fcvtzs %s.4s, v28.4s", dHighV))
		} else if isAvx {
			lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
		}

	case x86asm.CVTPD2PS, x86asm.VCVTPD2PS:
		lines = append(lines, fmt.Sprintf("    fcvtn %s.2s, %s.2d", dLowV, sLowV))
		if isYmm {
			lines = append(lines, fmt.Sprintf("    fcvtn2 %s.4s, %s.2d", dLowV, sHighV))
		} else {
			lines = append(lines, fmt.Sprintf("    mov %s.d[1], xzr", dLowV))
		}
		if isAvx {
			lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
		}

	case x86asm.CVTPS2PD, x86asm.VCVTPS2PD:
		lines = append(lines, fmt.Sprintf("    fcvtl %s.2d, %s.2s", dLowV, sLowV))
		if isYmm {
			lines = append(lines, fmt.Sprintf("    fcvtl2 %s.2d, %s.4s", dHighV, sLowV))
		} else if isAvx {
			lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
		}

	case x86asm.CVTTPD2DQ, x86asm.VCVTTPD2DQ:
		lines = append(lines,
			fmt.Sprintf("    fcvtzs v28.2d, %s.2d", sLowV),
			fmt.Sprintf("    fcvtn %s.2s, v28.2d", dLowV),
		)
		if isYmm {
			lines = append(lines,
				fmt.Sprintf("    fcvtzs v29.2d, %s.2d", sHighV),
				fmt.Sprintf("    fcvtn2 %s.4s, v29.2d", dLowV),
			)
		} else {
			lines = append(lines, fmt.Sprintf("    mov %s.d[1], xzr", dLowV))
		}
		if isAvx {
			lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
		}

	case x86asm.CVTDQ2PD, x86asm.VCVTDQ2PD:
		if isYmm {
			lines = append(lines,
				fmt.Sprintf("    scvtf v28.4s, %s.4s", sLowV),
				fmt.Sprintf("    fcvtl %s.2d, v28.2s", dLowV),
				fmt.Sprintf("    fcvtl2 %s.2d, v28.4s", dHighV),
			)
		} else {
			lines = append(lines,
				fmt.Sprintf("    scvtf v28.2s, %s.2s", sLowV),
				fmt.Sprintf("    fcvtl %s.2d, v28.2s", dLowV),
			)
			if isAvx {
				lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
			}
		}

	case x86asm.VCVTPH2PS:
		lines = append(lines, fmt.Sprintf("    fcvtl %s.4s, %s.4h", dLowV, sLowV))
		if isYmm {
			lines = append(lines, fmt.Sprintf("    fcvtl2 %s.4s, %s.8h", dHighV, sLowV))
		} else {
			lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
		}

	case x86asm.VCVTPS2PH:
		lines = append(lines, fmt.Sprintf("    fcvtn %s.4h, %s.4s", dLowV, sLowV))
		if isYmm {
			lines = append(lines, fmt.Sprintf("    fcvtn2 %s.8h, %s.4s", dLowV, sHighV))
		} else {
			lines = append(lines, fmt.Sprintf("    mov %s.d[1], xzr", dLowV))
		}
		lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
	}

	return lines, nil
}
