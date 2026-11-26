//! Breaking one shaped run into lines.
//!
//! In core, linking nothing. It takes a `TextRun` that was shaped as a single
//! line and produces one whose glyphs are stacked over several, plus the table
//! a caret and a hit test need. The tests build runs by hand, so they need no
//! font.
//!
//! **The paragraph is shaped once and then sliced, not shaped per line.** The
//! shaper already gave every glyph a pen position and a cluster, so the width
//! of any prefix is a lookup and a line is a range of clusters. Re-shaping
//! each line after choosing where to break would cost a shaping pass per line
//! and is what a layout engine does when it needs the breaks to *change* the
//! shaping -- which happens for scripts where a letter's form depends on its
//! neighbours across the break, and does not happen for Latin or Vietnamese.
//! Saying which is which is better than paying for the general case or
//! pretending the simple one is general.
//!
//! The result is still **one `TextRun`**, with the per-line offsets folded
//! into each glyph's `dy`. Nothing downstream changes: the scene builder emits
//! the same quads it always did, and the element's box grows because
//! `TextRun.height` knows how many lines there are.

const std = @import("std");
const Allocator = std.mem.Allocator;

const glyph = @import("glyph.zig");
const linebreak = @import("linebreak.zig");
const geometry = @import("geometry.zig");

const Glyph = glyph.Glyph;
const TextRun = glyph.TextRun;
const Rect = geometry.Rect;

pub const Line = struct {
    /// The byte range of the source text this line carries, trailing spaces
    /// included: they belong to the line that ends with them, which is what
    /// puts a caret after a space on the right line.
    start: usize,
    end: usize,
    /// The line's glyphs, as a range into the wrapped run.
    first: usize,
    count: usize,
    /// Ink width, which is the width with the trailing spaces trimmed off.
    width: f32,
    /// The top of this line's box, from the paragraph's origin.
    y: f32,
};

