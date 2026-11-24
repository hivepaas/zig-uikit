//! Tests for the scene layer.
//!
//! Two of these are load-bearing for the architecture rather than for the code.
//! "a repaint does no layout work" is the reason `Paint` is not part of
//! `Style`, and "an unchanged frame does not rebuild the scene" is the reason
//! `Tree.revision` exists. If either regressed, the toolkit would still work
//! and would have lost the one measured advantage it was built for, silently.
//!
//! The rest check paint, which cannot be checked by asserting on numbers alone:
//! the right primitives in the right order can still rasterise wrongly. Those
//! probe pixels through the software reference rasteriser.

const std = @import("std");
const testing = std.testing;
const ui = @import("root.zig");

const Tree = ui.Tree;
const Scene = ui.Scene;
const Style = ui.Style;
const Paint = ui.Paint;
const Color = ui.Color;
const Rect = ui.Rect;
const Index = ui.Index;
const Framebuffer = ui.Framebuffer;

const viewport: ui.Size = .{ .w = 1000, .h = 600 };

const red = Color.hex(0xFF0000);
const green = Color.hex(0x00FF00);
const blue = Color.hex(0x0000FF);

fn expectRect(expected: Rect, got: Rect) !void {
    if (!Rect.eql(expected, got)) {
        std.debug.print("  expected {d},{d} {d}x{d}, got {d},{d} {d}x{d}\n", .{
            expected.x, expected.y, expected.w, expected.h,
            got.x,      got.y,      got.w,      got.h,
        });
        return error.RectMismatch;
    }
}

// ------------------------------------------- the two architectural guarantees

test "a repaint does no layout work at all" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const a = try t.appendChild(t.root(), .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 } });
    const b = try t.appendChild(t.root(), .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 40 } });
    t.layout(viewport);
    _ = t.flush();

    const before_a = t.bounds(a);
    const before_b = t.bounds(b);

    t.setPaint(a, .{ .background = red, .corner_radius = 6 });
    t.setPaint(b, .{ .border_color = blue, .border_width = 2 });

    const s = t.flush();
    try testing.expectEqual(@as(u32, 0), s.total());
    try testing.expectEqual(@as(u32, 0), s.full_layouts);
    try testing.expectEqual(@as(u32, 0), s.fast_path);
    try testing.expectEqual(@as(u32, 0), s.slow_path);
    // And nothing moved, which is the other half of the claim.
    try expectRect(before_a, t.bounds(a));
    try expectRect(before_b, t.bounds(b));
}

test "an unchanged frame does not rebuild the scene" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    t.setPaint(t.root(), .{ .background = Color.white });
    _ = try t.appendChild(t.root(), .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    t.layout(viewport);

    var sc = Scene.init(testing.allocator);
    defer sc.deinit();

    const first = try sc.build(&t);
    try testing.expect(first.rebuilt);
    try testing.expectEqual(@as(u32, 1), first.emitted);

    // Three frames where the application did nothing.
    for (0..3) |_| {
        _ = t.flush();
        const again = try sc.build(&t);
        try testing.expect(!again.rebuilt);
        try testing.expectEqual(@as(u32, 0), again.visited);
    }
    // The primitives are still there to upload.
    try testing.expectEqual(@as(usize, 1), sc.items().len);
}

test "a repaint does rebuild the scene, and changes the colour" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const a = try t.appendChild(t.root(), .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    t.setPaint(a, .{ .background = red });
    t.layout(viewport);

    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    _ = try sc.build(&t);
    try testing.expectEqual(red.pack(), sc.items()[0].background);

    t.setPaint(a, .{ .background = green });
    try testing.expectEqual(@as(u32, 0), t.flush().total());
    const s = try sc.build(&t);
    try testing.expect(s.rebuilt);
    try testing.expectEqual(green.pack(), sc.items()[0].background);
}

