/// build.zig and build.zig.zon generators for the labelle-cli assembler.
const std = @import("std");
const tpl = @import("template.zig");
const config = @import("config.zig");
const cache = @import("cache.zig");
const scan = @import("codegen/scan.zig");
pub const deps_linker = @import("deps_linker.zig");

const ProjectConfig = config.ProjectConfig;

// Build file templates
const build_zig_tmpl = @embedFile("templates/build_zig.txt");
const build_zig_zon_tmpl = @embedFile("templates/build_zig_zon.txt");

// ============================================================
// build.zig generator
// ============================================================

/// Returns the project-relative directory of an in-project library
/// plugin (`@libs/<lib>` → `libs/<lib>`), or null if the plugin is not
/// an in-project library. Used to chain each lib's `test` step into the
/// generated `test` step (issue #82).
///
/// Out-of-project `local:../foo` plugins are intentionally excluded:
/// their `test` step is not part of *this* project's test surface, and
/// their path can escape the project root. Only `@`-prefixed plugins
/// whose resolved path lands under `libs/` qualify.
fn inProjectLibDir(plugin: config.PluginDep) ?[]const u8 {
    if (!std.mem.startsWith(u8, plugin.repo, "@")) return null;
    const path = plugin.localPath();
    if (!std.mem.startsWith(u8, path, "libs/")) return null;
    return path;
}

/// Emit one `const <named>_mod = b.createModule(...)` per FlowNodes-bearing
/// game script (labelle-assembler#240 Gap 2), plus an
/// `overrideImport(game_mod, "<named>", <named>_mod)` so the shim's
/// `PluginFlowNodes` can `@import("<named>")`.
///
/// The promoted module's `.imports` table mirrors a game script's import
/// surface as seen from the root module: `labelle-core`, `labelle-gfx`,
/// `labelle-engine`, the four backend modules, every plugin (each by its
/// project.labelle `.name`, since game scripts `@import("<plugin>")` by
/// that name), and — when present — `ecs_backend` / `gui_backend`. This is
/// the exact set the exe/root module exposes, so a script's own
/// `@import("labelle-engine")` / `@import("box2d")` resolves identically
/// whether the file is path-imported by the root module or rooted in its
/// own named module.
///
/// Must be called AFTER the deps/backend/ecs/gui/plugin module variables
/// (`core_mod`, `engine_mod`, `backend_gfx`, `ecs_mod`, `gui_mod`,
/// `plugin_<name>_mod`) and `game_mod` are all in scope, and BEFORE the
/// exe/tests modules that import the named modules are created.
fn emitPromotedScriptModules(
    w: anytype,
    cfg: ProjectConfig,
    promoted_scripts: []const scan.PromotedScript,
) !void {
    if (promoted_scripts.len == 0) return;
    try w.writeByte('\n');
    try w.writeAll("    // Named modules for FlowNodes-bearing game scripts (#240 Gap 2).\n");
    for (promoted_scripts) |s| {
        try w.print("    const {s}_mod = b.createModule(.{{\n", .{s.module_name});
        try w.print("        .root_source_file = b.path(\"scripts/{s}\"),\n", .{s.rel_path});
        try w.writeAll("        .target = target,\n");
        try w.writeAll("        .optimize = optimize,\n");
        try w.writeAll("        .imports = &.{\n");
        try w.writeAll("            .{ .name = \"labelle-core\", .module = core_mod },\n");
        try w.writeAll("            .{ .name = \"labelle-gfx\", .module = gfx_mod },\n");
        try w.writeAll("            .{ .name = \"labelle-engine\", .module = engine_mod },\n");
        try w.writeAll("            .{ .name = \"backend_gfx\", .module = backend_gfx },\n");
        try w.writeAll("            .{ .name = \"backend_input\", .module = backend_input },\n");
        try w.writeAll("            .{ .name = \"backend_audio\", .module = backend_audio },\n");
        try w.writeAll("            .{ .name = \"backend_window\", .module = backend_window },\n");
        if (cfg.ecs != .mock) {
            try w.writeAll("            .{ .name = \"ecs_backend\", .module = ecs_mod },\n");
        }
        if (cfg.hasGui()) {
            try w.writeAll("            .{ .name = \"gui_backend\", .module = gui_mod },\n");
        }
        for (cfg.plugins) |plugin| {
            try w.print("            .{{ .name = \"{s}\", .module = plugin_{s}_mod }},\n", .{ plugin.name, plugin.name });
        }
        try w.writeAll("        },\n");
        try w.writeAll("    });\n");
        // The `game` module (shim) reaches the script via the named import
        // too. `overrideImport` rather than `addImport` keeps the GPA-leak
        // avoidance consistent with the plugin wiring above; it's a no-op
        // if the shim doesn't reference this particular module.
        try w.print("    overrideImport(game_mod, \"{s}\", {s}_mod);\n", .{ s.module_name, s.module_name });
    }
}

