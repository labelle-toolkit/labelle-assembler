/// Cache path resolution: pinned dependency → on-disk cache path.
///
/// Pure path math. No git, no network, no writes — only reads (`access`,
/// `realpath`, `readFile`) needed to resolve `local:` overrides and walk
/// git worktree linkfiles.
///
/// Disk-write counterparts (populate, copy, symlink) live in `disk.zig`;
/// network fetches live in `fetch.zig`; tests for the resolve-side helpers
/// are kept here.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const env = @import("env.zig");

/// Resolve a framework package (core, engine, gfx) to its cached path.
/// Returns an absolute path like: ~/.labelle/packages/core/0.3.0
/// `project_dir` is used to resolve `local:` paths relative to the project (not CWD).
pub fn resolveFrameworkPackage(allocator: std.mem.Allocator, package: []const u8, version: []const u8, project_dir: ?[]const u8) ![]const u8 {
    if (config.isLocalVersion(version)) {
        return resolveLocalPath(allocator, config.localVersionPath(version), project_dir);
    }

    const packages_dir = try env.getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    return try std.fs.path.join(allocator, &.{ packages_dir, package, version });
}

/// Resolve an assembler-bundled package (backend, ecs adapter, gui) to its cached path.
/// Returns an absolute path like: ~/.labelle/packages/assembler/0.3.0/backends/raylib
/// `project_dir` is used to resolve `local:` paths relative to the project (not CWD).
pub fn resolveAssemblerPackage(allocator: std.mem.Allocator, assembler_version: []const u8, project_dir: ?[]const u8, subpath: []const u8) ![]const u8 {
    if (config.isLocalVersion(assembler_version)) {
        const local_path = config.localVersionPath(assembler_version);
        const joined = try std.fs.path.join(allocator, &.{ local_path, subpath });
        defer allocator.free(joined);
        return resolveLocalPath(allocator, joined, project_dir);
    }

    const packages_dir = try env.getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    return try std.fs.path.join(allocator, &.{ packages_dir, "assembler", assembler_version, subpath });
}

/// Resolve a bundled package (backend/ecs/gui) from the assembler cache slot.
///
/// `cli_version` is accepted as the fallback version key for callers that
/// don't have `assembler_version` set yet — in production both versions ship
/// together, and during monorepo dev users can point each at a different
/// sibling repo via `local:` paths.
pub fn resolveBundledPackage(allocator: std.mem.Allocator, cli_version: []const u8, assembler_version: ?[]const u8, project_dir: ?[]const u8, subpath: []const u8) ![]const u8 {
    const asm_ver = assembler_version orelse cli_version;
    return resolveAssemblerPackage(allocator, asm_ver, project_dir, subpath);
}

/// Resolve a plugin to its cached path.
/// Returns an absolute path like: ~/.labelle/packages/plugins/github.com/labelle-toolkit/labelle-physics/0.3.0
/// `project_dir` is used to resolve `local:` paths relative to the project (not CWD).
pub fn resolvePlugin(allocator: std.mem.Allocator, plugin: config.PluginDep, project_dir: ?[]const u8) ![]const u8 {
    if (plugin.isLocal()) {
        return resolveLocalPath(allocator, plugin.localPath(), project_dir);
    }

    const packages_dir = try env.getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    return try std.fs.path.join(allocator, &.{ packages_dir, "plugins", plugin.repo, plugin.version });
}

