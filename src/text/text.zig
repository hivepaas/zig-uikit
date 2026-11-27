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
        return self.openScaled(gpa, family, px, 1);
    }

    /// Opens a font for a display with `scale` pixels per layout unit: `size`
    /// is in layout units, the face is rasterised at `size * scale` device
    /// pixels, and every number a shaped run carries comes back in layout
    /// units again.
    ///
    /// This is the answer `Quad.scaled` points at. A 13-point label on a 2x
    /// display is a 26-pixel font, hinted and rasterised at 26 pixels, not a
    /// 13-pixel bitmap stretched over twice the area -- which could not be
    /// sampled one texel per pixel and would be blurry if it could. Layout
    /// still sees a 13-point label, so a tree laid out for one display does not
    /// change shape on another; only the bitmaps differ.
    ///
    /// Positions in the run are whole device pixels divided by `scale`, so they
    /// are exact in binary for a scale of 2 but not, say, 1.5. The scene
    /// builder therefore snaps to the device grid itself (`Scene.pixel_scale`)
    /// rather than trusting the division to round-trip.
    pub fn openScaled(self: *Library, gpa: Allocator, family: [:0]const u8, size: u16, scale: f32) Error!Font {
        std.debug.assert(scale > 0);
        const px_f = @round(@as(f32, @floatFromInt(size)) * scale);
        if (px_f < 1 or px_f > std.math.maxInt(u16)) return Error.BadSize;
        const px: u16 = @intFromFloat(px_f);

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
            .ft = self.ft,
            .face = face,
            .hb = hb,
            .buf = c.hb_buffer_create() orelse return Error.OutOfMemory,
            .px = px,
            .scale = scale,
            .path = owned_path,
            .ascent = f26dot6(m.ascender),
            .descent = -f26dot6(m.descender),
            .line_height = f26dot6(m.height),
        };
    }
};

