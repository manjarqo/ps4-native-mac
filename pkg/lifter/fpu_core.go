package lifter

import (
	"fmt"

	"golang.org/x/arch/x86/x86asm"
)

// x87 core load/store/arithmetic lifting.
//
// The emulated register stack holds host doubles (see FPU_ST/fpu_push in
// recomp_context.h). Memory operands keep their architectural formats:
// m32/m64 IEEE floats, m16/m32/m64 integers and the 10-byte m80 extended
// format, which is converted exactly on store (FPU_STORE_M80) and rounded to
// double on load (FPU_LOAD_M80).

// x87MemSize returns the memory operand size in bytes for an x87 instruction.
// x86asm reports MemBytes == 0 for the m80 forms (FLD/FSTP m80, DB /5, DB /7),
// so an x87 load/store with a memory operand and no MemBytes is 10 bytes.
func x87MemSize(inst x86asm.Inst) int {
	if inst.MemBytes != 0 {
		return inst.MemBytes
	}
	switch inst.Op {
	case x86asm.FLD, x86asm.FSTP:
		for _, a := range inst.Args {
			if _, ok := a.(x86asm.Mem); ok {
				return 10
			}
		}
	}
	return 4
}

func isX87Reg(a x86asm.Arg) (int, bool) {
	if reg, ok := a.(x86asm.Reg); ok && reg >= x86asm.F0 && reg <= x86asm.F7 {
		return int(reg - x86asm.F0), true
	}
	return 0, false
}

func x87MemArg(args x86asm.Args) (x86asm.Mem, bool) {
	for _, a := range args {
		if m, ok := a.(x86asm.Mem); ok {
			return m, true
		}
	}
	return x86asm.Mem{}, false
}

// x87LoadMem returns a C statement assigning the memory operand at addrExpr,
// converted to double, to the variable named dst.
func x87LoadMem(dst, addrExpr string, size int, isInt bool) (string, error) {
	if isInt {
		switch size {
		case 2:
			return fmt.Sprintf("%s = (double)(int16_t)MEM_U16(%s);", dst, addrExpr), nil
		case 4:
			return fmt.Sprintf("%s = (double)(int32_t)MEM_U32(%s);", dst, addrExpr), nil
		case 8:
			return fmt.Sprintf("%s = (double)(int64_t)MEM_U64(%s);", dst, addrExpr), nil
		}
		return "", fmt.Errorf("unsupported x87 integer operand size %d", size)
	}
	switch size {
	case 4:
		return fmt.Sprintf("{ float f_; uint32_t u_ = MEM_U32(%s); memcpy(&f_, &u_, 4); %s = (double)f_; }", addrExpr, dst), nil
	case 8:
		return fmt.Sprintf("{ uint64_t u_ = MEM_U64(%s); memcpy(&%s, &u_, 8); }", addrExpr, dst), nil
	case 10:
		return fmt.Sprintf("%s = FPU_LOAD_M80(%s);", dst, addrExpr), nil
	}
	return "", fmt.Errorf("unsupported x87 float operand size %d", size)
}

// x87StoreMem returns a C statement storing the double expression val to memory
// in the given floating-point format.
func x87StoreMem(addrExpr, val string, size int) (string, error) {
	switch size {
	case 4:
		return fmt.Sprintf("{ float f_ = (float)(%s); uint32_t u_; memcpy(&u_, &f_, 4); MEM_U32(%s) = u_; }", val, addrExpr), nil
	case 8:
		return fmt.Sprintf("{ double d_ = (%s); uint64_t u_; memcpy(&u_, &d_, 8); MEM_U64(%s) = u_; }", val, addrExpr), nil
	case 10:
		return fmt.Sprintf("FPU_STORE_M80(%s, %s);", addrExpr, val), nil
	}
	return "", fmt.Errorf("unsupported x87 float store size %d", size)
}

func (l *Lifter) liftFld(arg x86asm.Arg, memSz int, nextPC uint64) ([]string, error) {
	if idx, ok := isX87Reg(arg); ok {
		// Read ST(i) before the push changes TOP.
		return []string{fmt.Sprintf("    { double t_ = FPU_ST(%d); fpu_push(ctx, t_); }", idx)}, nil
	}
	if mem, ok := arg.(x86asm.Mem); ok {
		addrExpr, err := MemAddrExpr(mem, nextPC)
		if err != nil {
			return nil, err
		}
		ld, err := x87LoadMem("t_", addrExpr, memSz, false)
		if err != nil {
			return nil, err
		}
		return []string{fmt.Sprintf("    { double t_; %s fpu_push(ctx, t_); }", ld)}, nil
	}
	return nil, fmt.Errorf("unsupported FLD operand")
}