/// Resolve a local path override relative to a project directory.
/// If project_dir is provided, joins it with the local path before resolving.
/// Falls back to CWD if project_dir is null.
///
/// Worktree handling: paths that escape the project tree (first component
/// is `..`) are anchored at the main checkout instead of the worktree —
/// `local:../sibling-repo` style entries describe siblings of the main
/// project, which sit next to the main checkout, not next to the worktree.
/// Project-internal paths (`@libs/foo` → `libs/foo`, or any path without
/// a leading `..`) keep the worktree's path so worker-edited code is
/// picked up correctly during parallel-agent workflows. See
/// resolveProjectRoot and pathEscapesProject.
fn resolveLocalPath(allocator: std.mem.Allocator, local_path: []const u8, project_dir: ?[]const u8) ![]const u8 {
    const resolve_path = if (std.fs.path.isAbsolute(local_path))
        try allocator.dupe(u8, local_path)
    else if (project_dir) |pd| blk: {
        const base = if (pathEscapesProject(local_path))
            try resolveProjectRoot(allocator, pd)
        else
            try allocator.dupe(u8, pd);
        defer allocator.free(base);
        break :blk try std.fs.path.join(allocator, &.{ base, local_path });
    } else try allocator.dupe(u8, local_path);
    defer allocator.free(resolve_path);

    // realPathFileAlloc returns [:0]u8 — dupe to plain []u8 so callers
    // can `allocator.free` without the sentinel-byte size mismatch.
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), resolve_path, allocator) catch {
        std.log.warn("labelle: local path '{s}' does not exist", .{resolve_path});
        return try allocator.dupe(u8, resolve_path);
    };
    defer allocator.free(resolved);
    return try allocator.dupe(u8, resolved);
}

/// Whether `path`'s first component is `..` — i.e. the path walks out of
/// the project tree it's joined against. Used to distinguish sibling-style
/// `local:../foo` entries from project-internal `@libs/foo` entries so the
/// worktree redirect only applies to the former.
fn pathEscapesProject(path: []const u8) bool {
    var iter = std.mem.tokenizeAny(u8, path, "/\\");
    const first = iter.next() orelse return false;
    return std.mem.eql(u8, first, "..");
}

/// In a worktree, return the main-checkout-equivalent of `abs_path` (a
/// path inside the worktree filesystem). Used by callers that need to
/// anchor path-resolution math at the main checkout while still reading
/// file contents from the worktree — most notably rewriteZonPaths in
/// deps_linker, where local plugin zons contain `.path = "../sibling"`
/// references that describe siblings of the main project.
///
/// Returns a copy of `abs_path` unchanged when:
///   - `project_dir` is not a worktree, or
///   - `abs_path` doesn't sit inside the (canonical) project_dir
///     (e.g. it already points at an external sibling).
pub fn toMainCheckoutPath(allocator: std.mem.Allocator, abs_path: []const u8, project_dir: []const u8) ![]const u8 {
    const root = try resolveProjectRoot(allocator, project_dir);
    defer allocator.free(root);

    if (std.mem.eql(u8, root, project_dir)) return allocator.dupe(u8, abs_path);

    // Dupe to []u8 to free cleanly (realPathFileAlloc returns [:0]u8).
    const project_canon_z = std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), project_dir, allocator) catch
        return allocator.dupe(u8, abs_path);
    defer allocator.free(project_canon_z);
    const project_canon = try allocator.dupe(u8, project_canon_z);
    defer allocator.free(project_canon);

    if (std.mem.eql(u8, root, project_canon)) return allocator.dupe(u8, abs_path);
    if (!std.mem.startsWith(u8, abs_path, project_canon)) return allocator.dupe(u8, abs_path);
    if (abs_path.len == project_canon.len) return allocator.dupe(u8, root);
    if (abs_path[project_canon.len] != '/' and abs_path[project_canon.len] != '\\')
        return allocator.dupe(u8, abs_path);

    return std.fs.path.join(allocator, &.{ root, abs_path[project_canon.len + 1 ..] });
}

