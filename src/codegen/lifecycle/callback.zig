//! Callback-lifecycle code builders for sokol / wasm / Android backends.
//!
//! Extracted from `src/main_zig.zig` as the eighth step of the cut plan
//! in `docs/REFACTOR-PLAN-main-zig.md` (labelle-assembler#183, "8b —
//! HIGH risk"). Holds the three builders the orchestrator invokes
//! to fill the callback-backend template holes:
//!
//!   - `buildCallbackInitCode`     — init() callback body (sokol/wasm)
//!   - `buildImmersiveEntryCode`   — sokol_main() body for Android
//!                                    immersive-mode bootstrap
//!   - `buildCallbackCleanupCode`  — cleanup() callback body
//!
//! **Call-order sensitivity.** `buildCallbackInitCode` mirrors the
//! order in `buildSetupCode` (the loop-lifecycle sibling): image
//! backend wiring first, then conditional audio/font, then resource
//! loads, then prefabs, then JSONC scenes + manifests + initial
//! state, then `setScene`, then `runner.setup`, then plugin systems
//! and controllers. Any reordering changes the generated `main.zig`
//! and is detectable through `scripts/gen_all_examples.sh`.
//!
//! Pure move + re-export. The asset-wiring + resource-loader helpers
//! (`writeImageBackendWiring`, `writeAudioBackendWiring`,
//! `writeFontBackendWiring`, `emitResourceLoad`, `LoadStyle`) are
//! pulled directly from `../blocks/asset_wiring.zig` and
//! `../blocks/resource_loader.zig` — both blocks now live in this
//! umbrella, so the previous routing through `main_zig.zig` (kept as
//! a forward-compat shim during the staged extraction) is gone.
//! `pathToIdent` comes straight from `codegen/scan.zig`.

const std = @import("std");
const config = @import("../../config.zig");
const scan = @import("../scan.zig");
const asset_wiring = @import("../blocks/asset_wiring.zig");
const resource_loader = @import("../blocks/resource_loader.zig");

const ProjectConfig = config.ProjectConfig;

const pathToIdent = scan.pathToIdent;
const writeImageBackendWiring = asset_wiring.writeImageBackendWiring;
const writeAudioBackendWiring = asset_wiring.writeAudioBackendWiring;
const writeFontBackendWiring = asset_wiring.writeFontBackendWiring;
const emitResourceLoad = resource_loader.emitResourceLoad;
const LoadStyle = resource_loader.LoadStyle;

/// Init code for callback-based backends (inside a `!void` helper, can use try).
pub fn buildCallbackInitCode(allocator: std.mem.Allocator, cfg: ProjectConfig, jsonc_scene_names: []const []const u8, prefab_names: []const []const u8) ![]const u8 {
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

        const initial = cfg.resolvedInitialPrefab() orelse jsonc_scene_names[0];
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
pub fn buildImmersiveEntryCode(allocator: std.mem.Allocator, cfg: ProjectConfig) ![]const u8 {
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
pub fn buildCallbackCleanupCode(allocator: std.mem.Allocator, cfg: ProjectConfig) ![]const u8 {
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

/// Mixin factory for `Codegen` (labelle-assembler#183, mixin conversion).
///
/// Pulls `allocator`, `cfg`, `jsonc_scene_names`, `prefab_names` from
/// `self`. Standalone functions above stay `pub` for the test surface
/// (`test/tests.zig`'s `buildCallbackInitCode` shape assertion).
pub fn Mixin(comptime Self: type) type {
    // Capture the enclosing file's namespace so the same-name methods
    // below can reach the standalone bodies without shadowing recursion.
    // `@This()` evaluated here (in the factory body, outside the returned
    // struct) resolves to the file namespace; survives file renames that
    // an `@import("self.zig")` workaround would silently break.
    const file = @This();
    return struct {
        pub fn buildCallbackInitCode(self: *Self) ![]const u8 {
            return file.buildCallbackInitCode(self.allocator, self.cfg, self.jsonc_scene_names, self.prefab_names);
        }
        pub fn buildImmersiveEntryCode(self: *Self) ![]const u8 {
            return file.buildImmersiveEntryCode(self.allocator, self.cfg);
        }
        pub fn buildCallbackCleanupCode(self: *Self) ![]const u8 {
            return file.buildCallbackCleanupCode(self.allocator, self.cfg);
        }
    };
}
