const std = @import("std");
const zspec = @import("zspec");
const generate = @import("generator");
const h = @import("helpers.zig");

const engine_template = h.engine_template;
const raylib_lifecycle = h.raylib_lifecycle;
const sokol_lifecycle = h.sokol_lifecycle;
const empty_names = h.empty_names;
const empty_entries = h.empty_entries;
const SceneManifest = h.SceneManifest;
const empty_scene_manifests = h.empty_scene_manifests;
const empty_plugin_events = h.empty_plugin_events;
const empty_plugin_flow_nodes = h.empty_plugin_flow_nodes;
const empty_plugin_pin_styles = h.empty_plugin_pin_styles;
const empty_plugin_coercions = h.empty_plugin_coercions;

test {
    zspec.runAll(@This());
}

pub const POST_FX_SETUP = struct {
    test "loop path emits gated setPostFx with the mapped bloom literal (raylib)" {
        const jsonc_scenes = &[_][]const u8{"menu"};
        const manifests = [_]SceneManifest{
            .{ .name = "menu", .assets = &[_][]const u8{} },
        };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .post_fx = &.{
                .{ .bloom = .{ .threshold = 0.8, .intensity = 1.0, .radius = 1.0 } },
            },
        }, raylib_lifecycle, empty_entries, empty_names, jsonc_scenes, &manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "if (@hasDecl(AssembledGame, \"setPostFx\")) g.setPostFx(&.{") != null);
        // RFC §2.2: threshold→scalar0, intensity→scalar1, radius→scalar2.
        // `{d}`: 0.8 → "0.8", 1.0 → "1".
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.PostPass{ .kind = .bloom, .uniforms = .{ .scalar0 = 0.8, .scalar1 = 1, .scalar2 = 1 } },") != null);
    }

    test "callback path emits the SAME gated setPostFx statement (sokol)" {
        h.setSokolLifecycle();
        defer h.clearLifecycleOverrides();
        const jsonc_scenes = &[_][]const u8{"menu"};
        const manifests = [_]SceneManifest{
            .{ .name = "menu", .assets = &[_][]const u8{} },
        };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .post_fx = &.{
                .{ .bloom = .{ .threshold = 0.8, .intensity = 1.0, .radius = 1.0 } },
            },
        }, sokol_lifecycle, empty_entries, empty_names, jsonc_scenes, &manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // setPostFx is void, so the callback path emits the IDENTICAL statement
        // as the loop path — no `catch @panic` split.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "if (@hasDecl(AssembledGame, \"setPostFx\")) g.setPostFx(&.{") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.PostPass{ .kind = .bloom, .uniforms = .{ .scalar0 = 0.8, .scalar1 = 1, .scalar2 = 1 } },") != null);
    }

    test "multi-pass stack emits each kind's mapped slots incl. crt aberration→scalar3" {
        const jsonc_scenes = &[_][]const u8{"menu"};
        const manifests = [_]SceneManifest{
            .{ .name = "menu", .assets = &[_][]const u8{} },
        };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .post_fx = &.{
                .{ .bloom = .{ .threshold = 0.5, .intensity = 2.0, .radius = 1.0 } },
                .{ .crt = .{ .curvature = 0.2, .scanline = 0.5, .mask = 0.3, .aberration = 0.1 } },
            },
        }, raylib_lifecycle, empty_entries, empty_names, jsonc_scenes, &manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.PostPass{ .kind = .bloom, .uniforms = .{ .scalar0 = 0.5, .scalar1 = 2, .scalar2 = 1 } },") != null);
        // RFC §2.2 crt: curvature→scalar0, scanline→scalar1, mask→scalar2, aberration→scalar3.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.PostPass{ .kind = .crt, .uniforms = .{ .scalar0 = 0.2, .scalar1 = 0.5, .scalar2 = 0.3, .scalar3 = 0.1 } },") != null);
    }

    test "no .post_fx block emits no setPostFx (byte-compat)" {
        const jsonc_scenes = &[_][]const u8{"menu"};
        const manifests = [_]SceneManifest{
            .{ .name = "menu", .assets = &[_][]const u8{} },
        };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, jsonc_scenes, &manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "setPostFx") == null);
    }
};
