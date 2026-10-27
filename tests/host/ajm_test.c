// Host test of libSceAjm's batch error record (SceAjmBatchError), sceAjmBatchErrorDump and
// sceAjmDecAt9ParseConfigData, through the guest ABI on a fake guest memory.
//
// inFAMOUS Second Son builds a batch with a SceAjmBatchInfo, starts it with sceAjmBatchStartBuffer
// and, when that fails, calls sceAjmBatchErrorDump(&info, &error) (eboot 0x872e53). The record has
// the layout {int32 error_code; void *job_addr; uint32 cmd_offset; void *job_ra} (32 bytes).
//
// Checks: a batch whose second job names an instance that does not exist fails sceAjmBatchWait
// with 0 (as shadPS4's does), fills the job's result sideband and the record names that job (not the first, valid one, and not the
// third failing one) by command offset, job address and the return address it was built with;
// a clean batch leaves a cleared record; failures of sceAjmBatchStartBuffer fill the record too;
// sceAjmBatchErrorDump validates its arguments; the ATRAC9 config word FE 72 2E 70 parses to
// 372-byte frames, 4 per superframe, 256 samples each, and broken configs are refused.
//
// Per-instance counters (ps4_ajm_instance_stats): a batch of one decode job over a RIFF-wrapped,
// zeroed 372-byte ATRAC9 frame (config FE 72 2E 70) counts 1 job, and its frames and errors match
// the job's result sideband, whatever libatrac9 makes of the zero frame; a zeroed superframe
// after it adds its own frames and samples; the failing batch's missing instances do not count
// against the instance, whose own job in that batch counts once.
#include "ps4_ajm.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(cond, ...)                                                                       \
    do {                                                                                       \
        if (!(cond)) {                                                                         \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);                               \
            fprintf(stderr, __VA_ARGS__);                                                      \
            fprintf(stderr, "\n");                                                             \
            failures++;                                                                        \
        }                                                                                      \
    } while (0)

#define MEM_SIZE 0x100000
#define STACK 0x1000
static GuestContext g;

static void *gp(uint64_t a) { return g.mem_base + a; }

// Calls a shim with a return address at the stack top, the way the recompiled caller does.
static int32_t call(void (*fn)(GuestContext *), uint64_t a1, uint64_t a2, uint64_t a3,
                    uint64_t a4, uint64_t a5, uint64_t a6) {
    g.rsp = STACK;
    g.rdi = a1;
    g.rsi = a2;
    g.rdx = a3;
    g.rcx = a4;
    g.r8 = a5;
    g.r9 = a6;
    g.rax = 0xdeadbeef;
    fn(&g);
    CHECK(g.rsp == STACK + 8, "shim did not pop its return address");
    return (int32_t)g.rax;
}

// sceAjmBatchJobControlBufferRa(batch, instance, flags, in, in_size, out, out_size, ra): the
// last two arguments are on the stack. Returns the guest address after the job.
static uint64_t add_control_job(uint64_t at, uint32_t instance, uint64_t out, uint64_t ra) {
    uint64_t *stack = (uint64_t *)gp(STACK);
    stack[1] = 16; // out_size
    stack[2] = ra;
    g.rsp = STACK;
    g.rdi = at;
    g.rsi = instance;
    g.rdx = 0;
    g.rcx = 0;
    g.r8 = 0;
    g.r9 = out;
    shim_sceAjmBatchJobControlBufferRa(&g);
    return g.rax;
}

// sceAjmBatchJobRunBufferRa(batch, instance, flags, in, in_size, out, out_size, sideband,
// sideband_size, ra): the last four arguments are on the stack.
static uint64_t add_run_job(uint64_t at, uint32_t instance, uint64_t flags, uint64_t in,
                            uint64_t in_size, uint64_t out, uint64_t out_size, uint64_t sb,
                            uint64_t sb_size) {
    uint64_t *stack = (uint64_t *)gp(STACK);
    stack[1] = out_size;
    stack[2] = sb;
    stack[3] = sb_size;
    stack[4] = 0;
    g.rsp = STACK;
    g.rdi = at;
    g.rsi = instance;
    g.rdx = flags;
    g.rcx = in;
    g.r8 = in_size;
    g.r9 = out;
    shim_sceAjmBatchJobRunBufferRa(&g);
    return g.rax;
}

