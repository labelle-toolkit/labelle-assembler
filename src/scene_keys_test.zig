//! Tests for `scene_keys.zig` and for every walker that classifies scene
//! keys through it (labelle-assembler#651 escaped spellings, #652 flat
//! pack-namespaced keys). Discovered via the `test {}` block in `root.zig`.

const std = @import("std");
const scene_keys = @import("scene_keys.zig");
const scene_manifest = @import("scene_manifest.zig");
const scene_name_lint = @import("scene_name_lint.zig");
const pack_refs = @import("codegen/scan/pack_refs.zig");

const Class = scene_keys.Class;

/// Reference classification of a DECODED key, spelled out from the engine's
/// `unified_format.zig` (`isTargetKey`, then `isComponentKeyShape`).
fn engineClass(decoded: []const u8) Class {
    if (scene_keys.isTargetKey(decoded)) return .target;
    if (scene_keys.isComponentKeyShape(decoded)) return .component;
    return .structural;
}

// ── Decoded-key rules: engine parity (#652) ────────────────────────────────

test "scene_keys: component-key shape matches engine unified_format (table)" {
    const cases = [_]struct { key: []const u8, component: bool, flat: bool }{
        .{ .key = "Worker", .component = true, .flat = true },
        .{ .key = "industry__TendableWorkstation", .component = true, .flat = true },
        .{ .key = "rooms__Room", .component = true, .flat = true },
        // Suffix after the LAST `__` decides.
        .{ .key = "a__b__Room", .component = true, .flat = true },
        .{ .key = "a__Room__b", .component = false, .flat = false },
        .{ .key = "capacity__oops", .component = false, .flat = false },
        // Empty prefix / empty suffix.
        .{ .key = "__Worker", .component = false, .flat = false },
        .{ .key = "rooms__", .component = false, .flat = false },
        .{ .key = "rooms_Room", .component = false, .flat = false },
        .{ .key = "prefab", .component = false, .flat = false },
        .{ .key = "children", .component = false, .flat = false },
        .{ .key = "", .component = false, .flat = false },
        .{ .key = "@slot", .component = false, .flat = true },
        .{ .key = "@", .component = false, .flat = false },
    };
    for (cases) |c| {
        errdefer std.debug.print("key '{s}'\n", .{c.key});
        try std.testing.expectEqual(c.component, scene_keys.isComponentKeyShape(c.key));
        try std.testing.expectEqual(c.flat, scene_keys.isFlatComponentKey(c.key));
        // No escapes, so the raw path must agree with the decoded rules.
        try std.testing.expectEqual(c.flat, scene_keys.rawIsFlatComponentKey(c.key));
    }
}

// ── Escaped spellings (#651) ───────────────────────────────────────────────

test "scene_keys: decode mirrors the engine parser's escape set" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("W/orker", try scene_keys.decode("W\\/orker", &buf));
    try std.testing.expectEqualStrings("a\"b\\c\n", try scene_keys.decode("a\\\"b\\\\c\\n", &buf));
    // `\u` is NOT decoded by the engine: its parser fails the file.
    try std.testing.expectError(error.InvalidEscape, scene_keys.decode("\\u0057orker", &buf));
    try std.testing.expectError(error.InvalidEscape, scene_keys.decode("\\u0040slot", &buf));
    try std.testing.expectError(error.InvalidEscape, scene_keys.decode("Worker\\", &buf));
    try std.testing.expectError(error.InvalidEscape, scene_keys.decode("Wor\\ker", &buf));
}

test "scene_keys: escaped spellings classify like their decoded key (table)" {
    // Every key here is loadable by the engine; the raw classification must
    // equal the engine's classification of the decoded key.
    const cases = [_]struct { raw: []const u8, want: Class }{
        .{ .raw = "Worker", .want = .component },
        .{ .raw = "Wor\\/ker", .want = .component },
        .{ .raw = "Worker\\n", .want = .component },
        .{ .raw = "rooms__Ro\\\"om", .want = .component },
        .{ .raw = "ro\\toms__Room", .want = .component },
        .{ .raw = "rooms__\\/Room", .want = .structural },
        .{ .raw = "\\/Worker", .want = .structural },
        .{ .raw = "\\\\Worker", .want = .structural },
        .{ .raw = "@slot", .want = .target },
        .{ .raw = "@\\/slot", .want = .target },
        .{ .raw = "@\\n", .want = .target },
        .{ .raw = "\\/@slot", .want = .structural },
        .{ .raw = "compo\\/nents", .want = .structural },
        .{ .raw = "prefab", .want = .structural },
    };
    var buf: [64]u8 = undefined;
    for (cases) |c| {
        errdefer std.debug.print("raw '{s}'\n", .{c.raw});
        const decoded = try scene_keys.decode(c.raw, &buf);
        try std.testing.expectEqual(c.want, engineClass(decoded));
        try std.testing.expectEqual(c.want, scene_keys.classifyRaw(c.raw));
    }
}

