package lifter

import (
	"fmt"
	"strings"

	"ps4-recomp/pkg/disasm"

	"golang.org/x/arch/x86/x86asm"
)

// RegDesc holds the ARM64 register mapping details for an x86 register.
type Arm64RegDesc struct {
	X       string // 64-bit ARM64 register name (e.g. "x19")
	W       string // 32-bit ARM64 register name (e.g. "w19")
	Size    int    // Size in bytes: 1, 2, 4, 8
	IsHigh8 bool   // true for AH, BH, CH, DH (bits 8-15)
}

// XmmDesc holds the ARM64 vector register mapping for an x86 XMM register.
type XmmDesc struct {
	Q string // 128-bit (e.g. "q0")
	D string // 64-bit float/double (e.g. "d0")
	S string // 32-bit float (e.g. "s0")
	V string // Vector register (e.g. "v0")
}

// Register map:
// x86 GPRs map directly to dedicated ARM64 registers.
// X19-X25: callee-saved registers in Apple Darwin ABI (preserved across C calls)
// X26: Guest RSP
// X27: Guest FS_BASE (TLS)
// X28: Guest MEM_BASE (Base address of mapped guest virtual memory)
// X8-X15: Guest R8-R15
var arm64RegMap = map[x86asm.Reg]Arm64RegDesc{
	// RAX
	x86asm.RAX: {X: "x19", W: "w19", Size: 8},
	x86asm.EAX: {X: "x19", W: "w19", Size: 4},
	x86asm.AX:  {X: "x19", W: "w19", Size: 2},
	x86asm.AL:  {X: "x19", W: "w19", Size: 1, IsHigh8: false},
	x86asm.AH:  {X: "x19", W: "w19", Size: 1, IsHigh8: true},

	// RBX
	x86asm.RBX: {X: "x20", W: "w20", Size: 8},
	x86asm.EBX: {X: "x20", W: "w20", Size: 4},
	x86asm.BX:  {X: "x20", W: "w20", Size: 2},
	x86asm.BL:  {X: "x20", W: "w20", Size: 1, IsHigh8: false},
	x86asm.BH:  {X: "x20", W: "w20", Size: 1, IsHigh8: true},

	// RCX
	x86asm.RCX: {X: "x21", W: "w21", Size: 8},
	x86asm.ECX: {X: "x21", W: "w21", Size: 4},
	x86asm.CX:  {X: "x21", W: "w21", Size: 2},
	x86asm.CL:  {X: "x21", W: "w21", Size: 1, IsHigh8: false},
	x86asm.CH:  {X: "x21", W: "w21", Size: 1, IsHigh8: true},

	// RDX
	x86asm.RDX: {X: "x22", W: "w22", Size: 8},
	x86asm.EDX: {X: "x22", W: "w22", Size: 4},
	x86asm.DX:  {X: "x22", W: "w22", Size: 2},
	x86asm.DL:  {X: "x22", W: "w22", Size: 1, IsHigh8: false},
	x86asm.DH:  {X: "x22", W: "w22", Size: 1, IsHigh8: true},

	// RSI
	x86asm.RSI: {X: "x23", W: "w23", Size: 8},
	x86asm.ESI: {X: "x23", W: "w23", Size: 4},
	x86asm.SI:  {X: "x23", W: "w23", Size: 2},
	x86asm.SIB: {X: "x23", W: "w23", Size: 1},

	// RDI
	x86asm.RDI: {X: "x24", W: "w24", Size: 8},
	x86asm.EDI: {X: "x24", W: "w24", Size: 4},
	x86asm.DI:  {X: "x24", W: "w24", Size: 2},
	x86asm.DIB: {X: "x24", W: "w24", Size: 1},

	// RBP
	x86asm.RBP: {X: "x25", W: "w25", Size: 8},
	x86asm.EBP: {X: "x25", W: "w25", Size: 4},
	x86asm.BP:  {X: "x25", W: "w25", Size: 2},
	x86asm.BPB: {X: "x25", W: "w25", Size: 1},

	// RSP
	x86asm.RSP: {X: "x26", W: "w26", Size: 8},
	x86asm.ESP: {X: "x26", W: "w26", Size: 4},
	x86asm.SP:  {X: "x26", W: "w26", Size: 2},
	x86asm.SPB: {X: "x26", W: "w26", Size: 1},

	// R8 - R15
	x86asm.R8:  {X: "x8", W: "w8", Size: 8},
	x86asm.R8L: {X: "x8", W: "w8", Size: 4},
	x86asm.R8W: {X: "x8", W: "w8", Size: 2},
	x86asm.R8B: {X: "x8", W: "w8", Size: 1},

	x86asm.R9:  {X: "x9", W: "w9", Size: 8},
	x86asm.R9L: {X: "x9", W: "w9", Size: 4},
	x86asm.R9W: {X: "x9", W: "w9", Size: 2},
	x86asm.R9B: {X: "x9", W: "w9", Size: 1},

	x86asm.R10:  {X: "x10", W: "w10", Size: 8},
	x86asm.R10L: {X: "x10", W: "w10", Size: 4},
	x86asm.R10W: {X: "x10", W: "w10", Size: 2},
	x86asm.R10B: {X: "x10", W: "w10", Size: 1},

	x86asm.R11:  {X: "x11", W: "w11", Size: 8},
	x86asm.R11L: {X: "x11", W: "w11", Size: 4},
	x86asm.R11W: {X: "x11", W: "w11", Size: 2},
	x86asm.R11B: {X: "x11", W: "w11", Size: 1},

	x86asm.R12:  {X: "x12", W: "w12", Size: 8},
	x86asm.R12L: {X: "x12", W: "w12", Size: 4},
	x86asm.R12W: {X: "x12", W: "w12", Size: 2},
	x86asm.R12B: {X: "x12", W: "w12", Size: 1},

	x86asm.R13:  {X: "x13", W: "w13", Size: 8},
	x86asm.R13L: {X: "x13", W: "w13", Size: 4},
	x86asm.R13W: {X: "x13", W: "w13", Size: 2},
	x86asm.R13B: {X: "x13", W: "w13", Size: 1},

	x86asm.R14:  {X: "x14", W: "w14", Size: 8},
	x86asm.R14L: {X: "x14", W: "w14", Size: 4},
	x86asm.R14W: {X: "x14", W: "w14", Size: 2},
	x86asm.R14B: {X: "x14", W: "w14", Size: 1},

	x86asm.R15:  {X: "x15", W: "w15", Size: 8},
	x86asm.R15L: {X: "x15", W: "w15", Size: 4},
	x86asm.R15W: {X: "x15", W: "w15", Size: 2},
	x86asm.R15B: {X: "x15", W: "w15", Size: 1},
}

// XMM registers map to ARM64 NEON V0-V15
var arm64XmmMap = map[x86asm.Reg]XmmDesc{
	x86asm.X0:  {Q: "q0", D: "d0", S: "s0", V: "v0"},
	x86asm.X1:  {Q: "q1", D: "d1", S: "s1", V: "v1"},
	x86asm.X2:  {Q: "q2", D: "d2", S: "s2", V: "v2"},
	x86asm.X3:  {Q: "q3", D: "d3", S: "s3", V: "v3"},
	x86asm.X4:  {Q: "q4", D: "d4", S: "s4", V: "v4"},
	x86asm.X5:  {Q: "q5", D: "d5", S: "s5", V: "v5"},
	x86asm.X6:  {Q: "q6", D: "d6", S: "s6", V: "v6"},
	x86asm.X7:  {Q: "q7", D: "d7", S: "s7", V: "v7"},
	x86asm.X8:  {Q: "q8", D: "d8", S: "s8", V: "v8"},
	x86asm.X9:  {Q: "q9", D: "d9", S: "s9", V: "v9"},
	x86asm.X10: {Q: "q10", D: "d10", S: "s10", V: "v10"},
	x86asm.X11: {Q: "q11", D: "d11", S: "s11", V: "v11"},
	x86asm.X12: {Q: "q12", D: "d12", S: "s12", V: "v12"},
	x86asm.X13: {Q: "q13", D: "d13", S: "s13", V: "v13"},
	x86asm.X14: {Q: "q14", D: "d14", S: "s14", V: "v14"},
	x86asm.X15: {Q: "q15", D: "d15", S: "s15", V: "v15"},
}

// getVectorDesc resolves XMM or YMM registers to ARM64 NEON registers (q0-q31 / v0-v31).
func getVectorDesc(reg x86asm.Reg) (isYmm bool, lowQ, highQ, lowV, highV, lowS, lowD string, ok bool) {
	if reg >= x86asm.Y0 && reg <= x86asm.Y15 {
		idx := int(reg - x86asm.Y0)
		return true, fmt.Sprintf("q%d", idx), fmt.Sprintf("q%d", idx+16),
			fmt.Sprintf("v%d", idx), fmt.Sprintf("v%d", idx+16),
			fmt.Sprintf("s%d", idx), fmt.Sprintf("d%d", idx), true
	}
	if reg >= x86asm.X0 && reg <= x86asm.X15 {
		idx := int(reg - x86asm.X0)
		return false, fmt.Sprintf("q%d", idx), fmt.Sprintf("q%d", idx+16),
			fmt.Sprintf("v%d", idx), fmt.Sprintf("v%d", idx+16),
			fmt.Sprintf("s%d", idx), fmt.Sprintf("d%d", idx), true
	}
	return false, "", "", "", "", "", "", false
}

// Arm64Lifter translates x86-64 instructions directly into Apple Silicon ARM64 assembly (.s).
type Arm64Lifter struct {
	knownFuncs    map[uint64]bool
	currentFn     *disasm.Function
	unsuppCounter uint64
	labelCounter  uint64
}

// NewArm64Lifter creates a new ARM64 assembly lifter.
func NewArm64Lifter(knownFuncs map[uint64]bool) *Arm64Lifter {
	return &Arm64Lifter{
		knownFuncs: knownFuncs,
	}
}

// emitUnsupported generates a diagnostic stub that calls recomp_unsupported_instruction.
func (l *Arm64Lifter) emitUnsupported(inst disasm.Instruction, reason string) []string {
	var fnEntry uint64
	if l != nil && l.currentFn != nil {
		fnEntry = l.currentFn.EntryAddr
	}
	msg := reason
	if msg == "" {
		msg = inst.Inst.String()
	}
	l.unsuppCounter++
	strLabel := fmt.Sprintf("L_unsupp_str_0x%x_%d", inst.Address, l.unsuppCounter)
	skipLabel := fmt.Sprintf("L_unsupp_skip_0x%x_%d", inst.Address, l.unsuppCounter)

	var lines []string
	lines = append(lines, fmt.Sprintf("    // UNSUPPORTED: %s", msg))
	lines = append(lines, loadImm64("x0", inst.Address)...)
	lines = append(lines, loadImm64("x1", fnEntry)...)
	lines = append(lines, fmt.Sprintf("    b %s", skipLabel))
	lines = append(lines, fmt.Sprintf("%s:", strLabel))
	escaped := strings.ReplaceAll(msg, "\"", "\\\"")
	lines = append(lines, fmt.Sprintf("    .asciz \"%s\"", escaped))
	lines = append(lines, "    .balign 4")
	lines = append(lines, fmt.Sprintf("%s:", skipLabel))
	lines = append(lines, fmt.Sprintf("    adr x2, %s", strLabel))
	lines = append(lines, "    b _recomp_unsupported_instruction")
	return lines
}

// IsKnownFunc reports whether addr is the entry point of a known function.
func (l *Arm64Lifter) IsKnownFunc(addr uint64) bool {
	return l != nil && l.knownFuncs != nil && l.knownFuncs[addr]
}

// loadImm32 generates instructions to load a 32-bit immediate into a 32-bit register.
func loadImm32(reg string, val uint32) []string {
	if reg == "" {
		return nil
	}
	if val <= 0xffff {
		return []string{fmt.Sprintf("    mov %s, #0x%x", reg, val)}
	}
	low := val & 0xffff
	hi := (val >> 16) & 0xffff
	res := []string{fmt.Sprintf("    movz %s, #0x%x", reg, low)}
	if hi != 0 {
		res = append(res, fmt.Sprintf("    movk %s, #0x%x, lsl #16", reg, hi))
	}
	return res
}

// loadImm64 generates instructions to load an arbitrary 64-bit immediate into a register.
func loadImm64(reg string, val uint64) []string {
	if reg == "" {
		return nil
	}
	if val == 0 {
		return []string{fmt.Sprintf("    mov %s, #0", reg)}
	}
	if val <= 0xffff {
		return []string{fmt.Sprintf("    movz %s, #0x%x", reg, val)}
	}
	var lines []string
	first := true
	for shift := 0; shift < 64; shift += 16 {
		chunk := (val >> shift) & 0xffff
		if chunk != 0 {
			if first {
				lines = append(lines, fmt.Sprintf("    movz %s, #0x%x, lsl #%d", reg, chunk, shift))
				first = false
			} else {
				lines = append(lines, fmt.Sprintf("    movk %s, #0x%x, lsl #%d", reg, chunk, shift))
			}
		}
	}
	if len(lines) == 0 {
		lines = append(lines, fmt.Sprintf("    mov %s, #0", reg))
	}
	return lines
}

// defMemSz determines the effective memory/operand size from an instruction.
func defMemSz(inst disasm.Instruction) int {
	sz := inst.Inst.MemBytes
	if sz == 0 && inst.Inst.DataSize > 0 {
		sz = inst.Inst.DataSize / 8
	}
	if sz == 0 {
		sz = 8
	}
	return sz
}