/// Emit `<artifact>.root_module.addImport("<named>", <named>_mod)` for
/// every promoted game-script module (labelle-assembler#240 Gap 2), so
/// the exe/wasm/lib/test root module can `@import("<named>")` from
/// main.zig's `AllScripts` + `PluginFlowNodes`. `artifact` is the build
/// variable name (`exe`, `wasm`, `lib`, or `test_root`).
fn emitPromotedScriptImports(
    w: anytype,
    artifact: []const u8,
    promoted_scripts: []const scan.PromotedScript,
) !void {
    for (promoted_scripts) |s| {
        try w.print("    {s}.root_module.addImport(\"{s}\", {s}_mod);\n", .{ artifact, s.module_name, s.module_name });
    }
}

pub const BuildZigOptions = struct {
    /// Emit a test-only build.zig: skip the exe step, the run step,
    /// and the backend artifact link. Used by `generateTestsTarget`
    /// in root.zig for `.labelle/tests/build.zig` (issue #83).
    is_tests_target: bool = false,
    /// Game scripts promoted to NAMED build-system modules because they
    /// export `pub const FlowNodes` (labelle-assembler#240 Gap 2). Each
    /// gets a `b.createModule` decl wired into BOTH the exe/root and
    /// `game` modules so `@import("<named>")` resolves from either side
    /// without the file landing in two modules at once. Defaults to
    /// empty — projects with no FlowNodes-bearing scripts (the common
    /// case) emit nothing here and keep their byte-identical build.zig.
    promoted_scripts: []const scan.PromotedScript = &.{},
};

