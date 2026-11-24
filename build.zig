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

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the layout tests").dependOn(&run_tests.step);
    b.getInstallStep().dependOn(&run_tests.step);
}
