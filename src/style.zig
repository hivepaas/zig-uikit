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
        if (@backingInt(a) != @backingInt(b)) return false;
        return switch (a) {
            .fixed => |v| v == b.fixed,
            .content => true,
            .grow => |v| v == b.grow,
        };
    }
};

/// Whether an element takes part in its parent's flow.
///
/// `absolute` exists because the alternative was being written over and over
/// in the demo: a caret, a selection highlight and a popover were each three
/// or four layout elements -- a zero-width anchor, a spacer whose width was
/// the x coordinate, and a column whose first child's height was the y -- with
/// a comment at every site saying what feature was missing. Five such sites,
/// and 201 layout elements for 71 things a person would name.
///
/// It also changes what a caret costs. An out-of-flow element cannot change
/// its siblings' sizes or its parent's content size, so moving one is a
/// recompute of that element and nothing else; moving a spacer was a size
/// change that climbed the tree.
pub const Position = enum(u8) {
    /// Laid out among its siblings. The default.
    flow,
    /// Taken out of flow and placed at `left`/`top` from the parent's content
    /// origin. It does not affect its siblings, and they do not affect it.
    ///
    /// Deliberately **relative to the parent**, not to a "nearest positioned
    /// ancestor" as in CSS. That rule exists for documents, where the thing
    /// you want to position against is often far up the tree; here the parent
    /// is the thing an overlay belongs to, and the walk it would need is a
    /// cost on every placement for a case nothing has yet asked for.
    absolute,
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

    position: Position = .flow,
    /// Only with `position: .absolute`: the offset from the parent's content
    /// origin. Ignored in flow, where the parent decides.
    left: f32 = 0,
    top: f32 = 0,

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
            a.justify == b.justify and a.align_items == b.align_items and
            a.position == b.position and a.left == b.left and a.top == b.top;
    }
};
