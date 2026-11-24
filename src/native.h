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
#include "text-input-unstable-v3-client-protocol.h"

// The keymap a compositor sends is a string in xkb's own text format, and
// turning a keycode into a character means compiling it. There is no way to
// do keyboard input on Wayland without this library: the protocol carries
// evdev scancodes and nothing else, so the client owns the entire translation
// from scancode to text. Only the window module links it -- the renderer
// never calls into it, so it costs the renderer nothing.
#include <xkbcommon/xkbcommon.h>

#define VK_USE_PLATFORM_WAYLAND_KHR
#include <vulkan/vulkan.h>