test "setting the same paint twice is not a change" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const a = try t.appendChild(t.root(), .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    t.layout(viewport);
    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    t.setPaint(a, .{ .background = red });
    _ = try sc.build(&t);
    // A declarative layer on top will re-set every property every frame.
    t.setPaint(a, .{ .background = red });
    try testing.expect(!(try sc.build(&t)).rebuilt);
}

test "a layout that moves something rebuilds the scene" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const a = try t.appendChild(t.root(), .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    const b = try t.appendChild(t.root(), .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    t.setPaint(b, .{ .background = red });
    t.layout(viewport);

    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    _ = try sc.build(&t);
    const y_before = sc.items()[0].y;

    try t.setStyle(a, .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 50 } });
    try testing.expect(t.flush().total() > 0);
    try testing.expect((try sc.build(&t)).rebuilt);
    try testing.expect(sc.items()[0].y != y_before);
}

// ------------------------------------------------------------- what gets built

test "parents paint before children and siblings paint in order" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    t.setPaint(t.root(), .{ .background = Color.white });
    const a = try t.appendChild(t.root(), .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    const b = try t.appendChild(t.root(), .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    const a_kid = try t.appendChild(a, .{ .width = .{ .fixed = 5 }, .height = .{ .fixed = 5 } });
    for ([_]Index{ a, b, a_kid }) |e| t.setPaint(e, .{ .background = red });
    t.layout(viewport);

    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    _ = try sc.build(&t);
    try testing.expectEqualSlices(Index, &.{ t.root(), a, a_kid, b }, sc.owners.items);
}

test "an element with no fill and no border emits nothing but still clips" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const box = try t.appendChild(t.root(), .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 50 } });
    t.setPaint(box, .{ .clip_children = true });
    const inner = try t.appendChild(box, .{ .width = .{ .fixed = 200 }, .height = .{ .fixed = 200 } });
    t.setPaint(inner, .{ .background = red });
    t.layout(viewport);

    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    const s = try sc.build(&t);
    try testing.expectEqual(@as(u32, 1), s.emitted);
    try testing.expectEqual(inner, sc.owners.items[0]);
    try expectRect(.{ .x = 0, .y = 0, .w = 100, .h = 50 }, sc.items()[0].clipRect());
}

test "clips nest by intersection" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{ .axis = .col, .padding = 20 });
    const outer = try t.appendChild(t.root(), .{ .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 } });
    t.setPaint(outer, .{ .clip_children = true });
    // Offset inward, and taller than the outer box, so each axis is decided by
    // a different one of the two rectangles.
    try t.setStyle(outer, .{ .axis = .col, .padding = 10, .width = .{ .fixed = 100 }, .height = .{ .fixed = 100 } });
    const mid = try t.appendChild(outer, .{ .width = .{ .fixed = 60 }, .height = .{ .fixed = 200 }, .flex_shrink = 0 });
    t.setPaint(mid, .{ .clip_children = true });
    const leaf = try t.appendChild(mid, .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    t.setPaint(leaf, .{ .background = red });
    t.layout(viewport);

    try expectRect(.{ .x = 20, .y = 20, .w = 100, .h = 100 }, t.bounds(outer));
    try expectRect(.{ .x = 30, .y = 30, .w = 60, .h = 200 }, t.bounds(mid));

    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    _ = try sc.build(&t);
    // outer: 20..120 on both axes. mid: 30..90 across, 30..230 down.
    try expectRect(.{ .x = 30, .y = 30, .w = 60, .h = 90 }, sc.items()[0].clipRect());
}