/// The byte after the character starting at `b`. A local copy of
/// `offsets.nextChar`, because this module takes core as `ui` and reaching
/// into its internals for three lines would be worse than three lines.
fn offsets_nextChar(s: []const u8, b: usize) usize {
    if (b >= s.len) return s.len;
    const n = std.unicode.utf8ByteSequenceLength(s[b]) catch 1;
    return @min(b + n, s.len);
}

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
    /// FreeType's handle, so a font can open the fallbacks it needs without a
    /// reference to the `Library` struct -- which is returned by value and
    /// therefore moves, where this pointer does not.
    ft: c.FT_Library,
    face: c.FT_Face,
    hb: *c.hb_font_t,
    /// Reused across calls. A HarfBuzz buffer holds the scratch arrays shaping
    /// needs, and recreating it per string would allocate on every keystroke.
    buf: *c.hb_buffer_t,
    /// The size the face is rasterised at, in device pixels.
    px: u16,
    /// Device pixels per layout unit; 1 unless opened with `openScaled`.
    scale: f32 = 1,
    path: []u8,

    /// These three are in device pixels, like everything FreeType and HarfBuzz
    /// report. `height()` and the runs `shape` returns are in layout units.
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

    /// The paragraph's direction runs, reused between calls.
    bidi_runs: std.ArrayList(ui.bidi.Run) = .empty,
    /// The same runs as the shaped run carries them: glyph ranges rather than
    /// byte ranges. Left empty for text that is all one direction, which is
    /// what `TextRun.spans` takes to mean a single left-to-right stretch.
    spans: std.ArrayList(ui.glyph.Span) = .empty,

    /// Fonts opened to cover characters this one does not have.
    ///
    /// Owned, and kept per font rather than per library because the glyph
    /// cache is keyed by glyph id: the same id means different glyphs in two
    /// faces, so two faces cannot share a cache and a fallback is simply
    /// another `Font`.
    fallbacks: std.ArrayList(Font) = .empty,

    /// Characters that had no glyph in this font and none in any fallback
    /// either, since this font was opened.
    ///
    /// Reported rather than hidden: a missing glyph draws the font's `.notdef`
    /// box, and a toolkit that silently draws boxes is one you find out about
    /// from a screenshot.
    missing: u32 = 0,

    const Cached = struct {
        slot: Slot,
        /// FreeType's bitmap offsets from the pen position, in whole pixels.
        left: i16,
        top: i16,
    };

    pub fn deinit(self: *Font) void {
        for (self.fallbacks.items) |*f| f.deinit();
        self.fallbacks.deinit(self.gpa);
        self.cache.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.bidi_runs.deinit(self.gpa);
        self.spans.deinit(self.gpa);
        self.gpa.free(self.path);
        c.hb_buffer_destroy(self.buf);
        c.hb_font_destroy(self.hb);
        _ = c.FT_Done_Face(self.face);
        self.* = undefined;
    }

    /// Ascent plus descent, in layout units.
    pub fn height(self: *const Font) f32 {
        return (self.ascent + self.descent) / self.scale;
    }

    /// Shapes one line of UTF-8 and rasterises whatever is not already cached.
    ///
    /// The returned run borrows this font's scratch buffer, so it is valid
    /// until the next call on the same font. `Tree.setText` copies it, which is
    /// why that is the intended destination.
    /// Shapes one line of UTF-8 and rasterises whatever is not already cached.
    ///
    /// The returned run borrows this font's scratch buffer, so it is valid
    /// until the next call on the same font. `Tree.setText` copies it, which is
    /// why that is the intended destination.
    ///
    /// Characters this font lacks are shaped again with a font that has them;
    /// see `fallbackFor`. The baseline stays this font's, so a line that mixes
    /// families still sits on one.
    pub fn shape(self: *Font, atlas: *Atlas, s: []const u8) Error!ui.TextRun {
        self.scratch.clearRetainingCapacity();
        try self.scratch.ensureTotalCapacity(self.gpa, s.len);

        var pen_x: f32 = 0;
        var max_ascent = self.ascent;
        var max_descent = self.descent;

        // One buffer per direction run, in visual order. HarfBuzz does not do
        // bidi: handed a right-to-left buffer it reverses everything in it,
        // including an English word, so `"אבג abc דהו"` came out with `abc`
        // as `cba`. See `src/bidi.zig`.
        //
        // Text with no right-to-left character in it -- nearly all of it --
        // takes the single-run path and never touches the algorithm.
        self.spans.clearRetainingCapacity();
        if (ui.bidi.hasRtl(s)) {
            _ = try ui.bidi.runs(self.gpa, s, null, &self.bidi_runs);
            for (self.bidi_runs.items) |r| {
                const first = self.scratch.items.len;
                try self.shapeRange(
                    atlas,
                    s,
                    r.start,
                    r.end - r.start,
                    &pen_x,
                    &max_ascent,
                    &max_descent,
                    true,
                    r.direction(),
                );
                // The glyphs a direction run produced are contiguous, fallback
                // included: a fallback appends into the same list in place.
                try self.spans.append(self.gpa, .{
                    .first = @intCast(first),
                    .count = @intCast(self.scratch.items.len - first),
                    .start = @intCast(r.start),
                    .end = @intCast(r.end),
                    .rtl = r.direction() == .rtl,
                });
            }
            // One run is one direction, which is what an empty table already
            // means. Keeping it empty is what lets every caller skip the
            // general case without a flag to check.
            if (self.spans.items.len == 1 and !self.spans.items[0].rtl) {
                self.spans.clearRetainingCapacity();
            }
        } else {
            try self.shapeRange(atlas, s, 0, s.len, &pen_x, &max_ascent, &max_descent, true, .ltr);
        }

        // A fallback with a taller ascent needs the whole line pushed down,
        // because the baseline was placed at this font's ascent before the
        // taller one was known. One pass over the glyphs rather than two over
        // the text: the alternative is shaping everything twice to find the
        // maximum first, and fallbacks are rare.
        if (max_ascent > self.ascent) {
            const d = max_ascent - self.ascent;
            for (self.scratch.items) |*g| g.dy += d;
        }

        // Everything above is device pixels. The run leaves in layout units,
        // texel coordinates aside: those address the atlas, which is pixels by
        // definition, and the scene builder relies on `w * scale` recovering
        // the texel extent.
        if (self.scale != 1) {
            const inv = 1 / self.scale;
            for (self.scratch.items) |*g| {
                g.dx *= inv;
                g.dy *= inv;
                g.w *= inv;
                g.h *= inv;
                g.pen_x *= inv;
            }
        }

        return .{
            .glyphs = self.scratch.items,
            .spans = self.spans.items,
            .width = pen_x / self.scale,
            .ascent = max_ascent / self.scale,
            .descent = max_descent / self.scale,
        };
    }

    /// Shapes `s[off..][0..len]` with this font and appends to `self.scratch`.
    ///
    /// `pen_x` is carried in and out, so a caller can shape a range, hand the
    /// next one to another font, and come back. `baseline` is the y every
    /// glyph is placed against -- the *outer* font's ascent, not this one's,
    /// which is what keeps a mixed line on one baseline.
    fn shapeRange(
        self: *Font,
        atlas: *Atlas,
        s: []const u8,
        off: usize,
        len: usize,
        pen_x: *f32,
        max_ascent: *f32,
        max_descent: *f32,
        allow_fallback: bool,
        dir: ui.bidi.Direction,
    ) Error!void {
        try self.shapeInto(atlas, s, off, len, pen_x, self.ascent, max_ascent, max_descent, allow_fallback, self, dir);
    }

    fn shapeInto(
        self: *Font,
        atlas: *Atlas,
        s: []const u8,
        off: usize,
        len: usize,
        pen_x: *f32,
        baseline: f32,
        max_ascent: *f32,
        max_descent: *f32,
        allow_fallback: bool,
        out_owner: *Font,
        dir: ui.bidi.Direction,
    ) Error!void {
        if (len == 0) return;
        c.hb_buffer_reset(self.buf);
        // The WHOLE string with an offset, not the substring: HarfBuzz then
        // reports clusters as byte offsets into `s`, so a fallback's glyphs
        // carry the same offsets everything else does and a caret can still
        // be placed by byte.
        c.hb_buffer_add_utf8(self.buf, s.ptr, @intCast(s.len), @intCast(off), @intCast(len));
        // The direction is decided, not guessed: `bidi.runs` resolved it for
        // the whole paragraph and this is one of its runs. Set before
        // guessing, because `hb_buffer_guess_segment_properties` only fills
        // in what is still unset -- so script and language are still inferred
        // from the text, which is right for them and was never right for
        // direction.
        c.hb_buffer_set_direction(self.buf, if (dir == .rtl)
            c.HB_DIRECTION_RTL
        else
            c.HB_DIRECTION_LTR);
        c.hb_buffer_guess_segment_properties(self.buf);
        c.hb_shape(self.hb, self.buf, null, 0);

        var n: c_uint = 0;
        const infos = c.hb_buffer_get_glyph_infos(self.buf, &n);
        const positions = c.hb_buffer_get_glyph_positions(self.buf, &n);
        const count: usize = @intCast(n);

        var pen_y: f32 = 0;
        var i: usize = 0;
        while (i < count) {
            // Glyph zero is `.notdef`: the font has no glyph for this
            // character and would draw its empty box. A run of them is one
            // stretch of text to hand to another font.
            if (allow_fallback and infos[i].codepoint == 0) {
                var j = i;
                while (j < count and infos[j].codepoint == 0) j += 1;

                // The byte range the run covers, which is NOT simply the
                // first and last clusters. HarfBuzz emits glyphs in visual
                // order, so in a right-to-left run the clusters **descend**
                // along the array: the run starts at the last of them and
                // ends where the glyph before it began.
                //
                // Getting this wrong does not produce a missing glyph, it
                // produces a duplicated line. Shaping `"אבג abc דהו"` took
                // the end of the string as the end of the run and shaped
                // thirteen bytes of it a second time, so the text appeared
                // twice -- found by printing the clusters, not by reading the
                // code.
                const rtl = c.hb_buffer_get_direction(self.buf) == c.HB_DIRECTION_RTL;
                const c0: usize = if (rtl)
                    @intCast(infos[j - 1].cluster)
                else
                    @intCast(infos[i].cluster);
                const c1: usize = if (rtl)
                    (if (i > 0) @intCast(infos[i - 1].cluster) else off + len)
                else
                    (if (j < count) @intCast(infos[j].cluster) else off + len);

                if (c1 > c0) {
                    const cp = std.unicode.utf8Decode(s[c0..offsets_nextChar(s, c0)]) catch 0;
                    if (self.fallbackFor(cp)) |fb| {
                        try fb.shapeInto(
                            atlas,
                            s,
                            c0,
                            c1 - c0,
                            pen_x,
                            baseline,
                            max_ascent,
                            max_descent,
                            // One level only. A fallback that still has no
                            // glyph has nothing better to offer, and the
                            // search has to terminate.
                            false,
                            out_owner,
                            // The same direction: this is a stretch of one
                            // bidi run, not a run of its own.
                            dir,
                        );
                        max_ascent.* = @max(max_ascent.*, fb.ascent);
                        max_descent.* = @max(max_descent.*, fb.descent);
                        i = j;
                        continue;
                    }
                    self.missing += 1;
                }
            }

            const gid = infos[i].codepoint;
            const pos = positions[i];
            const entry = try self.glyph(atlas, gid);

            // The pen is fractional -- kerning and mark positioning are not
            // whole pixels -- and the glyph's position is rounded, because the
            // bitmap was rasterised on the pixel grid and sampling it anywhere
            // else is what makes text blurry. The pen itself is NOT rounded:
            // accumulating rounded advances drifts, and over a long line the
            // drift is visible as uneven spacing.
            const gx = @round(pen_x.* + f26dot6(pos.x_offset));
            const gy = @round(pen_y - f26dot6(pos.y_offset));

            // Every shaped glyph goes in the run, including the ones with no
            // ink. A space advances the pen and draws nothing, and dropping it
            // would leave a hole in the cluster sequence exactly where a caret
            // has to be able to sit. The scene builder skips the ones with no
            // ink, so this costs entries in the run and no quads in the scene.
            try out_owner.scratch.append(out_owner.gpa, .{
                .dx = gx + @as(f32, @floatFromInt(entry.left)),
                .dy = baseline + gy - @as(f32, @floatFromInt(entry.top)),
                .w = @floatFromInt(entry.slot.width()),
                .h = @floatFromInt(entry.slot.height()),
                .u0 = entry.slot.u0,
                .v0 = entry.slot.v0,
                .u1 = entry.slot.u1,
                .v1 = entry.slot.v1,
                .cluster = infos[i].cluster,
                .pen_x = pen_x.*,
            });

            pen_x.* += f26dot6(pos.x_advance);
            pen_y -= f26dot6(pos.y_advance);
            i += 1;
        }
    }

    /// A font that has `cp`, at this font's size, or null.
    ///
    /// Asked of fontconfig, which is the only thing on a Linux desktop that
    /// knows what is installed and in what order the user wants it tried --
    /// the same mechanism that put Noto Sans in front of this request in the
    /// first place. The result is verified with `FT_Get_Char_Index` rather
    /// than trusted: matching never fails on a system with any font at all,
    /// so a character nothing covers comes back as some font that does not
    /// have it either.
    fn fallbackFor(self: *Font, cp: u21) ?*Font {
        if (cp == 0) return null;
        for (self.fallbacks.items) |*f| {
            if (c.FT_Get_Char_Index(f.face, cp) != 0) return f;
        }

        const cs = c.FcCharSetCreate() orelse return null;
        defer c.FcCharSetDestroy(cs);
        if (c.FcCharSetAddChar(cs, cp) == 0) return null;

        const pat = c.FcPatternCreate() orelse return null;
        defer c.FcPatternDestroy(pat);
        if (c.FcPatternAddCharSet(pat, "charset", cs) == 0) return null;
        _ = c.FcPatternAddDouble(pat, "pixelsize", @floatFromInt(self.px));
        _ = c.FcConfigSubstitute(null, pat, c.FcMatchPattern);
        c.FcDefaultSubstitute(pat);

        var res: c.FcResult = undefined;
        const matched = c.FcFontMatch(null, pat, &res) orelse return null;
        defer c.FcPatternDestroy(matched);
        if (res != c.FcResultMatch) return null;

        var file: [*c]c.FcChar8 = undefined;
        if (c.FcPatternGetString(matched, "file", 0, &file) != c.FcResultMatch) return null;

        var face: c.FT_Face = undefined;
        if (c.FT_New_Face(self.ft, @ptrCast(file), 0, &face) != 0) return null;
        var ok = false;
        defer if (!ok) {
            _ = c.FT_Done_Face(face);
        };
        if (c.FT_Get_Char_Index(face, cp) == 0) return null;
        if (c.FT_Set_Pixel_Sizes(face, 0, self.px) != 0) return null;
        const hb = c.hb_ft_font_create_referenced(face) orelse return null;
        const buf = c.hb_buffer_create() orelse {
            c.hb_font_destroy(hb);
            return null;
        };
        const path = std.mem.span(@as([*:0]const u8, @ptrCast(file)));
        const owned = self.gpa.dupe(u8, path) catch {
            c.hb_buffer_destroy(buf);
            c.hb_font_destroy(hb);
            return null;
        };

        const m = face.*.size.*.metrics;
        self.fallbacks.append(self.gpa, .{
            .gpa = self.gpa,
            .ft = self.ft,
            .face = face,
            .hb = hb,
            .buf = buf,
            .px = self.px,
            // One: the outer font converts the whole run to layout units once,
            // and doing it twice would halve these glyphs again.
            .scale = 1,
            .path = owned,
            .ascent = f26dot6(m.ascender),
            .descent = -f26dot6(m.descender),
            .line_height = f26dot6(m.height),
        }) catch {
            self.gpa.free(owned);
            c.hb_buffer_destroy(buf);
            c.hb_font_destroy(hb);
            return null;
        };
        ok = true;
        return &self.fallbacks.items[self.fallbacks.items.len - 1];
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

    /// Shapes one paragraph and breaks it into lines no wider than `max_width`.
    ///
    /// The paragraph is shaped **once** and then sliced: the shaper already gave
    /// every glyph a pen position and a cluster, so the width of any prefix is a
    /// lookup. See `text_layout.zig` for when that is and is not the right trade.
    ///
    /// `glyphs` and `lines` are the caller's, and the returned run borrows the
    /// first -- `Tree.setText` copies it, which is the intended destination.
    pub fn shapeWrapped(
        self: *Font,
        atlas: *Atlas,
        s: []const u8,
        max_width: f32,
        glyphs: *std.ArrayList(ui.Glyph),
        lines: *std.ArrayList(ui.text_layout.Line),
    ) (Error || Allocator.Error)!ui.text_layout.Wrapped {
        const one = try self.shape(atlas, s);
        return ui.text_layout.wrap(self.gpa, one, s, max_width, self.line_height, glyphs, lines);
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
/// Shapes `s`, wraps it to `max_width`, and installs it on `el`.
pub fn setWrappedText(
    t: *ui.Tree,
    el: ui.Index,
    font: *Font,
    atlas: *Atlas,
    s: []const u8,
    max_width: f32,
    glyphs: *std.ArrayList(ui.Glyph),
    lines: *std.ArrayList(ui.text_layout.Line),
) (Error || ui.Error)!ui.text_layout.Wrapped {
    const w = try font.shapeWrapped(atlas, s, max_width, glyphs, lines);
    try t.setText(el, w.run);
    return w;
}

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

test "a font opened for a 2x display is the device-size font, measured in layout units" {
    var lib = try Library.init();
    defer lib.deinit();
    var device = try lib.open(testing.allocator, "sans", 26);
    defer device.deinit();
    var scaled = try lib.openScaled(testing.allocator, "sans", 13, 2);
    defer scaled.deinit();
    try testing.expectEqual(@as(u16, 26), scaled.px);
    try testing.expectEqual(device.height() / 2, scaled.height());

    var a1 = try Atlas.init(testing.allocator, 512, 512);
    defer a1.deinit();
    var a2 = try Atlas.init(testing.allocator, 512, 512);
    defer a2.deinit();

    const s = "tiếng Việt";
    // Two fonts, two scratch buffers, so both runs stay valid together.
    const want = try device.shape(&a1, s);
    const got = try scaled.shape(&a2, s);
    try testing.expectEqual(want.glyphs.len, got.glyphs.len);
    try testing.expectEqual(want.width / 2, got.width);
    try testing.expectEqual(want.ascent / 2, got.ascent);
    try testing.expectEqual(want.descent / 2, got.descent);
    for (want.glyphs, got.glyphs) |w, g| {
        // The same bitmap, hinted at 26 pixels, in the same atlas place...
        try testing.expectEqual(w.u0, g.u0);
        try testing.expectEqual(w.v0, g.v0);
        try testing.expectEqual(w.u1, g.u1);
        try testing.expectEqual(w.v1, g.v1);
        try testing.expectEqual(w.cluster, g.cluster);
        // ...at half the distance, so that layout sees a 13-point label.
        try testing.expectEqual(w.dx / 2, g.dx);
        try testing.expectEqual(w.dy / 2, g.dy);
        try testing.expectEqual(w.w / 2, g.w);
        try testing.expectEqual(w.h / 2, g.h);
        try testing.expectEqual(w.pen_x / 2, g.pen_x);
    }
    try testing.expectEqualSlices(u8, a1.pixels, a2.pixels);
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

test "a paragraph wraps between Vietnamese syllables, with a real font" {
    // The core's line-breaking tests use hand-built runs where every glyph is
    // the same width. This one uses a font, so it is the test that the two
    // halves fit together: HarfBuzz's clusters are byte offsets into the same
    // string the breaker looks at, and `ế` is three bytes in both.
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 256, 256);
    defer atlas.deinit();

    var glyphs: std.ArrayList(ui.Glyph) = .empty;
    defer glyphs.deinit(testing.allocator);
    var lines: std.ArrayList(ui.text_layout.Line) = .empty;
    defer lines.deinit(testing.allocator);

    const s = "tiếng Việt rất hay và rất khó sắp chữ cho đúng";
    const one = try font.shape(&atlas, s);
    const full_width = one.width;

    // A third of the natural width, so it has to break several times.
    const w = try font.shapeWrapped(&atlas, s, full_width / 3, &glyphs, &lines);
    try testing.expect(w.lines.len >= 3);
    try testing.expectEqual(@as(u32, @intCast(w.lines.len)), w.run.lines);

    // Every line is whole syllables and valid UTF-8, and none of them is
    // wider than the limit unless it is a single word that cannot fit.
    for (w.lines) |ln| {
        const text = s[ln.start..ln.end];
        try testing.expect(std.unicode.utf8ValidateSlice(text));
        try testing.expect(text.len == 0 or text[0] != ' ');
        try testing.expect(ln.width <= full_width / 3 + 0.01);
    }

    // The lines reassemble into the original, give or take the spaces the
    // breaks consumed.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (w.lines, 0..) |ln, i| {
        if (i > 0) try joined.append(testing.allocator, ' ');
        try joined.appendSlice(testing.allocator, s[ln.start..ln.end]);
    }
    try testing.expectEqualStrings(s, joined.items);

    // And the box is the stack, which is what makes an element sized for it.
    try testing.expect(w.run.height() > one.height());
    try testing.expectEqual(font.line_height, w.run.line_height);
}

test "a character the family lacks is shaped by a font that has it" {
    // Noto Sans has no CJK, no Hebrew and no arrows; before this, all three
    // came out as the font's `.notdef` box and nothing said so.
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 512, 512);
    defer atlas.deinit();

    const s = "tiếng 日本語 việt";
    const run = try font.shape(&atlas, s);
    try testing.expect(run.glyphs.len > 0);

    // A fallback was opened, and it is not the font we started with.
    try testing.expect(font.fallbacks.items.len >= 1);
    try testing.expect(!std.mem.eql(u8, font.path, font.fallbacks.items[0].path));

    // Every CJK character got ink. Without a fallback they are `.notdef`,
    // which is a box with ink too -- so the test is that each one has a
    // DIFFERENT atlas rectangle, which three copies of one box would not.
    const cjk_start = "tiếng ".len;
    var seen: [3]ui.Glyph = undefined;
    var found: usize = 0;
    for (run.glyphs) |g| {
        if (g.cluster >= cjk_start and g.cluster < cjk_start + 9 and g.hasInk()) {
            if (found < 3) seen[found] = g;
            found += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), found);
    try testing.expect(seen[0].u0 != seen[1].u0 or seen[0].v0 != seen[1].v0);
    try testing.expect(seen[1].u0 != seen[2].u0 or seen[1].v0 != seen[2].v0);

    // And nothing was left without a glyph.
    try testing.expectEqual(@as(u32, 0), font.missing);
}

