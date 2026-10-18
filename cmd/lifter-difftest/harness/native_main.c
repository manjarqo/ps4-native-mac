// x86-64 side (run under Rosetta 2): executes the raw instructions.
#include "harness.h"
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>

extern const uint64_t nt_count;
extern void (*const nt_table[])(DtState *);
extern const uint64_t nt_regsets[][17];
static sigjmp_buf jb;
static volatile int sig_hit;
static void on_sig(int s) { sig_hit = s; siglongjmp(jb, 1); }

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
    sigaction(SIGFPE, &sa, NULL);
    for (unsigned t = 0; t < nt_count; t++) {
        for (unsigned k = 0; k < DT_TRIALS; k++) {
            DtResult res;
            memset(&res, 0, sizeof(res));
            memset(scr, 0, DT_SCRATCH_SIZE);
            dt_make_state(&res.st, scr, t, k, special, nt_regsets[t]);
            sig_hit = 0;
            if (sigsetjmp(jb, 1) == 0) {
                nt_table[t](&res.st);
            } else {
                res.status = sig_hit == SIGILL ? 1 : 2;
            }
            memcpy(res.mem, scr + (DT_MEM_TARGET - DT_SCRATCH_BASE) - 32, DT_MEM_WINDOW);
            fwrite(&res, sizeof(res), 1, out);
        }
    }
    fclose(out);
    return 0;
}