test "an element entirely outside its clip is culled" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const box = try t.appendChild(t.root(), .{ .axis = .col, .width = .{ .fixed = 100 }, .height = .{ .fixed = 50 } });
    t.setPaint(box, .{ .clip_children = true, .background = Color.white });
    // `flex_shrink = 0` is not decoration: with the CSS default of 1 these two
    // are squeezed to fit the 50-pixel box and nothing overflows at all, so
    // there would be nothing to cull. Overflow has to be asked for.
    const visible = try t.appendChild(box, .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 100 }, .flex_shrink = 0 });
    const gone = try t.appendChild(box, .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 20 }, .flex_shrink = 0 });
    t.setPaint(visible, .{ .background = red });
    t.setPaint(gone, .{ .background = green });
    t.layout(viewport);

    try expectRect(.{ .x = 0, .y = 100, .w = 10, .h = 20 }, t.bounds(gone));

    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    const s = try sc.build(&t);
    try testing.expectEqual(@as(u32, 2), s.emitted);
    try testing.expectEqual(@as(u32, 1), s.culled);
    try testing.expectEqualSlices(Index, &.{ box, visible }, sc.owners.items);
}

test "a culled subtree is skipped only when its root clips" {
    // The distinction this asserts is the reason culling cannot just stop at
    // the first element outside the clip: without `clip_children`, a child may
    // overflow its culled parent and land back inside the clip, so the subtree
    // has to be walked anyway.
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const box = try t.appendChild(t.root(), .{ .axis = .col, .width = .{ .fixed = 100 }, .height = .{ .fixed = 50 } });
    t.setPaint(box, .{ .clip_children = true });
    _ = try t.appendChild(box, .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 100 }, .flex_shrink = 0 });

    // Both of these are pushed past y=50 by the sibling above, and both have a
    // child of their own.
    const porous = try t.appendChild(box, .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 }, .flex_shrink = 0 });
    _ = try t.appendChild(porous, .{ .width = .{ .fixed = 5 }, .height = .{ .fixed = 5 } });
    const sealed = try t.appendChild(box, .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 }, .flex_shrink = 0 });
    t.setPaint(sealed, .{ .clip_children = true });
    _ = try t.appendChild(sealed, .{ .width = .{ .fixed = 5 }, .height = .{ .fixed = 5 } });
    t.layout(viewport);

    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    const s = try sc.build(&t);
    try testing.expectEqual(@as(u32, 1), s.skipped_subtrees);
    // root, box, the tall child, porous, porous's child, sealed -- but not
    // sealed's child.
    try testing.expectEqual(@as(u32, 6), s.visited);
    try testing.expectEqual(@as(usize, 7), t.count());
}

// -------------------------------------------------------------------- layers

