//! Embedded-tilemap generate phase (T2 Phase 4, tilemap epic).
//!
//! Extracted from `root.zig`'s `generate` to keep that orchestrator under
//! the repo's 1000-line limit. Owns the policy around `Tilemap` components:
//! honoring a project-registered `Tilemap` (engine C2), failing loud on the
//! not-yet-supported prefab-borne case — game-root AND pack prefabs
//! (assembler#561) — aggregating the
//! scene-declared `asset_name`s, and resolving them into the
//! `@embedFile`-backed registrations the generated `init()` emits.
//!
//! Returns an owned `[]tilemap_scan.Registration` — the caller frees it
//! with `tilemap_scan.freeRegistrations`.

const std = @import("std");
const config = @import("../config.zig");
const scene_manifest = @import("../scene_manifest.zig");
const tilemap_scan = @import("../tilemap_scan.zig");
const idents = @import("../codegen/idents.zig");
const scan = @import("../codegen/scan.zig");

const SceneManifest = scene_manifest.SceneManifest;
const PackScan = scan.PackScan;

/// Build the embedded-tilemap registrations for a generation.
///
/// Runs AFTER the project's `assets/` dir is linked into `target_dir` so
/// the `.tmx` files are present for reading here and for `@embedFile` at
/// build time.
///
/// Engine C2 (labelle-engine#703): a project that registers its OWN
/// `Tilemap` component (a `components/Tilemap.zig`, pascal-matched) wins
/// over the engine built-in — the engine routes all `Tilemap` components to
/// the registered type, so the assembler must embed NOTHING. (Plugin/
/// pack-registered `Tilemap` is not detected; that edge is assembler#562 —
/// it fails loud via a missing-asset error rather than corrupting output.)
pub fn collectRegistrations(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    scene_manifests: []const SceneManifest,
    component_names: []const []const u8,
    prefab_names: []const []const u8,
    pack_scans: []const PackScan,
) ![]const tilemap_scan.Registration {
    const project_registers_tilemap = blk: {
        var pascal_buf: [128]u8 = undefined;
        for (component_names) |name| {
            if (std.mem.eql(u8, idents.pathToPascal(name, &pascal_buf), "Tilemap")) break :blk true;
        }
        break :blk false;
    };

    var asset_names: std.ArrayList([]const u8) = .empty;
    defer asset_names.deinit(allocator);
    if (project_registers_tilemap) {
        std.log.info("labelle-assembler: project registers its own `Tilemap` component — skipping built-in tilemap embedding (engine C2)", .{});
    } else {
        // Prefab-borne tilemaps aren't embedded yet (minimal-T2 is
        // scene-only). Fail LOUD rather than ship a binary that panics on a
        // missing tilemap asset at runtime — for BOTH game-root and pack
        // prefabs. Tracked in assembler#561.
        try failOnPrefabTilemaps(allocator, target_dir, prefab_names, pack_scans);
        for (scene_manifests) |m| {
            for (m.tilemap_assets) |an| try asset_names.append(allocator, an);
        }
    }
    // `collect` dedups by registry key, so passing the raw (possibly
    // repeated) names across scenes is fine. Empty → reads no files, emits
    // nothing.
    return tilemap_scan.collect(allocator, target_dir, asset_names.items);
}

/// Fail LOUD if any prefab JSONC — game-root OR pack — declares a `Tilemap`
/// component. Minimal-T2 embeds tilemap assets only for SCENE-borne `Tilemap`
/// components; a prefab-borne one (including a light-pack prefab wired in via
/// `pack_scans`) would not get its assets embedded and would panic at runtime
/// on a missing `addEmbeddedTilemapAsset` lookup. Rather than ship that broken
/// binary, abort generation with a clear message. Full prefab-tilemap support
/// is tracked in assembler#561.
fn failOnPrefabTilemaps(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    prefab_names: []const []const u8,
    pack_scans: []const PackScan,
) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    // Game-root prefabs: <target>/prefabs/<name>.jsonc
    for (prefab_names) |name| {
        try checkPrefabForTilemap(allocator, io, cwd, target_dir, "prefabs", name, "prefab");
    }
    // Pack prefabs: <target>/<import_prefix>/prefabs/<name>.jsonc — the same
    // staged tree the generated `init()` `@embedFile`s pack prefabs from.
    for (pack_scans) |pack| {
        const subdir = try std.fmt.allocPrint(allocator, "{s}/prefabs", .{pack.import_prefix});
        defer allocator.free(subdir);
        for (pack.prefab_names) |name| {
            try checkPrefabForTilemap(allocator, io, cwd, target_dir, subdir, name, "pack prefab");
        }
    }
}

/// Read `<target_dir>/<subdir>/<name>.jsonc` and abort if it declares a
/// `Tilemap` component. A missing/unreadable file is skipped (a stale name
/// isn't this guard's concern). `origin` labels the site in the error
/// ("prefab" / "pack prefab").
fn checkPrefabForTilemap(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    target_dir: []const u8,
    subdir: []const u8,
    name: []const u8,
    origin: []const u8,
) !void {
    const rel = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}.jsonc", .{ target_dir, subdir, name });
    defer allocator.free(rel);
    const src = cwd.readFileAlloc(io, rel, allocator, .limited(1024 * 1024)) catch return;
    defer allocator.free(src);
    const assets = try scene_manifest.scanTilemapAssets(allocator, src);
    defer scene_manifest.freeTilemapAssets(allocator, assets);
    if (assets.len > 0) {
        std.log.err(
            "labelle-assembler: {s} '{s}' declares a Tilemap component ('{s}'), but prefab-borne\n" ++
                "  tilemaps are not embedded yet (minimal-T2 is scene-only; pack prefabs included). Move\n" ++
                "  the Tilemap into a scene, or track full prefab-tilemap support at labelle-assembler#561.",
            .{ origin, name, assets[0] },
        );
        return error.PrefabTilemapUnsupported;
    }
}
