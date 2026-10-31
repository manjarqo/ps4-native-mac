// SPDX-License-Identifier: GPL-2.0-or-later
// gnm_replay <frame_dir> <pass> [--out <dir>] [--allocs <n>]: replays one captured pass through
// the renderer and compares its outputs with the capture byte for byte (gnm_replay.h).
// gnm_replay <frame_dir> <a>-<b>|all --sha [--out <dir>]: replays a range of passes in one
// process and prints one P line per pass and one O line per output with its SHA-256 (see
// FormatPassResult); it exits 0 whatever the passes did (a pass that cannot be replayed is a P
// ... NOT line), 2 on a bad argument.
// --settle (single pass or range), a diagnostic that classifies a difference a plain replay found,
// not a gate for ordering changes (Options::settle): each pass is replayed twice, inputs restored
// each time, and the second replay is judged. An output whose two replays differ is reported with
// both hashes: single pass, an "UNSTABLE-FIRST <what>: first <sha> settled <sha>" line per output
// and "pass <n>: UNSTABLE-FIRST" before the verdict line; range, U lines (FormatPassResult). A
// pass writing a texture it creates is replayed once ("NOT SETTLED", S line). The exit status is
// the judged replay's.
// gnm_replay <frame_dir> <pass>|<a>-<b>|all --time <n>: median and min encode + GPU wall time of
// each pass over n warmed-up replays (TimePasses), one "pass <id> <kind> <shader> median_ms <x>
// min_ms <x> runs <n>" line per pass and, for a range, a "total median_ms" line. Not combinable
// with --allocs, --settle or --sha.
// Single-pass exit status: 0 every output matches, 1 a mismatch, 2 the pass could not be replayed
// or the capture records no output of it (nothing to compare; the notes on stderr list the store
// instructions in its shaders, whose writes the renderer may not track).
#import <Foundation/Foundation.h>

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>

