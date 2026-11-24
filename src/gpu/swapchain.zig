//! Presentation: a Vulkan surface on a Wayland window, and the swapchain that
//! drives it.
//!
//! One frame in flight, deliberately. The instance buffer in `Renderer` is
//! single-buffered, so pipelining two frames would mean either a second buffer
//! or a race, and there is nothing to gain yet: the CPU side of a frame costs
//! microseconds against a 16 ms vsync interval. When that stops being true the
//! measurement will say so, and the buffer can be doubled then.
//!
//! `VK_PRESENT_MODE_FIFO_KHR`, which is the only mode Vulkan guarantees, and
//! the right one for a user interface: it is vsync, so the loop is paced by the
//! compositor rather than by a spin.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("vk");
const ui = @import("zig-uikit");
const vulkan = @import("vulkan.zig");

const Gpu = vulkan.Gpu;
const Renderer = vulkan.Renderer;
const Error = vulkan.Error;
const check = vulkan.check;
const Color = ui.Color;
const Scene = ui.Scene;

/// Wraps the Wayland surface in a `VkSurfaceKHR`. The Vulkan calls stay in this
/// module so the window module never has to know about Vulkan.
pub fn createWaylandSurface(
    gpu: *Gpu,
    display: *c.struct_wl_display,
    wl_surface: *c.struct_wl_surface,
) Error!c.VkSurfaceKHR {
    const ci: c.VkWaylandSurfaceCreateInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
        .display = display,
        .surface = wl_surface,
    };
    var surface: c.VkSurfaceKHR = null;
    try check("vkCreateWaylandSurfaceKHR", c.vkCreateWaylandSurfaceKHR(gpu.instance, &ci, null, &surface));
    return surface;
}

