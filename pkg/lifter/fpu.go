package lifter

import (
	"fmt"

	"golang.org/x/arch/x86/x86asm"
)

func (l *Lifter) liftFxch(arg x86asm.Arg) ([]string, error) {
	idx := 1
	if reg, ok := arg.(x86asm.Reg); ok && reg >= x86asm.F0 && reg <= x86asm.F7 {
		idx = int(reg - x86asm.F0)
	}
	return []string{
		fmt.Sprintf("    { double tmp = FPU_ST(0); FPU_ST(0) = FPU_ST(%d); FPU_ST(%d) = tmp; }", idx, idx),
	}, nil
}

func (l *Lifter) liftFucomi(op x86asm.Op, args x86asm.Args) ([]string, error) {
	idx := 1
	if reg, ok := args[1].(x86asm.Reg); ok && reg >= x86asm.F0 && reg <= x86asm.F7 {
		idx = int(reg - x86asm.F0)
	}
	lines := []string{
		fmt.Sprintf("    { double a = FPU_ST(0); double b = FPU_ST(%d);", idx),
		"      if (isnan(a) || isnan(b)) { ctx->zf = 1; ctx->pf = 1; ctx->cf = 1; }",
		"      else if (a > b) { ctx->zf = 0; ctx->pf = 0; ctx->cf = 0; }",
		"      else if (a < b) { ctx->zf = 0; ctx->pf = 0; ctx->cf = 1; }",
		"      else { ctx->zf = 1; ctx->pf = 0; ctx->cf = 0; }",
		"      ctx->of = 0; ctx->sf = 0; ctx->af = 0; }",
	}
	if op == x86asm.FUCOMIP {
		lines = append(lines, "    fpu_pop(ctx);")
	}
	return lines, nil
}

func (l *Lifter) liftFldcw(arg x86asm.Arg, nextPC uint64) ([]string, error) {
	if mem, ok := arg.(x86asm.Mem); ok {
		addrExpr, err := MemAddrExpr(mem, nextPC)
		if err != nil {
			return nil, err
		}
		return []string{fmt.Sprintf("    ctx->fpu_cw = MEM_U16(%s);", addrExpr)}, nil
	}
	return nil, fmt.Errorf("unsupported FLDCW operand")
}

func (l *Lifter) liftFnstcw(arg x86asm.Arg, nextPC uint64) ([]string, error) {
	if mem, ok := arg.(x86asm.Mem); ok {
		addrExpr, err := MemAddrExpr(mem, nextPC)
		if err != nil {
			return nil, err
		}
		return []string{fmt.Sprintf("    MEM_U16(%s) = ctx->fpu_cw;", addrExpr)}, nil
	}
	return nil, fmt.Errorf("unsupported FNSTCW operand")
}

func (l *Lifter) liftFicom(op x86asm.Op, arg x86asm.Arg, defMemSz int, nextPC uint64) ([]string, error) {
	mem, ok := arg.(x86asm.Mem)
	if !ok {
		return nil, fmt.Errorf("ficom requires memory operand")
	}
	addrExpr, err := MemAddrExpr(mem, nextPC)
	if err != nil {
		return nil, err
	}
	lines := []string{"    {"}
	if defMemSz == 2 {
		lines = append(lines, fmt.Sprintf("      double b = (double)(int16_t)MEM_U16(%s);", addrExpr))
	} else {
		lines = append(lines, fmt.Sprintf("      double b = (double)(int32_t)MEM_U32(%s);", addrExpr))
	}
	lines = append(lines,
		"      double a = FPU_ST(0);",
		"      uint16_t sw = ctx->fpu_sw & ~0x4500;",
		"      if (isnan(a) || isnan(b)) { sw |= 0x4500; }",
		"      else if (a < b) { sw |= 0x0100; }",
		"      else if (a == b) { sw |= 0x4000; }",
		"      ctx->fpu_sw = sw;",
	)
	if op == x86asm.FICOMP {
		lines = append(lines, "      fpu_pop(ctx);")
	}
	lines = append(lines, "    }")
	return lines, nil
}

