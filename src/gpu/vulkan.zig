//! The Vulkan backend: uploads a `Scene` and renders it.
//!
//! This module is deliberately NOT part of the `zig-uikit` module. The layout
//! core and the scene layer have no platform dependencies and their tests run
//! anywhere; this links `libvulkan` and needs a device, so it is a separate
//! module with a separate test step. A toolkit whose unit tests need a GPU is a
//! toolkit nobody runs the tests of.
//!
//! The scene's `Quad` is uploaded with **no repacking at all**: it is the
//! per-instance vertex attribute layout, and the offsets the pipeline declares
//! are the struct's field offsets. That was the reason for making it an
//! `extern struct` of 48 bytes, and `attributeDescriptions` asserts it still
//! holds rather than trusting a comment.
//!
//! Rendering goes to an offscreen image and is read back to host memory, which
//! is how it is tested: `tools/gpu_demo.zig` renders the same scene through
//! this and through `src/raster.zig` and compares every pixel. A window and a
//! swapchain are a separate concern and are not here yet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("vk");
const ui = @import("zig-uikit");

pub const Quad = ui.Quad;
pub const Scene = ui.Scene;
pub const Color = ui.Color;

pub const Error = error{
    NoVulkanLoader,
    NoDevice,
    NoGraphicsQueue,
    NoSuitableMemoryType,
    ShaderRejected,
    /// The surface reported a zero-sized extent, which a compositor does while
    /// a window is minimised or mid-resize. Not fatal: try again.
    SurfaceHasNoArea,
    NoSuitableSurfaceFormat,
    VulkanCallFailed,
} || Allocator.Error;

/// Last Vulkan result that failed, for the message. A global because a
/// `VkResult` cannot travel inside a Zig error, and because this is a backend
/// with one thread doing setup.
pub var last_result: c.VkResult = c.VK_SUCCESS;
pub var last_call: []const u8 = "";

pub fn check(where: []const u8, r: c.VkResult) Error!void {
    if (r == c.VK_SUCCESS) return;
    last_result = r;
    last_call = where;
    return Error.VulkanCallFailed;
}

pub fn lastErrorMessage(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} returned VkResult {d}", .{ last_call, last_result }) catch "vulkan call failed";
}

// ---------------------------------------------------------------- the device

