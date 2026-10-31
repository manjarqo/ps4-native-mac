// Storage images must preserve their volume depth when written and sampled, including
// when the same guest address previously held a 2D render target.
#import <Metal/Metal.h>
#include <cstdio>
#include <vector>
#include "ps4_gnm_resources.h"
#include "test_backend.h"
extern "C" uint64_t ps4_hitch_now_ns(void) { return 0; }
extern "C" void ps4_hitch_add_ns(int, uint64_t) {}
extern "C" void ps4_gnm_hitch_note_upload(double) {}
extern "C" int32_t sceKernelIsNeoMode(void) { return 0; }
using namespace ps4gnm;
static ImageDesc Image(uint64_t address, bool volume) {
    uint32_t t[8] = {};
    t[0] = uint32_t(address >> 8);
    t[1] = 10u << 20; // RGBA8 unorm
    t[2] = 7u | (7u << 14);
    t[3] = 4u | (5u << 3) | (6u << 6) | (7u << 9) | (13u << 20) | ((volume ? 10u : 9u) << 28);
    t[4] = (volume ? 3u : 0u) | (7u << 13);
    ImageDesc d;
    DecodeImage(t, 8, &d);
    return d;
}
int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return 1;
        std::string why;
        auto be = MakeTestBackend(dev, &why);
        if (!be) {
            const char* env = getenv("PS4_GNM_METAL");
            const bool skip = env && !strcmp(env, "4") && ![dev supportsFamily:MTLGPUFamilyMetal4];
            printf("gnm_storage_3d_test: %s: %s\n", skip ? "SKIP" : "FAIL", why.c_str());
            return skip ? 0 : 1;
        }
        auto q = be->SideQueue();
        TestTextureResidency res;
        res.be = be.get();
        std::vector<uint8_t> mem(1 << 20);
        bool ok = true;
        {
            TextureCache tc(dev, q, mem.data(), mem.size());
            TextureCache::TextureHooks hooks;
            hooks.ctx = &res; hooks.created = TestTextureResidency::Created; hooks.released = TestTextureResidency::Released;
            tc.SetHooks(hooks);
            NSError* err = nil;
            NSString* source = @"#include <metal_stdlib>\nusing namespace metal;\nkernel void fill(texture3d<float, access::write> t [[texture(0)]], uint3 p [[thread_position_in_grid]]) { t.write(float4(float3(p + uint3(1,2,3))/255.0,1.0),p); }";
            auto lib = [dev newLibraryWithSource:source options:nil error:&err];
            auto fn = [lib newFunctionWithName:@"fill"];
            auto pipe = [dev newComputePipelineStateWithFunction:fn error:&err];
            if (!pipe) { fprintf(stderr, "%s\n", err.description.UTF8String); return 1; }
            for (bool reused : {false, true}) {
                auto image = Image(reused ? 0x20000 : 0x10000, true);
                if (reused) tc.GetStorageTexture(Image(image.address, false));
                auto storage = tc.GetStorageTexture(image);
                if (!storage || storage.textureType != MTLTextureType3D || storage.depth != 4) {
                    printf("FAIL: storage volume lost its type/depth (reused=%d, type=%lu, depth=%lu)\n", reused, (unsigned long)storage.textureType, (unsigned long)storage.depth);
                    ok = false; continue;
                }
                auto cb = [q commandBuffer];
                auto enc = [cb computeCommandEncoder];
                [enc setComputePipelineState:pipe]; [enc setTexture:storage atIndex:0];
                [enc dispatchThreads:MTLSizeMake(8,8,4) threadsPerThreadgroup:MTLSizeMake(4,4,1)];
                [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
                if (cb.status == MTLCommandBufferStatusError) { ok = false; continue; }
                auto sampled = tc.GetTexture(image);
                if (!sampled || sampled.textureType != MTLTextureType3D || sampled.depth != 4) {
                    printf("FAIL: sampled volume lost its type/depth\n"); ok = false; continue;
                }
                uint8_t pixels[8*8*4*4] = {};
                [sampled getBytes:pixels bytesPerRow:32 bytesPerImage:256 fromRegion:MTLRegionMake3D(0,0,0,8,8,4) mipmapLevel:0 slice:0];
                for (unsigned z=0; z<4; ++z) for (unsigned y=0; y<8; ++y) for (unsigned x=0; x<8; ++x) {
                    auto p = &pixels[((z*8+y)*8+x)*4];
                    if (p[0]!=x+1 || p[1]!=y+2 || p[2]!=z+3 || p[3]!=255) ok = false;
                }
                if (tc.GetStorageTexture(image) != storage) { printf("FAIL: storage identity changed\n"); ok = false; }
            }
        }
        res.Retire();
        if (res.Leaked()) ok = false;
        printf("gnm_storage_3d_test: %s\n", ok ? "PASS" : "FAIL");
        return ok ? 0 : 1;
    }
}
