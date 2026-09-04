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
//! contains that version**. Local sources get a reserved NAMESPACE of their
//! own, outside the version tree entirely:
//!
//!   ~/.labelle/packages/gfx/1.29.0/       ← always the 1.29.0 release
//!   ~/.labelle/packages/local/gfx         ← symlink to the sibling checkout
//!   ~/.labelle/packages/local/gfx.origin  ← provenance for that symlink
//!
//! A namespace rather than a reserved name inside each package, because
//! `versionToGitRef` accepts branch/ref names verbatim: `local` is a
//! perfectly valid version, and `<package>/local` would then be both a
//! reserved slot and a legitimate fetch target (#688 review). Nothing a
//! version resolver constructs can address `packages/local/…`.
//!
//! The `.origin` marker records where the source came from and at what
//! working-tree revision, so `resolve` (and any future `doctor`) can say
//! *exactly* what is being built. It is also the discriminator: only
//! `populate*` writes one.
//!
//! Resolution prefers a local slot only when it was populated FROM the
//! checkout the running assembler lives in. A released binary
//! (`~/.labelle/bin/labelle-assembler`, which the `labelle` CLI shells out
//! to) therefore always resolves the pinned release, which is what #679
//! expected and did not get — and one shared `LABELLE_HOME` cannot leak
//! one clone's sources into another clone's build.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const env = @import("env.zig");

/// Reserved NAMESPACE for locally-sourced slots:
/// `~/.labelle/packages/local/…`.
///
/// A namespace, not a slot name inside each package's version directory
/// (#688 review round 2). `versionToGitRef` passes non-semver versions
/// through verbatim, so `local` is a supported git ref whose ordinary cache
/// path would be `<package>/local` — exactly a reserved slot. A released
/// assembler, with no local slot active, would then resolve a `local` pin
/// straight onto the monorepo-populated directory and report it cached, so
/// no provenance gate on the *activation* side could close it. Under
/// `packages/local/` nothing a version resolver constructs can ever land:
/// framework paths are `packages/<core|engine|gfx>/<version>`, plugins
/// `packages/plugins/<repo>/<version>`, assembler
/// `packages/assembler/<version>`.
pub const SLOT_NS = "local";

/// Reserved namespace for the provenance markers, mirroring the slot tree:
/// `packages/local/gfx` → `packages/local.origins/gfx`.
///
/// A separate tree rather than a `<slot>.origin` sibling (#688 review
/// round 2). Plugin slots are keyed by repo path, and `.` is legal in a
/// repository name, so the marker for `github.com/acme/foo` would have been
/// the slot path of `github.com/acme/foo.origin` — cache both locally and
/// one blocks or overwrites the other. Mirroring the tree makes slot and
/// marker paths structurally disjoint whatever the repo is called.
///
/// `local.origins` cannot itself be mistaken for the slot namespace: the
/// prefix tests below require a path separator right after `packages/local`.
pub const ORIGINS_NS = "local.origins";

// ── slot paths ───────────────────────────────────────────────────────

/// `~/.labelle/packages/local` — the root of the reserved namespace.
pub fn slotsRoot(allocator: std.mem.Allocator) ![]const u8 {
    const packages_dir = try env.getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    return std.fs.path.join(allocator, &.{ packages_dir, SLOT_NS });
}

/// `~/.labelle/packages/local/<package>` — the local slot for a framework
/// package (core, engine, gfx).
pub fn frameworkSlot(allocator: std.mem.Allocator, package: []const u8) ![]const u8 {
    const root = try slotsRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, package });
}

/// `~/.labelle/packages/local/plugins/<key>` — the local slot for a plugin
/// or external backend package.
///
/// The key is ONE opaque component, not the repo path (#688 review round
/// 7). Repo strings are unconstrained, so `<repo>/<name>` pairs can nest:
/// `{ repo = "github.com/acme/foo", name = "bar" }` and
/// `{ repo = "github.com/acme/foo/bar/baz", name = "qux" }` put the second
/// slot INSIDE the first — and the first is a symlink to a checkout, so
/// populating the second would write through it into the user's source
/// tree. A flat key cannot nest.
///
/// Both repo AND name go into it: the repo identifies the package, but the
/// SOURCE is `labelle-<name>`, and one project may declare two non-local
/// deps sharing a repo under different names (an external backend and a
/// plugin alias), populated from different sibling checkouts.
pub fn pluginSlot(allocator: std.mem.Allocator, plugin: config.PluginDep) ![]const u8 {
    const root = try slotsRoot(allocator);
    defer allocator.free(root);

    const key = try pluginSlotKey(allocator, plugin);
    defer allocator.free(key);

    return std.fs.path.join(allocator, &.{ root, "plugins", key });
}

/// `<readable name>-<hash of repo + name>`: legible in a diagnostic, but
/// still a single path component that no other identity can collide with.
fn pluginSlotKey(allocator: std.mem.Allocator, plugin: config.PluginDep) ![]const u8 {
    var hasher = std.hash.Wyhash.init(0x1abe11e);
    hasher.update(plugin.repo);
    hasher.update(&[_]u8{0});
    hasher.update(plugin.name);

    var label: std.ArrayList(u8) = .empty;
    defer label.deinit(allocator);
    for (plugin.name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.') {
            if (label.items.len < 32) try label.append(allocator, c);
        }
    }
    const readable = if (label.items.len == 0) "plugin" else label.items;
    return std.fmt.allocPrint(allocator, "{s}-{x:0>16}", .{ readable, hasher.final() });
}