test "a fallback keeps the baseline and the byte offsets" {
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 512, 512);
    defer atlas.deinit();

    const s = "a日b";
    const run = try font.shape(&atlas, s);
    try testing.expectEqual(@as(usize, 3), run.glyphs.len);

    // Clusters are byte offsets into the whole string, not into the piece
    // the fallback was handed: 0, 1, 4.
    try testing.expectEqual(@as(u32, 0), run.glyphs[0].cluster);
    try testing.expectEqual(@as(u32, 1), run.glyphs[1].cluster);
    try testing.expectEqual(@as(u32, 4), run.glyphs[2].cluster);

    // The pen only moves forward, and the fallback glyph is between its
    // neighbours rather than back at the origin.
    try testing.expect(run.glyphs[0].pen_x < run.glyphs[1].pen_x);
    try testing.expect(run.glyphs[1].pen_x < run.glyphs[2].pen_x);
    try testing.expectEqual(@as(f32, 0), run.glyphs[0].pen_x);

    // And a caret can still be placed by byte, which is the whole reason the
    // clusters have to be absolute.
    try testing.expectEqual(run.glyphs[1].pen_x, run.caretX(1));
    try testing.expectEqual(run.glyphs[2].pen_x, run.caretX(4));

    // The box grew to hold the taller face rather than clipping it.
    try testing.expect(run.ascent >= font.ascent / font.scale);
    try testing.expect(run.height() >= font.height());
}