// computeEffAddr generates instructions to compute a guest memory effective address into targetReg (usually x16).
func computeEffAddr(mem x86asm.Mem, nextPC uint64, targetReg string) []string {
	var lines []string
	disp := int64(int32(mem.Disp))

	// 1. RIP-relative addressing: [rip + disp]
	if mem.Base == x86asm.RIP || (mem.Segment == 0 && mem.Base == 0 && mem.Index == 0 && mem.Disp != 0) {
		effAddr := uint64(int64(nextPC) + disp)
		return loadImm64(targetReg, effAddr)
	}

	// 2. Segment-based (FS: [fs_base + disp])
	if mem.Segment == x86asm.FS {
		if disp != 0 {
			if disp >= 0 && disp <= 4095 {
				lines = append(lines, fmt.Sprintf("    add %s, x27, #%d", targetReg, disp))
			} else if disp < 0 && -disp <= 4095 {
				lines = append(lines, fmt.Sprintf("    sub %s, x27, #%d", targetReg, -disp))
			} else {
				lines = append(lines, loadImm64(targetReg, uint64(disp))...)
				lines = append(lines, fmt.Sprintf("    add %s, x27, %s", targetReg, targetReg))
			}
		} else {
			lines = append(lines, fmt.Sprintf("    mov %s, x27", targetReg))
		}
		return lines
	}

	// 3. Base register
	hasBase := false
	if mem.Base != 0 {
		if armReg, ok := arm64RegMap[mem.Base]; ok {
			lines = append(lines, fmt.Sprintf("    mov %s, %s", targetReg, armReg.X))
			hasBase = true
		}
	}

	// 4. Index * Scale
	if mem.Index != 0 {
		if armIdx, ok := arm64RegMap[mem.Index]; ok {
			shift := 0
			switch mem.Scale {
			case 2:
				shift = 1
			case 4:
				shift = 2
			case 8:
				shift = 3
			}
			if hasBase {
				if shift > 0 {
					lines = append(lines, fmt.Sprintf("    add %s, %s, %s, lsl #%d", targetReg, targetReg, armIdx.X, shift))
				} else {
					lines = append(lines, fmt.Sprintf("    add %s, %s, %s", targetReg, targetReg, armIdx.X))
				}
			} else {
				if shift > 0 {
					lines = append(lines, fmt.Sprintf("    lsl %s, %s, #%d", targetReg, armIdx.X, shift))
				} else {
					lines = append(lines, fmt.Sprintf("    mov %s, %s", targetReg, armIdx.X))
				}
				hasBase = true
			}
		}
	}

	if !hasBase {
		lines = append(lines, fmt.Sprintf("    mov %s, #0", targetReg))
	}

	// 5. Displacement
	if disp != 0 {
		if disp > 0 && disp <= 4095 {
			lines = append(lines, fmt.Sprintf("    add %s, %s, #%d", targetReg, targetReg, disp))
		} else if disp < 0 && -disp <= 4095 {
			lines = append(lines, fmt.Sprintf("    sub %s, %s, #%d", targetReg, targetReg, -disp))
		} else {
			lines = append(lines, loadImm64("x17", uint64(disp))...)
			lines = append(lines, fmt.Sprintf("    add %s, %s, x17", targetReg, targetReg))
		}
	}

	return lines
}

// readRegTo generates code to read the value of an x86 register into targetArmReg (e.g. x16 / w16).
func readRegTo(reg x86asm.Reg, targetX string, targetW string) ([]string, bool) {
	desc, ok := arm64RegMap[reg]
	if !ok {
		return nil, false
	}
	var lines []string
	if desc.IsHigh8 {
		lines = append(lines, fmt.Sprintf("    ubfx %s, %s, #8, #8", targetW, desc.W))
	} else if desc.Size == 1 {
		lines = append(lines, fmt.Sprintf("    and %s, %s, #0xff", targetW, desc.W))
	} else if desc.Size == 2 {
		lines = append(lines, fmt.Sprintf("    and %s, %s, #0xffff", targetW, desc.W))
	} else if desc.Size == 4 {
		lines = append(lines, fmt.Sprintf("    mov %s, %s", targetW, desc.W))
	} else {
		lines = append(lines, fmt.Sprintf("    mov %s, %s", targetX, desc.X))
	}
	return lines, true
}

// writeRegFrom generates code to write the value in srcArmReg (e.g. x16 / w16) into an x86 register.
func writeRegFrom(reg x86asm.Reg, srcX string, srcW string) ([]string, bool) {
	desc, ok := arm64RegMap[reg]
	if !ok {
		return nil, false
	}
	var lines []string
	if desc.IsHigh8 {
		lines = append(lines, fmt.Sprintf("    bfi %s, %s, #8, #8", desc.X, srcX))
	} else if desc.Size == 1 {
		lines = append(lines, fmt.Sprintf("    bfi %s, %s, #0, #8", desc.X, srcX))
	} else if desc.Size == 2 {
		lines = append(lines, fmt.Sprintf("    bfi %s, %s, #0, #16", desc.X, srcX))
	} else if desc.Size == 4 {
		lines = append(lines, fmt.Sprintf("    mov %s, %s", desc.W, srcW)) // zeroes upper 32 bits
	} else {
		lines = append(lines, fmt.Sprintf("    mov %s, %s", desc.X, srcX))
	}
	return lines, true
}

// loadImmToReg writes an immediate value into an x86 register respecting x86 register sizing.
func loadImmToReg(reg x86asm.Reg, val uint64) ([]string, bool) {
	desc, ok := arm64RegMap[reg]
	if !ok {
		return nil, false
	}
	var lines []string
	if desc.IsHigh8 {
		lines = append(lines, fmt.Sprintf("    mov w16, #0x%x", val&0xff))
		lines = append(lines, fmt.Sprintf("    bfi %s, x16, #8, #8", desc.X))
	} else if desc.Size == 1 {
		lines = append(lines, fmt.Sprintf("    mov w16, #0x%x", val&0xff))
		lines = append(lines, fmt.Sprintf("    bfi %s, x16, #0, #8", desc.X))
	} else if desc.Size == 2 {
		lines = append(lines, fmt.Sprintf("    mov w16, #0x%x", val&0xffff))
		lines = append(lines, fmt.Sprintf("    bfi %s, x16, #0, #16", desc.X))
	} else if desc.Size == 4 {
		lines = append(lines, loadImm32(desc.W, uint32(val))...)
	} else {
		lines = append(lines, loadImm64(desc.X, val)...)
	}
	return lines, true
}

// readMemTo generates instructions to read memory into target ARM register.
func readMemTo(mem x86asm.Mem, nextPC uint64, size int, targetX string, targetW string) []string {
	var lines []string
	lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
	switch size {
	case 1:
		lines = append(lines, fmt.Sprintf("    ldrb %s, [x28, x16]", targetW))
	case 2:
		lines = append(lines, fmt.Sprintf("    ldrh %s, [x28, x16]", targetW))
	case 4:
		lines = append(lines, fmt.Sprintf("    ldr %s, [x28, x16]", targetW))
	default:
		lines = append(lines, fmt.Sprintf("    ldr %s, [x28, x16]", targetX))
	}
	return lines
}

// writeMemFrom generates instructions to write from ARM register to guest memory.
func writeMemFrom(mem x86asm.Mem, nextPC uint64, size int, srcX string, srcW string) []string {
	var lines []string
	lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
	switch size {
	case 1:
		lines = append(lines, fmt.Sprintf("    strb %s, [x28, x16]", srcW))
	case 2:
		lines = append(lines, fmt.Sprintf("    strh %s, [x28, x16]", srcW))
	case 4:
		lines = append(lines, fmt.Sprintf("    str %s, [x28, x16]", srcW))
	default:
		lines = append(lines, fmt.Sprintf("    str %s, [x28, x16]", srcX))
	}
	return lines
}

// arm64Cond converts an x86 condition code to ARM64 condition suffix.
func arm64Cond(op x86asm.Op) (string, bool) {
	switch op {
	case x86asm.JE:
		return "eq", true
	case x86asm.JNE:
		return "ne", true
	case x86asm.JB:
		return "cc", true // Carry clear (unsigned lower)
	case x86asm.JAE:
		return "cs", true // Carry set (unsigned higher or same)
	case x86asm.JA:
		return "hi", true // Unsigned higher
	case x86asm.JBE:
		return "ls", true // Unsigned lower or same
	case x86asm.JL:
		return "lt", true // Signed less than
	case x86asm.JGE:
		return "ge", true // Signed greater or equal
	case x86asm.JLE:
		return "le", true // Signed less or equal
	case x86asm.JG:
		return "gt", true // Signed greater than
	case x86asm.JS:
		return "mi", true // Negative (minus)
	case x86asm.JNS:
		return "pl", true // Positive or zero (plus)
	case x86asm.JO:
		return "vs", true // Overflow set
	case x86asm.JNO:
		return "vc", true // Overflow clear
	case x86asm.JP:
		return "vs", true // Parity / FP unordered
	case x86asm.JNP:
		return "vc", true // No parity / FP ordered
	default:
		return "", false
	}
}

func invertArm64Cond(cond string) string {
	switch cond {
	case "eq":
		return "ne"
	case "ne":
		return "eq"
	case "cc":
		return "cs"
	case "cs":
		return "cc"
	case "hi":
		return "ls"
	case "ls":
		return "hi"
	case "lt":
		return "ge"
	case "ge":
		return "lt"
	case "le":
		return "gt"
	case "gt":
		return "le"
	case "mi":
		return "pl"
	case "pl":
		return "mi"
	case "vs":
		return "vc"
	case "vc":
		return "vs"
	default:
		return "ne"
	}
}

// setccCond returns ARM64 condition suffix for SETcc opcodes.
func setccCond(op x86asm.Op) (string, bool) {
	switch op {
	case x86asm.SETE:
		return "eq", true
	case x86asm.SETNE:
		return "ne", true
	case x86asm.SETB:
		return "cc", true
	case x86asm.SETAE:
		return "cs", true
	case x86asm.SETA:
		return "hi", true
	case x86asm.SETBE:
		return "ls", true
	case x86asm.SETL:
		return "lt", true
	case x86asm.SETGE:
		return "ge", true
	case x86asm.SETLE:
		return "le", true
	case x86asm.SETG:
		return "gt", true
	case x86asm.SETS:
		return "mi", true
	case x86asm.SETNS:
		return "pl", true
	case x86asm.SETO:
		return "vs", true
	case x86asm.SETNO:
		return "vc", true
	case x86asm.SETP:
		return "vs", true // Parity / FP unordered
	case x86asm.SETNP:
		return "vc", true // No parity / FP ordered
	default:
		return "", false
	}
}

// cmovccCond returns ARM64 condition suffix for CMOVcc opcodes.
func cmovccCond(op x86asm.Op) (string, bool) {
	switch op {
	case x86asm.CMOVE:
		return "eq", true
	case x86asm.CMOVNE:
		return "ne", true
	case x86asm.CMOVB:
		return "cc", true
	case x86asm.CMOVAE:
		return "cs", true
	case x86asm.CMOVA:
		return "hi", true
	case x86asm.CMOVBE:
		return "ls", true
	case x86asm.CMOVL:
		return "lt", true
	case x86asm.CMOVGE:
		return "ge", true
	case x86asm.CMOVLE:
		return "le", true
	case x86asm.CMOVG:
		return "gt", true
	case x86asm.CMOVS:
		return "mi", true
	case x86asm.CMOVNS:
		return "pl", true
	case x86asm.CMOVO:
		return "vs", true
	case x86asm.CMOVNO:
		return "vc", true
	case x86asm.CMOVP:
		return "vs", true // Parity / FP unordered
	case x86asm.CMOVNP:
		return "vc", true // No parity / FP ordered
	default:
		return "", false
	}
}

