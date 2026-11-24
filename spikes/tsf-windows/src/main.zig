//! Spike E: Windows IME via the Text Services Framework, from Zig.
//!
//! The last quarter of tier A, and the hardest. Spike B did Wayland IME with
//! `zwp_text_input_v3`: six client requests, six events, one state machine.
//! TSF asks the application to implement `ITextStoreACP` -- twenty-nine methods
//! -- plus a lock protocol, and to host a COM thread manager.
//!
//! Cross-compiled on Linux like spike D: Zig bundles mingw-w64's `msctf.h` and
//! `textstor.h`, so no MSVC and no Windows SDK are needed.
//!
//! THE FINDING THAT CHANGES THE TEXT FIELD'S DATA MODEL:
//!
//!   Wayland: preedit is a SEPARATE STRING. It never enters the document.
//!   Windows: composition text is WRITTEN INTO THE DOCUMENT by the TIP.
//!
//! On Wayland the compositor hands over `preedit_string` and the application
//! draws it at the caret while the document stays untouched -- spike B asserts
//! exactly that, and it held for every one of 28 preedit events.
//!
//! Under TSF the input processor takes a read/write lock on the text store and
//! calls `SetText` to put the composing characters *into the buffer*, then marks
//! that range with display attributes so the application underlines it. There is
//! no separate preedit string to render. The text is in the document, and it is
//! provisional.
//!
//! So a cross-platform text field cannot model composition as "a string beside
//! the document". It needs a document that can carry a provisional range, which
//! Wayland then simply never uses. Designing it the other way round -- Wayland
//! first, as spike B did -- produces a model that cannot represent what Windows
//! does.
//!
//! OFFSET UNITS, closing the loop from spikes B, C and D:
//!
//!   zwp_text_input_v3  ->  UTF-8 bytes
//!   AT-SPI             ->  codepoints
//!   Windows BSTR       ->  UTF-16 code units
//!   TSF "ACP"          ->  UTF-16 code units   <- this spike
//!
//! Application Character Position is UTF-16 code units, the same unit as a
//! BSTR. That makes Windows internally CONSISTENT: its accessibility and its
//! input method agree. Linux is not: `text-input-v3` counts bytes while AT-SPI
//! counts codepoints, so on Linux a text field must convert between its own two
//! platform protocols. One fewer conversion on Windows, and that asymmetry is
//! not something either platform's documentation points out.
//!
//! SCOPE: the twenty-nine ITextStoreACP methods (five of the embedded-object
//! ones return E_NOTIMPL), the lock protocol including re-entrant requests,
//! composition sink notifications, and a Win32 window. No rendering, no
//! underline for the composing range, no candidate window placement -- the
//! risk being tested is the protocol.

const std = @import("std");
const c = @import("c");

// ----------------------------------------------------------------- COM basics

const S_OK: c.HRESULT = 0;
const S_FALSE: c.HRESULT = 1;
const E_NOTIMPL: c.HRESULT = @bitCast(@as(u32, 0x8000_4001));
const E_NOINTERFACE: c.HRESULT = @bitCast(@as(u32, 0x8000_4002));
const E_POINTER: c.HRESULT = @bitCast(@as(u32, 0x8000_4003));
const E_INVALIDARG: c.HRESULT = @bitCast(@as(u32, 0x8007_0057));
const E_FAIL: c.HRESULT = @bitCast(@as(u32, 0x8000_4005));

/// translate-c cannot expand `MAKE_HRESULT`, so the TSF result codes come
/// through as @compileError and have to be computed here. The macro is
/// `(sev<<31) | (fac<<16) | code` with SEVERITY_ERROR=1, SEVERITY_SUCCESS=0 and
/// FACILITY_ITF=4; the `code` values are transcribed from textstor.h.
fn tsHr(comptime sev: u32, comptime code: u32) c.HRESULT {
    return @bitCast((sev << 31) | (4 << 16) | code);
}

const TS_E_INVALIDPOS = tsHr(1, 0x0200);
const TS_E_NOLOCK = tsHr(1, 0x0201);
const TS_E_NOLAYOUT = tsHr(1, 0x0206);
const TS_E_SYNCHRONOUS = tsHr(1, 0x0208);
const TS_S_ASYNC = tsHr(0, 0x0300);

comptime {
    std.debug.assert(@as(u32, @bitCast(TS_E_NOLOCK)) == 0x8004_0201);
    std.debug.assert(@as(u32, @bitCast(TS_S_ASYNC)) == 0x0004_0300);
}

fn guid(a: u32, b: u16, cc: u16, d: [8]u8) c.GUID {
    return .{ .Data1 = a, .Data2 = b, .Data3 = cc, .Data4 = d };
}

/// Transcribed from the DEFINE_GUID macros in the bundled mingw headers.
const IID_IUnknown = guid(0x00000000, 0x0000, 0x0000, .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 });
const IID_ITextStoreACP = guid(0x28888fe3, 0xc2a0, 0x483a, .{ 0xa3, 0xea, 0x8c, 0xb1, 0xce, 0x51, 0xff, 0x3d });
const IID_ITfContextOwnerCompositionSink = guid(0x5f20aa40, 0xb57a, 0x4f34, .{ 0x96, 0xab, 0x35, 0x76, 0xf3, 0x77, 0xcc, 0x79 });
const IID_ITfThreadMgr = guid(0xaa80e801, 0x2021, 0x11d2, .{ 0x93, 0xe0, 0x00, 0x60, 0xb0, 0x67, 0xb8, 0x6e });

/// NOT from the headers: mingw declares `CLSID_TF_ThreadMgr` as
/// `EXTERN_C const CLSID` and ships no library defining it, and unlike the IIDs
/// there is no DEFINE_GUID to transcribe. This is the documented value, and it
/// is checked at runtime -- a wrong CLSID fails CoCreateInstance with
/// REGDB_E_CLASSNOTREG, which the log below would show immediately. The test
/// run also reads the authoritative value out of the guest's registry to
/// confirm it.
const CLSID_TF_ThreadMgr = guid(0x529a9e6b, 0x6587, 0x4f23, .{ 0xab, 0x9e, 0x9c, 0x7d, 0x68, 0x3e, 0x3c, 0x50 });

fn sameGuid(a: [*c]const c.IID, b: *const c.GUID) bool {
    if (a == null) return false;
    return std.mem.eql(u8, std.mem.asBytes(&a.*), std.mem.asBytes(b));
}

fn hrName(hr: c.HRESULT) []const u8 {
    return switch (@as(u32, @bitCast(hr))) {
        0x0000_0000 => "S_OK",
        0x0000_0001 => "S_FALSE",
        0x8000_4001 => "E_NOTIMPL",
        0x8000_4002 => "E_NOINTERFACE",
        0x8000_4005 => "E_FAIL",
        0x8007_0057 => "E_INVALIDARG",
        0x8004_005F => "REGDB_E_CLASSNOTREG",
        else => "other",
    };
}

// ------------------------------------------------------------------- document

/// Everything here is in ACP: Application Character Position, which on Windows
/// means UTF-16 CODE UNITS. There is exactly one unit in this file, and the
/// only place another appears is `reportUnits`, which exists to show the
/// contrast.
const DOC_CAP = 4096;

var doc: [DOC_CAP]u16 = undefined;
var doc_len: usize = 0;
var sel_start: usize = 0;
var sel_end: usize = 0;

