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

pub const HIDDEN_WINDOW = struct {
    test "hidden=true generates window hidden flag in raylib" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .hidden = true,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.setConfigFlags(.{ .window_hidden = true })") != null);
    }

    test "hidden=false does not generate window hidden flag" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .hidden = false,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window_hidden") == null);
    }

    test "hidden=true generates window hidden flag in sokol" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .hidden = true,
        }, sokol_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "window.setConfigFlags(.{ .window_hidden = true })") != null);
    }
};

pub const SUBFOLDERS = struct {
    test "subfolder prefabs register by basename + embedFile by full path" {
        const prefabs = &[_][]const u8{ "items/poop", "characters/worker", "player" };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, prefabs, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Registered name is the basename only — every `spawnPrefab`
        // / scene reference can use the flat name regardless of
        // where on disk the prefab lives.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "addEmbeddedPrefab(&g, \"poop\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "addEmbeddedPrefab(&g, \"worker\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "addEmbeddedPrefab(&g, \"player\"") != null);
        // The embedFile still uses the full path so the bytes resolve.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"prefabs/items/poop.jsonc\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"prefabs/characters/worker.jsonc\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"prefabs/player.jsonc\")") != null);
        // The path-qualified name is NOT used — old projects that
        // relied on `"items/poop"` as the registered name need to
        // update their `spawnPrefab` / scene references.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "addEmbeddedPrefab(&g, \"items/poop\"") == null);
    }

    test "duplicate basenames across subfolders error at generate time" {
        // Two prefabs with the same basename in different subfolders
        // would both try to register as `"goblin"`, silently
        // overwriting one with the other. The generator must surface
        // this at generate time so the developer renames before
        // shipping.
        const prefabs = &[_][]const u8{ "enemies/goblin", "allies/goblin" };
        const result = generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, prefabs, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        try std.testing.expectError(error.PrefabBasenameCollision, result);
    }

    test "scripts in organizational subdirs use path-based identifiers" {
        const playing_states: []const []const u8 = &.{"playing"};
        const entries: []const ScriptEntry = &.{
            .{ .name = "movement", .filename = "movement.zig", .states = playing_states, .sort_order = null, .subdir = "playing", .rel_path = "playing/systems/movement.zig" },
            .{ .name = "combat", .filename = "combat.zig", .states = playing_states, .sort_order = null, .subdir = "playing", .rel_path = "playing/systems/combat.zig" },
            .{ .name = "camera_control", .filename = "camera_control.zig", .states = &.{}, .sort_order = null, .subdir = null, .rel_path = "camera_control.zig" },
        };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // State-scoped scripts: identifier derived from rel_path (each `/`
        // escaped to `_s_` by the injective pathToIdent — issue #172),
        // import uses full path.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const playing_s_systems_s_movement = struct {") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"scripts/playing/systems/movement.zig\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const playing_s_systems_s_combat = struct {") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@import(\"scripts/playing/systems/combat.zig\")") != null);
        // Global script: direct import. The literal `_` in the basename is
        // escaped to `_u_` by the injective pathToIdent (issue #172).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const camera_u_control = @import(\"scripts/camera_control.zig\")") != null);
    }

    test "component names resolve to a natural PascalCase type name" {
        const components = &[_][]const u8{ "physics/rigid_body", "health" };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, components, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // The component type name is the natural PascalCase of the path
        // (`pathToPascal` — `/` and `_` are word boundaries), so
        // `physics/rigid_body` -> `PhysicsRigidBody`. It must NOT run
        // through `pathToIdent`'s injective `_`-escaping (issue #172):
        // that escaping is for generated *symbol* names, whereas this
        // name has to match the `pub const` declared in the user's
        // file (e.g. `components/jump_anim.zig` -> `JumpAnim`).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".PhysicsRigidBody = @import(\"components/physics/rigid_body.zig\").PhysicsRigidBody") != null);
        // Top-level component: `health` -> `Health`.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".Health = @import(\"components/health.zig\").Health") != null);
    }

    test "gizmo names with slashes use underscore identifiers" {
        const gizmos = &[_][]const u8{ "debug/collision", "editor/grid" };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, gizmos, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".debug_s_collision = @import(\"gizmos/debug/collision.zon\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".editor_s_grid = @import(\"gizmos/editor/grid.zon\")") != null);
    }

    test "view names with slashes use underscore identifiers" {
        const views = &[_][]const u8{ "panels/inventory", "hud" };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, views, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".panels_s_inventory = @import(\"views/panels/inventory.zon\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".hud = @import(\"views/hud.zon\")") != null);
    }
};

