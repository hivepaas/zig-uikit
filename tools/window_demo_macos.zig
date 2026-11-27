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
//!
//! `--click` drives the field with the mouse the same way: synthesised
//! `NSEvent`s at positions read from the layout, through AppKit, the input
//! method (which sees mouse events first) and `editing.press`/`drag`, and
//! checks what each gesture selected.
//!
//! The interface is also described to accessibility clients, through an
//! `access.Tree` that `demo.buildUi` fills (see `platform/macos_access.zig`).
//! `--ax` runs for ten seconds, types `xin chào` into the field three seconds
//! in, and reports every call a client made into the tree: start it, then
//! point `ax_probe` -- or VoiceOver -- at it.

const std = @import("std");
const ui = @import("zig-uikit");
const mtl = @import("zig-uikit-metal");
const mac = @import("zig-uikit-macos");
const demo = @import("demo.zig");

const bg = ui.Color.hex(0x1E1F22);
const hover_tint = ui.Color.hex(0x3D4450);

/// Compares the frame the window server was actually handed against the
/// software reference, and writes it out.
const Diff = struct { worst: u32, over1: usize, glyphs: usize };

/// The presented frame `rgba` against the software reference drawn from the
/// same scene at the swapchain's scale.
fn diffAgainstReference(gpa: std.mem.Allocator, swapchain: *const mtl.Swapchain, scene: *const ui.Scene, atlas: ui.AtlasView, rgba: []const u8) !Diff {
    const w = swapchain.extent.width;
    const h = swapchain.extent.height;
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
            const dd: u32 = if (a > b) a - b else b - a;
            px_worst = @max(px_worst, dd);
        }
        worst = @max(worst, px_worst);
        if (px_worst > 1) over1 += 1;
    }
    return .{ .worst = worst, .over1 = over1, .glyphs = glyphs };
}

/// Everything a frame drawn from inside AppKit's resize loop needs: the main
/// loop's state, by pointer, because the main loop is suspended underneath
/// the call and its locals are exactly where it left them.
const Live = struct {
    gpa: std.mem.Allocator,
    swapchain: *mtl.Swapchain,
    renderer: *mtl.Renderer,
    t: *ui.Tree,
    scene: *ui.Scene,
    fonts: *demo.Fonts,
    field: *Field,
    /// Which step of the drag to capture and compare, 0 for none.
    capture_step: u32 = 0,
    captured: ?Diff = null,
    captured_size: [2]u32 = .{ 0, 0 },
    ns_total: u64 = 0,
    ns_worst: u64 = 0,
    timed: u32 = 0,
};

/// The editable field and everything laying it out again needs. It is the
/// context of the text target's callbacks, and what a resize re-wraps with:
/// the field is as wide as the window lets it be, so a narrower window is more
/// lines.
const Field = struct {
    win: *mac.Window,
    t: *ui.Tree,
    fonts: *demo.Fonts,
    doc: *ui.Document,
    shown: *std.ArrayList(u8),
    glyphs: *std.ArrayList(ui.Glyph),
    lines: *std.ArrayList(ui.text_layout.Line),

    /// Shapes and wraps the field again, and hands the text target the new
    /// line table -- `demo.editableLines` is null until the first wrap.
    fn refresh(self: *Field) !void {
        try demo.refreshEditable(self.t, self.fonts, self.doc, self.shown, self.glyphs, self.lines);
        if (self.win.text) |*tt| tt.options.lines = demo.editableLines();
    }
};

/// `TextTarget.sync`: the document changed inside this turn of the event loop
/// and something asked where its text is before the frame laid it out.
fn syncField(ctx: ?*anyopaque) void {
    const f: *Field = @ptrCast(@alignCast(ctx.?));
    f.refresh() catch {};
}

/// The text target for the field: the window edits its document while the
/// field has focus, and has none otherwise.
fn fieldTarget(f: *Field) mac.Window.TextTarget {
    var tt: mac.Window.TextTarget = .{ .doc = f.doc, .rect = rangeRect, .hit = hitTest, .sync = syncField, .ctx = f };
    tt.options.lines = demo.editableLines();
    return tt;
}

/// What has keyboard focus inside the window -- the field or the button --
/// and the button the pointer is pressing. The rules are `ui.focus`'s; this
/// is the demo carrying them out: attaching the field to the window's text
/// input or detaching it, telling the accessibility tree, and painting.
const Focus = struct {
    win: *mac.Window,
    t: *ui.Tree,
    at: *ui.access.Tree,
    field: *Field,
    scene: *const ui.Scene,
    node: ui.access.NodeId,
    press: ui.focus.Press = .{},
    /// Button activations, by the pointer or by Space.
    activated: u32 = 0,
    /// Tab stops at buttons even without the system setting: `--focus`
    /// tests the order, not this Mac's settings.
    force_tab_to_buttons: bool = false,

    fn options(self: *const Focus) ui.focus.Options {
        var o = ui.focus.Options.mac;
        o.tab_to_buttons = self.force_tab_to_buttons or self.win.keyboardNavigation();
        return o;
    }

    fn set(self: *Focus, n: ui.access.NodeId) void {
        if (n == self.node) return;
        self.node = n;
        self.apply();
    }

    /// Makes everything agree with `node`: after a change, and after the
    /// trees are rebuilt for a new display.
    fn apply(self: *Focus) void {
        self.at.setFocus(self.node);
        const on_field = self.node == demo.editable_node;
        const has_field = self.win.text != null;
        if (on_field and !has_field) self.win.setTextTarget(fieldTarget(self.field));
        if (!on_field and has_field) self.win.setTextTarget(null);
        self.win.accessibilityFocusChanged();
        self.paint();
    }

    /// The button's ring when it has focus and its darker fill while the
    /// pointer holds it; the field's selection grey when it does not have
    /// focus, as a Mac draws an inactive selection. The caret is the main
    /// loop's, because it also depends on the window being key.
    fn paint(self: *Focus) void {
        if (demo.button_el != std.math.maxInt(ui.Index)) {
            var p = demo.button_paint;
            if (self.node == demo.button_node) {
                p.border_color = ui.Color.hex(0xBFD3FF);
                p.border_width = 2;
            }
            if (self.press.armed == demo.button_node and self.press.over) p.background = ui.Color.hex(0x3A62C0);
            self.t.setPaint(demo.button_el, p);
        }
        if (demo.editable) |ed| {
            const c = if (self.node == demo.editable_node) demo.selection_color else ui.Color.hex(0x464A52);
            for (ed.selection) |o| {
                var p = self.t.paint(o.box);
                p.background = c;
                self.t.setPaint(o.box, p);
            }
        }
    }

    fn activate(self: *Focus, n: ui.access.NodeId) void {
        self.activated += 1;
        std.debug.print("pressed: \"{s}\"\n", .{if (self.at.get(n)) |node| node.name else "?"});
    }

    /// `Window.PointerHook`: every press, drag and release, before the field
    /// sees it, so that a click on the unfocused field focuses it and then
    /// places the caret.
    fn pointer(ctx: ?*anyopaque, _: *mac.Window, ev: mac.Window.PointerEvent) void {
        const self: *Focus = @ptrCast(@alignCast(ctx.?));
        // What was painted at the point, popover included -- not the tree's
        // descent, which cannot see a layer (`Scene.hitTest`).
        const el = self.scene.hitTest(ev.p) orelse self.t.root();
        const node = ui.focus.nodeAt(self.at, self.t, el);
        switch (ev.kind) {
            .down => {
                if (ui.focus.onPress(self.at, node, self.options())) |n| self.set(n);
                _ = self.press.down(self.at, node);
            },
            .dragged => self.press.moved(self.at, node),
            .up => if (self.press.up(self.at, node)) |b| self.activate(b),
        }
        self.paint();
    }
};

