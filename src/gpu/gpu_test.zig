//! Tests that need a Vulkan device, kept out of `zig build test` on purpose.
//!
//! Each one skips rather than fails when there is no device, so that running
//! them on a machine without a GPU reports "skipped" instead of a red build
//! that means nothing.

const std = @import("std");
const testing = std.testing;
const ui = @import("zig-uikit");
const vk = @import("vulkan.zig");

fn openGpu() !vk.Gpu {
    return vk.Gpu.init(testing.allocator, .{}) catch return error.SkipZigTest;
}

test "a device can be opened and reports a name" {
    var gpu = try openGpu();
    defer gpu.deinit();
    try testing.expect(gpu.name().len > 0);
    try testing.expect(gpu.device != null);
    try testing.expect(gpu.queue != null);
}

test "clear and read back returns exactly the clear colour" {
    var gpu = try openGpu();
    defer gpu.deinit();
    var target = try vk.Target.init(&gpu, 64, 48);
    defer target.deinit();

    const c = ui.Color.rgba(0x33, 0x66, 0x99, 0xFF);
    try vk.clearOnly(&gpu, &target, c);

    const px = target.pixels();
    try testing.expectEqual(@as(usize, 64 * 48 * 4), px.len);
    for (0..64 * 48) |i| {
        try testing.expectEqual(c.r, px[i * 4 + 0]);
        try testing.expectEqual(c.g, px[i * 4 + 1]);
        try testing.expectEqual(c.b, px[i * 4 + 2]);
    }
}

test "a target can be resized by making another one" {
    var gpu = try openGpu();
    defer gpu.deinit();
    for ([_]u32{ 1, 17, 256 }) |n| {
        var target = try vk.Target.init(&gpu, n, n);
        defer target.deinit();
        try vk.clearOnly(&gpu, &target, ui.Color.white);
        try testing.expectEqual(@as(u8, 255), target.pixels()[0]);
    }
}

test "a shader module is rejected before Vulkan sees it" {
    var gpu = try openGpu();
    defer gpu.deinit();
    // Not a multiple of four, too short, and the wrong magic number: three
    // ways for a build step to hand over a file that is not SPIR-V.
    try testing.expectError(vk.Error.ShaderRejected, vk.Renderer.init(&gpu, "abc", "abc"));
    const zeros: [32]u8 = @splat(0);
    try testing.expectError(vk.Error.ShaderRejected, vk.Renderer.init(&gpu, &zeros, &zeros));
}
