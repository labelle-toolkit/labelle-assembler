//! Embedded-tilemap generate phase (T2 Phase 4 + T3 follow-ups, tilemap epic).
//!
//! Extracted from `root.zig`'s `generate` to keep that orchestrator under
//! the repo's 1000-line limit. Owns the policy around `Tilemap` components:
//! honoring a registered `Tilemap` (engine C2 — project OR pack), scanning
//! the tilemap `asset_name`s declared in scenes AND prefabs (game-root and
//! pack prefabs, assembler#561), and resolving them into the
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
/// Runs AFTER the project's `assets/` dir is linked into `target_dir` (and
/// AFTER `loadPackScans` staged the pack prefab JSONC) so the `.tmx` files
/// are present for reading here and for `@embedFile` at build time, and the
/// pack prefabs are visible on disk.
///
/// Engine C2 (labelle-engine#703): a project that registers its OWN `Tilemap`
/// component (a `components/Tilemap.zig`, pascal-matched) wins over the engine
/// built-in — the engine gates the built-in on `Components.has("Tilemap")`, an
/// EXACT-name check — so the assembler must embed NOTHING. Only an
/// un-namespaced `Tilemap` satisfies that gate; see `registersTilemap`.
///
/// A SCRIPT-DECLARED `Tilemap` (labelle-assembler#585) registers under its
/// exact declared name in the same root namespace, so it satisfies the same
/// gate and must suppress embedding identically — which is why `generate`
/// runs this phase AFTER the declare phase and threads the declared names in
/// (`declared_component_names`, matched verbatim by `declaresTilemap`).
///
/// A PACK's `components/Tilemap.zig` registers under the namespaced field
/// `<pack>__Tilemap`, a DIFFERENT component that does NOT shadow the built-in,
/// so a pack-registered `Tilemap` must NOT suppress embedding (assembler#562
/// P1 fix). Decl-module plugins register their components in Zig source the
/// assembler never parses, so an un-namespaced plugin `Tilemap` is not
/// name-detectable here — but a scene/prefab reference to it only triggers an
/// embed when it carries a non-empty `asset_name`, so the benign case (a
/// plugin `Tilemap` without `asset_name`) already embeds nothing.
///
/// Prefab-borne tilemaps (assembler#561) are embedded exactly like scene ones
/// now — the earlier fail-loud guard is gone. A pack's own `Tilemap` component
/// key is rewritten to the namespaced `<pack>__Tilemap` when `scanPack` stages
/// the prefab, so only genuine engine-built-in `Tilemap` refs survive the scan
/// of a pack prefab; a pack shipping its own `Tilemap` therefore embeds no
/// `.tmx` for it. Genuinely-unsupported cases the scanner already rejects
/// (external `.tsx` tilesets #563, key collisions) still fail loud in
/// `tilemap_scan.collect`.
pub fn collectRegistrations(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    scene_manifests: []const SceneManifest,
    component_names: []const []const u8,
    declared_component_names: []const []const u8,
    prefab_names: []const []const u8,
    pack_scans: []const PackScan,
) ![]const tilemap_scan.Registration {
    // #562: a PROJECT-registered `Tilemap` (exact built-in name) overrides the
    // built-in — embed nothing and let the generic component dispatch route it.
    // A pack's namespaced `<pack>__Tilemap` does NOT override (P1 fix). A
    // script-declared `Tilemap` (#585) registers un-namespaced and overrides
    // exactly like a `components/Tilemap.zig`.
    if (registersTilemap(component_names) or declaresTilemap(declared_component_names)) {
        std.log.info("labelle-assembler: project registers its own `Tilemap` component — skipping built-in tilemap embedding (engine C2)", .{});
        return tilemap_scan.collect(allocator, target_dir, &.{});
    }

    // Aggregate the tilemap `asset_name`s across scenes AND prefabs. Scene
    // names are BORROWED from the manifests; the prefab-scanned names are
    // freshly allocated slices tracked in `prefab_slices` and freed together
    // after `collect` (which only reads them).
    var asset_names: std.ArrayList([]const u8) = .empty;
    defer asset_names.deinit(allocator);
    var prefab_slices: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (prefab_slices.items) |s| scene_manifest.freeTilemapAssets(allocator, s);
        prefab_slices.deinit(allocator);
    }

    for (scene_manifests) |m| {
        for (m.tilemap_assets) |an| try asset_names.append(allocator, an);
    }

    // #561: game-root prefabs — <target>/prefabs/<name>.jsonc.
    try appendPrefabAssets(allocator, target_dir, "prefabs", prefab_names, &asset_names, &prefab_slices);

    // #561: pack prefabs — <target>/<import_prefix>/prefabs/<name>.jsonc, the
    // SAME staged (ref-rewritten) tree the generated `init()` `@embedFile`s
    // pack prefabs from.
    for (pack_scans) |pack| {
        const subdir = try std.fmt.allocPrint(allocator, "{s}/prefabs", .{pack.import_prefix});
        defer allocator.free(subdir);
        try appendPrefabAssets(allocator, target_dir, subdir, pack.prefab_names, &asset_names, &prefab_slices);
    }

    // `collect` dedups by registry key, so passing the raw (possibly repeated)
    // names across scenes + prefabs is fine. Empty → reads no files, emits
    // nothing.
    return tilemap_scan.collect(allocator, target_dir, asset_names.items);
}

