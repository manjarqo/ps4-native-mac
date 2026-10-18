package lifter

import (
	"fmt"

	"ps4-recomp/pkg/disasm"

	"golang.org/x/arch/x86/x86asm"
)

// hasLockPrefix reports whether the instruction carries an F0 LOCK prefix.
func hasLockPrefix(inst x86asm.Inst) bool {
	for _, p := range inst.Prefix {
		if p == 0 {
			break
		}
		if p&0xFF == x86asm.PrefixLOCK {
			return true
		}
	}
	return false
}

// liftLocked lowers LOCK-prefixed read-modify-write instructions on memory
// (and the implicitly locked XCHG with a memory operand) to host atomics.
// x86 guarantees these are atomic with full-barrier semantics; lifting them as
// plain load/op/store loses updates between guest threads (job counters,
// spinlock releases, lock-free queues). ok is false when the instruction is
// not handled here and the regular lowering should be used.
func (l *Lifter) liftLocked(inst disasm.Instruction, defMemSz int, nextPC uint64) (lines []string, ok bool, err error) {
	op := inst.Inst.Op
	args := inst.Inst.Args

	if op == x86asm.XCHG {
		mem, reg, found := xchgMemReg(args[0], args[1])
		if !found {
			return nil, false, nil
		}
		return l.liftAtomicXchg(mem, reg, nextPC)
	}

	if !hasLockPrefix(inst.Inst) {
		return nil, false, nil
	}
	mem, isMem := args[0].(x86asm.Mem)
	if !isMem {
		return nil, false, nil
	}
	sz := defMemSz
	if args[1] != nil {
		if reg, ok := args[1].(x86asm.Reg); ok {
			if info, ok := regMap[reg]; ok && info.Size > 0 && op != x86asm.BTS && op != x86asm.BTR && op != x86asm.BTC {
				sz = info.Size
			}
		}
	}
	if sz != 1 && sz != 2 && sz != 4 && sz != 8 {
		return nil, false, nil
	}
	addr, err := MemAddrExpr(mem, nextPC)
	if err != nil {
		return nil, false, err
	}
	cType := uintType(sz)
	bits := sz * 8
	ptr := fmt.Sprintf("((%s *)(ctx->mem_base + (%s)))", cType, addr)

	srcExpr := func() (string, error) {
		s, _, err := l.getOperandRead(args[1], sz, nextPC)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("(%s)(%s)", cType, s), nil
	}

	switch op {
	case x86asm.ADD, x86asm.SUB, x86asm.AND, x86asm.OR, x86asm.XOR:
		b, err := srcExpr()
		if err != nil {
			return nil, false, err
		}
		var fetch, calc, flags string
		switch op {
		case x86asm.ADD:
			fetch, calc, flags = "__atomic_fetch_add", "old + b", fmt.Sprintf("set_flags_add_u%d(ctx, old, b, res);", bits)
		case x86asm.SUB:
			fetch, calc, flags = "__atomic_fetch_sub", "old - b", fmt.Sprintf("set_flags_sub_u%d(ctx, old, b, res);", bits)
		case x86asm.AND:
			fetch, calc, flags = "__atomic_fetch_and", "old & b", fmt.Sprintf("set_flags_logic_u%d(ctx, res);", bits)
		case x86asm.OR:
			fetch, calc, flags = "__atomic_fetch_or", "old | b", fmt.Sprintf("set_flags_logic_u%d(ctx, res);", bits)
		default:
			fetch, calc, flags = "__atomic_fetch_xor", "old ^ b", fmt.Sprintf("set_flags_logic_u%d(ctx, res);", bits)
		}
		lines = []string{
			fmt.Sprintf("    { %s b = %s;", cType, b),
			fmt.Sprintf("      %s old = %s(%s, b, __ATOMIC_SEQ_CST);", cType, fetch, ptr),
			fmt.Sprintf("      %s res = (%s)(%s);", cType, cType, calc),
			"      " + flags,
			"      (void)res;",
			"    }",
		}
		return lines, true, nil

	case x86asm.INC, x86asm.DEC:
		fetch, calc, flags := "__atomic_fetch_add", "old + 1", fmt.Sprintf("set_flags_inc_u%d(ctx, old, res);", bits)
		if op == x86asm.DEC {
			fetch, calc, flags = "__atomic_fetch_sub", "old - 1", fmt.Sprintf("set_flags_dec_u%d(ctx, old, res);", bits)
		}
		lines = []string{
			fmt.Sprintf("    { %s old = %s(%s, (%s)1, __ATOMIC_SEQ_CST);", cType, fetch, ptr, cType),
			fmt.Sprintf("      %s res = (%s)(%s);", cType, cType, calc),
			"      " + flags,
			"    }",
		}
		return lines, true, nil

	case x86asm.NEG, x86asm.NOT:
		calc := "(~old)"
		flags := ""
		if op == x86asm.NEG {
			calc = "(-old)"
			flags = fmt.Sprintf("      set_flags_sub_u%d(ctx, 0, old, res);", bits)
		}
		lines = []string{
			fmt.Sprintf("    { %s old = __atomic_load_n(%s, __ATOMIC_SEQ_CST); %s res;", cType, ptr, cType),
			fmt.Sprintf("      do { res = (%s)%s; } while (!__atomic_compare_exchange_n(%s, &old, res, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST));", cType, calc, ptr),
		}
		if flags != "" {
			lines = append(lines, flags)
		}
		lines = append(lines, "    }")
		return lines, true, nil

	case x86asm.BTS, x86asm.BTR, x86asm.BTC:
		// Register bit offsets can address beyond the operand; immediates are
		// taken modulo the operand width.
		bitRead, _, err := l.getOperandRead(args[1], sz, nextPC)
		if err != nil {
			return nil, false, err
		}
		var fetch, maskExpr string
		switch op {
		case x86asm.BTS:
			fetch, maskExpr = "__atomic_fetch_or", "m"
		case x86asm.BTR:
			fetch, maskExpr = "__atomic_fetch_and", "(" + cType + ")~m"
		default:
			fetch, maskExpr = "__atomic_fetch_xor", "m"
		}
		basePtr := fmt.Sprintf("(ctx->mem_base + (%s))", addr)
		elemPtr := ptr
		if _, isImm := args[1].(x86asm.Imm); !isImm {
			// Signed bit offset: select the containing element.
			elemPtr = fmt.Sprintf("((%s *)(%s + (int64_t)(off >> %d) * %d))", cType, basePtr, log2(bits), sz)
		}
		lines = []string{
			fmt.Sprintf("    { int64_t off = (int64_t)(%s)(%s);", intType(sz), bitRead),
			fmt.Sprintf("      %s m = (%s)((%s)1 << (off & %d));", cType, cType, cType, bits-1),
			fmt.Sprintf("      %s old = %s(%s, %s, __ATOMIC_SEQ_CST);", cType, fetch, elemPtr, maskExpr),
			"      ctx->cf = (old & m) != 0;",
			"    }",
		}
		return lines, true, nil
	}
	return nil, false, nil
}

