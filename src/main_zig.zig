/// main.zig generator — shared sections + backend lifecycle template rendering.
///
/// **Refactor in progress (labelle-assembler#183).** Discovery helpers
/// (`PluginEvent`, `PluginFlowDecls`, `discoverPluginEvents`,
/// `discoverPluginFlowDecls`, `sanitizePluginIdent`, `pathToIdent`, …)
/// now live in `src/codegen/scan.zig`. They are re-exported below so
/// `root.zig` and `test/tests.zig` can keep their existing imports
/// unchanged while the split lands incrementally. See
/// `docs/REFACTOR-PLAN-main-zig.md` for the full cut plan.
const std = @import("std");
const tpl = @import("template.zig");
const config = @import("config.zig");
const cache = @import("cache.zig");
const script_scanner = @import("script_scanner.zig");
const scene_manifest = @import("scene_manifest.zig");
const scan = @import("codegen/scan.zig");
const idents = @import("codegen/idents.zig");
pub const validate = @import("codegen/validate.zig");
pub const resource_loader = @import("codegen/blocks/resource_loader.zig");
pub const scene_manifests_block = @import("codegen/blocks/scene_manifests.zig");

const ProjectConfig = config.ProjectConfig;
const PluginDep = config.PluginDep;
const LayerDef = config.LayerDef;
const ResourceDef = config.ResourceDef;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;
const SceneManifest = scene_manifest.SceneManifest;

// ── Re-exports from src/codegen/scan.zig (refactor #183 PoC) ─────────
//
// These let `root.zig`, `test/tests.zig`, and any other in-tree caller
// keep their `@import("main_zig.zig").PluginEvent` / `.discoverPluginEvents`
// style imports working after the move. Pure aliases — no logic, no
// allocations, no behavior change. The orchestrator below also reaches
// the same names through `scan.*` to make the new dependency direction
// obvious.
pub const PluginEvent = scan.PluginEvent;
pub const PluginEvents = scan.PluginEvents;
pub const PluginFlowNode = scan.PluginFlowNode;
pub const PluginPinStyle = scan.PluginPinStyle;
pub const PluginCoercion = scan.PluginCoercion;
pub const PluginFlowDecls = scan.PluginFlowDecls;
pub const discoverPluginEvents = scan.discoverPluginEvents;
pub const discoverPluginFlowDecls = scan.discoverPluginFlowDecls;
pub const dedupePinStyles = scan.dedupePinStyles;

// `sanitizePluginIdent` and `pathToIdent` are private helpers that
// `main_zig.zig` still uses for the registry-block emitters living in
// this file. Aliasing them locally keeps every existing call site
// (`pathToIdent(name, &buf)`) unchanged — when those block writers
// move out in a later cut, this private alias goes with them.
const sanitizePluginIdent = scan.sanitizePluginIdent;
const pathToIdent = scan.pathToIdent;

// Identifier / string-emit helpers extracted to `src/codegen/idents.zig`
// in the second cut of the refactor (see docs/REFACTOR-PLAN-main-zig.md).
// Kept as private aliases so existing call sites in this file
// (`extWithoutDot(res.sound)`, `pathToPascal(name, &buf)`, …) don't
// have to be sprinkled with `idents.` prefixes; the new module file is
// the source of truth and these aliases vanish when each consuming
// block writer / validator moves out.
const extWithoutDot = idents.extWithoutDot;
const isValidZigIdentifier = idents.isValidZigIdentifier;
const writeZigString = idents.writeZigString;
const pathToPascal = idents.pathToPascal;

// Validation helpers extracted to `src/codegen/validate.zig` in the
// third cut of the refactor (see docs/REFACTOR-PLAN-main-zig.md).
// `checkBasenameCollisions`, `hasContextEntry`, and `validateResources`
// are pure validation passes — no template state, no codegen output —
// so they were the third low-risk move. Kept as private aliases here
// so the orchestrator call sites (`try validateResources(cfg)`, etc.)
// don't need `validate.` prefixes; the new module is the source of
// truth.
const checkBasenameCollisions = validate.checkBasenameCollisions;
const hasContextEntry = validate.hasContextEntry;
const validateResources = validate.validateResources;

// Scene-manifest block writers extracted to
// `src/codegen/blocks/scene_manifests.zig` per step 5 of the cut plan
// (see docs/REFACTOR-PLAN-main-zig.md, labelle-assembler#183). The
// module is re-exported above as `scene_manifests_block` so external
// callers can reach it through main_zig; these private aliases preserve
// the existing call shape inside the orchestrator without sprinkling
// `scene_manifests_block.` prefixes.
const writeSceneAssetManifests = scene_manifests_block.writeSceneAssetManifests;
const writeSceneInitialStateManifests = scene_manifests_block.writeSceneInitialStateManifests;

// Resource-loader emit moved to `src/codegen/blocks/resource_loader.zig`
// in step 5b of the refactor (see docs/REFACTOR-PLAN-main-zig.md).
// `emitResourceLoad` is reached from BOTH lifecycle paths
// (`buildSetupCode` with `.try_style`, the sokol callback init builder
// with `.catch_panic_style`); the public re-export above and the local
// aliases below keep both call sites unchanged while the lifecycle
// builders still live in this file.
pub const LoadStyle = resource_loader.LoadStyle;
pub const emitResourceLoad = resource_loader.emitResourceLoad;

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