pub const Swapchain = struct {
    gpa: Allocator,
    gpu: *Gpu,
    surface: c.VkSurfaceKHR,

    handle: c.VkSwapchainKHR = null,
    format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
    /// True when the chosen format stores blue first, so the shader has to swap
    /// red and blue on the way in. `B8G8R8A8_UNORM` is frequently the only
    /// eight-bit UNORM format a surface offers, and silently rendering with the
    /// channels crossed is the kind of bug that looks like a palette mistake.
    swap_rb: bool = false,
    extent: c.VkExtent2D = .{ .width = 0, .height = 0 },

    images: []c.VkImage = &.{},
    views: []c.VkImageView = &.{},
    /// One per swapchain image, not per frame: a present operation waits on the
    /// semaphore belonging to the image it is presenting, and reusing one
    /// across images is a use-after-signal waiting to happen.
    rendered: []c.VkSemaphore = &.{},

    acquired: c.VkSemaphore = null,
    fence: c.VkFence = null,
    cmd: c.VkCommandBuffer = null,

    /// Set to have the next presented frame copied into `capture_mapped`.
    ///
    /// This exists so the presented image can be checked, not as a feature. A
    /// swapchain has its own format, its own extent and its own channel order,
    /// and none of those are exercised by rendering offscreen -- so "the
    /// offscreen path matches the software reference" says nothing about what
    /// is on the screen. The copy is recorded into the same command buffer as
    /// the frame, so what lands here is the image that was presented and not a
    /// re-render of it.
    capture_request: bool = false,
    capture_buf: c.VkBuffer = null,
    capture_mem: c.VkDeviceMemory = null,
    capture_mapped: [*]u8 = undefined,
    capture_size: usize = 0,

    pub fn init(gpa: Allocator, gpu: *Gpu, surface: c.VkSurfaceKHR, w: u32, h: u32) Error!Swapchain {
        var self: Swapchain = .{ .gpa = gpa, .gpu = gpu, .surface = surface };
        errdefer self.deinit();

        const sci: c.VkSemaphoreCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
        try check("vkCreateSemaphore", c.vkCreateSemaphore(gpu.device, &sci, null, &self.acquired));
        const fci: c.VkFenceCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        };
        try check("vkCreateFence", c.vkCreateFence(gpu.device, &fci, null, &self.fence));
        const cbai: c.VkCommandBufferAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = gpu.pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        try check("vkAllocateCommandBuffers", c.vkAllocateCommandBuffers(gpu.device, &cbai, &self.cmd));

        try self.build(w, h);
        return self;
    }

    pub fn deinit(self: *Swapchain) void {
        const d = self.gpu.device;
        if (d == null) return;
        _ = c.vkDeviceWaitIdle(d);
        self.teardown();
        if (self.capture_mem != null) {
            c.vkUnmapMemory(d, self.capture_mem);
            c.vkFreeMemory(d, self.capture_mem, null);
            c.vkDestroyBuffer(d, self.capture_buf, null);
        }
        if (self.cmd != null) c.vkFreeCommandBuffers(d, self.gpu.pool, 1, &self.cmd);
        if (self.fence != null) c.vkDestroyFence(d, self.fence, null);
        if (self.acquired != null) c.vkDestroySemaphore(d, self.acquired, null);
        if (self.surface != null) c.vkDestroySurfaceKHR(self.gpu.instance, self.surface, null);
        self.* = undefined;
    }

    fn teardown(self: *Swapchain) void {
        const d = self.gpu.device;
        for (self.rendered) |s| if (s != null) c.vkDestroySemaphore(d, s, null);
        for (self.views) |v| if (v != null) c.vkDestroyImageView(d, v, null);
        self.gpa.free(self.rendered);
        self.gpa.free(self.views);
        self.gpa.free(self.images);
        self.rendered = &.{};
        self.views = &.{};
        self.images = &.{};
        if (self.handle != null) c.vkDestroySwapchainKHR(d, self.handle, null);
        self.handle = null;
    }

    fn build(self: *Swapchain, w: u32, h: u32) Error!void {
        const gpu = self.gpu;

        var caps: c.VkSurfaceCapabilitiesKHR = undefined;
        try check(
            "vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
            c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(gpu.physical, self.surface, &caps),
        );

        // A compositor that has decided the size reports it here; 0xFFFFFFFF
        // means it has not, and the window's own idea of its size is used.
        self.extent = if (caps.currentExtent.width != 0xFFFF_FFFF)
            caps.currentExtent
        else .{
            .width = std.math.clamp(w, caps.minImageExtent.width, caps.maxImageExtent.width),
            .height = std.math.clamp(h, caps.minImageExtent.height, caps.maxImageExtent.height),
        };
        if (self.extent.width == 0 or self.extent.height == 0) return Error.SurfaceHasNoArea;

        var nf: u32 = 0;
        try check(
            "vkGetPhysicalDeviceSurfaceFormatsKHR",
            c.vkGetPhysicalDeviceSurfaceFormatsKHR(gpu.physical, self.surface, &nf, null),
        );
        const formats = try self.gpa.alloc(c.VkSurfaceFormatKHR, nf);
        defer self.gpa.free(formats);
        try check(
            "vkGetPhysicalDeviceSurfaceFormatsKHR",
            c.vkGetPhysicalDeviceSurfaceFormatsKHR(gpu.physical, self.surface, &nf, formats.ptr),
        );

        // UNORM and not SRGB, for the same reason the offscreen target is
        // UNORM: the whole toolkit blends eight-bit sRGB values directly, and
        // an SRGB swapchain would make the compositor path disagree with the
        // software reference.
        var chosen: ?c.VkSurfaceFormatKHR = null;
        for (formats[0..nf]) |f| {
            if (f.colorSpace != c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) continue;
            if (f.format == c.VK_FORMAT_R8G8B8A8_UNORM) {
                chosen = f;
                break;
            }
            if (f.format == c.VK_FORMAT_B8G8R8A8_UNORM and chosen == null) chosen = f;
        }
        const fmt = chosen orelse return Error.NoSuitableSurfaceFormat;
        self.format = fmt.format;
        self.swap_rb = fmt.format == c.VK_FORMAT_B8G8R8A8_UNORM;

        var count = caps.minImageCount + 1;
        if (caps.maxImageCount > 0 and count > caps.maxImageCount) count = caps.maxImageCount;

        var usage: c.VkImageUsageFlags = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        if (caps.supportedUsageFlags & c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT != 0) {
            usage |= c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        }

        const ci: c.VkSwapchainCreateInfoKHR = .{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = self.surface,
            .minImageCount = count,
            .imageFormat = self.format,
            .imageColorSpace = fmt.colorSpace,
            .imageExtent = self.extent,
            .imageArrayLayers = 1,
            // TRANSFER_SRC so a presented frame can be copied out; see
            // `capture_request`. Universally supported for swapchain images in
            // practice, and the capability is checked below.
            .imageUsage = usage,
            .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .preTransform = caps.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = c.VK_PRESENT_MODE_FIFO_KHR,
            .clipped = c.VK_TRUE,
        };
        try check("vkCreateSwapchainKHR", c.vkCreateSwapchainKHR(gpu.device, &ci, null, &self.handle));

        var n: u32 = 0;
        try check("vkGetSwapchainImagesKHR", c.vkGetSwapchainImagesKHR(gpu.device, self.handle, &n, null));
        self.images = try self.gpa.alloc(c.VkImage, n);
        try check("vkGetSwapchainImagesKHR", c.vkGetSwapchainImagesKHR(gpu.device, self.handle, &n, self.images.ptr));

        self.views = try self.gpa.alloc(c.VkImageView, n);
        @memset(self.views, null);
        self.rendered = try self.gpa.alloc(c.VkSemaphore, n);
        @memset(self.rendered, null);
        const sci: c.VkSemaphoreCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
        for (self.images, 0..) |img, i| {
            const vci: c.VkImageViewCreateInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = img,
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = self.format,
                .subresourceRange = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .levelCount = 1,
                    .layerCount = 1,
                },
            };
            try check("vkCreateImageView", c.vkCreateImageView(gpu.device, &vci, null, &self.views[i]));
            try check("vkCreateSemaphore", c.vkCreateSemaphore(gpu.device, &sci, null, &self.rendered[i]));
        }
    }

    pub fn recreate(self: *Swapchain, w: u32, h: u32) Error!void {
        _ = c.vkDeviceWaitIdle(self.gpu.device);
        self.teardown();
        try self.build(w, h);
    }

    fn ensureCaptureBuffer(self: *Swapchain) Error!void {
        const need = @as(usize, self.extent.width) * self.extent.height * 4;
        if (need <= self.capture_size) return;
        const d = self.gpu.device;
        if (self.capture_mem != null) {
            c.vkUnmapMemory(d, self.capture_mem);
            c.vkFreeMemory(d, self.capture_mem, null);
            c.vkDestroyBuffer(d, self.capture_buf, null);
        }
        const bci: c.VkBufferCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = need,
            .usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        };
        try check("vkCreateBuffer", c.vkCreateBuffer(d, &bci, null, &self.capture_buf));
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(d, self.capture_buf, &req);
        const mai: c.VkMemoryAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size,
            .memoryTypeIndex = try self.gpu.memoryType(
                req.memoryTypeBits,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            ),
        };
        try check("vkAllocateMemory", c.vkAllocateMemory(d, &mai, null, &self.capture_mem));
        try check("vkBindBufferMemory", c.vkBindBufferMemory(d, self.capture_buf, self.capture_mem, 0));
        var ptr: ?*anyopaque = null;
        try check("vkMapMemory", c.vkMapMemory(d, self.capture_mem, 0, need, 0, &ptr));
        self.capture_mapped = @ptrCast(ptr.?);
        self.capture_size = need;
    }

    fn recordCapture(self: *Swapchain, index: u32) void {
        const copy: c.VkBufferImageCopy = .{
            .imageSubresource = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .layerCount = 1,
            },
            .imageExtent = .{ .width = self.extent.width, .height = self.extent.height, .depth = 1 },
        };
        c.vkCmdCopyImageToBuffer(
            self.cmd,
            self.images[index],
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            self.capture_buf,
            1,
            &copy,
        );
        vulkan.transitionPublic(
            self.cmd,
            self.images[index],
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            c.VK_ACCESS_TRANSFER_READ_BIT,
            0,
        );
    }

    /// The last captured frame, in the swapchain's own channel order. When
    /// `swap_rb` is set this is BGRA, which is what `captureRgba` exists for.
    pub fn captured(self: *const Swapchain) []const u8 {
        return self.capture_mapped[0 .. @as(usize, self.extent.width) * self.extent.height * 4];
    }

    /// The last captured frame as RGBA, converting if the swapchain is BGRA.
    pub fn captureRgba(self: *const Swapchain, gpa: Allocator) Allocator.Error![]u8 {
        const src = self.captured();
        const out = try gpa.alloc(u8, src.len);
        if (!self.swap_rb) {
            @memcpy(out, src);
            return out;
        }
        var i: usize = 0;
        while (i < src.len) : (i += 4) {
            out[i + 0] = src[i + 2];
            out[i + 1] = src[i + 1];
            out[i + 2] = src[i + 0];
            out[i + 3] = src[i + 3];
        }
        return out;
    }

    /// Draws the scene into the next swapchain image and presents it.
    ///
    /// Returns false when the swapchain no longer matches the surface, which is
    /// what a resize looks like from here; the caller recreates and tries
    /// again. That is not an error, so it is not reported as one.
    pub fn drawAndPresent(
        self: *Swapchain,
        renderer: *Renderer,
        scene: *const Scene,
        clear: Color,
    ) Error!bool {
        const gpu = self.gpu;
        try check("vkWaitForFences", c.vkWaitForFences(gpu.device, 1, &self.fence, c.VK_TRUE, std.math.maxInt(u64)));

        var index: u32 = 0;
        const acq = c.vkAcquireNextImageKHR(
            gpu.device,
            self.handle,
            std.math.maxInt(u64),
            self.acquired,
            null,
            &index,
        );
        if (acq == c.VK_ERROR_OUT_OF_DATE_KHR) return false;
        if (acq != c.VK_SUCCESS and acq != c.VK_SUBOPTIMAL_KHR) {
            try check("vkAcquireNextImageKHR", acq);
        }

        const count = try renderer.upload(scene);

        try check("vkResetFences", c.vkResetFences(gpu.device, 1, &self.fence));
        try check("vkResetCommandBuffer", c.vkResetCommandBuffer(self.cmd, 0));
        const bi: c.VkCommandBufferBeginInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        try check("vkBeginCommandBuffer", c.vkBeginCommandBuffer(self.cmd, &bi));
        const capturing = self.capture_request;
        if (capturing) try self.ensureCaptureBuffer();
        renderer.recordPass(self.cmd, .{
            .image = self.images[index],
            .view = self.views[index],
            .w = self.extent.width,
            .h = self.extent.height,
            .final_layout = if (capturing)
                c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
            else
                c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            .final_stage = if (capturing)
                c.VK_PIPELINE_STAGE_TRANSFER_BIT
            else
                c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            .final_access = if (capturing) c.VK_ACCESS_TRANSFER_READ_BIT else 0,
            .swap_rb = self.swap_rb,
        }, count, clear);
        if (capturing) self.recordCapture(index);
        try check("vkEndCommandBuffer", c.vkEndCommandBuffer(self.cmd));

        const wait_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        const si: c.VkSubmitInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.acquired,
            .pWaitDstStageMask = &wait_stage,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.cmd,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &self.rendered[index],
        };
        try check("vkQueueSubmit", c.vkQueueSubmit(gpu.queue, 1, &si, self.fence));

        const pi: c.VkPresentInfoKHR = .{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &self.rendered[index],
            .swapchainCount = 1,
            .pSwapchains = &self.handle,
            .pImageIndices = &index,
        };
        if (capturing) {
            try check("vkWaitForFences", c.vkWaitForFences(gpu.device, 1, &self.fence, c.VK_TRUE, std.math.maxInt(u64)));
            self.capture_request = false;
        }

        const pres = c.vkQueuePresentKHR(gpu.queue, &pi);
        if (pres == c.VK_ERROR_OUT_OF_DATE_KHR or pres == c.VK_SUBOPTIMAL_KHR) return false;
        try check("vkQueuePresentKHR", pres);
        return true;
    }
};
