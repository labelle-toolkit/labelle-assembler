//! Locally-sourced cache slots (#685).
//!
//! A `(local)` install — the assembler running inside the labelle-toolkit
//! monorepo, symlinking a sibling checkout into the cache instead of
//! cloning/downloading a release — used to write that working-tree source
//! into the slot named by the *pinned* version. So
//! `~/.labelle/packages/gfx/1.29.0/` could hold gfx 1.30.0 code while every
//! manifest, lockfile and diagnostic still said 1.29.0.
//!
//! This module restores the invariant that **a slot named for a version
//! contains that version**. Local sources get their own reserved slot next
//! to the version slots:
//!
//!   ~/.labelle/packages/gfx/1.29.0/        ← always the 1.29.0 release
//!   ~/.labelle/packages/gfx/local          ← symlink to the sibling checkout
//!   ~/.labelle/packages/gfx/local.origin   ← provenance for that symlink
//!
//! `local` is not a semver string, so it can never collide with a released
//! version. The `.origin` marker records where the source came from and at
//! what working-tree revision, so `resolve` (and any future `doctor`) can
//! say *exactly* what is being built.
//!
//! Resolution only prefers the local slot when the running assembler is
//! itself inside the monorepo checkout — the same condition under which the
//! slot gets populated. A released binary (`~/.labelle/bin/labelle-assembler`,
//! which the `labelle` CLI shells out to) therefore always resolves the
//! pinned release, which is what #679 expected and did not get.
const std = @import("std");
const config = @import("../config.zig");
const env = @import("env.zig");

/// Reserved slot name for locally-sourced packages. Not a valid semver
/// string, so it cannot collide with a released version directory.
pub const SLOT_NAME = "local";

/// Provenance marker written next to the local slot.
pub const ORIGIN_NAME = "local.origin";

// ── slot paths ───────────────────────────────────────────────────────

/// `~/.labelle/packages/<package>/local` — the local slot for a framework
/// package (core, engine, gfx).
pub fn frameworkSlot(allocator: std.mem.Allocator, package: []const u8) ![]const u8 {
    const packages_dir = try env.getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    return std.fs.path.join(allocator, &.{ packages_dir, package, SLOT_NAME });
}

/// `~/.labelle/packages/plugins/<repo>/local` — the local slot for a plugin
/// or external backend package.
pub fn pluginSlot(allocator: std.mem.Allocator, repo: []const u8) ![]const u8 {
    const packages_dir = try env.getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    return std.fs.path.join(allocator, &.{ packages_dir, "plugins", repo, SLOT_NAME });
}

/// `~/.labelle/packages/assembler/local` — the local slot for the
/// assembler-bundled packages (backends/, ecs/, gui/).
pub fn assemblerSlot(allocator: std.mem.Allocator) ![]const u8 {
    const packages_dir = try env.getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    return std.fs.path.join(allocator, &.{ packages_dir, "assembler", SLOT_NAME });
}

/// The `.origin` marker path for a slot produced by the helpers above:
/// `<parent>/local.origin`.
pub fn originPath(allocator: std.mem.Allocator, slot: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(slot) orelse return error.InvalidSlotPath;
    return std.fs.path.join(allocator, &.{ parent, ORIGIN_NAME });
}

/// Whether `path` names a local slot — i.e. any path component is exactly
/// `local`. Covers both a bare slot (`…/gfx/local`) and a subpath inside one
/// (`…/assembler/local/backends/sokol`).
pub fn isLocalSlotPath(path: []const u8) bool {
    var iter = std.mem.tokenizeAny(u8, path, "/\\");
    while (iter.next()) |component| {
        if (std.mem.eql(u8, component, SLOT_NAME)) return true;
    }
    return false;
}

// ── monorepo probe ───────────────────────────────────────────────────

/// Test seam: the directory the monorepo probe starts from. `null` (the
/// production value) means "the running executable's directory".
var probe_start_override: ?[]const u8 = null;

/// Point the monorepo probe at `dir` instead of the running executable's
/// directory. Tests only — pass `null` to restore the default.
pub fn setProbeStartForTesting(dir: ?[]const u8) void {
    probe_start_override = dir;
}

