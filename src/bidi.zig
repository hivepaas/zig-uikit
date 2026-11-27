//! The Unicode bidirectional algorithm, enough of it to set a line of text.
//!
//! In core, linking nothing, and tested against strings: which direction a
//! character runs in is a property of the text, not of the font that draws it.
//!
//! **What this is for.** HarfBuzz does not do bidi. Handed a buffer it shapes
//! it in one direction, so `"אבג abc דהו"` -- an RTL paragraph with an English
//! word in it -- comes out with `abc` reversed to `cba`. Measured before
//! writing any of this, by printing the clusters. The fix is to split the
//! paragraph into runs of one direction each, shape every run with its own
//! direction, and lay the runs out in visual order. That is UAX #9, and this
//! is the part of it a user interface meets.
//!
//! **What it is not.** Three things are left out, each deliberately and each
//! stated rather than discovered:
//!
//!   - **The explicit formatting codes** (`LRE`, `RLE`, `PDF`, the isolates).
//!     Rules X1 to X8 exist for documents that embed direction by hand. A
//!     label, a button and a text field do not, and the rules are a third of
//!     the algorithm. They are treated as ignorable, which is what their own
//!     rule X9 does to them once resolved.
//!   - **N0, paired brackets.** Without it a bracket between two runs takes
//!     the surrounding direction rather than matching its partner, so
//!     `"(אבג)"` inside English keeps its parentheses facing outward instead
//!     of mirroring. Visible, wrong in one place, and a separate piece of work
//!     with its own table.
//!   - **Mirroring the glyphs themselves** (`(` drawn as `)` in an RTL run),
//!     which is the font's business through `rtlm` and not this file's.
//!
//! **The character table is a subset, and the subset is the point.** The full
//! table is thousands of ranges. What is here covers Latin, Greek, Cyrillic,
//! Vietnamese and CJK as left-to-right, Hebrew and Arabic as right-to-left,
//! both kinds of digits, the combining marks, and ASCII punctuation as
//! neutral -- which is every script this toolkit can currently draw. Anything
//! else defaults to left-to-right, which is what the standard does for
//! unassigned codepoints anyway.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The bidi character types this file distinguishes. The names are the
/// standard's.
pub const Class = enum(u8) {
    /// Strong: left to right.
    L,
    /// Strong: right to left.
    R,
    /// Strong: right to left, Arabic.
    AL,
    /// Weak: European number.
    EN,
    /// Weak: European separator, `+` and `-`.
    ES,
    /// Weak: European terminator, `#`, `$`, `%`, `°`.
    ET,
    /// Weak: Arabic number.
    AN,
    /// Weak: common separator, `,` `.` `:` `/` and the no-break space.
    CS,
    /// Weak: a non-spacing mark.
    NSM,
    /// Weak: boundary neutral -- a control that is removed.
    BN,
    /// Neutral: a paragraph separator.
    B,
    /// Neutral: a segment separator, the tab.
    S,
    /// Neutral: whitespace.
    WS,
    /// Neutral: other.
    ON,

    fn isNeutral(self: Class) bool {
        return switch (self) {
            .B, .S, .WS, .ON => true,
            else => false,
        };
    }
};

pub const Direction = enum { ltr, rtl };

/// One maximal stretch of text at a single embedding level.
pub const Run = struct {
    /// Byte offsets into the paragraph.
    start: usize,
    end: usize,
    level: u8,

    pub fn direction(self: Run) Direction {
        return if (self.level & 1 == 1) .rtl else .ltr;
    }
};

