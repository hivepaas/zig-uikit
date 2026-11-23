//! Spike D: Windows UI Automation for a self-drawn widget tree, from Zig.
//!
//! The Windows half of tier A. Spike C proved the Linux half: AT-SPI
//! implemented directly over DBus, with Orca reading the tree and decoding the
//! text events. This asks the same question on Windows, and the answer is
//! shaped very differently.
//!
//! BUILT ON LINUX. Zig bundles mingw-w64's `uiautomation.h` and the
//! `uiautomationcore.def` exports, so this cross-compiles to a real PE32+
//! binary with no MSVC, no Windows SDK and no Visual Studio. That matters more
//! than it sounds: the edit-build loop stays on the fast machine and only the
//! run happens in the VM.
//!
//! THE ARCHITECTURAL CONTRAST, which is the point of doing both:
//!
//!   AT-SPI is PUSH, out of process.    UIA is PULL, in process.
//!
//! On Linux the application exports objects on a separate bus, registers with a
//! registry, and hands over a serialised snapshot of the whole tree when asked
//! (`Cache.GetItems`). Screen readers live in another process and talk over
//! DBus.
//!
//! On Windows there is no bus and no registration. The client calls
//! `WM_GETOBJECT` on the window, the application hands back a COM object, and
//! the client then calls straight into the application's vtables, in process,
//! on demand. Nothing is serialised and nothing is cached by the toolkit.
//!
//! For a cross-platform toolkit that is not a detail. An AT-SPI backend wants a
//! tree it can snapshot and serialise; a UIA backend wants stable COM objects
//! with correct reference counting and lifetimes. A single internal
//! accessibility tree can feed both, but the adapters have almost nothing in
//! common beyond the node data.
//!
//! THREE OFFSET UNITS, which is the finding that carries forward:
//!
//!   zwp_text_input_v3  ->  UTF-8 BYTES
//!   AT-SPI             ->  CHARACTERS (codepoints)
//!   Windows BSTR       ->  UTF-16 CODE UNITS
//!
//! Spike B found the first, spike C the second. Windows adds a third, and the
//! sample text is chosen so that all three numbers differ: `tiếng việt 🇻🇳` is
//! 23 bytes, 13 codepoints and 15 UTF-16 code units, because the flag is two
//! non-BMP codepoints that each take a surrogate pair. A text field that gets
//! any one of these wrong is silently incorrect on exactly one platform.
//!
//! SCOPE: a window, a two-node provider tree, the four interfaces an edit
//! control needs, and property-changed events. No rendering beyond a solid
//! fill, consistent with spikes B and C — the risk being tested is the
//! protocol, not the pixels.

const std = @import("std");
const c = @import("c");

// ----------------------------------------------------------------- COM basics

const S_OK: c.HRESULT = 0;
const E_NOINTERFACE: c.HRESULT = @bitCast(@as(u32, 0x8000_4002));
const E_INVALIDARG: c.HRESULT = @bitCast(@as(u32, 0x8007_0057));
const E_POINTER: c.HRESULT = @bitCast(@as(u32, 0x8000_4003));

/// `WM_GETOBJECT`'s lParam for the UIA root. Defined in
/// uiautomationcoreapi.h, which mingw does not expose as a constant.
const UiaRootObjectId: c.LPARAM = -25;

const VT_EMPTY: u16 = 0;
const VT_I4: u16 = 3;
const VT_BSTR: u16 = 8;
const VT_BOOL: u16 = 11;
const VARIANT_TRUE: i16 = -1;
const VARIANT_FALSE: i16 = 0;

