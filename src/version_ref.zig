//! Package `version` string → git ref (#159, #783).
//!
//! A version is fetched from its published release TAG, `v<version>`; any
//! other string is a ref name (branch, commit) used verbatim. Re-exported as
//! `config.versionToGitRef` / `config.isTagVersion`.
const std = @import("std");
const config = @import("config.zig");

/// Whether `version` names a published release tag (`v<version>`): a
/// release-shaped pin (`config.isSemverVersion`: `1.2.3`, and the `1.2` form
/// it also admits), or a full semver 2.0.0 version carrying a pre-release
/// and/or build suffix (`1.2.3-rc.1`, `1.2.3+build.5`, `1.2.3-rc.1+b`).
///
/// The suffixed form is judged by the spec, not by shape: its core must be
/// exactly `MAJOR.MINOR.PATCH` in plain digits, and the whole string must
/// pass `std.SemanticVersion.parse` (no leading zeros; non-empty
/// `[0-9A-Za-z-]` identifiers; no leading zero in a numeric pre-release
/// identifier). Anything else — `159-fix`, `1.2.3-`, `1.2.3-rc/1`,
/// `1.2-rc.1` — is not a version and stays a ref name.
pub fn isTagVersion(version: []const u8) bool {
    if (config.isSemverVersion(version)) return true;
    const suffix_at = std.mem.indexOfAny(u8, version, "-+") orelse return false;
    const core = version[0..suffix_at];
    // Plain digits and exactly two dots: `std.fmt.parseUnsigned` (under
    // `SemanticVersion.parse`) would also take `1_0` or a sign.
    if (!config.isSemverVersion(core) or std.mem.count(u8, core, ".") != 2) return false;
    _ = std.SemanticVersion.parse(version) catch return false;
    return true;
}

/// Map a package `version` string to the git ref to clone.
///
/// A version (`isTagVersion`) maps to its release tag: `v` followed by the
/// version VERBATIM — `1.2.3` → `v1.2.3`, `1.2.3-rc.1` → `v1.2.3-rc.1`,
/// `1.2.3+build.5` → `v1.2.3+build.5`. Build metadata is kept, not
/// stripped: it is part of the version the user pinned, and dropping it
/// would silently fetch a different tag (`v1.2.3`). Anything else — `dev`,
/// `main`, a feature-branch name — is a ref in its own right and is used
/// verbatim. Blindly prepending `v` to a non-numeric version produced bogus
/// refs like `vdev` that failed deep inside the fetch (issue #159).
///
/// Returns an allocator-owned slice; the caller frees it.
pub fn versionToGitRef(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    if (isTagVersion(version)) {
        return std.fmt.allocPrint(allocator, "v{s}", .{version});
    }
    return allocator.dupe(u8, version);
}

test "versionToGitRef: table — versions become `v`-tags, everything else is a verbatim ref (#159, #783)" {
    const alloc = std.testing.allocator;
    const Case = struct { version: []const u8, tag: bool, ref: []const u8 };
    const cases = [_]Case{
        // Releases.
        .{ .version = "1.2.3", .tag = true, .ref = "v1.2.3" },
        .{ .version = "0.31.0", .tag = true, .ref = "v0.31.0" },
        .{ .version = "1.13.0", .tag = true, .ref = "v1.13.0" },
        .{ .version = "1.2", .tag = true, .ref = "v1.2" }, // the abbreviated form isSemverVersion admits
        // Pre-release and build suffixes (semver 2.0.0 items 9 and 10).
        .{ .version = "1.2.3-rc.1", .tag = true, .ref = "v1.2.3-rc.1" },
        .{ .version = "1.0.0-alpha", .tag = true, .ref = "v1.0.0-alpha" },
        .{ .version = "1.0.0-0.3.7", .tag = true, .ref = "v1.0.0-0.3.7" },
        .{ .version = "1.0.0-x.7.z.92", .tag = true, .ref = "v1.0.0-x.7.z.92" },
        .{ .version = "1.0.0-x-y-z.--", .tag = true, .ref = "v1.0.0-x-y-z.--" },
        .{ .version = "1.2.3+build", .tag = true, .ref = "v1.2.3+build" },
        .{ .version = "1.2.3+build.5", .tag = true, .ref = "v1.2.3+build.5" },
        .{ .version = "1.0.0+21AF26D3----117B344092BD", .tag = true, .ref = "v1.0.0+21AF26D3----117B344092BD" },
        .{ .version = "1.2.3-rc.1+b.5", .tag = true, .ref = "v1.2.3-rc.1+b.5" },
        .{ .version = "2.10.0-feature", .tag = true, .ref = "v2.10.0-feature" },
        // Refs: not versions, used verbatim (#159: `dev` must not become `vdev`).
        .{ .version = "dev", .tag = false, .ref = "dev" },
        .{ .version = "main", .tag = false, .ref = "main" },
        .{ .version = "feature/foo", .tag = false, .ref = "feature/foo" },
        .{ .version = "159-fix", .tag = false, .ref = "159-fix" },
        .{ .version = "2026/dev", .tag = false, .ref = "2026/dev" },
        .{ .version = "v1.2.3", .tag = false, .ref = "v1.2.3" },
        // Invalid semver suffixes: not versions either.
        .{ .version = "1.2.3-", .tag = false, .ref = "1.2.3-" },
        .{ .version = "1.2.3+", .tag = false, .ref = "1.2.3+" },
        .{ .version = "1.2.3-01", .tag = false, .ref = "1.2.3-01" },
        .{ .version = "1.2.3-rc..1", .tag = false, .ref = "1.2.3-rc..1" },
        .{ .version = "1.2.3-rc/1", .tag = false, .ref = "1.2.3-rc/1" },
        .{ .version = "1.2.3-feature/x", .tag = false, .ref = "1.2.3-feature/x" },
        .{ .version = "1.2.3+b_1", .tag = false, .ref = "1.2.3+b_1" },
        .{ .version = "01.2.3-rc.1", .tag = false, .ref = "01.2.3-rc.1" },
        .{ .version = "1.2-rc.1", .tag = false, .ref = "1.2-rc.1" },
        .{ .version = "1.2.3.4-rc.1", .tag = false, .ref = "1.2.3.4-rc.1" },
        .{ .version = "1_0.2.3-rc.1", .tag = false, .ref = "1_0.2.3-rc.1" },
        .{ .version = "-rc.1", .tag = false, .ref = "-rc.1" },
    };
    for (cases) |c| {
        errdefer std.debug.print("version '{s}'\n", .{c.version});
        // Mechanism: which branch of versionToGitRef the version takes.
        try std.testing.expectEqual(c.tag, isTagVersion(c.version));
        const ref = try versionToGitRef(alloc, c.version);
        defer alloc.free(ref);
        try std.testing.expectEqualStrings(c.ref, ref);
    }
}
