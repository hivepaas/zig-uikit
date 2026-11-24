//! Keystrokes applied to a `Document`: the layer that makes a text field
//! typeable.
//!
//! In core, linking nothing, which is the point. Everything a text field does
//! in response to a key -- insert, delete a whole character, extend a
//! selection, step over a word -- is decided here and tested here, against a
//! document in memory. The Wayland module's job shrinks to producing
//! `KeyEvent`s, and the only thing that needs a compositor to test is whether
//! the right event came out.
//!
//! **What it refuses to do is as deliberate as what it does.**
//!
//! `.up` and `.down` are not handled, because there is no line breaker yet.
//! Nothing in this toolkit knows where the second line starts, so a vertical
//! move would have to guess, and a caret that guesses is worse than one that
//! does not move. `.home` and `.end` go to the ends of the *document* for the
//! same reason, and say so.
//!
//! Clipboard keys are not handled either. Ctrl+C needs `wl_data_device` and a
//! round trip through the compositor; it is not an editing operation that
//! happens to have a key attached, and pretending otherwise here would put a
//! protocol dependency in core.
//!
//! Word movement is not UAX #29. It is a three-class scan -- space, word,
//! punctuation -- and the one thing it gets right that a naive version does
//! not is that **every codepoint above U+007F that is not a listed space is a
//! word character**. An ASCII `isAlphanumeric` test would make `tiếng` three
//! words, because `ế` is not ASCII. It still treats a run of Han characters as
//! one word, which UAX #29 does not; a real segmenter replaces this function
//! and nothing else.

const std = @import("std");

const document = @import("document.zig");
const keys = @import("keys.zig");
const offsets = @import("offsets.zig");

const Document = document.Document;
const Range = document.Range;
const KeyEvent = keys.KeyEvent;

pub const Error = document.Error;

pub const Options = struct {
    /// Whether Enter inserts a newline. A single-line field leaves Enter
    /// unhandled so that whatever owns the field can treat it as "submit"
    /// rather than having to undo an insertion.
    multiline: bool = false,
};

pub const Result = struct {
    /// Whether this layer acted on the event at all. An unhandled event is
    /// the caller's to deal with -- Tab, Escape, F5, Ctrl+S -- and saying so
    /// is how a text field coexists with the application around it.
    handled: bool = false,
    /// The document's bytes changed, so the text has to be shaped again.
    edited: bool = false,
    /// The selection or the caret moved. Separate from `edited` because the
    /// two cost different amounts: a caret move repositions one rectangle,
    /// an edit reshapes a line.
    moved: bool = false,
    /// Present exactly when `edited` is set, carrying the extent in all three
    /// offset units for whatever has to be told about it.
    edit: ?document.Edit = null,
};

/// What a keystroke means to a text field, apart from typing: the vocabulary
/// `apply` translates keys into, and the one a platform that already did that
/// translation hands over directly.
///
/// It exists because macOS does the translation itself. AppKit never tells a
/// text view "Option and Left were pressed"; it runs the key through the
/// user's key bindings and calls `moveWordLeft:`. Reconstructing a keystroke
/// from that -- inventing a Ctrl so that `apply` would move by word -- would
/// write Linux's chord into the Mac path, and would break the day someone
/// rebinds a key in `DefaultKeyBinding.dict`, which is a thing Mac users do.
/// So the meaning is the interface, and the chord is one way of arriving at it.
pub const Command = struct {
    op: Op,
    /// Moves the focus and leaves the anchor: Shift with an arrow. Ignored by
    /// the operations that are not movements.
    extend: bool = false,

    pub const Op = enum {
        char_left,
        char_right,
        word_left,
        word_right,
        /// The ends of the document, not of a line: there is no line breaker.
        /// See the note at the top of the file.
        doc_start,
        doc_end,
        delete_char_backward,
        delete_char_forward,
        delete_word_backward,
        delete_word_forward,
        /// Cmd+Backspace on a Mac, which deletes to the start of the *line*;
        /// here, of the document, for the same reason as `doc_start`.
        delete_to_doc_start,
        delete_to_doc_end,
        select_all,
        newline,
    };
};