/// translate-c renders VARIANT as a chain of anonymous unions that is painful
/// to navigate and does not expose the VT_* constants at all, so the layout is
/// redeclared here. The documented x64 layout is an 8-byte header followed by a
/// 16-byte value union (16 because of BRECORD, which is two pointers), for 24
/// bytes total. The comptime assertion below checks that against the real
/// header rather than trusting this comment.
const VARIANT = extern struct {
    vt: u16 = VT_EMPTY,
    r1: u16 = 0,
    r2: u16 = 0,
    r3: u16 = 0,
    val: extern union {
        llVal: i64,
        lVal: i32,
        boolVal: i16,
        bstrVal: ?[*:0]u16,
        punkVal: ?*anyopaque,
        brecord: extern struct { pv: ?*anyopaque, pri: ?*anyopaque },
    } = .{ .llVal = 0 },

    fn ptr(self: *VARIANT) [*c]c.VARIANT {
        return @ptrCast(self);
    }
};

comptime {
    std.debug.assert(@sizeOf(VARIANT) == @sizeOf(c.VARIANT));
    std.debug.assert(@sizeOf(VARIANT) == 24);
}

fn guid(a: u32, b: u16, cc: u16, d: [8]u8) c.GUID {
    return .{ .Data1 = a, .Data2 = b, .Data3 = cc, .Data4 = d };
}

/// mingw declares the interface IIDs as `extern const GUID` but ships no import
/// library that defines them, so the values are taken from the DEFINE_GUID
/// macros in the bundled headers.
const IID_IUnknown = guid(0x00000000, 0x0000, 0x0000, .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 });
const IID_ISimple = guid(0xd6dd68d1, 0x86fd, 0x4332, .{ 0x86, 0x66, 0x9a, 0xbe, 0xde, 0xa2, 0xd2, 0x4c });
const IID_IFragment = guid(0xf7063da8, 0x8359, 0x439c, .{ 0x92, 0x97, 0xbb, 0xc5, 0x29, 0x9a, 0x7d, 0x87 });
const IID_IFragmentRoot = guid(0x620ce2a5, 0xab8f, 0x40a9, .{ 0x86, 0xcb, 0xde, 0x3c, 0x75, 0x59, 0x9b, 0x58 });
const IID_IValue = guid(0xc7935180, 0x6fb3, 0x4201, .{ 0xb1, 0x74, 0x7d, 0xf7, 0x3a, 0xdb, 0xf6, 0x4a });

fn sameGuid(a: [*c]const c.IID, b: *const c.GUID) bool {
    if (a == null) return false;
    return std.mem.eql(u8, std.mem.asBytes(&a.*), std.mem.asBytes(b));
}

// ------------------------------------------------------------------ node data

/// The same shape as spike C's node, so the two backends can be compared
/// directly. Roles differ (UIA control types vs AT-SPI roles) but nothing else
/// about the data does, which is the evidence that one internal tree can feed
/// both.
const Node = struct {
    name: [:0]const u16,
    control_type: c.LONG,
    parent: i32,
    children: []const u32,
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
    has_value: bool = false,
    keyboard_focusable: bool = false,
};

