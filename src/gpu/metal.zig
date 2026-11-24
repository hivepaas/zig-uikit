//! The Metal backend: offscreen rendering, and presentation into a
//! `CAMetalLayer`.
//!
//! It exposes the same offscreen surface as the Vulkan backend -- `Gpu`,
//! `Target`, `Renderer`, `clearOnly`, `lastErrorMessage` -- so that
//! `tools/gpu_demo.zig` is one program that checks whichever backend the
//! target has, rather than two programs that check two things that look alike.
//!
//! Why Metal and not MoltenVK: MoltenVK would have reused the Vulkan backend
//! unchanged, at the cost of a dependency that is not on a stock Mac and a
//! translation layer between the toolkit and the only GPU API Apple supports.
//! Metal itself is a few hundred lines through the Objective-C runtime, and the
//! `CAMetalLayer` it presents into is the same layer the tier C design in
//! `docs/native-vs-drawn.md` composes native views beside -- so the layer has to
//! be understood directly either way.
//!
//! What carries over from Vulkan exactly: the scene's 48-byte `Quad` is the
//! per-instance vertex layout, with attribute offsets taken from `@offsetOf`;
//! one draw call; premultiplied-alpha blending; an eight-bit UNORM target and
//! no sRGB conversion, for the reason given on `Target`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("zig-uikit");
const objc = @import("objc");
const id = objc.id;
const send = objc.send;

pub const Quad = ui.Quad;
pub const Scene = ui.Scene;
pub const Color = ui.Color;

/// Written into `docs/` file names, so the Metal run does not overwrite the
/// images the Vulkan run produced and the README quotes.
pub const backend_name = "metal";

pub const Error = error{
    NoMetalDevice,
    ShaderRejected,
    PipelineFailed,
    OutOfDeviceMemory,
    CommandFailed,
    SurfaceHasNoArea,
} || objc.Error || Allocator.Error;

// --- Metal enums, from the SDK headers. There are no headers here, so these are
// --- the values, checked against MacOSX.sdk when they were written.
const MTLPixelFormatRGBA8Unorm: objc.NSUInteger = 70;
const MTLPixelFormatBGRA8Unorm: objc.NSUInteger = 80;
const MTLVertexFormatFloat2: objc.NSUInteger = 29;
const MTLVertexFormatFloat4: objc.NSUInteger = 31;
const MTLVertexFormatUInt2: objc.NSUInteger = 37;
const MTLVertexStepFunctionPerInstance: objc.NSUInteger = 2;
const MTLBlendFactorOne: objc.NSUInteger = 1;
const MTLBlendFactorOneMinusSourceAlpha: objc.NSUInteger = 5;
const MTLLoadActionClear: objc.NSUInteger = 2;
const MTLStoreActionStore: objc.NSUInteger = 1;
const MTLPrimitiveTypeTriangle: objc.NSUInteger = 3;
const MTLResourceStorageModeShared: objc.NSUInteger = 0;
const MTLStorageModePrivate: objc.NSUInteger = 2;
const MTLTextureUsageShaderRead: objc.NSUInteger = 0x1;
const MTLTextureUsageRenderTarget: objc.NSUInteger = 0x4;
const MTLCommandBufferStatusCompleted: objc.NSUInteger = 4;
const MTLMathModeSafe: objc.NSInteger = 0;

const MTLClearColor = extern struct { red: f64, green: f64, blue: f64, alpha: f64 };
const MTLOrigin = extern struct { x: usize, y: usize, z: usize };
const MTLSize = extern struct { width: usize, height: usize, depth: usize };

extern "Metal" fn MTLCreateSystemDefaultDevice() ?id;

// The last NSError's description, so a failure can say more than its error
// name. One buffer, like `vulkan.lastErrorMessage`: errors are reported from
// the thread that hit them, immediately.
threadlocal var last_error_buf: [512]u8 = undefined;
threadlocal var last_error_len: usize = 0;

pub fn lastErrorMessage(buf: []u8) []const u8 {
    const n = @min(buf.len, last_error_len);
    @memcpy(buf[0..n], last_error_buf[0..n]);
    return buf[0..n];
}

