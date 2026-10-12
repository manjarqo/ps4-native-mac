package lifter

import (
	"fmt"

	"golang.org/x/arch/x86/x86asm"
	"ps4-recomp/pkg/disasm"
)

// liftStringOp handles string instructions: MOVS*, STOS*, LODS*, SCAS*, CMPS*.
func (l *Arm64Lifter) liftStringOp(inst disasm.Instruction, width int, lines []string) ([]string, error) {
	op := inst.Inst.Op
	switch op {
	case x86asm.MOVSB, x86asm.MOVSW, x86asm.MOVSD, x86asm.MOVSQ:
		return l.liftMovs(inst, width, lines)
	case x86asm.STOSB, x86asm.STOSW, x86asm.STOSD, x86asm.STOSQ:
		return l.liftStos(inst, width, lines)
	case x86asm.LODSB, x86asm.LODSW, x86asm.LODSD, x86asm.LODSQ:
		return l.liftLods(inst, width, lines)
	case x86asm.SCASB, x86asm.SCASW, x86asm.SCASD, x86asm.SCASQ:
		return l.liftScas(inst, width, lines)
	case x86asm.CMPSB, x86asm.CMPSW, x86asm.CMPSD, x86asm.CMPSQ:
		return l.liftCmps(inst, width, lines)
	default:
		lines = append(lines, l.emitUnsupported(inst, "unsupported string op")...)
		return lines, nil
	}
}

func (l *Arm64Lifter) liftMovs(inst disasm.Instruction, width int, lines []string) ([]string, error) {
	loadInst := "ldr"
	storeInst := "str"
	reg := "x16"
	switch width {
	case 1:
		loadInst = "ldrb"
		storeInst = "strb"
		reg = "w16"
	case 2:
		loadInst = "ldrh"
		storeInst = "strh"
		reg = "w16"
	case 4:
		loadInst = "ldr"
		storeInst = "str"
		reg = "w16"
	case 8:
		loadInst = "ldr"
		storeInst = "str"
		reg = "x16"
	}

	if instHasRep(inst.Inst) {
		lblLoop := fmt.Sprintf("L_rep_movs_loop_%x", inst.Address)
		lblDone := fmt.Sprintf("L_rep_movs_done_%x", inst.Address)
		lines = append(lines,
			fmt.Sprintf("    cbz x21, %s", lblDone),
			fmt.Sprintf("%s:", lblLoop),
			fmt.Sprintf("    %s %s, [x28, x23]", loadInst, reg),
			fmt.Sprintf("    %s %s, [x28, x24]", storeInst, reg),
			fmt.Sprintf("    add x23, x23, #%d", width),
			fmt.Sprintf("    add x24, x24, #%d", width),
			"    subs x21, x21, #1",
			fmt.Sprintf("    b.ne %s", lblLoop),
			fmt.Sprintf("%s:", lblDone),
		)
		return lines, nil
	}

	lines = append(lines,
		fmt.Sprintf("    %s %s, [x28, x23]", loadInst, reg),
		fmt.Sprintf("    %s %s, [x28, x24]", storeInst, reg),
		fmt.Sprintf("    add x23, x23, #%d", width),
		fmt.Sprintf("    add x24, x24, #%d", width),
	)
	return lines, nil
}

func (l *Arm64Lifter) liftStos(inst disasm.Instruction, width int, lines []string) ([]string, error) {
	storeInst := "str"
	reg := "x19"
	switch width {
	case 1:
		storeInst = "strb"
		reg = "w19"
	case 2:
		storeInst = "strh"
		reg = "w19"
	case 4:
		storeInst = "str"
		reg = "w19"
	case 8:
		storeInst = "str"
		reg = "x19"
	}

	if instHasRep(inst.Inst) {
		lblLoop := fmt.Sprintf("L_rep_stos_loop_%x", inst.Address)
		lblDone := fmt.Sprintf("L_rep_stos_done_%x", inst.Address)
		lines = append(lines,
			fmt.Sprintf("    cbz x21, %s", lblDone),
			fmt.Sprintf("%s:", lblLoop),
			fmt.Sprintf("    %s %s, [x28, x24]", storeInst, reg),
			fmt.Sprintf("    add x24, x24, #%d", width),
			"    subs x21, x21, #1",
			fmt.Sprintf("    b.ne %s", lblLoop),
			fmt.Sprintf("%s:", lblDone),
		)
		return lines, nil
	}

	lines = append(lines,
		fmt.Sprintf("    %s %s, [x28, x24]", storeInst, reg),
		fmt.Sprintf("    add x24, x24, #%d", width),
	)
	return lines, nil
}

