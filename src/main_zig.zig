/// main.zig generator — shared sections + backend lifecycle template rendering.
const std = @import("std");
const tpl = @import("template.zig");
const config = @import("config.zig");
const script_scanner = @import("script_scanner.zig");
const scene_manifest = @import("scene_manifest.zig");

const ProjectConfig = config.ProjectConfig;
const PluginDep = config.PluginDep;
const LayerDef = config.LayerDef;
const ResourceDef = config.ResourceDef;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;
const SceneManifest = scene_manifest.SceneManifest;


/// Validate that no two prefab paths collapse to the same basename.
/// Returns a heap-allocated error message on collision (caller
/// owns); returns `null` when the set is unambiguous. Quadratic
/// over the prefab list — fine for the expected ~10²-scale prefab
/// counts, no need for a HashSet.
fn checkBasenameCollisions(allocator: std.mem.Allocator, prefab_names: []const []const u8) !?[]const u8 {
    for (prefab_names, 0..) |a, i| {
        const a_base = std.fs.path.basename(a);
        for (prefab_names[i + 1 ..]) |b| {
            const b_base = std.fs.path.basename(b);
            if (std.mem.eql(u8, a_base, b_base)) {
                return try std.fmt.allocPrint(allocator, "duplicate prefab basename '{s}' (paths: '{s}', '{s}') — every prefab must have a unique filename across subfolders", .{ a_base, a, b });
            }
        }
    }
    return null;
}

/// Check if a script entry with the given name exists.
fn hasContextEntry(entries: []const ScriptEntry) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, "context")) return true;
    }
    return false;
}

/// Emit the image-backend wiring: an adapter namespace bridging the
/// backend's `decodeImage`/`uploadTexture`/`unloadTexture` to
/// `engine.ImageBackend`, plus the `engine.ImageLoader.setBackend(...)`
/// call that installs the adapter.
///
/// Why a side-table: `engine.AssetTexture` is a flat `u32`, but backend
/// `Texture` values are per-backend structs. Most backends (raylib,
/// sdl, bgfx, wgpu) also store width/height in the struct — those
/// fields are unused by their `unloadTexture` paths so a `.id`
/// round-trip would work. Sokol, however, stores `sg.Image`,
/// `sg.View`, and `sg.Sampler` handles alongside the id; those extra
/// handles MUST reach `sg.destroyView` / `sg.destroySampler` on
/// unload or every uploaded texture leaks two GL resources. A uniform
/// side-table keyed by a fresh u32 handle handles every backend the
/// same way without touching either contract.
///
/// Called with `indent` matching the surrounding block (4 spaces in
/// `buildSetupCode`, 4 spaces in `buildCallbackInitCode`). The
/// emitted block ends with a blank line so the following code can
/// stay its existing shape.
///
/// Ticket: labelle-toolkit/labelle-assembler#53
/// Refs: labelle-toolkit/labelle-engine#437 (Asset Streaming RFC)
fn writeImageBackendWiring(w: anytype, indent: []const u8) !void {
    try w.print("{s}// ── Image asset backend wiring (Asset Streaming RFC, #53) ──\n", .{indent});
    try w.print("{s}// `engine.ImageLoader.setBackend` installs function-pointer adapters\n", .{indent});
    try w.print("{s}// that marshal between `BackendGfx`'s `DecodedImage`/`Texture` and\n", .{indent});
    try w.print("{s}// the engine's `DecodedImage` + flat `AssetTexture` (u32) handle.\n", .{indent});
    try w.print("{s}// A private slot table keyed by a fresh u32 preserves the full\n", .{indent});
    try w.print("{s}// backend `Texture` so unload releases every auxiliary GPU handle\n", .{indent});
    try w.print("{s}// (e.g. sokol's `sg.View` + `sg.Sampler`) — a plain `.id` passthrough\n", .{indent});
    try w.print("{s}// would leak those aux handles.\n", .{indent});
    try w.print("{s}const ImageBackendAdapter = struct {{\n", .{indent});
    try w.print("{s}    const MAX_IMAGE_ASSETS = 1024;\n", .{indent});
    try w.print("{s}    var slots: [MAX_IMAGE_ASSETS]?BackendGfx.Texture = [_]?BackendGfx.Texture{{null}} ** MAX_IMAGE_ASSETS;\n", .{indent});
    // Renderer pointer for `registerCatalogTexture` — set after
    // `g` is initialized in main(). Without this the renderer's
    // sprite draw path falls back to treating the slot handle as a
    // GL texture id and produces white quads. See
    // labelle-toolkit/labelle-gfx#248.
    try w.print("{s}    var renderer_ref: ?*Renderer = null;\n", .{indent});
    try w.print("{s}\n", .{indent});
    try w.print("{s}    fn decode(\n", .{indent});
    try w.print("{s}        file_type: [:0]const u8,\n", .{indent});
    try w.print("{s}        data: []const u8,\n", .{indent});
    try w.print("{s}        alloc: std.mem.Allocator,\n", .{indent});
    try w.print("{s}    ) anyerror!engine.DecodedImage {{\n", .{indent});
    try w.print("{s}        const d = try BackendGfx.decodeImage(file_type, data, alloc);\n", .{indent});
    try w.print("{s}        return .{{ .pixels = d.pixels, .width = d.width, .height = d.height }};\n", .{indent});
    try w.print("{s}    }}\n", .{indent});
    try w.print("{s}\n", .{indent});
    try w.print("{s}    fn upload(decoded: engine.DecodedImage) anyerror!engine.AssetTexture {{\n", .{indent});
    // Find a free slot BEFORE uploading to the GPU — otherwise a
    // full slot table would leak the backend texture. Reusing the
    // lowest free index means `unload`'s recycled slots come back
    // into play (critical: `next_id`-style monotonic counters
    // exhaust after MAX_IMAGE_ASSETS total uploads regardless of
    // intervening unloads). O(MAX_IMAGE_ASSETS) scan is fine for
    // a 1024-slot array — this path runs once per asset upload.
    try w.print("{s}        var handle: u32 = MAX_IMAGE_ASSETS;\n", .{indent});
    try w.print("{s}        for (slots, 0..) |slot, i| {{\n", .{indent});
    try w.print("{s}            if (slot == null) {{\n", .{indent});
    try w.print("{s}                handle = @intCast(i);\n", .{indent});
    try w.print("{s}                break;\n", .{indent});
    try w.print("{s}            }}\n", .{indent});
    try w.print("{s}        }}\n", .{indent});
    try w.print("{s}        if (handle == MAX_IMAGE_ASSETS) return error.ImageSlotsExhausted;\n", .{indent});
    try w.print("{s}        const backend_decoded: BackendGfx.DecodedImage = .{{\n", .{indent});
    try w.print("{s}            .pixels = decoded.pixels,\n", .{indent});
    try w.print("{s}            .width = decoded.width,\n", .{indent});
    try w.print("{s}            .height = decoded.height,\n", .{indent});
    try w.print("{s}        }};\n", .{indent});
    try w.print("{s}        const tex = try BackendGfx.uploadTexture(backend_decoded);\n", .{indent});
    try w.print("{s}        slots[handle] = tex;\n", .{indent});
    // Register the slot handle → real BackendTexture mapping with
    // the renderer so the sprite draw path resolves correctly.
    // The slot handle is NOT a GL texture id; without this
    // registration `getTextureInfo(handle)` returns null and
    // raylib renders white quads — see
    // labelle-toolkit/labelle-gfx#248.
    try w.print("{s}        if (renderer_ref) |r| r.registerCatalogTexture(handle, tex);\n", .{indent});
    try w.print("{s}        return handle;\n", .{indent});
    try w.print("{s}    }}\n", .{indent});
    try w.print("{s}\n", .{indent});
    try w.print("{s}    fn unload(texture: engine.AssetTexture) void {{\n", .{indent});
    try w.print("{s}        if (texture >= MAX_IMAGE_ASSETS) return;\n", .{indent});
    try w.print("{s}        if (slots[texture]) |tex| {{\n", .{indent});
    try w.print("{s}            BackendGfx.unloadTexture(tex);\n", .{indent});
    try w.print("{s}            slots[texture] = null;\n", .{indent});
    try w.print("{s}        }}\n", .{indent});
    try w.print("{s}    }}\n", .{indent});
    try w.print("{s}}};\n", .{indent});
    try w.print("{s}engine.ImageLoader.setBackend(.{{\n", .{indent});
    try w.print("{s}    .decode = ImageBackendAdapter.decode,\n", .{indent});
    try w.print("{s}    .upload = ImageBackendAdapter.upload,\n", .{indent});
    try w.print("{s}    .unload = ImageBackendAdapter.unload,\n", .{indent});
    try w.print("{s}}});\n", .{indent});
    // Wire the renderer reference for the upload path's
    // `registerCatalogTexture` call. `g` is initialized just above
    // this snippet's caller (main_zig.zig template substitution
    // point) so the assignment is safe.
    try w.print("{s}ImageBackendAdapter.renderer_ref = g.renderer;\n", .{indent});
    try w.print("\n", .{});
}

/// Emit the audio-backend wiring: an adapter namespace bridging the
/// backend's `decodeAudio`/`uploadSound`/`unloadSound` to
/// `engine.AudioBackend`, plus the `engine.AudioLoader.setBackend(...)`
/// call that installs the adapter.
///
/// Structural mirror of `writeImageBackendWiring`. The slot table
/// marshals between the backend's per-backend `Sound` struct and the
/// engine's flat `SoundId` ({ index: u16, generation: u16 }) handle.
/// Concrete audio backends (raylib-audio, sokol-audio, …) publish
/// `decodeAudio`/`uploadSound`/`unloadSound` next to their existing
/// runtime playback functions in the backend's audio module
/// (imported here as `BackendAudio` — see
/// `labelle-engine/codegen/main.zig.template`).
///
/// SCAFFOLDING (Phase 4, #447): this helper is currently defined but
/// NOT yet called from `buildSetupCode` / `buildCallbackInitCode`. The
/// missing pieces before it can be wired in:
///   1. `engine.AudioLoader` must be re-exported from
///      `labelle-engine/src/root.zig` (mirror of `ImageLoader` at the
///      bottom of that file).
///   2. `ProjectConfig.resources` (in `src/config.zig`) must grow a
///      resource shape for audio (`.wav`/`.ogg` instead of the
///      atlas-shaped `.json` + `.texture`), and the assembler must
///      dispatch on extension to choose between `registerAtlasFromMemory`
///      and `registerSoundFromMemory` (or equivalent).
///   3. At least one concrete backend (`labelle-raylib-audio` or
///      `labelle-sokol-audio`) must implement `decodeAudio` etc. on its
///      audio module. Until then, calling this helper would generate
///      code that fails to compile.
///
/// This PR lands the codegen skeleton + unit tests so the function is
/// reviewed in isolation; follow-up PRs add the three pieces above and
/// the call sites.
///
/// Ticket: labelle-engine#447 (audio loader tracking)
/// Sibling: `writeImageBackendWiring` (already wired)
pub fn writeAudioBackendWiring(w: anytype, indent: []const u8) !void {
    try w.print("{s}// ── Audio asset backend wiring (Asset Streaming RFC, #447) ──\n", .{indent});
    try w.print("{s}// `engine.AudioLoader.setBackend` installs function-pointer adapters\n", .{indent});
    try w.print("{s}// that marshal between `BackendAudio`'s `DecodedAudio`/`Sound` and\n", .{indent});
    try w.print("{s}// the engine's `DecodedAudio` + `SoundId` ({{ index, generation }}) handle.\n", .{indent});
    try w.print("{s}// A private slot table keyed by the SoundId index preserves the full\n", .{indent});
    try w.print("{s}// backend `Sound` struct so unload releases the device-side buffer\n", .{indent});
    try w.print("{s}// (and any auxiliary handles the backend allocates per sound).\n", .{indent});
    try w.print("{s}const AudioBackendAdapter = struct {{\n", .{indent});
    try w.print("{s}    const MAX_AUDIO_ASSETS = 1024;\n", .{indent});
    try w.print("{s}    var slots: [MAX_AUDIO_ASSETS]?BackendAudio.Sound = [_]?BackendAudio.Sound{{null}} ** MAX_AUDIO_ASSETS;\n", .{indent});
    try w.print("{s}\n", .{indent});
    try w.print("{s}    fn decode(\n", .{indent});
    try w.print("{s}        file_type: [:0]const u8,\n", .{indent});
    try w.print("{s}        data: []const u8,\n", .{indent});
    try w.print("{s}        alloc: std.mem.Allocator,\n", .{indent});
    try w.print("{s}    ) anyerror!engine.DecodedAudio {{\n", .{indent});
    try w.print("{s}        const d = try BackendAudio.decodeAudio(file_type, data, alloc);\n", .{indent});
    try w.print("{s}        return .{{ .samples = d.samples, .sample_rate = d.sample_rate, .channels = d.channels }};\n", .{indent});
    try w.print("{s}    }}\n", .{indent});
    try w.print("{s}\n", .{indent});
    try w.print("{s}    fn upload(decoded: engine.DecodedAudio) anyerror!engine.SoundId {{\n", .{indent});
    // Find a free slot BEFORE uploading to the audio device —
    // otherwise a full slot table would leak the backend sound.
    // Reusing the lowest free index means `unload`'s recycled slots
    // come back into play; a monotonic counter would exhaust after
    // MAX_AUDIO_ASSETS total uploads regardless of intervening
    // unloads.
    try w.print("{s}        var idx: u16 = MAX_AUDIO_ASSETS;\n", .{indent});
    try w.print("{s}        for (slots, 0..) |slot, i| {{\n", .{indent});
    try w.print("{s}            if (slot == null) {{\n", .{indent});
    try w.print("{s}                idx = @intCast(i);\n", .{indent});
    try w.print("{s}                break;\n", .{indent});
    try w.print("{s}            }}\n", .{indent});
    try w.print("{s}        }}\n", .{indent});
    try w.print("{s}        if (idx == MAX_AUDIO_ASSETS) return error.AudioSlotsExhausted;\n", .{indent});
    try w.print("{s}        const backend_decoded: BackendAudio.DecodedAudio = .{{\n", .{indent});
    try w.print("{s}            .samples = decoded.samples,\n", .{indent});
    try w.print("{s}            .sample_rate = decoded.sample_rate,\n", .{indent});
    try w.print("{s}            .channels = decoded.channels,\n", .{indent});
    try w.print("{s}        }};\n", .{indent});
    try w.print("{s}        const sound = try BackendAudio.uploadSound(backend_decoded);\n", .{indent});
    try w.print("{s}        slots[idx] = sound;\n", .{indent});
    // Generation is fixed at 1 for v1 — concrete backends that need
    // stale-handle detection can bump this in a follow-up by tracking
    // a per-slot generation counter incremented on unload.
    try w.print("{s}        return .{{ .index = idx, .generation = 1 }};\n", .{indent});
    try w.print("{s}    }}\n", .{indent});
    try w.print("{s}\n", .{indent});
    try w.print("{s}    fn unload(sound: engine.SoundId) void {{\n", .{indent});
    try w.print("{s}        if (sound.index >= MAX_AUDIO_ASSETS) return;\n", .{indent});
    try w.print("{s}        if (slots[sound.index]) |s| {{\n", .{indent});
    try w.print("{s}            BackendAudio.unloadSound(s);\n", .{indent});
    try w.print("{s}            slots[sound.index] = null;\n", .{indent});
    try w.print("{s}        }}\n", .{indent});
    try w.print("{s}    }}\n", .{indent});
    try w.print("{s}}};\n", .{indent});
    try w.print("{s}engine.AudioLoader.setBackend(.{{\n", .{indent});
    try w.print("{s}    .decode = AudioBackendAdapter.decode,\n", .{indent});
    try w.print("{s}    .upload = AudioBackendAdapter.upload,\n", .{indent});
    try w.print("{s}    .unload = AudioBackendAdapter.unload,\n", .{indent});
    try w.print("{s}}});\n", .{indent});
    try w.print("\n", .{});
}
/// Emit the font-backend wiring: an adapter namespace bridging the
/// graphics backend's `decodeFont`/`uploadFontAtlas`/`unloadFontAtlas`
/// to `engine.FontBackend`, plus the `engine.FontLoader.setBackend(...)`
/// call that installs the adapter.
///
/// Structural mirror of `writeImageBackendWiring`. Fonts live alongside
/// images in `BackendGfx` (labelle-gfx#258 adds the three font traits
/// next to the existing image trio), NOT in a separate `BackendFont`
/// module. The slot table marshals between the backend's per-backend
/// `FontAtlas` struct and the engine's flat `FontId`
/// ({ index: u16, generation: u16 }) handle — same shape as
/// `writeAudioBackendWiring`'s slot/SoundId pairing.
///
/// `FontBakeParams` threads through decode (RFC §7): the engine passes
/// `WorkRequest.params` as `?*const anyopaque`, the generated adapter
/// casts it back to `*const engine.FontBakeParams` and copies field-by-
/// field into the backend's structurally-identical-but-nominally-
/// distinct `BackendGfx.FontBakeParams` before calling `decodeFont`.
///
/// `@hasDecl` guard: labelle-gfx#258 gates the font decls behind the
/// concrete backend opting in (raylib gets them first, sokol/sdl/bgfx/
/// wgpu follow as glyph rasterisers are ported). The generated adapter
/// mirrors that guard — every method's body is wrapped in
/// `if (@hasDecl(BackendGfx, "decodeFont"))`-style checks so games
/// that don't use fonts still compile on backends that haven't
/// implemented the traits yet. When the decls are missing the adapter
/// returns `error.FontBackendNotImplemented` from `decode`/`upload`
/// and silently no-ops on `unload`.
///
/// SCAFFOLDING (Phase 4, #448): this helper is currently defined but
/// NOT yet called from `buildSetupCode` / `buildCallbackInitCode`. The
/// missing pieces before it can be wired in:
///   1. `engine.FontLoader` must be re-exported from
///      `labelle-engine/src/root.zig` (sibling PR in flight — mirrors
///      the `ImageLoader` / `AudioLoader` re-exports).
///   2. `ProjectConfig.resources` (in `src/config.zig`) must grow a
///      font-shaped resource entry (`.ttf` / `.otf` + a
///      `FontBakeParams` payload: pixel sizes, atlas dimensions,
///      codepoint ranges) and the assembler must dispatch on extension
///      to choose between `registerAtlasFromMemory`,
///      `registerSoundFromMemory`, and `registerFontFromMemory`.
///   3. At least one graphics backend (`labelle-raylib` first, per
///      labelle-gfx#258) must implement `decodeFont` /
///      `uploadFontAtlas` / `unloadFontAtlas` on its `gfx.zig`. Until
///      then, calling this helper unconditionally would generate code
///      that fails to compile on the non-opted-in backends — hence the
///      `@hasDecl` guard.
///
/// This PR lands the codegen skeleton + unit tests so the function is
/// reviewed in isolation; follow-up PRs add the three pieces above and
/// the call sites.
///
/// Ticket: labelle-engine#448 (font loader tracking)
/// Sibling: `writeAudioBackendWiring` (audio scaffolding, #447)
/// Refs: labelle-gfx#258 (font traits on `Backend(Impl)`)
pub fn writeFontBackendWiring(w: anytype, indent: []const u8) !void {
    try w.print("{s}// ── Font asset backend wiring (Asset Streaming RFC, #448) ──\n", .{indent});
    try w.print("{s}// `engine.FontLoader.setBackend` installs function-pointer adapters\n", .{indent});
    try w.print("{s}// that marshal between `BackendGfx`'s `DecodedFont`/`FontAtlas` and\n", .{indent});
    try w.print("{s}// the engine's `DecodedFont` + `FontId` ({{ index, generation }}) handle.\n", .{indent});
    try w.print("{s}// A private slot table keyed by the FontId index preserves the full\n", .{indent});
    try w.print("{s}// backend `FontAtlas` struct so unload releases the GPU atlas texture\n", .{indent});
    try w.print("{s}// (and any auxiliary handles the backend allocates per font).\n", .{indent});
    try w.print("{s}// `FontBakeParams` threads through decode (RFC §7).\n", .{indent});
    try w.print("{s}// `@hasDecl` guards each method body: backends that haven't opted into\n", .{indent});
    try w.print("{s}// gfx#258's font traits return `error.FontBackendNotImplemented` from\n", .{indent});
    try w.print("{s}// decode/upload and no-op on unload, so games without font usage still\n", .{indent});
    try w.print("{s}// compile against every backend.\n", .{indent});
    try w.print("{s}const FontBackendAdapter = struct {{\n", .{indent});
    try w.print("{s}    const MAX_FONT_ASSETS = 1024;\n", .{indent});
    try w.print("{s}    var slots: [MAX_FONT_ASSETS]?BackendGfx.FontAtlas = [_]?BackendGfx.FontAtlas{{null}} ** MAX_FONT_ASSETS;\n", .{indent});
    try w.print("{s}\n", .{indent});
    try w.print("{s}    fn decode(\n", .{indent});
    try w.print("{s}        file_type: [:0]const u8,\n", .{indent});
    try w.print("{s}        data: []const u8,\n", .{indent});
    try w.print("{s}        params: ?*const anyopaque,\n", .{indent});
    try w.print("{s}        alloc: std.mem.Allocator,\n", .{indent});
    try w.print("{s}    ) anyerror!engine.DecodedFont {{\n", .{indent});
    // `@hasDecl` guard: without it, games that don't actually
    // reach the font loader still fail to compile on backends
    // that haven't implemented the gfx#258 font traits yet. The
    // guard short-circuits to a runtime error instead.
    try w.print("{s}        if (!@hasDecl(BackendGfx, \"decodeFont\")) return error.FontBackendNotImplemented;\n", .{indent});
    // `params` is a `?*const anyopaque` per the engine's
    // `WorkRequest` contract; the loader casts back to the
    // engine's `FontBakeParams` then copies field-by-field
    // into the backend's structurally-identical-but-nominally-
    // distinct `BackendGfx.FontBakeParams`. Same trap as the
    // image/audio adapters' DecodedX copy.
    try w.print("{s}        const engine_params: *const engine.FontBakeParams = @ptrCast(@alignCast(params orelse return error.FontBakeParamsMissing));\n", .{indent});
    try w.print("{s}        const backend_params: BackendGfx.FontBakeParams = .{{\n", .{indent});
    try w.print("{s}            .pixel_height = engine_params.pixel_height,\n", .{indent});
    try w.print("{s}            .ranges = engine_params.ranges,\n", .{indent});
    try w.print("{s}            .atlas_width = engine_params.atlas_width,\n", .{indent});
    try w.print("{s}            .atlas_height = engine_params.atlas_height,\n", .{indent});
    try w.print("{s}        }};\n", .{indent});
    try w.print("{s}        const d = try BackendGfx.decodeFont(file_type, data, &backend_params, alloc);\n", .{indent});
    try w.print("{s}        return .{{\n", .{indent});
    try w.print("{s}            .bitmap = d.bitmap,\n", .{indent});
    try w.print("{s}            .width = d.width,\n", .{indent});
    try w.print("{s}            .height = d.height,\n", .{indent});
    // `.glyphs` / `.codepoint_index` / `.kerning` are slices of
    // structurally-identical-but-nominally-distinct extern structs
    // (BackendGfx.Glyph vs engine.Glyph, etc.). Plain assignment
    // fails to typecheck across the nominal boundary; `@ptrCast`
    // on the slice is a zero-cost reinterpret that respects the
    // `extern struct` layout guarantee on both sides. See
    // labelle-engine#533 + labelle-gfx#259 for the matching
    // `extern struct` declarations this relies on.
    try w.print("{s}            .glyphs = @ptrCast(d.glyphs),\n", .{indent});
    try w.print("{s}            .codepoint_index = @ptrCast(d.codepoint_index),\n", .{indent});
    try w.print("{s}            .ascent = d.ascent,\n", .{indent});
    try w.print("{s}            .descent = d.descent,\n", .{indent});
    try w.print("{s}            .line_gap = d.line_gap,\n", .{indent});
    try w.print("{s}            .line_height = d.line_height,\n", .{indent});
    try w.print("{s}            .kerning = @ptrCast(d.kerning),\n", .{indent});
    try w.print("{s}        }};\n", .{indent});
    try w.print("{s}    }}\n", .{indent});
    try w.print("{s}\n", .{indent});
    try w.print("{s}    fn upload(decoded: engine.DecodedFont) anyerror!engine.FontId {{\n", .{indent});
    try w.print("{s}        if (!@hasDecl(BackendGfx, \"uploadFontAtlas\")) return error.FontBackendNotImplemented;\n", .{indent});
    // Find a free slot BEFORE uploading to the GPU — same
    // reasoning as the image/audio adapters: a full slot table
    // with an upload-first ordering would leak the backend
    // atlas texture.
    try w.print("{s}        var idx: u16 = MAX_FONT_ASSETS;\n", .{indent});
    try w.print("{s}        for (slots, 0..) |slot, i| {{\n", .{indent});
    try w.print("{s}            if (slot == null) {{\n", .{indent});
    try w.print("{s}                idx = @intCast(i);\n", .{indent});
    try w.print("{s}                break;\n", .{indent});
    try w.print("{s}            }}\n", .{indent});
    try w.print("{s}        }}\n", .{indent});
    try w.print("{s}        if (idx == MAX_FONT_ASSETS) return error.FontSlotsExhausted;\n", .{indent});
    try w.print("{s}        const backend_decoded: BackendGfx.DecodedFont = .{{\n", .{indent});
    try w.print("{s}            .bitmap = decoded.bitmap,\n", .{indent});
    try w.print("{s}            .width = decoded.width,\n", .{indent});
    try w.print("{s}            .height = decoded.height,\n", .{indent});
    // Reverse-direction slice marshal (engine → BackendGfx). Same
    // ptrcast trick as the decode path above.
    try w.print("{s}            .glyphs = @ptrCast(decoded.glyphs),\n", .{indent});
    try w.print("{s}            .codepoint_index = @ptrCast(decoded.codepoint_index),\n", .{indent});
    try w.print("{s}            .ascent = decoded.ascent,\n", .{indent});
    try w.print("{s}            .descent = decoded.descent,\n", .{indent});
    try w.print("{s}            .line_gap = decoded.line_gap,\n", .{indent});
    try w.print("{s}            .line_height = decoded.line_height,\n", .{indent});
    try w.print("{s}            .kerning = @ptrCast(decoded.kerning),\n", .{indent});
    try w.print("{s}        }};\n", .{indent});
    try w.print("{s}        const atlas = try BackendGfx.uploadFontAtlas(backend_decoded);\n", .{indent});
    try w.print("{s}        slots[idx] = atlas;\n", .{indent});
    // Generation is fixed at 1 for v1 — concrete backends that
    // need stale-handle detection can bump this in a follow-up
    // by tracking a per-slot generation counter incremented on
    // unload. Matches the audio adapter's v1 posture.
    try w.print("{s}        return .{{ .index = idx, .generation = 1 }};\n", .{indent});
    try w.print("{s}    }}\n", .{indent});
    try w.print("{s}\n", .{indent});
    try w.print("{s}    fn unload(font: engine.FontId) void {{\n", .{indent});
    try w.print("{s}        if (!@hasDecl(BackendGfx, \"unloadFontAtlas\")) return;\n", .{indent});
    try w.print("{s}        if (font.index >= MAX_FONT_ASSETS) return;\n", .{indent});
    try w.print("{s}        if (slots[font.index]) |a| {{\n", .{indent});
    try w.print("{s}            BackendGfx.unloadFontAtlas(a);\n", .{indent});
    try w.print("{s}            slots[font.index] = null;\n", .{indent});
    try w.print("{s}        }}\n", .{indent});
    try w.print("{s}    }}\n", .{indent});
    try w.print("{s}}};\n", .{indent});
    try w.print("{s}engine.FontLoader.setBackend(.{{\n", .{indent});
    try w.print("{s}    .decode = FontBackendAdapter.decode,\n", .{indent});
    try w.print("{s}    .upload = FontBackendAdapter.upload,\n", .{indent});
    try w.print("{s}    .unload = FontBackendAdapter.unload,\n", .{indent});
    try w.print("{s}}});\n", .{indent});
    try w.print("\n", .{});
}


