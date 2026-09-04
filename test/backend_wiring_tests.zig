const std = @import("std");
const zspec = @import("zspec");
const generate = @import("generator");
const h = @import("helpers.zig");

const engine_template = h.engine_template;
const raylib_lifecycle = h.raylib_lifecycle;
const sokol_lifecycle = h.sokol_lifecycle;
const null_lifecycle = h.null_lifecycle;
const sokol_alloc_lifecycle = h.sokol_alloc_lifecycle;
const empty_names = h.empty_names;
const ScriptEntry = h.ScriptEntry;
const empty_entries = h.empty_entries;
const SceneManifest = h.SceneManifest;
const empty_scene_manifests = h.empty_scene_manifests;
const PluginEvent = h.PluginEvent;
const empty_plugin_events = h.empty_plugin_events;
const PluginFlowNode = h.PluginFlowNode;
const empty_plugin_flow_nodes = h.empty_plugin_flow_nodes;
const PluginPinStyle = h.PluginPinStyle;
const empty_plugin_pin_styles = h.empty_plugin_pin_styles;
const PluginCoercion = h.PluginCoercion;
const empty_plugin_coercions = h.empty_plugin_coercions;
const GlobalEntries = h.GlobalEntries;
const globalEntries = h.globalEntries;
const testGuiRenderInterface = h.testGuiRenderInterface;
const testGuiRawBackend = h.testGuiRawBackend;

test {
    zspec.runAll(@This());
}

