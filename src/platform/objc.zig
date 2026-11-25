//! The Objective-C runtime, reached through its C entry points.
//!
//! Zig has no Objective-C support, and every macOS API this toolkit needs --
//! AppKit, Metal, Core Animation -- is an Objective-C API. They are all reached
//! the way the Objective-C compiler reaches them: `objc_msgSend`, cast to the
//! exact C signature of the method being called.
//!
//! That cast is the whole trick and the whole risk. `objc_msgSend` is a
//! trampoline that jumps to the method's implementation with the argument
//! registers untouched, so calling it through the right function type *is*
//! calling the method. Calling it through the wrong one passes garbage, and
//! nothing checks: there are no headers here, only the signatures written at
//! each call site. `send` builds the function type from the arguments' Zig
//! types, so the one rule is that every argument has a concrete C type --
//! `@as(usize, 0)`, never a bare `0`.
//!
//! The same runtime is how classes are *defined*, not only called. A window
//! delegate, and later the view that implements `NSTextInputClient`, is a class
//! registered at run time with `objc_allocateClassPair` and given methods whose
//! implementations are Zig functions. `ClassBuilder` wraps that.

const std = @import("std");
const builtin = @import("builtin");

pub const Object = opaque {};
pub const id = *Object;
pub const Selector = opaque {};
pub const SEL = *Selector;
pub const ClassT = opaque {};
pub const Class = *ClassT;
pub const IvarT = opaque {};
pub const Ivar = *IvarT;

/// `BOOL` is C `bool` on Apple silicon and `signed char` on Intel. Both are one
/// byte in a register, so passing either is the same; only reading one back
/// differs, and `truthy` covers that.
pub const BOOL = if (builtin.cpu.arch == .aarch64) bool else i8;
pub const YES: BOOL = if (BOOL == bool) true else 1;
pub const NO: BOOL = if (BOOL == bool) false else 0;

pub fn truthy(b: BOOL) bool {
    return if (BOOL == bool) b else b != 0;
}

pub const NSInteger = isize;
pub const NSUInteger = usize;
pub const CGFloat = f64;

pub const CGPoint = extern struct { x: CGFloat, y: CGFloat };
pub const CGSize = extern struct { width: CGFloat, height: CGFloat };
pub const CGRect = extern struct { origin: CGPoint, size: CGSize };

extern "objc" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
extern "objc" fn sel_getName(s: SEL) [*:0]const u8;
extern "objc" fn objc_msgSend() void;
extern "objc" fn objc_msgSend_stret() void;
extern "objc" fn objc_msgSendSuper() void;
extern "objc" fn class_getSuperclass(cls: Class) ?Class;
extern "objc" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra: usize) ?Class;
extern "objc" fn objc_registerClassPair(cls: Class) void;
extern "objc" fn class_addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) BOOL;
extern "objc" fn class_addIvar(cls: Class, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) BOOL;
extern "objc" fn class_addProtocol(cls: Class, protocol: *anyopaque) BOOL;
extern "objc" fn class_getInstanceVariable(cls: Class, name: [*:0]const u8) ?Ivar;
extern "objc" fn ivar_getOffset(v: Ivar) isize;
extern "objc" fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;
extern "objc" fn objc_autoreleasePoolPush() *anyopaque;
extern "objc" fn objc_autoreleasePoolPop(pool: *anyopaque) void;

pub const Error = error{ ClassNotFound, ClassExists, MethodRejected, IvarRejected, ProtocolNotFound };

/// Looks a class up by name. Classes come from linked frameworks, so a missing
/// one means a framework was not linked, which is a build mistake rather than a
/// run-time condition; it is still reported rather than crashed on.
pub fn class(comptime name: [:0]const u8) Error!Class {
    return objc_getClass(name) orelse Error.ClassNotFound;
}

/// A selector, registered once per name and cached, so a call site in a frame
/// loop does not pay the runtime's selector table lookup on every frame.
///
/// The cache is a static in a struct that must *mention* `name`. A container
/// declared in a generic function is only a distinct type per instantiation if
/// it captures the comptime parameter; without `_name` below there is one
/// `cached` for every selector, the first one registered wins, and `retain`
/// is sent as `newCommandQueue` -- which is how this was found.
pub fn sel(comptime name: [:0]const u8) SEL {
    const S = struct {
        const _name = name;
        var cached: ?SEL = null;
    };
    if (S.cached) |s| return s;
    const s = sel_registerName(name);
    S.cached = s;
    return s;
}