/// A wrapped paragraph: the run to draw and the lines to navigate.
///
/// Both slices are borrowed from the lists the caller passed to `wrap`.
pub const Wrapped = struct {
    run: TextRun,
    lines: []const Line,

    pub fn lineCount(self: Wrapped) usize {
        return self.lines.len;
    }

    /// Which line a byte offset is on.
    ///
    /// An offset at a line's end belongs to that line rather than the next,
    /// because that is where a caret that just moved to the end of a line
    /// should be drawn. The exception is the very end of the paragraph.
    pub fn lineOf(self: Wrapped, b: usize) usize {
        for (self.lines, 0..) |ln, i| {
            if (b < ln.end) return i;
            if (b == ln.end) return i;
        }
        return if (self.lines.len == 0) 0 else self.lines.len - 1;
    }

    /// Where a caret immediately before byte `b` sits.
    pub fn caret(self: Wrapped, b: usize) Rect {
        if (self.lines.len == 0) return .{ .x = 0, .y = 0, .w = 0, .h = self.run.height() };
        const i = self.lineOf(b);
        const ln = self.lines[i];
        const at = @min(@max(b, ln.start), ln.end);
        return .{
            .x = self.xOnLine(ln, at),
            .y = ln.y,
            .w = 0,
            .h = self.run.ascent + self.run.descent,
        };
    }

    /// The byte a click at `(x, y)` should move the caret to.
    pub fn byteAt(self: Wrapped, x: f32, y: f32, len: usize) usize {
        if (self.lines.len == 0) return 0;
        return self.byteOnLine(self.lineAtY(y), x, len);
    }

    /// The line a point at height `y` is on: above the first is the first,
    /// below the last is the last.
    pub fn lineAtY(self: Wrapped, y: f32) usize {
        var i: usize = 0;
        while (i + 1 < self.lines.len and y >= self.lines[i + 1].y) i += 1;
        return i;
    }

    /// The character *under* `(x, y)`, not rounded to an edge: what a
    /// double-click selects the word around. `TextRun.clusterAt` for one line
    /// of a paragraph, and for the same reason -- rounding would turn a click
    /// on the right half of a word's last letter into the space after it.
    ///
    /// Before a line's first glyph, its first character. Past its ink, the
    /// line's end, which is the trailing space the line owns; on the last
    /// line, `len`, as `TextRun.clusterAt` says past the end of one line.
    pub fn clusterAt(self: Wrapped, x: f32, y: f32, len: usize) usize {
        if (self.lines.len == 0) return 0;
        const i = self.lineAtY(y);
        const ln = self.lines[i];
        const past = if (i + 1 == self.lines.len) len else ln.end;
        const gs = self.run.glyphs[ln.first..][0..ln.count];
        if (gs.len == 0) return past;
        if (x < gs[0].pen_x) return gs[0].cluster;
        for (gs, 0..) |g, k| {
            // The trailing spaces have glyphs but no ink to be under.
            if (g.cluster >= ln.end) break;
            const next_x = if (k + 1 < gs.len) @min(gs[k + 1].pen_x, ln.width) else ln.width;
            if (x < next_x) return g.cluster;
        }
        return past;
    }

    /// The bytes line `i` owns: from its start to where the next line starts,
    /// trailing spaces included, and to `len` for the last. What a screen
    /// reader reads as "the line" -- it reads the space too, and a line that
    /// lost its space would make the next one start mid-word.
    pub fn lineSpan(self: Wrapped, i: usize, len: usize) struct { start: usize, end: usize } {
        if (self.lines.len == 0) return .{ .start = 0, .end = len };
        const k = @min(i, self.lines.len - 1);
        const end = if (k + 1 < self.lines.len) self.lines[k + 1].start else len;
        return .{ .start = self.lines[k].start, .end = end };
    }

    /// The line whose span holds the character at byte `b`. Not `lineOf`,
    /// which answers where a *caret* before `b` is drawn: a trailing space is
    /// on the line it ends, and the caret after it is on the next.
    pub fn lineOwning(self: Wrapped, b: usize) usize {
        var i: usize = 0;
        while (i + 1 < self.lines.len and b >= self.lines[i + 1].start) i += 1;
        return i;
    }

    /// The byte a caret at `x` should move to on line `i`. What a vertical
    /// arrow key needs: the column is an x, not a character count, because
    /// characters are not all the same width.
    pub fn byteOnLine(self: Wrapped, i: usize, x: f32, len: usize) usize {
        if (self.lines.len == 0) return 0;
        const li = @min(i, self.lines.len - 1);
        const ln = self.lines[li];
        const gs = self.run.glyphs[ln.first..][0..ln.count];
        if (gs.len == 0) return ln.start;
        for (gs, 0..) |g, k| {
            const next_x = if (k + 1 < gs.len) gs[k + 1].pen_x else ln.width;
            if (x >= next_x) continue;
            const mid = (g.pen_x + next_x) * 0.5;
            if (x < mid) return g.cluster;
            return if (k + 1 < gs.len) gs[k + 1].cluster else self.lineEnd(li, len);
        }
        return self.lineEnd(li, len);
    }

    fn lineEnd(self: Wrapped, i: usize, len: usize) usize {
        // The trailing spaces are on this line, but a caret dropped past the
        // end of it belongs before them: a click in the margin should land
        // where the ink stops, not after a space that is not there to see.
        //
        // Except on the last line, where there is no next line for the caret
        // after the space to be drawn on: past the end of the paragraph is
        // its end. A field that ends in a space -- the demo's does, so that
        // typing starts a new word -- otherwise puts a click after the text
        // *before* that space, and the next word typed runs into the last.
        if (i + 1 >= self.lines.len) return len;
        return self.lines[i].end;
    }

    fn xOnLine(self: Wrapped, ln: Line, b: usize) f32 {
        const gs = self.run.glyphs[ln.first..][0..ln.count];
        for (gs) |g| {
            if (g.cluster >= b) return g.pen_x;
        }
        return ln.width;
    }
};