/// The provisional range the input processor is currently composing, in ACP.
/// On Wayland this would be a separate preedit string; here it is a slice of
/// the real document. See the header.
var comp_active = false;
var comp_start: usize = 0;
var comp_end: usize = 0;

fn docUtf8(buf: []u8) []const u8 {
    const n = std.unicode.utf16LeToUtf8(buf, doc[0..doc_len]) catch 0;
    return buf[0..n];
}

/// The whole point of the four spikes in one line of output.
fn reportUnits() void {
    var buf: [DOC_CAP * 4]u8 = undefined;
    const s = docUtf8(&buf);
    const cps = std.unicode.utf8CountCodepoints(s) catch s.len;
    std.debug.print(
        "  [doc] \"{s}\" | acp sel {d}..{d}{s} | {d} utf16 = {d} bytes = {d} codepoints\n",
        .{
            s,
            sel_start,
            sel_end,
            if (comp_active) " | COMPOSING" else "",
            doc_len,
            s.len,
            cps,
        },
    );
}

// --------------------------------------------------------------- the lock

/// TSF's lock protocol, which has no equivalent in text-input-v3.
///
/// An input processor asks for a read or read/write lock; the store grants it
/// by calling back into `OnLockGranted`, during which the processor does its
/// reads and writes. Two rules make this more than a boolean:
///
///   1. A request arriving while a lock is held must NOT recurse. It is queued
///      and granted after the current one unwinds, and the caller is told
///      TS_S_ASYNC. Granting it immediately re-enters the processor and
///      corrupts its state.
///   2. A write during a read-only lock must fail with TS_E_NOLOCK. Silently
///      allowing it is the bug that produces text the processor does not know
///      about.
var lock_flags: u32 = 0;
var pending_lock: u32 = 0;

fn hasWriteLock() bool {
    return (lock_flags & c.TS_LF_READWRITE) == c.TS_LF_READWRITE;
}
fn hasReadLock() bool {
    return (lock_flags & c.TS_LF_READ) != 0;
}

// ----------------------------------------------------------------- the sink

var sink: [*c]c.ITextStoreACPSink = null;
var sink_mask: c.DWORD = 0;

fn notifyTextChange(start: usize, old_end: usize, new_end: usize) void {
    if (sink == null) return;
    var tc = c.TS_TEXTCHANGE{
        .acpStart = @intCast(start),
        .acpOldEnd = @intCast(old_end),
        .acpNewEnd = @intCast(new_end),
    };
    std.debug.print("  <= OnTextChange(start={d} oldEnd={d} newEnd={d})\n", .{ start, old_end, new_end });
    _ = sink.*.lpVtbl.*.OnTextChange.?(sink, 0, &tc);
}

fn notifySelectionChange() void {
    if (sink == null) return;
    std.debug.print("  <= OnSelectionChange()\n", .{});
    _ = sink.*.lpVtbl.*.OnSelectionChange.?(sink);
}

/// Edits the application makes ITSELF -- a plain keystroke, Backspace, a caret
/// move. These are the only changes the sink must be told about: when the input
/// processor calls SetText it already knows what it did, and notifying it about
/// its own edit is how notification storms start.
///
/// The deferral rule matters more than it looks. While the processor holds a
/// lock the application MUST NOT touch the text; doing so changes the document
/// underneath a reader that believes it has exclusive access. There is no queue
/// here because a spike has nowhere to put one -- the edit is refused and
/// logged, which at least makes the collision visible instead of silent.
fn appEdit(kind: enum { insert, backspace, left, right }, ch: u16) void {
    if (lock_flags != 0) {
        std.debug.print("  !! app edit refused: the input processor holds a lock (0x{x})\n", .{lock_flags});
        return;
    }
    if (comp_active) {
        // Editing under an active composition would desynchronise the
        // processor's idea of the composing range from the document.
        std.debug.print("  !! app edit refused: a composition is active\n", .{});
        return;
    }

    const old_start = sel_start;
    switch (kind) {
        .insert => {
            if (doc_len + 1 > DOC_CAP) return;
            const tail = doc_len - sel_end;
            std.mem.copyBackwards(u16, doc[sel_start + 1 ..][0..tail], doc[sel_end..][0..tail]);
            doc[sel_start] = ch;
            doc_len = doc_len - (sel_end - sel_start) + 1;
            sel_start += 1;
            sel_end = sel_start;
            notifyTextChange(old_start, old_start, sel_start);
            notifySelectionChange();
        },
        .backspace => {
            if (sel_start == 0 and sel_end == 0) return;
            var from = sel_start;
            const to = sel_end;
            if (from == to) {
                // One UTF-16 unit is not one character: step over a low
                // surrogate so a backspace cannot split a pair.
                from -= 1;
                if (from > 0 and doc[from] >= 0xDC00 and doc[from] <= 0xDFFF) from -= 1;
            }
            const tail = doc_len - to;
            std.mem.copyForwards(u16, doc[from..], doc[to..][0..tail]);
            doc_len -= to - from;
            sel_start = from;
            sel_end = from;
            notifyTextChange(from, to, from);
            notifySelectionChange();
        },
        .left => {
            if (sel_start == 0) return;
            sel_start -= 1;
            if (sel_start > 0 and doc[sel_start] >= 0xDC00 and doc[sel_start] <= 0xDFFF) sel_start -= 1;
            sel_end = sel_start;
            notifySelectionChange();
        },
        .right => {
            if (sel_end >= doc_len) return;
            sel_end += 1;
            if (sel_end < doc_len and doc[sel_end] >= 0xDC00 and doc[sel_end] <= 0xDFFF) sel_end += 1;
            sel_start = sel_end;
            notifySelectionChange();
        },
    }
    reportUnits();
}

// ------------------------------------------------------------- the text store

/// One object exposing `ITextStoreACP` and `ITfContextOwnerCompositionSink`.
/// Same layout trick as spike D: a pointer to each embedded interface struct is
/// a valid pointer to that interface.
const Store = extern struct {
    acp: c.ITextStoreACP,
    comp: c.ITfContextOwnerCompositionSink,
    refs: i32,
    hwnd: c.HWND,
};

var store: Store = undefined;

fn fromAcp(this: [*c]c.ITextStoreACP) *Store {
    return @ptrFromInt(@intFromPtr(this) - @offsetOf(Store, "acp"));
}
fn fromComp(this: [*c]c.ITfContextOwnerCompositionSink) *Store {
    return @ptrFromInt(@intFromPtr(this) - @offsetOf(Store, "comp"));
}

var n_calls: u32 = 0;
fn log(comptime fmt: []const u8, args: anytype) void {
    n_calls += 1;
    std.debug.print("  -> " ++ fmt ++ "\n", args);
}

fn qi(p: *Store, riid: [*c]const c.IID, out: [*c]?*anyopaque) c.HRESULT {
    if (out == null) return E_POINTER;
    out.* = null;
    if (sameGuid(riid, &IID_IUnknown) or sameGuid(riid, &IID_ITextStoreACP)) {
        out.* = @ptrCast(&p.acp);
    } else if (sameGuid(riid, &IID_ITfContextOwnerCompositionSink)) {
        out.* = @ptrCast(&p.comp);
    } else {
        return E_NOINTERFACE;
    }
    p.refs += 1;
    return S_OK;
}

// --- ITextStoreACP: IUnknown ---

