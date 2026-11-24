//! The accessibility tree: what a screen reader is told the interface is.
//!
//! `docs/text-and-accessibility.md` §3 asks for "one internal accessibility
//! tree" feeding every platform, with the node shape spikes C and D both used:
//! role, name, bounds, state, text, parent, children, index in parent, and a
//! stable id. This is that tree. It links nothing, and the platform adapters
//! (`platform/macos.zig` today) read it.
//!
//! **It is not the layout tree, and that is the main decision here.** Layout
//! is full of elements that are not things: the demo's caret is three
//! elements -- an anchor, a spacer and a box -- because there is no absolute
//! positioning, and a row of cards has a container whose only job is the gap
//! between them. A screen reader that walked the layout tree would announce
//! every one. So accessible nodes are *registered* against the layout
//! elements that carry them, and the rest of the layout tree does not exist
//! here. A node's parent is the nearest registered ancestor in layout, which
//! is what keeps the two trees consistent without asking the caller to state
//! the structure twice.
//!
//! **Ids are stable and never reused.** VoiceOver, Narrator and Orca all
//! decide "same element or new one" by id; spike D's README records what
//! happens otherwise -- everything is announced as new. An id is the node's
//! slot, a removed node's slot is never handed out again, and asking about a
//! removed id answers null rather than describing whatever replaced it. That
//! is also this tree's half of §5's lifetime problem: an adapter's object can
//! outlive its node, and when it asks, the node is simply gone.
//!
//! **Bounds are not stored.** A node names its layout element and the bounds
//! are read from layout when asked, so a relayout cannot leave the
//! accessibility tree describing where things used to be.

const std = @import("std");
const Allocator = std.mem.Allocator;

const tree_mod = @import("tree.zig");
const document = @import("document.zig");
const geometry = @import("geometry.zig");

const LayoutTree = tree_mod.Tree;
const Index = tree_mod.Index;
const Document = document.Document;
const Rect = geometry.Rect;

pub const NodeId = u32;
pub const no_node: NodeId = std.math.maxInt(NodeId);

/// What a node is. Deliberately short: the platforms each have dozens and
/// they do not line up (UIA control types against AT-SPI roles against AppKit
/// role strings), so each adapter maps this list and nothing longer.
pub const Role = enum {
    /// The root: the window's content.
    window,
    /// A container with a name of its own -- a card, a panel -- that a screen
    /// reader can enter and leave.
    group,
    /// Text that is read, not edited. Its name is the text.
    static_text,
    /// Editable text, backed by a `Document`.
    text_field,
    button,
};

pub const State = packed struct(u8) {
    focusable: bool = false,
    editable: bool = false,
    disabled: bool = false,
    _rest: u5 = 0,
};

pub const Node = struct {
    id: NodeId,
    role: Role,
    /// Owned. For static text, the text itself.
    name: []u8,
    /// The layout element whose bounds are this node's.
    element: Index,
    state: State,
    /// The text a text field holds. Borrowed: the application owns it.
    doc: ?*const Document = null,
    parent: NodeId,
    children: std.ArrayList(NodeId) = .empty,
    alive: bool = true,
};

pub const Info = struct {
    role: Role,
    name: []const u8 = "",
    state: State = .{},
    doc: ?*const Document = null,
};

