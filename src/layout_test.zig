//! The test that matters is `incremental layout == full recompute`, bit for
//! bit, and it is here because it has already earned its keep three times.
//!
//! In the benchmark repository it caught two fast-path bugs that each reported
//! themselves as a 2x speed-up (run 4), and one in the upward climb that laid
//! the root out as its own child (run 9). An incremental layout engine without
//! this comparison does not report bugs as bugs -- it reports them as
//! improvements, because skipping work it owed is indistinguishable from being
//! fast.

const std = @import("std");
const testing = std.testing;
const ui = @import("root.zig");

const Tree = ui.Tree;
const Style = ui.Style;
const Rect = ui.Rect;
const Index = ui.Index;

const viewport: ui.Size = .{ .w = 1000, .h = 600 };

/// Snapshots what the incremental path produced, recomputes everything from
/// scratch, and compares. Any divergence is a bug in the incremental path,
/// because the full path is the definition.
fn expectIncrementalMatchesFull(t: *Tree) !void {
    const n = t.count();
    const snap = try testing.allocator.alloc(Rect, n);
    defer testing.allocator.free(snap);
    var i: Index = 0;
    while (i < n) : (i += 1) snap[i] = t.bounds(i);

    t.layout(t.viewport);

    i = 0;
    var bad: u32 = 0;
    while (i < n) : (i += 1) {
        const got = t.bounds(i);
        if (!Rect.eql(snap[i], got)) {
            if (bad < 6) std.debug.print(
                "  element {d}: incremental {d},{d} {d}x{d} != full {d},{d} {d}x{d}\n",
                .{ i, snap[i].x, snap[i].y, snap[i].w, snap[i].h, got.x, got.y, got.w, got.h },
            );
            bad += 1;
        }
    }
    if (bad != 0) {
        std.debug.print("  {d} of {d} elements diverged\n", .{ bad, n });
        return error.IncrementalDivergedFromFull;
    }
}

// --------------------------------------------------------------- basic layout

test "an overflowing child does not enlarge its line" {
    // CSS 9.4 step 8: a single-line container's line cross size is the
    // container's inner cross size. Taking the maximum over the children
    // instead lets one overflowing child move every centred sibling, which is
    // what a popover anchor did to a toolbar row in `tools/demo.zig`.
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const row = try t.appendChild(t.root(), .{
        .axis = .row,
        .height = .{ .fixed = 28 },
        .flex_shrink = 0,
        .padding = 7,
        .gap = 8,
        .align_items = .center,
    });
    const icon = try t.appendChild(row, .{
        .width = .{ .fixed = 14 },
        .height = .{ .fixed = 14 },
        .flex_shrink = 0,
    });
    // Four times taller than the row's inner box, and invisible.
    const anchor = try t.appendChild(row, .{
        .width = .{ .fixed = 0 },
        .height = .{ .fixed = 56 },
        .flex_shrink = 0,
    });
    t.layout(viewport);

    // The icon exactly fills the row's 14-pixel inner height, so centring puts
    // it at the padding edge and nowhere else.
    try testing.expectEqual(@as(f32, 7), t.bounds(icon).y);
    try testing.expectEqual(@as(f32, 7), t.bounds(anchor).y);
    try testing.expectEqual(@as(f32, 28), t.bounds(row).h);
}

test "a column stacks children and sums their heights" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{ .axis = .col, .padding = 10, .gap = 5 });
    const a = try t.appendChild(t.root(), .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 20 } });
    const b = try t.appendChild(t.root(), .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 30 } });
    t.layout(viewport);

    try testing.expectEqual(@as(f32, 10), t.bounds(a).y);
    try testing.expectEqual(@as(f32, 35), t.bounds(b).y); // 10 pad + 20 + 5 gap
    try testing.expectEqual(@as(f32, 20), t.bounds(a).h);
}

test "grow splits the free space by factor" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{ .axis = .row, .width = .{ .fixed = 300 }, .height = .{ .fixed = 50 } });
    const a = try t.appendChild(t.root(), .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } });
    const b = try t.appendChild(t.root(), .{ .width = .{ .grow = 2 }, .height = .{ .fixed = 10 } });
    t.layout(viewport);

    try testing.expectEqual(@as(f32, 100), t.bounds(a).w);
    try testing.expectEqual(@as(f32, 200), t.bounds(b).w);
}

test "an overflowing line shrinks every item, weighted by size" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{ .axis = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 50 } });
    // 60 + 60 = 120 into 100: 20 to give back, weighted by flex_shrink x base,
    // which is equal here, so 10 each.
    const a = try t.appendChild(t.root(), .{ .width = .{ .fixed = 60 }, .height = .{ .fixed = 10 } });
    const b = try t.appendChild(t.root(), .{ .width = .{ .fixed = 60 }, .height = .{ .fixed = 10 } });
    t.layout(viewport);

    try testing.expectEqual(@as(f32, 50), t.bounds(a).w);
    try testing.expectEqual(@as(f32, 50), t.bounds(b).w);
}