/// Emit the `PluginEvents` tagged union (RFC-PLUGIN-EVENTS phase 1).
///
/// Plugin events are discovered **at assembler time** by parsing each
/// plugin's `src/root.zig` AST (see `discoverPluginEvents`) and folding
/// every `pub const <name> = struct` inside the plugin's top-level
/// `pub const Events = struct { … }` into a union variant with a
/// plugin-qualified tag (`<plugin>__<event>`). `.` is not a valid Zig
/// identifier character, so the on-disk JSONC dot form
/// (`box2d.collision_begin`) resolves to the qualified tag
/// (`box2d__collision_begin`) when flow-codegen consumes this in
/// phase 3.
///
/// Why a literal `union(enum) { … }` rather than the comptime
/// `@Union(.auto, …)` builtin: `@Union` with zero fields returns an
/// "uninstantiable" type. `std.ArrayList(T)`'s deinit path does
/// `@memset(self.items, undefined)`, which the 0.16 compiler rejects
/// for uninstantiable unions ("cannot coerce to uninstantiable type").
/// That manifests as the plugin-controllers CI failure on every
/// post-`9f8c5fc` commit. Writing the union out as source bypasses the
/// builtin entirely and, in the empty-discovery case, we emit `void`
/// instead (the engine's `has_events = GameEvents != void` gate then
/// elides the event buffer at type level).
///
/// Plugins without a `pub const Events` struct contribute zero
/// entries — that's the back-compat path every existing plugin
/// (labelle-fsm, labelle-pathfinding, the demo plugin) takes.
///
/// The plugin "name" prefix is the same string used in
/// `@import("<name>")` (project.labelle's `.plugins[].name`),
/// sanitized to a valid Zig identifier — non-`[A-Za-z0-9_]` bytes
/// collapse to `_`. Two plugins whose sanitized name collide would
/// produce duplicate variant names, which Zig rejects at the union
/// declaration itself.
pub fn writePluginEventsBlock(bw: anytype, plugin_events: []const PluginEvent) !void {
    try bw.writeAll("// --- Plugin events (RFC-PLUGIN-EVENTS phase 1) ---\n");
    try bw.writeAll("// Discovered at assembler time from `pub const Events` on each\n");
    try bw.writeAll("// plugin's `src/root.zig` — same convention as the comptime walk\n");
    try bw.writeAll("// (Components/Systems/GizmoCategories) but materialised statically\n");
    try bw.writeAll("// so the union is a real source-level type (the comptime `@Union`\n");
    try bw.writeAll("// builtin's zero-field result is uninstantiable in std.ArrayList).\n");
    try bw.writeAll("// Variant tag = `<plugin>__<event>` so a flow's dotted name\n");
    try bw.writeAll("// (`box2d.collision_begin`) maps to a Zig identifier.\n");
    if (plugin_events.len == 0) {
        // No plugin contributed an `Events` decl — emit `void` and let
        // `has_events = GameEvents != void` elide the event buffer.
        try bw.writeAll("pub const PluginEvents = void;\n\n");
        return;
    }
    try bw.writeAll("pub const PluginEvents = union(enum) {\n");
    for (plugin_events) |e| {
        // The engine is discovered alongside plugins (labelle-engine
        // #578) but its Zig module name is `labelle-engine`, not
        // `engine` (the latter is just the dotted-form prefix used in
        // the qualified variant tag and on-disk JSONC names). Special-
        // case the resolver so `@import("...").Events.<name>` lands on
        // the right module. Plugins keep their identity-mapped name.
        const import_name = if (std.mem.eql(u8, e.plugin_import_name, "engine"))
            "labelle-engine"
        else
            e.plugin_import_name;
        try bw.print(
            "    {s}__{s}: @import(\"{s}\").Events.{s},\n",
            .{ e.plugin_sanitized, e.event_name, import_name, e.event_name },
        );
    }
    try bw.writeAll("};\n\n");
}

/// Emit the `PluginFlowNodes` registry (RFC-FLOW-VOCABULARY phase 2).
///
/// One `pub const <module>__<name>` entry per discovered FlowNode,
/// aliased to the source-module decl so all metadata (display_name,
/// category, docs, kind, pins) **and** the `impl` comptime decl
/// survive intact for downstream reflection. Plugins and game
/// scripts use different `@import` forms — plugins resolve as
/// `@import("<plugin>")`, game scripts as `@import("scripts/<rel>")`.
///
/// Plus a comptime `resolve` decl: given a dotted name like
/// `"box2d.apply_impulse"`, returns the canonical qualified field
/// name (`"box2d__apply_impulse"`) and a `@hasDecl(PluginFlowNodes,
/// resolved)` check confirms membership. Mechanism mirrors how
/// flow-codegen's RFC-PLUGIN-EVENTS phase 3 resolver looked up event
/// names via `@FieldType(game.PluginEvents, "<tag>")`. Callers do
/// `@field(PluginFlowNodes, resolved)` to reach the entry value.
///
/// Empty discovery (no plugins/game scripts declare `FlowNodes`)
/// emits a `void`-equivalent: an empty `struct {}` with a stub
/// `resolve` that always returns `null`, so flow-codegen's eventual
/// `CustomNode` lowering doesn't need a separate empty-case branch.
pub fn writePluginFlowNodesBlock(bw: anytype, flow_nodes: []const PluginFlowNode) !void {
    try bw.writeAll("// --- Plugin flow nodes (RFC-FLOW-VOCABULARY phase 2) ---\n");
    try bw.writeAll("// Discovered at assembler time from `pub const FlowNodes` on each\n");
    try bw.writeAll("// plugin's `src/root.zig` AND each game-script module under\n");
    try bw.writeAll("// `scripts/` (RFC §5: any module exporting FlowNodes contributes).\n");
    try bw.writeAll("// Each entry aliases the source decl directly so the FlowNode\n");
    try bw.writeAll("// factory's metadata + `impl` comptime decl pass through to\n");
    try bw.writeAll("// downstream consumers (flow-codegen `CustomNode` lowering in\n");
    try bw.writeAll("// phase 3, labelle-gui palette UI in phase 4).\n");
    try bw.writeAll("pub const PluginFlowNodes = struct {\n");
    for (flow_nodes) |fn_| {
        // RFC-FLOW-VOCABULARY §1 / O5 — surface the captured `.constructs`
        // hint as a doc-comment above the alias. The alias itself carries
        // the value through the FlowNode factory's struct field, so
        // downstream consumers can also read it via reflection
        // (`PluginFlowNodes.<qualified>.constructs`); the comment is a
        // human-readable signal for anyone reading the generated file.
        if (fn_.constructs) |c| {
            try bw.print("    /// constructs: {s}\n", .{c});
        }
        if (fn_.is_script) {
            try bw.print(
                "    pub const {s}__{s} = @import(\"scripts/{s}\").FlowNodes.{s};\n",
                .{ fn_.module_sanitized, fn_.node_name, fn_.module_import_path, fn_.node_name },
            );
        } else {
            try bw.print(
                "    pub const {s}__{s} = @import(\"{s}\").FlowNodes.{s};\n",
                .{ fn_.module_sanitized, fn_.node_name, fn_.module_import_path, fn_.node_name },
            );
        }
    }
    // Name resolver — emitted unconditionally so callers can use a
    // single canonical entry point regardless of whether discovery
    // found anything. The implementation matches what
    // RFC-PLUGIN-EVENTS used for event-name resolution: split the
    // dotted form on `.`, swap to `__`, return the joined identifier
    // when it names a public decl on `PluginFlowNodes`. Pure comptime
    // — flow-codegen calls this during `CustomNode` lowering.
    try bw.writeAll("\n");
    try bw.writeAll("    /// Comptime name resolver for flow-codegen's `CustomNode`\n");
    try bw.writeAll("    /// lowering. Given a dotted node name (`\"box2d.apply_impulse\"`),\n");
    try bw.writeAll("    /// returns the canonical qualified identifier\n");
    try bw.writeAll("    /// (`\"box2d__apply_impulse\"`) iff a matching decl exists on\n");
    try bw.writeAll("    /// this struct, else `null`. Callers reach the entry value via\n");
    try bw.writeAll("    /// `@field(PluginFlowNodes, resolved)`.\n");
    try bw.writeAll("    pub fn resolve(comptime dotted: []const u8) ?[]const u8 {\n");
    try bw.writeAll("        const dot = std.mem.indexOfScalar(u8, dotted, '.') orelse return null;\n");
    try bw.writeAll("        const module = dotted[0..dot];\n");
    try bw.writeAll("        const node = dotted[dot + 1 ..];\n");
    try bw.writeAll("        if (node.len == 0) return null;\n");
    try bw.writeAll("        const qualified = module ++ \"__\" ++ node;\n");
    try bw.writeAll("        if (!@hasDecl(@This(), qualified)) return null;\n");
    try bw.writeAll("        return qualified;\n");
    try bw.writeAll("    }\n");
    try bw.writeAll("};\n\n");
}

