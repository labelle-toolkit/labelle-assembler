/// File scanning and directory copy utilities for the labelle-cli generator.
const std = @import("std");
const config = @import("config.zig");
const junction = @import("junction.zig");

pub fn freeNames(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

/// Directory names that are never project source: generated output,
/// compiler/package caches, vendored dependency trees, and the git
/// metadata dir itself. Every recursive walk in this file prunes them.
const skip_dir_names = [_][]const u8{
    ".git",
    ".labelle",
    "zig-out",
    "zig-cache",
    ".zig-cache",
    "zig-pkg",
    "node_modules",
};

/// True when a directory entry named `name` inside `parent` must not be
/// descended into (labelle-assembler#692).
///
/// Two rules, and the second is the one that matters:
///
///  1. `name` is a known generated/cache/vendored dir (`skip_dir_names`).
///  2. `parent/name` is itself a REPOSITORY ROOT — it contains a `.git`
///     entry. Naming `.worktrees` specifically would not do: `git worktree
///     add` takes an arbitrary path, and a submodule or a plain nested
///     clone has exactly the same problem. Note the `.git` of a worktree
///     (and of a submodule) is a FILE holding a `gitdir:` pointer, not a
///     directory, so this deliberately tests for the entry's EXISTENCE and
///     not its kind.
///
/// Without rule 2 the scan walks every branch checked out beside the
/// working tree and pulls that branch's scripts/components/tests into the
/// build graph — duplicate compilation at best, code from an unrelated
/// branch at worst.
pub fn isSkippableDir(parent: std.Io.Dir, name: []const u8) bool {
    for (skip_dir_names) |skip| {
        if (std.mem.eql(u8, name, skip)) return true;
    }
    return isRepoRoot(parent, name);
}

/// Rule 2 of `isSkippableDir` on its own: is `parent/name` a repository
/// root (worktree, submodule or plain nested clone)?
///
/// Split out because the name-list half of `isSkippableDir` is specific
/// to the asset/source mirror, while this half must hold for EVERY walk
/// over project source. `script_scanner` needs exactly this rule and
/// none of `skip_dir_names`, so sharing the whole predicate would change
/// which directories it treats as state dirs.
pub fn isRepoRoot(parent: std.Io.Dir, name: []const u8) bool {
    const io = config.globalIo();
    var sub = parent.openDir(io, name, .{}) catch return false;
    defer sub.close(io);
    // EXISTENCE, not kind: a worktree's / submodule's `.git` is a file
    // holding a `gitdir:` pointer, not a directory.
    sub.access(io, ".git", .{}) catch return false;
    return true;
}

/// Mirror files from src_base/folder to dst_base/folder (recursively) and
/// return sorted file stems matching the given extension. Subfolder paths are
/// preserved in the returned names (e.g., "enemies/goblin" for
/// prefabs/enemies/goblin.zon).
///
/// This is a true mirror: destination entries that no longer have a matching
/// source are pruned, so deleting a source file does not leave a stale orphan
/// in the generated tree (issue #45). The destination must be a
/// generator-owned directory — see `copyAndScanRecursive` for the rationale.
pub fn copyAndScan(allocator: std.mem.Allocator, src_base: []const u8, dst_base: []const u8, folder: []const u8, ext: []const u8) ![][]const u8 {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const src_path = try std.fs.path.join(allocator, &.{ src_base, folder });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ dst_base, folder });
    defer allocator.free(dst_path);

    try cwd.createDirPath(io, dst_path);

    var names: std.ArrayList([]const u8) = .empty;
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
///
/// This is a true *mirror*: after copying every source entry it sweeps the
/// destination directory and removes anything that no longer has a matching
/// source entry. Without this sweep, deleting a source file would leave a
/// stale "orphan" copy behind — and because the generated `main.zig` builds
/// its comptime registry by walking the target tree, that orphan would keep
/// being compiled and run (see issue #45).
///
/// The sweep is safe because every caller of this helper points the
/// destination at a fully generator-owned directory (e.g.
/// `<target>/<plugin-dir>/` or `<target>/scripts/.plugin_<name>/`). The
/// generated target tree is exclusively managed by the assembler — no
/// hand-written files live there — so deleting non-source entries cannot
/// destroy user content.
fn copyAndScanRecursive(
    allocator: std.mem.Allocator,
    cwd: std.Io.Dir,
    src_path: []const u8,
    dst_path: []const u8,
    prefix: []const u8,
    ext: []const u8,
    names: *std.ArrayList([]const u8),
) !void {
    const io = config.globalIo();
    var src_dir = cwd.openDir(io, src_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer src_dir.close(io);

    try cwd.createDirPath(io, dst_path);
    var dst_dir = try cwd.openDir(io, dst_path, .{});
    defer dst_dir.close(io);

    // Track the names we copy/recurse into at this level so the orphan
    // sweep below can tell which destination entries are still backed by
    // a source. Owned strings are freed at function exit.
    var written: std.ArrayList([]const u8) = .empty;
    defer {
        for (written.items) |w| allocator.free(w);
        written.deinit(allocator);
    }

    var iter = src_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".bridge.zig")) continue;

        switch (entry.kind) {
            .file => {
                // Copy file
                const content = try src_dir.readFileAlloc(io, entry.name, allocator, .limited(1024 * 1024));
                defer allocator.free(content);
                const out_file = try dst_dir.createFile(io, entry.name, .{});
                defer out_file.close(io);
                try out_file.writeStreamingAll(io, content);

                try written.append(allocator, try allocator.dupe(u8, entry.name));

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
                // Nested repo roots / cache dirs are not project source
                // (#692). `continue` (not just "don't recurse") keeps the
                // name out of `written`, so the orphan sweep below also
                // removes any copy a previous generate left behind.
                if (isSkippableDir(src_dir, entry.name)) continue;

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

                try written.append(allocator, try allocator.dupe(u8, entry.name));
            },
            else => {},
        }
    }

    try pruneOrphans(allocator, cwd, dst_path, written.items);
}