/// A frame at the window's new size, drawn from `setFrameSize:` while the
/// user drags. The same work the main loop does on a resize -- new
/// drawables, a full layout, a scene -- and nothing else: no hover, no
/// keyboard, nothing that needs the event queue AppKit is holding.
fn liveDraw(ctx: ?*anyopaque, win: *mac.Window) void {
    const l: *Live = @ptrCast(@alignCast(ctx.?));
    const capture = win.live.steps == l.capture_step;
    const t0 = nowNs();
    // Timed to the present, and not on the frame that is captured, whose
    // read-back and comparison are the test's cost, not the drag's.
    defer if (!capture) {
        const spent = nowNs() - t0;
        l.ns_total += spent;
        l.ns_worst = @max(l.ns_worst, spent);
        l.timed += 1;
    };
    l.swapchain.recreate(win.pixelWidth(), win.pixelHeight(), win.scale) catch return;
    l.t.layout(viewport(win));
    // The field's width changed, so its lines did: wrapped to the width just
    // laid out, and laid out again for the height that gives it.
    l.field.refresh() catch {};
    _ = l.t.flush();
    win.textGeometryChanged();
    _ = l.scene.build(l.t) catch return;
    if (capture) l.swapchain.capture_request = true;
    const presented = l.swapchain.drawAndPresent(l.renderer, l.scene, bg) catch return;
    if (capture and presented and !l.swapchain.capture_request) {
        const rgba = l.swapchain.captureRgba(l.gpa) catch return;
        defer l.gpa.free(rgba);
        l.captured = diffAgainstReference(l.gpa, l.swapchain, l.scene, l.fonts.atlas.view(), rgba) catch null;
        l.captured_size = .{ l.swapchain.extent.width, l.swapchain.extent.height };
    }
}

fn checkPresentedFrame(
    gpa: std.mem.Allocator,
    swapchain: *mtl.Swapchain,
    scene: *const ui.Scene,
    atlas: ui.AtlasView,
    t: *const ui.Tree,
    /// A crop of the editable field, written only by `--telex` and `--click`
    /// so that a plain `--capture` does not replace it with an untouched
    /// field: the input method's work, mid-word, or a selection across a line
    /// break, as the window server was handed it.
    crop: ?Crop,
) !void {
    const w = swapchain.extent.width;
    const h = swapchain.extent.height;

    const rgba = try swapchain.captureRgba(gpa);
    defer gpa.free(rgba);
    const d = try diffAgainstReference(gpa, swapchain, scene, atlas, rgba);
    const worst = d.worst;
    const over1 = d.over1;
    const glyphs = d.glyphs;

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var fb: ui.Framebuffer = .{ .gpa = gpa, .w = w, .h = h, .px = rgba };
    // The whole window only from the runs that leave it as it starts: a
    // selection is not what the picture of the demo should show.
    const whole = if (crop) |c| c.whole else true;
    if (whole) try fb.writePng(io, "docs/demo-window-macos.png");
    if (crop) |c| if (demo.editable) |ed| {
        // In pixels: the frame is two pixels per point, and the crop is of
        // the frame.
        const s = swapchain.scale;
        const b = t.bounds(ed.field);
        try demo.writeCrop(gpa, io, &fb, .{
            .x = b.x * s,
            .y = b.y * s,
            .w = @min(b.w, c.max_w) * s,
            .h = b.h * s,
        }, 1, c.path);
        std.debug.print("wrote {s}\n", .{c.path});
    };
    std.debug.print(
        \\presented frame vs software reference, {d}x{d} pixels at scale {d}, {d} glyphs:
        \\  largest channel difference   {d}
        \\  pixels differing by > 1      {d}
        \\
    , .{ w, h, swapchain.scale, glyphs, worst, over1 });
    if (whole) std.debug.print("wrote docs/demo-window-macos.png\n", .{});
    std.debug.print("\n", .{});
}

const Crop = struct {
    path: []const u8,
    /// In points: the crop's width, at most.
    max_w: f32 = 360,
    /// Whether to write the whole window as well.
    whole: bool = true,
};

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
    /// Sent in the same turn of the event loop as the stroke before it, so
    /// that nothing lays the text out in between -- what a fast typist or a
    /// key repeat does. See `TextTarget.sync`.
    with_previous: bool = false,
};

const kVK_Delete = 51;
const kVK_LeftArrow = 123;
const kVK_RightArrow = 124;
const kVK_Space = 49;
const kVK_DownArrow = 125;
const kVK_UpArrow = 126;
const left_arrow = "\u{F702}";
const right_arrow = "\u{F703}";
const up_arrow = "\u{F700}";
const down_arrow = "\u{F701}";
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
    // Down and back up, between the field's lines: `moveDown:` and
    // `moveUp:`, which keep the column across both.
    // The Down arrives with the last backspace, before any frame has laid
    // out the shorter text: the line table it needs is one keystroke old
    // unless the window asks for a new one.
    try list.append(gpa, .{ .code = kVK_DownArrow, .chars = down_arrow, .bare = down_arrow, .mods = .{ .function = true }, .with_previous = true });
    try list.append(gpa, .{ .code = kVK_UpArrow, .chars = up_arrow, .bare = up_arrow, .mods = .{ .function = true } });
    try list.append(gpa, .{ .code = kVK_LeftArrow, .chars = left_arrow, .bare = left_arrow, .mods = .{ .command = true, .function = true } });
    try list.append(gpa, .{ .code = kVK_RightArrow, .chars = right_arrow, .bare = right_arrow, .mods = .{ .option = true, .function = true } });
    try list.append(gpa, .{ .code = kVK_RightArrow, .chars = right_arrow, .bare = right_arrow, .mods = .{ .option = true, .function = true } });
    try list.append(gpa, .{ .code = kVK_RightArrow, .chars = right_arrow, .bare = right_arrow, .mods = .{ .command = true, .shift = true, .function = true } });
    try list.append(gpa, .{ .code = 7, .chars = "X", .bare = "x", .mods = .{ .shift = true } });
    try list.append(gpa, .{ .code = kVK_Delete, .chars = backspace, .bare = backspace, .mods = .{ .option = true } });
    // Cmd+Down is `moveToEndOfDocument:`, Ctrl+End's opposite number; then
    // up and down again from the end, where the lines are uneven.
    try list.append(gpa, .{ .code = kVK_DownArrow, .chars = down_arrow, .bare = down_arrow, .mods = .{ .command = true, .function = true } });
    try list.append(gpa, .{ .code = kVK_UpArrow, .chars = up_arrow, .bare = up_arrow, .mods = .{ .function = true } });
    try list.append(gpa, .{ .code = kVK_DownArrow, .chars = down_arrow, .bare = down_arrow, .mods = .{ .function = true } });
    return list.toOwnedSlice(gpa);
}

