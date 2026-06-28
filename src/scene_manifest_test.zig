/// Extracted tests for `scene_manifest.zig`.
///
/// These tests were split out of `scene_manifest.zig` verbatim to keep
/// that source file under the repo's 1000-line limit. They exercise the
/// scene .jsonc manifest parser end-to-end (object, flat, bundle, and
/// hybrid shapes) plus the pure classifier/validator helpers.
///
/// Discovered via the `test {}` block in `root.zig`, which imports this
/// file so `addTest` (rooted at `src/root.zig`) runs these tests. The
/// helpers some tests reach for (`validateBundle`, `validateRootBlock`,
/// `parseAssetsField`, `isBundleHeader`, `MAX_CHILDREN_DEPTH`) are
/// `pub` in `scene_manifest.zig` solely so this file can reach them.
const std = @import("std");
const scene_manifest = @import("scene_manifest.zig");

// Aliases so the moved test bodies compile unchanged (they refer to
// these symbols unqualified).
const parseSceneSource = scene_manifest.parseSceneSource;
const freeManifest = scene_manifest.freeManifest;
const classifyTopLevel = scene_manifest.classifyTopLevel;
const MAX_CHILDREN_DEPTH = scene_manifest.MAX_CHILDREN_DEPTH;

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

test "bundle parses meta.assets from header" {
    // RFC #596 axis 3: a bundle's first element may be a
    // `{meta: {...}}` header carrying file-level metadata. The
    // assembler reads `meta.assets` so `SceneAssetManifests.<scene>`
    // gets populated at codegen time (counterpart to engine #599's
    // runtime `meta.initial_state` consumer).
    const src =
        \\[
        \\    { "meta": { "assets": ["a", "b"] } },
        \\    { "prefab": "x" }
        \\]
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "scenes/menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 2), m.assets.len);
    try std.testing.expectEqualStrings("a", m.assets[0]);
    try std.testing.expectEqualStrings("b", m.assets[1]);
    try std.testing.expect(m.initial_state == null);
}

test "bundle without meta header returns empty assets" {
    // No `{meta}` header at index 0 — the bundle is entity-only.
    // `manifest.assets` defaults to the empty slice.
    const src =
        \\[
        \\    { "prefab": "x" },
        \\    { "prefab": "y" }
        \\]
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "scenes/menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 0), m.assets.len);
}

