//! What the layout core and the scene layer cost, measured on this library.
//!
//! This matters because of what has NOT been measured before. Runs 2 through 9
//! of the benchmark repository measured a prototype -- `incremental_flex.zig`
//! -- and the headline figure the whole project rests on (an unchanged frame at
//! ~15 ns and zero allocations, against ~2.32 ms of CPU for a view-level
//! toolkit) is a figure for that prototype, not for the code shipped here. The
//! library was written from the prototype's lessons but is not the same code:
//! it has a separate paint channel, text as a layout input, and a correctness
//! fix (CSS 9.4 step 8) the prototype still does not have.
//!
//! So the numbers below either reproduce the claim on the real implementation
//! or do not. The comparison baselines, all from the benchmark repository at
//! 1649 elements on the same machine, are printed alongside.
//!
//! Build with `-Doptimize=ReleaseFast`. A debug build says so and its numbers
//! mean nothing.

const std = @import("std");
const builtin = @import("builtin");
const ui = @import("zig-uikit");
const text = @import("zig-uikit-text");

const Tree = ui.Tree;
const Color = ui.Color;
const Index = ui.Index;

/// Eight columns of fifty-one rows of three cells: 1641 elements, against the
/// 1649 that every figure in the benchmark repository is quoted at.
///
/// A grid rather than a single long list, because the viewport has to show all
/// of it. A list of 408 rows is 10 000 pixels tall, so 95% of it would be
/// culled and the scene build would be measuring the culling test instead of
/// the emission -- which would not be comparable to run 6's "all 1649 quads
/// written" at all.
const columns = 8;
const rows_per_column = 51;
const cells_per_row = 3;

const viewport: ui.Size = .{ .w = 1600, .h = 1000 };

// macOS's `clock_gettime(MONOTONIC)` has microsecond resolution, too coarse
// for figures in nanoseconds; `CLOCK_UPTIME_RAW` through the `_nsec_np` variant
// is `mach_absolute_time` in nanoseconds.
extern "c" fn clock_gettime_nsec_np(clock: std.c.clockid_t) u64;