/// If `project_dir` is a git worktree, return the path of the main checkout.
/// Otherwise return a copy of `project_dir` unchanged.
///
/// Worktree detection: `<project_dir>/.git` exists as a regular file (not a
/// directory). The file is a linkfile starting with `gitdir: <path>` where
/// `<path>` matches `<main>/.git/worktrees/<name>`. We validate this exact
/// shape — git uses `.git` linkfiles for other layouts (submodules end in
/// `/.git/modules/<name>`, `--separate-git-dir` can land anywhere) and
/// stripping three dirname levels would return the wrong directory.
///
/// `gitdir:` values can be either absolute or relative — git itself supports
/// both. Relative values are resolved against the directory containing the
/// `.git` file (i.e. project_dir).
///
/// Linkfiles are typically a single line but can carry additional keys like
/// `commondir:` — only the first line is parsed.
///
/// On any error (no .git, parse failure, non-worktree layout, etc.) returns
/// project_dir unchanged so non-git callers and the main checkout keep
/// their existing behavior.
fn resolveProjectRoot(allocator: std.mem.Allocator, project_dir: []const u8) ![]u8 {
    const git_path = try std.fs.path.join(allocator, &.{ project_dir, ".git" });
    defer allocator.free(git_path);

    const io = config.globalIo();
    const stat = std.Io.Dir.cwd().statFile(io, git_path, .{}) catch return allocator.dupe(u8, project_dir);
    if (stat.kind != .file) return allocator.dupe(u8, project_dir);

    const content = std.Io.Dir.cwd().readFileAlloc(io, git_path, allocator, .limited(4096)) catch
        return allocator.dupe(u8, project_dir);
    defer allocator.free(content);

    // Parse only the first line — `commondir:` and other keys may follow.
    const eol = std.mem.indexOfAny(u8, content, "\r\n") orelse content.len;
    const first_line = std.mem.trim(u8, content[0..eol], " \t");

    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, first_line, prefix)) return allocator.dupe(u8, project_dir);

    const gitdir_raw = std.mem.trim(u8, first_line[prefix.len..], " \t");
    if (gitdir_raw.len == 0) return allocator.dupe(u8, project_dir);

    // Resolve a relative `gitdir:` against project_dir (git defines
    // relative gitdir entries as relative to the `.git` file itself).
    var gitdir_owned: ?[]u8 = null;
    defer if (gitdir_owned) |b| allocator.free(b);
    const gitdir = if (std.fs.path.isAbsolute(gitdir_raw)) gitdir_raw else blk: {
        const joined = try std.fs.path.join(allocator, &.{ project_dir, gitdir_raw });
        gitdir_owned = joined;
        break :blk joined;
    };

    // Validate worktree layout: gitdir must match `<main>/.git/worktrees/<name>`.
    // Submodules (`<parent>/.git/modules/<name>`) and `--separate-git-dir`
    // layouts also use `.git` linkfiles — silently anchoring those at a
    // wrong path would corrupt `local:` resolution.
    const wt_dir = std.fs.path.dirname(gitdir) orelse return allocator.dupe(u8, project_dir);
    if (!std.mem.eql(u8, std.fs.path.basename(wt_dir), "worktrees"))
        return allocator.dupe(u8, project_dir);

    const dot_git = std.fs.path.dirname(wt_dir) orelse return allocator.dupe(u8, project_dir);
    if (!std.mem.eql(u8, std.fs.path.basename(dot_git), ".git"))
        return allocator.dupe(u8, project_dir);

    const main_checkout = std.fs.path.dirname(dot_git) orelse return allocator.dupe(u8, project_dir);
    // Resolve the main checkout in case the gitdir contained `..`/symlinks.
    // realPathFileAlloc returns [:0]u8 — dupe to plain []u8 for clean free.
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), main_checkout, allocator) catch
        return allocator.dupe(u8, main_checkout);
    defer allocator.free(resolved);
    return try allocator.dupe(u8, resolved);
}

