/// Package cache manager — resolves versioned dependencies to local paths.
///
/// Cache layout:
///   ~/.labelle/packages/
///     core/0.3.0/              (fetched from core repo)
///     engine/0.3.0/            (fetched from engine repo)
///     gfx/0.3.0/              (fetched from gfx repo)
///     plugins/{repo}/{version}/ (fetched from plugin repos)
///     cli/0.3.0/              (populated from CLI companion directory)
///       backends/raylib/
///       ecs/zig-ecs/
///
/// Overridable via LABELLE_HOME env var.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

/// The default cache root directory name inside the user's home.
const DEFAULT_CACHE_DIR = ".labelle";
const PACKAGES_SUBDIR = "packages";

/// Look up an env var via the process Environ. Populated from main's
/// `Init.Minimal.environ` in production; in test builds, `config.globalEnviron()`
/// transparently returns `std.testing.environ` (populated by the test runner).
fn envLookup(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    const env = config.globalEnviron();
    if (env.getAlloc(allocator, name)) |v| return v else |_| {}
    return null;
}

/// Resolve the cache root directory.
/// Priority: LABELLE_HOME env var > ~/.labelle/
pub fn getCacheRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (envLookup(allocator, "LABELLE_HOME")) |home| return home;

    // Fall back to platform-appropriate home directory
    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home_dir = envLookup(allocator, home_env) orelse {
        // Production callers (`main.zig`) re-log this with subcommand
        // context via `@errorName(err)`; the test runner treats every
        // `std.log.err` as a test failure even when the caller catches
        // the error (see flow_catalog leak-injection test, which walks
        // every alloc index and expects no log output).
        if (!builtin.is_test) {
            std.log.err("labelle: could not determine home directory ({s})", .{home_env});
        }
        return error.NoHomeDirectory;
    };
    defer allocator.free(home_dir);

    return try std.fs.path.join(allocator, &.{ home_dir, DEFAULT_CACHE_DIR });
}

/// Resolve the packages directory: ~/.labelle/packages/
pub fn getPackagesDir(allocator: std.mem.Allocator) ![]const u8 {
    const cache_root = try getCacheRoot(allocator);
    defer allocator.free(cache_root);
    return try std.fs.path.join(allocator, &.{ cache_root, PACKAGES_SUBDIR });
}

