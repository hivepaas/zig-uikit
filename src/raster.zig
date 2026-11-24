//! A software rasteriser for the scene, and the reference implementation of
//! what a quad looks like.
//!
//! This is not the renderer. It exists for two reasons, both of which are about
//! being able to check the work:
//!
//!   1. Paint is the one part of a UI toolkit that cannot be tested by
//!      asserting on numbers alone. A scene can hold the right primitives in
//!      the right order and still be wrong, and the only way to find out is to
//!      look at pixels. With this, `src/scene_test.zig` probes pixels in a
//!      process with no GPU, no window and no compositor, and `tools/demo.zig`
//!      produces an image a person can open.
//!
//!   2. `coverage` below is the whole definition of a quad's shape. The GPU
//!      shader will evaluate the same signed distance field per fragment. Two
//!      implementations of one formula is a real risk, so the formula lives
//!      here as a pure function and the shader will be written from it -- which
//!      also means a disagreement between the two shows up as a pixel
//!      difference against this, rather than as "the GPU looks slightly off".
//!
//! Blending is done in non-linear sRGB with eight-bit channels. That is
//! technically wrong and is what every shipping UI toolkit does; gamma-correct
//! compositing is a decision for the renderer, where there is a framebuffer
//! format to decide it against, and matching the common behaviour is more
//! useful here than being correct alone.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geometry = @import("geometry.zig");
const paint_mod = @import("paint.zig");
const scene_mod = @import("scene.zig");

pub const Rect = geometry.Rect;
pub const Color = paint_mod.Color;
pub const Quad = scene_mod.Quad;
pub const Scene = scene_mod.Scene;

/// Signed distance from a point to a rounded rectangle: negative inside,
/// positive outside, in pixels. Inigo Quilez's formulation.
///
/// The radius is clamped to half the shorter side, so an over-large radius
/// yields a capsule or a circle rather than a self-intersecting mess.
pub fn roundedBoxSdf(px: f32, py: f32, r: Rect, radius: f32) f32 {
    const hw = r.w * 0.5;
    const hh = r.h * 0.5;
    const rad = @min(radius, @min(hw, hh));
    const dx = @abs(px - (r.x + hw)) - (hw - rad);
    const dy = @abs(py - (r.y + hh)) - (hh - rad);
    const ax = @max(dx, 0);
    const ay = @max(dy, 0);
    return @sqrt(ax * ax + ay * ay) + @min(@max(dx, dy), 0) - rad;
}

/// Antialiased coverage of a shape at a signed distance, over one pixel.
///
/// A linear ramp across one pixel either side of the edge. This is the cheap
/// approximation a fragment shader uses, and it is exact for an edge running
/// through a pixel at 0 or 90 degrees.
pub fn coverage(sd: f32) f32 {
    return std.math.clamp(0.5 - sd, 0, 1);
}

/// Exact coverage of an axis-aligned rectangle over the pixel centred at
/// `(px, py)`. Used for the clip rectangle, where the geometry is always
/// axis-aligned, so there is no reason to approximate it.
pub fn boxCoverage(px: f32, py: f32, r: Rect) f32 {
    const ox = @min(px + 0.5, r.x + r.w) - @max(px - 0.5, r.x);
    const oy = @min(py + 0.5, r.y + r.h) - @max(py - 0.5, r.y);
    return std.math.clamp(ox, 0, 1) * std.math.clamp(oy, 0, 1);
}