/// `~/.labelle/packages/local/assembler` — the local slot for the
/// assembler-bundled packages (backends/, ecs/, gui/).
pub fn assemblerSlot(allocator: std.mem.Allocator) ![]const u8 {
    const root = try slotsRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "assembler" });
}

/// `~/.labelle/packages/local.origins` — the root of the marker tree.
pub fn originsRoot(allocator: std.mem.Allocator) ![]const u8 {
    const packages_dir = try env.getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    return std.fs.path.join(allocator, &.{ packages_dir, ORIGINS_NS });
}

/// The provenance marker for a slot: the slot's path relative to the slot
/// namespace, re-rooted under the marker namespace.
pub fn originPath(allocator: std.mem.Allocator, slot: []const u8) ![]const u8 {
    const root = try slotsRoot(allocator);
    defer allocator.free(root);
    if (slot.len <= root.len) return error.InvalidSlotPath;
    if (!std.mem.startsWith(u8, slot, root)) return error.InvalidSlotPath;
    if (!isSep(slot[root.len])) return error.InvalidSlotPath;

    const origins = try originsRoot(allocator);
    defer allocator.free(origins);
    return std.fs.path.join(allocator, &.{ origins, slot[root.len + 1 ..] });
}

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// Whether `path` is a local slot or a subpath inside one — i.e. whether it
/// lies under the reserved namespace. Purely structural: no directory named
/// `local` OUTSIDE `packages/` can qualify, so a cache home such as
/// `/usr/local/labelle` and a plugin owner such as `github.com/local/foo`
/// are both unaffected (#688 review).
pub fn isLocalSlotPath(allocator: std.mem.Allocator, path: []const u8) bool {
    const root = slotsRoot(allocator) catch return false;
    defer allocator.free(root);
    if (path.len <= root.len) return false;
    if (!std.mem.startsWith(u8, path, root)) return false;
    return isSep(path[root.len]);
}

/// The slot `path` lies at or inside — the longest marker-bearing prefix
/// under the reserved namespace. `…/local/gfx` → itself;
/// `…/local/assembler/backends/sokol` → `…/local/assembler`. Caller owns
/// the result.
///
/// Needed because a resolved path may be a SUBPATH of its slot, and the
/// marker sits beside the slot root: reading it at the subpath would always
/// miss, so the warning would drop source and revision (#688 review).
/// Plugin slots sit at a repo-dependent depth, hence the walk rather than a
/// fixed component count.
pub fn localSlotRoot(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const root = slotsRoot(allocator) catch return null;
    defer allocator.free(root);
    if (path.len <= root.len) return null;
    if (!std.mem.startsWith(u8, path, root)) return null;
    if (!isSep(path[root.len])) return null;

    var end = path.len;
    while (end > root.len) {
        const candidate = path[0..end];
        if (hasMarker(allocator, candidate)) return allocator.dupe(u8, candidate) catch null;
        var i = end;
        while (i > root.len and !isSep(path[i - 1])) i -= 1;
        end = i - 1;
    }
    return null;
}

/// Whether the provenance marker for `slot` exists. Only `populate*` writes
/// one, which is what tells a populated slot from any other directory.
fn hasMarker(allocator: std.mem.Allocator, slot: []const u8) bool {
    const marker = originPath(allocator, slot) catch return false;
    defer allocator.free(marker);
    return pathExists(marker);
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

/// The sibling checkout directory name for a framework package
/// (`core` → `labelle-core`).
pub fn frameworkDirName(package: []const u8) []const u8 {
    if (std.mem.eql(u8, package, "core")) return "labelle-core";
    if (std.mem.eql(u8, package, "engine")) return "labelle-engine";
    if (std.mem.eql(u8, package, "gfx")) return "labelle-gfx";
    return package;
}

// ── resolution ───────────────────────────────────────────────────────

/// The sibling checkout a plugin or external backend is populated from.
/// `fetchPluginWithFallback` / `fetchBackendWithFallback` both derive it
/// from the LOGICAL name, not the repo, so the slot (which is keyed by
/// repo) has to be validated against it.
pub fn pluginDirName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "labelle-{s}", .{name});
}

/// The local slot for a framework package, when it should be used: it is
/// populated, and it was populated from the very checkout this assembler is
/// running out of. Caller owns the returned path.
pub fn activeFrameworkSlot(allocator: std.mem.Allocator, package: []const u8) !?[]const u8 {
    const root = findRepoRoot(allocator) orelse return null;
    defer allocator.free(root);

    const expected = try std.fs.path.join(allocator, &.{ root, frameworkDirName(package) });
    defer allocator.free(expected);

    const slot = try frameworkSlot(allocator, package);
    return activeOrFree(allocator, slot, expected);
}

/// The local slot for a plugin / external backend package, when it should
/// be used. Caller owns the returned path.
///
/// Takes the whole dep, not just the repo: the slot is keyed by `.repo`
/// (which identifies the package) but populated from `labelle-<.name>`, so
/// two projects sharing a repo under different logical names expect
/// different siblings, and "some direct child of this monorepo" would let
/// one of them compile the other's checkout (#688 review).
pub fn activePluginSlot(allocator: std.mem.Allocator, plugin: config.PluginDep) !?[]const u8 {
    const root = findRepoRoot(allocator) orelse return null;
    defer allocator.free(root);

    const dir_name = try pluginDirName(allocator, plugin.name);
    defer allocator.free(dir_name);
    const expected = try std.fs.path.join(allocator, &.{ root, dir_name });
    defer allocator.free(expected);

    const slot = try pluginSlot(allocator, plugin);
    return activeOrFree(allocator, slot, expected);
}