func (l *Lifter) liftFild(arg x86asm.Arg, memSz int, nextPC uint64) ([]string, error) {
	mem, ok := arg.(x86asm.Mem)
	if !ok {
		return nil, fmt.Errorf("unsupported FILD operand")
	}
	addrExpr, err := MemAddrExpr(mem, nextPC)
	if err != nil {
		return nil, err
	}
	ld, err := x87LoadMem("t_", addrExpr, memSz, true)
	if err != nil {
		return nil, err
	}
	return []string{fmt.Sprintf("    { double t_; %s fpu_push(ctx, t_); }", ld)}, nil
}

// liftFstp handles FST and FSTP (register and m32/m64/m80 destinations).
// Only FSTP pops. The value is read into a temporary first so that the
// destination slot is computed with the pre-pop TOP.
func (l *Lifter) liftFstp(op x86asm.Op, arg x86asm.Arg, memSz int, nextPC uint64) ([]string, error) {
	var lines []string
	if idx, ok := isX87Reg(arg); ok {
		if idx != 0 {
			lines = append(lines, fmt.Sprintf("    { double t_ = FPU_ST(0); FPU_ST(%d) = t_; }", idx))
		}
	} else if mem, ok := arg.(x86asm.Mem); ok {
		addrExpr, err := MemAddrExpr(mem, nextPC)
		if err != nil {
			return nil, err
		}
		st, err := x87StoreMem(addrExpr, "FPU_ST(0)", memSz)
		if err != nil {
			return nil, err
		}
		lines = append(lines, "    "+st)
	} else {
		return nil, fmt.Errorf("unsupported FST/FSTP operand")
	}
	if op == x86asm.FSTP {
		lines = append(lines, "    fpu_pop(ctx);")
	}
	return lines, nil
}

func x87IntStore(addrExpr, val string, size int) (string, error) {
	switch size {
	case 2:
		return fmt.Sprintf("MEM_U16(%s) = (uint16_t)fpu_to_i16(%s);", addrExpr, val), nil
	case 4:
		return fmt.Sprintf("MEM_U32(%s) = (uint32_t)fpu_to_i32(%s);", addrExpr, val), nil
	case 8:
		return fmt.Sprintf("MEM_U64(%s) = (uint64_t)fpu_to_i64(%s);", addrExpr, val), nil
	}
	return "", fmt.Errorf("unsupported x87 integer store size %d", size)
}

// liftFist handles FIST/FISTP, rounding per the control word RC field.
func (l *Lifter) liftFist(op x86asm.Op, arg x86asm.Arg, memSz int, nextPC uint64) ([]string, error) {
	mem, ok := arg.(x86asm.Mem)
	if !ok {
		return nil, fmt.Errorf("unsupported FIST operand")
	}
	addrExpr, err := MemAddrExpr(mem, nextPC)
	if err != nil {
		return nil, err
	}
	st, err := x87IntStore(addrExpr, "fpu_round_cw(ctx->fpu_cw, FPU_ST(0))", memSz)
	if err != nil {
		return nil, err
	}
	lines := []string{"    " + st}
	if op == x86asm.FISTP {
		lines = append(lines, "    fpu_pop(ctx);")
	}
	return lines, nil
}

// liftFisttp stores with truncation (SSE3 FISTTP) and pops.
func (l *Lifter) liftFisttp(arg x86asm.Arg, memSz int, nextPC uint64) ([]string, error) {
	mem, ok := arg.(x86asm.Mem)
	if !ok {
		return nil, fmt.Errorf("unsupported FISTTP operand")
	}
	addrExpr, err := MemAddrExpr(mem, nextPC)
	if err != nil {
		return nil, err
	}
	st, err := x87IntStore(addrExpr, "trunc(FPU_ST(0))", memSz)
	if err != nil {
		return nil, err
	}
	return []string{"    " + st, "    fpu_pop(ctx);"}, nil
}

func (l *Lifter) liftFrndint() []string {
	return []string{"    FPU_ST(0) = fpu_round_cw(ctx->fpu_cw, FPU_ST(0));"}
}

