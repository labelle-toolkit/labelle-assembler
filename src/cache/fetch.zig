/// Cache fetch layer: pull dependencies into the cache from remote sources.
///
/// All operations here shell out to `git` (shallow clone). Once the working
/// tree is in place, `disk.zig` handles further file layout (subdir copies
/// for assembler packages); pure path math stays in `resolve.zig`.
///
/// `.url`+`hash` GUI plugins keep their `.git` directory after fetch so
/// every later cache-hit resolution can re-run `verifyGuiUrlHash` — a
/// pinned config must never be silently satisfied by a stale or unverified
/// checkout. See `fetchGuiUrl` for the contract.
const std = @import("std");
const config = @import("../config.zig");
const env = @import("env.zig");
const resolve = @import("resolve.zig");
const disk = @import("disk.zig");

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

    const target = try resolve.resolveFrameworkPackage(allocator, package, version, null);
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
    const target = try resolve.resolvePlugin(allocator, plugin, null);
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
//                resolve.resolvePlugin — so cache_cmd / lockfile tooling
//                can mirror the path)
//   .url      → ~/.labelle/packages/gui-url/{url-hash}/{ref}
//               (a deterministic per-URL slot; the URL is hashed because
//                it isn't a filesystem-safe key)
//
// `.package` is treated exactly like a regular plugin's `repo` field: a
// host/path string such as `github.com/labelle-toolkit/labelle-imgui`.

/// Fetch a GUI `.package` from its git repo at a given version into the
/// cache. Mirrors fetchPlugin: shallow-clones `https://{package}.git` at
/// the version's git ref.
pub fn fetchGuiPackage(allocator: std.mem.Allocator, package: []const u8, version: []const u8) !void {
    const target = try resolve.resolveGuiPackage(allocator, package, version, null);
    defer allocator.free(target);

    const git_url = try std.fmt.allocPrint(allocator, "https://{s}.git", .{package});
    defer allocator.free(git_url);

    const git_ref = try config.versionToGitRef(allocator, version);
    defer allocator.free(git_ref);

    try gitCloneShallow(allocator, git_url, git_ref, target);
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
    const target = try resolve.resolveGuiUrl(allocator, url, slot);
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
    const packages_dir = try env.getPackagesDir(allocator);
    defer allocator.free(packages_dir);

    const target = try std.fs.path.join(allocator, &.{ packages_dir, "assembler", assembler_version });
    defer allocator.free(target);

    const git_url = "https://github.com/labelle-toolkit/labelle-assembler.git";
    const git_ref = try config.versionToGitRef(allocator, assembler_version);
    defer allocator.free(git_ref);

    const tmp_dir = try env.getTempPath(allocator, "labelle-assembler-fetch", assembler_version);
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

        if (!disk.dirExists(src)) continue;

        const dst = try std.fs.path.join(allocator, &.{ target, subdir });
        defer allocator.free(dst);

        disk.copyDirRecursive(allocator, src, dst) catch |err| {
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

// ── Tests ────────────────────────────────────────────────────────────

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
