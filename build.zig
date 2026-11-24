const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library. No platform dependencies yet: the layout core is pure
    // computation and is tested without a window, a GPU or a compositor.
    const mod = b.addModule("zig-uikit", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- the text stack ---
    //
    // A separate module, for the same reason the renderers are: shaping and
    // rasterisation need fontconfig, FreeType and HarfBuzz, and the layout core
    // is tested on machines with none of them. `src/glyph.zig` carries the
    // plain-data types that let the core lay out and paint text it cannot
    // itself produce.
    //
    // Not behind the platform switch, because nothing in it is
    // platform-specific -- but see `test-text` in the README: the three
    // libraries have to be installed, which on macOS means Homebrew.
    const text_c = b.addTranslateC(.{
        .root_source_file = b.path("src/text.h"),
        .target = target,
        .optimize = optimize,
    });
    for (pkgIncludes(b, &.{ "freetype2", "harfbuzz", "fontconfig" })) |dir| {
        text_c.addIncludePath(.{ .cwd_relative = dir });
    }

    const text_mod = b.addModule("zig-uikit-text", .{
        .root_source_file = b.path("src/text/text.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = text_c.createModule() },
            .{ .name = "zig-uikit", .module = mod },
        },
    });
    text_mod.linkSystemLibrary("freetype", .{});
    text_mod.linkSystemLibrary("harfbuzz", .{});
    text_mod.linkSystemLibrary("fontconfig", .{});

    const text_tests = b.addTest(.{ .root_module = text_mod });
    const run_text_tests = b.addRunArtifact(text_tests);
    b.step("test-text", "Run the tests that need a font installed").dependOn(&run_text_tests.step);

    // A window's worth of interface, rasterised in software and written as a
    // PPM. There is no renderer yet, so this is how the scene layer is looked
    // at rather than only asserted about.
    const demo = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-uikit", .module = mod },
                .{ .name = "zig-uikit-text", .module = text_mod },
            },
        }),
    });
    const run_demo = b.addRunArtifact(demo);
    b.step("demo", "Render a demo interface to demo.ppm").dependOn(&run_demo.step);

    // Scene build and rasterisation cost, against the figures in the benchmark
    // repository that the design was chosen from.
    const bench = b.addExecutable(.{
        .name = "scene_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/scene_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-uikit", .module = mod },
                .{ .name = "zig-uikit-text", .module = text_mod },
            },
        }),
    });
    // Deliberately inherits -Doptimize rather than forcing ReleaseFast: the
    // library module carries its own optimize mode, so forcing it here would
    // link release-built benchmark code against a debug-built library and
    // report a number that is neither. The benchmark says so at runtime
    // instead of producing a quiet lie.
    const run_bench = b.addRunArtifact(bench);
    b.step("bench", "Measure scene build and raster cost").dependOn(&run_bench.step);

    // The platform layer. One set of step names, and the backend behind them
    // follows the target: Vulkan and Wayland on Linux, Metal and AppKit on
    // macOS. `zig build window` means the same thing on both.
    switch (target.result.os.tag) {
        .macos => addMacos(b, target, optimize, mod, text_mod),
        else => addLinux(b, target, optimize, mod, text_mod),
    }

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the layout tests").dependOn(&run_tests.step);
    b.getInstallStep().dependOn(&run_tests.step);
}

