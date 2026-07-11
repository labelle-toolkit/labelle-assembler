//! Tests for `tilemap_scan.zig` (T2 Phase 4, tilemap epic).
//!
//! Cover the pure helpers (image-source extraction, path convention) plus
//! the filesystem-backed `collect` end-to-end against a hermetic tmpDir.
//! Discovered via the `test {}` block in `root.zig`.

const std = @import("std");
const tilemap_scan = @import("tilemap_scan.zig");
const scene_manifest = @import("scene_manifest.zig");
const tilemap_assets = @import("codegen/blocks/tilemap_assets.zig");

const testing = std.testing;

// The minimal Tiled map the engine's own tilemap_test.zig uses: one inline
// tileset referencing `tiles.png`, a 3×2 CSV tile layer.
const minimal_tmx =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<map version="1.10" orientation="orthogonal" width="3" height="2" tilewidth="16" tileheight="16">
    \\ <tileset firstgid="1" name="test_tiles" tilewidth="16" tileheight="16" columns="4" tilecount="8">
    \\  <image source="tiles.png" width="64" height="32"/>
    \\ </tileset>
    \\ <layer id="1" name="ground" width="3" height="2">
    \\  <data encoding="csv">1,2,3,4,5,6</data>
    \\ </layer>
    \\</map>
;

// A stand-in tileset image (bytes are irrelevant to the scan — only the
// path resolution + embedding matters).
const fake_png = "\x89PNG\r\n\x1a\n fake tileset pixels";

test "extractImageSources pulls the single inline tileset image" {
    const imgs = try tilemap_scan.extractImageSources(testing.allocator, minimal_tmx);
    defer {
        for (imgs) |s| testing.allocator.free(s);
        testing.allocator.free(imgs);
    }
    try testing.expectEqual(@as(usize, 1), imgs.len);
    try testing.expectEqualStrings("tiles.png", imgs[0]);
}

test "extractImageSources pulls every tileset image in document order" {
    const tmx =
        \\<map>
        \\ <tileset firstgid="1"><image source="a.png" width="16" height="16"/></tileset>
        \\ <tileset firstgid="9"><image source="sub/b.png" width="16" height="16"/></tileset>
        \\</map>
    ;
    const imgs = try tilemap_scan.extractImageSources(testing.allocator, tmx);
    defer {
        for (imgs) |s| testing.allocator.free(s);
        testing.allocator.free(imgs);
    }
    try testing.expectEqual(@as(usize, 2), imgs.len);
    try testing.expectEqualStrings("a.png", imgs[0]);
    try testing.expectEqualStrings("sub/b.png", imgs[1]);
}

test "extractImageSources ignores an external <tileset source> (no inline image)" {
    const tmx =
        \\<map>
        \\ <tileset firstgid="1" source="ext.tsx"/>
        \\</map>
    ;
    const imgs = try tilemap_scan.extractImageSources(testing.allocator, tmx);
    defer {
        for (imgs) |s| testing.allocator.free(s);
        testing.allocator.free(imgs);
    }
    try testing.expectEqual(@as(usize, 0), imgs.len);
}

test "extractImageSources accepts spaces around `=` and single quotes" {
    // Both are legal XML/TMX attribute syntax and must still be found.
    const tmx =
        \\<map>
        \\ <tileset firstgid="1"><image source = "spaced.png" width="16"/></tileset>
        \\ <tileset firstgid="9"><image source='single.png' width="16"/></tileset>
        \\</map>
    ;
    const imgs = try tilemap_scan.extractImageSources(testing.allocator, tmx);
    defer {
        for (imgs) |s| testing.allocator.free(s);
        testing.allocator.free(imgs);
    }
    try testing.expectEqual(@as(usize, 2), imgs.len);
    try testing.expectEqualStrings("spaced.png", imgs[0]);
    try testing.expectEqualStrings("single.png", imgs[1]);
}

test "extractImageSources ignores a commented-out <image>, keeps a real one" {
    // A stale `<image>` kept in an XML comment must NOT yield a registration
    // (the generated @embedFile would reference an asset the map never uses,
    // breaking the build). The real one alongside it still registers.
    const tmx =
        \\<map>
        \\ <!-- old tileset: <image source="old.png" width="16"/> -->
        \\ <tileset firstgid="1"><image source="real.png" width="16"/></tileset>
        \\</map>
    ;
    const imgs = try tilemap_scan.extractImageSources(testing.allocator, tmx);
    defer {
        for (imgs) |s| testing.allocator.free(s);
        testing.allocator.free(imgs);
    }
    try testing.expectEqual(@as(usize, 1), imgs.len);
    try testing.expectEqualStrings("real.png", imgs[0]);
}

