//! Builds a window's worth of interface, rasterises it with the software
//! reference rasteriser, and writes a PPM.
//!
//! There is no window and no GPU involved. The point is that the scene layer
//! can be looked at before either of those exists, and that the image shows
//! the three things that are hard to get right and easy to assert wrongly
//! about: a clipped scrolling list whose overflowing rows are culled, a popover
//! that escapes the clip of the panel that owns it, and borders that meet their
//! fills without a seam.
//!
//! There is no text, so labels are drawn as the bars a design tool would use
//! for them. That is honest about what exists rather than hiding it.

const std = @import("std");
const ui = @import("zig-uikit");

const Tree = ui.Tree;
const Color = ui.Color;
const Index = ui.Index;

const bg = Color.hex(0x1E1F22);
const chrome = Color.hex(0x2B2D30);
const panel = Color.hex(0x26282C);
const card = Color.hex(0x2F3135);
const line = Color.hex(0x3C3F44);
const accent = Color.hex(0x4C7EF3);
const dim = Color.hex(0x6E7177);
const bright = Color.hex(0x9AA0A6);
const row_alt = Color.hex(0x33363B);

const width = 900;
const height = 560;

/// A label placeholder: the bar a mockup uses where text will go.
fn bar(t: *Tree, parent: Index, w: f32, h: f32, c: Color) !Index {
    const e = try t.appendChild(parent, .{
        .width = .{ .fixed = w },
        .height = .{ .fixed = h },
        .flex_shrink = 0,
    });
    t.setPaint(e, .{ .background = c, .corner_radius = h / 2 });
    return e;
}