/// The local slot for the assembler-bundled packages, when it should be
/// used. Caller owns the returned path.
///
/// Carries one extra condition the single-directory slots don't need: the
/// slot is a *tree* of bundled subdirs, and it is never renamed, so a slot
/// populated while the checkout still lacked `ecs`/`gui` would otherwise go
/// on satisfying every later pin while `resolveAssemblerPackage` handed back
/// paths that do not exist. Version-named slots used to get this for free —
/// a version bump chose a fresh directory. Content-check instead.
pub fn activeAssemblerSlot(allocator: std.mem.Allocator) !?[]const u8 {
    const root = findRepoRoot(allocator) orelse return null;
    defer allocator.free(root);

    const expected = try std.fs.path.join(allocator, &.{ root, "labelle-assembler" });
    defer allocator.free(expected);

    const slot = try assemblerSlot(allocator);
    errdefer allocator.free(slot);
    if (!pathExists(slot)) {
        allocator.free(slot);
        return null;
    }
    const origin = readOrigin(allocator, slot) orelse {
        allocator.free(slot);
        return null;
    };
    defer origin.deinit(allocator);
    if (!samePath(allocator, origin.source, expected) or
        !assemblerSlotComplete(allocator, slot, origin.source))
    {
        allocator.free(slot);
        return null;
    }
    return slot;
}

/// Whether an active slot still TRACKS its source, rather than being a
/// snapshot of it.
///
/// `symlinkToCache` falls back to COPYING the checkout on filesystems where
/// directory symlinks fail (Windows without developer mode). A copy does
/// not see later source edits, and the reserved slot is never renamed, so
/// it would be reused indefinitely — the version-named slot at least got a
/// fresh copy whenever the pin moved (#688 review). Reporting a copy stale
/// makes the cache probes miss, so `ensureCache` repopulates it.
pub fn slotTracksSource(slot: []const u8) bool {
    return isSymlinkPath(slot);
}

/// Same question for the assembler slot, which is a real directory whose
/// bundled SUBDIRS carry the links.
pub fn assemblerSlotTracksSource(allocator: std.mem.Allocator, slot: []const u8) bool {
    for (ASSEMBLER_SUBDIRS) |subdir| {
        const dst = std.fs.path.join(allocator, &.{ slot, subdir }) catch return false;
        defer allocator.free(dst);
        if (!pathExists(dst)) continue;
        if (!isSymlinkPath(dst)) return false;
    }
    return true;
}

/// The bundled subdirectories `populateAssemblerCache` links into the slot.
pub const ASSEMBLER_SUBDIRS = [_][]const u8{ "backends", "ecs", "gui" };

/// Whether the slot's bundled subdirs MATCH the companion checkout's: every
/// one the checkout has is present, and none the checkout has dropped is
/// left behind. A leftover subdir is a stale copy (or a link whose target is
/// gone) that would still be compiled (#688 review round 7).
pub fn assemblerSlotComplete(allocator: std.mem.Allocator, slot: []const u8, companion_dir: []const u8) bool {
    for (ASSEMBLER_SUBDIRS) |subdir| {
        const src = std.fs.path.join(allocator, &.{ companion_dir, subdir }) catch return false;
        defer allocator.free(src);
        if (!pathExists(src)) {
            const stale = std.fs.path.join(allocator, &.{ slot, subdir }) catch return false;
            defer allocator.free(stale);
            if (pathExists(stale) or isSymlinkPath(stale)) return false;
            continue;
        }

        const dst = std.fs.path.join(allocator, &.{ slot, subdir }) catch return false;
        defer allocator.free(dst);
        if (!pathExists(dst)) return false;
    }
    return true;
}

/// A populated slot counts as active only when its provenance marker names
/// EXACTLY the checkout this project would populate it from (#688 review).
/// Several things go wrong with anything weaker:
///
///   * one `LABELLE_HOME` shared between monorepo clones or worktrees lets
///     clone A's sources satisfy a build run out of clone B, silently;
///   * a plugin slot is keyed by `.repo` but populated from
///     `labelle-<.name>`, so "any sibling of this monorepo" would let two
///     projects sharing a repo compile each other's checkouts; and
///   * the marker is the only thing `populate*` writes, so requiring it is
///     also what stops any other directory — a fetched archive included —
///     from passing as a local checkout.
fn activeOrFree(allocator: std.mem.Allocator, slot: []const u8, expected_source: []const u8) ?[]const u8 {
    if (pathExists(slot) and populatedFrom(allocator, slot, expected_source)) return slot;
    allocator.free(slot);
    return null;
}

fn populatedFrom(allocator: std.mem.Allocator, slot: []const u8, expected_source: []const u8) bool {
    const origin = readOrigin(allocator, slot) orelse return false;
    defer origin.deinit(allocator);
    return samePath(allocator, origin.source, expected_source);
}

