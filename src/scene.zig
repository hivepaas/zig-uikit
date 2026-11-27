//! The scene: a flat list of GPU-ready primitives, rebuilt from the tree.
//!
//! Three decisions here were made from the benchmark rather than from taste,
//! and each one is the opposite of what the layout engine does.
//!
//! **The scene is rebuilt whole, not patched.** Run 6 of the benchmark measured
//! writing all 1649 quads of a GPUI-sized tree into Vulkan-mapped GPU memory at
//! 0.58-1.22 us, which suggested that patching primitives incrementally was not
//! worth it. `tools/scene_bench.zig` now measures the thing itself rather than
//! that proxy: a full rebuild of 1641 quads is **8.1 us**, seven times the cost
//! of merely writing them, and 0.35% of the 2.32 ms of CPU a view-level toolkit
//! spends on a frame where nothing changed. The conclusion survives the more
//! expensive number, which is why it is quoted here rather than the proxy. The
//! retained tree exists because reusing last frame's *layout* saves
//! milliseconds; reusing last frame's quads saves microseconds, and a second
//! dirty-tracking system is not worth microseconds.
//!
//! **An unchanged frame still costs nothing.** `Tree.revision` is bumped only
//! when a repaint or a layout that did work has actually happened, so `build`
//! returns after one integer comparison on a frame where nothing changed. That
//! is what keeps the ~15 ns claim true end to end rather than only inside the
//! layout engine.
//!
//! **Clipping is resolved per primitive, not pushed and popped.** Every quad
//! carries the absolute rectangle it is clipped to. A push/pop command stream
//! would be destroyed by the layer bucketing below, would cost scissor state
//! changes on the GPU, and would not let a subtree outside its clip be skipped
//! in a single test.
//!
//! **Text is the same primitive.** A glyph is a clipped rectangle whose
//! coverage comes from an atlas instead of from a distance field, so it goes in
//! the same list, in tree order, right after the box of the element it belongs
//! to. See `Quad` for why that is worth eight bytes on every box in the scene.
//!
//! What is deliberately absent: images, shadows and transforms. Each is a
//! primitive whose shape should be decided when there is something to measure.
//! Guessing at them now would mean a `Quad` with unused fields and a renderer
//! with unreachable branches.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geometry = @import("geometry.zig");
const paint_mod = @import("paint.zig");
const tree_mod = @import("tree.zig");

pub const Rect = geometry.Rect;
pub const Size = geometry.Size;
pub const Point = geometry.Point;
pub const Color = paint_mod.Color;
pub const Layer = paint_mod.Layer;
pub const Tree = tree_mod.Tree;
pub const Index = tree_mod.Index;
const none = tree_mod.none;

