//! Keyboard focus: which node keys go to, where Tab moves it, what a click
//! does to it, and how a button is pressed with the pointer.
//!
//! In core and linking nothing, like `editing.zig`, and over the
//! accessibility tree rather than the layout tree. That is deliberate: what
//! can take focus is exactly what a screen reader is told is focusable, so
//! the two cannot disagree, and the layout elements that are not things --
//! the caret's three boxes, a row's gap -- are not candidates for either.
//! Focus order is the accessibility tree's order, which is the order the
//! builder registered things in, which is reading order.
//!
//! **The platforms disagree about two things, and they are options rather
//! than guesses.** On a Mac, Tab stops at buttons only when the user has
//! turned on keyboard navigation (System Settings, Keyboard), and a click on
//! a button presses it without taking focus from the text field; on Windows
//! and in GTK, Tab always stops at buttons and a click focuses what it
//! presses. A Mac user who clicks "OK" and then types expects the text to go
//! where it went before.

const std = @import("std");

const access = @import("access.zig");
const tree_mod = @import("tree.zig");
const keys = @import("keys.zig");

const NodeId = access.NodeId;
const no_node = access.no_node;
const LayoutTree = tree_mod.Tree;
const Index = tree_mod.Index;

pub const Options = struct {
    /// Whether Tab stops at buttons. Always, except on a Mac without
    /// keyboard navigation turned on.
    tab_to_buttons: bool = true,
    /// Whether a click on a button focuses it. Yes on Windows and in GTK; no
    /// on a Mac.
    click_focuses_buttons: bool = true,

    pub const mac: Options = .{ .tab_to_buttons = false, .click_focuses_buttons = false };
};

fn takesTab(n: *const access.Node, opt: Options) bool {
    if (!n.state.focusable or n.state.disabled) return false;
    return n.role != .button or opt.tab_to_buttons;
}

/// Where Tab moves focus from `from` -- Shift+Tab with `backward` -- in tree
/// order, wrapping at either end. From `no_node`, the first (or last). Null
/// when nothing takes focus. `from` itself is the answer when it is the only
/// thing that does, which is a Tab that goes nowhere and says so.
pub fn next(at: *const access.Tree, from: NodeId, backward: bool, opt: Options) ?NodeId {
    var w: Walk = .{ .from = from, .backward = backward, .opt = opt };
    w.visit(at, access.Tree.root);
    if (w.found) |f| return f;
    // Wrapped: the first going forward, the last going back.
    return if (backward) w.last else w.first;
}

const Walk = struct {
    from: NodeId,
    backward: bool,
    opt: Options,
    passed: bool = false,
    first: ?NodeId = null,
    last: ?NodeId = null,
    /// Going back: the last candidate before `from`.
    before: ?NodeId = null,
    found: ?NodeId = null,

    fn visit(self: *Walk, at: *const access.Tree, id: NodeId) void {
        if (self.found != null and !self.backward) return;
        const n = at.get(id) orelse return;
        const candidate = takesTab(n, self.opt);
        if (candidate) {
            if (self.first == null) self.first = id;
            self.last = id;
        }
        if (id == self.from) {
            self.passed = true;
            if (self.backward and self.before != null) self.found = self.before;
        } else if (candidate) {
            if (!self.passed) self.before = id;
            if (!self.backward and self.passed and self.found == null) self.found = id;
        }
        for (at.children(id)) |c| self.visit(at, c);
    }
};

/// The node a press on layout element `el` lands on: the one it carries, or
/// the nearest registered ancestor's. A click on the field's text lands on
/// the field, because the text is not a node of its own.
pub fn nodeAt(at: *const access.Tree, layout: *const LayoutTree, el: Index) NodeId {
    var e = el;
    while (e != tree_mod.none) : (e = layout.parentOf(e)) {
        if (at.nodeFor(e)) |n| return n;
    }
    return access.Tree.root;
}

