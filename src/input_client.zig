//! What an input method that writes into the document asks of it: AppKit's
//! `NSTextInputClient`, in plain Zig on a `Document`.
//!
//! In core and linking nothing, like `editing.zig`, so that everything a Mac
//! input method can do to a field is tested here against a document in memory
//! and the AppKit view (`platform/macos.zig`) is left translating `NSString`s
//! and `NSRange`s. A protocol that can only be exercised by an input method is
//! a protocol with no tests.
//!
//! **macOS has the Windows shape.** `setMarkedText:` puts the provisional text
//! *into* the client's storage and the client reports where it is
//! (`markedRange`), exactly as TSF's `SetText` does and unlike Wayland's
//! preedit, which never enters the document. `docs/text-and-accessibility.md`
//! §2 chose the document model so that this shape fits; this file is the
//! first time a second platform has tested that choice, and it fits without a
//! change to `document.zig`.
//!
//! **Ranges are UTF-16**, as they are in TSF: an `NSRange` indexes an
//! `NSString`, which is UTF-16 code units. Everything here converts through
//! `offsets.zig` at the boundary and the document stays in bytes.
//!
//! **A replacement range of `not_found` means "the marked text, or else the
//! selection"**, which is the one rule the protocol's documentation states and
//! every implementation has to get right: Telex replaces the marked `vie` with
//! `viê`, and a client that inserted at the caret instead would produce
//! `vieviê`.
//!
//! The second half of the file is the other thing AppKit hands a text view:
//! not keystrokes but *selectors*, the output of the user's key bindings.
//! `commandForSelector` maps them onto `editing.Command`.

const std = @import("std");

const document = @import("document.zig");
const editing = @import("editing.zig");
const keys = @import("keys.zig");
const offsets = @import("offsets.zig");

const Document = document.Document;
const Range = document.Range;
const Error = document.Error;

/// `NSNotFound`, which is `NSIntegerMax` and not the maximum of the unsigned
/// type the range is made of.
pub const not_found: usize = std.math.maxInt(isize);

/// An `NSRange`: a UTF-16 location and length, laid out as AppKit passes it.
pub const Utf16Range = extern struct {
    location: usize,
    length: usize,

    pub const none: Utf16Range = .{ .location = not_found, .length = 0 };

    pub fn isNone(self: Utf16Range) bool {
        return self.location == not_found;
    }
};

/// `selectedRange`: the selection, or the caret as an empty range.
pub fn selectedRange(doc: *const Document) Utf16Range {
    const r = doc.selectionUtf16();
    return .{ .location = r.start, .length = r.end - r.start };
}

/// `markedRange`: where the provisional text is, or `none`.
pub fn markedRange(doc: *const Document) Utf16Range {
    const c = doc.composing orelse return .none;
    return fromBytes(doc.text(), c);
}

pub fn hasMarkedText(doc: *const Document) bool {
    return doc.composing != null;
}

/// `setMarkedText:selectedRange:replacementRange:`.
///
/// `s` replaces the replacement range -- or the marked text, or else the
/// selection -- and becomes the new marked text. `sel` is relative to `s`:
/// where the input method wants the caret inside its own provisional text.
/// An empty `s` removes the marked text and ends the composition, which is how
/// an input method cancels one.
pub fn setMarkedText(doc: *Document, s: []const u8, sel: Utf16Range, replacement: Utf16Range) Error!void {
    const target = try targetRange(doc, replacement);
    const e = try doc.replaceRange(.input_method, target, s);
    const start = e.bytes.start;
    if (s.len == 0) {
        doc.endComposition();
        try doc.setCaret(start);
        return;
    }
    try doc.setComposingRange(.{ .start = start, .end = e.bytes.new_end });
    // Clamped, not trusted: the input method is another process, and a range
    // past the end of its own string is a request with no correct answer.
    const sel_start = offsets.utf16ToByte(s, @min(sel.location, not_found - 1));
    const sel_end = offsets.utf16ToByte(s, sel.location +| sel.length);
    try doc.setSelection(start + sel_start, start + sel_end);
}