/// What `--type` should leave in the document: the Wayland demo's script,
/// with Linux chords, applied by `editing.apply` with no window at all.
///
/// The text is wrapped before every keystroke, with the same font to the same
/// width as the window's field, because the vertical keys and Home and End
/// are about lines: without the line table they would mean something else and
/// the comparison would be of two different scripts.
fn linuxEquivalent(gpa: std.mem.Allocator, fonts: *demo.Fonts, width: f32) !ui.Document {
    const Replay = struct {
        gpa: std.mem.Allocator,
        doc: ui.Document,
        fonts: *demo.Fonts,
        width: f32,
        glyphs: std.ArrayList(ui.Glyph) = .empty,
        lines: std.ArrayList(ui.text_layout.Line) = .empty,
        goal_x: ?f32 = null,

        fn key(self: *@This(), ev: ui.KeyEvent) !void {
            const one = try self.fonts.ui.shape(&self.fonts.atlas, self.doc.text());
            const w = try ui.text_layout.wrap(self.gpa, one, self.doc.text(), self.width, self.fonts.ui.line_height, &self.glyphs, &self.lines);
            const r = try ui.editing.apply(&self.doc, ev, .{ .lines = &w, .goal_x = self.goal_x });
            self.goal_x = r.goal_x;
        }
    };
    var rp: Replay = .{ .gpa = gpa, .doc = ui.Document.init(gpa), .fonts = fonts, .width = width };
    defer rp.glyphs.deinit(gpa);
    defer rp.lines.deinit(gpa);
    errdefer rp.doc.deinit();
    _ = try rp.doc.insert(.application, demo.editable_initial);
    const ctrl: ui.Mods = .{ .ctrl = true };
    var it = (std.unicode.Utf8View.init(" — thử xoá và chọn") catch unreachable).iterator();
    while (it.nextCodepointSlice()) |ch| try rp.key(ui.KeyEvent.typed(ch));
    for (0..4) |_| try rp.key(ui.KeyEvent.named(.backspace));
    try rp.key(ui.KeyEvent.named(.down));
    try rp.key(ui.KeyEvent.named(.up));
    try rp.key(ui.KeyEvent.named(.home));
    try rp.key(ui.KeyEvent.named(.right).withMods(ctrl));
    try rp.key(ui.KeyEvent.named(.right).withMods(ctrl));
    try rp.key(ui.KeyEvent.named(.end).withMods(.{ .shift = true }));
    try rp.key(ui.KeyEvent.typed("X"));
    try rp.key(ui.KeyEvent.named(.backspace).withMods(ctrl));
    try rp.key(ui.KeyEvent.named(.end).withMods(ctrl));
    try rp.key(ui.KeyEvent.named(.up));
    try rp.key(ui.KeyEvent.named(.down));
    return rp.doc;
}

/// `--telex`: to the end of the field, then `tieengs Vieetj ` as key codes
/// and nothing else. The characters come from the keyboard layout and their
/// meaning from the input method; see `Window.sendKeyCode`.
fn telexScript(gpa: std.mem.Allocator) ![]Stroke {
    var list: std.ArrayList(Stroke) = .empty;
    // Navigation goes through `sendKey`, with characters, because a
    // Core Graphics arrow made here does not reach the key bindings at all --
    // `doCommandBySelector:` is never called -- and the caret is already at
    // the end anyway. The letters are what the input method is for.
    try list.append(gpa, .{ .code = kVK_RightArrow, .chars = right_arrow, .bare = right_arrow, .mods = .{ .command = true, .function = true } });
    // No leading space: the field already ends in one, and two in a row are
    // not two spaces with this input method. Simple Telex turns them into
    // ". ", as macOS's double-space shortcut does -- one more replacing
    // `insertText:`, measured when the field's initial text gained its
    // trailing space and this script did not lose its leading one.
    for ("tieengs Vieetj ") |ch| try list.append(gpa, .{
        .code = if (ch == ' ') kVK_Space else letterCode(std.ascii.toLower(ch)),
        .chars = "",
        .bare = "",
        .mods = .{ .shift = std.ascii.isUpper(ch) },
    });
    return list.toOwnedSlice(gpa);
}

/// The input method's caret rectangle callback: where a byte range of the
/// editable field is, which the window converts to screen coordinates.
// `--resize` drags the window's corner with the real pointer. Events made
// inside the process do not start a live resize -- measured: three positions
// on and around the corner, zero resizes -- because the window server handles
// the drag, so the test has to post events where a mouse would. That moves
// the user's pointer for half a second; it is put back afterwards.
const CGPoint = extern struct { x: f64, y: f64 };
extern "CoreGraphics" fn CGEventCreateMouseEvent(source: ?*anyopaque, kind: u32, p: CGPoint, button: u32) ?*anyopaque;
extern "CoreGraphics" fn CGEventCreate(source: ?*anyopaque) ?*anyopaque;
extern "CoreGraphics" fn CGEventGetLocation(ev: *anyopaque) CGPoint;
extern "CoreGraphics" fn CGEventPost(tap: u32, ev: *anyopaque) void;
extern "CoreGraphics" fn CGWarpMouseCursorPosition(p: CGPoint) i32;
extern "CoreFoundation" fn CFRelease(obj: *anyopaque) void;

const Drag = struct { from: CGPoint, dx: f64, dy: f64, steps: u32 };

fn postMouse(kind: u32, p: CGPoint) void {
    const ev = CGEventCreateMouseEvent(null, kind, p, 0) orelse return;
    defer CFRelease(ev);
    CGEventPost(0, ev); // kCGHIDEventTap
}

/// On its own thread, so the main loop keeps pumping and AppKit can enter
/// its resize loop when the press arrives -- as it would for a person.
fn dragThread(d: Drag) void {
    const was = blk: {
        const e = CGEventCreate(null) orelse break :blk d.from;
        defer CFRelease(e);
        break :blk CGEventGetLocation(e);
    };
    const pause = 16 * std.time.ns_per_ms;
    postMouse(5, d.from); // moved, so the press is not a jump
    sleepNs(pause * 4);
    postMouse(1, d.from); // left down
    sleepNs(pause * 2);
    var i: u32 = 1;
    while (i <= d.steps) : (i += 1) {
        const f = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(d.steps));
        postMouse(6, .{ .x = d.from.x + d.dx * f, .y = d.from.y + d.dy * f }); // dragged
        sleepNs(pause);
    }
    postMouse(2, .{ .x = d.from.x + d.dx, .y = d.from.y + d.dy }); // up
    sleepNs(pause * 2);
    _ = CGWarpMouseCursorPosition(was);
}

fn sleepNs(ns: u64) void {
    var ts: std.c.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    _ = std.c.nanosleep(&ts, &ts);
}

