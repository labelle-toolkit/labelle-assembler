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

    test "sokol build does not link libudev — core dlopens it at runtime (#249)" {
        // labelle-core's Linux gamepad-detection source (gamepad_source/
        // linux.zig) loads libudev at RUNTIME via std.DynLib (dlopen of
        // `libudev.so.1`) as of labelle-core#20, degrading gracefully when
        // it is absent. So the generated sokol build must NOT emit a
        // build-time `linkSystemLibrary("udev", ...)` — doing so would
        // reintroduce a hard build/runtime dependency that defeats core's
        // graceful-degradation design. Runtime device-access setup lives in
        // docs/gamepad-linux.md.
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkSystemLibrary(\"udev\"") == null);
    }

    test "raylib build does not link libudev (#249)" {
        // No backend should emit a build-time libudev link — libudev is a
        // runtime dlopen dependency of labelle-core, never a link-time one.
        // raylib additionally supplies its own gamepad polling.
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkSystemLibrary(\"udev\"") == null);
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

    test "bgfx android builds a NativeActivity shared library, not a glfw exe" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .bgfx,
            .platform = .android,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // Android-targeted bgfx (#303): fetch the backend for the android
        // target, pull the NativeActivity-glue `android_app` module, and
        // build a dynamic library — NOT the desktop glfw executable.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_bgfx") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, ".target = android_target") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "backend_dep.module(\"android_app\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, ".name = \"backend_app\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, ".linkage = .dynamic") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkLibrary(bgfx_artifact)") != null);

        // NDK shell libs for the bgfx GLES renderer + NativeActivity glue.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkSystemLibrary(\"GLESv3\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkSystemLibrary(\"EGL\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkSystemLibrary(\"android\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkSystemLibrary(\"log\"") != null);

        // Desktop-only zglfw must NOT appear — it doesn't build for Android.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "glfw_artifact") == null);
        // And the APK packaging step is wired in.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "Package and sign Android APK") != null);
    }

    test "external backend matching its enum tag uses the enum path on non-desktop (#386)" {
        // bgfx extracted out-of-tree, selected via `.backend = .bgfx` while a
        // package resolves it (the post-flip shape). On ANDROID the desktop-only
        // manifest splice doesn't run, so the backend-dep section falls through
        // to the enum `switch (cfg.backend)` — which is correct, because the tag
        // is preserved and the android sections pull the backend from
        // `b.dependency("labelle_bgfx")` (resolving to the fetched package). It
        // must NOT raise ExternalBackendNeedsManifest. (Validated on-device: FP
        // builds + runs against the external bgfx; the build_files guard that
        // distinguishes "named by a tag" from "named only by string" is what
        // lets the android path through.)
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .bgfx,
            .platform = .android,
            .backend_package = .{ .name = "bgfx", .repo = "local:../bgfx" },
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.dependency(\"labelle_bgfx\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "backend_dep.module(\"android_app\")") != null);
    }

    test "external backend named ONLY by string (no matching tag) still needs a manifest (#386)" {
        // A genuine third-party backend whose package name has no matching enum
        // tag (`cfg.backend` sits at its `.raylib` default) cannot use the enum
        // switch — that would emit raylib codegen. With no manifest splice
        // (project_dir null here), it must hard-error rather than mis-emit.
        try std.testing.expectError(error.ExternalBackendNeedsManifest, generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend_package = .{ .name = "thirdparty", .repo = "local:../tp" },
            .ecs = .mock,
        }, .{}));
    }

    test "tag-matched external backend on a NON-android no-splice target still errors (#386)" {
        // The enum-path fallthrough is scoped to ANDROID only (the validated,
        // tag-safe target). A tag-matched external on wasm would otherwise emit
        // enum backend deps but miss the wasm-specific `wasm_emsdk_*`/`link_*_wasm`
        // wiring, so it must hard-error and route through the manifest instead.
        try std.testing.expectError(error.ExternalBackendNeedsManifest, generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .platform = .wasm,
            .backend_package = .{ .name = "sokol", .repo = "local:../sokol" },
            .ecs = .mock,
        }, .{}));
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

    test "unifies labelle-core onto gfx's sub-packages (camera/spatial_grid/tilemap) — gfx#276 diamond" {
        // gfx#276 threads the project `y_axis` (a core.YAxis) from the gfx
        // renderer into `camera.CameraWith(...)`. The camera/spatial_grid/
        // tilemap sub-packages pin their OWN labelle-core, so without unifying
        // them onto `core_mod` the two `core.YAxis` enums don't match and the
        // example fails to compile ("expected 'YAxis', found 'YAxis'").
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // The helper is defined and invoked from the deps section.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "fn unifyGfxSubpackageCore(") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "unifyGfxSubpackageCore(gfx_mod, core_mod);") != null);
        // It targets each of gfx's sub-packages by name.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "\"camera\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "\"spatial_grid\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "\"tilemap\"") != null);
    }

    test "unifies labelle-core onto the raylib backend input module" {
        // The raylib `input` module imports labelle-core (for GamepadEvent),
        // so it must be forced onto the project core to avoid a second core
        // module instance crossing the engine<->backend boundary. The raylib
        // backend declares the import under the hyphenated name.
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(backend_input, \"labelle-core\", core_mod)") != null);
    }

    test "unifies labelle-core onto the sdl backend input module" {
        // The SDL `input` module imports core under the UNDERSCORE name
        // `labelle_core`, so the override key must match that exactly.
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sdl,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(backend_input, \"labelle_core\", core_mod)") != null);
    }

    test "backends without a core import get no backend_input override" {
        // null / bgfx / wgpu backend `input` modules do not import
        // labelle-core, so no `overrideImport(backend_input, ...)` line
        // should be emitted. (raylib and sdl import core unconditionally;
        // sokol imports it on desktop Linux only — covered below.)
        for ([_]generate.Backend{ .null, .bgfx, .wgpu }) |be| {
            const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
                .name = "test-game",
                .backend = be,
                .ecs = .mock,
            }, .{});
            defer std.testing.allocator.free(build_zig);
            try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(backend_input,") == null);
        }
    }

    test "sokol emits a GUARDED backend_input core override (Linux core gamepad route)" {
        // On desktop Linux the sokol input module imports labelle-core
        // DIRECTLY to reach the udev/evdev gamepad source (core#33 scope 2);
        // on every other target that import is absent. The template therefore
        // emits the override behind an import_table.get guard so it fires
        // only when the import exists — asserting both halves here keeps the
        // guard from being "simplified" away into a dead-import injection
        // (#258) or dropped entirely (silent core type-split on Linux).
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "backend_input.import_table.get(\"labelle-core\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(backend_input, \"labelle-core\", core_mod)") != null);
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

    test "names desktop exe after the sanitized project name (#362)" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "energy flow!",
            .backend = .bgfx,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // The exe is named after the project so concurrent games are
        // distinguishable to `pgrep`; non-`[A-Za-z0-9_-]` bytes are dropped.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, ".name = \"energyflow\"") != null);
        // The hardcoded `bin/game` name is gone from the exe step.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "addExecutable") != null);
    }

    test "falls back to game when the sanitized exe name is empty (#362)" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "!!!",
            .backend = .bgfx,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // The exe-name line (`.name = "game",` directly preceding the
        // `.root_module = b.createModule` of `addExecutable`) is distinct
        // from the `.{ .name = "game", .module = game_mod }` import line.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, ".name = \"game\",\n        .root_module") != null);
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
