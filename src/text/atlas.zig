//! A glyph atlas: one 8-bit coverage channel, packed in shelves.
//!
//! Deliberately knows nothing about fonts. The packer is the one part of the
//! text stack that is pure arithmetic, so it is the one part that can be tested
//! without a font installed, and it is separated for that reason.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ui = @import("zig-uikit");

pub const Error = error{
    OutOfMemory,
    /// The atlas has no room left.
    ///
    /// Not recoverable from inside here, and that is a design statement rather
    /// than a shortcut. Growing the atlas moves every glyph already in it, so
    /// every texel coordinate cached on every element in the tree becomes
    /// wrong -- which means growth needs a re-shape pass over the whole tree,
    /// driven by whatever owns both. Eviction has the same problem plus a
    /// policy question. Both belong to the layer that owns the tree, and
    /// failing loudly here is what keeps that decision from being made by
    /// accident.
    AtlasFull,
};

/// A rectangle in atlas texels. `u16` because an atlas larger than 65535 on a
/// side exceeds `maxImageDimension2D` on every GPU this will run on.
pub const Slot = struct {
    u0: u16,
    v0: u16,
    u1: u16,
    v1: u16,

    pub fn width(self: Slot) u16 {
        return self.u1 - self.u0;
    }

    pub fn height(self: Slot) u16 {
        return self.v1 - self.v0;
    }
};

pub const Atlas = struct {
    gpa: Allocator,
    pixels: []u8,
    w: u16,
    h: u16,

    /// Shelf packing: fill a row left to right, and when a glyph does not fit,
    /// start a new row below the tallest glyph in the old one.
    ///
    /// Chosen over skyline packing because glyphs from one font at one size are
    /// all within a few pixels of the same height, which is the case shelves
    /// are efficient for -- the wasted strip above each glyph is the difference
    /// between it and the tallest glyph on its shelf, a pixel or two, not the
    /// arbitrary gaps a general rectangle packer has to cope with. A skyline
    /// packer is four times the code to recover a few percent.
    shelf_x: u16 = 0,
    shelf_y: u16 = 0,
    shelf_h: u16 = 0,

    /// Texels actually handed out, for reporting how full the atlas is.
    used: u32 = 0,

    /// Bumped whenever texels change.
    ///
    /// The GPU holds a copy of this image, and the only way to know whether it
    /// is stale is to be told. Comparing fill ratios would miss a glyph that
    /// happened to replace one of the same area; re-uploading every frame
    /// would cost a texture upload per frame for text that almost never
    /// changes. A counter answers the question exactly: typing a character the
    /// font has already rasterised changes nothing and uploads nothing.
    generation: u32 = 0,

    pub fn init(gpa: Allocator, w: u16, h: u16) Error!Atlas {
        const pixels = try gpa.alloc(u8, @as(usize, w) * h);
        // Zero is "no coverage", so an empty atlas is a transparent one and a
        // slot nothing was blitted into draws nothing rather than garbage.
        @memset(pixels, 0);
        return .{ .gpa = gpa, .pixels = pixels, .w = w, .h = h };
    }

    pub fn deinit(self: *Atlas) void {
        self.gpa.free(self.pixels);
        self.* = undefined;
    }

    pub fn view(self: *const Atlas) ui.AtlasView {
        return .{ .pixels = self.pixels, .w = self.w, .h = self.h };
    }

    /// Reserves space for a `w` by `h` bitmap.
    ///
    /// No gutter between slots, and that is not an oversight. A gutter exists
    /// to stop a filtered sampler reading a neighbour's texels; this atlas is
    /// read with `texelFetch` against the slot's own bounds, on the GPU and in
    /// the software reference alike, so no sample can reach outside a slot and
    /// there is nothing for a gutter to prevent. Exact texel addressing pays
    /// for itself twice: crisp text, and a denser atlas.
    pub fn reserve(self: *Atlas, w: u16, h: u16) Error!Slot {
        if (w == 0 or h == 0) {
            // A space has an advance and no ink. Giving it an empty slot at the
            // origin keeps it in the glyph list -- it is a real glyph with a
            // real cluster, and the text layer will need it when it maps a
            // caret position back to a byte offset.
            return .{ .u0 = 0, .v0 = 0, .u1 = 0, .v1 = 0 };
        }
        if (w > self.w) return Error.AtlasFull;

        if (@as(u32, self.shelf_x) + w > self.w) {
            self.shelf_y += self.shelf_h;
            self.shelf_x = 0;
            self.shelf_h = 0;
        }
        if (@as(u32, self.shelf_y) + h > self.h) return Error.AtlasFull;

        const slot: Slot = .{
            .u0 = self.shelf_x,
            .v0 = self.shelf_y,
            .u1 = self.shelf_x + w,
            .v1 = self.shelf_y + h,
        };
        self.shelf_x += w;
        self.shelf_h = @max(self.shelf_h, h);
        self.used += @as(u32, w) * h;
        return slot;
    }

    /// Copies an 8-bit bitmap into a reserved slot. `src_stride` is FreeType's
    /// `bitmap.pitch`, which is not always equal to the width.
    pub fn blit(self: *Atlas, slot: Slot, src: []const u8, src_stride: usize) void {
        const w = slot.width();
        const h = slot.height();
        self.generation += 1;
        for (0..h) |row| {
            const dst = (@as(usize, slot.v0) + row) * self.w + slot.u0;
            const from = row * src_stride;
            @memcpy(self.pixels[dst..][0..w], src[from..][0..w]);
        }
    }

    pub fn fillRatio(self: *const Atlas) f32 {
        const total: f32 = @floatFromInt(@as(u32, self.w) * self.h);
        return @as(f32, @floatFromInt(self.used)) / total;
    }
};

