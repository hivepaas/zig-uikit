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

/// The field `window_demo.zig` types into, and the three elements whose
/// geometry a keystroke changes.
///
/// Null when `buildUi` was given no fonts: there is nothing to type into when
/// there is no shaper. See `label`.
pub const Editable = struct {
    field: Index,
    label: Index,
    /// The field's lines as they were last laid out, for `editing.Options`:
    /// which line a byte is on is a fact about how the text was set, and this
    /// is where it is known. Valid until the next `refreshEditable`.
    wrapped: ?ui.text_layout.Wrapped = null,
    /// Behind the text, so it is created before the label.
    selection: Overlay,
    /// Under the provisional text while an input method is composing, and
    /// zero-width otherwise. `docs/text-and-accessibility.md` §2 says
    /// provisional text is drawn differently and is part of the laid-out
    /// line, which is what a byte range over one shaped run buys.
    underline: Overlay,
    caret: Overlay,
    run_h: f32,
};
pub var editable: ?Editable = null;

/// The editable field's lines, for `editing.Options`. Null before the field
/// has been laid out, which is what tells the editing layer to report a
/// vertical arrow unhandled rather than guess.
pub fn editableLines() ?*const ui.text_layout.Wrapped {
    if (editable) |*e| {
        if (e.wrapped) |*w| return w;
    }
    return null;
}

/// The accessibility tree `buildUi` registers its nodes in, when the caller
/// wants one: a screen reader's view of the same interface. Null for the
/// software and GPU demos, which have no screen reader to talk to.
///
/// What is registered is what a person would name: each label as static
/// text, each card as a group, the button, and the typeable field as a text
/// field. The layout elements in between -- rows, spacers, the three elements
/// of each overlay -- are not, which is the reason the accessibility tree is a
/// separate tree; see `access.zig`.
pub var access_tree: ?*ui.access.Tree = null;
/// The typeable field's node, for the window to attach the document to.
pub var editable_node: ui.access.NodeId = ui.access.no_node;
/// Set while building something whose own node already says what its label
/// would: the button, the text field.
var access_mute = false;

fn register(t: *Tree, el: Index, info: ui.access.Info) !ui.access.NodeId {
    const at = access_tree orelse return ui.access.no_node;
    return at.add(t, el, info);
}

/// What the editable field starts out holding.
///
/// Chosen so that the field is interesting before anyone types: multi-byte
/// characters, word boundaries an ASCII word-scan would get wrong, and enough
/// of it to wrap, so that the arrow keys have more than one line to move
/// between. It ends on a space so that a composition started at the caret
/// reads as a new word rather than running into the last one.
pub const editable_initial =
    "Gõ vào đây: ô này tự xuống dòng khi chữ dài hơn bề ngang của nó, " ++
    "và mũi tên lên xuống đi được giữa các dòng. Gõ thử: tiếng ";

pub const caret_color = Color.white;
pub const selection_color = Color.hex(0x2F4B8F);