fn spacer(t: *Tree, parent: Index) !Index {
    return t.appendChild(parent, .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 1 } });
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var t = try Tree.init(gpa);
    defer t.deinit();
    t.setPaint(t.root(), .{ .background = bg });
    // `align_items` defaults to `.start` here, where CSS defaults it to
    // `stretch`. Every container that should fill its parent across its axis
    // therefore has to say so. Whether the default is the right one is a
    // separate question from this demo; it is called out in the README.
    try t.setStyle(t.root(), .{ .axis = .col, .align_items = .stretch });

    // --- title bar ---
    const title = try t.appendChild(t.root(), .{
        .axis = .row,
        .height = .{ .fixed = 36 },
        .flex_shrink = 0,
        .padding = 12,
        .gap = 8,
        .align_items = .center,
    });
    t.setPaint(title, .{ .background = chrome });
    for ([_]u32{ 0xFF5F57, 0xFEBC2E, 0x28C840 }) |rgb| {
        const dot = try t.appendChild(title, .{
            .width = .{ .fixed = 12 },
            .height = .{ .fixed = 12 },
            .flex_shrink = 0,
        });
        t.setPaint(dot, .{ .background = Color.hex(rgb), .corner_radius = 6 });
    }
    _ = try spacer(&t, title);
    _ = try bar(&t, title, 160, 8, dim);
    _ = try spacer(&t, title);

    // --- body ---
    const body = try t.appendChild(t.root(), .{
        .axis = .row,
        .height = .{ .grow = 1 },
        .align_items = .stretch,
    });

    // --- sidebar, with the selected row owning a popover ---
    const sidebar = try t.appendChild(body, .{
        .axis = .col,
        .width = .{ .fixed = 200 },
        .flex_shrink = 0,
        .padding = 10,
        .gap = 4,
        .align_items = .stretch,
    });
    t.setPaint(sidebar, .{ .background = panel });
    for (0..9) |i| {
        const selected = i == 2;
        const row = try t.appendChild(sidebar, .{
            .axis = .row,
            .height = .{ .fixed = 28 },
            .flex_shrink = 0,
            .padding = 7,
            .gap = 8,
            .align_items = .center,
        });
        t.setPaint(row, .{
            .background = if (selected) accent else Color.transparent,
            .corner_radius = 6,
        });
        const icon = try t.appendChild(row, .{
            .width = .{ .fixed = 14 },
            .height = .{ .fixed = 14 },
            .flex_shrink = 0,
        });
        t.setPaint(icon, .{
            .background = if (selected) Color.white else dim,
            .corner_radius = 4,
        });
        _ = try bar(&t, row, 96, 7, if (selected) Color.white else bright);

        if (!selected) continue;

        // A zero-width anchor: it takes no space on the row's main axis, so
        // the popover hanging off it does not push the row's contents around.
        // This is what an absolute-positioning primitive will replace; the
        // layout engine has none yet, and faking one with a real element is
        // closer to honest than adding a half-designed one.
        const anchor = try t.appendChild(row, .{
            .axis = .col,
            .width = .{ .fixed = 0 },
            .flex_shrink = 0,
        });
        const pop = try t.appendChild(anchor, .{
            .axis = .col,
            .width = .{ .fixed = 230 },
            .height = .{ .fixed = 116 },
            .flex_shrink = 0,
            .padding = 12,
            .gap = 9,
        });
        t.setPaint(pop, .{
            .background = Color.hex(0x3A3D42),
            .border_color = Color.hex(0x51555C),
            .border_width = 1,
            .corner_radius = 10,
            .layer = ui.layers.popover,
        });
        _ = try bar(&t, pop, 110, 8, Color.white);
        _ = try bar(&t, pop, 190, 6, bright);
        _ = try bar(&t, pop, 160, 6, bright);
        const ok = try t.appendChild(pop, .{
            .width = .{ .fixed = 76 },
            .height = .{ .fixed = 24 },
            .flex_shrink = 0,
        });
        t.setPaint(ok, .{ .background = accent, .corner_radius = 6 });
    }

    // --- content ---
    const content = try t.appendChild(body, .{
        .axis = .col,
        .width = .{ .grow = 1 },
        .padding = 16,
        .gap = 14,
        .align_items = .stretch,
    });

    const cards = try t.appendChild(content, .{
        .axis = .row,
        .height = .{ .fixed = 100 },
        .flex_shrink = 0,
        .gap = 14,
        .align_items = .stretch,
    });
    for (0..3) |_| {
        const c = try t.appendChild(cards, .{
            .axis = .col,
            .width = .{ .grow = 1 },
            .padding = 12,
            .gap = 10,
        });
        t.setPaint(c, .{
            .background = card,
            .border_color = line,
            .border_width = 1,
            .corner_radius = 10,
        });
        _ = try bar(&t, c, 70, 7, bright);
        _ = try bar(&t, c, 110, 18, Color.white);
        _ = try bar(&t, c, 90, 6, dim);
    }

    // --- the scrolling list: more rows than fit, clipped and culled ---
    const list = try t.appendChild(content, .{
        .axis = .col,
        .height = .{ .grow = 1 },
        .padding = 8,
        .gap = 4,
        .align_items = .stretch,
    });
    t.setPaint(list, .{
        .background = card,
        .border_color = line,
        .border_width = 1,
        .corner_radius = 10,
        .clip_children = true,
    });
    const row_total = 20;
    for (0..row_total) |i| {
        const row = try t.appendChild(list, .{
            .axis = .row,
            .height = .{ .fixed = 26 },
            .flex_shrink = 0,
            .padding = 8,
            .gap = 10,
            .align_items = .center,
        });
        t.setPaint(row, .{
            .background = if (i % 2 == 0) row_alt else Color.transparent,
            .corner_radius = 5,
        });
        const d = try t.appendChild(row, .{
            .width = .{ .fixed = 8 },
            .height = .{ .fixed = 8 },
            .flex_shrink = 0,
        });
        t.setPaint(d, .{
            .background = if (i % 3 == 0) accent else dim,
            .corner_radius = 4,
        });
        _ = try bar(&t, row, 150, 6, bright);
        _ = try spacer(&t, row);
        _ = try bar(&t, row, 48, 6, dim);
    }

    t.layout(.{ .w = width, .h = height });

    var sc = ui.Scene.init(gpa);
    defer sc.deinit();
    const s = try sc.build(&t);

    var fb = try ui.Framebuffer.init(gpa, width, height);
    defer fb.deinit();
    fb.clear(bg);
    ui.raster.drawScene(&fb, &sc);

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    // Written into docs/ rather than the working directory on purpose: it is
    // the screenshot in the README, so regenerating it is `zig build demo` and
    // the image in the repository cannot drift from the code that made it.
    const path = "docs/demo.png";
    try fb.writePng(io, path);

    std.debug.print(
        \\{d} elements, {d} visited, {d} quads emitted
        \\{d} culled as entirely outside their clip, of {d} list rows and their contents
        \\{d} painting layers
        \\wrote {s} ({d}x{d})
        \\
    , .{
        t.count(),  s.visited, s.emitted,
        s.culled,   row_total,
        s.layers_used,
        path,       width,     height,
    });
}
