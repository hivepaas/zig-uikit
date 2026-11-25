//! Where a line is allowed to break.
//!
//! In core, linking nothing, and tested against strings rather than against a
//! font: a break opportunity is a property of the text, not of how it was
//! shaped.
//!
//! **This is not UAX #14, and the difference is stated rather than
//! discovered.** The Unicode line breaking algorithm is a pair table over
//! forty-odd classes plus a dozen tailoring rules, and most of it exists for
//! cases this toolkit does not meet yet. What is here is the subset that is
//! *correct* for the text this project has to set:
//!
//!   - after a run of spaces, which is how Latin and Vietnamese break;
//!   - between two ideographs, which is how Chinese and Japanese break;
//!   - after a hyphen;
//!   - at a newline, mandatorily.
//!
//! and the subset that is *not wrong* in the cases it declines to handle: no
//! break before a closing bracket or a trailing comma, and none after an
//! opening bracket, because those are the places a naive "break between any
//! two characters" rule looks broken. Where no opportunity exists the line
//! overflows, which is visible, instead of breaking somewhere a reader would
//! notice.
//!
//! Vietnamese is the case worth saying out loud: its syllables are
//! space-separated, so space breaking *is* correct Vietnamese line breaking.
//! Thai and Khmer are not, and need a dictionary; they are not handled, and
//! their text will overflow rather than break in the middle of a word.

const std = @import("std");

const offsets = @import("offsets.zig");

pub const Class = enum {
    /// A newline: the line ends here and the next one starts after it.
    mandatory,
    space,
    /// Han, Hiragana, Katakana, Hangul syllables: breakable on either side.
    ideograph,
    /// Cannot begin a line: closing brackets, and the punctuation that
    /// follows a word.
    close,
    /// Cannot end a line: opening brackets.
    open,
    /// Breakable after, like a space, but it is ink and stays on the line.
    hyphen,
    other,
};

pub fn classOf(cp: u21) Class {
    switch (cp) {
        '\n', 0x0B, 0x0C, 0x85, 0x2028, 0x2029 => return .mandatory,
        // A carriage return is a break too; a CRLF pair breaks once because
        // the LF that follows starts no new opportunity of its own.
        '\r' => return .mandatory,
        ' ', '\t' => return .space,
        0x1680, 0x2000...0x200A, 0x205F, 0x3000 => return .space,
        // A zero-width space is a break opportunity and nothing else: it is
        // the only way to mark one inside a word.
        0x200B => return .space,
        '-' => return .hyphen,
        // The ones that may not start a line.
        ')', ']', '}', ',', '.', ';', ':', '!', '?', '%' => return .close,
        '"', '\'' => return .close,
        0x2019, 0x201D, 0x3001, 0x3002, 0xFF0C, 0xFF0E, 0xFF09, 0xFF3D => return .close,
        // The ones that may not end a line.
        '(', '[', '{' => return .open,
        0x2018, 0x201C, 0x3008, 0x300A, 0x300C, 0xFF08, 0xFF3B => return .open,
        else => {},
    }
    // A no-break space is not a space for this purpose, which is the whole
    // point of it.
    if (cp == 0xA0 or cp == 0x202F or cp == 0x2011) return .other;

    // CJK, where a break is allowed between any two characters. The ranges
    // are the ones a line breaker needs and not the full set of scripts:
    // CJK Unified Ideographs and its extension A, the compatibility block,
    // Hiragana, Katakana, and Hangul syllables.
    if ((cp >= 0x3040 and cp <= 0x30FF) or
        (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF)) return .ideograph;

    return .other;
}

fn classAt(s: []const u8, b: usize) Class {
    if (b >= s.len) return .other;
    const end = offsets.nextChar(s, b);
    const cp = std.unicode.utf8Decode(s[b..end]) catch return .other;
    return classOf(cp);
}

pub const Opportunity = struct {
    /// The byte offset a line may start at.
    at: usize,
    /// Whether the break is required rather than merely allowed.
    mandatory: bool,
};

/// The next place a line may break **strictly after** `from`, or null when
/// the only one left is the end of the text.
///
/// `from` is a byte offset and the result is the offset the *next* line would
/// start at, so a caller fills a line by asking repeatedly and keeping the
/// last answer that fits. Strictly after, because a caller that passed back
/// the offset it was just given would otherwise be handed it again -- a loop
/// that does not terminate, and the reason this contract is written down.
pub fn next(s: []const u8, from: usize) ?Opportunity {
    if (from >= s.len) return null;
    var i = offsets.nextChar(s, from);
    while (i < s.len) : (i = offsets.nextChar(s, i)) {
        const prev_b = offsets.prevChar(s, i);
        const prev = classAt(s, prev_b);
        const cur = classAt(s, i);

        // A mandatory break takes precedence over every other rule, including
        // the ones about what may not start a line.
        if (prev == .mandatory) {
            // CRLF is one break and not two, so the pair is not split: the
            // guard is on the carriage return, because that is the one with a
            // newline after it. Written the other way round first, which
            // broke between the two and left the line starting with a `\n`.
            if (s[prev_b] == '\r' and s[i] == '\n') continue;
            return .{ .at = i, .mandatory = true };
        }
        if (cur == .mandatory) continue;

        // Nothing may start a line with a closing bracket, and nothing may
        // end one with an opening bracket. Checked before the rules that
        // would otherwise allow a break here.
        if (cur == .close or prev == .open) continue;

        if (prev == .space and cur != .space) return .{ .at = i, .mandatory = false };
        if (prev == .hyphen and cur != .space) return .{ .at = i, .mandatory = false };
        if (prev == .ideograph or cur == .ideograph) {
            if (cur != .space) return .{ .at = i, .mandatory = false };
        }
    }
    return null;
}