func (l *Lifter) liftFcmov(op x86asm.Op, arg x86asm.Arg) ([]string, error) {
	reg, ok := arg.(x86asm.Reg)
	if !ok || reg < x86asm.F0 || reg > x86asm.F7 {
		return nil, fmt.Errorf("fcmov requires FPU register")
	}
	idx := int(reg - x86asm.F0)
	cond := "0"
	switch op {
	case x86asm.FCMOVB:
		cond = "ctx->cf"
	case x86asm.FCMOVE:
		cond = "ctx->zf"
	case x86asm.FCMOVNB:
		cond = "!ctx->cf"
	case x86asm.FCMOVNE:
		cond = "!ctx->zf"
	case x86asm.FCMOVBE:
		cond = "ctx->cf || ctx->zf"
	case x86asm.FCMOVNBE:
		cond = "!ctx->cf && !ctx->zf"
	case x86asm.FCMOVU:
		cond = "ctx->pf"
	case x86asm.FCMOVNU:
		cond = "!ctx->pf"
	}
	return []string{
		fmt.Sprintf("    if (%s) { FPU_ST(0) = FPU_ST(%d); }", cond, idx),
	}, nil
}

func (l *Lifter) liftFldl2t() []string {
	return []string{"    fpu_push(ctx, 3.32192809488736234787);"}
}

func (l *Lifter) liftFbstp(arg x86asm.Arg, nextPC uint64) ([]string, error) {
	mem, ok := arg.(x86asm.Mem)
	if !ok {
		return nil, fmt.Errorf("fbstp requires memory operand")
	}
	addrExpr, err := MemAddrExpr(mem, nextPC)
	if err != nil {
		return nil, err
	}
	return []string{
		"    {",
		"      int64_t val = (int64_t)round(fpu_pop(ctx));",
		"      uint8_t sign = (val < 0) ? 0x80 : 0x00;",
		"      uint64_t pos = (val < 0) ? (uint64_t)(-val) : (uint64_t)val;",
		"      uint8_t bcd[10] = {0};",
		"      for (int i = 0; i < 9; i++) { uint8_t d0 = pos % 10; pos /= 10; uint8_t d1 = pos % 10; pos /= 10; bcd[i] = d0 | (d1 << 4); }",
		"      bcd[9] = sign;",
		fmt.Sprintf("      memcpy(ctx->mem_base + (%s), bcd, 10);", addrExpr),
		"    }",
	}, nil
}

func (l *Lifter) liftFnstenv(arg x86asm.Arg, nextPC uint64) ([]string, error) {
	mem, ok := arg.(x86asm.Mem)
	if !ok {
		return nil, fmt.Errorf("fnstenv requires memory operand")
	}
	addrExpr, err := MemAddrExpr(mem, nextPC)
	if err != nil {
		return nil, err
	}
	return []string{
		"    {",
		fmt.Sprintf("      uint8_t *ptr = ctx->mem_base + (%s);", addrExpr),
		"      *(uint16_t*)(ptr) = ctx->fpu_cw;",
		"      *(uint16_t*)(ptr + 4) = (ctx->fpu_sw & ~0x3800) | ((ctx->fpu_top & 7) << 11);",
		"      *(uint16_t*)(ptr + 8) = 0xFFFF;",
		"    }",
	}, nil
}

func (l *Lifter) liftFnstsw(arg x86asm.Arg, nextPC uint64) ([]string, error) {
	swExpr := "((ctx->fpu_sw & ~0x3800) | ((ctx->fpu_top & 7) << 11))"
	if reg, ok := arg.(x86asm.Reg); ok && (reg == x86asm.AX || reg == x86asm.EAX || reg == x86asm.RAX) {
		return []string{
			fmt.Sprintf("    ctx->rax = (ctx->rax & ~0xFFFFULL) | (uint16_t)%s;", swExpr),
		}, nil
	}
	if mem, ok := arg.(x86asm.Mem); ok {
		addrExpr, err := MemAddrExpr(mem, nextPC)
		if err != nil {
			return nil, err
		}
		return []string{
			fmt.Sprintf("    MEM_U16(%s) = (uint16_t)%s;", addrExpr, swExpr),
		}, nil
	}
	return nil, fmt.Errorf("unsupported FNSTSW operand")
}

func (l *Lifter) liftFyl2xp1() []string {
	return []string{"    FPU_ST(1) *= log2(FPU_ST(0) + 1.0); fpu_pop(ctx);"}
}

func (l *Lifter) liftFldenv(arg x86asm.Arg, nextPC uint64) ([]string, error) {
	mem, ok := arg.(x86asm.Mem)
	if !ok {
		return nil, fmt.Errorf("fldenv requires memory operand")
	}
	addrExpr, err := MemAddrExpr(mem, nextPC)
	if err != nil {
		return nil, err
	}
	return []string{
		"    {",
		fmt.Sprintf("      const uint8_t *ptr = ctx->mem_base + (%s);", addrExpr),
		"      ctx->fpu_cw = *(const uint16_t*)(ptr);",
		"      ctx->fpu_sw = *(const uint16_t*)(ptr + 4);",
		"      ctx->fpu_top = (ctx->fpu_sw >> 11) & 7;",
		"    }",
	}, nil
}