/// One clipped rectangle -- either a rounded bordered box or a glyph sampled
/// from the atlas -- in 60 bytes, and the only primitive there is.
///
/// `extern` and flat so the list can be uploaded as an instance buffer with no
/// repacking. The fields are in the order a shader reads them, and the clip
/// rectangle is part of the instance rather than pipeline state for the reason
/// given in the module comment.
///
/// **Why text is this primitive and not a second one.** A separate text
/// pipeline would need its own primitive list, and then the two lists would
/// have to be interleaved by draw call to keep a label painting over its own
/// background -- which is to say, the ordering that falls out of one sorted
/// list for free would have to be reconstructed, and a window of alternating
/// boxes and labels would become a draw call per element. One primitive, one
/// list, one pipeline, one draw call: paint order stays a property of the list.
///
/// The cost is twelve bytes on every box quad that has no text in it: 48 bytes
/// became 60, a quarter more upload volume for a scene with no text in it at
/// all, and `zig build bench` reports what that did to the rebuild. The struct
/// is deliberately NOT padded out to a 64-byte cache line. 60 is a legal vertex
/// stride, the four bytes would buy an aligned instance fetch, and no
/// measurement here says that is worth 6% more bandwidth -- so the spare field
/// stays unwritten until something asks for it.
pub const Quad = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    /// Packed `0xAABBGGRR`; see `Color.pack`.
    background: u32,
    border_color: u32,

    /// Stroked inward from the edge, so it never changes the element's size.
    border_width: f32,
    corner_radius: f32,

    /// Absolute clip rectangle. Not intersected with the quad's own bounds:
    /// doing that would cut a corner's antialiased edge with a second
    /// antialiased edge and darken it.
    cx: f32,
    cy: f32,
    cw: f32,
    ch: f32,

    /// Atlas texels, when `flags.textured` is set: the top-left texel and one
    /// past the bottom-right. Addressed as integers rather than normalised
    /// coordinates, and sampled with `texelFetch`, so that destination pixel
    /// and source texel correspond exactly with no filtering in between. That
    /// is what lets the GPU and the software reference produce the same bytes
    /// for text rather than nearly the same.
    u0: u16 = 0,
    v0: u16 = 0,
    u1: u16 = 0,
    v1: u16 = 0,

    flags: Flags = .{},

    pub const Flags = packed struct(u32) {
        /// Coverage comes from the atlas instead of from the distance field.
        /// A textured quad ignores `border_*` and `corner_radius`, and takes
        /// its colour from `background`.
        textured: bool = false,
        _rest: u31 = 0,

        pub fn bits(self: Flags) u32 {
            return @bitCast(self);
        }
    };

    pub fn rect(self: Quad) Rect {
        return .{ .x = self.x, .y = self.y, .w = self.w, .h = self.h };
    }

    pub fn clipRect(self: Quad) Rect {
        return .{ .x = self.cx, .y = self.cy, .w = self.cw, .h = self.ch };
    }

    /// The quad with every length multiplied by `s`: what a renderer draws for
    /// a display with `s` pixels per layout unit. Renderers do this on the GPU;
    /// this is for the software reference, so a Retina frame can be checked
    /// against the same scene the window laid out.
    ///
    /// **A glyph cannot be scaled**: its atlas rectangle is a fixed number of
    /// texels, and the whole basis of how a glyph is sampled is that one
    /// destination pixel reads one texel. Doubling the destination and not the
    /// source would leave half the glyph outside its own texel range and
    /// discarded. The answer on a scaled display is to shape at the device
    /// pixel size -- a 13-point label on a 2x display is a 26-pixel font, not a
    /// 13-pixel one drawn twice as large -- and a glyph shaped that way is
    /// already `w * s` texels wide and snapped to the device grid. So a
    /// textured quad is accepted exactly when scaling it lands it on whole
    /// pixels at its texel size, and anything else is the bug this describes.
    pub fn scaled(self: Quad, s: f32) Quad {
        if (self.flags.textured) {
            const tol = 1e-3;
            std.debug.assert(@abs(self.w * s - @as(f32, @floatFromInt(self.u1 - self.u0))) < tol);
            std.debug.assert(@abs(self.h * s - @as(f32, @floatFromInt(self.v1 - self.v0))) < tol);
            std.debug.assert(@abs(self.x * s - @round(self.x * s)) < tol);
            std.debug.assert(@abs(self.y * s - @round(self.y * s)) < tol);
        }
        var q = self;
        q.x *= s;
        q.y *= s;
        q.w *= s;
        q.h *= s;
        q.border_width *= s;
        q.corner_radius *= s;
        q.cx *= s;
        q.cy *= s;
        q.cw *= s;
        q.ch *= s;
        if (q.flags.textured) {
            // Exact again after the asserts above allowed for rounding error.
            q.x = @round(q.x);
            q.y = @round(q.y);
            q.w = @floatFromInt(q.u1 - q.u0);
            q.h = @floatFromInt(q.v1 - q.v0);
        }
        return q;
    }
};

comptime {
    // Not a requirement, an assertion that the layout has not drifted: the
    // renderer's vertex attribute offsets are derived from this.
    std.debug.assert(@sizeOf(Quad) == 60);
}

pub const Stats = struct {
    /// Elements examined.
    visited: u32 = 0,
    /// Quads written, boxes and glyphs together.
    emitted: u32 = 0,
    /// How many of `emitted` were glyphs.
    glyphs: u32 = 0,
    /// Elements with nothing inside their clip.
    culled: u32 = 0,
    /// Subtrees skipped without being visited at all, which is only possible
    /// under a clipping ancestor; see `skipped_subtrees` in the module comment
    /// for why an unclipped overflowing child cannot be skipped this way.
    skipped_subtrees: u32 = 0,
    /// Distinct painting layers that emitted anything. One means the bucketing
    /// pass was skipped entirely.
    layers_used: u32 = 0,
    /// False when the revision check short-circuited, which is the case this
    /// whole design is built around.
    rebuilt: bool = false,
};