/// Walk up from the assembler executable's directory looking for the
/// monorepo root (identified by a `labelle-core` sibling). Returns null
/// when the binary isn't running inside the monorepo checkout.
///
/// Moved here from cache_cmd.zig: both the populate side (which decides to
/// symlink a sibling checkout) and the resolve side (which decides whether
/// to honour that symlink) need the same answer.
pub fn findRepoRoot(allocator: std.mem.Allocator) ?[]const u8 {
    const io = config.globalIo();

    var exe_path: ?[:0]u8 = null;
    defer if (exe_path) |p| allocator.free(p);

    var dir: []const u8 = undefined;
    if (probe_start_override) |override| {
        dir = override;
    } else {
        exe_path = std.process.executablePathAlloc(io, allocator) catch return null;
        dir = std.fs.path.dirname(exe_path.?) orelse return null;
    }

    var depth: u8 = 0;
    while (depth < 6) : (depth += 1) {
        const marker = std.fs.path.join(allocator, &.{ dir, "labelle-core" }) catch return null;
        defer allocator.free(marker);
        std.Io.Dir.cwd().access(io, marker, .{}) catch {
            dir = std.fs.path.dirname(dir) orelse return null;
            continue;
        };
        return allocator.dupe(u8, dir) catch return null;
    }
    return null;
}

/// Whether the running assembler lives inside the monorepo checkout.
pub fn inMonorepo(allocator: std.mem.Allocator) bool {
    const root = findRepoRoot(allocator) orelse return false;
    allocator.free(root);
    return true;
}

/// The sibling checkout directory name for a framework package
/// (`core` → `labelle-core`).
pub fn frameworkDirName(package: []const u8) []const u8 {
    if (std.mem.eql(u8, package, "core")) return "labelle-core";
    if (std.mem.eql(u8, package, "engine")) return "labelle-engine";
    if (std.mem.eql(u8, package, "gfx")) return "labelle-gfx";
    return package;
}

// ── resolution ───────────────────────────────────────────────────────

/// The local slot for a framework package, when it should be used: the
/// running assembler is inside the monorepo AND the slot is populated.
/// Caller owns the returned path.
pub fn activeFrameworkSlot(allocator: std.mem.Allocator, package: []const u8) !?[]const u8 {
    if (!inMonorepo(allocator)) return null;
    const slot = try frameworkSlot(allocator, package);
    return activeOrFree(allocator, slot);
}

/// The local slot for a plugin / external backend package, when it should
/// be used. Caller owns the returned path.
pub fn activePluginSlot(allocator: std.mem.Allocator, repo: []const u8) !?[]const u8 {
    if (!inMonorepo(allocator)) return null;
    const slot = try pluginSlot(allocator, repo);
    return activeOrFree(allocator, slot);
}

/// The local slot for the assembler-bundled packages, when it should be
/// used. Caller owns the returned path.
pub fn activeAssemblerSlot(allocator: std.mem.Allocator) !?[]const u8 {
    if (!inMonorepo(allocator)) return null;
    const slot = try assemblerSlot(allocator);
    return activeOrFree(allocator, slot);
}

fn activeOrFree(allocator: std.mem.Allocator, slot: []const u8) ?[]const u8 {
    if (pathExists(slot)) return slot;
    allocator.free(slot);
    return null;
}

/// Whether `path` exists (local copy of disk.dirExists — kept here so this
/// module does not have to import the disk layer, which imports this one).
pub fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(config.globalIo(), path, .{}) catch return false;
    return true;
}

/// Whether `path` is a symlink.
pub fn isSymlinkPath(path: []const u8) bool {
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    _ = std.Io.Dir.readLinkAbsolute(config.globalIo(), path, &link_buf) catch return false;
    return true;
}

// ── provenance marker ────────────────────────────────────────────────

pub const Origin = struct {
    /// Absolute path of the checkout the slot was populated from.
    source: []const u8,
    /// Working-tree revision at populate time, or "unknown".
    revision: []const u8,
    /// The version that was pinned when the slot was populated. Recorded
    /// for diagnostics only — the slot is NOT that version.
    pinned: []const u8,

    pub fn deinit(self: Origin, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.revision);
        allocator.free(self.pinned);
    }
};

/// Record where a local slot came from. Best-effort: a marker that cannot
/// be written costs a warning, not the install.
pub fn writeOrigin(
    allocator: std.mem.Allocator,
    slot: []const u8,
    source_dir: []const u8,
    pinned_version: []const u8,
) void {
    const io = config.globalIo();
    const path = originPath(allocator, slot) catch return;
    defer allocator.free(path);

    const revision = gitRevision(allocator, source_dir) orelse
        (allocator.dupe(u8, "unknown") catch return);
    defer allocator.free(revision);

    const body = std.fmt.allocPrint(
        allocator,
        "# labelle local cache slot (#685) — NOT a released version\n" ++
            "source = {s}\nrevision = {s}\npinned = {s}\n",
        .{ source_dir, revision, pinned_version },
    ) catch return;
    defer allocator.free(body);

    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, body) catch {};
}

