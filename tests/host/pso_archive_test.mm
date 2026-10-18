// Host test of the pipeline archive (ps4_gnm_pipeline_archive.mm) on the real Metal device.
// Runs as separate processes: write → read must find both pipelines in the archive without
// compiling (MTLPipelineOptionFailOnBinaryArchiveMiss); append adds a pipeline in a later session
// (its own file) and read2 must find all three; budget, corrupt and stale start anew.
#import <Metal/Metal.h>
#include "ps4_gnm_pipeline_archive.h"
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <string>
#include <sys/stat.h>

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

static int Fail(const char* what) {
    printf("pso_archive_test: FAIL (%s)\n", what);
    return 1;
}

int main(int argc, char** argv) {
    if (argc != 4) return Fail("usage: pso_archive_test <write|read|append|read2|budget|corrupt|stale> <dir> <nonce>");
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
        const uint64_t budget = mode == "budget" ? 1 : (64ull << 20);
        if (!ps4gnm_pso_archive::Open(dev, dir, budget)) return Fail("open");
        if (mode == "write") {
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
