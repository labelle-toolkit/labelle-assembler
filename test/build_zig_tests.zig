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

pub const BUILD_ZIG = struct {
    test "links raylib artifact" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkLibrary") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "raylib") != null);
    }

    test "links sokol_clib artifact" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkLibrary") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "sokol_clib") != null);
    }

    test "wires sdl backend modules" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sdl,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_sdl") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "backend_gfx") != null);
    }

    test "links bgfx and glfw artifacts" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .bgfx,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_bgfx") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "bgfx_artifact") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "glfw_artifact") != null);
    }

    test "links wgpu glfw artifact" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .wgpu,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_wgpu") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "glfw_artifact") != null);
    }

    test "null backend wires modules without artifact link" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .null,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // Module wiring still happens — the engine's import surface is the
        // same regardless of backend.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_null") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "backend_gfx") != null);

        // No native artifact to link — the null backend is pure Zig. The
        // raylib/sokol/sdl/bgfx/wgpu paths each emit a `linkLibrary(...)`
        // for their backend artifact; null must not.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "raylib_artifact") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "sokol_clib") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "bgfx_artifact") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "glfw_artifact") == null);
    }

    test "deduplicates labelle-core across gfx and engine" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // gfx and engine must use the project-level core, not their own resolved version
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(gfx_mod, \"labelle-core\", core_mod)") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(engine_mod, \"labelle-core\", core_mod)") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(engine_mod, \"labelle-gfx\", gfx_mod)") != null);
    }

    test "resolved_gui wires gui_backend" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resolved_gui = testGuiRenderInterface("clay"),
        }, .{});
        defer std.testing.allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "gui_mod") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_gui") != null);
    }

    test "resolved_gui raw_backend wires bridge artifact" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resolved_gui = testGuiRawBackend("imgui"),
        }, .{});
        defer std.testing.allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "gui_bridge") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "gui_bridge_artifact") != null);
    }

    test "no gui omits gui_mod" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "gui_mod") == null);
    }

    test "emits test step rooted at __tests_root.zig wrapper" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // The test step is the entry point users invoke via `zig build test`.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.step(\"test\"") != null);
        // Single addTest rooted at the assembler-generated wrapper. The
        // wrapper at the build root is what lets test files reach
        // `components/`, `scripts/`, etc. via relative `@import`.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "addTest") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "__tests_root.zig") != null);
    }

    test "test step reuses exe module imports" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .zig_ecs,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // The exe and the test step both bind `ecs_backend` from `ecs_mod`,
        // so each appears twice in the rendered build.zig — once in the
        // exe imports list and once in the per-test addTest module.
        const exe_count = std.mem.count(u8, build_zig, "ecs_backend");
        try std.testing.expect(exe_count >= 2);
    }

    test "is_tests_target trims exe assembly + run step (issue #83)" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .null,
            .ecs = .mock,
        }, .{ .is_tests_target = true });
        defer std.testing.allocator.free(build_zig);

        // Test step is the only entry point — keep it.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.step(\"test\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "addTest") != null);

        // No exe assembly: `addExecutable`, `installArtifact(exe)`, the
        // run step, or `b.addRunArtifact(exe)` would all reference an
        // undefined `exe` symbol since we never declared one.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "addExecutable") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "installArtifact(exe)") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.step(\"run\"") == null);

        // overrideImport helper still emitted — the plugin/gfx/engine
        // module-graph wiring above the test step calls it.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "fn overrideImport(") != null);
    }

    test "chains in-project @libs/ plugin test step into test step (issue #82)" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "pathfinder", .repo = "@libs/pathfinder" },
            },
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // Per-lib `zig build test` shelled out from the master test step.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "addSystemCommand(&.{ \"zig\", \"build\", \"test\" })") != null);
        // cwd points two levels up from the backend build dir into libs/.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.path(\"../../libs/pathfinder\")") != null);
        // The lib test is wired as a dependency of the `test` step.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "test_step.dependOn(&lib_test.step)") != null);
    }

    test "chains every @libs/ plugin into test step (issue #82)" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "pathfinder", .repo = "@libs/pathfinder" },
                .{ .name = "combat", .repo = "@libs/combat" },
            },
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.path(\"../../libs/pathfinder\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.path(\"../../libs/combat\")") != null);
        // One `addSystemCommand` per lib.
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, build_zig, "addSystemCommand(&.{ \"zig\", \"build\", \"test\" })"));
    }

    test "no @libs/ plugins emits no lib test chaining (issue #82)" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{},
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // No libs → no `zig build test` fan-out at all.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "\"zig\", \"build\", \"test\"") == null);
    }

    test "out-of-project local: plugins are not chained as libs (issue #82)" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                // local: paths can escape the project root — not part of
                // this project's test surface.
                .{ .name = "external", .repo = "local:../external" },
            },
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "\"zig\", \"build\", \"test\"") == null);
    }

    test "lib test chaining present in is_tests_target build (issue #82)" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .null,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "pathfinder", .repo = "@libs/pathfinder" },
            },
        }, .{ .is_tests_target = true });
        defer std.testing.allocator.free(build_zig);

        // The tests-only target is the canonical `zig build test` entry
        // point, so it must also fan out to in-project libs.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.path(\"../../libs/pathfinder\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "test_step.dependOn(&lib_test.step)") != null);
    }
};

