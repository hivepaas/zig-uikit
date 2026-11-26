//! `NSAccessibility` for the window: the accessibility tree in `access.zig`,
//! as AppKit's accessibility objects.
//!
//! **Pull, in process, like UIA.** A client -- VoiceOver, Accessibility
//! Inspector, anything holding an `AXUIElementRef` to this process -- asks
//! AppKit's accessibility server, which calls methods on objects in this
//! process: `accessibilityChildren`, `accessibilityFrame`, `accessibilityValue`.
//! Nothing is pushed and nothing is serialised. So every method below reads the
//! live tree, the live layout and the live document when it is called, and
//! keeps nothing that could go stale; the only cache is the object per node.
//!
//! **One object per node, made on first request.** An `NSAccessibilityElement`
//! subclass defined at run time, `ZigUIKitAXElement`, holding a node id --
//! not a pointer to the node -- so that a removed node makes its object answer
//! nothing rather than read freed memory.
//!
//! **Lifetimes: AppKit's server stands between the client and the object,
//! which settles §5 here.** The problem spike D deferred is that a client can
//! hold a reference past the element it describes; in UIA that reference is a
//! COM pointer into this process. On a Mac it is not: a client in another
//! process holds an `AXUIElementRef` token, and AppKit's accessibility server
//! maps it to the object. Measured with `ax_probe`: after a node is removed
//! and the window releases its object, the object is freed (its `dealloc`
//! runs and frees the Zig state) while the probe still holds its token, and
//! the probe's next question gets `kAXErrorInvalidUIElement` -- an error in
//! the client, not a use-after-free in either process. Nor is notifying the
//! window's job: AppKit posts `AXUIElementDestroyed` when the object is
//! deallocated, and posting it by hand as well breaks it (see `retire`). So
//! removing a node is releasing an object, and no equivalent of
//! `UiaDisconnectProvider` is needed.
//!
//! **Notifications are gated on someone having asked.** §4 found that Linux
//! can answer "is anyone listening" and Windows cannot. AppKit offers no such
//! query either -- VoiceOver's flag says nothing about Accessibility Inspector
//! or automation tools -- so the gate here is the one Chromium uses: until a
//! client has called into the tree at least once, nothing is posted. The
//! window demo measures whether AppKit calls in by itself; see the README.

const std = @import("std");
const objc = @import("objc");
const ui = @import("zig-uikit");
const macos = @import("macos.zig");

const id = objc.id;
const send = objc.send;
const Window = macos.Window;
const access = ui.access;
const NodeId = access.NodeId;
const ic = ui.input_client;

/// What the window describes to accessibility clients.
pub const Target = struct {
    tree: *access.Tree,
    layout: *const ui.Tree,
};

/// Calls into the tree, by method: the number spike D measured as 93 for
/// Narrator on a two-node tree.
pub const Stats = struct {
    calls: [@typeInfo(Method).@"enum".field_names.len]u32 = @splat(0),
    /// Objects made, and objects whose node was removed while a client might
    /// still hold them.
    elements_made: u32 = 0,
    elements_retired: u32 = 0,
    notifications_posted: u32 = 0,
    /// Notifications not posted because no client has called in yet.
    notifications_gated: u32 = 0,

    pub fn total(self: *const Stats) u64 {
        var n: u64 = 0;
        for (self.calls) |c| n += c;
        return n;
    }

    pub fn count(self: *const Stats, m: Method) u32 {
        return self.calls[@backingInt(m)];
    }
};

pub const Method = enum {
    view_children,
    view_focused,
    view_hit_test,
    role,
    label,
    value,
    parent,
    children,
    frame,
    focused,
    enabled,
    number_of_characters,
    selected_text_range,
    selected_text,
    visible_character_range,
    insertion_point_line,
    string_for_range,
    frame_for_range,
    line_for_index,
    range_for_line,
    perform_press,
    set_selected_text_range,
};

/// The Zig half of one `ZigUIKitAXElement`. Owned by the object and freed in
/// its `dealloc`; `window` goes null when the node or the window goes away.
const ElementState = struct {
    window: ?*Window,
    node: NodeId,
};

const gpa = std.heap.c_allocator;

/// Objects whose last reference went away, process-wide: the window's and
/// every client's. Counted because it is the evidence that a retired object
/// is actually freed once the client lets go, rather than leaked to be safe.
pub var elements_freed: u32 = 0;

// ------------------------------------------------------------ window side

pub fn attach(w: *Window, target: ?Target) void {
    detach(w);
    w.access = target;
    if (target) |t| w.access_revision = t.tree.revision;
}