// LiftInstructionToBuf translates a single x86 instruction into ARM64 assembly instructions.
func (l *Arm64Lifter) LiftInstructionToBuf(inst disasm.Instruction, nextPC uint64, fn *disasm.Function, dst []string) ([]string, error) {
	l.currentFn = fn
	op := inst.Inst.Op
	args := inst.Inst.Args
	lines := dst

	comment := fmt.Sprintf("    // 0x%x: %s", inst.Address, inst.Inst.String())
	lines = append(lines, comment)

	switch op {
	case x86asm.NOP, x86asm.FNOP, x86asm.FWAIT,
		x86asm.PREFETCHT0, x86asm.PREFETCHNTA, x86asm.PREFETCHT1, x86asm.PREFETCHT2, x86asm.PREFETCHW:
		lines = append(lines, "    nop")
		return lines, nil

	case x86asm.CLD, x86asm.STD:
		// In standard x86-64 System V ABI, direction flag is expected to be forward (0).
		lines = append(lines, "    nop")
		return lines, nil

	case x86asm.PAUSE:
		lines = append(lines, "    yield")
		return lines, nil

	case x86asm.MFENCE:
		lines = append(lines, "    dmb ish")
		return lines, nil

	case x86asm.LFENCE:
		lines = append(lines, "    dmb ishld")
		return lines, nil

	case x86asm.SFENCE:
		lines = append(lines, "    dmb ishst")
		return lines, nil

	case x86asm.UD2:
		lines = append(lines, "    brk #0")
		return lines, nil

	case x86asm.MOV:
		return l.liftMov(inst, nextPC, lines)

	case x86asm.MOVZX:
		return l.liftMovzx(inst, nextPC, lines)

	case x86asm.MOVSX, x86asm.MOVSXD:
		return l.liftMovsx(inst, nextPC, lines)

	case x86asm.LEA:
		mem, ok := args[1].(x86asm.Mem)
		if !ok {
			lines = append(lines, "    brk #0 // unsupported lea operand")
			return lines, nil
		}
		dstReg, ok := args[0].(x86asm.Reg)
		if !ok {
			lines = append(lines, "    brk #0 // unsupported lea dst")
			return lines, nil
		}
		desc, ok := arm64RegMap[dstReg]
		if !ok {
			lines = append(lines, "    brk #0 // unmapped lea dst")
			return lines, nil
		}
		lines = append(lines, computeEffAddr(mem, nextPC, desc.X)...)
		if desc.Size == 4 {
			lines = append(lines, fmt.Sprintf("    mov %s, %s", desc.W, desc.W))
		}
		return lines, nil

	case x86asm.ADD, x86asm.SUB, x86asm.AND, x86asm.OR, x86asm.XOR:
		return l.liftAlu(inst, nextPC, lines)

	case x86asm.CMP, x86asm.TEST:
		return l.liftCmpTest(inst, nextPC, lines)

	case x86asm.INC, x86asm.DEC:
		return l.liftIncDec(inst, nextPC, lines)

	case x86asm.NEG, x86asm.NOT:
		return l.liftNegNot(inst, nextPC, lines)

	case x86asm.SHL, x86asm.SHR, x86asm.SAR, x86asm.ROL, x86asm.ROR:
		return l.liftShift(inst, nextPC, lines)

	case x86asm.IMUL:
		return l.liftImul(inst, nextPC, lines)

	case x86asm.MUL:
		return l.liftMul(inst, nextPC, lines)

	case x86asm.IDIV, x86asm.DIV:
		return l.liftDiv(inst, nextPC, lines)

	case x86asm.XADD:
		return l.liftXadd(inst, nextPC, lines)

	case x86asm.CMPXCHG:
		return l.liftCmpxchg(inst, nextPC, lines)

	case x86asm.XCHG:
		return l.liftXchg(inst, nextPC, lines)

	case x86asm.CDQ:
		lines = append(lines, "    asr x22, x19, #31")
		return lines, nil

	case x86asm.CQO:
		lines = append(lines, "    asr x22, x19, #63")
		return lines, nil

	case x86asm.CDQE:
		lines = append(lines, "    sxtw x19, w19")
		return lines, nil

	case x86asm.CWDE:
		lines = append(lines, "    sxth w19, w19")
		return lines, nil

	case x86asm.CBW:
		lines = append(lines, "    sxtb w16, w19")
		lines = append(lines, "    bfi x19, x16, #0, #16")
		return lines, nil

	case x86asm.BSWAP:
		if reg, ok := args[0].(x86asm.Reg); ok {
			if desc, okDesc := arm64RegMap[reg]; okDesc {
				if desc.Size == 4 {
					lines = append(lines, fmt.Sprintf("    rev %s, %s", desc.W, desc.W))
				} else {
					lines = append(lines, fmt.Sprintf("    rev %s, %s", desc.X, desc.X))
				}
				return lines, nil
			}
		}
		lines = append(lines, "    brk #0 // unsupported bswap")
		return lines, nil

	case x86asm.BSF, x86asm.TZCNT:
		if dstReg, ok := args[0].(x86asm.Reg); ok {
			if descDst, okDst := arm64RegMap[dstReg]; okDst {
				if srcReg, okSrcR := args[1].(x86asm.Reg); okSrcR {
					if descSrc, okSrc := arm64RegMap[srcReg]; okSrc {
						if descDst.Size == 4 {
							lines = append(lines, fmt.Sprintf("    rbit w16, %s", descSrc.W))
							lines = append(lines, fmt.Sprintf("    clz %s, w16", descDst.W))
						} else {
							lines = append(lines, fmt.Sprintf("    rbit x16, %s", descSrc.X))
							lines = append(lines, fmt.Sprintf("    clz %s, x16", descDst.X))
						}
						return lines, nil
					}
				} else if mem, okMem := args[1].(x86asm.Mem); okMem {
					lines = append(lines, readMemTo(mem, nextPC, descDst.Size, "x17", "w17")...)
					if descDst.Size == 4 {
						lines = append(lines, "    rbit w16, w17")
						lines = append(lines, fmt.Sprintf("    clz %s, w16", descDst.W))
					} else {
						lines = append(lines, "    rbit x16, x17")
						lines = append(lines, fmt.Sprintf("    clz %s, x16", descDst.X))
					}
					return lines, nil
				}
			}
		}
		lines = append(lines, l.emitUnsupported(inst, "unsupported bsf/tzcnt")...)
		return lines, nil

	case x86asm.BSR:
		if dstReg, ok := args[0].(x86asm.Reg); ok {
			if descDst, okDst := arm64RegMap[dstReg]; okDst {
				if srcReg, okSrcR := args[1].(x86asm.Reg); okSrcR {
					if descSrc, okSrc := arm64RegMap[srcReg]; okSrc {
						if descDst.Size == 4 {
							lines = append(lines, fmt.Sprintf("    clz w16, %s", descSrc.W))
							lines = append(lines, fmt.Sprintf("    mov %s, #31", descDst.W))
							lines = append(lines, fmt.Sprintf("    sub %s, %s, w16", descDst.W, descDst.W))
						} else {
							lines = append(lines, fmt.Sprintf("    clz x16, %s", descSrc.X))
							lines = append(lines, fmt.Sprintf("    mov %s, #63", descDst.X))
							lines = append(lines, fmt.Sprintf("    sub %s, %s, x16", descDst.X, descDst.X))
						}
						return lines, nil
					}
				} else if mem, okMem := args[1].(x86asm.Mem); okMem {
					lines = append(lines, readMemTo(mem, nextPC, descDst.Size, "x17", "w17")...)
					if descDst.Size == 4 {
						lines = append(lines, "    clz w16, w17")
						lines = append(lines, fmt.Sprintf("    mov %s, #31", descDst.W))
						lines = append(lines, fmt.Sprintf("    sub %s, %s, w16", descDst.W, descDst.W))
					} else {
						lines = append(lines, "    clz x16, x17")
						lines = append(lines, fmt.Sprintf("    mov %s, #63", descDst.X))
						lines = append(lines, fmt.Sprintf("    sub %s, %s, x16", descDst.X, descDst.X))
					}
					return lines, nil
				}
			}
		}
		lines = append(lines, l.emitUnsupported(inst, "unsupported bsr")...)
		return lines, nil

	case x86asm.LZCNT:
		if dstReg, ok := args[0].(x86asm.Reg); ok {
			if descDst, okDst := arm64RegMap[dstReg]; okDst {
				if srcReg, okSrcR := args[1].(x86asm.Reg); okSrcR {
					if descSrc, okSrc := arm64RegMap[srcReg]; okSrc {
						if descDst.Size == 4 {
							lines = append(lines, fmt.Sprintf("    clz %s, %s", descDst.W, descSrc.W))
						} else {
							lines = append(lines, fmt.Sprintf("    clz %s, %s", descDst.X, descSrc.X))
						}
						return lines, nil
					}
				} else if mem, okMem := args[1].(x86asm.Mem); okMem {
					lines = append(lines, readMemTo(mem, nextPC, descDst.Size, "x17", "w17")...)
					if descDst.Size == 4 {
						lines = append(lines, fmt.Sprintf("    clz %s, w17", descDst.W))
					} else {
						lines = append(lines, fmt.Sprintf("    clz %s, x17", descDst.X))
					}
					return lines, nil
				}
			}
		}
		lines = append(lines, l.emitUnsupported(inst, "unsupported lzcnt")...)
		return lines, nil

	case x86asm.JMP:
		if rel, ok := args[0].(x86asm.Rel); ok {
			target := uint64(int64(nextPC) + int64(rel))
			if fn != nil && fn.Blocks[target] != nil {
				lines = append(lines, fmt.Sprintf("    b L_fn_0x%x_loc_0x%x", fn.EntryAddr, target))
			} else if l.IsKnownFunc(target) {
				lines = append(lines, "    ldr x30, [sp], #16")
				lines = append(lines, fmt.Sprintf("    b _fn_0x%x", target))
			} else {
				lines = append(lines, loadImm64("x0", target)...)
				lines = append(lines, "    ldr x30, [sp], #16")
				lines = append(lines, "    b _recomp_indirect_jump")
			}
			return lines, nil
		}
		emitLocalJumpTable := func(targetReg string) {
			if fn != nil && len(fn.Blocks) > 1 && fn.EndAddr > fn.EntryAddr {
				skipLocal := fmt.Sprintf("L_fn_0x%x_not_local_0x%x", fn.EntryAddr, inst.Address)
				lines = append(lines, loadImm64("x16", fn.EntryAddr)...)
				lines = append(lines, fmt.Sprintf("    cmp %s, x16", targetReg))
				lines = append(lines, fmt.Sprintf("    b.lo %s", skipLocal))
				lines = append(lines, loadImm64("x16", fn.EndAddr)...)
				lines = append(lines, fmt.Sprintf("    cmp %s, x16", targetReg))
				lines = append(lines, fmt.Sprintf("    b.hs %s", skipLocal))

				for _, blockAddr := range fn.BlockOrder {
					lines = append(lines, loadImm64("x16", blockAddr)...)
					lines = append(lines, fmt.Sprintf("    cmp %s, x16", targetReg))
					lines = append(lines, fmt.Sprintf("    b.eq L_fn_0x%x_loc_0x%x", fn.EntryAddr, blockAddr))
				}
				lines = append(lines, fmt.Sprintf("%s:", skipLocal))
			}
		}

		if reg, ok := args[0].(x86asm.Reg); ok {
			if desc, okDesc := arm64RegMap[reg]; okDesc {
				lines = append(lines, fmt.Sprintf("    mov x0, %s", desc.X))
				emitLocalJumpTable("x0")
				lines = append(lines, "    ldr x30, [sp], #16")
				lines = append(lines, "    b _recomp_indirect_jump")
				return lines, nil
			}
		}
		if mem, ok := args[0].(x86asm.Mem); ok {
			lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
			lines = append(lines, "    ldr x0, [x28, x16]")
			emitLocalJumpTable("x0")
			lines = append(lines, "    ldr x30, [sp], #16")
			lines = append(lines, "    b _recomp_indirect_jump")
			return lines, nil
		}
		lines = append(lines, "    brk #0 // unsupported indirect jmp")
		return lines, nil

	case x86asm.CALL:
		if rel, ok := args[0].(x86asm.Rel); ok {
			target := uint64(int64(nextPC) + int64(rel))
			lines = append(lines, "    sub x26, x26, #8")
			lines = append(lines, loadImm64("x16", nextPC)...)
			lines = append(lines, "    str x16, [x28, x26]")
			if l.IsKnownFunc(target) {
				lines = append(lines, fmt.Sprintf("    bl _fn_0x%x", target))
			} else {
				lines = append(lines, loadImm64("x0", target)...)
				lines = append(lines, "    bl _recomp_indirect_call")
			}
			return lines, nil
		}
		if reg, ok := args[0].(x86asm.Reg); ok {
			if desc, okDesc := arm64RegMap[reg]; okDesc {
				lines = append(lines, "    sub x26, x26, #8")
				lines = append(lines, loadImm64("x16", nextPC)...)
				lines = append(lines, "    str x16, [x28, x26]")
				lines = append(lines, fmt.Sprintf("    mov x0, %s", desc.X))
				lines = append(lines, "    bl _recomp_indirect_call")
				return lines, nil
			}
		}
		if mem, ok := args[0].(x86asm.Mem); ok {
			lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
			lines = append(lines, "    ldr x0, [x28, x16]")
			lines = append(lines, "    sub x26, x26, #8")
			lines = append(lines, loadImm64("x16", nextPC)...)
			lines = append(lines, "    str x16, [x28, x26]")
			lines = append(lines, "    bl _recomp_indirect_call")
			return lines, nil
		}
		lines = append(lines, "    brk #0 // unsupported indirect call")
		return lines, nil

	case x86asm.RET:
		lines = append(lines, "    ldr x16, [x28, x26]")
		lines = append(lines, "    add x26, x26, #8")
		lines = append(lines, "    ldr x30, [sp], #16")
		lines = append(lines, "    ret")
		return lines, nil

	case x86asm.PUSH:
		lines = append(lines, "    sub x26, x26, #8")
		if reg, ok := args[0].(x86asm.Reg); ok {
			if desc, okDesc := arm64RegMap[reg]; okDesc {
				lines = append(lines, fmt.Sprintf("    str %s, [x28, x26]", desc.X))
				return lines, nil
			}
		} else if imm, ok := args[0].(x86asm.Imm); ok {
			lines = append(lines, loadImm64("x16", uint64(imm))...)
			lines = append(lines, "    str x16, [x28, x26]")
			return lines, nil
		}
		lines = append(lines, "    brk #0 // unsupported push")
		return lines, nil

	case x86asm.POP:
		if reg, ok := args[0].(x86asm.Reg); ok {
			if desc, okDesc := arm64RegMap[reg]; okDesc {
				lines = append(lines, fmt.Sprintf("    ldr %s, [x28, x26]", desc.X))
				lines = append(lines, "    add x26, x26, #8")
				return lines, nil
			}
		}
		lines = append(lines, "    brk #0 // unsupported pop")
		return lines, nil

	// Vector & Floating Point Moves
	case x86asm.MOVAPS, x86asm.MOVUPS, x86asm.MOVDQA, x86asm.MOVDQU, x86asm.MOVAPD, x86asm.MOVUPD:
		return l.liftVectorMove128(inst, nextPC, lines)

	case x86asm.MOVSS:
		return l.liftVectorMove32(inst, nextPC, lines)

	case x86asm.MOVSD, x86asm.MOVSD_XMM:
		return l.liftVectorMove64(inst, nextPC, lines)

	case x86asm.MOVD, x86asm.MOVQ:
		return l.liftMovdMovq(inst, nextPC, lines)

	case x86asm.XORPS, x86asm.XORPD, x86asm.PXOR:
		return l.liftVectorLogic(inst, "eor", lines)

	case x86asm.ANDPS, x86asm.ANDPD, x86asm.PAND:
		return l.liftVectorLogic(inst, "and", lines)

	case x86asm.ORPS, x86asm.ORPD, x86asm.POR:
		return l.liftVectorLogic(inst, "orr", lines)

	case x86asm.ADDSS:
		return l.liftFpAlu(inst, nextPC, "fadd", false, lines)
	case x86asm.SUBSS:
		return l.liftFpAlu(inst, nextPC, "fsub", false, lines)
	case x86asm.MULSS:
		return l.liftFpAlu(inst, nextPC, "fmul", false, lines)
	case x86asm.DIVSS:
		return l.liftFpAlu(inst, nextPC, "fdiv", false, lines)

	case x86asm.ADDSD:
		return l.liftFpAlu(inst, nextPC, "fadd", true, lines)
	case x86asm.SUBSD:
		return l.liftFpAlu(inst, nextPC, "fsub", true, lines)
	case x86asm.MULSD:
		return l.liftFpAlu(inst, nextPC, "fmul", true, lines)
	case x86asm.DIVSD:
		return l.liftFpAlu(inst, nextPC, "fdiv", true, lines)

	case x86asm.UCOMISS, x86asm.COMISS:
		return l.liftFpCmp(inst, nextPC, false, lines)

	case x86asm.UCOMISD, x86asm.COMISD:
		return l.liftFpCmp(inst, nextPC, true, lines)

	case x86asm.CVTSI2SS, x86asm.CVTSI2SD:
		return l.liftCvtsi2fp(inst, nextPC, lines)

	case x86asm.CVTSS2SI, x86asm.CVTSD2SI, x86asm.CVTTSS2SI, x86asm.CVTTSD2SI:
		return l.liftCvtfp2si(inst, nextPC, lines)

	case x86asm.CVTSS2SD, x86asm.CVTSD2SS:
		return l.liftFpConvert(inst, nextPC, lines)

	case x86asm.ADC:
		return l.liftAdcSbb(inst, nextPC, false, lines)

	case x86asm.SBB:
		return l.liftAdcSbb(inst, nextPC, true, lines)

	case x86asm.BT:
		return l.liftBt(inst, nextPC, lines)

	case x86asm.PSHUFD:
		return l.liftPshufd(inst, nextPC, lines)

	case x86asm.PSHUFLW:
		return l.liftPshuflw(inst, nextPC, lines)

	case x86asm.MOVBE:
		return l.liftMovbe(inst, nextPC, lines)

	case x86asm.RDTSC:
		lines = l.liftRdtsc(lines)
		return lines, nil

	case x86asm.POPCNT:
		return l.liftPopcnt(inst, nextPC, lines)

	case x86asm.PANDN, x86asm.PUNPCKLDQ, x86asm.PCMPGTD, x86asm.PMULUDQ,
		x86asm.PADDB, x86asm.PADDW, x86asm.PADDD, x86asm.PADDQ,
		x86asm.PSUBB, x86asm.PSUBW, x86asm.PSUBD, x86asm.PSUBQ,
		x86asm.PCMPEQB, x86asm.PCMPEQW, x86asm.PCMPEQD,
		x86asm.PMAXUB, x86asm.PMINUB, x86asm.PMULLW,
		x86asm.PUNPCKLBW, x86asm.PUNPCKLWD, x86asm.PUNPCKLQDQ,
		x86asm.PUNPCKHBW, x86asm.PUNPCKHWD, x86asm.PUNPCKHDQ, x86asm.PUNPCKHQDQ:
		return l.liftVectorBinary(inst, nextPC, lines)

	case x86asm.PSRLDQ:
		return l.liftVectorByteShift(inst, false, lines)

	case x86asm.PSLLDQ:
		return l.liftVectorByteShift(inst, true, lines)

	case x86asm.PSLLW, x86asm.PSLLD, x86asm.PSLLQ,
		x86asm.PSRLW, x86asm.PSRLD, x86asm.PSRLQ,
		x86asm.PSRAW, x86asm.PSRAD:
		return l.liftVectorShift(inst, nextPC, lines)

	case x86asm.VMOVUPS, x86asm.VMOVUPD, x86asm.VMOVAPS, x86asm.VMOVAPD, x86asm.VMOVDQU, x86asm.VMOVDQA:
		return l.liftAvxMove(inst, nextPC, lines)

	case x86asm.VMOVSS:
		return l.liftAvxScalarMove(inst, nextPC, false, lines)

	case x86asm.VMOVSD:
		return l.liftAvxScalarMove(inst, nextPC, true, lines)

	case x86asm.VZEROUPPER, x86asm.VZEROALL:
		lines = l.liftVzeroupper(lines)
		return lines, nil

	case x86asm.VBROADCASTSS:
		return l.liftVbroadcastss(inst, nextPC, lines)

	case x86asm.VXORPS, x86asm.VXORPD, x86asm.VPXOR:
		return l.liftAvx3Op(inst, nextPC, "eor", false, lines)

	case x86asm.VANDPS, x86asm.VANDPD, x86asm.VPAND:
		return l.liftAvx3Op(inst, nextPC, "and", false, lines)

	case x86asm.VORPS, x86asm.VORPD, x86asm.VPOR:
		return l.liftAvx3Op(inst, nextPC, "orr", false, lines)

	case x86asm.VADDPS:
		return l.liftAvx3Op(inst, nextPC, "fadd", false, lines)

	case x86asm.VMULPS:
		return l.liftAvx3Op(inst, nextPC, "fmul", false, lines)

	case x86asm.VSUBPS:
		return l.liftAvx3Op(inst, nextPC, "fsub", false, lines)

	case x86asm.VDIVPS:
		return l.liftAvx3Op(inst, nextPC, "fdiv", false, lines)

	case x86asm.VADDSS:
		return l.liftAvxScalarAlu(inst, nextPC, "fadd", false, lines)

	case x86asm.VMULSS:
		return l.liftAvxScalarAlu(inst, nextPC, "fmul", false, lines)

	case x86asm.VSUBSS:
		return l.liftAvxScalarAlu(inst, nextPC, "fsub", false, lines)

	case x86asm.VDIVSS:
		return l.liftAvxScalarAlu(inst, nextPC, "fdiv", false, lines)

	case x86asm.VADDSD:
		return l.liftAvxScalarAlu(inst, nextPC, "fadd", true, lines)

	case x86asm.VMULSD:
		return l.liftAvxScalarAlu(inst, nextPC, "fmul", true, lines)

	case x86asm.VSUBSD:
		return l.liftAvxScalarAlu(inst, nextPC, "fsub", true, lines)

	case x86asm.VDIVSD:
		return l.liftAvxScalarAlu(inst, nextPC, "fdiv", true, lines)

	case x86asm.VUCOMISS:
		return l.liftFpCmp(inst, nextPC, false, lines)

	case x86asm.VUCOMISD:
		return l.liftFpCmp(inst, nextPC, true, lines)

	case x86asm.VPADDD:
		return l.liftAvx3Op(inst, nextPC, "add", true, lines)

	case x86asm.VPSUBD:
		return l.liftAvx3Op(inst, nextPC, "sub", true, lines)

	case x86asm.HLT:
		lines = append(lines, "    brk #0")
		return lines, nil

	case x86asm.INT:
		if len(args) > 0 {
			if imm, ok := args[0].(x86asm.Imm); ok && imm == 3 {
				lines = append(lines, "    brk #0")
				return lines, nil
			}
		}
		lines = append(lines, l.emitUnsupported(inst, "unsupported int")...)
		return lines, nil

	default:
		// Check SETcc
		if cond, ok := setccCond(op); ok {
			return l.liftSetcc(inst, nextPC, cond, lines)
		}

		// Check CMOVcc
		if cond, ok := cmovccCond(op); ok {
			return l.liftCmovcc(inst, nextPC, cond, lines)
		}

		// Check conditional branches
		if cond, ok := arm64Cond(op); ok {
			if rel, ok := args[0].(x86asm.Rel); ok {
				target := uint64(int64(nextPC) + int64(rel))
				if fn != nil && fn.Blocks[target] != nil {
					lines = append(lines, fmt.Sprintf("    b.%s L_fn_0x%x_loc_0x%x", cond, fn.EntryAddr, target))
				} else {
					inv := invertArm64Cond(cond)
					skipLabel := fmt.Sprintf("L_fn_0x%x_skip_%d", fn.EntryAddr, l.labelCounter)
					l.labelCounter++
					lines = append(lines, fmt.Sprintf("    b.%s %s", inv, skipLabel))
					if l.IsKnownFunc(target) {
						lines = append(lines, "    ldr x30, [sp], #16")
						lines = append(lines, fmt.Sprintf("    b _fn_0x%x", target))
					} else {
						lines = append(lines, loadImm64("x0", target)...)
						lines = append(lines, "    ldr x30, [sp], #16")
						lines = append(lines, "    b _recomp_indirect_jump")
					}
					lines = append(lines, fmt.Sprintf("%s:", skipLabel))
				}
				return lines, nil
			}
		}

		// Fallback diagnostic
		lines = append(lines, l.emitUnsupported(inst, "")...)
		return lines, nil
	}
}

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
		lines = append(lines, fmt.Sprintf("    ldrb %s, [x28, x16]", descDst.W))
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
		if inst.Inst.Op == x86asm.MOVSXD {
			lines = append(lines, fmt.Sprintf("    ldrsw %s, [x28, x16]", descDst.X))
		} else {
			lines = append(lines, fmt.Sprintf("    ldrsb %s, [x28, x16]", descDst.W))
		}
		return lines, nil
	}

	lines = append(lines, "    brk #0 // unsupported movsx")
	return lines, nil
}