test "a higher layer paints last whatever its position in the tree" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    t.setPaint(t.root(), .{ .background = Color.white });
    // The popover is the FIRST child, so tree order would paint it underneath.
    const pop = try t.appendChild(t.root(), .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    const a = try t.appendChild(t.root(), .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    const b = try t.appendChild(t.root(), .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    t.setPaint(pop, .{ .background = green, .layer = ui.layers.popover });
    t.setPaint(a, .{ .background = red });
    t.setPaint(b, .{ .background = blue });
    t.layout(viewport);

    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    const s = try sc.build(&t);
    try testing.expectEqual(@as(u32, 2), s.layers_used);
    // Stable within a layer: root, a, b keep tree order.
    try testing.expectEqualSlices(Index, &.{ t.root(), a, b, pop }, sc.owners.items);
}

test "a layer is inherited by the subtree and does not need repeating" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const pop = try t.appendChild(t.root(), .{ .axis = .col, .width = .{ .fixed = 50 }, .height = .{ .fixed = 50 } });
    const pop_kid = try t.appendChild(pop, .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    const after = try t.appendChild(t.root(), .{ .width = .{ .fixed = 10 }, .height = .{ .fixed = 10 } });
    t.setPaint(pop, .{ .background = green, .layer = ui.layers.popover });
    t.setPaint(pop_kid, .{ .background = blue });
    t.setPaint(after, .{ .background = red });
    t.layout(viewport);

    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    _ = try sc.build(&t);
    try testing.expectEqualSlices(Index, &.{ after, pop, pop_kid }, sc.owners.items);
}

test "entering a layer escapes the clip it was inside" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const scroll = try t.appendChild(t.root(), .{ .axis = .col, .width = .{ .fixed = 100 }, .height = .{ .fixed = 50 } });
    t.setPaint(scroll, .{ .clip_children = true });
    // A popover owned by a control inside the scroll box, overflowing it on
    // both axes. Clipping it to its owner is exactly the bug layers prevent.
    const pop = try t.appendChild(scroll, .{ .width = .{ .fixed = 300 }, .height = .{ .fixed = 200 } });
    t.setPaint(pop, .{ .background = green, .layer = ui.layers.popover });
    t.layout(viewport);

    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    const s = try sc.build(&t);
    try testing.expectEqual(@as(u32, 1), s.emitted);
    try expectRect(.{ .x = 0, .y = 0, .w = 1000, .h = 600 }, sc.items()[0].clipRect());
}

// ----------------------------------------------------- what it actually looks like

fn render(t: *const Tree, w: u32, h: u32) !Framebuffer {
    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    _ = try sc.build(t);
    var fb = try Framebuffer.init(testing.allocator, w, h);
    ui.raster.drawScene(&fb, &sc, null);
    return fb;
}

test "a filled rectangle covers exactly its bounds" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    try t.setStyle(t.root(), .{ .axis = .col, .padding = 10 });
    const box = try t.appendChild(t.root(), .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 20 } });
    t.setPaint(box, .{ .background = red });
    t.layout(.{ .w = 60, .h = 50 });

    var fb = try render(&t, 60, 50);
    defer fb.deinit();

    // Inside.
    try testing.expect(Color.eql(red, fb.at(20, 20)));
    // The last covered pixel is at 39,29; the first clear one at 40,30.
    try testing.expect(Color.eql(red, fb.at(39, 29)));
    try testing.expect(Color.eql(Color.white, fb.at(40, 20)));
    try testing.expect(Color.eql(Color.white, fb.at(20, 30)));
    // Outside, before the box starts.
    try testing.expect(Color.eql(Color.white, fb.at(9, 20)));
}

test "a corner radius removes the corner and antialiases it" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const box = try t.appendChild(t.root(), .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 40 } });
    t.setPaint(box, .{ .background = Color.black, .corner_radius = 12 });
    t.layout(.{ .w = 40, .h = 40 });

    var fb = try render(&t, 40, 40);
    defer fb.deinit();

    // The very corner is outside a radius-12 arc.
    try testing.expect(Color.eql(Color.white, fb.at(0, 0)));
    // The centre is not.
    try testing.expect(Color.eql(Color.black, fb.at(20, 20)));
    // The arc crosses the corner block, so somewhere in it there are pixels
    // that are neither fully covered nor fully clear. That is the whole point
    // of a distance field rather than a rectangle test.
    var partial: u32 = 0;
    for (0..13) |y| {
        for (0..13) |x| {
            const g = fb.at(@intCast(x), @intCast(y)).r;
            if (g > 0 and g < 255) partial += 1;
        }
    }
    try testing.expect(partial >= 8);
}

test "a border is stroked inward and meets the fill without a seam" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const box = try t.appendChild(t.root(), .{ .width = .{ .fixed = 30 }, .height = .{ .fixed = 30 } });
    t.setPaint(box, .{ .background = green, .border_color = red, .border_width = 4 });
    t.layout(.{ .w = 30, .h = 30 });

    var fb = try render(&t, 30, 30);
    defer fb.deinit();

    // Outermost pixel is border, not background: inward stroke.
    try testing.expect(Color.eql(red, fb.at(0, 15)));
    try testing.expect(Color.eql(red, fb.at(3, 15)));
    // Just past the border width, fill.
    try testing.expect(Color.eql(green, fb.at(5, 15)));
    try testing.expect(Color.eql(green, fb.at(15, 15)));
    // No seam: every pixel across the join is fully opaque, so the two
    // coverages summed to one rather than leaving a gap.
    for (0..30) |x| {
        try testing.expectEqual(@as(u8, 255), fb.at(@intCast(x), 15).a);
    }
}

