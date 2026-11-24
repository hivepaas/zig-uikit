// The quad pipeline in Metal Shading Language: quad.vert and quad.frag, one
// file, transcribed rather than translated by a tool.
//
// That makes three implementations of one signed distance field -- this file,
// the GLSL, and `roundedBoxSdf`/`coverage`/`boxCoverage` in `src/raster.zig` --
// and the duplication is watched the same way as before: `zig build gpu-demo`
// renders the demo through this file and through the reference and compares
// every pixel.
//
// Compiled at run time by `newLibraryWithSource:`, embedded as text. Building
// the toolkit therefore needs no Metal compiler, which in Xcode 26 is a
// separate download; the cost moves to start-up and is measured there.
//
// Three differences from the Vulkan pipeline:
//
//   - Metal's clip space has +Y up where Vulkan's has +Y down, so the vertex
//     shader flips Y. `[[position]]` in the fragment shader is top-left origin
//     with pixel centres at .5, exactly like `gl_FragCoord`, so nothing below
//     the vertex shader changes.
//   - A scale factor. The scene is laid out in points and a Retina display has
//     two pixels per point; the vertex shader scales every length in the quad
//     so the fragment shader evaluates the distance field in pixels, where its
//     half-pixel antialiasing ramp is meant to be.
//   - No red/blue swap. A layer's drawables are BGRA8Unorm, and a pixel
//     format names channels rather than reordering what the shader writes, so
//     the shader writes RGBA into a BGRA target and the result is correct.
//     Measured, not assumed: with a swap like the one the Vulkan shader used
//     to have, the presented frame differs from the reference by 208 of 255
//     on 98.5% of its pixels. The Vulkan swap was the same bug and is gone.

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewport; // pixels
    float scale;     // pixels per layout unit
    float _pad;
};

// The scene's `Quad`, read with no repacking. The attribute offsets come from
// `@offsetOf` on the Zig struct; see `vertexDescriptor` in metal.zig.
struct QuadIn {
    float4 rect   [[attribute(0)]]; // offset  0: x, y, w, h
    uint2  color  [[attribute(1)]]; // offset 16: background, border_color
    float2 params [[attribute(2)]]; // offset 24: border_width, corner_radius
    float4 clip   [[attribute(3)]]; // offset 32: cx, cy, cw, ch
};

struct Varyings {
    float4 position [[position]];
    float4 rect   [[flat]];
    uint2  color  [[flat]];
    float2 params [[flat]];
    float4 clip   [[flat]];
};

vertex Varyings quad_vertex(QuadIn q [[stage_in]],
                            uint vid [[vertex_id]],
                            constant Uniforms& u [[buffer(1)]]) {
    // 0:(0,0) 1:(1,0) 2:(1,1) 3:(0,0) 4:(1,1) 5:(0,1)
    float2 uv = float2(
        (vid == 1u || vid == 2u || vid == 4u) ? 1.0 : 0.0,
        (vid == 2u || vid == 4u || vid == 5u) ? 1.0 : 0.0);

    float4 rect = q.rect * u.scale;

    // Expanded by one pixel on every side so the antialiased edge, which
    // extends half a pixel past the geometric one, is not clipped by the quad.
    float2 p = rect.xy - 1.0 + uv * (rect.zw + 2.0);
    float2 ndc = p / u.viewport * 2.0 - 1.0;

    Varyings out;
    out.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
    out.rect = rect;
    out.color = q.color;
    out.params = q.params * u.scale;
    out.clip = q.clip * u.scale;
    return out;
}

static float sdRoundedBox(float2 p, float4 r, float radius) {
    float2 h = r.zw * 0.5;
    float rad = min(radius, min(h.x, h.y));
    float2 d = abs(p - (r.xy + h)) - (h - rad);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - rad;
}

static float boxCoverage(float2 p, float4 r) {
    float ox = min(p.x + 0.5, r.x + r.z) - max(p.x - 0.5, r.x);
    float oy = min(p.y + 0.5, r.y + r.w) - max(p.y - 0.5, r.y);
    return clamp(ox, 0.0, 1.0) * clamp(oy, 0.0, 1.0);
}

static float4 unpack(uint v) {
    return float4(
        float(v & 0xffu),
        float((v >> 8) & 0xffu),
        float((v >> 16) & 0xffu),
        float((v >> 24) & 0xffu)) / 255.0;
}

fragment float4 quad_fragment(Varyings in [[stage_in]]) {
    float2 p = in.position.xy;

    float in_clip = boxCoverage(p, in.clip);
    if (in_clip <= 0.0) discard_fragment();

    float sd = sdRoundedBox(p, in.rect, in.params.y);
    float outer = clamp(0.5 - sd, 0.0, 1.0);
    if (outer <= 0.0) discard_fragment();

    float bw = in.params.x;
    float inner = bw > 0.0 ? clamp(0.5 - (sd + bw), 0.0, 1.0) : outer;

    float4 bg = unpack(in.color.x);
    float4 bc = unpack(in.color.y);
    float fill_a = bg.a * inner * in_clip;
    float border_a = bc.a * max(outer - inner, 0.0) * in_clip;

    // Fill first, border over it: the order the reference blends in.
    float3 rgb = bc.rgb * border_a + bg.rgb * fill_a * (1.0 - border_a);
    float a = border_a + fill_a * (1.0 - border_a);
    return float4(rgb, a);
}
