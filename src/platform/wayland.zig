//! A Wayland window: `xdg_shell` surface, configure handling, and the pointer.
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

pub const Error = error{
    NoWaylandDisplay,
    MissingGlobal,
    SurfaceFailed,
} || Allocator.Error;

pub const Window = struct {
    gpa: Allocator,

    display: *c.struct_wl_display,
    registry: ?*c.struct_wl_registry = null,
    compositor: ?*c.struct_wl_compositor = null,
    wm_base: ?*c.struct_xdg_wm_base = null,
    seat: ?*c.struct_wl_seat = null,
    pointer: ?*c.struct_wl_pointer = null,

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
        return self;
    }

    pub fn close(self: *Window) void {
        if (self.toplevel) |t| c.xdg_toplevel_destroy(t);
        if (self.xdg_surface) |x| c.xdg_surface_destroy(x);
        if (self.surface) |s| c.wl_surface_destroy(s);
        if (self.pointer) |p| c.wl_pointer_destroy(p);
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
        const n = std.posix.poll(&fds, 0) catch return;
        if (n > 0) {
            if (c.wl_display_dispatch(self.display) < 0) self.closed = true;
        }
    }
};

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
}
fn seatName(_: ?*anyopaque, _: ?*c.struct_wl_seat, _: [*c]const u8) callconv(.c) void {}
const seat_listener: c.struct_wl_seat_listener = .{ .capabilities = seatCaps, .name = seatName };

/// Wayland sends coordinates as 24.8 fixed point.
fn fixedToFloat(v: c.wl_fixed_t) f32 {
    return @as(f32, @floatFromInt(v)) / 256.0;
}
