//! A retained element tree with element-level dirty tracking, and the flexbox
//! engine that lays it out.
//!
//! This is the architectural bet the project exists to make, and it is the one
//! part of the design that was measured before it was written. The benchmark
//! repository's runs 2 through 9 established, against GPUI as the baseline:
//!
//!   - a frame where nothing changed costs ~15 ns and zero allocations here,
//!     against ~2.3 ms of CPU and ~8 400 allocations for a view-level design
//!   - that figure is unaffected by how complicated the layout model is, because
//!     a frame that changes nothing does no layout work at all
//!   - a size change stays local in realistic trees, and degrades to a full
//!     container relayout when a line overflows, because `flex-shrink` defaults
//!     to 1 and couples every sibling
//!
//! Consequences that shaped this file, each of which cost a measurement to
//! learn:
//!
//!   - The tree is RETAINED. A frame arena that is reset wholesale cannot reuse
//!     last frame's subtrees, which is the entire saving.
//!   - The cross extent of a single non-wrapping line is the container's own
//!     inner cross size, not the tallest child's. That is what CSS 9.4 step 8
//!     says, and it is also the only version the fast path can compute without
//!     scanning siblings -- the correct rule turned out to be the cheap one.
//!   - `sum_main` is maintained incrementally so the overflow test is O(1).
//!     Testing it the obvious way means scanning every sibling, which is the
//!     work being avoided, and without the cache `flex-shrink: 1` alone forces
//!     the slow path on every single size change.
//!   - The reposition drain follows a stamped path, not just moved bounds. A
//!     child can land exactly where it was while a descendant still needs
//!     laying out.
//!   - The climb has two exits and they are not the same case. Collapsing them
//!     laid the root out as its own child; see `flushElement`.
//!
//! Storage, layout and dirty tracking are in one file deliberately. They share
//! twelve scratch buffers and a frame stamp, and splitting them would mean
//! either mutual imports or passing all of it as arguments. It gets split when
//! that stops being true.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geometry = @import("geometry.zig");
const style_mod = @import("style.zig");
const paint_mod = @import("paint.zig");
const glyph_mod = @import("glyph.zig");

pub const Rect = geometry.Rect;
pub const Size = geometry.Size;
pub const Point = geometry.Point;
pub const Axis = geometry.Axis;
pub const Style = style_mod.Style;
pub const Sizing = style_mod.Sizing;
pub const Justify = style_mod.Justify;
pub const AlignItems = style_mod.AlignItems;
pub const Paint = paint_mod.Paint;
pub const Color = paint_mod.Color;
pub const Glyph = glyph_mod.Glyph;
pub const TextRun = glyph_mod.TextRun;

pub const Index = u32;
pub const none: Index = std.math.maxInt(Index);

/// Internal size mode. The public API uses `Sizing`, a tagged union; this is
/// the denormalised form the hot loops read, refreshed whenever a style is set.
const Mode = enum(u8) { fixed, content, grow };

fn modeOf(s: Sizing) Mode {
    return switch (s) {
        .fixed => .fixed,
        .content => .content,
        .grow => .grow,
    };
}

fn definiteLen(s: Sizing) f32 {
    return switch (s) {
        .fixed => |v| v,
        else => 0,
    };
}

fn growOf(s: Sizing) f32 {
    return switch (s) {
        .grow => |v| v,
        else => 0,
    };
}

fn clampF(v: f32, lo: f32, hi: f32) f32 {
    return @min(@max(v, lo), hi);
}

pub const Element = struct {
    // --- structure ---
    parent: Index = none,
    first_child: Index = none,
    last_child: Index = none,
    next_sibling: Index = none,
    child_count: u32 = 0,

    // --- the caller's style, kept verbatim so `setStyle` can compare inputs ---
    style: Style = .{},

    /// What this element looks like. Deliberately a separate value from
    /// `style`, reached by a separate setter that does not dirty layout; see
    /// `paint.zig`.
    paint: Paint = .{},

    /// This element's shaped text, and a layout input: a leaf with text takes
    /// its content size and its baseline from the run rather than from the
    /// synthesised guess a childless element otherwise gets.
    ///
    /// The glyph slice is owned by the tree and freed in `deinit`. Shaped by
    /// the `text` module, which the core does not import; see `glyph.zig` for
    /// why the dependency runs that way.
    text: TextRun = .{},

    // --- denormalised style, read by the hot loops ---
    axis: Axis = .col,
    w_mode: Mode = .content,
    h_mode: Mode = .content,
    fixed_w: f32 = 0,
    fixed_h: f32 = 0,
    flex_grow_w: f32 = 0,
    flex_grow_h: f32 = 0,

    // --- computed ---
    /// Content size: what this element wants to be, before its parent flexes it.
    intrinsic_w: f32 = 0,
    intrinsic_h: f32 = 0,
    /// Distance from the top edge to the first baseline. Derivable bottom-up, so
    /// a baseline change propagates through the same dirty chain as a size
    /// change -- which is how a change reaches the root at all.
    baseline: f32 = 0,
    /// Final position and size, in the coordinate space of the tree's viewport.
    bounds: Rect = .{},

    // --- incremental bookkeeping ---
    /// Children's hypothetical outer main sizes plus gaps. Maintained as
    /// intrinsics are recomputed; see the file header.
    sum_main: f32 = 0,
    /// Any child with a grow factor on this element's main axis.
    any_grow_main: bool = false,
    /// Any child that will shrink when the line overflows. Almost always true
    /// under the CSS default, which is the point.
    any_shrink_main: bool = false,
    /// Children's positions are a pure prefix scan, so repositioning may start
    /// at a middle child and stop early. Requires no grow, no wrap, and
    /// justify-content at the start; overflow is checked separately because it
    /// is dynamic.
    simple_main: bool = false,
};

pub const Stats = struct {
    /// Elements whose content size was recomputed, plus the children examined.
    intrinsic: u32 = 0,
    /// Child slots positioned.
    position: u32 = 0,
    /// Items visited by the CSS 9.7 freeze loop, summed over passes. Separate
    /// from `position` because this is the cost real flexbox adds.
    flex_passes: u32 = 0,
    /// Repositions that kept the prefix-scan path.
    fast_path: u32 = 0,
    /// Repositions that had to lay out the whole container.
    slow_path: u32 = 0,
    /// Whole-tree layouts. Should be rare after the first frame; one per frame
    /// means the dirty tracking is not working.
    full_layouts: u32 = 0,

    pub fn total(self: Stats) u32 {
        return self.intrinsic + self.position + self.flex_passes;
    }
};

