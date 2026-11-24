//! What a widget tells assistive technology about itself.
//!
//! This is `docs/text-and-accessibility.md` §4 and §5 in core, linking
//! nothing: no DBus, no AT-SPI, no UI Automation. The adapter that speaks a
//! protocol lives in `src/platform/`, and everything it has to get right about
//! *meaning* -- roles, states, and above all offsets -- is decided and tested
//! here, where the tests need no screen reader running.
//!
//! **The finding spike C exists to record, and it is a trap rather than a
//! difficulty:**
//!
//!     AT-SPI text offsets are in CHARACTERS.
//!     zwp_text_input_v3 offsets are in BYTES.
//!
//! The same text field speaks bytes to the input method and characters to the
//! screen reader. `Document` is byte-indexed throughout, deliberately, because
//! that is what the input method needs -- so every offset crossing into
//! accessibility has to be converted. Getting it backwards does not crash and
//! is invisible in ASCII: the screen reader simply reads the wrong characters.
//!
//! `tiếng việt` is 14 bytes and 10 characters, which is why that string is in
//! the tests. Spike C verified the conversion live against Orca, and the
//! numbers it captured are asserted below rather than described.
//!
//! The role and state numbers are from
//! `/usr/include/at-spi-2.0/atspi/atspi-constants.h`, not from memory. They
//! are not obvious -- `entry` is 79 and `frame` is 23 -- and a wrong one is a
//! widget a screen reader describes as the wrong kind of thing.

const std = @import("std");

const access = @import("access.zig");
const document = @import("document.zig");
const offsets = @import("offsets.zig");
const geometry = @import("geometry.zig");

const Document = document.Document;
const Edit = document.Edit;
const Rect = geometry.Rect;

/// What kind of thing a widget is.
///
/// The values are AT-SPI's. A second adapter maps this enum onto its own
/// vocabulary -- UI Automation calls an entry an `Edit` control type -- which
/// is the reason this is an enum with a conversion rather than a bare number.
/// Only the roles something in this toolkit can currently be are listed;
/// AT-SPI has 132.
pub const Role = enum(u32) {
    unknown = 67,
    /// Space with no meaning. What most of a laid-out tree is, and what should
    /// therefore never reach a screen reader.
    filler = 20,
    frame = 23,
    label = 29,
    list = 31,
    list_item = 32,
    panel = 39,
    button = 43,
    separator = 50,
    /// A multi-line text view. A single-line field is `entry`.
    text = 61,
    window = 69,
    application = 75,
    entry = 79,
    section = 85,
    /// Text that is not a label for anything else.
    static = 116,

    /// What `Accessible.GetRoleName` returns: AT-SPI's own lowercase spelling,
    /// which is not derivable from the enum name -- `button` is "push button".
    pub fn atspiName(self: Role) [:0]const u8 {
        return switch (self) {
            .unknown => "unknown",
            .filler => "filler",
            .frame => "frame",
            .label => "label",
            .list => "list",
            .list_item => "list item",
            .panel => "panel",
            .button => "push button",
            .separator => "separator",
            .text => "text",
            .window => "window",
            .application => "application",
            .entry => "entry",
            .section => "section",
            .static => "static",
        };
    }
};

/// A bit position in AT-SPI's state set. The numbers are the header's.
pub const State = enum(u6) {
    active = 1,
    editable = 7,
    enabled = 8,
    focusable = 11,
    focused = 12,
    multi_line = 17,
    selectable = 22,
    sensitive = 24,
    showing = 25,
    single_line = 26,
    visible = 30,
    read_only = 43,
};

/// AT-SPI sends the state set as two 32-bit words, low first. Kept as one u64
/// here because that is what it is.
pub const StateSet = struct {
    bits: u64 = 0,

    pub fn of(list: []const State) StateSet {
        var s: StateSet = .{};
        for (list) |st| s = s.with(st);
        return s;
    }

    pub fn with(self: StateSet, st: State) StateSet {
        return .{ .bits = self.bits | (@as(u64, 1) << @backingInt(st)) };
    }

    pub fn without(self: StateSet, st: State) StateSet {
        return .{ .bits = self.bits & ~(@as(u64, 1) << @backingInt(st)) };
    }

    pub fn set(self: StateSet, st: State, on: bool) StateSet {
        return if (on) self.with(st) else self.without(st);
    }

    pub fn has(self: StateSet, st: State) bool {
        return self.bits & (@as(u64, 1) << @backingInt(st)) != 0;
    }

    pub fn low(self: StateSet) u32 {
        return @truncate(self.bits);
    }

    pub fn high(self: StateSet) u32 {
        return @truncate(self.bits >> 32);
    }
};