fn nowNs() u64 {
    if (builtin.os.tag == .macos) return clock_gettime_nsec_np(.UPTIME_RAW);
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const Built = struct {
    t: Tree,
    /// A leaf with a definite main size, for the incremental size-change case.
    leaf: Index,
    /// A leaf whose colour is changed, for the repaint case.
    tinted: Index,
};

/// Rows of cells: the shape a real application spends its elements on, and the
/// one where the prefix-scan fast path is reachable. Every element gets visible
/// paint, so the scene build is not measured on a tree that mostly emits
/// nothing.
fn build(gpa: std.mem.Allocator) !Built {
    var t = try Tree.init(gpa);
    try t.setStyle(t.root(), .{ .axis = .row, .padding = 8, .gap = 8, .align_items = .stretch });
    t.setPaint(t.root(), .{ .background = Color.hex(0x1E1F22) });

    var leaf: Index = 0;
    var tinted: Index = 0;
    for (0..columns) |col| {
        const column = try t.appendChild(t.root(), .{
            .axis = .col,
            .width = .{ .grow = 1 },
            .gap = 2,
            .align_items = .stretch,
        });
        t.setPaint(column, .{ .background = Color.hex(0x26282C) });
        for (0..rows_per_column) |i| {
            const row = try t.appendChild(column, .{
                .axis = .row,
                .height = .{ .fixed = 16 },
                .flex_shrink = 0,
                .padding = 2,
                .gap = 4,
                .align_items = .center,
            });
            t.setPaint(row, .{ .background = Color.hex(0x2F3135), .corner_radius = 4 });
            for (0..cells_per_row) |j| {
                const cell = try t.appendChild(row, .{
                    .width = .{ .fixed = 36 },
                    .height = .{ .fixed = 8 },
                });
                t.setPaint(cell, .{ .background = Color.hex(0x9AA0A6), .corner_radius = 4 });
                if (col == columns / 2 and i == rows_per_column / 2 and j == 1) leaf = cell;
                if (col == 1 and i == rows_per_column / 3 and j == 2) tinted = cell;
            }
        }
    }
    t.layout(viewport);
    _ = t.flush();
    return .{ .t = t, .leaf = leaf, .tinted = tinted };
}

fn report(name: []const u8, total_ns: u64, iters: u64, baseline: []const u8) void {
    const per = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iters));
    var unit: []const u8 = "ns";
    var v = per;
    if (v >= 1_000_000) {
        v /= 1_000_000;
        unit = "ms";
    } else if (v >= 1_000) {
        v /= 1_000;
        unit = "us";
    }
    std.debug.print("  {s:<34} {d:>9.2} {s:<3}  {s}\n", .{ name, v, unit, baseline });
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    if (builtin.mode == .debug) {
        std.debug.print(
            \\
            \\  !! debug build: these numbers are meaningless.
            \\  !! rebuild with: zig build bench -Doptimize=ReleaseFast
            \\
        , .{});
    }

    var b = try build(gpa);
    defer b.t.deinit();
    var sc = ui.Scene.init(gpa);
    defer sc.deinit();
    var fb = try ui.Framebuffer.init(gpa, @intFromFloat(viewport.w), @intFromFloat(viewport.h));
    defer fb.deinit();

    const first = try sc.build(&b.t);
    std.debug.print(
        \\
        \\{d} elements, {d} quads, {d} culled, {d} subtrees skipped
        \\viewport {d}x{d}
        \\
        \\
    , .{
        b.t.count(), first.emitted, first.culled, first.skipped_subtrees,
        viewport.w,  viewport.h,
    });
    // Culling anything would mean the scene numbers below are measuring the
    // culling test rather than emission, and would not be comparable to run 6.
    std.debug.assert(first.culled == 0);

    // --- layout ---
    std.debug.print("layout\n", .{});
    {
        const iters = 200;
        for (0..20) |_| b.t.layout(viewport);
        const t0 = nowNs();
        for (0..iters) |_| b.t.layout(viewport);
        report("full layout", nowNs() - t0, iters, "GPUI full refresh: 3.50 ms");
    }
    {
        // The claim. Nothing is dirty, so this should do no work whatsoever.
        const iters = 1_000_000;
        for (0..1000) |_| _ = b.t.flush();
        const t0 = nowNs();
        var sink: u32 = 0;
        for (0..iters) |_| {
            sink += b.t.flush().total();
            std.mem.doNotOptimizeAway(&b.t);
        }
        const dt = nowNs() - t0;
        std.debug.assert(sink == 0);
        report("flush, nothing changed", dt, iters, "GPUI unchanged: 2.32 ms of CPU");
    }
    {
        // A definite size change on one leaf: the incremental case.
        const iters = 200_000;
        var h: f32 = 10;
        const t0 = nowNs();
        for (0..iters) |_| {
            h = if (h == 10) 11 else 10;
            try b.t.setStyle(b.leaf, .{ .width = .{ .fixed = 80 }, .height = .{ .fixed = h } });
            _ = b.t.flush();
        }
        report("setStyle a leaf's size + flush", nowNs() - t0, iters, "propagates: no GPUI equivalent");
    }
    {
        // A repaint. Must cost nothing in layout terms; this measures that the
        // separation of `Paint` from `Style` actually holds in the built code.
        const iters = 500_000;
        var flip = false;
        var work: u32 = 0;
        const t0 = nowNs();
        for (0..iters) |_| {
            flip = !flip;
            b.t.setPaint(b.tinted, .{
                .background = if (flip) Color.hex(0x9AA0A6) else Color.hex(0x4C7EF3),
                .corner_radius = 5,
            });
            work += b.t.flush().total();
        }
        const dt = nowNs() - t0;
        std.debug.assert(work == 0);
        report("setPaint a leaf + flush", dt, iters, "GPUI leaf style: 3.9 ms");
    }

    // --- hit testing ---
    //
    // Here because the window demo showed it dominating an idle frame: once
    // layout and scene build cost nanoseconds, a tree walk per pointer move is
    // what is left. Measured on the same tree, so the number is comparable to
    // the ones above.
    std.debug.print("\nhit test\n", .{});
    {
        const iters = 200_000;
        var sink: u64 = 0;
        const t0 = nowNs();
        for (0..iters) |i| {
            const fi: f32 = @floatFromInt(i % 977);
            sink += b.t.hitTest(.{ .x = 40 + fi, .y = 20 + fi * 0.7 });
        }
        const dt = nowNs() - t0;
        std.mem.doNotOptimizeAway(&sink);
        report("hitTest, 8 columns of 51 rows", dt, iters, "depth 4, widest sibling list 51");
    }
    {
        // The shape that would actually hurt. `hitTest` scans every child of
        // each element on the path, so its cost is the widest sibling list, not
        // the element count -- and a long list is exactly one parent with
        // thousands of children. Measuring the grid alone would have said hit
        // testing was cheap and meant nothing.
        var flat = try Tree.init(gpa);
        defer flat.deinit();
        try flat.setStyle(flat.root(), .{ .axis = .col });
        for (0..10_000) |_| {
            _ = try flat.appendChild(flat.root(), .{ .height = .{ .fixed = 20 }, .flex_shrink = 0 });
        }
        flat.layout(viewport);
        _ = flat.flush();

        const iters = 20_000;
        var sink: u64 = 0;
        const t0 = nowNs();
        for (0..iters) |i| {
            const fi: f32 = @floatFromInt(i % 500);
            sink += flat.hitTest(.{ .x = 10, .y = fi });
        }
        const dt = nowNs() - t0;
        std.mem.doNotOptimizeAway(&sink);
        report("hitTest, 10 000 rows under one parent", dt, iters, "widest sibling list 10 000");
    }

    // --- scene ---
    std.debug.print("\nscene\n", .{});
    {
        // Every iteration changes something, so every iteration rebuilds.
        const iters = 20_000;
        var flip = false;
        const t0 = nowNs();
        for (0..iters) |_| {
            flip = !flip;
            b.t.setPaint(b.tinted, .{
                .background = if (flip) Color.hex(0x9AA0A6) else Color.hex(0x4C7EF3),
                .corner_radius = 5,
            });
            _ = b.t.flush();
            _ = try sc.build(&b.t);
        }
        report("full scene rebuild", nowNs() - t0, iters, "run 6, all 1649 quads written: 0.58-1.22 us");
    }
    {
        const iters = 1_000_000;
        var rebuilt: u32 = 0;
        const t0 = nowNs();
        for (0..iters) |_| {
            const s = try sc.build(&b.t);
            if (s.rebuilt) rebuilt += 1;
        }
        const dt = nowNs() - t0;
        std.debug.assert(rebuilt == 0);
        report("scene build, nothing changed", dt, iters, "one integer comparison");
    }

    // --- text on the frame path ---
    //
    // Synthetic glyph runs, not shaped ones: no font is opened here. Shaping is
    // not on the frame path -- it happens when the text changes -- and what is
    // measured below is what a window full of text costs every time the scene
    // is rebuilt. Six glyphs per cell is a short label, and 1224 cells is a
    // dense table.
    {
        var text_tree = try build(gpa);
        defer text_tree.t.deinit();
        var glyphs: [6]ui.Glyph = undefined;
        for (&glyphs, 0..) |*g, i| {
            const at: u16 = @intCast(i * 6);
            g.* = .{
                .dx = @floatFromInt(at),
                .dy = 0,
                .w = 6,
                .h = 10,
                .u0 = at,
                .v0 = 0,
                .u1 = at + 6,
                .v1 = 10,
                .cluster = @intCast(i),
                .pen_x = @floatFromInt(at),
            };
        }
        const run: ui.TextRun = .{ .glyphs = &glyphs, .width = 36, .ascent = 8, .descent = 2 };

        var labelled: u32 = 0;
        var el: Index = 0;
        while (el < text_tree.t.count()) : (el += 1) {
            if (text_tree.t.childCount(el) != 0) continue;
            try text_tree.t.setText(el, run);
            labelled += 1;
        }
        text_tree.t.layout(viewport);
        _ = text_tree.t.flush();

        var text_scene = ui.Scene.init(gpa);
        defer text_scene.deinit();
        const ts = try text_scene.build(&text_tree.t);

        std.debug.print("\ntext ({d} labels of {d} glyphs: {d} quads, {d} of them glyphs)\n", .{
            labelled, glyphs.len, ts.emitted, ts.glyphs,
        });

        const iters = 2_000;
        var flip = false;
        const t0 = nowNs();
        for (0..iters) |_| {
            flip = !flip;
            text_tree.t.setPaint(text_tree.tinted, .{
                .background = if (flip) Color.hex(0x9AA0A6) else Color.hex(0x4C7EF3),
                .corner_radius = 5,
            });
            _ = text_tree.t.flush();
            _ = try text_scene.build(&text_tree.t);
        }
        report("full scene rebuild, with text", nowNs() - t0, iters, "the same grid without text: see above");

        const rc_iters = 1_000_000;
        const t1 = nowNs();
        for (0..rc_iters) |_| {
            _ = text_tree.t.flush();
        }
        report("recolour text, flush", nowNs() - t1, rc_iters, "text colour is paint, so no layout runs");
    }

    // --- shaping, which is NOT on the frame path ---
    //
    // Measured anyway, because the first question about any text stack is what
    // a string costs, and because the answer is what justifies shaping on
    // change rather than per frame. Both numbers are with a warm glyph cache,
    // which is the realistic case: a label whose text changes is overwhelmingly
    // made of letters the atlas already holds.
    {
        var lib = try text.Library.init();
        defer lib.deinit();
        var font = try lib.open(gpa, "sans", 13);
        defer font.deinit();
        var atlas = try text.Atlas.init(gpa, 512, 512);
        defer atlas.deinit();

        const line = "Hàng thứ 12 — tiếng Việt đã được tạo hình";
        _ = try font.shape(&atlas, line);

        std.debug.print("\nshaping (off the frame path: happens when the text changes)\n", .{});
        {
            const iters = 20_000;
            const t0 = nowNs();
            for (0..iters) |_| _ = try font.shape(&atlas, line);
            report("shape a 40-character line", nowNs() - t0, iters, "HarfBuzz, warm glyph cache");
        }
        {
            var t2 = try Tree.init(gpa);
            defer t2.deinit();
            const el = try t2.appendChild(t2.root(), .{});
            const iters = 20_000;
            const t0 = nowNs();
            for (0..iters) |_| try text.setText(&t2, el, &font, &atlas, line);
            report("shape it and install it", nowNs() - t0, iters, "plus the copy onto the element");
        }
        {
            // What the bidirectional path costs when it is actually taken:
            // the same length of text, with a right-to-left word in it, so
            // the algorithm runs and the line is shaped as three buffers
            // instead of one.
            const mixed = "tiếng Việt אבג zig uikit דהו rất hay";
            _ = try font.shape(&atlas, mixed);
            const iters = 20_000;
            const t0 = nowNs();
            for (0..iters) |_| _ = try font.shape(&atlas, mixed);
            report("shape a mixed-direction line", nowNs() - t0, iters, "three runs, and the algorithm");
        }
    }

    // --- raster ---
    std.debug.print("\nsoftware raster (reference, not the renderer)\n", .{});
    {
        const iters = 200;
        for (0..10) |_| ui.raster.drawScene(&fb, &sc, null);
        const t0 = nowNs();
        for (0..iters) |_| ui.raster.drawScene(&fb, &sc, null);
        report("drawScene, whole viewport", nowNs() - t0, iters, "a GPU does this in the compositor's budget");
    }
    std.debug.print("\noverlays\n", .{});
    // --- moving an overlay: out of flow against the trick it replaced ---
    //
    // A caret moves on every keystroke, so what it costs is a real number and
    // not a curiosity. Both shapes are built here, side by side on the same
    // tree, because the interesting figure is the ratio and that is the only
    // way to measure it once the old shape has been deleted from the demo.
    {
        const field = try b.t.appendChild(b.t.root(), .{
            .axis = .row,
            .padding = 8,
            .width = .{ .fixed = 400 },
            .height = .{ .fixed = 34 },
            .flex_shrink = 0,
        });
        // The old shape: an anchor taking no space on the row, a spacer whose
        // WIDTH is the x coordinate, a column, and the box.
        const anchor = try b.t.appendChild(field, .{
            .axis = .row,
            .width = .{ .fixed = 0 },
            .height = .{ .fixed = 18 },
            .flex_shrink = 0,
        });
        const spacer = try b.t.appendChild(anchor, .{
            .width = .{ .fixed = 0 },
            .height = .{ .fixed = 1 },
            .flex_shrink = 0,
        });
        const column = try b.t.appendChild(anchor, .{
            .axis = .col,
            .width = .{ .fixed = 1 },
            .flex_shrink = 0,
        });
        _ = try b.t.appendChild(column, .{
            .width = .{ .fixed = 1 },
            .height = .{ .fixed = 18 },
            .flex_shrink = 0,
        });
        // The new shape: one element, out of flow.
        const caret = try b.t.appendChild(field, .{
            .position = .absolute,
            .left = 0,
            .top = 0,
            .width = .{ .fixed = 1 },
            .height = .{ .fixed = 18 },
        });
        _ = try b.t.appendChild(field, .{ .width = .{ .fixed = 200 }, .height = .{ .fixed = 18 } });
        b.t.layout(viewport);

        const iters = 200_000;
        {
            var x: f32 = 40;
            var work: u64 = 0;
            const t0 = nowNs();
            for (0..iters) |_| {
                x = if (x == 40) 41 else 40;
                try b.t.setStyle(spacer, .{
                    .width = .{ .fixed = x },
                    .height = .{ .fixed = 1 },
                    .flex_shrink = 0,
                });
                work += b.t.flush().total();
            }
            const dt = nowNs() - t0;
            report("move a caret: spacer width", dt, iters, "");
            std.debug.print("      {d:.1} units of layout work per move\n", .{
                @as(f64, @floatFromInt(work)) / @as(f64, @floatFromInt(iters)),
            });
        }
        {
            var x: f32 = 40;
            var work: u64 = 0;
            const t0 = nowNs();
            for (0..iters) |_| {
                x = if (x == 40) 41 else 40;
                var st = b.t.style(caret);
                st.left = x;
                try b.t.setStyle(caret, st);
                work += b.t.flush().total();
            }
            const dt = nowNs() - t0;
            report("move a caret: out of flow", dt, iters, "");
            std.debug.print("      {d:.1} units of layout work per move\n", .{
                @as(f64, @floatFromInt(work)) / @as(f64, @floatFromInt(iters)),
            });
        }
    }

    std.debug.print("\n", .{});
}
