//! Spike B: can a self-drawn text field get *correct* IME on Linux, from Zig?
//!
//! The design note in docs/native-vs-drawn.md commits this project to drawing
//! its own widgets while speaking the platform's input protocols. That makes
//! tier A load-bearing: if IME is merely adequate, the argument for self-drawn
//! widgets collapses, because an imitation without native semantics is strictly
//! worse than the native widget it imitates.
//!
//! Nobody has done this in Zig, so it is the risk most likely to kill the
//! project, and it is cheaper to find out now than after a widget library
//! exists.
//!
//! WHAT THIS DELIBERATELY DOES NOT DO: draw text. The window is a solid colour.
//! Rendering a text field is known-solvable -- run 8 already measured HarfBuzz
//! shaping at 56 ns/char -- and it is not the risk. The risk is whether the
//! protocol state machine can be driven correctly, so the document state is
//! dumped to the terminal where it can be checked character by character.
//!
//! WHY VIETNAMESE IS THE TEST CASE, and not a convenience: Telex composes
//! diacritics by *retroactively rewriting* letters already typed. `a` then `w`
//! becomes `ă`; `a` `w` `s` becomes `ắ`. That exercises the two things
//! implementations get wrong:
//!
//!   1. `delete_surrounding_text` lengths are in BYTES, not codepoints or
//!      characters. `ă` is two bytes. An implementation that treats them as
//!      characters appears to work in ASCII and corrupts text the moment a
//!      diacritic appears.
//!   2. Preedit must be rendered at the cursor but must NOT be part of the
//!      document, and must not be included in `set_surrounding_text`. Mixing
//!      them up produces doubled characters that only show up mid-composition.
//!
//! Both bugs are invisible to an English-only test. Chinese and Japanese add a
//! candidate window, which is a UI problem; Vietnamese isolates the protocol
//! problem, which is the harder one to get right and the one that silently
//! corrupts data.
//!
//! Protocol: zwp_text_input_v3. On Wayland the client never talks to ibus or
//! fcitx directly -- the compositor mediates -- so this is the whole surface
//! area for Wayland IME. X11 (XIM, or ibus over DBus) is a separate problem and
//! is not covered here.

const std = @import("std");
const c = @import("c");

// ---------------------------------------------------------------- text buffer

/// Fixed storage. A spike's text field is short, and Zig 0.17 reworked
/// `std.ArrayList` to be unmanaged with a different `init`; avoiding it keeps
/// this file about IME rather than about allocator API churn.
const DOC_CAP = 4096;
const PREEDIT_CAP = 512;

/// The editable text. Offsets are BYTE offsets throughout, matching the
/// protocol. Mixing byte and codepoint offsets is the single most common way to
/// corrupt non-ASCII text, so there is exactly one unit here.
const Doc = struct {
    buf: [DOC_CAP]u8 = undefined,
    len: usize = 0,
    /// Insertion point, in bytes.
    cursor: usize = 0,

    fn text(self: *const Doc) []const u8 {
        return self.buf[0..self.len];
    }

    fn insert(self: *Doc, s: []const u8) void {
        if (s.len == 0) return;
        if (self.len + s.len > DOC_CAP) {
            std.debug.print("  !! doc full, dropping insert of {d} bytes\n", .{s.len});
            return;
        }
        // shift the tail right
        std.mem.copyBackwards(
            u8,
            self.buf[self.cursor + s.len .. self.len + s.len],
            self.buf[self.cursor..self.len],
        );
        @memcpy(self.buf[self.cursor..][0..s.len], s);
        self.len += s.len;
        self.cursor += s.len;
    }

    /// Deletes `before` bytes before the cursor and `after` bytes after it, as
    /// `delete_surrounding_text` specifies. Clamped to UTF-8 boundaries: the
    /// compositor should already send boundary-aligned lengths, but a malformed
    /// length must not be allowed to split a codepoint and poison the buffer.
    fn deleteSurrounding(self: *Doc, before: usize, after: usize) void {
        var b = @min(before, self.cursor);
        var a = @min(after, self.len - self.cursor);
        while (b > 0 and !isBoundary(self.buf[0..self.len], self.cursor - b)) b -= 1;
        while (a > 0 and !isBoundary(self.buf[0..self.len], self.cursor + a)) a -= 1;
        if (b != before or a != after) std.debug.print(
            "  !! delete_surrounding_text({d},{d}) snapped to ({d},{d}) at UTF-8 boundary\n",
            .{ before, after, b, a },
        );
        if (b == 0 and a == 0) return;
        const from = self.cursor + a;
        const to = self.cursor - b;
        std.mem.copyForwards(u8, self.buf[to..], self.buf[from..self.len]);
        self.len -= b + a;
        self.cursor = to;
    }

    fn backspace(self: *Doc) void {
        if (self.cursor == 0) return;
        var n: usize = 1;
        while (n < self.cursor and !isBoundary(self.buf[0..self.len], self.cursor - n)) n += 1;
        self.deleteSurrounding(n, 0);
    }

    fn moveLeft(self: *Doc) void {
        if (self.cursor == 0) return;
        var n: usize = 1;
        while (n < self.cursor and !isBoundary(self.buf[0..self.len], self.cursor - n)) n += 1;
        self.cursor -= n;
    }

    fn moveRight(self: *Doc) void {
        if (self.cursor >= self.len) return;
        var n: usize = 1;
        while (self.cursor + n < self.len and !isBoundary(self.buf[0..self.len], self.cursor + n)) n += 1;
        self.cursor += n;
    }
};

