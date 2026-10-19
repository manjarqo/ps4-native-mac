package lifter

import (
	"fmt"

	"ps4-recomp/pkg/disasm"

	"golang.org/x/arch/x86/x86asm"
)

// liftFpu handles x87 FPU stack instructions for the ARM64 assembly backend. The stack values
// are worked on in d27-d29 (d0-d15 are XMM0-XMM15, which x87 code must not change).
// In the assembly runtime:
// GuestContext pointer is in global _g_current_guest_ctx.
// fpu_stack is at offset 0x2a0 (8 doubles = 64 bytes).
// fpu_top is at offset 0x2e0 (int32).
// fpu_sw is at offset 0x2e6 (uint16).
// fpu_cw is at offset 0x2e4 (uint16).
func (l *Arm64Lifter) liftFpu(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	args := inst.Inst.Args
	defMemSz := defMemSz(inst)

	// Helper to load context pointer into a GPR (e.g. x16)
	loadCtxPtr := func(reg string) []string {
		return []string{
			fmt.Sprintf("    add  %s, x27, #0x70", reg),
			fmt.Sprintf("    ldr  %s, [x28, %s]", reg, reg),
		}
	}

	// Helper to emit fpu_push(double in d28)
	// top = (top - 1) & 7
	// stack[top] = val
	emitFpuPushD0 := func() []string {
		var code []string
		code = append(code, loadCtxPtr("x16")...)
		code = append(code,
			"    ldr  w17, [x16, #0x2e0]",     // w17 = fpu_top
			"    sub  w17, w17, #1",           // w17 = top - 1
			"    and  w17, w17, #7",           // w17 = (top - 1) & 7
			"    str  w17, [x16, #0x2e0]",     // update fpu_top
			"    add  x5, x16, #0x2a0",       // x5 = &fpu_stack[0]
			"    str  d28, [x5, w17, uxtw #3]", // fpu_stack[top] = d28
		)
		return code
	}

	// Helper to emit fpu_pop() -> result in d28
	// val = stack[top]
	// top = (top + 1) & 7
	emitFpuPopD0 := func() []string {
		var code []string
		code = append(code, loadCtxPtr("x16")...)
		code = append(code,
			"    ldr  w17, [x16, #0x2e0]",     // w17 = fpu_top
			"    add  x5, x16, #0x2a0",       // x5 = &fpu_stack[0]
			"    ldr  d28, [x5, w17, uxtw #3]", // d28 = fpu_stack[top]
			"    add  w17, w17, #1",           // w17 = top + 1
			"    and  w17, w17, #7",           // w17 = (top + 1) & 7
			"    str  w17, [x16, #0x2e0]",     // update fpu_top
		)
		return code
	}

	// Helper to read FPU ST(idx) into a target float reg (e.g. d28, d29)
	loadFpuSt := func(targetD string, idx int) []string {
		var code []string
		code = append(code, loadCtxPtr("x16")...)
		code = append(code,
			"    ldr  w17, [x16, #0x2e0]",             // w17 = fpu_top
			fmt.Sprintf("    add  w17, w17, #%d", idx), // w17 = top + idx
			"    and  w17, w17, #7",                   // w17 = (top + idx) & 7
			"    add  x5, x16, #0x2a0",               // x5 = &fpu_stack[0]
			fmt.Sprintf("    ldr  %s, [x5, w17, uxtw #3]", targetD),
		)
		return code
	}

	// Helper to store a float reg (e.g. d28) into FPU ST(idx)
	storeFpuSt := func(srcD string, idx int) []string {
		var code []string
		code = append(code, loadCtxPtr("x16")...)
		code = append(code,
			"    ldr  w17, [x16, #0x2e0]",             // w17 = fpu_top
			fmt.Sprintf("    add  w17, w17, #%d", idx), // w17 = top + idx
			"    and  w17, w17, #7",                   // w17 = (top + idx) & 7
			"    add  x5, x16, #0x2a0",               // x5 = &fpu_stack[0]
			fmt.Sprintf("    str  %s, [x5, w17, uxtw #3]", srcD),
		)
		return code
	}

	// Discard top of FPU stack: fpu_top = (fpu_top + 1) & 7
	emitFpuDiscard := func() []string {
		var code []string
		code = append(code, loadCtxPtr("x16")...)
		code = append(code,
			"    ldr  w17, [x16, #0x2e0]",
			"    add  w17, w17, #1",
			"    and  w17, w17, #7",
			"    str  w17, [x16, #0x2e0]",
		)
		return code
	}

	switch op {
	case x86asm.FLDZ:
		lines = append(lines, "    fmov d28, xzr")
		lines = append(lines, emitFpuPushD0()...)
		return lines, nil

	case x86asm.FLD1:
		lines = append(lines, "    fmov d28, #1.0")
		lines = append(lines, emitFpuPushD0()...)
		return lines, nil

	case x86asm.FLD:
		if reg, ok := args[0].(x86asm.Reg); ok && reg >= x86asm.F0 && reg <= x86asm.F7 {
			idx := int(reg - x86asm.F0)
			lines = append(lines, loadFpuSt("d28", idx)...)
			lines = append(lines, emitFpuPushD0()...)
			return lines, nil
		}
		if mem, ok := args[0].(x86asm.Mem); ok {
			lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
			if defMemSz == 8 {
				lines = append(lines, "    ldr d28, [x28, x16]")
			} else {
				lines = append(lines,
					"    ldr s28, [x28, x16]",
					"    fcvt d28, s28",
				)
			}
			lines = append(lines, emitFpuPushD0()...)
			return lines, nil
		}

	case x86asm.FILD:
		if mem, ok := args[0].(x86asm.Mem); ok {
			lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
			if defMemSz == 8 {
				lines = append(lines,
					"    ldr x17, [x28, x16]",
					"    scvtf d28, x17",
				)
			} else if defMemSz == 2 {
				lines = append(lines,
					"    ldrsh w17, [x28, x16]",
					"    scvtf d28, w17",
				)
			} else {
				lines = append(lines,
					"    ldrsw x17, [x28, x16]",
					"    scvtf d28, x17",
				)
			}
			lines = append(lines, emitFpuPushD0()...)
			return lines, nil
		}

	case x86asm.FST, x86asm.FSTP:
		isPop := (op == x86asm.FSTP)
		if reg, ok := args[0].(x86asm.Reg); ok && reg >= x86asm.F0 && reg <= x86asm.F7 {
			idx := int(reg - x86asm.F0)
			lines = append(lines, loadFpuSt("d28", 0)...)
			if idx != 0 {
				lines = append(lines, storeFpuSt("d28", idx)...)
			}
			if isPop {
				lines = append(lines, emitFpuDiscard()...)
			}
			return lines, nil
		}
		if mem, ok := args[0].(x86asm.Mem); ok {
			// Read ST(0) before computing the address: the stack helpers use x16 for the
			// GuestContext pointer.
			lines = append(lines, loadFpuSt("d28", 0)...)
			if defMemSz == 8 {
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				lines = append(lines, "    str d28, [x28, x16]")
			} else {
				lines = append(lines, "    fcvt s28, d28")
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				lines = append(lines, "    str s28, [x28, x16]")
			}
			if isPop {
				lines = append(lines, emitFpuDiscard()...)
			}
			return lines, nil
		}

	case x86asm.FIST, x86asm.FISTP, x86asm.FISTTP:
		if mem, ok := args[0].(x86asm.Mem); ok {
			// Value first, address second (the stack helpers use x16), then the store.
			if op == x86asm.FIST {
				lines = append(lines, loadFpuSt("d28", 0)...)
			} else {
				lines = append(lines, emitFpuPopD0()...)
			}
			trunc := op == x86asm.FISTTP
			switch defMemSz {
			case 8:
				lines = append(lines, fpToIntX86("x17", "d28", trunc)...)
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				lines = append(lines, "    str x17, [x28, x16]")
			case 2:
				lines = append(lines, fpToInt16X86("w17", "d28", trunc)...)
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				lines = append(lines, "    strh w17, [x28, x16]")
			default:
				lines = append(lines, fpToIntX86("w17", "d28", trunc)...)
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				lines = append(lines, "    str w17, [x28, x16]")
			}
			return lines, nil
		}

	case x86asm.FXCH:
		idx := 1
		if len(args) > 0 {
			if reg, ok := args[0].(x86asm.Reg); ok && reg >= x86asm.F0 && reg <= x86asm.F7 {
				idx = int(reg - x86asm.F0)
			}
		}
		// Swap ST(0) and ST(idx)
		lines = append(lines, loadFpuSt("d28", 0)...)
		lines = append(lines, loadFpuSt("d29", idx)...)
		lines = append(lines, storeFpuSt("d29", 0)...)
		lines = append(lines, storeFpuSt("d28", idx)...)
		return lines, nil

	case x86asm.FCHS:
		lines = append(lines, loadFpuSt("d28", 0)...)
		lines = append(lines, "    fneg d28, d28")
		lines = append(lines, storeFpuSt("d28", 0)...)
		return lines, nil

	case x86asm.FABS:
		lines = append(lines, loadFpuSt("d28", 0)...)
		lines = append(lines, "    fabs d28, d28")
		lines = append(lines, storeFpuSt("d28", 0)...)
		return lines, nil

	case x86asm.FSQRT:
		lines = append(lines, loadFpuSt("d28", 0)...)
		lines = append(lines, "    fsqrt d28, d28")
		lines = append(lines, storeFpuSt("d28", 0)...)
		return lines, nil

	// Binary arithmetic: FADD, FADDP, FSUB, FSUBP, FSUBR, FSUBRP, FMUL, FMULP, FDIV, FDIVP, FDIVR, FDIVRP
	case x86asm.FADD, x86asm.FADDP,
		x86asm.FSUB, x86asm.FSUBP, x86asm.FSUBR, x86asm.FSUBRP,
		x86asm.FMUL, x86asm.FMULP,
		x86asm.FDIV, x86asm.FDIVP, x86asm.FDIVR, x86asm.FDIVRP:

		isPop := (op == x86asm.FADDP || op == x86asm.FSUBP || op == x86asm.FSUBRP ||
			op == x86asm.FMULP || op == x86asm.FDIVP || op == x86asm.FDIVRP)

		dstIdx := 0
		if isPop {
			dstIdx = 1
		}

		armFpOp := "fadd"
		isRev := false
		switch op {
		case x86asm.FADD, x86asm.FADDP:
			armFpOp = "fadd"
		case x86asm.FMUL, x86asm.FMULP:
			armFpOp = "fmul"
		case x86asm.FSUB, x86asm.FSUBP:
			armFpOp = "fsub"
		case x86asm.FSUBR, x86asm.FSUBRP:
			armFpOp = "fsub"
			isRev = true
		case x86asm.FDIV, x86asm.FDIVP:
			armFpOp = "fdiv"
		case x86asm.FDIVR, x86asm.FDIVRP:
			armFpOp = "fdiv"
			isRev = true
		}

		if len(args) > 0 && args[0] != nil {
			if reg0, ok0 := args[0].(x86asm.Reg); ok0 && reg0 >= x86asm.F0 && reg0 <= x86asm.F7 {
				dstIdx = int(reg0 - x86asm.F0)
				srcIdx := 0
				if len(args) > 1 && args[1] != nil {
					if reg1, ok1 := args[1].(x86asm.Reg); ok1 && reg1 >= x86asm.F0 && reg1 <= x86asm.F7 {
						srcIdx = int(reg1 - x86asm.F0)
					}
				}
				lines = append(lines, loadFpuSt("d28", dstIdx)...)
				lines = append(lines, loadFpuSt("d29", srcIdx)...)
				if isRev {
					lines = append(lines, fmt.Sprintf("    %s d28, d29, d28", armFpOp))
				} else {
					lines = append(lines, fmt.Sprintf("    %s d28, d28, d29", armFpOp))
				}
				lines = append(lines, storeFpuSt("d28", dstIdx)...)
				if isPop {
					lines = append(lines, emitFpuDiscard()...)
				}
				return lines, nil
			}

			if mem, okMem := args[0].(x86asm.Mem); okMem {
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				if defMemSz == 8 {
					lines = append(lines, "    ldr d29, [x28, x16]")
				} else {
					lines = append(lines,
						"    ldr s29, [x28, x16]",
						"    fcvt d29, s29",
					)
				}
				lines = append(lines, loadFpuSt("d28", 0)...)
				if isRev {
					lines = append(lines, fmt.Sprintf("    %s d28, d29, d28", armFpOp))
				} else {
					lines = append(lines, fmt.Sprintf("    %s d28, d28, d29", armFpOp))
				}
				lines = append(lines, storeFpuSt("d28", 0)...)
				if isPop {
					lines = append(lines, emitFpuDiscard()...)
				}
				return lines, nil
			}
		}

		// Default implicit ST(1) op ST(0)
		lines = append(lines, loadFpuSt("d28", 1)...)
		lines = append(lines, loadFpuSt("d29", 0)...)
		if isRev {
			lines = append(lines, fmt.Sprintf("    %s d28, d29, d28", armFpOp))
		} else {
			lines = append(lines, fmt.Sprintf("    %s d28, d28, d29", armFpOp))
		}
		lines = append(lines, storeFpuSt("d28", 1)...)
		if isPop {
			lines = append(lines, emitFpuDiscard()...)
		}
		return lines, nil

	// Integer arithmetic: FIADD, FISUB, FIMUL, FIDIV
	case x86asm.FIADD, x86asm.FISUB, x86asm.FIMUL, x86asm.FIDIV:
		if mem, ok := args[0].(x86asm.Mem); ok {
			lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
			if defMemSz == 2 {
				lines = append(lines,
					"    ldrsh w17, [x28, x16]",
					"    scvtf d29, w17",
				)
			} else {
				lines = append(lines,
					"    ldrsw x17, [x28, x16]",
					"    scvtf d29, x17",
				)
			}
			lines = append(lines, loadFpuSt("d28", 0)...)
			switch op {
			case x86asm.FIADD:
				lines = append(lines, "    fadd d28, d28, d29")
			case x86asm.FISUB:
				lines = append(lines, "    fsub d28, d28, d29")
			case x86asm.FIMUL:
				lines = append(lines, "    fmul d28, d28, d29")
			case x86asm.FIDIV:
				lines = append(lines, "    fdiv d28, d28, d29")
			}
			lines = append(lines, storeFpuSt("d28", 0)...)
			return lines, nil
		}

	// Comparisons setting EFLAGS: FUCOMI, FUCOMIP, FCOMI, FCOMIP
	case x86asm.FUCOMI, x86asm.FUCOMIP, x86asm.FCOMI:
		idx := 1
		if len(args) > 1 && args[1] != nil {
			if reg, ok := args[1].(x86asm.Reg); ok && reg >= x86asm.F0 && reg <= x86asm.F7 {
				idx = int(reg - x86asm.F0)
			}
		}
		lines = append(lines, loadFpuSt("d28", 0)...)
		lines = append(lines, loadFpuSt("d29", idx)...)
		// fcmp sets NZCV directly!
		// In ARM64:
		// EQ -> Z=1, C=1
		// LT -> C=0, Z=0
		// GT -> C=1, Z=0
		// Unordered -> V=1, C=1, Z=0
		lines = append(lines, "    fcmp d28, d29")
		lines = append(lines, l.fpCompareFlags()...)
		if op == x86asm.FUCOMIP {
			lines = append(lines, emitFpuDiscard()...)
		}
		return lines, nil

	// Conditional moves: FCMOVB, FCMOVE, FCMOVBE, FCMOVU, FCMOVNB, FCMOVNE, FCMOVNBE, FCMOVNU
	case x86asm.FCMOVB, x86asm.FCMOVE, x86asm.FCMOVBE, x86asm.FCMOVU,
		x86asm.FCMOVNB, x86asm.FCMOVNE, x86asm.FCMOVNBE, x86asm.FCMOVNU:
		// FCMOVcc ST(0), ST(i): the source is the second operand.
		idx := 1
		if len(args) > 1 {
			if reg, ok := args[1].(x86asm.Reg); ok && reg >= x86asm.F0 && reg <= x86asm.F7 {
				idx = int(reg - x86asm.F0)
			}
		}
		// x86 condition encoding (see x86CondIndex): B, AE, E, NE, BE, A, P, NP.
		cc := map[x86asm.Op]int{
			x86asm.FCMOVB: 2, x86asm.FCMOVNB: 3, x86asm.FCMOVE: 4, x86asm.FCMOVNE: 5,
			x86asm.FCMOVBE: 6, x86asm.FCMOVNBE: 7, x86asm.FCMOVU: 10, x86asm.FCMOVNU: 11,
		}[op]
		pre, cond := l.condFor(cc)
		lines = append(lines, pre...)
		lines = append(lines, loadFpuSt("d28", 0)...)
		lines = append(lines, loadFpuSt("d29", idx)...)
		lines = append(lines, fmt.Sprintf("    fcsel d28, d29, d28, %s", cond))
		lines = append(lines, storeFpuSt("d28", 0)...)
		return lines, nil

	// Status and Control Word
	case x86asm.FNSTSW:
		// Store FPU status word into AX or memory
		lines = append(lines, loadCtxPtr("x16")...)
		lines = append(lines,
			"    ldrh w17, [x16, #0x2e6]",     // w17 = fpu_sw
			"    ldr  w5, [x16, #0x2e0]",     // w5 = fpu_top
			"    and  w5, w5, #7",
			"    bic  w17, w17, #(7 << 11)",   // clear TOP bits
			"    orr  w17, w17, w5, lsl #11", // insert TOP bits
		)
		if reg, ok := args[0].(x86asm.Reg); ok && reg == x86asm.AX {
			lines = append(lines, "    bfi x19, x17, #0, #16") // AX is in x19
			return lines, nil
		}
		if mem, ok := args[0].(x86asm.Mem); ok {
			lines = append(lines, computeEffAddr(mem, nextPC, "x5")...)
			lines = append(lines, "    strh w17, [x28, x5]")
			return lines, nil
		}

	case x86asm.FLDCW:
		if mem, ok := args[0].(x86asm.Mem); ok {
			lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
			lines = append(lines, "    ldrh w17, [x28, x16]")
			lines = append(lines, loadCtxPtr("x5")...)
			lines = append(lines, "    strh w17, [x5, #0x2e4]")
			return lines, nil
		}

	case x86asm.FNSTCW:
		if mem, ok := args[0].(x86asm.Mem); ok {
			lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
			lines = append(lines, loadCtxPtr("x5")...)
			lines = append(lines,
				"    ldrh w17, [x5, #0x2e4]",
				"    strh w17, [x28, x16]",
			)
			return lines, nil
		}

	case x86asm.FNCLEX:
		lines = append(lines, loadCtxPtr("x16")...)
		lines = append(lines,
			"    ldrh w17, [x16, #0x2e6]",
			"    bic  w17, w17, #0x7f",
			"    strh w17, [x16, #0x2e6]",
		)
		return lines, nil

	case x86asm.FSCALE:
		lines = append(lines, loadFpuSt("d28", 0)...)
		lines = append(lines, loadFpuSt("d29", 1)...)
		lines = append(lines,
			"    frintz d29, d29",
			"    fcvtzs x16, d29",
			"    add   x16, x16, #1023",
			"    lsl   x16, x16, #52",
			"    fmov  d27, x16",
			"    fmul  d28, d28, d27",
		)
		lines = append(lines, storeFpuSt("d28", 0)...)
		return lines, nil

	case x86asm.FPREM, x86asm.FPREM1:
		lines = append(lines, loadFpuSt("d28", 0)...)
		lines = append(lines, loadFpuSt("d29", 1)...)
		lines = append(lines,
			"    fdiv   d27, d28, d29",
			"    frintn d27, d27",
			"    fnmsub d28, d27, d29, d28",
		)
		lines = append(lines, storeFpuSt("d28", 0)...)
		return lines, nil

	case x86asm.FFREE, x86asm.FFREEP:
		if op == x86asm.FFREEP {
			lines = append(lines, emitFpuDiscard()...)
		}
		return lines, nil

	case x86asm.FNSTENV:
		if mem, ok := args[0].(x86asm.Mem); ok {
			lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
			lines = append(lines, "    add  x16, x28, x16")
			lines = append(lines, loadCtxPtr("x5")...)
			lines = append(lines,
				"    ldrh w17, [x5, #0x2e4]",
				"    str  w17, [x16, #0]",
				"    ldrh w17, [x5, #0x2e6]",
				"    str  w17, [x16, #4]",
				"    mov  w17, #0xffff",
				"    str  w17, [x16, #8]",
			)
			return lines, nil
		}

	case x86asm.FLDENV:
		if mem, ok := args[0].(x86asm.Mem); ok {
			lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
			lines = append(lines, "    add  x16, x28, x16")
			lines = append(lines, loadCtxPtr("x5")...)
			lines = append(lines,
				"    ldrh w17, [x16, #0]",
				"    strh w17, [x5, #0x2e4]",
				"    ldrh w17, [x16, #4]",
				"    strh w17, [x5, #0x2e6]",
			)
			return lines, nil
		}

	case x86asm.FCOS:
		// Runtime call: cos() takes and returns its argument in d0 (and may clobber v0-v7 and
		// v16-v31; x87 helpers are Task 5's).
		lines = append(lines, loadFpuSt("d28", 0)...)
		lines = append(lines,
			"    fmov d0, d28",
			"    sub  sp, sp, #96",
			"    stp  x29, x30, [sp, #80]",
			"    add  x29, sp, #80",
			"    stp  x8,  x9,  [sp, #0]",
			"    stp  x10, x11, [sp, #16]",
			"    stp  x12, x13, [sp, #32]",
			"    stp  x14, x15, [sp, #48]",
			"    bl   _cos",
			"    ldp  x8,  x9,  [sp, #0]",
			"    ldp  x10, x11, [sp, #16]",
			"    ldp  x12, x13, [sp, #32]",
			"    ldp  x14, x15, [sp, #48]",
			"    ldp  x29, x30, [sp, #80]",
			"    add  sp, sp, #96",
			"    fmov d28, d0",
		)
		lines = append(lines, storeFpuSt("d28", 0)...)
		return lines, nil

	case x86asm.FLDL2T:
		lines = append(lines,
			"    movz x16, #0xa371",
			"    movk x16, #0x0979, lsl #16",
			"    movk x16, #0x934f, lsl #32",
			"    movk x16, #0x400a, lsl #48",
			"    fmov d28, x16",
		)
		lines = append(lines, emitFpuPushD0()...)
		return lines, nil

	case x86asm.FRNDINT:
		lines = append(lines, loadFpuSt("d28", 0)...)
		lines = append(lines, "    frinti d28, d28")
		lines = append(lines, storeFpuSt("d28", 0)...)
		return lines, nil

	case x86asm.FXTRACT:
		lines = append(lines, loadFpuSt("d28", 0)...)
		lines = append(lines,
			"    fmov d29, d28",
			"    fmov x16, d28",
			"    ubfx x17, x16, #52, #11",
			"    sub  x17, x17, #1023",
			"    scvtf d27, x17",
			"    movz x5, #1023",
			"    bfi  x16, x5, #52, #11",
			"    fmov d28, x16",
		)
		lines = append(lines, storeFpuSt("d28", 0)...)
		lines = append(lines, "    fmov d28, d27")
		lines = append(lines, emitFpuPushD0()...)
		return lines, nil

	case x86asm.FCOM, x86asm.FCOMP, x86asm.FCOMPP, x86asm.FICOM, x86asm.FICOMP:
		lines = append(lines, loadFpuSt("d28", 0)...)
		isInteger := (op == x86asm.FICOM || op == x86asm.FICOMP)
		if len(args) > 0 && args[0] != nil {
			if reg, ok := args[0].(x86asm.Reg); ok && reg >= x86asm.F0 && reg <= x86asm.F7 {
				lines = append(lines, loadFpuSt("d29", int(reg-x86asm.F0))...)
			} else if mem, ok := args[0].(x86asm.Mem); ok {
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				if isInteger {
					if defMemSz == 2 {
						lines = append(lines,
							"    ldrsh w17, [x28, x16]",
							"    scvtf d29, w17",
						)
					} else {
						lines = append(lines,
							"    ldr  w17, [x28, x16]",
							"    scvtf d29, w17",
						)
					}
				} else {
					if defMemSz == 4 {
						lines = append(lines,
							"    ldr  s29, [x28, x16]",
							"    fcvt d29, s29",
						)
					} else {
						lines = append(lines,
							"    ldr  d29, [x28, x16]",
						)
					}
				}
			}
		} else {
			lines = append(lines, loadFpuSt("d29", 1)...)
		}
		lines = append(lines, loadCtxPtr("x16")...)
		lines = append(lines,
			"    fcmp d28, d29",
			"    ldrh w17, [x16, #0x2e6]",
			"    movz w5, #0x4500",
			"    bic  w17, w17, w5",
			"    b.vs 1f",
			"    b.eq 2f",
			"    b.mi 3f",
			"    b    4f",
			"1:",
			"    orr  w17, w17, w5",
			"    b    4f",
			"2:",
			"    movz w5, #0x4000",
			"    orr  w17, w17, w5",
			"    b    4f",
			"3:",
			"    movz w5, #0x0100",
			"    orr  w17, w17, w5",
			"4:",
			"    strh w17, [x16, #0x2e6]",
		)
		if op == x86asm.FCOMP || op == x86asm.FICOMP {
			lines = append(lines, emitFpuDiscard()...)
		} else if op == x86asm.FCOMPP {
			lines = append(lines, emitFpuDiscard()...)
			lines = append(lines, emitFpuDiscard()...)
		}
		return lines, nil
	}

	lines = append(lines, l.emitUnsupported(inst, fmt.Sprintf("unsupported fpu: %v", op))...)
	return lines, nil
}

