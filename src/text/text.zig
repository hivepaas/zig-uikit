//! Shaping and rasterisation: the only module that knows what a font is.
//!
//! Three C libraries, each doing one thing that cannot sensibly be done
//! without it:
//!
//!   - **fontconfig** answers "what file is `sans`". Hardcoding a path works on
//!     exactly one machine, and the answer differs between distributions, user
//!     configuration and language.
//!   - **FreeType** turns an outline into antialiased coverage, with hinting.
//!   - **HarfBuzz** turns a string into positioned glyph ids.
//!
//! **Why HarfBuzz is in the first slice of text rather than a later one.** The
//! tempting shortcut is a glyph per codepoint via `FT_Get_Char_Index`, which
//! renders English correctly and is maybe thirty lines. It renders `tiếng
//! việt` wrongly. Vietnamese stacks a tone mark over a vowel that may already
//! carry a diacritic, and whether that is one precomposed glyph or two glyphs
//! with the second positioned by the font's `GPOS` table is a property of the
//! font, not of the text. Only the shaper knows. A toolkit written in Vietnam
//! that cannot set Vietnamese is not a toolkit with a missing feature; it is
//! one built on a model that has to be thrown away.
//!
//! What this module does NOT do yet: line breaking, bidirectional text, font
//! fallback for a glyph the chosen family lacks, and the document model that
//! `docs/text-and-accessibility.md` specifies. One shaped line is the unit
//! here, and the first three of those are each a separate piece of work on top
//! of it rather than something to half-do inside it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c");
const ui = @import("zig-uikit");
pub const atlas_mod = @import("atlas.zig");

pub const Atlas = atlas_mod.Atlas;
pub const Slot = atlas_mod.Slot;

pub const Error = error{
    OutOfMemory,
    AtlasFull,
    /// fontconfig or FreeType could not be started.
    InitFailed,
    /// fontconfig matched nothing, which on a system with no fonts at all is
    /// the honest answer.
    NoSuchFont,
    /// The file fontconfig named could not be loaded as a face.
    BadFont,
    /// FreeType refused the requested pixel size.
    BadSize,
    /// FreeType loaded the glyph but produced something other than an 8-bit
    /// grey bitmap -- a colour emoji font, or a bitmap-only font in a mode
    /// this does not handle.
    UnsupportedGlyphFormat,
};