/// Walk `dst_path` and delete any entry whose name is not in `keep`.
/// Used as the "sweep" half of the mark-and-sweep mirror in
/// `copyAndScanRecursive`. `.bridge.zig` is preserved — it's a legacy
/// artifact the copy pass deliberately never overwrites, so the sweep
/// must not treat it as an orphan either.
fn pruneOrphans(
    allocator: std.mem.Allocator,
    cwd: std.Io.Dir,
    dst_path: []const u8,
    keep: []const []const u8,
) !void {
    const io = config.globalIo();
    var dst_dir = cwd.openDir(io, dst_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dst_dir.close(io);

    // Collect orphan names first, then delete — mutating a directory
    // while iterating it is not guaranteed to be safe across platforms.
    var orphans: std.ArrayList([]const u8) = .empty;
    defer {
        for (orphans.items) |o| allocator.free(o);
        orphans.deinit(allocator);
    }

    var iter = dst_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".bridge.zig")) continue;
        var kept = false;
        for (keep) |k| {
            if (std.mem.eql(u8, k, entry.name)) {
                kept = true;
                break;
            }
        }
        if (!kept) try orphans.append(allocator, try allocator.dupe(u8, entry.name));
    }

    for (orphans.items) |name| {
        // `deleteTree` handles files, symlinks, and subdirectories
        // uniformly so a source directory turning into a file (or
        // vice versa) is also reconciled.
        try dst_dir.deleteTree(io, name);
    }
}

pub fn writeFile(dir_path: []const u8, filename: []const u8, content: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);
    const file = try dir.createFile(io, filename, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

/// Mirror files from `src_dir` to `dst_dir` (recursively) and return sorted
/// file stems matching the given extension. Like `copyAndScan` but takes
/// two fully-resolved absolute paths instead of a base+folder pair, so the
/// source and destination don't have to share a relative folder name.
///
/// As with `copyAndScan`, destination orphans (files whose source was
/// deleted) are pruned — see `copyAndScanRecursive` (issue #45).
///
/// Motivating use: plugin-shipped scripts at `<plugin>/scripts/**` need to
/// land at `<target>/scripts/.plugin_<name>/**`. Those two paths don't share
/// a last segment, so `copyAndScan(src_base, dst_base, "scripts", ".zig")`
/// can't express the shape. This helper splits the concerns cleanly.
pub fn copyAndScanAbs(allocator: std.mem.Allocator, src_dir: []const u8, dst_dir: []const u8, ext: []const u8) ![][]const u8 {
    const cwd = std.Io.Dir.cwd();

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    try copyAndScanRecursive(allocator, cwd, src_dir, dst_dir, "", ext, &names);

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return names.toOwnedSlice(allocator);
}

/// Copy a subdirectory from src_base/folder to dst_base/folder.
/// Copies all files (non-recursive, skips directories and .bridge.zig).
pub fn copyDir(allocator: std.mem.Allocator, src_base: []const u8, dst_base: []const u8, folder: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const src_path = try std.fs.path.join(allocator, &.{ src_base, folder });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ dst_base, folder });
    defer allocator.free(dst_path);

    try cwd.createDirPath(io, dst_path);

    var src_dir = cwd.openDir(io, src_path, .{ .iterate = true }) catch return; // skip if doesn't exist
    defer src_dir.close(io);
    var dst_dir = try cwd.openDir(io, dst_path, .{});
    defer dst_dir.close(io);

    var iter = src_dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, ".bridge.zig")) continue; // skip old bridge files

        const content = try src_dir.readFileAlloc(io, entry.name, allocator, .limited(1024 * 1024));
        defer allocator.free(content);

        const out_file = try dst_dir.createFile(io, entry.name, .{});
        defer out_file.close(io);
        try out_file.writeStreamingAll(io, content);
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
    const src_path = try std.fs.path.join(allocator, &.{ src_base, folder });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ dst_base, folder });
    defer allocator.free(dst_path);
    try linkDirAbs(allocator, src_path, dst_path);
}

