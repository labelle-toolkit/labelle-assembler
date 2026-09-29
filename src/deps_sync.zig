//! deps_sync — reconcile a staged package under `.labelle/deps/` with its
//! source tree IN PLACE (#674).
//!
//! `generate` used to `deleteTree` the whole `deps/` dir and re-hardlink every
//! package on every run. A long-lived `zig build --watch` loses its directory
//! watches across that delete+recreate, and every staged file gets a new
//! identity even when nothing changed. `syncTree` is a mirror instead:
//!
//!   * a dest file that is still the SAME file as the source (a hardlink —
//!     same inode, size and mtime) or holds the same bytes (the copy fallback)
//!     is left alone;
//!   * a missing or different dest file is (re)linked from the source;
//!   * a dest entry with no source counterpart is removed (orphan sweep);
//!   * build/VCS/output dirs (`skip_dirs`) are never staged from the source —
//!     and never swept from the dest either: a tool run INSIDE the staged
//!     package creates them there (the scripting declare step's `zig build`
//!     fetches the package's url deps into its `zig-pkg/`), and sweeping them
//!     would re-fetch on every generate. The old wipe-and-relink staging never
//!     copied them, so no stale copy of one exists to clean up.
//!
//! `preserve_top_zon`: a local package's top-level `build.zig.zon` is
//! re-written by `deps_linker` (relative `.path` deps re-anchored for the deps
//! location), so an EXISTING dest zon is left for that step to reconcile —
//! syncing it back to the source bytes would make the rewrite churn it on
//! every run. A missing one is linked like any file.
//!
//! A dest LINK (symlink / junction) where the source has a DIRECTORY — the
//! overlay `scripting_splice.stageNativeSources` places over the plugin's
//! placeholder crate dir — is unlinked (never followed or descended into) and
//! the source dir mirrored back. That phase re-places its link right after
//! whenever the game still has native sources; when it no longer does, the
//! restored placeholder is exactly what the build needs.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const write_if_changed = @import("write_if_changed.zig");

/// Directory names never staged from a package (see `syncTree`).
///   - zig-pkg: the fetched-dependency cache, whose hashed subpaths blow past
///     the OS path limit (NameTooLong).
///   - .labelle: generated output — critical when a package ships an example
///     inside itself (labelle-bgfx/examples/…): staging it while generating
///     that example would copy the example's own output back into the stage.
pub const skip_dirs = [_][]const u8{ ".zig-cache", "zig-out", "zig-pkg", ".labelle", ".git" };

pub const Options = struct {
    /// Leave an existing top-level `build.zig.zon` alone (see module doc).
    preserve_top_zon: bool = false,
};

/// What a sync did — the mechanism the tests assert on.
pub const Stats = struct {
    /// Files (re)linked or copied because the dest was missing or different.
    linked: usize = 0,
    /// Files left untouched because they were already up to date.
    kept: usize = 0,
    /// Dest entries removed because the source no longer has them.
    removed: usize = 0,
};

