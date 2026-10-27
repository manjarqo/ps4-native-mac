// The Metal vertex buffer layout of a GCN vertex input (ps4gnm_vertex::SetLayout, used by
// ps4_gnm_draw.mm). A V# with stride 0 gives every vertex the same element, which the renderer
// maps to Metal's constant step function. The test builds a pipeline whose colour input comes
// from such a buffer, as the renderer does: it must be accepted by pipeline validation and by a
// binary archive (Metal asserts "references a buffer ... that has no stride" for a layout without
// stride; inFAMOUS Second Son hit it, probe p2_26), and it must draw every vertex with the
// buffer's one element.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdio>
#include <cstring>

#include "ps4_gnm_vertex_layout.h"

static int g_failures;
#define CHECK(cond, ...)                                                                           \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            printf("FAIL line %d: %s  ", __LINE__, #cond);                                         \
            printf(__VA_ARGS__);                                                                   \
            printf("\n");                                                                          \
            g_failures++;                                                                          \
        }                                                                                          \
    } while (0)

static const char* kSrc = R"(
#include <metal_stdlib>
using namespace metal;
struct VI { float4 c [[attribute(6)]]; };
struct VO { float4 p [[position]]; float4 c; };
vertex VO vs(VI i [[stage_in]], uint id [[vertex_id]]) {
    VO o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.p = float4(uv * 2 - 1, 0, 1);
    o.c = i.c;
    return o;
}
fragment float4 fs(VO i [[stage_in]]) { return i.c; }
)";

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("gnm_vertex_layout_test: SKIP (no Metal device)\n");
            return 0;
        }
        NSError* e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(kSrc) options:nil error:&e];
        CHECK(lib, "library: %s", e.localizedDescription.UTF8String);
        MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"vs"];
        d.fragmentFunction = [lib newFunctionWithName:@"fs"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
        MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
        vd.attributes[6].format = MTLVertexFormatFloat4;
        vd.attributes[6].offset = 0;
        vd.attributes[6].bufferIndex = 15;
        // As the renderer maps a V# with stride 0.
        ps4gnm_vertex::SetLayout(vd.layouts[15], 0, MTLVertexStepFunctionConstant, 0);
        d.vertexDescriptor = vd;
        MTLBinaryArchiveDescriptor* ad = [MTLBinaryArchiveDescriptor new];
        id<MTLBinaryArchive> archive = [dev newBinaryArchiveWithDescriptor:ad error:&e];
        CHECK(archive, "archive: %s", e.localizedDescription.UTF8String);
        d.binaryArchives = @[ archive ];
        CHECK([archive addRenderPipelineFunctionsWithDescriptor:d error:&e], "archive add: %s",
              e.localizedDescription.UTF8String);
        id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:d error:&e];
        CHECK(pso, "pipeline: %s", e.localizedDescription.UTF8String);
        if (!pso) return 1;

        // One element, followed by others the draw must not read.
        const float vals[12] = {0.25f, 0.5f, 0.75f, 1.0f, 9, 9, 9, 9, 7, 7, 7, 7};
        id<MTLBuffer> vb = [dev newBufferWithBytes:vals length:sizeof(vals) options:MTLResourceStorageModeShared];
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                                      width:8
                                                                                     height:8
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = rt;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pso];
        [enc setVertexBuffer:vb offset:0 atIndex:15];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        CHECK(cb.status == MTLCommandBufferStatusCompleted, "command buffer status %ld", (long)cb.status);
        float px[8 * 8 * 4];
        [rt getBytes:px bytesPerRow:8 * 16 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
        int wrong = 0;
        for (int i = 0; i < 64; i++) {
            const float* p = px + i * 4;
            if (memcmp(p, vals, 16) != 0) {
                if (!wrong) printf("pixel %d: %g %g %g %g\n", i, p[0], p[1], p[2], p[3]);
                wrong++;
            }
        }
        CHECK(wrong == 0, "%d of 64 pixels are not the buffer's first element", wrong);
    }
    if (g_failures) {
        printf("gnm_vertex_layout_test: %d FAILED\n", g_failures);
        return 1;
    }
    printf("gnm_vertex_layout_test: PASS\n");
    return 0;
}
