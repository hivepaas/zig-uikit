//! A Wayland window: `xdg_shell` surface, configure handling, the pointer, the
//! keyboard and the input method.
//!
//! Heap-allocated and returned by pointer, which is not a style choice. Every
//! Wayland listener is given a `void *` that it keeps for the life of the
//! object, so a `Window` returned by value would hand the compositor the
//! address of a temporary.
//!
//! There is no drawing here. The window owns the surface; `src/gpu/swapchain.zig`
//! wraps that surface in a `VkSurfaceKHR` and everything visible happens
//! through Vulkan.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("vk");
const ui = @import("zig-uikit");

pub const Error = error{
    NoWaylandDisplay,
    MissingGlobal,
    SurfaceFailed,
    /// `xkb_context_new` failed, which in practice means the system has no
    /// keymap data installed. Fatal rather than degraded: a window that cannot
    /// translate a scancode cannot be typed into, and finding that out at the
    /// first keystroke is worse than finding it out at start-up.
    NoKeymapSupport,
} || Allocator.Error;

pub const Window = struct {
    gpa: Allocator,

    display: *c.struct_wl_display,
    registry: ?*c.struct_wl_registry = null,
    compositor: ?*c.struct_wl_compositor = null,
    wm_base: ?*c.struct_xdg_wm_base = null,
    seat: ?*c.struct_wl_seat = null,
    pointer: ?*c.struct_wl_pointer = null,
    keyboard: ?*c.struct_wl_keyboard = null,

    // --- the keyboard ---
    //
    // The compositor sends evdev scancodes and a keymap, and nothing else.
    // Everything from scancode to text happens in this process, through xkb:
    // which character a key produces, whether Shift was held, and -- because
    // the protocol does not repeat keys for you -- when a held key should
    // produce another one.
    xkb_ctx: ?*c.struct_xkb_context = null,
    xkb_keymap: ?*c.struct_xkb_keymap = null,
    xkb_state: ?*c.struct_xkb_state = null,

    /// Keystrokes waiting to be drained, oldest first.
    ///
    /// A queue and not a "last key pressed" field, because a frame can contain
    /// several keystrokes and a text field that keeps only the newest loses
    /// characters at exactly the moment someone is typing fast enough to care.
    keys: ui.KeyQueue = .{},
    /// Whether this surface has keyboard focus. A window without it must draw
    /// no caret, and must not repeat a key.
    focused: bool = false,

    /// What `repeat_info` asked for: keys per second, and the delay in
    /// milliseconds before repeating starts. Defaults match what compositors
    /// send when they send anything at all, because the event is optional and
    /// a keyboard that does not repeat feels broken.
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
    /// The scancode being held, or zero. Only one: a second key going down
    /// takes over, which is what every other toolkit does and what typing
    /// `aaa` then holding `b` feels like.
    repeat_code: u32 = 0,
    repeat_event: ui.KeyEvent = .{},
    repeat_at_ns: u64 = 0,

    /// The name of the active layout, for reporting. Copied rather than
    /// borrowed: the keymap it belongs to is replaced whenever the layout
    /// changes.
    layout_buf: [64]u8 = @splat(0),
    layout_len: u8 = 0,

    // --- the input method ---
    //
    // `zwp_text_input_v3` is double-buffered in both directions. Requests do
    // nothing until `commit`; events do nothing until `done`. Everything
    // below with `pend_` in its name is state the compositor has sent that
    // must not be applied yet, and applying each event as it arrives is the
    // bug that produces flicker and doubled characters mid-composition.
    ti_manager: ?*c.struct_zwp_text_input_manager_v3 = null,
    text_input: ?*c.struct_zwp_text_input_v3 = null,

    /// The document that has text-input focus.
    ///
    /// A pointer and not a queue of events, unlike the keyboard, because this
    /// is what the protocol itself models: `zwp_text_input_v3` is per-seat and
    /// refers to whichever field is focused. It also puts the resync rule
    /// below somewhere it cannot be got wrong once per application.
    ime_doc: ?*ui.Document = null,
    /// Whether the compositor has given this surface text-input focus.
    ti_entered: bool = false,
    ime_enabled: bool = false,

    /// Commits issued so far. `done` carries the one the compositor saw, and a
    /// mismatch means a commit of ours is still in flight.
    ime_serial: u32 = 0,
    stale_dones: u32 = 0,

    pending: Pending = .{},

    /// Resyncs this window decided to send. Counted because the decision is
    /// the protocol trap: too many is an infinite loop, too few is an input
    /// method working from a document that no longer exists.
    ime_resyncs: u32 = 0,
    /// How many times this surface was given text-input focus. Zero at exit
    /// means the input method never saw the field at all, which looks exactly
    /// like a broken implementation and is usually a window that was never
    /// focused.
    ime_enters: u32 = 0,

    /// One counter per event the input method sends, in the same shape spike B
    /// printed on exit. They are how a session that produced nothing is told
    /// apart from one the protocol never reached: `done` arriving at all means
    /// the requests went out and the compositor answered, and a preedit count
    /// of zero after typing means the input method is not engaged.
    ime_events: Counters = .{},

    /// Set when a `done` changed the document or the preedit; the application
    /// clears it with `takeImeDirty`.
    ime_dirty: bool = false,
    /// The first failure applying a `done`. A libwayland callback has nowhere
    /// to return an error to, so it is kept here instead of swallowed.
    ime_error: ?anyerror = null,

    /// The caret, in **surface** coordinates.
    ///
    /// Surface and not screen, which is worth saying because the other three
    /// protocols this toolkit has to answer want screen coordinates and this
    /// one does not. `set_cursor_rectangle` is surface-local, so placing a
    /// candidate window correctly needs the text layout and nothing from the
    /// compositor about where the window is.
    ime_caret: ui.Rect = .{},
    /// A NUL-terminated copy of the surrounding text, because the protocol
    /// takes a C string and the document is a slice.
    surround_z: std.ArrayList(u8) = .empty,

    surface: ?*c.struct_wl_surface = null,
    xdg_surface: ?*c.struct_xdg_surface = null,
    toplevel: ?*c.struct_xdg_toplevel = null,

    width: u32,
    height: u32,
    /// What the compositor last asked for, applied when the matching
    /// `xdg_surface.configure` arrives. A toplevel configure on its own is not
    /// permission to resize; the surface configure that follows it is.
    pending_w: u32 = 0,
    pending_h: u32 = 0,

    configured: bool = false,
    closed: bool = false,
    /// Set when the size changed and cleared by the caller once it has acted.
    resized: bool = false,

    pointer_x: f32 = -1,
    pointer_y: f32 = -1,
    pointer_inside: bool = false,
    clicked: bool = false,

    /// Scroll accumulated since the application last took it, in surface
    /// units -- the same space pointer motion is in, which is what the
    /// protocol says and what makes a touchpad's smooth scrolling come out as
    /// a distance rather than as notches.
    ///
    /// Accumulated rather than delivered one event at a time because a
    /// compositor sends several axis events per frame and a scroll is a
    /// distance: adding them up loses nothing, where a queue would make the
    /// caller add them up itself.
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,

    pub fn open(gpa: Allocator, title: [*:0]const u8, w: u32, h: u32) Error!*Window {
        const display = c.wl_display_connect(null) orelse return Error.NoWaylandDisplay;
        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .display = display, .width = w, .height = h };

        // Before the roundtrip, because the keymap arrives as a consequence of
        // binding the seat and the handler for it needs somewhere to compile
        // into.
        self.xkb_ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse
            return Error.NoKeymapSupport;

        self.registry = c.wl_display_get_registry(display);
        _ = c.wl_registry_add_listener(self.registry, &registry_listener, self);
        _ = c.wl_display_roundtrip(display);

        if (self.compositor == null or self.wm_base == null) return Error.MissingGlobal;

        // Both globals are known by now, which is why this is here and not in
        // the registry handler: a text input is created from the manager *and*
        // the seat, and the two arrive in whichever order the compositor
        // chooses to advertise them.
        if (self.ti_manager) |mgr| {
            if (self.seat) |seat| {
                self.text_input = c.zwp_text_input_manager_v3_get_text_input(mgr, seat);
                _ = c.zwp_text_input_v3_add_listener(self.text_input, &text_input_listener, self);
            }
        }

        self.surface = c.wl_compositor_create_surface(self.compositor) orelse return Error.SurfaceFailed;
        self.xdg_surface = c.xdg_wm_base_get_xdg_surface(self.wm_base, self.surface) orelse
            return Error.SurfaceFailed;
        _ = c.xdg_surface_add_listener(self.xdg_surface, &xdg_surface_listener, self);
        self.toplevel = c.xdg_surface_get_toplevel(self.xdg_surface) orelse return Error.SurfaceFailed;
        _ = c.xdg_toplevel_add_listener(self.toplevel, &toplevel_listener, self);
        c.xdg_toplevel_set_title(self.toplevel, title);
        c.xdg_toplevel_set_app_id(self.toplevel, "dev.zig-uikit.demo");

        // A surface has to be committed with no buffer before the compositor
        // will send the first configure, and nothing may be drawn until it has.
        c.wl_surface_commit(self.surface);
        while (!self.configured) {
            if (c.wl_display_dispatch(display) < 0) return Error.SurfaceFailed;
        }
        // One more round trip so the keymap and the repeat rate have arrived.
        // They are sent as a consequence of binding the keyboard, not of the
        // surface being configured, so without this `layoutName` is empty
        // until the first frame and a key pressed in the first few
        // milliseconds would be dropped for want of a keymap.
        _ = c.wl_display_roundtrip(display);
        return self;
    }

    pub fn close(self: *Window) void {
        if (self.toplevel) |t| c.xdg_toplevel_destroy(t);
        if (self.xdg_surface) |x| c.xdg_surface_destroy(x);
        if (self.surface) |s| c.wl_surface_destroy(s);
        if (self.pointer) |p| c.wl_pointer_destroy(p);
        if (self.keyboard) |k| c.wl_keyboard_release(k);
        if (self.text_input) |t| c.zwp_text_input_v3_destroy(t);
        if (self.ti_manager) |m| c.zwp_text_input_manager_v3_destroy(m);
        self.pending.deinit(self.gpa);
        self.surround_z.deinit(self.gpa);
        if (self.xkb_state) |x| c.xkb_state_unref(x);
        if (self.xkb_keymap) |k| c.xkb_keymap_unref(k);
        if (self.xkb_ctx) |x| c.xkb_context_unref(x);
        if (self.seat) |s| c.wl_seat_destroy(s);
        if (self.wm_base) |b| c.xdg_wm_base_destroy(b);
        if (self.compositor) |cp| c.wl_compositor_destroy(cp);
        if (self.registry) |r| c.wl_registry_destroy(r);
        c.wl_display_disconnect(self.display);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Processes whatever the compositor has sent, without blocking.
    ///
    /// `wl_display_dispatch` blocks when the socket is empty, so the socket is
    /// polled first with a zero timeout. Frame pacing is the swapchain's job --
    /// FIFO present blocks until vblank -- and doing it here as well would mean
    /// two things waiting on each other.
    pub fn pump(self: *Window) void {
        _ = c.wl_display_dispatch_pending(self.display);
        _ = c.wl_display_flush(self.display);
        var fds = [_]std.posix.pollfd{.{
            .fd = c.wl_display_get_fd(self.display),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const n = std.posix.poll(&fds, 0) catch 0;
        if (n > 0) {
            if (c.wl_display_dispatch(self.display) < 0) self.closed = true;
        }
        self.pumpRepeat();
    }

    /// Synthesises the repeats of a held key.
    ///
    /// Wayland does not repeat keys. The compositor sends one press and one
    /// release and tells the client the rate it should repeat at, so a client
    /// that does not do this has a keyboard where holding Backspace deletes
    /// one character. Driven from `pump` rather than from a timer thread:
    /// there is already a loop running once per frame, and 60 Hz is finer
    /// granularity than the fastest repeat rate any compositor offers.
    fn pumpRepeat(self: *Window) void {
        if (self.repeat_code == 0 or self.repeat_rate <= 0) return;
        const interval: u64 = 1_000_000_000 / @as(u64, @intCast(self.repeat_rate));
        const now = nowNs();
        var emitted: u32 = 0;
        while (now >= self.repeat_at_ns) {
            self.keys.push(self.repeat_event);
            self.repeat_at_ns += interval;
            emitted += 1;
            // After a stall -- a slow frame, a swapchain recreation, the
            // process descheduled -- the accumulated deadline can be a long
            // way behind, and paying off the whole debt would insert a burst
            // of keystrokes nobody typed. Resync to now instead and say so
            // here, because the alternative looks like a dropped keystroke and
            // is actually a deliberate one.
            if (emitted >= 4) {
                self.repeat_at_ns = now + interval;
                break;
            }
        }
    }

    /// Stops a held key from repeating. Called on release and on focus loss;
    /// the second is the one that matters, because a key released while
    /// another window has focus sends this window no release event at all, and
    /// a repeat that is never cancelled types forever.
    fn stopRepeat(self: *Window) void {
        self.repeat_code = 0;
        self.repeat_at_ns = 0;
    }

    /// How far the pointer has scrolled since this was last asked, and clears
    /// it. Zero when nothing scrolled.
    pub fn takeScroll(self: *Window) ui.Point {
        defer {
            self.scroll_x = 0;
            self.scroll_y = 0;
        }
        return .{ .x = self.scroll_x, .y = self.scroll_y };
    }

    /// The active keyboard layout's name, or an empty string before the keymap
    /// has arrived.
    pub fn layoutName(self: *const Window) []const u8 {
        return self.layout_buf[0..self.layout_len];
    }

    // ------------------------------------------------------- input method

    /// Whether the compositor offers `zwp_text_input_manager_v3` at all.
    ///
    /// Worth asking before anything else: when it is absent, no client on that
    /// compositor can talk to an input method, and a text field that silently
    /// took raw keystrokes instead would look like a bug in this toolkit.
    pub fn hasInputMethod(self: *const Window) bool {
        return self.text_input != null;
    }

    /// Gives a document text-input focus, or takes it away.
    ///
    /// The document is borrowed for as long as it is focused, and the
    /// compositor may write into it from inside `pump`.
    pub fn focusTextInput(self: *Window, doc: ?*ui.Document) void {
        if (self.ime_doc == doc) return;
        self.ime_doc = doc;
        if (doc == null) self.disableTextInput() else self.enableTextInput();
    }

    /// Where the caret is, in surface coordinates, so the input method can put
    /// its candidate window beside it instead of at the window's origin --
    /// which is what all four spikes did, because none of them had a text
    /// layout to ask.
    ///
    /// Stored rather than sent: it goes out with the next state update, and
    /// every edit sends one.
    pub fn setCaretRect(self: *Window, r: ui.Rect) void {
        self.ime_caret = r;
    }

    /// Called after the *application* changed the focused document -- a
    /// keystroke, a click that moved the caret, a paste.
    ///
    /// The input method has to be told, because its next offsets are relative
    /// to text it believes is there. The change cause distinguishes this from
    /// the input method's own edits, which are not news to it.
    pub fn notifyTextChanged(self: *Window) void {
        self.sendState(.other);
    }

    /// Whether a `done` changed the focused document since this was last
    /// asked, and clears the flag.
    pub fn takeImeDirty(self: *Window) bool {
        defer self.ime_dirty = false;
        return self.ime_dirty;
    }

    fn enableTextInput(self: *Window) void {
        const ti = self.text_input orelse return;
        if (self.ime_enabled or !self.ti_entered or self.ime_doc == null) return;
        c.zwp_text_input_v3_enable(ti);
        c.zwp_text_input_v3_set_content_type(
            ti,
            c.ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE,
            c.ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL,
        );
        self.ime_enabled = true;
        // `enable` does nothing until a commit, and `sendState` ends with one.
        self.sendState(.other);
    }

    fn disableTextInput(self: *Window) void {
        const ti = self.text_input orelse return;
        if (!self.ime_enabled) return;
        c.zwp_text_input_v3_disable(ti);
        c.zwp_text_input_v3_commit(ti);
        self.ime_serial += 1;
        self.ime_enabled = false;
    }

    /// Sends the whole state the protocol wants and commits it.
    ///
    /// All of it every time, because the requests are a double-buffered set
    /// rather than a stream of deltas: a commit replaces the pending state
    /// with what was sent since the last one, so a request left out is a
    /// request that reverts.
    fn sendState(self: *Window, cause: ui.input_method.ChangeCause) void {
        const ti = self.text_input orelse return;
        if (!self.ime_enabled) return;
        const doc = self.ime_doc orelse return;

        const s = ui.input_method.surrounding(doc, ui.input_method.max_surrounding);
        self.surround_z.clearRetainingCapacity();
        self.surround_z.appendSlice(self.gpa, s.text) catch {
            self.ime_error = error.OutOfMemory;
            return;
        };
        self.surround_z.append(self.gpa, 0) catch {
            self.ime_error = error.OutOfMemory;
            return;
        };

        c.zwp_text_input_v3_set_surrounding_text(
            ti,
            @ptrCast(self.surround_z.items.ptr),
            @intCast(s.cursor),
            @intCast(s.anchor),
        );
        c.zwp_text_input_v3_set_text_change_cause(ti, switch (cause) {
            .input_method => c.ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_INPUT_METHOD,
            .other => c.ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_OTHER,
        });
        c.zwp_text_input_v3_set_cursor_rectangle(
            ti,
            @intFromFloat(self.ime_caret.x),
            @intFromFloat(self.ime_caret.y),
            @intFromFloat(@max(1, self.ime_caret.w)),
            @intFromFloat(@max(1, self.ime_caret.h)),
        );
        c.zwp_text_input_v3_commit(ti);
        self.ime_serial += 1;
    }
};

/// The double-buffered half of `zwp_text_input_v3`, with no Wayland objects in
/// it.
///
/// Separate from `Window` so the protocol's state machine can be driven by a
/// test: the five events below do nothing but fill this in, and `done` turns
/// it into one `Change`. What is left in the listeners is the part that calls
/// libwayland, which a test could not reach anyway.
pub const Pending = struct {
    commit: std.ArrayList(u8) = .empty,
    preedit: std.ArrayList(u8) = .empty,
    has_commit: bool = false,
    has_preedit: bool = false,
    cursor: ?ui.Range = null,
    delete_before: u32 = 0,
    delete_after: u32 = 0,
    /// An allocation that failed inside a callback with nowhere to return to.
    failed: bool = false,

    pub fn deinit(self: *Pending, gpa: Allocator) void {
        self.commit.deinit(gpa);
        self.preedit.deinit(gpa);
    }

    pub fn setCommit(self: *Pending, gpa: Allocator, text: []const u8) void {
        self.has_commit = true;
        self.commit.clearRetainingCapacity();
        self.commit.appendSlice(gpa, text) catch {
            self.failed = true;
        };
    }

    pub fn setPreedit(self: *Pending, gpa: Allocator, text: []const u8, begin: i32, end: i32) void {
        self.has_preedit = true;
        self.preedit.clearRetainingCapacity();
        self.preedit.appendSlice(gpa, text) catch {
            self.failed = true;
        };
        // -1 is the protocol's "draw no cursor", which is a request and not an
        // absence: an input method showing a candidate list often wants the
        // caret hidden while the list is up.
        self.cursor = if (begin < 0) null else .{
            .start = @intCast(begin),
            .end = @intCast(@max(end, begin)),
        };
    }

    pub fn change(self: *const Pending) ui.input_method.Change {
        return .{
            .delete_before = self.delete_before,
            .delete_after = self.delete_after,
            .commit = if (self.has_commit) self.commit.items else null,
            .preedit = if (self.has_preedit) self.preedit.items else null,
            .preedit_cursor = self.cursor,
        };
    }

    pub fn reset(self: *Pending) void {
        self.commit.clearRetainingCapacity();
        self.preedit.clearRetainingCapacity();
        self.has_commit = false;
        self.has_preedit = false;
        self.cursor = null;
        self.delete_before = 0;
        self.delete_after = 0;
    }
};

pub const Counters = struct {
    done: u32 = 0,
    preedit: u32 = 0,
    commit: u32 = 0,
    delete: u32 = 0,
};

/// Whether a `done` should be answered with fresh state.
///
/// **This one predicate is the protocol trap.** Returning true for a preedit
/// change is an infinite loop: the resync is a commit, the commit makes the
/// compositor send another `done`, and that `done` would resync again. Spike B
/// spun at full speed on an empty document before this rule existed. Returning
/// true for a stale `done` races a commit that is already in flight and will
/// produce its own `done` with the current serial.
pub fn shouldResync(r: ui.input_method.Result, stale: bool) bool {
    return r.document_changed and !stale;
}

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// ------------------------------------------------------------------ listeners

fn regGlobal(
    data: ?*anyopaque,
    reg: ?*c.struct_wl_registry,
    name: u32,
    iface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    _ = version;
    const self: *Window = @ptrCast(@alignCast(data.?));
    const s = std.mem.span(iface);
    if (std.mem.eql(u8, s, "wl_compositor")) {
        self.compositor = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_compositor_interface, 4));
    } else if (std.mem.eql(u8, s, "xdg_wm_base")) {
        self.wm_base = @ptrCast(c.wl_registry_bind(reg, name, &c.xdg_wm_base_interface, 1));
        _ = c.xdg_wm_base_add_listener(self.wm_base, &wm_base_listener, self);
    } else if (std.mem.eql(u8, s, "zwp_text_input_manager_v3")) {
        // Absent on a compositor with no input-method support, which is worth
        // reporting rather than crashing on: it means Wayland IME is
        // impossible for *any* client there, not just this one.
        self.ti_manager = @ptrCast(c.wl_registry_bind(reg, name, &c.zwp_text_input_manager_v3_interface, 1));
    } else if (std.mem.eql(u8, s, "wl_seat")) {
        // Version 5: enough for scroll frames, and short of the events that
        // only exist from version 8, which this listener does not handle.
        self.seat = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_seat_interface, 5));
        _ = c.wl_seat_add_listener(self.seat, &seat_listener, self);
    }
}

