// RectList draws on Metal (GCN primitive type 17: three vertices per rectangle, the GPU makes
// the fourth). Metal has no such primitive and no stage between the vertex and the fragment
// shader, so a RectList draw is encoded as two draws in the open render pass (see
// gcn_shader_rectlist_msl in gcn_recompiler.h for the two vertex shaders):
//  1. the guest vertex shader's capture variant (rasterization disabled) runs the draw as given
//     and stores every vertex's outputs in a buffer;
//  2. after a vertex-to-vertex memory barrier, the expansion vertex shader emits two triangles per
//     rectangle from those vertices, with the guest fragment shader and the draw's state.
// Shared by the renderer (ps4_gnm_draw.mm) and its host test (tests/host/gnm_rectlist_test.mm).
#pragma once

#import <Metal/Metal.h>

#include <cstdint>

namespace ps4gnm_rect {

// Capture index of every vertex of a RectList draw of `count` vertices (3 per rectangle):
// the index buffer values of an indexed draw (indices != nullptr; 32-bit if i32), 0..count-1
// otherwise. Returns the number of capture slots per instance (largest index + 1), or 0 if
// count is not a positive multiple of 3.
inline uint32_t BuildSlots(const void* indices, bool i32, uint32_t count, uint32_t* slots) {
    if (count == 0 || count % 3) return 0;
    uint32_t n = 0;
    for (uint32_t i = 0; i < count; ++i) {
        const uint32_t v = !indices ? i : i32 ? static_cast<const uint32_t*>(indices)[i]
                                             : static_cast<const uint16_t*>(indices)[i];
        slots[i] = v;
        if (v >= n) n = v + 1;
    }
    return n;
}

// The guest draw as Metal parameters.
struct Geometry {
    uint32_t count = 0;         // vertices (indices of an indexed draw), 3 per rectangle
    uint32_t instances = 1;
    uint32_t base_instance = 0;
    uint32_t vertex_start = 0;  // non-indexed draws
    int32_t base_vertex = 0;    // indexed draws
    id<MTLBuffer> index_buffer = nil; // nil: non-indexed
    NSUInteger index_offset = 0;
    MTLIndexType index_type = MTLIndexTypeUInt16;
};

// Buffers of the two draws.
struct Buffers {
    id<MTLBuffer> vertices; // per_instance * instances * vertex_stride bytes, written by draw 1
    NSUInteger vertices_off;
    id<MTLBuffer> slots;    // uint32 per vertex of the draw (BuildSlots)
    NSUInteger slots_off;
    id<MTLBuffer> params;   // uint32 per_instance (BuildSlots' result)
    NSUInteger params_off;
    uint32_t capture_slot, params_slot; // gcn_rectlist_msl capture_buffer / params_buffer
};

// Encodes both draws on `enc`. Before the call the caller has bound everything the guest vertex
// shader reads on the vertex stage (resources and vertex buffers) and the fragment shader's
// resources, and set the draw's fixed-function state. Afterwards the encoder's pipeline is
// `expand` and vertex buffer slots 0, 1, 2, capture_slot and params_slot hold `b`.
inline void Encode(id<MTLRenderCommandEncoder> enc, id<MTLRenderPipelineState> capture,
                   id<MTLRenderPipelineState> expand, const Geometry& g, const Buffers& b) {
    [enc setRenderPipelineState:capture];
    [enc setVertexBuffer:b.vertices offset:b.vertices_off atIndex:b.capture_slot];
    [enc setVertexBuffer:b.params offset:b.params_off atIndex:b.params_slot];
    if (g.index_buffer)
        [enc drawIndexedPrimitives:MTLPrimitiveTypePoint indexCount:g.count indexType:g.index_type
                       indexBuffer:g.index_buffer indexBufferOffset:g.index_offset instanceCount:g.instances
                        baseVertex:g.base_vertex baseInstance:g.base_instance];
    else
        [enc drawPrimitives:MTLPrimitiveTypePoint vertexStart:g.vertex_start vertexCount:g.count
              instanceCount:g.instances baseInstance:g.base_instance];
    // The expansion's vertex shader reads what the capture's vertex shader wrote.
    [enc memoryBarrierWithScope:MTLBarrierScopeBuffers afterStages:MTLRenderStageVertex
                   beforeStages:MTLRenderStageVertex];
    [enc setRenderPipelineState:expand];
    [enc setVertexBuffer:b.vertices offset:b.vertices_off atIndex:0];
    [enc setVertexBuffer:b.slots offset:b.slots_off atIndex:1];
    [enc setVertexBuffer:b.params offset:b.params_off atIndex:2];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:g.count / 3 * 6
          instanceCount:g.instances baseInstance:g.base_instance];
}

} // namespace ps4gnm_rect