fn isBoundary(s: []const u8, i: usize) bool {
    if (i == 0 or i >= s.len) return true;
    return (s[i] & 0xC0) != 0x80;
}

fn countCodepoints(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// The in-flight composition. Rendered at the cursor, never part of the
/// document, never sent back as surrounding text.
const Preedit = struct {
    buf: [PREEDIT_CAP]u8 = undefined,
    len: usize = 0,
    /// Byte offsets into the preedit marking where the IME wants the cursor.
    /// -1 means "hide the cursor", which the protocol allows.
    cursor_begin: i32 = 0,
    cursor_end: i32 = 0,

    fn text(self: *const Preedit) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Preedit, s: []const u8, cb: i32, ce: i32) void {
        self.len = @min(s.len, PREEDIT_CAP);
        @memcpy(self.buf[0..self.len], s[0..self.len]);
        self.cursor_begin = cb;
        self.cursor_end = ce;
    }

    fn clear(self: *Preedit) void {
        self.len = 0;
        self.cursor_begin = 0;
        self.cursor_end = 0;
    }
};

/// Events arriving between `done` events are PENDING, not applied. The protocol
/// is explicitly double-buffered, and applying each event as it arrives is the
/// bug that produces flicker and doubled characters during composition.
const Pending = struct {
    has_preedit: bool = false,
    pre: [PREEDIT_CAP]u8 = undefined,
    pre_len: usize = 0,
    pre_cb: i32 = 0,
    pre_ce: i32 = 0,

    has_commit: bool = false,
    com: [PREEDIT_CAP]u8 = undefined,
    com_len: usize = 0,

    del_before: u32 = 0,
    del_after: u32 = 0,

    fn clear(self: *Pending) void {
        self.has_preedit = false;
        self.pre_len = 0;
        self.pre_cb = 0;
        self.pre_ce = 0;
        self.has_commit = false;
        self.com_len = 0;
        self.del_before = 0;
        self.del_after = 0;
    }
};

// --------------------------------------------------------------------- state

