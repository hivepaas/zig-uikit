// The text stack's C surface: font discovery, rasterisation and shaping.
//
// A separate translation unit from `native.h` on purpose. Nothing crosses
// between them -- what the renderer receives from here is a byte buffer of
// coverage and its dimensions, not a FreeType or HarfBuzz type -- so the
// reason `native.h` has to be one unit (a `struct wl_display` shared between
// Wayland and Vulkan) does not apply, and keeping them apart means the layout
// core's dependencies do not grow a GPU and the renderer's do not grow a font
// engine.
#include <fontconfig/fontconfig.h>

// `#include FT_FREETYPE_H` is the documented spelling, and translate-c cannot
// follow a macro used as an include target. The direct path has been supported
// since FreeType 2.10.
#include <freetype/freetype.h>

#include <hb.h>
#include <hb-ft.h>
