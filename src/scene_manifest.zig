/// Scene .jsonc manifest parsing for the labelle-assembler.
///
/// At codegen time the assembler peeks at each scene file in `scenes/` to:
///   1. Extract the optional top-level `assets:` array — a list of resource
///      names the scene wants the engine to preload before construction. The
///      assembler emits these as a comptime map (scene name → []const u8 slice
///      of asset names) consumed by labelle-engine's SceneEntry (issue #445).
///   2. Reject unknown top-level keys with a hard build error so typos like
///      `"asest"` instead of `"assets"` cannot silently disable preloading.
///
/// This module deliberately does not validate asset names against
/// `project.labelle` resources, nor offer Levenshtein "did you mean"
/// suggestions — those belong to a follow-up ticket.
const std = @import("std");

/// Parsed manifest for a single scene file.
pub const SceneManifest = struct {
    /// Scene name as known by the assembler (path-style: "menu", "world/intro").
    /// Owned by the caller (typically the slice from `copyAndScan`).
    name: []const u8,
    /// Assets requested by the scene's top-level `assets:` array. May be empty.
    /// Each string is owned by this manifest's allocator.
    assets: []const []const u8,
};

/// Whitelisted top-level keys allowed in a scene .jsonc file. Anything outside
/// this set triggers `error.UnknownSceneKey` so typos are caught at build time.
///
/// The set unions every key the engine's JsoncSceneBridge currently consumes
/// (`include`, `entities`) with cosmetic keys observed in real scenes
/// (`name`, `scripts`) and the new `assets` key parsed here. Adding a real new
/// scene-level key in the future means adding it here too — that is the
/// intended speed bump.
const ALLOWED_TOP_LEVEL_KEYS: []const []const u8 = &.{
    "name",
    "assets",
    "include",
    "entities",
    "scripts",
};

fn isAllowedTopLevelKey(key: []const u8) bool {
    for (ALLOWED_TOP_LEVEL_KEYS) |allowed| {
        if (std.mem.eql(u8, key, allowed)) return true;
    }
    return false;
}

/// Errors surfaced from manifest parsing. `UnknownSceneKey` and
/// `InvalidAssetsField` are hard build errors — the assembler must abort and
/// print a clear message naming the offending file.
pub const ParseError = error{
    UnknownSceneKey,
    InvalidAssetsField,
    InvalidSceneJson,
    OutOfMemory,
};

/// Strip JSONC line + block comments and trailing commas from `source`,
/// returning a freshly allocated buffer the caller owns.
///
/// The strategy preserves byte offsets where possible by overwriting comment
/// runs with spaces, so any error spans reported by `std.json` line up with
/// the original file. This is intentionally a tiny purpose-built routine —
/// the assembler only needs to read top-level keys, so a full JSONC parser
/// would be over-engineered.
fn stripJsonc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, source.len);
    @memcpy(out, source);

    var i: usize = 0;
    var in_string = false;
    while (i < out.len) {
        const c = out[i];
        if (in_string) {
            if (c == '\\' and i + 1 < out.len) {
                i += 2;
                continue;
            }
            if (c == '"') in_string = false;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < out.len) {
            const next = out[i + 1];
            if (next == '/') {
                // Line comment — blank to end of line.
                while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
                continue;
            }
            if (next == '*') {
                // Block comment — blank to closing */, preserving newlines.
                out[i] = ' ';
                out[i + 1] = ' ';
                i += 2;
                while (i + 1 < out.len and !(out[i] == '*' and out[i + 1] == '/')) : (i += 1) {
                    if (out[i] != '\n') out[i] = ' ';
                }
                if (i + 1 < out.len) {
                    out[i] = ' ';
                    out[i + 1] = ' ';
                    i += 2;
                }
                continue;
            }
        }
        i += 1;
    }

    // Second pass: blank trailing commas (`, }` and `, ]`) so std.json accepts
    // the JSONC dialect without complaining. Whitespace between `,` and the
    // closer is allowed; we also tolerate newlines.
    in_string = false;
    i = 0;
    while (i < out.len) : (i += 1) {
        const c = out[i];
        if (in_string) {
            if (c == '\\' and i + 1 < out.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }
        if (c == ',') {
            var j = i + 1;
            while (j < out.len and (out[j] == ' ' or out[j] == '\t' or out[j] == '\n' or out[j] == '\r')) : (j += 1) {}
            if (j < out.len and (out[j] == '}' or out[j] == ']')) {
                out[i] = ' ';
            }
        }
    }

    return out;
}

