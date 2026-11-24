//! Tests that need a Metal device, kept out of `zig build test` for the same
//! reason as the Vulkan ones. They skip rather than fail when there is none.

const std = @import("std");
const testing = std.testing;
const ui = @import("zig-uikit");
const mtl = @import("metal.zig");

fn openGpu() !mtl.Gpu {
    return mtl.Gpu.init(testing.allocator, .{}) catch return error.SkipZigTest;
}

test "a device can be opened and reports a name" {
    var gpu = try openGpu();
    defer gpu.deinit();
    try testing.expect(gpu.name().len > 0);
}

test "clear and read back returns exactly the clear colour" {
    var gpu = try openGpu();
    defer gpu.deinit();
    var target = try mtl.Target.init(&gpu, 64, 48);
    defer target.deinit();

    const c = ui.Color.rgba(0x33, 0x66, 0x99, 0xFF);
    try mtl.clearOnly(&gpu, &target, c);

    const px = target.pixels();
    try testing.expectEqual(@as(usize, 64 * 48 * 4), px.len);
    for (0..64 * 48) |i| {
        try testing.expectEqual(c.r, px[i * 4 + 0]);
        try testing.expectEqual(c.g, px[i * 4 + 1]);
        try testing.expectEqual(c.b, px[i * 4 + 2]);
    }
}

test "a target with no area is refused" {
    var gpu = try openGpu();
    defer gpu.deinit();
    try testing.expectError(mtl.Error.SurfaceHasNoArea, mtl.Target.init(&gpu, 0, 16));
}

test "a shader that does not compile is reported, with the compiler's message" {
    var gpu = try openGpu();
    defer gpu.deinit();
    try testing.expectError(mtl.Error.ShaderRejected, mtl.Renderer.init(&gpu, "this is not metal"));
    var buf: [512]u8 = undefined;
    const msg = mtl.lastErrorMessage(&buf);
    try testing.expect(std.mem.startsWith(u8, msg, "newLibraryWithSource"));
    // The compiler's own diagnostic, not only where it failed.
    try testing.expect(msg.len > "newLibraryWithSource".len);
}

test "a shader that compiles but lacks the entry points is reported" {
    var gpu = try openGpu();
    defer gpu.deinit();
    try testing.expectError(mtl.Error.ShaderRejected, mtl.Renderer.init(&gpu, "#include <metal_stdlib>\n"));
}

/// Every branch the fragment shader has: a plain fill, a rounded fill, a thick
/// translucent border, and a clipped overflow. The same scene as the Vulkan
/// backend's test.
fn buildBranches(t: *ui.Tree, w: f32, h: f32) !void {
    t.setPaint(t.root(), .{ .background = ui.Color.hex(0x202225) });
    try t.setStyle(t.root(), .{ .axis = .col, .padding = 10, .gap = 8, .align_items = .stretch });

    const plain = try t.appendChild(t.root(), .{ .height = .{ .fixed = 20 }, .flex_shrink = 0 });
    t.setPaint(plain, .{ .background = ui.Color.hex(0xE06C75) });

    const round = try t.appendChild(t.root(), .{ .height = .{ .fixed = 24 }, .flex_shrink = 0 });
    t.setPaint(round, .{ .background = ui.Color.hex(0x61AFEF), .corner_radius = 11 });

    const bordered = try t.appendChild(t.root(), .{ .height = .{ .fixed = 26 }, .flex_shrink = 0 });
    t.setPaint(bordered, .{
        .background = ui.Color.rgba(0x98, 0xC3, 0x79, 0x80),
        .border_color = ui.Color.hex(0xE5C07B),
        .border_width = 3,
        .corner_radius = 6,
    });

    const clipper = try t.appendChild(t.root(), .{
        .axis = .col,
        .height = .{ .fixed = 18 },
        .flex_shrink = 0,
        .align_items = .stretch,
    });
    t.setPaint(clipper, .{
        .background = ui.Color.hex(0x2C313A),
        .border_color = ui.Color.hex(0x5C6370),
        .border_width = 2,
        .corner_radius = 5,
        .clip_children = true,
    });
    const overflow = try t.appendChild(clipper, .{ .height = .{ .fixed = 60 }, .flex_shrink = 0 });
    t.setPaint(overflow, .{ .background = ui.Color.hex(0xC678DD) });

    t.layout(.{ .w = w, .h = h });
}

/// The largest channel difference between a GPU image and the reference
/// rasteriser drawing the same scene at the same scale.
fn worstAgainstReference(got: []const u8, scene: *const ui.Scene, w: u32, h: u32, scale: f32, clear: ui.Color) !u32 {
    var fb = try ui.Framebuffer.init(testing.allocator, w, h);
    defer fb.deinit();
    fb.clear(clear);
    for (scene.items()) |q| ui.raster.drawQuad(&fb, q.scaled(scale), null);

    var worst: u32 = 0;
    var worst_at: usize = 0;
    for (0..@as(usize, w) * h) |i| {
        for (0..3) |ch| {
            const a = got[i * 4 + ch];
            const b = fb.px[i * 4 + ch];
            const d: u32 = if (a > b) a - b else b - a;
            if (d > worst) {
                worst = d;
                worst_at = i;
            }
        }
    }
    if (worst > 2) std.debug.print(
        "  GPU and reference differ by {d} at pixel ({d},{d}), scale {d}\n",
        .{ worst, worst_at % w, worst_at / w, scale },
    );
    return worst;
}