/// Path equality that survives symlinked/relative spellings of the same
/// directory. Falls back to the textual answer when either side cannot be
/// canonicalised (a source checkout that has since been deleted, say).
fn samePath(allocator: std.mem.Allocator, a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const canon_a = cwd.realPathFileAlloc(io, a, allocator) catch return false;
    defer allocator.free(canon_a);
    const canon_b = cwd.realPathFileAlloc(io, b, allocator) catch return false;
    defer allocator.free(canon_b);
    return std.mem.eql(u8, canon_a, canon_b);
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

/// Record where a local slot came from.
///
/// NOT best-effort (#688 review round 2): every resolver requires the
/// marker before activating a slot, so a marker that silently failed to
/// write would leave `install` reporting success while the next generate
/// ignored the slot and resolved a version-named directory that does not
/// exist. A slot without provenance is not a usable slot, so the failure
/// belongs to population.
pub fn writeOrigin(
    allocator: std.mem.Allocator,
    slot: []const u8,
    source_dir: []const u8,
    pinned_version: []const u8,
) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const path = try originPath(allocator, slot);
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |parent| {
        cwd.createDirPath(io, parent) catch |err| {
            std.log.warn("labelle: could not create provenance directory '{s}': {any}", .{ parent, err });
            return error.CachePopulationFailed;
        };
    }

    const revision = gitRevision(allocator, source_dir) orelse
        try allocator.dupe(u8, "unknown");
    defer allocator.free(revision);

    const body = try std.fmt.allocPrint(
        allocator,
        "# labelle local cache slot (#685) — NOT a released version\n" ++
            "source = {s}\nrevision = {s}\npinned = {s}\n",
        .{ source_dir, revision, pinned_version },
    );
    defer allocator.free(body);

    const file = cwd.createFile(io, path, .{}) catch |err| {
        std.log.warn("labelle: could not write provenance marker '{s}': {any}", .{ path, err });
        return error.CachePopulationFailed;
    };
    defer file.close(io);
    file.writeStreamingAll(io, body) catch |err| {
        std.log.warn("labelle: could not write provenance marker '{s}': {any}", .{ path, err });
        return error.CachePopulationFailed;
    };
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
        // Only the FIRST line is the `gitdir:` entry — a linkfile may carry
        // further keys (mirrors resolveProjectRoot in resolve.zig).
        const eol = std.mem.indexOfAny(u8, linkfile, "\r\n") orelse linkfile.len;
        const trimmed = std.mem.trim(u8, linkfile[0..eol], " \t");
        if (std.mem.startsWith(u8, trimmed, "gitdir:")) {
            const target = std.mem.trim(u8, trimmed["gitdir:".len..], " \t");
            // git accepts a RELATIVE gitdir and resolves it against the
            // directory holding the `.git` file. Submodules always write one;
            // `worktree.useRelativePaths` / `git worktree add --relative-paths`
            // makes worktrees write one too. Taken verbatim it would resolve
            // against the process CWD and every read below would miss, so the
            // revision would silently degrade to "unknown" (#688 review).
            const owned = if (std.fs.path.isAbsolute(target))
                allocator.dupe(u8, target) catch return null
            else
                std.fs.path.join(allocator, &.{ source_dir, target }) catch return null;
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

    // A main checkout keeps its refs in `.git/<ref>`; try that first.
    if (readRef(allocator, git_dir, ref)) |sha| return sha;

    // A LINKED worktree does not: its per-worktree gitdir holds HEAD, but the
    // branch ref lives in the common git dir named by `<gitdir>/commondir`.
    // Without following it every worktree build recorded `refs/heads/<branch>`
    // instead of a commit, and the recorded "revision" never moved as commits
    // landed (#688 review).
    if (readCommonDir(allocator, git_dir)) |common| {
        defer allocator.free(common);
        if (readRef(allocator, common, ref)) |sha| return sha;
    }

    // Fall back to naming the branch — better than "unknown" for a
    // packed-refs checkout.
    return allocator.dupe(u8, ref) catch null;
}

/// `<git_dir>/<ref>` as a trimmed SHA, or null when it isn't a loose ref.
fn readRef(allocator: std.mem.Allocator, git_dir: []const u8, ref: []const u8) ?[]const u8 {
    const path = std.fs.path.join(allocator, &.{ git_dir, ref }) catch return null;
    defer allocator.free(path);
    const sha = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, allocator, .limited(4096)) catch return null;
    defer allocator.free(sha);
    return allocator.dupe(u8, std.mem.trim(u8, sha, " \t\r\n")) catch null;
}