/// What a press on `node` does to focus: the node to focus, or null to leave
/// focus where it is. A press on something that cannot take focus -- a label,
/// the background -- leaves it alone, which is what every desktop platform
/// does and what a web page does not.
pub fn onPress(at: *const access.Tree, node: NodeId, opt: Options) ?NodeId {
    var id = node;
    while (true) {
        const n = at.get(id) orelse return null;
        if (n.state.focusable and !n.state.disabled) {
            if (n.role == .button and !opt.click_focuses_buttons) return null;
            return id;
        }
        id = at.parent(id) orelse return null;
    }
}

/// Whether a key activates the focused node: Space on a button. Not Enter,
/// which in a dialog means the default button wherever focus is, and is the
/// dialog's to decide.
pub fn activates(at: *const access.Tree, focused: NodeId, ev: keys.KeyEvent) bool {
    const n = at.get(focused) orelse return false;
    if (n.role != .button or n.state.disabled) return false;
    return std.mem.eql(u8, ev.text(), " ") and !ev.mods.anyAccel();
}

fn buttonOf(at: *const access.Tree, node: NodeId) ?NodeId {
    var id = node;
    while (true) {
        const n = at.get(id) orelse return null;
        if (n.role == .button) return if (n.state.disabled) null else id;
        id = at.parent(id) orelse return null;
    }
}

/// A button pressed with the pointer.
///
/// Armed on the press and activated on a release *over the same button*; a
/// release anywhere else cancels it. That is how a user backs out of a click
/// they have started, and a button that fired on the press would take that
/// away. While armed, `over` says whether the pointer is still on it, so the
/// button can look pressed only while letting go would press it.
pub const Press = struct {
    armed: NodeId = no_node,
    over: bool = false,

    /// Returns whether a button was armed.
    pub fn down(self: *Press, at: *const access.Tree, node: NodeId) bool {
        self.armed = buttonOf(at, node) orelse no_node;
        self.over = self.armed != no_node;
        return self.over;
    }

    pub fn moved(self: *Press, at: *const access.Tree, node: NodeId) void {
        if (self.armed == no_node) return;
        self.over = buttonOf(at, node) == self.armed;
    }

    /// The button activated, if the release was over the one that was armed.
    pub fn up(self: *Press, at: *const access.Tree, node: NodeId) ?NodeId {
        defer self.* = .{};
        if (self.armed == no_node) return null;
        // Removed while it was held: nothing to activate.
        if (at.get(self.armed) == null) return null;
        return if (buttonOf(at, node) == self.armed) self.armed else null;
    }
};

// ---------------------------------------------------------------------- tests

const testing = std.testing;

/// A window with a label, a text field holding a text element, a card with a
/// button, and a second field: two fields so that Tab without buttons still
/// has somewhere to go.
const Fixture = struct {
    lt: LayoutTree,
    at: access.Tree,
    label: NodeId,
    field: NodeId,
    field_text: Index,
    card: NodeId,
    button: NodeId,
    button_text: Index,
    field2: NodeId,

    fn init(self: *Fixture) !void {
        self.lt = try LayoutTree.init(testing.allocator);
        errdefer self.lt.deinit();
        self.at = try access.Tree.init(testing.allocator, "w");
        const r = self.lt.root();
        const label = try self.lt.appendChild(r, .{});
        const field = try self.lt.appendChild(r, .{});
        self.field_text = try self.lt.appendChild(field, .{});
        const card = try self.lt.appendChild(r, .{});
        const button = try self.lt.appendChild(card, .{});
        self.button_text = try self.lt.appendChild(button, .{});
        const field2 = try self.lt.appendChild(r, .{});
        const editable: access.State = .{ .focusable = true, .editable = true };
        self.label = try self.at.add(&self.lt, label, .{ .role = .static_text, .name = "Name" });
        self.field = try self.at.add(&self.lt, field, .{ .role = .text_field, .state = editable });
        self.card = try self.at.add(&self.lt, card, .{ .role = .group, .name = "card" });
        self.button = try self.at.add(&self.lt, button, .{ .role = .button, .name = "OK", .state = .{ .focusable = true } });
        self.field2 = try self.at.add(&self.lt, field2, .{ .role = .text_field, .state = editable });
    }

    fn deinit(self: *Fixture) void {
        self.at.deinit();
        self.lt.deinit();
    }
};