pub const Gpu = struct {
    gpa: Allocator,
    instance: c.VkInstance = null,
    physical: c.VkPhysicalDevice = null,
    device: c.VkDevice = null,
    queue: c.VkQueue = null,
    queue_family: u32 = 0,
    pool: c.VkCommandPool = null,
    mem_props: c.VkPhysicalDeviceMemoryProperties = undefined,
    name_buf: [256]u8 = @splat(0),
    is_software: bool = false,

    pub const Options = struct {
        /// Prefer a CPU implementation. Useful for reproducing a rendering
        /// difference on a machine with different hardware.
        prefer_software: bool = false,
        /// The Wayland display to present to, if this device will drive a
        /// window. When set, the surface and swapchain extensions are enabled
        /// and the queue family is additionally required to support
        /// presentation to this display -- which is a real constraint and not a
        /// formality, because a queue that can draw cannot necessarily present.
        present_to: ?*c.struct_wl_display = null,
    };

    pub fn init(gpa: Allocator, opts: Options) Error!Gpu {
        var self: Gpu = .{ .gpa = gpa };
        errdefer self.deinit();

        const app: c.VkApplicationInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "zig-uikit",
            .apiVersion = c.VK_API_VERSION_1_3,
        };
        const surface_exts = [_][*:0]const u8{
            c.VK_KHR_SURFACE_EXTENSION_NAME,
            c.VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME,
        };
        const ici: c.VkInstanceCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app,
            .enabledExtensionCount = if (opts.present_to != null) surface_exts.len else 0,
            .ppEnabledExtensionNames = if (opts.present_to != null) @ptrCast(&surface_exts) else null,
        };
        try check("vkCreateInstance", c.vkCreateInstance(&ici, null, &self.instance));

        var n: u32 = 0;
        try check("vkEnumeratePhysicalDevices", c.vkEnumeratePhysicalDevices(self.instance, &n, null));
        if (n == 0) return Error.NoDevice;
        const devices = try gpa.alloc(c.VkPhysicalDevice, n);
        defer gpa.free(devices);
        try check("vkEnumeratePhysicalDevices", c.vkEnumeratePhysicalDevices(self.instance, &n, devices.ptr));

        var best: ?c.VkPhysicalDevice = null;
        var best_score: i32 = -1;
        var best_props: c.VkPhysicalDeviceProperties = undefined;
        for (devices[0..n]) |d| {
            var props: c.VkPhysicalDeviceProperties = undefined;
            c.vkGetPhysicalDeviceProperties(d, &props);
            const software = props.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_CPU;
            const score: i32 = switch (props.deviceType) {
                c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 3,
                c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 2,
                c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 1,
                else => 0,
            };
            const adjusted = if (opts.prefer_software) (if (software) @as(i32, 10) else score) else score;
            if (adjusted > best_score) {
                best_score = adjusted;
                best = d;
                best_props = props;
                self.is_software = software;
            }
        }
        self.physical = best orelse return Error.NoDevice;
        const dev_name: [*:0]const u8 = @ptrCast(&best_props.deviceName);
        const len = @min(std.mem.len(dev_name), self.name_buf.len - 1);
        @memcpy(self.name_buf[0..len], dev_name[0..len]);

        c.vkGetPhysicalDeviceMemoryProperties(self.physical, &self.mem_props);

        var qn: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties(self.physical, &qn, null);
        const families = try gpa.alloc(c.VkQueueFamilyProperties, qn);
        defer gpa.free(families);
        c.vkGetPhysicalDeviceQueueFamilyProperties(self.physical, &qn, families.ptr);
        var found = false;
        for (families[0..qn], 0..) |f, i| {
            if (f.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 0) continue;
            if (opts.present_to) |display| {
                const ok = c.vkGetPhysicalDeviceWaylandPresentationSupportKHR(
                    self.physical,
                    @intCast(i),
                    display,
                );
                if (ok != c.VK_TRUE) continue;
            }
            self.queue_family = @intCast(i);
            found = true;
            break;
        }
        if (!found) return Error.NoGraphicsQueue;

        const priority: f32 = 1.0;
        const qci: c.VkDeviceQueueCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = self.queue_family,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
        // Dynamic rendering instead of render pass and framebuffer objects:
        // the same result in roughly eighty fewer lines, and core since 1.3.
        var f13: c.VkPhysicalDeviceVulkan13Features = .{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            .dynamicRendering = c.VK_TRUE,
        };
        const device_exts = [_][*:0]const u8{c.VK_KHR_SWAPCHAIN_EXTENSION_NAME};
        const dci: c.VkDeviceCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = &f13,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &qci,
            .enabledExtensionCount = if (opts.present_to != null) device_exts.len else 0,
            .ppEnabledExtensionNames = if (opts.present_to != null) @ptrCast(&device_exts) else null,
        };
        try check("vkCreateDevice", c.vkCreateDevice(self.physical, &dci, null, &self.device));
        c.vkGetDeviceQueue(self.device, self.queue_family, 0, &self.queue);

        const pci: c.VkCommandPoolCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.queue_family,
        };
        try check("vkCreateCommandPool", c.vkCreateCommandPool(self.device, &pci, null, &self.pool));

        return self;
    }

    pub fn deinit(self: *Gpu) void {
        if (self.device != null) {
            _ = c.vkDeviceWaitIdle(self.device);
            if (self.pool != null) c.vkDestroyCommandPool(self.device, self.pool, null);
            c.vkDestroyDevice(self.device, null);
        }
        if (self.instance != null) c.vkDestroyInstance(self.instance, null);
        self.device = null;
        self.instance = null;
    }

    pub fn name(self: *const Gpu) []const u8 {
        return std.mem.sliceTo(&self.name_buf, 0);
    }

    pub fn memoryType(self: *const Gpu, bits: u32, want: c.VkMemoryPropertyFlags) Error!u32 {
        for (0..self.mem_props.memoryTypeCount) |i| {
            const usable = bits & (@as(u32, 1) << @intCast(i)) != 0;
            const has = self.mem_props.memoryTypes[i].propertyFlags & want == want;
            if (usable and has) return @intCast(i);
        }
        return Error.NoSuitableMemoryType;
    }

    /// Records, submits and waits. Every operation here is one-shot setup or a
    /// single offscreen frame, so there is no frame pipelining to get wrong.
    fn oneShot(self: *Gpu, comptime Ctx: type, ctx: Ctx, record: fn (Ctx, c.VkCommandBuffer) void) Error!void {
        var cb: c.VkCommandBuffer = null;
        const ai: c.VkCommandBufferAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        try check("vkAllocateCommandBuffers", c.vkAllocateCommandBuffers(self.device, &ai, &cb));
        defer c.vkFreeCommandBuffers(self.device, self.pool, 1, &cb);

        const bi: c.VkCommandBufferBeginInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        try check("vkBeginCommandBuffer", c.vkBeginCommandBuffer(cb, &bi));
        record(ctx, cb);
        try check("vkEndCommandBuffer", c.vkEndCommandBuffer(cb));

        var fence: c.VkFence = null;
        const fci: c.VkFenceCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
        try check("vkCreateFence", c.vkCreateFence(self.device, &fci, null, &fence));
        defer c.vkDestroyFence(self.device, fence, null);

        const si: c.VkSubmitInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &cb,
        };
        try check("vkQueueSubmit", c.vkQueueSubmit(self.queue, 1, &si, fence));
        try check("vkWaitForFences", c.vkWaitForFences(self.device, 1, &fence, c.VK_TRUE, std.math.maxInt(u64)));
    }
};

// --------------------------------------------------------------- the target