/// Breaks `src` into lines no wider than `max_width`.
///
/// `glyphs` and `lines` are cleared and filled; the returned run borrows the
/// first. A width of zero or less, or a run with no glyphs, produces one line
/// and the original glyphs.
pub fn wrap(
    gpa: Allocator,
    src: TextRun,
    text: []const u8,
    max_width: f32,
    line_height: f32,
    glyphs: *std.ArrayList(Glyph),
    lines: *std.ArrayList(Line),
) Allocator.Error!Wrapped {
    glyphs.clearRetainingCapacity();
    lines.clearRetainingCapacity();
    const lh = if (line_height > 0) line_height else src.height();

    if (src.glyphs.len == 0 or text.len == 0) {
        try lines.append(gpa, .{
            .start = 0,
            .end = 0,
            .first = 0,
            .count = 0,
            .width = 0,
            .y = 0,
        });
        return .{ .run = src, .lines = lines.items };
    }

    try glyphs.ensureTotalCapacity(gpa, src.glyphs.len);

    var start: usize = 0;
    var y: f32 = 0;
    var widest: f32 = 0;
    var gi: usize = 0;

    while (true) {
        const x0 = src.caretX(start);
        const chosen = chooseBreak(src, text, start, x0, max_width);

        // Progress is the one thing that must hold, and it is checked rather
        // than argued: a break that does not advance is an infinite loop, and
        // this file already produced one on the way here.
        std.debug.assert(chosen.next > start);

        const first = glyphs.items.len;
        while (gi < src.glyphs.len and src.glyphs[gi].cluster < chosen.next) : (gi += 1) {
            var g = src.glyphs[gi];
            g.dx -= x0;
            g.pen_x -= x0;
            g.dy += y;
            glyphs.appendAssumeCapacity(g);
        }
        const width = src.caretX(chosen.ink_end) - x0;
        widest = @max(widest, width);
        try lines.append(gpa, .{
            .start = start,
            .end = chosen.ink_end,
            .first = first,
            .count = glyphs.items.len - first,
            .width = width,
            .y = y,
        });

        start = chosen.next;
        y += lh;
        if (start >= text.len) break;
    }

    // Whatever is left: glyphs whose cluster is past the end of the text,
    // which shaping can produce for a trailing mark. They belong to the last
    // line rather than to nothing.
    if (gi < src.glyphs.len and lines.items.len > 0) {
        const last = &lines.items[lines.items.len - 1];
        const x0 = src.caretX(last.start);
        while (gi < src.glyphs.len) : (gi += 1) {
            var g = src.glyphs[gi];
            g.dx -= x0;
            g.pen_x -= x0;
            g.dy += last.y;
            glyphs.appendAssumeCapacity(g);
        }
        last.count = glyphs.items.len - last.first;
    }

    return .{
        .run = .{
            .glyphs = glyphs.items,
            .width = widest,
            .ascent = src.ascent,
            .descent = src.descent,
            .lines = @intCast(lines.items.len),
            .line_height = lh,
        },
        .lines = lines.items,
    };
}

const Break = struct {
    /// Where the ink on this line stops.
    ink_end: usize,
    /// Where the next line starts.
    next: usize,
};

/// The furthest break that still fits, or the first one if none does.
///
/// Greedy, which is what a text field wants: the alternative is Knuth-Plass
/// over the whole paragraph, which is better typesetting and is also a
/// reflow of everything whenever one character changes.
fn chooseBreak(src: TextRun, text: []const u8, start: usize, x0: f32, max_width: f32) Break {
    var at = start;
    var best: Break = .{ .ink_end = start, .next = start };
    var have = false;

    while (true) {
        const o = linebreak.next(text, at);
        const next: usize = if (o) |x| x.at else text.len;
        const mandatory = if (o) |x| x.mandatory else false;
        const ink = linebreak.trimTrailing(text, next);
        const w = src.caretX(ink) - x0;

        if (w <= max_width or max_width <= 0) {
            best = .{ .ink_end = ink, .next = next };
            have = true;
            if (mandatory or o == null) break;
            at = next;
            continue;
        }
        // It overflows. Use the last one that fitted; if nothing did, this
        // one has to be taken anyway, because a word wider than the line has
        // to go somewhere and a line of nothing makes no progress.
        if (!have) best = .{ .ink_end = ink, .next = next };
        break;
    }
    return best;
}

// ---------------------------------------------------------------------- tests
//
// The runs here are built by hand, so none of this needs a font: one glyph per
// codepoint, every one the same width. That is not what real text looks like,
// and it is exactly right for testing a line breaker, where the question is
// which cluster a line ends at and not how wide a `W` is.

const testing = std.testing;

const adv = 10;
const asc = 8;
const desc = 2;

