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
const junction = @import("../junction.zig");

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

/// The local slot for a framework package, when it should be used. Caller
/// owns the returned path.
///
/// Two ways a slot qualifies, and they are not interchangeable — a caller
/// must NOT assume the result is tied to the running assembler's own
/// checkout (#704 review):
///
///   * a DISCOVERED slot, only when it was populated from the very checkout
///     this assembler runs out of; and
///   * an EXPLICIT slot — `install <pkg> local:<path>` — wherever this
///     assembler runs, and whatever path it names.
///
/// Either way the source must still exist. See `Origin.Mode`.
pub fn activeFrameworkSlot(allocator: std.mem.Allocator, package: []const u8) !?[]const u8 {
    const expected = try discoveredSource(allocator, frameworkDirName(package));
    defer if (expected) |e| allocator.free(e);

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
    const dir_name = try pluginDirName(allocator, plugin.name);
    defer allocator.free(dir_name);

    const expected = try discoveredSource(allocator, dir_name);
    defer if (expected) |e| allocator.free(e);

    const slot = try pluginSlot(allocator, plugin);
    return activeOrFree(allocator, slot, expected);
}

/// The checkout an EXPLICIT override registered for `package`, if there is
/// one and it is still on disk. Caller owns the result.
///
/// Deliberately weaker than `activeFrameworkSlot`: it does not care whether
/// the slot still TRACKS that checkout. Answering while the slot is a stale
/// copy is the whole point — on Windows `symlinkToCache` falls back to
/// copying (`std.Io.Dir.symLink` needs SeCreateSymbolicLinkPrivilege, which
/// an ordinary account does not hold), and a copy that nothing refreshes
/// serves the sources as they were on install day, forever (#704).
pub fn explicitFrameworkSource(allocator: std.mem.Allocator, package: []const u8) !?[]const u8 {
    const slot = try frameworkSlot(allocator, package);
    defer allocator.free(slot);
    if (!pathExists(slot)) return null;

    const origin = readOrigin(allocator, slot) orelse return null;
    defer origin.deinit(allocator);
    if (origin.mode != .explicit) return null;
    if (!pathExists(origin.source)) return null;

    return try allocator.dupe(u8, origin.source);
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
    const expected = try discoveredSource(allocator, "labelle-assembler");
    defer if (expected) |e| allocator.free(e);

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
    if (!originActive(allocator, origin, expected) or
        !assemblerSlotComplete(allocator, slot, origin.source))
    {
        allocator.free(slot);
        return null;
    }
    return slot;
}

