//! Shared manifest constants + name-validation helpers, extracted from
//! `plugin_manifest.zig` (behavior-preserving split, mirrors #539).
//!
//! Both the `plugin.labelle` (`plugin.zig`) and `pack.labelle`
//! (`pack.zig`) paths depend on these — the supported-version gate, the
//! reserved convention-dir names, and the reserved/safe name checks.
//! Re-exported unchanged from the `plugin_manifest.zig` barrel.
const std = @import("std");

/// Highest manifest_version this CLI release understands. Bump when
/// adding a new field that older CLIs cannot safely ignore.
pub const SUPPORTED_MANIFEST_VERSION: u8 = 1;

/// Reserved convention directory names. A plugin manifest may not
/// declare any of these — they are owned by the hardcoded copy/scan
/// pass in `generator/src/root.zig` and represent first-class engine
/// concepts. Kept in sync with the names used in `root.zig`.
pub const RESERVED_DIR_NAMES = [_][]const u8{
    "assets",
    "components",
    "enums",
    "events",
    "gizmos",
    "hooks",
    // `packs` is owned by the pack-scan layout (Packs RFC §4, #439): the
    // generator copies each scanned pack into `<target>/packs/<name>/`, so a
    // plugin must not claim `packs` as a convention dir and write into that
    // same tree (CodeRabbit, #478).
    "packs",
    "prefabs",
    "scenes",
    "scripts",
    "views",
};

pub fn isReservedDirName(name: []const u8) bool {
    for (RESERVED_DIR_NAMES) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return true;
    }
    return false;
}

/// Returns true iff `name` is a plain, safe relative directory segment
/// suitable for concatenating into a path under the game root.
///
/// Rejects anything that could escape the game directory or otherwise
/// surprise the copy/scan routines:
///   - empty string
///   - contains a path separator (`/` or `\`)
///   - `.` or `..` exactly
///   - contains a NUL byte
///
/// Subdirectory paths (e.g. `"nested/dir"`) are intentionally rejected
/// too — plugins should declare one `convention_dirs` entry per
/// top-level directory, not walk into subfolders at declaration time.
pub fn isSafeDirName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".")) return false;
    if (std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        if (c == '/' or c == '\\' or c == 0) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "isReservedDirName: matches every hardcoded name" {
    inline for (.{
        "assets", "components", "enums",   "events", "gizmos",
        "hooks",  "packs",      "prefabs", "scenes", "scripts",
        "views",
    }) |name| {
        try testing.expect(isReservedDirName(name));
    }
    try testing.expect(!isReservedDirName("state_machines"));
    try testing.expect(!isReservedDirName("dialogue_trees"));
    try testing.expect(!isReservedDirName(""));
}

test "isSafeDirName: accepts plain segments, rejects escape attempts" {
    try testing.expect(isSafeDirName("state_machines"));
    try testing.expect(isSafeDirName("fsm_extras"));
    try testing.expect(isSafeDirName("a"));
    try testing.expect(isSafeDirName("with.dots.ok"));

    try testing.expect(!isSafeDirName(""));
    try testing.expect(!isSafeDirName("."));
    try testing.expect(!isSafeDirName(".."));
    try testing.expect(!isSafeDirName("../escape"));
    try testing.expect(!isSafeDirName("foo/bar"));
    try testing.expect(!isSafeDirName("foo\\bar"));
    try testing.expect(!isSafeDirName("/absolute"));
    try testing.expect(!isSafeDirName("has\x00null"));
}