#include "gnm_replay.h"
#include "ps4_gnm_draw.h"

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: gnm_replay <frame_dir> <pass>|<a>-<b>|all [--out <dir>] [--sha] [--settle] [--allocs <n>] [--time <n>]\n");
            return 2;
        }
        ps4replay::Options o;
        o.frame_dir = argv[1];
        bool sha = false;
        int allocs = 0, time_runs = 0;
        for (int i = 3; i < argc; ++i) {
            if (!strcmp(argv[i], "--sha")) sha = true;
            else if (!strcmp(argv[i], "--settle")) o.settle = true;
            else if (!strcmp(argv[i], "--allocs") && i + 1 < argc) {
                char* e = nullptr;
                const long v = strtol(argv[++i], &e, 10);
                if (e == argv[i] || *e || v < 1 || v > 100000) {
                    fprintf(stderr, "--allocs wants a count from 1 to 100000, got '%s'\n", argv[i]);
                    return 2;
                }
                allocs = (int)v;
            }
            else if (!strcmp(argv[i], "--time") && i + 1 < argc) {
                char* e = nullptr;
                const long v = strtol(argv[++i], &e, 10);
                if (e == argv[i] || *e || v < 1 || v > 100000) {
                    fprintf(stderr, "--time wants a count from 1 to 100000, got '%s'\n", argv[i]);
                    return 2;
                }
                time_runs = (int)v;
            }
            else if (!strcmp(argv[i], "--out") && i + 1 < argc) o.out_dir = argv[++i];
        }
        uint32_t first = 0, last = 0;
        bool range = false;
        if (!ps4replay::ParsePassSpec(argv[2], &first, &last, &range)) {
            fprintf(stderr, "bad pass argument '%s': want <pass>, <a>-<b> with a <= b, or all\n", argv[2]);
            return 2;
        }
        if (time_runs) {
            if (allocs || o.settle || sha) {
                fprintf(stderr, "--time measures replays of its own: --allocs, --settle and --sha do not apply\n");
                return 2;
            }
            ps4gnm_capture::FrameRec f;
            std::string err;
            if (!ps4gnm_capture::LoadFrame(o.frame_dir, &f, &err)) {
                fprintf(stderr, "%s\n", err.c_str());
                return 2;
            }
            std::vector<std::string> notes;
            const std::vector<ps4replay::PassTime> times = ps4replay::TimePasses(o, first, last, time_runs, &notes);
            for (const std::string& n : notes) fprintf(stderr, "note: %s\n", n.c_str());
            double total = 0;
            for (const ps4replay::PassTime& t : times) {
                const ps4gnm_capture::PassRec& p = f.passes[t.pass];
                // the shader a pass is known by: the pixel shader of a draw (else its first stage), the compute shader
                const ps4gnm_capture::StageRec* st = p.stages.empty() ? nullptr : &p.stages[0];
                for (const ps4gnm_capture::StageRec& s : p.stages)
                    if (s.stage == "ps" || s.stage == "cs") st = &s;
                printf("pass %u %s 0x%llx median_ms %.3f min_ms %.3f runs %d\n", t.pass, p.type.c_str(),
                       (unsigned long long)(st ? st->code_addr : 0), t.median_ms, t.min_ms, t.runs);
                total += t.median_ms;
            }
            if (range) printf("total median_ms %.3f\n", total);
            if (times.empty()) {
                fprintf(stderr, "no pass could be timed\n");
                return 2;
            }
            return 0;
        }
        if (range) {
            if (allocs) {
                fprintf(stderr, "--allocs measures one pass: give a pass number, not a range\n");
                return 2;
            }
            if (!sha) {
                fprintf(stderr, "a range replay prints one hash per output: pass --sha\n");
                return 2;
            }
            o.sha256 = true;
            for (const ps4replay::PassResult& p : ps4replay::ReplayPasses(o, first, last)) {
                for (const std::string& n : p.r.notes) fprintf(stderr, "note: pass %u: %s\n", p.pass, n.c_str());
                fputs(ps4replay::FormatPassResult(p).c_str(), stdout);
            }
            // PS4_GNM_ASYNC_COMPUTE=1: where the replayed compute-ring passes ran
            const ps4draw::AsyncComputeCounts ac = ps4draw::GetAsyncComputeCounts();
            if (ac.on)
                fprintf(stderr, "async compute: %llu compute-ring jobs on the asynchronous compute queue, %llu on the main one\n",
                        (unsigned long long)ac.eligible, (unsigned long long)ac.joined);
            return 0;
        }
        o.pass = first;
        if (allocs > 0 && o.settle) {
            fprintf(stderr, "--allocs already measures warmed-up replays: --settle does not apply\n");
            return 2;
        }
        if (allocs > 0) {
            struct Counter {
                void (*begin)(void);
                uint64_t (*end)(void);
                uint64_t last = UINT64_MAX; // UINT64_MAX: the hooks did not run for this replay
            } c{(void (*)(void))dlsym(RTLD_DEFAULT, "alloc_count_begin"),
                (uint64_t(*)(void))dlsym(RTLD_DEFAULT, "alloc_count_end")};
            if (!c.begin || !c.end) {
                printf("alloc_count.dylib is not loaded (DYLD_INSERT_LIBRARIES=<replay out>/alloc_count.dylib)\n");
                return 2;
            }
            ps4replay::Result warm = ps4replay::ReplayPass(o); // caches, pipelines, textures
            if (!warm.ran) {
                printf("pass %u: NOT REPLAYED: %s\n", o.pass, warm.error.c_str());
                return 2;
            }
            o.around_render = [](void* p, bool begin) {
                Counter* k = static_cast<Counter*>(p);
                if (begin) k->begin();
                else k->last = k->end();
            };
            o.around_ctx = &c;
            uint64_t mn = UINT64_MAX, mx = 0;
            for (int k = 0; k < allocs; ++k) {
                c.last = UINT64_MAX;
                const ps4replay::Result run = ps4replay::ReplayPass(o);
                if (!run.ran || c.last == UINT64_MAX) {
                    printf("pass %u: measured replay %d did not run: %s\n", o.pass, k + 1,
                           run.ran ? "the renderer was not called" : run.error.c_str());
                    return 2;
                }
                mn = std::min(mn, c.last);
                mx = std::max(mx, c.last);
            }
            // every thread of the process counts, between the renderer's Draw/Dispatch and its Flush
            printf("allocs per replay: %llu (min of %d), max %llu\n", (unsigned long long)mn, allocs,
                   (unsigned long long)mx);
            return 0;
        }
        const ps4replay::Result r = ps4replay::ReplayPass(o);
        for (const std::string& n : r.notes) fprintf(stderr, "note: %s\n", n.c_str());
        if (!r.ran) {
            printf("pass %u: NOT REPLAYED: %s\n", o.pass, r.error.c_str());
            return 2;
        }
        if (r.outputs.empty()) {
            printf("pass %u: NOTHING TO COMPARE: no output recorded; the shader may write memory the renderer "
                   "does not track\n", o.pass);
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
        for (const ps4replay::OutputResult& out : r.outputs)
            if (out.unstable_first)
                printf("UNSTABLE-FIRST %s: first %s settled %s\n", out.what.c_str(), out.first_sha256.c_str(),
                       out.sha256.c_str());
        for (const auto& [what, h] : r.first_only)
            printf("UNSTABLE-FIRST %s: first %s settled ABSENT\n", what.c_str(), h.c_str());
        if (r.unstable_first) printf("pass %u: UNSTABLE-FIRST\n", o.pass);
        if (!r.not_settled.empty()) printf("pass %u: NOT SETTLED: %s\n", o.pass, r.not_settled.c_str());
        const bool ok = r.AllMatch();
        printf("pass %u: %s\n", o.pass, ok ? "BYTE-EXACT" : "MISMATCH");
        return ok ? 0 : 1;
    }
}