pub const IMAGE_BACKEND_WIRING = struct {
    // Assertions shared across every backend variant we generate for.
    // Every assembler-generated `main.zig` MUST ship:
    //   * the three `ImageBackendAdapter` member functions
    //     (decode/upload/unload) so `setBackend`'s function-pointer
    //     struct literal is well-typed;
    //   * the `engine.ImageLoader.setBackend(...)` call itself; AND
    //   * that call must appear BEFORE any `registerAtlasFromMemory`
    //     / `loadAtlasFromMemory` / scene / script code that could
    //     reach `AssetCatalog.acquire` on an image asset. If any of
    //     those fire with the slot still null, the engine surfaces
    //     `error.ImageBackendNotInitialized` at the entry's failed
    //     state — clean but game-breaking.
    fn expectImageBackendWiring(main_zig: []const u8) !void {
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const ImageBackendAdapter = struct {") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "fn decode(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "fn upload(decoded: engine.DecodedImage) anyerror!engine.AssetTexture") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "fn unload(texture: engine.AssetTexture) void") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "BackendGfx.decodeImage(file_type, data, alloc)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "BackendGfx.uploadTexture(.{") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "BackendGfx.unloadTexture(tex)") != null);
        // Compressed (ASTC) blobs route through a comptime-gated path: the
        // `supports_compressed` flag requires the ENTIRE lifecycle (isCompressed
        // + compressedDims + uploadCompressed), and both decode and upload wrap
        // their compressed arms in `if (comptime supports_compressed)` so a
        // backend lacking `uploadCompressed` never references the missing decl.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const supports_compressed = @hasDecl(BackendGfx, \"isCompressed\") and @hasDecl(BackendGfx, \"compressedDims\") and @hasDecl(BackendGfx, \"uploadCompressed\");") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "if (comptime supports_compressed)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "BackendGfx.compressedDims(data)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".compressed = true") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "if (decoded.compressed) break :blk try BackendGfx.uploadCompressed(decoded.pixels);") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.ImageLoader.setBackend(.{") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".decode = ImageBackendAdapter.decode") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".upload = ImageBackendAdapter.upload") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".unload = ImageBackendAdapter.unload") != null);
    }

    test "buildSetupCode emits setBackend + adapters (raylib)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try expectImageBackendWiring(main_zig);
    }

    test "buildCallbackInitCode emits setBackend + adapters (sokol)" {
        h.setSokolLifecycle();
        defer h.clearLifecycleOverrides();
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, sokol_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try expectImageBackendWiring(main_zig);
    }

    // The remaining three backends go through the same `buildSetupCode`
    // path as raylib (see `use_callback_lifecycle` in
    // `src/main_zig.zig` — only `.sokol` or `.wasm` flip to the
    // callback path). We still assert each variant individually so a
    // future split in the lifecycle selection can't silently drop one.
    test "buildSetupCode emits setBackend + adapters (sdl)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .sdl,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try expectImageBackendWiring(main_zig);
    }

    test "buildSetupCode emits setBackend + adapters (bgfx)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .bgfx,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try expectImageBackendWiring(main_zig);
    }

    test "buildSetupCode emits setBackend + adapters (wgpu)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .wgpu,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try expectImageBackendWiring(main_zig);
    }

    test "setBackend runs before any registerScene / atlas registration (raylib)" {
        const jsonc_scenes = &[_][]const u8{"menu"};
        const manifests = [_]SceneManifest{
            .{ .name = "menu", .assets = &[_][]const u8{} },
        };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "sprites", .json = "assets/sprites.json", .texture = "assets/sprites.png" },
            },
        }, raylib_lifecycle, empty_entries, empty_names, jsonc_scenes, &manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // The rule: `setBackend` populates the hook BEFORE any
        // asset/scene code can reach `AssetCatalog.acquire`. For the
        // loop-based backends that means before the atlas loader
        // call and before `registerSceneSimple`. We assert the
        // setBackend index is strictly less than both.
        const set_backend_idx = std.mem.indexOf(u8, main_zig, "engine.ImageLoader.setBackend(.{") orelse return error.SetBackendMissing;
        const atlas_idx = std.mem.indexOf(u8, main_zig, "g.loadAtlasFromMemory") orelse std.mem.indexOf(u8, main_zig, "g.registerAtlasFromMemory") orelse return error.AtlasLoadMissing;
        const register_scene_idx = std.mem.indexOf(u8, main_zig, "g.registerSceneSimple(") orelse return error.RegisterSceneMissing;

        try std.testing.expect(set_backend_idx < atlas_idx);
        try std.testing.expect(set_backend_idx < register_scene_idx);
    }

    test "setBackend runs before any registerScene / atlas registration (sokol)" {
        h.setSokolLifecycle();
        defer h.clearLifecycleOverrides();
        const jsonc_scenes = &[_][]const u8{"menu"};
        const manifests = [_]SceneManifest{
            .{ .name = "menu", .assets = &[_][]const u8{} },
        };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "sprites", .json = "assets/sprites.json", .texture = "assets/sprites.png" },
            },
        }, sokol_lifecycle, empty_entries, empty_names, jsonc_scenes, &manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        const set_backend_idx = std.mem.indexOf(u8, main_zig, "engine.ImageLoader.setBackend(.{") orelse return error.SetBackendMissing;
        const atlas_idx = std.mem.indexOf(u8, main_zig, "g.loadAtlasFromMemory") orelse std.mem.indexOf(u8, main_zig, "g.registerAtlasFromMemory") orelse return error.AtlasLoadMissing;
        const register_scene_idx = std.mem.indexOf(u8, main_zig, "g.registerSceneSimple(") orelse return error.RegisterSceneMissing;

        try std.testing.expect(set_backend_idx < atlas_idx);
        try std.testing.expect(set_backend_idx < register_scene_idx);
    }

    test "adapters stash the full backend Texture in a slot table (raylib)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // The side-table is the load-bearing bit — without it we'd
        // lose the sokol/bgfx/wgpu/sdl aux handles on every unload.
        // Assert the storage shape (optional BackendGfx.Texture per
        // slot) and that the upload/unload paths both go through it.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var slots: [MAX_IMAGE_ASSETS]?BackendGfx.Texture") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "slots[handle] = tex;") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "if (slots[idx]) |tex|") != null);

        // engine#813: catalog handles share the renderer's `textures` map
        // with ids minted by `loadTextureFromMemory`, which keys by the
        // BACKEND pool id. A raw 0-based slot index collides with those,
        // and the loser samples the other's pixels. The emitted adapter
        // must offset its half of the space and translate back on unload.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const CATALOG_ID_BASE: u32 = 1 << 24;") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const out_handle = handle + CATALOG_ID_BASE;") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerCatalogTexture(out_handle, tex)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "return out_handle;") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "if (texture < CATALOG_ID_BASE) return;") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const idx = texture - CATALOG_ID_BASE;") != null);
        // The raw index must NOT reach the renderer any more.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerCatalogTexture(handle, tex)") == null);

        // The exhaustion guard MUST appear before `uploadTexture` in
        // the emitted `upload` body: if the table is full and we
        // upload first, we leak a GPU resource (the handle is
        // discarded with the error return). Matches the new slot-scan
        // form — the `handle == MAX_IMAGE_ASSETS` sentinel is how the
        // rewrite signals "no free slot" after the scan.
        const guard_idx = std.mem.indexOf(u8, main_zig, "if (handle == MAX_IMAGE_ASSETS) return error.ImageSlotsExhausted;") orelse return error.GuardMissing;
        const upload_call_idx = std.mem.indexOf(u8, main_zig, "BackendGfx.uploadTexture(.{") orelse return error.UploadCallMissing;
        try std.testing.expect(guard_idx < upload_call_idx);

        // Also lock in the slot-reuse behavior: the scan must run
        // BEFORE the guard, and `unload` must clear `slots[texture]`
        // so recycled indices come back into play. Monotonic
        // `next_id`-style counters are gone — guard against
        // regression.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "for (slots, 0..) |slot, i|") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "slots[idx] = null;") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var next_id:") == null);
    }

    test "adapter decode marshals engine.DecodedImage from backend DecodedImage" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Assert the field-for-field copy shape — a mismatch here
        // would silently break the engine's DecodedImage layout.
        // The emitted struct literal must reach every field of
        // `engine.DecodedImage`: pixels, width, height.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".pixels = d.pixels") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".width = d.width") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".height = d.height") != null);
    }
};

