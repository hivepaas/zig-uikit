//! The text a field holds: bytes, a selection, and a composition in progress.
//!
//! This is `docs/text-and-accessibility.md` §1, §2 and §6 made executable. It
//! links nothing, needs no font and no window, and every behaviour in it was
//! specified by a spike that ran against a real input method or a real screen
//! reader -- which is the only reason to believe any of it.
//!
//! **The shape is Windows-first, deliberately.** Wayland's `zwp_text_input_v3`
//! keeps a preedit as a separate string that never enters the document;
//! Windows' TSF has the input processor write *into* the document and mark the
//! range provisional. The Windows shape can represent Wayland -- leave the
//! range unused -- and the Wayland shape cannot represent Windows at all. Spike
//! B designed Wayland-first and produced a model spike E could not use, so the
//! provisional range is here and the preedit sits beside it.
//!
//! **Offsets are bytes**, because `text-input-v3` counts bytes and has no
//! conversion available. Everything leaving converts through `offsets.zig`, and
//! an edit reports its extent in all three units at once -- computed here,
//! where both the old text and the new one exist, which is the only place it
//! can be done correctly.

const std = @import("std");
const Allocator = std.mem.Allocator;

const offsets = @import("offsets.zig");

pub const Error = error{
    OutOfMemory,
    /// An application-initiated edit arrived while an input processor held a
    /// lock, or while a composition was active. See `canEditNow`.
    Locked,
    /// A range that is not a character boundary, or runs backwards, or past
    /// the end.
    BadRange,
};

/// A half-open byte range.
pub const Range = struct {
    start: usize = 0,
    end: usize = 0,

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }

    pub fn isEmpty(self: Range) bool {
        return self.end == self.start;
    }

    pub fn ordered(a: usize, b: usize) Range {
        return .{ .start = @min(a, b), .end = @max(a, b) };
    }
};

/// Who asked for an edit.
///
/// Not bookkeeping: §6 turns on this distinction twice. An
/// application-initiated edit is refused while a processor holds a lock, and
/// only an application-initiated edit notifies the input-method and
/// accessibility sinks -- telling a processor about its own edit is how
/// notification storms start.
pub const Origin = enum {
    application,
    input_method,
};

/// What a text store lock permits, as TSF defines it.
///
/// The document only needs to know whether one is held and what it allows. The
/// *queue* -- a request arriving while a lock is held must be deferred and
/// granted after the current one unwinds, returning `TS_S_ASYNC`, and the drain
/// has to be a loop because a request can be queued from inside a deferred
/// grant -- belongs to the TSF adapter, which is the only thing that has a
/// `RequestLock` to answer. Wayland has no equivalent at all.
pub const Lock = enum {
    none,
    read,
    read_write,
};

/// An edit's extent, in one unit. `old_end` indexes the text before the edit
/// and `new_end` the text after it.
pub const Extent = struct {
    start: usize,
    old_end: usize,
    new_end: usize,
};

/// What changed, in every unit a protocol might ask for.
///
/// All three are computed at the moment of the edit, because `old_end` can only
/// be converted against the text as it was and `new_end` against the text as it
/// is. A caller that kept only bytes and converted later would be converting
/// `old_end` against the wrong string -- a bug that does not crash and shows up
/// as a screen reader reading the wrong span.
pub const Edit = struct {
    /// TSF's `acpStart`, `acpOldEnd`, `acpNewEnd` are this in `utf16`.
    bytes: Extent,
    /// AT-SPI counts codepoints.
    chars: Extent,
    utf16: Extent,

    /// AT-SPI's `(start, length)` for the text that was inserted.
    pub fn insertedChars(self: Edit) struct { start: usize, len: usize } {
        return .{ .start = self.chars.start, .len = self.chars.new_end - self.chars.start };
    }

    /// AT-SPI's `(start, length)` for the text that was removed.
    pub fn removedChars(self: Edit) struct { start: usize, len: usize } {
        return .{ .start = self.chars.start, .len = self.chars.old_end - self.chars.start };
    }

    pub fn isEmpty(self: Edit) bool {
        return self.bytes.start == self.bytes.old_end and
            self.bytes.start == self.bytes.new_end;
    }
};

