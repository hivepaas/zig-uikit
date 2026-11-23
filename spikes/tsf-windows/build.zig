const std = @import("std");

/// Cross-compiles to Windows from any host: Zig bundles mingw-w64's msctf.h and
/// textstor.h, so no MSVC and no Windows SDK are needed.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    });
    const optimize = b.standardOptimizeOption(.{});

    const tc = b.addTranslateC(.{
        .root_source_file = b.path("src/win.h"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("c", tc.createModule());
    mod.link_libc = true;
    mod.linkSystemLibrary("ole32", .{});
    mod.linkSystemLibrary("oleaut32", .{});
    mod.linkSystemLibrary("user32", .{});
    mod.linkSystemLibrary("gdi32", .{});

    const exe = b.addExecutable(.{ .name = "tsf-spike", .root_module = mod });
    b.installArtifact(exe);
}
