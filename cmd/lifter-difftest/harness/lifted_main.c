// arm64 side: executes the lifter's C translation with mem_base = 0.
#include "harness.h"
#include "recomp_context.h"
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>

extern const uint64_t lt_count;
extern void (*const lt_table[])(GuestContext *);
extern const uint64_t lt_regsets[][17];
static sigjmp_buf jb;
static void on_sig(int s) { (void)s; siglongjmp(jb, 1); }

static uint64_t *gpr_ptr(GuestContext *c, int i) {
    uint64_t *base[16] = {&c->rax, &c->rcx, &c->rdx, &c->rbx, &c->rsp, &c->rbp, &c->rsi, &c->rdi,
                          &c->r8,  &c->r9,  &c->r10, &c->r11, &c->r12, &c->r13, &c->r14, &c->r15};
    return base[i];
}

int main(int argc, char **argv) {
    int special = argc > 2 && atoi(argv[2]);
    uint8_t *scr = mmap((void *)DT_SCRATCH_BASE, DT_SCRATCH_SIZE, PROT_READ | PROT_WRITE,
                        MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0);
    if (scr != (uint8_t *)DT_SCRATCH_BASE) { perror("mmap"); return 1; }
    FILE *out = fopen(argv[1], "wb");
    struct sigaction sa = {0};
    sa.sa_handler = on_sig;
    sa.sa_flags = SA_NODEFER;
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    static GuestContext ctx;
    for (unsigned t = 0; t < lt_count; t++) {
        for (unsigned k = 0; k < DT_TRIALS; k++) {
            DtResult res;
            memset(&res, 0, sizeof(res));
            memset(scr, 0, DT_SCRATCH_SIZE);
            dt_make_state(&res.st, scr, t, k, special, lt_regsets[t]);
            memset(&ctx, 0, sizeof(ctx));
            ctx.mem_base = (uint8_t *)0;
            ctx.mem_size = 1ULL << 46;
            for (int i = 0; i < 16; i++) *gpr_ptr(&ctx, i) = res.st.gpr[i];
            uint64_t f = res.st.flags;
            ctx.cf = f & 1; ctx.pf = (f >> 2) & 1; ctx.af = (f >> 4) & 1; ctx.zf = (f >> 6) & 1;
            ctx.sf = (f >> 7) & 1; ctx.df = (f >> 10) & 1; ctx.of = (f >> 11) & 1;
            ctx.mxcsr = res.st.mxcsr;
            for (int i = 0; i < 16; i++) {
                memcpy(&ctx.xmm[i], &res.st.ymm[i][0], 16);
                memcpy(&ctx.ymmh[i], &res.st.ymm[i][16], 16);
            }
            ctx.fpu_cw = 0x37f;
            if (sigsetjmp(jb, 1) == 0) {
                lt_table[t](&ctx);
                for (int i = 0; i < 16; i++) res.st.gpr[i] = *gpr_ptr(&ctx, i);
                res.st.flags = 0x202 | ctx.cf | (ctx.pf << 2) | (ctx.af << 4) | (ctx.zf << 6) | (ctx.sf << 7) |
                               ((uint64_t)ctx.df << 10) | ((uint64_t)ctx.of << 11);
                res.st.mxcsr = ctx.mxcsr;
                for (int i = 0; i < 16; i++) {
                    memcpy(&res.st.ymm[i][0], &ctx.xmm[i], 16);
                    memcpy(&res.st.ymm[i][16], &ctx.ymmh[i], 16);
                }
            } else {
                res.status = 2;
            }
            memcpy(res.mem, scr + (DT_MEM_TARGET - DT_SCRATCH_BASE) - 32, DT_MEM_WINDOW);
            fwrite(&res, sizeof(res), 1, out);
        }
    }
    fclose(out);
    return 0;
}