fn isSkipDir(name: []const u8) bool {
    for (skip_dirs) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

/// Mirror `src_path` into `dest_path` (see module doc). Errors when the source
/// dir cannot be opened (a missing source is `error.FileNotFound`).
pub fn syncTree(allocator: std.mem.Allocator, src_path: []const u8, dest_path: []const u8, opts: Options, stats: *Stats) !void {
    try syncDir(allocator, src_path, dest_path, opts, true, stats);
}

fn syncDir(allocator: std.mem.Allocator, src_path: []const u8, dest_path: []const u8, opts: Options, top: bool, stats: *Stats) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    var src_dir = try cwd.openDir(io, src_path, .{ .iterate = true });
    defer src_dir.close(io);
    try cwd.createDirPath(io, dest_path);

    // Names the source still has at this level — everything else in dest is
    // an orphan. Owned strings, freed on exit.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit(allocator);
    }

    var iter = src_dir.iterate();
    while (try iter.next(io)) |entry| {
        switch (entry.kind) {
            .directory, .file, .sym_link => {},
            else => continue,
        }
        if (entry.kind == .directory and isSkipDir(entry.name)) continue;
        try seen.put(allocator, try allocator.dupe(u8, entry.name), {});

        const src_sub = try std.fs.path.join(allocator, &.{ src_path, entry.name });
        defer allocator.free(src_sub);
        const dest_sub = try std.fs.path.join(allocator, &.{ dest_path, entry.name });
        defer allocator.free(dest_sub);

        switch (entry.kind) {
            .directory => {
                // A link (overlay) or a file where the source has a dir:
                // remove it — `removeEntry` unlinks, never follows.
                if (isLink(dest_sub)) {
                    try removeEntry(dest_sub);
                } else if (destKind(dest_sub)) |k| {
                    if (k != .directory) try removeEntry(dest_sub);
                }
                try syncDir(allocator, src_sub, dest_sub, opts, false, stats);
            },
            .file => {
                if (top and opts.preserve_top_zon and std.mem.eql(u8, entry.name, "build.zig.zon") and destKind(dest_sub) != null) {
                    stats.kept += 1;
                    continue;
                }
                if (isSameFile(src_sub, dest_sub)) {
                    stats.kept += 1;
                    continue;
                }
                if (try stageFile(allocator, src_sub, dest_sub)) stats.linked += 1 else stats.kept += 1;
            },
            .sym_link => {
                var src_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const src_len = src_dir.readLink(io, entry.name, &src_buf) catch continue;
                var dest_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                if (cwd.readLink(io, dest_sub, &dest_buf)) |dest_len| {
                    if (std.mem.eql(u8, src_buf[0..src_len], dest_buf[0..dest_len])) {
                        stats.kept += 1;
                        continue;
                    }
                } else |_| {}
                if (destKind(dest_sub) != null) try removeEntry(dest_sub);
                cwd.symLink(io, src_buf[0..src_len], dest_sub, .{}) catch {};
                stats.linked += 1;
            },
            else => unreachable,
        }
    }

    // Orphan sweep. Collect first, then delete — mutating a directory while
    // iterating it is not portable.
    var orphans: std.ArrayList([]const u8) = .empty;
    defer {
        for (orphans.items) |o| allocator.free(o);
        orphans.deinit(allocator);
    }
    {
        var dest_dir = try cwd.openDir(io, dest_path, .{ .iterate = true });
        defer dest_dir.close(io);
        var dit = dest_dir.iterate();
        while (try dit.next(io)) |entry| {
            if (seen.contains(entry.name)) continue;
            if (entry.kind == .directory and isSkipDir(entry.name)) continue;
            try orphans.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }
    for (orphans.items) |name| {
        const p = try std.fs.path.join(allocator, &.{ dest_path, name });
        defer allocator.free(p);
        try removeEntry(p);
        stats.removed += 1;
    }
}

/// Remove one dest entry of any kind. A link is unlinked, never followed —
/// `deleteTree` on a Windows directory link could otherwise recurse into (and
/// empty) the tree it points at.
fn removeEntry(path: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    if (isLink(path)) {
        cwd.deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            // Windows directory symlinks / junctions are removed as dirs.
            error.IsDir => cwd.deleteDir(io, path) catch |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            },
            else => return err,
        };
    } else {
        try cwd.deleteTree(io, path);
    }
}

fn isLink(path: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = std.Io.Dir.cwd().readLink(config.globalIo(), path, &buf) catch return false;
    return true;
}

/// Kind of the entry at `path` WITHOUT following links; null when absent.
fn destKind(path: []const u8) ?std.Io.File.Kind {
    const st = std.Io.Dir.cwd().statFile(config.globalIo(), path, .{ .follow_symlinks = false }) catch return null;
    return st.kind;
}

/// True when `dest` IS the source file — a hardlink to it: same inode, size
/// and mtime (size/mtime guard a coincidental inode match across two
/// filesystems; see #806). Byte equality is deliberately NOT enough: a stage
/// hardlinked to another tree, or detached from a source that was replaced,
/// would stop tracking the current source.
fn isSameFile(src: []const u8, dest: []const u8) bool {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const ds = cwd.statFile(io, dest, .{ .follow_symlinks = false }) catch return false;
    if (ds.kind != .file) return false;
    const ss = cwd.statFile(io, src, .{}) catch return false;
    return ss.inode == ds.inode and ss.size == ds.size and ss.mtime.nanoseconds == ds.mtime.nanoseconds;
}

