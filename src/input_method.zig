//! One atomic change from an input method, applied to a `Document`.
//!
//! `zwp_text_input_v3` is double-buffered: `preedit_string`, `commit_string`
//! and `delete_surrounding_text` all modify *pending* state, and `done`
//! replaces the current state with it. Applying each event as it arrives is
//! the bug that produces flicker and doubled characters during composition, so
//! the platform layer accumulates a `Change` and this applies it.
//!
//! In core, linking nothing, for the usual reason: the whole protocol state
//! machine is then testable against a document in memory, and spike B's
//! self-test -- 21 assertions it wrote because ibus-bamboo in its default mode
//! never reaches half these paths -- comes along with it.
//!
//! **The order is fixed by the protocol and is not arbitrary.** Drop the old
//! preedit, delete the surrounding text, insert the commit string, then
//! install the new preedit. Doing the delete after the insert is what makes
//! Telex eat the wrong character: ibus-bamboo asks to delete what is already
//! committed *before* committing its replacement, so `a` + delete(1) +
//! commit("ă") has to leave `ă` and not something built out of both.

const std = @import("std");

const document = @import("document.zig");
const offsets = @import("offsets.zig");

const Document = document.Document;
const Range = document.Range;

pub const Error = document.Error;

/// What `done` says to apply, gathered from the events before it.
///
/// The strings are borrowed from whoever assembled the change and need to
/// outlive only the call to `apply`.
pub const Change = struct {
    /// Bytes to remove before and after the cursor. **Bytes**, because that is
    /// the unit the protocol states -- `ă` is two of them, and an
    /// implementation that treats these as characters passes every ASCII test
    /// and corrupts text the moment a diacritic appears.
    delete_before: u32 = 0,
    delete_after: u32 = 0,

    /// Text to insert at the cursor. Null and empty mean different things:
    /// null is "no commit_string event arrived", empty is one that arrived
    /// carrying nothing.
    commit: ?[]const u8 = null,

    /// The new preedit, which never enters the document.
    preedit: ?[]const u8 = null,
    /// The caret inside the preedit, in bytes within it. The protocol sends
    /// -1 for "no caret", which arrives here as null.
    preedit_cursor: ?Range = null,

    pub fn isEmpty(self: Change) bool {
        return self.delete_before == 0 and self.delete_after == 0 and
            self.commit == null and self.preedit == null;
    }
};

pub const Result = struct {
    /// The document's own bytes changed.
    ///
    /// This is the flag the resync rule turns on, and getting it wrong is an
    /// infinite loop rather than a glitch. Re-sending `set_surrounding_text`
    /// makes the compositor emit another `done`; if a preedit-only change
    /// counted as a document change, each `done` would cause the next and the
    /// client would spin at full speed. A preedit is not part of surrounding
    /// text, so there is nothing new to tell the input method about.
    document_changed: bool = false,
    /// The preedit changed, so the line has to be laid out again even though
    /// the document did not.
    preedit_changed: bool = false,
};

/// Applies a `done`.
pub fn apply(doc: *Document, ch: Change) Error!Result {
    var r: Result = .{};

    // 1. Drop the old preedit. It was never in the document, so this is a
    //    display change and nothing else -- but it has to happen first,
    //    because the deletion below counts bytes from the cursor and the
    //    cursor is where the preedit was being shown.
    const had_preedit = doc.preedit.items.len > 0;
    if (had_preedit) {
        try doc.setPreedit("");
        r.preedit_changed = true;
    }

    // 2. Delete the surrounding text. Byte counts from another process, so
    //    `deleteSurrounding` aligns them to character boundaries rather than
    //    trusting them; a length that would split `ế` snaps instead of
    //    leaving the buffer holding invalid UTF-8.
    if (ch.delete_before > 0 or ch.delete_after > 0) {
        const e = try doc.deleteSurrounding(.input_method, ch.delete_before, ch.delete_after);
        if (!e.isEmpty()) r.document_changed = true;
    }

    // 3. Insert the commit string, caret after it.
    if (ch.commit) |s| {
        if (s.len > 0 or !doc.selection().isEmpty()) {
            const e = try doc.insert(.input_method, s);
            if (!e.isEmpty()) r.document_changed = true;
        }
    }

    // 4. Install the new preedit.
    if (ch.preedit) |s| {
        if (s.len > 0 or had_preedit) {
            try doc.setPreedit(s);
            if (ch.preedit_cursor) |pc| doc.setPreeditCursor(pc.start, pc.end);
            r.preedit_changed = true;
        }
    } else if (ch.commit != null and had_preedit) {
        // A commit with no new preedit ends the composition. Without this the
        // document stays `composition_active` forever and every application
        // edit after it is refused with `error.Locked`.
        doc.endComposition();
    }

    return r;
}