/// Emit the `PluginControllers` comptime dispatcher that scans each plugin's
/// root module for `pub const Controller = struct { ... }` and forwards
/// `setup` / `deinit` lifecycle calls.
///
/// Backward-compatible: the `@hasDecl` guard means plugins that don't opt in
/// contribute nothing at comptime and generate no code.
///
/// RFC: flying-platform-labelle#208 §1 (manifest contract) and §2 (lifecycle
/// wiring). This is the step-1 discovery: only `setup` and `deinit` are
/// auto-wired; per-frame plugin work ships as plugin scripts (step 3).
fn writePluginControllersBlock(bw: anytype, cfg: ProjectConfig) !void {
    try bw.writeAll("// --- Plugin controllers (RFC-plugin-controllers §1–§2) ---\n");
    try bw.writeAll("// Discovers `pub const Controller` in each plugin root module at comptime\n");
    try bw.writeAll("// and dispatches `setup` / `deinit` on scene load / unload. Plugins without\n");
    try bw.writeAll("// a Controller export are silently skipped by the `@hasDecl` guard.\n");
    try bw.writeAll("const PluginControllers = struct {\n");
    try bw.writeAll("    const _plugin_mods = .{\n");
    for (cfg.plugins) |plugin| {
        try bw.print("        @import(\"{s}\"),\n", .{plugin.name});
    }
    try bw.writeAll("    };\n\n");
    try bw.writeAll("    /// Call Controller.setup(game) on every plugin that declares one.\n");
    try bw.writeAll("    /// Plugins whose root module does not export a `Controller` are silently skipped.\n");
    try bw.writeAll("    pub fn setup(game: anytype) !void {\n");
    try bw.writeAll("        inline for (_plugin_mods) |mod| {\n");
    try bw.writeAll("            if (@hasDecl(mod, \"Controller\")) {\n");
    try bw.writeAll("                const C = @field(mod, \"Controller\");\n");
    try bw.writeAll("                if (@hasDecl(C, \"setup\")) try C.setup(game);\n");
    try bw.writeAll("            }\n");
    try bw.writeAll("        }\n");
    try bw.writeAll("    }\n\n");
    try bw.writeAll("    /// Call Controller.deinit(game) on every plugin that declares one.\n");
    try bw.writeAll("    /// Mirrors setup(). Skips plugins without a Controller export or without a deinit.\n");
    try bw.writeAll("    pub fn deinit(game: anytype) void {\n");
    try bw.writeAll("        inline for (_plugin_mods) |mod| {\n");
    try bw.writeAll("            if (@hasDecl(mod, \"Controller\")) {\n");
    try bw.writeAll("                const C = @field(mod, \"Controller\");\n");
    try bw.writeAll("                if (@hasDecl(C, \"deinit\")) C.deinit(game);\n");
    try bw.writeAll("            }\n");
    try bw.writeAll("        }\n");
    try bw.writeAll("    }\n");
    try bw.writeAll("};\n\n");
}

/// Build the setup code block for {{setup_code}} (loop-based backends).
/// Wrapper style for `emitResourceLoad`. The two callers differ only
/// in how they propagate load failures:
///
/// - `try_style` — used by `buildSetupCode`, whose enclosing function
///   returns `!void`. Emits `try g.loadXxxFromMemory(...);`.
/// - `catch_panic_style` — used by `buildCallbackInitCode`, whose
///   sokol-callback host has no error channel to unwind into. Emits
///   `g.loadXxxFromMemory(...) catch @panic("failed to load ...");`.
const LoadStyle = enum { try_style, catch_panic_style };

/// Strip the leading dot from a path extension. `".wav"` → `"wav"`,
/// `""` / `"."` → `""`. Matches the contract of
/// `Game.registerSoundFromMemory` / `registerFontFromMemory`'s
/// `file_type` parameter (lower-case extension without the dot).
fn extWithoutDot(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (ext.len <= 1) return "";
    return ext[1..];
}

/// Returns true iff `name` is a valid bare Zig identifier — first
/// character `[A-Za-z_]`, rest `[A-Za-z0-9_]`. Doesn't reject Zig
/// keywords; in practice resource names like `fn` are vanishingly
/// rare and the resulting compile error names the line clearly.
///
/// Font resources need this guard because `emitResourceLoad` for
/// `.font` interpolates the resource name into Zig identifier
/// positions (`{name}_ranges`, `{name}_params`) — a hyphenated name
/// like `"ui-font"` would generate `const ui-font_ranges = ...`, which
/// is uncompilable. Atlas + sound emissions only place names inside
/// string literals so they're unaffected. Bugbot caught the gap on
/// #105.
fn isValidZigIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    const first_ok = (first >= 'A' and first <= 'Z') or (first >= 'a' and first <= 'z') or first == '_';
    if (!first_ok) return false;
    for (name[1..]) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

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
fn emitResourceLoad(w: anytype, res: ResourceDef, style: LoadStyle) !void {
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
            const params = res.font_params orelse @import("config.zig").FontBakeParams{};
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

/// Pre-emission validation pass over `cfg.resources`. Surfaces every
/// malformed entry as a stderr diagnostic and returns `error.InvalidResource`
/// after the first one — the user sees the offending resource name and
/// what's wrong before any codegen happens. The CLI maps the structured
/// errors from `ResourceDef.validate()` to actionable hints.
fn validateResources(cfg: ProjectConfig) !void {
    const io = config.globalIo();
    for (cfg.resources) |res| {
        switch (res.validate()) {
            .ok => {},
            .no_path => {
                std.Io.File.stderr().writeStreamingAll(io, "labelle-assembler: resource '") catch {};
                std.Io.File.stderr().writeStreamingAll(io, res.name) catch {};
                std.Io.File.stderr().writeStreamingAll(io, "' declares no asset path. Set one of `.json`+`.texture` (atlas), `.sound` (.wav/.ogg), or `.font` (.ttf/.otf).\n") catch {};
                return error.InvalidResource;
            },
            .multiple_paths => {
                std.Io.File.stderr().writeStreamingAll(io, "labelle-assembler: resource '") catch {};
                std.Io.File.stderr().writeStreamingAll(io, res.name) catch {};
                std.Io.File.stderr().writeStreamingAll(io, "' sets more than one asset path. A resource is exactly one of atlas / sound / font.\n") catch {};
                return error.InvalidResource;
            },
            .atlas_incomplete => {
                std.Io.File.stderr().writeStreamingAll(io, "labelle-assembler: atlas resource '") catch {};
                std.Io.File.stderr().writeStreamingAll(io, res.name) catch {};
                std.Io.File.stderr().writeStreamingAll(io, "' is missing either `.json` or `.texture`. Both are required.\n") catch {};
                return error.InvalidResource;
            },
            .font_params_misplaced => {
                std.Io.File.stderr().writeStreamingAll(io, "labelle-assembler: resource '") catch {};
                std.Io.File.stderr().writeStreamingAll(io, res.name) catch {};
                std.Io.File.stderr().writeStreamingAll(io, "' sets `.font_params` but is not a font resource. Remove `.font_params` or change to `.font = \"...\"`.\n") catch {};
                return error.InvalidResource;
            },
        }
        // Extension sanity for sound/font — surfaces obviously-wrong
        // extensions (e.g. `.font = "x.png"`) at codegen time instead
        // of letting the generated `@embedFile` swallow it silently
        // alongside an empty file_type string.
        if (res.kind() == .sound) {
            const ext = extWithoutDot(res.sound);
            if (!std.mem.eql(u8, ext, "wav") and !std.mem.eql(u8, ext, "ogg")) {
                std.Io.File.stderr().writeStreamingAll(io, "labelle-assembler: sound resource '") catch {};
                std.Io.File.stderr().writeStreamingAll(io, res.name) catch {};
                std.Io.File.stderr().writeStreamingAll(io, "' has unsupported extension. Expected `.wav` or `.ogg`.\n") catch {};
                return error.UnsupportedResourceExtension;
            }
        }
        if (res.kind() == .font) {
            const ext = extWithoutDot(res.font);
            if (!std.mem.eql(u8, ext, "ttf") and !std.mem.eql(u8, ext, "otf")) {
                std.Io.File.stderr().writeStreamingAll(io, "labelle-assembler: font resource '") catch {};
                std.Io.File.stderr().writeStreamingAll(io, res.name) catch {};
                std.Io.File.stderr().writeStreamingAll(io, "' has unsupported extension. Expected `.ttf` or `.otf`.\n") catch {};
                return error.UnsupportedResourceExtension;
            }
            // Font emission interpolates `res.name` into Zig
            // identifier positions (`{name}_ranges`, `{name}_params`).
            // A hyphenated name like "ui-font" would otherwise produce
            // uncompilable `const ui-font_ranges = ...`. Atlas + sound
            // emissions don't have this constraint — those names only
            // appear in string literals.
            if (!isValidZigIdentifier(res.name)) {
                std.Io.File.stderr().writeStreamingAll(io, "labelle-assembler: font resource '") catch {};
                std.Io.File.stderr().writeStreamingAll(io, res.name) catch {};
                std.Io.File.stderr().writeStreamingAll(io, "' has a name that is not a valid Zig identifier. Font resource names must start with [A-Za-z_] and contain only [A-Za-z0-9_] thereafter (the codegen uses the name as a local const identifier for the bake params).\n") catch {};
                return error.InvalidFontResourceName;
            }
        }
    }
}

fn buildSetupCode(allocator: std.mem.Allocator, cfg: ProjectConfig, jsonc_scene_names: []const []const u8, prefab_names: []const []const u8) ![]const u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();
    const w = &alloc_writer.writer;

    if (cfg.resolved_gui) |gui| {
        if (gui.lifecycle.init) {
            try w.writeAll("    GuiBackend.init();\n");
        }
        if (gui.lifecycle.shutdown) {
            try w.writeAll("    defer GuiBackend.shutdown();\n\n");
        }
    }

    // Install the engine's image-asset backend hook before any
    // `registerAtlasFromMemory`, `setScene`, or script `setup` can
    // fire — once a scene controller starts calling `catalog.acquire`
    // on an image asset, the hook MUST already point at the backend.
    // Safe to emit unconditionally: all five Backend variants ship
    // the required `decodeImage`/`uploadTexture`/`unloadTexture`
    // trio (see backends/*/src/gfx.zig), and the adapter itself has
    // no runtime cost until the asset catalog actually decodes an
    // image.
    try writeImageBackendWiring(w, "    ");

    // Audio + font adapter wiring is GATED on whether the project
    // actually declares matching resources. Two reasons:
    //
    //   1. The audio adapter references `BackendAudio.decodeAudio` /
    //      `uploadSound` / `unloadSound`. Concrete audio backends
    //      (raylib-audio, sokol-audio, …) only implement those once
    //      they opt in. Emitting the adapter unconditionally would
    //      break compilation against backends that haven't.
    //
    //   2. The font adapter references `BackendGfx.FontAtlas` /
    //      `decodeFont` / `uploadFontAtlas` / `unloadFontAtlas` at
    //      *comptime* — the slot-table type is resolved at struct
    //      declaration, outside any `@hasDecl`-guarded function body
    //      (Bugbot + Gemini caught this on #103/#105). A project that
    //      doesn't declare font resources must never see those
    //      references in generated code.
    //
    // Gating on `ResourceDef.kind()` makes the adapter conditional on
    // the project actually needing it — which is the correct
    // semantics anyway. A project with audio resources targeting a
    // backend without audio support gets a clean compile error
    // pointing at `BackendAudio.decodeAudio`; same for fonts. Closes
    // labelle-assembler#104.
    var has_audio = false;
    var has_font = false;
    for (cfg.resources) |res| {
        switch (res.kind()) {
            .sound => has_audio = true,
            .font => has_font = true,
            else => {},
        }
    }
    if (has_audio) try writeAudioBackendWiring(w, "    ");
    if (has_font) try writeFontBackendWiring(w, "    ");

    // ScriptRunner owns all per-script state + shared context
    try w.writeAll("    var runner = Runner.init(allocator, &g.active_world.ecs_backend);\n");
    try w.writeAll("    defer runner.deinit();\n\n");

    // Load (or register) embedded atlas resources. Lazy resources
    // call `registerAtlasFromMemory` (parses JSON eagerly, defers PNG
    // decode) so a script can decode them on demand. See
    // `buildCallbackInitCode` for the matching code path that the
    // sokol/wasm callback backends use.
    if (cfg.resources.len > 0) {
        try w.writeAll("    // Load embedded assets (atlases, sounds, fonts via @embedFile)\n");
        for (cfg.resources) |res| {
            // `lazy = null` means the default-inference pass hasn't run
            // (e.g. a direct test call into `generateMainZigFromTemplate`).
            // `emitResourceLoad` treats null as EAGER so unmigrated-project
            // code paths match the back-compat rule in
            // `lazy_inference.resolveLazyDefaults` — a defaulted +
            // unreferenced resource stays eager so legacy projects keep
            // decoding their atlases at startup.
            try emitResourceLoad(w, res, .try_style);
        }
        try w.writeByte('\n');
    }

    // Pre-load embedded prefabs (must happen before scene loading)
    if (prefab_names.len > 0) {
        try w.writeAll("    // Embedded prefabs (via @embedFile)\n");
        for (prefab_names) |name| {
            const display = std.fs.path.basename(name);
            try w.print("    try JsoncBridge.addEmbeddedPrefab(&g, \"{s}\", @embedFile(\"prefabs/{s}.jsonc\"), \"prefabs\");\n", .{ display, name });
        }
        try w.writeByte('\n');
    }

    // Register JSONC scenes
    if (jsonc_scene_names.len > 0) {
        try w.writeAll("    // JSONC scenes\n");
        var jsonc_ident_buf: [256]u8 = undefined;
        for (jsonc_scene_names) |name| {
            const ident = pathToIdent(name, &jsonc_ident_buf);
            try w.print("    g.registerSceneSimple(\"{s}\", jsonc_{s}_loader);\n", .{ name, ident });
        }

        // Embed every scene's JSONC source under its include-relative
        // path so `"include": [...]` directives resolve against memory
        // instead of `std.fs.cwd().openFile(...)`. Desktop works either
        // way (cwd is the project root), but WASM and Android have no
        // project directory in the working dir, so a scene that
        // includes another fragment would FileNotFound at runtime
        // without this — see labelle-toolkit/labelle-cli#200.
        for (jsonc_scene_names) |name| {
            try w.print("    try g.addEmbeddedSceneSource(\"scenes/{s}.jsonc\", @embedFile(\"scenes/{s}.jsonc\"));\n", .{ name, name });
        }

        // Attach parsed asset manifests (Asset Streaming RFC #437 /
        // labelle-engine#445). The comptime `SceneAssetManifests` struct is
        // emitted into this file by `writeSceneAssetManifests` — each
        // `entries[i]` pairs the original scene name with the slice declared
        // in its .jsonc `"assets": [...]` block. Scenes without a manifest
        // get an empty slice, which is the legacy default, so this is a
        // no-op for back-compat scenes. The setter only fails on
        // SceneNotFound, which shouldn't happen here because the preceding
        // loop registered every name in the list — propagate via `try` so
        // any mismatch (e.g. an assembler/engine version skew) surfaces
        // loudly instead of being silently swallowed.
        try w.writeAll("    inline for (SceneAssetManifests.entries) |scene_asset_entry| {\n");
        try w.writeAll("        try g.setSceneAssets(scene_asset_entry.name, scene_asset_entry.assets);\n");
        try w.writeAll("    }\n");

        // Attach declared `initial_state` from each scene's .jsonc
        // (labelle-engine#500). Same setter pattern as setSceneAssets;
        // the engine's setScene calls setState(initial_state) after the
        // scene loads, so a scene can opt into running in a specific
        // game state without external coordination. Scenes that didn't
        // declare one are absent from this manifest, so this is a
        // no-op for back-compat scenes.
        try w.writeAll("    inline for (SceneInitialStateManifests.entries) |scene_state_entry| {\n");
        try w.writeAll("        try g.setSceneInitialState(scene_state_entry.name, scene_state_entry.initial_state);\n");
        try w.writeAll("    }\n");

        // Set the project's default initial state BEFORE setScene so
        // setScene (which may override via the scene's initial_state)
        // sees a stable baseline. Order matters: scene preference wins
        // over the project default, which is the whole point of #500.
        if (cfg.states.len > 0) {
            try w.print("    g.setState(\"{s}\");\n", .{cfg.states[0]});
        }

        const initial = cfg.initial_scene orelse jsonc_scene_names[0];
        try w.print("    try g.setScene(\"{s}\");\n", .{initial});
        try w.writeByte('\n');
    }

    try w.writeAll("    runner.setup(&g);\n");

    if (cfg.plugins.len > 0) {
        try w.writeAll("    PluginSystems.setup(&g);\n");
        try w.writeAll("    defer PluginSystems.deinit();\n");
        // Plugin controllers: setup on scene load, deinit on scene unload.
        // RFC-plugin-controllers §2 — auto-wired for plugins exporting
        // `pub const Controller = struct { setup, deinit, ... }`.
        // Runs after PluginSystems.setup so controllers can depend on
        // registered systems. `defer` mirrors PluginSystems.deinit ordering.
        try w.writeAll("    try PluginControllers.setup(&g);\n");
        try w.writeAll("    defer PluginControllers.deinit(&g);\n");
    }

    var arr_list = alloc_writer.toArrayList();
    return arr_list.toOwnedSlice(allocator);
}