pub const Document = struct {
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,

    /// The selection, as the place it started and the place it is being
    /// dragged to -- not as an ordered pair. Shift+Left from a selection made
    /// left to right shrinks it; from one made right to left it grows it, and
    /// an ordered pair cannot tell those apart.
    anchor: usize = 0,
    focus: usize = 0,

    /// The provisional range, when an input processor is writing into the
    /// document: the TSF shape. Null on Wayland, always.
    composing: ?Range = null,

    /// The preedit that never enters the document: the Wayland shape. Empty on
    /// Windows, always. Displayed at the caret by `displayText`.
    preedit: std.ArrayList(u8) = .empty,

    /// True between `OnStartComposition` and `OnEndComposition`, or between the
    /// first non-empty preedit and the commit. Separate from `composing` being
    /// non-null because Wayland is composing with no range.
    composition_active: bool = false,

    lock: Lock = .none,

    pub fn init(gpa: Allocator) Document {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Document) void {
        self.buf.deinit(self.gpa);
        self.preedit.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn text(self: *const Document) []const u8 {
        return self.buf.items;
    }

    pub fn len(self: *const Document) usize {
        return self.buf.items.len;
    }

    /// The selection with its ends in order.
    pub fn selection(self: *const Document) Range {
        return Range.ordered(self.anchor, self.focus);
    }

    /// Whether the application may edit right now.
    ///
    /// False while a processor holds a lock -- editing then changes the
    /// document underneath a reader that believes it has exclusive access --
    /// and false while a composition is active, because the processor owns the
    /// provisional text until it commits or abandons it.
    pub fn canEditNow(self: *const Document) bool {
        return self.lock == .none and !self.composition_active;
    }

    // ----------------------------------------------------------------- edits

    /// Replaces `range` with `s`. The primitive every other edit is written in
    /// terms of, and TSF's `SetText` directly.
    pub fn replaceRange(
        self: *Document,
        origin: Origin,
        range: Range,
        s: []const u8,
    ) Error!Edit {
        if (origin == .application and !self.canEditNow()) return Error.Locked;
        if (origin == .input_method and self.lock == .read) return Error.Locked;
        try self.validate(range);

        // Converted before the buffer changes: `old_end` has no meaning
        // against the new text.
        const old = self.buf.items;
        const start_char = offsets.byteToChar(old, range.start);
        const start_u16 = offsets.byteToUtf16(old, range.start);
        const old_end_char = offsets.byteToChar(old, range.end);
        const old_end_u16 = offsets.byteToUtf16(old, range.end);

        try self.buf.replaceRange(self.gpa, range.start, range.len(), s);

        const new_end = range.start + s.len;
        const inserted_chars = offsets.byteToChar(s, s.len);
        const inserted_u16 = offsets.byteToUtf16(s, s.len);

        self.shift(range, new_end);

        return .{
            .bytes = .{ .start = range.start, .old_end = range.end, .new_end = new_end },
            .chars = .{
                .start = start_char,
                .old_end = old_end_char,
                .new_end = start_char + inserted_chars,
            },
            .utf16 = .{
                .start = start_u16,
                .old_end = old_end_u16,
                .new_end = start_u16 + inserted_u16,
            },
        };
    }

    /// Replaces the selection with `s` and puts the caret after it: a
    /// keystroke, or `commit_string`.
    pub fn insert(self: *Document, origin: Origin, s: []const u8) Error!Edit {
        const e = try self.replaceRange(origin, self.selection(), s);
        // Collapsed explicitly. The generic offset shift leaves the selection
        // spanning what was just inserted, which is right for an edit made
        // somewhere else in the document and wrong for a keystroke: typing
        // over a selection leaves a caret, not a selection of what you typed.
        self.anchor = e.bytes.new_end;
        self.focus = e.bytes.new_end;
        return e;
    }

    /// Deletes the selection, or the character before the caret when the
    /// selection is empty. Backspace.
    pub fn deleteBackwards(self: *Document, origin: Origin) Error!Edit {
        const sel = self.selection();
        if (!sel.isEmpty()) return self.replaceRange(origin, sel, "");
        if (sel.start == 0) return emptyEdit(self, 0);
        // A whole character, not a byte. Deleting one byte of `ế` leaves the
        // buffer holding something that is not UTF-8 at all.
        const before = offsets.prevChar(self.buf.items, sel.start);
        return self.replaceRange(origin, .{ .start = before, .end = sel.start }, "");
    }

    /// `zwp_text_input_v3`'s `delete_surrounding_text`: remove `before` bytes
    /// in front of the caret and `after` bytes behind it, then apply the
    /// commit.
    ///
    /// In bytes because that is the unit the protocol states. Both counts are
    /// aligned to character boundaries rather than trusted: a compositor is
    /// another process, and a count that splits a character would leave the
    /// buffer holding invalid UTF-8.
    ///
    /// ibus-bamboo in mode 1 never sends this, so spike B covered it with a
    /// self test and said in its own output that it proved the model and not
    /// that anything drives it. That is still true here.
    pub fn deleteSurrounding(self: *Document, origin: Origin, before: usize, after: usize) Error!Edit {
        const sel = self.selection();
        const s = self.buf.items;
        const start = offsets.alignToChar(s, sel.start -| before);
        const end_raw = @min(sel.end + after, s.len);
        const end = offsets.alignForward(s, end_raw);
        return self.replaceRange(origin, .{ .start = start, .end = end }, "");
    }

    // ----------------------------------------------------------- composition

    /// The TSF shape: the processor has written into the document, and `range`
    /// is provisional until it commits.
    pub fn setComposingRange(self: *Document, range: Range) Error!void {
        try self.validate(range);
        self.composing = range;
        self.composition_active = true;
    }

    /// The Wayland shape: text that is NOT in the document, shown at the
    /// caret. An empty string ends the preedit without committing anything.
    pub fn setPreedit(self: *Document, s: []const u8) Error!void {
        self.preedit.clearRetainingCapacity();
        try self.preedit.appendSlice(self.gpa, s);
        self.composition_active = s.len > 0;
    }

    /// `OnEndComposition`, or a Wayland `commit_string` having been applied.
    /// The text stays; it simply stops being provisional.
    pub fn endComposition(self: *Document) void {
        self.composing = null;
        self.preedit.clearRetainingCapacity();
        self.composition_active = false;
    }

    /// The string to lay out, and which part of it is provisional.
    ///
    /// One function for both platforms, which is the point of the model. On
    /// Windows the document already contains the provisional text and this
    /// returns it unchanged with the range it was given. On Wayland the preedit
    /// is spliced in at the caret and the range describes where it landed --
    /// so the renderer underlines a byte range either way and never learns
    /// which protocol it is talking to.
    ///
    /// `scratch` is used only when there is a preedit to splice; otherwise the
    /// document's own bytes are returned and nothing is copied.
    pub fn displayText(self: *const Document, scratch: *std.ArrayList(u8)) Error!struct {
        text: []const u8,
        composing: ?Range,
    } {
        if (self.preedit.items.len == 0) {
            return .{ .text = self.buf.items, .composing = self.composing };
        }
        const at = self.selection().start;
        scratch.clearRetainingCapacity();
        try scratch.appendSlice(self.gpa, self.buf.items[0..at]);
        try scratch.appendSlice(self.gpa, self.preedit.items);
        try scratch.appendSlice(self.gpa, self.buf.items[at..]);
        return .{
            .text = scratch.items,
            .composing = .{ .start = at, .end = at + self.preedit.items.len },
        };
    }

    // ------------------------------------------------------------ selection

    pub fn setSelection(self: *Document, anchor: usize, focus: usize) Error!void {
        if (anchor > self.len() or focus > self.len()) return Error.BadRange;
        if (anchor != offsets.alignToChar(self.buf.items, anchor)) return Error.BadRange;
        if (focus != offsets.alignToChar(self.buf.items, focus)) return Error.BadRange;
        self.anchor = anchor;
        self.focus = focus;
    }

    pub fn setCaret(self: *Document, at: usize) Error!void {
        return self.setSelection(at, at);
    }

    /// The selection in codepoints, which is what AT-SPI asks for.
    pub fn selectionChars(self: *const Document) Range {
        const sel = self.selection();
        return .{
            .start = offsets.byteToChar(self.buf.items, sel.start),
            .end = offsets.byteToChar(self.buf.items, sel.end),
        };
    }

    /// The selection in UTF-16 code units, which is what TSF and UIA ask for.
    pub fn selectionUtf16(self: *const Document) Range {
        const sel = self.selection();
        return .{
            .start = offsets.byteToUtf16(self.buf.items, sel.start),
            .end = offsets.byteToUtf16(self.buf.items, sel.end),
        };
    }

    // ------------------------------------------------------------- internals

    fn validate(self: *const Document, r: Range) Error!void {
        if (r.start > r.end or r.end > self.len()) return Error.BadRange;
        const s = self.buf.items;
        if (r.start != offsets.alignToChar(s, r.start)) return Error.BadRange;
        if (r.end != offsets.alignToChar(s, r.end)) return Error.BadRange;
    }

    /// Moves the selection and the composing range to account for an edit.
    fn shift(self: *Document, replaced: Range, new_end: usize) void {
        self.anchor = shiftOffset(self.anchor, replaced, new_end);
        self.focus = shiftOffset(self.focus, replaced, new_end);
        if (self.composing) |c| {
            self.composing = .{
                .start = shiftOffset(c.start, replaced, new_end),
                .end = shiftOffset(c.end, replaced, new_end),
            };
        }
    }

    fn emptyEdit(self: *const Document, at: usize) Edit {
        const s = self.buf.items;
        const ch = offsets.byteToChar(s, at);
        const u = offsets.byteToUtf16(s, at);
        return .{
            .bytes = .{ .start = at, .old_end = at, .new_end = at },
            .chars = .{ .start = ch, .old_end = ch, .new_end = ch },
            .utf16 = .{ .start = u, .old_end = u, .new_end = u },
        };
    }
};

/// Where an offset ends up after `replaced` became `replaced.start..new_end`.
///
/// An offset inside the replaced range collapses to `new_end` rather than to
/// the start. The caret after typing over a selection belongs after what was
/// typed, and this is the rule that puts it there.
fn shiftOffset(off: usize, replaced: Range, new_end: usize) usize {
    if (off <= replaced.start) return off;
    if (off >= replaced.end) return off + new_end - replaced.end;
    return new_end;
}

// ---------------------------------------------------------------------- tests
//
// The two sequences below are transcribed from the spikes' own logs. They are
// the test this file exists to pass: the same three keystrokes, `a` `w` `s`
// producing `ă`, arriving through two protocols that disagree about where
// provisional text lives.

const testing = std.testing;

test "spike B: Wayland keeps the preedit out of the document" {
    var d = Document.init(testing.allocator);
    defer d.deinit();
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);

    // preedit_string("a")
    try d.setPreedit("a");
    try testing.expectEqualStrings("", d.text());
    var shown = try d.displayText(&scratch);
    try testing.expectEqualStrings("a", shown.text);
    try testing.expectEqual(@as(usize, 0), shown.composing.?.start);
    try testing.expectEqual(@as(usize, 1), shown.composing.?.end);
    // The document is untouched, so the application may not edit it either.
    try testing.expect(!d.canEditNow());

    // preedit_string("ă")
    try d.setPreedit("ă");
    try testing.expectEqualStrings("", d.text());
    shown = try d.displayText(&scratch);
    try testing.expectEqualStrings("ă", shown.text);

    // commit_string("ă"), then the preedit is dropped.
    _ = try d.insert(.input_method, "ă");
    d.endComposition();
    try testing.expectEqualStrings("ă", d.text());
    shown = try d.displayText(&scratch);
    try testing.expectEqualStrings("ă", shown.text);
    try testing.expect(shown.composing == null);
    try testing.expect(d.canEditNow());
    // The caret is after the committed text.
    try testing.expectEqual(d.len(), d.selection().start);
}