pub const SOKOL_PASS_ORDER = struct {
    fn readRepoFile(allocator: std.mem.Allocator, rel_path: []const u8) ![]const u8 {
        // Tests run with the package root (assembler repo root) as cwd,
        // per the repo's `zig build test` convention.
        return std.Io.Dir.cwd().readFileAlloc(std.testing.io, rel_path, allocator, .limited(1 * 1024 * 1024));
    }

    test "desktop template calls flushScene between renderGizmos and gui_draw_code" {
        const tmpl = try readRepoFile(std.testing.allocator, "backends/sokol/templates/desktop.txt");
        defer std.testing.allocator.free(tmpl);

        const flush_idx = std.mem.indexOf(u8, tmpl, "window.flushScene()") orelse {
            return error.MissingFlushScene;
        };
        const gizmos_idx = std.mem.indexOf(u8, tmpl, "g.renderGizmos()") orelse {
            return error.MissingRenderGizmos;
        };
        const gui_idx = std.mem.indexOf(u8, tmpl, "{{gui_draw_code}}") orelse {
            return error.MissingGuiDrawCode;
        };

        // Ordering: renderGizmos < flushScene < gui_draw_code.
        try std.testing.expect(gizmos_idx < flush_idx);
        try std.testing.expect(flush_idx < gui_idx);
    }

    test "endFrame in sokol window backend has no sgl.draw call" {
        // The defensive `sgl.draw` was removed because sokol-gl rewinds
        // its vertex / command buffers on `sg_commit` — not on
        // `sgl_draw` — so a second `sgl.draw` re-submits the same
        // vertex buffer and re-paints the sprites on top of the GUI.
        const window_zig = try readRepoFile(std.testing.allocator, "backends/sokol/src/window.zig");
        defer std.testing.allocator.free(window_zig);

        // Locate `pub fn endFrame` and the matching closing brace, then
        // assert the body has no actual `sgl.draw()` call. The doc
        // comment intentionally references the call name in prose, so
        // we walk the body line-by-line and skip `//`-prefixed lines.
        const end_frame_signature = "pub fn endFrame() void {";
        const start = std.mem.indexOf(u8, window_zig, end_frame_signature) orelse {
            return error.MissingEndFrame;
        };
        const body_start = start + end_frame_signature.len;
        const body_end_rel = std.mem.indexOfScalar(u8, window_zig[body_start..], '}') orelse {
            return error.UnterminatedEndFrame;
        };
        const body = window_zig[body_start .. body_start + body_end_rel];

        var saw_end_pass = false;
        var saw_commit = false;
        var iter = std.mem.splitScalar(u8, body, '\n');
        while (iter.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t");
            if (line.len == 0 or std.mem.startsWith(u8, line, "//")) continue;
            // Real code line — must not contain `sgl.draw`.
            try std.testing.expect(std.mem.indexOf(u8, line, "sgl.draw") == null);
            if (std.mem.indexOf(u8, line, "sg.endPass") != null) saw_end_pass = true;
            if (std.mem.indexOf(u8, line, "sg.commit") != null) saw_commit = true;
        }
        try std.testing.expect(saw_end_pass);
        try std.testing.expect(saw_commit);
    }

    test "mobile template calls flushScene before endFrame" {
        // Mobile has no GUI block today — but `endFrame` no longer
        // flushes sgl on its own (split out by the desktop fix), so
        // mobile must call `flushScene` itself or sprites never reach
        // the framebuffer (black-screen regression first hit on the
        // tablet during PR #80 testing).
        const tmpl = try readRepoFile(std.testing.allocator, "backends/sokol/templates/mobile.txt");
        defer std.testing.allocator.free(tmpl);

        const flush_idx = std.mem.indexOf(u8, tmpl, "window.flushScene()") orelse {
            return error.MissingFlushScene;
        };
        const end_idx = std.mem.indexOf(u8, tmpl, "window.endFrame()") orelse {
            return error.MissingEndFrame;
        };
        try std.testing.expect(flush_idx < end_idx);
    }

    test "flushScene exists and calls sgl.draw" {
        const window_zig = try readRepoFile(std.testing.allocator, "backends/sokol/src/window.zig");
        defer std.testing.allocator.free(window_zig);

        const flush_signature = "pub fn flushScene() void {";
        const start = std.mem.indexOf(u8, window_zig, flush_signature) orelse {
            return error.MissingFlushScene;
        };
        const body_start = start + flush_signature.len;
        const body_end_rel = std.mem.indexOfScalar(u8, window_zig[body_start..], '}') orelse {
            return error.UnterminatedFlushScene;
        };
        const body = window_zig[body_start .. body_start + body_end_rel];

        try std.testing.expect(std.mem.indexOf(u8, body, "sgl.draw") != null);
    }
};

pub const PLUGINS_IMGUI = struct {
    test "imgui plugin build.zig adds module as labelle_imgui" {
        const plugin_build = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "plugins/imgui/build.zig", std.testing.allocator, .limited(1 * 1024 * 1024));
        defer std.testing.allocator.free(plugin_build);
        try std.testing.expect(std.mem.indexOf(u8, plugin_build, "addModule(\"labelle_imgui\"") != null);
        // Old name guarded against — would silently break game builds.
        try std.testing.expect(std.mem.indexOf(u8, plugin_build, "addModule(\"gui\"") == null);
    }
};
