const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cli_version: []const u8 = b.option([]const u8, "cli_version", "CLI version string") orelse "dev";
    // Framework version defaults stamped into a freshly scaffolded
    // project.labelle by `init`. These MUST be real, fetchable release
    // versions — a fresh project has to build out of the box. They used to
    // fall back to `cli_version` ("dev" in a non-release build), which the
    // fetcher then mapped to a bogus `vdev` git ref (issue #159). A release
    // build of the CLI overrides each with `-D<pkg>_version=`.
    // Keep this trio a MUTUALLY COMPATIBLE set: a fresh `labelle init` resolves
    // these defaults, so a mismatch fails `labelle build` before any user code.
    // engine 1.75.1 pins gfx v1.21.0 (test-only) and floors core at v1.24.0;
    // gfx v1.21.0 in turn pins core v1.24.0 — read straight from those tags'
    // build.zig.zon. Bump all three together when moving the engine default.
    const core_version: []const u8 = b.option([]const u8, "core_version", "Default core library version") orelse "1.24.0";
    const engine_version: []const u8 = b.option([]const u8, "engine_version", "Default engine library version") orelse "1.75.1";
    const gfx_version: []const u8 = b.option([]const u8, "gfx_version", "Default gfx library version") orelse "1.21.0";
    // Version this assembler binary stamps into a freshly scaffolded
    // project.labelle's `assembler_version` field. Defaults to the
    // package version from build.zig.zon so a release binary pins itself.
    const assembler_version: []const u8 = b.option([]const u8, "assembler_version", "Default assembler version for `init`") orelse blk: {
        const v = @import("build.zig.zon").version;
        break :blk v;
    };

    const zspec_dep = b.dependency("zspec", .{ .target = target, .optimize = optimize });
    const flow_codegen_dep = b.dependency("flow_codegen", .{ .target = target, .optimize = optimize });
    const flow_codegen_module = flow_codegen_dep.module("flow_codegen");

    const options = b.addOptions();
    options.addOption([]const u8, "cli_version", cli_version);
    options.addOption([]const u8, "core_version", core_version);
    options.addOption([]const u8, "engine_version", engine_version);
    options.addOption([]const u8, "gfx_version", gfx_version);
    options.addOption([]const u8, "assembler_version", assembler_version);

    const generator_module = b.addModule("generator", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    generator_module.addOptions("build_options", options);
    generator_module.addImport("flow_codegen", flow_codegen_module);

    // ── Assembler binary ───────────────────────────────────────────────
    const assembler_exe = b.addExecutable(.{
        .name = "labelle-assembler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    assembler_exe.root_module.addOptions("build_options", options);
    assembler_exe.root_module.addImport("flow_codegen", flow_codegen_module);
    // `src/flow_catalog/json_writer.zig` calls `std.posix.system.clock_gettime`
    // for the sidecar's `generated_at` timestamp. On Linux/macOS Zig finds
    // the libc symbols implicitly via the system loader, but Windows
    // cross-compiles require explicit `linkLibC()` (Zig 0.16's `std.time.timestamp`
    // was removed). Cheap addition for a build tool that already depends on
    // libc transparently.
    assembler_exe.root_module.link_libc = true;
    b.installArtifact(assembler_exe);

    const assembler_run = b.addRunArtifact(assembler_exe);
    if (b.args) |args| assembler_run.addArgs(args);
    const run_step = b.step("run", "Run the labelle-assembler binary");
    run_step.dependOn(&assembler_run.step);

    // ── Tests ───────────────────────────────────────────────────────────
    const test_step = b.step("test", "Run assembler tests");

    // Unit tests from src/
    const src_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    src_tests.root_module.addOptions("build_options", options);
    src_tests.root_module.addImport("flow_codegen", flow_codegen_module);
    src_tests.root_module.link_libc = true; // see assembler_exe comment above
    test_step.dependOn(&b.addRunArtifact(src_tests).step);

    // Subcommand tests — `src/main.zig` is the binary's root and reaches
    // the subcommand modules (`init_cmd`, `cache_cmd`) that `src/root.zig`
    // (the `generator` library) intentionally does not import.
    const bin_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bin_tests.root_module.addOptions("build_options", options);
    bin_tests.root_module.addImport("flow_codegen", flow_codegen_module);
    bin_tests.root_module.link_libc = true; // see assembler_exe comment above
    test_step.dependOn(&b.addRunArtifact(bin_tests).step);

    // BDD-style tests from test/. Each test target gets `generator`,
    // `zspec`, and `flow_codegen` so any future test file can reach
    // them without further build.zig churn. flow_codegen is cheap to
    // attach (pure-Zig sub-package, no native deps) so the blanket
    // import isn't an unwanted runtime cost.
    const test_files = [_][]const u8{
        // BDD test suites previously concentrated in test/tests.zig
        // (3768 lines). Split by domain via #184. Shared fixtures live
        // in test/helpers.zig.
        "test/build_zig_zon_tests.zig",
        "test/build_zig_tests.zig",
        "test/main_zig_tests.zig",
        "test/scene_asset_manifests_tests.zig",
        "test/backend_wiring_tests.zig",
        "test/scripts_prefabs_views_layers_tests.zig",
        "test/resources_tests.zig",
        "test/window_subfolders_imgui_tests.zig",
        "test/preview_mode_tests.zig",
        "test/script_scanner_tests.zig",
        "test/deps_linker_tests.zig",
        "test/template_dynamic_test.zig",
        "test/scanner_symlink_tests.zig",
        "test/scanner_orphan_tests.zig",
        // Packs dir-scan (RFC §4, labelle-assembler#439): scanPack copy/scan
        // + emission assertions that pack components/events/prefabs reach the
        // generated registries.
        "test/pack_scan_tests.zig",
        // flow_scanner test shim — re-exports per-domain test sections
        // from `test/flow_scanner/*.zig` so a single zspec dispatcher
        // walks them all. The split was issue #185 (was 2445 lines).
        "test/flow_scanner_tests.zig",
        // labelle-engine#578 — engine-side extension to
        // `discoverPluginEvents` (engine pass walks
        // `labelle-engine/src/root.zig` for `pub const Events`).
        "test/engine_events_discovery_test.zig",
    };

    for (test_files) |test_file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "generator", .module = generator_module },
                    .{ .name = "zspec", .module = zspec_dep.module("zspec") },
                    .{ .name = "flow_codegen", .module = flow_codegen_module },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // manifest-v2 sokol backend HOOK (epic #453 item 3, PR 5 android + PR 6 ios).
    // The dedicated hook (`backends/sokol/backend.hook.zig`) is a std-only file the
    // generated v2 android/ios build.zig `@import`s and calls
    // (`resolve_target`/`post_wire`, design §4). Compiling it as its own test target
    // is the design §7 "run the hook in the gate" gate: it typechecks the residual
    // against the real `std.Build` API (addLibraryPath/setLibCFile/linkSystemLibrary/
    // addSystemFrameworkPath/resolveTargetQuery must stay valid) AND runs the hook's
    // pure-helper unit tests (android arch selection, NDK triple, required-SDK
    // enforcement, libc.txt body; ios SDK-name/target selection, required SDK-path
    // enforcement). It takes NO generator/zspec imports — a hook must make no
    // package-local import assumptions (§3).
    const hook_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("backends/sokol/backend.hook.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(hook_tests).step);

    // manifest-v2 raylib backend HOOK (epic #453 item 3, PR 9). raylib's dedicated
    // hook (`backends/raylib_v2/backend.hook.zig`) is a std-only file the generated
    // v2 WASM build.zig `@import`s and calls (`post_wire`, design §4 residual (c)).
    // Compiling it as its own test target is the design §7 "run the hook in the
    // gate": it typechecks the emcc `emLinkStep` reconstruction against the real
    // `std.Build` API (addSystemCommand/addArtifactArg/addInstallDirectory must
    // stay valid) AND runs the hook's pure decision tests (the raylib web emcc
    // args). Like sokol's hook it takes NO generator/zspec imports (§3).
    const raylib_hook_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("backends/raylib_v2/backend.hook.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(raylib_hook_tests).step);

    // manifest-v2 bgfx backend HOOK (epic #453 item 3, PR 10). bgfx's dedicated
    // hook (`backends/bgfx_v2/backend.hook.zig`) is a std-only file the generated v2
    // ANDROID build.zig `@import`s and calls (`resolve_target`/`post_wire`, design
    // §4). Compiling it as its own test target is the design §7 "run the hook in the
    // gate": it typechecks the android residual (addLibraryPath/setLibCFile/
    // resolveTargetQuery) against the real `std.Build` API AND runs the hook's pure
    // decision tests (arch selection, NDK triple, required-SDK enforcement, libc.txt
    // body). Like sokol/raylib's hooks it takes NO generator/zspec imports (§3).
    const bgfx_hook_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("backends/bgfx_v2/backend.hook.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(bgfx_hook_tests).step);
}