test "a character no font has is counted, not hidden" {
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 256, 256);
    defer atlas.deinit();

    // A private-use codepoint: nothing on any system has a glyph for it.
    _ = try font.shape(&atlas, "a\u{F0000}b");
    try testing.expect(font.missing >= 1);
}

test "an English word in a Hebrew line is not reversed" {
    // The bug this fixes, end to end: HarfBuzz handed the whole line as one
    // right-to-left buffer shapes `abc` as `cba`. Split into direction runs,
    // it does not. Checked on the glyphs, because that is where it was wrong.
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 512, 512);
    defer atlas.deinit();

    const s = "אבג abc דהו";
    const run = try font.shape(&atlas, s);
    // Eleven characters, eleven glyphs: no duplication, which is what the
    // right-to-left cluster range used to produce.
    try testing.expectEqual(@as(usize, 11), run.glyphs.len);

    // `a`, `b`, `c` are at bytes 7, 8, 9 and must appear in that order from
    // left to right.
    var xa: f32 = -1;
    var xb: f32 = -1;
    var xc: f32 = -1;
    for (run.glyphs) |g| switch (g.cluster) {
        7 => xa = g.pen_x,
        8 => xb = g.pen_x,
        9 => xc = g.pen_x,
        else => {},
    };
    try testing.expect(xa >= 0 and xb >= 0 and xc >= 0);
    try testing.expect(xa < xb);
    try testing.expect(xb < xc);

    // And the Hebrew still runs the other way: the first logical word is on
    // the right of the line, the last on the left.
    var first_hebrew: f32 = -1;
    var last_hebrew: f32 = -1;
    for (run.glyphs) |g| {
        if (g.cluster == 0) first_hebrew = g.pen_x;
        if (g.cluster == 15) last_hebrew = g.pen_x;
    }
    try testing.expect(last_hebrew < first_hebrew);
}