/// The command a keystroke stands for on a keyboard that names its chords the
/// Linux and Windows way: Ctrl for words, Shift to extend. Null for a key that
/// types text or that a text field does not act on.
pub fn commandFor(ev: KeyEvent) ?Command {
    const m = ev.mods;

    // Ctrl+A. Here rather than left to the application because it is purely a
    // selection change, and because it is the one accelerator a field that
    // cannot do it looks broken without.
    //
    // Matched on `base`, not on the typed text: with Ctrl held the keymap
    // produces `\x01`, so matching the text would match nothing. See the note
    // in `keys.zig`.
    if (m.ctrl and !m.alt and !m.logo and ev.base == 'a') return .{ .op = .select_all };

    return switch (ev.key) {
        .left => .{ .op = if (m.ctrl) .word_left else .char_left, .extend = m.shift },
        .right => .{ .op = if (m.ctrl) .word_right else .char_right, .extend = m.shift },
        .home => .{ .op = .doc_start, .extend = m.shift },
        .end => .{ .op = .doc_end, .extend = m.shift },
        .backspace => .{ .op = if (m.ctrl) .delete_word_backward else .delete_char_backward },
        .delete => .{ .op = if (m.ctrl) .delete_word_forward else .delete_char_forward },
        .enter => .{ .op = .newline },
        // No line breaker, so there is no second line to move to. Reported as
        // unhandled rather than silently swallowed, so that a scroll view
        // above can still act on it. Focus traversal and dismissal belong to
        // whatever owns the field.
        .up, .down, .page_up, .page_down, .tab, .escape, .insert, .none => null,
    };
}

/// Applies one keystroke.
///
/// Returns `Error.Locked` when the document cannot be edited right now --
/// which happens for real: an input method holding a lock, or a composition in
/// progress. Spike B hit exactly this and printed a warning about "two writers
/// to one document"; here it is an error the caller has to decide about,
/// because the right recovery (commit the composition, or cancel it) depends
/// on which key it was and only the caller knows.
///
/// Caret movement is refused under the same condition, and that is not an
/// oversight. The composing range is a byte range into this document; moving
/// the caret out from under it leaves the input method describing text that is
/// no longer where it thinks it is.
pub fn apply(doc: *Document, ev: KeyEvent, opt: Options) Error!Result {
    if (commandFor(ev)) |cmd| return applyCommand(doc, cmd, opt);
    if (ev.key != .none) return .{};

    // A plain typed character.
    //
    // Refused when an accelerator modifier is held, even though the platform
    // layer has already dropped the control characters that Ctrl produces.
    // Two reasons it is checked again here: a platform that reports Ctrl+A as
    // the text `a` rather than as `\x01` is not hypothetical -- that is what a
    // Windows WM_CHAR path can look like -- and this is the layer with tests,
    // so this is where the rule should be enforceable without a keyboard.
    const s = ev.text();
    if (s.len == 0 or ev.mods.anyAccel()) return .{};
    if (!isInsertable(s)) return .{};
    if (!doc.canEditNow()) return Error.Locked;
    const e = try doc.insert(.application, s);
    return .{ .handled = true, .edited = true, .moved = true, .edit = e };
}

