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

pub const MAIN_ZIG = struct {
    test "uses MockEcsBackend for mock ecs" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "MockEcsBackend") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"ecs_backend\")") == null);
    }

    test "uses EcsAdapter for real ecs" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .zflecs,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "EcsAdapter") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "ecs_backend") != null);
    }

    test "contains window dimensions" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "StubGui") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "gui_backend") == null);
    }

    test "resolved_gui wires gui_backend in main.zig" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .backend = .sdl,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub fn main()") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "MockEcsBackend") != null);
    }
};

pub const NULL_BACKEND = struct {
    test "null backend generates headless main with no sokol_app.run" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        // Frame-counter loop, not a windowShouldClose loop.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "while (frame < max_frames)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "windowShouldClose") == null);
    }

    test "null backend wires LABELLE_PREVIEW env-var (control plane works)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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

    test "raylib + sokol unchanged — null doesn't leak into other backends" {
        // Regression-lock: the headless main pattern must NOT appear in
        // raylib's or sokol's generated output, and each backend's
        // existing rendering wiring stays intact.
        const raylib_main = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(raylib_main);

        // Frame-counter loop is null-only; raylib uses windowShouldClose.
        try std.testing.expect(std.mem.indexOf(u8, raylib_main, "while (frame < max_frames)") == null);
        try std.testing.expect(std.mem.indexOf(u8, raylib_main, "windowShouldClose") != null);
        // Rendering path intact.
        try std.testing.expect(std.mem.indexOf(u8, raylib_main, "g.render()") != null);

        const sokol_main = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = plugins_two,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "try PluginControllers.setup(&g);") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "defer PluginControllers.deinit(&g);") != null);
    }

    test "plugins present wires controllers into init/cleanup (sokol callback backend)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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

        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .height = 600,
            .backend = .sokol,
            .ecs = .mock,
        }, sokol_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "setScreenHeight") != null);
    }

    test "generates callback-style main" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
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
