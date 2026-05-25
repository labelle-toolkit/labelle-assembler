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

pub const SCENE_ASSET_MANIFESTS = struct {
    test "emits SceneAssetManifests struct with per-scene decls" {
        const jsonc_scenes = &[_][]const u8{ "menu", "gameplay" };
        const manifests = [_]SceneManifest{
            .{ .name = "menu", .assets = &[_][]const u8{"background"} },
            .{ .name = "gameplay", .assets = &[_][]const u8{ "ship", "rooms" } },
        };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, jsonc_scenes, &manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Comptime struct + per-scene named decls.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const SceneAssetManifests = struct {") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const menu: []const []const u8 = &.{ \"background\" };") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const gameplay: []const []const u8 = &.{ \"ship\", \"rooms\" };") != null);

        // Stable iteration entries — engine consumer (#445) reads this.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const Entry = struct { name: []const u8, assets: []const []const u8 };") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".{ .name = \"menu\", .assets = @This().menu }") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".{ .name = \"gameplay\", .assets = @This().gameplay }") != null);
    }

    test "scenes without assets get explicit empty slice decls" {
        const jsonc_scenes = &[_][]const u8{"menu"};
        const manifests = [_]SceneManifest{
            .{ .name = "menu", .assets = &[_][]const u8{} },
        };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, jsonc_scenes, &manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const menu: []const []const u8 = &.{};") != null);
    }

    test "scene names with slashes flatten to underscore decls" {
        const jsonc_scenes = &[_][]const u8{"world/intro"};
        const manifests = [_]SceneManifest{
            .{ .name = "world/intro", .assets = &[_][]const u8{"background"} },
        };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, jsonc_scenes, &manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Decl uses the injective `_s_`-escaped ident (issue #172)...
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "pub const world_s_intro: []const []const u8 = &.{ \"background\" };") != null);
        // ...but the entries[] preserves the original slash-style name.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".{ .name = \"world/intro\", .assets = @This().world_s_intro }") != null);
    }

    test "no scenes emits no SceneAssetManifests struct" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "SceneAssetManifests") == null);
    }

    test "asset names with backslash or quote are escaped in generated source" {
        const jsonc_scenes = &[_][]const u8{"menu"};
        const manifests = [_]SceneManifest{
            .{ .name = "menu", .assets = &[_][]const u8{ "path\\asset", "say\"hi" } },
        };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, jsonc_scenes, &manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "\"path\\\\asset\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "\"say\\\"hi\"") != null);
    }

    test "setup emits setSceneAssets loop driven by SceneAssetManifests.entries (raylib)" {
        const jsonc_scenes = &[_][]const u8{ "menu", "gameplay" };
        const manifests = [_]SceneManifest{
            .{ .name = "menu", .assets = &[_][]const u8{"background"} },
            .{ .name = "gameplay", .assets = &[_][]const u8{ "ship", "rooms" } },
        };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, jsonc_scenes, &manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // The setup block should thread SceneAssetManifests.entries into
        // SceneEntry.assets via the engine's setSceneAssets helper. See
        // labelle-engine#445 for the consumer.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "inline for (SceneAssetManifests.entries) |scene_asset_entry|") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.setSceneAssets(scene_asset_entry.name, scene_asset_entry.assets)") != null);
    }

    test "callback-init path also emits setSceneAssets loop (sokol)" {
        const jsonc_scenes = &[_][]const u8{"menu"};
        const manifests = [_]SceneManifest{
            .{ .name = "menu", .assets = &[_][]const u8{"background"} },
        };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, sokol_lifecycle, empty_entries, empty_names, jsonc_scenes, &manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "inline for (SceneAssetManifests.entries) |scene_asset_entry|") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.setSceneAssets(scene_asset_entry.name, scene_asset_entry.assets)") != null);
    }
};