test "flex_shrink 0 opts out of shrinking" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{ .axis = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 50 } });
    const fixedk = try t.appendChild(t.root(), .{
        .width = .{ .fixed = 60 },
        .height = .{ .fixed = 10 },
        .flex_shrink = 0,
    });
    const squeezed = try t.appendChild(t.root(), .{ .width = .{ .fixed = 60 }, .height = .{ .fixed = 10 } });
    t.layout(viewport);

    try testing.expectEqual(@as(f32, 60), t.bounds(fixedk).w);
    try testing.expectEqual(@as(f32, 40), t.bounds(squeezed).w);
}

test "a minimum stops the shrink and the freeze loop redistributes" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{ .axis = .row, .width = .{ .fixed = 100 }, .height = .{ .fixed = 50 } });
    const floored = try t.appendChild(t.root(), .{
        .width = .{ .fixed = 60 },
        .height = .{ .fixed = 10 },
        .min_width = 55,
    });
    const rest = try t.appendChild(t.root(), .{ .width = .{ .fixed = 60 }, .height = .{ .fixed = 10 } });
    t.layout(viewport);

    try testing.expectEqual(@as(f32, 55), t.bounds(floored).w);
    // The 5 px the floored item refused is taken from the other one, which is
    // the pass the freeze loop exists for.
    try testing.expectEqual(@as(f32, 45), t.bounds(rest).w);
}

test "justify space_between pushes the ends apart" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{
        .axis = .row,
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 50 },
        .justify = .space_between,
    });
    const a = try t.appendChild(t.root(), .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 10 } });
    const b = try t.appendChild(t.root(), .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 10 } });
    t.layout(viewport);

    try testing.expectEqual(@as(f32, 0), t.bounds(a).x);
    try testing.expectEqual(@as(f32, 180), t.bounds(b).x);
}

test "align center and stretch across the axis" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{
        .axis = .row,
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 100 },
        .align_items = .center,
    });
    const a = try t.appendChild(t.root(), .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 40 } });
    t.layout(viewport);
    try testing.expectEqual(@as(f32, 30), t.bounds(a).y); // (100 - 40) / 2

    try t.setStyle(t.root(), .{
        .axis = .row,
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 100 },
        .align_items = .stretch,
    });
    _ = t.flush();
    const b = try t.appendChild(t.root(), .{ .width = .{ .fixed = 20 } });
    t.layout(viewport);
    try testing.expectEqual(@as(f32, 100), t.bounds(b).h);
}

test "wrap breaks lines and needs a definite cross size" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{
        .axis = .row,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 100 },
        .wrap = true,
    });
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        _ = try t.appendChild(t.root(), .{
            .width = .{ .fixed = 60 },
            .height = .{ .fixed = 20 },
            .flex_shrink = 0,
        });
    }
    t.layout(viewport);
    // 60 + 60 does not fit in 100, so the second item starts a new line.
    try testing.expectEqual(@as(f32, 0), t.bounds(1).y);
    try testing.expect(t.bounds(2).y > 0);

    // A wrapping container with a content-sized cross axis is rejected rather
    // than laid out wrongly; a correct answer needs a second pass.
    try testing.expectError(
        ui.Error.WrapNeedsDefiniteCrossSize,
        t.setStyle(t.root(), .{ .axis = .row, .width = .{ .fixed = 100 }, .wrap = true }),
    );
}

test "baseline alignment lines up the text baselines" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{
        .axis = .row,
        .width = .{ .fixed = 300 },
        .height = .{ .fixed = 100 },
        .align_items = .baseline,
    });
    const small = try t.appendChild(t.root(), .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } });
    const big = try t.appendChild(t.root(), .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 50 } });
    t.layout(viewport);

    // Leaf baselines sit at 80% of the height: 16 and 40. The deeper baseline
    // wins, so the small box is pushed down by the difference.
    try testing.expectEqual(@as(f32, 0), t.bounds(big).y);
    try testing.expectEqual(@as(f32, 24), t.bounds(small).y);
}

// ------------------------------------------------------- incremental behaviour

test "an unchanged frame does no work at all" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        _ = try t.appendChild(t.root(), .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    }
    t.layout(viewport);

    const s = t.flush();
    try testing.expectEqual(@as(u32, 0), s.total());
    try testing.expectEqual(@as(u32, 0), s.full_layouts);
}

