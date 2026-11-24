//! Tests that need a Vulkan device, kept out of `zig build test` on purpose.
//!
//! Each one skips rather than fails when there is no device, so that running
//! them on a machine without a GPU reports "skipped" instead of a red build
//! that means nothing.

const std = @import("std");
const testing = std.testing;
const ui = @import("zig-uikit");
const vk = @import("vulkan.zig");

fn openGpu() !vk.Gpu {
    return vk.Gpu.init(testing.allocator, .{}) catch return error.SkipZigTest;
}

test "a device can be opened and reports a name" {
    var gpu = try openGpu();
    defer gpu.deinit();
    try testing.expect(gpu.name().len > 0);
    try testing.expect(gpu.device != null);
    try testing.expect(gpu.queue != null);
}

test "clear and read back returns exactly the clear colour" {
    var gpu = try openGpu();
    defer gpu.deinit();
    var target = try vk.Target.init(&gpu, 64, 48);
    defer target.deinit();

    const c = ui.Color.rgba(0x33, 0x66, 0x99, 0xFF);
    try vk.clearOnly(&gpu, &target, c);

    const px = target.pixels();
    try testing.expectEqual(@as(usize, 64 * 48 * 4), px.len);
    for (0..64 * 48) |i| {
        try testing.expectEqual(c.r, px[i * 4 + 0]);
        try testing.expectEqual(c.g, px[i * 4 + 1]);
        try testing.expectEqual(c.b, px[i * 4 + 2]);
    }
}

test "a target can be resized by making another one" {
    var gpu = try openGpu();
    defer gpu.deinit();
    for ([_]u32{ 1, 17, 256 }) |n| {
        var target = try vk.Target.init(&gpu, n, n);
        defer target.deinit();
        try vk.clearOnly(&gpu, &target, ui.Color.white);
        try testing.expectEqual(@as(u8, 255), target.pixels()[0]);
    }
}

test "a shader module is rejected before Vulkan sees it" {
    var gpu = try openGpu();
    defer gpu.deinit();
    // Too short, and the right length with the wrong magic number: two ways
    // for a build step to hand over a file that is not SPIR-V. A length that is
    // not a multiple of four is the third, and it is also rejected.
    const short: [4]u8 align(4) = .{ 1, 2, 3, 4 };
    try testing.expectError(vk.Error.ShaderRejected, vk.Renderer.init(&gpu, &short, &short));
    const zeros: [32]u8 align(4) = @splat(0);
    try testing.expectError(vk.Error.ShaderRejected, vk.Renderer.init(&gpu, &zeros, &zeros));
    const odd: [33]u8 align(4) = @splat(0);
    try testing.expectError(vk.Error.ShaderRejected, vk.Renderer.init(&gpu, &odd, &odd));
}

test "the GPU renders what the software reference renders" {
    // The one test that guards the real duplication in this design: the signed
    // distance field exists twice, once in GLSL and once in Zig. They are not
    // expected to be bit-identical -- the reference blends fill and border as
    // two eight-bit steps where the shader folds them into one premultiplied
    // source -- so this bounds the disagreement rather than forbidding it.
    var gpu = try openGpu();
    defer gpu.deinit();

    const w = 160;
    const h = 120;

    var t = try ui.Tree.init(testing.allocator);
    defer t.deinit();
    t.setPaint(t.root(), .{ .background = ui.Color.hex(0x202225) });
    try t.setStyle(t.root(), .{ .axis = .col, .padding = 10, .gap = 8, .align_items = .stretch });

    // A plain fill, a rounded fill, a thick border, and a clipped overflow:
    // every branch the fragment shader has.
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
        // Without this the overflowing child sizes to its own content, which
        // is nothing, and is culled for being zero-wide rather than clipped.
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

    var scene = ui.Scene.init(testing.allocator);
    defer scene.deinit();
    const stats = try scene.build(&t);
    try testing.expectEqual(@as(u32, 6), stats.emitted);

    const clear = ui.Color.hex(0x202225);
    var fb = try ui.Framebuffer.init(testing.allocator, w, h);
    defer fb.deinit();
    fb.clear(clear);
    ui.raster.drawScene(&fb, &scene);

    var target = try vk.Target.init(&gpu, w, h);
    defer target.deinit();
    var renderer = try vk.Renderer.initDefault(&gpu);
    defer renderer.deinit();
    try renderer.render(&target, &scene, clear);

    const got = target.pixels();
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
    if (worst > 2) {
        std.debug.print(
            "  GPU and reference differ by {d} at pixel ({d},{d})\n",
            .{ worst, worst_at % w, worst_at / w },
        );
        return error.RendererDivergedFromReference;
    }
}