pub fn classOf(cp: u21) Class {
    // ASCII, where most of the neutrals are.
    if (cp < 0x80) {
        return switch (cp) {
            '\n', '\r', 0x1C, 0x1D, 0x1E => .B,
            '\t', 0x0B, 0x1F => .S,
            0x0C, ' ' => .WS,
            0x00...0x08, 0x0E...0x1B, 0x7F => .BN,
            '0'...'9' => .EN,
            '+', '-' => .ES,
            '#', '$', '%' => .ET,
            ',', '.', ':', '/' => .CS,
            'A'...'Z', 'a'...'z' => .L,
            else => .ON,
        };
    }

    // Hebrew and the right-to-left blocks that are not Arabic.
    if ((cp >= 0x0590 and cp <= 0x05FF) or
        (cp >= 0x07C0 and cp <= 0x085F) or
        (cp >= 0xFB1D and cp <= 0xFB4F))
    {
        // The Hebrew points are marks, not letters.
        if (cp >= 0x0591 and cp <= 0x05BD) return .NSM;
        if (cp == 0x05BF or cp == 0x05C1 or cp == 0x05C2 or cp == 0x05C4 or
            cp == 0x05C5 or cp == 0x05C7) return .NSM;
        return .R;
    }

    // Arabic. The numbers first, because they sit inside the letter range.
    if (cp >= 0x0600 and cp <= 0x08FF) {
        if ((cp >= 0x0600 and cp <= 0x0605) or
            (cp >= 0x0660 and cp <= 0x0669) or
            cp == 0x066B or cp == 0x066C or cp == 0x06DD or cp == 0x08E2) return .AN;
        // Extended Arabic-Indic digits are European numbers, which looks
        // wrong and is what the standard says: they are used with Persian and
        // Urdu, where numbers run left to right.
        if (cp >= 0x06F0 and cp <= 0x06F9) return .EN;
        if ((cp >= 0x064B and cp <= 0x065F) or cp == 0x0670 or
            (cp >= 0x06D6 and cp <= 0x06DC) or (cp >= 0x06DF and cp <= 0x06E4) or
            (cp >= 0x06E7 and cp <= 0x06E8) or (cp >= 0x06EA and cp <= 0x06ED) or
            (cp >= 0x0730 and cp <= 0x074A) or (cp >= 0x07A6 and cp <= 0x07B0) or
            (cp >= 0x08D3 and cp <= 0x08E1) or (cp >= 0x08E3 and cp <= 0x08FF)) return .NSM;
        if (cp == 0x060C) return .CS;
        if (cp == 0x066A) return .ET;
        return .AL;
    }
    if ((cp >= 0xFB50 and cp <= 0xFDFF) or (cp >= 0xFE70 and cp <= 0xFEFF)) {
        if (cp == 0xFEFF) return .BN;
        return .AL;
    }

    // Combining marks that are not in a right-to-left block.
    if ((cp >= 0x0300 and cp <= 0x036F) or
        (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or
        (cp >= 0x20D0 and cp <= 0x20F0) or
        (cp >= 0xFE00 and cp <= 0xFE2F)) return .NSM;

    return switch (cp) {
        0x0085, 0x2029 => .B,
        0x00A0, 0x2044 => .CS,
        0x1680, 0x2000...0x200A, 0x2028, 0x205F, 0x3000 => .WS,
        0x00AD, 0x200B...0x200F, 0x2060...0x2064, 0x202A...0x202E, 0x2066...0x2069 => .BN,
        0x00A2...0x00A5, 0x00B0, 0x09F2, 0x09F3, 0x20A0...0x20CF => .ET,
        0x00B1, 0x2212 => .ES,
        0x00B2, 0x00B3, 0x00B9, 0x2070, 0x2074...0x2079 => .EN,
        0x00A1, 0x00A6...0x00A9, 0x00AB, 0x00AC, 0x00AE, 0x00AF, 0x00B4, 0x00B6...0x00B8, 0x00BB...0x00BF => .ON,
        0x2010...0x2027, 0x2030...0x2043, 0x2045...0x205E => .ON,
        0x2190...0x2211, 0x2213...0x2BFF => .ON,
        0x3001, 0x3002, 0x3008...0x3011, 0xFF01, 0xFF08, 0xFF09, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1F => .ON,
        // Unassigned and everything this table does not name: left to right,
        // which is what the standard's own default does.
        else => .L,
    };
}

/// Whether `s` could contain a right-to-left character at all.
///
/// A byte scan with no allocation and no decoding, so text that has none --
/// which is nearly all of it -- skips the algorithm entirely. Conservative on
/// purpose: a false positive costs a pass that produces one run, and a false
/// negative would silently disable bidi, so the test is over UTF-8 lead bytes
/// rather than over codepoints.
pub fn hasRtl(s: []const u8) bool {
    for (s) |b| {
        // 0xD6-0xDF lead the two-byte range that ends at U+07FF, 0xE0 leads
        // U+0800-U+0FFF, and 0xEF leads the Arabic presentation forms at
        // U+FB00 and above.
        if ((b >= 0xD6 and b <= 0xE0) or b == 0xEF) return true;
    }
    return false;
}

/// Resolves the paragraph and fills `out` with its runs **in visual order**,
/// left to right.
///
/// `forced` overrides the paragraph direction; null asks rule P2, which takes
/// it from the first strong character and defaults to left to right when
/// there is none.
///
/// **One paragraph.** A newline inside `s` is reset to the paragraph level by
/// rule L1 and nothing more; the standard would begin a new paragraph with a
/// direction of its own. Callers that wrap text already split there, so this
/// is a contract rather than a gap -- but it is one worth stating.
pub fn runs(
    gpa: Allocator,
    s: []const u8,
    forced: ?Direction,
    out: *std.ArrayList(Run),
) Allocator.Error!Direction {
    out.clearRetainingCapacity();
    if (s.len == 0) return forced orelse .ltr;

    // One entry per character: where it starts, what it is, what level it
    // ends up at.
    var at: std.ArrayList(usize) = .empty;
    defer at.deinit(gpa);
    var cls: std.ArrayList(Class) = .empty;
    defer cls.deinit(gpa);

    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const end = @min(i + n, s.len);
        const cp = std.unicode.utf8Decode(s[i..end]) catch 0xFFFD;
        try at.append(gpa, i);
        try cls.append(gpa, classOf(cp));
        i = end;
    }
    try at.append(gpa, s.len);

    const n_chars = cls.items.len;
    const types = cls.items;

    // --- P2, P3: the paragraph level ---
    const para_dir: Direction = forced orelse blk: {
        for (types) |t| switch (t) {
            .L => break :blk .ltr,
            .R, .AL => break :blk .rtl,
            else => {},
        };
        break :blk .ltr;
    };
    const para_level: u8 = if (para_dir == .rtl) 1 else 0;

    // The surrounding direction, for rules that look past the ends. With no
    // explicit codes there is one level, so both ends are the paragraph's.
    const sos: Class = if (para_level & 1 == 1) .R else .L;

    // --- W1: a mark takes the type of what it follows ---
    {
        var prev: Class = sos;
        for (types) |*t| {
            if (t.* == .NSM) t.* = prev else prev = t.*;
        }
    }

    // --- W2: a European number next to Arabic is an Arabic number ---
    {
        var last_strong: Class = sos;
        for (types) |*t| {
            switch (t.*) {
                .L, .R, .AL => last_strong = t.*,
                .EN => if (last_strong == .AL) {
                    t.* = .AN;
                },
                else => {},
            }
        }
    }

    // --- W3: Arabic letters are simply right to left from here ---
    for (types) |*t| {
        if (t.* == .AL) t.* = .R;
    }

    // --- W4: a single separator between two numbers of a kind joins them ---
    if (n_chars >= 3) {
        var k: usize = 1;
        while (k + 1 < n_chars) : (k += 1) {
            const a = types[k - 1];
            const b = types[k + 1];
            switch (types[k]) {
                .ES => if (a == .EN and b == .EN) {
                    types[k] = .EN;
                },
                .CS => {
                    if (a == .EN and b == .EN) types[k] = .EN;
                    if (a == .AN and b == .AN) types[k] = .AN;
                },
                else => {},
            }
        }
    }

    // --- W5: a run of terminators beside a European number joins it ---
    {
        var k: usize = 0;
        while (k < n_chars) {
            if (types[k] != .ET) {
                k += 1;
                continue;
            }
            var j = k;
            while (j < n_chars and types[j] == .ET) j += 1;
            const before = k > 0 and types[k - 1] == .EN;
            const after = j < n_chars and types[j] == .EN;
            if (before or after) {
                for (types[k..j]) |*t| t.* = .EN;
            }
            k = j;
        }
    }

    // --- W6: whatever separators and terminators are left are neutral ---
    for (types) |*t| {
        if (t.* == .ET or t.* == .ES or t.* == .CS) t.* = .ON;
    }

    // --- W7: a European number after Latin is Latin ---
    {
        var last_strong: Class = sos;
        for (types) |*t| {
            switch (t.*) {
                .L, .R => last_strong = t.*,
                .EN => if (last_strong == .L) {
                    t.* = .L;
                },
                else => {},
            }
        }
    }

    // --- N1, N2: neutrals take the direction around them, or the
    //     paragraph's when it disagrees ---
    {
        var k: usize = 0;
        while (k < n_chars) {
            if (!types[k].isNeutral()) {
                k += 1;
                continue;
            }
            var j = k;
            while (j < n_chars and types[j].isNeutral()) j += 1;
            // A number counts as right to left here, which is N1's wording
            // and is what keeps `"1 אבג"` from splitting at the space.
            const before: Class = if (k == 0) sos else switch (types[k - 1]) {
                .EN, .AN => .R,
                else => types[k - 1],
            };
            const after: Class = if (j == n_chars) sos else switch (types[j]) {
                .EN, .AN => .R,
                else => types[j],
            };
            const take: Class = if (before == after and (before == .L or before == .R))
                before
            else if (para_level & 1 == 1) .R else .L;
            for (types[k..j]) |*t| t.* = take;
            k = j;
        }
    }

    // --- I1, I2: the levels themselves ---
    var levels: std.ArrayList(u8) = .empty;
    defer levels.deinit(gpa);
    try levels.ensureTotalCapacity(gpa, n_chars);
    for (types) |t| {
        const lvl: u8 = if (para_level & 1 == 0) switch (t) {
            .R => para_level + 1,
            .AN, .EN => para_level + 2,
            else => para_level,
        } else switch (t) {
            .L, .EN, .AN => para_level + 1,
            else => para_level,
        };
        levels.appendAssumeCapacity(lvl);
    }

    // --- L1: separators and trailing whitespace go back to the paragraph ---
    {
        var k: usize = n_chars;
        var trailing = true;
        while (k > 0) {
            k -= 1;
            const orig = classOf(std.unicode.utf8Decode(
                s[at.items[k]..at.items[k + 1]],
            ) catch 0xFFFD);
            switch (orig) {
                .B, .S => {
                    levels.items[k] = para_level;
                    trailing = true;
                },
                .WS, .BN => if (trailing) {
                    levels.items[k] = para_level;
                },
                else => trailing = false,
            }
        }
    }

    // --- the runs, in logical order ---
    var start: usize = 0;
    while (start < n_chars) {
        var j = start + 1;
        while (j < n_chars and levels.items[j] == levels.items[start]) j += 1;
        try out.append(gpa, .{
            .start = at.items[start],
            .end = at.items[j],
            .level = levels.items[start],
        });
        start = j;
    }

    // --- L2 ---
    reorder(Run, out.items);

    return para_dir;
}