func (l *Arm64Lifter) liftLods(inst disasm.Instruction, width int, lines []string) ([]string, error) {
	if instHasRep(inst.Inst) {
		lblDone := fmt.Sprintf("L_rep_lods_done_%x", inst.Address)
		lines = append(lines,
			fmt.Sprintf("    cbz x21, %s", lblDone),
			"    sub x16, x21, #1",
			fmt.Sprintf("    mov x17, #%d", width),
			"    mul x16, x16, x17",
			"    add x23, x23, x16",
		)
	}

	switch width {
	case 1:
		lines = append(lines,
			"    ldrb w16, [x28, x23]",
			"    bfi x19, x16, #0, #8",
			"    add x23, x23, #1",
		)
	case 2:
		lines = append(lines,
			"    ldrh w16, [x28, x23]",
			"    bfi x19, x16, #0, #16",
			"    add x23, x23, #2",
		)
	case 4:
		lines = append(lines,
			"    ldr w19, [x28, x23]",
			"    add x23, x23, #4",
		)
	case 8:
		lines = append(lines,
			"    ldr x19, [x28, x23]",
			"    add x23, x23, #8",
		)
	}

	if instHasRep(inst.Inst) {
		lblDone := fmt.Sprintf("L_rep_lods_done_%x", inst.Address)
		lines = append(lines,
			"    mov x21, #0",
			fmt.Sprintf("%s:", lblDone),
		)
	}
	return lines, nil
}

func (l *Arm64Lifter) liftScas(inst disasm.Instruction, width int, lines []string) ([]string, error) {
	loadInst := "ldr"
	reg := "x16"
	axReg := "x19"
	cmpInst := "cmp"
	switch width {
	case 1:
		loadInst = "ldrb"
		reg = "w16"
		axReg = "w19"
	case 2:
		loadInst = "ldrh"
		reg = "w16"
		axReg = "w19"
	case 4:
		loadInst = "ldr"
		reg = "w16"
		axReg = "w19"
	case 8:
		loadInst = "ldr"
		reg = "x16"
		axReg = "x19"
	}

	stopOnMatch := instHasRepn(inst.Inst)
	counted := stopOnMatch || instHasRep(inst.Inst)
	if counted {
		lblLoop := fmt.Sprintf("L_rep_scas_loop_%x", inst.Address)
		lblDone := fmt.Sprintf("L_rep_scas_done_%x", inst.Address)
		stopBranch := "b.eq" // REPNE stops when equal
		if !stopOnMatch {
			stopBranch = "b.ne" // REPE stops when not equal
		}

		lines = append(lines,
			fmt.Sprintf("    cbz x21, %s", lblDone),
			fmt.Sprintf("%s:", lblLoop),
			fmt.Sprintf("    %s %s, [x28, x24]", loadInst, reg),
			fmt.Sprintf("    add x24, x24, #%d", width),
			"    subs x21, x21, #1",
			fmt.Sprintf("    %s %s, %s", cmpInst, reg, axReg),
			fmt.Sprintf("    %s %s", stopBranch, lblDone),
			fmt.Sprintf("    cbnz x21, %s", lblLoop),
			fmt.Sprintf("%s:", lblDone),
		)
		return lines, nil
	}

	lines = append(lines,
		fmt.Sprintf("    %s %s, [x28, x24]", loadInst, reg),
		fmt.Sprintf("    add x24, x24, #%d", width),
		fmt.Sprintf("    %s %s, %s", cmpInst, reg, axReg),
	)
	return lines, nil
}

func (l *Arm64Lifter) liftCmps(inst disasm.Instruction, width int, lines []string) ([]string, error) {
	loadInst := "ldr"
	r16 := "x16"
	r17 := "x17"
	cmpInst := "cmp"
	switch width {
	case 1:
		loadInst = "ldrb"
		r16 = "w16"
		r17 = "w17"
	case 2:
		loadInst = "ldrh"
		r16 = "w16"
		r17 = "w17"
	case 4:
		loadInst = "ldr"
		r16 = "w16"
		r17 = "w17"
	case 8:
		loadInst = "ldr"
		r16 = "x16"
		r17 = "x17"
	}

	stopOnMatch := instHasRepn(inst.Inst)
	counted := stopOnMatch || instHasRep(inst.Inst)
	if counted {
		lblLoop := fmt.Sprintf("L_rep_cmps_loop_%x", inst.Address)
		lblDone := fmt.Sprintf("L_rep_cmps_done_%x", inst.Address)
		stopBranch := "b.eq" // REPNE stops when equal
		if !stopOnMatch {
			stopBranch = "b.ne" // REPE stops when not equal
		}

		lines = append(lines,
			fmt.Sprintf("    cbz x21, %s", lblDone),
			fmt.Sprintf("%s:", lblLoop),
			fmt.Sprintf("    %s %s, [x28, x23]", loadInst, r16),
			fmt.Sprintf("    %s %s, [x28, x24]", loadInst, r17),
			fmt.Sprintf("    add x23, x23, #%d", width),
			fmt.Sprintf("    add x24, x24, #%d", width),
			"    subs x21, x21, #1",
			fmt.Sprintf("    %s %s, %s", cmpInst, r16, r17),
			fmt.Sprintf("    %s %s", stopBranch, lblDone),
			fmt.Sprintf("    cbnz x21, %s", lblLoop),
			fmt.Sprintf("%s:", lblDone),
		)
		return lines, nil
	}

	lines = append(lines,
		fmt.Sprintf("    %s %s, [x28, x23]", loadInst, r16),
		fmt.Sprintf("    %s %s, [x28, x24]", loadInst, r17),
		fmt.Sprintf("    add x23, x23, #%d", width),
		fmt.Sprintf("    add x24, x24, #%d", width),
		fmt.Sprintf("    %s %s, %s", cmpInst, r16, r17),
	)
	return lines, nil
}