test "spike E: TSF writes into the document and marks it provisional" {
    var d = Document.init(testing.allocator);
    defer d.deinit();
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);

    // OnStartComposition, then SetText(0..0 <- "a")
    d.lock = .read_write;
    _ = try d.replaceRange(.input_method, .{ .start = 0, .end = 0 }, "a");
    try d.setComposingRange(.{ .start = 0, .end = 1 });
    try testing.expectEqualStrings("a", d.text());

    // The text IS in the document, and `displayText` returns it unchanged with
    // the range that is provisional -- the same two values the Wayland path
    // produced by splicing.
    const shown = try d.displayText(&scratch);
    try testing.expectEqualStrings("a", shown.text);
    try testing.expectEqual(@as(usize, 1), shown.composing.?.end);
    try testing.expectEqual(@as(usize, 0), d.preedit.items.len);

    // SetText(0..1 <- "ă")
    _ = try d.replaceRange(.input_method, .{ .start = 0, .end = 1 }, "ă");
    try d.setComposingRange(.{ .start = 0, .end = "ă".len });
    try testing.expectEqualStrings("ă", d.text());

    // OnEndComposition
    d.lock = .none;
    d.endComposition();
    try testing.expectEqualStrings("ă", d.text());
    try testing.expect(d.composing == null);
    try testing.expect(d.canEditNow());
}

