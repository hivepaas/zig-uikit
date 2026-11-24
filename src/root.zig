//! zig-uikit — a declarative GPU UI toolkit for Zig.
//!
//! Pre-alpha. What exists in THIS module is the layout core -- a retained
//! element tree with element-level dirty tracking and a flexbox engine over it
//! -- and the scene layer above it, which turns laid-out elements into a flat
//! list of GPU-ready primitives. The software rasteriser in `raster.zig`
//! exists to verify the scene, not to draw a window.
//!
//! This module links nothing and its tests run on a machine with no fonts, no
//! GPU and no compositor. The Vulkan renderer, the Wayland window and the text
//! stack are separate modules for that reason; `glyph.zig` holds the plain
//! numbers that let the core lay out and paint text it cannot itself produce.
//! The input-method and accessibility work lives in `spikes/` and has not been
//! folded in.
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
pub const glyph = @import("glyph.zig");
pub const offsets = @import("offsets.zig");
pub const document = @import("document.zig");
pub const keys = @import("keys.zig");
pub const editing = @import("editing.zig");
pub const input_client = @import("input_client.zig");
pub const input_method = @import("input_method.zig");
pub const access = @import("access.zig");
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

pub const Document = document.Document;
pub const Range = document.Range;

pub const Key = keys.Key;
pub const Mods = keys.Mods;
pub const KeyEvent = keys.KeyEvent;
pub const KeyQueue = keys.Queue;

pub const Glyph = glyph.Glyph;
pub const TextRun = glyph.TextRun;
pub const AtlasView = glyph.AtlasView;

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
    _ = glyph;
    _ = offsets;
    _ = document;
    _ = keys;
    _ = editing;
    _ = input_client;
    _ = input_method;
    _ = access;
    _ = scene;
    _ = raster;
    _ = @import("layout_test.zig");
    _ = @import("scene_test.zig");
}
