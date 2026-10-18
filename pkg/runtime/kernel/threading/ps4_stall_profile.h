// Aggregation of thread samples taken during a frame stall (PS4_STALL_PROFILE): samples are
// stored raw while the stall lasts; the report symbolizes them, counts the leaf host function of
// every sample per thread and prints the most frequent ones.
#pragma once
#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

#define STALL_PROFILE_MAX_THREADS 64
#define STALL_PROFILE_DEPTH 8
// Samples kept per stall (all threads together); later samples count in totals only.
#define STALL_PROFILE_POOL 32768

// Resolves pc to the start address and name of its function; returns 0 when unknown.
typedef int (*stall_symbolize_fn)(uint64_t pc, uint64_t *func_start, const char **name);

typedef struct StallProfile StallProfile;

StallProfile *stall_profile_create(stall_symbolize_fn sym);
void stall_profile_destroy(StallProfile *p);
void stall_profile_reset(StallProfile *p);
// One sample of thread `slot`: pcs[0] is the PC, pcs[1..n-1] the return addresses (innermost
// first). Only copies the pcs into the pool allocated at create: never symbolizes, never
// allocates, never takes a lock.
void stall_profile_add(StallProfile *p, int slot, const char *thread_name, const uint64_t *pcs, int n);
// Prints "[stall-profile]" lines: the stall, then every thread that was busy for at least 5 %
// of its samples (and "Frame Submission" always) with its `top` most frequent functions.
// Symbolizes the stored samples on the calling thread.
void stall_profile_report(const StallProfile *p, FILE *out, double stall_ms, int top);
// Same, with " (watchdog max gap G ms)" appended to the header when max_gap_ms >= 0.
void stall_profile_report_gap(const StallProfile *p, FILE *out, double stall_ms, int top, double max_gap_ms);

#ifdef __cplusplus
}
#endif