fn a_QI(this: [*c]c.ITextStoreACP, riid: [*c]const c.IID, out: [*c]?*anyopaque) callconv(.c) c.HRESULT {
    return qi(fromAcp(this), riid, out);
}
fn a_AddRef(this: [*c]c.ITextStoreACP) callconv(.c) c.ULONG {
    const p = fromAcp(this);
    p.refs += 1;
    return @intCast(p.refs);
}
fn a_Release(this: [*c]c.ITextStoreACP) callconv(.c) c.ULONG {
    const p = fromAcp(this);
    if (p.refs > 0) p.refs -= 1;
    return @intCast(p.refs);
}

// --- ITextStoreACP: sink management ---

fn a_AdviseSink(this: [*c]c.ITextStoreACP, riid: [*c]const c.IID, punk: ?*c.IUnknown, mask: c.DWORD) callconv(.c) c.HRESULT {
    _ = this;
    _ = riid;
    if (punk == null) return E_INVALIDARG;
    var out: ?*anyopaque = null;
    const unk: [*c]c.IUnknown = @ptrCast(punk);
    const hr = unk.*.lpVtbl.*.QueryInterface.?(unk, &IID_ITextStoreACPSinkLocal, @ptrCast(&out));
    if (hr != S_OK or out == null) return E_NOINTERFACE;
    sink = @ptrCast(@alignCast(out));
    sink_mask = mask;
    log("AdviseSink(mask=0x{x})", .{mask});
    return S_OK;
}

const IID_ITextStoreACPSinkLocal = guid(0x22d44c94, 0xa419, 0x4542, .{ 0xa2, 0x72, 0xae, 0x26, 0x09, 0x3e, 0xce, 0xcf });

fn a_UnadviseSink(this: [*c]c.ITextStoreACP, punk: ?*c.IUnknown) callconv(.c) c.HRESULT {
    _ = this;
    _ = punk;
    log("UnadviseSink", .{});
    if (sink != null) {
        _ = sink.*.lpVtbl.*.Release.?(sink);
        sink = null;
    }
    return S_OK;
}

// --- ITextStoreACP: the lock ---

fn a_RequestLock(this: [*c]c.ITextStoreACP, flags: c.DWORD, hrSession: [*c]c.HRESULT) callconv(.c) c.HRESULT {
    _ = this;
    if (hrSession == null) return E_POINTER;
    if (sink == null) return E_FAIL;

    if (lock_flags != 0) {
        // Already locked. A synchronous request cannot be deferred, so it is
        // refused outright; anything else is queued.
        if ((flags & c.TS_LF_SYNC) != 0) {
            hrSession.* = TS_E_SYNCHRONOUS;
            log("RequestLock(0x{x}) while locked -> TS_E_SYNCHRONOUS", .{flags});
            return S_OK;
        }
        pending_lock = flags;
        hrSession.* = TS_S_ASYNC;
        log("RequestLock(0x{x}) while locked -> queued, TS_S_ASYNC", .{flags});
        return S_OK;
    }

    lock_flags = flags;
    log("RequestLock(0x{x}) -> granting{s}", .{
        flags,
        if (hasWriteLock()) " [read/write]" else " [read only]",
    });
    hrSession.* = sink.*.lpVtbl.*.OnLockGranted.?(sink, flags);
    lock_flags = 0;

    // Drain anything that arrived during the grant, now that the stack has
    // unwound. Looping rather than granting once: a processor may queue another
    // request from inside the deferred grant.
    while (pending_lock != 0) {
        const f = pending_lock;
        pending_lock = 0;
        lock_flags = f;
        log("granting queued lock(0x{x})", .{f});
        _ = sink.*.lpVtbl.*.OnLockGranted.?(sink, f);
        lock_flags = 0;
    }
    return S_OK;
}

fn a_GetStatus(this: [*c]c.ITextStoreACP, st: [*c]c.TS_STATUS) callconv(.c) c.HRESULT {
    _ = this;
    if (st == null) return E_POINTER;
    st.*.dwDynamicFlags = 0;
    // TS_SS_TRANSITORY would mean the text is thrown away; TS_SS_REGIONS means
    // multiple disjoint editable areas. A plain single-line field has neither.
    st.*.dwStaticFlags = c.TS_SS_NOHIDDENTEXT;
    return S_OK;
}

fn a_QueryInsert(
    this: [*c]c.ITextStoreACP,
    acpTestStart: c.LONG,
    acpTestEnd: c.LONG,
    cch: c.ULONG,
    pacpResultStart: [*c]c.LONG,
    pacpResultEnd: [*c]c.LONG,
) callconv(.c) c.HRESULT {
    _ = this;
    _ = cch;
    if (pacpResultStart == null or pacpResultEnd == null) return E_POINTER;
    const end: c.LONG = @intCast(doc_len);
    if (acpTestStart < 0 or acpTestEnd < 0 or acpTestStart > end or acpTestEnd > end) return E_INVALIDARG;
    pacpResultStart.* = acpTestStart;
    pacpResultEnd.* = acpTestEnd;
    return S_OK;
}

// --- ITextStoreACP: selection ---

fn a_GetSelection(
    this: [*c]c.ITextStoreACP,
    ulIndex: c.ULONG,
    ulCount: c.ULONG,
    pSelection: [*c]c.TS_SELECTION_ACP,
    pcFetched: [*c]c.ULONG,
) callconv(.c) c.HRESULT {
    _ = this;
    if (pcFetched == null or pSelection == null) return E_POINTER;
    pcFetched.* = 0;
    if (!hasReadLock()) return TS_E_NOLOCK;
    if (ulCount == 0) return S_OK;
    if (ulIndex != c.TS_DEFAULT_SELECTION and ulIndex != 0) return E_INVALIDARG;
    pSelection[0] = .{
        .acpStart = @intCast(sel_start),
        .acpEnd = @intCast(sel_end),
        .style = .{ .ase = c.TS_AE_END, .fInterimChar = 0 },
    };
    pcFetched.* = 1;
    log("GetSelection -> {d}..{d}", .{ sel_start, sel_end });
    return S_OK;
}

fn a_SetSelection(
    this: [*c]c.ITextStoreACP,
    ulCount: c.ULONG,
    pSelection: [*c]const c.TS_SELECTION_ACP,
) callconv(.c) c.HRESULT {
    _ = this;
    if (!hasWriteLock()) return TS_E_NOLOCK;
    if (ulCount == 0 or pSelection == null) return E_INVALIDARG;
    const s = pSelection[0];
    if (s.acpStart < 0 or s.acpEnd < 0) return TS_E_INVALIDPOS;
    const a: usize = @intCast(s.acpStart);
    const b: usize = @intCast(s.acpEnd);
    if (a > doc_len or b > doc_len) return TS_E_INVALIDPOS;
    sel_start = a;
    sel_end = b;
    log("SetSelection({d}..{d})", .{ a, b });
    return S_OK;
}

// --- ITextStoreACP: text ---

