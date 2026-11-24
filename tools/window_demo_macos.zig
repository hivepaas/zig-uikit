//! The demo interface in a real window on macOS: AppKit, a `CAMetalLayer`, and
//! the Metal backend.
//!
//! The same program as `window_demo.zig`, and the same counter is the point of
//! it: hovering changes `Paint` and must do no layout work, resizing does a
//! full layout, and a frame where nothing moved costs one integer comparison.
//! It is a separate file because the window and swapchain types differ, not
//! because anything it measures does.
//!
//! One thing exists here that the Wayland window does not have: a backing
//! scale factor. The tree is laid out in points and drawn at two pixels per
//! point on a Retina display, so `--capture` compares the presented frame with
//! the reference drawn at the same scale, not at one.
//!
//! Text follows the scale rather than being scaled: the fonts are opened for
//! the window's backing scale (`Fonts.initScaled`), so a 13-point label is
//! shaped and rasterised as a 26-pixel font and laid out as a 13-point one,
//! and the scene snaps glyphs to the device grid. A window dragged to a
//! display with a different scale reopens its fonts and rebuilds its tree.

const std = @import("std");
const ui = @import("zig-uikit");
const mtl = @import("zig-uikit-metal");
const mac = @import("zig-uikit-macos");
const demo = @import("demo.zig");

const bg = ui.Color.hex(0x1E1F22);
const hover_tint = ui.Color.hex(0x3D4450);

/// Compares the frame the window server was actually handed against the
/// software reference, and writes it out.
fn checkPresentedFrame(gpa: std.mem.Allocator, swapchain: *mtl.Swapchain, scene: *const ui.Scene, atlas: ui.AtlasView) !void {
    const w = swapchain.extent.width;
    const h = swapchain.extent.height;

    const rgba = try swapchain.captureRgba(gpa);
    defer gpa.free(rgba);

    var reference = try ui.Framebuffer.init(gpa, w, h);
    defer reference.deinit();
    reference.clear(bg);
    // The same scene scaled the way the vertex shader scales it. `scaled`
    // checks that every glyph already sits on the device grid at its texel
    // size, which is what shaping at the device size guarantees.
    var glyphs: usize = 0;
    for (scene.items()) |q| {
        if (q.flags.textured) glyphs += 1;
        ui.raster.drawQuad(&reference, q.scaled(swapchain.scale), atlas);
    }

    var worst: u32 = 0;
    var over1: usize = 0;
    for (0..@as(usize, w) * h) |i| {
        var px_worst: u32 = 0;
        for (0..3) |ch| {
            const a = rgba[i * 4 + ch];
            const b = reference.px[i * 4 + ch];
            const d: u32 = if (a > b) a - b else b - a;
            px_worst = @max(px_worst, d);
        }
        worst = @max(worst, px_worst);
        if (px_worst > 1) over1 += 1;
    }

    var threaded: std.Io.Threaded = .init_single_threaded;
    var fb: ui.Framebuffer = .{ .gpa = gpa, .w = w, .h = h, .px = rgba };
    try fb.writePng(threaded.io(), "docs/demo-window-macos.png");
    std.debug.print(
        \\presented frame vs software reference, {d}x{d} pixels at scale {d}, {d} glyphs:
        \\  largest channel difference   {d}
        \\  pixels differing by > 1      {d}
        \\wrote docs/demo-window-macos.png
        \\
        \\
    , .{ w, h, swapchain.scale, glyphs, worst, over1 });
}

/// `clock_gettime(MONOTONIC)` on macOS is only microsecond-resolution, which
/// rounds a 300 ns idle frame to 0 or 1000. `CLOCK_UPTIME_RAW` through
/// `clock_gettime_nsec_np` is `mach_absolute_time` scaled to nanoseconds:
/// 41.7 ns ticks on Apple silicon, fine enough for the idle-frame figure.
extern "c" fn clock_gettime_nsec_np(clock: std.c.clockid_t) u64;

fn nowNs() u64 {
    return clock_gettime_nsec_np(.UPTIME_RAW);
}

