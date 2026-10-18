#include "ps4_gnm_pipeline_archive.h"
#import <Foundation/Foundation.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <atomic>
#include <dirent.h>
#include <sys/sysctl.h>
#include <mutex>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_set>
#include <vector>

namespace ps4gnm_pso_archive {
namespace {
// Metal fails to serialize an archive that was loaded from a file and then got pipelines added
// ("expecting 'fragment' stage in pipeline no. N", seen with the game's pipelines), while a new
// archive always serializes. So archive files are never added to after they are written: each
// save writes the pipelines added since the previous save into a new file, pipelines-<n>.metalar,
// and further additions go into a new archive. That also keeps the save at quit short (it only
// writes the additions since the last save; at most kSaveBatch of them).
struct ArchiveState {
    id<MTLDevice> dev = nil;
    std::atomic<bool> enabled{false};
    id<MTLBinaryArchive> archive = nil;         // additions since the last save (written to `path`); q only
    NSArray<id<MTLBinaryArchive>>* list = nil; // all archives (files read and written, then `archive`); mu
    std::string dir, path, index_path;          // path: q only
    int next_file = 0;                          // q only
    dispatch_queue_t q = nil;          // additions and saves, in order
    dispatch_source_t timer = nil;     // periodic save
    std::mutex mu;                     // keys, unsaved, list
    std::unordered_set<uint64_t> keys; // in the archive or queued for it
    std::vector<uint64_t> unsaved;     // added since the last save (appended to the index then)
    bool dirty = false;                // q only
};
ArchiveState A;

// Header of the index file: the archive is valid only for the OS build and GPU it was written on.
// Layout (bytes): magic 0..7, version 8..11, reserved 12..15, kern.osversion 16..79,
// device name 80..207, registryID 208..215. Keys (8 bytes each) follow; they cover all the
// pipelines-<n>.metalar files.
struct IndexHeader {
    char magic[8];
    uint32_t version;
    uint32_t reserved;
    char os[64];
    char device[128];
    uint64_t registry_id;
};
static_assert(sizeof(IndexHeader) == 216, "index header layout");
constexpr uint32_t kIndexVersion = 2; // 1: a single pipelines.metalar
// More archive files than this: everything is deleted and a new archive started.
constexpr int kMaxFiles = 128;
// A save starts as soon as this many pipelines were added since the last one.
constexpr size_t kSaveBatch = 64;

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

// Number n of a pipelines-<n>.metalar file name, or -1.
int FileNumber(const char* name) {
    int n = -1, end = 0;
    if (sscanf(name, "pipelines-%d.metalar%n", &n, &end) == 1 && name[end] == 0 && n >= 0) return n;
    return -1;
}

// Deletes temporary archives left by a save that was cut short (quit timeout).
void RemoveStaleTemps(const std::string& dir) {
    DIR* d = opendir(dir.c_str());
    if (!d) return;
    while (dirent* de = readdir(d))
        if (strncmp(de->d_name, "pipelines", 9) == 0 && strstr(de->d_name, ".metalar.tmp"))
            unlink((dir + "/" + de->d_name).c_str());
    closedir(d);
}

// Numbers of the pipelines-<n>.metalar files, sorted.
std::vector<int> ListFiles(const std::string& dir) {
    std::vector<int> v;
    if (DIR* d = opendir(dir.c_str())) {
        while (dirent* de = readdir(d))
            if (const int n = FileNumber(de->d_name); n >= 0) v.push_back(n);
        closedir(d);
    }
    std::sort(v.begin(), v.end());
    return v;
}

std::string FilePath(int n) {
    return A.dir + "/pipelines-" + std::to_string(n) + ".metalar";
}

id<MTLBinaryArchive> NewArchive(id<MTLDevice> dev, NSURL* url, NSError** err) {
    MTLBinaryArchiveDescriptor* ad = [MTLBinaryArchiveDescriptor new];
    ad.url = url; // nil: a new, empty archive
    return [dev newBinaryArchiveWithDescriptor:ad error:err];
}

// Deletes every archive file (including the single file of index version 1) and the index.
void DropFiles() {
    for (int n : ListFiles(A.dir)) unlink(FilePath(n).c_str());
    unlink((A.dir + "/pipelines.metalar").c_str());
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
        // Retrying the same archive would fail again and lose every later addition, so its
        // pipelines are given up (archived again in a later session) and a new archive started.
        fprintf(stderr, "[gnm-pso-archive] save failed, %zu pipelines dropped: %s\n", A.unsaved.size(),
                e.localizedDescription.UTF8String);
        unlink(tmp.UTF8String);
        id<MTLBinaryArchive> next = NewArchive(A.dev, nil, &e);
        std::lock_guard<std::mutex> lk(A.mu);
        for (uint64_t k : A.unsaved) A.keys.erase(k);
        A.unsaved.clear();
        A.dirty = false;
        if (next) {
            A.archive = next;
            A.list = [A.list arrayByAddingObject:next];
        } else {
            A.enabled = false;
        }
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
    fprintf(stderr, "[gnm-pso-archive] saved %s (%zu new pipelines)\n", A.path.c_str(), saved.size());
    // The written archive stays in the list for lookups; later additions go into a new one.
    id<MTLBinaryArchive> next = NewArchive(A.dev, nil, &e);
    if (!next) {
        fprintf(stderr, "[gnm-pso-archive] no new archive (%s): later additions are not saved\n",
                e.localizedDescription.UTF8String);
        A.enabled = false;
        return true;
    }
    A.archive = next;
    A.path = FilePath(A.next_file++);
    std::lock_guard<std::mutex> lk(A.mu);
    A.list = [A.list arrayByAddingObject:next];
    return true;
}

template <class Desc, class AddFn>
void AddImpl(uint64_t key, Desc* d, AddFn add) {
    if (!A.enabled || !d) return;
    {
        std::lock_guard<std::mutex> lk(A.mu);
        if (!A.keys.insert(key).second) return;
    }
    Desc* copy = [d copy];
    dispatch_async(A.q, ^{
        NSError* e = nil;
        if (!A.enabled) return;
        if (add(copy, &e)) {
            bool full;
            {
                std::lock_guard<std::mutex> lk(A.mu);
                A.unsaved.push_back(key);
                full = A.unsaved.size() >= kSaveBatch;
            }
            A.dirty = true;
            if (full) SaveOnQueue();
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
    A.dir = dir;
    A.index_path = dir + "/pipelines_archived.bin";
    A.q = dispatch_queue_create("ps4.gnm.pso_archive", DISPATCH_QUEUE_SERIAL);
    RemoveStaleTemps(dir);
    std::vector<int> files = ListFiles(dir);
    uint64_t total = 0;
    struct stat st;
    for (int n : files)
        if (stat(FilePath(n).c_str(), &st) == 0) total += (uint64_t)st.st_size;
    if (total > budget_bytes || (int)files.size() > kMaxFiles) {
        fprintf(stderr, "[gnm-pso-archive] %zu archive files, %llu MB (budget %llu MB, at most %d files): starting a new archive\n",
                files.size(), (unsigned long long)(total >> 20), (unsigned long long)(budget_bytes >> 20), kMaxFiles);
        DropFiles();
        files.clear();
    }
    const IndexHeader cur = CurrentHeader(dev);
    NSError* e = nil;
    NSMutableArray<id<MTLBinaryArchive>>* list = [NSMutableArray array];
    if (!LoadIndex(cur)) {
        if (!files.empty() || stat(A.index_path.c_str(), &st) == 0)
            fprintf(stderr, "[gnm-pso-archive] %s is missing or not for this OS/GPU: starting a new archive\n",
                    A.index_path.c_str());
        A.keys.clear();
        DropFiles();
        files.clear();
        if (!WriteHeader(cur)) {
            fprintf(stderr, "[gnm-pso-archive] cannot write %s (errno %d): disabled\n", A.index_path.c_str(), errno);
            return false;
        }
    }
    for (int n : files) {
        id<MTLBinaryArchive> a = NewArchive(dev, [NSURL fileURLWithPath:@(FilePath(n).c_str())], &e);
        if (!a) {
            fprintf(stderr, "[gnm-pso-archive] cannot open %s (%s): starting a new archive\n", FilePath(n).c_str(),
                    e.localizedDescription.UTF8String);
            [list removeAllObjects];
            A.keys.clear();
            DropFiles();
            files.clear();
            if (!WriteHeader(cur)) {
                fprintf(stderr, "[gnm-pso-archive] cannot write %s (errno %d): disabled\n", A.index_path.c_str(), errno);
                return false;
            }
            break;
        }
        [list addObject:a];
    }
    A.dev = dev;
    A.archive = NewArchive(dev, nil, &e);
    if (!A.archive) {
        fprintf(stderr, "[gnm-pso-archive] disabled: %s\n", e.localizedDescription.UTF8String);
        return false;
    }
    A.next_file = files.empty() ? 0 : files.back() + 1;
    A.path = FilePath(A.next_file++);
    [list addObject:A.archive];
    A.list = list;
    A.enabled = true;
    fprintf(stderr, "[gnm-pso-archive] %s: %zu pipelines in %zu files\n", dir.c_str(), A.keys.size(), files.size());
    return true;
}

bool Enabled() {
    return A.enabled;
}

namespace {
NSArray<id<MTLBinaryArchive>>* List() {
    std::lock_guard<std::mutex> lk(A.mu);
    return A.list;
}
} // namespace

void Attach(MTLRenderPipelineDescriptor* d) {
    if (NSArray<id<MTLBinaryArchive>>* l = List()) d.binaryArchives = l;
}

void Attach(MTLComputePipelineDescriptor* d) {
    if (NSArray<id<MTLBinaryArchive>>* l = List()) d.binaryArchives = l;
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
    if (!A.q) return true;
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
    if (!A.enabled || A.timer) return;
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
    if (!ps4gnm_pso_archive::Enabled()) return;
    if (!ps4gnm_pso_archive::SaveNow(timeout_s))
        fprintf(stderr, "[gnm-pso-archive] quit: save failed or did not finish in %.1f s\n", timeout_s);
}