fn regRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}

const registry_listener: c.struct_wl_registry_listener = .{
    .global = regGlobal,
    .global_remove = regRemove,
};

fn wmPing(_: ?*anyopaque, base: ?*c.struct_xdg_wm_base, serial: u32) callconv(.c) void {
    c.xdg_wm_base_pong(base, serial);
}
const wm_base_listener: c.struct_xdg_wm_base_listener = .{ .ping = wmPing };

fn xdgConfigure(data: ?*anyopaque, surf: ?*c.struct_xdg_surface, serial: u32) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    c.xdg_surface_ack_configure(surf, serial);
    if (self.pending_w > 0 and self.pending_h > 0) {
        if (self.pending_w != self.width or self.pending_h != self.height) {
            self.width = self.pending_w;
            self.height = self.pending_h;
            self.resized = true;
        }
    }
    self.configured = true;
}
const xdg_surface_listener: c.struct_xdg_surface_listener = .{ .configure = xdgConfigure };

fn tlConfigure(
    data: ?*anyopaque,
    _: ?*c.struct_xdg_toplevel,
    w: i32,
    h: i32,
    _: [*c]c.struct_wl_array,
) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    // Zero means "you choose", which is what arrives for a floating window the
    // compositor has no opinion about.
    if (w > 0 and h > 0) {
        self.pending_w = @intCast(w);
        self.pending_h = @intCast(h);
    }
}
fn tlClose(data: ?*anyopaque, _: ?*c.struct_xdg_toplevel) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    self.closed = true;
}
fn tlBounds(_: ?*anyopaque, _: ?*c.struct_xdg_toplevel, _: i32, _: i32) callconv(.c) void {}
fn tlCaps(_: ?*anyopaque, _: ?*c.struct_xdg_toplevel, _: [*c]c.struct_wl_array) callconv(.c) void {}

