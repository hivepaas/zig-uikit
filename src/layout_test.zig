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
        const topo: topologies = @enumFromInt(seed % 4);

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
                .justify = @enumFromInt(r.uintLessThan(u8, 4)),
                .align_items = @enumFromInt(r.uintLessThan(u8, 5)),
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
