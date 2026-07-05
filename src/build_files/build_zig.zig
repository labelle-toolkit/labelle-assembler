/// `build.zig` generator for the labelle-cli assembler.
///
/// Extracted from the former single-file `build_files.zig` (behavior-preserving
/// split, mirrors #539/#541). Emits the generated project's `build.zig` from the
/// embedded template + the resolved backend manifest-v2 data.
const std = @import("std");
const tpl = @import("../template.zig");
const config = @import("../config.zig");
const backend_registry = @import("../backend_registry.zig");
const capabilities = @import("../capabilities.zig");
const scan = @import("../codegen/scan.zig");
const pack_root = @import("../codegen/pack_root.zig");
const manifest_splice = @import("../codegen/manifest_splice.zig");
const manifest_v2 = @import("../codegen/manifest_v2.zig");
const manifest_v2_splice = @import("../codegen/manifest_v2_splice.zig");
const emsdk_preflight = @import("../codegen/emsdk_preflight.zig");

const ProjectConfig = config.ProjectConfig;

// Build file template
const build_zig_tmpl = @embedFile("../templates/build_zig.txt");

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

/// Emit one `const pack__<prefix>_mod = b.createModule(...)` per light pack
/// (assembler#498 PR 2, "wire the wall"), rooted at the generated
/// `packs/<name>/__pack_root.zig`.
///
/// The import table is the pack isolation contract. It mirrors
/// `emitPromotedScriptModules`' surface — engine/core/gfx, the four backend
/// modules, `ecs_backend`/`gui_backend` when wired, and every decl-module
/// plugin (plugins are the sanctioned inter-domain surface; FP's packs route
/// worker access through `worker_controller`'s citizens surface by design) —
/// and deliberately EXCLUDES the `game` shim and every sibling pack. A pack
/// file importing either is now unresolvable, which is the wall. `depends_on`
/// surface modules land in PR 4; the `@import("pack")` self-import + Registry
/// bridge land in PR 3.
///
/// After all pack modules are declared, the implicit shared `contracts` pack
/// (`pack_validate.IMPLICIT_DEPS`) — when the project declares one — is wired
/// into every OTHER pack module via `overrideImport(…, "contracts", …)`. A
/// two-pass shape because declaration order between packs is arbitrary.
///
/// Gated on pack presence: a pack-less project emits nothing (byte-identical
/// build.zig, the invariant every #498 PR keeps).
fn emitPackModules(
    w: anytype,
    cfg: ProjectConfig,
    pack_modules: []const pack_root.PackModule,
) !void {
    if (pack_modules.len == 0) return;
    try w.writeByte('\n');
    try w.writeAll("    // Per-pack modules (assembler#498 \"wire the wall\"): each light\n");
    try w.writeAll("    // pack's files belong to its OWN module, whose restricted import\n");
    try w.writeAll("    // table (no `game`, no sibling packs) is the isolation boundary.\n");
    for (pack_modules) |p| {
        try w.print("    const pack__{s}_mod = b.createModule(.{{\n", .{p.prefix});
        try w.print("        .root_source_file = b.path(\"packs/{s}/__pack_root.zig\"),\n", .{p.name});
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
        // Self-import (#498 PR 3): pack code reaches its own module root —
        // and the Registry bridge on it — as `@import("pack")`, uniform
        // across packs so authored code never hardcodes its prefix.
        try w.print("    overrideImport(pack__{s}_mod, \"pack\", pack__{s}_mod);\n", .{ p.prefix, p.prefix });
    }
    // Implicit `contracts` wiring — dependents reach the shared-vocabulary
    // pack as `@import("contracts")`. `contracts` itself must not
    // self-import. Deliberately the FULL pack module, not a surface:
    // exposes-narrowing doesn't apply to the shared-vocabulary pack
    // (`pack_validate.IMPLICIT_DEPS`).
    const contracts: ?pack_root.PackModule = for (pack_modules) |p| {
        if (std.mem.eql(u8, p.name, pack_root.CONTRACTS_PACK_NAME)) break p;
    } else null;
    if (contracts) |c| {
        for (pack_modules) |p| {
            if (std.mem.eql(u8, p.name, c.name)) continue;
            try w.print("    overrideImport(pack__{s}_mod, \"contracts\", pack__{s}_mod);\n", .{ p.prefix, c.prefix });
        }
    }

    // Surface modules (#498 PR 4): rooted at the generated
    // `__surface.zig`, sole import = the pack module itself (as "pack" —
    // the same self-name the pack's own code uses). Declared ON DEMAND:
    // only packs some sibling actually `depends_on` get a module var —
    // an unconditionally-declared one that nothing references would be
    // Zig's "unused local constant" compile error in the generated
    // build.zig (the `__surface.zig` FILE is still written for every
    // pack, so adding a dependent later changes only this wiring).
    var any_surface = false;
    for (pack_modules) |p| {
        const depended = blk: {
            for (pack_modules) |q| {
                for (q.depends_on) |dep| {
                    if (std.mem.eql(u8, dep, pack_root.CONTRACTS_PACK_NAME)) continue;
                    if (std.mem.eql(u8, dep, p.name)) break :blk true;
                }
            }
            break :blk false;
        };
        if (!depended) continue;
        if (!any_surface) {
            try w.writeAll("    // Pack `exposes` surfaces (#498 PR 4): the only face a dependent sees.\n");
            any_surface = true;
        }
        try w.print("    const pack_surface__{s}_mod = b.createModule(.{{\n", .{p.prefix});
        try w.print("        .root_source_file = b.path(\"packs/{s}/__surface.zig\"),\n", .{p.name});
        try w.writeAll("        .target = target,\n");
        try w.writeAll("        .optimize = optimize,\n");
        try w.print("        .imports = &.{{.{{ .name = \"pack\", .module = pack__{s}_mod }}}},\n", .{p.prefix});
        try w.writeAll("    });\n");
    }

    // `depends_on` wiring (#498 PR 4): a dependency that names a sibling
    // PACK maps the dep's plain name onto its SURFACE module — dependents
    // never see `pack__<prefix>` (whose root re-exports the private
    // internals). Entries naming decl-module plugins are already in every
    // pack module's import table; `contracts` was wired above as the
    // implicit full module.
    for (pack_modules) |p| {
        for (p.depends_on) |dep| {
            if (std.mem.eql(u8, dep, pack_root.CONTRACTS_PACK_NAME)) continue;
            const dep_pack: ?pack_root.PackModule = for (pack_modules) |q| {
                if (std.mem.eql(u8, q.name, dep)) break q;
            } else null;
            if (dep_pack) |d| {
                try w.print("    overrideImport(pack__{s}_mod, \"{s}\", pack_surface__{s}_mod);\n", .{ p.prefix, dep, d.prefix });
            }
        }
    }
}

