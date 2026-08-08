//! Zig-keyword detection for generated-identifier lints (flying-platform#786
//! friction #2, via the i18n and constants phases).
//!
//! A key segment named like a Zig keyword ("resume", "error", "suspend")
//! still GENERATES -- every emitted declaration is @""-quoted -- but call
//! sites must then write `K.pause.@"resume"`, which is the ergonomic trap
//! the lint warns about. Detection defers to `std.zig.Token.getKeyword`, so
//! the table is the compiler's own and never drifts from the language.
//!
//! Primitive type names ("bool", "u8", "type") are deliberately NOT linted:
//! they only clash as standalone identifiers, and `K.hud.bool` is ordinary
//! field access -- no @"" needed at any call site.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// True when `s` is a Zig keyword (`fn`, `error`, `resume`, ...).
pub fn isKeyword(s: []const u8) bool {
    return std.zig.Token.getKeyword(s) != null;
}

/// The first dotted segment of `key` that is a Zig keyword, or null when
/// every segment is call-site-clean.
pub fn firstKeywordSegment(key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, key, '.');
    while (it.next()) |seg| {
        if (isKeyword(seg)) return seg;
    }
    return null;
}

/// `key` with every segment a call site could not write bare @""-quoted --
/// exactly what the call site has to type, for the warning to show:
/// `pause.resume` -> `pause.@"resume"`. Quoting keys off std.zig.isValidId,
/// not just isKeyword: i18n composes pack-surfaced paths from the RAW pack
/// name, so a segment like `my-pack__hunger` needs @"" for shape, not
/// keyword-ness.
pub fn quoteDottedPath(arena: Allocator, key: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, key, '.');
    var first = true;
    while (it.next()) |seg| {
        if (!first) try out.append(arena, '.');
        first = false;
        if (std.zig.isValidId(seg)) {
            try out.appendSlice(arena, seg);
        } else {
            try out.appendSlice(arena, "@\"");
            try out.appendSlice(arena, seg);
            try out.appendSlice(arena, "\"");
        }
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "keywords are detected; near-misses and primitives are not" {
    try testing.expect(isKeyword("resume"));
    try testing.expect(isKeyword("error"));
    try testing.expect(isKeyword("suspend"));
    try testing.expect(isKeyword("fn"));
    try testing.expect(isKeyword("test"));
    // The rename the lint suggests is clean.
    try testing.expect(!isKeyword("resume_"));
    try testing.expect(!isKeyword("resume_game"));
    // Primitives need no @"" after a dot -- out of scope by design.
    try testing.expect(!isKeyword("bool"));
    try testing.expect(!isKeyword("u8"));
    try testing.expect(!isKeyword(""));
}

test "firstKeywordSegment walks dotted keys" {
    try testing.expectEqualStrings("resume", firstKeywordSegment("pause.resume").?);
    try testing.expectEqualStrings("error", firstKeywordSegment("error.title").?);
    try testing.expect(firstKeywordSegment("pause.resume_game") == null);
    try testing.expect(firstKeywordSegment("menu.new_game") == null);
}

test "quoteDottedPath quotes exactly the segments a call site cannot write bare" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("pause.@\"resume\"", try quoteDottedPath(arena, "pause.resume"));
    try testing.expectEqualStrings("@\"error\".title", try quoteDottedPath(arena, "error.title"));
    try testing.expectEqualStrings("menu.new_game", try quoteDottedPath(arena, "menu.new_game"));
    // A raw pack name composes non-identifier segments into surfaced paths:
    // shape needs @"" as much as keyword-ness does.
    try testing.expectEqualStrings("@\"my-pack__hunger\".@\"resume\"", try quoteDottedPath(arena, "my-pack__hunger.resume"));
}
