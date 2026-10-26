// Host test for the output gamma of sceVideoOutAdjustColor (libSceVideoOut/ps4_output_gamma.h).
#include "ps4_output_gamma.h"
#include <math.h>
#include <stdio.h>

static int fails;

#define CHECK(cond, ...)                                                       \
    do {                                                                       \
        if (!(cond)) {                                                         \
            fprintf(stderr, "output_gamma_test:%d: ", __LINE__);               \
            fprintf(stderr, __VA_ARGS__);                                      \
            fprintf(stderr, "\n");                                             \
            fails++;                                                           \
        }                                                                      \
    } while (0)

int main(void) {
    // 1.0 is the identity
    for (int i = 0; i <= 255; i++) {
        const float e = i / 255.0f;
        const float o = ps4_output_gamma_apply(e, 1.0f);
        CHECK(fabsf(o - e) < 2e-3f, "gamma 1.0 changed %f to %f", e, o);
    }
    // below 1 darkens, above 1 brightens (the game's default 0.8 must not wash the image out)
    CHECK(ps4_output_gamma_apply(0.5f, 0.8f) < 0.5f, "gamma 0.8 does not darken mid grey");
    CHECK(ps4_output_gamma_apply(0.5f, 1.2f) > 0.5f, "gamma 1.2 does not brighten mid grey");
    // monotonic in the value and in gamma; black and white stay put
    for (int gi = 5; gi <= 15; gi++) {
        const float g = gi / 10.0f;
        float prev = -1.0f;
        for (int i = 0; i <= 255; i++) {
            const float o = ps4_output_gamma_apply(i / 255.0f, g);
            CHECK(o >= prev, "not monotonic at gamma %f, value %d", g, i);
            prev = o;
        }
        CHECK(ps4_output_gamma_apply(0.0f, g) == 0.0f, "black moved at gamma %f", g);
        CHECK(fabsf(ps4_output_gamma_apply(1.0f, g) - 1.0f) < 1e-4f, "white moved at gamma %f", g);
        CHECK(ps4_output_gamma_apply(0.5f, g) <= ps4_output_gamma_apply(0.5f, g + 0.1f),
              "not monotonic in gamma at %f", g);
    }
    if (fails) return 1;
    printf("output_gamma_test: ok\n");
    return 0;
}
