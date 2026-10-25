// Host tests that drive a renderer backend directly: the backend PS4_GNM_METAL names
// (test_backend.h), a CHECK that counts failures, a commit that waits for its seq, and the
// backend-generic encoder-state checks.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <memory>
#include <string>

#include "ps4_gnm_backend.h"
#include "test_backend.h"

// Failures counted by CHECK (one counter per test program).
inline int g_fail = 0;
#define CHECK(c, ...)                                                    \
    do {                                                                 \
        if (!(c)) {                                                      \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);         \
            fprintf(stderr, __VA_ARGS__);                                \
            fprintf(stderr, "\n");                                       \
            g_fail++;                                                    \
        }                                                                \
    } while (0)

// A child process that is expected to abort (a FATAL under test) calls ExitOnAbort() first: its
// SIGABRT handler exits with kAbortExit, so the intended abort leaves no crash report. The parent
// checks WIFEXITED with kAbortExit (any other end, a crash or a return, fails) and the message.
constexpr int kAbortExit = 86;
inline void ExitOnAbort() {
    signal(SIGABRT, [](int) { _exit(kAbortExit); });
}

// Commits seq and waits (5 s) for its completion; false on failure or timeout.
inline bool CommitAndWait(ps4gnm::GnmBackend& be, uint64_t seq) {
    struct Done {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        bool failed = false;
    };
    auto* d = new Done; // deleted after the wait (a timed-out one leaks it; the test fails anyway)
    be.Commit(seq, [](void* p, const ps4gnm::GnmCompletion& c) {
        Done* x = static_cast<Done*>(p);
        x->failed = c.failed;
        dispatch_semaphore_signal(x->sem);
    }, d);
    if (dispatch_semaphore_wait(d->sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) return false;
    const bool ok = !d->failed;
    delete d;
    return ok;
}

// The encoder state the renderer reads (OpenEncoder, EncoderSerial: GnmBackend's NoteEncoder*
// bookkeeping), per target, across an encoder's open and end and target switches: an encoder
// opened on Upload never changes Main's serial (the serial is per target). Opens Main and Upload command
// buffers and copy encoders; leaves both command buffers open, all encoders ended, Main current.
inline void CheckEncoderTracking(ps4gnm::GnmBackend& be) {
    using ps4gnm::GnmCmdTarget;
    using ps4gnm::GnmEncoder;
    CHECK(!be.CmdOpen(GnmCmdTarget::Main) && !be.CmdOpen(GnmCmdTarget::Upload), "a command buffer open at start");
    CHECK(be.Target() == GnmCmdTarget::Main, "Main is not the current target");
    be.BeginCmd(GnmCmdTarget::Main, @"encoder tracking main", false);
    CHECK(be.OpenEncoder() == GnmEncoder::None, "an encoder reported before one was opened");
    const uint64_t m0 = be.EncoderSerial();
    be.BeginCopies();
    const uint64_t m1 = be.EncoderSerial();
    CHECK(m1 != m0, "opening an encoder on Main did not change Main's serial");
    CHECK(be.OpenEncoder() == GnmEncoder::Copy, "copy encoder on Main not reported (%d)", (int)be.OpenEncoder());

    be.UseTarget(GnmCmdTarget::Upload);
    CHECK(be.Target() == GnmCmdTarget::Upload, "UseTarget(Upload)");
    be.BeginCmd(GnmCmdTarget::Upload, @"encoder tracking upload", false);
    CHECK(be.OpenEncoder() == GnmEncoder::None, "Upload reports Main's encoder (%d)", (int)be.OpenEncoder());
    const uint64_t u0 = be.EncoderSerial();
    be.BeginCopies();
    CHECK(be.OpenEncoder() == GnmEncoder::Copy, "copy encoder on Upload not reported (%d)", (int)be.OpenEncoder());
    CHECK(be.EncoderSerial() != u0, "opening an encoder on Upload did not change Upload's serial");
    be.EndEncoder();
    CHECK(be.OpenEncoder() == GnmEncoder::None, "EndEncoder on Upload left an encoder reported");
    be.BeginCopies();
    be.EndEncoder();

    be.UseTarget(GnmCmdTarget::Main);
    CHECK(be.EncoderSerial() == m1, "Upload encoders changed Main's serial: %llu -> %llu", (unsigned long long)m1,
          (unsigned long long)be.EncoderSerial());
    CHECK(be.OpenEncoder() == GnmEncoder::Copy, "Main's copy encoder no longer reported after the switch back");
    be.EndEncoder();
    CHECK(be.OpenEncoder() == GnmEncoder::None, "EndEncoder on Main left an encoder reported");
    CHECK(be.EncoderSerial() == m1, "EndEncoder changed Main's serial");
}
