// Host test of the pipeline archive (ps4_gnm_pipeline_archive.mm) on the real Metal device.
// Runs as separate processes: write → read must find both pipelines in the archive without
// compiling (MTLPipelineOptionFailOnBinaryArchiveMiss); append adds a pipeline in a later session
// (its own file) and read2 must find all three; budget, corrupt and stale start anew. In a fresh
// directory, add<k> (k = 0..9) writes one file with pipeline key 100+k; evict (run with
// PS4_GNM_PSO_ARCHIVE_MAX_FILES) must delete the oldest files and their keys and keep the newest
// one served from the archive, evicted checks that the rewritten index kept exactly that, and
// budgetstop (1 byte budget) must stop accepting pipelines once a file passes the budget.
// hold opens the archive (owning it) and sleeps; lookup, run meanwhile on the same directory after
// write, must open lookup only, find the archived pipelines, and adding and saving must change no
// file in the directory.
#import <Metal/Metal.h>
#include "ps4_gnm_pipeline_archive.h"
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <map>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

// The nonce (one per test-suite run, passed by the driver) is baked into the shader code so that
// pipeline caches left by earlier runs cannot satisfy this run.
static std::string ShaderSource(const std::string& nonce) {
    return "#include <metal_stdlib>\nusing namespace metal;\n"
           "constant float kNonce = " + nonce + ".0;\n"
           "vertex float4 vmain(uint vid [[vertex_id]]) { return float4(float(vid & 1), float(vid >> 1), 0, 1); }\n"
           "fragment float4 fmain() { return float4(1, 0.5, 0.25, kNonce); }\n"
           "kernel void cmain(device float* o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = float(i) * 2.0 + kNonce; }\n";
}

// Number of pipelines-<n>.metalar files in dir.
static int ArchiveFiles(const std::string& dir) {
    int n = 0;
    if (DIR* d = opendir(dir.c_str())) {
        while (dirent* de = readdir(d)) {
            const size_t l = strlen(de->d_name);
            if (strncmp(de->d_name, "pipelines-", 10) == 0 && l > 8 && strcmp(de->d_name + l - 8, ".metalar") == 0) ++n;
        }
        closedir(d);
    }
    return n;
}

// Name -> size, modification time and contents of every file in dir.
static std::map<std::string, std::string> Snapshot(const std::string& dir) {
    std::map<std::string, std::string> m;
    if (DIR* d = opendir(dir.c_str())) {
        while (dirent* de = readdir(d)) {
            if (de->d_name[0] == '.') continue;
            const std::string p = dir + "/" + de->d_name;
            struct stat st;
            if (stat(p.c_str(), &st) != 0) continue;
            std::string v = std::to_string((long long)st.st_size) + ":" + std::to_string((long long)st.st_mtimespec.tv_sec) +
                            "." + std::to_string((long long)st.st_mtimespec.tv_nsec) + ":";
            if (FILE* f = fopen(p.c_str(), "rb")) {
                std::vector<char> buf(1 << 16);
                size_t n;
                while ((n = fread(buf.data(), 1, buf.size(), f)) > 0) v.append(buf.data(), n);
                fclose(f);
            }
            m[de->d_name] = v;
        }
        closedir(d);
    }
    return m;
}

static int Fail(const char* what) {
    printf("pso_archive_test: FAIL (%s)\n", what);
    return 1;
}

