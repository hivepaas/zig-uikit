//! The Vulkan backend's public surface: offscreen rendering and presentation.

const vulkan = @import("vulkan.zig");
const swapchain = @import("swapchain.zig");

pub const Error = vulkan.Error;
pub const Gpu = vulkan.Gpu;
pub const Target = vulkan.Target;
pub const Renderer = vulkan.Renderer;
pub const clearOnly = vulkan.clearOnly;
pub const lastErrorMessage = vulkan.lastErrorMessage;
pub const shaders = vulkan.shaders;

pub const Swapchain = swapchain.Swapchain;
pub const createWaylandSurface = swapchain.createWaylandSurface;

test {
    _ = vulkan;
    _ = swapchain;
}