/// Applies one command. Refused with `Error.Locked` under the same conditions
/// as `apply`, for the same reasons.
pub fn applyCommand(doc: *Document, cmd: Command, opt: Options) Error!Result {
    switch (cmd.op) {
        .char_left, .char_right, .word_left, .word_right, .doc_start, .doc_end => return move(doc, cmd),

        .select_all => {
            if (!doc.canEditNow()) return Error.Locked;
            try doc.setSelection(0, doc.len());
            return .{ .handled = true, .moved = true };
        },

        .delete_char_backward, .delete_word_backward, .delete_to_doc_start => {
            if (!doc.canEditNow()) return Error.Locked;
            const sel = doc.selection();
            if (!sel.isEmpty()) return deleteRange(doc, sel);
            if (sel.start == 0) return .{ .handled = true };
            const to: usize = switch (cmd.op) {
                .delete_word_backward => prevWord(doc.text(), sel.start),
                .delete_to_doc_start => 0,
                else => offsets.prevChar(doc.text(), sel.start),
            };
            return deleteRange(doc, .{ .start = to, .end = sel.start });
        },

        .delete_char_forward, .delete_word_forward, .delete_to_doc_end => {
            if (!doc.canEditNow()) return Error.Locked;
            const sel = doc.selection();
            if (!sel.isEmpty()) return deleteRange(doc, sel);
            if (sel.end == doc.len()) return .{ .handled = true };
            const to: usize = switch (cmd.op) {
                .delete_word_forward => nextWord(doc.text(), sel.end),
                .delete_to_doc_end => doc.len(),
                else => offsets.nextChar(doc.text(), sel.end),
            };
            return deleteRange(doc, .{ .start = sel.end, .end = to });
        },

        .newline => {
            if (!opt.multiline) return .{};
            if (!doc.canEditNow()) return Error.Locked;
            const e = try doc.insert(.application, "\n");
            return .{ .handled = true, .edited = true, .moved = true, .edit = e };
        },
    }
}

fn deleteRange(doc: *Document, r: Range) Error!Result {
    const e = try doc.replaceRange(.application, r, "");
    return .{ .handled = true, .edited = true, .moved = true, .edit = e };
}

/// Whether a string is text rather than a control sequence.
///
/// The platform layer drops control characters, so in practice this is a
/// second line of defence -- and it is also what makes "the document never
/// contains a control byte a keystroke put there" a property of core rather
/// than a property of one backend.
pub fn isInsertable(s: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(s)) return false;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        // C0, DEL, and C1. A newline is excluded too: it arrives as `.enter`,
        // which knows whether the field is multi-line, and a pasted newline is
        // the paste path's business rather than a keystroke's.
        if (cp < 0x20 or cp == 0x7F) return false;
        if (cp >= 0x80 and cp <= 0x9F) return false;
    }
    return true;
}

// ------------------------------------------------------------------- movement

fn move(doc: *Document, cmd: Command) Error!Result {
    if (!doc.canEditNow()) return Error.Locked;

    const s = doc.text();
    const sel = doc.selection();

    const target: usize = switch (cmd.op) {
        // To the ends of the DOCUMENT, not of the line. There is no line
        // breaker, so there are no line ends to go to; when there is one, this
        // is the function that changes.
        .doc_start => 0,
        .doc_end => s.len,
        .char_left, .word_left => blk: {
            // An unshifted arrow with a selection collapses it to the near
            // edge rather than moving from the focus. Which edge is "near"
            // depends on the direction, not on which end the focus is at,
            // which is why the selection is kept as anchor-and-focus and not
            // as an ordered pair.
            if (!cmd.extend and !sel.isEmpty()) break :blk sel.start;
            break :blk if (cmd.op == .word_left) prevWord(s, doc.focus) else offsets.prevChar(s, doc.focus);
        },
        .char_right, .word_right => blk: {
            if (!cmd.extend and !sel.isEmpty()) break :blk sel.end;
            break :blk if (cmd.op == .word_right) nextWord(s, doc.focus) else offsets.nextChar(s, doc.focus);
        },
        else => unreachable,
    };

    const anchor_was = doc.anchor;
    const focus_was = doc.focus;
    if (cmd.extend) {
        try doc.setSelection(doc.anchor, target);
    } else {
        try doc.setCaret(target);
    }
    return .{
        .handled = true,
        .moved = doc.anchor != anchor_was or doc.focus != focus_was,
    };
}