// liftAlu handles ADD, SUB, AND, OR, XOR.
func (l *Arm64Lifter) liftAlu(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	armOp := ""
	updateFlags := !inst.SkipFlags

	switch op {
	case x86asm.ADD:
		if updateFlags {
			armOp = "adds"
		} else {
			armOp = "add"
		}
	case x86asm.SUB:
		if updateFlags {
			armOp = "subs"
		} else {
			armOp = "sub"
		}
	case x86asm.AND:
		if updateFlags {
			armOp = "ands"
		} else {
			armOp = "and"
		}
	case x86asm.OR:
		armOp = "orr"
	case x86asm.XOR:
		armOp = "eor"
	}

	if dstReg, ok := dst.(x86asm.Reg); ok {
		descDst, okDst := arm64RegMap[dstReg]
		if okDst {
			if srcReg, okSrc := src.(x86asm.Reg); okSrc {
				descSrc, okSrcD := arm64RegMap[srcReg]
				if okSrcD {
					if descDst.Size == 1 || descDst.Size == 2 {
						rcD, _ := readRegTo(dstReg, "x17", "w17")
						lines = append(lines, rcD...)
						rcS, _ := readRegTo(srcReg, "x16", "w16")
						lines = append(lines, rcS...)
						lines = append(lines, fmt.Sprintf("    %s w17, w17, w16", armOp))
						wcD, _ := writeRegFrom(dstReg, "x17", "w17")
						lines = append(lines, wcD...)
					} else if descDst.Size == 4 {
						lines = append(lines, fmt.Sprintf("    %s %s, %s, %s", armOp, descDst.W, descDst.W, descSrc.W))
					} else {
						lines = append(lines, fmt.Sprintf("    %s %s, %s, %s", armOp, descDst.X, descDst.X, descSrc.X))
					}
					return lines, nil
				}
			}

			if imm, okImm := src.(x86asm.Imm); okImm {
				val := int64(imm)
				isAddSub := armOp == "add" || armOp == "adds" || armOp == "sub" || armOp == "subs"
				if descDst.Size == 1 || descDst.Size == 2 {
					rcD, _ := readRegTo(dstReg, "x17", "w17")
					lines = append(lines, rcD...)
					lines = append(lines, loadImm32("w16", uint32(val))...)
					lines = append(lines, fmt.Sprintf("    %s w17, w17, w16", armOp))
					wcD, _ := writeRegFrom(dstReg, "x17", "w17")
					lines = append(lines, wcD...)
				} else if descDst.Size == 4 {
					if isAddSub && val >= 0 && val <= 4095 {
						lines = append(lines, fmt.Sprintf("    %s %s, %s, #%d", armOp, descDst.W, descDst.W, val))
					} else {
						lines = append(lines, loadImm32("w16", uint32(val))...)
						lines = append(lines, fmt.Sprintf("    %s %s, %s, w16", armOp, descDst.W, descDst.W))
					}
				} else {
					if isAddSub && val >= 0 && val <= 4095 {
						lines = append(lines, fmt.Sprintf("    %s %s, %s, #%d", armOp, descDst.X, descDst.X, val))
					} else {
						lines = append(lines, loadImm64("x16", uint64(val))...)
						lines = append(lines, fmt.Sprintf("    %s %s, %s, x16", armOp, descDst.X, descDst.X))
					}
				}
				return lines, nil
			}

			if mem, okMem := src.(x86asm.Mem); okMem {
				lines = append(lines, readMemTo(mem, nextPC, descDst.Size, "x16", "w16")...)
				if descDst.Size == 1 || descDst.Size == 2 {
					rcD, _ := readRegTo(dstReg, "x17", "w17")
					lines = append(lines, rcD...)
					lines = append(lines, fmt.Sprintf("    %s w17, w17, w16", armOp))
					wcD, _ := writeRegFrom(dstReg, "x17", "w17")
					lines = append(lines, wcD...)
				} else if descDst.Size == 4 {
					lines = append(lines, fmt.Sprintf("    %s %s, %s, w16", armOp, descDst.W, descDst.W))
				} else {
					lines = append(lines, fmt.Sprintf("    %s %s, %s, x16", armOp, descDst.X, descDst.X))
				}
				return lines, nil
			}
		}
	}

	// Mem, Imm / Mem, Reg
	if mem, okMem := dst.(x86asm.Mem); okMem {
		sz := defMemSz(inst)
		lines = append(lines, readMemTo(mem, nextPC, sz, "x17", "w17")...)
		isAddSub := armOp == "add" || armOp == "adds" || armOp == "sub" || armOp == "subs"
		if imm, okImm := src.(x86asm.Imm); okImm {
			val := int64(imm)
			if sz == 4 {
				if isAddSub && val >= 0 && val <= 4095 {
					lines = append(lines, fmt.Sprintf("    %s w17, w17, #%d", armOp, val))
				} else {
					lines = append(lines, loadImm32("w0", uint32(val))...)
					lines = append(lines, fmt.Sprintf("    %s w17, w17, w0", armOp))
				}
			} else {
				if isAddSub && val >= 0 && val <= 4095 {
					lines = append(lines, fmt.Sprintf("    %s x17, x17, #%d", armOp, val))
				} else {
					lines = append(lines, loadImm64("x0", uint64(val))...)
					lines = append(lines, fmt.Sprintf("    %s x17, x17, x0", armOp))
				}
			}
			switch sz {
			case 1:
				lines = append(lines, "    strb w17, [x28, x16]")
			case 2:
				lines = append(lines, "    strh w17, [x28, x16]")
			case 4:
				lines = append(lines, "    str w17, [x28, x16]")
			default:
				lines = append(lines, "    str x17, [x28, x16]")
			}
			return lines, nil
		}
		if srcReg, okSrc := src.(x86asm.Reg); okSrc {
			if descSrc, okSrcD := arm64RegMap[srcReg]; okSrcD {
				if sz == 4 {
					lines = append(lines, fmt.Sprintf("    %s w17, w17, %s", armOp, descSrc.W))
				} else {
					lines = append(lines, fmt.Sprintf("    %s x17, x17, %s", armOp, descSrc.X))
				}
				switch sz {
				case 1:
					lines = append(lines, "    strb w17, [x28, x16]")
				case 2:
					lines = append(lines, "    strh w17, [x28, x16]")
				case 4:
					lines = append(lines, "    str w17, [x28, x16]")
				default:
					lines = append(lines, "    str x17, [x28, x16]")
				}
				return lines, nil
			}
		}
	}

	lines = append(lines, fmt.Sprintf("    brk #0 // unsupported %s", strings.ToLower(inst.Inst.Op.String())))
	return lines, nil
}

