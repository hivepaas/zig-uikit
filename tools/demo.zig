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
//! The text is real: shaped by HarfBuzz, rasterised by FreeType, and set in
//! Vietnamese on purpose. Vietnamese stacks a tone mark over a vowel that may
//! already carry a diacritic, so `tiếng Việt` is the shortest string that
//! tells you whether the text stack actually shapes or merely maps codepoints
//! to glyphs. An earlier version of this file drew labels as grey bars, which
//! was honest about there being no text and useless for finding out whether
//! the text was right.

const std = @import("std");
const ui = @import("zig-uikit");
const text = @import("zig-uikit-text");

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

/// The field holding a composition in progress, so `main` can write a
/// magnified crop of it. A module-level variable because this is a demo tool
/// and threading a return value through three callers to carry one index would
/// be worse than saying so here.
pub var composition_field: Index = std.math.maxInt(Index);
/// The width of that field's text, so the crop can show its end rather than a
/// guessed offset that moves whenever the string does.
pub var composition_text_w: f32 = 0;


/// More rows than the panel can show, so the clip and the culling both have
/// something to do.
const row_total = 20;

/// The fonts and the one atlas they share.
///
/// One atlas for every size and weight, not one per font. A glyph's cache key
/// is its glyph id in a particular `Font`, and a `Font` is a family at a size,
/// so three fonts filling one atlas is three disjoint sets of slots -- and one
/// atlas means one texture, which means the renderer still issues one draw
/// call for the whole window no matter how many fonts the interface uses.
pub const Fonts = struct {
    lib: text.Library,
    ui: text.Font,
    strong: text.Font,
    big: text.Font,
    atlas: text.Atlas,

    pub fn init(gpa: std.mem.Allocator) !Fonts {
        var lib = try text.Library.init();
        return .{
            .lib = lib,
            .ui = try lib.open(gpa, "sans", 13),
            .strong = try lib.open(gpa, "sans:bold", 13),
            .big = try lib.open(gpa, "sans:bold", 22),
            .atlas = try text.Atlas.init(gpa, 512, 512),
        };
    }

    pub fn deinit(self: *Fonts) void {
        self.atlas.deinit();
        self.big.deinit();
        self.strong.deinit();
        self.ui.deinit();
        self.lib.deinit();
        self.* = undefined;
    }
};

/// A line of text as its own element, sized by the text.
///
/// `flex_shrink = 0` because a label has no sensible smaller size: shrinking it
/// does not reflow it -- there is no line breaker yet -- it just overlaps
/// whatever is beside it. Saying so is also what keeps the layout fast path
/// alive on a row that overflows; see `Style.flex_shrink`.
///
/// With no fonts, it draws the grey bar a design tool uses where text will go.
/// That path exists for the Metal backend, which has no glyph atlas yet: a
/// textured quad there would be drawn by the rounded-rectangle branch of its
/// shader, which is a picture of a bug rather than a picture of missing text.
fn label(t: *Tree, parent: Index, f: ?*text.Font, atlas: ?*text.Atlas, s: []const u8, c: Color) !Index {
    if (f == null or atlas == null) {
        const w = @as(f32, @floatFromInt(std.unicode.utf8CountCodepoints(s) catch s.len)) * 6;
        const e = try t.appendChild(parent, .{
            .width = .{ .fixed = w },
            .height = .{ .fixed = 7 },
            .flex_shrink = 0,
        });
        t.setPaint(e, .{ .background = c, .corner_radius = 3.5 });
        return e;
    }
    const e = try t.appendChild(parent, .{ .flex_shrink = 0 });
    t.setPaint(e, .{ .text_color = c });
    try text.setText(t, e, f.?, atlas.?, s);
    return e;
}

/// A bordered box that holds one line of text and whatever is drawn over it.
fn textField(t: *Tree, parent: Index) !Index {
    const field = try t.appendChild(parent, .{
        .axis = .row,
        .height = .{ .fixed = 34 },
        .flex_shrink = 0,
        .padding = 8,
        .align_items = .center,
    });
    t.setPaint(field, .{
        .background = card,
        .border_color = line,
        .border_width = 1,
        .corner_radius = 8,
    });
    return field;
}