const Class = enum { space, word, punct };

fn classOf(cp: u21) Class {
    switch (cp) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C => return .space,
        // The space characters above U+007F that a real document contains:
        // no-break space, the typographic spaces, line and paragraph
        // separators, narrow no-break space, medium mathematical space, and
        // the CJK ideographic space.
        0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => return .space,
        0x2000...0x200A => return .space,
        else => {},
    }
    if (cp < 0x80) {
        // `_` stays a word character: it is part of an identifier everywhere
        // that a text field is used to type one.
        if (cp == '_') return .word;
        const is_alnum = (cp >= '0' and cp <= '9') or
            (cp >= 'A' and cp <= 'Z') or
            (cp >= 'a' and cp <= 'z');
        return if (is_alnum) .word else .punct;
    }
    // Everything else: a word character. See the note at the top of the file
    // about why this is the important case and not the fallback it looks like.
    return .word;
}

fn classAt(s: []const u8, b: usize) Class {
    if (b >= s.len) return .space;
    const cp = std.unicode.utf8Decode(s[b..offsets.nextChar(s, b)]) catch return .punct;
    return classOf(cp);
}

/// The start of the word before `b`: skip any spaces backwards, then skip the
/// run of same-class characters that ends there.
pub fn prevWord(s: []const u8, b: usize) usize {
    var i = @min(b, s.len);
    while (i > 0) {
        const p = offsets.prevChar(s, i);
        if (classAt(s, p) != .space) break;
        i = p;
    }
    if (i == 0) return 0;
    const run = classAt(s, offsets.prevChar(s, i));
    while (i > 0) {
        const p = offsets.prevChar(s, i);
        if (classAt(s, p) != run) break;
        i = p;
    }
    return i;
}

/// The end of the word after `b`: skip any spaces forwards, then skip the run
/// of same-class characters that starts there.
pub fn nextWord(s: []const u8, b: usize) usize {
    var i = @min(b, s.len);
    while (i < s.len and classAt(s, i) == .space) i = offsets.nextChar(s, i);
    if (i == s.len) return i;
    const run = classAt(s, i);
    while (i < s.len and classAt(s, i) == run) i = offsets.nextChar(s, i);
    return i;
}

// ---------------------------------------------------------------------- tests

const testing = std.testing;

fn docWith(s: []const u8) !Document {
    var d = Document.init(testing.allocator);
    _ = try d.insert(.application, s);
    return d;
}

test "typing inserts and advances the caret" {
    var d = Document.init(testing.allocator);
    defer d.deinit();

    for ([_][]const u8{ "t", "i", "ế", "n", "g" }) |ch| {
        const r = try apply(&d, KeyEvent.typed(ch), .{});
        try testing.expect(r.handled and r.edited);
    }
    try testing.expectEqualStrings("tiếng", d.text());
    try testing.expectEqual(d.len(), d.focus);
}

test "an accelerator chord types nothing" {
    var d = Document.init(testing.allocator);
    defer d.deinit();

    // Both shapes a platform can deliver Ctrl+S in: the control character
    // `xkbcommon` produces, and the plain letter a Windows path would.
    const ctrl: keys.Mods = .{ .ctrl = true };
    _ = try apply(&d, KeyEvent.typed("\x13").withMods(ctrl), .{});
    _ = try apply(&d, KeyEvent.typed("s").withMods(ctrl), .{});
    try testing.expectEqualStrings("", d.text());

    // Shift is not an accelerator: a capital letter is text.
    const r = try apply(&d, KeyEvent.typed("S").withMods(.{ .shift = true }), .{});
    try testing.expect(r.edited);
    try testing.expectEqualStrings("S", d.text());
}