test "re-setting an identical style dirties nothing" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const a = try t.appendChild(t.root(), .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    t.layout(viewport);

    // A declarative layer on top re-sets every style every frame. If that
    // dirtied the tree, this design would collapse into the view-level one.
    try t.setStyle(a, .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    try testing.expectEqual(@as(u32, 0), t.flush().total());
}

test "resizing a leaf does not trigger a full layout" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{ .axis = .col, .width = .{ .fixed = 400 }, .height = .{ .fixed = 400 } });
    var leaves: [20]Index = undefined;
    for (&leaves) |*l| {
        l.* = try t.appendChild(t.root(), .{
            .width = .{ .fixed = 50 },
            .height = .{ .fixed = 10 },
            .flex_shrink = 0,
        });
    }
    t.layout(viewport);

    try t.setStyle(leaves[10], .{
        .width = .{ .fixed = 50 },
        .height = .{ .fixed = 14 },
        .flex_shrink = 0,
    });
    const s = t.flush();

    try testing.expectEqual(@as(u32, 0), s.full_layouts);
    try testing.expect(s.fast_path > 0);
    // Only the changed leaf and its later siblings move, not all 20.
    try testing.expect(s.position < 20);
    try expectIncrementalMatchesFull(&t);
}

test "an overflowing container falls back to the slow path, and is still correct" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{ .axis = .col, .width = .{ .fixed = 100 }, .height = .{ .fixed = 50 } });
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        _ = try t.appendChild(t.root(), .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 20 } });
    }
    t.layout(viewport);

    // 10 x 20 = 200 into 50: the line overflows, so flex-shrink couples every
    // sibling and the prefix scan is invalid.
    try t.setStyle(5, .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 24 } });
    const s = t.flush();
    try testing.expect(s.slow_path > 0);
    try expectIncrementalMatchesFull(&t);
}

test "a change that reaches the root does not lay the root out as its own child" {
    // The run 9 bug: both exits of the upward climb were collapsed into one,
    // and the root came out at x = padding instead of x = 0.
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{ .axis = .col, .padding = 8, .gap = 4 });
    const mid = try t.appendChild(t.root(), .{ .axis = .col, .padding = 3 });
    const leaf = try t.appendChild(mid, .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } });
    t.layout(viewport);

    try t.setStyle(leaf, .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 60 } });
    _ = t.flush();

    try testing.expectEqual(@as(f32, 0), t.bounds(t.root()).x);
    try testing.expectEqual(@as(f32, 0), t.bounds(t.root()).y);
    try expectIncrementalMatchesFull(&t);
}

test "a deep chain lays out iteratively, without recursing" {
    // GPUI needs `stacker` to grow the stack past roughly 384-512 nested
    // elements. This engine uses an explicit work stack, so depth is bounded by
    // the scratch array rather than by the thread stack.
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{ .axis = .col, .width = .{ .fixed = 500 }, .height = .{ .fixed = 500 } });
    var parent = t.root();
    var i: u32 = 0;
    while (i < 2000) : (i += 1) {
        parent = try t.appendChild(parent, .{ .axis = .col, .padding = 0 });
    }
    const leaf = try t.appendChild(parent, .{ .width = .{ .fixed = 5 }, .height = .{ .fixed = 5 } });
    t.layout(viewport);
    try testing.expectEqual(@as(f32, 5), t.bounds(leaf).h);

    try t.setStyle(leaf, .{ .width = .{ .fixed = 5 }, .height = .{ .fixed = 9 } });
    _ = t.flush();
    try expectIncrementalMatchesFull(&t);
}

test "hit testing finds the deepest element under a point" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{ .axis = .col, .width = .{ .fixed = 200 }, .height = .{ .fixed = 200 } });
    const outer = try t.appendChild(t.root(), .{
        .axis = .col,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 100 },
        .padding = 10,
    });
    const inner = try t.appendChild(outer, .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } });
    t.layout(viewport);

    try testing.expectEqual(inner, t.hitTest(.{ .x = 15, .y = 15 }));
    try testing.expectEqual(outer, t.hitTest(.{ .x = 95, .y = 95 }));
    try testing.expectEqual(t.root(), t.hitTest(.{ .x = 150, .y = 150 }));
}

// ----------------------------------------------- randomised equivalence sweep