const App = struct {
    // wayland globals
    display: ?*c.struct_wl_display = null,
    registry: ?*c.struct_wl_registry = null,
    compositor: ?*c.struct_wl_compositor = null,
    shm: ?*c.struct_wl_shm = null,
    wm_base: ?*c.struct_xdg_wm_base = null,
    seat: ?*c.struct_wl_seat = null,
    ti_mgr: ?*c.struct_zwp_text_input_manager_v3 = null,

    surface: ?*c.struct_wl_surface = null,
    xdg_surface: ?*c.struct_xdg_surface = null,
    toplevel: ?*c.struct_xdg_toplevel = null,
    keyboard: ?*c.struct_wl_keyboard = null,
    text_input: ?*c.struct_zwp_text_input_v3 = null,

    // xkb, for keys the IME does not consume
    xkb_ctx: ?*c.struct_xkb_context = null,
    xkb_keymap: ?*c.struct_xkb_keymap = null,
    xkb_state: ?*c.struct_xkb_state = null,

    doc: Doc = .{},
    preedit: Preedit = .{},
    pending: Pending = .{},

    /// Number of `commit` requests sent. The `done` event echoes the serial of
    /// the commit the IME was responding to; a mismatch means the IME computed
    /// against surrounding text that is now stale.
    commit_serial: u32 = 0,
    focused: bool = false,
    ime_active: bool = false,
    running: bool = true,
    configured: bool = false,
    probe_only: bool = false,
    /// Resync attempts. An unconditional resync on `done` is an infinite loop;
    /// see applyPending.
    n_sendstate: u32 = 0,
    /// Suppresses the per-transaction trace. The self test drives hundreds of
    /// transactions and the trace is for a human watching one.
    quiet: bool = false,

    // observed-behaviour tally, printed on exit
    n_preedit: u32 = 0,
    n_commit: u32 = 0,
    n_delete: u32 = 0,
    n_done: u32 = 0,
    n_stale: u32 = 0,
    max_del_before: u32 = 0,

    fn dumpDoc(self: *App, tag: []const u8) void {
        const d = &self.doc;
        vlog("  [{s}] doc=\"{s}\" | cursor={d}B ({d}cp)", .{
            tag,
            d.text(),
            d.cursor,
            countCodepoints(d.buf[0..d.cursor]),
        });
        if (self.preedit.len > 0) {
            vlog(" | preedit=\"{s}\" cur={d}..{d}", .{
                self.preedit.text(),
                self.preedit.cursor_begin,
                self.preedit.cursor_end,
            });
        }
        vlog(" | {d}B {d}cp\n", .{ d.len, countCodepoints(d.text()) });
    }

    /// Tells the IME what the text around the cursor is, and where the cursor is
    /// on screen so a candidate window can be placed.
    ///
    /// `set_surrounding_text` must NOT include the preedit, and the cursor and
    /// anchor offsets are byte offsets *into the string actually sent*. The
    /// protocol caps the string at 4000 bytes, so a long document must send a
    /// window around the cursor with offsets rebased into it -- forgetting to
    /// rebase is a bug that only appears once the document grows.
    fn sendState(self: *App, cause: u32) void {
        // Counted BEFORE the null check so the self test can assert how many
        // resyncs were attempted without a compositor attached.
        self.n_sendstate += 1;
        const ti = self.text_input orelse return;
        const d = &self.doc;

        const MAX = 2000;
        var start: usize = 0;
        var end: usize = d.len;
        if (d.len > MAX) {
            const half = MAX / 2;
            start = if (d.cursor > half) d.cursor - half else 0;
            end = @min(d.len, start + MAX);
            while (start > 0 and !isBoundary(d.text(), start)) start -= 1;
            while (end < d.len and !isBoundary(d.text(), end)) end += 1;
        }
        const slice = d.buf[start..end];
        const rel: i32 = @intCast(d.cursor - start);

        var tmp: [MAX + 1]u8 = undefined;
        @memcpy(tmp[0..slice.len], slice);
        tmp[slice.len] = 0;

        c.zwp_text_input_v3_set_surrounding_text(ti, &tmp, rel, rel);
        c.zwp_text_input_v3_set_text_change_cause(ti, cause);
        c.zwp_text_input_v3_set_content_type(
            ti,
            c.ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE,
            c.ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_NORMAL,
        );
        // A real toolkit computes this from the glyph position. The spike has no
        // text layout, so it reports a fixed box; the candidate window will be
        // placed at the window origin rather than at the caret.
        c.zwp_text_input_v3_set_cursor_rectangle(ti, 8, 8, 2, 20);
        c.zwp_text_input_v3_commit(ti);
        self.commit_serial += 1;
    }

    /// Applies one IME transaction, in the order text-input-v3 specifies:
    ///   1. drop the old preedit (it was never in the document)
    ///   2. delete the requested surrounding text
    ///   3. insert the commit string, cursor at its end
    ///   4. recompute surrounding text
    ///   5. install the new preedit
    ///
    /// Doing 2 and 3 in the other order is the bug that makes Telex eat the
    /// wrong character: ibus-bamboo asks to delete what is already committed
    /// *before* committing the replacement.
    fn applyPending(self: *App, serial: u32) void {
        self.n_done += 1;
        const stale = serial != self.commit_serial;
        if (stale) {
            self.n_stale += 1;
            vlog(
                "  .. done(serial={d}) != our commit count {d}: IME saw stale surrounding text\n",
                .{ serial, self.commit_serial },
            );
        }

        const p = &self.pending;
        const had_preedit = self.preedit.len > 0;
        // Only a change to the DOCUMENT requires re-sending surrounding text.
        // Resyncing on every `done` is an infinite loop, because our own
        // `commit` makes the compositor emit another `done`: the first version
        // of this spike spun at full speed on an empty document. A preedit
        // change must NOT trigger a resync -- preedit is not part of
        // surrounding text, so there is nothing new to tell the IME.
        var doc_changed = false;
        var anything = false;

        // 1. the old preedit is discarded; it never entered the document
        self.preedit.clear();

        // 2. delete surrounding text, in bytes
        if (p.del_before != 0 or p.del_after != 0) {
            self.n_delete += 1;
            self.max_del_before = @max(self.max_del_before, p.del_before);
            vlog("  <- delete_surrounding_text(before={d}B, after={d}B)\n", .{
                p.del_before, p.del_after,
            });
            self.doc.deleteSurrounding(p.del_before, p.del_after);
            doc_changed = true;
            anything = true;
        }

        // 3. insert the commit string
        if (p.has_commit and p.com_len > 0) {
            self.n_commit += 1;
            vlog("  <- commit_string(\"{s}\") {d}B {d}cp\n", .{
                p.com[0..p.com_len],
                p.com_len,
                countCodepoints(p.com[0..p.com_len]),
            });
            self.doc.insert(p.com[0..p.com_len]);
            doc_changed = true;
            anything = true;
        }

        // 5. install the new preedit
        if (p.has_preedit and p.pre_len > 0) {
            self.n_preedit += 1;
            vlog("  <- preedit_string(\"{s}\") cursor={d}..{d}\n", .{
                p.pre[0..p.pre_len], p.pre_cb, p.pre_ce,
            });
            self.preedit.set(p.pre[0..p.pre_len], p.pre_cb, p.pre_ce);
            anything = true;
        } else if (had_preedit) {
            vlog("  <- preedit cleared\n", .{});
            anything = true;
        }

        p.clear();
        if (anything) self.dumpDoc("doc");
        // 4. tell the IME the new surrounding text -- but only if the document
        // actually moved. See `doc_changed`.
        if (doc_changed) self.sendState(c.ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_INPUT_METHOD);
    }
};