fn L(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

/// All three numbers differ for this string. See the header.
const ENTRY_TEXT_UTF8 = "tiếng việt 🇻🇳";

var nodes = [_]Node{
    .{
        // The window itself. UIA_PaneControlTypeId reads as "pane"; a real
        // toolkit would use Window for a top level frame.
        .name = L("zig-uikit UIA spike"),
        .control_type = c.UIA_PaneControlTypeId,
        .parent = -1,
        .children = &.{1},
        .w = 720,
        .h = 180,
    },
    .{
        .name = L("Name"),
        .control_type = c.UIA_EditControlTypeId,
        .parent = 0,
        .children = &.{},
        .x = 8,
        .y = 40,
        .w = 300,
        .h = 28,
        .has_value = true,
        .keyboard_focusable = true,
    },
};

/// The entry's live text, UTF-16 because that is what a BSTR is. The
/// conversions in and out are the whole point; see `reportUnits`.
var entry_utf16: [256:0]u16 = undefined;
var entry_utf16_len: usize = 0;

fn setEntryText(utf8: []const u8) void {
    entry_utf16_len = std.unicode.utf8ToUtf16Le(entry_utf16[0..], utf8) catch 0;
    entry_utf16[entry_utf16_len] = 0;
}

// --------------------------------------------------------------- the provider

/// One COM object exposing four interfaces. A pointer to each embedded
/// interface struct is a valid pointer to that interface, because each is just
/// a vtable pointer; `QueryInterface` hands out the right one and every method
/// recovers the Provider by subtracting its own field offset.
const Provider = extern struct {
    simple: c.IRawElementProviderSimple,
    fragment: c.IRawElementProviderFragment,
    froot: c.IRawElementProviderFragmentRoot,
    value: c.IValueProvider,
    refs: i32,
    node: u32,
    // `c.HWND` is already a nullable C pointer; wrapping it in `?` gives an
    // optional with no guaranteed layout, which an extern struct forbids.
    hwnd: c.HWND,
};

var providers: [nodes.len]Provider = undefined;

fn fromSimple(this: [*c]c.IRawElementProviderSimple) *Provider {
    return @ptrFromInt(@intFromPtr(this) - @offsetOf(Provider, "simple"));
}
fn fromFragment(this: [*c]c.IRawElementProviderFragment) *Provider {
    return @ptrFromInt(@intFromPtr(this) - @offsetOf(Provider, "fragment"));
}
fn fromFRoot(this: [*c]c.IRawElementProviderFragmentRoot) *Provider {
    return @ptrFromInt(@intFromPtr(this) - @offsetOf(Provider, "froot"));
}
fn fromValue(this: [*c]c.IValueProvider) *Provider {
    return @ptrFromInt(@intFromPtr(this) - @offsetOf(Provider, "value"));
}

var n_calls: u32 = 0;
var n_events: u32 = 0;

fn log(comptime fmt: []const u8, args: anytype) void {
    n_calls += 1;
    std.debug.print("  -> " ++ fmt ++ "\n", args);
}

/// Shared by all four interfaces. The returned pointer must be the one matching
/// the requested interface, not simply the object.
fn qi(p: *Provider, riid: [*c]const c.IID, out: [*c]?*anyopaque) c.HRESULT {
    if (out == null) return E_POINTER;
    out.* = null;
    if (sameGuid(riid, &IID_IUnknown) or sameGuid(riid, &IID_ISimple)) {
        out.* = @ptrCast(&p.simple);
    } else if (sameGuid(riid, &IID_IFragment)) {
        out.* = @ptrCast(&p.fragment);
    } else if (sameGuid(riid, &IID_IFragmentRoot)) {
        // Only the root is a fragment root.
        if (p.node != 0) return E_NOINTERFACE;
        out.* = @ptrCast(&p.froot);
    } else if (sameGuid(riid, &IID_IValue)) {
        if (!nodes[p.node].has_value) return E_NOINTERFACE;
        out.* = @ptrCast(&p.value);
    } else {
        return E_NOINTERFACE;
    }
    p.refs += 1;
    return S_OK;
}

fn addRef(p: *Provider) c.ULONG {
    p.refs += 1;
    return @intCast(p.refs);
}

/// The providers are statically allocated for the life of the process, so
/// Release never frees. A real toolkit must free here, and must also call
/// UiaDisconnectProvider when an element goes away -- a client can hold a
/// provider reference across the element's destruction, which is the main
/// lifetime hazard UIA has and AT-SPI does not.
fn release(p: *Provider) c.ULONG {
    if (p.refs > 0) p.refs -= 1;
    return @intCast(p.refs);
}

// --- IRawElementProviderSimple ---

fn s_QI(this: [*c]c.IRawElementProviderSimple, riid: [*c]const c.IID, out: [*c]?*anyopaque) callconv(.c) c.HRESULT {
    return qi(fromSimple(this), riid, out);
}
fn s_AddRef(this: [*c]c.IRawElementProviderSimple) callconv(.c) c.ULONG {
    return addRef(fromSimple(this));
}
fn s_Release(this: [*c]c.IRawElementProviderSimple) callconv(.c) c.ULONG {
    return release(fromSimple(this));
}

fn s_ProviderOptions(this: [*c]c.IRawElementProviderSimple, out: [*c]c.enum_ProviderOptions) callconv(.c) c.HRESULT {
    _ = this;
    if (out == null) return E_POINTER;
    out.* = c.ProviderOptions_ServerSideProvider | c.ProviderOptions_UseComThreading;
    return S_OK;
}

fn s_GetPatternProvider(this: [*c]c.IRawElementProviderSimple, pattern: c.PATTERNID, out: [*c][*c]c.IUnknown) callconv(.c) c.HRESULT {
    if (out == null) return E_POINTER;
    out.* = null;
    const p = fromSimple(this);
    if (pattern == c.UIA_ValuePatternId and nodes[p.node].has_value) {
        log("GetPatternProvider(Value) node={d}", .{p.node});
        p.refs += 1;
        out.* = @ptrCast(&p.value);
    }
    return S_OK;
}

fn s_GetPropertyValue(this: [*c]c.IRawElementProviderSimple, prop: c.PROPERTYID, out: [*c]c.VARIANT) callconv(.c) c.HRESULT {
    if (out == null) return E_POINTER;
    const p = fromSimple(this);
    const n = &nodes[p.node];
    var v: VARIANT = .{};

    if (prop == c.UIA_NamePropertyId) {
        v.vt = VT_BSTR;
        v.val.bstrVal = c.SysAllocString(n.name.ptr);
        log("GetPropertyValue(Name) node={d}", .{p.node});
    } else if (prop == c.UIA_ControlTypePropertyId) {
        v.vt = VT_I4;
        v.val.lVal = n.control_type;
        log("GetPropertyValue(ControlType) node={d}", .{p.node});
    } else if (prop == c.UIA_IsKeyboardFocusablePropertyId) {
        v.vt = VT_BOOL;
        v.val.boolVal = if (n.keyboard_focusable) VARIANT_TRUE else VARIANT_FALSE;
    } else if (prop == c.UIA_IsControlElementPropertyId or prop == c.UIA_IsContentElementPropertyId) {
        v.vt = VT_BOOL;
        v.val.boolVal = VARIANT_TRUE;
    } else if (prop == c.UIA_IsEnabledPropertyId) {
        v.vt = VT_BOOL;
        v.val.boolVal = VARIANT_TRUE;
    } else if (prop == c.UIA_ValueValuePropertyId and n.has_value) {
        v.vt = VT_BSTR;
        v.val.bstrVal = c.SysAllocString(&entry_utf16);
        log("GetPropertyValue(Value) node={d}", .{p.node});
    } else if (prop == c.UIA_ProviderDescriptionPropertyId) {
        v.vt = VT_BSTR;
        v.val.bstrVal = c.SysAllocString(L("zig-uikit UIA spike (direct provider)").ptr);
    } else {
        // VT_EMPTY is how a provider says "I do not supply this property", and
        // UIA then falls back. Returning an error here instead makes clients
        // treat the element as broken.
        v.vt = VT_EMPTY;
    }
    const dst: *VARIANT = @ptrCast(out);
    dst.* = v;
    return S_OK;
}

fn s_HostProvider(this: [*c]c.IRawElementProviderSimple, out: [*c][*c]c.IRawElementProviderSimple) callconv(.c) c.HRESULT {
    if (out == null) return E_POINTER;
    out.* = null;
    const p = fromSimple(this);
    // Only the fragment root has a host: the window provider that supplies the
    // default window properties. Children must return null or UIA reports the
    // tree twice.
    if (p.node == 0 and p.hwnd != null) {
        log("get_HostRawElementProvider node=0", .{});
        return c.UiaHostProviderFromHwnd(p.hwnd, out);
    }
    return S_OK;
}

const simple_vtbl = c.IRawElementProviderSimpleVtbl{
    .QueryInterface = s_QI,
    .AddRef = s_AddRef,
    .Release = s_Release,
    .get_ProviderOptions = s_ProviderOptions,
    .GetPatternProvider = s_GetPatternProvider,
    .GetPropertyValue = s_GetPropertyValue,
    .get_HostRawElementProvider = s_HostProvider,
};

// --- IRawElementProviderFragment ---

fn f_QI(this: [*c]c.IRawElementProviderFragment, riid: [*c]const c.IID, out: [*c]?*anyopaque) callconv(.c) c.HRESULT {
    return qi(fromFragment(this), riid, out);
}
fn f_AddRef(this: [*c]c.IRawElementProviderFragment) callconv(.c) c.ULONG {
    return addRef(fromFragment(this));
}
fn f_Release(this: [*c]c.IRawElementProviderFragment) callconv(.c) c.ULONG {
    return release(fromFragment(this));
}

fn f_Navigate(this: [*c]c.IRawElementProviderFragment, dir: c.NavigateDirection, out: [*c][*c]c.IRawElementProviderFragment) callconv(.c) c.HRESULT {
    if (out == null) return E_POINTER;
    out.* = null;
    const p = fromFragment(this);
    const n = &nodes[p.node];

    const target: ?u32 = switch (dir) {
        c.NavigateDirection_Parent => if (n.parent < 0) null else @intCast(n.parent),
        c.NavigateDirection_FirstChild => if (n.children.len == 0) null else n.children[0],
        c.NavigateDirection_LastChild => if (n.children.len == 0) null else n.children[n.children.len - 1],
        c.NavigateDirection_NextSibling, c.NavigateDirection_PreviousSibling => blk: {
            if (n.parent < 0) break :blk null;
            const sib = nodes[@intCast(n.parent)].children;
            var idx: ?usize = null;
            for (sib, 0..) |ci, k| if (ci == p.node) {
                idx = k;
            };
            const i = idx orelse break :blk null;
            if (dir == c.NavigateDirection_NextSibling) {
                break :blk if (i + 1 < sib.len) sib[i + 1] else null;
            }
            break :blk if (i > 0) sib[i - 1] else null;
        },
        else => null,
    };

    log("Navigate(dir={d}) node={d} -> {?d}", .{ dir, p.node, target });
    if (target) |t| {
        providers[t].refs += 1;
        out.* = @ptrCast(&providers[t].fragment);
    }
    return S_OK;
}

/// A runtime id must be unique within the desktop and STABLE for the element's
/// lifetime -- clients use it to tell "same element" from "new element". The
/// convention is to prefix with UiaAppendRuntimeId so the host window's id is
/// prepended. Returning a fresh id each call makes a screen reader announce
/// every element as new.
fn f_GetRuntimeId(this: [*c]c.IRawElementProviderFragment, out: [*c][*c]c.SAFEARRAY) callconv(.c) c.HRESULT {
    if (out == null) return E_POINTER;
    out.* = null;
    const p = fromFragment(this);
    if (p.node == 0) return S_OK; // the host provider supplies the root's id

    const UiaAppendRuntimeId: c.LONG = 3;
    const sa = c.SafeArrayCreateVector(VT_I4, 0, 2) orelse return E_INVALIDARG;
    var idx: c.LONG = 0;
    var v0: c.LONG = UiaAppendRuntimeId;
    var v1: c.LONG = @intCast(p.node + 1);
    _ = c.SafeArrayPutElement(sa, &idx, &v0);
    idx = 1;
    _ = c.SafeArrayPutElement(sa, &idx, &v1);
    out.* = sa;
    log("GetRuntimeId node={d}", .{p.node});
    return S_OK;
}

fn f_BoundingRect(this: [*c]c.IRawElementProviderFragment, out: [*c]c.UiaRect) callconv(.c) c.HRESULT {
    if (out == null) return E_POINTER;
    const p = fromFragment(this);
    const n = &nodes[p.node];
    // UIA wants SCREEN coordinates. Client-relative values here put a screen
    // reader's highlight in the wrong place, which is invisible until someone
    // actually uses it.
    var origin = c.POINT{ .x = 0, .y = 0 };
    if (p.hwnd != null) _ = c.ClientToScreen(p.hwnd, &origin);
    out.* = .{
        .left = n.x + @as(f64, @floatFromInt(origin.x)),
        .top = n.y + @as(f64, @floatFromInt(origin.y)),
        .width = n.w,
        .height = n.h,
    };
    log("get_BoundingRectangle node={d}", .{p.node});
    return S_OK;
}

fn f_EmbeddedRoots(this: [*c]c.IRawElementProviderFragment, out: [*c][*c]c.SAFEARRAY) callconv(.c) c.HRESULT {
    _ = this;
    if (out == null) return E_POINTER;
    out.* = null;
    return S_OK;
}

fn f_SetFocus(this: [*c]c.IRawElementProviderFragment) callconv(.c) c.HRESULT {
    const p = fromFragment(this);
    log("SetFocus node={d}", .{p.node});
    return S_OK;
}

fn f_FragmentRoot(this: [*c]c.IRawElementProviderFragment, out: [*c][*c]c.IRawElementProviderFragmentRoot) callconv(.c) c.HRESULT {
    _ = this;
    if (out == null) return E_POINTER;
    providers[0].refs += 1;
    out.* = @ptrCast(&providers[0].froot);
    return S_OK;
}

const fragment_vtbl = c.IRawElementProviderFragmentVtbl{
    .QueryInterface = f_QI,
    .AddRef = f_AddRef,
    .Release = f_Release,
    .Navigate = f_Navigate,
    .GetRuntimeId = f_GetRuntimeId,
    .get_BoundingRectangle = f_BoundingRect,
    .GetEmbeddedFragmentRoots = f_EmbeddedRoots,
    .SetFocus = f_SetFocus,
    .get_FragmentRoot = f_FragmentRoot,
};

// --- IRawElementProviderFragmentRoot ---

fn r_QI(this: [*c]c.IRawElementProviderFragmentRoot, riid: [*c]const c.IID, out: [*c]?*anyopaque) callconv(.c) c.HRESULT {
    return qi(fromFRoot(this), riid, out);
}
fn r_AddRef(this: [*c]c.IRawElementProviderFragmentRoot) callconv(.c) c.ULONG {
    return addRef(fromFRoot(this));
}
fn r_Release(this: [*c]c.IRawElementProviderFragmentRoot) callconv(.c) c.ULONG {
    return release(fromFRoot(this));
}

fn r_FromPoint(this: [*c]c.IRawElementProviderFragmentRoot, x: f64, y: f64, out: [*c][*c]c.IRawElementProviderFragment) callconv(.c) c.HRESULT {
    if (out == null) return E_POINTER;
    out.* = null;
    const p = fromFRoot(this);
    var origin = c.POINT{ .x = 0, .y = 0 };
    if (p.hwnd != null) _ = c.ClientToScreen(p.hwnd, &origin);
    const cx = x - @as(f64, @floatFromInt(origin.x));
    const cy = y - @as(f64, @floatFromInt(origin.y));
    const n = nodes[1];
    if (cx >= n.x and cx < n.x + n.w and cy >= n.y and cy < n.y + n.h) {
        providers[1].refs += 1;
        out.* = @ptrCast(&providers[1].fragment);
        log("ElementProviderFromPoint -> node=1", .{});
    }
    return S_OK;
}

fn r_GetFocus(this: [*c]c.IRawElementProviderFragmentRoot, out: [*c][*c]c.IRawElementProviderFragment) callconv(.c) c.HRESULT {
    _ = this;
    if (out == null) return E_POINTER;
    providers[1].refs += 1;
    out.* = @ptrCast(&providers[1].fragment);
    log("GetFocus -> node=1", .{});
    return S_OK;
}

const froot_vtbl = c.IRawElementProviderFragmentRootVtbl{
    .QueryInterface = r_QI,
    .AddRef = r_AddRef,
    .Release = r_Release,
    .ElementProviderFromPoint = r_FromPoint,
    .GetFocus = r_GetFocus,
};

// --- IValueProvider ---

fn v_QI(this: [*c]c.IValueProvider, riid: [*c]const c.IID, out: [*c]?*anyopaque) callconv(.c) c.HRESULT {
    return qi(fromValue(this), riid, out);
}
fn v_AddRef(this: [*c]c.IValueProvider) callconv(.c) c.ULONG {
    return addRef(fromValue(this));
}
fn v_Release(this: [*c]c.IValueProvider) callconv(.c) c.ULONG {
    return release(fromValue(this));
}

fn v_SetValue(this: [*c]c.IValueProvider, val: [*c]const u16) callconv(.c) c.HRESULT {
    _ = this;
    if (val == null) return E_POINTER;
    const s = std.mem.span(@as([*:0]const u16, @ptrCast(val)));
    const n = @min(s.len, entry_utf16.len - 1);
    @memcpy(entry_utf16[0..n], s[0..n]);
    entry_utf16_len = n;
    entry_utf16[n] = 0;
    log("SetValue (len={d} utf16 units)", .{n});
    raiseValueChanged();
    return S_OK;
}

fn v_GetValue(this: [*c]c.IValueProvider, out: [*c][*c]u16) callconv(.c) c.HRESULT {
    _ = this;
    if (out == null) return E_POINTER;
    out.* = c.SysAllocString(&entry_utf16);
    log("get_Value", .{});
    return S_OK;
}

fn v_IsReadOnly(this: [*c]c.IValueProvider, out: [*c]c.BOOL) callconv(.c) c.HRESULT {
    _ = this;
    if (out == null) return E_POINTER;
    out.* = 0;
    return S_OK;
}

const value_vtbl = c.IValueProviderVtbl{
    .QueryInterface = v_QI,
    .AddRef = v_AddRef,
    .Release = v_Release,
    .SetValue = v_SetValue,
    .get_Value = v_GetValue,
    .get_IsReadOnly = v_IsReadOnly,
};

// ---------------------------------------------------------------------- events

/// The Windows analogue of AT-SPI's GetRegisteredEvents -- but a WEAKER one,
/// and measurement corrected the assumption here.
///
/// On Linux, GetRegisteredEvents returned an empty array with no screen reader
/// running, so it gates event work precisely. UiaClientsAreListening returned
/// TRUE on an idle Windows 11 desktop with no screen reader at all: Windows
/// itself has UIA clients. So it distinguishes "something uses UIA" from
/// "nothing does", not "a screen reader needs this" from "nobody does".
///
/// It is still worth calling -- it is one cheap call and it is correct when it
/// returns false -- but it cannot be relied on to skip the work.
fn clientsListening() bool {
    return c.UiaClientsAreListening() != 0;
}

fn raiseValueChanged() void {
    if (!clientsListening()) return;
    var old: VARIANT = .{ .vt = VT_EMPTY };
    var new: VARIANT = .{ .vt = VT_BSTR };
    new.val.bstrVal = c.SysAllocString(&entry_utf16);
    _ = c.UiaRaiseAutomationPropertyChangedEvent(
        @ptrCast(&providers[1].simple),
        c.UIA_ValueValuePropertyId,
        old.ptr().*,
        new.ptr().*,
    );
    n_events += 1;
    std.debug.print("  <= PropertyChanged(Value) {d} utf16 units\n", .{entry_utf16_len});
}

fn raiseFocus() void {
    if (!clientsListening()) return;
    _ = c.UiaRaiseAutomationEvent(
        @ptrCast(&providers[1].simple),
        c.UIA_AutomationFocusChangedEventId,
    );
    n_events += 1;
    std.debug.print("  <= AutomationFocusChanged on node=1\n", .{});
}

// ---------------------------------------------------------------- the window

var g_hwnd: c.HWND = null;

fn wndProc(h: c.HWND, msg: c.UINT, wp: c.WPARAM, lp: c.LPARAM) callconv(.c) c.LRESULT {
    switch (msg) {
        c.WM_GETOBJECT => {
            // This is the ENTIRE handshake. No bus, no registration, no
            // announcement: a client asks the window for an object and then
            // calls into this process directly.
            if (lp == UiaRootObjectId) {
                std.debug.print("  -> WM_GETOBJECT(UiaRootObjectId): handing over the root provider\n", .{});
                n_calls += 1;
                return c.UiaReturnRawElementProvider(h, wp, lp, @ptrCast(&providers[0].simple));
            }
            return 0;
        },
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
        c.WM_SETFOCUS => {
            raiseFocus();
            return 0;
        },
        c.WM_DESTROY => {
            c.PostQuitMessage(0);
            return 0;
        },
        else => return c.DefWindowProcW(h, msg, wp, lp),
    }
}

// ---------------------------------------------------------------- unit report

fn reportUnits(label: []const u8, utf8: []const u8) void {
    var buf: [256]u16 = undefined;
    const u16_len = std.unicode.utf8ToUtf16Le(buf[0..], utf8) catch 0;
    const cps = std.unicode.utf8CountCodepoints(utf8) catch utf8.len;
    std.debug.print("  {s:<16} {d:>3} bytes  {d:>3} codepoints  {d:>3} utf16 units\n", .{
        label, utf8.len, cps, u16_len,
    });
}

// ---------------------------------------------------------------------- main

pub fn main() !void {
    _ = c.CoInitializeEx(null, c.COINIT_APARTMENTTHREADED);
    defer c.CoUninitialize();

    std.debug.print(
        \\zig-uikit UIA spike -- UI Automation provider, implemented directly.
        \\Cross-compiled on Linux: no MSVC, no Windows SDK.
        \\
        \\Three offset units, one text field:
        \\
    , .{});
    reportUnits("entry text", ENTRY_TEXT_UTF8);
    reportUnits("tieng viet", "tiếng việt");
    reportUnits("ascii only", "tieng viet");
    std.debug.print(
        \\
        \\  utf-8 bytes      <- zwp_text_input_v3 (spike B)
        \\  codepoints       <- AT-SPI            (spike C)
        \\  utf-16 units     <- Windows BSTR      (this spike)
        \\
        \\
    , .{});

    setEntryText(ENTRY_TEXT_UTF8);

    for (&providers, 0..) |*p, i| {
        p.* = .{
            .simple = .{ .lpVtbl = @constCast(&simple_vtbl) },
            .fragment = .{ .lpVtbl = @constCast(&fragment_vtbl) },
            .froot = .{ .lpVtbl = @constCast(&froot_vtbl) },
            .value = .{ .lpVtbl = @constCast(&value_vtbl) },
            .refs = 1,
            .node = @intCast(i),
            .hwnd = null,
        };
    }

    const hinst = c.GetModuleHandleW(null);
    var wc = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = @ptrCast(hinst);
    wc.lpszClassName = L("ZigUikitUiaSpike").ptr;
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW
    if (c.RegisterClassExW(&wc) == 0) {
        std.debug.print("RegisterClassExW failed: {d}\n", .{c.GetLastError()});
        return error.RegisterClassFailed;
    }

    g_hwnd = c.CreateWindowExW(
        0,
        wc.lpszClassName,
        L("zig-uikit UIA spike - Narrator should read the edit field").ptr,
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
    if (g_hwnd == null) {
        std.debug.print("CreateWindowExW failed: {d}\n", .{c.GetLastError()});
        return error.CreateWindowFailed;
    }
    for (&providers) |*p| p.hwnd = g_hwnd;

    _ = c.ShowWindow(g_hwnd, c.SW_SHOW);
    _ = c.UpdateWindow(g_hwnd);

    std.debug.print(
        \\Window open. UiaClientsAreListening() = {s}
        \\
        \\  Start Narrator with Ctrl+Win+Enter, then Tab/arrow into the window.
        \\  Every UIA call into this process is logged below.
        \\
        \\  Close the window to finish.
        \\
        \\
    , .{if (clientsListening()) "true (an assistive client is active)" else "false (nothing listening yet)"});

    var msg: c.MSG = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }

    std.debug.print(
        "\n--- observed ---\n  uia calls served  {d}\n  events raised     {d}\n",
        .{ n_calls, n_events },
    );
}
