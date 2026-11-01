#include "ps4_discmap.h"
#include <stdint.h>

void shim_sceDiscMapIsRequestOnHDD(GuestContext *ctx) {
    ctx->rax = 0; // All files are on HDD
    SHIM_RETURN();
}

void shim_sceDiscMap_8A828CAEE7EDD5E9(GuestContext *ctx) {
    ctx->rax = 0; // All files are on HDD
    SHIM_RETURN();
}

void shim_Func_8A828CAEE7EDD5E9(GuestContext *ctx) {
    ctx->rax = 0; // All files are on HDD
    SHIM_RETURN();
}

void shim_Func_7C980FFB0AA27E7A(GuestContext *ctx) {
    uint64_t flags_guest = ctx->rcx;
    uint64_t ret1_guest = ctx->r8;
    uint64_t ret2_guest = ctx->r9;
    if (flags_guest && ctx->mem_base) {
        *(int32_t *)(ctx->mem_base + flags_guest) = 0;
    }
    if (ret1_guest && ctx->mem_base) {
        *(int32_t *)(ctx->mem_base + ret1_guest) = 0;
    }
    if (ret2_guest && ctx->mem_base) {
        *(int32_t *)(ctx->mem_base + ret2_guest) = 0;
    }
    ctx->rax = 0;
    SHIM_RETURN();
}

void shim_sceDiscMapGetPackageSize(GuestContext *ctx) {
    uint64_t ret1_guest = ctx->rsi;
    uint64_t ret2_guest = ctx->rdx;
    if (ret1_guest && ctx->mem_base) {
        *(int32_t *)(ctx->mem_base + ret1_guest) = 0;
    }
    if (ret2_guest && ctx->mem_base) {
        *(int32_t *)(ctx->mem_base + ret2_guest) = 0;
    }
    ctx->rax = 0;
    SHIM_RETURN();
}

void shim_Func_E7EBCE96E92F91F8(GuestContext *ctx) {
    ctx->rax = 0;
    SHIM_RETURN();
}