test "the clip rectangle cuts the pixels, not just the primitive list" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const box = try t.appendChild(t.root(), .{ .axis = .col, .width = .{ .fixed = 20 }, .height = .{ .fixed = 10 } });
    t.setPaint(box, .{ .clip_children = true });
    const inner = try t.appendChild(box, .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 40 } });
    t.setPaint(inner, .{ .background = Color.black });
    t.layout(.{ .w = 20, .h = 40 });

    var fb = try render(&t, 20, 40);
    defer fb.deinit();

    // The inner box is 40 tall and the clip is 10, so rows 0..9 are painted and
    // rows 10..39 are not -- even though the primitive's own bounds cover them.
    try testing.expect(Color.eql(Color.black, fb.at(10, 9)));
    try testing.expect(Color.eql(Color.white, fb.at(10, 10)));
    try testing.expect(Color.eql(Color.white, fb.at(10, 39)));
}

test "alpha composites against what is already there" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const under = try t.appendChild(t.root(), .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } });
    t.setPaint(under, .{ .background = Color.black });
    const over = try t.appendChild(under, .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } });
    t.setPaint(over, .{ .background = Color.rgba(255, 255, 255, 128) });
    t.layout(.{ .w = 20, .h = 20 });

    var fb = try render(&t, 20, 20);
    defer fb.deinit();

    const mid = fb.at(10, 10);
    try testing.expect(mid.r > 120 and mid.r < 136);
    try testing.expectEqual(@as(u8, 255), mid.a);
}

test "a higher layer really does cover what is beneath it" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    // A zero-height anchor, so its overflowing child shares the space with the
    // sibling that follows it. This is the shape of a real popover: owned by
    // something in the layout, drawn outside it.
    const anchor = try t.appendChild(t.root(), .{ .axis = .col, .width = .{ .fixed = 20 }, .height = .{ .fixed = 0 }, .flex_shrink = 0 });
    const pop = try t.appendChild(anchor, .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 }, .flex_shrink = 0 });
    const content = try t.appendChild(t.root(), .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 }, .flex_shrink = 0 });
    t.setPaint(pop, .{ .background = Color.white, .layer = ui.layers.tooltip });
    t.setPaint(content, .{ .background = Color.black });
    t.layout(.{ .w = 20, .h = 20 });
    // Both cover the same pixels, and in tree order the popover comes first --
    // so without layers the black content would be on top.
    try expectRect(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, t.bounds(pop));
    try expectRect(.{ .x = 0, .y = 0, .w = 20, .h = 20 }, t.bounds(content));

    var fb = try render(&t, 20, 20);
    defer fb.deinit();
    try testing.expect(Color.eql(Color.white, fb.at(10, 10)));
}

test "a clip cuts at the inside of the border, not the outer edge" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const panel = try t.appendChild(t.root(), .{ .axis = .col, .width = .{ .fixed = 20 }, .height = .{ .fixed = 20 } });
    t.setPaint(panel, .{
        .background = Color.white,
        .border_color = red,
        .border_width = 3,
        .clip_children = true,
    });
    const over = try t.appendChild(panel, .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 40 }, .flex_shrink = 0 });
    t.setPaint(over, .{ .background = Color.black });
    t.layout(.{ .w = 20, .h = 20 });

    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    _ = try sc.build(&t);
    try expectRect(.{ .x = 3, .y = 3, .w = 14, .h = 14 }, sc.items()[1].clipRect());

    var fb = try render(&t, 20, 20);
    defer fb.deinit();
    // The border survives on every side, including the one the child overflows.
    try testing.expect(Color.eql(red, fb.at(10, 1)));
    try testing.expect(Color.eql(red, fb.at(10, 18)));
    try testing.expect(Color.eql(red, fb.at(1, 10)));
    try testing.expect(Color.eql(Color.black, fb.at(10, 10)));
}

