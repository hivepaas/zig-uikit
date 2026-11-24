//! Converting between the three units four protocols count text in.
//!
//! `docs/text-and-accessibility.md` §1 is the whole reason this file exists,
//! and it is the one requirement from the spikes that is a *shape* rather than
//! a behaviour:
//!
//! ```
//! zwp_text_input_v3   UTF-8 bytes
//! AT-SPI              codepoints
//! Windows BSTR (UIA)  UTF-16 code units
//! TSF "ACP"           UTF-16 code units
//! ```
//!
//! `tiếng việt 🇻🇳` is **23 bytes, 13 codepoints, 15 UTF-16 code units**. ASCII
//! collapses all three to one number, Vietnamese separates bytes from
//! codepoints, and only a non-BMP character separates codepoints from UTF-16
//! units — which is why a toolkit tested in English passes every test it has
//! and then edits the wrong characters on one platform.
//!
//! Windows is internally consistent: its accessibility and its input method
//! both count UTF-16 units, so one number serves both. **Linux is not.**
//! `text-input-v3` counts bytes while AT-SPI counts codepoints, so a Linux text
//! field has to convert between its own two platform protocols. Neither
//! platform's documentation points this out; spike C and spike E did.
//!
//! The document stores **UTF-8 bytes**, because that is what the protocol with
//! no conversion available needs. Everything leaving it converts here, in
//! exactly two functions per unit and nowhere else. Scattering the arithmetic
//! is how `SetText(0..1)` ends up replacing one byte of a three-byte character:
//! the bug does not crash, it silently edits the wrong text, on one platform.

const std = @import("std");

/// How many codepoints precede byte offset `b`.
///
/// `b` must be a character boundary. A continuation byte is not a position any
/// of the four protocols can name, so asking about one is a bug in the caller
/// rather than a value to round.
pub fn byteToChar(s: []const u8, b: usize) usize {
    std.debug.assert(b <= s.len);
    var chars: usize = 0;
    for (s[0..b]) |byte| {
        if (!isContinuation(byte)) chars += 1;
    }
    return chars;
}

/// The byte offset `c` codepoints into `s`, or `s.len` if `c` is past the end.
///
/// Clamping rather than trapping, because this direction takes a number from
/// another process: AT-SPI hands over a character offset computed by a screen
/// reader against a string it last saw some microseconds ago.
pub fn charToByte(s: []const u8, c: usize) usize {
    var chars: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (isContinuation(s[i])) continue;
        if (chars == c) return i;
        chars += 1;
    }
    return s.len;
}

/// How many UTF-16 code units precede byte offset `b`.
///
/// A codepoint above U+FFFF is two units. That is the only difference from
/// `byteToChar`, and it is invisible until someone types an emoji.
pub fn byteToUtf16(s: []const u8, b: usize) usize {
    std.debug.assert(b <= s.len);
    var units: usize = 0;
    var i: usize = 0;
    while (i < b) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        units += if (len == 4) @as(usize, 2) else 1;
        i += len;
    }
    return units;
}

/// The byte offset `u` UTF-16 code units into `s`.
///
/// An offset landing between a surrogate pair resolves to the start of that
/// character, which is the only answer that is a valid byte offset. Input
/// processors do produce such offsets: TSF ranges are arithmetic on numbers it
/// never checks against the encoding.
pub fn utf16ToByte(s: []const u8, u: usize) usize {
    var units: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const width: usize = if (len == 4) 2 else 1;
        // The test is "does `u` fall at or inside this character", not "have
        // we passed it". Stopping only once the count has passed `u` steps
        // over the character an offset inside a surrogate pair belongs to, and
        // answers with the byte offset AFTER it.
        if (units + width > u) return i;
        units += width;
        i += len;
    }
    return s.len;
}

/// The byte offset of the character boundary at or before `b`.
///
/// For taking an offset from somewhere that does not know about UTF-8 and
/// turning it into one this library can use.
pub fn alignToChar(s: []const u8, b: usize) usize {
    var i = @min(b, s.len);
    // Step back while `i` points AT a continuation byte. Looking at `s[i - 1]`
    // instead asks whether the previous byte was a continuation, which is a
    // different question and true for a boundary that follows a multi-byte
    // character.
    while (i > 0 and i < s.len and isContinuation(s[i])) i -= 1;
    return i;
}

