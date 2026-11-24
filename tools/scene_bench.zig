//! What the layout core and the scene layer cost, measured on this library.
//!
//! This matters because of what has NOT been measured before. Runs 2 through 9
//! of the benchmark repository measured a prototype -- `incremental_flex.zig`
//! -- and the headline figure the whole project rests on (an unchanged frame at
//! ~15 ns and zero allocations, against ~2.32 ms of CPU for a view-level
//! toolkit) is a figure for that prototype, not for the code shipped here. The
//! library was written from the prototype's lessons but is not the same code:
//! it has a separate paint channel, a `max_cross` cache the prototype lacked,
//! and a correctness fix the prototype still does not have.
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

fn nowNs() u64 {
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

    // --- raster ---
    std.debug.print("\nsoftware raster (reference, not the renderer)\n", .{});
    {
        const iters = 200;
        for (0..10) |_| ui.raster.drawScene(&fb, &sc);
        const t0 = nowNs();
        for (0..iters) |_| ui.raster.drawScene(&fb, &sc);
        report("drawScene, whole viewport", nowNs() - t0, iters, "a GPU does this in the compositor's budget");
    }
    std.debug.print("\n", .{});
}