// The test that found the real bugs. Builds random trees, makes random style
// changes, and demands the incremental result match a full recompute exactly.
// Shapes mirror the benchmark's topologies, because those are the ones whose
// behaviour is characterised.
test "randomised: incremental always matches full" {
    const topologies = enum { wide, deep, mixed, narrow };
    var seed: u64 = 0;
    while (seed < 24) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        const topo: topologies = @fromBackingInt(@intCast(seed % 4));

        var t = try Tree.init(testing.allocator);
        defer t.deinit();
        try t.setStyle(t.root(), .{
            .axis = .col,
            .width = .{ .fixed = 1000 },
            .height = .{ .fixed = 600 },
            .padding = 8,
            .gap = 4,
        });

        const n: u32 = 40 + r.uintLessThan(u32, 60);
        var last: Index = t.root();
        var leaves: std.ArrayList(Index) = .empty;
        defer leaves.deinit(testing.allocator);

        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const parent: Index = switch (topo) {
                .wide => t.root(),
                .deep => last,
                .mixed => r.uintLessThan(Index, @intCast(t.count())),
                .narrow => if (r.uintLessThan(u8, 5) == 0) t.root() else last,
            };
            const leafish = r.uintLessThan(u8, 3) == 0;
            const s: Style = .{
                .axis = if (r.boolean()) .row else .col,
                .width = if (leafish)
                    .{ .fixed = @floatFromInt(8 + r.uintLessThan(u32, 60)) }
                else
                    .{ .grow = 1 },
                .height = if (leafish)
                    .{ .fixed = @floatFromInt(8 + r.uintLessThan(u32, 24)) }
                else
                    .content,
                .min_width = if (r.uintLessThan(u32, 4) == 0) 6 else 0,
                .max_width = if (r.uintLessThan(u32, 6) == 0) 48 else std.math.floatMax(f32),
                .flex_shrink = if (r.uintLessThan(u32, 3) == 0) 0 else 1,
                .padding = @floatFromInt(r.uintLessThan(u32, 5)),
                .gap = @floatFromInt(r.uintLessThan(u32, 4)),
                .justify = @fromBackingInt(@intCast(r.uintLessThan(u8, 4))),
                .align_items = @fromBackingInt(@intCast(r.uintLessThan(u8, 5))),
            };
            const el = try t.appendChild(parent, s);
            if (leafish) try leaves.append(testing.allocator, el);
            last = el;
        }

        t.layout(viewport);
        if (leaves.items.len == 0) continue;

        // A run of incremental changes, each verified against a full recompute,
        // so a bug cannot hide behind a later full layout.
        var round: u32 = 0;
        while (round < 6) : (round += 1) {
            const el = leaves.items[r.uintLessThan(usize, leaves.items.len)];
            var s = t.style(el);
            // Only the LENGTH changes; the mode and factors stay put, which is
            // the incremental path rather than the structural one.
            s.width = .{ .fixed = @floatFromInt(8 + r.uintLessThan(u32, 60)) };
            s.height = .{ .fixed = @floatFromInt(8 + r.uintLessThan(u32, 24)) };
            try t.setStyle(el, s);
            const st = t.flush();
            try testing.expectEqual(@as(u32, 0), st.full_layouts);
            expectIncrementalMatchesFull(&t) catch |err| {
                std.debug.print(
                    "  seed {d} topo {s} round {d} element {d}\n",
                    .{ seed, @tagName(topo), round, el },
                );
                return err;
            };
        }
    }
}

test "randomised: binary-search hit testing matches scanning every child" {
    // `hitChild` binary searches on the claim that a non-wrapping container's
    // children occupy increasing, non-overlapping ranges along its main axis.
    // That is a property of how `positionChildren` places them, not something
    // the type system enforces, so it is checked against the definition it
    // replaced -- on trees that include wrapping containers, overflowing lines,
    // zero-sized children and every alignment, because those are the cases
    // where the claim could fail.
    var seed: u64 = 0;
    while (seed < 40) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const rnd = prng.random();

        var t = try Tree.init(testing.allocator);
        defer t.deinit();

        const wide = seed % 2 == 0;
        try t.setStyle(t.root(), .{
            .axis = if (rnd.boolean()) .row else .col,
            .padding = @floatFromInt(rnd.intRangeAtMost(u32, 0, 12)),
            .gap = @floatFromInt(rnd.intRangeAtMost(u32, 0, 8)),
            .align_items = randomAlign(rnd),
            .justify = randomJustify(rnd),
        });

        var parents: [64]Index = undefined;
        var n_parents: usize = 1;
        parents[0] = t.root();

        const count: usize = if (wide) 220 else 70;
        for (0..count) |_| {
            const parent = parents[rnd.uintLessThan(usize, n_parents)];
            const wrap = rnd.uintLessThan(u32, 8) == 0;
            const style: ui.Style = .{
                .axis = if (rnd.boolean()) .row else .col,
                // A wrapping container needs a definite cross size.
                .width = if (wrap or rnd.boolean())
                    .{ .fixed = @floatFromInt(rnd.intRangeAtMost(u32, 0, 90)) }
                else
                    .content,
                .height = if (wrap or rnd.boolean())
                    .{ .fixed = @floatFromInt(rnd.intRangeAtMost(u32, 0, 70)) }
                else
                    .content,
                // Zero shrink makes lines overflow, which is where the
                // monotonicity claim is least obvious.
                .flex_shrink = if (rnd.boolean()) 0 else 1,
                .padding = @floatFromInt(rnd.intRangeAtMost(u32, 0, 6)),
                .gap = @floatFromInt(rnd.intRangeAtMost(u32, 0, 6)),
                .wrap = wrap,
                .align_items = randomAlign(rnd),
                .justify = randomJustify(rnd),
            };
            const e = try t.appendChild(parent, style);
            // Biased towards wide containers on even seeds, so the binary
            // search path (eight children or more) is actually taken.
            if (!wide and n_parents < parents.len and rnd.uintLessThan(u32, 3) == 0) {
                parents[n_parents] = e;
                n_parents += 1;
            }
        }
        t.layout(viewport);

        // Without this the test could pass by never taking the binary search
        // at all: containers with fewer than eight children are scanned.
        var widest: usize = 0;
        var e: Index = 0;
        while (e < t.count()) : (e += 1) widest = @max(widest, t.childrenOf(e).len);
        if (wide) try testing.expect(widest >= 8);

        var probe: u32 = 0;
        while (probe < 400) : (probe += 1) {
            const p: ui.Point = .{
                .x = @as(f32, @floatFromInt(rnd.intRangeAtMost(i32, -20, 1020))) + 0.5,
                .y = @as(f32, @floatFromInt(rnd.intRangeAtMost(i32, -20, 620))) + 0.5,
            };
            const fast = t.hitTest(p);
            const slow = t.hitTestLinear(p);
            if (fast != slow) {
                std.debug.print(
                    "  seed {d}: point {d},{d} -> binary search {d}, scan {d}\n",
                    .{ seed, p.x, p.y, fast, slow },
                );
                return error.HitTestDiverged;
            }
        }
    }
}

