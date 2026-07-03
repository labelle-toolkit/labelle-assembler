/// build.zig and build.zig.zon generators for the labelle-cli assembler.
const std = @import("std");
const tpl = @import("template.zig");
const config = @import("config.zig");
const cache = @import("cache.zig");
const backend_registry = @import("backend_registry.zig");
const capabilities = @import("capabilities.zig");
const scan = @import("codegen/scan.zig");
const manifest_splice = @import("codegen/manifest_splice.zig");
const manifest_v2 = @import("codegen/manifest_v2.zig");
const manifest_v2_splice = @import("codegen/manifest_v2_splice.zig");
const emsdk_preflight = @import("codegen/emsdk_preflight.zig");
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

/// Sanitize a project name into a safe desktop-executable name
/// (labelle-assembler#362). Every project used to build to an
/// identically-named `zig-out/bin/game`, so concurrent games were
/// indistinguishable to `pgrep`/`pkill`. Naming the binary after the
/// project makes a running game identifiable by `pgrep -f <name>`.
///
/// Keeps only `[A-Za-z0-9_-]` (matching `labelle-cli`'s docker run path,
/// which derives the same name independently); every other byte is
/// dropped. Falls back to `"game"` when the result is empty, so the
/// generated `build.zig` always has a valid `exe.name`. Caller owns the
/// returned slice.
pub fn sanitizeExeName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (name) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (ok) try buf.append(allocator, c);
    }
    if (buf.items.len == 0) {
        buf.deinit(allocator);
        return allocator.dupe(u8, "game");
    }
    return buf.toOwnedSlice(allocator);
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
    /// Project root, used to locate the resolved backend package's
    /// `backend.manifest.v2.zon` (pluggable-backends RFC, assembler#453/#461).
    /// Null (default) means no manifest can be loaded, so codegen hard-errors —
    /// the enum/v1 fallback is gone. Only consulted when
    /// `manifest_splice.manifestPathEnabled` returns true.
    project_dir: ?[]const u8 = null,
    /// Which backend manifest file to load, relative to the resolved backend
    /// package root (manifest-v2, epic #453 item 3). `generate` auto-detects
    /// `backend.manifest.v2.zon` and threads its name here. The named manifest is
    /// header-first parsed (`manifest_v2.parseManifest`) into a `BackendManifestV2`;
    /// a v1/field-less manifest is REJECTED (the v1/enum codegen path was removed in
    /// #461). Null means no v2 manifest → codegen hard-errors. Tests pass
    /// `"backend.manifest.v2.zon"` explicitly to drive the v2 path against a fixture.
    backend_manifest_name: ?[]const u8 = null,
};

/// True when the DESKTOP build should take the manifest-v2 GENERIC declarative
/// path (loop-form `unifyCoreDiamond` walk + manifest-driven artifact/framework
/// link, design §7 golden cells like null/wgpu) rather than the sokol byte-anchor
/// unroll. Only fires for a v2 desktop build whose backend is NOT the sokol
/// byte-anchor fixture (`manifest_v2_splice.isDesktopByteAnchor`), so the
/// sokol-desktop 0-diff anchor is untouched (epic #453 item 3, PR 8).
fn desktopUsesGenericV2(v2_manifest: ?manifest_v2.BackendManifestV2, cfg: ProjectConfig) bool {
    if (cfg.platform != .desktop) return false;
    const m = v2_manifest orelse return false;
    return !manifest_v2_splice.isDesktopByteAnchor(m);
}

