//! A Wayland window: `xdg_shell` surface, configure handling, the pointer and
//! the keyboard.
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

    /// The active keyboard layout's name, or an empty string before the keymap
    /// has arrived.
    pub fn layoutName(self: *const Window) []const u8 {
        return self.layout_buf[0..self.layout_len];
    }
};

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

fn ptrAxis(_: ?*anyopaque, _: ?*c.struct_wl_pointer, _: u32, _: u32, _: c.wl_fixed_t) callconv(.c) void {}
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
