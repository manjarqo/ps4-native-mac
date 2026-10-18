#include "ps4_gnm_pipeline_archive.h"
#import <Foundation/Foundation.h>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_set>
#include <vector>

namespace ps4gnm_pso_archive {
namespace {
struct ArchiveState {
    id<MTLBinaryArchive> archive = nil;
    NSArray<id<MTLBinaryArchive>>* list = nil;
    std::string path, index_path;
    dispatch_queue_t q = nil;          // additions and saves, in order
    dispatch_source_t timer = nil;     // periodic save
    std::mutex mu;                     // keys, unsaved
    std::unordered_set<uint64_t> keys; // in the archive or queued for it
    std::vector<uint64_t> unsaved;     // added since the last save (appended to the index then)
    bool dirty = false;                // q only
};
ArchiveState A;

id<MTLBinaryArchive> NewArchive(id<MTLDevice> dev, NSURL* url, NSError** err) {
    MTLBinaryArchiveDescriptor* ad = [MTLBinaryArchiveDescriptor new];
    ad.url = url; // nil: a new, empty archive
    return [dev newBinaryArchiveWithDescriptor:ad error:err];
}

void DropFiles() {
    unlink(A.path.c_str());
    unlink(A.index_path.c_str());
}

void LoadIndex() {
    FILE* f = fopen(A.index_path.c_str(), "rb");
    if (!f) return;
    uint64_t k;
    while (fread(&k, sizeof(k), 1, f) == 1) A.keys.insert(k);
    fclose(f);
}

// Runs on A.q.
bool SaveOnQueue() {
    if (!A.dirty) return true;
    NSString* tmp = [NSString stringWithFormat:@"%s.tmp%d", A.path.c_str(), (int)getpid()];
    NSError* e = nil;
    if (![A.archive serializeToURL:[NSURL fileURLWithPath:tmp] error:&e]) {
        fprintf(stderr, "[gnm-pso-archive] save failed: %s\n", e.localizedDescription.UTF8String);
        unlink(tmp.UTF8String);
        return false;
    }
    if (rename(tmp.UTF8String, A.path.c_str()) != 0) {
        unlink(tmp.UTF8String);
        return false;
    }
    std::vector<uint64_t> saved;
    {
        std::lock_guard<std::mutex> lk(A.mu);
        saved.swap(A.unsaved);
    }
    if (FILE* f = fopen(A.index_path.c_str(), "ab")) {
        fwrite(saved.data(), sizeof(uint64_t), saved.size(), f);
        fclose(f);
    }
    A.dirty = false;
    return true;
}

template <class Desc, class AddFn>
void AddImpl(uint64_t key, Desc* d, AddFn add) {
    if (!A.archive || !d) return;
    {
        std::lock_guard<std::mutex> lk(A.mu);
        if (!A.keys.insert(key).second) return;
    }
    Desc* copy = [d copy];
    dispatch_async(A.q, ^{
        NSError* e = nil;
        if (add(copy, &e)) {
            std::lock_guard<std::mutex> lk(A.mu);
            A.unsaved.push_back(key);
            A.dirty = true;
        } else {
            fprintf(stderr, "[gnm-pso-archive] add failed: %s\n", e.localizedDescription.UTF8String);
            std::lock_guard<std::mutex> lk(A.mu);
            A.keys.erase(key);
        }
    });
}
} // namespace

bool Open(id<MTLDevice> dev, const std::string& dir, uint64_t budget_bytes) {
    if (getenv("PS4_GNM_NO_PSO_ARCHIVE")) return false;
    A.path = dir + "/pipelines.metalar";
    A.index_path = dir + "/pipelines_archived.bin";
    A.q = dispatch_queue_create("ps4.gnm.pso_archive", DISPATCH_QUEUE_SERIAL);
    struct stat st;
    if (stat(A.path.c_str(), &st) == 0 && (uint64_t)st.st_size > budget_bytes) {
        fprintf(stderr, "[gnm-pso-archive] %s is %lld MB (budget %llu MB): starting a new archive\n", A.path.c_str(),
                (long long)(st.st_size >> 20), (unsigned long long)(budget_bytes >> 20));
        DropFiles();
    }
    NSError* e = nil;
    if (stat(A.path.c_str(), &st) == 0) {
        A.archive = NewArchive(dev, [NSURL fileURLWithPath:@(A.path.c_str())], &e);
        if (A.archive) {
            LoadIndex();
        } else {
            fprintf(stderr, "[gnm-pso-archive] cannot open %s (%s): starting a new archive\n", A.path.c_str(),
                    e.localizedDescription.UTF8String);
            DropFiles();
        }
    } else {
        unlink(A.index_path.c_str()); // an index without its archive describes nothing
    }
    if (!A.archive) A.archive = NewArchive(dev, nil, &e);
    if (!A.archive) {
        fprintf(stderr, "[gnm-pso-archive] disabled: %s\n", e.localizedDescription.UTF8String);
        return false;
    }
    A.list = @[ A.archive ];
    fprintf(stderr, "[gnm-pso-archive] %s: %zu pipelines\n", A.path.c_str(), A.keys.size());
    return true;
}

bool Enabled() {
    return A.archive != nil;
}

void Attach(MTLRenderPipelineDescriptor* d) {
    if (A.list) d.binaryArchives = A.list;
}

void Attach(MTLComputePipelineDescriptor* d) {
    if (A.list) d.binaryArchives = A.list;
}

bool Contains(uint64_t key) {
    std::lock_guard<std::mutex> lk(A.mu);
    return A.keys.count(key) != 0;
}

void Add(uint64_t key, MTLRenderPipelineDescriptor* d) {
    AddImpl(key, d, ^bool(MTLRenderPipelineDescriptor* c, NSError** e) {
        return [A.archive addRenderPipelineFunctionsWithDescriptor:c error:e];
    });
}

void Add(uint64_t key, MTLComputePipelineDescriptor* d) {
    AddImpl(key, d, ^bool(MTLComputePipelineDescriptor* c, NSError** e) {
        return [A.archive addComputePipelineFunctionsWithDescriptor:c error:e];
    });
}

bool SaveNow(double timeout_s) {
    if (!A.archive) return true;
    __block bool ok = false;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(A.q, ^{
        ok = SaveOnQueue();
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout_s * NSEC_PER_SEC))) != 0)
        return false;
    return ok;
}

void StartPeriodicSave(double period_s) {
    if (!A.archive || A.timer) return;
    A.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, A.q);
    const uint64_t ns = (uint64_t)(period_s * NSEC_PER_SEC);
    dispatch_source_set_timer(A.timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)ns), ns, NSEC_PER_SEC);
    dispatch_source_set_event_handler(A.timer, ^{
        SaveOnQueue();
    });
    dispatch_resume(A.timer);
}
} // namespace ps4gnm_pso_archive

extern "C" void ps4_gnm_pso_archive_save_for_quit(double timeout_s) {
    ps4gnm_pso_archive::SaveNow(timeout_s);
}