/// Retires every object: marks its state dead and drops the window's
/// reference, which frees it; AppKit tells clients. A client still holding a
/// token for one gets `kAXErrorInvalidUIElement` when it asks.
pub fn detach(w: *Window) void {
    var it = w.access_elements.iterator();
    while (it.next()) |e| retire(w, e.value_ptr.*);
    w.access_elements.clearRetainingCapacity();
    w.access = null;
}

/// Drops the window's reference to a retired object.
///
/// Nothing is posted. AppKit posts `AXUIElementDestroyed` itself when an
/// accessibility element is deallocated, and measured with `ax_probe`:
///
///   - release only                      client told once     -- this
///   - post, then release a second later  client told twice
///   - post, then release at once          client told never
///
/// The last is the surprising one and was this file's first version. Posting
/// the notification by hand is therefore not merely redundant but harmful.
fn retire(w: *Window, el: id) void {
    if (stateOf(el)) |st| st.window = null;
    w.access_stats.elements_retired += 1;
    objc.release(el);
}

/// Called from `pump`: drops the objects of nodes the tree no longer has.
pub fn sweep(w: *Window) void {
    const t = w.access orelse return;
    if (t.tree.revision == w.access_revision) return;
    w.access_revision = t.tree.revision;
    var dead: std.ArrayList(NodeId) = .empty;
    defer dead.deinit(gpa);
    var it = w.access_elements.iterator();
    while (it.next()) |e| {
        if (t.tree.get(e.key_ptr.*) == null) dead.append(gpa, e.key_ptr.*) catch return;
    }
    for (dead.items) |n| {
        const el = w.access_elements.fetchRemove(n).?.value;
        retire(w, el);
    }
}

/// The value or selection of a text node changed. Posts the notifications a
/// screen reader reads typing from, if anyone has asked about this window.
pub fn textChanged(w: *Window, node: NodeId, edited: bool) void {
    if (gated(w)) return;
    const el = elementFor(w, node) orelse return;
    if (edited) post(w, el, "AXValueChanged");
    post(w, el, "AXSelectedTextChanged");
}

pub fn focusChanged(w: *Window) void {
    if (gated(w)) return;
    const t = w.access orelse return;
    const el = elementFor(w, t.tree.focus) orelse return;
    post(w, el, "AXFocusedUIElementChanged");
}

extern "AppKit" fn NSAccessibilityPostNotification(element: id, notification: id) void;

// The notification names are the *values* of AppKit's constants, which are
// the AX strings: `NSAccessibilityValueChangedNotification` is
// `@"AXValueChanged"`. Passing the constant's own name posts a notification
// nobody can have registered for, silently -- which is how the first version
// of this file posted sixteen and delivered none.

/// True, and counted, when no client has called in yet. Checked before an
/// object is made, so that a window nobody inspects makes none.
fn gated(w: *Window) bool {
    if (w.access_stats.total() != 0) return false;
    w.access_stats.notifications_gated += 1;
    return true;
}

fn post(w: *Window, el: id, comptime name: [:0]const u8) void {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    NSAccessibilityPostNotification(el, objc.string(name));
    w.access_stats.notifications_posted += 1;
}

fn elementFor(w: *Window, node: NodeId) ?id {
    const t = w.access orelse return null;
    if (t.tree.get(node) == null or node == access.Tree.root) return null;
    if (w.access_elements.get(node)) |el| return el;
    const cls = elementClass() catch return null;
    const st = gpa.create(ElementState) catch return null;
    st.* = .{ .window = w, .node = node };
    const el = objc.new(cls);
    objc.setState(el, cls, st);
    w.access_elements.put(w.gpa, node, el) catch {
        objc.release(el);
        return null;
    };
    w.access_stats.elements_made += 1;
    return el;
}

/// An autoreleased `NSArray` of the objects for these nodes.
fn arrayOf(w: *Window, nodes: []const NodeId) ?id {
    const arr = send(id, objc.class("NSMutableArray") catch return null, "arrayWithCapacity:", .{nodes.len});
    for (nodes) |n| {
        if (elementFor(w, n)) |el| send(void, arr, "addObject:", .{el});
    }
    return arr;
}

// --------------------------------------------------------------- the view

/// The view stands for the root: it is not an element itself, so AppKit
/// promotes its children to the window, which is where VoiceOver expects a
/// window's content to start.
pub fn viewChildren(w: *Window) ?id {
    const t = w.access orelse return null;
    w.access_stats.calls[@backingInt(Method.view_children)] += 1;
    return arrayOf(w, t.tree.children(access.Tree.root));
}

