const std = @import("std");

/// Build script for the `fantasy-dungeon` reference asset plugin.
///
/// The plugin's content (packs, atlases, prefabs, generator script) is all
/// declarative — copied and dir-scanned by the assembler, needing no compiled
/// code. This module exists only so the plugin is a well-formed Zig package the
/// generated game `build.zig` can reference as
/// `plugin_fantasy_dungeon_dep.module("labelle_fantasy_dungeon")` (module name
/// must be exactly `labelle_<plugin_name>` — see the assembler's
/// build_files.zig `plugin_{s}_mod` line). `src/root.zig` is intentionally
/// empty of plugin machinery.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("labelle_fantasy_dungeon", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}