pub const PLUGINS = struct {
    test "no plugins excludes pathfinding/physics from build.zig.zon" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{},
        }, null, null, null, .{});
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_pathfinding") == null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_physics") == null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_tasks") == null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_core") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_gfx") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "engine") != null);
    }

    test "no plugins excludes pathfinding/physics from build.zig" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{},
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_pathfinding") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_physics") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_tasks") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "pf_mod") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "physics_mod") == null);
    }

    test "plugins enabled includes pathfinding/physics in build.zig.zon" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "pathfinding", .repo = "github.com/labelle-toolkit/labelle-pathfinding", .version = "0.1.0" },
                .{ .name = "physics", .repo = "github.com/labelle-toolkit/labelle-physics", .version = "0.1.0" },
            },
        }, null, null, null, .{});
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_pathfinding") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_physics") != null);
    }

    test "plugins enabled includes pathfinding/physics in build.zig" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "pathfinding", .repo = "github.com/labelle-toolkit/labelle-pathfinding", .version = "0.1.0" },
                .{ .name = "physics", .repo = "github.com/labelle-toolkit/labelle-physics", .version = "0.1.0" },
            },
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_pathfinding") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_physics") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "plugin_pathfinding_mod") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "plugin_physics_mod") != null);
    }

    test "plugins receive all engine subsystem imports" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .zig_ecs,
            .plugins = &.{
                .{ .name = "physics", .repo = "github.com/labelle-toolkit/labelle-physics", .version = "0.1.0" },
            },
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // Core + gfx + engine (always injected)
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"labelle-core\", core_mod)") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"labelle-gfx\", gfx_mod)") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"labelle-engine\", engine_mod)") != null);

        // ECS backend (injected when ecs != mock)
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"ecs_backend\", ecs_mod)") != null);

        // Backend modules (always injected)
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"backend_gfx\", backend_gfx)") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"backend_input\", backend_input)") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"backend_audio\", backend_audio)") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"backend_window\", backend_window)") != null);
    }

    test "plugins with mock ecs omit ecs_backend import" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "physics", .repo = "github.com/labelle-toolkit/labelle-physics", .version = "0.1.0" },
            },
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // Should NOT have ecs_backend when using mock
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(\"ecs_backend\"") == null);
        // But should still have core, gfx, engine
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"labelle-core\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"labelle-engine\"") != null);
    }

    test "plugins receive gui_backend when gui is active" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resolved_gui = testGuiRenderInterface("clay"),
            .plugins = &.{
                .{ .name = "physics", .repo = "github.com/labelle-toolkit/labelle-physics", .version = "0.1.0" },
            },
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"gui_backend\", gui_mod)") != null);
    }

    test "plugins omit gui_backend when no gui" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "physics", .repo = "github.com/labelle-toolkit/labelle-physics", .version = "0.1.0" },
            },
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(\"gui_backend\"") == null);
    }

    test "single plugin only includes that plugin" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "pathfinding", .repo = "github.com/labelle-toolkit/labelle-pathfinding", .version = "0.1.0" },
            },
        }, null, null, null, .{});
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_pathfinding") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_physics") == null);
    }
};