// liftCmpTest handles CMP and TEST.
func (l *Arm64Lifter) liftCmpTest(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	armOp := "cmp"
	if op == x86asm.TEST {
		armOp = "tst"
	}

	if dstReg, ok := dst.(x86asm.Reg); ok {
		descDst, okDst := arm64RegMap[dstReg]
		if okDst {
			if srcReg, okSrc := src.(x86asm.Reg); okSrc {
				descSrc, okSrcD := arm64RegMap[srcReg]
				if okSrcD {
					if descDst.Size == 4 {
						lines = append(lines, fmt.Sprintf("    %s %s, %s", armOp, descDst.W, descSrc.W))
					} else {
						lines = append(lines, fmt.Sprintf("    %s %s, %s", armOp, descDst.X, descSrc.X))
					}
					return lines, nil
				}
			}

			if imm, okImm := src.(x86asm.Imm); okImm {
				val := int64(imm)
				if descDst.Size == 8 {
					if armOp == "cmp" && val >= 0 && val <= 4095 {
						lines = append(lines, fmt.Sprintf("    cmp %s, #%d", descDst.X, val))
					} else {
						lines = append(lines, loadImm64("x16", uint64(val))...)
						lines = append(lines, fmt.Sprintf("    %s %s, x16", armOp, descDst.X))
					}
				} else if descDst.Size == 4 {
					if armOp == "cmp" && val >= 0 && val <= 4095 {
						lines = append(lines, fmt.Sprintf("    cmp %s, #%d", descDst.W, val))
					} else {
						lines = append(lines, loadImm32("w16", uint32(val))...)
						lines = append(lines, fmt.Sprintf("    %s %s, w16", armOp, descDst.W))
					}
				} else {
					rc, _ := readRegTo(dstReg, "x17", "w17")
					lines = append(lines, rc...)
					uval := uint32(val)
					if descDst.Size == 1 {
						uval &= 0xff
					} else {
						uval &= 0xffff
					}
					if armOp == "cmp" && uval <= 4095 {
						lines = append(lines, fmt.Sprintf("    cmp w17, #%d", uval))
					} else {
						lines = append(lines, loadImm32("w16", uval)...)
						lines = append(lines, fmt.Sprintf("    %s w17, w16", armOp))
					}
				}
				return lines, nil
			}

			if mem, okMem := src.(x86asm.Mem); okMem {
				lines = append(lines, readMemTo(mem, nextPC, descDst.Size, "x16", "w16")...)
				if descDst.Size == 4 {
					lines = append(lines, fmt.Sprintf("    %s %s, w16", armOp, descDst.W))
				} else {
					lines = append(lines, fmt.Sprintf("    %s %s, x16", armOp, descDst.X))
				}
				return lines, nil
			}
		}
	}

	// Mem, Imm / Mem, Reg
	if mem, okMem := dst.(x86asm.Mem); okMem {
		sz := defMemSz(inst)
		lines = append(lines, readMemTo(mem, nextPC, sz, "x16", "w16")...)
		if imm, okImm := src.(x86asm.Imm); okImm {
			val := int64(imm)
			if sz == 8 {
				if armOp == "cmp" && val >= 0 && val <= 4095 {
					lines = append(lines, fmt.Sprintf("    cmp x16, #%d", val))
				} else {
					lines = append(lines, loadImm64("x17", uint64(val))...)
					lines = append(lines, fmt.Sprintf("    %s x16, x17", armOp))
				}
			} else {
				uval := uint32(val)
				if sz == 1 {
					uval &= 0xff
				} else if sz == 2 {
					uval &= 0xffff
				}
				if armOp == "cmp" && uval <= 4095 {
					lines = append(lines, fmt.Sprintf("    cmp w16, #%d", uval))
				} else {
					lines = append(lines, loadImm32("w17", uval)...)
					lines = append(lines, fmt.Sprintf("    %s w16, w17", armOp))
				}
			}
			return lines, nil
		}
		if srcReg, okSrc := src.(x86asm.Reg); okSrc {
			if descSrc, okSrcD := arm64RegMap[srcReg]; okSrcD {
				if sz == 4 || sz == 1 || sz == 2 {
					lines = append(lines, fmt.Sprintf("    %s w16, %s", armOp, descSrc.W))
				} else {
					lines = append(lines, fmt.Sprintf("    %s x16, %s", armOp, descSrc.X))
				}
				return lines, nil
			}
		}
	}

	lines = append(lines, fmt.Sprintf("    brk #0 // unsupported %s", strings.ToLower(op.String())))
	return lines, nil
}

// liftIncDec handles INC and DEC.
func (l *Arm64Lifter) liftIncDec(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	dst := inst.Inst.Args[0]

	armOp := "adds"
	if op == x86asm.DEC {
		armOp = "subs"
	}

	if reg, ok := dst.(x86asm.Reg); ok {
		if desc, okDesc := arm64RegMap[reg]; okDesc {
			if desc.Size == 4 {
				lines = append(lines, fmt.Sprintf("    %s %s, %s, #1", armOp, desc.W, desc.W))
			} else {
				lines = append(lines, fmt.Sprintf("    %s %s, %s, #1", armOp, desc.X, desc.X))
			}
			return lines, nil
		}
	}

	if mem, okMem := dst.(x86asm.Mem); okMem {
		sz := defMemSz(inst)
		lines = append(lines, readMemTo(mem, nextPC, sz, "x17", "w17")...)
		if sz == 4 || sz == 1 || sz == 2 {
			lines = append(lines, fmt.Sprintf("    %s w17, w17, #1", armOp))
		} else {
			lines = append(lines, fmt.Sprintf("    %s x17, x17, #1", armOp))
		}
		switch sz {
		case 1:
			lines = append(lines, "    strb w17, [x28, x16]")
		case 2:
			lines = append(lines, "    strh w17, [x28, x16]")
		case 4:
			lines = append(lines, "    str w17, [x28, x16]")
		default:
			lines = append(lines, "    str x17, [x28, x16]")
		}
		return lines, nil
	}

	lines = append(lines, fmt.Sprintf("    brk #0 // unsupported %s", strings.ToLower(op.String())))
	return lines, nil
}

