// Host test for GnmPendingWrites (libSceGnmDriver/ps4_gnm_pending_writes.h): random frames of writes,
// commits, completions and queries, each query compared with the scan it replaces (the open
// command buffer's write list plus the lists of the command buffers in flight, as
// OverlapsPendingWrite did), and the steady state (the same ranges every frame) allocates no
// entries.
#include "ps4_gnm_pending_writes.h"

#include <stdio.h>

#include <deque>
#include <random>
#include <set>
#include <vector>

using namespace ps4gnm;

static int fails;
#define CHECK(c, ...)                                            \
    do {                                                         \
        if (!(c)) {                                              \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                        \
            fprintf(stderr, "\n");                               \
            if (++fails > 20) return 1;                          \
        }                                                        \
    } while (0)

// The scan GnmPendingWrites replaces.
struct Reference {
    using Range = GnmPendingWrites::Range;
    std::vector<Range> open;
    std::deque<std::pair<uint64_t, std::vector<Range>>> inflight;
    void Note(uint64_t a, uint64_t n, uint64_t epoch) {
        for (Range& r : open)
            if (r.addr == a && r.size == n) {
                r.epoch = epoch;
                return;
            }
        open.push_back({a, n, epoch});
    }
    void Commit(uint64_t seq) {
        if (!open.empty()) inflight.push_back({seq, open});
        open.clear();
    }
    void Prune(uint64_t done) {
        while (!inflight.empty() && inflight.front().first <= done) inflight.pop_front();
    }
    // the distinct ranges with a pending write
    size_t Distinct() const {
        std::set<std::pair<uint64_t, uint64_t>> d;
        for (const Range& r : open) d.insert({r.addr, r.size});
        for (auto& w : inflight)
            for (const Range& r : w.second) d.insert({r.addr, r.size});
        return d.size();
    }
    bool Overlaps(uint64_t a, uint64_t n, Range* hit) const {
        bool any = false;
        auto check = [&](const Range& r) {
            if (r.addr < a + n && a < r.addr + r.size) {
                if (!any || r.epoch > hit->epoch) *hit = r;
                any = true;
            }
        };
        for (const Range& r : open) check(r);
        for (auto& w : inflight)
            for (const Range& r : w.second) check(r);
        return any;
    }
};