/// Resolve a framework package (core, engine, gfx) to its cached path.
/// Returns an absolute path like: ~/.labelle/packages/core/0.3.0
/// `project_dir` is used to resolve `local:` paths relative to the project (not CWD).
pub fn resolveFrameworkPackage(allocator: std.mem.Allocator, package: []const u8, version: []const u8, project_dir: ?[]const u8) ![]const u8 {
    if (config.isLocalVersion(version)) {
        return resolveLocalPath(allocator, config.localVersionPath(version), project_dir);
    }

    const packages_dir = try getPackagesDir(allocator);
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

    const packages_dir = try getPackagesDir(allocator);
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

    const packages_dir = try getPackagesDir(allocator);
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

/// Check if a framework package version is cached.
pub fn isFrameworkCached(allocator: std.mem.Allocator, package: []const u8, version: []const u8) !bool {
    if (config.isLocalVersion(version)) return true;

    const path = try resolveFrameworkPackage(allocator, package, version, null);
    defer allocator.free(path);
    return dirExists(path);
}

/// Check if an assembler package version is cached.
pub fn isAssemblerCached(allocator: std.mem.Allocator, assembler_version: []const u8) !bool {
    if (config.isLocalVersion(assembler_version)) return true;

    const packages_dir = try getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    const path = try std.fs.path.join(allocator, &.{ packages_dir, "assembler", assembler_version });
    defer allocator.free(path);
    return dirExists(path);
}

/// Check if a plugin version is cached.
pub fn isPluginCached(allocator: std.mem.Allocator, plugin: config.PluginDep) !bool {
    if (plugin.isLocal()) return true;

    const path = try resolvePlugin(allocator, plugin, null);
    defer allocator.free(path);
    return dirExists(path);
}


/// Populate the assembler cache from the assembler source directory.
/// `companion_dir` points at the labelle-assembler repo root (for dev) or
/// an install-time bundled directory. Symlinks `backends/` into
/// ~/.labelle/packages/assembler/{version}/. Missing subdirectories are
/// skipped silently so the same function works through the staged migration
/// as more subdirs (ecs, gui) move over.
pub fn populateAssemblerCache(allocator: std.mem.Allocator, assembler_version: []const u8, companion_dir: []const u8) !void {
    const packages_dir = try getPackagesDir(allocator);
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

    // Plugins
    for (cfg.plugins) |plugin| {
        if (!try isPluginCached(allocator, plugin)) {
            try missing.append(allocator, try std.fmt.allocPrint(allocator, "plugin {s} {s}", .{ plugin.name, plugin.version }));
        }
    }

    return missing.toOwnedSlice(allocator);
}

/// Populate a framework package (core, engine, gfx) into the cache from a source directory.
/// Creates a symlink from the cache location to the source directory.
pub fn populateFrameworkPackage(allocator: std.mem.Allocator, package: []const u8, version: []const u8, source_dir: []const u8) !void {
    const target = try resolveFrameworkPackage(allocator, package, version, null);
    defer allocator.free(target);
    try symlinkToCache(allocator, source_dir, target);
}

/// Populate a plugin into the cache from a source directory.
/// Creates a symlink from the cache location to the source directory.
pub fn populatePlugin(allocator: std.mem.Allocator, plugin: config.PluginDep, source_dir: []const u8) !void {
    const target = try resolvePlugin(allocator, plugin, null);
    defer allocator.free(target);
    try symlinkToCache(allocator, source_dir, target);
}

// ── Remote fetching ──────────────────────────────────────────────────

/// Known GitHub repos for first-party framework packages.
const FRAMEWORK_REPOS = [_]struct { name: []const u8, repo: []const u8 }{
    .{ .name = "core", .repo = "github.com/labelle-toolkit/labelle-core" },
    .{ .name = "engine", .repo = "github.com/labelle-toolkit/labelle-engine" },
    .{ .name = "gfx", .repo = "github.com/labelle-toolkit/labelle-gfx" },
};

/// R2 base URL for CLI releases (binary + bundled packages).
pub const R2_BASE_URL = "https://releases.labelle.games/cli";

/// Fetch a framework package from its git repo at a given version.
/// Clones into the cache directory.
pub fn fetchFrameworkPackage(allocator: std.mem.Allocator, package: []const u8, version: []const u8) !void {
    // Find the repo URL
    var repo_url: ?[]const u8 = null;
    for (FRAMEWORK_REPOS) |fw| {
        if (std.mem.eql(u8, fw.name, package)) {
            repo_url = fw.repo;
            break;
        }
    }

    if (repo_url == null) {
        std.log.err("labelle: unknown framework package '{s}'", .{package});
        return error.UnknownPackage;
    }

    const target = try resolveFrameworkPackage(allocator, package, version, null);
    defer allocator.free(target);

    const git_url = try std.fmt.allocPrint(allocator, "https://{s}.git", .{repo_url.?});
    defer allocator.free(git_url);

    // Map version → git ref: a semver version (`1.2.3`) becomes a `v`-prefixed
    // release tag; anything else (`dev`, `main`, a branch) is a ref name
    // used verbatim. See config.versionToGitRef / issue #159.
    const git_ref = try config.versionToGitRef(allocator, version);
    defer allocator.free(git_ref);

    try gitCloneShallow(allocator, git_url, git_ref, target);
}

/// Fetch a plugin from its git repo at a given version.
pub fn fetchPlugin(allocator: std.mem.Allocator, plugin: config.PluginDep) !void {
    const target = try resolvePlugin(allocator, plugin, null);
    defer allocator.free(target);

    const git_url = try std.fmt.allocPrint(allocator, "https://{s}.git", .{plugin.repo});
    defer allocator.free(git_url);

    const git_ref = try config.versionToGitRef(allocator, plugin.version);
    defer allocator.free(git_ref);

    try gitCloneShallow(allocator, git_url, git_ref, target);
}

// ── GUI plugin (`.package` / `.url`) resolution ──────────────────────
//
// A GUI plugin declared as `.gui = .{ .package = "..." }` or
// `.gui = .{ .url = "..." }` (see config.GuiPlugin) lands in the same
// `~/.labelle/packages/...` cache tree the rest of the assembler uses:
//
//   .package  → ~/.labelle/packages/plugins/{package}/{version}
//               (identical layout to a regular declared plugin — see
//                resolvePlugin — so cache_cmd / lockfile tooling can
//                mirror the path)
//   .url      → ~/.labelle/packages/gui-url/{url-hash}/{ref}
//               (a deterministic per-URL slot; the URL is hashed because
//                it isn't a filesystem-safe key)
//
// `.package` is treated exactly like a regular plugin's `repo` field: a
// host/path string such as `github.com/labelle-toolkit/labelle-imgui`.

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

    const packages_dir = try getPackagesDir(allocator);
    defer allocator.free(packages_dir);
    return try std.fs.path.join(allocator, &.{ packages_dir, "plugins", package, version });
}