fn a_GetText(
    this: [*c]c.ITextStoreACP,
    acpStart: c.LONG,
    acpEnd: c.LONG,
    pchPlain: [*c]u16,
    cchPlainReq: c.ULONG,
    pcchPlainOut: [*c]c.ULONG,
    prgRunInfo: [*c]c.TS_RUNINFO,
    ulRunInfoReq: c.ULONG,
    pulRunInfoOut: [*c]c.ULONG,
    pacpNext: [*c]c.LONG,
) callconv(.c) c.HRESULT {
    _ = this;
    if (!hasReadLock()) return TS_E_NOLOCK;
    if (pcchPlainOut == null or pulRunInfoOut == null or pacpNext == null) return E_POINTER;
    pcchPlainOut.* = 0;
    pulRunInfoOut.* = 0;

    if (acpStart < 0 or acpStart > @as(c.LONG, @intCast(doc_len))) return TS_E_INVALIDPOS;
    const start: usize = @intCast(acpStart);
    // -1 means "to the end", which is easy to miss and produces a silently
    // empty read.
    const end: usize = if (acpEnd < 0) doc_len else @min(@as(usize, @intCast(acpEnd)), doc_len);
    if (end < start) return TS_E_INVALIDPOS;

    const want = end - start;
    const n = if (pchPlain != null and cchPlainReq > 0) @min(want, cchPlainReq) else 0;
    if (n > 0) @memcpy(pchPlain[0..n], doc[start..][0..n]);
    pcchPlainOut.* = @intCast(n);

    // One run, all of it visible. A field with hidden text would report more.
    if (prgRunInfo != null and ulRunInfoReq > 0) {
        prgRunInfo[0] = .{ .uCount = @intCast(n), .type = c.TS_RT_PLAIN };
        pulRunInfoOut.* = 1;
    }
    pacpNext.* = @intCast(start + n);
    log("GetText({d}..{d}) -> {d} utf16 units", .{ acpStart, acpEnd, n });
    return S_OK;
}

/// Where composition text actually lands. The input processor takes a write
/// lock and calls this with the characters it is composing -- they go into the
/// real document, which is the difference from Wayland described in the header.
fn a_SetText(
    this: [*c]c.ITextStoreACP,
    dwFlags: c.DWORD,
    acpStart: c.LONG,
    acpEnd: c.LONG,
    pchText: [*c]const u16,
    cch: c.ULONG,
    pChange: [*c]c.TS_TEXTCHANGE,
) callconv(.c) c.HRESULT {
    _ = this;
    if (!hasWriteLock()) return TS_E_NOLOCK;
    if (acpStart < 0) return TS_E_INVALIDPOS;

    const start: usize = @intCast(acpStart);
    const end: usize = if (acpEnd < 0) doc_len else @min(@as(usize, @intCast(acpEnd)), doc_len);
    if (start > doc_len or end < start) return TS_E_INVALIDPOS;

    const ins: usize = @intCast(cch);
    const removed = end - start;
    if (doc_len - removed + ins > DOC_CAP) return E_FAIL;

    // shift the tail, then write the new run
    const tail = doc_len - end;
    if (ins != removed) {
        std.mem.copyBackwards(u16, doc[start + ins ..][0..tail], doc[end..][0..tail]);
    }
    if (ins > 0 and pchText != null) @memcpy(doc[start..][0..ins], pchText[0..ins]);
    doc_len = doc_len - removed + ins;
    sel_start = start + ins;
    sel_end = sel_start;

    if (pChange != null) {
        pChange.*.acpStart = @intCast(start);
        pChange.*.acpOldEnd = @intCast(end);
        pChange.*.acpNewEnd = @intCast(start + ins);
    }

    var u8buf: [512]u8 = undefined;
    const n8 = std.unicode.utf16LeToUtf8(&u8buf, if (ins > 0 and pchText != null) pchText[0..ins] else &.{}) catch 0;
    log("SetText(flags=0x{x} {d}..{d} <- \"{s}\" {d} utf16 units)", .{
        dwFlags, acpStart, acpEnd, u8buf[0..n8], ins,
    });
    reportUnits();
    return S_OK;
}

fn a_InsertTextAtSelection(
    this: [*c]c.ITextStoreACP,
    dwFlags: c.DWORD,
    pchText: [*c]const u16,
    cch: c.ULONG,
    pacpStart: [*c]c.LONG,
    pacpEnd: [*c]c.LONG,
    pChange: [*c]c.TS_TEXTCHANGE,
) callconv(.c) c.HRESULT {
    // TS_IAS_QUERYONLY asks where the text WOULD go without inserting it.
    // Treating it as a real insert duplicates every composed character.
    const query_only = (dwFlags & c.TS_IAS_QUERYONLY) != 0;
    if (!query_only and !hasWriteLock()) return TS_E_NOLOCK;
    if (query_only and !hasReadLock()) return TS_E_NOLOCK;

    if (query_only) {
        if (pacpStart != null) pacpStart.* = @intCast(sel_start);
        if (pacpEnd != null) pacpEnd.* = @intCast(sel_end);
        log("InsertTextAtSelection(QUERYONLY) -> {d}..{d}", .{ sel_start, sel_end });
        return S_OK;
    }

    const s: c.LONG = @intCast(sel_start);
    const e: c.LONG = @intCast(sel_end);
    const hr = a_SetText(this, 0, s, e, pchText, cch, pChange);
    if (hr != S_OK) return hr;
    if (pacpStart != null) pacpStart.* = s;
    if (pacpEnd != null) pacpEnd.* = @intCast(sel_end);
    log("InsertTextAtSelection -> {d}..{d}", .{ sel_start, sel_end });
    return S_OK;
}

fn a_GetEndACP(this: [*c]c.ITextStoreACP, pacp: [*c]c.LONG) callconv(.c) c.HRESULT {
    _ = this;
    if (pacp == null) return E_POINTER;
    if (!hasReadLock()) return TS_E_NOLOCK;
    pacp.* = @intCast(doc_len);
    return S_OK;
}

// --- ITextStoreACP: layout, which positions the candidate window ---

fn a_GetActiveView(this: [*c]c.ITextStoreACP, pvcView: [*c]c.TsViewCookie) callconv(.c) c.HRESULT {
    _ = this;
    if (pvcView == null) return E_POINTER;
    pvcView.* = 1;
    return S_OK;
}

fn a_GetACPFromPoint(
    this: [*c]c.ITextStoreACP,
    vcView: c.TsViewCookie,
    pt: [*c]const c.POINT,
    dwFlags: c.DWORD,
    pacp: [*c]c.LONG,
) callconv(.c) c.HRESULT {
    _ = this;
    _ = vcView;
    _ = pt;
    _ = dwFlags;
    if (pacp == null) return E_POINTER;
    // Would need text layout to answer. TS_E_NOLAYOUT is the correct way to
    // say so; E_NOTIMPL makes some processors give up on the store entirely.
    return TS_E_NOLAYOUT;
}

/// The rectangle a candidate window is placed against. This spike has no text
/// layout, so it reports a fixed box below the field -- the same honest
/// limitation spike B has with `set_cursor_rectangle`. A real toolkit computes
/// it from the glyph positions of the range.
fn a_GetTextExt(
    this: [*c]c.ITextStoreACP,
    vcView: c.TsViewCookie,
    acpStart: c.LONG,
    acpEnd: c.LONG,
    prc: [*c]c.RECT,
    pfClipped: [*c]c.BOOL,
) callconv(.c) c.HRESULT {
    _ = vcView;
    _ = acpStart;
    _ = acpEnd;
    const p = fromAcp(this);
    if (prc == null or pfClipped == null) return E_POINTER;
    if (!hasReadLock()) return TS_E_NOLOCK;
    var origin = c.POINT{ .x = 8, .y = 68 };
    if (p.hwnd != null) _ = c.ClientToScreen(p.hwnd, &origin);
    prc.* = .{ .left = origin.x, .top = origin.y, .right = origin.x + 8, .bottom = origin.y + 20 };
    pfClipped.* = 0;
    log("GetTextExt -> screen ({d},{d})", .{ origin.x, origin.y });
    return S_OK;
}