/// Read the provenance marker for a local slot, if there is one.
pub fn readOrigin(allocator: std.mem.Allocator, slot: []const u8) ?Origin {
    const io = config.globalIo();
    const path = originPath(allocator, slot) catch return null;
    defer allocator.free(path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch return null;
    defer allocator.free(content);

    const source = fieldValue(content, "source") orelse return null;
    const revision = fieldValue(content, "revision") orelse "unknown";
    const pinned = fieldValue(content, "pinned") orelse "unknown";

    const source_owned = allocator.dupe(u8, source) catch return null;
    const revision_owned = allocator.dupe(u8, revision) catch {
        allocator.free(source_owned);
        return null;
    };
    const pinned_owned = allocator.dupe(u8, pinned) catch {
        allocator.free(source_owned);
        allocator.free(revision_owned);
        return null;
    };
    return .{ .source = source_owned, .revision = revision_owned, .pinned = pinned_owned };
}

/// `key = value` lookup over the marker's line-oriented body.
fn fieldValue(content: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        const rest = std.mem.trim(u8, trimmed[key.len..], " \t");
        if (!std.mem.startsWith(u8, rest, "=")) continue;
        return std.mem.trim(u8, rest[1..], " \t");
    }
    return null;
}

/// Best-effort working-tree revision for `source_dir`, read straight out of
/// `.git` — no subprocess. Returns null when the revision can't be
/// determined (packed refs, a detached-but-missing ref, no `.git` at all).
pub fn gitRevision(allocator: std.mem.Allocator, source_dir: []const u8) ?[]const u8 {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const git_path = std.fs.path.join(allocator, &.{ source_dir, ".git" }) catch return null;
    defer allocator.free(git_path);

    // `.git` is a directory in a main checkout and a `gitdir:` linkfile in a
    // worktree. Resolve the linkfile so worktree checkouts report their own
    // HEAD rather than nothing.
    var git_dir: []const u8 = allocator.dupe(u8, git_path) catch return null;
    defer allocator.free(git_dir);

    if (cwd.readFileAlloc(io, git_path, allocator, .limited(4096))) |linkfile| {
        defer allocator.free(linkfile);
        const trimmed = std.mem.trim(u8, linkfile, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "gitdir:")) {
            const target = std.mem.trim(u8, trimmed["gitdir:".len..], " \t\r\n");
            const owned = allocator.dupe(u8, target) catch return null;
            allocator.free(git_dir);
            git_dir = owned;
        }
    } else |_| {}

    const head_path = std.fs.path.join(allocator, &.{ git_dir, "HEAD" }) catch return null;
    defer allocator.free(head_path);

    const head = cwd.readFileAlloc(io, head_path, allocator, .limited(4096)) catch return null;
    defer allocator.free(head);
    const head_trimmed = std.mem.trim(u8, head, " \t\r\n");

    if (!std.mem.startsWith(u8, head_trimmed, "ref:")) {
        // Detached HEAD — the sha is right there.
        return allocator.dupe(u8, head_trimmed) catch null;
    }

    const ref = std.mem.trim(u8, head_trimmed["ref:".len..], " \t\r\n");
    // A worktree's refs live in the COMMON dir, not its per-worktree gitdir.
    // Try the per-worktree dir first, then the main `.git` beside it.
    const ref_path = std.fs.path.join(allocator, &.{ git_dir, ref }) catch return null;
    defer allocator.free(ref_path);

    if (cwd.readFileAlloc(io, ref_path, allocator, .limited(4096))) |sha| {
        defer allocator.free(sha);
        return allocator.dupe(u8, std.mem.trim(u8, sha, " \t\r\n")) catch null;
    } else |_| {}

    // Fall back to naming the branch — better than "unknown" for a
    // packed-refs checkout.
    return allocator.dupe(u8, ref) catch null;
}

// ── build-time diagnostics ───────────────────────────────────────────

