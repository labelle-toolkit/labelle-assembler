/// `build.zig` generator for the labelle-cli assembler.
///
/// Extracted from the former single-file `build_files.zig` (behavior-preserving
/// split, mirrors #539/#541). Emits the generated project's `build.zig` from the
/// embedded template + the resolved backend manifest-v2 data.
const std = @import("std");
const tpl = @import("../template.zig");
const config = @import("../config.zig");
const plugin_params = @import("../plugin_params.zig");
const plugin_build_steps = @import("../plugin_build_steps.zig");
const scripting_csharp = @import("../scripting_csharp.zig");
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
/// The desktop exe's Windows icon-resource wiring (labelle-cli#359), emitted
/// right after the exe declaration. Exact text — pinned by the goldens.
pub const windows_icon_resource_block =
    "    // Windows exe icon (labelle-cli#359): compile the assembler-written\n" ++
    "    // app_icon.rc (`1 ICON \"app_icon.ico\"`) into the binary so Explorer and\n" ++
    "    // the taskbar show the project's app_icon. Windows targets only.\n" ++
    "    if (target.result.os.tag == .windows) {\n" ++
    "        exe.root_module.addWin32ResourceFile(.{ .file = b.path(\"app_icon.rc\") });\n" ++
    "    }\n\n";

fn inProjectLibDir(plugin: config.PluginDep) ?[]const u8 {
    if (!std.mem.startsWith(u8, plugin.repo, "@")) return null;
    const path = plugin.localPath();
    if (!std.mem.startsWith(u8, path, "libs/")) return null;
    // The prefix test alone is nominal: `@libs/../../shared` normalizes to a
    // path OUTSIDE libs/, so a `.`/`..`/empty component (or a `\` smuggling
    // one on Windows) must not classify as in-project (PR #662 review). This
    // stays LEXICAL — it derives the literal `../../<path>` cwd the emitted
    // test step runs in, and shelling a lib's own `zig build test` mutates no
    // import table; the generated-data injection uses the resolver's CANONICAL
    // classification instead (`cache.isInProjectLib` → `lib_plugin_names`).
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return null;
        if (std.mem.indexOfScalar(u8, comp, '\\') != null) return null;
    }
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
    constants: bool,
    i18n: bool,
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
        if (constants) try w.writeAll("            .{ .name = \"constants\", .module = constants_mod },\n");
        if (i18n) try w.writeAll("            .{ .name = \"i18n\", .module = i18n_mod },\n");
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

/// Emit the `constants` module (RFC-CONSTANTS phase 1): a pure-data module
/// rooted at the generated `constants.zig`. No imports of its own -- it is
/// nested `pub const` declarations and nothing else -- which is why this is
/// one createModule and not a mirror of a script's import surface. Wired into
/// `game_mod` here; each artifact's root module picks it up via
/// `emitConstantsImport` after its creation.
fn emitConstantsModule(w: anytype, constants: bool) !void {
    if (!constants) return;
    try w.writeByte('\n');
    try w.writeAll("    // Game constants (RFC-CONSTANTS phase 1): generated from constants/*.yaml.\n");
    try w.writeAll("    const constants_mod = b.createModule(.{\n");
    try w.writeAll("        .root_source_file = b.path(\"constants.zig\"),\n");
    try w.writeAll("        .target = target,\n");
    try w.writeAll("        .optimize = optimize,\n");
    try w.writeAll("    });\n");
    try w.writeAll("    overrideImport(game_mod, \"constants\", constants_mod);\n");
}

fn emitConstantsImport(w: anytype, artifact: []const u8, constants: bool) !void {
    if (!constants) return;
    try w.print("    {s}.root_module.addImport(\"constants\", constants_mod);\n", .{artifact});
}

/// The i18n module (RFC-I18N phase 1), mirroring the constants wiring: a
/// self-contained generated module (it imports only std), overrideImport into
/// game_mod, addImport per artifact via emitI18nImport.
fn emitI18nModule(w: anytype, i18n: bool) !void {
    if (!i18n) return;
    try w.writeByte('\n');
    try w.writeAll("    // i18n (RFC-I18N phase 1): generated from locales/*.jsonc.\n");
    try w.writeAll("    const i18n_mod = b.createModule(.{\n");
    try w.writeAll("        .root_source_file = b.path(\"i18n.zig\"),\n");
    try w.writeAll("        .target = target,\n");
    try w.writeAll("        .optimize = optimize,\n");
    try w.writeAll("    });\n");
    try w.writeAll("    overrideImport(game_mod, \"i18n\", i18n_mod);\n");
}

fn emitI18nImport(w: anytype, artifact: []const u8, i18n: bool) !void {
    if (!i18n) return;
    try w.print("    {s}.root_module.addImport(\"i18n\", i18n_mod);\n", .{artifact});
}

