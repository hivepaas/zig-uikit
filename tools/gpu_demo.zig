//! Renders the demo interface twice -- once through the GPU backend and once
//! through the software reference rasteriser -- and compares every pixel.
//!
//! The backend is whichever one the target has, Vulkan or Metal, imported as
//! `gpu`. They expose the same offscreen surface for exactly this reason: one
//! comparison program, not one per backend that could quietly stop checking
//! the same thing.
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
//!
//! Text is compared separately, because it has a tighter bound available. A
//! glyph's coverage is a byte fetched from the same atlas on both sides with
//! the same integer arithmetic -- no distance field, no ramp, no filtering --
//! so the two sides agree on *coverage* exactly. What they still round
//! independently is the blend of that coverage into the framebuffer, which is
//! worth one unit. So a glyph pixel differing by more than one would mean the
//! two are addressing different texels, and the breakdown below says so rather
//! than letting it hide in an average over the whole window.
//!
//! Measured on an AMD RADV device, the largest channel difference over the
//! whole demo is 1 of 255 and no pixel differs by more than that. The written
//! difference image is amplified 64x, so a difference of one shows as a visible
//! grey; it is black except along antialiased edges and corners.

const std = @import("std");
const ui = @import("zig-uikit");
const vk = @import("gpu");

/// The Vulkan run writes the file names the README quotes; any other backend
/// writes beside them rather than over them.
const suffix = if (std.mem.eql(u8, vk.backend_name, "vulkan")) "" else "-" ++ vk.backend_name;
const demo = @import("demo.zig");

const width = 900;
const height = 560;