/// What `access.Role` means to AT-SPI.
///
/// The internal tree's roles are deliberately few, because the platforms each
/// have dozens and they do not line up; this is the Linux half of that
/// mapping and the only place in this project that knows AT-SPI's numbers.
///
/// `window` becomes `frame` and not `window`: AT-SPI's `window` is a top-level
/// with no title bar or border, which is a popup, and `frame` is the ordinary
/// application window.
pub fn roleOf(r: access.Role) Role {
    return switch (r) {
        .window => .frame,
        .group => .panel,
        .static_text => .label,
        .text_field => .entry,
        .button => .button,
    };
}

/// What `access.State` means to AT-SPI, plus the states every live node has.
///
/// `enabled` and `sensitive` are separate bits that AT-SPI expects to move
/// together for an ordinary widget, and `showing` and `visible` likewise --
/// which is why they are set here rather than asked of each caller, who would
/// have to know that to get a widget a screen reader will read at all.
pub fn statesOf(node: *const access.Node, focused: bool) StateSet {
    var s = StateSet.of(&.{ .showing, .visible });
    if (!node.state.disabled) s = s.with(.enabled).with(.sensitive);
    if (node.state.focusable) s = s.with(.focusable);
    if (node.state.editable) s = s.with(.editable);
    if (node.role == .text_field) s = s.with(.single_line);
    if (node.role == .button) s = s.with(.focusable);
    return s.set(.focused, focused);
}

// ----------------------------------------------------------------- text, in
// ----------------------------------------------------------------- characters
//
// Every function below takes or returns CHARACTERS. That is the discipline
// spike C concluded is the only thing that makes this survivable: exactly two
// places convert, and no offset changes units anywhere else.

/// `Text.CharacterCount`.
pub fn characterCount(s: []const u8) usize {
    return offsets.byteToChar(s, s.len);
}

/// `Text.GetText(start, end)`, with both offsets in characters, clamped.
///
/// Returns a slice of `s`, so nothing is copied and the caller owns no memory.
pub fn getText(s: []const u8, start: usize, end: usize) []const u8 {
    const n = characterCount(s);
    const a = @min(start, n);
    const b = @min(@max(end, a), n);
    return s[offsets.charToByte(s, a)..offsets.charToByte(s, b)];
}

/// `Text.CaretOffset`, in characters.
pub fn caretOffset(doc: *const Document) usize {
    return offsets.byteToChar(doc.text(), doc.focus);
}

/// `Text.GetSelection`, in characters.
pub fn selection(doc: *const Document) struct { start: usize, end: usize } {
    const sel = doc.selection();
    const s = doc.text();
    return .{
        .start = offsets.byteToChar(s, sel.start),
        .end = offsets.byteToChar(s, sel.end),
    };
}

/// One `object:text-changed` signal.
pub const TextChange = struct {
    pub const Kind = enum { insert, delete };

    kind: Kind,
    /// `detail1`. **Characters.**
    offset: usize,
    /// `detail2`. **Characters.**
    length: usize,
    /// The `any_data` variant: the text inserted or removed. Borrowed from
    /// whichever string it came out of.
    text: []const u8,
};

/// The signals an edit has to produce.
///
/// Zero, one or two: a replacement is a delete followed by an insert, in that
/// order, because that is the order a screen reader can follow -- an insert
/// first would describe text at offsets the delete then invalidates.
///
/// `before` is the text as it was. The adapter has to keep a copy, because
/// `object:text-changed:delete` carries the removed text and after the edit it
/// is gone. That copy is not overhead invented here: an adapter needs to know
/// what it last told the client anyway.
pub fn changesFor(
    edit: Edit,
    before: []const u8,
    after: []const u8,
    out: *[2]TextChange,
) []TextChange {
    var n: usize = 0;
    const removed = edit.removedChars();
    if (removed.len > 0) {
        out[n] = .{
            .kind = .delete,
            .offset = removed.start,
            .length = removed.len,
            .text = before[edit.bytes.start..edit.bytes.old_end],
        };
        n += 1;
    }
    const inserted = edit.insertedChars();
    if (inserted.len > 0) {
        out[n] = .{
            .kind = .insert,
            .offset = inserted.start,
            .length = inserted.len,
            .text = after[edit.bytes.start..edit.bytes.new_end],
        };
        n += 1;
    }
    return out[0..n];
}