pub const Framebuffer = struct {
    gpa: Allocator,
    w: u32,
    h: u32,
    /// Eight bits per channel, RGBA, row-major, no padding.
    px: []u8,

    pub fn init(gpa: Allocator, w: u32, h: u32) Allocator.Error!Framebuffer {
        const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
        var fb: Framebuffer = .{ .gpa = gpa, .w = w, .h = h, .px = px };
        fb.clear(Color.white);
        return fb;
    }

    pub fn deinit(self: *Framebuffer) void {
        self.gpa.free(self.px);
        self.* = undefined;
    }

    pub fn clear(self: *Framebuffer, c: Color) void {
        var i: usize = 0;
        while (i < self.px.len) : (i += 4) {
            self.px[i + 0] = c.r;
            self.px[i + 1] = c.g;
            self.px[i + 2] = c.b;
            self.px[i + 3] = c.a;
        }
    }

    pub fn at(self: *const Framebuffer, x: u32, y: u32) Color {
        const i = (@as(usize, y) * self.w + x) * 4;
        return .{
            .r = self.px[i],
            .g = self.px[i + 1],
            .b = self.px[i + 2],
            .a = self.px[i + 3],
        };
    }

    fn blend(self: *Framebuffer, x: u32, y: u32, c: Color, alpha: f32) void {
        if (alpha <= 0) return;
        const a = alpha * (@as(f32, @floatFromInt(c.a)) / 255.0);
        if (a <= 0) return;
        const i = (@as(usize, y) * self.w + x) * 4;
        inline for (0..3) |ch| {
            const src: f32 = @floatFromInt(switch (ch) {
                0 => c.r,
                1 => c.g,
                else => c.b,
            });
            const dst: f32 = @floatFromInt(self.px[i + ch]);
            const out = src * a + dst * (1 - a);
            self.px[i + ch] = @intFromFloat(std.math.clamp(@round(out), 0, 255));
        }
        // The framebuffer is treated as opaque: a UI window's backdrop is
        // decided by the platform layer, not by whatever was last drawn.
        const da: f32 = @floatFromInt(self.px[i + 3]);
        self.px[i + 3] = @intFromFloat(std.math.clamp(@round(a * 255.0 + da * (1 - a)), 0, 255));
    }

    /// Encodes the framebuffer as a binary P6 PPM.
    ///
    /// PPM rather than PNG because PNG needs a deflate implementation, and this
    /// module exists so that the scene can be checked without pulling anything
    /// in. Converting is one command for anyone who wants a PNG.
    pub fn encodePpm(self: *const Framebuffer, gpa: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var header_buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ self.w, self.h }) catch unreachable;
        try out.appendSlice(gpa, header);
        try out.ensureUnusedCapacity(gpa, @as(usize, self.w) * self.h * 3);
        var i: usize = 0;
        while (i < self.px.len) : (i += 4) {
            out.appendSliceAssumeCapacity(self.px[i .. i + 3]);
        }
        return out.toOwnedSlice(gpa);
    }

    /// Encodes the framebuffer as a PNG.
    ///
    /// Written out by hand because the alternative is a C dependency in a
    /// module whose entire job is to need nothing, and because the parts are
    /// all in the standard library: `std.compress.flate` for the pixel data and
    /// `std.hash.Crc32` for the chunk checksums. About forty lines buys a file
    /// that every viewer, browser and code host opens -- which matters, since
    /// the point of this module is that someone can look at the output.
    pub fn encodePng(self: *const Framebuffer, gpa: Allocator) ![]u8 {
        const stride = @as(usize, self.w) * 3;
        // PNG prefixes every scanline with a filter byte. Filter 0 is "none",
        // which costs some compression ratio and no complexity at all.
        const raw = try gpa.alloc(u8, (stride + 1) * self.h);
        defer gpa.free(raw);
        for (0..self.h) |y| {
            const dst = raw[y * (stride + 1) ..];
            dst[0] = 0;
            for (0..self.w) |x| {
                const src = (@as(usize, y) * self.w + x) * 4;
                @memcpy(dst[1 + x * 3 ..][0..3], self.px[src..][0..3]);
            }
        }

        var deflated: std.Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
        defer deflated.deinit();
        const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
        defer gpa.free(window);
        var comp = try std.compress.flate.Compress.init(&deflated.writer, window, .zlib, .level_6);
        try comp.writer.writeAll(raw);
        try comp.finish();

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });

        var ihdr: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr[0..4], self.w, .big);
        std.mem.writeInt(u32, ihdr[4..8], self.h, .big);
        ihdr[8] = 8; // bits per channel
        ihdr[9] = 2; // truecolour RGB
        ihdr[10] = 0; // deflate
        ihdr[11] = 0; // adaptive filtering
        ihdr[12] = 0; // no interlace
        try appendChunk(&out, gpa, "IHDR", &ihdr);
        try appendChunk(&out, gpa, "IDAT", deflated.written());
        try appendChunk(&out, gpa, "IEND", &.{});
        return out.toOwnedSlice(gpa);
    }

    fn appendChunk(out: *std.ArrayList(u8), gpa: Allocator, kind: *const [4]u8, data: []const u8) Allocator.Error!void {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(data.len), .big);
        try out.appendSlice(gpa, &len);
        const start = out.items.len;
        try out.appendSlice(gpa, kind);
        try out.appendSlice(gpa, data);
        var crc: [4]u8 = undefined;
        std.mem.writeInt(u32, &crc, std.hash.Crc32.hash(out.items[start..]), .big);
        try out.appendSlice(gpa, &crc);
    }

    /// Writes the PNG to a file. See `writePpm` on why `io` is a parameter.
    pub fn writePng(self: *const Framebuffer, io: std.Io, path: []const u8) !void {
        const bytes = try self.encodePng(self.gpa);
        defer self.gpa.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    }

    /// Writes the PPM to a file.
    ///
    /// The `Io` is a parameter rather than something taken from the
    /// environment because Zig 0.17 moved file access behind it, and a library
    /// that reaches for a global one takes that choice away from its caller.
    /// It is also the only function in this library that touches a file at all.
    pub fn writePpm(self: *const Framebuffer, io: std.Io, path: []const u8) !void {
        const bytes = try self.encodePpm(self.gpa);
        defer self.gpa.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    }
};