// liftNegNot handles NEG and NOT.
func (l *Arm64Lifter) liftNegNot(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	op := inst.Inst.Op
	dst := inst.Inst.Args[0]

	armOp := "negs"
	if op == x86asm.NOT {
		armOp = "mvn"
	}

	if reg, ok := dst.(x86asm.Reg); ok {
		if desc, okDesc := arm64RegMap[reg]; okDesc {
			if desc.Size == 4 {
				lines = append(lines, fmt.Sprintf("    %s %s, %s", armOp, desc.W, desc.W))
			} else {
				lines = append(lines, fmt.Sprintf("    %s %s, %s", armOp, desc.X, desc.X))
			}
			return lines, nil
		}
	}

	lines = append(lines, fmt.Sprintf("    brk #0 // unsupported %s", strings.ToLower(op.String())))
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
					}
					return lines, nil
				} else if desc.Size == 4 {
					shiftVal &= 31
					if op == x86asm.ROL {
						shiftVal = (32 - shiftVal) & 31
					}
					if shiftVal > 0 {
						lines = append(lines, fmt.Sprintf("    %s %s, %s, #%d", armOp, desc.W, desc.W, shiftVal))
					}
					return lines, nil
				} else {
					// 8-bit or 16-bit
					bitSize := desc.Size * 8
					shiftVal &= 31
					if op == x86asm.ROL {
						shiftVal = (bitSize - (shiftVal % bitSize)) % bitSize
					}
					rc, _ := readRegTo(reg, "x16", "w16")
					lines = append(lines, rc...)
					if shiftVal > 0 {
						lines = append(lines, fmt.Sprintf("    %s w16, w16, #%d", armOp, shiftVal))
					}
					wc, _ := writeRegFrom(reg, "x16", "w16")
					lines = append(lines, wc...)
					return lines, nil
				}
			}
			// Variable shift (CL in x21 / w21)
			if desc.Size == 8 {
				lines = append(lines, fmt.Sprintf("    %s %s, %s, x21", armOp, desc.X, desc.X))
			} else if desc.Size == 4 {
				lines = append(lines, fmt.Sprintf("    %s %s, %s, w21", armOp, desc.W, desc.W))
			} else {
				rc, _ := readRegTo(reg, "x16", "w16")
				lines = append(lines, rc...)
				lines = append(lines, fmt.Sprintf("    %s w16, w16, w21", armOp))
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
				}
			} else {
				bitSize := sz * 8
				shiftVal &= 31
				if op == x86asm.ROL {
					shiftVal = (bitSize - (shiftVal % bitSize)) % bitSize
				}
				if shiftVal > 0 {
					lines = append(lines, fmt.Sprintf("    %s w17, w17, #%d", armOp, shiftVal))
				}
			}
		} else {
			if sz == 8 {
				lines = append(lines, fmt.Sprintf("    %s x17, x17, x21", armOp))
			} else {
				lines = append(lines, fmt.Sprintf("    %s w17, w17, w21", armOp))
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
	if args[0] != nil && args[1] != nil && args[2] != nil {
		dstReg, okDst := args[0].(x86asm.Reg)
		srcReg, okSrc := args[1].(x86asm.Reg)
		imm, okImm := args[2].(x86asm.Imm)
		descDst, okDescDst := arm64RegMap[dstReg]
		descSrc, okDescSrc := arm64RegMap[srcReg]
		if okDst && okSrc && okImm && okDescDst && okDescSrc {
			lines = append(lines, loadImm32("w16", uint32(imm))...)
			if descDst.Size == 4 {
				lines = append(lines, fmt.Sprintf("    mul %s, %s, w16", descDst.W, descSrc.W))
			} else {
				lines = append(lines, fmt.Sprintf("    mul %s, %s, x16", descDst.X, descSrc.X))
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
			if desc.Size == 4 {
				lines = append(lines, fmt.Sprintf("    umull x16, w19, %s", desc.W))
				lines = append(lines, "    mov w19, w16")
				lines = append(lines, "    lsr x22, x16, #32")
			} else {
				lines = append(lines, fmt.Sprintf("    umulh x22, x19, %s", desc.X))
				lines = append(lines, fmt.Sprintf("    mul x19, x19, %s", desc.X))
			}
			return lines, nil
		}
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
			if desc.Size == 4 {
				lines = append(lines, fmt.Sprintf("    %s w16, w19, %s", divOp, desc.W))
				lines = append(lines, fmt.Sprintf("    msub w22, w16, %s, w19", desc.W))
				lines = append(lines, "    mov w19, w16")
			} else {
				lines = append(lines, fmt.Sprintf("    %s x16, x19, %s", divOp, desc.X))
				lines = append(lines, fmt.Sprintf("    msub x22, x16, %s, x19", desc.X))
				lines = append(lines, "    mov x19, x16")
			}
			return lines, nil
		}
	}
	lines = append(lines, "    brk #0 // unsupported div")
	return lines, nil
}

// liftSetcc handles SETcc.
func (l *Arm64Lifter) liftSetcc(inst disasm.Instruction, nextPC uint64, cond string, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	lines = append(lines, fmt.Sprintf("    cset w16, %s", cond))

	if reg, ok := dst.(x86asm.Reg); ok {
		storeCode, okStore := writeRegFrom(reg, "x16", "w16")
		if okStore {
			lines = append(lines, storeCode...)
			return lines, nil
		}
	}

	if mem, ok := dst.(x86asm.Mem); ok {
		lines = append(lines, writeMemFrom(mem, nextPC, 1, "x16", "w16")...)
		return lines, nil
	}

	lines = append(lines, "    brk #0 // unsupported setcc")
	return lines, nil
}

// liftCmovcc handles CMOVcc.
func (l *Arm64Lifter) liftCmovcc(inst disasm.Instruction, nextPC uint64, cond string, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	src := inst.Inst.Args[1]

	descDst, okDescDst := arm64RegMap[dstReg]
	if !okDst || !okDescDst {
		lines = append(lines, "    brk #0 // unsupported cmov dst")
		return lines, nil
	}

	if srcReg, okSrc := src.(x86asm.Reg); okSrc {
		if descSrc, okDescSrc := arm64RegMap[srcReg]; okDescSrc {
			if descDst.Size == 4 {
				lines = append(lines, fmt.Sprintf("    csel %s, %s, %s, %s", descDst.W, descSrc.W, descDst.W, cond))
			} else {
				lines = append(lines, fmt.Sprintf("    csel %s, %s, %s, %s", descDst.X, descSrc.X, descDst.X, cond))
			}
			return lines, nil
		}
	}

	if mem, okMem := src.(x86asm.Mem); okMem {
		lines = append(lines, readMemTo(mem, nextPC, descDst.Size, "x16", "w16")...)
		if descDst.Size == 4 {
			lines = append(lines, fmt.Sprintf("    csel %s, w16, %s, %s", descDst.W, descDst.W, cond))
		} else {
			lines = append(lines, fmt.Sprintf("    csel %s, x16, %s, %s", descDst.X, descDst.X, cond))
		}
		return lines, nil
	}

	lines = append(lines, "    brk #0 // unsupported cmov")
	return lines, nil
}

// liftVectorMove128 handles MOVAPS, MOVUPS, MOVDQA, MOVDQU.
func (l *Arm64Lifter) liftVectorMove128(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	if dstReg, okDst := dst.(x86asm.Reg); okDst {
		if xmmDst, okXD := arm64XmmMap[dstReg]; okXD {
			if srcReg, okSrc := src.(x86asm.Reg); okSrc {
				if xmmSrc, okXS := arm64XmmMap[srcReg]; okXS {
					lines = append(lines, fmt.Sprintf("    mov %s.16b, %s.16b", xmmDst.V, xmmSrc.V))
					return lines, nil
				}
			}
			if mem, okMem := src.(x86asm.Mem); okMem {
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				lines = append(lines, fmt.Sprintf("    ldr %s, [x28, x16]", xmmDst.Q))
				return lines, nil
			}
		}
	}

	if mem, okMem := dst.(x86asm.Mem); okMem {
		if srcReg, okSrc := src.(x86asm.Reg); okSrc {
			if xmmSrc, okXS := arm64XmmMap[srcReg]; okXS {
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				lines = append(lines, fmt.Sprintf("    str %s, [x28, x16]", xmmSrc.Q))
				return lines, nil
			}
		}
	}

	lines = append(lines, "    brk #0 // unsupported vector move")
	return lines, nil
}

// liftVectorMove32 handles MOVSS.
func (l *Arm64Lifter) liftVectorMove32(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	if dstReg, okDst := dst.(x86asm.Reg); okDst {
		if xmmDst, okXD := arm64XmmMap[dstReg]; okXD {
			if srcReg, okSrc := src.(x86asm.Reg); okSrc {
				if xmmSrc, okXS := arm64XmmMap[srcReg]; okXS {
					lines = append(lines, fmt.Sprintf("    fmov %s, %s", xmmDst.S, xmmSrc.S))
					return lines, nil
				}
			}
			if mem, okMem := src.(x86asm.Mem); okMem {
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				lines = append(lines, fmt.Sprintf("    ldr %s, [x28, x16]", xmmDst.S))
				return lines, nil
			}
		}
	}

	if mem, okMem := dst.(x86asm.Mem); okMem {
		if srcReg, okSrc := src.(x86asm.Reg); okSrc {
			if xmmSrc, okXS := arm64XmmMap[srcReg]; okXS {
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				lines = append(lines, fmt.Sprintf("    str %s, [x28, x16]", xmmSrc.S))
				return lines, nil
			}
		}
	}

	lines = append(lines, "    brk #0 // unsupported movss")
	return lines, nil
}

// liftVectorMove64 handles MOVSD.
func (l *Arm64Lifter) liftVectorMove64(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	if dstReg, okDst := dst.(x86asm.Reg); okDst {
		if xmmDst, okXD := arm64XmmMap[dstReg]; okXD {
			if srcReg, okSrc := src.(x86asm.Reg); okSrc {
				if xmmSrc, okXS := arm64XmmMap[srcReg]; okXS {
					lines = append(lines, fmt.Sprintf("    fmov %s, %s", xmmDst.D, xmmSrc.D))
					return lines, nil
				}
			}
			if mem, okMem := src.(x86asm.Mem); okMem {
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				lines = append(lines, fmt.Sprintf("    ldr %s, [x28, x16]", xmmDst.D))
				return lines, nil
			}
		}
	}

	if mem, okMem := dst.(x86asm.Mem); okMem {
		if srcReg, okSrc := src.(x86asm.Reg); okSrc {
			if xmmSrc, okXS := arm64XmmMap[srcReg]; okXS {
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				lines = append(lines, fmt.Sprintf("    str %s, [x28, x16]", xmmSrc.D))
				return lines, nil
			}
		}
	}

	lines = append(lines, "    brk #0 // unsupported movsd")
	return lines, nil
}

// liftMovdMovq handles MOVD and MOVQ between GPR/memory and XMM.
func (l *Arm64Lifter) liftMovdMovq(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]
	is64 := inst.Inst.Op == x86asm.MOVQ

	if dstReg, okDst := dst.(x86asm.Reg); okDst {
		// XMM <- GPR
		if xmmDst, okXD := arm64XmmMap[dstReg]; okXD {
			if srcReg, okSrc := src.(x86asm.Reg); okSrc {
				if descSrc, okDesc := arm64RegMap[srcReg]; okDesc {
					if is64 {
						lines = append(lines, fmt.Sprintf("    fmov %s, %s", xmmDst.D, descSrc.X))
					} else {
						lines = append(lines, fmt.Sprintf("    fmov %s, %s", xmmDst.S, descSrc.W))
					}
					return lines, nil
				}
			}
			if mem, okMem := src.(x86asm.Mem); okMem {
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				if is64 {
					lines = append(lines, fmt.Sprintf("    ldr %s, [x28, x16]", xmmDst.D))
				} else {
					lines = append(lines, fmt.Sprintf("    ldr %s, [x28, x16]", xmmDst.S))
				}
				return lines, nil
			}
		}
		// GPR <- XMM
		if descDst, okDesc := arm64RegMap[dstReg]; okDesc {
			if srcReg, okSrc := src.(x86asm.Reg); okSrc {
				if xmmSrc, okXS := arm64XmmMap[srcReg]; okXS {
					if is64 {
						lines = append(lines, fmt.Sprintf("    fmov %s, %s", descDst.X, xmmSrc.D))
					} else {
						lines = append(lines, fmt.Sprintf("    fmov %s, %s", descDst.W, xmmSrc.S))
					}
					return lines, nil
				}
			}
		}
	}

	lines = append(lines, "    brk #0 // unsupported movd/movq")
	return lines, nil
}

// liftVectorLogic handles XORPS, ANDPS, ORPS, PXOR, PAND, POR.
func (l *Arm64Lifter) liftVectorLogic(inst disasm.Instruction, armOp string, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	dstReg, okDst := dst.(x86asm.Reg)
	srcReg, okSrc := src.(x86asm.Reg)
	xmmDst, okXD := arm64XmmMap[dstReg]
	xmmSrc, okXS := arm64XmmMap[srcReg]

	if okDst && okSrc && okXD && okXS {
		lines = append(lines, fmt.Sprintf("    %s %s.16b, %s.16b, %s.16b", armOp, xmmDst.V, xmmDst.V, xmmSrc.V))
		return lines, nil
	}

	lines = append(lines, fmt.Sprintf("    brk #0 // unsupported vector %s", armOp))
	return lines, nil
}

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

// liftFpCmp handles UCOMISS and UCOMISD.
func (l *Arm64Lifter) liftFpCmp(inst disasm.Instruction, nextPC uint64, isDouble bool, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	dstReg, okDst := dst.(x86asm.Reg)
	xmmDst, okXD := arm64XmmMap[dstReg]
	if !okDst || !okXD {
		lines = append(lines, "    brk #0 // unsupported fp cmp dst")
		return lines, nil
	}

	if srcReg, okSrc := src.(x86asm.Reg); okSrc {
		if xmmSrc, okXS := arm64XmmMap[srcReg]; okXS {
			if isDouble {
				lines = append(lines, fmt.Sprintf("    fcmp %s, %s", xmmDst.D, xmmSrc.D))
			} else {
				lines = append(lines, fmt.Sprintf("    fcmp %s, %s", xmmDst.S, xmmSrc.S))
			}
			return lines, nil
		}
	}

	lines = append(lines, "    brk #0 // unsupported fp cmp")
	return lines, nil
}

// liftCvtsi2fp handles CVTSI2SS and CVTSI2SD.
func (l *Arm64Lifter) liftCvtsi2fp(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	xmmDst, okXD := arm64XmmMap[dstReg]
	isDouble := inst.Inst.Op == x86asm.CVTSI2SD

	if !okDst || !okXD {
		lines = append(lines, "    brk #0 // unsupported cvtsi2fp dst")
		return lines, nil
	}

	if srcReg, okSrc := inst.Inst.Args[1].(x86asm.Reg); okSrc {
		if descSrc, okDesc := arm64RegMap[srcReg]; okDesc {
			if isDouble {
				if descSrc.Size == 4 {
					lines = append(lines, fmt.Sprintf("    scvtf %s, %s", xmmDst.D, descSrc.W))
				} else {
					lines = append(lines, fmt.Sprintf("    scvtf %s, %s", xmmDst.D, descSrc.X))
				}
			} else {
				if descSrc.Size == 4 {
					lines = append(lines, fmt.Sprintf("    scvtf %s, %s", xmmDst.S, descSrc.W))
				} else {
					lines = append(lines, fmt.Sprintf("    scvtf %s, %s", xmmDst.S, descSrc.X))
				}
			}
			return lines, nil
		}
	}

	lines = append(lines, "    brk #0 // unsupported cvtsi2fp")
	return lines, nil
}