const toplevel_listener: c.struct_xdg_toplevel_listener = .{
    .configure = tlConfigure,
    .close = tlClose,
    .configure_bounds = tlBounds,
    .wm_capabilities = tlCaps,
};

// -------------------------------------------------------------------- pointer

fn ptrEnter(
    data: ?*anyopaque,
    _: ?*c.struct_wl_pointer,
    _: u32,
    _: ?*c.struct_wl_surface,
    x: c.wl_fixed_t,
    y: c.wl_fixed_t,
) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    self.pointer_inside = true;
    self.pointer_x = fixedToFloat(x);
    self.pointer_y = fixedToFloat(y);
}

fn ptrLeave(data: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: ?*c.struct_wl_surface) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    self.pointer_inside = false;
    self.pointer_x = -1;
    self.pointer_y = -1;
}

fn ptrMotion(
    data: ?*anyopaque,
    _: ?*c.struct_wl_pointer,
    _: u32,
    x: c.wl_fixed_t,
    y: c.wl_fixed_t,
) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    self.pointer_x = fixedToFloat(x);
    self.pointer_y = fixedToFloat(y);
}

fn ptrButton(
    data: ?*anyopaque,
    _: ?*c.struct_wl_pointer,
    _: u32,
    _: u32,
    _: u32,
    state: u32,
) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    if (state == c.WL_POINTER_BUTTON_STATE_PRESSED) self.clicked = true;
}