/// `<monorepo root>/<dir_name>` — the checkout auto-discovery would have
/// populated a slot from, or null when this assembler is not running inside
/// the monorepo at all (a released binary). Caller owns the result.
fn discoveredSource(allocator: std.mem.Allocator, dir_name: []const u8) !?[]const u8 {
    const root = findRepoRoot(allocator) orelse return null;
    defer allocator.free(root);
    return try std.fs.path.join(allocator, &.{ root, dir_name });
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

/// A DISCOVERED slot counts as active only when its provenance marker names
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
///
/// An EXPLICIT slot (#704) skips the source comparison: the user named the
/// path, so there is no silent substitution to defend against, and
/// `expected_source` is null anyway whenever the running binary is a
/// release rather than the monorepo's own. Requiring the marker, and
/// requiring the source to still exist, both still apply.
fn activeOrFree(allocator: std.mem.Allocator, slot: []const u8, expected_source: ?[]const u8) ?[]const u8 {
    if (!pathExists(slot)) {
        allocator.free(slot);
        return null;
    }
    const origin = readOrigin(allocator, slot) orelse {
        allocator.free(slot);
        return null;
    };
    defer origin.deinit(allocator);
    if (originActive(allocator, origin, expected_source)) return slot;
    allocator.free(slot);
    return null;
}

fn originActive(allocator: std.mem.Allocator, origin: Origin, expected_source: ?[]const u8) bool {
    // The source has to still BE there (#688 review round 8). `samePath`
    // falls back to a textual comparison when neither side canonicalises, so
    // a deleted checkout still "matches" its own recorded path — and a
    // COPIED slot (the Windows fallback) survives its source, staying active
    // while the probes fetch the release it is standing in for. An explicit
    // slot needs the check just as much: a checkout the user has since
    // deleted must fall back to the pinned release, not fail the build with
    // a dangling link.
    if (!pathExists(origin.source)) return false;
    if (origin.mode == .explicit) return true;
    const expected = expected_source orelse return false;
    return samePath(allocator, origin.source, expected);
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
    /// The version the slot's sources declare (`build.zig.zon`'s
    /// `.version`) for an explicit install, or the version that was pinned
    /// when auto-discovery populated it. Diagnostics only — the slot is NOT
    /// a released copy of that version either way.
    pinned: []const u8,
    /// How the slot came to be. See `Mode`.
    mode: Mode,

    /// Whether a human asked for these sources by path, or the assembler
    /// went looking for them (#704).
    ///
    /// The distinction is the activation rule. A `discovered` slot is only
    /// honoured by an assembler running out of the very monorepo the
    /// sources sit in, so a released binary resolves the pinned release and
    /// one shared `LABELLE_HOME` cannot leak one clone's sources into
    /// another clone's build — the #679/#685 guarantee.
    ///
    /// An `explicit` slot carries the user's own `install <pkg>
    /// local:<path>`, so there is no silent substitution to guard against
    /// and no monorepo to require: it activates wherever the assembler
    /// runs, which is the only way a RELEASED binary can build a project
    /// that needs unreleased framework sources (#704). Every build that
    /// resolves through one still warns (`warnIfLocallySourced`), and
    /// `labelle-assembler clean` drops it.
    ///
    /// Markers written before #704 carry no `mode` and read back as
    /// `discovered`, so no pre-existing slot changes behaviour.
    pub const Mode = enum {
        discovered,
        explicit,

        pub fn parse(text: []const u8) Mode {
            if (std.mem.eql(u8, text, "explicit")) return .explicit;
            return .discovered;
        }

        pub fn label(self: Mode) []const u8 {
            return switch (self) {
                .discovered => "discovered",
                .explicit => "explicit",
            };
        }
    };

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
    mode: Origin.Mode,
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
            "source = {s}\nrevision = {s}\npinned = {s}\nmode = {s}\n",
        .{ source_dir, revision, pinned_version, mode.label() },
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
    // Absent in markers written before #704: those slots were all
    // auto-discovered, which is exactly what `.discovered` means.
    const mode = Origin.Mode.parse(fieldValue(content, "mode") orelse "discovered");

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
    return .{ .source = source_owned, .revision = revision_owned, .pinned = pinned_owned, .mode = mode };
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

test "localSlotRoot: the reserved namespace, subpaths inside it, and nothing else" {
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

    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    const gfx_slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(gfx_slot);
    try junction.linkDir(alloc, checkout, gfx_slot);
    try writeOrigin(alloc, gfx_slot, checkout, "1.29.0", .discovered);

    const asm_slot = try assemblerSlot(alloc);
    defer alloc.free(asm_slot);
    try writeOrigin(alloc, asm_slot, checkout, "1.2.3", .discovered);

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
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "usr/local/labelle/packages/gfx/1.29.0");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "usr/local/labelle", alloc);
    defer alloc.free(home);
    // The `local` component, spelled with the HOST separator — a literal
    // "/local/" is absent from a Windows realpath, so the test would fail
    // on its own precondition rather than on the behaviour (#699).
    const local_component = std.fs.path.sep_str ++ "local" ++ std.fs.path.sep_str;
    try std.testing.expect(std.mem.indexOf(u8, home, local_component) != null);

    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    const release = try std.fs.path.join(alloc, &.{ home, "packages", "gfx", "1.29.0" });
    defer alloc.free(release);
    try std.testing.expect(!isLocalSlotPath(alloc, release));
}

