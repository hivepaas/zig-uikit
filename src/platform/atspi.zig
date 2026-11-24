//! AT-SPI over DBus: the accessibility tree a screen reader reads.
//!
//! `docs/text-and-accessibility.md` §4 and §5, and the half of tier A that
//! nobody in the Zig ecosystem has: dvui has no accessibility and
//! `ddalcu/zigui` has no accessibility files at all. The design note is blunt
//! about why it matters -- a widget that looks native but is invisible to a
//! screen reader is strictly worse than the native widget it imitates.
//!
//! **There is no shortcut.** Three routes exist and two are closed: ATK plus
//! the at-spi2-atk bridge requires being a GTK application, and `libatspi` is
//! the *client* library, for screen readers and inspection tools, not for
//! applications exposing a tree. An application that draws its own widgets
//! implements the AT-SPI DBus interfaces directly. That is what AccessKit's
//! Linux backend does, and it is what this does.
//!
//! Everything about *meaning* -- roles, states, and above all the fact that
//! AT-SPI counts characters where the document counts bytes -- is in
//! `src/a11y.zig`, in core, with tests that need no bus. What is here is the
//! wire: DBus message construction, the object tree, registration, and the
//! signals. The split is not decoration; the offset conversion is the thing
//! that silently makes a screen reader read the wrong characters, and it
//! belongs where it can be tested.
//!
//! Ported from spike C, which verified every one of these answers against the
//! running registry and against Orca. Two of them were found by running Orca
//! rather than by reading the specification, and both are noted where they
//! are implemented: `Cache.GetItems` and `GetApplicationBusAddress`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("dbus");
const ui = @import("zig-uikit");

const a11y = ui.a11y;

pub const Error = error{
    NoSessionBus,
    NoA11yBus,
    OpenFailed,
    RegisterFailed,
    RegisterPathFailed,
    EmbedFailed,
    BadReply,
    AddressTooLong,
} || Allocator.Error;

const IF_ACCESSIBLE = "org.a11y.atspi.Accessible";
const IF_APPLICATION = "org.a11y.atspi.Application";
const IF_COMPONENT = "org.a11y.atspi.Component";
const IF_TEXT = "org.a11y.atspi.Text";
const IF_PROPS = "org.freedesktop.DBus.Properties";
const IF_INTRO = "org.freedesktop.DBus.Introspectable";
const IF_CACHE = "org.a11y.atspi.Cache";

const EV_OBJECT = "org.a11y.atspi.Event.Object";
const EV_WINDOW = "org.a11y.atspi.Event.Window";

const PATH_PREFIX = "/org/a11y/atspi/accessible/";
const PATH_ROOT = PATH_PREFIX ++ "root";
/// AT-SPI's explicit null reference. A parent or child slot with no object is
/// this, not an empty path.
const PATH_NULL = "/org/a11y/atspi/null";
/// A **sibling** of the accessible subtree, not a child of it. That is why the
/// fallback handler is registered one level higher; otherwise the call never
/// reaches it and libdbus answers the error itself.
const PATH_CACHE = "/org/a11y/atspi/cache";

/// `DBusError` carries five one-bit bitfields and Zig has no C bitfield
/// support, so translate-c renders the whole struct as opaque. The layout is
/// stable and documented, so it is redeclared and checked against the C
/// compiler's idea of it.
///
/// This is the only thing in this project that translate-c could not handle at
/// all. It is not hard; it is a hand-maintained layout that no compiler will
/// check against the real header, which is a different kind of risk from the
/// rest of the C surface here.
const DBusError = extern struct {
    name: ?[*:0]const u8 = null,
    message: ?[*:0]const u8 = null,
    bits: c_uint = 0,
    _pad: c_uint = 0,
    padding1: ?*anyopaque = null,

    fn ptr(self: *DBusError) *c.DBusError {
        return @ptrCast(self);
    }

    fn msg(self: *const DBusError) []const u8 {
        return if (self.message) |m| std.mem.span(m) else "unknown";
    }
};

comptime {
    std.debug.assert(@sizeOf(DBusError) == 32);
    std.debug.assert(@offsetOf(DBusError, "message") == 8);
}

/// What the bridge adds on top of an `access.Node`.
///
/// The tree itself is `src/access.zig`, in core, shared with the macOS
/// adapter: one internal tree, two protocols reading it. **Nothing is copied
/// out of it here.** Names, bounds, text and structure are all read live on
/// every query, so a relayout or a keystroke cannot leave a screen reader
/// describing what used to be there.
///
/// The only per-node state the bridge owns is a mirror, and only for a node
/// backed by a document: `text-changed:delete` has to carry the text that was
/// removed, and after the edit it is gone.
const Extra = struct {
    mirror: a11y.Mirror = .{},
};

/// Either the synthetic application node or a node of the internal tree.
///
/// AT-SPI wants an `application` whose child is a `frame`, and the internal
/// tree starts at the window. So the application is a node here and nowhere
/// else; inventing it in the shared tree would put one protocol's shape into
/// the layer that exists to be protocol-neutral.
const Target = union(enum) {
    app,
    node: ui.access.NodeId,
};

pub const Options = struct {
    /// What the desktop lists the application as.
    app_name: []const u8 = "zig-uikit application",
    toolkit_name: []const u8 = "zig-uikit",
    toolkit_version: []const u8 = "0.0.0",
    locale: []const u8 = "en_US.UTF-8",
    /// Emit signals even when the registry says nothing is listening.
    ///
    /// Off by default, and the default is the behaviour that matters: with no
    /// assistive technology running, `GetRegisteredEvents` comes back empty
    /// and every signal goes to nobody, so emitting unconditionally would put
    /// traffic on the accessibility bus for almost every user. This exists so
    /// the signals can be captured with `dbus-monitor` on a machine with no
    /// screen reader installed, which is how their wire format was checked.
    always_emit: bool = false,
};