test "a right-to-left run inside English keeps its own order" {
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 512, 512);
    defer atlas.deinit();

    const s = "abc אבג def";
    const run = try font.shape(&atlas, s);
    try testing.expectEqual(@as(usize, 11), run.glyphs.len);

    // Latin before and after, in order; Hebrew between them, reversed.
    var x0: f32 = -1;
    var x4: f32 = -1;
    var x8: f32 = -1;
    var x10: f32 = -1;
    for (run.glyphs) |g| switch (g.cluster) {
        0 => x0 = g.pen_x,
        4 => x4 = g.pen_x,
        8 => x8 = g.pen_x,
        10 => x10 = g.pen_x,
        else => {},
    };
    try testing.expect(x0 < x8);
    try testing.expect(x8 < x4);
    try testing.expect(x4 < x10);
}

test "Latin and Vietnamese take the path that never runs the algorithm" {
    // The fast path has to produce the same answer, not merely be faster.
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 512, 512);
    defer atlas.deinit();

    const s = "tiếng Việt";
    try testing.expect(!ui.bidi.hasRtl(s));
    const run = try font.shape(&atlas, s);
    var prev: f32 = -1;
    for (run.glyphs) |g| {
        try testing.expect(g.pen_x >= prev);
        prev = g.pen_x;
    }
    // Clusters ascend too, which is what "one left-to-right run" means.
    var last: u32 = 0;
    for (run.glyphs) |g| {
        try testing.expect(g.cluster >= last);
        last = g.cluster;
    }
}