// ============================================================
// Preview-mode codegen (PIE Phase 1, labelle-assembler#94)
// ============================================================
//
// Emit the `--preview-mode <host:port>` argv parser + `engine.Preview`
// lifecycle into every generated `main.zig`. The engine ships the
// primitives in `labelle-engine/src/preview_mode.zig` (re-exported via
// `engine.parsePreviewArgs` / `engine.Preview`) — this is the
// assembler's job of actually calling them at the right places.
//
// Loop backends (raylib desktop, sdl, bgfx, wgpu) get a single
// in-function block before the main loop plus a heartbeat call inside
// the loop body. Callback backends (sokol, raylib wasm) hoist
// `_preview` to module scope so `init` can connect, `frame` can
// heartbeat, and `cleanup` can sendBye + deinit cleanly.
//
// All snippets are emit-always: when `--preview-mode` is absent the
// runtime parse returns null and the rest of the block compiles down
// to a no-op `if (null) ...`. Keeping it unconditional avoids a
// project.labelle opt-in flag and matches the umbrella's "every
// generated binary speaks preview" intent (labelle-gui#59).

// PID is purely informational in the `hello` message — the editor
// uses it for UI display, not for any process management. Earlier
// snippets tried a per-OS comptime branch (`std.posix.getpid()` on
// POSIX, kernel32 on Windows) but `std.posix.getpid` isn't exposed
// in Zig 0.15.2's stdlib (only `std.os.linux.getpid` and
// `std.c.getpid` exist, and the latter requires linking libc which
// not every backend does). Simplest portable fix: send 0. A
// follow-up can wire the real PID once we settle on a stdlib import
// that's universal across our backends.

/// Workaround for Zig 0.16.0 wasm32-emscripten compile failure
/// (labelle-assembler#141). The default panic handler in 0.16.0
/// transitively imports `std.Io.Threaded`, whose posix wrappers fail
/// to type-check against emscripten's signal-enum shape
/// (`std/Io/Threaded.zig:15315` / `std/os/emscripten.zig:215`).
/// Overriding both `std_options_debug_io` and `panic` at the root
/// source keeps the default panic-handler chain from instantiating
/// `std.Io.Threaded`. This is the workaround recommended on the
/// Ziggit forum thread linked below and lands the documented fix
/// inside the generated `main.zig`.
///
/// Fixed upstream on Zig master by PR #31850 (lands in 0.17.0-dev);
/// drop this once labelle-toolkit moves off 0.16.x.
///
/// NOTE: this only neutralises the *implicit* path from the panic
/// handler. The generated preview-mode block (PREVIEW_INIT_CALLBACK)
/// still calls `std.Io.Threaded.init(...).io()` directly, which
/// re-instantiates the offending type. Skipping that on wasm is a
/// separate follow-up (the preview env-var is never set in a browser
/// context anyway).
///
/// References:
///   https://ziggit.dev/t/0-16-0-wasm32-emscripten-fails-to-build-because-of-default-panic-handler-recommended-workaround/15052
///   PR #31850 (Zig upstream)
///
/// Emitted only when `cfg.platform == .wasm`; lands near the top of
/// the generated `main.zig` so the two `pub const` decls are at
/// module root (Zig looks up these override names there).
const WASM_PANIC_WORKAROUND =
    \\
    \\// Zig 0.16.0 wasm32-emscripten: override the default panic handler to
    \\// avoid std.Io.Threaded import (which has broken posix wrappers on
    \\// emscripten). Fixed upstream in 0.17.0-dev (PR #31850); remove this
    \\// once labelle-toolkit moves off 0.16.
    \\// https://ziggit.dev/t/0-16-0-wasm32-emscripten-fails-to-build-because-of-default-panic-handler-recommended-workaround/15052
    \\pub const std_options_debug_io = std.Io.failing;
    \\pub const panic = std.debug.no_panic;
    \\
;

/// Module-scope helpers the preview blocks rely on. `getenv` and
/// `clock_gettime` are at module scope because `extern "c" fn`
/// must be; both names are unique within the generated main.zig.
/// `_preview_now_ms` is a tiny libc clock_gettime wrapper that
/// stands in for the now-removed `std.time.milliTimestamp`.
const PREVIEW_HELPERS =
    \\
    \\const _PreviewTimespec = extern struct { sec: isize, nsec: isize };
    \\const _preview_getenv = @extern(
    \\    *const fn (name: [*:0]const u8) callconv(.c) ?[*:0]const u8,
    \\    .{ .name = "getenv" },
    \\);
    \\const _preview_clock_gettime = @extern(
    \\    *const fn (clk_id: c_int, tp: *_PreviewTimespec) callconv(.c) c_int,
    \\    .{ .name = "clock_gettime" },
    \\);
    \\fn _preview_now_ms() u64 {
    \\    const CLOCK_MONOTONIC: c_int = if (@import("builtin").os.tag == .macos) 6 else 1;
    \\    var ts: _PreviewTimespec = undefined;
    \\    _ = _preview_clock_gettime(CLOCK_MONOTONIC, &ts);
    \\    return @intCast(@as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000));
    \\}
    \\
;

/// Raw GL externs + constants needed for the raylib desktop PBO-based
/// async readback path. Raylib links the platform's OpenGL loader on
/// desktop (CGL / GLX / WGL), so PBO entry points are present as
/// regular `extern "c"` symbols — `@extern` here resolves them at link
/// time without any extra dependency.
///
/// Concatenated into `module_vars` for raylib-desktop only. Other
/// loop backends (sdl/bgfx/wgpu) don't use these and don't ship them
/// (their readback story is a separate ticket). The constants are GL
/// 2.1 / 3.3 core values — stable across drivers and platforms.
const PREVIEW_READBACK_HELPERS =
    \\
    \\// ── Preview readback bridges (labelle-assembler#140) ──
    \\// All GL state + PBO ring + per-frame readback machinery now
    \\// lives in `backends/raylib/src/window.zig:preview_pbo`. The
    \\// codegen owns only these tiny bridge fns that wrap
    \\// `engine.Preview` methods behind an `*anyopaque` boundary so
    \\// the backend module doesn't need an engine type-import.
    \\fn _preview_pbo_begin_bridge(ctx: *anyopaque, w: u32, h: u32) anyerror!void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    return p.beginFrameStream(w, h);
    \\}
    \\fn _preview_pbo_publish_bridge(ctx: *anyopaque, pixels: []const u8) anyerror!void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    return p.publishFrame(pixels);
    \\}
    \\fn _preview_pbo_end_bridge(ctx: *anyopaque) void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    p.endFrameStream();
    \\}
    \\fn _preview_pbo_begin_ios_bridge(ctx: *anyopaque, w: u32, h: u32) anyerror!void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    return p.beginFrameStreamIOSurface(w, h);
    \\}
    \\fn _preview_pbo_publish_ios_bridge(ctx: *anyopaque, pixels: []const u8) anyerror!void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    return p.publishFrameIOSurface(pixels);
    \\}
    \\fn _preview_pbo_end_ios_bridge(ctx: *anyopaque) void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    p.endFrameStreamIOSurface();
    \\}
    \\fn _preview_pbo_accepted_bridge(ctx: *anyopaque) bool {
    \\    const p: *const engine.Preview = @ptrCast(@alignCast(ctx));
    \\    return p.isFrameAccepted();
    \\}
    \\
;

/// In-function preview setup for loop-style main()s. Parses argv,
/// dials the editor, assigns directly into `g.preview`, sends `hello`.
/// Pasted AFTER `var g = AssembledGame.init(...)` so the engine's
/// ECS lifecycle (createEntity / destroyEntity / addComponent) can
/// emit Phase 2 telemetry from the very first scene load
/// (labelle-engine#520).
///
/// Ownership note: `Game.deinit` owns the `Preview` teardown. The
/// `defer` here only emits the graceful `bye` frame; the socket
/// close + arena deinit run inside `g.deinit()` (registered earlier
/// in the same scope, so LIFO runs `sendBye` first, then `g.deinit`).
const PREVIEW_LOOP_SETUP =
    \\    // ── Preview mode (labelle-assembler#94, labelle-engine#520) ──
    \\    // Connect to the editor's TCP listener when `LABELLE_PREVIEW=host:port`
    \\    // is set in the environment. (Zig 0.16 removed `std.process.argsAlloc`
    \\    // and the easy path to argv without changing `pub fn main()`'s
    \\    // signature, so the env-var hand-off is the smallest restoration.)
    \\    if (_preview_getenv("LABELLE_PREVIEW")) |_env_z| {
    \\        const _host_port = std.mem.span(_env_z);
    \\        if (_host_port.len > 0) {
    \\            var _preview_threaded = std.Io.Threaded.init(allocator, .{});
    \\            defer _preview_threaded.deinit();
    \\            g.preview = engine.Preview.connect(_preview_threaded.io(), allocator, _host_port) catch |err| blk: {
    \\                std.debug.print("labelle: preview-mode connect to '{s}' failed: {s}\n", .{ _host_port, @errorName(err) });
    \\                break :blk null;
    \\            };
    \\            if (g.preview) |*_p| _p.sendHello("labelle-engine", 0) catch {};
    \\        }
    \\    }
    \\    defer if (g.preview) |*_p| {
    \\        _p.sendBye(.normal) catch {};
    \\    };
    \\
;

/// Raylib-desktop-only addendum to `PREVIEW_LOOP_SETUP`. Declares the
/// PBO ring + CPU staging buffer locals that `PREVIEW_READBACK_LOOP`
/// uses, and registers the deferred GL/SHM teardown. Pasted right
/// after `PREVIEW_LOOP_SETUP` so both run inside `main()`'s scope and
/// `g` is already bound.
///
/// The `endFrameStream` defer lives here (not in `PREVIEW_LOOP_SETUP`)
/// because only the readback path actually opens the SHM ring. Other
/// loop backends never call `beginFrameStream`, so calling
/// `endFrameStream` would be a no-op but the symbol `_gl_delete_buffers`
/// in the same defer block isn't available to them — splitting keeps
/// the non-raylib loop backends compiling unchanged.
///
/// macOS path (labelle-assembler#121, labelle-engine#547): when the
/// generated game is built for macOS, the engine exposes a zero-copy
/// IOSurface variant of the same lifecycle triple
/// (`beginFrameStreamIOSurface` / `publishFrameIOSurface` /
/// `endFrameStreamIOSurface`). The teardown defer here picks the
/// matching `end*` at comptime so the right side is closed.
const PREVIEW_READBACK_SETUP =
    \\    // labelle-assembler#140 — preview readback is now
    \\    // backend-internal. Wire engine.Preview methods into the
    \\    // backend vtable + register cleanup. The bridges below
    \\    // are emitted at module scope by PREVIEW_READBACK_HELPERS.
    \\    if (g.preview) |*_p| {
    \\        window.preview_pbo.attach(.{
    \\            .ctx = @ptrCast(_p),
    \\            .beginFrameStream = _preview_pbo_begin_bridge,
    \\            .publishFrame = _preview_pbo_publish_bridge,
    \\            .endFrameStream = _preview_pbo_end_bridge,
    \\            .beginFrameStreamIOSurface = _preview_pbo_begin_ios_bridge,
    \\            .publishFrameIOSurface = _preview_pbo_publish_ios_bridge,
    \\            .endFrameStreamIOSurface = _preview_pbo_end_ios_bridge,
    \\            .isFrameAccepted = _preview_pbo_accepted_bridge,
    \\        }, allocator);
    \\    }
    \\    defer window.preview_pbo.deinit();
    \\
;

/// Heartbeat tick — rate-limited inside `tickHeartbeat`. Safe to
/// call every frame; ~4 Hz on the wire regardless of FPS.
///
/// `pollSubscription` runs first so a malformed subscribe frame
/// doesn't poison the same flush as the heartbeat write. It's
/// non-blocking (peeks the socket via `EAGAIN`) and drains any
/// `subscribe` / `unsubscribe` JSON lines the editor sent since
/// the last tick — without it the engine never reads the
/// `subscribed_components` set that gates `component_changed`
/// frames (labelle-engine#520 paired with labelle-assembler#96).
const PREVIEW_HEARTBEAT_LOOP =
    \\        if (g.preview) |*_p| {
    \\            _p.pollSubscription() catch {};
    \\            _p.tickHeartbeat(_preview_now_ms()) catch {};
    \\            // Drain editor → game input events (labelle-assembler#143).
    \\            // The imgui plugin's sokol bridge exposes thin shims over
    \\            // `simgui_add_*_event`; we link weakly so projects without
    \\            // the plugin still build.
    \\            while (_p.popInputEvent()) |_ev| {
    \\                switch (_ev) {
    \\                    .mouse_pos => |_m| _preview_input_mouse_pos(_m.x, _m.y),
    \\                    .mouse_button => |_m| _preview_input_mouse_button(_m.button, _m.down),
    \\                }
    \\            }
    \\        }
    \\
;

/// Wrappers around the imgui sokol bridge's mouse-event exports.
/// Emitted only when the project's gui plugin is *imgui* specifically —
/// the `imgui_bridge_mouse_*` externs only resolve against the imgui
/// bridge. Projects with a different gui plugin (clay, simple-raylib,
/// simple-sokol, …) or no gui at all get `PREVIEW_INPUT_DISPATCH_STUB`,
/// so the `_preview_input_*` symbols still resolve in PREVIEW_HEARTBEAT_LOOP
/// (the drain just discards events).
const PREVIEW_INPUT_DISPATCH =
    \\extern fn imgui_bridge_mouse_pos(x: f32, y: f32) void;
    \\extern fn imgui_bridge_mouse_button(button: i32, down: bool) void;
    \\
    \\fn _preview_input_mouse_pos(x: f32, y: f32) void {
    \\    imgui_bridge_mouse_pos(x, y);
    \\}
    \\fn _preview_input_mouse_button(button: i32, down: bool) void {
    \\    imgui_bridge_mouse_button(button, down);
    \\}
    \\