/// Fetch a GUI `.package` from its git repo at a given version into the
/// cache. Mirrors fetchPlugin: shallow-clones `https://{package}.git` at
/// the version's git ref.
pub fn fetchGuiPackage(allocator: std.mem.Allocator, package: []const u8, version: []const u8) !void {
    const target = try resolveGuiPackage(allocator, package, version, null);
    defer allocator.free(target);

    const git_url = try std.fmt.allocPrint(allocator, "https://{s}.git", .{package});
    defer allocator.free(git_url);

    const git_ref = try config.versionToGitRef(allocator, version);
    defer allocator.free(git_ref);

    try gitCloneShallow(allocator, git_url, git_ref, target);
}

/// Resolve a GUI `.url` reference to its deterministic cache path.
/// The URL is hashed (it's not a filesystem-safe key); `ref` is the git
/// ref to check out (`.version` from the GuiPlugin, or "default").
/// Returns an absolute path like:
///   ~/.labelle/packages/gui-url/a1b2c3d4e5f6a7b8/default
pub fn resolveGuiUrl(allocator: std.mem.Allocator, url: []const u8, ref: []const u8) ![]const u8 {
    const packages_dir = try getPackagesDir(allocator);
    defer allocator.free(packages_dir);

    const url_hash = std.hash.Wyhash.hash(0xfa11e11e, url);
    const hash_str = try std.fmt.allocPrint(allocator, "{x:0>16}", .{url_hash});
    defer allocator.free(hash_str);

    return try std.fs.path.join(allocator, &.{ packages_dir, "gui-url", hash_str, ref });
}

/// Fetch a GUI `.url` repo into its deterministic cache slot.
/// Shallow-clones `url` into the path returned by `resolveGuiUrl(url, slot)`.
/// `git_ref` is the branch/tag to check out, or null for the repo's
/// default branch; `slot` is the cache-path component (the resolved ref
/// name, or "default" for the implicit-default-branch case).
///
/// `.url`+`hash` contract: a `.url` GUI plugin is git-cloned, so `hash`
/// (when set) is the **expected commit SHA** the checked-out ref must
/// resolve to. After cloning, the actual `HEAD` commit is verified against
/// `expected_sha`; a mismatch aborts the fetch with `error.GuiUrlHashMismatch`
/// so the build never proceeds against an unexpected revision. A full or
/// abbreviated (>=7 char) SHA prefix is accepted. This differs from the
/// Zig-package-manager `.url`+`hash` used in build.zig.zon, where `hash`
/// is a tarball *content* hash — git URLs aren't fetched through the Zig
/// package manager, so the closest pinning primitive available is the
/// commit SHA. When `hash` is null the plugin is fetched unpinned (the
/// pre-existing behavior) and a warning is emitted.
///
/// The `.git` directory of a `.url` checkout is **always retained** (it is
/// not stripped after a fresh fetch). Keeping it lets `resolvePluginDir`
/// re-run `verifyGuiUrlHash` on every later resolution — a cache *hit*
/// against a pinned `.hash` must be re-verified, otherwise a previously
/// unpinned (or differently-pinned) checkout could silently satisfy a
/// pinned config.
pub fn fetchGuiUrl(
    allocator: std.mem.Allocator,
    url: []const u8,
    slot: []const u8,
    git_ref: ?[]const u8,
    expected_sha: ?[]const u8,
) !void {
    const target = try resolveGuiUrl(allocator, url, slot);
    defer allocator.free(target);

    // Always keep `.git`: a pinned `.url` checkout is re-verified against
    // `.hash` on every resolution, including cache hits, which needs
    // `git rev-parse HEAD` to keep working.
    if (git_ref) |r| {
        try gitCloneShallow2(allocator, url, r, target, true);
    } else {
        try gitCloneShallowDefaultBranch2(allocator, url, target, true);
    }

    if (expected_sha) |sha| {
        verifyGuiUrlHash(allocator, target, sha) catch |err| {
            // The checkout is wrong / unverifiable — don't leave a poisoned
            // cache slot that a later run would treat as already-fetched.
            std.Io.Dir.cwd().deleteTree(config.globalIo(), target) catch {};
            return err;
        };
    } else {
        std.log.warn(
            "labelle: GUI plugin url '{s}' fetched without a '.hash' — " ++
                "the checkout is unpinned and unverified; add '.hash = \"<commit-sha>\"' to pin it",
            .{url},
        );
    }
}