fn a_GetScreenExt(this: [*c]c.ITextStoreACP, vcView: c.TsViewCookie, prc: [*c]c.RECT) callconv(.c) c.HRESULT {
    _ = vcView;
    const p = fromAcp(this);
    if (prc == null) return E_POINTER;
    if (p.hwnd == null) return E_FAIL;
    var rc: c.RECT = undefined;
    _ = c.GetClientRect(p.hwnd, &rc);
    var tl = c.POINT{ .x = rc.left, .y = rc.top };
    var br = c.POINT{ .x = rc.right, .y = rc.bottom };
    _ = c.ClientToScreen(p.hwnd, &tl);
    _ = c.ClientToScreen(p.hwnd, &br);
    prc.* = .{ .left = tl.x, .top = tl.y, .right = br.x, .bottom = br.y };
    return S_OK;
}

fn a_GetWnd(this: [*c]c.ITextStoreACP, vcView: c.TsViewCookie, phwnd: [*c]c.HWND) callconv(.c) c.HRESULT {
    _ = vcView;
    const p = fromAcp(this);
    if (phwnd == null) return E_POINTER;
    phwnd.* = p.hwnd;
    return S_OK;
}

// --- ITextStoreACP: attributes ---
//
// A plain field supports no attributes, but the methods must still behave:
// RequestSupportedAttrs followed by RetrieveRequestedAttrs returning zero is
// the correct "I have none", where E_NOTIMPL is not.

fn a_RequestSupportedAttrs(this: [*c]c.ITextStoreACP, dwFlags: c.DWORD, cFilterAttrs: c.ULONG, paFilterAttrs: [*c]const c.TS_ATTRID) callconv(.c) c.HRESULT {
    _ = this;
    _ = dwFlags;
    _ = cFilterAttrs;
    _ = paFilterAttrs;
    return S_OK;
}

fn a_RequestAttrsAtPosition(this: [*c]c.ITextStoreACP, acpPos: c.LONG, cFilterAttrs: c.ULONG, paFilterAttrs: [*c]const c.TS_ATTRID, dwFlags: c.DWORD) callconv(.c) c.HRESULT {
    _ = this;
    _ = acpPos;
    _ = cFilterAttrs;
    _ = paFilterAttrs;
    _ = dwFlags;
    return S_OK;
}

fn a_RequestAttrsTransitioningAtPosition(this: [*c]c.ITextStoreACP, acpPos: c.LONG, cFilterAttrs: c.ULONG, paFilterAttrs: [*c]const c.TS_ATTRID, dwFlags: c.DWORD) callconv(.c) c.HRESULT {
    _ = this;
    _ = acpPos;
    _ = cFilterAttrs;
    _ = paFilterAttrs;
    _ = dwFlags;
    return S_OK;
}

fn a_FindNextAttrTransition(
    this: [*c]c.ITextStoreACP,
    acpStart: c.LONG,
    acpHalt: c.LONG,
    cFilterAttrs: c.ULONG,
    paFilterAttrs: [*c]const c.TS_ATTRID,
    dwFlags: c.DWORD,
    pacpNext: [*c]c.LONG,
    pfFound: [*c]c.BOOL,
    plFoundOffset: [*c]c.LONG,
) callconv(.c) c.HRESULT {
    _ = this;
    _ = acpHalt;
    _ = cFilterAttrs;
    _ = paFilterAttrs;
    _ = dwFlags;
    if (pacpNext == null or pfFound == null or plFoundOffset == null) return E_POINTER;
    pacpNext.* = acpStart;
    pfFound.* = 0;
    plFoundOffset.* = 0;
    return S_OK;
}

fn a_RetrieveRequestedAttrs(this: [*c]c.ITextStoreACP, ulCount: c.ULONG, paAttrVals: [*c]c.TS_ATTRVAL, pcFetched: [*c]c.ULONG) callconv(.c) c.HRESULT {
    _ = this;
    _ = ulCount;
    _ = paAttrVals;
    if (pcFetched == null) return E_POINTER;
    pcFetched.* = 0;
    return S_OK;
}

// --- ITextStoreACP: embedded objects, genuinely not supported ---

fn a_GetFormattedText(this: [*c]c.ITextStoreACP, acpStart: c.LONG, acpEnd: c.LONG, ppDataObject: [*c][*c]c.IDataObject) callconv(.c) c.HRESULT {
    _ = this;
    _ = acpStart;
    _ = acpEnd;
    _ = ppDataObject;
    return E_NOTIMPL;
}
fn a_GetEmbedded(this: [*c]c.ITextStoreACP, acpPos: c.LONG, rguidService: [*c]const c.GUID, riid: [*c]const c.IID, ppunk: [*c]?*c.IUnknown) callconv(.c) c.HRESULT {
    _ = this;
    _ = acpPos;
    _ = rguidService;
    _ = riid;
    _ = ppunk;
    return E_NOTIMPL;
}
fn a_QueryInsertEmbedded(this: [*c]c.ITextStoreACP, pguidService: [*c]const c.GUID, pFormatEtc: [*c]const c.FORMATETC, pfInsertable: [*c]c.BOOL) callconv(.c) c.HRESULT {
    _ = this;
    _ = pguidService;
    _ = pFormatEtc;
    if (pfInsertable == null) return E_POINTER;
    pfInsertable.* = 0;
    return S_OK;
}
fn a_InsertEmbedded(this: [*c]c.ITextStoreACP, dwFlags: c.DWORD, acpStart: c.LONG, acpEnd: c.LONG, pDataObject: ?*c.IDataObject, pChange: [*c]c.TS_TEXTCHANGE) callconv(.c) c.HRESULT {
    _ = this;
    _ = dwFlags;
    _ = acpStart;
    _ = acpEnd;
    _ = pDataObject;
    _ = pChange;
    return E_NOTIMPL;
}
fn a_InsertEmbeddedAtSelection(this: [*c]c.ITextStoreACP, dwFlags: c.DWORD, pDataObject: ?*c.IDataObject, pacpStart: [*c]c.LONG, pacpEnd: [*c]c.LONG, pChange: [*c]c.TS_TEXTCHANGE) callconv(.c) c.HRESULT {
    _ = this;
    _ = dwFlags;
    _ = pDataObject;
    _ = pacpStart;
    _ = pacpEnd;
    _ = pChange;
    return E_NOTIMPL;
}