fn addLinux(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mod: *std.Build.Module,
    text_mod: *std.Build.Module,
) void {
    // --- the Vulkan backend ---
    //
    // A separate module on purpose. The library above has no platform
    // dependencies and its tests run anywhere; this links libvulkan and needs a
    // device, so it gets its own module and its own steps. A toolkit whose unit
    // tests need a GPU is a toolkit nobody runs the tests of.
    // wayland-scanner turns protocol XML into a header of request wrappers and
    // a .c file of interface tables. Both are needed: the header to call
    // through, the tables to link against.
    const proto_dir = "/usr/share/wayland-protocols";
    const xdg_header_cmd = b.addSystemCommand(&.{ "wayland-scanner", "client-header", proto_dir ++ "/stable/xdg-shell/xdg-shell.xml" });
    const xdg_header = xdg_header_cmd.addOutputFileArg("xdg-shell-client-protocol.h");
    const xdg_code_cmd = b.addSystemCommand(&.{ "wayland-scanner", "private-code", proto_dir ++ "/stable/xdg-shell/xdg-shell.xml" });
    const xdg_code = xdg_code_cmd.addOutputFileArg("xdg-shell-protocol.c");

    const vk_c = b.addTranslateC(.{
        .root_source_file = b.path("src/native.h"),
        .target = target,
        .optimize = optimize,
    });
    vk_c.addIncludePath(xdg_header.dirname());
    const c_mod = vk_c.createModule();

    const gpu_mod = b.addModule("zig-uikit-vulkan", .{
        .root_source_file = b.path("src/gpu/gpu.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "vk", .module = c_mod },
            .{ .name = "zig-uikit", .module = mod },
        },
    });
    gpu_mod.linkSystemLibrary("vulkan", .{});

    // The window. Separate from the renderer because they are separate
    // concerns even on the one platform that exists so far: this module knows
    // nothing about Vulkan beyond handing over a surface.
    const wl_mod = b.addModule("zig-uikit-wayland", .{
        .root_source_file = b.path("src/platform/wayland.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "vk", .module = c_mod },
            // For `keys.zig` only: the window fills a queue of plain-data key
            // events and knows nothing else about the toolkit.
            .{ .name = "zig-uikit", .module = mod },
        },
    });
    wl_mod.linkSystemLibrary("wayland-client", .{});
    // Only this module. The keymap compiler is what turns an evdev scancode
    // into a character; the renderer never asks, so it never links it.
    wl_mod.linkSystemLibrary("xkbcommon", .{});
    // The generated interface tables are plain C and have to be compiled in.
    wl_mod.addCSourceFile(.{ .file = xdg_code, .flags = &.{"-std=c99"} });

    const window_demo = b.addExecutable(.{
        .name = "window_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/window_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-uikit", .module = mod },
                .{ .name = "zig-uikit-vulkan", .module = gpu_mod },
                .{ .name = "zig-uikit-wayland", .module = wl_mod },
                .{ .name = "zig-uikit-text", .module = text_mod },
            },
        }),
    });
    // Installed as well as runnable, because `zig build window` cannot forward
    // arguments -- `b.args` was removed in Zig 0.17 -- and the capture mode
    // needs one.
    b.installArtifact(window_demo);
    const run_window_demo = b.addRunArtifact(window_demo);
    b.step("window", "Open a window and render the demo on the GPU").dependOn(&run_window_demo.step);

    const gpu_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/gpu_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zig-uikit", .module = mod },
                .{ .name = "vk", .module = c_mod },
            },
        }),
    });
    gpu_tests.root_module.linkSystemLibrary("vulkan", .{});
    const run_gpu_tests = b.addRunArtifact(gpu_tests);
    b.step("test-gpu", "Run the tests that need a Vulkan device").dependOn(&run_gpu_tests.step);

    // The keyboard translation, without a compositor. `xkbcommon` compiles a
    // keymap from layout names alone, so the scancode-to-character path is
    // testable on any machine with a keyboard layout installed -- which is a
    // much weaker requirement than a seat, a window and someone pressing keys.
    const input_tests = b.addTest(.{ .root_module = wl_mod });
    const run_input_tests = b.addRunArtifact(input_tests);
    b.step("test-input", "Run the keyboard tests, which need xkbcommon and a layout")
        .dependOn(&run_input_tests.step);

    const gpu_demo = b.addExecutable(.{
        .name = "gpu_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gpu_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-uikit", .module = mod },
                .{ .name = "gpu", .module = gpu_mod },
                .{ .name = "zig-uikit-text", .module = text_mod },
            },
        }),
    });
    const run_gpu_demo = b.addRunArtifact(gpu_demo);
    b.step("gpu-demo", "Render the demo on the GPU and diff it against the software reference")
        .dependOn(&run_gpu_demo.step);
}