/// Resolve a GUI `.package` reference to its cached path.
/// `package` is a repo-style host/path string (e.g.
/// `github.com/labelle-toolkit/labelle-imgui`); `version` is a release
/// version or a `local:` path override.
/// Returns an absolute path like:
///   ~/.labelle/packages/plugins/github.com/labelle-toolkit/labelle-imgui/0.3.0
pub fn resolveGuiPackage(allocator: std.mem.Allocator, package: []const u8, version: []const u8, project_dir: ?[]const u8) ![]const u8 {
    if (config.isLocalVersion(version)) {
        return resolveLocalPath(allocator, config.localVersionPath(version), project_dir);
    }

    const packages_dir = try env.getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    return try std.fs.path.join(allocator, &.{ packages_dir, "plugins", package, version });
}

/// Resolve a GUI `.url` reference to its deterministic cache path.
/// The URL is hashed (it's not a filesystem-safe key); `ref` is the git
/// ref to check out (`.version` from the GuiPlugin, or "default").
/// Returns an absolute path like:
///   ~/.labelle/packages/gui-url/a1b2c3d4e5f6a7b8/default
pub fn resolveGuiUrl(allocator: std.mem.Allocator, url: []const u8, ref: []const u8) ![]const u8 {
    const packages_dir = try env.getPackagesDir(allocator);
    defer allocator.free(packages_dir);

    const url_hash = std.hash.Wyhash.hash(0xfa11e11e, url);
    const hash_str = try std.fmt.allocPrint(allocator, "{x:0>16}", .{url_hash});
    defer allocator.free(hash_str);

    return try std.fs.path.join(allocator, &.{ packages_dir, "gui-url", hash_str, ref });
}

// ── Cache presence probes ────────────────────────────────────────────

/// Check if a framework package version is cached.
pub fn isFrameworkCached(allocator: std.mem.Allocator, package: []const u8, version: []const u8) !bool {
    if (config.isLocalVersion(version)) return true;

    const path = try resolveFrameworkPackage(allocator, package, version, null);
    defer allocator.free(path);
    return @import("disk.zig").dirExists(path);
}

/// Check if an assembler package version is cached.
pub fn isAssemblerCached(allocator: std.mem.Allocator, assembler_version: []const u8) !bool {
    if (config.isLocalVersion(assembler_version)) return true;

    const packages_dir = try env.getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    const path = try std.fs.path.join(allocator, &.{ packages_dir, "assembler", assembler_version });
    defer allocator.free(path);
    return @import("disk.zig").dirExists(path);
}

/// Check if a plugin version is cached.
pub fn isPluginCached(allocator: std.mem.Allocator, plugin: config.PluginDep) !bool {
    if (plugin.isLocal()) return true;

    const path = try resolvePlugin(allocator, plugin, null);
    defer allocator.free(path);
    return @import("disk.zig").dirExists(path);
}

/// Validate that all dependencies in a project config are cached.
/// Returns a list of missing packages, or empty if all are cached.
pub fn validateCache(allocator: std.mem.Allocator, cfg: config.ProjectConfig) ![]const []const u8 {
    var missing: std.ArrayList([]const u8) = .empty;

    // Framework packages
    const framework = [_]struct { name: []const u8, version: []const u8 }{
        .{ .name = "core", .version = cfg.core_version },
        .{ .name = "engine", .version = cfg.engine_version },
        .{ .name = "gfx", .version = cfg.gfx_version },
    };

    for (framework) |pkg| {
        if (!try isFrameworkCached(allocator, pkg.name, pkg.version)) {
            try missing.append(allocator, try std.fmt.allocPrint(allocator, "{s} {s}", .{ pkg.name, pkg.version }));
        }
    }

    // Assembler-bundled packages (backends, ecs, gui).
    // Mirrors ensureCache in labelle-cli: asm_ver = assembler_version orelse
    // labelle_version. When the two differ (e.g. pinned assembler version),
    // we must probe the slot keyed by asm_ver, not labelle_version.
    const asm_ver = cfg.assembler_version orelse cfg.labelle_version;
    if (!try isAssemblerCached(allocator, asm_ver)) {
        try missing.append(allocator, try std.fmt.allocPrint(allocator, "assembler {s}", .{asm_ver}));
    }

    // External backend package (#386 Phase 6a). A `backend_package` is a
    // `PluginDep`, so a remote one is cached on the same `plugins/` path a
    // plugin uses (`resolvePlugin` → `isPluginCached`). Local (`local:`/`@libs`)
    // backends always report cached (the early return in `isPluginCached`), so
    // only a non-local `.repo` ever lands here. Built-in backends have no
    // `backend_package` and stay accounted for by the assembler-bundled slot
    // above, so this never touches the byte-identical built-in path.
    if (cfg.backend_package) |bp| {
        if (!try isPluginCached(allocator, bp)) {
            try missing.append(allocator, try std.fmt.allocPrint(allocator, "backend {s} {s}", .{ bp.name, bp.version }));
        }
    }

    // Plugins
    for (cfg.plugins) |plugin| {
        if (!try isPluginCached(allocator, plugin)) {
            try missing.append(allocator, try std.fmt.allocPrint(allocator, "plugin {s} {s}", .{ plugin.name, plugin.version }));
        }
    }

    return missing.toOwnedSlice(allocator);
}