func xchgMemReg(a, b x86asm.Arg) (x86asm.Mem, x86asm.Reg, bool) {
	if m, ok := a.(x86asm.Mem); ok {
		if r, ok := b.(x86asm.Reg); ok {
			return m, r, true
		}
	}
	if m, ok := b.(x86asm.Mem); ok {
		if r, ok := a.(x86asm.Reg); ok {
			return m, r, true
		}
	}
	return x86asm.Mem{}, 0, false
}

func (l *Lifter) liftAtomicXchg(mem x86asm.Mem, reg x86asm.Reg, nextPC uint64) ([]string, bool, error) {
	info, ok := regMap[reg]
	if !ok || (info.Size != 1 && info.Size != 2 && info.Size != 4 && info.Size != 8) {
		return nil, false, nil
	}
	sz := info.Size
	cType := uintType(sz)
	addr, err := MemAddrExpr(mem, nextPC)
	if err != nil {
		return nil, false, err
	}
	rRead, _, err := l.getOperandRead(reg, sz, nextPC)
	if err != nil {
		return nil, false, err
	}
	w, err := l.getOperandWrite(reg, sz, "old", nextPC)
	if err != nil {
		return nil, false, err
	}
	lines := []string{
		fmt.Sprintf("    { %s old = __atomic_exchange_n((%s *)(ctx->mem_base + (%s)), (%s)(%s), __ATOMIC_SEQ_CST);", cType, cType, addr, cType, rRead),
	}
	for _, s := range w {
		lines = append(lines, "      "+s)
	}
	lines = append(lines, "    }")
	return lines, true, nil
}

func log2(n int) int {
	r := 0
	for n > 1 {
		n >>= 1
		r++
	}
	return r
}