/// FreeType and fontconfig, initialised once.
///
/// Both are process-global in effect -- fontconfig keeps a default config,
/// FreeType an allocator and module list -- so this is a handle to that rather
/// than an object there would be any point in having two of.
pub const Library = struct {
    ft: c.FT_Library,

    pub fn init() Error!Library {
        if (c.FcInit() == 0) return Error.InitFailed;
        var ft: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&ft) != 0) return Error.InitFailed;
        return .{ .ft = ft };
    }

    pub fn deinit(self: *Library) void {
        _ = c.FT_Done_FreeType(self.ft);
        // `FcFini` is deliberately not called. It invalidates every pattern
        // and config fontconfig ever handed out, including any still held by
        // another library in the process, and the documentation says as much.
        self.* = undefined;
    }

    /// Opens the font fontconfig matches for `family`, at `px` pixels.
    ///
    /// `family` is a fontconfig name, so the generic aliases work: `sans`,
    /// `serif`, `monospace`, as well as a real family name. Matching never
    /// fails on a system with any font installed, which means asking for a
    /// family that does not exist silently gives a different one -- that is
    /// fontconfig's entire purpose and not something to defeat here.
    pub fn open(self: *Library, gpa: Allocator, family: [:0]const u8, px: u16) Error!Font {
        const pat = c.FcNameParse(family.ptr) orelse return Error.NoSuchFont;
        defer c.FcPatternDestroy(pat);
        _ = c.FcConfigSubstitute(null, pat, c.FcMatchPattern);
        c.FcDefaultSubstitute(pat);

        var res: c.FcResult = undefined;
        const matched = c.FcFontMatch(null, pat, &res) orelse return Error.NoSuchFont;
        defer c.FcPatternDestroy(matched);
        if (res != c.FcResultMatch) return Error.NoSuchFont;

        var file: [*c]c.FcChar8 = undefined;
        if (c.FcPatternGetString(matched, "file", 0, &file) != c.FcResultMatch) {
            return Error.NoSuchFont;
        }

        var face: c.FT_Face = undefined;
        if (c.FT_New_Face(self.ft, @ptrCast(file), 0, &face) != 0) return Error.BadFont;
        errdefer _ = c.FT_Done_Face(face);

        if (c.FT_Set_Pixel_Sizes(face, 0, px) != 0) return Error.BadSize;

        // Created after the size is set: hb-ft reads the face's current size,
        // and a font created before would report metrics for the wrong one.
        const hb = c.hb_ft_font_create_referenced(face) orelse return Error.BadFont;

        const path = std.mem.span(@as([*:0]const u8, @ptrCast(file)));
        const owned_path = try gpa.dupe(u8, path);

        // 26.6 fixed point. Descender is negative, pointing below the
        // baseline, and is stored positive here because every caller wants a
        // magnitude.
        const m = face.*.size.*.metrics;
        return .{
            .gpa = gpa,
            .face = face,
            .hb = hb,
            .buf = c.hb_buffer_create() orelse return Error.OutOfMemory,
            .px = px,
            .path = owned_path,
            .ascent = f26dot6(m.ascender),
            .descent = -f26dot6(m.descender),
            .line_height = f26dot6(m.height),
        };
    }
};

fn f26dot6(v: c_long) f32 {
    return @as(f32, @floatFromInt(v)) / 64.0;
}