var app: App = .{};

/// The per-transaction trace, silenced during the self test.
fn vlog(comptime fmt: []const u8, args: anytype) void {
    if (app.quiet) return;
    std.debug.print(fmt, args);
}

// ------------------------------------------------------------------ self test
//
// ibus-bamboo's default mode keeps the whole syllable in the preedit and never
// rewrites committed text, so `delete_surrounding_text` was called ZERO times
// across the real session. The byte-length hazard this spike was built to catch
// therefore went untested by typing -- exactly the position spike E was in with
// its queued lock.
//
// This drives the four event handlers directly, with no compositor, and asserts
// the document that comes out. It reaches the paths typing could not.
//
// It proves the document model, not that a compositor drives it that way. The
// real session (logs/session-01) is what proves the latter, and it is the one
// that found the resync infinite loop.

var t_pass: u32 = 0;
var t_fail: u32 = 0;

fn check(cond: bool, comptime what: []const u8) void {
    if (cond) {
        t_pass += 1;
        std.debug.print("  PASS  {s}\n", .{what});
    } else {
        t_fail += 1;
        std.debug.print("  FAIL  {s}\n", .{what});
    }
}

fn checkDoc(want: []const u8, comptime what: []const u8) void {
    const got = app.doc.text();
    const ok = std.mem.eql(u8, got, want);
    if (!ok) std.debug.print("        want \"{s}\" got \"{s}\"\n", .{ want, got });
    check(ok, what);
}

/// One IME transaction, the way the compositor would deliver it.
const Txn = struct {
    preedit: ?[]const u8 = null,
    pre_cb: i32 = 0,
    pre_ce: i32 = 0,
    commit: ?[]const u8 = null,
    del_before: u32 = 0,
    del_after: u32 = 0,
};

fn feed(t: Txn) void {
    if (t.preedit) |pz| {
        var buf: [PREEDIT_CAP]u8 = undefined;
        @memcpy(buf[0..pz.len], pz);
        buf[pz.len] = 0;
        tiPreedit(null, null, &buf, t.pre_cb, t.pre_ce);
    }
    if (t.commit) |cz| {
        var buf: [PREEDIT_CAP]u8 = undefined;
        @memcpy(buf[0..cz.len], cz);
        buf[cz.len] = 0;
        tiCommit(null, null, &buf);
    }
    if (t.del_before != 0 or t.del_after != 0) {
        tiDelete(null, null, t.del_before, t.del_after);
    }
    // The serial is matched so no stale-serial warning fires.
    tiDone(null, null, app.commit_serial);
}

fn resetDoc() void {
    app.doc = .{};
    app.preedit.clear();
    app.pending.clear();
    app.commit_serial = 0;
    app.n_sendstate = 0;
}

