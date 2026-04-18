const std = @import("std");

/// Minimal fixture plugin for the plugin-controllers E2E example.
///
/// Exposes a single module, `labelle_demo_plugin`, which the generated
/// build.zig references as `plugin_demo_plugin_dep.module("labelle_demo_plugin")`.
/// Module name must exactly match `labelle_<plugin_name>` (see the
/// assembler's build_files.zig `plugin_{s}_mod` line).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("labelle_demo_plugin", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}
