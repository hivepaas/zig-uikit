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
//!
//! The third text field is typeable, through the Mac's own text system: the
//! window attaches a `Document` as its text target, and AppKit's key bindings
//! and input methods edit it (see `platform/macos.zig`). Two scripted runs
//! drive it through the whole path with synthesised `NSEvent`s:
//!
//!   - `--type` sends the keystrokes the Wayland demo's `--type` sends, in Mac
//!     chords -- Cmd+Left, Option+Right, Option+Backspace -- with the ABC
//!     layout selected, and checks the document against the same edits made
//!     with Linux chords through `editing.apply`. Two roads, one answer.
//!   - `--telex` selects Apple's Vietnamese Simple Telex input method and
//!     types `tieengs Vieetj` as key codes, so that the input method -- not
//!     this program -- decides what they mean, and checks that the document
//!     ends up holding `tiếng Việt`. It restores the input source it found.

const std = @import("std");
const ui = @import("zig-uikit");
const mtl = @import("zig-uikit-metal");
const mac = @import("zig-uikit-macos");
const demo = @import("demo.zig");

const bg = ui.Color.hex(0x1E1F22);
const hover_tint = ui.Color.hex(0x3D4450);

/// Compares the frame the window server was actually handed against the
/// software reference, and writes it out.
fn checkPresentedFrame(
    gpa: std.mem.Allocator,
    swapchain: *mtl.Swapchain,
    scene: *const ui.Scene,
    atlas: ui.AtlasView,
    t: *const ui.Tree,
    /// A magnified crop of the editable field, written only by `--telex` so
    /// that a plain `--capture` does not replace it with an untouched field:
    /// the input method's work, mid-word, as the window server was handed it.
    crop: ?[]const u8,
) !void {
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
    const io = threaded.io();
    var fb: ui.Framebuffer = .{ .gpa = gpa, .w = w, .h = h, .px = rgba };
    try fb.writePng(io, "docs/demo-window-macos.png");
    if (crop) |path| if (demo.editable) |ed| {
        // In pixels: the frame is two pixels per point, and the crop is of
        // the frame.
        const s = swapchain.scale;
        const b = t.bounds(ed.field);
        try demo.writeCrop(gpa, io, &fb, .{
            .x = b.x * s,
            .y = b.y * s,
            .w = @min(b.w, 360) * s,
            .h = b.h * s,
        }, 1, path);
        std.debug.print("wrote {s}\n", .{path});
    };
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

/// One keystroke for `sendKey`: the virtual key code, what it types, what it
/// types with no modifiers, and the modifiers.
const Stroke = struct {
    code: u16,
    chars: []const u8,
    bare: []const u8,
    mods: mac.Window.KeyMods = .{},
};

const kVK_Delete = 51;
const kVK_LeftArrow = 123;
const kVK_RightArrow = 124;
const kVK_Space = 49;
const left_arrow = "\u{F702}";
const right_arrow = "\u{F703}";
const backspace = "\x7f";

/// The ANSI key code for a lower-case letter: what an input method reads,
/// rather than the character, to know which key it was.
fn letterCode(ch: u8) u16 {
    const codes = "asdfhgzxcv?bqweryt";
    if (std.mem.indexOfScalar(u8, codes, ch)) |i| return @intCast(i);
    return switch (ch) {
        'o' => 31,
        'u' => 32,
        'i' => 34,
        'p' => 35,
        'l' => 37,
        'j' => 38,
        'k' => 40,
        'n' => 45,
        'm' => 46,
        else => 0,
    };
}

/// The Mac half of `--type`, in Mac chords. The keystrokes of the Wayland
/// demo's script, one for one; see `linuxEquivalent`.
fn typeScript(gpa: std.mem.Allocator) ![]Stroke {
    var list: std.ArrayList(Stroke) = .empty;
    var it = (std.unicode.Utf8View.init(" — thử xoá và chọn") catch unreachable).iterator();
    // Characters a US keyboard cannot type are sent as what they are, with no
    // key code: the ABC layout passes them through as text, which is what a
    // character palette or a dictation result looks like to a view.
    while (it.nextCodepointSlice()) |ch| try list.append(gpa, .{ .code = if (ch.len == 1) letterCode(ch[0]) else 0, .chars = ch, .bare = ch });
    for (0..4) |_| try list.append(gpa, .{ .code = kVK_Delete, .chars = backspace, .bare = backspace });
    try list.append(gpa, .{ .code = kVK_LeftArrow, .chars = left_arrow, .bare = left_arrow, .mods = .{ .command = true, .function = true } });
    try list.append(gpa, .{ .code = kVK_RightArrow, .chars = right_arrow, .bare = right_arrow, .mods = .{ .option = true, .function = true } });
    try list.append(gpa, .{ .code = kVK_RightArrow, .chars = right_arrow, .bare = right_arrow, .mods = .{ .option = true, .function = true } });
    try list.append(gpa, .{ .code = kVK_RightArrow, .chars = right_arrow, .bare = right_arrow, .mods = .{ .command = true, .shift = true, .function = true } });
    try list.append(gpa, .{ .code = 7, .chars = "X", .bare = "x", .mods = .{ .shift = true } });
    try list.append(gpa, .{ .code = kVK_Delete, .chars = backspace, .bare = backspace, .mods = .{ .option = true } });
    return list.toOwnedSlice(gpa);
}

/// What `--type` should leave in the document: the Wayland demo's script,
/// with Linux chords, applied by `editing.apply` with no window at all.
fn linuxEquivalent(gpa: std.mem.Allocator) !ui.Document {
    var doc = ui.Document.init(gpa);
    errdefer doc.deinit();
    _ = try doc.insert(.application, demo.editable_initial);
    const ctrl: ui.Mods = .{ .ctrl = true };
    var it = (std.unicode.Utf8View.init(" — thử xoá và chọn") catch unreachable).iterator();
    while (it.nextCodepointSlice()) |ch| _ = try ui.editing.apply(&doc, ui.KeyEvent.typed(ch), .{});
    for (0..4) |_| _ = try ui.editing.apply(&doc, ui.KeyEvent.named(.backspace), .{});
    _ = try ui.editing.apply(&doc, ui.KeyEvent.named(.home), .{});
    _ = try ui.editing.apply(&doc, ui.KeyEvent.named(.right).withMods(ctrl), .{});
    _ = try ui.editing.apply(&doc, ui.KeyEvent.named(.right).withMods(ctrl), .{});
    _ = try ui.editing.apply(&doc, ui.KeyEvent.named(.end).withMods(.{ .shift = true }), .{});
    _ = try ui.editing.apply(&doc, ui.KeyEvent.typed("X"), .{});
    _ = try ui.editing.apply(&doc, ui.KeyEvent.named(.backspace).withMods(ctrl), .{});
    return doc;
}

/// `--telex`: to the end of the field, then ` tieengs Vieetj ` as key codes
/// and nothing else. The characters come from the keyboard layout and their
/// meaning from the input method; see `Window.sendKeyCode`.
fn telexScript(gpa: std.mem.Allocator) ![]Stroke {
    var list: std.ArrayList(Stroke) = .empty;
    // Navigation goes through `sendKey`, with characters, because a
    // Core Graphics arrow made here does not reach the key bindings at all --
    // `doCommandBySelector:` is never called -- and the caret is already at
    // the end anyway. The letters are what the input method is for.
    try list.append(gpa, .{ .code = kVK_RightArrow, .chars = right_arrow, .bare = right_arrow, .mods = .{ .command = true, .function = true } });
    for (" tieengs Vieetj ") |ch| try list.append(gpa, .{
        .code = if (ch == ' ') kVK_Space else letterCode(std.ascii.toLower(ch)),
        .chars = "",
        .bare = "",
        .mods = .{ .shift = std.ascii.isUpper(ch) },
    });
    return list.toOwnedSlice(gpa);
}

/// The input method's caret rectangle callback: where a byte range of the
/// editable field is, which the window converts to screen coordinates.
fn rangeRect(ctx: ?*anyopaque, r: ui.Range) ui.Rect {
    const t: *const ui.Tree = @ptrCast(@alignCast(ctx.?));
    return demo.editableRangeRect(t, r);
}

fn viewport(win: *const mac.Window) ui.Size {
    return .{ .w = @floatFromInt(win.width), .h = @floatFromInt(win.height) };
}

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var capture = false;
    var sweep: u64 = 0;
    var type_test = false;
    var telex = false;
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--capture")) capture = true;
        if (std.mem.eql(u8, a, "--sweep")) sweep = 180;
        if (std.mem.eql(u8, a, "--type")) type_test = true;
        if (std.mem.eql(u8, a, "--telex")) telex = true;
    }
    // The capture of a composition in progress needs the swapchain to be
    // capturable.
    if (telex) capture = true;

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

    // The text the editable field holds, attached to the window so that the
    // Mac's text system edits it directly.
    var doc = ui.Document.init(gpa);
    defer doc.deinit();
    _ = try doc.insert(.application, demo.editable_initial);
    win.setTextTarget(.{ .doc = &doc, .rect = rangeRect, .ctx = &t });
    defer win.setTextTarget(null);
    var atlas_gen = fonts.atlas.generation;

    // A scripted run needs a known input source, and must give the user's
    // back. `--type` wants a plain layout so that letters are letters.
    var source_buf: [256]u8 = undefined;
    var restore_source: ?[]const u8 = null;
    if (type_test or telex) {
        const want: [*:0]const u8 = if (telex)
            "com.apple.inputmethod.VietnameseIM.VietnameseSimpleTelex"
        else
            "com.apple.keylayout.ABC";
        restore_source = win.selectInputSource(want, &source_buf) orelse {
            std.debug.print("input source {s} is not enabled in System Settings\n", .{want});
            return error.InputSourceUnavailable;
        };
        std.debug.print("input source {s} (was {s})\n", .{ want, restore_source.? });
    }
    defer if (restore_source) |was| {
        var z: [257]u8 = undefined;
        @memcpy(z[0..was.len], was);
        z[was.len] = 0;
        var ignored: [256]u8 = undefined;
        _ = win.selectInputSource(z[0..was.len :0], &ignored);
    };

    const script: []Stroke = if (type_test) try typeScript(gpa) else if (telex) try telexScript(gpa) else &.{};
    defer if (script.len > 0) gpa.free(script);
    var script_at: usize = 0;
    // `--telex` captures the frame after this keystroke: `Vieet` typed, which
    // the input method has already rewritten to `Viêt` in the document, before
    // the `j` and the space.
    const telex_capture_after: usize = 1 + " tieengs Vieet".len;
    var keystroke_ns_total: u64 = 0;
    var keystroke_ns_worst: u64 = 0;
    var unhandled: u64 = 0;
    var atlas_uploads: u64 = 0;
    var caret_visible = true;
    var capture_pending = false;
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
                try demo.refreshEditable(&t, &fonts, &doc);
                try renderer.setAtlas(fonts.atlas.view());
                atlas_gen = fonts.atlas.generation;
                scene.setPixelScale(win.scale);
            }
            t.layout(viewport(win));
            relayouts += 1;
            // The highlighted element may no longer be under the pointer, and
            // its saved paint predates the relayout; forget it.
            hovered = 0;
        }

        const t0 = nowNs();

        // --- the keyboard ---
        //
        // A scripted keystroke goes through AppKit synchronously: by the time
        // `sendKey` returns, the input method has run and the document holds
        // the result. It is timed because that is the per-keystroke cost of
        // the whole Mac text system, input method included.
        if (script_at < script.len and frames % 4 == 0 and frames > 0) {
            const st = script[script_at];
            const k0 = nowNs();
            if (st.chars.len == 0) win.sendKeyCode(st.code, st.mods) else win.sendKey(st.code, st.chars, st.bare, st.mods);
            const k = nowNs() - k0;
            keystroke_ns_total += k;
            keystroke_ns_worst = @max(keystroke_ns_worst, k);
            script_at += 1;
            if (telex and script_at == telex_capture_after) {
                swapchain.capture_request = true;
                capture_pending = true;
            }
        }
        while (win.keys.pop()) |ev| {
            if (ev.key == .escape) {
                win.closed = true;
                break;
            }
            unhandled += 1;
        }
        if (win.text_changed) {
            win.text_changed = false;
            demo.refreshEditable(&t, &fonts, &doc) catch |e| switch (e) {
                error.AtlasFull => std.debug.print("atlas full -- text stopped updating\n", .{}),
                else => return e,
            };
            if (fonts.atlas.generation != atlas_gen) {
                try renderer.setAtlas(fonts.atlas.view());
                atlas_gen = fonts.atlas.generation;
                atlas_uploads += 1;
            }
            win.textGeometryChanged();
        }
        if (demo.editable) |ed| {
            if (win.focused != caret_visible) {
                caret_visible = win.focused;
                t.setPaint(ed.caret.box, .{
                    .background = if (caret_visible) demo.caret_color else ui.Color.rgba(0, 0, 0, 0),
                });
            }
        }

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
        if (capture and !telex and frames == 9) {
            swapchain.capture_request = true;
            capture_pending = true;
        }

        const presented = try swapchain.drawAndPresent(&renderer, &scene, bg);
        if (!presented) {
            skipped += 1;
            continue;
        }

        // The request is cleared by the present that honoured it.
        if (capture_pending and !swapchain.capture_request) {
            capture_pending = false;
            try checkPresentedFrame(gpa, &swapchain, &scene, fonts.atlas.view(), &t, if (telex) "docs/demo-typing-macos.png" else null);
            capture = false;
            if (sweep == 0 and script.len == 0) break;
        }
        if (sweep > 0 and frames >= sweep) break;
        if (script.len > 0 and script_at >= script.len and frames >= script.len * 4 + 20) break;
    }

    if (script.len > 0) {
        const n = win.ime;
        std.debug.print(
            \\
            \\{d} scripted keystrokes through AppKit: mean {d} ns, worst {d} ns
            \\  insertText            {d} ({d} of them replacing text already there)
            \\  setMarkedText         {d} (and {d} cancelling)
            \\  unmarkText            {d}
            \\  editing commands      {d}, refused {d}
            \\  passed on as keys     {d} ({d} reached the application)
            \\  substring queries     {d}, rectangle queries {d}
            \\  atlas re-uploads      {d}
            \\document: "{s}"
            \\
        , .{
            script.len,
            keystroke_ns_total / script.len,
            keystroke_ns_worst,
            n.inserted,
            n.replaced,
            n.marked,
            n.cancelled,
            n.unmarked,
            n.commands,
            n.refused,
            n.passed_on,
            unhandled,
            n.substring_queries,
            n.rect_queries,
            atlas_uploads,
            doc.text(),
        });
        if (type_test) {
            var want = try linuxEquivalent(gpa);
            defer want.deinit();
            const same = std.mem.eql(u8, want.text(), doc.text()) and
                want.anchor == doc.anchor and want.focus == doc.focus;
            std.debug.print("the same edits with Linux chords through editing.apply: \"{s}\" -- {s}\n", .{
                want.text(), if (same) "identical, selection included" else "DIFFERENT",
            });
            if (!same) return error.TypeScriptDiverged;
        }
        if (telex) {
            const want = demo.editable_initial ++ " tiếng Việt ";
            const ok = std.mem.eql(u8, want, doc.text());
            std.debug.print("expected \"{s}\" -- {s}\n", .{ want, if (ok) "composed" else "DIFFERENT" });
            if (!ok) return error.TelexDiverged;
        }
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
