// SPDX-License-Identifier: GPL-2.0-or-later
// Link-time definitions for the replay tool, which links the renderer (ps4_gnm_draw.mm and the
// files it needs) without the rest of the runtime. The renderer refers to these from its
// presentation and statistics paths (Present, the 300-frame perf line), and recomp_runtime.c from
// its teardown paths, none of which a replay runs; the draw / dispatch path uses none of them, so
// they abort if reached instead of returning a made-up result. The few silent ones say why
// their behaviour is the real one in a replay. Two are real: sceKernelIsNeoMode
// is the capture's neo mode, set by gnm_replay_lib.mm before the renderer starts (it selects Neo
// tiling layouts), and ps4_metal_screen_get_device has no window to offer (Init then falls back
// to MTLCreateSystemDefaultDevice).
// A new undefined symbol at link time must be one of the same kind (add it here, naming its
// caller); a symbol on the draw / dispatch path means the replay must link its real source.
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

#include <stdbool.h>

#include "recomp_runtime.h"

static void NotInReplay(const char *what) {
    fprintf(stderr, "gnm_replay: %s was called; it is not on the draw / dispatch path a replay runs\n", what);
    abort();
}

int32_t g_replay_neo = 0;
int32_t sceKernelIsNeoMode(void) { return g_replay_neo; }

// ps4_metal_screen.m: no window in a replay
void *ps4_metal_screen_get_device(void) { return NULL; }
void *ps4_metal_screen_acquire_frame(int width, int height) {
    (void)width; (void)height;
    NotInReplay("ps4_metal_screen_acquire_frame (Present)");
    return NULL;
}
int ps4_metal_screen_encode_present(void *command_buffer, void *texture) {
    (void)command_buffer; (void)texture;
    NotInReplay("ps4_metal_screen_encode_present (Present)");
    return 0;
}
int ps4_metal_screen_present_frame(const void *pixels, size_t pitch, int width, int height) {
    (void)pixels; (void)pitch; (void)width; (void)height;
    NotInReplay("ps4_metal_screen_present_frame (Present)");
    return 0;
}
// ps4_gnm_metal.mm (the command processor, not linked): CPU detiling of a display buffer for
// ps4_gnm_draw.mm PresentFromGuestMemory
int ps4_gnm_read_display_cpu(GuestContext *ctx, uint64_t addr, uint32_t width, uint32_t height, uint32_t pitch,
                             uint32_t tiling_mode, uint32_t pixel_format, uint8_t *out_bgra) {
    (void)ctx; (void)addr; (void)width; (void)height; (void)pitch; (void)tiling_mode; (void)pixel_format; (void)out_bgra;
    NotInReplay("ps4_gnm_read_display_cpu (PresentFromGuestMemory)");
    return 0;
}
// ps4_gnm_metal.mm (command processor statistics), ps4_fiber.c, ps4_sync.c: the perf line of Present
uint64_t ps4_gnm_take_cp_ns(void) { NotInReplay("ps4_gnm_take_cp_ns (Present perf line)"); return 0; }
void ps4_gnm_print_sync_stats(void) { NotInReplay("ps4_gnm_print_sync_stats (Present perf line)"); }
void ps4_fiber_print_stats(int frames) { (void)frames; NotInReplay("ps4_fiber_print_stats (Present perf line)"); }
void ps4_sync_print_stats(int frames) { (void)frames; NotInReplay("ps4_sync_print_stats (Present perf line)"); }
// ps4_direct_mem.c: recomp_runtime.c recomp_free_runtime (process teardown) and recomp_vm_free
// (guest munmap); the replay's guest memory is its own mapping, never freed through the runtime
void ps4_direct_mem_destroy(void) { NotInReplay("ps4_direct_mem_destroy (recomp_free_runtime)"); }
void ps4_direct_mem_on_unmap(GuestContext *ctx, uint64_t addr, size_t size) {
    (void)ctx; (void)addr; (void)size;
    NotInReplay("ps4_direct_mem_on_unmap (recomp_vm_free)");
}
// recomp_runtime.c, which the renderer links for GuestContext and the guest-memory helpers: its
// boot (recomp_init_main_thread, recomp_resolve_symbol, the app root), its crash report
// (recomp_module_text_contains) and its teardown (the *_destroy calls of recomp_free_runtime)
// are not run by a replay.
void ps4_aio_destroy(void) { NotInReplay("ps4_aio_destroy (recomp_free_runtime)"); }
void ps4_ajm_destroy(void) { NotInReplay("ps4_ajm_destroy (recomp_free_runtime)"); }
void ps4_equeue_destroy(void) { NotInReplay("ps4_equeue_destroy (recomp_free_runtime)"); }
void ps4_event_flag_destroy(void) { NotInReplay("ps4_event_flag_destroy (recomp_free_runtime)"); }
void ps4_gnmdriver_destroy(void) { NotInReplay("ps4_gnmdriver_destroy (recomp_free_runtime)"); }
void ps4_keyboard_destroy(void) { NotInReplay("ps4_keyboard_destroy (recomp_free_runtime)"); }
void ps4_metal_screen_destroy(void) { NotInReplay("ps4_metal_screen_destroy (recomp_free_runtime)"); }
void ps4_sync_destroy(void) { NotInReplay("ps4_sync_destroy (recomp_free_runtime)"); }
void ps4_vfs_destroy(void) { NotInReplay("ps4_vfs_destroy (recomp_free_runtime)"); }
void ps4_videoout_destroy(void) { NotInReplay("ps4_videoout_destroy (recomp_free_runtime)"); }
// recomp_runtime.c boot and ps4_gnm_shader_cache.mm (the shader cache, off in a replay)
const char *ps4_vfs_get_app_root(void) { NotInReplay("ps4_vfs_get_app_root (boot, shader cache)"); return NULL; }
void recomp_init_main_thread(GuestContext *ctx) { (void)ctx; NotInReplay("recomp_init_main_thread (boot)"); }
uint64_t recomp_resolve_symbol(const char *m, const char *s) {
    (void)m; (void)s;
    NotInReplay("recomp_resolve_symbol (boot)");
    return 0;
}
bool recomp_module_text_contains(uint64_t addr) {
    (void)addr;
    NotInReplay("recomp_module_text_contains (crash report)");
    return false;
}
// recomp_runtime.c crash report and FATAL paths: drains the asynchronous log of ps4_log.c, which
// a replay does not link (its stdout / stderr are the C library's own), so there is nothing to
// drain and returning at once is the real behaviour; aborting here would lose the FATAL report.
void ps4_log_drain_sync(double t) { (void)t; }
// recomp_runtime.c guest-memory watch log (PS4_WATCH, debugging): the flip count printed with
// each change; a replay presents no frames, so it stays 0.
volatile uint64_t g_ps4_videoout_flip_count;
// recomp_runtime.c reads the bounds of the __TEXT,__recomp_guest section (recompiled guest code,
// none in a replay); the linker defines them only when the section exists.
__attribute__((used, section("__TEXT,__recomp_guest"))) static const char g_guest_text_marker[16];