/// The wheel, or two fingers on a touchpad.
///
/// Only `axis` is handled and not `axis_discrete`, which is deliberate: the
/// protocol always sends `axis` and sends `axis_discrete` as extra information
/// about the same movement, so acting on both scrolls twice.
fn ptrAxis(
    data: ?*anyopaque,
    _: ?*c.struct_wl_pointer,
    _: u32,
    axis: u32,
    value: c.wl_fixed_t,
) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    const v = fixedToFloat(value);
    switch (axis) {
        c.WL_POINTER_AXIS_VERTICAL_SCROLL => self.scroll_y += v,
        c.WL_POINTER_AXIS_HORIZONTAL_SCROLL => self.scroll_x += v,
        else => {},
    }
}
fn ptrFrame(_: ?*anyopaque, _: ?*c.struct_wl_pointer) callconv(.c) void {}
fn ptrAxisSource(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32) callconv(.c) void {}
fn ptrAxisStop(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32) callconv(.c) void {}
fn ptrAxisDiscrete(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: i32) callconv(.c) void {}

/// Every member is filled, including the ones this window has no use for.
/// libwayland calls whatever pointer is in the slot when the event arrives, so
/// a null for an event the compositor does send is a crash rather than a
/// no-op.
const pointer_listener: c.struct_wl_pointer_listener = .{
    .enter = ptrEnter,
    .leave = ptrLeave,
    .motion = ptrMotion,
    .button = ptrButton,
    .axis = ptrAxis,
    .frame = ptrFrame,
    .axis_source = ptrAxisSource,
    .axis_stop = ptrAxisStop,
    .axis_discrete = ptrAxisDiscrete,
};

