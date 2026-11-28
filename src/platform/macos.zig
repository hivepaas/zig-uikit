//! A macOS window: `NSApplication`, `NSWindow`, a view hosting a
//! `CAMetalLayer`, and the pointer.
//!
//! The counterpart of `wayland.zig`, with the same fields where the concepts
//! match so the window demos read alike. Two concepts do not match and are
//! added rather than hidden:
//!
//!   - **Points and pixels.** `width`, `height` and the pointer are in points,
//!     which is what the layout engine is given. `scale` is the backing scale
//!     factor -- two on a Retina display -- and the layer's drawables are
//!     `width * scale` by `height * scale` pixels. The renderer scales on the
//!     GPU; nothing in the tree knows about it.
//!   - **The application.** AppKit has one `NSApplication` per process, which
//!     owns the event queue and the menu bar. Wayland has no such thing. It is
//!     created on the first `open`.
//!
//! Heap-allocated for the same reason as the Wayland window: the delegate keeps
//! a pointer to it for the life of the window.
//!
//! The delegate is a class defined at run time (see `objc.ClassBuilder`), and
//! so is the view: `ZigUIKitView` is an `NSView` that conforms to
//! `NSTextInputClient`, which is how a Mac input method talks to a text field.
//!
//! **Keyboard input is not keystrokes on a Mac.** AppKit hands `keyDown:` to
//! the view, the view hands it straight back with `interpretKeyEvents:`, and
//! what comes out is one of three calls: `insertText:` for text,
//! `setMarkedText:` for an input method's provisional text, or
//! `doCommandBySelector:` with whatever the user's key bindings say the key
//! means. The view never decodes a key itself, and so never disagrees with
//! the rest of the Mac about what Option+Left does. The three calls are
//! implemented in core (`input_client.zig`, `editing.zig`) against the
//! `Document` the application attaches with `setTextTarget`; this file only
//! converts `NSString`s and `NSRange`s.
//!
//! What the editing layer does not handle -- Escape, Tab, the vertical arrows
//! -- arrives in `keys` as a `KeyEvent`, as it does on Wayland.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
/// For tools that need one message this module has no wrapper for -- the
/// window demo's `--cursor` sets a cursor the way another application would.
pub const runtime = objc;
const ui = @import("zig-uikit");
const id = objc.id;
const send = objc.send;
const ic = ui.input_client;
pub const ax = @import("macos_access.zig");

pub const Error = error{ WindowFailed, NotMainThread } || objc.Error || Allocator.Error;

const NSWindowStyleMaskTitled: objc.NSUInteger = 1 << 0;
const NSWindowStyleMaskClosable: objc.NSUInteger = 1 << 1;
const NSWindowStyleMaskMiniaturizable: objc.NSUInteger = 1 << 2;
const NSWindowStyleMaskResizable: objc.NSUInteger = 1 << 3;
const NSBackingStoreBuffered: objc.NSUInteger = 2;
const NSApplicationActivationPolicyRegular: objc.NSInteger = 0;
const NSTerminateCancel: objc.NSUInteger = 0;
const NSEventMaskAny: u64 = std.math.maxInt(u64);

extern "Foundation" const NSDefaultRunLoopMode: id;
extern "c" fn pthread_main_np() c_int;
extern "CoreGraphics" fn CGEventCreateKeyboardEvent(source: ?*anyopaque, key: u16, down: bool) ?*anyopaque;
extern "CoreGraphics" fn CGEventSetFlags(ev: *anyopaque, flags: u64) void;
extern "CoreFoundation" fn CFRelease(obj: *anyopaque) void;
extern "CoreGraphics" fn CGEventCreateScrollWheelEvent2(source: ?*anyopaque, units: u32, wheel_count: u32, wheel1: i32, wheel2: i32, wheel3: i32) ?*anyopaque;
extern "CoreGraphics" fn CGEventPost(tap: u32, ev: *anyopaque) void;

pub const LiveFrame = struct {
    ctx: ?*anyopaque,
    draw: *const fn (ctx: ?*anyopaque, w: *Window) void,
};

pub const LiveStats = struct {
    /// Whether a live resize is in progress right now.
    active: bool = false,
    resizes: u32 = 0,
    /// Size changes AppKit made during live resizes, and frames drawn for
    /// them by `Window.live_frame`.
    steps: u32 = 0,
    frames: u32 = 0,
};