/// Metal and AppKit, both reached through the Objective-C runtime: there is no
/// translate-c step, because Zig cannot read Objective-C headers, and no
/// shader compiler, because the Metal source is compiled at run time. Building
/// for macOS needs the SDK's frameworks and nothing else.
fn addMacos(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mod: *std.Build.Module,
    text_mod: *std.Build.Module,
) void {
    const objc_mod = b.addModule("zig-uikit-objc", .{
        .root_source_file = b.path("src/platform/objc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    objc_mod.linkSystemLibrary("objc", .{ .use_pkg_config = .no });
    objc_mod.linkFramework("Foundation", .{});

    const metal_mod = b.addModule("zig-uikit-metal", .{
        .root_source_file = b.path("src/gpu/metal.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zig-uikit", .module = mod },
            .{ .name = "objc", .module = objc_mod },
        },
    });
    metal_mod.linkFramework("Metal", .{});
    metal_mod.linkFramework("QuartzCore", .{});
    metal_mod.linkFramework("CoreGraphics", .{});

    // The window knows nothing about Metal beyond creating the layer it will
    // be drawn into, as the Wayland window knows nothing about Vulkan beyond
    // handing over a surface.
    const appkit_mod = b.addModule("zig-uikit-macos", .{
        .root_source_file = b.path("src/platform/macos.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "objc", .module = objc_mod },
            // For the key events, the document and the input-method model in
            // core, as the Wayland window imports it for `keys.zig`.
            .{ .name = "zig-uikit", .module = mod },
        },
    });
    appkit_mod.linkFramework("AppKit", .{});
    appkit_mod.linkFramework("QuartzCore", .{});
    appkit_mod.linkFramework("CoreGraphics", .{});

    const window_demo = b.addExecutable(.{
        .name = "window_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/window_demo_macos.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-uikit", .module = mod },
                .{ .name = "zig-uikit-metal", .module = metal_mod },
                .{ .name = "zig-uikit-macos", .module = appkit_mod },
                .{ .name = "zig-uikit-text", .module = text_mod },
            },
        }),
    });
    b.installArtifact(window_demo);
    const run_window_demo = b.addRunArtifact(window_demo);
    b.step("window", "Open a window and render the demo on the GPU").dependOn(&run_window_demo.step);

    const gpu_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gpu/metal_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-uikit", .module = mod },
                .{ .name = "objc", .module = objc_mod },
            },
        }),
    });
    gpu_tests.root_module.linkFramework("Metal", .{});
    gpu_tests.root_module.linkFramework("QuartzCore", .{});
    gpu_tests.root_module.linkFramework("CoreGraphics", .{});
    const run_gpu_tests = b.addRunArtifact(gpu_tests);
    b.step("test-gpu", "Run the tests that need a Metal device").dependOn(&run_gpu_tests.step);

    const gpu_demo = b.addExecutable(.{
        .name = "gpu_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gpu_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-uikit", .module = mod },
                .{ .name = "gpu", .module = metal_mod },
                .{ .name = "zig-uikit-text", .module = text_mod },
            },
        }),
    });
    const run_gpu_demo = b.addRunArtifact(gpu_demo);
    b.step("gpu-demo", "Render the demo on the GPU and diff it against the software reference")
        .dependOn(&run_gpu_demo.step);
}

/// The include directories `pkg-config` reports for a set of libraries.
///
/// `linkSystemLibrary` finds these for a compilation, but translate-c is a
/// separate step that needs them spelled out, and FreeType and HarfBuzz both
/// live in a subdirectory rather than on the default include path. Hardcoding
/// `/usr/include/freetype2` works on this machine and not on a BSD, a Nix
/// store or a Mac, so the question is asked rather than assumed -- and if
/// `pkg-config` is absent the usual Linux paths are tried anyway, because
/// failing the whole build over a missing helper would be worse than a clear
/// compile error about a missing header.
fn pkgIncludes(b: *std.Build, libs: []const []const u8) []const []const u8 {
    // Resolved to an absolute path first. `runAllowFail` does not search PATH
    // for argv[0] (`expand_arg0` defaults to `.no_expand`), so a bare
    // "pkg-config" always failed to spawn and the Linux fallback below was
    // what ran everywhere -- correct on Debian by coincidence, and the reason
    // Homebrew's headers were never found on a Mac.
    const pkg_config = b.findProgram(.{ .names = &.{ "pkg-config", "pkgconf" } }) orelse "pkg-config";
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(b.allocator, &.{ pkg_config, "--cflags-only-I" }) catch @panic("OOM");
    argv.appendSlice(b.allocator, libs) catch @panic("OOM");

    var out: std.ArrayList([]const u8) = .empty;
    var code: u8 = 0;
    if (b.runAllowFail(argv.items, &code, .ignore)) |stdout| {
        var it = std.mem.tokenizeAny(u8, stdout, " \n\r\t");
        while (it.next()) |tok| {
            if (std.mem.startsWith(u8, tok, "-I")) {
                out.append(b.allocator, tok[2..]) catch @panic("OOM");
            }
        }
    } else |_| {
        out.appendSlice(b.allocator, &.{
            "/usr/include/freetype2",
            "/usr/include/harfbuzz",
        }) catch @panic("OOM");
    }
    return out.items;
}
