//! Spike C: can a self-drawn widget expose a real accessibility tree on Linux,
//! from Zig?
//!
//! This is the other half of tier A from docs/native-vs-drawn.md, and the half
//! nobody in the Zig ecosystem has touched: dvui has no accessibility, and
//! ddalcu/zigui has no accessibility files at all. The design note says that if
//! this work is merely adequate the self-drawn argument collapses, because a
//! widget that looks native but is invisible to a screen reader is strictly
//! worse than the native widget it imitates.
//!
//! There is no shortcut available. The GTK route (ATK plus the at-spi2-atk
//! bridge) requires being a GTK app. `libatspi` is the *client* library, for
//! screen readers, not for applications exposing a tree. So an application that
//! draws its own widgets must implement the AT-SPI DBus interfaces directly --
//! which is exactly what AccessKit's Linux backend does.
//!
//! THE FINDING THAT MATTERS, and it is a trap rather than a difficulty:
//!
//!   AT-SPI text offsets are in CHARACTERS.
//!   zwp_text_input_v3 offsets are in BYTES.
//!
//! The same text field has to speak bytes to the input method and characters to
//! the screen reader. Spike B's document model is byte-indexed throughout,
//! deliberately, because that is what the IME needs; every offset crossing into
//! AT-SPI must be converted. Getting it backwards does not crash and does not
//! show up in ASCII -- the screen reader just reads the wrong characters, which
//! is the kind of bug that ships.
//!
//! The text in the tree below is Vietnamese for that reason: "tiếng việt" is
//! 10 characters and 14 bytes, so the two numbers cannot be confused by
//! accident.
//!
//! SCOPE: a three-node tree, the four interfaces a text field needs, and
//! registration with the running registry. No events, no focus tracking, no
//! live editing. Enough to answer "is this feasible and what is the minimum".

const std = @import("std");
const c = @import("c");

// --------------------------------------------------------------- AT-SPI enums

// Extracted from /usr/include/at-spi-2.0/atspi/atspi-constants.h rather than
// guessed; the enums are long and the values are not obvious.
const ROLE_FRAME: u32 = 23;
const ROLE_APPLICATION: u32 = 75;
const ROLE_ENTRY: u32 = 79;

const ST_ACTIVE: u6 = 1;
const ST_EDITABLE: u6 = 7;
const ST_ENABLED: u6 = 8;
const ST_FOCUSABLE: u6 = 11;
const ST_FOCUSED: u6 = 12;
const ST_SENSITIVE: u6 = 24;
const ST_SHOWING: u6 = 25;
const ST_SINGLE_LINE: u6 = 26;
const ST_VISIBLE: u6 = 30;

fn bit(b: u6) u64 {
    return @as(u64, 1) << b;
}

const IF_ACCESSIBLE = "org.a11y.atspi.Accessible";
const IF_APPLICATION = "org.a11y.atspi.Application";
const IF_COMPONENT = "org.a11y.atspi.Component";
const IF_TEXT = "org.a11y.atspi.Text";
const IF_PROPS = "org.freedesktop.DBus.Properties";
const IF_INTRO = "org.freedesktop.DBus.Introspectable";

const PATH_PREFIX = "/org/a11y/atspi/accessible/";
const PATH_ROOT = "/org/a11y/atspi/accessible/root";
/// AT-SPI's explicit null reference. A parent or child slot that has no object
/// is this, not an empty path.
const PATH_NULL = "/org/a11y/atspi/null";

// ----------------------------------------------------------------------- tree

const Node = struct {
    path: [:0]const u8,
    name: [:0]const u8,
    role: u32,
    role_name: [:0]const u8,
    parent: i32, // index, -1 for none
    children: []const u32,
    states: u64,
    /// Screen coordinates. A real toolkit computes these from the element's
    /// layout bounds plus the window origin.
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    /// Non-empty only for nodes implementing org.a11y.atspi.Text.
    text: [:0]const u8 = "",
    has_text: bool = false,
};

const ENTRY_TEXT = "tiếng việt";

