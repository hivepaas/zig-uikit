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
const text_layout = @import("text_layout.zig");
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

    /// The field's lines, as the text layer laid them out.
    ///
    /// This is the one place geometry enters the editing layer, and it is
    /// borrowed rather than owned: which line a byte is on is a fact about
    /// how the text was *set*, not about the document, and a field that has
    /// not been laid out yet has no answer. Null means exactly that -- the
    /// vertical movements then report themselves unhandled, and Home and End
    /// mean the ends of the document, which is what they meant before there
    /// was a line breaker.
    lines: ?*const text_layout.Wrapped = null,

    /// The x a run of vertical movements is aiming for.
    ///
    /// Up and down keep the column, and the column is the x the caret had
    /// *before the first* of them -- not the x it has now. Without that, a
    /// caret that passes through a short line drifts left and never comes
    /// back, which is the single most noticeable thing a text editor can get
    /// wrong about arrow keys. The caller keeps whatever `Result.goal_x` said
    /// and hands it back; any other movement clears it, because it reports
    /// null.
    goal_x: ?f32 = null,
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
    /// The column a following vertical movement should aim for, or null to
    /// forget one. See `Options.goal_x`.
    goal_x: ?f32 = null,
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
        /// Up and down, keeping the column. They need `Options.lines`; with
        /// none they report themselves unhandled rather than guessing.
        line_up,
        line_down,
        /// The ends of the line the caret is on, or of the document when
        /// there are no lines to ask.
        line_start,
        line_end,
        /// The ends of the document: Ctrl+Home and Ctrl+End.
        doc_start,
        doc_end,
        delete_char_backward,
        delete_char_forward,
        delete_word_backward,
        delete_word_forward,
        delete_to_doc_start,
        delete_to_doc_end,
        /// Cmd+Backspace on a Mac: to the start of the line the caret is on,
        /// and Ctrl+Delete's opposite number to its end. With no lines to
        /// ask, the document's ends, as `line_start` and `line_end` do.
        delete_to_line_start,
        delete_to_line_end,
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
        // Home is the start of the line and Ctrl+Home the start of the
        // document, which is what every toolkit on these two platforms does.
        // With no lines to ask, the two mean the same thing.
        .home => .{ .op = if (m.ctrl) .doc_start else .line_start, .extend = m.shift },
        .end => .{ .op = if (m.ctrl) .doc_end else .line_end, .extend = m.shift },
        .up => .{ .op = .line_up, .extend = m.shift },
        .down => .{ .op = .line_down, .extend = m.shift },
        .backspace => .{ .op = if (m.ctrl) .delete_word_backward else .delete_char_backward },
        .delete => .{ .op = if (m.ctrl) .delete_word_forward else .delete_char_forward },
        .enter => .{ .op = .newline },
        // A page is a viewport height, which this layer is not told. Focus
        // traversal and dismissal belong to whatever owns the field. All
        // reported as unhandled rather than silently swallowed, so that a
        // scroll view above can still act on them.
        .page_up, .page_down, .tab, .escape, .insert, .none => null,
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
        .char_left,
        .char_right,
        .word_left,
        .word_right,
        .line_start,
        .line_end,
        .doc_start,
        .doc_end,
        => return move(doc, cmd, opt),

        .line_up, .line_down => return moveVertical(doc, cmd, opt),

        .select_all => {
            if (!doc.canEditNow()) return Error.Locked;
            try doc.setSelection(0, doc.len());
            return .{ .handled = true, .moved = true };
        },

        .delete_char_backward, .delete_word_backward, .delete_to_doc_start, .delete_to_line_start => {
            if (!doc.canEditNow()) return Error.Locked;
            const sel = doc.selection();
            if (!sel.isEmpty()) return deleteRange(doc, sel);
            if (sel.start == 0) return .{ .handled = true };
            const to: usize = switch (cmd.op) {
                .delete_word_backward => prevWord(doc.text(), sel.start),
                .delete_to_doc_start => 0,
                .delete_to_line_start => lineEdge(doc.text(), sel.start, .start, opt),
                else => offsets.prevChar(doc.text(), sel.start),
            };
            return deleteRange(doc, .{ .start = to, .end = sel.start });
        },

        .delete_char_forward, .delete_word_forward, .delete_to_doc_end, .delete_to_line_end => {
            if (!doc.canEditNow()) return Error.Locked;
            const sel = doc.selection();
            if (!sel.isEmpty()) return deleteRange(doc, sel);
            if (sel.end == doc.len()) return .{ .handled = true };
            const to: usize = switch (cmd.op) {
                .delete_word_forward => nextWord(doc.text(), sel.end),
                .delete_to_doc_end => doc.len(),
                .delete_to_line_end => lineEdge(doc.text(), sel.end, .end, opt),
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

/// The start or the end of the line a caret at `at` is drawn on, or of the
/// document when there are no lines to ask.
///
/// A line's end is where its ink stops, before the space that wrapped it: End
/// on a wrapped line leaves the caret on that line, where the space after it
/// would put it at the start of the next. The last line has no next, so its
/// end is the document's -- a field that ends in a space has End go past it.
fn lineEdge(s: []const u8, at: usize, edge: enum { start, end }, opt: Options) usize {
    const w = opt.lines orelse return if (edge == .start) 0 else s.len;
    if (w.lines.len == 0) return if (edge == .start) 0 else s.len;
    const i = w.lineOf(at);
    const ln = w.lines[i];
    if (edge == .start) return @min(ln.start, s.len);
    if (i + 1 == w.lines.len) return s.len;
    return @min(ln.end, s.len);
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

fn move(doc: *Document, cmd: Command, opt: Options) Error!Result {
    if (!doc.canEditNow()) return Error.Locked;

    const s = doc.text();
    const sel = doc.selection();

    const target: usize = switch (cmd.op) {
        .doc_start => 0,
        .doc_end => s.len,
        // The ends of the line the caret is on, when anything knows where
        // those are. With no layout they are the document's, which is what
        // Home and End meant before there was a line breaker.
        .line_start => lineEdge(s, doc.focus, .start, opt),
        .line_end => lineEdge(s, doc.focus, .end, opt),
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

/// Up and down, keeping the column.
///
/// Reports itself unhandled with no layout, rather than approximating. A
/// caret that guesses which line it is on is worse than one that does not
/// move: the guess is invisible until the text wraps, and then it is wrong
/// everywhere at once.
fn moveVertical(doc: *Document, cmd: Command, opt: Options) Error!Result {
    const w = opt.lines orelse return .{};
    if (w.lines.len == 0) return .{};
    if (!doc.canEditNow()) return Error.Locked;

    const line = w.lineOf(doc.focus);
    // The column is the one the caret had before the *first* vertical move,
    // not the one it has now. See `Options.goal_x`.
    const goal = opt.goal_x orelse w.caret(doc.focus).x;
    const up = cmd.op == .line_up;

    const target: usize = if (up and line == 0)
        // Already on the first line: go to the start of the document, which
        // is what every text field does and is more useful than refusing.
        0
    else if (!up and line + 1 >= w.lines.len)
        doc.len()
    else
        w.byteOnLine(if (up) line - 1 else line + 1, goal, doc.len());

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
        // Kept even when the caret ran into the end of the document, so that
        // coming back up returns to the column it left.
        .goal_x = goal,
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

// ------------------------------------------------------------------ pointer
//
// What a click does to a field, in core like the keystrokes above, so that it
// is the same on every platform and tested with no pointer at all. The
// platform layer turns a click into a byte offset -- `TextRun.byteAt` -- and a
// click count; everything after that is here.
//
// The rules are the ones every desktop text field shares: one click places
// the caret, Shift-click extends the selection from its anchor, two clicks
// select a word, three select the line -- all of it, with no line breaker --
// and a drag that began with two clicks extends a word at a time, keeping the
// whole of the word it started on.

/// Where a pointer is in a field's text, in two senses: the caret boundary
/// nearest to it, which a click moves the caret to (`TextRun.byteAt`), and
/// the character under it, which a double-click selects the word of
/// (`TextRun.clusterAt`). They differ exactly where it matters -- on the right
/// half of a word's last letter the nearest boundary is after the word.
pub const Hit = struct {
    caret: usize,
    char: usize,
};

/// What a drag extends by.
pub const Granularity = enum { char, word, all };

/// A press in progress: what a drag keeps extending from. Returned by `press`
/// and passed back to `drag`, so the gesture's state lives with the caller
/// that owns the pointer, not in the document.
pub const Gesture = struct {
    granularity: Granularity = .char,
    /// For `.word`: the word the press landed on, which stays selected
    /// whichever way the drag goes.
    origin: Range = .{},
};

/// A button press at `at`, the `count`th in a row.
///
/// Refused with `error.Locked` during a composition, as every caret move is:
/// a click in the middle of provisional text is the input method's to handle,
/// and the platform layer offers it there first and commits the composition
/// if the input method declines.
pub fn press(doc: *Document, at: Hit, count: u32, extend: bool) Error!struct { result: Result, gesture: Gesture } {
    if (!doc.canEditNow()) return Error.Locked;
    const s = doc.text();
    const b = offsets.alignToChar(s, @min(at.caret, s.len));
    const anchor_was = doc.anchor;
    const focus_was = doc.focus;
    var g: Gesture = .{};
    switch (count) {
        0, 1 => if (extend) try doc.setSelection(doc.anchor, b) else try doc.setCaret(b),
        2 => {
            g = .{ .granularity = .word, .origin = wordAt(s, at.char) };
            try doc.setSelection(g.origin.start, g.origin.end);
        },
        else => {
            g = .{ .granularity = .all, .origin = .{ .start = 0, .end = s.len } };
            try doc.setSelection(0, s.len);
        },
    }
    return .{
        .result = .{ .handled = true, .moved = doc.anchor != anchor_was or doc.focus != focus_was },
        .gesture = g,
    };
}

/// The pointer moved to `at` with the button held.
pub fn drag(doc: *Document, g: Gesture, at: Hit) Error!Result {
    if (!doc.canEditNow()) return Error.Locked;
    const s = doc.text();
    const b = offsets.alignToChar(s, @min(at.caret, s.len));
    const anchor_was = doc.anchor;
    const focus_was = doc.focus;
    switch (g.granularity) {
        .char => try doc.setSelection(doc.anchor, b),
        .word => {
            const w = wordAt(s, at.char);
            if (at.char < g.origin.start) {
                try doc.setSelection(g.origin.end, w.start);
            } else {
                try doc.setSelection(g.origin.start, @max(w.end, g.origin.end));
            }
        },
        .all => {},
    }
    return .{ .handled = true, .moved = doc.anchor != anchor_was or doc.focus != focus_was };
}

/// The run of same-class characters containing the one at `b` -- a word, a
/// run of punctuation, or a run of spaces -- which is what a double-click
/// selects. At the end of the text, the run before it.
pub fn wordAt(s: []const u8, b: usize) Range {
    if (s.len == 0) return .{};
    const i = if (b >= s.len) offsets.prevChar(s, s.len) else offsets.alignToChar(s, b);
    // `b` is the character under the pointer (`Hit.char`), not a boundary.
    const class = classAt(s, i);
    var start = i;
    while (start > 0) {
        const p = offsets.prevChar(s, start);
        if (classAt(s, p) != class) break;
        start = p;
    }
    var end = offsets.nextChar(s, i);
    while (end < s.len and classAt(s, end) == class) end = offsets.nextChar(s, end);
    return .{ .start = start, .end = end };
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

/// A pointer exactly on byte `b`: the caret boundary and the character after
/// it agree, which is the case away from a glyph's right half.
fn hit(b: usize) Hit {
    return .{ .caret = b, .char = b };
}

test "one click places the caret, Shift-click extends from the anchor" {
    var d = try docWith("Gõ vào đây: tiếng");
    defer d.deinit();
    const vao = std.mem.indexOf(u8, d.text(), "vào").?;
    _ = try press(&d, hit(vao), 1, false);
    try testing.expectEqual(vao, d.focus);
    try testing.expect(d.selection().isEmpty());
    _ = try press(&d, hit(d.len()), 1, true);
    try testing.expectEqualStrings("vào đây: tiếng", d.text()[d.selection().start..d.selection().end]);
    try testing.expectEqual(vao, d.anchor);
}

test "a click in the middle of a character lands on its start" {
    var d = try docWith("ế");
    defer d.deinit();
    _ = try press(&d, hit(1), 1, false);
    try testing.expectEqual(@as(usize, 0), d.focus);
}

test "a double-click selects the Vietnamese syllable, not a third of it" {
    var d = try docWith("Gõ vào đây: tiếng");
    defer d.deinit();
    // Inside `ế`, which is three bytes and not ASCII: an alphanumeric test
    // would stop the word there.
    const at = std.mem.indexOf(u8, d.text(), "ế").? + 1;
    _ = try press(&d, hit(at), 2, false);
    const sel = d.selection();
    try testing.expectEqualStrings("tiếng", d.text()[sel.start..sel.end]);
    // On the colon: the punctuation run, not a word.
    _ = try press(&d, hit(std.mem.indexOf(u8, d.text(), ":").?), 2, false);
    try testing.expectEqualStrings(":", d.text()[d.selection().start..d.selection().end]);
    // Past the end: the last word.
    _ = try press(&d, hit(d.len()), 2, false);
    try testing.expectEqualStrings("tiếng", d.text()[d.selection().start..d.selection().end]);
}

test "a drag after a double-click extends a word at a time, both ways" {
    var d = try docWith("một hai ba bốn");
    defer d.deinit();
    const s = d.text();
    const hai = std.mem.indexOf(u8, s, "hai").?;
    const p = try press(&d, hit(hai + 1), 2, false);
    // Rightwards into the middle of `bốn`: all of it, and all of `hai`.
    _ = try drag(&d, p.gesture, hit(std.mem.indexOf(u8, s, "ốn").?));
    try testing.expectEqualStrings("hai ba bốn", s[d.selection().start..d.selection().end]);
    // Leftwards into `một`: the word dragged back over, still all of `hai`,
    // and the focus at the far end so Shift+arrows continue from there.
    _ = try drag(&d, p.gesture, hit(2));
    try testing.expectEqualStrings("một hai", s[d.selection().start..d.selection().end]);
    try testing.expectEqual(@as(usize, 0), d.focus);
}

test "a plain drag selects character by character from the press" {
    var d = try docWith("tiếng Việt");
    defer d.deinit();
    const p = try press(&d, hit(0), 1, false);
    _ = try drag(&d, p.gesture, hit(std.mem.indexOf(u8, d.text(), " ").?));
    try testing.expectEqualStrings("tiếng", d.text()[d.selection().start..d.selection().end]);
}

test "a triple-click selects everything" {
    var d = try docWith("tiếng Việt");
    defer d.deinit();
    _ = try press(&d, hit(3), 3, false);
    try testing.expectEqual(@as(usize, d.len()), d.selection().len());
}

test "a click during a composition is refused" {
    var d = try docWith("vi");
    defer d.deinit();
    try d.setComposingRange(.{ .start = 0, .end = 2 });
    try testing.expectError(Error.Locked, press(&d, hit(0), 1, false));
}

test "a double-click on the right half of a word's last letter selects that word" {
    // The nearest caret boundary is after the `g`; the character under the
    // pointer is the `g`. Selecting by the boundary would select the space.
    var d = try docWith("tiếng Việt");
    defer d.deinit();
    const g = std.mem.indexOf(u8, d.text(), "g").?;
    _ = try press(&d, .{ .caret = g + 1, .char = g }, 2, false);
    try testing.expectEqualStrings("tiếng", d.text()[d.selection().start..d.selection().end]);
}

// ------------------------------------------------------ up, down, and Home
//
// A layout built by hand, one glyph per codepoint and all the same width, for
// the same reason `text_layout.zig` does it: the question is which line a byte
// is on, not how wide a `W` is.

const Laid = struct {
    src: std.ArrayList(glyph_mod.Glyph) = .empty,
    buf: text_layout.Buffers = .{},
    w: text_layout.Wrapped = undefined,

    const advance = 10;

    fn deinit(self: *Laid) void {
        self.src.deinit(testing.allocator);
        self.buf.deinit(testing.allocator);
    }

    fn of(self: *Laid, s: []const u8, max_width: f32) !*const text_layout.Wrapped {
        self.src.clearRetainingCapacity();
        var i: usize = 0;
        var k: f32 = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            try self.src.append(testing.allocator, .{
                .dx = k * advance,
                .dy = 0,
                .w = advance,
                .h = 8,
                .u0 = 0,
                .v0 = 0,
                .u1 = 1,
                .v1 = 1,
                .cluster = @intCast(i),
                .pen_x = k * advance,
            });
            i += n;
            k += 1;
        }
        const run: glyph_mod.TextRun = .{
            .glyphs = self.src.items,
            .width = k * advance,
            .ascent = 8,
            .descent = 2,
        };
        self.w = try text_layout.wrap(testing.allocator, run, s, &self.buf, .{ .width = max_width, .line_height = 12 });
        return &self.w;
    }
};

const glyph_mod = @import("glyph.zig");

test "down moves to the line below at the same column" {
    var d = try docWith("one two three");
    defer d.deinit();
    var l: Laid = .{};
    defer l.deinit();
    const w = try l.of(d.text(), 8 * Laid.advance);
    // Two lines: "one two" and "three".
    try testing.expectEqual(@as(usize, 2), w.lines.len);

    try d.setCaret(2); // third character of line 0
    const r = try apply(&d, KeyEvent.named(.down), .{ .lines = w });
    try testing.expect(r.handled and r.moved);
    try testing.expectEqual(@as(usize, 10), d.focus); // third character of line 1
    try testing.expectEqual(@as(?f32, 2 * Laid.advance), r.goal_x);

    const back = try apply(&d, KeyEvent.named(.up), .{ .lines = w, .goal_x = r.goal_x });
    try testing.expect(back.moved);
    try testing.expectEqual(@as(usize, 2), d.focus);
}

test "the column survives a short line instead of drifting left" {
    // The thing a text editor is most noticeably wrong about when it gets
    // this wrong: a caret that passes through a short line and never comes
    // back to where it was.
    var d = try docWith("aaaaaaaa\nbb\ncccccccc");
    defer d.deinit();
    var l: Laid = .{};
    defer l.deinit();
    const w = try l.of(d.text(), 1000);
    try testing.expectEqual(@as(usize, 3), w.lines.len);

    try d.setCaret(6); // seventh character of the first line
    var goal: ?f32 = null;

    const down1 = try apply(&d, KeyEvent.named(.down), .{ .lines = w, .goal_x = goal });
    goal = down1.goal_x;
    // The middle line has two characters, so the caret lands at its end.
    try testing.expectEqual(@as(usize, 11), d.focus);

    const down2 = try apply(&d, KeyEvent.named(.down), .{ .lines = w, .goal_x = goal });
    goal = down2.goal_x;
    // And the column comes back on the long line below. Without the goal it
    // would have stayed at two characters across.
    try testing.expectEqual(@as(usize, 18), d.focus);
    try testing.expectEqual(@as(?f32, 6 * Laid.advance), goal);
}

test "any other movement forgets the column" {
    var d = try docWith("aaaaaaaa\nbb\ncccccccc");
    defer d.deinit();
    var l: Laid = .{};
    defer l.deinit();
    const w = try l.of(d.text(), 1000);

    try d.setCaret(6);
    const down = try apply(&d, KeyEvent.named(.down), .{ .lines = w });
    try testing.expect(down.goal_x != null);
    // A horizontal move reports no column, which is how the caller knows to
    // forget the one it was keeping.
    const left = try apply(&d, KeyEvent.named(.left), .{ .lines = w });
    try testing.expectEqual(@as(?f32, null), left.goal_x);
}

test "up on the first line and down on the last go to the document's ends" {
    var d = try docWith("one\ntwo");
    defer d.deinit();
    var l: Laid = .{};
    defer l.deinit();
    const w = try l.of(d.text(), 1000);

    try d.setCaret(2);
    _ = try apply(&d, KeyEvent.named(.up), .{ .lines = w });
    try testing.expectEqual(@as(usize, 0), d.focus);

    try d.setCaret(5);
    _ = try apply(&d, KeyEvent.named(.down), .{ .lines = w });
    try testing.expectEqual(d.len(), d.focus);
}

test "shift and a vertical arrow extend the selection" {
    var d = try docWith("one two three");
    defer d.deinit();
    var l: Laid = .{};
    defer l.deinit();
    const w = try l.of(d.text(), 8 * Laid.advance);

    try d.setCaret(2);
    _ = try apply(&d, KeyEvent.named(.down).withMods(.{ .shift = true }), .{ .lines = w });
    try testing.expectEqual(@as(usize, 2), d.anchor);
    try testing.expectEqual(@as(usize, 10), d.focus);
    try testing.expectEqualStrings("e two th", d.text()[d.selection().start..d.selection().end]);
}

test "Home is the line, Ctrl+Home is the document" {
    var d = try docWith("one two three");
    defer d.deinit();
    var l: Laid = .{};
    defer l.deinit();
    const w = try l.of(d.text(), 8 * Laid.advance);

    try d.setCaret(10); // on the second line
    _ = try apply(&d, KeyEvent.named(.home), .{ .lines = w });
    try testing.expectEqual(@as(usize, 8), d.focus);

    _ = try apply(&d, KeyEvent.named(.end), .{ .lines = w });
    try testing.expectEqual(d.len(), d.focus);

    try d.setCaret(10);
    _ = try apply(&d, KeyEvent.named(.home).withMods(.{ .ctrl = true }), .{ .lines = w });
    try testing.expectEqual(@as(usize, 0), d.focus);

    _ = try apply(&d, KeyEvent.named(.end).withMods(.{ .ctrl = true }), .{ .lines = w });
    try testing.expectEqual(d.len(), d.focus);
}

test "with no layout, Home and End still mean the document's ends" {
    // The fallback that keeps a field which has never been laid out usable,
    // and the reason the existing tests above did not have to change.
    var d = try docWith("one two three");
    defer d.deinit();
    try d.setCaret(5);
    _ = try apply(&d, KeyEvent.named(.home), .{});
    try testing.expectEqual(@as(usize, 0), d.focus);
    _ = try apply(&d, KeyEvent.named(.end), .{});
    try testing.expectEqual(d.len(), d.focus);
}

test "Cmd+Backspace deletes to the start of the line, not of the document" {
    // The Mac's `deleteToBeginningOfLine:`. With a line table it is the
    // line the caret is drawn on; without one, the document's start, which is
    // what it was before there were lines.
    var d = try docWith("one two three");
    defer d.deinit();
    var l: Laid = .{};
    defer l.deinit();
    const w = try l.of(d.text(), 8 * Laid.advance);
    try d.setCaret(11); // "thr|ee"
    const r = try applyCommand(&d, .{ .op = .delete_to_line_start }, .{ .lines = w });
    try testing.expect(r.edited);
    try testing.expectEqualStrings("one two ee", d.text());

    var d2 = try docWith("one two three");
    defer d2.deinit();
    try d2.setCaret(11);
    _ = try applyCommand(&d2, .{ .op = .delete_to_line_start }, .{});
    try testing.expectEqualStrings("ee", d2.text());
}

test "End on a wrapped line stops at its ink, and on the last line goes past a trailing space" {
    var d = try docWith("one two three ");
    defer d.deinit();
    var l: Laid = .{};
    defer l.deinit();
    const w = try l.of(d.text(), 8 * Laid.advance);
    try testing.expectEqual(@as(usize, 2), w.lines.len);
    try d.setCaret(1);
    _ = try applyCommand(&d, .{ .op = .line_end }, .{ .lines = w });
    // Before the space that wrapped the line: after it is the next line.
    try testing.expectEqual(@as(usize, 7), d.focus);
    try d.setCaret(9);
    _ = try applyCommand(&d, .{ .op = .line_end }, .{ .lines = w });
    try testing.expectEqual(d.len(), d.focus);
    _ = try applyCommand(&d, .{ .op = .line_start }, .{ .lines = w });
    try testing.expectEqual(@as(usize, 8), d.focus);
}