/// The changes between two versions of a string, when no `Edit` is available.
///
/// An edit made by an input method is applied inside the platform layer and
/// the application never sees an `Edit` for it, so the adapter has to recover
/// one. The mirror it keeps for deletions is exactly what that needs: compare
/// what was last reported against what is there now.
///
/// It is a prefix/suffix comparison and not a real diff, which is right for
/// this: a text field's edits are contiguous, and a smallest-edit-script
/// algorithm would be slower and would report changes a screen reader cannot
/// use. Where an `Edit` is available it is exact and should be preferred --
/// this cannot tell `abc` -> `abcabc` inserted at the front from the same
/// inserted at the back, and the `Edit` can.
pub fn changesBetween(
    before: []const u8,
    after: []const u8,
    out: *[2]TextChange,
) []TextChange {
    // The common prefix, snapped back to a character boundary so that two
    // strings differing inside a multi-byte character are not reported as
    // sharing part of it.
    var p: usize = 0;
    while (p < before.len and p < after.len and before[p] == after[p]) p += 1;
    p = @min(offsets.alignToChar(before, p), offsets.alignToChar(after, p));

    // The common suffix, not allowed to overlap the prefix.
    var s_len: usize = 0;
    while (s_len < before.len - p and s_len < after.len - p and
        before[before.len - 1 - s_len] == after[after.len - 1 - s_len]) s_len += 1;
    var b_end = before.len - s_len;
    var a_end = after.len - s_len;
    b_end = @max(p, offsets.alignForward(before, b_end));
    a_end = @max(p, offsets.alignForward(after, a_end));

    const at = offsets.byteToChar(before, p);
    var n: usize = 0;
    if (b_end > p) {
        out[n] = .{
            .kind = .delete,
            .offset = at,
            .length = offsets.byteToChar(before, b_end) - at,
            .text = before[p..b_end],
        };
        n += 1;
    }
    if (a_end > p) {
        out[n] = .{
            .kind = .insert,
            .offset = at,
            .length = offsets.byteToChar(after, a_end) - offsets.byteToChar(after, p),
            .text = after[p..a_end],
        };
        n += 1;
    }
    return out[0..n];
}

/// The text an adapter last reported, so a deletion can say what was deleted.
pub const Mirror = struct {
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Mirror, gpa: std.mem.Allocator) void {
        self.buf.deinit(gpa);
    }

    pub fn text(self: *const Mirror) []const u8 {
        return self.buf.items;
    }

    pub fn sync(self: *Mirror, gpa: std.mem.Allocator, s: []const u8) !void {
        self.buf.clearRetainingCapacity();
        try self.buf.appendSlice(gpa, s);
    }
};

/// Whether to emit anything at all.
///
/// With no assistive technology running, `GetRegisteredEvents` returns an
/// empty array and every signal goes to nobody. A toolkit that emits
/// unconditionally puts traffic on the accessibility bus for the great
/// majority of users who run no screen reader, which is why this is a question
/// the adapter asks rather than an assumption it makes. Spike C reported the
/// count and did not act on it; this does.
pub fn shouldEmit(registered_listeners: u32) bool {
    return registered_listeners > 0;
}

/// The bounds a screen reader is told, in **screen** coordinates.
///
/// This is the half of §7 that Wayland did not need: `set_cursor_rectangle` is
/// surface-local, and `Component.GetExtents` is not. A Wayland client is not
/// told where its window is, so the origin here is whatever the platform layer
/// can find out -- and on Wayland that is nothing, which the adapter has to
/// say rather than quietly report surface coordinates as screen ones.
pub fn screenRect(local: Rect, origin_x: f32, origin_y: f32) Rect {
    return .{
        .x = local.x + origin_x,
        .y = local.y + origin_y,
        .w = local.w,
        .h = local.h,
    };
}

