//! Placeholder parsing for RFC-I18N §4 (phase 2).
//!
//! `{name}` is a placeholder; `{{` and `}}` are literal braces, matching
//! std.fmt so nobody learns two escape rules. A string parses into segments —
//! literal runs and argument references — which is the shape `tf` needs at
//! runtime: the string is chosen by the *active locale* while the arguments
//! are comptime, so the reference locale's placeholder order proves nothing
//! about any other locale's. Word order is the thing translation changes
//! ("{count} of {max}" vs "Von {max} Artikeln: {count}"), and a naïve
//! comptime-format-string implementation renders every reordering locale
//! wrong. Codegen therefore emits one segment list per (key, locale) and the
//! generated `tf` walks the active one.
//!
//! Parsing happens here, once, at build time; nothing in the shipped game
//! scans for braces.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Segment = union(enum) {
    lit: []const u8,
    /// The placeholder's name; resolved against the Args struct at runtime by
    /// the generated tf via an inline field walk.
    arg: []const u8,
};

pub const ParseResult = union(enum) {
    ok: []Segment,
    fail: []const u8, // message
};

/// Parses one translated string into segments. Escapes are resolved here —
/// a `{{` arrives in the segment list as a literal `{`.
pub fn parse(arena: Allocator, s: []const u8) Allocator.Error!ParseResult {
    var segs: std.ArrayList(Segment) = .empty;
    var lit: std.ArrayList(u8) = .empty;

    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '{') {
            if (i + 1 < s.len and s[i + 1] == '{') {
                try lit.append(arena, '{');
                i += 2;
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, s, i + 1, '}') orelse {
                return .{ .fail = try std.fmt.allocPrint(arena, "unclosed '{{' at byte {d}; write '{{{{' for a literal brace", .{i}) };
            };
            const name = s[i + 1 .. end];
            if (!isIdentifier(name)) {
                return .{ .fail = try std.fmt.allocPrint(arena, "placeholder '{{{s}}}' is not an identifier", .{name}) };
            }
            if (lit.items.len > 0) {
                try segs.append(arena, .{ .lit = try arena.dupe(u8, lit.items) });
                lit.clearRetainingCapacity();
            }
            try segs.append(arena, .{ .arg = try arena.dupe(u8, name) });
            i = end + 1;
            continue;
        }
        if (c == '}') {
            if (i + 1 < s.len and s[i + 1] == '}') {
                try lit.append(arena, '}');
                i += 2;
                continue;
            }
            return .{ .fail = try std.fmt.allocPrint(arena, "stray '}}' at byte {d}; write '}}}}' for a literal brace", .{i}) };
        }
        try lit.append(arena, c);
        i += 1;
    }
    if (lit.items.len > 0) {
        try segs.append(arena, .{ .lit = try arena.dupe(u8, lit.items) });
    }
    return .{ .ok = segs.items };
}

/// The sorted, deduplicated placeholder names of a parsed string. Sorted so
/// two strings with the same set in different orders compare equal — order is
/// legitimate translation, never drift (§3 checks *sets*).
pub fn names(arena: Allocator, segs: []const Segment) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (segs) |seg| {
        switch (seg) {
            .arg => |n| {
                var seen = false;
                for (out.items) |existing| {
                    if (std.mem.eql(u8, existing, n)) seen = true;
                }
                if (!seen) try out.append(arena, n);
            },
            .lit => {},
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return out.items;
}

pub fn sameNames(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseOk(arena: Allocator, s: []const u8) ![]Segment {
    switch (try parse(arena, s)) {
        .ok => |segs| return segs,
        .fail => |msg| {
            std.debug.print("unexpected: {s}\n", .{msg});
            return error.TestUnexpectedResult;
        },
    }
}

test "plain text is one literal segment; placeholders split it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const plain = try parseOk(a, "New Game");
    try testing.expectEqual(@as(usize, 1), plain.len);
    try testing.expectEqualStrings("New Game", plain[0].lit);

    const segs = try parseOk(a, "{count} de {max}");
    try testing.expectEqual(@as(usize, 3), segs.len);
    try testing.expectEqualStrings("count", segs[0].arg);
    try testing.expectEqualStrings(" de ", segs[1].lit);
    try testing.expectEqualStrings("max", segs[2].arg);
}

test "reordering produces the same name set -- order is translation, not drift" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const en = try names(a, try parseOk(a, "{count} of {max} items"));
    const de = try names(a, try parseOk(a, "Von {max} Artikeln: {count}"));
    try testing.expect(sameNames(en, de));
}

test "double braces are literal braces" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const segs = try parseOk(a, "{{not_a_placeholder}} but {real}");
    try testing.expectEqualStrings("{not_a_placeholder} but ", segs[0].lit);
    try testing.expectEqualStrings("real", segs[1].arg);
}

test "unclosed and stray braces are errors that teach the escape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    switch (try parse(a, "broken {")) {
        .ok => return error.TestUnexpectedResult,
        .fail => |m| try testing.expect(std.mem.indexOf(u8, m, "unclosed") != null),
    }
    switch (try parse(a, "broken } here")) {
        .ok => return error.TestUnexpectedResult,
        .fail => |m| try testing.expect(std.mem.indexOf(u8, m, "stray") != null),
    }
    switch (try parse(a, "{not valid}")) {
        .ok => return error.TestUnexpectedResult,
        .fail => |m| try testing.expect(std.mem.indexOf(u8, m, "identifier") != null),
    }
}

test "a repeated placeholder counts once in the name set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const ns = try names(a, try parseOk(a, "{n} and {n} again"));
    try testing.expectEqual(@as(usize, 1), ns.len);
}