test "backspace removes a whole character, not a byte" {
    var d = try docWith("tiếng Việt");
    defer d.deinit();

    const r = try apply(&d, KeyEvent.named(.backspace), .{});
    try testing.expect(r.edited);
    try testing.expectEqualStrings("tiếng Việ", d.text());
    try testing.expect(std.unicode.utf8ValidateSlice(d.text()));

    // And again over the three-byte `ệ`.
    _ = try apply(&d, KeyEvent.named(.backspace), .{});
    try testing.expectEqualStrings("tiếng Vi", d.text());
}

test "forward delete removes a whole character" {
    var d = try docWith("ếch");
    defer d.deinit();
    try d.setCaret(0);

    _ = try apply(&d, KeyEvent.named(.delete), .{});
    try testing.expectEqualStrings("ch", d.text());
}

test "arrows move by character and shift extends" {
    var d = try docWith("ếch");
    defer d.deinit();

    // From the end: one press crosses all three bytes of `ế` only after two
    // single-byte steps.
    _ = try apply(&d, KeyEvent.named(.left), .{});
    try testing.expectEqual(@as(usize, 4), d.focus);
    _ = try apply(&d, KeyEvent.named(.left), .{});
    try testing.expectEqual(@as(usize, 3), d.focus);
    _ = try apply(&d, KeyEvent.named(.left), .{});
    try testing.expectEqual(@as(usize, 0), d.focus);

    const shift: keys.Mods = .{ .shift = true };
    _ = try apply(&d, KeyEvent.named(.right).withMods(shift), .{});
    try testing.expectEqual(@as(usize, 0), d.anchor);
    try testing.expectEqual(@as(usize, 3), d.focus);
    try testing.expectEqualStrings("ế", d.text()[d.selection().start..d.selection().end]);
}

test "an unshifted arrow collapses a selection to the near edge" {
    var d = try docWith("one two");
    defer d.deinit();
    try d.setSelection(2, 5);

    _ = try apply(&d, KeyEvent.named(.left), .{});
    try testing.expectEqual(@as(usize, 2), d.focus);
    try testing.expect(d.selection().isEmpty());

    try d.setSelection(2, 5);
    _ = try apply(&d, KeyEvent.named(.right), .{});
    try testing.expectEqual(@as(usize, 5), d.focus);

    // The direction decides the edge, not which end the focus is at: the same
    // selection written backwards collapses to the same place.
    try d.setSelection(5, 2);
    _ = try apply(&d, KeyEvent.named(.right), .{});
    try testing.expectEqual(@as(usize, 5), d.focus);
}

test "typing over a selection replaces it" {
    var d = try docWith("tiếng Việt");
    defer d.deinit();
    // Counted, not guessed: `ế` is three bytes, so "tiếng " ends at 8.
    try d.setSelection(0, "tiếng ".len);

    const r = try apply(&d, KeyEvent.typed("X"), .{});
    try testing.expect(r.edited);
    try testing.expectEqualStrings("XViệt", d.text());
    try testing.expect(d.selection().isEmpty());
}

test "word movement treats a Vietnamese syllable as one word" {
    // The case an ASCII-only word test gets wrong: every one of these
    // syllables contains a codepoint above U+007F, and a classifier that
    // called those non-word would stop the caret inside `tiếng`.
    const s = "tiếng Việt rất hay";
    var d = try docWith(s);
    defer d.deinit();
    try d.setCaret(0);

    const ctrl: keys.Mods = .{ .ctrl = true };
    const want = [_][]const u8{ "tiếng", "tiếng Việt", "tiếng Việt rất", s };
    for (want) |prefix| {
        _ = try apply(&d, KeyEvent.named(.right).withMods(ctrl), .{});
        try testing.expectEqual(prefix.len, d.focus);
    }

    // And back, to the start of each.
    const back = [_][]const u8{ "tiếng Việt rất ", "tiếng Việt ", "tiếng ", "" };
    for (back) |prefix| {
        _ = try apply(&d, KeyEvent.named(.left).withMods(ctrl), .{});
        try testing.expectEqual(prefix.len, d.focus);
    }
}