/// The common git directory for a linked worktree, read from
/// `<git_dir>/commondir`. Relative values resolve against `git_dir`.
fn readCommonDir(allocator: std.mem.Allocator, git_dir: []const u8) ?[]const u8 {
    const path = std.fs.path.join(allocator, &.{ git_dir, "commondir" }) catch return null;
    defer allocator.free(path);
    const raw = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), path, allocator, .limited(4096)) catch return null;
    defer allocator.free(raw);
    const target = std.mem.trim(u8, raw, " \t\r\n");
    if (target.len == 0) return null;
    if (std.fs.path.isAbsolute(target)) return allocator.dupe(u8, target) catch null;
    return std.fs.path.join(allocator, &.{ git_dir, target }) catch null;
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

    // The marker sits beside the slot ROOT, so a resolved subpath
    // (`…/assembler/local/backends/sokol`) has to be trimmed back to it
    // before the lookup — otherwise every bundled package fell through to
    // the path-only message and dropped source and revision (#688 review).
    if (localSlotRoot(allocator, path)) |slot_root| {
        defer allocator.free(slot_root);
        if (readOrigin(allocator, slot_root)) |origin| {
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

/// Point LABELLE_HOME at `home` for the duration of a test; the caller
/// restores the returned Environ. PosixBlock-only, so callers skip on
/// Windows.
fn setTestCacheHome(envp: *const [1:null]?[*:0]const u8) std.process.Environ {
    const saved = std.testing.environ;
    std.testing.environ = .{ .block = .{ .slice = envp } };
    return saved;
}

test "localSlotRoot: the reserved namespace, subpaths inside it, and nothing else" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A genuine extracted release, a plugin whose OWNER is literally called
    // `local`, and a version slot for the git ref `local` — none of which is
    // a local slot — beside the reserved namespace, which is.
    try tmp.dir.createDirPath(std.testing.io, "home/packages/gfx/1.29.0");
    try tmp.dir.createDirPath(std.testing.io, "home/packages/gfx/local");
    try tmp.dir.createDirPath(std.testing.io, "home/packages/plugins/github.com/local/foo/1.0.0");
    try tmp.dir.createDirPath(std.testing.io, "home/packages/local/assembler/backends");
    try tmp.dir.createDirPath(std.testing.io, "checkout");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);
    const checkout = try tmp.dir.realPathFileAlloc(std.testing.io, "checkout", alloc);
    defer alloc.free(checkout);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer std.testing.environ = saved_environ;

    const gfx_slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(gfx_slot);
    try std.Io.Dir.cwd().symLink(std.testing.io, checkout, gfx_slot, .{ .is_directory = true });
    try writeOrigin(alloc, gfx_slot, checkout, "1.29.0");

    const asm_slot = try assemblerSlot(alloc);
    defer alloc.free(asm_slot);
    try writeOrigin(alloc, asm_slot, checkout, "1.2.3");

    // Recognised: the slot itself, and a subpath inside one — trimmed back to
    // the slot root so the marker is read beside it, not beside the subpath.
    try std.testing.expect(isLocalSlotPath(alloc, gfx_slot));

    const sub = try std.fs.path.join(alloc, &.{ asm_slot, "backends", "sokol" });
    defer alloc.free(sub);
    const root = localSlotRoot(alloc, sub) orelse return error.TestUnexpectedResult;
    defer alloc.free(root);
    try std.testing.expectEqualStrings(asm_slot, root);

    // Not recognised: a genuine release slot …
    const release = try std.fs.path.join(alloc, &.{ home, "packages", "gfx", "1.29.0" });
    defer alloc.free(release);
    try std.testing.expect(!isLocalSlotPath(alloc, release));

    // … the cache slot for the git REF named `local`, which is an ordinary
    // version path and must stay one (#688 review round 2) …
    const ref_slot = try std.fs.path.join(alloc, &.{ home, "packages", "gfx", "local" });
    defer alloc.free(ref_slot);
    try std.testing.expect(!isLocalSlotPath(alloc, ref_slot));

    // … a plugin whose repo OWNER happens to be named `local` …
    const owner_local = try std.fs.path.join(alloc, &.{ home, "packages", "plugins", "github.com", "local", "foo", "1.0.0" });
    defer alloc.free(owner_local);
    try std.testing.expect(!isLocalSlotPath(alloc, owner_local));

    // … and nothing outside the packages dir at all.
    try std.testing.expect(!isLocalSlotPath(alloc, "/usr/local/share/whatever"));
}

test "localSlotRoot: a cache home containing a `local` component is not a local slot (#688 review)" {
    // The regression the reviewers named: `LABELLE_HOME=/usr/local/labelle`
    // made EVERY version slot classify as locally sourced, so genuine releases
    // were reported as "built from LOCAL sources" and users were pointed at a
    // destructive cleanup.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "usr/local/labelle/packages/gfx/1.29.0");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "usr/local/labelle", alloc);
    defer alloc.free(home);
    try std.testing.expect(std.mem.indexOf(u8, home, "/local/") != null);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer std.testing.environ = saved_environ;

    const release = try std.fs.path.join(alloc, &.{ home, "packages", "gfx", "1.29.0" });
    defer alloc.free(release);
    try std.testing.expect(!isLocalSlotPath(alloc, release));
}

test "activeFrameworkSlot: a slot populated from ANOTHER checkout is not honoured (#688 review)" {
    // One shared LABELLE_HOME, two monorepo clones. A slot populated from
    // clone A must not satisfy a build run out of clone B — B's siblings can
    // be at completely different revisions.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/packages/local");
    try tmp.dir.createDirPath(std.testing.io, "clone-a/labelle-core");
    try tmp.dir.createDirPath(std.testing.io, "clone-a/labelle-gfx");
    try tmp.dir.createDirPath(std.testing.io, "clone-b/labelle-core");
    try tmp.dir.createDirPath(std.testing.io, "clone-b/labelle-assembler/zig-out/bin");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);
    const src_a = try tmp.dir.realPathFileAlloc(std.testing.io, "clone-a/labelle-gfx", alloc);
    defer alloc.free(src_a);
    const bin_b = try tmp.dir.realPathFileAlloc(std.testing.io, "clone-b/labelle-assembler/zig-out/bin", alloc);
    defer alloc.free(bin_b);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer std.testing.environ = saved_environ;

    // Populated from clone A.
    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);
    try std.Io.Dir.cwd().symLink(std.testing.io, src_a, slot, .{ .is_directory = true });
    try writeOrigin(alloc, slot, src_a, "1.29.0");

    // Running out of clone B: not honoured.
    {
        setProbeStartForTesting(bin_b);
        defer setProbeStartForTesting(null);
        try std.testing.expect(try activeFrameworkSlot(alloc, "gfx") == null);
    }

    // Running out of clone A: honoured.
    try tmp.dir.createDirPath(std.testing.io, "clone-a/labelle-assembler/zig-out/bin");
    const bin_a = try tmp.dir.realPathFileAlloc(std.testing.io, "clone-a/labelle-assembler/zig-out/bin", alloc);
    defer alloc.free(bin_a);
    setProbeStartForTesting(bin_a);
    defer setProbeStartForTesting(null);
    const active = try activeFrameworkSlot(alloc, "gfx") orelse return error.TestUnexpectedResult;
    defer alloc.free(active);
    try std.testing.expectEqualStrings(slot, active);
}