test "the PNG encoder produces a file that decodes back to the pixels" {
    // A hand-written encoder is exactly the kind of thing that produces a file
    // which opens in one viewer and not another, so this decodes it rather than
    // checking that it looks plausible: every chunk's CRC is verified and the
    // compressed stream is inflated and compared to the framebuffer.
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const box = try t.appendChild(t.root(), .{ .width = .{ .fixed = 8 }, .height = .{ .fixed = 6 } });
    t.setPaint(box, .{ .background = red });
    t.layout(.{ .w = 16, .h = 12 });

    var fb = try render(&t, 16, 12);
    defer fb.deinit();

    const png = try fb.encodePng(testing.allocator);
    defer testing.allocator.free(png);

    try testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A }, png[0..8]);

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(testing.allocator);
    var saw_ihdr = false;
    var saw_iend = false;

    var at: usize = 8;
    while (at + 12 <= png.len) {
        const len = std.mem.readInt(u32, png[at..][0..4], .big);
        const kind = png[at + 4 ..][0..4];
        const data = png[at + 8 ..][0..len];
        const want_crc = std.mem.readInt(u32, png[at + 8 + len ..][0..4], .big);
        try testing.expectEqual(want_crc, std.hash.Crc32.hash(png[at + 4 .. at + 8 + len]));

        if (std.mem.eql(u8, kind, "IHDR")) {
            saw_ihdr = true;
            try testing.expectEqual(@as(u32, 16), std.mem.readInt(u32, data[0..4], .big));
            try testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, data[4..8], .big));
            try testing.expectEqual(@as(u8, 8), data[8]);
            try testing.expectEqual(@as(u8, 2), data[9]);
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(testing.allocator, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            saw_iend = true;
        }
        at += 12 + len;
    }
    try testing.expect(saw_ihdr and saw_iend);
    try testing.expectEqual(png.len, at);

    var in: std.Io.Reader = .fixed(idat.items);
    const window = try testing.allocator.alloc(u8, std.compress.flate.max_window_len);
    defer testing.allocator.free(window);
    var dec: std.compress.flate.Decompress = .init(&in, .zlib, window);
    const raw = try dec.reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(raw);

    const stride = 16 * 3;
    try testing.expectEqual((stride + 1) * 12, raw.len);
    for (0..12) |y| {
        const row = raw[y * (stride + 1) ..];
        try testing.expectEqual(@as(u8, 0), row[0]); // filter: none
        for (0..16) |x| {
            const want = fb.at(@intCast(x), @intCast(y));
            try testing.expectEqualSlices(u8, &.{ want.r, want.g, want.b }, row[1 + x * 3 ..][0..3]);
        }
    }
}

// ------------------------------------------------------------------- text
//
// No font is involved in any of these. The atlas is a handful of bytes written
// by hand, which is the point: the core's half of text is "sample a coverage
// byte at an exact texel and blend it", and that is checkable without
// fontconfig, FreeType or HarfBuzz being installed. What those produce is
// tested in `zig build test-text`.

/// A run of `n` glyphs in a row, each `size` square, reading from a diagonal
/// strip of the atlas so every glyph has a different coverage value.
fn fakeRun(glyphs: []ui.Glyph, size: u16) ui.TextRun {
    for (glyphs, 0..) |*g, i| {
        const at: u16 = @intCast(i * size);
        g.* = .{
            .dx = @floatFromInt(at),
            .dy = 0,
            .w = @floatFromInt(size),
            .h = @floatFromInt(size),
            .u0 = at,
            .v0 = 0,
            .u1 = at + size,
            .v1 = size,
        };
    }
    return .{
        .glyphs = glyphs,
        .width = @floatFromInt(glyphs.len * size),
        .ascent = @floatFromInt(size),
        .descent = 0,
    };
}

