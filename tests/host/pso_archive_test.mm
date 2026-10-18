// Host test of the pipeline archive (ps4_gnm_pipeline_archive.mm) on the real Metal device.
// Runs as separate processes: write → read must find both pipelines in the archive without
// compiling (MTLPipelineOptionFailOnBinaryArchiveMiss); budget and corrupt start anew.
#import <Metal/Metal.h>
#include "ps4_gnm_pipeline_archive.h"
#include <cstdio>
#include <cstring>
#include <string>
#include <sys/stat.h>

static const char* kSrc =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "vertex float4 vmain(uint vid [[vertex_id]]) { return float4(float(vid & 1), float(vid >> 1), 0, 1); }\n"
    "fragment float4 fmain() { return float4(1, 0.5, 0.25, 1); }\n"
    "kernel void cmain(device float* o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = float(i) * 2.0; }\n";

static int Fail(const char* what) {
    printf("pso_archive_test: FAIL (%s)\n", what);
    return 1;
}

int main(int argc, char** argv) {
    if (argc != 3) return Fail("usage: pso_archive_test <write|read|budget|corrupt> <dir>");
    const std::string mode = argv[1], dir = argv[2];
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        NSError* e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(kSrc) options:nil error:&e];
        if (!lib) return Fail("library");
        MTLRenderPipelineDescriptor* rd = [MTLRenderPipelineDescriptor new];
        rd.vertexFunction = [lib newFunctionWithName:@"vmain"];
        rd.fragmentFunction = [lib newFunctionWithName:@"fmain"];
        rd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        MTLComputePipelineDescriptor* cd = [MTLComputePipelineDescriptor new];
        cd.computeFunction = [lib newFunctionWithName:@"cmain"];
        const std::string archive = dir + "/pipelines.metalar";

        if (mode == "corrupt") {
            FILE* f = fopen(archive.c_str(), "wb");
            fputs("not an archive", f);
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
            if (stat(archive.c_str(), &st) != 0 || st.st_size == 0) return Fail("archive file");
        } else if (mode == "read") {
            if (!ps4gnm_pso_archive::Contains(1) || !ps4gnm_pso_archive::Contains(2)) return Fail("index lost keys");
            ps4gnm_pso_archive::Attach(rd);
            ps4gnm_pso_archive::Attach(cd);
            if (![dev newRenderPipelineStateWithDescriptor:rd options:MTLPipelineOptionFailOnBinaryArchiveMiss
                                                reflection:nil error:&e])
                return Fail("render pipeline not served from the archive");
            if (![dev newComputePipelineStateWithDescriptor:cd options:MTLPipelineOptionFailOnBinaryArchiveMiss
                                                 reflection:nil error:&e])
                return Fail("compute pipeline not served from the archive");
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