fn recordError(where: []const u8, err: ?id) void {
    var w: std.Io.Writer = .fixed(&last_error_buf);
    w.print("{s}", .{where}) catch {};
    if (err) |e| {
        if (send(?id, e, "localizedDescription", .{})) |d| w.print(": {s}", .{objc.utf8(d)}) catch {};
    }
    last_error_len = w.end;
}

pub const Gpu = struct {
    device: id,
    queue: id,
    device_name: id,
    /// Metal has no software device on macOS, so this is always false. It is
    /// here because `gpu_demo` reports it for the Vulkan backend, where a
    /// llvmpipe device is a real possibility and changes what a result means.
    is_software: bool = false,
    /// Whether CPU and GPU share memory. On Apple silicon they do, and that is
    /// why readback here is a copy into a shared buffer rather than a
    /// synchronisation of a managed resource.
    unified_memory: bool,

    pub const Options = struct {};

    pub fn init(gpa: Allocator, opts: Options) Error!Gpu {
        _ = gpa;
        _ = opts;
        const device = MTLCreateSystemDefaultDevice() orelse return Error.NoMetalDevice;
        const queue = send(?id, device, "newCommandQueue", .{}) orelse {
            objc.release(device);
            return Error.NoMetalDevice;
        };
        const name_str = objc.retain(send(id, device, "name", .{}));
        return .{
            .device = device,
            .queue = queue,
            .device_name = name_str,
            .unified_memory = objc.truthy(send(objc.BOOL, device, "hasUnifiedMemory", .{})),
        };
    }

    pub fn deinit(self: *Gpu) void {
        objc.release(self.device_name);
        objc.release(self.queue);
        objc.release(self.device);
    }

    pub fn name(self: *const Gpu) []const u8 {
        return objc.utf8(self.device_name);
    }

    fn newBuffer(self: *const Gpu, len: usize) Error!id {
        return send(?id, self.device, "newBufferWithLength:options:", .{ len, MTLResourceStorageModeShared }) orelse
            Error.OutOfDeviceMemory;
    }
};

/// An offscreen colour target and the buffer it is read back through.
///
/// `RGBA8Unorm` and not `RGBA8Unorm_sRGB`, as on Vulkan: the software reference
/// blends eight-bit sRGB values directly, which is what shipping UI toolkits
/// do, and an sRGB format would make the GPU blend in linear space so that the
/// two disagreed by construction.
///
/// The texture is private and copied into a shared buffer, which is the
/// Vulkan backend's image-to-buffer copy again. A shared texture would skip the
/// copy on Apple silicon, but render targets are not allowed to be shared on
/// Intel Macs with discrete GPUs, and a readback path that only works on one
/// kind of Mac is not worth the copy it saves in a test.
pub const Target = struct {
    gpu: *Gpu,
    texture: id,
    readback: id,
    w: u32,
    h: u32,

    pub const format = MTLPixelFormatRGBA8Unorm;

    pub fn init(gpu: *Gpu, w: u32, h: u32) Error!Target {
        if (w == 0 or h == 0) return Error.SurfaceHasNoArea;
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();

        const cls = try objc.class("MTLTextureDescriptor");
        const desc = send(id, cls, "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
            format, @as(usize, w), @as(usize, h), objc.NO,
        });
        send(void, desc, "setUsage:", .{MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead});
        send(void, desc, "setStorageMode:", .{MTLStorageModePrivate});
        const texture = send(?id, gpu.device, "newTextureWithDescriptor:", .{desc}) orelse
            return Error.OutOfDeviceMemory;
        errdefer objc.release(texture);
        const readback = try gpu.newBuffer(@as(usize, w) * h * 4);
        return .{ .gpu = gpu, .texture = texture, .readback = readback, .w = w, .h = h };
    }

    pub fn deinit(self: *Target) void {
        objc.release(self.readback);
        objc.release(self.texture);
    }

    /// The last rendered image, RGBA, tightly packed. Valid after `render` or
    /// `clearOnly` returns.
    pub fn pixels(self: *const Target) []const u8 {
        const p: [*]const u8 = @ptrCast(send(*anyopaque, self.readback, "contents", .{}));
        return p[0 .. @as(usize, self.w) * self.h * 4];
    }
};