test "an ACP range is UTF-16 units and converting it is not optional" {
    var d = Document.init(testing.allocator);
    defer d.deinit();
    try d.buf.appendSlice(testing.allocator, "ế");

    // `ế` is three bytes and one UTF-16 unit. An input processor replacing
    // "the first character" sends acp 0..1. Treating that 1 as a byte offset
    // would split the character and leave the buffer holding invalid UTF-8;
    // the conversion is what makes it 0..3.
    const acp_end = offsets.utf16ToByte(d.text(), 1);
    try testing.expectEqual(@as(usize, 3), acp_end);
    _ = try d.replaceRange(.input_method, .{ .start = 0, .end = acp_end }, "ề");
    try testing.expectEqualStrings("ề", d.text());
    try testing.expect(std.unicode.utf8ValidateSlice(d.text()));

    // And a byte range that splits a character is refused rather than applied.
    try testing.expectError(
        Error.BadRange,
        d.replaceRange(.input_method, .{ .start = 0, .end = 1 }, "x"),
    );
}

test "an edit reports its extent in all three units" {
    var d = Document.init(testing.allocator);
    defer d.deinit();
    // 15 bytes, 11 characters, 11 UTF-16 units.
    _ = try d.insert(.application, "tiếng việt ");

    // Appending a flag: 8 bytes, 2 codepoints, 4 UTF-16 units.
    const e = try d.insert(.application, "🇻🇳");

    try testing.expectEqual(@as(usize, 15), e.bytes.start);
    try testing.expectEqual(@as(usize, 15), e.bytes.old_end);
    try testing.expectEqual(@as(usize, 23), e.bytes.new_end);

    try testing.expectEqual(@as(usize, 11), e.chars.start);
    try testing.expectEqual(@as(usize, 13), e.chars.new_end);

    try testing.expectEqual(@as(usize, 11), e.utf16.start);
    try testing.expectEqual(@as(usize, 15), e.utf16.new_end);

    // AT-SPI wants (start, length) in characters.
    const ins = e.insertedChars();
    try testing.expectEqual(@as(usize, 11), ins.start);
    try testing.expectEqual(@as(usize, 2), ins.len);

    // The three units disagree, which is the whole reason they are all here.
    try testing.expect(e.bytes.new_end != e.chars.new_end);
    try testing.expect(e.chars.new_end != e.utf16.new_end);
}

