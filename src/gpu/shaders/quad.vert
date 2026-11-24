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

layout(location = 0) in vec4 in_rect;    // offset  0: x, y, w, h
layout(location = 1) in uvec2 in_color;  // offset 16: background, border_color
layout(location = 2) in vec2 in_params;  // offset 24: border_width, corner_radius
layout(location = 3) in vec4 in_clip;    // offset 32: cx, cy, cw, ch

layout(location = 0) flat out vec4 v_rect;
layout(location = 1) flat out uvec2 v_color;
layout(location = 2) flat out vec2 v_params;
layout(location = 3) flat out vec4 v_clip;

void main() {
    // 0:(0,0) 1:(1,0) 2:(1,1) 3:(0,0) 4:(1,1) 5:(0,1)
    uint i = uint(gl_VertexIndex);
    vec2 uv = vec2(
        (i == 1u || i == 2u || i == 4u) ? 1.0 : 0.0,
        (i == 2u || i == 4u || i == 5u) ? 1.0 : 0.0);

    // Expanded by one pixel on every side, because the fragment shader's
    // coverage ramp extends half a pixel past the geometric edge and a quad
    // that stopped exactly at its bounds would clip its own antialiasing.
    vec2 p = in_rect.xy - 1.0 + uv * (in_rect.zw + 2.0);

    // Vulkan's clip space has +Y down, which is the same direction as the
    // layout engine's pixel coordinates, so there is no flip here.
    gl_Position = vec4(p / pc.viewport * 2.0 - 1.0, 0.0, 1.0);

    v_rect = in_rect;
    v_color = in_color;
    v_params = in_params;
    v_clip = in_clip;
}