fn randomAlign(rnd: std.Random) ui.AlignItems {
    return switch (rnd.uintLessThan(u32, 5)) {
        0 => .start,
        1 => .center,
        2 => .end,
        3 => .stretch,
        else => .baseline,
    };
}

fn randomJustify(rnd: std.Random) ui.Justify {
    return switch (rnd.uintLessThan(u32, 4)) {
        0 => .start,
        1 => .center,
        2 => .end,
        else => .space_between,
    };
}

// ------------------------------------------------------- out-of-flow children
//
// `position: .absolute` exists to delete a trick, and these pin both halves of
// it: that an out-of-flow child is placed where it says and that it is
// invisible to everything else. The second half is the one that is easy to
// half-implement -- a popover that quietly enlarges the toolbar it hangs off
// is no better than the zero-width anchor it replaces.

test "an out-of-flow child does not change its parent's content size" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{ .axis = .row, .padding = 10 });

    const row = try t.appendChild(t.root(), .{ .axis = .row, .gap = 4, .padding = 6 });
    _ = try t.appendChild(row, .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } });
    _ = try t.appendChild(row, .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 20 } });
    t.layout(viewport);
    const before = t.bounds(row);

    // Much larger than the row, and out of flow.
    _ = try t.appendChild(row, .{
        .position = .absolute,
        .left = 4,
        .top = 2,
        .width = .{ .fixed = 400 },
        .height = .{ .fixed = 300 },
    });
    t.layout(viewport);

    try testing.expectEqual(before.w, t.bounds(row).w);
    try testing.expectEqual(before.h, t.bounds(row).h);
}

test "an out-of-flow child is placed from the parent's content origin" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const panel = try t.appendChild(t.root(), .{
        .axis = .col,
        .padding = 8,
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 100 },
    });
    const box = try t.appendChild(panel, .{
        .position = .absolute,
        .left = 30,
        .top = 5,
        .width = .{ .fixed = 12 },
        .height = .{ .fixed = 3 },
    });
    t.layout(viewport);

    const p = t.bounds(panel);
    const b = t.bounds(box);
    // Content origin, so the parent's padding counts once and the offsets are
    // measured from inside it.
    try testing.expectEqual(p.x + 8 + 30, b.x);
    try testing.expectEqual(p.y + 8 + 5, b.y);
    try testing.expectEqual(@as(f32, 12), b.w);
    try testing.expectEqual(@as(f32, 3), b.h);
}

test "flow siblings are laid out as if it were not there" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();

    // The same row twice, once with an out-of-flow child in the middle of the
    // sibling list and once without, and every flow child must land in the
    // same place.
    const plain = try t.appendChild(t.root(), .{ .axis = .row, .gap = 5 });
    const a1 = try t.appendChild(plain, .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    const b1 = try t.appendChild(plain, .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });

    const mixed = try t.appendChild(t.root(), .{ .axis = .row, .gap = 5 });
    const a2 = try t.appendChild(mixed, .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    _ = try t.appendChild(mixed, .{
        .position = .absolute,
        .left = 100,
        .width = .{ .fixed = 50 },
        .height = .{ .fixed = 50 },
    });
    const b2 = try t.appendChild(mixed, .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    t.layout(viewport);

    try testing.expectEqual(t.bounds(a1).x - t.bounds(plain).x, t.bounds(a2).x - t.bounds(mixed).x);
    try testing.expectEqual(t.bounds(b1).x - t.bounds(plain).x, t.bounds(b2).x - t.bounds(mixed).x);
}

test "out of flow, grow fills what is left after the offset" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const panel = try t.appendChild(t.root(), .{
        .padding = 4,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 60 },
    });
    const fill = try t.appendChild(panel, .{
        .position = .absolute,
        .left = 20,
        .top = 10,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
    });
    t.layout(viewport);

    // The content box is 92x52; from (20, 10) that leaves 72x42.
    try testing.expectEqual(@as(f32, 72), t.bounds(fill).w);
    try testing.expectEqual(@as(f32, 42), t.bounds(fill).h);
}

