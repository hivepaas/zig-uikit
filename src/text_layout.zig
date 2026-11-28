//! Breaking one shaped run into lines.
//!
//! In core, linking nothing outside it. It takes a `TextRun` that was shaped
//! as a single line and produces one whose glyphs are stacked over several,
//! plus the table a caret and a hit test need. The tests build runs by hand,
//! so they need no font.
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
//!
//! **Mixed-direction text takes the long way round.** A paragraph that mixes
//! directions has been laid out in visual order by the shaper, so its clusters
//! are not monotonic and a line is not a slice of it: taking every glyph whose
//! cluster is before the break picks glyphs from all over the paragraph. UAX #9
//! gives the order to work in -- resolve the paragraph, break it into lines,
//! then reorder *each line* -- and that is what happens here: breaking
//! measures widths as sums of advances in logical order, and each line is
//! assembled by clipping the paragraph's direction runs to it and reordering
//! the pieces by rule L2. The shaping is still done once for the paragraph,
//! because breaking inside a direction run does not change it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const bidi = @import("bidi.zig");
const glyph = @import("glyph.zig");
const linebreak = @import("linebreak.zig");
const geometry = @import("geometry.zig");

const Glyph = glyph.Glyph;
const Span = glyph.Span;
const TextRun = glyph.TextRun;
const Rect = geometry.Rect;

/// Which edge of its box a paragraph's lines are set against.
///
/// `start` and `end` are the paragraph's own: the start of a right-to-left
/// paragraph is its right-hand edge. They are the pair worth defaulting to,
/// because an application that does not know which direction the text it was
/// handed runs in still gets it right -- and almost no application knows.
///
/// Justification is not here. Stretching a line to both edges means deciding
/// where the slack goes -- between words, inside them, or by stretching the
/// glyphs -- and in a script with joined letters it is a shaping decision
/// rather than a spacing one. It is a different piece of work, not a fifth
/// value of this.
pub const Align = enum {
    start,
    end,
    left,
    right,
    center,

    /// What it means for a paragraph at this embedding level: even levels run
    /// left to right, odd ones right to left.
    pub fn resolve(self: Align, base_level: u8) enum { left, right, center } {
        const rtl = base_level & 1 == 1;
        return switch (self) {
            .left => .left,
            .right => .right,
            .center => .center,
            .start => if (rtl) .right else .left,
            .end => if (rtl) .left else .right,
        };
    }
};

/// What to break to, and how to set what comes out.
pub const Options = struct {
    /// The width to break at, and the box the lines are aligned in. Zero or
    /// less means no limit: one line, and nothing to align it against.
    width: f32,
    /// The pitch to stack lines at. Zero takes the run's own height, which is
    /// what a run with no font behind it has.
    line_height: f32 = 0,
    alignment: Align = .start,
};

pub const Line = struct {
    /// The byte range of the source text this line carries, trailing spaces
    /// included: they belong to the line that ends with them, which is what
    /// puts a caret after a space on the right line.
    start: usize,
    end: usize,
    /// The line's glyphs, as a range into the wrapped run.
    first: usize,
    count: usize,
    /// Where this line's ink starts, from the paragraph's left edge. Zero
    /// unless the paragraph is aligned somewhere other than its left.
    ///
    /// Already added into the glyphs; it is kept because a hit test past the
    /// end of a line needs to know where the line *is*, not only how wide it
    /// is.
    x: f32 = 0,
    /// Ink width, which is the width with the trailing spaces trimmed off.
    width: f32,
    /// The top of this line's box, from the paragraph's origin.
    y: f32,
    /// This line's direction stretches, as a range into `Wrapped.spans`, in
    /// visual order.
    ///
    /// A count of zero means one left-to-right stretch covering the whole
    /// line, which is what every line of plain text is -- so plain text
    /// produces no table at all and pays nothing for the general case.
    span_first: usize = 0,
    span_count: usize = 0,
};

/// The three lists a wrapped paragraph lives in.
///
/// One struct rather than three parameters because the caller holds them
/// across frames and hands the same ones back every time the text changes; a
/// fourth buffer should not be a change at every call site.
pub const Buffers = struct {
    glyphs: std.ArrayList(Glyph) = .empty,
    lines: std.ArrayList(Line) = .empty,
    spans: std.ArrayList(Span) = .empty,

    pub fn deinit(self: *Buffers, gpa: Allocator) void {
        self.glyphs.deinit(gpa);
        self.lines.deinit(gpa);
        self.spans.deinit(gpa);
    }
};