test "text sizes a leaf and gives it a real baseline" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const label = try t.appendChild(t.root(), .{});

    var glyphs: [4]ui.Glyph = undefined;
    try t.setText(label, fakeRun(&glyphs, 6));
    t.layout(.{ .w = 200, .h = 100 });

    // 4 glyphs of 6 pixels wide, 6 of ascent and nothing below the baseline.
    try testing.expectEqual(@as(f32, 24), t.bounds(label).w);
    try testing.expectEqual(@as(f32, 6), t.bounds(label).h);
    // The baseline is the ascent, not the 0.8 * height a childless element
    // without text has to guess at.
    try testing.expectEqual(@as(f32, 6), t.elements()[label].baseline);
}

test "padding surrounds text the same way it surrounds children" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const label = try t.appendChild(t.root(), .{ .padding = 5 });

    var glyphs: [2]ui.Glyph = undefined;
    try t.setText(label, fakeRun(&glyphs, 10));
    t.layout(.{ .w = 200, .h = 100 });

    try testing.expectEqual(@as(f32, 30), t.bounds(label).w); // 20 + 2*5
    try testing.expectEqual(@as(f32, 20), t.bounds(label).h); // 10 + 2*5
    try testing.expectEqual(@as(f32, 15), t.elements()[label].baseline);
}

test "setting text dirties layout and recolouring it does not" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const label = try t.appendChild(t.root(), .{});
    var glyphs: [3]ui.Glyph = undefined;
    try t.setText(label, fakeRun(&glyphs, 8));
    t.layout(.{ .w = 200, .h = 100 });

    // Longer text is wider, and that has to reach the parent.
    var more: [5]ui.Glyph = undefined;
    try t.setText(label, fakeRun(&more, 8));
    const s = t.flush();
    try testing.expect(s.total() > 0);
    try testing.expectEqual(@as(f32, 40), t.bounds(label).w);

    // Colour is not a size input.
    const rev = t.revision;
    t.setPaint(label, .{ .text_color = Color.hex(0xFF0000) });
    try testing.expect(t.revision > rev);
    try testing.expectEqual(@as(u32, 0), t.flush().total());
}

test "glyph quads follow their element's box, in its clip and its layer" {
    var t = try Tree.init(testing.allocator);
    defer t.deinit();
    const box = try t.appendChild(t.root(), .{
        .width = .{ .fixed = 50 },
        .height = .{ .fixed = 20 },
        .padding = 2,
    });
    t.setPaint(box, .{ .background = Color.hex(0x112233), .clip_children = true });
    var glyphs: [3]ui.Glyph = undefined;
    try t.setText(box, fakeRun(&glyphs, 4));
    t.layout(.{ .w = 200, .h = 100 });

    var sc = Scene.init(testing.allocator);
    defer sc.deinit();
    const st = try sc.build(&t);
    try testing.expectEqual(@as(u32, 3), st.glyphs);

    const q = sc.items();
    try testing.expectEqual(@as(usize, 4), q.len);
    // The box first, then its glyphs -- which is what makes a label paint over
    // its own background without anything having to sort.
    try testing.expect(!q[0].flags.textured);
    for (q[1..]) |g| {
        try testing.expect(g.flags.textured);
        // Positioned from the element's content origin, which is the padding
        // box corner, not the element's edge.
        try testing.expect(g.x >= t.bounds(box).x + 2);
        // Carrying the clip of the element they belong to.
        try testing.expectEqual(q[0].cx, g.cx);
    }
    try testing.expectEqual(t.bounds(box).x + 2, q[1].x);
}

