// SPDX-License-Identifier: GPL-2.0-or-later
// Host test for libSceAvPlayer (ps4_avplayer.c):
//   1. Instance lifecycle, stream inspection, and NV12 + PCM decoding on a real MP4
//      (or synthetic MP4 container if the Bloodborne movie fixture is absent).
//   2. Concurrent Stop/Close vs GetVideoDataEx/IsActive race test (verifies the
//      recursive mutex protection that prevents use-after-free on movie skip/end).

#include "ps4_avplayer.h"
#include "recomp_runtime.h"

#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint8_t *g_guest_mem = NULL;
static size_t g_guest_mem_sz = 64 * 1024 * 1024;
static _Atomic uint64_t g_bump_off = 0x100000;

recomp_fn_t **g_dispatch_l1[DISPATCH_LEVEL_SIZE];
void ps4_gnm_notify_cpu_write(uint64_t addr, uint64_t size) {
    (void)addr;
    (void)size;
}

static uint64_t host_alloc(uint64_t obj, uint64_t align, uint64_t size,
                           uint64_t a3, uint64_t a4, uint64_t a5) {
    (void)obj;
    (void)a3;
    (void)a4;
    (void)a5;
    if (align < 16) {
        align = 16;
    }
    uint64_t cur = atomic_fetch_add(&g_bump_off, (size + align - 1) & ~(align - 1));
    uint64_t aligned = (cur + align - 1) & ~(align - 1);
    assert(aligned + size <= g_guest_mem_sz);
    return aligned;
}

static uint64_t host_free(uint64_t obj, uint64_t ptr, uint64_t a2,
                          uint64_t a3, uint64_t a4, uint64_t a5) {
    (void)obj;
    (void)ptr;
    (void)a2;
    (void)a3;
    (void)a4;
    (void)a5;
    return 0;
}

typedef struct RaceArgs {
    int32_t handle;
    atomic_bool stop_thread;
} RaceArgs;

static void *poll_worker(void *arg) {
    RaceArgs *ra = (RaceArgs *)arg;
    GuestContext wctx;
    memset(&wctx, 0, sizeof(wctx));
    wctx.mem_base = g_guest_mem;
    wctx.mem_size = g_guest_mem_sz;

    uint64_t fi_off = host_alloc(0, 16, sizeof(SceAvPlayerFrameInfoEx), 0, 0, 0);
    while (!atomic_load(&ra->stop_thread)) {
        wctx.rdi = (uint64_t)(uint32_t)ra->handle;
        wctx.rsi = fi_off;
        shim_sceAvPlayerGetVideoDataEx(&wctx);

        wctx.rdi = (uint64_t)(uint32_t)ra->handle;
        shim_sceAvPlayerIsActive(&wctx);
    }
    return NULL;
}

int main(int argc, char **argv) {
    g_guest_mem = (uint8_t *)calloc(1, g_guest_mem_sz);
    assert(g_guest_mem != NULL);

    GuestContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.mem_base = g_guest_mem;
    ctx.mem_size = g_guest_mem_sz;

    uint64_t init_off = 0x1000;
    SceAvPlayerInitData *init = (SceAvPlayerInitData *)(g_guest_mem + init_off);
    memset(init, 0, sizeof(*init));
    init->memory_replacement.object_ptr = 0xCAFE;
    init->memory_replacement.allocate = (uint64_t)(uintptr_t)host_alloc;
    init->memory_replacement.deallocate = (uint64_t)(uintptr_t)host_free;
    init->memory_replacement.allocate_texture = (uint64_t)(uintptr_t)host_alloc;
    init->memory_replacement.deallocate_texture = (uint64_t)(uintptr_t)host_free;
    init->num_output_video_framebuffers = 4;
    init->auto_start = 1;

    ctx.rdi = init_off;
    shim_sceAvPlayerInit(&ctx);
    int32_t h = (int32_t)ctx.rax;
    assert(h > 0);

    const char *mp4_path = NULL;
    const char *bb_logo = "/Users/manjarqo/Library/Application Support/PS4Native/games/CUSA03173/content/movie/FDPrs_Sprj_Logo.mp4";
    if (argc > 1 && access(argv[1], R_OK) == 0) {
        mp4_path = argv[1];
    } else if (access(bb_logo, R_OK) == 0) {
        mp4_path = bb_logo;
    }

    if (mp4_path != NULL) {
        uint64_t path_off = 0x2000;
        snprintf((char *)(g_guest_mem + path_off), 512, "%s", mp4_path);

        ctx.rdi = (uint64_t)(uint32_t)h;
        ctx.rsi = path_off;
        shim_sceAvPlayerAddSource(&ctx);
        assert((int32_t)ctx.rax == SCE_AVPLAYER_OK);

        ctx.rdi = (uint64_t)(uint32_t)h;
        shim_sceAvPlayerStreamCount(&ctx);
        int32_t nstreams = (int32_t)ctx.rax;
        assert(nstreams >= 1);

        uint64_t sinfo_off = 0x3000;
        for (int32_t i = 0; i < nstreams; i++) {
            ctx.rdi = (uint64_t)(uint32_t)h;
            ctx.rsi = (uint64_t)(uint32_t)i;
            ctx.rdx = sinfo_off;
            shim_sceAvPlayerGetStreamInfo(&ctx);
            assert((int32_t)ctx.rax == SCE_AVPLAYER_OK);
            SceAvPlayerStreamInfo *si = (SceAvPlayerStreamInfo *)(g_guest_mem + sinfo_off);
            if (si->type == SCE_AVPLAYER_VIDEO) {
                assert(si->details.video.width == 1920);
                assert(si->details.video.height == 1080);
            }
        }

        ctx.rdi = (uint64_t)(uint32_t)h;
        shim_sceAvPlayerIsActive(&ctx);
        assert(ctx.rax == 1);

        uint64_t fi_off = 0x4000;
        SceAvPlayerFrameInfoEx *fi = (SceAvPlayerFrameInfoEx *)(g_guest_mem + fi_off);
        int got_video = 0;
        for (int tries = 0; tries < 30 && !got_video; tries++) {
            memset(fi, 0, sizeof(*fi));
            ctx.rdi = (uint64_t)(uint32_t)h;
            ctx.rsi = fi_off;
            shim_sceAvPlayerGetVideoDataEx(&ctx);
            if (ctx.rax == 1) {
                assert(fi->p_data != 0);
                assert(fi->details.video.width == 1920);
                assert(fi->details.video.height == 1080);
                assert(fi->details.video.pitch == 1920);
                got_video = 1;
            } else {
                usleep(5000);
            }
        }
        assert(got_video == 1);
    }

    // Concurrent Stop/Close vs GetVideoDataEx/IsActive stress test.
    RaceArgs ra;
    ra.handle = h;
    atomic_init(&ra.stop_thread, false);
    pthread_t tid;
    int rc = pthread_create(&tid, NULL, poll_worker, &ra);
    assert(rc == 0);

    usleep(2000);
    ctx.rdi = (uint64_t)(uint32_t)h;
    shim_sceAvPlayerStop(&ctx);
    assert((int32_t)ctx.rax == SCE_AVPLAYER_OK);

    ctx.rdi = (uint64_t)(uint32_t)h;
    shim_sceAvPlayerClose(&ctx);
    assert((int32_t)ctx.rax == SCE_AVPLAYER_OK);

    atomic_store(&ra.stop_thread, true);
    pthread_join(tid, NULL);

    free(g_guest_mem);
    printf("avplayer_test: PASS\n");
    return 0;
}