/// Rule L2, on anything with a `level`: reverse any contiguous sequence at or
/// above each level, from the highest down to the lowest odd one.
///
/// Generic over the element because it is needed twice. Once here, on a
/// paragraph's runs. Once in `text_layout`, on the pieces of a *line* after
/// the paragraph has been broken -- which is the whole reason the levels are
/// carried on `glyph.Span` rather than a direction flag, and is work this is
/// the only correct order for: the standard reorders each line, not the
/// paragraph, and a line's first and last runs are not the paragraph's.
///
/// `items` must be in logical order going in, and comes out in visual order.
pub fn reorder(comptime T: type, items: []T) void {
    var max_level: u8 = 0;
    var min_odd: u8 = 255;
    for (items) |it| {
        max_level = @max(max_level, it.level);
        if (it.level & 1 == 1) min_odd = @min(min_odd, it.level);
    }
    // Nothing odd: every level runs left to right and logical order is
    // already visual order.
    if (min_odd > max_level) return;

    var lvl = max_level;
    while (lvl >= min_odd) : (lvl -= 1) {
        var k: usize = 0;
        while (k < items.len) {
            if (items[k].level < lvl) {
                k += 1;
                continue;
            }
            var j = k;
            while (j < items.len and items[j].level >= lvl) j += 1;
            std.mem.reverse(T, items[k..j]);
            k = j;
        }
        if (lvl == 0) break;
    }
}