/// Wire the generated data modules into every in-project `libs/` plugin
/// module (flying-platform#786 friction #1). A lib under `libs/` is
/// game-local code — RFC-CONSTANTS' headline example, `health_drain_rate`,
/// lives in one — so its `@import("constants")` must resolve exactly as a
/// game script's does. External and out-of-project `local:` plugin packages
/// are deliberately NOT wired: a package meant to build standalone and serve
/// many games cannot depend on one game's generated data, and the
/// overrideImport would silently REPLACE a `constants`/`i18n` module such a
/// package declares for itself.
///
/// `lib_plugin_names` carries the RESOLVER's canonical classification
/// (`cache.isInProjectLib`, PR #662 reviews): each name's `@libs/...` path
/// realpath-resolves inside the project's own `libs/` dir, so a `libs/foo`
/// that is really a symlink/junction to an external package never lands
/// here — the lexical spelling is not re-derived at emission.
///
/// Must be called AFTER `emitConstantsModule`/`emitI18nModule` put
/// `constants_mod`/`i18n_mod` in scope. Emits nothing when the project has
/// no constants/i18n or no in-project libs — byte-identical build.zig, the
/// invariant every optional feature holds.
fn emitLibPluginDataImports(w: anytype, lib_plugin_names: []const []const u8, constants: bool, i18n: bool) !void {
    if (!constants and !i18n) return;
    for (lib_plugin_names, 0..) |name, i| {
        if (i == 0) {
            try w.writeAll("    // In-project libs read the game's constants/strings too (the libs/\n");
            try w.writeAll("    // gap, flying-platform#786): resolve their generated-data imports.\n");
        }
        if (constants) try w.print("    overrideImport(plugin_{s}_mod, \"constants\", constants_mod);\n", .{name});
        if (i18n) try w.print("    overrideImport(plugin_{s}_mod, \"i18n\", i18n_mod);\n", .{name});
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
    constants: bool,
    i18n: bool,
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
        // Generated data modules: a pack's own scripts are the likeliest
        // readers of its own constants/strings (which is why the usage
        // scanner covers pack sources), and this isolated table is the only
        // way `@import("constants")` resolves for them.
        if (constants) try w.writeAll("            .{ .name = \"constants\", .module = constants_mod },\n");
        if (i18n) try w.writeAll("            .{ .name = \"i18n\", .module = i18n_mod },\n");
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

/// A declared plugin that ships a native build hook (`plugin.hook.zig`,
/// labelle-assembler#518). Discovered + staged by `plugin_build_hook.zig`; here
/// it only carries the plugin name, which MUST match a `cfg.plugins` entry so
/// the `plugin_<name>_mod` / `plugin_<name>_dep` variables are already in scope
/// when the hook CALL is emitted.
pub const PluginHook = struct {
    plugin_name: []const u8,
};

/// Emit the native build-hook CALL for every plugin that ships a
/// `plugin.hook.zig` (labelle-assembler#518), mirroring the backend
/// `backend.hook.zig` `post_wire` mechanism. The assembler stages each hook
/// next to the generated build.zig as `plugin_<name>_build_hook.zig` (see
/// `plugin_build_hook.stage`), so the `@import` here resolves at build time.
///
/// Runs AFTER `artifact` (`exe`/`wasm`/`lib`) and its imports are assembled, so
/// the hook can `addCSourceFiles` / `linkLibCpp` / `addIncludePath` onto
/// `ctx.artifact` (or contribute to `ctx.module`). The context struct also
/// carries `.plugin_dep` (the plugin's `b.dependency` result) so the hook can
/// reach files/modules shipped by the plugin package, plus `.target` /
/// `.optimize` for any native sub-artifact it builds.
///
/// A project whose plugins ship no hook passes an empty `plugin_hooks` and
/// emits nothing here — the generated build.zig stays byte-identical.
fn emitPluginBuildHooks(
    w: anytype,
    artifact: []const u8,
    plugin_hooks: []const PluginHook,
) !void {
    for (plugin_hooks) |h| {
        try w.print("    const plugin_{s}_build_hook = @import(\"plugin_{s}_build_hook.zig\");\n", .{ h.plugin_name, h.plugin_name });
        try w.print("    plugin_{s}_build_hook.postWire(b, .{{\n", .{h.plugin_name});
        try w.print("        .artifact = {s},\n", .{artifact});
        try w.print("        .module = plugin_{s}_mod,\n", .{h.plugin_name});
        try w.print("        .plugin_dep = plugin_{s}_dep,\n", .{h.plugin_name});
        try w.writeAll("        .target = target,\n");
        try w.writeAll("        .optimize = optimize,\n");
        try w.writeAll("    });\n");
    }
}

/// A declared plugin whose `plugin.labelle` carries a `.build` block
/// (labelle-assembler#586). Loaded + validated + placeholder-root-resolved by
/// root.zig (via `plugin_build_steps.loadFromDir`); here it drives
/// `emitPluginBuildSteps` — the b.addSystemCommand + addObjectFile wiring in
/// the generated build.zig. See `src/plugin_build_steps.zig` for the schema,
/// placeholder language, and safety posture.
pub const PluginBuildStepsWiring = struct {
    /// Matches a `cfg.plugins` entry name (already identifier-safe — the
    /// same guarantee `plugin_<name>_mod` emission relies on).
    plugin_name: []const u8,
    /// ABSOLUTE staged package dir — the `{package}` placeholder value and
    /// the base every step cwd resolves under. Generate-time resolved
    /// (deps copy, cache fallback), so the emitted command never depends
    /// on the invoker's cwd.
    package_abs: []const u8,
    /// Build-root-RELATIVE persistent work dir — the `{cache}` placeholder
    /// (`plugin-build/<name>`), resolved at build time via `b.pathFromRoot`
    /// so the generated tree stays relocatable on that axis.
    cache_rel: []const u8,
    /// The steps to EMIT — root.zig already applied the generate-time
    /// `.os` filter (`stepAllowsOs`), so slice order here IS the emitted
    /// chain order.
    steps: []const plugin_build_steps.Step,
    /// Library SEARCH paths for the game's final link, RESOLVED at
    /// generate time by root.zig from the emitted steps' `.library_paths`
    /// (`{crystal_env:VAR}` expanded via `crystal env`, deduped, declared
    /// order). Each becomes one `addLibraryPath` on the artifact's root
    /// module. Empty for every pre-crystal plugin — byte-identity holds.
    library_paths: []const []const u8 = &.{},
    /// The steps publish RUNTIME-LOADED outputs into `{cache}` — the C#
    /// CoreCLR-host contract (labelle-assembler#617): the link-less
    /// `dotnet publish` step's output dir IS the runtime payload (the
    /// managed assembly + its runtimeconfig/deps.json), so the emission
    /// additionally stages it where the plugin's hostfxr vm resolves the
    /// assembly — an InstallDir step copying `{cache}` beside the
    /// installed exe (`emitPluginBuildSteps`), plus the `run` step's
    /// `LABELLE_CS_ASSEMBLY_DIR` env pointing at `{cache}` (the desktop
    /// footer — `zig build run` executes the CACHED binary, which has no
    /// assembly beside it). Decided by root.zig via
    /// `scripting_csharp.stagesRuntimeOutputs`; default false keeps every
    /// other project's build.zig byte-identical.
    stage_runtime_outputs: bool = false,
};

/// Emit one declared argv element as generated build.zig source.
///
/// `{package}` is substituted NOW (a generate-time absolute literal);
/// `{cache}` / `{target}` / `{staticlib:NAME}` become `{s}` slots of a
/// `b.fmt(...)` resolved at build time against the per-plugin
/// `plugin_<name>_build_cache` const / the shared
/// `plugin_build_target_triple` const / the shared
/// `plugin_build_lib_prefix` + `plugin_build_lib_ext` pair (a staticlib
/// token expands to `{s}NAME{s}` — `libNAME.a` everywhere but Windows's
/// `NAME.lib`). An arg that IS exactly one build-time placeholder
/// references the const directly (no b.fmt). All literal content is
/// escaped for the Zig string literal; when the b.fmt layer wraps the
/// arg, literal braces (only reachable via a substituted package path —
/// declared args cannot carry stray braces, validated at load) are
/// doubled so the format string stays well-formed.
fn emitBuildStepArg(
    allocator: std.mem.Allocator,
    w: anytype,
    entry: PluginBuildStepsWiring,
    arg: []const u8,
) !void {
    const has_slots =
        plugin_build_steps.containsPlaceholder(arg, plugin_build_steps.PLACEHOLDER_CACHE) or
        plugin_build_steps.containsPlaceholder(arg, plugin_build_steps.PLACEHOLDER_TARGET) or
        plugin_build_steps.containsPlaceholder(arg, plugin_build_steps.PLACEHOLDER_CRYSTAL_TARGET) or
        plugin_build_steps.containsStaticlibPlaceholder(arg);

    var fmt_body: std.ArrayList(u8) = .empty;
    defer fmt_body.deinit(allocator);
    var refs: std.ArrayList([]const u8) = .empty;
    defer {
        for (refs.items) |r| allocator.free(r);
        refs.deinit(allocator);
    }

    var i: usize = 0;
    while (i < arg.len) {
        if (plugin_build_steps.placeholderAt(arg, i)) |ph| {
            if (std.mem.eql(u8, ph, plugin_build_steps.PLACEHOLDER_PACKAGE)) {
                for (entry.package_abs) |ch| {
                    try fmt_body.append(allocator, ch);
                    // Double braces ONLY under a b.fmt wrap — a plain string
                    // literal must carry them verbatim.
                    if (has_slots and (ch == '{' or ch == '}')) try fmt_body.append(allocator, ch);
                }
            } else if (std.mem.eql(u8, ph, plugin_build_steps.PLACEHOLDER_CACHE)) {
                try fmt_body.appendSlice(allocator, "{s}");
                try refs.append(allocator, try std.fmt.allocPrint(allocator, "plugin_{s}_build_cache", .{entry.plugin_name}));
            } else if (std.mem.eql(u8, ph, plugin_build_steps.PLACEHOLDER_TARGET)) {
                try fmt_body.appendSlice(allocator, "{s}");
                try refs.append(allocator, try allocator.dupe(u8, "plugin_build_target_triple"));
            } else if (std.mem.eql(u8, ph, plugin_build_steps.PLACEHOLDER_CRYSTAL_TARGET)) {
                try fmt_body.appendSlice(allocator, "{s}");
                const ct_ref = try allocator.dupe(u8, "plugin_build_crystal_target");
                errdefer allocator.free(ct_ref);
                try refs.append(allocator, ct_ref);
            } else {
                // {staticlib:NAME} → "{s}NAME{s}" over the shared lib
                // prefix/ext consts. NAME's charset ([A-Za-z0-9_-],
                // load-validated) can't carry braces/quotes, so it splices
                // into the format string verbatim.
                try fmt_body.appendSlice(allocator, "{s}");
                const prefix_ref = try allocator.dupe(u8, "plugin_build_lib_prefix");
                errdefer allocator.free(prefix_ref);
                try refs.append(allocator, prefix_ref);
                try fmt_body.appendSlice(allocator, plugin_build_steps.staticlibName(ph));
                try fmt_body.appendSlice(allocator, "{s}");
                const ext_ref = try allocator.dupe(u8, "plugin_build_lib_ext");
                errdefer allocator.free(ext_ref);
                try refs.append(allocator, ext_ref);
            }
            i += ph.len;
        } else {
            try fmt_body.append(allocator, arg[i]);
            i += 1;
        }
    }

    if (!has_slots) {
        try w.print("\"{f}\"", .{std.zig.fmtString(fmt_body.items)});
    } else if (refs.items.len == 1 and std.mem.eql(u8, fmt_body.items, "{s}")) {
        try w.writeAll(refs.items[0]);
    } else {
        try w.print("b.fmt(\"{f}\", .{{ ", .{std.zig.fmtString(fmt_body.items)});
        for (refs.items, 0..) |r, ri| {
            if (ri > 0) try w.writeAll(", ");
            try w.writeAll(r);
        }
        try w.writeAll(" })");
    }
}

/// Emit the declarative plugin build steps (labelle-assembler#586): per step
/// a `b.addSystemCommand` run step (cwd inside the staged package, declared
/// argv — no shell), chained in DECLARED ORDER within a plugin; per linked
/// artifact an `addObjectFile` on the game artifact's root module plus the
/// step dependency that orders the command before the link. `.static_lib`
/// and `.object` both wire through `addObjectFile` (zig's build API treats
/// `.a`/`.o` uniformly there — the mode is declarative intent, see
/// `plugin_build_steps.LinkMode`).
///
/// Runs AFTER `artifact` (`exe`/`wasm`/`lib`) is assembled, mirroring
/// `emitPluginBuildHooks`. Steps run on every `zig build` (a Run step with
/// no declared outputs always executes); staleness is the TOOL's job —
/// cargo / zig build-lib are internally incremental, so an unchanged input
/// re-runs in tool-cache time. Wired into the MAIN artifact only (not
/// `test_root`): game tests that extern-call plugin native symbols are a
/// documented follow-up, and unreferenced externs don't link-fail.
///
/// A project whose plugins declare no `.build` passes an empty slice and
/// emits nothing — the generated build.zig stays byte-identical (#586's
/// additive invariant).
fn emitPluginBuildSteps(
    allocator: std.mem.Allocator,
    w: anytype,
    artifact: []const u8,
    entries: []const PluginBuildStepsWiring,
) !void {
    if (entries.len == 0) return;

    // The shared consts: emitted ONCE (a per-plugin decl would collide),
    // and only when some arg/artifact uses the placeholder — an unused
    // local const is a compile error in the generated build.zig.
    var wants_triple = false;
    var wants_staticlib = false;
    var wants_crystal_target = false;
    for (entries) |e| {
        for (e.steps) |s| {
            for (s.command) |arg| {
                if (plugin_build_steps.containsPlaceholder(arg, plugin_build_steps.PLACEHOLDER_TARGET)) wants_triple = true;
                if (plugin_build_steps.containsPlaceholder(arg, plugin_build_steps.PLACEHOLDER_CRYSTAL_TARGET)) wants_crystal_target = true;
                if (plugin_build_steps.containsStaticlibPlaceholder(arg)) wants_staticlib = true;
            }
            if (s.artifact) |a| {
                if (plugin_build_steps.containsStaticlibPlaceholder(a)) wants_staticlib = true;
            }
        }
    }

    try w.writeAll("\n    // Plugin build steps (labelle-assembler#586): declared argv from each\n");
    try w.writeAll("    // plugin's plugin.labelle `.build` block; produced artifacts link onto\n");
    try w.writeAll("    // the game artifact. Declared order = execution order within a plugin.\n");
    if (wants_triple) {
        try w.writeAll("    const plugin_build_target_triple = target.result.zigTriple(b.allocator) catch @panic(\"OOM\");\n");
    }
    if (wants_crystal_target) {
        // The labelle-scripting `crystalTriple` mapping, verbatim: crystal's
        // `--target` names are not zig triples, and only the desktop
        // macos/linux × aarch64/x86_64 cells exist. The @panic arms are
        // unreachable for supported projects (the generate-time `.os` +
        // platform gates rejected everything else already) — they fire only
        // when the GENERATED project is hand-crossed via `-Dtarget=`, with
        // a message naming the constraint.
        try w.writeAll("    // {crystal_target}: crystal's --target triple for the resolved zig target.\n");
        try w.writeAll("    const plugin_build_crystal_target: []const u8 = switch (target.result.os.tag) {\n");
        try w.writeAll("        .macos => switch (target.result.cpu.arch) {\n");
        try w.writeAll("            .aarch64 => \"aarch64-apple-darwin\",\n");
        try w.writeAll("            .x86_64 => \"x86_64-apple-darwin\",\n");
        try w.writeAll("            else => @panic(\"crystal scripts: unsupported cpu arch (aarch64/x86_64 only)\"),\n");
        try w.writeAll("        },\n");
        try w.writeAll("        .linux => switch (target.result.cpu.arch) {\n");
        try w.writeAll("            .aarch64 => \"aarch64-linux-gnu\",\n");
        try w.writeAll("            .x86_64 => \"x86_64-linux-gnu\",\n");
        try w.writeAll("            else => @panic(\"crystal scripts: unsupported cpu arch (aarch64/x86_64 only)\"),\n");
        try w.writeAll("        },\n");
        try w.writeAll("        else => @panic(\"crystal scripts: unsupported target OS (macos/linux only)\"),\n");
        try w.writeAll("    };\n");
    }
    if (wants_staticlib) {
        // {staticlib:NAME}: cargo-style toolchains emit `NAME.lib` on
        // Windows and `libNAME.a` everywhere else — resolved at build
        // time so one declared path finds the artifact on every OS.
        try w.writeAll("    const plugin_build_lib_prefix: []const u8 = if (target.result.os.tag == .windows) \"\" else \"lib\";\n");
        try w.writeAll("    const plugin_build_lib_ext: []const u8 = if (target.result.os.tag == .windows) \".lib\" else \".a\";\n");
    }

    for (entries) |e| {
        // The {cache} const: per plugin, only when an arg references it
        // (artifact paths use b.path directly and never need the const) —
        // or when the runtime-output staging references it (#617: the
        // InstallDir source + the run step's env var below).
        var wants_cache = e.stage_runtime_outputs;
        for (e.steps) |s| {
            for (s.command) |arg| {
                if (plugin_build_steps.containsPlaceholder(arg, plugin_build_steps.PLACEHOLDER_CACHE)) wants_cache = true;
            }
        }
        if (wants_cache) {
            try w.print("    const plugin_{s}_build_cache = b.pathFromRoot(\"{f}\");\n", .{ e.plugin_name, std.zig.fmtString(e.cache_rel) });
        }

        for (e.steps, 0..) |s, i| {
            try w.print("    // .build step '{s}' of plugin '{s}'\n", .{ s.name, e.plugin_name });
            try w.print("    const plugin_{s}_build_step_{d} = b.addSystemCommand(&.{{ ", .{ e.plugin_name, i });
            for (s.command, 0..) |arg, ai| {
                if (ai > 0) try w.writeAll(", ");
                try emitBuildStepArg(allocator, w, e, arg);
            }
            try w.writeAll(" });\n");
            if (s.cwd) |c| {
                try w.print("    plugin_{s}_build_step_{d}.setCwd(.{{ .cwd_relative = \"{f}/{f}\" }});\n", .{ e.plugin_name, i, std.zig.fmtString(e.package_abs), std.zig.fmtString(c) });
            } else {
                try w.print("    plugin_{s}_build_step_{d}.setCwd(.{{ .cwd_relative = \"{f}\" }});\n", .{ e.plugin_name, i, std.zig.fmtString(e.package_abs) });
            }
            if (i > 0) {
                try w.print("    plugin_{s}_build_step_{d}.step.dependOn(&plugin_{s}_build_step_{d}.step);\n", .{ e.plugin_name, i, e.plugin_name, i - 1 });
            }
            if (s.link != .none) {
                const a = s.artifact.?; // load-time validation guarantees presence + root
                const has_lib_slot = plugin_build_steps.containsStaticlibPlaceholder(a);
                if (std.mem.startsWith(u8, a, plugin_build_steps.PLACEHOLDER_CACHE ++ "/")) {
                    const rest = a[plugin_build_steps.PLACEHOLDER_CACHE.len + 1 ..];
                    if (has_lib_slot) {
                        // {staticlib:NAME} in the tail → a build-time
                        // b.fmt path. The {cache} root becomes the
                        // LITERAL cache_rel here (b.path wants a
                        // build-root-relative path, not the absolute
                        // pathFromRoot const) — cache_rel is
                        // `plugin-build/<name>` with an identifier-safe
                        // name, so splicing it into the arg emitter's
                        // input never introduces stray braces.
                        const arg_text = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ e.cache_rel, rest });
                        defer allocator.free(arg_text);
                        try w.print("    const plugin_{s}_build_artifact_{d} = b.path(", .{ e.plugin_name, i });
                        try emitBuildStepArg(allocator, w, e, arg_text);
                        try w.writeAll(");\n");
                    } else {
                        try w.print("    const plugin_{s}_build_artifact_{d} = b.path(\"{f}/{f}\");\n", .{ e.plugin_name, i, std.zig.fmtString(e.cache_rel), std.zig.fmtString(rest) });
                    }
                } else {
                    const rest = a[plugin_build_steps.PLACEHOLDER_PACKAGE.len + 1 ..];
                    if (has_lib_slot) {
                        // Package-rooted twin: re-feed the declared
                        // `{package}/<tail>` through the arg emitter so
                        // the absolute package path keeps its
                        // brace-doubling under the b.fmt wrap.
                        try w.print("    const plugin_{s}_build_artifact_{d}: std.Build.LazyPath = .{{ .cwd_relative = ", .{ e.plugin_name, i });
                        try emitBuildStepArg(allocator, w, e, a);
                        try w.writeAll(" };\n");
                    } else {
                        try w.print("    const plugin_{s}_build_artifact_{d}: std.Build.LazyPath = .{{ .cwd_relative = \"{f}/{f}\" }};\n", .{ e.plugin_name, i, std.zig.fmtString(e.package_abs), std.zig.fmtString(rest) });
                    }
                }
                try w.print("    {s}.root_module.addObjectFile(plugin_{s}_build_artifact_{d});\n", .{ artifact, e.plugin_name, i });
                if (!s.system_libs.isEmpty()) {
                    // Per-OS system libs (declared `.system_libs`): the
                    // linked artifact's final-link dependencies — e.g. a
                    // rust panic=unwind staticlib needs gcc_s/pthread/…
                    // on Linux, none of which exist on macOS. One switch
                    // per step; the resolved target picks its arm.
                    try w.print("    // Final-link system libs for step '{s}' of plugin '{s}' (per target OS).\n", .{ s.name, e.plugin_name });
                    try w.writeAll("    switch (target.result.os.tag) {\n");
                    inline for (@typeInfo(plugin_build_steps.SystemLibs).@"struct".fields) |f| {
                        const libs = @field(s.system_libs, f.name);
                        if (libs.len > 0) {
                            try w.print("        .{s} => {{\n", .{f.name});
                            for (libs) |lib| {
                                try w.print("            {s}.root_module.linkSystemLibrary(\"{f}\", .{{}});\n", .{ artifact, std.zig.fmtString(lib) });
                            }
                            try w.writeAll("        },\n");
                        }
                    }
                    try w.writeAll("        else => {},\n");
                    try w.writeAll("    }\n");
                }
            }
        }
        // Library search paths (declared `.library_paths`, generate-time
        // resolved — crystal's runtime libs live wherever `crystal env
        // CRYSTAL_LIBRARY_PATH` says): one addLibraryPath per entry, on
        // the game artifact's module like the system libs above.
        if (e.library_paths.len > 0) {
            try w.print("    // Library search paths for plugin '{s}' (.library_paths, resolved at generate).\n", .{e.plugin_name});
            for (e.library_paths) |lp| {
                try w.print("    {s}.root_module.addLibraryPath(.{{ .cwd_relative = \"{f}\" }});\n", .{ artifact, std.zig.fmtString(lp) });
            }
        }
        // The game artifact waits for the plugin's LAST step; the chain
        // orders everything before it.
        try w.print("    {s}.step.dependOn(&plugin_{s}_build_step_{d}.step);\n", .{ artifact, e.plugin_name, e.steps.len - 1 });

        // Runtime outputs beside the binary (labelle-assembler#617): the
        // link-less steps publish runtime-LOADED artifacts (the C# managed
        // assembly + its runtimeconfig/deps.json) into `{cache}` — install
        // that dir's contents next to the exe so the plugin's hostfxr host
        // resolves the assembly beside the shipped binary, and `zig build`
        // alone yields a complete, deployable game dir. Desktop-exe only:
        // the csharp steps are desktop-allowlisted, and only the exe target
        // installs a runnable binary.
        if (e.stage_runtime_outputs and std.mem.eql(u8, artifact, "exe")) {
            try w.print("    // Runtime outputs of plugin '{s}' (labelle-assembler#617): stage the\n", .{e.plugin_name});
            try w.writeAll("    // published managed assembly (+ runtimeconfig/deps.json) beside the exe.\n");
            try w.print("    const plugin_{s}_runtime_outputs = b.addInstallDirectory(.{{\n", .{e.plugin_name});
            try w.print("        .source_dir = .{{ .cwd_relative = plugin_{s}_build_cache }},\n", .{e.plugin_name});
            try w.writeAll("        .install_dir = .bin,\n");
            try w.writeAll("        .install_subdir = \"\",\n");
            try w.writeAll("    });\n");
            try w.print("    plugin_{s}_runtime_outputs.step.dependOn(&plugin_{s}_build_step_{d}.step);\n", .{ e.plugin_name, e.plugin_name, e.steps.len - 1 });
            try w.print("    b.getInstallStep().dependOn(&plugin_{s}_runtime_outputs.step);\n", .{e.plugin_name});
        }
    }
}

