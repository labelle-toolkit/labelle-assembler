/// Cache fetch layer: pull dependencies into the cache from remote sources.
///
/// Dependencies are fetched as **HTTPS source archives** (`/archive/<ref>.tar.gz`,
/// served by github.com and codeberg.org for tags, branches, and commit SHAs),
/// downloaded with `curl` and extracted with the system `tar`. Both ship with
/// clean Windows 10 1803+/11, macOS, and Linux — unlike `git`, which a fresh
/// Windows box lacks (labelle-cli#296). Once the tree is in place, `disk.zig`
/// handles further file layout; pure path math stays in `resolve.zig`.
///
/// `.url`+`hash` GUI plugins write a `.labelle-ref` marker recording the ref
/// they were fetched at, so every later cache-hit resolution can re-run
/// `verifyGuiUrlHash` — a pinned config must never be silently satisfied by a
/// stale or unverified checkout. See `fetchGuiUrl` for the contract.
const std = @import("std");
const builtin = @import("builtin");
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

/// Filename of the per-checkout ref marker written into a `.url` cache slot;
/// records the ref/SHA the archive was fetched at so `.hash` can be
/// re-verified on cache hits without git.
const MARKER_FILE = ".labelle-ref";

/// Fetch a framework package from its source archive at a given version.
pub fn fetchFrameworkPackage(allocator: std.mem.Allocator, package: []const u8, version: []const u8) !void {
    var repo: ?[]const u8 = null;
    for (FRAMEWORK_REPOS) |fw| {
        if (std.mem.eql(u8, fw.name, package)) {
            repo = fw.repo;
            break;
        }
    }

    if (repo == null) {
        std.log.err("labelle: unknown framework package '{s}'", .{package});
        return error.UnknownPackage;
    }

    const target = try resolve.resolveFrameworkPackage(allocator, package, version, null);
    defer allocator.free(target);

    // Map version → ref: a semver version (`1.2.3`) becomes a `v`-prefixed
    // release tag; anything else (`dev`, `main`, a branch) is a ref name used
    // verbatim. See config.versionToGitRef / issue #159.
    const ref = try config.versionToGitRef(allocator, version);
    defer allocator.free(ref);

    try archiveFetch(allocator, repo.?, ref, target);
}

