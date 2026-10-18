#include "ps4_gnm_pipeline_archive.h"
#import <Foundation/Foundation.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <sys/sysctl.h>
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

// Header of the index file: the archive is valid only for the OS build and GPU it was written on.
// Layout (bytes): magic 0..7, version 8..11, reserved 12..15, kern.osversion 16..79,
// device name 80..207, registryID 208..215. Keys (8 bytes each) follow.
struct IndexHeader {
    char magic[8];
    uint32_t version;
    uint32_t reserved;
    char os[64];
    char device[128];
    uint64_t registry_id;
};
static_assert(sizeof(IndexHeader) == 216, "index header layout");
constexpr uint32_t kIndexVersion = 1;

IndexHeader CurrentHeader(id<MTLDevice> dev) {
    IndexHeader h;
    memset(&h, 0, sizeof(h));
    memcpy(h.magic, "PS4PSOAR", 8);
    h.version = kIndexVersion;
    size_t n = sizeof(h.os) - 1;
    if (sysctlbyname("kern.osversion", h.os, &n, nullptr, 0) != 0) h.os[0] = 0;
    strncpy(h.device, dev.name.UTF8String ? dev.name.UTF8String : "", sizeof(h.device) - 1);
    h.registry_id = dev.registryID;
    return h;
}

bool WriteHeader(const IndexHeader& h) {
    FILE* f = fopen(A.index_path.c_str(), "wb");
    if (!f) return false;
    bool ok = fwrite(&h, sizeof(h), 1, f) == 1;
    ok = fclose(f) == 0 && ok;
    return ok;
}

// Deletes temporary archives left by a save that was cut short (quit timeout).
void RemoveStaleTemps(const std::string& dir) {
    DIR* d = opendir(dir.c_str());
    if (!d) return;
    const char* prefix = "pipelines.metalar.tmp";
    while (dirent* de = readdir(d))
        if (strncmp(de->d_name, prefix, strlen(prefix)) == 0) unlink((dir + "/" + de->d_name).c_str());
    closedir(d);
}

id<MTLBinaryArchive> NewArchive(id<MTLDevice> dev, NSURL* url, NSError** err) {
    MTLBinaryArchiveDescriptor* ad = [MTLBinaryArchiveDescriptor new];
    ad.url = url; // nil: a new, empty archive
    return [dev newBinaryArchiveWithDescriptor:ad error:err];
}

void DropFiles() {
    unlink(A.path.c_str());
    unlink(A.index_path.c_str());
}

// True if the index has this OS/GPU's header; then fills A.keys (a trailing partial key is ignored).
bool LoadIndex(const IndexHeader& cur) {
    FILE* f = fopen(A.index_path.c_str(), "rb");
    if (!f) return false;
    IndexHeader h;
    if (fread(&h, sizeof(h), 1, f) != 1 || memcmp(&h, &cur, sizeof(h)) != 0) {
        fclose(f);
        return false;
    }
    uint64_t k;
    while (fread(&k, sizeof(k), 1, f) == 1) A.keys.insert(k);
    fclose(f);
    return true;
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
        fprintf(stderr, "[gnm-pso-archive] rename to %s failed (errno %d)\n", A.path.c_str(), errno);
        unlink(tmp.UTF8String);
        return false;
    }
    std::vector<uint64_t> saved;
    {
        std::lock_guard<std::mutex> lk(A.mu);
        saved.swap(A.unsaved);
    }
    FILE* f = fopen(A.index_path.c_str(), "ab");
    bool index_ok = f != nullptr;
    if (f) {
        index_ok = fwrite(saved.data(), sizeof(uint64_t), saved.size(), f) == saved.size();
        index_ok = fclose(f) == 0 && index_ok;
    }
    if (!index_ok) {
        // The archive holds these pipelines but the index does not know them: they are archived
        // again on their next build (adding an existing pipeline is harmless).
        fprintf(stderr, "[gnm-pso-archive] writing %s failed (errno %d)\n", A.index_path.c_str(), errno);
        A.dirty = false;
        return false;
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
    const char* off = getenv("PS4_GNM_NO_PSO_ARCHIVE");
    if (off && strcmp(off, "1") == 0) return false;
    A.path = dir + "/pipelines.metalar";
    A.index_path = dir + "/pipelines_archived.bin";
    A.q = dispatch_queue_create("ps4.gnm.pso_archive", DISPATCH_QUEUE_SERIAL);
    struct stat st;
    if (stat(A.path.c_str(), &st) == 0 && (uint64_t)st.st_size > budget_bytes) {
        fprintf(stderr, "[gnm-pso-archive] %s is %lld MB (budget %llu MB): starting a new archive\n", A.path.c_str(),
                (long long)(st.st_size >> 20), (unsigned long long)(budget_bytes >> 20));
        DropFiles();
    }
    RemoveStaleTemps(dir);
    const IndexHeader cur = CurrentHeader(dev);
    NSError* e = nil;
    if (stat(A.path.c_str(), &st) == 0) {
        if (!LoadIndex(cur)) {
            fprintf(stderr, "[gnm-pso-archive] %s has no index for this OS/GPU: starting a new archive\n",
                    A.path.c_str());
            A.keys.clear();
            DropFiles();
        } else {
            A.archive = NewArchive(dev, [NSURL fileURLWithPath:@(A.path.c_str())], &e);
            if (!A.archive) {
                fprintf(stderr, "[gnm-pso-archive] cannot open %s (%s): starting a new archive\n", A.path.c_str(),
                        e.localizedDescription.UTF8String);
                A.keys.clear();
                DropFiles();
            }
        }
    }
    if (!A.archive) {
        A.archive = NewArchive(dev, nil, &e);
        if (!A.archive) {
            fprintf(stderr, "[gnm-pso-archive] disabled: %s\n", e.localizedDescription.UTF8String);
            return false;
        }
        if (!WriteHeader(cur)) {
            fprintf(stderr, "[gnm-pso-archive] cannot write %s (errno %d): disabled\n", A.index_path.c_str(), errno);
            A.archive = nil;
            return false;
        }
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