/// Heap-allocated and returned by pointer, like the window and for the same
/// reason: libdbus keeps the `void *` it is handed for the life of the
/// connection.
pub const Bridge = struct {
    gpa: Allocator,
    conn: ?*c.DBusConnection = null,
    unique_name: [*c]const u8 = "",

    /// The internal tree, borrowed. Read on every query.
    access: *const ui.access.Tree,
    /// Where the nodes' bounds come from, borrowed.
    layout: *const ui.Tree,
    /// Indexed by `access.NodeId`, grown to match the tree.
    extra: std.ArrayList(Extra) = .empty,

    opts: Options,
    app_name_z: [:0]u8 = undefined,
    toolkit_name_z: [:0]u8 = undefined,
    toolkit_version_z: [:0]u8 = undefined,
    locale_z: [:0]u8 = undefined,

    /// Assigned by the registry through `Properties.Set` right after `Embed`.
    /// Spike C found this by logging unhandled methods rather than by reading
    /// the specification: it was accepting the registration and then refusing
    /// the id that follows it, leaving the application registered but
    /// anonymous.
    app_id: i32 = 0,

    /// How many events the registry says anything is listening for.
    listener_count: u32 = 0,

    /// Where the window is on screen, if anything knows.
    ///
    /// On Wayland nothing does: a client is not told its own position, and
    /// `Component.GetExtents` is specified in screen coordinates. So this
    /// stays zero there and the extents are surface coordinates labelled as
    /// screen ones -- which is wrong, and is reported as a known limitation
    /// rather than hidden. The error is the window's position: a constant per
    /// window, not per element.
    origin_x: f32 = 0,
    origin_y: f32 = 0,

    calls_served: u32 = 0,
    events_emitted: u32 = 0,
    /// Scratch for NUL-terminating a string before it goes on the wire.
    /// Refilled between appends; libdbus copies as it appends.
    scratch: std.ArrayList(u8) = .empty,

    pub fn init(
        gpa: Allocator,
        access_tree: *const ui.access.Tree,
        layout: *const ui.Tree,
        opts: Options,
    ) Error!*Bridge {
        var addr_buf: [512]u8 = undefined;
        const addr = try a11yBusAddress(&addr_buf);

        const self = try gpa.create(Bridge);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .access = access_tree, .layout = layout, .opts = opts };
        self.app_name_z = try gpa.dupeSentinel(u8, opts.app_name, 0);
        self.toolkit_name_z = try gpa.dupeSentinel(u8, opts.toolkit_name, 0);
        self.toolkit_version_z = try gpa.dupeSentinel(u8, opts.toolkit_version, 0);
        self.locale_z = try gpa.dupeSentinel(u8, opts.locale, 0);

        var err: DBusError = .{};
        c.dbus_error_init(err.ptr());
        self.conn = c.dbus_connection_open_private(addr.ptr, err.ptr()) orelse
            return Error.OpenFailed;
        if (c.dbus_bus_register(self.conn, err.ptr()) == 0) return Error.RegisterFailed;
        self.unique_name = c.dbus_bus_get_unique_name(self.conn);

        // One fallback handler for the whole subtree rather than a
        // registration per object: an accessibility tree is dynamic, and
        // re-registering paths as elements come and go would be pure overhead.
        //
        // Registered on `/org/a11y/atspi` and not on the accessible subtree,
        // so that the same handler also receives the cache path.
        var vtable = std.mem.zeroes(c.DBusObjectPathVTable);
        vtable.message_function = onMessage;
        if (c.dbus_connection_register_fallback(self.conn, "/org/a11y/atspi", &vtable, self) == 0) {
            return Error.RegisterPathFailed;
        }

        try self.embed();
        self.refreshListeners();

        // Seed the mirrors from whatever text the tree already holds.
        //
        // Without this the first edit compares against an empty mirror and
        // announces the whole field as freshly inserted -- which a screen
        // reader would read out in full on the first keystroke. It showed up
        // in a `dbus-monitor` capture as `insert 0 18` carrying the initial
        // text, before anything had been typed.
        self.syncAllText();
        return self;
    }

    pub fn deinit(self: *Bridge) void {
        const gpa = self.gpa;
        for (self.extra.items) |*e| e.mirror.deinit(gpa);
        self.extra.deinit(gpa);
        self.scratch.deinit(gpa);
        gpa.free(self.app_name_z);
        gpa.free(self.toolkit_name_z);
        gpa.free(self.toolkit_version_z);
        gpa.free(self.locale_z);
        if (self.conn) |conn| {
            c.dbus_connection_close(conn);
            c.dbus_connection_unref(conn);
        }
        gpa.destroy(self);
    }

    /// Our name on the accessibility bus, for pointing an inspection tool at.
    pub fn busName(self: *const Bridge) []const u8 {
        return std.mem.span(self.unique_name);
    }

    /// Processes whatever the bus has sent, without blocking.
    ///
    /// Called once a frame beside `Window.pump`. A screen reader's queries
    /// arrive in bursts -- Orca's first move pulls the whole tree -- and a
    /// blocking dispatch here would stall the frame loop on another process.
    pub fn pump(self: *Bridge) void {
        const conn = self.conn orelse return;
        _ = c.dbus_connection_read_write(conn, 0);
        while (c.dbus_connection_dispatch(conn) == c.DBUS_DISPATCH_DATA_REMAINS) {}
    }

    pub fn listeners(self: *const Bridge) u32 {
        return self.listener_count;
    }

    /// Asks the registry how many events anything is listening for.
    ///
    /// Worth re-asking: a screen reader can start after the application did,
    /// and one that asked only at start-up would stay silent for the session.
    pub fn refreshListeners(self: *Bridge) void {
        const n = self.registeredEventCount();
        self.listener_count = if (n < 0) 0 else @intCast(n);
    }

    /// Records a node's current text as what was last reported, emitting
    /// nothing. For a document attached after the bridge started.
    pub fn syncText(self: *Bridge, id: ui.access.NodeId) void {
        const node = self.access.get(id) orelse return;
        const doc = node.doc orelse return;
        const ex = self.extraFor(id) orelse return;
        ex.mirror.sync(self.gpa, doc.text()) catch {};
    }

    fn syncAllText(self: *Bridge) void {
        var id: ui.access.NodeId = 0;
        while (id < self.access.nodes.items.len) : (id += 1) self.syncText(id);
    }

    fn emitting(self: *const Bridge) bool {
        return self.opts.always_emit or a11y.shouldEmit(self.listener_count);
    }

    fn extraFor(self: *Bridge, id: ui.access.NodeId) ?*Extra {
        while (self.extra.items.len <= id) {
            self.extra.append(self.gpa, .{}) catch return null;
        }
        return &self.extra.items[id];
    }

    // ------------------------------------------------------------- events

    /// The signals one document edit has to produce.
    ///
    /// `edit` is the exact extent when the application made the change --
    /// computed where both the old text and the new one existed. It is null
    /// for an edit an input method made, because that happens inside the
    /// platform layer and the application never sees one; then the mirror is
    /// compared instead.
    pub fn textChanged(self: *Bridge, id: ui.access.NodeId, edit: ?ui.document.Edit) void {
        const node = self.access.get(id) orelse return;
        const doc = node.doc orelse return;
        const ex = self.extraFor(id) orelse return;
        defer ex.mirror.sync(self.gpa, doc.text()) catch {};
        if (!self.emitting()) return;

        var buf: [64]u8 = undefined;
        const path = self.pathOf(.{ .node = id }, &buf);
        var out: [2]a11y.TextChange = undefined;
        const changes = if (edit) |e|
            a11y.changesFor(e, ex.mirror.text(), doc.text(), &out)
        else
            a11y.changesBetween(ex.mirror.text(), doc.text(), &out);
        for (changes) |ch| {
            const z = self.zeroTerm(ch.text);
            self.emit(path, EV_OBJECT, "TextChanged", switch (ch.kind) {
                .insert => "insert",
                .delete => "delete",
            }, @intCast(ch.offset), @intCast(ch.length), .{ .str = z });
        }
        self.caretMoved(id);
    }

    pub fn caretMoved(self: *Bridge, id: ui.access.NodeId) void {
        if (!self.emitting()) return;
        const node = self.access.get(id) orelse return;
        const doc = node.doc orelse return;
        var buf: [64]u8 = undefined;
        self.emit(
            self.pathOf(.{ .node = id }, &buf),
            EV_OBJECT,
            "TextCaretMoved",
            "",
            @intCast(a11y.caretOffset(doc)),
            0,
            .none,
        );
    }

    /// Focus is the internal tree's, so there is nothing to set here: this
    /// only tells the bus what the tree already says.
    pub fn focusChanged(self: *Bridge, id: ui.access.NodeId) void {
        if (!self.emitting()) return;
        if (self.access.get(id) == null) return;
        var buf: [64]u8 = undefined;
        // `focus:` is deliberately not also sent. Spike C emitted it on the
        // stated belief that Orca still listens for it; with Orca running,
        // `GetRegisteredEvents` returned 39 listeners and `Focus:` was not
        // among them. It was traffic to nobody.
        self.emit(
            self.pathOf(.{ .node = id }, &buf),
            EV_OBJECT,
            "StateChanged",
            "focused",
            if (self.access.focus == id) 1 else 0,
            0,
            .none,
        );
    }

    pub fn windowActivated(self: *Bridge, active: bool) void {
        if (!self.emitting()) return;
        var buf: [64]u8 = undefined;
        const root: ui.access.NodeId = ui.access.Tree.root;
        self.emit(
            self.pathOf(.{ .node = root }, &buf),
            EV_WINDOW,
            if (active) "Activate" else "Deactivate",
            "",
            0,
            0,
            .{ .str = self.zeroTerm(self.access.get(root).?.name) },
        );
    }

    fn zeroTerm(self: *Bridge, s: []const u8) [:0]const u8 {
        self.scratch.clearRetainingCapacity();
        self.scratch.appendSlice(self.gpa, s) catch return "";
        self.scratch.append(self.gpa, 0) catch return "";
        return self.scratch.items[0 .. self.scratch.items.len - 1 :0];
    }

    const AnyData = union(enum) {
        none,
        int: i32,
        str: [:0]const u8,
    };

    /// The signal is emitted on the **source** object's path -- that is how a
    /// listener knows which element changed. The trailing `(so)` is the
    /// application, not the source.
    ///
    /// Signature `siiv(so)`, confirmed from `libatspi.so.0` rather than from
    /// memory, and consumed by Orca without complaint. The registry's own
    /// events use `siiva{sv}`; both strings exist in the library and the
    /// application form is this one.
    fn emit(
        self: *Bridge,
        path: [:0]const u8,
        iface: [*c]const u8,
        member: [*c]const u8,
        detail: [*c]const u8,
        d1: i32,
        d2: i32,
        any: AnyData,
    ) void {
        const msg = c.dbus_message_new_signal(path.ptr, iface, member) orelse return;
        defer c.dbus_message_unref(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(msg, &it);
        appendStr(&it, detail);
        appendI32(&it, d1);
        appendI32(&it, d2);
        switch (any) {
            .none => appendVariantI32(&it, 0),
            .int => |v| appendVariantI32(&it, v),
            .str => |v| appendVariantStr(&it, v.ptr),
        }
        appendRef(&it, self.unique_name, PATH_ROOT);
        _ = c.dbus_connection_send(self.conn, msg, null);
        _ = c.dbus_connection_flush(self.conn);
        self.events_emitted += 1;
    }

    // ------------------------------------------------------------- setup

    /// Hands the registry our (bus name, root path) so the desktop tree
    /// includes us. Without it the objects are exported and nothing looks at
    /// them.
    fn embed(self: *Bridge) Error!void {
        var err: DBusError = .{};
        c.dbus_error_init(err.ptr());
        const msg = c.dbus_message_new_method_call(
            "org.a11y.atspi.Registry",
            PATH_ROOT,
            "org.a11y.atspi.Socket",
            "Embed",
        ) orelse return Error.OutOfMemory;
        defer c.dbus_message_unref(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(msg, &it);
        appendRef(&it, self.unique_name, PATH_ROOT);

        const reply = c.dbus_connection_send_with_reply_and_block(self.conn, msg, 3000, err.ptr());
        if (reply == null) return Error.EmbedFailed;
        c.dbus_message_unref(reply);
    }

    fn registeredEventCount(self: *Bridge) i32 {
        var err: DBusError = .{};
        c.dbus_error_init(err.ptr());
        const msg = c.dbus_message_new_method_call(
            "org.a11y.atspi.Registry",
            "/org/a11y/atspi/registry",
            "org.a11y.atspi.Registry",
            "GetRegisteredEvents",
        ) orelse return -1;
        defer c.dbus_message_unref(msg);
        const reply = c.dbus_connection_send_with_reply_and_block(self.conn, msg, 2000, err.ptr());
        if (reply == null) return -1;
        defer c.dbus_message_unref(reply);
        var it: c.DBusMessageIter = undefined;
        if (c.dbus_message_iter_init(reply, &it) == 0) return 0;
        if (c.dbus_message_iter_get_arg_type(&it) != c.DBUS_TYPE_ARRAY) return 0;
        var sub: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&it, &sub);
        var n: i32 = 0;
        while (c.dbus_message_iter_get_arg_type(&sub) != c.DBUS_TYPE_INVALID) {
            n += 1;
            if (c.dbus_message_iter_next(&sub) == 0) break;
        }
        return n;
    }

    // ----------------------------------------------- the tree, read live

    /// An object path back to what it names, or null for one we never issued.
    ///
    /// A path whose id has been removed answers null, which is the protocol
    /// end of the internal tree's rule that ids are never reused: a client
    /// holding a stale reference is told the object is gone rather than being
    /// handed whatever took its place.
    fn targetFor(self: *const Bridge, path: []const u8) ?Target {
        if (!std.mem.startsWith(u8, path, PATH_PREFIX)) return null;
        const tail = path[PATH_PREFIX.len..];
        if (std.mem.eql(u8, tail, "root")) return .app;
        const id = std.fmt.parseInt(ui.access.NodeId, tail, 10) catch return null;
        if (self.access.get(id) == null) return null;
        return .{ .node = id };
    }

    /// NUL-terminated, because every use of it is a C string: a signal's
    /// path, or an object reference on the wire.
    fn pathOf(self: *const Bridge, t: Target, buf: []u8) [:0]const u8 {
        _ = self;
        return switch (t) {
            .app => PATH_ROOT,
            .node => |id| std.fmt.bufPrintSentinel(buf, PATH_PREFIX ++ "{d}", .{id}, 0) catch PATH_NULL,
        };
    }

    fn nameOf(self: *const Bridge, t: Target) []const u8 {
        return switch (t) {
            .app => self.opts.app_name,
            .node => |id| if (self.access.get(id)) |n| n.name else "",
        };
    }

    fn roleOf(self: *const Bridge, t: Target) a11y.Role {
        return switch (t) {
            .app => .application,
            .node => |id| if (self.access.get(id)) |n| a11y.roleOf(n.role) else .unknown,
        };
    }

    fn statesOf(self: *const Bridge, t: Target) a11y.StateSet {
        return switch (t) {
            // The application itself is not a widget: it is there, and
            // nothing else about it is true.
            .app => a11y.StateSet.of(&.{ .enabled, .sensitive, .showing, .visible }),
            .node => |id| if (self.access.get(id)) |n|
                a11y.statesOf(n, self.access.focus == id)
            else
                .{},
        };
    }

    fn parentOf(self: *const Bridge, t: Target) ?Target {
        return switch (t) {
            .app => null,
            .node => |id| if (id == ui.access.Tree.root)
                .app
            else if (self.access.parent(id)) |p| .{ .node = p } else null,
        };
    }

    fn childrenOf(self: *const Bridge, t: Target) []const ui.access.NodeId {
        return switch (t) {
            // The application's one child is the window, which is the
            // internal tree's root.
            .app => &[_]ui.access.NodeId{ui.access.Tree.root},
            .node => |id| self.access.children(id),
        };
    }

    fn docOf(self: *const Bridge, t: Target) ?*const ui.Document {
        return switch (t) {
            .app => null,
            .node => |id| if (self.access.get(id)) |n| n.doc else null,
        };
    }

    /// The bounds a client is told, in screen coordinates. See `origin_x`.
    fn extentsOf(self: *const Bridge, t: Target) ui.Rect {
        return switch (t) {
            .app => .{},
            .node => |id| if (self.access.bounds(id, self.layout)) |r|
                a11y.screenRect(r, self.origin_x, self.origin_y)
            else
                .{},
        };
    }

    fn indexInParent(self: *const Bridge, t: Target) i32 {
        return switch (t) {
            .app => -1,
            .node => |id| if (id == ui.access.Tree.root)
                0
            else if (self.access.indexInParent(id)) |i| @intCast(i) else -1,
        };
    }
};
// --------------------------------------------------------------- dbus helpers

