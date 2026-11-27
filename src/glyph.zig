//! Glyph data the core carries without knowing how to produce it.
//!
//! Everything here is plain numbers on purpose. Shaping and rasterising text
//! needs HarfBuzz, FreeType and fontconfig; the core module has no platform
//! dependencies and its tests run on a machine with no fonts, no GPU and no
//! compositor, which is a property worth keeping. So the split is: the `text`
//! module produces a `TextRun` and fills an atlas, and the core stores the run,
//! lays out around it, and emits primitives for it -- reading nothing but
//! offsets and coverage bytes.
//!
//! The direction matters. Had `Tree.setText` taken a string and a font, the
//! core would link three C libraries and `zig build test` would need a font
//! installed. Taking an already-shaped run instead also puts shaping where it
//! belongs in the reactivity story: shaping is expensive and happens when the
//! text changes, not once per frame.

const std = @import("std");

const Rect = @import("geometry.zig").Rect;

/// One positioned, already-rasterised glyph.
///
/// Positions are integral. Subpixel glyph positioning would mean either a
/// cache entry per fractional offset or filtered sampling, and both break the
/// exact texel-for-pixel correspondence that lets the GPU and the software
/// reference agree bit for bit. Integral positions are also what FreeType's
/// hinted outlines assume.
pub const Glyph = extern struct {
    /// Offset from the element's content origin -- its padding box corner --
    /// to the top-left of this glyph's bitmap, in logical pixels.
    dx: f32,
    dy: f32,

    /// The bitmap's size in pixels, equal to the size of its atlas rectangle.
    w: f32,
    h: f32,

    /// Top-left texel in the atlas, and one past the bottom-right. Equal
    /// values mean no ink: a space is a real glyph with a real advance and
    /// nothing to draw.
    u0: u16,
    v0: u16,
    u1: u16,
    v1: u16,

    /// The byte offset in the source string this glyph came from.
    ///
    /// Carried because without it a caret cannot be placed. Shaping is not a
    /// one-to-one map: a ligature is one glyph for several bytes, a decomposed
    /// `ế` is two glyphs for one character, and reordering means the nth glyph
    /// is not the nth character. The shaper is the only thing that knows which
    /// bytes produced which glyph, so throwing the answer away means it cannot
    /// be recovered afterwards -- which is what an earlier version of this
    /// file did.
    cluster: u32,

    /// The pen position before this glyph, which is where a caret in front of
    /// it goes.
    ///
    /// Not the same as `dx`: that is the left edge of the *bitmap*, which sits
    /// wherever the outline does and is frequently negative relative to the
    /// pen. A caret drawn at `dx` lands inside the letter.
    pen_x: f32,

    pub fn hasInk(self: Glyph) bool {
        return self.u1 > self.u0 and self.v1 > self.v0;
    }
};

comptime {
    std.debug.assert(@sizeOf(Glyph) == 32);
}

/// A shaped line of text: where its glyphs sit, and the metrics layout needs.
///
/// There is no string here. The core never re-reads the text, so keeping a
/// copy would be storage nobody indexes -- and the document model the input
/// method and accessibility layers need (`docs/text-and-accessibility.md` §1)
/// owns the bytes and indexes them in UTF-8, which is a different structure
/// from this one and belongs beside it rather than inside it.
/// One stretch of glyphs at a single direction, contiguous in visual order.
pub const Span = struct {
    /// Glyphs `[first, first + count)` of the run.
    first: u32,
    count: u32,
    /// The byte range of the source string this stretch covers.
    start: u32,
    end: u32,
    /// Whether the glyphs in it run right to left -- their clusters descend
    /// where a left-to-right stretch's ascend.
    rtl: bool,

    pub fn last(self: Span) u32 {
        return self.first + self.count;
    }
};