test "an out-of-flow child is not centred by its parent's alignment" {
    // Worth pinning because it is a difference callers have to know about: a
    // row that centres its children does not centre this one, and whatever
    // places it has to say where it goes. That is what "out of flow" means,
    // and the demo's overlays compute the offset for exactly this reason.
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const row = try t.appendChild(t.root(), .{
        .axis = .row,
        .align_items = .center,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 40 },
    });
    const box = try t.appendChild(row, .{
        .position = .absolute,
        .width = .{ .fixed = 10 },
        .height = .{ .fixed = 10 },
    });
    t.layout(viewport);
    try testing.expectEqual(t.bounds(row).y, t.bounds(box).y);
}

test "moving an out-of-flow child costs one element and no sibling moves" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const field = try t.appendChild(t.root(), .{
        .axis = .row,
        .padding = 8,
        .gap = 4,
        .width = .{ .fixed = 300 },
        .height = .{ .fixed = 34 },
    });
    const caret = try t.appendChild(field, .{
        .position = .absolute,
        .left = 0,
        .width = .{ .fixed = 1 },
        .height = .{ .fixed = 18 },
    });
    const label = try t.appendChild(field, .{ .width = .{ .fixed = 120 }, .height = .{ .fixed = 18 } });
    t.layout(viewport);

    const label_was = t.bounds(label);
    const field_was = t.bounds(field);

    var s = t.style(caret);
    s.left = 77;
    try t.setStyle(caret, s);
    const stats = t.flush();

    try testing.expectEqual(field_was.x + 8 + 77, t.bounds(caret).x);
    // Nothing else moved, and nothing was laid out the slow way.
    try testing.expect(Rect.eql(label_was, t.bounds(label)));
    try testing.expect(Rect.eql(field_was, t.bounds(field)));
    try testing.expectEqual(@as(u32, 0), stats.slow_path);
    try testing.expectEqual(@as(u32, 0), stats.full_layouts);
    // One element recomputed, one placed. A spacer standing in for the same x
    // coordinate was a size change that climbed to the row and re-ran it.
    try testing.expect(stats.total() <= 3);

    try expectIncrementalMatchesFull(&t);
}

test "a subtree under an out-of-flow element moves with it" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const panel = try t.appendChild(t.root(), .{
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 200 },
    });
    const popover = try t.appendChild(panel, .{
        .axis = .col,
        .position = .absolute,
        .left = 10,
        .top = 10,
        .padding = 6,
        .width = .{ .fixed = 80 },
        .height = .{ .fixed = 50 },
    });
    const inside = try t.appendChild(popover, .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } });
    t.layout(viewport);
    const inside_was = t.bounds(inside);

    var s = t.style(popover);
    s.left = 60;
    s.top = 40;
    try t.setStyle(popover, s);
    _ = t.flush();

    try testing.expectEqual(inside_was.x + 50, t.bounds(inside).x);
    try testing.expectEqual(inside_was.y + 30, t.bounds(inside).y);
    try expectIncrementalMatchesFull(&t);
}

test "a container whose only children are out of flow still sizes from its own rules" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const content = try t.appendChild(t.root(), .{ .width = .{ .fixed = 50 }, .height = .{ .fixed = 50 } });
    _ = content;
    const only_abs = try t.appendChild(t.root(), .{ .padding = 3 });
    const box = try t.appendChild(only_abs, .{
        .position = .absolute,
        .left = 1,
        .top = 2,
        .width = .{ .fixed = 9 },
        .height = .{ .fixed = 9 },
    });
    t.layout(viewport);

    // Content-sized with no flow children, so it is just its padding.
    try testing.expectEqual(@as(f32, 6), t.bounds(only_abs).w);
    try testing.expectEqual(@as(f32, 6), t.bounds(only_abs).h);
    // And the out-of-flow child is still placed, overflowing it.
    try testing.expectEqual(t.bounds(only_abs).x + 3 + 1, t.bounds(box).x);
}

test "an out-of-flow child is clamped by its own min and max" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const panel = try t.appendChild(t.root(), .{
        .padding = 2,
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 200 },
    });
    const box = try t.appendChild(panel, .{
        .position = .absolute,
        .width = .{ .grow = 1 },
        .height = .{ .fixed = 5 },
        .max_width = 40,
        .min_height = 20,
    });
    t.layout(viewport);
    try testing.expectEqual(@as(f32, 40), t.bounds(box).w);
    try testing.expectEqual(@as(f32, 20), t.bounds(box).h);
}

