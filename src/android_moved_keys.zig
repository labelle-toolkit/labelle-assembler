//! `.android` packaging keys that moved to the labelle-android provider
//! (labelle-cli#405, plan decision D4).
//!
//! `project.labelle`'s `.android` block now carries ONLY the keys the
//! assembler's codegen reads (`config.AndroidConfig`: `immersive_mode`,
//! `target_sdk_version`, `load_assets_from_apk`). Every APK-packaging key
//! lives in `providers/android.json`, owned by the labelle-android provider.
//!
//! The project parse is strict, so a moved key would already fail — but with
//! a bare "unexpected field" that reads like a typo. This pre-pass names the
//! key and where it went instead. Unknown keys that were NEVER Android
//! packaging keys are left to the strict typed parse, so a real typo still
//! gets the parser's own `line:col` diagnostic rather than a misleading
//! "move this" hint.

const std = @import("std");

/// Packaging keys that used to be (or are documented as) `.android` keys and
/// now belong in `providers/android.json`. The first five are the former
/// `AndroidConfig` fields; the rest are the provider schema's other keys
/// (plan PR 1), listed so a project copying them into `.android` gets the
/// same hint.
pub const moved_keys = [_][]const u8{
    "app_name",
    "package_name",
    "min_sdk_version",
    "orientation",
    "debuggable",
    "version_name",
    "abis",
    "signing",
    "deploy",
    "studio",
};

pub const Error = error{AndroidKeyMovedToProvider};

/// The key in the source's `.android` block that moved to the provider, if
/// any (the first one, in source order). Returns a slice of `moved_keys`, so
/// it outlives the parse. A source that does not parse returns null: the
/// strict typed parse owns that diagnostic.
pub fn findMovedKey(gpa: std.mem.Allocator, source: [:0]const u8) !?[]const u8 {
    var ast = try std.zig.Ast.parse(gpa, source, .zon);
    defer ast.deinit(gpa);
    if (ast.errors.len != 0) return null;
    var zoir = try std.zig.ZonGen.generate(gpa, ast, .{ .parse_str_lits = false });
    defer zoir.deinit(gpa);
    if (zoir.hasCompileErrors()) return null;

    const root = switch (std.zig.Zoir.Node.Index.root.get(zoir)) {
        .struct_literal => |fields| fields,
        else => return null,
    };
    for (root.names, 0..) |name, i| {
        if (!std.mem.eql(u8, name.get(zoir), "android")) continue;
        const android = switch (root.vals.at(@intCast(i)).get(zoir)) {
            .struct_literal => |fields| fields,
            else => return null, // `.{}` or a type error: the typed parse's call
        };
        for (android.names) |key| {
            const key_name = key.get(zoir);
            for (moved_keys) |moved| {
                if (std.mem.eql(u8, key_name, moved)) return moved;
            }
        }
        return null;
    }
    return null;
}

/// Write the user-facing hint for a moved key.
pub fn writeHint(w: *std.Io.Writer, key: []const u8) std.Io.Writer.Error!void {
    try w.print(
        "`.android.{s}` is no longer read from project.labelle: move {s} to " ++
            "providers/android.json (labelle-android provider; see labelle-cli#405)",
        .{ key, key },
    );
}

/// Fail with `error.AndroidKeyMovedToProvider` (logging the hint) when the
/// source's `.android` block carries a moved packaging key.
pub fn check(gpa: std.mem.Allocator, source: [:0]const u8) !void {
    const key = (try findMovedKey(gpa, source)) orelse return;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeHint(&w, key) catch {};
    // `warn`, not `err`: like the typed parse's diagnostic, this is the
    // DETAIL of a failure the command layer reports as an error.
    std.log.warn("project.labelle: {s}", .{w.buffered()});
    return error.AndroidKeyMovedToProvider;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "android moved keys: every moved key is found and hinted" {
    inline for (moved_keys) |key| {
        const src: [:0]const u8 = ".{ .name = \"g\", .android = .{ .immersive_mode = true, ." ++ key ++ " = 1 } }";
        const found = (try findMovedKey(testing.allocator, src)) orelse return error.TestExpectedMovedKey;
        try testing.expectEqualStrings(key, found);

        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeHint(&w, found);
        const want = "move " ++ key ++ " to providers/android.json (labelle-android provider; see labelle-cli#405)";
        try testing.expect(std.mem.indexOf(u8, w.buffered(), want) != null);

        try testing.expectError(error.AndroidKeyMovedToProvider, check(testing.allocator, src));
    }
}

test "android moved keys: the kept codegen keys, a missing block and an empty block pass" {
    const ok = [_][:0]const u8{
        ".{ .name = \"g\" }",
        ".{ .name = \"g\", .android = .{} }",
        ".{ .name = \"g\", .android = .{ .immersive_mode = true, .target_sdk_version = 35, .load_assets_from_apk = true } }",
        // A moved key name OUTSIDE `.android` is none of this pass's business.
        ".{ .name = \"g\", .ios = .{ .orientation = .portrait, .app_name = \"x\" } }",
    };
    for (ok) |src| {
        try testing.expect((try findMovedKey(testing.allocator, src)) == null);
        try check(testing.allocator, src);
    }
}

test "android moved keys: a typo is left to the strict typed parse" {
    // Not a packaging key → no "move it" hint; the typed parse reports it.
    try testing.expect((try findMovedKey(testing.allocator, ".{ .android = .{ .immersiv_mode = true } }")) == null);
    // Malformed ZON → null, never a crash or a misleading hint.
    try testing.expect((try findMovedKey(testing.allocator, ".{ .android = .{ .package_name = }")) == null);
}