pub const Tree = struct {
    gpa: Allocator,
    /// Indexed by id. Removed nodes keep their slot, marked dead.
    nodes: std.ArrayList(Node) = .empty,
    /// Which node a layout element carries, for finding parents.
    by_element: std.AutoHashMapUnmanaged(Index, NodeId) = .empty,
    focus: NodeId = no_node,
    /// Bumped whenever a node is added or removed, so that an adapter can
    /// tell whether a cached list of children is still the list.
    revision: u64 = 1,

    pub const root: NodeId = 0;

    /// A tree with its root, carried by the layout root.
    pub fn init(gpa: Allocator, name: []const u8) Allocator.Error!Tree {
        var t: Tree = .{ .gpa = gpa };
        errdefer t.deinit();
        try t.nodes.append(gpa, .{
            .id = root,
            .role = .window,
            .name = try gpa.dupe(u8, name),
            .element = 0,
            .state = .{},
            .parent = no_node,
        });
        try t.by_element.put(gpa, 0, root);
        return t;
    }

    pub fn deinit(self: *Tree) void {
        for (self.nodes.items) |*n| {
            self.gpa.free(n.name);
            n.children.deinit(self.gpa);
        }
        self.nodes.deinit(self.gpa);
        self.by_element.deinit(self.gpa);
        self.* = undefined;
    }

    /// Registers layout element `el` as an accessible node, as the last child
    /// of the node carried by its nearest registered layout ancestor.
    ///
    /// Register parents before children, which is the order a builder creates
    /// them in anyway.
    pub fn add(self: *Tree, layout: *const LayoutTree, el: Index, info: Info) Allocator.Error!NodeId {
        std.debug.assert(!self.by_element.contains(el));
        var owner: NodeId = root;
        var up = layout.parentOf(el);
        while (up != tree_mod.none) : (up = layout.parentOf(up)) {
            if (self.by_element.get(up)) |p| {
                owner = p;
                break;
            }
        }
        const id: NodeId = @intCast(self.nodes.items.len);
        const name = try self.gpa.dupe(u8, info.name);
        errdefer self.gpa.free(name);
        try self.nodes.append(self.gpa, .{
            .id = id,
            .role = info.role,
            .name = name,
            .element = el,
            .state = info.state,
            .doc = info.doc,
            .parent = owner,
        });
        errdefer _ = self.nodes.pop();
        try self.nodes.items[owner].children.append(self.gpa, id);
        try self.by_element.put(self.gpa, el, id);
        self.revision += 1;
        return id;
    }

    /// Removes a node and everything under it. Their ids stay retired.
    pub fn remove(self: *Tree, id: NodeId) void {
        std.debug.assert(id != root);
        const n = self.get(id) orelse return;
        const siblings = &self.nodes.items[n.parent].children;
        if (std.mem.indexOfScalar(NodeId, siblings.items, id)) |i| _ = siblings.orderedRemove(i);
        self.kill(id);
        self.revision += 1;
    }

    fn kill(self: *Tree, id: NodeId) void {
        const n = &self.nodes.items[id];
        for (n.children.items) |c| self.kill(c);
        n.alive = false;
        _ = self.by_element.remove(n.element);
        if (self.focus == id) self.focus = no_node;
    }

    /// The node, or null when the id was never issued or has been removed.
    pub fn get(self: *const Tree, id: NodeId) ?*const Node {
        if (id >= self.nodes.items.len) return null;
        const n = &self.nodes.items[id];
        return if (n.alive) n else null;
    }

    pub fn nodeFor(self: *const Tree, el: Index) ?NodeId {
        return self.by_element.get(el);
    }

    pub fn children(self: *const Tree, id: NodeId) []const NodeId {
        const n = self.get(id) orelse return &.{};
        return n.children.items;
    }

    pub fn parent(self: *const Tree, id: NodeId) ?NodeId {
        const n = self.get(id) orelse return null;
        return if (n.parent == no_node) null else n.parent;
    }

    pub fn indexInParent(self: *const Tree, id: NodeId) ?usize {
        const p = self.parent(id) orelse return null;
        return std.mem.indexOfScalar(NodeId, self.nodes.items[p].children.items, id);
    }

    /// In layout units, from the top-left of the window's content: where the
    /// layout put the node's element this frame.
    pub fn bounds(self: *const Tree, id: NodeId, layout: *const LayoutTree) ?Rect {
        const n = self.get(id) orelse return null;
        return layout.bounds(n.element);
    }

    pub fn setName(self: *Tree, id: NodeId, name: []const u8) Allocator.Error!void {
        if (self.get(id) == null) return;
        const n = &self.nodes.items[id];
        const copy = try self.gpa.dupe(u8, name);
        self.gpa.free(n.name);
        n.name = copy;
    }

    pub fn setDocument(self: *Tree, id: NodeId, doc: ?*const Document) void {
        if (self.get(id) == null) return;
        self.nodes.items[id].doc = doc;
    }

    /// The focused node, or `no_node`. Only a focusable node can hold focus.
    pub fn setFocus(self: *Tree, id: NodeId) void {
        if (id == no_node) {
            self.focus = no_node;
            return;
        }
        const n = self.get(id) orelse return;
        if (n.state.focusable) self.focus = id;
    }

    /// Live nodes, counted. The bulk question AT-SPI's `Cache.GetItems` asks.
    pub fn count(self: *const Tree) usize {
        var c: usize = 0;
        for (self.nodes.items) |n| c += @intFromBool(n.alive);
        return c;
    }
};

