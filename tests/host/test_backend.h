// The renderer backend a host test runs on: the one PS4_GNM_METAL names (3 when unset), and the
// one allowed skip (a Metal 4 test on a GPU without MTLGPUFamilyMetal4), and the texture cache's
// residency hooks. Defines no failure counter: tests with their own check() include it as well as
// backend_harness.h's users.
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <memory>
#include <string>

#include "ps4_gnm_backend.h"
#include "ps4_gnm_backend_metal4.h"

inline bool RequireMetal4(id<MTLDevice> dev, const char* test) {
    if ([dev supportsFamily:MTLGPUFamilyMetal4]) return true;
    printf("%s: SKIP: no MTLGPUFamilyMetal4 on %s\n", test, dev.name.UTF8String);
    return false;
}

// nullptr (why set) if the named backend cannot run here; on a Metal 4-family GPU "4" always runs.
// PS4_GNM_METAL is unset, "3" or "4"; any other value ends the test with exit status 2 (a test run
// on an unintended backend would report PASS for the wrong one).
inline std::unique_ptr<ps4gnm::GnmBackend> MakeTestBackend(id<MTLDevice> dev, std::string* why) {
    const char* e = getenv("PS4_GNM_METAL");
    if (e && strcmp(e, "3") && strcmp(e, "4")) {
        fprintf(stderr, "FATAL: PS4_GNM_METAL=%s: the host tests take 3 or 4\n", e);
        exit(2);
    }
    std::unique_ptr<ps4gnm::GnmBackend> be;
    if (e && !strcmp(e, "4")) {
        if (![dev supportsFamily:MTLGPUFamilyMetal4]) {
            *why = "PS4_GNM_METAL=4 on a GPU without MTLGPUFamilyMetal4";
            return nullptr;
        }
        be = ps4gnm::MakeMetal4Backend();
    } else {
        be = ps4gnm::MakeMetal3Backend();
    }
    if (!be->Init(dev, why)) return nullptr;
    return be;
}

// Texture residency the way the renderer keeps it for its texture cache (ps4_gnm_draw.mm,
// TextureCache::TextureHooks): a texture reported created is made resident on the backend, one
// reported released is evicted. These tests commit nothing on the backend's timeline (their
// command buffers go to SideQueue), so no seq that could use an evicted texture is in flight:
// Retire runs the removals as if every seq had completed, as the backend's completion handling
// would. Metal 3: the backend keeps no sets, Retire and Leaked do nothing.
struct TestTextureResidency {
    ps4gnm::GnmBackend* be = nullptr;

    static void Created(void* c, id<MTLTexture> t) {
        static_cast<TestTextureResidency*>(c)->be->MakeResident(t, ps4gnm::GnmResidencyClass::Texture);
    }
    static void Released(void* c, id<MTLTexture> t) { static_cast<TestTextureResidency*>(c)->be->Evict(t, 0); }

    // the backend lets go of the textures evicted so far
    void Retire() const {
        if (be->Kind() == ps4gnm::GnmBackendKind::Metal4) static_cast<ps4gnm::Metal4Backend*>(be)->Residency().Retire(UINT64_MAX);
    }
    // after Retire: the cache textures still in the backend's sets (0 once every cache is destroyed)
    size_t Leaked() const {
        if (be->Kind() != ps4gnm::GnmBackendKind::Metal4) return 0;
        ps4gnm::GnmResidency& r = static_cast<ps4gnm::Metal4Backend*>(be)->Residency();
        r.Retire(UINT64_MAX);
        return r.Count(ps4gnm::GnmResidencyClass::Texture);
    }
};
