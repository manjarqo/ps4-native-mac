// Subsystems recomp_runtime.c references that the boundary tests do not use.
#include "recomp_runtime.h"
#include "ps4_log.h"
#include "ps4_sysmodule.h"
#include "ps4_vfs.h"

volatile uint64_t g_ps4_videoout_flip_count;

void ps4_aio_destroy(void) {}
void ps4_ajm_destroy(void) {}
void ps4_direct_mem_destroy(void) {}
void ps4_direct_mem_on_unmap(GuestContext *ctx, uint64_t addr, size_t size) {
  (void)ctx;
  (void)addr;
  (void)size;
}
void ps4_equeue_destroy(void) {}
void ps4_event_flag_destroy(void) {}
void ps4_gnmdriver_destroy(void) {}
void ps4_keyboard_destroy(void) {}
void ps4_log_drain_sync(double timeout_s) { (void)timeout_s; }
void ps4_metal_screen_destroy(void) {}
void ps4_sync_destroy(void) {}
void ps4_vfs_destroy(void) {}
const char *ps4_vfs_get_app_root(void) { return "."; }
void ps4_videoout_destroy(void) {}
uint64_t recomp_resolve_symbol(const char *module_name, const char *symbol) {
  (void)module_name;
  (void)symbol;
  return 0;
}
