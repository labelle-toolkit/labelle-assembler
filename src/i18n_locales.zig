//! Locale file parsing for RFC-I18N (labelle-engine#811 / #809), phase 1.
//!
//! One `locales/<tag>.jsonc` per language: nested objects, string leaves,
//! comments allowed (translator notes are genuinely useful). The filename is
//! the BCP-47 tag and the only place a locale is declared.
//!
//! The output is a flat, sorted map of dotted key -> string. Sorted here, once,
//! because key order is index order in the generated table and OQ3 (key type
//! stability) wants that deterministic regardless of file layout.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct {
    /// Dotted path, e.g. "menu.new_game". Every segment is a Zig identifier.
    key: []const u8,
    value: []const u8,
};

pub const Locale = struct {
    entries: []Entry,

    pub fn get(self: *const Locale, key: []const u8) ?[]const u8 {
        // Sorted, so this could bisect; locale files are small enough that
        // linear is clearer and the assembler runs this once per build.
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }
};

pub const Error = struct {
    /// A human-positionable description; JSONC positions are painful to carry
    /// through std.json, so errors name the key path instead of a line.
    msg: []const u8,
};

pub const ParseResult = union(enum) {
    ok: Locale,
    fail: Error,
};

/// Parses one locale file. Arena-owned, like constants_yaml.parse.
pub fn parse(arena: Allocator, source: []const u8) Allocator.Error!ParseResult {
    const stripped = try stripJsonc(arena, source);

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, stripped, .{}) catch {
        return .{ .fail = .{ .msg = try arena.dupe(u8, "not valid JSON (after comment stripping)") } };
    };

    const root = switch (parsed) {
        .object => |o| o,
        else => return .{ .fail = .{ .msg = try arena.dupe(u8, "the top level must be an object of keys") } },
    };

    var entries: std.ArrayList(Entry) = .empty;
    if (try flatten(arena, &entries, root, "")) |e| return .{ .fail = e };

    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lessThan);

    return .{ .ok = .{ .entries = entries.items } };
}

/// Walks the object tree into dotted keys. Returns an error description on the
/// first structural violation, null on success.
fn flatten(
    arena: Allocator,
    entries: *std.ArrayList(Entry),
    obj: std.json.ObjectMap,
    prefix: []const u8,
) Allocator.Error!?Error {
    var it = obj.iterator();
    while (it.next()) |kv| {
        const seg = kv.key_ptr.*;
        const path = if (prefix.len == 0)
            try arena.dupe(u8, seg)
        else
            try std.fmt.allocPrint(arena, "{s}.{s}", .{ prefix, seg });

        if (!isIdentifier(seg)) {
            return .{ .msg = try std.fmt.allocPrint(arena, "key '{s}': every segment must be a Zig identifier ([A-Za-z_][A-Za-z0-9_]*), because keys become K.<path> constants", .{path}) };
        }

        switch (kv.value_ptr.*) {
            .object => |child| {
                if (try flatten(arena, entries, child, path)) |e| return e;
            },
            .string => |s| {
                try entries.append(arena, .{ .key = path, .value = try arena.dupe(u8, s) });
            },
            else => {
                return .{ .msg = try std.fmt.allocPrint(arena, "key '{s}': locale values are strings; found {s}. Numbers belong in constants/ (RFC-CONSTANTS)", .{ path, @tagName(kv.value_ptr.*) }) };
            },
        }
    }
    return null;
}

/// Strips `//` and `/* */` comments outside string literals, plus trailing
/// commas before `}` / `]` (JSONC's two liberties the std parser lacks).
/// Comment bytes become spaces so any offsets std.json reports still line up.
pub fn stripJsonc(arena: Allocator, source: []const u8) Allocator.Error![]u8 {
    const out = try arena.dupe(u8, source);

    // Pass 1: comments -> spaces (newlines kept, so offsets stay plausible).
    var i: usize = 0;
    var in_string = false;
    while (i < out.len) : (i += 1) {
        const c = out[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '/' => {
                if (i + 1 < out.len and out[i + 1] == '/') {
                    while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
                    if (i < out.len) i -= 1;
                } else if (i + 1 < out.len and out[i + 1] == '*') {
                    while (i + 1 < out.len and !(out[i] == '*' and out[i + 1] == '/')) : (i += 1) {
                        if (out[i] != '\n') out[i] = ' ';
                    }
                    if (i + 1 < out.len) {
                        out[i] = ' ';
                        out[i + 1] = ' ';
                        i += 1;
                    }
                }
            },
            else => {},
        }
    }

    // Pass 2: trailing commas -> spaces. Runs after comment blanking so a
    // comment between the comma and the brace no longer hides the brace.
    i = 0;
    in_string = false;
    while (i < out.len) : (i += 1) {
        const c = out[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            ',' => {
                var j = i + 1;
                while (j < out.len and (out[j] == ' ' or out[j] == '\t' or out[j] == '\r' or out[j] == '\n')) : (j += 1) {}
                if (j < out.len and (out[j] == '}' or out[j] == ']')) out[i] = ' ';
            },
            else => {},
        }
    }
    return out;
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

fn parseOk(arena: Allocator, src: []const u8) !Locale {
    switch (try parse(arena, src)) {
        .ok => |l| return l,
        .fail => |e| {
            std.debug.print("unexpected locale parse failure: {s}\n", .{e.msg});
            return error.TestUnexpectedResult;
        },
    }
}

test "nested objects flatten to sorted dotted keys" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const l = try parseOk(arena_state.allocator(),
        \\{
        \\  "menu": {
        \\    "new_game": "Novo Jogo",
        \\    "exit": "Sair",
        \\  },
        \\  "hud": { "stock": "{count} de {max}" },
        \\}
    );
    try testing.expectEqual(@as(usize, 3), l.entries.len);
    // Sorted: hud.stock < menu.exit < menu.new_game
    try testing.expectEqualStrings("hud.stock", l.entries[0].key);
    try testing.expectEqualStrings("menu.exit", l.entries[1].key);
    try testing.expectEqualStrings("menu.new_game", l.entries[2].key);
    try testing.expectEqualStrings("Novo Jogo", l.get("menu.new_game").?);
}

test "comments and trailing commas are JSONC, and survive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const l = try parseOk(arena_state.allocator(),
        \\{
        \\  // translator note: keep it short, the button is narrow
        \\  "menu": {
        \\    "options": "Opções", /* inline too */
        \\  },
        \\}
    );
    try testing.expectEqualStrings("Opções", l.get("menu.options").?);
}

test "a non-string leaf is an error that points at constants" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    switch (try parse(arena_state.allocator(),
        \\{ "hud": { "max_items": 5 } }
    )) {
        .ok => return error.TestUnexpectedResult,
        .fail => |e| {
            try testing.expect(std.mem.indexOf(u8, e.msg, "hud.max_items") != null);
            try testing.expect(std.mem.indexOf(u8, e.msg, "RFC-CONSTANTS") != null);
        },
    }
}

test "a non-identifier key segment is an error naming the path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    switch (try parse(arena_state.allocator(),
        \\{ "menu": { "new-game": "x" } }
    )) {
        .ok => return error.TestUnexpectedResult,
        .fail => |e| try testing.expect(std.mem.indexOf(u8, e.msg, "menu.new-game") != null),
    }
}

test "comment markers inside strings are content, not comments" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const l = try parseOk(arena_state.allocator(),
        \\{ "help": { "url_hint": "see https://example.com // docs" } }
    );
    try testing.expectEqualStrings("see https://example.com // docs", l.get("help.url_hint").?);
}