// ---------------------------------------------------------------------- tests

const testing = std.testing;

const vi = "tiếng việt";

test "the Vietnamese string separates bytes from characters" {
    // If these two were equal the rest of this file would be untestable.
    try testing.expectEqual(@as(usize, 14), vi.len);
    try testing.expectEqual(@as(usize, 10), characterCount(vi));
}

test "GetText takes characters, as spike C verified over DBus" {
    // Transcribed from the live session: these four answers came back from the
    // running registry and are the reason the conversion is believed.
    try testing.expectEqualStrings(vi, getText(vi, 0, 10));
    // 5 characters is 7 bytes. Byte offsets would have cut `tiế` in half.
    try testing.expectEqualStrings("tiếng", getText(vi, 0, 5));
    // Offsets 6-10 land past two three-byte characters.
    try testing.expectEqualStrings("việt", getText(vi, 6, 10));
}

test "GetText clamps rather than failing" {
    try testing.expectEqualStrings(vi, getText(vi, 0, 999));
    try testing.expectEqualStrings("", getText(vi, 10, 10));
    try testing.expectEqualStrings("", getText(vi, 999, 999));
    // Backwards is empty, not a slice that runs the wrong way.
    try testing.expectEqualStrings("", getText(vi, 5, 2));
}

test "the state set is bit-exact against a value read off the bus" {
    // 1191188864 is what `GetState` returned for the spike's entry, checked
    // arithmetically at the time rather than eyeballed. It is here because a
    // wrong bit is a state a screen reader silently never mentions.
    const entry = StateSet.of(&.{
        .editable, .enabled, .focusable, .focused, .sensitive, .showing, .single_line, .visible,
    });
    try testing.expectEqual(@as(u64, 1191188864), entry.bits);
    try testing.expect(entry.has(.editable));
    try testing.expect(!entry.has(.read_only));

    // And the split AT-SPI actually sends: two 32-bit words, low first.
    try testing.expectEqual(@as(u32, 1191188864), entry.low());
    try testing.expectEqual(@as(u32, 0), entry.high());

    // A state above bit 31 lands in the high word, which the single-u64 shape
    // is what makes impossible to get wrong.
    const ro = StateSet.of(&.{.read_only});
    try testing.expectEqual(@as(u32, 0), ro.low());
    try testing.expectEqual(@as(u32, 1 << 11), ro.high());
}

test "the internal roles map onto AT-SPI's" {
    try testing.expectEqual(Role.entry, roleOf(.text_field));
    try testing.expectEqual(Role.panel, roleOf(.group));
    try testing.expectEqual(Role.label, roleOf(.static_text));
    try testing.expectEqual(Role.button, roleOf(.button));
    // AT-SPI's `window` is a top-level with no title bar -- a popup. An
    // application's window is a `frame`.
    try testing.expectEqual(Role.frame, roleOf(.window));
}

test "a text field's states are the ones read back off the bus" {
    var layout = try @import("tree.zig").Tree.init(testing.allocator);
    defer layout.deinit();
    var at = try access.Tree.init(testing.allocator, "demo");
    defer at.deinit();

    const el = try layout.appendChild(layout.root(), .{});
    const id = try at.add(&layout, el, .{
        .role = .text_field,
        .name = "field",
        .state = .{ .focusable = true, .editable = true },
    });
    at.setFocus(id);

    // 1191188864, the same number the bus returned for spike C's entry and
    // the same one the test above builds by hand -- now reached from the
    // internal tree instead.
    const st = statesOf(at.get(id).?, at.focus == id);
    try testing.expectEqual(@as(u64, 1191188864), st.bits);

    // Unfocused, the FOCUSED bit and nothing else goes.
    const un = statesOf(at.get(id).?, false);
    try testing.expectEqual(@as(u64, 1191188864 - (1 << 12)), un.bits);
}

test "a disabled node is neither enabled nor sensitive" {
    var layout = try @import("tree.zig").Tree.init(testing.allocator);
    defer layout.deinit();
    var at = try access.Tree.init(testing.allocator, "demo");
    defer at.deinit();

    const el = try layout.appendChild(layout.root(), .{});
    const id = try at.add(&layout, el, .{ .role = .button, .name = "x", .state = .{ .disabled = true } });
    const st = statesOf(at.get(id).?, false);
    try testing.expect(!st.has(.enabled));
    try testing.expect(!st.has(.sensitive));
    // Still visible: a greyed-out button is there, and a screen reader that
    // was never told about it could not explain why nothing happens.
    try testing.expect(st.has(.visible));
}