/// Whether the Android exe's root module must import the NativeActivity shell
/// module (published under the `backend_app` root alias). bgfx owns the
/// `android_main` entry and needs the shell to register its init/tick callbacks
/// + drive `run`; sokol's C runtime provides the entry and needs no such import.
///
/// Manifest-driven (assembler#461): the bgfx-Android platform entry declares the
/// shell as an `extra_module` aliased to `backend_app`
/// (`.{ .name = "android_app", .root_alias = "backend_app" }`), so this keys off
/// THAT declaration. Any v2 backend (including a name-only third party) that
/// declares such an extra module gets the import; one that does not (sokol-Android)
/// does not. Takes the resolved v2 manifest directly — the enum/v1 path is gone,
/// so an Android build always carries one.
fn androidNeedsAppImport(m: manifest_v2.BackendManifestV2, cfg: ProjectConfig) bool {
    const entry = manifest_v2_splice.platformEntry(m, cfg.platform) orelse return false;
    for (entry.extra_modules) |mod| {
        // Match the module's EFFECTIVE root alias as `manifest_v2_splice.moduleAlias`
        // emits it — `root_alias` if declared, else the default `backend_<name>`.
        // That equals `backend_app` iff the declared `root_alias` is `backend_app`,
        // OR (no `root_alias`) the name is `app` — so no allocation is needed. A
        // `.name = "android_app"` module with no `root_alias` is emitted as
        // `backend_android_app`, so keying off the bare name would emit
        // `.module = backend_app` for a module never declared under that alias → an
        // undefined reference. bgfx sets `.root_alias = "backend_app"` explicitly, so
        // it matches; a name-only `android_app` correctly does not.
        if (mod.root_alias) |a| {
            if (std.mem.eql(u8, a, "backend_app")) return true;
        } else if (std.mem.eql(u8, mod.name, "app")) {
            return true;
        }
    }
    return false;
}