pub fn viewFocused(w: *Window, view: id) id {
    w.access_stats.calls[@backingInt(Method.view_focused)] += 1;
    const t = w.access orelse return view;
    return elementFor(w, t.tree.focus) orelse view;
}

/// The deepest node under a screen point, or the view. Asked by VoiceOver's
/// mouse-follows mode and by Accessibility Inspector's pointer.
pub fn viewHitTest(w: *Window, view: id, screen: objc.CGPoint) id {
    w.access_stats.calls[@backingInt(Method.view_hit_test)] += 1;
    const t = w.access orelse return view;
    const p = w.screenPointToLayout(screen);
    var best: NodeId = access.Tree.root;
    var at: NodeId = access.Tree.root;
    descend: while (true) {
        for (t.tree.children(at)) |c| {
            const b = t.tree.bounds(c, t.layout) orelse continue;
            if (p.x >= b.x and p.y >= b.y and p.x < b.x + b.w and p.y < b.y + b.h) {
                best = c;
                at = c;
                continue :descend;
            }
        }
        break;
    }
    return elementFor(w, best) orelse view;
}

// ------------------------------------------------------------ the element

var element_class: ?objc.Class = null;

const B = if (objc.BOOL == bool) "B" else "c";
const R = "{_NSRange=QQ}";
const RECT = "{CGRect={CGPoint=dd}{CGSize=dd}}";

fn elementClass() objc.Error!objc.Class {
    if (element_class) |c| return c;
    if (try objc.ClassBuilder.begin("NSAccessibilityElement", "ZigUIKitAXElement")) |b| {
        try b.method("dealloc", &dealloc, "v@:");
        try b.method("isAccessibilityElement", &isElement, B ++ "@:");
        try b.method("accessibilityRole", &role, "@@:");
        try b.method("accessibilityLabel", &label, "@@:");
        try b.method("accessibilityValue", &value, "@@:");
        try b.method("accessibilityParent", &parent, "@@:");
        try b.method("accessibilityChildren", &children, "@@:");
        try b.method("accessibilityFrame", &frame, RECT ++ "@:");
        try b.method("isAccessibilityFocused", &focused, B ++ "@:");
        try b.method("isAccessibilityEnabled", &enabled, B ++ "@:");
        try b.method("accessibilityNumberOfCharacters", &numberOfCharacters, "q@:");
        try b.method("accessibilitySelectedTextRange", &selectedTextRange, R ++ "@:");
        try b.method("accessibilitySelectedText", &selectedText, "@@:");
        try b.method("accessibilityVisibleCharacterRange", &visibleCharacterRange, R ++ "@:");
        try b.method("accessibilityInsertionPointLineNumber", &insertionPointLine, "q@:");
        try b.method("accessibilityStringForRange:", &stringForRange, "@@:" ++ R);
        try b.method("accessibilityFrameForRange:", &frameForRange, RECT ++ "@:" ++ R);
        try b.method("accessibilityLineForIndex:", &lineForIndex, "q@:q");
        try b.method("accessibilityRangeForLine:", &rangeForLine, R ++ "@:q");
        try b.method("accessibilityPerformPress", &performPress, B ++ "@:");
        try b.method("setAccessibilitySelectedTextRange:", &setSelectedTextRange, "v@:" ++ R);
        element_class = b.finish();
    } else {
        element_class = try objc.class("ZigUIKitAXElement");
    }
    return element_class.?;
}

fn stateOf(el: id) ?*ElementState {
    return objc.getState(ElementState, el, element_class orelse return null);
}

/// The window and node an object describes, if both still exist, counting
/// the call.
fn resolve(el: id, m: Method) ?struct { w: *Window, t: Target, n: *const access.Node } {
    const st = stateOf(el) orelse return null;
    const w = st.window orelse return null;
    w.access_stats.calls[@backingInt(m)] += 1;
    const t = w.access orelse return null;
    const n = t.tree.get(st.node) orelse return null;
    return .{ .w = w, .t = t, .n = n };
}

fn dealloc(self: id, _: objc.SEL) callconv(.c) void {
    if (stateOf(self)) |st| gpa.destroy(st);
    elements_freed += 1;
    objc.setState(self, element_class.?, null);
    objc.sendSuper(void, self, element_class.?, "dealloc", .{});
}

fn isElement(_: id, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}