test "the caret goes on the other side of right-to-left text" {
    // Rendering mixed text correctly made the caret over it visibly wrong:
    // before the first character of a right-to-left word is to its RIGHT,
    // and the old arithmetic walked the glyphs assuming clusters ascend.
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 512, 512);
    defer atlas.deinit();

    // "abc " then three Hebrew letters at bytes 4, 6, 8, then " def".
    const s = "abc אבג def";
    const run = try font.shape(&atlas, s);
    try testing.expectEqual(@as(usize, 3), run.spans.len);
    try testing.expect(!run.spans[0].rtl);
    try testing.expect(run.spans[1].rtl);
    try testing.expect(!run.spans[2].rtl);

    // The Latin before it still reads left to right.
    try testing.expect(run.caretX(0) < run.caretX(1));
    try testing.expect(run.caretX(1) < run.caretX(4));

    // Inside the Hebrew the caret moves LEFT as the offset grows, which is
    // the whole point: byte 4 is the first Hebrew letter and sits rightmost.
    try testing.expect(run.caretX(4) > run.caretX(6));
    try testing.expect(run.caretX(6) > run.caretX(8));

    // The caret before byte 4 is the right edge of the Hebrew stretch, and
    // the caret at its end is the left edge -- so the whole stretch lies
    // between the Latin on either side.
    try testing.expect(run.caretX(3) <= run.caretX(10));
    try testing.expect(run.caretX(10) < run.caretX(11));
}