fn appendStr(it: *c.DBusMessageIter, s: [*c]const u8) void {
    var p = s;
    _ = c.dbus_message_iter_append_basic(it, c.DBUS_TYPE_STRING, @ptrCast(&p));
}

fn appendObjPath(it: *c.DBusMessageIter, s: [*c]const u8) void {
    var p = s;
    _ = c.dbus_message_iter_append_basic(it, c.DBUS_TYPE_OBJECT_PATH, @ptrCast(&p));
}

fn appendI32(it: *c.DBusMessageIter, v: i32) void {
    var x = v;
    _ = c.dbus_message_iter_append_basic(it, c.DBUS_TYPE_INT32, @ptrCast(&x));
}

fn appendU32(it: *c.DBusMessageIter, v: u32) void {
    var x = v;
    _ = c.dbus_message_iter_append_basic(it, c.DBUS_TYPE_UINT32, @ptrCast(&x));
}

/// An AT-SPI object reference is `(so)`: the owning bus name and the object
/// path. Every cross-reference in the protocol is one of these.
fn appendRef(it: *c.DBusMessageIter, bus: [*c]const u8, path: [*c]const u8) void {
    var sub: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(it, c.DBUS_TYPE_STRUCT, null, &sub);
    appendStr(&sub, bus);
    appendObjPath(&sub, path);
    _ = c.dbus_message_iter_close_container(it, &sub);
}

