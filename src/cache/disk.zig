/// Cache disk-layout operations: populate cache slots from local source
/// directories, copy / symlink trees, patch sibling-style path deps in
/// build.zig.zon files after the cache is populated.
///
/// This is the side of the cache that *writes* to disk (or symlinks /
/// copies into it). The pure path-math is in `resolve.zig`; the network
/// side (git clones) is in `fetch.zig`.
const std = @import("std");
const config = @import("../config.zig");
const env = @import("env.zig");
const resolve = @import("resolve.zig");

/// Populate the assembler cache from the assembler source directory.
/// `companion_dir` points at the labelle-assembler repo root (for dev) or
/// an install-time bundled directory. Symlinks `backends/` into
/// ~/.labelle/packages/assembler/{version}/. Missing subdirectories are
/// skipped silently so the same function works through the staged migration
/// as more subdirs (ecs, gui) move over.
pub fn populateAssemblerCache(allocator: std.mem.Allocator, assembler_version: []const u8, companion_dir: []const u8) !void {
    const packages_dir = try env.getPackagesDir(allocator);
    defer allocator.free(packages_dir);

    const target = try std.fs.path.join(allocator, &.{ packages_dir, "assembler", assembler_version });
    defer allocator.free(target);

    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    cwd.createDirPath(io, target) catch |err| {
        std.log.err("labelle: could not create cache directory '{s}': {any}", .{ target, err });
        return error.CachePopulationFailed;
    };

    const subdirs = [_][]const u8{ "backends", "ecs", "gui" };
    for (subdirs) |subdir| {
        const src_path = try std.fs.path.join(allocator, &.{ companion_dir, subdir });
        defer allocator.free(src_path);

        if (!dirExists(src_path)) continue;

        const dst_path = try std.fs.path.join(allocator, &.{ target, subdir });
        defer allocator.free(dst_path);

        symlinkToCache(allocator, src_path, dst_path) catch |err| {
            std.log.err("labelle: could not link '{s}' to cache: {any}", .{ src_path, err });
            return error.CachePopulationFailed;
        };
    }
}

/// Populate a framework package (core, engine, gfx) into the cache from a source directory.
/// Creates a symlink from the cache location to the source directory.
pub fn populateFrameworkPackage(allocator: std.mem.Allocator, package: []const u8, version: []const u8, source_dir: []const u8) !void {
    const target = try resolve.resolveFrameworkPackage(allocator, package, version, null);
    defer allocator.free(target);
    try symlinkToCache(allocator, source_dir, target);
}

/// Populate a plugin into the cache from a source directory.
/// Creates a symlink from the cache location to the source directory.
pub fn populatePlugin(allocator: std.mem.Allocator, plugin: config.PluginDep, source_dir: []const u8) !void {
    const target = try resolve.resolvePlugin(allocator, plugin, null);
    defer allocator.free(target);
    try symlinkToCache(allocator, source_dir, target);
}

/// Create a symlink from cache target to source directory.
/// The source_dir must be an absolute path (resolved via realpath).
/// Creates parent directories as needed.
pub fn symlinkToCache(allocator: std.mem.Allocator, source_dir: []const u8, target: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    // Resolve source to absolute path. Dupe to plain []u8 so the free
    // doesn't trip on realPathFileAlloc's sentinel byte.
    const abs_source_z = cwd.realPathFileAlloc(io, source_dir, allocator) catch |err| {
        std.log.err("labelle: source directory not found '{s}': {any}", .{ source_dir, err });
        return error.CachePopulationFailed;
    };
    defer allocator.free(abs_source_z);
    const abs_source = try allocator.dupe(u8, abs_source_z);
    defer allocator.free(abs_source);

    // Ensure parent directory exists
    if (std.fs.path.dirname(target)) |parent| {
        cwd.createDirPath(io, parent) catch |err| {
            std.log.err("labelle: could not create cache directory '{s}': {any}", .{ parent, err });
            return error.CachePopulationFailed;
        };
    }

    // Create symlink (absolute target → source), fall back to copy on failure
    // (Windows requires admin/Developer Mode for symlinks)
    cwd.symLink(io, abs_source, target, .{ .is_directory = true }) catch |err| {
        if (err == error.PathAlreadyExists) {
            // Verify the existing entry points to the expected source
            var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const existing_len = std.Io.Dir.readLinkAbsolute(io, target, &link_buf) catch return; // not a symlink, assume OK
            const existing = link_buf[0..existing_len];
            if (!std.mem.eql(u8, existing, abs_source)) {
                std.log.warn("labelle: cache entry '{s}' points to '{s}', expected '{s}'", .{ target, existing, abs_source });
                // Remove stale link and recreate
                cwd.deleteFile(io, target) catch return;
                cwd.symLink(io, abs_source, target, .{ .is_directory = true }) catch return;
            }
            return;
        }
        // Fall back to copying the directory
        copyDirRecursive(allocator, abs_source, target) catch |copy_err| {
            std.log.err("labelle: could not link or copy '{s}' to '{s}': {any}", .{ abs_source, target, copy_err });
            return error.CachePopulationFailed;
        };
    };
}