test "activeFrameworkSlot: a slot populated from ANOTHER checkout is not honoured (#688 review)" {
    // One shared LABELLE_HOME, two monorepo clones. A slot populated from
    // clone A must not satisfy a build run out of clone B — B's siblings can
    // be at completely different revisions.
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

    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    // Populated from clone A.
    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);
    try junction.linkDir(alloc, src_a, slot);
    try writeOrigin(alloc, slot, src_a, "1.29.0", .discovered);

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
    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    // A populated local slot, exactly as a monorepo-run assembler leaves it.
    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);
    try junction.linkDir(alloc, src, slot);
    try writeOrigin(alloc, slot, src, "1.29.0", .discovered);

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

    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    const slot = try assemblerSlot(alloc);
    defer alloc.free(slot);
    try writeOrigin(alloc, slot, companion, "1.2.3", .discovered);

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
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(root);

    env.setCacheRootForTesting(root);
    defer env.setCacheRootForTesting(null);

    // Every path here is JOINED rather than written with `/`. The cache root
    // joins with `\` on Windows, so a hardcoded POSIX literal fails
    // `originPath`'s namespace prefix check for a reason that has nothing to
    // do with the behaviour under test (#699).
    const slot = try std.fs.path.join(alloc, &.{ root, "packages", "local", "gfx" });
    defer alloc.free(slot);
    const want = try std.fs.path.join(alloc, &.{ root, "packages", "local.origins", "gfx" });
    defer alloc.free(want);

    const framework = try originPath(alloc, slot);
    defer alloc.free(framework);
    try std.testing.expectEqualStrings(want, framework);

    // A repo whose NAME ends in `.origin` gets its own marker path — with a
    // `<slot>.origin` sibling the two would have collided (#688 review).
    const repo = try std.fs.path.join(alloc, &.{ root, "packages", "local", "plugins", "github.com", "acme", "foo" });
    defer alloc.free(repo);
    const repo_origin = try std.fs.path.join(alloc, &.{ root, "packages", "local", "plugins", "github.com", "acme", "foo.origin" });
    defer alloc.free(repo_origin);

    const a = try originPath(alloc, repo);
    defer alloc.free(a);
    const b = try originPath(alloc, repo_origin);
    defer alloc.free(b);

    const want_a = try std.fs.path.join(alloc, &.{ root, "packages", "local.origins", "plugins", "github.com", "acme", "foo" });
    defer alloc.free(want_a);
    try std.testing.expectEqualStrings(want_a, a);
    try std.testing.expect(!std.mem.eql(u8, a, repo_origin));
    try std.testing.expect(!std.mem.eql(u8, a, b));

    // Anything outside the slot namespace has no marker path at all.
    const outside = try std.fs.path.join(alloc, &.{ root, "packages", "gfx", "1.29.0" });
    defer alloc.free(outside);
    try std.testing.expectError(error.InvalidSlotPath, originPath(alloc, outside));
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
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/packages/local");
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);

    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);

    try writeOrigin(alloc, slot, "/src/labelle-gfx", "1.29.0", .discovered);

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

    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    setProbeStartForTesting(bin);
    defer setProbeStartForTesting(null);

    const resolve = @import("resolve.zig");
    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);

    // The slot as a COPY (a plain directory), with a valid marker: active,
    // but stale — so the probe reports it not cached.
    try writeOrigin(alloc, slot, src, "1.29.0", .discovered);
    const active_copy = try activeFrameworkSlot(alloc, "gfx") orelse return error.TestUnexpectedResult;
    alloc.free(active_copy);
    try std.testing.expect(!try resolve.isFrameworkCached(alloc, "gfx", "1.29.0"));

    // The same slot as a symlink tracks its source, so it satisfies the pin.
    try std.Io.Dir.cwd().deleteTree(std.testing.io, slot);
    try junction.linkDir(alloc, src, slot);
    try std.testing.expect(try resolve.isFrameworkCached(alloc, "gfx", "1.29.0"));
}

test "activePluginSlot: a slot populated for a DIFFERENT logical name is not honoured (#688 review)" {
    // A plugin slot is keyed by `.repo`, but `fetchPluginWithFallback`
    // populates it from `labelle-<.name>`. Two projects sharing a repo under
    // different logical names therefore expect different siblings — and both
    // checkouts can be present at different revisions — so "any direct child
    // of this monorepo" would let one compile the other's sources.
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

    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    const repo = "github.com/labelle-toolkit/labelle-physics";
    const same: config.PluginDep = .{ .name = "physics", .repo = repo, .version = "0.4.0" };
    const slot = try pluginSlot(alloc, same);
    defer alloc.free(slot);
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), std.fs.path.dirname(slot).?);
    try junction.linkDir(alloc, src, slot);
    try writeOrigin(alloc, slot, src, "0.4.0", .discovered);

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
    try junction.linkDir(alloc, src, other_slot);
    try writeOrigin(alloc, other_slot, src, "0.4.0", .discovered);
    try std.testing.expect(try activePluginSlot(alloc, other) == null);
}

