//! The demo interface in a real window, on the GPU.
//!
//! The point of this program is a counter. Move the pointer over the list and
//! the row under it highlights; resize the window and the layout recomputes.
//! When it exits it reports how many frames did any layout work at all, which
//! is the claim the whole toolkit is built on, observed on a running
//! application rather than in a benchmark harness:
//!
//!   - hovering changes `Paint`, so it does no layout work and no allocation
//!   - resizing changes the viewport, so it does a full layout
//!   - a frame where the pointer did not move does nothing on the CPU at all,
//!     and the scene build returns after one integer comparison
//!
//! Frame pacing comes from FIFO present, so the loop runs at the display's
//! refresh rate without a sleep anywhere in it.

const std = @import("std");
const ui = @import("zig-uikit");
const vk = @import("zig-uikit-vulkan");
const wl = @import("zig-uikit-wayland");
const demo = @import("demo.zig");

const bg = ui.Color.hex(0x1E1F22);
const hover_tint = ui.Color.hex(0x3D4450);

/// Compares the frame the compositor was actually given against the software
/// reference, and writes it out.
///
/// The offscreen comparison in `gpu_demo.zig` cannot do this: it never touches
/// a swapchain, so it says nothing about the surface format, the extent or the
/// channel order. Those are exactly the things that go wrong once a window is
/// involved, and they go wrong in ways that look like a palette mistake rather
/// than a crash.
fn checkPresentedFrame(
    gpa: std.mem.Allocator,
    swapchain: *vk.Swapchain,
    scene: *const ui.Scene,
    atlas: ui.AtlasView,
) !void {
    const w = swapchain.extent.width;
    const h = swapchain.extent.height;

    const rgba = try swapchain.captureRgba(gpa);
    defer gpa.free(rgba);

    var reference = try ui.Framebuffer.init(gpa, w, h);
    defer reference.deinit();
    reference.clear(bg);
    ui.raster.drawScene(&reference, scene, atlas);

    var worst: u32 = 0;
    for (0..@as(usize, w) * h) |i| {
        for (0..3) |ch| {
            const a = rgba[i * 4 + ch];
            const b = reference.px[i * 4 + ch];
            const d: u32 = if (a > b) a - b else b - a;
            worst = @max(worst, d);
        }
    }

    var threaded: std.Io.Threaded = .init_single_threaded;
    var fb: ui.Framebuffer = .{ .gpa = gpa, .w = w, .h = h, .px = rgba };
    try fb.writePng(threaded.io(), "docs/demo-window.png");
    std.debug.print(
        "presented frame vs software reference: largest channel difference {d}\nwrote docs/demo-window.png\n\n",
        .{worst},
    );
}

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    // `--capture` presents a few frames, copies the one that was actually put
    // on the screen out of the swapchain, writes it and exits. It is how the
    // window path gets checked at all: the offscreen comparison says nothing
    // about the swapchain's format, extent or channel order.
    //
    // `--sweep` drives a synthetic pointer down the list for a fixed number of
    // frames and exits with the counters. It exists because the counters are
    // the point of this program and a human moving a mouse is not a
    // measurement.
    var capture = false;
    var sweep: u64 = 0;
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--capture")) capture = true;
        if (std.mem.eql(u8, a, "--sweep")) sweep = 180;
    }

    var win = try wl.Window.open(gpa, "zig-uikit", 900, 560);
    defer win.close();

    var gpu = try vk.Gpu.init(gpa, .{ .present_to = win.display });
    defer gpu.deinit();

    const surface = try vk.createWaylandSurface(&gpu, win.display, win.surface.?);
    var swapchain = try vk.Swapchain.init(gpa, &gpu, surface, win.width, win.height);
    defer swapchain.deinit();

    var renderer = try vk.Renderer.initDefault(&gpu);
    defer renderer.deinit();

    var fonts = try demo.Fonts.init(gpa);
    defer fonts.deinit();

    var t = try ui.Tree.init(gpa);
    defer t.deinit();
    try demo.buildUi(&t, &fonts);
    // Uploaded once, after the interface is built, because that is when every
    // glyph it uses is in the atlas. Nothing in the loop adds text, so nothing
    // in the loop touches the atlas; an application that did would call this
    // again when the shaper reported new glyphs.
    try renderer.setAtlas(fonts.atlas.view());
    t.layout(.{
        .w = @floatFromInt(swapchain.extent.width),
        .h = @floatFromInt(swapchain.extent.height),
    });

    var scene = ui.Scene.init(gpa);
    defer scene.deinit();

    std.debug.print(
        \\{s}
        \\{d}x{d}, {s}{s}
        \\
        \\move the pointer over the list; close the window to see the counters.
        \\
        \\
    , .{
        gpu.name(),
        swapchain.extent.width,
        swapchain.extent.height,
        if (swapchain.bgra) "B8G8R8A8_UNORM" else "R8G8B8A8_UNORM",
        if (swapchain.bgra) " (BGRA in memory; only the capture reorders)" else "",
    });

    var hovered: ui.Index = 0;
    var hovered_was: ui.Paint = .{};

    var frames: u64 = 0;
    var frames_with_layout: u64 = 0;
    var frames_with_scene: u64 = 0;
    var relayouts: u64 = 0;
    var cpu_total_ns: u64 = 0;
    var cpu_worst_ns: u64 = 0;
    var idle_frames: u64 = 0;
    var idle_cpu_ns: u64 = 0;

    while (!win.closed) {
        win.pump();
        if (win.closed) break;

        if (win.resized) {
            win.resized = false;
            swapchain.recreate(win.width, win.height) catch |e| {
                if (e == vk.Error.SurfaceHasNoArea) continue;
                return e;
            };
            t.layout(.{
                .w = @floatFromInt(swapchain.extent.width),
                .h = @floatFromInt(swapchain.extent.height),
            });
            relayouts += 1;
            // The hover highlight belongs to an element that may no longer be
            // under the pointer, and its saved paint was captured before the
            // relayout; forget it rather than restore it to the wrong element.
            hovered = 0;
        }

        const t0 = nowNs();

        // --- hover: a paint change and nothing else ---
        var px = win.pointer_x;
        var py = win.pointer_y;
        var inside = win.pointer_inside;
        if (sweep > 0) {
            // Down the middle of the list panel, one row every few frames.
            inside = true;
            px = @as(f32, @floatFromInt(swapchain.extent.width)) * 0.6;
            py = 180 + @as(f32, @floatFromInt(frames % 300));
        }
        const want: ui.Index = if (inside)
            t.hitTest(.{ .x = px, .y = py })
        else
            0;
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

        // A few frames in, so the compositor has settled on a size and the
        // window is actually mapped. Requested and checked in the SAME
        // iteration: requesting it one frame earlier compares the image that
        // was presented against the scene as it is a frame later, which under
        // `--sweep` is a different scene and shows up as a difference of 21
        // rather than of 1.
        if (capture and frames == 9) swapchain.capture_request = true;

        const ok = swapchain.drawAndPresent(&renderer, &scene, bg) catch |e| {
            if (e == vk.Error.SurfaceHasNoArea) continue;
            return e;
        };
        if (!ok) {
            swapchain.recreate(win.width, win.height) catch |e| {
                if (e == vk.Error.SurfaceHasNoArea) continue;
                return e;
            };
            t.layout(.{
                .w = @floatFromInt(swapchain.extent.width),
                .h = @floatFromInt(swapchain.extent.height),
            });
            relayouts += 1;
            hovered = 0;
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
    std.debug.print(
        \\
        \\{d} frames
        \\  frames that did any layout work   {d} ({d:.1}%) -- {d} were window resizes
        \\  frames that rebuilt the scene     {d} ({d:.1}%)
        \\  mean CPU per frame                {d} ns
        \\  worst CPU in one frame            {d} ns
        \\  mean CPU on the {d} frames that changed nothing   {d} ns
        \\
        \\The CPU figure is everything between the pointer moving and the quads
        \\being ready to upload: hit test, layout flush, scene build. Timing the
        \\three separately costs more than the work does -- two more clock reads
        \\per frame moved the mean by 70% -- so the split is measured in
        \\`zig build bench` instead, where it can be amortised.
        \\
    , .{
        frames,
        frames_with_layout,
        100 * @as(f64, @floatFromInt(frames_with_layout)) / @as(f64, @floatFromInt(frames)),
        relayouts,
        frames_with_scene,
        100 * @as(f64, @floatFromInt(frames_with_scene)) / @as(f64, @floatFromInt(frames)),
        cpu_total_ns / frames,
        cpu_worst_ns,
        idle_frames,
        if (idle_frames == 0) 0 else idle_cpu_ns / idle_frames,
    });
}