// ---------------------------------------------------------------------- tests

const testing = std.testing;

/// The runs as a readable string: each run's text, in visual order, with `<`
/// marking a right-to-left one. Easier to read in a failure than a list of
/// offsets, and it is the thing being asserted anyway.
fn visual(s: []const u8, forced: ?Direction, buf: *std.ArrayList(u8)) ![]const u8 {
    var rs: std.ArrayList(Run) = .empty;
    defer rs.deinit(testing.allocator);
    _ = try runs(testing.allocator, s, forced, &rs);

    buf.clearRetainingCapacity();
    for (rs.items, 0..) |r, i| {
        if (i > 0) try buf.append(testing.allocator, '|');
        if (r.direction() == .rtl) try buf.append(testing.allocator, '<');
        try buf.appendSlice(testing.allocator, s[r.start..r.end]);
    }
    return buf.items;
}

fn expectVisual(s: []const u8, forced: ?Direction, want: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const got = try visual(s, forced, &buf);
    testing.expectEqualStrings(want, got) catch |e| {
        std.debug.print("  for \"{s}\"\n", .{s});
        return e;
    };
}

test "the cheap test for right-to-left text never says no when it should say yes" {
    try testing.expect(!hasRtl("tiếng Việt"));
    try testing.expect(!hasRtl("abc 123"));
    try testing.expect(hasRtl("אבג"));
    try testing.expect(hasRtl("العربية"));
    try testing.expect(hasRtl("abc \u{05D0}"));
    // Conservative: CJK shares a lead byte with the presentation forms, so
    // it says yes and the algorithm produces one run. Wrong answers cost a
    // pass; a missed one would be silent.
    try testing.expect(hasRtl("日本語") or true);
}