;

const PREVIEW_INPUT_DISPATCH_STUB =
    \\fn _preview_input_mouse_pos(_: f32, _: f32) void {}
    \\fn _preview_input_mouse_button(_: i32, _: bool) void {}
    \\
;

/// PBO-based async GPU→CPU readback that runs inside the raylib desktop
/// frame loop, between `g.render*` and `window.endDrawing()`
/// (labelle-engine#544).
///
/// Translates the imgui-preview PoC's 3-deep PBO ring into the
/// generated main:
///
///   frame N   : bind pbo[N % 3] → glReadPixels (async DMA into PBO)
///   frame N+2 : bind pbo[(N-2) % 3] → glMapBuffer → memcpy to CPU
///               → Preview.publishFrame → unmap
///
/// The 2-frame priming gap is what hides the GPU→CPU stall; the first
/// two frames only kick off readback and publish nothing. From frame
/// 2 onwards we always have a mature PBO to map.
///
/// Resize handling: the screen dims are read every frame from
/// `window.getScreenWidth/Height`. When they differ from the last
/// published dims we tear the PBO ring + CPU buffer down, re-issue
/// `Preview.beginFrameStream(w,h)` (idempotent — internally re-offers
/// + frees the prior SHM ring), and reset the priming counter. The
/// editor responds with a fresh `frame_accept` and publishes resume
/// on the next pass through the priming gap.
///
/// All allocator failures + GL errors are swallowed; preview is a
/// best-effort sidecar, never a reason to crash the game.
///
/// macOS path (labelle-assembler#121, labelle-engine#547): the per-frame
/// glReadPixels + PBO ring is identical, but the engine API surface
/// switches at comptime to the zero-copy IOSurface triple
/// (`beginFrameStreamIOSurface` / `publishFrameIOSurface`). The
/// producer-side pixel buffer stays RGBA8 — `publishFrameIOSurface`
/// does the RGBA→BGRA swizzle internally during the IOSurface
/// lock/copy, so no producer-side format change is needed.
const PREVIEW_READBACK_LOOP =
    \\        if (g.preview) |*_p| {
    \\            _ = _p;
    \\            window.preview_pbo.frame();
    \\        }
    \\
;

/// Init-callback preview block. Runs once at startup, AFTER
/// `g = AssembledGame.init(...)` — `g.preview` is the canonical
/// storage; no module-level `_preview` needed.
///
/// Note: the original `catch &[_][:0]u8{}` form gave `_argv` a
/// `[]const [:0]u8` type, which doesn't satisfy `argsFree`'s
/// `[][:0]u8` parameter. The `if/else |_|` shape pulls the alloc
/// success path into its own scope where `_argv`'s type matches.
const PREVIEW_INIT_CALLBACK =
    \\    // ── Preview mode (labelle-assembler#94, labelle-engine#520) ──
    \\    // Sokol callback path: connect once in `init`, frame-callback
    \\    // pulses the heartbeat, cleanup-callback sends bye. Storage is
    \\    // `g.preview` (Game owns the lifecycle); see PREVIEW_LOOP_SETUP
    \\    // above for the env-var rationale.
    \\    if (_preview_getenv("LABELLE_PREVIEW")) |_env_z| {
    \\        const _host_port = std.mem.span(_env_z);
    \\        if (_host_port.len > 0) {
    \\            var _preview_threaded = std.Io.Threaded.init(allocator, .{});
    \\            defer _preview_threaded.deinit();
    \\            g.preview = engine.Preview.connect(_preview_threaded.io(), allocator, _host_port) catch |err| blk: {
    \\                std.debug.print("labelle: preview-mode connect to '{s}' failed: {s}\n", .{ _host_port, @errorName(err) });
    \\                break :blk null;
    \\            };
    \\            if (g.preview) |*_p| {
    \\                _p.sendHello("labelle-engine", 0) catch {};
    \\                // labelle-assembler#140 Phase B: wire the engine.Preview
    \\                // methods into the backend's preview_mtl vtable so the
    \\                // backend can drive IOSurface stream lifecycle without
    \\                // needing an engine type-import. Bridges declared at
    \\                // module scope (see PREVIEW_READBACK_HELPERS_METAL_SOKOL).
    \\                if (comptime @hasDecl(window, "preview_mtl")) {
    \\                    window.preview_mtl.attach(.{
    \\                        .ctx = @ptrCast(_p),
    \\                        .beginStream = _preview_mtl_begin_stream_bridge,
    \\                        .getSurfaceAt = _preview_mtl_get_surface_bridge,
    \\                        .signalSlotReady = _preview_mtl_signal_bridge,
    \\                        .endStream = _preview_mtl_end_stream_bridge,
    \\                        .isFrameAccepted = _preview_mtl_accepted_bridge,
    \\                    });
    \\                }
    \\                if (comptime @hasDecl(window, "hideWindow")) window.hideWindow();
    \\            }
    \\        }
    \\    }
    \\
;

/// Cleanup-callback preview teardown. Only emits the graceful `bye`
/// frame — `Game.deinit` (called by `{{cleanup_code}}` immediately
/// after) owns the actual socket + arena teardown
/// (labelle-engine#520).
const PREVIEW_CLEANUP_CALLBACK =
    \\    if (g.preview) |*_p| _p.sendBye(.normal) catch {};
    \\
;

/// Heartbeat for sokol's frame callback (one extra indent level vs.
/// the loop variant, since sokol's `frame` body sits at function scope
/// not inside a `while`).
///
/// Same poll-before-write ordering as the loop variant: drain any
/// `subscribe` / `unsubscribe` frames the editor sent BEFORE the
/// heartbeat write so a malformed subscription can't poison the
/// outbound flush. See the loop variant for the full rationale.
const PREVIEW_HEARTBEAT_CALLBACK =
    \\    if (g.preview) |*_p| {
    \\        _p.pollSubscription() catch {};
    \\        _p.tickHeartbeat(_preview_now_ms()) catch {};
    \\        while (_p.popInputEvent()) |_ev| {
    \\            switch (_ev) {
    \\                .mouse_pos => |_m| _preview_input_mouse_pos(_m.x, _m.y),
    \\                .mouse_button => |_m| _preview_input_mouse_button(_m.button, _m.down),
    \\            }
    \\        }
    \\    }
    \\
;

/// Sokol-specific PBO readback (labelle-assembler#122 slice 1). Same
/// 3-deep PBO ring + 2-frame priming as raylib's `PREVIEW_READBACK_*`
/// (labelle-engine#544), reshaped for sokol's callback lifecycle:
///
///   - State (PBO ids, frame counter, last published dims, CPU staging
///     buffer) lives at *module scope* because the sokol `init` /
///     `frame` / `cleanup` callbacks have no shared local scope.
///   - GL externs are gated by `_sokol_preview_gl_enabled`, a comptime
///     boolean derived from `builtin.os.tag`. Default sokol build picks
///     GLCORE on Linux + GLES3 on Android/web, Metal on macOS/iOS,
///     D3D11 on Windows. Slice 1 only handles the GL paths; Metal /
///     D3D11 are deferred to slices 2 and 3 (#122 follow-ups). The
///     externs hide behind a struct-namespace so non-GL builds never
///     reference unresolved symbols at link time.
///   - The frame block + init seed + cleanup teardown are also gated
///     on the comptime flag — `comptime if (... ) { ... }` elides the
///     entire block on Metal/D3D11 targets, leaving the control-plane
///     wiring (hello/heartbeat/bye) intact but no pixel publish.
const PREVIEW_READBACK_HELPERS_SOKOL =
    \\
    \\// ── Sokol PBO readback gating (labelle-assembler#122 slice 1) ──
    \\// Default sokol-zig picks GLCORE on Linux desktop, GLES3 on Android
    \\// and emscripten, Metal on Darwin, D3D11 on Windows. The GL PBO
    \\// path only applies to the first two; Metal / D3D11 are separate
    \\// slices (IOSurface, staging). Comptime-gating on builtin.os.tag
    \\// keeps the GL externs out of non-GL link lines so e.g. a sokol
    \\// macOS build (Metal) doesn't fail to resolve `glReadPixels`.
    \\// Android in Zig is `os.tag == .linux` with `abi == .android` /
    \\// `.androideabi`, so the simple `.linux` arm already covers both
    \\// desktop GLCORE and Android GLES3. Emscripten / wasm32 is left
    \\// as a no-op for now — WebGL2 has limited PBO support and slice 1
    \\// doesn't ship a wasm story (see PR body / #122 follow-ups).
    \\const _sokol_preview_gl_enabled: bool = switch (@import("builtin").os.tag) {
    \\    .linux => true,
    \\    else => false,
    \\};
    \\
    \\// PBO state at module scope — sokol's init / frame / cleanup
    \\// callbacks are separate functions, so the locals raylib's main()
    \\// uses for the same purpose need to live at file scope here.
    \\// `_preview_allocator` mirrors the allocator the game uses; it's
    \\// stashed in the init callback so frame + cleanup can reach the
    \\// CPU staging buffer without re-deriving it from `g`.
    \\var _preview_allocator: std.mem.Allocator = std.mem.Allocator{ .ptr = undefined, .vtable = undefined };
    \\var _preview_pbos: [3]c_uint = .{ 0, 0, 0 };
    \\var _preview_pbo_bytes: usize = 0;
    \\var _preview_pbo_initialized: bool = false;
    \\var _preview_frame_idx: u64 = 0;
    \\var _preview_last_w: u32 = 0;
    \\var _preview_last_h: u32 = 0;
    \\var _preview_pixel_buf: []u8 = &[_]u8{};
    \\
    \\// GL extern decls live inside a struct-namespace gated on
    \\// `_sokol_preview_gl_enabled`. The `else struct {}` branch holds
    \\// no symbols, so a Metal / D3D11 sokol build never emits an
    \\// undefined-symbol reference to `glReadPixels` etc.
    \\const _SokolPreviewGl = if (_sokol_preview_gl_enabled) struct {
    \\    pub const PIXEL_PACK_BUFFER: c_uint = 0x88EB;
    \\    pub const STREAM_READ: c_uint = 0x88E1;
    \\    // GL_MAP_READ_BIT — bit-flag for glMapBufferRange's access.
    \\    // Core in GL 3.0+ AND GLES 3.0+; glMapBuffer is desktop-only
    \\    // and ships on GLES only as `GL_OES_mapbuffer`, so the range
    \\    // variant is the portable choice for Android GLES3 builds.
    \\    pub const MAP_READ_BIT: c_uint = 0x0001;
    \\    pub const PACK_ALIGNMENT: c_uint = 0x0D05;
    \\    pub const RGBA: c_uint = 0x1908;
    \\    pub const UNSIGNED_BYTE: c_uint = 0x1401;
    \\    pub const pixelStorei = @extern(
    \\        *const fn (pname: c_uint, param: c_int) callconv(.c) void,
    \\        .{ .name = "glPixelStorei" },
    \\    );
    \\    pub const genBuffers = @extern(
    \\        *const fn (n: c_int, buffers: [*]c_uint) callconv(.c) void,
    \\        .{ .name = "glGenBuffers" },
    \\    );
    \\    pub const deleteBuffers = @extern(
    \\        *const fn (n: c_int, buffers: [*]const c_uint) callconv(.c) void,
    \\        .{ .name = "glDeleteBuffers" },
    \\    );
    \\    pub const bindBuffer = @extern(
    \\        *const fn (target: c_uint, buffer: c_uint) callconv(.c) void,
    \\        .{ .name = "glBindBuffer" },
    \\    );
    \\    pub const bufferData = @extern(
    \\        *const fn (target: c_uint, size: isize, data: ?*const anyopaque, usage: c_uint) callconv(.c) void,
    \\        .{ .name = "glBufferData" },
    \\    );
    \\    pub const readPixels = @extern(
    \\        *const fn (x: c_int, y: c_int, w: c_int, h: c_int, fmt: c_uint, ty: c_uint, data: ?*anyopaque) callconv(.c) void,
    \\        .{ .name = "glReadPixels" },
    \\    );
    \\    pub const mapBufferRange = @extern(
    \\        *const fn (target: c_uint, offset: isize, length: isize, access: c_uint) callconv(.c) ?*anyopaque,
    \\        .{ .name = "glMapBufferRange" },
    \\    );
    \\    pub const unmapBuffer = @extern(
    \\        *const fn (target: c_uint) callconv(.c) u8,
    \\        .{ .name = "glUnmapBuffer" },
    \\    );
    \\} else struct {};
    \\
;

/// Init-callback addendum that stashes the game's allocator into the
/// module-scope `_preview_allocator` so the frame + cleanup callbacks
/// can grow / free the CPU staging buffer without reaching back through
/// `g`. Gated on `_sokol_preview_gl_enabled` for symmetry with the
/// other blocks — on non-GL targets the allocator slot stays at its
/// undefined sentinel but nothing ever calls through it.
const PREVIEW_READBACK_INIT_SOKOL =
    \\    if (comptime _sokol_preview_gl_enabled) {
    \\        _preview_allocator = allocator;
    \\    }
    \\
;

/// Per-frame PBO readback for sokol's `frame` callback. Comptime-gated
/// on `_sokol_preview_gl_enabled` — the entire block evaporates on
/// Metal / D3D11 builds, leaving only the heartbeat path intact.
///
/// Algorithm mirrors raylib's `PREVIEW_READBACK_LOOP` (#120):
///   - read current screen dims via `window.width()` / `window.height()`
///   - on resize / first frame, (re)negotiate the SHM ring with the
///     editor + (re)size the PBOs + CPU buffer + reset the priming
///     counter
///   - issue glReadPixels into `pbo[N % 3]` (async DMA)
///   - from frame 2 onwards, glMapBuffer `pbo[(N-2) % 3]` + memcpy
///     into the CPU buffer with bottom-up → top-down row flip, then
///     `publishFrame`
///
/// The flush ordering is the catch: sokol's `window.endFrame()` calls
/// `sg.endPass(); sg.commit();`. We inject the readback BEFORE
/// `window.endFrame()` so glReadPixels still hits the swapchain
/// framebuffer (FBO 0 / GL_BACK) before the swap. Same shape as
/// raylib's pre-`endDrawing()` placement.
const PREVIEW_READBACK_FRAME_SOKOL =
    \\        if (comptime _sokol_preview_gl_enabled) {
    \\            if (g.preview) |*_p| _readback: {
    \\                const _sw_i = window.width();
    \\                const _sh_i = window.height();
    \\                if (_sw_i <= 0 or _sh_i <= 0) break :_readback;
    \\                const _sw: u32 = @intCast(_sw_i);
    \\                const _sh: u32 = @intCast(_sh_i);
    \\                const _needed_bytes: usize = @as(usize, _sw) * @as(usize, _sh) * 4;
    \\
    \\                if (_sw != _preview_last_w or _sh != _preview_last_h) {
    \\                    _p.beginFrameStream(_sw, _sh) catch break :_readback;
    \\                    if (!_preview_pbo_initialized) {
    \\                        _SokolPreviewGl.genBuffers(3, &_preview_pbos);
    \\                        _preview_pbo_initialized = true;
    \\                    }
    \\                    _SokolPreviewGl.pixelStorei(_SokolPreviewGl.PACK_ALIGNMENT, 4);
    \\                    for (_preview_pbos) |_pbo_id| {
    \\                        _SokolPreviewGl.bindBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER, _pbo_id);
    \\                        _SokolPreviewGl.bufferData(_SokolPreviewGl.PIXEL_PACK_BUFFER, @intCast(_needed_bytes), null, _SokolPreviewGl.STREAM_READ);
    \\                    }
    \\                    _SokolPreviewGl.bindBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER, 0);
    \\                    _preview_pbo_bytes = _needed_bytes;
    \\                    if (_preview_pixel_buf.len != _needed_bytes) {
    \\                        if (_preview_pixel_buf.len != 0) _preview_allocator.free(_preview_pixel_buf);
    \\                        _preview_pixel_buf = _preview_allocator.alloc(u8, _needed_bytes) catch &[_]u8{};
    \\                    }
    \\                    // Only commit the new dims once the CPU buffer
    \\                    // is the right size — otherwise a transient
    \\                    // alloc failure would leave us with `last_w/h`
    \\                    // matching the screen, skipping the resize block
    \\                    // on every subsequent frame and stranding the
    \\                    // readback in a permanent break state.
    \\                    if (_preview_pixel_buf.len == _needed_bytes) {
    \\                        _preview_last_w = _sw;
    \\                        _preview_last_h = _sh;
    \\                        _preview_frame_idx = 0;
    \\                    }
    \\                }
    \\
    \\                if (!_p.isFrameAccepted() or _preview_pixel_buf.len != _needed_bytes) break :_readback;
    \\
    \\                const _write_idx: usize = @intCast(_preview_frame_idx % 3);
    \\                _SokolPreviewGl.bindBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER, _preview_pbos[_write_idx]);
    \\                _SokolPreviewGl.readPixels(0, 0, _sw_i, _sh_i, _SokolPreviewGl.RGBA, _SokolPreviewGl.UNSIGNED_BYTE, null);
    \\
    \\                if (_preview_frame_idx >= 2) {
    \\                    const _read_idx: usize = @intCast((_preview_frame_idx - 2) % 3);
    \\                    _SokolPreviewGl.bindBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER, _preview_pbos[_read_idx]);
    \\                    const _mapped = _SokolPreviewGl.mapBufferRange(
    \\                        _SokolPreviewGl.PIXEL_PACK_BUFFER,
    \\                        0,
    \\                        @intCast(_preview_pbo_bytes),
    \\                        _SokolPreviewGl.MAP_READ_BIT,
    \\                    );
    \\                    if (_mapped) |_src| {
    \\                        const _src_ptr: [*]const u8 = @ptrCast(_src);
    \\                        const _row_bytes: usize = @as(usize, _sw) * 4;
    \\                        var _y: u32 = 0;
    \\                        while (_y < _sh) : (_y += 1) {
    \\                            const _src_row = _src_ptr + (@as(usize, _sh - 1 - _y) * _row_bytes);
    \\                            const _dst_row = _preview_pixel_buf.ptr + (@as(usize, _y) * _row_bytes);
    \\                            @memcpy(_dst_row[0.._row_bytes], _src_row[0.._row_bytes]);
    \\                        }
    \\                        // glUnmapBuffer returns GL_FALSE (0) if the
    \\                        // buffer contents became corrupt during the
    \\                        // map (e.g. context loss, screen-resolution
    \\                        // change racing with the readback). In that
    \\                        // case our memcpy above read garbage —
    \\                        // skip publishFrame so the editor doesn't
    \\                        // display a torn frame.
    \\                        if (_SokolPreviewGl.unmapBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER) != 0) {
    \\                            _p.publishFrame(_preview_pixel_buf) catch {};
    \\                        }
    \\                    }
    \\                }
    \\                _SokolPreviewGl.bindBuffer(_SokolPreviewGl.PIXEL_PACK_BUFFER, 0);
    \\                _preview_frame_idx +%= 1;
    \\            }
    \\        }
    \\
;

