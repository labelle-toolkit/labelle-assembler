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
/// suggestions for unknown top-level scene keys — asset-name
/// validation lives in `asset_validator.zig` (ticket #47).
const std = @import("std");
const config = @import("config.zig");

/// Parsed manifest for a single scene file.
pub const SceneManifest = struct {
    /// Scene name as known by the assembler (path-style: "menu", "world/intro").
    /// Owned by the caller (typically the slice from `copyAndScan`).
    name: []const u8,
    /// Assets requested by the scene's top-level `assets:` array. May be empty.
    /// Each string is owned by this manifest's allocator.
    assets: []const []const u8,
    /// Game state the scene wants `setScene` to transition into after load.
    /// `null` means the scene didn't declare one; `setScene` leaves the
    /// game state untouched (current behavior). When non-null, codegen
    /// emits a `setSceneInitialState(name, state)` call so the engine
    /// honors it at runtime. See labelle-engine#500.
    /// String is owned by this manifest's allocator.
    initial_state: ?[]const u8 = null,
};

/// Whitelisted top-level keys allowed in a scene .jsonc file. Anything outside
/// this set triggers `error.UnknownSceneKey` so typos are caught at build time.
///
/// The set unions every key the engine's JsoncSceneBridge currently consumes
/// (`include`, `entities`, plus the unified `root` block from RFC #560)
/// with cosmetic keys observed in real scenes (`name`, `scripts`) and the
/// `assets` key parsed here. Adding a real new scene-level key in the
/// future means adding it here too — that is the intended speed bump.
///
/// `root` is the unified-format wrapper introduced by
/// labelle-engine#573 / RFC-UNIFY-SCENES-AND-PREFABS.md (§"Unified shape").
/// A unified scene puts its entity list under `root.children` instead of
/// the legacy top-level `entities` array; the assembler accepts both so
/// in-tree projects can migrate file-by-file without breaking the pre-build
/// scan (issue #181).
const ALLOWED_TOP_LEVEL_KEYS: []const []const u8 = &.{
    "name",
    "assets",
    "include",
    "entities",
    "root",
    "scripts",
    "initial_state",
};

fn isAllowedTopLevelKey(key: []const u8) bool {
    for (ALLOWED_TOP_LEVEL_KEYS) |allowed| {
        if (std.mem.eql(u8, key, allowed)) return true;
    }
    return false;
}