/// Whether this backend can draw a textured quad. Only the Vulkan one has a
/// glyph atlas so far, so on Metal the demo is built with no text in it --
/// drawing a glyph through a shader with no atlas branch would produce a
/// rounded rectangle per letter, which is a picture of a bug rather than a
/// picture of missing text.
const has_text = @hasDecl(vk.Renderer, "setAtlas");

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var fonts: ?demo.Fonts = if (has_text) try demo.Fonts.init(gpa) else null;
    defer if (fonts) |*f| f.deinit();
    const atlas: ?ui.AtlasView = if (fonts) |*f| f.atlas.view() else null;

    var t = try ui.Tree.init(gpa);
    defer t.deinit();
    try demo.buildUi(&t, if (fonts) |*f| f else null);
    t.layout(.{ .w = width, .h = height });

    // Lay out, then wrap the editable field to the width that layout gave it,
    // then lay out again. That is the measure pass this engine does not have,
    // done by hand at the one call site that needs it -- and it is why
    // `buildUi` leaves the field's text on one line: it has no width to wrap
    // to until this has happened.
    var doc = ui.Document.init(gpa);
    defer doc.deinit();
    _ = try doc.insert(.application, demo.editable_initial);
    // Outside the branch, because `demo.editable.wrapped` borrows them and
    // the field outlives any block they could be scoped to.
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    var wg: std.ArrayList(ui.Glyph) = .empty;
    defer wg.deinit(gpa);
    var wl: std.ArrayList(ui.text_layout.Line) = .empty;
    defer wl.deinit(gpa);
    if (fonts) |*f| {
        try demo.refreshEditable(&t, f, &doc, &scratch, &wg, &wl);
        _ = t.flush();
    }

    var scene = ui.Scene.init(gpa);
    defer scene.deinit();
    const stats = try scene.build(&t);

    const bg = ui.Color.hex(0x1E1F22);

    // --- the reference ---
    var fb = try ui.Framebuffer.init(gpa, width, height);
    defer fb.deinit();
    fb.clear(bg);
    ui.raster.drawScene(&fb, &scene, atlas);

    // --- the GPU ---
    var gpu = vk.Gpu.init(gpa, .{}) catch |e| {
        var buf: [128]u8 = undefined;
        std.debug.print("no usable {s} device: {s} ({s})\n", .{ vk.backend_name, @errorName(e), vk.lastErrorMessage(&buf) });
        return e;
    };
    defer gpu.deinit();
    std.debug.print("device: {s}{s}\n{d} quads, {d} bytes uploaded with no repacking\n\n", .{
        gpu.name(),
        if (gpu.is_software) " (software)" else "",
        stats.emitted,
        scene.items().len * @sizeOf(ui.Quad),
    });
    if (fonts) |*f| {
        std.debug.print("{d} of those quads are glyphs, from a {d}x{d} atlas\n\n", .{
            stats.glyphs, f.atlas.w, f.atlas.h,
        });
    } else {
        std.debug.print("no text: this backend has no glyph atlas yet\n\n", .{});
    }

    var target = try vk.Target.init(&gpu, width, height);
    defer target.deinit();

    var renderer = vk.Renderer.initDefault(&gpu) catch |e| {
        var buf: [128]u8 = undefined;
        std.debug.print("pipeline: {s} ({s})\n", .{ @errorName(e), vk.lastErrorMessage(&buf) });
        return e;
    };
    defer renderer.deinit();
    // Metal compiles its shader at run time; say what that costs, since it is
    // the price of the build needing no shader compiler.
    if (@hasField(vk.Renderer, "compile_ns")) {
        std.debug.print("shader compiled at start-up in {d:.1} ms\n\n", .{
            @as(f64, @floatFromInt(renderer.compile_ns)) / 1e6,
        });
    }
    if (atlas) |a| try renderer.setAtlas(a);
    try renderer.render(&target, &scene, bg);

    // --- compare ---
    const gpu_px = target.pixels();

    // Which pixels any glyph quad touched. Built from the scene rather than
    // guessed at from the image, so the breakdown is about the primitive and
    // not about "the parts that look like text".
    const is_text = try gpa.alloc(bool, @as(usize, width) * height);
    defer gpa.free(is_text);
    @memset(is_text, false);
    for (scene.items()) |q| {
        if (!q.flags.textured) continue;
        // Clamped at both ends, because a quad may lie entirely outside the
        // window -- a popover hanging off the edge, or text wider than what
        // holds it -- and `x0..x1` with `x1 < x0` is an integer overflow
        // rather than an empty range. Found by a panic, not by a review.
        const x0: usize = @intFromFloat(std.math.clamp(q.x, 0, @as(f32, width)));
        const y0: usize = @intFromFloat(std.math.clamp(q.y, 0, @as(f32, height)));
        const x1: usize = @max(x0, @as(usize, @intFromFloat(std.math.clamp(q.x + q.w, 0, @as(f32, width)))));
        const y1: usize = @max(y0, @as(usize, @intFromFloat(std.math.clamp(q.y + q.h, 0, @as(f32, height)))));
        for (y0..y1) |y| for (x0..x1) |x| {
            is_text[y * width + x] = true;
        };
    }

    var text_pixels: usize = 0;
    var text_max: u32 = 0;
    var text_over1: usize = 0;
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
        if (is_text[i]) {
            text_pixels += 1;
            text_max = @max(text_max, worst);
            if (worst > 1) text_over1 += 1;
        }
        if (worst > 1) over1 += 1;
        if (worst > 8) over8 += 1;
        // Amplified, because a difference of 3 in 255 is invisible and is
        // exactly the kind that matters here.
        const v: u8 = @intCast(@min(255, worst * 64));
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
        over1,
        100 * @as(f64, @floatFromInt(over1)) / @as(f64, @floatFromInt(total)),
        over8,
        100 * @as(f64, @floatFromInt(over8)) / @as(f64, @floatFromInt(total)),
    });
    std.debug.print(
        \\of which {d} pixels are covered by a glyph:
        \\  largest channel difference   {d}
        \\  glyph pixels differing by > 1 {d}
        \\
    , .{ text_pixels, text_max, text_over1 });

    try writePng(gpa, io, gpu_px, "docs/demo-gpu" ++ suffix ++ ".png");
    try writePng(gpa, io, diff, "docs/demo-diff" ++ suffix ++ ".png");
    std.debug.print("wrote docs/demo-gpu{s}.png and docs/demo-diff{s}.png\n", .{ suffix, suffix });
}

fn writePng(gpa: std.mem.Allocator, io: std.Io, rgba: []const u8, path: []const u8) !void {
    var fb: ui.Framebuffer = .{ .gpa = gpa, .w = width, .h = height, .px = @constCast(rgba) };
    try fb.writePng(io, path);
}
