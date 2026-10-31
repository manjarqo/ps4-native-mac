#ifndef PS4_NEO_H
#define PS4_NEO_H

#include "ps4_sfo.h"

#ifdef __cplusplus
extern "C" {
#endif

// Whether a title runs in PS4 Pro (Neo) mode. On the console a Pro reports Neo mode only to a
// title whose param.sfo declares Pro support; every other title gets the base console (base GPU
// configuration, base direct memory), "boost mode" only raises its clocks. shadPS4 implements
// the same rule: sceKernelIsNeoMode() = IsNeo() && PSFAttributes.support_neo_mode, with
// support_neo_mode = ATTRIBUTE bit 23 ("Supports PS4 Pro (Neo) mode"), and sceKernelHasNeoMode()
// = IsNeo() (src/core/libraries/kernel/process.cpp, src/common/elf_info.h).
#define PS4_SFO_ATTRIBUTE_SUPPORT_NEO (1u << 23)

typedef enum {
    PS4_NEO_TITLE_UNKNOWN = -1, // no application param.sfo: the title's support is not known
    PS4_NEO_TITLE_BASE = 0,     // the application's param.sfo does not declare Pro support
    PS4_NEO_TITLE_PRO = 1,      // the application's param.sfo declares Pro support
} Ps4NeoTitleSupport;

// The title's declared support from its param.sfo (NULL = none found). Only an application's
// param.sfo counts: its CATEGORY starts with 'g' (gd application, gp patch, ...). An add-on's
// ("ac") or any other category describes other content, so the support stays unknown. `why`
// gets a short reason for the log.
Ps4NeoTitleSupport ps4_neo_title_support(const Ps4SfoContext *sfo, char *why, size_t why_size);

// Neo mode = the host asks for a Pro console and the title does not run in base mode there. An
// unknown title follows the host setting.
int ps4_neo_mode_rule(int host_pro, Ps4NeoTitleSupport title);

#ifdef __cplusplus
}
#endif

#endif // PS4_NEO_H