/// One font at one pixel size, with its rasterised glyphs cached.
///
/// Size is part of the identity rather than an argument, because the glyph
/// cache, the atlas slots and the metrics are all per size. Two sizes of the
/// same family are two `Font`s sharing one file on disk, which FreeType is
/// happy to do.
pub const Font = struct {
    gpa: Allocator,
    face: c.FT_Face,
    hb: *c.hb_font_t,
    /// Reused across calls. A HarfBuzz buffer holds the scratch arrays shaping
    /// needs, and recreating it per string would allocate on every keystroke.
    buf: *c.hb_buffer_t,
    px: u16,
    path: []u8,

    ascent: f32,
    descent: f32,
    /// The font's own preferred line spacing. Not used by a single-line run,
    /// and the number a line breaker will want.
    line_height: f32,

    /// Glyph id to its place in the atlas. Keyed by glyph id and not by
    /// codepoint, because that is what shaping returns and because the
    /// relation between the two is not one to one in either direction.
    cache: std.AutoHashMapUnmanaged(u32, Cached) = .empty,

    /// Scratch for the run being built, reused between calls.
    scratch: std.ArrayList(ui.Glyph) = .empty,

    const Cached = struct {
        slot: Slot,
        /// FreeType's bitmap offsets from the pen position, in whole pixels.
        left: i16,
        top: i16,
    };

    pub fn deinit(self: *Font) void {
        self.cache.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.gpa.free(self.path);
        c.hb_buffer_destroy(self.buf);
        c.hb_font_destroy(self.hb);
        _ = c.FT_Done_Face(self.face);
        self.* = undefined;
    }

    pub fn height(self: *const Font) f32 {
        return self.ascent + self.descent;
    }

    /// Shapes one line of UTF-8 and rasterises whatever is not already cached.
    ///
    /// The returned run borrows this font's scratch buffer, so it is valid
    /// until the next call on the same font. `Tree.setText` copies it, which is
    /// why that is the intended destination.
    pub fn shape(self: *Font, atlas: *Atlas, s: []const u8) Error!ui.TextRun {
        c.hb_buffer_reset(self.buf);
        c.hb_buffer_add_utf8(self.buf, s.ptr, @intCast(s.len), 0, @intCast(s.len));
        // Direction, script and language inferred from the text itself. For
        // Latin and Vietnamese this is right; for mixed-direction text it is
        // the thing a real itemiser replaces, and it is honest about being a
        // guess in a way that hardcoding LTR/Latin would not be.
        c.hb_buffer_guess_segment_properties(self.buf);
        c.hb_shape(self.hb, self.buf, null, 0);

        var n: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(self.buf, &n);
        const positions = c.hb_buffer_get_glyph_positions(self.buf, &n);
        const count: usize = @intCast(n);

        self.scratch.clearRetainingCapacity();
        try self.scratch.ensureTotalCapacity(self.gpa, count);

        var pen_x: f32 = 0;
        var pen_y: f32 = 0;
        for (0..count) |i| {
            const gid = infos[i].codepoint;
            const pos = positions[i];
            const entry = try self.glyph(atlas, gid);

            // The pen is fractional -- kerning and mark positioning are not
            // whole pixels -- and the glyph's position is rounded, because the
            // bitmap was rasterised on the pixel grid and sampling it anywhere
            // else is what makes text blurry. The pen itself is NOT rounded:
            // accumulating rounded advances drifts, and over a long line the
            // drift is visible as uneven spacing.
            const gx = @round(pen_x + f26dot6(pos.x_offset));
            const gy = @round(pen_y - f26dot6(pos.y_offset));

            // Every shaped glyph goes in the run, including the ones with no
            // ink. A space advances the pen and draws nothing, and dropping it
            // would leave a hole in the cluster sequence exactly where a caret
            // has to be able to sit. The scene builder skips the ones with no
            // ink, so this costs entries in the run and no quads in the scene.
            self.scratch.appendAssumeCapacity(.{
                .dx = gx + @as(f32, @floatFromInt(entry.left)),
                .dy = self.ascent + gy - @as(f32, @floatFromInt(entry.top)),
                .w = @floatFromInt(entry.slot.width()),
                .h = @floatFromInt(entry.slot.height()),
                .u0 = entry.slot.u0,
                .v0 = entry.slot.v0,
                .u1 = entry.slot.u1,
                .v1 = entry.slot.v1,
                .cluster = infos[i].cluster,
                .pen_x = pen_x,
            });

            pen_x += f26dot6(pos.x_advance);
            pen_y -= f26dot6(pos.y_advance);
        }

        return .{
            .glyphs = self.scratch.items,
            .width = pen_x,
            .ascent = self.ascent,
            .descent = self.descent,
        };
    }

    /// The number of glyphs shaping produces for a string. Separate from
    /// `shape` so a test can ask the question without an atlas.
    pub fn glyphCount(self: *Font, s: []const u8) usize {
        c.hb_buffer_reset(self.buf);
        c.hb_buffer_add_utf8(self.buf, s.ptr, @intCast(s.len), 0, @intCast(s.len));
        c.hb_buffer_guess_segment_properties(self.buf);
        c.hb_shape(self.hb, self.buf, null, 0);
        var n: c_uint = 0;
        _ = c.hb_buffer_get_glyph_infos(self.buf, &n);
        return @intCast(n);
    }

    fn glyph(self: *Font, atlas: *Atlas, gid: u32) Error!Cached {
        if (self.cache.get(gid)) |e| return e;

        // `FT_LOAD_RENDER` loads and rasterises in one call. Default hinting
        // and default (horizontal, 8-bit) antialiasing: matching what a desktop
        // expects matters more here than any of the alternatives.
        if (c.FT_Load_Glyph(self.face, gid, c.FT_LOAD_RENDER) != 0) {
            return Error.UnsupportedGlyphFormat;
        }
        const g = self.face.*.glyph;
        const bm = g.*.bitmap;
        if (bm.pixel_mode != c.FT_PIXEL_MODE_GRAY and bm.rows != 0) {
            return Error.UnsupportedGlyphFormat;
        }

        const slot = try atlas.reserve(@intCast(bm.width), @intCast(bm.rows));
        if (slot.width() > 0) {
            // A negative pitch means the rows are stored bottom-up. FreeType
            // does not produce that for `FT_PIXEL_MODE_GRAY`, so rather than
            // write an untested flipping path, say so.
            const pitch = bm.pitch;
            if (pitch < 0) return Error.UnsupportedGlyphFormat;
            const stride: usize = @intCast(pitch);
            const src = bm.buffer[0 .. stride * bm.rows];
            atlas.blit(slot, src, stride);
        }

        const entry: Cached = .{
            .slot = slot,
            .left = @intCast(g.*.bitmap_left),
            .top = @intCast(g.*.bitmap_top),
        };
        try self.cache.put(self.gpa, gid, entry);
        return entry;
    }
};