fn selfTest() void {
    app.quiet = true;
    std.debug.print("--- document model self test ---\n\n", .{});

    // 1 -- preedit must never reach the document
    resetDoc();
    feed(.{ .preedit = "a", .pre_cb = 1, .pre_ce = 1 });
    checkDoc("", "a preedit leaves the document empty");
    check(std.mem.eql(u8, app.preedit.text(), "a"), "the preedit is held separately");
    feed(.{ .preedit = "ă", .pre_cb = 2, .pre_ce = 2 });
    checkDoc("", "a changed preedit still leaves the document empty");

    // 2 -- a preedit-only transaction must NOT resync. This is the bug that
    //      span at full speed: our commit makes the compositor send done again.
    resetDoc();
    app.n_sendstate = 0;
    feed(.{ .preedit = "x" });
    check(app.n_sendstate == 0, "a preedit-only change triggers no resync");
    feed(.{ .commit = "x" });
    check(app.n_sendstate == 1, "a document change triggers exactly one resync");

    // 3 -- commit lands, preedit clears
    resetDoc();
    feed(.{ .preedit = "ă", .pre_cb = 2, .pre_ce = 2 });
    feed(.{ .commit = "ă" });
    checkDoc("ă", "the commit string enters the document");
    check(app.preedit.len == 0, "the preedit is cleared by the commit");
    check(app.doc.cursor == 2, "the cursor is in BYTES, past a 2-byte char");

    // 4 -- THE TELEX CASE, and the whole reason this spike exists.
    //      delete_surrounding_text lengths are BYTES. Deleting the committed
    //      "a" must take 1 byte, and the replacement is 2 bytes.
    resetDoc();
    feed(.{ .commit = "a" });
    checkDoc("a", "plain 'a' committed");
    feed(.{ .del_before = 1, .commit = "ă" });
    checkDoc("ă", "delete 1 BYTE then commit 2 bytes leaves exactly \"ă\"");
    check(app.doc.len == 2, "the document is 2 bytes");
    check(countCodepoints(app.doc.text()) == 1, "...and 1 codepoint");

    // 5 -- the order is fixed: DELETE happens before the commit is inserted.
    //      Doing it the other way round eats the wrong character.
    resetDoc();
    feed(.{ .commit = "xy" });
    feed(.{ .del_before = 1, .commit = "Z" });
    checkDoc("xZ", "delete-then-insert, not insert-then-delete");

    // 6 -- a multi-byte delete: "ế" is 3 bytes
    resetDoc();
    feed(.{ .commit = "tiế" });
    check(app.doc.len == 5, "\"tiế\" is 5 bytes");
    feed(.{ .del_before = 3, .commit = "ê" });
    checkDoc("tiê", "deleting 3 bytes removes exactly one 3-byte character");

    // 7 -- a length that would SPLIT a character must snap, not corrupt.
    //      The compositor should never send this; if it does, the document
    //      must survive it.
    resetDoc();
    feed(.{ .commit = "ă" });
    feed(.{ .del_before = 1 });
    check(app.doc.len == 0 or app.doc.len == 2, "a split-mid-character delete did not corrupt the buffer");
    check(std.unicode.utf8ValidateSlice(app.doc.text()), "the document is still valid UTF-8");

    // 8 -- delete AFTER the cursor as well as before
    resetDoc();
    feed(.{ .commit = "abcd" });
    app.doc.cursor = 2;
    feed(.{ .del_before = 1, .del_after = 1 });
    checkDoc("ad", "delete_surrounding_text removes on both sides of the cursor");

    // 9 -- surrounding text must be a window with REBASED offsets once the
    //      document exceeds the protocol's limit. Without a compositor the
    //      send is a no-op, so this asserts the document survives a long
    //      build-up and the cursor stays in bounds.
    resetDoc();
    var i: usize = 0;
    while (i < 700) : (i += 1) feed(.{ .commit = "ếu" });
    check(app.doc.len > 2000, "the document grew past the 2000-byte window");
    check(app.doc.cursor == app.doc.len, "the cursor tracked to the end");
    check(std.unicode.utf8ValidateSlice(app.doc.text()), "a long multi-byte document is valid UTF-8");

    std.debug.print("\n  {d} passed, {d} failed\n", .{ t_pass, t_fail });
    std.debug.print(
        "\n  NOTE: this proves the document model, not that a compositor drives\n" ++
            "  it this way. ibus-bamboo never sent delete_surrounding_text.\n",
        .{},
    );
}

// ----------------------------------------------------------- text-input-v3

fn tiEnter(_: ?*anyopaque, ti: ?*c.struct_zwp_text_input_v3, _: ?*c.struct_wl_surface) callconv(.c) void {
    app.focused = true;
    std.debug.print("\n[focus] surface gained keyboard focus -> enabling input context\n", .{});
    // `enable` is what makes the compositor route composition to us. Without
    // the following `commit` it has no effect: every text-input-v3 request is
    // double-buffered and applied only on commit.
    c.zwp_text_input_v3_enable(ti);
    app.ime_active = true;
    app.sendState(c.ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_OTHER);
}

fn tiLeave(_: ?*anyopaque, ti: ?*c.struct_zwp_text_input_v3, _: ?*c.struct_wl_surface) callconv(.c) void {
    app.focused = false;
    app.ime_active = false;
    std.debug.print("[focus] lost focus -> disabling input context\n", .{});
    c.zwp_text_input_v3_disable(ti);
    c.zwp_text_input_v3_commit(ti);
    app.commit_serial += 1;
}

fn tiPreedit(
    _: ?*anyopaque,
    _: ?*c.struct_zwp_text_input_v3,
    text: [*c]const u8,
    cursor_begin: i32,
    cursor_end: i32,
) callconv(.c) void {
    const p = &app.pending;
    p.has_preedit = true;
    p.pre_len = 0;
    if (text != null) {
        const s = std.mem.span(text);
        p.pre_len = @min(s.len, PREEDIT_CAP);
        @memcpy(p.pre[0..p.pre_len], s[0..p.pre_len]);
    }
    p.pre_cb = cursor_begin;
    p.pre_ce = cursor_end;
}

fn tiCommit(_: ?*anyopaque, _: ?*c.struct_zwp_text_input_v3, text: [*c]const u8) callconv(.c) void {
    const p = &app.pending;
    p.has_commit = true;
    p.com_len = 0;
    if (text != null) {
        const s = std.mem.span(text);
        p.com_len = @min(s.len, PREEDIT_CAP);
        @memcpy(p.com[0..p.com_len], s[0..p.com_len]);
    }
}