/// `insertText:replacementRange:`: commit `s`, replacing the replacement
/// range -- or the marked text, or else the selection -- and end any
/// composition. The caret goes after the inserted text.
///
/// This is also how plain typing arrives on a Mac with no input method in the
/// way: AppKit calls it with one character and no marked text, so the target
/// is the selection and this is an ordinary keystroke. It is still written as
/// an input-method edit, because AppKit is the input method's side of the
/// protocol even when no input method is installed.
pub fn insertText(doc: *Document, s: []const u8, replacement: Utf16Range) Error!document.Edit {
    const target = try targetRange(doc, replacement);
    const e = try doc.replaceRange(.input_method, target, s);
    doc.endComposition();
    try doc.setCaret(e.bytes.new_end);
    return e;
}

/// `unmarkText`: the marked text stays and stops being provisional.
pub fn unmarkText(doc: *Document) void {
    doc.endComposition();
}

/// `attributedSubstringForProposedRange:actualRange:`, minus the attributes:
/// the bytes of a UTF-16 range, clamped to the document, and the range they
/// actually cover. Null when the range starts past the end.
pub fn substring(doc: *const Document, r: Utf16Range) ?struct { text: []const u8, actual: Utf16Range } {
    const s = doc.text();
    const total = offsets.byteToUtf16(s, s.len);
    if (r.isNone() or r.location > total) return null;
    const b = toBytes(s, r);
    return .{ .text = s[b.start..b.end], .actual = fromBytes(s, b) };
}

/// A UTF-16 range as bytes. A location inside a surrogate pair resolves to
/// the character's start, as `utf16ToByte` does, and the end is clamped.
pub fn toBytes(s: []const u8, r: Utf16Range) Range {
    const start = offsets.utf16ToByte(s, r.location);
    const end = offsets.utf16ToByte(s, r.location +| r.length);
    return .{ .start = start, .end = @max(start, end) };
}

pub fn fromBytes(s: []const u8, r: Range) Utf16Range {
    const a = offsets.byteToUtf16(s, r.start);
    return .{ .location = a, .length = offsets.byteToUtf16(s, r.end) - a };
}

fn targetRange(doc: *const Document, replacement: Utf16Range) Error!Range {
    if (!replacement.isNone()) return toBytes(doc.text(), replacement);
    if (doc.composing) |c| return c;
    return doc.selection();
}

// ------------------------------------------------------------- key bindings
//
// AppKit runs every key that is not text through the key bindings --
// `StandardKeyBinding.dict`, then the user's `DefaultKeyBinding.dict` -- and
// calls `doCommandBySelector:` with the result. So Option+Left arrives as
// `moveWordLeft:`, Cmd+Left as `moveToLeftEndOfLine:`, and Ctrl+K, if nobody
// rebound it, as `deleteToEndOfParagraph:`. The selector is the meaning, and
// a text view that switched on the key instead would ignore every binding the
// user has.
//
// Line commands are the line the caret is drawn on, which needs the field's
// line table in `editing.Options`; without one they fall back to the ends of
// the document, as `editing.zig` says. Paragraph commands are the document's
// ends, because a field is one paragraph until it takes a newline -- Ctrl+A
// and Ctrl+E, which Emacs users reach for, are paragraph commands on a Mac,
// and that is right for every field this toolkit has.
//
// Up and down are commands too, now that there are lines. When a field has
// none they report themselves unhandled, and the view passes them on as keys
// (`keyForSelector`) for a list or a scroll view to act on.

const Op = editing.Command.Op;

const Binding = struct { name: []const u8, op: Op, extend: bool = false };

