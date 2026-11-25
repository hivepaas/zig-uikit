//! An accessibility client, in another process: what VoiceOver sees of the
//! window demo, through the same `AXUIElement` API VoiceOver and Accessibility
//! Inspector use.
//!
//!     ./zig-out/bin/window_demo --ax &
//!     sleep 1; ./zig-out/bin/ax_probe $!
//!
//! It walks the window's tree, reads the text field the way a screen reader
//! does -- value, length, selection, a substring by UTF-16 range, the bounds
//! of that range -- hit-tests a point, presses the button, and then listens
//! for the notifications the demo posts while it types. The checks print
//! `ok` or `WRONG`, and the process exits non-zero on any `WRONG`.
//!
//! It needs the Accessibility permission (System Settings, Privacy &
//! Security), like any client; the process it inherits from is what is asked.
//! Spikes C and D used Orca and Narrator for this. A program is less
//! convincing than a screen reader and more repeatable; both are worth having,
//! and this is the one that runs unattended.

const std = @import("std");

const CFTypeRef = *anyopaque;
const CFStringRef = *anyopaque;
const AXUIElementRef = *anyopaque;
const AXObserverRef = *anyopaque;

const CGPoint = extern struct { x: f64, y: f64 };
const CGSize = extern struct { width: f64, height: f64 };
const CGRect = extern struct { origin: CGPoint, size: CGSize };
const CFRange = extern struct { location: isize, length: isize };

const kAXValueCGPointType: u32 = 1;
const kAXValueCGSizeType: u32 = 2;
const kAXValueCGRectType: u32 = 3;
const kAXValueCFRangeType: u32 = 4;
const kCFStringEncodingUTF8: u32 = 0x08000100;
const kCFNumberSInt64Type: c_int = 4;

extern "ApplicationServices" fn AXUIElementCreateApplication(pid: c_int) AXUIElementRef;
extern "ApplicationServices" fn AXUIElementCopyAttributeValue(el: AXUIElementRef, attr: CFStringRef, out: *?CFTypeRef) i32;
extern "ApplicationServices" fn AXUIElementCopyParameterizedAttributeValue(el: AXUIElementRef, attr: CFStringRef, param: CFTypeRef, out: *?CFTypeRef) i32;
extern "ApplicationServices" fn AXUIElementCopyElementAtPosition(app: AXUIElementRef, x: f32, y: f32, out: *?AXUIElementRef) i32;
extern "ApplicationServices" fn AXUIElementSetAttributeValue(el: AXUIElementRef, attr: CFStringRef, value: CFTypeRef) i32;
extern "ApplicationServices" fn AXUIElementPerformAction(el: AXUIElementRef, action: CFStringRef) i32;
extern "ApplicationServices" fn AXUIElementSetMessagingTimeout(el: AXUIElementRef, seconds: f32) i32;
extern "ApplicationServices" fn AXValueCreate(t: u32, ptr: *const anyopaque) ?CFTypeRef;
extern "ApplicationServices" fn AXValueGetValue(v: CFTypeRef, t: u32, out: *anyopaque) bool;
extern "ApplicationServices" fn AXObserverCreate(pid: c_int, cb: *const fn (AXObserverRef, AXUIElementRef, CFStringRef, ?*anyopaque) callconv(.c) void, out: *?AXObserverRef) i32;
extern "ApplicationServices" fn AXObserverAddNotification(obs: AXObserverRef, el: AXUIElementRef, notification: CFStringRef, refcon: ?*anyopaque) i32;
extern "ApplicationServices" fn AXObserverGetRunLoopSource(obs: AXObserverRef) *anyopaque;
extern "ApplicationServices" fn AXIsProcessTrusted() bool;

extern "CoreFoundation" fn CFStringCreateWithCString(alloc: ?*anyopaque, s: [*:0]const u8, enc: u32) CFStringRef;
extern "CoreFoundation" fn CFStringGetCString(s: CFStringRef, buf: [*]u8, len: isize, enc: u32) bool;
extern "CoreFoundation" fn CFGetTypeID(v: CFTypeRef) usize;
extern "CoreFoundation" fn CFStringGetTypeID() usize;
extern "CoreFoundation" fn CFArrayGetTypeID() usize;
extern "CoreFoundation" fn CFNumberGetTypeID() usize;
extern "CoreFoundation" fn CFArrayGetCount(a: CFTypeRef) isize;
extern "CoreFoundation" fn CFArrayGetValueAtIndex(a: CFTypeRef, i: isize) CFTypeRef;
extern "CoreFoundation" fn CFNumberGetValue(n: CFTypeRef, t: c_int, out: *anyopaque) bool;
extern "CoreFoundation" fn CFRelease(v: CFTypeRef) void;
extern "CoreFoundation" fn CFRetain(v: CFTypeRef) CFTypeRef;
extern "CoreFoundation" fn CFRunLoopGetCurrent() *anyopaque;
extern "CoreFoundation" fn CFRunLoopAddSource(rl: *anyopaque, src: *anyopaque, mode: CFStringRef) void;
extern "CoreFoundation" fn CFRunLoopRunInMode(mode: CFStringRef, seconds: f64, return_after_source: bool) i32;
extern "CoreFoundation" var kCFRunLoopDefaultMode: CFStringRef;

