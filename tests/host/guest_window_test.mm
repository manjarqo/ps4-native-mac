// Guest memory windows with the NULL page guard on: a no-copy MTLBuffer over window 0 must be
// created although guest [0, 0x10000) is PROT_NONE. A buffer that includes the guarded page
// must fail, which proves the guard is active and the test can fail.
#import <Metal/Metal.h>
#include <stdio.h>
#include <sys/mman.h>
#include "ps4_gnm_guest_window.h"

static int g_fail;

static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) g_fail = 1;
}

static id<MTLBuffer> window_buffer(id<MTLDevice> dev, uint8_t *mem, uint64_t mem_size, uint64_t addr,
                                   uint64_t size, uint64_t *offset) {
    uint64_t base, end, nwin;
    if (!ps4_gnm_guest_window_range(addr, size, mem_size, &base, &end, &nwin)) return nil;
    *offset = addr - base;
    return [dev newBufferWithBytesNoCopy:mem + base length:end - base options:MTLResourceStorageModeShared
                             deallocator:nil];
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("FAIL: no Metal device\n");
            return 1;
        }
        const uint64_t mem_size = 3 * PS4_GNM_WINDOW_SIZE;
        uint8_t *mem = (uint8_t *)mmap(NULL, mem_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (mem == MAP_FAILED) {
            printf("FAIL: mmap\n");
            return 1;
        }
        check(mprotect(mem, PS4_GNM_WINDOW0_BASE, PROT_NONE) == 0, "guard page mprotect");

        // Teeth: the old window 0 (base 0) contains the guarded page and cannot be wrapped.
        id<MTLBuffer> whole = [dev newBufferWithBytesNoCopy:mem length:PS4_GNM_WINDOW_SIZE
                                                    options:MTLResourceStorageModeShared deallocator:nil];
        check(whole == nil, "buffer over [0, 64 MiB) fails with the guard on");

        uint64_t off = 0;
        mem[0x20000] = 0x5a;
        id<MTLBuffer> w0 = window_buffer(dev, mem, mem_size, 0x20000, 0x1000, &off);
        check(w0 != nil, "window 0 buffer is created with the guard on");
        check(w0 && off == 0x10000 && ((uint8_t *)w0.contents)[off] == 0x5a, "window 0 offset maps the guest byte");

        id<MTLBuffer> cross = window_buffer(dev, mem, mem_size, PS4_GNM_WINDOW_SIZE - 0x100, 0x200, &off);
        check(cross != nil && cross.length == 2 * PS4_GNM_WINDOW_SIZE - PS4_GNM_WINDOW0_BASE,
              "range crossing windows 0 and 1");

        mem[PS4_GNM_WINDOW_SIZE + 0x40] = 0xa5;
        id<MTLBuffer> w1 = window_buffer(dev, mem, mem_size, PS4_GNM_WINDOW_SIZE + 0x40, 0x10, &off);
        check(w1 != nil && off == 0x40 && ((uint8_t *)w1.contents)[off] == 0xa5, "window 1 buffer");

        check(window_buffer(dev, mem, mem_size, 0x100, 0x10, &off) == nil, "NULL page area is rejected");
    }
    printf("guest_window_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail;
}