/// Emit the `PluginPinStyles` registry (RFC-FLOW-VOCABULARY phase 2).
///
/// One `pub const <TypeName>` entry per discovered `PinStyle`, aliased
/// to the source-module decl. Keyed by the Zig **type name** (e.g.
/// `BodyId`), so two plugins both declaring a `BodyId` style would
/// emit duplicate decls — the assembler deduplicates upstream
/// (last-write-wins, matching the RFC §1 contract) so the emitted
/// block has at most one entry per type name.
///
/// Empty discovery emits an empty `struct { }` — same shape as the
/// populated case so callers can iterate `@typeInfo(PluginPinStyles)`
/// uniformly. The editor layers these on top of `default_pin_styles`
/// (which already ship in `labelle-core`), so an empty plugin-side
/// registry just means "no per-type overrides beyond the defaults".
pub fn writePluginPinStylesBlock(bw: anytype, pin_styles: []const PluginPinStyle) !void {
    try bw.writeAll("// --- Plugin pin styles (RFC-FLOW-VOCABULARY phase 2) ---\n");
    try bw.writeAll("// Discovered at assembler time from `pub const PinStyles` on each\n");
    try bw.writeAll("// plugin's `src/root.zig` AND each game-script module under\n");
    try bw.writeAll("// `scripts/`. The editor layers these on top of\n");
    try bw.writeAll("// `labelle-core`'s `default_pin_styles` (primitives + EntityId).\n");
    try bw.writeAll("// Keyed by Zig type name; duplicates across modules are deduped\n");
    try bw.writeAll("// last-write-wins by the assembler before emission, matching\n");
    try bw.writeAll("// the RFC §1 contract.\n");
    try bw.writeAll("pub const PluginPinStyles = struct {\n");
    for (pin_styles) |ps| {
        if (ps.is_script) {
            try bw.print(
                "    pub const {s} = @import(\"scripts/{s}\").PinStyles.{s};\n",
                .{ ps.type_name, ps.module_import_path, ps.type_name },
            );
        } else {
            try bw.print(
                "    pub const {s} = @import(\"{s}\").PinStyles.{s};\n",
                .{ ps.type_name, ps.module_import_path, ps.type_name },
            );
        }
    }
    try bw.writeAll("};\n\n");
}