test "a click in right-to-left text rounds to the right byte" {
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 512, 512);
    defer atlas.deinit();

    const s = "abc אבג def";
    const run = try font.shape(&atlas, s);

    // Click on the middle of each Hebrew glyph: the character under the
    // pointer is the one drawn there, whichever way the text runs. The x
    // comes from the glyph and not from two carets, because at the edge of a
    // direction run two carets are two different places.
    for ([_]usize{ 4, 6, 8 }) |b| {
        var mid: f32 = -1;
        for (run.glyphs, 0..) |g, i| {
            if (g.cluster != b) continue;
            const right = if (i + 1 < run.glyphs.len) run.glyphs[i + 1].pen_x else run.width;
            mid = (g.pen_x + right) * 0.5;
        }
        try testing.expect(mid >= 0);
        try testing.expectEqual(b, run.clusterAt(mid, s.len));
    }

    // And they really are drawn in the opposite order from the bytes.
    var x4: f32 = 0;
    var x8: f32 = 0;
    for (run.glyphs) |g| {
        if (g.cluster == 4) x4 = g.pen_x;
        if (g.cluster == 8) x8 = g.pen_x;
    }
    try testing.expect(x8 < x4);

    // And a click rounds to a caret position that is a real character
    // boundary, never into the middle of a letter.
    var x: f32 = 0;
    while (x < run.width) : (x += 1) {
        const at = run.byteAt(x, s.len);
        try testing.expect(at <= s.len);
        try testing.expect(at == s.len or (s[at] & 0xC0) != 0x80);
    }
}