test "firstExternalTileset finds an external .tsx tileset, null for inline" {
    const external =
        \\<map>
        \\ <tileset firstgid="1" source="terrain.tsx"/>
        \\</map>
    ;
    try testing.expect(tilemap_scan.firstExternalTileset(external) != null);
    try testing.expectEqualStrings("terrain.tsx", tilemap_scan.firstExternalTileset(external).?);
    // Inline tileset: the `source` lives on <image>, not <tileset>.
    try testing.expect(tilemap_scan.firstExternalTileset(minimal_tmx) == null);
    // A commented-out external tileset must NOT be treated as external.
    const commented =
        \\<map>
        \\ <!-- <tileset firstgid="1" source="terrain.tsx"/> -->
        \\ <tileset firstgid="1"><image source="real.png" width="16"/></tileset>
        \\</map>
    ;
    try testing.expect(tilemap_scan.firstExternalTileset(commented) == null);
}

test "extractImageSources keeps the source RAW (no XML-entity decode)" {
    // gfx v1.21.0 stores image_source verbatim (no &amp;→& decode), so the
    // engine's ImageProvider looks up the RAW string — the registry key must
    // match byte-for-byte. Decoding here would silently miss (see #564).
    const tmx =
        \\<map>
        \\ <tileset firstgid="1"><image source="tiles&amp;decor.png" width="16" height="16"/></tileset>
        \\</map>
    ;
    const imgs = try tilemap_scan.extractImageSources(testing.allocator, tmx);
    defer {
        for (imgs) |s| testing.allocator.free(s);
        testing.allocator.free(imgs);
    }
    try testing.expectEqual(@as(usize, 1), imgs.len);
    try testing.expectEqualStrings("tiles&amp;decor.png", imgs[0]);
}

test "extractImageSources ignores an <imagelayer> image, keeps the tileset image" {
    // Only TILESET images are fetched by the engine's ImageProvider; an
    // image-layer background must NOT be embedded (it would require an absent
    // file / collide, though the runtime never requests it).
    const tmx =
        \\<map>
        \\ <imagelayer name="bg"><image source="draft_bg.png" width="64" height="32"/></imagelayer>
        \\ <tileset firstgid="1"><image source="tiles.png" width="64" height="32"/></tileset>
        \\</map>
    ;
    const imgs = try tilemap_scan.extractImageSources(testing.allocator, tmx);
    defer {
        for (imgs) |s| testing.allocator.free(s);
        testing.allocator.free(imgs);
    }
    try testing.expectEqual(@as(usize, 1), imgs.len);
    try testing.expectEqualStrings("tiles.png", imgs[0]);
}

test "tmxEmbedPath appends .tmx for a bare asset name" {
    const p = try tilemap_scan.tmxEmbedPath(testing.allocator, "colony_map");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("assets/colony_map.tmx", p);
}

test "tmxEmbedPath keeps an explicit .tmx suffix" {
    const p = try tilemap_scan.tmxEmbedPath(testing.allocator, "colony_map.tmx");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("assets/colony_map.tmx", p);
}

test "imageEmbedPath resolves relative to the .tmx directory" {
    const p = try tilemap_scan.imageEmbedPath(testing.allocator, "assets/colony_map.tmx", "tiles.png");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("assets/tiles.png", p);
}

test "imageEmbedPath normalises a parent-relative image source" {
    const p = try tilemap_scan.imageEmbedPath(testing.allocator, "assets/maps/level.tmx", "../textures/tiles.png");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("assets/textures/tiles.png", p);
}

test "imageEmbedPath normalises Windows backslash separators to `/`" {
    // A Tiled-on-Windows source; the copied asset lives at assets/tiles/x.png.
    const p = try tilemap_scan.imageEmbedPath(testing.allocator, "assets/colony_map.tmx", "tiles\\terrain.png");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("assets/tiles/terrain.png", p);
}