/// `--focus`, in order. Telex is the input source throughout, so that a
/// letter typed with the button focused would compose if the input method
/// were still attached, and so that composing again after Shift+Tab shows it
/// was attached again.
const focus_steps = [_][]const u8{
    "Tab moves focus to the button",
    "Space presses it, and types no space",
    "a letter with the button focused types nothing",
    "Shift-Tab goes back to the field",
    "Telex composes in it again: aa is â",
    "a click on the button presses it and leaves focus in the field",
    "a press on the button let go off it presses nothing",
    "a click on a label leaves focus where it was",
    "Tab away to the button",
    "a click in the field focuses it and places the caret, in one click",
};

const kVK_Tab = 48;

/// One step of `--cursor`: something done to the pointer, and the cursor the
/// screen must show afterwards. Checked with `Window.systemCursor`, which is
/// the screen's cursor and not this program's idea of it.
const CursorStep = struct {
    what: []const u8,
    /// Where to move the real pointer, in Core Graphics' global coordinates.
    warp: ?CGPoint = null,
    /// A synthetic press or release, at a point in layout units.
    mouse: ?struct { p: ui.Point, kind: mac.Window.MouseKind } = null,
    /// Set a cursor behind the window's back.
    foreign: bool = false,
    expect: ?ui.Cursor,
};

fn currentPointer() CGPoint {
    const e = CGEventCreate(null) orelse return .{ .x = 0, .y = 0 };
    defer CFRelease(e);
    return CGEventGetLocation(e);
}

/// A point in layout units as Core Graphics' global coordinates, which have
/// their origin at the top left of the main display.
fn layoutToGlobal(win: *mac.Window, p: ui.Point) CGPoint {
    const r = win.layoutRectToScreen(.{ .x = p.x, .y = p.y, .w = 0, .h = 0 });
    return .{ .x = r.origin.x, .y = win.screenFrame().main_height - r.origin.y };
}

fn cursorScript(win: *mac.Window, t: *const ui.Tree) [6]CursorStep {
    const f = t.bounds(demo.editable.?.field);
    const in_field: ui.Point = .{ .x = f.x + f.w / 2, .y = f.y + f.h / 2 };
    // Above the field, on the label that names it: content, not text.
    const off_field: ui.Point = .{ .x = f.x + 10, .y = f.y - 40 };
    return .{
        .{ .what = "the pointer over the field", .warp = layoutToGlobal(win, in_field), .expect = .text },
        .{ .what = "the pointer off it", .warp = layoutToGlobal(win, off_field), .expect = .arrow },
        // A press in the field with the pointer where it is: the drag has
        // begun in text, so the I-beam stays while it lasts.
        .{ .what = "a drag that began in the field, off it", .mouse = .{ .p = in_field, .kind = .down }, .expect = .text },
        .{ .what = "the drag released", .mouse = .{ .p = in_field, .kind = .up }, .expect = .arrow },
        .{ .what = "back over the field", .warp = layoutToGlobal(win, in_field), .expect = .text },
        // A foreign cursor, with the pointer still: the window has nothing
        // new to say, and puts its own back anyway.
        .{ .what = "a crosshair set behind the window's back", .foreign = true, .expect = .text },
    };
}

fn hitTest(ctx: ?*anyopaque, doc: *const ui.Document, p: ui.Point, clamp: bool) ?ui.editing.Hit {
    const f: *const Field = @ptrCast(@alignCast(ctx.?));
    return demo.editableHit(f.t, doc.len(), p, clamp);
}

const MouseEv = struct { p: ui.Point, kind: mac.Window.MouseKind, clicks: u32 = 1, shift: bool = false };

/// One gesture of `--click` and what it must leave selected.
const ClickStep = struct {
    what: []const u8,
    events: []const MouseEv,
    selected: []const u8,
    /// For a gesture that leaves a caret: where, as the text after it.
    caret_before: ?[]const u8 = null,
    /// Capture the frame that shows the result.
    capture: bool = false,
};