pub const Window = struct {
    gpa: Allocator,

    app: id,
    window: id,
    view: id,
    /// The `CAMetalLayer` the view hosts. The window creates it and does
    /// nothing else with it; `metal.Swapchain` configures and draws into it.
    layer: id,
    delegate: id,

    /// Content size in points.
    width: u32,
    height: u32,
    /// Pixels per point. Changes when the window moves between a Retina and a
    /// non-Retina display, which is reported as a resize.
    scale: f32,

    closed: bool = false,
    /// Set when the size or scale changed and cleared by the caller once it
    /// has acted.
    resized: bool = false,

    /// In points, top-left origin, like the layout engine.
    pointer_x: f32 = -1,
    pointer_y: f32 = -1,
    pointer_inside: bool = false,

    /// Whether this window has keyboard focus: it is the key window.
    focused: bool = false,

    /// Keys the editing layer did not act on, for the application: Escape,
    /// Tab, the vertical arrows. Text and editing commands do not come through
    /// here when a text target is attached; they go straight to its document.
    keys: ui.KeyQueue = .{},

    /// The document keyboard input edits, if any. See `setTextTarget`.
    text: ?TextTarget = null,
    /// Set whenever the text target's document or selection changed, by
    /// typing, by an input method or by a command, and cleared by the caller
    /// once it has reshaped the line.
    text_changed: bool = false,
    /// Set when the document's bytes changed and nothing has laid them out
    /// since, so the target's geometry -- its line table, where a range is,
    /// what is under a point -- describes the text as it was. See
    /// `TextTarget.sync` and `textGeometry`.
    text_stale: bool = false,
    /// The column a run of up and down arrows is aiming for, kept between
    /// keystrokes as `editing.Options.goal_x` says.
    goal_x: ?f32 = null,
    /// What the input method did, counted. The evidence a spike reports.
    ime: ImeStats = .{},

    /// The press being dragged, if a mouse button is down in the text target.
    gesture: ?ui.editing.Gesture = null,

    /// Scroll accumulated since the application last took it (`takeScroll`),
    /// in layout units, positive when the content should move up -- the
    /// direction `Tree.scrollBy` and the Wayland window both use. AppKit's
    /// natural-scrolling setting is already folded into what it reports.
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    /// Where the last scroll event was, in layout units: a wheel event names
    /// a position, and the box it scrolls is the one there.
    scroll_at: ui.Point = .{ .x = -1, .y = -1 },
    /// Scroll events, and of them the precise ones -- a trackpad or a Magic
    /// Mouse, in points, against a wheel's notches in lines.
    scroll_events: u32 = 0,
    scroll_precise: u32 = 0,

    /// Told about every press, drag and release in the content before the
    /// text target is. See `setPointerHook`.
    pointer_hook: ?PointerHook = null,

    /// The cursor the application wants over this window. See `setCursor`.
    cursor: ui.Cursor = .arrow,
    /// Times the cursor had to be set: because the application changed its
    /// mind, or because something else -- AppKit at a window edge, another
    /// application's window the pointer came from -- left a different one.
    cursor_sets: u32 = 0,

    /// Called to draw a frame while the user drags the window's edge. See
    /// `setLiveFrame`.
    live_frame: ?LiveFrame = null,
    live: LiveStats = .{},

    /// The accessibility tree this window describes, if any. See
    /// `setAccessTarget` and `macos_access.zig`.
    access: ?ax.Target = null,
    access_revision: u64 = 0,
    /// One `ZigUIKitAXElement` per node a client has asked about, retained.
    access_elements: std.AutoHashMapUnmanaged(ui.access.NodeId, id) = .empty,
    access_stats: ax.Stats = .{},
    /// Buttons pressed by an accessibility client, for the application.
    access_presses: ax.Presses = .{},

    pub const TextTarget = struct {
        doc: *ui.Document,
        options: ui.editing.Options = .{},
        /// Where a byte range of the document is drawn, in points from the
        /// view's top-left corner. An input method asks, through
        /// `firstRectForCharacterRange:`, so that its candidate window opens
        /// beside the text instead of in a corner of the screen; that is
        /// `docs/text-and-accessibility.md` §7, and every spike answered it
        /// with a fixed rectangle. Null answers with the view's corner.
        rect: ?*const fn (ctx: ?*anyopaque, r: ui.Range) ui.Rect = null,
        /// Where a point in layout units is in the text -- the nearest caret
        /// boundary and the character under it -- or null when the point is
        /// outside the field. With `clamp`, a point outside still answers,
        /// at the nearer end, which is what a drag that leaves the field
        /// wants. Null disables the pointer.
        hit: ?*const fn (ctx: ?*anyopaque, doc: *const ui.Document, p: ui.Point, clamp: bool) ?ui.editing.Hit = null,
        /// Lays the document out again, so that `rect`, `hit` and
        /// `options.lines` describe the text as it is now.
        ///
        /// Called before any of them is consulted when the bytes changed
        /// since the application last laid them out -- which happens inside
        /// one turn of the event loop: a keystroke and a Down arrow in the
        /// same batch of events, or an input method that inserts and then
        /// asks where the caret is before the frame has drawn anything. A
        /// line table one keystroke old answers with offsets into text that
        /// is not there any more. Null trusts the geometry as it stands.
        sync: ?*const fn (ctx: ?*anyopaque) void = null,
        ctx: ?*anyopaque = null,
    };

    pub const ImeStats = struct {
        /// `setMarkedText:` calls with text, and with none (a cancel).
        marked: u32 = 0,
        cancelled: u32 = 0,
        /// `insertText:` calls: commits and plain typing alike.
        inserted: u32 = 0,
        /// Of those, the ones with an explicit replacement range: an input
        /// method rewriting text already in the document. Apple's Simple
        /// Telex composes entirely this way and never marks anything.
        replaced: u32 = 0,
        unmarked: u32 = 0,
        /// `doCommandBySelector:` calls that became editing commands, and the
        /// ones that were passed on as keys or ignored.
        commands: u32 = 0,
        passed_on: u32 = 0,
        /// Edits the document refused (`error.Locked`, `error.BadRange`).
        refused: u32 = 0,
        rect_queries: u32 = 0,
        substring_queries: u32 = 0,
        /// Mouse presses that moved the caret or the selection, and the ones
        /// the input method took instead.
        presses: u32 = 0,
        presses_to_input_method: u32 = 0,
        /// Compositions committed because the user clicked elsewhere.
        committed_by_click: u32 = 0,
        /// Up and down arrows that moved between lines, and the times the
        /// geometry had to be laid out again before a question about it
        /// could be answered (`TextTarget.sync`).
        vertical: u32 = 0,
        syncs: u32 = 0,
    };

    pub fn open(gpa: Allocator, title: [*:0]const u8, w: u32, h: u32) Error!*Window {
        // AppKit is main-thread-only and says so by crashing somewhere else
        // later. Saying so here is cheaper.
        if (pthread_main_np() == 0) return Error.NotMainThread;

        const pool = objc.AutoreleasePool.push();
        defer pool.pop();

        const app = try sharedApplication();

        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);

        const rect: objc.CGRect = .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) },
        };
        const style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
        const window = send(?id, send(id, try objc.class("NSWindow"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{
            rect, style, NSBackingStoreBuffered, objc.NO,
        }) orelse return Error.WindowFailed;
        // An `NSWindow` releases itself when closed unless told otherwise, and
        // `close` below releases it again: a double free on the red button.
        send(void, window, "setReleasedWhenClosed:", .{objc.NO});
        send(void, window, "setTitle:", .{objc.string(title)});

        // A layer-hosting view: the layer is set *before* `wantsLayer`, so the
        // view hosts this layer instead of creating a backing layer of its own
        // that AppKit would draw into. Core Animation composites it directly.
        const view = send(id, send(id, try viewClass(), "alloc", .{}), "initWithFrame:", .{rect});
        objc.setState(view, try viewClass(), self);
        const layer = objc.retain(send(id, try objc.class("CAMetalLayer"), "layer", .{}));
        send(void, view, "setLayer:", .{layer});
        send(void, view, "setWantsLayer:", .{objc.YES});
        send(void, window, "setContentView:", .{view});
        // Keys go to the first responder, which would otherwise be the window.
        _ = send(objc.BOOL, window, "makeFirstResponder:", .{view});

        const delegate = objc.new(try delegateClass());
        objc.setState(delegate, try delegateClass(), self);
        send(void, window, "setDelegate:", .{delegate});
        app_delegate_target = self;

        const scale: f32 = @floatCast(send(objc.CGFloat, window, "backingScaleFactor", .{}));
        send(void, layer, "setContentsScale:", .{@as(f64, scale)});

        self.* = .{
            .gpa = gpa,
            .app = app,
            .window = window,
            .view = view,
            .layer = layer,
            .delegate = delegate,
            .width = w,
            .height = h,
            .scale = scale,
        };

        send(void, window, "center", .{});
        send(void, window, "makeKeyAndOrderFront:", .{@as(?id, null)});
        // Launched from a terminal, the process is not the active application
        // and the window would open behind the terminal with no key focus.
        send(void, app, "activateIgnoringOtherApps:", .{objc.YES});

        self.pump();
        self.resized = false;
        return self;
    }

    pub fn close(self: *Window) void {
        if (app_delegate_target == self) app_delegate_target = null;
        send(void, self.window, "setDelegate:", .{@as(?id, null)});
        objc.setState(self.delegate, delegateClass() catch unreachable, null);
        objc.setState(self.view, viewClass() catch unreachable, null);
        ax.detach(self);
        self.access_elements.deinit(self.gpa);
        if (!self.closed) send(void, self.window, "close", .{});
        objc.release(self.delegate);
        objc.release(self.layer);
        objc.release(self.view);
        objc.release(self.window);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// The display's refresh interval in seconds: 1/120 on a ProMotion panel.
    pub fn refreshInterval(self: *const Window) f64 {
        const screen = send(?id, self.window, "screen", .{}) orelse return 1.0 / 60.0;
        const fps = send(objc.NSInteger, screen, "maximumFramesPerSecond", .{});
        return if (fps > 0) 1.0 / @as(f64, @floatFromInt(fps)) else 1.0 / 60.0;
    }

    /// The content size in pixels: what the layer's drawables should be.
    pub fn pixelWidth(self: *const Window) u32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(self.width)) * self.scale));
    }

    pub fn pixelHeight(self: *const Window) u32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(self.height)) * self.scale));
    }

    /// Attaches the document keyboard input edits, or detaches it with null.
    ///
    /// While one is attached, typing, input-method composition and editing
    /// commands change it directly, during `pump`, and set `text_changed`. It
    /// has to be direct rather than queued: an input method asks the client
    /// for its marked range and selection in the middle of a keystroke and
    /// expects answers that already include the edit it just made.
    pub fn setTextTarget(self: *Window, target: ?TextTarget) void {
        if (self.text) |t| {
            if (ic.hasMarkedText(t.doc)) ic.unmarkText(t.doc);
        }
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        if (send(?id, self.view, "inputContext", .{})) |ctx| send(void, ctx, "discardMarkedText", .{});
        self.text = target;
    }

    /// The text target, with its geometry brought up to date first if the
    /// document changed since it was laid out. Everything that asks where
    /// text is goes through here: the input method, the pointer, the line
    /// commands, and an accessibility client.
    pub fn textGeometry(self: *Window) ?TextTarget {
        const t = self.text orelse return null;
        if (self.text_stale) {
            self.text_stale = false;
            if (t.sync) |f| {
                f(t.ctx);
                self.ime.syncs += 1;
            }
        }
        return t;
    }

    /// Attaches the accessibility tree this window describes, or detaches it.
    /// Both trees are borrowed and must outlive the attachment.
    pub fn setAccessTarget(self: *Window, target: ?ax.Target) void {
        ax.attach(self, target);
    }

    /// A text node's value or selection changed: tells accessibility clients,
    /// if any has asked about this window.
    pub fn accessibilityTextChanged(self: *Window, node: ui.access.NodeId, edited: bool) void {
        ax.textChanged(self, node, edited);
    }

    pub fn accessibilityFocusChanged(self: *Window) void {
        ax.focusChanged(self);
    }

    /// A rectangle in layout units, from the top-left of the content, in
    /// screen coordinates: what both the input method and accessibility
    /// clients want (§7). The view is not flipped, so the y axis turns over on
    /// the way.
    pub fn layoutRectToScreen(self: *Window, r: ui.Rect) objc.CGRect {
        const bounds = send(objc.CGRect, self.view, "bounds", .{});
        const in_view: objc.CGRect = .{
            .origin = .{ .x = r.x, .y = bounds.size.height - (r.y + r.h) },
            .size = .{ .width = r.w, .height = r.h },
        };
        const in_window = send(objc.CGRect, self.view, "convertRect:toView:", .{ in_view, @as(?id, null) });
        return send(objc.CGRect, self.window, "convertRectToScreen:", .{in_window});
    }

    pub fn screenPointToLayout(self: *Window, p: objc.CGPoint) ui.Point {
        const r = send(objc.CGRect, self.window, "convertRectFromScreen:", .{objc.CGRect{ .origin = p, .size = .{ .width = 0, .height = 0 } }});
        const v = send(objc.CGPoint, self.view, "convertPoint:fromView:", .{ r.origin, @as(?id, null) });
        const bounds = send(objc.CGRect, self.view, "bounds", .{});
        return .{ .x = @floatCast(v.x), .y = @floatCast(bounds.size.height - v.y) };
    }

    /// Tells the input method that the text moved on screen, so that it asks
    /// for `firstRectForCharacterRange:` again.
    ///
    /// It also tells this window the target's geometry is current again,
    /// so a query that follows does not lay the text out a second time.
    pub fn textGeometryChanged(self: *Window) void {
        self.text_stale = false;
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        if (send(?id, self.view, "inputContext", .{})) |ctx| send(void, ctx, "invalidateCharacterCoordinates", .{});
    }

    /// The input source this window's text input uses, by identifier --
    /// `com.apple.inputmethod.VietnameseIM.VietnameseSimpleTelex`, say -- and
    /// the one it replaced, which the caller should put back. Changing it is
    /// not private to this window: it is the input source in the menu bar.
    /// Returns null when the view has no input context, or the source is not
    /// enabled in System Settings.
    pub fn selectInputSource(self: *Window, source: [*:0]const u8, previous: []u8) ?[]const u8 {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const ctx = send(?id, self.view, "inputContext", .{}) orelse return null;
        const was = objc.utf8(send(?id, ctx, "selectedKeyboardInputSource", .{}) orelse objc.string(""));
        const n = @min(was.len, previous.len);
        @memcpy(previous[0..n], was[0..n]);
        const want = objc.string(source);
        const enabled = send(?id, ctx, "keyboardInputSources", .{}) orelse return null;
        if (!objc.truthy(send(objc.BOOL, enabled, "containsObject:", .{want}))) return null;
        send(void, ctx, "setSelectedKeyboardInputSource:", .{want});
        return previous[0..n];
    }

    /// Delivers a keystroke with stated characters: to the window, the first
    /// responder and the key bindings -- but **not** to an input method.
    ///
    /// Measured, not documented anywhere: an event made by
    /// `keyEventWithType:...characters:` reaches `interpretKeyEvents:` and the
    /// key bindings normally, and Apple's Vietnamese input method ignores it
    /// -- every key arrives as a plain `insertText:` of its own character.
    /// That makes this the way to type text a keyboard layout cannot produce
    /// (`—`, `ử`) and to test the key bindings, and `sendKeyCode` the way to
    /// test an input method.
    ///
    /// `chars` is what the key types with the modifiers applied and `bare`
    /// without them; `code` is the virtual key code.
    pub fn sendKey(self: *Window, code: u16, chars: []const u8, bare: []const u8, mods: KeyMods) void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const NSEventTypeKeyDown: objc.NSUInteger = 10;
        const NSEventTypeKeyUp: objc.NSUInteger = 11;
        var flags: objc.NSUInteger = 0;
        if (mods.shift) flags |= 1 << 17;
        if (mods.control) flags |= 1 << 18;
        if (mods.option) flags |= 1 << 19;
        if (mods.command) flags |= 1 << 20;
        // Arrow keys carry these two on real hardware, and the standard key
        // bindings are keyed on them.
        if (mods.function) flags |= (1 << 21) | (1 << 23);
        const number = send(objc.NSInteger, self.window, "windowNumber", .{});
        const now = send(f64, send(id, objc.class("NSProcessInfo") catch return, "processInfo", .{}), "systemUptime", .{});
        const cls = objc.class("NSEvent") catch return;
        for ([_]objc.NSUInteger{ NSEventTypeKeyDown, NSEventTypeKeyUp }) |kind| {
            const ev = send(?id, cls, "keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:", .{
                kind,
                objc.CGPoint{ .x = 0, .y = 0 },
                flags,
                now,
                number,
                @as(?id, null),
                objc.stringFromSlice(chars),
                objc.stringFromSlice(bare),
                objc.NO,
                code,
            }) orelse return;
            send(void, self.window, "sendEvent:", .{ev});
        }
    }

    /// A keystroke by key code alone, as the hardware would send it: the
    /// event is made by Core Graphics, its characters come from the current
    /// keyboard layout, and an input method sees it. See `sendKey` for why
    /// there are two. Delivered to this window directly rather than posted to
    /// the system, so it needs no accessibility permission and cannot type
    /// into anything else.
    pub fn sendKeyCode(self: *Window, code: u16, mods: KeyMods) void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        var flags: u64 = 0;
        if (mods.shift) flags |= 1 << 17;
        if (mods.control) flags |= 1 << 18;
        if (mods.option) flags |= 1 << 19;
        if (mods.command) flags |= 1 << 20;
        if (mods.function) flags |= (1 << 21) | (1 << 23);
        const cls = objc.class("NSEvent") catch return;
        for ([_]bool{ true, false }) |down| {
            const cg = CGEventCreateKeyboardEvent(null, code, down) orelse return;
            defer CFRelease(cg);
            CGEventSetFlags(cg, flags);
            const ev = send(?id, cls, "eventWithCGEvent:", .{cg}) orelse return;
            send(void, self.window, "sendEvent:", .{ev});
        }
    }

    /// Sets the function that draws a frame during a live resize, or clears
    /// it with null.
    ///
    /// While the user drags the window's edge, AppKit runs its own event loop
    /// inside `sendEvent:` and does not return until the button is released,
    /// so a loop that draws after `pump` draws nothing for the whole drag:
    /// the window shows the last frame, stretched. AppKit does call the
    /// view's `setFrameSize:` at every step of the drag, and that is where
    /// this is called from, with `width`, `height` and `scale` already
    /// updated and `resized` set. It should lay out and present at the new
    /// size; the main loop sees `resized` afterwards and may relayout again,
    /// which is idempotent.
    pub fn setLiveFrame(self: *Window, f: ?LiveFrame) void {
        self.live_frame = f;
    }

    /// The window's frame on screen, in Cocoa screen coordinates (origin at
    /// the bottom-left of the main display), and that display's height, for
    /// converting to the top-left coordinates Core Graphics events use.
    pub fn screenFrame(self: *const Window) struct { frame: objc.CGRect, main_height: f64 } {
        const frame = send(objc.CGRect, self.window, "frame", .{});
        const screens = send(id, objc.class("NSScreen") catch unreachable, "screens", .{});
        const main = send(id, screens, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
        return .{ .frame = frame, .main_height = send(objc.CGRect, main, "frame", .{}).size.height };
    }

    /// Whether the user has turned on keyboard navigation (System Settings,
    /// Keyboard), which is what makes Tab stop at buttons on a Mac. See
    /// `ui.focus.Options`.
    pub fn keyboardNavigation(self: *const Window) bool {
        return objc.truthy(send(objc.BOOL, self.app, "isFullKeyboardAccessEnabled", .{}));
    }

    /// The cursor to show while the pointer is over this window's content.
    ///
    /// The application decides, because only it knows what is under the
    /// pointer (`ui.cursor.forPointer` has the text-field rule), and says so
    /// whenever its answer changes; the window shows it.
    ///
    /// It is held as a *level*, not sent as an edge: every `pump` compares
    /// the application's current cursor with this one and sets it again if
    /// they differ. AppKit changes the cursor behind a view's back -- to a
    /// resize arrow at the window's edge, to whatever the window the pointer
    /// came from left -- and a view that set its cursor only when its own
    /// answer changed would keep the wrong one until the pointer crossed into
    /// the field and out again. Cursor rectangles are AppKit's own answer to
    /// that, and they are the wrong shape here: they are areas registered in
    /// advance, where this toolkit hit-tests a laid-out tree every frame and
    /// already knows.
    pub fn setCursor(self: *Window, c: ui.Cursor) void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        self.cursor = c;
        self.applyCursor();
    }

    fn nsCursor(c: ui.Cursor) ?id {
        const NSCursor = objc.class("NSCursor") catch return null;
        return switch (c) {
            .arrow => send(id, NSCursor, "arrowCursor", .{}),
            .text => send(id, NSCursor, "IBeamCursor", .{}),
        };
    }

    fn applyCursor(self: *Window) void {
        // Only over the content, and only while this application is the
        // active one: the cursor is the whole screen's, and an inactive
        // application setting it would fight the one in front.
        if (!self.pointer_inside) return;
        if (!objc.truthy(send(objc.BOOL, self.app, "isActive", .{}))) return;
        const want = nsCursor(self.cursor) orelse return;
        const NSCursor = objc.class("NSCursor") catch return;
        if (send(?id, NSCursor, "currentCursor", .{}) == want) return;
        send(void, want, "set", .{});
        self.cursor_sets += 1;
    }

    /// The cursor the *screen* shows now, whichever application set it, as
    /// one of ours, or null for any other shape. For tests: the application's
    /// own idea (`NSCursor.currentCursor`) is what it last set, which says
    /// nothing about whether anyone can see it.
    ///
    /// `currentSystemCursor` returns a new object rather than the shared one,
    /// so the comparison is by hot spot and image size, which is enough to
    /// tell an arrow from an I-beam.
    pub fn systemCursor(self: *const Window) ?ui.Cursor {
        _ = self;
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const NSCursor = objc.class("NSCursor") catch return null;
        const shown = send(?id, NSCursor, "currentSystemCursor", .{}) orelse return null;
        for ([_]ui.Cursor{ .arrow, .text }) |c| {
            const known = nsCursor(c) orelse continue;
            const a = send(objc.CGPoint, shown, "hotSpot", .{});
            const b = send(objc.CGPoint, known, "hotSpot", .{});
            const sa = send(objc.CGSize, send(id, shown, "image", .{}), "size", .{});
            const sb = send(objc.CGSize, send(id, known, "image", .{}), "size", .{});
            if (a.x == b.x and a.y == b.y and sa.width == sb.width and sa.height == sb.height) return c;
        }
        return null;
    }

    /// How far the content has been scrolled since this was last asked, and
    /// clears it. Zero when nothing scrolled. The same shape as the Wayland
    /// window's, so a frame loop asks both the same question.
    pub fn takeScroll(self: *Window) ui.Point {
        defer {
            self.scroll_x = 0;
            self.scroll_y = 0;
        }
        return .{ .x = self.scroll_x, .y = self.scroll_y };
    }

    /// A scroll event as a device delivers it, posted to the window server
    /// at the pointer: `precise` is a trackpad's distance in points, and
    /// otherwise `dy` is a wheel's count of lines. Positive `dy` scrolls the
    /// content up, as `takeScroll` reports it.
    ///
    /// Posted rather than handed to the window, because that does not work:
    /// `NSEvent` has no constructor for scroll events, and one made from a
    /// Core Graphics event has window number 0 and a screen location, and
    /// `NSWindow.sendEvent:` delivered none of the first run's to the view.
    /// The window server sends a scroll to the window under the pointer, so
    /// the caller puts the pointer there.
    pub fn postScroll(self: *Window, dy: f32, precise: bool) void {
        _ = self;
        // Core Graphics' wheel 1 is positive upwards, which is the content
        // moving down: the opposite of `takeScroll`.
        const ev = CGEventCreateScrollWheelEvent2(null, if (precise) 0 else 1, 1, @intFromFloat(-dy), 0, 0) orelse return;
        defer CFRelease(ev);
        CGEventPost(0, ev); // kCGHIDEventTap
    }

    pub const MouseKind = enum { down, dragged, up };

    /// A left-button event in the content, in layout units.
    pub const PointerEvent = struct {
        kind: MouseKind,
        p: ui.Point,
        clicks: u32 = 1,
        shift: bool = false,
    };

    pub const PointerHook = struct {
        ctx: ?*anyopaque,
        event: *const fn (ctx: ?*anyopaque, w: *Window, ev: PointerEvent) void,
    };

    /// Tells the application about every press, drag and release in the
    /// content -- buttons, labels, the background, the text field -- and
    /// *before* the text target sees it.
    ///
    /// Before, because a press is where focus moves. A click on a text field
    /// that does not have focus has to give it focus and place the caret, in
    /// that order, in one event: the application attaches the field as the
    /// text target from inside this call, and the press then reaches it. Told
    /// afterwards, the first click on an unfocused field would only focus it.
    /// The input method still sees a press first, when one is attached,
    /// because a click inside its composition is its business and not the
    /// application's.
    pub fn setPointerHook(self: *Window, h: ?PointerHook) void {
        self.pointer_hook = h;
    }

    /// A left-button event at a point in layout units, delivered through
    /// AppKit like `sendKey`: to the window, the view, and the input method,
    /// which sees mouse events first. `clicks` is the click count AppKit
    /// would have computed -- two for the second press of a double-click.
    pub fn sendMouse(self: *Window, p: ui.Point, kind: MouseKind, clicks: u32, shift: bool) void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const bounds = send(objc.CGRect, self.view, "bounds", .{});
        const in_view: objc.CGPoint = .{ .x = p.x, .y = bounds.size.height - p.y };
        const in_window = send(objc.CGPoint, self.view, "convertPoint:toView:", .{ in_view, @as(?id, null) });
        const kind_code: objc.NSUInteger = switch (kind) {
            .down => 1,
            .up => 2,
            .dragged => 6,
        };
        const flags: objc.NSUInteger = if (shift) 1 << 17 else 0;
        const now = send(f64, send(id, objc.class("NSProcessInfo") catch return, "processInfo", .{}), "systemUptime", .{});
        const ev = send(?id, objc.class("NSEvent") catch return, "mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:", .{
            kind_code,
            in_window,
            flags,
            now,
            send(objc.NSInteger, self.window, "windowNumber", .{}),
            @as(?id, null),
            @as(objc.NSInteger, 0),
            @as(objc.NSInteger, @intCast(clicks)),
            @as(f32, if (kind == .up) 0 else 1),
        }) orelse return;
        send(void, self.window, "sendEvent:", .{ev});
    }

    pub const KeyMods = packed struct {
        shift: bool = false,
        control: bool = false,
        option: bool = false,
        command: bool = false,
        function: bool = false,
    };

    /// Processes every queued event without blocking, then samples the size
    /// and the pointer.
    ///
    /// The pointer is polled rather than tracked through `mouseMoved:`
    /// events. The window demo wants the pointer's position once per frame,
    /// not every intermediate position, and polling needs no view subclass and
    /// no tracking area. Clicks and keys will need events; hover does not.
    pub fn pump(self: *Window) void {
        self.pumpFor(0);
    }

    /// `pump`, but spending `seconds` in the run loop first, handling events
    /// as they arrive, before sampling.
    ///
    /// This is for accessibility, and the reason is measured. A client's
    /// queries are served by AppKit on the main run loop, one at a time, and a
    /// frame loop that blocks in `nextDrawable` turns the run loop once per
    /// frame -- so every query waits for a vsync. `ax_probe` walking 76 nodes
    /// made 457 queries and took 3.9 s. Waiting here instead, until shortly
    /// before the next frame is due, leaves the main thread asleep in the run
    /// loop where a query is answered the moment it arrives.
    pub fn pumpFor(self: *Window, seconds: f64) void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();

        const NSDate = objc.class("NSDate") catch unreachable;
        const now = send(id, NSDate, "date", .{});
        const until = if (seconds > 0)
            send(id, now, "dateByAddingTimeInterval:", .{seconds})
        else
            send(id, NSDate, "distantPast", .{});
        while (send(?id, self.app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
            NSEventMaskAny, until, NSDefaultRunLoopMode, objc.YES,
        })) |ev| {
            send(void, self.app, "sendEvent:", .{ev});
            if (self.closed) break;
        }
        if (self.closed) return;
        ax.sweep(self);

        const bounds = send(objc.CGRect, self.view, "bounds", .{});
        const w: u32 = @intFromFloat(@max(bounds.size.width, 0));
        const h: u32 = @intFromFloat(@max(bounds.size.height, 0));
        const scale: f32 = @floatCast(send(objc.CGFloat, self.window, "backingScaleFactor", .{}));
        if (w != self.width or h != self.height or scale != self.scale) {
            self.width = w;
            self.height = h;
            self.scale = scale;
            self.resized = true;
        }

        // Window coordinates have their origin at the bottom left; the content
        // view fills the window, so flipping against its height is enough.
        const p = send(objc.CGPoint, self.window, "mouseLocationOutsideOfEventStream", .{});
        self.pointer_x = @floatCast(p.x);
        self.pointer_y = @floatCast(bounds.size.height - p.y);
        self.pointer_inside = p.x >= 0 and p.y >= 0 and p.x < bounds.size.width and p.y < bounds.size.height;
        self.focused = objc.truthy(send(objc.BOOL, self.window, "isKeyWindow", .{}));
        self.applyCursor();
    }
};