// ------------------------------------------------------- surrounding text

/// What `set_surrounding_text` sends: a window of the document and the
/// selection within it.
pub const Surrounding = struct {
    /// Borrowed from the document.
    text: []const u8,
    /// Byte offsets **into `text`**, not into the document.
    cursor: u32,
    anchor: u32,
};

/// The most a `set_surrounding_text` may carry.
///
/// A Wayland message cannot exceed 4096 bytes in total, so the protocol's own
/// note is that the text has to be shorter than that. 2000 leaves room for the
/// message header and for the other requests in the same commit, and it is
/// what spike B measured a 2 740-byte document against.
pub const max_surrounding = 2000;

/// The surrounding text for a document, windowed around the cursor.
///
/// **The preedit is not in it.** It is not part of the document, and sending
/// it is the mistake that produces doubled characters that only appear
/// mid-composition -- the input method sees its own uncommitted text coming
/// back as context.
pub fn surrounding(doc: *const Document, max_bytes: usize) Surrounding {
    const s = doc.text();
    if (s.len <= max_bytes) {
        return .{
            .text = s,
            .cursor = @intCast(doc.focus),
            .anchor = @intCast(doc.anchor),
        };
    }

    // A window centred on the cursor, snapped outward to character
    // boundaries. Snapping the start backwards and the end forwards can make
    // the window a few bytes longer than asked for, which is why the limit
    // above has room to spare.
    const half = max_bytes / 2;
    var start = offsets.alignToChar(s, doc.focus -| half);
    var end = offsets.alignForward(s, @min(start + max_bytes, s.len));
    if (end - start > max_bytes) start = offsets.alignForward(s, end - max_bytes);
    if (start > doc.focus) start = offsets.alignToChar(s, doc.focus);
    if (end < doc.focus) end = offsets.alignForward(s, doc.focus);

    // The anchor can be outside the window when a long selection is open.
    // Clamped, because the protocol's offsets index the text that was sent and
    // an offset past its end is not representable at all.
    const anchor = std.math.clamp(doc.anchor, start, end);
    return .{
        .text = s[start..end],
        .cursor = @intCast(doc.focus - start),
        .anchor = @intCast(anchor - start),
    };
}

/// What `set_text_change_cause` reports. The input method needs to know
/// whether it caused a change itself, because its own edit is not news.
pub const ChangeCause = enum { input_method, other };

// ---------------------------------------------------------------------- tests
//
// Transcribed from spike B's self test, which exists because ibus-bamboo's
// default input mode keeps a whole syllable in the preedit and commits only
// the finished result -- so a real typing session, however long, never sends
// `delete_surrounding_text` at all. The more dangerous of the two hazards is
// the one typing cannot reach.

const testing = std.testing;

fn emptyDoc() Document {
    return Document.init(testing.allocator);
}

test "a preedit leaves the document empty, twice over" {
    var d = emptyDoc();
    defer d.deinit();

    const r1 = try apply(&d, .{ .preedit = "a" });
    try testing.expectEqualStrings("", d.text());
    try testing.expect(r1.preedit_changed and !r1.document_changed);

    const r2 = try apply(&d, .{ .preedit = "ă" });
    try testing.expectEqualStrings("", d.text());
    try testing.expect(r2.preedit_changed and !r2.document_changed);

    // And it is shown at the caret without being in the buffer.
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(testing.allocator);
    const shown = try d.displayText(&scratch);
    try testing.expectEqualStrings("ă", shown.text);
    try testing.expectEqual(@as(usize, 0), shown.composing.?.start);
}

