/// Cache environment + directory-layout helpers.
///
/// This module owns:
///   * env-var resolution (`LABELLE_HOME`, `HOME` / `USERPROFILE`, `TEMP`/`TMP`)
///   * the `~/.labelle/packages/` layout constants
///   * the public `getCacheRoot` / `getPackagesDir` entry points used by the
///     resolve and fetch layers
///
/// The `HOME`-missing log is silenced under `builtin.is_test` so the test
/// runner doesn't fail when callers exercise `error.NoHomeDirectory` paths
/// (see #179 and the flow_catalog leak-injection test).
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");

/// The default cache root directory name inside the user's home.
pub const DEFAULT_CACHE_DIR = ".labelle";
pub const PACKAGES_SUBDIR = "packages";

/// Look up an env var via the process Environ. Populated from main's
/// `Init.Minimal.environ` in production; in test builds, `config.globalEnviron()`
/// transparently returns `std.testing.environ` (populated by the test runner).
pub fn envLookup(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    const env = config.globalEnviron();
    if (env.getAlloc(allocator, name)) |v| return v else |_| {}
    return null;
}

/// Test seam: the cache root, bypassing the environment entirely. `null`
/// (the production value) means "read `$LABELLE_HOME`, else the home dir".
///
/// Needed because `std.testing.environ` cannot carry a synthetic environment
/// on Windows. `Environ.Block` is `GlobalBlock` there — std's own comment
/// explains why: "the memory pointed at by the PEB changes when the
/// environment is modified, so a long-lived pointer cannot be used" — so it
/// can only say *use the real process environment*, never *use this one*.
/// (`WindowsBlock` exists, but for building a CHILD process's environment,
/// not for overriding our own.)
///
/// Tests therefore set `$LABELLE_HOME` through a `PosixBlock` and opened
/// with `if (os.tag == .windows) return error.SkipZigTest`, which is why the
/// Windows CI job — the repo's only Windows job — executed 40 of the 123
/// tests it nominally ran and skipped 83 (#699). A run of Windows-specific
/// cache defects (#704, #706, #708, #710) all shipped green underneath it.
///
/// An explicit override needs no environment and works on every platform.
/// Mirrors `local.setProbeStartForTesting`.
var cache_root_override: ?[]const u8 = null;

/// Point the cache root at `dir` instead of the environment. Tests only —
/// pass `null` to restore.
pub fn setCacheRootForTesting(dir: ?[]const u8) void {
    cache_root_override = dir;
}

/// Resolve the cache root directory.
/// Priority: LABELLE_HOME env var > ~/.labelle/
pub fn getCacheRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (cache_root_override) |dir| return allocator.dupe(u8, dir);
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

/// Get a platform-aware temporary directory path.
/// Uses TEMP/TMP on Windows, /tmp on Unix.
pub fn getTempPath(allocator: std.mem.Allocator, prefix: []const u8, suffix: []const u8) ![]const u8 {
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
