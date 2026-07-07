//! Embedded-tilemap registration emit for the generated `main.zig`
//! (T2 Phase 4, labelle-engine tilemap epic).
//!
//! A scene entity carrying a `Tilemap` component references a `.tmx` map
//! by `asset_name`; the assembler's `tilemap_scan` resolves that (plus the
//! map's tileset images) into a flat list of `Registration { key,
//! embed_path }`. This block turns each into one
//!
//!   `g.addEmbeddedTilemapAsset("<key>", @embedFile("<embed_path>"))`
//!
//! call. The engine (≥ v1.75.0) reads that single registry to fetch the
//! `.tmx` bytes (keyed by `asset_name`) and, after decoding, each tileset
//! image (keyed by the verbatim `<image source="...">` string). The keys
//! are computed by `tilemap_scan`; this module only spells the calls.
//!
//! Emitted from BOTH lifecycle paths, differing only in failure handling
//! — the same `LoadStyle` split `resource_loader` uses. These calls MUST
//! run before `setScene` (which triggers the engine's tilemap decode), so
//! both callers emit this block before the scene-registration block.

const resource_loader = @import("resource_loader.zig");
const tilemap_scan = @import("../../tilemap_scan.zig");

pub const LoadStyle = resource_loader.LoadStyle;

/// Emit `addEmbeddedTilemapAsset` calls for every registration. No-op
/// (emits nothing) when `regs` is empty, so tilemap-free projects are
/// byte-identical to the pre-Phase-4 output.
pub fn emitTilemapRegistrations(
    w: anytype,
    regs: []const tilemap_scan.Registration,
    style: LoadStyle,
) !void {
    if (regs.len == 0) return;

    try w.writeAll("    // Embedded tilemaps (.tmx + tileset images via @embedFile, T2 Phase 4)\n");
    for (regs) |r| {
        switch (style) {
            .try_style => try w.print(
                "    try g.addEmbeddedTilemapAsset(\"{s}\", @embedFile(\"{s}\"));\n",
                .{ r.key, r.embed_path },
            ),
            .catch_panic_style => try w.print(
                "    g.addEmbeddedTilemapAsset(\"{s}\", @embedFile(\"{s}\")) catch @panic(\"failed to register embedded tilemap asset: {s}\");\n",
                .{ r.key, r.embed_path, r.key },
            ),
        }
    }
    try w.writeByte('\n');
}
