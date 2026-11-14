// Ported from iShareScreen src/isharescreen/frontend/desktop/gpu.py
// (WGSL_BIPLANAR) (AGPL-3.0)
//
// Bi-planar YCbCr → RGB. Plane 0 is luma (r8Unorm, or r16Unorm for 10-bit),
// plane 1 is interleaved Cb/Cr (rg8Unorm / rg16Unorm): nv24 ('444f') for
// Apple's 4:4:4 stream. Chroma is sampled with the same normalized
// coordinates as luma, so 4:2:0 output works unchanged.
//
// Deviation: the reference draws ONE full-screen triangle into canvas-sized
// textures it uploads every tile into. Here each tile's decoded image is
// sampled in place (zero copy, CVMetalTextureCache), so each strip is its own
// quad at the strip's place in the aspect-fitted canvas.
#include <metal_stdlib>
using namespace metal;

struct StripUniforms {
    float4 dstRect;     // NDC: left, top, right, bottom
    float2 texExtent;   // fraction of the image sampled (cut at the canvas edge)
    float2 pad;
    float4 range;       // luma offset, luma scale, chroma offset, chroma scale
    float4 coeffs;      // R = Y + x·Cr; G = Y − y·Cb − z·Cr; B = Y + w·Cb
};

struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut stripVertex(uint vid [[vertex_id]], constant StripUniforms &u [[buffer(0)]]) {
    // Triangle strip: top-left, bottom-left, top-right, bottom-right.
    float2 corner = float2(vid >= 2 ? 1.0 : 0.0, (vid & 1) ? 1.0 : 0.0);
    VOut o;
    o.position = float4(mix(u.dstRect.x, u.dstRect.z, corner.x), mix(u.dstRect.y, u.dstRect.w, corner.y), 0.0, 1.0);
    o.uv = corner * u.texExtent;
    return o;
}

fragment float4 stripFragment(VOut in [[stage_in]],
                              texture2d<float> lumaTex [[texture(0)]],
                              texture2d<float> chromaTex [[texture(1)]],
                              constant StripUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y = (lumaTex.sample(s, in.uv).r - u.range.x) * u.range.y;
    float2 c = (chromaTex.sample(s, in.uv).rg - u.range.z) * u.range.w;   // (Cb, Cr)
    float3 rgb = float3(y + u.coeffs.x * c.y,
                        y - u.coeffs.y * c.x - u.coeffs.z * c.y,
                        y + u.coeffs.w * c.x);
    return float4(saturate(rgb), 1.0);
}