/// Shapes `s` and installs it on `el`.
///
/// The whole point of the module in one function: the caller names an element
/// and a string, and the font engine, the atlas and the tree are the three
/// things it has to have already decided about.
pub fn setText(
    t: *ui.Tree,
    el: ui.Index,
    font: *Font,
    atlas: *Atlas,
    s: []const u8,
) (Error || ui.Error)!void {
    const run = try font.shape(atlas, s);
    try t.setText(el, run);
}

// ---------------------------------------------------------------------- tests
//
// These need a font installed, which is why they are behind `zig build
// test-text` and not `zig build test`. They avoid asserting exact pixel
// metrics, because those are properties of whichever font fontconfig matched
// and of the FreeType version doing the hinting, and a test that breaks when
// the distribution updates a font is a test nobody keeps. What they assert is
// the things that must hold for ANY font: the relations between the numbers,
// and the shaping behaviour the module exists for.

const testing = std.testing;

fn openSans(lib: *Library, gpa: Allocator) !Font {
    return lib.open(gpa, "sans", 15) catch |err| switch (err) {
        Error.NoSuchFont => return error.SkipZigTest,
        else => return err,
    };
}

test "a matched font has sane metrics" {
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();

    try testing.expect(font.ascent > 0);
    try testing.expect(font.descent > 0);
    // At 15 pixels, ascent plus descent is within a factor of two of 15 for
    // anything that is actually a text font.
    try testing.expect(font.height() >= 10 and font.height() <= 30);
    // Line height includes the gap the font asks for, so it is never less than
    // the glyphs it has to hold.
    // `line_height` is NOT `ascent + descent`, and it is not necessarily
    // larger. Noto Sans at 15 pixels reports ascent 17, descent 5 and line
    // height 20: the font's preferred line spacing is two pixels LESS than the
    // extent it claims for its glyphs, because ascent and descent are maxima
    // over every glyph in the font -- including accents almost no line
    // contains -- while line height is what the designer wants lines set at.
    //
    // So the two numbers answer different questions and a line breaker must use
    // `line_height`, not the sum. This assertion exists to record the
    // relationship rather than to check it: it is not a bug in the font.
    try testing.expect(font.line_height > 0);
    try testing.expect(font.line_height >= font.ascent);
    try testing.expect(font.path.len > 0);
}

test "shaping produces glyphs, an advance, and an atlas that fills up" {
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 256, 256);
    defer atlas.deinit();

    const run = try font.shape(&atlas, "Hello");
    try testing.expectEqual(@as(usize, 5), run.glyphs.len);
    try testing.expect(run.width > 0);
    try testing.expectEqual(font.ascent, run.ascent);

    // Glyphs advance rightwards and do not all sit on top of each other.
    try testing.expect(run.glyphs[4].dx > run.glyphs[0].dx);
    // Every glyph got a non-empty atlas rectangle, and its quad is the size of
    // that rectangle -- the invariant the exact-texel sampling depends on.
    for (run.glyphs) |g| {
        try testing.expect(g.u1 > g.u0 and g.v1 > g.v0);
        try testing.expectEqual(@as(f32, @floatFromInt(g.u1 - g.u0)), g.w);
        try testing.expectEqual(@as(f32, @floatFromInt(g.v1 - g.v0)), g.h);
    }
    try testing.expect(atlas.used > 0);
}