const Uniforms = extern struct { vw: f32, vh: f32, scale: f32, _pad: f32 = 0 };

pub const shaders = struct {
    pub const msl: [:0]const u8 = @embedFile("shaders/quad.metal");
};

/// How many frames may be in flight at once. A `CAMetalLayer` has three
/// drawables, so a fourth frame would wait for a drawable anyway; three
/// instance buffers mean the CPU never writes into one the GPU is reading.
const frames_in_flight = 3;

pub const Renderer = struct {
    gpu: *Gpu,
    library: ?id = null,
    vertex_fn: ?id = null,
    fragment_fn: ?id = null,
    /// A Metal pipeline is compiled against one attachment pixel format, so the
    /// offscreen target and the layer's drawables need one each. Built when
    /// first used.
    pipeline_rgba: ?id = null,
    pipeline_bgra: ?id = null,

    slots: [frames_in_flight]Slot = @splat(.{}),
    next_slot: usize = 0,

    /// How long `newLibraryWithSource:` took. The price of not needing a
    /// Metal compiler at build time, paid once per process.
    compile_ns: u64 = 0,

    const Slot = struct {
        buffer: ?id = null,
        capacity: usize = 0,
        /// The command buffer that last read this slot's instances, retained
        /// until it is known to have completed.
        in_flight: ?id = null,
    };

    pub fn initDefault(gpu: *Gpu) Error!Renderer {
        return init(gpu, shaders.msl);
    }

    pub fn init(gpu: *Gpu, msl: [:0]const u8) Error!Renderer {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();

        var self: Renderer = .{ .gpu = gpu };
        errdefer self.deinit();

        // Fast math is on by default in Metal and is precisely the thing that
        // must be off here: the point of this shader is to agree with a
        // reference implementation, and fast math licenses the compiler to
        // disagree with IEEE 754 in ways the reference does not.
        const opts = objc.new(try objc.class("MTLCompileOptions"));
        defer objc.release(opts);
        if (objc.truthy(send(objc.BOOL, opts, "respondsToSelector:", .{objc.sel("setMathMode:")}))) {
            send(void, opts, "setMathMode:", .{MTLMathModeSafe});
        } else {
            send(void, opts, "setFastMathEnabled:", .{objc.NO});
        }

        var err: ?id = null;
        const t0 = monotonicNs();
        self.library = send(?id, gpu.device, "newLibraryWithSource:options:error:", .{ objc.string(msl), opts, &err });
        self.compile_ns = monotonicNs() - t0;
        if (self.library == null) {
            recordError("newLibraryWithSource", err);
            return Error.ShaderRejected;
        }
        self.vertex_fn = send(?id, self.library.?, "newFunctionWithName:", .{objc.string("quad_vertex")});
        self.fragment_fn = send(?id, self.library.?, "newFunctionWithName:", .{objc.string("quad_fragment")});
        if (self.vertex_fn == null or self.fragment_fn == null) {
            recordError("newFunctionWithName: quad_vertex/quad_fragment missing", null);
            return Error.ShaderRejected;
        }
        // The offscreen pipeline is built now so that a broken pipeline fails
        // at init, where the Vulkan backend fails, rather than at first draw.
        _ = try self.pipelineFor(MTLPixelFormatRGBA8Unorm);
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        for (&self.slots) |*s| {
            if (s.in_flight) |cb| {
                send(void, cb, "waitUntilCompleted", .{});
                objc.release(cb);
            }
            if (s.buffer) |b| objc.release(b);
            s.* = .{};
        }
        inline for (.{ "pipeline_bgra", "pipeline_rgba", "fragment_fn", "vertex_fn", "library" }) |f| {
            if (@field(self, f)) |o| objc.release(o);
            @field(self, f) = null;
        }
    }

    fn pipelineFor(self: *Renderer, pixel_format: objc.NSUInteger) Error!id {
        const slot = if (pixel_format == MTLPixelFormatBGRA8Unorm) &self.pipeline_bgra else &self.pipeline_rgba;
        if (slot.*) |p| return p;

        const pool = objc.AutoreleasePool.push();
        defer pool.pop();

        const desc = objc.new(try objc.class("MTLRenderPipelineDescriptor"));
        defer objc.release(desc);
        send(void, desc, "setVertexFunction:", .{self.vertex_fn.?});
        send(void, desc, "setFragmentFunction:", .{self.fragment_fn.?});
        send(void, desc, "setVertexDescriptor:", .{try vertexDescriptor()});

        const att = send(id, send(id, desc, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(usize, 0)});
        send(void, att, "setPixelFormat:", .{pixel_format});
        // Premultiplied source over: the fragment shader already multiplied
        // colour by coverage, so the source factor is one.
        send(void, att, "setBlendingEnabled:", .{objc.YES});
        send(void, att, "setSourceRGBBlendFactor:", .{MTLBlendFactorOne});
        send(void, att, "setDestinationRGBBlendFactor:", .{MTLBlendFactorOneMinusSourceAlpha});
        send(void, att, "setSourceAlphaBlendFactor:", .{MTLBlendFactorOne});
        send(void, att, "setDestinationAlphaBlendFactor:", .{MTLBlendFactorOneMinusSourceAlpha});

        var err: ?id = null;
        const p = send(?id, self.gpu.device, "newRenderPipelineStateWithDescriptor:error:", .{ desc, &err }) orelse {
            recordError("newRenderPipelineStateWithDescriptor", err);
            return Error.PipelineFailed;
        };
        slot.* = p;
        return p;
    }

    /// The next instance buffer, once the GPU has finished with it, grown to
    /// hold the scene and filled from it byte for byte.
    fn upload(self: *Renderer, scene: *const Scene) Error!struct { slot: *Slot, count: u32 } {
        const slot = &self.slots[self.next_slot];
        self.next_slot = (self.next_slot + 1) % frames_in_flight;
        if (slot.in_flight) |cb| {
            send(void, cb, "waitUntilCompleted", .{});
            objc.release(cb);
            slot.in_flight = null;
        }

        const quads = scene.items();
        const bytes = quads.len * @sizeOf(Quad);
        if (bytes > slot.capacity or slot.buffer == null) {
            var cap: usize = @max(slot.capacity, 64 * @sizeOf(Quad));
            while (cap < bytes) cap *= 2;
            if (slot.buffer) |b| objc.release(b);
            slot.buffer = null;
            slot.capacity = 0;
            slot.buffer = try self.gpu.newBuffer(cap);
            slot.capacity = cap;
        }
        if (bytes > 0) {
            const dst: [*]u8 = @ptrCast(send(*anyopaque, slot.buffer.?, "contents", .{}));
            @memcpy(dst[0..bytes], std.mem.sliceAsBytes(quads));
        }
        return .{ .slot = slot, .count = @intCast(quads.len) };
    }

    pub const Pass = struct {
        texture: id,
        pixel_format: objc.NSUInteger,
        w: u32,
        h: u32,
        /// Pixels per layout unit. One offscreen; the backing scale factor in
        /// a window.
        scale: f32 = 1,
    };

    /// Encodes the clear and the draw into `cb`. Shared by the offscreen path
    /// and the layer path, which differ only in where the texture comes from
    /// and what happens to it afterwards.
    fn encodePass(self: *Renderer, cb: id, pass: Pass, instances: ?id, count: u32, clear: Color) Error!void {
        const rpd = send(id, try objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
        const ca = send(id, send(id, rpd, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(usize, 0)});
        send(void, ca, "setTexture:", .{pass.texture});
        send(void, ca, "setLoadAction:", .{MTLLoadActionClear});
        send(void, ca, "setStoreAction:", .{MTLStoreActionStore});
        send(void, ca, "setClearColor:", .{MTLClearColor{
            .red = @as(f64, @floatFromInt(clear.r)) / 255.0,
            .green = @as(f64, @floatFromInt(clear.g)) / 255.0,
            .blue = @as(f64, @floatFromInt(clear.b)) / 255.0,
            .alpha = @as(f64, @floatFromInt(clear.a)) / 255.0,
        }});

        const enc = send(?id, cb, "renderCommandEncoderWithDescriptor:", .{rpd}) orelse return Error.CommandFailed;
        if (count > 0 and instances != null) {
            send(void, enc, "setRenderPipelineState:", .{try self.pipelineFor(pass.pixel_format)});
            send(void, enc, "setVertexBuffer:offset:atIndex:", .{ instances.?, @as(usize, 0), @as(usize, 0) });
            const u: Uniforms = .{
                .vw = @floatFromInt(pass.w),
                .vh = @floatFromInt(pass.h),
                .scale = pass.scale,
            };
            send(void, enc, "setVertexBytes:length:atIndex:", .{ @as(*const anyopaque, &u), @as(usize, @sizeOf(Uniforms)), @as(usize, 1) });
            send(void, enc, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
                MTLPrimitiveTypeTriangle, @as(usize, 0), @as(usize, 6), @as(usize, count),
            });
        }
        send(void, enc, "endEncoding", .{});
    }

    /// Uploads the scene's quads, draws them into the target and reads the
    /// result back. `target.pixels()` holds the image when this returns.
    pub fn render(self: *Renderer, target: *Target, scene: *const Scene, clear: Color) Error!void {
        return self.renderScaled(target, scene, clear, 1);
    }

    /// `render` with every length in the scene multiplied by `scale` on the
    /// GPU: what a window on a Retina display does.
    pub fn renderScaled(self: *Renderer, target: *Target, scene: *const Scene, clear: Color, scale: f32) Error!void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const up = try self.upload(scene);
        const cb = send(id, self.gpu.queue, "commandBuffer", .{});
        try self.encodePass(cb, .{
            .texture = target.texture,
            .pixel_format = Target.format,
            .w = target.w,
            .h = target.h,
            .scale = scale,
        }, up.slot.buffer, up.count, clear);
        try copyOut(cb, target.texture, target.readback, target.w, target.h);
        try commitAndWait(cb);
    }
};