/// An offscreen colour image plus a host-visible buffer to read it back into.
///
/// `R8G8B8A8_UNORM` and not `_SRGB`, deliberately. The software reference
/// rasteriser blends eight-bit sRGB values directly, which is what every
/// shipping UI toolkit does; an sRGB format would make the GPU blend in linear
/// space and the two would disagree by construction. Gamma-correct compositing
/// is a decision to make once, for both, not a difference to discover.
pub const Target = struct {
    gpu: *Gpu,
    w: u32,
    h: u32,
    image: c.VkImage = null,
    image_memory: c.VkDeviceMemory = null,
    view: c.VkImageView = null,
    readback: c.VkBuffer = null,
    readback_memory: c.VkDeviceMemory = null,
    mapped: [*]u8 = undefined,

    pub const format = c.VK_FORMAT_R8G8B8A8_UNORM;

    pub fn init(gpu: *Gpu, w: u32, h: u32) Error!Target {
        var self: Target = .{ .gpu = gpu, .w = w, .h = h };
        errdefer self.deinit();

        const ici: c.VkImageCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = format,
            .extent = .{ .width = w, .height = h, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        try check("vkCreateImage", c.vkCreateImage(gpu.device, &ici, null, &self.image));

        var req: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(gpu.device, self.image, &req);
        const mai: c.VkMemoryAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size,
            .memoryTypeIndex = try gpu.memoryType(req.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        };
        try check("vkAllocateMemory", c.vkAllocateMemory(gpu.device, &mai, null, &self.image_memory));
        try check("vkBindImageMemory", c.vkBindImageMemory(gpu.device, self.image, self.image_memory, 0));

        const vci: c.VkImageViewCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = self.image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = format,
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .levelCount = 1,
                .layerCount = 1,
            },
        };
        try check("vkCreateImageView", c.vkCreateImageView(gpu.device, &vci, null, &self.view));

        const size: c.VkDeviceSize = @as(u64, w) * h * 4;
        const bci: c.VkBufferCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = size,
            .usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        };
        try check("vkCreateBuffer", c.vkCreateBuffer(gpu.device, &bci, null, &self.readback));
        var breq: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(gpu.device, self.readback, &breq);
        const bmai: c.VkMemoryAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = breq.size,
            .memoryTypeIndex = try gpu.memoryType(
                breq.memoryTypeBits,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            ),
        };
        try check("vkAllocateMemory", c.vkAllocateMemory(gpu.device, &bmai, null, &self.readback_memory));
        try check("vkBindBufferMemory", c.vkBindBufferMemory(gpu.device, self.readback, self.readback_memory, 0));

        var ptr: ?*anyopaque = null;
        try check("vkMapMemory", c.vkMapMemory(gpu.device, self.readback_memory, 0, size, 0, &ptr));
        self.mapped = @ptrCast(ptr.?);
        return self;
    }

    pub fn deinit(self: *Target) void {
        const d = self.gpu.device;
        if (d == null) return;
        _ = c.vkDeviceWaitIdle(d);
        if (self.readback_memory != null) {
            c.vkUnmapMemory(d, self.readback_memory);
            c.vkFreeMemory(d, self.readback_memory, null);
        }
        if (self.readback != null) c.vkDestroyBuffer(d, self.readback, null);
        if (self.view != null) c.vkDestroyImageView(d, self.view, null);
        if (self.image != null) c.vkDestroyImage(d, self.image, null);
        if (self.image_memory != null) c.vkFreeMemory(d, self.image_memory, null);
        self.* = undefined;
    }

    /// The pixels last read back: RGBA, row-major, no padding. Exactly the
    /// layout `raster.Framebuffer.px` uses, so the two are directly comparable.
    pub fn pixels(self: *const Target) []const u8 {
        return self.mapped[0 .. @as(usize, self.w) * self.h * 4];
    }
};

// ------------------------------------------------------------ the quad pipeline

pub const transitionPublic = transition;

fn transition(
    cb: c.VkCommandBuffer,
    image: c.VkImage,
    from: c.VkImageLayout,
    to: c.VkImageLayout,
    src_stage: c.VkPipelineStageFlags,
    dst_stage: c.VkPipelineStageFlags,
    src_access: c.VkAccessFlags,
    dst_access: c.VkAccessFlags,
) void {
    const b: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = src_access,
        .dstAccessMask = dst_access,
        .oldLayout = from,
        .newLayout = to,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .levelCount = 1,
            .layerCount = 1,
        },
    };
    c.vkCmdPipelineBarrier(cb, src_stage, dst_stage, 0, 0, null, 0, null, 1, &b);
}

/// The per-instance attribute layout, read straight off `Quad`.
fn attributeDescriptions() [6]c.VkVertexInputAttributeDescription {
    return .{
        .{ .location = 0, .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(Quad, "x") },
        .{ .location = 1, .binding = 0, .format = c.VK_FORMAT_R32G32_UINT, .offset = @offsetOf(Quad, "background") },
        .{ .location = 2, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(Quad, "border_width") },
        .{ .location = 3, .binding = 0, .format = c.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(Quad, "cx") },
        // The four atlas texels as one 16-bit uvec4. `R16G16B16A16_UINT` is a
        // mandatory vertex format, so no capability check is needed.
        .{ .location = 4, .binding = 0, .format = c.VK_FORMAT_R16G16B16A16_UINT, .offset = @offsetOf(Quad, "u0") },
        .{ .location = 5, .binding = 0, .format = c.VK_FORMAT_R32_UINT, .offset = @offsetOf(Quad, "flags") },
    };
}