/// Make `dest` the source file. Returns true when it changed `dest`.
///
/// Hardlink first, to a temp name renamed over `dest` (the old file is never
/// written through). Only when hardlinking is impossible (cross-device, no
/// hardlink support) does it fall back to a copy — and then an existing
/// `dest` with the same bytes and permissions is kept (returns false), so the
/// copy fallback is byte-stable too.
fn stageFile(allocator: std.mem.Allocator, src: []const u8, dest: []const u8) !bool {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const tmp = try std.fmt.allocPrint(allocator, "{s}.labelle-link", .{dest});
    defer allocator.free(tmp);
    cwd.deleteFile(io, tmp) catch {};

    if (hardLink(allocator, src, tmp)) {
        if (destKind(dest)) |k| if (k != .file) try removeEntry(dest);
        try cwd.rename(tmp, cwd, dest, io);
        return true;
    } else |_| {}

    if (write_if_changed.sameFiles(io, cwd, src, cwd, dest)) return false;
    if (destKind(dest) != null) try removeEntry(dest);
    try cwd.copyFile(src, cwd, dest, io, .{});
    return true;
}

fn hardLink(allocator: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    if (comptime builtin.os.tag == .windows) return windowsHardLink(allocator, src, dest);
    return std.Io.Dir.cwd().hardLink(src, std.Io.Dir.cwd(), dest, config.globalIo(), .{});
}

/// Windows hardlink via kernel32.CreateHardLinkW (NTFS, no admin needed).
fn windowsHardLink(allocator: std.mem.Allocator, src: []const u8, dest: []const u8) !void {
    if (comptime builtin.os.tag != .windows) unreachable;
    // Zig 0.16 removed `std.os.windows.sliceToPrefixedFileW`; convert the
    // UTF-8 paths to NUL-terminated UTF-16LE ourselves. CreateHardLinkW is a
    // Win32 (not NT) call, so a plain wide path — no `\??\` prefix.
    const src_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, src);
    defer allocator.free(src_w);
    const dest_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, dest);
    defer allocator.free(dest_w);
    if (CreateHardLinkW(dest_w.ptr, src_w.ptr, null) == 0) return error.PermissionDenied;
}

extern "kernel32" fn CreateHardLinkW(
    lpFileName: [*:0]const u16,
    lpExistingFileName: [*:0]const u16,
    lpSecurityAttributes: ?*anyopaque,
) callconv(.winapi) c_int;

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    src: []u8,
    dest: []u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(testing.io, "pkg/src");
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/build.zig", .data = "// build" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/build.zig.zon", .data = ".{}" });
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/src/root.zig", .data = "pub const x = 1;" });
        const src = try tmp.dir.realPathFileAlloc(testing.io, "pkg", testing.allocator);
        defer testing.allocator.free(src);
        const base = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(base);
        return .{
            .tmp = tmp,
            .src = try testing.allocator.dupe(u8, src),
            .dest = try std.fs.path.join(testing.allocator, &.{ base, "deps", "labelle-pkg" }),
        };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.src);
        testing.allocator.free(self.dest);
        self.tmp.cleanup();
    }

    fn sync(self: *Fixture, opts: Options) !Stats {
        var stats: Stats = .{};
        try syncTree(testing.allocator, self.src, self.dest, opts, &stats);
        return stats;
    }

    fn stat(self: *Fixture, rel: []const u8) !std.Io.File.Stat {
        const p = try std.fs.path.join(testing.allocator, &.{ self.dest, rel });
        defer testing.allocator.free(p);
        return std.Io.Dir.cwd().statFile(testing.io, p, .{});
    }
};

