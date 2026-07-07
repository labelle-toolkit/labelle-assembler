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