func (l *Lifter) liftFnclex() []string {
	return []string{"    ctx->fpu_sw &= ~0x7F;"}
}

func (l *Lifter) liftFfreep() []string {
	return []string{"    fpu_pop(ctx);"}
}

func (l *Lifter) liftFcos() []string {
	return []string{
		"    FPU_ST(0) = cos(FPU_ST(0));",
		"    ctx->fpu_sw &= ~0x0400;",
	}
}

func (l *Lifter) liftFsqrt() []string {
	return []string{"    FPU_ST(0) = sqrt(FPU_ST(0));"}
}

func (l *Lifter) liftFxtract() []string {
	return []string{
		"    {",
		"      double v = FPU_ST(0);",
		"      int exp = 0;",
		"      double sig = frexp(v, &exp);",
		"      // x87: significand in [1,2), exponent = frexp exponent - 1",
		"      if (v == 0.0) { FPU_ST(0) = -INFINITY; fpu_push(ctx, v); }",
		"      else if (isinf(v) || isnan(v)) { FPU_ST(0) = isnan(v) ? v : INFINITY; fpu_push(ctx, v); }",
		"      else { FPU_ST(0) = (double)(exp - 1); fpu_push(ctx, sig * 2.0); }",
		"    }",
	}
}

func (l *Lifter) liftFscale() []string {
	return []string{"    FPU_ST(0) = ldexp(FPU_ST(0), (int)trunc(FPU_ST(1)));"}
}

func (l *Lifter) liftFprem1() []string {
	return []string{"    FPU_ST(0) = remainder(FPU_ST(0), FPU_ST(1));"}
}

func (l *Lifter) liftFrstor(arg x86asm.Arg, nextPC uint64) ([]string, error) {
	mem, ok := arg.(x86asm.Mem)
	if !ok {
		return nil, fmt.Errorf("frstor requires memory operand")
	}
	addrExpr, err := MemAddrExpr(mem, nextPC)
	if err != nil {
		return nil, err
	}
	return []string{
		"    {",
		fmt.Sprintf("      const uint8_t *ptr = ctx->mem_base + (%s);", addrExpr),
		"      ctx->fpu_cw = *(const uint16_t*)(ptr);",
		"      ctx->fpu_sw = *(const uint16_t*)(ptr + 4);",
		"      ctx->fpu_top = (ctx->fpu_sw >> 11) & 7;",
		"    }",
	}, nil
}

func (l *Lifter) liftFxsave(arg x86asm.Arg, nextPC uint64) ([]string, error) {
	mem, ok := arg.(x86asm.Mem)
	if !ok {
		return nil, fmt.Errorf("fxsave requires memory operand")
	}
	addrExpr, err := MemAddrExpr(mem, nextPC)
	if err != nil {
		return nil, err
	}
	return []string{
		"    {",
		fmt.Sprintf("      uint8_t *ptr = ctx->mem_base + (%s);", addrExpr),
		"      memset(ptr, 0, 512);",
		"      *(uint16_t*)(ptr) = ctx->fpu_cw;",
		"      *(uint16_t*)(ptr + 2) = (ctx->fpu_sw & ~0x3800) | ((ctx->fpu_top & 7) << 11);",
		"      *(uint16_t*)(ptr + 4) = 0xFFFF;",
		"      *(uint32_t*)(ptr + 24) = ctx->mxcsr ? ctx->mxcsr : 0x1F80;",
		"      *(uint32_t*)(ptr + 28) = 0xFFFF; // mxcsr_mask",
		"      memcpy(ptr + 160, ctx->xmm, 256); // 16 xmm registers",
		"    }",
	}, nil
}

func (l *Lifter) liftFxrstor(arg x86asm.Arg, nextPC uint64) ([]string, error) {
	mem, ok := arg.(x86asm.Mem)
	if !ok {
		return nil, fmt.Errorf("fxrstor requires memory operand")
	}
	addrExpr, err := MemAddrExpr(mem, nextPC)
	if err != nil {
		return nil, err
	}
	return []string{
		"    {",
		fmt.Sprintf("      const uint8_t *ptr = ctx->mem_base + (%s);", addrExpr),
		"      ctx->fpu_cw = *(const uint16_t*)(ptr);",
		"      ctx->fpu_sw = *(const uint16_t*)(ptr + 2);",
		"      ctx->fpu_top = (ctx->fpu_sw >> 11) & 7;",
		"      ctx->mxcsr = *(const uint32_t*)(ptr + 24);",
		"      memcpy(ctx->xmm, ptr + 160, 256);",
		"    }",
	}, nil
}