const acp_vtbl = c.ITextStoreACPVtbl{
    .QueryInterface = a_QI,
    .AddRef = a_AddRef,
    .Release = a_Release,
    .AdviseSink = a_AdviseSink,
    .UnadviseSink = a_UnadviseSink,
    .RequestLock = a_RequestLock,
    .GetStatus = a_GetStatus,
    .QueryInsert = a_QueryInsert,
    .GetSelection = a_GetSelection,
    .SetSelection = a_SetSelection,
    .GetText = a_GetText,
    .SetText = a_SetText,
    .GetFormattedText = a_GetFormattedText,
    .GetEmbedded = a_GetEmbedded,
    .QueryInsertEmbedded = a_QueryInsertEmbedded,
    .InsertEmbedded = a_InsertEmbedded,
    .InsertTextAtSelection = a_InsertTextAtSelection,
    .InsertEmbeddedAtSelection = a_InsertEmbeddedAtSelection,
    .RequestSupportedAttrs = a_RequestSupportedAttrs,
    .RequestAttrsAtPosition = a_RequestAttrsAtPosition,
    .RequestAttrsTransitioningAtPosition = a_RequestAttrsTransitioningAtPosition,
    .FindNextAttrTransition = a_FindNextAttrTransition,
    .RetrieveRequestedAttrs = a_RetrieveRequestedAttrs,
    .GetEndACP = a_GetEndACP,
    .GetActiveView = a_GetActiveView,
    .GetACPFromPoint = a_GetACPFromPoint,
    .GetTextExt = a_GetTextExt,
    .GetScreenExt = a_GetScreenExt,
    .GetWnd = a_GetWnd,
};

// --- ITfContextOwnerCompositionSink ---

fn k_QI(this: [*c]c.ITfContextOwnerCompositionSink, riid: [*c]const c.IID, out: [*c]?*anyopaque) callconv(.c) c.HRESULT {
    return qi(fromComp(this), riid, out);
}
fn k_AddRef(this: [*c]c.ITfContextOwnerCompositionSink) callconv(.c) c.ULONG {
    const p = fromComp(this);
    p.refs += 1;
    return @intCast(p.refs);
}
fn k_Release(this: [*c]c.ITfContextOwnerCompositionSink) callconv(.c) c.ULONG {
    const p = fromComp(this);
    if (p.refs > 0) p.refs -= 1;
    return @intCast(p.refs);
}

/// The only signal that the text now in the document is PROVISIONAL. Without
/// tracking this, an application cannot tell committed text from text the
/// input processor may still rewrite -- and on Windows both live in the same
/// buffer.
fn k_OnStartComposition(
    this: [*c]c.ITfContextOwnerCompositionSink,
    pComposition: ?*c.ITfCompositionView,
    pfOk: [*c]c.BOOL,
) callconv(.c) c.HRESULT {
    _ = this;
    _ = pComposition;
    if (pfOk != null) pfOk.* = 1; // refusing here blocks the IME entirely
    comp_active = true;
    comp_start = sel_start;
    comp_end = sel_end;
    log("OnStartComposition at {d}", .{sel_start});
    return S_OK;
}

fn k_OnUpdateComposition(
    this: [*c]c.ITfContextOwnerCompositionSink,
    pComposition: ?*c.ITfCompositionView,
    pRangeNew: ?*c.ITfRange,
) callconv(.c) c.HRESULT {
    _ = this;
    _ = pComposition;
    _ = pRangeNew;
    log("OnUpdateComposition", .{});
    return S_OK;
}

fn k_OnEndComposition(
    this: [*c]c.ITfContextOwnerCompositionSink,
    pComposition: ?*c.ITfCompositionView,
) callconv(.c) c.HRESULT {
    _ = this;
    _ = pComposition;
    comp_active = false;
    log("OnEndComposition -- the text in the document is now committed", .{});
    reportUnits();
    return S_OK;
}

const comp_vtbl = c.ITfContextOwnerCompositionSinkVtbl{
    .QueryInterface = k_QI,
    .AddRef = k_AddRef,
    .Release = k_Release,
    .OnStartComposition = k_OnStartComposition,
    .OnUpdateComposition = k_OnUpdateComposition,
    .OnEndComposition = k_OnEndComposition,
};

// ------------------------------------------------------------------ self test
//
// A real input processor decides for itself whether to re-enter RequestLock,
// and Vietnamese Telex never did: 27 grants, every one already read/write, so
// no upgrade was ever needed. The queued path therefore cannot be reached by
// typing, and shipping it untested would be exactly the kind of "it compiles,
// so it works" that run 4 of the benchmark punished.
//
// This drives the state machine directly through a fake sink and asserts what
// comes back. It proves the state machine is internally correct. It does NOT
// prove a real processor exercises it -- that distinction is the whole reason
// the spikes insist on running Orca and Narrator rather than trusting the code.

var test_pass: u32 = 0;
var test_fail: u32 = 0;

fn check(cond: bool, comptime what: []const u8) void {
    if (cond) {
        test_pass += 1;
        std.debug.print("  PASS  {s}\n", .{what});
    } else {
        test_fail += 1;
        std.debug.print("  FAIL  {s}\n", .{what});
    }
}

/// What the fake sink does when the lock is granted.
const Script = enum {
    nothing,
    /// Re-request asynchronously: must be queued and granted later.
    reenter_async,
    /// Re-request synchronously: cannot be deferred, must be refused.
    reenter_sync,
    /// Re-request once from the outer grant and once from the deferred grant,
    /// which is what distinguishes a drain LOOP from a single deferred grant.
    reenter_twice,
    /// Attempt a write while holding a read-only lock.
    write_under_read,
};

var script: Script = .nothing;
var grants: u32 = 0;
var inner_hr: c.HRESULT = 0;
var inner_ret: c.HRESULT = 0;
var write_hr: c.HRESULT = 0;

const FakeSink = extern struct {
    sink: c.ITextStoreACPSink,
    refs: i32,
};
var fake: FakeSink = undefined;

fn fs_QI(this: [*c]c.ITextStoreACPSink, riid: [*c]const c.IID, out: [*c]?*anyopaque) callconv(.c) c.HRESULT {
    if (out == null) return E_POINTER;
    out.* = null;
    if (sameGuid(riid, &IID_IUnknown) or sameGuid(riid, &IID_ITextStoreACPSinkLocal)) {
        out.* = @ptrCast(this);
        fake.refs += 1;
        return S_OK;
    }
    return E_NOINTERFACE;
}
fn fs_AddRef(this: [*c]c.ITextStoreACPSink) callconv(.c) c.ULONG {
    _ = this;
    fake.refs += 1;
    return @intCast(fake.refs);
}
fn fs_Release(this: [*c]c.ITextStoreACPSink) callconv(.c) c.ULONG {
    _ = this;
    if (fake.refs > 0) fake.refs -= 1;
    return @intCast(fake.refs);
}

fn fs_OnLockGranted(this: [*c]c.ITextStoreACPSink, flags: c.DWORD) callconv(.c) c.HRESULT {
    _ = this;
    grants += 1;
    const depth = grants;
    switch (script) {
        .nothing => {},
        .reenter_async, .reenter_twice => {
            // Only re-enter from the first grant unless the script wants a
            // second round from inside the deferred one.
            const again = (depth == 1) or (script == .reenter_twice and depth == 2);
            if (again) {
                inner_ret = a_RequestLock(@ptrCast(&store.acp), c.TS_LF_READWRITE, &inner_hr);
            }
        },
        .reenter_sync => {
            if (depth == 1) {
                inner_ret = a_RequestLock(
                    @ptrCast(&store.acp),
                    c.TS_LF_READWRITE | c.TS_LF_SYNC,
                    &inner_hr,
                );
            }
        },
        .write_under_read => {
            if (depth == 1) {
                var tc: c.TS_TEXTCHANGE = undefined;
                const txt = [_]u16{ 'x', 0 };
                write_hr = a_SetText(@ptrCast(&store.acp), 0, 0, 0, &txt, 1, &tc);
            }
        },
    }
    _ = flags;
    return S_OK;
}