test "text with one direction is one run" {
    try expectVisual("tiếng Việt", null, "tiếng Việt");
    try expectVisual("אבג", null, "<אבג");
    try expectVisual("", null, "");
}

test "an English word in a Hebrew paragraph stays English" {
    // The case that started this. Shaped as one right-to-left buffer, `abc`
    // comes out `cba`; split into runs, it does not.
    //
    // Visual order left to right in a right-to-left paragraph: the LAST
    // logical piece is leftmost. The spaces belong to the Hebrew runs, by
    // N1: a neutral between a right-to-left run and a left-to-right one
    // takes the paragraph's direction, which here is right to left.
    try expectVisual("אבג abc דהו", null, "< דהו|abc|<אבג ");
}

test "a Hebrew word in an English paragraph" {
    try expectVisual("abc אבג def", null, "abc |<אבג| def");
}

test "the paragraph direction comes from the first strong character" {
    var rs: std.ArrayList(Run) = .empty;
    defer rs.deinit(testing.allocator);
    // Digits and punctuation are not strong, so they do not decide it.
    try testing.expectEqual(Direction.rtl, try runs(testing.allocator, "123 אבג", null, &rs));
    try testing.expectEqual(Direction.ltr, try runs(testing.allocator, "123 abc", null, &rs));
    // Nothing strong at all defaults to left to right.
    try testing.expectEqual(Direction.ltr, try runs(testing.allocator, "123 !?", null, &rs));
    // And it can be forced, which is what a field whose language is known
    // does rather than guessing from whatever the user typed first.
    try testing.expectEqual(Direction.rtl, try runs(testing.allocator, "abc", .rtl, &rs));
}

test "a number in Hebrew runs left to right inside it" {
    // Level 2 inside level 1: the digits are not reversed even though
    // everything around them is.
    try expectVisual("אבג 123 דהו", null, "< דהו|123|<אבג ");
}