/// The quad's vertex layout, from the Zig struct. `@offsetOf` and not
/// hand-written numbers: if `Quad` is ever reordered, this follows it, and the
/// comptime assertions below say so loudly instead of the shader reading a
/// colour as a width.
fn vertexDescriptor() Error!id {
    comptime {
        std.debug.assert(@sizeOf(Quad) == 48);
        std.debug.assert(@offsetOf(Quad, "w") == @offsetOf(Quad, "x") + 8);
        std.debug.assert(@offsetOf(Quad, "border_color") == @offsetOf(Quad, "background") + 4);
        std.debug.assert(@offsetOf(Quad, "corner_radius") == @offsetOf(Quad, "border_width") + 4);
        std.debug.assert(@offsetOf(Quad, "ch") == @offsetOf(Quad, "cx") + 12);
    }
    const vd = send(id, try objc.class("MTLVertexDescriptor"), "vertexDescriptor", .{});
    const attrs = send(id, vd, "attributes", .{});
    const fields = [_]struct { fmt: objc.NSUInteger, off: usize }{
        .{ .fmt = MTLVertexFormatFloat4, .off = @offsetOf(Quad, "x") },
        .{ .fmt = MTLVertexFormatUInt2, .off = @offsetOf(Quad, "background") },
        .{ .fmt = MTLVertexFormatFloat2, .off = @offsetOf(Quad, "border_width") },
        .{ .fmt = MTLVertexFormatFloat4, .off = @offsetOf(Quad, "cx") },
    };
    for (fields, 0..) |f, i| {
        const a = send(id, attrs, "objectAtIndexedSubscript:", .{i});
        send(void, a, "setFormat:", .{f.fmt});
        send(void, a, "setOffset:", .{f.off});
        send(void, a, "setBufferIndex:", .{@as(usize, 0)});
    }
    const layout = send(id, send(id, vd, "layouts", .{}), "objectAtIndexedSubscript:", .{@as(usize, 0)});
    send(void, layout, "setStride:", .{@as(usize, @sizeOf(Quad))});
    send(void, layout, "setStepFunction:", .{MTLVertexStepFunctionPerInstance});
    send(void, layout, "setStepRate:", .{@as(usize, 1)});
    return vd;
}