fn appendVariantStr(it: *c.DBusMessageIter, s: [*c]const u8) void {
    var v: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(it, c.DBUS_TYPE_VARIANT, "s", &v);
    appendStr(&v, s);
    _ = c.dbus_message_iter_close_container(it, &v);
}

fn appendVariantI32(it: *c.DBusMessageIter, n: i32) void {
    var v: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(it, c.DBUS_TYPE_VARIANT, "i", &v);
    appendI32(&v, n);
    _ = c.dbus_message_iter_close_container(it, &v);
}

fn appendVariantRef(it: *c.DBusMessageIter, bus: [*c]const u8, path: [*c]const u8) void {
    var v: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(it, c.DBUS_TYPE_VARIANT, "(so)", &v);
    appendRef(&v, bus, path);
    _ = c.dbus_message_iter_close_container(it, &v);
}

fn argI32(msg: ?*c.DBusMessage, index: u32) i32 {
    var it: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(msg, &it) == 0) return 0;
    var k: u32 = 0;
    while (k < index) : (k += 1) {
        if (c.dbus_message_iter_next(&it) == 0) return 0;
    }
    const t = c.dbus_message_iter_get_arg_type(&it);
    if (t == c.DBUS_TYPE_INT32) {
        var v: i32 = 0;
        c.dbus_message_iter_get_basic(&it, @ptrCast(&v));
        return v;
    }
    if (t == c.DBUS_TYPE_UINT32) {
        var v: u32 = 0;
        c.dbus_message_iter_get_basic(&it, @ptrCast(&v));
        return @intCast(v);
    }
    return 0;
}