test "scene_keys: raw == decoded classification for every accepted escape at every position" {
    // Exhaustive over the engine's escape letters and insertion points in a
    // set of base keys that cover each rule (PascalCase first byte,
    // namespaced suffix, `@` target, structural names).
    const bases = [_][]const u8{ "Worker", "rooms__Room", "a__b__C", "@slot", "prefab", "components", "x__y", "@" };
    const letters = "ntrbf\\\"/";
    var raw_buf: [64]u8 = undefined;
    var dec_buf: [64]u8 = undefined;
    for (bases) |base| {
        for (letters) |letter| {
            var pos: usize = 0;
            while (pos <= base.len) : (pos += 1) {
                const raw = try std.fmt.bufPrint(&raw_buf, "{s}\\{c}{s}", .{ base[0..pos], letter, base[pos..] });
                const decoded = try scene_keys.decode(raw, &dec_buf);
                errdefer std.debug.print("raw '{s}'\n", .{raw});
                try std.testing.expectEqual(engineClass(decoded), scene_keys.classifyRaw(raw));
            }
        }
    }
}

test "scene_keys: \\u spellings are unloadable, never content" {
    const cases = [_][]const u8{ "\\u0057orker", "\\u0040slot", "rooms__\\u0052oom", "Worker\\u0021", "\\u0063omponents" };
    for (cases) |raw| {
        errdefer std.debug.print("raw '{s}'\n", .{raw});
        try std.testing.expectEqual(Class.unloadable, scene_keys.classifyRaw(raw));
        try std.testing.expect(!scene_keys.rawIsFlatComponentKey(raw));
        try std.testing.expect(!scene_keys.rawIsTargetKey(raw));
    }
}

test "scene_keys: firstInvalidEscape finds engine-rejected escapes in strings only" {
    try std.testing.expectEqual(@as(?usize, null), scene_keys.firstInvalidEscape(
        \\{ "W\/orker": { "s": "a\"b\\c\n" } }
    ));
    // In a comment: the engine skips comments, so this is fine.
    try std.testing.expectEqual(@as(?usize, null), scene_keys.firstInvalidEscape(
        \\{ // "\u0057orker"
        \\  /* "\u0040slot" */ "Worker": {} }
    ));
    const src = "{ \"\\u0057orker\": {} }";
    try std.testing.expectEqual(@as(?usize, 3), scene_keys.firstInvalidEscape(src));
    // Values count too: the engine's parser decodes every string.
    try std.testing.expect(scene_keys.firstInvalidEscape("{ \"Label\": { \"t\": \"caf\\u00e9\" } }") != null);
}

// ── Walkers: scene_manifest (std.json path) ────────────────────────────────

test "scene_manifest: flat pack-namespaced top-level key is accepted (#652)" {
    const m = try scene_manifest.parseSceneSource(std.testing.allocator, "s", "s.jsonc",
        \\{ "prefab": "room", "rooms__Room": { "w": 3 } }
    );
    defer scene_manifest.freeManifest(std.testing.allocator, m);
}

test "scene_manifest: top-level keys are accepted exactly where the engine accepts them (table)" {
    const cases = [_]struct { src: []const u8, ok: bool }{
        .{ .src = "{ \"prefab\": \"room\", \"rooms__Room\": {} }", .ok = true },
        .{ .src = "{ \"prefab\": \"room\", \"a__b__Room\": {} }", .ok = true },
        .{ .src = "{ \"prefab\": \"room\", \"Room\": {} }", .ok = true },
        .{ .src = "{ \"prefab\": \"room\", \"capacity__oops\": {} }", .ok = false },
        .{ .src = "{ \"prefab\": \"room\", \"__Room\": {} }", .ok = false },
        .{ .src = "{ \"prefab\": \"room\", \"rooms_Room\": {} }", .ok = false },
    };
    for (cases) |c| {
        errdefer std.debug.print("src {s}\n", .{c.src});
        const r = scene_manifest.parseSceneSource(std.testing.allocator, "s", "s.jsonc", c.src);
        if (c.ok) {
            scene_manifest.freeManifest(std.testing.allocator, try r);
        } else {
            try std.testing.expectError(error.UnknownSceneKey, r);
        }
    }
}

