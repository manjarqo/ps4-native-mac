// SPDX-License-Identifier: GPL-2.0-or-later
// Allocation counter for gnm_replay --allocs (docs/metal4-backend.md, "Allocations per pass").
// Loaded with DYLD_INSERT_LIBRARIES, it interposes the malloc family (dyld __interpose: every
// other image's calls come here, this image's own calls go to the real functions) and counts the
// calls made by any thread of the process between alloc_count_begin() and alloc_count_end():
// the renderer does part of its work on worker threads and completion handlers, and a per-draw
// allocation budget has to include them. The state is two atomics, so it needs no allocation and
// no initialization order. Counted: malloc, calloc, realloc, valloc, posix_memalign,
// aligned_alloc and the malloc_zone_ malloc, calloc, realloc, memalign, valloc and batch_malloc
// (one call each). Not counted: vm_allocate / mmap, and allocator entry points the SDK might
// route around these names (malloc_type_*; the SDK of this repo's toolchain still reaches the
// interposed names, which alloc_count_test checks).
#include <malloc/malloc.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>

static _Atomic uint64_t g_count;
static _Atomic int g_armed;

static inline void note(void) {
    if (atomic_load_explicit(&g_armed, memory_order_relaxed)) atomic_fetch_add_explicit(&g_count, 1, memory_order_relaxed);
}

void alloc_count_begin(void) {
    atomic_store(&g_count, 0);
    atomic_store(&g_armed, 1);
}

uint64_t alloc_count_end(void) {
    atomic_store(&g_armed, 0);
    return atomic_load(&g_count);
}

static void* c_malloc(size_t n) { note(); return malloc(n); }
static void* c_calloc(size_t c, size_t n) { note(); return calloc(c, n); }
static void* c_realloc(void* p, size_t n) { note(); return realloc(p, n); }
static void* c_valloc(size_t n) { note(); return valloc(n); }
static int c_posix_memalign(void** p, size_t a, size_t n) { note(); return posix_memalign(p, a, n); }
static void* c_aligned_alloc(size_t a, size_t n) { note(); return aligned_alloc(a, n); }
static void* c_zone_malloc(malloc_zone_t* z, size_t n) { note(); return malloc_zone_malloc(z, n); }
static void* c_zone_calloc(malloc_zone_t* z, size_t c, size_t n) { note(); return malloc_zone_calloc(z, c, n); }
static void* c_zone_realloc(malloc_zone_t* z, void* p, size_t n) { note(); return malloc_zone_realloc(z, p, n); }
static void* c_zone_memalign(malloc_zone_t* z, size_t a, size_t n) { note(); return malloc_zone_memalign(z, a, n); }
static void* c_zone_valloc(malloc_zone_t* z, size_t n) { note(); return malloc_zone_valloc(z, n); }
static unsigned c_zone_batch_malloc(malloc_zone_t* z, size_t n, void** r, unsigned c) {
    note();
    return malloc_zone_batch_malloc(z, n, r, c);
}

#define INTERPOSE(rep, orig)                                                                        \
    __attribute__((used)) static const struct { const void* r; const void* o; } interpose_##orig \
        __attribute__((section("__DATA,__interpose"))) = {(const void*)(rep), (const void*)(orig)}

INTERPOSE(c_malloc, malloc);
INTERPOSE(c_calloc, calloc);
INTERPOSE(c_realloc, realloc);
INTERPOSE(c_valloc, valloc);
INTERPOSE(c_posix_memalign, posix_memalign);
INTERPOSE(c_aligned_alloc, aligned_alloc);
INTERPOSE(c_zone_malloc, malloc_zone_malloc);
INTERPOSE(c_zone_calloc, malloc_zone_calloc);
INTERPOSE(c_zone_realloc, malloc_zone_realloc);
INTERPOSE(c_zone_memalign, malloc_zone_memalign);
INTERPOSE(c_zone_valloc, malloc_zone_valloc);
INTERPOSE(c_zone_batch_malloc, malloc_zone_batch_malloc);