/// Fetch a plugin from its source archive at a given version.
pub fn fetchPlugin(allocator: std.mem.Allocator, plugin: config.PluginDep) !void {
    const target = try resolve.resolvePlugin(allocator, plugin, null);
    defer allocator.free(target);

    const ref = try config.versionToGitRef(allocator, plugin.version);
    defer allocator.free(ref);

    try archiveFetch(allocator, plugin.repo, ref, target);
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

/// Fetch a GUI `.package` from its source archive at a given version.
/// Mirrors fetchPlugin.
pub fn fetchGuiPackage(allocator: std.mem.Allocator, package: []const u8, version: []const u8) !void {
    const target = try resolve.resolveGuiPackage(allocator, package, version, null);
    defer allocator.free(target);

    const ref = try config.versionToGitRef(allocator, version);
    defer allocator.free(ref);

    try archiveFetch(allocator, package, ref, target);
}

/// Fetch a GUI `.url` repo into its deterministic cache slot.
///
/// `.url`+`hash` contract: when `.hash` (a commit SHA) is set, the commit's
/// source archive is fetched directly (`/archive/<sha>.tar.gz`) — so the
/// checkout is **pinned by construction** — and a `.labelle-ref` marker
/// recording that SHA is written. Every later resolution re-runs
/// `verifyGuiUrlHash`, which compares the marker to the configured `.hash`, so
/// a pinned config can never be silently satisfied by a stale slot. This
/// differs from the Zig-package-manager `.url`+`hash` (build.zig.zon), where
/// `hash` is a tarball *content* hash. When `.hash` is null the plugin is
/// fetched at the ref (or the default branch) unpinned, and a warning is
/// emitted.
pub fn fetchGuiUrl(
    allocator: std.mem.Allocator,
    url: []const u8,
    slot: []const u8,
    git_ref: ?[]const u8,
    expected_sha: ?[]const u8,
) !void {
    const target = try resolve.resolveGuiUrl(allocator, url, slot);
    defer allocator.free(target);

    if (expected_sha) |sha| {
        // Pin by construction: fetch the commit's archive, record it.
        try archiveFetch(allocator, url, sha, target);
        writeRefMarker(allocator, target, sha);
    } else if (git_ref) |r| {
        try archiveFetch(allocator, url, r, target);
        writeRefMarker(allocator, target, r);
        warnUnpinned(url);
    } else {
        try fetchDefaultBranch(allocator, url, target);
        warnUnpinned(url);
    }
}

fn warnUnpinned(url: []const u8) void {
    std.log.warn(
        "labelle: GUI plugin url '{s}' fetched without a '.hash' — " ++
            "the checkout is unpinned and unverified; add '.hash = \"<commit-sha>\"' to pin it",
        .{url},
    );
}

/// No ref and no hash: fetch the repo's default branch. github/codeberg don't
/// expose a stable "default branch" archive alias, so try the common names.
fn fetchDefaultBranch(allocator: std.mem.Allocator, url: []const u8, target: []const u8) !void {
    archiveFetch(allocator, url, "main", target) catch {
        try archiveFetch(allocator, url, "master", target);
        writeRefMarker(allocator, target, "master");
        return;
    };
    writeRefMarker(allocator, target, "main");
}

/// Caller-facing `.hash` verification for a `.url` GUI checkout.
///
/// Compares the `.labelle-ref` marker written at fetch time against the
/// configured `.hash` and, on any failure, emits the appropriate
/// human-readable diagnostic before re-raising the typed error. This is the
/// single place `.hash` verification is logged — `verifyRefMarker` itself
/// stays silent so tests can exercise its reject paths without tripping the
/// test runner (Zig's test runner fails any test that emits a `std.log.err`).
///
/// Used both right after a fresh fetch and on every cache-hit resolution (see
/// gui_resolve's `.url` branch), so a pinned config can never silently run
/// against a stale or unverified checkout.
pub fn verifyGuiUrlHash(allocator: std.mem.Allocator, repo_dir: []const u8, expected_sha: []const u8) !void {
    verifyRefMarker(allocator, repo_dir, expected_sha) catch |err| {
        switch (err) {
            error.GuiUrlHashInvalid => std.log.err(
                "labelle: GUI plugin '.hash' must be a git commit SHA (7-40 hex chars), got '{s}'",
                .{expected_sha},
            ),
            error.GuiUrlHashUnverifiable => std.log.err(
                "labelle: could not verify GUI plugin '.hash' — missing '{s}' marker in '{s}' " ++
                    "(re-fetch the plugin to repopulate it)",
                .{ MARKER_FILE, repo_dir },
            ),
            error.GuiUrlHashMismatch => std.log.err(
                "labelle: GUI plugin url checkout in '{s}' does not match expected '.hash' '{s}'",
                .{ repo_dir, expected_sha },
            ),
        }
        return err;
    };
}

/// Verify the `.labelle-ref` marker at `repo_dir` matches `expected_sha`.
/// Accepts a full 40-char SHA or an abbreviated prefix (>=7 chars).
///
/// Intentionally **silent**: returns a typed error and never calls
/// `std.log.err` — logging is the caller's job (see `verifyGuiUrlHash`).
///
/// Errors:
///   error.GuiUrlHashInvalid       — `.hash` is not a 7-40 char hex string.
///   error.GuiUrlHashUnverifiable  — the marker is missing / unreadable.
///   error.GuiUrlHashMismatch      — the marker does not match `expected_sha`.
fn verifyRefMarker(allocator: std.mem.Allocator, repo_dir: []const u8, expected_sha: []const u8) !void {
    if (expected_sha.len < 7 or expected_sha.len > 40) {
        return error.GuiUrlHashInvalid;
    }
    for (expected_sha) |c| {
        if (!std.ascii.isHex(c)) {
            return error.GuiUrlHashInvalid;
        }
    }

    const io = config.globalIo();
    const marker_path = std.fs.path.join(allocator, &.{ repo_dir, MARKER_FILE }) catch
        return error.GuiUrlHashUnverifiable;
    defer allocator.free(marker_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, marker_path, allocator, .limited(128)) catch
        return error.GuiUrlHashUnverifiable;
    defer allocator.free(content);

    const marker = std.mem.trim(u8, content, " \t\r\n");
    // Case-insensitive prefix match: a full SHA matches exactly, an
    // abbreviated `.hash` matches the leading hex of the recorded ref.
    const matches = marker.len >= expected_sha.len and
        std.ascii.eqlIgnoreCase(marker[0..expected_sha.len], expected_sha);
    if (!matches) {
        return error.GuiUrlHashMismatch;
    }
}

/// Write the `.labelle-ref` marker recording the ref/SHA a `.url` slot was
/// fetched at. Best-effort — a failure only means a later cache-hit `.hash`
/// re-verification can't run and forces a re-fetch.
fn writeRefMarker(allocator: std.mem.Allocator, target: []const u8, ref: []const u8) void {
    const io = config.globalIo();
    const marker_path = std.fs.path.join(allocator, &.{ target, MARKER_FILE }) catch return;
    defer allocator.free(marker_path);
    const file = std.Io.Dir.cwd().createFile(io, marker_path, .{}) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, ref) catch {};
}

