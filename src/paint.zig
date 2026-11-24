//! What an element looks like, kept in a struct of its own and NOT in `Style`.
//!
//! The separation is the point, not tidiness. `Style.eql` is what decides
//! whether an element is dirty for layout, so a background colour living in
//! `Style` would mean that recolouring a button runs the flexbox engine over
//! its container. The measured claim this project rests on is that a frame
//! which changes nothing costs ~15 ns and no allocations; a frame that changes
//! only appearance must stay on that side of the line, and the only way to
//! guarantee it is for the two property sets to be separate values reached by
//! separate setters. `Tree.setPaint` never touches the dirty list, and
//! `layout_test.zig` asserts that a recolour returns an all-zero `Stats`.

const std = @import("std");

/// Non-premultiplied sRGB, eight bits per channel.
///
/// Eight bits because that is what a caller writes by hand and what a designer
/// hands over, and the conversion to whatever the GPU wants belongs in the
/// renderer rather than in every call site. Non-premultiplied for the same
/// reason: `rgba(255, 0, 0, 128)` is a half-transparent red to everyone except
/// a compositing engine.
pub const Color = extern struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255 };

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// `0xRRGGBB` or `0xRRGGBBAA`, distinguished by magnitude: a value that
    /// fits in 24 bits is opaque. `0x000000FF` is therefore ambiguous and
    /// resolves to transparent black; write it as `rgba` if that matters.
    pub fn hex(v: u32) Color {
        if (v <= 0xFFFFFF) return .{
            .r = @truncate(v >> 16),
            .g = @truncate(v >> 8),
            .b = @truncate(v),
        };
        return .{
            .r = @truncate(v >> 24),
            .g = @truncate(v >> 16),
            .b = @truncate(v >> 8),
            .a = @truncate(v),
        };
    }

    /// Little-endian `0xAABBGGRR`, which is what both the software reference
    /// rasteriser and a `R8G8B8A8_UNORM` vertex attribute read.
    pub fn pack(self: Color) u32 {
        return @as(u32, self.r) |
            (@as(u32, self.g) << 8) |
            (@as(u32, self.b) << 16) |
            (@as(u32, self.a) << 24);
    }

    pub fn eql(a: Color, b: Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }

    pub fn isInvisible(self: Color) bool {
        return self.a == 0;
    }
};

/// The painting layer an element and its subtree belong to.
///
/// Primitives are emitted in tree order and then bucketed by layer, so a higher
/// layer paints over everything below it regardless of where it sits in the
/// tree. This is what a menu, a tooltip or a drag ghost needs: tree position
/// decides layout and ownership, layer decides what covers what.
///
/// A `u8` rather than a signed or wider integer because bucketing 256 values is
/// a counting pass with no comparison sort, and because the set of things that
/// genuinely need to escape tree order is small and nameable.
pub const Layer = u8;

/// Named layers. Nothing enforces these; they exist so that two parts of an
/// application do not have to agree on a magic number.
pub const layers = struct {
    pub const content: Layer = 0;
    pub const popover: Layer = 64;
    pub const tooltip: Layer = 128;
    pub const drag: Layer = 192;
    pub const debug: Layer = 255;
};

pub const Paint = struct {
    /// Filled inside the rounded rectangle. Alpha 0 means no fill is emitted.
    background: Color = Color.transparent,

    /// Stroked inward from the element's edge, so a bordered element never
    /// grows: a border is paint, and paint does not move anything. CSS would
    /// call this `box-sizing: border-box` for the border alone.
    border_color: Color = Color.transparent,
    border_width: f32 = 0,

    /// The colour the element's text is drawn in.
    ///
    /// In `Paint` and not in the text run, for the reason this whole struct
    /// exists: a theme switch recolours every label in the window, and if the
    /// colour lived in the run then recolouring would mean re-shaping. Here it
    /// bumps the revision, rebuilds the scene, and runs no layout and no
    /// HarfBuzz at all.
    text_color: Color = Color.black,

    /// One radius for all four corners. Per-corner radii are a mechanical
    /// extension of the same distance field and are left out rather than
    /// half-done.
    corner_radius: f32 = 0,

    /// Whether this element's bounds clip its descendants.
    ///
    /// The clip is the padding box: the bounds inset by `border_width`, as in
    /// CSS. Clipping at the outer edge instead would let an overflowing child
    /// paint over the border meant to contain it.
    ///
    /// Clipping is resolved during scene building into an absolute rectangle
    /// carried by every primitive, rather than into push/pop commands. Three
    /// reasons: the GPU wants one draw call with the test in the shader instead
    /// of scissor state changes; a resolved rectangle survives the layer
    /// bucketing that push/pop pairs would not; and it is what makes a subtree
    /// outside its clip skippable in one test.
    clip_children: bool = false,

    /// Non-zero moves this element and its subtree to another painting layer.
    ///
    /// It also resets the clip to the viewport, deliberately. A popover is a
    /// child of the control that owns it, and that control is frequently inside
    /// a scroll box; inheriting the scroll box's clip would clip the popover to
    /// the thing it is supposed to escape, which is the bug layers exist to
    /// prevent.
    layer: Layer = 0,

    /// True when nothing that affects the scene differs.
    pub fn eql(a: Paint, b: Paint) bool {
        return Color.eql(a.background, b.background) and
            Color.eql(a.border_color, b.border_color) and
            Color.eql(a.text_color, b.text_color) and
            a.border_width == b.border_width and
            a.corner_radius == b.corner_radius and
            a.clip_children == b.clip_children and
            a.layer == b.layer;
    }

    /// Whether this element contributes a *box* primitive of its own. An
    /// element with no fill and no border still clips, still carries a layer,
    /// and may still have text, so being invisible is not the same as being
    /// absent -- and text is deliberately not consulted here, because this
    /// question is about the box.
    pub fn isVisible(self: Paint) bool {
        if (!self.background.isInvisible()) return true;
        return self.border_width > 0 and !self.border_color.isInvisible();
    }
};

test "hex distinguishes by magnitude" {
    try std.testing.expect(Color.eql(Color.hex(0x336699), Color.rgb(0x33, 0x66, 0x99)));
    try std.testing.expect(Color.eql(Color.hex(0x33669980), Color.rgba(0x33, 0x66, 0x99, 0x80)));
    // Documented ambiguity: 24 bits wins.
    try std.testing.expect(Color.hex(0x0000FF).a == 255);
}

test "pack is little-endian RGBA" {
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), Color.rgb(255, 0, 0).pack());
    try std.testing.expectEqual(@as(u32, 0x80112233), Color.rgba(0x33, 0x22, 0x11, 0x80).pack());
}

test "invisible paint still clips" {
    const p: Paint = .{ .clip_children = true };
    try std.testing.expect(!p.isVisible());
    try std.testing.expect(p.clip_children);
}

test "a border with no colour is not visible" {
    try std.testing.expect(!(Paint{ .border_width = 2 }).isVisible());
    try std.testing.expect((Paint{ .border_width = 2, .border_color = Color.black }).isVisible());
}