test "the GPU renders what the software reference renders" {
    var gpu = try openGpu();
    defer gpu.deinit();

    const w = 160;
    const h = 120;
    var t = try ui.Tree.init(testing.allocator);
    defer t.deinit();
    try buildBranches(&t, w, h);

    var scene = ui.Scene.init(testing.allocator);
    defer scene.deinit();
    const stats = try scene.build(&t);
    try testing.expectEqual(@as(u32, 6), stats.emitted);

    var target = try mtl.Target.init(&gpu, w, h);
    defer target.deinit();
    var renderer = try mtl.Renderer.initDefault(&gpu);
    defer renderer.deinit();

    const clear = ui.Color.hex(0x202225);
    try renderer.render(&target, &scene, clear);
    try testing.expect(try worstAgainstReference(target.pixels(), &scene, w, h, 1, clear) <= 2);
}

test "at a Retina scale factor the GPU still agrees with the reference" {
    // The scene is laid out in points and drawn at two pixels per point, with
    // the scaling done in the vertex shader. The reference draws the same quads
    // scaled on the CPU. If the shader scaled a length the reference does not,
    // or forgot one -- the corner radius, the border, the clip -- this differs
    // by far more than one.
    var gpu = try openGpu();
    defer gpu.deinit();

    const w = 160;
    const h = 120;
    var t = try ui.Tree.init(testing.allocator);
    defer t.deinit();
    try buildBranches(&t, w, h);
    var scene = ui.Scene.init(testing.allocator);
    defer scene.deinit();
    _ = try scene.build(&t);

    var target = try mtl.Target.init(&gpu, w * 2, h * 2);
    defer target.deinit();
    var renderer = try mtl.Renderer.initDefault(&gpu);
    defer renderer.deinit();

    const clear = ui.Color.hex(0x202225);
    try renderer.renderScaled(&target, &scene, clear, 2);
    try testing.expect(try worstAgainstReference(target.pixels(), &scene, w * 2, h * 2, 2, clear) <= 2);
}

test "instance buffers are reused round the ring without mixing frames" {
    // Three instance buffers rotate. Rendering more scenes than there are
    // buffers, each different and each checked, catches a slot that is reused
    // before the GPU finished with it or that kept a stale, smaller capacity.
    var gpu = try openGpu();
    defer gpu.deinit();
    var renderer = try mtl.Renderer.initDefault(&gpu);
    defer renderer.deinit();

    const w = 96;
    const h = 64;
    var target = try mtl.Target.init(&gpu, w, h);
    defer target.deinit();
    const clear = ui.Color.hex(0x101010);

    for (0..7) |frame| {
        var t = try ui.Tree.init(testing.allocator);
        defer t.deinit();
        try t.setStyle(t.root(), .{ .axis = .row, .height = .{ .fixed = h }, .padding = 2, .gap = 1, .wrap = true });
        // A growing number of cells, so later frames need bigger buffers than
        // the slot they land in was first given.
        const cells = 3 + frame * 40;
        for (0..cells) |i| {
            const e = try t.appendChild(t.root(), .{ .width = .{ .fixed = 5 }, .height = .{ .fixed = 5 }, .flex_shrink = 0 });
            t.setPaint(e, .{ .background = ui.Color.rgba(@intCast((i * 37 + frame * 11) & 0xFF), 0x80, @intCast(frame * 30), 0xFF) });
        }
        t.layout(.{ .w = w, .h = h });
        var scene = ui.Scene.init(testing.allocator);
        defer scene.deinit();
        _ = try scene.build(&t);

        try renderer.render(&target, &scene, clear);
        try testing.expect(try worstAgainstReference(target.pixels(), &scene, w, h, 1, clear) <= 2);
    }
}