test "scene_manifest: a namespaced-only file is flat form, and namespaced + wrapper is hybrid (#652)" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{ "rooms__Room": {} }
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("top level", (try scene_manifest.classifyTopLevel(parsed.value.object)).?);

    var hybrid = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{ "prefab": "room", "overrides": { "Room": {} }, "rooms__Room": {} }
    , .{});
    defer hybrid.deinit();
    try std.testing.expectEqualStrings("overrides", scene_manifest.checkHybridForm(hybrid.value.object).?);

    // A lowercase non-component `__` key is not content: no hybrid.
    var not_hybrid = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{ "prefab": "room", "overrides": { "Room": {} }, "meta__notes": {} }
    , .{});
    defer not_hybrid.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), scene_manifest.checkHybridForm(not_hybrid.value.object));

    try std.testing.expectError(error.HybridForm, scene_manifest.parseSceneSource(std.testing.allocator, "s", "s.jsonc",
        \\{ "components": { "Position": {} }, "rooms__Room": {} }
    ));
}

test "scene_manifest: a \\u escape the engine cannot load is rejected before std.json decodes it (#651)" {
    // std.json alone would decode this to a valid `Worker` component.
    try std.testing.expectError(error.InvalidSceneJson, scene_manifest.parseSceneSource(std.testing.allocator, "s", "s.jsonc",
        \\{ "prefab": "p", "\u0057orker": {} }
    ));
    try std.testing.expectError(error.InvalidSceneJson, scene_manifest.parseSceneSource(std.testing.allocator, "s", "s.jsonc",
        \\{ "name": "caf\u00e9", "entities": [] }
    ));
    // Engine-accepted escapes still parse.
    const m = try scene_manifest.parseSceneSource(std.testing.allocator, "s", "s.jsonc",
        \\{ "name": "a\/b", "prefab": "p", "Worker": {} } // "\u0057"
    );
    scene_manifest.freeManifest(std.testing.allocator, m);
}

// ── Walkers: scene_name_lint ───────────────────────────────────────────────

fn refNames(arena: std.mem.Allocator, src: []const u8) ![]const []const u8 {
    const refs = try scene_name_lint.collectComponentRefs(arena, src);
    const names = try arena.alloc([]const u8, refs.len);
    for (refs, names) |r, *n| n.* = r.name;
    return names;
}

test "scene_name_lint: flat entity-scope refs follow the engine's key shape (table)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cases = [_]struct { key: []const u8, is_ref: bool }{
        .{ .key = "Worker", .is_ref = true },
        .{ .key = "citizens__Worker", .is_ref = true }, // #652
        .{ .key = "Wor\\/ker", .is_ref = true }, // #651: escaped, still a component
        .{ .key = "capacity__oops", .is_ref = false },
        .{ .key = "__Worker", .is_ref = false },
        .{ .key = "meta", .is_ref = false },
        .{ .key = "\\u0057orker", .is_ref = false }, // engine can't load it
    };
    for (cases) |c| {
        errdefer std.debug.print("key '{s}'\n", .{c.key});
        const src = try std.fmt.allocPrint(arena, "{{ \"prefab\": \"p\", \"{s}\": {{ \"Inner\": 1 }} }}", .{c.key});
        const names = try refNames(arena, src);
        if (c.is_ref) {
            try std.testing.expectEqual(@as(usize, 1), names.len);
            try std.testing.expectEqualStrings(c.key, names[0]);
        } else {
            // And the value stays payload: `Inner` is never a ref.
            try std.testing.expectEqual(@as(usize, 0), names.len);
        }
    }
}

test "scene_name_lint: @ gate classifies escaped spellings like the engine (#651)" {
    try std.testing.expect(scene_name_lint.sourceUsesTargetKeys(
        \\{ "prefab": "m", "@slot": { "Storage": {} } }
    ));
    try std.testing.expect(scene_name_lint.sourceUsesTargetKeys(
        \\{ "prefab": "m", "@\/slot": { "Storage": {} } }
    ));
    // The engine's parser rejects `\u` on every version, so this file never
    // loads anywhere: no silent drop for the version gate to catch.
    try std.testing.expect(!scene_name_lint.sourceUsesTargetKeys(
        \\{ "prefab": "m", "\u0040slot": { "Storage": {} } }
    ));
    // A namespaced flat component opens a payload, not a component map, so
    // an `@` key below it is payload data.
    try std.testing.expect(!scene_name_lint.sourceUsesTargetKeys(
        \\{ "prefab": "m", "rooms__Room": { "@id": 1 } }
    ));
}