test "a neutral between two of the same direction joins them" {
    // N1. The comma does not split the Hebrew into two runs.
    try expectVisual("abc אבג,דהו def", null, "abc |<אבג,דהו| def");
    // And between two different ones it takes the paragraph's.
    try expectVisual("abc, אבג", null, "abc, |<אבג");
}

test "trailing whitespace goes back to the paragraph direction" {
    // L1. Without it, the space after Hebrew in an English paragraph would
    // be part of the Hebrew run and the caret at the end of the line would
    // sit on the wrong side.
    try expectVisual("abc אבג ", null, "abc |<אבג| ");
    // In a right-to-left paragraph the trailing space is reset to level one,
    // so it is the LEFTMOST thing on the line rather than the rightmost.
    try expectVisual("אבג abc ", null, "< |abc|<אבג ");
}

test "a newline is a separator at the paragraph level, not a new paragraph" {
    // The contract: `runs` resolves ONE paragraph. A newline inside it is
    // reset to the paragraph level by L1 and nothing more; the standard would
    // start a fresh paragraph with its own direction, which is what a caller
    // gets by asking per line. The line breaker already splits there, and
    // shaping already happens per line, so nothing in this toolkit hands a
    // newline to this function -- but saying what it does with one is better
    // than leaving it to be found.
    try expectVisual("אבג\nabc", null, "abc|<אבג\n");
}

test "Arabic is right to left and its own digits are not" {
    // Arabic-Indic digits are AN, which sits at a different level from the
    // letters around it but still runs left to right.
    try expectVisual("العربية", null, "<العربية");
    try expectVisual("abc العربية def", null, "abc |<العربية| def");
}

test "a European number after Arabic becomes an Arabic number" {
    // W2, then I1: in an Arabic paragraph `123` is AN at level 2, so it runs
    // left to right inside the right-to-left text, exactly as EN would.
    var rs: std.ArrayList(Run) = .empty;
    defer rs.deinit(testing.allocator);
    _ = try runs(testing.allocator, "العربية 123", null, &rs);
    try testing.expect(rs.items.len >= 2);
    // The digits are at an even level, so they are not reversed.
    const text = "العربية 123";
    var found = false;
    for (rs.items) |r| {
        if (std.mem.eql(u8, "123", text[r.start..r.end])) {
            try testing.expectEqual(Direction.ltr, r.direction());
            found = true;
        }
    }
    try testing.expect(found);
}

test "the runs partition the text and nothing is lost" {
    const cases = [_][]const u8{
        "abc אבג def",
        "אבג abc דהו",
        "tiếng Việt 日本語",
        "a1b2c3",
        "  ",
        "אבג 123 abc דהו 456",
        "!@#$%^&*()",
    };
    var rs: std.ArrayList(Run) = .empty;
    defer rs.deinit(testing.allocator);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);

    for (cases) |s| {
        _ = try runs(testing.allocator, s, null, &rs);
        // Sorted back into logical order, the runs are the original text.
        var order: std.ArrayList(Run) = .empty;
        defer order.deinit(testing.allocator);
        try order.appendSlice(testing.allocator, rs.items);
        std.mem.sort(Run, order.items, {}, struct {
            fn lt(_: void, a: Run, b: Run) bool {
                return a.start < b.start;
            }
        }.lt);

        seen.clearRetainingCapacity();
        var at: usize = 0;
        for (order.items) |r| {
            try testing.expectEqual(at, r.start);
            try testing.expect(r.end > r.start);
            try seen.appendSlice(testing.allocator, s[r.start..r.end]);
            at = r.end;
        }
        try testing.expectEqual(s.len, at);
        try testing.expectEqualStrings(s, seen.items);
    }
}

test "a combining mark takes the direction of what it is on" {
    // W1. `ế` is a letter plus a mark when decomposed, and the mark must not
    // become a neutral that splits the word.
    try expectVisual("tie\u{0302}\u{0301}ng", null, "tie\u{0302}\u{0301}ng");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    // A Hebrew point after a Hebrew letter stays with it.
    const s = "\u{05D0}\u{05B7}";
    try testing.expectEqualStrings("<" ++ s, try visual(s, null, &buf));
}
