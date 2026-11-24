// The quad's shape, evaluated per fragment.
//
// `sdRoundedBox`, `coverage` and `boxCoverage` are transcriptions of
// `roundedBoxSdf`, `coverage` and `boxCoverage` in `src/raster.zig`, and that
// duplication is the one real risk in this file: two implementations of one
// formula drift. `tools/gpu_demo.zig` renders the same scene through both and
// compares the pixels, so a drift shows up as a number rather than as "the GPU
// looks slightly off".
#version 450

layout(location = 0) flat in vec4 v_rect;
layout(location = 1) flat in uvec2 v_color;
layout(location = 2) flat in vec2 v_params;
layout(location = 3) flat in vec4 v_clip;
layout(location = 4) flat in ivec4 v_uv;
layout(location = 5) flat in uint v_flags;

layout(set = 0, binding = 0) uniform sampler2D atlas;

layout(location = 0) out vec4 out_color;

const uint FLAG_TEXTURED = 1u;

float sdRoundedBox(vec2 p, vec4 r, float radius) {
    vec2 h = r.zw * 0.5;
    float rad = min(radius, min(h.x, h.y));
    vec2 d = abs(p - (r.xy + h)) - (h - rad);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - rad;
}

// Exact coverage of an axis-aligned rectangle over one pixel. Exact rather than
// a ramp because the clip rectangle is always axis-aligned.
float boxCoverage(vec2 p, vec4 r) {
    float ox = min(p.x + 0.5, r.x + r.z) - max(p.x - 0.5, r.x);
    float oy = min(p.y + 0.5, r.y + r.w) - max(p.y - 0.5, r.y);
    return clamp(ox, 0.0, 1.0) * clamp(oy, 0.0, 1.0);
}

vec4 unpack(uint v) {
    return vec4(
        float(v & 0xffu),
        float((v >> 8) & 0xffu),
        float((v >> 16) & 0xffu),
        float((v >> 24) & 0xffu)) / 255.0;
}

void main() {
    vec2 p = gl_FragCoord.xy;

    float in_clip = boxCoverage(p, v_clip);
    if (in_clip <= 0.0) discard;

    if ((v_flags & FLAG_TEXTURED) != 0u) {
        // One destination pixel, one atlas texel, no filtering. The scene
        // builder snapped this quad to the pixel grid, so the offset from the
        // quad's origin IS the offset into its atlas rectangle -- which is the
        // same arithmetic `drawGlyph` in `src/raster.zig` does, and why the two
        // agree exactly rather than approximately on text.
        ivec2 t = ivec2(floor(p - v_rect.xy));
        if (t.x < 0 || t.y < 0 || t.x >= v_uv.z - v_uv.x || t.y >= v_uv.w - v_uv.y) discard;
        float cov = texelFetch(atlas, ivec2(v_uv.x, v_uv.y) + t, 0).r;
        if (cov <= 0.0) discard;
        vec4 fg = unpack(v_color.x);
        float a = fg.a * cov * in_clip;
        out_color = vec4(fg.rgb * a, a);
        return;
    }

    float sd = sdRoundedBox(p, v_rect, v_params.y);
    float outer = clamp(0.5 - sd, 0.0, 1.0);
    if (outer <= 0.0) discard;

    float bw = v_params.x;
    // The fill is the shape inset by the border width. Subtracting coverages
    // rather than evaluating a second distance field is what makes the border
    // an exact complement of the fill: no seam and no double-blended pixel.
    float inner = bw > 0.0 ? clamp(0.5 - (sd + bw), 0.0, 1.0) : outer;

    vec4 bg = unpack(v_color.x);
    vec4 bc = unpack(v_color.y);
    float fill_a = bg.a * inner * in_clip;
    float border_a = bc.a * max(outer - inner, 0.0) * in_clip;

    // The reference rasteriser blends the fill into the target and then the
    // border over the result. Folding both into one premultiplied source has to
    // preserve that order, so the border is the one that is "over".
    vec3 rgb = bc.rgb * border_a + bg.rgb * fill_a * (1.0 - border_a);
    float a = border_a + fill_a * (1.0 - border_a);
    out_color = vec4(rgb, a);
}
