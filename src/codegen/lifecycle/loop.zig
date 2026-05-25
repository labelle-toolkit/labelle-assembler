//! Loop-lifecycle code builders for backends that drive `main()` themselves
//! (raylib desktop, sdl, bgfx, wgpu).
//!
//! Extracted from `src/main_zig.zig` as the eighth step of the #183 refactor
//! (see `docs/REFACTOR-PLAN-main-zig.md`). Pure cut + import — call order
//! across `writeXxxWiring` + `emitResourceLoad` is preserved byte-for-byte,
//! verified with `scripts/gen_all_examples.sh`.
//!
//! Helpers reached through `main_zig.zig` (`writeImageBackendWiring`,
//! `writeAudioBackendWiring`, `writeFontBackendWiring`, `emitResourceLoad`,
//! `LoadStyle`) are still inline in the orchestrator on this branch — the
//! parallel `blocks/asset_wiring.zig` + `blocks/resource_loader.zig` cuts
//! (PRs #197, #199) move them out to their own modules; this file's imports
//! flip to those locations as part of that merge.
const std = @import("std");
const config = @import("../../config.zig");
const main_zig = @import("../../main_zig.zig");
const scan = @import("../scan.zig");

const ProjectConfig = config.ProjectConfig;
const ResourceDef = config.ResourceDef;

const writeImageBackendWiring = main_zig.writeImageBackendWiring;
const writeAudioBackendWiring = main_zig.writeAudioBackendWiring;
const writeFontBackendWiring = main_zig.writeFontBackendWiring;
const emitResourceLoad = main_zig.emitResourceLoad;
const pathToIdent = scan.pathToIdent;

pub fn buildSetupCode(allocator: std.mem.Allocator, cfg: ProjectConfig, jsonc_scene_names: []const []const u8, prefab_names: []const []const u8) ![]const u8 {
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

pub fn buildGuiDrawCode(allocator: std.mem.Allocator, cfg: ProjectConfig, view_names: []const []const u8) ![]const u8 {
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

/// Mixin factory for `Codegen` (labelle-assembler#183, mixin conversion).
///
/// Pulls `allocator`, `cfg`, `jsonc_scene_names`, `prefab_names`,
/// `view_names` from `self` so the orchestrator dispatches
/// `ctx.buildSetupCode()` / `ctx.buildGuiDrawCode()` without re-
/// threading those slices. Standalone functions above stay `pub` for
/// the test surface (`test/tests.zig`'s `buildSetupCode` shape
/// assertions).
pub fn Mixin(comptime Self: type) type {
    return struct {
        pub fn buildSetupCode(self: *Self) ![]const u8 {
            return impl.buildSetupCode(self.allocator, self.cfg, self.jsonc_scene_names, self.prefab_names);
        }
        pub fn buildGuiDrawCode(self: *Self) ![]const u8 {
            return impl.buildGuiDrawCode(self.allocator, self.cfg, self.view_names);
        }
    };
}

const impl = struct {
    pub const buildSetupCode = @import("loop.zig").buildSetupCode;
    pub const buildGuiDrawCode = @import("loop.zig").buildGuiDrawCode;
};