fn tiDelete(
    _: ?*anyopaque,
    _: ?*c.struct_zwp_text_input_v3,
    before_length: u32,
    after_length: u32,
) callconv(.c) void {
    app.pending.del_before = before_length;
    app.pending.del_after = after_length;
}

fn tiDone(_: ?*anyopaque, _: ?*c.struct_zwp_text_input_v3, serial: u32) callconv(.c) void {
    app.applyPending(serial);
}

const ti_listener = c.struct_zwp_text_input_v3_listener{
    .enter = tiEnter,
    .leave = tiLeave,
    .preedit_string = tiPreedit,
    .commit_string = tiCommit,
    .delete_surrounding_text = tiDelete,
    .done = tiDone,
};

// ------------------------------------------------------------------ keyboard

fn kbKeymap(
    _: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    format: u32,
    fd: i32,
    size: u32,
) callconv(.c) void {
    defer _ = std.os.linux.close(fd);
    if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;
    const map = std.posix.mmap(
        null,
        size,
        .{ .READ = true }, // PROT became a packed struct of bools in 0.17
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ) catch return;
    defer std.posix.munmap(map);
    const km = c.xkb_keymap_new_from_string(
        app.xkb_ctx,
        @ptrCast(map.ptr),
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return;
    if (app.xkb_state) |s| c.xkb_state_unref(s);
    if (app.xkb_keymap) |k| c.xkb_keymap_unref(k);
    app.xkb_keymap = km;
    app.xkb_state = c.xkb_state_new(km);
}

/// Keys the IME did not consume arrive here. With an IME active this is the
/// minority path, but it is the one that must handle Backspace and the arrow
/// keys -- and a text field that cannot move its own cursor cannot report
/// correct surrounding text, which then breaks the IME.
fn kbKey(
    _: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    _: u32,
    _: u32,
    key: u32,
    state: u32,
) callconv(.c) void {
    if (state != c.WL_KEYBOARD_KEY_STATE_PRESSED) return;
    // An ordering hazard the first session never reached: a raw key arriving
    // while a preedit is pending. The IME normally consumes keys during
    // composition, so this path should be unreachable then -- but if it is
    // reached, inserting into the document behind a live preedit interleaves
    // two writers and corrupts the text. Surfaced rather than silently handled,
    // because the correct recovery (commit the preedit, or cancel it) depends
    // on which key it is, and guessing here would hide the problem.
    if (app.preedit.len > 0) {
        std.debug.print(
            "  !! raw key while preedit=\"{s}\" is live -- two writers to one document\n",
            .{app.preedit.text()},
        );
    }
    const xkb_state = app.xkb_state orelse return;
    const code = key + 8; // evdev -> xkb keycode
    const sym = c.xkb_state_key_get_one_sym(xkb_state, code);

    switch (sym) {
        c.XKB_KEY_Escape => {
            app.running = false;
            return;
        },
        c.XKB_KEY_BackSpace => {
            std.debug.print("[key ] BackSpace (not consumed by IME)\n", .{});
            app.doc.backspace();
            app.dumpDoc("doc");
            app.sendState(c.ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_OTHER);
            return;
        },
        c.XKB_KEY_Left => {
            app.doc.moveLeft();
            app.dumpDoc("doc");
            app.sendState(c.ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_OTHER);
            return;
        },
        c.XKB_KEY_Right => {
            app.doc.moveRight();
            app.dumpDoc("doc");
            app.sendState(c.ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_OTHER);
            return;
        },
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => {
            std.debug.print("[key ] Return\n", .{});
            app.doc.insert("\n");
            app.dumpDoc("doc");
            app.sendState(c.ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_OTHER);
            return;
        },
        else => {},
    }

    var buf: [16]u8 = undefined;
    const n = c.xkb_state_key_get_utf8(xkb_state, code, &buf, buf.len);
    if (n > 0) {
        const s = buf[0..@intCast(n)];
        if (s.len == 1 and (s[0] < 0x20)) return;
        std.debug.print("[key ] \"{s}\" direct (IME did not consume)\n", .{s});
        app.doc.insert(s);
        app.dumpDoc("doc");
        app.sendState(c.ZWP_TEXT_INPUT_V3_CHANGE_CAUSE_OTHER);
    }
}

fn kbModifiers(
    _: ?*anyopaque,
    _: ?*c.struct_wl_keyboard,
    _: u32,
    depressed: u32,
    latched: u32,
    locked: u32,
    group: u32,
) callconv(.c) void {
    if (app.xkb_state) |s| {
        _ = c.xkb_state_update_mask(s, depressed, latched, locked, 0, 0, group);
    }
}

fn kbEnter(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: ?*c.struct_wl_surface, _: [*c]c.struct_wl_array) callconv(.c) void {}
fn kbLeave(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: u32, _: ?*c.struct_wl_surface) callconv(.c) void {}
fn kbRepeat(_: ?*anyopaque, _: ?*c.struct_wl_keyboard, _: i32, _: i32) callconv(.c) void {}

const kb_listener = c.struct_wl_keyboard_listener{
    .keymap = kbKeymap,
    .enter = kbEnter,
    .leave = kbLeave,
    .key = kbKey,
    .modifiers = kbModifiers,
    .repeat_info = kbRepeat,
};

fn seatCaps(_: ?*anyopaque, seat: ?*c.struct_wl_seat, caps: u32) callconv(.c) void {
    if ((caps & c.WL_SEAT_CAPABILITY_KEYBOARD) != 0 and app.keyboard == null) {
        app.keyboard = c.wl_seat_get_keyboard(seat);
        _ = c.wl_keyboard_add_listener(app.keyboard, &kb_listener, null);
    }
}
fn seatName(_: ?*anyopaque, _: ?*c.struct_wl_seat, _: [*c]const u8) callconv(.c) void {}

const seat_listener = c.struct_wl_seat_listener{ .capabilities = seatCaps, .name = seatName };

// --------------------------------------------------------------------- shell

fn xdgPing(_: ?*anyopaque, base: ?*c.struct_xdg_wm_base, serial: u32) callconv(.c) void {
    c.xdg_wm_base_pong(base, serial);
}
const wm_base_listener = c.struct_xdg_wm_base_listener{ .ping = xdgPing };

fn xdgSurfConfigure(_: ?*anyopaque, surf: ?*c.struct_xdg_surface, serial: u32) callconv(.c) void {
    c.xdg_surface_ack_configure(surf, serial);
    app.configured = true;
}
const xdg_surface_listener = c.struct_xdg_surface_listener{ .configure = xdgSurfConfigure };

fn tlConfigure(_: ?*anyopaque, _: ?*c.struct_xdg_toplevel, _: i32, _: i32, _: [*c]c.struct_wl_array) callconv(.c) void {}
fn tlClose(_: ?*anyopaque, _: ?*c.struct_xdg_toplevel) callconv(.c) void {
    app.running = false;
}
fn tlBounds(_: ?*anyopaque, _: ?*c.struct_xdg_toplevel, _: i32, _: i32) callconv(.c) void {}
fn tlCaps(_: ?*anyopaque, _: ?*c.struct_xdg_toplevel, _: [*c]c.struct_wl_array) callconv(.c) void {}

const toplevel_listener = c.struct_xdg_toplevel_listener{
    .configure = tlConfigure,
    .close = tlClose,
    .configure_bounds = tlBounds,
    .wm_capabilities = tlCaps,
};

// ------------------------------------------------------------------ registry

fn regGlobal(
    _: ?*anyopaque,
    reg: ?*c.struct_wl_registry,
    name: u32,
    iface: [*c]const u8,
    _: u32,
) callconv(.c) void {
    const s = std.mem.span(iface);
    if (std.mem.eql(u8, s, "wl_compositor")) {
        app.compositor = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_compositor_interface, 4));
    } else if (std.mem.eql(u8, s, "wl_shm")) {
        app.shm = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_shm_interface, 1));
    } else if (std.mem.eql(u8, s, "xdg_wm_base")) {
        app.wm_base = @ptrCast(c.wl_registry_bind(reg, name, &c.xdg_wm_base_interface, 1));
        _ = c.xdg_wm_base_add_listener(app.wm_base, &wm_base_listener, null);
    } else if (std.mem.eql(u8, s, "wl_seat")) {
        app.seat = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_seat_interface, 5));
        _ = c.wl_seat_add_listener(app.seat, &seat_listener, null);
    } else if (std.mem.eql(u8, s, "zwp_text_input_manager_v3")) {
        app.ti_mgr = @ptrCast(c.wl_registry_bind(reg, name, &c.zwp_text_input_manager_v3_interface, 1));
    }
}
fn regRemove(_: ?*anyopaque, _: ?*c.struct_wl_registry, _: u32) callconv(.c) void {}

