//! zig-uikit — a declarative GPU UI toolkit for Zig.
//!
//! Pre-alpha. What exists today is the layout core -- a retained element tree
//! with element-level dirty tracking and a flexbox engine over it -- and the
//! scene layer above it, which turns laid-out elements into a flat list of
//! GPU-ready primitives. There is no GPU renderer, no text and no platform
//! layer in this module yet; the software rasteriser in `raster.zig` exists to
//! verify the scene, not to draw a window. The input-method and accessibility
//! work lives in `spikes/` and has not been folded in.
//!
//! The design is documented in two notes, both written from measurements rather
//! than from preference:
//!
//!   - `docs/native-vs-drawn.md`        — one widget set, three tiers of "native"
//!   - `docs/text-and-accessibility.md` — eight requirements the spikes produced

pub const geometry = @import("geometry.zig");
pub const style = @import("style.zig");
pub const tree = @import("tree.zig");
pub const paint = @import("paint.zig");
pub const scene = @import("scene.zig");
pub const raster = @import("raster.zig");

pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Rect = geometry.Rect;
pub const Axis = geometry.Axis;

pub const Style = style.Style;
pub const Sizing = style.Sizing;
pub const Justify = style.Justify;
pub const AlignItems = style.AlignItems;

pub const Color = paint.Color;
pub const Paint = paint.Paint;
pub const Layer = paint.Layer;
pub const layers = paint.layers;

pub const Scene = scene.Scene;
pub const Quad = scene.Quad;
pub const SceneStats = scene.Stats;

pub const Framebuffer = raster.Framebuffer;

pub const Tree = tree.Tree;
pub const Element = tree.Element;
pub const Index = tree.Index;
pub const Stats = tree.Stats;
pub const Error = tree.Error;

test {
    // `std.testing.refAllDeclsRecursive` was removed in Zig 0.17, so the test
    // files are imported explicitly.
    _ = geometry;
    _ = style;
    _ = tree;
    _ = paint;
    _ = scene;
    _ = raster;
    _ = @import("layout_test.zig");
    _ = @import("scene_test.zig");
}
