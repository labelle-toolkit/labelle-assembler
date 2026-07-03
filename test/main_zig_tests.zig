const std = @import("std");
const zspec = @import("zspec");
const generate = @import("generator");
const h = @import("helpers.zig");

const engine_template = h.engine_template;
const raylib_lifecycle = h.raylib_lifecycle;
const sokol_lifecycle = h.sokol_lifecycle;
const bgfx_android_lifecycle = h.bgfx_android_lifecycle;
const sokol_mobile_lifecycle = h.sokol_mobile_lifecycle;
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

pub const MAIN_ZIG = struct {
    test "uses MockEcsBackend for mock ecs" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "MockEcsBackend") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"ecs_backend\")") == null);
    }

    test "uses EcsAdapter for real ecs" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .zflecs,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "EcsAdapter") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "ecs_backend") != null);
    }

    test "contains window dimensions" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .title = "My Game",
            .width = 1024,
            .height = 768,
            .target_fps = 120,
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "1024") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "768") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "120") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "My Game") != null);
    }

    test "no gui uses StubGui" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "StubGui") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "gui_backend") == null);
    }

    test "resolved_gui wires gui_backend in main.zig" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resolved_gui = testGuiRenderInterface("clay"),
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "gui_backend") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "StubGui") == null);
    }

    test "resolved_gui with lifecycle generates init/shutdown" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resolved_gui = testGuiRawBackend("imgui"),
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "GuiBackend.init()") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "GuiBackend.shutdown()") != null);
    }

    test "resolved_gui render_interface omits init/shutdown" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resolved_gui = testGuiRenderInterface("clay"),
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "GuiBackend.init()") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "GuiBackend.shutdown()") == null);
    }

    test "resolved_gui in zon includes labelle_gui dep" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resolved_gui = testGuiRenderInterface("clay"),
        }, null, null, null, .{});
        defer std.testing.allocator.free(zon);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_gui") != null);
    }

    test "resolved_gui raw_backend in zon includes gui_bridge dep" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resolved_gui = testGuiRawBackend("imgui"),
        }, null, null, null, .{});
        defer std.testing.allocator.free(zon);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_gui") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "gui_bridge") != null);
    }

    test "sets renderer screen height" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .height = 768,
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "setScreenHeight") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "768") != null);
    }

    test "sdl generates loop-based main" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sdl,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub fn main()") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "MockEcsBackend") != null);
    }

    test "bgfx android generates callback-driven main owning android_main" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .bgfx,
            .platform = .android,
            .ecs = .mock,
        }, bgfx_android_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // bgfx-android (#303) takes the CALLBACK path, not the desktop loop:
        // the game exports `android_main`, opts the shell out of its own
        // export, and registers init + tick callbacks. No `pub fn main()`
        // and no `shouldQuit` loop.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "export fn android_main(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const labelle_provides_android_main = true;") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "android_app.setInitCallback(&gameInit)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "android_app.setTickCallback(&gameFrame)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "android_app.run(app)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub fn main()") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "shouldQuit") == null);
        // Module-scope runner (assigned in gameInit), not an init-scope local.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var runner: Runner = undefined;") != null);
    }

    test "bgfx android immersive registers the UI-thread hide callback (bgfx-immersive)" {
        // The engine's hook-based `enableImmersiveMode()` cannot work on bgfx
        // (native_app_glue owns onContentRectChanged) and the hide must run on
        // the UI thread (not the glue app thread the frame loop runs on). So the
        // codegen registers the engine's UI-thread hide with the shell, which
        // chains onWindowFocusChanged (a UI-thread callback). Assert the
        // registration lands in `android_main`, before `run`.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .bgfx,
            .platform = .android,
            .ecs = .mock,
            .android = .{ .immersive_mode = true },
        }, bgfx_android_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // The UI-thread hide is registered with the shell.
        const reg = "android_app.setImmersiveCallback(&engine.android.applyImmersiveUiThread);";
        const reg_idx = std.mem.indexOf(u8, main_zig, reg);
        try std.testing.expect(reg_idx != null);

        // Registration must precede `run(app)` — the shell installs the focus
        // chain inside `run`, reading the registered callback.
        const run_idx = std.mem.indexOf(u8, main_zig, "android_app.run(app)");
        try std.testing.expect(run_idx != null);
        try std.testing.expect(reg_idx.? < run_idx.?);

        // bgfx must NOT call the no-op sokol hook path. (The emitted comment
        // mentions enableImmersiveMode by name, so match the CALL form.)
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.android.enableImmersiveMode(") == null);
    }

    test "bgfx android does NOT register the immersive callback when immersive is off" {
        // Without the opt-in, no immersive call of any kind: the shell still
        // chains onWindowFocusChanged but with no callback registered it just
        // forwards, so applyImmersiveUiThread is never referenced.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .bgfx,
            .platform = .android,
            .ecs = .mock,
        }, bgfx_android_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "setImmersiveCallback") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "applyImmersiveUiThread") == null);
    }

    test "sokol android registers the core Android backend seam before immersive (labelle-core#310)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .platform = .android,
            .ecs = .mock,
            .android = .{ .immersive_mode = true },
        }, sokol_mobile_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Stage 3 (labelle-core#310): the generated `sokol_main()` registers the
        // sokol backend's AndroidBackendContext with core, sourced from the
        // backend adapter (`backend_input.android.backendContext()`), via the
        // engine's core re-export.
        const reg = "engine.core.registerAndroidBackend(@import(\"backend_input\").android.backendContext());";
        const reg_idx = std.mem.indexOf(u8, main_zig, reg);
        try std.testing.expect(reg_idx != null);

        // The immersive call is still emitted (immersive_mode = true)...
        const imm_idx = std.mem.indexOf(u8, main_zig, "engine.android.enableImmersiveMode();");
        try std.testing.expect(imm_idx != null);

        // ...and registration MUST precede it — core's immersive path reads the
        // registered context's `get_native_activity`, so registering after would
        // make it a no-op. Both run inside `sokol_main()` (the UI thread, before
        // sokol registers its own ANativeActivity callbacks), so this textual
        // ordering is also the runtime ordering. Core's gamepad source likewise
        // reads the context lazily at first poll (well after `sokol_main()`), so
        // registering at the top of `sokol_main()` precedes every consumer.
        try std.testing.expect(reg_idx.? < imm_idx.?);
    }

    test "sokol android registers the backend seam even when immersive mode is off" {
        // Gamepad detection needs the context regardless of immersive mode, so
        // the registration is emitted on every sokol-Android build; only the
        // immersive call is gated on `.android.immersive_mode`.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .platform = .android,
            .ecs = .mock,
        }, sokol_mobile_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.core.registerAndroidBackend(") != null);
        // No immersive call without the opt-in.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.android.enableImmersiveMode();") == null);
    }

    test "non-android sokol does NOT emit the Android backend registration" {
        // Desktop sokol must not reference the Android seam — the registration
        // is gated to sokol + Android in `buildImmersiveEntryCode`.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, sokol_mobile_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerAndroidBackend") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "enableImmersiveMode") == null);
    }

    // ── RFC-Y-AXIS-CONVENTION (#370) ────────────────────────────────────

    test "y_axis = .up overrides the project_y_axis const to .up" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .y_axis = .up,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // The engine template's single `project_y_axis` const is overridden to
        // the project's choice; it feeds both `GfxRendererWith` and the
        // y-axis-aware `GameConfigWithYAxis` (so output flip + input picking agree).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.GameConfigWithYAxis(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.GameConfig(") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const project_y_axis: engine.core.YAxis = .up;") != null);
    }

    test "y_axis = .down overrides the project_y_axis const to .down" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .y_axis = .down,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // The const is flipped to .down — and the .up default is gone.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.GameConfigWithYAxis(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const project_y_axis: engine.core.YAxis = .down;") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const project_y_axis: engine.core.YAxis = .up;") == null);
    }

    test "absent y_axis triggers the unset-guard hard error" {
        // The safety net (RFC Migration): an unset `.y_axis` is rejected so
        // no existing game silently flips when the framework default flips to
        // `.down`. The error is surfaced as `error.MissingYAxis`.
        const result = generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            // .y_axis intentionally omitted
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        try std.testing.expectError(error.MissingYAxis, result);
    }
};