// ── Tests ────────────────────────────────────────────────────────────

/// True if any entry in `missing` starts with `prefix`.
fn missingHasPrefix(missing: []const []const u8, prefix: []const u8) bool {
    for (missing) |m| {
        if (std.mem.startsWith(u8, m, prefix)) return true;
    }
    return false;
}

test "validateCache: a LOCAL external backend is never reported missing" {
    // A `local:`/`@libs` backend resolves to its checkout in place, so
    // `isPluginCached` reports it cached unconditionally — it must never appear
    // in the missing set. All framework/assembler versions are pinned `local:`
    // here so the probe touches neither the env nor the disk: the only thing
    // under test is the backend branch.
    const alloc = std.testing.allocator;
    const cfg = config.ProjectConfig{
        .name = "stubgame",
        .core_version = "local:../labelle-core",
        .engine_version = "local:../labelle-engine",
        .gfx_version = "local:../labelle-gfx",
        .assembler_version = "local:../labelle-assembler",
        .backend_package = .{ .name = "stubbackend", .repo = "local:../stubbackend" },
    };

    const missing = try validateCache(alloc, cfg);
    defer {
        for (missing) |m| alloc.free(m);
        alloc.free(missing);
    }

    try std.testing.expect(!missingHasPrefix(missing, "backend "));
}

test "validateCache: a remote external backend with no cache entry is reported missing" {
    // A non-local `.repo` is fetched onto the same `plugins/` cache path a
    // plugin uses. With every framework/assembler dep pinned `local:`, a
    // remote backend that was never fetched is the sole missing entry —
    // reported as `backend <name> <version>` so `ensureCache` knows to fetch it.
    //
    // Hermetic: point LABELLE_HOME at a guaranteed-absent dir so the cache
    // probe can't be swayed by whatever lives in the caller's real
    // ~/.labelle/packages on a dev box or a reused CI home. The construction
    // is PosixBlock-only, so skip on Windows (a different env-block layout).
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const saved_environ = std.testing.environ;
    defer std.testing.environ = saved_environ;
    const envp = [_:null]?[*:0]const u8{"LABELLE_HOME=/nonexistent/labelle-validatecache-test-home"};
    std.testing.environ = .{ .block = .{ .slice = &envp } };

    const alloc = std.testing.allocator;
    const cfg = config.ProjectConfig{
        .name = "stubgame",
        .core_version = "local:../labelle-core",
        .engine_version = "local:../labelle-engine",
        .gfx_version = "local:../labelle-gfx",
        .assembler_version = "local:../labelle-assembler",
        // A repo string that cannot exist under the (absent) test cache home.
        .backend_package = .{
            .name = "fakebackend",
            .repo = "github.com/labelle-toolkit-test/labelle-nonexistent-backend-xyz",
            .version = "9.9.9",
        },
    };

    const missing = try validateCache(alloc, cfg);
    defer {
        for (missing) |m| alloc.free(m);
        alloc.free(missing);
    }

    // Framework/assembler are all `local:` (always cached) and there are no
    // plugins, so the remote backend is the ONE and only missing entry.
    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expect(missingHasPrefix(missing, "backend fakebackend 9.9.9"));
}

