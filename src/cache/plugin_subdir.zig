//! `.subdir` on a plugin pin (#771): a plugin that lives in a directory of a
//! monorepo instead of at the root of a repo of its own.
//!
//! The fetch layer downloads `<repo>/archive/<ref>.tar.gz` and extracts the
//! repo ROOT into `packages/plugins/<repo>/<version>`; there is no way to
//! download "one directory at a tag". So the archive is cached whole, keyed
//! exactly as before, and `.subdir` only moves the plugin ROOT inside it:
//!
//!   packages/plugins/github.com/labelle-toolkit/labelle-assembler/0.118.0/
//!       plugins/debug/        ← resolvePlugin for `.subdir = "plugins/debug"`
//!       plugins/imgui/        ← a second plugin from the same archive
//!
//! Two plugins from one repo at one version therefore share one download.
//!
//! The subdir is joined into a cache path, so it has to be a plain relative
//! path that stays inside the archive: no absolute path, no drive letter, no
//! `.`/`..` component, no empty component. And it is for REMOTE pins only —
//! a `local:`/`@` repo already names the plugin directory itself, so a subdir
//! there would make one entry mean two different directories depending on
//! who reads it.
const std = @import("std");
const config = @import("../config.zig");
const path_key = @import("path_key.zig");

pub const Error = error{InvalidPluginSubdir};

/// Why a subdir is rejected, or null when it is acceptable. Pure; the caller
/// decides whether to log.
pub fn problem(plugin: config.PluginDep) ?[]const u8 {
    const sub = plugin.subdir;
    if (sub.len == 0) return null;
    if (plugin.isLocal())
        return "'.subdir' only applies to a remote '.repo' — a 'local:'/'@' repo already names the plugin directory, so point it there instead";
    // Forward slashes only, whatever the host: the pin is committed, and on
    // POSIX `path.join` keeps a `\` as part of one directory NAME, so a
    // `plugins\debug` written on Windows would miss on Linux (Codex review).
    if (std.mem.indexOfScalar(u8, sub, '\\') != null) return "'.subdir' must use '/' as its separator";
    if (sub[0] == '/') return "'.subdir' must be relative to the repo root, not absolute";
    // Judged by Windows' rules on EVERY host (#782's `path_key`), for the same
    // reason; this also rejects a drive letter (`C:`).
    if (path_key.firstBadByte(sub, .windows) != null)
        return "'.subdir' contains a character a Windows path cannot hold (<>:\"|?* or a control byte)";
    var parts = std.mem.splitScalar(u8, sub, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return "'.subdir' has an empty path component";
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
            return "'.subdir' may not contain '.' or '..' components — it must stay inside the repo";
    }
    return null;
}

/// `problem`, logged once with the plugin named. For the entry points that
/// run once per command (install / ensureCache); `resolvePlugin` runs many
/// times per generate and only returns the error.
pub fn validate(plugin: config.PluginDep) Error!void {
    if (problem(plugin)) |why| {
        std.log.err("labelle: plugin '{s}': {s} (got '.subdir = \"{s}\"')", .{ plugin.name, why, plugin.subdir });
        return error.InvalidPluginSubdir;
    }
}

/// The plugin root inside an extracted archive at `archive_root`: the
/// archive root itself when there is no subdir. Caller owns the result.
pub fn pluginRoot(allocator: std.mem.Allocator, archive_root: []const u8, plugin: config.PluginDep) ![]const u8 {
    if (problem(plugin) != null) return error.InvalidPluginSubdir;
    if (plugin.subdir.len == 0) return allocator.dupe(u8, archive_root);
    return std.fs.path.join(allocator, &.{ archive_root, plugin.subdir });
}

// ── Tests ────────────────────────────────────────────────────────────

test "plugin_subdir: an empty subdir is the archive root, byte-identical to before #771" {
    const alloc = std.testing.allocator;
    const p: config.PluginDep = .{ .name = "fsm", .repo = "github.com/acme/fsm", .version = "1.0.0" };
    try std.testing.expect(problem(p) == null);
    const root = try pluginRoot(alloc, "/cache/plugins/github.com/acme/fsm/1.0.0", p);
    defer alloc.free(root);
    try std.testing.expectEqualStrings("/cache/plugins/github.com/acme/fsm/1.0.0", root);
}