test "punctuation is its own word run" {
    const s = "a, b";
    try testing.expectEqual(@as(usize, 1), nextWord(s, 0));
    try testing.expectEqual(@as(usize, 2), nextWord(s, 1));
    try testing.expectEqual(@as(usize, 4), nextWord(s, 2));
    try testing.expectEqual(@as(usize, 3), prevWord(s, 4));
    try testing.expectEqual(@as(usize, 1), prevWord(s, 3));
}

test "ctrl+backspace deletes a word" {
    var d = try docWith("tiếng Việt");
    defer d.deinit();

    _ = try apply(&d, KeyEvent.named(.backspace).withMods(.{ .ctrl = true }), .{});
    try testing.expectEqualStrings("tiếng ", d.text());
}

test "ctrl+a selects everything, and does not type an 'a'" {
    var d = try docWith("tiếng Việt");
    defer d.deinit();
    try d.setCaret(0);

    var ev = KeyEvent.typed("\x01");
    ev.base = 'a';
    const r = try apply(&d, ev.withMods(.{ .ctrl = true }), .{});
    try testing.expect(r.handled and r.moved and !r.edited);
    try testing.expectEqual(@as(usize, 0), d.selection().start);
    try testing.expectEqual(d.len(), d.selection().end);
    try testing.expectEqualStrings("tiếng Việt", d.text());
}

test "home and end go to the ends of the document" {
    var d = try docWith("tiếng Việt");
    defer d.deinit();

    _ = try apply(&d, KeyEvent.named(.home), .{});
    try testing.expectEqual(@as(usize, 0), d.focus);
    _ = try apply(&d, KeyEvent.named(.end).withMods(.{ .shift = true }), .{});
    try testing.expectEqual(d.len(), d.selection().end);
    try testing.expectEqual(@as(usize, 0), d.selection().start);
}

test "enter is unhandled in a single-line field and inserts in a multi-line one" {
    var d = Document.init(testing.allocator);
    defer d.deinit();

    const single = try apply(&d, KeyEvent.named(.enter), .{});
    try testing.expect(!single.handled);
    try testing.expectEqualStrings("", d.text());

    const multi = try apply(&d, KeyEvent.named(.enter), .{ .multiline = true });
    try testing.expect(multi.edited);
    try testing.expectEqualStrings("\n", d.text());
}

test "vertical movement is reported unhandled rather than guessed at" {
    var d = try docWith("one\ntwo");
    defer d.deinit();
    const before = d.focus;
    for ([_]keys.Key{ .up, .down, .page_up, .page_down }) |k| {
        const r = try apply(&d, KeyEvent.named(k), .{});
        try testing.expect(!r.handled);
    }
    try testing.expectEqual(before, d.focus);
}

test "a keystroke during a composition is refused, not interleaved" {
    var d = try docWith("tiếng Vi");
    defer d.deinit();
    try d.setPreedit("ệt");

    // This is spike B's "two writers to one document", as an error rather than
    // as a printed warning.
    try testing.expectError(Error.Locked, apply(&d, KeyEvent.typed("x"), .{}));
    try testing.expectError(Error.Locked, apply(&d, KeyEvent.named(.backspace), .{}));
    try testing.expectError(Error.Locked, apply(&d, KeyEvent.named(.left), .{}));
    try testing.expectEqualStrings("tiếng Vi", d.text());

    d.endComposition();
    const r = try apply(&d, KeyEvent.typed("x"), .{});
    try testing.expect(r.edited);
}

test "the document never gains a control byte from a keystroke" {
    var d = Document.init(testing.allocator);
    defer d.deinit();
    for ([_][]const u8{ "\x00", "\x1B", "\x7F", "\n", "\r", "\t", "\u{0085}" }) |s| {
        _ = try apply(&d, KeyEvent.typed(s), .{});
    }
    try testing.expectEqualStrings("", d.text());
    try testing.expect(!isInsertable("a\nb"));
    try testing.expect(isInsertable("tiếng Việt"));
}