pub const NULL_BACKEND = struct {
    test "null backend generates headless main with no sokol_app.run" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .null,
            .ecs = .mock,
        }, null_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Real `pub fn main()` orchestrates the lifecycle — not a sokol
        // export-fn triple driven by `sapp_run`.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub fn main()") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "export fn init() callconv(.c) void") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "sapp_run") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.run(.{") == null);
        // Frame-counter loop, not a shouldQuit loop.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "while (frame < max_frames)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "shouldQuit") == null);
    }

    test "null backend wires LABELLE_PREVIEW env-var (control plane works)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .null,
            .ecs = .mock,
        }, null_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // LABELLE_PREVIEW handshake: parse env, dial editor, send hello,
        // tick heartbeats, send bye. The wire is GPU-independent — only
        // the readback path is GPU-bound — so headless preview is real.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_preview_getenv(\"LABELLE_PREVIEW\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.Preview.connect") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "sendHello") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "tickHeartbeat") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "sendBye") != null);
    }

    test "null backend does NOT emit PREVIEW_READBACK_* blocks" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .null,
            .ecs = .mock,
        }, null_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // No GPU → no GL/D3D11/Metal readback helpers, no publishFrame
        // path. The raylib desktop branch (and the three sokol slices)
        // own those; null must stay clear of every one of them.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_preview_pbos") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_gl_read_pixels") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "publishFrame") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "publishFrameIOSurface") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "beginFrameStream") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "endFrameStream") == null);
    }

    test "external backend emits the core-contract verification guard (#386 Phase 6b)" {
        // A fetched out-of-tree backend has no enum-path codegen to vet it, so
        // generated main.zig asserts its modules satisfy labelle-core's render /
        // window / input contracts up front — a missing decl then fails with a
        // decl-naming message at this call site, not deep in engine wiring.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend_package = .{ .name = "nullfixture", .repo = "local:../nf" },
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "assertBackend(@import(\"backend_gfx\"))") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "assertWindow(@import(\"backend_window\"))") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "assertInput(@import(\"backend_input\"))") != null);
    }

    test "external backend emits directional per-sub-surface contract-version asserts (#453 item 1)" {
        // Contract versioning (labelle-assembler#453): on top of the shape check
        // above, each sub-surface gets a `@hasDecl`-guarded DIRECTIONAL version
        // assert comparing the backend's `targets_<surface>_contract` against
        // labelle-core's `<SURFACE>_CONTRACT_VERSION`. Both a too-new (`>`,
        // upgrade core) and a too-old (`<`, upgrade backend) branch are emitted,
        // so ANY mismatch is a `@compileError` naming which side to bump. The
        // `@hasDecl` guard is the no-flag-day property: a backend that hasn't
        // adopted `targets_*` is untouched (guarded body isn't analyzed).
        //
        // NOTE: the negative direction (a MISMATCHED `targets_*` -> build fails)
        // is a Sema-level `@compileError` that requires a full backend+core
        // compile the assembler's string-golden test harness does not run. It is
        // covered by inspection here: we assert BOTH the `>`/provides and the
        // `<`/expects `@compileError` branches are present for every sub-surface,
        // so the failing comparison provably exists in the generated source.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend_package = .{ .name = "nullfixture", .repo = "local:../nf" },
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // The four backend-sub-surface module bindings the version guards read.
        // `backend_audio` is newly imported into this comptime block for #453.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const _bc_gfx = @import(\"backend_gfx\");") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const _bc_window = @import(\"backend_window\");") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const _bc_input = @import(\"backend_input\");") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const _bc_audio = @import(\"backend_audio\");") != null);

        // Every sub-surface: the `@hasDecl` opt-in guard + BOTH directional
        // `@compileError` comparisons (`>` provides / `<` expects) against the
        // matching labelle-core `*_CONTRACT_VERSION` const.
        const Case = struct { mod: []const u8, decl: []const u8, core: []const u8 };
        const cases = [_]Case{
            .{ .mod = "_bc_gfx", .decl = "targets_draw_contract", .core = "DRAW_CONTRACT_VERSION" },
            .{ .mod = "_bc_gfx", .decl = "targets_loader_contract", .core = "LOADER_CONTRACT_VERSION" },
            .{ .mod = "_bc_window", .decl = "targets_window_contract", .core = "WINDOW_CONTRACT_VERSION" },
            .{ .mod = "_bc_input", .decl = "targets_input_contract", .core = "INPUT_CONTRACT_VERSION" },
            .{ .mod = "_bc_audio", .decl = "targets_audio_playback_contract", .core = "AUDIO_PLAYBACK_CONTRACT_VERSION" },
            .{ .mod = "_bc_audio", .decl = "targets_audio_loader_contract", .core = "AUDIO_LOADER_CONTRACT_VERSION" },
        };
        inline for (cases) |c| {
            const guard = "@hasDecl(" ++ c.mod ++ ", \"" ++ c.decl ++ "\")";
            const too_new = "if (" ++ c.mod ++ "." ++ c.decl ++ " > _backend_contract_core." ++ c.core ++ ")";
            const too_old = "if (" ++ c.mod ++ "." ++ c.decl ++ " < _backend_contract_core." ++ c.core ++ ")";
            try std.testing.expect(std.mem.indexOf(u8, main_zig, guard) != null);
            try std.testing.expect(std.mem.indexOf(u8, main_zig, too_new) != null);
            try std.testing.expect(std.mem.indexOf(u8, main_zig, too_old) != null);
        }

        // Both @compileError message directions ("provides" = upgrade core,
        // "expects" = upgrade backend) are present at least once.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "upgrade labelle-core") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "upgrade the backend") != null);
        // Messages are built at comptime from the actual version numbers.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "std.fmt.comptimePrint(") != null);

        // ORDER (#453 finding): the directional VERSION asserts must be emitted
        // BEFORE the shape (`assertBackend`/`assertWindow`/`assertInput`) asserts.
        // Otherwise a shape assert can `@compileError` first on a decl the newer
        // contract renamed/added, and the intended directional "upgrade the
        // backend / labelle-core" message never fires.
        const first_version_guard = std.mem.indexOf(u8, main_zig, "@hasDecl(_bc_gfx, \"targets_draw_contract\")").?;
        const first_shape_assert = std.mem.indexOf(u8, main_zig, "assertBackend(@import(\"backend_gfx\"))").?;
        try std.testing.expect(first_version_guard < first_shape_assert);
    }

    // NOTE: the companion "built-in backend emits NO contract guard" test was
    // removed in #386 Phase 6c. The guard is gated on `cfg.isExternal()`, and
    // post-flip EVERY built-in backend resolves to an external provider package,
    // so the no-guard branch is no longer reachable from any `.backend = .<tag>`
    // config — every backend now emits the contract guard (covered by the
    // external-backend test directly above). The `if (!cfg.isExternal()) return`
    // in `codegen/blocks/imports.zig` is retained as defensive dead code.

    test "external backend with a callback run-loop is rejected (not yet wired, #386)" {
        // `.platform = .wasm` forces `use_callback_lifecycle = true`; paired with
        // an external `backend_package` this must fail FAST rather than fall
        // through the `cfg.backend == .sokol` checks into the raylib-wasm callback
        // branch (cfg.backend sits at its `.raylib` default for an external
        // backend). Callback-style external backends aren't wired through codegen
        // yet — only loop-style are.
        try std.testing.expectError(error.ExternalCallbackBackendUnsupported, generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .platform = .wasm,
            .backend_package = .{ .name = "cbexternal", .repo = "local:../cb" },
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions));
    }

    test "external bgfx-android is NOT rejected — it has a real callback dispatch path (#386)" {
        // The callback-external guard must reject only backends that would fall
        // through to the raylib-wasm fallback. An EXTERNAL bgfx on Android keeps
        // `cfg.backend == .bgfx` (the enum-as-shorthand preserves the tag), so
        // `is_bgfx_android` still fires and the callback dispatch has a real
        // branch — it must generate the bgfx-android callback main, not error.
        // (Setting both `.backend = .bgfx` and `.backend_package` models the
        // post-flip state: external resolution + preserved enum tag.)
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .bgfx,
            .platform = .android,
            .backend_package = .{ .name = "bgfx", .repo = "local:../bgfx" },
            .ecs = .mock,
        }, bgfx_android_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Took the bgfx-android callback path (owns android_main), not the error
        // and not the raylib-wasm fallback.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "export fn android_main(") != null);
    }

    test "external sokol-desktop is NOT rejected — it has a real callback dispatch path (#454)" {
        // Regression-lock for the #454 re-check: sokol is now a fully EXTERNAL
        // backend (`builtinProvider(.sokol)` resolves to labelle-sokol), and it
        // declares a `.callback` run-loop. The callback-external guard must NOT
        // reject it — the enum-as-shorthand preserves `cfg.backend == .sokol`, so
        // `callback_dispatch_handled` is true and the sokol callback dispatch has
        // a real branch. This must generate the sokol callback main (export
        // init/frame/cleanup), not `error.ExternalCallbackBackendUnsupported`.
        // (Setting both `.backend = .sokol` and `.backend_package` models the
        // post-flip state: external resolution + preserved enum tag. If someone
        // ever drops `cfg.backend == .sokol` from `callback_dispatch_handled`,
        // this test fails instead of production silently breaking sokol-desktop.)
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .platform = .desktop,
            .backend_package = .{ .name = "sokol", .repo = "local:../sokol" },
            .ecs = .mock,
        }, sokol_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Took the sokol callback path (exported init/frame/cleanup callbacks),
        // not the error and not the raylib-wasm fallback.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "export fn frame() callconv(.c) void") != null);
    }

    test "third-party callback backend with a declared lifecycle GENERATES (assembler#501)" {
        // The end goal: a STRING-NAMED callback backend (no enum tag, `cfg.backend`
        // at its `.raylib` default) that declares its callback-lifecycle blocks in
        // its v2 manifest generates a valid callback main — no
        // `error.ExternalCallbackBackendUnsupported`. The manifest declaration is
        // threaded via the `lifecycle_override` threadlocal (production resolves the
        // SAME value from `.platforms.desktop.lifecycle` via
        // `resolveLifecycleOverride`); `loop_style_override = .callback` mirrors the
        // manifest's `loop_style` so `use_callback_lifecycle` fires without an enum tag.
        generate.main_template.loop_style_override = .callback;
        defer generate.main_template.loop_style_override = null;
        generate.main_template.lifecycle_override = h.acme_callback_lifecycle_decl;
        defer generate.main_template.lifecycle_override = null;

        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .platform = .desktop,
            .backend_package = h.acme_callback_fixture_package,
            .ecs = .mock,
        }, h.acme_callback_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Callback shape: exported C callbacks + the module-scope runner the
        // declared `runner_module_var` block emits (via `{{module_vars}}`), plus
        // the `cleanup_callback` teardown (`runner.deinit();`).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "export fn init() callconv(.c) void") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "export fn frame() callconv(.c) void") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "export fn cleanup() callconv(.c) void") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var runner: Runner = undefined;") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "runner.deinit();") != null);
        // NOT the loop shape — no `while (!shouldQuit())` marker.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "shouldQuit") == null);
        // NO backend-private holes leaked in: no sokol readback, no imgui bridge.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "imgui_bridge_handle_event") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_sokol_preview") == null);
    }

    test "third-party callback main.zig matches its reviewed golden (assembler#501)" {
        // First main.zig GOLDEN (deliberate: this third-party callback cell has no
        // enum baseline to byte-anchor against, so a reviewed golden is the gate).
        // Regenerate with `zig build` + capture on an intentional change.
        generate.main_template.loop_style_override = .callback;
        defer generate.main_template.loop_style_override = null;
        generate.main_template.lifecycle_override = h.acme_callback_lifecycle_decl;
        defer generate.main_template.lifecycle_override = null;

        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .platform = .desktop,
            .backend_package = h.acme_callback_fixture_package,
            .ecs = .mock,
        }, h.acme_callback_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        const golden = @embedFile("goldens/acme_callback_main.zig");
        try std.testing.expectEqualStrings(golden, main_zig);
    }

    test "a v2 callback entry WITHOUT a lifecycle declaration is STILL rejected (assembler#501)" {
        // Negative B: relaxing the gate must NOT drop the fail-fast for an
        // UNDECLARED callback external. `loop_style_override = .callback` forces
        // `use_callback_lifecycle`, the backend is external + non-enum-tag-backed,
        // and `lifecycle_override` stays null (no `.lifecycle` in the manifest) —
        // so the reworded `error.ExternalCallbackBackendUnsupported` must fire.
        generate.main_template.loop_style_override = .callback;
        defer generate.main_template.loop_style_override = null;
        // lifecycle_override deliberately left at its null default.

        try std.testing.expectError(error.ExternalCallbackBackendUnsupported, generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .platform = .desktop,
            .backend_package = .{ .name = "undeclaredcb", .repo = "local:../ucb" },
            .ecs = .mock,
        }, h.acme_callback_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions));
    }

    test "raylib desktop (external-by-default) STILL emits the PBO preview readback (#386 flip regression)" {
        // Post-#386 flip `.backend = .raylib` resolves to labelle-raylib, so
        // `cfg.isExternal()` is now true even for the DEFAULT raylib. The render
        // gate must key off the RESOLVED backend NAME ("raylib"), not
        // `!isExternal()` — otherwise the `{{preview_setup}}`/`{{preview_readback}}`
        // holes (labelle-raylib's desktop template still carries them) fill EMPTY
        // and the editor preview connects but publishes no frames.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .platform = .desktop,
            .ecs = .mock,
        }, h.raylib_desktop_preview_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // PBO readback setup (attach) + per-frame readback + the publish bridge
        // must all be present — the async-readback path that publishes frames.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.preview_pbo.attach(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.preview_pbo.frame();") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_preview_pbo_publish_bridge") != null);
    }

    test "a non-raylib external backend does NOT get raylib's PBO readback (#409 intent preserved)" {
        // The gate must still EXCLUDE other/third-party external backends: their
        // window module has no `preview_pbo`, so emitting raylib's readback would
        // fail to compile. A backend whose resolved NAME is not "raylib" (here the
        // `nullfixture` package, `cfg.backend` at its `.raylib` enum default) keeps
        // the empty-readback path — same as null/sdl/bgfx/wgpu.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .platform = .desktop,
            .backend_package = .{ .name = "nullfixture", .repo = "local:../nf" },
            .ecs = .mock,
        }, h.raylib_desktop_preview_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.preview_pbo.attach(") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.preview_pbo.frame();") == null);
    }

    test "raylib + sokol unchanged — null doesn't leak into other backends" {
        // Regression-lock: the headless main pattern must NOT appear in
        // raylib's or sokol's generated output, and each backend's
        // existing rendering wiring stays intact.
        const raylib_main = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(raylib_main);

        // Frame-counter loop is null-only; raylib uses shouldQuit.
        try std.testing.expect(std.mem.indexOf(u8, raylib_main, "while (frame < max_frames)") == null);
        try std.testing.expect(std.mem.indexOf(u8, raylib_main, "shouldQuit") != null);
        // Rendering path intact.
        try std.testing.expect(std.mem.indexOf(u8, raylib_main, "g.render()") != null);

        const sokol_main = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, sokol_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(sokol_main);

        // Sokol uses callback exports, not a frame counter.
        try std.testing.expect(std.mem.indexOf(u8, sokol_main, "while (frame < max_frames)") == null);
        try std.testing.expect(std.mem.indexOf(u8, sokol_main, "export fn frame()") != null);
        try std.testing.expect(std.mem.indexOf(u8, sokol_main, "g.render()") != null);
    }
};