/// A box at `(x, y)` in the coordinates of the run that the label after it
/// will hold, taking no space on the row.
///
/// The anchor is given the run's full height rather than zero. Under
/// `align_items: .center` a zero-height element is centred as a *point*, so
/// its children hang down from the middle of the row instead of lining up with
/// the text -- which is what the first version of this did, and what the
/// rendered image showed.
fn overlay(t: *Tree, field: Index, x: f32, y: f32, w: f32, h: f32, run_h: f32, c: Color) !void {
    const anchor = try t.appendChild(field, .{
        .axis = .row,
        .width = .{ .fixed = 0 },
        .height = .{ .fixed = run_h },
        .flex_shrink = 0,
    });
    _ = try t.appendChild(anchor, .{
        .width = .{ .fixed = x },
        .height = .{ .fixed = 1 },
        .flex_shrink = 0,
    });
    const column = try t.appendChild(anchor, .{
        .axis = .col,
        .width = .{ .fixed = w },
        .flex_shrink = 0,
    });
    _ = try t.appendChild(column, .{
        .width = .{ .fixed = 1 },
        .height = .{ .fixed = y },
        .flex_shrink = 0,
    });
    const box = try t.appendChild(column, .{
        .width = .{ .fixed = w },
        .height = .{ .fixed = h },
        .flex_shrink = 0,
    });
    t.setPaint(box, .{ .background = c, .corner_radius = if (h > 4) 2 else 0 });
}

fn spacer(t: *Tree, parent: Index) !Index {
    return t.appendChild(parent, .{ .width = .{ .grow = 1 }, .height = .{ .fixed = 1 } });
}