comptime {
    // The attribute layout above assumes the fields are contiguous in this
    // order. If `Quad` is reordered, the shader reads the wrong bytes and the
    // picture is subtly wrong rather than obviously broken, so it is checked
    // here instead.
    std.debug.assert(@offsetOf(Quad, "x") == 0);
    std.debug.assert(@offsetOf(Quad, "y") == 4);
    std.debug.assert(@offsetOf(Quad, "w") == 8);
    std.debug.assert(@offsetOf(Quad, "h") == 12);
    std.debug.assert(@offsetOf(Quad, "background") == 16);
    std.debug.assert(@offsetOf(Quad, "border_color") == 20);
    std.debug.assert(@offsetOf(Quad, "border_width") == 24);
    std.debug.assert(@offsetOf(Quad, "corner_radius") == 28);
    std.debug.assert(@offsetOf(Quad, "cx") == 32);
    std.debug.assert(@offsetOf(Quad, "u0") == 48);
    std.debug.assert(@offsetOf(Quad, "v0") == 50);
    std.debug.assert(@offsetOf(Quad, "u1") == 52);
    std.debug.assert(@offsetOf(Quad, "v1") == 54);
    std.debug.assert(@offsetOf(Quad, "flags") == 56);
    std.debug.assert(@sizeOf(Quad) == 60);
}

const Push = extern struct { vw: f32, vh: f32, flags: u32 };
const flag_swap_rb: u32 = 1;

/// The compiled shaders, built into the binary.
///
/// Embedded rather than loaded at runtime so that a program using this backend
/// is one file and cannot be started next to the wrong `.spv`. They are
/// committed to the repository for the same reason the build does not need a
/// shader compiler; see `src/gpu/shaders/README.md`.
/// SPIR-V is a stream of 32-bit words and `vkCreateShaderModule` takes a
/// `u32` pointer, while `@embedFile` yields a byte array aligned to one. The
/// alignment is in the type here, and in `Renderer.init`'s parameter, so a
/// caller handing over a misaligned buffer is a compile error rather than a
/// panic inside the backend.
pub const shaders = struct {
    const vert_bytes = @embedFile("shaders/quad.vert.spv");
    const frag_bytes = @embedFile("shaders/quad.frag.spv");
    pub const vert: [vert_bytes.len]u8 align(4) = vert_bytes.*;
    pub const frag: [frag_bytes.len]u8 align(4) = frag_bytes.*;
};