/// Emit the `PluginCoercions` registry (RFC-FLOW-VOCABULARY §2 / O4).
///
/// One `pub const <module>__<name>` entry per discovered Coercion,
/// aliased to the source-module decl so the `From` / `To` types and
/// the `convert` function survive reflection. Plugins and game
/// scripts use different `@import` forms — plugins resolve as
/// `@import("<plugin>")`, game scripts as `@import("scripts/<rel>")`.
///
/// Plus a comptime `resolve` decl: given a dotted name like
/// `"box2d.body_to_entity"`, returns the canonical qualified field
/// name (`"box2d__body_to_entity"`) and a `@hasDecl(PluginCoercions,
/// resolved)` check confirms membership. Same shape as
/// `PluginFlowNodes.resolve`.
///
/// Plus a comptime `findByTypes(From, To)` helper: scans the registry
/// for an entry whose `From` and `To` match the given types and
/// returns its qualified name (or `null`). flow-codegen consumes this
/// at edge emission to decide whether to wrap an expression in a
/// `<plugin>__<name>.convert(...)` call.
///
/// Empty discovery (no plugins/game scripts declare `Coercions`)
/// emits a `struct {}` with the stub helpers, so downstream
/// reflection doesn't need an empty-case branch.
pub fn writePluginCoercionsBlock(bw: anytype, coercions: []const PluginCoercion) !void {
    try bw.writeAll("// --- Plugin coercions (RFC-FLOW-VOCABULARY §2 / O4) ---\n");
    try bw.writeAll("// Discovered at assembler time from `pub const Coercions` on each\n");
    try bw.writeAll("// plugin's `src/root.zig` AND each game-script module under\n");
    try bw.writeAll("// `scripts/`. Each entry aliases the source decl directly so the\n");
    try bw.writeAll("// `From` / `To` comptime decls + `convert` function pass through\n");
    try bw.writeAll("// to flow-codegen's edge-wrap path (it consults `findByTypes` to\n");
    try bw.writeAll("// decide when to wrap an expression in `<qualified>.convert(...)`).\n");
    try bw.writeAll("pub const PluginCoercions = struct {\n");
    for (coercions) |co| {
        if (co.is_script) {
            try bw.print(
                "    pub const {s}__{s} = @import(\"scripts/{s}\").Coercions.{s};\n",
                .{ co.module_sanitized, co.name, co.module_import_path, co.name },
            );
        } else {
            try bw.print(
                "    pub const {s}__{s} = @import(\"{s}\").Coercions.{s};\n",
                .{ co.module_sanitized, co.name, co.module_import_path, co.name },
            );
        }
    }
    // Name resolver — same shape as `PluginFlowNodes.resolve` so flow-codegen's
    // CustomNode lowering and coercion wrap path share an identical pattern.
    try bw.writeAll("\n");
    try bw.writeAll("    /// Comptime name resolver — given a dotted coercion name\n");
    try bw.writeAll("    /// (`\"box2d.body_to_entity\"`), returns the canonical qualified\n");
    try bw.writeAll("    /// identifier (`\"box2d__body_to_entity\"`) iff a matching decl\n");
    try bw.writeAll("    /// exists on this struct, else `null`. Callers reach the entry\n");
    try bw.writeAll("    /// value via `@field(PluginCoercions, resolved)`.\n");
    try bw.writeAll("    pub fn resolve(comptime dotted: []const u8) ?[]const u8 {\n");
    try bw.writeAll("        const dot = std.mem.indexOfScalar(u8, dotted, '.') orelse return null;\n");
    try bw.writeAll("        const module = dotted[0..dot];\n");
    try bw.writeAll("        const name = dotted[dot + 1 ..];\n");
    try bw.writeAll("        if (name.len == 0) return null;\n");
    try bw.writeAll("        const qualified = module ++ \"__\" ++ name;\n");
    try bw.writeAll("        if (!@hasDecl(@This(), qualified)) return null;\n");
    try bw.writeAll("        return qualified;\n");
    try bw.writeAll("    }\n");
    // Type-keyed lookup — the wire-fit rule asks "is there a coercion for
    // (From, To)?". Scans all decls at comptime; tiny registries (≤ dozens)
    // mean linear walk is the right shape.
    try bw.writeAll("\n");
    try bw.writeAll("    /// Comptime type-keyed lookup — scans every entry on this\n");
    try bw.writeAll("    /// struct for one whose `.From == From` and `.To == To`. Returns\n");
    try bw.writeAll("    /// its qualified decl name (the same string `resolve` would\n");
    try bw.writeAll("    /// return) when found, else `null`. flow-codegen calls this at\n");
    try bw.writeAll("    /// edge-emission time to decide whether a wire across mismatched\n");
    try bw.writeAll("    /// types is accepted via a declared coercion (RFC §2 rule 3).\n");
    try bw.writeAll("    pub fn findByTypes(comptime From: type, comptime To: type) ?[]const u8 {\n");
    try bw.writeAll("        const decls = @typeInfo(@This()).@\"struct\".decls;\n");
    try bw.writeAll("        inline for (decls) |d| {\n");
    try bw.writeAll("            const entry = @field(@This(), d.name);\n");
    try bw.writeAll("            const ET = @TypeOf(entry);\n");
    try bw.writeAll("            // Skip non-coercion decls (e.g. the resolve/findByTypes fns\n");
    try bw.writeAll("            // themselves and any future helpers). A coercion entry is a\n");
    try bw.writeAll("            // struct value carrying the `__is_labelle_coercion` marker;\n");
    try bw.writeAll("            // anything else (functions, plain ints, etc.) is filtered.\n");
    try bw.writeAll("            if (@typeInfo(ET) != .@\"struct\") continue;\n");
    try bw.writeAll("            if (!@hasDecl(ET, \"__is_labelle_coercion\")) continue;\n");
    try bw.writeAll("            if (ET.From == From and ET.To == To) return d.name;\n");
    try bw.writeAll("        }\n");
    try bw.writeAll("        return null;\n");
    try bw.writeAll("    }\n");
    try bw.writeAll("};\n\n");
}


/// Build the setup code block for {{setup_code}} (loop-based backends).
//
// `LoadStyle` + `emitResourceLoad` were moved to
// `src/codegen/blocks/resource_loader.zig` in step 5b of the refactor
// (see docs/REFACTOR-PLAN-main-zig.md). Re-exported as `pub` above so
// `root.zig` / `test/tests.zig` keep their existing imports, and
// aliased privately so both lifecycle callers (`buildSetupCode` below
// and the sokol callback init builder later in this file) continue to
// reference the unqualified names.

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

    // ── No Android immersive-mode call here (intentional) ────────────
    //
    // `buildCallbackInitCode` emits `engine.android.enableImmersiveMode()`
    // for Android projects, but `buildSetupCode` does NOT — and that is
    // correct, not an omission. `buildSetupCode` only ever runs for the
    // loop-based backends (raylib, sdl, bgfx, wgpu), and NONE of those
    // can target Android: Android is sokol-only. The only Android
    // backend template that exists is `backends/sokol/templates/
    // mobile.txt`; the loop-based backends ship `desktop.txt` (and
    // raylib also `wasm.txt`) and have no `android.txt`, so
    // `loadBackendTemplate` (see `root.zig`, which maps a non-sokol
    // Android config to a missing `android.txt`) fails with
    // `error.TemplateNotFound` before codegen ever reaches this
    // function. Emitting the immersive call here would therefore be
    // dead code that can never run on an Android target.

    var arr_list = alloc_writer.toArrayList();
    return arr_list.toOwnedSlice(allocator);
}

