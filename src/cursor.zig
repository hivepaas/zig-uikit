//! What the pointer looks like.
//!
//! The vocabulary is the platforms' common ground and nothing more: AppKit's
//! `NSCursor` class methods, Wayland's `wp_cursor_shape_v1` names and Win32's
//! `IDC_*` resources all have an arrow and an I-beam, and they agree on what
//! each means. The list grows when something in the toolkit needs a shape --
//! a splitter wants a resize cursor, a link a pointing hand -- and not before,
//! because a shape nothing asks for is a mapping three backends maintain for
//! nobody.
//!
//! Which cursor to show is the application's decision, because only it knows
//! what is under the pointer. The one rule every text field shares is here,
//! so that it is the same on every platform and has a test.

/// | shape   | AppKit                  | Wayland (`wp_cursor_shape_v1`) | Win32       |
/// | ------- | ----------------------- | ------------------------------ | ----------- |
/// | `arrow` | `arrowCursor`           | `default`                      | `IDC_ARROW` |
/// | `text`  | `IBeamCursor`           | `text`                         | `IDC_IBEAM` |
pub const Cursor = enum {
    arrow,
    /// Over text that can be selected or edited: where a click places a caret.
    text,
};

/// The cursor for a pointer over text (or not), while a selection is being
/// dragged (or not).
///
/// The I-beam stays for the whole of a drag that began in text, wherever the
/// pointer goes: the drag is still selecting, and a pointer that turned into
/// an arrow on leaving the field would say it had stopped. Both AppKit's text
/// view and GTK's entry do this.
pub fn forPointer(over_text: bool, selecting: bool) Cursor {
    return if (over_text or selecting) .text else .arrow;
}

test "the I-beam is over text, and for the whole of a drag that began in it" {
    const testing = @import("std").testing;
    try testing.expectEqual(Cursor.text, forPointer(true, false));
    try testing.expectEqual(Cursor.arrow, forPointer(false, false));
    // Dragged out of the field: still selecting, still an I-beam.
    try testing.expectEqual(Cursor.text, forPointer(false, true));
}