test "resolveFrameworkPackage: the git ref `local` resolves to its own version slot, not the local slot (#688 review)" {
    // `versionToGitRef` passes non-semver versions through verbatim, so
    // `local` is a supported ref. While local slots lived at
    // `<package>/local` its cache path WAS the reserved slot, and a released
    // assembler — with no slot active, so no provenance gate to apply —
    // resolved a `local` pin straight onto the monorepo-populated directory
    // and reported it cached. The reserved namespace makes the two paths
    // disjoint by construction.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/packages/local");
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-core");
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-gfx");
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-assembler/zig-out/bin");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);
    const src = try tmp.dir.realPathFileAlloc(std.testing.io, "toolkit/labelle-gfx", alloc);
    defer alloc.free(src);
    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer std.testing.environ = saved_environ;

    // A populated local slot, exactly as a monorepo-run assembler leaves it.
    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);
    try std.Io.Dir.cwd().symLink(std.testing.io, src, slot, .{ .is_directory = true });
    try writeOrigin(alloc, slot, src, "1.29.0");

    // A released binary, outside the monorepo, pinned to the ref `local`.
    setProbeStartForTesting(null);
    const resolve = @import("resolve.zig");
    const path = try resolve.resolveFrameworkPackage(alloc, "gfx", SLOT_NS, null);
    defer alloc.free(path);

    const expected = try std.fs.path.join(alloc, &.{ home, "packages", "gfx", SLOT_NS });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, path);
    try std.testing.expect(!isLocalSlotPath(alloc, path));
    try std.testing.expect(!std.mem.eql(u8, path, slot));

    // And it is NOT reported cached just because the local slot exists — the
    // ref has to be fetched.
    try std.testing.expect(!try resolve.isFrameworkCached(alloc, "gfx", SLOT_NS));
}

test "activeAssemblerSlot: an incomplete slot is refused so it gets repopulated (#688 review)" {
    // A slot populated while the checkout still lacked `gui` must not go on
    // reporting the assembler cached once the checkout grows one — the
    // version-named slot used to get this for free by changing name.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/packages/local/assembler/backends");
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-core");
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-assembler/backends");
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-assembler/zig-out/bin");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);
    const companion = try tmp.dir.realPathFileAlloc(std.testing.io, "toolkit/labelle-assembler", alloc);
    defer alloc.free(companion);
    const bin = try tmp.dir.realPathFileAlloc(std.testing.io, "toolkit/labelle-assembler/zig-out/bin", alloc);
    defer alloc.free(bin);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer std.testing.environ = saved_environ;

    const slot = try assemblerSlot(alloc);
    defer alloc.free(slot);
    try writeOrigin(alloc, slot, companion, "1.2.3");

    setProbeStartForTesting(bin);
    defer setProbeStartForTesting(null);

    // Matched contents: active.
    {
        const active = try activeAssemblerSlot(alloc) orelse return error.TestUnexpectedResult;
        defer alloc.free(active);
        try std.testing.expectEqualStrings(slot, active);
    }

    // The checkout grows a `gui/` the slot doesn't have: refused.
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-assembler/gui");
    try std.testing.expect(try activeAssemblerSlot(alloc) == null);
}

test "originPath: mirrors the slot tree into the marker namespace" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const home_env = "LABELLE_HOME=/c";
    const envp = [_:null]?[*:0]const u8{home_env};
    const saved_environ = setTestCacheHome(&envp);
    defer std.testing.environ = saved_environ;

    const framework = try originPath(alloc, "/c/packages/local/gfx");
    defer alloc.free(framework);
    try std.testing.expectEqualStrings("/c/packages/local.origins/gfx", framework);

    // A repo whose NAME ends in `.origin` gets its own marker path — with a
    // `<slot>.origin` sibling the two would have collided (#688 review).
    const a = try originPath(alloc, "/c/packages/local/plugins/github.com/acme/foo");
    defer alloc.free(a);
    const b = try originPath(alloc, "/c/packages/local/plugins/github.com/acme/foo.origin");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("/c/packages/local.origins/plugins/github.com/acme/foo", a);
    try std.testing.expect(!std.mem.eql(u8, a, "/c/packages/local/plugins/github.com/acme/foo.origin"));
    try std.testing.expect(!std.mem.eql(u8, a, b));

    // Anything outside the slot namespace has no marker path at all.
    try std.testing.expectError(error.InvalidSlotPath, originPath(alloc, "/c/packages/gfx/1.29.0"));
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