test "resolveProjectRoot: main checkout (.git is a directory) returns project_dir unchanged" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io,"project/.git");
    const project_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "project", alloc);
    defer alloc.free(project_abs);

    const root = try resolveProjectRoot(alloc, project_abs);
    defer alloc.free(root);

    try std.testing.expectEqualStrings(project_abs, root);
}

test "resolveProjectRoot: worktree linkfile resolves to main checkout" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Layout:
    //   tmp/main/.git/worktrees/wt
    //   tmp/wt/.git  (linkfile pointing back into main/.git/worktrees/wt)
    try tmp.dir.createDirPath(std.testing.io,"main/.git/worktrees/wt");
    try tmp.dir.createDirPath(std.testing.io,"wt");

    const main_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "main", alloc);
    defer alloc.free(main_abs);
    const wt_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "wt", alloc);
    defer alloc.free(wt_abs);

    const linkfile_contents = try std.fmt.allocPrint(alloc, "gitdir: {s}/.git/worktrees/wt\n", .{main_abs});
    defer alloc.free(linkfile_contents);
    const f = try tmp.dir.createFile(std.testing.io, "wt/.git", .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, linkfile_contents);

    const root = try resolveProjectRoot(alloc, wt_abs);
    defer alloc.free(root);

    try std.testing.expectEqualStrings(main_abs, root);
}

test "resolveProjectRoot: not a git repo returns project_dir unchanged" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io,"plain");
    const plain_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "plain", alloc);
    defer alloc.free(plain_abs);

    const root = try resolveProjectRoot(alloc, plain_abs);
    defer alloc.free(root);

    try std.testing.expectEqualStrings(plain_abs, root);
}

test "resolveLocalPath: worktree-internal path (no `..` prefix) stays in the worktree" {
    // Regression test for Copilot review on PR #88: `@libs/foo` plugins
    // (which become bare `libs/foo` after PluginDep.localPath strips the
    // prefix) describe paths INSIDE the project tree. They must resolve
    // against the worktree itself, not the main checkout — otherwise
    // worker edits to libs/<plugin>/ in a worktree would be ignored and
    // the build would silently use the main checkout's version.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Layout: main checkout has libs/foo/file with old content; worktree
    // has libs/foo/file with new content. resolveLocalPath called from
    // the worktree must return the worktree's libs/foo, not main's.
    try tmp.dir.createDirPath(std.testing.io,"main/.git/worktrees/wt");
    try tmp.dir.createDirPath(std.testing.io,"main/libs/foo");
    try tmp.dir.createDirPath(std.testing.io,"wt/libs/foo");

    const main_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "main", alloc);
    defer alloc.free(main_abs);
    const wt_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "wt", alloc);
    defer alloc.free(wt_abs);

    const linkfile = try std.fmt.allocPrint(alloc, "gitdir: {s}/.git/worktrees/wt\n", .{main_abs});
    defer alloc.free(linkfile);
    const f = try tmp.dir.createFile(std.testing.io, "wt/.git", .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, linkfile);

    const resolved = try resolveLocalPath(alloc, "libs/foo", wt_abs);
    defer alloc.free(resolved);

    const expected = try std.fs.path.join(alloc, &.{ wt_abs, "libs/foo" });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, resolved);
}