/// The (single) wiring entry whose steps publish runtime-loaded outputs
/// (labelle-assembler#617), if any — drives the desktop footer's
/// `run_cmd` env injection. One scripting plugin per project is already
/// policy-enforced (#584), so first-match is exhaustive.
fn runtimeOutputsEntry(entries: []const PluginBuildStepsWiring) ?PluginBuildStepsWiring {
    for (entries) |e| {
        if (e.stage_runtime_outputs) return e;
    }
    return null;
}

pub const BuildZigOptions = struct {
    /// Emit a test-only build.zig: skip the exe step, the run step,
    /// and the backend artifact link. Used by `generateTestsTarget`
    /// in root.zig for `.labelle/tests/build.zig` (issue #83).
    is_tests_target: bool = false,
    /// Game constants (RFC-CONSTANTS phase 1, labelle-engine#811): when
    /// true, the phase emitted `constants.zig` into the target dir and every
    /// artifact gains a `constants` module so game code reaches
    /// `@import("constants").C.<domain>.<name>`. Defaults to false -- a
    /// project with no `constants/` directory keeps a byte-identical
    /// build.zig, the invariant every optional feature holds.
    constants: bool = false,
    /// i18n (RFC-I18N phase 1): when true, the phase emitted i18n.zig and
    /// every artifact gains an `i18n` module -- `@import("i18n").t(K.menu.play)`.
    /// Defaults to false: locale-less projects keep a byte-identical build.zig.
    i18n: bool = false,
    /// Plugins classified by the RESOLVER as in-project `libs/` libraries
    /// (`cache.isInProjectLib` -- canonical realpath containment under the
    /// project's `libs/`, so symlink/junction escapes stay external; PR #662
    /// reviews). Each name matches a `cfg.plugins` entry and gets the
    /// generated `constants`/`i18n` modules overrideImport-ed into its
    /// module. Defaults to empty -- projects without in-project libs (or
    /// without constants/i18n, which is when root.zig even computes this)
    /// keep a byte-identical build.zig.
    lib_plugin_names: []const []const u8 = &.{},
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
    /// Plugins that ship a native build hook (`plugin.hook.zig`,
    /// labelle-assembler#518). Each entry emits an `@import` of the staged
    /// `plugin_<name>_build_hook.zig` + a `postWire(b, .{ … })` CALL after the
    /// game artifact is assembled, letting the plugin contribute native
    /// (C/C++) sources / link steps / include paths — mirroring the backend
    /// `backend.hook.zig` mechanism. Defaults to empty: a project whose
    /// plugins ship no hook keeps a byte-identical build.zig.
    plugin_hooks: []const PluginHook = &.{},
    /// Declarative plugin build steps (labelle-assembler#586): each entry
    /// emits `b.addSystemCommand` run steps + artifact `addObjectFile` link
    /// wiring after the game artifact is assembled (`emitPluginBuildSteps`).
    /// Loaded/validated/resolved by root.zig from each plugin.labelle's
    /// `.build` block. Defaults to empty — a project whose plugins declare
    /// no `.build` keeps a byte-identical build.zig.
    plugin_build_steps: []const PluginBuildStepsWiring = &.{},
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
    /// Scripting plugin build wiring (labelle-assembler#593). When set, the
    /// `.plugins` entry whose name matches `plugin_name` gets
    /// `.language = .<language>` appended to its `b.dependency` args, driving
    /// labelle-scripting's `-Dlanguage` build option (which language
    /// sub-module + vendored VM the plugin embeds). `language` comes from the
    /// validated `.params.language` — a frozen built-in OR a manifest
    /// `.languages` row (#619), always `isLanguageIdentifier`-shaped so it is
    /// a valid enum-literal spelling. Defaults to null —
    /// splice-less projects keep a byte-identical build.zig.
    scripting: ?ScriptingDep = null,
    /// Schema-declared plugin params (labelle-assembler#591): one entry per
    /// plugin that resolved a non-empty schema. Each emits — inside the
    /// shared plugin-injection block, so every platform and the tests target
    /// get it — a `plugin_<name>_params_mod` createModule rooted at the
    /// staged `plugin_<name>_params.zig` (see `plugin_params.stage`) plus
    /// the `overrideImport(plugin_<name>_mod, "plugin_params", …)` that lets
    /// the plugin read `@import("plugin_params")` comptime. Defaults to
    /// empty — params-less projects keep a byte-identical build.zig.
    plugin_params: []const plugin_params.ResolvedPluginParams = &.{},

    pub const ScriptingDep = struct {
        plugin_name: []const u8,
        language: []const u8,
        /// Dev-mode hot reload (labelle-assembler#637): when true, the
        /// scripting plugin's dep args also gain
        /// `.hot_reload = optimize == .Debug` — Debug builds compile the
        /// plugin's disk watcher + tick pump in (`labelle run`'s default),
        /// release builds keep the option at its off default, so nothing
        /// ships. Set from `scripting_splice.buildDepHotReload` (embed
        /// family + capability probe + never-tests-target + desktop);
        /// MUST stay false for a plugin predating the option — an unknown
        /// dependency option is a hard `zig build` error. Default false
        /// keeps every existing caller byte-identical.
        hot_reload: bool = false,
    };
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
        if (cfg.plugins.len > 0 or cfg.ecs != .mock or cfg.hasGui() or opts.promoted_scripts.len > 0 or
            opts.constants or opts.i18n or opts.pack_modules.len > 0)
        {
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
        if (cfg.plugins.len > 0 or cfg.ecs != .mock or cfg.hasGui() or opts.promoted_scripts.len > 0 or
            opts.constants or opts.i18n or opts.pack_modules.len > 0)
        {
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
        // Scripting plugin (labelle-assembler#593): thread the project's
        // declared script language into the plugin's `-Dlanguage` build
        // option, selecting which language sub-module (and vendored VM) the
        // plugin embeds. Empty for every other plugin — and for every
        // project without the splice — so existing dep args stay
        // byte-identical. The language is emitted as an ENUM LITERAL
        // (`.language = .<name>`), so `language_policy.isLanguageIdentifier`
        // gates every declared language (frozen built-in OR manifest
        // `.languages` row — #619) to a bare `[a-z][a-z0-9_]*` identifier
        // that both spells a valid enum literal and cannot overflow the
        // fixed buffer. Dev-mode hot reload (#637): a
        // capable splice additionally passes `.hot_reload = optimize ==
        // .Debug` — the plugin's watcher/pump compile into Debug builds
        // (`labelle run`'s default) and stay at the off default for release;
        // see `ScriptingDep.hot_reload` for the gate set.
        var scripting_lang_buf: [96]u8 = undefined;
        const scripting_lang_arg: []const u8 = blk: {
            const s = opts.scripting orelse break :blk "";
            if (!std.mem.eql(u8, s.plugin_name, plugin.name)) break :blk "";
            const hot: []const u8 = if (s.hot_reload) ", .hot_reload = optimize == .Debug" else "";
            break :blk std.fmt.bufPrint(&scripting_lang_buf, ", .language = .{s}{s}", .{ s.language, hot }) catch unreachable;
        };
        if (cfg.platform == .ios) {
            // Pass iOS SDK path to plugins so C dependencies can find system headers
            try w.print("    const plugin_{s}_dep = b.dependency(\"labelle_{s}\", .{{ .target = target, .optimize = optimize{s}, .ios_sdk_path = @as(?[]const u8, sdk_path) }});\n", .{ plugin.name, plugin.name, scripting_lang_arg });
        } else {
            try w.print("    const plugin_{s}_dep = b.dependency(\"labelle_{s}\", .{{ .target = target, .optimize = optimize{s} }});\n", .{ plugin.name, plugin.name, scripting_lang_arg });
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

            // Schema-declared params (#591): a plugin that resolved params
            // gets the staged `plugin_<name>_params.zig` as its OWN module,
            // injected under the FIXED `plugin_params` import name (the
            // packs' `@import("pack")` self-name convention) — so the
            // plugin's code reads `@import("plugin_params")` comptime.
            // Emitted LAST in the plugin's wiring so it wins any name
            // shadowing (a sibling literally named `plugin_params` is
            // already rejected at resolve time). Params-less plugins emit
            // nothing — byte-identical build.zig.
            for (opts.plugin_params) |pp| {
                if (!std.mem.eql(u8, pp.plugin_name, plugin.name)) continue;
                try w.print("    const plugin_{s}_params_mod = b.createModule(.{{\n", .{plugin.name});
                try w.print("        .root_source_file = b.path(\"plugin_{s}_params.zig\"),\n", .{plugin.name});
                try w.writeAll("        .target = target,\n");
                try w.writeAll("        .optimize = optimize,\n");
                try w.writeAll("    });\n");
                try w.print("    overrideImport(plugin_{s}_mod, \"{s}\", plugin_{s}_params_mod);\n", .{ plugin.name, plugin_params.IMPORT_NAME, plugin.name });
            }
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
    // Generated data modules FIRST: promoted-script and pack modules import
    // them, so `constants_mod` / `i18n_mod` must already be in scope. A
    // FlowNodes-bearing script or a pack script reading its own constants
    // compiles under its own module, whose import table does not inherit
    // game_mod's -- without these entries, valid `@import("constants")` in
    // exactly the sources the usage scanner covers failed to resolve.
    try emitConstantsModule(w, opts.constants);
    try emitI18nModule(w, opts.i18n);
    // In-project lib plugin modules pick the data modules up here — after
    // the decls above, before any artifact builds the plugins (#786 friction 1).
    try emitLibPluginDataImports(w, opts.lib_plugin_names, opts.constants, opts.i18n);
    try emitPromotedScriptModules(w, cfg, opts.promoted_scripts, opts.constants, opts.i18n);

    // Per-pack modules (assembler#498 PR 2) — declared beside the promoted
    // script modules, before any target artifact that imports them.
    try emitPackModules(w, cfg, opts.pack_modules, opts.constants, opts.i18n);

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
        try emitConstantsImport(w, "wasm", opts.constants);
        try emitI18nImport(w, "wasm", opts.i18n);
        try emitPackImports(w, "wasm", opts.pack_modules);

        // Plugin native build hooks (#518).
        try emitPluginBuildHooks(w, "wasm", opts.plugin_hooks);

        // Declarative plugin build steps (#586).
        try emitPluginBuildSteps(allocator, w, "wasm", opts.plugin_build_steps);

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
        try emitConstantsImport(w, "exe", opts.constants);
        try emitI18nImport(w, "exe", opts.i18n);
        try emitPackImports(w, "exe", opts.pack_modules);

        // Plugin native build hooks (#518).
        try emitPluginBuildHooks(w, "exe", opts.plugin_hooks);

        // Declarative plugin build steps (#586).
        try emitPluginBuildSteps(allocator, w, "exe", opts.plugin_build_steps);

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
        try emitConstantsImport(w, "lib", opts.constants);
        try emitI18nImport(w, "lib", opts.i18n);
        try emitPackImports(w, "lib", opts.pack_modules);

        // Plugin native build hooks (#518).
        try emitPluginBuildHooks(w, "lib", opts.plugin_hooks);

        // Declarative plugin build steps (#586).
        try emitPluginBuildSteps(allocator, w, "lib", opts.plugin_build_steps);

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

            // Windows exe icon (labelle-cli#359): `app_icon.rc` + `app_icon.ico`
            // are written beside this file by `app_icon.writeDesktopIconArtifacts`
            // on every desktop generate. Gated at BUILD time on the resolved
            // target (not here on the host): the generated build.zig serves
            // `-Dtarget=x86_64-windows` cross-builds too, and Zig's built-in
            // resource compiler handles the .rc from any host.
            try w.writeAll(windows_icon_resource_block);

            // Wire each promoted game-script module into the exe's root
            // module so main.zig's `AllScripts` + `PluginFlowNodes` can
            // `@import("<named>")` (labelle-assembler#240 Gap 2).
            try emitPromotedScriptImports(w, "exe", opts.promoted_scripts);
            try emitConstantsImport(w, "exe", opts.constants);
            try emitI18nImport(w, "exe", opts.i18n);
            try emitPackImports(w, "exe", opts.pack_modules);

            // Plugin native build hooks (#518): let a plugin contribute C/C++
            // sources / link steps / include paths to the exe.
            try emitPluginBuildHooks(w, "exe", opts.plugin_hooks);

            // Declarative plugin build steps (#586): run each plugin's declared
            // commands and link the produced staticlib/object into the exe.
            try emitPluginBuildSteps(allocator, w, "exe", opts.plugin_build_steps);

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
        try emitConstantsImport(w, "test_root", opts.constants);
        try emitI18nImport(w, "test_root", opts.i18n);
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
        // that wires `b.installArtifact(exe)` and the `run` step — split
        // into install-run/close halves (byte-identical concatenation)
        // so a runtime-outputs plugin (#617, the C# managed assembly) can
        // point the run step's env at the publish dir: `zig build run`
        // executes the CACHED binary, which has no assembly beside it,
        // so the hostfxr host resolves it via its documented override.
        if (opts.is_tests_target) {
            try tpl.writeSection(build_zig_tmpl, "tests_only_footer", w);
        } else {
            try tpl.writeSection(build_zig_tmpl, "footer_install_run", w);
            if (runtimeOutputsEntry(opts.plugin_build_steps)) |e| {
                try w.print("    // The run step executes the cached (uninstalled) binary — point the\n" ++
                    "    // CoreCLR host's documented override at the publish dir (#617).\n" ++
                    "    run_cmd.setEnvironmentVariable(\"{s}\", plugin_{s}_build_cache);\n", .{ scripting_csharp.RUNTIME_ASSEMBLY_DIR_ENV, e.plugin_name });
            }
            try tpl.writeSection(build_zig_tmpl, "footer_close", w);
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
// Tests
// ============================================================

const testing = std.testing;

test "emitPluginBuildHooks: emits the postWire CALL for a plugin native hook" {
    // A plugin declaring a native build hook (#518) gets its `plugin.hook.zig`
    // staged as `plugin_<name>_build_hook.zig` and the generated build.zig
    // `@import`s it + calls `postWire` on the game artifact, so the plugin can
    // contribute C/C++ sources / link steps / include paths.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try emitPluginBuildHooks(&aw.writer, "exe", &.{.{ .plugin_name = "spine" }});

    try testing.expectEqualStrings(
        "    const plugin_spine_build_hook = @import(\"plugin_spine_build_hook.zig\");\n" ++
            "    plugin_spine_build_hook.postWire(b, .{\n" ++
            "        .artifact = exe,\n" ++
            "        .module = plugin_spine_mod,\n" ++
            "        .plugin_dep = plugin_spine_dep,\n" ++
            "        .target = target,\n" ++
            "        .optimize = optimize,\n" ++
            "    });\n",
        aw.written(),
    );
}

test "emitPluginBuildHooks: threads the given artifact name (wasm/lib/exe)" {
    // The same seam serves every platform's artifact variable — desktop/ios
    // `exe`, wasm `wasm`, android `lib`.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitPluginBuildHooks(&aw.writer, "lib", &.{.{ .plugin_name = "spine" }});
    try testing.expect(std.mem.indexOf(u8, aw.written(), ".artifact = lib,\n") != null);
}

test "emitLibPluginDataImports: resolver-classified libs get constants+i18n (byte pin)" {
    // The libs/ gap (flying-platform#786 friction #1): only plugins the
    // RESOLVER classified as in-project (`cache.isInProjectLib` — canonical
    // containment, so lexical `@libs/` claims and symlink escapes never land
    // in this slice) receive the generated data modules; a fetched or
    // out-of-project package must keep building standalone and may declare a
    // `constants` module of its own.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try emitLibPluginDataImports(&aw.writer, &.{"needs_machine"}, true, true);

    try testing.expectEqualStrings(
        "    // In-project libs read the game's constants/strings too (the libs/\n" ++
            "    // gap, flying-platform#786): resolve their generated-data imports.\n" ++
            "    overrideImport(plugin_needs_machine_mod, \"constants\", constants_mod);\n" ++
            "    overrideImport(plugin_needs_machine_mod, \"i18n\", i18n_mod);\n",
        aw.written(),
    );
}

test "inProjectLibDir: traversal and degenerate components do not classify as in-project (#662 review)" {
    // `libs/` is a PREFIX test on the unnormalized path; without the component
    // walk, `@libs/../../shared` would chain a test step (#82) with a cwd
    // outside the tree. (The generated-data injection no longer consults this
    // — it rides the resolver's canonical `lib_plugin_names`.)
    try testing.expectEqualStrings("libs/needs_machine", inProjectLibDir(.{ .name = "n", .repo = "@libs/needs_machine" }).?);
    try testing.expectEqualStrings("libs/a/b", inProjectLibDir(.{ .name = "n", .repo = "@libs/a/b" }).?);
    try testing.expect(inProjectLibDir(.{ .name = "n", .repo = "@libs/../../shared" }) == null);
    try testing.expect(inProjectLibDir(.{ .name = "n", .repo = "@libs/a/../b" }) == null);
    try testing.expect(inProjectLibDir(.{ .name = "n", .repo = "@libs/./a" }) == null);
    try testing.expect(inProjectLibDir(.{ .name = "n", .repo = "@libs/a\\..\\b" }) == null);
    try testing.expect(inProjectLibDir(.{ .name = "n", .repo = "@libs//a" }) == null);
    try testing.expect(inProjectLibDir(.{ .name = "n", .repo = "@libs/a/" }) == null);
    try testing.expect(inProjectLibDir(.{ .name = "n", .repo = "local:libs/a" }) == null);
}

test "emitLibPluginDataImports: each flag gates its own line" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitLibPluginDataImports(&aw.writer, &.{"needs_machine"}, true, false);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"constants\"") != null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "\"i18n\"") == null);
}

test "emitLibPluginDataImports: constants/i18n off, or no lib plugins, emits nothing (byte-identical build.zig)" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitLibPluginDataImports(&aw.writer, &.{"needs_machine"}, false, false);
    try emitLibPluginDataImports(&aw.writer, &.{}, true, true);
    try testing.expectEqualStrings("", aw.written());
}

