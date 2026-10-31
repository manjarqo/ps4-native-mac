#include "ps4_neo.h"

#include <stdio.h>
#include <string.h>

Ps4NeoTitleSupport ps4_neo_title_support(const Ps4SfoContext *sfo, char *why, size_t why_size) {
    char category[16] = "";
    if (!sfo) {
        snprintf(why, why_size, "no param.sfo");
        return PS4_NEO_TITLE_UNKNOWN;
    }
    if (!ps4_sfo_get_string(sfo, "CATEGORY", category, sizeof(category)) || category[0] != 'g') {
        snprintf(why, why_size, "param.sfo category '%s' is not an application's", category);
        return PS4_NEO_TITLE_UNKNOWN;
    }
    int32_t attr = 0;
    const int has_attr = ps4_sfo_get_int(sfo, "ATTRIBUTE", &attr);
    const int pro = ((uint32_t)attr & PS4_SFO_ATTRIBUTE_SUPPORT_NEO) != 0;
    snprintf(why, why_size, "param.sfo category %s, ATTRIBUTE 0x%x%s: Pro support %s", category, (uint32_t)attr,
             has_attr ? "" : " (absent)", pro ? "declared" : "not declared");
    return pro ? PS4_NEO_TITLE_PRO : PS4_NEO_TITLE_BASE;
}

int ps4_neo_mode_rule(int host_pro, Ps4NeoTitleSupport title) {
    return host_pro && title != PS4_NEO_TITLE_BASE;
}
