//! Embedded-tilemap registration emit for the generated `main.zig`
//! (T2 Phase 4, labelle-engine tilemap epic).
//!
//! A scene entity carrying a `Tilemap` component references a `.tmx` map
//! by `asset_name`; the assembler's `tilemap_scan` resolves that (plus the
//! map's tileset images and any external `.tsx` tilesets it references)
//! into a flat list of `Registration { key, embed_path }`. This block turns
//! each into one
//!
//!   `g.addEmbeddedTilemapAsset("<key>", @embedFile("<embed_path>"))`
//!
//! call. The engine (≥ v1.75.0) reads that single registry to fetch the
//! `.tmx` bytes (keyed by `asset_name`) and, after decoding, each tileset
//! image (keyed by the `<image source="...">` string gfx ends up holding).
//!
//! **External tilesets (#678 / gfx#336).** The same registry is what backs
//! gfx's `LoadOptions.tsx_resolver`, whose `resolve(source)` is handed the
//! `<tileset source="...">` attribute EXACTLY as the `.tmx` writes it. So a
//! `.tsx` registration emitted here — key = that verbatim `source`, bytes =
//! `@embedFile` of the resolved file — IS the resolver's table entry: no
//! extra generated wiring is needed beyond this call. The keys are computed
//! by `tilemap_scan`; this module only spells the calls.
//!
//! Emitted from BOTH lifecycle paths, differing only in failure handling
//! — the same `LoadStyle` split `resource_loader` uses. These calls MUST
//! run before `setScene` (which triggers the engine's tilemap decode), so
//! both callers emit this block before the scene-registration block.

const std = @import("std");
const resource_loader = @import("resource_loader.zig");
const tilemap_scan = @import("../../tilemap_scan.zig");

pub const LoadStyle = resource_loader.LoadStyle;

/// Emit `addEmbeddedTilemapAsset` calls for every registration. No-op
/// (emits nothing) when `regs` is empty, so tilemap-free projects are
/// byte-identical to the pre-Phase-4 output.
///
/// The registry key and the `@embedFile` path are emitted through
/// `std.zig.fmtString` (the `{f}` slots), NOT raw `{s}`: a tileset
/// `<image source>` or scene `asset_name` may legally contain a backslash
/// or quote (e.g. a Windows-authored `tiles\terrain.png`), which raw
/// interpolation would turn into invalid Zig or a mis-decoded literal — so
/// the generated key would no longer match what the engine requests at
/// runtime. Escaping keeps the emitted literal both valid AND byte-faithful
/// to the resolver key `tilemap_scan` computed.
pub fn emitTilemapRegistrations(
    w: anytype,
    regs: []const tilemap_scan.Registration,
    style: LoadStyle,
) !void {
    if (regs.len == 0) return;

    try w.writeAll("    // Embedded tilemaps (.tmx + tileset images via @embedFile, T2 Phase 4)\n");
    for (regs) |r| {
        const key = std.zig.fmtString(r.key);
        const path = std.zig.fmtString(r.embed_path);
        switch (style) {
            .try_style => try w.print(
                "    try g.addEmbeddedTilemapAsset(\"{f}\", @embedFile(\"{f}\"));\n",
                .{ key, path },
            ),
            .catch_panic_style => try w.print(
                "    g.addEmbeddedTilemapAsset(\"{f}\", @embedFile(\"{f}\")) catch @panic(\"failed to register embedded tilemap asset: {f}\");\n",
                .{ key, path, key },
            ),
        }
    }
    try w.writeByte('\n');
}