fn writeFileAbs(dir: std.Io.Dir, rel: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(rel)) |parent| try dir.createDirPath(std.testing.io, parent);
    const f = try dir.createFile(std.testing.io, rel, .{});
    defer f.close(std.testing.io);
    try f.writeStreamingAll(std.testing.io, content);
}

test "collect embeds the .tmx and its tileset image, keyed for the engine" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFileAbs(tmp.dir, "assets/level.tmx", minimal_tmx);
    try writeFileAbs(tmp.dir, "assets/tiles.png", fake_png);

    const target_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(target_dir);

    // Scene declares the map by a BARE asset_name ("level"); the registry
    // key stays that verbatim name, the file resolves to assets/level.tmx.
    const regs = try tilemap_scan.collect(testing.allocator, target_dir, &.{"level"});
    defer tilemap_scan.freeRegistrations(testing.allocator, regs);

    try testing.expectEqual(@as(usize, 2), regs.len);
    // .tmx registration.
    try testing.expectEqualStrings("level", regs[0].key);
    try testing.expectEqualStrings("assets/level.tmx", regs[0].embed_path);
    // tileset image — key is the VERBATIM `<image source>` (load-bearing:
    // the engine's ImageProvider.get is called with exactly this string).
    try testing.expectEqualStrings("tiles.png", regs[1].key);
    try testing.expectEqualStrings("assets/tiles.png", regs[1].embed_path);
}

test "collect: backslash source → RAW key, `/`-normalized embed path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A Windows-authored source. gfx keeps `image_source` raw, so the engine
    // looks up the backslash key — the registration KEY must stay raw; only
    // the @embedFile PATH is normalized to the copied asset location.
    const tmx =
        \\<map>
        \\ <tileset firstgid="1"><image source="tiles\terrain.png" width="16" height="16"/></tileset>
        \\</map>
    ;
    try writeFileAbs(tmp.dir, "assets/level.tmx", tmx);

    const target_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(target_dir);

    const regs = try tilemap_scan.collect(testing.allocator, target_dir, &.{"level"});
    defer tilemap_scan.freeRegistrations(testing.allocator, regs);

    try testing.expectEqual(@as(usize, 2), regs.len);
    // KEY: raw backslash (matches gfx's ImageProvider lookup).
    try testing.expectEqualStrings("tiles\\terrain.png", regs[1].key);
    // PATH: `/`-normalized to the copied asset.
    try testing.expectEqualStrings("assets/tiles/terrain.png", regs[1].embed_path);
}

test "collect dedups a shared tileset image across two maps" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFileAbs(tmp.dir, "assets/a.tmx", minimal_tmx);
    try writeFileAbs(tmp.dir, "assets/b.tmx", minimal_tmx); // same <image source="tiles.png">
    try writeFileAbs(tmp.dir, "assets/tiles.png", fake_png);

    const target_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(target_dir);

    // Pass "a" twice to also exercise asset_name dedup.
    const regs = try tilemap_scan.collect(testing.allocator, target_dir, &.{ "a", "a", "b" });
    defer tilemap_scan.freeRegistrations(testing.allocator, regs);

    // a.tmx, b.tmx, tiles.png — the image registers ONCE despite two maps.
    try testing.expectEqual(@as(usize, 3), regs.len);
    var image_count: usize = 0;
    for (regs) |r| {
        if (std.mem.eql(u8, r.key, "tiles.png")) image_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), image_count);
}

test "collect errors clearly when the .tmx is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "assets");

    const target_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(target_dir);

    try testing.expectError(
        error.TilemapAssetNotFound,
        tilemap_scan.collect(testing.allocator, target_dir, &.{"ghost"}),
    );
}

test "collect hard-errors when a .tmx asset_name collides with a tileset image key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // level.tmx references a tileset image literally named "shared"; a second
    // scene declares a Tilemap whose asset_name is ALSO "shared" — both would
    // land under the same engine registry key.
    const level_tmx =
        \\<map>
        \\ <tileset firstgid="1"><image source="shared" width="16" height="16"/></tileset>
        \\</map>
    ;
    try writeFileAbs(tmp.dir, "assets/level.tmx", level_tmx);

    const target_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(target_dir);

    // "level" registers image key "shared"; "shared" (a .tmx asset_name) then
    // collides — detected before its file is even read.
    try testing.expectError(
        error.TilemapKeyCollision,
        tilemap_scan.collect(testing.allocator, target_dir, &.{ "level", "shared" }),
    );
}

