// The whole native C surface, in one translation unit on purpose.
//
// Vulkan's Wayland surface extension refers to `struct wl_display` and
// `struct wl_surface`, so the Wayland and Vulkan declarations have to come out
// of a single translate-c step. Two steps would produce two distinct Zig types
// for the same C type, and nothing would pass between the backend and the
// window.
//
// This does mean the Vulkan backend's module carries Wayland declarations it
// never calls when rendering offscreen. That costs nothing at link time, since
// Zig emits relocations only for symbols actually referenced, and it is simpler
// than keeping two parallel surface types in step.
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

#define VK_USE_PLATFORM_WAYLAND_KHR
#include <vulkan/vulkan.h>