const bindings = [_]Binding{
    .{ .name = "moveLeft:", .op = .char_left },
    .{ .name = "moveRight:", .op = .char_right },
    .{ .name = "moveBackward:", .op = .char_left },
    .{ .name = "moveForward:", .op = .char_right },
    .{ .name = "moveLeftAndModifySelection:", .op = .char_left, .extend = true },
    .{ .name = "moveRightAndModifySelection:", .op = .char_right, .extend = true },
    .{ .name = "moveBackwardAndModifySelection:", .op = .char_left, .extend = true },
    .{ .name = "moveForwardAndModifySelection:", .op = .char_right, .extend = true },

    .{ .name = "moveWordLeft:", .op = .word_left },
    .{ .name = "moveWordRight:", .op = .word_right },
    .{ .name = "moveWordBackward:", .op = .word_left },
    .{ .name = "moveWordForward:", .op = .word_right },
    .{ .name = "moveWordLeftAndModifySelection:", .op = .word_left, .extend = true },
    .{ .name = "moveWordRightAndModifySelection:", .op = .word_right, .extend = true },
    .{ .name = "moveWordBackwardAndModifySelection:", .op = .word_left, .extend = true },
    .{ .name = "moveWordForwardAndModifySelection:", .op = .word_right, .extend = true },

    .{ .name = "moveUp:", .op = .line_up },
    .{ .name = "moveDown:", .op = .line_down },
    .{ .name = "moveUpAndModifySelection:", .op = .line_up, .extend = true },
    .{ .name = "moveDownAndModifySelection:", .op = .line_down, .extend = true },

    .{ .name = "moveToLeftEndOfLine:", .op = .line_start },
    .{ .name = "moveToRightEndOfLine:", .op = .line_end },
    .{ .name = "moveToBeginningOfLine:", .op = .line_start },
    .{ .name = "moveToEndOfLine:", .op = .line_end },
    .{ .name = "moveToBeginningOfParagraph:", .op = .doc_start },
    .{ .name = "moveToEndOfParagraph:", .op = .doc_end },
    .{ .name = "moveToBeginningOfDocument:", .op = .doc_start },
    .{ .name = "moveToEndOfDocument:", .op = .doc_end },
    .{ .name = "moveToLeftEndOfLineAndModifySelection:", .op = .line_start, .extend = true },
    .{ .name = "moveToRightEndOfLineAndModifySelection:", .op = .line_end, .extend = true },
    .{ .name = "moveToBeginningOfLineAndModifySelection:", .op = .line_start, .extend = true },
    .{ .name = "moveToEndOfLineAndModifySelection:", .op = .line_end, .extend = true },
    .{ .name = "moveToBeginningOfParagraphAndModifySelection:", .op = .doc_start, .extend = true },
    .{ .name = "moveToEndOfParagraphAndModifySelection:", .op = .doc_end, .extend = true },
    .{ .name = "moveToBeginningOfDocumentAndModifySelection:", .op = .doc_start, .extend = true },
    .{ .name = "moveToEndOfDocumentAndModifySelection:", .op = .doc_end, .extend = true },

    .{ .name = "deleteBackward:", .op = .delete_char_backward },
    // Ctrl+Backspace. It means "remove the last mark and keep the base
    // letter" -- `ế` to `ê` -- which is a real Vietnamese editing operation
    // and not one this toolkit does yet. Deleting the whole character is the
    // honest approximation, and a test pins that it is one.
    .{ .name = "deleteBackwardByDecomposingPreviousCharacter:", .op = .delete_char_backward },
    .{ .name = "deleteForward:", .op = .delete_char_forward },
    .{ .name = "deleteWordBackward:", .op = .delete_word_backward },
    .{ .name = "deleteWordForward:", .op = .delete_word_forward },
    .{ .name = "deleteToBeginningOfLine:", .op = .delete_to_line_start },
    .{ .name = "deleteToEndOfLine:", .op = .delete_to_line_end },
    .{ .name = "deleteToBeginningOfParagraph:", .op = .delete_to_doc_start },
    .{ .name = "deleteToEndOfParagraph:", .op = .delete_to_doc_end },

    .{ .name = "selectAll:", .op = .select_all },
    .{ .name = "insertNewline:", .op = .newline },
    .{ .name = "insertLineBreak:", .op = .newline },
    .{ .name = "insertNewlineIgnoringFieldEditor:", .op = .newline },
};

/// The editing command a key-binding selector names, or null for one a text
/// field does not act on itself.
pub fn commandForSelector(name: []const u8) ?editing.Command {
    for (bindings) |b| {
        if (std.mem.eql(u8, b.name, name)) return .{ .op = b.op, .extend = b.extend };
    }
    return null;
}