fn copyOut(cb: id, texture: id, buffer: id, w: u32, h: u32) Error!void {
    const blit = send(?id, cb, "blitCommandEncoder", .{}) orelse return Error.CommandFailed;
    send(void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:", .{
        texture,
        @as(usize, 0),
        @as(usize, 0),
        MTLOrigin{ .x = 0, .y = 0, .z = 0 },
        MTLSize{ .width = w, .height = h, .depth = 1 },
        buffer,
        @as(usize, 0),
        @as(usize, w) * 4,
        @as(usize, w) * h * 4,
    });
    send(void, blit, "endEncoding", .{});
}

fn commitAndWait(cb: id) Error!void {
    send(void, cb, "commit", .{});
    send(void, cb, "waitUntilCompleted", .{});
    if (send(objc.NSUInteger, cb, "status", .{}) != MTLCommandBufferStatusCompleted) {
        recordError("command buffer", send(?id, cb, "error", .{}));
        return Error.CommandFailed;
    }
}

/// Clears the target and reads it back, with no pipeline involved: the half of
/// the backend that can be wrong independently of the shader.
pub fn clearOnly(gpu: *Gpu, target: *Target, color: Color) Error!void {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    var bare: Renderer = .{ .gpu = gpu };
    const cb = send(id, gpu.queue, "commandBuffer", .{});
    try bare.encodePass(cb, .{
        .texture = target.texture,
        .pixel_format = Target.format,
        .w = target.w,
        .h = target.h,
    }, null, 0, color);
    try copyOut(cb, target.texture, target.readback, target.w, target.h);
    try commitAndWait(cb);
}

