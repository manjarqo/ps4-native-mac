package disasm

import "golang.org/x/arch/x86/x86asm"

// CF/OF liveness across the blocks of a function.
//
// The ARM64 assembly lifter keeps x86 CF in ARM C with an inverted sense after subtractions
// (C = !CF, ARM's borrow convention) and the direct sense after additions and logical
// operations. At a block boundary the lifter assumes the subtract sense, so a block that ends in
// the other sense has to invert C on the way out, but only when a successor can read CF before
// redefining it. Some lowerings also preserve CF (INC/DEC) or compute CF/OF (rotates) only when
// the flag is live. This pass computes, per instruction, whether CF and OF are dead after it.
// It is conservative: unknown successors and unknown instructions keep the flags live.

const (
	flagCF uint8 = 1 << iota
	flagOF
)

// carryOverflowEffect returns the CF/OF bits an instruction reads (before writing) and the bits
// it defines (writes or leaves undefined, so an earlier value cannot be observed through it).
func carryOverflowEffect(inst x86asm.Inst) (reads, kills uint8) {
	both := flagCF | flagOF
	switch inst.Op {
	case x86asm.JB, x86asm.JAE, x86asm.JBE, x86asm.JA,
		x86asm.SETB, x86asm.SETAE, x86asm.SETBE, x86asm.SETA,
		x86asm.CMOVB, x86asm.CMOVAE, x86asm.CMOVBE, x86asm.CMOVA, x86asm.LAHF:
		return flagCF, 0
	case x86asm.JO, x86asm.JNO, x86asm.JL, x86asm.JGE, x86asm.JLE, x86asm.JG,
		x86asm.SETO, x86asm.SETNO, x86asm.SETL, x86asm.SETGE, x86asm.SETLE, x86asm.SETG,
		x86asm.CMOVO, x86asm.CMOVNO, x86asm.CMOVL, x86asm.CMOVGE, x86asm.CMOVLE, x86asm.CMOVG:
		return flagOF, 0
	case x86asm.PUSHF, x86asm.PUSHFD, x86asm.PUSHFQ:
		return both, 0
	case x86asm.ADC, x86asm.SBB:
		return flagCF, both
	case x86asm.CMC:
		return flagCF, flagCF
	case x86asm.CLC, x86asm.STC:
		return 0, flagCF
	case x86asm.INC, x86asm.DEC:
		return 0, flagOF // CF is preserved
	case x86asm.SAHF:
		return 0, flagCF // OF is preserved
	case x86asm.ADD, x86asm.SUB, x86asm.CMP, x86asm.TEST, x86asm.AND, x86asm.OR, x86asm.XOR, x86asm.NEG,
		x86asm.BSF, x86asm.BSR, x86asm.TZCNT, x86asm.LZCNT, x86asm.POPCNT,
		x86asm.MUL, x86asm.IMUL, x86asm.DIV, x86asm.IDIV,
		x86asm.ANDN, x86asm.BEXTR, x86asm.BLSI, x86asm.BLSR, x86asm.BLSMSK, x86asm.BZHI,
		x86asm.COMISS, x86asm.UCOMISS, x86asm.COMISD, x86asm.UCOMISD,
		x86asm.VCOMISS, x86asm.VUCOMISS, x86asm.VCOMISD, x86asm.VUCOMISD,
		x86asm.PTEST, x86asm.VPTEST, x86asm.VTESTPS, x86asm.VTESTPD,
		x86asm.BT, x86asm.BTS, x86asm.BTR, x86asm.BTC,
		x86asm.POPF, x86asm.POPFD, x86asm.POPFQ, x86asm.CMPXCHG, x86asm.XADD,
		x86asm.CMPSB, x86asm.CMPSW, x86asm.CMPSD, x86asm.CMPSQ, x86asm.SCASB, x86asm.SCASW, x86asm.SCASD, x86asm.SCASQ,
		x86asm.FCOMI, x86asm.FCOMIP, x86asm.FUCOMI, x86asm.FUCOMIP,
		x86asm.PCMPISTRI, x86asm.PCMPESTRI, x86asm.PCMPISTRM, x86asm.PCMPESTRM,
		x86asm.VPCMPISTRI, x86asm.VPCMPESTRI, x86asm.VPCMPISTRM, x86asm.VPCMPESTRM,
		// Flags are not preserved across calls (System V ABI).
		x86asm.CALL:
		return 0, both
	case x86asm.SHL, x86asm.SHR, x86asm.SAR, x86asm.ROL, x86asm.ROR, x86asm.SHLD, x86asm.SHRD:
		// A count of 0 leaves the flags unchanged, so only a non-zero immediate count defines them.
		if c, ok := shiftImmCount(inst); ok && c != 0 {
			return 0, both
		}
		return 0, 0
	case x86asm.RCL, x86asm.RCR:
		if c, ok := shiftImmCount(inst); ok && c != 0 {
			return flagCF, both
		}
		return flagCF, 0
	}
	return 0, 0
}