fn seatCaps(data: ?*anyopaque, seat: ?*c.struct_wl_seat, caps: u32) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    if (caps & c.WL_SEAT_CAPABILITY_POINTER != 0 and self.pointer == null) {
        self.pointer = c.wl_seat_get_pointer(seat);
        _ = c.wl_pointer_add_listener(self.pointer, &pointer_listener, self);
    }
    if (caps & c.WL_SEAT_CAPABILITY_KEYBOARD != 0 and self.keyboard == null) {
        self.keyboard = c.wl_seat_get_keyboard(seat);
        _ = c.wl_keyboard_add_listener(self.keyboard, &keyboard_listener, self);
    }
}
fn seatName(_: ?*anyopaque, _: ?*c.struct_wl_seat, _: [*c]const u8) callconv(.c) void {}
const seat_listener: c.struct_wl_seat_listener = .{ .capabilities = seatCaps, .name = seatName };

/// Wayland sends coordinates as 24.8 fixed point.
fn fixedToFloat(v: c.wl_fixed_t) f32 {
    return @as(f32, @floatFromInt(v)) / 256.0;
}

// ------------------------------------------------------------------- keyboard
//
// The protocol's share of keyboard input is small and the client's share is
// large. What arrives is: a keymap, as a file descriptor holding xkb's text
// format; focus in and out; evdev scancodes with a pressed/released flag; the
// modifier masks, already resolved by the compositor; and the repeat rate the
// user configured. Everything else -- which character that scancode is, what
// Shift does to it, whether it should repeat, and when -- is this file's.

fn kbKeymap(
    data: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    format: u32,
    fd: i32,
    size: u32,
) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    // The fd is ours to close whatever happens next, including the paths that
    // give up on it. Leaking one per layout change is a slow leak that only
    // shows up on a machine where someone switches layouts all day.
    // `std.posix.close` was removed in Zig 0.17, so this is the raw syscall.
    defer _ = std.os.linux.close(fd);
    if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;

    // MAP_PRIVATE, not MAP_SHARED: the compositor may hand over a read-only
    // descriptor, and a shared mapping of one fails.
    const map = std.posix.mmap(
        null,
        size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ) catch return;
    defer std.posix.munmap(map);

    const km = c.xkb_keymap_new_from_string(
        self.xkb_ctx,
        @ptrCast(map.ptr),
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return;
    const st = c.xkb_state_new(km) orelse {
        c.xkb_keymap_unref(km);
        return;
    };

    // Replaced only once the new pair is built. A failure above leaves the old
    // keymap in place, which is a keyboard that still works rather than one
    // that silently stops producing characters.
    if (self.xkb_state) |old| c.xkb_state_unref(old);
    if (self.xkb_keymap) |old| c.xkb_keymap_unref(old);
    self.xkb_keymap = km;
    self.xkb_state = st;

    // The layout can change under a running window, so the name is copied
    // every time rather than read once at start-up.
    self.layout_len = 0;
    if (c.xkb_keymap_layout_get_name(km, 0)) |name| {
        const s = std.mem.span(name);
        const n = @min(s.len, self.layout_buf.len);
        @memcpy(self.layout_buf[0..n], s[0..n]);
        self.layout_len = @intCast(n);
    }

    // A keymap arriving while a key is held leaves the held scancode meaning
    // something else, so the repeat is dropped rather than continued with a
    // stale character.
    self.stopRepeat();
}

fn kbEnter(
    data: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    _: u32,
    _: ?*c.struct_wl_surface,
    _: [*c]c.struct_wl_array,
) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    self.focused = true;
    // The event carries the keys that were already down. They are deliberately
    // ignored: they were pressed at whatever had focus before, and delivering
    // them as presses here types a character into this window that was aimed
    // somewhere else.
    self.stopRepeat();
}

fn kbLeave(data: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: ?*c.struct_wl_surface) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    self.focused = false;
    self.stopRepeat();
    // The modifier state is also stale now: a Shift released while another
    // window had focus is a Shift this window is never told about, and it
    // would stay held forever.
    if (self.xkb_state) |st| _ = c.xkb_state_update_mask(st, 0, 0, 0, 0, 0, 0);
}

fn kbKey(
    data: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    _: u32,
    _: u32,
    key: u32,
    state: u32,
) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    const st = self.xkb_state orelse return;
    const km = self.xkb_keymap orelse return;

    // evdev numbers keys from 0; xkb numbers them from 8. The offset is not a
    // detail of either library, it is XKB's historical origin, and it is the
    // single most common mistake in a first Wayland keyboard implementation --
    // it produces a keyboard where every key is a few keys off.
    const code = key + 8;

    if (state != c.WL_KEYBOARD_KEY_STATE_PRESSED) {
        if (self.repeat_code == code) self.stopRepeat();
        return;
    }

    const ev = buildEvent(st, km, code);
    self.keys.push(ev);

    // Only keys the keymap says repeat. Without this check a held Shift
    // repeats, which does nothing visible, and a held Escape repeats, which
    // closes things more than once.
    if (c.xkb_keymap_key_repeats(km, code) != 0 and self.repeat_rate > 0) {
        self.repeat_code = code;
        var r = ev;
        r.repeat = true;
        self.repeat_event = r;
        self.repeat_at_ns = nowNs() + @as(u64, @intCast(self.repeat_delay)) * 1_000_000;
    } else {
        self.stopRepeat();
    }
}

fn buildEvent(
    st: *c.struct_xkb_state,
    km: *c.struct_xkb_keymap,
    code: u32,
) ui.KeyEvent {
    var ev: ui.KeyEvent = .{};
    ev.mods = readMods(st);
    ev.key = keyFromSym(c.xkb_state_key_get_one_sym(st, code));

    // What the key typed. `xkb_state_key_get_utf8` writes a NUL terminator, so
    // the returned length is what to take and the buffer has to have room for
    // one more byte than that.
    var buf: [ui.keys.text_capacity + 1]u8 = undefined;
    const n = c.xkb_state_key_get_utf8(st, code, &buf, buf.len);
    if (n > 0 and n <= ui.keys.text_capacity) {
        const s = buf[0..@intCast(n)];
        // Control characters are not text. xkb translates Ctrl+A to `\x01`,
        // Enter to `\r` and Tab to `\t`, all of which would be written into a
        // document by a field that inserted whatever arrived. The named key is
        // already set above, so nothing is lost by dropping these.
        if (ui.editing.isInsertable(s)) _ = ev.setText(s);
    }

    // And which key it was, independent of the modifiers: level 0 of the
    // current layout. This is what an accelerator matches against, and it
    // cannot be recovered from the text -- with Ctrl held the text is a
    // control character, and with Shift held it is the wrong case.
    const layout = c.xkb_state_key_get_layout(st, code);
    var syms: [*c]const c.xkb_keysym_t = undefined;
    const count = c.xkb_keymap_key_get_syms_by_level(km, code, layout, 0, &syms);
    if (count > 0) {
        const cp = c.xkb_keysym_to_utf32(syms[0]);
        if (cp != 0 and cp <= 0x10FFFF) ev.base = @intCast(cp);
    }

    return ev;
}

