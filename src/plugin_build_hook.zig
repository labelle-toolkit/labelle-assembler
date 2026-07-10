//! Plugin native build-hook support (labelle-assembler#518).
//!
//! The assembler wires plugins as **Zig modules only** — `b.dependency` +
//! `plugin_<name>_dep.module("labelle_<name>")`. That is enough for a
//! pure-Zig plugin, but a plugin that must compile **native (C/C++) sources**
//! into the game (e.g. `labelle-spine`, which links the user's spine-c /
//! spine-cpp) has no seam: the generated `build.zig` never calls the plugin's
//! `addCSourceFiles` / `linkLibCpp` / include-path helper.
//!
//! This module adds the missing seam, mirroring the existing **backend**
//! hook (`backend.hook.zig` / `stageBackendBuildHook`, `manifest_v2_splice`):
//!
//!   1. **Convention.** A plugin ships a `plugin.hook.zig` file at its
//!      package root exporting
//!      `pub fn postWire(b: *std.Build, ctx: anytype) void`.
//!   2. **Discovery.** At `generate` time we probe each declared plugin's
//!      resolved directory for that file (`discover`).
//!   3. **Staging.** Each hook found is copied next to the generated
//!      `build.zig` under `plugin_<name>_build_hook.zig` (`stage`), so the
//!      generated `@import("plugin_<name>_build_hook.zig")` resolves in the
//!      real output dir — exactly how `backend_build_hook.zig` is staged.
//!   4. **Call.** `build_files.emitPluginBuildHooks` emits the
//!      `@import` + `postWire(b, .{ … })` CALL after the game artifact is
//!      assembled, passing the artifact (`*std.Build.Step.Compile`), the
//!      plugin's module + dep, and `target`/`optimize`, so the hook can
//!      contribute native sources / link steps / include paths.
//!
//! **Additive.** A plugin with no `plugin.hook.zig` is never discovered, so
//! its wiring — and the generated `build.zig` of any project using it — is
//! byte-identical to before. The hook file, like `backend.hook.zig`, must
//! make no package-local import assumptions: it takes everything it needs
//! from `b` and the `ctx` struct (which carries `.plugin_dep` for
//! `b.dependency`-style path/module access).

const std = @import("std");
const config = @import("config.zig");
const cache = @import("cache.zig");

const ProjectConfig = config.ProjectConfig;

/// The convention filename a plugin ships at its package root to contribute a
/// native build step. Mirrors the backend `build_hook` convention.
pub const HOOK_FILENAME = "plugin.hook.zig";

/// A plugin found to ship a `plugin.hook.zig`.
pub const Discovered = struct {
    /// The plugin's `project.labelle` name. Borrowed from `cfg.plugins[i].name`
    /// — NOT owned, do not free.
    plugin_name: []const u8,
    /// Absolute source path of the plugin's hook file. Owned; released by
    /// `freeDiscovered`.
    src_path: []const u8,
};

/// The sibling import-file name the staged hook is written under, next to the
/// generated `build.zig`. MUST agree with the identifier
/// `build_files.emitPluginBuildHooks` emits (`plugin_<name>_build_hook.zig`).
/// Caller owns the returned slice.
pub fn stagedName(allocator: std.mem.Allocator, plugin_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "plugin_{s}_build_hook.zig", .{plugin_name});
}

/// Probe every declared plugin's resolved directory for a `plugin.hook.zig`.
/// Returns the list of plugins that ship one (empty when none do — the common
/// case, keeping the generated build byte-identical). A plugin whose directory
/// cannot be resolved is silently skipped: a missing/miswired plugin is a
/// pre-existing hard error elsewhere in the pipeline; the hook probe must not
/// be the thing that surfaces it.
pub fn discover(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    project_dir: []const u8,
) !std.ArrayList(Discovered) {
    var list: std.ArrayList(Discovered) = .empty;
    errdefer freeDiscovered(allocator, &list);

    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    for (cfg.plugins) |plugin| {
        const plugin_dir = cache.resolvePlugin(allocator, plugin, project_dir) catch continue;
        defer allocator.free(plugin_dir);

        const hook_path = try std.fs.path.join(allocator, &.{ plugin_dir, HOOK_FILENAME });
        errdefer allocator.free(hook_path);

        cwd.access(io, hook_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(hook_path);
                continue;
            },
            else => return err,
        };

        try list.append(allocator, .{ .plugin_name = plugin.name, .src_path = hook_path });
    }

    return list;
}

