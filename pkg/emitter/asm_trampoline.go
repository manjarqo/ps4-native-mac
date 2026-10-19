package emitter

// trampolineAsm is the ARM64 bridge between the host C runtime and recompiled guest code
// (trampoline_arm64.s). The guest-state contract is documented at _recomp_enter_guest.
const trampolineAsm = `// ARM64 assembly bridge between the host C runtime and recompiled guest code.
.text
.p2align 2

// Stores the 16 guest GPRs to the GuestContext at \c (rax, rcx, rdx, rbx, rsp, rbp, rsi,
// rdi, r8-r15 at offsets 0x00-0x78).
.macro SAVE_GPRS c
    stp  x19, x21, [\c, #0x00]   // rax, rcx
    stp  x22, x20, [\c, #0x10]   // rdx, rbx
    stp  x26, x25, [\c, #0x20]   // rsp, rbp
    stp  x23, x24, [\c, #0x30]   // rsi, rdi
    stp  x8,  x9,  [\c, #0x40]
    stp  x10, x11, [\c, #0x50]
    stp  x12, x13, [\c, #0x60]
    stp  x14, x15, [\c, #0x70]
.endm

// Loads the 16 guest GPRs from the GuestContext at \c.
.macro LOAD_GPRS c
    ldp  x19, x21, [\c, #0x00]
    ldp  x22, x20, [\c, #0x10]
    ldp  x26, x25, [\c, #0x20]
    ldp  x23, x24, [\c, #0x30]
    ldp  x8,  x9,  [\c, #0x40]
    ldp  x10, x11, [\c, #0x50]
    ldp  x12, x13, [\c, #0x60]
    ldp  x14, x15, [\c, #0x70]
.endm

// ---- Guest-state contract ------------------------------------------------------------
//
// While recompiled guest code runs, the x86 state is pinned in host registers:
//   rax x19, rbx x20, rcx x21, rdx x22, rsi x23, rdi x24, rbp x25, rsp x26, r8-r15 x8-x15,
//   FS base x27, guest memory base x28; xmm0-15 (low 128 bits) v0-v15, the upper halves
//   of ymm0-15 v16-v31; the flags in NZCV.
// x0-x7, x16 and x17 are scratch, x18 is never touched, x29 is not maintained (guest code
// builds no frame records). Each active guest function keeps its host return address (x30)
// in a 16-byte slot on the host stack.
// Code that runs in this state (recompiled functions, shim stubs, the indirect-branch entry
// points below) is in the __TEXT,__recomp_guest section: a host PC there means the pinned
// registers are the guest registers; anywhere else the GuestContext holds what the last
// guest -> host transition stored (recomp_pc_in_guest_code; signal handlers rely on it).
// The rest of the guest state (x87 stack, MMX, MXCSR) lives in the GuestContext of the
// execution context that runs, found through the TCB slot [x28 + x27 + 0x70]. The runtime
// keeps that slot pointing at the context that runs on the guest thread: the thread's own
// GuestContext, or the fiber's while a fiber runs (ps4_fiber.c).
//
// Host -> guest, recomp_enter_guest(ctx, fn): saves the host callee-saved x19-x30, loads the
// 16 GPRs, FS base and memory base from ctx, calls fn, and on return stores the 16 GPRs back
// to ctx.
//
// Guest -> host, _recomp_call_shim (x0 = shim; the shim stub branches here in place of a
// guest function): ctx = the TCB slot. Stores the 16 GPRs to ctx, calls shim(ctx), then
// reloads from that same ctx (kept in the bridge frame, not looked up again):
// rax, rdx, rsp, r8-r15, FS base and memory base. A shim returns values through ctx.
//
// A shim that switches context (sceFiberRun/Switch/ReturnToThread) switches host stacks
// inside the shim. The bridge frame of a call lives on the host stack of the context that
// made the call, so when that context is resumed, its own frame finishes the call: it
// reloads the guest registers that context stored, and the FS base from ctx->fs_base, which
// the fiber runtime updates when a fiber resumes on another guest thread. The runtime must
// point the TCB slot of a guest thread at the GuestContext of the endpoint it switches to,
// before the switch.
// --------------------------------------------------------------------------------------

// void recomp_enter_guest(GuestContext *ctx, uint64_t target_fn)
// x0 = ctx, x1 = target_fn
.globl _recomp_enter_guest
_recomp_enter_guest:
    stp  x29, x30, [sp, #-112]!
    mov  x29, sp
    stp  x19, x20, [sp, #16]
    stp  x21, x22, [sp, #32]
    stp  x23, x24, [sp, #48]
    stp  x25, x26, [sp, #64]
    stp  x27, x28, [sp, #80]
    str  x0,       [sp, #96]

    LOAD_GPRS x0
    ldr  x27, [x0, #0x88]        // fs_base
    ldr  x28, [x0, #0x330]       // mem_base

    blr  x1

    ldr  x0, [sp, #96]
    SAVE_GPRS x0

    ldp  x19, x20, [sp, #16]
    ldp  x21, x22, [sp, #32]
    ldp  x23, x24, [sp, #48]
    ldp  x25, x26, [sp, #64]
    ldp  x27, x28, [sp, #80]
    ldp  x29, x30, [sp], #112
    ret

// _recomp_call_shim: calls a host C shim from guest code (see the contract above).
// x0 = shim. Frame: [sp] x29, x30; [sp+16] shim, ctx; [sp+32] q0-q7.
.globl _recomp_call_shim
_recomp_call_shim:
    stp  x29, x30, [sp, #-160]!
    mov  x29, sp
    add  x1, x27, #0x70
    ldr  x1, [x28, x1]           // ctx: the TCB slot
    stp  x0, x1, [sp, #16]
    stp  q0, q1, [sp, #32]
    stp  q2, q3, [sp, #64]
    stp  q4, q5, [sp, #96]
    stp  q6, q7, [sp, #128]
    SAVE_GPRS x1

    mov  x0, x1
    ldr  x2, [sp, #16]
    blr  x2

    // The ctx this call stored into. A context switch inside the shim may have changed the
    // TCB slot, and x27 may name another guest thread's TCB by now.
    ldr  x1, [sp, #24]
    ldr  x19, [x1, #0x00]        // rax
    ldr  x22, [x1, #0x10]        // rdx
    ldr  x26, [x1, #0x20]        // rsp
    ldp  x8,  x9,  [x1, #0x40]
    ldp  x10, x11, [x1, #0x50]
    ldp  x12, x13, [x1, #0x60]
    ldp  x14, x15, [x1, #0x70]
    ldr  x27, [x1, #0x88]        // fs_base
    ldr  x28, [x1, #0x330]       // mem_base

    ldp  q0, q1, [sp, #32]
    ldp  q2, q3, [sp, #64]
    ldp  q4, q5, [sp, #96]
    ldp  q6, q7, [sp, #128]
    ldp  x29, x30, [sp], #160
    ret

// Slow path of _recomp_indirect_call/_recomp_indirect_jump: the target is not in the
// dispatch table; recomp_dispatch_external reports it. x0 = guest target RIP.
.macro DISPATCH_EXTERNAL
    stp  x29, x30, [sp, #-32]!
    mov  x29, sp
    add  x2, x27, #0x70
    ldr  x2, [x28, x2]
    stp  x0, x2, [sp, #16]
    cbz  x2, 98f
    SAVE_GPRS x2
98:
    ldr  x1, [sp, #16]
    mov  x0, x2
    bl   _recomp_dispatch_external
    ldr  x0, [sp, #24]
    cbz  x0, 97f
    LOAD_GPRS x0
    ldr  x27, [x0, #0x88]        // fs_base
    ldr  x28, [x0, #0x330]       // mem_base
97:
    ldp  x29, x30, [sp], #32
    ret
.endm

// Three-level dispatch table lookup of the guest RIP in x0; branches to the recompiled
// function, or falls through to 99 when the target is unknown.
.macro DISPATCH_LOOKUP
    adrp x16, _g_dispatch_l1@PAGE
    add  x16, x16, _g_dispatch_l1@PAGEOFF
    lsr  x17, x0, #32
    and  x17, x17, #0xffff
    ldr  x16, [x16, x17, lsl #3]
    cbz  x16, 99f
    lsr  x17, x0, #16
    and  x17, x17, #0xffff
    ldr  x16, [x16, x17, lsl #3]
    cbz  x16, 99f
    and  x17, x0, #0xffff
    ldr  x16, [x16, x17, lsl #3]
    cbz  x16, 99f
    br   x16
.endm

// The indirect-branch entry points run with the guest registers live: guest code section.
.section __TEXT,__recomp_guest,regular,pure_instructions
.p2align 2

// _recomp_indirect_call: calls a guest function via dispatch. x0 = guest target RIP.
.globl _recomp_indirect_call
_recomp_indirect_call:
    DISPATCH_LOOKUP
99:
    DISPATCH_EXTERNAL

// _recomp_indirect_jump: jumps to a guest function via dispatch. x0 = guest target RIP.
.globl _recomp_indirect_jump
_recomp_indirect_jump:
    DISPATCH_LOOKUP
99:
    DISPATCH_EXTERNAL
`