/// Verify the `HEAD` commit of the git checkout at `repo_dir` matches
/// `expected_sha`. Accepts a full 40-char SHA or an abbreviated prefix
/// (>=7 chars).
///
/// This helper is intentionally **silent**: it returns a typed error and
/// never calls `std.log.err` itself. Logging is the caller's job — Zig's
/// test runner fails any test that emits a `std.log.err`, so a negative
/// test must be able to exercise the reject paths cleanly with
/// `expectError`. Callers (`fetchGuiUrl`, `verifyGuiUrlHash`) own the
/// diagnostics.
///
/// Errors:
///   error.GuiUrlHashInvalid       — `.hash` is not a 7-40 char hex string.
///   error.GuiUrlHashUnverifiable  — `git rev-parse HEAD` could not be run.
///   error.GuiUrlHashMismatch      — HEAD does not match `expected_sha`.
fn verifyGitHead(allocator: std.mem.Allocator, repo_dir: []const u8, expected_sha: []const u8) !void {
    if (expected_sha.len < 7 or expected_sha.len > 40) {
        return error.GuiUrlHashInvalid;
    }
    for (expected_sha) |c| {
        if (!std.ascii.isHex(c)) {
            return error.GuiUrlHashInvalid;
        }
    }

    const io = config.globalIo();
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", repo_dir, "rev-parse", "HEAD" },
    }) catch {
        return error.GuiUrlHashUnverifiable;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            return error.GuiUrlHashUnverifiable;
        },
        else => {
            return error.GuiUrlHashUnverifiable;
        },
    }

    const head = std.mem.trim(u8, result.stdout, " \t\r\n");
    // Case-insensitive prefix match: a full SHA matches exactly, an
    // abbreviated `.hash` matches the leading hex of the resolved HEAD.
    const matches = head.len >= expected_sha.len and
        std.ascii.eqlIgnoreCase(head[0..expected_sha.len], expected_sha);
    if (!matches) {
        return error.GuiUrlHashMismatch;
    }
}

/// Caller-facing `.hash` verification for a `.url` GUI checkout.
///
/// Runs `verifyGitHead` against the checkout at `repo_dir` and, on any
/// failure, emits the appropriate human-readable diagnostic before
/// re-raising the typed error. This is the single place `.hash`
/// verification is logged — `verifyGitHead` itself stays silent so tests
/// can exercise its reject paths without tripping the test runner.
///
/// Used both right after a fresh fetch and on every cache-hit resolution
/// (see `resolvePluginDir`'s `.url` branch), so a pinned config can never
/// silently run against a stale or unverified checkout.
pub fn verifyGuiUrlHash(allocator: std.mem.Allocator, repo_dir: []const u8, expected_sha: []const u8) !void {
    verifyGitHead(allocator, repo_dir, expected_sha) catch |err| {
        switch (err) {
            error.GuiUrlHashInvalid => std.log.err(
                "labelle: GUI plugin '.hash' must be a git commit SHA (7-40 hex chars), got '{s}'",
                .{expected_sha},
            ),
            error.GuiUrlHashUnverifiable => std.log.err(
                "labelle: could not verify GUI plugin '.hash' — 'git rev-parse HEAD' " ++
                    "failed in '{s}' (is it a git checkout, and is git installed?)",
                .{repo_dir},
            ),
            error.GuiUrlHashMismatch => std.log.err(
                "labelle: GUI plugin url checkout in '{s}' does not match expected '.hash' '{s}'",
                .{ repo_dir, expected_sha },
            ),
        }
        return err;
    };
}

/// Shallow-clone a git repo's default branch (no `--branch`) into `target`.
fn gitCloneShallowDefaultBranch(allocator: std.mem.Allocator, repo_url: []const u8, target: []const u8) !void {
    return gitCloneShallowDefaultBranch2(allocator, repo_url, target, false);
}