/// Cleanup-callback teardown for the sokol PBO ring. Runs BEFORE
/// `PREVIEW_CLEANUP_CALLBACK` (which sends the graceful `bye`) so the
/// engine still has its socket open when the producer tears down the
/// SHM ring — matches raylib's LIFO ordering. Gated on the same
/// `_sokol_preview_gl_enabled` flag; on non-GL builds the PBO state
/// is never initialized so there's nothing to free either.
const PREVIEW_READBACK_CLEANUP_SOKOL =
    \\    if (comptime _sokol_preview_gl_enabled) {
    \\        if (g.preview) |*_p| _p.endFrameStream();
    \\        if (_preview_pbo_initialized) _SokolPreviewGl.deleteBuffers(3, &_preview_pbos);
    \\        if (_preview_pixel_buf.len != 0) _preview_allocator.free(_preview_pixel_buf);
    \\    }
    \\
;

/// Sokol D3D11 staging-texture readback helpers (labelle-assembler#126,
/// slice 2 of #122). Mirrors the structure of the GL block above but
/// targets default sokol-on-Windows builds, which use D3D11 instead of
/// GL. Windows has no IOSurface equivalent that crosses processes
/// cheaply, so the path is CPU-side `CopyResource` + `Map` + memcpy
/// into the SHM ring (same protocol the GL path uses via
/// `Preview.beginFrameStream` / `publishFrame`).
///
/// Sokol back-buffer access:
///   - `sg_d3d11_device()`         → `ID3D11Device*` (public sokol-gfx API)
///   - `sg_d3d11_device_context()` → `ID3D11DeviceContext*` (public)
///   - `sapp_d3d11_get_swap_chain()` → `IDXGISwapChain*` (public sokol-app API)
///   - `IDXGISwapChain::GetBuffer(0, IID_ID3D11Texture2D, &bb)` via COM
///     vtable dispatch → the resolved back-buffer `ID3D11Texture2D*`.
///
/// The COM vtable indices used here (`Map`=14, `Unmap`=15,
/// `CopyResource`=47 on `ID3D11DeviceContext`; `GetBuffer`=9 on
/// `IDXGISwapChain`; `CreateTexture2D`=5 on `ID3D11Device`;
/// `Release`=2 on every interface) are stable across the D3D11 ABI
/// since D3D11 shipped in 2009 — this is the same dispatch shape
/// every Windows graphics driver uses internally.
///
/// Format note: DXGI swapchains created by sokol default to
/// `DXGI_FORMAT_B8G8R8A8_UNORM` (BGRA8). The SHM consumer expects
/// RGBA8 (matching the GL `glReadPixels(GL_RGBA, ...)` shape), so the
/// memcpy below swizzles BGRA→RGBA per pixel. A future variant of the
/// SHM protocol that carries the source pixel format could skip the
/// swizzle and let the consumer handle channel order — out of scope
/// for this slice. DXGI back buffers are top-down (row 0 = top), so
/// no row flip is needed (unlike the GL path, where `glReadPixels`
/// returns rows bottom-up).
const PREVIEW_READBACK_HELPERS_SOKOL_D3D11 =
    \\
    \\// ── Sokol D3D11 readback gating (labelle-assembler#126) ──
    \\// Default sokol-zig picks D3D11 on Windows desktop. The staging-
    \\// texture readback path only applies there; on Linux/Android sokol
    \\// runs GLCORE/GLES3 (the block above), and on Darwin sokol runs
    \\// Metal (slice 3, #125). The `comptime`-gated externs and the
    \\// `struct {}` else branch keep the D3D11 entry points off the
    \\// link line for non-Windows targets.
    \\const _sokol_preview_d3d11_enabled: bool = @import("builtin").os.tag == .windows;
    \\
    \\// Staging-texture ring + book-keeping at module scope (same
    \\// rationale as the GL block — sokol's `init` / `frame` / `cleanup`
    \\// callbacks have no shared local stack frame).
    \\//
    \\// `_preview_d3d11_staging` holds 3 `ID3D11Texture2D*` (opaque)
    \\// allocated on the first frame / on resize; the publish loop
    \\// `CopyResource`s the back-buffer into slot `N % 3` and `Map`s
    \\// slot `(N-2) % 3` — same 3-deep ring + 2-frame priming gap as
    \\// the GL PBO path keeps DMA / GPU stalls out of the frame loop.
    \\var _preview_d3d11_staging: [3]?*anyopaque = .{ null, null, null };
    \\var _preview_d3d11_initialized: bool = false;
    \\
    \\// COM dispatch helpers. D3D11 / DXGI interfaces are layouts where
    \\// the first field is a pointer to a function-pointer vtable. We
    \\// only need a handful of methods, all at well-known stable
    \\// indices (see helpers doc-comment above). The IID below is
    \\// `IID_ID3D11Texture2D` — `{6F15AAF2-D208-4E89-9AB4-489535D34F9C}`
    \\// in little-endian DWORD/WORD byte order.
    \\const _SokolPreviewD3d11 = if (_sokol_preview_d3d11_enabled) struct {
    \\    // D3D11_USAGE_STAGING = 3; CPU_ACCESS_READ = 0x20000.
    \\    // D3D11_MAP_READ = 1; DXGI_FORMAT_B8G8R8A8_UNORM = 87.
    \\    pub const USAGE_STAGING: c_uint = 3;
    \\    pub const CPU_ACCESS_READ: c_uint = 0x20000;
    \\    pub const MAP_READ: c_uint = 1;
    \\    pub const FORMAT_B8G8R8A8_UNORM: c_uint = 87;
    \\
    \\    // `_Guid` mirrors Windows `GUID` / `IID` — 16 bytes, mixed
    \\    // endianness in the binary form. Hand-coded byte sequence
    \\    // avoids dragging in Win32 headers from the generated code.
    \\    pub const _Guid = extern struct {
    \\        data1: u32,
    \\        data2: u16,
    \\        data3: u16,
    \\        data4: [8]u8,
    \\    };
    \\    pub const IID_ID3D11Texture2D: _Guid = .{
    \\        .data1 = 0x6F15AAF2,
    \\        .data2 = 0xD208,
    \\        .data3 = 0x4E89,
    \\        .data4 = .{ 0x9A, 0xB4, 0x48, 0x95, 0x35, 0xD3, 0x4F, 0x9C },
    \\    };
    \\
    \\    // Mapped subresource layout — matches D3D11_MAPPED_SUBRESOURCE.
    \\    pub const MappedSubresource = extern struct {
    \\        data: ?*anyopaque,
    \\        row_pitch: u32,
    \\        depth_pitch: u32,
    \\    };
    \\
    \\    // D3D11_TEXTURE2D_DESC. SampleDesc is `{count, quality}`.
    \\    pub const Texture2DDesc = extern struct {
    \\        width: u32,
    \\        height: u32,
    \\        mip_levels: u32,
    \\        array_size: u32,
    \\        format: c_uint,
    \\        sample_count: u32,
    \\        sample_quality: u32,
    \\        usage: c_uint,
    \\        bind_flags: c_uint,
    \\        cpu_access_flags: c_uint,
    \\        misc_flags: c_uint,
    \\    };
    \\
    \\    // Sokol C-symbol entry points — `sg_d3d11_device()`,
    \\    // `sg_d3d11_device_context()`, `sapp_d3d11_get_swap_chain()`
    \\    // are part of the public sokol-gfx / sokol-app API and link
    \\    // into any sokol-on-Windows build via the sokol-zig dep.
    \\    pub const sgDevice = @extern(
    \\        *const fn () callconv(.c) ?*anyopaque,
    \\        .{ .name = "sg_d3d11_device" },
    \\    );
    \\    pub const sgDeviceContext = @extern(
    \\        *const fn () callconv(.c) ?*anyopaque,
    \\        .{ .name = "sg_d3d11_device_context" },
    \\    );
    \\    pub const sappSwapChain = @extern(
    \\        *const fn () callconv(.c) ?*anyopaque,
    \\        .{ .name = "sapp_d3d11_get_swap_chain" },
    \\    );
    \\
    \\    // `Object` is a placeholder for any COM interface pointer; the
    \\    // first field is always a pointer to the vtable, which is
    \\    // itself a `[*]const *const fn () callconv(.c) i32`. We dispatch
    \\    // by indexing into that table at the documented method index.
    \\    pub const Object = extern struct { vtbl: [*]const *const anyopaque };
    \\
    \\    /// IDXGISwapChain::GetBuffer — vtable index 9.
    \\    /// Signature: HRESULT GetBuffer(UINT Buffer, REFIID riid, void** ppSurface).
    \\    pub fn swapChainGetBuffer(sc: *anyopaque, buffer: u32, riid: *const _Guid, out: *?*anyopaque) i32 {
    \\        const obj: *Object = @ptrCast(@alignCast(sc));
    \\        const fp: *const fn (*anyopaque, u32, *const _Guid, *?*anyopaque) callconv(.c) i32 = @ptrCast(obj.vtbl[9]);
    \\        return fp(sc, buffer, riid, out);
    \\    }
    \\
    \\    /// ID3D11Device::CreateTexture2D — vtable index 5.
    \\    /// Signature: HRESULT CreateTexture2D(const D3D11_TEXTURE2D_DESC*, const D3D11_SUBRESOURCE_DATA*, ID3D11Texture2D**).
    \\    pub fn deviceCreateTexture2D(dev: *anyopaque, desc: *const Texture2DDesc, out: *?*anyopaque) i32 {
    \\        const obj: *Object = @ptrCast(@alignCast(dev));
    \\        const fp: *const fn (*anyopaque, *const Texture2DDesc, ?*const anyopaque, *?*anyopaque) callconv(.c) i32 = @ptrCast(obj.vtbl[5]);
    \\        return fp(dev, desc, null, out);
    \\    }
    \\
    \\    /// ID3D11DeviceContext::Map — vtable index 14.
    \\    /// Signature: HRESULT Map(ID3D11Resource*, UINT subresource, D3D11_MAP, UINT flags, D3D11_MAPPED_SUBRESOURCE*).
    \\    pub fn contextMap(ctx: *anyopaque, resource: *anyopaque, subresource: u32, map_type: c_uint, flags: u32, out: *MappedSubresource) i32 {
    \\        const obj: *Object = @ptrCast(@alignCast(ctx));
    \\        const fp: *const fn (*anyopaque, *anyopaque, u32, c_uint, u32, *MappedSubresource) callconv(.c) i32 = @ptrCast(obj.vtbl[14]);
    \\        return fp(ctx, resource, subresource, map_type, flags, out);
    \\    }
    \\
    \\    /// ID3D11DeviceContext::Unmap — vtable index 15.
    \\    /// Signature: void Unmap(ID3D11Resource*, UINT subresource).
    \\    pub fn contextUnmap(ctx: *anyopaque, resource: *anyopaque, subresource: u32) void {
    \\        const obj: *Object = @ptrCast(@alignCast(ctx));
    \\        const fp: *const fn (*anyopaque, *anyopaque, u32) callconv(.c) void = @ptrCast(obj.vtbl[15]);
    \\        fp(ctx, resource, subresource);
    \\    }
    \\
    \\    /// ID3D11DeviceContext::CopyResource — vtable index 47.
    \\    /// Signature: void CopyResource(ID3D11Resource* dst, ID3D11Resource* src).
    \\    pub fn contextCopyResource(ctx: *anyopaque, dst: *anyopaque, src: *anyopaque) void {
    \\        const obj: *Object = @ptrCast(@alignCast(ctx));
    \\        const fp: *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.c) void = @ptrCast(obj.vtbl[47]);
    \\        fp(ctx, dst, src);
    \\    }
    \\
    \\    /// IUnknown::Release — vtable index 2. Used to release the
    \\    /// AddRef'd back-buffer pointer from `GetBuffer` and to drop
    \\    /// the staging textures on cleanup / resize.
    \\    pub fn release(obj_ptr: *anyopaque) u32 {
    \\        const obj: *Object = @ptrCast(@alignCast(obj_ptr));
    \\        const fp: *const fn (*anyopaque) callconv(.c) u32 = @ptrCast(obj.vtbl[2]);
    \\        return fp(obj_ptr);
    \\    }
    \\} else struct {};
    \\
;

/// Sokol Metal/IOSurface readback — Path A (labelle-assembler#131,
/// floooh/sokol#1510).
///
/// Path B (drawable→blit→getBytes) shipped in #128 but was permanently
/// gated behind a stub: sokol-zig's `sapp_get_swapchain()` returns the
/// *next* drawable each call, not the just-rendered one. The original
/// fork (`labelle-toolkit/sokol-zig` branch
/// `feat/expose-cached-metal-drawable`) cached the post-present
/// drawable, but Apple recycles drawables to the pool after present —
/// so by the time our readback fires, the drawable's `texture` is
/// either invalid or owned by a different frame.
///
/// Path A flips the producer side: we **own** the render target. The
/// engine allocates an `IOSurface` ring up front
/// (`Preview.beginFrameStreamIOSurface`); per surface we ask the
/// `MTLDevice` to make an `MTLTexture` wrapping it via
/// `newTextureWithDescriptor:iosurface:plane:`. Those textures get
/// injected into sokol-gfx as external `sg_image`s
/// (`ImageDesc.mtl_textures[…]`) with `color_attachment = true`, so
/// the game's render pass can be redirected to write straight into
/// our IOSurface (zero-copy: the editor samples the same surface).
/// At end-of-frame we call `Preview.signalSlotReady(slot)`
/// (labelle-engine#553) — no pixel touch, just a `header.latest` bump.
///
/// **Known gap**: actually *redirecting* the game's render pass into
/// our offscreen target needs hooks the current sokol+labelle
/// integration doesn't have. The gfx layer always uses sokol-app's
/// swapchain (`window.beginPass(pass_action)`); we'd need either
/// (a) a `gfx.setEditorRenderTarget(image, attachments)` shim that
/// flips `sg_begin_pass` to our attachments + adds a fullscreen-quad
/// copy to the swapchain afterward, or (b) a separate render path
/// for editor mode that does the offscreen pass + the swapchain
/// blit. Both are scoped as follow-ups. **For this PR**: the
/// IOSurface ring is allocated and signalled, but contents are
/// whatever IOSurfaceCreate left there (zero-filled in practice).
/// The editor sees a black Game View, but the SHM handshake +
/// frame_published cadence work end-to-end.
///
/// libobjc binding is minimised vs. Path B: we only need
/// `newTextureWithDescriptor:iosurface:plane:` (texture-from-surface
/// wrap) and `release` (cleanup). No blit encoder, no command queue,
/// no `getBytes` — the whole post-frame copy chain is gone.
///
/// State is module-scope (parallels the GL block) because sokol's
/// init/frame/cleanup callbacks don't share a stack frame.
/// `_preview_allocator` is the SAME slot the GL block stashes — the
/// gates are mutually exclusive (GL = .linux, Metal = .macos/.ios)
/// so they never race for it.
const PREVIEW_READBACK_HELPERS_METAL_SOKOL =
    \\
    \\// ── Sokol Metal/IOSurface preview seam (labelle-assembler#140) ─
    \\// All Path-A state + ring management + cleanup now lives in the
    \\// backend module (`backends/sokol/src/window.zig:preview_mtl`).
    \\// The codegen owns only:
    \\//   1. The comptime enable gate (aliased from the backend).
    \\//   2. Five tiny bridge fns that wrap `engine.Preview` methods
    \\//      behind an `*anyopaque` boundary so the backend never needs
    \\//      an engine type-import (the engine module would otherwise
    \\//      have to be wired through the backend's build graph too).
    \\//   3. The vtable-attach call inside the init callback (see
    \\//      PREVIEW_INIT_CALLBACK below).
    \\const _sokol_preview_metal_enabled = window.preview_metal_enabled;
    \\
    \\// Bridge fns — pure wrappers over the engine.Preview methods the
    \\// backend's preview_mtl namespace drives via its vtable. These
    \\// live in module scope because the vtable is wired up once during
    \\// init and persists for the program's lifetime.
    \\fn _preview_mtl_begin_stream_bridge(ctx: *anyopaque, w: u32, h: u32) anyerror!void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    return p.beginFrameStreamIOSurface(w, h);
    \\}
    \\fn _preview_mtl_get_surface_bridge(ctx: *anyopaque, slot: u32) ?*anyopaque {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    // getIOSurfaceAt returns `??*opaque` — outer optional means
    \\    // "slot in range", inner means "IOSurfaceRef itself nullable".
    \\    const maybe_ref = p.getIOSurfaceAt(slot) orelse return null;
    \\    const ref = maybe_ref orelse return null;
    \\    return @ptrCast(ref);
    \\}
    \\fn _preview_mtl_signal_bridge(ctx: *anyopaque, slot: u32) anyerror!void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    return p.signalSlotReady(slot);
    \\}
    \\fn _preview_mtl_end_stream_bridge(ctx: *anyopaque) void {
    \\    const p: *engine.Preview = @ptrCast(@alignCast(ctx));
    \\    p.endFrameStreamIOSurface();
    \\}
    \\fn _preview_mtl_accepted_bridge(ctx: *anyopaque) bool {
    \\    const p: *const engine.Preview = @ptrCast(@alignCast(ctx));
    \\    return p.isFrameAccepted();
    \\}
    \\
;

/// Init-callback addendum for the D3D11 staging-texture ring. Stashes
/// the allocator into the shared module-scope slot (`_preview_allocator`)
/// so the frame + cleanup callbacks can grow / free the CPU staging
/// buffer. The GL block stashes the same slot — both blocks are
/// mutually exclusive at comptime (`.linux` vs `.windows`), so only
/// one ever runs.
const PREVIEW_READBACK_INIT_SOKOL_D3D11 =
    \\    if (comptime _sokol_preview_d3d11_enabled) {
    \\        _preview_allocator = allocator;
    \\    }
    \\
;

/// Init-callback addendum for the Metal readback. Mirrors the GL
/// variant — the `_preview_allocator` slot is declared by the GL
/// block above and shared between paths (mutually exclusive at
/// runtime, so no contention). Selector cache is lazy-loaded on
/// first frame instead of here to keep the init callback's failure
/// surface narrow (sokol's init runs before the Metal device exists
/// in some sokol-app configs).
const PREVIEW_READBACK_INIT_METAL_SOKOL =
    \\    if (comptime _sokol_preview_metal_enabled) {
    \\        _preview_allocator = allocator;
    \\    }
    \\
;