/// Whether `path` exists and is accessible. Public so the cache
/// subcommand handlers (cache_cmd.zig) can probe monorepo source dirs
/// before deciding between a local symlink and a remote clone.
pub fn dirExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(config.globalIo(), path, .{}) catch return false;
    return true;
}

/// Check if a path is a symlink.
pub fn isSymlink(path: []const u8) bool {
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = std.Io.Dir.readLinkAbsolute(config.globalIo(), path, &link_buf) catch return false;
    return true;
}

/// Recursively copy a directory tree.
pub fn copyDirRecursive(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dst) catch {};

    var src_dir = try cwd.openDir(io, src, .{ .iterate = true });
    defer src_dir.close(io);

    var iter = src_dir.iterate();
    while (try iter.next(io)) |entry| {
        const src_sub = try std.fs.path.join(allocator, &.{ src, entry.name });
        defer allocator.free(src_sub);
        const dst_sub = try std.fs.path.join(allocator, &.{ dst, entry.name });
        defer allocator.free(dst_sub);

        switch (entry.kind) {
            .directory => try copyDirRecursive(allocator, src_sub, dst_sub),
            .file => {
                cwd.copyFile(src_sub, cwd, dst_sub, io, .{}) catch |err| {
                    std.log.warn("labelle: could not copy '{s}': {any}", .{ src_sub, err });
                    return err;
                };
            },
            else => {},
        }
    }
}

/// Patch build.zig.zon files in cached packages to rewrite sibling path deps
/// (e.g. `../labelle-core`) to point to other cached packages.
/// Must be called after all framework packages are cached.
pub fn patchCachedDeps(allocator: std.mem.Allocator, cfg: config.ProjectConfig) !void {
    // Only patch non-local packages
    const packages = [_]struct { name: []const u8, version: []const u8 }{
        .{ .name = "engine", .version = cfg.engine_version },
        .{ .name = "gfx", .version = cfg.gfx_version },
    };

    for (packages) |pkg| {
        if (config.isLocalVersion(pkg.version)) continue;

        const pkg_dir = try resolve.resolveFrameworkPackage(allocator, pkg.name, pkg.version, null);
        defer allocator.free(pkg_dir);

        // Never patch symlinked packages — they point to local repos that must not be mutated.
        if (isSymlink(pkg_dir)) continue;

        // Patch the main build.zig.zon (root: core is sibling → "../labelle-core")
        try patchZonFile(allocator, pkg_dir, "build.zig.zon", false);

        // Patch subpackage build.zig.zon files (scene/, camera/, etc.)
        // Subpackages are one level deeper → "../../labelle-core"
        const io = config.globalIo();
        var dir = std.Io.Dir.cwd().openDir(io, pkg_dir, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            const sub_zon = try std.fs.path.join(allocator, &.{ pkg_dir, entry.name, "build.zig.zon" });
            defer allocator.free(sub_zon);
            if (std.Io.Dir.cwd().access(io, sub_zon, .{})) |_| {
                const sub_dir = try std.fs.path.join(allocator, &.{ pkg_dir, entry.name });
                defer allocator.free(sub_dir);
                try patchZonFile(allocator, sub_dir, "build.zig.zon", true);
            } else |_| {}
        }
    }
}

/// Patch a single build.zig.zon file in the global cache, rewriting
/// labelle-core path deps to work after deps_linker hardlinks the package
/// into .labelle/deps/ alongside core. In the deps layout, packages are
/// siblings, so core is at "../labelle-core" from a root package or
/// "../../labelle-core" from a subpackage (scene/, camera/).
fn patchZonFile(allocator: std.mem.Allocator, dir_path: []const u8, filename: []const u8, is_subpackage: bool) !void {
    const file_path = try std.fs.path.join(allocator, &.{ dir_path, filename });
    defer allocator.free(file_path);

    const io = config.globalIo();
    const content = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(256 * 1024)) catch return;
    defer allocator.free(content);

    // After deps_linker, all packages are siblings under .labelle/deps/.
    // Root build.zig.zon: core is at "../labelle-core"
    // Subpackage build.zig.zon (scene/, camera/): core is at "../../labelle-core"
    const target = if (is_subpackage) "../../labelle-core" else "../labelle-core";

    // Normalize all core path variants to the correct target for this depth.
    // Use a placeholder to avoid "../labelle-core" matching inside "../../labelle-core".
    var result = try allocator.dupe(u8, content);
    const step1 = try replaceAll(allocator, result, "../../labelle-core", "\x00CORE_REF\x00");
    allocator.free(result);
    const step2 = try replaceAll(allocator, step1, "../labelle-core", "\x00CORE_REF\x00");
    allocator.free(step1);
    const step3 = try replaceAll(allocator, step2, "\x00CORE_REF\x00", target);
    allocator.free(step2);
    result = step3;

    // Only write if changed
    if (!std.mem.eql(u8, content, result)) {
        const file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, result);
    }
    allocator.free(result);
}

/// Simple string replace-all helper.
fn replaceAll(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < haystack.len) {
        if (i + needle.len <= haystack.len and std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
            try list.appendSlice(allocator, replacement);
            i += needle.len;
        } else {
            try list.append(allocator, haystack[i]);
            i += 1;
        }
    }
    return list.toOwnedSlice(allocator);
}