fn role(self: id, _: objc.SEL) callconv(.c) ?id {
    const r = resolve(self, .role) orelse return null;
    return objc.string(switch (r.n.role) {
        .window, .group => "AXGroup",
        .static_text => "AXStaticText",
        .text_field => "AXTextField",
        .button => "AXButton",
    });
}

fn label(self: id, _: objc.SEL) callconv(.c) ?id {
    const r = resolve(self, .label) orelse return null;
    // Static text says its text as its value; a label as well would be read
    // twice.
    if (r.n.role == .static_text or r.n.name.len == 0) return null;
    return objc.stringFromSlice(r.n.name);
}

fn value(self: id, _: objc.SEL) callconv(.c) ?id {
    const r = resolve(self, .value) orelse return null;
    return switch (r.n.role) {
        .static_text => objc.stringFromSlice(r.n.name),
        .text_field => objc.stringFromSlice(if (r.n.doc) |d| d.text() else ""),
        else => null,
    };
}

fn parent(self: id, _: objc.SEL) callconv(.c) ?id {
    const r = resolve(self, .parent) orelse return null;
    if (r.n.parent == access.Tree.root) return r.w.view;
    return elementFor(r.w, r.n.parent) orelse r.w.view;
}

fn children(self: id, _: objc.SEL) callconv(.c) ?id {
    const r = resolve(self, .children) orelse return null;
    return arrayOf(r.w, r.n.children.items);
}

const zero_rect: objc.CGRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };

fn frame(self: id, _: objc.SEL) callconv(.c) objc.CGRect {
    const r = resolve(self, .frame) orelse return zero_rect;
    const b = r.t.tree.bounds(r.n.id, r.t.layout) orelse return zero_rect;
    return r.w.layoutRectToScreen(b);
}

fn focused(self: id, _: objc.SEL) callconv(.c) objc.BOOL {
    const r = resolve(self, .focused) orelse return objc.NO;
    return if (r.t.tree.focus == r.n.id and r.w.focused) objc.YES else objc.NO;
}

fn enabled(self: id, _: objc.SEL) callconv(.c) objc.BOOL {
    const r = resolve(self, .enabled) orelse return objc.NO;
    return if (r.n.state.disabled) objc.NO else objc.YES;
}

// Text. Every range is UTF-16, as `NSString` is, and converts through
// `input_client.zig` -- which converts through `offsets.zig`, the only place
// units change (§1).

fn docOf(self: id, m: Method) ?struct { w: *Window, doc: *const ui.Document } {
    const r = resolve(self, m) orelse return null;
    const d = r.n.doc orelse return null;
    return .{ .w = r.w, .doc = d };
}

fn utf16Len(s: []const u8) usize {
    return ui.offsets.byteToUtf16(s, s.len);
}

fn numberOfCharacters(self: id, _: objc.SEL) callconv(.c) objc.NSInteger {
    const d = docOf(self, .number_of_characters) orelse return 0;
    return @intCast(utf16Len(d.doc.text()));
}

fn selectedTextRange(self: id, _: objc.SEL) callconv(.c) ic.Utf16Range {
    const d = docOf(self, .selected_text_range) orelse return .{ .location = 0, .length = 0 };
    return ic.selectedRange(d.doc);
}

fn selectedText(self: id, _: objc.SEL) callconv(.c) ?id {
    const d = docOf(self, .selected_text) orelse return null;
    const sel = d.doc.selection();
    return objc.stringFromSlice(d.doc.text()[sel.start..sel.end]);
}

fn visibleCharacterRange(self: id, _: objc.SEL) callconv(.c) ic.Utf16Range {
    const d = docOf(self, .visible_character_range) orelse return .{ .location = 0, .length = 0 };
    // Nothing scrolls, so every line is visible: all of it.
    return .{ .location = 0, .length = utf16Len(d.doc.text()) };
}

/// The field's line table, current, when the window's text target edits this
/// node's document -- the one place lines are known. Null for text nothing has
/// laid out, which then reads as one line.
fn linesOf(w: *Window, doc: *const ui.Document) ?*const ui.text_layout.Wrapped {
    const tt = w.textGeometry() orelse return null;
    if (tt.doc != doc) return null;
    const lines = tt.options.lines orelse return null;
    return if (lines.lines.len == 0) null else lines;
}

/// The line the caret is drawn on, which is the line VoiceOver reads when the
/// user asks "what line am I on": after a trailing space that wrapped, that
/// is the next line, as it is on screen.
fn insertionPointLine(self: id, _: objc.SEL) callconv(.c) objc.NSInteger {
    const d = docOf(self, .insertion_point_line) orelse return 0;
    const lines = linesOf(d.w, d.doc) orelse return 0;
    return @intCast(lines.lineOf(d.doc.focus));
}