/// The gestures, at positions read from the laid-out field. Everything is
/// found by substring in the field's text, so the script follows the text
/// rather than pixel coordinates that would go stale with a font change.
fn clickScript(arena: std.mem.Allocator, t: *const ui.Tree, s: []const u8) ![]ClickStep {
    const R = struct {
        t: *const ui.Tree,
        s: []const u8,
        fn at(self: @This(), needle: []const u8) usize {
            return std.mem.indexOf(u8, self.s, needle).?;
        }
        /// A point inside the character starting at byte `b`, `frac` of the
        /// way across it.
        fn in(self: @This(), b: usize, frac: f32) ui.Point {
            const n = std.unicode.utf8ByteSequenceLength(self.s[b]) catch 1;
            const r = demo.editableRangeRect(self.t, .{ .start = b, .end = b + n });
            return .{ .x = r.x + r.w * frac, .y = r.y + r.h / 2 };
        }
        /// A point in the right quarter of the character that ends at `e`.
        fn endOf(self: @This(), e: usize) ui.Point {
            return self.in(ui.offsets.prevChar(self.s, e), 0.75);
        }
    };
    const q: R = .{ .t = t, .s = s };
    const vao = q.at("vào");
    const day_end = q.at("đây") + "đây".len;
    const tieng = q.at("tiếng");
    const colon_end = q.at(":") + 1;
    const field = t.bounds(demo.editable.?.field);

    var steps: std.ArrayList(ClickStep) = .empty;
    const dbl = try arena.dupe(MouseEv, &.{
        .{ .p = q.in(vao + 1, 0.5), .kind = .down },
        .{ .p = q.in(vao + 1, 0.5), .kind = .up },
        .{ .p = q.in(vao + 1, 0.5), .kind = .down, .clicks = 2 },
        .{ .p = q.in(vao + 1, 0.5), .kind = .up, .clicks = 2 },
    });
    try steps.append(arena, .{ .what = "a double-click selects the word", .events = dbl, .selected = "vào" });
    try steps.append(arena, .{ .what = "Shift-click extends it", .events = try arena.dupe(MouseEv, &.{
        .{ .p = q.endOf(day_end), .kind = .down, .shift = true },
        .{ .p = q.endOf(day_end), .kind = .up, .shift = true },
    }), .selected = "vào đây" });
    try steps.append(arena, .{ .what = "a click places the caret", .events = try arena.dupe(MouseEv, &.{
        .{ .p = q.in(tieng, 0.25), .kind = .down },
        .{ .p = q.in(tieng, 0.25), .kind = .up },
    }), .selected = "", .caret_before = "tiếng " });
    try steps.append(arena, .{ .what = "a drag selects", .events = try arena.dupe(MouseEv, &.{
        .{ .p = q.in(0, 0.25), .kind = .down },
        .{ .p = q.in(vao, 0.5), .kind = .dragged },
        .{ .p = q.endOf(colon_end), .kind = .dragged },
        .{ .p = q.endOf(colon_end), .kind = .up },
    }), .selected = "Gõ vào đây:" });
    const day = q.at("đây") + 1;
    try steps.append(arena, .{ .what = "a double-click dragged back extends by words", .events = try arena.dupe(MouseEv, &.{
        .{ .p = q.in(day, 0.5), .kind = .down },
        .{ .p = q.in(day, 0.5), .kind = .up },
        .{ .p = q.in(day, 0.5), .kind = .down, .clicks = 2 },
        .{ .p = q.in(1, 0.5), .kind = .dragged, .clicks = 2 },
        .{ .p = q.in(1, 0.5), .kind = .up, .clicks = 2 },
    }), .selected = "Gõ vào đây" });
    // The field wraps, so "past the end" is two places: to the right of a
    // line, which is that line's end, and below the field, which is the
    // document's.
    const first_line_end = demo.editableLines().?.lines[0].end;
    const right_of_first = q.in(vao, 0.25);
    try steps.append(arena, .{ .what = "a drag off the right of the first line", .events = try arena.dupe(MouseEv, &.{
        .{ .p = q.in(vao, 0.25), .kind = .down },
        .{ .p = .{ .x = field.x + field.w + 80, .y = right_of_first.y }, .kind = .dragged },
        .{ .p = .{ .x = field.x + field.w + 80, .y = right_of_first.y }, .kind = .up },
    }), .selected = s[vao..first_line_end] });
    const next_line = q.at("các dòng");
    try steps.append(arena, .{ .what = "a drag onto the next line selects across the break", .events = try arena.dupe(MouseEv, &.{
        .{ .p = q.in(vao, 0.25), .kind = .down },
        .{ .p = q.in(next_line, 0.25), .kind = .dragged },
        .{ .p = q.in(next_line, 0.25), .kind = .up },
    }), .selected = s[vao..next_line], .capture = true });
    std.debug.assert(next_line > first_line_end);
    try steps.append(arena, .{ .what = "a drag out of the bottom of the field", .events = try arena.dupe(MouseEv, &.{
        .{ .p = q.in(vao, 0.25), .kind = .down },
        .{ .p = .{ .x = field.x + field.w / 2, .y = field.y + field.h + 40 }, .kind = .dragged },
        .{ .p = .{ .x = field.x + field.w / 2, .y = field.y + field.h + 40 }, .kind = .up },
    }), .selected = s[vao..] });
    try steps.append(arena, .{ .what = "a triple-click selects it all", .events = try arena.dupe(MouseEv, &.{
        .{ .p = q.in(vao, 0.5), .kind = .down },
        .{ .p = q.in(vao, 0.5), .kind = .up },
        .{ .p = q.in(vao, 0.5), .kind = .down, .clicks = 2 },
        .{ .p = q.in(vao, 0.5), .kind = .up, .clicks = 2 },
        .{ .p = q.in(vao, 0.5), .kind = .down, .clicks = 3 },
        .{ .p = q.in(vao, 0.5), .kind = .up, .clicks = 3 },
    }), .selected = s });
    try steps.append(arena, .{ .what = "a click outside the field changes nothing", .events = try arena.dupe(MouseEv, &.{
        .{ .p = .{ .x = field.x + 10, .y = field.y - 40 }, .kind = .down },
        .{ .p = .{ .x = field.x + 10, .y = field.y - 40 }, .kind = .up },
    }), .selected = s });
    return steps.toOwnedSlice(arena);
}