fn argStr(msg: ?*c.DBusMessage, index: u32) []const u8 {
    var it: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(msg, &it) == 0) return "";
    var k: u32 = 0;
    while (k < index) : (k += 1) {
        if (c.dbus_message_iter_next(&it) == 0) return "";
    }
    if (c.dbus_message_iter_get_arg_type(&it) != c.DBUS_TYPE_STRING) return "";
    var v: [*c]const u8 = null;
    c.dbus_message_iter_get_basic(&it, @ptrCast(&v));
    if (v == null) return "";
    return std.mem.span(v);
}

/// Reads an INT32 out of a variant. `Properties.Set` has signature `(ssv)`, so
/// the value is one level below the top iterator.
fn argVariantI32(msg: ?*c.DBusMessage, index: u32) i32 {
    var it: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(msg, &it) == 0) return 0;
    var k: u32 = 0;
    while (k < index) : (k += 1) {
        if (c.dbus_message_iter_next(&it) == 0) return 0;
    }
    if (c.dbus_message_iter_get_arg_type(&it) != c.DBUS_TYPE_VARIANT) return 0;
    var sub: c.DBusMessageIter = undefined;
    c.dbus_message_iter_recurse(&it, &sub);
    const t = c.dbus_message_iter_get_arg_type(&sub);
    if (t == c.DBUS_TYPE_INT32) {
        var v: i32 = 0;
        c.dbus_message_iter_get_basic(&sub, @ptrCast(&v));
        return v;
    }
    if (t == c.DBUS_TYPE_UINT32) {
        var v: u32 = 0;
        c.dbus_message_iter_get_basic(&sub, @ptrCast(&v));
        return @intCast(v);
    }
    return 0;
}

/// The accessibility bus is a *separate* bus from the session bus, and its
/// address has to be asked for over the session bus first.
fn a11yBusAddress(buf: []u8) Error![]const u8 {
    var err: DBusError = .{};
    c.dbus_error_init(err.ptr());
    const session = c.dbus_bus_get(c.DBUS_BUS_SESSION, err.ptr()) orelse
        return Error.NoSessionBus;
    const msg = c.dbus_message_new_method_call(
        "org.a11y.Bus",
        "/org/a11y/bus",
        "org.a11y.Bus",
        "GetAddress",
    ) orelse return Error.OutOfMemory;
    defer c.dbus_message_unref(msg);
    const reply = c.dbus_connection_send_with_reply_and_block(session, msg, 2000, err.ptr());
    if (reply == null) return Error.NoA11yBus;
    defer c.dbus_message_unref(reply);
    var it: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(reply, &it) == 0) return Error.BadReply;
    var v: [*c]const u8 = null;
    c.dbus_message_iter_get_basic(&it, @ptrCast(&v));
    if (v == null) return Error.BadReply;
    const s = std.mem.span(v);
    if (s.len >= buf.len) return Error.AddressTooLong;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len];
}

// ------------------------------------------------------------ method dispatch

fn send(conn: ?*c.DBusConnection, reply: ?*c.DBusMessage) void {
    _ = c.dbus_connection_send(conn, reply, null);
    c.dbus_message_unref(reply);
}