/// Warn when a package that is *pinned to a version* has resolved to
/// something that is not that released version — either the reserved local
/// slot (this assembler's own doing) or a legacy version slot that an older
/// assembler symlinked at a sibling checkout (#685's original defect).
///
/// A `local:` pin is explicit and self-describing, so it is never warned
/// about: the version string itself already says where the source is.
pub fn warnIfLocallySourced(
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    path: []const u8,
) void {
    if (config.isLocalVersion(version)) return;

    if (isLocalSlotPath(path)) {
        if (readOrigin(allocator, path)) |origin| {
            defer origin.deinit(allocator);
            std.log.warn(
                "labelle: {s} is built from LOCAL sources, not the pinned {s} — " ++
                    "source '{s}' (rev {s}). Run 'labelle-assembler clean' to drop it.",
                .{ name, version, origin.source, origin.revision },
            );
        } else {
            std.log.warn(
                "labelle: {s} is built from LOCAL sources at '{s}', not the pinned {s}.",
                .{ name, path, version },
            );
        }
        return;
    }

    if (isSymlinkPath(path)) {
        std.log.warn(
            "labelle: cache slot '{s}' is a symlink to a local checkout, so {s} {s} " ++
                "is NOT the released version (#685). Run 'labelle-assembler install' to repair it.",
            .{ path, name, version },
        );
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "isLocalSlotPath: recognises the reserved slot and subpaths inside it" {
    try std.testing.expect(isLocalSlotPath("/home/u/.labelle/packages/gfx/local"));
    try std.testing.expect(isLocalSlotPath("/home/u/.labelle/packages/assembler/local/backends/sokol"));
    try std.testing.expect(isLocalSlotPath("C:\\Users\\u\\.labelle\\packages\\gfx\\local"));
    try std.testing.expect(!isLocalSlotPath("/home/u/.labelle/packages/gfx/1.29.0"));
    try std.testing.expect(!isLocalSlotPath("/home/u/.labelle/packages/plugins/github.com/x/localish/1.0.0"));
}

test "originPath: sits beside the slot, not inside it" {
    const alloc = std.testing.allocator;
    const p = try originPath(alloc, "/c/packages/gfx/local");
    defer alloc.free(p);
    try std.testing.expectEqualStrings("/c/packages/gfx/local.origin", p);
}

test "fieldValue: parses the marker body" {
    const body = "# comment\nsource = /a/b\nrevision = deadbeef\npinned = 1.29.0\n";
    try std.testing.expectEqualStrings("/a/b", fieldValue(body, "source").?);
    try std.testing.expectEqualStrings("deadbeef", fieldValue(body, "revision").?);
    try std.testing.expectEqualStrings("1.29.0", fieldValue(body, "pinned").?);
    try std.testing.expect(fieldValue(body, "absent") == null);
}

test "findRepoRoot: finds the monorepo root above the probe start" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-core");
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-assembler/zig-out/bin");

    const bin = try tmp.dir.realPathFileAlloc(std.testing.io, "toolkit/labelle-assembler/zig-out/bin", alloc);
    defer alloc.free(bin);
    const toolkit = try tmp.dir.realPathFileAlloc(std.testing.io, "toolkit", alloc);
    defer alloc.free(toolkit);

    setProbeStartForTesting(bin);
    defer setProbeStartForTesting(null);

    const root = findRepoRoot(alloc) orelse return error.TestUnexpectedResult;
    defer alloc.free(root);
    try std.testing.expectEqualStrings(toolkit, root);
}

test "findRepoRoot: returns null outside the monorepo" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "elsewhere/bin");
    const bin = try tmp.dir.realPathFileAlloc(std.testing.io, "elsewhere/bin", alloc);
    defer alloc.free(bin);

    setProbeStartForTesting(bin);
    defer setProbeStartForTesting(null);

    try std.testing.expect(findRepoRoot(alloc) == null);
}

test "writeOrigin/readOrigin: round-trips provenance for a slot" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "packages/gfx");
    const gfx_dir = try tmp.dir.realPathFileAlloc(std.testing.io, "packages/gfx", alloc);
    defer alloc.free(gfx_dir);
    const slot = try std.fs.path.join(alloc, &.{ gfx_dir, SLOT_NAME });
    defer alloc.free(slot);

    writeOrigin(alloc, slot, "/src/labelle-gfx", "1.29.0");

    const origin = readOrigin(alloc, slot) orelse return error.TestUnexpectedResult;
    defer origin.deinit(alloc);
    try std.testing.expectEqualStrings("/src/labelle-gfx", origin.source);
    try std.testing.expectEqualStrings("1.29.0", origin.pinned);
}