test "a preedit-only change asks for no resync, a document change asks for one" {
    // The infinite loop, pinned. Re-sending surrounding text makes the
    // compositor send another `done`; if a preedit counted as a document
    // change, each `done` would cause the next one.
    var d = emptyDoc();
    defer d.deinit();

    try testing.expect(!(try apply(&d, .{ .preedit = "tie" })).document_changed);
    try testing.expect(!(try apply(&d, .{ .preedit = "tieng" })).document_changed);
    try testing.expect((try apply(&d, .{ .commit = "tiếng" })).document_changed);
    try testing.expectEqualStrings("tiếng", d.text());
}

test "delete one byte then commit two leaves exactly ă" {
    // Hazard 1, the Telex case, which no amount of typing in bamboo's default
    // mode reaches. `a` is one byte and `ă` is two.
    var d = emptyDoc();
    defer d.deinit();
    _ = try d.insert(.application, "a");

    _ = try apply(&d, .{ .delete_before = 1, .commit = "ă" });
    try testing.expectEqualStrings("ă", d.text());
    try testing.expectEqual(@as(usize, 2), d.len());
    try testing.expectEqual(d.len(), d.focus);
}

test "the delete happens before the insert, not after" {
    var d = emptyDoc();
    defer d.deinit();
    _ = try d.insert(.application, "xa");

    // Reversed, this inserts first and then deletes a byte of what it just
    // inserted, which is how Telex ends up eating the wrong character.
    _ = try apply(&d, .{ .delete_before = 1, .commit = "ă" });
    try testing.expectEqualStrings("xă", d.text());
    try testing.expect(std.unicode.utf8ValidateSlice(d.text()));
}

test "deleting three bytes removes exactly one three-byte character" {
    var d = emptyDoc();
    defer d.deinit();
    _ = try d.insert(.application, "tiế");

    _ = try apply(&d, .{ .delete_before = 3 });
    try testing.expectEqualStrings("ti", d.text());
}

test "a delete that would split a character snaps instead of corrupting" {
    // A compositor should never send this. If one does, the document has to
    // survive it: a buffer holding half of `ế` is not UTF-8 at all, and
    // everything downstream -- shaping, the accessibility tree, the next
    // surrounding-text message -- is then operating on bytes that cannot be
    // decoded.
    var d = emptyDoc();
    defer d.deinit();
    _ = try d.insert(.application, "tiế");

    _ = try apply(&d, .{ .delete_before = 1 });
    try testing.expect(std.unicode.utf8ValidateSlice(d.text()));
    // Snapped **outward**, to the whole character. Spike B snapped inward and
    // deleted nothing -- its log reads `(1,0) snapped to (0,0)` -- and this
    // deliberately does the opposite. An input method sending a split count
    // has miscounted bytes for characters, so it believes a character is gone;
    // deleting nothing leaves its idea of the document permanently ahead of
    // the real one, and every later offset it sends is wrong. Deleting the
    // character it meant costs at most two bytes more than it asked for and
    // keeps the two in step. Either way the buffer stays valid UTF-8, which
    // is the part that is not negotiable.
    try testing.expectEqualStrings("ti", d.text());
}

test "a commit with no new preedit ends the composition" {
    var d = emptyDoc();
    defer d.deinit();

    _ = try apply(&d, .{ .preedit = "vieejt" });
    try testing.expect(d.composition_active);
    // While it is active the application cannot edit, which is §6.
    try testing.expectError(document.Error.Locked, d.insert(.application, "x"));

    _ = try apply(&d, .{ .commit = "việt" });
    try testing.expect(!d.composition_active);
    try testing.expectEqualStrings("việt", d.text());
    _ = try d.insert(.application, "!");
    try testing.expectEqualStrings("việt!", d.text());
}