pub const AUDIO_BACKEND_WIRING = struct {
    fn renderAudio() ![]const u8 {
        var alloc_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
        errdefer alloc_writer.deinit();
        var ctx = h.emptyCodegen(std.testing.allocator);
        try ctx.writeAudioBackendWiring(&alloc_writer.writer, "    ");
        return alloc_writer.toOwnedSlice();
    }

    test "writeAudioBackendWiring emits adapter + setBackend" {
        const out = try renderAudio();
        defer std.testing.allocator.free(out);

        // Adapter shape.
        try std.testing.expect(std.mem.indexOf(u8, out, "const AudioBackendAdapter = struct {") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "fn decode(") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "fn upload(decoded: engine.DecodedAudio) anyerror!engine.SoundId") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "fn unload(sound: engine.SoundId) void") != null);

        // Marshalling to the backend's audio module.
        try std.testing.expect(std.mem.indexOf(u8, out, "BackendAudio.decodeAudio(file_type, data, alloc)") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "BackendAudio.uploadSound(backend_decoded)") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "BackendAudio.unloadSound(s)") != null);

        // setBackend installation.
        try std.testing.expect(std.mem.indexOf(u8, out, "engine.AudioLoader.setBackend(.{") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".decode = AudioBackendAdapter.decode") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".upload = AudioBackendAdapter.upload") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".unload = AudioBackendAdapter.unload") != null);
    }

    test "writeAudioBackendWiring marshals DecodedAudio fields" {
        // `BackendAudio.DecodedAudio` is structurally identical to
        // `engine.DecodedAudio` but nominally distinct (same trap as
        // images). Verify the field-by-field copy.
        const out = try renderAudio();
        defer std.testing.allocator.free(out);

        try std.testing.expect(std.mem.indexOf(u8, out, ".samples = decoded.samples") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".sample_rate = decoded.sample_rate") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".channels = decoded.channels") != null);
    }

    test "writeAudioBackendWiring marshals Sound via slot table → SoundId" {
        // Slot table mirrors the image side: backend's `Sound` struct
        // stays alongside a u16 slot index that becomes
        // `SoundId.index`. Generation pinned to 1 in v1 (documented).
        const out = try renderAudio();
        defer std.testing.allocator.free(out);

        try std.testing.expect(std.mem.indexOf(u8, out, "var slots: [MAX_AUDIO_ASSETS]?BackendAudio.Sound") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "if (idx == MAX_AUDIO_ASSETS) return error.AudioSlotsExhausted") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".index = idx, .generation = 1") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "if (sound.index >= MAX_AUDIO_ASSETS) return") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "slots[sound.index] = null") != null);
    }
};

