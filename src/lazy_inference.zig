/// Ticket #48 — resolve the implicit `lazy` default on resource entries
/// in `project.labelle`.
///
/// Goals:
/// - An omitted `lazy` field (ZON: the struct literal doesn't mention
///   it) is represented as `?bool = null` by the parser.
/// - The new conceptual default is `lazy = true`, matching the
///   direction the Asset Streaming RFC is moving in.
/// - BUT: every existing project that hasn't yet migrated its scenes
///   to declare `assets:` must keep working. Flipping the default
///   blindly would cause those atlases to never load (lazy + no
///   scene-driven preload = no decode ever).
///
/// The resolution rule, applied by `resolveLazyDefaults` below:
///
///   explicit lazy = true  → stays true
///   explicit lazy = false → stays false
///   lazy omitted (null)   →
///     - true  if the resource's name appears in at least one
///       scene manifest's `assets:` list (a scene will request it
///       via `game.loadAtlasIfNeeded`), or
///     - false otherwise (back-compat: the project is unmigrated,
///       behave like the old eager default so the atlas still
///       decodes at startup).
///
/// This pass mutates the `lazy` field in-place (filling in `null`
/// slots). Callers that care about preserving the raw parsed form
/// should clone the slice before calling.
const std = @import("std");
const config = @import("config.zig");
const scene_manifest = @import("scene_manifest.zig");

/// Resolve every `lazy = null` entry in `resources` to a concrete
/// boolean, using the presence (or absence) of the resource name in
/// `manifests` as the tiebreaker.
///
/// `resources` is a mutable slice so we can fill in the null slots in
/// place. The caller (`generate` in root.zig) is expected to have
/// duplicated the parsed slice before calling, since the parsed ZON
/// memory may be `[]const ResourceDef` in some call paths.
///
/// Complexity: O(Resources + TotalSceneAssets). We build a single
/// `StringHashMap` of every referenced asset name once, then look each
/// resource up in constant time — a plain nested scan would be
/// O(Resources × Scenes × Assets), which grows uncomfortably for larger
/// projects and is unnecessary given how cheap the map is.
pub fn resolveLazyDefaults(
    allocator: std.mem.Allocator,
    resources: []config.ResourceDef,
    manifests: []const scene_manifest.SceneManifest,
) !void {
    var referenced = std.StringHashMap(void).init(allocator);
    defer referenced.deinit();
    for (manifests) |m| {
        for (m.assets) |asset| {
            try referenced.put(asset, {});
        }
    }

    for (resources) |*res| {
        if (res.lazy != null) continue; // Explicit — user wins.
        res.lazy = referenced.contains(res.name);
    }
}

// ───── Tests ──────────────────────────────────────────────────────────

const SceneManifest = scene_manifest.SceneManifest;
const ResourceDef = config.ResourceDef;

test "explicit lazy=true is preserved even when unreferenced" {
    var resources = [_]ResourceDef{
        .{ .name = "ignored_by_scene", .lazy = true },
    };
    const manifests = [_]SceneManifest{};
    try resolveLazyDefaults(std.testing.allocator, &resources, &manifests);
    try std.testing.expectEqual(@as(?bool, true), resources[0].lazy);
}

test "explicit lazy=false is preserved even when referenced" {
    var resources = [_]ResourceDef{
        .{ .name = "characters", .lazy = false },
    };
    const assets = [_][]const u8{"characters"};
    const manifests = [_]SceneManifest{
        .{ .name = "menu", .assets = &assets },
    };
    try resolveLazyDefaults(std.testing.allocator, &resources, &manifests);
    try std.testing.expectEqual(@as(?bool, false), resources[0].lazy);
}

test "default + referenced-by-scene → lazy" {
    var resources = [_]ResourceDef{
        .{ .name = "background" },
    };
    const assets = [_][]const u8{"background"};
    const manifests = [_]SceneManifest{
        .{ .name = "menu", .assets = &assets },
    };
    try resolveLazyDefaults(std.testing.allocator, &resources, &manifests);
    try std.testing.expectEqual(@as(?bool, true), resources[0].lazy);
}

test "default + not-referenced → eager (back-compat)" {
    var resources = [_]ResourceDef{
        .{ .name = "legacy_atlas" },
    };
    const manifests = [_]SceneManifest{};
    try resolveLazyDefaults(std.testing.allocator, &resources, &manifests);
    try std.testing.expectEqual(@as(?bool, false), resources[0].lazy);
}

test "default + empty assets across scenes → eager (back-compat)" {
    // Scenes parsed, but none declare assets — this is the classic
    // unmigrated project shape. Back-compat kicks in.
    var resources = [_]ResourceDef{
        .{ .name = "legacy_atlas" },
    };
    const empty: []const []const u8 = &.{};
    const manifests = [_]SceneManifest{
        .{ .name = "menu", .assets = empty },
        .{ .name = "gameplay", .assets = empty },
    };
    try resolveLazyDefaults(std.testing.allocator, &resources, &manifests);
    try std.testing.expectEqual(@as(?bool, false), resources[0].lazy);
}

test "mixed: some referenced, some explicit, some unreferenced" {
    var resources = [_]ResourceDef{
        .{ .name = "referenced" },
        .{ .name = "unreferenced" },
        .{ .name = "explicit_lazy", .lazy = true },
        .{ .name = "explicit_eager", .lazy = false },
    };
    const assets = [_][]const u8{"referenced"};
    const manifests = [_]SceneManifest{
        .{ .name = "menu", .assets = &assets },
    };
    try resolveLazyDefaults(std.testing.allocator, &resources, &manifests);
    try std.testing.expectEqual(@as(?bool, true), resources[0].lazy); // defaulted → referenced → lazy
    try std.testing.expectEqual(@as(?bool, false), resources[1].lazy); // defaulted → unreferenced → eager
    try std.testing.expectEqual(@as(?bool, true), resources[2].lazy); // explicit kept
    try std.testing.expectEqual(@as(?bool, false), resources[3].lazy); // explicit kept
}

test "scene referencing an undeclared resource does not affect unrelated defaults" {
    // The validator pass runs before this one; if we get here, all
    // scene asset names matched some resource. Still, verify the
    // match is exact — a resource whose name doesn't appear in any
    // scene list must not accidentally flip to lazy just because
    // some *other* resource does.
    var resources = [_]ResourceDef{
        .{ .name = "foo" },
        .{ .name = "bar" },
    };
    const assets = [_][]const u8{"foo"};
    const manifests = [_]SceneManifest{
        .{ .name = "menu", .assets = &assets },
    };
    try resolveLazyDefaults(std.testing.allocator, &resources, &manifests);
    try std.testing.expectEqual(@as(?bool, true), resources[0].lazy);
    try std.testing.expectEqual(@as(?bool, false), resources[1].lazy);
}