pub fn generateBuildZig(allocator: std.mem.Allocator, cfg: ProjectConfig, opts: BuildZigOptions) ![]const u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();
    const w = &alloc_writer.writer;

    if (cfg.platform == .wasm) {
        try tpl.writeSection(build_zig_tmpl, "header_wasm", w);
        try tpl.writeSection(build_zig_tmpl, "wasm_target", w);
    } else if (cfg.platform == .ios) {
        try tpl.writeSection(build_zig_tmpl, "header_ios", w);
    } else if (cfg.platform == .android) {
        try tpl.writeSection(build_zig_tmpl, "header_android", w);
    } else {
        try tpl.writeSection(build_zig_tmpl, "header", w);
    }

    if (cfg.platform == .ios) {
        if (cfg.plugins.len > 0 or cfg.ecs != .mock or cfg.hasGui()) {
            try tpl.writeSection(build_zig_tmpl, "ios_target_alias", w);
        }
        try tpl.writeSection(build_zig_tmpl, "ios_deps", w);
        try tpl.writeSection(build_zig_tmpl, "game_mod_decl_ios", w);
    } else if (cfg.platform == .android) {
        if (cfg.plugins.len > 0 or cfg.ecs != .mock or cfg.hasGui()) {
            try tpl.writeSection(build_zig_tmpl, "android_target_alias", w);
        }
        try tpl.writeSection(build_zig_tmpl, "android_deps", w);
        try tpl.writeSection(build_zig_tmpl, "game_mod_decl_android", w);
    } else {
        try tpl.writeSection(build_zig_tmpl, "deps", w);
        // Bind the `game` module right after deps so the exe/tests
        // module imports below can reference `game_mod`. See
        // labelle-assembler#116.
        try tpl.writeSection(build_zig_tmpl, "game_mod_decl", w);
    }

    // Plugin dep/module declarations (for all declared plugins)
    for (cfg.plugins) |plugin| {
        if (cfg.platform == .ios) {
            // Pass iOS SDK path to plugins so C dependencies can find system headers
            try w.print("    const plugin_{s}_dep = b.dependency(\"labelle_{s}\", .{{ .target = target, .optimize = optimize, .ios_sdk_path = @as(?[]const u8, sdk_path) }});\n", .{ plugin.name, plugin.name });
        } else {
            try w.print("    const plugin_{s}_dep = b.dependency(\"labelle_{s}\", .{{ .target = target, .optimize = optimize }});\n", .{ plugin.name, plugin.name });
        }
        try w.print("    const plugin_{s}_mod = plugin_{s}_dep.module(\"labelle_{s}\");\n", .{ plugin.name, plugin.name, plugin.name });
    }

    // `gamepad_enabled` flips the shared SDL desktop gamepad source on
    // (core#28 slice 5). When `.auto`, the backend's build.zig wires
    // `sdl_gamepad` + links SDL2 on desktop and routes through it; when
    // `.none` (opt-out), the backend omits the import and links no SDL, and
    // the input module's gamepad queries resolve to the truly-disabled path.
    // Computed + substituted exactly like `with_imgui`.
    const gamepad_enabled: []const u8 = if (cfg.gamepad == .auto) "true" else "false";

    // Backend dep — always the standard backend (never a merged GUI+backend package)
    switch (cfg.backend) {
        .raylib => try tpl.renderSection(build_zig_tmpl, "backend_raylib", .{ .gamepad_enabled = gamepad_enabled }, w),
        .sokol => {
            // `with_imgui` must be true ONLY when the project's gui plugin
            // is imgui — sokol_imgui.c needs cimgui.h on its include path,
            // which only the imgui bridge provides. When imgui IS in the
            // dep graph, the option set here MUST match
            // `labelle-imgui/bridges/sokol/build.zig` exactly so Zig
            // resolves a single `sokol_clib` artifact (and a single `_sg`
            // static state) — see labelle-assembler#140.
            const with_imgui: []const u8 = if (cfg.resolved_gui) |gui|
                if (std.mem.eql(u8, gui.name, "imgui")) "true" else "false"
            else
                "false";
            if (cfg.platform == .wasm) {
                try tpl.renderSection(build_zig_tmpl, "backend_sokol_wasm", .{ .with_imgui = with_imgui }, w);
            } else if (cfg.platform == .ios) {
                try tpl.renderSection(build_zig_tmpl, "backend_sokol_ios", .{ .with_imgui = with_imgui }, w);
            } else if (cfg.platform == .android) {
                try tpl.renderSection(build_zig_tmpl, "backend_sokol_android", .{ .with_imgui = with_imgui }, w);
            } else {
                try tpl.renderSection(build_zig_tmpl, "backend_sokol", .{ .with_imgui = with_imgui, .gamepad_enabled = gamepad_enabled }, w);
            }
        },
        .sdl => try tpl.writeSection(build_zig_tmpl, "backend_sdl", w),
        .bgfx => try tpl.writeSection(build_zig_tmpl, "backend_bgfx", w),
        .wgpu => try tpl.writeSection(build_zig_tmpl, "backend_wgpu", w),
        .null => try tpl.writeSection(build_zig_tmpl, "backend_null", w),
    }

    switch (cfg.ecs) {
        .mock => {},
        .zig_ecs => try tpl.renderSection(build_zig_tmpl, "ecs_adapter", .{ .ecs_dep_name = "labelle_zig_ecs" }, w),
        .zflecs => try tpl.renderSection(build_zig_tmpl, "ecs_adapter", .{ .ecs_dep_name = "labelle_zflecs" }, w),
        .mr_ecs => try tpl.renderSection(build_zig_tmpl, "ecs_adapter", .{ .ecs_dep_name = "labelle_mr_ecs" }, w),
    }

    // labelle-assembler#275 — the tests target's `game.zig` shim
    // instantiates `Game` over the REAL ECS backend (`@import("ecs_backend")`)
    // so a backend-agnostic `labelle test` can drive plugin systems
    // headless. The exe target's shim re-exports `engine.Game` and never
    // imports `ecs_backend`, so this wiring is tests-only. `overrideImport`
    // is a no-op for the mock backend (no `ecs_mod` exists, and the shim
    // uses `engine.MockEcsBackend` directly), so the guard skips it.
    if (opts.is_tests_target and cfg.ecs != .mock) {
        try w.writeAll("    overrideImport(game_mod, \"ecs_backend\", ecs_mod);\n");
    }

    // GUI plugin dep (manifest-driven — no switch on GUI type)
    if (cfg.resolved_gui) |gui| {
        const gui_mod_name = try std.fmt.allocPrint(allocator, "labelle_{s}", .{gui.name});
        defer allocator.free(gui_mod_name);
        try tpl.renderSection(build_zig_tmpl, "gui_backend", .{ .gui_dep_name = "labelle_gui", .gui_mod_name = gui_mod_name }, w);
    }

    // Inject shared modules into plugins — ensures all plugins use the same
    // package instances and have access to engine subsystems (#42, #61).
    if (cfg.plugins.len > 0) {
        try w.writeByte('\n');
        for (cfg.plugins) |plugin| {
            // Core + gfx + engine — use overrideImport to avoid GPA leaks
            try w.print("    overrideImport(plugin_{s}_mod, \"labelle-core\", core_mod);\n", .{plugin.name});
            try w.print("    overrideImport(plugin_{s}_mod, \"labelle-gfx\", gfx_mod);\n", .{plugin.name});
            try w.print("    overrideImport(plugin_{s}_mod, \"labelle-engine\", engine_mod);\n", .{plugin.name});

            // ECS backend
            if (cfg.ecs != .mock) {
                try w.print("    overrideImport(plugin_{s}_mod, \"ecs_backend\", ecs_mod);\n", .{plugin.name});
            }

            // Backend modules
            try w.print("    overrideImport(plugin_{s}_mod, \"backend_gfx\", backend_gfx);\n", .{plugin.name});
            try w.print("    overrideImport(plugin_{s}_mod, \"backend_input\", backend_input);\n", .{plugin.name});
            try w.print("    overrideImport(plugin_{s}_mod, \"backend_audio\", backend_audio);\n", .{plugin.name});
            try w.print("    overrideImport(plugin_{s}_mod, \"backend_window\", backend_window);\n", .{plugin.name});

            // GUI backend
            if (cfg.hasGui()) {
                try w.print("    overrideImport(plugin_{s}_mod, \"gui_backend\", gui_mod);\n", .{plugin.name});
            }

            // Sibling plugins — every plugin can `@import("<other-plugin>")`
            // and reach its root module. Closes flying-platform-labelle#262.
            // `overrideImport` is a no-op for plugins that don't actually
            // import the sibling, so wiring all-to-all is safe and keeps
            // the assembler's manifest schema unchanged.
            for (cfg.plugins) |sibling| {
                if (std.mem.eql(u8, plugin.name, sibling.name)) continue;
                try w.print("    overrideImport(plugin_{s}_mod, \"{s}\", plugin_{s}_mod);\n", .{ plugin.name, sibling.name, sibling.name });
            }

            // `game.zig` shim re-exports `PluginEvents` (RFC-PLUGIN-EVENTS
            // phase 3) — wire each plugin into `game_mod` so the shim's
            // `@import("<plugin>")` resolves. `overrideImport` is a no-op
            // when the shim doesn't import the plugin (project with no
            // plugins), so wiring every plugin is safe.
            try w.print("    overrideImport(game_mod, \"{s}\", plugin_{s}_mod);\n", .{ plugin.name, plugin.name });
        }
    }

    // ── Named-module promotion for FlowNodes-bearing game scripts ──
    // (labelle-assembler#240 Gap 2). A game script that exports
    // `pub const FlowNodes` is referenced from BOTH the root module
    // (main.zig's `AllScripts` for hook registration) AND the `game`
    // module (the shim's `PluginFlowNodes`). Path-importing the same
    // file from two module roots is a hard Zig error
    // ("file exists in modules 'root' and 'game'"). Promoting it to a
    // standalone NAMED module sidesteps that: the file is the root of
    // its own module, and every consumer reaches it via
    // `@import("<named>")`. Here we declare the module and wire it into
    // `game_mod`; the exe/tests root modules pick it up via the
    // `addImport` calls emitted after their creation below. The module
    // mirrors a game script's import surface (engine + every plugin +
    // ecs/gui backends) so the script's own `@import("labelle-engine")`
    // / `@import("<plugin>")` resolve exactly as they do when the file
    // is path-imported by the root module.
    try emitPromotedScriptModules(w, cfg, opts.promoted_scripts);

    if (cfg.platform == .wasm) {
        // WASM: import emsdk helpers from backend
        switch (cfg.backend) {
            .raylib => try tpl.writeSection(build_zig_tmpl, "wasm_emsdk_raylib", w),
            .sokol => try tpl.writeSection(build_zig_tmpl, "wasm_emsdk_sokol", w),
            else => {},
        }

        // WASM: build as library, link via emcc
        try tpl.writeSection(build_zig_tmpl, "wasm_exe_start", w);

        for (cfg.plugins) |plugin| {
            try w.print("                .{{ .name = \"{s}\", .module = plugin_{s}_mod }},\n", .{ plugin.name, plugin.name });
        }

        if (cfg.ecs != .mock) {
            try tpl.writeSection(build_zig_tmpl, "wasm_exe_ecs_import", w);
        }
        if (cfg.hasGui()) {
            try tpl.writeSection(build_zig_tmpl, "wasm_exe_gui_import", w);
        }
        try tpl.writeSection(build_zig_tmpl, "wasm_exe_game_import", w);

        try tpl.writeSection(build_zig_tmpl, "wasm_exe_end", w);

        // Promoted game-script modules → wasm root module (#240 Gap 2).
        try emitPromotedScriptImports(w, "wasm", opts.promoted_scripts);

        // Link bridge artifact for WASM (raw_backend GUIs) BEFORE the
        // backend-specific link step. sokol-zig's `emLinkStep` snapshots
        // `lib_main.getCompileDependencies(false)` to assemble the emcc
        // command line — libraries linked AFTER `emLinkStep` returned
        // don't always end up on the emcc cmdline reliably (observed
        // missing `libsokol_imgui_bridge.a` despite `linkLibrary`
        // running before `make()`, labelle-assembler#141). Moving the
        // bridge link to BEFORE the backend's emLinkStep call ensures
        // the dep list is complete when emcc args are gathered.
        if (cfg.resolved_gui) |gui| {
            if (gui.rendering == .raw_backend and gui.bridge_dir != null) {
                try tpl.renderSection(build_zig_tmpl, "gui_bridge", .{ .bridge_artifact_name = gui.bridge_artifact }, w);
                try tpl.writeSection(build_zig_tmpl, "link_gui_bridge_wasm", w);
            }
        }

        switch (cfg.backend) {
            .raylib => try tpl.writeSection(build_zig_tmpl, "link_raylib_wasm", w),
            .sokol => try tpl.writeSection(build_zig_tmpl, "link_sokol_wasm", w),
            else => {},
        }

        try tpl.writeSection(build_zig_tmpl, "wasm_footer", w);
    } else if (cfg.platform == .ios) {
        // iOS: build executable for simulator, link frameworks manually
        try tpl.writeSection(build_zig_tmpl, "ios_exe_start", w);

        for (cfg.plugins) |plugin| {
            try w.print("                .{{ .name = \"{s}\", .module = plugin_{s}_mod }},\n", .{ plugin.name, plugin.name });
        }

        if (cfg.ecs != .mock) {
            try tpl.writeSection(build_zig_tmpl, "ios_exe_ecs_import", w);
        }
        if (cfg.hasGui()) {
            try tpl.writeSection(build_zig_tmpl, "ios_exe_gui_import", w);
        }
        try tpl.writeSection(build_zig_tmpl, "ios_exe_game_import", w);

        try tpl.writeSection(build_zig_tmpl, "ios_exe_end", w);

        // Promoted game-script modules → iOS exe root module (#240 Gap 2).
        try emitPromotedScriptImports(w, "exe", opts.promoted_scripts);

        try tpl.writeSection(build_zig_tmpl, "ios_link", w);

        // Bridge artifact (raw_backend GUIs)
        if (cfg.resolved_gui) |gui| {
            if (gui.rendering == .raw_backend and gui.bridge_dir != null) {
                try tpl.renderSection(build_zig_tmpl, "gui_bridge", .{ .bridge_artifact_name = gui.bridge_artifact }, w);
                try tpl.writeSection(build_zig_tmpl, "ios_link_gui_bridge", w);
            }
        }

        try tpl.writeSection(build_zig_tmpl, "ios_footer", w);
    } else if (cfg.platform == .android) {
        // Android: build shared library for NativeActivity, link NDK libs
        try tpl.writeSection(build_zig_tmpl, "android_exe_start", w);

        for (cfg.plugins) |plugin| {
            try w.print("                .{{ .name = \"{s}\", .module = plugin_{s}_mod }},\n", .{ plugin.name, plugin.name });
        }

        if (cfg.ecs != .mock) {
            try tpl.writeSection(build_zig_tmpl, "android_exe_ecs_import", w);
        }
        if (cfg.hasGui()) {
            try tpl.writeSection(build_zig_tmpl, "android_exe_gui_import", w);
        }
        try tpl.writeSection(build_zig_tmpl, "android_exe_game_import", w);

        try tpl.writeSection(build_zig_tmpl, "android_exe_end", w);

        // Promoted game-script modules → Android lib root module (#240 Gap 2).
        try emitPromotedScriptImports(w, "lib", opts.promoted_scripts);

        // Pass target_sdk_version from AndroidConfig (default 34) for NDK library path
        const android_cfg = cfg.android orelse config.AndroidConfig{};
        var sdk_buf: [10]u8 = undefined;
        const sdk_version_str = std.fmt.bufPrint(&sdk_buf, "{d}", .{android_cfg.target_sdk_version}) catch "34";
        try tpl.renderSection(build_zig_tmpl, "android_link", .{ .target_sdk_version = sdk_version_str }, w);

        if (cfg.resolved_gui) |gui| {
            if (gui.rendering == .raw_backend and gui.bridge_dir != null) {
                try tpl.renderSection(build_zig_tmpl, "gui_bridge", .{ .bridge_artifact_name = gui.bridge_artifact }, w);
                try tpl.writeSection(build_zig_tmpl, "android_link_gui_bridge", w);
            }
        }

        try tpl.writeSection(build_zig_tmpl, "android_package", w);
        try tpl.writeSection(build_zig_tmpl, "android_footer", w);
    } else {
        // Desktop: build as executable, link natively. Test-only targets
        // (issue #83) skip the exe assembly + backend artifact link + bridge
        // entirely — they go straight from the deps/plugin/gui wiring above
        // to the test step below, then to a stripped footer that closes the
        // build function without referencing `exe`.
        if (!opts.is_tests_target) {
            try tpl.writeSection(build_zig_tmpl, "exe_start", w);

            for (cfg.plugins) |plugin| {
                try w.print("                .{{ .name = \"{s}\", .module = plugin_{s}_mod }},\n", .{ plugin.name, plugin.name });
            }

            if (cfg.ecs != .mock) {
                try tpl.writeSection(build_zig_tmpl, "exe_ecs_import", w);
            }
            if (cfg.hasGui()) {
                try tpl.writeSection(build_zig_tmpl, "exe_gui_import", w);
            }
            try tpl.writeSection(build_zig_tmpl, "exe_game_import", w);

            try tpl.writeSection(build_zig_tmpl, "exe_end", w);

            // Wire each promoted game-script module into the exe's root
            // module so main.zig's `AllScripts` + `PluginFlowNodes` can
            // `@import("<named>")` (labelle-assembler#240 Gap 2).
            try emitPromotedScriptImports(w, "exe", opts.promoted_scripts);

            // Link backend artifact
            switch (cfg.backend) {
                .raylib => try tpl.writeSection(build_zig_tmpl, "link_raylib", w),
                .sokol => try tpl.writeSection(build_zig_tmpl, "link_sokol", w),
                .sdl => try tpl.writeSection(build_zig_tmpl, "link_sdl", w),
                .bgfx => try tpl.writeSection(build_zig_tmpl, "link_bgfx", w),
                .wgpu => try tpl.writeSection(build_zig_tmpl, "link_wgpu", w),
                // Null backend has no native artifact — every backend module is
                // pure Zig, no library to link.
                .null => {},
            }

            // Bridge artifact (raw_backend GUIs) — declare + link
            if (cfg.resolved_gui) |gui| {
                if (gui.rendering == .raw_backend and gui.bridge_dir != null) {
                    try tpl.renderSection(build_zig_tmpl, "gui_bridge", .{ .bridge_artifact_name = gui.bridge_artifact }, w);
                    try tpl.writeSection(build_zig_tmpl, "link_gui_bridge", w);
                }
            }
        }

        // ── Test step (desktop only) ───────────────────────────────
        // Emits the same plugin/ecs/gui import shape as the exe so test
        // files have access to the full game module graph. Cross-compile
        // targets (wasm/ios/android) skip this — tests run on the host.
        try tpl.writeSection(build_zig_tmpl, "tests_start", w);
        for (cfg.plugins) |plugin| {
            try w.print("                        .{{ .name = \"{s}\", .module = plugin_{s}_mod }},\n", .{ plugin.name, plugin.name });
        }
        if (cfg.ecs != .mock) {
            try tpl.writeSection(build_zig_tmpl, "tests_ecs_import", w);
        }
        if (cfg.hasGui()) {
            try tpl.writeSection(build_zig_tmpl, "tests_gui_import", w);
        }
        try tpl.writeSection(build_zig_tmpl, "tests_game_import", w);
        try tpl.writeSection(build_zig_tmpl, "tests_end", w);

        // Wire promoted game-script modules into the test root module too
        // — the merged `AllScripts` block compiles into the test binary
        // exactly as it does the exe (labelle-assembler#240 Gap 2). The
        // tests target (issue #83) shares this codepath, so its
        // `__tests_root.zig` reaches the same named modules.
        try emitPromotedScriptImports(w, "test_root", opts.promoted_scripts);

        // Chain each in-project library's `test` step into the master
        // `test` step (issue #82). An `@libs/<lib>` plugin lives at
        // `libs/<lib>/` under the project root and ships its own
        // `build.zig`; `zig build test` here shells out to each one so a
        // single invocation covers the game-side `tests/` files and
        // every in-project library. Out-of-project `local:` plugins are
        // skipped — they aren't part of this project's test surface.
        for (cfg.plugins) |plugin| {
            const lib_dir = inProjectLibDir(plugin) orelse continue;
            // build.zig sits at `.labelle/<backend>_<platform>/`, so the
            // lib dir is two levels up from the build root.
            const lib_cwd = try std.fmt.allocPrint(allocator, "../../{s}", .{lib_dir});
            defer allocator.free(lib_cwd);
            try tpl.renderSection(build_zig_tmpl, "lib_test_step", .{
                .lib_cwd = lib_cwd,
                .lib_name = plugin.name,
            }, w);
        }

        // Test-only target (issue #83): close the build function without
        // installing/running the exe. Otherwise emit the regular footer
        // that wires `b.installArtifact(exe)` and the `run` step.
        if (opts.is_tests_target) {
            try tpl.writeSection(build_zig_tmpl, "tests_only_footer", w);
        } else {
            try tpl.writeSection(build_zig_tmpl, "footer", w);
        }
    }

    var arr_list = alloc_writer.toArrayList();
    return arr_list.toOwnedSlice(allocator);
}