test "writeOrigin: an unwritable marker fails population rather than reporting success (#688 review)" {
    // Every resolver requires the marker before activating a slot, so a
    // silently-skipped marker would leave `install` reporting success while
    // the next generate ignored the slot and resolved a version-named
    // directory that does not exist.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/packages/local");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);

    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);

    // Block the marker path with a directory so createFile cannot win.
    const marker = try originPath(alloc, slot);
    defer alloc.free(marker);
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), marker);

    try std.testing.expectError(error.CachePopulationFailed, writeOrigin(alloc, slot, home, "1.29.0", .discovered));
}

test "pluginSlot: no plugin identity can nest inside another's slot (#688 review)" {
    // Repo strings are unconstrained, so `<repo>/<name>` pairs could nest:
    // `{repo=github.com/acme/foo, name=bar}` and
    // `{repo=github.com/acme/foo/bar/baz, name=qux}` put the second slot
    // INSIDE the first — which is a symlink to a checkout, so populating the
    // second would write through it into the user's source tree.
    const alloc = std.testing.allocator;

    env.setCacheRootForTesting("/c");
    defer env.setCacheRootForTesting(null);

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

test "activeFrameworkSlot: a slot whose source checkout is gone is not honoured (#688 review)" {
    // `samePath` falls back to a textual comparison when neither side
    // canonicalises, so a deleted checkout still matches its own recorded
    // path. A COPIED slot (the Windows fallback) then outlives its source and
    // stays active while the probes fetch the release it stands in for.
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

    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    setProbeStartForTesting(bin);
    defer setProbeStartForTesting(null);

    // A COPIED slot (a real directory, as the Windows fallback leaves it).
    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);
    try writeOrigin(alloc, slot, src, "1.29.0", .discovered);

    const active = try activeFrameworkSlot(alloc, "gfx") orelse return error.TestUnexpectedResult;
    alloc.free(active);

    // The checkout goes away; the copy and its marker do not.
    try std.Io.Dir.cwd().deleteTree(std.testing.io, src);
    try std.testing.expect(try activeFrameworkSlot(alloc, "gfx") == null);
}

test "readOrigin: a marker written before #704 has no mode and reads back discovered" {
    // The mode field is additive. Every slot that exists today was
    // auto-discovered, and reading one as `.explicit` would hand a released
    // binary the monorepo sources #679 was filed about.
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/packages/local");
    try tmp.dir.createDirPath(std.testing.io, "home/packages/local.origins");
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);

    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);
    const marker = try originPath(alloc, slot);
    defer alloc.free(marker);

    const legacy =
        "# labelle local cache slot (#685) — NOT a released version\n" ++
        "source = /src/labelle-gfx\nrevision = deadbeef\npinned = 1.29.0\n";
    const file = try std.Io.Dir.cwd().createFile(std.testing.io, marker, .{});
    try file.writeStreamingAll(std.testing.io, legacy);
    file.close(std.testing.io);

    const origin = readOrigin(alloc, slot) orelse return error.TestUnexpectedResult;
    defer origin.deinit(alloc);
    try std.testing.expectEqual(Origin.Mode.discovered, origin.mode);
}

test "writeOrigin/readOrigin: round-trips an explicit mode" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "home/packages/local");
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);

    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);

    try writeOrigin(alloc, slot, "/src/labelle-gfx", "1.30.0", .explicit);

    const origin = readOrigin(alloc, slot) orelse return error.TestUnexpectedResult;
    defer origin.deinit(alloc);
    try std.testing.expectEqual(Origin.Mode.explicit, origin.mode);
    // `pinned` is a VERSION, not the `local:` spec the user typed (#704).
    try std.testing.expectEqualStrings("1.30.0", origin.pinned);
}