test "a caret round-trips through its own x in mixed text" {
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 512, 512);
    defer atlas.deinit();

    const s = "abc אבג def";
    const run = try font.shape(&atlas, s);
    // Every character boundary that is not a direction boundary -- those are
    // two places on the screen for one offset, and the round trip can land on
    // either.
    for ([_]usize{ 0, 1, 2, 6, 8, 11, 12 }) |b| {
        const x = run.caretX(b);
        try testing.expectEqual(b, run.byteAt(x, s.len));
    }
}

test "text all one direction carries no table at all" {
    var lib = try Library.init();
    defer lib.deinit();
    var font = try openSans(&lib, testing.allocator);
    defer font.deinit();
    var atlas = try Atlas.init(testing.allocator, 512, 512);
    defer atlas.deinit();

    // The common case pays nothing: an empty table means one left-to-right
    // stretch, and every caret function reads it that way.
    const run = try font.shape(&atlas, "tiếng Việt");
    try testing.expectEqual(@as(usize, 0), run.spans.len);
    try testing.expect(run.caretX(0) < run.caretX(6));

    // A line that is nothing but Hebrew does carry one, because it is not
    // left to right.
    const heb = try font.shape(&atlas, "אבג");
    try testing.expectEqual(@as(usize, 1), heb.spans.len);
    try testing.expect(heb.spans[0].rtl);
    try testing.expect(heb.caretX(0) > heb.caretX(6));
}