typedef struct {
    int32_t error_code;
    uint64_t job_addr;
    uint32_t cmd_offset;
    uint64_t job_ra;
} Record;

static void poison(uint64_t a) { memset(gp(a), 0xAA, 32); }
static Record rd(uint64_t a) {
    uint8_t *p = (uint8_t *)gp(a);
    Record r;
    memcpy(&r.error_code, p, 4);
    memcpy(&r.job_addr, p + 8, 8);
    memcpy(&r.cmd_offset, p + 16, 4);
    memcpy(&r.job_ra, p + 24, 8);
    return r;
}

#define BATCH 0x10000
#define REC 0x2000
#define OUT_ID 0x2100
#define INFO 0x2200
#define SIDEBAND 0x3000
#define CFG 0x2300
#define CODEC 0x2400
#define AT9_IN 0x20000
#define AT9_OUT 0x30000
#define AT9_SB 0x3800

// Result bits that make a job count as an error (ps4_ajm.c's AJM_RESULT_ERROR_MASK).
#define ERROR_BITS                                                                             \
    (ORBIS_AJM_RESULT_NOT_INITIALIZED | ORBIS_AJM_RESULT_INVALID_DATA |                          \
     ORBIS_AJM_RESULT_INVALID_PARAM | ORBIS_AJM_RESULT_TOO_MANY_CHANS |                          \
     ORBIS_AJM_RESULT_UNSUPP_FLAG | ORBIS_AJM_RESULT_CODEC_ERROR | ORBIS_AJM_RESULT_FATAL)

// Runs one batch of one decode job (multiple frames, stream sideband) and returns its result
// sideband: result, frames, bytes written.
static void run_decode(uint32_t ctxid, uint32_t inst, uint64_t in_size, int32_t *result,
                       uint32_t *frames, int32_t *written) {
    const uint64_t flags = ((uint64_t)AJM_RUN_MULTIPLE_FRAMES << 11) |
                           ((uint64_t)AJM_SIDEBAND_STREAM << 45);
    memset(gp(AT9_SB), 0xAA, 64);
    uint64_t end = add_run_job(BATCH, inst, flags, AT9_IN, in_size, AT9_OUT, 0x4000, AT9_SB, 32);
    CHECK(call(shim_sceAjmBatchStartBuffer, ctxid, BATCH, (uint32_t)(end - BATCH), 0, REC, OUT_ID) == 0,
          "start decode");
    uint32_t id;
    memcpy(&id, gp(OUT_ID), 4);
    CHECK(call(shim_sceAjmBatchWait, ctxid, id, 0xFFFFFFFFu, REC, 0, 0) == 0, "wait decode");
    // result {result, internal}, stream {consumed, written, total}, mframe {frames, reserved}
    memcpy(result, gp(AT9_SB), 4);
    memcpy(written, gp(AT9_SB + 12), 4);
    memcpy(frames, gp(AT9_SB + 24), 4);
}