fn fs_OnTextChange(this: [*c]c.ITextStoreACPSink, flags: c.DWORD, ch: [*c]const c.TS_TEXTCHANGE) callconv(.c) c.HRESULT {
    _ = this;
    _ = flags;
    _ = ch;
    return S_OK;
}
fn fs_OnSelectionChange(this: [*c]c.ITextStoreACPSink) callconv(.c) c.HRESULT {
    _ = this;
    return S_OK;
}
fn fs_OnLayoutChange(this: [*c]c.ITextStoreACPSink, lcode: c.TsLayoutCode, vc: c.TsViewCookie) callconv(.c) c.HRESULT {
    _ = this;
    _ = lcode;
    _ = vc;
    return S_OK;
}
fn fs_OnStatusChange(this: [*c]c.ITextStoreACPSink, flags: c.DWORD) callconv(.c) c.HRESULT {
    _ = this;
    _ = flags;
    return S_OK;
}
fn fs_OnAttrsChange(this: [*c]c.ITextStoreACPSink, s0: c.LONG, s1: c.LONG, n: c.ULONG, a: [*c]const c.TS_ATTRID) callconv(.c) c.HRESULT {
    _ = this;
    _ = s0;
    _ = s1;
    _ = n;
    _ = a;
    return S_OK;
}
fn fs_OnStartEditTransaction(this: [*c]c.ITextStoreACPSink) callconv(.c) c.HRESULT {
    _ = this;
    return S_OK;
}
fn fs_OnEndEditTransaction(this: [*c]c.ITextStoreACPSink) callconv(.c) c.HRESULT {
    _ = this;
    return S_OK;
}

const fake_vtbl = c.ITextStoreACPSinkVtbl{
    .QueryInterface = fs_QI,
    .AddRef = fs_AddRef,
    .Release = fs_Release,
    .OnTextChange = fs_OnTextChange,
    .OnSelectionChange = fs_OnSelectionChange,
    .OnLayoutChange = fs_OnLayoutChange,
    .OnStatusChange = fs_OnStatusChange,
    .OnAttrsChange = fs_OnAttrsChange,
    .OnLockGranted = fs_OnLockGranted,
    .OnStartEditTransaction = fs_OnStartEditTransaction,
    .OnEndEditTransaction = fs_OnEndEditTransaction,
};

fn resetStore() void {
    doc_len = 0;
    sel_start = 0;
    sel_end = 0;
    comp_active = false;
    lock_flags = 0;
    pending_lock = 0;
    grants = 0;
    inner_hr = 0;
    inner_ret = 0;
    write_hr = 0;
}

fn selfTest() void {
    std.debug.print("--- lock state machine self test ---\n", .{});

    store = .{
        .acp = .{ .lpVtbl = @constCast(&acp_vtbl) },
        .comp = .{ .lpVtbl = @constCast(&comp_vtbl) },
        .refs = 1,
        .hwnd = null,
    };
    fake = .{ .sink = .{ .lpVtbl = @constCast(&fake_vtbl) }, .refs = 1 };
    sink = @ptrCast(&fake.sink);

    // 1 -- a plain grant, and the lock must be released afterwards
    resetStore();
    script = .nothing;
    var hr: c.HRESULT = 0;
    var ret = a_RequestLock(@ptrCast(&store.acp), c.TS_LF_READWRITE, &hr);
    check(ret == S_OK, "RequestLock returns S_OK");
    check(hr == S_OK, "hrSession is the session result");
    check(grants == 1, "the sink was granted exactly once");
    check(lock_flags == 0, "the lock is released after the grant");

    // 2 -- re-entrant async request: queued, then granted
    resetStore();
    script = .reenter_async;
    ret = a_RequestLock(@ptrCast(&store.acp), c.TS_LF_READWRITE, &hr);
    check(ret == S_OK, "re-entrant: outer RequestLock still returns S_OK");
    check(inner_ret == S_OK, "re-entrant: inner RequestLock returns S_OK");
    check(inner_hr == TS_S_ASYNC, "re-entrant: inner hrSession is TS_S_ASYNC");
    check(grants == 2, "re-entrant: the queued lock WAS granted afterwards");
    check(lock_flags == 0 and pending_lock == 0, "re-entrant: nothing left held or queued");

    // 3 -- a synchronous request cannot be deferred
    resetStore();
    script = .reenter_sync;
    ret = a_RequestLock(@ptrCast(&store.acp), c.TS_LF_READWRITE, &hr);
    check(inner_hr == TS_E_SYNCHRONOUS, "sync re-entry is refused with TS_E_SYNCHRONOUS");
    check(grants == 1, "sync re-entry granted no second lock");
    check(pending_lock == 0, "sync re-entry queued nothing");

    // 4 -- the drain must LOOP, not grant once
    resetStore();
    script = .reenter_twice;
    ret = a_RequestLock(@ptrCast(&store.acp), c.TS_LF_READWRITE, &hr);
    check(grants == 3, "a request queued from the deferred grant is also drained");
    check(lock_flags == 0 and pending_lock == 0, "drain loop finished clean");

    // 5 -- writes need a write lock
    resetStore();
    script = .write_under_read;
    ret = a_RequestLock(@ptrCast(&store.acp), c.TS_LF_READ, &hr);
    check(write_hr == TS_E_NOLOCK, "SetText under a read-only lock is TS_E_NOLOCK");
    check(doc_len == 0, "the refused write left the document untouched");

    // 6 -- and without any lock at all
    resetStore();
    script = .nothing;
    var sel: c.TS_SELECTION_ACP = undefined;
    var fetched: c.ULONG = 0;
    const ghr = a_GetSelection(@ptrCast(&store.acp), c.TS_DEFAULT_SELECTION, 1, &sel, &fetched);
    check(ghr == TS_E_NOLOCK, "GetSelection with no lock is TS_E_NOLOCK");

    std.debug.print("\n  {d} passed, {d} failed\n", .{ test_pass, test_fail });
    std.debug.print(
        "\n  NOTE: this proves the state machine, not that a real input\n" ++
            "  processor drives it. Telex never re-entered RequestLock.\n",
        .{},
    );
}

// ---------------------------------------------------------------- the window

var g_hwnd: c.HWND = null;

fn wndProc(h: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.c) c.LRESULT {
    switch (msg) {
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(h, &ps);
            var rc: c.RECT = undefined;
            _ = c.GetClientRect(h, &rc);
            const br = c.CreateSolidBrush(0x2e1e1e);
            _ = c.FillRect(hdc, &rc, br);
            _ = c.DeleteObject(br);
            _ = c.EndPaint(h, &ps);
            return 0;
        },
        // Keys the input processor did not consume. With an IME active this is
        // the minority path, but it is the one that edits the document directly
        // and therefore the only one that owes the sink a notification.
        c.WM_CHAR => {
            const ch: u16 = @truncate(wp);
            if (ch == 8) {
                appEdit(.backspace, 0);
            } else if (ch >= 0x20) {
                appEdit(.insert, ch);
            }
            return 0;
        },
        c.WM_KEYDOWN => {
            switch (wp) {
                c.VK_LEFT => appEdit(.left, 0),
                c.VK_RIGHT => appEdit(.right, 0),
                else => {},
            }
            return 0;
        },
        c.WM_DESTROY => {
            c.PostQuitMessage(0);
            return 0;
        },
        else => return c.DefWindowProcW(h, msg, wp, lp),
    }
}