// ------------------------------------------------------------- the application

var app_ready = false;
/// Which window Quit closes. One window is all there is so far.
var app_delegate_target: ?*Window = null;

/// The process's `NSApplication`, set up on first use: a regular application
/// with a Dock icon, a menu bar with Quit, and a delegate that turns Quit into
/// closing the window instead of `exit()`.
///
/// Without the delegate, Cmd-Q calls `exit()` from inside `sendEvent:`, and the
/// demo never gets to print the counters it exists to print.
fn sharedApplication() Error!id {
    const app = send(id, try objc.class("NSApplication"), "sharedApplication", .{});
    if (app_ready) return app;

    _ = send(objc.BOOL, app, "setActivationPolicy:", .{NSApplicationActivationPolicyRegular});

    const menubar = objc.new(try objc.class("NSMenu"));
    const app_item = objc.new(try objc.class("NSMenuItem"));
    send(void, menubar, "addItem:", .{app_item});
    const app_menu = objc.new(try objc.class("NSMenu"));
    const quit = send(id, send(id, try objc.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{
        objc.string("Quit"), objc.sel("terminate:"), objc.string("q"),
    });
    send(void, app_menu, "addItem:", .{quit});
    send(void, app_item, "setSubmenu:", .{app_menu});

    // Cmd-A is not a key binding on a Mac; it is the Select All menu item's
    // key equivalent, sent to the first responder as `selectAll:`. Without an
    // Edit menu the shortcut does nothing at all, so there is one, with the
    // single item this toolkit implements. Cut, Copy and Paste need the
    // pasteboard and are not here rather than here and inert.
    const edit_item = objc.new(try objc.class("NSMenuItem"));
    send(void, menubar, "addItem:", .{edit_item});
    const edit_menu = send(id, send(id, try objc.class("NSMenu"), "alloc", .{}), "initWithTitle:", .{objc.string("Edit")});
    const select_all = send(id, send(id, try objc.class("NSMenuItem"), "alloc", .{}), "initWithTitle:action:keyEquivalent:", .{
        objc.string("Select All"), objc.sel("selectAll:"), objc.string("a"),
    });
    send(void, edit_menu, "addItem:", .{select_all});
    send(void, edit_item, "setSubmenu:", .{edit_menu});

    send(void, app, "setMainMenu:", .{menubar});
    objc.release(select_all);
    objc.release(edit_menu);
    objc.release(edit_item);
    objc.release(quit);
    objc.release(app_menu);
    objc.release(app_item);
    objc.release(menubar);

    // Retained by nothing else: `NSApplication.delegate` is a weak reference.
    // It lives for the process, which is the application's lifetime too.
    const delegate = objc.new(try appDelegateClass());
    send(void, app, "setDelegate:", .{delegate});

    // `run` would do this; a loop that pumps events itself has to.
    send(void, app, "finishLaunching", .{});
    app_ready = true;
    return app;
}

var delegate_class: ?objc.Class = null;
var app_delegate_class: ?objc.Class = null;
var view_class: ?objc.Class = null;

fn delegateClass() Error!objc.Class {
    if (delegate_class) |c| return c;
    if (try objc.ClassBuilder.begin("NSObject", "ZigUIKitWindowDelegate")) |b| {
        b.protocol("NSWindowDelegate");
        try b.method("windowWillClose:", &windowWillClose, "v@:@");
        try b.method("windowDidChangeBackingProperties:", &windowDidChangeBacking, "v@:@");
        try b.method("windowDidResignKey:", &windowDidResignKey, "v@:@");
        delegate_class = b.finish();
    } else {
        delegate_class = try objc.class("ZigUIKitWindowDelegate");
    }
    return delegate_class.?;
}

fn appDelegateClass() Error!objc.Class {
    if (app_delegate_class) |c| return c;
    if (try objc.ClassBuilder.begin("NSObject", "ZigUIKitAppDelegate")) |b| {
        b.protocol("NSApplicationDelegate");
        // `NSApplicationTerminateReply` is an NSUInteger: "Q" in the encoding.
        try b.method("applicationShouldTerminate:", &applicationShouldTerminate, "Q@:@");
        app_delegate_class = b.finish();
    } else {
        app_delegate_class = try objc.class("ZigUIKitAppDelegate");
    }
    return app_delegate_class.?;
}

fn windowWillClose(self: id, _: objc.SEL, _: id) callconv(.c) void {
    const w = objc.getState(Window, self, delegate_class.?) orelse return;
    w.closed = true;
}

fn windowDidChangeBacking(self: id, _: objc.SEL, _: id) callconv(.c) void {
    // Polled in `pump` as well; this makes a scale change between frames
    // impossible to miss when the size happens to be unchanged.
    const w = objc.getState(Window, self, delegate_class.?) orelse return;
    w.resized = true;
}

fn windowDidResignKey(self: id, _: objc.SEL, _: id) callconv(.c) void {
    // The input method's composition belongs to the key window. Committing
    // what is marked when focus leaves is what every Mac text view does, and
    // it stops a composition outliving the keyboard that was making it.
    const w = objc.getState(Window, self, delegate_class.?) orelse return;
    w.focused = false;
    const t = w.text orelse return;
    if (ic.hasMarkedText(t.doc)) {
        ic.unmarkText(t.doc);
        w.ime.unmarked += 1;
        w.text_changed = true;
    }
}

fn applicationShouldTerminate(_: id, _: objc.SEL, _: id) callconv(.c) objc.NSUInteger {
    if (app_delegate_target) |w| w.closed = true;
    return NSTerminateCancel;
}

// ------------------------------------------------------------------ the view
//
// `ZigUIKitView`: an `NSView` that hosts the layer, accepts first responder,
// and conforms to `NSTextInputClient`. Every method below converts its
// arguments and calls into `input_client.zig` or `editing.zig`; none of them
// decides anything about text.
//
// Type encodings: `B` is `BOOL` on Apple silicon (a C `bool`) and `c` on
// Intel (a `signed char`); `{_NSRange=QQ}` is an `NSRange` by value; and a
// method returning a `CGRect` is written as one, the Zig function returning
// the struct -- the C calling convention then does whatever the architecture
// requires, which on arm64 is a hidden pointer the runtime supplies.

const B = if (objc.BOOL == bool) "B" else "c";
const R = "{_NSRange=QQ}";
const RECT = "{CGRect={CGPoint=dd}{CGSize=dd}}";

fn viewClass() Error!objc.Class {
    if (view_class) |c| return c;
    if (try objc.ClassBuilder.begin("NSView", "ZigUIKitView")) |b| {
        try b.requireProtocol("NSTextInputClient");
        try b.method("acceptsFirstResponder", &acceptsFirstResponder, B ++ "@:");
        try b.method("keyDown:", &keyDown, "v@:@");
        try b.method("selectAll:", &selectAll, "v@:@");
        try b.method("mouseDown:", &mouseDown, "v@:@");
        try b.method("setFrameSize:", &setFrameSize, "v@:{CGSize=dd}");
        try b.method("viewWillStartLiveResize", &willStartLiveResize, "v@:");
        try b.method("viewDidEndLiveResize", &didEndLiveResize, "v@:");
        try b.method("mouseDragged:", &mouseDragged, "v@:@");
        try b.method("mouseUp:", &mouseUp, "v@:@");
        try b.method("scrollWheel:", &scrollWheel, "v@:@");
        try b.method("inputContext", &inputContext, "@@:");
        try b.method("insertText:", &insertTextPlain, "v@:@");

        try b.method("insertText:replacementRange:", &insertText, "v@:@" ++ R);
        try b.method("setMarkedText:selectedRange:replacementRange:", &setMarkedText, "v@:@" ++ R ++ R);
        try b.method("unmarkText", &unmarkText, "v@:");
        try b.method("doCommandBySelector:", &doCommandBySelector, "v@::");
        try b.method("selectedRange", &selectedRange, R ++ "@:");
        try b.method("markedRange", &markedRange, R ++ "@:");
        try b.method("hasMarkedText", &hasMarkedText, B ++ "@:");
        try b.method("attributedSubstringForProposedRange:actualRange:", &attributedSubstring, "@@:" ++ R ++ "^" ++ R);
        try b.method("validAttributesForMarkedText", &validAttributes, "@@:");
        try b.method("firstRectForCharacterRange:actualRange:", &firstRect, RECT ++ "@:" ++ R ++ "^" ++ R);
        try b.method("characterIndexForPoint:", &characterIndex, "Q@:{CGPoint=dd}");

        // The accessibility side: the view stands for the tree's root.
        try b.method("accessibilityChildren", &axChildren, "@@:");
        try b.method("accessibilityFocusedUIElement", &axFocused, "@@:");
        try b.method("accessibilityHitTest:", &axHitTest, "@@:{CGPoint=dd}");
        view_class = b.finish();
    } else {
        view_class = try objc.class("ZigUIKitView");
    }
    return view_class.?;
}

fn stateOf(self: id) ?*Window {
    return objc.getState(Window, self, view_class.?);
}

/// The text of an argument AppKit documents as "an `NSString` or an
/// `NSAttributedString`": both arrive, depending on the input method.
fn plainText(obj: id) []const u8 {
    const attributed = objc.class("NSAttributedString") catch return objc.utf8(obj);
    if (objc.truthy(send(objc.BOOL, obj, "isKindOfClass:", .{attributed}))) {
        return objc.utf8(send(id, obj, "string", .{}));
    }
    return objc.utf8(obj);
}

fn acceptsFirstResponder(_: id, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn keyDown(self: id, _: objc.SEL, event: id) callconv(.c) void {
    // Straight back to AppKit, which runs the input method and the key
    // bindings and calls one of the methods below. See the module comment.
    const arr = send(id, objc.class("NSArray") catch return, "arrayWithObject:", .{event});
    send(void, self, "interpretKeyEvents:", .{arr});
}

fn selectAll(self: id, _: objc.SEL, _: ?id) callconv(.c) void {
    const w = stateOf(self) orelse return;
    _ = runCommand(w, .{ .op = .select_all });
}

/// Whether the field took the command. One it did not take is the
/// application's: Enter in a single-line field, or up and down in a field
/// with no line to move to.
fn runCommand(w: *Window, cmd: ui.editing.Command) bool {
    // Only the commands that read the line table need it current; the rest
    // are about bytes, and laying the text out for them would be waste.
    const needs_lines = switch (cmd.op) {
        .line_up, .line_down, .line_start, .line_end, .delete_to_line_start, .delete_to_line_end => true,
        else => false,
    };
    const t = (if (needs_lines) w.textGeometry() else w.text) orelse return false;
    var opt = t.options;
    opt.goal_x = w.goal_x;
    const res = ui.editing.applyCommand(t.doc, cmd, opt) catch {
        w.ime.refused += 1;
        return true;
    };
    w.ime.commands += 1;
    // Null from anything but a vertical move, which is how the column is
    // forgotten.
    w.goal_x = res.goal_x;
    if ((cmd.op == .line_up or cmd.op == .line_down) and res.moved) w.ime.vertical += 1;
    if (res.edited) w.text_stale = true;
    if (res.edited or res.moved) w.text_changed = true;
    if (!res.handled and cmd.op == .newline) {
        w.keys.push(ui.KeyEvent.named(.enter));
        return true;
    }
    return res.handled;
}

/// The document's bytes changed under the window's feet: by typing, by the
/// input method. The column is forgotten, as any edit forgets it, and the
/// geometry is stale until something lays the text out.
fn bytesChanged(w: *Window) void {
    w.text_changed = true;
    w.text_stale = true;
    w.goal_x = null;
}

fn insertText(self: id, _: objc.SEL, string: id, replacement: ic.Utf16Range) callconv(.c) void {
    const w = stateOf(self) orelse return;
    const s = plainText(string);
    // Control characters reach here from some input methods; they are not
    // text, for the reason `editing.isInsertable` gives.
    if (!ui.editing.isInsertable(s)) return;
    w.ime.inserted += 1;
    if (!replacement.isNone()) w.ime.replaced += 1;
    const t = w.text orelse {
        var ev: ui.KeyEvent = .{};
        if (ev.setText(s)) w.keys.push(ev);
        return;
    };
    _ = ic.insertText(t.doc, s, replacement) catch {
        w.ime.refused += 1;
        return;
    };
    bytesChanged(w);
}

fn setMarkedText(self: id, _: objc.SEL, string: id, sel: ic.Utf16Range, replacement: ic.Utf16Range) callconv(.c) void {
    const w = stateOf(self) orelse return;
    const t = w.text orelse return;
    const s = plainText(string);
    if (s.len == 0) w.ime.cancelled += 1 else w.ime.marked += 1;
    ic.setMarkedText(t.doc, s, sel, replacement) catch {
        w.ime.refused += 1;
        return;
    };
    bytesChanged(w);
}

fn unmarkText(self: id, _: objc.SEL) callconv(.c) void {
    const w = stateOf(self) orelse return;
    const t = w.text orelse return;
    w.ime.unmarked += 1;
    ic.unmarkText(t.doc);
    w.text_changed = true;
}

fn doCommandBySelector(self: id, _: objc.SEL, which: objc.SEL) callconv(.c) void {
    const w = stateOf(self) orelse return;
    const name = objc.selName(which);
    if (ic.commandForSelector(name)) |cmd| {
        if (w.text != null and runCommand(w, cmd)) return;
    }
    w.ime.passed_on += 1;
    if (ic.keyForSelector(name)) |ev| w.keys.push(ev);
    // Anything else -- `noop:` for a Cmd chord with no binding, `complete:`
    // for Escape in some layouts -- is dropped. NSTextView beeps; a toolkit
    // that wants to beep can do it from the counters.
}

fn selectedRange(self: id, _: objc.SEL) callconv(.c) ic.Utf16Range {
    const w = stateOf(self) orelse return .none;
    const t = w.text orelse return .none;
    return ic.selectedRange(t.doc);
}

fn markedRange(self: id, _: objc.SEL) callconv(.c) ic.Utf16Range {
    const w = stateOf(self) orelse return .none;
    const t = w.text orelse return .none;
    return ic.markedRange(t.doc);
}

fn hasMarkedText(self: id, _: objc.SEL) callconv(.c) objc.BOOL {
    const w = stateOf(self) orelse return objc.NO;
    const t = w.text orelse return objc.NO;
    return if (ic.hasMarkedText(t.doc)) objc.YES else objc.NO;
}

fn attributedSubstring(self: id, _: objc.SEL, range: ic.Utf16Range, actual: ?*ic.Utf16Range) callconv(.c) ?id {
    const w = stateOf(self) orelse return null;
    const t = w.text orelse return null;
    w.ime.substring_queries += 1;
    const got = ic.substring(t.doc, range) orelse return null;
    if (actual) |a| a.* = got.actual;
    const cls = objc.class("NSAttributedString") catch return null;
    const str = send(id, send(id, cls, "alloc", .{}), "initWithString:", .{objc.stringFromSlice(got.text)});
    return send(id, str, "autorelease", .{});
}

fn validAttributes(_: id, _: objc.SEL) callconv(.c) ?id {
    // No attributes: marked text is drawn underlined by the application, the
    // way the document model says provisional text is drawn, whatever the
    // input method would like. An empty array is a valid answer; nil is not.
    return send(id, objc.class("NSArray") catch return null, "array", .{});
}

fn firstRect(self: id, _: objc.SEL, range: ic.Utf16Range, actual: ?*ic.Utf16Range) callconv(.c) objc.CGRect {
    const zero: objc.CGRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    const w = stateOf(self) orelse return zero;
    w.ime.rect_queries += 1;
    var local: ui.Rect = .{};
    if (w.textGeometry()) |t| {
        const b = ic.toBytes(t.doc.text(), range);
        if (actual) |a| a.* = ic.fromBytes(t.doc.text(), b);
        if (t.rect) |f| local = f(t.ctx, b);
    }
    return w.layoutRectToScreen(local);
}

fn axChildren(self: id, _: objc.SEL) callconv(.c) ?id {
    const w = stateOf(self) orelse return null;
    return ax.viewChildren(w);
}

fn axFocused(self: id, _: objc.SEL) callconv(.c) ?id {
    const w = stateOf(self) orelse return self;
    return ax.viewFocused(w, self);
}

fn axHitTest(self: id, _: objc.SEL, p: objc.CGPoint) callconv(.c) ?id {
    const w = stateOf(self) orelse return self;
    return ax.viewHitTest(w, self, p);
}

fn setFrameSize(self: id, _: objc.SEL, size: objc.CGSize) callconv(.c) void {
    objc.sendSuper(void, self, view_class.?, "setFrameSize:", .{size});
    const w = stateOf(self) orelse return;
    if (!w.live.active) return;
    w.live.steps += 1;
    w.width = @intFromFloat(@max(size.width, 0));
    w.height = @intFromFloat(@max(size.height, 0));
    w.scale = @floatCast(send(objc.CGFloat, w.window, "backingScaleFactor", .{}));
    w.resized = true;
    if (w.live_frame) |lf| {
        lf.draw(lf.ctx, w);
        w.live.frames += 1;
    }
}

fn willStartLiveResize(self: id, _: objc.SEL) callconv(.c) void {
    objc.sendSuper(void, self, view_class.?, "viewWillStartLiveResize", .{});
    const w = stateOf(self) orelse return;
    w.live.active = true;
    w.live.resizes += 1;
    // For the drag only: each present is then part of the Core Animation
    // transaction that moves the window's edge, so the new frame and the new
    // size appear together. Out of a resize it would cost latency for nothing.
    send(void, w.layer, "setPresentsWithTransaction:", .{objc.YES});
}

fn didEndLiveResize(self: id, _: objc.SEL) callconv(.c) void {
    objc.sendSuper(void, self, view_class.?, "viewDidEndLiveResize", .{});
    const w = stateOf(self) orelse return;
    w.live.active = false;
    send(void, w.layer, "setPresentsWithTransaction:", .{objc.NO});
}

/// Where an event's location is in the text, through the target's hit test.
fn hitOf(w: *Window, event: id, clamp: bool) ?ui.editing.Hit {
    const t = w.textGeometry() orelse return null;
    const f = t.hit orelse return null;
    const loc = send(objc.CGPoint, event, "locationInWindow", .{});
    const v = send(objc.CGPoint, w.view, "convertPoint:fromView:", .{ loc, @as(?id, null) });
    const bounds = send(objc.CGRect, w.view, "bounds", .{});
    return f(t.ctx, t.doc, .{ .x = @floatCast(v.x), .y = @floatCast(bounds.size.height - v.y) }, clamp);
}

/// Offers a mouse event to the input method, which sees them first: a click
/// inside marked text is how a user picks a point in a composition, and only
/// the input method knows what that means.
fn toInputMethod(self: id, event: id) bool {
    const ctx = send(?id, self, "inputContext", .{}) orelse return false;
    return objc.truthy(send(objc.BOOL, ctx, "handleEvent:", .{event}));
}

/// Where a mouse event is, in layout units.
fn layoutPointOf(w: *Window, event: id) ui.Point {
    const loc = send(objc.CGPoint, event, "locationInWindow", .{});
    const v = send(objc.CGPoint, w.view, "convertPoint:fromView:", .{ loc, @as(?id, null) });
    const bounds = send(objc.CGRect, w.view, "bounds", .{});
    return .{ .x = @floatCast(v.x), .y = @floatCast(bounds.size.height - v.y) };
}

fn toApplication(w: *Window, event: id, kind: Window.MouseKind) void {
    const h = w.pointer_hook orelse return;
    const clicks: u32 = @intCast(@max(1, send(objc.NSInteger, event, "clickCount", .{})));
    const flags = send(objc.NSUInteger, event, "modifierFlags", .{});
    h.event(h.ctx, w, .{ .kind = kind, .p = layoutPointOf(w, event), .clicks = clicks, .shift = flags & (1 << 17) != 0 });
}

fn mouseDown(self: id, _: objc.SEL, event: id) callconv(.c) void {
    const w = stateOf(self) orelse return;
    if (w.text != null and toInputMethod(self, event)) {
        w.ime.presses_to_input_method += 1;
        return;
    }
    // The application first, which may move focus and so change the text
    // target. See `setPointerHook`.
    toApplication(w, event, .down);
    const t = w.text orelse return;
    const at = hitOf(w, event, false) orelse return;
    // The input method declined the click, so the composition ends where it
    // stands: committed, and the input method told to drop its state. This
    // is what NSTextView does, and the alternative -- a caret outside a
    // composition that is still provisional -- is the state `canEditNow`
    // exists to forbid.
    if (ic.hasMarkedText(t.doc)) {
        ic.unmarkText(t.doc);
        if (send(?id, self, "inputContext", .{})) |ctx| send(void, ctx, "discardMarkedText", .{});
        w.ime.committed_by_click += 1;
        w.text_changed = true;
    }
    const clicks: u32 = @intCast(@max(1, send(objc.NSInteger, event, "clickCount", .{})));
    const flags = send(objc.NSUInteger, event, "modifierFlags", .{});
    const p = ui.editing.press(t.doc, at, clicks, flags & (1 << 17) != 0) catch {
        w.ime.refused += 1;
        return;
    };
    w.gesture = p.gesture;
    w.goal_x = null;
    w.ime.presses += 1;
    if (p.result.moved) w.text_changed = true;
}

fn mouseDragged(self: id, _: objc.SEL, event: id) callconv(.c) void {
    const w = stateOf(self) orelse return;
    if (w.text != null and toInputMethod(self, event)) return;
    toApplication(w, event, .dragged);
    const t = w.text orelse return;
    const g = w.gesture orelse return;
    const at = hitOf(w, event, true) orelse return;
    const res = ui.editing.drag(t.doc, g, at) catch return;
    if (res.moved) w.text_changed = true;
}

/// What a scroll view scrolls for one line of a wheel that reports lines:
/// `NSScrollView`'s default `verticalLineScroll`, measured.
const line_scroll: f32 = 10;

fn scrollWheel(self: id, _: objc.SEL, event: id) callconv(.c) void {
    const w = stateOf(self) orelse return;
    const precise = objc.truthy(send(objc.BOOL, event, "hasPreciseScrollingDeltas", .{}));
    const unit: f32 = if (precise) 1 else line_scroll;
    const dx: f32 = @floatCast(send(objc.CGFloat, event, "scrollingDeltaX", .{}));
    const dy: f32 = @floatCast(send(objc.CGFloat, event, "scrollingDeltaY", .{}));
    // AppKit's deltas are positive when the content should move down and
    // right; the tree's are the other way.
    w.scroll_x -= dx * unit;
    w.scroll_y -= dy * unit;
    w.scroll_at = layoutPointOf(w, event);
    w.scroll_events += 1;
    if (precise) w.scroll_precise += 1;
}

fn mouseUp(self: id, _: objc.SEL, event: id) callconv(.c) void {
    const w = stateOf(self) orelse return;
    if (w.text != null) _ = toInputMethod(self, event);
    toApplication(w, event, .up);
    w.gesture = null;
}

/// `NSResponder`'s `insertText:`, the one-argument form, which is what the
/// key bindings call when there is no input context -- that is, while nothing
/// editable has focus (`inputContext` below). Without it, Space with a button
/// focused went up the responder chain and was lost: measured, by `--focus`.
fn insertTextPlain(self: id, sel: objc.SEL, string: id) callconv(.c) void {
    insertText(self, sel, string, ic.Utf16Range.none);
}

/// No input context while nothing editable has focus.
///
/// AppKit routes keys through the first responder's input context, and the
/// view is the first responder whichever element has focus inside it. With
/// a button focused, Vietnamese Telex would otherwise go on composing --
/// reading context from a document nobody is editing, and turning Space into
/// part of a word instead of a press. Returning nil makes `interpretKeyEvents:`
/// run the key bindings alone, so Space is `insertText:` and Tab is
/// `insertTab:`, both of which reach the application as keys.
fn inputContext(self: id, _: objc.SEL) callconv(.c) ?id {
    const w = stateOf(self) orelse return null;
    if (w.text == null) return null;
    return objc.sendSuper(?id, self, view_class.?, "inputContext", .{});
}

fn characterIndex(self: id, _: objc.SEL, screen: objc.CGPoint) callconv(.c) objc.NSUInteger {
    // Asked by an input method about a click inside its marked text: which
    // character, in UTF-16, is under this screen point.
    const w = stateOf(self) orelse return ic.not_found;
    const t = w.textGeometry() orelse return ic.not_found;
    const f = t.hit orelse return ic.not_found;
    const h = f(t.ctx, t.doc, w.screenPointToLayout(screen), false) orelse return ic.not_found;
    return ui.offsets.byteToUtf16(t.doc.text(), h.char);
}
