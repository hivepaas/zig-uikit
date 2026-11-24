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
//! The third text field is typeable. Keystrokes arrive as `ui.KeyEvent`s in
//! the window's queue, `ui.editing.apply` turns them into edits on a
//! `Document`, and `demo.refreshEditable` reshapes the line and moves the
//! caret. That path is the one thing in this program that is NOT free on an
//! unchanged frame, and the counters say what it costs.
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
    t: *const ui.Tree,
    /// Whether to also write the magnified crop of the editable field. Only
    /// under `--type`, so that the committed image is of a field something
    /// actually typed into and a plain `--capture` does not quietly replace it
    /// with an untouched one.
    crop: bool,
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
    const io = threaded.io();
    var fb: ui.Framebuffer = .{ .gpa = gpa, .w = w, .h = h, .px = rgba };
    try fb.writePng(io, "docs/demo-window.png");

    // And a magnified crop of the editable field, out of the same frame the
    // compositor was handed. The caret is one pixel wide; in a 900x560
    // screenshot it is a claim nobody can check.
    if (crop) if (demo.editable) |ed| {
        const b = t.bounds(ed.field);
        try demo.writeCrop(gpa, io, &fb, .{
            .x = b.x,
            .y = b.y - 30,
            .w = @min(b.w, 420),
            .h = b.h + 30,
        }, 3, "docs/demo-typing.png");
        std.debug.print("wrote docs/demo-typing.png\n", .{});
    };
    std.debug.print(
        "presented frame vs software reference: largest channel difference {d}\nwrote docs/demo-window.png\n\n",
        .{worst},
    );
}