fn L(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

// ---------------------------------------------------------------------- main

var thread_mgr: [*c]c.ITfThreadMgr = null;
var doc_mgr: [*c]c.ITfDocumentMgr = null;
var context: [*c]c.ITfContext = null;
var client_id: c.TfClientId = 0;
var edit_cookie: c.TfEditCookie = 0;

/// Zig's argument API is not portable the way the rest of std is:
/// `std.process.Args.Iterator.init` is a hard @compileError on Windows
/// ("In Windows, use initAllocator instead"), because Windows hands over a
/// WTF-16 command line that has to be converted. Rather than carry an allocator
/// into a spike for one flag, this reads the native command line and searches
/// it -- no allocation, and nothing to break on the next std reshuffle.
fn hasFlag(comptime flag: []const u8) bool {
    const w = std.unicode.utf8ToUtf16LeStringLiteral(flag);
    const cmd = c.GetCommandLineW() orelse return false;
    var i: usize = 0;
    while (cmd[i] != 0) : (i += 1) {
        var k: usize = 0;
        while (k < w.len and cmd[i + k] == w[k]) k += 1;
        if (k == w.len) return true;
    }
    return false;
}

pub fn main() !void {
    if (hasFlag("--selftest")) {
        selfTest();
        return;
    }

    const hr_init = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    if (hr_init < 0) {
        std.debug.print("CoInitializeEx failed: {s}\n", .{hrName(hr_init)});
        return error.CoInitFailed;
    }
    defer c.CoUninitialize();

    std.debug.print(
        \\zig-uikit TSF spike -- Windows IME via ITextStoreACP.
        \\Cross-compiled on Linux: no MSVC, no Windows SDK.
        \\
        \\  ACP = Application Character Position = UTF-16 CODE UNITS,
        \\  the same unit as a BSTR. Windows is internally consistent;
        \\  Linux is not (text-input-v3 counts bytes, AT-SPI counts codepoints).
        \\
        \\
    , .{});

    // --- window first: TSF wants an HWND to associate focus with ---
    const hinst = c.GetModuleHandleW(null);
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = @ptrCast(hinst);
    wc.lpszClassName = L("ZigUikitTsfSpike").ptr;
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    if (c.RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;

    g_hwnd = c.CreateWindowExW(
        0,
        wc.lpszClassName,
        L("zig-uikit TSF spike - click here and type Vietnamese Telex").ptr,
        c.WS_OVERLAPPEDWINDOW,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        760,
        240,
        null,
        null,
        @ptrCast(hinst),
        null,
    );
    if (g_hwnd == null) return error.CreateWindowFailed;

    store = .{
        .acp = .{ .lpVtbl = @constCast(&acp_vtbl) },
        .comp = .{ .lpVtbl = @constCast(&comp_vtbl) },
        .refs = 1,
        .hwnd = g_hwnd,
    };

    // --- TSF bring-up ---
    var tm: ?*anyopaque = null;
    const hr_cc = c.CoCreateInstance(
        &CLSID_TF_ThreadMgr,
        null,
        c.CLSCTX_INPROC_SERVER,
        &IID_ITfThreadMgr,
        @ptrCast(&tm),
    );
    if (hr_cc != S_OK or tm == null) {
        std.debug.print("CoCreateInstance(CLSID_TF_ThreadMgr) failed: {s} (0x{x})\n", .{
            hrName(hr_cc), @as(u32, @bitCast(hr_cc)),
        });
        return error.ThreadMgrFailed;
    }
    thread_mgr = @ptrCast(@alignCast(tm));
    std.debug.print("ITfThreadMgr created\n", .{});

    if (thread_mgr.*.lpVtbl.*.Activate.?(thread_mgr, &client_id) != S_OK) {
        std.debug.print("ITfThreadMgr::Activate failed\n", .{});
        return error.ActivateFailed;
    }
    std.debug.print("activated, client id {d}\n", .{client_id});

    if (thread_mgr.*.lpVtbl.*.CreateDocumentMgr.?(thread_mgr, &doc_mgr) != S_OK) return error.DocMgrFailed;

    // The text store is handed over HERE. From this point the input processor
    // drives the application through ITextStoreACP, not the other way round.
    if (doc_mgr.*.lpVtbl.*.CreateContext.?(
        doc_mgr,
        client_id,
        0,
        @ptrCast(&store.acp),
        &context,
        &edit_cookie,
    ) != S_OK) return error.CreateContextFailed;

    if (doc_mgr.*.lpVtbl.*.Push.?(doc_mgr, context) != S_OK) return error.PushFailed;

    var prev: [*c]c.ITfDocumentMgr = null;
    if (thread_mgr.*.lpVtbl.*.AssociateFocus.?(thread_mgr, g_hwnd, doc_mgr, &prev) != S_OK) {
        return error.AssociateFocusFailed;
    }
    std.debug.print("document manager associated with the window\n\n", .{});

    _ = c.ShowWindow(g_hwnd, c.SW_SHOW);
    _ = c.UpdateWindow(g_hwnd);
    // SetFocus alone is not enough. It assigns keyboard focus WITHIN this
    // thread's active window; it does not make the window foreground. Launched
    // from a console the console keeps the foreground, so an input method sees
    // no focused text store and never starts composing -- which looked exactly
    // like a broken ITextStoreACP until the window was brought forward.
    _ = c.BringWindowToTop(g_hwnd);
    _ = c.SetForegroundWindow(g_hwnd);
    _ = c.SetActiveWindow(g_hwnd);
    _ = c.SetFocus(g_hwnd);

    std.debug.print(
        \\Window open and focused. Switch the input language to Vietnamese
        \\(Win+Space) and type Telex: aw -> a-breve, aws -> a-breve-acute,
        \\dd -> d-stroke, "tieengs vieejt" -> two words.
        \\
        \\What to watch for, and it is the opposite of spike B:
        \\  - SetText puts the COMPOSING characters into the document
        \\  - OnStartComposition marks them provisional, OnEndComposition commits
        \\  - every offset is UTF-16 code units, never bytes
        \\
        \\Close the window to finish.
        \\
        \\
    , .{});

    var msg: c.MSG = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }

    // Teardown in reverse. Leaving the document manager associated or the
    // thread manager active leaks an input context into the thread.
    var dummy: [*c]c.ITfDocumentMgr = null;
    _ = thread_mgr.*.lpVtbl.*.AssociateFocus.?(thread_mgr, g_hwnd, null, &dummy);
    _ = doc_mgr.*.lpVtbl.*.Pop.?(doc_mgr, c.TF_POPF_ALL);
    if (context != null) _ = context.*.lpVtbl.*.Release.?(context);
    if (doc_mgr != null) _ = doc_mgr.*.lpVtbl.*.Release.?(doc_mgr);
    _ = thread_mgr.*.lpVtbl.*.Deactivate.?(thread_mgr);
    _ = thread_mgr.*.lpVtbl.*.Release.?(thread_mgr);

    var buf: [DOC_CAP * 4]u8 = undefined;
    const s = docUtf8(&buf);
    const cps = std.unicode.utf8CountCodepoints(s) catch s.len;
    std.debug.print(
        \\
        \\--- observed ---
        \\  ITextStoreACP calls  {d}
        \\  final text           "{s}"
        \\  utf-16 units (ACP)   {d}
        \\  utf-8 bytes          {d}
        \\  codepoints           {d}
        \\
    , .{ n_calls, s, doc_len, s.len, cps });
}