pub const PLUGIN_CONTROLLERS = struct {
    const plugins_two = &[_]generate.PluginDep{
        .{ .name = "pathfinder", .repo = "github.com/labelle-toolkit/labelle-pathfinding", .version = "0.1.0" },
        .{ .name = "fsm", .repo = "github.com/labelle-toolkit/labelle-fsm", .version = "0.1.0" },
    };

    test "plugins present emits PluginControllers scaffold with @hasDecl discovery" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = plugins_two,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Scaffold struct is emitted
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const PluginControllers = struct") != null);

        // Both plugin imports end up in the _plugin_mods tuple
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"pathfinder\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"fsm\")") != null);

        // Discovery is `@hasDecl`-guarded (plugins without Controller are skipped)
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "if (@hasDecl(mod, \"Controller\"))") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "if (@hasDecl(C, \"setup\"))") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "if (@hasDecl(C, \"deinit\"))") != null);

        // setup is `!void` (controllers can fail), deinit is `void` (must not)
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub fn setup(game: anytype) !void") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub fn deinit(game: anytype) void") != null);
    }

    test "plugins present wires controllers into setup_code (loop backend)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = plugins_two,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "try PluginControllers.setup(&g);") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "defer PluginControllers.deinit(&g);") != null);
    }

    test "plugins present wires PluginSystems.renderMeshes into the render sequence (gfx#290)" {
        // engine#660 added `SystemRegistry.renderMeshes(game)` — the render-phase
        // sibling of `drawGui`. The generated render loop must fire it after
        // `g.render()` so a plugin's `renderMeshes` system actually runs. Unlike
        // `drawGui` it is NOT nested in the imgui `guiBegin`/`guiEnd` pass and is
        // independent of `hasGui()` — this project has no GUI, yet the call is
        // still emitted (Spine world meshes must render without imgui).
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = plugins_two,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        const rm_idx = std.mem.indexOf(u8, main_zig, "PluginSystems.renderMeshes(&g);") orelse return error.NotFound;
        const render_idx = std.mem.indexOf(u8, main_zig, "g.render()") orelse return error.NotFound;
        // Fires in the render phase, after the scene render flushes sprites.
        try std.testing.expect(render_idx < rm_idx);
    }

    test "plugins present wires controllers into init/cleanup (sokol callback backend)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = plugins_two,
        }, sokol_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Callback backends can't `try` in `void` init, so setup uses `catch @panic`.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "PluginControllers.setup(&g) catch") != null);
        // Cleanup emits the deinit call directly (no defer scope across callbacks).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "PluginControllers.deinit(&g);") != null);
    }

    test "no plugins omits all controller scaffolding (backward-compat)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{},
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "PluginControllers") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "PluginSystems") == null);
    }

    test "plugin-shipped scripts: AllScripts imports from .plugin_<name>/ subtree" {
        // The assembler copies plugin scripts into
        // `<target>/scripts/.plugin_<name>/…` so `@import("scripts/<rel>")`
        // works. Sanity-check: given a script entry with plugin_name set and
        // a `rel_path = ".plugin_pathfinder/01_advance.zig"`, the generator
        // emits an import that references the plugin subtree and gives it a
        // legal Zig identifier (the leading `.` must be rewritten).
        const plugin_script_entry: generate.script_scanner.ScriptScanner.ScriptEntry = .{
            .name = "advance",
            .filename = "01_advance.zig",
            .states = &.{},
            .sort_order = 1,
            .subdir = null,
            .rel_path = ".plugin_pathfinder/01_advance.zig",
            .plugin_name = "pathfinder",
            .plugin_index = 1,
        };
        const entries: []const generate.script_scanner.ScriptScanner.ScriptEntry = &.{plugin_script_entry};

        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = plugins_two,
        }, raylib_lifecycle, entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Plugin script lives under `<target>/scripts/.plugin_pathfinder/…`
        // on disk, and the generated code must reference it by that path.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"scripts/.plugin_pathfinder/01_advance.zig\")") != null);

        // The Zig identifier used for the const decl escapes the leading
        // `.` (`_d_`), every literal `_` (`_u_`) and the `/` (`_s_`) via the
        // injective pathToIdent (issue #172) so the generated source compiles.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_d_plugin_u_pathfinder_s_01_u_advance") != null);
    }

    test "plugin block preserves .plugins declaration order in _plugin_mods tuple" {
        // Declaration order in `project.labelle` drives both the gate for
        // controller setup/deinit AND (later, step 3) the plugin-script block
        // order. This test pins the first invariant so a refactor can't silently
        // swap plugins around.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = plugins_two,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        const pathfinder_idx = std.mem.indexOf(u8, main_zig, "@import(\"pathfinder\")") orelse return error.NotFound;
        const fsm_idx = std.mem.indexOf(u8, main_zig, "@import(\"fsm\")") orelse return error.NotFound;
        // pathfinder is declared first in `plugins_two`, so it must appear
        // first in _plugin_mods too. (Both plugins appear twice — once in
        // PluginSystems, once in PluginControllers — but relative order is
        // the same, so comparing the first occurrences is unambiguous.)
        try std.testing.expect(pathfinder_idx < fsm_idx);
    }
};

