// Shared state generation for the lifter differential test (native x86-64 and lifted arm64 asm).
#pragma once
#include <stdint.h>
#include <string.h>

#define DT_SCRATCH_BASE 0x800000000ULL
#define DT_SCRATCH_SIZE 0x100000ULL
#define DT_MEM_TARGET (DT_SCRATCH_BASE + 0x80000ULL)
#define DT_MEM_WINDOW 128 /* bytes compared, starting at DT_MEM_TARGET - 32 */
#define DT_TRIALS 8
#define DT_FAKE_TCB (DT_SCRATCH_BASE + 0xE0000ULL) /* x27 (FS) on the arm64 side; [FS+0x70] = GuestContext* */

typedef struct DtState {
    uint64_t gpr[16];
    uint64_t flags;
    uint32_t mxcsr;
    uint32_t pad; /* input CL (shift/rotate count), set by dt_make_state */
    uint8_t ymm[16][32];
} DtState;

typedef struct DtResult {
    uint32_t status; /* 0 ok, 1 SIGILL, 2 SIGSEGV/other */
    uint32_t pad;
    DtState st;
    uint8_t mem[DT_MEM_WINDOW];
} DtResult;

static inline uint64_t dt_rng(uint64_t *s) {
    uint64_t z = (*s += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

static inline uint32_t dt_lane(uint64_t *s, int special) {
    uint64_t r = dt_rng(s);
    unsigned mode = (unsigned)(r % 100);
    union { float f; uint32_t u; } v;
    if (special && mode < 10) {
        static const uint32_t sp[] = {0x7f800000u, 0xff800000u, 0x7fc00000u, 0x00000001u, 0x80000000u, 0x7f7fffffu,
                                      0x4f000000u, 0xcf000000u, 0x5f000000u, 0x3f000000u};
        return sp[(r >> 8) % 10];
    }
    if (mode < 65) {
        double m = (double)((r >> 11) & 0xFFFFF) / (double)0x100000; /* [0,1) */
        int e = (int)((r >> 32) % 24) - 12;
        v.f = (float)((m * 2.0 - 1.0) * (double)(1 << 10) * __builtin_ldexp(1.0, e));
        return v.u;
    }
    if (mode < 80) return (uint32_t)(r >> 16);
    if (mode < 92) return (uint32_t)((int32_t)((r >> 20) % 200) - 100);
    static const uint32_t simple[] = {0, 0x80000000u, 0x3f800000u, 0xbf800000u, 0x40000000u, 0x3f000000u, 1, 0xffffffffu};
    return simple[(r >> 8) % 8];
}

static inline void dt_make_state(DtState *st, uint8_t *scratch, unsigned test, unsigned trial, int special,
                                 const uint64_t regset[17]) {
    uint64_t s = 0x1234567ULL * (test + 1) + 0x9876543ULL * (trial + 1);
    memset(st, 0, sizeof(*st));
    for (int i = 0; i < 16; i++) st->gpr[i] = dt_rng(&s);
    st->gpr[4] = DT_SCRATCH_BASE + 0xF0000; /* rsp (unused) */
    if (trial & 1) for (int i = 0; i < 16; i++) st->gpr[i] &= 0xFFFFFFFFULL;   /* mix in small values */
    if (trial & 2) for (int i = 0; i < 16; i++) st->gpr[i] &= 0xFFULL;
    st->gpr[4] = DT_SCRATCH_BASE + 0xF0000;
    for (int i = 0; i < 16; i++)
        if (regset[0] >> i & 1) st->gpr[i] = regset[1 + i];
    st->pad = (uint32_t)(st->gpr[1] & 0xff);
    uint64_t r = dt_rng(&s);
    st->flags = 0x202 | (r & 0x8D5); /* CF PF AF ZF SF OF */
    st->mxcsr = 0x1F80;
    for (int i = 0; i < 16; i++)
        for (int k = 0; k < 8; k++) {
            uint32_t u = dt_lane(&s, special);
            memcpy(&st->ymm[i][k * 4], &u, 4);
        }
    for (uint64_t off = 0; off < 0x400; off += 4) {
        uint32_t u = dt_lane(&s, special);
        memcpy(scratch + (DT_MEM_TARGET - DT_SCRATCH_BASE) - 0x200 + off, &u, 4);
    }
}