/// The character boundary immediately before `b`, or 0.
///
/// Moving a caret left is this, not `b - 1`: one byte back from the end of
/// `ế` lands in the middle of it.
pub fn prevChar(s: []const u8, b: usize) usize {
    if (b == 0) return 0;
    return alignToChar(s, b - 1);
}

/// The character boundary immediately after `b`, or `s.len`.
pub fn nextChar(s: []const u8, b: usize) usize {
    if (b >= s.len) return s.len;
    const seq = std.unicode.utf8ByteSequenceLength(s[b]) catch 1;
    return @min(b + seq, s.len);
}

/// `b` itself when it is a boundary, otherwise the next one after it.
///
/// `alignToChar` rounds down, which is right for a caret and wrong for the end
/// of a range being deleted: rounding the end down can make it smaller than
/// the start.
pub fn alignForward(s: []const u8, b: usize) usize {
    const back = alignToChar(s, b);
    if (back == b or back == s.len) return back;
    const seq = std.unicode.utf8ByteSequenceLength(s[back]) catch 1;
    return @min(back + seq, s.len);
}

fn isContinuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

const testing = std.testing;

/// The example from the specification, which is there because it is the
/// shortest string that separates all three units.
const vi = "tiếng việt 🇻🇳";

test "three units, and they disagree" {
    try testing.expectEqual(@as(usize, 23), vi.len);
    try testing.expectEqual(@as(usize, 13), byteToChar(vi, vi.len));
    try testing.expectEqual(@as(usize, 15), byteToUtf16(vi, vi.len));
}

test "ASCII collapses all three" {
    const s = "hello";
    try testing.expectEqual(@as(usize, 5), byteToChar(s, s.len));
    try testing.expectEqual(@as(usize, 5), byteToUtf16(s, s.len));
    try testing.expectEqual(@as(usize, 3), charToByte(s, 3));
    try testing.expectEqual(@as(usize, 3), utf16ToByte(s, 3));
}

test "every character boundary round-trips in both units" {
    var i: usize = 0;
    while (i <= vi.len) : (i += 1) {
        if (i < vi.len and isContinuation(vi[i])) continue;
        try testing.expectEqual(i, charToByte(vi, byteToChar(vi, i)));
        try testing.expectEqual(i, utf16ToByte(vi, byteToUtf16(vi, i)));
    }
}

test "the emoji is where the two non-byte units part company" {
    // `tiếng việt ` is 11 characters and 15 bytes; the flag follows.
    const before_flag = 15;
    try testing.expectEqual(@as(usize, 11), byteToChar(vi, before_flag));
    try testing.expectEqual(@as(usize, 11), byteToUtf16(vi, before_flag));
    // One regional indicator: one codepoint, two UTF-16 units.
    try testing.expectEqual(@as(usize, 12), byteToChar(vi, before_flag + 4));
    try testing.expectEqual(@as(usize, 13), byteToUtf16(vi, before_flag + 4));
}

test "an offset inside a surrogate pair resolves to the character start" {
    const before_flag = 15;
    // Unit 12 is the low surrogate of the first regional indicator. There is
    // no byte offset for it, so the character's start is the answer.
    try testing.expectEqual(@as(usize, before_flag), utf16ToByte(vi, 12));
}

test "offsets past the end clamp rather than trap" {
    try testing.expectEqual(vi.len, charToByte(vi, 9999));
    try testing.expectEqual(vi.len, utf16ToByte(vi, 9999));
}

test "a byte in the middle of a character aligns backwards" {
    // `ế` starts at byte 2 and is three bytes long.
    try testing.expectEqual(@as(usize, 2), alignToChar(vi, 3));
    try testing.expectEqual(@as(usize, 2), alignToChar(vi, 4));
    try testing.expectEqual(@as(usize, 5), alignToChar(vi, 5));
}
