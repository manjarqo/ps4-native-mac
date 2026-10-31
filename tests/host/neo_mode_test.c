// Host test of the PS4 Pro (Neo) mode rule (core/ps4_neo.c) on the real param.sfo parser:
//  - a Pro-enhanced title's param.sfo (an application's, ATTRIBUTE bit 23) -> Neo on a Pro host;
//  - an application param.sfo without it -> base mode even on a Pro host (the console rule);
//  - an add-on's param.sfo (CATEGORY "ac", as repacks ship in sce_sys/) and no param.sfo at
//    all -> unknown, the host setting decides;
//  - a base host never gets Neo mode;
//  - an application param.sfo without CATEGORY -> unknown;
//  - crafted / truncated param.sfo files (a data offset that wraps a 32-bit sum, a string length
//    past the end, a buffer cut short) are rejected without reading out of bounds (run with ASan).
#include "ps4_neo.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures;
#define CHECK(cond, ...)                                                                            \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            printf("FAIL line %d: %s  ", __LINE__, #cond);                                         \
            printf(__VA_ARGS__);                                                                   \
            printf("\n");                                                                          \
            g_failures++;                                                                          \
        }                                                                                          \
    } while (0)

static void put32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}
static void put16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8);
}

// Writes a two-entry param.sfo (or, with no_category, a one-entry one with only ATTRIBUTE) (CATEGORY string, ATTRIBUTE int) in the PSF layout into buf.
static size_t make_sfo_n(uint8_t *buf, const char *category, uint32_t attribute, uint32_t n) {
    memset(buf, 0, 256);
    const uint32_t keys = 20 + 16 * n;
    const char k_attr[] = "ATTRIBUTE", k_cat[] = "CATEGORY";
    memcpy(buf + keys, k_attr, sizeof(k_attr));
    memcpy(buf + keys + sizeof(k_attr), k_cat, sizeof(k_cat));
    const uint32_t data = (keys + sizeof(k_attr) + sizeof(k_cat) + 3) & ~3u;
    buf[0] = 0; buf[1] = 'P'; buf[2] = 'S'; buf[3] = 'F';
    put32(buf + 4, 0x101);
    put32(buf + 8, keys);
    put32(buf + 12, data);
    put32(buf + 16, n);
    uint8_t *e = buf + 20;
    put16(e, 0); put16(e + 2, PSF_FMT_INT); put32(e + 4, 4); put32(e + 8, 4); put32(e + 12, 0);
    put32(buf + data, attribute);
    e += 16;
    const uint32_t clen = (uint32_t)strlen(category) + 1;
    put16(e, (uint16_t)sizeof(k_attr)); put16(e + 2, PSF_FMT_STRING); put32(e + 4, clen); put32(e + 8, 4);
    put32(e + 12, 4);
    memcpy(buf + data + 4, category, clen);
    return data + 4 + 4;
}

static size_t make_sfo(uint8_t *buf, const char *category, uint32_t attribute) {
    return make_sfo_n(buf, category, attribute, 2);
}

// Offsets of the two entries' data_offset / param_len fields in a make_sfo buffer.
enum { ATTR_LEN = 20 + 4, ATTR_DATA_OFF = 20 + 12, CAT_LEN = 36 + 4, CAT_DATA_OFF = 36 + 12 };

// Parses a crafted copy and returns its support; ASan reports an out-of-bounds read.
static Ps4NeoTitleSupport support_of_buf(uint8_t *buf, size_t size, char *why, size_t n, int *parsed) {
    Ps4SfoContext sfo;
    memset(&sfo, 0, sizeof(sfo));
    *parsed = ps4_sfo_load_memory(&sfo, buf, size);
    return *parsed ? ps4_neo_title_support(&sfo, why, n) : PS4_NEO_TITLE_UNKNOWN;
}

static Ps4NeoTitleSupport support_of(const char *category, uint32_t attribute, char *why, size_t n) {
    static uint8_t buf[256];
    const size_t size = make_sfo(buf, category, attribute);
    Ps4SfoContext sfo;
    memset(&sfo, 0, sizeof(sfo));
    if (!ps4_sfo_load_memory(&sfo, buf, size)) {
        printf("FAIL: fake param.sfo (%s) did not parse\n", category);
        g_failures++;
        return PS4_NEO_TITLE_UNKNOWN;
    }
    return ps4_neo_title_support(&sfo, why, n);
}