/// The key to report to the application for a selector the field did not act
/// on but the application may want: Escape, Tab, paging, and up and down when
/// the field has no lines to move between, so that a scroll view can act on
/// them.
pub fn keyForSelector(name: []const u8) ?keys.KeyEvent {
    const table = [_]struct { []const u8, keys.Key, keys.Mods }{
        .{ "cancelOperation:", .escape, .{} },
        .{ "insertTab:", .tab, .{} },
        .{ "insertBacktab:", .tab, .{ .shift = true } },
        .{ "moveUp:", .up, .{} },
        .{ "moveDown:", .down, .{} },
        .{ "moveUpAndModifySelection:", .up, .{ .shift = true } },
        .{ "moveDownAndModifySelection:", .down, .{ .shift = true } },
        .{ "pageUp:", .page_up, .{} },
        .{ "pageDown:", .page_down, .{} },
        .{ "scrollPageUp:", .page_up, .{} },
        .{ "scrollPageDown:", .page_down, .{} },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e[0], name)) return keys.KeyEvent.named(e[1]).withMods(e[2]);
    }
    return null;
}

// ---------------------------------------------------------------------- tests

const testing = std.testing;

fn r16(location: usize, length: usize) Utf16Range {
    return .{ .location = location, .length = length };
}

test "plain typing is insertText with nothing marked" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    _ = try insertText(&doc, "a", .none);
    _ = try insertText(&doc, "ă", .none);
    try testing.expectEqualStrings("aă", doc.text());
    try testing.expectEqual(r16(2, 0), selectedRange(&doc));
    try testing.expect(!hasMarkedText(&doc));
    try testing.expect(doc.canEditNow());
}

test "Telex: each mark replaces the marked text, and the commit replaces it once more" {
    // What Apple's Vietnamese input method sends for `v i e e t j`, then a
    // space: the provisional syllable grows and changes in place, and the
    // client's only job is to replace the marked text rather than insert at
    // the caret. Getting the default target wrong produces `vviviêviêt...`.
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    _ = try insertText(&doc, "tiếng ", .none);

    const steps = [_][]const u8{ "v", "vi", "vie", "viê", "viêt", "việt" };
    for (steps) |s| {
        const n = offsets.byteToUtf16(s, s.len);
        try setMarkedText(&doc, s, r16(n, 0), .none);
        try testing.expect(hasMarkedText(&doc));
        try testing.expectEqual(r16(6, n), markedRange(&doc));
        try testing.expectEqual(r16(6 + n, 0), selectedRange(&doc));
        // The application may not type into the middle of this.
        try testing.expect(!doc.canEditNow());
    }
    try testing.expectEqualStrings("tiếng việt", doc.text());

    _ = try insertText(&doc, "việt", .none);
    _ = try insertText(&doc, " ", .none);
    try testing.expectEqualStrings("tiếng việt ", doc.text());
    try testing.expect(!hasMarkedText(&doc));
    try testing.expectEqual(markedRange(&doc), Utf16Range.none);
    try testing.expect(doc.canEditNow());
}

test "an empty marked string cancels the composition and removes its text" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    _ = try insertText(&doc, "ab", .none);
    try setMarkedText(&doc, "xê", r16(2, 0), .none);
    try testing.expectEqualStrings("abxê", doc.text());
    try setMarkedText(&doc, "", r16(0, 0), .none);
    try testing.expectEqualStrings("ab", doc.text());
    try testing.expect(!hasMarkedText(&doc));
    try testing.expectEqual(r16(2, 0), selectedRange(&doc));
}

test "unmarkText keeps the text and ends the composition" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    try setMarkedText(&doc, "việt", r16(4, 0), .none);
    unmarkText(&doc);
    try testing.expectEqualStrings("việt", doc.text());
    try testing.expect(!hasMarkedText(&doc));
    try testing.expect(doc.canEditNow());
}

test "marked text replaces a selection, and its caret is relative to itself" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    _ = try insertText(&doc, "một hai ba", .none);
    // Select "hai" (UTF-16 4..7) and start composing over it.
    try doc.setSelection(offsets.utf16ToByte(doc.text(), 4), offsets.utf16ToByte(doc.text(), 7));
    try setMarkedText(&doc, "bốn", r16(1, 1), .none);
    try testing.expectEqualStrings("một bốn ba", doc.text());
    try testing.expectEqual(r16(4, 3), markedRange(&doc));
    // The input method asked for its second character selected.
    try testing.expectEqual(r16(5, 1), selectedRange(&doc));
}