/// True iff a PROJECT component pascal-matches the EXACT built-in name
/// `Tilemap` (engine C2 override, assembler#562). This mirrors the engine's
/// `Components.has("Tilemap")` gate, which is an exact-name check.
///
/// Deliberately does NOT consider pack components: a pack's `components/
/// Tilemap.zig` registers under the NAMESPACED field `<pack>__Tilemap`, a
/// DIFFERENT component that does not satisfy `has("Tilemap")` and so does not
/// shadow the built-in — a project legitimately using the built-in `Tilemap`
/// while importing such a pack must still get its `.tmx`/images embedded. A
/// pack's own tilemap usage is a normal namespaced component and never matches
/// the built-in `Tilemap { asset_name }` shape the prefab scan looks for.
/// Decl-module plugins that register an un-namespaced `Tilemap` aren't
/// enumerable by the assembler (their components live in Zig source we never
/// parse) — a known limitation, handled by the benign no-`asset_name` path.
fn registersTilemap(component_names: []const []const u8) bool {
    var pascal_buf: [128]u8 = undefined;
    for (component_names) |name| {
        if (std.mem.eql(u8, idents.pathToPascal(name, &pascal_buf), "Tilemap")) return true;
    }
    return false;
}

/// True iff a SCRIPT-DECLARED component carries the EXACT built-in name
/// `Tilemap` (labelle-assembler#585). Declared components register under
/// their declared name verbatim (no pathToPascal, no pack namespace — see
/// the registry block's `.{name} = @import("scripting_components.zig")`
/// emission), so a literal compare mirrors the engine's exact-name
/// `Components.has("Tilemap")` gate.
fn declaresTilemap(declared_component_names: []const []const u8) bool {
    for (declared_component_names) |name| {
        if (std.mem.eql(u8, name, "Tilemap")) return true;
    }
    return false;
}

/// Read each `<target_dir>/<subdir>/<name>.jsonc` prefab and collect its
/// `Tilemap` component `asset_name`s (assembler#561). A missing/unreadable
/// prefab is skipped (a stale name isn't this scan's concern). Each returned
/// slice is retained in `prefab_slices` (freed by the caller after `collect`);
/// its member strings are pushed onto `asset_names` for embedding.
fn appendPrefabAssets(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    subdir: []const u8,
    prefab_names: []const []const u8,
    asset_names: *std.ArrayList([]const u8),
    prefab_slices: *std.ArrayList([]const []const u8),
) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    for (prefab_names) |name| {
        const rel = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}.jsonc", .{ target_dir, subdir, name });
        defer allocator.free(rel);
        // A prefab NAME may be stale (file genuinely absent) → skip. But any
        // OTHER read failure — OOM, or a real prefab that exceeds the 1 MiB
        // limit / is otherwise unreadable — must PROPAGATE: the generated
        // init() still embeds + registers that prefab, so silently dropping
        // its tilemap asset_names would leave it instantiable at runtime with
        // no addEmbeddedTilemapAsset registration (missing-asset). Only a
        // truly-absent name is benign to skip.
        const src = cwd.readFileAlloc(io, rel, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(src);
        const assets = try scene_manifest.scanTilemapAssets(allocator, src);
        // Empty → `&.{}` (no allocation); nothing to retain or embed.
        if (assets.len == 0) continue;
        prefab_slices.append(allocator, assets) catch |err| {
            scene_manifest.freeTilemapAssets(allocator, assets);
            return err;
        };
        // `assets` is now owned by `prefab_slices`; on a later append error the
        // caller's defer frees its strings — `asset_names` frees only its list.
        for (assets) |an| try asset_names.append(allocator, an);
    }
}