test "emitPluginBuildHooks: no hooks emits nothing (byte-identical build.zig)" {
    // The additive invariant: a project whose plugins ship no `plugin.hook.zig`
    // passes an empty slice and this helper writes zero bytes, so the generated
    // build.zig is byte-identical to before #518.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitPluginBuildHooks(&aw.writer, "exe", &.{});
    try testing.expectEqualStrings("", aw.written());
}

test "emitPluginBuildSteps: the ticket's cargo shape — command, cwd, artifact link (byte pin)" {
    // The #586 acceptance wiring: a {cache}-parameterised command becomes a
    // b.addSystemCommand with the per-plugin cache const spliced as the arg,
    // cwd lands inside the staged package, the produced staticlib links via
    // addObjectFile, and the exe waits on the step.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try emitPluginBuildSteps(testing.allocator, &aw.writer, "exe", &.{.{
        .plugin_name = "foo",
        .package_abs = "/abs/deps/labelle-foo",
        .cache_rel = "plugin-build/foo",
        .steps = &.{.{
            .name = "cargo-lib",
            .command = &.{ "cargo", "build", "--release", "--target-dir", "{cache}" },
            .cwd = "native",
            .artifact = "{cache}/release/libfoo.a",
            .link = .static_lib,
        }},
    }});

    try testing.expectEqualStrings(
        "\n    // Plugin build steps (labelle-assembler#586): declared argv from each\n" ++
            "    // plugin's plugin.labelle `.build` block; produced artifacts link onto\n" ++
            "    // the game artifact. Declared order = execution order within a plugin.\n" ++
            "    const plugin_foo_build_cache = b.pathFromRoot(\"plugin-build/foo\");\n" ++
            "    // .build step 'cargo-lib' of plugin 'foo'\n" ++
            "    const plugin_foo_build_step_0 = b.addSystemCommand(&.{ \"cargo\", \"build\", \"--release\", \"--target-dir\", plugin_foo_build_cache });\n" ++
            "    plugin_foo_build_step_0.setCwd(.{ .cwd_relative = \"/abs/deps/labelle-foo/native\" });\n" ++
            "    const plugin_foo_build_artifact_0 = b.path(\"plugin-build/foo/release/libfoo.a\");\n" ++
            "    exe.root_module.addObjectFile(plugin_foo_build_artifact_0);\n" ++
            "    exe.step.dependOn(&plugin_foo_build_step_0.step);\n",
        aw.written(),
    );
}