/// Emit `<artifact>.root_module.addImport("pack__<prefix>", pack__<prefix>_mod)`
/// per pack, so the generated main.zig (and the tests root) reach pack
/// contents EXCLUSIVELY through the module — the only sanctioned path once
/// the pack's files stop being root-module members (#498 PR 2).
fn emitPackImports(
    w: anytype,
    artifact: []const u8,
    pack_modules: []const pack_root.PackModule,
) !void {
    for (pack_modules) |p| {
        try w.print("    {s}.root_module.addImport(\"pack__{s}\", pack__{s}_mod);\n", .{ artifact, p.prefix, p.prefix });
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
    /// Light packs promoted to per-pack build modules (assembler#498
    /// PR 2, "wire the wall"). One `pack__<prefix>_mod` createModule per
    /// entry (rooted at the generated `packs/<name>/__pack_root.zig`,
    /// restricted import table) + an `addImport` on every target
    /// artifact. Defaults to empty — pack-less projects keep their
    /// byte-identical build.zig, the invariant every #498 PR holds.
    pack_modules: []const pack_root.PackModule = &.{},
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

    // Per-pack modules (assembler#498 PR 2) — declared beside the promoted
    // script modules, before any target artifact that imports them.
    try emitPackModules(w, cfg, opts.pack_modules);

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
        try emitPackImports(w, "wasm", opts.pack_modules);

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
        try emitPackImports(w, "exe", opts.pack_modules);

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
        try emitPackImports(w, "lib", opts.pack_modules);

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
            try emitPackImports(w, "exe", opts.pack_modules);

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
        try emitPackImports(w, "test_root", opts.pack_modules);

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
