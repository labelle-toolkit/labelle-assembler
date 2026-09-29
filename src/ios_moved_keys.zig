//! `.ios` keys that moved to the labelle-ios provider (labelle-cli#471,
//! item I4 — the `android_moved_keys.zig` pattern).
//!
//! The assembler's codegen never read `.ios`: `IosConfig` was parsed only so
//! the strict project parse would accept the block, and its values fed the
//! CLI's legacy `labelle ios` app packaging. That packaging now lives in the
//! labelle-ios provider, configured by `providers/ios.json` (settings schema
//! v1). `config.IosConfig` is therefore an empty struct: `.ios = .{}` still
//! parses (harmless, like an empty `.android`), and every former key fails.
//!
//! The project parse is strict, so a moved key would already fail — but with
//! a bare "unexpected field" that reads like a typo. This pre-pass names the
//! key and where it went instead. Unknown keys that were NEVER iOS settings
//! are left to the strict typed parse, so a real typo still gets the parser's
//! own `line:col` diagnostic rather than a misleading "move this" hint.

const std = @import("std");

/// Keys that used to be `.ios` keys (the former `IosConfig` fields — the
/// first six) or that belong to the labelle-ios `providers/ios.json` schema
/// v1 (the rest), listed so a project copying them into `.ios` gets the same
/// hint.
pub const moved_keys = [_][]const u8{
    "app_name",
    "bundle_id",
    "team_id",
    "minimum_ios",
    "orientation",
    "device_family",
    "simulator",
    "destination",
};

pub const Error = error{IosKeyMovedToProvider};

/// The key in the source's `.ios` block that moved to the provider, if any
/// (the first one, in source order). Returns a slice of `moved_keys`, so it
/// outlives the parse. A source that does not parse returns null: the strict
/// typed parse owns that diagnostic.
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
        if (!std.mem.eql(u8, name.get(zoir), "ios")) continue;
        const ios = switch (root.vals.at(@intCast(i)).get(zoir)) {
            .struct_literal => |fields| fields,
            else => return null, // `.{}` or a type error: the typed parse's call
        };
        for (ios.names) |key| {
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
        "`.ios.{s}` is no longer read from project.labelle: move {s} to " ++
            "providers/ios.json (labelle-ios provider; see labelle-cli#471)",
        .{ key, key },
    );
}

/// Fail with `error.IosKeyMovedToProvider` (logging the hint) when the
/// source's `.ios` block carries a moved key.
pub fn check(gpa: std.mem.Allocator, source: [:0]const u8) !void {
    const key = (try findMovedKey(gpa, source)) orelse return;
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeHint(&w, key) catch {};
    // `warn`, not `err`: like the typed parse's diagnostic, this is the
    // DETAIL of a failure the command layer reports as an error.
    std.log.warn("project.labelle: {s}", .{w.buffered()});
    return error.IosKeyMovedToProvider;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "ios moved keys: every moved key is found and hinted" {
    inline for (moved_keys) |key| {
        const src: [:0]const u8 = ".{ .name = \"g\", .ios = .{ ." ++ key ++ " = 1 } }";
        const found = (try findMovedKey(testing.allocator, src)) orelse return error.TestExpectedMovedKey;
        try testing.expectEqualStrings(key, found);

        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try writeHint(&w, found);
        const want = "move " ++ key ++ " to providers/ios.json (labelle-ios provider; see labelle-cli#471)";
        try testing.expect(std.mem.indexOf(u8, w.buffered(), want) != null);

        try testing.expectError(error.IosKeyMovedToProvider, check(testing.allocator, src));
    }
}

test "ios moved keys: the first moved key in source order is named" {
    const src: [:0]const u8 = ".{ .ios = .{ .bundle_id = \"com.x.y\", .app_name = \"X\" } }";
    try testing.expectEqualStrings("bundle_id", (try findMovedKey(testing.allocator, src)).?);
}

test "ios moved keys: a missing block and an empty block pass" {
    const ok = [_][:0]const u8{
        ".{ .name = \"g\" }",
        ".{ .name = \"g\", .ios = .{} }",
        // A moved key name OUTSIDE `.ios` is none of this pass's business.
        ".{ .name = \"g\", .android = .{ .app_name = \"x\" }, .title = \"t\" }",
    };
    for (ok) |src| {
        try testing.expect((try findMovedKey(testing.allocator, src)) == null);
        try check(testing.allocator, src);
    }
}

test "ios moved keys: a typo is left to the strict typed parse" {
    // Not a former iOS key → no "move it" hint; the typed parse reports it.
    try testing.expect((try findMovedKey(testing.allocator, ".{ .ios = .{ .bundle_idd = \"x\" } }")) == null);
    // Malformed ZON → null, never a crash or a misleading hint.
    try testing.expect((try findMovedKey(testing.allocator, ".{ .ios = .{ .bundle_id = }")) == null);
}
