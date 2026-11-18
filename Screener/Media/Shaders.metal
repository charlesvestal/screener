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
    float2 opts;        // x: 1 = nearest-neighbour (exact 1:1 mapping), 0 = bilinear
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
    // 1:1 (CompositeLayout.isOneToOne): nearest-neighbour, so every drawable
    // pixel is exactly one decoded pixel whatever the interpolated uv's
    // rounding. Otherwise bilinear (scaled / zoomed).
    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    constexpr sampler near(filter::nearest, address::clamp_to_edge);
    bool exact = u.opts.x > 0.5;
    float yv = exact ? lumaTex.sample(near, in.uv).r : lumaTex.sample(lin, in.uv).r;
    float2 cv = exact ? chromaTex.sample(near, in.uv).rg : chromaTex.sample(lin, in.uv).rg;
    float y = (yv - u.range.x) * u.range.y;
    float2 c = (cv - u.range.z) * u.range.w;   // (Cb, Cr)
    float3 rgb = float3(y + u.coeffs.x * c.y,
                        y - u.coeffs.y * c.x - u.coeffs.z * c.y,
                        y + u.coeffs.w * c.x);
    return float4(saturate(rgb), 1.0);
}

// TCP-only fallback (Task 19): the framebuffer path's BGRA8 picture
// (FramebufferPipeline) is sampled as-is; same vertex stage as the strips.
fragment float4 bgraFragment(VOut in [[stage_in]],
                             texture2d<float> tex [[texture(0)]],
                             constant StripUniforms &u [[buffer(0)]]) {
    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    constexpr sampler near(filter::nearest, address::clamp_to_edge);
    return float4((u.opts.x > 0.5 ? tex.sample(near, in.uv) : tex.sample(lin, in.uv)).rgb, 1.0);
}

// Cursor overlay (gpu.py WGSL_CURSOR): one textured quad over the video.
// The texture is premultiplied RGBA (RemoteCursor); the pipeline blends
// one / one-minus-source-alpha. (gpu.py samples straight alpha and blends
// src-alpha / one-minus-src-alpha: same result.)
struct CursorUniforms {
    float4 dstRect;     // NDC: left, top, right, bottom
};

vertex VOut cursorVertex(uint vid [[vertex_id]], constant CursorUniforms &u [[buffer(0)]]) {
    float2 corner = float2(vid >= 2 ? 1.0 : 0.0, (vid & 1) ? 1.0 : 0.0);
    VOut o;
    o.position = float4(mix(u.dstRect.x, u.dstRect.z, corner.x), mix(u.dstRect.y, u.dstRect.w, corner.y), 0.0, 1.0);
    o.uv = corner;
    return o;
}

// `alpha` fades the whole sprite (motion-trail ghosts; 1 for the cursor).
fragment float4 cursorFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                               constant float &alpha [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv) * alpha;
}

// Cursor halo glow: a soft disc filling the quad (cursorVertex), premultiplied
// (same blend as the cursor). color.a is the centre opacity.
fragment float4 glowFragment(VOut in [[stage_in]], constant float4 &color [[buffer(0)]]) {
    float d = length(in.uv * 2.0 - 1.0);
    float a = color.a * pow(saturate(1.0 - d), 2.0);
    return float4(color.rgb * a, a);
}

// Touch ripples (MetalRenderer, RippleField): a full-screen pass over the
// picture drawn into an offscreen `scene` texture. Each ripple is a ring of
// radius R and half-width W around C (pixels): with x = (|p − C| − R) / W the
// picture is sampled displaced along the radius by A·x·e^(−x²) (normalised
// so the peak is A: content just outside the ring is pushed outward, just
// inside pulled in — a refracting wave), and the crest gets a screen-blended
// highlight H·e^(−2x²) in the ripple's tint. Reduce Motion ripples have A = 0
// (highlight only).
// Tinted rim (so a ring reads on white, where refraction and a white crest
// vanish): a band of half-width Rw around radius Rr with soft (~1 px) edges,
// opacity Ra, plus an outer glow G·e^(−(d/5Rw)²). Its blend adapts to the
// picture's luminance L under each pixel: over light content it multiplies
// by a deeper tint (a darker coloured line), over dark content it screens a
// lighter tint (a glow), crossfading between L ≈ 0.3 and 0.7.
// Uniforms (float4s): [w, h, count, 0], then per ripple
// [Cx, Cy, R, A] [W, H, Ra, Rw] [tint.rgb, G] [rimTint.rgb, Rr].
struct PostOut {
    float4 position [[position]];
};

vertex PostOut postVertex(uint vid [[vertex_id]]) {
    // One triangle covering the target.
    float2 p = float2((vid == 1) ? 3.0 : -1.0, (vid == 2) ? -3.0 : 1.0);
    PostOut o;
    o.position = float4(p, 0.0, 1.0);
    return o;
}

fragment float4 rippleFragment(PostOut in [[stage_in]], texture2d<float> scene [[texture(0)]],
                               constant float4 *u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 size = u[0].xy;
    int n = min(int(u[0].z), 8);
    float2 p = in.position.xy;
    float2 disp = float2(0.0);
    float3 glow = float3(0.0);
    float rimKeep = 1.0;            // Π(1 − rim opacity)
    float rimSum = 0.0;
    float3 rimTint = float3(0.0);   // opacity-weighted
    for (int i = 0; i < n; i++) {
        float4 a = u[1 + 4 * i], b = u[2 + 4 * i], c = u[3 + 4 * i], e = u[4 + 4 * i];
        float2 d = p - a.xy;
        float r = length(d);
        // Tinted rim + glow.
        if (b.z > 0.0 || c.w > 0.0) {
            float dr = abs(r - e.w);
            float band = 1.0 - smoothstep(b.w - 0.75, b.w + 0.75, dr);
            float gw = 5.0 * b.w;
            float ra = saturate(b.z * band + c.w * exp(-(dr * dr) / (gw * gw)) * (1.0 - band));
            rimKeep *= 1.0 - ra;
            rimSum += ra;
            rimTint += e.rgb * ra;
        }
        float x = (r - a.z) / b.x;
        if (abs(x) > 3.5) continue;
        float g = exp(-x * x);
        float2 dir = r > 0.5 ? d / r : float2(0.0);
        disp += dir * (a.w * 2.3316 * x * g);           // 1/max(x·e^(−x²)) = 2.3316
        glow += c.rgb * (b.y * g * g);                   // a narrower crest
    }
    float3 rgb = scene.sample(s, (p - disp) / size).rgb;
    float lum = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = 1.0 - (1.0 - rgb) * (1.0 - saturate(glow));   // screen blend
    float ra = 1.0 - rimKeep;
    if (ra > 0.0) {
        float3 tint = rimTint / max(rimSum, 1e-4);
        float3 deep = tint * 0.7;                        // over light: multiply by a deeper tint
        float3 lite = mix(tint, float3(1.0), 0.25);      // over dark: screen a lighter tint
        float3 onLight = rgb * deep;
        float3 onDark = 1.0 - (1.0 - rgb) * (1.0 - lite);
        float3 rim = mix(onDark, onLight, smoothstep(0.3, 0.7, lum));
        rgb = mix(rgb, rim, ra);
    }
    return float4(rgb, 1.0);
}
