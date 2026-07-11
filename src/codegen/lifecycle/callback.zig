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
//! The asset-wiring + resource-loader helpers
//! (`writeImageBackendWiring`, `writeAudioBackendWiring`,
//! `writeFontBackendWiring`, `emitResourceLoad`, `LoadStyle`) are
//! pulled directly from `../blocks/asset_wiring.zig` and
//! `../blocks/resource_loader.zig` — both blocks live in the same
//! umbrella, so the previous routing through `main_zig.zig` (kept as
//! a forward-compat shim during the staged extraction) is gone.
//! `pathToIdent` comes straight from `codegen/scan.zig`.
//!
//! Mixin-only surface: the previous standalone `pub fn buildXxx` forms
//! were collapsed into the mixin methods once `main_template.zig`
//! migrated to `ctx.buildXxx()` dispatch (labelle-assembler#206
//! follow-up). `self.allocator`, `self.cfg`, `self.jsonc_scene_names`,
//! `self.prefab_names` carry what used to be positional args.

const std = @import("std");
const config = @import("../../config.zig");
const scan = @import("../scan.zig");
const asset_wiring = @import("../blocks/asset_wiring.zig");
const resource_loader = @import("../blocks/resource_loader.zig");
const tilemap_assets = @import("../blocks/tilemap_assets.zig");
const post_fx_block = @import("../blocks/post_fx.zig");

const ProjectConfig = config.ProjectConfig;

const pathToIdent = scan.pathToIdent;
const writeImageBackendWiring = asset_wiring.writeImageBackendWiring;
const writeAudioBackendWiring = asset_wiring.writeAudioBackendWiring;
const writeFontBackendWiring = asset_wiring.writeFontBackendWiring;
const emitResourceLoad = resource_loader.emitResourceLoad;
const LoadStyle = resource_loader.LoadStyle;