/// `linkDir` over two fully-resolved paths (the `copyAndScanAbs`
/// precedent: source and destination need not share a last segment —
/// the native scripting splice links the game's `scripts/` at the staged
/// plugin package's `native/src/game`). Same semantics as the wrapper:
/// idempotent reconcile, relative link text, missing-source skip, and
/// the Windows copy fallback.
pub fn linkDirAbs(
    allocator: std.mem.Allocator,
    src_path: []const u8,
    dst_path: []const u8,
) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    // Skip silently if source doesn't exist — matches copyDirRecursive.
    cwd.access(io, src_path, .{}) catch return;

    // Ensure the symlink's immediate parent exists. Using dst_parent
    // (not the caller's base) handles nested destinations like
    // "foo/bar" correctly — makePath of the base alone would fail
    // on symLink() because the intermediate dirs wouldn't exist.
    const dst_parent = std.fs.path.dirname(dst_path) orelse ".";
    try cwd.createDirPath(io, dst_parent);

    // Compute the relative target from the parent of the link to the
    // source. Using a relative link lets the project directory be moved
    // without breaking (absolute paths would snap on relocation).
    const relative_target = try std.fs.path.relative(allocator, "", null, dst_parent, src_path);
    defer allocator.free(relative_target);

    // Inspect whatever is at dst_path. `deleteTree` handles every
    // case uniformly — it removes file symlinks, directory symlinks
    // (on Windows where deleteFile can't), and real directories left
    // over from older copy-based generates (or, for the native splice,
    // the plugin package's shipped placeholder dir). Safe because every
    // caller's destination is CLI-managed (`.labelle/<target>/`, the
    // staged deps tree).
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (cwd.readLink(io, dst_path, &link_buf)) |existing_len| {
        const existing = link_buf[0..existing_len];
        if (std.mem.eql(u8, existing, relative_target)) return;
        try cwd.deleteTree(io, dst_path);
    } else |err| switch (err) {
        error.FileNotFound => {},
        error.NotLink => try cwd.deleteTree(io, dst_path),
        else => return err,
    }

    cwd.symLink(io, relative_target, dst_path, .{ .is_directory = true }) catch |err| {
        if (err != error.AccessDenied and err != error.PermissionDenied) return err;

        // Windows without SeCreateSymbolicLinkPrivilege, which an ordinary
        // account does not hold (#710). A JUNCTION needs no privilege, and
        // unlike the copy below it is a live view — which is the entire
        // point of these links: `.labelle/<target>/scripts` exists so a
        // source edit reaches the staged tree without re-generating.
        //
        // The trade is deliberate. A junction stores an NT path and has no
        // relative form, so it does NOT survive moving the project the way
        // the relative symlink above does. That is the lesser loss:
        //
        //   * a copy does not track edits at all, so it defeats the link's
        //     primary purpose on every build, not just after a move; and
        //   * a moved project breaks the junction LOUDLY — an unresolvable
        //     path — and the next `generate` recreates it, whereas a stale
        //     copy silently serves yesterday's source.
        //
        // POSIX, and Windows with Developer Mode, never reach this: they
        // keep the relative symlink. The copy remains as the last resort
        // for anything that can express neither.
        junction.create(allocator, src_path, dst_path) catch {
            try copyDirRecursiveAbs(allocator, src_path, dst_path);
        };
    };
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

    const cwd = std.Io.Dir.cwd();
    const src_path = try std.fs.path.join(allocator, &.{ src_base, folder });
    defer allocator.free(src_path);

    var names: std.ArrayList([]const u8) = .empty;
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