pub const Renderer = struct {
    gpu: *Gpu,
    vert: c.VkShaderModule = null,
    frag: c.VkShaderModule = null,
    layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,

    instances: c.VkBuffer = null,
    instance_memory: c.VkDeviceMemory = null,
    instance_mapped: [*]u8 = undefined,
    instance_capacity: usize = 0,

    /// The glyph atlas, as a single-channel sampled image.
    ///
    /// Always present, even with no text in the scene: a descriptor the
    /// fragment shader declares has to be bound whether or not any invocation
    /// reaches the branch that reads it, so `init` makes a one-texel atlas and
    /// `setAtlas` replaces it. The alternative -- two pipelines, one with the
    /// sampler and one without -- would be a pipeline switch mid-frame to save
    /// a descriptor write per atlas change.
    atlas_image: c.VkImage = null,
    atlas_memory: c.VkDeviceMemory = null,
    atlas_view: c.VkImageView = null,
    atlas_sampler: c.VkSampler = null,
    atlas_w: u32 = 0,
    atlas_h: u32 = 0,

    set_layout: c.VkDescriptorSetLayout = null,
    desc_pool: c.VkDescriptorPool = null,
    desc_set: c.VkDescriptorSet = null,

    /// The ordinary case: the quad pipeline with the shaders this module ships.
    pub fn initDefault(gpu: *Gpu) Error!Renderer {
        return init(gpu, &shaders.vert, &shaders.frag);
    }

    /// Takes the compiled shaders as bytes, so a caller replacing them -- a
    /// test, or an application with its own primitive -- does not have to go
    /// through a file. See `src/gpu/shaders/README.md` for how they are built.
    pub fn init(gpu: *Gpu, vert_spv: []align(4) const u8, frag_spv: []align(4) const u8) Error!Renderer {
        var self: Renderer = .{ .gpu = gpu };
        errdefer self.deinit();

        self.vert = try shaderModule(gpu, vert_spv);
        self.frag = try shaderModule(gpu, frag_spv);

        try self.initAtlasResources();

        const pcr: c.VkPushConstantRange = .{
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT,
            .offset = 0,
            .size = @sizeOf(Push),
        };
        const plci: c.VkPipelineLayoutCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1,
            .pSetLayouts = &self.set_layout,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &pcr,
        };
        try check("vkCreatePipelineLayout", c.vkCreatePipelineLayout(gpu.device, &plci, null, &self.layout));

        const stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
                .module = self.vert,
                .pName = "main",
            },
            .{
                .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
                .module = self.frag,
                .pName = "main",
            },
        };

        const binding: c.VkVertexInputBindingDescription = .{
            .binding = 0,
            .stride = @sizeOf(Quad),
            .inputRate = c.VK_VERTEX_INPUT_RATE_INSTANCE,
        };
        const attrs = attributeDescriptions();
        const vi: c.VkPipelineVertexInputStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = &binding,
            .vertexAttributeDescriptionCount = attrs.len,
            .pVertexAttributeDescriptions = &attrs,
        };
        const ia: c.VkPipelineInputAssemblyStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        };
        const vp: c.VkPipelineViewportStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .scissorCount = 1,
        };
        const rs: c.VkPipelineRasterizationStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            .cullMode = c.VK_CULL_MODE_NONE,
            .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .lineWidth = 1,
        };
        const ms: c.VkPipelineMultisampleStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
        };
        // The fragment shader outputs premultiplied alpha, so the source factor
        // is ONE. Using SRC_ALPHA here would multiply by alpha twice and darken
        // every antialiased edge -- which the comparison against the software
        // rasteriser would catch, but only after looking.
        const blend: c.VkPipelineColorBlendAttachmentState = .{
            .blendEnable = c.VK_TRUE,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT |
                c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
        };
        const cb_state: c.VkPipelineColorBlendStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &blend,
        };
        const dyn = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        const ds: c.VkPipelineDynamicStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = dyn.len,
            .pDynamicStates = &dyn,
        };
        var color_format: c.VkFormat = Target.format;
        const rendering: c.VkPipelineRenderingCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .colorAttachmentCount = 1,
            .pColorAttachmentFormats = &color_format,
        };
        const gpci: c.VkGraphicsPipelineCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = &rendering,
            .stageCount = stages.len,
            .pStages = &stages,
            .pVertexInputState = &vi,
            .pInputAssemblyState = &ia,
            .pViewportState = &vp,
            .pRasterizationState = &rs,
            .pMultisampleState = &ms,
            .pColorBlendState = &cb_state,
            .pDynamicState = &ds,
            .layout = self.layout,
        };
        try check(
            "vkCreateGraphicsPipelines",
            c.vkCreateGraphicsPipelines(gpu.device, null, 1, &gpci, null, &self.pipeline),
        );
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        const d = self.gpu.device;
        if (d == null) return;
        _ = c.vkDeviceWaitIdle(d);
        if (self.instance_memory != null) {
            c.vkUnmapMemory(d, self.instance_memory);
            c.vkFreeMemory(d, self.instance_memory, null);
        }
        if (self.instances != null) c.vkDestroyBuffer(d, self.instances, null);
        self.destroyAtlasImage();
        if (self.atlas_sampler != null) c.vkDestroySampler(d, self.atlas_sampler, null);
        if (self.desc_pool != null) c.vkDestroyDescriptorPool(d, self.desc_pool, null);
        if (self.set_layout != null) c.vkDestroyDescriptorSetLayout(d, self.set_layout, null);
        self.atlas_sampler = null;
        self.desc_pool = null;
        self.desc_set = null;
        self.set_layout = null;
        if (self.pipeline != null) c.vkDestroyPipeline(d, self.pipeline, null);
        if (self.layout != null) c.vkDestroyPipelineLayout(d, self.layout, null);
        if (self.frag != null) c.vkDestroyShaderModule(d, self.frag, null);
        if (self.vert != null) c.vkDestroyShaderModule(d, self.vert, null);
        self.pipeline = null;
        self.layout = null;
        self.frag = null;
        self.vert = null;
        self.instances = null;
        self.instance_memory = null;
    }

    // ------------------------------------------------------------- the atlas

    fn initAtlasResources(self: *Renderer) Error!void {
        const d = self.gpu.device;

        const binding: c.VkDescriptorSetLayoutBinding = .{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
        };
        const slci: c.VkDescriptorSetLayoutCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .bindingCount = 1,
            .pBindings = &binding,
        };
        try check(
            "vkCreateDescriptorSetLayout",
            c.vkCreateDescriptorSetLayout(d, &slci, null, &self.set_layout),
        );

        const pool_size: c.VkDescriptorPoolSize = .{
            .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
        };
        const dpci: c.VkDescriptorPoolCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = 1,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        };
        try check("vkCreateDescriptorPool", c.vkCreateDescriptorPool(d, &dpci, null, &self.desc_pool));

        const dsai: c.VkDescriptorSetAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = self.desc_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.set_layout,
        };
        try check("vkAllocateDescriptorSets", c.vkAllocateDescriptorSets(d, &dsai, &self.desc_set));

        // `NEAREST` everywhere, and it does not actually matter: the fragment
        // shader reads the atlas with `texelFetch`, which bypasses the sampler
        // entirely. A sampler object still has to exist because the descriptor
        // type is a combined image sampler, so this one is the least
        // surprising thing to look at in a debugger -- and if someone ever
        // switches that fetch to a `texture()` call, nearest sampling is what
        // keeps the result matching the software reference.
        const sci: c.VkSamplerCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = c.VK_FILTER_NEAREST,
            .minFilter = c.VK_FILTER_NEAREST,
            .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .maxLod = 0,
            .borderColor = c.VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK,
        };
        try check("vkCreateSampler", c.vkCreateSampler(d, &sci, null, &self.atlas_sampler));

        // One transparent texel, so the descriptor is valid before any text
        // exists. A scene with no glyphs never samples it.
        try self.setAtlas(.{ .pixels = &[_]u8{0}, .w = 1, .h = 1 });
    }

    fn destroyAtlasImage(self: *Renderer) void {
        const d = self.gpu.device;
        if (self.atlas_view != null) c.vkDestroyImageView(d, self.atlas_view, null);
        if (self.atlas_image != null) c.vkDestroyImage(d, self.atlas_image, null);
        if (self.atlas_memory != null) c.vkFreeMemory(d, self.atlas_memory, null);
        self.atlas_view = null;
        self.atlas_image = null;
        self.atlas_memory = null;
        self.atlas_w = 0;
        self.atlas_h = 0;
    }

    /// Uploads a glyph atlas, replacing whatever was there.
    ///
    /// The whole atlas every time, not the part that changed. A 512-square
    /// atlas is 256 KB and this happens when glyphs are added -- the first
    /// frame, a new font size, a character nobody has typed before -- not per
    /// frame. Tracking a dirty rectangle would be a second incremental system
    /// guarding a cost that is not on the frame path.
    pub fn setAtlas(self: *Renderer, atlas: ui.AtlasView) Error!void {
        const d = self.gpu.device;
        if (atlas.w == 0 or atlas.h == 0) return Error.NoSuitableMemoryType;
        if (atlas.pixels.len < @as(usize, atlas.w) * atlas.h) return Error.NoSuitableMemoryType;

        if (atlas.w != self.atlas_w or atlas.h != self.atlas_h) {
            _ = c.vkDeviceWaitIdle(d);
            self.destroyAtlasImage();

            const ici: c.VkImageCreateInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                .imageType = c.VK_IMAGE_TYPE_2D,
                // One channel of coverage. `R8_UNORM` is mandatory for sampled
                // images with linear filtering on every Vulkan implementation,
                // so there is nothing to fall back to.
                .format = c.VK_FORMAT_R8_UNORM,
                .extent = .{ .width = atlas.w, .height = atlas.h, .depth = 1 },
                .mipLevels = 1,
                .arrayLayers = 1,
                .samples = c.VK_SAMPLE_COUNT_1_BIT,
                .tiling = c.VK_IMAGE_TILING_OPTIMAL,
                .usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
                .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
                .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            };
            try check("vkCreateImage", c.vkCreateImage(d, &ici, null, &self.atlas_image));

            var req: c.VkMemoryRequirements = undefined;
            c.vkGetImageMemoryRequirements(d, self.atlas_image, &req);
            const mai: c.VkMemoryAllocateInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                .allocationSize = req.size,
                .memoryTypeIndex = try self.gpu.memoryType(
                    req.memoryTypeBits,
                    c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
                ),
            };
            try check("vkAllocateMemory", c.vkAllocateMemory(d, &mai, null, &self.atlas_memory));
            try check("vkBindImageMemory", c.vkBindImageMemory(d, self.atlas_image, self.atlas_memory, 0));

            const vci: c.VkImageViewCreateInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = self.atlas_image,
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = c.VK_FORMAT_R8_UNORM,
                .subresourceRange = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .levelCount = 1,
                    .layerCount = 1,
                },
            };
            try check("vkCreateImageView", c.vkCreateImageView(d, &vci, null, &self.atlas_view));

            self.atlas_w = atlas.w;
            self.atlas_h = atlas.h;

            const info: c.VkDescriptorImageInfo = .{
                .sampler = self.atlas_sampler,
                .imageView = self.atlas_view,
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            const write: c.VkWriteDescriptorSet = .{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = self.desc_set,
                .dstBinding = 0,
                .descriptorCount = 1,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImageInfo = &info,
            };
            c.vkUpdateDescriptorSets(d, 1, &write, 0, null);
        }

        try self.uploadAtlas(atlas);
    }

    const AtlasUpload = struct {
        image: c.VkImage,
        staging: c.VkBuffer,
        w: u32,
        h: u32,
    };

    fn uploadAtlas(self: *Renderer, atlas: ui.AtlasView) Error!void {
        const d = self.gpu.device;
        const size: c.VkDeviceSize = @as(u64, atlas.w) * atlas.h;

        var staging: c.VkBuffer = null;
        var memory: c.VkDeviceMemory = null;
        const bci: c.VkBufferCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = size,
            .usage = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        };
        try check("vkCreateBuffer", c.vkCreateBuffer(d, &bci, null, &staging));
        defer c.vkDestroyBuffer(d, staging, null);

        var req: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(d, staging, &req);
        const mai: c.VkMemoryAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size,
            .memoryTypeIndex = try self.gpu.memoryType(
                req.memoryTypeBits,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            ),
        };
        try check("vkAllocateMemory", c.vkAllocateMemory(d, &mai, null, &memory));
        defer c.vkFreeMemory(d, memory, null);
        try check("vkBindBufferMemory", c.vkBindBufferMemory(d, staging, memory, 0));

        var ptr: ?*anyopaque = null;
        try check("vkMapMemory", c.vkMapMemory(d, memory, 0, size, 0, &ptr));
        const dst: [*]u8 = @ptrCast(ptr.?);
        @memcpy(dst[0..@intCast(size)], atlas.pixels[0..@intCast(size)]);
        c.vkUnmapMemory(d, memory);

        try self.gpu.oneShot(AtlasUpload, .{
            .image = self.atlas_image,
            .staging = staging,
            .w = atlas.w,
            .h = atlas.h,
        }, recordAtlasUpload);
    }

    fn recordAtlasUpload(u: AtlasUpload, cb: c.VkCommandBuffer) void {
        // `UNDEFINED` as the source layout discards whatever was in the image,
        // which is correct precisely because the whole atlas is being written.
        transition(
            cb,
            u.image,
            c.VK_IMAGE_LAYOUT_UNDEFINED,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            c.VK_ACCESS_TRANSFER_WRITE_BIT,
        );
        const copy: c.VkBufferImageCopy = .{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = u.w, .height = u.h, .depth = 1 },
        };
        c.vkCmdCopyBufferToImage(
            cb,
            u.staging,
            u.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &copy,
        );
        transition(
            cb,
            u.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            c.VK_ACCESS_TRANSFER_WRITE_BIT,
            c.VK_ACCESS_SHADER_READ_BIT,
        );
    }

    fn ensureInstances(self: *Renderer, count: usize) Error!void {
        const needed = @max(count, 1) * @sizeOf(Quad);
        if (needed <= self.instance_capacity) return;
        const d = self.gpu.device;
        if (self.instance_memory != null) {
            _ = c.vkDeviceWaitIdle(d);
            c.vkUnmapMemory(d, self.instance_memory);
            c.vkFreeMemory(d, self.instance_memory, null);
            c.vkDestroyBuffer(d, self.instances, null);
        }
        // Grow in powers of two so a scene that creeps upward does not
        // reallocate device memory every frame.
        var cap: usize = 64 * @sizeOf(Quad);
        while (cap < needed) cap *= 2;

        const bci: c.VkBufferCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = cap,
            .usage = c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        };
        try check("vkCreateBuffer", c.vkCreateBuffer(d, &bci, null, &self.instances));
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(d, self.instances, &req);
        const mai: c.VkMemoryAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size,
            .memoryTypeIndex = try self.gpu.memoryType(
                req.memoryTypeBits,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            ),
        };
        try check("vkAllocateMemory", c.vkAllocateMemory(d, &mai, null, &self.instance_memory));
        try check("vkBindBufferMemory", c.vkBindBufferMemory(d, self.instances, self.instance_memory, 0));
        var ptr: ?*anyopaque = null;
        try check("vkMapMemory", c.vkMapMemory(d, self.instance_memory, 0, cap, 0, &ptr));
        self.instance_mapped = @ptrCast(ptr.?);
        self.instance_capacity = cap;
    }

    /// Where a frame is drawn, and what the image has to be ready for when it
    /// is done. The offscreen path finishes in `TRANSFER_SRC_OPTIMAL` so it can
    /// be copied out; the swapchain path finishes in `PRESENT_SRC_KHR`. Nothing
    /// else differs between them, so nothing else is duplicated.
    pub const Pass = struct {
        image: c.VkImage,
        view: c.VkImageView,
        w: u32,
        h: u32,
        final_layout: c.VkImageLayout,
        final_stage: c.VkPipelineStageFlags,
        final_access: c.VkAccessFlags,
        /// The target stores blue first. See `Swapchain.swap_rb`.
        swap_rb: bool = false,
    };

    const Frame = struct {
        self: *Renderer,
        target: *Target,
        count: u32,
        clear: Color,
    };

    /// Uploads the scene's quads and draws them into the target, then reads the
    /// result back. `target.pixels()` holds the image when this returns.
    pub fn render(self: *Renderer, target: *Target, scene: *const Scene, clear: Color) Error!void {
        const count = try self.upload(scene);
        const frame: Frame = .{
            .self = self,
            .target = target,
            .count = count,
            .clear = clear,
        };
        try self.gpu.oneShot(Frame, frame, recordFrame);
    }

    /// Records a whole frame: the transition in, the clear, the draw, and the
    /// transition out. Shared by the offscreen path and the swapchain path.
    pub fn recordPass(self: *Renderer, cb: c.VkCommandBuffer, pass: Pass, count: u32, clear: Color) void {
        transition(
            cb,
            pass.image,
            c.VK_IMAGE_LAYOUT_UNDEFINED,
            c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            0,
            c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        );

        var clear_value: c.VkClearValue = undefined;
        clear_value.color.float32 = .{
            @as(f32, @floatFromInt(clear.r)) / 255.0,
            @as(f32, @floatFromInt(clear.g)) / 255.0,
            @as(f32, @floatFromInt(clear.b)) / 255.0,
            @as(f32, @floatFromInt(clear.a)) / 255.0,
        };
        const attachment: c.VkRenderingAttachmentInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = pass.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = clear_value,
        };
        const ri: c.VkRenderingInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = pass.w, .height = pass.h } },
            .layerCount = 1,
            .colorAttachmentCount = 1,
            .pColorAttachments = &attachment,
        };
        c.vkCmdBeginRendering(cb, &ri);

        if (count > 0 and self.pipeline != null) {
            const viewport: c.VkViewport = .{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(pass.w),
                .height = @floatFromInt(pass.h),
                .minDepth = 0,
                .maxDepth = 1,
            };
            const scissor: c.VkRect2D = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = pass.w, .height = pass.h },
            };
            c.vkCmdSetViewport(cb, 0, 1, &viewport);
            c.vkCmdSetScissor(cb, 0, 1, &scissor);
            c.vkCmdBindPipeline(cb, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
            if (self.desc_set != null) {
                c.vkCmdBindDescriptorSets(
                    cb,
                    c.VK_PIPELINE_BIND_POINT_GRAPHICS,
                    self.layout,
                    0,
                    1,
                    &self.desc_set,
                    0,
                    null,
                );
            }
            const offset: c.VkDeviceSize = 0;
            c.vkCmdBindVertexBuffers(cb, 0, 1, &self.instances, &offset);
            const push: Push = .{
                .vw = @floatFromInt(pass.w),
                .vh = @floatFromInt(pass.h),
                .flags = if (pass.swap_rb) flag_swap_rb else 0,
            };
            c.vkCmdPushConstants(cb, self.layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Push), &push);
            c.vkCmdDraw(cb, 6, count, 0, 0);
        }

        c.vkCmdEndRendering(cb);

        transition(
            cb,
            pass.image,
            c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            pass.final_layout,
            c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            pass.final_stage,
            c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            pass.final_access,
        );
    }

    /// Uploads the scene's quads into the instance buffer. Separated from
    /// recording because the swapchain path uploads once and records into a
    /// command buffer it owns.
    pub fn upload(self: *Renderer, scene: *const Scene) Error!u32 {
        const quads = scene.items();
        try self.ensureInstances(quads.len);
        // The one and only upload: the scene's own memory, byte for byte.
        if (quads.len > 0) {
            @memcpy(self.instance_mapped[0 .. quads.len * @sizeOf(Quad)], std.mem.sliceAsBytes(quads));
        }
        return @intCast(quads.len);
    }

    fn recordFrame(f: Frame, cb: c.VkCommandBuffer) void {
        const t = f.target;
        f.self.recordPass(cb, .{
            .image = t.image,
            .view = t.view,
            .w = t.w,
            .h = t.h,
            .final_layout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            .final_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            .final_access = c.VK_ACCESS_TRANSFER_READ_BIT,
        }, f.count, f.clear);

        const copy: c.VkBufferImageCopy = .{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = t.w, .height = t.h, .depth = 1 },
        };
        c.vkCmdCopyImageToBuffer(
            cb,
            t.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            t.readback,
            1,
            &copy,
        );
    }
};

