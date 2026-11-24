//! Renders the demo interface twice -- once through the Vulkan backend and
//! once through the software reference rasteriser -- and compares every pixel.
//!
//! This is the test that the GPU shader and `src/raster.zig` have not drifted.
//! They are two implementations of one signed distance field, written in two
//! languages, and the only thing stopping them disagreeing is this comparison.
//!
//! They are not expected to be bit-identical, and the report says by how much
//! they differ rather than passing or failing on exact equality. Two reasons,
//! both real: the reference blends the fill and then the border as separate
//! eight-bit steps while the shader folds them into one premultiplied source,
//! so a pixel on the seam rounds differently; and float-to-unorm conversion is
//! the driver's, not ours.

const std = @import("std");
const ui = @import("zig-uikit");
const vk = @import("zig-uikit-vulkan");
const demo = @import("demo.zig");

const width = 900;
const height = 560;

fn loadSpv(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch null;
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var t = try ui.Tree.init(gpa);
    defer t.deinit();
    try demo.buildUi(&t);
    t.layout(.{ .w = width, .h = height });

    var scene = ui.Scene.init(gpa);
    defer scene.deinit();
    const stats = try scene.build(&t);

    const bg = ui.Color.hex(0x1E1F22);

    // --- the reference ---
    var fb = try ui.Framebuffer.init(gpa, width, height);
    defer fb.deinit();
    fb.clear(bg);
    ui.raster.drawScene(&fb, &scene);

    // --- the GPU ---
    var gpu = vk.Gpu.init(gpa, .{}) catch |e| {
        var buf: [128]u8 = undefined;
        std.debug.print("no usable Vulkan device: {s} ({s})\n", .{ @errorName(e), vk.lastErrorMessage(&buf) });
        return e;
    };
    defer gpu.deinit();
    std.debug.print("device: {s}{s}\n{d} quads, {d} bytes uploaded with no repacking\n\n", .{
        gpu.name(),
        if (gpu.is_software) " (software)" else "",
        stats.emitted,
        scene.items().len * @sizeOf(ui.Quad),
    });

    var target = try vk.Target.init(&gpu, width, height);
    defer target.deinit();

    const vert = loadSpv(gpa, io, "src/gpu/shaders/quad.vert.spv");
    const frag = loadSpv(gpa, io, "src/gpu/shaders/quad.frag.spv");
    defer if (vert) |v| gpa.free(v);
    defer if (frag) |f| gpa.free(f);

    if (vert == null or frag == null) {
        // Everything except the pipeline can still be exercised, and when a
        // frame comes out wrong the first question is whether the problem is
        // the shader or everything around it. So this path is not a stub: it
        // checks the clear, both layout transitions, the copy and the readback.
        std.debug.print(
            \\compiled shaders not found, so this is the clear-only path:
            \\the device, the offscreen image, both layout transitions, the
            \\image-to-buffer copy and the readback, with no pipeline.
            \\see src/gpu/shaders/README.md to build them.
            \\
            \\
        , .{});
        try vk.clearOnly(&gpu, &target, bg);
        const px = target.pixels();
        var wrong: usize = 0;
        for (0..@as(usize, width) * height) |i| {
            if (px[i * 4] != bg.r or px[i * 4 + 1] != bg.g or px[i * 4 + 2] != bg.b) wrong += 1;
        }
        std.debug.print("clear + readback: {d} of {d} pixels wrong\n", .{ wrong, @as(usize, width) * height });
        if (wrong != 0) return error.ClearReadbackWrong;
        return;
    }

    var renderer = vk.Renderer.init(&gpu, vert.?, frag.?) catch |e| {
        var buf: [128]u8 = undefined;
        std.debug.print("pipeline: {s} ({s})\n", .{ @errorName(e), vk.lastErrorMessage(&buf) });
        return e;
    };
    defer renderer.deinit();
    try renderer.render(&target, &scene, bg);

    // --- compare ---
    const gpu_px = target.pixels();
    var max_delta: u32 = 0;
    var over1: usize = 0;
    var over8: usize = 0;
    var sum: u64 = 0;
    var diff = try gpa.alloc(u8, @as(usize, width) * height * 4);
    defer gpa.free(diff);
    for (0..@as(usize, width) * height) |i| {
        var worst: u32 = 0;
        for (0..3) |ch| {
            const a = gpu_px[i * 4 + ch];
            const b = fb.px[i * 4 + ch];
            const d = if (a > b) a - b else b - a;
            worst = @max(worst, d);
        }
        sum += worst;
        max_delta = @max(max_delta, worst);
        if (worst > 1) over1 += 1;
        if (worst > 8) over8 += 1;
        // Amplified, because a difference of 3 in 255 is invisible and is
        // exactly the kind that matters here.
        const v: u8 = @intCast(@min(255, worst * 16));
        diff[i * 4 + 0] = v;
        diff[i * 4 + 1] = v;
        diff[i * 4 + 2] = v;
        diff[i * 4 + 3] = 255;
    }
    const total = @as(usize, width) * height;
    std.debug.print(
        \\GPU vs software reference, {d} pixels:
        \\  largest channel difference   {d}
        \\  mean channel difference      {d:.4}
        \\  pixels differing by > 1      {d} ({d:.3}%)
        \\  pixels differing by > 8      {d} ({d:.3}%)
        \\
    , .{
        total,
        max_delta,
        @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(total)),
        over1, 100 * @as(f64, @floatFromInt(over1)) / @as(f64, @floatFromInt(total)),
        over8, 100 * @as(f64, @floatFromInt(over8)) / @as(f64, @floatFromInt(total)),
    });

    try writePng(gpa, io, gpu_px, "docs/demo-gpu.png");
    try writePng(gpa, io, diff, "docs/demo-diff.png");
    std.debug.print("wrote docs/demo-gpu.png and docs/demo-diff.png\n", .{});
}

fn writePng(gpa: std.mem.Allocator, io: std.Io, rgba: []const u8, path: []const u8) !void {
    var fb: ui.Framebuffer = .{ .gpa = gpa, .w = width, .h = height, .px = @constCast(rgba) };
    try fb.writePng(io, path);
}