/// Scan a fully-resolved directory (recursively, NO link/copy) for file
/// stems matching `ext` — sorted, subfolder paths `/`-joined, the exact
/// `linkAndScan` stem contract. A missing dir scans empty. Motivating
/// use: the typescript transpile phase re-scans the target's
/// MATERIALIZED script dir (copied `.js` + tsc-emitted `.js`) after the
/// link was already placed and replaced — there is nothing left to link.
pub fn scanDirAbs(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    ext: []const u8,
) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    try scanRecursive(allocator, std.Io.Dir.cwd(), dir_path, "", ext, &names);

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return names.toOwnedSlice(allocator);
}

fn scanRecursive(
    allocator: std.mem.Allocator,
    cwd: std.Io.Dir,
    src_path: []const u8,
    prefix: []const u8,
    ext: []const u8,
    names: *std.ArrayList([]const u8),
) !void {
    const io = config.globalIo();
    var src_dir = cwd.openDir(io, src_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer src_dir.close(io);

    var iter = src_dir.iterate();
    while (try iter.next(io)) |entry| {
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
                // A nested checkout under any name (`.worktrees/`, a
                // submodule, a plain clone) is not this project's source
                // — see `isSkippableDir` (#692).
                if (isSkippableDir(src_dir, entry.name)) continue;

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
    const src_path = try std.fs.path.join(allocator, &.{ src_base, folder });
    defer allocator.free(src_path);
    const dst_path = try std.fs.path.join(allocator, &.{ dst_base, folder });
    defer allocator.free(dst_path);
    try copyDirRecursiveAbs(allocator, src_path, dst_path);
}

/// `copyDirRecursive` over two fully-resolved paths (the `copyAndScanAbs`
/// precedent: source and destination need not share a last segment).
/// Extracted for `linkDirAbs`'s Windows fallback — behavior is exactly the
/// base+folder wrapper's.
pub fn copyDirRecursiveAbs(allocator: std.mem.Allocator, src_path: []const u8, dst_path: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, dst_path);

    // Only a missing source is a silent skip (matches linkDir); any other
    // openDir failure must propagate or the caller would treat a partial
    // (or empty) destination as a successful copy.
    var src_dir = cwd.openDir(io, src_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer src_dir.close(io);

    var iter = src_dir.iterate();
    while (try iter.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                var dst_dir = try cwd.openDir(io, dst_path, .{});
                defer dst_dir.close(io);
                // Streaming copy: no size cap and no whole-file allocation
                // (assets routinely exceed any fixed readFileAlloc limit).
                try src_dir.copyFile(entry.name, dst_dir, entry.name, io, .{});
            },
            .directory => {
                // Same pruning as the scanning walks (#692): an asset tree
                // (or a Windows symlink-fallback copy of a game dir) that
                // happens to contain a nested checkout must not be
                // duplicated wholesale into the generated target.
                if (isSkippableDir(src_dir, entry.name)) {
                    // Drop any copy an EARLIER run made. Without this the
                    // `continue` leaves `dst_path/entry.name` untouched, so
                    // a nested checkout mirrored by an older assembler — or
                    // a directory that only later gained a `.git` — survives
                    // regeneration even though the source is now skipped.
                    // `copyAndScanRecursive` prunes its orphans in a
                    // dedicated pass; this walk has none, so it must clean
                    // up here or the skip is only honoured into a clean
                    // destination.
                    //
                    // Safe to delete: the destination is generator-owned
                    // (see the mirror contract on `copyAndScanRecursive`).
                    var stale_parent = cwd.openDir(io, dst_path, .{}) catch |err| switch (err) {
                        error.FileNotFound => continue,
                        else => return err,
                    };
                    defer stale_parent.close(io);
                    // `deleteTree` is already idempotent on a missing
                    // path (no `FileNotFound` in its error set).
                    try stale_parent.deleteTree(io, entry.name);
                    continue;
                }

                const sub_src = try std.fs.path.join(allocator, &.{ src_path, entry.name });
                defer allocator.free(sub_src);
                const sub_dst = try std.fs.path.join(allocator, &.{ dst_path, entry.name });
                defer allocator.free(sub_dst);
                try copyDirRecursiveAbs(allocator, sub_src, sub_dst);
            },
            else => {},
        }
    }
}