/// Errors surfaced from manifest parsing. `UnknownSceneKey`,
/// `InvalidAssetsField`, `InvalidInitialStateField`, and
/// `InvalidEntityShape` are hard build errors — the assembler must
/// abort and print a clear message naming the offending file.
///
/// `InvalidEntityShape` covers RFC #560 §B2 violations: an entity
/// entry that declares both `prefab` (reference mode) and `children`
/// (authoring mode), plus malformed `root` blocks under the unified
/// format.
pub const ParseError = error{
    UnknownSceneKey,
    InvalidAssetsField,
    InvalidInitialStateField,
    InvalidEntityShape,
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

/// Validate a unified-format `root` block. The block must be a JSON
/// object; it carries either inline content (`components`/`children`)
/// or a reference (`prefab`/`overrides`). Walks the `children` array
/// recursively to enforce §B2 on every descendant.
///
/// Mirrors the engine loader's two-mode grammar (see
/// labelle-engine/src/jsonc/unified_format.zig). The assembler doesn't
/// need the full accessor surface — it only needs to descend the tree
/// far enough to catch §B2 violations early, with a clear scene-path
/// in the error message.
fn validateRootBlock(value: std.json.Value, display_path: []const u8) ParseError!void {
    const obj = switch (value) {
        .object => |o| o,
        else => {
            std.debug.print(
                "labelle-assembler: scene '{s}' has 'root' but it is not a JSON object.\n" ++
                    "  Expected: \"root\": {{ \"children\": [...] }} or \"root\": {{ \"prefab\": \"...\" }}.\n" ++
                    "  See labelle-engine/RFC-UNIFY-SCENES-AND-PREFABS.md §\"Unified shape\".\n",
                .{display_path},
            );
            return error.InvalidEntityShape;
        },
    };

    // Reference-mode root: §B2 forbids `children` here just as for
    // child entries. The RFC calls this out explicitly: "The same §B2
    // rule applies here as at child entries: reference-mode root
    // cannot declare `children` — instantiating doesn't author."
    if (obj.get("prefab")) |_| {
        if (obj.get("children")) |_| {
            std.debug.print(
                "labelle-assembler: scene '{s}' has a 'root' that declares both 'prefab' and 'children'.\n" ++
                    "  RFC #560 §B2: reference-mode entries cannot carry children — instantiating doesn't author.\n" ++
                    "  Either author a new prefab file that combines them, or drop one of the keys.\n",
                .{display_path},
            );
            return error.InvalidEntityShape;
        }
    }

    if (obj.get("children")) |children_val| {
        try validateChildrenArray(children_val, display_path);
    }
}

/// Validate a `children` (or legacy `entities`) array. Every entry
/// must be a JSON object, and §B2 forbids the simultaneous presence
/// of `prefab` and `children`. Recurses into nested `children`.
fn validateChildrenArray(value: std.json.Value, display_path: []const u8) ParseError!void {
    const arr = switch (value) {
        .array => |a| a,
        else => return, // Non-array `entities`/`children` is not this pass's concern.
    };
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const has_prefab = obj.get("prefab") != null;
        const has_children = obj.get("children") != null;
        if (has_prefab and has_children) {
            std.debug.print(
                "labelle-assembler: scene '{s}' has a child entry that declares both 'prefab' and 'children'.\n" ++
                    "  RFC #560 §B2: a reference-mode child cannot carry children — instantiating doesn't author.\n" ++
                    "  Author a wrapper prefab that combines them, or drop one of the keys.\n",
                .{display_path},
            );
            return error.InvalidEntityShape;
        }
        if (has_children) {
            try validateChildrenArray(obj.get("children").?, display_path);
        }
    }
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
                    "  Allowed keys: name, assets, include, entities, root, scripts, initial_state\n" ++
                    "  (Did-you-mean suggestions land in labelle-assembler#47.)\n",
                .{ entry.key_ptr.*, display_path },
            );
            return error.UnknownSceneKey;
        }
    }

    // RFC #560 §B2 — walk the scene's entity tree and reject any reference
    // entry (`prefab` set) that also declares `children`. Inline mode is
    // authoring; reference mode is instantiating. Appending children at a
    // reference site silently re-authors a recipe at the call site — the
    // engine's unified loader (labelle-engine#573) rejects this at load
    // time, and the assembler does the same so the failure surfaces against
    // the assembler's scene-path-aware error message rather than a deeper
    // engine panic. Walks both the unified `root.children` shape and the
    // legacy top-level `entities` array; the engine accepts both for the
    // migration window.
    if (root.get("root")) |root_val| {
        try validateRootBlock(root_val, display_path);
    }
    if (root.get("entities")) |entities_val| {
        try validateChildrenArray(entities_val, display_path);
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

    // Read initial_state — optional, default null. Must be a plain
    // string ("playing", "menu", etc.). Invalid types are a hard build
    // error so a typo like a numeric or array value can't silently fall
    // back to "no initial state declared".
    var initial_state: ?[]const u8 = null;
    if (root.get("initial_state")) |state_val| {
        switch (state_val) {
            .string => |s| {
                if (s.len == 0) {
                    // Use std.debug.print, not std.log.err — the negative-
                    // path tests in this file rely on these prints not
                    // counting as logged errors (which would fail the
                    // expectError tests). Same pattern as the assets
                    // validation errors above.
                    std.debug.print(
                        "labelle-assembler: scene '{s}' has empty 'initial_state' string\n",
                        .{display_path},
                    );
                    return error.InvalidInitialStateField;
                }
                initial_state = try allocator.dupe(u8, s);
            },
            else => {
                std.debug.print(
                    "labelle-assembler: scene '{s}' has 'initial_state' but it is not a string\n",
                    .{display_path},
                );
                return error.InvalidInitialStateField;
            },
        }
    }

    return .{
        .name = scene_name,
        .assets = assets,
        .initial_state = initial_state,
    };
}