/// Release the owned `src_path` of every entry and the backing storage.
pub fn freeDiscovered(allocator: std.mem.Allocator, list: *std.ArrayList(Discovered)) void {
    for (list.items) |d| allocator.free(d.src_path);
    list.deinit(allocator);
}

/// Stage (copy) each discovered plugin hook next to the generated `build.zig`
/// under `plugin_<name>_build_hook.zig`, so the generated
/// `@import("plugin_<name>_build_hook.zig")` resolves at build time. Mirrors
/// `manifest_v2_splice.stageBackendBuildHook`. No-op when `discovered` is empty.
pub fn stage(
    allocator: std.mem.Allocator,
    discovered: []const Discovered,
    target_dir: []const u8,
) !void {
    if (discovered.len == 0) return;

    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    var dir = try cwd.openDir(io, target_dir, .{});
    defer dir.close(io);

    for (discovered) |d| {
        const content = try cwd.readFileAlloc(io, d.src_path, allocator, .limited(1024 * 1024));
        defer allocator.free(content);

        const dest_name = try stagedName(allocator, d.plugin_name);
        defer allocator.free(dest_name);

        const file = try dir.createFile(io, dest_name, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, content);
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "stagedName: derives the sibling import name from the plugin name" {
    const name = try stagedName(testing.allocator, "spine");
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("plugin_spine_build_hook.zig", name);
}

test "discover: returns empty for a project with no plugins" {
    const cfg = ProjectConfig{ .name = "empty" };
    var list = try discover(testing.allocator, cfg, ".");
    defer freeDiscovered(testing.allocator, &list);
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

test "discover: finds a local plugin that ships plugin.hook.zig, skips one that doesn't" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = testing.io;
    // Two local plugins under the project root: `withhook/` ships the file,
    // `nohook/` does not.
    try tmp.dir.createDirPath(io, "withhook");
    try tmp.dir.createDirPath(io, "nohook");
    {
        var f = try tmp.dir.createFile(io, "withhook/plugin.hook.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "pub fn postWire(_: anytype, _: anytype) void {}\n");
    }

    const project_dir = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(project_dir);

    const cfg = ProjectConfig{
        .name = "t",
        .plugins = &.{
            .{ .name = "withhook", .repo = "@withhook" },
            .{ .name = "nohook", .repo = "@nohook" },
        },
    };

    var list = try discover(testing.allocator, cfg, project_dir);
    defer freeDiscovered(testing.allocator, &list);

    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings("withhook", list.items[0].plugin_name);
}

test "stage: copies each discovered hook next to the generated build.zig" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = testing.io;
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.createDirPath(io, "out");
    {
        var f = try tmp.dir.createFile(io, "src/plugin.hook.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "// hook body\n");
    }

    const src_path = try tmp.dir.realPathFileAlloc(io, "src/plugin.hook.zig", testing.allocator);
    defer testing.allocator.free(src_path);
    const out_dir = try tmp.dir.realPathFileAlloc(io, "out", testing.allocator);
    defer testing.allocator.free(out_dir);

    const discovered = [_]Discovered{.{ .plugin_name = "spine", .src_path = src_path }};
    try stage(testing.allocator, &discovered, out_dir);

    const staged = try tmp.dir.readFileAlloc(io, "out/plugin_spine_build_hook.zig", testing.allocator, .limited(4096));
    defer testing.allocator.free(staged);
    try testing.expectEqualStrings("// hook body\n", staged);
}