int main(void) {
    g.mem_base = (uint8_t *)calloc(1, MEM_SIZE);
    g.mem_size = MEM_SIZE;

    uint32_t ctxid = 0, inst = 0;
    CHECK(call(shim_sceAjmInitialize, 0, 0x2500, 0, 0, 0, 0) == 0, "initialize");
    memcpy(&ctxid, gp(0x2500), 4);
    CHECK(call(shim_sceAjmModuleRegister, ctxid, 1, 0, 0, 0, 0) == 0, "register ATRAC9");
    CHECK(call(shim_sceAjmInstanceCreate, ctxid, 1, 0, 0x2510, 0, 0) == 0, "create instance");
    memcpy(&inst, gp(0x2510), 4);

    // --- per-instance counters: one decode job over a RIFF-wrapped zeroed 372-byte frame ---
    {
        PS4AjmInstanceStats st0;
        CHECK(ps4_ajm_instance_stats(ctxid, inst, &st0) == 0, "stats of a fresh instance");
        CHECK(st0.jobs == 0 && st0.frames_decoded == 0 && st0.samples_out == 0 && st0.errors == 0,
              "a fresh instance has no counts");
        CHECK(ps4_ajm_instance_stats(ctxid, inst, NULL) == (int)ORBIS_AJM_ERROR_INVALID_PARAMETER,
              "stats without out");
        CHECK(ps4_ajm_instance_stats(ctxid, 0x3F00, &st0) == (int)ORBIS_AJM_ERROR_INVALID_INSTANCE,
              "stats of a missing instance");
        CHECK(ps4_ajm_instance_stats(ctxid + 1, inst, &st0) == (int)ORBIS_AJM_ERROR_INVALID_INSTANCE,
              "stats through another context");

        // RIFF | WAVE | fmt (WAVE_FORMAT_EXTENSIBLE, the ATRAC9 GUID, config FE 72 2E 70) | data
        static const uint8_t guid[16] = {0xD2, 0x42, 0xE1, 0x47, 0xBA, 0x36, 0x8D, 0x4D,
                                         0x88, 0xFC, 0x61, 0x65, 0x4F, 0x8C, 0x83, 0x6C};
        uint8_t *p = (uint8_t *)gp(AT9_IN);
        memset(p, 0, 0x1000);
        const uint32_t fmt_len = 52, frame = 372;
        uint32_t v;
        uint16_t h;
        memcpy(p, "RIFF", 4);
        v = 4 + 8 + fmt_len + 8 + frame;
        memcpy(p + 4, &v, 4);
        memcpy(p + 8, "WAVEfmt ", 8);
        memcpy(p + 16, &fmt_len, 4);
        uint8_t *f = p + 20;
        h = 0xFFFE; memcpy(f + 0, &h, 2);   // fmt_type
        h = 2;      memcpy(f + 2, &h, 2);   // channels
        v = 48000;  memcpy(f + 4, &v, 4);   // sample rate
        h = 256;    memcpy(f + 18, &h, 2);  // samples per block
        memcpy(f + 24, guid, 16);
        v = 1;      memcpy(f + 40, &v, 4);  // version
        const uint8_t cfg[4] = {0xFE, 0x72, 0x2E, 0x70};
        memcpy(f + 44, cfg, 4);
        memcpy(p + 20 + fmt_len, "data", 4);
        memcpy(p + 24 + fmt_len, &frame, 4);
        const uint64_t riff_size = 28 + fmt_len + frame; // the frame itself is zeroed

        int32_t res = 0, written = 0;
        uint32_t frames = 0;
        run_decode(ctxid, inst, riff_size, &res, &frames, &written);
        PS4AjmInstanceStats st;
        CHECK(ps4_ajm_instance_stats(ctxid, inst, &st) == 0, "stats after the decode batch");
        fprintf(stderr, "ajm_test: zero frame: result 0x%x, frames %u, bytes %d; stats jobs %llu "
                        "frames %llu samples %llu errors %llu (last 0x%x)\n",
                (uint32_t)res, frames, written, (unsigned long long)st.jobs,
                (unsigned long long)st.frames_decoded, (unsigned long long)st.samples_out,
                (unsigned long long)st.errors, (uint32_t)st.last_error);
        CHECK(st.jobs == 1, "jobs %llu after one decode job", (unsigned long long)st.jobs);
        CHECK(st.frames_decoded == frames, "frames %llu, sideband %u",
              (unsigned long long)st.frames_decoded, frames);
        CHECK(st.samples_out == (uint64_t)written / (2 * 2), "samples %llu, sideband %d bytes",
              (unsigned long long)st.samples_out, written);
        CHECK(st.errors == ((res & ERROR_BITS) ? 1u : 0u), "errors %llu, result 0x%x",
              (unsigned long long)st.errors, (uint32_t)res);
        CHECK(st.last_error == ((res & ERROR_BITS) ? res : 0), "last_error 0x%x, result 0x%x",
              (uint32_t)st.last_error, (uint32_t)res);

        // A zeroed superframe (4 x 372 bytes) on the now initialized instance.
        memset(p, 0, 4 * frame);
        int32_t res2 = 0, written2 = 0;
        uint32_t frames2 = 0;
        run_decode(ctxid, inst, 4 * frame, &res2, &frames2, &written2);
        CHECK(ps4_ajm_instance_stats(ctxid, inst, &st) == 0, "stats after the superframe");
        fprintf(stderr, "ajm_test: zero superframe: result 0x%x, frames %u, bytes %d; stats jobs "
                        "%llu frames %llu samples %llu errors %llu\n",
                (uint32_t)res2, frames2, written2, (unsigned long long)st.jobs,
                (unsigned long long)st.frames_decoded, (unsigned long long)st.samples_out,
                (unsigned long long)st.errors);
        CHECK(st.jobs == 2, "jobs %llu after two decode jobs", (unsigned long long)st.jobs);
        CHECK(st.frames_decoded == (uint64_t)frames + frames2, "frames %llu, sidebands %u + %u",
              (unsigned long long)st.frames_decoded, frames, frames2);
        CHECK(st.samples_out == (uint64_t)(written + written2) / (2 * 2), "samples %llu",
              (unsigned long long)st.samples_out);
        CHECK(st.errors == ((res & ERROR_BITS) ? 1u : 0u) + ((res2 & ERROR_BITS) ? 1u : 0u),
              "errors %llu", (unsigned long long)st.errors);
    }
    PS4AjmInstanceStats before;
    CHECK(ps4_ajm_instance_stats(ctxid, inst, &before) == 0, "stats before the failing batch");

    // --- a batch whose second job names an instance that does not exist ---
    const uint32_t bad = 0x3F00;
    uint64_t a0 = BATCH;
    uint64_t a1 = add_control_job(a0, inst, SIDEBAND, 0x41000);
    uint64_t a2 = add_control_job(a1, bad, SIDEBAND + 0x100, 0x42000);
    uint64_t a3 = add_control_job(a2, bad + 1, SIDEBAND + 0x200, 0x43000);
    poison(REC);
    int32_t r = call(shim_sceAjmBatchStartBuffer, ctxid, BATCH, (uint32_t)(a3 - BATCH), 0, REC,
                     OUT_ID);
    CHECK(r == 0, "start returned 0x%x", r);
    Record rec = rd(REC);
    CHECK(rec.error_code == 0 && rec.job_addr == 0 && rec.cmd_offset == 0 && rec.job_ra == 0,
          "an accepted batch leaves a cleared record (code 0x%x)", rec.error_code);
    uint32_t id;
    memcpy(&id, gp(OUT_ID), 4);
    poison(REC);
    r = call(shim_sceAjmBatchWait, ctxid, id, 0xFFFFFFFFu, REC, 0, 0);
    CHECK(r == 0, "wait returned 0x%x (a failed job does not fail the wait)", (uint32_t)r);
    {
        // the failed job's own result sideband says it was fatal
        int32_t res;
        memcpy(&res, gp(SIDEBAND + 0x100), 4);
        CHECK(res == (int32_t)(ORBIS_AJM_RESULT_INVALID_PARAM | ORBIS_AJM_RESULT_FATAL),
              "result sideband 0x%x", (uint32_t)res);
    }
    rec = rd(REC);
    CHECK((uint32_t)rec.error_code == ORBIS_AJM_ERROR_INVALID_INSTANCE, "record code 0x%x",
          (uint32_t)rec.error_code);
    CHECK(rec.cmd_offset == (uint32_t)(a1 - BATCH), "cmd_offset 0x%x, want 0x%x", rec.cmd_offset,
          (uint32_t)(a1 - BATCH));
    CHECK(rec.job_addr == a1, "job_addr 0x%llx, want 0x%llx", (unsigned long long)rec.job_addr,
          (unsigned long long)a1);
    CHECK(rec.job_ra == 0x42000, "job_ra 0x%llx, want 0x42000", (unsigned long long)rec.job_ra);
    {
        // Only the instance's own (first) job counts; the missing instances' failures do not.
        PS4AjmInstanceStats after;
        CHECK(ps4_ajm_instance_stats(ctxid, inst, &after) == 0, "stats after the failing batch");
        CHECK(after.jobs == before.jobs + 1, "jobs %llu -> %llu", (unsigned long long)before.jobs,
              (unsigned long long)after.jobs);
        CHECK(after.errors == before.errors && after.frames_decoded == before.frames_decoded,
              "errors %llu -> %llu", (unsigned long long)before.errors,
              (unsigned long long)after.errors);
    }

    // --- sceAjmBatchErrorDump ---
    uint64_t info[3] = {BATCH, a3 - BATCH, 0x1000};
    memcpy(gp(INFO), info, sizeof(info));
    CHECK(call(shim_sceAjmBatchErrorDump, INFO, REC, 0, 0, 0, 0) == 0, "dump of a failed job");
    CHECK((uint32_t)call(shim_sceAjmBatchErrorDump, INFO, 0, 0, 0, 0, 0) ==
              ORBIS_AJM_ERROR_INVALID_PARAMETER,
          "dump without a record");
    CHECK((uint32_t)call(shim_sceAjmBatchErrorDump, 0, REC, 0, 0, 0, 0) ==
              ORBIS_AJM_ERROR_INVALID_PARAMETER,
          "dump without a batch");
    uint64_t empty[3] = {0, 0, 0x1000};
    memcpy(gp(INFO + 0x40), empty, sizeof(empty));
    CHECK((uint32_t)call(shim_sceAjmBatchErrorDump, INFO + 0x40, REC, 0, 0, 0, 0) ==
              ORBIS_AJM_ERROR_INVALID_BATCH,
          "dump of a batch without a buffer");
    uint64_t shorter[3] = {BATCH, 8, 0x1000}; // the failing command is past the used part
    memcpy(gp(INFO + 0x80), shorter, sizeof(shorter));
    CHECK((uint32_t)call(shim_sceAjmBatchErrorDump, INFO + 0x80, REC, 0, 0, 0, 0) ==
              ORBIS_AJM_ERROR_INVALID_BATCH,
          "dump with the failing command outside the batch");

    // --- a clean batch ---
    uint64_t c1 = add_control_job(BATCH, inst, SIDEBAND, 0x41000);
    CHECK(call(shim_sceAjmBatchStartBuffer, ctxid, BATCH, (uint32_t)(c1 - BATCH), 0, REC, OUT_ID) == 0,
          "start clean");
    memcpy(&id, gp(OUT_ID), 4);
    poison(REC);
    CHECK(call(shim_sceAjmBatchWait, ctxid, id, 0xFFFFFFFFu, REC, 0, 0) == 0, "wait clean");
    rec = rd(REC);
    CHECK(rec.error_code == 0 && rec.job_addr == 0 && rec.cmd_offset == 0 && rec.job_ra == 0,
          "a clean batch leaves a cleared record (code 0x%x)", rec.error_code);
    uint64_t cleanInfo[3] = {BATCH, c1 - BATCH, 0x1000};
    memcpy(gp(INFO), cleanInfo, sizeof(cleanInfo));
    CHECK(call(shim_sceAjmBatchErrorDump, INFO, REC, 0, 0, 0, 0) == 0, "dump of an empty record");

    // --- sceAjmBatchStartBuffer failures fill the record ---
    poison(REC);
    r = call(shim_sceAjmBatchStartBuffer, ctxid, BATCH, 12, 0, REC, OUT_ID);
    CHECK((uint32_t)r == ORBIS_AJM_ERROR_MALFORMED_BATCH, "malformed size: 0x%x", (uint32_t)r);
    rec = rd(REC);
    CHECK((uint32_t)rec.error_code == ORBIS_AJM_ERROR_MALFORMED_BATCH, "record for malformed: 0x%x",
          (uint32_t)rec.error_code);
    poison(REC);
    r = call(shim_sceAjmBatchStartBuffer, ctxid + 9, BATCH, (uint32_t)(c1 - BATCH), 0, REC, OUT_ID);
    CHECK((uint32_t)r == ORBIS_AJM_ERROR_INVALID_CONTEXT, "bad context: 0x%x", (uint32_t)r);
    rec = rd(REC);
    CHECK((uint32_t)rec.error_code == ORBIS_AJM_ERROR_INVALID_CONTEXT, "record for context: 0x%x",
          (uint32_t)rec.error_code);

    // --- sceAjmDecAt9ParseConfigData ---
    // FE | rate index 7 (48 kHz) | channel config 1 | 0 | frame bytes - 1 = 371 | superframe 2^2
    const uint8_t good[4] = {0xFE, 0x72, 0x2E, 0x70};
    memcpy(gp(CFG), good, 4);
    memset(gp(CODEC), 0xAA, 16);
    CHECK(call(shim_sceAjmDecAt9ParseConfigData, CFG, CODEC, 0, 0, 0, 0) == 0, "parse good config");
    uint32_t ci[4];
    memcpy(ci, gp(CODEC), 16);
    CHECK(ci[0] == 372u * 4, "super_frame_size %u", ci[0]);
    CHECK(ci[1] == 4, "frames_in_super_frame %u", ci[1]);
    CHECK(ci[2] == 372u * 4, "next_frame_size %u", ci[2]);
    CHECK(ci[3] == 256, "frame_samples %u", ci[3]);
    struct {
        const char *name;
        uint8_t cfg[4];
        uint32_t super, frames, samples;
    } more[] = {
        // rate index 6 (44.1 kHz), channel config 0 (mono), 200-byte frames, superframe index 0
        {"mono 44.1 kHz, superframe 0", {0xFE, 0x60, 0x18, 0xE0}, 200, 1, 256},
        // rate 7, channel config 2 (stereo block), 100-byte frames, superframe index 3
        {"stereo 48 kHz, superframe 3", {0xFE, 0x74, 0x0C, 0x78}, 800, 8, 256},
    };
    for (size_t k = 0; k < sizeof(more) / sizeof(more[0]); k++) {
        memcpy(gp(CFG), more[k].cfg, 4);
        CHECK(call(shim_sceAjmDecAt9ParseConfigData, CFG, CODEC, 0, 0, 0, 0) == 0, "%s", more[k].name);
        memcpy(ci, gp(CODEC), 16);
        CHECK(ci[0] == more[k].super && ci[1] == more[k].frames && ci[2] == more[k].super &&
                  ci[3] == more[k].samples,
              "%s: got %u %u %u %u", more[k].name, ci[0], ci[1], ci[2], ci[3]);
    }
    // channel config indices 6 and 7 have no entry in libatrac9's table
    const uint8_t badChan6[4] = {0xFE, 0x7C, 0x2E, 0x70};
    const uint8_t badChan7[4] = {0xFE, 0x7E, 0x2E, 0x70};
    memcpy(gp(CFG), badChan6, 4);
    CHECK((uint32_t)call(shim_sceAjmDecAt9ParseConfigData, CFG, CODEC, 0, 0, 0, 0) ==
              ORBIS_AJM_ERROR_INVALID_PARAMETER,
          "channel config 6");
    memcpy(gp(CFG), badChan7, 4);
    CHECK((uint32_t)call(shim_sceAjmDecAt9ParseConfigData, CFG, CODEC, 0, 0, 0, 0) ==
              ORBIS_AJM_ERROR_INVALID_PARAMETER,
          "channel config 7");
    const uint8_t badHeader[4] = {0x00, 0x72, 0x2E, 0x70};
    const uint8_t badCheckBit[4] = {0xFE, 0x73, 0x2E, 0x70};
    memcpy(gp(CFG), badHeader, 4);
    memset(gp(CODEC), 0xAA, 16);
    CHECK((uint32_t)call(shim_sceAjmDecAt9ParseConfigData, CFG, CODEC, 0, 0, 0, 0) ==
              ORBIS_AJM_ERROR_INVALID_PARAMETER,
          "wrong header byte");
    memcpy(ci, gp(CODEC), 16);
    CHECK(ci[0] == 0xAAAAAAAAu, "a refused config leaves the output alone");
    memcpy(gp(CFG), badCheckBit, 4);
    CHECK((uint32_t)call(shim_sceAjmDecAt9ParseConfigData, CFG, CODEC, 0, 0, 0, 0) ==
              ORBIS_AJM_ERROR_INVALID_PARAMETER,
          "validation bit set");
    CHECK((uint32_t)call(shim_sceAjmDecAt9ParseConfigData, 0, CODEC, 0, 0, 0, 0) ==
              ORBIS_AJM_ERROR_INVALID_PARAMETER,
          "no config");
    CHECK((uint32_t)call(shim_sceAjmDecAt9ParseConfigData, CFG, 0, 0, 0, 0, 0) ==
              ORBIS_AJM_ERROR_INVALID_PARAMETER,
          "no output");

    ps4_ajm_destroy();
    free(g.mem_base);
    if (failures) {
        fprintf(stderr, "ajm_test: %d failures\n", failures);
        return 1;
    }
    printf("ajm_test: PASS\n");
    return 0;
}