/// Fetch assembler-bundled packages (backends, ecs, gui) into the cache.
/// Downloads the labelle-assembler source archive at the matching ref and
/// copies the bundled subdirs. These packages ship with the assembler and are
/// normally populated from the companion directory in dev; this is the remote
/// fallback.
pub fn fetchAssemblerPackages(allocator: std.mem.Allocator, assembler_version: []const u8) !void {
    const packages_dir = try env.getPackagesDir(allocator);
    defer allocator.free(packages_dir);

    const target = try std.fs.path.join(allocator, &.{ packages_dir, "assembler", assembler_version });
    defer allocator.free(target);

    const ref = try config.versionToGitRef(allocator, assembler_version);
    defer allocator.free(ref);

    const tmp_dir = try env.getTempPath(allocator, "labelle-assembler-fetch", assembler_version);
    defer allocator.free(tmp_dir);

    const io = config.globalIo();
    std.Io.Dir.cwd().deleteTree(io, tmp_dir) catch {};

    archiveFetch(allocator, "github.com/labelle-toolkit/labelle-assembler", ref, tmp_dir) catch {
        std.log.err("labelle: could not fetch assembler packages at {s}\n" ++
            "  assembler-bundled packages (backends, ecs, gui) ship with the assembler binary.", .{ref});
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

// ── HTTPS source-archive fetch (curl + tar, no git) ──────────────────

/// Download `<repo>/archive/<ref>.tar.gz` and extract it into `target` with the
/// archive's top-level `<repo>-<ref>/` wrapper stripped. `repo` may be a bare
/// `host/owner/repo` (framework/plugin form) or a full clone URL (a GUI
/// `.url`); it is normalized either way.
fn archiveFetch(allocator: std.mem.Allocator, repo: []const u8, ref: []const u8, target: []const u8) !void {
    const hostpath = try repoHostPath(allocator, repo);
    defer allocator.free(hostpath);

    const url = try std.fmt.allocPrint(allocator, "https://{s}/archive/{s}.tar.gz", .{ hostpath, ref });
    defer allocator.free(url);

    const slug = try slugify(allocator, ref);
    defer allocator.free(slug);
    const archive = try env.getTempPath(allocator, "labelle-archive", slug);
    defer allocator.free(archive);

    const io = config.globalIo();
    std.Io.Dir.cwd().deleteTree(io, archive) catch {};
    try downloadFile(allocator, url, archive);
    defer std.Io.Dir.cwd().deleteTree(io, archive) catch {};

    // Fresh target: a partial/failed prior extract must not leave a half tree.
    std.Io.Dir.cwd().deleteTree(io, target) catch {};
    if (std.fs.path.dirname(target)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch {};
    }
    std.Io.Dir.cwd().createDirPath(io, target) catch {};

    try extractTarGz(allocator, archive, target);
}

/// Normalize a clone URL / host-path to a bare `host/owner/repo`: strip a
/// `git+` prefix, the scheme, any `?query`/`#fragment`, a trailing `.git`, and
/// a trailing slash. Idempotent for values already in host-path form.
fn repoHostPath(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var s = url;
    if (std.mem.startsWith(u8, s, "git+")) s = s["git+".len..];
    if (std.mem.startsWith(u8, s, "https://")) {
        s = s["https://".len..];
    } else if (std.mem.startsWith(u8, s, "http://")) {
        s = s["http://".len..];
    }
    if (std.mem.indexOfAny(u8, s, "?#")) |i| s = s[0..i];
    if (std.mem.endsWith(u8, s, ".git")) s = s[0 .. s.len - ".git".len];
    if (std.mem.endsWith(u8, s, "/")) s = s[0 .. s.len - 1];
    return allocator.dupe(u8, s);
}

/// Filesystem-safe slug for a temp filename: non-alphanumerics → `-`.
fn slugify(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = if (std.ascii.isAlphanumeric(c)) c else '-';
    return out;
}

/// `curl` the archive at `url` to `dest`. Fails closed with a diagnostic.
fn downloadFile(allocator: std.mem.Allocator, url: []const u8, dest: []const u8) !void {
    const io = config.globalIo();
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "curl", "-fSL", "--retry", "3", "-o", dest, url },
    }) catch |err| {
        std.log.err("labelle: download failed (is curl available?): {any}", .{err});
        return error.FetchFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.err("labelle: download of {s} failed:\n{s}", .{ url, result.stderr });
            return error.FetchFailed;
        },
        else => {
            std.log.err("labelle: download terminated abnormally", .{});
            return error.FetchFailed;
        },
    }
}