test "roles carry AT-SPI's numbers and AT-SPI's names" {
    try testing.expectEqual(@as(u32, 79), @backingInt(Role.entry));
    try testing.expectEqual(@as(u32, 23), @backingInt(Role.frame));
    try testing.expectEqual(@as(u32, 75), @backingInt(Role.application));
    // The name is not the enum name, and this is the one that catches it.
    try testing.expectEqualStrings("push button", Role.button.atspiName());
    try testing.expectEqualStrings("list item", Role.list_item.atspiName());
}

test "an edit becomes the events spike C captured with dbus-monitor" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    var mirror: Mirror = .{};
    defer mirror.deinit(testing.allocator);
    var out: [2]TextChange = undefined;

    // insert "tiếng " at 0 -- 8 bytes, 6 characters. The emitted length is 6.
    {
        const before = mirror.text();
        const e = try doc.insert(.application, "tiếng ");
        const ch = changesFor(e, before, doc.text(), &out);
        try testing.expectEqual(@as(usize, 1), ch.len);
        try testing.expectEqual(TextChange.Kind.insert, ch[0].kind);
        try testing.expectEqual(@as(usize, 0), ch[0].offset);
        try testing.expectEqual(@as(usize, 6), ch[0].length);
        try testing.expectEqualStrings("tiếng ", ch[0].text);
        try mirror.sync(testing.allocator, doc.text());
    }

    // insert "việt" at character 6, whose byte offset is 8. The emitted
    // offset is 6. This is the whole argument in one number.
    {
        const before = mirror.text();
        const e = try doc.insert(.application, "việt");
        const ch = changesFor(e, before, doc.text(), &out);
        try testing.expectEqual(@as(usize, 6), ch[0].offset);
        try testing.expectEqual(@as(usize, 4), ch[0].length);
        try testing.expectEqualStrings("việt", ch[0].text);
        try testing.expectEqual(@as(usize, 8), e.bytes.start);
        try mirror.sync(testing.allocator, doc.text());
    }

    // backspace: delete at character 9, length 1.
    {
        const before = mirror.text();
        const e = try doc.deleteBackwards(.application);
        const ch = changesFor(e, before, doc.text(), &out);
        try testing.expectEqual(@as(usize, 1), ch.len);
        try testing.expectEqual(TextChange.Kind.delete, ch[0].kind);
        try testing.expectEqual(@as(usize, 9), ch[0].offset);
        try testing.expectEqual(@as(usize, 1), ch[0].length);
        try testing.expectEqualStrings("t", ch[0].text);
        try mirror.sync(testing.allocator, doc.text());
    }

    try testing.expectEqualStrings("tiếng việ", doc.text());
    try testing.expectEqual(@as(usize, 9), caretOffset(&doc));
}

test "a replacement is a delete and then an insert" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    var mirror: Mirror = .{};
    defer mirror.deinit(testing.allocator);
    _ = try doc.insert(.application, vi);
    try mirror.sync(testing.allocator, doc.text());

    // Select `tiếng` -- five characters, seven bytes -- and type over it.
    try doc.setSelection(0, offsets.charToByte(doc.text(), 5));
    var out: [2]TextChange = undefined;
    const before = mirror.text();
    const e = try doc.insert(.application, "chữ");
    const ch = changesFor(e, before, doc.text(), &out);

    try testing.expectEqual(@as(usize, 2), ch.len);
    try testing.expectEqual(TextChange.Kind.delete, ch[0].kind);
    try testing.expectEqual(@as(usize, 0), ch[0].offset);
    try testing.expectEqual(@as(usize, 5), ch[0].length);
    try testing.expectEqualStrings("tiếng", ch[0].text);

    try testing.expectEqual(TextChange.Kind.insert, ch[1].kind);
    try testing.expectEqual(@as(usize, 0), ch[1].offset);
    try testing.expectEqual(@as(usize, 3), ch[1].length);
    try testing.expectEqualStrings("chữ", ch[1].text);

    try testing.expectEqualStrings("chữ việt", doc.text());
}