test "incremental and full agree with out-of-flow children in the tree" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{ .axis = .col, .padding = 7, .gap = 3, .align_items = .stretch });

    var rows: [6]Index = undefined;
    for (&rows, 0..) |*r, i| {
        r.* = try t.appendChild(t.root(), .{
            .axis = .row,
            .height = .{ .fixed = 20 + @as(f32, @floatFromInt(i)) },
            .gap = 2,
            .padding = 1,
            .flex_shrink = 0,
        });
        _ = try t.appendChild(r.*, .{
            .position = .absolute,
            .left = @floatFromInt(i * 3),
            .top = 1,
            .width = .{ .fixed = 2 },
            .height = .{ .fixed = 4 },
        });
        _ = try t.appendChild(r.*, .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 10 } });
        _ = try t.appendChild(r.*, .{ .width = .{ .fixed = 15 }, .height = .{ .fixed = 10 } });
    }
    t.layout(viewport);

    // A mix of changes: an out-of-flow move, a flow size change, and both in
    // one flush.
    var s0 = t.style(t.firstChild(rows[1]));
    s0.left = 44;
    try t.setStyle(t.firstChild(rows[1]), s0);

    var s1 = t.style(rows[3]);
    s1.height = .{ .fixed = 31 };
    try t.setStyle(rows[3], s1);
    _ = t.flush();

    try expectIncrementalMatchesFull(&t);
}

test "a wrapped paragraph is given a box as tall as its lines" {
    // The bug this pins: `setText` used to rebuild the run field by field and
    // drop the two a wrapped paragraph carries, so a two-line paragraph got a
    // one-line box and whatever came after it was laid out on top.
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const col = try t.appendChild(t.root(), .{ .axis = .col });
    const para = try t.appendChild(col, .{ .flex_shrink = 0 });
    const after = try t.appendChild(col, .{
        .width = .{ .fixed = 10 },
        .height = .{ .fixed = 10 },
        .flex_shrink = 0,
    });

    // Three lines, stacked at 20, with an ascent of 16 and a descent of 4.
    var glyphs = [_]ui.Glyph{.{
        .dx = 0,
        .dy = 0,
        .w = 5,
        .h = 5,
        .u0 = 0,
        .v0 = 0,
        .u1 = 1,
        .v1 = 1,
        .cluster = 0,
        .pen_x = 0,
    }};
    try t.setText(para, .{
        .glyphs = &glyphs,
        .width = 100,
        .ascent = 16,
        .descent = 4,
        .lines = 3,
        .line_height = 20,
    });
    t.layout(viewport);

    // 20 + 20 for the first two lines, then ascent plus descent for the last.
    try testing.expectEqual(@as(f32, 60), t.bounds(para).h);
    // And the element after it starts below, not over it.
    try testing.expectEqual(t.bounds(para).y + 60, t.bounds(after).y);

    // The run survived the copy intact, which is the part that broke.
    try testing.expectEqual(@as(u32, 3), t.text(para).lines);
    try testing.expectEqual(@as(f32, 20), t.text(para).line_height);
}

// ------------------------------------------------------------------ scrolling

fn scrollBox(t: *Tree, rows: usize, row_h: f32) !Index {
    const box = try t.appendChild(t.root(), .{
        .axis = .col,
        .padding = 4,
        .gap = 2,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 50 },
        .flex_shrink = 0,
        .align_items = .stretch,
    });
    for (0..rows) |_| {
        _ = try t.appendChild(box, .{ .height = .{ .fixed = row_h }, .flex_shrink = 0 });
    }
    return box;
}

test "scrolling moves the content and not the box" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const box = try scrollBox(&t, 10, 20);
    t.layout(viewport);

    const box_was = t.bounds(box);
    const first = t.firstChild(box);
    const first_was = t.bounds(first);

    const moved = try t.scrollBy(box, 0, 30);
    _ = t.flush();

    try testing.expectEqual(@as(f32, 30), moved.y);
    try testing.expect(Rect.eql(box_was, t.bounds(box)));
    try testing.expectEqual(first_was.y - 30, t.bounds(first).y);
    // The space the children are given does not change: scrolling moves the
    // content, it does not make the box bigger or smaller.
    try testing.expectEqual(first_was.w, t.bounds(first).w);

    try expectIncrementalMatchesFull(&t);
}

test "a scroll clamps to the content and reports what it did" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    // Ten rows of 20 with a gap of 2 is 218 of content in a 42-unit viewport.
    const box = try scrollBox(&t, 10, 20);
    t.layout(viewport);

    try testing.expectEqual(@as(f32, 218), t.scrollExtent(box).h);

    // Past the end clamps, and the return value says how far it really went.
    const far = try t.scrollBy(box, 0, 1000);
    _ = t.flush();
    try testing.expectEqual(@as(f32, 218 - 42), far.y);

    // At the end, another scroll does nothing and says so -- which is how a
    // caller knows to let the wheel through to whatever is behind.
    const none_left = try t.scrollBy(box, 0, 10);
    try testing.expectEqual(@as(f32, 0), none_left.y);

    // And back up clamps at zero.
    const up = try t.scrollBy(box, 0, -1000);
    _ = t.flush();
    try testing.expectEqual(-(218 - 42), up.y);
    try testing.expectEqual(@as(f32, 0), t.style(box).scroll_y);
}