/// A `CFString` for a constant name, made once per name and kept.
fn cf(comptime s: [:0]const u8) CFStringRef {
    const S = struct {
        const _s = s;
        var v: ?CFStringRef = null;
    };
    if (S.v) |v| return v;
    S.v = CFStringCreateWithCString(null, s, kCFStringEncodingUTF8);
    return S.v.?;
}

var queries: u32 = 0;
var failures: u32 = 0;

fn attr(el: AXUIElementRef, comptime name: [:0]const u8) ?CFTypeRef {
    queries += 1;
    var out: ?CFTypeRef = null;
    if (AXUIElementCopyAttributeValue(el, cf(name), &out) != 0) return null;
    return out;
}

fn paramAttr(el: AXUIElementRef, comptime name: [:0]const u8, param: CFTypeRef) ?CFTypeRef {
    queries += 1;
    var out: ?CFTypeRef = null;
    if (AXUIElementCopyParameterizedAttributeValue(el, cf(name), param, &out) != 0) return null;
    return out;
}

/// A string attribute into `buf`, or null.
fn str(v: ?CFTypeRef, buf: []u8) ?[]const u8 {
    const x = v orelse return null;
    defer CFRelease(x);
    if (CFGetTypeID(x) != CFStringGetTypeID()) return null;
    if (!CFStringGetCString(x, buf.ptr, @intCast(buf.len), kCFStringEncodingUTF8)) return null;
    return std.mem.sliceTo(buf, 0);
}

fn int(v: ?CFTypeRef) ?i64 {
    const x = v orelse return null;
    defer CFRelease(x);
    if (CFGetTypeID(x) != CFNumberGetTypeID()) return null;
    var n: i64 = 0;
    _ = CFNumberGetValue(x, kCFNumberSInt64Type, &n);
    return n;
}

fn axValue(comptime T: type, v: ?CFTypeRef, t: u32) ?T {
    const x = v orelse return null;
    defer CFRelease(x);
    var out: T = undefined;
    if (!AXValueGetValue(x, t, &out)) return null;
    return out;
}

fn frameOf(el: AXUIElementRef) ?CGRect {
    const p = axValue(CGPoint, attr(el, "AXPosition"), kAXValueCGPointType) orelse return null;
    const s = axValue(CGSize, attr(el, "AXSize"), kAXValueCGSizeType) orelse return null;
    return .{ .origin = p, .size = s };
}

fn check(ok: bool, comptime what: []const u8, args: anytype) void {
    std.debug.print("  " ++ what ++ " -- {s}\n", args ++ .{if (ok) "ok" else "WRONG"});
    if (!ok) failures += 1;
}

const Found = struct {
    nodes: u32 = 0,
    static_text: u32 = 0,
    groups: u32 = 0,
    text_field: ?AXUIElementRef = null,
    button: ?AXUIElementRef = null,
};

