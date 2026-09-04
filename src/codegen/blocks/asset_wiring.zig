//! Asset-backend wiring emit helpers extracted from `main_zig.zig`
//! (labelle-assembler#183, step 4 of the cut plan in
//! `docs/REFACTOR-PLAN-main-zig.md`).
//!
//! Three sibling helpers — `writeImageBackendWiring`,
//! `writeAudioBackendWiring`, `writeFontBackendWiring` — each emit an
//! adapter namespace plus the matching `engine.{Image,Audio,Font}Loader
//! .setBackend(...)` install call. All three are pure `try w.print(...)`
//! with no shared state, no allocations, and no template-slot
//! orchestration; the orchestrator (`buildSetupCode` /
//! `buildCallbackInitCode`) calls them in the same lexical slot it used
//! before this extraction.
//!
//! ⚠️  Bit-identical contract: every literal in this file lands directly
//! in the generated `main.zig` for every backend × platform combo. A
//! stray whitespace edit here surfaces as a diff in
//! `scripts/gen_all_examples.sh`. The shape tests in `test/tests.zig`
//! (`writeAudioBackendWiring` / `writeFontBackendWiring` blocks) reach
//! through the `root.zig` re-exports and pin the emitted strings.
//!
//! Refs: labelle-toolkit/labelle-assembler#53 (image), #447 (audio),
//! #448 (font).