/// Like gitCloneShallowDefaultBranch, but `keep_git_dir` controls whether the
/// `.git` directory is stripped afterwards. Callers that need to verify the
/// checked-out commit (`.url`+`hash`) pass `true` and strip `.git` themselves
/// once verification has run.
fn gitCloneShallowDefaultBranch2(
    allocator: std.mem.Allocator,
    repo_url: []const u8,
    target: []const u8,
    keep_git_dir: bool,
) !void {
    const io = config.globalIo();
    if (std.fs.path.dirname(target)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch {};
    }

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "clone", "--depth", "1", repo_url, target },
    }) catch |err| {
        std.log.err("labelle: git clone failed (is git installed?): {any}", .{err});
        return error.FetchFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.err("labelle: git clone failed:\n{s}", .{result.stderr});
            return error.FetchFailed;
        },
        else => {
            std.log.err("labelle: git clone terminated abnormally", .{});
            return error.FetchFailed;
        },
    }

    if (keep_git_dir) return;
    const git_dir = try std.fs.path.join(allocator, &.{ target, ".git" });
    defer allocator.free(git_dir);
    std.Io.Dir.cwd().deleteTree(io, git_dir) catch {};
}

/// Fetch assembler-bundled packages (backends, ecs, gui) into the cache.
/// Clones from the labelle-assembler repo at the matching git ref.
/// These packages ship with the assembler and are normally populated from the
/// companion directory in dev; this is the remote fallback.
pub fn fetchAssemblerPackages(allocator: std.mem.Allocator, assembler_version: []const u8) !void {
    const packages_dir = try getPackagesDir(allocator);
    defer allocator.free(packages_dir);

    const target = try std.fs.path.join(allocator, &.{ packages_dir, "assembler", assembler_version });
    defer allocator.free(target);

    const git_url = "https://github.com/labelle-toolkit/labelle-assembler.git";
    const git_ref = try config.versionToGitRef(allocator, assembler_version);
    defer allocator.free(git_ref);

    const tmp_dir = try getTempPath(allocator, "labelle-assembler-fetch", assembler_version);
    defer allocator.free(tmp_dir);

    const io = config.globalIo();
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    gitCloneShallow(allocator, git_url, git_ref, tmp_dir) catch {
        std.log.err("labelle: could not fetch assembler packages at {s}\n" ++
            "  assembler-bundled packages (backends, ecs, gui) ship with the assembler binary.", .{git_ref});
        return error.FetchFailed;
    };

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, target) catch {};

    const subdirs = [_][]const u8{ "backends", "ecs", "gui" };
    for (subdirs) |subdir| {
        const src = try std.fs.path.join(allocator, &.{ tmp_dir, subdir });
        defer allocator.free(src);

        if (!dirExists(src)) continue;

        const dst = try std.fs.path.join(allocator, &.{ target, subdir });
        defer allocator.free(dst);

        copyDirRecursive(allocator, src, dst) catch |err| {
            std.log.warn("labelle: could not copy {s}: {any}", .{ subdir, err });
        };
    }

    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
}

/// Shallow clone a git repo at a specific git ref (tag or branch) into the
/// target directory.
fn gitCloneShallow(allocator: std.mem.Allocator, repo_url: []const u8, git_ref: []const u8, target: []const u8) !void {
    return gitCloneShallow2(allocator, repo_url, git_ref, target, false);
}

/// Like gitCloneShallow, but `keep_git_dir` controls whether the `.git`
/// directory is stripped afterwards. Callers that need to verify the
/// checked-out commit (`.url`+`hash`) pass `true` and strip `.git`
/// themselves once verification has run.
fn gitCloneShallow2(
    allocator: std.mem.Allocator,
    repo_url: []const u8,
    git_ref: []const u8,
    target: []const u8,
    keep_git_dir: bool,
) !void {
    const io = config.globalIo();
    // Ensure parent directory exists
    if (std.fs.path.dirname(target)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch {};
    }

    const result = std.process.run(allocator, io, .{
        .argv = &.{
            "git", "clone", "--depth", "1", "--branch", git_ref, repo_url, target,
        },
    }) catch |err| {
        std.log.err("labelle: git clone failed (is git installed?): {any}", .{err});
        return error.FetchFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.err("labelle: git clone failed:\n{s}", .{result.stderr});
            return error.FetchFailed;
        },
        else => {
            std.log.err("labelle: git clone terminated abnormally", .{});
            return error.FetchFailed;
        },
    }

    if (keep_git_dir) return;
    // Remove .git directory to save space
    const git_dir = try std.fs.path.join(allocator, &.{ target, ".git" });
    defer allocator.free(git_dir);
    std.Io.Dir.cwd().deleteTree(io, git_dir) catch {};
}