test "collect hard-errors when one image key resolves to two different files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Two maps in different dirs BOTH reference `source="tiles.png"` — same
    // runtime key, different files (assets/maps/tiles.png vs assets/other/…).
    const tmx =
        \\<map>
        \\ <tileset firstgid="1"><image source="tiles.png" width="16" height="16"/></tileset>
        \\</map>
    ;
    try writeFileAbs(tmp.dir, "assets/maps/a.tmx", tmx);
    try writeFileAbs(tmp.dir, "assets/other/b.tmx", tmx);

    const target_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(target_dir);

    try testing.expectError(
        error.TilemapKeyCollision,
        tilemap_scan.collect(testing.allocator, target_dir, &.{ "maps/a", "other/b" }),
    );
}

test "collect: same image key + SAME path across two maps is a benign dedup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Both maps sit in the same dir → `tiles.png` resolves to one file.
    try writeFileAbs(tmp.dir, "assets/a.tmx", minimal_tmx);
    try writeFileAbs(tmp.dir, "assets/b.tmx", minimal_tmx);

    const target_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(target_dir);

    const regs = try tilemap_scan.collect(testing.allocator, target_dir, &.{ "a", "b" });
    defer tilemap_scan.freeRegistrations(testing.allocator, regs);
    // a.tmx, b.tmx, tiles.png (once).
    try testing.expectEqual(@as(usize, 3), regs.len);
}

test "collect hard-errors on an external .tsx tileset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const external_tmx =
        \\<map>
        \\ <tileset firstgid="1" source="terrain.tsx"/>
        \\</map>
    ;
    try writeFileAbs(tmp.dir, "assets/level.tmx", external_tmx);

    const target_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(target_dir);

    try testing.expectError(
        error.ExternalTilesetUnsupported,
        tilemap_scan.collect(testing.allocator, target_dir, &.{"level"}),
    );
}

// ── emitTilemapRegistrations spellings (the generated init() call shapes) ──

const sample_regs = [_]tilemap_scan.Registration{
    .{ .key = "colony_map", .embed_path = "assets/colony_map.tmx" },
    .{ .key = "tiles.png", .embed_path = "assets/tiles.png" },
};

fn emitToString(regs: []const tilemap_scan.Registration, style: tilemap_assets.LoadStyle) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try tilemap_assets.emitTilemapRegistrations(&aw.writer, regs, style);
    var list = aw.toArrayList();
    return list.toOwnedSlice(testing.allocator);
}

test "emitTilemapRegistrations: try_style spells `try g.addEmbeddedTilemapAsset`" {
    const out = try emitToString(&sample_regs, .try_style);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "try g.addEmbeddedTilemapAsset(\"colony_map\", @embedFile(\"assets/colony_map.tmx\"));") != null);
    try testing.expect(std.mem.indexOf(u8, out, "try g.addEmbeddedTilemapAsset(\"tiles.png\", @embedFile(\"assets/tiles.png\"));") != null);
}

test "emitTilemapRegistrations: catch_panic_style spells the callback-host shape" {
    const out = try emitToString(&sample_regs, .catch_panic_style);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "g.addEmbeddedTilemapAsset(\"colony_map\", @embedFile(\"assets/colony_map.tmx\")) catch @panic(") != null);
    try testing.expect(std.mem.indexOf(u8, out, "g.addEmbeddedTilemapAsset(\"tiles.png\", @embedFile(\"assets/tiles.png\")) catch @panic(") != null);
}

test "emitTilemapRegistrations: empty regs emit nothing" {
    const out = try emitToString(&.{}, .try_style);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "emitTilemapRegistrations: escapes backslashes + quotes into valid Zig" {
    // A Windows-authored `<image source>` with a backslash and a double
    // quote must produce a valid, correctly-keyed Zig literal — raw `{s}`
    // would emit broken source (or reinterpret `\t` as a tab).
    const regs = [_]tilemap_scan.Registration{
        .{ .key = "ti\"le\\s.png", .embed_path = "assets\\ti\"le\\s.png" },
    };
    const out = try emitToString(&regs, .try_style);
    defer testing.allocator.free(out);

    // The literal carries the ESCAPED forms (\\ and \") — not the raw bytes.
    try testing.expect(std.mem.indexOf(u8, out, "ti\\\"le\\\\s.png") != null);
    // And the whole emitted snippet is valid Zig.
    const wrapped = try std.fmt.allocPrintSentinel(testing.allocator, "pub fn f(g: anytype) !void {{\n{s}}}\n", .{out}, 0);
    defer testing.allocator.free(wrapped);
    var ast = try std.zig.Ast.parse(testing.allocator, wrapped, .zig);
    defer ast.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ast.errors.len);
}