/// A wrapped paragraph: the run to draw and the lines to navigate.
///
/// The slices are borrowed from the `Buffers` the caller passed to `wrap`.
pub const Wrapped = struct {
    run: TextRun,
    lines: []const Line,
    /// Every line's direction stretches, concatenated; each line names its
    /// own range. Empty for a paragraph that is all one left-to-right run.
    spans: []const Span = &.{},

    pub fn lineCount(self: Wrapped) usize {
        return self.lines.len;
    }

    /// Line `i` as a stretch of the paragraph's glyphs, which is what the
    /// caret and the hit test work on.
    ///
    /// `scratch` carries the single left-to-right stretch that a line with no
    /// span table stands for; see `TextRun.view`, which does the same thing
    /// for a whole run. The glyphs are *not* sliced: a line is a range of the
    /// paragraph's array, and the spans index into that array.
    pub fn viewOfLine(self: Wrapped, i: usize, scratch: *[1]Span) glyph.View {
        const ln = self.lines[@min(i, self.lines.len - 1)];
        if (ln.span_count == 0) {
            scratch[0] = .{
                .first = @intCast(ln.first),
                .count = @intCast(ln.count),
                .start = @intCast(ln.start),
                // Not `ln.end`: the stretch has to contain a caret at the end
                // of the line, and the glyphs of the trailing spaces past it.
                .end = std.math.maxInt(u32),
            };
        }
        return .{
            .glyphs = self.run.glyphs,
            .spans = if (ln.span_count > 0)
                self.spans[ln.span_first..][0..ln.span_count]
            else
                scratch[0..1],
            .lo = ln.first,
            .hi = ln.first + ln.count,
            // Where the ink ends, so that a click in the margin past the end
            // of a line is past the end of the stretch rather than on the
            // trailing space, which has an advance and nothing to see.
            .right_edge = ln.x + ln.width,
        };
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
        var one: [1]Span = undefined;
        return .{
            .x = self.viewOfLine(i, &one).caretX(at),
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
        // The trailing spaces have glyphs and no ink to be under: past the
        // ink of a left-to-right line, and hanging off the left of a
        // right-to-left one, where they are before its first character.
        if (ln.count == 0 or x >= ln.x + ln.width) return past;
        if (x < ln.x and self.run.base_level & 1 == 1) return past;
        var one: [1]Span = undefined;
        return self.viewOfLine(i, &one).clusterAt(x) orelse past;
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
        if (ln.count == 0) return ln.start;
        var one: [1]Span = undefined;
        const hit = self.viewOfLine(li, &one).byteAt(x) orelse return self.lineEnd(li, len);
        return @min(hit, self.lineEnd(li, len));
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
};

/// Breaks `src` into lines no wider than `opts.width`, and sets them against
/// the edge `opts.alignment` names.
///
/// `buf` is cleared and filled; the returned run borrows its glyphs and the
/// lines borrow its spans. A width of zero or less, or a run with no glyphs,
/// produces one line and the original glyphs.
pub fn wrap(
    gpa: Allocator,
    src: TextRun,
    text: []const u8,
    buf: *Buffers,
    opts: Options,
) Allocator.Error!Wrapped {
    buf.glyphs.clearRetainingCapacity();
    buf.lines.clearRetainingCapacity();
    buf.spans.clearRetainingCapacity();
    const max_width = opts.width;
    const lh = if (opts.line_height > 0) opts.line_height else src.height();

    if (src.glyphs.len == 0 or text.len == 0) {
        try buf.lines.append(gpa, .{
            .start = 0,
            .end = linebreak.trimTrailing(text, text.len),
            .first = 0,
            .count = src.glyphs.len,
            .width = src.width,
            .y = 0,
        });
        return .{ .run = src, .lines = buf.lines.items };
    }

    // A span table means the paragraph is not one left-to-right stretch, and
    // every step below has a second answer for that case: the width of a
    // range is a sum of advances rather than a difference of two x positions,
    // and a line is assembled by reordering its pieces rather than by taking
    // a slice.
    const mixed = src.spans.len > 0;

    // The paragraph's direction runs in **logical** order. `src.spans` is in
    // visual order -- that is what it is for -- and breaking happens in
    // logical order, so the one is an index permutation of the other. Built
    // once for the paragraph rather than per line.
    var order: []u32 = &.{};
    defer gpa.free(order);
    if (mixed) {
        order = try gpa.alloc(u32, src.spans.len);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, src.spans, lessByStart);
    }

    try buf.glyphs.ensureTotalCapacity(gpa, src.glyphs.len);

    var start: usize = 0;
    var y: f32 = 0;
    var widest: f32 = 0;
    var gi: usize = 0;

    while (true) {
        const x0 = if (mixed) 0 else src.caretX(start);
        const chosen = chooseBreak(src, text, start, x0, max_width, mixed);

        // Progress is the one thing that must hold, and it is checked rather
        // than argued: a break that does not advance is an infinite loop, and
        // this file already produced one on the way here.
        std.debug.assert(chosen.next > start);

        const first = buf.glyphs.items.len;
        const span_first = buf.spans.items.len;
        var width: f32 = 0;

        if (mixed) {
            width = try placeLine(gpa, src, buf, order, start, chosen, y, chosen.next >= text.len);
        } else {
            while (gi < src.glyphs.len and src.glyphs[gi].cluster < chosen.next) : (gi += 1) {
                var g = src.glyphs[gi];
                g.dx -= x0;
                g.pen_x -= x0;
                g.dy += y;
                buf.glyphs.appendAssumeCapacity(g);
            }
            width = src.caretX(chosen.ink_end) - x0;
        }

        widest = @max(widest, width);
        try buf.lines.append(gpa, .{
            .start = start,
            .end = chosen.ink_end,
            .first = first,
            .count = buf.glyphs.items.len - first,
            .width = width,
            .y = y,
            .span_first = span_first,
            .span_count = buf.spans.items.len - span_first,
        });

        start = chosen.next;
        y += lh;
        if (start >= text.len) break;
    }

    // Whatever is left: glyphs whose cluster is past the end of the text,
    // which shaping can produce for a trailing mark. They belong to the last
    // line rather than to nothing. The mixed path has already taken them --
    // its last line reaches past the end of the text for exactly this.
    if (!mixed and gi < src.glyphs.len and buf.lines.items.len > 0) {
        const last = &buf.lines.items[buf.lines.items.len - 1];
        const x0 = src.caretX(last.start);
        while (gi < src.glyphs.len) : (gi += 1) {
            var g = src.glyphs[gi];
            g.dx -= x0;
            g.pen_x -= x0;
            g.dy += last.y;
            buf.glyphs.appendAssumeCapacity(g);
        }
        last.count = buf.glyphs.items.len - last.first;
    }

    // --- alignment ---
    //
    // A second pass over the glyphs rather than an offset the scene builder
    // would have to add: the offsets are already baked per line (`y` is), and
    // everything downstream of this -- the scene builder, the caret, the hit
    // test, the accessibility rectangles -- would otherwise each need to know
    // about it and one of them would forget.
    const how = opts.alignment.resolve(src.base_level);
    if (max_width > 0 and how != .left) {
        for (buf.lines.items) |*ln| {
            const room = max_width - ln.width;
            // A line wider than the box starts at the box's left edge and
            // overflows to the right, whatever the alignment: overflowing one
            // way is visible, and overflowing both ways is a line nobody can
            // read the start of.
            const shift = @max(0, if (how == .center) room / 2 else room);
            if (shift == 0) continue;
            ln.x = shift;
            for (buf.glyphs.items[ln.first..][0..ln.count]) |*g| {
                g.dx += shift;
                g.pen_x += shift;
            }
        }
    }

    return .{
        .run = .{
            .glyphs = buf.glyphs.items,
            .spans = buf.spans.items,
            .base_level = src.base_level,
            // Aligned text is as wide as the box it was aligned in, not as
            // wide as its widest line: the glyphs were moved to the far edge
            // of that box, and an element sized to the ink would clip them.
            // Left-aligned text keeps the ink width it always had.
            .width = if (how == .left) widest else @max(widest, max_width),
            .ascent = src.ascent,
            .descent = src.descent,
            .lines = @intCast(buf.lines.items.len),
            .line_height = lh,
        },
        .lines = buf.lines.items,
        .spans = buf.spans.items,
    };
}

fn lessByStart(spans: []const Span, a: u32, b: u32) bool {
    return spans[a].start < spans[b].start;
}

/// Lays out one line of a mixed-direction paragraph, and returns its ink
/// width.
///
/// The break was chosen in logical order; this is where the line becomes
/// visual, and it is the order UAX #9 gives: resolve the paragraph, break it
/// into lines, then **reorder each line**. Not the paragraph -- a paragraph's
/// visual order is not the concatenation of its lines' visual orders, which
/// is precisely why slicing the already-reordered paragraph produced lines
/// assembled out of order and had to be guarded against instead.
///
/// So each direction run of the paragraph is clipped to this line, the clipped
/// pieces are reordered by rule L2, and each one's glyphs are copied in at the
/// pen the pieces before it left. The glyphs *within* a piece keep their
/// relative positions, which is what makes this a reorder and not a reshape:
/// breaking inside a direction run does not change the shaping of either side
/// for the scripts this handles -- the same trade the module makes for Latin,
/// made once more and for the same reason.
fn placeLine(
    gpa: Allocator,
    src: TextRun,
    buf: *Buffers,
    order: []const u32,
    start: usize,
    chosen: Break,
    y: f32,
    last_line: bool,
) Allocator.Error!f32 {
    const span0 = buf.spans.items.len;

    // The ink, in logical order: every direction run of the paragraph,
    // clipped to the part of it this line carries.
    const a0: u32 = @intCast(start);
    const b0: u32 = @intCast(chosen.ink_end);
    for (order) |oi| {
        const sp = src.spans[oi];
        const a = @max(sp.start, a0);
        const b = @min(sp.end, b0);
        if (b <= a) continue;
        const r = glyphRange(src, sp, a, b) orelse continue;
        try buf.spans.append(gpa, .{
            .first = r.first,
            .count = r.count,
            .start = a,
            .end = b,
            .level = sp.level,
        });
    }

    // Rule L2, on this line's pieces. The reason `Span` carries a level and
    // not a direction: the sequence to reverse is "level `n` or higher", and
    // an English word inside Hebrew inside an English paragraph is a level
    // nobody can recover from a flag.
    bidi.reorder(Span, buf.spans.items[span0..]);
    const n_ink = buf.spans.items.len - span0;

    // The trailing spaces the line owns, after everything else on it.
    //
    // Rule L1 resets a line's trailing whitespace to the paragraph's level,
    // which puts it at the end of the line. Putting it at the right-hand end
    // is that rule for a left-to-right paragraph and an approximation for a
    // right-to-left one -- where the deeper missing piece is that the line is
    // not right-aligned either, so there is no right-hand end for it to be
    // at. Said rather than half-done; the glyphs have no ink, so what moves
    // is where a caret after them is drawn.
    //
    // The last line reaches past the end of the text, which is where a
    // trailing mark's glyph can be: it belongs to the last line rather than
    // to nothing.
    const tail_a: u32 = b0;
    const tail_b: u32 = if (last_line) std.math.maxInt(u32) else @intCast(chosen.next);
    if (tail_b > tail_a) {
        for (order) |oi| {
            const sp = src.spans[oi];
            const a = @max(sp.start, tail_a);
            const b = if (last_line) tail_b else @min(sp.end, tail_b);
            if (b <= a) continue;
            const r = glyphRange(src, sp, a, b) orelse continue;
            try buf.spans.append(gpa, .{
                .first = r.first,
                .count = r.count,
                .start = a,
                .end = @min(b, sp.end),
                // Rule L1: the paragraph's level, not the level the run it
                // came from had. A space between a Hebrew word and the break
                // reads as part of the paragraph, so a caret before it goes
                // on the paragraph's side of it.
                .level = src.base_level,
            });
        }
    }

    const pieces = buf.spans.items[span0..];
    const n_tail = pieces.len - n_ink;
    const rtl_para = src.base_level & 1 == 1;

    // The rest of rule L1: the trailing whitespace goes at the paragraph's
    // *trailing* end, which for a right-to-left paragraph is its left -- in
    // front of the line's first character, hanging off the ink rather than
    // indenting it. Both halves of that have to move: the glyphs, and the
    // stretches, which have to stay in the order the glyphs are in.
    if (rtl_para and n_tail > 0) std.mem.rotate(Span, pieces, n_ink);

    var x: f32 = if (rtl_para and n_tail > 0) -piecesWidth(src, pieces[0..n_tail]) else 0;
    var ink: f32 = 0;
    for (pieces, 0..) |*p, i| {
        emit(src, buf, p, &x, y);
        // Where the ink ends: after the last ink piece, which comes last in a
        // right-to-left paragraph and before the whitespace in every other.
        if (!rtl_para and i + 1 == n_ink) ink = x;
    }
    if (rtl_para) ink = x;

    return ink;
}

/// What a run of pieces advances by, before any of them have been placed.
fn piecesWidth(src: TextRun, pieces: []const Span) f32 {
    var sum: f32 = 0;
    for (pieces) |p| {
        if (p.count == 0) continue;
        const last = p.first + p.count - 1;
        const right = if (last + 1 < src.glyphs.len) src.glyphs[last + 1].pen_x else src.width;
        sum += right - src.glyphs[p.first].pen_x;
    }
    return sum;
}

const Range = struct { first: u32, count: u32 };

/// The glyphs of `sp` whose clusters fall in the byte range `[a, b)`.
///
/// Contiguous, because the clusters of one direction run are monotonic along
/// the glyph array: ascending in a left-to-right run and **descending** in a
/// right-to-left one. So a logical range of bytes is an index range either
/// way, and which end of it is which is the whole of the difference.
fn glyphRange(src: TextRun, sp: Span, a: u32, b: u32) ?Range {
    var lo: ?u32 = null;
    var hi: u32 = 0;
    var i = sp.first;
    while (i < sp.last()) : (i += 1) {
        const cl = src.glyphs[i].cluster;
        if (cl < a or cl >= b) continue;
        if (lo == null) lo = i;
        hi = i + 1;
    }
    const l = lo orelse return null;
    return .{ .first = l, .count = hi - l };
}

/// Copies one piece's glyphs into the line at pen `x`, and rewrites the piece
/// to point at them.
///
/// Within a piece the glyph indices run left to right whichever direction the
/// text does -- that is what visual order means -- so the first glyph's pen
/// position is the piece's left edge and the advance after its last is the
/// right.
fn emit(src: TextRun, buf: *Buffers, p: *Span, x: *f32, y: f32) void {
    if (p.count == 0) return;
    const base = src.glyphs[p.first].pen_x;
    const shift = x.* - base;
    const out_first: u32 = @intCast(buf.glyphs.items.len);
    for (src.glyphs[p.first..][0..p.count]) |g0| {
        var g = g0;
        g.dx += shift;
        g.pen_x += shift;
        g.dy += y;
        buf.glyphs.appendAssumeCapacity(g);
    }
    const last = p.first + p.count - 1;
    const right = if (last + 1 < src.glyphs.len) src.glyphs[last + 1].pen_x else src.width;
    x.* += right - base;
    p.first = out_first;
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
fn chooseBreak(
    src: TextRun,
    text: []const u8,
    start: usize,
    x0: f32,
    max_width: f32,
    mixed: bool,
) Break {
    var at = start;
    var best: Break = .{ .ink_end = start, .next = start };
    var have = false;

    while (true) {
        const o = linebreak.next(text, at);
        const next: usize = if (o) |x| x.at else text.len;
        const mandatory = if (o) |x| x.mandatory else false;
        const ink = linebreak.trimTrailing(text, next);
        const w = if (mixed) logicalWidth(src, start, ink) else src.caretX(ink) - x0;

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

/// The width of the logical byte range `[a, b)`: the sum of the advances of
/// the glyphs whose clusters fall in it.
///
/// Not the difference of two caret positions, which is what the left-to-right
/// path uses. In mixed text the x of a byte is not monotonic in the byte --
/// that is what mixed text *is* -- so the distance between two carets is not
/// the width of the text between them, and can come out negative.
///
/// One pass over the paragraph's glyphs per candidate break, paid only by
/// paragraphs that mix directions. A prefix table in logical order would make
/// it a subtraction; that is a refinement to make when a measurement asks for
/// it, and the measurement is in `tools/scene_bench.zig`.
fn logicalWidth(src: TextRun, a: usize, b: usize) f32 {
    var sum: f32 = 0;
    for (src.glyphs, 0..) |g, i| {
        if (g.cluster < a or g.cluster >= b) continue;
        const right = if (i + 1 < src.glyphs.len) src.glyphs[i + 1].pen_x else src.width;
        sum += right - g.pen_x;
    }
    return sum;
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
    src_spans: std.ArrayList(Span) = .empty,
    buf: Buffers = .{},

    fn deinit(self: *Bits) void {
        self.src.deinit(testing.allocator);
        self.src_spans.deinit(testing.allocator);
        self.buf.deinit(testing.allocator);
    }

    fn run(self: *Bits, s: []const u8, max_width: f32) !Wrapped {
        const src = try fakeRun(s, &self.src);
        return wrap(testing.allocator, src, s, &self.buf, .{ .width = max_width, .line_height = 12 });
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

/// One direction run of a test paragraph, in logical order.
const Piece = struct { start: usize, end: usize, level: u8 };

/// A run shaped the way `text.Font.shape` shapes a mixed paragraph: the pieces
/// reordered into visual order, each one's glyphs laid out left to right, and
/// a right-to-left piece's clusters therefore **descending** along the array.
///
/// Capital letters stand in for Hebrew. Real Hebrew would make the test need a
/// font, and -- worse -- make every expectation below unreadable: `"one OWT"`
/// says what it means in a way that a reversed string of letters nobody in the
/// room can spell does not.
fn fakeMixedRun(
    s: []const u8,
    base_level: u8,
    pieces: []const Piece,
    out: *std.ArrayList(Glyph),
    spans: *std.ArrayList(Span),
) !TextRun {
    out.clearRetainingCapacity();
    spans.clearRetainingCapacity();

    const visual = try testing.allocator.dupe(Piece, pieces);
    defer testing.allocator.free(visual);
    bidi.reorder(Piece, visual);

    var k: f32 = 0;
    for (visual) |pc| {
        const first = out.items.len;
        var at: [64]usize = undefined;
        var n: usize = 0;
        var i = pc.start;
        while (i < pc.end) {
            at[n] = i;
            n += 1;
            i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        }
        if (pc.level & 1 == 1) std.mem.reverse(usize, at[0..n]);
        for (at[0..n]) |b| {
            try out.append(testing.allocator, .{
                .dx = k * adv,
                .dy = 0,
                .w = adv,
                .h = asc,
                .u0 = 0,
                .v0 = 0,
                .u1 = 1,
                .v1 = 1,
                .cluster = @intCast(b),
                .pen_x = k * adv,
            });
            k += 1;
        }
        try spans.append(testing.allocator, .{
            .first = @intCast(first),
            .count = @intCast(out.items.len - first),
            .start = @intCast(pc.start),
            .end = @intCast(pc.end),
            .level = pc.level,
        });
    }
    return .{
        .glyphs = out.items,
        .spans = spans.items,
        .base_level = base_level,
        .width = k * adv,
        .ascent = asc,
        .descent = desc,
    };
}

/// The clusters of one line, in the order they are drawn.
fn clustersOf(w: Wrapped, i: usize, out: []u32) []u32 {
    const ln = w.lines[i];
    for (w.run.glyphs[ln.first..][0..ln.count], 0..) |g, k| out[k] = g.cluster;
    return out[0..ln.count];
}

test "a mixed-direction paragraph breaks in logical order and each line is reordered" {
    // "one TWO three", where TWO is right to left. Visually the paragraph is
    // "one OWT three"; broken after "TWO" the first line is "one OWT " and
    // the second is "three", and neither is a slice of the paragraph's glyphs.
    var b: Bits = .{};
    defer b.deinit();
    const s = "one TWO three";
    const src = try fakeMixedRun(s, 0, &.{
        .{ .start = 0, .end = 4, .level = 0 },
        .{ .start = 4, .end = 7, .level = 1 },
        .{ .start = 7, .end = 13, .level = 0 },
    }, &b.src, &b.src_spans);

    const w = try wrap(testing.allocator, src, s, &b.buf, .{ .width = 8 * adv, .line_height = 12 });
    try expectWellFormed(w, s);
    try testing.expectEqual(@as(usize, 2), w.lines.len);

    var buf: [16]u32 = undefined;
    // The right-to-left word is reversed inside the line, and the line's
    // left-to-right text is not.
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 6, 5, 4, 7 }, clustersOf(w, 0, &buf));
    try testing.expectEqualSlices(u32, &.{ 8, 9, 10, 11, 12 }, clustersOf(w, 1, &buf));

    // Rebased: every line starts at the paragraph's left edge, the one before
    // the break is seven characters of ink and the one after is five.
    try testing.expectEqual(@as(f32, 7 * adv), w.lines[0].width);
    try testing.expectEqual(@as(f32, 5 * adv), w.lines[1].width);
    try testing.expectEqual(@as(f32, 0), w.run.glyphs[w.lines[1].first].pen_x);
    try testing.expectEqual(@as(f32, 12), w.run.glyphs[w.lines[1].first].dy);

    // And the caret inside the reordered line is still on the right side of
    // the glyph: before the first letter of "TWO" is the *right* edge of it.
    try testing.expectEqual(@as(f32, 7 * adv), w.caret(4).x);
    try testing.expectEqual(@as(f32, 6 * adv), w.caret(5).x);
    try testing.expectEqual(@as(f32, 0), w.caret(4).y);
    // Byte 7 ends the right-to-left word and begins the space after it, so it
    // has two valid positions: the left edge of "OWT" at 4 and the left edge
    // of the space at 7. `Span.spanFor` takes the stretch that *contains* the
    // offset, which is the space -- the convention that keeps the caret
    // moving forward as the offset grows, and the one `glyph.zig` documents.
    try testing.expectEqual(@as(f32, 7 * adv), w.caret(7).x);
    // On the second line it reads left to right again.
    try testing.expectEqual(@as(f32, 0), w.caret(8).x);
    try testing.expectEqual(@as(f32, 12), w.caret(8).y);

    // A click on the left half of the rightmost letter of "TWO" -- which is
    // its *first* letter -- is before it, not after it.
    try testing.expectEqual(@as(usize, 5), w.byteAt(6.4 * adv, 0, s.len));
    try testing.expectEqual(@as(usize, 4), w.byteAt(6.6 * adv, 0, s.len));
}

test "a right-to-left paragraph wraps, and its first line is not its last" {
    // The case the old guard did not even cover: one direction run, right to
    // left, longer than the line. The glyphs' clusters descend, so the
    // left-to-right path took no glyph for the first line and dumped all of
    // them on the last. Nothing was out of order on screen; the text was
    // simply all on one line and the rest were empty.
    var b: Bits = .{};
    defer b.deinit();
    const s = "ABC DEF GHI";
    const src = try fakeMixedRun(s, 1, &.{.{ .start = 0, .end = 11, .level = 1 }}, &b.src, &b.src_spans);

    const w = try wrap(testing.allocator, src, s, &b.buf, .{ .width = 8 * adv, .line_height = 12 });
    try expectWellFormed(w, s);
    try testing.expectEqual(@as(usize, 2), w.lines.len);

    var buf: [16]u32 = undefined;
    // "ABC DEF" displayed right to left is "FED CBA", and rule L1 puts the
    // space the line ends with at the paragraph's trailing end -- which for
    // this paragraph is the left, in front of everything else on the line.
    try testing.expectEqualSlices(u32, &.{ 7, 6, 5, 4, 3, 2, 1, 0 }, clustersOf(w, 0, &buf));
    try testing.expectEqualSlices(u32, &.{ 10, 9, 8 }, clustersOf(w, 1, &buf));
    try testing.expectEqual(@as(f32, 7 * adv), w.lines[0].width);
    try testing.expectEqual(@as(f32, 3 * adv), w.lines[1].width);

    // `start` is the right-hand edge for this paragraph, so both lines are
    // set against it: the first has a character of room, the second five.
    try testing.expectEqual(@as(f32, adv), w.lines[0].x);
    try testing.expectEqual(@as(f32, 5 * adv), w.lines[1].x);
    // And the space hangs off the left of the ink rather than indenting it:
    // the first line's ink still reaches the box's right edge.
    try testing.expectEqual(@as(f32, 0), w.run.glyphs[w.lines[0].first].pen_x);
    try testing.expectEqual(@as(f32, 8 * adv), w.lines[0].x + w.lines[0].width);

    // The caret before the first character of a right-to-left line is at the
    // right-hand end of it, and the caret before the trailing space -- which
    // is after every character on the line, reading right to left -- is at
    // the left-hand end. Those were the same x before L1 moved the space.
    try testing.expectEqual(@as(f32, 8 * adv), w.caret(0).x);
    try testing.expectEqual(@as(f32, adv), w.caret(7).x);
    try testing.expectEqual(@as(f32, 8 * adv), w.caret(8).x);
    try testing.expectEqual(@as(f32, 12), w.caret(8).y);
    try testing.expectEqual(@as(f32, 5 * adv), w.caret(11).x);
}

test "a paragraph is set against the edge it is told to be" {
    var b: Bits = .{};
    defer b.deinit();
    const s = "one two three";
    const src = try fakeRun(s, &b.src);
    const box = 10 * adv;

    // Lines of seven and five characters in a box of ten.
    const left = try wrap(testing.allocator, src, s, &b.buf, .{ .width = box, .line_height = 12 });
    try expectWellFormed(left, s);
    try testing.expectEqual(@as(usize, 2), left.lines.len);
    try testing.expectEqual(@as(f32, 0), left.lines[0].x);
    try testing.expectEqual(@as(f32, 0), left.lines[1].x);
    // Left-aligned text is as wide as its ink, which is what an element sized
    // to it has always been.
    try testing.expectEqual(@as(f32, 7 * adv), left.run.width);

    const right = try wrap(testing.allocator, src, s, &b.buf, .{ .width = box, .line_height = 12, .alignment = .right });
    try expectWellFormed(right, s);
    try testing.expectEqual(@as(f32, 3 * adv), right.lines[0].x);
    try testing.expectEqual(@as(f32, 5 * adv), right.lines[1].x);
    // Aligned text is as wide as the box: the glyphs were moved to its far
    // edge, and an element sized to the ink would clip them.
    try testing.expectEqual(box, right.run.width);
    // The glyphs moved with it, and the caret and the hit test with them.
    try testing.expectEqual(@as(f32, 3 * adv), right.run.glyphs[0].pen_x);
    try testing.expectEqual(@as(f32, 3 * adv), right.caret(0).x);
    try testing.expectEqual(@as(usize, 0), right.byteAt(3.1 * adv, 0, s.len));
    // Left of the first line's ink is still its first character, not the end
    // of the line above it.
    try testing.expectEqual(@as(usize, 0), right.byteAt(0, 0, s.len));

    const center = try wrap(testing.allocator, src, s, &b.buf, .{ .width = box, .line_height = 12, .alignment = .center });
    try testing.expectEqual(@as(f32, 1.5 * adv), center.lines[0].x);
    try testing.expectEqual(@as(f32, 2.5 * adv), center.lines[1].x);
    try testing.expectEqual(@as(f32, 1.5 * adv), center.caret(0).x);

    // `start` and `end` are the paragraph's own edges, and this paragraph
    // runs left to right.
    const start = try wrap(testing.allocator, src, s, &b.buf, .{ .width = box, .line_height = 12, .alignment = .start });
    try testing.expectEqual(@as(f32, 0), start.lines[0].x);
    const end = try wrap(testing.allocator, src, s, &b.buf, .{ .width = box, .line_height = 12, .alignment = .end });
    try testing.expectEqual(@as(f32, 3 * adv), end.lines[0].x);
}

test "a line wider than the box overflows one way, whatever the alignment" {
    // Centring a line that does not fit would push its start off the left of
    // the box, where nobody can read it. It starts at the box's left edge and
    // overflows to the right instead, which is where every other overflow in
    // this engine goes.
    var b: Bits = .{};
    defer b.deinit();
    const s = "supercalifragilistic";
    const src = try fakeRun(s, &b.src);
    for ([_]Align{ .left, .right, .center, .start, .end }) |a| {
        const w = try wrap(testing.allocator, src, s, &b.buf, .{ .width = 3 * adv, .line_height = 12, .alignment = a });
        try expectWellFormed(w, s);
        try testing.expectEqual(@as(usize, 1), w.lines.len);
        try testing.expectEqual(@as(f32, 0), w.lines[0].x);
        try testing.expectEqual(@as(f32, 0), w.run.glyphs[0].pen_x);
    }
}

test "aligning is off when there is nothing to align in" {
    // A width of zero is "no limit", so there is no box and nothing to be at
    // the far edge of. The alignment is ignored rather than measured against
    // zero, which would put every line at a negative x.
    var b: Bits = .{};
    defer b.deinit();
    const s = "one two three";
    const src = try fakeRun(s, &b.src);
    const w = try wrap(testing.allocator, src, s, &b.buf, .{ .width = 0, .line_height = 12, .alignment = .right });
    try testing.expectEqual(@as(usize, 1), w.lines.len);
    try testing.expectEqual(@as(f32, 0), w.lines[0].x);
    try testing.expectEqual(src.width, w.run.width);
}

test "a mixed paragraph that fits is one line, and its spans survive" {
    var b: Bits = .{};
    defer b.deinit();
    const s = "one TWO three";
    const src = try fakeMixedRun(s, 0, &.{
        .{ .start = 0, .end = 4, .level = 0 },
        .{ .start = 4, .end = 7, .level = 1 },
        .{ .start = 7, .end = 13, .level = 0 },
    }, &b.src, &b.src_spans);

    const w = try wrap(testing.allocator, src, s, &b.buf, .{ .width = 1000, .line_height = 12 });
    try expectWellFormed(w, s);
    try testing.expectEqual(@as(usize, 1), w.lines.len);
    try testing.expectEqual(src.glyphs.len, w.lines[0].count);
    try testing.expectEqual(@as(usize, 3), w.lines[0].span_count);
    try testing.expectEqual(src.width, w.lines[0].width);
}

test "no width loses or duplicates a glyph of a mixed paragraph" {
    // The property the three tests above check one case of each: a set of
    // lines partitions the glyphs. Across every width from one character to
    // the whole paragraph, including the ones that break inside the
    // right-to-left word.
    var b: Bits = .{};
    defer b.deinit();
    const s = "a ONE b TWO c";
    const pieces = [_]Piece{
        .{ .start = 0, .end = 2, .level = 0 },
        .{ .start = 2, .end = 5, .level = 1 },
        .{ .start = 5, .end = 8, .level = 0 },
        .{ .start = 8, .end = 11, .level = 1 },
        .{ .start = 11, .end = 13, .level = 0 },
    };

    var width: f32 = adv;
    while (width <= 14 * adv) : (width += adv) {
        const src = try fakeMixedRun(s, 0, &pieces, &b.src, &b.src_spans);
        const w = try wrap(testing.allocator, src, s, &b.buf, .{ .width = width, .line_height = 12 });
        try expectWellFormed(w, s);

        // Every line's spans cover its glyphs exactly, in visual order: the
        // caret arithmetic reads them, so a gap is a caret that lands
        // somewhere else entirely. And every line *is* in visual order: its
        // glyph indices run left to right, which is the property slicing the
        // paragraph could not have -- and which no count would show.
        for (w.lines) |ln| {
            const gs = w.run.glyphs[ln.first..][0..ln.count];
            for (gs, 0..) |g, k| {
                if (k > 0) try testing.expect(g.pen_x >= gs[k - 1].pen_x);
            }
            var next = ln.first;
            for (w.spans[ln.span_first..][0..ln.span_count]) |sp| {
                try testing.expectEqual(next, sp.first);
                next += sp.count;
            }
            try testing.expectEqual(ln.first + ln.count, next);
        }

        // And every byte of the text has a caret position on the line that
        // owns it, inside that line's ink.
        for (0..s.len) |i| {
            const c = w.caret(i);
            try testing.expect(c.x >= 0);
            try testing.expect(c.x <= w.lines[w.lineOf(i)].width + 0.01);
        }
    }
}