test "plugin_subdir: a nested subdir is joined under the archive root" {
    const alloc = std.testing.allocator;
    const p: config.PluginDep = .{
        .name = "debug",
        .repo = "github.com/labelle-toolkit/labelle-assembler",
        .version = "0.118.0",
        .subdir = "plugins/debug",
    };
    try std.testing.expect(problem(p) == null);
    const root = try pluginRoot(alloc, "archive", p);
    defer alloc.free(root);
    const expected = try std.fs.path.join(alloc, &.{ "archive", "plugins/debug" });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, root);
}

test "plugin_subdir: traversal, absolute paths and local repos are rejected" {
    const alloc = std.testing.allocator;
    const bad = [_][]const u8{ "plugins/a:b", "plugins/de?bug", "../x", "plugins/../../x", "/abs", "\\abs", "C:\\x", "plugins//debug", "./plugins", "plugins/.", "plugins/debug/", "plugins\\debug" };
    for (bad) |sub| {
        const p: config.PluginDep = .{ .name = "d", .repo = "github.com/acme/mono", .version = "1.0.0", .subdir = sub };
        try std.testing.expect(problem(p) != null);
        try std.testing.expectError(error.InvalidPluginSubdir, pluginRoot(alloc, "archive", p));
    }
    const local_pin: config.PluginDep = .{ .name = "d", .repo = "local:../mono", .subdir = "plugins/debug" };
    try std.testing.expect(problem(local_pin) != null);
    const at_pin: config.PluginDep = .{ .name = "d", .repo = "@libs/mono", .subdir = "plugins/debug" };
    try std.testing.expect(problem(at_pin) != null);
}

test "plugin_subdir: the #685 purge keeps a monorepo archive whose root zon versions the monorepo" {
    const alloc = std.testing.allocator;
    const env = @import("env.zig");
    const disk = @import("disk.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The assembler's own v0.118.0 archive declared `.version = "0.107.0"`.
    const rel = "home/packages/plugins/github.com/acme/mono/0.118.0";
    try tmp.dir.createDirPath(std.testing.io, rel ++ "/plugins/debug");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = rel ++ "/build.zig.zon", .data = ".{ .version = \"0.107.0\" }\n" });
    const home_z = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home_z);
    env.setCacheRootForTesting(home_z);
    defer env.setCacheRootForTesting(null);

    const sub_pin: config.PluginDep = .{ .name = "debug", .repo = "github.com/acme/mono", .version = "0.118.0", .subdir = "plugins/debug" };
    const plugins = [_]config.PluginDep{sub_pin};
    try disk.purgeLegacyLocalSlots(alloc, .{ .name = "g", .plugins = &plugins });
    try tmp.dir.access(std.testing.io, rel ++ "/plugins/debug", .{});

    // Control: the same archive pinned WITHOUT a subdir is judged by its
    // root zon, and is dropped — the content rule is what the subdir skips.
    const root_pin: config.PluginDep = .{ .name = "mono", .repo = "github.com/acme/mono", .version = "0.118.0" };
    const root_plugins = [_]config.PluginDep{root_pin};
    try disk.purgeLegacyLocalSlots(alloc, .{ .name = "g", .plugins = &root_plugins });
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, rel, .{}));
}

test "plugin_subdir: a subdir naming a FILE in a cached archive is not a cache hit" {
    const alloc = std.testing.allocator;
    const env = @import("env.zig");
    const resolve = @import("resolve.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel = "home/packages/plugins/github.com/acme/mono/1.0.0";
    try tmp.dir.createDirPath(std.testing.io, rel ++ "/plugins/real");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = rel ++ "/plugins/file", .data = "not a dir" });
    const home_z = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home_z);
    env.setCacheRootForTesting(home_z);
    defer env.setCacheRootForTesting(null);

    const real: config.PluginDep = .{ .name = "real", .repo = "github.com/acme/mono", .version = "1.0.0", .subdir = "plugins/real" };
    try std.testing.expect(try resolve.isPluginCached(alloc, real));
    var file = real;
    file.name = "file";
    file.subdir = "plugins/file";
    try std.testing.expect(!try resolve.isPluginCached(alloc, file));
    var missing = real;
    missing.subdir = "plugins/nope";
    try std.testing.expect(!try resolve.isPluginCached(alloc, missing));
}