pub const SOKOL = struct {
    test "sets renderer screen height" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .height = 600,
            .backend = .sokol,
            .ecs = .mock,
        }, sokol_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "setScreenHeight") != null);
    }

    test "generates callback-style main" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, sokol_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "export fn init() callconv(.c)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "export fn frame() callconv(.c)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "export fn cleanup() callconv(.c)") != null);
    }

    test "uses module-level runner var" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, sokol_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var runner: Runner = undefined;") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "runner = Runner.init(") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "runner.deinit()") != null);
    }

    test "initial_prefab overrides default jsonc_scene_names[0]" {
        const jsonc_scenes = &[_][]const u8{ "intro", "main_menu", "gameplay" };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .initial_prefab = "main_menu",
        }, sokol_lifecycle, empty_entries, empty_names, jsonc_scenes, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.setScene(\"main_menu\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.setScene(\"intro\")") == null);
    }

    test "initial_scene legacy alias still overrides default jsonc_scene_names[0]" {
        const jsonc_scenes = &[_][]const u8{ "intro", "main_menu", "gameplay" };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .initial_scene = "main_menu",
        }, sokol_lifecycle, empty_entries, empty_names, jsonc_scenes, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.setScene(\"main_menu\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.setScene(\"intro\")") == null);
    }

    test "initial_prefab wins over deprecated initial_scene when both set" {
        var cfg = generate.ProjectConfig{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .initial_prefab = "main_menu",
            .initial_scene = "intro",
        };
        cfg.normalizeInitialPrefab();
        try std.testing.expectEqualStrings("main_menu", cfg.resolvedInitialPrefab().?);
        try std.testing.expect(cfg.initial_scene == null);
    }

    test "normalizeInitialPrefab migrates legacy initial_scene" {
        var cfg = generate.ProjectConfig{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .initial_scene = "intro",
        };
        cfg.normalizeInitialPrefab();
        try std.testing.expectEqualStrings("intro", cfg.initial_prefab.?);
        try std.testing.expect(cfg.initial_scene == null);
    }

    test "resolved_gui with lifecycle generates init in callback and shutdown in cleanup" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .resolved_gui = testGuiRawBackend("imgui"),
        }, sokol_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "GuiBackend.init()") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "GuiBackend.shutdown()") != null);
    }

    // Regression: labelle-cli#198. The generator used to emit
    // `const allocator = std.heap.c_allocator;` at module scope AND
    // `const allocator = std.heap.c_allocator;` inside `initInner`, so
    // Zig rejected the sokol+wasm build with a "local constant shadows
    // declaration" error before any of the game code could compile.
    // For wasm, the inner declaration must be omitted (allocator is
    // already in scope from the module-level `{{allocator_decl}}`).
    test "wasm: no duplicate const allocator declaration in main.zig" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .platform = .wasm,
            .ecs = .mock,
        }, sokol_alloc_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // The module-scope decl must still be emitted — that's where
        // `allocator` lives for the whole generated file on wasm.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const allocator = std.heap.c_allocator;") != null);

        // But there must be only one such declaration anywhere in the
        // file — the inner one inside `initInner` would shadow it.
        const needle = "const allocator = std.heap.c_allocator;";
        const first = std.mem.indexOf(u8, main_zig, needle) orelse return error.NotFound;
        const after = main_zig[first + needle.len ..];
        try std.testing.expect(std.mem.indexOf(u8, after, needle) == null);
    }

    // Counter-test: desktop sokol must still emit the inner alias so
    // `initInner` can refer to `allocator` (the module scope only has
    // `var gpa = ...`, not `const allocator = ...`).
    test "desktop: initInner declares allocator from gpa" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .platform = .desktop,
            .ecs = .mock,
        }, sokol_alloc_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "var gpa = std.heap.DebugAllocator") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const allocator = gpa.allocator();") != null);
    }
};