fn fakeRun(s: []const u8, out: *std.ArrayList(Glyph)) !TextRun {
    out.clearRetainingCapacity();
    var i: usize = 0;
    var k: f32 = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        try out.append(testing.allocator, .{
            .dx = k * adv,
            .dy = 0,
            .w = adv,
            .h = asc,
            .u0 = 0,
            .v0 = 0,
            .u1 = 1,
            .v1 = 1,
            .cluster = @intCast(i),
            .pen_x = k * adv,
        });
        i += n;
        k += 1;
    }
    return .{
        .glyphs = out.items,
        .width = k * adv,
        .ascent = asc,
        .descent = desc,
    };
}

const Bits = struct {
    src: std.ArrayList(Glyph) = .empty,
    gl: std.ArrayList(Glyph) = .empty,
    ln: std.ArrayList(Line) = .empty,

    fn deinit(self: *Bits) void {
        self.src.deinit(testing.allocator);
        self.gl.deinit(testing.allocator);
        self.ln.deinit(testing.allocator);
    }

    fn run(self: *Bits, s: []const u8, max_width: f32) !Wrapped {
        const src = try fakeRun(s, &self.src);
        return wrap(testing.allocator, src, s, max_width, 12, &self.gl, &self.ln);
    }
};

/// Every test asserts these, because they are what "a set of lines" means and
/// a breaker that gets them wrong loses or duplicates text.
fn expectWellFormed(w: Wrapped, text: []const u8) !void {
    try testing.expect(w.lines.len > 0);
    var total: usize = 0;
    var prev_end: usize = 0;
    for (w.lines, 0..) |ln, i| {
        try testing.expect(ln.start <= ln.end);
        try testing.expect(ln.end <= text.len);
        if (i > 0) try testing.expect(ln.start >= prev_end);
        try testing.expectEqual(total, ln.first);
        total += ln.count;
        prev_end = ln.end;
    }
    // The lines' glyph ranges partition the run: nothing dropped, nothing
    // counted twice.
    try testing.expectEqual(w.run.glyphs.len, total);
    try testing.expectEqual(@as(u32, @intCast(w.lines.len)), w.run.lines);
}

test "a paragraph that fits stays one line" {
    var b: Bits = .{};
    defer b.deinit();
    const s = "one two";
    const w = try b.run(s, 1000);
    try expectWellFormed(w, s);
    try testing.expectEqual(@as(usize, 1), w.lines.len);
    try testing.expectEqual(@as(f32, 7 * adv), w.lines[0].width);
    // One line, so the height is the bound that cannot clip ink.
    try testing.expectEqual(@as(f32, asc + desc), w.run.height());
}

test "it breaks at a space and the next line starts after it" {
    var b: Bits = .{};
    defer b.deinit();
    const s = "one two three";
    // Room for "one two" but not for "one two three".
    const w = try b.run(s, 8 * adv);
    try expectWellFormed(w, s);
    try testing.expectEqual(@as(usize, 2), w.lines.len);
    try testing.expectEqual(@as(usize, 0), w.lines[0].start);
    try testing.expectEqual(@as(usize, 7), w.lines[0].end);
    try testing.expectEqual(@as(usize, 8), w.lines[1].start);
    try testing.expectEqual(s.len, w.lines[1].end);
}

test "a trailing space does not make a line wrap early" {
    var b: Bits = .{};
    defer b.deinit();
    // Exactly seven characters of room. "one two" is seven, and the space
    // after it would be an eighth if it counted.
    const s = "one two three";
    const w = try b.run(s, 7 * adv);
    try expectWellFormed(w, s);
    try testing.expectEqual(@as(usize, 7), w.lines[0].end);
    try testing.expectEqual(@as(f32, 7 * adv), w.lines[0].width);
}

test "the lines are stacked at the line height and each starts at x zero" {
    var b: Bits = .{};
    defer b.deinit();
    const s = "one two three four";
    const w = try b.run(s, 8 * adv);
    try expectWellFormed(w, s);
    try testing.expect(w.lines.len >= 2);

    for (w.lines, 0..) |ln, i| {
        try testing.expectEqual(@as(f32, @floatFromInt(i)) * 12, ln.y);
        if (ln.count == 0) continue;
        const first = w.run.glyphs[ln.first];
        // Rebased: the first glyph of every line sits at the paragraph's left
        // edge, not at the x it had in the unwrapped run.
        try testing.expectEqual(@as(f32, 0), first.pen_x);
        try testing.expectEqual(ln.y, first.dy);
    }
    // Several lines, so the box is the stack.
    const n: f32 = @floatFromInt(w.lines.len - 1);
    try testing.expectEqual(n * 12 + asc + desc, w.run.height());
}