var nodes = [_]Node{
    .{
        .path = PATH_ROOT,
        .name = "zig-uikit a11y spike",
        .role = ROLE_APPLICATION,
        .role_name = "application",
        .parent = -1,
        .children = &.{1},
        .states = bit(ST_ENABLED) | bit(ST_SENSITIVE) | bit(ST_SHOWING) | bit(ST_VISIBLE),
    },
    .{
        .path = PATH_PREFIX ++ "1",
        .name = "Spike window",
        .role = ROLE_FRAME,
        .role_name = "frame",
        .parent = 0,
        .children = &.{2},
        .states = bit(ST_ENABLED) | bit(ST_SENSITIVE) | bit(ST_SHOWING) |
            bit(ST_VISIBLE) | bit(ST_ACTIVE),
        .x = 100,
        .y = 100,
        .w = 720,
        .h = 180,
    },
    .{
        .path = PATH_PREFIX ++ "2",
        .name = "Name",
        .role = ROLE_ENTRY,
        .role_name = "entry",
        .parent = 1,
        .children = &.{},
        .states = bit(ST_ENABLED) | bit(ST_SENSITIVE) | bit(ST_SHOWING) |
            bit(ST_VISIBLE) | bit(ST_FOCUSABLE) | bit(ST_FOCUSED) |
            bit(ST_EDITABLE) | bit(ST_SINGLE_LINE),
        .x = 108,
        .y = 140,
        .w = 300,
        .h = 28,
        .text = ENTRY_TEXT,
        .has_text = true,
    },
};

fn nodeByPath(path: []const u8) ?*Node {
    for (&nodes) |*n| if (std.mem.eql(u8, n.path, path)) return n;
    return null;
}

// ------------------------------------------------------- byte/character offsets

/// AT-SPI counts characters; our document model counts bytes. Every offset that
/// crosses this boundary goes through one of these two functions, and nowhere
/// else in the file does an offset change units.
fn charCount(s: []const u8) i32 {
    return @intCast(std.unicode.utf8CountCodepoints(s) catch s.len);
}

fn charToByte(s: []const u8, char_off: i32) usize {
    if (char_off <= 0) return 0;
    var seen: i32 = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (seen == char_off) return i;
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += n;
        seen += 1;
    }
    return s.len;
}

// --------------------------------------------------------------- dbus helpers

/// translate-c renders `DBusError` as opaque, because the struct carries five
/// one-bit bitfields and Zig has no C bitfield support. The layout is stable
/// and documented, so it is redeclared here and verified against the C
/// compiler: sizeof 32, align 8, name at 0, message at 8 on x86_64.
///
/// This is the first thing in these spikes that Zig could not do through
/// translate-c at all. It is not hard, but it is the kind of friction a
/// toolkit binding C libraries will keep meeting.
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

var conn: ?*c.DBusConnection = null;
var unique_name: [*c]const u8 = undefined;

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