test "bundle with meta but no assets returns empty" {
    // Header carries `initial_state` only (consumed at runtime by
    // engine #599, NOT here). Assembler-side assets stays empty.
    const src =
        \\[
        \\    { "meta": { "initial_state": "playing" } },
        \\    { "prefab": "x" }
        \\]
    ;
    const m = try parseSceneSource(std.testing.allocator, "menu", "scenes/menu.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 0), m.assets.len);
    // initial_state stays null on the codegen-side manifest — engine
    // #599 reads the directive at runtime; doubling it would re-fire.
    try std.testing.expect(m.initial_state == null);
}

test "bundle meta.assets non-array rejected" {
    // Same error vocabulary as the object-form `assets:` validator —
    // shared via `parseAssetsField`.
    const src =
        \\[
        \\    { "meta": { "assets": "not-an-array" } }
        \\]
    ;
    const result = parseSceneSource(std.testing.allocator, "menu", "scenes/menu.jsonc", src);
    try std.testing.expectError(error.InvalidAssetsField, result);
}

test "bundle meta.assets non-string entry rejected" {
    const src =
        \\[
        \\    { "meta": { "assets": [1, 2] } }
        \\]
    ;
    const result = parseSceneSource(std.testing.allocator, "menu", "scenes/menu.jsonc", src);
    try std.testing.expectError(error.InvalidAssetsField, result);
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

test "children nested at exactly MAX_CHILDREN_DEPTH levels is accepted" {
    // Build a chain: root.children → children → ... MAX_CHILDREN_DEPTH levels
    // deep with a single leaf entity at the bottom.  The depth counter starts
    // at 0 at the root's children array, so MAX_CHILDREN_DEPTH levels of
    // nesting must all pass.
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"root\":{\"children\":[");
    var i: u32 = 0;
    while (i < MAX_CHILDREN_DEPTH) : (i += 1) {
        try buf.appendSlice(allocator, "{\"children\":[");
    }
    try buf.appendSlice(allocator, "{\"prefab\":\"leaf\"}");
    i = 0;
    while (i < MAX_CHILDREN_DEPTH) : (i += 1) {
        try buf.appendSlice(allocator, "]}");
    }
    try buf.appendSlice(allocator, "]}}");
    const m = try parseSceneSource(allocator, "deep_ok", "deep_ok.jsonc", buf.items);
    freeManifest(allocator, m);
}

test "children nested beyond MAX_CHILDREN_DEPTH is a hard error" {
    // One extra level beyond the cap must trigger error.InvalidEntityShape.
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"root\":{\"children\":[");
    var i: u32 = 0;
    while (i < MAX_CHILDREN_DEPTH + 1) : (i += 1) {
        try buf.appendSlice(allocator, "{\"children\":[");
    }
    try buf.appendSlice(allocator, "{\"prefab\":\"leaf\"}");
    i = 0;
    while (i < MAX_CHILDREN_DEPTH + 1) : (i += 1) {
        try buf.appendSlice(allocator, "]}");
    }
    try buf.appendSlice(allocator, "]}}");
    const result = parseSceneSource(allocator, "deep_bad", "deep_bad.jsonc", buf.items);
    try std.testing.expectError(error.InvalidEntityShape, result);
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

// ── Flat-form unified scene tests (RFC #594 phase 2 / engine #595) ───
//
// These mirror the engine's `flat:` tests in
// `labelle-engine/test/jsonc/unified_format_test.zig`. Each test
// pins one corner of the dual-acceptance contract:
//   1. Flat component-only entity.
//   2. Flat entity with components + children.
//   3. Flat reference (Mode B): `prefab` at the top level.
//   4. File-level metadata (`name`, `assets`) coexisting with flat
//      entity-shape keys.
//   5. §B2 still fires at the flat top level.
//   6. Mixed: root-wrapped form still loads unchanged (regression pin).

test "flat: component-only scene loads (no root wrapper)" {
    const src =
        \\{
        \\    "name": "spawn",
        \\    "components": { "Position": { "x": 0, "y": 0 } }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "spawn", "scenes/spawn.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqualStrings("spawn", m.name);
}

test "flat: scene with components + children loads" {
    const src =
        \\{
        \\    "name": "playground",
        \\    "components": { "Position": { "x": 0, "y": 0 } },
        \\    "children": [
        \\        { "prefab": "player" },
        \\        { "prefab": "enemy" }
        \\    ]
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "playground", "scenes/playground.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "flat: prefab reference at the file's top level (Mode B specialization)" {
    // A prefab file authored in the flat form, used to specialize an
    // existing recipe. The engine accepts this; the assembler must
    // accept it too. Mirrors engine #595's "flat: prefab reference at
    // root (specialization)" test.
    const src =
        \\{
        \\    "name": "fast_enemy",
        \\    "prefab": "enemy",
        \\    "overrides": { "Speed": { "px_per_s": 200 } }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "fast_enemy", "prefabs/fast_enemy.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "flat: scene with file metadata + entity-shape keys coexisting" {
    // Closed-and-disjoint key sets per the RFC: file metadata
    // (`name`, `assets`, `initial_state`) lives alongside entity-shape
    // keys (`components`, `children`) at the same top level.
    const src =
        \\{
        \\    "name": "arena",
        \\    "assets": ["combat"],
        \\    "initial_state": "playing",
        \\    "components": { "Position": { "x": 0, "y": 0 } },
        \\    "children": [
        \\        { "prefab": "fighter" }
        \\    ]
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "arena", "scenes/arena.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqualStrings("combat", m.assets[0]);
    try std.testing.expectEqualStrings("playing", m.initial_state.?);
}

test "flat: §B2 fires on flat reference-mode root with children" {
    // The flat-form analogue of "§B2 — root with both prefab and
    // children is rejected". With no `root:` wrapper, the file's
    // top-level object IS the root entity, so the §B2 rule must
    // still fire. Mirrors engine #595's "flat: §B2 still fires on
    // a flat reference-mode root with children" test.
    const src =
        \\{
        \\    "name": "broken",
        \\    "prefab": "base",
        \\    "children": [ { "prefab": "extra" } ]
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "broken", "scenes/broken.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "flat: §B2 fires on a nested child violation below the flat top level" {
    // The walker must recurse into `children` arrays the same way it
    // does under the root-wrapped shape.
    const src =
        \\{
        \\    "children": [
        \\        {
        \\            "components": { "Position": { "x": 0, "y": 0 } },
        \\            "children": [
        \\                {
        \\                    "prefab": "boss",
        \\                    "children": [ { "prefab": "minion" } ]
        \\                }
        \\            ]
        \\        }
        \\    ]
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "deep_flat", "scenes/deep_flat.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "flat: dual-acceptance regression — root-wrapped form still loads unchanged" {
    // Pin the dual-acceptance contract: same parser, same file,
    // root-wrapped form must continue to load with no behavioral
    // change. This is the regression sentinel for the v2.0 cutover.
    const src =
        \\{
        \\    "name": "wrapped",
        \\    "root": {
        \\        "components": { "Position": { "x": 1, "y": 2 } },
        \\        "children": [ { "prefab": "player" } ]
        \\    }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "wrapped", "scenes/wrapped.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqualStrings("wrapped", m.name);
}

test "flat: metadata-only file (no entity-shape keys) parses (e.g. include-only)" {
    // A file that carries only metadata + `include` (no entity-shape
    // keys) is NOT in flat form — the §B2 walk must be a no-op,
    // exactly as it was before the flat-form change.
    const src =
        \\{
        \\    "name": "shared",
        \\    "include": ["common/base.jsonc"]
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "shared", "scenes/shared.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

// ── Cursor #233 fixes: hybrid-form rejection + §B2 site labels ───────

test "hybrid: file with both 'root' wrapper and flat entity-shape keys is rejected" {
    // Cursor #233 finding 1 — dual-accept must not silently drop one
    // side when a file carries both shapes. The §B2 walker only
    // descends one branch, so a mixed file would lose data for users
    // mid-migration. The classifier rejects the shape outright.
    const src =
        \\{
        \\    "name": "mixed",
        \\    "root": { "components": { "Position": { "x": 0, "y": 0 } } },
        \\    "components": { "Other": {} }
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "mixed", "scenes/mixed.jsonc", src);
    try std.testing.expectError(error.HybridForm, result);
}

test "§B2 site label — flat form classifies as 'top level' (not 'root')" {
    // Cursor #233 finding 2 — when a flat-form file trips §B2, the
    // error message must not point users at a `root:` key that
    // doesn't exist in their file. We can't intercept stderr in
    // tests, so the label-selection rule is exposed via the pure
    // `classifyTopLevel` helper and verified directly. The label
    // returned here is exactly what `validateRootBlock` will
    // interpolate into the §B2 message — see `parseSceneSource` and
    // the `{s}` format slot in the §B2 stderrPrint call.
    //
    // Shape: top-level `prefab` + `children`. parseSceneSource itself
    // will reject this with InvalidEntityShape; we cover the
    // end-to-end rejection in "flat: §B2 fires on flat reference-mode
    // root with children" above.
    const src =
        \\{ "prefab": "x", "children": [] }
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, src, .{});
    defer parsed.deinit();
    const label = try classifyTopLevel(parsed.value.object);
    try std.testing.expect(label != null);
    try std.testing.expectEqualStrings("top level", label.?);
}

test "§B2 site label — root-wrapped form classifies as 'root' (regression pin)" {
    // Cursor #233 finding 2 — regression sentinel for the
    // pre-existing label. Users with root-wrapped files must keep
    // seeing the "root" word in §B2 messages; if a future refactor
    // swaps the label to "top level" for wrapped files, this fails.
    const src =
        \\{ "root": { "prefab": "x", "children": [] } }
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, src, .{});
    defer parsed.deinit();
    const label = try classifyTopLevel(parsed.value.object);
    try std.testing.expect(label != null);
    try std.testing.expectEqualStrings("root", label.?);
}

// ── RFC #596 — wrapper-flat + bundle + meta shapes (engine #597) ─────
//
// These mirror engine #597's `rfc596:` test suite in
// `labelle-engine/test/jsonc/unified_format_test.zig`. Each test pins
// one corner of the new dual-acceptance axes:
//
//   - Axis 2: PascalCase keys as entity-scope components, dropping the
//     `overrides:` / `components:` wrappers.
//   - Axis 3: top-level JSON Array as a bundle of sibling entities,
//     with an optional `{meta}` header at index 0.
//   - Axis 4: free-form `meta:` keys at file-header and entity scope,
//     never validated.
//
// The hybrid-form gate (RFC #596 corollary; cursor #233 style)
// rejects any file that mixes a wrapper with its flat counterpart at
// the same site.

test "rfc596: flat reference — PascalCase override sibling of prefab key" {
    // The dominant FP shape post-RFC-#596: a scene reference with
    // PascalCase component overrides sitting next to `prefab:`, no
    // `overrides:` wrapper. Mirrors engine #597's
    // "rfc596: flat reference — PascalCase override sibling of prefab key".
    const src =
        \\{
        \\    "name": "fast_enemy",
        \\    "prefab": "enemy",
        \\    "Position": { "x": 100, "y": 50 },
        \\    "Speed": { "px_per_s": 200 }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "fast_enemy", "prefabs/fast_enemy.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "rfc596: flat inline — PascalCase keys declare an inline entity" {
    // The dominant FP shape for inline entities post-RFC-#596: a file
    // whose root entity declares its components directly via
    // PascalCase keys, no `components:` wrapper, optional `children:`
    // for true parent-of-children.
    const src =
        \\{
        \\    "name": "kitchen_workstation",
        \\    "Image": { "sprite": "kitchen" },
        \\    "Workstation": { "kind": "kitchen" },
        \\    "children": [
        \\        { "prefab": "eis_slot", "Position": { "x": -30, "y": 0 } }
        \\    ]
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "kitchen", "prefabs/kitchen.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "rfc596: bundle scene — top-level Array spawns N siblings" {
    // The bundle shape collapses the colony scene's outer
    // `{name, children: [...]}` wrapping into a direct Array. Each
    // element is an entity walked through `validateRootBlock` with
    // the site label "bundle entry".
    const src =
        \\[
        \\    { "prefab": "ship_carcase", "Position": { "x": 0,   "y": 0 } },
        \\    { "prefab": "ship_carcase", "Position": { "x": 780, "y": 0 } },
        \\    { "prefab": "condenser",    "Position": { "x": 0,   "y": 0 } }
        \\]
    ;
    const m = try parseSceneSource(std.testing.allocator, "colony", "scenes/colony.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    // Bundles carry no file-level metadata channel — `assets` is
    // empty and `initial_state` is null. Pin that contract here so a
    // future refactor doesn't accidentally surface file metadata that
    // the bundle shape can't actually carry.
    try std.testing.expectEqual(@as(usize, 0), m.assets.len);
    try std.testing.expect(m.initial_state == null);
}

test "rfc596: bundle header — only-meta object at index 0 is file-meta, not entity" {
    // The first bundle element MAY be `{meta: {...}}` only, carrying
    // file-level authoring metadata. It is NOT walked as an entity.
    // If it were, the §B2 walker would still pass (no `prefab` /
    // `children`), but a future stricter check would mis-fire. Pin
    // the file-header detection here directly.
    const src =
        \\[
        \\    { "meta": { "name": "Production Colony Demo", "author": "alexandre" } },
        \\    { "prefab": "ship_carcase", "Position": { "x": 0, "y": 0 } },
        \\    { "prefab": "condenser",    "Position": { "x": 0, "y": 0 } }
        \\]
    ;
    const m = try parseSceneSource(std.testing.allocator, "colony", "scenes/colony.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "rfc596: empty bundle [] is valid, zero entities" {
    // RFC #596 resolved decision 2: `[]` is a valid zero-entity file.
    // Authoring workflows (new file → `[]` → add entities) and the
    // empty-checked-in-by-mistake case both get the same treatment.
    const src = "[]";
    const m = try parseSceneSource(std.testing.allocator, "empty", "scenes/empty.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
    try std.testing.expectEqual(@as(usize, 0), m.assets.len);
}

test "rfc596: meta on an entity is ignored by the scan (no findings)" {
    // `meta:` is structural, lowercase, and never validated. An
    // entity that carries `meta` alongside real components and
    // structural keys still walks normally. Pin that the presence
    // of `meta` doesn't change any other gate's behavior.
    const src =
        \\{
        \\    "name": "labeled_kitchen",
        \\    "prefab": "kitchen",
        \\    "Position": { "x": 156, "y": 93 },
        \\    "meta": { "name": "Main Kitchen", "notes": "first build" }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "labeled_kitchen", "prefabs/labeled_kitchen.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "rfc596: file-header-only `meta:` is accepted (no entity walk)" {
    // A file shaped `{meta: {...}}` alone — no entity-shape keys —
    // carries only authoring metadata at file-header scope. The
    // §B2 walk is skipped (no root entity to walk); the unknown-key
    // gate accepts `meta` from the allow-list. Mirrors the
    // metadata-only #594 contract for the new key.
    const src =
        \\{
        \\    "name": "labels",
        \\    "meta": { "author": "alexandre", "version": 1 }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "labels", "scenes/labels.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "rfc596: wrapped 'overrides' form still works (dual-accept regression)" {
    // The legacy wrapped form must continue to load unchanged through
    // v1.x. Same shape as yesterday's #233 regression pin, kept here
    // so anyone adding a new RFC #596 gate accidentally affecting the
    // wrapped path fails this test directly. Removed at v2.0.
    const src =
        \\{
        \\    "name": "fast_enemy",
        \\    "prefab": "enemy",
        \\    "overrides": { "Position": { "x": 100, "y": 50 } }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "fast_enemy", "prefabs/fast_enemy.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "rfc596: hybrid form — overrides + flat PascalCase at root is HybridForm" {
    // RFC #596 corollary (engine #597's same gate): a file that
    // declares BOTH the legacy `overrides:` wrapper AND flat
    // PascalCase siblings is ambiguous — the walker can only honor
    // one side, silently dropping the other would lose data for
    // users mid-migration. Reject the shape outright.
    const src =
        \\{
        \\    "prefab": "enemy",
        \\    "overrides": { "Position": { "x": 0, "y": 0 } },
        \\    "Speed": { "px_per_s": 200 }
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "mixed", "scenes/mixed.jsonc", src);
    try std.testing.expectError(error.HybridForm, result);
}

test "rfc596: hybrid form — components + flat PascalCase at root is HybridForm" {
    // Same shape as the previous test but for the inline-entity
    // wrapper. `components:` + a PascalCase sibling is ambiguous.
    const src =
        \\{
        \\    "components": { "Workstation": { "kind": "kitchen" } },
        \\    "Image": { "sprite": "kitchen" }
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "mixed", "scenes/mixed.jsonc", src);
    try std.testing.expectError(error.HybridForm, result);
}

test "rfc596: hybrid form — overrides + flat PascalCase on a child entry is HybridForm" {
    // The hybrid-form gate applies at every entity site, not just the
    // root — child entries are also rejected if they mix wrapper +
    // flat. Engine #597 follows the same per-entity rule.
    const src =
        \\{
        \\    "children": [
        \\        {
        \\            "prefab": "enemy",
        \\            "overrides": { "Position": { "x": 0, "y": 0 } },
        \\            "Speed": { "px_per_s": 200 }
        \\        }
        \\    ]
        \\}
    ;
    const result = parseSceneSource(std.testing.allocator, "mixed", "scenes/mixed.jsonc", src);
    try std.testing.expectError(error.HybridForm, result);
}

test "rfc596: §B2 fires on a flat bundle entry with {prefab + children}" {
    // The bundle shape doesn't bypass §B2 — every bundle entry is
    // walked the same way a root entity is, with the site label
    // "bundle entry". A reference-mode entry with `children` is still
    // a §B2 violation. Mirrors engine #597's
    // "rfc596: §B2 still fires on a flat bundle element with {prefab + children}".
    const src =
        \\[
        \\    { "prefab": "ship_carcase", "Position": { "x": 0, "y": 0 } },
        \\    { "prefab": "door", "children": [ { "prefab": "plate" } ] }
        \\]
    ;
    const result = parseSceneSource(std.testing.allocator, "broken_bundle", "scenes/broken_bundle.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "rfc596: §B2 fires on a nested bundle entry — recursion preserved" {
    // The walker still recurses into bundle entries' `children`.
    const src =
        \\[
        \\    {
        \\        "Image": { "sprite": "x" },
        \\        "children": [
        \\            { "prefab": "boss", "children": [ { "prefab": "minion" } ] }
        \\        ]
        \\    }
        \\]
    ;
    const result = parseSceneSource(std.testing.allocator, "nested_bundle", "scenes/nested_bundle.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "rfc596: bundle entry with non-object element is rejected" {
    // A bundle of strings/numbers is malformed.
    const src =
        \\[
        \\    { "prefab": "ship" },
        \\    "not-an-entity"
        \\]
    ;
    const result = parseSceneSource(std.testing.allocator, "bad_bundle", "scenes/bad_bundle.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}

test "rfc596: §B2 site label — bundle entry classifies via validateBundle path" {
    // `classifyTopLevel` only runs for object-shape top-level files;
    // bundles bypass it entirely and go straight through
    // `validateBundle`. Pin that the classifier returns null when
    // handed an object that LOOKS like a bundle entry but at file
    // top level — to catch regressions where the wrong code path is
    // taken for the bundle shape.
    //
    // (The user-visible label "bundle entry" is interpolated into
    // §B2 messages from `validateBundle`'s direct call to
    // `validateRootBlock`; we can't capture stderr in tests, so this
    // pins the structural path instead.)
    const src =
        \\{ "prefab": "x", "Position": { "x": 0, "y": 0 } }
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, src, .{});
    defer parsed.deinit();
    const label = try classifyTopLevel(parsed.value.object);
    try std.testing.expect(label != null);
    try std.testing.expectEqualStrings("top level", label.?);
}

test "rfc596: unknown PascalCase key at top level is accepted (warn deferred to loader)" {
    // The audit's option-C resolution: the assembler scan can't see
    // the engine's component registry, so unknown PascalCase keys
    // (typos like `Posiiton`, or cross-repo plugin types) are
    // accepted at scan time and the loader's runtime warn-once path
    // catches them. Pin that behavior here so a future change that
    // tries to introspect the registry from the assembler — and
    // accidentally rejects valid unknown-PascalCase-at-scan-time —
    // fails this test directly.
    const src =
        \\{
        \\    "prefab": "enemy",
        \\    "Posiiton": { "x": 0, "y": 0 }
        \\}
    ;
    const m = try parseSceneSource(std.testing.allocator, "typo", "scenes/typo.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "rfc596: bundle with `{meta}` at non-zero index is walked as an entity" {
    // File-header status is positional — only index 0 may be a pure
    // `{meta}` header. A `{meta}`-only object anywhere else is an
    // entity, and an entity with no `prefab` / no components / no
    // `children` is... not what the loader wants. The scan doesn't
    // currently distinguish "empty entity" from "well-formed entity"
    // (that's the loader's job — see RFC #596 "Empty bundles" final
    // paragraph), so the scan accepts the shape. Pin that contract.
    const src =
        \\[
        \\    { "prefab": "ship_carcase", "Position": { "x": 0, "y": 0 } },
        \\    { "meta": { "note": "this is not a header — it's at index 1" } }
        \\]
    ;
    const m = try parseSceneSource(std.testing.allocator, "labeled", "scenes/labeled.jsonc", src);
    defer freeManifest(std.testing.allocator, m);
}

test "rfc596: top-level non-object non-array is still a hard error" {
    // The error message for a malformed top-level was updated to
    // mention the bundle shape; pin that an actually malformed file
    // (e.g. a top-level string) still rejects.
    const src = "\"just a string\"";
    const result = parseSceneSource(std.testing.allocator, "bad", "scenes/bad.jsonc", src);
    try std.testing.expectError(error.InvalidSceneJson, result);
}

test "rfc596: file-header `{meta}` with extra keys is treated as an entity (positional)" {
    // `isBundleHeader` requires the object to have EXACTLY one key
    // and that key to be `meta`. A `{meta, prefab}` first element is
    // a real entity (with `meta` sitting alongside) and must be
    // walked as such — including any §B2 violation it carries.
    const src =
        \\[
        \\    { "meta": { "x": 1 }, "prefab": "enemy", "children": [ { "prefab": "minion" } ] }
        \\]
    ;
    const result = parseSceneSource(std.testing.allocator, "bad_header", "scenes/bad_header.jsonc", src);
    try std.testing.expectError(error.InvalidEntityShape, result);
}