const std = @import("std");

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
pub fn writeImageBackendWiring(w: anytype, indent: []const u8) !void {
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
    // Catalog handles are a PRIVATE index into `slots`, but they are
    // stored in the renderer's one `textures` map alongside ids minted by
    // `loadTextureFromMemory` — which keys by the BACKEND pool id (1, 2,
    // ...). Two allocators, one map: a catalog index and a pool id of the
    // same value overwrite each other, and whichever loses samples the
    // other's pixels. That is engine#813 — a game uploading a standalone
    // texture (the `drawMesh` seam, a UI atlas) before a scene's atlases
    // bound made its sprites render from the wrong texture.
    //
    // Offsetting the catalog's half out of the backend's range makes the
    // two spaces disjoint by construction. The base is far above any
    // plausible pool id (bgfx caps at 512 slots) and far below u32 max.
    try w.print("{s}    const CATALOG_ID_BASE: u32 = 1 << 24;\n", .{indent});
    try w.print("{s}    var slots: [MAX_IMAGE_ASSETS]?BackendGfx.Texture = [_]?BackendGfx.Texture{{null}} ** MAX_IMAGE_ASSETS;\n", .{indent});
    // Renderer pointer for `registerCatalogTexture` — set after
    // `g` is initialized in main(). Without this the renderer's
    // sprite draw path falls back to treating the slot handle as a
    // GL texture id and produces white quads. See
    // labelle-toolkit/labelle-gfx#248.
    try w.print("{s}    var renderer_ref: ?*Renderer = null;\n", .{indent});
    // A backend supports the compressed lifecycle only if it exposes the
    // ENTIRE seam: detection (`isCompressed`), dimension probe
    // (`compressedDims`) AND the GPU upload (`uploadCompressed`). Gating on a
    // single comptime flag (rather than per-decl `@hasDecl` checks) means a
    // backend that exposes the probe decls but NOT `uploadCompressed` never
    // emits a dangling reference to the missing upload — the inner blocks
    // below are wrapped in `if (comptime supports_compressed)` so they are
    // not semantically analyzed when the flag is comptime-false.
    try w.print("{s}    const supports_compressed = @hasDecl(BackendGfx, \"isCompressed\") and @hasDecl(BackendGfx, \"compressedDims\") and @hasDecl(BackendGfx, \"uploadCompressed\");\n", .{indent});
    try w.print("{s}\n", .{indent});
    try w.print("{s}    fn decode(\n", .{indent});
    try w.print("{s}        file_type: [:0]const u8,\n", .{indent});
    try w.print("{s}        data: []const u8,\n", .{indent});
    try w.print("{s}        alloc: std.mem.Allocator,\n", .{indent});
    try w.print("{s}    ) anyerror!engine.DecodedImage {{\n", .{indent});
    // GPU-compressed blobs (ASTC) skip the CPU decoder entirely: dupe the
    // raw bytes (the catalog frees them after upload) and read dims from the
    // header. This is the async-catalog counterpart to the synchronous
    // `loadTextureFromMemory` seam — the streaming path (engine#450) splits
    // worker-thread decode from main-thread upload, so the divert happens here.
    // Guarded by `comptime supports_compressed` so backends without the full
    // compressed lifecycle (or a future headless backend) still generate valid
    // code and just always CPU-decode — the `BackendGfx.isCompressed` /
    // `compressedDims` references inside are not analyzed when the flag is
    // comptime-false.
    try w.print("{s}        if (comptime supports_compressed) {{\n", .{indent});
    try w.print("{s}            if (BackendGfx.isCompressed(data)) {{\n", .{indent});
    try w.print("{s}                const dims = BackendGfx.compressedDims(data) orelse return error.LoadFailed;\n", .{indent});
    try w.print("{s}                return .{{ .pixels = try alloc.dupe(u8, data), .width = dims.width, .height = dims.height, .compressed = true }};\n", .{indent});
    try w.print("{s}            }}\n", .{indent});
    try w.print("{s}        }}\n", .{indent});
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
    // Compressed blobs upload as-is via `uploadCompressed`; RGBA8 goes through
    // the normal `uploadTexture`. Either way the catalog frees `decoded.pixels`.
    // The `uploadCompressed` arm is wrapped in `if (comptime supports_compressed)`
    // so backends WITHOUT the full compressed lifecycle never reference the
    // missing `BackendGfx.uploadCompressed` (the inner block is not analyzed
    // when the flag is comptime-false) — and `decode` never marks `.compressed`
    // for them, so the compressed arm is unreachable at runtime anyway.
    try w.print("{s}        const tex = blk: {{\n", .{indent});
    try w.print("{s}            if (comptime supports_compressed) {{\n", .{indent});
    try w.print("{s}                if (decoded.compressed) break :blk try BackendGfx.uploadCompressed(decoded.pixels);\n", .{indent});
    try w.print("{s}            }}\n", .{indent});
    try w.print("{s}            break :blk try BackendGfx.uploadTexture(.{{\n", .{indent});
    try w.print("{s}                .pixels = decoded.pixels,\n", .{indent});
    try w.print("{s}                .width = decoded.width,\n", .{indent});
    try w.print("{s}                .height = decoded.height,\n", .{indent});
    try w.print("{s}            }});\n", .{indent});
    try w.print("{s}        }};\n", .{indent});
    try w.print("{s}        slots[handle] = tex;\n", .{indent});
    // Register the slot handle → real BackendTexture mapping with
    // the renderer so the sprite draw path resolves correctly.
    // The slot handle is NOT a GL texture id; without this
    // registration `getTextureInfo(handle)` returns null and
    // raylib renders white quads — see
    // labelle-toolkit/labelle-gfx#248.
    try w.print("{s}        const out_handle = handle + CATALOG_ID_BASE;\n", .{indent});
    try w.print("{s}        if (renderer_ref) |r| r.registerCatalogTexture(out_handle, tex);\n", .{indent});
    try w.print("{s}        return out_handle;\n", .{indent});
    try w.print("{s}    }}\n", .{indent});
    try w.print("{s}\n", .{indent});
    // Unload routes through the RENDERER when one is wired, so the
    // catalog-key registry entry dies WITH the backend texture. The old
    // bare `BackendGfx.unloadTexture` left the renderer's entry
    // dangling; the next scene's upload recycling this slot then
    // OVERWROTE it, and any stale holder of the old key silently
    // sampled the wrong atlas (labelle-engine#821, the scene-reload
    // "mob of workers" cross-wire). The renderer's `unloadTexture`
    // removes the entry and destroys the backend texture in one call.
    // Param type is derived from the seam's own signature (same trick
    // as engine `atlas_mixin.normalizeHandle`) so gfx's typed
    // `TextureId` and integer-handle backends both compile; backends
    // whose renderer lacks the seam fall back to the bare destroy.
    try w.print("{s}    fn unload(texture: engine.AssetTexture) void {{\n", .{indent});
    try w.print("{s}        if (texture < CATALOG_ID_BASE) return;\n", .{indent});
    try w.print("{s}        const idx = texture - CATALOG_ID_BASE;\n", .{indent});
    try w.print("{s}        if (idx >= MAX_IMAGE_ASSETS) return;\n", .{indent});
    try w.print("{s}        if (slots[idx]) |tex| {{\n", .{indent});
    try w.print("{s}            routed: {{\n", .{indent});
    try w.print("{s}                if (comptime @hasDecl(Renderer, \"unloadTexture\")) {{\n", .{indent});
    try w.print("{s}                    if (renderer_ref) |r| {{\n", .{indent});
    try w.print("{s}                        const Param = @typeInfo(@TypeOf(Renderer.unloadTexture)).@\"fn\".params[1].type.?;\n", .{indent});
    try w.print("{s}                        const typed: Param = if (comptime @typeInfo(Param) == .@\"enum\") @enumFromInt(texture) else @intCast(texture);\n", .{indent});
    try w.print("{s}                        r.unloadTexture(typed);\n", .{indent});
    try w.print("{s}                        break :routed;\n", .{indent});
    try w.print("{s}                    }}\n", .{indent});
    try w.print("{s}                }}\n", .{indent});
    try w.print("{s}                BackendGfx.unloadTexture(tex);\n", .{indent});
    try w.print("{s}            }}\n", .{indent});
    try w.print("{s}            slots[idx] = null;\n", .{indent});
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
/// WIRED (Phase 4 complete — #447 landed via #104): called from BOTH lifecycle
/// builders — `buildSetupCode` (codegen/lifecycle/loop.zig:107) and
/// `buildCallbackInitCode` (codegen/lifecycle/callback.zig:95) — GATED on the
/// project declaring at least one resource whose `kind()` is `.sound`. The gate
/// is load-bearing: the emitted adapter references `BackendAudio.decodeAudio` /
/// `uploadSound` / `unloadSound`, which only audio-capable backends implement,
/// so a project with no sound resources must never see those references in its
/// generated main.zig (full rationale at codegen/lifecycle/loop.zig:75-97). A
/// project WITH sound resources on a backend without audio support gets a clean
/// compile error pointing at `BackendAudio.decodeAudio`.
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
/// WIRED (Phase 4 complete — #448 landed via #104): called from BOTH lifecycle
/// builders — `buildSetupCode` (codegen/lifecycle/loop.zig:108) and
/// `buildCallbackInitCode` (codegen/lifecycle/callback.zig:96) — GATED on the
/// project declaring at least one resource whose `kind()` is `.font`. The gate
/// is load-bearing: the emitted adapter references `BackendGfx.decodeFont` /
/// `uploadFontAtlas` / `unloadFontAtlas`, which only font-capable backends
/// implement, so a project with no font resources must never see those
/// references in its generated main.zig (full rationale at
/// codegen/lifecycle/loop.zig:75-97). A project WITH font resources on a backend
/// without font support gets a clean compile error pointing at
/// `BackendGfx.decodeFont`.
///
/// ## `decode`'s parameter shape (#700)
///
/// `engine.FontBackend.decode` takes `params: FontBakeParams` BY VALUE.
/// It always has: `FontBackend` was introduced by labelle-engine#529
/// (commit c7b6fcb, first released in **engine v1.36.0**) already
/// declaring the typed struct, and every commit that has touched
/// `src/assets/loaders/font.zig` since keeps it — verified through
/// v2.15.0. No released engine ever declared it as `?*const anyopaque`;
/// that type-erased shape belongs to the catalog's
/// `WorkRequest.params`, which the engine's own `font.zig` casts back
/// to `FontBakeParams` BEFORE calling into this adapter. Engines older
/// than v1.36.0 have no `FontLoader.setBackend` at all, so this block
/// cannot compile against them under any signature — v1.36.0 is the
/// hard floor for a `.font` resource, and above it there is exactly one
/// shape to emit.
///
/// The adapter emitted `?*const anyopaque` from the start, so
/// `engine.FontLoader.setBackend(.{ .decode = FontBackendAdapter.decode })`
/// was a type error and declaring ANY `.font` resource failed to
/// compile on every assembler + engine pairing that has shipped.
///
/// ## The minted handle has to be resolvable (labelle-bgfx#85)
///
/// `upload` mints `engine.FontId{ .index = <slot>, .generation = 1 }`
/// where the index is private to THIS adapter's `slots` table, and the
/// backend's own `FontAtlas` carries no id at all. The number then
/// travels — engine packs it into the renderer's `Text.font`
/// (labelle-engine#849), gfx forwards `text.font.toInt()` through
/// core's optional `drawTextWithFont` (labelle-core#75) — and lands at
/// a backend that cannot map it back to the atlas it uploaded. The two
/// `u32` spaces are unrelated allocators that merely coincide today.
///
/// So `upload` also registers the mapping on the backend through an
/// OPTIONAL `registerCatalogFont` / `unregisterCatalogFont` pair, the
/// font twin of the image arm's `registerCatalogTexture`. Unlike the
/// image arm the seam is on `BackendGfx`, not on the renderer: gfx's
/// `drawTextEntry` resolves nothing, it forwards the handle, so the
/// backend is the party that needs the lookup.
///
/// Ticket: labelle-engine#448 (font loader tracking)
/// Ticket: labelle-assembler#700 (this signature fix)
/// Sibling: `writeAudioBackendWiring` (audio scaffolding, #447)
/// Refs: labelle-gfx#258 (font traits on `Backend(Impl)`)
/// Refs: labelle-gfx#248 (the image arm's identical registration)
/// Refs: labelle-bgfx#85 (the unresolvable-handle report)
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
    // ── Catalog font registry seam (labelle-bgfx#85) ───────────────────
    //
    // The font counterpart of the image arm's `registerCatalogTexture`
    // (labelle-gfx#248), and it exists for exactly the same reason: the
    // handle this adapter mints is a PRIVATE index into `slots` above,
    // not anything the party that eventually draws with it can resolve.
    //
    // The image arm registers with the RENDERER because gfx's sprite
    // path is what resolves a texture handle. The font path is
    // different: gfx's `drawTextEntry` does not resolve anything — it
    // forwards `text.font.toInt()` straight through core's optional
    // `drawTextWithFont(..., font: ?FontHandle)` (labelle-core#75) to
    // the graphics BACKEND, which then has to find the atlas it itself
    // uploaded. So the registration belongs on `BackendGfx`, one hop
    // closer to the consumer, and no labelle-gfx decl is involved.
    //
    // Both halves are required together (same shape as the image arm's
    // `supports_compressed` whole-seam gate): a backend that could
    // register but not unregister would keep resolving a destroyed
    // atlas after a scene unload — the font-side twin of the dangling
    // renderer entry that was labelle-engine#821.
    //
    // A backend declaring NEITHER (bgfx and sokol today) keeps the flag
    // comptime-false, so every reference below is unanalysed and a
    // font-less backend compiles exactly as it does now.
    try w.print("{s}    const supports_catalog_font_registry = @hasDecl(BackendGfx, \"registerCatalogFont\") and @hasDecl(BackendGfx, \"unregisterCatalogFont\");\n", .{indent});
    try w.print("{s}\n", .{indent});
    // The wire value. `engine.FontId` is `{{ index: u16, generation: u16 }}`,
    // but the seam that reaches the backend transports a flat `u32`
    // (core's `FontHandle`). The engine packs it INDEX-LOW /
    // GENERATION-HIGH on its way into the renderer's `Text.font`
    // (labelle-engine#849 `atlas_mixin.packFontId`), and gfx hands that
    // same number to `drawTextWithFont`. Registering under any other
    // arithmetic would key the table on a number the draw call never
    // produces — the failure would be silent, so this MUST agree with
    // #849 bit for bit.
    //
    // Two properties fall out of that layout, both relied on here:
    //   * `{{ .index = 0, .generation = 0 }}` packs to 0, which is gfx's
    //     `FontId.invalid` — a default text component and an engine
    //     `.invalid` agree without a special case, and gfx never even
    //     reaches `drawTextWithFont` for it.
    //   * the index is recoverable with a plain `@truncate` to `u16`,
    //     which is what a slot-keyed backend resolver wants.
    try w.print("{s}    fn catalogFontHandle(id: engine.FontId) u32 {{\n", .{indent});
    try w.print("{s}        return @as(u32, id.index) | (@as(u32, id.generation) << 16);\n", .{indent});
    try w.print("{s}    }}\n", .{indent});
    try w.print("{s}\n", .{indent});
    try w.print("{s}    fn decode(\n", .{indent});
    try w.print("{s}        file_type: [:0]const u8,\n", .{indent});
    try w.print("{s}        data: []const u8,\n", .{indent});
    // `engine.FontBakeParams` BY VALUE — that is what `FontBackend.decode`
    // has declared in every engine release that ships a `FontBackend`
    // (labelle-engine v1.36.0 onward; see the header note). The
    // type-erased `?*const anyopaque` lives one level up, on the
    // catalog's `WorkRequest.params`: the engine's own `font.zig`
    // `decode` casts it back to `FontBakeParams` and hands the ADAPTER
    // the typed struct. Emitting `?*const anyopaque` here made
    // `setBackend(.{ .decode = FontBackendAdapter.decode, ... })` a hard
    // type error, so declaring ANY `.font` resource failed to compile
    // (#700).
    try w.print("{s}        params: engine.FontBakeParams,\n", .{indent});
    try w.print("{s}        alloc: std.mem.Allocator,\n", .{indent});
    try w.print("{s}    ) anyerror!engine.DecodedFont {{\n", .{indent});
    // `@hasDecl` guard: without it, games that don't actually
    // reach the font loader still fail to compile on backends
    // that haven't implemented the gfx#258 font traits yet. The
    // guard short-circuits to a runtime error instead. The
    // condition is comptime-known, so the whole marshal below is
    // dead code (never analysed) on such a backend — which is why
    // `BackendGfx.FontBakeParams` may be absent entirely.
    try w.print("{s}        if (!@hasDecl(BackendGfx, \"decodeFont\")) return error.FontBackendNotImplemented;\n", .{indent});
    // The engine's `FontBakeParams` and the backend's are
    // structurally identical but nominally distinct, so the struct is
    // copied field-by-field — same trap as the image/audio adapters'
    // DecodedX copy.
    //
    // `.ranges` needs the same treatment ONE LEVEL DEEPER: it is a
    // slice of `engine.CodepointRange` (a plain `struct`) that has to
    // become a slice of the backend's own range type (an `extern
    // struct` in every in-tree backend). Neither a plain assignment
    // nor a `@ptrCast` is legal across that boundary — the engine
    // side carries no layout guarantee — so the elements are rebuilt
    // into a scratch buffer. The element type is read off the
    // backend's own field rather than assuming a `BackendGfx
    // .CodepointRange` decl, so a backend that only re-exports
    // `FontBakeParams` still wires up.
    //
    // Lifetime: `FontBakeParams.ranges` is documented as BORROWED for
    // the duration of the decode call, so the scratch buffer is freed
    // on the way out — `decodeFont` copies whatever it needs.
    try w.print("{s}        const BackendRange = @typeInfo(@FieldType(BackendGfx.FontBakeParams, \"ranges\")).pointer.child;\n", .{indent});
    try w.print("{s}        const ranges = try alloc.alloc(BackendRange, params.ranges.len);\n", .{indent});
    try w.print("{s}        defer alloc.free(ranges);\n", .{indent});
    try w.print("{s}        for (params.ranges, ranges) |src_range, *dst_range| {{\n", .{indent});
    try w.print("{s}            dst_range.* = .{{ .first = src_range.first, .last = src_range.last }};\n", .{indent});
    try w.print("{s}        }}\n", .{indent});
    try w.print("{s}        const backend_params: BackendGfx.FontBakeParams = .{{\n", .{indent});
    try w.print("{s}            .pixel_height = params.pixel_height,\n", .{indent});
    try w.print("{s}            .ranges = ranges,\n", .{indent});
    try w.print("{s}            .atlas_width = params.atlas_width,\n", .{indent});
    try w.print("{s}            .atlas_height = params.atlas_height,\n", .{indent});
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
    try w.print("{s}        const id: engine.FontId = .{{ .index = idx, .generation = 1 }};\n", .{indent});
    // Hand the backend the mapping from the handle it will actually be
    // given at draw time to the atlas it just returned. Without this the
    // number arriving at `drawTextWithFont` indexes a table only this
    // adapter can see, and the backend degrades to its built-in face for
    // every font — labelle-bgfx#85. Directly analogous to the image
    // arm's `registerCatalogTexture(out_handle, tex)` a few hundred
    // lines up, whose absence rendered white quads (labelle-gfx#248).
    try w.print("{s}        if (comptime supports_catalog_font_registry) {{\n", .{indent});
    try w.print("{s}            BackendGfx.registerCatalogFont(catalogFontHandle(id), atlas);\n", .{indent});
    try w.print("{s}        }}\n", .{indent});
    try w.print("{s}        return id;\n", .{indent});
    try w.print("{s}    }}\n", .{indent});
    try w.print("{s}\n", .{indent});
    try w.print("{s}    fn unload(font: engine.FontId) void {{\n", .{indent});
    try w.print("{s}        if (!@hasDecl(BackendGfx, \"unloadFontAtlas\")) return;\n", .{indent});
    try w.print("{s}        if (font.index >= MAX_FONT_ASSETS) return;\n", .{indent});
    try w.print("{s}        if (slots[font.index]) |a| {{\n", .{indent});
    // Drop the registry entry BEFORE destroying the atlas, so no draw
    // can resolve a handle to a dead atlas in between — and so the next
    // upload recycling this slot cannot inherit a live entry pointing at
    // freed GPU state. That ordering is the font-side answer to
    // labelle-engine#821, where the image path's stale renderer entry
    // survived an unload and the recycled key sampled the wrong atlas.
    try w.print("{s}            if (comptime supports_catalog_font_registry) {{\n", .{indent});
    try w.print("{s}                BackendGfx.unregisterCatalogFont(catalogFontHandle(font));\n", .{indent});
    try w.print("{s}            }}\n", .{indent});
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

/// Mixin factory for `Codegen` (labelle-assembler#183, mixin conversion).
///
/// Returns thin delegator methods so the orchestrator can call
/// `ctx.writeXxx(w, indent)` in the mixin shape modelled on
/// `labelle-engine/src/game/*_mixin.zig`. The three writers are pure —
/// they pull no state from `self` (the engine's audio_mixin shows the
/// equivalent `_: *Game` shape) — so the mixin only exists to satisfy
/// the dispatch-through-context contract. Standalone functions above
/// stay `pub` for the test surface (`test/tests.zig`) and
/// `root.zig` re-exports.
pub fn Mixin(comptime Self: type) type {
    // Capture the enclosing file's namespace so the same-name methods
    // below can reach the standalone bodies without shadowing recursion.
    // `@This()` evaluated here (in the factory body, outside the returned
    // struct) resolves to the file namespace; survives file renames that
    // an `@import("self.zig")` workaround would silently break.
    const file = @This();
    return struct {
        pub fn writeImageBackendWiring(_: *Self, w: anytype, indent: []const u8) !void {
            return file.writeImageBackendWiring(w, indent);
        }
        pub fn writeAudioBackendWiring(_: *Self, w: anytype, indent: []const u8) !void {
            return file.writeAudioBackendWiring(w, indent);
        }
        pub fn writeFontBackendWiring(_: *Self, w: anytype, indent: []const u8) !void {
            return file.writeFontBackendWiring(w, indent);
        }
    };
}