test "a caret move produces no text change" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    var mirror: Mirror = .{};
    defer mirror.deinit(testing.allocator);
    _ = try doc.insert(.application, vi);
    try mirror.sync(testing.allocator, doc.text());

    try doc.setCaret(offsets.charToByte(doc.text(), 6));
    try testing.expectEqual(@as(usize, 6), caretOffset(&doc));
    // Character 6 is byte 8, so a caret event sent in bytes would put a
    // screen reader two characters off. Silently.
    try testing.expectEqual(@as(usize, 8), doc.focus);
}

test "a selection is reported in characters too" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    _ = try doc.insert(.application, vi);
    try doc.setSelection(offsets.charToByte(doc.text(), 6), offsets.charToByte(doc.text(), 10));

    const sel = selection(&doc);
    try testing.expectEqual(@as(usize, 6), sel.start);
    try testing.expectEqual(@as(usize, 10), sel.end);
    try testing.expectEqualStrings("việt", getText(doc.text(), sel.start, sel.end));
}

test "a change can be recovered by comparison when no Edit exists" {
    var out: [2]TextChange = undefined;

    // An insert in the middle, with multi-byte text on both sides so that a
    // byte-aligned comparison would report the wrong offsets.
    {
        const ch = changesBetween("tiếng việt", "tiếng Việt việt", &out);
        try testing.expectEqual(@as(usize, 1), ch.len);
        try testing.expectEqual(TextChange.Kind.insert, ch[0].kind);
        try testing.expectEqual(@as(usize, 6), ch[0].offset);
        try testing.expectEqualStrings("Việt ", ch[0].text);
        try testing.expectEqual(@as(usize, 5), ch[0].length);
    }
    // A pure deletion.
    {
        const ch = changesBetween("tiếng việt", "tiếng", &out);
        try testing.expectEqual(@as(usize, 1), ch.len);
        try testing.expectEqual(TextChange.Kind.delete, ch[0].kind);
        try testing.expectEqual(@as(usize, 5), ch[0].offset);
        try testing.expectEqualStrings(" việt", ch[0].text);
    }
    // A replacement: delete then insert, in that order.
    {
        const ch = changesBetween("tiếng việt", "tiếng Việt", &out);
        try testing.expectEqual(@as(usize, 2), ch.len);
        try testing.expectEqual(TextChange.Kind.delete, ch[0].kind);
        try testing.expectEqual(TextChange.Kind.insert, ch[1].kind);
        try testing.expectEqual(ch[0].offset, ch[1].offset);
    }
    // No change at all.
    try testing.expectEqual(@as(usize, 0), changesBetween(vi, vi, &out).len);
    // From nothing, and to nothing.
    try testing.expectEqual(TextChange.Kind.insert, changesBetween("", vi, &out)[0].kind);
    try testing.expectEqual(TextChange.Kind.delete, changesBetween(vi, "", &out)[0].kind);
}

test "a comparison never splits a character" {
    var out: [2]TextChange = undefined;
    // `ế` and `ệ` share their first two bytes, so a byte-wise prefix would
    // stop in the middle of a character and report text that is not UTF-8.
    const ch = changesBetween("tiếng", "tiệng", &out);
    for (ch) |x| try testing.expect(std.unicode.utf8ValidateSlice(x.text));
    try testing.expectEqual(@as(usize, 2), ch.len);
    try testing.expectEqualStrings("ế", ch[0].text);
    try testing.expectEqualStrings("ệ", ch[1].text);
    try testing.expectEqual(@as(usize, 2), ch[0].offset);
}

test "nothing is emitted when nothing is listening" {
    // Outside a test, this is the common case: `GetRegisteredEvents` comes
    // back empty unless a screen reader is running.
    try testing.expect(!shouldEmit(0));
    try testing.expect(shouldEmit(1));
}

test "an empty edit produces no events" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    _ = try doc.insert(.application, vi);

    var out: [2]TextChange = undefined;
    // Backspace at the start of the document: nothing to delete.
    try doc.setCaret(0);
    const e = try doc.deleteBackwards(.application);
    const ch = changesFor(e, doc.text(), doc.text(), &out);
    try testing.expectEqual(@as(usize, 0), ch.len);
}