// ── scene_manifest Tilemap extraction (the upstream that feeds collect) ──

test "scene_manifest: flat-form Tilemap asset_name is collected" {
    const src =
        \\{
        \\    "Tilemap": { "asset_name": "colony_map" }
        \\}
    ;
    const m = try scene_manifest.parseSceneSource(testing.allocator, "world", "world.jsonc", src);
    defer scene_manifest.freeManifest(testing.allocator, m);
    try testing.expectEqual(@as(usize, 1), m.tilemap_assets.len);
    try testing.expectEqualStrings("colony_map", m.tilemap_assets[0]);
}

test "scene_manifest: Tilemap under a components wrapper in a child is collected" {
    const src =
        \\{
        \\    "children": [
        \\        { "components": { "Tilemap": { "asset_name": "level1" } } }
        \\    ]
        \\}
    ;
    const m = try scene_manifest.parseSceneSource(testing.allocator, "world", "world.jsonc", src);
    defer scene_manifest.freeManifest(testing.allocator, m);
    try testing.expectEqual(@as(usize, 1), m.tilemap_assets.len);
    try testing.expectEqualStrings("level1", m.tilemap_assets[0]);
}

test "scene_manifest: Tilemap with empty/missing asset_name contributes nothing" {
    const src =
        \\{
        \\    "children": [
        \\        { "Tilemap": { "asset_name": "" } },
        \\        { "Tilemap": {} }
        \\    ]
        \\}
    ;
    const m = try scene_manifest.parseSceneSource(testing.allocator, "world", "world.jsonc", src);
    defer scene_manifest.freeManifest(testing.allocator, m);
    try testing.expectEqual(@as(usize, 0), m.tilemap_assets.len);
}

test "scene_manifest: scene without a Tilemap yields empty tilemap_assets" {
    const src =
        \\{
        \\    "entities": [ { "Position": { "x": 1, "y": 2 } } ]
        \\}
    ;
    const m = try scene_manifest.parseSceneSource(testing.allocator, "world", "world.jsonc", src);
    defer scene_manifest.freeManifest(testing.allocator, m);
    try testing.expectEqual(@as(usize, 0), m.tilemap_assets.len);
}

test "scene_manifest: a `Tilemap` key nested in ANOTHER component's data is NOT collected" {
    // `Spawner` is the component; its opaque data happens to contain a
    // `Tilemap` key. This must NOT be treated as a tilemap component (the
    // over-match bug) — otherwise the assembler would try to embed
    // assets/should_not_embed.tmx for an unrelated scene.
    const src =
        \\{
        \\    "components": {
        \\        "Spawner": { "Tilemap": { "asset_name": "should_not_embed" } }
        \\    }
        \\}
    ;
    const m = try scene_manifest.parseSceneSource(testing.allocator, "world", "world.jsonc", src);
    defer scene_manifest.freeManifest(testing.allocator, m);
    try testing.expectEqual(@as(usize, 0), m.tilemap_assets.len);
}

test "scene_manifest: a `Tilemap` key inside a flat-form component's data is NOT collected" {
    const src =
        \\{
        \\    "Spawner": { "Tilemap": { "asset_name": "should_not_embed" } }
        \\}
    ;
    const m = try scene_manifest.parseSceneSource(testing.allocator, "world", "world.jsonc", src);
    defer scene_manifest.freeManifest(testing.allocator, m);
    try testing.expectEqual(@as(usize, 0), m.tilemap_assets.len);
}