// liftX87Arith lifts the FADD/FSUB/FSUBR/FMUL/FDIV/FDIVR families, their
// popping forms and the FI* integer-memory forms.
//
// Register forms follow x86asm operand order: Args[0] is the destination and
// Args[1] the source, i.e. "fsub st0, st3" => ST0 = ST0 - ST3 and
// "fsubr st3, st0" => ST3 = ST0 - ST3. Memory forms always target ST0.
func (l *Lifter) liftX87Arith(op x86asm.Op, args x86asm.Args, memSz int, nextPC uint64) ([]string, error) {
	var cop string
	rev, pop, isInt := false, false, false
	switch op {
	case x86asm.FADD:
		cop = "+"
	case x86asm.FADDP:
		cop, pop = "+", true
	case x86asm.FIADD:
		cop, isInt = "+", true
	case x86asm.FSUB:
		cop = "-"
	case x86asm.FSUBP:
		cop, pop = "-", true
	case x86asm.FISUB:
		cop, isInt = "-", true
	case x86asm.FSUBR:
		cop, rev = "-", true
	case x86asm.FSUBRP:
		cop, rev, pop = "-", true, true
	case x86asm.FISUBR:
		cop, rev, isInt = "-", true, true
	case x86asm.FMUL:
		cop = "*"
	case x86asm.FMULP:
		cop, pop = "*", true
	case x86asm.FIMUL:
		cop, isInt = "*", true
	case x86asm.FDIV:
		cop = "/"
	case x86asm.FDIVP:
		cop, pop = "/", true
	case x86asm.FIDIV:
		cop, isInt = "/", true
	case x86asm.FDIVR:
		cop, rev = "/", true
	case x86asm.FDIVRP:
		cop, rev, pop = "/", true, true
	case x86asm.FIDIVR:
		cop, rev, isInt = "/", true, true
	default:
		return nil, fmt.Errorf("liftX87Arith: unexpected op %v", op)
	}

	expr := "a_ " + cop + " b_"
	if rev {
		expr = "b_ " + cop + " a_"
	}

	var lines []string
	if mem, ok := x87MemArg(args); ok {
		addrExpr, err := MemAddrExpr(mem, nextPC)
		if err != nil {
			return nil, err
		}
		ld, err := x87LoadMem("b_", addrExpr, memSz, isInt)
		if err != nil {
			return nil, err
		}
		lines = append(lines, fmt.Sprintf("    { double a_ = FPU_ST(0); double b_; %s FPU_ST(0) = %s; }", ld, expr))
	} else {
		if isInt {
			return nil, fmt.Errorf("%v requires a memory operand", op)
		}
		var regs []int
		for _, a := range args {
			if idx, ok := isX87Reg(a); ok {
				regs = append(regs, idx)
			}
		}
		dst, src := 0, 1
		switch {
		case len(regs) >= 2:
			dst, src = regs[0], regs[1]
		case len(regs) == 1 && pop:
			dst, src = regs[0], 0
		case len(regs) == 1:
			dst, src = 0, regs[0]
		case pop:
			dst, src = 1, 0
		}
		lines = append(lines, fmt.Sprintf("    { double a_ = FPU_ST(%d); double b_ = FPU_ST(%d); FPU_ST(%d) = %s; }", dst, src, dst, expr))
	}
	if pop {
		lines = append(lines, "    fpu_pop(ctx);")
	}
	return lines, nil
}

// liftX87Compare lifts FCOM/FCOMP/FCOMPP/FUCOM/FUCOMP/FUCOMPP, which set the
// C0/C2/C3 condition bits in the status word.
func (l *Lifter) liftX87Compare(op x86asm.Op, args x86asm.Args, memSz int, nextPC uint64) ([]string, error) {
	pops := 0
	switch op {
	case x86asm.FCOMP, x86asm.FUCOMP:
		pops = 1
	case x86asm.FCOMPP, x86asm.FUCOMPP:
		pops = 2
	}
	lines := []string{"    {", "      double a_ = FPU_ST(0); double b_;"}
	if mem, ok := x87MemArg(args); ok {
		addrExpr, err := MemAddrExpr(mem, nextPC)
		if err != nil {
			return nil, err
		}
		ld, err := x87LoadMem("b_", addrExpr, memSz, false)
		if err != nil {
			return nil, err
		}
		lines = append(lines, "      "+ld)
	} else {
		src := 1
		var regs []int
		for _, a := range args {
			if idx, ok := isX87Reg(a); ok {
				regs = append(regs, idx)
			}
		}
		if len(regs) >= 2 {
			src = regs[1]
		} else if len(regs) == 1 {
			src = regs[0]
		}
		lines = append(lines, fmt.Sprintf("      b_ = FPU_ST(%d);", src))
	}
	lines = append(lines,
		"      uint16_t sw_ = ctx->fpu_sw & ~0x4500;",
		"      if (isnan(a_) || isnan(b_)) { sw_ |= 0x4500; }",
		"      else if (a_ < b_) { sw_ |= 0x0100; }",
		"      else if (a_ == b_) { sw_ |= 0x4000; }",
		"      ctx->fpu_sw = sw_;",
		"    }",
	)
	for i := 0; i < pops; i++ {
		lines = append(lines, "    fpu_pop(ctx);")
	}
	return lines, nil
}