const testing = std.testing;

test "shelves advance across and then down" {
    var a = try Atlas.init(testing.allocator, 16, 16);
    defer a.deinit();

    const s1 = try a.reserve(10, 8);
    try testing.expectEqual(@as(u16, 0), s1.u0);
    try testing.expectEqual(@as(u16, 0), s1.v0);

    // Fits beside it.
    const s2 = try a.reserve(6, 4);
    try testing.expectEqual(@as(u16, 10), s2.u0);
    try testing.expectEqual(@as(u16, 0), s2.v0);

    // Does not: a new shelf below the TALLEST glyph on the old one, not below
    // the last one placed.
    const s3 = try a.reserve(4, 4);
    try testing.expectEqual(@as(u16, 0), s3.u0);
    try testing.expectEqual(@as(u16, 8), s3.v0);
}

test "running out is an error, not a wrap" {
    var a = try Atlas.init(testing.allocator, 8, 8);
    defer a.deinit();
    _ = try a.reserve(8, 8);
    try testing.expectError(Error.AtlasFull, a.reserve(1, 1));
    // Wider than the atlas can never fit on any shelf.
    try testing.expectError(Error.AtlasFull, a.reserve(9, 1));
}

test "an empty glyph takes no space and still gets a slot" {
    var a = try Atlas.init(testing.allocator, 8, 8);
    defer a.deinit();
    const s = try a.reserve(0, 0);
    try testing.expectEqual(@as(u16, 0), s.width());
    try testing.expectEqual(@as(u32, 0), a.used);
}

test "blit respects a pitch wider than the glyph" {
    var a = try Atlas.init(testing.allocator, 8, 8);
    defer a.deinit();
    const s = try a.reserve(2, 2);
    // 2x2 glyph stored with a pitch of 4.
    const src = [_]u8{ 1, 2, 99, 99, 3, 4, 99, 99 };
    a.blit(s, &src, 4);
    try testing.expectEqual(@as(u8, 1), a.view().at(0, 0));
    try testing.expectEqual(@as(u8, 2), a.view().at(1, 0));
    try testing.expectEqual(@as(u8, 3), a.view().at(0, 1));
    try testing.expectEqual(@as(u8, 4), a.view().at(1, 1));
    // The pitch padding did not come along.
    try testing.expectEqual(@as(u8, 0), a.view().at(2, 0));
}

test "a view reports zero outside itself" {
    var a = try Atlas.init(testing.allocator, 4, 4);
    defer a.deinit();
    const v = a.view();
    try testing.expectEqual(@as(u8, 0), v.at(-1, 0));
    try testing.expectEqual(@as(u8, 0), v.at(0, -1));
    try testing.expectEqual(@as(u8, 0), v.at(4, 0));
    try testing.expectEqual(@as(u8, 0), v.at(0, 4));
}
