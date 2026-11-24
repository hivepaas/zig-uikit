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

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the layout tests").dependOn(&run_tests.step);
    b.getInstallStep().dependOn(&run_tests.step);
}