// fpToInt16X86 converts the double in src (d<n>) to int16 in dst (w register) with x86 FIST
// semantics: NaN and values outside [-32768, 32767] give the integer indefinite 0x8000. FISTTP
// truncates; FIST/FISTP round by the current mode. NZCV is not touched. Scratch: x1, x2, v30,
// v31.
func fpToInt16X86(dst, src string, trunc bool) []string {
	var out []string
	if !trunc {
		out = append(out, fmt.Sprintf("    frintx d31, %s", src))
		src = "d31"
	}
	x := "x" + dst[1:]
	out = append(out,
		fmt.Sprintf("    fcvtzs %s, %s", x, src),
		fmt.Sprintf("    fcmeq d30, %s, %s", src, src),
		"    fmov x2, d30", // all ones unless NaN
		fmt.Sprintf("    sxth x1, %s", dst),
		fmt.Sprintf("    eor x1, x1, %s", x), // 0 iff it fits in 16 bits
		"    clz x1, x1",
		"    lsr x1, x1, #6",
		"    sub x1, x1, #1", // 0 iff it fits, else all ones
		"    orn x1, x1, x2", // ... or NaN
		fmt.Sprintf("    bic %s, %s, w1", dst, dst),
		"    and w1, w1, #0x8000",
		fmt.Sprintf("    orr %s, %s, w1", dst, dst))
	return out
}