pub const Error = error{
    OutOfMemory,
    /// A wrapping container needs a definite size across its axis; see
    /// `Style.wrap`.
    WrapNeedsDefiniteCrossSize,
};

pub const Tree = struct {
    gpa: Allocator,
    els: std.ArrayList(Element) = .empty,

    /// Traversal orders, rebuilt when the structure changes.
    pre: std.ArrayList(Index) = .empty,
    post: std.ArrayList(Index) = .empty,

    /// Elements whose own size inputs changed since the last flush.
    dirty: std.ArrayList(Index) = .empty,

    /// Every element's children, grouped by parent, with `child_off[i]` the
    /// start of element `i`'s run. Rebuilt alongside `pre` and `post`, because
    /// it changes for exactly the same reason they do.
    ///
    /// The tree's own structure is a linked list of children, which is right
    /// for building and wrong for searching: `hitTest` wants to binary search
    /// a container's children, and a linked list cannot be indexed.
    child_list: std.ArrayList(Index) = .empty,
    child_off: std.ArrayList(u32) = .empty,

    /// Scratch, all sized to the element count because a single container may
    /// hold every element in the tree.
    stack: []Index = &.{},
    kids: []Index = &.{},
    base: []f32 = &.{},
    target: []f32 = &.{},
    frozen: []bool = &.{},
    hypo_cross: []f32 = &.{},
    line_start: []u32 = &.{},
    line_count: []u32 = &.{},
    line_main: []f32 = &.{},
    line_cross: []f32 = &.{},
    line_bl: []f32 = &.{},
    /// Marks the chain of elements whose intrinsic size changed this pass.
    /// Descent must follow this chain even where bounds did not move. A stamp
    /// avoids clearing the array every pass.
    path_stamp: []u32 = &.{},
    frame_no: u32 = 1,

    /// Set by any structural change. The benchmark only ever measured
    /// incremental *style* changes, so claiming incremental structural updates
    /// would be claiming something unmeasured.
    needs_full: bool = true,

    viewport: Size = .{},
    stats: Stats = .{},

    /// Glyphs across every element. Maintained by `setText` so that
    /// `Scene.build` can reserve its exact upper bound without a pass over the
    /// elements first.
    glyph_total: usize = 0,

    /// Bumped whenever anything that could change the rendered scene has
    /// actually changed: a repaint, or a layout that did work.
    ///
    /// This is how the measured claim survives the paint layer. `Scene.build`
    /// records the revision it built from and returns immediately when it still
    /// matches, so a frame where nothing changed costs one integer comparison
    /// at the scene layer too, rather than a walk over the tree emitting the
    /// same primitives again. A `u64` so it cannot wrap in any real session.
    revision: u64 = 1,

    pub fn init(gpa: Allocator) Error!Tree {
        var t: Tree = .{ .gpa = gpa };
        _ = try t.addElement(none, .{});
        return t;
    }

    pub fn deinit(self: *Tree) void {
        for (self.els.items) |e| {
            if (e.text.glyphs.len > 0) self.gpa.free(e.text.glyphs);
        }
        self.els.deinit(self.gpa);
        self.pre.deinit(self.gpa);
        self.post.deinit(self.gpa);
        self.dirty.deinit(self.gpa);
        self.child_list.deinit(self.gpa);
        self.child_off.deinit(self.gpa);
        self.freeScratch();
        self.* = undefined;
    }

    fn freeScratch(self: *Tree) void {
        self.gpa.free(self.stack);
        self.gpa.free(self.kids);
        self.gpa.free(self.base);
        self.gpa.free(self.target);
        self.gpa.free(self.frozen);
        self.gpa.free(self.hypo_cross);
        self.gpa.free(self.line_start);
        self.gpa.free(self.line_count);
        self.gpa.free(self.line_main);
        self.gpa.free(self.line_cross);
        self.gpa.free(self.line_bl);
        self.gpa.free(self.path_stamp);
    }

    fn growScratch(self: *Tree, n: usize) Error!void {
        if (self.path_stamp.len >= n) return;
        // +1 so line arrays can hold a sentinel line without a bounds check.
        const cap = n + 1;
        self.freeScratch();
        self.stack = try self.gpa.alloc(Index, cap);
        self.kids = try self.gpa.alloc(Index, cap);
        self.base = try self.gpa.alloc(f32, cap);
        self.target = try self.gpa.alloc(f32, cap);
        self.frozen = try self.gpa.alloc(bool, cap);
        self.hypo_cross = try self.gpa.alloc(f32, cap);
        self.line_start = try self.gpa.alloc(u32, cap);
        self.line_count = try self.gpa.alloc(u32, cap);
        self.line_main = try self.gpa.alloc(f32, cap);
        self.line_cross = try self.gpa.alloc(f32, cap);
        self.line_bl = try self.gpa.alloc(f32, cap);
        self.path_stamp = try self.gpa.alloc(u32, cap);
        @memset(self.path_stamp, 0);
        self.frame_no = 1;
    }

    // ------------------------------------------------------------- structure

    pub fn root(self: *const Tree) Index {
        _ = self;
        return 0;
    }

    pub fn count(self: *const Tree) usize {
        return self.els.items.len;
    }

    fn addElement(self: *Tree, parent: Index, s: Style) Error!Index {
        const idx: Index = @intCast(self.els.items.len);
        try self.els.append(self.gpa, .{ .parent = parent });
        try self.growScratch(self.els.items.len);
        self.applyStyle(idx, s);
        return idx;
    }

    /// Appends a child. Structural changes force a full layout on the next
    /// flush; they are rare and were never measured incrementally.
    pub fn appendChild(self: *Tree, parent: Index, s: Style) Error!Index {
        try validate(s);
        const idx = try self.addElement(parent, s);
        const p = &self.els.items[parent];
        if (p.last_child == none) {
            p.first_child = idx;
        } else {
            self.els.items[p.last_child].next_sibling = idx;
        }
        p.last_child = idx;
        p.child_count += 1;
        self.needs_full = true;
        return idx;
    }

    fn validate(s: Style) Error!void {
        if (!s.wrap) return;
        const cross_definite = switch (s.axis) {
            .row => s.height != .content,
            .col => s.width != .content,
        };
        if (!cross_definite) return Error.WrapNeedsDefiniteCrossSize;
    }

    // ----------------------------------------------------------------- style

    pub fn style(self: *const Tree, el: Index) Style {
        return self.els.items[el].style;
    }

    pub fn bounds(self: *const Tree, el: Index) Rect {
        return self.els.items[el].bounds;
    }

    pub fn contentSize(self: *const Tree, el: Index) Size {
        const e = &self.els.items[el];
        return .{ .w = e.intrinsic_w, .h = e.intrinsic_h };
    }

    /// Every element, in index order. The scene builder and the layout engine
    /// both walk this directly rather than through accessors, because a tree
    /// walk that re-indexes the list per field read pays a bounds check per
    /// field; callers outside the package should use the accessors below.
    pub fn elements(self: *const Tree) []const Element {
        return self.els.items;
    }

    /// Named `parentOf` rather than `parent` because the layout engine already
    /// uses `parent` as a local name throughout.
    pub fn parentOf(self: *const Tree, el: Index) Index {
        return self.els.items[el].parent;
    }

    pub fn firstChild(self: *const Tree, el: Index) Index {
        return self.els.items[el].first_child;
    }

    pub fn nextSibling(self: *const Tree, el: Index) Index {
        return self.els.items[el].next_sibling;
    }

    pub fn childCount(self: *const Tree, el: Index) u32 {
        return self.els.items[el].child_count;
    }

    pub fn paint(self: *const Tree, el: Index) Paint {
        return self.els.items[el].paint;
    }

    /// Sets appearance. Never dirties layout, by construction: the whole reason
    /// `Paint` is not part of `Style` is so that this function cannot.
    pub fn setPaint(self: *Tree, el: Index, p: Paint) void {
        const e = &self.els.items[el];
        if (Paint.eql(e.paint, p)) return;
        e.paint = p;
        self.revision += 1;
    }

    pub fn text(self: *const Tree, el: Index) TextRun {
        return self.els.items[el].text;
    }

    /// Installs a shaped run on an element, taking a copy of the glyphs.
    ///
    /// A copy, not the caller's slice, because the tree outlives whatever
    /// scratch buffer the shaper used and nothing else in this API asks a
    /// caller to keep a buffer alive for as long as the element exists.
    ///
    /// Unlike `setPaint` this DOES dirty layout, and that asymmetry is the
    /// whole content of the function: text is a size input. A label that
    /// changes from "3" to "3000" is wider, and its container has to be laid
    /// out again. Changing the colour of that label is not, which is why the
    /// colour is in `Paint` and goes through the setter that cannot dirty
    /// anything.
    ///
    /// Comparing the old run against the new one first would be the same
    /// optimisation `setStyle` makes, and is deliberately not done: a glyph
    /// slice comparison is O(glyphs), the shaping that produced it already cost
    /// far more than the comparison would save, and a caller re-setting
    /// identical text every frame is a caller that should not be re-shaping
    /// every frame either. The right place to stop that is the shaper's cache,
    /// not here.
    pub fn setText(self: *Tree, el: Index, run: TextRun) Error!void {
        const copy = if (run.glyphs.len == 0)
            &.{}
        else
            try self.gpa.dupe(Glyph, run.glyphs);

        const e = &self.els.items[el];
        self.glyph_total -= e.text.glyphs.len;
        if (e.text.glyphs.len > 0) self.gpa.free(e.text.glyphs);
        e.text = .{
            .glyphs = copy,
            .width = run.width,
            .ascent = run.ascent,
            .descent = run.descent,
        };
        self.glyph_total += copy.len;

        try self.dirty.append(self.gpa, el);
        self.revision += 1;
    }

    pub fn clearText(self: *Tree, el: Index) Error!void {
        if (self.els.items[el].text.glyphs.len == 0 and
            self.els.items[el].text.width == 0) return;
        try self.setText(el, .{});
    }

    fn applyStyle(self: *Tree, el: Index, s: Style) void {
        const e = &self.els.items[el];
        e.style = s;
        e.axis = s.axis;
        e.w_mode = modeOf(s.width);
        e.h_mode = modeOf(s.height);
        e.fixed_w = definiteLen(s.width);
        e.fixed_h = definiteLen(s.height);
        e.flex_grow_w = growOf(s.width);
        e.flex_grow_h = growOf(s.height);
    }

    /// Sets a style and marks the element dirty if anything actually changed.
    ///
    /// Comparing first is not an optimisation detail: a caller that re-sets the
    /// same style every frame -- which any declarative layer on top will do --
    /// would otherwise dirty the whole tree every frame and give back exactly
    /// the view-level behaviour this design exists to avoid.
    pub fn setStyle(self: *Tree, el: Index, s: Style) Error!void {
        try validate(s);
        const e = &self.els.items[el];
        if (Style.eql(e.style, s)) return;

        // Properties that change how this element's CHILDREN are arranged
        // invalidate cached predicates on this element, and those are recomputed
        // for the whole tree only on a full layout.
        const container_changed = e.style.axis != s.axis or
            e.style.gap != s.gap or
            e.style.wrap != s.wrap or
            e.style.justify != s.justify or
            e.style.align_items != s.align_items;
        // A change to this element's own flex PARTICIPATION changes its
        // parent's cached predicates. Participation is the mode and the factor,
        // NOT the length: going from `.fixed = 100` to `.fixed = 110` is the
        // ordinary incremental case the benchmark measured, and treating it as
        // structural would force a full layout on every resize and give back
        // exactly the behaviour this design exists to avoid.
        const participation_changed =
            modeOf(e.style.width) != modeOf(s.width) or
            modeOf(e.style.height) != modeOf(s.height) or
            growOf(e.style.width) != growOf(s.width) or
            growOf(e.style.height) != growOf(s.height) or
            e.style.flex_shrink != s.flex_shrink;

        self.applyStyle(el, s);

        if (container_changed or participation_changed) {
            self.needs_full = true;
        } else {
            try self.dirty.append(self.gpa, el);
        }
    }

    /// Marks an element whose own size inputs changed by some other route.
    pub fn markDirty(self: *Tree, el: Index) Error!void {
        try self.dirty.append(self.gpa, el);
    }

    // ---------------------------------------------------------------- queries

    /// Deepest element containing the point, or the root. Front-to-back within
    /// a parent: later children are painted later and so hit first.
    ///
    /// `Paint.clip_children` needs no test here, which is worth stating because
    /// the opposite is the obvious assumption. The descent only enters a child
    /// whose bounds contain the point, so every element on the path contains
    /// it; a clip is the intersection of the clipping elements on that path,
    /// and a point inside all of them is inside their intersection. A clip can
    /// therefore never exclude a hit this function would otherwise report.
    /// Clip-aware testing starts to matter only for a hit test that does not
    /// descend by containment -- which is the scene-order one described below.
    ///
    /// What this does NOT respect is `Paint.layer`. A layered subtree paints
    /// over whatever is beneath it but is not hit first here, so a tooltip
    /// drawn over a button does not yet intercept the click. Getting that right
    /// means testing in the order things were actually painted, which is the
    /// order `Scene` already holds, against the clip each primitive already
    /// carries. So it belongs to a scene-driven hit test and is left undone
    /// rather than approximated here.
    /// A container's children, in order. Empty until the first `layout`.
    pub fn childrenOf(self: *const Tree, el: Index) []const Index {
        if (self.child_off.items.len <= el + 1) return &.{};
        const a = self.child_off.items[el];
        const b = self.child_off.items[el + 1];
        return self.child_list.items[a..b];
    }

    pub fn hitTest(self: *const Tree, p: Point) Index {
        var hit: Index = self.root();
        if (!self.els.items[hit].bounds.contains(p)) return hit;
        while (true) {
            const found = self.hitChild(hit, p);
            if (found == none) break;
            hit = found;
        }
        return hit;
    }

    /// The child of `parent` containing `p`, or `none`.
    ///
    /// A non-wrapping container places its children by prefix scan along its
    /// main axis, so their main-axis ranges are increasing and do not overlap:
    /// a child's bounds are exactly the slot it was given, and the next slot
    /// starts where this one ends. At most one child can contain the point, and
    /// it can be found by binary search.
    ///
    /// That invariant is worth the code. Scanning every child makes hit testing
    /// cost the widest sibling list rather than the depth, and a long list is
    /// one parent with ten thousand children: measured at 16.9 us per pointer
    /// move against 73 ns on a tree of the same size shaped as a grid.
    ///
    /// A wrapping container breaks the invariant -- several lines share a main
    /// range -- so it is scanned.
    fn hitChild(self: *const Tree, parent: Index, p: Point) Index {
        const kids = self.childrenOf(parent);
        if (kids.len == 0) return none;
        const e = &self.els.items[parent];

        if (e.style.wrap or kids.len < 8) return self.hitChildLinear(kids, p);

        const want = switch (e.axis) {
            .row => p.x,
            .col => p.y,
        };
        // The last child whose main-axis start is at or before the point. A
        // child that starts after it cannot contain it, and an earlier one
        // ended before the candidate began.
        var lo: usize = 0;
        var hi: usize = kids.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const b = self.els.items[kids[mid]].bounds;
            const start = switch (e.axis) {
                .row => b.x,
                .col => b.y,
            };
            if (start <= want) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return none;
        const candidate = kids[lo - 1];
        return if (self.els.items[candidate].bounds.contains(p)) candidate else none;
    }

    /// The definition `hitChild` has to agree with: the last child containing
    /// the point, later children being painted over earlier ones.
    fn hitChildLinear(self: *const Tree, kids: []const Index, p: Point) Index {
        var found: Index = none;
        for (kids) |c| {
            if (self.els.items[c].bounds.contains(p)) found = c;
        }
        return found;
    }

    /// Hit testing with every container scanned. Kept so the randomised test in
    /// `layout_test.zig` has something to compare the binary search against;
    /// the two must agree for every point on every tree.
    pub fn hitTestLinear(self: *const Tree, p: Point) Index {
        var hit: Index = self.root();
        if (!self.els.items[hit].bounds.contains(p)) return hit;
        while (true) {
            const found = self.hitChildLinear(self.childrenOf(hit), p);
            if (found == none) break;
            hit = found;
        }
        return hit;
    }

    // ----------------------------------------------------------------- layout

    /// Lays out the whole tree. Required after a structural change, and after
    /// the viewport changes.
    pub fn layout(self: *Tree, viewport: Size) void {
        self.viewport = viewport;
        self.refreshOrders();
        self.refreshPredicates();
        self.intrinsicAll();
        self.positionAll();
        self.dirty.clearRetainingCapacity();
        self.needs_full = false;
        self.stats.full_layouts += 1;
        self.revision += 1;
    }

    /// Applies everything marked dirty since the last call, and returns what it
    /// cost. An unchanged frame does no work at all and returns zeroes -- the
    /// measurement this whole design rests on.
    pub fn flush(self: *Tree) Stats {
        self.stats = .{};
        if (self.needs_full) {
            self.layout(self.viewport);
            const s = self.stats;
            self.stats = .{};
            return s;
        }
        for (self.dirty.items) |el| self.flushElement(el);
        self.dirty.clearRetainingCapacity();
        // A dirty element that turned out not to move still counted work, and
        // `Stats.total()` being zero here means every entry was a no-op, so the
        // scene genuinely cannot have changed.
        if (self.stats.total() > 0) self.revision += 1;
        return self.stats;
    }

    fn refreshOrders(self: *Tree) void {
        const n = self.els.items.len;
        self.pre.clearRetainingCapacity();
        self.post.clearRetainingCapacity();
        self.pre.ensureTotalCapacity(self.gpa, n) catch return;
        self.post.ensureTotalCapacity(self.gpa, n) catch return;

        var sp: usize = 0;
        self.stack[sp] = self.root();
        sp += 1;
        while (sp > 0) {
            sp -= 1;
            const idx = self.stack[sp];
            self.pre.appendAssumeCapacity(idx);
            var c = self.els.items[idx].first_child;
            while (c != none) : (c = self.els.items[c].next_sibling) {
                self.stack[sp] = c;
                sp += 1;
            }
        }
        // Bottom-up order is the reverse of a pre-order walk.
        var i = self.pre.items.len;
        while (i > 0) {
            i -= 1;
            self.post.appendAssumeCapacity(self.pre.items[i]);
        }

        self.child_list.clearRetainingCapacity();
        self.child_off.clearRetainingCapacity();
        self.child_list.ensureTotalCapacity(self.gpa, n) catch return;
        self.child_off.ensureTotalCapacity(self.gpa, n + 1) catch return;
        for (self.els.items) |*e| {
            self.child_off.appendAssumeCapacity(@intCast(self.child_list.items.len));
            var c = e.first_child;
            while (c != none) : (c = self.els.items[c].next_sibling) {
                self.child_list.appendAssumeCapacity(c);
            }
        }
        self.child_off.appendAssumeCapacity(@intCast(self.child_list.items.len));
    }

    fn refreshPredicates(self: *Tree) void {
        for (self.els.items) |*e| {
            var grow = false;
            var shrink = false;
            var c = e.first_child;
            while (c != none) : (c = self.els.items[c].next_sibling) {
                const ch = &self.els.items[c];
                const main_mode = switch (e.axis) {
                    .row => ch.w_mode,
                    .col => ch.h_mode,
                };
                const main_grow = switch (e.axis) {
                    .row => ch.flex_grow_w,
                    .col => ch.flex_grow_h,
                };
                if (main_mode == .grow and main_grow > 0) grow = true;
                if (ch.style.flex_shrink > 0) shrink = true;
            }
            e.any_grow_main = grow;
            e.any_shrink_main = shrink;
            // Baseline alignment needs the maximum baseline and the maximum
            // descent across the line, both of which are maxima over siblings
            // and so cost exactly the scan the fast path exists to avoid. It
            // takes the slow path. Every other alignment is expressible from
            // the container's own bounds.
            e.simple_main = !grow and !e.style.wrap and
                e.style.justify == .start and
                e.style.align_items != .baseline;
        }
    }

    // --- sizing helpers, all in logical pixels ---

    fn baseMain(self: *const Tree, idx: Index, axis: Axis) f32 {
        const e = &self.els.items[idx];
        return switch (axis) {
            .row => if (e.w_mode == .fixed) e.fixed_w else e.intrinsic_w,
            .col => if (e.h_mode == .fixed) e.fixed_h else e.intrinsic_h,
        };
    }

    fn minMain(self: *const Tree, idx: Index, axis: Axis) f32 {
        const s = &self.els.items[idx].style;
        return switch (axis) {
            .row => s.min_width,
            .col => s.min_height,
        };
    }

    fn maxMain(self: *const Tree, idx: Index, axis: Axis) f32 {
        const s = &self.els.items[idx].style;
        return switch (axis) {
            .row => s.max_width,
            .col => s.max_height,
        };
    }

    /// The flex base size clamped by min/max. Line breaking and `sum_main` are
    /// computed from this.
    fn hypoMain(self: *const Tree, idx: Index, axis: Axis) f32 {
        return clampF(self.baseMain(idx, axis), self.minMain(idx, axis), self.maxMain(idx, axis));
    }

    /// The size across the parent's axis, before any stretch is applied.
    fn hypoCross(self: *const Tree, idx: Index, axis: Axis) f32 {
        const e = &self.els.items[idx];
        const s = &e.style;
        return switch (axis) {
            .row => clampF(if (e.h_mode == .fixed) e.fixed_h else e.intrinsic_h, s.min_height, s.max_height),
            .col => clampF(if (e.w_mode == .fixed) e.fixed_w else e.intrinsic_w, s.min_width, s.max_width),
        };
    }

    fn mainGrow(self: *const Tree, idx: Index, axis: Axis) f32 {
        const e = &self.els.items[idx];
        const m = switch (axis) {
            .row => e.w_mode,
            .col => e.h_mode,
        };
        if (m != .grow) return 0;
        return switch (axis) {
            .row => e.flex_grow_w,
            .col => e.flex_grow_h,
        };
    }

    /// Recomputes one element's content size and baseline from its children.
    /// Returns true if anything the parent can observe changed, which is what
    /// stops the upward climb.
    fn recomputeIntrinsic(self: *Tree, idx: Index) bool {
        const e = &self.els.items[idx];
        const was_w = e.intrinsic_w;
        const was_h = e.intrinsic_h;
        const was_bl = e.baseline;
        const pad = e.style.padding;

        var main_sz: f32 = 0;
        var cross: f32 = 0;
        var kids: u32 = 0;
        var deepest_bl: f32 = 0;
        var first_bl: f32 = 0;
        var c = e.first_child;
        while (c != none) : (c = self.els.items[c].next_sibling) {
            main_sz += self.hypoMain(c, e.axis);
            cross = @max(cross, self.hypoCross(c, e.axis));
            deepest_bl = @max(deepest_bl, self.els.items[c].baseline);
            if (kids == 0) first_bl = self.els.items[c].baseline;
            kids += 1;
        }
        if (kids > 1) main_sz += e.style.gap * @as(f32, @floatFromInt(kids - 1));
        e.sum_main = main_sz;
        main_sz += pad * 2;
        cross += pad * 2;

        switch (e.axis) {
            .row => {
                e.intrinsic_w = main_sz;
                e.intrinsic_h = cross;
            },
            .col => {
                e.intrinsic_h = main_sz;
                e.intrinsic_w = cross;
            },
        }
        // Text is a content size, and it is the element's OWN content rather
        // than a child's, so it is folded in as a lower bound on both axes
        // instead of replacing the sum over children. A container that has both
        // text and children is unusual and the result is at least defensible:
        // it is as large as it needs to be for either.
        //
        // `@max` and not an assignment for the same reason: an element with
        // text and a padding of 8 is text plus 16 wide, and an element with
        // text whose children are wider than the text is as wide as the
        // children.
        if (!e.text.isEmpty()) {
            e.intrinsic_w = @max(e.intrinsic_w, e.text.width + pad * 2);
            e.intrinsic_h = @max(e.intrinsic_h, e.text.height() + pad * 2);
        }

        if (e.w_mode == .fixed) e.intrinsic_w = e.fixed_w;
        if (e.h_mode == .fixed) e.intrinsic_h = e.fixed_h;

        // A row takes the deepest child baseline and a column the first
        // child's. A leaf with text has a real baseline -- the font's ascent
        // below the content edge, which is exactly where its glyphs were
        // positioned -- and a leaf without text keeps the synthesised guess,
        // because `align_items: .baseline` on a row of plain boxes still has to
        // mean something.
        if (!e.text.isEmpty() and kids == 0) {
            e.baseline = pad + e.text.ascent;
        } else if (kids == 0) {
            e.baseline = e.intrinsic_h * 0.8;
        } else switch (e.axis) {
            .row => e.baseline = pad + deepest_bl,
            .col => e.baseline = pad + first_bl,
        }

        self.stats.intrinsic += 1 + kids;
        return e.intrinsic_w != was_w or e.intrinsic_h != was_h or e.baseline != was_bl;
    }

    fn intrinsicAll(self: *Tree) void {
        for (self.post.items) |idx| _ = self.recomputeIntrinsic(idx);
    }

    /// CSS 9.7, "resolve the flexible lengths": distribute free space by flex
    /// factor, clamp to min/max, freeze whatever violated its clamp, repeat.
    /// `target[k]` receives the resolved main size for `kids[k]`.
    ///
    /// The loop is why real flexbox costs more than a prefix scan: with clamps
    /// reachable it runs more than once, and each pass is O(unfrozen).
    fn resolveFlexibleLengths(
        self: *Tree,
        axis: Axis,
        k0: usize,
        k1: usize,
        avail_main: f32,
        gap_total: f32,
    ) void {
        var sum_hypo: f32 = gap_total;
        var i = k0;
        while (i < k1) : (i += 1) {
            const c = self.kids[i];
            self.base[i] = self.baseMain(c, axis);
            self.target[i] = clampF(self.base[i], self.minMain(c, axis), self.maxMain(c, axis));
            sum_hypo += self.target[i];
        }
        const growing = sum_hypo < avail_main;

        // Freeze what cannot flex in the needed direction, including anything
        // whose base size is already on the wrong side of its clamp.
        i = k0;
        while (i < k1) : (i += 1) {
            const c = self.kids[i];
            const factor = if (growing)
                self.mainGrow(c, axis)
            else
                self.els.items[c].style.flex_shrink;
            const clamped_wrong = if (growing)
                self.base[i] > self.target[i]
            else
                self.base[i] < self.target[i];
            self.frozen[i] = (factor == 0) or clamped_wrong;
        }

        // Bounded because each pass freezes at least one item unless it is the
        // last; the guard is belt and braces against a float pathology.
        var guard: u32 = 0;
        while (guard < 64) : (guard += 1) {
            var used: f32 = gap_total;
            var factor_sum: f32 = 0;
            var scaled_sum: f32 = 0;
            var unfrozen: u32 = 0;
            i = k0;
            while (i < k1) : (i += 1) {
                const c = self.kids[i];
                if (self.frozen[i]) {
                    used += self.target[i];
                } else {
                    used += self.base[i];
                    unfrozen += 1;
                    if (growing) {
                        factor_sum += self.mainGrow(c, axis);
                    } else {
                        const sh = self.els.items[c].style.flex_shrink;
                        factor_sum += sh;
                        scaled_sum += sh * self.base[i];
                    }
                }
            }
            self.stats.flex_passes += unfrozen;
            if (unfrozen == 0) break;

            const free_space = avail_main - used;
            var violation: f32 = 0;
            i = k0;
            while (i < k1) : (i += 1) {
                if (self.frozen[i]) continue;
                const c = self.kids[i];
                var want: f32 = self.base[i];
                if (growing) {
                    const f = self.mainGrow(c, axis);
                    if (factor_sum > 0) want = self.base[i] + free_space * (f / factor_sum);
                } else {
                    // Shrinking is weighted by factor x base size, so a large
                    // item gives up more than a small one, as CSS specifies.
                    const sf = self.els.items[c].style.flex_shrink * self.base[i];
                    if (scaled_sum > 0) want = self.base[i] + free_space * (sf / scaled_sum);
                }
                const clamped = clampF(want, self.minMain(c, axis), self.maxMain(c, axis));
                violation += clamped - want;
                self.target[i] = clamped;
            }

            if (violation == 0) {
                i = k0;
                while (i < k1) : (i += 1) self.frozen[i] = true;
                break;
            }
            // Freeze whatever clamped in the direction of the total violation;
            // the rest get another pass with the space that freed up.
            i = k0;
            while (i < k1) : (i += 1) {
                if (self.frozen[i]) continue;
                const c = self.kids[i];
                const lo = self.minMain(c, axis);
                const hi = self.maxMain(c, axis);
                if (violation > 0) {
                    if (self.target[i] == lo) self.frozen[i] = true;
                } else {
                    if (self.target[i] == hi) self.frozen[i] = true;
                }
            }
        }
    }

    /// Full flexbox layout of one element's children: materialise the items,
    /// break them into lines, resolve flexible lengths per line, then apply
    /// justify-content and align-items. Returns true if any child moved.
    fn positionChildren(self: *Tree, idx: Index) bool {
        const e = &self.els.items[idx];
        if (e.first_child == none) return false;

        const pad = e.style.padding;
        const gap = e.style.gap;
        const inner_x = e.bounds.x + pad;
        const inner_y = e.bounds.y + pad;
        const inner_w = @max(0, e.bounds.w - pad * 2);
        const inner_h = @max(0, e.bounds.h - pad * 2);
        const avail_main = switch (e.axis) {
            .row => inner_w,
            .col => inner_h,
        };
        const avail_cross = switch (e.axis) {
            .row => inner_h,
            .col => inner_w,
        };

        var k: usize = 0;
        var c = e.first_child;
        while (c != none) : (c = self.els.items[c].next_sibling) {
            self.kids[k] = c;
            k += 1;
        }
        var work: u32 = @intCast(k);

        // --- line breaking ---
        var n_lines: usize = 0;
        if (!e.style.wrap) {
            self.line_start[0] = 0;
            self.line_count[0] = @intCast(k);
            n_lines = 1;
        } else {
            var i: usize = 0;
            var ls: usize = 0;
            var run: f32 = 0;
            while (i < k) : (i += 1) {
                const hm = self.hypoMain(self.kids[i], e.axis);
                const add = if (i == ls) hm else gap + hm;
                if (i > ls and run + add > avail_main) {
                    self.line_start[n_lines] = @intCast(ls);
                    self.line_count[n_lines] = @intCast(i - ls);
                    n_lines += 1;
                    ls = i;
                    run = hm;
                } else {
                    run += add;
                }
            }
            self.line_start[n_lines] = @intCast(ls);
            self.line_count[n_lines] = @intCast(k - ls);
            n_lines += 1;
            work += @intCast(k);
        }

        // --- per line: resolve main sizes, then the cross extent ---
        var li: usize = 0;
        while (li < n_lines) : (li += 1) {
            const k0: usize = self.line_start[li];
            const k1: usize = k0 + self.line_count[li];
            const cnt = k1 - k0;
            const gap_total = if (cnt > 1) gap * @as(f32, @floatFromInt(cnt - 1)) else 0;

            self.resolveFlexibleLengths(e.axis, k0, k1, avail_main, gap_total);

            var used: f32 = gap_total;
            var line_cross: f32 = 0;
            var max_bl: f32 = 0;
            var max_below: f32 = 0;
            var i = k0;
            while (i < k1) : (i += 1) {
                const ci = self.kids[i];
                used += self.target[i];
                const hc = self.hypoCross(ci, e.axis);
                self.hypo_cross[i] = hc;
                line_cross = @max(line_cross, hc);
                if (e.style.align_items == .baseline) {
                    const bl = self.els.items[ci].baseline;
                    max_bl = @max(max_bl, bl);
                    max_below = @max(max_below, hc - bl);
                }
            }
            if (e.style.align_items == .baseline) line_cross = @max(line_cross, max_bl + max_below);
            self.line_main[li] = used;
            self.line_bl[li] = max_bl;
            // A single non-wrapping line's cross extent IS the container's
            // inner cross size, not the larger of that and the tallest child.
            // CSS 9.4 step 8 says so, and the difference is visible: taking the
            // maximum lets one overflowing child enlarge the line, which then
            // moves every centred sibling. An invisible 116-pixel popover
            // anchor inside a 28-pixel toolbar row pushed the row's icon and
            // label 51 pixels down its own container -- found by looking at
            // `tools/demo.zig`, not by any test.
            //
            // Where the container's cross size came from its content, this is
            // the same number by construction: the intrinsic pass set it to the
            // largest child. Where it was imposed -- fixed, stretched, or
            // clamped by min/max -- the imposed value is the correct one and
            // the maximum was wrong.
            self.line_cross[li] = if (n_lines == 1 and !e.style.wrap)
                avail_cross
            else
                line_cross;
        }

        // --- place ---
        var any_moved = false;
        var cross_cursor: f32 = switch (e.axis) {
            .row => inner_y,
            .col => inner_x,
        };
        li = 0;
        while (li < n_lines) : (li += 1) {
            const k0: usize = self.line_start[li];
            const k1: usize = k0 + self.line_count[li];
            const cnt = k1 - k0;
            const lc = self.line_cross[li];

            const slack = avail_main - self.line_main[li];
            var main_cursor: f32 = switch (e.axis) {
                .row => inner_x,
                .col => inner_y,
            };
            var extra: f32 = 0;
            switch (e.style.justify) {
                .start => {},
                .center => main_cursor += @max(0, slack) / 2,
                .end => main_cursor += @max(0, slack),
                .space_between => if (cnt > 1) {
                    extra = @max(0, slack) / @as(f32, @floatFromInt(cnt - 1));
                },
            }

            var i = k0;
            while (i < k1) : (i += 1) {
                const ci = self.kids[i];
                const ch = &self.els.items[ci];
                const main_sz = self.target[i];

                var cross_sz = self.hypo_cross[i];
                var cross_off: f32 = 0;
                switch (e.style.align_items) {
                    .start => {},
                    .center => cross_off = @max(0, lc - cross_sz) / 2,
                    .end => cross_off = @max(0, lc - cross_sz),
                    .stretch => {
                        const cross_auto = switch (e.axis) {
                            .row => ch.h_mode != .fixed,
                            .col => ch.w_mode != .fixed,
                        };
                        if (cross_auto) {
                            const lo = switch (e.axis) {
                                .row => ch.style.min_height,
                                .col => ch.style.min_width,
                            };
                            const hi = switch (e.axis) {
                                .row => ch.style.max_height,
                                .col => ch.style.max_width,
                            };
                            cross_sz = clampF(lc, lo, hi);
                        }
                    },
                    .baseline => cross_off = @max(0, self.line_bl[li] - ch.baseline),
                }

                const nb: Rect = switch (e.axis) {
                    .row => .{ .x = main_cursor, .y = cross_cursor + cross_off, .w = main_sz, .h = cross_sz },
                    .col => .{ .x = cross_cursor + cross_off, .y = main_cursor, .w = cross_sz, .h = main_sz },
                };
                if (!nb.eql(ch.bounds)) {
                    ch.bounds = nb;
                    any_moved = true;
                }
                main_cursor += main_sz + gap + extra;
                work += 1;
            }
            cross_cursor += lc + gap;
        }

        self.stats.position += work;
        return any_moved;
    }

    fn positionAll(self: *Tree) void {
        const r = &self.els.items[self.root()];
        r.bounds = .{
            .x = 0,
            .y = 0,
            .w = if (r.w_mode == .fixed) r.fixed_w else self.viewport.w,
            .h = if (r.h_mode == .fixed) r.fixed_h else self.viewport.h,
        };
        for (self.pre.items) |idx| _ = self.positionChildren(idx);
    }

    fn repositionSubtree(self: *Tree, from: Index) void {
        self.stack[0] = from;
        self.drainReposition(1);
    }

    /// Repositions `start_child` and its later siblings, leaving earlier
    /// siblings alone.
    ///
    /// Valid only when the parent's children are a pure prefix scan, which with
    /// real flexbox needs FOUR conditions and not one:
    ///
    ///   - no flex-grow on the main axis, or one child's size changes others'
    ///   - no wrap, or a size change can move an item to another line
    ///   - justify-content at the start, or earlier siblings move too
    ///   - no overflow, so flex-shrink is not active
    ///
    /// The first three are static and cached in `simple_main`. The fourth is
    /// dynamic, and is why `sum_main` is maintained incrementally: it makes the
    /// overflow test O(1). Without that cache, `flex-shrink: 1` alone would
    /// force the slow path on every size change and this function would be dead
    /// code under CSS semantics.
    fn repositionFrom(self: *Tree, parent: Index, start_child: Index) void {
        const e = &self.els.items[parent];
        const pad = e.style.padding;
        const avail_main = switch (e.axis) {
            .row => @max(0, e.bounds.w - pad * 2),
            .col => @max(0, e.bounds.h - pad * 2),
        };
        if (!e.simple_main or (e.any_shrink_main and e.sum_main > avail_main)) {
            self.stats.slow_path += 1;
            self.repositionSubtree(parent);
            return;
        }
        self.stats.fast_path += 1;

        const inner_x = e.bounds.x + pad;
        const inner_y = e.bounds.y + pad;
        // The fast path only ever runs on a single non-wrapping line, so the
        // line's cross extent is the container's inner cross size; see the
        // same decision in `positionChildren`. This used to read
        // `@max(e.max_cross, avail_cross)` and had to match whatever that did.
        const lc = switch (e.axis) {
            .row => @max(0, e.bounds.h - pad * 2),
            .col => @max(0, e.bounds.w - pad * 2),
        };
        const gap = e.style.gap;

        var sp: usize = 0;
        var work: u32 = 0;
        var cursor: f32 = switch (e.axis) {
            .row => self.els.items[start_child].bounds.x,
            .col => self.els.items[start_child].bounds.y,
        };

        var c = start_child;
        while (c != none) : (c = self.els.items[c].next_sibling) {
            const ch = &self.els.items[c];
            const main_sz = self.hypoMain(c, e.axis);
            var cross_sz = self.hypoCross(c, e.axis);
            // Cross alignment must be applied here too. Omitting it and writing
            // the content edge unconditionally is a real bug: it left every
            // element on a centred row three pixels high, and the randomised
            // equivalence test is what found it where fixed cases did not.
            var cross_off: f32 = 0;
            switch (e.style.align_items) {
                .start => {},
                .center => cross_off = @max(0, lc - cross_sz) / 2,
                .end => cross_off = @max(0, lc - cross_sz),
                .stretch => {
                    const cross_auto = switch (e.axis) {
                        .row => ch.h_mode != .fixed,
                        .col => ch.w_mode != .fixed,
                    };
                    if (cross_auto) {
                        const lo = switch (e.axis) {
                            .row => ch.style.min_height,
                            .col => ch.style.min_width,
                        };
                        const hi = switch (e.axis) {
                            .row => ch.style.max_height,
                            .col => ch.style.max_width,
                        };
                        cross_sz = clampF(lc, lo, hi);
                    }
                },
                // Excluded from the fast path by `simple_main`.
                .baseline => unreachable,
            }

            const nb: Rect = switch (e.axis) {
                .row => .{ .x = cursor, .y = inner_y + cross_off, .w = main_sz, .h = cross_sz },
                .col => .{ .x = inner_x + cross_off, .y = cursor, .w = cross_sz, .h = main_sz },
            };
            work += 1;
            // The start child's own bounds may be unchanged while its children's
            // sizes are not, so it is always descended into. For later siblings,
            // landing where they already were means every later one does too.
            if (c != start_child and nb.eql(ch.bounds)) break;
            ch.bounds = nb;
            if (ch.first_child != none) {
                self.stack[sp] = c;
                sp += 1;
            }
            cursor += main_sz + gap;
        }
        self.stats.position += work;
        self.drainReposition(sp);
    }

    fn drainReposition(self: *Tree, seeded: usize) void {
        var sp = seeded;
        while (sp > 0) {
            sp -= 1;
            const idx = self.stack[sp];
            const moved = self.positionChildren(idx);
            var c = self.els.items[idx].first_child;
            while (c != none) : (c = self.els.items[c].next_sibling) {
                if (self.els.items[c].first_child == none) continue;
                // Descend where the child moved, OR where it carries a changed
                // intrinsic further down even though it did not move itself.
                // Gating on `moved` alone leaves descendants stale.
                if (moved or self.path_stamp[c] == self.frame_no) {
                    self.stack[sp] = c;
                    sp += 1;
                }
            }
        }
    }

    /// Applies one dirty element: recompute its own size, carry the change up
    /// while ancestors keep changing, then reposition from where the change
    /// stopped.
    fn flushElement(self: *Tree, el: Index) void {
        _ = self.recomputeIntrinsic(el);

        var child_on_path = el;
        var node = self.els.items[el].parent;
        while (node != none) {
            if (!self.recomputeIntrinsic(node)) break;
            child_on_path = node;
            node = self.els.items[node].parent;
        }

        // Stamp the chain so the drain can follow it through elements whose own
        // bounds happen not to move.
        self.frame_no +%= 1;
        if (self.frame_no == 0) {
            @memset(self.path_stamp, 0);
            self.frame_no = 1;
        }
        var m = el;
        while (m != none) : (m = self.els.items[m].parent) {
            self.path_stamp[m] = self.frame_no;
            if (node != none and m == node) break;
        }

        // The loop has two exits and they are NOT the same case.
        //
        //   break      -> `node` is an ancestor whose own size did not change,
        //                 so it stays put and only its children from
        //                 `child_on_path` onward need repositioning.
        //   node==none -> the change propagated out of the tree. There is no
        //                 parent to reposition from and `child_on_path` is the
        //                 root itself; feeding that to `repositionFrom` lays the
        //                 root out as its own child and adds its own padding to
        //                 its own origin.
        //
        // Collapsing them put the root at x=8 instead of x=0.
        if (node == none) {
            self.repositionSubtree(self.root());
        } else {
            // `recomputeIntrinsic(node)` already refreshed `sum_main` on the
            // way past, even though it reported no change of its own, so the
            // overflow test is current.
            self.repositionFrom(node, child_on_path);
        }
    }
};