// liftCvtfp2si handles CVTSS2SI, CVTSD2SI, CVTTSS2SI, CVTTSD2SI.
func (l *Arm64Lifter) liftCvtfp2si(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	descDst, okDesc := arm64RegMap[dstReg]
	isDouble := inst.Inst.Op == x86asm.CVTSD2SI || inst.Inst.Op == x86asm.CVTTSD2SI

	if !okDst || !okDesc {
		lines = append(lines, "    brk #0 // unsupported cvtfp2si dst")
		return lines, nil
	}

	if srcReg, okSrc := inst.Inst.Args[1].(x86asm.Reg); okSrc {
		if xmmSrc, okXS := arm64XmmMap[srcReg]; okXS {
			if isDouble {
				if descDst.Size == 4 {
					lines = append(lines, fmt.Sprintf("    fcvtzs %s, %s", descDst.W, xmmSrc.D))
				} else {
					lines = append(lines, fmt.Sprintf("    fcvtzs %s, %s", descDst.X, xmmSrc.D))
				}
			} else {
				if descDst.Size == 4 {
					lines = append(lines, fmt.Sprintf("    fcvtzs %s, %s", descDst.W, xmmSrc.S))
				} else {
					lines = append(lines, fmt.Sprintf("    fcvtzs %s, %s", descDst.X, xmmSrc.S))
				}
			}
			return lines, nil
		}
	}

	lines = append(lines, "    brk #0 // unsupported cvtfp2si")
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

// liftAdcSbb handles ADC and SBB operations.
func (l *Arm64Lifter) liftAdcSbb(inst disasm.Instruction, nextPC uint64, isSbb bool, lines []string) ([]string, error) {
	armOp := "adcs"
	if isSbb {
		armOp = "sbcs"
	}
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	// Reg <- Reg
	if dstReg, okDst := dst.(x86asm.Reg); okDst {
		descDst, okDstD := arm64RegMap[dstReg]
		if okDstD {
			if srcReg, okSrc := src.(x86asm.Reg); okSrc {
				descSrc, okSrcD := arm64RegMap[srcReg]
				if okSrcD {
					if descDst.Size == 8 && descSrc.Size == 8 {
						lines = append(lines, fmt.Sprintf("    %s %s, %s, %s", armOp, descDst.X, descDst.X, descSrc.X))
						return lines, nil
					} else if descDst.Size == 4 && descSrc.Size == 4 {
						lines = append(lines, fmt.Sprintf("    %s %s, %s, %s", armOp, descDst.W, descDst.W, descSrc.W))
						return lines, nil
					} else {
						rcDst, _ := readRegTo(dstReg, "x16", "w16")
						rcSrc, _ := readRegTo(srcReg, "x17", "w17")
						lines = append(lines, rcDst...)
						lines = append(lines, rcSrc...)
						lines = append(lines, fmt.Sprintf("    %s w16, w16, w17", armOp))
						wcDst, _ := writeRegFrom(dstReg, "x16", "w16")
						lines = append(lines, wcDst...)
						return lines, nil
					}
				}
			}

			// Reg <- Imm
			if imm, okImm := src.(x86asm.Imm); okImm {
				val := int64(imm)
				if descDst.Size == 8 {
					lines = append(lines, loadImm64("x16", uint64(val))...)
					lines = append(lines, fmt.Sprintf("    %s %s, %s, x16", armOp, descDst.X, descDst.X))
					return lines, nil
				} else if descDst.Size == 4 {
					lines = append(lines, loadImm32("w16", uint32(val))...)
					lines = append(lines, fmt.Sprintf("    %s %s, %s, w16", armOp, descDst.W, descDst.W))
					return lines, nil
				} else {
					rcDst, _ := readRegTo(dstReg, "x16", "w16")
					lines = append(lines, rcDst...)
					lines = append(lines, loadImm32("w17", uint32(val))...)
					lines = append(lines, fmt.Sprintf("    %s w16, w16, w17", armOp))
					wcDst, _ := writeRegFrom(dstReg, "x16", "w16")
					lines = append(lines, wcDst...)
					return lines, nil
				}
			}

			// Reg <- Mem
			if mem, okMem := src.(x86asm.Mem); okMem {
				lines = append(lines, readMemTo(mem, nextPC, descDst.Size, "x16", "w16")...)
				if descDst.Size == 8 {
					lines = append(lines, fmt.Sprintf("    %s %s, %s, x16", armOp, descDst.X, descDst.X))
				} else if descDst.Size == 4 {
					lines = append(lines, fmt.Sprintf("    %s %s, %s, w16", armOp, descDst.W, descDst.W))
				} else {
					rcDst, _ := readRegTo(dstReg, "x17", "w17")
					lines = append(lines, rcDst...)
					lines = append(lines, fmt.Sprintf("    %s w17, w17, w16", armOp))
					wcDst, _ := writeRegFrom(dstReg, "x17", "w17")
					lines = append(lines, wcDst...)
				}
				return lines, nil
			}
		}
	}

	// Mem <- Imm / Mem <- Reg
	if mem, okMem := dst.(x86asm.Mem); okMem {
		sz := defMemSz(inst)
		lines = append(lines, readMemTo(mem, nextPC, sz, "x17", "w17")...)
		if imm, okImm := src.(x86asm.Imm); okImm {
			val := int64(imm)
			if sz == 8 {
				lines = append(lines, loadImm64("x0", uint64(val))...)
				lines = append(lines, fmt.Sprintf("    %s x17, x17, x0", armOp))
				lines = append(lines, "    str x17, [x28, x16]")
			} else {
				lines = append(lines, loadImm32("w0", uint32(val))...)
				lines = append(lines, fmt.Sprintf("    %s w17, w17, w0", armOp))
				switch sz {
				case 1:
					lines = append(lines, "    strb w17, [x28, x16]")
				case 2:
					lines = append(lines, "    strh w17, [x28, x16]")
				default:
					lines = append(lines, "    str w17, [x28, x16]")
				}
			}
			return lines, nil
		}
		if srcReg, okSrc := src.(x86asm.Reg); okSrc {
			if descSrc, okSrcD := arm64RegMap[srcReg]; okSrcD {
				if sz == 8 {
					lines = append(lines, fmt.Sprintf("    %s x17, x17, %s", armOp, descSrc.X))
					lines = append(lines, "    str x17, [x28, x16]")
				} else {
					lines = append(lines, fmt.Sprintf("    %s w17, w17, %s", armOp, descSrc.W))
					switch sz {
					case 1:
						lines = append(lines, "    strb w17, [x28, x16]")
					case 2:
						lines = append(lines, "    strh w17, [x28, x16]")
					default:
						lines = append(lines, "    str w17, [x28, x16]")
					}
				}
				return lines, nil
			}
		}
	}

	lines = append(lines, l.emitUnsupported(inst, "unsupported adc/sbb operand")...)
	return lines, nil
}

// liftBt handles BT (Bit Test).
func (l *Arm64Lifter) liftBt(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	dstReg, okDst := dst.(x86asm.Reg)
	if !okDst {
		lines = append(lines, l.emitUnsupported(inst, "unsupported bt dst")...)
		return lines, nil
	}
	descDst, okDstD := arm64RegMap[dstReg]
	if !okDstD {
		lines = append(lines, l.emitUnsupported(inst, "unmapped bt dst")...)
		return lines, nil
	}

	bitWidth := descDst.Size * 8

	// Src is immediate
	if imm, okImm := src.(x86asm.Imm); okImm {
		bitIdx := uint64(imm) % uint64(bitWidth)
		if descDst.Size == 8 {
			lines = append(lines, fmt.Sprintf("    ubfx x16, %s, #%d, #1", descDst.X, bitIdx))
			lines = append(lines, "    cmp xzr, x16")
		} else if descDst.Size == 4 {
			lines = append(lines, fmt.Sprintf("    ubfx w16, %s, #%d, #1", descDst.W, bitIdx))
			lines = append(lines, "    cmp wzr, w16")
		} else {
			rc, _ := readRegTo(dstReg, "x17", "w17")
			lines = append(lines, rc...)
			lines = append(lines, fmt.Sprintf("    ubfx w16, w17, #%d, #1", bitIdx))
			lines = append(lines, "    cmp wzr, w16")
		}
		return lines, nil
	}

	// Src is register
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
		} else if descDst.Size == 4 {
			lines = append(lines, fmt.Sprintf("    and w17, %s, #31", descSrc.W))
			lines = append(lines, fmt.Sprintf("    lsr w16, %s, w17", descDst.W))
			lines = append(lines, "    and w16, w16, #1")
			lines = append(lines, "    cmp wzr, w16")
		} else {
			rcDst, _ := readRegTo(dstReg, "x16", "w16")
			rcSrc, _ := readRegTo(srcReg, "x17", "w17")
			lines = append(lines, rcDst...)
			lines = append(lines, rcSrc...)
			mask := bitWidth - 1
			lines = append(lines, fmt.Sprintf("    and w17, w17, #%d", mask))
			lines = append(lines, "    lsr w16, w16, w17")
			lines = append(lines, "    and w16, w16, #1")
			lines = append(lines, "    cmp wzr, w16")
		}
		return lines, nil
	}

	lines = append(lines, l.emitUnsupported(inst, "unsupported bt operand")...)
	return lines, nil
}

// liftFpConvert handles CVTSS2SD and CVTSD2SS.
func (l *Arm64Lifter) liftFpConvert(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	xmmDst, okXD := arm64XmmMap[dstReg]
	if !okDst || !okXD {
		lines = append(lines, l.emitUnsupported(inst, "unsupported fp convert dst")...)
		return lines, nil
	}

	isSS2SD := inst.Inst.Op == x86asm.CVTSS2SD
	src := inst.Inst.Args[1]

	if srcReg, okSrc := src.(x86asm.Reg); okSrc {
		if xmmSrc, okXS := arm64XmmMap[srcReg]; okXS {
			if isSS2SD {
				lines = append(lines, fmt.Sprintf("    fcvt %s, %s", xmmDst.D, xmmSrc.S))
			} else {
				lines = append(lines, fmt.Sprintf("    fcvt %s, %s", xmmDst.S, xmmSrc.D))
			}
			return lines, nil
		}
	}

	if mem, okMem := src.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		if isSS2SD {
			lines = append(lines, "    ldr s31, [x28, x16]")
			lines = append(lines, fmt.Sprintf("    fcvt %s, s31", xmmDst.D))
		} else {
			lines = append(lines, "    ldr d31, [x28, x16]")
			lines = append(lines, fmt.Sprintf("    fcvt %s, d31", xmmDst.S))
		}
		return lines, nil
	}

	lines = append(lines, l.emitUnsupported(inst, "unsupported fp convert operand")...)
	return lines, nil
}

// liftPshufd handles PSHUFD.
func (l *Arm64Lifter) liftPshufd(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	xmmDst, okXD := arm64XmmMap[dstReg]
	if !okDst || !okXD {
		lines = append(lines, l.emitUnsupported(inst, "unsupported pshufd dst")...)
		return lines, nil
	}

	src := inst.Inst.Args[1]
	imm, okImm := inst.Inst.Args[2].(x86asm.Imm)
	if !okImm {
		lines = append(lines, l.emitUnsupported(inst, "unsupported pshufd imm")...)
		return lines, nil
	}

	srcRegStr := ""
	if srcReg, okSrc := src.(x86asm.Reg); okSrc {
		if xmmSrc, okXS := arm64XmmMap[srcReg]; okXS {
			srcRegStr = xmmSrc.V
		}
	} else if mem, okMem := src.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		lines = append(lines, "    ldr q31, [x28, x16]")
		srcRegStr = "v31"
	}
	if srcRegStr == "" {
		lines = append(lines, l.emitUnsupported(inst, "unsupported pshufd src")...)
		return lines, nil
	}

	immVal := uint8(imm)
	if immVal == 0x00 {
		lines = append(lines, fmt.Sprintf("    dup %s.4s, %s.s[0]", xmmDst.V, srcRegStr))
		return lines, nil
	} else if immVal == 0x55 {
		lines = append(lines, fmt.Sprintf("    dup %s.4s, %s.s[1]", xmmDst.V, srcRegStr))
		return lines, nil
	} else if immVal == 0xaa {
		lines = append(lines, fmt.Sprintf("    dup %s.4s, %s.s[2]", xmmDst.V, srcRegStr))
		return lines, nil
	} else if immVal == 0xff {
		lines = append(lines, fmt.Sprintf("    dup %s.4s, %s.s[3]", xmmDst.V, srcRegStr))
		return lines, nil
	}

	var maskBytes [16]byte
	for lane := 0; lane < 4; lane++ {
		srcLane := (immVal >> (lane * 2)) & 3
		for b := 0; b < 4; b++ {
			maskBytes[lane*4+b] = srcLane*4 + byte(b)
		}
	}
	var low64, high64 uint64
	for i := 0; i < 8; i++ {
		low64 |= uint64(maskBytes[i]) << (i * 8)
		high64 |= uint64(maskBytes[8+i]) << (i * 8)
	}

	lines = append(lines, loadImm64("x16", low64)...)
	lines = append(lines, loadImm64("x17", high64)...)
	lines = append(lines, "    fmov d30, x16")
	lines = append(lines, "    mov v30.d[1], x17")
	lines = append(lines, fmt.Sprintf("    tbl %s.16b, {%s.16b}, v30.16b", xmmDst.V, srcRegStr))
	return lines, nil
}

// liftPshuflw handles PSHUFLW.
func (l *Arm64Lifter) liftPshuflw(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	xmmDst, okXD := arm64XmmMap[dstReg]
	if !okDst || !okXD {
		lines = append(lines, l.emitUnsupported(inst, "unsupported pshuflw dst")...)
		return lines, nil
	}

	src := inst.Inst.Args[1]
	imm, okImm := inst.Inst.Args[2].(x86asm.Imm)
	if !okImm {
		lines = append(lines, l.emitUnsupported(inst, "unsupported pshuflw imm")...)
		return lines, nil
	}

	srcRegStr := ""
	if srcReg, okSrc := src.(x86asm.Reg); okSrc {
		if xmmSrc, okXS := arm64XmmMap[srcReg]; okXS {
			srcRegStr = xmmSrc.V
		}
	} else if mem, okMem := src.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		lines = append(lines, "    ldr q31, [x28, x16]")
		srcRegStr = "v31"
	}
	if srcRegStr == "" {
		lines = append(lines, l.emitUnsupported(inst, "unsupported pshuflw src")...)
		return lines, nil
	}

	immVal := uint8(imm)
	var maskBytes [16]byte
	for lane := 0; lane < 4; lane++ {
		srcLane := (immVal >> (lane * 2)) & 3
		maskBytes[lane*2] = srcLane * 2
		maskBytes[lane*2+1] = srcLane*2 + 1
	}
	for i := 8; i < 16; i++ {
		maskBytes[i] = byte(i)
	}
	var low64, high64 uint64
	for i := 0; i < 8; i++ {
		low64 |= uint64(maskBytes[i]) << (i * 8)
		high64 |= uint64(maskBytes[8+i]) << (i * 8)
	}

	lines = append(lines, loadImm64("x16", low64)...)
	lines = append(lines, loadImm64("x17", high64)...)
	lines = append(lines, "    fmov d30, x16")
	lines = append(lines, "    mov v30.d[1], x17")
	lines = append(lines, fmt.Sprintf("    tbl %s.16b, {%s.16b}, v30.16b", xmmDst.V, srcRegStr))
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