/// Reshapes the editable field and repositions its caret and selection.
///
/// Everything a keystroke costs is in this function: one shaping pass over the
/// line, three style changes, and a copy of the run into the element. It is
/// here rather than in `window_demo.zig` so that the software demo and the GPU
/// demo can call it too, and so that the cost is measured in one place.
///
/// Provisional text is underlined whichever shape it arrives in.
/// `displayText` returns the document unchanged on macOS and Windows, where
/// the input method has already written into it, and the document with the
/// Wayland preedit spliced in at the caret otherwise -- with the provisional
/// byte range either way. Nothing below learns which protocol it is talking
/// to, which is the whole reason that function exists.
pub fn refreshEditable(
    t: *Tree,
    fonts: *Fonts,
    doc: *const ui.Document,
    scratch: *std.ArrayList(u8),
    glyphs: *std.ArrayList(ui.Glyph),
    lines: *std.ArrayList(ui.text_layout.Line),
) !void {
    // `if (editable) |*p|` and not `&(editable orelse return)`: the second
    // takes the address of the unwrapped payload as an expression, and the
    // store to `e.wrapped` below has to reach the module variable.
    const e = if (editable) |*p| p else return;

    const shown = try doc.displayText(scratch);
    const one = try fonts.ui.shape(&fonts.atlas, shown.text);

    // The width to wrap to is the field's content box *as it was last laid
    // out*. There is no better answer available: the width comes from layout
    // and layout needs the text's size, so on the frame a resize happens the
    // wrap is one frame behind. The window relays out and calls this again,
    // so it catches up immediately; it is a frame of staleness and not a
    // wrong answer that stays wrong.
    const avail = @max(0, t.bounds(e.field).w - field_padding * 2);
    const w = try ui.text_layout.wrap(t.gpa, one, shown.text, avail, fonts.ui.line_height, glyphs, lines);
    e.wrapped = w;

    // A field of one line centres its text; a field of several fills its
    // content box, so the offset is zero. One expression covers both.
    const top = @max(0, (t.bounds(e.field).h - field_padding * 2 - w.run.height()) / 2);

    // The selection's offsets index the document. When a Wayland preedit has
    // been spliced into the laid-out line they no longer index *it*, so the
    // highlight is dropped rather than drawn over the wrong bytes. Nothing is
    // spliced in the macOS and Windows shape -- the provisional text is in the
    // document already -- so there the selection stays.
    //
    // It is also drawn on one line only: a selection running across a line
    // break is several rectangles, and three overlays cannot be that. What it
    // needs is a repeat over `w.lines`, which is a widget's job rather than
    // this demo's.
    if (doc.preedit.items.len > 0) {
        try moveOverlay(t, e.selection, 0, 0, 0);
    } else {
        const sel = doc.selection();
        const a = w.caret(sel.start);
        const b = w.caret(sel.end);
        if (a.y == b.y) {
            try moveOverlay(t, e.selection, a.x, top + a.y, b.x - a.x);
        } else {
            try moveOverlay(t, e.selection, 0, 0, 0);
        }
    }

    if (shown.composing) |cmp| {
        const a = w.caret(cmp.start);
        const b = w.caret(cmp.end);
        if (a.y == b.y) {
            try moveOverlay(t, e.underline, a.x, top + a.y + one.ascent + 2, b.x - a.x);
        } else {
            try moveOverlay(t, e.underline, 0, 0, 0);
        }
    } else {
        try moveOverlay(t, e.underline, 0, 0, 0);
    }

    // Null when the input method asked for no caret while its candidate list
    // is up. A zero-width quad is culled, so that needs no other special case.
    if (doc.displayCaret()) |at| {
        const c = w.caret(at);
        try moveOverlay(t, e.caret, c.x, top + c.y, 1);
    } else {
        try moveOverlay(t, e.caret, 0, 0, 0);
    }

    // Last, because it copies the run out of the list above and the calls
    // here read it.
    try t.setText(e.label, w.run);
}

/// Where a byte range of the editable field's text is drawn, in layout units
/// from the top-left of the window: what an input method asks so that its
/// candidate window opens beside the text. Read from the tree after layout,
/// so it is wherever the field actually is, not where it was built.
pub fn editableRangeRect(t: *const Tree, r: ui.Range) ui.Rect {
    const e = editable orelse return .{};
    const b = t.bounds(e.label);
    const run = t.text(e.label);
    const pad = t.style(e.label).padding;
    const rr = run.rangeRect(r.start, r.end);
    return .{ .x = b.x + pad + rr.x, .y = b.y + pad + rr.y, .w = rr.w, .h = rr.h };
}