fn rangeRect(ctx: ?*anyopaque, r: ui.Range) ui.Rect {
    const f: *const Field = @ptrCast(@alignCast(ctx.?));
    return demo.editableRangeRect(f.t, r);
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
    var ax_test = false;
    var click_test = false;
    var resize_test = false;
    var cursor_test = false;
    var focus_test = false;
    var live_off = false;
    var resize_thread: ?std.Thread = null;
    var resize_reported = false;
    var resize_w0: u32 = 0;
    var resize_h0: u32 = 0;
    var resize_t0: u64 = 0;
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--capture")) capture = true;
        if (std.mem.eql(u8, a, "--sweep")) sweep = 180;
        if (std.mem.eql(u8, a, "--type")) type_test = true;
        if (std.mem.eql(u8, a, "--telex")) telex = true;
        if (std.mem.eql(u8, a, "--ax")) ax_test = true;
        if (std.mem.eql(u8, a, "--click")) click_test = true;
        if (std.mem.eql(u8, a, "--resize")) resize_test = true;
        // Moves the real pointer over the field and off it, checks what the
        // screen shows, and puts the pointer back. See `CursorStep`.
        if (std.mem.eql(u8, a, "--cursor")) cursor_test = true;
        // Tab, Space, Telex, and clicks on the button, the label and the
        // field. See `FocusTest`.
        if (std.mem.eql(u8, a, "--focus")) focus_test = true;
        // Measures the window without its live-resize drawing: the baseline.
        if (std.mem.eql(u8, a, "--no-live")) live_off = true;
    }
    // The capture of a composition in progress needs the swapchain to be
    // capturable.
    if (telex) capture = true;

    var win = try mac.Window.open(gpa, "zig-uikit", 900, 560);
    defer win.close();

    var gpu = try mtl.Gpu.init(gpa, .{});
    defer gpu.deinit();

    var swapchain = try mtl.Swapchain.init(&gpu, win.layer, win.pixelWidth(), win.pixelHeight(), win.scale, .{
        .capturable = capture or resize_test or click_test,
    });
    defer swapchain.deinit();

    var renderer = try mtl.Renderer.initDefault(&gpu);
    defer renderer.deinit();

    var fonts = try demo.Fonts.initScaled(gpa, win.scale);
    defer fonts.deinit();
    var fonts_scale = win.scale;

    var t = try ui.Tree.init(gpa);
    defer t.deinit();
    var at = try ui.access.Tree.init(gpa, "zig-uikit");
    defer at.deinit();
    demo.access_tree = &at;
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

    // Scratch for `displayText`, which the field now shapes instead of the
    // document's own bytes. On this platform nothing is ever spliced -- marked
    // text is written into the document -- so this stays empty here and is
    // used on Wayland, where the preedit is not in the document. One call for
    // both shapes is the point of that function.
    var shown: std.ArrayList(u8) = .empty;
    defer shown.deinit(gpa);
    // The field's wrapped run and its line table. Owned here because
    // `demo.editable` borrows them for as long as the field exists.
    var wrapped_glyphs: std.ArrayList(ui.Glyph) = .empty;
    defer wrapped_glyphs.deinit(gpa);
    var wrapped_lines: std.ArrayList(ui.text_layout.Line) = .empty;
    defer wrapped_lines.deinit(gpa);
    _ = try doc.insert(.application, demo.editable_initial);
    var field: Field = .{
        .win = win,
        .t = &t,
        .fonts = &fonts,
        .doc = &doc,
        .shown = &shown,
        .glyphs = &wrapped_glyphs,
        .lines = &wrapped_lines,
    };
    win.setTextTarget(fieldTarget(&field));
    defer win.setTextTarget(null);
    // Wrapped once before anything asks where the text is: `buildUi` set it
    // as one line, and the field's width is known now that it is laid out.
    try field.refresh();
    _ = t.flush();
    at.setDocument(demo.editable_node, &doc);
    at.setFocus(demo.editable_node);
    win.setAccessTarget(.{ .tree = &at, .layout = &t });
    defer win.setAccessTarget(null);
    var focus: Focus = .{ .win = win, .t = &t, .at = &at, .field = &field, .scene = &scene, .node = demo.editable_node, .force_tab_to_buttons = focus_test };
    win.setPointerHook(.{ .ctx = &focus, .event = Focus.pointer });
    defer win.setPointerHook(null);
    // Whether the text changed or only the caret moved, for the notification
    // a screen reader needs: a value change is read aloud, a caret move is not.
    var text_hash = std.hash.Wyhash.hash(0, doc.text());
    var atlas_gen = fonts.atlas.generation;

    // A scripted run needs a known input source, and must give the user's
    // back. `--type` wants a plain layout so that letters are letters.
    var source_buf: [256]u8 = undefined;
    var restore_source: ?[]const u8 = null;
    if (type_test or telex or focus_test) {
        const want: [*:0]const u8 = if (telex or focus_test)
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
    const telex_capture_after: usize = 1 + "tieengs Vieet".len;
    var keystroke_ns_total: u64 = 0;
    var keystroke_ns_worst: u64 = 0;
    var unhandled: u64 = 0;
    var atlas_uploads: u64 = 0;
    var caret_visible = true;
    var capture_pending = false;
    var ax_typed: usize = 0;
    var live: Live = .{
        .gpa = gpa,
        .swapchain = &swapchain,
        .renderer = &renderer,
        .t = &t,
        .scene = &scene,
        .fonts = &fonts,
        .field = &field,
        .capture_step = if (resize_test) 15 else 0,
    };
    if (!live_off) win.setLiveFrame(.{ .ctx = &live, .draw = liveDraw });
    defer win.setLiveFrame(null);
    var click_arena: std.heap.ArenaAllocator = .init(gpa);
    defer click_arena.deinit();
    var click_steps: []ClickStep = &.{};
    var click_at: usize = 0;
    var click_wrong: u32 = 0;
    var click_capture_frame: u64 = std.math.maxInt(u64);
    var cursor_steps: [6]CursorStep = undefined;
    var focus_at: usize = 0;
    var focus_wrong: u32 = 0;
    var focus_before: [512]u8 = undefined;
    var focus_before_len: usize = 0;
    var cursor_at: usize = 0;
    var cursor_wrong: u32 = 0;
    var cursor_was: CGPoint = .{ .x = 0, .y = 0 };
    var ax_removed = false;
    const frame_ns = win.refreshInterval() * 1e9;
    var last_present_ns: u64 = 0;
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
        // Asleep in the run loop until about 2 ms before the next frame is
        // due, rather than in `nextDrawable`: input and accessibility queries
        // are then served as they arrive instead of once per vsync. See
        // `Window.pumpFor`.
        const since_present = nowNs() - last_present_ns;
        const wait_ns = @as(i64, @intFromFloat(frame_ns)) - @as(i64, @intCast(since_present)) - 2_000_000;
        if (wait_ns > 0) win.pumpFor(@as(f64, @floatFromInt(wait_ns)) / 1e9) else win.pump();
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
                // The accessibility tree goes with it: its nodes name layout
                // elements that no longer exist. Every object a client held
                // is retired, and the client is told.
                win.setAccessTarget(null);
                at.deinit();
                at = try ui.access.Tree.init(gpa, "zig-uikit");
                try demo.buildUi(&t, &fonts);
                at.setDocument(demo.editable_node, &doc);
                win.setAccessTarget(.{ .tree = &at, .layout = &t });
                // The nodes were registered in the same order, so the ids
                // are the same ones; the paint and the tree's focus are new.
                focus.apply();
                try renderer.setAtlas(fonts.atlas.view());
                atlas_gen = fonts.atlas.generation;
                scene.setPixelScale(win.scale);
            }
            t.layout(viewport(win));
            // A new width is new lines. Wrapped to it and laid out again,
            // before the hover test below reads any bounds.
            try field.refresh();
            _ = t.flush();
            win.textGeometryChanged();
            // After a change of display the document is shaped at the new
            // size for the first time, and may have glyphs the rebuilt tree
            // did not.
            if (fonts.atlas.generation != atlas_gen) {
                try renderer.setAtlas(fonts.atlas.view());
                atlas_gen = fonts.atlas.generation;
            }
            relayouts += 1;
            // The highlighted element may no longer be under the pointer, and
            // its saved paint predates the relayout; forget it.
            hovered = 0;
        }

        const t0 = nowNs();
        var scripted_frame = false;

        // --- the keyboard ---
        //
        // A scripted keystroke goes through AppKit synchronously: by the time
        // `sendKey` returns, the input method has run and the document holds
        // the result. It is timed because that is the per-keystroke cost of
        // the whole Mac text system, input method included.
        if (script_at < script.len and frames % 4 == 0 and frames > 0) {
            scripted_frame = true;
            while (true) {
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
                if (script_at == script.len or !script[script_at].with_previous) break;
            }
        }
        while (win.keys.pop()) |ev| {
            if (ev.key == .escape) {
                win.closed = true;
                break;
            }
            // Tab and Shift+Tab: `insertTab:` and `insertBacktab:` from the
            // field, the same from the view's key bindings when nothing
            // editable has focus.
            if (ev.key == .tab and !ev.mods.anyAccel()) {
                if (ui.focus.next(&at, focus.node, ev.mods.shift, focus.options())) |n| focus.set(n);
                continue;
            }
            if (ui.focus.activates(&at, focus.node, ev)) {
                focus.activate(focus.node);
                continue;
            }
            unhandled += 1;
        }
        if (win.text_changed) {
            win.text_changed = false;
            field.refresh() catch |e| switch (e) {
                error.AtlasFull => std.debug.print("atlas full -- text stopped updating\n", .{}),
                else => return e,
            };
            if (fonts.atlas.generation != atlas_gen) {
                try renderer.setAtlas(fonts.atlas.view());
                atlas_gen = fonts.atlas.generation;
                atlas_uploads += 1;
            }
            win.textGeometryChanged();
            const h = std.hash.Wyhash.hash(0, doc.text());
            win.accessibilityTextChanged(demo.editable_node, h != text_hash);
            text_hash = h;
        }
        // `--click`: one gesture every six frames, from the tenth on, so the
        // field has been laid out and presented before the first.
        if (click_test and frames >= 10 and frames % 6 == 0) {
            if (click_steps.len == 0 and click_at == 0) click_steps = try clickScript(click_arena.allocator(), &t, doc.text());
            if (click_at < click_steps.len) {
                const st = click_steps[click_at];
                scripted_frame = true;
                for (st.events) |e| win.sendMouse(e.p, e.kind, e.clicks, e.shift);
                const sel = doc.selection();
                const got = doc.text()[sel.start..sel.end];
                var ok = std.mem.eql(u8, got, st.selected);
                if (st.caret_before) |after| ok = ok and std.mem.eql(u8, doc.text()[doc.focus..], after);
                if (!ok) click_wrong += 1;
                std.debug.print("  {s}: \"{s}\" -- {s}\n", .{ st.what, got, if (ok) "ok" else "WRONG" });
                // The selection that crosses a line break is three
                // rectangles; the frame that shows it is compared against
                // the software reference and kept. The next frame's, because
                // this one's field was refreshed before the gesture ran (and
                // `frames` has already counted this one by the time it draws).
                if (st.capture) click_capture_frame = frames + 2;
                click_at += 1;
            } else if (frames > 10 + 6 * (click_steps.len + 2)) {
                std.debug.print("{d} gestures, {d} wrong; {d} presses reached the field, {d} the input method\n", .{
                    click_steps.len, click_wrong, win.ime.presses, win.ime.presses_to_input_method,
                });
                if (click_wrong > 0) return error.ClickScriptDiverged;
                break;
            }
        }
        // `--cursor`: one step every eight frames from the twentieth, each
        // checked on the step after it, so that a pump has sampled the
        // pointer and the frame has decided.
        if (cursor_test and frames >= 20 and frames % 8 == 4) {
            scripted_frame = true;
            if (cursor_at == 0) {
                cursor_was = currentPointer();
                cursor_steps = cursorScript(win, &t);
            } else {
                const st = cursor_steps[cursor_at - 1];
                const on_screen = win.systemCursor();
                const ok = on_screen == st.expect;
                if (!ok) cursor_wrong += 1;
                std.debug.print("  {s}: {s} -- {s}\n", .{ st.what, if (on_screen) |c| @tagName(c) else "another shape", if (ok) "ok" else "WRONG" });
            }
            if (cursor_at < cursor_steps.len) {
                const st = cursor_steps[cursor_at];
                if (st.warp) |p| _ = CGWarpMouseCursorPosition(p);
                if (st.mouse) |m| win.sendMouse(m.p, m.kind, 1, false);
                if (st.foreign) {
                    // What another application, or AppKit at the window's
                    // edge, does: sets a cursor of its own. Nothing in this
                    // program's state changes, so only the level check in
                    // `pump` can notice.
                    const rt = mac.runtime;
                    const NSCursor = try rt.class("NSCursor");
                    rt.send(void, rt.send(rt.id, NSCursor, "crosshairCursor", .{}), "set", .{});
                }
                cursor_at += 1;
            } else {
                _ = CGWarpMouseCursorPosition(cursor_was);
                std.debug.print("{d} steps, {d} wrong; the cursor was set {d} times\n", .{ cursor_steps.len, cursor_wrong, win.cursor_sets });
                if (cursor_wrong > 0) return error.CursorScriptDiverged;
                break;
            }
        }
        // `--focus`: one step every eight frames from the twentieth, each
        // checked at the next, as `--cursor` does. See `focus_steps`.
        if (focus_test and frames >= 20 and frames % 8 == 4) {
            scripted_frame = true;
            if (focus_at > 0) {
                const i = focus_at - 1;
                const before = focus_before[0..focus_before_len];
                const text_now = doc.text();
                const on_field = focus.node == demo.editable_node and win.text != null and at.focus == demo.editable_node;
                const ok = switch (i) {
                    0 => focus.node == demo.button_node and win.text == null and at.focus == demo.button_node,
                    1 => focus.activated == 1 and std.mem.eql(u8, text_now, before),
                    2 => std.mem.eql(u8, text_now, before),
                    3 => on_field,
                    4 => on_field and std.mem.endsWith(u8, text_now, "â"),
                    5 => focus.activated == 2 and on_field,
                    6 => focus.activated == 2,
                    7 => on_field,
                    8 => focus.node == demo.button_node and win.text == null,
                    9 => on_field and std.mem.startsWith(u8, text_now[doc.focus..], "vào"),
                    else => unreachable,
                };
                if (!ok) focus_wrong += 1;
                std.debug.print("  {s} -- {s}\n", .{ focus_steps[i], if (ok) "ok" else "WRONG" });
            }
            if (focus_at < focus_steps.len) {
                const fb = t.bounds(demo.editable.?.field);
                const bb = t.bounds(demo.button_el);
                const button_mid: ui.Point = .{ .x = bb.x + bb.w / 2, .y = bb.y + bb.h / 2 };
                const label: ui.Point = .{ .x = fb.x + 10, .y = fb.y - 40 };
                switch (focus_at) {
                    0 => win.sendKey(kVK_Tab, "\t", "\t", .{}),
                    1 => {
                        focus_before_len = doc.text().len;
                        @memcpy(focus_before[0..focus_before_len], doc.text());
                        win.sendKey(kVK_Space, " ", " ", .{});
                    },
                    // Through the input source, as a person types: with no
                    // input context it reaches the application as a key.
                    2 => win.sendKeyCode(letterCode('x'), .{}),
                    3 => win.sendKey(kVK_Tab, "\x19", "\t", .{ .shift = true }),
                    4 => {
                        win.sendKeyCode(letterCode('a'), .{});
                        win.sendKeyCode(letterCode('a'), .{});
                    },
                    5 => {
                        win.sendMouse(button_mid, .down, 1, false);
                        win.sendMouse(button_mid, .up, 1, false);
                    },
                    6 => {
                        win.sendMouse(button_mid, .down, 1, false);
                        win.sendMouse(label, .dragged, 1, false);
                        win.sendMouse(label, .up, 1, false);
                    },
                    7 => {
                        win.sendMouse(label, .down, 1, false);
                        win.sendMouse(label, .up, 1, false);
                    },
                    8 => win.sendKey(kVK_Tab, "\t", "\t", .{}),
                    // Its own step: a key is queued for the frame and a
                    // click is handled as it arrives, so a Tab and a click
                    // in one frame happen click first.
                    9 => {
                        const vao = std.mem.indexOf(u8, doc.text(), "vào").?;
                        const r = demo.editableRangeRect(&t, .{ .start = vao, .end = vao + 1 });
                        const p: ui.Point = .{ .x = r.x + 1, .y = r.y + r.h / 2 };
                        win.sendMouse(p, .down, 1, false);
                        win.sendMouse(p, .up, 1, false);
                    },
                    else => unreachable,
                }
                focus_at += 1;
            } else {
                std.debug.print("{d} steps, {d} wrong; {d} button presses, {d} mouse presses taken by the input method\n", .{ focus_steps.len, focus_wrong, focus.activated, win.ime.presses_to_input_method });
                if (focus_wrong > 0) return error.FocusScriptDiverged;
                break;
            }
        }
        // `--resize`: the window's corner dragged 240 by 140 points in 30
        // steps, through AppKit's own resize loop. `sendResizeDrag` returns
        // only when the drag is over -- the frame loop is stopped for all of
        // it, which is the point.
        if (resize_test and frames == 20) {
            const sf = win.screenFrame();
            // The bottom-right corner, in Core Graphics' top-left coordinates,
            // one point inside.
            const corner: CGPoint = .{
                .x = sf.frame.origin.x + sf.frame.size.width - 1,
                .y = sf.main_height - sf.frame.origin.y - 1,
            };
            resize_w0 = win.width;
            resize_h0 = win.height;
            resize_t0 = nowNs();
            resize_thread = try std.Thread.spawn(.{}, dragThread, .{Drag{ .from = corner, .dx = 240, .dy = 140, .steps = 30 }});
        }
        if (resize_thread != null and frames > 20 and !win.live.active and win.live.resizes > 0 and !resize_reported) {
            resize_reported = true;
            const spent = nowNs() - resize_t0;
            const w0 = resize_w0;
            const h0 = resize_h0;
            defer if (live.captured) |d| std.debug.print(
                "  frame {d} of the drag, {d}x{d} pixels, against the reference at that size: largest difference {d}, {d} pixels over 1\n  drawing a frame inside the drag: mean {d} us, worst {d} us\n",
                .{ live.capture_step, live.captured_size[0], live.captured_size[1], d.worst, d.over1, live.ns_total / @max(1, live.timed) / 1000, live.ns_worst / 1000 },
            );
            std.debug.print(
                \\live resize: {d}x{d} -> {d}x{d} points in {d:.0} ms
                \\  live resizes {d}, size changes during them {d}, frames drawn during them {d}
                \\
            , .{ w0, h0, win.width, win.height, @as(f64, @floatFromInt(spent)) / 1e6, win.live.resizes, win.live.steps, win.live.frames });
        }
        if (resize_test and (resize_reported or frames > 600) and frames > 40) {
            if (resize_thread) |th| th.join();
            resize_thread = null;
            if (!resize_reported) std.debug.print("live resize: none happened\n", .{});
            break;
        }
        while (win.access_presses.pop()) |n| {
            std.debug.print("pressed through accessibility: \"{s}\"\n", .{if (at.get(n)) |node| node.name else "?"});
        }
        // `--ax`: `xin chào` three seconds in, one character every 100 ms,
        // through the key bindings (no input method), so that a client that
        // registered for notifications has something to be told about.
        if (ax_test) {
            const since = nowNs() - started;
            const typed = "xin chào";
            const due: usize = if (since < 3_000_000_000) 0 else @min(typed.len, (since - 3_000_000_000) / 100_000_000 + 1);
            while (ax_typed < due) {
                const n = std.unicode.utf8ByteSequenceLength(typed[ax_typed]) catch 1;
                const ch = typed[ax_typed..][0..n];
                win.sendKey(0, ch, ch, .{});
                ax_typed += n;
            }
            // Five seconds in, the button's node goes, as it would when a
            // popover closes: the probe holds an object for it and must be
            // told, and must get an error rather than a crash when it asks.
            if (since > 5_000_000_000 and !ax_removed) {
                for (at.nodes.items) |n| if (n.alive and n.role == .button) {
                    at.remove(n.id);
                    break;
                };
                ax_removed = true;
            }
            if (since > 10_000_000_000) break;
        }
        if (demo.editable) |ed| {
            const show_caret = win.focused and focus.node == demo.editable_node;
            if (show_caret != caret_visible) {
                caret_visible = show_caret;
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

        // The I-beam over the field, and for the whole of a drag that began
        // in it. A hit test against the field's rectangle, which is what
        // `editableHit` does when it is not clamping.
        if (sweep == 0) {
            const over_text = inside and demo.editableHit(&t, doc.len(), .{ .x = px, .y = py }, false) != null;
            const want_cursor = ui.cursor.forPointer(over_text, win.gesture != null);
            if (want_cursor != win.cursor) win.setCursor(want_cursor);
        }

        const layout = t.flush();
        const built = try scene.build(&t);
        const cpu = nowNs() - t0;

        cpu_total_ns += cpu;
        cpu_worst_ns = @max(cpu_worst_ns, cpu);
        frames += 1;
        if (layout.total() > 0) frames_with_layout += 1;
        if (built.rebuilt) frames_with_scene += 1;
        // A frame that ran a scripted keystroke or gesture is not idle even
        // when it changed nothing -- clicking outside the field does not --
        // because it spent milliseconds in AppKit and the input method.
        if (layout.total() == 0 and !built.rebuilt and !scripted_frame) {
            idle_frames += 1;
            idle_cpu_ns += cpu;
        }

        // Requested and checked in the same iteration, for the reason given in
        // `window_demo.zig`: a frame later is a different scene under --sweep.
        if (frames == click_capture_frame) {
            swapchain.capture_request = true;
            capture_pending = true;
        }
        if (capture and !telex and frames == 9) {
            swapchain.capture_request = true;
            capture_pending = true;
        }

        const presented = try swapchain.drawAndPresent(&renderer, &scene, bg);
        last_present_ns = nowNs();
        if (!presented) {
            skipped += 1;
            continue;
        }

        // The request is cleared by the present that honoured it.
        if (capture_pending and !swapchain.capture_request) {
            capture_pending = false;
            const crop: ?Crop = if (telex)
                .{ .path = "docs/demo-typing-macos.png" }
            else if (click_test)
                .{ .path = "docs/demo-selection-macos.png", .max_w = 10_000, .whole = false }
            else
                null;
            try checkPresentedFrame(gpa, &swapchain, &scene, fonts.atlas.view(), &t, crop);
            capture = false;
            if (sweep == 0 and script.len == 0 and !click_test) break;
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
            \\  editing commands      {d}, refused {d}; {d} moved between lines
            \\  layout on demand      {d} (geometry asked for before the frame laid the text out)
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
            n.vertical,
            n.syncs,
            n.passed_on,
            unhandled,
            n.substring_queries,
            n.rect_queries,
            atlas_uploads,
            doc.text(),
        });
        if (type_test) {
            var want = try linuxEquivalent(gpa, &fonts, demo.editableWrapWidth(&t));
            defer want.deinit();
            const same = std.mem.eql(u8, want.text(), doc.text()) and
                want.anchor == doc.anchor and want.focus == doc.focus;
            std.debug.print("the same edits with Linux chords through editing.apply: \"{s}\" -- {s}\n", .{
                want.text(), if (same) "identical, selection included" else "DIFFERENT",
            });
            if (!same) return error.TypeScriptDiverged;
        }
        if (telex) {
            const want = demo.editable_initial ++ "tiếng Việt ";
            const ok = std.mem.eql(u8, want, doc.text());
            std.debug.print("expected \"{s}\" -- {s}\n", .{ want, if (ok) "composed" else "DIFFERENT" });
            if (!ok) return error.TelexDiverged;
        }
    }

    if (ax_test) {
        const st = &win.access_stats;
        std.debug.print(
            \\
            \\accessibility: {d} nodes, {d} calls into the tree from clients
            \\  objects made {d}, retired {d}, freed {d}
            \\  notifications posted {d}, held back before any client asked {d}
            \\document: "{s}"
            \\
        , .{ at.count(), st.total(), st.elements_made, st.elements_retired, mac.ax.elements_freed, st.notifications_posted, st.notifications_gated, doc.text() });
        for (std.enums.values(mac.ax.Method)) |m| {
            const c = st.count(m);
            if (c > 0) std.debug.print("  {s:<26} {d}\n", .{ @tagName(m), c });
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