/// Parse a single scene file's source buffer. `scene_name` is the name the
/// assembler uses elsewhere (e.g. "menu" or "world/intro") and `display_path`
/// is the path printed in error messages so users can find the offending file.
///
/// Returns a `SceneManifest` whose `assets` slice (and the contained strings)
/// are allocated from `allocator`. Caller frees via `freeManifest`.
pub fn parseSceneSource(
    allocator: std.mem.Allocator,
    scene_name: []const u8,
    display_path: []const u8,
    source: []const u8,
) ParseError!SceneManifest {
    const stripped = stripJsonc(allocator, source) catch return error.OutOfMemory;
    defer allocator.free(stripped);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, stripped, .{}) catch |err| {
        std.debug.print(
            "labelle-assembler: failed to parse scene '{s}': {s}\n",
            .{ display_path, @errorName(err) },
        );
        return error.InvalidSceneJson;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => {
            std.debug.print(
                "labelle-assembler: scene '{s}' must have a top-level JSON object\n",
                .{display_path},
            );
            return error.InvalidSceneJson;
        },
    };

    // Unknown-key guard. Run this BEFORE reading any field so we always report
    // typos even when the rest of the file looks valid.
    var key_iter = root.iterator();
    while (key_iter.next()) |entry| {
        if (!isAllowedTopLevelKey(entry.key_ptr.*)) {
            std.debug.print(
                "labelle-assembler: unknown top-level key '{s}' in scene '{s}'.\n" ++
                    "  Allowed keys: name, assets, include, entities, scripts\n" ++
                    "  (Did-you-mean suggestions land in labelle-assembler#47.)\n",
                .{ entry.key_ptr.*, display_path },
            );
            return error.UnknownSceneKey;
        }
    }

    // Read assets — optional, default empty.
    var assets: []const []const u8 = &.{};
    if (root.get("assets")) |assets_val| {
        const arr = switch (assets_val) {
            .array => |a| a,
            else => {
                std.debug.print(
                    "labelle-assembler: scene '{s}' has 'assets' but it is not an array\n",
                    .{display_path},
                );
                return error.InvalidAssetsField;
            },
        };

        if (arr.items.len > 0) {
            var list = try allocator.alloc([]const u8, arr.items.len);
            var n: usize = 0;
            errdefer {
                for (list[0..n]) |s| allocator.free(s);
                allocator.free(list);
            }
            for (arr.items) |item| {
                switch (item) {
                    .string => |s| {
                        list[n] = try allocator.dupe(u8, s);
                        n += 1;
                    },
                    else => {
                        std.debug.print(
                            "labelle-assembler: scene '{s}' has a non-string entry in 'assets'\n",
                            .{display_path},
                        );
                        return error.InvalidAssetsField;
                    },
                }
            }
            assets = list;
        }
    }

    return .{
        .name = scene_name,
        .assets = assets,
    };
}

/// Free the strings + slice owned by a manifest produced by parseSceneSource.
pub fn freeManifest(allocator: std.mem.Allocator, manifest: SceneManifest) void {
    for (manifest.assets) |s| allocator.free(s);
    if (manifest.assets.len > 0) {
        allocator.free(manifest.assets);
    }
}

/// Free a slice of manifests in one shot.
pub fn freeManifests(allocator: std.mem.Allocator, manifests: []const SceneManifest) void {
    for (manifests) |m| freeManifest(allocator, m);
    allocator.free(manifests);
}