/// Write `body` to `rel` inside `dir`, creating parent directories.
fn writeFileAt(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(rel)) |parent| try dir.createDirPath(std.testing.io, parent);
    const file = try dir.createFile(std.testing.io, rel, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, body);
}

test "gitRevision: a main checkout reports its loose ref" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFileAt(tmp.dir, "repo/.git/HEAD", "ref: refs/heads/main\n");
    try writeFileAt(tmp.dir, "repo/.git/refs/heads/main", "1111111111111111111111111111111111111111\n");

    const repo = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", alloc);
    defer alloc.free(repo);

    const rev = gitRevision(alloc, repo) orelse return error.TestUnexpectedResult;
    defer alloc.free(rev);
    try std.testing.expectEqualStrings("1111111111111111111111111111111111111111", rev);
}

test "gitRevision: a worktree with a RELATIVE gitdir resolves through commondir (#688 review)" {
    // Two defects in one layout: `gitdir:` is relative (git writes one for
    // submodules, and for worktrees under `worktree.useRelativePaths`), so
    // taken verbatim every read below resolves against the process CWD; and
    // the branch ref lives in the COMMON git dir, not the per-worktree one,
    // so the revision degraded to the branch NAME and stopped tracking
    // commits.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFileAt(tmp.dir, "main/.git/HEAD", "ref: refs/heads/main\n");
    try writeFileAt(tmp.dir, "main/.git/refs/heads/feature", "2222222222222222222222222222222222222222\n");
    try writeFileAt(tmp.dir, "main/.git/worktrees/wt/HEAD", "ref: refs/heads/feature\n");
    try writeFileAt(tmp.dir, "main/.git/worktrees/wt/commondir", "../..\n");
    // Relative link back at the per-worktree gitdir.
    try writeFileAt(tmp.dir, "wt/.git", "gitdir: ../main/.git/worktrees/wt\n");

    const wt = try tmp.dir.realPathFileAlloc(std.testing.io, "wt", alloc);
    defer alloc.free(wt);

    const rev = gitRevision(alloc, wt) orelse return error.TestUnexpectedResult;
    defer alloc.free(rev);
    try std.testing.expectEqualStrings("2222222222222222222222222222222222222222", rev);
}

test "writeOrigin/readOrigin: round-trips provenance for a slot" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/packages/local");
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer std.testing.environ = saved_environ;

    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);

    try writeOrigin(alloc, slot, "/src/labelle-gfx", "1.29.0");

    const origin = readOrigin(alloc, slot) orelse return error.TestUnexpectedResult;
    defer origin.deinit(alloc);
    try std.testing.expectEqualStrings("/src/labelle-gfx", origin.source);
    try std.testing.expectEqualStrings("1.29.0", origin.pinned);
}

test "isFrameworkCached: a COPIED local slot is stale, so ensureCache repopulates it (#688 review)" {
    // `symlinkToCache` falls back to copying the checkout where directory
    // symlinks fail (Windows without developer mode). A copy is a snapshot:
    // source edits never reach it. The version-named slot at least got a
    // fresh copy whenever the pin moved; the reserved slot never changes
    // name, so it would be reused indefinitely unless the probe calls it out.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/packages/local/gfx");
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-core");
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-gfx");
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-assembler/zig-out/bin");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);
    const src = try tmp.dir.realPathFileAlloc(std.testing.io, "toolkit/labelle-gfx", alloc);
    defer alloc.free(src);
    const bin = try tmp.dir.realPathFileAlloc(std.testing.io, "toolkit/labelle-assembler/zig-out/bin", alloc);
    defer alloc.free(bin);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer std.testing.environ = saved_environ;

    setProbeStartForTesting(bin);
    defer setProbeStartForTesting(null);

    const resolve = @import("resolve.zig");
    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);

    // The slot as a COPY (a plain directory), with a valid marker: active,
    // but stale — so the probe reports it not cached.
    try writeOrigin(alloc, slot, src, "1.29.0");
    const active_copy = try activeFrameworkSlot(alloc, "gfx") orelse return error.TestUnexpectedResult;
    alloc.free(active_copy);
    try std.testing.expect(!try resolve.isFrameworkCached(alloc, "gfx", "1.29.0"));

    // The same slot as a symlink tracks its source, so it satisfies the pin.
    try std.Io.Dir.cwd().deleteTree(std.testing.io, slot);
    try std.Io.Dir.cwd().symLink(std.testing.io, src, slot, .{ .is_directory = true });
    try std.testing.expect(try resolve.isFrameworkCached(alloc, "gfx", "1.29.0"));
}