/// The modifiers as xkb has already resolved them.
///
/// Asked by name rather than decoded from the masks the `modifiers` event
/// carries: the mask bit for Alt is `Mod1` on one keymap and something else on
/// another, and the whole point of letting xkb compile the keymap is not
/// having to know which.
fn readMods(st: *c.struct_xkb_state) ui.Mods {
    const eff = c.XKB_STATE_MODS_EFFECTIVE;
    const on = struct {
        fn f(s: *c.struct_xkb_state, name: [*:0]const u8, which: c_uint) bool {
            return c.xkb_state_mod_name_is_active(s, name, which) > 0;
        }
    }.f;
    return .{
        .shift = on(st, "Shift", eff),
        .ctrl = on(st, "Control", eff),
        .alt = on(st, "Mod1", eff),
        .logo = on(st, "Mod4", eff),
        .caps_lock = on(st, "Lock", eff),
        .num_lock = on(st, "Mod2", eff),
    };
}

fn keyFromSym(sym: c.xkb_keysym_t) ui.Key {
    return switch (sym) {
        c.XKB_KEY_Escape => .escape,
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => .enter,
        c.XKB_KEY_Tab, c.XKB_KEY_ISO_Left_Tab => .tab,
        c.XKB_KEY_BackSpace => .backspace,
        c.XKB_KEY_Delete, c.XKB_KEY_KP_Delete => .delete,
        c.XKB_KEY_Insert, c.XKB_KEY_KP_Insert => .insert,
        c.XKB_KEY_Left, c.XKB_KEY_KP_Left => .left,
        c.XKB_KEY_Right, c.XKB_KEY_KP_Right => .right,
        c.XKB_KEY_Up, c.XKB_KEY_KP_Up => .up,
        c.XKB_KEY_Down, c.XKB_KEY_KP_Down => .down,
        c.XKB_KEY_Home, c.XKB_KEY_KP_Home => .home,
        c.XKB_KEY_End, c.XKB_KEY_KP_End => .end,
        c.XKB_KEY_Page_Up, c.XKB_KEY_KP_Page_Up => .page_up,
        c.XKB_KEY_Page_Down, c.XKB_KEY_KP_Page_Down => .page_down,
        // Everything else arrives as text, if it produces any. A full keysym
        // table here would be a table to keep in step with three platforms for
        // the benefit of nothing that currently asks.
        else => .none,
    };
}

fn kbModifiers(
    data: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    _: u32,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    if (self.xkb_state) |st| {
        _ = c.xkb_state_update_mask(st, depressed, latched, locked, 0, 0, group);
    }
}

fn kbRepeatInfo(data: ?*anyopaque, _: ?*c.struct_wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    self.repeat_rate = rate;
    self.repeat_delay = delay;
    // A rate of zero means the user turned repeat off. Honour it immediately
    // rather than at the next press, in case a key is down right now.
    if (rate <= 0) self.stopRepeat();
}

const keyboard_listener: c.struct_wl_keyboard_listener = .{
    .keymap = kbKeymap,
    .enter = kbEnter,
    .leave = kbLeave,
    .key = kbKey,
    .modifiers = kbModifiers,
    .repeat_info = kbRepeatInfo,
};

// -------------------------------------------------------------- input method
//
// Six events, and only one of them does anything: `done`. The other five
// accumulate pending state. That is the protocol's own shape, and the reason
// it has that shape is composition -- an input method rewrites its preedit
// several times per keystroke, and a client that redrew on each event would
// flicker through states the user never asked to see.

fn tiEnter(
    data: ?*anyopaque,
    _: ?*c.struct_zwp_text_input_v3,
    surface: ?*c.struct_wl_surface,
) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    if (surface != self.surface) return;
    self.ti_entered = true;
    self.ime_enters += 1;
    self.enableTextInput();
}

fn tiLeave(
    data: ?*anyopaque,
    _: ?*c.struct_zwp_text_input_v3,
    _: ?*c.struct_wl_surface,
) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    self.ti_entered = false;
    self.ime_enabled = false;
    self.pending.reset();
    // A composition in progress is over, and its preedit was never in the
    // document. Leaving it on screen would draw text that nothing can commit
    // and that the next keystroke would have to interleave with.
    if (self.ime_doc) |doc| {
        if (doc.composition_active) {
            doc.endComposition();
            self.ime_dirty = true;
        }
    }
}

fn tiPreedit(
    data: ?*anyopaque,
    _: ?*c.struct_zwp_text_input_v3,
    text: [*c]const u8,
    cursor_begin: i32,
    cursor_end: i32,
) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    // A null string is the protocol's way of saying "no preedit", which is not
    // the same as not sending the event at all.
    const t: []const u8 = if (text) |p| std.mem.span(p) else "";
    self.ime_events.preedit += 1;
    self.pending.setPreedit(self.gpa, t, cursor_begin, cursor_end);
}

fn tiCommit(data: ?*anyopaque, _: ?*c.struct_zwp_text_input_v3, text: [*c]const u8) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    const t: []const u8 = if (text) |p| std.mem.span(p) else "";
    self.ime_events.commit += 1;
    self.pending.setCommit(self.gpa, t);
}

fn tiDelete(
    data: ?*anyopaque,
    _: ?*c.struct_zwp_text_input_v3,
    before: u32,
    after: u32,
) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    self.ime_events.delete += 1;
    self.pending.delete_before = before;
    self.pending.delete_after = after;
}

fn tiDone(data: ?*anyopaque, _: ?*c.struct_zwp_text_input_v3, serial: u32) callconv(.c) void {
    const self: *Window = @ptrCast(@alignCast(data.?));
    defer self.pending.reset();
    self.ime_events.done += 1;

    // A `done` whose serial is not our commit count describes a state we have
    // already moved past: a commit of ours is still in flight.
    const stale = serial != self.ime_serial;
    if (stale) self.stale_dones += 1;
    if (self.pending.failed) {
        self.ime_error = error.OutOfMemory;
        self.pending.failed = false;
        return;
    }

    const doc = self.ime_doc orelse return;
    const r = ui.input_method.apply(doc, self.pending.change()) catch |e| {
        self.ime_error = e;
        return;
    };
    if (r.document_changed or r.preedit_changed) self.ime_dirty = true;

    // The resync rule, which is in `shouldResync` so that a test can drive it
    // without a compositor.
    if (shouldResync(r, stale)) {
        self.ime_resyncs += 1;
        self.sendState(.input_method);
    }
}