// ---------------------------------------------------------------------- tests

const testing = std.testing;

test "a node's parent is its nearest registered layout ancestor" {
    var lt = try LayoutTree.init(testing.allocator);
    defer lt.deinit();
    const card = try lt.appendChild(lt.root(), .{});
    // Two layers of layout that are not things: a row and a spacer column.
    const row = try lt.appendChild(card, .{});
    const col = try lt.appendChild(row, .{});
    const label = try lt.appendChild(col, .{});

    var at = try Tree.init(testing.allocator, "demo");
    defer at.deinit();
    const c = try at.add(&lt, card, .{ .role = .group, .name = "card" });
    const l = try at.add(&lt, label, .{ .role = .static_text, .name = "tiếng Việt" });

    try testing.expectEqual(@as(?NodeId, c), at.parent(l));
    try testing.expectEqual(@as(?NodeId, Tree.root), at.parent(c));
    try testing.expectEqualSlices(NodeId, &.{c}, at.children(Tree.root));
    try testing.expectEqualSlices(NodeId, &.{l}, at.children(c));
    try testing.expectEqual(@as(?usize, 0), at.indexInParent(l));
    // The layout elements in between are not in the tree at all.
    try testing.expectEqual(@as(?NodeId, null), at.nodeFor(row));
    try testing.expectEqual(@as(usize, 3), at.count());
}

test "ids are never reused, and a removed id answers null" {
    var lt = try LayoutTree.init(testing.allocator);
    defer lt.deinit();
    const a = try lt.appendChild(lt.root(), .{});
    const a1 = try lt.appendChild(a, .{});
    const b = try lt.appendChild(lt.root(), .{});

    var at = try Tree.init(testing.allocator, "demo");
    defer at.deinit();
    const na = try at.add(&lt, a, .{ .role = .group, .name = "a" });
    const na1 = try at.add(&lt, a1, .{ .role = .button, .name = "ok", .state = .{ .focusable = true } });
    at.setFocus(na1);
    const rev = at.revision;

    at.remove(na);
    try testing.expect(at.revision > rev);
    try testing.expectEqual(@as(?*const Node, null), at.get(na));
    // The subtree went with it, focus included.
    try testing.expectEqual(@as(?*const Node, null), at.get(na1));
    try testing.expectEqual(no_node, at.focus);
    try testing.expectEqual(@as(usize, 0), at.children(Tree.root).len);

    // A new node does not inherit a retired id, so an adapter still holding
    // `na1` cannot end up describing it.
    const nb = try at.add(&lt, b, .{ .role = .static_text, .name = "b" });
    try testing.expect(nb != na and nb != na1);
    try testing.expectEqual(@as(?*const Node, null), at.get(na1));
}

test "bounds are read from layout, so a relayout is never stale" {
    var lt = try LayoutTree.init(testing.allocator);
    defer lt.deinit();
    const box = try lt.appendChild(lt.root(), .{ .width = .{ .fixed = 40 }, .height = .{ .fixed = 10 }, .padding = 0 });
    try lt.setStyle(lt.root(), .{ .padding = 5 });
    lt.layout(.{ .w = 200, .h = 100 });

    var at = try Tree.init(testing.allocator, "demo");
    defer at.deinit();
    const n = try at.add(&lt, box, .{ .role = .static_text, .name = "x" });
    try testing.expectEqual(@as(f32, 5), at.bounds(n, &lt).?.x);

    try lt.setStyle(lt.root(), .{ .padding = 9 });
    _ = lt.flush();
    try testing.expectEqual(@as(f32, 9), at.bounds(n, &lt).?.x);
}

test "only a focusable node takes focus" {
    var lt = try LayoutTree.init(testing.allocator);
    defer lt.deinit();
    const a = try lt.appendChild(lt.root(), .{});
    const b = try lt.appendChild(lt.root(), .{});
    var at = try Tree.init(testing.allocator, "demo");
    defer at.deinit();
    const text = try at.add(&lt, a, .{ .role = .static_text, .name = "label" });
    const field = try at.add(&lt, b, .{ .role = .text_field, .state = .{ .focusable = true, .editable = true } });
    at.setFocus(text);
    try testing.expectEqual(no_node, at.focus);
    at.setFocus(field);
    try testing.expectEqual(field, at.focus);
}