/// Draws one quad. The bounding box is the quad expanded by one pixel for the
/// antialiased edge, intersected with the clip and with the framebuffer, so the
/// cost of a clipped-away quad is the intersection and nothing else.
pub fn drawQuad(fb: *Framebuffer, q: Quad) void {
    const bounds = q.rect();
    const clip = q.clipRect();
    if (clip.w <= 0 or clip.h <= 0) return;

    const x0 = @max(@floor(@max(bounds.x, clip.x)) - 1, 0);
    const y0 = @max(@floor(@max(bounds.y, clip.y)) - 1, 0);
    const x1 = @min(@ceil(@min(bounds.x + bounds.w, clip.x + clip.w)) + 1, @as(f32, @floatFromInt(fb.w)));
    const y1 = @min(@ceil(@min(bounds.y + bounds.h, clip.y + clip.h)) + 1, @as(f32, @floatFromInt(fb.h)));
    if (x1 <= x0 or y1 <= y0) return;

    const bg = unpack(q.background);
    const bc = unpack(q.border_color);
    const bw = q.border_width;

    var y: u32 = @intFromFloat(y0);
    const y_end: u32 = @intFromFloat(y1);
    const x_start: u32 = @intFromFloat(x0);
    const x_end: u32 = @intFromFloat(x1);
    while (y < y_end) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        var x: u32 = x_start;
        while (x < x_end) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const in_clip = boxCoverage(px, py, clip);
            if (in_clip <= 0) continue;

            const sd = roundedBoxSdf(px, py, bounds, q.corner_radius);
            const outer = coverage(sd);
            if (outer <= 0) continue;
            // The fill is the shape inset by the border width. Subtracting the
            // two coverages rather than evaluating a second distance field is
            // what makes a border an exact complement of the fill: no seam, and
            // no double-blended pixel where they meet.
            const inner = if (bw > 0) coverage(sd + bw) else outer;

            if (inner > 0) fb.blend(x, y, bg, inner * in_clip);
            if (bw > 0 and outer > inner) fb.blend(x, y, bc, (outer - inner) * in_clip);
        }
    }
}

pub fn drawScene(fb: *Framebuffer, s: *const Scene) void {
    for (s.items()) |q| drawQuad(fb, q);
}

fn unpack(v: u32) Color {
    return .{
        .r = @truncate(v),
        .g = @truncate(v >> 8),
        .b = @truncate(v >> 16),
        .a = @truncate(v >> 24),
    };
}

test "the distance field agrees with the shape it describes" {
    const r: Rect = .{ .x = 10, .y = 10, .w = 100, .h = 50 };
    // Centre: negative, and the distance to the nearest edge is the half-height.
    try std.testing.expectApproxEqAbs(@as(f32, -25), roundedBoxSdf(60, 35, r, 0), 0.001);
    // Just outside the right edge.
    try std.testing.expectApproxEqAbs(@as(f32, 5), roundedBoxSdf(115, 35, r, 0), 0.001);
    // A corner with a radius is further away than one without.
    try std.testing.expect(roundedBoxSdf(10.5, 10.5, r, 12) > roundedBoxSdf(10.5, 10.5, r, 0));
}

test "box coverage is exact for partial pixels" {
    const r: Rect = .{ .x = 10, .y = 0, .w = 80, .h = 100 };
    // Pixel 9 spans 9..10 and the rect starts at 10: no overlap.
    try std.testing.expectApproxEqAbs(@as(f32, 0), boxCoverage(9.5, 50, r), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), boxCoverage(10.5, 50, r), 0.001);
    // Half-pixel edge.
    const half: Rect = .{ .x = 10.5, .y = 0, .w = 80, .h = 100 };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), boxCoverage(10.5, 50, half), 0.001);
}
