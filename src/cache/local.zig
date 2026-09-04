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
const builtin = @import("builtin");
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

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// The reserved local slot `path` lies at or inside, or null when it does
/// not. `…/gfx/local` → itself; `…/assembler/local/backends/sokol` →
/// `…/assembler/local`. Caller owns the result.
///
/// The classification is *structural*, not textual (#688 review). A bare
/// "does any component spell `local`" test misfires two ways:
///
///   * the cache root is configurable, so `LABELLE_HOME=/usr/local/labelle`
///     or `~/.local/share/labelle` would make every released version slot
///     look local; and
///   * a plugin repo path carries its owner, so
///     `plugins/github.com/local/foo/1.0.0` would too.
///
/// So the `local` component must lie strictly INSIDE the configured
/// packages directory, and the candidate must actually be a slot: either it
/// carries the sibling provenance marker, or it is the symlink a local
/// install created. Both are things only `populate*` produces.
pub fn localSlotRoot(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const packages_dir = env.getPackagesDir(allocator) catch return null;
    defer allocator.free(packages_dir);

    if (path.len <= packages_dir.len) return null;
    if (!std.mem.startsWith(u8, path, packages_dir)) return null;
    if (!isSep(path[packages_dir.len])) return null;

    const rel_start = packages_dir.len + 1;
    var iter = std.mem.tokenizeAny(u8, path[rel_start..], "/\\");
    while (iter.next()) |component| {
        if (!std.mem.eql(u8, component, SLOT_NAME)) continue;
        const candidate = path[0 .. rel_start + iter.index];
        if (!looksLikeSlot(allocator, candidate)) continue;
        return allocator.dupe(u8, candidate) catch null;
    }
    return null;
}

/// Whether `candidate` bears the fingerprints of a populated local slot:
/// the provenance marker beside it, or the symlink itself (the marker is
/// best-effort, so a slot whose marker could not be written still counts).
fn looksLikeSlot(allocator: std.mem.Allocator, candidate: []const u8) bool {
    if (isSymlinkPath(candidate)) return true;
    const marker = originPath(allocator, candidate) catch return false;
    defer allocator.free(marker);
    return pathExists(marker);
}