test "emitPluginBuildSteps: {package}/{target} args, step chaining, package-rooted artifact" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try emitPluginBuildSteps(testing.allocator, &aw.writer, "lib", &.{.{
        .plugin_name = "bar",
        .package_abs = "/pkg/bar",
        .cache_rel = "plugin-build/bar",
        .steps = &.{
            .{
                .name = "gen",
                .command = &.{ "tool", "--triple={target}", "{package}/src" },
            },
            .{
                .name = "pack",
                .command = &.{ "pack", "{package}/out.o" },
                .artifact = "{package}/libbar.a",
                .link = .object,
            },
        },
    }});
    const out = aw.written();

    // {target} in an arg → ONE shared triple const, resolved at build time.
    const triple_decl = "    const plugin_build_target_triple = target.result.zigTriple(b.allocator) catch @panic(\"OOM\");\n";
    const first = std.mem.indexOf(u8, out, triple_decl) orelse return error.MissingTripleDecl;
    try testing.expect(std.mem.indexOfPos(u8, out, first + 1, triple_decl) == null);

    // Mixed-text {target} arg → b.fmt; {package} arg → generate-time literal.
    try testing.expect(std.mem.indexOf(u8, out, "    const plugin_bar_build_step_0 = b.addSystemCommand(&.{ \"tool\", b.fmt(\"--triple={s}\", .{ plugin_build_target_triple }), \"/pkg/bar/src\" });\n") != null);

    // No {cache} use anywhere → no cache const (would be an unused-const
    // compile error in the generated build.zig).
    try testing.expect(std.mem.indexOf(u8, out, "plugin_bar_build_cache") == null);

    // Declared order = execution order: step 1 waits on step 0; the lib
    // artifact waits on the LAST step.
    try testing.expect(std.mem.indexOf(u8, out, "    plugin_bar_build_step_1.step.dependOn(&plugin_bar_build_step_0.step);\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    lib.step.dependOn(&plugin_bar_build_step_1.step);\n") != null);

    // {package}-rooted artifact → absolute cwd_relative LazyPath.
    try testing.expect(std.mem.indexOf(u8, out, "    const plugin_bar_build_artifact_1: std.Build.LazyPath = .{ .cwd_relative = \"/pkg/bar/libbar.a\" };\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    lib.root_module.addObjectFile(plugin_bar_build_artifact_1);\n") != null);

    // A .link = .none step links nothing.
    try testing.expect(std.mem.indexOf(u8, out, "plugin_bar_build_artifact_0") == null);

    // Default cwd = the package root.
    try testing.expect(std.mem.indexOf(u8, out, "    plugin_bar_build_step_0.setCwd(.{ .cwd_relative = \"/pkg/bar\" });\n") != null);
}