/// A selector's name: what `doCommandBySelector:` was asked to do.
pub fn selName(s: SEL) []const u8 {
    return std.mem.span(sel_getName(s));
}

/// Sends a message: `[target selector:args...]`.
///
/// `Ret` and the types of `args` *are* the method's signature, and there is no
/// header to check them against. Integer and float literals must be given a
/// type; a bare literal is a compile error here rather than a guess.
pub fn send(comptime Ret: type, target: anytype, comptime selector: [:0]const u8, args: anytype) Ret {
    const Target = @TypeOf(target);
    const info = @typeInfo(@TypeOf(args)).@"struct";
    const params = comptime blk: {
        var p: [info.field_types.len + 2]type = undefined;
        p[0] = Target;
        p[1] = SEL;
        for (info.field_types, info.field_names, 0..) |T, n, i| {
            if (T == comptime_int or T == comptime_float)
                @compileError("objc.send(" ++ selector ++ "): argument " ++ n ++
                    " is an untyped literal; give it a C type with @as");
            p[i + 2] = T;
        }
        break :blk p;
    };
    const attrs: [params.len]std.lang.Type.Fn.ParamAttributes = @splat(.{});
    const F = @Fn(&params, &attrs, Ret, .{ .@"callconv" = .c });
    // On Intel a struct too large for two registers is returned through a
    // hidden pointer, and the runtime has a separate trampoline for that. On
    // Apple silicon there is one trampoline for everything. The Intel branch
    // compiles but has not been run.
    const tramp = if (builtin.cpu.arch == .x86_64 and @typeInfo(Ret) == .@"struct" and @sizeOf(Ret) > 16)
        &objc_msgSend_stret
    else
        &objc_msgSend;
    const f: *const F = @ptrCast(tramp);
    return @call(.auto, f, .{ target, sel(selector) } ++ args);
}

/// `[super selector]` from inside a method of `cls`: the superclass's
/// implementation, run on `target`. What a `dealloc` override has to end with.
pub fn sendSuper(comptime Ret: type, target: id, cls: Class, comptime selector: [:0]const u8, args: anytype) Ret {
    const Super = extern struct { receiver: id, super_class: Class };
    var sup: Super = .{ .receiver = target, .super_class = class_getSuperclass(cls).? };
    const info = @typeInfo(@TypeOf(args)).@"struct";
    const params = comptime blk: {
        var p: [info.field_types.len + 2]type = undefined;
        p[0] = *Super;
        p[1] = SEL;
        for (info.field_types, 2..) |T, i| p[i] = T;
        break :blk p;
    };
    const attrs: [params.len]std.lang.Type.Fn.ParamAttributes = @splat(.{});
    const F = @Fn(&params, &attrs, Ret, .{ .@"callconv" = .c });
    const f: *const F = @ptrCast(&objc_msgSendSuper);
    return @call(.auto, f, .{ &sup, sel(selector) } ++ args);
}

/// `[[cls alloc] init]`: a +1 reference the caller owns and must `release`.
pub fn new(cls: Class) id {
    const a = send(id, cls, "alloc", .{});
    return send(id, a, "init", .{});
}

pub fn retain(obj: id) id {
    return send(id, obj, "retain", .{});
}

pub fn release(obj: id) void {
    send(void, obj, "release", .{});
}

/// An autoreleased `NSString`. Only valid inside an `AutoreleasePool`.
pub fn string(s: [*:0]const u8) id {
    const cls = class("NSString") catch unreachable;
    return send(id, cls, "stringWithUTF8String:", .{s});
}

/// An autoreleased `NSString` from UTF-8 bytes that need not be terminated.
pub fn stringFromSlice(s: []const u8) id {
    const NSUTF8StringEncoding: NSUInteger = 4;
    const cls = class("NSString") catch unreachable;
    const str = send(id, send(id, cls, "alloc", .{}), "initWithBytes:length:encoding:", .{
        s.ptr, s.len, NSUTF8StringEncoding,
    });
    return send(id, str, "autorelease", .{});
}