fn onMessage(
    _: ?*c.DBusConnection,
    msg: ?*c.DBusMessage,
    data: ?*anyopaque,
) callconv(.c) c.DBusHandlerResult {
    const self: *Bridge = @ptrCast(@alignCast(data.?));
    const iface_c = c.dbus_message_get_interface(msg);
    const member_c = c.dbus_message_get_member(msg);
    const path_c = c.dbus_message_get_path(msg);
    if (iface_c == null or member_c == null or path_c == null)
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    const iface = std.mem.span(iface_c);
    const member = std.mem.span(member_c);
    const path = std.mem.span(path_c);

    self.calls_served += 1;

    if (std.mem.eql(u8, iface, IF_INTRO) and std.mem.eql(u8, member, "Introspect")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendStr(&it, introspect_xml);
        send(self.conn, reply);
        return c.DBUS_HANDLER_RESULT_HANDLED;
    }

    if (std.mem.eql(u8, path, PATH_CACHE)) {
        if (handleCache(self, msg, iface, member)) return c.DBUS_HANDLER_RESULT_HANDLED;
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }

    const t = self.targetFor(path) orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

    if (std.mem.eql(u8, iface, IF_APPLICATION)) {
        // Asked by Orca before it reads anything. An empty string means "I am
        // on the main accessibility bus, talk to me there"; an error here
        // makes a client believe the application has a private bus it cannot
        // reach. Found by running Orca, not by reading the specification.
        if (std.mem.eql(u8, member, "GetApplicationBusAddress")) {
            const reply = c.dbus_message_new_method_return(msg);
            var it: c.DBusMessageIter = undefined;
            c.dbus_message_iter_init_append(reply, &it);
            appendStr(&it, "");
            send(self.conn, reply);
            return c.DBUS_HANDLER_RESULT_HANDLED;
        }
        if (std.mem.eql(u8, member, "GetLocale")) {
            const reply = c.dbus_message_new_method_return(msg);
            var it: c.DBusMessageIter = undefined;
            c.dbus_message_iter_init_append(reply, &it);
            appendStr(&it, self.locale_z.ptr);
            send(self.conn, reply);
            return c.DBUS_HANDLER_RESULT_HANDLED;
        }
    }

    const ok = if (std.mem.eql(u8, iface, IF_PROPS))
        handleProps(self, msg, t, member)
    else if (std.mem.eql(u8, iface, IF_ACCESSIBLE))
        handleAccessible(self, msg, t, member)
    else if (std.mem.eql(u8, iface, IF_COMPONENT))
        handleComponent(self, msg, t, member)
    else if (std.mem.eql(u8, iface, IF_TEXT))
        handleText(self, msg, t, member)
    else
        false;

    return if (ok) c.DBUS_HANDLER_RESULT_HANDLED else c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

/// A node's parent, as a reference, or AT-SPI's explicit null.
///
/// The application's parent is the desktop, and the registry fills that in at
/// Embed time. The honest answer from here is the null ref; inventing one is
/// what makes an application show up detached in Accerciser.
fn appendParentRef(it: *c.DBusMessageIter, self: *Bridge, t: Target, variant: bool) void {
    var buf: [64]u8 = undefined;
    if (self.parentOf(t)) |p| {
        const z = self.pathOf(p, &buf);
        if (variant) appendVariantRef(it, self.unique_name, z.ptr) else appendRef(it, self.unique_name, z.ptr);
    } else {
        if (variant) appendVariantRef(it, "", PATH_NULL) else appendRef(it, "", PATH_NULL);
    }
}

fn appendNodeRef(it: *c.DBusMessageIter, self: *Bridge, t: Target) void {
    var buf: [64]u8 = undefined;
    appendRef(it, self.unique_name, self.pathOf(t, &buf).ptr);
}

fn handleProps(self: *Bridge, msg: ?*c.DBusMessage, t: Target, member: []const u8) bool {
    const iface = argStr(msg, 0);

    if (std.mem.eql(u8, member, "Set")) {
        const prop = argStr(msg, 1);
        if (std.mem.eql(u8, iface, IF_APPLICATION) and std.mem.eql(u8, prop, "Id")) {
            self.app_id = argVariantI32(msg, 2);
        }
        // A property Set replies with an empty method return, not a value.
        send(self.conn, c.dbus_message_new_method_return(msg));
        return true;
    }

    if (std.mem.eql(u8, member, "Get")) {
        const prop = argStr(msg, 1);
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);

        if (std.mem.eql(u8, iface, IF_ACCESSIBLE)) {
            if (std.mem.eql(u8, prop, "Name")) {
                appendVariantStr(&it, self.zeroTerm(self.nameOf(t)).ptr);
            } else if (std.mem.eql(u8, prop, "ChildCount")) {
                appendVariantI32(&it, @intCast(self.childrenOf(t).len));
            } else if (std.mem.eql(u8, prop, "Locale")) {
                appendVariantStr(&it, self.locale_z.ptr);
            } else if (std.mem.eql(u8, prop, "Parent")) {
                appendParentRef(&it, self, t, true);
            } else {
                appendVariantStr(&it, "");
            }
        } else if (std.mem.eql(u8, iface, IF_APPLICATION)) {
            if (std.mem.eql(u8, prop, "ToolkitName")) {
                appendVariantStr(&it, self.toolkit_name_z.ptr);
            } else if (std.mem.eql(u8, prop, "Version") or
                std.mem.eql(u8, prop, "ToolkitVersion"))
            {
                appendVariantStr(&it, self.toolkit_version_z.ptr);
            } else if (std.mem.eql(u8, prop, "AtspiVersion")) {
                appendVariantStr(&it, "2.1");
            } else if (std.mem.eql(u8, prop, "InterfaceVersion")) {
                appendVariantI32(&it, 1);
            } else if (std.mem.eql(u8, prop, "Id")) {
                appendVariantI32(&it, self.app_id);
            } else {
                appendVariantStr(&it, "");
            }
        } else if (std.mem.eql(u8, iface, IF_TEXT)) {
            const doc = self.docOf(t);
            if (std.mem.eql(u8, prop, "CharacterCount")) {
                // CHARACTERS, not bytes.
                const s = if (doc) |d| d.text() else "";
                appendVariantI32(&it, @intCast(a11y.characterCount(s)));
            } else if (std.mem.eql(u8, prop, "CaretOffset")) {
                appendVariantI32(&it, if (doc) |d| @intCast(a11y.caretOffset(d)) else 0);
            } else {
                appendVariantI32(&it, 0);
            }
        } else {
            appendVariantStr(&it, "");
        }
        send(self.conn, reply);
        return true;
    }

    if (std.mem.eql(u8, member, "GetAll")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var arr: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_ARRAY, "{sv}", &arr);

        if (std.mem.eql(u8, iface, IF_ACCESSIBLE)) {
            dictStr(&arr, "Name", self.zeroTerm(self.nameOf(t)).ptr);
            dictStr(&arr, "Description", "");
            dictI32(&arr, "ChildCount", @intCast(self.childrenOf(t).len));
            var d: c.DBusMessageIter = undefined;
            _ = c.dbus_message_iter_open_container(&arr, c.DBUS_TYPE_DICT_ENTRY, null, &d);
            appendStr(&d, "Parent");
            appendParentRef(&d, self, t, true);
            _ = c.dbus_message_iter_close_container(&arr, &d);
        } else if (std.mem.eql(u8, iface, IF_TEXT)) {
            const doc = self.docOf(t);
            const s = if (doc) |d| d.text() else "";
            dictI32(&arr, "CharacterCount", @intCast(a11y.characterCount(s)));
            dictI32(&arr, "CaretOffset", if (doc) |d| @intCast(a11y.caretOffset(d)) else 0);
        }
        _ = c.dbus_message_iter_close_container(&it, &arr);
        send(self.conn, reply);
        return true;
    }
    return false;
}