// One run: keep_idle is GnmPendingWrites' (a low one makes Prune compact often, the checks running
// across it).
static int Run(size_t keep_idle) {
    std::mt19937_64 rng(12345);
    // a pool of ranges: most recur every frame (render targets), some are one-off
    std::vector<std::pair<uint64_t, uint64_t>> pool;
    for (int i = 0; i < 300; ++i) {
        const uint64_t a = 0x1900000000ull + (rng() % 4096) * 0x10000 + (rng() % 4) * 0x100;
        pool.push_back({a, 0x100 + (rng() % 64) * 0x1000});
    }
    GnmPendingWrites w(keep_idle);
    Reference ref;
    uint64_t epoch = 0, seq = 0, done = 0, queries = 0, hits = 0;
    for (int frame = 0; frame < 400; ++frame) {
        for (int cb = 0; cb < 12; ++cb) {
            const int nw = (int)(rng() % 20);
            for (int k = 0; k < nw; ++k) {
                uint64_t a, n;
                const uint64_t edge = 0x1900000000ull + ((rng() % 64) << 20); // a bucket boundary
                if (rng() % 6 == 0) { // through one byte at a bucket boundary: each end of a range
                    switch (rng() % 4) {
                    case 0: a = edge - 1, n = 1; break;         // the last byte below it
                    case 1: a = edge, n = 1; break;             // the first byte above it
                    case 2: a = edge - 1, n = 2; break;         // one byte on each side
                    default: a = edge - 0x800, n = 0x801; break; // ending one byte above it
                    }
                } else if (rng() % 300 == 0) { // wider than the buckets (GnmPendingWrites' wide_ list)
                    a = 0x1800000000ull + (rng() % 0x100000000ull);
                    n = (64ull << 20) + rng() % (128ull << 20);
                } else if (rng() % 10) {
                    std::tie(a, n) = pool[rng() % pool.size()];
                } else {
                    a = 0x1800000000ull + (rng() % 1000000) * 0x100;
                    n = 0x40 + rng() % 0x8000;
                }
                ++epoch;
                w.Note(a, n, epoch);
                ref.Note(a, n, epoch);
            }
            for (int q = 0; q < 30; ++q) {
                uint64_t a = rng() % 3 ? pool[rng() % pool.size()].first + (rng() % 0x2000)
                                       : 0x1800000000ull + (rng() % 0x200000000ull);
                uint64_t n = 1 + rng() % 0x40000;
                if (q % 5 == 1) { // one byte (or two) at a bucket boundary, where the edge writes are
                    const uint64_t edge = 0x1900000000ull + ((rng() % 64) << 20);
                    switch (rng() % 4) {
                    case 0: a = edge - 1, n = 1; break;
                    case 1: a = edge, n = 1; break;
                    case 2: a = edge - 1, n = 2; break;
                    default: a = edge, n = 2; break;
                    }
                } else if (q % 17 == 5) { // wider than the buckets: the walk of every pending entry
                    a = 0x1800000000ull + (rng() % 0x200000000ull);
                    n = (64ull << 20) + rng() % (512ull << 20);
                } else if (q % 3 == 0) { // exactly at a range's ends: [end, ...) or [..., start)
                    const auto& [ra, rn] = pool[rng() % pool.size()];
                    n = 1 + rng() % 0x100;
                    a = q % 2 ? ra + rn : ra - n;
                }
                GnmPendingWrites::Range h1, h2;
                const bool o1 = w.Overlaps(a, n, &h1), o2 = ref.Overlaps(a, n, &h2);
                ++queries;
                hits += o2;
                CHECK(o1 == o2, "frame %d cb %d: overlap of 0x%llx+0x%llx: %d, the scan says %d", frame, cb,
                      (unsigned long long)a, (unsigned long long)n, o1, o2);
                if (o1 && o2)
                    CHECK(h1.epoch == h2.epoch && h1.addr == h2.addr && h1.size == h2.size,
                          "frame %d cb %d: latest overlapping write epoch %llu (0x%llx+0x%llx), the scan's %llu "
                          "(0x%llx+0x%llx)",
                          frame, cb, (unsigned long long)h1.epoch, (unsigned long long)h1.addr,
                          (unsigned long long)h1.size, (unsigned long long)h2.epoch, (unsigned long long)h2.addr,
                          (unsigned long long)h2.size);
            }
            if (rng() % 5) { // a commit (otherwise the open command buffer goes on recording)
                ++seq;
                w.Commit(seq);
                ref.Commit(seq);
            }
            // completions lag by 0-6 seqs, sometimes all at once (a drain)
            const uint64_t lag = rng() % 8 == 0 ? 0 : rng() % 7;
            if (seq > lag && seq - lag > done) {
                done = seq - lag;
                w.Prune(done);
                ref.Prune(done);
                // one entry per pending range (none lost, none doubled, also across Compact)
                CHECK(w.Size() == ref.Distinct(), "frame %d: %zu pending entries, %zu pending ranges", frame, w.Size(),
                      ref.Distinct());
            }
        }
    }
    CHECK(hits > queries / 40 && hits < queries, "the queries hit %llu of %llu: not a test of both answers",
          (unsigned long long)hits, (unsigned long long)queries);
    // a drain: everything committed completed (the open command buffer's writes stay pending)
    ++seq;
    w.Commit(seq);
    ref.Commit(seq);
    w.Prune(seq);
    ref.Prune(seq);
    GnmPendingWrites::Range h;
    CHECK(!w.Overlaps(0, UINT64_MAX / 2, &h) && !ref.Overlaps(0, UINT64_MAX / 2, &h) && w.Size() == 0,
          "after a drain: %zu pending", w.Size());
    // steady state: frames writing only ranges written before keep the same entries
    const size_t before = w.Entries();
    for (int frame = 0; frame < 50; ++frame)
        for (int cb = 0; cb < 12; ++cb) {
            for (auto& [a, n] : pool) w.Note(a, n, ++epoch);
            w.Commit(++seq);
            w.Prune(seq - 3);
        }
    if (keep_idle == GnmPendingWrites::kKeepIdle) // (a low keep_idle drops the idle entries at the drain)
        CHECK(w.Entries() == before, "the same ranges every frame: %zu entries, %zu before", w.Entries(), before);
    // 3 seqs in flight wrote the same ranges: each is one pending entry (the scan had 3 records)
    CHECK(w.Size() == pool.size(), "3 seqs in flight: %zu pending, want %zu", w.Size(), pool.size());
    if (keep_idle < GnmPendingWrites::kKeepIdle)
        CHECK(w.Compactions() > 10, "keep_idle %zu: Compact ran %llu times", keep_idle,
              (unsigned long long)w.Compactions());
    if (fails) return 1;
    printf("gnm_pending_writes_test: keep_idle %zu: %llu queries, %llu overlapping, %llu compactions\n", keep_idle,
           (unsigned long long)queries, (unsigned long long)hits, (unsigned long long)w.Compactions());
    return 0;
}

int main() {
    if (Run(GnmPendingWrites::kKeepIdle) || Run(8)) return 1;
    printf("gnm_pending_writes_test: PASS\n");
    return 0;
}