test "emitPluginBuildSteps: no declared steps emits nothing (byte-identical build.zig)" {
    // #586's additive invariant, same shape as the #518 no-hooks pin.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitPluginBuildSteps(testing.allocator, &aw.writer, "exe", &.{});
    try testing.expectEqualStrings("", aw.written());
}

test "emitPluginBuildSteps: {staticlib:NAME} artifact + per-OS system_libs — the rust cargo shape (linux+windows golden)" {
    // The labelle-engine#741 wiring: the artifact name is TARGET-specific
    // (`labelle_rust_scripts.lib` on Windows, `liblabelle_rust_scripts.a`
    // elsewhere), and the panic=unwind staticlib needs gcc_s/… at the
    // final link on Linux ONLY. One generated build.zig carries both:
    // build-time prefix/ext consts + a per-OS linkSystemLibrary switch.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try emitPluginBuildSteps(testing.allocator, &aw.writer, "exe", &.{.{
        .plugin_name = "scripting",
        .package_abs = "/abs/deps/labelle-scripting",
        .cache_rel = "plugin-build/scripting",
        .steps = &.{.{
            .name = "cargo-scripts",
            .command = &.{ "cargo", "build", "--release", "--locked", "--manifest-path", "{package}/native/Cargo.toml", "--target-dir", "{cache}" },
            .artifact = "{cache}/release/{staticlib:labelle_rust_scripts}",
            .link = .static_lib,
            .system_libs = .{
                .linux = &.{ "gcc_s", "util", "rt", "pthread", "m", "dl" },
                .windows = &.{ "ws2_32", "userenv" },
            },
        }},
    }});
    const out = aw.written();

    // The shared lib-name consts, emitted once, resolved at build time.
    try testing.expect(std.mem.indexOf(u8, out, "    const plugin_build_lib_prefix: []const u8 = if (target.result.os.tag == .windows) \"\" else \"lib\";\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    const plugin_build_lib_ext: []const u8 = if (target.result.os.tag == .windows) \".lib\" else \".a\";\n") != null);

    // The artifact path becomes a build-time b.fmt (windows finds its
    // `.lib`, unix its `lib….a` — no per-OS manifest duplication).
    try testing.expect(std.mem.indexOf(u8, out, "    const plugin_scripting_build_artifact_0 = b.path(b.fmt(\"plugin-build/scripting/release/{s}labelle_rust_scripts{s}\", .{ plugin_build_lib_prefix, plugin_build_lib_ext }));\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    exe.root_module.addObjectFile(plugin_scripting_build_artifact_0);\n") != null);

    // The per-OS final-link switch: linux + windows arms exactly as
    // declared, NO macos arm (empty list = no arm), else fallthrough.
    const switch_golden =
        "    switch (target.result.os.tag) {\n" ++
        "        .linux => {\n" ++
        "            exe.root_module.linkSystemLibrary(\"gcc_s\", .{});\n" ++
        "            exe.root_module.linkSystemLibrary(\"util\", .{});\n" ++
        "            exe.root_module.linkSystemLibrary(\"rt\", .{});\n" ++
        "            exe.root_module.linkSystemLibrary(\"pthread\", .{});\n" ++
        "            exe.root_module.linkSystemLibrary(\"m\", .{});\n" ++
        "            exe.root_module.linkSystemLibrary(\"dl\", .{});\n" ++
        "        },\n" ++
        "        .windows => {\n" ++
        "            exe.root_module.linkSystemLibrary(\"ws2_32\", .{});\n" ++
        "            exe.root_module.linkSystemLibrary(\"userenv\", .{});\n" ++
        "        },\n" ++
        "        else => {},\n" ++
        "    }\n";
    try testing.expect(std.mem.indexOf(u8, out, switch_golden) != null);
    try testing.expect(std.mem.indexOf(u8, out, ".macos =>") == null);

    // Ordering: the switch belongs to the artifact link, after the
    // addObjectFile and before the exe→step dependency close.
    const add_obj = std.mem.indexOf(u8, out, "addObjectFile(plugin_scripting_build_artifact_0)").?;
    const sw = std.mem.indexOf(u8, out, "switch (target.result.os.tag)").?;
    const dep = std.mem.indexOf(u8, out, "exe.step.dependOn(&plugin_scripting_build_step_0.step);").?;
    try testing.expect(add_obj < sw);
    try testing.expect(sw < dep);
}

