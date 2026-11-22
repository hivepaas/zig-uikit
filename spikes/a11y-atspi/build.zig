const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Hardcoded rather than read from `pkg-config --cflags dbus-1`, to keep the
    // spike's build readable. The real toolkit must query pkg-config: the second
    // path is architecture-dependent.
    const dbus_inc = [_][]const u8{
        "/usr/include/dbus-1.0",
        "/usr/lib/x86_64-linux-gnu/dbus-1.0/include",
    };

    const tc = b.addTranslateC(.{
        .root_source_file = b.path("src/dbus.h"),
        .target = target,
        .optimize = optimize,
    });
    for (dbus_inc) |p| tc.addIncludePath(.{ .cwd_relative = p });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("c", tc.createModule());
    mod.link_libc = true;
    for (dbus_inc) |p| mod.addIncludePath(.{ .cwd_relative = p });
    mod.linkSystemLibrary("dbus-1", .{});

    const exe = b.addExecutable(.{ .name = "a11y-atspi", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Expose the tree on the accessibility bus").dependOn(&run.step);
}