fn dictStr(arr: *c.DBusMessageIter, key: [*c]const u8, value: [*c]const u8) void {
    var d: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(arr, c.DBUS_TYPE_DICT_ENTRY, null, &d);
    appendStr(&d, key);
    appendVariantStr(&d, value);
    _ = c.dbus_message_iter_close_container(arr, &d);
}

fn dictI32(arr: *c.DBusMessageIter, key: [*c]const u8, value: i32) void {
    var d: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(arr, c.DBUS_TYPE_DICT_ENTRY, null, &d);
    appendStr(&d, key);
    appendVariantI32(&d, value);
    _ = c.dbus_message_iter_close_container(arr, &d);
}

/// The interfaces a node implements, which is how a client knows what to ask
/// it. Everything has Accessible; only the application has Application;
/// anything with bounds has Component; only a document-backed node has Text.
fn appendInterfaces(arr: *c.DBusMessageIter, self: *Bridge, t: Target) void {
    appendStr(arr, IF_ACCESSIBLE);
    if (t == .app) appendStr(arr, IF_APPLICATION);
    if (self.extentsOf(t).w > 0) appendStr(arr, IF_COMPONENT);
    if (self.docOf(t) != null) appendStr(arr, IF_TEXT);
}

fn handleAccessible(self: *Bridge, msg: ?*c.DBusMessage, t: Target, member: []const u8) bool {
    if (std.mem.eql(u8, member, "GetRole")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendU32(&it, @backingInt(self.roleOf(t)));
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetRoleName") or
        std.mem.eql(u8, member, "GetLocalizedRoleName"))
    {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendStr(&it, self.roleOf(t).atspiName().ptr);
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetState")) {
        // `au` of exactly two words: bits 0-31 then 32-63.
        const st = self.statesOf(t);
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var arr: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_ARRAY, "u", &arr);
        appendU32(&arr, st.low());
        appendU32(&arr, st.high());
        _ = c.dbus_message_iter_close_container(&it, &arr);
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetChildAtIndex")) {
        const i = argI32(msg, 0);
        const kids = self.childrenOf(t);
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        if (i >= 0 and i < kids.len) {
            appendNodeRef(&it, self, .{ .node = kids[@intCast(i)] });
        } else {
            appendRef(&it, "", PATH_NULL);
        }
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetChildren")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var arr: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_ARRAY, "(so)", &arr);
        for (self.childrenOf(t)) |ci| appendNodeRef(&arr, self, .{ .node = ci });
        _ = c.dbus_message_iter_close_container(&it, &arr);
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetIndexInParent")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendI32(&it, self.indexInParent(t));
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetApplication")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendRef(&it, self.unique_name, PATH_ROOT);
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetInterfaces")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var arr: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_ARRAY, "s", &arr);
        appendInterfaces(&arr, self, t);
        _ = c.dbus_message_iter_close_container(&it, &arr);
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetRelationSet")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var arr: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_ARRAY, "(ua(so))", &arr);
        _ = c.dbus_message_iter_close_container(&it, &arr);
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetAttributes")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var arr: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_ARRAY, "{ss}", &arr);
        _ = c.dbus_message_iter_close_container(&it, &arr);
        send(self.conn, reply);
        return true;
    }
    return false;
}

fn handleComponent(self: *Bridge, msg: ?*c.DBusMessage, t: Target, member: []const u8) bool {
    const r = self.extentsOf(t);
    const x: i32 = @intFromFloat(r.x);
    const y: i32 = @intFromFloat(r.y);
    const w: i32 = @intFromFloat(r.w);
    const h: i32 = @intFromFloat(r.h);

    if (std.mem.eql(u8, member, "GetExtents")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var s: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_STRUCT, null, &s);
        appendI32(&s, x);
        appendI32(&s, y);
        appendI32(&s, w);
        appendI32(&s, h);
        _ = c.dbus_message_iter_close_container(&it, &s);
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetPosition")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendI32(&it, x);
        appendI32(&it, y);
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetSize")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendI32(&it, w);
        appendI32(&it, h);
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetLayer")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendU32(&it, 3); // ATSPI_LAYER_WIDGET
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "Contains")) {
        const px = argI32(msg, 0);
        const py = argI32(msg, 1);
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var yes: c.dbus_bool_t = if (px >= x and px < x + w and py >= y and py < y + h) 1 else 0;
        _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_BOOLEAN, @ptrCast(&yes));
        send(self.conn, reply);
        return true;
    }
    return false;
}

fn handleText(self: *Bridge, msg: ?*c.DBusMessage, t: Target, member: []const u8) bool {
    const doc = self.docOf(t) orelse return false;
    const s = doc.text();

    if (std.mem.eql(u8, member, "GetText")) {
        // Offsets arrive in CHARACTERS and are converted before they touch the
        // byte-indexed document. `a11y.getText` is that conversion and the
        // only place it happens.
        const start = argI32(msg, 0);
        const end = argI32(msg, 1);
        const n_chars = a11y.characterCount(s);
        const a: usize = if (start <= 0) 0 else @intCast(start);
        const b: usize = if (end < 0) n_chars else @intCast(end);
        const z = self.zeroTerm(a11y.getText(s, a, b));
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendStr(&it, z.ptr);
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetCharacterCount")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendI32(&it, @intCast(a11y.characterCount(s)));
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetCaretOffset")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendI32(&it, @intCast(a11y.caretOffset(doc)));
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetNSelections")) {
        const sel = a11y.selection(doc);
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendI32(&it, if (sel.start == sel.end) 0 else 1);
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetSelection")) {
        const sel = a11y.selection(doc);
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendI32(&it, @intCast(sel.start));
        appendI32(&it, @intCast(sel.end));
        send(self.conn, reply);
        return true;
    }
    return false;
}