// ── Internal helpers ─────────────────────────────────────────────────

/// Create a symlink from cache target to source directory.
/// The source_dir must be an absolute path (resolved via realpath).
/// Creates parent directories as needed.
fn symlinkToCache(allocator: std.mem.Allocator, source_dir: []const u8, target: []const u8) !void {
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

/// Get a platform-aware temporary directory path.
/// Uses TEMP/TMP on Windows, /tmp on Unix.
fn getTempPath(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8) ![]const u8 {
    const env = config.globalEnviron();
    const tmp_base = if (builtin.os.tag == .windows)
        env.getAlloc(allocator, "TEMP") catch
            env.getAlloc(allocator, "TMP") catch
            try allocator.dupe(u8, "C:\\Windows\\Temp")
    else
        try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmp_base);

    return try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}-{s}", .{ tmp_base, prefix, suffix });
}

/// Whether `path` exists and is accessible. Public so the cache
/// subcommand handlers (cache_cmd.zig) can probe monorepo source dirs
/// before deciding between a local symlink and a remote clone.
pub fn dirExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(config.globalIo(), path, .{}) catch return false;
    return true;
}

// ── Cache patching ───────────────────────────────────────────────────

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

        const pkg_dir = try resolveFrameworkPackage(allocator, pkg.name, pkg.version, null);
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

/// Check if a path is a symlink.
fn isSymlink(path: []const u8) bool {
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

// ── Tests ────────────────────────────────────────────────────────────

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

test "verifyGitHead: rejects a non-hex / wrong-length `.hash`" {
    const alloc = std.testing.allocator;
    // Too short.
    try std.testing.expectError(
        error.GuiUrlHashInvalid,
        verifyGitHead(alloc, "/tmp/does-not-matter", "abc"),
    );
    // Non-hex characters.
    try std.testing.expectError(
        error.GuiUrlHashInvalid,
        verifyGitHead(alloc, "/tmp/does-not-matter", "zzzzzzzz"),
    );
}

test "verifyGitHead: matches the HEAD commit of a real git repo" {
    const alloc = std.testing.allocator;
    const io = config.globalIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo");
    const repo_abs = try tmp.dir.realPathFileAlloc(io, "repo", alloc);
    defer alloc.free(repo_abs);

    // Build a one-commit git repo. Skip the test gracefully if git is
    // unavailable in the environment.
    const gitRun = struct {
        fn run(a: std.mem.Allocator, argv: []const []const u8) !bool {
            const r = std.process.run(a, config.globalIo(), .{ .argv = argv }) catch return false;
            defer a.free(r.stdout);
            defer a.free(r.stderr);
            return switch (r.term) {
                .exited => |code| code == 0,
                else => false,
            };
        }
    }.run;

    if (!try gitRun(alloc, &.{ "git", "-C", repo_abs, "init", "-q" })) return error.SkipZigTest;
    {
        const f = try tmp.dir.createFile(io, "repo/file.txt", .{});
        f.close(io);
    }
    _ = try gitRun(alloc, &.{ "git", "-C", repo_abs, "add", "." });
    // CI runners have no global git identity, so `git commit` would fail
    // with "Committer identity unknown" and leave the repo with no HEAD.
    // Pass the identity inline via `-c` so the test never depends on the
    // environment's git config.
    if (!try gitRun(alloc, &.{
        "git",                   "-C",
        repo_abs,                "-c",
        "user.email=ci@example.com", "-c",
        "user.name=ci",          "commit",
        "-q",                    "-m",
        "init",
    }))
        return error.SkipZigTest;

    // Read the actual HEAD SHA.
    const rev = std.process.run(alloc, io, .{
        .argv = &.{ "git", "-C", repo_abs, "rev-parse", "HEAD" },
    }) catch return error.SkipZigTest;
    defer alloc.free(rev.stdout);
    defer alloc.free(rev.stderr);
    const head = std.mem.trim(u8, rev.stdout, " \t\r\n");

    // Full SHA verifies.
    try verifyGitHead(alloc, repo_abs, head);
    // Abbreviated (10-char) prefix verifies.
    try verifyGitHead(alloc, repo_abs, head[0..10]);
    // A wrong SHA is rejected.
    try std.testing.expectError(
        error.GuiUrlHashMismatch,
        verifyGitHead(alloc, repo_abs, "0123456789abcdef0123456789abcdef01234567"),
    );
}