test "clusters are byte offsets into the string that was shaped" {
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 512, 512);
    defer atlas.deinit();

    const s = "tiếng Việt";
    const run = try font.shape(&atlas, s);

    // Every cluster is a real byte offset and a character boundary. A cluster
    // pointing into the middle of a multi-byte character would place a caret
    // somewhere the document cannot be split.
    for (run.glyphs) |g| {
        try testing.expect(g.cluster < s.len);
        try testing.expectEqual(
            @as(usize, g.cluster),
            ui.offsets.alignToChar(s, g.cluster),
        );
    }

    // Left to right, so clusters do not go backwards.
    var last: u32 = 0;
    for (run.glyphs) |g| {
        try testing.expect(g.cluster >= last);
        last = g.cluster;
    }

    // The first glyph starts at byte zero and the pen starts at zero.
    try testing.expectEqual(@as(u32, 0), run.glyphs[0].cluster);
    try testing.expectEqual(@as(f32, 0), run.glyphs[0].pen_x);
}

test "a caret can be placed at every character boundary" {
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 512, 512);
    defer atlas.deinit();

    const s = "tiếng Việt";
    const run = try font.shape(&atlas, s);

    // Walking the string forwards, the caret must never go backwards and must
    // reach the full width at the end. `ế` is three bytes and `Việt` has a
    // mark, so this is the case where a per-codepoint model drifts.
    var prev: f32 = -1;
    var b: usize = 0;
    while (b <= s.len) : (b += 1) {
        if (b != ui.offsets.alignToChar(s, b)) continue;
        const x = run.caretX(b);
        try testing.expect(x >= prev);
        prev = x;
    }
    try testing.expectEqual(run.width, run.caretX(s.len));

    // And a click on each caret comes back to the byte it was made from.
    b = 0;
    while (b <= s.len) : (b += 1) {
        if (b != ui.offsets.alignToChar(s, b)) continue;
        const back = run.byteAt(run.caretX(b), s.len);
        try testing.expectEqual(b, back);
    }
}

test "a space advances the pen and emits no glyph" {
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 256, 256);
    defer atlas.deinit();

    const one = try font.shape(&atlas, "ab");
    const w_one = one.width;

    const two = try font.shape(&atlas, "a b");
    // Shaping saw three characters, and all three are in the run: the space is
    // kept because a caret has to be able to sit on either side of it.
    try testing.expectEqual(@as(usize, 3), font.glyphCount("a b"));
    try testing.expectEqual(@as(usize, 3), two.glyphs.len);
    // Exactly one of them has nothing to draw.
    var inked: usize = 0;
    for (two.glyphs) |g| {
        if (g.hasInk()) inked += 1;
    }
    try testing.expectEqual(@as(usize, 2), inked);
    // The space still took width, and the caret after it is past the gap.
    try testing.expect(two.width > w_one);
    try testing.expect(two.caretX(2) > two.caretX(1));
}

test "glyphs are cached, so the atlas does not grow on a repeat" {
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 256, 256);
    defer atlas.deinit();

    _ = try font.shape(&atlas, "caching");
    const after_first = atlas.used;
    _ = try font.shape(&atlas, "caching");
    try testing.expectEqual(after_first, atlas.used);
    // A new letter does cost space.
    _ = try font.shape(&atlas, "z");
    try testing.expect(atlas.used > after_first);
}

