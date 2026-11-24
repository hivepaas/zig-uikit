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
    for (scene.items()) |q| ui.raster.drawQuad(&fb, q.scaled(scale));

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