test "syncTree: a second sync of an unchanged package touches nothing (inode + mtime survive)" {
    var fx = try Fixture.init();
    defer fx.deinit();

    const first = try fx.sync(.{});
    try testing.expectEqual(@as(usize, 3), first.linked);
    const before = try fx.stat("src/root.zig");

    const second = try fx.sync(.{});
    // Mechanism: nothing relinked, nothing removed — every file was KEPT.
    try testing.expectEqual(@as(usize, 0), second.linked);
    try testing.expectEqual(@as(usize, 0), second.removed);
    try testing.expectEqual(@as(usize, 3), second.kept);
    const after = try fx.stat("src/root.zig");
    try testing.expectEqual(before.inode, after.inode);
    try testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
}

test "syncTree: a replaced source file is relinked, a deleted one is swept, the rest kept" {
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.sync(.{});
    const kept_before = try fx.stat("build.zig");

    // Replace (new inode, new bytes) one file and delete another.
    try fx.tmp.dir.deleteFile(testing.io, "pkg/src/root.zig");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/src/root.zig", .data = "pub const x = 2;" });
    try fx.tmp.dir.deleteFile(testing.io, "pkg/build.zig.zon");

    const s = try fx.sync(.{});
    try testing.expectEqual(@as(usize, 1), s.linked);
    try testing.expectEqual(@as(usize, 1), s.removed);
    try testing.expectEqual(@as(usize, 1), s.kept);

    var buf: [64]u8 = undefined;
    const p = try std.fs.path.join(testing.allocator, &.{ fx.dest, "src/root.zig" });
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("pub const x = 2;", try std.Io.Dir.cwd().readFile(testing.io, p, &buf));
    try testing.expectError(error.FileNotFound, fx.stat("build.zig.zon"));
    const kept_after = try fx.stat("build.zig");
    try testing.expectEqual(kept_before.inode, kept_after.inode);
}

test "syncTree: preserve_top_zon keeps an existing (rewritten) dest zon, links a missing one" {
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.sync(.{ .preserve_top_zon = true });

    // Simulate deps_linker's re-anchoring rewrite: a DIFFERENT file at dest.
    const zon = try std.fs.path.join(testing.allocator, &.{ fx.dest, "build.zig.zon" });
    defer testing.allocator.free(zon);
    try std.Io.Dir.cwd().deleteFile(testing.io, zon);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = zon, .data = ".{ .rewritten = true }" });

    const s = try fx.sync(.{ .preserve_top_zon = true });
    try testing.expectEqual(@as(usize, 0), s.linked);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(".{ .rewritten = true }", try std.Io.Dir.cwd().readFile(testing.io, zon, &buf));

    // Without the option the stale zon is brought back to the source bytes.
    const s2 = try fx.sync(.{});
    try testing.expectEqual(@as(usize, 1), s2.linked);
    try testing.expectEqualStrings(".{}", try std.Io.Dir.cwd().readFile(testing.io, zon, &buf));
}

test "syncTree: a stage hardlinked to ANOTHER tree with identical bytes is relinked to the current source" {
    // The pin moved to a different checkout whose files have the same bytes:
    // byte equality must not keep the stage tied to the old tree.
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.sync(.{});

    try fx.tmp.dir.createDirPath(testing.io, "fork/src");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "fork/build.zig", .data = "// build" });
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "fork/build.zig.zon", .data = ".{}" });
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "fork/src/root.zig", .data = "pub const x = 1;" });
    const fork = try fx.tmp.dir.realPathFileAlloc(testing.io, "fork", testing.allocator);
    defer testing.allocator.free(fork);

    var stats: Stats = .{};
    try syncTree(testing.allocator, fork, fx.dest, .{}, &stats);
    const staged = try fx.stat("src/root.zig");
    const fork_file = try fx.tmp.dir.statFile(testing.io, "fork/src/root.zig", .{});
    if (staged.nlink > 1) {
        // Hardlinks available: every file now IS the fork's file.
        try testing.expectEqual(@as(usize, 3), stats.linked);
        try testing.expectEqual(fork_file.inode, staged.inode);
    }
}

