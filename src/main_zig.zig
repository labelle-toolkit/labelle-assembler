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

/// Build the setup code block for {{setup_code}} (loop-based backends).
fn buildSetupCode(allocator: std.mem.Allocator, cfg: ProjectConfig, jsonc_scene_names: []const []const u8, prefab_names: []const []const u8) ![]const u8 {
    var buf = std.ArrayList(u8){};
    const w = buf.writer(allocator);

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

    // ScriptRunner owns all per-script state + shared context
    try w.writeAll("    var runner = Runner.init(allocator, &g.active_world.ecs_backend);\n");
    try w.writeAll("    defer runner.deinit();\n\n");

    // Load (or register) embedded atlas resources. Lazy resources
    // call `registerAtlasFromMemory` (parses JSON eagerly, defers PNG
    // decode) so a script can decode them on demand. See
    // `buildCallbackInitCode` for the matching code path that the
    // sokol/wasm callback backends use.
    if (cfg.resources.len > 0) {
        try w.writeAll("    // Load sprite atlases (embedded via @embedFile)\n");
        for (cfg.resources) |res| {
            // `null` means the default-inference pass hasn't run (e.g. a
            // direct test call into `generateMainZigFromTemplate`). Fall
            // back to EAGER so an unmigrated-project code path matches
            // the back-compat rule in `lazy_inference.resolveLazyDefaults`
            // — a defaulted + unreferenced resource stays eager so legacy
            // projects keep decoding their atlases at startup.
            const is_lazy = res.lazy orelse false;
            const fn_name = if (is_lazy) "registerAtlasFromMemory" else "loadAtlasFromMemory";
            try w.print("    try g.{s}(\"{s}\", @embedFile(\"{s}\"), @embedFile(\"{s}\"), \".png\");\n", .{ fn_name, res.name, res.json, res.texture });
        }
        try w.writeByte('\n');
    }

    // Pre-load embedded prefabs (must happen before scene loading)
    if (prefab_names.len > 0) {
        try w.writeAll("    // Embedded prefabs (via @embedFile)\n");
        for (prefab_names) |name| {
            try w.print("    try JsoncBridge.addEmbeddedPrefab(&g, \"{s}\", @embedFile(\"prefabs/{s}.jsonc\"), \"prefabs\");\n", .{ name, name });
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

        const initial = cfg.initial_scene orelse jsonc_scene_names[0];
        try w.print("    try g.setScene(\"{s}\");\n", .{initial});
        // Set initial game state (first declared state in project.labelle)
        if (cfg.states.len > 0) {
            try w.print("    g.setState(\"{s}\");\n", .{cfg.states[0]});
        }
        try w.writeByte('\n');
    }

    try w.writeAll("    runner.setup(&g);\n");

    if (cfg.plugins.len > 0) {
        try w.writeAll("    PluginSystems.setup(&g);\n");
        try w.writeAll("    defer PluginSystems.deinit();\n");
    }

    return buf.toOwnedSlice(allocator);
}

/// Build the GUI draw code for {{gui_draw_code}}.
fn buildGuiDrawCode(allocator: std.mem.Allocator, cfg: ProjectConfig, view_names: []const []const u8) ![]const u8 {
    var buf = std.ArrayList(u8){};
    const w = buf.writer(allocator);

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

    return buf.toOwnedSlice(allocator);
}

// ============================================================
// Callback-lifecycle code builders (sokol — init/frame/cleanup callbacks)
// ============================================================

/// Init code for callback-based backends (inside a `!void` helper, can use try).
fn buildCallbackInitCode(allocator: std.mem.Allocator, cfg: ProjectConfig, jsonc_scene_names: []const []const u8, prefab_names: []const []const u8) ![]const u8 {
    var buf = std.ArrayList(u8){};
    const w = buf.writer(allocator);

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
        try w.writeAll("    // Load sprite atlases (embedded via @embedFile)\n");
        for (cfg.resources) |res| {
            // See buildSetupCode for the rationale — null means "inference
            // pass didn't run", which we treat as eager (back-compat) so
            // unmigrated sokol/wasm projects keep decoding their atlases
            // at startup. Must match the fallback in buildSetupCode.
            const is_lazy = res.lazy orelse false;
            const fn_name = if (is_lazy) "registerAtlasFromMemory" else "loadAtlasFromMemory";
            try w.print("    g.{s}(\"{s}\", @embedFile(\"{s}\"), @embedFile(\"{s}\"), \".png\") catch @panic(\"failed to load atlas: {s}\");\n", .{ fn_name, res.name, res.json, res.texture, res.name });
        }
        try w.writeByte('\n');
    }

    // Pre-load embedded prefabs
    if (prefab_names.len > 0) {
        try w.writeAll("    // Embedded prefabs (via @embedFile)\n");
        for (prefab_names) |name| {
            try w.print("    JsoncBridge.addEmbeddedPrefab(&g, \"{s}\", @embedFile(\"prefabs/{s}.jsonc\"), \"prefabs\") catch @panic(\"failed to load prefab\");\n", .{ name, name });
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

        // Attach parsed asset manifests — mirrors the loop-based setup path.
        // See `buildSetupCode` for the rationale. `init` is void here (C
        // compatibility for sokol/wasm callback backends), so we can't
        // propagate with `try`; panic on the impossible SceneNotFound
        // instead of swallowing, matching the `setScene` pattern below.
        try w.writeAll("    inline for (SceneAssetManifests.entries) |scene_asset_entry| {\n");
        try w.writeAll("        g.setSceneAssets(scene_asset_entry.name, scene_asset_entry.assets) catch @panic(\"failed to set scene assets\");\n");
        try w.writeAll("    }\n");

        const initial = cfg.initial_scene orelse jsonc_scene_names[0];
        try w.print("    g.setScene(\"{s}\") catch @panic(\"failed to set initial scene\");\n", .{initial});
        if (cfg.states.len > 0) {
            try w.print("    g.setState(\"{s}\");\n", .{cfg.states[0]});
        }
    }

    try w.writeAll("    runner.setup(&g);\n");

    if (cfg.plugins.len > 0) {
        try w.writeAll("    PluginSystems.setup(&g);\n");
    }

    return buf.toOwnedSlice(allocator);
}

/// Cleanup code for callback-based backends (in cleanup() C callback).
fn buildCallbackCleanupCode(allocator: std.mem.Allocator, cfg: ProjectConfig) ![]const u8 {
    var buf = std.ArrayList(u8){};
    const w = buf.writer(allocator);

    if (cfg.resolved_gui) |gui| {
        if (gui.lifecycle.shutdown) {
            try w.writeAll("    GuiBackend.shutdown();\n");
        }
    }

    if (cfg.plugins.len > 0) {
        try w.writeAll("    PluginSystems.deinit();\n");
    }

    try w.writeAll("    runner.deinit();\n");

    return buf.toOwnedSlice(allocator);
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

/// Convert a path-style name to a valid Zig identifier: "enemies/goblin" -> "enemies_goblin".
/// Replaces `/` and `+` with `_`, strips `.zig` extension.
fn pathToIdent(name: []const u8, buf: *[256]u8) []const u8 {
    if (name.len > buf.len) {
        std.debug.print("labelle: path too long for identifier (max {d} chars): '{s}'\n", .{ buf.len, name });
        @panic("path exceeds identifier buffer size");
    }
    // Strip .zig extension
    const end = if (std.mem.endsWith(u8, name, ".zig")) name.len - 4 else name.len;
    var i: usize = 0;
    for (name[0..end]) |c| {
        buf[i] = if (c == '/' or c == '+') '_' else c;
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
    var data = tpl.TemplateData{
        .scalars = std.StringHashMap([]const u8).init(allocator),
        .lists = std.StringHashMap([]const tpl.ListItem).init(allocator),
    };
    defer data.scalars.deinit();
    defer data.lists.deinit();

    // Track allocations for cleanup
    var allocs = std.ArrayList([]const u8){};
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
    {
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);
        if (hook_names.len > 0) {
            try bw.writeAll("\n// --- Hook imports ---\n");
            for (hook_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print("const {s} = @import(\"hooks/{s}.zig\");\n", .{ ident, name });
            }
        }
        const block = try buf.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("hook_imports_block", block);
    }

    // Event imports block
    {
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);
        if (event_names.len > 0) {
            try bw.writeAll("\n// --- Event imports ---\n");
            for (event_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print("const {s} = @import(\"events/{s}.zig\");\n", .{ ident, name });
            }
        }
        const block = try buf.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("event_imports_block", block);
    }

    // Enum imports block
    {
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);
        if (enum_names.len > 0) {
            try bw.writeAll("\n// --- Enum imports ---\n");
            for (enum_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print("const {s} = @import(\"enums/{s}.zig\");\n", .{ ident, name });
            }
        }
        const block = try buf.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("enum_imports_block", block);
    }

    // JSONC scene block
    {
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);
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
        }
        const block = try buf.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("jsonc_scene_block", block);
    }

    // Game layers block
    {
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);
        try generateGameLayers(cfg.layers, bw);
        const block = try buf.toOwnedSlice(allocator);
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
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);
        if (event_names.len == 0) {
            try bw.writeAll("const AllHookPayloads = engine.HookPayload(EcsBackend.Entity);\n\n");
        } else {
            try bw.writeAll("const AllHookPayloads = engine.core.MergeHookPayloads(.{ engine.HookPayload(EcsBackend.Entity), GameEvents });\n\n");
        }
        const block = try buf.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("all_hook_payloads_block", block);
    }

    // Game hooks block
    {
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);
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
        const block = try buf.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("game_hooks_block", block);
    }

    // Hooks init block — instantiate individual hooks and wire into GameHooks
    {
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);
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
        const block = try buf.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("hooks_init_block", block);
    }

    // Game events block
    {
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);
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
        const block = try buf.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("game_events_block", block);
    }

    // Prefab registry block — JSONC prefabs are loaded at runtime via
    // addEmbeddedPrefab, so the comptime registry is always empty.
    {
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);
        try bw.writeAll("const Prefabs = engine.PrefabRegistry(.{});\n\n");
        const block = try buf.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("prefab_registry_block", block);
    }

    // Component registry block
    {
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);
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
        const block = try buf.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("component_registry_block", block);
    }

    // System registry block
    {
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);
        if (cfg.plugins.len > 0) {
            try bw.writeAll("const PluginSystems = engine.SystemRegistry(.{\n");
            try bw.writeAll("    @import(\"labelle-gfx\"),\n");
            for (cfg.plugins) |plugin| {
                try bw.print("    @import(\"{s}\"),\n", .{plugin.name});
            }
            try bw.writeAll("});\n\n");
            try bw.writeAll("const DiscoveredGizmoCategories = PluginSystems.gizmoCategories();\n\n");
        } else {
            try bw.writeAll("const GizmoCatEntry = struct { name: []const u8, id: u8 };\n");
            try bw.writeAll("const DiscoveredGizmoCategories: []const GizmoCatEntry = &.{};\n\n");
        }
        const block = try buf.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("system_registry_block", block);
    }

    // All scripts block
    {
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);
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
        const block = try buf.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("all_scripts_block", block);
    }

    // View registry block
    {
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);
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
        const block = try buf.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("view_registry_block", block);
    }

    // Gizmo registry block
    {
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);
        if (gizmo_names.len > 0) {
            try bw.writeAll("const Gizmos = engine.GizmoRegistry(.{\n");
            for (gizmo_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print("    .{s} = @import(\"gizmos/{s}.zon\"),\n", .{ ident, name });
            }
            try bw.writeAll("});\n\n");
        }
        const block = try buf.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("gizmo_registry_block", block);
    }

    // Animation registry block
    {
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);
        if (animation_names.len > 0) {
            var anim_pascal_buf: [128]u8 = undefined;
            for (animation_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                const pascal = snakeToPascal(ident, &anim_pascal_buf);
                try bw.print("const {s}Anim = engine.AnimationDef(@import(\"animations/{s}.zon\"));\n", .{ pascal, name });
            }
            try bw.writeAll("\n");
        }
        const block = try buf.toOwnedSlice(allocator);
        try allocs.append(allocator, block);
        try data.scalars.put("animation_registry_block", block);
    }

    // ── Lifecycle section (rendered from backend template, same as procedural path) ──
    {
        var buf = std.ArrayList(u8){};
        const bw = buf.writer(allocator);

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
            const module_vars = if (cfg.backend == .sokol) "var runner: Runner = undefined;\n" else "";
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
                    "var gpa = std.heap.GeneralPurposeAllocator(.{}){};";
                const allocator_expr: []const u8 = if (is_wasm) "std.heap.c_allocator" else "gpa.allocator()";
                const allocator_cleanup: []const u8 = if (is_wasm) "" else "    _ = gpa.deinit();\n";

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
                    .allocator_cleanup = allocator_cleanup,
                }, bw);
            } else {
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
                }, bw);
            }
        } else {
            const setup_code = try buildSetupCode(allocator, cfg, jsonc_scene_names, prefab_names);
            defer allocator.free(setup_code);

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
            }, bw);
        }

        const lifecycle = try buf.toOwnedSlice(allocator);
        try allocs.append(allocator, lifecycle);
        try data.scalars.put("lifecycle", lifecycle);
    }

    // ── Render the engine template ──
    var output = std.ArrayList(u8){};
    errdefer output.deinit(allocator);
    try tpl.renderDynamic(engine_template, data, output.writer(allocator));
    return output.toOwnedSlice(allocator);
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
