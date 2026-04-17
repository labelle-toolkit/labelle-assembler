/// File scanning and directory copy utilities for the labelle-cli generator.
const std = @import("std");

pub fn freeNames(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

/// Copy files from src_base/folder to dst_base/folder (recursively) and return
/// sorted file stems matching the given extension. Subfolder paths are preserved
/// in the returned names (e.g., "enemies/goblin" for prefabs/enemies/goblin.zon).
pub fn copyAndScan(allocator: std.mem.Allocator, src_base: []const u8, dst_base: []const u8, folder: []const u8, ext: []const u8) ![][]const u8 {
    const cwd = std.fs.cwd();

    const src_path = try std.fs.path.join(allocator, &.{ src_base, folder });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ dst_base, folder });
    defer allocator.free(dst_path);

    try cwd.makePath(dst_path);

    var names: std.ArrayList([]const u8) = .{};
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    try copyAndScanRecursive(allocator, cwd, src_path, dst_path, "", ext, &names);

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return names.toOwnedSlice(allocator);
}

/// Recursive helper for copyAndScan. `prefix` is the relative path from the
/// folder root (empty string for the top level, "enemies" for a subfolder, etc.).
fn copyAndScanRecursive(
    allocator: std.mem.Allocator,
    cwd: std.fs.Dir,
    src_path: []const u8,
    dst_path: []const u8,
    prefix: []const u8,
    ext: []const u8,
    names: *std.ArrayList([]const u8),
) !void {
    var src_dir = cwd.openDir(src_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer src_dir.close();

    try cwd.makePath(dst_path);
    var dst_dir = try cwd.openDir(dst_path, .{});
    defer dst_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.eql(u8, entry.name, ".bridge.zig")) continue;

        switch (entry.kind) {
            .file => {
                // Copy file
                const content = try src_dir.readFileAlloc(allocator, entry.name, 1024 * 1024);
                defer allocator.free(content);
                const out_file = try dst_dir.createFile(entry.name, .{});
                defer out_file.close();
                try out_file.writeAll(content);

                // Collect stem if extension matches
                if (std.mem.endsWith(u8, entry.name, ext)) {
                    const base_stem = entry.name[0 .. entry.name.len - ext.len];
                    const stem = if (prefix.len > 0)
                        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, base_stem })
                    else
                        try allocator.dupe(u8, base_stem);
                    try names.append(allocator, stem);
                }
            },
            .directory => {
                const sub_src = try std.fs.path.join(allocator, &.{ src_path, entry.name });
                defer allocator.free(sub_src);
                const sub_dst = try std.fs.path.join(allocator, &.{ dst_path, entry.name });
                defer allocator.free(sub_dst);
                const sub_prefix = if (prefix.len > 0)
                    try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
                else
                    try allocator.dupe(u8, entry.name);
                defer allocator.free(sub_prefix);
                try copyAndScanRecursive(allocator, cwd, sub_src, sub_dst, sub_prefix, ext, names);
            },
            else => {},
        }
    }
}

pub fn writeFile(dir_path: []const u8, filename: []const u8, content: []const u8) !void {
    const cwd = std.fs.cwd();
    var dir = try cwd.openDir(dir_path, .{});
    defer dir.close();
    const file = try dir.createFile(filename, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Copy a subdirectory from src_base/folder to dst_base/folder.
/// Copies all files (non-recursive, skips directories and .bridge.zig).
pub fn copyDir(allocator: std.mem.Allocator, src_base: []const u8, dst_base: []const u8, folder: []const u8) !void {
    const cwd = std.fs.cwd();

    const src_path = try std.fs.path.join(allocator, &.{ src_base, folder });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ dst_base, folder });
    defer allocator.free(dst_path);

    try cwd.makePath(dst_path);

    var src_dir = cwd.openDir(src_path, .{ .iterate = true }) catch return; // skip if doesn't exist
    defer src_dir.close();
    var dst_dir = try cwd.openDir(dst_path, .{});
    defer dst_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, ".bridge.zig")) continue; // skip old bridge files

        const content = try src_dir.readFileAlloc(allocator, entry.name, 1024 * 1024);
        defer allocator.free(content);

        const out_file = try dst_dir.createFile(entry.name, .{});
        defer out_file.close();
        try out_file.writeAll(content);
    }
}