// liftVectorBinary handles 128-bit SIMD binary operations.
func (l *Arm64Lifter) liftVectorBinary(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	xmmDst, okXD := arm64XmmMap[dstReg]
	if !okDst || !okXD {
		lines = append(lines, l.emitUnsupported(inst, "unsupported simd binary dst")...)
		return lines, nil
	}

	src := inst.Inst.Args[1]
	srcRegStr := ""
	if srcReg, okSrc := src.(x86asm.Reg); okSrc {
		if xmmSrc, okXS := arm64XmmMap[srcReg]; okXS {
			srcRegStr = xmmSrc.V
		}
	} else if mem, okMem := src.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		lines = append(lines, "    ldr q31, [x28, x16]")
		srcRegStr = "v31"
	}
	if srcRegStr == "" {
		lines = append(lines, l.emitUnsupported(inst, "unsupported simd binary src")...)
		return lines, nil
	}

	switch inst.Inst.Op {
	case x86asm.PADDB:
		lines = append(lines, fmt.Sprintf("    add %s.16b, %s.16b, %s.16b", xmmDst.V, xmmDst.V, srcRegStr))
	case x86asm.PADDW:
		lines = append(lines, fmt.Sprintf("    add %s.8h, %s.8h, %s.8h", xmmDst.V, xmmDst.V, srcRegStr))
	case x86asm.PADDD:
		lines = append(lines, fmt.Sprintf("    add %s.4s, %s.4s, %s.4s", xmmDst.V, xmmDst.V, srcRegStr))
	case x86asm.PADDQ:
		lines = append(lines, fmt.Sprintf("    add %s.2d, %s.2d, %s.2d", xmmDst.V, xmmDst.V, srcRegStr))

	case x86asm.PSUBB:
		lines = append(lines, fmt.Sprintf("    sub %s.16b, %s.16b, %s.16b", xmmDst.V, xmmDst.V, srcRegStr))
	case x86asm.PSUBW:
		lines = append(lines, fmt.Sprintf("    sub %s.8h, %s.8h, %s.8h", xmmDst.V, xmmDst.V, srcRegStr))
	case x86asm.PSUBD:
		lines = append(lines, fmt.Sprintf("    sub %s.4s, %s.4s, %s.4s", xmmDst.V, xmmDst.V, srcRegStr))
	case x86asm.PSUBQ:
		lines = append(lines, fmt.Sprintf("    sub %s.2d, %s.2d, %s.2d", xmmDst.V, xmmDst.V, srcRegStr))

	case x86asm.PCMPEQB:
		lines = append(lines, fmt.Sprintf("    cmeq %s.16b, %s.16b, %s.16b", xmmDst.V, xmmDst.V, srcRegStr))
	case x86asm.PCMPEQW:
		lines = append(lines, fmt.Sprintf("    cmeq %s.8h, %s.8h, %s.8h", xmmDst.V, xmmDst.V, srcRegStr))
	case x86asm.PCMPEQD:
		lines = append(lines, fmt.Sprintf("    cmeq %s.4s, %s.4s, %s.4s", xmmDst.V, xmmDst.V, srcRegStr))

	case x86asm.PMAXUB:
		lines = append(lines, fmt.Sprintf("    umax %s.16b, %s.16b, %s.16b", xmmDst.V, xmmDst.V, srcRegStr))
	case x86asm.PMINUB:
		lines = append(lines, fmt.Sprintf("    umin %s.16b, %s.16b, %s.16b", xmmDst.V, xmmDst.V, srcRegStr))

	case x86asm.PMULLW:
		lines = append(lines, fmt.Sprintf("    mul %s.8h, %s.8h, %s.8h", xmmDst.V, xmmDst.V, srcRegStr))

	case x86asm.PUNPCKLBW:
		lines = append(lines, fmt.Sprintf("    zip1 %s.16b, %s.16b, %s.16b", xmmDst.V, xmmDst.V, srcRegStr))
	case x86asm.PUNPCKLWD:
		lines = append(lines, fmt.Sprintf("    zip1 %s.8h, %s.8h, %s.8h", xmmDst.V, xmmDst.V, srcRegStr))
	case x86asm.PUNPCKLDQ:
		lines = append(lines, fmt.Sprintf("    zip1 %s.4s, %s.4s, %s.4s", xmmDst.V, xmmDst.V, srcRegStr))
	case x86asm.PUNPCKLQDQ:
		lines = append(lines, fmt.Sprintf("    zip1 %s.2d, %s.2d, %s.2d", xmmDst.V, xmmDst.V, srcRegStr))

	case x86asm.PUNPCKHBW:
		lines = append(lines, fmt.Sprintf("    zip2 %s.16b, %s.16b, %s.16b", xmmDst.V, xmmDst.V, srcRegStr))
	case x86asm.PUNPCKHWD:
		lines = append(lines, fmt.Sprintf("    zip2 %s.8h, %s.8h, %s.8h", xmmDst.V, xmmDst.V, srcRegStr))
	case x86asm.PUNPCKHDQ:
		lines = append(lines, fmt.Sprintf("    zip2 %s.4s, %s.4s, %s.4s", xmmDst.V, xmmDst.V, srcRegStr))
	case x86asm.PUNPCKHQDQ:
		lines = append(lines, fmt.Sprintf("    zip2 %s.2d, %s.2d, %s.2d", xmmDst.V, xmmDst.V, srcRegStr))

	case x86asm.PANDN:
		lines = append(lines, fmt.Sprintf("    bic %s.16b, %s.16b, %s.16b", xmmDst.V, srcRegStr, xmmDst.V))
	case x86asm.PCMPGTD:
		lines = append(lines, fmt.Sprintf("    cmgt %s.4s, %s.4s, %s.4s", xmmDst.V, xmmDst.V, srcRegStr))
	case x86asm.PMULUDQ:
		lines = append(lines, fmt.Sprintf("    umull %s.2d, %s.2s, %s.2s", xmmDst.V, xmmDst.V, srcRegStr))
	default:
		lines = append(lines, l.emitUnsupported(inst, "unsupported simd binary op")...)
	}
	return lines, nil
}

// liftVectorByteShift handles PSRLDQ and PSLLDQ instructions.
func (l *Arm64Lifter) liftVectorByteShift(inst disasm.Instruction, isLeft bool, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	xmmDst, okXD := arm64XmmMap[dstReg]
	if !okDst || !okXD {
		lines = append(lines, l.emitUnsupported(inst, "unsupported byte shift dst")...)
		return lines, nil
	}
	imm, okImm := inst.Inst.Args[1].(x86asm.Imm)
	if !okImm {
		lines = append(lines, l.emitUnsupported(inst, "unsupported byte shift imm")...)
		return lines, nil
	}
	shift := int(imm)
	if shift >= 16 {
		lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", xmmDst.V))
		return lines, nil
	}
	if shift <= 0 {
		return lines, nil
	}
	lines = append(lines, "    movi v31.16b, #0")
	if isLeft {
		lines = append(lines, fmt.Sprintf("    ext %s.16b, v31.16b, %s.16b, #%d", xmmDst.V, xmmDst.V, 16-shift))
	} else {
		lines = append(lines, fmt.Sprintf("    ext %s.16b, %s.16b, v31.16b, #%d", xmmDst.V, xmmDst.V, shift))
	}
	return lines, nil
}

// liftVectorShift handles packed integer shifts (PSLLW, PSLLD, PSLLQ, PSRLW, PSRLD, PSRLQ, PSRAW, PSRAD).
func (l *Arm64Lifter) liftVectorShift(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	xmmDst, okXD := arm64XmmMap[dstReg]
	if !okDst || !okXD {
		lines = append(lines, l.emitUnsupported(inst, "unsupported simd shift dst")...)
		return lines, nil
	}

	src := inst.Inst.Args[1]
	imm, okImm := src.(x86asm.Imm)
	if okImm {
		shift := int64(imm)
		switch inst.Inst.Op {
		case x86asm.PSLLW:
			if shift >= 16 {
				lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", xmmDst.V))
			} else if shift > 0 {
				lines = append(lines, fmt.Sprintf("    shl %s.8h, %s.8h, #%d", xmmDst.V, xmmDst.V, shift))
			}
		case x86asm.PSLLD:
			if shift >= 32 {
				lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", xmmDst.V))
			} else if shift > 0 {
				lines = append(lines, fmt.Sprintf("    shl %s.4s, %s.4s, #%d", xmmDst.V, xmmDst.V, shift))
			}
		case x86asm.PSLLQ:
			if shift >= 64 {
				lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", xmmDst.V))
			} else if shift > 0 {
				lines = append(lines, fmt.Sprintf("    shl %s.2d, %s.2d, #%d", xmmDst.V, xmmDst.V, shift))
			}
		case x86asm.PSRLW:
			if shift >= 16 {
				lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", xmmDst.V))
			} else if shift > 0 {
				lines = append(lines, fmt.Sprintf("    ushr %s.8h, %s.8h, #%d", xmmDst.V, xmmDst.V, shift))
			}
		case x86asm.PSRLD:
			if shift >= 32 {
				lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", xmmDst.V))
			} else if shift > 0 {
				lines = append(lines, fmt.Sprintf("    ushr %s.4s, %s.4s, #%d", xmmDst.V, xmmDst.V, shift))
			}
		case x86asm.PSRLQ:
			if shift >= 64 {
				lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", xmmDst.V))
			} else if shift > 0 {
				lines = append(lines, fmt.Sprintf("    ushr %s.2d, %s.2d, #%d", xmmDst.V, xmmDst.V, shift))
			}
		case x86asm.PSRAW:
			if shift >= 16 {
				lines = append(lines, fmt.Sprintf("    sshr %s.8h, %s.8h, #16", xmmDst.V, xmmDst.V))
			} else if shift > 0 {
				lines = append(lines, fmt.Sprintf("    sshr %s.8h, %s.8h, #%d", xmmDst.V, xmmDst.V, shift))
			}
		case x86asm.PSRAD:
			if shift >= 32 {
				lines = append(lines, fmt.Sprintf("    sshr %s.4s, %s.4s, #32", xmmDst.V, xmmDst.V))
			} else if shift > 0 {
				lines = append(lines, fmt.Sprintf("    sshr %s.4s, %s.4s, #%d", xmmDst.V, xmmDst.V, shift))
			}
		default:
			lines = append(lines, l.emitUnsupported(inst, "unsupported simd shift op")...)
		}
		return lines, nil
	}

	lines = append(lines, l.emitUnsupported(inst, "unsupported non-imm simd shift")...)
	return lines, nil
}

// liftAvxMove handles VMOVUPS, VMOVUPD, VMOVAPS, VMOVAPD, VMOVDQU, VMOVDQA.
func (l *Arm64Lifter) liftAvxMove(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dst := inst.Inst.Args[0]
	src := inst.Inst.Args[1]

	// Reg <- Mem
	if dstReg, okDst := dst.(x86asm.Reg); okDst {
		if isYmm, dLowQ, dHighQ, dLowV, dHighV, _, _, okD := getVectorDesc(dstReg); okD {
			if mem, okMem := src.(x86asm.Mem); okMem {
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				lines = append(lines, fmt.Sprintf("    ldr %s, [x28, x16]", dLowQ))
				if isYmm {
					lines = append(lines, "    add x16, x16, #16")
					lines = append(lines, fmt.Sprintf("    ldr %s, [x28, x16]", dHighQ))
				} else {
					lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
				}
				return lines, nil
			}
			if srcReg, okSrc := src.(x86asm.Reg); okSrc {
				if _, _, _, sLowV, sHighV, _, _, okS := getVectorDesc(srcReg); okS {
					lines = append(lines, fmt.Sprintf("    mov %s.16b, %s.16b", dLowV, sLowV))
					if isYmm {
						lines = append(lines, fmt.Sprintf("    mov %s.16b, %s.16b", dHighV, sHighV))
					} else {
						lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
					}
					return lines, nil
				}
			}
		}
	}

	// Mem <- Reg
	if mem, okMem := dst.(x86asm.Mem); okMem {
		if srcReg, okSrc := src.(x86asm.Reg); okSrc {
			if isYmm, sLowQ, sHighQ, _, _, _, _, okS := getVectorDesc(srcReg); okS {
				lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
				lines = append(lines, fmt.Sprintf("    str %s, [x28, x16]", sLowQ))
				if isYmm {
					lines = append(lines, "    add x16, x16, #16")
					lines = append(lines, fmt.Sprintf("    str %s, [x28, x16]", sHighQ))
				}
				return lines, nil
			}
		}
	}

	lines = append(lines, l.emitUnsupported(inst, "unsupported avx move")...)
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

// liftVzeroupper zeroes the upper 128 bits of all YMM registers (v16-v31).
func (l *Arm64Lifter) liftVzeroupper(lines []string) []string {
	for i := 16; i <= 31; i++ {
		lines = append(lines, fmt.Sprintf("    movi v%d.16b, #0", i))
	}
	return lines
}

// liftVbroadcastss handles VBROADCASTSS.
func (l *Arm64Lifter) liftVbroadcastss(inst disasm.Instruction, nextPC uint64, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	isYmm, _, _, dLowV, dHighV, _, _, okD := getVectorDesc(dstReg)
	if !okDst || !okD {
		lines = append(lines, l.emitUnsupported(inst, "unsupported vbroadcastss dst")...)
		return lines, nil
	}

	src := inst.Inst.Args[1]
	if mem, okMem := src.(x86asm.Mem); okMem {
		lines = append(lines, computeEffAddr(mem, nextPC, "x16")...)
		lines = append(lines, "    add x16, x28, x16")
		lines = append(lines, fmt.Sprintf("    ld1r {%s.4s}, [x16]", dLowV))
		if isYmm {
			lines = append(lines, fmt.Sprintf("    mov %s.16b, %s.16b", dHighV, dLowV))
		} else {
			lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
		}
		return lines, nil
	}
	if srcReg, okSrc := src.(x86asm.Reg); okSrc {
		if _, _, _, sLowV, _, _, _, okS := getVectorDesc(srcReg); okS {
			lines = append(lines, fmt.Sprintf("    dup %s.4s, %s.s[0]", dLowV, sLowV))
			if isYmm {
				lines = append(lines, fmt.Sprintf("    mov %s.16b, %s.16b", dHighV, dLowV))
			} else {
				lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
			}
			return lines, nil
		}
	}

	lines = append(lines, l.emitUnsupported(inst, "unsupported vbroadcastss src")...)
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

// liftAvx3Op handles 3-operand packed operations (float, double, int, or logic).
func (l *Arm64Lifter) liftAvx3Op(inst disasm.Instruction, nextPC uint64, armOp string, isInt32 bool, lines []string) ([]string, error) {
	dstReg, okDst := inst.Inst.Args[0].(x86asm.Reg)
	src1Reg, okSrc1 := inst.Inst.Args[1].(x86asm.Reg)
	src2 := inst.Inst.Args[2]

	isYmm, _, _, dLowV, dHighV, _, _, okD := getVectorDesc(dstReg)
	_, _, _, s1LowV, s1HighV, _, _, okS1 := getVectorDesc(src1Reg)
	if !okDst || !okSrc1 || !okD || !okS1 {
		lines = append(lines, l.emitUnsupported(inst, "unsupported avx 3op dst/src1")...)
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
		lines = append(lines, l.emitUnsupported(inst, "unsupported avx 3op src2")...)
		return lines, nil
	}

	laneSuffix := ".4s"
	if armOp == "eor" || armOp == "and" || armOp == "orr" {
		laneSuffix = ".16b"
	}
	_ = isInt32

	lines = append(lines, fmt.Sprintf("    %s %s%s, %s%s, %s%s", armOp, dLowV, laneSuffix, s1LowV, laneSuffix, s2LowV, laneSuffix))
	if isYmm {
		lines = append(lines, fmt.Sprintf("    %s %s%s, %s%s, %s%s", armOp, dHighV, laneSuffix, s1HighV, laneSuffix, s2HighV, laneSuffix))
	} else {
		lines = append(lines, fmt.Sprintf("    movi %s.16b, #0", dHighV))
	}
	return lines, nil
}