// shiftImmCount returns the masked immediate count of a shift or rotate.
func shiftImmCount(inst x86asm.Inst) (uint64, bool) {
	for i := len(inst.Args) - 1; i >= 1; i-- {
		if inst.Args[i] == nil {
			continue
		}
		imm, ok := inst.Args[i].(x86asm.Imm)
		if !ok {
			return 0, false
		}
		mask := uint64(0x1f)
		if inst.DataSize == 64 || inst.MemBytes == 8 {
			mask = 0x3f
		}
		if r, isReg := inst.Args[0].(x86asm.Reg); isReg && r >= x86asm.RAX && r <= x86asm.R15 {
			mask = 0x3f
		}
		return uint64(imm) & mask, true
	}
	return 0, false
}

// blockSuccessors returns the start addresses of the blocks control can reach from the end of b
// inside fn; unknown is true when a successor cannot be determined (indirect jump without a
// recovered table, fallthrough into an address that is not a block of fn).
func blockSuccessors(fn *Function, b *BasicBlock) (succs []uint64, unknown bool) {
	if len(b.Insts) == 0 {
		return nil, true
	}
	last := b.Insts[len(b.Insts)-1]
	nextPC := last.Address + uint64(last.Inst.Len)
	local := func(t uint64) {
		if fn.Blocks[t] != nil {
			succs = append(succs, t)
		}
		// A transfer out of the function is a tail call: flags are dead there.
	}
	switch op := last.Inst.Op; {
	case op == x86asm.RET || op == x86asm.LRET || op == x86asm.UD2 || op == x86asm.HLT || op == x86asm.INT:
		return nil, false
	case op == x86asm.JMP:
		if rel, ok := last.Inst.Args[0].(x86asm.Rel); ok {
			local(uint64(int64(nextPC) + int64(rel)))
			return succs, false
		}
		if ts, ok := fn.JumpTables[last.Address]; ok && len(ts) > 0 {
			for _, t := range ts {
				local(t)
			}
			return succs, false
		}
		return nil, true
	case isJcc(op):
		if rel, ok := last.Inst.Args[0].(x86asm.Rel); ok {
			local(uint64(int64(nextPC) + int64(rel)))
		} else {
			unknown = true
		}
		if fn.Blocks[nextPC] != nil {
			succs = append(succs, nextPC)
		} else {
			unknown = true
		}
		return succs, unknown
	}
	if fn.Blocks[nextPC] != nil {
		return []uint64{nextPC}, false
	}
	return nil, true
}

// analyzeCarryOverflowLiveness sets Instruction.CarryDead / OverflowDead for every instruction
// of fn (see the comment at the top of the file).
func analyzeCarryOverflowLiveness(fn *Function) {
	if fn == nil || len(fn.Blocks) == 0 {
		return
	}
	type info struct {
		succs   []uint64
		unknown bool
		in      uint8
	}
	infos := make(map[uint64]*info, len(fn.Blocks))
	for addr, b := range fn.Blocks {
		s, u := blockSuccessors(fn, b)
		infos[addr] = &info{succs: s, unknown: u}
	}
	all := flagCF | flagOF
	for changed := true; changed; {
		changed = false
		for i := len(fn.BlockOrder) - 1; i >= 0; i-- {
			addr := fn.BlockOrder[i]
			b, bi := fn.Blocks[addr], infos[addr]
			if b == nil || bi == nil {
				continue
			}
			var live uint8
			if bi.unknown {
				live = all
			}
			for _, s := range bi.succs {
				if si := infos[s]; si != nil {
					live |= si.in
				}
			}
			for k := len(b.Insts) - 1; k >= 0; k-- {
				in := &b.Insts[k]
				in.CarryDead = live&flagCF == 0
				in.OverflowDead = live&flagOF == 0
				reads, kills := carryOverflowEffect(in.Inst)
				live = (live &^ kills) | reads
			}
			if live != bi.in {
				bi.in = live
				changed = true
			}
		}
	}
}