/// Create a relative directory symlink at `dst_base/folder` pointing at
/// `src_base/folder`. Idempotent across re-runs:
///   - missing source → silently skipped (matches `copyDirRecursive`);
///   - link already points at the right target → no-op;
///   - link points elsewhere → replaced;
///   - real directory (legacy copy-based layout) → removed + replaced.
///
/// Relative link text is computed from `dst_base/folder`'s parent to
/// `src_base/folder`, so the link survives a project move as long as
/// the project's internal layout is intact.
pub fn linkDir(
    allocator: std.mem.Allocator,
    src_base: []const u8,
    dst_base: []const u8,
    folder: []const u8,
) !void {
    const cwd = std.fs.cwd();

    const src_path = try std.fs.path.join(allocator, &.{ src_base, folder });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ dst_base, folder });
    defer allocator.free(dst_path);

    // Skip silently if source doesn't exist — matches copyDirRecursive.
    cwd.access(src_path, .{}) catch return;

    // Ensure the symlink's immediate parent exists. Using dst_parent
    // (not dst_base) handles plugin-declared nested `folder` values
    // like "foo/bar" correctly — makePath(dst_base) alone would fail
    // on symLink() because `dst_base/foo` wouldn't exist.
    const dst_parent = std.fs.path.dirname(dst_path) orelse ".";
    try cwd.makePath(dst_parent);

    // Compute the relative target from the parent of the link to the
    // source. Using a relative link lets the project directory be moved
    // without breaking (absolute paths would snap on relocation).
    const relative_target = try std.fs.path.relative(allocator, dst_parent, src_path);
    defer allocator.free(relative_target);

    // Inspect whatever is at dst_path. `deleteTree` handles every
    // case uniformly — it removes file symlinks, directory symlinks
    // (on Windows where deleteFile can't), and real directories left
    // over from older copy-based generates. Safe because `dst_base`
    // is the CLI's managed target directory (`.labelle/<target>/`).
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (cwd.readLink(dst_path, &link_buf)) |existing| {
        if (std.mem.eql(u8, existing, relative_target)) return;
        try cwd.deleteTree(dst_path);
    } else |err| switch (err) {
        error.FileNotFound => {},
        error.NotLink => try cwd.deleteTree(dst_path),
        else => return err,
    }

    try cwd.symLink(relative_target, dst_path, .{ .is_directory = true });
}

/// Scan `src_base/folder` recursively for file stems matching `ext` and
/// create a directory symlink at `dst_base/folder` (via `linkDir`) so
/// downstream code that reads from the target tree resolves through the
/// link back to the source. Returns sorted stems; subfolder paths are
/// preserved (e.g., "enemies/goblin" for prefabs/enemies/goblin.zon).
///
/// Replaces the old `copyAndScan` for game-owned directories — the
/// scan walks the *source*, not the link, so nested content is picked
/// up regardless of symlink-follow behavior in the iterator.
pub fn linkAndScan(
    allocator: std.mem.Allocator,
    src_base: []const u8,
    dst_base: []const u8,
    folder: []const u8,
    ext: []const u8,
) ![][]const u8 {
    try linkDir(allocator, src_base, dst_base, folder);

    const cwd = std.fs.cwd();
    const src_path = try std.fs.path.join(allocator, &.{ src_base, folder });
    defer allocator.free(src_path);

    var names: std.ArrayList([]const u8) = .{};
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    try scanRecursive(allocator, cwd, src_path, "", ext, &names);

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return names.toOwnedSlice(allocator);
}

fn scanRecursive(
    allocator: std.mem.Allocator,
    cwd: std.fs.Dir,
    src_path: []const u8,
    prefix: []const u8,
    ext: []const u8,
    names: *std.ArrayList([]const u8),
) !void {
    var src_dir = cwd.openDir(src_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer src_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.eql(u8, entry.name, ".bridge.zig")) continue;

        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, ext)) {
                    const base_stem = entry.name[0 .. entry.name.len - ext.len];
                    const stem = if (prefix.len > 0)
                        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, base_stem })
                    else
                        try allocator.dupe(u8, base_stem);
                    // If `append` fails between the stem allocation
                    // and the list taking ownership, free it here
                    // so the outer errdefer (which only walks the
                    // list) doesn't miss it.
                    errdefer allocator.free(stem);
                    try names.append(allocator, stem);
                }
            },
            .directory => {
                const sub_src = try std.fs.path.join(allocator, &.{ src_path, entry.name });
                defer allocator.free(sub_src);
                const sub_prefix = if (prefix.len > 0)
                    try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
                else
                    try allocator.dupe(u8, entry.name);
                defer allocator.free(sub_prefix);
                try scanRecursive(allocator, cwd, sub_src, sub_prefix, ext, names);
            },
            else => {},
        }
    }
}

/// Recursively copy a directory tree from src_base/folder to dst_base/folder.
/// Copies all files and subdirectories. Used for assets which have nested folders.
pub fn copyDirRecursive(allocator: std.mem.Allocator, src_base: []const u8, dst_base: []const u8, folder: []const u8) !void {
    const cwd = std.fs.cwd();

    const src_path = try std.fs.path.join(allocator, &.{ src_base, folder });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ dst_base, folder });
    defer allocator.free(dst_path);

    try cwd.makePath(dst_path);

    var src_dir = cwd.openDir(src_path, .{ .iterate = true }) catch return;
    defer src_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const content = try src_dir.readFileAlloc(allocator, entry.name, 10 * 1024 * 1024);
                defer allocator.free(content);

                var dst_dir = try cwd.openDir(dst_path, .{});
                defer dst_dir.close();
                const out_file = try dst_dir.createFile(entry.name, .{});
                defer out_file.close();
                try out_file.writeAll(content);
            },
            .directory => {
                const sub_folder = try std.fs.path.join(allocator, &.{ folder, entry.name });
                defer allocator.free(sub_folder);
                try copyDirRecursive(allocator, src_base, dst_base, sub_folder);
            },
            else => {},
        }
    }
}
