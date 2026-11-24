//! What the caller sets. Computed layout state lives on the element and is not
//! part of this struct, so that "did the style change" is a comparison of
//! inputs only.

const std = @import("std");
const geometry = @import("geometry.zig");

pub const Axis = geometry.Axis;

/// How an element is sized along one axis.
///
/// `grow` carries its own flex factor rather than being a separate field,
/// because a factor is meaningless without the mode and the two drifting apart
/// is a class of bug the tagged union removes.
pub const Sizing = union(enum) {
    /// A definite length.
    fixed: f32,
    /// The content size: the sum of the children's hypothetical sizes along the
    /// container's main axis, or the maximum across it.
    content,
    /// Takes a share of the free space, weighted by this factor. CSS calls it
    /// `flex-grow: n` with `flex-basis: auto`.
    grow: f32,

    pub fn eql(a: Sizing, b: Sizing) bool {
        if (@intFromEnum(a) != @intFromEnum(b)) return false;
        return switch (a) {
            .fixed => |v| v == b.fixed,
            .content => true,
            .grow => |v| v == b.grow,
        };
    }
};

pub const Justify = enum(u8) {
    start,
    center,
    end,
    space_between,
};

pub const AlignItems = enum(u8) {
    start,
    center,
    end,
    stretch,
    baseline,
};

pub const Style = struct {
    /// The axis children are laid out along.
    axis: Axis = .col,

    width: Sizing = .content,
    height: Sizing = .content,

    min_width: f32 = 0,
    min_height: f32 = 0,
    max_width: f32 = std.math.floatMax(f32),
    max_height: f32 = std.math.floatMax(f32),

    /// How willingly this element gives up size when its line overflows.
    ///
    /// The default is 1, matching CSS `flex-shrink: 1`, and that default is the
    /// single most consequential value in this struct. It means **every** item
    /// shrinks, so an overflowing line couples the size of every sibling to
    /// every other, which is what defeats the incremental fast path. See
    /// `docs/text-and-accessibility.md` and run 9 of the benchmark.
    ///
    /// Setting it to 0 on a container whose children must not be squeezed is
    /// what re-enables the fast path, and is worth doing deliberately.
    flex_shrink: f32 = 1,

    /// Inset on all four sides. A single scalar for now; per-side padding is a
    /// mechanical extension and is not implemented rather than half-implemented.
    padding: f32 = 0,

    /// Space between adjacent children, and between wrapped lines.
    gap: f32 = 0,

    /// Whether children that do not fit move to another line.
    ///
    /// A wrapping container must have a definite size across its axis: a correct
    /// content-based cross size for a wrap container depends on the available
    /// main size and needs a second layout pass, which this engine does not run.
    /// `Tree.setStyle` rejects the combination rather than laying out wrongly.
    wrap: bool = false,

    justify: Justify = .start,
    align_items: AlignItems = .start,

    /// True when nothing that affects layout differs.
    pub fn eql(a: Style, b: Style) bool {
        return a.axis == b.axis and
            Sizing.eql(a.width, b.width) and
            Sizing.eql(a.height, b.height) and
            a.min_width == b.min_width and a.min_height == b.min_height and
            a.max_width == b.max_width and a.max_height == b.max_height and
            a.flex_shrink == b.flex_shrink and
            a.padding == b.padding and a.gap == b.gap and
            a.wrap == b.wrap and
            a.justify == b.justify and a.align_items == b.align_items;
    }
};