/// Whether `path` names a local slot or a subpath inside one.
pub fn isLocalSlotPath(allocator: std.mem.Allocator, path: []const u8) bool {
    const root = localSlotRoot(allocator, path) orelse return false;
    allocator.free(root);
    return true;
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

/// The local slot for a framework package, when it should be used: it is
/// populated, and it was populated from the very checkout this assembler is
/// running out of. Caller owns the returned path.
pub fn activeFrameworkSlot(allocator: std.mem.Allocator, package: []const u8) !?[]const u8 {
    const root = findRepoRoot(allocator) orelse return null;
    defer allocator.free(root);
    const slot = try frameworkSlot(allocator, package);
    return activeOrFree(allocator, slot, root);
}

/// The local slot for a plugin / external backend package, when it should
/// be used. Caller owns the returned path.
pub fn activePluginSlot(allocator: std.mem.Allocator, repo: []const u8) !?[]const u8 {
    const root = findRepoRoot(allocator) orelse return null;
    defer allocator.free(root);
    const slot = try pluginSlot(allocator, repo);
    return activeOrFree(allocator, slot, root);
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
    if (!sourcedFrom(allocator, origin.source, root) or
        !assemblerSlotComplete(allocator, slot, origin.source))
    {
        allocator.free(slot);
        return null;
    }
    return slot;
}

/// The bundled subdirectories `populateAssemblerCache` links into the slot.
pub const ASSEMBLER_SUBDIRS = [_][]const u8{ "backends", "ecs", "gui" };

/// Whether every bundled subdir the companion checkout has is present in
/// the slot.
pub fn assemblerSlotComplete(allocator: std.mem.Allocator, slot: []const u8, companion_dir: []const u8) bool {
    for (ASSEMBLER_SUBDIRS) |subdir| {
        const src = std.fs.path.join(allocator, &.{ companion_dir, subdir }) catch return false;
        defer allocator.free(src);
        if (!pathExists(src)) continue;

        const dst = std.fs.path.join(allocator, &.{ slot, subdir }) catch return false;
        defer allocator.free(dst);
        if (!pathExists(dst)) return false;
    }
    return true;
}

/// A populated slot counts as active only when its provenance marker names
/// a source inside the checkout this executable is running from (#688
/// review). Two things go wrong without it:
///
///   * one `LABELLE_HOME` shared between monorepo clones or worktrees lets
///     clone A's sources satisfy a build run out of clone B, silently, and
///   * `versionToGitRef` passes non-semver versions through verbatim, so
///     `local` is a fetchable branch name whose ordinary cache path is
///     `<package>/local` — an existence test alone would mistake that
///     release for a checkout and serve it for every other pin.
///
/// The marker is the discriminator: only `populate*` writes one.
fn activeOrFree(allocator: std.mem.Allocator, slot: []const u8, repo_root: []const u8) ?[]const u8 {
    if (pathExists(slot) and populatedFrom(allocator, slot, repo_root)) return slot;
    allocator.free(slot);
    return null;
}

fn populatedFrom(allocator: std.mem.Allocator, slot: []const u8, repo_root: []const u8) bool {
    const origin = readOrigin(allocator, slot) orelse return false;
    defer origin.deinit(allocator);
    return sourcedFrom(allocator, origin.source, repo_root);
}

/// Every local source is a direct child of the monorepo root
/// (`<root>/labelle-gfx`, `<root>/labelle-assembler`, …), so containment is
/// a parent-directory comparison.
fn sourcedFrom(allocator: std.mem.Allocator, source: []const u8, repo_root: []const u8) bool {
    const parent = std.fs.path.dirname(source) orelse return false;
    return samePath(allocator, parent, repo_root);
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

test "localSlotRoot: the reserved slot, subpaths inside it, and nothing else" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A real local framework slot (a symlink, as populate makes it), a real
    // assembler slot (a directory + marker), a genuine extracted release, and
    // a plugin whose OWNER is literally called `local`.
    try tmp.dir.createDirPath(std.testing.io, "home/packages/gfx");
    try tmp.dir.createDirPath(std.testing.io, "home/packages/gfx/1.29.0");
    try tmp.dir.createDirPath(std.testing.io, "home/packages/assembler/local/backends");
    try tmp.dir.createDirPath(std.testing.io, "home/packages/plugins/github.com/local/foo/1.0.0");
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

    const asm_slot = try assemblerSlot(alloc);
    defer alloc.free(asm_slot);
    writeOrigin(alloc, asm_slot, checkout, "1.2.3");

    // Recognised: the slot itself, and a subpath inside one, trimmed back to
    // the slot root.
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

    // … a plugin whose repo OWNER happens to be named `local` (#688 review) …
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
    try tmp.dir.createDirPath(std.testing.io, "home/packages/gfx");
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
    writeOrigin(alloc, slot, src_a, "1.29.0");

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

test "activeFrameworkSlot: an unmarked `local` directory is a fetched ref, not a checkout (#688 review)" {
    // `versionToGitRef` passes non-semver versions through verbatim, so
    // `local` is a fetchable branch whose ordinary cache path is
    // `<package>/local`. Existence alone would mistake that release for a
    // local checkout and serve it for every other pin. The provenance marker
    // is what tells them apart.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/packages/gfx/local");
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-core");
    try tmp.dir.createDirPath(std.testing.io, "toolkit/labelle-assembler/zig-out/bin");

    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", alloc);
    defer alloc.free(home);
    const bin = try tmp.dir.realPathFileAlloc(std.testing.io, "toolkit/labelle-assembler/zig-out/bin", alloc);
    defer alloc.free(bin);

    const home_env = try std.fmt.allocPrintSentinel(alloc, "LABELLE_HOME={s}", .{home}, 0);
    defer alloc.free(home_env);
    const envp = [_:null]?[*:0]const u8{home_env.ptr};
    const saved_environ = setTestCacheHome(&envp);
    defer std.testing.environ = saved_environ;

    setProbeStartForTesting(bin);
    defer setProbeStartForTesting(null);

    try std.testing.expect(try activeFrameworkSlot(alloc, "gfx") == null);
}

test "activeAssemblerSlot: an incomplete slot is refused so it gets repopulated (#688 review)" {
    // A slot populated while the checkout still lacked `gui` must not go on
    // reporting the assembler cached once the checkout grows one — the
    // version-named slot used to get this for free by changing name.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/packages/assembler/local/backends");
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
    writeOrigin(alloc, slot, companion, "1.2.3");

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