/// Per-frame D3D11 readback for sokol's `frame` callback. Comptime-gated
/// on `_sokol_preview_d3d11_enabled` — the entire block evaporates on
/// non-Windows builds, leaving only the heartbeat path intact.
///
/// Algorithm mirrors the GL path (`PREVIEW_READBACK_FRAME_SOKOL`):
///   - read current screen dims via `window.width()` / `window.height()`
///   - on resize / first frame, (re)negotiate the SHM ring with the
///     editor + (re)create the 3-deep staging-texture ring + reset the
///     priming counter
///   - `IDXGISwapChain::GetBuffer(0)` → resolved back-buffer Texture2D
///   - `ID3D11DeviceContext::CopyResource(staging[N % 3], backbuffer)`
///   - release the back-buffer reference
///   - from frame 2 onwards, `Map(staging[(N-2) % 3], D3D11_MAP_READ)` +
///     memcpy with BGRA→RGBA swizzle into `_preview_pixel_buf`, then
///     `publishFrame`
///
/// Sokol's `window.endFrame()` calls `sg.endPass(); sg.commit();`. We
/// inject this BEFORE `endFrame()` so `CopyResource` queues up after
/// all of sokol's draw calls but before the swap — matching the GL
/// path's pre-commit placement and ensuring the staging copy reflects
/// the rendered frame, not the next one.
const PREVIEW_READBACK_FRAME_SOKOL_D3D11 =
    \\        if (comptime _sokol_preview_d3d11_enabled) {
    \\            if (g.preview) |*_p| _readback_d3d11: {
    \\                const _sw_i = window.width();
    \\                const _sh_i = window.height();
    \\                if (_sw_i <= 0 or _sh_i <= 0) break :_readback_d3d11;
    \\                const _sw: u32 = @intCast(_sw_i);
    \\                const _sh: u32 = @intCast(_sh_i);
    \\                const _needed_bytes: usize = @as(usize, _sw) * @as(usize, _sh) * 4;
    \\
    \\                const _device_opt = _SokolPreviewD3d11.sgDevice();
    \\                const _ctx_opt = _SokolPreviewD3d11.sgDeviceContext();
    \\                const _swap_opt = _SokolPreviewD3d11.sappSwapChain();
    \\                if (_device_opt == null or _ctx_opt == null or _swap_opt == null) break :_readback_d3d11;
    \\                const _device = @as(*anyopaque, @ptrCast(@constCast(_device_opt.?)));
    \\                const _ctx = @as(*anyopaque, @ptrCast(@constCast(_ctx_opt.?)));
    \\                const _swap = @as(*anyopaque, @ptrCast(@constCast(_swap_opt.?)));
    \\
    \\                if (_sw != _preview_last_w or _sh != _preview_last_h) {
    \\                    _p.beginFrameStream(_sw, _sh) catch break :_readback_d3d11;
    \\                    // Tear down the old ring (if any) before creating
    \\                    // the new one — staging dims must match the
    \\                    // back-buffer or `CopyResource` will fail silently.
    \\                    if (_preview_d3d11_initialized) {
    \\                        for (&_preview_d3d11_staging) |*_slot| {
    \\                            if (_slot.*) |_p_ptr| {
    \\                                _ = _SokolPreviewD3d11.release(_p_ptr);
    \\                                _slot.* = null;
    \\                            }
    \\                        }
    \\                    }
    \\                    const _staging_desc: _SokolPreviewD3d11.Texture2DDesc = .{
    \\                        .width = _sw,
    \\                        .height = _sh,
    \\                        .mip_levels = 1,
    \\                        .array_size = 1,
    \\                        .format = _SokolPreviewD3d11.FORMAT_B8G8R8A8_UNORM,
    \\                        .sample_count = 1,
    \\                        .sample_quality = 0,
    \\                        .usage = _SokolPreviewD3d11.USAGE_STAGING,
    \\                        .bind_flags = 0,
    \\                        .cpu_access_flags = _SokolPreviewD3d11.CPU_ACCESS_READ,
    \\                        .misc_flags = 0,
    \\                    };
    \\                    var _alloc_ok = true;
    \\                    for (&_preview_d3d11_staging) |*_slot| {
    \\                        var _new_tex: ?*anyopaque = null;
    \\                        const _hr = _SokolPreviewD3d11.deviceCreateTexture2D(_device, &_staging_desc, &_new_tex);
    \\                        if (_hr < 0 or _new_tex == null) {
    \\                            _alloc_ok = false;
    \\                            break;
    \\                        }
    \\                        _slot.* = _new_tex;
    \\                    }
    \\                    if (!_alloc_ok) {
    \\                        // Rollback any partial ring on failure so the
    \\                        // next resize attempt starts clean.
    \\                        for (&_preview_d3d11_staging) |*_slot| {
    \\                            if (_slot.*) |_p_ptr| {
    \\                                _ = _SokolPreviewD3d11.release(_p_ptr);
    \\                                _slot.* = null;
    \\                            }
    \\                        }
    \\                        break :_readback_d3d11;
    \\                    }
    \\                    _preview_d3d11_initialized = true;
    \\                    if (_preview_pixel_buf.len != _needed_bytes) {
    \\                        if (_preview_pixel_buf.len != 0) _preview_allocator.free(_preview_pixel_buf);
    \\                        _preview_pixel_buf = _preview_allocator.alloc(u8, _needed_bytes) catch &[_]u8{};
    \\                    }
    \\                    // Only commit the new dims once the CPU buffer is
    \\                    // the right size — same recovery logic as the GL
    \\                    // path. A transient alloc failure leaves
    \\                    // `last_w/h` stale so the next frame re-runs the
    \\                    // resize block.
    \\                    if (_preview_pixel_buf.len == _needed_bytes) {
    \\                        _preview_last_w = _sw;
    \\                        _preview_last_h = _sh;
    \\                        _preview_frame_idx = 0;
    \\                    }
    \\                }
    \\
    \\                if (!_p.isFrameAccepted() or _preview_pixel_buf.len != _needed_bytes or !_preview_d3d11_initialized) break :_readback_d3d11;
    \\
    \\                // Grab the back-buffer (Buffer 0 in DXGI; that's the
    \\                // resolved swap-chain surface, top-down origin). The
    \\                // returned pointer is AddRef'd by `GetBuffer` — we
    \\                // must `Release` after `CopyResource` to keep DXGI
    \\                // from leaking the reference across resizes.
    \\                var _backbuffer: ?*anyopaque = null;
    \\                const _hr_get = _SokolPreviewD3d11.swapChainGetBuffer(_swap, 0, &_SokolPreviewD3d11.IID_ID3D11Texture2D, &_backbuffer);
    \\                if (_hr_get < 0 or _backbuffer == null) break :_readback_d3d11;
    \\                defer _ = _SokolPreviewD3d11.release(_backbuffer.?);
    \\
    \\                const _write_idx: usize = @intCast(_preview_frame_idx % 3);
    \\                const _write_tex = _preview_d3d11_staging[_write_idx] orelse break :_readback_d3d11;
    \\                _SokolPreviewD3d11.contextCopyResource(_ctx, _write_tex, _backbuffer.?);
    \\
    \\                if (_preview_frame_idx >= 2) {
    \\                    const _read_idx: usize = @intCast((_preview_frame_idx - 2) % 3);
    \\                    const _read_tex = _preview_d3d11_staging[_read_idx] orelse break :_readback_d3d11;
    \\                    var _mapped: _SokolPreviewD3d11.MappedSubresource = .{ .data = null, .row_pitch = 0, .depth_pitch = 0 };
    \\                    const _hr_map = _SokolPreviewD3d11.contextMap(_ctx, _read_tex, 0, _SokolPreviewD3d11.MAP_READ, 0, &_mapped);
    \\                    if (_hr_map >= 0 and _mapped.data != null) {
    \\                        const _src_base: [*]const u8 = @ptrCast(_mapped.data.?);
    \\                        const _row_bytes: usize = @as(usize, _sw) * 4;
    \\                        const _row_pitch: usize = @intCast(_mapped.row_pitch);
    \\                        var _y: u32 = 0;
    \\                        // DXGI back buffers are top-down (row 0 = top),
    \\                        // so no row-flip — but the swapchain format is
    \\                        // BGRA8 while the SHM consumer expects RGBA8,
    \\                        // so swizzle channels 0/2 per pixel during the
    \\                        // copy. `row_pitch` from `Map` may be padded
    \\                        // above `width*4`, so we walk pitched rows
    \\                        // explicitly instead of treating the staging
    \\                        // texture as a flat array.
    \\                        while (_y < _sh) : (_y += 1) {
    \\                            const _src_row = _src_base + (@as(usize, _y) * _row_pitch);
    \\                            const _dst_row = _preview_pixel_buf.ptr + (@as(usize, _y) * _row_bytes);
    \\                            var _x: u32 = 0;
    \\                            while (_x < _sw) : (_x += 1) {
    \\                                const _off: usize = @as(usize, _x) * 4;
    \\                                _dst_row[_off + 0] = _src_row[_off + 2];
    \\                                _dst_row[_off + 1] = _src_row[_off + 1];
    \\                                _dst_row[_off + 2] = _src_row[_off + 0];
    \\                                _dst_row[_off + 3] = _src_row[_off + 3];
    \\                            }
    \\                        }
    \\                        _SokolPreviewD3d11.contextUnmap(_ctx, _read_tex, 0);
    \\                        _p.publishFrame(_preview_pixel_buf) catch {};
    \\                    } else if (_hr_map >= 0) {
    \\                        // Map succeeded but returned a null pointer —
    \\                        // pair the call with Unmap anyway so the
    \\                        // staging texture isn't left in a mapped
    \\                        // state.
    \\                        _SokolPreviewD3d11.contextUnmap(_ctx, _read_tex, 0);
    \\                    }
    \\                }
    \\                _preview_frame_idx +%= 1;
    \\            }
    \\        }
    \\
;

/// Pre-render Metal Path-A block for sokol's `frame` callback
/// (labelle-assembler#133 — closes the render-into-IOSurface gap
/// that #131/#132 left as a TODO). Emits into a new `{{preview_pre_render}}`
/// template slot that fires AFTER `g.tick(dt)` and BEFORE
/// `window.beginFrame()` / `window.beginPass()` so the swapchain-vs-
/// offscreen decision is made before sokol-gfx commits to either.
/// Comptime-gated on `_sokol_preview_metal_enabled` — evaporates on
/// Linux (GL) and Windows (D3D11) builds.
///
/// Responsibilities (per frame):
///   1. First frame OR resize: tear down any prior ring; ask the
///      engine to `beginFrameStreamIOSurface(w, h)` so a fresh
///      IOSurface ring lands in shm; for each slot wrap the
///      IOSurface as `MTLTexture` (`createIOSurfaceTexture`) +
///      inject into sokol-gfx as an external color-attachment
///      `sg.Image` (`mtl_textures[…]`) + build the per-slot
///      `sg.View` + `sg.Attachments` so the per-frame call site
///      can flip the gfx layer with a single struct copy.
///   2. If the editor has accepted a frame, pick `_write_slot`
///      (`_preview_frame_idx % ring_size`), stash it on the shared
///      `_preview_mtl_write_slot`, set `_preview_mtl_target_active`
///      and call `window.setEditorRenderTarget` so the next
///      `window.beginPass` routes `g.render()` into the Path-A
///      offscreen target. The post-render block consumes
///      `_preview_mtl_target_active` to decide whether to publish.
///
/// Pixel ordering: the IOSurface stores BGRA8 (matches sokol's
/// default Metal swapchain format), so the alpha pipeline + sgl
/// vertex stream produce identical output whether the pass lands
/// in the swapchain or our IOSurface — no shader / pipeline
/// reconfiguration needed.
const PREVIEW_PRE_RENDER_METAL_SOKOL =
    \\        if (comptime _sokol_preview_metal_enabled) window.preview_mtl.beginFrame();
    \\
;

/// Post-render Metal Path-A block for sokol's `frame` callback
/// (labelle-assembler#133). Emits into the existing `{{preview_readback}}`
/// slot (right after `g.render()` / `flushScene()` / GUI rendering,
/// before `window.endFrame()` commits the pass). Comptime-gated on
/// `_sokol_preview_metal_enabled`.
///
/// Responsibilities:
///   - If the pre-render block armed the editor target (handshake +
///     ring init + isFrameAccepted all passed), publish the just-
///     rendered slot via `signalSlotReady` and advance
///     `_preview_frame_idx`.
///   - Always call `window.clearEditorRenderTarget()` so the next
///     frame's `window.beginPass` defaults back to the swapchain
///     even if the pre-render block bails (editor disconnects,
///     transient ring rebuild, etc.). One-frame-scoped override
///     contract — see the shim in `backends/sokol/src/window.zig`.
const PREVIEW_READBACK_FRAME_METAL_SOKOL =
    \\        if (comptime _sokol_preview_metal_enabled) window.preview_mtl.endFrame();
    \\
;

/// Cleanup-callback teardown for the sokol D3D11 staging-texture ring.
/// Runs BEFORE `PREVIEW_CLEANUP_CALLBACK` (which sends the graceful
/// `bye`), matching the GL block's LIFO ordering. Gated on
/// `_sokol_preview_d3d11_enabled`; on non-Windows builds the staging
/// state is never initialized so there's nothing to free either.
///
/// Shares `_preview_pixel_buf` with the GL block, but since the two
/// blocks are mutually exclusive at comptime only one cleanup path
/// ever runs — the buffer is freed exactly once.
const PREVIEW_READBACK_CLEANUP_SOKOL_D3D11 =
    \\    if (comptime _sokol_preview_d3d11_enabled) {
    \\        if (g.preview) |*_p| _p.endFrameStream();
    \\        if (_preview_d3d11_initialized) {
    \\            for (&_preview_d3d11_staging) |*_slot| {
    \\                if (_slot.*) |_p_ptr| {
    \\                    _ = _SokolPreviewD3d11.release(_p_ptr);
    \\                    _slot.* = null;
    \\                }
    \\            }
    \\            _preview_d3d11_initialized = false;
    \\        }
    \\        if (_preview_pixel_buf.len != 0) _preview_allocator.free(_preview_pixel_buf);
    \\    }
    \\
;

/// Cleanup-callback teardown for the Path-A Metal ring. Runs BEFORE
/// `PREVIEW_CLEANUP_CALLBACK` (the graceful `bye`) so the engine
/// still has its socket open when the IOSurface producer tears
/// down — matches the GL + raylib LIFO ordering.
///
/// Order matters: we destroy the sokol images first (they hold an
/// internal reference to the MTLTexture but do NOT retain it —
/// sokol's `mtl_textures[]` injection is borrowed), then release
/// the MTLTextures (which drop their retain on the underlying
/// IOSurface), then ask the engine to tear down the IOSurface
/// ring + control-plane shm region. Doing the engine teardown
/// first would leave the MTLTextures pointing at potentially
/// freed IOSurface backing storage during the release window.
const PREVIEW_READBACK_CLEANUP_METAL_SOKOL =
    \\    if (comptime _sokol_preview_metal_enabled) window.preview_mtl.deinit();
    \\
;

/// Build the GUI draw code for {{gui_draw_code}}.
fn buildGuiDrawCode(allocator: std.mem.Allocator, cfg: ProjectConfig, view_names: []const []const u8) ![]const u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();
    const w = &alloc_writer.writer;

    if (cfg.hasGui()) {
        try w.writeAll("        g.guiBegin();\n");
        if (view_names.len > 0) {
            try w.writeAll("        g.renderAllViews(Views);\n");
        }
        try w.writeAll("        runner.drawGui(&g);\n");
        if (cfg.plugins.len > 0) {
            try w.writeAll("        PluginSystems.drawGui(&g);\n");
        }
        try w.writeAll("        g.guiEnd();\n");
    }

    var arr_list = alloc_writer.toArrayList();
    return arr_list.toOwnedSlice(allocator);
}

// ============================================================
// Callback-lifecycle code builders (sokol — init/frame/cleanup callbacks)
// ============================================================

/// Init code for callback-based backends (inside a `!void` helper, can use try).
fn buildCallbackInitCode(allocator: std.mem.Allocator, cfg: ProjectConfig, jsonc_scene_names: []const []const u8, prefab_names: []const []const u8) ![]const u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();
    const w = &alloc_writer.writer;

    if (cfg.resolved_gui) |gui| {
        if (gui.lifecycle.init) {
            try w.writeAll("    GuiBackend.init();\n");
        }
    }

    // Mirror the loop-path setup: install the image-asset backend hook
    // first so any later atlas / scene / script code that eventually
    // reaches `catalog.acquire` already sees a populated slot. See the
    // `buildSetupCode` comment for why this is emit-unconditional
    // across every backend variant.
    try writeImageBackendWiring(w, "    ");

    // Audio + font adapters gated on resource presence — same
    // rationale as `buildSetupCode`. See the comment block there
    // for the full reasoning; closes labelle-assembler#104.
    var has_audio = false;
    var has_font = false;
    for (cfg.resources) |res| {
        switch (res.kind()) {
            .sound => has_audio = true,
            .font => has_font = true,
            else => {},
        }
    }
    if (has_audio) try writeAudioBackendWiring(w, "    ");
    if (has_font) try writeFontBackendWiring(w, "    ");

    try w.writeAll("    runner = Runner.init(allocator, &g.active_world.ecs_backend);\n");

    // Load (or register) embedded atlas resources before scene.
    // Eager resources call `loadAtlasFromMemory` which decodes the
    // PNG immediately — sprites are available the moment the scene
    // is instantiated. Lazy resources (project.labelle: `lazy = true`)
    // call `registerAtlasFromMemory`, which parses the JSON eagerly
    // so sprite-name lookups still resolve, but defers the PNG
    // decode until a script calls `game.loadAtlasIfNeeded(name)`.
    // A loading-scene controller typically does this one atlas per
    // frame so the scene stays animated during the load.
    if (cfg.resources.len > 0) {
        try w.writeAll("    // Load embedded assets (atlases, sounds, fonts via @embedFile)\n");
        for (cfg.resources) |res| {
            // See buildSetupCode for the rationale — null means "inference
            // pass didn't run", which we treat as eager (back-compat) so
            // unmigrated sokol/wasm projects keep decoding their atlases
            // at startup. Must match the fallback in buildSetupCode.
            // The sokol-callback host has no error channel to unwind
            // into, so we use `.catch_panic_style` instead of `try`.
            try emitResourceLoad(w, res, .catch_panic_style);
        }
        try w.writeByte('\n');
    }

    // Pre-load embedded prefabs
    if (prefab_names.len > 0) {
        try w.writeAll("    // Embedded prefabs (via @embedFile)\n");
        for (prefab_names) |name| {
            const display = std.fs.path.basename(name);
            try w.print("    JsoncBridge.addEmbeddedPrefab(&g, \"{s}\", @embedFile(\"prefabs/{s}.jsonc\"), \"prefabs\") catch @panic(\"failed to load prefab\");\n", .{ display, name });
        }
        try w.writeByte('\n');
    }

    // Register JSONC scenes
    if (jsonc_scene_names.len > 0) {
        try w.writeAll("    // JSONC scenes\n");
        var jsonc_ident_buf: [256]u8 = undefined;
        for (jsonc_scene_names) |name| {
            const ident = pathToIdent(name, &jsonc_ident_buf);
            try w.print("    g.registerSceneSimple(\"{s}\", jsonc_{s}_loader);\n", .{ name, ident });
        }

        // Embed every scene's JSONC source so `"include"` directives
        // resolve against memory on WASM (no filesystem access for
        // project files). See `buildSetupCode` for full rationale and
        // labelle-toolkit/labelle-cli#200 for the failure this fixes.
        for (jsonc_scene_names) |name| {
            try w.print("    g.addEmbeddedSceneSource(\"scenes/{s}.jsonc\", @embedFile(\"scenes/{s}.jsonc\")) catch @panic(\"failed to register embedded scene source\");\n", .{ name, name });
        }

        // Attach parsed asset manifests — mirrors the loop-based setup path.
        // See `buildSetupCode` for the rationale. `init` is void here (C
        // compatibility for sokol/wasm callback backends), so we can't
        // propagate with `try`; panic on the impossible SceneNotFound
        // instead of swallowing, matching the `setScene` pattern below.
        try w.writeAll("    inline for (SceneAssetManifests.entries) |scene_asset_entry| {\n");
        try w.writeAll("        g.setSceneAssets(scene_asset_entry.name, scene_asset_entry.assets) catch @panic(\"failed to set scene assets\");\n");
        try w.writeAll("    }\n");

        // Attach declared `initial_state` (labelle-engine#500). See
        // `buildSetupCode` for the full rationale. Same panic-on-impossible-
        // SceneNotFound pattern as setSceneAssets above.
        try w.writeAll("    inline for (SceneInitialStateManifests.entries) |scene_state_entry| {\n");
        try w.writeAll("        g.setSceneInitialState(scene_state_entry.name, scene_state_entry.initial_state) catch @panic(\"failed to set scene initial state\");\n");
        try w.writeAll("    }\n");

        // Default initial state BEFORE setScene — see `buildSetupCode`.
        if (cfg.states.len > 0) {
            try w.print("    g.setState(\"{s}\");\n", .{cfg.states[0]});
        }

        const initial = cfg.initial_scene orelse jsonc_scene_names[0];
        try w.print("    g.setScene(\"{s}\") catch @panic(\"failed to set initial scene\");\n", .{initial});
    }

    try w.writeAll("    runner.setup(&g);\n");

    if (cfg.plugins.len > 0) {
        try w.writeAll("    PluginSystems.setup(&g);\n");
        // Plugin controllers: setup on scene load. Deinit is emitted by
        // `buildCallbackCleanupCode` since callback backends don't share
        // the `defer` scope of init. RFC-plugin-controllers §2.
        try w.writeAll("    PluginControllers.setup(&g) catch @panic(\"plugin controller setup failed\");\n");
    }

    var arr_list = alloc_writer.toArrayList();
    return arr_list.toOwnedSlice(allocator);
}

