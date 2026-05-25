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

pub const BUILD_ZIG_ZON = struct {
    test "contains raylib dep for raylib backend" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, null, null, null, .{});
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_raylib") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_sokol") == null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_zig_ecs") == null);
    }

    test "contains zig_ecs dep when selected" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .zig_ecs,
        }, null, null, null, .{});
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_raylib") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_zig_ecs") != null);
    }

    test "contains sdl dep for sdl backend" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sdl,
            .ecs = .mock,
        }, null, null, null, .{});
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_sdl") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_raylib") == null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_sokol") == null);
    }

    test "contains bgfx dep for bgfx backend" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .bgfx,
            .ecs = .mock,
        }, null, null, null, .{});
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_bgfx") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_raylib") == null);
    }

    test "contains wgpu dep for wgpu backend" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .wgpu,
            .ecs = .mock,
        }, null, null, null, .{});
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_wgpu") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_raylib") == null);
    }

    test "uses config.version instead of hardcoded version" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .version = "1.2.3",
        }, null, null, null, .{});
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, ".version = \"1.2.3\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, ".version = \"0.1.0\"") == null);
    }

    test "defaults to version 0.1.0" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, null, null, null, .{});
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, ".version = \"0.1.0\"") != null);
    }

    test "uses path deps by default" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, null, null, null, .{});
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, ".path =") != null);
    }
};