/// Where a point in layout units is in the editable field's text, or null
/// outside the field; with `clamp`, the nearer end instead.
/// The other half of `editableRangeRect`, and the platform's whole view of
/// where a click landed: what the click *does* is `editing.press`.
///
/// Offsets are into the shaped run, which is the document's text unless a
/// Wayland preedit is spliced into it; a click during one is refused before
/// this matters (`editing.press` returns `error.Locked`).
pub fn editableHit(t: *const Tree, doc_len: usize, p: ui.Point, clamp: bool) ?ui.editing.Hit {
    const e = editable orelse return null;
    const f = t.bounds(e.field);
    if (!clamp and (p.x < f.x or p.y < f.y or p.x >= f.x + f.w or p.y >= f.y + f.h)) return null;
    const b = t.bounds(e.label);
    const pad = t.style(e.label).padding;
    const run = t.text(e.label);
    const x = p.x - (b.x + pad);
    return .{ .caret = run.byteAt(x, doc_len), .char = run.clusterAt(x, doc_len) };
}

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
        return initScaled(gpa, 1);
    }

    /// The same three fonts for a display with `scale` pixels per point: the
    /// sizes stay 13, 13 and 22 points and the bitmaps are rasterised at the
    /// device size, so the atlas grows with the square of the scale.
    pub fn initScaled(gpa: std.mem.Allocator, scale: f32) !Fonts {
        var lib = try text.Library.init();
        const side: u16 = @intFromFloat(512 * @ceil(scale));
        return .{
            .lib = lib,
            .ui = try lib.openScaled(gpa, "sans", 13, scale),
            .strong = try lib.openScaled(gpa, "sans:bold", 13, scale),
            .big = try lib.openScaled(gpa, "sans:bold", 22, scale),
            .atlas = try text.Atlas.init(gpa, side, side),
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
/// Both backends draw text now, so nothing in the repository asks for that;
/// it stays because `buildUi(t, null)` is the interface with no font
/// dependency at all, which is a useful thing to be able to lay out.
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
    if (!access_mute) _ = try register(t, e, .{ .role = .static_text, .name = s });
    return e;
}

/// A paragraph broken into lines no wider than `max_width`.
///
/// One element and one `TextRun`, like a single-line label: the lines are
/// folded into the glyphs' `dy`, so nothing downstream knows the difference
/// and the element's box grows because `TextRun.height` counts them.
///
/// The width has to be given rather than discovered, and that is a real
/// limitation rather than a simplification for the demo: the width a paragraph
/// may use comes from layout, and layout needs the paragraph's size. A toolkit
/// that wraps text inside a content-sized box needs a measure pass that this
/// engine does not have. A fixed-width container has no such problem, which is
/// why the popover below is given one.
fn paragraph(
    t: *Tree,
    parent: Index,
    f: ?*text.Font,
    atlas: ?*text.Atlas,
    s: []const u8,
    max_width: f32,
    c: Color,
) !Index {
    if (f == null or atlas == null) {
        const e = try t.appendChild(parent, .{
            .width = .{ .fixed = max_width },
            .height = .{ .fixed = 16 },
            .flex_shrink = 0,
        });
        t.setPaint(e, .{ .background = c, .corner_radius = 3.5 });
        return e;
    }
    // The run is copied onto the element, so these live no longer than the
    // call.
    var gl: std.ArrayList(ui.Glyph) = .empty;
    defer gl.deinit(t.gpa);
    var ls: std.ArrayList(ui.text_layout.Line) = .empty;
    defer ls.deinit(t.gpa);

    const e = try t.appendChild(parent, .{ .flex_shrink = 0 });
    t.setPaint(e, .{ .text_color = c });
    _ = try text.setWrappedText(t, e, f.?, atlas.?, s, max_width, &gl, &ls);
    // One accessible node for the paragraph, not one per line: the lines are
    // a typesetting decision and a screen reader should not hear them.
    if (!access_mute) _ = try register(t, e, .{ .role = .static_text, .name = s });
    return e;
}

/// A bordered box that holds one line of text and whatever is drawn over it.
fn textField(t: *Tree, parent: Index) !Index {
    const field = try t.appendChild(parent, .{
        .axis = .row,
        // Content height with a floor, so a field whose text wraps grows
        // instead of clipping it. One line still comes out at `field_height`,
        // which is what the overlays' vertical centring assumes.
        .height = .content,
        .min_height = field_height,
        .flex_shrink = 0,
        .padding = field_padding,
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

/// The height of a text field's content box: everything the overlays below
/// measure from.
const popover_width = 250;
const popover_padding = 12;

const field_padding = 8;
const field_height = 34;
const field_inner_h = field_height - field_padding * 2;

/// A box at `(x, y)` in the coordinates of the run the field's label holds.
///
/// **One element.** It used to be four -- a zero-width anchor, a spacer whose
/// width was `x`, a column, and a spacer whose height was `y` -- with a
/// comment at every site naming the missing feature. `position: .absolute` is
/// that feature, and this is what it deleted.
///
/// The vertical offset is computed rather than inherited, because an
/// out-of-flow element is not centred by its parent's `align_items`. That is
/// the one thing a caller has to know, and it is the price of the element not
/// being pushed around by its siblings either.
fn overlay(t: *Tree, field: Index, x: f32, y: f32, w: f32, h: f32, run_h: f32, c: Color) !Overlay {
    const box = try t.appendChild(field, .{
        .position = .absolute,
        .left = @max(0, x),
        .top = @max(0, (field_inner_h - run_h) / 2) + y,
        .width = .{ .fixed = @max(0, w) },
        .height = .{ .fixed = h },
    });
    t.setPaint(box, .{ .background = c, .corner_radius = if (h > 4) 2 else 0 });
    return .{ .box = box };
}

/// An overlay whose geometry can be changed afterwards.
pub const Overlay = struct {
    box: Index,
};

/// Moves an overlay to `x` and resizes it to `w`, both in run coordinates.
///
/// A width of zero leaves nothing visible: the scene builder culls a
/// zero-width quad, so an empty selection needs no special case here.
///
/// One `setStyle` on one out-of-flow element, so the flush that follows
/// recomputes that element and places it, and touches nothing else. Moving the
/// spacer that used to stand for `x` was a size change that climbed to the row
/// and re-ran it.
pub fn moveOverlay(t: *Tree, o: Overlay, x: f32, y: f32, w: f32) !void {
    var st = t.style(o.box);
    st.left = @max(0, x);
    st.top = @max(0, y);
    st.width = .{ .fixed = @max(0, w) };
    try t.setStyle(o.box, st);
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
        "Trang chủ",
        "Dự án",
        "Tài liệu",
        "Hình ảnh",
        "Âm nhạc",
        "Tải về",
        "Đã lưu",
        "Thùng rác",
        "Cài đặt",
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

        // Out of flow, so it neither pushes the row's contents around nor is
        // pushed by them. This used to be a zero-width anchor with the popover
        // hanging off it, and the comment here used to say what feature was
        // missing.
        const pop = try t.appendChild(row, .{
            .axis = .col,
            .position = .absolute,
            // A definite width now, because the paragraph inside it has to be
            // broken to something and the width a content-sized box would end
            // up with is not known until after the text is laid out. See
            // `paragraph`.
            .width = .{ .fixed = popover_width },
            .flex_shrink = 0,
            .padding = popover_padding,
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
        // One paragraph, broken by the line breaker. It used to be two labels
        // with the break typed in by hand, which is what a toolkit with no
        // line breaking makes you do.
        _ = try paragraph(
            t,
            pop,
            ui_font,
            atlas,
            "Thư mục này nằm trong hộp cuộn nhưng vẫn vẽ được ra ngoài.",
            popover_width - 2 * popover_padding,
            bright,
        );
        const ok = try t.appendChild(pop, .{
            .height = .{ .fixed = 24 },
            .flex_shrink = 0,
            .padding = 6,
            .justify = .center,
            .align_items = .center,
        });
        t.setPaint(ok, .{ .background = accent, .corner_radius = 6 });
        _ = try register(t, ok, .{ .role = .button, .name = "Đồng ý", .state = .{ .focusable = true } });
        access_mute = true;
        _ = try label(t, ok, ui_font, atlas, "Đồng ý", Color.white);
        access_mute = false;
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
        _ = try register(t, c, .{ .role = .group, .name = cell[0] });
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
            _ = try overlay(t, field, r.x, 0, r.w, r.h, run.height(), Color.hex(0x2F4B8F));
            _ = try overlay(t, field, r.x + r.w, 0, 1, r.h, run.height(), Color.white);
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
            _ = try overlay(t, field, r.x, run.ascent + 2, r.w, 1, run.height(), accent);
            _ = try overlay(t, field, r.x + r.w, 0, 1, r.h, run.height(), Color.white);
        }
        _ = try label(t, field, ui_font, atlas, shown.text, bright);
    }
    {
        // --- the field that is actually typed into ---
        //
        // The two rows above are pictures of a text field. This one is a text
        // field: `window_demo.zig` holds a `Document` for it, drains the
        // window's key queue into `editing.apply`, and calls
        // `refreshEditable` when something changed. Nothing about the
        // keyboard reaches this file.
        //
        // An input method is attached on both platforms now, through
        // `NSTextInputClient` on a Mac and `zwp_text_input_v3` on Wayland,
        // and provisional text in it is underlined by `refreshEditable`.
        // The two protocols disagree about where that text lives and this
        // file never finds out which one it is drawing.
        _ = try label(t, content, ui_font, atlas, "Gõ được thật — bàn phím, bộ gõ, và Document:", dim);

        const field = try textField(t, content);
        if (ui_font) |f| {
            const run = try f.shape(atlas.?, editable_initial);
            const h = run.height();
            const sel = try overlay(t, field, 0, 0, 0, h, h, selection_color);
            // The same place and thickness as the composition row above.
            const under = try overlay(t, field, 0, run.ascent + 2, 0, 1, h, accent);
            const caret = try overlay(t, field, run.width, 0, 1, h, h, caret_color);
            // Named by the label above it, as a form would be; its value is
            // the document, attached by the window that owns the document.
            editable_node = try register(t, field, .{
                .role = .text_field,
                .name = "Gõ được thật",
                .state = .{ .focusable = true, .editable = true },
            });
            access_mute = true;
            const lbl = try label(t, field, ui_font, atlas, editable_initial, Color.white);
            access_mute = false;
            editable = .{
                .field = field,
                .label = lbl,
                .selection = sel,
                .underline = under,
                .caret = caret,
                .run_h = h,
            };
        } else {
            _ = try label(t, field, ui_font, atlas, editable_initial, Color.white);
        }
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

    // Lay out, wrap the editable field to the width layout gave it, lay out
    // again. The measure pass this engine does not have, done by hand at the
    // one call site that needs it: `buildUi` sets the field's text on one
    // line because it has no width to wrap to until this has happened.
    var doc = ui.Document.init(gpa);
    defer doc.deinit();
    _ = try doc.insert(.application, editable_initial);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    var wg: std.ArrayList(ui.Glyph) = .empty;
    defer wg.deinit(gpa);
    var wl: std.ArrayList(ui.text_layout.Line) = .empty;
    defer wl.deinit(gpa);
    try refreshEditable(&t, &fonts, &doc, &scratch, &wg, &wl);
    _ = t.flush();

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
        t.count(),     s.visited,                     s.emitted,     s.glyphs,
        s.culled,      row_total,                     s.layers_used, fonts.atlas.w,
        fonts.atlas.h, fonts.atlas.fillRatio() * 100, path,          width,
        height,
    });
}

/// Writes a magnified crop of a framebuffer.
///
/// Nearest-neighbour, because the point of magnifying a UI screenshot is to
/// see the pixels as they are. Smoothing them would hide exactly the thing
/// being looked at.
/// A magnified crop of a framebuffer, for the details a 900x560 screenshot
/// cannot carry: a one-pixel underline, a one-pixel caret.
pub fn writeCrop(
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