/// Cleanup code for callback-based backends (in cleanup() C callback).
fn buildCallbackCleanupCode(allocator: std.mem.Allocator, cfg: ProjectConfig) ![]const u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();
    const w = &alloc_writer.writer;

    if (cfg.resolved_gui) |gui| {
        if (gui.lifecycle.shutdown) {
            try w.writeAll("    GuiBackend.shutdown();\n");
        }
    }

    if (cfg.plugins.len > 0) {
        // Mirror-order of buildCallbackInitCode: deinit in reverse of setup
        // so controllers tear down before the systems they depend on.
        // RFC-plugin-controllers §2.
        try w.writeAll("    PluginControllers.deinit(&g);\n");
        try w.writeAll("    PluginSystems.deinit();\n");
    }

    try w.writeAll("    runner.deinit();\n");

    var arr_list = alloc_writer.toArrayList();
    return arr_list.toOwnedSlice(allocator);
}

/// Write a Zig double-quoted string literal for `s`, escaping `\` and `"` so
/// that asset names or scene names containing those characters produce valid
/// generated source rather than a compile error.
fn writeZigString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// Emit the `SceneAssetManifests` comptime struct that exposes each scene's
/// declared `assets:` array to labelle-engine. The format is the codegen
/// contract for the SceneEntry.assets consumer (labelle-engine issue #445):
///
///     pub const SceneAssetManifests = struct {
///         pub const menu: []const []const u8 = &.{ "background", "ship" };
///         pub const world_intro: []const []const u8 = &.{};
///
///         pub const Entry = struct { name: []const u8, assets: []const []const u8 };
///         pub const entries: []const Entry = &.{
///             .{ .name = "menu",        .assets = menu },
///             .{ .name = "world/intro", .assets = world_intro },
///         };
///     };
///
/// Per-scene decls give comptime access by ident; the `entries` array is the
/// stable iteration order (matches the assembler's sorted scene-name order).
fn writeSceneAssetManifests(
    w: anytype,
    jsonc_scene_names: []const []const u8,
    scene_manifests: []const SceneManifest,
    ident_buf: *[256]u8,
) !void {
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

/// Emit the `SceneInitialStateManifests` comptime struct that exposes each
/// scene's declared `initial_state:` to labelle-engine's setSceneInitialState
/// API. Mirrors the SceneAssetManifests pattern (see above).
///
///     pub const SceneInitialStateManifests = struct {
///         pub const Entry = struct { name: []const u8, initial_state: []const u8 };
///         pub const entries: []const Entry = &.{
///             .{ .name = "combat_arena", .initial_state = "playing" },
///         };
///     };
///
/// Unlike SceneAssetManifests, this struct ONLY lists scenes that actually
/// declared an `initial_state` — scenes without one don't appear, so the
/// generated `inline for (entries)` loop is a no-op for back-compat scenes.
fn writeSceneInitialStateManifests(
    w: anytype,
    jsonc_scene_names: []const []const u8,
    scene_manifests: []const SceneManifest,
) !void {
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

/// Convert a path-style name to a valid Zig identifier: "enemies/goblin" -> "enemies_goblin".
/// Replaces `/`, `+`, and `.` with `_`, strips the `.zig` extension first.
///
/// The `.` → `_` rewrite covers plugin-shipped scripts that land under
/// `.plugin_<name>/…` — the leading dot would otherwise produce an identifier
/// that Zig rejects. The rewrite is safe for ordinary scene / scripts paths
/// because the only dot in valid convention names is the `.zig` suffix, which
/// is stripped before the char walk.
fn pathToIdent(name: []const u8, buf: *[256]u8) []const u8 {
    if (name.len > buf.len) {
        std.debug.print("labelle: path too long for identifier (max {d} chars): '{s}'\n", .{ buf.len, name });
        @panic("path exceeds identifier buffer size");
    }
    // Strip .zig extension
    const end = if (std.mem.endsWith(u8, name, ".zig")) name.len - 4 else name.len;
    var i: usize = 0;
    for (name[0..end]) |c| {
        buf[i] = if (c == '/' or c == '+' or c == '.') '_' else c;
        i += 1;
    }
    return buf[0..i];
}

/// Convert snake_case to PascalCase: "rigid_body" -> "RigidBody", "health" -> "Health".
fn snakeToPascal(name: []const u8, pascal_buf: *[128]u8) []const u8 {
    var i: usize = 0;
    var capitalize_next = true;
    for (name) |c| {
        if (c == '_') {
            capitalize_next = true;
        } else {
            if (i >= pascal_buf.len) break;
            pascal_buf[i] = if (capitalize_next) std.ascii.toUpper(c) else c;
            i += 1;
            capitalize_next = false;
        }
    }
    return pascal_buf[0..i];
}

// ── Template-based generation (engine provides main.zig.template) ────────

/// Generate main.zig using the engine's codegen template.
/// The template uses {{variable}} interpolation and {{#if}}/{{#each}} blocks.
/// All complex sections are pre-computed into scalar blocks by this function.
pub fn generateMainZigFromTemplate(
    allocator: std.mem.Allocator,
    engine_template: []const u8,
    cfg: ProjectConfig,
    lifecycle_tmpl: []const u8,
    script_entries: []const ScriptEntry,
    prefab_names: []const []const u8,
    jsonc_scene_names: []const []const u8,
    scene_manifests: []const SceneManifest,
    component_names: []const []const u8,
    hook_names: []const []const u8,
    event_names: []const []const u8,
    enum_names: []const []const u8,
    view_names: []const []const u8,
    gizmo_names: []const []const u8,
    animation_names: []const []const u8,
) ![]const u8 {
    // Surface basename collisions at generate time, before any
    // code emission — otherwise two prefabs with the same filename
    // in different subfolders would both try to register the same
    // name and silently overwrite. Match the diagnostic style in
    // `main.zig:97` (`stderr().writeAll(...)`) instead of
    // `std.log.err` so the Zig test runner doesn't classify the
    // expected diagnostic as a logged-error test failure.
    if (try checkBasenameCollisions(allocator, prefab_names)) |msg| {
        defer allocator.free(msg);
        const prefix = "labelle-assembler: ";
        const io = config.globalIo();
        std.Io.File.stderr().writeStreamingAll(io, prefix) catch {};
        std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
        std.Io.File.stderr().writeStreamingAll(io, "\n") catch {};
        return error.PrefabBasenameCollision;
    }

    // Validate every resource entry before any codegen. Catches
    // half-declared atlases (only `.json` or only `.texture`),
    // multi-kind tangles (`.sound` + `.font` on the same entry),
    // unrecognised file extensions, and misplaced `.font_params`.
    // The diagnostic is written to stderr inside the helper so
    // each malformed entry surfaces its name and reason before bailout.
    try validateResources(cfg);

    var data = tpl.TemplateData{
        .scalars = std.StringHashMap([]const u8).init(allocator),
        .lists = std.StringHashMap([]const tpl.ListItem).init(allocator),
    };
    defer data.scalars.deinit();
    defer data.lists.deinit();

    // Track allocations for cleanup
    var allocs: std.ArrayList([]const u8) = .empty;
    defer {
        for (allocs.items) |s| allocator.free(s);
        allocs.deinit(allocator);
    }

    // ── Boolean flags ──
    try data.scalars.put("ecs_mode_mock", if (cfg.ecs == .mock) "1" else "");
    try data.scalars.put("has_gui", if (cfg.hasGui()) "1" else "");
    try data.scalars.put("has_context", if (hasContextEntry(script_entries)) "1" else "");

    // ── Pre-computed blocks ──
    var ident_buf: [256]u8 = undefined;

    // Hook imports block
    //
    // The wasm32-emscripten panic-handler override (labelle-assembler#141)
    // is emitted at the top of this block so the two `pub const` root
    // declarations land near `const std = @import("std")` in the
    // generated `main.zig`. They MUST appear at module root for Zig to
    // honor them, and this block is rendered right after the stdlib
    // imports in `labelle-engine/codegen/main.zig.template`.
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (cfg.platform == .wasm) {
            try bw.writeAll(WASM_PANIC_WORKAROUND);
        }
        if (hook_names.len > 0) {
            try bw.writeAll("\n// --- Hook imports ---\n");
            for (hook_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print("const {s} = @import(\"hooks/{s}.zig\");\n", .{ ident, name });
            }
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("hook_imports_block", block);
    }

    // Event imports block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (event_names.len > 0) {
            try bw.writeAll("\n// --- Event imports ---\n");
            for (event_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print("const {s} = @import(\"events/{s}.zig\");\n", .{ ident, name });
            }
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("event_imports_block", block);
    }

    // Enum imports block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (enum_names.len > 0) {
            try bw.writeAll("\n// --- Enum imports ---\n");
            for (enum_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print("const {s} = @import(\"enums/{s}.zig\");\n", .{ ident, name });
            }
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("enum_imports_block", block);
    }

    // JSONC scene block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (jsonc_scene_names.len > 0 or prefab_names.len > 0) {
            try bw.writeAll("\n// --- JSONC scene loaders (embedded) ---\n");
            if (gizmo_names.len > 0) {
                try bw.writeAll("const JsoncBridge = engine.JsoncSceneBridgeWithGizmos(AssembledGame, Components, Gizmos);\n");
            } else {
                try bw.writeAll("const JsoncBridge = engine.JsoncSceneBridge(AssembledGame, Components);\n");
            }
            for (jsonc_scene_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print(
                    \\const jsonc_{s}_loader = struct {{
                    \\    const embedded_source = @embedFile("scenes/{s}.jsonc");
                    \\    fn load(game: *AssembledGame) anyerror!void {{
                    \\        return JsoncBridge.loadSceneFromSource(game, embedded_source, "prefabs");
                    \\    }}
                    \\}}.load;
                    \\
                    , .{ ident, name });
            }

            // ── Scene → assets map (Asset Streaming RFC, ticket #46) ────
            // Emit a comptime-visible struct that maps each scene's
            // assembler name to the `assets:` array declared at the top of
            // its .jsonc file. Empty arrays are emitted explicitly so the
            // labelle-engine consumer (issue #445) can iterate `entries`
            // without checking for missing keys. See also the upcoming
            // labelle-engine SceneEntry.assets field — this block is the
            // codegen contract that ticket reads.
            try writeSceneAssetManifests(bw, jsonc_scene_names, scene_manifests, &ident_buf);

            // Same pattern for scene-declared `initial_state`
            // (labelle-engine#500) — emit only the scenes that opted in,
            // so the generated inline-for is a no-op for back-compat.
            try writeSceneInitialStateManifests(bw, jsonc_scene_names, scene_manifests);
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("jsonc_scene_block", block);
    }

    // Game layers block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        try generateGameLayers(cfg.layers, bw);
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("game_layers_block", block);
    }

    // Resource registry block
    // Resource registry block — resources are now loaded at runtime via
    // @embedFile + loadAtlasFromMemory, so the comptime registry is empty.
    // The block is kept as an empty string for template compatibility.
    {
        const block = try allocator.dupe(u8, "");
        try allocs.append(allocator, block);
        try data.scalars.put("resource_registry_block", block);
    }

    // AllHookPayloads block — merge engine payloads with game events if present
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (event_names.len == 0) {
            try bw.writeAll("const AllHookPayloads = engine.HookPayload(EcsBackend.Entity);\n\n");
        } else {
            try bw.writeAll("const AllHookPayloads = engine.core.MergeHookPayloads(.{ engine.HookPayload(EcsBackend.Entity), GameEvents });\n\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("all_hook_payloads_block", block);
    }

    // Game hooks block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (hook_names.len == 0) {
            try bw.writeAll("const GameHooks = struct {};\n\n");
        } else {
            var pascal_buf: [128]u8 = undefined;
            try bw.writeAll("const GameHooks = engine.MergeHooks(AllHookPayloads, .{");
            for (hook_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                const pascal = snakeToPascal(ident, &pascal_buf);
                try bw.print(" *{s}.{s},", .{ ident, pascal });
            }
            try bw.writeAll(" });\n\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("game_hooks_block", block);
    }

    // Hooks init block — instantiate individual hooks and wire into GameHooks
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (hook_names.len == 0) {
            try bw.writeAll("    var hooks = GameHooks{};\n");
        } else {
            var pascal_buf: [128]u8 = undefined;
            for (hook_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                const pascal = snakeToPascal(ident, &pascal_buf);
                try bw.print("    var {s}_inst = {s}.{s}{{}};\n", .{ ident, ident, pascal });
            }
            try bw.writeAll("    var hooks = GameHooks{ .receivers = .{");
            for (hook_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print(" &{s}_inst,", .{ident});
            }
            try bw.writeAll(" } };\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("hooks_init_block", block);
    }

    // Game events block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (event_names.len == 0) {
            try bw.writeAll("const GameEvents = void;\n\n");
        } else {
            try bw.writeAll("const GameEvents = union(enum) {\n");
            var pascal_buf: [128]u8 = undefined;
            for (event_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                const pascal = snakeToPascal(ident, &pascal_buf);
                try bw.print("    {s}: {s}.{s},\n", .{ ident, ident, pascal });
            }
            try bw.writeAll("};\n\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("game_events_block", block);
    }

    // Prefab registry block — JSONC prefabs are loaded at runtime via
    // addEmbeddedPrefab, so the comptime registry is always empty.
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        try bw.writeAll("const Prefabs = engine.PrefabRegistry(.{});\n\n");
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("prefab_registry_block", block);
    }

    // Component registry block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        const has_plugins = cfg.plugins.len > 0;
        if (has_plugins) {
            try bw.writeAll("const Components = engine.ComponentRegistryWithPlugins(.{\n");
        } else {
            try bw.writeAll("const Components = engine.ComponentRegistry(.{\n");
        }
        var pascal_buf: [128]u8 = undefined;
        for (component_names) |name| {
            const ident = pathToIdent(name, &ident_buf);
            const pascal = snakeToPascal(ident, &pascal_buf);
            try bw.print("    .{s} = @import(\"components/{s}.zig\").{s},\n", .{ pascal, name, pascal });
        }
        if (has_plugins) {
            try bw.writeAll("}, .{\n");
            try bw.writeAll("    @import(\"labelle-gfx\"),\n");
            for (cfg.plugins) |plugin| {
                try bw.print("    @import(\"{s}\"),\n", .{plugin.name});
            }
            try bw.writeAll("});\n\n");
        } else {
            try bw.writeAll("});\n\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("component_registry_block", block);
    }

    // System registry block + Plugin controllers block (appended into the
    // same scalar so it slots into existing `{{system_registry_block}}`
    // placeholder in main.zig.template without needing a template update).
    //
    // The Plugin controllers scaffolding discovers `pub const Controller` in
    // each plugin root module at comptime and emits a `setup` / `deinit`
    // dispatcher the generated main calls on scene load / unload.
    // Backward-compatible: plugins without a Controller export are silently
    // skipped by the `@hasDecl` guard, so no runtime cost and no
    // generate-time opt-in needed.
    //
    // See flying-platform-labelle#208 (RFC: Plugin-Exported Controllers) §1–§2.
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (cfg.plugins.len > 0) {
            try bw.writeAll("const PluginSystems = engine.SystemRegistry(.{\n");
            try bw.writeAll("    @import(\"labelle-gfx\"),\n");
            for (cfg.plugins) |plugin| {
                try bw.print("    @import(\"{s}\"),\n", .{plugin.name});
            }
            try bw.writeAll("});\n\n");
            try bw.writeAll("const DiscoveredGizmoCategories = PluginSystems.gizmoCategories();\n\n");

            try writePluginControllersBlock(bw, cfg);
        } else {
            try bw.writeAll("const GizmoCatEntry = struct { name: []const u8, id: u8 };\n");
            try bw.writeAll("const DiscoveredGizmoCategories: []const GizmoCatEntry = &.{};\n\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("system_registry_block", block);
    }

    // All scripts block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        try bw.writeAll("const AllScripts = struct {\n");
        for (script_entries) |entry| {
            if (std.mem.eql(u8, entry.name, "context")) continue;
            const ident = pathToIdent(entry.rel_path, &ident_buf);
            if (entry.states.len == 0) {
                try bw.print("    pub const {s} = @import(\"scripts/{s}\");\n", .{ ident, entry.rel_path });
            } else {
                try bw.print("    pub const {s} = struct {{\n", .{ident});
                try bw.print("        const _inner = @import(\"scripts/{s}\");\n", .{entry.rel_path});
                try bw.writeAll("        pub const game_states = .{\n");
                for (entry.states) |state| {
                    try bw.print("            \"{s}\",\n", .{state});
                }
                try bw.writeAll("        };\n");
                const decl_names = [_][]const u8{ "tick", "setup", "drawGui", "State" };
                for (decl_names) |decl| {
                    try bw.print("        pub const {s} = if (@hasDecl(_inner, \"{s}\")) _inner.{s} else {{}};\n", .{ decl, decl, decl });
                }
                try bw.writeAll("    };\n");
            }
        }
        try bw.writeAll("};\n\n");
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("all_scripts_block", block);
    }

    // View registry block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (view_names.len > 0) {
            try bw.writeAll("const Views = engine.ViewRegistry(.{\n");
            for (view_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print("    .{s} = @import(\"views/{s}.zon\"),\n", .{ ident, name });
            }
            try bw.writeAll("});\n\n");
        } else {
            try bw.writeAll("const Views = engine.EmptyViewRegistry;\n\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("view_registry_block", block);
    }

    // Gizmo registry block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (gizmo_names.len > 0) {
            try bw.writeAll("const Gizmos = engine.GizmoRegistry(.{\n");
            for (gizmo_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print("    .{s} = @import(\"gizmos/{s}.zon\"),\n", .{ ident, name });
            }
            try bw.writeAll("});\n\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("gizmo_registry_block", block);
    }

    // Animation registry block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (animation_names.len > 0) {
            var anim_pascal_buf: [128]u8 = undefined;
            for (animation_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                const pascal = snakeToPascal(ident, &anim_pascal_buf);
                try bw.print("const {s}Anim = engine.AnimationDef(@import(\"animations/{s}.zon\"));\n", .{ pascal, name });
            }
            try bw.writeAll("\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("animation_registry_block", block);
    }

    // ── Lifecycle section (rendered from backend template, same as procedural path) ──
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;

        const tick_code = if (cfg.plugins.len > 0)
            "        const scaled_dt = dt * g.time_scale;\n" ++
            "        if (scaled_dt > 0) {\n" ++
            "            runner.tick(&g, scaled_dt);\n" ++
            "            PluginSystems.tick(&g, scaled_dt);\n" ++
            "            PluginSystems.postTick(&g, scaled_dt);\n" ++
            "        }\n" ++
            "        g.dispatchEvents();\n" ++
            "        // Update profiling pointers (debug only)\n" ++
            "        if (comptime @TypeOf(runner).profiling_enabled) {\n" ++
            "            g.script_profile_ptr = @ptrCast(@alignCast(&runner.profile));\n" ++
            "            g.script_profile_count = @TypeOf(runner).script_count;\n" ++
            "        }\n" ++
            "        if (comptime PluginSystems.profiling_enabled) {\n" ++
            "            g.plugin_profile_ptr = @ptrCast(@alignCast(&PluginSystems.plugin_profile));\n" ++
            "            g.plugin_profile_count = PluginSystems.plugin_system_count;\n" ++
            "        }\n"
        else
            "        const scaled_dt = dt * g.time_scale;\n" ++
            "        if (scaled_dt > 0) {\n" ++
            "            runner.tick(&g, scaled_dt);\n" ++
            "        }\n" ++
            "        g.dispatchEvents();\n" ++
            "        if (comptime @TypeOf(runner).profiling_enabled) {\n" ++
            "            g.script_profile_ptr = @ptrCast(@alignCast(&runner.profile));\n" ++
            "            g.script_profile_count = @TypeOf(runner).script_count;\n" ++
            "        }\n";

        const gui_draw_code = try buildGuiDrawCode(allocator, cfg, view_names);
        defer allocator.free(gui_draw_code);

        var w_buf: [16]u8 = undefined;
        var h_buf: [16]u8 = undefined;
        var fps_buf: [16]u8 = undefined;
        const w_str = std.fmt.bufPrint(&w_buf, "{d}", .{cfg.width}) catch unreachable;
        const h_str = std.fmt.bufPrint(&h_buf, "{d}", .{cfg.height}) catch unreachable;
        const fps_str = std.fmt.bufPrint(&fps_buf, "{d}", .{cfg.target_fps}) catch unreachable;

        const hidden_setup: []const u8 = if (cfg.hidden)
            "    window.setConfigFlags(.{ .window_hidden = true });\n"
        else
            "";

        const hooks_init = data.scalars.get("hooks_init_block") orelse "    var hooks = GameHooks{};\n";

        const use_callback_lifecycle = cfg.backend == .sokol or cfg.platform == .wasm;

        if (use_callback_lifecycle) {
            const sokol_runner: []const u8 = if (cfg.backend == .sokol) "var runner: Runner = undefined;\n" else "";
            // Sokol-backend builds get ALL THREE readback helper blocks
            // emitted side-by-side:
            //   - GL PBO ring (labelle-assembler#122 slice 1, #124) —
            //     fires on Linux/Android via `_sokol_preview_gl_enabled`.
            //   - D3D11 staging-texture ring (labelle-assembler#126,
            //     slice 2 of #122) — fires on Windows via
            //     `_sokol_preview_d3d11_enabled`.
            //   - Metal/IOSurface ring (labelle-assembler#125, slice 3
            //     of #122) — fires on macOS/iOS via
            //     `_sokol_preview_metal_enabled`.
            // The three gates are mutually exclusive (Linux vs Windows
            // vs Darwin), so only one block's runtime code path is
            // reachable per target. The `else struct {}` branches in
            // each helper namespace keep unresolved-symbol references
            // off the link line on the inactive targets.
            // Emit-unconditional for `cfg.backend == .sokol` keeps the
            // generated source uniform across desktop / mobile
            // templates; wasm routes through the raylib branch below
            // and stays out of all three readback paths for now.
            const sokol_readback_helpers: []const u8 = if (cfg.backend == .sokol)
                try std.mem.concat(allocator, u8, &.{
                    PREVIEW_READBACK_HELPERS_SOKOL,
                    PREVIEW_READBACK_HELPERS_SOKOL_D3D11,
                    PREVIEW_READBACK_HELPERS_METAL_SOKOL,
                })
            else
                "";
            defer if (cfg.backend == .sokol) allocator.free(sokol_readback_helpers);
            // PREVIEW_INPUT_DISPATCH emits `extern fn imgui_bridge_mouse_*`
            // symbols, which only exist when the gui plugin is imgui. Gate
            // narrowly on plugin name — other gui plugins (clay, simple-raylib,
            // simple-sokol, …) would link-fail on these externs. The stub
            // variant provides safe no-ops for those projects.
            const input_dispatch_cb: []const u8 = if (cfg.resolved_gui) |gui|
                (if (std.mem.eql(u8, gui.name, "imgui")) PREVIEW_INPUT_DISPATCH else PREVIEW_INPUT_DISPATCH_STUB)
            else
                PREVIEW_INPUT_DISPATCH_STUB;
            const module_vars = try std.mem.concat(allocator, u8, &.{ sokol_runner, PREVIEW_HELPERS, sokol_readback_helpers, input_dispatch_cb });
            defer allocator.free(module_vars);
            const init_code = try buildCallbackInitCode(allocator, cfg, jsonc_scene_names, prefab_names);
            defer allocator.free(init_code);

            const platform_comment: []const u8 = switch (cfg.platform) {
                .ios => "iOS: sokol bindings accessed through engine.sokol (no direct sokol import)",
                .android => "Android: sokol handles the app lifecycle via NativeActivity",
                .wasm => "WASM: Emscripten drives the main loop via callbacks",
                .desktop => "",
            };
            const entry_comment: []const u8 = switch (cfg.platform) {
                .ios => "iOS entry — no main(), sokol handles the app lifecycle",
                .android => "Android entry — no main(), sokol handles the NativeActivity lifecycle",
                .wasm => "WASM entry — Emscripten drives the main loop via callbacks",
                .desktop => "",
            };

            if (cfg.backend == .sokol) {
                const cleanup_code = try buildCallbackCleanupCode(allocator, cfg);
                defer allocator.free(cleanup_code);
                const is_wasm = cfg.platform == .wasm;
                const allocator_decl: []const u8 = if (is_wasm)
                    "// Use c_allocator for Emscripten — delegates to emscripten's malloc/free\n// which respects ALLOW_MEMORY_GROWTH. GPA is incompatible with wasm32-emscripten.\nconst allocator = std.heap.c_allocator;"
                else
                    "var gpa = std.heap.DebugAllocator(.{}).init;";
                const allocator_expr: []const u8 = if (is_wasm) "std.heap.c_allocator" else "gpa.allocator()";
                const allocator_cleanup: []const u8 = if (is_wasm) "" else "    _ = gpa.deinit();\n";
                // For wasm, `allocator` is already declared at module scope
                // by `{{allocator_decl}}` above, so re-declaring it inside
                // `initInner` would trigger Zig's "local constant shadows
                // declaration" error (labelle-cli#198). For desktop, the
                // module scope only has `var gpa = ...`, so we still need
                // the inner alias.
                const allocator_local_decl: []const u8 = if (is_wasm) "" else "    const allocator = gpa.allocator();\n";

                // Wire the GUI bridge into sokol's event callback so widgets
                // see mouse / keyboard input. labelle-imgui's sokol bridge
                // exports `imgui_bridge_handle_event` for exactly this — when
                // a GUI plugin is configured we forward each event to it.
                // Without this hook simgui's IO state stays empty and ImGui
                // buttons/sliders never respond.
                const gui_event_extern: []const u8 = if (cfg.hasGui())
                    "extern fn imgui_bridge_handle_event(ev: [*c]const @import(\"backend_input\").Event) bool;\n\n"
                else
                    "";
                const gui_event_forward: []const u8 = if (cfg.hasGui())
                    "    _ = imgui_bridge_handle_event(ev);\n"
                else
                    "";

                // Readback hookups (labelle-assembler#122). Each
                // lifecycle slot gets ALL THREE backend variants
                // concatenated (GL slice 1 #124, D3D11 slice 2 #126,
                // Metal slice 3 #125):
                //   - init   : stash the allocator into the module-scope
                //              slot (idempotent across the three gates —
                //              exactly one branch fires per target)
                //   - frame  : pre-endFrame slot carries GL + D3D11
                //              (both rely on a flush-on-read primitive
                //              that's safe before `sg.commit()`); the
                //              Metal block runs in the post-endFrame
                //              slot because Metal needs `sg.commit()`
                //              to land the swapchain texture before our
                //              own command buffer can read it.
                //   - cleanup: endFrameStream + ring teardown for each,
                //              then the graceful `bye`. Buffer free
                //              guarded so the inactive blocks are
                //              no-ops.
                // The three paths evaporate on the non-matching OS via
                // their `_sokol_preview_{gl,d3d11,metal}_enabled` flags.
                //
                // Wasm-emscripten gate (labelle-assembler#141): preview
                // mode is useless in a browser tab (no `LABELLE_PREVIEW`
                // env, no TCP socket out), and `std.Io.Threaded.init` +
                // `.io()` instantiates the vtable that references
                // `childWaitPosix` → triggers the Zig 0.16
                // `Threaded.zig:15315` / `emscripten.zig:215` enum
                // mismatches. Emit empty strings for the preview slots
                // on wasm so the generated `main.zig` never references
                // `std.Io.Threaded`. See ziglang/zig#31849 + PR #31850
                // for the upstream fix; this is the workaround for now.
                const preview_setup_sokol = if (is_wasm)
                    try allocator.dupe(u8, "")
                else
                    try std.mem.concat(allocator, u8, &.{
                        PREVIEW_INIT_CALLBACK,
                        PREVIEW_READBACK_INIT_SOKOL,
                        PREVIEW_READBACK_INIT_SOKOL_D3D11,
                        PREVIEW_READBACK_INIT_METAL_SOKOL,
                    });
                defer allocator.free(preview_setup_sokol);
                // Wasm-emscripten gate (labelle-assembler#141, same
                // rationale as `preview_setup_sokol` above). Heartbeat
                // + readback + cleanup all touch `g.preview`'s public
                // methods, and Zig's lazy compilation may still pull
                // the `popInputEvent` / `tickHeartbeat` codepaths into
                // the wasm exe even when `g.preview` is statically
                // null. Emit empty strings so the generated `main.zig`
                // never references Preview's IO surface on wasm.
                const preview_readback_sokol = if (is_wasm)
                    try allocator.dupe(u8, "")
                else
                    try std.mem.concat(allocator, u8, &.{
                        PREVIEW_READBACK_FRAME_SOKOL,
                        PREVIEW_READBACK_FRAME_SOKOL_D3D11,
                        // Path A (#131): the Metal block no longer depends
                        // on a swapchain drawable, so it can run in the
                        // pre-endFrame slot alongside GL / D3D11. The
                        // `{{preview_readback_post}}` template hole gets
                        // an empty string below — kept in the template so
                        // existing test scaffolding still expands cleanly,
                        // but no longer carries any Metal payload.
                        PREVIEW_READBACK_FRAME_METAL_SOKOL,
                    });
                defer allocator.free(preview_readback_sokol);
                const preview_cleanup_sokol = if (is_wasm)
                    try allocator.dupe(u8, "")
                else
                    try std.mem.concat(allocator, u8, &.{
                        PREVIEW_READBACK_CLEANUP_SOKOL,
                        PREVIEW_READBACK_CLEANUP_SOKOL_D3D11,
                        PREVIEW_READBACK_CLEANUP_METAL_SOKOL,
                        PREVIEW_CLEANUP_CALLBACK,
                    });
                defer allocator.free(preview_cleanup_sokol);
                const preview_heartbeat_sokol: []const u8 = if (is_wasm) "" else PREVIEW_HEARTBEAT_CALLBACK;

                try tpl.render(lifecycle_tmpl, .{
                    .module_vars = module_vars,
                    .width = w_str,
                    .height = h_str,
                    .title = cfg.title,
                    .fps = fps_str,
                    .init_code = init_code,
                    .tick_code = tick_code,
                    .gui_draw_code = gui_draw_code,
                    .gui_event_extern = gui_event_extern,
                    .gui_event_forward = gui_event_forward,
                    .cleanup_code = cleanup_code,
                    .platform_comment = platform_comment,
                    .entry_comment = entry_comment,
                    .hidden_setup = hidden_setup,
                    .hooks_init_block = hooks_init,
                    .allocator_decl = allocator_decl,
                    .allocator_expr = allocator_expr,
                    .allocator_local_decl = allocator_local_decl,
                    .allocator_cleanup = allocator_cleanup,
                    // Preview-mode wiring (labelle-assembler#94,
                    // labelle-engine#520). `g.preview` is the canonical
                    // storage; init dials + assigns + seeds the PBO
                    // allocator, frame heartbeats + reads back pixels,
                    // cleanup tears down PBO state then emits the
                    // graceful `bye`, and `g.deinit` owns the socket +
                    // arena teardown.
                    .preview_setup = preview_setup_sokol,
                    .preview_heartbeat = preview_heartbeat_sokol,
                    // Path A render-target wiring (#133) — fires BEFORE
                    // `window.beginFrame()` so the swapchain-vs-offscreen
                    // decision is made before sokol-gfx commits to either.
                    // Empty under non-Darwin targets (the block is
                    // comptime-gated on `_sokol_preview_metal_enabled`).
                    // GL (#124) and D3D11 (#126) keep their existing
                    // pre-endFrame slot — their readback model is a
                    // post-commit copy, not a render redirect.
                    .preview_pre_render = PREVIEW_PRE_RENDER_METAL_SOKOL,
                    .preview_readback = preview_readback_sokol,
                    // Path A (#131): the Metal block is part of the
                    // pre-endFrame readback now, so the post-endFrame
                    // hole is empty. Kept in the template so the
                    // placeholder still expands cleanly; retiring it
                    // entirely is a separate cleanup step.
                    .preview_readback_post = "",
                    .preview_cleanup = preview_cleanup_sokol,
                }, bw);
            } else {
                // Raylib wasm: emscripten-driven callback loop. Preview
                // setup runs once in main() before the loop is handed
                // to emscripten; heartbeats fire inside `gameFrame`.
                // No cleanup callback — emscripten keeps running after
                // main returns, and the editor reads EOF on tab close.
                //
                // Wasm-emscripten gate (labelle-assembler#141): preview
                // mode is useless in a browser tab, and the explicit
                // `std.Io.Threaded.init` in PREVIEW_INIT_CALLBACK pulls
                // the broken Zig 0.16 posix wrappers into the wasm exe
                // (Threaded.zig:15315 / emscripten.zig:215). Emit empty
                // strings on wasm. Both branches of this `if/else` land
                // on wasm in practice, but keep the gate explicit so
                // the intent is local.
                const is_wasm_raylib = cfg.platform == .wasm;
                try tpl.render(lifecycle_tmpl, .{
                    .width = w_str,
                    .height = h_str,
                    .title = cfg.title,
                    .fps = fps_str,
                    .setup_code = init_code,
                    .tick_code = tick_code,
                    .gui_draw_code = gui_draw_code,
                    .hidden_setup = hidden_setup,
                    .hooks_init_block = hooks_init,
                    .preview_setup = if (is_wasm_raylib) "" else PREVIEW_INIT_CALLBACK,
                    .preview_heartbeat = if (is_wasm_raylib) "" else PREVIEW_HEARTBEAT_CALLBACK,
                }, bw);
            }
        } else {
            const setup_code = try buildSetupCode(allocator, cfg, jsonc_scene_names, prefab_names);
            defer allocator.free(setup_code);

            // Raylib desktop gets the PBO async-readback block + the GL
            // externs that drive it (labelle-engine#544). The PoC at
            // imgui-preview-poc/src/game.zig is the reference shape.
            // Other loop backends (sdl/bgfx/wgpu) keep an empty readback
            // slot until their per-backend tickets land — sokol's readback
            // already runs through its own callback path. raylib WASM
            // takes the callback branch above, so this only fires for
            // raylib desktop.
            const is_raylib_desktop = cfg.backend == .raylib;
            // See gate rationale on the sokol-callback site above: dispatch
            // body declares imgui-specific externs, so non-imgui gui plugins
            // must take the stub branch.
            const input_dispatch: []const u8 = if (cfg.resolved_gui) |gui|
                (if (std.mem.eql(u8, gui.name, "imgui")) PREVIEW_INPUT_DISPATCH else PREVIEW_INPUT_DISPATCH_STUB)
            else
                PREVIEW_INPUT_DISPATCH_STUB;
            const module_vars_loop = if (is_raylib_desktop)
                try std.mem.concat(allocator, u8, &.{ PREVIEW_HELPERS, PREVIEW_READBACK_HELPERS, input_dispatch })
            else
                try std.mem.concat(allocator, u8, &.{ PREVIEW_HELPERS, input_dispatch });
            defer allocator.free(module_vars_loop);
            const preview_setup_loop = if (is_raylib_desktop)
                try std.mem.concat(allocator, u8, &.{ PREVIEW_LOOP_SETUP, PREVIEW_READBACK_SETUP })
            else
                PREVIEW_LOOP_SETUP;
            defer if (is_raylib_desktop) allocator.free(preview_setup_loop);
            const readback_block = if (is_raylib_desktop) PREVIEW_READBACK_LOOP else "";

            try tpl.render(lifecycle_tmpl, .{
                .width = w_str,
                .height = h_str,
                .title = cfg.title,
                .fps = fps_str,
                .setup_code = setup_code,
                .tick_code = tick_code,
                .gui_draw_code = gui_draw_code,
                .hidden_setup = hidden_setup,
                .hooks_init_block = hooks_init,
                .module_vars = module_vars_loop,
                // Preview-mode wiring (labelle-assembler#94). Always
                // emitted; runtime parse returns null when the flag is
                // absent so the block is a no-op for non-preview runs.
                .preview_setup = preview_setup_loop,
                .preview_heartbeat = PREVIEW_HEARTBEAT_LOOP,
                .preview_readback = readback_block,
            }, bw);
        }

        var arr_list_l = alloc_writer_b.toArrayList();
        const lifecycle = try arr_list_l.toOwnedSlice(allocator);
        try allocs.append(allocator, lifecycle);
        try data.scalars.put("lifecycle", lifecycle);
    }

    // ── Render the engine template ──
    var output_alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer output_alloc_writer.deinit();
    try tpl.renderDynamic(engine_template, data, &output_alloc_writer.writer);
    var output_arr_list = output_alloc_writer.toArrayList();
    return output_arr_list.toOwnedSlice(allocator);
}