/// The interface itself, shared with `gpu_demo.zig` so that the GPU and the
/// software rasteriser are compared on the same scene rather than on two
/// things that look alike.
/// `fonts` may be null, which draws placeholder bars instead of text; see
/// `label`.
pub fn buildUi(t: *Tree, fonts: ?*Fonts) !void {
    const atlas: ?*text.Atlas = if (fonts) |f| &f.atlas else null;
    const ui_font: ?*text.Font = if (fonts) |f| &f.ui else null;
    const strong_font: ?*text.Font = if (fonts) |f| &f.strong else null;
    const big_font: ?*text.Font = if (fonts) |f| &f.big else null;
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
    _ = try spacer(t, title);
    _ = try label(t, title, ui_font, atlas, "zig-uikit — bản thử nghiệm", bright);
    _ = try spacer(t, title);

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
    const nav = [_][]const u8{
        "Trang chủ",   "Dự án",    "Tài liệu",
        "Hình ảnh",    "Âm nhạc",  "Tải về",
        "Đã lưu",      "Thùng rác", "Cài đặt",
    };
    for (nav, 0..) |name, i| {
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
        _ = try label(t, row, ui_font, atlas, name, if (selected) Color.white else bright);

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
            // Sized by its text now, where it used to be a fixed 230x116
            // chosen to look right around placeholder bars.
            .flex_shrink = 0,
            .padding = 12,
            .gap = 8,
        });
        t.setPaint(pop, .{
            .background = Color.hex(0x3A3D42),
            .border_color = Color.hex(0x51555C),
            .border_width = 1,
            .corner_radius = 10,
            .layer = ui.layers.popover,
        });
        _ = try label(t, pop, strong_font, atlas, "Tài liệu", Color.white);
        _ = try label(t, pop, ui_font, atlas, "Thư mục này nằm trong hộp cuộn", bright);
        _ = try label(t, pop, ui_font, atlas, "nhưng vẫn vẽ ra ngoài được.", bright);
        const ok = try t.appendChild(pop, .{
            .height = .{ .fixed = 24 },
            .flex_shrink = 0,
            .padding = 6,
            .justify = .center,
            .align_items = .center,
        });
        t.setPaint(ok, .{ .background = accent, .corner_radius = 6 });
        _ = try label(t, ok, ui_font, atlas, "Đồng ý", Color.white);
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
    const stats = [_][3][]const u8{
        .{ "Phần tử", "1 641", "trong một cây" },
        .{ "Dựng scene", "8,1 µs", "toàn bộ, mỗi khung" },
        .{ "Khung không đổi", "15 ns", "không cấp phát" },
    };
    for (stats) |cell| {
        const c = try t.appendChild(cards, .{
            .axis = .col,
            .width = .{ .grow = 1 },
            .padding = 12,
            .gap = 6,
        });
        t.setPaint(c, .{
            .background = card,
            .border_color = line,
            .border_width = 1,
            .corner_radius = 10,
        });
        _ = try label(t, c, ui_font, atlas, cell[0], bright);
        _ = try label(t, c, big_font, atlas, cell[1], Color.white);
        _ = try label(t, c, ui_font, atlas, cell[2], dim);
    }

    // --- what a text field looks like, drawn from the run and the document ---
    //
    // Two rows. The first is run-level: a selection and a caret, positioned by
    // `TextRun.rangeRect` and `caretX`. The second is document-level: a
    // `Document` holding a composition in progress, which is what
    // `docs/text-and-accessibility.md` §2 is about -- and the first picture
    // this project has produced of it.
    //
    // The positioning here is a workaround and says something true about the
    // toolkit. The scene builder paints an element's box, then its glyphs,
    // then its children, so there is no way to put a rectangle behind an
    // element's OWN text. Every overlay below is therefore a preceding
    // sibling, positioned by a zero-width anchor and a spacer -- the same
    // trick the popover uses, for the same missing feature: absolute
    // positioning. The spacer is also why an overlay cannot start left of the
    // label: a negative fixed width clamps to zero.
    {
        const field_text = "Nháy chuột vào đây: tiếng Việt";
        const sel = "tiếng Việt";
        const sel_start = std.mem.indexOf(u8, field_text, sel).?;
        const sel_end = sel_start + sel.len;

        const field = try textField(t, content);
        if (ui_font) |f| {
            // Shaped once up here because the overlays have to be created
            // before the label they sit behind, and their positions come from
            // the shaped run. `setText` below shapes again -- 2 us, with every
            // glyph already in the atlas -- rather than the demo reaching into
            // the element's run after the fact.
            const run = try f.shape(atlas.?, field_text);
            const r = run.rangeRect(sel_start, sel_end);
            try overlay(t, field, r.x, 0, r.w, r.h, run.height(), Color.hex(0x2F4B8F));
            try overlay(t, field, r.x + r.w, 0, 1, r.h, run.height(), Color.white);
        }
        _ = try label(t, field, ui_font, atlas, field_text, bright);
    }
    {
        // A Telex composition caught mid-word: the document ends in "Vi" and
        // the input method is offering "ệt". On Wayland that offer is a
        // preedit string that never enters the document; on Windows the
        // processor would have written it in and marked the range provisional.
        // `displayText` returns the same two values either way -- the string
        // to lay out, and the byte range that is provisional -- so what
        // follows never learns which protocol it is talking to.
        var doc = ui.Document.init(t.gpa);
        defer doc.deinit();
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(t.gpa);

        _ = try doc.insert(.application, "Bộ gõ đang soạn dở chữ: tiếng Vi");
        try doc.setPreedit("ệt");
        const shown = try doc.displayText(&scratch);

        const field = try textField(t, content);
        composition_field = field;
        if (ui_font) |f| {
            const run = try f.shape(atlas.?, shown.text);
            composition_text_w = run.width;
            const c = shown.composing.?;
            const r = run.rangeRect(c.start, c.end);
            // Underlined, not highlighted: §2 says provisional text is drawn
            // differently and is part of the laid-out text, which is exactly
            // what a byte range over one run buys.
            try overlay(t, field, r.x, run.ascent + 2, r.w, 1, run.height(), accent);
            try overlay(t, field, r.x + r.w, 0, 1, r.h, run.height(), Color.white);
        }
        _ = try label(t, field, ui_font, atlas, shown.text, bright);
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
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "Hàng thứ {d} — tiếng Việt đã được tạo hình", .{i + 1});
        _ = try label(t, row, ui_font, atlas, name, bright);
        _ = try spacer(t, row);
        var size_buf: [32]u8 = undefined;
        const size = try std.fmt.bufPrint(&size_buf, "{d} KB", .{(i + 1) * 37});
        _ = try label(t, row, ui_font, atlas, size, dim);
    }

}