test "Vietnamese is shaped, not mapped codepoint by codepoint" {
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 512, 512);
    defer atlas.deinit();

    // Decomposed: `e` + combining circumflex + combining acute. Three
    // codepoints, and what a font should draw is one `ế`. `ệ` is `e` + dot
    // below + circumflex, in canonical order (the dot below has the lower
    // combining class). It used to be spelled `e` + dot below alone, which is
    // `ẹ` -- a different letter that happens to be as wide as `ệ` in every
    // font this ran on, so the width assertion below still passed.
    const decomposed = "ti\u{0065}\u{0302}\u{0301}ng vi\u{0065}\u{0323}\u{0302}t";
    const precomposed = "tiếng việt";

    const a = try font.shape(&atlas, precomposed);
    const a_width = a.width;
    const a_glyphs = a.glyphs.len;

    const b = try font.shape(&atlas, decomposed);

    // The two spellings are the same text and must set to the same width. This
    // is the assertion a per-codepoint renderer fails: it would draw the
    // combining marks as separate advancing characters and come out wider.
    try testing.expectApproxEqAbs(a_width, b.width, 0.5);
    try testing.expectEqual(a_glyphs, b.glyphs.len);

    // `tiếng việt` is 10 codepoints and sets as 9 drawable glyphs plus a
    // space. Stated as a bound rather than an equality because whether the
    // tone mark is a separate positioned glyph is a property of the font.
    try testing.expect(b.glyphs.len >= 9);

    // The stacked marks put ink above the bare letter: `ế` must start higher
    // than `e` does. This used to compare `tiếng` against `ting`, which asks
    // whether the marks rise above the `i`'s dot -- a property of the font,
    // not of shaping. Verdana, which fontconfig matches for "sans" on a Mac,
    // sets `ế` at 15 px with its top exactly level with the dot.
    // Read before shaping again: a run borrows the font's scratch buffer.
    const plain = try font.shape(&atlas, "e");
    try testing.expectEqual(@as(usize, 1), plain.glyphs.len);
    const dy_plain = plain.glyphs[0].dy;
    const marked = try font.shape(&atlas, "ế");
    try testing.expect(marked.glyphs.len >= 1);
    var min_dy_marked: f32 = 1e9;
    for (marked.glyphs) |g| min_dy_marked = @min(min_dy_marked, g.dy);
    try testing.expect(min_dy_marked < dy_plain);
}

test "a run installs on a tree and sizes the element" {
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 256, 256);
    defer atlas.deinit();

    var t = try ui.Tree.init(testing.allocator);
    defer t.deinit();
    const label = try t.appendChild(t.root(), .{});

    try setText(&t, label, &font, &atlas, "Xin chào");
    t.layout(.{ .w = 400, .h = 300 });

    const b = t.bounds(label);
    try testing.expect(b.w > 0);
    try testing.expectApproxEqAbs(font.height(), b.h, 0.01);
    try testing.expectApproxEqAbs(t.text(label).width, b.w, 0.01);

    // Re-setting shorter text shrinks it, which is the whole reason `setText`
    // dirties layout where `setPaint` does not.
    try setText(&t, label, &font, &atlas, "X");
    _ = t.flush();
    try testing.expect(t.bounds(label).w < b.w);
}

test "recolouring text runs no layout" {
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 256, 256);
    defer atlas.deinit();

    var t = try ui.Tree.init(testing.allocator);
    defer t.deinit();
    const label = try t.appendChild(t.root(), .{});
    try setText(&t, label, &font, &atlas, "theme me");
    t.layout(.{ .w = 400, .h = 300 });

    const before = t.revision;
    t.setPaint(label, .{ .text_color = ui.Color.hex(0xFF0000) });
    const stats = t.flush();
    // The scene must be rebuilt...
    try testing.expect(t.revision > before);
    // ...and the flexbox engine must not have run at all.
    try testing.expectEqual(@as(u32, 0), stats.total());
    try testing.expectEqual(@as(u32, 0), stats.full_layouts);
}