test "old_end is converted against the old text" {
    var d = Document.init(testing.allocator);
    defer d.deinit();
    _ = try d.insert(.application, "ếx");

    // Replace the three-byte `ế` with a one-byte `e`. `old_end` is 1 character
    // and 1 UTF-16 unit in the OLD text; converting it afterwards against the
    // new text would still give 1 here, so make the replacement change the
    // count: replace `ế` with nothing.
    try d.setSelection(0, 0);
    const e = try d.replaceRange(.application, .{ .start = 0, .end = 3 }, "");
    try testing.expectEqualStrings("x", d.text());
    try testing.expectEqual(@as(usize, 3), e.bytes.old_end);
    try testing.expectEqual(@as(usize, 1), e.chars.old_end);
    try testing.expectEqual(@as(usize, 0), e.chars.new_end);
    const rem = e.removedChars();
    try testing.expectEqual(@as(usize, 1), rem.len);
}

test "the lock protocol refuses the edits it is supposed to" {
    var d = Document.init(testing.allocator);
    defer d.deinit();
    _ = try d.insert(.application, "abc");

    // §6: the application must not edit while a processor holds a lock.
    d.lock = .read;
    try testing.expectError(Error.Locked, d.insert(.application, "x"));
    // Nor may the processor write under a read-only lock: TS_E_NOLOCK.
    try testing.expectError(Error.Locked, d.insert(.input_method, "x"));

    d.lock = .read_write;
    try testing.expectError(Error.Locked, d.insert(.application, "x"));
    // The processor may, which is what the lock was taken for.
    _ = try d.insert(.input_method, "x");
    try testing.expectEqualStrings("abcx", d.text());

    d.lock = .none;
    _ = try d.insert(.application, "y");
    try testing.expectEqualStrings("abcxy", d.text());
}