pub const TextRun = struct {
    /// Const because nothing downstream of shaping mutates a glyph: layout
    /// reads the metrics, the scene builder reads the offsets. When a run is
    /// installed on a tree the tree owns the memory and frees it; a run handed
    /// straight out of a shaper borrows the shaper's scratch buffer.
    glyphs: []const Glyph = &.{},

    /// The sum of the glyph advances: how wide the line is, which is not the
    /// same as the extent of its ink. A trailing space advances the pen and
    /// draws nothing, and an italic `f` can overhang its own advance.
    width: f32 = 0,

    /// The font's ascent and descent at this size, not this run's ink extent.
    /// Using the ink would make two labels in a row sit at different heights
    /// because one of them happens to contain a `g`.
    ///
    /// `height()` is their sum, and that is deliberately NOT the font's own
    /// line height, which can be smaller -- Noto Sans at 15 pixels reports
    /// ascent 17, descent 5 and a preferred line spacing of 20. Ascent and
    /// descent are maxima over every glyph in the font, so a box that tall
    /// cannot clip ink; line spacing is a typographic preference that assumes
    /// most lines do not reach those extremes. A single label's box uses the
    /// bound that cannot clip, which matters most for exactly the text this
    /// project has to set correctly: `ế` stacks two marks above the x-height.
    /// A line breaker, when there is one, will stack lines at `line_height`
    /// instead.
    ascent: f32 = 0,
    descent: f32 = 0,

    /// The direction runs, in the order they are drawn.
    ///
    /// Empty means what nearly every run is: one stretch of left-to-right
    /// text. Anything else is a mixed-direction line, where the glyphs are in
    /// visual order and the clusters therefore are **not** monotonic -- which
    /// is exactly what the three functions below would get wrong without
    /// this.
    spans: []const Span = &.{},

    /// How many lines the glyphs are stacked over. One for a run that has not
    /// been through `text_layout.wrap`.
    lines: u32 = 1,
    /// The font's preferred line spacing, used to stack them. Ignored while
    /// `lines` is one, which is why a single-line run never has to carry it.
    line_height: f32 = 0,

    /// The box the glyphs need.
    ///
    /// For one line this is ascent plus descent, which is the bound that
    /// cannot clip ink. For several it is the stack: the lines above spaced at
    /// `line_height`, and the last one still given its full ascent and
    /// descent, because the bottom of the box has to clear the deepest
    /// descender on the last line and `line_height` does not promise that.
    pub fn height(self: TextRun) f32 {
        const base = self.ascent + self.descent;
        if (self.lines <= 1) return base;
        return self.line_height * @as(f32, @floatFromInt(self.lines - 1)) + base;
    }

    pub fn isEmpty(self: TextRun) bool {
        return self.glyphs.len == 0;
    }

    // ------------------------------------------------------------- the caret
    //
    // `docs/text-and-accessibility.md` §7: three protocols ask the same
    // question in three ways -- `set_cursor_rectangle` on Wayland,
    // `GetTextExt` in TSF, `get_BoundingRectangle` in UIA -- and all four
    // spikes answer it with a fixed rectangle, which is why their candidate
    // windows appear in the wrong place. These are the functions that answer
    // it properly, and the adapters convert their own units into bytes with
    // `offsets.zig` before asking.
    //
    // **Left to right only.** The run carries no direction, so a right-to-left
    // or mixed line would need the glyphs grouped into runs of one direction
    // each and the arithmetic done per run. Saying so is better than an
    // implementation that is quietly wrong for Arabic and Hebrew; a toolkit
    // that got Vietnamese right by shaping properly should not then get
    // direction wrong by assuming.

    /// Where a caret immediately before byte `b` sits, measured from the run's
    /// origin.
    ///
    /// A byte inside a cluster resolves to that cluster's start. One glyph can
    /// cover several bytes -- a ligature, or a precomposed character built
    /// from a base and a mark -- and there is no position *inside* a glyph
    /// that corresponds to a byte. Splitting the advance proportionally is
    /// what a text editor does for a long ligature; it is a refinement of this
    /// and not a different answer.
    /// The spans, or the single left-to-right one an empty table stands for.
    ///
    /// One place to put the default, so that every function below is written
    /// once for the general case rather than twice with a fast path that can
    /// drift from it.
    fn spansOf(self: TextRun, scratch: *[1]Span) []const Span {
        if (self.spans.len > 0) return self.spans;
        scratch[0] = .{
            .first = 0,
            .count = @intCast(self.glyphs.len),
            .start = 0,
            .end = if (self.glyphs.len == 0) 0 else std.math.maxInt(u32),
            .rtl = false,
        };
        return scratch[0..1];
    }

    /// Where glyph `i` ends: where the next one starts, or the run's end.
    fn edgeAfter(self: TextRun, i: usize) f32 {
        return if (i + 1 < self.glyphs.len) self.glyphs[i + 1].pen_x else self.width;
    }

    /// The byte that follows the character glyph `i` of `sp` stands for, in
    /// **logical** order.
    ///
    /// In a left-to-right stretch that is the next glyph along; in a
    /// right-to-left one it is the previous, because the glyphs were laid out
    /// in the opposite order from the bytes.
    fn logicalNext(self: TextRun, sp: Span, i: usize) usize {
        if (sp.rtl) {
            return if (i > sp.first) self.glyphs[i - 1].cluster else sp.end;
        }
        return if (i + 1 < sp.last()) self.glyphs[i + 1].cluster else sp.end;
    }

    /// Where a caret immediately before byte `b` sits, measured from the run's
    /// origin.
    ///
    /// A byte inside a cluster resolves to that cluster's start. One glyph can
    /// cover several bytes -- a ligature, or a precomposed character built
    /// from a base and a mark -- and there is no position *inside* a glyph
    /// that corresponds to a byte. Splitting the advance proportionally is
    /// what a text editor does for a long ligature; it is a refinement of this
    /// and not a different answer.
    ///
    /// **In a right-to-left stretch the caret goes on the other side of the
    /// glyph.** Before the first character of `"אבג"` is to the *right* of
    /// `א`, because that is where the text starts. Getting this backwards
    /// puts the caret one character out and in the wrong direction, which is
    /// what made it worth doing properly once the text itself drew correctly.
    pub fn caretX(self: TextRun, b: usize) f32 {
        var one: [1]Span = undefined;
        const sp = spanFor(self.spansOf(&one), b) orelse return self.width;

        // The glyph whose cluster is the smallest one at or after `b`. In a
        // left-to-right stretch the clusters ascend along the array, so that
        // is the first match going forwards; in a right-to-left one they
        // **descend**, so it is the first match going backwards. Scanning
        // forwards in a right-to-left stretch finds the leftmost glyph
        // instead, and puts the caret at the far end of the word.
        if (sp.rtl) {
            var i = sp.last();
            while (i > sp.first) {
                i -= 1;
                if (self.glyphs[i].cluster >= b) return self.edgeAfter(i);
            }
        } else {
            var i = sp.first;
            while (i < sp.last()) : (i += 1) {
                if (self.glyphs[i].cluster >= b) return self.glyphs[i].pen_x;
            }
        }
        // Past every cluster in the stretch: the logical end of it, which is
        // its right edge going one way and its left edge going the other.
        if (sp.count == 0) return self.width;
        return if (sp.rtl)
            self.glyphs[sp.first].pen_x
        else
            self.edgeAfter(sp.last() - 1);
    }

    /// The stretch a byte offset belongs to.
    ///
    /// A boundary between two directions is two valid caret positions -- the
    /// end of one stretch and the start of the next are the same byte in
    /// different places on the screen. This takes the stretch that *contains*
    /// the offset, and falls back to the last one that ends at or before it,
    /// which is the convention that keeps a caret moving forward through the
    /// text as the offset grows.
    fn spanFor(spans: []const Span, b: usize) ?Span {
        for (spans) |sp| {
            if (b >= sp.start and b < sp.end) return sp;
        }
        var best: ?Span = null;
        for (spans) |sp| {
            if (sp.end <= b) {
                if (best == null or sp.end >= best.?.end) best = sp;
            }
        }
        return best orelse (if (spans.len > 0) spans[0] else null);
    }

    /// The glyph `x` falls on, as an index, or null past either end.
    fn glyphAt(self: TextRun, x: f32) ?usize {
        if (self.glyphs.len == 0) return null;
        if (x < self.glyphs[0].pen_x) return 0;
        for (0..self.glyphs.len) |i| {
            if (x < self.edgeAfter(i)) return i;
        }
        return null;
    }

    fn spanOfGlyph(spans: []const Span, i: usize) Span {
        for (spans) |sp| {
            if (i >= sp.first and i < sp.last()) return sp;
        }
        return spans[spans.len - 1];
    }

    /// The byte offset of the character *under* `x`: not rounded to an edge
    /// like `byteAt`. A double-click selects the word under the pointer, and
    /// rounding would turn a click on the right half of a word's last letter
    /// into the boundary after it -- and select the space that follows.
    /// Before the first glyph, the first; past the end, `len`.
    pub fn clusterAt(self: TextRun, x: f32, len: usize) usize {
        if (self.glyphs.len == 0) return 0;
        const i = self.glyphAt(x) orelse return len;
        return self.glyphs[i].cluster;
    }

    /// The byte offset a caret should move to for a click at `x`.
    ///
    /// Rounds to the nearer edge of whichever glyph `x` falls in, because a
    /// click in the left half of a letter means "before it" and in the right
    /// half means "after it" -- and in a right-to-left stretch those two
    /// sentences swap, because the letter after this one is to its left.
    pub fn byteAt(self: TextRun, x: f32, len: usize) usize {
        if (self.glyphs.len == 0 or x <= 0) return 0;
        var one: [1]Span = undefined;
        const spans = self.spansOf(&one);
        const i = self.glyphAt(x) orelse return len;
        const sp = spanOfGlyph(spans, i);
        const g = self.glyphs[i];
        const mid = (g.pen_x + self.edgeAfter(i)) * 0.5;
        const near_side = x < mid;
        const after = self.logicalNext(sp, i);
        const at = if (sp.rtl) (if (near_side) after else g.cluster) else (if (near_side) g.cluster else after);
        return @min(at, len);
    }

    /// The rectangle covering bytes `start..end`, relative to the run's
    /// origin. A zero-width rectangle is a caret; a wide one is a selection.
    /// The rectangle covering bytes `start..end`, relative to the run's
    /// origin. A zero-width rectangle is a caret; a wide one is a selection.
    ///
    /// **One rectangle**, so a selection that crosses a direction boundary is
    /// not this: the bytes between two offsets are not one stretch on screen
    /// when half of them run the other way. That wants a rectangle per span,
    /// the way a selection across a line break already wants one per line,
    /// and it is said here rather than approximated.
    pub fn rangeRect(self: TextRun, start: usize, end: usize) Rect {
        const x0 = self.caretX(@min(start, end));
        const x1 = self.caretX(@max(start, end));
        return .{ .x = @min(x0, x1), .y = 0, .w = @abs(x1 - x0), .h = self.height() };
    }
};

/// A borrowed view of a glyph atlas: one byte of coverage per texel.
///
/// Single-channel because that is what antialiased glyph coverage is. Colour
/// comes from the primitive, so one atlas entry serves every colour the same
/// text is ever drawn in.
pub const AtlasView = struct {
    pixels: []const u8,
    w: u32,
    h: u32,

    /// Coverage at a texel, or zero outside the atlas. Out of range returns
    /// zero rather than trapping because the caller asks about texels derived
    /// from a quad's pixel coverage, and the quad is expanded by a pixel for
    /// an antialiased edge it does not have.
    pub fn at(self: AtlasView, x: i32, y: i32) u8 {
        if (x < 0 or y < 0) return 0;
        const ux: u32 = @intCast(x);
        const uy: u32 = @intCast(y);
        if (ux >= self.w or uy >= self.h) return 0;
        return self.pixels[@as(usize, uy) * self.w + ux];
    }
};
