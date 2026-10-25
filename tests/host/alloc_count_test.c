// The allocation counter of gnm_replay --allocs (tools/gnm_replay/alloc_count.c): with the
// interposer loaded, exactly the allocations made between begin and end are counted, on every
// thread (renderer work runs on worker threads too), through every interposed entry point; none
// made outside the window; without it, the program says so and exits 3, so a run that forgot
// DYLD_INSERT_LIBRARIES cannot report a count of 0.
#include <dlfcn.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

enum { kWorker = 7, kMain = 10 + 5 + 10, kWant = kWorker + kMain };

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static int g_go; // the window is open: the worker may allocate

// Started before the window, so creating it is not counted; its allocations inside the window are.
static void* worker(void* arg) {
    (void)arg;
    pthread_mutex_lock(&g_mu);
    while (!g_go) pthread_cond_wait(&g_cv, &g_mu);
    pthread_mutex_unlock(&g_mu);
    for (int i = 0; i < kWorker; i++) free(malloc(32));
    return NULL;
}

int main(void) {
    void (*begin)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "alloc_count_begin");
    uint64_t (*end)(void) = (uint64_t(*)(void))dlsym(RTLD_DEFAULT, "alloc_count_end");
    if (!begin || !end) {
        printf("alloc_count_test: alloc_count.dylib is not loaded\n");
        return 3;
    }
    pthread_t th;
    pthread_create(&th, NULL, worker, NULL);
    void* keep[kMain];
    int k = 0;
    malloc_zone_t* z = malloc_default_zone();
    void* batch[1];
    free(malloc(8)); // anything lazy in the allocator happens before the window
    begin();
    pthread_mutex_lock(&g_mu);
    g_go = 1;
    pthread_cond_broadcast(&g_cv);
    pthread_mutex_unlock(&g_mu);
    for (int i = 0; i < 10; i++) keep[k++] = malloc(16 + i);
    for (int i = 0; i < 5; i++) keep[k++] = calloc(4, 8);
    keep[k++] = realloc(NULL, 24);
    keep[k++] = valloc(100);
    {
        void* m = NULL;
        posix_memalign(&m, 64, 100);
        keep[k++] = m;
    }
    keep[k++] = aligned_alloc(64, 128);
    keep[k++] = malloc_zone_malloc(z, 40);
    keep[k++] = malloc_zone_calloc(z, 2, 20);
    keep[k++] = malloc_zone_realloc(z, NULL, 48);
    keep[k++] = malloc_zone_memalign(z, 64, 80);
    keep[k++] = malloc_zone_valloc(z, 90);
    if (malloc_zone_batch_malloc(z, 56, batch, 1) == 1) keep[k++] = batch[0];
    pthread_join(th, NULL);
    const uint64_t n = end();
    for (int i = 0; i < 100; i++) free(malloc(16)); // outside the window: not counted
    for (int i = 0; i < k; i++) free(keep[i]);
    const int ok = n == kWant && k == kMain;
    printf("alloc_count_test: %s (%llu allocations counted, want %d)\n", ok ? "PASS" : "FAIL", (unsigned long long)n,
           (int)kWant);
    return ok ? 0 : 1;
}
