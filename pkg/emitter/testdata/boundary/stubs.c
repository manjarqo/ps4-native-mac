// Subsystems recomp_runtime.c references that the boundary tests do not use.
#include "recomp_runtime.h"
#include "ps4_log.h"
#include "ps4_sysmodule.h"
#include "ps4_vfs.h"
#include "ps4_syscalls.h"

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
int ps4_host_setting_pro_mode(void) { return 0; }
const RecompModuleUnwindInfo *recomp_module_find_by_addr(uint64_t addr) {
  (void)addr;
  return NULL;
}
const RecompModuleUnwindInfo *recomp_module_find_by_handle(int32_t handle) {
  (void)handle;
  return NULL;
}
void shim_clock_gettime(GuestContext *ctx) { SHIM_RETURN(); }
bool recomp_module_text_contains(uint64_t addr) { return addr >= 0x400000 && addr < 0x600000; }
// The module registry is not under test; the emitted recomp_register_guest_modules only feeds it.
void recomp_module_register(const char *filename, const RecompModuleExport *exports) {
  (void)filename;
  (void)exports;
}
void recomp_module_register_unwind_info(const RecompModuleUnwindInfo *info) { (void)info; }
