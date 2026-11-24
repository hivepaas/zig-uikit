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

    // A window's worth of interface, rasterised in software and written as a
    // PPM. There is no renderer yet, so this is how the scene layer is looked
    // at rather than only asserted about.
    const demo = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zig-uikit", .module = mod }},
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
            .imports = &.{.{ .name = "zig-uikit", .module = mod }},
        }),
    });
    // Deliberately inherits -Doptimize rather than forcing ReleaseFast: the
    // library module carries its own optimize mode, so forcing it here would
    // link release-built benchmark code against a debug-built library and
    // report a number that is neither. The benchmark says so at runtime
    // instead of producing a quiet lie.
    const run_bench = b.addRunArtifact(bench);
    b.step("bench", "Measure scene build and raster cost").dependOn(&run_bench.step);

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
        .imports = &.{.{ .name = "vk", .module = c_mod }},
    });
    wl_mod.linkSystemLibrary("wayland-client", .{});
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

    const gpu_demo = b.addExecutable(.{
        .name = "gpu_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gpu_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig-uikit", .module = mod },
                .{ .name = "zig-uikit-vulkan", .module = gpu_mod },
            },
        }),
    });
    const run_gpu_demo = b.addRunArtifact(gpu_demo);
    b.step("gpu-demo", "Render the demo on the GPU and diff it against the software reference")
        .dependOn(&run_gpu_demo.step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the layout tests").dependOn(&run_tests.step);
    b.getInstallStep().dependOn(&run_tests.step);
}