fn appendNullRef(it: *c.DBusMessageIter) void {
    appendRef(it, "", PATH_NULL);
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

fn send(reply: ?*c.DBusMessage) void {
    _ = c.dbus_connection_send(conn, reply, null);
    c.dbus_message_unref(reply);
}

// -------------------------------------------------------------- introspection

const INTROSPECT_XML =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\  <interface name="org.freedesktop.DBus.Introspectable">
    \\    <method name="Introspect"><arg name="data" direction="out" type="s"/></method>
    \\  </interface>
    \\  <interface name="org.freedesktop.DBus.Properties">
    \\    <method name="Get">
    \\      <arg direction="in" type="s"/><arg direction="in" type="s"/>
    \\      <arg direction="out" type="v"/>
    \\    </method>
    \\    <method name="GetAll">
    \\      <arg direction="in" type="s"/><arg direction="out" type="a{sv}"/>
    \\    </method>
    \\  </interface>
    \\  <interface name="org.a11y.atspi.Accessible">
    \\    <property name="Name" type="s" access="read"/>
    \\    <property name="Description" type="s" access="read"/>
    \\    <property name="Parent" type="(so)" access="read"/>
    \\    <property name="ChildCount" type="i" access="read"/>
    \\    <method name="GetRole"><arg direction="out" type="u"/></method>
    \\    <method name="GetRoleName"><arg direction="out" type="s"/></method>
    \\    <method name="GetState"><arg direction="out" type="au"/></method>
    \\    <method name="GetChildAtIndex">
    \\      <arg direction="in" type="i"/><arg direction="out" type="(so)"/>
    \\    </method>
    \\    <method name="GetChildren"><arg direction="out" type="a(so)"/></method>
    \\    <method name="GetIndexInParent"><arg direction="out" type="i"/></method>
    \\    <method name="GetInterfaces"><arg direction="out" type="as"/></method>
    \\  </interface>
    \\  <interface name="org.a11y.atspi.Component">
    \\    <method name="GetExtents">
    \\      <arg direction="in" type="u"/><arg direction="out" type="(iiii)"/>
    \\    </method>
    \\    <method name="GetLayer"><arg direction="out" type="u"/></method>
    \\  </interface>
    \\  <interface name="org.a11y.atspi.Text">
    \\    <property name="CharacterCount" type="i" access="read"/>
    \\    <property name="CaretOffset" type="i" access="read"/>
    \\    <method name="GetText">
    \\      <arg direction="in" type="i"/><arg direction="in" type="i"/>
    \\      <arg direction="out" type="s"/>
    \\    </method>
    \\  </interface>
    \\</node>
;

// ------------------------------------------------------------- method dispatch

var n_calls: u32 = 0;

fn handleProps(msg: ?*c.DBusMessage, n: *Node, member: []const u8) bool {
    const iface = argStr(msg, 0);
    if (std.mem.eql(u8, member, "Get")) {
        const prop = argStr(msg, 1);
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);

        if (std.mem.eql(u8, iface, IF_ACCESSIBLE)) {
            if (std.mem.eql(u8, prop, "Name")) {
                appendVariantStr(&it, n.name.ptr);
            } else if (std.mem.eql(u8, prop, "Description")) {
                appendVariantStr(&it, "");
            } else if (std.mem.eql(u8, prop, "ChildCount")) {
                appendVariantI32(&it, @intCast(n.children.len));
            } else if (std.mem.eql(u8, prop, "Locale")) {
                appendVariantStr(&it, "vi_VN.UTF-8");
            } else if (std.mem.eql(u8, prop, "AccessibleId")) {
                appendVariantStr(&it, n.path.ptr);
            } else if (std.mem.eql(u8, prop, "Parent")) {
                if (n.parent < 0) {
                    // The application's parent is the desktop. Reporting a null
                    // ref here is what makes an app show up detached in
                    // Accerciser; the registry fills this in at Embed time, so
                    // the honest answer from us is the null ref.
                    appendVariantRef(&it, "", PATH_NULL);
                } else {
                    appendVariantRef(&it, unique_name, nodes[@intCast(n.parent)].path.ptr);
                }
            } else {
                appendVariantStr(&it, "");
            }
        } else if (std.mem.eql(u8, iface, IF_APPLICATION)) {
            if (std.mem.eql(u8, prop, "ToolkitName")) {
                appendVariantStr(&it, "zig-uikit");
            } else if (std.mem.eql(u8, prop, "Version")) {
                appendVariantStr(&it, "0.0.0-spike");
            } else if (std.mem.eql(u8, prop, "AtspiVersion")) {
                appendVariantStr(&it, "2.1");
            } else if (std.mem.eql(u8, prop, "Id")) {
                appendVariantI32(&it, 1);
            } else {
                appendVariantStr(&it, "");
            }
        } else if (std.mem.eql(u8, iface, IF_TEXT)) {
            if (std.mem.eql(u8, prop, "CharacterCount")) {
                // CHARACTERS, not bytes. See the header.
                appendVariantI32(&it, charCount(n.text));
            } else if (std.mem.eql(u8, prop, "CaretOffset")) {
                appendVariantI32(&it, charCount(n.text));
            } else {
                appendVariantI32(&it, 0);
            }
        } else {
            appendVariantStr(&it, "");
        }
        send(reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetAll")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var arr: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_ARRAY, "{sv}", &arr);

        const Entry = struct { k: [*c]const u8, kind: u8 };
        if (std.mem.eql(u8, iface, IF_ACCESSIBLE)) {
            inline for (.{ "Name", "Description", "ChildCount", "Parent" }) |k| {
                var d: c.DBusMessageIter = undefined;
                _ = c.dbus_message_iter_open_container(&arr, c.DBUS_TYPE_DICT_ENTRY, null, &d);
                appendStr(&d, k);
                if (comptime std.mem.eql(u8, k, "Name")) {
                    appendVariantStr(&d, n.name.ptr);
                } else if (comptime std.mem.eql(u8, k, "Description")) {
                    appendVariantStr(&d, "");
                } else if (comptime std.mem.eql(u8, k, "ChildCount")) {
                    appendVariantI32(&d, @intCast(n.children.len));
                } else {
                    if (n.parent < 0)
                        appendVariantRef(&d, "", PATH_NULL)
                    else
                        appendVariantRef(&d, unique_name, nodes[@intCast(n.parent)].path.ptr);
                }
                _ = c.dbus_message_iter_close_container(&arr, &d);
            }
        } else if (std.mem.eql(u8, iface, IF_TEXT)) {
            inline for (.{ "CharacterCount", "CaretOffset" }) |k| {
                var d: c.DBusMessageIter = undefined;
                _ = c.dbus_message_iter_open_container(&arr, c.DBUS_TYPE_DICT_ENTRY, null, &d);
                appendStr(&d, k);
                appendVariantI32(&d, charCount(n.text));
                _ = c.dbus_message_iter_close_container(&arr, &d);
            }
        }
        _ = Entry; // kept for shape; unused in this minimal set
        _ = c.dbus_message_iter_close_container(&it, &arr);
        send(reply);
        return true;
    }
    return false;
}

fn handleAccessible(msg: ?*c.DBusMessage, n: *Node, member: []const u8) bool {
    if (std.mem.eql(u8, member, "GetRole")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendU32(&it, n.role);
        send(reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetRoleName") or
        std.mem.eql(u8, member, "GetLocalizedRoleName"))
    {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendStr(&it, n.role_name.ptr);
        send(reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetState")) {
        // `au` of exactly two words: bits 0-31 then 32-63.
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var arr: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_ARRAY, "u", &arr);
        appendU32(&arr, @truncate(n.states));
        appendU32(&arr, @truncate(n.states >> 32));
        _ = c.dbus_message_iter_close_container(&it, &arr);
        send(reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetChildAtIndex")) {
        const i = argI32(msg, 0);
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        if (i >= 0 and i < n.children.len) {
            appendRef(&it, unique_name, nodes[n.children[@intCast(i)]].path.ptr);
        } else {
            appendNullRef(&it);
        }
        send(reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetChildren")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var arr: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_ARRAY, "(so)", &arr);
        for (n.children) |ci| appendRef(&arr, unique_name, nodes[ci].path.ptr);
        _ = c.dbus_message_iter_close_container(&it, &arr);
        send(reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetIndexInParent")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var idx: i32 = -1;
        if (n.parent >= 0) {
            const p = nodes[@intCast(n.parent)];
            for (p.children, 0..) |ci, k| {
                if (std.mem.eql(u8, nodes[ci].path, n.path)) idx = @intCast(k);
            }
        }
        appendI32(&it, idx);
        send(reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetApplication")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendRef(&it, unique_name, PATH_ROOT);
        send(reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetInterfaces")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var arr: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_ARRAY, "s", &arr);
        appendStr(&arr, IF_ACCESSIBLE);
        if (n.parent < 0) appendStr(&arr, IF_APPLICATION);
        if (n.w > 0) appendStr(&arr, IF_COMPONENT);
        if (n.has_text) appendStr(&arr, IF_TEXT);
        _ = c.dbus_message_iter_close_container(&it, &arr);
        send(reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetRelationSet")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var arr: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_ARRAY, "(ua(so))", &arr);
        _ = c.dbus_message_iter_close_container(&it, &arr);
        send(reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetAttributes")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var arr: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_ARRAY, "{ss}", &arr);
        _ = c.dbus_message_iter_close_container(&it, &arr);
        send(reply);
        return true;
    }
    return false;
}

fn handleComponent(msg: ?*c.DBusMessage, n: *Node, member: []const u8) bool {
    if (std.mem.eql(u8, member, "GetExtents")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        var s: c.DBusMessageIter = undefined;
        _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_STRUCT, null, &s);
        appendI32(&s, n.x);
        appendI32(&s, n.y);
        appendI32(&s, n.w);
        appendI32(&s, n.h);
        _ = c.dbus_message_iter_close_container(&it, &s);
        send(reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetPosition")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendI32(&it, n.x);
        appendI32(&it, n.y);
        send(reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetSize")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendI32(&it, n.w);
        appendI32(&it, n.h);
        send(reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetLayer")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendU32(&it, 3); // ATSPI_LAYER_WIDGET
        send(reply);
        return true;
    }
    return false;
}

fn handleText(msg: ?*c.DBusMessage, n: *Node, member: []const u8) bool {
    if (std.mem.eql(u8, member, "GetText")) {
        // Offsets arrive in CHARACTERS and must be converted before they touch
        // the byte-indexed buffer. This is the conversion the header warns
        // about; it is the only place in the file that changes units.
        const start = argI32(msg, 0);
        var end = argI32(msg, 1);
        if (end < 0) end = charCount(n.text);
        const b0 = charToByte(n.text, start);
        const b1 = charToByte(n.text, end);
        var tmp: [512]u8 = undefined;
        const lo = @min(b0, b1);
        const hi = @max(b0, b1);
        const len = @min(hi - lo, tmp.len - 1);
        @memcpy(tmp[0..len], n.text[lo..][0..len]);
        tmp[len] = 0;
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendStr(&it, &tmp);
        send(reply);
        return true;
    }
    if (std.mem.eql(u8, member, "GetCharacterCount")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendI32(&it, charCount(n.text));
        send(reply);
        return true;
    }
    return false;
}

fn onMessage(
    _: ?*c.DBusConnection,
    msg: ?*c.DBusMessage,
    _: ?*anyopaque,
) callconv(.c) c.DBusHandlerResult {
    const iface_c = c.dbus_message_get_interface(msg);
    const member_c = c.dbus_message_get_member(msg);
    const path_c = c.dbus_message_get_path(msg);
    if (iface_c == null or member_c == null or path_c == null)
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    const iface = std.mem.span(iface_c);
    const member = std.mem.span(member_c);
    const path = std.mem.span(path_c);

    n_calls += 1;
    std.debug.print("  -> {s}.{s} on {s}\n", .{ iface, member, path });

    if (std.mem.eql(u8, iface, IF_INTRO) and std.mem.eql(u8, member, "Introspect")) {
        const reply = c.dbus_message_new_method_return(msg);
        var it: c.DBusMessageIter = undefined;
        c.dbus_message_iter_init_append(reply, &it);
        appendStr(&it, INTROSPECT_XML);
        send(reply);
        return c.DBUS_HANDLER_RESULT_HANDLED;
    }

    const n = nodeByPath(path) orelse return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

    const ok = if (std.mem.eql(u8, iface, IF_PROPS))
        handleProps(msg, n, member)
    else if (std.mem.eql(u8, iface, IF_ACCESSIBLE))
        handleAccessible(msg, n, member)
    else if (std.mem.eql(u8, iface, IF_COMPONENT))
        handleComponent(msg, n, member)
    else if (std.mem.eql(u8, iface, IF_TEXT))
        handleText(msg, n, member)
    else
        false;

    if (!ok) {
        std.debug.print("     (unhandled)\n", .{});
        return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    }
    return c.DBUS_HANDLER_RESULT_HANDLED;
}

// ---------------------------------------------------------------------- setup

/// The accessibility bus is a *separate* bus from the session bus, and its
/// address has to be asked for over the session bus first.
fn a11yBusAddress(buf: []u8) ![]const u8 {
    var err: DBusError = .{};
    c.dbus_error_init(err.ptr());
    const session = c.dbus_bus_get(c.DBUS_BUS_SESSION, err.ptr()) orelse return error.NoSessionBus;
    const msg = c.dbus_message_new_method_call(
        "org.a11y.Bus",
        "/org/a11y/bus",
        "org.a11y.Bus",
        "GetAddress",
    ) orelse return error.OutOfMemory;
    defer c.dbus_message_unref(msg);
    const reply = c.dbus_connection_send_with_reply_and_block(session, msg, 2000, err.ptr());
    if (reply == null) {
        std.debug.print("org.a11y.Bus.GetAddress failed: {s}\n", .{err.msg()});
        return error.NoA11yBus;
    }
    defer c.dbus_message_unref(reply);
    var it: c.DBusMessageIter = undefined;
    if (c.dbus_message_iter_init(reply, &it) == 0) return error.BadReply;
    var v: [*c]const u8 = null;
    c.dbus_message_iter_get_basic(&it, @ptrCast(&v));
    if (v == null) return error.BadReply;
    const s = std.mem.span(v);
    if (s.len >= buf.len) return error.AddressTooLong;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf[0..s.len];
}

/// Hands the registry our (bus name, root path) so the desktop tree includes
/// us. Without this the objects are exported but nothing is looking at them.
fn embed() !void {
    var err: DBusError = .{};
    c.dbus_error_init(err.ptr());
    const msg = c.dbus_message_new_method_call(
        "org.a11y.atspi.Registry",
        PATH_ROOT,
        "org.a11y.atspi.Socket",
        "Embed",
    ) orelse return error.OutOfMemory;
    defer c.dbus_message_unref(msg);
    var it: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(msg, &it);
    appendRef(&it, unique_name, PATH_ROOT);

    const reply = c.dbus_connection_send_with_reply_and_block(conn, msg, 3000, err.ptr());
    if (reply == null) {
        std.debug.print("Socket.Embed failed: {s}\n", .{err.msg()});
        return error.EmbedFailed;
    }
    defer c.dbus_message_unref(reply);
    std.debug.print("Socket.Embed accepted by the registry\n", .{});
}

pub fn main(init: std.process.Init.Minimal) !void {
    var seconds: u32 = 0;
    var itr = std.process.Args.Iterator.init(init.args);
    _ = itr.next();
    while (itr.next()) |a| {
        if (std.mem.startsWith(u8, a, "--seconds=")) {
            seconds = std.fmt.parseInt(u32, a["--seconds=".len..], 10) catch 0;
        }
    }

    std.debug.print(
        \\zig-uikit a11y spike -- AT-SPI over DBus, implemented directly.
        \\
        \\  entry text  "{s}"
        \\  bytes       {d}   <- what the IME protocol counts
        \\  characters  {d}   <- what AT-SPI counts
        \\
    , .{ ENTRY_TEXT, ENTRY_TEXT.len, charCount(ENTRY_TEXT) });

    var abuf: [512]u8 = undefined;
    const addr = try a11yBusAddress(&abuf);
    std.debug.print("a11y bus: {s}\n", .{addr});

    var err: DBusError = .{};
    c.dbus_error_init(err.ptr());
    conn = c.dbus_connection_open_private(addr.ptr, err.ptr()) orelse {
        std.debug.print("cannot open the a11y bus\n", .{});
        return error.OpenFailed;
    };
    if (c.dbus_bus_register(conn, err.ptr()) == 0) {
        std.debug.print("dbus_bus_register failed\n", .{});
        return error.RegisterFailed;
    }
    unique_name = c.dbus_bus_get_unique_name(conn);
    std.debug.print("our bus name: {s}\n", .{std.mem.span(unique_name)});

    // One fallback handler for the whole accessible subtree, rather than a
    // registration per object: an accessibility tree is dynamic, and
    // re-registering paths as elements come and go would be pure overhead.
    var vtable = std.mem.zeroes(c.DBusObjectPathVTable);
    vtable.message_function = onMessage;
    if (c.dbus_connection_register_fallback(conn, "/org/a11y/atspi/accessible", &vtable, null) == 0) {
        return error.RegisterPathFailed;
    }

    try embed();

    std.debug.print(
        \\
        \\Exported 3 nodes: application -> frame -> entry
        \\
        \\Inspect from another terminal:
        \\  busctl --user --address='{s}' \
        \\      introspect {s} {s}
        \\
        \\Or read the entry's text the way a screen reader would:
        \\  gdbus call --address '{s}' \
        \\      --dest {s} --object-path {s}2 \
        \\      --method org.a11y.atspi.Text.GetText 0 -1
        \\
        \\
    , .{
        addr,
        std.mem.span(unique_name),
        PATH_ROOT,
        addr,
        std.mem.span(unique_name),
        PATH_PREFIX,
    });

    const deadline: i64 = if (seconds == 0) std.math.maxInt(i64) else @intCast(seconds * 1000);
    var elapsed: i64 = 0;
    while (elapsed < deadline) {
        if (c.dbus_connection_read_write_dispatch(conn, 200) == 0) break;
        elapsed += 200;
    }

    std.debug.print("\n--- observed ---\n  dbus calls served  {d}\n", .{n_calls});
}