/// A scripted sequence of keystrokes, for `--type`.
///
/// It exists for the same reason `--sweep` does: the per-keystroke cost is the
/// claim this field is making, and a human typing is not a measurement. What
/// it covers is chosen rather than arbitrary -- multi-byte insertion, deletion
/// of a character whose bytes are not one, word movement across a Vietnamese
/// syllable, and typing over a selection -- so a pass means those four things
/// work and not just that the queue drains.
fn typeScript(gpa: std.mem.Allocator) ![]ui.KeyEvent {
    var list: std.ArrayList(ui.KeyEvent) = .empty;
    const ctrl: ui.Mods = .{ .ctrl = true };
    const shift: ui.Mods = .{ .shift = true };

    // Typed one character at a time, as a keyboard delivers it.
    var it = (std.unicode.Utf8View.init(" — thử xoá và chọn") catch unreachable).iterator();
    while (it.nextCodepointSlice()) |ch| try list.append(gpa, ui.KeyEvent.typed(ch));

    // Four characters back off the end; the last of them is multi-byte.
    for (0..4) |_| try list.append(gpa, ui.KeyEvent.named(.backspace));
    // To the start, one word in, then select to the end and type over it.
    try list.append(gpa, ui.KeyEvent.named(.home));
    try list.append(gpa, ui.KeyEvent.named(.right).withMods(ctrl));
    try list.append(gpa, ui.KeyEvent.named(.right).withMods(ctrl));
    try list.append(gpa, ui.KeyEvent.named(.end).withMods(shift));
    try list.append(gpa, ui.KeyEvent.typed("X"));
    try list.append(gpa, ui.KeyEvent.named(.backspace).withMods(ctrl));
    return list.toOwnedSlice(gpa);
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
    var type_test = false;
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--capture")) capture = true;
        if (std.mem.eql(u8, a, "--sweep")) sweep = 180;
        // Feeds `typeScript` into the key queue, a keystroke every few frames,
        // and reports what each one cost.
        if (std.mem.eql(u8, a, "--type")) type_test = true;
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

    // The text the editable field holds. `demo.buildUi` put the same string
    // into the element, which is the one piece of duplication in this
    // arrangement: the document is the truth and the element is a view of it,
    // but the view has to exist before there is anything to drive it.
    var doc = ui.Document.init(gpa);
    defer doc.deinit();
    _ = try doc.insert(.application, demo.editable_initial);

    // The GPU's copy of the atlas is current as of here. Typing a character
    // the font has not rasterised yet changes the atlas, and this is how that
    // is noticed without re-uploading a texture every frame.
    var atlas_gen = fonts.atlas.generation;

    var scene = ui.Scene.init(gpa);
    defer scene.deinit();

    std.debug.print(
        \\{s}
        \\{d}x{d}, {s}{s}
        \\
        \\keyboard: {s}{s}
        \\
        \\move the pointer over the list, type into the third field, Escape to
        \\close; the counters are printed on the way out.
        \\
        \\
    , .{
        gpu.name(),
        swapchain.extent.width,
        swapchain.extent.height,
        if (swapchain.bgra) "B8G8R8A8_UNORM" else "R8G8B8A8_UNORM",
        if (swapchain.bgra) " (BGRA in memory; only the capture reorders)" else "",
        if (win.keyboard == null) "none on this seat" else win.layoutName(),
        if (win.keyboard == null) "" else " layout, repeating after the compositor's delay",
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
    var keystrokes: u64 = 0;
    var unhandled: u64 = 0;
    var edit_ns_total: u64 = 0;
    var edits: u64 = 0;
    var edit_worst_ns: u64 = 0;
    var atlas_uploads: u64 = 0;
    var upload_ns_total: u64 = 0;
    var hot_ns_total: u64 = 0;
    var hot_shapes: u64 = 0;
    var caret_visible = false;

    const script: []ui.KeyEvent = if (type_test) try typeScript(gpa) else &.{};
    defer if (type_test) gpa.free(script);
    var script_at: usize = 0;

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

        // --- the keyboard: an edit, a reshape, and a caret that moves ---
        //
        // Drained in a loop rather than one per frame. A frame at 60 Hz is
        // 16 ms, and a fast typist with key repeat on can put several
        // keystrokes in one; taking one and leaving the rest would make the
        // field lag behind the keyboard by a frame per character.
        if (type_test and script_at < script.len and frames % 4 == 0) {
            win.keys.push(script[script_at]);
            script_at += 1;
        }
        var text_dirty = false;
        while (win.keys.pop()) |ev| {
            if (ev.key == .escape) {
                win.closed = true;
                break;
            }
            const r = ui.editing.apply(&doc, ev, .{}) catch |e| switch (e) {
                // No input method is attached to this document yet, so there
                // is nothing to hold a lock or to be composing. Reported
                // rather than ignored, because if it ever happens it means the
                // text-input path landed and this loop needs to decide what to
                // do about it.
                error.Locked => {
                    std.debug.print("edit refused: the document is locked\n", .{});
                    continue;
                },
                else => return e,
            };
            if (r.handled) keystrokes += 1 else unhandled += 1;
            if (r.edited or r.moved) text_dirty = true;
        }
        if (text_dirty) {
            const e0 = nowNs();
            demo.refreshEditable(&t, &fonts, &doc) catch |e| switch (e) {
                // 512x512 holds thousands of glyphs at this size, so this
                // needs a lot of distinct characters to reach. It is caught
                // rather than propagated because losing the window over it
                // would be a worse answer than a field that stops updating,
                // and because growing the atlas is a decision for whatever
                // owns the tree -- every cached texel coordinate moves.
                error.AtlasFull => std.debug.print("atlas full at {d:.0}% -- text stopped updating\n", .{fonts.atlas.fillRatio() * 100}),
                else => return e,
            };
            const spent = nowNs() - e0;
            // Shaped once more, and timed, only under `--type`.
            //
            // This is here because the first measurement of this field was
            // misleading in a way worth keeping a number against. A keystroke
            // reshapes a fifty-byte line in 12-60 us, and the benchmark says
            // the same shaping costs 2 us. Both are true: the benchmark runs
            // in a tight loop with the font tables, the glyph cache and the
            // scratch buffer all in L1, and a keystroke arrives tens of
            // milliseconds after the last one with all of that evicted. The
            // second shape below is the hot number, measured in the same
            // process on the same line a microsecond after the cold one, so
            // the report carries its own explanation instead of a figure that
            // disagrees with the benchmark for no stated reason.
            if (type_test) {
                const h0 = nowNs();
                _ = try fonts.ui.shape(&fonts.atlas, doc.text());
                hot_ns_total += nowNs() - h0;
                hot_shapes += 1;
            }
            edit_ns_total += spent;
            edit_worst_ns = @max(edit_worst_ns, spent);
            edits += 1;

            // Timed separately, because it is a different cost with a
            // different fix, and folding the two into one number would have
            // hidden which of them to work on.
            //
            // It costs 1.7-2.1 ms, and measuring where that goes changed the
            // answer: staging the whole 256 KB image is 11-80 us, and the rest
            // is `vkQueueSubmit` plus a fence wait, serialised behind a
            // swapchain presenting at 60 Hz. So uploading only the new glyph's
            // rectangle -- the obvious fix -- would save nothing. What this
            // wants is the transfer recorded into the frame's own command
            // buffer instead of a synchronous round trip through the queue,
            // which is a swapchain change and not a text one.
            if (fonts.atlas.generation != atlas_gen) {
                const up0 = nowNs();
                try renderer.setAtlas(fonts.atlas.view());
                atlas_gen = fonts.atlas.generation;
                atlas_uploads += 1;
                upload_ns_total += nowNs() - up0;
            }
        }
        // A window without keyboard focus draws no caret. A paint change, so
        // it costs no layout -- which is the whole point of `Paint` being
        // separate from `Style`, demonstrated on the smallest possible case.
        if (demo.editable) |ed| {
            const want_caret = win.focused;
            if (want_caret != caret_visible) {
                caret_visible = want_caret;
                t.setPaint(ed.caret.box, .{
                    .background = if (want_caret) demo.caret_color else ui.Color.rgba(0, 0, 0, 0),
                });
            }
        }

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
            try checkPresentedFrame(gpa, &swapchain, &scene, fonts.atlas.view(), &t, type_test);
            capture = false;
            if (sweep == 0) break;
        }
        if (sweep > 0 and frames >= sweep) break;
        // Long enough after the last scripted keystroke for the frame it
        // produced to have been presented.
        if (type_test and script_at >= script.len and win.keys.len() == 0 and frames >= script.len * 4 + 20) break;
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
        \\{d} keystrokes handled, {d} left for the application
        \\  keys dropped because the queue filled   {d}
        \\  {d} edits: mean {d} ns each, worst {d} ns
        \\  the same line shaped again, hot         {d} ns ({d} samples)
        \\  atlas re-uploads                        {d}, mean {d} ns each
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
        keystrokes,
        unhandled,
        win.keys.dropped,
        edits,
        if (edits == 0) 0 else edit_ns_total / edits,
        edit_worst_ns,
        if (hot_shapes == 0) 0 else hot_ns_total / hot_shapes,
        hot_shapes,
        atlas_uploads,
        if (atlas_uploads == 0) 0 else upload_ns_total / atlas_uploads,
    });
}