pub const EMBED_SCENES = struct {
    test "scenes are always embedded via @embedFile" {
        const jsonc_scenes = &[_][]const u8{ "intro", "gameplay" };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, jsonc_scenes, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"scenes/intro.jsonc\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"scenes/gameplay.jsonc\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadSceneFromSource") != null);
        // No file-based loadScene
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadScene(game") == null);
    }
};

pub const GAME_EVENT_VARIANT_NAMES = struct {
    // Regression for the `_u_` underscore-escape leak: `pathToIdent` was
    // applied to event-file basenames when building the `GameEvents`
    // union, so a file `events/anim_transition.zig` produced a variant
    // named `anim_u_transition` — which cannot match a user handler
    // named `pub fn anim_transition(...)` under engine 1.44.0's
    // stricter handler check (labelle-engine#16). The basename must
    // pass through verbatim because the user writes the handler name
    // by hand and expects it to match.
    //
    // The stock `engine_template` doesn't reference the
    // `event_imports_block` / `game_events_block` slots (it's a
    // backend-wiring smoke fixture), so each test wires up a minimal
    // template that lays bare exactly those slots — enough to assert
    // on the variant + import emissions without dragging in the rest
    // of the orchestrator output.
    const events_test_template =
        \\{{event_imports_block}}
        \\{{game_events_block}}
        \\{{lifecycle}}
    ;

    test "preserves underscores in event-file basename as variant name" {
        const event_names = &[_][]const u8{"anim_transition"};
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, events_test_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, event_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Import alias uses the basename verbatim — `anim_transition`,
        // NOT `anim_u_transition`.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const anim_transition = @import(\"events/anim_transition.zig\")") != null);
        // The union variant name matches what the user's handler
        // function is named.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "anim_transition: anim_transition.AnimTransition") != null);
        // No `_u_` escape leaks through.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "anim_u_transition") == null);
    }

    test "multi-underscore basenames pass through verbatim" {
        const event_names = &[_][]const u8{ "worker_eat_start", "fight_started" };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, events_test_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, event_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "worker_eat_start: worker_eat_start.WorkerEatStart") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "fight_started: fight_started.FightStarted") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "worker_u_eat_u_start") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "fight_u_started") == null);
    }
};