test "a newline breaks even when the line would have fitted" {
    var b: Bits = .{};
    defer b.deinit();
    const s = "a\nb";
    const w = try b.run(s, 1000);
    try expectWellFormed(w, s);
    try testing.expectEqual(@as(usize, 2), w.lines.len);
    try testing.expectEqual(@as(usize, 1), w.lines[0].end);
    try testing.expectEqual(@as(usize, 2), w.lines[1].start);
}

test "a word wider than the line overflows rather than looping" {
    var b: Bits = .{};
    defer b.deinit();
    // Twenty characters with nowhere to break, in room for three.
    const s = "supercalifragilistic";
    const w = try b.run(s, 3 * adv);
    try expectWellFormed(w, s);
    try testing.expectEqual(@as(usize, 1), w.lines.len);
    try testing.expect(w.lines[0].width > 3 * adv);

    // And a long word after a short one: the short one is its own line, the
    // long one overflows its own.
    const s2 = "a supercalifragilistic";
    const w2 = try b.run(s2, 3 * adv);
    try expectWellFormed(w2, s2);
    try testing.expectEqual(@as(usize, 2), w2.lines.len);
    try testing.expectEqual(@as(usize, 1), w2.lines[0].end);
}

test "Vietnamese wraps between syllables" {
    var b: Bits = .{};
    defer b.deinit();
    const s = "tiếng Việt rất hay";
    // Eleven characters of room: "tiếng Việt" is ten.
    const w = try b.run(s, 11 * adv);
    try expectWellFormed(w, s);
    try testing.expectEqual(@as(usize, 2), w.lines.len);
    try testing.expectEqualStrings("tiếng Việt", s[w.lines[0].start..w.lines[0].end]);
    try testing.expectEqualStrings("rất hay", s[w.lines[1].start..w.lines[1].end]);
    // And never inside a syllable: every line boundary is a character
    // boundary, which a byte-wise breaker would get wrong on `ế`.
    for (w.lines) |ln| {
        try testing.expect(std.unicode.utf8ValidateSlice(s[ln.start..ln.end]));
    }
}

test "the caret lands on the right line at the right x" {
    var b: Bits = .{};
    defer b.deinit();
    const s = "one two three";
    const w = try b.run(s, 8 * adv);

    // Start of the paragraph.
    const c0 = w.caret(0);
    try testing.expectEqual(@as(f32, 0), c0.x);
    try testing.expectEqual(@as(f32, 0), c0.y);
    // End of the first line.
    const c7 = w.caret(7);
    try testing.expectEqual(@as(f32, 7 * adv), c7.x);
    try testing.expectEqual(@as(f32, 0), c7.y);
    // Start of the second.
    const c8 = w.caret(8);
    try testing.expectEqual(@as(f32, 0), c8.x);
    try testing.expectEqual(@as(f32, 12), c8.y);
    // A caret is zero wide and one line tall, not the height of the
    // paragraph.
    try testing.expectEqual(@as(f32, 0), c8.w);
    try testing.expectEqual(@as(f32, asc + desc), c8.h);
}

test "a click finds the byte on the line it was on" {
    var b: Bits = .{};
    defer b.deinit();
    const s = "one two three";
    const w = try b.run(s, 8 * adv);

    // Second line, two and a bit characters across: between `r` and `e`.
    try testing.expectEqual(@as(usize, 10), w.byteAt(2.4 * adv, 12, s.len));
    // Same x on the first line is a different byte.
    try testing.expectEqual(@as(usize, 2), w.byteAt(2.4 * adv, 0, s.len));
    // Past the right edge of a line stops at that line's end, not at the
    // paragraph's.
    try testing.expectEqual(@as(usize, 7), w.byteAt(1000, 0, s.len));
    // Above the first line is the first line.
    try testing.expectEqual(@as(usize, 0), w.byteAt(0, -50, s.len));
}