const registry_listener = c.struct_wl_registry_listener{ .global = regGlobal, .global_remove = regRemove };

// -------------------------------------------------------------------- buffer

const W = 720;
const H = 180;

fn makeBuffer() ?*c.struct_wl_buffer {
    const stride = W * 4;
    const size: usize = stride * H;
    const fd = std.posix.memfd_create("zig-uikit-ime", 0) catch return null;
    defer _ = std.os.linux.close(fd);
    if (std.os.linux.ftruncate(fd, size) != 0) return null;
    const mem = std.posix.mmap(
        null,
        size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    ) catch return null;
    // Solid colour. This spike does not draw text; see the header.
    const px: []u32 = @alignCast(std.mem.bytesAsSlice(u32, mem));
    @memset(px, 0xff1e1e2e);
    const pool = c.wl_shm_create_pool(app.shm, fd, @intCast(size));
    const buf = c.wl_shm_pool_create_buffer(pool, 0, W, H, stride, c.WL_SHM_FORMAT_ARGB8888);
    c.wl_shm_pool_destroy(pool);
    return buf;
}

// ---------------------------------------------------------------------- main

/// Zig 0.17 removed BOTH `std.process.args()` and `std.os.argv`. Arguments now
/// reach the program by declaring `main` to take `std.process.Init.Minimal`,
/// which carries the argument vector and the environment block. That is the
/// idiomatic form, and it needs no allocator.
pub fn main(init: std.process.Init.Minimal) !void {
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.next(); // argv[0]
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--probe")) app.probe_only = true;
        if (std.mem.eql(u8, a, "--selftest")) {
            selfTest();
            return;
        }
    }

    app.display = c.wl_display_connect(null) orelse {
        std.debug.print("cannot connect to a Wayland display (WAYLAND_DISPLAY set?)\n", .{});
        return error.NoDisplay;
    };
    app.registry = c.wl_display_get_registry(app.display);
    _ = c.wl_registry_add_listener(app.registry, &registry_listener, null);
    _ = c.wl_display_roundtrip(app.display);

    std.debug.print("globals:\n", .{});
    std.debug.print("  wl_compositor              {s}\n", .{if (app.compositor != null) "yes" else "NO"});
    std.debug.print("  wl_shm                     {s}\n", .{if (app.shm != null) "yes" else "NO"});
    std.debug.print("  xdg_wm_base                {s}\n", .{if (app.wm_base != null) "yes" else "NO"});
    std.debug.print("  wl_seat                    {s}\n", .{if (app.seat != null) "yes" else "NO"});
    std.debug.print("  zwp_text_input_manager_v3  {s}\n", .{if (app.ti_mgr != null) "yes" else "NO"});

    if (app.ti_mgr == null) {
        std.debug.print(
            "\nThis compositor does not advertise zwp_text_input_manager_v3.\n" ++
                "Wayland IME is impossible for any client here, not just this one.\n",
            .{},
        );
        return error.NoTextInput;
    }
    if (app.probe_only) {
        std.debug.print("\n--probe: protocol is available; exiting without opening a window.\n", .{});
        return;
    }

    app.xkb_ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);

    app.surface = c.wl_compositor_create_surface(app.compositor);
    app.xdg_surface = c.xdg_wm_base_get_xdg_surface(app.wm_base, app.surface);
    _ = c.xdg_surface_add_listener(app.xdg_surface, &xdg_surface_listener, null);
    app.toplevel = c.xdg_surface_get_toplevel(app.xdg_surface);
    _ = c.xdg_toplevel_add_listener(app.toplevel, &toplevel_listener, null);
    c.xdg_toplevel_set_title(app.toplevel, "zig-uikit IME spike - type here, Esc to quit");
    c.xdg_toplevel_set_app_id(app.toplevel, "dev.zig-uikit.ime-spike");
    c.wl_surface_commit(app.surface);
    _ = c.wl_display_roundtrip(app.display);

    const buf = makeBuffer() orelse return error.NoBuffer;
    c.wl_surface_attach(app.surface, buf, 0, 0);
    c.wl_surface_damage(app.surface, 0, 0, W, H);
    c.wl_surface_commit(app.surface);

    // One text_input per seat.
    app.text_input = c.zwp_text_input_manager_v3_get_text_input(app.ti_mgr, app.seat);
    _ = c.zwp_text_input_v3_add_listener(app.text_input, &ti_listener, null);
    _ = c.wl_display_roundtrip(app.display);

    std.debug.print(
        \\
        \\A window is open. Click it to focus, then type.
        \\
        \\  Vietnamese (Telex, ibus-bamboo):  aw -> a-breve     aws -> a-breve-acute
        \\                                    dd -> d-stroke    oo  -> o-circumflex
        \\  What to watch for:
        \\    - preedit_string arrives WITHOUT the document changing
        \\    - delete_surrounding_text lengths are BYTES; a diacritic is 2 bytes
        \\    - the doc line must show the same text your eyes expect, every step
        \\
        \\  Esc or close the window to finish.
        \\
    , .{});

    while (app.running) {
        if (c.wl_display_dispatch(app.display) < 0) break;
    }

    std.debug.print(
        \\
        \\--- observed ---
        \\  done events              {d}
        \\  preedit_string           {d}
        \\  commit_string            {d}
        \\  delete_surrounding_text  {d}  (largest before= {d} bytes)
        \\  stale-serial done        {d}
        \\  final doc                "{s}"  {d} bytes, {d} codepoints
        \\
    , .{
        app.n_done,
        app.n_preedit,
        app.n_commit,
        app.n_delete,
        app.max_del_before,
        app.n_stale,
        app.doc.text(),
        app.doc.len,
        countCodepoints(app.doc.text()),
    });
}