// ── Editor-preview wasm splice (labelle-studio Play mode, Phase 3) ──────────
// The assembler side of the studio's Play mode: an editor-preview generation
// (`cfg.editor_preview`, activated by LABELLE_EDITOR_PREVIEW=1 /
// --editor-preview, wasm-only) fills the `{{editor_bind}}` /
// `{{editor_sim_open}}` / `{{editor_sim_close}}` holes a backend's wasm
// template declares (labelle-bgfx ≥ 0.6.1 first) so the generated main binds
// `engine.editor_api` and gates the sim; a non-preview generation fills them
// EMPTY and must reproduce the pre-preview bytes exactly.
pub const EDITOR_PREVIEW = struct {
    fn genBgfxWasm(editor_preview: bool) ![]const u8 {
        return generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .bgfx,
            .platform = .wasm,
            .editor_preview = editor_preview,
            .ecs = .mock,
        }, h.bgfx_wasm_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
    }

    test "editor-preview bgfx-wasm main.zig matches its reviewed golden" {
        // Golden for the three splice points (same discipline as
        // `acme_callback_main.zig`, #501): bind / sim gate / frame sync in
        // the bgfx wasm callback shape. Regenerate + re-review on an
        // intentional change.
        const main_zig = try genBgfxWasm(true);
        defer std.testing.allocator.free(main_zig);

        const golden = @embedFile("goldens/bgfx_wasm_editor_preview_main.zig");
        try std.testing.expectEqualStrings(golden, main_zig);
    }

    test "editor-preview splice: bind before the main loop, sim gated, frame after sim" {
        const main_zig = try genBgfxWasm(true);
        defer std.testing.allocator.free(main_zig);

        // (1) bind — once at startup, after setup (runner.setup is the tail
        // of {{setup_code}}), BEFORE emscripten_set_main_loop.
        const bind_at = std.mem.indexOf(u8, main_zig, "engine.editor_api.bind(&g, &runner);").?;
        const setup_at = std.mem.indexOf(u8, main_zig, "runner.setup(&g);").?;
        const loop_at = std.mem.indexOf(u8, main_zig, "emscripten_set_main_loop(&gameFrame").?;
        try std.testing.expect(setup_at < bind_at);
        try std.testing.expect(bind_at < loop_at);

        // (2) sim gate — shouldTick opens BEFORE the tick block; the close
        // brace + frame(&g) land AFTER g.tick(dt) and BEFORE the render half.
        const gate_at = std.mem.indexOf(u8, main_zig, "if (engine.editor_api.shouldTick()) {").?;
        const tick_at = std.mem.indexOf(u8, main_zig, "runner.tick(&g, scaled_dt);").?;
        const gtick_at = std.mem.indexOf(u8, main_zig, "g.tick(dt);").?;
        const frame_at = std.mem.indexOf(u8, main_zig, "engine.editor_api.frame(&g);").?;
        const render_at = std.mem.indexOf(u8, main_zig, "window.beginFrame();").?;
        try std.testing.expect(gate_at < tick_at);
        try std.testing.expect(tick_at < gtick_at);
        try std.testing.expect(gtick_at < frame_at);
        try std.testing.expect(frame_at < render_at);

        // (3) stale-engine guard — a pin without editor_api fails with the
        // actionable @compileError, not a bare missing-member error.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@hasDecl(engine, \"editor_api\")") != null);

        // No template hole leaked through unfilled.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "{{editor_") == null);
    }

    test "NON-preview generation against the hole-bearing template emits NO editor code" {
        // The byte-identity property: the SAME (hole-bearing) wasm template,
        // preview off → no editor_api anywhere, no leaked `{{editor_*}}`
        // placeholder, and the splice lines collapse to the pre-preview
        // shape (`g.tick(dt);` followed by a blank line, `{{setup_code}}`
        // directly followed by the emscripten_set_main_loop call).
        const main_zig = try genBgfxWasm(false);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "editor_api") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "{{editor_") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "    g.tick(dt);\n\n    window.beginFrame();") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "    emscripten_set_main_loop(&gameFrame, 0, 1);") != null);
    }

    test "editor_preview is inert off wasm (the wasm-only rule at the codegen layer)" {
        // `generate` normalizes the flag off for non-wasm platforms, but the
        // codegen layer must ALSO ignore a stray flag: a desktop generation
        // with editor_preview set emits no editor code (its template has no
        // holes and the splice is wasm-gated).
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .platform = .desktop,
            .editor_preview = true,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "editor_api") == null);
    }

    test "editor preview against a wasm template WITHOUT the holes is a hard error" {
        // A backend whose wasm template predates the editor holes cannot
        // produce a drivable Play-mode build — silently emitting a non-editor
        // main would leave the studio connecting to a game it cannot drive.
        // The template below is the PRE-0.6.1 bgfx wasm shape (no holes).
        const holeless_wasm_lifecycle =
            \\{{module_vars}}var g: AssembledGame = undefined;
            \\{{hooks_init_block}}
            \\fn gameFrame() callconv(.c) void {
            \\    const dt: f32 = 0.016;
            \\{{preview_heartbeat}}{{tick_code}}    g.tick(dt);
            \\
            \\    window.beginFrame();
            \\    window.endFrame();
            \\}
            \\pub fn main() !void {
            \\    const allocator = std.heap.c_allocator;
            \\    g = AssembledGame.init(allocator);
            \\    g.setHooks(&hooks);
            \\{{preview_setup}}{{setup_code}}    emscripten_set_main_loop(&gameFrame, 0, 1);
            \\}
            \\
        ;
        try std.testing.expectError(error.EditorPreviewUnsupportedByBackend, generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .bgfx,
            .platform = .wasm,
            .editor_preview = true,
            .ecs = .mock,
        }, holeless_wasm_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions));
    }

    test "editor-preview main.zig is syntactically valid Zig" {
        const main_zig = try genBgfxWasm(true);
        defer std.testing.allocator.free(main_zig);
        const dup = try std.testing.allocator.dupeZ(u8, main_zig);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }
};