test "the preedit caret is a position inside the preedit, and can be absent" {
    var d = emptyDoc();
    defer d.deinit();
    _ = try d.insert(.application, "ti");

    _ = try apply(&d, .{ .preedit = "ếng", .preedit_cursor = .{ .start = 3, .end = 3 } });
    // Three bytes into the preedit, which is two bytes into the document plus
    // the three bytes of `ế`.
    try testing.expectEqual(@as(?usize, 5), d.displayCaret());

    // No caret requested: the input method is showing a candidate list and
    // does not want one drawn.
    _ = try apply(&d, .{ .preedit = "ếng" });
    try testing.expectEqual(@as(?usize, null), d.displayCaret());
}

test "the full Telex sequence, as spike B logged it" {
    // `a` `w` `s` -> `ắ`, through the events the compositor actually sent.
    var d = emptyDoc();
    defer d.deinit();

    _ = try apply(&d, .{ .preedit = "a" });
    _ = try apply(&d, .{ .preedit = "ă" });
    _ = try apply(&d, .{ .preedit = "ắ" });
    try testing.expectEqualStrings("", d.text());

    _ = try apply(&d, .{ .commit = "ắ" });
    try testing.expectEqualStrings("ắ", d.text());
    try testing.expectEqual(@as(usize, 3), d.len());
    try testing.expectEqual(@as(usize, 1), offsets.byteToChar(d.text(), d.len()));
}

test "surrounding text excludes the preedit" {
    // Hazard 2. Sending the preedit back as context is what produces doubled
    // characters mid-composition.
    var d = emptyDoc();
    defer d.deinit();
    _ = try d.insert(.application, "tiếng ");
    _ = try apply(&d, .{ .preedit = "Vieejt" });

    const s = surrounding(&d, max_surrounding);
    try testing.expectEqualStrings("tiếng ", s.text);
    try testing.expectEqual(@as(u32, 8), s.cursor);
    try testing.expectEqual(s.cursor, s.anchor);
}

test "surrounding text carries a selection, not just a caret" {
    var d = emptyDoc();
    defer d.deinit();
    _ = try d.insert(.application, "tiếng Việt");
    try d.setSelection(8, 0);

    const s = surrounding(&d, max_surrounding);
    try testing.expectEqual(@as(u32, 8), s.anchor);
    try testing.expectEqual(@as(u32, 0), s.cursor);
}

test "a document past the window is sent as a window around the cursor" {
    var d = emptyDoc();
    defer d.deinit();
    // 2 740 bytes of multi-byte text, the size spike B used.
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(testing.allocator);
    while (long.items.len < 2740) try long.appendSlice(testing.allocator, "tiếng Việt ");
    _ = try d.insert(.application, long.items);
    try d.setCaret(offsets.alignToChar(d.text(), d.len() / 2));

    const s = surrounding(&d, max_surrounding);
    try testing.expect(s.text.len <= max_surrounding + 4);
    try testing.expect(s.text.len < d.len());
    // The things that must hold whatever the window is: it is valid UTF-8, and
    // both offsets are inside it.
    try testing.expect(std.unicode.utf8ValidateSlice(s.text));
    try testing.expect(s.cursor <= s.text.len);
    try testing.expect(s.anchor <= s.text.len);
    // And the cursor really is where the caret is: the text on either side of
    // it matches the document on either side of the caret.
    const at = d.focus;
    try testing.expectEqualStrings(
        d.text()[at - 10 .. at],
        s.text[s.cursor - 10 .. s.cursor],
    );
}

test "an empty change changes nothing and asks for nothing" {
    var d = emptyDoc();
    defer d.deinit();
    _ = try d.insert(.application, "tiếng");

    const r = try apply(&d, .{});
    try testing.expect(!r.document_changed and !r.preedit_changed);
    try testing.expect((Change{}).isEmpty());
    try testing.expectEqualStrings("tiếng", d.text());
}

test "an input method may write while a composition is active" {
    // The §6 guard is asymmetric on purpose: the application is locked out
    // during composition and the processor is not. A symmetric guard would
    // mean the input method could not commit its own preedit.
    var d = emptyDoc();
    defer d.deinit();
    _ = try apply(&d, .{ .preedit = "a" });
    try testing.expect(!d.canEditNow());

    const r = try apply(&d, .{ .delete_before = 0, .commit = "ă", .preedit = "" });
    try testing.expect(r.document_changed);
    try testing.expectEqualStrings("ă", d.text());
}
