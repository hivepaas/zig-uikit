// One instanced quad per scene primitive.
//
// There is no vertex buffer for positions: six indices expand a unit square,
// and everything else is per-instance data read straight out of the `Quad`
// struct from `src/scene.zig` with no repacking. That is what the scene layer's
// 48-byte extern struct is for, and the attribute offsets below are the
// struct's field offsets.
#version 450

layout(push_constant) uniform Push {
    vec2 viewport;
} pc;

// There is no red/blue swap, whatever the target's byte order. A format such
// as B8G8R8A8_UNORM names channels; it does not reorder what the shader
// writes. An earlier version swapped here for BGRA targets and crossed the
// channels on every one of them -- a difference of 208 of 255 -- which went
// unseen because the machine it was written on offered R8G8B8A8_UNORM.

layout(location = 0) in vec4 in_rect;    // offset  0: x, y, w, h
layout(location = 1) in uvec2 in_color;  // offset 16: background, border_color
layout(location = 2) in vec2 in_params;  // offset 24: border_width, corner_radius
layout(location = 3) in vec4 in_clip;    // offset 32: cx, cy, cw, ch
layout(location = 4) in uvec4 in_uv;     // offset 48: u0, v0, u1, v1 (16-bit)
layout(location = 5) in uint in_flags;   // offset 56

layout(location = 0) flat out vec4 v_rect;
layout(location = 1) flat out uvec2 v_color;
layout(location = 2) flat out vec2 v_params;
layout(location = 3) flat out vec4 v_clip;
layout(location = 4) flat out ivec4 v_uv;
layout(location = 5) flat out uint v_flags;

void main() {
    // 0:(0,0) 1:(1,0) 2:(1,1) 3:(0,0) 4:(1,1) 5:(0,1)
    uint i = uint(gl_VertexIndex);
    vec2 uv = vec2(
        (i == 1u || i == 2u || i == 4u) ? 1.0 : 0.0,
        (i == 2u || i == 4u || i == 5u) ? 1.0 : 0.0);

    // Expanded by one pixel on every side, because the fragment shader's
    // coverage ramp extends half a pixel past the geometric edge and a quad
    // that stopped exactly at its bounds would clip its own antialiasing.
    //
    // A textured quad has no ramp -- its edge is a texel boundary -- so the
    // expansion is wasted fragments for glyphs. It is kept uniform anyway: the
    // fragment shader has to bounds-check the texel fetch regardless, the
    // waste is a one-pixel border on glyphs that are typically 6 by 10, and one
    // code path here is worth more than that.
    vec2 p = in_rect.xy - 1.0 + uv * (in_rect.zw + 2.0);

    // Vulkan's clip space has +Y down, which is the same direction as the
    // layout engine's pixel coordinates, so there is no flip here.
    gl_Position = vec4(p / pc.viewport * 2.0 - 1.0, 0.0, 1.0);

    v_rect = in_rect;
    v_color = in_color;
    v_params = in_params;
    v_clip = in_clip;
    v_uv = ivec4(in_uv);
    v_flags = in_flags;
}