// ============================================================
// Preview-mode codegen (PIE Phase 1, labelle-assembler#94)
// ============================================================
//
// All `PREVIEW_*` string-literal templates + the wasm panic
// workaround were extracted to `src/codegen/preview.zig` in the
// preview cut of refactor #183. Re-exported here so the orchestrator
// below (and the in-tree caller via re-export through `main_zig.zig`)
// keeps every existing reference (`try bw.writeAll(WASM_PANIC_WORKAROUND)`,
// `try std.mem.concat(allocator, u8, &.{ ..., PREVIEW_HELPERS, ... })`)
// byte-identical. Pure aliases — no logic, no allocations.
const preview = @import("codegen/preview.zig");
pub const WASM_PANIC_WORKAROUND = preview.WASM_PANIC_WORKAROUND;
pub const PREVIEW_HELPERS = preview.PREVIEW_HELPERS;
pub const PREVIEW_READBACK_HELPERS = preview.PREVIEW_READBACK_HELPERS;
pub const PREVIEW_LOOP_SETUP = preview.PREVIEW_LOOP_SETUP;
pub const PREVIEW_READBACK_SETUP = preview.PREVIEW_READBACK_SETUP;
pub const PREVIEW_HEARTBEAT_LOOP = preview.PREVIEW_HEARTBEAT_LOOP;
pub const PREVIEW_INPUT_DISPATCH = preview.PREVIEW_INPUT_DISPATCH;
pub const PREVIEW_INPUT_DISPATCH_STUB = preview.PREVIEW_INPUT_DISPATCH_STUB;
pub const PREVIEW_READBACK_LOOP = preview.PREVIEW_READBACK_LOOP;
pub const PREVIEW_INIT_CALLBACK = preview.PREVIEW_INIT_CALLBACK;
pub const PREVIEW_CLEANUP_CALLBACK = preview.PREVIEW_CLEANUP_CALLBACK;
pub const PREVIEW_HEARTBEAT_CALLBACK = preview.PREVIEW_HEARTBEAT_CALLBACK;
pub const PREVIEW_READBACK_HELPERS_SOKOL = preview.PREVIEW_READBACK_HELPERS_SOKOL;
pub const PREVIEW_READBACK_INIT_SOKOL = preview.PREVIEW_READBACK_INIT_SOKOL;
pub const PREVIEW_READBACK_FRAME_SOKOL = preview.PREVIEW_READBACK_FRAME_SOKOL;
pub const PREVIEW_READBACK_CLEANUP_SOKOL = preview.PREVIEW_READBACK_CLEANUP_SOKOL;
pub const PREVIEW_READBACK_HELPERS_SOKOL_D3D11 = preview.PREVIEW_READBACK_HELPERS_SOKOL_D3D11;
pub const PREVIEW_READBACK_HELPERS_METAL_SOKOL = preview.PREVIEW_READBACK_HELPERS_METAL_SOKOL;
pub const PREVIEW_READBACK_INIT_SOKOL_D3D11 = preview.PREVIEW_READBACK_INIT_SOKOL_D3D11;
pub const PREVIEW_READBACK_INIT_METAL_SOKOL = preview.PREVIEW_READBACK_INIT_METAL_SOKOL;
pub const PREVIEW_READBACK_FRAME_SOKOL_D3D11 = preview.PREVIEW_READBACK_FRAME_SOKOL_D3D11;
pub const PREVIEW_PRE_RENDER_METAL_SOKOL = preview.PREVIEW_PRE_RENDER_METAL_SOKOL;
pub const PREVIEW_READBACK_FRAME_METAL_SOKOL = preview.PREVIEW_READBACK_FRAME_METAL_SOKOL;
pub const PREVIEW_READBACK_CLEANUP_SOKOL_D3D11 = preview.PREVIEW_READBACK_CLEANUP_SOKOL_D3D11;
pub const PREVIEW_READBACK_CLEANUP_METAL_SOKOL = preview.PREVIEW_READBACK_CLEANUP_METAL_SOKOL;

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

    // ── Android immersive mode ──────────────────────────────────────
    //
    // The `engine.android.enableImmersiveMode()` call is NOT emitted
    // here. It must run on the Android UI thread, which the render-
    // thread `init` callback is not — so it is emitted into
    // `sokol_main()` instead (see `buildImmersiveEntryCode`). The
    // `init` callback runs too late to catch the window's first
    // `onWindowFocusChanged`, which is why the bars used to stay
    // visible until the first background+foreground cycle.

    var arr_list = alloc_writer.toArrayList();
    return arr_list.toOwnedSlice(allocator);
}