test "syncTree: a stage detached from an atomically replaced source (same bytes) is relinked" {
    // Replace-by-rename leaves the old stage hardlink with nlink == 1 and the
    // same bytes — it must still be relinked, or later in-place edits to the
    // new source never reach the stage.
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.sync(.{});
    const before = try fx.stat("src/root.zig");
    if (before.nlink < 2) return error.SkipZigTest; // no hardlinks here

    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "pkg/src/root.zig.new", .data = "pub const x = 1;" });
    try fx.tmp.dir.rename("pkg/src/root.zig.new", fx.tmp.dir, "pkg/src/root.zig", testing.io);

    const s = try fx.sync(.{});
    try testing.expectEqual(@as(usize, 1), s.linked);
    const src_now = try fx.tmp.dir.statFile(testing.io, "pkg/src/root.zig", .{});
    try testing.expectEqual(src_now.inode, (try fx.stat("src/root.zig")).inode);
}

test "syncTree: a link overlay over a source dir is unlinked (never followed) and the dir restored" {
    // `stageNativeSources` links the game's sources over the plugin's
    // placeholder dir. When the game drops its native sources, the next sync
    // must bring the placeholder back — and must not touch the link target.
    var fx = try Fixture.init();
    defer fx.deinit();
    _ = try fx.sync(.{});

    try fx.tmp.dir.createDirPath(testing.io, "game/scripts");
    try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = "game/scripts/mod.rs", .data = "// game source" });
    const game_scripts = try fx.tmp.dir.realPathFileAlloc(testing.io, "game/scripts", testing.allocator);
    defer testing.allocator.free(game_scripts);
    const overlay = try std.fs.path.join(testing.allocator, &.{ fx.dest, "src" });
    defer testing.allocator.free(overlay);
    try std.Io.Dir.cwd().deleteTree(testing.io, overlay);
    std.Io.Dir.cwd().symLink(testing.io, game_scripts, overlay, .{ .is_directory = true }) catch return error.SkipZigTest;

    _ = try fx.sync(.{});
    try testing.expect(!isLink(overlay));
    _ = try fx.stat("src/root.zig");
    // The game's own file behind the old link is untouched.
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("// game source", try fx.tmp.dir.readFile(testing.io, "game/scripts/mod.rs", &buf));
}

test "syncTree: errors on missing source" {
    // createDepsLinks pre-checks source existence and relies on this staying
    // an error (the #87 cascade).
    var fx = try Fixture.init();
    defer fx.deinit();
    const missing = try std.fs.path.join(testing.allocator, &.{ fx.src, "nope" });
    defer testing.allocator.free(missing);
    var stats: Stats = .{};
    try testing.expectError(error.FileNotFound, syncTree(testing.allocator, missing, fx.dest, .{}, &stats));
}

test "syncTree: never stages zig-pkg/.labelle/.git/.zig-cache/zig-out, never sweeps a tool-created one" {
    var fx = try Fixture.init();
    defer fx.deinit();
    for (skip_dirs) |d| {
        const p = try std.fmt.allocPrint(testing.allocator, "pkg/{s}/deep", .{d});
        defer testing.allocator.free(p);
        try fx.tmp.dir.createDirPath(testing.io, p);
        const f = try std.fmt.allocPrint(testing.allocator, "pkg/{s}/deep/x.txt", .{d});
        defer testing.allocator.free(f);
        try fx.tmp.dir.writeFile(testing.io, .{ .sub_path = f, .data = "x" });
    }
    _ = try fx.sync(.{});
    for (skip_dirs) |d| try testing.expectError(error.FileNotFound, fx.stat(d));
    _ = try fx.stat("src/root.zig");

    // A `zig build` run inside the staged package (the declare step) leaves
    // its fetched deps behind; the next sync must keep them.
    const fetched = try std.fs.path.join(testing.allocator, &.{ fx.dest, "zig-pkg", "lua-5.4.8" });
    defer testing.allocator.free(fetched);
    try std.Io.Dir.cwd().createDirPath(testing.io, fetched);
    const s = try fx.sync(.{});
    try testing.expectEqual(@as(usize, 0), s.removed);
    _ = try fx.stat("zig-pkg/lua-5.4.8");
}