test "content that fits does not scroll at all" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const box = try scrollBox(&t, 1, 10);
    t.layout(viewport);
    const moved = try t.scrollBy(box, 0, 50);
    try testing.expectEqual(@as(f32, 0), moved.y);
}

test "scrolling costs one subtree and nothing above it" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const outer = try t.appendChild(t.root(), .{ .axis = .col, .gap = 5, .align_items = .stretch });
    const box = try t.appendChild(outer, .{
        .axis = .col,
        .padding = 4,
        .width = .{ .fixed = 100 },
        .height = .{ .fixed = 50 },
        .flex_shrink = 0,
        .align_items = .stretch,
    });
    for (0..10) |_| _ = try t.appendChild(box, .{ .height = .{ .fixed = 20 }, .flex_shrink = 0 });
    const after = try t.appendChild(outer, .{ .height = .{ .fixed = 10 }, .flex_shrink = 0 });
    t.layout(viewport);

    const outer_was = t.bounds(outer);
    const after_was = t.bounds(after);
    _ = try t.scrollBy(box, 0, 20);
    const stats = t.flush();

    // Nothing above the box moved, and no full layout ran: a scroll is a
    // reposition of one subtree, which is the claim worth having.
    try testing.expect(Rect.eql(outer_was, t.bounds(outer)));
    try testing.expect(Rect.eql(after_was, t.bounds(after)));
    try testing.expectEqual(@as(u32, 0), stats.full_layouts);
    try expectIncrementalMatchesFull(&t);
}

test "an out-of-flow child scrolls with the content" {
    // A popover anchored to a row inside a scroll box has to follow the row.
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const box = try scrollBox(&t, 5, 20);
    const pop = try t.appendChild(box, .{
        .position = .absolute,
        .left = 3,
        .top = 60,
        .width = .{ .fixed = 20 },
        .height = .{ .fixed = 20 },
    });
    t.layout(viewport);
    const was = t.bounds(pop);

    _ = try t.scrollBy(box, 0, 25);
    _ = t.flush();
    try testing.expectEqual(was.y - 25, t.bounds(pop).y);
    try expectIncrementalMatchesFull(&t);
}

test "hit testing follows the scrolled content" {
    // The reason the offset is in layout and not in the scene builder: the
    // bounds are what hit testing and a screen reader's extents both read, so
    // there is one answer to where a row is and not two.
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const box = try scrollBox(&t, 10, 20);
    t.layout(viewport);

    const b = t.bounds(box);
    const probe: ui.Point = .{ .x = b.x + 10, .y = b.y + 10 };
    const before = t.hitTest(probe);
    _ = try t.scrollBy(box, 0, 44);
    _ = t.flush();
    const after = t.hitTest(probe);
    try testing.expect(before != after);
    try testing.expect(after != 0);
}

test "the wheel finds the innermost box that has anything to scroll" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    // A panel that overflows, holding a list that overflows, holding rows
    // that do not.
    const panel = try t.appendChild(t.root(), .{
        .axis = .col,
        .width = .{ .fixed = 200 },
        .height = .{ .fixed = 60 },
        .flex_shrink = 0,
        .align_items = .stretch,
    });
    const list = try t.appendChild(panel, .{
        .axis = .col,
        .height = .{ .fixed = 40 },
        .flex_shrink = 0,
        .align_items = .stretch,
    });
    var rows: [6]Index = undefined;
    for (&rows) |*r| {
        r.* = try t.appendChild(list, .{ .height = .{ .fixed = 15 }, .flex_shrink = 0 });
    }
    // Enough after the list to overflow the panel too.
    _ = try t.appendChild(panel, .{ .height = .{ .fixed = 80 }, .flex_shrink = 0 });
    t.layout(viewport);

    // Over a row: the row has nothing to scroll, the list does.
    const in_list = t.bounds(rows[0]);
    try testing.expectEqual(list, t.scrollTargetAt(.{ .x = in_list.x + 2, .y = in_list.y + 2 }));

    // Over the panel below the list: the panel.
    const below = t.bounds(panel);
    try testing.expectEqual(panel, t.scrollTargetAt(.{ .x = below.x + 2, .y = below.y + 50 }));

    // Once the list is at its end it still owns the wheel -- deciding to pass
    // it on is the caller's, from what `scrollBy` reports.
    _ = try t.scrollBy(list, 0, 1000);
    _ = t.flush();
    try testing.expectEqual(list, t.scrollTargetAt(.{ .x = in_list.x + 2, .y = in_list.y + 2 }));
    const none_left = try t.scrollBy(list, 0, 10);
    try testing.expectEqual(@as(f32, 0), none_left.y);

    // And nowhere over nothing.
    try testing.expectEqual(@as(Index, 0), t.scrollTargetAt(.{ .x = 900, .y = 500 }));
}