// ------------------------------------------------------------------ the layer

extern "CoreGraphics" const kCGColorSpaceSRGB: *const anyopaque;
extern "CoreGraphics" fn CGColorSpaceCreateWithName(name: *const anyopaque) ?*anyopaque;
extern "CoreGraphics" fn CGColorSpaceRelease(cs: *anyopaque) void;

/// Presentation into a `CAMetalLayer`, which is Metal's swapchain: it owns a
/// small pool of drawables and hands one out per frame.
///
/// Named after the Vulkan type it corresponds to so the window demos read the
/// same, but the mechanics differ in one way that matters for pacing:
/// `nextDrawable` blocks when every drawable is queued for display, and
/// presentation waits for vblank, so the loop is paced by the display exactly
/// as FIFO present paces it on Vulkan -- with no sleep and no display link.
pub const Swapchain = struct {
    gpu: *Gpu,
    layer: id,
    extent: struct { width: u32, height: u32 },
    scale: f32,

    capturable: bool,
    /// Set by the caller; the next `drawAndPresent` copies the frame it
    /// presents into `captured`.
    capture_request: bool = false,
    capture_buf: ?id = null,
    capture_len: usize = 0,

    pub const Options = struct {
        /// A layer whose drawables can be read back. Off by default: Core
        /// Animation can composite a framebuffer-only drawable without a copy.
        capturable: bool = false,
    };

    pub fn init(gpu: *Gpu, layer: id, pixel_w: u32, pixel_h: u32, scale: f32, opts: Options) Error!Swapchain {
        send(void, layer, "setDevice:", .{gpu.device});
        send(void, layer, "setPixelFormat:", .{MTLPixelFormatBGRA8Unorm});
        send(void, layer, "setFramebufferOnly:", .{if (opts.capturable) objc.NO else objc.YES});
        // Tag the drawables as sRGB, so the window server colour-matches them
        // to the display the way it does every other application's content.
        // Untagged, they would be shown in the display's native gamut, and the
        // same bytes would look more saturated here than in a screenshot.
        if (CGColorSpaceCreateWithName(kCGColorSpaceSRGB)) |cs| {
            send(void, layer, "setColorspace:", .{cs});
            CGColorSpaceRelease(cs);
        }
        var self: Swapchain = .{
            .gpu = gpu,
            .layer = objc.retain(layer),
            .extent = .{ .width = 0, .height = 0 },
            .scale = scale,
            .capturable = opts.capturable,
        };
        try self.recreate(pixel_w, pixel_h, scale);
        return self;
    }

    pub fn deinit(self: *Swapchain) void {
        if (self.capture_buf) |b| objc.release(b);
        objc.release(self.layer);
    }

    /// Resizes the drawables. Cheap: the layer reallocates lazily on the next
    /// `nextDrawable`, so there is nothing here to tear down and rebuild.
    pub fn recreate(self: *Swapchain, pixel_w: u32, pixel_h: u32, scale: f32) Error!void {
        if (pixel_w == 0 or pixel_h == 0) return Error.SurfaceHasNoArea;
        self.extent = .{ .width = pixel_w, .height = pixel_h };
        self.scale = scale;
        send(void, self.layer, "setContentsScale:", .{@as(f64, scale)});
        send(void, self.layer, "setDrawableSize:", .{objc.CGSize{
            .width = @floatFromInt(pixel_w),
            .height = @floatFromInt(pixel_h),
        }});
    }

    /// Draws the scene into the next drawable and queues it for display.
    /// Returns false when no drawable was available -- the window is hidden or
    /// the layer timed out -- in which case nothing was drawn and the caller
    /// simply tries again next frame.
    pub fn drawAndPresent(self: *Swapchain, renderer: *Renderer, scene: *const Scene, clear: Color) Error!bool {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();

        const drawable = send(?id, self.layer, "nextDrawable", .{}) orelse return false;
        const texture = send(id, drawable, "texture", .{});
        const tw: u32 = @intCast(send(usize, texture, "width", .{}));
        const th: u32 = @intCast(send(usize, texture, "height", .{}));

        const up = try renderer.upload(scene);
        const cb = send(id, self.gpu.queue, "commandBuffer", .{});
        try renderer.encodePass(cb, .{
            .texture = texture,
            .pixel_format = MTLPixelFormatBGRA8Unorm,
            .w = tw,
            .h = th,
            .scale = self.scale,
        }, up.slot.buffer, up.count, clear);

        const capturing = self.capture_request and self.capturable;
        if (capturing) {
            const len = @as(usize, tw) * th * 4;
            if (self.capture_buf == null or self.capture_len < len) {
                if (self.capture_buf) |b| objc.release(b);
                self.capture_buf = null;
                self.capture_buf = try self.gpu.newBuffer(len);
            }
            self.capture_len = len;
            self.extent = .{ .width = tw, .height = th };
            try copyOut(cb, texture, self.capture_buf.?, tw, th);
        }

        send(void, cb, "presentDrawable:", .{drawable});
        send(void, cb, "commit", .{});
        up.slot.in_flight = objc.retain(cb);

        if (capturing) {
            self.capture_request = false;
            send(void, cb, "waitUntilCompleted", .{});
        }
        return true;
    }

    /// The last captured frame, in the drawable's own byte order: BGRA.
    ///
    /// `CAMetalLayer` offers `BGRA8Unorm` and no eight-bit RGBA format, so the
    /// channel-order question the Vulkan backend meets only on some drivers is
    /// met on every Mac. The format names channels; it does not reorder what
    /// the shader writes. The shader writes RGBA, the memory holds BGRA, and
    /// only the copy out needs swapping -- which `--capture` checks.
    pub fn captured(self: *const Swapchain) []const u8 {
        const b = self.capture_buf orelse return &.{};
        const p: [*]const u8 = @ptrCast(send(*anyopaque, b, "contents", .{}));
        return p[0..self.capture_len];
    }

    /// The last captured frame as RGBA.
    pub fn captureRgba(self: *const Swapchain, gpa: Allocator) Allocator.Error![]u8 {
        const src = self.captured();
        const out = try gpa.alloc(u8, src.len);
        var i: usize = 0;
        while (i < src.len) : (i += 4) {
            out[i + 0] = src[i + 2];
            out[i + 1] = src[i + 1];
            out[i + 2] = src[i + 0];
            out[i + 3] = src[i + 3];
        }
        return out;
    }
};

extern "c" fn clock_gettime_nsec_np(clock: std.c.clockid_t) u64;

fn monotonicNs() u64 {
    return clock_gettime_nsec_np(.UPTIME_RAW);
}