fn walk(el: AXUIElementRef, depth: usize, found: *Found) void {
    var rb: [64]u8 = undefined;
    var nb: [256]u8 = undefined;
    const role = str(attr(el, "AXRole"), &rb) orelse "?";
    found.nodes += 1;
    if (std.mem.eql(u8, role, "AXStaticText")) found.static_text += 1;
    if (std.mem.eql(u8, role, "AXGroup")) found.groups += 1;
    // Retained: `el` belongs to its parent's children array, which is
    // released when the walk leaves it.
    if (std.mem.eql(u8, role, "AXTextField")) found.text_field = CFRetain(el);
    if (std.mem.eql(u8, role, "AXButton") and found.button == null) found.button = CFRetain(el);
    // Print the top of the tree and the interesting nodes, not all seventy.
    const name = str(attr(el, "AXDescription"), &nb) orelse str(attr(el, "AXValue"), &nb) orelse str(attr(el, "AXTitle"), &nb) orelse "";
    if (depth <= 2 or !std.mem.eql(u8, role, "AXStaticText")) {
        const f = frameOf(el);
        for (0..depth) |_| std.debug.print("  ", .{});
        std.debug.print("{s} \"{s}\"", .{ role, name });
        if (f) |r| std.debug.print(" at ({d:.0},{d:.0}) {d:.0}x{d:.0}", .{ r.origin.x, r.origin.y, r.size.width, r.size.height });
        std.debug.print("\n", .{});
    }
    const kids = attr(el, "AXChildren") orelse return;
    defer CFRelease(kids);
    if (CFGetTypeID(kids) != CFArrayGetTypeID()) return;
    const n = CFArrayGetCount(kids);
    var i: isize = 0;
    while (i < n) : (i += 1) walk(CFArrayGetValueAtIndex(kids, i), depth + 1, found);
}

var notes_value: u32 = 0;
var notes_selection: u32 = 0;
var notes_destroyed: u32 = 0;