test "Tab goes through what takes focus in reading order, and wraps" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // The button is inside a card, so reading order is depth first.
    try testing.expectEqual(@as(?NodeId, f.field), next(&f.at, no_node, false, .{}));
    try testing.expectEqual(@as(?NodeId, f.button), next(&f.at, f.field, false, .{}));
    try testing.expectEqual(@as(?NodeId, f.field2), next(&f.at, f.button, false, .{}));
    try testing.expectEqual(@as(?NodeId, f.field), next(&f.at, f.field2, false, .{}));
    // And back.
    try testing.expectEqual(@as(?NodeId, f.button), next(&f.at, f.field2, true, .{}));
    try testing.expectEqual(@as(?NodeId, f.field2), next(&f.at, f.field, true, .{}));
    try testing.expectEqual(@as(?NodeId, f.field2), next(&f.at, no_node, true, .{}));
}

test "on a Mac without keyboard navigation, Tab skips the button" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try testing.expectEqual(@as(?NodeId, f.field2), next(&f.at, f.field, false, Options.mac));
    try testing.expectEqual(@as(?NodeId, f.field), next(&f.at, f.field2, true, Options.mac));
    // With one field left, Tab stays on it rather than reporting nothing.
    f.at.remove(f.field2);
    try testing.expectEqual(@as(?NodeId, f.field), next(&f.at, f.field, false, Options.mac));
    try testing.expectEqual(@as(?NodeId, f.field), next(&f.at, f.field, true, Options.mac));
}

test "a removed node is not a Tab stop, and Tab from it still finds one" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.at.remove(f.card);
    try testing.expectEqual(@as(?NodeId, f.field2), next(&f.at, f.field, false, .{}));
    // Focus was on the button when its card went away.
    try testing.expectEqual(@as(?NodeId, f.field), next(&f.at, f.button, false, .{}));
}

test "a press lands on the nearest node, and only a focusable one takes focus" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // The field's text is not a node: the press is the field's.
    try testing.expectEqual(f.field, nodeAt(&f.at, &f.lt, f.field_text));
    try testing.expectEqual(@as(?NodeId, f.field), onPress(&f.at, f.field, .{}));
    // A label cannot take focus, and neither can anything above it.
    try testing.expectEqual(@as(?NodeId, null), onPress(&f.at, f.label, .{}));
    try testing.expectEqual(@as(?NodeId, null), onPress(&f.at, access.Tree.root, .{}));
    // A button does, except on a Mac.
    const b = nodeAt(&f.at, &f.lt, f.button_text);
    try testing.expectEqual(f.button, b);
    try testing.expectEqual(@as(?NodeId, f.button), onPress(&f.at, b, .{}));
    try testing.expectEqual(@as(?NodeId, null), onPress(&f.at, b, Options.mac));
}

test "a button fires on a release over it, and a release elsewhere backs out" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var p: Press = .{};
    try testing.expect(p.down(&f.at, f.button));
    try testing.expectEqual(@as(?NodeId, f.button), p.up(&f.at, f.button));

    try testing.expect(p.down(&f.at, f.button));
    p.moved(&f.at, f.field);
    try testing.expect(!p.over);
    // Back on it before letting go still counts.
    p.moved(&f.at, f.button);
    try testing.expect(p.over);
    p.moved(&f.at, f.label);
    try testing.expectEqual(@as(?NodeId, null), p.up(&f.at, f.label));

    // A press that did not start on a button arms nothing.
    try testing.expect(!p.down(&f.at, f.field));
    try testing.expectEqual(@as(?NodeId, null), p.up(&f.at, f.button));

    // The button removed while held.
    try testing.expect(p.down(&f.at, f.button));
    f.at.remove(f.card);
    try testing.expectEqual(@as(?NodeId, null), p.up(&f.at, f.button));
}

test "Space presses a focused button, and is only a space in a field" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const space = keys.KeyEvent.typed(" ");
    try testing.expect(activates(&f.at, f.button, space));
    try testing.expect(!activates(&f.at, f.field, space));
    try testing.expect(!activates(&f.at, f.button, keys.KeyEvent.named(.enter)));
    try testing.expect(!activates(&f.at, f.button, keys.KeyEvent.typed(" ").withMods(.{ .ctrl = true })));
}