/// Mixin factory for `Codegen` (labelle-assembler#183, mixin conversion).
///
/// Reads `allocator`, `cfg`, `jsonc_scene_names`, `prefab_names` from
/// `self`. Methods produce the three callback-lifecycle code fragments
/// the orchestrator splices into the sokol/wasm/Android template holes.
pub fn Mixin(comptime Self: type) type {
    return struct {
        /// Init code for callback-based backends (inside a `!void`
        /// helper, can use try).
        pub fn buildCallbackInitCode(self: *Self) ![]const u8 {
            const allocator = self.allocator;
            const cfg = self.cfg;
            const jsonc_scene_names = self.jsonc_scene_names;
            const prefab_names = self.prefab_names;

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
            if (prefab_names.len > 0 or self.hasPackPrefabs()) {
                try w.writeAll("    // Embedded prefabs (via @embedFile)\n");
                for (prefab_names) |name| {
                    const display = std.fs.path.basename(name);
                    try w.print("    JsoncBridge.addEmbeddedPrefab(&g, \"{s}\", @embedFile(\"prefabs/{s}.jsonc\"), \"prefabs\") catch @panic(\"failed to load prefab\");\n", .{ display, name });
                }
                // Pack prefabs (Packs RFC §4, #439) — see the loop-lifecycle
                // sibling for rationale. Embedded from the pack's prefix; the
                // callback host has no error channel, so panic-on-failure. The
                // prefab root is the pack's own `<import_prefix>/prefabs` so a
                // pack prefab's `"include"` / source-relative lookups resolve
                // against the copied pack dir, not the game's (chatgpt-codex, #478).
                // The registration KEY is the invisible `<pack>__<display>`
                // (#440) so a pack and the game root that both ship `worker`
                // don't collide in the runtime name→source registry.
                var pack_prefix_buf: [128]u8 = undefined;
                for (self.pack_scans) |pack| {
                    const prefix = scan.packNamespacePrefix(pack.name, &pack_prefix_buf);
                    for (pack.prefab_names) |name| {
                        const display = std.fs.path.basename(name);
                        try w.print("    JsoncBridge.addEmbeddedPrefab(&g, \"{s}__{s}\", @embedFile(\"{s}/prefabs/{s}.jsonc\"), \"{s}/prefabs\") catch @panic(\"failed to load prefab\");\n", .{ prefix, display, pack.import_prefix, name, pack.import_prefix });
                    }
                }
                try w.writeByte('\n');
            }

            // Embedded tilemaps (T2 Phase 4). Register every scene-referenced
            // `.tmx` + its tileset images BEFORE `setScene` below — the
            // engine decodes a Tilemap component's `.tmx` during scene load,
            // reading the bytes back from this same registry. The
            // sokol/wasm callback host has no error channel, so this uses
            // `.catch_panic_style` (matching the atlas loads above). No-op
            // for a tilemap-free project.
            try tilemap_assets.emitTilemapRegistrations(w, self.tilemap_registrations, .catch_panic_style);

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

                // Hand each scene's JSONC source to the engine by NAME for
                // sprite-based asset inference (labelle-engine#563) — see the
                // loop-based setup path for the full rationale. Gated on
                // `@hasDecl` for forward-compat with older engines; `init` is
                // void here (C-callback backends) so panic on the impossible
                // SceneNotFound instead of `try`, matching setSceneAssets above.
                for (jsonc_scene_names) |name| {
                    try w.print("    if (@hasDecl(AssembledGame, \"setSceneSource\")) g.setSceneSource(\"{s}\", @embedFile(\"scenes/{s}.jsonc\")) catch @panic(\"failed to set scene source\");\n", .{ name, name });
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

            // Seed the declared static post-fx stack (labelle-gfx#305 P2 Slice
            // C) — same lexical slot + IDENTICAL statement as the loop path.
            // `setPostFx` is void, so no `catch @panic` distinction here.
            // Gated on `@hasDecl(AssembledGame, "setPostFx")` for forward-compat;
            // no-op when `.post_fx` is empty.
            try post_fx_block.emitPostFxSetup(w, cfg, "    ");

            try w.writeAll("    runner.setup(&g);\n");

            // Embedded language scripts (labelle-assembler#593) — mirrors the
            // loop-path emission in `loop.zig`: register every copied
            // convention-dir source (`lua/`, `ts/` — the splice's `dir`)
            // with the scripting plugin BEFORE `PluginControllers.setup`
            // below boots the VM. Pre-sorted stems, byte-stable; no-op for
            // splice-less projects. EMBED family only (labelle-engine#741):
            // native-compiled splices link, never embed — see loop.zig.
            if (self.scripting) |s| {
                if (s.family == .embed and s.script_names.len > 0) {
                    try w.writeByte('\n');
                    try w.print("    // Embedded {s} scripts (via @embedFile) — registered with the\n", .{s.language});
                    try w.writeAll("    // scripting plugin before PluginControllers.setup boots the VM.\n");
                    for (s.script_names) |name| {
                        try w.print("    scripting.registerScript(\"{s}\", @embedFile(\"{s}/{s}{s}\"));\n", .{ name, s.dir, name, s.extension });
                    }
                    try w.writeByte('\n');
                }
            }

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

        /// Body for the `{{immersive_entry}}` hole in the sokol
        /// `mobile.txt` template, emitted at the top of `sokol_main()`. On
        /// Android it carries two things, in order:
        ///
        ///   1. **Backend-context registration (labelle-core#310, Stage 3).**
        ///      Core's Android gamepad source + the engine's immersive call no
        ///      longer link sokol's `sapp_*` / `labelle_android_gamepad_*`
        ///      symbols directly — they route through an
        ///      `AndroidBackendContext` vtable the active backend registers at
        ///      startup. The sokol backend's adapter
        ///      (`backends/sokol/src/android.zig`, surfaced as
        ///      `backend_input.android`) builds that context; we register it
        ///      here so sokol-Android keeps immersive mode + gamepad detection.
        ///      This MUST run before `enableImmersiveMode()` (which reads the
        ///      registered context's `get_native_activity`) and before the
        ///      gamepad source initializes. Emitted on EVERY sokol-Android
        ///      build, even when immersive mode is off, because gamepad
        ///      detection needs it too.
        ///   2. **Immersive mode (`.android.immersive_mode`).** The
        ///      `engine.android.enableImmersiveMode()` call (only when opted
        ///      in).
        ///
        /// **Why `sokol_main()` and not `init()`:** the legacy
        /// `Theme.NoTitleBar.Fullscreen` manifest theme `labelle-cli`
        /// writes does NOT hide the system bars on modern Android
        /// (verified broken on Android 14 / API 34) — Google moved
        /// system-bar control to a runtime API.
        /// `enableImmersiveMode()` installs a UI-thread callback hook
        /// that performs that runtime JNI call.
        ///
        /// sokol's `ANativeActivity_onCreate` invokes `sokol_main()` on
        /// the **UI thread**, before it registers its own
        /// `ANativeActivityCallbacks` — early enough that the hook fires
        /// at launch. The `init()` callback, by contrast, runs on
        /// sokol's render thread *after* the window's first
        /// `onWindowFocusChanged`; a hook installed there misses that
        /// first focus event, leaving the bars visible until the player
        /// background+foregrounds the app. See
        /// `labelle-engine/src/android.zig`.
        ///
        /// Returns an empty string off Android; the placeholder then expands to
        /// nothing (and is harmless in the shared sokol desktop / wasm
        /// `desktop.txt`, which has no `{{immersive_entry}}` hole at all).
        pub fn buildImmersiveEntryCode(self: *Self) ![]const u8 {
            const allocator = self.allocator;
            const cfg = self.cfg;
            if (cfg.platform != .android) return allocator.dupe(u8, "");

            var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
            errdefer alloc_writer.deinit();
            const w = &alloc_writer.writer;

            // (1) Register the sokol backend's Android JNI seam with core
            //     (labelle-core#310). Routes core's gamepad source + the
            //     engine's immersive call to sokol's native activity / JNI glue
            //     without core/engine linking any sokol symbol directly. Runs
            //     ONCE at startup, before the immersive call below and before
            //     the gamepad source initializes. `engine.core` is
            //     labelle-engine's re-export of labelle-core (the generated main
            //     imports `engine`); the context comes from the sokol backend
            //     adapter surfaced as `backend_input.android`.
            try w.writeAll(
                \\    // Register the sokol Android backend seam with core (labelle-core#310):
                \\    // core's gamepad source and the engine's immersive mode reach the
                \\    // running ANativeActivity / InputManager JNI glue through this context
                \\    // instead of linking sokol's symbols directly. Must run before
                \\    // `enableImmersiveMode()` (it reads `get_native_activity`) and before
                \\    // the gamepad source initializes. See backends/sokol/src/android.zig.
                \\    engine.core.registerAndroidBackend(@import("backend_input").android.backendContext());
                \\
            );

            // (2) Immersive mode — only when opted in.
            const immersive = if (cfg.android) |a| a.immersive_mode else false;
            if (immersive) {
                try w.writeAll(
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

            var arr_list = alloc_writer.toArrayList();
            return arr_list.toOwnedSlice(allocator);
        }

        /// Cleanup code for callback-based backends (in cleanup() C
        /// callback).
        pub fn buildCallbackCleanupCode(self: *Self) ![]const u8 {
            const allocator = self.allocator;
            const cfg = self.cfg;

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
    };
}