/// The UTF-8 bytes of an `NSString`, borrowed for as long as the string lives.
pub fn utf8(s: id) []const u8 {
    const p = send(?[*:0]const u8, s, "UTF8String", .{}) orelse return "";
    return std.mem.span(p);
}

/// Every Cocoa method that returns an object not named `new`, `alloc`, `copy`
/// or `mutableCopy` hands back an autoreleased one, and Metal's `nextDrawable`
/// is among them. A loop that does not drain a pool per iteration grows without
/// bound; that is what this is for.
pub const AutoreleasePool = struct {
    handle: *anyopaque,

    pub fn push() AutoreleasePool {
        return .{ .handle = objc_autoreleasePoolPush() };
    }

    pub fn pop(self: AutoreleasePool) void {
        objc_autoreleasePoolPop(self.handle);
    }
};

/// Defines an Objective-C class at run time, with Zig functions as its methods
/// and one pointer-sized instance variable that points back at Zig state.
///
/// A class name is process-global and can be registered once. `define` returns
/// the existing class when the name is already taken by an earlier call, which
/// is what lets a second window reuse the delegate class the first defined.
pub const ClassBuilder = struct {
    cls: Class,

    pub const ivar_name = "zig_state";

    /// Starts a new class, or returns null when one of this name already exists
    /// and the caller should look it up instead.
    pub fn begin(comptime superclass: [:0]const u8, comptime name: [:0]const u8) Error!?ClassBuilder {
        if (objc_getClass(name) != null) return null;
        const super = try class(superclass);
        const cls = objc_allocateClassPair(super, name, 0) orelse return Error.ClassExists;
        // "^v": a void pointer. The alignment argument is log2 of the byte
        // alignment, not the alignment itself.
        if (!truthy(class_addIvar(cls, ivar_name, @sizeOf(usize), std.math.log2_int(usize, @alignOf(usize)), "^v")))
            return Error.IvarRejected;
        return .{ .cls = cls };
    }

    /// Adds a method. `types` is the Objective-C type encoding of the
    /// signature, return type first: `"v@:@"` is `void (id self, SEL _cmd, id)`.
    pub fn method(self: ClassBuilder, comptime selector: [:0]const u8, imp: *const anyopaque, comptime types: [:0]const u8) Error!void {
        if (!truthy(class_addMethod(self.cls, sel(selector), imp, types))) return Error.MethodRejected;
    }

    /// Declares conformance to a protocol by name. Unknown protocols are
    /// skipped: conformance is advisory for the delegate protocols used here.
    pub fn protocol(self: ClassBuilder, comptime name: [:0]const u8) void {
        if (objc_getProtocol(name)) |p| _ = class_addProtocol(self.cls, p);
    }

    /// Declares conformance, and fails when the protocol is not known to the
    /// runtime. For a protocol that AppKit *checks* rather than merely
    /// documents: `-[NSView inputContext]` returns nil for a view that does not
    /// conform to `NSTextInputClient`, and the symptom of that is an input
    /// method that silently never starts.
    pub fn requireProtocol(self: ClassBuilder, comptime name: [:0]const u8) Error!void {
        const p = objc_getProtocol(name) orelse return Error.ProtocolNotFound;
        _ = class_addProtocol(self.cls, p);
    }

    pub fn finish(self: ClassBuilder) Class {
        objc_registerClassPair(self.cls);
        return self.cls;
    }
};

/// Stores a pointer to Zig state in an instance of a `ClassBuilder` class.
pub fn setState(obj: id, cls: Class, ptr: ?*anyopaque) void {
    const iv = class_getInstanceVariable(cls, ClassBuilder.ivar_name) orelse return;
    const slot: *?*anyopaque = @ptrFromInt(@intFromPtr(obj) + @as(usize, @intCast(ivar_getOffset(iv))));
    slot.* = ptr;
}

/// Reads the pointer stored by `setState`, typed by the caller.
pub fn getState(comptime T: type, obj: id, cls: Class) ?*T {
    const iv = class_getInstanceVariable(cls, ClassBuilder.ivar_name) orelse return null;
    const slot: *?*anyopaque = @ptrFromInt(@intFromPtr(obj) + @as(usize, @intCast(ivar_getOffset(iv))));
    return @ptrCast(@alignCast(slot.*));
}