test "emitPluginBuildSteps: {staticlib:NAME} in command args and package-rooted artifacts rides b.fmt" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try emitPluginBuildSteps(testing.allocator, &aw.writer, "exe", &.{.{
        .plugin_name = "foo",
        .package_abs = "/pkg/foo",
        .cache_rel = "plugin-build/foo",
        .steps = &.{.{
            .name = "ziglib",
            .command = &.{ "zig", "build-lib", "-femit-bin={cache}/{staticlib:adder}" },
            .artifact = "{package}/out/{staticlib:adder}",
            .link = .static_lib,
        }},
    }});
    const out = aw.written();

    // Mixed {cache} + staticlib arg: one b.fmt, slots in token order.
    try testing.expect(std.mem.indexOf(u8, out, "b.fmt(\"-femit-bin={s}/{s}adder{s}\", .{ plugin_foo_build_cache, plugin_build_lib_prefix, plugin_build_lib_ext })") != null);
    // Package-rooted artifact with the token: absolute cwd_relative b.fmt.
    try testing.expect(std.mem.indexOf(u8, out, "    const plugin_foo_build_artifact_0: std.Build.LazyPath = .{ .cwd_relative = b.fmt(\"/pkg/foo/out/{s}adder{s}\", .{ plugin_build_lib_prefix, plugin_build_lib_ext }) };\n") != null);
    // No system_libs declared → no per-OS switch anywhere.
    try testing.expect(std.mem.indexOf(u8, out, "switch (target.result.os.tag)") == null);
}

test "emitPluginBuildSteps: the crystal shape — {crystal_target} const, artifact-less chaining, library paths (golden)" {
    // The wiring arrives PRE-FILTERED (root.zig applied the `.os` gate,
    // so a macOS generate emits crystal-build + the macOS localization
    // only) with the {crystal_env:…} library paths already resolved.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try emitPluginBuildSteps(testing.allocator, &aw.writer, "exe", &.{.{
        .plugin_name = "scripting",
        .package_abs = "/abs/deps/labelle-scripting",
        .cache_rel = "plugin-build/scripting",
        .library_paths = &.{ "/opt/homebrew/lib", "/opt/crystal/lib" },
        .steps = &.{
            .{
                .name = "crystal-build",
                .command = &.{ "crystal", "build", "--release", "--cross-compile", "--target", "{crystal_target}", "{package}/native-crystal/src/main.cr", "-o", "{cache}/labelle_crystal_scripts" },
                .os = &.{ "macos", "linux" },
            },
            .{
                .name = "localize-main-macos",
                .command = &.{ "ld", "-r", "{cache}/labelle_crystal_scripts.o", "-o", "{cache}/labelle_crystal_scripts_lib.o", "-exported_symbols_list", "{package}/native-crystal/exported_symbols_macos.txt" },
                .artifact = "{cache}/labelle_crystal_scripts_lib.o",
                .link = .object,
                .os = &.{"macos"},
                .system_libs = .{ .macos = &.{ "gc", "iconv", "pcre2-8" } },
            },
        },
    }});
    const out = aw.written();

    // The shared crystal-target const: the crystalTriple mapping verbatim,
    // resolved at build time, emitted once.
    const ct_decl = "    const plugin_build_crystal_target: []const u8 = switch (target.result.os.tag) {\n";
    const first = std.mem.indexOf(u8, out, ct_decl) orelse return error.MissingCrystalTargetDecl;
    try testing.expect(std.mem.indexOfPos(u8, out, first + 1, ct_decl) == null);
    try testing.expect(std.mem.indexOf(u8, out, "            .aarch64 => \"aarch64-apple-darwin\",\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "            .x86_64 => \"x86_64-linux-gnu\",\n") != null);
    // …and the argv references it as a bare build-time slot.
    try testing.expect(std.mem.indexOf(u8, out, "\"--target\", plugin_build_crystal_target,") != null);

    // Artifact-less intermediate: step 0 links nothing (no artifact
    // const), the localization step chains after it and ITS object links.
    try testing.expect(std.mem.indexOf(u8, out, "plugin_scripting_build_artifact_0") == null);
    try testing.expect(std.mem.indexOf(u8, out, "    plugin_scripting_build_step_1.step.dependOn(&plugin_scripting_build_step_0.step);\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    const plugin_scripting_build_artifact_1 = b.path(\"plugin-build/scripting/labelle_crystal_scripts_lib.o\");\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    exe.root_module.addObjectFile(plugin_scripting_build_artifact_1);\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    exe.step.dependOn(&plugin_scripting_build_step_1.step);\n") != null);

    // Resolved library paths: one addLibraryPath per entry, declared order.
    const lp_a = std.mem.indexOf(u8, out, "    exe.root_module.addLibraryPath(.{ .cwd_relative = \"/opt/homebrew/lib\" });\n") orelse return error.MissingLibraryPath;
    const lp_b = std.mem.indexOf(u8, out, "    exe.root_module.addLibraryPath(.{ .cwd_relative = \"/opt/crystal/lib\" });\n") orelse return error.MissingLibraryPath;
    try testing.expect(lp_a < lp_b);

    // The per-OS system libs ride the existing switch emission.
    try testing.expect(std.mem.indexOf(u8, out, "            exe.root_module.linkSystemLibrary(\"iconv\", .{});\n") != null);

    // No runtime-output staging for a linked-artifact language (crystal):
    // the #617 install wiring is csharp's alone.
    try testing.expect(std.mem.indexOf(u8, out, "runtime_outputs") == null);
}