pub const viewport: ui.Size = .{ .w = width, .h = height };

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var fonts = try Fonts.init(gpa);
    defer fonts.deinit();

    var t = try Tree.init(gpa);
    defer t.deinit();
    try buildUi(&t, &fonts);
    t.layout(.{ .w = width, .h = height });

    var sc = ui.Scene.init(gpa);
    defer sc.deinit();
    const s = try sc.build(&t);

    var fb = try ui.Framebuffer.init(gpa, width, height);
    defer fb.deinit();
    fb.clear(bg);
    ui.raster.drawScene(&fb, &sc, fonts.atlas.view());

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    // Written into docs/ rather than the working directory on purpose: it is
    // the screenshot in the README, so regenerating it is `zig build demo` and
    // the image in the repository cannot drift from the code that made it.
    const path = "docs/demo.png";
    try fb.writePng(io, path);

    // The underline under provisional text is one pixel tall in a 900x560
    // image, which is to say invisible in the screenshot. The README makes a
    // claim about it, so the README gets a picture it can be checked against.
    if (composition_field != std.math.maxInt(Index)) {
        const b = t.bounds(composition_field);
        // Just the end of the line: enough to show the committed text, the
        // provisional text under it, and the caret, without the popover that
        // overlaps the start of this field.
        const tail = 100;
        try writeCrop(gpa, io, &fb, .{
            .x = b.x + 8 + @max(0, composition_text_w - tail),
            .y = b.y,
            .w = tail + 14,
            .h = b.h,
        }, 3, "docs/demo-composition.png");
    }

    std.debug.print(
        \\{d} elements, {d} visited, {d} quads emitted ({d} of them glyphs)
        \\{d} culled as entirely outside their clip, of {d} list rows and their contents
        \\{d} painting layers
        \\atlas {d}x{d}, {d:.1}% full
        \\wrote {s} ({d}x{d})
        \\
    , .{
        t.count(),         s.visited,          s.emitted, s.glyphs,
        s.culled,          row_total,
        s.layers_used,
        fonts.atlas.w,     fonts.atlas.h,      fonts.atlas.fillRatio() * 100,
        path,              width,              height,
    });
}

/// Writes a magnified crop of a framebuffer.
///
/// Nearest-neighbour, because the point of magnifying a UI screenshot is to
/// see the pixels as they are. Smoothing them would hide exactly the thing
/// being looked at.
fn writeCrop(
    gpa: std.mem.Allocator,
    io: std.Io,
    src: *const ui.Framebuffer,
    r: ui.Rect,
    scale: u32,
    path: []const u8,
) !void {
    const x0: u32 = @intFromFloat(@max(0, r.x));
    const y0: u32 = @intFromFloat(@max(0, r.y));
    const w = @min(@as(u32, @intFromFloat(r.w)), src.w - x0);
    const h = @min(@as(u32, @intFromFloat(r.h)), src.h - y0);

    var out = try ui.Framebuffer.init(gpa, w * scale, h * scale);
    defer out.deinit();
    for (0..h * scale) |dy| {
        for (0..w * scale) |dx| {
            const sx = x0 + @as(u32, @intCast(dx)) / scale;
            const sy = y0 + @as(u32, @intCast(dy)) / scale;
            const from = (@as(usize, sy) * src.w + sx) * 4;
            const to = (dy * w * scale + dx) * 4;
            @memcpy(out.px[to..][0..4], src.px[from..][0..4]);
        }
    }
    try out.writePng(io, path);
}
