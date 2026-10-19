// Guest functions for the guest-state boundary tests (boundary_test.go), written the way the
// assembly emitter lays recompiled code out: guest registers pinned (rax x19, rbx x20, rcx x21,
// rdx x22, rsi x23, rdi x24, rbp x25, rsp x26, r8-r15 x8-x15, FS x27, memory x28), one 16-byte
// host stack slot per active function for x30, x86 calls push a return address on the guest
// stack. The shim stubs (_stub_*) are generated with the emitter's writeShimStub.
// Addresses are the guest data layout of harness.c.
.section __TEXT,__recomp_guest,regular,pure_instructions
.p2align 2

.set D, 0x1000000
.set FIBER_A, D + 0x000
.set FIBER_B, D + 0x100
.set ARGRET1, D + 0x300
.set ARGRET2, D + 0x308
.set ARGRUN_A, D + 0x310
.set ARGRUN_A2, D + 0x318
.set ARGRUN_B, D + 0x320
.set ARGRUN_A3, D + 0x328
.set RES, D + 0x1000            // result block n at RES + n * 0x100 (harness.c: res())
.set RES_M1, RES + 0x000
.set RES_A1, RES + 0x100
.set RES_A2, RES + 0x200
.set RES_B1, RES + 0x300
.set RES_M2, RES + 0x400
.set RES_A_ARGS, RES + 0x500
.set RES_B_ARGS, RES + 0x600
.set RES_A_PRE, RES + 0x700
.set RES_B_PRE, RES + 0x800
.set RES_M1_PRE, RES + 0x900
.set RES_M2_PRE, RES + 0xa00
.set RES_EXC_PRE, RES + 0xb00
.set RES_EXC, RES + 0xc00
.set RES_EXC_HANDLER, RES + 0xd00
.set RES_GPRS_PRE, RES + 0xe00
.set RES_GPRS, RES + 0xf00

.macro LI reg, val
    movz \reg, #((\val) & 0xffff)
    movk \reg, #(((\val) >> 16) & 0xffff), lsl #16
.endm

.macro GUEST_FN name
.globl \name
.p2align 2
\name:
    str  x30, [sp, #-16]!
.endm

// x86 RET as the lifter emits it.
.macro GUEST_RET
    ldr  x16, [x28, x26]
    add  x26, x26, #8
    ldr  x30, [sp], #16
    ret
.endm

// x86 CALL of a shim: push a return address, branch to the shim stub.
.macro GUEST_CALL target
    sub  x26, x26, #8
    str  xzr, [x28, x26]
    bl   \target
.endm

// Distinct values in the GPRs a call must not change (System V callee-saved: rbx, rbp,
// r12-r15) and in r8-r11; harness.c check_pattern() knows the layout.
.macro SET_PATTERN p
    movz x20, #(\p + 0x01)
    movz x25, #(\p + 0x02)
    movz x8,  #(\p + 0x08)
    movz x9,  #(\p + 0x09)
    movz x10, #(\p + 0x0a)
    movz x11, #(\p + 0x0b)
    movz x12, #(\p + 0x0c)
    movz x13, #(\p + 0x0d)
    movz x14, #(\p + 0x0e)
    movz x15, #(\p + 0x0f)
.endm

// Result block: rax rbx rcx rdx rsi rdi rbp rsp r8-r15 fs mem (18 words).
.macro STORE_REGS addr
    LI   x16, \addr
    add  x16, x28, x16
    stp  x19, x20, [x16, #0]
    stp  x21, x22, [x16, #16]
    stp  x23, x24, [x16, #32]
    stp  x25, x26, [x16, #48]
    stp  x8,  x9,  [x16, #64]
    stp  x10, x11, [x16, #80]
    stp  x12, x13, [x16, #96]
    stp  x14, x15, [x16, #112]
    stp  x27, x28, [x16, #128]
.endm

// ---- Fibers: thread 1 runs A; A switches to B; B calls a shim and switches back to A; A
// returns to thread 1. Thread 2 runs A again (A resumes on another guest thread), A switches
// to B (B resumes on thread 2), B returns to thread 2.

GUEST_FN _guest_fiber_main1
    SET_PATTERN 0x1100
    STORE_REGS RES_M1_PRE
    LI   x24, FIBER_A
    LI   x23, 0x5150
    LI   x22, ARGRET1
    GUEST_CALL _stub_sceFiberRun
    STORE_REGS RES_M1
    GUEST_RET

GUEST_FN _guest_fiber_main2
    SET_PATTERN 0x2200
    STORE_REGS RES_M2_PRE
    LI   x24, FIBER_A
    LI   x23, 0x5250
    LI   x22, ARGRET2
    GUEST_CALL _stub_sceFiberRun
    STORE_REGS RES_M2
    GUEST_RET

GUEST_FN _guest_fiber_a
    STORE_REGS RES_A_ARGS
    SET_PATTERN 0xa000
    STORE_REGS RES_A_PRE
    LI   x24, FIBER_B
    LI   x23, 0x5151
    LI   x22, ARGRUN_A
    GUEST_CALL _stub_sceFiberSwitch
    STORE_REGS RES_A1
    LI   x24, 0x77
    LI   x23, ARGRUN_A2
    GUEST_CALL _stub_sceFiberReturnToThread
    STORE_REGS RES_A2
    LI   x24, FIBER_B
    LI   x23, 0x5252
    LI   x22, ARGRUN_A3
    GUEST_CALL _stub_sceFiberSwitch
    brk  #1

GUEST_FN _guest_fiber_b
    STORE_REGS RES_B_ARGS
    SET_PATTERN 0xb000
    STORE_REGS RES_B_PRE
    GUEST_CALL _stub_test_noop
    LI   x24, FIBER_A
    LI   x23, 0x5353
    LI   x22, ARGRUN_B
    GUEST_CALL _stub_sceFiberSwitch
    STORE_REGS RES_B1
    LI   x24, 0x88
    movz x23, #0
    GUEST_CALL _stub_sceFiberReturnToThread
    brk  #2

// ---- Guest exception handler (SIGUSR1) delivered while the thread is inside a shim.

GUEST_FN _guest_exc_main
    SET_PATTERN 0xe000
    STORE_REGS RES_EXC_PRE
    GUEST_CALL _stub_test_wait_signal
    STORE_REGS RES_EXC
    GUEST_RET

// void handler(int signum, void *ucontext)
GUEST_FN _guest_exc_handler
    STORE_REGS RES_EXC_HANDLER
    GUEST_RET

// ---- A shim that sets every GPR (as a longjmp-style shim does).

GUEST_FN _guest_gprs
    SET_PATTERN 0xc000
    movz x19, #0xc019
    movz x21, #0xc021
    movz x22, #0xc022
    movz x23, #0xc023
    movz x24, #0xc024
    STORE_REGS RES_GPRS_PRE
    GUEST_CALL _stub_test_set_gprs
    STORE_REGS RES_GPRS
    GUEST_RET