const text_input_listener: c.struct_zwp_text_input_v3_listener = .{
    .enter = tiEnter,
    .leave = tiLeave,
    .preedit_string = tiPreedit,
    .commit_string = tiCommit,
    .delete_surrounding_text = tiDelete,
    .done = tiDone,
};

// ---------------------------------------------------------------------- tests
//
// These need no compositor, no seat and no window. `xkbcommon` will compile a
// keymap from layout names alone, which is enough to drive the one piece of
// this file that is real logic rather than plumbing: turning an evdev scancode
// plus a modifier state into a `KeyEvent`.
//
// That is worth testing here and not only through the window, because the
// window's `--type` mode pushes events straight into the queue and therefore
// proves nothing about this translation. What is checked below is exactly the
// part a synthetic keystroke skips.
//
// They are behind `zig build test-input` rather than `zig build test`, because
// they need xkbcommon and an installed keyboard layout, and the core test
// suite is the one that has to run on a machine with neither.

const testing = std.testing;

const Keymap = struct {
    ctx: *c.struct_xkb_context,
    map: *c.struct_xkb_keymap,
    state: *c.struct_xkb_state,

    fn open() !Keymap {
        const ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return error.SkipZigTest;
        const names: c.struct_xkb_rule_names = .{ .layout = "us" };
        const map = c.xkb_keymap_new_from_names(ctx, &names, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse {
            c.xkb_context_unref(ctx);
            return error.SkipZigTest;
        };
        const state = c.xkb_state_new(map) orelse {
            c.xkb_keymap_unref(map);
            c.xkb_context_unref(ctx);
            return error.SkipZigTest;
        };
        return .{ .ctx = ctx, .map = map, .state = state };
    }

    fn close(self: *Keymap) void {
        c.xkb_state_unref(self.state);
        c.xkb_keymap_unref(self.map);
        c.xkb_context_unref(self.ctx);
    }

    /// `scan` is an evdev code, as the protocol delivers it.
    fn press(self: *Keymap, scan: u32) ui.KeyEvent {
        return buildEvent(self.state, self.map, scan + 8);
    }

    fn hold(self: *Keymap, scan: u32) void {
        _ = c.xkb_state_update_key(self.state, scan + 8, c.XKB_KEY_DOWN);
    }

    fn release(self: *Keymap, scan: u32) void {
        _ = c.xkb_state_update_key(self.state, scan + 8, c.XKB_KEY_UP);
    }
};

// evdev scancodes, from `linux/input-event-codes.h`. Written out rather than
// read from a header because they are part of the protocol's contract and not
// of any library's.
const KEY_ESC = 1;
const KEY_A = 30;
const KEY_S = 31;
const KEY_BACKSPACE = 14;
const KEY_ENTER = 28;
const KEY_TAB = 15;
const KEY_LEFTCTRL = 29;
const KEY_LEFTSHIFT = 42;
const KEY_LEFTALT = 56;
const KEY_LEFT = 105;
const KEY_HOME = 102;
const KEY_DELETE = 111;

test "a letter key produces text and a base character" {
    var km = try Keymap.open();
    defer km.close();

    const ev = km.press(KEY_A);
    try testing.expectEqual(ui.Key.none, ev.key);
    try testing.expectEqualStrings("a", ev.text());
    try testing.expectEqual(@as(u21, 'a'), ev.base);
    try testing.expect(!ev.mods.shift);
}

test "shift changes the text but not the base character" {
    var km = try Keymap.open();
    defer km.close();

    km.hold(KEY_LEFTSHIFT);
    const ev = km.press(KEY_A);
    try testing.expectEqualStrings("A", ev.text());
    // The accelerator table has to still see this as the A key.
    try testing.expectEqual(@as(u21, 'a'), ev.base);
    try testing.expect(ev.mods.shift);

    km.release(KEY_LEFTSHIFT);
    try testing.expect(!km.press(KEY_A).mods.shift);
}

test "ctrl produces no text and still identifies the key" {
    var km = try Keymap.open();
    defer km.close();

    km.hold(KEY_LEFTCTRL);
    const ev = km.press(KEY_S);
    // This is the whole reason `base` exists: xkb's text for Ctrl+S is the
    // control character 0x13, which is dropped, and without `base` there
    // would be nothing left to match an accelerator against.
    try testing.expectEqualStrings("", ev.text());
    try testing.expectEqual(@as(u21, 's'), ev.base);
    try testing.expect(ev.mods.ctrl);
    try testing.expect(ev.mods.anyAccel());
}

test "named keys arrive named and carry no text" {
    var km = try Keymap.open();
    defer km.close();

    // Each of these has a control character as its xkb text -- `\x08`, `\r`,
    // `\t`, `\x1b` -- and every one of them would end up in the document if
    // the control-character filter were not there.
    const cases = [_]struct { scan: u32, key: ui.Key }{
        .{ .scan = KEY_BACKSPACE, .key = .backspace },
        .{ .scan = KEY_ENTER, .key = .enter },
        .{ .scan = KEY_TAB, .key = .tab },
        .{ .scan = KEY_ESC, .key = .escape },
        .{ .scan = KEY_LEFT, .key = .left },
        .{ .scan = KEY_HOME, .key = .home },
        .{ .scan = KEY_DELETE, .key = .delete },
    };
    for (cases) |case| {
        const ev = km.press(case.scan);
        try testing.expectEqual(case.key, ev.key);
        try testing.expectEqualStrings("", ev.text());
    }
}

test "the evdev-to-xkb offset is the one being applied" {
    var km = try Keymap.open();
    defer km.close();

    // If the offset were missing this would still produce *some* character,
    // which is why the test names the expected one rather than checking that
    // the text is non-empty.
    try testing.expectEqualStrings("a", km.press(KEY_A).text());
    try testing.expectEqualStrings("s", km.press(KEY_S).text());

    // And here is what missing it actually does, pinned rather than asserted
    // in prose: xkb keycode 30 is evdev 22, which is the U key. A keyboard
    // without the offset is not broken, it is shifted -- every key types a
    // different letter, consistently, which is the kind of wrong that gets
    // blamed on the layout.
    const no_offset = buildEvent(km.state, km.map, KEY_A);
    try testing.expectEqualStrings("u", no_offset.text());
}

test "alt is reported and is an accelerator modifier" {
    var km = try Keymap.open();
    defer km.close();

    km.hold(KEY_LEFTALT);
    const ev = km.press(KEY_A);
    try testing.expect(ev.mods.alt);
    try testing.expect(ev.mods.anyAccel());
    km.release(KEY_LEFTALT);
}

test "a keystroke goes through editing into a document" {
    // The two halves joined: a scancode in, a document with text in it out.
    // Neither module can be asked this question alone, and it is the question
    // the whole slice exists to answer.
    var km = try Keymap.open();
    defer km.close();

    var doc = ui.Document.init(testing.allocator);
    defer doc.deinit();

    km.hold(KEY_LEFTSHIFT);
    _ = try ui.editing.apply(&doc, km.press(KEY_A), .{});
    km.release(KEY_LEFTSHIFT);
    _ = try ui.editing.apply(&doc, km.press(KEY_S), .{});
    try testing.expectEqualStrings("As", doc.text());

    _ = try ui.editing.apply(&doc, km.press(KEY_BACKSPACE), .{});
    try testing.expectEqualStrings("A", doc.text());

    // And Ctrl+S, which a text field must not type.
    km.hold(KEY_LEFTCTRL);
    const saved = try ui.editing.apply(&doc, km.press(KEY_S), .{});
    km.release(KEY_LEFTCTRL);
    try testing.expect(!saved.handled);
    try testing.expectEqualStrings("A", doc.text());
}

// --------------------------------------------------- the input-method events
//
// `Pending` plus `shouldResync` is the whole protocol state machine with the
// libwayland calls taken out, so these drive it the way a compositor would and
// assert on the document that comes out. This is spike B's self test, which
// exists because ibus-bamboo in its default input mode keeps a whole syllable
// in the preedit and never sends `delete_surrounding_text` at all -- so no
// amount of typing reaches the half of this that corrupts text when it is
// wrong.

/// One `done`: the pending state as the five events left it, applied.
fn deliver(p: *Pending, doc: *ui.Document, stale: bool) !struct {
    result: ui.input_method.Result,
    resync: bool,
} {
    defer p.reset();
    const r = try ui.input_method.apply(doc, p.change());
    return .{ .result = r, .resync = shouldResync(r, stale) };
}

test "a preedit is accumulated and applied only on done" {
    var p: Pending = .{};
    defer p.deinit(testing.allocator);
    var doc = ui.Document.init(testing.allocator);
    defer doc.deinit();

    // Three preedit events before a done, which is what an input method sends
    // while a syllable is being built. Only the last survives.
    p.setPreedit(testing.allocator, "a", 1, 1);
    p.setPreedit(testing.allocator, "ă", 2, 2);
    p.setPreedit(testing.allocator, "ắ", 3, 3);
    try testing.expectEqualStrings("", doc.text());

    const d = try deliver(&p, &doc, false);
    try testing.expectEqualStrings("", doc.text());
    try testing.expectEqualStrings("ắ", doc.preedit.items);
    try testing.expect(d.result.preedit_changed);
    try testing.expect(!d.resync);
}

test "a preedit change asks for no resync and a commit asks for exactly one" {
    var p: Pending = .{};
    defer p.deinit(testing.allocator);
    var doc = ui.Document.init(testing.allocator);
    defer doc.deinit();

    p.setPreedit(testing.allocator, "tieengs", 7, 7);
    try testing.expect(!(try deliver(&p, &doc, false)).resync);

    p.setCommit(testing.allocator, "tiếng");
    p.setPreedit(testing.allocator, "", -1, -1);
    const d = try deliver(&p, &doc, false);
    try testing.expect(d.resync);
    try testing.expectEqualStrings("tiếng", doc.text());

    // And the `done` that the resync's own commit provokes carries nothing,
    // so it does not resync again. That is what makes the rule terminate
    // rather than merely slow the loop down.
    try testing.expect(!(try deliver(&p, &doc, false)).resync);
}

test "a stale done is applied but not answered" {
    var p: Pending = .{};
    defer p.deinit(testing.allocator);
    var doc = ui.Document.init(testing.allocator);
    defer doc.deinit();

    p.setCommit(testing.allocator, "ắ");
    const d = try deliver(&p, &doc, true);
    try testing.expectEqualStrings("ắ", doc.text());
    try testing.expect(d.result.document_changed);
    // Applied, because the text is real; unanswered, because a commit of ours
    // is already in flight and will produce its own `done`.
    try testing.expect(!d.resync);
}

test "delete_surrounding_text and commit_string in one done are the Telex case" {
    var p: Pending = .{};
    defer p.deinit(testing.allocator);
    var doc = ui.Document.init(testing.allocator);
    defer doc.deinit();
    _ = try doc.insert(.application, "a");

    // bamboo input mode 2: delete what is already committed, then commit the
    // replacement, in one `done`. One byte out, two bytes in.
    p.delete_before = 1;
    p.setCommit(testing.allocator, "ă");
    _ = try deliver(&p, &doc, false);
    try testing.expectEqualStrings("ă", doc.text());
}

test "a null string is an event that arrived carrying nothing" {
    var p: Pending = .{};
    defer p.deinit(testing.allocator);
    var doc = ui.Document.init(testing.allocator);
    defer doc.deinit();
    _ = try doc.insert(.application, "x");

    // `tiPreedit` turns a null pointer into an empty slice, which still means
    // "there is a preedit event and it is empty" -- different from no event,
    // and the difference is whether a live preedit gets cleared.
    p.setPreedit(testing.allocator, "abc", 3, 3);
    _ = try deliver(&p, &doc, false);
    try testing.expectEqualStrings("abc", doc.preedit.items);

    p.setPreedit(testing.allocator, "", -1, -1);
    _ = try deliver(&p, &doc, false);
    try testing.expectEqualStrings("", doc.preedit.items);
    try testing.expect(!doc.composition_active);
    try testing.expectEqualStrings("x", doc.text());
}

test "the preedit caret survives the round trip from the protocol's -1" {
    var p: Pending = .{};
    defer p.deinit(testing.allocator);
    var doc = ui.Document.init(testing.allocator);
    defer doc.deinit();

    p.setPreedit(testing.allocator, "ếng", -1, -1);
    _ = try deliver(&p, &doc, false);
    try testing.expectEqual(@as(?usize, null), doc.displayCaret());

    p.setPreedit(testing.allocator, "ếng", 3, 3);
    _ = try deliver(&p, &doc, false);
    try testing.expectEqual(@as(?usize, 3), doc.displayCaret());
}

test "surrounding text follows the document and never carries the preedit" {
    var p: Pending = .{};
    defer p.deinit(testing.allocator);
    var doc = ui.Document.init(testing.allocator);
    defer doc.deinit();
    _ = try doc.insert(.application, "tiếng ");

    p.setPreedit(testing.allocator, "Vieejt", 6, 6);
    _ = try deliver(&p, &doc, false);
    const before = ui.input_method.surrounding(&doc, ui.input_method.max_surrounding);
    try testing.expectEqualStrings("tiếng ", before.text);

    p.setCommit(testing.allocator, "Việt");
    p.setPreedit(testing.allocator, "", -1, -1);
    _ = try deliver(&p, &doc, false);
    const after = ui.input_method.surrounding(&doc, ui.input_method.max_surrounding);
    try testing.expectEqualStrings("tiếng Việt", after.text);
    try testing.expectEqual(@as(u32, "tiếng Việt".len), after.cursor);
}