/// Extract a `.tar.gz` into `target`, stripping the top-level wrapper dir.
/// Windows uses the system bsdtar (`%SystemRoot%\System32\tar.exe`, Win10
/// 1803+) by full path — NOT a bare `tar`, which on a dev box's PATH is often
/// GNU tar. macOS/Linux use their native `tar`. Both auto-detect gzip.
fn extractTarGz(allocator: std.mem.Allocator, archive: []const u8, target: []const u8) !void {
    const io = config.globalIo();

    var tar_exe: ?[]u8 = null;
    defer if (tar_exe) |t| allocator.free(t);

    var argv_buf: [6][]const u8 = undefined;
    if (builtin.os.tag == .windows) {
        const environ = config.globalEnviron();
        const sysroot = environ.getAlloc(allocator, "SystemRoot") catch
            try allocator.dupe(u8, "C:\\Windows");
        defer allocator.free(sysroot);
        tar_exe = try std.fs.path.join(allocator, &.{ sysroot, "System32", "tar.exe" });
        argv_buf = .{ tar_exe.?, "-xf", archive, "-C", target, "--strip-components=1" };
    } else {
        argv_buf = .{ "tar", "-xf", archive, "-C", target, "--strip-components=1" };
    }

    const result = std.process.run(allocator, io, .{ .argv = &argv_buf }) catch |err| {
        std.log.err("labelle: extract failed (is tar available?): {any}", .{err});
        return error.FetchFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.err("labelle: extract of {s} failed:\n{s}", .{ archive, result.stderr });
            return error.FetchFailed;
        },
        else => {
            std.log.err("labelle: extract terminated abnormally", .{});
            return error.FetchFailed;
        },
    }
}

// ── Tests ────────────────────────────────────────────────────────────

test "repoHostPath: normalizes clone URLs and host-paths" {
    const alloc = std.testing.allocator;
    inline for (.{
        .{ "github.com/labelle-toolkit/labelle-core", "github.com/labelle-toolkit/labelle-core" },
        .{ "https://github.com/labelle-toolkit/labelle-core", "github.com/labelle-toolkit/labelle-core" },
        .{ "https://github.com/labelle-toolkit/labelle-core.git", "github.com/labelle-toolkit/labelle-core" },
        .{ "git+https://github.com/x/y?ref=v1.0#abc", "github.com/x/y" },
        .{ "https://codeberg.org/a/b/", "codeberg.org/a/b" },
    }) |case| {
        const got = try repoHostPath(alloc, case[0]);
        defer alloc.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "slugify: non-alphanumerics become dashes" {
    const alloc = std.testing.allocator;
    const got = try slugify(alloc, "v1.2.3");
    defer alloc.free(got);
    try std.testing.expectEqualStrings("v1-2-3", got);
}

test "verifyRefMarker: rejects a non-hex / wrong-length `.hash`" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.GuiUrlHashInvalid,
        verifyRefMarker(alloc, "/tmp/does-not-matter", "abc"),
    );
    try std.testing.expectError(
        error.GuiUrlHashInvalid,
        verifyRefMarker(alloc, "/tmp/does-not-matter", "zzzzzzzz"),
    );
}

test "verifyRefMarker: matches the ref recorded in the marker" {
    const alloc = std.testing.allocator;
    const io = config.globalIo();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "slot");
    const slot_abs = try tmp.dir.realPathFileAlloc(io, "slot", alloc);
    defer alloc.free(slot_abs);

    const sha = "467c099457be307acefad5f0703bc5baadd68313";
    writeRefMarker(alloc, slot_abs, sha);

    // Full SHA verifies.
    try verifyRefMarker(alloc, slot_abs, sha);
    // Abbreviated (10-char) prefix verifies.
    try verifyRefMarker(alloc, slot_abs, sha[0..10]);
    // A wrong SHA is rejected.
    try std.testing.expectError(
        error.GuiUrlHashMismatch,
        verifyRefMarker(alloc, slot_abs, "0123456789abcdef0123456789abcdef01234567"),
    );
    // A missing marker is unverifiable.
    const empty_abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(empty_abs);
    try std.testing.expectError(
        error.GuiUrlHashUnverifiable,
        verifyRefMarker(alloc, empty_abs, sha),
    );
}
