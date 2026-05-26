//! Scene-manifest comptime structs emitted into the generated `main.zig`.
//!
//! Two pure block writers that consume the assembler's parsed
//! `SceneManifest` records and produce comptime-discoverable structs
//! the engine reads via `inline for` at scene-load time:
//!
//!   - `writeSceneAssetManifests`        → `pub const SceneAssetManifests = struct { ... };`
//!   - `writeSceneInitialStateManifests` → `pub const SceneInitialStateManifests = struct { ... };`
//!
//! Extracted from `src/main_zig.zig` per step 5 of the cut plan in
//! `docs/REFACTOR-PLAN-main-zig.md` (labelle-assembler#183). Following
//! the mixin-only cleanup (labelle-assembler#206 follow-up), the two
//! writers live as methods on the `Codegen` mixin below — the previous
//! standalone `pub fn writeXxx` forms were collapsed into the mixin
//! method bodies once every external caller (orchestrator + tests) had
//! migrated to the `ctx.writeXxx(...)` dispatch shape. Reads
//! `jsonc_scene_names` + `scene_manifests` from `self`; no allocations,
//! no template state, no I/O beyond the writer.

const std = @import("std");
const scene_manifest = @import("../../scene_manifest.zig");
const idents = @import("../idents.zig");
const scan = @import("../scan.zig");

const SceneManifest = scene_manifest.SceneManifest;
const writeZigString = idents.writeZigString;
const pathToIdent = scan.pathToIdent;

/// Mixin factory for `Codegen` (labelle-assembler#183, mixin
/// conversion). Reads `jsonc_scene_names` + `scene_manifests` from
/// `self` so the orchestrator can call
/// `ctx.writeSceneAssetManifests(w, &ident_buf)` instead of re-threading
/// the slices through every call site. The standalone form is gone —
/// tests + orchestrator all dispatch through the context now.
pub fn Mixin(comptime Self: type) type {
    return struct {
        /// Emit the `SceneAssetManifests` comptime struct that exposes each
        /// scene's declared asset list to labelle-engine's auto-streaming
        /// loader. The shape:
        ///
        ///     pub const SceneAssetManifests = struct {
        ///         pub const menu        = [_][]const u8{ "atlas:ui", "sound:click" };
        ///         pub const world_intro = [_][]const u8{ ... };
        ///
        ///         pub const Entry = struct { name: []const u8, assets: []const []const u8 };
        ///         pub const entries: []const Entry = &.{
        ///             .{ .name = "menu",        .assets = menu },
        ///             .{ .name = "world/intro", .assets = world_intro },
        ///         };
        ///     };
        ///
        /// Per-scene decls give comptime access by ident; the `entries`
        /// array is the stable iteration order (matches the assembler's
        /// sorted scene-name order).
        pub fn writeSceneAssetManifests(self: *Self, w: anytype, ident_buf: *[256]u8) !void {
            const jsonc_scene_names = self.jsonc_scene_names;
            const scene_manifests = self.scene_manifests;
            if (jsonc_scene_names.len == 0) return;
            // In the production codegen path the two slices are produced together in
            // root.zig and are always the same length. Existing main.zig generation
            // tests, however, pass the legacy parameter set with an empty manifest
            // slice — we treat that as "no asset metadata, all scenes empty" so old
            // tests stay valid without a forced rewrite.
            const have_manifests = scene_manifests.len == jsonc_scene_names.len;
            std.debug.assert(have_manifests or scene_manifests.len == 0);

            try w.writeAll("\n// --- Scene asset manifests (parsed from scenes/*.jsonc) ---\n");
            try w.writeAll("pub const SceneAssetManifests = struct {\n");

            // Per-scene named decls.
            for (jsonc_scene_names, 0..) |name, idx| {
                const ident = pathToIdent(name, ident_buf);
                const assets: []const []const u8 = if (have_manifests) scene_manifests[idx].assets else &.{};
                if (assets.len == 0) {
                    try w.print("    pub const {s}: []const []const u8 = &.{{}};\n", .{ident});
                } else {
                    try w.print("    pub const {s}: []const []const u8 = &.{{ ", .{ident});
                    for (assets, 0..) |asset, i| {
                        if (i > 0) try w.writeAll(", ");
                        try writeZigString(w, asset);
                    }
                    try w.writeAll(" };\n");
                }
            }

            // Stable iteration list. Engine code can do
            //   for (SceneAssetManifests.entries) |e| { ... e.name, e.assets ... }
            // without touching @typeInfo at all.
            try w.writeAll("\n    pub const Entry = struct { name: []const u8, assets: []const []const u8 };\n");
            try w.writeAll("    pub const entries: []const Entry = &.{\n");
            for (jsonc_scene_names) |name| {
                const ident = pathToIdent(name, ident_buf);
                try w.writeAll("        .{ .name = ");
                try writeZigString(w, name);
                try w.print(", .assets = @This().{s} }},\n", .{ident});
            }
            try w.writeAll("    };\n");
            try w.writeAll("};\n");
        }

        /// Emit the `SceneInitialStateManifests` comptime struct that
        /// exposes each scene's declared `initial_state:` to
        /// labelle-engine's setSceneInitialState API. Mirrors the
        /// SceneAssetManifests pattern (see above).
        ///
        ///     pub const SceneInitialStateManifests = struct {
        ///         pub const Entry = struct { name: []const u8, initial_state: []const u8 };
        ///         pub const entries: []const Entry = &.{
        ///             .{ .name = "combat_arena", .initial_state = "playing" },
        ///         };
        ///     };
        ///
        /// Unlike SceneAssetManifests, this struct ONLY lists scenes that
        /// actually declared an `initial_state` — scenes without one don't
        /// appear, so the generated `inline for (entries)` loop is a no-op
        /// for back-compat scenes.
        pub fn writeSceneInitialStateManifests(self: *Self, w: anytype) !void {
            const jsonc_scene_names = self.jsonc_scene_names;
            const scene_manifests = self.scene_manifests;
            if (jsonc_scene_names.len == 0) return;
            if (scene_manifests.len != jsonc_scene_names.len) {
                // Legacy parameter set (manifest slice empty) — emit a stub
                // with no entries so the generated inline-for is a no-op.
                try w.writeAll("\n// --- Scene initial-state manifests (parsed from scenes/*.jsonc) ---\n");
                try w.writeAll("pub const SceneInitialStateManifests = struct {\n");
                try w.writeAll("    pub const Entry = struct { name: []const u8, initial_state: []const u8 };\n");
                try w.writeAll("    pub const entries: []const Entry = &.{};\n");
                try w.writeAll("};\n");
                return;
            }

            try w.writeAll("\n// --- Scene initial-state manifests (parsed from scenes/*.jsonc) ---\n");
            try w.writeAll("pub const SceneInitialStateManifests = struct {\n");
            try w.writeAll("    pub const Entry = struct { name: []const u8, initial_state: []const u8 };\n");
            try w.writeAll("    pub const entries: []const Entry = &.{\n");
            for (scene_manifests) |m| {
                const state = m.initial_state orelse continue;
                try w.writeAll("        .{ .name = ");
                try writeZigString(w, m.name);
                try w.writeAll(", .initial_state = ");
                try writeZigString(w, state);
                try w.writeAll(" },\n");
            }
            try w.writeAll("    };\n");
            try w.writeAll("};\n");
        }
    };
}