test "a glyph samples exactly one texel per pixel" {
    // A 4x1 atlas with four distinct coverages, drawn as one 4x1 glyph at an
    // integral position. Each destination pixel must read its own texel: this
    // is the property the GPU's `texelFetch` path is written to match, and the
    // reason glyph positions are snapped to the pixel grid.
    const pixels = [_]u8{ 0, 85, 170, 255 };
    const atlas: ui.AtlasView = .{ .pixels = &pixels, .w = 4, .h = 1 };

    var fb = try ui.Framebuffer.init(testing.allocator, 8, 3);
    defer fb.deinit();
    fb.clear(Color.black);

    const q: ui.Quad = .{
        .x = 2,
        .y = 1,
        .w = 4,
        .h = 1,
        .background = Color.white.pack(),
        .border_color = 0,
        .border_width = 0,
        .corner_radius = 0,
        .cx = 0,
        .cy = 0,
        .cw = 8,
        .ch = 3,
        .u0 = 0,
        .v0 = 0,
        .u1 = 4,
        .v1 = 1,
        .flags = .{ .textured = true },
    };
    ui.raster.drawQuad(&fb, q, atlas);

    for (pixels, 0..) |cov, i| {
        const got = fb.at(@intCast(2 + i), 1).r;
        try testing.expectEqual(cov, got);
    }
    // The quad is expanded by a pixel for antialiasing it does not have, so
    // the pixels either side must be untouched rather than reading a
    // neighbouring texel or the edge one twice.
    try testing.expectEqual(@as(u8, 0), fb.at(1, 1).r);
    try testing.expectEqual(@as(u8, 0), fb.at(6, 1).r);
    try testing.expectEqual(@as(u8, 0), fb.at(2, 0).r);
    try testing.expectEqual(@as(u8, 0), fb.at(2, 2).r);
}

test "a clip cuts a glyph at the texel the clip falls on" {
    const pixels = [_]u8{ 255, 255, 255, 255 };
    const atlas: ui.AtlasView = .{ .pixels = &pixels, .w = 4, .h = 1 };

    var fb = try ui.Framebuffer.init(testing.allocator, 8, 3);
    defer fb.deinit();
    fb.clear(Color.black);

    const q: ui.Quad = .{
        .x = 2,
        .y = 1,
        .w = 4,
        .h = 1,
        .background = Color.white.pack(),
        .border_color = 0,
        .border_width = 0,
        .corner_radius = 0,
        // Clip ends halfway through the glyph's third pixel.
        .cx = 0,
        .cy = 0,
        .cw = 4.5,
        .ch = 3,
        .u0 = 0,
        .v0 = 0,
        .u1 = 4,
        .v1 = 1,
        .flags = .{ .textured = true },
    };
    ui.raster.drawQuad(&fb, q, atlas);

    try testing.expectEqual(@as(u8, 255), fb.at(2, 1).r);
    try testing.expectEqual(@as(u8, 255), fb.at(3, 1).r);
    // Half covered by the clip: the clip is antialiased even though the glyph
    // is not, because the clip edge is geometry and the glyph edge is a texel.
    try testing.expectEqual(@as(u8, 128), fb.at(4, 1).r);
    try testing.expectEqual(@as(u8, 0), fb.at(5, 1).r);
}

test "a textured quad with no atlas draws nothing" {
    var fb = try ui.Framebuffer.init(testing.allocator, 4, 4);
    defer fb.deinit();
    fb.clear(Color.black);
    const q: ui.Quad = .{
        .x = 0,
        .y = 0,
        .w = 4,
        .h = 4,
        .background = Color.white.pack(),
        .border_color = 0,
        .border_width = 0,
        .corner_radius = 0,
        .cx = 0,
        .cy = 0,
        .cw = 4,
        .ch = 4,
        .u0 = 0,
        .v0 = 0,
        .u1 = 4,
        .v1 = 4,
        .flags = .{ .textured = true },
    };
    ui.raster.drawQuad(&fb, q, null);
    try testing.expectEqual(@as(u8, 0), fb.at(2, 2).r);
}