fn stringForRange(self: id, _: objc.SEL, range: ic.Utf16Range) callconv(.c) ?id {
    const d = docOf(self, .string_for_range) orelse return null;
    const got = ic.substring(d.doc, range) orelse return null;
    return objc.stringFromSlice(got.text);
}

fn frameForRange(self: id, _: objc.SEL, range: ic.Utf16Range) callconv(.c) objc.CGRect {
    const r = resolve(self, .frame_for_range) orelse return zero_rect;
    const d = r.n.doc orelse return zero_rect;
    // The input method's geometry callback answers the same question for the
    // same document, so it is asked here too: one function says where a byte
    // range is drawn, for both clients (§7).
    if (r.w.textGeometry()) |tt| if (tt.doc == d) if (tt.rect) |f| {
        return r.w.layoutRectToScreen(f(tt.ctx, ic.toBytes(d.text(), range)));
    };
    const b = r.t.tree.bounds(r.n.id, r.t.layout) orelse return zero_rect;
    return r.w.layoutRectToScreen(b);
}

/// The line that owns the *character* at a UTF-16 index: a trailing space is
/// on the line it ends. VoiceOver reads a line by asking this for the caret's
/// index and then `rangeForLine` for the answer.
fn lineForIndex(self: id, _: objc.SEL, index: objc.NSInteger) callconv(.c) objc.NSInteger {
    const d = docOf(self, .line_for_index) orelse return 0;
    const lines = linesOf(d.w, d.doc) orelse return 0;
    const s = d.doc.text();
    const b = ui.offsets.utf16ToByte(s, @intCast(@max(0, index)));
    return @intCast(lines.lineOwning(b));
}

/// A line's characters, trailing spaces included, in UTF-16. Past the last
/// line, not found: VoiceOver walks lines until it is told there are no more.
fn rangeForLine(self: id, _: objc.SEL, line: objc.NSInteger) callconv(.c) ic.Utf16Range {
    const d = docOf(self, .range_for_line) orelse return .{ .location = 0, .length = 0 };
    const s = d.doc.text();
    const lines = linesOf(d.w, d.doc) orelse {
        if (line != 0) return .{ .location = ic.not_found, .length = 0 };
        return .{ .location = 0, .length = utf16Len(s) };
    };
    if (line < 0 or line >= lines.lines.len) return .{ .location = ic.not_found, .length = 0 };
    const span = lines.lineSpan(@intCast(line), s.len);
    return ic.fromBytes(s, .{ .start = span.start, .end = span.end });
}

/// VoiceOver moving the caret: the one write this tree accepts. It goes to the
/// document the window's text target edits -- the accessibility tree holds a
/// read-only view of it -- and through the same refusal as every other caret
/// move: not during a composition.
fn setSelectedTextRange(self: id, _: objc.SEL, range: ic.Utf16Range) callconv(.c) void {
    const r = resolve(self, .set_selected_text_range) orelse return;
    const d = r.n.doc orelse return;
    const tt = r.w.text orelse return;
    if (tt.doc != d or !tt.doc.canEditNow()) return;
    const b = ic.toBytes(tt.doc.text(), range);
    tt.doc.setSelection(b.start, b.end) catch return;
    r.w.goal_x = null;
    r.w.text_changed = true;
}

fn performPress(self: id, _: objc.SEL) callconv(.c) objc.BOOL {
    const r = resolve(self, .perform_press) orelse return objc.NO;
    if (r.n.role != .button) return objc.NO;
    r.w.access_presses.push(r.n.id);
    return objc.YES;
}

/// Buttons pressed through accessibility -- VoiceOver's VO-Space -- for the
/// application to act on, like `Window.keys`. Fixed size for the same reason:
/// it is filled from inside an AppKit callback with nowhere to report an
/// allocation failure, so it counts what it drops.
pub const Presses = struct {
    ids: [16]NodeId = undefined,
    len: usize = 0,
    dropped: u32 = 0,

    pub fn push(self: *Presses, n: NodeId) void {
        if (self.len == self.ids.len) {
            self.dropped += 1;
            return;
        }
        self.ids[self.len] = n;
        self.len += 1;
    }

    pub fn pop(self: *Presses) ?NodeId {
        if (self.len == 0) return null;
        const n = self.ids[0];
        std.mem.copyForwards(NodeId, self.ids[0 .. self.len - 1], self.ids[1..self.len]);
        self.len -= 1;
        return n;
    }
};