/// Where the ink on a line that ends at `b` really stops.
///
/// Trailing spaces hang past the end of the line rather than counting towards
/// its width, which is what every typesetter does: a line ending in a space
/// followed by a word that does not fit should not be made to wrap one word
/// early because of the space.
pub fn trimTrailing(s: []const u8, b: usize) usize {
    var i = @min(b, s.len);
    while (i > 0) {
        const p = offsets.prevChar(s, i);
        const cl = classAt(s, p);
        if (cl != .space and cl != .mandatory) break;
        i = p;
    }
    return i;
}

// ---------------------------------------------------------------------- tests

const testing = std.testing;

fn opportunities(s: []const u8, out: *std.ArrayList(usize)) !void {
    out.clearRetainingCapacity();
    var at: usize = 0;
    while (next(s, at)) |o| {
        try out.append(testing.allocator, o.at);
        at = o.at;
    }
}

fn expectBreaks(s: []const u8, want: []const usize) !void {
    var got: std.ArrayList(usize) = .empty;
    defer got.deinit(testing.allocator);
    try opportunities(s, &got);
    testing.expectEqualSlices(usize, want, got.items) catch |e| {
        std.debug.print("  for \"{s}\": got {any}, want {any}\n", .{ s, got.items, want });
        return e;
    };
}

test "a space is a break opportunity and the break is after it" {
    // "one two" -- the only place a line may start is at `t`.
    try expectBreaks("one two", &.{4});
    // A run of spaces breaks once, after all of them.
    try expectBreaks("one   two", &.{6});
}

test "Vietnamese breaks between syllables, which is where its spaces are" {
    const s = "tiếng Việt rất hay";
    try expectBreaks(s, &.{
        "tiếng ".len,
        "tiếng Việt ".len,
        "tiếng Việt rất ".len,
    });
    // And never inside a syllable, which is what a byte-wise breaker would do.
    for (&[_]usize{ 1, 2, 3, 4 }) |i| {
        var got: std.ArrayList(usize) = .empty;
        defer got.deinit(testing.allocator);
        try opportunities(s, &got);
        try testing.expect(std.mem.indexOfScalar(usize, got.items, i) == null);
    }
}

test "a newline is a mandatory break" {
    const s = "one\ntwo";
    const o = next(s, 0).?;
    try testing.expectEqual(@as(usize, 4), o.at);
    try testing.expect(o.mandatory);
    // And it is the only one.
    try testing.expectEqual(@as(?Opportunity, null), next(s, 4));
}

test "a carriage return and newline together break once" {
    const s = "one\r\ntwo";
    const o = next(s, 0).?;
    try testing.expectEqual(@as(usize, 5), o.at);
    try testing.expect(o.mandatory);
    try testing.expectEqual(@as(?Opportunity, null), next(s, 5));
}

test "a line may not start with a closing bracket or a comma" {
    // Without the rule, "a (b), c" would offer a break before `,` and before
    // `)`. The two it does offer are before `(` and before `c`.
    try expectBreaks("a (b), c", &.{ 2, 7 });
    // And may not end with an opening one: no break between `(` and the space
    // after it, so the opportunities are before `(` and before `b`.
    try expectBreaks("a ( b", &.{ 2, 4 });
}

test "CJK breaks between any two ideographs" {
    const s = "日本語のテキスト";
    var got: std.ArrayList(usize) = .empty;
    defer got.deinit(testing.allocator);
    try opportunities(s, &got);
    // Eight characters of three bytes each: seven opportunities, one before
    // each character after the first.
    try testing.expectEqual(@as(usize, 7), got.items.len);
    for (got.items, 1..) |b, i| try testing.expectEqual(i * 3, b);
}

test "CJK punctuation still may not start a line" {
    // The ideographic comma is a closing class, so no break before it even
    // though its neighbours are ideographs.
    const s = "日本、語";
    var got: std.ArrayList(usize) = .empty;
    defer got.deinit(testing.allocator);
    try opportunities(s, &got);
    // Opportunities before 本 and before 語, but not before 、.
    try testing.expectEqualSlices(usize, &.{ 3, 9 }, got.items);
}

test "a hyphen breaks after itself and a no-break hyphen does not" {
    try expectBreaks("well-known", &.{5});
    // U+2011 NON-BREAKING HYPHEN.
    try expectBreaks("well\u{2011}known", &.{});
}

test "a no-break space is not a break opportunity" {
    try expectBreaks("10\u{00A0}km", &.{});
    try expectBreaks("10 km", &.{3});
}

test "a zero-width space breaks inside a word" {
    // The only way to mark an opportunity where there is no space, which is
    // how a caller tells a breaker about a language it does not know.
    try expectBreaks("ab\u{200B}cd", &.{5});
}

test "no opportunity at all means the line overflows rather than breaks badly" {
    try expectBreaks("supercalifragilistic", &.{});
    try expectBreaks("", &.{});
    try expectBreaks("a", &.{});
}

test "trailing spaces hang past the end of the line" {
    const s = "one two  ";
    try testing.expectEqual(@as(usize, 7), trimTrailing(s, s.len));
    try testing.expectEqual(@as(usize, 3), trimTrailing(s, 4));
    // A newline is trimmed too: the line's ink ends before it.
    try testing.expectEqual(@as(usize, 3), trimTrailing("one\ntwo", 4));
}
