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

/// Resolve the cache root directory.
/// Priority: LABELLE_HOME env var > ~/.labelle/
pub fn getCacheRoot(allocator: std.mem.Allocator) ![]const u8 {
    const env = config.globalEnviron();
    // Check LABELLE_HOME env var first
    if (env.getAlloc(allocator, "LABELLE_HOME")) |home| {
        return home;
    } else |_| {}

    // Fall back to platform-appropriate home directory
    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home_dir = env.getAlloc(allocator, home_env) catch |err| {
        std.debug.print("labelle: could not determine home directory ({s}): {any}\n", .{ home_env, err });
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

    return std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), resolve_path, allocator) catch {
        std.debug.print("labelle: warning: local path '{s}' does not exist\n", .{resolve_path});
        return try allocator.dupe(u8, resolve_path);
    };
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

    const project_canon = std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), project_dir, allocator) catch
        return allocator.dupe(u8, abs_path);
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
    return std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), main_checkout, allocator) catch allocator.dupe(u8, main_checkout);
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
        std.debug.print("labelle: could not create cache directory '{s}': {any}\n", .{ target, err });
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
            std.debug.print("labelle: could not link '{s}' to cache: {any}\n", .{ src_path, err });
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

/// Fetch a framework package from its git repo at a given version tag.
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
        std.debug.print("labelle: unknown framework package '{s}'\n", .{package});
        return error.UnknownPackage;
    }

    const target = try resolveFrameworkPackage(allocator, package, version, null);
    defer allocator.free(target);

    const git_url = try std.fmt.allocPrint(allocator, "https://{s}.git", .{repo_url.?});
    defer allocator.free(git_url);

    const tag = try std.fmt.allocPrint(allocator, "v{s}", .{version});
    defer allocator.free(tag);

    try gitCloneShallow(allocator, git_url, tag, target);
}

/// Fetch a plugin from its git repo at a given version tag.
pub fn fetchPlugin(allocator: std.mem.Allocator, plugin: config.PluginDep) !void {
    const target = try resolvePlugin(allocator, plugin, null);
    defer allocator.free(target);

    const git_url = try std.fmt.allocPrint(allocator, "https://{s}.git", .{plugin.repo});
    defer allocator.free(git_url);

    const tag = try std.fmt.allocPrint(allocator, "v{s}", .{plugin.version});
    defer allocator.free(tag);

    try gitCloneShallow(allocator, git_url, tag, target);
}

/// Fetch assembler-bundled packages (backends, ecs, gui) into the cache.
/// Clones from the labelle-assembler repo at the matching tag.
/// These packages ship with the assembler and are normally populated from the
/// companion directory in dev; this is the remote fallback.
pub fn fetchAssemblerPackages(allocator: std.mem.Allocator, assembler_version: []const u8) !void {
    const packages_dir = try getPackagesDir(allocator);
    defer allocator.free(packages_dir);

    const target = try std.fs.path.join(allocator, &.{ packages_dir, "assembler", assembler_version });
    defer allocator.free(target);

    const git_url = "https://github.com/labelle-toolkit/labelle-assembler.git";
    const tag = try std.fmt.allocPrint(allocator, "v{s}", .{assembler_version});
    defer allocator.free(tag);

    const tmp_dir = try getTempPath(allocator, "labelle-assembler-fetch", assembler_version);
    defer allocator.free(tmp_dir);

    const io = config.globalIo();
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    gitCloneShallow(allocator, git_url, tag, tmp_dir) catch {
        std.debug.print("labelle: could not fetch assembler packages at v{s}\n", .{assembler_version});
        std.debug.print("  assembler-bundled packages (backends, ecs, gui) ship with the assembler binary.\n", .{});
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
            std.debug.print("labelle: warning: could not copy {s}: {any}\n", .{ subdir, err });
        };
    }

    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};
}

/// Shallow clone a git repo at a specific tag into the target directory.
fn gitCloneShallow(allocator: std.mem.Allocator, repo_url: []const u8, tag: []const u8, target: []const u8) !void {
    const io = config.globalIo();
    // Ensure parent directory exists
    if (std.fs.path.dirname(target)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch {};
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "git", "clone", "--depth", "1", "--branch", tag, repo_url, target,
        },
    }) catch |err| {
        std.debug.print("labelle: git clone failed (is git installed?): {any}\n", .{err});
        return error.FetchFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("labelle: git clone failed:\n{s}\n", .{result.stderr});
            return error.FetchFailed;
        },
        else => {
            std.debug.print("labelle: git clone terminated abnormally\n", .{});
            return error.FetchFailed;
        },
    }

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

    // Resolve source to absolute path
    const abs_source = cwd.realPathFileAlloc(io, source_dir, allocator) catch |err| {
        std.debug.print("labelle: source directory not found '{s}': {any}\n", .{ source_dir, err });
        return error.CachePopulationFailed;
    };
    defer allocator.free(abs_source);

    // Ensure parent directory exists
    if (std.fs.path.dirname(target)) |parent| {
        cwd.createDirPath(io, parent) catch |err| {
            std.debug.print("labelle: could not create cache directory '{s}': {any}\n", .{ parent, err });
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
                std.debug.print("labelle: warning: cache entry '{s}' points to '{s}', expected '{s}'\n", .{ target, existing, abs_source });
                // Remove stale link and recreate
                cwd.deleteFile(io, target) catch return;
                cwd.symLink(io, abs_source, target, .{ .is_directory = true }) catch return;
            }
            return;
        }
        // Fall back to copying the directory
        copyDirRecursive(allocator, abs_source, target) catch |copy_err| {
            std.debug.print("labelle: could not link or copy '{s}' to '{s}': {any}\n", .{ abs_source, target, copy_err });
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

fn dirExists(path: []const u8) bool {
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
                    std.debug.print("labelle: could not copy '{s}': {any}\n", .{ src_sub, err });
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