fn viewport(win: *const mac.Window) ui.Size {
    return .{ .w = @floatFromInt(win.width), .h = @floatFromInt(win.height) };
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var capture = false;
    var sweep: u64 = 0;
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--capture")) capture = true;
        if (std.mem.eql(u8, a, "--sweep")) sweep = 180;
    }

    var win = try mac.Window.open(gpa, "zig-uikit", 900, 560);
    defer win.close();

    var gpu = try mtl.Gpu.init(gpa, .{});
    defer gpu.deinit();

    var swapchain = try mtl.Swapchain.init(&gpu, win.layer, win.pixelWidth(), win.pixelHeight(), win.scale, .{
        .capturable = capture,
    });
    defer swapchain.deinit();

    var renderer = try mtl.Renderer.initDefault(&gpu);
    defer renderer.deinit();

    var fonts = try demo.Fonts.initScaled(gpa, win.scale);
    defer fonts.deinit();
    var fonts_scale = win.scale;

    var t = try ui.Tree.init(gpa);
    defer t.deinit();
    try demo.buildUi(&t, &fonts);
    t.layout(viewport(win));
    // Once, after the tree is built: nothing in the loop adds text, so nothing
    // in the loop touches the atlas, except a change of display below.
    try renderer.setAtlas(fonts.atlas.view());

    var scene = ui.Scene.init(gpa);
    defer scene.deinit();
    scene.setPixelScale(win.scale);

    std.debug.print(
        \\{s}
        \\{d}x{d} points, {d}x{d} pixels at scale {d}, BGRA8Unorm
        \\shader compiled at start-up in {d:.1} ms
        \\
        \\move the pointer over the list; close the window or press Cmd-Q to see the counters.
        \\
        \\
    , .{
        gpu.name(),
        win.width,
        win.height,
        swapchain.extent.width,
        swapchain.extent.height,
        win.scale,
        @as(f64, @floatFromInt(renderer.compile_ns)) / 1e6,
    });

    var hovered: ui.Index = 0;
    var hovered_was: ui.Paint = .{};

    var frames: u64 = 0;
    var frames_with_layout: u64 = 0;
    var frames_with_scene: u64 = 0;
    var relayouts: u64 = 0;
    var skipped: u64 = 0;
    var cpu_total_ns: u64 = 0;
    var cpu_worst_ns: u64 = 0;
    var idle_frames: u64 = 0;
    var idle_cpu_ns: u64 = 0;
    const started = nowNs();

    while (!win.closed) {
        win.pump();
        if (win.closed) break;

        if (win.resized) {
            win.resized = false;
            swapchain.recreate(win.pixelWidth(), win.pixelHeight(), win.scale) catch |e| {
                if (e == mtl.Error.SurfaceHasNoArea) continue;
                return e;
            };
            if (win.scale != fonts_scale) {
                // A different display. The runs in the tree were shaped for
                // the old one and their bitmaps are the wrong size, so the
                // fonts, the atlas and the text all go. The tree is rebuilt
                // rather than re-shaped label by label because the demo keeps
                // no record of which string each label holds.
                fonts.deinit();
                fonts = try demo.Fonts.initScaled(gpa, win.scale);
                fonts_scale = win.scale;
                t.deinit();
                t = try ui.Tree.init(gpa);
                try demo.buildUi(&t, &fonts);
                try renderer.setAtlas(fonts.atlas.view());
                scene.setPixelScale(win.scale);
            }
            t.layout(viewport(win));
            relayouts += 1;
            // The highlighted element may no longer be under the pointer, and
            // its saved paint predates the relayout; forget it.
            hovered = 0;
        }

        const t0 = nowNs();

        var px = win.pointer_x;
        var py = win.pointer_y;
        var inside = win.pointer_inside;
        if (sweep > 0) {
            inside = true;
            px = @as(f32, @floatFromInt(win.width)) * 0.6;
            py = 180 + @as(f32, @floatFromInt(frames % 300));
        }
        const want: ui.Index = if (inside) t.hitTest(.{ .x = px, .y = py }) else 0;
        if (want != hovered) {
            if (hovered != 0) t.setPaint(hovered, hovered_was);
            hovered = want;
            if (hovered != 0) {
                hovered_was = t.paint(hovered);
                var p = hovered_was;
                p.background = hover_tint;
                t.setPaint(hovered, p);
            }
        }

        const layout = t.flush();
        const built = try scene.build(&t);
        const cpu = nowNs() - t0;

        cpu_total_ns += cpu;
        cpu_worst_ns = @max(cpu_worst_ns, cpu);
        frames += 1;
        if (layout.total() > 0) frames_with_layout += 1;
        if (built.rebuilt) frames_with_scene += 1;
        if (layout.total() == 0 and !built.rebuilt) {
            idle_frames += 1;
            idle_cpu_ns += cpu;
        }

        // Requested and checked in the same iteration, for the reason given in
        // `window_demo.zig`: a frame later is a different scene under --sweep.
        if (capture and frames == 9) swapchain.capture_request = true;

        const presented = try swapchain.drawAndPresent(&renderer, &scene, bg);
        if (!presented) {
            skipped += 1;
            continue;
        }

        if (capture and frames == 9) {
            try checkPresentedFrame(gpa, &swapchain, &scene, fonts.atlas.view());
            capture = false;
            if (sweep == 0) break;
        }
        if (sweep > 0 and frames >= sweep) break;
    }

    if (frames == 0) return;
    const elapsed_s = @as(f64, @floatFromInt(nowNs() - started)) / 1e9;
    std.debug.print(
        \\
        \\{d} frames in {d:.2} s ({d:.1} per second; pacing is the display's, there is no sleep)
        \\  frames that did any layout work   {d} ({d:.1}%) -- {d} were window resizes
        \\  frames that rebuilt the scene     {d} ({d:.1}%)
        \\  frames with no drawable           {d}
        \\  mean CPU per frame                {d} ns
        \\  worst CPU in one frame            {d} ns
        \\  mean CPU on the {d} frames that changed nothing   {d} ns
        \\
        \\The CPU figure is hit test, layout flush and scene build: everything
        \\between the pointer moving and the quads being ready to upload.
        \\
    , .{
        frames,
        elapsed_s,
        @as(f64, @floatFromInt(frames)) / elapsed_s,
        frames_with_layout,
        100 * @as(f64, @floatFromInt(frames_with_layout)) / @as(f64, @floatFromInt(frames)),
        relayouts,
        frames_with_scene,
        100 * @as(f64, @floatFromInt(frames_with_scene)) / @as(f64, @floatFromInt(frames)),
        skipped,
        cpu_total_ns / frames,
        cpu_worst_ns,
        idle_frames,
        if (idle_frames == 0) 0 else idle_cpu_ns / idle_frames,
    });
}