/// Body for the `{{immersive_entry}}` hole in the sokol `mobile.txt`
/// template — the `engine.android.enableImmersiveMode()` call, emitted
/// inside `sokol_main()`.
///
/// **Why `sokol_main()` and not `init()`:** the legacy
/// `Theme.NoTitleBar.Fullscreen` manifest theme `labelle-cli` writes
/// does NOT hide the system bars on modern Android (verified broken on
/// Android 14 / API 34) — Google moved system-bar control to a runtime
/// API. `enableImmersiveMode()` installs a UI-thread callback hook that
/// performs that runtime JNI call.
///
/// sokol's `ANativeActivity_onCreate` invokes `sokol_main()` on the
/// **UI thread**, before it registers its own `ANativeActivityCallbacks`
/// — early enough that the hook fires at launch. The `init()` callback,
/// by contrast, runs on sokol's render thread *after* the window's
/// first `onWindowFocusChanged`; a hook installed there misses that
/// first focus event, leaving the bars visible until the player
/// background+foregrounds the app. See `labelle-engine/src/android.zig`.
///
/// Returns an empty string unless the target is Android with
/// `.android = .{ .immersive_mode = true }`; the placeholder then
/// expands to nothing (and is harmless in the shared sokol desktop /
/// wasm `desktop.txt`, which has no `{{immersive_entry}}` hole at all).
fn buildImmersiveEntryCode(allocator: std.mem.Allocator, cfg: ProjectConfig) ![]const u8 {
    if (cfg.platform != .android) return allocator.dupe(u8, "");
    const immersive = if (cfg.android) |a| a.immersive_mode else false;
    if (!immersive) return allocator.dupe(u8, "");
    return allocator.dupe(u8,
        \\    // Android immersive mode (project.labelle `.android.immersive_mode`):
        \\    // hide the status + navigation bars (immersive-sticky). Called from
        \\    // `sokol_main()` — the UI thread, before sokol registers its own
        \\    // ANativeActivity callbacks — so the hook catches the window's
        \\    // first focus and the bars are hidden at launch. The helper only
        \\    // installs a UI-thread callback hook; the JNI decor-view call runs
        \\    // on the UI thread. See labelle-engine src/android.zig.
        \\    engine.android.enableImmersiveMode();
        \\
    );
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
    plugin_events: []const PluginEvent,
    // RFC-FLOW-VOCABULARY phase 2 — discovered FlowNodes/PinStyles from
    // plugin AND game-script modules. Both lists may be empty; the
    // emitter writes a `PluginFlowNodes = struct {}` / `PluginPinStyles
    // = struct {}` shell either way so downstream code paths
    // (flow-codegen phase 3, labelle-gui phase 4) can reflect uniformly.
    plugin_flow_nodes: []const PluginFlowNode,
    plugin_pin_styles: []const PluginPinStyle,
    /// RFC-FLOW-VOCABULARY §2 / O4 — plugin-declared coercions. Same
    /// shape contract as `plugin_flow_nodes` / `plugin_pin_styles`:
    /// emitter writes a `PluginCoercions = struct {}` shell when this
    /// slice is empty so downstream comptime reflection (flow-codegen
    /// edge wrap, labelle-gui wire-fit check) stays uniform.
    plugin_coercions: []const PluginCoercion,
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

    // Track allocations for cleanup. Capacity is reserved up front for
    // every `appendAssumeCapacity` call site below — each emitted block
    // is appended at most once, so reserving the literal call-site count
    // is a safe upper bound. Reserving makes the appends infallible,
    // closing the OOM window where a `toOwnedSlice`'d block is owned but
    // not yet in this cleanup list (errdefer audit, #75).
    const ALLOCS_BLOCK_COUNT = 18;
    var allocs: std.ArrayList([]const u8) = .empty;
    defer {
        for (allocs.items) |s| allocator.free(s);
        allocs.deinit(allocator);
    }
    try allocs.ensureTotalCapacity(allocator, ALLOCS_BLOCK_COUNT);

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
        allocs.appendAssumeCapacity(block);
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
        allocs.appendAssumeCapacity(block);
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
        allocs.appendAssumeCapacity(block);
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
        allocs.appendAssumeCapacity(block);
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
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("game_layers_block", block);
    }

    // Resource registry block
    // Resource registry block — resources are now loaded at runtime via
    // @embedFile + loadAtlasFromMemory, so the comptime registry is empty.
    // The block is kept as an empty string for template compatibility.
    {
        const block = try allocator.dupe(u8, "");
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("resource_registry_block", block);
    }

    // AllHookPayloads block — merge engine payloads with game events
    // (`events/*.zig` scan, labelle-engine#422) and plugin events
    // (`pub const Events` on plugin modules, RFC-PLUGIN-EVENTS phase 1).
    // PluginEvents is always a union (possibly empty) when any plugin
    // exists, so it can sit inside the same `MergeHookPayloads` call —
    // game events stay on the same merged `AllHookPayloads` (no parallel
    // dispatcher, per RFC §2 "feed the existing pipeline").
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        // Gate on **discovered** events, not declared plugins — a project
        // can declare a plugin whose `Events` decl is empty (or absent, e.g.
        // the plugin-controllers demo plugin), in which case `PluginEvents`
        // is emitted as `void` and must NOT be folded into `GameEvents`
        // (`MergeHookPayloads` rejects `void` operands).
        const has_plugin_events = plugin_events.len > 0;
        // When plugins declare events, the assembler emits a widened
        // `GameEvents` that already folds in `PluginEvents` (see the
        // game_events_block emission below). So `AllHookPayloads` only
        // needs to merge `GameEvents` once — referencing `PluginEvents`
        // here too would re-emit every plugin variant twice and trip
        // `MergeHookPayloads`' duplicate-field check.
        if (event_names.len == 0 and !has_plugin_events) {
            try bw.writeAll("const AllHookPayloads = engine.HookPayload(EcsBackend.Entity);\n\n");
        } else {
            try bw.writeAll("const AllHookPayloads = engine.core.MergeHookPayloads(.{ engine.HookPayload(EcsBackend.Entity)");
            if (event_names.len > 0 or has_plugin_events) try bw.writeAll(", GameEvents");
            try bw.writeAll(" });\n\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("all_hook_payloads_block", block);
    }

    // Count + collect new-form flow handlers (RFC-PLUGIN-EVENTS phase 4,
    // labelle-assembler#175). flow-codegen emits `pub const FlowEventHandler`
    // for new-form `OnEvent` flows; flow_scanner flips
    // `ScriptEntry.has_event_handler` on those. We thread them into the
    // existing `GameHooks` receiver tuple — by default in the
    // scanner-sorted order `script_entries` arrives in
    // (numeric-prefix-then-alphabetical; `flow_scanner.zig:220-232`, O3
    // in the RFC).
    //
    // **Phase 7 layering (RFC-PLUGIN-EVENTS O4 / labelle-core#16).** A
    // flow listening to a consumable event sets `priority` in its
    // `.flow.jsonc`; `flow_scanner` lifts that onto
    // `ScriptEntry.event_priority`. Flows with a priority sort to the
    // front of the flow tail, priority descending; the rest stay on the
    // scanner sort. The runtime `MergeHooks.emit`
    // (`labelle-core/src/dispatcher.zig`) switches to the return-aware
    // path automatically when the variant's payload declares
    // `pub const consumable = true`, breaking the loop on the first
    // handler that returns `true` — so the highest-priority consumer
    // wins, which is the contract phase 7 promises.
    //
    // **Sort scope — whole flow tail, not per-event.** A single flow
    // handler struct currently subscribes to exactly one event (one
    // `OnEvent` per `.flow.jsonc`), but the assembler-side sort is
    // over the **whole flow tail**, not partitioned per event. The
    // reason: priority is only meaningful for consumable events, and a
    // notification handler's relative position in the tail doesn't
    // affect dispatch correctness (every notification listener runs
    // regardless of order). Front-loading the priority-set flows ahead
    // of notification flows is the simplest scope that satisfies the
    // consumable-flavor contract without re-keying the tuple by event
    // tag. If a future flow listens to multiple events (one consumable,
    // one notification, with different priorities each), the
    // single-priority shape no longer fits — that's the day a per-event
    // sort becomes load-bearing; not now.
    //
    // The handler module is referenced via an inline `@import("scripts/<rel_path>")`
    // because `AllScripts` (which holds these imports under stable
    // identifiers) is declared *after* `GameHooks` in the template
    // (`labelle-engine/codegen/main.zig.template:20` vs `:35`), so we
    // can't borrow the alias. Spelling the import inline keeps the
    // wiring local to these two blocks without adding a new template
    // slot ahead of `game_hooks_block`. An ident derived from `rel_path`
    // names the per-handler `var` declaration in `hooks_init_block`.
    var flow_handler_count: usize = 0;
    for (script_entries) |entry| {
        if (entry.has_event_handler) flow_handler_count += 1;
    }

    // Priority-aware ordering of the flow tail. The list holds indices
    // into `script_entries` for every entry with
    // `has_event_handler == true`, in the order the receiver tuple
    // must emit them: priority-set entries first (descending), then
    // the rest in scanner order. A stable sort on (priority bucket,
    // scanner index) keeps everything deterministic — the input is
    // already in scanner order, so the tie-breaker is just "preserve
    // relative position".
    var flow_order: std.ArrayList(usize) = .empty;
    defer flow_order.deinit(allocator);
    try flow_order.ensureTotalCapacity(allocator, flow_handler_count);
    for (script_entries, 0..) |entry, i| {
        if (entry.has_event_handler) flow_order.appendAssumeCapacity(i);
    }
    const FlowSortCtx = struct {
        entries: []const ScriptEntry,
        fn lessThan(self: @This(), a: usize, b: usize) bool {
            const ea = self.entries[a];
            const eb = self.entries[b];
            // Priority-set entries strictly precede priority-null
            // entries; among priority-set entries, higher value first.
            if (ea.event_priority != null and eb.event_priority == null) return true;
            if (ea.event_priority == null and eb.event_priority != null) return false;
            if (ea.event_priority) |pa| {
                if (eb.event_priority) |pb| {
                    if (pa != pb) return pa > pb;
                }
            }
            // Same bucket: preserve the input scanner-sort order.
            return a < b;
        }
    };
    std.mem.sort(usize, flow_order.items, FlowSortCtx{ .entries = script_entries }, FlowSortCtx.lessThan);

    // Game hooks block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (hook_names.len == 0 and flow_handler_count == 0) {
            try bw.writeAll("const GameHooks = struct {};\n\n");
        } else {
            var pascal_buf: [128]u8 = undefined;
            try bw.writeAll("const GameHooks = engine.MergeHooks(AllHookPayloads, .{");
            for (hook_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                const pascal = pathToPascal(name, &pascal_buf);
                try bw.print(" *{s}.{s},", .{ ident, pascal });
            }
            // Flow handler receiver types — appended after hooks so the
            // scanner sort (flows-among-flows) sits inside a single
            // tail block, leaving the existing hook order at the head
            // unchanged. `rel_path` is e.g. `flows/hit_counter.zig`,
            // matching the on-disk layout the `AllScripts` block already
            // imports. Iteration order is `flow_order` — priority-set
            // flows first (desc), then scanner-sorted notification flows.
            for (flow_order.items) |i| {
                const entry = script_entries[i];
                try bw.print(" *@import(\"scripts/{s}\").FlowEventHandler,", .{entry.rel_path});
            }
            try bw.writeAll(" });\n\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("game_hooks_block", block);
    }

    // Hooks init block — instantiate individual hooks and wire into GameHooks
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (hook_names.len == 0 and flow_handler_count == 0) {
            try bw.writeAll("    var hooks = GameHooks{};\n");
        } else {
            var pascal_buf: [128]u8 = undefined;
            for (hook_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                const pascal = pathToPascal(name, &pascal_buf);
                try bw.print("    var {s}_inst = {s}.{s}{{}};\n", .{ ident, ident, pascal });
            }
            // Materialise each flow handler so it has a stable address
            // the `&` operator can produce a pointer to. `pathToIdent`
            // makes the `rel_path` injective into the Zig identifier
            // namespace (issue #173), so multiple flows in subdirs
            // can't collide on the same `<ident>_flow_handler` name.
            // `setHooks` walks the receiver tuple and injects
            // `*AssembledGame` into `game_ptr` for every receiver that
            // declares such a field (`labelle-engine/src/game.zig:419-429`),
            // so no extra init step is needed here — the existing walk
            // reaches these entries the same way it does the hook ones.
            //
            // Note: the `var` decls below can be emitted in any order
            // (each one names a unique identifier) but we follow
            // `flow_order` for clean diff-readability — the `var`s
            // appear in the same order their `&` references will inside
            // the tuple literal.
            for (flow_order.items) |i| {
                const entry = script_entries[i];
                const ident = pathToIdent(entry.rel_path, &ident_buf);
                try bw.print(
                    "    var {s}_flow_handler: @import(\"scripts/{s}\").FlowEventHandler = .{{}};\n",
                    .{ ident, entry.rel_path },
                );
            }
            try bw.writeAll("    var hooks = GameHooks{ .receivers = .{");
            for (hook_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print(" &{s}_inst,", .{ident});
            }
            // The tuple-literal order MUST match the receiver-type
            // order in `GameHooks` above — `MergeHooks.emit` looks each
            // receiver up by its tuple position. Iterate `flow_order`
            // identically to the `game_hooks_block` loop.
            for (flow_order.items) |i| {
                const entry = script_entries[i];
                const ident = pathToIdent(entry.rel_path, &ident_buf);
                try bw.print(" &{s}_flow_handler,", .{ident});
            }
            try bw.writeAll(" } };\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("hooks_init_block", block);
    }

    // Game events + Plugin events block.
    //
    // `GameEvents` is the game-side scan of `events/*.zig`
    // (labelle-engine#422 — shipped). `PluginEvents` is the
    // plugin-side discovery added by RFC-PLUGIN-EVENTS phase 1: walks
    // every plugin module with `@hasDecl(plugin, "Events")` at
    // comptime — same convention as `Components`/`Systems`/
    // `GizmoCategories` — and folds each `pub const <name> = struct`
    // declaration into a single tagged union with plugin-qualified
    // variant names (`<plugin>__<event>`). `.` is not a valid Zig
    // identifier character, so the on-disk JSONC dot form
    // (`box2d.collision_begin`) resolves to the qualified tag
    // (`box2d__collision_begin`) when flow-codegen consumes this in
    // phase 3.
    //
    // Both decls are `pub` so flow-codegen-emitted hook handler
    // structs (phase 3) can reference them by name via the existing
    // module-level import path. The resolver is the comptime
    // reflection itself (option (a) — generated comptime decl rather
    // than a JSON sidecar): `@FieldType(PluginEvents, "<tag>")` and
    // `@typeInfo(...).@"struct".fields` give the payload field list
    // without a separate registry file to keep in sync.
    //
    // **Phase 3 widening:** the engine's `Game.emit(event: GameEvents)`
    // accepts a single union type, but plugins (RFC-PLUGIN-EVENTS phase
    // 2, e.g. labelle-box2d 6c44691) now `game.emit(.{ .box2d__... = .{...} })`.
    // So when plugins declare events, `GameEvents` is **widened** to the
    // union of the game-side scan and `PluginEvents` — emitted via
    // `pub const GameEvents = engine.core.MergeHookPayloads(.{ GameEventsRaw, PluginEvents })`
    // — and `GameConfig(..., GameEvents)` (the existing engine template
    // slot, unchanged) now sees the merged type. The raw game-side scan
    // is kept under a private alias `GameEventsRaw` so the merge has a
    // stable second operand even when `events/*.zig` is empty.
    //
    // No engine template change required: the `GameEvents,` token in
    // `codegen/main.zig.template` keeps its v1 shape; only the
    // **meaning** of `GameEvents` widens when plugins declare events.
    // Every project without plugin events keeps the v1 semantics
    // verbatim — `GameEvents` is either `void` or the events/*.zig
    // union.
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;

        // Gate on **discovered** plugin events, not declared plugins —
        // a project can declare a plugin whose `Events` is empty/absent
        // (e.g. the plugin-controllers demo plugin), and in that case
        // we want the v1 emission shape verbatim ("no plugin events"),
        // not a `GameEvents = PluginEvents = void` path that would
        // confuse downstream consumers.
        const has_plugin_events_local = plugin_events.len > 0;
        const has_game_events_local = event_names.len > 0;

        // The raw game-side scan keeps its v1 shape; the alias is what
        // the merge feeds on when plugins are also in play. For
        // plugin-less projects with no game events, `GameEventsRaw` is
        // omitted and `GameEvents = void` is emitted directly (the
        // pre-RFC shape every shipped game already has).
        if (has_plugin_events_local) {
            // Need a name for the raw events to feed into the merge.
            // Without game events, the alias is `void` and we end up
            // with `GameEvents = PluginEvents` directly (skipping the
            // merge — `MergeHookPayloads` rejects `void`).
            if (has_game_events_local) {
                try bw.writeAll("pub const GameEventsRaw = union(enum) {\n");
                var pascal_buf: [128]u8 = undefined;
                for (event_names) |name| {
                    const ident = pathToIdent(name, &ident_buf);
                    const pascal = pathToPascal(name, &pascal_buf);
                    try bw.print("    {s}: {s}.{s},\n", .{ ident, ident, pascal });
                }
                try bw.writeAll("};\n\n");
            }
            try writePluginEventsBlock(bw, plugin_events);
            if (has_game_events_local) {
                try bw.writeAll("pub const GameEvents = engine.core.MergeHookPayloads(.{ GameEventsRaw, PluginEvents });\n\n");
            } else {
                try bw.writeAll("pub const GameEvents = PluginEvents;\n\n");
            }
        } else {
            // No plugins — the v1 emission verbatim, every shipped
            // pre-RFC game keeps its exact shape.
            if (has_game_events_local) {
                try bw.writeAll("pub const GameEvents = union(enum) {\n");
                var pascal_buf: [128]u8 = undefined;
                for (event_names) |name| {
                    const ident = pathToIdent(name, &ident_buf);
                    const pascal = pathToPascal(name, &pascal_buf);
                    try bw.print("    {s}: {s}.{s},\n", .{ ident, ident, pascal });
                }
                try bw.writeAll("};\n\n");
            } else {
                try bw.writeAll("pub const GameEvents = void;\n\n");
            }
        }

        // RFC-FLOW-VOCABULARY phase 2 — emit the PluginFlowNodes and
        // PluginPinStyles registries inside the same generated block so
        // the engine template stays unchanged. Both decls are always
        // emitted (empty `struct {}` when discovery found nothing) so
        // downstream consumers can do uniform reflection. See the
        // file header on `writePluginFlowNodesBlock` for the
        // mechanism + RFC §5 (game-script-as-source) for the scope.
        try writePluginFlowNodesBlock(bw, plugin_flow_nodes);
        const deduped_styles = try dedupePinStyles(allocator, plugin_pin_styles);
        defer allocator.free(deduped_styles);
        try writePluginPinStylesBlock(bw, deduped_styles);
        // RFC-FLOW-VOCABULARY §2 / O4 — emit PluginCoercions next to
        // the other registries. The block carries its own `resolve` +
        // `findByTypes` helpers so flow-codegen + the editor can do
        // the wire-fit lookup without re-iterating the decls.
        try writePluginCoercionsBlock(bw, plugin_coercions);

        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
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
        allocs.appendAssumeCapacity(block);
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
            const pascal = pathToPascal(name, &pascal_buf);
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
        allocs.appendAssumeCapacity(block);
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
        allocs.appendAssumeCapacity(block);
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
        allocs.appendAssumeCapacity(block);
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
        allocs.appendAssumeCapacity(block);
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
        allocs.appendAssumeCapacity(block);
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
                const pascal = pathToPascal(name, &anim_pascal_buf);
                try bw.print("const {s}Anim = engine.AnimationDef(@import(\"animations/{s}.zon\"));\n", .{ pascal, name });
            }
            try bw.writeAll("\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
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

                // `{{immersive_entry}}` — Android immersive-mode call,
                // emitted into `sokol_main()` (UI thread, pre-callback
                // registration) so the bars are hidden at launch. Empty
                // for non-Android / non-immersive projects; the shared
                // sokol `desktop.txt` has no such hole, so an empty
                // value there is a harmless no-op.
                const immersive_entry = try buildImmersiveEntryCode(allocator, cfg);
                defer allocator.free(immersive_entry);

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
                    .immersive_entry = immersive_entry,
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
        allocs.appendAssumeCapacity(lifecycle);
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

// ── Tests ────────────────────────────────────────────────────────────────