/// Free the strings + slice owned by a manifest produced by parseSceneSource.
pub fn freeManifest(allocator: std.mem.Allocator, manifest: SceneManifest) void {
    for (manifest.assets) |s| allocator.free(s);
    if (manifest.assets.len > 0) {
        allocator.free(manifest.assets);
    }
    if (manifest.initial_state) |s| allocator.free(s);
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

        const source = std.Io.Dir.cwd().readFileAlloc(config.globalIo(), rel, allocator, .limited(1024 * 1024)) catch |err| {
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

test "parses initial_state string" {
    const src =
        \\{
        \\    "name": "combat_arena",
        \\    "initial_state": "playing",
        \\    "entities": []
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "combat_arena", "combat.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expect(m.initial_state != null);
    try std.testing.expectEqualStrings("playing", m.initial_state.?);
}

test "scene without initial_state yields null (back-compat default)" {
    const src =
        \\{
        \\    "name": "menu",
        \\    "entities": []
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expect(m.initial_state == null);
}

test "non-string initial_state is a hard error" {
    const src =
        \\{
        \\    "initial_state": ["playing"]
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    try std.testing.expectError(error.InvalidInitialStateField, result);
}

test "empty initial_state string is a hard error" {
    const src =
        \\{
        \\    "initial_state": ""
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "menu", "menu.jsonc", src);
    try std.testing.expectError(error.InvalidInitialStateField, result);
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

// ── Unified-format scene tests (RFC #560 / labelle-engine#573) ────────

test "unified-format scene with root.children loads" {
    // The smoke-test shape from labelle-assembler#181: a scene
    // authored in the unified format that previously got rejected
    // with "unknown top-level key 'root'".
    const src =
        \\{
        \\    "name": "main",
        \\    "root": {
        \\        "children": []
        \\    }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "main", "scenes/main.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqualStrings("main", m.name);
}

test "unified-format scene with root reference (Mode B) loads" {
    // Reference-mode root — instantiates an existing prefab as the
    // scene root. Allowed by the unified format; the assembler must
    // not reject it.
    const src =
        \\{
        \\    "name": "level1",
        \\    "root": {
        \\        "prefab": "world",
        \\        "overrides": { "Position": { "x": 0, "y": 0 } }
        \\    }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "level1", "scenes/level1.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "unified-format scene with reference children inside root.children" {
    const src =
        \\{
        \\    "name": "playground",
        \\    "assets": ["background"],
        \\    "root": {
        \\        "children": [
        \\            { "prefab": "player" },
        \\            { "prefab": "enemy", "overrides": { "Health": { "hp": 5 } } },
        \\            { "components": { "Position": { "x": 0, "y": 0 } } }
        \\        ]
        \\    }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "playground", "scenes/playground.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 1), m.assets.len);
}

test "unified scene with initial_state + assets at file level" {
    // File-level metadata (`name`, `assets`, `initial_state`) coexists
    // with the unified `root` block. These keys live at the file level
    // — only the entity tree moves into `root`.
    const src =
        \\{
        \\    "name": "arena",
        \\    "assets": ["combat"],
        \\    "initial_state": "playing",
        \\    "root": {
        \\        "children": [
        \\            { "prefab": "fighter" }
        \\        ]
        \\    }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "arena", "scenes/arena.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqualStrings("combat", m.assets[0]);
    try std.testing.expectEqualStrings("playing", m.initial_state.?);
}

test "§B2 — child entry with both prefab and children is rejected" {
    const src =
        \\{
        \\    "name": "main",
        \\    "root": {
        \\        "children": [
        \\            {
        \\                "prefab": "door",
        \\                "children": [
        \\                    { "prefab": "pressure_plate" }
        \\                ]
        \\            }
        \\        ]
        \\    }
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "main", "scenes/main.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "§B2 — root with both prefab and children is rejected" {
    // The RFC calls this out explicitly: reference-mode root cannot
    // declare children. The assembler enforces the same rule the
    // engine's unified loader does.
    const src =
        \\{
        \\    "name": "broken",
        \\    "root": {
        \\        "prefab": "base",
        \\        "children": [ { "prefab": "extra" } ]
        \\    }
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "broken", "scenes/broken.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "§B2 — nested child violation is detected (deep walk)" {
    // The walker must recurse — a violation buried two levels deep
    // is still a violation.
    const src =
        \\{
        \\    "root": {
        \\        "children": [
        \\            {
        \\                "components": { "Position": { "x": 0, "y": 0 } },
        \\                "children": [
        \\                    {
        \\                        "prefab": "boss",
        \\                        "children": [ { "prefab": "minion" } ]
        \\                    }
        \\                ]
        \\            }
        \\        ]
        \\    }
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "deep", "scenes/deep.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "§B2 — legacy entities array is also walked for violations" {
    // Mixed legacy + unified projects must still have §B2 enforced
    // on the legacy side until the migration completes.
    const src =
        \\{
        \\    "name": "legacy",
        \\    "entities": [
        \\        {
        \\            "prefab": "door",
        \\            "children": [ { "prefab": "plate" } ]
        \\        }
        \\    ]
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "legacy", "scenes/legacy.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "non-object root is a hard error" {
    const src =
        \\{
        \\    "name": "broken",
        \\    "root": []
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "broken", "scenes/broken.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "legacy entities + unified root coexist (half-migrated scene)" {
    // A scene mid-migration may temporarily carry both keys — the
    // engine loader prefers `root.children` and warns about the
    // legacy key (see unified_format.fileChildren). The assembler
    // must accept the shape so it doesn't block the migration.
    const src =
        \\{
        \\    "name": "transition",
        \\    "entities": [],
        \\    "root": { "children": [] }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "transition", "scenes/transition.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
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
