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

pub const SCRIPTS = struct {
    test "generates AllScripts struct for global scripts" {
        const entries = globalEntries(&.{ "movement", "spawn", "gui" });
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const AllScripts = struct {") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const movement = @import(\"scripts/movement.zig\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const spawn = @import(\"scripts/spawn.zig\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const gui = @import(\"scripts/gui.zig\")") != null);
    }

    test "generates state-scoped wrapper for state-bound scripts" {
        const playing_states: []const []const u8 = &.{"playing"};
        const entries: []const ScriptEntry = &.{
            .{ .name = "movement", .filename = "movement.zig", .states = &.{}, .sort_order = null, .subdir = null, .rel_path = "movement.zig" },
            .{ .name = "pathfinder", .filename = "01_pathfinder.zig", .states = playing_states, .sort_order = 1, .subdir = "playing", .rel_path = "playing/01_pathfinder.zig" },
        };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Global script: direct import, no wrapper
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const movement = @import(\"scripts/movement.zig\")") != null);
        // State-scoped script: wrapper with game_states (identifier derived from rel_path;
        // injective pathToIdent escapes `/` to `_s_` and literal `_` to `_u_` — issue #172)
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const playing_s_01_u_pathfinder = struct {") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_inner = @import(\"scripts/playing/01_pathfinder.zig\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const game_states = .{") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "\"playing\",") != null);
    }

    test "generates multi-state wrapper for playing+paused scripts" {
        const both_states: []const []const u8 = &.{ "playing", "paused" };
        const entries: []const ScriptEntry = &.{
            .{ .name = "camera", .filename = "camera.zig", .states = both_states, .sort_order = null, .subdir = "playing+paused", .rel_path = "playing+paused/camera.zig" },
        };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // `playing+paused/camera.zig`: `+` -> `_p_`, `/` -> `_s_` (injective — issue #172).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const playing_p_paused_s_camera = struct {") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "\"playing\",") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "\"paused\",") != null);
    }

    test "uses ScriptRunner for dispatch" {
        const entries = globalEntries(&.{ "movement", "spawn" });
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const Runner = engine.ScriptRunner(AllScripts, GameContext, EcsBackend)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "Runner.init(allocator, &g.active_world.ecs_backend)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "runner.setup(&g)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "runner.tick(&g, scaled_dt)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "runner.deinit()") != null);
    }

    test "detects context.zig for GameContext" {
        const entries = globalEntries(&.{ "context", "movement" });
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const GameContext = @import(\"scripts/context.zig\").GameContext(EcsBackend)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const context =") == null);
    }

    test "uses empty struct when no context.zig" {
        const entries = globalEntries(&.{"movement"});
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const GameContext = struct {}") != null);
    }
};

pub const PREFABS_AND_SCENES = struct {
    test "embeds prefabs via addEmbeddedPrefab" {
        const prefabs = &[_][]const u8{ "enemy", "player" };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, prefabs, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Prefabs are embedded at runtime, not compiled via PrefabRegistry
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "addEmbeddedPrefab") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"prefabs/player.jsonc\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"prefabs/enemy.jsonc\")") != null);
        // Empty comptime PrefabRegistry
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "PrefabRegistry(.{})") != null);
    }

};

pub const VIEWS = struct {
    test "generates ViewRegistry from scanned views" {
        const views = &[_][]const u8{ "hud", "inventory" };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, views, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const Views = engine.ViewRegistry(.{") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".hud = @import(\"views/hud.zon\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".inventory = @import(\"views/inventory.zon\")") != null);
    }

    test "auto-renders views in GUI section" {
        const views = &[_][]const u8{"hud"};
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resolved_gui = testGuiRenderInterface("clay"),
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, views, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.guiBegin()") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.renderAllViews(Views)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.guiEnd()") != null);
    }

    test "uses EmptyViewRegistry when no views" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const Views = engine.EmptyViewRegistry") != null);
    }
};

pub const LAYERS = struct {
    test "generates GameLayers from project config" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .layers = &.{
                .{ .name = "bg", .order = 0, .space = .screen },
                .{ .name = "world", .order = 1, .space = .world },
                .{ .name = "hud", .order = 2, .space = .screen },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const GameLayers = enum(u8)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "bg,") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "world,") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "hud,") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".bg => .{ .order = 0, .space = .screen }") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".world => .{ .order = 1, .space = .world }") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "GfxRendererWith(BackendGfx, GameLayers,") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "config.GameLayers") == null);
    }
};