test "resolveLocalPath: escaping path (starts with `..`) anchors at main checkout" {
    // The other half of the worktree split: `local:../sibling-repo` style
    // paths describe siblings of the main project, which sit next to the
    // main checkout. These MUST anchor at the main checkout, otherwise
    // they climb out of the worktree into a non-existent location.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io,"main/.git/worktrees/wt");
    try tmp.dir.createDirPath(std.testing.io,"sibling");
    try tmp.dir.createDirPath(std.testing.io,"wt");

    const main_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "main", alloc);
    defer alloc.free(main_abs);
    const wt_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "wt", alloc);
    defer alloc.free(wt_abs);
    const sibling_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "sibling", alloc);
    defer alloc.free(sibling_abs);

    const linkfile = try std.fmt.allocPrint(alloc, "gitdir: {s}/.git/worktrees/wt\n", .{main_abs});
    defer alloc.free(linkfile);
    const f = try tmp.dir.createFile(std.testing.io, "wt/.git", .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, linkfile);

    const resolved = try resolveLocalPath(alloc, "../sibling", wt_abs);
    defer alloc.free(resolved);

    try std.testing.expectEqualStrings(sibling_abs, resolved);
}

test "toMainCheckoutPath: worktree path inside project_dir maps to main checkout" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io,"main/.git/worktrees/wt");
    try tmp.dir.createDirPath(std.testing.io,"main/libs/foo");
    try tmp.dir.createDirPath(std.testing.io,"wt/libs/foo");

    const main_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "main", alloc);
    defer alloc.free(main_abs);
    const wt_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "wt", alloc);
    defer alloc.free(wt_abs);
    const wt_libs_foo = try tmp.dir.realPathFileAlloc(std.testing.io, "wt/libs/foo", alloc);
    defer alloc.free(wt_libs_foo);

    const linkfile = try std.fmt.allocPrint(alloc, "gitdir: {s}/.git/worktrees/wt\n", .{main_abs});
    defer alloc.free(linkfile);
    const f = try tmp.dir.createFile(std.testing.io, "wt/.git", .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, linkfile);

    const mapped = try toMainCheckoutPath(alloc, wt_libs_foo, wt_abs);
    defer alloc.free(mapped);

    const expected = try std.fs.path.join(alloc, &.{ main_abs, "libs/foo" });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, mapped);
}

test "toMainCheckoutPath: path outside project_dir is returned unchanged" {
    // Sibling-style local plugins resolve to paths OUTSIDE the worktree
    // (e.g. `local:../labelle-assembler/...` already lands at a path
    // next to the main checkout). toMainCheckoutPath must leave these
    // alone so the prefix substitution doesn't corrupt them.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io,"main/.git/worktrees/wt");
    try tmp.dir.createDirPath(std.testing.io,"sibling");
    try tmp.dir.createDirPath(std.testing.io,"wt");

    const main_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "main", alloc);
    defer alloc.free(main_abs);
    const wt_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "wt", alloc);
    defer alloc.free(wt_abs);
    const sibling_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "sibling", alloc);
    defer alloc.free(sibling_abs);

    const linkfile = try std.fmt.allocPrint(alloc, "gitdir: {s}/.git/worktrees/wt\n", .{main_abs});
    defer alloc.free(linkfile);
    const f = try tmp.dir.createFile(std.testing.io, "wt/.git", .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, linkfile);

    const mapped = try toMainCheckoutPath(alloc, sibling_abs, wt_abs);
    defer alloc.free(mapped);

    try std.testing.expectEqualStrings(sibling_abs, mapped);
}

test "toMainCheckoutPath: not in a worktree returns path unchanged" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io,"main/.git");
    try tmp.dir.createDirPath(std.testing.io,"main/libs/foo");

    const main_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "main", alloc);
    defer alloc.free(main_abs);
    const libs_foo = try tmp.dir.realPathFileAlloc(std.testing.io, "main/libs/foo", alloc);
    defer alloc.free(libs_foo);

    const mapped = try toMainCheckoutPath(alloc, libs_foo, main_abs);
    defer alloc.free(mapped);

    try std.testing.expectEqualStrings(libs_foo, mapped);
}

