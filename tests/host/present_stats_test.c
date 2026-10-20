// Host test for the presenter statistics (libSceVideoOut/ps4_present_stats.c).
#include "ps4_present_stats.h"

#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_fail;
#define CHECK(c)                                                                                                       \
    do {                                                                                                               \
        if (!(c)) {                                                                                                    \
            fprintf(stderr, "present_stats_test: %s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #c);                \
            g_fail = 1;                                                                                                \
        }                                                                                                              \
    } while (0)
#define NEAR(a, b, eps) CHECK(fabs((double)(a) - (double)(b)) <= (eps))

// Value after `key` in `line`, -1 when absent.
static double field(const char *line, const char *key) {
    const char *k = strstr(line, key);
    return k ? atof(k + strlen(key)) : -1;
}

static void summarize_test(void) {
    float ms[100];
    // shuffled 1..100 ms
    for (int i = 0; i < 100; i++) ms[i] = (float)((i * 37) % 100 + 1);
    ps4_present_summary s;
    ps4_present_summarize(ms, 100, &s);
    CHECK(s.frames == 100);
    NEAR(s.p50, 51, 1e-6); // index 50 of the sorted values
    NEAR(s.p95, 96, 1e-6);
    NEAR(s.p99, 100, 1e-6);
    NEAR(s.max, 100, 1e-6);
    CHECK(s.over33 == 67); // 34..100
    CHECK(s.over50 == 50); // 51..100
    CHECK(s.over100 == 0);
    CHECK(s.under6 == 5); // 1..5
    float one = 8.3f;
    ps4_present_summarize(&one, 1, &s);
    CHECK(s.frames == 1 && s.p50 == one && s.p99 == one && s.max == one);
    ps4_present_summarize(ms, 0, &s);
    CHECK(s.frames == 0 && s.max == 0);
}

static void chain_test(void) {
    ps4_present_stats st;
    ps4_present_stats_init(&st);
    // 120 Hz display: frames on refreshes 0, 1, 3 (one refresh missed), a dropped drawable, then 4
    const double hz = 1.0 / 120.0;
    ps4_present_stats_on_presented(&st, 100.0);
    ps4_present_stats_on_presented(&st, 100.0 + hz);
    ps4_present_stats_on_presented(&st, 100.0 + 3 * hz);
    ps4_present_stats_on_presented(&st, 0); // dropped: does not break the chain
    ps4_present_stats_on_presented(&st, 100.0 + 4 * hz);
    CHECK(st.n_interval == 3);
    NEAR(st.interval_ms[0], 8.333, 0.01);
    NEAR(st.interval_ms[1], 16.667, 0.01);
    NEAR(st.interval_ms[2], 8.333, 0.01);
    CHECK(st.dropped == 1 && st.total_dropped == 1 && st.total_presented == 4);
    // a time that goes backwards adds no interval, the chain restarts from it
    ps4_present_stats_on_presented(&st, 99.0);
    CHECK(st.n_interval == 3);
    ps4_present_stats_on_presented(&st, 99.0 + 2 * hz);
    CHECK(st.n_interval == 4);
    NEAR(st.interval_ms[3], 16.667, 0.01);
}

static void report_test(void) {
    ps4_present_stats st;
    ps4_present_stats_init(&st);
    char line[512];
    // 599 frames at 120 Hz, the 300th 50 ms late (a hitch: 6 refreshes)
    double t = 10.0;
    for (int i = 0; i < PS4_PRESENT_STATS_WINDOW - 1; i++) {
        t += (i == 300) ? 0.050 : 1.0 / 120.0;
        ps4_present_stats_on_presented(&st, t);
        CHECK(!ps4_present_stats_report(&st, line, sizeof(line)));
    }
    ps4_present_stats_on_acquire(&st, 0.5);
    ps4_present_stats_on_acquire(&st, 5.0);
    ps4_present_stats_on_acquire(&st, 20.0);
    ps4_present_stats_on_backpressure(&st, 3.0);
    ps4_present_stats_on_superseded(&st);
    ps4_present_stats_on_submit(&st, 1.000);
    ps4_present_stats_on_submit(&st, 1.001); // 1 ms after the previous: a burst
    ps4_present_stats_on_submit(&st, 1.010);
    ps4_present_stats_on_presented(&st, 0); // the 600th frame is dropped
    CHECK(ps4_present_stats_report(&st, line, sizeof(line)));
    CHECK(field(line, "displayed ") == 598); // 599 shown frames, 598 intervals between them
    NEAR(field(line, "p50 "), 8.3, 0.05);
    NEAR(field(line, "p99 "), 8.3, 0.05);
    NEAR(field(line, "max "), 50.0, 0.05);
    CHECK(field(line, ">33ms ") == 1);
    CHECK(field(line, ">50ms ") == 0); // 50.0 is not over 50
    CHECK(field(line, "dropped ") == 1);
    CHECK(field(line, "superseded ") == 1);
    NEAR(field(line, "nextDrawable avg "), 25.5 / 3, 0.01);
    NEAR(field(line, "nextDrawable avg 8.50 max "), 20.0, 0.01);
    CHECK(field(line, "(>4ms ") == 2);
    CHECK(field(line, ">16ms ") == 1);
    NEAR(field(line, "backpressure avg "), 3.0, 0.01);
    CHECK(field(line, "submits ") == 3);
    CHECK(field(line, "bursts <2ms ") == 1);
    // the next window starts empty but keeps the chain: its first frame has an interval
    CHECK(!ps4_present_stats_report(&st, line, sizeof(line)));
    CHECK(st.n_window == 0 && st.n_interval == 0 && st.dropped == 0 && st.acquire_n == 0 && st.submits == 0);
    ps4_present_stats_on_presented(&st, t + 1.0 / 60.0);
    CHECK(st.n_interval == 1);
    NEAR(st.interval_ms[0], 16.667, 0.01);
    CHECK(st.total_presented == 600 && st.total_dropped == 1 && st.total_superseded == 1);
}

// Presented handlers run on Metal's threads: concurrent updates must not be lost.
static ps4_present_stats g_shared;
static void *hammer(void *arg) {
    const int id = (int)(long)arg;
    for (int i = 0; i < 20000; i++) {
        ps4_present_stats_on_presented(&g_shared, (i % 7 == 0) ? 0.0 : 1.0 + id * 1000.0 + i * 0.001);
        ps4_present_stats_on_acquire(&g_shared, 1.0);
        char line[512];
        ps4_present_stats_report(&g_shared, line, sizeof(line));
    }
    return NULL;
}

static void thread_test(void) {
    ps4_present_stats_init(&g_shared);
    pthread_t th[4];
    for (long i = 0; i < 4; i++) pthread_create(&th[i], NULL, hammer, (void *)i);
    for (int i = 0; i < 4; i++) pthread_join(th[i], NULL);
    const uint64_t dropped_per_thread = (20000 + 6) / 7; // i % 7 == 0
    CHECK(g_shared.total_dropped == 4 * dropped_per_thread);
    CHECK(g_shared.total_presented == 4 * (20000 - dropped_per_thread));
}

int main(void) {
    summarize_test();
    chain_test();
    report_test();
    thread_test();
    if (g_fail) return 1;
    printf("present_stats_test: PASS\n");
    return 0;
}