test "activePluginSlot: a slot populated for a DIFFERENT logical name is not honoured (#688 review)" {
    // A plugin slot is keyed by `.repo`, but `fetchPluginWithFallback`
    // populates it from `labelle-<.name>`. Two projects sharing a repo under
    // different logical names therefore expect different siblings — and both
    // checkouts can be present at different revisions — so "any direct child
    // of this monorepo" would let one compile the other's sources.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/packages/local");
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-core");
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-physics");
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-physics2");
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-assembler/zig-out/bin");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);
    const src = try tmp.dir.realPathFileAlloc(std.testing.io, "toolkit/labelle-physics", alloc);
    defer alloc.free(src);
    const bin = try tmp.dir.realPathFileAlloc(std.testing.io, "toolkit/labelle-assembler/zig-out/bin", alloc);
    defer alloc.free(bin);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer std.testing.environ = saved_environ;

    const repo = "github.com/labelle-toolkit/labelle-physics";
    const same: config.PluginDep = .{ .name = "physics", .repo = repo, .version = "0.4.0" };
    const slot = try pluginSlot(alloc, same);
    defer alloc.free(slot);
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), std.fs.path.dirname(slot).?);
    try std.Io.Dir.cwd().symLink(std.testing.io, src, slot, .{ .is_directory = true });
    try writeOrigin(alloc, slot, src, "0.4.0");

    setProbeStartForTesting(bin);
    defer setProbeStartForTesting(null);

    // The dep the slot was populated for: honoured.
    const active = try activePluginSlot(alloc, same) orelse return error.TestUnexpectedResult;
    alloc.free(active);

    // Same repo, different logical name — its own slot, unpopulated, so
    // nothing is served and the two never overwrite each other.
    const other: config.PluginDep = .{ .name = "physics2", .repo = repo, .version = "0.4.0" };
    const other_slot = try pluginSlot(alloc, other);
    defer alloc.free(other_slot);
    try std.testing.expect(!std.mem.eql(u8, slot, other_slot));
    try std.testing.expect(try activePluginSlot(alloc, other) == null);

    // And even if that slot existed, holding the WRONG checkout, it would
    // not be honoured: the marker must name `labelle-physics2`.
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), std.fs.path.dirname(other_slot).?);
    try std.Io.Dir.cwd().symLink(std.testing.io, src, other_slot, .{ .is_directory = true });
    try writeOrigin(alloc, other_slot, src, "0.4.0");
    try std.testing.expect(try activePluginSlot(alloc, other) == null);
}

test "writeOrigin: an unwritable marker fails population rather than reporting success (#688 review)" {
    // Every resolver requires the marker before activating a slot, so a
    // silently-skipped marker would leave `install` reporting success while
    // the next generate ignored the slot and resolved a version-named
    // directory that does not exist.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/packages/local");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer std.testing.environ = saved_environ;

    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);

    // Block the marker path with a directory so createFile cannot win.
    const marker = try originPath(alloc, slot);
    defer alloc.free(marker);
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), marker);

    try std.testing.expectError(error.CachePopulationFailed, writeOrigin(alloc, slot, home, "1.29.0"));
}

test "pluginSlot: no plugin identity can nest inside another's slot (#688 review)" {
    // Repo strings are unconstrained, so `<repo>/<name>` pairs could nest:
    // `{repo=github.com/acme/foo, name=bar}` and
    // `{repo=github.com/acme/foo/bar/baz, name=qux}` put the second slot
    // INSIDE the first — which is a symlink to a checkout, so populating the
    // second would write through it into the user's source tree.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const home_env = "LABELLE_HOME=/c";
    const envp = [_:null]?[*:0]const u8{home_env};
    const saved_environ = setTestCacheHome(&envp);
    defer std.testing.environ = saved_environ;

    const outer: config.PluginDep = .{ .name = "bar", .repo = "github.com/acme/foo", .version = "1.0.0" };
    const inner: config.PluginDep = .{ .name = "qux", .repo = "github.com/acme/foo/bar/baz", .version = "1.0.0" };

    const a = try pluginSlot(alloc, outer);
    defer alloc.free(a);
    const b = try pluginSlot(alloc, inner);
    defer alloc.free(b);

    try std.testing.expect(!std.mem.eql(u8, a, b));
    try std.testing.expect(!std.mem.startsWith(u8, b, a));
    try std.testing.expect(!std.mem.startsWith(u8, a, b));

    // One flat component under `plugins/`, so nesting is impossible by shape.
    const plugins_dir = try std.fs.path.join(alloc, &.{ "/c", "packages", SLOT_NS, "plugins" });
    defer alloc.free(plugins_dir);
    for ([_][]const u8{ a, b }) |slot| {
        try std.testing.expect(std.mem.startsWith(u8, slot, plugins_dir));
        const rel = slot[plugins_dir.len + 1 ..];
        try std.testing.expect(std.mem.indexOfAny(u8, rel, "/\\") == null);
    }

    // Same repo, different logical name still means different slots.
    const alias: config.PluginDep = .{ .name = "baz", .repo = outer.repo, .version = "1.0.0" };
    const c = try pluginSlot(alloc, alias);
    defer alloc.free(c);
    try std.testing.expect(!std.mem.eql(u8, a, c));
}

test "assemblerSlotComplete: a subdir the checkout dropped makes the slot stale (#688 review)" {
    // A leftover `gui/` — a stale copy, or a link whose target is gone —
    // would otherwise survive every repopulation and still be compiled.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "slot/backends");
    try tmp.dir.createDirPath(std.testing.io, "slot/gui");
    try tmp.dir.createDirPath(std.testing.io, "companion/backends");

    const slot = try tmp.dir.realPathFileAlloc(std.testing.io, "slot", alloc);
    defer alloc.free(slot);
    const companion = try tmp.dir.realPathFileAlloc(std.testing.io, "companion", alloc);
    defer alloc.free(companion);

    // The checkout has no `gui/`, the slot still does: stale.
    try std.testing.expect(!assemblerSlotComplete(alloc, slot, companion));

    // Drop it and the slot matches again.
    const stale = try std.fs.path.join(alloc, &.{ slot, "gui" });
    defer alloc.free(stale);
    try std.Io.Dir.cwd().deleteTree(config.globalIo(), stale);
    try std.testing.expect(assemblerSlotComplete(alloc, slot, companion));
}