// ── Walkers: pack rewrite (pass 1 + pass 2) ────────────────────────────────

fn rewrite(src: []const u8) ![]u8 {
    return pack_refs.rewritePackLocalRefs(std.testing.allocator, src, &.{"Worker"}, &.{}, "citizens");
}

/// Compare ignoring spaces: pass 1 keeps the author's trivia around moved
/// pairs, and these tests pin WHERE each pair lands, not the spacing.
fn expectSameShape(expected: []const u8, actual: []const u8) !void {
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(std.testing.allocator);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    for (expected) |c| if (c != ' ') try a.append(std.testing.allocator, c);
    for (actual) |c| if (c != ' ') try b.append(std.testing.allocator, c);
    try std.testing.expectEqualStrings(a.items, b.items);
}

test "pack rewrite: flat namespaced pairs move into the synthesized wrapper (#652)" {
    const out = try rewrite(
        \\{ "prefab": "base", "Worker": { "hp": 1 }, "rooms__Room": { "w": 2 } }
    );
    defer std.testing.allocator.free(out);
    // One wrapper, and the namespaced pair is INSIDE it. Left flat beside
    // the wrapper, the engine would warn wrapper-wins and drop it.
    try expectSameShape(
        \\{ "prefab": "base", "overrides": { "citizens__Worker": { "hp": 1 }, "rooms__Room": { "w": 2 } } }
    , out);
}

test "pack rewrite: which flat keys ride into the wrapper follows the engine (table)" {
    const cases = [_]struct { key: []const u8, moves: bool }{
        .{ .key = "Other", .moves = true },
        .{ .key = "rooms__Room", .moves = true }, // #652
        .{ .key = "Oth\\/er", .moves = true }, // #651: escaped component
        .{ .key = "@slot", .moves = true },
        .{ .key = "@\\/slot", .moves = true }, // #651: escaped target
        .{ .key = "capacity__oops", .moves = false },
        .{ .key = "meta", .moves = false },
        .{ .key = "\\u0040slot", .moves = false }, // unloadable: inert
        .{ .key = "\\u0057orker", .moves = false }, // unloadable: inert
    };
    for (cases) |c| {
        errdefer std.debug.print("key '{s}'\n", .{c.key});
        const src = try std.fmt.allocPrint(std.testing.allocator, "{{ \"prefab\": \"base\", \"Worker\": {{}}, \"{s}\": {{ \"v\": 1 }} }}", .{c.key});
        defer std.testing.allocator.free(src);
        const out = try rewrite(src);
        defer std.testing.allocator.free(out);
        const moved = try std.fmt.allocPrint(std.testing.allocator, "{{ \"prefab\": \"base\", \"overrides\": {{ \"citizens__Worker\": {{}}, \"{s}\": {{ \"v\": 1 }} }} }}", .{c.key});
        defer std.testing.allocator.free(moved);
        const stayed = try std.fmt.allocPrint(std.testing.allocator, "{{ \"prefab\": \"base\", \"overrides\": {{ \"citizens__Worker\": {{}} }}, \"{s}\": {{ \"v\": 1 }} }}", .{c.key});
        defer std.testing.allocator.free(stayed);
        try expectSameShape(if (c.moves) moved else stayed, out);
    }
}

test "pack rewrite: an escaped @ target's value is a component map exactly when the engine loads it (#651)" {
    // Loadable escape: the target opens a component map, so `Worker` under
    // it is namespaced.
    const ok = try rewrite(
        \\{ "prefab": "base", "overrides": { "@\/slot": { "Worker": { "hp": 9 } } } }
    );
    defer std.testing.allocator.free(ok);
    try std.testing.expect(std.mem.indexOf(u8, ok, "\"citizens__Worker\": { \"hp\": 9 }") != null);
    // `\u`: the file never loads, and the walker leaves it byte-identical.
    const src =
        \\{ "prefab": "base", "overrides": { "\u0040slot": { "Worker": { "hp": 9 } } } }
    ;
    const inert = try rewrite(src);
    defer std.testing.allocator.free(inert);
    try std.testing.expectEqualStrings(src, inert);
}