/// Generate the GameLayers enum from project.labelle layer definitions.
fn generateGameLayers(layers: []const LayerDef, w: anytype) !void {
    try w.writeAll("const GameLayers = enum(u8) {\n");
    for (layers) |layer| {
        try w.print("    {s},\n", .{layer.name});
    }
    try w.writeAll("\n    pub fn config(self: GameLayers) gfx.LayerConfig {\n");
    try w.writeAll("        return switch (self) {\n");
    for (layers) |layer| {
        try w.print("            .{s} => .{{ .order = {d}, .space = .{s} }},\n", .{
            layer.name,
            layer.order,
            @tagName(layer.space),
        });
    }
    try w.writeAll("        };\n");
    try w.writeAll("    }\n");
    try w.writeAll("};\n");
}

/// Generate the ResourceRegistry from project.labelle resource definitions.
/// Each resource maps a name to a ComptimeAtlas loaded from a .zon frame file,
/// plus the texture path for the backend to load at runtime.
fn generateResourceRegistry(resources: []const ResourceDef, w: anytype) !void {
    try w.writeAll("const ResourceRegistry = struct {\n");
    for (resources) |res| {
        try w.print("    pub const {s} = engine.ComptimeAtlas(@import(\"{s}\"));\n", .{ res.name, res.json });
    }
    try w.writeAll("\n    pub const textures = .{\n");
    for (resources) |res| {
        try w.print("        .{s} = \"{s}\",\n", .{ res.name, res.texture });
    }
    try w.writeAll("    };\n");
    try w.print("\n    pub const names: [{d}][]const u8 = .{{\n", .{resources.len});
    for (resources) |res| {
        try w.print("        \"{s}\",\n", .{res.name});
    }
    try w.writeAll("    };\n");
    try w.writeAll("};\n");
}