test "the application may not edit during a composition either" {
    var d = Document.init(testing.allocator);
    defer d.deinit();
    try d.setPreedit("a");
    try testing.expect(!d.canEditNow());
    try testing.expectError(Error.Locked, d.insert(.application, "z"));
    d.endComposition();
    _ = try d.insert(.application, "z");
    try testing.expectEqualStrings("z", d.text());
}

test "backspace deletes a character, not a byte" {
    var d = Document.init(testing.allocator);
    defer d.deinit();
    _ = try d.insert(.application, "tiế");
    try testing.expectEqual(@as(usize, 5), d.len());

    _ = try d.deleteBackwards(.application);
    try testing.expectEqualStrings("ti", d.text());
    try testing.expect(std.unicode.utf8ValidateSlice(d.text()));
    try testing.expectEqual(@as(usize, 2), d.selection().start);

    // At the start it is a no-op rather than an underflow.
    try d.setCaret(0);
    const e = try d.deleteBackwards(.application);
    try testing.expect(e.isEmpty());
    try testing.expectEqualStrings("ti", d.text());
}

test "delete_surrounding_text aligns counts it did not choose" {
    var d = Document.init(testing.allocator);
    defer d.deinit();
    _ = try d.insert(.application, "aếb");
    // Caret after the `ế`, which spans bytes 1..4.
    try d.setCaret(4);

    // The compositor asks to delete two bytes before the caret. Two bytes lands
    // inside `ế`; taking it literally would leave a lone continuation byte.
    _ = try d.deleteSurrounding(.input_method, 2, 0);
    try testing.expectEqualStrings("ab", d.text());
    try testing.expect(std.unicode.utf8ValidateSlice(d.text()));
}

test "typing over a selection leaves a caret, not a selection" {
    var d = Document.init(testing.allocator);
    defer d.deinit();
    _ = try d.insert(.application, "hello world");
    try d.setSelection(6, 11);
    _ = try d.insert(.application, "there");
    try testing.expectEqualStrings("hello there", d.text());
    try testing.expect(d.selection().isEmpty());
    try testing.expectEqual(@as(usize, 11), d.selection().start);
}

test "a selection dragged backwards keeps its direction" {
    var d = Document.init(testing.allocator);
    defer d.deinit();
    _ = try d.insert(.application, "abcdef");
    try d.setSelection(4, 2);
    // Ordered for anyone asking what is selected...
    try testing.expectEqual(@as(usize, 2), d.selection().start);
    try testing.expectEqual(@as(usize, 4), d.selection().end);
    // ...and unordered for anyone extending it, which is the case an ordered
    // pair cannot represent.
    try testing.expectEqual(@as(usize, 4), d.anchor);
    try testing.expectEqual(@as(usize, 2), d.focus);
}

test "an edit before the composing range carries it along" {
    var d = Document.init(testing.allocator);
    defer d.deinit();
    d.lock = .read_write;
    _ = try d.replaceRange(.input_method, .{ .start = 0, .end = 0 }, "xxă");
    try d.setComposingRange(.{ .start = 2, .end = 4 });

    // Something inserted in front of it must move it, or the underline ends up
    // under the wrong characters.
    _ = try d.replaceRange(.input_method, .{ .start = 0, .end = 0 }, "yy");
    try testing.expectEqual(@as(usize, 4), d.composing.?.start);
    try testing.expectEqual(@as(usize, 6), d.composing.?.end);
}

test "the selection converts into the units the protocols ask for" {
    var d = Document.init(testing.allocator);
    defer d.deinit();
    _ = try d.insert(.application, "tiếng việt 🇻🇳");
    try d.setSelection(0, d.len());

    try testing.expectEqual(@as(usize, 23), d.selection().end);
    try testing.expectEqual(@as(usize, 13), d.selectionChars().end);
    try testing.expectEqual(@as(usize, 15), d.selectionUtf16().end);
}