fn insetBy(r: Rect, d: f32) Rect {
    if (d <= 0) return r;
    return .{
        .x = r.x + d,
        .y = r.y + d,
        .w = @max(0, r.w - d * 2),
        .h = @max(0, r.h - d * 2),
    };
}

const Frame = struct {
    /// The next sibling to visit in this frame, or `none` when the frame is
    /// spent. Iterating siblings forwards is why this is a cursor rather than a
    /// node: the tree has no `prev_sibling`, and paint order is first child
    /// first, which is the opposite of the order a plain node stack yields.
    next: Index,
    clip: Rect,
    layer: Layer,
};

pub const Scene = struct {
    gpa: Allocator,

    quads: std.ArrayList(Quad) = .empty,
    /// The element each quad came from, parallel to `quads`. Kept separate so
    /// that `quads` stays uploadable as-is, and because the GPU has no use for
    /// it. This is what a scene-driven hit test will read.
    owners: std.ArrayList(Index) = .empty,

    stack: std.ArrayList(Frame) = .empty,
    layer_of: std.ArrayList(Layer) = .empty,
    /// Destination for the bucketing pass, allocated on the first frame that
    /// actually uses more than one layer.
    sorted_quads: std.ArrayList(Quad) = .empty,
    sorted_owners: std.ArrayList(Index) = .empty,

    built_revision: u64 = 0,
    stats: Stats = .{},

    /// Device pixels per layout unit, which is the grid glyph quads are snapped
    /// to. Box quads do not care -- their edges are antialiased by the distance
    /// field at any position -- but a glyph's bitmap was rasterised for whole
    /// device pixels, so its quad has to land on them. Set it with
    /// `setPixelScale`, which also forces the next build, and give the scene
    /// text shaped for the same scale (`text.Library.openScaled`).
    pixel_scale: f32 = 1,

    pub fn init(gpa: Allocator) Scene {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Scene) void {
        self.quads.deinit(self.gpa);
        self.owners.deinit(self.gpa);
        self.stack.deinit(self.gpa);
        self.layer_of.deinit(self.gpa);
        self.sorted_quads.deinit(self.gpa);
        self.sorted_owners.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn setPixelScale(self: *Scene, s: f32) void {
        std.debug.assert(s > 0);
        if (s == self.pixel_scale) return;
        self.pixel_scale = s;
        // The tree has not changed, so its revision would let the next build
        // return the quads snapped to the old grid. Revisions start at 1.
        self.built_revision = 0;
    }

    pub fn items(self: *const Scene) []const Quad {
        return self.quads.items;
    }

    pub fn ownerOf(self: *const Scene, quad_index: usize) Index {
        return self.owners.items[quad_index];
    }

    /// The element painted frontmost at `p`, or null where nothing is
    /// painted: the scene-driven hit test `Tree.hitTest` leaves to this file.
    ///
    /// It walks the primitives back to front in the order they were drawn,
    /// layers included, so a popover hanging out of the row that owns it --
    /// which the tree's descent by containment never enters -- is hit before
    /// whatever it covers. A primitive counts where the point is inside both
    /// its rectangle and its clip, so a row scrolled out of its list is not
    /// clicked through the list's edge. Glyphs count: a click on a letter is a
    /// click on its label. Rounded corners do not: a click in the corner of a
    /// rounded button is on the button, which is what a person meant.
    ///
    /// What it answers is what is *on screen*, which is the last built scene
    /// -- the right question for a click, whose target is what the user saw.
    /// Linear in the primitives, which is fine for a click and is why hover,
    /// every frame, keeps the tree's binary search.
    pub fn hitTest(self: *const Scene, p: Point) ?Index {
        var i = self.quads.items.len;
        while (i > 0) {
            i -= 1;
            const q = self.quads.items[i];
            if (q.rect().contains(p) and q.clipRect().contains(p)) return self.owners.items[i];
        }
        return null;
    }

    /// Rebuilds the primitive list from the tree, unless nothing has changed.
    ///
    /// The tree must have been laid out. Returns what the build cost; a frame
    /// where nothing changed returns `.{ .rebuilt = false }` and leaves the
    /// previous primitives in place, so the caller may upload them again or
    /// skip the upload as it prefers.
    pub fn build(self: *Scene, t: *const Tree) Allocator.Error!Stats {
        if (self.built_revision == t.revision) {
            self.stats = .{ .rebuilt = false };
            return self.stats;
        }
        self.stats = .{ .rebuilt = true };

        self.quads.clearRetainingCapacity();
        self.owners.clearRetainingCapacity();
        self.layer_of.clearRetainingCapacity();
        self.stack.clearRetainingCapacity();

        const els = t.elements();
        const view: Rect = .{ .w = t.viewport.w, .h = t.viewport.h };

        // One element emits at most one box quad plus one quad per glyph, so
        // the exact upper bound is known before the walk -- the tree keeps the
        // glyph total so that finding it is not itself a pass over the
        // elements. Reserving it turns every append into a store, and means a
        // rebuild performs no allocation at all once the tree has reached its
        // largest size.
        const cap = els.len + t.glyph_total;
        try self.quads.ensureTotalCapacity(self.gpa, cap);
        try self.owners.ensureTotalCapacity(self.gpa, cap);
        try self.layer_of.ensureTotalCapacity(self.gpa, cap);

        var multi_layer = false;
        var first_layer: Layer = 0;

        try self.stack.append(self.gpa, .{ .next = t.root(), .clip = view, .layer = 0 });

        while (self.stack.items.len > 0) {
            const depth = self.stack.items.len - 1;
            const idx = self.stack.items[depth].next;
            if (idx == none) {
                _ = self.stack.pop();
                continue;
            }
            const inherited_clip = self.stack.items[depth].clip;
            const inherited_layer = self.stack.items[depth].layer;
            const e = &els[idx];
            // Advance the cursor before anything can reallocate the stack.
            self.stack.items[depth].next = e.next_sibling;

            self.stats.visited += 1;

            // Entering a layer restarts the clip chain at the viewport; see
            // `Paint.layer` for why that is the behaviour and not a bug.
            var clip = inherited_clip;
            var layer = inherited_layer;
            if (e.paint.layer != 0 and e.paint.layer != inherited_layer) {
                layer = e.paint.layer;
                clip = view;
            }

            const visible_part = clip.intersect(e.bounds);
            const inside = visible_part.w > 0 and visible_part.h > 0;

            if (!inside) {
                self.stats.culled += 1;
                // Only a clipping element can vouch for its descendants. An
                // element without `clip_children` may have children that
                // overflow it and land back inside the clip, so its subtree has
                // to be walked even though the element itself is invisible.
                if (e.paint.clip_children) {
                    self.stats.skipped_subtrees += 1;
                    continue;
                }
            } else {
                if (e.paint.isVisible()) {
                    self.quads.appendAssumeCapacity(.{
                        .x = e.bounds.x,
                        .y = e.bounds.y,
                        .w = e.bounds.w,
                        .h = e.bounds.h,
                        .background = e.paint.background.pack(),
                        .border_color = e.paint.border_color.pack(),
                        .border_width = e.paint.border_width,
                        .corner_radius = e.paint.corner_radius,
                        .cx = clip.x,
                        .cy = clip.y,
                        .cw = clip.w,
                        .ch = clip.h,
                    });
                    self.owners.appendAssumeCapacity(idx);
                    self.layer_of.appendAssumeCapacity(layer);
                    if (self.stats.emitted == 0) {
                        first_layer = layer;
                    } else if (layer != first_layer) {
                        multi_layer = true;
                    }
                    self.stats.emitted += 1;
                }

                // Glyphs come after the box, so a label paints over its own
                // background without anything having to sort them. They are
                // emitted whether or not the box was: a label normally has no
                // fill at all, and `isVisible` is a question about the box.
                //
                // Positions are relative to the content origin -- the padding
                // box corner -- and are not clipped to the element's own
                // bounds. Text that overflows its element behaves like any
                // other overflow: it shows unless an ancestor clips it.
                if (e.text.glyphs.len > 0) {
                    const fg = e.paint.text_color.pack();
                    const ps = self.pixel_scale;
                    const ox = e.bounds.x + e.style.padding;
                    const oy = e.bounds.y + e.style.padding;
                    for (e.text.glyphs) |g| {
                        // A space is a glyph with an advance and no ink. It is
                        // in the run because a caret has to be able to sit
                        // after it; it is not in the scene because there is
                        // nothing to draw.
                        if (!g.hasInk()) continue;
                        self.quads.appendAssumeCapacity(.{
                            // Snapped to the pixel grid. Element bounds are
                            // fractional in general -- flex division produces
                            // thirds -- and a glyph quad at a fractional
                            // position would no longer map one destination
                            // pixel to one atlas texel, which is the whole
                            // basis of how text is sampled here. Rounding
                            // moves a line of text by at most half a pixel and
                            // keeps it crisp; not rounding keeps it where the
                            // layout put it and makes it blurry. Every toolkit
                            // that does not do subpixel positioning makes the
                            // same trade.
                            //
                            // The grid is the device's, not the layout's: on a
                            // 2x display a glyph may sit on a half point.
                            .x = @round((ox + g.dx) * ps) / ps,
                            .y = @round((oy + g.dy) * ps) / ps,
                            .w = g.w,
                            .h = g.h,
                            .background = fg,
                            .border_color = 0,
                            .border_width = 0,
                            .corner_radius = 0,
                            .cx = clip.x,
                            .cy = clip.y,
                            .cw = clip.w,
                            .ch = clip.h,
                            .u0 = g.u0,
                            .v0 = g.v0,
                            .u1 = g.u1,
                            .v1 = g.v1,
                            .flags = .{ .textured = true },
                        });
                        self.owners.appendAssumeCapacity(idx);
                        self.layer_of.appendAssumeCapacity(layer);
                        if (self.stats.emitted == 0) {
                            first_layer = layer;
                        } else if (layer != first_layer) {
                            multi_layer = true;
                        }
                        self.stats.emitted += 1;
                        self.stats.glyphs += 1;
                    }
                }
            }

            if (e.first_child != none) {
                // A clip cuts at the inside of the border, not at the element's
                // edge. Clipping at the edge instead lets the first overflowing
                // child paint over the border that is supposed to contain it,
                // which is visible at the bottom of the list panel in
                // `tools/demo.zig`. CSS calls this the padding box.
                const child_clip = if (e.paint.clip_children)
                    clip.intersect(insetBy(e.bounds, e.paint.border_width))
                else
                    clip;
                try self.stack.append(self.gpa, .{
                    .next = e.first_child,
                    .clip = child_clip,
                    .layer = layer,
                });
            }
        }

        self.stats.layers_used = if (self.stats.emitted == 0)
            0
        else if (multi_layer)
            try self.bucketByLayer()
        else
            1;

        self.built_revision = t.revision;
        return self.stats;
    }

    /// Stable counting sort of the primitives by layer.
    ///
    /// A counting pass rather than a comparison sort because `Layer` is a `u8`:
    /// 256 buckets is a fixed array, the pass is linear, and stability comes
    /// free from writing in build order -- which matters, because stability is
    /// what preserves tree paint order inside a layer.
    fn bucketByLayer(self: *Scene) Allocator.Error!u32 {
        var counts: [256]u32 = @splat(0);
        for (self.layer_of.items) |l| counts[l] += 1;

        var used: u32 = 0;
        var offsets: [256]u32 = @splat(0);
        var running: u32 = 0;
        for (&offsets, counts) |*off, n| {
            off.* = running;
            running += n;
            if (n > 0) used += 1;
        }

        const n = self.quads.items.len;
        try self.sorted_quads.resize(self.gpa, n);
        try self.sorted_owners.resize(self.gpa, n);
        for (self.quads.items, self.owners.items, self.layer_of.items) |q, o, l| {
            const at = offsets[l];
            offsets[l] = at + 1;
            self.sorted_quads.items[at] = q;
            self.sorted_owners.items[at] = o;
        }
        std.mem.swap(std.ArrayList(Quad), &self.quads, &self.sorted_quads);
        std.mem.swap(std.ArrayList(Index), &self.owners, &self.sorted_owners);
        return used;
    }
};