test "activeFrameworkSlot: an explicit override activates outside the monorepo, a discovered one does not (#704)" {
    // The reason the feature exists. `labelle` shells out to the RELEASED
    // ~/.labelle/bin/labelle-assembler, where `findRepoRoot` finds nothing,
    // so a slot that only activates inside the monorepo can never build a
    // project pinned to unreleased framework sources — which is what left
    // #704's reporter unable to build at all.
    //
    // The other half is the guard that must survive: a DISCOVERED slot
    // stays inert out here, so no released binary ever picks up a monorepo
    // checkout nobody asked it to build (#679/#685).
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/packages/local");
    try tmp.dir.createDirPath(std.testing.io, "checkout");
    // Somewhere with no `labelle-core` sibling anywhere above it: a
    // released binary's directory.
    try tmp.dir.createDirPath(std.testing.io, "elsewhere/bin");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);
    const src = try tmp.dir.realPathFileAlloc(std.testing.io, "checkout", alloc);
    defer alloc.free(src);
    const bin = try tmp.dir.realPathFileAlloc(std.testing.io, "elsewhere/bin", alloc);
    defer alloc.free(bin);

    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    setProbeStartForTesting(bin);
    defer setProbeStartForTesting(null);
    try std.testing.expect(findRepoRoot(alloc) == null);

    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);
    try junction.linkDir(alloc, src, slot);

    try writeOrigin(alloc, slot, src, "1.30.0", .explicit);
    const active = try activeFrameworkSlot(alloc, "gfx") orelse return error.TestUnexpectedResult;
    alloc.free(active);

    // Same slot, same source, marked as auto-discovered: inert.
    try writeOrigin(alloc, slot, src, "1.30.0", .discovered);
    try std.testing.expect(try activeFrameworkSlot(alloc, "gfx") == null);
}

test "activeFrameworkSlot: an explicit override whose checkout is gone falls back to the pin (#704)" {
    // A deleted source must not leave a dangling slot standing in for a
    // release: the build would resolve a path that isn't there.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/packages/local");
    try tmp.dir.createDirPath(std.testing.io, "checkout");
    try tmp.dir.createDirPath(std.testing.io, "elsewhere/bin");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);
    const src = try tmp.dir.realPathFileAlloc(std.testing.io, "checkout", alloc);
    defer alloc.free(src);
    const bin = try tmp.dir.realPathFileAlloc(std.testing.io, "elsewhere/bin", alloc);
    defer alloc.free(bin);

    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    setProbeStartForTesting(bin);
    defer setProbeStartForTesting(null);

    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);
    try junction.linkDir(alloc, src, slot);
    try writeOrigin(alloc, slot, src, "1.30.0", .explicit);

    try std.Io.Dir.cwd().deleteTree(std.testing.io, src);
    try std.testing.expect(try activeFrameworkSlot(alloc, "gfx") == null);
}

test "explicitFrameworkSource: names the checkout for an explicit slot only (#704)" {
    // `ensureCache` uses this to REFRESH a slot the platform copied rather
    // than linked, so — unlike `activeFrameworkSlot` — it must answer for a
    // slot that no longer tracks its source. It must stay silent for a
    // discovered slot, which auto-discovery already repopulates.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The slot as a plain directory: what the Windows copy fallback leaves.
    try tmp.dir.createDirPath(std.testing.io, "home/packages/local/gfx");
    try tmp.dir.createDirPath(std.testing.io, "checkout");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);
    const src = try tmp.dir.realPathFileAlloc(std.testing.io, "checkout", alloc);
    defer alloc.free(src);

    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);
    try std.testing.expect(!slotTracksSource(slot));

    try writeOrigin(alloc, slot, src, "1.30.0", .explicit);
    const found = try explicitFrameworkSource(alloc, "gfx") orelse return error.TestUnexpectedResult;
    defer alloc.free(found);
    try std.testing.expectEqualStrings(src, found);

    try writeOrigin(alloc, slot, src, "1.30.0", .discovered);
    try std.testing.expect(try explicitFrameworkSource(alloc, "gfx") == null);

    // No marker at all is not an override either.
    try writeOrigin(alloc, slot, src, "1.30.0", .explicit);
    const marker = try originPath(alloc, slot);
    defer alloc.free(marker);
    try std.Io.Dir.cwd().deleteTree(std.testing.io, marker);
    try std.testing.expect(try explicitFrameworkSource(alloc, "gfx") == null);
}