test "a vertical move keeps the x and changes the line" {
    // What `.up` and `.down` will ask for: the column is an x, because
    // characters are not all the same width and a character count would drift
    // on every line of proportional text.
    var b: Bits = .{};
    defer b.deinit();
    const s = "one two three";
    const w = try b.run(s, 8 * adv);

    // Byte 5 is the `w` of "two", five characters across. Straight down from
    // there is past the end of "three", which is only five characters long,
    // so the caret lands at its end -- also five across.
    const from = w.caret(5);
    try testing.expectEqual(@as(f32, 5 * adv), from.x);
    const down = w.byteOnLine(1, from.x, s.len);
    try testing.expectEqual(s.len, down);

    // And back up from there returns to where it started, because the x did
    // not change. That round trip is the property; the byte offsets either
    // end of it are not equal and have no reason to be.
    try testing.expectEqual(from.x, w.caret(down).x);
    const back = w.byteOnLine(0, w.caret(down).x, s.len);
    try testing.expectEqual(@as(usize, 5), back);
}

test "an empty paragraph is one empty line" {
    var b: Bits = .{};
    defer b.deinit();
    const w = try b.run("", 100);
    try testing.expectEqual(@as(usize, 1), w.lines.len);
    try testing.expectEqual(@as(usize, 0), w.lines[0].count);
    try testing.expectEqual(@as(usize, 0), w.caret(0).x);
    try testing.expectEqual(@as(usize, 0), w.byteAt(50, 50, 0));
}

test "a width of zero does not wrap at every character" {
    // Zero is "no limit" rather than "break everywhere": a caller that has
    // not measured yet gets one line, not one line per glyph.
    var b: Bits = .{};
    defer b.deinit();
    const s = "one two three";
    const w = try b.run(s, 0);
    try expectWellFormed(w, s);
    try testing.expectEqual(@as(usize, 1), w.lines.len);
}

test "past the end of the last line is the end of the paragraph, trailing space included" {
    // The demo's field ends in a space so that typing starts a new word. A
    // click after the text that landed before that space would run the next
    // word into the last one. On a line that is not the last, the caret
    // still stops where the ink does.
    var b: Bits = .{};
    defer b.deinit();
    const s = "one two three ";
    const w = try b.run(s, 8 * adv);
    try testing.expectEqual(@as(usize, 2), w.lines.len);
    try testing.expectEqual(s.len, w.byteAt(1000, 12, s.len));
    try testing.expectEqual(@as(usize, 7), w.byteAt(1000, 0, s.len));
}

test "the character under a point is found on the line the point is on" {
    var b: Bits = .{};
    defer b.deinit();
    const s = "one two three";
    const w = try b.run(s, 8 * adv);
    // The right half of `o` in "two" is still the `o`, not the boundary
    // after it, which is what keeps a double-click on the word.
    try testing.expectEqual(@as(usize, 6), w.clusterAt(6.8 * adv, 0, s.len));
    try testing.expectEqual(@as(usize, 6), w.byteAt(6.4 * adv, 0, s.len));
    // The same x on the second line is the `e` of "three".
    try testing.expectEqual(@as(usize, 11), w.clusterAt(3.8 * adv, 12, s.len));
    // Past the ink of the first line is its trailing space, not the next
    // line's first character; past the last is the end.
    try testing.expectEqual(@as(usize, 7), w.clusterAt(1000, 0, s.len));
    try testing.expectEqual(s.len, w.clusterAt(1000, 12, s.len));
}

test "a line's span is what a screen reader reads, and the space is on the line it ends" {
    var b: Bits = .{};
    defer b.deinit();
    const s = "one two three";
    const w = try b.run(s, 8 * adv);
    const first = w.lineSpan(0, s.len);
    try testing.expectEqualStrings("one two ", s[first.start..first.end]);
    const last = w.lineSpan(1, s.len);
    try testing.expectEqualStrings("three", s[last.start..last.end]);
    // Asked past the last line, the last.
    try testing.expectEqual(last.start, w.lineSpan(9, s.len).start);

    // The space at byte 7 is the first line's. A caret *after* it is drawn
    // on the second line, which is `lineOf`'s answer and a different
    // question.
    try testing.expectEqual(@as(usize, 0), w.lineOwning(7));
    try testing.expectEqual(@as(usize, 1), w.lineOwning(8));
    try testing.expectEqual(@as(usize, 1), w.lineOf(8));
    try testing.expectEqual(@as(usize, 1), w.lineOwning(s.len));
}