// ============================================================
// build.zig.zon generator
// ============================================================

pub const BuildZigZonOptions = struct {
    /// True (default) wipes the shared `.labelle/deps/` directory before
    /// recreating it. The tests target (issue #83) sets this to false so
    /// the second-pass generation merges its null-backend dep into the
    /// existing dir without orphaning the exe target's chosen-backend dep.
    recreate_deps: bool = true,
};

pub fn generateBuildZigZon(allocator: std.mem.Allocator, cfg: ProjectConfig, target_dir: ?[]const u8, output_dir: ?[]const u8, project_dir: ?[]const u8, opts: BuildZigZonOptions) ![]const u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();
    const w = &alloc_writer.writer;

    // Create deps/ hardlinks in .labelle/deps/ (shared across targets).
    // On failure (e.g. a `local:` plugin pointing at a non-existent
    // directory), log loudly and fall back to cache-relative paths.
    // Silent failure used to mask the underlying issue and surface
    // later as cryptic "package's path-relative dep doesn't resolve"
    // errors during `zig build` — see labelle-toolkit/labelle-cli#174.
    const deps_parent = output_dir orelse target_dir;
    const resolved_deps: ?[]const deps_linker.DepEntry = if (deps_parent != null and project_dir != null)
        deps_linker.createDepsLinks(allocator, cfg, deps_parent.?, project_dir.?, .{ .recreate = opts.recreate_deps }) catch |err| blk: {
            // OOM is not recoverable by retrying with cache-relative
            // paths — those need allocation too. Propagate so the caller
            // can fail cleanly instead of papering over the failure.
            if (err == error.OutOfMemory) return err;
            // Cache location is configurable via `LABELLE_HOME` (see
            // `src/cache.zig`), so we don't hardcode `~/.labelle/...`
            // in the user-facing message — and we route via std.log.warn
            // for proper level / sink integration with the rest of the
            // CLI's output.
            std.log.warn(
                "createDepsLinks failed ({s}); falling back to cache-relative dep paths.\n" ++
                    "  This often masks the real cause: a `local:` plugin path that doesn't exist,\n" ++
                    "  or a missing entry in the package cache. Check your project.labelle plugins.",
                .{@errorName(err)},
            );
            break :blk null;
        }
    else
        null;

    // Zig 0.16 validates `build.zig.zon` fingerprints with the formula
    // `(fingerprint >> 32) == std.hash.Crc32.hash(name)` where `name`
    // is the literal `.name` field in the zon file — *not* the project
    // name from project.labelle. The template hardcodes
    // `.name = .generated_game,` so the CRC seed is fixed too. The
    // lower 32 bits are a free-form "fork ID" derived from cfg.name so
    // regenerating yields a stable value per project (no gratuitous
    // cache invalidation). The previous FNV-1a-based hash produced
    // fingerprints rejected by Zig 0.16's validator.
    //
    // The id half can't be 0 (reserved by Zig 0.16 for "unhashed") or
    // 0xffffffff (reserved for "explicitly opted out of dedup"). Both
    // reservations are checked in `std.zon.Manifest`; a project name
    // whose Wyhash happens to land on either would generate a zon
    // file that fails validation despite the correct CRC half. Clamp
    // to a safe non-reserved value.
    const zon_package_name = "generated_game";
    const name_crc: u32 = std.hash.Crc32.hash(zon_package_name);
    const fork_id: u32 = blk: {
        var h = std.hash.Wyhash.init(0xa11e11e);
        h.update(cfg.name);
        const raw: u32 = @truncate(h.final());
        // Coerce away the two reserved sentinels.
        break :blk switch (raw) {
            0 => 1,
            0xffffffff => 0xfffffffe,
            else => raw,
        };
    };
    const hash: u64 = (@as(u64, name_crc) << 32) | @as(u64, fork_id);
    var hash_buf: [16]u8 = undefined;
    const hash_str = std.fmt.bufPrint(&hash_buf, "{x}", .{hash}) catch unreachable;

    try tpl.renderSection(build_zig_zon_tmpl, "header", .{ .hash = hash_str, .version = cfg.version }, w);

    if (resolved_deps) |deps| {
        defer deps_linker.freeDepEntries(allocator, deps);
        // Deps are at .labelle/deps/, zon is at .labelle/<target>/
        const prefix = if (output_dir != null and target_dir != null) "../deps" else "deps";
        for (deps) |dep| {
            try w.print("        .{s} = .{{\n", .{dep.zon_name});
            try w.print("            .path = \"{s}/{s}\",\n", .{ prefix, dep.link_name });
            try w.writeAll("        },\n");
        }
    } else {
        // Fallback: relative paths (for tests without target_dir)
        try generateZonPathsFallback(allocator, cfg, target_dir, project_dir, w);
    }

    if (cfg.platform == .wasm) {
        try tpl.writeSection(build_zig_zon_tmpl, "dep_emsdk", w);
    }

    try tpl.writeSection(build_zig_zon_tmpl, "footer", w);

    var arr_list = alloc_writer.toArrayList();
    return arr_list.toOwnedSlice(allocator);
}

