//! A keystroke as the rest of the toolkit sees it: a named key, a modifier
//! set, and the text the key produced.
//!
//! Plain data, in core, linking nothing -- which is the whole reason it is
//! here rather than in the Wayland module. The editing layer above it
//! (`editing.zig`) turns these into document operations, and its tests run on
//! a machine with no compositor, no seat and no keymap. A keyboard abstraction
//! that can only be exercised by pressing a key is a keyboard abstraction with
//! no tests.
//!
//! Three things in the shape are decisions, not incidental:
//!
//! **`text` is carried inline, not as a slice.** A `KeyEvent` is produced
//! inside a libwayland listener and consumed a frame later, so a slice would
//! point into the listener's stack. Sixteen bytes is more than any single
//! keystroke produces -- the longest real case is a dead-key compose sequence,
//! one grapheme -- and it makes the event copyable, which is what lets the
//! queue below be a plain array.
//!
//! **`base` is separate from `text`.** They answer different questions. `text`
//! is what the key typed; `base` is which key it was, as the layout names it,
//! with no modifiers applied. An accelerator needs the second: pressing Ctrl
//! with the A key produces the text `\x01`, not `a`, so anything matching
//! Ctrl+A against the typed text matches nothing. Every toolkit that gets this
//! wrong gets it wrong in the same place.
//!
//! **A key that only types has `key == .none`.** The named keys are the ones
//! an editor has to switch on. Everything else arrives as text and needs no
//! name, so the enum stays short instead of being a keysym table that would
//! have to be kept in step with three platforms.

const std = @import("std");

/// The keys an editor acts on by name rather than by the text they produce.
///
/// Deliberately not a full keysym table. A letter, a digit and a punctuation
/// mark are all `.none` plus text, because nothing in a text field wants to
/// know which of them it was.
pub const Key = enum(u8) {
    /// Not a named key. The event carries text, or nothing at all.
    none = 0,

    escape,
    enter,
    tab,
    backspace,
    delete,
    insert,

    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
};

/// Which modifiers were held when the key went down.
///
/// `caps_lock` is here and is NOT consulted by anything: the keymap has
/// already applied it by the time text comes out, so acting on it again would
/// uppercase twice. It is reported because an application drawing an on-screen
/// keyboard wants it, and leaving it out would mean adding a second path
/// later.
pub const Mods = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    /// Super, Windows, Command.
    logo: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _rest: u2 = 0,

    pub fn eql(a: Mods, b: Mods) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
    }

    /// Whether any modifier that changes what a key *means* is held. Caps lock
    /// and num lock are not such modifiers -- the keymap folded them in
    /// already -- so they are excluded, and that exclusion is the only reason
    /// this function exists instead of a comparison against `.{}`.
    pub fn anyAccel(self: Mods) bool {
        return self.ctrl or self.alt or self.logo;
    }
};

/// The most text one keystroke can carry. See the note at the top of the file.
pub const text_capacity = 16;

pub const KeyEvent = struct {
    key: Key = .none,
    mods: Mods = .{},
    /// Set on an event the client synthesised because the key is being held.
    /// An application that is counting keystrokes, or that wants Backspace to
    /// repeat but not Enter, needs to be able to tell.
    repeat: bool = false,

    /// What the key typed, UTF-8. Empty for a named key and for any
    /// combination that types nothing.
    ///
    /// Control characters are not text and never appear here; the platform
    /// layer drops them. This matters more than it sounds: `xkbcommon`
    /// translates Ctrl+A to `\x01` and Enter to `\r`, so a field that inserted
    /// whatever arrived would quietly write control bytes into the document.
    text_buf: [text_capacity]u8 = @splat(0),
    text_len: u8 = 0,

    /// The codepoint this key produces with no modifiers applied, as the
    /// layout says -- `a` for the A key whether Shift or Ctrl is held or not.
    /// Zero when the key produces no character at all. This is what an
    /// accelerator compares against.
    base: u21 = 0,

    pub fn text(self: *const KeyEvent) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    /// A typed character, for tests and for synthetic input.
    pub fn typed(s: []const u8) KeyEvent {
        var ev: KeyEvent = .{};
        _ = ev.setText(s);
        if (std.unicode.utf8Decode(s) catch null) |cp| ev.base = cp;
        return ev;
    }

    pub fn named(k: Key) KeyEvent {
        return .{ .key = k };
    }

    /// Returns false when `s` does not fit, leaving the text empty rather than
    /// truncating it. A truncated UTF-8 sequence is not text, and inserting
    /// half of one would put bytes in the document that are not valid UTF-8 at
    /// all -- which is a worse failure than a dropped keystroke.
    pub fn setText(self: *KeyEvent, s: []const u8) bool {
        if (s.len > text_capacity) return false;
        @memcpy(self.text_buf[0..s.len], s);
        self.text_len = @intCast(s.len);
        return true;
    }

    pub fn withMods(self: KeyEvent, m: Mods) KeyEvent {
        var ev = self;
        ev.mods = m;
        return ev;
    }
};