test "pathEscapesProject: classifies paths correctly" {
    try std.testing.expect(pathEscapesProject(".."));
    try std.testing.expect(pathEscapesProject("../foo"));
    try std.testing.expect(pathEscapesProject("../foo/bar"));
    try std.testing.expect(!pathEscapesProject("foo"));
    try std.testing.expect(!pathEscapesProject("./foo"));
    try std.testing.expect(!pathEscapesProject("libs/foo"));
    try std.testing.expect(!pathEscapesProject(""));
}

test "resolveProjectRoot: submodule .git linkfile returns project_dir unchanged" {
    // Git also uses `.git` files for submodules: `gitdir: <parent>/.git/modules/<name>`.
    // resolveProjectRoot must NOT treat these as worktrees — stripping
    // three dirname levels would land at `<parent>/.git`, anchoring `local:`
    // resolution at the superproject's git internals.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io,"super/.git/modules/sub");
    try tmp.dir.createDirPath(std.testing.io,"super/sub");

    const super_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "super", alloc);
    defer alloc.free(super_abs);
    const sub_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "super/sub", alloc);
    defer alloc.free(sub_abs);

    const linkfile = try std.fmt.allocPrint(alloc, "gitdir: {s}/.git/modules/sub\n", .{super_abs});
    defer alloc.free(linkfile);
    const f = try tmp.dir.createFile(std.testing.io, "super/sub/.git", .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, linkfile);

    const root = try resolveProjectRoot(alloc, sub_abs);
    defer alloc.free(root);

    try std.testing.expectEqualStrings(sub_abs, root);
}

test "resolveProjectRoot: relative gitdir is resolved against project_dir" {
    // git can write relative `gitdir:` values (especially with
    // `git config worktree.useRelativePaths`). resolveProjectRoot must
    // anchor them at project_dir, not treat them as already absolute.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io,"main/.git/worktrees/wt");
    try tmp.dir.createDirPath(std.testing.io,"main/wt");

    const main_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "main", alloc);
    defer alloc.free(main_abs);
    const wt_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "main/wt", alloc);
    defer alloc.free(wt_abs);

    const f = try tmp.dir.createFile(std.testing.io, "main/wt/.git", .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, "gitdir: ../.git/worktrees/wt\n");

    const root = try resolveProjectRoot(alloc, wt_abs);
    defer alloc.free(root);

    try std.testing.expectEqualStrings(main_abs, root);
}

test "resolveProjectRoot: linkfile with extra keys (commondir) parses first line only" {
    // git linkfiles may carry additional trailing keys like `commondir:`.
    // Only the first line is the gitdir.
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io,"main/.git/worktrees/wt");
    try tmp.dir.createDirPath(std.testing.io,"wt");

    const main_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "main", alloc);
    defer alloc.free(main_abs);
    const wt_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "wt", alloc);
    defer alloc.free(wt_abs);

    const linkfile = try std.fmt.allocPrint(
        alloc,
        "gitdir: {s}/.git/worktrees/wt\ncommondir: {s}/.git\n",
        .{ main_abs, main_abs },
    );
    defer alloc.free(linkfile);
    const f = try tmp.dir.createFile(std.testing.io, "wt/.git", .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, linkfile);

    const root = try resolveProjectRoot(alloc, wt_abs);
    defer alloc.free(root);

    try std.testing.expectEqualStrings(main_abs, root);
}

test "resolveProjectRoot: malformed linkfile returns project_dir unchanged" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io,"wt");
    const wt_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "wt", alloc);
    defer alloc.free(wt_abs);

    const f = try tmp.dir.createFile(std.testing.io, "wt/.git", .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, "not a gitdir line\n");

    const root = try resolveProjectRoot(alloc, wt_abs);
    defer alloc.free(root);

    try std.testing.expectEqualStrings(wt_abs, root);
}
