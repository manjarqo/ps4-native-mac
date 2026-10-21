// SPDX-License-Identifier: GPL-2.0-or-later
// gnm_replay <frame_dir> <pass> [--out <dir>]: replays one captured pass through the renderer and
// compares its outputs with the capture byte for byte (gnm_replay.h).
// Exit status: 0 every output matches, 1 a mismatch, 2 the pass could not be replayed or the
// capture records no output of it (nothing to compare).
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gnm_replay.h"

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: gnm_replay <frame_dir> <pass> [--out <dir>]\n");
            return 2;
        }
        ps4replay::Options o;
        o.frame_dir = argv[1];
        o.pass = (uint32_t)strtoul(argv[2], nullptr, 10);
        for (int i = 3; i + 1 < argc; ++i)
            if (!strcmp(argv[i], "--out")) o.out_dir = argv[++i];
        const ps4replay::Result r = ps4replay::ReplayPass(o);
        for (const std::string& n : r.notes) printf("note: %s\n", n.c_str());
        if (!r.ran) {
            printf("pass %u: NOT REPLAYED: %s\n", o.pass, r.error.c_str());
            return 2;
        }
        if (r.outputs.empty()) {
            printf("pass %u: NOTHING TO COMPARE: the capture records no output this pass writes\n", o.pass);
            return 2;
        }
        for (const ps4replay::OutputResult& out : r.outputs) {
            if (!out.compared)
                printf("NOT CAPTURED %s\n", out.what.c_str());
            else if (out.match)
                printf("MATCH %s (%llu bytes)\n", out.what.c_str(), (unsigned long long)out.size);
            else
                printf("DIFF %s: %llu of %llu bytes differ, first at offset 0x%llx\n", out.what.c_str(),
                       (unsigned long long)out.diff_bytes, (unsigned long long)out.size,
                       (unsigned long long)out.first_diff);
        }
        const bool ok = r.AllMatch();
        printf("pass %u: %s\n", o.pass, ok ? "BYTE-EXACT" : "MISMATCH");
        return ok ? 0 : 1;
    }
}