test "scene_manifest.scanTilemapAssets detects a prefab-borne Tilemap" {
    // Backs root/tilemap_phase.appendPrefabAssets: prefabs use raw JSONC
    // (no scene unknown-key validation), and a Tilemap in one must be
    // detected so its `.tmx`/images are embedded (assembler#561).
    const src =
        \\{
        \\    "components": { "Tilemap": { "asset_name": "room_map" } }
        \\}
    ;
    const assets = try scene_manifest.scanTilemapAssets(testing.allocator, src);
    defer scene_manifest.freeTilemapAssets(testing.allocator, assets);
    try testing.expectEqual(@as(usize, 1), assets.len);
    try testing.expectEqualStrings("room_map", assets[0]);
}

// ── collectRegistrations: prefab + pack + registered-Tilemap (T3 #561/#562) ──
//
// End-to-end against a hermetic tmpDir. These exercise `tilemap_phase`'s
// aggregation policy directly (scenes + game-root prefabs + pack prefabs, and
// the project/pack-registered-`Tilemap` override), not just the pure scanner.

const tilemap_phase = @import("root/tilemap_phase.zig");
const scan = @import("codegen/scan.zig");

// Find a registration by its engine registry key, or null.
fn findReg(regs: []const tilemap_scan.Registration, key: []const u8) ?tilemap_scan.Registration {
    for (regs) |r| {
        if (std.mem.eql(u8, r.key, key)) return r;
    }
    return null;
}

test "collectRegistrations embeds a GAME-ROOT prefab's Tilemap (.tmx + image)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFileAbs(tmp.dir, "assets/room_map.tmx", minimal_tmx);
    try writeFileAbs(tmp.dir, "assets/tiles.png", fake_png);
    try writeFileAbs(tmp.dir, "prefabs/room.jsonc",
        \\{ "components": { "Tilemap": { "asset_name": "room_map" } } }
    );

    const target_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(target_dir);

    const regs = try tilemap_phase.collectRegistrations(
        testing.allocator,
        target_dir,
        &.{}, // no scenes
        &.{}, // no project components
        &.{}, // no script-declared components
        &.{"room"}, // game-root prefab stems
        &.{}, // no packs
    );
    defer tilemap_scan.freeRegistrations(testing.allocator, regs);

    try testing.expectEqual(@as(usize, 2), regs.len);
    try testing.expect(findReg(regs, "room_map") != null);
    const img = findReg(regs, "tiles.png") orelse return error.MissingImageReg;
    try testing.expectEqualStrings("assets/tiles.png", img.embed_path);
}

test "collectRegistrations embeds a PACK prefab's Tilemap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFileAbs(tmp.dir, "assets/pack_map.tmx", minimal_tmx);
    try writeFileAbs(tmp.dir, "assets/tiles.png", fake_png);
    // Pack prefab lives under the pack's staged import-prefix tree.
    try writeFileAbs(tmp.dir, "packs/mappack/prefabs/room.jsonc",
        \\{ "components": { "Tilemap": { "asset_name": "pack_map" } } }
    );

    const target_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(target_dir);

    const pack: scan.PackScan = .{
        .name = "mappack",
        .import_prefix = "packs/mappack",
        .component_names = &.{},
        .event_names = &.{},
        .prefab_names = &.{"room"},
    };

    const regs = try tilemap_phase.collectRegistrations(
        testing.allocator,
        target_dir,
        &.{},
        &.{},
        &.{}, // no script-declared components
        &.{}, // no game-root prefabs
        &.{pack},
    );
    defer tilemap_scan.freeRegistrations(testing.allocator, regs);

    try testing.expectEqual(@as(usize, 2), regs.len);
    try testing.expect(findReg(regs, "pack_map") != null);
    try testing.expect(findReg(regs, "tiles.png") != null);
}

test "collectRegistrations: a PROJECT `Tilemap` component skips the built-in embed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A scene references a `Tilemap` by asset_name, BUT the PROJECT ships its
    // own `components/Tilemap.zig` (exact built-in name) — so it overrides the
    // built-in (engine C2 / #562) and NOTHING is embedded. No `.tmx` exists,
    // proving no embed was attempted (else the missing-asset read would error).
    const scene: scene_manifest.SceneManifest = .{
        .name = "world",
        .assets = &.{},
        .tilemap_assets = &.{"never_embedded"},
    };
    const project_components = [_][]const u8{"Tilemap"};

    const target_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(target_dir);

    const regs = try tilemap_phase.collectRegistrations(
        testing.allocator,
        target_dir,
        &.{scene},
        &project_components, // project registers `Tilemap`
        &.{}, // no script-declared components
        &.{},
        &.{},
    );
    defer tilemap_scan.freeRegistrations(testing.allocator, regs);

    try testing.expectEqual(@as(usize, 0), regs.len);
}