test "an explicit replacement range is UTF-16, and a non-BMP character counts twice" {
    // The emoji is two UTF-16 units and four bytes. A client that read the
    // replacement range as bytes or as codepoints replaces the wrong text.
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    _ = try insertText(&doc, "🇻🇳 a", .none);
    // The flag is four UTF-16 units; "a" is at 5.
    _ = try insertText(&doc, "ă", r16(5, 1));
    try testing.expectEqualStrings("🇻🇳 ă", doc.text());
    try testing.expectEqual(r16(6, 0), selectedRange(&doc));
}

test "a hostile range is clamped, not trusted" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    _ = try insertText(&doc, "abc", .none);
    _ = try insertText(&doc, "X", r16(2, 1000));
    try testing.expectEqualStrings("abX", doc.text());
    try setMarkedText(&doc, "ê", r16(50, 50), .none);
    try testing.expectEqualStrings("abXê", doc.text());
    try testing.expectEqual(r16(4, 0), selectedRange(&doc));
}

test "substring clamps and reports the range it actually covered" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    _ = try insertText(&doc, "tiếng Việt", .none);
    const got = substring(&doc, r16(6, 100)).?;
    try testing.expectEqualStrings("Việt", got.text);
    try testing.expectEqual(r16(6, 4), got.actual);
    try testing.expect(substring(&doc, r16(11, 1)) == null);
    try testing.expect(substring(&doc, .none) == null);
}

test "key-binding selectors are editing commands, by meaning and not by chord" {
    const word = commandForSelector("moveWordLeftAndModifySelection:").?;
    try testing.expectEqual(Op.word_left, word.op);
    try testing.expect(word.extend);
    try testing.expectEqual(Op.line_start, commandForSelector("moveToLeftEndOfLine:").?.op);
    try testing.expectEqual(Op.doc_start, commandForSelector("moveToBeginningOfDocument:").?.op);
    try testing.expectEqual(Op.delete_to_doc_end, commandForSelector("deleteToEndOfParagraph:").?.op);
    try testing.expectEqual(Op.line_up, commandForSelector("moveUp:").?.op);
    try testing.expectEqual(Op.line_end, commandForSelector("moveToEndOfLine:").?.op);
    try testing.expectEqual(@as(?editing.Command, null), commandForSelector("noop:"));

    try testing.expectEqual(keys.Key.escape, keyForSelector("cancelOperation:").?.key);
    try testing.expect(keyForSelector("insertBacktab:").?.mods.shift);
    try testing.expectEqual(@as(?keys.KeyEvent, null), keyForSelector("moveLeft:"));
    // Up and down are both: a command first, and a key for the application
    // when the field had no line to move to.
    try testing.expectEqual(keys.Key.up, keyForSelector("moveUp:").?.key);
}

test "Option+Left on a Mac moves by word through a Vietnamese syllable" {
    // The command a Mac sends for Option+Left, applied to the same text the
    // Linux test moves Ctrl+Left through: the same answer by another road.
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    _ = try insertText(&doc, "Gõ vào đây: tiếng Việt", .none);
    const cmd = commandForSelector("moveWordLeft:").?;
    _ = try editing.applyCommand(&doc, cmd, .{});
    try testing.expectEqualStrings("Việt", doc.text()[doc.focus..]);
    _ = try editing.applyCommand(&doc, cmd, .{});
    try testing.expectEqualStrings("tiếng Việt", doc.text()[doc.focus..]);

    // Cmd+Backspace. One line, since nothing laid it out: to the start.
    _ = try editing.applyCommand(&doc, commandForSelector("deleteToBeginningOfLine:").?, .{});
    try testing.expectEqualStrings("tiếng Việt", doc.text());
}

test "Ctrl+Backspace on a Mac deletes the whole character, for now" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    _ = try insertText(&doc, "tiế", .none);
    _ = try editing.applyCommand(&doc, commandForSelector("deleteBackwardByDecomposingPreviousCharacter:").?, .{});
    try testing.expectEqualStrings("ti", doc.text());
}

test "a command during a composition is refused" {
    var doc = Document.init(testing.allocator);
    defer doc.deinit();
    try setMarkedText(&doc, "vi", r16(2, 0), .none);
    try testing.expectError(Error.Locked, editing.applyCommand(&doc, commandForSelector("deleteBackward:").?, .{}));
    try testing.expectEqualStrings("vi", doc.text());
}