int main(void) {
    char why[160];
    // Uncharted 4's application param.sfo: ATTRIBUTE 0x20c00002 has bit 23.
    Ps4NeoTitleSupport t = support_of("gp", 0x20c00002u, why, sizeof(why));
    CHECK(t == PS4_NEO_TITLE_PRO, "Pro title: %d (%s)", t, why);
    CHECK(ps4_neo_mode_rule(1, t) == 1, "Pro title on a Pro host is not in Neo mode");
    CHECK(ps4_neo_mode_rule(0, t) == 0, "Pro title on a base host is in Neo mode");

    // An application that does not declare Pro support: base mode on a Pro.
    t = support_of("gd", 0x20400002u, why, sizeof(why));
    CHECK(t == PS4_NEO_TITLE_BASE, "base title: %d (%s)", t, why);
    CHECK(ps4_neo_mode_rule(1, t) == 0, "base title on a Pro host is in Neo mode");
    CHECK(strstr(why, "not declared") != NULL, "reason '%s'", why);

    // An add-on's param.sfo is not the application's, even with bit 23 set.
    t = support_of("ac", 0x00800000u, why, sizeof(why));
    CHECK(t == PS4_NEO_TITLE_UNKNOWN, "add-on sfo: %d (%s)", t, why);
    CHECK(ps4_neo_mode_rule(1, t) == 1 && ps4_neo_mode_rule(0, t) == 0, "unknown title does not follow the host");
    CHECK(strstr(why, "'ac'") != NULL, "reason '%s'", why);

    // No param.sfo.
    t = ps4_neo_title_support(NULL, why, sizeof(why));
    CHECK(t == PS4_NEO_TITLE_UNKNOWN, "no sfo: %d (%s)", t, why);
    CHECK(ps4_neo_mode_rule(1, t) == 1, "no sfo on a Pro host is not in Neo mode");

    // An application param.sfo without CATEGORY (one entry: ATTRIBUTE with bit 23).
    {
        static uint8_t buf[256];
        const size_t size = make_sfo_n(buf, "gd", 0x00800000u, 1);
        int parsed;
        t = support_of_buf(buf, size, why, sizeof(why), &parsed);
        CHECK(parsed && t == PS4_NEO_TITLE_UNKNOWN, "no CATEGORY: parsed %d, %d (%s)", parsed, t, why);
    }
    // Crafted ATTRIBUTE data offset: data_table_offset + 0xfffffff8 + 4 wraps a 32-bit sum to a
    // small value; the attribute must read as absent, not from before the buffer.
    {
        static uint8_t buf[256];
        const size_t size = make_sfo(buf, "gd", 0x00800000u);
        put32(buf + ATTR_DATA_OFF, 0xfffffff8u);
        int parsed;
        t = support_of_buf(buf, size, why, sizeof(why), &parsed);
        CHECK(parsed && t == PS4_NEO_TITLE_BASE && strstr(why, "absent"), "wrapped ATTRIBUTE offset: %d (%s)", t, why);
    }
    // Crafted CATEGORY length past the end of the buffer (and a wrapping one).
    {
        static uint8_t buf[256];
        const size_t size = make_sfo(buf, "gd", 0x00800000u);
        put32(buf + CAT_LEN, 0x1000u);
        int parsed;
        t = support_of_buf(buf, size, why, sizeof(why), &parsed);
        CHECK(parsed && t == PS4_NEO_TITLE_UNKNOWN, "long CATEGORY: %d (%s)", t, why);
        put32(buf + CAT_LEN, 3);
        put32(buf + CAT_DATA_OFF, 0xfffffffcu);
        t = support_of_buf(buf, size, why, sizeof(why), &parsed);
        CHECK(parsed && t == PS4_NEO_TITLE_UNKNOWN, "wrapped CATEGORY offset: %d (%s)", t, why);
    }
    // Truncated: the same file cut before its data table.
    {
        static uint8_t full[256];
        const size_t size = make_sfo(full, "gp", 0x00800000u);
        uint8_t *cut = malloc(size - 8); // exactly sized, so ASan sees any read past it
        memcpy(cut, full, size - 8);
        int parsed;
        t = support_of_buf(cut, size - 8, why, sizeof(why), &parsed);
        CHECK(t != PS4_NEO_TITLE_PRO, "truncated sfo still reads as Pro (parsed %d, %s)", parsed, why);
        free(cut);
    }

    if (g_failures) {
        printf("neo_mode_test: %d FAILED\n", g_failures);
        return 1;
    }
    printf("neo_mode_test: PASS\n");
    return 0;
}