test "collectRegistrations: a SCRIPT-DECLARED `Tilemap` component skips the built-in embed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Mirror of the PROJECT-component override above (#585): the declare
    // phase registers a script-declared `Tilemap` under the EXACT built-in
    // name (un-namespaced, same root registry), so it satisfies the engine's
    // `has("Tilemap")` gate the same way `components/Tilemap.zig` does —
    // NOTHING is embedded. No `.tmx` exists, proving no embed was attempted.
    const scene: scene_manifest.SceneManifest = .{
        .name = "world",
        .assets = &.{},
        .tilemap_assets = &.{"never_embedded"},
    };
    const declared_components = [_][]const u8{"Tilemap"};

    const target_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(target_dir);

    const regs = try tilemap_phase.collectRegistrations(
        testing.allocator,
        target_dir,
        &.{scene},
        &.{}, // no PROJECT components
        &declared_components, // script declares `Tilemap`
        &.{},
        &.{},
    );
    defer tilemap_scan.freeRegistrations(testing.allocator, regs);

    try testing.expectEqual(@as(usize, 0), regs.len);
}

test "collectRegistrations: a pack's namespaced `Tilemap` does NOT suppress the built-in" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // P1 regression (assembler#562): a project legitimately uses the built-in
    // `Tilemap` in a scene AND imports a pack that happens to ship its own
    // `components/Tilemap.zig`. The pack's component is namespaced
    // (`<pack>__Tilemap`) and does NOT satisfy the engine's `has("Tilemap")`
    // gate, so the built-in `.tmx` + tileset images MUST still be embedded.
    try writeFileAbs(tmp.dir, "assets/scene_map.tmx", minimal_tmx);
    try writeFileAbs(tmp.dir, "assets/tiles.png", fake_png);

    const scene: scene_manifest.SceneManifest = .{
        .name = "world",
        .assets = &.{},
        .tilemap_assets = &.{"scene_map"},
    };
    const pack_components = [_][]const u8{"Tilemap"};
    const pack: scan.PackScan = .{
        .name = "custom",
        .import_prefix = "packs/custom",
        .component_names = &pack_components,
        .event_names = &.{},
        .prefab_names = &.{},
    };

    const target_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(target_dir);

    const regs = try tilemap_phase.collectRegistrations(
        testing.allocator,
        target_dir,
        &.{scene},
        &.{}, // no PROJECT components
        &.{}, // no script-declared components
        &.{},
        &.{pack}, // pack ships a (namespaced) Tilemap — must not suppress
    );
    defer tilemap_scan.freeRegistrations(testing.allocator, regs);

    try testing.expectEqual(@as(usize, 2), regs.len);
    try testing.expect(findReg(regs, "scene_map") != null);
    try testing.expect(findReg(regs, "tiles.png") != null);
}

test "collectRegistrations embeds BOTH a scene and a prefab tilemap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFileAbs(tmp.dir, "assets/scene_map.tmx", minimal_tmx);
    try writeFileAbs(tmp.dir, "assets/prefab_map.tmx", minimal_tmx);
    try writeFileAbs(tmp.dir, "assets/tiles.png", fake_png);
    try writeFileAbs(tmp.dir, "prefabs/room.jsonc",
        \\{ "components": { "Tilemap": { "asset_name": "prefab_map" } } }
    );

    const scene: scene_manifest.SceneManifest = .{
        .name = "world",
        .assets = &.{},
        .tilemap_assets = &.{"scene_map"},
    };

    const target_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(target_dir);

    const regs = try tilemap_phase.collectRegistrations(
        testing.allocator,
        target_dir,
        &.{scene},
        &.{},
        &.{}, // no script-declared components
        &.{"room"},
        &.{},
    );
    defer tilemap_scan.freeRegistrations(testing.allocator, regs);

    // scene_map.tmx + prefab_map.tmx + one shared tiles.png (deduped).
    try testing.expectEqual(@as(usize, 3), regs.len);
    try testing.expect(findReg(regs, "scene_map") != null);
    try testing.expect(findReg(regs, "prefab_map") != null);
    try testing.expect(findReg(regs, "tiles.png") != null);
}