test "emitPluginBuildSteps: the csharp shape (#617) — link-less dotnet publish, runtime outputs installed beside the exe (golden)" {
    // The csharp `.language_builds` entry as root.zig wires it: ONE
    // link-less `dotnet publish -o {cache}` step with
    // `stage_runtime_outputs` decided true (scripting_csharp
    // .stagesRuntimeOutputs). The publish dir IS the runtime payload, so
    // the emission adds the InstallDir step staging it beside the exe.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try emitPluginBuildSteps(testing.allocator, &aw.writer, "exe", &.{.{
        .plugin_name = "scripting",
        .package_abs = "/abs/deps/labelle-scripting",
        .cache_rel = "plugin-build/scripting",
        .stage_runtime_outputs = true,
        .steps = &.{.{
            .name = "dotnet-publish-scripts",
            .command = &.{ "dotnet", "publish", "{package}/native-csharp/LabelleScripts.csproj", "-c", "Release", "--self-contained", "false", "-o", "{cache}" },
        }},
    }});
    const out = aw.written();

    // The cache const is FORCED (the -o arg also references it here, but
    // the install wiring must not depend on that) and the command emits.
    try testing.expect(std.mem.indexOf(u8, out, "    const plugin_scripting_build_cache = b.pathFromRoot(\"plugin-build/scripting\");\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "b.addSystemCommand(&.{ \"dotnet\", \"publish\"") != null);

    // Link-less: nothing is linked, the exe just depends on the step.
    try testing.expect(std.mem.indexOf(u8, out, "addObjectFile") == null);
    try testing.expect(std.mem.indexOf(u8, out, "    exe.step.dependOn(&plugin_scripting_build_step_0.step);\n") != null);

    // THE #617 wiring: an InstallDir step copies {cache} (the publish
    // output) into the exe's install dir, ordered after the publish and
    // reached from the default install step — `zig build` alone yields
    // the assembly beside the binary.
    try testing.expect(std.mem.indexOf(u8, out, "    const plugin_scripting_runtime_outputs = b.addInstallDirectory(.{\n" ++
        "        .source_dir = .{ .cwd_relative = plugin_scripting_build_cache },\n" ++
        "        .install_dir = .bin,\n" ++
        "        .install_subdir = \"\",\n" ++
        "    });\n" ++
        "    plugin_scripting_runtime_outputs.step.dependOn(&plugin_scripting_build_step_0.step);\n" ++
        "    b.getInstallStep().dependOn(&plugin_scripting_runtime_outputs.step);\n") != null);
}

test "emitPluginBuildSteps: runtime outputs stage on the exe target only (never wasm/lib)" {
    // The csharp steps are desktop-allowlisted and only the desktop exe
    // installs a runnable binary — the lib/wasm emissions must stay free
    // of the InstallDir wiring even if a wiring entry carried the flag.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try emitPluginBuildSteps(testing.allocator, &aw.writer, "lib", &.{.{
        .plugin_name = "scripting",
        .package_abs = "/abs/deps/labelle-scripting",
        .cache_rel = "plugin-build/scripting",
        .stage_runtime_outputs = true,
        .steps = &.{.{ .name = "dotnet-publish-scripts", .command = &.{ "dotnet", "publish", "-o", "{cache}" } }},
    }});
    try testing.expect(std.mem.indexOf(u8, aw.written(), "runtime_outputs") == null);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "    lib.step.dependOn(&plugin_scripting_build_step_0.step);\n") != null);
}

test "runtimeOutputsEntry: picks the flagged entry, none when absent (footer env gate)" {
    const flagged = PluginBuildStepsWiring{
        .plugin_name = "scripting",
        .package_abs = "/abs",
        .cache_rel = "plugin-build/scripting",
        .stage_runtime_outputs = true,
        .steps = &.{},
    };
    const plain = PluginBuildStepsWiring{
        .plugin_name = "physics",
        .package_abs = "/abs",
        .cache_rel = "plugin-build/physics",
        .steps = &.{},
    };
    try testing.expect(runtimeOutputsEntry(&.{ plain, flagged }) != null);
    try testing.expectEqualStrings("scripting", runtimeOutputsEntry(&.{ plain, flagged }).?.plugin_name);
    try testing.expect(runtimeOutputsEntry(&.{plain}) == null);
    try testing.expect(runtimeOutputsEntry(&.{}) == null);
}

test "generateBuildZig footer (codex #644 round 2): the C# run env + InstallDir bind to the SCRIPTING plugin even when a link-less non-scripting plugin is ordered first" {
    // The regression scenario at the emission layer: a non-scripting
    // "helper" whose link-less build is ordered FIRST (stage_runtime_outputs
    // = false, as root.zig now flags a non-scripting plugin) and the
    // scripting csharp publish SECOND (stage = true). The footer must point
    // LABELLE_CS_ASSEMBLY_DIR at the SCRIPTING plugin's publish cache — never
    // the helper's, which merely happens to build first. (root.zig's DECISION
    // to flag only the scripting plugin is covered by
    // `scripting_csharp.stagesRuntimeOutputs`'s unit test; this pins the
    // emission honors the flag regardless of plugin order.)
    const allocator = testing.allocator;
    const helper: PluginBuildStepsWiring = .{
        .plugin_name = "helper",
        .package_abs = "/abs/deps/labelle-helper",
        .cache_rel = "plugin-build/helper",
        .stage_runtime_outputs = false,
        .steps = &.{.{ .name = "helper-build", .command = &.{ "dotnet", "publish", "-o", "{cache}" } }},
    };
    const scripting: PluginBuildStepsWiring = .{
        .plugin_name = "scripting",
        .package_abs = "/abs/deps/labelle-scripting",
        .cache_rel = "plugin-build/scripting",
        .stage_runtime_outputs = true,
        .steps = &.{.{ .name = "dotnet-publish-scripts", .command = &.{ "dotnet", "publish", "-o", "{cache}" } }},
    };
    // Desktop exe path against the in-tree sokol v2 fixture (cwd = repo root
    // under `zig build test`); is_tests_target = false so the run footer is
    // emitted. generateBuildZig emits only build.zig, so no engine template
    // is needed (same shape as the helpers' `genSokolBuildZigV2`).
    const cfg = ProjectConfig{
        .name = "two-plugin-game",
        .backend_package = .{ .name = "sokol", .repo = "local:backends/sokol" },
        .ecs = .mock,
    };
    const out = try generateBuildZig(allocator, cfg, .{
        .is_tests_target = false,
        .project_dir = ".",
        .backend_manifest_name = "backend.manifest.v2.zon",
        .plugin_build_steps = &.{ helper, scripting },
    });
    defer allocator.free(out);

    // The run env binds the CoreCLR host to the SCRIPTING cache…
    try testing.expect(std.mem.indexOf(u8, out, "run_cmd.setEnvironmentVariable(\"LABELLE_CS_ASSEMBLY_DIR\", plugin_scripting_build_cache);") != null);
    // …never the helper's (which builds first).
    try testing.expect(std.mem.indexOf(u8, out, "LABELLE_CS_ASSEMBLY_DIR\", plugin_helper_build_cache") == null);
    // Only the scripting plugin stages runtime outputs beside the exe.
    try testing.expect(std.mem.indexOf(u8, out, "plugin_scripting_runtime_outputs") != null);
    try testing.expect(std.mem.indexOf(u8, out, "plugin_helper_runtime_outputs") == null);
    // The helper's own build step still emits — it just doesn't stage/capture.
    try testing.expect(std.mem.indexOf(u8, out, "plugin_helper_build_step_0") != null);
}