fn shaderModule(gpu: *Gpu, spv: []align(4) const u8) Error!c.VkShaderModule {
    if (spv.len % 4 != 0 or spv.len < 20) return Error.ShaderRejected;
    if (std.mem.readInt(u32, spv[0..4], .little) != 0x07230203) return Error.ShaderRejected;
    const ci: c.VkShaderModuleCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = spv.len,
        .pCode = @ptrCast(spv.ptr),
    };
    var m: c.VkShaderModule = null;
    try check("vkCreateShaderModule", c.vkCreateShaderModule(gpu.device, &ci, null, &m));
    return m;
}

/// Renders a scene with no pipeline at all: the clear, the layout transitions,
/// the copy and the readback, and nothing else.
///
/// This exists because it is the half of the backend that can be verified
/// without a shader compiler, and because when a rendered frame comes out wrong
/// the first question is whether the problem is in the shader or in everything
/// around it.
pub fn clearOnly(gpu: *Gpu, target: *Target, color: Color) Error!void {
    var bare: Renderer = .{ .gpu = gpu };
    const frame: Renderer.Frame = .{
        .self = &bare,
        .target = target,
        .count = 0,
        .clear = color,
    };
    try gpu.oneShot(Renderer.Frame, frame, Renderer.recordFrame);
}