pub fn generateBuildZig(allocator: std.mem.Allocator, cfg: ProjectConfig, opts: BuildZigOptions) ![]const u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();
    const w = &alloc_writer.writer;

    // ── Manifest-v2 backend codegen (pluggable-backends RFC, #453/#461) ────
    // The enum/v1 build-graph splice is gone (#461); every backend generates its
    // build.zig from a typed v2 `backend.manifest.v2.zon`. `generate` auto-detects
    // that file and threads its name through as `opts.backend_manifest_name`.
    //
    // Loaded UP HERE (before the header/deps emission) because a v2 android build
    // emits a hook-imported `resolve_target` header, so the platform-scaffold
    // emission below must have the manifest in hand.
    if (opts.project_dir) |pd| try manifest_splice.requireManifestIfExternal(allocator, cfg, pd, opts.backend_manifest_name);

    const use_manifest = opts.project_dir != null and
        manifest_splice.manifestPathEnabled(allocator, cfg, opts.project_dir.?, opts.backend_manifest_name);
    // The v2 build-graph manifest is now the ONLY codegen input (#461 removed the
    // enum/v1 splice). It is loaded via the auto-detected `backend_manifest_name`
    // (`generate` probes for `backend.manifest.v2.zon`). A build that resolves no v2
    // manifest cannot be wired and errors below.
    var v2_manifest: ?manifest_v2.BackendManifestV2 = null;
    defer if (v2_manifest) |m| std.zon.parse.free(allocator, m);
    if (use_manifest) {
        if (opts.backend_manifest_name) |name| {
            v2_manifest = try manifest_v2.loadNamedManifest(allocator, cfg, opts.project_dir.?, name);
        }
    }

    // ── Capability negotiation on the v2 path (RFC step 1, epic #453 PR 11) ──
    // The v2 manifest carries its OWN `.id` + `.capabilities`; the resolve-time
    // `validateProviderContracts` (root.zig) reads only the v1 `backend.manifest.zon`
    // via `loadProviderManifest`, so a v2-only third-party backend (no legacy
    // sibling) would bypass BOTH identity and capability checks. Run them HERE,
    // against the v2 manifest, BEFORE any build-graph text is emitted — so a
    // project requiring a capability the backend does not declare fails with the
    // readable project-level `error.UnsupportedCapability` (capabilities.validate)
    // rather than a deep codegen/compile error, and a third party claiming the
    // reserved `labelle.*` namespace is still rejected (validateProviderIdentity).
    // No-op in production (v2_manifest is null unless `backend_manifest_name`
    // opts into a v2 manifest), so the enum/v1 path is byte-unchanged.
    if (v2_manifest) |m| {
        try backend_registry.validateProviderIdentity(cfg, m.id);
        // SKIPPED for the tests target (issue #83), consistent with the
        // root-level `validateProviderContracts` skip: that target
        // force-substitutes `cfg.backend = .null` (a headless test HARNESS)
        // while keeping the rest of the config describing the REAL backend's
        // needs, so `requiredCapabilities(cfg)` still derives e.g.
        // `.raw_gui_adapter`. The forced-null harness never builds the real
        // GUI/gamepad, and null-v2 declares only `.headless`, so requiring the
        // gate here would hard-fail `zig build test` for every GUI/gamepad
        // project. Identity check above stays ON (cheap + still valid); only
        // the capability REQUIREMENT is skipped. The real exe target
        // (`is_tests_target = false`) still enforces the gate.
        if (!opts.is_tests_target) {
            const required = try capabilities.requiredCapabilities(allocator, cfg);
            defer allocator.free(required);
            const provider_id = m.id orelse cfg.backendName();
            try capabilities.validate(required, m.capabilities, provider_id);
        }
    }

    // #461: the enum/v1 codegen path is deleted, so a v2 build-graph manifest is
    // now MANDATORY. A build that reaches here without one (no `project_dir`, or a
    // backend that ships no `backend.manifest.v2.zon`) cannot be wired — fail loudly
    // rather than emit a broken build.zig. Every emission below can therefore unwrap
    // `v2_manifest` unconditionally.
    const manifest = v2_manifest orelse return error.ExternalBackendNeedsManifest;

    if (cfg.platform == .wasm) {
        // manifest-v2 wasm: the header imports the backend hook and resolves the
        // STATIC wasm32-emscripten target inline (design §3 — a fixed .triple, so NO
        // resolve_target hook).
        try manifest_v2_splice.renderWasmHeaderV2(manifest, w);
    } else if (cfg.platform == .ios) {
        // manifest-v2 ios: the header imports the backend hook and resolves BOTH the
        // ios target and the SDK path via `resolve_target` (design §4).
        try manifest_v2_splice.renderIosHeaderV2(manifest, w);
    } else if (cfg.platform == .android) {
        // manifest-v2 android: the header imports the backend hook and resolves the
        // android target via `resolve_target` (design §4).
        try manifest_v2_splice.renderAndroidHeaderV2(manifest, w);
    } else {
        try tpl.writeSection(build_zig_tmpl, "header", w);
    }

    if (cfg.platform == .ios) {
        // `target` (the alias for `ios_target`) is consumed by the deps/plugin
        // decls AND by `emitPromotedScriptModules` (`.target = target`). Emit the
        // alias whenever ANY consumer needs it — including promoted scripts on an
        // otherwise plugin/ECS/GUI-free game (PR #466 Finding 1).
        if (cfg.plugins.len > 0 or cfg.ecs != .mock or cfg.hasGui() or opts.promoted_scripts.len > 0) {
            try tpl.writeSection(build_zig_tmpl, "ios_target_alias", w);
        }
        // manifest-v2 ios: emit the core/gfx/engine dep decls WITHOUT the unrolled
        // overrideImport diamond — the generic `unifyCoreDiamond` walk (emitted after
        // the backend-dep section) replaces it (design §5).
        try manifest_v2_splice.renderIosDepsDeclsV2(w);
        try tpl.writeSection(build_zig_tmpl, "game_mod_decl_ios", w);
    } else if (cfg.platform == .android) {
        // `target` (the alias for `android_target`) is consumed by the deps/plugin
        // decls AND by `emitPromotedScriptModules` (`.target = target`). Include the
        // promoted-scripts condition so `target` is defined whenever any consumer
        // needs it — a promoted-scripts + no-plugin/ECS/GUI android game previously
        // emitted an undefined `target` (PR #466 Finding 1).
        if (cfg.plugins.len > 0 or cfg.ecs != .mock or cfg.hasGui() or opts.promoted_scripts.len > 0) {
            try tpl.writeSection(build_zig_tmpl, "android_target_alias", w);
        }
        // manifest-v2 android: emit the core/gfx/engine dep decls WITHOUT the
        // unrolled overrideImport diamond — the generic `unifyCoreDiamond` walk
        // replaces it (design §5).
        try manifest_v2_splice.renderAndroidDepsDeclsV2(w);
        try tpl.writeSection(build_zig_tmpl, "game_mod_decl_android", w);
    } else if (cfg.platform == .wasm) {
        // manifest-v2 wasm: emit the core/gfx/engine dep decls WITHOUT the unrolled
        // overrideImport diamond — the generic `unifyCoreDiamond` walk replaces it
        // (design §5). Uses the plain `target` alias the v2 wasm header declares.
        try manifest_v2_splice.renderWasmDepsDeclsV2(w);
        try tpl.writeSection(build_zig_tmpl, "game_mod_decl", w);
    } else {
        // manifest-v2 GENERIC desktop (PR 8, e.g. null/wgpu): emit the core/gfx/
        // engine dep decls WITHOUT the unrolled overrideImport diamond — the
        // generic `unifyCoreDiamond` walk (emitted after the backend-dep section)
        // replaces it (design §5/§7). The sokol byte-anchor desktop cell keeps the
        // enum `deps` (unrolled) so its 0-diff holds — hence the anchor guard.
        if (desktopUsesGenericV2(v2_manifest, cfg)) {
            try manifest_v2_splice.renderDesktopDepsDeclsV2(w);
        } else {
            try tpl.writeSection(build_zig_tmpl, "deps", w);
        }
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

    // Backend dep — always the standard backend (never a merged GUI+backend
    // package). manifest-v2 codegen (design §3/§5/§7): render the b.dependency
    // literal + modules + artifacts from typed manifest data. Desktop is the sokol
    // byte-anchor / generic-declarative golden; android/ios/wasm are golden cells —
    // the backend-dep emitter also appends the generic core-diamond walk calls.
    try manifest_v2_splice.renderBackendDepSectionV2(allocator, manifest, cfg, w);

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
        // manifest-v2 wasm: no emsdk-helper import in the generated build.zig — the
        // emcc residual moved into the backend hook's `post_wire`, which resolves
        // emsdk itself via `b.dependency("emsdk", .{})` (design §2 (c)).

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

        // emsdk activation preflight (labelle-assembler#492). The manifest-v2
        // `post_wire` owns the emcc wiring, so every wasm build emits this guard.
        // Runs at configure time, before the emcc link step, turning the opaque
        // `.../upstream/emscripten/emcc file_hash FileNotFound` into an actionable
        // "run ./emsdk install/activate" message.
        try emsdk_preflight.emitCheckCall(w);

        // WASM link step. manifest-v2 wasm: the generic link (linkLibrary the wasm
        // lib's artifact) plus the `post_wire` hook call for the emcc `emLinkStep`
        // residual + install/run wiring (design §2 (c) / §4). The hook owns the emcc
        // step AND (being void) the install/run wiring.
        try manifest_v2_splice.renderLinkSectionV2(allocator, manifest, cfg, w);

        // manifest-v2 wasm footer: the build-fn close + helper defs (post_wire owns
        // install/run), then the generic `unifyCoreDiamond` walk (design §5) as a
        // top-level helper — same footer→walk shape as android/ios.
        try manifest_v2_splice.renderWasmFooterV2(w);
        try w.writeByte('\n');
        try manifest_v2_splice.emitCoreDiamondWalk(w);

        // The `ensureEmsdkActivated` helper the guard call above invokes — a
        // top-level fn appended after the footer, same footer→helper shape as the
        // core-diamond walk (labelle-assembler#492).
        try emsdk_preflight.emitHelperFn(w);
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

        // manifest-v2 ios: the generic link (linkLibrary + link_libc + linkFramework
        // from `.frameworks.ios`) plus the `post_wire` hook call for the SDK
        // include/lib/framework paths residual (design §4).
        try manifest_v2_splice.renderLinkSectionV2(allocator, manifest, cfg, w);

        // Bridge artifact (raw_backend GUIs)
        if (cfg.resolved_gui) |gui| {
            if (gui.rendering == .raw_backend and gui.bridge_dir != null) {
                try tpl.renderSection(build_zig_tmpl, "gui_bridge", .{ .bridge_artifact_name = gui.bridge_artifact }, w);
                try tpl.writeSection(build_zig_tmpl, "ios_link_gui_bridge", w);
            }
        }

        // manifest-v2 packaging seam (design §3/§6): ios ships `.binary` (a NO-OP),
        // so this emits nothing — but it keeps every v2 platform path routing
        // packaging through the shared packager off the typed `PlatformEntry.package`
        // recipe.
        try manifest_v2_splice.renderPackageV2(manifest, cfg.platform, w);

        try tpl.writeSection(build_zig_tmpl, "ios_footer", w);

        // manifest-v2 ios emits the generic `unifyCoreDiamond` walk (design §5) as a
        // top-level helper AFTER the build fn + the footer's `overrideImport` def it
        // calls.
        try w.writeByte('\n');
        try manifest_v2_splice.emitCoreDiamondWalk(w);
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

        // bgfx owns the NativeActivity `android_main` entry, so the
        // generated `main.zig` imports the `android_app` shell module under
        // `backend_app` (registers init/tick callbacks, drives `run`). The
        // sokol Android path has no such import — sokol's C runtime
        // provides the entry. Keyed off the v2 manifest's `backend_app`
        // extra-module declaration (assembler#461), not the backend enum.
        if (androidNeedsAppImport(manifest, cfg)) {
            try tpl.writeSection(build_zig_tmpl, "android_exe_app_import", w);
        }

        try tpl.writeSection(build_zig_tmpl, "android_exe_end", w);

        // Promoted game-script modules → Android lib root module (#240 Gap 2).
        try emitPromotedScriptImports(w, "lib", opts.promoted_scripts);

        // manifest-v2 android: the generic link (linkLibrary + linkSystemLibrary from
        // `.system_libs.android` + `link_libc`) plus the `post_wire` hook call for the
        // NDK-sysroot / addLibraryPath / libc.txt residual (design §4).
        try manifest_v2_splice.renderLinkSectionV2(allocator, manifest, cfg, w);

        if (cfg.resolved_gui) |gui| {
            if (gui.rendering == .raw_backend and gui.bridge_dir != null) {
                try tpl.renderSection(build_zig_tmpl, "gui_bridge", .{ .bridge_artifact_name = gui.bridge_artifact }, w);
                try tpl.writeSection(build_zig_tmpl, "android_link_gui_bridge", w);
            }
        }

        // Packaging: v2 delegates the `.apk` recipe to the shared packager.
        try manifest_v2_splice.renderPackageV2(manifest, cfg.platform, w);
        try tpl.writeSection(build_zig_tmpl, "android_footer", w);

        // manifest-v2 android emits the generic `unifyCoreDiamond` walk (design §5)
        // as a top-level helper AFTER the build fn + the footer's `overrideImport`
        // def it calls.
        try w.writeByte('\n');
        try manifest_v2_splice.emitCoreDiamondWalk(w);
    } else {
        // Desktop: build as executable, link natively. Test-only targets
        // (issue #83) skip the exe assembly + backend artifact link + bridge
        // entirely — they go straight from the deps/plugin/gui wiring above
        // to the test step below, then to a stripped footer that closes the
        // build function without referencing `exe`.
        if (!opts.is_tests_target) {
            // Name the desktop binary after the project (sanitized) so a
            // running game is identifiable by `pgrep -f <name>` instead of
            // every project building to an indistinguishable `bin/game`
            // (labelle-assembler#362). `labelle run` is unaffected — it uses
            // `zig build run`, which resolves the artifact by step, not path.
            const exe_name = try sanitizeExeName(allocator, cfg.name);
            defer allocator.free(exe_name);
            try tpl.renderSection(build_zig_tmpl, "exe_start", .{ .exe_name = exe_name }, w);

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

            // Link backend artifact. manifest-v2 desktop codegen: linkLibrary from
            // manifest artifacts + the per-OS framework/system-lib wiring (design
            // §3/§5/§7). null emits nothing (no artifact); sokol is the byte anchor.
            try manifest_v2_splice.renderLinkSectionV2(allocator, manifest, cfg, w);

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

        // manifest-v2 GENERIC desktop (PR 8): mirror the native linkage
        // (artifact `linkLibrary` + per-OS framework/syslib switch) onto
        // `test_root` too. `test_root` imports the backend modules, so a
        // wgpu-backed project's `zig build test` links against symbols in
        // `glfw` + the macOS Metal/Foundation/QuartzCore frameworks; the
        // exe-only link above left the test binary unresolved (review #469
        // coderabbit). The enum/sokol byte-anchor path links only the exe, so
        // this is generic-desktop-only. null emits nothing (no artifact/fw).
        if (desktopUsesGenericV2(v2_manifest, cfg)) {
            try manifest_v2_splice.renderDesktopTestLinkGenericV2(v2_manifest.?, w);
        }

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

        // manifest-v2 packaging seam (epic #453 item 3, PR 4): delegate this
        // platform's packaging to the shared packager off the typed
        // `PlatformEntry.package` recipe. Desktop's `.binary` is a NO-OP, so this
        // does not disturb the PR-3 desktop byte anchor; the apk/web recipes
        // (Android/wasm, PRs 5/7) emit their packaging block here.
        if (v2_manifest) |m| {
            try manifest_v2_splice.renderPackageV2(m, cfg.platform, w);
        }

        // Test-only target (issue #83): close the build function without
        // installing/running the exe. Otherwise emit the regular footer
        // that wires `b.installArtifact(exe)` and the `run` step.
        if (opts.is_tests_target) {
            try tpl.writeSection(build_zig_tmpl, "tests_only_footer", w);
        } else {
            try tpl.writeSection(build_zig_tmpl, "footer", w);
        }

        // manifest-v2 GENERIC desktop (PR 8) emits the generic `unifyCoreDiamond`
        // walk (design §5) as a top-level helper AFTER the build fn + the footer's
        // `overrideImport` def it calls — same footer→walk shape as android/ios.
        // The sokol byte-anchor desktop cell unrolls the overrides instead, so this
        // is generic-desktop-only (guarded by `desktopUsesGenericV2`).
        if (desktopUsesGenericV2(v2_manifest, cfg)) {
            try w.writeByte('\n');
            try manifest_v2_splice.emitCoreDiamondWalk(w);
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
    /// Which backend manifest file to load, relative to the resolved backend
    /// package root (manifest-v2, epic #453 item 3, PR 7). Null (default) keeps
    /// the PRODUCTION path 100% unchanged: emsdk is emitted for any wasm build
    /// via the hardcoded `dep_emsdk` section. When set AND the named manifest is
    /// `manifest_version >= 2`, the wasm emsdk dependency is instead driven by the
    /// manifest's `.platforms.wasm.root_build_deps` (design §3 `RootBuildDep`,
    /// review #459 finding 2) — a `.builtin` emsdk resolves to that same pinned
    /// section, so the emitted zon stays byte-identical. Mirrors
    /// `BuildZigOptions.backend_manifest_name`.
    backend_manifest_name: ?[]const u8 = null,
};

/// The `build.zig.zon` dependency KEY for the backend on the manifest-v2 path.
///
/// A v2 backend's generated `build.zig` resolves its provider modules via
/// `b.dependency(m.dep_name, ..)` (e.g. `b.dependency("acme_foo", ..)` for a
/// third-party backend), so the `build.zig.zon` dependency entry MUST be keyed
/// by `m.dep_name` — NOT the `labelle_<name>` derivation the zon generator /
/// deps-linker otherwise uses. The two diverge for a third-party backend whose
/// package name is not `labelle_*` (acme_foo → dep key `labelle_acme_foo` in the
/// zon vs `b.dependency("acme_foo")` in build.zig), so Zig can't resolve the
/// backend dependency. For a BUILT-IN v2 backend `m.dep_name` already equals the
/// `labelle_<name>` derivation (sokol → `labelle_sokol`), so the emitted key is
/// byte-unchanged.
///
/// Returns null — meaning "keep the `labelle_<name>` derivation" — for the
/// v1/enum path, when no manifest is requested, or when the requested manifest
/// isn't enabled for this target. Allocator-owned; caller frees. Errors
/// propagate exactly as the root-build-deps load does (a broken v2 manifest
/// fails zon generation, matching the build.zig generator — #468 finding 1).
fn v2BackendDepName(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    project_dir: ?[]const u8,
    backend_manifest_name: ?[]const u8,
) !?[]const u8 {
    const pd = project_dir orelse return null;
    const name = backend_manifest_name orelse return null;
    if (!manifest_splice.manifestPathEnabled(allocator, cfg, pd, name)) return null;
    const m = try manifest_v2.loadNamedManifest(allocator, cfg, pd, name);
    defer std.zon.parse.free(allocator, m);
    return try allocator.dupe(u8, m.dep_name);
}

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
    // Free `resolved_deps` on every subsequent error path. This defer must be
    // installed here — immediately after assignment — because fallible calls
    // below (e.g. `v2BackendDepName`) can return before the
    // `if (resolved_deps) |deps|` block, leaking the entries otherwise.
    defer if (resolved_deps) |deps| deps_linker.freeDepEntries(allocator, deps);

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

    // Manifest-v2 backend dep key: the generated build.zig calls
    // `b.dependency(m.dep_name, ..)`, so the zon backend entry must be keyed by
    // `m.dep_name` (see `v2BackendDepName`). Null → keep the `labelle_<name>`
    // derivation (v1/enum path, byte-unchanged; also unchanged for a built-in v2
    // backend whose `dep_name` already equals the derivation).
    const v2_backend_dep_name = try v2BackendDepName(allocator, cfg, project_dir, opts.backend_manifest_name);
    defer if (v2_backend_dep_name) |n| allocator.free(n);

    if (resolved_deps) |deps| {
        // Freed by the `defer` installed right after `resolved_deps` is
        // assigned (above), so it also covers the fallible calls in between.
        // Deps are at .labelle/deps/, zon is at .labelle/<target>/
        const prefix = if (output_dir != null and target_dir != null) "../deps" else "deps";
        // The deps-linker names the backend entry by the `labelle_<name>`
        // convention; on the v2 path that entry (and ONLY it) is re-keyed to
        // `m.dep_name` so build.zig and build.zig.zon agree on the backend dep.
        const derived_backend_zon = try std.fmt.allocPrint(allocator, "labelle_{s}", .{cfg.backendName()});
        defer allocator.free(derived_backend_zon);
        for (deps) |dep| {
            const zon_name = if (v2_backend_dep_name) |dn|
                (if (std.mem.eql(u8, dep.zon_name, derived_backend_zon)) dn else dep.zon_name)
            else
                dep.zon_name;
            try w.print("        .{s} = .{{\n", .{zon_name});
            try w.print("            .path = \"{s}/{s}\",\n", .{ prefix, dep.link_name });
            try w.writeAll("        },\n");
        }
    } else {
        // Fallback: relative paths (for tests without target_dir)
        try generateZonPathsFallback(allocator, cfg, target_dir, project_dir, v2_backend_dep_name, w);
    }

    // Root build-time deps a backend hook resolves via `b.dependency` at consumer
    // build time (design §3 `RootBuildDep`). On the manifest-v2 path (PR 7) the
    // wasm emsdk dep is driven by the manifest's `.platforms.wasm.root_build_deps`;
    // a `.builtin` emsdk reuses the pinned `dep_emsdk` section so the emitted zon
    // is byte-identical to the enum path. The production/enum path keeps the
    // hardcoded per-platform emsdk emission unchanged.
    var v2_root_deps_emitted = false;
    // Mirror `generateBuildZig`'s manifest gate + load so the two generators
    // agree: gate the load on `manifestPathEnabled` (a missing manifest → enum
    // fallback in BOTH), and propagate load errors with `try` rather than
    // swallowing them with `catch null`. A v2 manifest that fails to load must
    // error in build.zig.zon generation exactly as it does in build.zig
    // generation — otherwise a build.zig that resolved its hook deps against a
    // v2 manifest could be paired with a build.zig.zon that silently fell back
    // to enum output, producing a divergent (and broken) pair. #468 finding 1.
    if (project_dir) |pd| {
        if (opts.backend_manifest_name) |name| {
            if (manifest_splice.manifestPathEnabled(allocator, cfg, pd, name)) {
                const m = try manifest_v2.loadNamedManifest(allocator, cfg, pd, name);
                defer std.zon.parse.free(allocator, m);
                const dep_emsdk = tpl.getSection(build_zig_zon_tmpl, "dep_emsdk") orelse "";
                try manifest_v2_splice.emitRootBuildDepsV2(m, cfg.platform, dep_emsdk, w);
                v2_root_deps_emitted = true;
            }
        }
    }
    if (!v2_root_deps_emitted and cfg.platform == .wasm) {
        try tpl.writeSection(build_zig_zon_tmpl, "dep_emsdk", w);
    }

    try tpl.writeSection(build_zig_zon_tmpl, "footer", w);

    var arr_list = alloc_writer.toArrayList();
    return arr_list.toOwnedSlice(allocator);
}

/// Fallback: compute relative paths when deps/ symlinks aren't available.
/// `v2_backend_dep_name` (see `v2BackendDepName`) re-keys the backend dep entry
/// on the manifest-v2 path so it matches `b.dependency(m.dep_name, ..)` in the
/// generated build.zig; null keeps the `labelle_<name>` derivation.
fn generateZonPathsFallback(allocator: std.mem.Allocator, cfg: ProjectConfig, target_dir: ?[]const u8, project_dir: ?[]const u8, v2_backend_dep_name: ?[]const u8, w: anytype) !void {
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
        const bn = cfg.backendName();
        // Location seam: built-in → bundled slot; external → plugin checkout.
        const bp_abs = try backend_registry.resolveBackendPackage(allocator, cfg, project_dir);
        defer allocator.free(bp_abs);
        const bp = try relativePath(allocator, abs_target, bp_abs);
        defer allocator.free(bp);
        if (cfg.isExternal()) {
            // External backends have no per-name `dep_<name>_path` template
            // section — emit the dep inline (same shape as the plugin loop and
            // the built-in template sections: `.labelle_<name> = .{ .path }`).
            // On the v2 path the entry is keyed by `m.dep_name` so it matches
            // `b.dependency(m.dep_name, ..)` in the generated build.zig; the
            // v1/enum path keeps the `labelle_<name>` derivation.
            if (v2_backend_dep_name) |dn| {
                try w.print("        .{s} = .{{ .path = \"{s}\" }},\n", .{ dn, bp });
            } else {
                try w.print("        .labelle_{s} = .{{ .path = \"{s}\" }},\n", .{ bn, bp });
            }
        } else {
            // Built-in: keep the embedded per-name template section so the
            // generated zon stays byte-identical to before this change.
            var sb: [64]u8 = undefined;
            const section = std.fmt.bufPrint(&sb, "dep_{s}_path", .{bn}) catch unreachable;
            try tpl.renderSection(build_zig_zon_tmpl, section, .{ .backend_path = bp }, w);
        }
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
