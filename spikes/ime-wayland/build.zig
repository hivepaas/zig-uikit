const std = @import("std");

/// Where the system keeps protocol XML. Hardcoded rather than discovered via
/// `pkg-config --variable=pkgdatadir wayland-protocols` to keep the spike's
/// build readable; the real toolkit must query pkg-config.
const PROTO = "/usr/share/wayland-protocols";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // wayland-scanner turns protocol XML into a C header of static inline
    // request wrappers plus a .c file holding the interface tables. Both are
    // needed: the header to call, the table to link against.
    const Gen = struct {
        header: std.Build.LazyPath,
        code: std.Build.LazyPath,
    };

    const gen = struct {
        fn run(bb: *std.Build, xml: []const u8, stem: []const u8) Gen {
            const h = bb.addSystemCommand(&.{ "wayland-scanner", "client-header", xml });
            const header = h.addOutputFileArg(bb.fmt("{s}-client-protocol.h", .{stem}));
            const c = bb.addSystemCommand(&.{ "wayland-scanner", "private-code", xml });
            const code = c.addOutputFileArg(bb.fmt("{s}-protocol.c", .{stem}));
            return .{ .header = header, .code = code };
        }
    }.run;

    const xdg = gen(b, PROTO ++ "/stable/xdg-shell/xdg-shell.xml", "xdg-shell");
    const ti = gen(b, PROTO ++ "/unstable/text-input/text-input-unstable-v3.xml", "text-input-unstable-v3");

    // @cImport was removed in Zig 0.17, so the C surface is a translate-c build
    // step imported as a module.
    const tc = b.addTranslateC(.{
        .root_source_file = b.path("src/wl.h"),
        .target = target,
        .optimize = optimize,
    });
    tc.addIncludePath(xdg.header.dirname());
    tc.addIncludePath(ti.header.dirname());

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("c", tc.createModule());
    mod.link_libc = true;
    mod.addIncludePath(xdg.header.dirname());
    mod.addIncludePath(ti.header.dirname());
    mod.linkSystemLibrary("wayland-client", .{});
    mod.linkSystemLibrary("xkbcommon", .{});
    // The generated interface tables are plain C and must be compiled in.
    // In Zig 0.17 C sources attach to the module, not to the Compile step.
    mod.addCSourceFile(.{ .file = xdg.code, .flags = &.{"-std=c99"} });
    mod.addCSourceFile(.{ .file = ti.code, .flags = &.{"-std=c99"} });

    const exe = b.addExecutable(.{ .name = "ime-wayland", .root_module = mod });
    b.installArtifact(exe);

    // `b.args` no longer exists in Zig 0.17, so there is no forwarding of
    // trailing arguments here; run ./zig-out/bin/ime-wayland --probe directly.
    const run = b.addRunArtifact(exe);
    b.step("run", "Open the window and type into it").dependOn(&run.step);
}
