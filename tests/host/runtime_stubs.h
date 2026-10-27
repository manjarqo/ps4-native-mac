// Definitions of what recomp_runtime.c needs from the rest of the runtime when a host test
// links it on its own; none of it is used by these tests. Include once per test program.
#include <stdbool.h>
#include <stdint.h>
#include "recomp_runtime.h"

int g_ps4_videoout_flip_count;
void ps4_aio_destroy(void) {}
void ps4_ajm_destroy(void) {}
void ps4_equeue_destroy(void) {}
void ps4_event_flag_destroy(void) {}
void ps4_gnmdriver_destroy(void) {}
void ps4_keyboard_destroy(void) {}
void ps4_log_drain_sync(double t) { (void)t; }
void ps4_metal_screen_destroy(void) {}
#ifndef RUNTIME_STUBS_HAVE_SYNC // a test that links ps4_sync.c defines it
void ps4_sync_destroy(void) {}
#endif
#ifndef RUNTIME_STUBS_HAVE_VFS // a test that links ps4_vfs.c defines it
void ps4_vfs_destroy(void) {}
const char *ps4_vfs_get_app_root(void) { return NULL; }
#endif
void ps4_videoout_destroy(void) {}
#ifndef RUNTIME_STUBS_HAVE_THREADING // a test that links ps4_threading.c defines it
void recomp_init_main_thread(GuestContext *ctx) { (void)ctx; }
#endif
#ifndef RUNTIME_STUBS_HAVE_NEO_MODE // a test that sets the mode itself defines it
int32_t sceKernelIsNeoMode(void) { return 0; } // base mode (ps4_direct_mem.c sizes direct memory by it)
#endif
bool recomp_module_text_contains(uint64_t addr) { (void)addr; return false; }
uint64_t recomp_resolve_symbol(const char *m, const char *s) { (void)m; (void)s; return 0; }
__attribute__((used, section("__TEXT,__recomp_guest"))) static const char g_guest_text_marker[16];