/// Fallback: compute relative paths when deps/ symlinks aren't available.
fn generateZonPathsFallback(allocator: std.mem.Allocator, cfg: ProjectConfig, target_dir: ?[]const u8, project_dir: ?[]const u8, w: anytype) !void {
    const abs_target: ?[]const u8 = if (target_dir) |td|
        std.Io.Dir.cwd().realPathFileAlloc(config.globalIo(), td, allocator) catch null
    else
        null;
    defer if (abs_target) |at| allocator.free(at);

    const core_abs = try cache.resolveFrameworkPackage(allocator, "core", cfg.core_version, project_dir);
    defer allocator.free(core_abs);
    const core_path = try relativePath(allocator, abs_target, core_abs);
    defer allocator.free(core_path);
    const gfx_abs = try cache.resolveFrameworkPackage(allocator, "gfx", cfg.gfx_version, project_dir);
    defer allocator.free(gfx_abs);
    const gfx_path = try relativePath(allocator, abs_target, gfx_abs);
    defer allocator.free(gfx_path);
    const engine_abs = try cache.resolveFrameworkPackage(allocator, "engine", cfg.engine_version, project_dir);
    defer allocator.free(engine_abs);
    const engine_path = try relativePath(allocator, abs_target, engine_abs);
    defer allocator.free(engine_path);

    try tpl.renderSection(build_zig_zon_tmpl, "dep_core_path", .{ .core_path = core_path, .gfx_path = gfx_path, .engine_path = engine_path }, w);

    for (cfg.plugins) |plugin| {
        const p_abs = try cache.resolvePlugin(allocator, plugin, project_dir);
        defer allocator.free(p_abs);
        const p = try relativePath(allocator, abs_target, p_abs);
        defer allocator.free(p);
        try w.print("        .labelle_{s} = .{{ .path = \"{s}\" }},\n", .{ plugin.name, p });
    }

    {
        const bn = @tagName(cfg.backend);
        var sb: [64]u8 = undefined;
        const section = std.fmt.bufPrint(&sb, "dep_{s}_path", .{bn}) catch unreachable;
        var spb: [128]u8 = undefined;
        const sp = std.fmt.bufPrint(&spb, "backends/{s}", .{bn}) catch unreachable;
        const bp_abs = try cache.resolveBundledPackage(allocator, cfg.labelle_version, cfg.assembler_version, project_dir, sp);
        defer allocator.free(bp_abs);
        const bp = try relativePath(allocator, abs_target, bp_abs);
        defer allocator.free(bp);
        try tpl.renderSection(build_zig_zon_tmpl, section, .{ .backend_path = bp }, w);
    }

    switch (cfg.ecs) {
        .mock => {},
        .zig_ecs, .zflecs, .mr_ecs => {
            const dn: []const u8 = switch (cfg.ecs) { .zig_ecs => "labelle_zig_ecs", .zflecs => "labelle_zflecs", .mr_ecs => "labelle_mr_ecs", .mock => unreachable };
            const dd: []const u8 = switch (cfg.ecs) { .zig_ecs => "zig-ecs", .zflecs => "zflecs", .mr_ecs => "mr-ecs", .mock => unreachable };
            var spb: [128]u8 = undefined;
            const sp = std.fmt.bufPrint(&spb, "ecs/{s}", .{dd}) catch unreachable;
            const ep_abs = try cache.resolveBundledPackage(allocator, cfg.labelle_version, cfg.assembler_version, project_dir, sp);
            defer allocator.free(ep_abs);
            const ep = try relativePath(allocator, abs_target, ep_abs);
            defer allocator.free(ep);
            try tpl.renderSection(build_zig_zon_tmpl, "dep_ecs_path", .{ .ecs_dep_name = dn, .ecs_path = ep }, w);
        },
    }

    if (cfg.resolved_gui) |gui| {
        const gp = try relativePath(allocator, abs_target, gui.plugin_dir);
        defer allocator.free(gp);
        try tpl.renderSection(build_zig_zon_tmpl, "dep_gui_path", .{ .gui_dep_name = "labelle_gui", .gui_path = gp }, w);
        if (gui.bridge_dir) |bd| {
            const bp = try relativePath(allocator, abs_target, bd);
            defer allocator.free(bp);
            try tpl.renderSection(build_zig_zon_tmpl, "dep_gui_bridge_path", .{ .bridge_path = bp }, w);
        }
    }
}

/// Compute a relative path from `from_dir` to `to_path`.
/// If from_dir is null, returns a copy of to_path (absolute).
/// Both must be absolute paths when from_dir is provided. Returns an allocator-owned string.
fn relativePath(allocator: std.mem.Allocator, from_dir: ?[]const u8, to_path: []const u8) ![]const u8 {
    if (from_dir == null) return try allocator.dupe(u8, to_path);
    return std.fs.path.relative(allocator, "", null, from_dir.?, to_path);
}
