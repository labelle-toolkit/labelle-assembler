//! Pure JSON walk that extracts `Tilemap` component `asset_name`s from a
//! parsed scene / prefab tree (T2 Phase 4, tilemap epic).
//!
//! Split out of `scene_manifest.zig` to keep that file under the repo's
//! 1000-line limit; it operates only on an already-parsed `std.json.Value`
//! (no JSONC stripping / file IO), so it has no dependency on the scene
//! manifest's validation surface. `scene_manifest.parseSceneSource` and
//! `scene_manifest.scanTilemapAssets` both delegate the actual walk here.
//!
//! `Tilemap` is an engine built-in the scene loader resolves like
//! `Position` / `PrefabInstance`. A component appears in exactly two places
//! on an entity: as a direct key of the entity's `components:` (or
//! `overrides:`) map, or — flat-form (RFC #594/#596) — as a direct
//! PascalCase key of the entity object itself. This is a STRUCTURED walk of
//! the entity tree, NOT a generic deep scan: a `Tilemap` key that happens to
//! sit inside another component's *data* (e.g. `{"Spawner":{"Tilemap":
//! {...}}}` or `{"components":{"Spawner":{"Tilemap":{...}}}}`) is not a
//! tilemap component and must not be collected.

const std = @import("std");

/// Collect a scene's `Tilemap` asset names into an owned slice (empty →
/// `&.{}`, no allocation). Caller frees each string + the slice.
pub fn parseTilemapAssets(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }
    try collectTilemapAssets(allocator, value, &list);
    if (list.items.len == 0) {
        list.deinit(allocator);
        return &.{};
    }
    return list.toOwnedSlice(allocator);
}

/// Walk a parsed scene value (bundle array, root-wrapped, flat-form, or
/// legacy `entities`), collecting `Tilemap` component `asset_name`s in
/// document order. Appends owned dupes to `out`.
fn collectTilemapAssets(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    out: *std.ArrayList([]const u8),
) !void {
    switch (value) {
        // Bundle (RFC #596 axis 3) — every element is an independent entity.
        .array => |arr| {
            for (arr.items) |item| try collectFromEntity(allocator, item, out);
        },
        .object => |obj| {
            // Root-wrapped (legacy unified): the entity lives under `root`.
            if (obj.get("root")) |root_val| {
                try collectFromEntity(allocator, root_val, out);
            } else {
                // Flat-form / top-level: the file object IS the root entity.
                try collectFromEntity(allocator, value, out);
            }
            // Legacy top-level `entities` array — its elements are entities
            // regardless of the root shape above.
            if (obj.get("entities")) |ents| {
                if (ents == .array) {
                    for (ents.array.items) |item| try collectFromEntity(allocator, item, out);
                }
            }
        },
        else => {},
    }
}

/// Walk a single entity object, collecting a `Tilemap` component from its
/// direct component sites and recursing into `children`. Only DIRECT
/// component keys are inspected — component *values* are opaque data and
/// are never descended into looking for more components.
fn collectFromEntity(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    out: *std.ArrayList([]const u8),
) !void {
    const obj = switch (value) {
        .object => |o| o,
        else => return,
    };
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "Tilemap")) {
            // Flat-form component directly on the entity.
            try collectTilemapAssetName(allocator, val, out);
        } else if (std.mem.eql(u8, key, "components") or std.mem.eql(u8, key, "overrides")) {
            // Wrapped component map — `Tilemap` may be a direct member.
            if (val == .object) {
                if (val.object.get("Tilemap")) |tm| try collectTilemapAssetName(allocator, tm, out);
            }
        } else if (std.mem.eql(u8, key, "children")) {
            if (val == .array) {
                for (val.array.items) |child| try collectFromEntity(allocator, child, out);
            }
        }
        // Any other PascalCase key is a different component; its value is
        // opaque data — do NOT descend (that was the over-match bug).
    }
}

/// Append the non-empty `asset_name` string of a `Tilemap` component value.
fn collectTilemapAssetName(
    allocator: std.mem.Allocator,
    tilemap: std.json.Value,
    out: *std.ArrayList([]const u8),
) !void {
    if (tilemap != .object) return;
    if (tilemap.object.get("asset_name")) |an| {
        if (an == .string and an.string.len > 0) {
            try out.append(allocator, try allocator.dupe(u8, an.string));
        }
    }
}