int main(int argc, char** argv) {
    if (argc != 4)
        return Fail("usage: pso_archive_test <write|read|append|read2|budget|corrupt|stale|add<k>|evict|evicted|budgetstop|hold|lookup> <dir> <nonce>");
    const std::string mode = argv[1], dir = argv[2], nonce = argv[3];
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError* e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(ShaderSource(nonce).c_str()) options:nil error:&e];
        if (!lib) return Fail("library");
        MTLRenderPipelineDescriptor* rd = [MTLRenderPipelineDescriptor new];
        rd.vertexFunction = [lib newFunctionWithName:@"vmain"];
        rd.fragmentFunction = [lib newFunctionWithName:@"fmain"];
        rd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        MTLComputePipelineDescriptor* cd = [MTLComputePipelineDescriptor new];
        cd.computeFunction = [lib newFunctionWithName:@"cmain"];
        // The pipeline a later session adds (append, read2): another fragment function.
        id<MTLLibrary> lib3 = [dev newLibraryWithSource:@(ShaderSource(nonce + "3").c_str()) options:nil error:&e];
        if (!lib3) return Fail("library 3");
        MTLRenderPipelineDescriptor* rd3 = [rd copy];
        rd3.fragmentFunction = [lib3 newFunctionWithName:@"fmain"];
        const std::string archive = dir + "/pipelines-0.metalar";

        if (mode == "corrupt") {
            FILE* f = fopen(archive.c_str(), "wb");
            fputs("not an archive", f);
            fclose(f);
        }
        long long old_index_size = 0;
        if (mode == "stale") {
            // Pretend the archive was written on another OS build: flip a byte of the header's
            // kern.osversion field (bytes 16..79 of the index).
            const std::string idx = dir + "/pipelines_archived.bin";
            struct stat ist;
            if (stat(idx.c_str(), &ist) != 0) return Fail("stale: no index to patch");
            old_index_size = ist.st_size;
            FILE* f = fopen(idx.c_str(), "r+b");
            if (!f) return Fail("stale: open index");
            unsigned char b = 0;
            fseek(f, 16, SEEK_SET);
            if (fread(&b, 1, 1, f) != 1) return Fail("stale: read index");
            b ^= 0x5a;
            fseek(f, 16, SEEK_SET);
            fwrite(&b, 1, 1, f);
            fclose(f);
        }
        // Pipeline with key 100+k (add<k>, evict, evicted): its own fragment function.
        auto numbered = [&](int k) {
            id<MTLLibrary> l = [dev newLibraryWithSource:@(ShaderSource(nonce + "5" + std::to_string(k)).c_str())
                                                 options:nil
                                                   error:nil];
            MTLRenderPipelineDescriptor* d = [rd copy];
            d.fragmentFunction = [l newFunctionWithName:@"fmain"];
            return d;
        };
        const uint64_t budget = mode == "budget" || mode == "budgetstop" ? 1 : (64ull << 20);
        const std::map<std::string, std::string> before = Snapshot(dir);
        if (!ps4gnm_pso_archive::Open(dev, dir, budget)) return Fail("open");
        if (ps4gnm_pso_archive::LookupOnly() != (mode == "lookup")) return Fail("wrong lookup-only state");
        if (mode == "hold") {
            // the driver waits for this line, runs lookup, then kills this process
            printf("pso_archive_test: holding %s\n", dir.c_str());
            fflush(stdout);
            sleep(120);
            return Fail("hold: not killed");
        }
        if (mode.size() == 4 && mode.compare(0, 3, "add") == 0 && isdigit((unsigned char)mode[3])) {
            const int k = mode[3] - '0';
            MTLRenderPipelineDescriptor* d = numbered(k);
            ps4gnm_pso_archive::Attach(d);
            if (![dev newRenderPipelineStateWithDescriptor:d error:&e]) return Fail("add: render build");
            ps4gnm_pso_archive::Add(100 + k, d);
            if (!ps4gnm_pso_archive::SaveNow(30)) return Fail("add: save");
            if (ArchiveFiles(dir) != k + 1) return Fail("add: expected one more archive file");
        } else if (mode == "evict" || mode == "evicted") {
            // 6 files (add0..add5), cap 4: the oldest go until 3 (3/4 of the cap) are left.
            if (ArchiveFiles(dir) != 3) return Fail("evict: expected 3 archive files left");
            for (int k = 0; k < 6; ++k)
                if (ps4gnm_pso_archive::Contains(100 + k) != (k >= 3)) return Fail("evict: wrong keys kept");
            MTLRenderPipelineDescriptor* d = numbered(5);
            ps4gnm_pso_archive::Attach(d);
            if (![dev newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss
                                                reflection:nil error:&e])
                return Fail("evict: newest pipeline not served from the archive");
            // (a miss of an evicted pipeline cannot be checked: the system cache still has it)
            struct stat st;
            for (int k = 0; k < 6; ++k)
                if ((stat((dir + "/pipelines-" + std::to_string(k) + ".metalar").c_str(), &st) == 0) != (k >= 3))
                    return Fail("evict: wrong files kept");
        } else if (mode == "lookup") {
            if (Snapshot(dir) != before) return Fail("lookup: Open changed the directory");
            if (!ps4gnm_pso_archive::Contains(1) || !ps4gnm_pso_archive::Contains(2)) return Fail("lookup: keys not loaded");
            ps4gnm_pso_archive::Attach(rd);
            // only the file of the write session; no archive for additions
            if (rd.binaryArchives.count != 1) return Fail("lookup: wrong archives attached");
            if (![dev newRenderPipelineStateWithDescriptor:rd options:MTLPipelineOptionFailOnBinaryArchiveMiss
                                                reflection:nil error:&e])
                return Fail("lookup: archived pipeline not served from the archive");
            ps4gnm_pso_archive::Attach(rd3);
            if (![dev newRenderPipelineStateWithDescriptor:rd3 error:&e]) return Fail("lookup: render build");
            ps4gnm_pso_archive::Add(3, rd3);
            ps4gnm_pso_archive::Add(4, cd);
            if (ps4gnm_pso_archive::Contains(3) || ps4gnm_pso_archive::Contains(4)) return Fail("lookup: pipeline accepted");
            ps4gnm_pso_archive::StartPeriodicSave(0.05);
            if (!ps4gnm_pso_archive::SaveNow(30)) return Fail("lookup: save");
            usleep(200 * 1000);
            if (Snapshot(dir) != before) return Fail("lookup: adding or saving changed the directory");
        } else if (mode == "budgetstop") {
            ps4gnm_pso_archive::Attach(rd);
            if (![dev newRenderPipelineStateWithDescriptor:rd error:&e]) return Fail("budgetstop: render build");
            ps4gnm_pso_archive::Add(1, rd);
            if (!ps4gnm_pso_archive::SaveNow(30)) return Fail("budgetstop: save");
            if (ArchiveFiles(dir) != 1) return Fail("budgetstop: first file not written");
            ps4gnm_pso_archive::Add(2, cd);
            if (ps4gnm_pso_archive::Contains(2)) return Fail("budgetstop: pipeline accepted over the budget");
        } else if (mode == "write") {
            if (ps4gnm_pso_archive::Contains(1) || ps4gnm_pso_archive::Contains(2)) return Fail("fresh archive has keys");
            ps4gnm_pso_archive::Attach(rd);
            ps4gnm_pso_archive::Attach(cd);
            if (![dev newRenderPipelineStateWithDescriptor:rd error:&e]) return Fail("render build");
            if (![dev newComputePipelineStateWithDescriptor:cd options:MTLPipelineOptionNone reflection:nil error:&e])
                return Fail("compute build");
            ps4gnm_pso_archive::Add(1, rd);
            ps4gnm_pso_archive::Add(2, cd);
            if (!ps4gnm_pso_archive::SaveNow(30)) return Fail("save");
            struct stat st;
            if (ArchiveFiles(dir) != 1 || stat(archive.c_str(), &st) != 0 || st.st_size == 0) return Fail("archive file");
        } else if (mode == "append") {
            if (!ps4gnm_pso_archive::Contains(1) || !ps4gnm_pso_archive::Contains(2)) return Fail("append: index lost keys");
            if (ps4gnm_pso_archive::Contains(3)) return Fail("append: key 3 before adding it");
            ps4gnm_pso_archive::Attach(rd3);
            if (![dev newRenderPipelineStateWithDescriptor:rd3 error:&e]) return Fail("append: render build");
            ps4gnm_pso_archive::Add(3, rd3);
            if (!ps4gnm_pso_archive::SaveNow(30)) return Fail("append: save");
            if (ArchiveFiles(dir) != 2) return Fail("append: expected a second archive file");
        } else if (mode == "read" || mode == "read2") {
            if (!ps4gnm_pso_archive::Contains(1) || !ps4gnm_pso_archive::Contains(2)) return Fail("index lost keys");
            ps4gnm_pso_archive::Attach(rd);
            ps4gnm_pso_archive::Attach(cd);
            // FailOnBinaryArchiveMiss only has an effect with an archive attached (without one the
            // system cache or a fresh compile serves the pipeline), so check the attachment itself.
            // earlier sessions' files (1 after write, 2 after append) plus this session's archive
            const NSUInteger want = mode == "read" ? 2 : 3;
            if (rd.binaryArchives.count != want || cd.binaryArchives.count != want) return Fail("Attach did not set binaryArchives");
            // Negative control: a pipeline that was never archived must miss, which proves the
            // success below comes from the archive and not from an option that never fails.
            MTLRenderPipelineDescriptor* other = [rd copy];
            id<MTLLibrary> lib2 = [dev newLibraryWithSource:@(ShaderSource(nonce + "1").c_str()) options:nil error:&e];
            other.fragmentFunction = [lib2 newFunctionWithName:@"fmain"];
            if ([dev newRenderPipelineStateWithDescriptor:other options:MTLPipelineOptionFailOnBinaryArchiveMiss
                                               reflection:nil error:&e])
                return Fail("never-archived pipeline did not miss");
            if (mode == "read2") {
                if (!ps4gnm_pso_archive::Contains(3)) return Fail("read2: index lost key 3");
                ps4gnm_pso_archive::Attach(rd3);
                if (![dev newRenderPipelineStateWithDescriptor:rd3 options:MTLPipelineOptionFailOnBinaryArchiveMiss
                                                    reflection:nil error:&e])
                    return Fail("read2: pipeline of the later session not served from the archive");
            }
            if (![dev newRenderPipelineStateWithDescriptor:rd options:MTLPipelineOptionFailOnBinaryArchiveMiss
                                                reflection:nil error:&e])
                return Fail("render pipeline not served from the archive");
            if (![dev newComputePipelineStateWithDescriptor:cd options:MTLPipelineOptionFailOnBinaryArchiveMiss
                                                 reflection:nil error:&e])
                return Fail("compute pipeline not served from the archive");
        } else if (mode == "stale") {
            struct stat st;
            if (ps4gnm_pso_archive::Contains(1) || ps4gnm_pso_archive::Contains(2)) return Fail("stale index survived");
            if (ArchiveFiles(dir) != 0) return Fail("stale archive files not deleted");
            if (stat((dir + "/pipelines_archived.bin").c_str(), &st) != 0 || st.st_size >= old_index_size)
                return Fail("index not recreated with only a header");
        } else if (mode == "budget" || mode == "corrupt") {
            if (ps4gnm_pso_archive::Contains(1)) return Fail("old index survived");
            ps4gnm_pso_archive::Attach(rd);
            if (![dev newRenderPipelineStateWithDescriptor:rd error:&e]) return Fail("build after restart");
        } else {
            return Fail("unknown mode");
        }
    }
    printf("pso_archive_test: PASS (%s)\n", mode.c_str());
    return 0;
}