pub const FONT_BACKEND_WIRING = struct {
    fn renderFont() ![]const u8 {
        var alloc_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
        errdefer alloc_writer.deinit();
        var ctx = h.emptyCodegen(std.testing.allocator);
        try ctx.writeFontBackendWiring(&alloc_writer.writer, "    ");
        return alloc_writer.toOwnedSlice();
    }

    test "writeFontBackendWiring emits adapter + setBackend" {
        const out = try renderFont();
        defer std.testing.allocator.free(out);

        // Adapter shape.
        try std.testing.expect(std.mem.indexOf(u8, out, "const FontBackendAdapter = struct {") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "fn decode(") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "fn upload(decoded: engine.DecodedFont) anyerror!engine.FontId") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "fn unload(font: engine.FontId) void") != null);

        // Marshalling to the graphics backend (gfx#258 puts font traits
        // alongside the existing image trio on `Backend(Impl)`, NOT in
        // a separate `BackendFont` module).
        try std.testing.expect(std.mem.indexOf(u8, out, "BackendGfx.decodeFont(file_type, data, &backend_params, alloc)") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "BackendGfx.uploadFontAtlas(backend_decoded)") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "BackendGfx.unloadFontAtlas(a)") != null);

        // setBackend installation.
        try std.testing.expect(std.mem.indexOf(u8, out, "engine.FontLoader.setBackend(.{") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".decode = FontBackendAdapter.decode") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".upload = FontBackendAdapter.upload") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".unload = FontBackendAdapter.unload") != null);
    }

    test "writeFontBackendWiring marshals DecodedFont fields" {
        // `BackendGfx.DecodedFont` is structurally identical to
        // `engine.DecodedFont` but nominally distinct (same trap as
        // images / audio). Verify the field-by-field copy reaches
        // every field the engine ships in its DecodedFont contract:
        // bitmap + dims, glyph table + codepoint index, vertical
        // metrics, line height, kerning.
        const out = try renderFont();
        defer std.testing.allocator.free(out);

        try std.testing.expect(std.mem.indexOf(u8, out, ".bitmap = d.bitmap") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".width = d.width") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".height = d.height") != null);
        // Slice fields are `@ptrCast` across the nominally-distinct
        // extern-struct boundary between BackendGfx.Glyph and
        // engine.Glyph (and equivalent for the other two slice
        // element types). Locks the codegen so a regression to
        // plain `.glyphs = d.glyphs` would be caught here.
        try std.testing.expect(std.mem.indexOf(u8, out, ".glyphs = @ptrCast(d.glyphs)") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".codepoint_index = @ptrCast(d.codepoint_index)") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".ascent = d.ascent") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".descent = d.descent") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".line_gap = d.line_gap") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".line_height = d.line_height") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".kerning = @ptrCast(d.kerning)") != null);

        // Mirror asserts for the upload direction (engine → BackendGfx
        // slice marshal). Decode + upload both cross the nominal
        // boundary, so both need the ptrcast — Bugbot caught this gap
        // on initial review.
        try std.testing.expect(std.mem.indexOf(u8, out, ".glyphs = @ptrCast(decoded.glyphs)") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".codepoint_index = @ptrCast(decoded.codepoint_index)") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".kerning = @ptrCast(decoded.kerning)") != null);

        // FontBakeParams also threads through decode (RFC §7) — the
        // adapter takes the engine's TYPED struct by value (which is what
        // `engine.FontBackend.decode` has always declared) and copies it
        // field-by-field into the backend's mirror struct before
        // forwarding to `BackendGfx.decodeFont`.
        //
        // This used to pin `params: ?*const anyopaque` — the type-erased
        // shape belongs to the catalog's `WorkRequest.params` one level
        // up, NOT to the vtable, so the pin was locking in a signature
        // that could never satisfy `setBackend`. #700: declaring any
        // `.font` resource failed to compile for the whole life of the
        // feature while this assert passed. The real acceptance now lives
        // in `test/font_backend_signature_tests.zig`, which compiles and
        // RUNS the emitted adapter against the vtable.
        try std.testing.expect(std.mem.indexOf(u8, out, "params: engine.FontBakeParams") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "?*const anyopaque") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "const backend_params: BackendGfx.FontBakeParams = .{") != null);

        // Field names MUST match engine.FontBakeParams / gfx FontBakeParams
        // verbatim (pixel_height / ranges / atlas_width / atlas_height).
        // Initial scaffold (#103) drifted to `codepoint_ranges` +
        // `oversample_h` / `oversample_v` which don't exist on either
        // engine or gfx — caught by Gemini reviewing #105.
        try std.testing.expect(std.mem.indexOf(u8, out, ".pixel_height = params.pixel_height") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".atlas_width = params.atlas_width") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".atlas_height = params.atlas_height") != null);
        // `.ranges` is the one field that cannot be a plain assignment:
        // `engine.CodepointRange` is a plain struct and the backend's is an
        // `extern struct`, so the elements are rebuilt into a scratch
        // buffer (freed on the way out — the slice is borrowed for the
        // decode call only).
        try std.testing.expect(std.mem.indexOf(u8, out, ".ranges = ranges") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "@FieldType(BackendGfx.FontBakeParams, \"ranges\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "defer alloc.free(ranges)") != null);
        // Drift guards: these are the names #103 wrongly emitted —
        // none should appear in the generated code.
        try std.testing.expect(std.mem.indexOf(u8, out, "codepoint_ranges") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "oversample_h") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "oversample_v") == null);
    }

    test "writeFontBackendWiring marshals FontAtlas via slot table → FontId" {
        // Slot table mirrors the audio side: backend's `FontAtlas`
        // struct stays alongside a u16 slot index that becomes
        // `FontId.index`. Generation pinned to 1 in v1 (documented).
        // `@hasDecl` guard wraps every method body so backends that
        // haven't opted into gfx#258's font traits still compile,
        // erroring at runtime with `FontBackendNotImplemented`
        // instead of failing at compile time.
        const out = try renderFont();
        defer std.testing.allocator.free(out);

        try std.testing.expect(std.mem.indexOf(u8, out, "var slots: [MAX_FONT_ASSETS]?BackendGfx.FontAtlas") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "if (idx == MAX_FONT_ASSETS) return error.FontSlotsExhausted") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".index = idx, .generation = 1") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "if (font.index >= MAX_FONT_ASSETS) return") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "slots[font.index] = null") != null);

        // The `@hasDecl` guards are the load-bearing bit that lets
        // this scaffold land before every backend implements the
        // gfx#258 traits. Without them, `zig build` against a
        // backend missing `decodeFont` would fail at compile time
        // even for games that don't actually use fonts.
        try std.testing.expect(std.mem.indexOf(u8, out, "if (!@hasDecl(BackendGfx, \"decodeFont\")) return error.FontBackendNotImplemented") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "if (!@hasDecl(BackendGfx, \"uploadFontAtlas\")) return error.FontBackendNotImplemented") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "if (!@hasDecl(BackendGfx, \"unloadFontAtlas\")) return") != null);

        // Exhaustion guard MUST appear before `uploadFontAtlas`
        // in the emitted `upload` body — otherwise a full table
        // leaks the backend atlas (handle is discarded with the
        // error return).
        const guard_idx = std.mem.indexOf(u8, out, "if (idx == MAX_FONT_ASSETS) return error.FontSlotsExhausted") orelse return error.GuardMissing;
        const upload_call_idx = std.mem.indexOf(u8, out, "BackendGfx.uploadFontAtlas(backend_decoded)") orelse return error.UploadCallMissing;
        try std.testing.expect(guard_idx < upload_call_idx);
    }
};
