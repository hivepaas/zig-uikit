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
//! The delegate is a class defined at run time (see `objc.ClassBuilder`), which
//! is the mechanism `NSTextInputClient` and `NSAccessibility` will need, done
//! first where it is small: two methods, one instance variable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");
const id = objc.id;
const send = objc.send;

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
        const view = send(id, send(id, try objc.class("NSView"), "alloc", .{}), "initWithFrame:", .{rect});
        const layer = objc.retain(send(id, try objc.class("CAMetalLayer"), "layer", .{}));
        send(void, view, "setLayer:", .{layer});
        send(void, view, "setWantsLayer:", .{objc.YES});
        send(void, window, "setContentView:", .{view});

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
        if (!self.closed) send(void, self.window, "close", .{});
        objc.release(self.delegate);
        objc.release(self.layer);
        objc.release(self.view);
        objc.release(self.window);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// The content size in pixels: what the layer's drawables should be.
    pub fn pixelWidth(self: *const Window) u32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(self.width)) * self.scale));
    }

    pub fn pixelHeight(self: *const Window) u32 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(self.height)) * self.scale));
    }

    /// Processes every queued event without blocking, then samples the size
    /// and the pointer.
    ///
    /// The pointer is polled rather than tracked through `mouseMoved:`
    /// events. The window demo wants the pointer's position once per frame,
    /// not every intermediate position, and polling needs no view subclass and
    /// no tracking area. Clicks and keys will need events; hover does not.
    pub fn pump(self: *Window) void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();

        const distant_past = send(id, objc.class("NSDate") catch unreachable, "distantPast", .{});
        while (send(?id, self.app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
            NSEventMaskAny, distant_past, NSDefaultRunLoopMode, objc.YES,
        })) |ev| {
            send(void, self.app, "sendEvent:", .{ev});
        }
        if (self.closed) return;

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
    send(void, app, "setMainMenu:", .{menubar});
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

fn delegateClass() Error!objc.Class {
    if (delegate_class) |c| return c;
    if (try objc.ClassBuilder.begin("NSObject", "ZigUIKitWindowDelegate")) |b| {
        b.protocol("NSWindowDelegate");
        try b.method("windowWillClose:", &windowWillClose, "v@:@");
        try b.method("windowDidChangeBackingProperties:", &windowDidChangeBacking, "v@:@");
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

fn applicationShouldTerminate(_: id, _: objc.SEL, _: id) callconv(.c) objc.NSUInteger {
    if (app_delegate_target) |w| w.closed = true;
    return NSTerminateCancel;
}
