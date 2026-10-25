// Host test for the PS4_SCREENSHOT_EVERY_SEC time cadence (libSceVideoOut/ps4_screenshot_cadence.h).
#include "ps4_screenshot_cadence.h"
#include <stdio.h>
#include <math.h>
#include <stdlib.h>

static int fails;

// Expects the flip at `now` to be saved under `want` seconds (-1: not saved), and its elapsed
// milliseconds to be those since the first flip.
#define EXPECT(c, now, want)                                                                \
    do {                                                                                    \
        long ms_ = ps4_shot_cadence_due((c), (now));                                        \
        long got_ = ms_ < 0 ? -1 : ps4_shot_cadence_name((c)->every, ms_);                  \
        if (got_ != (want)) {                                                               \
            fprintf(stderr, "screenshot_cadence_test:%d: at %.3f s: got %ld, want %ld\n",   \
                    __LINE__, (double)(now), got_, (long)(want));                           \
            fails++;                                                                        \
        }                                                                                   \
        long want_ms_ = (long)floor(((now) - (c)->t0) * 1000.0);                            \
        if (ms_ >= 0 && ms_ != want_ms_) {                                                  \
            fprintf(stderr, "screenshot_cadence_test:%d: at %.3f s: %ld ms, want %ld\n",    \
                    __LINE__, (double)(now), ms_, want_ms_);                                \
            fails++;                                                                        \
        }                                                                                   \
    } while (0)

int main(void) {
    // Every 2 s, the clock starting at an arbitrary point: the first flip is t=0, then the first
    // flip at or after 2, 4, ... seconds after it; flips in between are not saved.
    ps4_shot_cadence c = {.every = 2};
    EXPECT(&c, 100.0, 0);
    EXPECT(&c, 100.5, -1);
    EXPECT(&c, 101.999, -1);
    EXPECT(&c, 102.0, 2);
    EXPECT(&c, 102.01, -1);
    EXPECT(&c, 103.9, -1);
    EXPECT(&c, 104.3, 4);
    // after a stall from 4.3 s to 10.1 s the flip is named by the last multiple it passed (10),
    // the moment it shows; the skipped multiples (6, 8) are not saved
    EXPECT(&c, 110.1, 10);
    EXPECT(&c, 110.2, -1);
    EXPECT(&c, 111.9, -1);
    EXPECT(&c, 112.0, 12);

    // Every 1 s with flips at 0.4 s: consecutive shots never share an index.
    ps4_shot_cadence f = {.every = 1};
    EXPECT(&f, 7.0, 0);
    EXPECT(&f, 7.4, -1);
    EXPECT(&f, 7.8, -1);
    EXPECT(&f, 8.2, 1);
    EXPECT(&f, 8.6, -1);
    EXPECT(&f, 9.0, 2);
    EXPECT(&f, 9.4, -1);

    // The same cadence over 60 s of flips at 30 fps: one shot per period, indices 0, 3, ... 57.
    ps4_shot_cadence r = {.every = 3};
    long expect = 0, shots = 0;
    for (int i = 0; i < 1800; i++) {
        long ms = ps4_shot_cadence_due(&r, 50.0 + i / 30.0);
        if (ms < 0) continue;
        long s = ps4_shot_cadence_name(r.every, ms);
        if (s != expect) {
            fprintf(stderr, "screenshot_cadence_test: flip %d: index %ld, want %ld\n", i, s, expect);
            fails++;
        }
        expect += 3;
        shots++;
    }
    if (shots != 20) {
        fprintf(stderr, "screenshot_cadence_test: %ld shots in 60 s at 3 s, want 20\n", shots);
        fails++;
    }

    if (fails) return 1;
    printf("screenshot_cadence_test: PASS\n");
    return 0;
}
