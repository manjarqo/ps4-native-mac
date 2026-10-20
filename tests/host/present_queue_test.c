// Host test for the presenter's frame queue and pacing policy (libSceVideoOut/ps4_present_queue.c).
#include "ps4_present_queue.h"

#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int g_fail;
#define CHECK(c)                                                                                                       \
    do {                                                                                                               \
        if (!(c)) {                                                                                                    \
            fprintf(stderr, "present_queue_test: %s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #c);                \
            g_fail = 1;                                                                                                \
        }                                                                                                              \
    } while (0)
#define NEAR(a, b, eps) CHECK(fabs((double)(a) - (double)(b)) <= (eps))

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

static void mode_test(void) {
    ps4_present_mode m;
    CHECK(ps4_present_parse_mode(NULL, &m) && m == PS4_PRESENT_UNCAPPED);
    CHECK(ps4_present_parse_mode("", &m) && m == PS4_PRESENT_UNCAPPED);
    CHECK(ps4_present_parse_mode("VSync", &m) && m == PS4_PRESENT_VSYNC);
    CHECK(ps4_present_parse_mode("mailbox", &m) && m == PS4_PRESENT_MAILBOX);
    CHECK(!ps4_present_parse_mode("fast", &m) && m == PS4_PRESENT_UNCAPPED);
    CHECK(!strcmp(ps4_present_mode_name(PS4_PRESENT_VSYNC), "vsync"));
}

static void min_duration_test(void) {
    const ps4_present_mode V = PS4_PRESENT_VSYNC;
    // uncapped and mailbox never hold a frame
    CHECK(ps4_present_min_duration(PS4_PRESENT_UNCAPPED, 1, PS4_FLIP_MODE_VSYNC, 120) == 0);
    CHECK(ps4_present_min_duration(PS4_PRESENT_MAILBOX, 1, PS4_FLIP_MODE_VSYNC, 120) == 0);
    // 60 Hz guest on a 120 Hz display: hold for two refreshes, minus half a refresh
    NEAR(ps4_present_min_duration(V, 0, PS4_FLIP_MODE_VSYNC, 120), 1 / 60.0 - 1 / 240.0, 1e-9);
    // 60 Hz guest on a 60 Hz display: vsync alone is the guest rate
    CHECK(ps4_present_min_duration(V, 0, PS4_FLIP_MODE_VSYNC, 60) == 0);
    CHECK(ps4_present_min_duration(V, 0, PS4_FLIP_MODE_VSYNC, 59.94) == 0);
    // display slower than the guest (48 Hz): nothing to hold
    CHECK(ps4_present_min_duration(V, 0, PS4_FLIP_MODE_VSYNC, 48) == 0);
    // 30 and 20 Hz flip rates
    NEAR(ps4_present_min_duration(V, 1, PS4_FLIP_MODE_VSYNC, 60), 1 / 30.0 - 1 / 120.0, 1e-9);
    NEAR(ps4_present_min_duration(V, 2, PS4_FLIP_MODE_VSYNC, 144), 1 / 20.0 - 1 / 288.0, 1e-9);
    // unknown refresh is taken as 60 Hz; an invalid flip rate as 60 Hz
    NEAR(ps4_present_min_duration(V, 1, PS4_FLIP_MODE_VSYNC, 0), 1 / 30.0 - 1 / 120.0, 1e-9);
    CHECK(ps4_present_min_duration(V, 7, PS4_FLIP_MODE_VSYNC, 60) == 0);
    // immediate (hsync) flips are never held
    CHECK(ps4_present_min_duration(V, 1, PS4_FLIP_MODE_HSYNC, 120) == 0);
}

// Display model: a frame ready at `ready` appears on the first refresh (multiple of 1/hz) that is
// not earlier than `ready` and not earlier than the previous appearance + min_duration.
static double appear(double ready, double prev, double min_dur, double hz) {
    const double period = 1.0 / hz;
    double t = ready > prev + min_dur ? ready : prev + min_dur;
    return ceil(t / period - 1e-9) * period;
}

// The policy's purpose: a 60 Hz guest that renders at ~90 fps with jitter, shown on a 120 Hz
// display, gets an even 16.7 ms cadence; uncapped it alternates between 8.3 and 16.7 ms.
static void cadence_test(void) {
    const double hz = 120;
    for (int mode = 0; mode < 2; mode++) {
        const double d = ps4_present_min_duration(mode ? PS4_PRESENT_VSYNC : PS4_PRESENT_UNCAPPED, 0,
                                                  PS4_FLIP_MODE_VSYNC, hz);
        double prev = 0, ready = 0;
        int n8 = 0, n16 = 0, other = 0;
        srand(7);
        for (int i = 0; i < 2000; i++) {
            // vsync mode: the producer is held back by the display (FIFO), so the next frame is
            // ready ~11 ms after the previous one appeared at the earliest
            ready = (mode ? (ready > prev ? ready : prev) : ready) + 0.011 + (rand() % 3000) * 1e-6;
            const double t = appear(ready, prev, d, hz);
            if (i > 0) {
                const double ms = (t - prev) * 1000;
                if (fabs(ms - 8.333) < 0.1) n8++;
                else if (fabs(ms - 16.667) < 0.1) n16++;
                else other++;
            }
            prev = t;
        }
        if (mode) {
            CHECK(n16 == 1999 && n8 == 0 && other == 0);
        } else {
            CHECK(n8 > 300 && n16 > 300); // the uneven cadence the vsync mode removes
        }
    }
}

static void fifo_test(void) {
    ps4_present_queue q;
    ps4_pq_init(&q, 3, false);
    int sup;
    CHECK(ps4_pq_try_acquire_locked(&q, &sup) == 0 && !sup);
    CHECK(ps4_pq_try_acquire_locked(&q, &sup) == 1);
    CHECK(ps4_pq_try_acquire_locked(&q, &sup) == 2);
    CHECK(ps4_pq_try_acquire_locked(&q, &sup) == -1); // full: FIFO waits, never replaces
    CHECK(ps4_pq_submit_locked(&q, 1, false));
    CHECK(ps4_pq_submit_locked(&q, 0, false));
    CHECK(!ps4_pq_submit_locked(&q, 0, false)); // already queued
    CHECK(ps4_pq_try_acquire_locked(&q, &sup) == -1 && !sup);
    CHECK(ps4_pq_try_take_locked(&q) == 1); // submission order, not slot order
    CHECK(ps4_pq_try_take_locked(&q) == 0);
    CHECK(ps4_pq_try_take_locked(&q) == -1);
    CHECK(!ps4_pq_idle_locked(&q));
    CHECK(!ps4_pq_release_locked(&q, 2)); // still rendering
    CHECK(ps4_pq_cancel_locked(&q, 2));
    CHECK(!ps4_pq_cancel_locked(&q, 2));
    CHECK(ps4_pq_release_locked(&q, 1));
    CHECK(!ps4_pq_release_locked(&q, 1));
    CHECK(ps4_pq_release_locked(&q, 0));
    CHECK(ps4_pq_idle_locked(&q));
    CHECK(!ps4_pq_submit_locked(&q, -1, false) && !ps4_pq_submit_locked(&q, 3, false));
    CHECK(q.superseded == 0);
}

static void mailbox_test(void) {
    ps4_present_queue q;
    ps4_pq_init(&q, 3, true);
    int sup;
    const int a = ps4_pq_try_acquire_locked(&q, &sup), b = ps4_pq_try_acquire_locked(&q, &sup);
    CHECK(ps4_pq_submit_locked(&q, a, false) && ps4_pq_submit_locked(&q, b, false));
    CHECK(ps4_pq_try_take_locked(&q) == a); // the presenter is busy with a (waiting for a drawable)
    const int c = ps4_pq_try_acquire_locked(&q, &sup);
    CHECK(c == 2 && !sup);
    CHECK(ps4_pq_submit_locked(&q, c, false));
    // no free slot: the oldest queued frame (b) is replaced, the one being presented is not
    int d = ps4_pq_try_acquire_locked(&q, &sup);
    CHECK(d == b && sup && q.superseded == 1);
    CHECK(ps4_pq_submit_locked(&q, d, false));
    d = ps4_pq_try_acquire_locked(&q, &sup);
    CHECK(d == c && sup && q.superseded == 2);
    // a frame that must be shown (screenshot) is never replaced
    CHECK(ps4_pq_submit_locked(&q, d, true));
    const int b2 = ps4_pq_try_acquire_locked(&q, &sup);
    CHECK(b2 == b && sup); // b is older than c and not kept
    CHECK(ps4_pq_submit_locked(&q, b2, false));
    CHECK(ps4_pq_try_take_locked(&q) == c); // kept c was queued first
    CHECK(ps4_pq_try_acquire_locked(&q, &sup) == b && sup);
    CHECK(ps4_pq_try_acquire_locked(&q, &sup) == -1); // a and c presenting, b rendering
}

// Threads: producer renders frames into slots, presenter shows them, like the renderer and the
// presenter thread. Every frame id that went into a slot is shown at most once, in order;
// FIFO shows all of them, mailbox shows the rest as superseded and never waits for long.
typedef struct {
    ps4_present_queue q;
    int frame_of_slot[PS4_PRESENT_MAX_SLOTS];
    int shown[4000];
    int n_shown;
    int frames;
    int present_us;
    double max_wait_s;
} Run;

static void *presenter(void *arg) {
    Run *r = arg;
    for (;;) {
        const int s = ps4_pq_take(&r->q);
        if (s < 0) return NULL;
        r->shown[r->n_shown++] = r->frame_of_slot[s];
        usleep(r->present_us); // waits for a drawable
        ps4_pq_release(&r->q, s);
    }
}

static void run_threads(Run *r, bool mailbox, int present_us) {
    memset(r, 0, sizeof(*r));
    ps4_pq_init(&r->q, 3, mailbox);
    r->frames = 1500;
    r->present_us = present_us;
    pthread_t th;
    pthread_create(&th, NULL, presenter, r);
    for (int f = 0; f < r->frames; f++) {
        double waited;
        int sup;
        const int s = ps4_pq_acquire(&r->q, 2.0, &sup, &waited);
        CHECK(s >= 0);
        if (s < 0) break;
        if (waited > r->max_wait_s) r->max_wait_s = waited;
        r->frame_of_slot[s] = f;
        if (f % 5 == 0) usleep(100); // renders
        CHECK(ps4_pq_submit(&r->q, s, f == 700));
    }
    CHECK(ps4_pq_drain(&r->q, 5.0));
    ps4_pq_stop(&r->q);
    pthread_join(th, NULL);
}

static void thread_test(void) {
    Run *r = calloc(1, sizeof(Run));
    run_threads(r, false, 200);
    CHECK(r->n_shown == r->frames && r->q.superseded == 0);
    for (int i = 0; i < r->n_shown; i++) CHECK(r->shown[i] == i);
    CHECK(r->max_wait_s > 0.0001); // the producer was held back by the slow presenter

    run_threads(r, true, 2000);
    CHECK(r->n_shown + (int)r->q.superseded == r->frames);
    CHECK(r->q.superseded > 0);
    int saw_kept = 0;
    for (int i = 1; i < r->n_shown; i++) CHECK(r->shown[i] > r->shown[i - 1]);
    for (int i = 0; i < r->n_shown; i++) saw_kept |= r->shown[i] == 700;
    CHECK(saw_kept);
    CHECK(r->shown[r->n_shown - 1] == r->frames - 1); // the newest frame is always shown
    CHECK(r->max_wait_s < 0.05); // never paced by the 2 ms presenter
    free(r);
}

static void timeout_test(void) {
    ps4_present_queue q;
    ps4_pq_init(&q, 2, false);
    int sup;
    double waited;
    CHECK(ps4_pq_acquire(&q, 1.0, &sup, &waited) == 0);
    CHECK(ps4_pq_acquire(&q, 1.0, &sup, &waited) == 1);
    const double t0 = now_s();
    CHECK(ps4_pq_acquire(&q, 0.05, &sup, &waited) == -1); // a stuck presenter cannot block forever
    CHECK(now_s() - t0 >= 0.045 && waited >= 0.045 && waited < 1.0);
    CHECK(ps4_pq_submit(&q, 0, false));
    CHECK(!ps4_pq_drain(&q, 0.02));
    CHECK(ps4_pq_take(&q) == 0);
    CHECK(ps4_pq_release(&q, 0));
    CHECK(ps4_pq_drain(&q, 0.02)); // slot 1 is rendering: that does not count as busy
    ps4_pq_stop(&q);
    CHECK(ps4_pq_take(&q) == -1);
    CHECK(ps4_pq_acquire(&q, 1.0, &sup, &waited) == -1);
}

int main(void) {
    mode_test();
    min_duration_test();
    cadence_test();
    fifo_test();
    mailbox_test();
    thread_test();
    timeout_test();
    if (g_fail) return 1;
    printf("present_queue_test: PASS\n");
    return 0;
}