/// A fixed-size ring of pending keystrokes.
///
/// Fixed size and no allocator, because it is filled from inside a libwayland
/// listener: that callback has no way to report an allocation failure and no
/// safe place to unwind to. So the queue cannot fail -- but it can fill, and
/// when it does it **counts** what it dropped rather than overwriting silently.
/// A text field that loses a keystroke without anyone knowing is the hardest
/// class of bug to believe a report of; a counter that says "3 dropped" is a
/// bug report.
///
/// Sixty-four events is about a second of the fastest key repeat a compositor
/// offers, so the only way to fill it is to stop draining it.
pub fn Ring(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        events: [capacity]KeyEvent = @splat(.{}),
        head: usize = 0,
        count: usize = 0,
        /// Keystrokes the queue had no room for. Never reset by the queue.
        dropped: u32 = 0,

        pub fn push(self: *Self, ev: KeyEvent) void {
            if (self.count == capacity) {
                self.dropped += 1;
                return;
            }
            self.events[(self.head + self.count) % capacity] = ev;
            self.count += 1;
        }

        pub fn pop(self: *Self) ?KeyEvent {
            if (self.count == 0) return null;
            const ev = self.events[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            return ev;
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.count = 0;
        }
    };
}

pub const Queue = Ring(64);

// ---------------------------------------------------------------------- tests

const testing = std.testing;

test "a typed event carries its text and its base character" {
    const ev = KeyEvent.typed("a");
    try testing.expectEqualStrings("a", ev.text());
    try testing.expectEqual(@as(u21, 'a'), ev.base);
    try testing.expectEqual(Key.none, ev.key);
}

test "base survives a multi-byte character" {
    const ev = KeyEvent.typed("ế");
    try testing.expectEqualStrings("ế", ev.text());
    try testing.expectEqual(@as(u21, 0x1EBF), ev.base);
}

test "text that does not fit is refused rather than truncated" {
    var ev: KeyEvent = .{};
    try testing.expect(ev.setText("0123456789abcdef"));
    try testing.expectEqual(@as(u8, 16), ev.text_len);

    var too_long: KeyEvent = .{};
    try testing.expect(!too_long.setText("0123456789abcdefg"));
    try testing.expectEqual(@as(u8, 0), too_long.text_len);
}

test "the ring keeps order and counts what it drops" {
    var q = Ring(4){};
    try testing.expectEqual(@as(?KeyEvent, null), q.pop());

    for ("abcd") |ch| q.push(KeyEvent.typed(&.{ch}));
    try testing.expectEqual(@as(usize, 4), q.len());

    // One too many: dropped, not written over the oldest.
    q.push(KeyEvent.typed("e"));
    try testing.expectEqual(@as(u32, 1), q.dropped);

    for ("abcd") |ch| {
        const ev = q.pop().?;
        try testing.expectEqualStrings(&.{ch}, ev.text());
    }
    try testing.expectEqual(@as(?KeyEvent, null), q.pop());

    // And it wraps: the indices moved, the capacity did not.
    for ("wxyz") |ch| q.push(KeyEvent.typed(&.{ch}));
    try testing.expectEqualStrings("w", q.pop().?.text());
    try testing.expectEqual(@as(u32, 1), q.dropped);
}

test "caps lock and num lock are not accelerator modifiers" {
    try testing.expect(!(Mods{ .caps_lock = true, .num_lock = true }).anyAccel());
    try testing.expect((Mods{ .ctrl = true }).anyAccel());
    try testing.expect((Mods{ .alt = true }).anyAccel());
    try testing.expect((Mods{ .logo = true }).anyAccel());
    try testing.expect(!(Mods{ .shift = true }).anyAccel());
}