test "populateFrameworkPackage: a failed marker write drops the slot rather than leaving it unmarked (#704 review)" {
    // `symlinkToCache` may have just REPOINTED an existing slot at a new
    // source. If the marker write then fails, the slot serves source B
    // while the retained marker still names source A — and an explicit
    // marker is trusted without a source comparison, so nothing would ever
    // catch it. A link-backed slot is never refreshed either, so the two
    // would never reconcile. No slot at all is the honest outcome.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/packages/local");
    try tmp.dir.createDirPath(std.testing.io, "checkout-a");
    try tmp.dir.createDirPath(std.testing.io, "checkout-b");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);
    const src_a = try tmp.dir.realPathFileAlloc(std.testing.io, "checkout-a", alloc);
    defer alloc.free(src_a);
    const src_b = try tmp.dir.realPathFileAlloc(std.testing.io, "checkout-b", alloc);
    defer alloc.free(src_b);

    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    const disk = @import("disk.zig");
    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);

    // A good explicit slot on checkout A.
    try disk.populateFrameworkPackage(alloc, "gfx", "1.30.0", src_a, .explicit);
    try std.testing.expect(pathExists(slot));

    // Now block the marker path and repopulate from checkout B.
    const marker = try originPath(alloc, slot);
    defer alloc.free(marker);
    try std.Io.Dir.cwd().deleteTree(config.globalIo(), marker);
    try std.Io.Dir.cwd().createDirPath(config.globalIo(), marker);

    try std.testing.expectError(
        error.CachePopulationFailed,
        disk.populateFrameworkPackage(alloc, "gfx", "1.30.0", src_b, .explicit),
    );

    // The slot is gone, so nothing resolves through unmatched provenance...
    try std.testing.expect(!pathExists(slot));
    try std.testing.expect(try activeFrameworkSlot(alloc, "gfx") == null);
    // ...and both checkouts are untouched (deleteTree drops a symlink, it
    // does not recurse through it).
    try std.testing.expect(pathExists(src_a));
    try std.testing.expect(pathExists(src_b));
}

test "isDirectory: a regular file is not a checkout, however accessible (#704 review)" {
    // `dirExists` only calls `access`, so it says yes to a plain file. That
    // file used to be linked into the cache as a framework package.
    const alloc = std.testing.allocator;
    _ = alloc;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "a-dir");
    const file = try tmp.dir.createFile(std.testing.io, "a-file", .{});
    file.close(std.testing.io);

    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var file_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp.dir.realPathFile(std.testing.io, "a-dir", &dir_buf)];
    const file_path = file_buf[0..try tmp.dir.realPathFile(std.testing.io, "a-file", &file_buf)];

    const disk = @import("disk.zig");
    try std.testing.expect(disk.dirExists(dir_path));
    try std.testing.expect(disk.isDirectory(dir_path));

    // The discriminating case.
    try std.testing.expect(disk.dirExists(file_path));
    try std.testing.expect(!disk.isDirectory(file_path));

    try std.testing.expect(!disk.isDirectory("/no/such/path/at/all"));
}

test "isFrameworkVersionCached: an active override does not make every release cached (#704 review)" {
    // `isFrameworkCached` answers "is this dependency satisfied", so an
    // active local slot says yes whatever version is asked for. Right for a
    // build; wrong for `install <version>`, which reported every release
    // already cached and fetched nothing.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/packages/local");
    try tmp.dir.createDirPath(std.testing.io, "checkout");
    try tmp.dir.createDirPath(std.testing.io, "elsewhere/bin");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);
    const src = try tmp.dir.realPathFileAlloc(std.testing.io, "checkout", alloc);
    defer alloc.free(src);
    const bin = try tmp.dir.realPathFileAlloc(std.testing.io, "elsewhere/bin", alloc);
    defer alloc.free(bin);

    env.setCacheRootForTesting(home);
    defer env.setCacheRootForTesting(null);

    setProbeStartForTesting(bin);
    defer setProbeStartForTesting(null);

    const slot = try frameworkSlot(alloc, "gfx");
    defer alloc.free(slot);
    try junction.linkDir(alloc, src, slot);
    try writeOrigin(alloc, slot, src, "1.34.0", .explicit);

    const resolve = @import("resolve.zig");
    // The build probe is satisfied by the override...
    try std.testing.expect(try resolve.isFrameworkCached(alloc, "gfx", "1.29.0"));
    // ...but the release itself is still not on disk.
    try std.testing.expect(!try resolve.isFrameworkVersionCached(alloc, "gfx", "1.29.0"));

    const version_slot = try resolve.frameworkVersionPath(alloc, "gfx", "1.29.0");
    defer alloc.free(version_slot);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, version_slot);
    try std.testing.expect(try resolve.isFrameworkVersionCached(alloc, "gfx", "1.29.0"));
}
