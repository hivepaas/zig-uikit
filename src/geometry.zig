//! Logical pixels throughout. Device pixels appear only in the renderer.

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Size = struct {
    w: f32 = 0,
    h: f32 = 0,

    pub fn eql(a: Size, b: Size) bool {
        return a.w == b.w and a.h == b.h;
    }
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    /// Exact comparison, deliberately. Layout compares a freshly computed
    /// rectangle against the stored one to decide whether anything moved, and a
    /// tolerance there would let drift accumulate silently across frames while
    /// also reporting "nothing moved" when something did.
    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }

    pub fn size(self: Rect) Size {
        return .{ .w = self.w, .h = self.h };
    }

    /// The overlapping part of two rectangles, or an empty rectangle pinned to
    /// the overlap's corner when they do not overlap. Width and height are
    /// clamped at zero, so an empty rectangle stays empty under further
    /// intersection -- which is what lets the scene builder treat "nothing of
    /// this element is inside its clip" as a single test.
    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.x and p.x < self.x + self.w and
            p.y >= self.y and p.y < self.y + self.h;
    }
};

pub const Axis = enum(u8) {
    row,
    col,

    pub fn cross(self: Axis) Axis {
        return switch (self) {
            .row => .col,
            .col => .row,
        };
    }
};
