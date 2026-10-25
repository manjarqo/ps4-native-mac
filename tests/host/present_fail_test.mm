// The present producer's failure rule (ps4_metal_screen.h, ps4_metal_screen_present_failed): a
// command buffer that failed may not have reached its present signal, so the CPU raises the event
// to the op's value; but only while that value is the newest one handed out, since a later
// command buffer's GPU signal must never be lowered again by this CPU write. No GPU fault is
// needed: two held frames are begun without encoding anything, and the failure handler is called
// on each, oldest first, then on the oldest again; then a present on the slot event (the
// presenter grants one slot at a time) is raised by its own event's newest value, not the held one's.
// Through the whole runtime (tests/host/build_runtime_test.sh): the Metal screen and its presenter.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <string>

#include "ps4_metal_screen.h"
#include "recomp_runtime.h"

extern "C" void recomp_enter_guest(void) {
    fprintf(stderr, "present_fail_test: recomp_enter_guest called\n");
    abort();
}

namespace {
int g_fail = 0;
#define CHECK(c, ...)                                                                \
    do {                                                                             \
        if (!(c)) {                                                                  \
            fprintf(stderr, "present_fail_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                            \
            fprintf(stderr, "\n");                                                   \
            g_fail++;                                                                \
        }                                                                            \
    } while (0)

void HeldDone(void*, int) {}

// a and b were begun in this order on the same event, nothing signals it: failing a (not the
// newest) changes nothing, failing b raises it to b, failing a again does not lower it
void CheckRule(const char* what, const ps4_metal_screen_present_op& a, const ps4_metal_screen_present_op& b) {
    id<MTLSharedEvent> ev = (__bridge id<MTLSharedEvent>)a.event;
    CHECK(ev && a.event == b.event && b.value == a.value + 1, "%s: ops not on one event in order (%llu, %llu)", what,
          (unsigned long long)a.value, (unsigned long long)b.value);
    if (!ev) return;
    const uint64_t base = ev.signaledValue;
    CHECK(base < a.value, "%s: the event is already at %llu", what, (unsigned long long)base);
    ps4_metal_screen_present_failed(&a);
    CHECK(ev.signaledValue == base, "%s: failing the older op raised the event to %llu (newest is %llu)", what,
          (unsigned long long)ev.signaledValue, (unsigned long long)b.value);
    ps4_metal_screen_present_failed(&b);
    CHECK(ev.signaledValue == b.value, "%s: failing the newest op left the event at %llu, want %llu", what,
          (unsigned long long)ev.signaledValue, (unsigned long long)b.value);
    ps4_metal_screen_present_failed(&a);
    CHECK(ev.signaledValue == b.value, "%s: failing the older op again moved the event to %llu", what,
          (unsigned long long)ev.signaledValue);
}
char g_tmp[] = "/tmp/present_fail_test.XXXXXX";
int g_err_fd = -1; // the process's stderr before the runtime routes fd 2 through its log thread

// a hung presenter call must not hang the suite: after 30 s report and leave (async-signal-safe)
void OnAlarm(int) {
    static const char msg[] = "present_fail_test: FAIL: timed out after 30 s\n";
    if (write(g_err_fd, msg, sizeof(msg) - 1) < 0) {}
    rmdir(g_tmp); // only if still empty; a non-empty scratch dir is left in /tmp
    _exit(1);
}

void RemoveTmp() {
    const std::string cmd = std::string("rm -rf '") + g_tmp + "'";
    if (system(cmd.c_str()) != 0) fprintf(stderr, "present_fail_test: could not remove %s\n", g_tmp);
}

// the runtime routes stdio through its log thread: ps4_host_quit drains it (the game's quit path,
// no static destructors while the presenter and Metal handlers still run)
[[noreturn]] void Finish() {
    RemoveTmp();
    if (g_fail)
        fprintf(stderr, "present_fail_test: %d failure(s)\n", g_fail);
    else
        printf("present_fail_test: PASS\n");
    ps4_host_quit(g_fail ? 1 : 0);
}

void* TestThread(void*) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        CHECK(dev, "no Metal device");
        if (!dev) Finish();
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:64
                                                                                     height:64
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> frame = [dev newTextureWithDescriptor:td];
        // the Metal screen; its window lives on the main thread's AppKit loop, as in the game
        if (ps4_metal_screen_init(64, 64, "present_fail_test") != 0) {
            CHECK(false, "no Metal screen");
            Finish();
        }
        // the presenter starts with the first present call
        ps4_metal_screen_present_op p1{};
        int r1 = 1;
        for (int i = 0; i < 200 && r1 == 1; ++i) { // a slot is free once the presenter is ready
            r1 = ps4_metal_screen_present_begin((__bridge void*)frame, &p1);
            if (r1 == 1) usleep(10000);
        }
        CHECK(r1 == 0 && p1.copy_dst, "a present did not get a slot (%d)", r1);
        // held frames (their own event): two outstanding at once, the newest-value rule on them
        void* h1 = ps4_metal_screen_hold_texture(64, 64);
        void* h2 = ps4_metal_screen_hold_texture(64, 64);
        CHECK(h1 && h2 && h1 != h2, "no two held textures");
        ps4_metal_screen_present_op q1{}, q2{}, q3{};
        const int s1 = h1 ? ps4_metal_screen_held_begin(h1, HeldDone, nullptr, &q1) : -1;
        const int s2 = h2 ? ps4_metal_screen_held_begin(h2, HeldDone, nullptr, &q2) : -1;
        CHECK(s1 == 0 && s2 == 0 && !q1.copy_dst && !q2.copy_dst, "two held frames were not queued (%d %d)", s1, s2);
        if (s1 == 0 && s2 == 0) CheckRule("held event", q1, q2);
        // a third held value, so the held event's newest value (3) differs from the slot event's (1)
        void* h3 = ps4_metal_screen_hold_texture(64, 64);
        const int s3 = h3 ? ps4_metal_screen_held_begin(h3, HeldDone, nullptr, &q3) : -1;
        CHECK(s3 == 0 && r1 == 0 && q3.value != p1.value, "held value %llu equals the slot value %llu (%d)",
              (unsigned long long)q3.value, (unsigned long long)p1.value, s3);
        // the slot event: p1 is its newest value, so a failure raises it to p1 (compared with the
        // slot event's own newest value, not the held one's)
        if (r1 == 0) {
            id<MTLSharedEvent> ev = (__bridge id<MTLSharedEvent>)p1.event;
            CHECK(p1.event != q1.event, "held frames signal the slot event");
            CHECK(ev.signaledValue < p1.value, "the slot event is already at %llu", (unsigned long long)ev.signaledValue);
            ps4_metal_screen_present_failed(&p1);
            CHECK(ev.signaledValue == p1.value, "failing the newest slot op left the event at %llu, want %llu",
                  (unsigned long long)ev.signaledValue, (unsigned long long)p1.value);
        }
    }
    // the presenter keeps the begun frames (nothing will signal their events)
    Finish();
}

} // namespace

int main() {
    if (!mkdtemp(g_tmp)) return 1;
    g_err_fd = dup(STDERR_FILENO);
    if (g_err_fd < 0) return 1;
    signal(SIGALRM, OnAlarm);
    alarm(30);
    setenv("PS4RECOMP_DATA_DIR", g_tmp, 1);
    setenv("PS4RECOMP_CACHE_DIR", g_tmp, 1);
    setenv("PS4_BACKGROUND_WINDOW", "1", 1);
    setenv("PS4_NO_DIALOGS", "1", 1);
    setenv("PS4_UPSCALE", "0", 1);
    pthread_t th;
    const int rc = pthread_create(&th, nullptr, TestThread, nullptr);
    if (rc != 0) {
        fprintf(stderr, "present_fail_test: FAIL: pthread_create: %s\n", strerror(rc));
        RemoveTmp();
        return 1;
    }
    ps4_host_run_main_loop();
}