test "an opaque glyph is bit-exact, not merely close" {
    // The Vulkan test of the same name, against Metal: a glyph's coverage is a
    // byte read from the atlas, so where it is 255 and the colour is opaque
    // both sides write the source colour and nothing else, and any difference
    // means they read different texels. The atlas is a diagonal so that
    // transposed, off-by-one or ignored texel coordinates cannot pass.
    var gpu = try openGpu();
    defer gpu.deinit();

    var pixels: [16]u8 = @splat(0);
    for (0..4) |i| pixels[i * 4 + i] = 255;
    const atlas: ui.AtlasView = .{ .pixels = &pixels, .w = 4, .h = 4 };

    const w = 12;
    const h = 12;
    const clear = ui.Color.hex(0x101010);
    const fg = ui.Color.hex(0xE0C040);

    var scene = ui.Scene.init(testing.allocator);
    defer scene.deinit();
    try scene.quads.append(testing.allocator, .{
        .x = 3,
        .y = 2,
        .w = 4,
        .h = 4,
        .background = fg.pack(),
        .border_color = 0,
        .border_width = 0,
        .corner_radius = 0,
        .cx = 0,
        .cy = 0,
        .cw = w,
        .ch = h,
        .u0 = 0,
        .v0 = 0,
        .u1 = 4,
        .v1 = 4,
        .flags = .{ .textured = true },
    });

    var fb = try ui.Framebuffer.init(testing.allocator, w, h);
    defer fb.deinit();
    fb.clear(clear);
    ui.raster.drawScene(&fb, &scene, atlas);

    var target = try mtl.Target.init(&gpu, w, h);
    defer target.deinit();
    var renderer = try mtl.Renderer.initDefault(&gpu);
    defer renderer.deinit();
    try renderer.setAtlas(atlas);
    try renderer.render(&target, &scene, clear);

    const got = target.pixels();
    for (0..@as(usize, w) * h) |i| {
        for (0..3) |ch| {
            if (got[i * 4 + ch] != fb.px[i * 4 + ch]) {
                std.debug.print(
                    "  glyph pixel ({d},{d}) channel {d}: gpu {d}, reference {d}\n",
                    .{ i % w, i / w, ch, got[i * 4 + ch], fb.px[i * 4 + ch] },
                );
                return error.GlyphDivergedFromReference;
            }
        }
    }
    for (0..4) |i| {
        const on = (2 + i) * w + (3 + i);
        try testing.expectEqual(fg.r, got[on * 4 + 0]);
        if (i + 1 < 4) {
            const off = (2 + i) * w + (3 + i + 1);
            try testing.expectEqual(clear.r, got[off * 4 + 0]);
        }
    }
}

test "at 2x a glyph shaped for the device lands one texel per device pixel" {
    // The diagonal again, now as a scene built for a Retina display: four
    // texels are two points, and the glyph sits on a half point. The vertex
    // shader scales the quad to whole device pixels and the fragment shader
    // reads one texel each, so the result is bit-exact against the reference
    // drawn from `Quad.scaled` -- the path the macOS window takes.
    var gpu = try openGpu();
    defer gpu.deinit();

    var pixels: [16]u8 = @splat(0);
    for (0..4) |i| pixels[i * 4 + i] = 255;
    const atlas: ui.AtlasView = .{ .pixels = &pixels, .w = 4, .h = 4 };

    const w = 12;
    const h = 12;
    const clear = ui.Color.hex(0x101010);
    const fg = ui.Color.hex(0xE0C040);

    var scene = ui.Scene.init(testing.allocator);
    defer scene.deinit();
    try scene.quads.append(testing.allocator, .{
        .x = 1.5,
        .y = 1,
        .w = 2,
        .h = 2,
        .background = fg.pack(),
        .border_color = 0,
        .border_width = 0,
        .corner_radius = 0,
        .cx = 0,
        .cy = 0,
        .cw = w / 2,
        .ch = h / 2,
        .u0 = 0,
        .v0 = 0,
        .u1 = 4,
        .v1 = 4,
        .flags = .{ .textured = true },
    });

    var fb = try ui.Framebuffer.init(testing.allocator, w, h);
    defer fb.deinit();
    fb.clear(clear);
    for (scene.items()) |q| ui.raster.drawQuad(&fb, q.scaled(2), atlas);

    var target = try mtl.Target.init(&gpu, w, h);
    defer target.deinit();
    var renderer = try mtl.Renderer.initDefault(&gpu);
    defer renderer.deinit();
    try renderer.setAtlas(atlas);
    try renderer.renderScaled(&target, &scene, clear, 2);

    const got = target.pixels();
    try testing.expectEqualSlices(u8, fb.px, got);
    for (0..4) |i| {
        const on = (2 + i) * w + (3 + i);
        try testing.expectEqual(fg.r, got[on * 4 + 0]);
        try testing.expectEqual(fg.r, fb.px[on * 4 + 0]);
    }
}

test "the atlas can be replaced at a different size" {
    var gpu = try openGpu();
    defer gpu.deinit();
    var renderer = try mtl.Renderer.initDefault(&gpu);
    defer renderer.deinit();

    var big: [64 * 32]u8 = @splat(200);
    try renderer.setAtlas(.{ .pixels = &big, .w = 64, .h = 32 });
    try testing.expectEqual(@as(u32, 64), renderer.atlas_w);

    var small: [8 * 8]u8 = @splat(7);
    try renderer.setAtlas(.{ .pixels = &small, .w = 8, .h = 8 });
    try testing.expectEqual(@as(u32, 8), renderer.atlas_w);

    // The same size again reuses the texture and only re-uploads.
    const before = renderer.atlas;
    try renderer.setAtlas(.{ .pixels = &small, .w = 8, .h = 8 });
    try testing.expectEqual(before, renderer.atlas);
}
