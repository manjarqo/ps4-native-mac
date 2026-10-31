// A guard-size attribute must round-trip and protect the low end of a new stack.
#define RUNTIME_STUBS_HAVE_THREADING
#include "runtime_stubs.h"
#include "ps4_threading.h"
#include <assert.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/mman.h>
#include <stdio.h>
#include <stdlib.h>

extern void shim_scePthreadAttrSetguardsize(GuestContext *);
extern void shim_scePthreadAttrGetguardsize(GuestContext *);
extern GuestContext *recomp_create_thread_context_guarded(GuestContext *, uint64_t, uint64_t);
void ps4_direct_mem_destroy(void) {}
void ps4_direct_mem_configure(GuestContext *c, uint64_t a) { (void)c; (void)a; }
void ps4_direct_mem_on_unmap(GuestContext *c, uint64_t a, size_t n) { (void)c; (void)a; (void)n; }

static vm_prot_t protection(void *p) {
    mach_vm_address_t a = (mach_vm_address_t)p;
    mach_vm_size_t n;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object;
    assert(mach_vm_region(mach_task_self(), &a, &n, VM_REGION_BASIC_INFO_64,
                         (vm_region_info_t)&info, &count, &object) == KERN_SUCCESS);
    if (object) mach_port_deallocate(mach_task_self(), object);
    return info.protection;
}

int main(void) {
    GuestContext p = {0};
    p.mem_size = 8ULL << 30;
    p.mem_base = mmap(NULL, p.mem_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    assert(p.mem_base != MAP_FAILED);
    p.process_ctx = &p;
    pthread_mutex_init(&p.vm_mutex, NULL);
    p.vm_extents = calloc(1, sizeof(GuestVMExtent));
    p.vm_extents->addr = 0x10000000;
    p.vm_extents->size = 0x10000000;
    p.vm_extents->is_free = true;
    p.rdi = 0x1000;
    p.rsp = 0x2000;
    shim_scePthreadAttrInit(&p);
    assert(p.rax == 0);
    p.rsi = 16;
    shim_scePthreadAttrSetguardsize(&p);
    assert(p.rax == 0);
    p.rsi = 0x3000;
    shim_scePthreadAttrGetguardsize(&p);
    assert(p.rax == 0 && *(uint64_t *)(p.mem_base + 0x3000) == 16);
    p.rdi = 0;
    shim_scePthreadAttrSetguardsize(&p);
    assert(p.rax == 0x80020016);
    p.rdi = 0x1000;
    p.rsi = 0;
    shim_scePthreadAttrGetguardsize(&p);
    assert(p.rax == 0x80020016);
    shim_scePthreadAttrDestroy(&p);

    GuestContext *c = recomp_create_thread_context_guarded(&p, 0x10000, 16);
    assert(c && c->stack_alloc_size >= 0x24000);
    assert(protection(p.mem_base + c->stack_base) == VM_PROT_NONE);
    assert(protection(p.mem_base + c->rsp) & VM_PROT_WRITE);
    assert(c->rsp >= c->stack_base + 0x4000);
    uint64_t base = c->stack_base;
    recomp_free_thread_context(c);
    c = recomp_create_thread_context(&p, 0x10000);
    assert(c && c->stack_base == base);
    assert(protection(p.mem_base + c->stack_base) & VM_PROT_WRITE);
    recomp_free_thread_context(c);
    assert(!recomp_create_thread_context_guarded(&p, 0x10000, UINT64_MAX));
    puts("pthread_guard_test: PASS");
    return 0;
}
