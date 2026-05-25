//! Per-resource loader emit for the generated `main.zig`.
//!
//! Extracted from `src/main_zig.zig` (labelle-assembler#183, step 5b)
//! per `docs/REFACTOR-PLAN-main-zig.md`. Owns the one-line dispatcher
//! that the orchestrator calls once per `ResourceDef` to materialise
//! a `Game.load{Atlas,Sound,Font}FromMemory(...)` (or `register…` for
//! lazy resources) into the generated source.
//!
//! `emitResourceLoad` is reached from BOTH lifecycle paths today —
//! `buildSetupCode` (loop-backend setup) uses `.try_style`, the sokol
//! callback initializer uses `.catch_panic_style`. Keeping the
//! per-style branching here means neither lifecycle builder has to
//! know how the underlying `Game.*FromMemory` calls are spelled.
//!
//! Pure emit: no allocations, no template state beyond the writer.
//! Depends on `idents.extWithoutDot` (asset ext sans the dot, matches
//! the engine's `file_type` contract) — `isValidZigIdentifier` is
//! validated upstream by `validateResources`, so this module just
//! interpolates the name into the generated source.

const std = @import("std");
const config = @import("../../config.zig");
const idents = @import("../idents.zig");

const ResourceDef = config.ResourceDef;
const extWithoutDot = idents.extWithoutDot;

/// Wrapper style for `emitResourceLoad`. The two callers differ only
/// in how they propagate load failures:
///
/// - `try_style` — used by `buildSetupCode`, whose enclosing function
///   returns `!void`. Emits `try g.loadXxxFromMemory(...);`.
/// - `catch_panic_style` — used by `buildCallbackInitCode`, whose
///   sokol-callback host has no error channel to unwind into. Emits
///   `g.loadXxxFromMemory(...) catch @panic("failed to load ...");`.
pub const LoadStyle = enum { try_style, catch_panic_style };

/// Emit the loader call for one `ResourceDef`, dispatching on
/// `res.kind()`:
///
/// - `.atlas` → `g.{load,register}AtlasFromMemory(name, json, png, ".png")`
/// - `.sound` → `g.{load,register}SoundFromMemory(name, ext, bytes)`
/// - `.font`  → emits `{name}_ranges` const array + `{name}_params`
///   const struct, then `g.{load,register}FontFromMemory(name, ext,
///   bytes, &{name}_params)`. Materialising the params as a local
///   `engine.FontBakeParams` lets the catalog's `WorkRequest.params`
///   slot point at it without a runtime allocation; the const lives
///   on the stack frame for `main()`'s lifetime.
///
/// Caller has already validated `res.kind() != .invalid` via
/// `validateResources` — this function returns `error.InvalidResourceDef`
/// if reached anyway to guard against future call-site additions.
pub fn emitResourceLoad(w: anytype, res: ResourceDef, style: LoadStyle) !void {
    const is_lazy = res.lazy orelse false;
    switch (res.kind()) {
        .atlas => {
            const fn_name = if (is_lazy) "registerAtlasFromMemory" else "loadAtlasFromMemory";
            switch (style) {
                .try_style => try w.print(
                    "    try g.{s}(\"{s}\", @embedFile(\"{s}\"), @embedFile(\"{s}\"), \".png\");\n",
                    .{ fn_name, res.name, res.json, res.texture },
                ),
                .catch_panic_style => try w.print(
                    "    g.{s}(\"{s}\", @embedFile(\"{s}\"), @embedFile(\"{s}\"), \".png\") catch @panic(\"failed to load atlas: {s}\");\n",
                    .{ fn_name, res.name, res.json, res.texture, res.name },
                ),
            }
        },
        .sound => {
            const fn_name = if (is_lazy) "registerSoundFromMemory" else "loadSoundFromMemory";
            const ext = extWithoutDot(res.sound);
            switch (style) {
                .try_style => try w.print(
                    "    try g.{s}(\"{s}\", \"{s}\", @embedFile(\"{s}\"));\n",
                    .{ fn_name, res.name, ext, res.sound },
                ),
                .catch_panic_style => try w.print(
                    "    g.{s}(\"{s}\", \"{s}\", @embedFile(\"{s}\")) catch @panic(\"failed to load sound: {s}\");\n",
                    .{ fn_name, res.name, ext, res.sound, res.name },
                ),
            }
        },
        .font => {
            const fn_name = if (is_lazy) "registerFontFromMemory" else "loadFontFromMemory";
            const ext = extWithoutDot(res.font);
            const params = res.font_params orelse config.FontBakeParams{};
            // Materialise FontBakeParams locally so the slice field has
            // a real address to point at. The trailing const sits in
            // main()'s frame until process exit — same lifetime as
            // `@embedFile` bytes on the catalog side.
            try w.print("    const {s}_ranges = [_]engine.CodepointRange{{\n", .{res.name});
            for (params.ranges) |r| {
                try w.print("        .{{ .first = 0x{X}, .last = 0x{X} }},\n", .{ r.first, r.last });
            }
            try w.print("    }};\n", .{});
            try w.print(
                "    const {s}_params: engine.FontBakeParams = .{{ .pixel_height = {d}, .ranges = &{s}_ranges, .atlas_width = {d}, .atlas_height = {d} }};\n",
                .{ res.name, params.pixel_height, res.name, params.atlas_width, params.atlas_height },
            );
            switch (style) {
                .try_style => try w.print(
                    "    try g.{s}(\"{s}\", \"{s}\", @embedFile(\"{s}\"), &{s}_params);\n",
                    .{ fn_name, res.name, ext, res.font, res.name },
                ),
                .catch_panic_style => try w.print(
                    "    g.{s}(\"{s}\", \"{s}\", @embedFile(\"{s}\"), &{s}_params) catch @panic(\"failed to load font: {s}\");\n",
                    .{ fn_name, res.name, ext, res.font, res.name, res.name },
                ),
            }
        },
        .invalid => return error.InvalidResourceDef,
    }
}
