#include "ps4_stall_profile.h"
#include <stdlib.h>
#include <string.h>

#define STALL_PROFILE_MAX_FUNCS 128

typedef struct {
  uint64_t leaf, guest; // function starts (guest: 0 for busy samples)
  const char *leaf_name, *guest_name;
  uint32_t count;
  int waiting;
} StallFunc;

typedef struct {
  char name[32];
  uint32_t samples; // all samples of the thread, stored or not
} StallThread;

typedef struct {
  uint8_t slot, n;
  uint64_t pcs[STALL_PROFILE_DEPTH];
} StallSample;

struct StallProfile {
  stall_symbolize_fn sym;
  uint32_t nsamples; // stored samples in pool
  StallThread threads[STALL_PROFILE_MAX_THREADS];
  StallSample pool[STALL_PROFILE_POOL];
};

static int is_wait_function(const char *n) {
  static const char *const prefixes[] = {"__psynch_", "__semwait_signal", "__ulock_wait", "mach_msg",
                                         "kevent", "__workq_kernreturn", "__select", "semaphore_"};
  for (size_t i = 0; i < sizeof prefixes / sizeof prefixes[0]; i++)
    if (strncmp(n, prefixes[i], strlen(prefixes[i])) == 0) {
      if (strncmp(n, "semaphore_", 10) == 0 && !strstr(n, "wait")) return 0;
      return 1;
    }
  return 0;
}

StallProfile *stall_profile_create(stall_symbolize_fn sym) {
  StallProfile *p = (StallProfile *)calloc(1, sizeof(StallProfile));
  if (p) p->sym = sym;
  return p;
}

void stall_profile_destroy(StallProfile *p) { free(p); }

void stall_profile_reset(StallProfile *p) {
  // The pool is overwritten sample by sample, so only the counters need clearing.
  p->nsamples = 0;
  memset(p->threads, 0, sizeof(p->threads));
}

void stall_profile_add(StallProfile *p, int slot, const char *thread_name, const uint64_t *pcs, int n) {
  if (!p || slot < 0 || slot >= STALL_PROFILE_MAX_THREADS || n <= 0) return;
  StallThread *t = &p->threads[slot];
  if (!t->name[0]) {
    strncpy(t->name, thread_name ? thread_name : "unnamed", sizeof(t->name) - 1);
  }
  t->samples++;
  if (p->nsamples == STALL_PROFILE_POOL) return; // pool full: the sample still counts in totals
  StallSample *s = &p->pool[p->nsamples++];
  if (n > STALL_PROFILE_DEPTH) n = STALL_PROFILE_DEPTH;
  s->slot = (uint8_t)slot;
  s->n = (uint8_t)n;
  memcpy(s->pcs, pcs, (size_t)n * sizeof(pcs[0]));
}

// Symbolizes one stored sample and counts it in funcs; returns 1 when the thread was busy.
static int count_sample(const StallProfile *p, const StallSample *smp, StallFunc *funcs, uint32_t *nfuncs) {
  uint64_t leaf = 0, guest = 0;
  const char *leaf_name = "?", *guest_name = NULL;
  if (!p->sym(smp->pcs[0], &leaf, &leaf_name)) {
    leaf = smp->pcs[0];
    leaf_name = "?";
  }
  const int waiting = is_wait_function(leaf_name);
  if (waiting) {
    for (int i = 1; i < smp->n; i++) {
      uint64_t s;
      const char *nm;
      if (p->sym(smp->pcs[i], &s, &nm) && strncmp(nm, "fn_0x", 5) == 0) {
        guest = s;
        guest_name = nm;
        break;
      }
    }
  }
  for (uint32_t i = 0; i < *nfuncs; i++) {
    StallFunc *f = &funcs[i];
    if (f->leaf == leaf && f->guest == guest) {
      f->count++;
      return !waiting;
    }
  }
  if (*nfuncs == STALL_PROFILE_MAX_FUNCS) return !waiting; // table full: counts in totals only
  StallFunc *f = &funcs[(*nfuncs)++];
  f->leaf = leaf;
  f->guest = guest;
  f->leaf_name = leaf_name;
  f->guest_name = guest_name;
  f->count = 1;
  f->waiting = waiting;
  return !waiting;
}

static uint32_t pct(uint32_t part, uint32_t total) { return total ? (part * 100 + total / 2) / total : 0; }

void stall_profile_report_gap(const StallProfile *p, FILE *out, double stall_ms, int top, double max_gap_ms) {
  uint32_t rounds = 0;
  for (int s = 0; s < STALL_PROFILE_MAX_THREADS; s++)
    if (p->threads[s].samples > rounds) rounds = p->threads[s].samples;
  fprintf(out, "[stall-profile] stall %.0f ms, %u samples", stall_ms, rounds);
  if (max_gap_ms >= 0) fprintf(out, " (watchdog max gap %.1f ms)", max_gap_ms);
  fprintf(out, "\n");
  StallFunc funcs[STALL_PROFILE_MAX_FUNCS];
  for (int s = 0; s < STALL_PROFILE_MAX_THREADS; s++) {
    const StallThread *t = &p->threads[s];
    if (!t->samples) continue;
    uint32_t nfuncs = 0, stored = 0, busy_n = 0;
    for (uint32_t i = 0; i < p->nsamples; i++) {
      if (p->pool[i].slot != s) continue;
      stored++;
      busy_n += (uint32_t)count_sample(p, &p->pool[i], funcs, &nfuncs);
    }
    // Percentages are over the stored samples (all of them unless the pool overflowed).
    const uint32_t busy = pct(busy_n, stored);
    if (busy < 5 && strcmp(t->name, "Frame Submission") != 0) continue;
    // order of the funcs by count (descending), stable for equal counts
    uint32_t order[STALL_PROFILE_MAX_FUNCS];
    for (uint32_t i = 0; i < nfuncs; i++) order[i] = i;
    for (uint32_t i = 1; i < nfuncs; i++) {
      uint32_t v = order[i], j = i;
      while (j > 0 && funcs[order[j - 1]].count < funcs[v].count) {
        order[j] = order[j - 1];
        j--;
      }
      order[j] = v;
    }
    fprintf(out, "[stall-profile]   %s: busy %u%%:", t->name, busy);
    for (uint32_t i = 0; i < nfuncs && (int)i < top; i++) {
      const StallFunc *f = &funcs[order[i]];
      fprintf(out, "%s %s", i ? "," : "", f->leaf_name);
      if (f->waiting && f->guest_name) fprintf(out, " in %s", f->guest_name);
      fprintf(out, " %u%%", pct(f->count, stored));
    }
    fprintf(out, "\n");
  }
}

void stall_profile_report(const StallProfile *p, FILE *out, double stall_ms, int top) {
  stall_profile_report_gap(p, out, stall_ms, top, -1.0);
}