/// One cache item: `((so)(so)(so)iiassusau)` -- object, application, parent,
/// index in parent, child count, interfaces, name, role, description, states.
/// The signature is from the introspection XML embedded in
/// `libatk-bridge-2.0.so.0`, which is the reference implementation.
fn appendCacheItem(arr: *c.DBusMessageIter, self: *Bridge, t: Target) void {
    var st: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(arr, c.DBUS_TYPE_STRUCT, null, &st);

    appendNodeRef(&st, self, t);
    appendRef(&st, self.unique_name, PATH_ROOT);
    appendParentRef(&st, self, t, false);

    appendI32(&st, self.indexInParent(t));
    appendI32(&st, @intCast(self.childrenOf(t).len));

    var ifs: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(&st, c.DBUS_TYPE_ARRAY, "s", &ifs);
    appendInterfaces(&ifs, self, t);
    _ = c.dbus_message_iter_close_container(&st, &ifs);

    appendStr(&st, self.zeroTerm(self.nameOf(t)).ptr);
    appendU32(&st, @backingInt(self.roleOf(t)));
    appendStr(&st, "");

    const states = self.statesOf(t);
    var sts: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(&st, c.DBUS_TYPE_ARRAY, "u", &sts);
    appendU32(&sts, states.low());
    appendU32(&sts, states.high());
    _ = c.dbus_message_iter_close_container(&st, &sts);

    _ = c.dbus_message_iter_close_container(arr, &st);
}

/// Orca's **first** move on a new application is `Cache.GetItems`: it pulls
/// the whole tree in one call rather than walking node by node. Without it an
/// application is listed by name and then unreadable, which is exactly what
/// spike C's first Orca run showed.
fn handleCache(self: *Bridge, msg: ?*c.DBusMessage, iface: []const u8, member: []const u8) bool {
    if (std.mem.eql(u8, iface, IF_CACHE) and std.mem.eql(u8, member, "GetItems")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var arr: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(
            &it,
            c.DBUS_TYPE_ARRAY,
            "((so)(so)(so)iiassusau)",
            &arr,
        );
        appendCacheItem(&arr, self, .app);
        // Every live node, by id. Dead ids are skipped rather than renumbered,
        // which is the whole point of never reusing them.
        var id: ui.access.NodeId = 0;
        while (id < self.access.nodes.items.len) : (id += 1) {
            if (self.access.get(id) == null) continue;
            appendCacheItem(&arr, self, .{ .node = id });
        }
        _ = c.dbus_message_iter_close_container(&it, &arr);
        send(self.conn, reply);
        return true;
    }
    if (std.mem.eql(u8, iface, IF_PROPS) and std.mem.eql(u8, member, "Get")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var v: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_VARIANT, "u", &v);
        appendU32(&v, 2);
        _ = c.dbus_message_iter_close_container(&it, &v);
        send(self.conn, reply);
        return true;
    }
    return false;
}

const introspect_xml =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\  <interface name="org.a11y.atspi.Accessible">
    \\    <property name="Name" type="s" access="read"/>
    \\    <property name="Description" type="s" access="read"/>
    \\    <property name="Parent" type="(so)" access="read"/>
    \\    <property name="ChildCount" type="i" access="read"/>
    \\    <method name="GetChildAtIndex"><arg direction="in" type="i"/><arg direction="out" type="(so)"/></method>
    \\    <method name="GetChildren"><arg direction="out" type="a(so)"/></method>
    \\    <method name="GetIndexInParent"><arg direction="out" type="i"/></method>
    \\    <method name="GetRelationSet"><arg direction="out" type="a(ua(so))"/></method>
    \\    <method name="GetRole"><arg direction="out" type="u"/></method>
    \\    <method name="GetRoleName"><arg direction="out" type="s"/></method>
    \\    <method name="GetLocalizedRoleName"><arg direction="out" type="s"/></method>
    \\    <method name="GetState"><arg direction="out" type="au"/></method>
    \\    <method name="GetAttributes"><arg direction="out" type="a{ss}"/></method>
    \\    <method name="GetApplication"><arg direction="out" type="(so)"/></method>
    \\    <method name="GetInterfaces"><arg direction="out" type="as"/></method>
    \\  </interface>
    \\  <interface name="org.a11y.atspi.Component">
    \\    <method name="Contains"><arg direction="in" type="i"/><arg direction="in" type="i"/><arg direction="in" type="u"/><arg direction="out" type="b"/></method>
    \\    <method name="GetExtents"><arg direction="in" type="u"/><arg direction="out" type="(iiii)"/></method>
    \\    <method name="GetPosition"><arg direction="in" type="u"/><arg direction="out" type="i"/><arg direction="out" type="i"/></method>
    \\    <method name="GetSize"><arg direction="out" type="i"/><arg direction="out" type="i"/></method>
    \\    <method name="GetLayer"><arg direction="out" type="u"/></method>
    \\  </interface>
    \\  <interface name="org.a11y.atspi.Text">
    \\    <property name="CharacterCount" type="i" access="read"/>
    \\    <property name="CaretOffset" type="i" access="read"/>
    \\    <method name="GetText"><arg direction="in" type="i"/><arg direction="in" type="i"/><arg direction="out" type="s"/></method>
    \\    <method name="GetCharacterCount"><arg direction="out" type="i"/></method>
    \\    <method name="GetCaretOffset"><arg direction="out" type="i"/></method>
    \\    <method name="GetNSelections"><arg direction="out" type="i"/></method>
    \\    <method name="GetSelection"><arg direction="in" type="i"/><arg direction="out" type="i"/><arg direction="out" type="i"/></method>
    \\  </interface>
    \\  <interface name="org.a11y.atspi.Application">
    \\    <property name="ToolkitName" type="s" access="read"/>
    \\    <property name="Version" type="s" access="read"/>
    \\    <property name="AtspiVersion" type="s" access="read"/>
    \\    <property name="Id" type="i" access="readwrite"/>
    \\    <method name="GetLocale"><arg direction="in" type="u"/><arg direction="out" type="s"/></method>
    \\    <method name="GetApplicationBusAddress"><arg direction="out" type="s"/></method>
    \\  </interface>
    \\</node>
;