/// Read every `<scenes_dir>/<name>.jsonc` (where `name` is one of `scene_names`,
/// possibly with subfolder slashes), parse it, and return the manifest list in
/// the same order as `scene_names`.
///
/// Hard-aborts (returns error) on the first scene that fails the unknown-key
/// guard or has a malformed `assets:` field.
pub fn parseSceneDir(
    allocator: std.mem.Allocator,
    scenes_dir: []const u8,
    scene_names: []const []const u8,
) ![]SceneManifest {
    var manifests = try allocator.alloc(SceneManifest, scene_names.len);
    var n: usize = 0;
    errdefer {
        for (manifests[0..n]) |m| freeManifest(allocator, m);
        allocator.free(manifests);
    }

    for (scene_names) |name| {
        const rel = try std.fmt.allocPrint(allocator, "{s}/{s}.jsonc", .{ scenes_dir, name });
        defer allocator.free(rel);

        const source = std.fs.cwd().readFileAlloc(allocator, rel, 1024 * 1024) catch |err| {
            std.debug.print(
                "labelle-assembler: could not read scene '{s}': {s}\n",
                .{ rel, @errorName(err) },
            );
            return err;
        };
        defer allocator.free(source);

        manifests[n] = try parseSceneSource(allocator, name, rel, source);
        n += 1;
    }

    return manifests;
}

// ───── Tests ──────────────────────────────────────────────────────────

test "parses scene with assets array" {
    const src =
        \\{
        \\    "name": "menu",
        \\    "assets": ["background", "ship"],
        \\    "entities": []
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);

    try std.testing.expectEqual(@as(usize, 2), m.assets.len);
    try std.testing.expectEqualStrings("background", m.assets[0]);
    try std.testing.expectEqualStrings("ship", m.assets[1]);
}

test "scene without assets key yields empty slice" {
    const src =
        \\{
        \\    "name": "menu",
        \\    "entities": []
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 0), m.assets.len);
}

test "empty assets array yields empty slice" {
    const src =
        \\{
        \\    "assets": [],
        \\    "entities": []
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 0), m.assets.len);
}

test "unknown top-level key is a hard error" {
    const src =
        \\{
        \\    "name": "menu",
        \\    "asest": ["background"],
        \\    "entities": []
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "menu", "scenes/menu.jsonc", src);
    try std.testing.expectError(error.UnknownSceneKey, result);
}

test "singular 'asset' typo is a hard error" {
    const src =
        \\{
        \\    "asset": ["background"]
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "menu", "scenes/menu.jsonc", src);
    try std.testing.expectError(error.UnknownSceneKey, result);
}

test "assets and entities coexist (back-compat)" {
    const src =
        \\{
        \\    "name": "menu",
        \\    "assets": ["a", "b"],
        \\    "entities": [
        \\        { "prefab": "player" }
        \\    ]
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 2), m.assets.len);
    try std.testing.expectEqualStrings("a", m.assets[0]);
    try std.testing.expectEqualStrings("b", m.assets[1]);
}

test "JSONC line comments are stripped" {
    const src =
        \\{
        \\    // top comment
        \\    "name": "menu", // trailing comment
        \\    "assets": ["a"] // another
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 1), m.assets.len);
}

test "JSONC block comments and trailing commas are tolerated" {
    const src =
        \\{
        \\    /* block
        \\       comment */
        \\    "assets": [
        \\        "a",
        \\        "b",
        \\    ],
        \\    "entities": [],
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 2), m.assets.len);
}

test "non-string asset entry is a hard error" {
    const src =
        \\{
        \\    "assets": ["good", 42]
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    try std.testing.expectError(error.InvalidAssetsField, result);
}

test "non-array assets field is a hard error" {
    const src =
        \\{
        \\    "assets": "background"
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    try std.testing.expectError(error.InvalidAssetsField, result);
}

test "comment-only string content is preserved" {
    // Make sure we don't accidentally treat // inside a string as a comment.
    const src =
        \\{
        \\    "name": "url://example",
        \\    "assets": ["a/b"]
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "url", "url.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 1), m.assets.len);
    try std.testing.expectEqualStrings("a/b", m.assets[0]);
}