fn onNotification(_: AXObserverRef, _: AXUIElementRef, name: CFStringRef, _: ?*anyopaque) callconv(.c) void {
    var b: [64]u8 = undefined;
    // Not `str`, which releases what it reads: the name is borrowed here.
    if (!CFStringGetCString(name, &b, b.len, kCFStringEncodingUTF8)) return;
    const n = std.mem.sliceTo(&b, 0);
    if (std.mem.eql(u8, n, "AXValueChanged")) notes_value += 1;
    if (std.mem.eql(u8, n, "AXSelectedTextChanged")) notes_selection += 1;
    if (std.mem.eql(u8, n, "AXUIElementDestroyed")) notes_destroyed += 1;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const pid_s = args.next() orelse {
        std.debug.print("usage: ax_probe <pid of window_demo --ax>\n", .{});
        return error.Usage;
    };
    const pid = try std.fmt.parseInt(c_int, pid_s, 10);
    if (!AXIsProcessTrusted()) {
        std.debug.print("this process is not trusted for accessibility; grant it in System Settings\n", .{});
        return error.NotTrusted;
    }

    const app = AXUIElementCreateApplication(pid);
    _ = AXUIElementSetMessagingTimeout(app, 2);

    const windows = attr(app, "AXWindows") orelse return error.NoWindows;
    defer CFRelease(windows);
    if (CFArrayGetCount(windows) < 1) return error.NoWindows;
    const window = CFArrayGetValueAtIndex(windows, 0);

    var found: Found = .{};
    const t0 = std.c.mach_absolute_time();
    walk(window, 0, &found);
    const walk_ticks = std.c.mach_absolute_time() - t0;
    std.debug.print("\n{d} nodes: {d} static text, {d} groups, {d} queries, {d:.1} ms to walk\n\n", .{
        found.nodes, found.static_text, found.groups, queries, @as(f64, @floatFromInt(walk_ticks)) * 41.667 / 1e6,
    });

    // --- the text field, read the way a screen reader reads it ---
    const field = found.text_field orelse return error.NoTextField;
    var b1: [512]u8 = undefined;
    const value = str(attr(field, "AXValue"), &b1) orelse "";
    std.debug.print("text field \"{s}\"\n", .{value});
    const initial = "Gõ vào đây: tiếng ";
    check(std.mem.eql(u8, value, initial), "AXValue is the document", .{});
    // 18 UTF-16 units, 24 bytes: a client counting bytes gets 24.
    const n_chars = int(attr(field, "AXNumberOfCharacters")) orelse -1;
    check(n_chars == 18, "AXNumberOfCharacters {d} is UTF-16 units, not 24 bytes", .{n_chars});
    const sel = axValue(CFRange, attr(field, "AXSelectedTextRange"), kAXValueCFRangeType);
    check(sel != null and sel.?.location == 18 and sel.?.length == 0, "AXSelectedTextRange is the caret at the end", .{});
    // `tiếng` is units 12..17 and bytes 16..23.
    const want_range: CFRange = .{ .location = 12, .length = 5 };
    const range_v = AXValueCreate(kAXValueCFRangeType, &want_range).?;
    defer CFRelease(range_v);
    var b2: [64]u8 = undefined;
    const sub = str(paramAttr(field, "AXStringForRange", range_v), &b2) orelse "";
    check(std.mem.eql(u8, sub, "tiếng"), "AXStringForRange(12, 5) is \"{s}\"", .{sub});
    // VoiceOver moving the caret: the one attribute the field lets a client
    // set. Selected, read back, and put back, so the typing below still
    // appends rather than replacing.
    queries += 1;
    const set_err = AXUIElementSetAttributeValue(field, cf("AXSelectedTextRange"), range_v);
    var b6: [64]u8 = undefined;
    const selected = str(attr(field, "AXSelectedText"), &b6) orelse "";
    check(set_err == 0 and std.mem.eql(u8, selected, "tiếng"), "setting AXSelectedTextRange(12, 5) selects \"{s}\"", .{selected});
    const end_range: CFRange = .{ .location = 18, .length = 0 };
    const end_v = AXValueCreate(kAXValueCFRangeType, &end_range).?;
    defer CFRelease(end_v);
    queries += 1;
    _ = AXUIElementSetAttributeValue(field, cf("AXSelectedTextRange"), end_v);
    const field_frame = frameOf(field);
    const word = axValue(CGRect, paramAttr(field, "AXBoundsForRange", range_v), kAXValueCGRectType);
    check(word != null and field_frame != null and
        word.?.origin.x > field_frame.?.origin.x and
        word.?.origin.x + word.?.size.width < field_frame.?.origin.x + field_frame.?.size.width and
        word.?.size.width > 10, "AXBoundsForRange puts the word inside the field, in screen coordinates", .{});
    var b3: [64]u8 = undefined;
    const focused = attr(app, "AXFocusedUIElement");
    const focused_role = if (focused) |f| blk: {
        defer CFRelease(f);
        break :blk str(attr(f, "AXRole"), &b3) orelse "";
    } else "";
    check(std.mem.eql(u8, focused_role, "AXTextField"), "AXFocusedUIElement is the text field", .{});

    // --- hit testing and an action ---
    if (found.button) |button| {
        const f = frameOf(button).?;
        var hit: ?AXUIElementRef = null;
        queries += 1;
        _ = AXUIElementCopyElementAtPosition(app, @floatCast(f.origin.x + f.size.width / 2), @floatCast(f.origin.y + f.size.height / 2), &hit);
        var b4: [64]u8 = undefined;
        const hit_role = if (hit) |h| str(attr(h, "AXRole"), &b4) orelse "" else "";
        check(std.mem.eql(u8, hit_role, "AXButton"), "the element at the button's centre is the button", .{});
        queries += 1;
        check(AXUIElementPerformAction(button, cf("AXPress")) == 0, "AXPress on the button", .{});
    } else check(false, "found a button", .{});

    // --- notifications while the demo types ---
    var obs: ?AXObserverRef = null;
    if (AXObserverCreate(pid, &onNotification, &obs) != 0) return error.NoObserver;
    const e1 = AXObserverAddNotification(obs.?, field, cf("AXValueChanged"), null);
    const e2 = AXObserverAddNotification(obs.?, field, cf("AXSelectedTextChanged"), null);
    if (e1 != 0 or e2 != 0) return error.NoObserver;
    // The demo removes the button's node five seconds in.
    if (found.button) |button| _ = AXObserverAddNotification(obs.?, button, cf("AXUIElementDestroyed"), null);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs.?), kCFRunLoopDefaultMode);
    std.debug.print("\nlistening while the demo types...\n", .{});
    _ = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 7.5, false);
    var b5: [512]u8 = undefined;
    const after = str(attr(field, "AXValue"), &b5) orelse "";
    std.debug.print("  {d} AXValueChanged, {d} AXSelectedTextChanged\n", .{ notes_value, notes_selection });
    check(notes_value == 8, "one value change per character of \"xin chào\"", .{});
    check(std.mem.eql(u8, after, initial ++ "xin chào"), "AXValue afterwards is \"{s}\"", .{after});

    // The button's node is gone. The object this process holds for it is
    // still a valid reference -- a retain, not a pointer -- and asking it
    // anything is an error, not a crash in either process.
    check(notes_destroyed == 1, "AXUIElementDestroyed for the removed button, {d} of them", .{notes_destroyed});
    if (found.button) |button| {
        var out: ?CFTypeRef = null;
        queries += 1;
        const err = AXUIElementCopyAttributeValue(button, cf("AXRole"), &out);
        if (out) |o| CFRelease(o);
        check(err != 0, "asking the removed button its role is error {d}", .{err});
    }

    std.debug.print("\n{d} queries in all, {d} wrong\n", .{ queries, failures });
    if (failures > 0) return error.ProbeFailed;
}
