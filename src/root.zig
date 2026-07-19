/// labelle-cli generator — reads project.labelle, outputs .labelle/ assembler files.
/// Thin orchestrator that delegates to focused submodules.
const std = @import("std");
const builtin = @import("builtin");

// ── Submodules ─────────────────────────────────────────────────────────
const config = @import("config.zig");
const cache = @import("cache.zig");
const backend_registry = @import("backend_registry.zig");
pub const scanner = @import("scanner.zig");
pub const scene_manifest = @import("scene_manifest.zig");
pub const tilemap_scan = @import("tilemap_scan.zig");
pub const asset_validator = @import("asset_validator.zig");
pub const lazy_inference = @import("lazy_inference.zig");
pub const main_zig = @import("main_zig.zig");
pub const script_scanner = @import("script_scanner.zig");
pub const flow_scanner = @import("flow_scanner.zig");
pub const flow_catalog = @import("flow_catalog.zig");
pub const pack_manifest = @import("manifest.zig");
const build_files = @import("build_files.zig");
const plugin_build_hook = @import("plugin_build_hook.zig");
pub const plugin_build_steps = @import("plugin_build_steps.zig");
const manifest_splice = @import("codegen/manifest_splice.zig");
pub const manifest_v2 = @import("codegen/manifest_v2.zig");
const manifest_v2_splice = @import("codegen/manifest_v2_splice.zig");
const capabilities = @import("capabilities.zig");
pub const template = @import("template.zig");
pub const plugin_manifest = @import("plugin_manifest.zig");
pub const plugin_params = @import("plugin_params.zig");
pub const scripting_splice = @import("scripting_splice.zig");
pub const scripting_declare = @import("scripting_declare.zig");
pub const scripting_transpile = @import("scripting_transpile.zig");
pub const scripting_csharp = @import("scripting_csharp.zig");
pub const pack_validate = @import("pack_validate.zig");
pub const panel_validate = @import("panel_validate.zig");
const scene_name_lint = @import("scene_name_lint.zig");
const gui_resolve = @import("gui_resolve.zig");
pub const app_icon = @import("app_icon.zig");
const scan = @import("codegen/scan.zig");
const pack_root_gen = @import("codegen/pack_root.zig");
const idents = @import("codegen/idents.zig");

// ── root/ sub-package (behavior-preserving split of this orchestrator) ──
// Cohesive helper groups extracted verbatim from this file; the barrel
// re-exports their public surface below and orchestrates them in `generate`.
const game_shim_mod = @import("root/game_shim.zig");
const provider_contracts = @import("root/provider_contracts.zig");
const manifest_detect = @import("root/manifest_detect.zig");
const pack_scan = @import("root/pack_scan.zig");
const templates = @import("root/templates.zig");
const generate_phases = @import("root/generate_phases.zig");
const tilemap_phase = @import("root/tilemap_phase.zig");

// Force test discovery for files that aren't transitively reached by
// any compiled function path during `addTest` runs.
test {
    _ = @import("config.zig");
    _ = @import("plugin_manifest.zig");
    _ = @import("plugin_build_hook.zig");
    _ = @import("plugin_build_steps.zig");
    // Pulls in the build_files/ sub-modules' inline tests (its own `test`
    // block references build_zig.zig + build_zig_zon.zig). Was missing —
    // the #518 emitPluginBuildHooks pins and the #586 emitPluginBuildSteps
    // goldens were dormant until this reference.
    _ = @import("build_files.zig");
    _ = @import("pack_validate.zig");
    _ = @import("check.zig");
    _ = @import("scene_name_lint.zig");
    _ = @import("scene_manifest.zig");
    _ = @import("scene_manifest_test.zig");
    _ = @import("tilemap_scan_test.zig"); // covers tilemap_scan + tilemap_scene_scan
    _ = @import("asset_validator.zig");
    _ = @import("pack_resources.zig");
    _ = @import("language_policy.zig");
    _ = @import("plugin_params.zig");
    _ = @import("scripting_splice.zig");
    _ = @import("scripting_declare.zig");
    _ = @import("scripting_transpile.zig");
    _ = @import("scripting_csharp.zig");
    _ = @import("panel_validate.zig");
    _ = @import("lazy_inference.zig");
    _ = @import("cache.zig");
    _ = @import("deps_linker.zig");
    _ = @import("backend_registry.zig");
    _ = @import("app_icon.zig");
    _ = @import("flow_catalog.zig");
    _ = @import("manifest.zig");
    _ = @import("codegen/idents.zig");
    _ = @import("codegen/validate.zig");
    _ = @import("codegen/manifest_splice.zig");
    _ = @import("codegen/manifest_v2.zig");
    _ = @import("codegen/manifest_v2_splice.zig");
    _ = @import("codegen/packager.zig");
    _ = @import("codegen/core_diamond.zig");
    _ = @import("codegen/emsdk_preflight.zig");
    _ = @import("codegen/main_template.zig");
    _ = @import("capabilities.zig");
    _ = @import("root/game_shim.zig");
    _ = @import("root/provider_contracts.zig");
    _ = @import("root/manifest_detect.zig");
    _ = @import("root/pack_scan.zig");
    _ = @import("root/templates.zig");
    _ = @import("root/generate_phases.zig");
}

// ── Re-exports (preserve public API for tests and consumers) ──────────
pub const Backend = config.Backend;
pub const Platform = config.Platform;
pub const EcsChoice = config.EcsChoice;
pub const GuiPlugin = config.GuiPlugin;
pub const ResolvedGui = config.ResolvedGui;
pub const RenderingMode = config.RenderingMode;
pub const GuiLifecycle = config.GuiLifecycle;
pub const PluginDep = config.PluginDep;
pub const IosConfig = config.IosConfig;
pub const AndroidConfig = config.AndroidConfig;
pub const Orientation = config.Orientation;
pub const LayerSpace = config.LayerSpace;
pub const LayerDef = config.LayerDef;
pub const ResourceDef = config.ResourceDef;
pub const ResourceKind = config.ResourceKind;
pub const ResourceValidationError = config.ResourceValidationError;
pub const FontBakeParams = config.FontBakeParams;
pub const CodepointRange = config.CodepointRange;
pub const ProjectConfig = config.ProjectConfig;
pub const CLI_VERSION = config.CLI_VERSION;
pub const CORE_VERSION = config.CORE_VERSION;
pub const ENGINE_VERSION = config.ENGINE_VERSION;
pub const GFX_VERSION = config.GFX_VERSION;
pub const ASSEMBLER_VERSION = config.ASSEMBLER_VERSION;
pub const isLocalVersion = config.isLocalVersion;
pub const initGlobalIo = config.initGlobalIo;

pub const resolveGuiPlugin = gui_resolve.resolveGuiPlugin;

pub const generateMainZigFromTemplate = main_zig.generateMainZigFromTemplate;
/// Codegen orchestrator module — exposed so callers/tests can set the
/// module-level `pack_scans` (Packs RFC §4, #439) / `loop_style_override`
/// vars that thread into `generateMainZigFromTemplate`.
pub const main_template = main_zig.main_template;
/// Pack dir-scan result (Packs RFC §4, #439). Re-exported so tests can build
/// one directly and callers can name the `scanPack` return type.
pub const PackScan = main_zig.PackScan;
pub const generateBuildZig = build_files.generateBuildZig;
pub const BuildZigOptions = build_files.BuildZigOptions;
pub const generateBuildZigZon = build_files.generateBuildZigZon;
pub const deps_linker = build_files.deps_linker;
// Stages the v2 backend build hook next to the generated build.zig
// (`backend_build_hook.zig`) so the generated `@import` resolves — see the fn
// docs (PR #466 Finding 3).
pub const stageBackendBuildHook = manifest_v2_splice.stageBackendBuildHook;
pub const backend_build_hook_name = manifest_v2_splice.hook_import_name;
pub const PromotedScript = @import("codegen/scan.zig").PromotedScript;
/// Per-pack module generation (#498 PR 2): `__pack_root.zig` renderer +
/// the `PackModule` build-wiring record. Exposed for tests.
pub const pack_root = @import("codegen/pack_root.zig");

pub const validateCache = cache.validateCache;
pub const getCacheRoot = cache.getCacheRoot;
pub const getPackagesDir = cache.getPackagesDir;
pub const populateAssemblerCache = cache.populateAssemblerCache;
pub const populateFrameworkPackage = cache.populateFrameworkPackage;
pub const populatePlugin = cache.populatePlugin;
pub const isFrameworkCached = cache.isFrameworkCached;
pub const isAssemblerCached = cache.isAssemblerCached;
pub const isPluginCached = cache.isPluginCached;
pub const fetchFrameworkPackage = cache.fetchFrameworkPackage;
pub const fetchPlugin = cache.fetchPlugin;
pub const fetchAssemblerPackages = cache.fetchAssemblerPackages;
pub const R2_BASE_URL = cache.R2_BASE_URL;
pub const patchCachedDeps = cache.patchCachedDeps;
pub const resolvePlugin = cache.resolvePlugin;
pub const resolveAssemblerPackage = cache.resolveAssemblerPackage;
pub const resolveBundledPackage = cache.resolveBundledPackage;
pub const resolveGuiPackage = cache.resolveGuiPackage;
pub const resolveGuiUrl = cache.resolveGuiUrl;
pub const fetchGuiPackage = cache.fetchGuiPackage;
pub const fetchGuiUrl = cache.fetchGuiUrl;

// ── Game shim generation (root/game_shim.zig) ───────────────────────
pub const GameShimOptions = game_shim_mod.GameShimOptions;
pub const generateGameShim = game_shim_mod.generateGameShim;

/// Generate all assembler files into output_dir/<target_name>/.
/// `opts.target_name_override` lets the caller pin the subdirectory name
/// (used by `generateTestsTarget` to emit `.labelle/tests/`); null falls
/// back to `<backend>_<platform>`. `opts.is_tests_target` selects the
/// test-only build.zig shape — no exe step, no main.zig — and is paired
/// with the override by `generateTestsTarget`. Issue #83.
pub const GenerateOptions = struct {
    target_name_override: ?[]const u8 = null,
    is_tests_target: bool = false,
    /// The target OS the per-step `.os` allowlists select against
    /// (labelle-engine#741 crystal: the main-localization pass differs
    /// per OS, so exactly one variant is emitted). Null (production) =
    /// the HOST OS (`builtin.os.tag`) — desktop generates build for the
    /// machine they run on; cross-desktop `zig build -Dtarget=` of the
    /// generated project is outside the per-OS step model's v1 scope.
    /// TEST SEAM: the suite drives macos/linux/windows selection through
    /// the real generate with it (the declare phase's override-runner
    /// pattern).
    plugin_build_os: ?std.Target.Os.Tag = null,
};

/// The `.os`-filtered view of `steps` for `os_tag`
/// (`plugin_build_steps.stepAllowsOs`), or null when every step already
/// allows it — callers then borrow the original slice, keeping the
/// no-`.os` common case allocation-free (and byte-identical downstream).
fn filterStepsByOs(
    allocator: std.mem.Allocator,
    steps: []const plugin_build_steps.Step,
    os_tag: std.Target.Os.Tag,
) !?[]plugin_build_steps.Step {
    var all = true;
    for (steps) |s| {
        if (!plugin_build_steps.stepAllowsOs(s, os_tag)) {
            all = false;
            break;
        }
    }
    if (all) return null;
    var kept: std.ArrayList(plugin_build_steps.Step) = .empty;
    errdefer kept.deinit(allocator);
    for (steps) |s| {
        if (plugin_build_steps.stepAllowsOs(s, os_tag)) try kept.append(allocator, s);
    }
    return try kept.toOwnedSlice(allocator);
}

// ── Provider-contract checks (root/provider_contracts.zig) ──────────
pub const validateProviderContracts = provider_contracts.validateProviderContracts;

// ── Backend manifest-v2 detection + overrides (root/manifest_detect.zig) ─
pub const resolveLoopStyleOverride = manifest_detect.resolveLoopStyleOverride;
pub const resolveLifecycleOverride = manifest_detect.resolveLifecycleOverride;

// ── Pack convention-dir scanning (root/pack_scan.zig) ───────────────
pub const declModulePlugins = pack_scan.declModulePlugins;
pub const scanPackScriptsAt = pack_scan.scanPackScriptsAt;
pub const scanPack = pack_scan.scanPack;

// ── Asset-Plugins Phase 1: pack resources (pack_resources.zig) ──────
// The merge (#573) + copy/namespace/validate (#574/#575) + scene auto-wiring
// (#575) entry points, wired into `generate()` above. Exposed for tests.
pub const pack_resources = @import("pack_resources.zig");

// ── One-language-per-project policy (#584, RFC-LANGUAGE-PLUGINS) ────
// The supported-language table plus the `.params.language` /
// `requires_language` / script-dir checks. Wired into `generate()` via
// `generate_phases.validateLanguagePolicy` (beside the pack-graph gate,
// before any target write). Exposed for tests.
pub const language_policy = @import("language_policy.zig");

pub fn generate(
    allocator: std.mem.Allocator,
    cfg_in: ProjectConfig,
    output_dir: []const u8,
    game_dir: []const u8,
    opts: GenerateOptions,
) !void {
    const target_name_override = opts.target_name_override;
    const is_tests_target = opts.is_tests_target;
    // Shadow the caller's cfg with a mutable copy. Ticket #48's lazy
    // default-inference pass needs to rewrite `cfg.resources[i].lazy`
    // in place, and we don't want to surprise callers by touching
    // their parsed slice.
    var cfg = cfg_in;
    const mutable_resources = try allocator.dupe(ResourceDef, cfg.resources);
    defer allocator.free(mutable_resources);
    cfg.resources = mutable_resources;

    // ── Editor-preview activation (labelle-studio Play mode) ─────────────
    // The studio spawns `labelle build --platform=wasm` with
    // `LABELLE_EDITOR_PREVIEW=1` in the environment; the env propagates
    // through the CLI into this assembler invocation, so reading it HERE
    // (instead of adding a CLI flag through labelle-cli) needs no labelle-cli
    // release. Preview is WASM-ONLY — the browser editor drives the running
    // game through the `editor_*` wasm exports — so on every other platform
    // the request is NORMALIZED OFF (not errored): a desktop build run with
    // the var set must stay byte-identical to a plain build. Zig 0.16 note:
    // `std.process.hasEnvVarConstant` / `std.posix.getenv` are gone; env
    // access goes through the process `Environ` (`config.globalEnviron`),
    // same as `cache/env.zig`.
    generate_phases.normalizeEditorPreview(allocator, &cfg);

    const io = config.globalIo();

    // ── Provider identity + capability negotiation (RFC "Opening the
    // ecosystem", §1616-1683; ecosystem-hardening #453) ──────────────
    // Resolve-time contract checks that produce EARLY, project-level errors —
    // before any build graph is emitted — instead of a deep `@compileError`
    // from generated code. Runs after `requireManifestIfExternal` (a manifest-
    // less external still errors first, with its clearer message) and before
    // `deps_linker.createDepsLinks` / build.zig emission below.
    //
    // ── manifest-v2 production cutover (epic #453, closes #472 P2) ──────
    // Auto-detect a `backend.manifest.v2.zon` in the resolved backend package
    // ONCE here and thread the result through every downstream site
    // (`requireManifestIfExternal`, `generateBuildZigZon`, `generateBuildZig`,
    // `stageBackendBuildHook`) so a v2-shipping backend drives the v2 codegen
    // WITHOUT the caller passing `backend_manifest_name`. `null` → the v1/enum
    // path, unchanged. Detection is LIVE: any resolved package shipping
    // `backend.manifest.v2.zon` — the in-tree fixtures via `backend_package`, or
    // a fetched provider repo that has added the file — drives the v2 path; a
    // dual-manifest backend's desktop output stays byte-identical (§7 anchor).
    // Passing the detected name to `requireManifestIfExternal` is load-bearing: a
    // v2-ONLY external backend (no legacy `backend.manifest.zon`) must not be
    // rejected as manifest-less (the requirement keys off THIS name).
    const backend_manifest_name = manifest_detect.detectV2ManifestName(allocator, cfg, game_dir);
    try manifest_splice.requireManifestIfExternal(allocator, cfg, game_dir, backend_manifest_name);
    try validateProviderContracts(allocator, cfg, game_dir, backend_manifest_name, is_tests_target);

    // ── Editor-preview link-path gate (#526 review, codex P2) ────────────
    // The `editor_*` exports reach the emcc link ONLY through the manifest-v2
    // wasm splice: `renderWasmLinkV2` threads `.editor_preview = true` into
    // the backend hook's `post_wire`, whose emcc arm adds the
    // `-sEXPORTED_FUNCTIONS=_main,_editor_*` list. On any other wasm build
    // path (v1/enum, or a v2 manifest without a wasm platform entry) nothing
    // threads the export list — a hole-bearing template there would splice
    // `editor_api` into main.zig while the JS side gets no callable editor
    // entry points, so Play mode would connect to a game it cannot drive.
    // Reject at generate time with the same upgrade-hint error the
    // template-hole check uses. (The tests target never trips this: it is
    // forced to `.desktop`, so the wasm-only normalization above already
    // cleared the flag.)
    try generate_phases.checkEditorPreviewLinkPath(allocator, cfg, game_dir, backend_manifest_name);

    // Swap `.texture = "...png"` to the pre-converted `.astc` sibling when the
    // target platform opts into ASTC (`asset_compression`) and `labelle astc`
    // produced one. The runtime detects the ASTC magic and uploads the
    // compressed blocks with zero CPU decode (labelle-gfx#269 / #340). Done
    // BEFORE the `.rgba` swap so ASTC wins (the bigger memory + load win); the
    // `.rgba` swap below then skips these (they no longer end in `.png`). Falls
    // back to the source PNG when no `.astc` sibling exists.
    var astc_path_allocs = try generate_phases.swapAstcTexturePaths(allocator, io, cfg, mutable_resources, game_dir);
    defer {
        for (astc_path_allocs.items) |s| allocator.free(s);
        astc_path_allocs.deinit(allocator);
    }

    // Swap `.texture = "...png"` to the pre-baked `.rgba` sibling
    // when `labelle build --bake` produced one. The runtime decoder
    // detects the LRGBA magic and skips stb_image entirely. Leaves
    // the path untouched when no sibling exists, so fresh checkouts
    // (and builds without `--bake`) still embed the source PNG.
    var rgba_path_allocs = try generate_phases.swapRgbaTexturePaths(allocator, io, mutable_resources, game_dir);
    defer {
        for (rgba_path_allocs.items) |s| allocator.free(s);
        rgba_path_allocs.deinit(allocator);
    }

    const cwd = std.Io.Dir.cwd();

    // Target subfolder: .labelle/raylib_desktop/, .labelle/sokol_ios/, etc.
    // Override is used for the `.labelle/tests/` target where the name
    // shouldn't reflect the backend (issue #83).
    const target_name = if (target_name_override) |name|
        try allocator.dupe(u8, name)
    else
        try std.fmt.allocPrint(allocator, "{s}_{s}", .{ cfg.backendName(), @tagName(cfg.platform) });
    defer allocator.free(target_name);
    const target_dir = try std.fs.path.join(allocator, &.{ output_dir, target_name });
    defer allocator.free(target_dir);

    // ── Pack manifest load + dependency-validation gate (Packs RFC §6, #441) ─
    //
    // Read every declared pack's `pack.labelle` ONCE here — BEFORE the target
    // dir is created or any project folder / plugin script is copied below —
    // then run the dependency gate: fail generation on a `depends_on` cycle or
    // a `depends_on` naming an undeclared pack/plugin. Running this early means
    // a bad graph rejects the build cheaply, without first mutating
    // `.labelle/<target>` and leaving stale output (chatgpt-codex review, #441).
    // The parsed manifests (with their owning PluginDep) stay alive for the
    // whole function via the defer below and are REUSED by the pack-scan loop
    // far down in `generate()` rather than re-read from disk. This is the
    // "generate-time validation" gate only — the depends_on ENFORCEMENT
    // (restricted per-pack module graph / `PackView` partition) is engine-side
    // #652-remainder, and the one-facet-one-owner check is mooted by #440's
    // `<pack>__` name prefix (registry names become pack-unique).
    // Load + gate the parsed manifests (moved verbatim to
    // `generate_phases`). `loadPackEntries` returns the owned list; the
    // cleanup `defer` stays HERE because the manifests are reused by the
    // pack-scan / pack-root / sidecar phases below. `validatePackGraph` runs
    // the depends_on + prefix-collision gates BEFORE the target dir is created,
    // so a bad graph rejects the build without leaving stale output (#441).
    var pack_entries = try generate_phases.loadPackEntries(allocator, cfg.plugins, game_dir);
    defer {
        for (pack_entries.items) |*e| e.deinit(allocator);
        pack_entries.deinit(allocator);
    }
    try generate_phases.validatePackGraph(allocator, pack_entries.items, cfg.plugins);

    // ── One-language-per-project policy gate (#584, RFC-LANGUAGE-PLUGINS) ─
    // Enforce the `.params.language` declaration rules (supported vocabulary,
    // at most ONE declaring plugin), every plugin/pack manifest's
    // `requires_language`, and the script-dir language scan (game root +
    // every pack source dir) — BEFORE the target dir is created, so a policy
    // violation rejects the build cheaply without leaving stale output,
    // exactly like the pack-graph gate above. Parse + validate ONLY: no
    // codegen consumes `.params.language` yet (the scripting plugin that does
    // is a separate ticket), so a clean project generates byte-identical
    // output.
    try generate_phases.validateLanguagePolicy(allocator, pack_entries.items, cfg.plugins, game_dir);

    // ── Schema-declared plugin params gate + resolution (#591) ─────────
    // Validate every plugin entry's `.params` bag against its manifest's
    // `.params_schema` and resolve the final param sets (project values +
    // schema defaults) — beside the language gate, BEFORE the target dir is
    // created, so an unknown/mistyped/missing-required param rejects the
    // build with no stale output. The resolved sets drive the staged
    // `plugin_<name>_params.zig` modules + the generated build.zig's
    // `overrideImport` wiring below; an empty list (every params-less
    // project) is a byte-identical no-op at every consumption site.
    var resolved_plugin_params = try generate_phases.resolvePluginParams(allocator, cfg.plugins, game_dir);
    defer plugin_params.freeResolvedList(allocator, &resolved_plugin_params);

    // ── Scripting splice detection (labelle-assembler#593) ─────────────
    // The consuming half of the policy above: when THE scripting plugin
    // (manifest name `scripting`) declares `.params.language`, resolve the
    // splice (plugin import name + language + embed extension) once. The
    // game root's `<language>/` dir is copied + scanned below (after the
    // target dir exists); the splice then drives the generated main's
    // registerScript calls / `scripting_enabled` flag / drainEvents tap and
    // the generated build's `-Dlanguage` dep option. Null for every project
    // without the plugin — all downstream sites are byte-identical no-ops.
    var maybe_scripting = try scripting_splice.detect(allocator, cfg.plugins, game_dir);
    // Frees the row-derived strings `detect` duped from the manifest (rev
    // 19); a no-op for the frozen-fallback / no-splice shapes (see
    // `ScriptingSplice.deinit`). Runs last — every read of `s.*` completes
    // first.
    defer if (maybe_scripting) |*s| s.deinit();

    // Dev-mode hot-reload watch path (labelle-assembler#637): the SOURCE
    // script dir as seen from the generated target dir — the generated
    // game's runtime cwd (`labelle run` → `zig build run` in
    // `.labelle/<target>/`). The watcher must poll the SOURCE tree the
    // developer edits, not the staged view (a real COPY on Windows without
    // symlink privileges — `scanner.linkDirAbs`'s fallback). Relative on
    // purpose so the embedded path survives moving the project;
    // forward-slash normalized so the emitted Zig string literal is
    // separator-safe on Windows (its file APIs accept `/`). Any failure
    // degrades to null — the emission then falls back to the cwd-relative
    // dir alone.
    //
    // Computed for every capable embed splice — INCLUDING typescript: a
    // js-only TS project (the `// @ts-check` workflow) never transpiles,
    // so its authored `.js` sources are the runnable files and it watches
    // the source tree exactly like ruby/lua (round-3 codex, PR #638). If
    // the transpile phase later ACTUALLY materializes output (`runPhase`
    // non-null, below), the path is cleared again and the watch moves to
    // the target's own dir — the discriminator is emitted-output-present,
    // never the language. Legacy dirs never splice at all
    // (`buildDepHotReload`'s legacy rationale), so no path is computed
    // for them.
    var watch_dir_rel: ?[]u8 = null;
    defer if (watch_dir_rel) |p| allocator.free(p);
    // Local pack script dirs (labelle-scripting#51) are collected LATER —
    // after `s.scripts` is populated (below), because the co-watch is
    // gated on the pack actually contributing a REGISTERED script (codex
    // P2 #642). This storage is declared here so its cleanup `defer` spans
    // the whole function; the population loop lives beside the `s.scripts`
    // assignment.
    var pack_watch_dirs: std.ArrayList(scripting_splice.PackWatchDir) = .empty;
    defer {
        for (pack_watch_dirs.items) |p| {
            allocator.free(p.from_target);
            allocator.free(p.from_root);
            allocator.free(p.name_prefix);
        }
        pack_watch_dirs.deinit(allocator);
    }
    if (maybe_scripting) |*s| {
        if (s.family == .embed and s.hot_reload_capable and !s.legacy) {
            const src_scripts_abs = try std.fs.path.join(allocator, &.{ game_dir, s.dir });
            defer allocator.free(src_scripts_abs);
            if (std.fs.path.relative(allocator, "", null, target_dir, src_scripts_abs)) |rel| {
                for (rel) |*ch| {
                    if (ch.* == '\\') ch.* = '/';
                }
                watch_dir_rel = rel;
                s.watch_dir_from_target = rel;
            } else |_| {}
        }
    }

    // ── Asset-Plugins Phase 3: studio panel descriptors (#577) ─────────
    // Validate every `studio/*.panel.jsonc` a plugin (or a pack it bundles)
    // ships, BEFORE any target is written — a malformed panel is a
    // generate-time error with a file (and line) location, so the studio
    // never renders an invalid panel from a generated project. Additive: a
    // project with no panels is a no-op.
    try panel_validate.validatePluginPanels(allocator, cfg, game_dir);

    // ── Asset-Plugins Phase 2: plugin-level `.resources` units (#576) ──
    // A decl-module plugin may declare its OWN atlases in `plugin.labelle`
    // (namespaced `<plugin>__<name>`, copied into `packs/<plugin>/assets/`). A
    // plugin is NOT a scannable pack, so these units feed ONLY the resource
    // merge + asset copy/namespace/validate below — never the pack scan / module
    // / script phases (which stay keyed on `pack_entries`). Combined with the
    // packs into `resource_entries`, they ride the exact Phase-1 machinery.
    var plugin_res_units = try generate_phases.loadPluginResourceEntries(allocator, cfg.plugins, game_dir);
    defer plugin_res_units.deinit(allocator);

    // `resource_entries` = game/nested packs ++ plugin-level resource units.
    // The merge + `processPackAssets` consume this combined view; everything
    // else consumes `pack_entries`. Empty plugin-resource list → identical to
    // `pack_entries` (byte-identity for plugins that ship no `.resources`).
    var resource_entries: std.ArrayList(generate_phases.PackEntry) = .empty;
    defer resource_entries.deinit(allocator);
    try resource_entries.ensureTotalCapacity(allocator, pack_entries.items.len + plugin_res_units.entries.items.len);
    resource_entries.appendSliceAssumeCapacity(pack_entries.items);
    resource_entries.appendSliceAssumeCapacity(plugin_res_units.entries.items);

    // ── Asset-Plugins Phase 1: merge pack `.resources` (#573) ──────────
    // Fold every pack's declared `.resources` into the game's resource list,
    // namespaced `<pack>__<name>` and repathed into the copied `packs/<pack>/…`
    // dir, so ALL downstream resource codegen (`resource_loader`,
    // `asset_wiring`, `scene_manifests`) + the scene-asset validation + lazy
    // inference below consume the pack atlases unchanged. Additive: with no
    // pack `.resources`, the merged list is byte-identical to the game's, so a
    // project without asset-bearing packs generates identical output. The astc/
    // rgba texture-path swaps above ran on the game resources only; pack
    // resources get the same sibling preference right after the merge, probed
    // against each pack's own SOURCE dir (`preferCompressedPackTextures`).
    var merged_resources = try pack_resources.mergePackResources(allocator, mutable_resources, resource_entries.items);
    defer merged_resources.deinit();
    cfg.resources = merged_resources.resources;

    // Compression parity for pack-shipped atlases (labelle-cli#315): `labelle
    // astc` converts pack-declared atlases to co-located siblings in the
    // pack's own assets/ dir, which `processPackAssets` copies wholesale into
    // the target — so preferring an existing sibling here always yields a
    // resolvable `@embedFile` path. Probes each pack's SOURCE dir (not
    // game_dir: `@libs/…`, `local:…` and cached external packs live outside
    // the game tree). Without this, an ASTC target embedded pack atlases as
    // raw PNG — the cold-start decode cost the compression epic exists to
    // remove (bit FP's sky pack, FP#618).
    try pack_resources.preferCompressedPackTextures(
        allocator,
        io,
        &merged_resources,
        mutable_resources.len,
        resource_entries.items,
        game_dir,
        cfg.asset_compression.formatFor(cfg.platform) == .astc,
    );

    try cwd.createDirPath(io, target_dir);

    // Copy game folders into target dir and scan file stems in one pass.
    // Folders that need scanning use copyAndScan; assets is copy-only.
    const prefab_names = try scanner.linkAndScan(allocator, game_dir, target_dir, "prefabs", ".jsonc");
    defer scanner.freeNames(allocator, prefab_names);

    const jsonc_scene_names = try scanner.linkAndScan(allocator, game_dir, target_dir, "scenes", ".jsonc");
    defer scanner.freeNames(allocator, jsonc_scene_names);

    // Parse each scene file's top-level manifest (assets: array + unknown-key
    // guard). Reads the *copied* scenes from target_dir so parser errors point
    // at the same files the engine will load. Hard-aborts on typos like
    // "asest" so a misspelled key cannot silently disable preloading.
    const scenes_target = try std.fs.path.join(allocator, &.{ target_dir, "scenes" });
    defer allocator.free(scenes_target);
    const scene_manifests = try scene_manifest.parseSceneDir(allocator, scenes_target, jsonc_scene_names);
    defer scene_manifest.freeManifests(allocator, scene_manifests);

    // ── Asset-Plugins Phase 1: scene auto-wiring (#575) ────────────────
    // A scene that instantiates any prefab from a pack gets that pack's
    // non-lazy resources auto-added to its asset manifest, so a scene using
    // `sky__sky_system` preloads the sky pack's atlases without hand-editing
    // `meta.assets`. Runs BEFORE `validateSceneAssets` (the added names are
    // namespaced `<pack>__<name>` entries the merge above put in the resource
    // list, so validation passes) and before lazy inference (a scene-referenced
    // resource infers lazy → scene-scoped preload). No-op when no scene
    // references a pack prefab, keeping non-pack projects byte-identical.
    try pack_resources.autoWireScenes(allocator, scene_manifests, pack_entries.items, scenes_target);

    // Reject scene `assets:` entries that don't match a resource
    // declared in project.labelle. Runs before any codegen so typos
    // like `backgroud` surface as a build error against the scene file
    // rather than a confusing "atlas not found" panic at runtime.
    // Ticket #47.
    try asset_validator.validateSceneAssets(allocator, scene_manifests, cfg.resources);

    // Resolve the implicit `lazy` default on each resource entry.
    // Explicit `lazy = true/false` wins; null falls back to `true`
    // (lazy) when the resource is referenced by any scene's `assets:`
    // list, or to `false` (eager) otherwise. The eager fallback keeps
    // unmigrated projects — the ones without `assets:` blocks — using
    // the old always-eager behavior. Ticket #48. Operates on the MERGED
    // resource list (game + pack) so pack atlases get lazy defaults too.
    try lazy_inference.resolveLazyDefaults(allocator, merged_resources.resources, scene_manifests);

    // Symlink the scripts directory; names from a shallow scan are
    // thrown away here because `script_scanner.ScriptScanner` below
    // does its own richer walk (state-directory binding, numeric
    // prefix ordering, etc.). `linkDir` gives the same layout as
    // `linkAndScan` without the redundant name collection.
    //
    // The SAME dir doubles as the script-LANGUAGE convention home
    // (labelle-engine#237): a scripting splice's `scripts/*.lua` (.rb, …)
    // live beside the Zig scripts, extension-keyed — the Zig scanner
    // collects only `.zig`, the splice collection below only the
    // language's extension, so the two layers share one structure without
    // ever seeing each other's files.
    //
    // Prune stale generated flow sidecars (#632) FIRST — against the
    // SOURCE tree, before `linkDir` stages `scripts/`. A removed/renamed
    // flow leaves an orphan `scripts/flows/<name>.zig`; if a project also
    // declares a state named `flows`, `script_scan.scanDir` below would
    // bind that orphan as a `flows`-state script and the generated game
    // would import a file the later `flow_scanner.scanAndEmit` pass
    // deletes. Pruning here — before staging — is the single correct
    // point: on the symlink path the staged `scripts/` is a symlink back
    // to the source so the delete is visible either way, but on the
    // Windows / no-symlink fallback `linkDir` COPIES the tree
    // (`scanner.copyDirRecursiveAbs`), so the orphan must be gone from the
    // source before the copy or it survives in the staged target (codex
    // #639 review).
    try flow_scanner.pruneStaleSidecars(allocator, game_dir);

    try scanner.linkDir(allocator, game_dir, target_dir, "scripts");

    // ── Scripting splice: collect the language sources (#593/#237) ─────
    // THREE collections, concatenated components → events → scripts onto
    // the splice (the registration order — each layer's constants must
    // exist when the next loads):
    //
    //   1. `components/*.<ext>` declaration files (#237's refinement:
    //      declarations live where their KIND lives — beside the Zig
    //      components; `collectComponentEmbeds`, plain alphabetical, no
    //      ordering prefixes). They register FIRST so the view constants
    //      they define exist by the time scripts load.
    //   2. `events/*.<ext>` declaration files (labelle-engine#772, the
    //      same where-their-kind-lives convention beside the Zig events;
    //      `collectEventEmbeds`, identical mechanics). They register
    //      after components and before scripts so the event-name
    //      constants they define (`HungerFeed = Labelle.event ...`)
    //      exist by the time scripts load.
    //   3. The script dir `detect` resolved — `scripts/` (top level only,
    //      Zig ordering convention: numeric prefixes first, stripped from
    //      the registered stem) or the deprecated legacy dir on the
    //      one-release grace fallback (verbatim pre-#237 recursive scan,
    //      plain sorted stems). `collectEmbedScripts` places/reuses the
    //      target link so the generated main's `@embedFile("<file>")`
    //      resolves (for `scripts/` that's the link just placed above —
    //      shared with the Zig scanner; for `components/` and `events/`
    //      it's the links placed just below).
    //
    // Entries carry TARGET-RELATIVE files. Missing dirs collect empty —
    // the plugin is wired, nothing embeds. Game root only;
    // `requires_language` pack dirs come later. Authored `.ts` sources
    // are NOT collected (the collections are embed-extension-only) — the
    // transpile phase below (labelle-engine#745, ordered after deps
    // staging) checks + emits them and REPLACES the script-dir entries
    // with the materialized dir's re-collection (the components entries
    // survive the swap). (Language files in `scripts/<state>/` subdirs
    // already failed generate inside `detect` — state subdirs are
    // Zig-only until the scripting Controller grows state awareness; a
    // `components/*.ts` authoring source is `collectComponentEmbeds`'
    // pointed error.)
    //
    // EMBED family only: a native-compiled language (rust) never embeds —
    // its sources are staged over the plugin package's crate instead
    // (`stageNativeSources` below, AFTER `createDepsLinks` staged that
    // package), and `scripts` stays empty so the registerScript
    // builders emit nothing.
    var component_embeds: ?[]scripting_splice.EmbedScript = null;
    defer if (component_embeds) |ce| scripting_splice.freeEmbedScripts(allocator, ce);
    var event_embeds: ?[]scripting_splice.EmbedScript = null;
    defer if (event_embeds) |ee| scripting_splice.freeEmbedScripts(allocator, ee);
    var script_embeds: ?[]scripting_splice.EmbedScript = null;
    defer if (script_embeds) |se| scripting_splice.freeEmbedScripts(allocator, se);
    // The emission slice: components ++ events ++ scripts, SHALLOW
    // (entries owned by the three collections above) — freed as a bare
    // slice, never through freeEmbedScripts.
    var combined_embeds: ?[]scripting_splice.EmbedScript = null;
    defer if (combined_embeds) |cb| allocator.free(cb);
    // The native family's declaration-file set (components/*.<ext> ++
    // events/*.<ext>), fed to the generic `.languages` declare tool
    // (RFC-LANGUAGE-PLUGINS rev 17, rust #774). SHALLOW over
    // `component_embeds`/`event_embeds` (freed as a bare slice). Unlike the
    // embed family this is NOT assigned to `s.scripts` — a native splice
    // embeds nothing; gameplay scripts are staged for the compiler
    // (`stageNativeSources`), never fed to the declare probe (they would not
    // compile as standalone declaration modules).
    var native_decl_embeds: ?[]scripting_splice.EmbedScript = null;
    defer if (native_decl_embeds) |nd| allocator.free(nd);
    if (maybe_scripting) |*s| {
        if (s.family == .embed) {
            component_embeds = try scripting_splice.collectComponentEmbeds(allocator, game_dir, s.*);
            event_embeds = try scripting_splice.collectEventEmbeds(allocator, game_dir, s.*);
            script_embeds = try scripting_splice.collectEmbedScripts(allocator, game_dir, target_dir, s.*);
            combined_embeds = try scripting_splice.concatEmbeds3(allocator, component_embeds.?, event_embeds.?, script_embeds.?);
            s.scripts = combined_embeds.?;

            // Local pack script dirs to co-watch (labelle-scripting#51):
            // now that `s.scripts` (the REGISTERED set) is known, collect
            // the co-watch pair for every `local:`/`@`-pinned pack that
            // ships a `scripts/` SOURCE dir AND contributes at least one
            // registered script (codex P2 #642 — a pack the assembler
            // never embedded has no reload target). Published/cached packs
            // and nested plugin-bundled packs (empty `.repo`, not
            // `isLocal`) are excluded. Each pair carries the same
            // primary/fallback candidates the game-dir watch uses
            // (coderabbit #642). OutOfMemory propagates (gemini #642);
            // only a genuinely-absent `scripts/` dir degrades to skip.
            if (s.hot_reload_capable and !s.legacy) {
                for (pack_entries.items) |*e| {
                    if (!e.plugin.isLocal()) continue;
                    // Gate on the ACTUAL registered set (`s.scripts`), not a
                    // directory scan (codex round-2 #642): watch a pack only
                    // when it contributes an embed the generated main
                    // `registerScript`s. Pack LANGUAGE scripts are not
                    // collected into `s.scripts` yet (see the note below), so
                    // this is currently always false — the watch activates
                    // automatically once that collection lands.
                    if (!scripting_splice.packHasRegisteredScript(s.scripts, e.manifest.name)) continue;
                    const pack_src = try e.resolveSrcDir(allocator, game_dir);
                    defer allocator.free(pack_src);
                    // The reload namespace the pack's scripts register under
                    // (`<pack>__`) — emitted as the `watchDirNamed` prefix so
                    // the watcher keys each reload onto the pack's namespaced
                    // registration, never the game's same-stem script.
                    var pfx_buf: [128]u8 = undefined;
                    const sanitized = scan.packNamespacePrefix(e.manifest.name, &pfx_buf);
                    var pfx_full_buf: [160]u8 = undefined;
                    const name_prefix = std.fmt.bufPrint(&pfx_full_buf, "{s}__", .{sanitized}) catch continue;
                    if (try scripting_splice.packWatchDirs(allocator, game_dir, target_dir, pack_src, name_prefix)) |pair| {
                        errdefer {
                            allocator.free(pair.from_target);
                            allocator.free(pair.from_root);
                            allocator.free(pair.name_prefix);
                        }
                        try pack_watch_dirs.append(allocator, pair);
                    }
                }
                s.pack_watch_dirs = pack_watch_dirs.items;
            }
        } else {
            // Native family (rust): collect ONLY the declaration files. The
            // Zig `components/`/`events/` links (below) expose them in the
            // target, so the declare tool's `target_dir/<file>` argv resolves.
            component_embeds = try scripting_splice.collectComponentEmbeds(allocator, game_dir, s.*);
            event_embeds = try scripting_splice.collectEventEmbeds(allocator, game_dir, s.*);
            const nd = try allocator.alloc(scripting_splice.EmbedScript, component_embeds.?.len + event_embeds.?.len);
            @memcpy(nd[0..component_embeds.?.len], component_embeds.?);
            @memcpy(nd[component_embeds.?.len..], event_embeds.?);
            native_decl_embeds = nd;
        }
    }

    const scripts_target = try std.fs.path.join(allocator, &.{ target_dir, "scripts" });
    defer allocator.free(scripts_target);

    var script_scan = script_scanner.ScriptScanner.init(allocator, cfg.states);
    defer script_scan.deinit();
    try script_scan.scanDir(scripts_target);
    // NOTE: `script_scan.getEntries()` is deliberately called AFTER the
    // plugin-shipped-scripts loop below (`scanPluginDir` appends more
    // entries and can reallocate the backing buffer). The final capture
    // happens just before `generateMainZigFromTemplate`.

    const component_names = try scanner.linkAndScan(allocator, game_dir, target_dir, "components", ".zig");
    defer scanner.freeNames(allocator, component_names);

    const hook_names = try scanner.linkAndScan(allocator, game_dir, target_dir, "hooks", ".zig");
    defer scanner.freeNames(allocator, hook_names);

    const event_names = try scanner.linkAndScan(allocator, game_dir, target_dir, "events", ".zig");
    defer scanner.freeNames(allocator, event_names);

    const enum_names = try scanner.linkAndScan(allocator, game_dir, target_dir, "enums", ".zig");
    defer scanner.freeNames(allocator, enum_names);

    const view_names = try scanner.linkAndScan(allocator, game_dir, target_dir, "views", ".zon");
    defer scanner.freeNames(allocator, view_names);

    const gizmo_names = try scanner.linkAndScan(allocator, game_dir, target_dir, "gizmos", ".zon");
    defer scanner.freeNames(allocator, gizmo_names);

    const animation_names = try scanner.linkAndScan(allocator, game_dir, target_dir, "animations", ".zon");
    defer scanner.freeNames(allocator, animation_names);

    // Copy-only folders (no scanning needed)
    try scanner.linkDir(allocator, game_dir, target_dir, "assets");

    // Inject the bundled default "Labelle" app icon when the project
    // declares no `app_icon` of its own (issue #66). A project that
    // sets `app_icon` ships its own icon, so the default is suppressed.
    // Runs after the assets dir is linked so the default lands beside
    // the project's own copied assets.
    try app_icon.injectDefaultIcon(allocator, cfg, target_dir);

    // `tests/` mirrors the project source tree (e.g. `tests/components/foo.zig`
    // tests `components/foo.zig`). Linked + scanned so the generated
    // `__tests_root.zig` wrapper can `_ = @import(...)` each test file.
    // Missing `tests/` returns an empty list and the wrapper is just an
    // empty `test {}` block — `zig build test` becomes a no-op.
    const test_names = try scanner.linkAndScan(allocator, game_dir, target_dir, "tests", ".zig");
    defer scanner.freeNames(allocator, test_names);

    // ── Plugin-declared convention directories ────────────────────────
    // Each plugin may ship a `plugin.labelle` declaring extra directories to
    // copy/scan from the game project (see `docs/RFC-plugin-manifest.md`).
    // Moved verbatim to `generate_phases.copyPluginConventionDirs` — duplicate
    // dir claims across plugins are a hard error; all scratch/manifest memory
    // is owned + freed inside the phase.
    try generate_phases.copyPluginConventionDirs(allocator, cfg.plugins, game_dir, target_dir);

    // ── Plugin-shipped scripts (RFC-plugin-controllers §2, step-1 half 3) ─
    //
    // A plugin can ship its own `scripts/` directory that the assembler
    // copies into the generated build alongside the game's own `scripts/`.
    // These are discovered via a convention — any plugin that has a
    // top-level `scripts/` dir in its cached package contributes scripts —
    // rather than via an explicit `plugin.labelle` entry, because `scripts`
    // is a reserved convention name (see RESERVED_DIR_NAMES) that the
    // plugin manifest already forbids plugins from claiming.
    //
    // Layout in the generated target:
    //   <target>/scripts/                         ← game's own scripts (unchanged)
    //   <target>/scripts/.plugin_<name>/<rel>     ← each plugin's scripts,
    //                                               isolated per plugin so
    //                                               they form their own
    //                                               numeric-prefix scope
    //
    // Scanning is driven by the `ScriptScanner` via `scanPluginDir`
    // below — each plugin's scripts form their own numeric-prefix
    // namespace, so the duplicate-prefix validator treats each plugin
    // block as independent. Cross-plugin prefix collisions are
    // impossible by construction. Game-vs-plugin collisions are also
    // impossible — the game scripts live under `scripts/` while plugin
    // scripts live under `scripts/.plugin_<name>/`, which the scanner
    // treats as a different namespace.
    //
    // Plugins without a `scripts/` dir contribute nothing — backward-compat
    // with every existing plugin (labelle-fsm, labelle-pathfinding today).
    // Both `copyAndScanAbs` and `scanPluginDir` silently no-op on a
    // missing source dir, so no explicit probe is needed here.
    //
    // Moved verbatim to `generate_phases.copyPluginShippedScripts`. Light
    // packs (in `pack_entries`) are scanned via `scanPackScriptsAt` at their
    // `.plugins` declaration-order position (interleaved with decl-module
    // plugins) so the scanner's `plugin_index` reflects `.plugins` order — a
    // separate later loop would break per-state script ordering (#487/#494).
    try generate_phases.copyPluginShippedScripts(allocator, &script_scan, cfg.plugins, pack_entries.items, game_dir, target_dir);

    // ── Pack dir-scan (Packs RFC §4, labelle-assembler#439) ────────────
    //
    // A *pack* is the light, directory-scanned form of a plugin: instead of
    // contributing components/events/prefabs via decl-modules, it drops
    // game-convention files into `components/ events/ prefabs/ hooks/` and
    // ships a thin `pack.labelle` whose scalar `.convention_dirs =
    // .copy_and_scan` says "scan all my convention dirs like the game root".
    //
    // For every plugin that carries a `pack.labelle`, copy its convention
    // subdirs into `<target>/packs/<name>/<subdir>/` and record the scanned
    // stems. The codegen block-writers then register those stems into the
    // SAME registries the game root feeds (the unified set) — see
    // `main_template.pack_scans`. Plugins WITHOUT a `pack.labelle` (every
    // decl-module plugin today) are skipped, so this is fully back-compat.
    //
    // Scope (#439 + #440): components + events + prefabs + hooks are scanned
    // and registered under the invisible `<pack>__<Name>` prefix (§4), and a
    // pack's own prefab JSONC has its local component refs rewritten to the
    // prefixed form (`scanPack` → `rewritePackPrefabRefs`).
    //
    // The per-pack `PackView` registry partition (#498, "wire the wall") is now
    // GENERATED assembler-side: the component-registry block emits a
    // `<pack>_pack_view = engine.PackView(Components, &.{…})` name-lens over the
    // single full registry for every pack (see `writePackViewsBlock`).
    // `Components` stays one flat registry (it feeds the serializer / bridge);
    // the view is the pack's sanctioned string-keyed surface. #498 PR 2 wired
    // the per-pack Zig MODULE graph: every pack's files belong to their own
    // `pack__<prefix>` module (rooted at the generated `__pack_root.zig`,
    // written below) with a restricted import table — no `game` shim, no
    // sibling packs — so a cross-pack path import is a compile error, not a
    // lint. PR 3 wired `@import("pack").Registry` (the sanctioned
    // string-keyed surface, via the `@import("root")` bridge); PR 4 wired
    // `exposes` surface modules + `depends_on` import narrowing. The wall
    // is COMPLETE — see `docs/packs.md` for the full contract. What stays
    // lint-only by design: the `game.ComponentRegistry` anytype hole,
    // `.global`-facet write discipline, and event direction (`labelle
    // check`, src/check.zig).
    //
    // The pack manifests reused below were parsed ONCE near the top of
    // `generate()` (`pack_entries`), where the dependency-validation gate AND
    // the sanitized-prefix collision gate both run — a bad `depends_on` graph
    // or two packs whose names sanitize to the same `<pack>__` prefix reject
    // the build before any target writes, rather than re-reading `pack.labelle`
    // here.
    // Moved verbatim to `generate_phases.loadPackScans` — returns the owned
    // list; the cleanup `defer` stays HERE because `pack_scans` is reused by
    // the pack-root, name-collision, module-wiring, and sidecar phases below.
    // A pack's OWN per-frame system is copied by the `cfg.plugins` script loop
    // above (declaration order, #494), NOT here.
    var pack_scans = try generate_phases.loadPackScans(allocator, pack_entries.items, game_dir, target_dir);
    defer {
        for (pack_scans.items) |*p| p.deinit(allocator);
        pack_scans.deinit(allocator);
    }

    // ── Asset-Plugins Phase 1: copy + namespace + validate pack assets ──
    // Runs AFTER `loadPackScans` copied each pack's convention dirs (its
    // prefabs are now under `<target>/packs/<pack>/prefabs/`). For every pack
    // declaring `.resources`: copy its `assets/` into the target, rewrite its
    // atlas frame keys to `<pack>/<frame>` + the pack's own prefab `sprite_name`
    // refs to match (#574), then validate every pack sprite ref resolves to a
    // shipped or `depends_on_resources` frame — a dangling ref is a
    // generate-time error, not a silent runtime blank (#575). No-op for packs
    // without `.resources`.
    try pack_resources.processPackAssets(allocator, resource_entries.items, cfg.resources, game_dir, target_dir);

    // Injectivity gate (#440 / chatgpt-codex events L164): the `<pack>__<name>`
    // scheme is not injective on its own — two distinct (pack, name) pairs can
    // fold to the same emitted symbol (e.g. pack `a` + `b__hit` and pack `a__b`
    // + `hit` both emit `a__b__hit`), which the sanitized-prefix gate above
    // can't see. Validate the fully-qualified component/event/prefab names the
    // block-writers will emit — over BOTH the game root and every pack — and
    // fail before any main.zig is written.
    try pack_validate.checkEmittedNameCollisions(
        allocator,
        component_names,
        event_names,
        prefab_names,
        pack_scans.items,
    );

    // ── Per-pack module roots (assembler#498 PR 2, "wire the wall") ────
    //
    // Generate `<target>/packs/<name>/__pack_root.zig` for every pack: the
    // root of the pack's OWN build-system module, re-exporting each scanned
    // component/event/hook/script so the generated main.zig reaches pack
    // contents exclusively through `@import("pack__<prefix>")`. The pack's
    // files thereby stop being ROOT-module members — a path import of any of
    // them from main.zig (or a relative escape from another pack) is now the
    // "file exists in two modules" compile error. That module boundary — not
    // the `labelle check` lint — is the enforcement layer the Packs epic
    // (labelle-engine#650) deferred.
    //
    // Pack SCRIPT entries were registered by the `cfg.plugins` loop above
    // (`scanPackScriptsAt`, declaration order, #494), so the scanner already
    // holds every pack script: filter by the `import_base == ""` pack marker
    // + the owning pack's name, and re-root each `packs/<name>/scripts/<rel>`
    // path at the module root (`scripts/<rel>`).
    // Moved verbatim to `generate_phases.writePackModuleRoots` — writes each
    // pack's `__pack_root.zig` + exposes-narrowed `__surface.zig`, validating
    // the `exposes` surface against shipped files before any build. All scratch
    // freed inside the phase.
    try generate_phases.writePackModuleRoots(allocator, pack_scans.items, pack_entries.items, &script_scan, target_dir);

    // ── Module-plugin filter — light packs are dir-scan-only (#481) ────
    //
    // A *light pack* (module-less, carrying `pack.labelle`) contributes to
    // the build ONLY via the dir-scan registry entries collected above
    // (`pack_scans`): its components/events/prefabs/hooks are already
    // copied, `<pack>__`-namespaced (#440), validated (#441), and wired
    // into the SAME unified registries the game root feeds (#439). It ships
    // NO importable Zig module and has NO `build.zig`, so it must NOT appear
    // in any codegen/build site that emits `@import("<name>")` or a
    // `b.dependency("labelle_<name>", …)` — the ComponentRegistryWithPlugins
    // / SystemRegistry args, plugin controllers/events, the build.zig module
    // graph, and the build.zig.zon deps. Emitting either for a module-less
    // pack fails to resolve and breaks `labelle build` (the #481 gap).
    //
    // Only genuine decl-module plugins (a `plugin.labelle` with `src/root.zig`
    // exports) get the module import + build dep. Every light pack carries a
    // `pack.labelle` and therefore appears in `pack_entries` (parsed near the
    // top of `generate()`), so membership there IS the light-pack predicate.
    //
    // Build a filtered plugin list and run the module-emitting phase against
    // a `cfg` copy whose `.plugins` excludes light packs (`cfg_modules`). The
    // scan/copy loops that need the FULL declared list already ran above, and
    // the project-description sidecars (flow catalog, feature manifest) keep
    // the original `cfg` so they still describe every declared plugin/pack.
    var pack_names_for_filter: std.ArrayList([]const u8) = .empty;
    defer pack_names_for_filter.deinit(allocator);
    try pack_names_for_filter.ensureTotalCapacity(allocator, pack_entries.items.len);
    for (pack_entries.items) |e| pack_names_for_filter.appendAssumeCapacity(e.plugin.name);

    const module_plugins = try declModulePlugins(allocator, cfg.plugins, pack_names_for_filter.items);
    defer allocator.free(module_plugins);
    // A `cfg` view whose `.plugins` is the decl-module subset. Passed to every
    // site that emits a Zig-module import or a build-file module dependency.
    var cfg_modules = cfg;
    cfg_modules.plugins = module_plugins;

    // ── Flow-node discovery (RFC-FLOW-VOCABULARY phase 2) ──────────────
    //
    // Discover `pub const FlowNodes` + `pub const PinStyles` +
    // `pub const Coercions` decls across plugins AND game-script modules
    // (RFC §5). Hoisted ABOVE the flow scan below because flow codegen
    // needs the FlowNode list to build the `CustomNodeRegistry` it
    // consults to lower `CustomNode` nodes — without it every
    // `CustomNode` reference errors as `UnknownFlowNode`
    // (labelle-assembler#238). The same discovery result is reused for
    // the `main.zig` emission later (no second walk).
    //
    // Discovery runs on the *real* script entries (`getEntries()`), not
    // the merged list that includes the synthetic flow-derived entries:
    // the generated `scripts/flows/*.zig` files don't declare
    // `FlowNodes`, so they contribute zero flow nodes and feeding them
    // in would be pointless (and they don't exist yet at this point in
    // the pipeline anyway). By here every game + plugin-shipped script
    // has already been fed to the scanner (the plugin-scripts loop above
    // runs first), so `getEntries()` is the complete real-script set.
    //
    // Game-script entries resolve against the copied source under
    // `<target>/scripts/<rel_path>` so the discovery walks the exact
    // files the generated `main.zig` will `@import`. Plugin-shipped
    // scripts are skipped here — they're covered by their containing
    // plugin's `src/root.zig` walk in the same pass.
    const scripts_target_for_flow = try std.fs.path.join(allocator, &.{ target_dir, "scripts" });
    defer allocator.free(scripts_target_for_flow);
    var plugin_flow_decls = try main_zig.discoverPluginFlowDecls(
        allocator,
        // Light packs contribute no decl-module `FlowNodes` (they have no
        // `src/root.zig`); walk only the decl-module plugins (#481).
        cfg_modules,
        game_dir,
        scripts_target_for_flow,
        script_scan.getEntries(),
    );
    defer plugin_flow_decls.deinit();

    // ── Flow codegen (#94, Part B) ─────────────────────────────────────
    //
    // Recursively walk `<game>/scripts/flows/**` for `*.flow.jsonc`,
    // emit a sibling `.zig` per file via the `flow_codegen` sub-package
    // (shipped from labelle-gui), and append a synthetic `ScriptEntry`
    // for each so
    // the existing AllScripts block picks them up naturally on the
    // next emit pass. The tests target shares this codepath — flows
    // are global (state-less) scripts and contribute to both exe and
    // tests builds. Empty `scripts/flows/` is a silent no-op.
    // flow_scanner already wrote a per-file `flows/<rel>: <err>`
    // diagnostic to stderr; propagate the typed error so `generate`
    // exits non-zero. The discovered FlowNode list is threaded in so the
    // scanner can build the `CustomNodeRegistry` for `CustomNode`
    // lowering (#238).
    var flow_result = try flow_scanner.scanAndEmit(allocator, game_dir, target_dir, plugin_flow_decls.flow_nodes);
    defer flow_result.deinit();

    // Generate build.zig.zon
    // `cfg_modules` (not `cfg`): a light pack has no `build.zig`/module, so it
    // must not become a `.labelle_<name> = .{ .path }` dep (#481).
    const zon = try build_files.generateBuildZigZon(allocator, cfg_modules, target_dir, output_dir, game_dir, .{
        // The tests target runs second — additive merge so the exe
        // target's deps (chosen-backend, plugins) survive. Issue #83.
        .recreate_deps = !is_tests_target,
        // manifest-v2 cutover: when the backend ships a v2 manifest, key the
        // backend dep entry off its `dep_name` + drive its `root_build_deps`
        // (design §3). Null → v1/enum, byte-unchanged.
        .backend_manifest_name = backend_manifest_name,
    });
    defer allocator.free(zon);
    try scanner.writeFile(target_dir, "build.zig.zon", zon);

    // ── Script-declared components + events: declare extraction (#585,
    // labelle-engine#772) ───────────────────────────────────────────────
    // RFC-LANGUAGE-PLUGINS revs 6-7 (epic labelle-engine#237), the second
    // consumer of the scripting splice: run the LANGUAGE's declare runner
    // (`DECLARE_RUNNERS` — lua + ruby today) over the collected sources
    // (`components/*.<ext>` declarations first, then `events/*.<ext>`
    // declarations, then the script dir's files — `scripts/`, or the
    // legacy dir on the grace fallback), codegen the declared components
    // into `scripting_components.zig` and the declared events into
    // `scripting_events.zig`, and thread both onto the splice so the
    // component-registry block registers components by name and the
    // game-events block emits one union variant per event.
    // Ordered AFTER build.zig.zon generation — `createDepsLinks` just
    // staged the plugin package under `<output>/deps/labelle-<name>/`,
    // which is where the language's runner is built from (`zig build
    // <step_name>` per `scripting_declare.DECLARE_RUNNERS`; see the
    // exec-slice doc + the #586 cross-ref) —
    // and BEFORE main.zig emission, which consumes `declared_components`.
    // Null/no-op for: no splice, no scripts, or scripts declaring nothing
    // — those emit byte-identical output (and drop a stale generated file).
    // ── Declaration-file transpile, BEFORE declare (RFC-LANGUAGE-PLUGINS
    // rev 20 option (b), labelle-engine#773) ─────────────────────────────
    // For a transpile-row embed language (typescript) the declare tool is a
    // toolchain-agnostic embedded-VM evaluator that receives the EMITTED
    // `.js`: the assembler transpiles `components/*.ts` + `events/*.ts` into
    // the target HERE — materializing those dirs, emitting `.js` beside the
    // authored sources — so the declare phase below reads
    // `<target>/components/*.js` + `<target>/events/*.js`, and the runtime
    // `@embedFile` finds the same output. No-op for lua/ruby (no transpile
    // row) and native (never reaches here). Idempotent, shared toolchain
    // cache — pulls `ensureTscTool` ahead of the later gameplay-script
    // transpile, warming the cache it reuses.
    if (maybe_scripting) |*s| {
        if (s.family == .embed) {
            try scripting_transpile.transpileDeclDirs(allocator, .{
                .plugins = cfg.plugins,
                .plugin_name = s.plugin_name,
                .language = s.language,
                .dir = s.dir,
                .legacy = s.legacy,
                .extension = s.extension,
                .game_dir = game_dir,
                .output_dir = output_dir,
                .target_dir = target_dir,
                .project_dir = game_dir,
                .component_names = component_names,
                .pack_scans = pack_scans.items,
                .transpile = s.transpile,
            });
        }
    }

    var declare_schema: ?scripting_declare.Schema = null;
    defer if (declare_schema) |*sch| sch.deinit();
    if (maybe_scripting) |*s| {
        // The declare tool's input files, TARGET-RELATIVE (the `EmbedScript.file`
        // column — not stems, whose ordering prefixes are stripped, so only the
        // file column rebuilds the path). For the EMBED family: every collected
        // source (`components/*.<ext>` declarations, then `events/*.<ext>`, then
        // the script dir — in-script chunk-scope declarations are legal, all
        // feed ONE schema with the runner owning duplicate detection). For the
        // NATIVE family (rev 17, rust #774): ONLY the declaration files
        // (`native_decl_embeds` = components ++ events); `s.scripts` is empty
        // (nothing embeds) and gameplay scripts are compiler-staged, never fed
        // to the declare probe. Either way the generic/hardcoded runPhase gets
        // components-first order.
        // NATIVE (rust/crystal): components ++ events only (`native_decl_embeds`).
        // TRANSPILE embed (typescript, rev 20 option (b)): also components ++
        // events only — the transpiled `.js` declaration files just emitted
        // above; gameplay scripts are transpiled AFTER declare and reference
        // declarations BY NAME, never re-declaring, so they never feed the
        // declare tool. Plain embed (lua/ruby): the whole collection
        // (components ++ events ++ scripts — in-script chunk-scope
        // declarations are legal, and the constant ledger needs the scripts).
        const is_transpile = s.transpile != null or scripting_splice.transpileSource(s.language) != null;
        var decl_only_embeds: ?[]scripting_splice.EmbedScript = null;
        defer if (decl_only_embeds) |d| allocator.free(d);
        const declare_inputs: []const scripting_splice.EmbedScript = if (s.family == .native)
            (native_decl_embeds orelse &.{})
        else if (is_transpile) blk: {
            const ce = component_embeds orelse &.{};
            const ee = event_embeds orelse &.{};
            const d = try allocator.alloc(scripting_splice.EmbedScript, ce.len + ee.len);
            @memcpy(d[0..ce.len], ce);
            @memcpy(d[ce.len..], ee);
            decl_only_embeds = d;
            break :blk d;
        } else s.scripts;
        const script_files = try allocator.alloc([]const u8, declare_inputs.len);
        defer allocator.free(script_files);
        for (declare_inputs, script_files) |sc, *f| f.* = sc.file;
        // The events-dir subset rides along separately (labelle-engine
        // #772): the phase's events gates (`events_min_pin` floor,
        // no-runner hard error, declares-nothing error) fire on these
        // files specifically — they're already IN `script_files` above,
        // so the runner argv is untouched.
        const event_files = try allocator.alloc([]const u8, if (event_embeds) |ee| ee.len else 0);
        defer allocator.free(event_files);
        if (event_embeds) |ee| {
            for (ee, event_files) |sc, *f| f.* = sc.file;
        }
        declare_schema = try scripting_declare.runPhase(allocator, .{
            .plugins = cfg.plugins,
            .plugin_name = s.plugin_name,
            .language = s.language,
            .script_files = script_files,
            .event_files = event_files,
            .output_dir = output_dir,
            .target_dir = target_dir,
            .project_dir = game_dir,
            .component_names = component_names,
            .event_names = event_names,
            .pack_scans = pack_scans.items,
        });
        if (declare_schema) |sch| {
            s.declared_components = sch.components;
            s.declared_events = sch.events;
        }
    }

    // ── TS→JS transpile: check + emit at generate (labelle-engine#745) ─
    // The third consumer of the scripting splice: when the splice's
    // language carries a transpile row (typescript's `.ts`) AND the
    // game's RESOLVED script dir (`scripts/` — the #237 convention — or
    // the legacy `ts/` on the grace fallback; the phase follows
    // `splice.dir`/`legacy` either way) actually holds such sources, run
    // the fetched TS 7 native compiler over them — type errors fail
    // generate with tsc's diagnostics relayed — and swap the splice's
    // entries for the MATERIALIZED target dir's re-collection
    // (`collectEmbedScriptsAbs`: copied game tree + emitted `.js`, same
    // ordering/stripping rules as the first collection; the coexisting
    // Zig scripts ride the materialized copy so their generated
    // `@import("scripts/…")`s keep resolving). Ordered like the declare
    // phase (deps just staged — the plugin package's shipped
    // contract/labelle.d.ts feeds the generated tsconfig) and BEFORE
    // main.zig emission, which consumes `scripts`. Null for every skip
    // shape (no transpile row; no `.ts` sources — the need probe, so
    // `.js`-only projects never fetch the toolchain and keep the plain
    // symlink layout, byte-identical output). The swap replaces only the
    // SCRIPT-DIR entries — the components-first prefix survives (the
    // phase never touches `components/`).
    if (maybe_scripting) |*s| {
        if (try scripting_transpile.runPhase(allocator, .{
            .plugins = cfg.plugins,
            .plugin_name = s.plugin_name,
            .language = s.language,
            .dir = s.dir,
            .legacy = s.legacy,
            .extension = s.extension,
            .game_dir = game_dir,
            .output_dir = output_dir,
            .target_dir = target_dir,
            .project_dir = game_dir,
            .component_names = component_names,
            .pack_scans = pack_scans.items,
            .declared_components = s.declared_components,
            .transpile = s.transpile,
        })) |transpiled| {
            if (script_embeds) |old| scripting_splice.freeEmbedScripts(allocator, old);
            script_embeds = transpiled;
            // Compute-then-swap: concatEmbeds3 is fallible, and freeing the
            // old slice first would leave `combined_embeds` dangling across
            // the try — the deferred free would double-free on that error
            // path. The declaration-dir prefixes (components ++ events)
            // survive the swap — the phase materializes only the script dir.
            const recombined = try scripting_splice.concatEmbeds3(allocator, component_embeds.?, event_embeds.?, transpiled);
            if (combined_embeds) |cb| allocator.free(cb);
            combined_embeds = recombined;
            s.scripts = recombined;
            // Dev-mode hot reload (#637, round-3 codex): output was REALLY
            // materialized, so the watch moves to the target's own dir —
            // the source `.ts` can never match the watcher's `.js` filter.
            // Clear the source-relative path computed above; the emission
            // keys on `transpile_emitted` (js-only TS projects never reach
            // here and keep the ruby/lua-style source watch).
            s.transpile_emitted = true;
            s.watch_dir_from_target = null;
        }
    }

    // ── Native-language game-source staging (labelle-engine#741) ───────
    // The native family's counterpart of the embed link above: LINK the
    // game's `<dir>/` (`scripts/` — the #237 convention; the legacy
    // `rust/` on the grace fallback) OVER the scripting plugin's staged
    // package (`deps/labelle-<name>/native/src/game`, replacing the
    // shipped placeholder — `scanner.linkDirAbs`, the same live-view
    // primitive `linkAndScan` gives embed script dirs), so the plugin's
    // `.language_builds` step (cargo) compiles the GAME's CURRENT
    // scripts into the staticlib the build wiring below links — edits to
    // scripts/*.rs flow into the next `zig build` without a re-generate.
    // `scripts/mod.rs` is the crate's game-module root.
    // Ordered like the declare phase: AFTER build.zig.zon generation
    // (`createDepsLinks` just staged the package) and BEFORE the
    // plugin-build-steps wiring resolves `{package}`. Hard-errors when
    // deps staging fell back to the shared plugin cache — game sources
    // are never placed there (see `stageNativeSources`' doc). Runs on
    // the tests-target pass too (deps survive it un-restaged; the
    // correct-link reconcile is a no-op).
    if (maybe_scripting) |s| {
        if (s.family == .native) {
            try scripting_splice.stageNativeSources(allocator, game_dir, output_dir, s);

            // Dev `.csproj` for IDE support (labelle-assembler#617): a csharp
            // game is ALSO a first-class C# project the author opens in Visual
            // Studio / Rider / VS Code — IntelliSense + build-in-place over the
            // game's scripts/ + components/ + events/ against the shipped
            // Labelle surface. Emitted AFTER staging so the resolved plugin
            // package (whose native-csharp/src the project references) is on
            // disk. Purely a dev aid — the real build stays the
            // `.language_builds` `dotnet publish` this splice already drives.
            if (std.mem.eql(u8, s.language, "csharp")) {
                const plugin_pkg = try scripting_declare.resolvePluginPackageDir(
                    allocator,
                    cfg.plugins,
                    s.plugin_name,
                    output_dir,
                    game_dir,
                );
                defer allocator.free(plugin_pkg);
                const plugin_src = try std.fs.path.join(allocator, &.{ plugin_pkg, "native-csharp", "src" });
                defer allocator.free(plugin_src);
                try scripting_splice.emitCsharpDevProject(allocator, game_dir, cfg.name, plugin_src);
            }
        }
    }

    // Embedded-tilemap registrations (T2 Phase 4 + T3 #561/#562 + #585).
    // AFTER `loadPackScans` so the prefab scan (assembler#561) sees the
    // staged pack prefab JSONC and pack-registered `Tilemap` (assembler#562),
    // and AFTER the declare phase so a SCRIPT-DECLARED `Tilemap` joins the
    // built-in-override decision exactly like a `components/Tilemap.zig`
    // (engine C2). The declare phase itself can't move up — it needs
    // `createDepsLinks` (build.zig.zon generation above) to have staged the
    // plugin package — so the collection moved down here instead; nothing
    // between the old spot (right after `loadPackScans`) and this one reads
    // the registrations or rewrites the prefab JSONC / `.tmx` files the scan
    // consumes, and the only consumer is main.zig emission far below.
    const declared_component_names: []const []const u8 = blk: {
        const sch = declare_schema orelse break :blk &.{};
        const names = try allocator.alloc([]const u8, sch.components.len);
        for (sch.components, names) |comp, *slot| slot.* = comp.name;
        break :blk names;
    };
    defer allocator.free(declared_component_names);
    const tilemap_registrations = try tilemap_phase.collectRegistrations(allocator, target_dir, scene_manifests, component_names, declared_component_names, prefab_names, pack_scans.items);
    defer tilemap_scan.freeRegistrations(allocator, tilemap_registrations);

    // labelle-assembler#240 Gap 2 — game scripts exporting `FlowNodes`
    // must be promoted to named build modules so the same file isn't a
    // member of both the root (main.zig `AllScripts`) and `game` (shim
    // `PluginFlowNodes`) modules. Derive the dedup'd set from the same
    // discovered FlowNode list the shim + main.zig consume.
    const promoted_scripts = try main_zig.collectPromotedScripts(allocator, plugin_flow_decls.flow_nodes);
    defer main_zig.freePromotedScripts(allocator, promoted_scripts);

    // Pack-module wiring info for the generated build.zig (#498 PR 2):
    // one `pack__<prefix>_mod` per pack, rooted at the `__pack_root.zig`
    // written above. The prefix is duped (the shared scratch buf doesn't
    // outlive the loop); freed with the list.
    var pack_modules = try generate_phases.buildPackModules(allocator, pack_scans.items, pack_entries.items);
    defer {
        for (pack_modules.items) |p| allocator.free(p.prefix);
        pack_modules.deinit(allocator);
    }

    // Plugin native build hooks (labelle-assembler#518): probe each declared
    // plugin's resolved directory for a `plugin.hook.zig`. Discovered hooks are
    // (a) emitted as `postWire` CALLs in the generated build.zig and (b) staged
    // next to it below. `cfg_modules` (not `cfg`): only decl-module plugins are
    // `b.dependency`-wired modules the hook can attach native sources to; light
    // packs contribute dir-scan registry entries, never a module. Empty when no
    // plugin ships a hook — the generated build.zig then stays byte-identical.
    var plugin_hook_disc = try plugin_build_hook.discover(allocator, cfg_modules, game_dir);
    defer plugin_build_hook.freeDiscovered(allocator, &plugin_hook_disc);
    const plugin_hooks = try allocator.alloc(build_files.PluginHook, plugin_hook_disc.items.len);
    defer allocator.free(plugin_hooks);
    for (plugin_hook_disc.items, 0..) |d, i| plugin_hooks[i] = .{ .plugin_name = d.plugin_name };

    // Plugin declarative build steps (labelle-assembler#586): load each
    // decl-module plugin's `plugin.labelle` `.build` block PLUS the
    // `.language_builds` entry matching the project's declared script
    // language (labelle-engine#741 — the native-compiled family's cargo
    // step), gate platform constraints, resolve the two placeholder roots,
    // and thread the wiring into the generated build.zig
    // (`emitPluginBuildSteps`: b.addSystemCommand
    // + addObjectFile + step deps — see plugin_build_steps.zig for the design,
    // placeholder language, and safety posture). Skipped for the tests target:
    // it assembles no exe, so there is nothing to hang a produced artifact on
    // (its build.zig stays byte-identical; the exe target of the same project
    // still runs the steps). `{package}` resolves to the deps copy
    // `createDepsLinks` just staged (build.zig.zon generation above — the same
    // ordering dependency the declare phase has); when deps staging fell back
    // to cache-relative paths, the cache-resolved plugin dir is used instead,
    // mirroring `scripting_declare`'s fallback. `{cache}` dirs are created
    // here so a command's first write (`-femit-bin={cache}/…`) never hits a
    // missing parent.
    var plugin_build_loaded: std.ArrayList(plugin_build_steps.BuildSteps) = .empty;
    defer {
        for (plugin_build_loaded.items) |*l| l.deinit();
        plugin_build_loaded.deinit(allocator);
    }
    // Per-language step lists (labelle-engine#741): each plugin's
    // `.language_builds` entry matching the project's declared language,
    // loaded beside `.build` and wired through the SAME emission. Kept in
    // their own list because the parse tree owns the steps the wiring
    // borrows.
    var plugin_langbuild_loaded: std.ArrayList(plugin_build_steps.LanguageBuilds) = .empty;
    defer {
        for (plugin_langbuild_loaded.items) |*l| l.deinit();
        plugin_langbuild_loaded.deinit(allocator);
    }
    // Concatenated `.build` ++ `.language_builds` step slices for plugins
    // declaring BOTH (the emitter needs ONE entry per plugin — its
    // generated variable names are `plugin_<name>_build_step_<i>`).
    var plugin_build_concat: std.ArrayList([]plugin_build_steps.Step) = .empty;
    defer {
        for (plugin_build_concat.items) |c| allocator.free(c);
        plugin_build_concat.deinit(allocator);
    }
    var plugin_build_wirings: std.ArrayList(build_files.PluginBuildStepsWiring) = .empty;
    defer {
        for (plugin_build_wirings.items) |pw| {
            allocator.free(pw.package_abs);
            allocator.free(pw.cache_rel);
            for (pw.library_paths) |p| allocator.free(p);
            allocator.free(pw.library_paths);
        }
        plugin_build_wirings.deinit(allocator);
    }
    if (!is_tests_target) {
        // The project's declared script language, if any — selects each
        // plugin's `.language_builds` entry. Resolved from the FULL plugin
        // list (the same view the policy phase validated; a decl-module
        // filter is irrelevant to the declaration). Same re-parse-per-phase
        // pattern as the splice detection.
        const declared_language: ?[]const u8 =
            if (try language_policy.resolveProjectLanguage(cfg.plugins)) |d| d.language else null;

        for (cfg_modules.plugins) |plugin| {
            // A plugin whose directory cannot be resolved is a pre-existing
            // hard error elsewhere in the pipeline (same posture as the #518
            // hook probe above) — the .build probe must not surface it.
            const plugin_dir = cache.resolvePlugin(allocator, plugin, game_dir) catch continue;
            defer allocator.free(plugin_dir);

            var maybe_build = try plugin_build_steps.loadFromDir(allocator, plugin_dir, plugin.name);
            errdefer if (maybe_build) |*l| l.deinit();
            // `.language_builds` applies only when the project declares a
            // language — a language-less project loads nothing, no matter
            // what the manifest carries (the "runs for EVERY consumer"
            // trap `.build` has is exactly what this key exists to avoid).
            var maybe_lang: ?plugin_build_steps.LanguageBuilds = null;
            errdefer if (maybe_lang) |*l| l.deinit();
            if (declared_language) |lang| {
                maybe_lang = try plugin_build_steps.loadLanguageBuildsFromDir(allocator, plugin_dir, plugin.name, lang);
            }
            if (maybe_build == null and maybe_lang == null) continue;

            const build_steps_all: []const plugin_build_steps.Step =
                if (maybe_build) |l| l.steps else &.{};
            const lang_steps_all: []const plugin_build_steps.Step =
                if (maybe_lang) |l| l.steps else &.{};

            // All appends below must be infallible once owned resources are
            // handed over, or an error between them double-frees. Three
            // concat-list slots: the two possible OS-filter allocations plus
            // the combined slice.
            try plugin_build_loaded.ensureUnusedCapacity(allocator, 1);
            try plugin_langbuild_loaded.ensureUnusedCapacity(allocator, 1);
            try plugin_build_concat.ensureUnusedCapacity(allocator, 3);
            try plugin_build_wirings.ensureUnusedCapacity(allocator, 1);

            // Platform gate: a declared allowlist excluding THIS platform
            // fails the generate up front — the alternative is a
            // missing-symbols link failure much later, far from the cause.
            // Both step sources gate identically (UNfiltered — a step that
            // demands a platform this project doesn't build is an error no
            // matter which OS it is scoped to); the label names the
            // offending block (a desktop-only rust `.language_builds` step
            // must fail a wasm generate pointing at itself).
            const gated_sets = [_]struct {
                steps: []const plugin_build_steps.Step,
                label: []const u8,
            }{
                .{ .steps = build_steps_all, .label = ".build" },
                .{ .steps = lang_steps_all, .label = ".language_builds" },
            };
            for (gated_sets) |set| {
                for (set.steps) |step| {
                    if (!plugin_build_steps.stepAllowsPlatform(step, cfg.platform)) {
                        const list = try std.mem.join(allocator, ", ", step.platforms);
                        defer allocator.free(list);
                        std.debug.print(
                            "labelle: plugin '{s}' {s} step '{s}' does not support platform '{s}' (declared platforms: {s})\n",
                            .{ plugin.name, set.label, step.name, @tagName(cfg.platform), list },
                        );
                        return error.PluginBuildUnsupportedPlatform;
                    }
                }
            }

            // ── Per-OS step selection (labelle-engine#741 crystal) ─────
            // Emit only the steps whose `.os` allowlist matches the target
            // OS (host, unless the test seam overrides): the crystal entry
            // declares one main-localization step per OS and exactly one
            // may run. `.build` blocks filter silently (a fully OS-gated
            // block is a declared per-OS no-op); the SELECTED language
            // entry is gated below — a Windows crystal generate must fail
            // up front, not select an artifact-less chain (codex, PR #19).
            const step_os: std.Target.Os.Tag = opts.plugin_build_os orelse builtin.os.tag;
            const build_steps_slice: []const plugin_build_steps.Step = blk: {
                if (try filterStepsByOs(allocator, build_steps_all, step_os)) |f| {
                    plugin_build_concat.appendAssumeCapacity(f);
                    break :blk f;
                }
                break :blk build_steps_all;
            };
            const lang_steps_slice: []const plugin_build_steps.Step = blk: {
                if (try filterStepsByOs(allocator, lang_steps_all, step_os)) |f| {
                    plugin_build_concat.appendAssumeCapacity(f);
                    break :blk f;
                }
                break :blk lang_steps_all;
            };
            // Captured, not `.?`-unwrapped (gemini #644): `maybe_lang` is only
            // ever set when the project declared a language (the loop above),
            // so this capture is total — but binding it keeps the diagnostics
            // and the csharp probe off a `.?` a future logic change could
            // panic through.
            if (maybe_lang != null) if (declared_language) |dl| {
                const declared_os_union = blk: {
                    var list: std.ArrayList([]const u8) = .empty;
                    errdefer list.deinit(allocator);
                    for (lang_steps_all) |step| {
                        for (step.os) |o| {
                            const dup = for (list.items) |seen| {
                                if (std.mem.eql(u8, seen, o)) break true;
                            } else false;
                            if (!dup) try list.append(allocator, o);
                        }
                    }
                    break :blk try list.toOwnedSlice(allocator);
                };
                defer allocator.free(declared_os_union);
                const os_list = try std.mem.join(allocator, ", ", declared_os_union);
                defer allocator.free(os_list);

                if (lang_steps_slice.len == 0) {
                    std.debug.print(
                        "labelle: plugin '{s}' .language_builds entry \"{s}\" has no build steps for OS '{s}' (steps declare .os: {s})\n" ++
                            "  {s} games build on those OSes only today — generate on one of them, or switch script language.\n",
                        .{ plugin.name, dl, @tagName(step_os), os_list, dl },
                    );
                    return error.PluginBuildNoStepsForOs;
                }
                var had_artifact = false;
                for (lang_steps_all) |step| {
                    if (step.link != .none) had_artifact = true;
                }
                var has_artifact = false;
                for (lang_steps_slice) |step| {
                    if (step.link != .none) has_artifact = true;
                }
                if (had_artifact and !has_artifact) {
                    std.debug.print(
                        "labelle: plugin '{s}' .language_builds entry \"{s}\" produces no linked artifact on OS '{s}' (artifact steps declare .os: {s})\n" ++
                            "  the {s} scripts object would never link — generate on a supported OS, or switch script language.\n",
                        .{ plugin.name, dl, @tagName(step_os), os_list, dl },
                    );
                    return error.PluginBuildNoArtifactForOs;
                }

                // Toolchain probe (labelle-assembler#617): the C# publish
                // step runs inside the user's next `zig build` — a missing
                // .NET SDK there surfaces as an opaque child-spawn failure
                // far from the cause. Probe the emitted step's argv[0] on
                // PATH NOW and fail pointedly (tool + install hint) — a
                // csharp generate without dotnet dies here, not mid-build.
                // Same up-front posture as the platform/cwd gates around
                // this block. Scoped to csharp deliberately: rust/crystal's
                // steps predate this probe and their tests never declared a
                // toolchain-present precondition; the cross-generate `.os`
                // seam can also legitimately select a tool absent from the
                // HOST PATH (linux `objcopy` on a macOS host). The generic
                // `ensureStepToolsOnPath` machinery is ready for #619 to
                // widen via a capability row; the CALL stays csharp-scoped.
                if (std.mem.eql(u8, dl, "csharp")) {
                    try scripting_csharp.ensureStepToolsOnPath(allocator, plugin.name, dl, lang_steps_slice);
                }
            };

            // ONE wiring entry per plugin: `.build` steps first, the
            // matched language's steps AFTER them (documented ordering —
            // the emitter chains a plugin's steps sequentially in slice
            // order, so language builds always run after plain builds).
            const combined: []const plugin_build_steps.Step = blk: {
                if (lang_steps_slice.len == 0) break :blk build_steps_slice;
                if (build_steps_slice.len == 0) break :blk lang_steps_slice;
                const c = try allocator.alloc(plugin_build_steps.Step, build_steps_slice.len + lang_steps_slice.len);
                @memcpy(c[0..build_steps_slice.len], build_steps_slice);
                @memcpy(c[build_steps_slice.len..], lang_steps_slice);
                plugin_build_concat.appendAssumeCapacity(c);
                break :blk c;
            };
            if (combined.len == 0) {
                // Every step OS-filtered away and no language entry (the
                // gates above own THAT case): a per-OS `.build` no-op.
                // Explicit deinits — `continue` is a normal exit, so the
                // errdefers won't fire.
                if (maybe_build) |*l| l.deinit();
                maybe_build = null;
                if (maybe_lang) |*l| l.deinit();
                maybe_lang = null;
                continue;
            }

            // ── Library search paths (.library_paths, generate-resolved) ──
            // `{crystal_env:VAR}` tokens expand by running `crystal env`
            // (or the test override); literals pass through. Deduped —
            // both per-OS localization variants declare the same token,
            // and even the single emitted one may repeat entries.
            var resolved_lib_paths: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (resolved_lib_paths.items) |p| allocator.free(p);
                resolved_lib_paths.deinit(allocator);
            }
            for (combined) |step| {
                for (step.library_paths) |lp| {
                    if (plugin_build_steps.isCrystalEnvToken(lp)) {
                        try plugin_build_steps.resolveCrystalEnv(
                            allocator,
                            plugin.name,
                            step.name,
                            plugin_build_steps.crystalEnvVar(lp),
                            &resolved_lib_paths,
                        );
                    } else {
                        const owned = try allocator.dupe(u8, lp);
                        errdefer allocator.free(owned);
                        try resolved_lib_paths.append(allocator, owned);
                    }
                }
            }
            {
                var w_i: usize = 0;
                for (resolved_lib_paths.items) |p| {
                    const dup = for (resolved_lib_paths.items[0..w_i]) |q| {
                        if (std.mem.eql(u8, p, q)) break true;
                    } else false;
                    if (dup) {
                        allocator.free(p);
                    } else {
                        resolved_lib_paths.items[w_i] = p;
                        w_i += 1;
                    }
                }
                resolved_lib_paths.shrinkRetainingCapacity(w_i);
            }
            const lib_paths_owned = try resolved_lib_paths.toOwnedSlice(allocator);
            errdefer {
                for (lib_paths_owned) |p| allocator.free(p);
                allocator.free(lib_paths_owned);
            }

            // `{package}` root: prefer the staged deps copy (byte-consistent
            // with what the game links, inside .labelle); fall back to the
            // cache-resolved dir when deps staging degraded. Absolutized —
            // the emitted setCwd/argv must not depend on the invoker's cwd.
            const io_l = config.globalIo();
            const fs_cwd = std.Io.Dir.cwd();
            const staged_rel = try std.fmt.allocPrint(allocator, "{s}/deps/labelle-{s}", .{ output_dir, plugin.name });
            defer allocator.free(staged_rel);
            const package_abs: []const u8 = blk: {
                // realPathFileAlloc returns [:0]; dupe to a plain slice so the
                // DebugAllocator size bookkeeping matches on free (same dance
                // as deps_linker).
                if (fs_cwd.realPathFileAlloc(io_l, staged_rel, allocator)) |abs| {
                    defer allocator.free(abs);
                    break :blk try allocator.dupe(u8, abs);
                } else |_| {
                    const abs = try fs_cwd.realPathFileAlloc(io_l, plugin_dir, allocator);
                    defer allocator.free(abs);
                    break :blk try allocator.dupe(u8, abs);
                }
            };
            errdefer allocator.free(package_abs);

            // Every declared cwd must exist in the staged package NOW — a
            // pointed generate error beats the child-spawn failure the user
            // would otherwise hit mid-`zig build`. Walks the COMBINED steps
            // so `.language_builds` cwds are held to the same rule.
            for (combined) |step| {
                const c = step.cwd orelse continue;
                const step_cwd = try std.fs.path.join(allocator, &.{ package_abs, c });
                defer allocator.free(step_cwd);
                fs_cwd.access(io_l, step_cwd, .{}) catch {
                    std.debug.print(
                        "labelle: plugin '{s}' build step '{s}' cwd '{s}' does not exist in the staged package ({s})\n",
                        .{ plugin.name, step.name, c, step_cwd },
                    );
                    return error.PluginBuildMissingCwd;
                };
            }

            // `{cache}` root: per-plugin persistent dir under THIS build root
            // (per backend×platform — cross-target artifacts never collide),
            // outside the wiped deps tree so tool caches survive regenerates.
            const cache_rel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ plugin_build_steps.CACHE_DIR_NAME, plugin.name });
            errdefer allocator.free(cache_rel);
            const cache_abs = try std.fs.path.join(allocator, &.{ target_dir, cache_rel });
            defer allocator.free(cache_abs);
            try fs_cwd.createDirPath(io_l, cache_abs);

            plugin_build_wirings.appendAssumeCapacity(.{
                .plugin_name = plugin.name,
                .package_abs = package_abs,
                .cache_rel = cache_rel,
                .steps = combined,
                .library_paths = lib_paths_owned,
                // C# EMBED path (labelle-assembler#617): the csharp entry's
                // link-less `dotnet publish` step makes `{cache}` the
                // runtime payload (the managed assembly the hostfxr vm
                // loads) — stage it beside the binary + point the run
                // step's env at it. Keyed on the SELECTED language row AND
                // on this being the SCRIPTING plugin (codex #644 round 2):
                // a non-scripting plugin with a link-less csharp
                // `.language_builds`, ordered before scripting, must not
                // capture the staging / LABELLE_CS_ASSEMBLY_DIR — the
                // runtime payload is the scripting plugin's published DLL.
                // False for every other language/plugin — byte-identity.
                // Captured, not `.?` (gemini #644): false unless BOTH a
                // language entry loaded AND the project declared a language.
                .stage_runtime_outputs = if (maybe_lang != null)
                    if (declared_language) |dl| scripting_csharp.stagesRuntimeOutputs(
                        dl,
                        plugin.name,
                        if (maybe_scripting) |s| s.plugin_name else null,
                        lang_steps_slice,
                    ) else false
                else
                    false,
            });
            // Hand the parse trees over to their lifetime lists and disarm
            // the errdefers (assume-capacity appends cannot fail between
            // the handovers).
            if (maybe_build) |l| {
                plugin_build_loaded.appendAssumeCapacity(l);
                maybe_build = null;
            }
            if (maybe_lang) |l| {
                plugin_langbuild_loaded.appendAssumeCapacity(l);
                maybe_lang = null;
            }
        }
    }

    // Generate build.zig
    // `cfg_modules` (not `cfg`): light packs get no `b.dependency` /
    // `overrideImport` module wiring — their contribution is dir-scan
    // registry entries, not an importable module (#481). Their PACK
    // modules (`pack__<prefix>_mod`, #498 PR 2) ride `pack_modules`
    // instead — a third wiring category driven by `pack_scans`, never by
    // `cfg.plugins`.
    const build_zig = try build_files.generateBuildZig(allocator, cfg_modules, .{
        .is_tests_target = is_tests_target,
        .promoted_scripts = promoted_scripts,
        .pack_modules = pack_modules.items,
        .plugin_hooks = plugin_hooks,
        // Declarative plugin build steps (#586): system-command + artifact
        // link wiring emitted after the game artifact is assembled. Empty
        // when no plugin declares `.build` — byte-identical build.zig.
        .plugin_build_steps = plugin_build_wirings.items,
        // Manifest-driven backend splice (assembler#378): pass the project
        // root so the splice can locate `backend.manifest.zon` + fragments.
        // Only consulted when the gate (desktop + manifest present) fires.
        .project_dir = game_dir,
        // manifest-v2 cutover: the auto-detected v2 manifest name (null → v1/enum,
        // byte-unchanged). When a v2 manifest is present this routes the
        // backend-dep + link sections to the v2 codegen (`manifest_v2_splice`).
        .backend_manifest_name = backend_manifest_name,
        // Scripting splice (labelle-assembler#593): thread the declared
        // language into the scripting plugin's `b.dependency` args
        // (`-Dlanguage`). Null → byte-identical dep args. Dev-mode hot
        // reload (#637): `.hot_reload` additionally passes the plugin's
        // `-Dhot_reload` as `optimize == .Debug` — gate set audited in
        // `scripting_splice.buildDepHotReload` (embed family + capability
        // probe + NEVER the tests target + desktop only; the tests target
        // must not compile the watcher in, the same explicit pin
        // `testsTargetConfig` carries for gamepad/backend).
        .scripting = if (maybe_scripting) |s| .{
            .plugin_name = s.plugin_name,
            .language = s.language,
            .hot_reload = scripting_splice.buildDepHotReload(s, is_tests_target, cfg.platform),
        } else null,
        // Schema-declared plugin params (#591): each entry emits the
        // `plugin_<name>_params_mod` createModule + the `overrideImport`
        // that injects it into the plugin as `@import("plugin_params")`.
        // Empty → byte-identical build.zig.
        .plugin_params = resolved_plugin_params.items,
    });
    defer allocator.free(build_zig);
    try scanner.writeFile(target_dir, "build.zig", build_zig);

    // manifest-v2 (PR #466 Finding 3): a v2 backend whose manifest declares a
    // `build_hook` needs that hook staged next to the generated build.zig as
    // `backend_build_hook.zig`, so the generated `@import("backend_build_hook.zig")`
    // resolves in the real output dir. No-op (returns false) for the v1/enum path
    // (backend_manifest_name null), a v1 manifest, or a hookless v2 manifest.
    if (backend_manifest_name) |name| {
        _ = try manifest_v2_splice.stageBackendBuildHook(allocator, cfg, game_dir, name, target_dir);
    }

    // Plugin build hooks (#518): stage each discovered `plugin.hook.zig` next to
    // the generated build.zig as `plugin_<name>_build_hook.zig`, so the
    // `@import` the codegen above emitted resolves in the real output dir.
    // Mirrors `stageBackendBuildHook`. No-op when no plugin ships a hook.
    try plugin_build_hook.stage(allocator, plugin_hook_disc.items, target_dir);

    // Plugin params modules (#591): render each resolved param set as
    // `plugin_<name>_params.zig` next to the generated build.zig, so the
    // `b.path(…)` the codegen above emitted resolves in the real output
    // dir. Same staging shape as the build hooks. No-op when no plugin
    // resolved params (every schema-less project — byte-identical output).
    try plugin_params.stage(allocator, resolved_plugin_params.items, target_dir);

    // Discover each plugin's `pub const Events` decls at assembler time
    // by AST-walking `<plugin>/src/root.zig`. The shim + main.zig
    // emission below both consume this list to build the literal
    // `PluginEvents = union(enum) { … }` (or `void` when empty) — see
    // the file header on `main_zig.writePluginEventsBlock` for why the
    // builtin `@Union(.auto, …)` path was retired (zero-field result is
    // uninstantiable, breaks the plugin-controllers example).
    // `cfg_modules`: only decl-module plugins have a `src/root.zig` with an
    // `Events` block; a light pack's events arrive via `pack_scans`, already
    // namespaced, so it contributes nothing here and must not be resolved as a
    // module (#481).
    var plugin_events = try main_zig.discoverPluginEvents(allocator, cfg_modules, game_dir);
    defer plugin_events.deinit();

    // Script-DECLARED events (labelle-engine#772) were gated against the
    // game/pack event namespaces inside the declare phase — but plugin
    // `Events` discovery only happens NOW, so a declared name that spells
    // a plugin's qualified tag (`box2d__collision_begin`) would sail
    // through `checkEventCollisions` and only explode later inside the
    // generated main.zig's `MergeHookPayloads` comptime duplicate-field
    // check — a terrible error for a user mistake. Gate it here, right
    // after discovery, with the declare phase's pointed collision voice.
    if (maybe_scripting) |s| {
        try scripting_declare.checkEventPluginCollisions(s.declared_events, plugin_events.entries);
    }

    // Same gate for Zig/pack GAME events whose generated variant name
    // spells a plugin tag (`events/box2d__collision_begin.zig` vs
    // box2d's `collision_begin` — #631 codex). Must run BEFORE the
    // consumption filter below, on the FULL discovery list: pre-#630
    // the duplicate always reached `MergeHookPayloads`' comptime
    // duplicate-field check, but an UNREFERENCED plugin entry would now
    // be elided first — the collision silently vanishes and the
    // plugin's `@hasField` emit gate turns on against the game's
    // same-named payload. Collision behavior must be
    // consumption-independent.
    try scripting_declare.checkGameEventPluginCollisions(event_names, pack_scans.items, plugin_events.entries);

    // Two providers whose sanitized names collide on the same event
    // (`foo-bar` + `foo_bar`, both declaring `hit` → `foo_bar__hit`
    // twice — #631 codex): pre-#630 the duplicate union field failed
    // loudly at the decl; under filtering a source naming only one
    // dotted form keeps one entry, elides the other, and the elided
    // plugin's emit gate turns on against the kept plugin's payload.
    // Gate on the FULL list before the filter, in every mode (`.all`
    // included — the pointed message beats the raw duplicate-field
    // compile error it replaces).
    try scripting_declare.checkDuplicatePluginTags(plugin_events.entries);

    // Consumption filter (labelle-assembler#630): fold only CONSUMED
    // events into the generated `PluginEvents` union. Runs AFTER the
    // collision gate above (which must keep seeing the FULL discovery
    // list so error behavior is consumption-independent) and BEFORE the
    // shim + main.zig emission below (both consume the same filtered
    // list). Scan roots: the game dir (hooks, scripts, flows — both the
    // `.flow.jsonc` sources' dotted refs and any committed generated
    // sidecars' qualified tags), plus the staged `<target>/scripts`
    // (plugin-shipped scripts, copied above — a symlink to the game's
    // `scripts/` on POSIX, a real copy on Windows) and `<target>/packs`
    // (staged pack hooks/components from published packs that don't
    // live in the game tree). The staged deps tree is deliberately NOT
    // scanned — plugin/engine SOURCE mentions its own tags at the emit
    // sites, which would mark everything consumed and void the filter.
    // The elided remainder is threaded to `writePluginEventsBlock` for
    // the `// elided (no consumer): <tag>` debug comments. Struct-copy
    // semantics: both lists borrow their strings from
    // `plugin_events.entries` (deinited once, above), so no double free.
    //
    // IN-TREE dependency sources are excluded from the walk (#631
    // review): a `local:plugins/box2d` / `@libs/box2d` plugin (or a
    // `local:` core/engine/gfx override) resolves UNDER the game dir,
    // and its own source names its event tags at the emit sites — left
    // in the corpus it would mark all its events consumed and void the
    // filter for exactly the local-plugin-heavy projects. Resolving
    // through the same `cache` paths discovery uses keeps the exclusion
    // in lockstep with what was discovered; a dep outside the game tree
    // is a harmless no-op exclude. The dependency's STAGED hooks/scripts
    // (`<target>/scripts/.plugin_*`, `<target>/packs`) stay in the
    // corpus, so cross-plugin consumption via shipped scripts keeps
    // working — local plugins end up symmetric with published ones
    // (whose cache dirs were never scanned).
    var excluded_dep_roots: std.ArrayList([]const u8) = .empty;
    defer {
        for (excluded_dep_roots.items) |p| allocator.free(p);
        excluded_dep_roots.deinit(allocator);
    }
    // The OUTPUT dir is excluded as a whole (CodeRabbit on 6ed5fef): the
    // `.labelle` basename skip only covers the DEFAULT output name — a
    // caller-configured in-tree output dir would otherwise be scanned,
    // and stale generated files retain every previously known tag: a
    // stale main.zig names each kept variant, and even the
    // `// elided (no consumer): <tag>` comments spell the qualified tag,
    // so every once-discovered event would be falsely retained forever
    // (a self-perpetuating ratchet). Excluding the output ROOT also
    // covers `deps/` (staged dependency sources) and stale sibling
    // target dirs under a non-default output name. The explicit
    // `<target>/scripts` / `<target>/packs` scan roots are unaffected:
    // exclusion is equality-per-directory, and those roots are passed
    // directly, not reached by descent. The `.labelle` basename skip
    // stays too (belt and suspenders for nested stale outputs).
    {
        const out_dup = try allocator.dupe(u8, output_dir);
        errdefer allocator.free(out_dup);
        try excluded_dep_roots.append(allocator, out_dup);
    }
    // `tests/` is a TESTS-TARGET consumer surface, not a production one
    // (#631 codex): test files feed the separate `__tests_root.zig`
    // target only, so a tag referenced NOWHERE but a test must not keep
    // the variant in the production GameEvents. Exclude exactly
    // `<game_dir>/tests` (canonical-root exclusion — NOT a blanket
    // basename skip, which would eat e.g. a pack's `tests/` fixtures) —
    // and ONLY for non-tests targets: the tests-target pass keeps
    // scanning it so a test referencing a variant gets that variant in
    // its OWN GameEvents and compiles. Per-target divergence is the
    // tests target's normal shape (cf. `testsTargetConfig`'s backend
    // `.null` / platform overrides): production elides what only tests
    // reference; the tests target keeps it.
    if (!is_tests_target) {
        const tests_dup = try std.fs.path.join(allocator, &.{ game_dir, "tests" });
        errdefer allocator.free(tests_dup);
        try excluded_dep_roots.append(allocator, tests_dup);
    }
    for (cfg.plugins) |plugin| {
        if (!plugin.isLocal()) continue;
        const dep_dir = cache.resolvePlugin(allocator, plugin, game_dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        errdefer allocator.free(dep_dir);
        try excluded_dep_roots.append(allocator, dep_dir);
    }
    const local_framework_versions = [_]struct { name: []const u8, version: []const u8 }{
        .{ .name = "core", .version = cfg.core_version },
        .{ .name = "engine", .version = cfg.engine_version },
        .{ .name = "gfx", .version = cfg.gfx_version },
    };
    for (local_framework_versions) |fw| {
        if (!config.isLocalVersion(fw.version)) continue;
        const dep_dir = cache.resolveFrameworkPackage(allocator, fw.name, fw.version, game_dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        errdefer allocator.free(dep_dir);
        try excluded_dep_roots.append(allocator, dep_dir);
    }

    // Force-kept RUNTIME channels (#631 codex): tags whose consumers
    // register at runtime rather than in authored text, so the scan
    // structurally cannot prove non-consumption. Survey result (engine
    // origin/main + assembler codegen seams): exactly ONE such channel
    // exists today —
    //
    //   `engine__editor_plugin_command` (labelle-engine#729, editor-
    //   contract v1.7 / bridge v1.8, script contract v1.2): the studio's
    //   panel actions and script-language `labelle_plugin_call` wrappers
    //   dispatch through the engine's `editor_plugin_command` bridge
    //   export, which `emitSync`s this variant
    //   (`src/game/editor_command_mixin.zig` in labelle-engine).
    //   Handlers register by RUNTIME subscription (script-contract subs)
    //   or by plugin hooks whose module source this scan deliberately
    //   excludes as a dependency emit-site — no game-authored text need
    //   ever name the tag. Force-kept UNCONDITIONALLY (not just for
    //   editor-preview builds): the script `plugin_call` channel works
    //   on every platform, presence-detection of panels/handlers at
    //   generate time is unreliable, and one kept `emitSync`-only
    //   variant has zero steady-state cost — vs silently dead studio
    //   panels. Every other engine event (input/lifecycle families) is
    //   delivered to authored hooks/flows/scripts and stays under the
    //   text scan.
    const static_force_consumed_tags = [_][]const u8{
        "engine__editor_plugin_command",
    };

    // Ungated-emit force-keep (#630 follow-up — the flying-platform
    // v0.93.0 breakage): a provider that emits with raw anonymous
    // union literals (labelle-pathfinding's
    // `game.emit(.{ .pathfinder__node_removed = .{ ... } })`) instead
    // of a `@hasField`-gated helper does not tolerate elision — the
    // PLUGIN SOURCE stops compiling ("no field named ... in union")
    // and `labelle build` breaks for the whole game. Scan each
    // provider's own resolved module dir (the same dirs
    // `discoverPluginEvents` walked) for its OWN tags in dot-prefixed
    // form and force-keep the matches via the same `force_consumed`
    // mechanism as the runtime channels above. See
    // `scan.detectUngatedEmits` for the discriminator + heuristic risk
    // profile (over-match force-keeps → safe; under-match = today's
    // loud compile error, no new failure mode). Skipped for
    // `.plugin_events = .all` (nothing is elided there anyway).
    var provider_dirs: std.ArrayList(main_zig.ProviderDir) = .empty;
    defer {
        for (provider_dirs.items) |p| allocator.free(p.dir);
        provider_dirs.deinit(allocator);
    }
    if (cfg.plugin_events != .all and plugin_events.entries.len > 0) {
        // Mirror discovery's resolution exactly (`discoverPluginEvents`
        // resolves the engine package + each `cfg_modules` plugin dir),
        // but only for providers that actually contributed entries —
        // needle-less walks would be pure I/O waste.
        var saw_engine = false;
        for (plugin_events.entries) |e| {
            if (std.mem.eql(u8, e.plugin_import_name, "engine")) {
                saw_engine = true;
                break;
            }
        }
        if (saw_engine) blk: {
            const dir = cache.resolveFrameworkPackage(allocator, "engine", cfg_modules.engine_version, game_dir) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break :blk,
            };
            errdefer allocator.free(dir);
            try provider_dirs.append(allocator, .{ .import_name = "engine", .dir = dir });
        }
        for (cfg_modules.plugins) |plugin| {
            var has_entry = false;
            for (plugin_events.entries) |e| {
                if (std.mem.eql(u8, e.plugin_import_name, plugin.name)) {
                    has_entry = true;
                    break;
                }
            }
            if (!has_entry) continue;
            const dir = cache.resolvePlugin(allocator, plugin, game_dir) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            errdefer allocator.free(dir);
            try provider_dirs.append(allocator, .{ .import_name = plugin.name, .dir = dir });
        }
    }
    const ungated_flags = try main_zig.detectUngatedEmits(allocator, plugin_events.entries, provider_dirs.items);
    defer allocator.free(ungated_flags);

    // Full force set = the static runtime channels + every ungated-emit
    // tag; plus the struct-copy subset for the
    // `// force-kept (provider emits ungated): <tag>` codegen comments
    // (entries borrow their strings from `plugin_events`, same
    // semantics as the kept/elided lists).
    var force_consumed_tags: std.ArrayList([]const u8) = .empty;
    defer {
        for (force_consumed_tags.items) |t| allocator.free(t);
        force_consumed_tags.deinit(allocator);
    }
    for (static_force_consumed_tags) |tag| {
        const dup = try allocator.dupe(u8, tag);
        errdefer allocator.free(dup);
        try force_consumed_tags.append(allocator, dup);
    }
    var force_kept_ungated: std.ArrayList(main_zig.PluginEvent) = .empty;
    defer force_kept_ungated.deinit(allocator);
    for (plugin_events.entries, ungated_flags) |e, is_ungated| {
        if (!is_ungated) continue;
        // Order matters (PR #634 review — gemini/codex double-free):
        // `force_kept_ungated` holds borrowed struct copies (no owned
        // strings), so append it FIRST. The owned `tag` then has exactly
        // one owner at every point — the errdefer until its append
        // succeeds, the `force_consumed_tags` cleanup after. With the
        // appends in the opposite order, a failing second append would
        // unwind through BOTH the still-armed errdefer and the list
        // cleanup: a double free under allocator pressure. (No
        // FailingAllocator test: the loop lives inline in `generate`,
        // which can't be driven with an injected allocator.)
        try force_kept_ungated.append(allocator, e);
        const tag = try std.fmt.allocPrint(allocator, "{s}__{s}", .{ e.plugin_sanitized, e.event_name });
        errdefer allocator.free(tag);
        try force_consumed_tags.append(allocator, tag);
    }

    // Declared plugin-to-plugin consumption (#633): a plugin that
    // consumes ANOTHER plugin's events from inside its own module
    // source is invisible to the text scan — dependency sources are
    // deliberately excluded above as emit-sites — so if no game-side
    // consumer names the tag either, the event would be elided and the
    // plugin-to-plugin delivery silently stops. The declared escape:
    // `.consumes_events = .{ "pathfinding.path_found" }` in the
    // consuming plugin's plugin.labelle feeds those events into the
    // same `force_consumed` set (dotted or qualified spelling — the
    // resolution mirrors the scanner's needles). An entry matching NO
    // discovered event fails generation loudly
    // (`resolveDeclaredConsume`'s pointed diagnostic) — a typo'd
    // declaration must not silently deliver nothing. Runs in every
    // mode, `.all` included: validation is consumption-independent,
    // like the collision gates above.
    for (cfg.plugins) |plugin| {
        var pmani = (try plugin_manifest.loadOptional(allocator, plugin, game_dir)) orelse continue;
        defer pmani.deinit();
        for (pmani.consumes_events) |ref| {
            const matched = try main_zig.resolveDeclaredConsume(plugin_events.entries, plugin.name, ref);
            const tag = try std.fmt.allocPrint(allocator, "{s}__{s}", .{ matched.plugin_sanitized, matched.event_name });
            errdefer allocator.free(tag);
            try force_consumed_tags.append(allocator, tag);
        }
    }

    const packs_target = try std.fs.path.join(allocator, &.{ target_dir, "packs" });
    defer allocator.free(packs_target);
    // The active splice's script extensions join the consumption scan
    // (#619): the comptime `scanned_extensions` list covers only the
    // FROZEN built-in languages, so a manifest-row language's sources
    // (the litmus `.py`) would otherwise be invisible and their
    // subscriptions silently elided. Frozen-language splices contribute
    // duplicates of already-scanned extensions — harmless.
    var script_ext_buf: [2][]const u8 = undefined;
    var script_ext_len: usize = 0;
    if (maybe_scripting) |s| {
        script_ext_buf[script_ext_len] = s.extension;
        script_ext_len += 1;
        if (s.transpile) |t| {
            script_ext_buf[script_ext_len] = t.source_extension;
            script_ext_len += 1;
        }
    }
    var event_consumption = try main_zig.filterConsumedEvents(
        allocator,
        plugin_events.entries,
        &.{ game_dir, scripts_target, packs_target },
        excluded_dep_roots.items,
        force_consumed_tags.items,
        script_ext_buf[0..script_ext_len],
        cfg.plugin_events,
    );
    defer event_consumption.deinit();

    // Emit the `game.zig` shim — a tiny re-export module that surfaces
    // `Game` and `EntityId` so generated flow files at
    // `scripts/flows/*.zig` can `@import("game")`. See
    // labelle-assembler#116. When at least one plugin declares events,
    // the shim also re-exports `PluginEvents` so new-form `OnEvent`
    // flow handlers (RFC-PLUGIN-EVENTS phase 3) can reflect payload
    // signatures through the same `@import("game")` they already use.
    // The matching `addImport("game", game_mod)` and per-plugin
    // `overrideImport(game_mod, "<plugin>", plugin_mod)` calls live in
    // `build_files.generateBuildZig`.
    // `plugin_flow_decls.flow_nodes` was discovered ABOVE the flow scan
    // (root.zig §flow discovery). Thread it in so the shim's
    // `PluginFlowNodes` block (Gap 1) matches the one main.zig emits.
    const game_shim = try generateGameShim(allocator, event_consumption.kept, plugin_flow_decls.flow_nodes, .{
        .is_tests_target = is_tests_target,
        .ecs = cfg.ecs,
        .plugin_events_elided = event_consumption.elided,
        .plugin_events_force_kept = force_kept_ungated.items,
    });
    defer allocator.free(game_shim);
    try scanner.writeFile(target_dir, "game.zig", game_shim);

    // Generate main.zig — load engine template from codegen/ directory.
    // Capture script entries NOW, after all game + plugin scripts have
    // been fed to the scanner (see root.zig §script discovery). Capturing
    // earlier would produce a stale slice that misses every
    // plugin-shipped script.
    //
    // The tests target has no exe and therefore no main.zig — its build.zig
    // only emits a `test` step rooted at `__tests_root.zig`.
    if (!is_tests_target) {
        const scanned_entries = script_scan.getEntries();
        // Merge in the synthetic flow entries so AllScripts sees both
        // hand-authored scripts and `.flow.jsonc`-derived ones. Flows
        // sort after every real script in the game block today (no
        // numeric prefix, alphabetical fallback), matching the file
        // layout on disk where `scripts/flows/*.zig` sits below
        // `scripts/*.zig` lexicographically. A future RFC can revisit
        // ordering — none of v1's flows depend on it.
        const merged_entries = try allocator.alloc(script_scanner.ScriptScanner.ScriptEntry, scanned_entries.len + flow_result.entries.len);
        defer allocator.free(merged_entries);
        @memcpy(merged_entries[0..scanned_entries.len], scanned_entries);
        @memcpy(merged_entries[scanned_entries.len..], flow_result.entries);

        // `plugin_flow_decls` + `scripts_target_for_flow` were discovered
        // ABOVE the flow scan (the registry the scanner needs is built
        // from the same FlowNode list). Reuse them here rather than
        // walking the source tree twice — the synthetic flow entries the
        // merge adds declare no `FlowNodes`, so re-running discovery on
        // `merged_entries` would produce an identical FlowNode set.

        // RFC-FLOW-VOCABULARY phase 4 follow-up: emit a per-project
        // `flow_catalog.json` sidecar so the labelle-gui flow editor
        // can read its palette from the project instead of carrying a
        // hand-maintained mirror of every plugin's `FlowNodes` block.
        // The discovery walks the same source files
        // `discoverPluginFlowDecls` does (plugins' `src/root.zig` +
        // game-script modules); the extra pass is independent and
        // does NOT block codegen — a parse failure here is logged via
        // the `flow_catalog` internals' graceful degradation and the
        // resulting sidecar simply omits the affected module.
        // The sidecar is **project-level**, not per-backend — a flow's
        // catalog (plugin verbs, events, pin types) is backend-independent.
        // Wave-4's per-backend layout (`<project>/.labelle/<backend>/...`)
        // forced the editor to pick a backend it had no business knowing
        // about and emitted N identical copies.
        const labelle_dir = try std.fs.path.join(allocator, &.{ game_dir, ".labelle" });
        defer allocator.free(labelle_dir);
        _ = flow_catalog.emitFlowCatalogSidecar(
            allocator,
            cfg,
            game_dir,
            labelle_dir,
            scripts_target_for_flow,
            merged_entries,
        ) catch |err| {
            // Don't fail the whole `generate` over a sidecar that's
            // additive. Log it and move on; the gui's static fallback
            // covers the editor regardless.
            std.debug.print("labelle-assembler: flow_catalog sidecar emission failed: {s}\n", .{@errorName(err)});
        };

        // Pack/feature manifest sidecar (#442, Packs RFC §7). Sits next to
        // `flow_catalog.json` and answers the "I'm adding a feature — which
        // realm owns this, what shapes do I touch, what already exists, what
        // may I call cross-pack" questions for an agent or a human. Built
        // from the same scanned data the codegen already has (component /
        // prefab / event / enum / hook names + script entries + discovered
        // FlowNodes + plugin events), plus a light AST pass over the game
        // root's `components/` + `events/` for field schemas. Additive and
        // best-effort — a failure here is logged, never fatal, exactly like
        // the flow catalog above.
        // Zip the pack scans (`pack_scans`, name + staged import prefix +
        // scanned stems) with the already-parsed `pack.labelle` surfaces
        // (`pack_entries`, `exposes` + `depends_on`) into the manifest input.
        // Both lists are appended once per iteration of the SAME pack loop
        // above, so `pack_scans.items[i]` ↔ `pack_entries.items[i]`. Borrows
        // both lists — valid only for the synchronous call below.
        std.debug.assert(pack_scans.items.len == pack_entries.items.len);
        const manifest_packs = try allocator.alloc(pack_manifest.PackInput, pack_scans.items.len);
        defer allocator.free(manifest_packs);
        for (pack_scans.items, pack_entries.items, 0..) |*ps, pe, i| {
            manifest_packs[i] = .{
                .scan = ps,
                .exposes = pe.manifest.exposes,
                .depends_on = pe.manifest.depends_on,
            };
        }

        pack_manifest.emitManifestSidecar(
            allocator,
            cfg,
            game_dir,
            labelle_dir,
            target_dir,
            component_names,
            // Script-declared components (#585) — registered into the same
            // game-root namespace as components/*.zig, so the sidecar's game
            // realm must list them too. Empty for declaration-less projects.
            if (maybe_scripting) |s| s.declared_components else &.{},
            // Script-declared events (labelle-engine#772) — one GameEvents
            // union variant each, exactly like events/*.zig; the sidecar's
            // game realm lists them the same way.
            if (maybe_scripting) |s| s.declared_events else &.{},
            prefab_names,
            enum_names,
            event_names,
            hook_names,
            merged_entries,
            plugin_flow_decls.flow_nodes,
            // FULL discovery list, not the #630-filtered subset: the
            // sidecar is a discoverability catalog ("what exists to
            // subscribe to") — an agent adding the FIRST consumer of an
            // event must still be able to find it here.
            plugin_events.entries,
            manifest_packs,
        ) catch |err| {
            std.log.warn("labelle-assembler: manifest sidecar emission failed: {s}", .{@errorName(err)});
        };

        // Backend lifecycle template — only the exe target needs it.
        // Loading it for the tests target would fail unnecessarily if the
        // null backend's `desktop.txt` is missing from the cache, since
        // the tests target never emits main.zig and therefore never uses
        // the template anyway.
        const backend_tmpl = try loadBackendTemplate(allocator, game_dir, cfg, backend_manifest_name);
        defer allocator.free(backend_tmpl);
        const engine_template = try templates.loadEngineTemplate(allocator, game_dir, cfg);
        defer allocator.free(engine_template);

        // Manifest-driven run-loop splice (assembler#378): when the manifest
        // path is enabled (desktop + a backend that ships a manifest), resolve
        // the lifecycle style (callback vs loop) from the backend manifest and
        // stash it where `generateMainZigFromTemplate` reads it — instead of the
        // `cfg.backend == .sokol` enum branch inside that function. Scoped to this
        // one call; cleared right after. Null override = enum path (bgfx-android,
        // sokol-wasm, etc. unchanged).
        //
        // manifest-v2 cutover (epic #453): a v2-detected backend reads the
        // PER-PLATFORM `.platforms[<platform>].loop_style` (bgfx-desktop is `.loop`,
        // bgfx-android `.callback` — the style MUST be per-platform); the v1 path
        // reads the top-level `loop_style`. Both map onto the same override enum.
        defer main_zig.main_template.loop_style_override = null;
        main_zig.main_template.loop_style_override = try resolveLoopStyleOverride(allocator, cfg, game_dir, backend_manifest_name);

        // Callback-lifecycle-blocks declaration (assembler#501) — resolved from
        // the SAME v2 manifest's `.platforms.<platform>.lifecycle`. Non-null
        // lifts the callback-external rejection AND drives the render shape for
        // a declared third-party callback backend. Same scoped-threadlocal
        // pattern; null keeps the built-in enum-predicate shape.
        defer main_zig.main_template.lifecycle_override = null;
        main_zig.main_template.lifecycle_override = try resolveLifecycleOverride(allocator, cfg, game_dir, backend_manifest_name);

        // Pack dir-scan results (Packs RFC §4, #439) — same module-level-var
        // pattern as loop_style_override, so the ~19-arg generator signature
        // (100+ call sites) stays untouched. Scoped to this one generation;
        // cleared right after. Empty when the project declares no packs.
        defer main_zig.main_template.pack_scans = &.{};
        main_zig.main_template.pack_scans = pack_scans.items;

        // Embedded-tilemap registrations (T2 Phase 4) — same scoped
        // module-level-var pattern as pack_scans. Set to the list collected
        // after the assets link above; cleared right after this generation.
        // Empty for tilemap-free projects, so their main.zig is byte-identical.
        defer main_zig.main_template.tilemap_registrations = &.{};
        main_zig.main_template.tilemap_registrations = tilemap_registrations;

        // Scripting splice (labelle-assembler#593) — same scoped pattern.
        // Carries the plugin import name + language + the sorted script
        // stems scanned by the `<language>/` copy above. Null for projects
        // without the scripting plugin, so their main.zig is byte-identical.
        defer main_zig.main_template.scripting_splice = null;
        main_zig.main_template.scripting_splice = maybe_scripting;

        // Elided plugin events (#630) — same scoped pattern. The
        // positional `plugin_events` arg below carries only the CONSUMED
        // entries (`event_consumption.kept`); this threads the elided
        // remainder so `writePluginEventsBlock` emits its per-variant
        // `// elided (no consumer)` comments. Empty for `.all`-mode
        // projects and projects whose events are all consumed, so their
        // main.zig is byte-identical.
        defer main_zig.main_template.plugin_events_elided = &.{};
        main_zig.main_template.plugin_events_elided = event_consumption.elided;

        // Force-kept ungated-emit events (#630 follow-up) — same scoped
        // pattern; threads the annotation subset so
        // `writePluginEventsBlock` emits its per-variant
        // `// force-kept (provider emits ungated)` comments. Empty for
        // `.all`-mode projects and projects with only gated providers,
        // so their main.zig is byte-identical.
        defer main_zig.main_template.plugin_events_force_kept = &.{};
        main_zig.main_template.plugin_events_force_kept = force_kept_ungated.items;

        const main_zig_content = try main_zig.generateMainZigFromTemplate(
            allocator,
            engine_template,
            // `cfg_modules`: the plugin `@import` sites inside main.zig
            // (ComponentRegistryWithPlugins / SystemRegistry / plugin
            // controllers) must skip light packs — their items are wired in
            // via `main_template.pack_scans` above, not a module import (#481).
            cfg_modules,
            backend_tmpl,
            merged_entries,
            prefab_names,
            jsonc_scene_names,
            scene_manifests,
            component_names,
            hook_names,
            event_names,
            enum_names,
            view_names,
            gizmo_names,
            animation_names,
            // Consumed subset only (#630) — the full discovery list stays
            // with the collision gate + manifest sidecar above.
            event_consumption.kept,
            plugin_flow_decls.flow_nodes,
            plugin_flow_decls.pin_styles,
            plugin_flow_decls.coercions,
        );
        defer allocator.free(main_zig_content);
        try scanner.writeFile(target_dir, "main.zig", main_zig_content);
    }

    // Emit `__tests_root.zig` — a `test { _ = @import("tests/<stem>.zig"); }`
    // wrapper that pulls every test file's blocks into the test compile unit.
    // Lives at the build root so its module path covers the whole project,
    // letting test files reach `components/`, `scripts/`, etc. via relative
    // `@import` exactly as `main.zig` does.
    const tests_root = try generateTestsRoot(allocator, test_names);
    defer allocator.free(tests_root);
    try scanner.writeFile(target_dir, "__tests_root.zig", tests_root);
}

/// Generate the backend-agnostic test target at `output_dir/tests/`. Issue #83.
///
/// Reuses `generate` with `cfg.backend = .null` so test compile units link
/// against the pure-Zig null backend (no native artifact, no system libs)
/// regardless of which backend the user picked for their exe build. This
/// lets `zig build test` run on any host without backend-specific apt-get
/// installs or cross-compile toolchains, and means tests are reproducible
/// across machines independent of the active exe target.
///
/// `is_tests_target = true` trims the emitted build.zig to a single test
/// step (no exe, no run step) and skips main.zig generation entirely.
pub fn generateTestsTarget(
    allocator: std.mem.Allocator,
    cfg_in: ProjectConfig,
    output_dir: []const u8,
    game_dir: []const u8,
) !void {
    try generate(allocator, testsTargetConfig(cfg_in), output_dir, game_dir, .{
        .target_name_override = "tests",
        .is_tests_target = true,
    });
}

/// The project config as seen by the `.labelle/tests/` target — the exe
/// config with the tests-target overrides applied. Extracted (and unit-tested
/// below) so the override set is auditable in one place.
fn testsTargetConfig(cfg_in: ProjectConfig) ProjectConfig {
    var cfg = cfg_in;
    cfg.backend = .null;
    // Force the host platform too. For wasm/ios/android projects, leaving
    // cfg.platform as-is would route the tests target through the
    // cross-compile build template (which omits the test step entirely),
    // producing a build.zig that builds cleanly but never runs tests. The
    // tests target is meant to run on the developer's host regardless of
    // what the exe target ships as.
    cfg.platform = .desktop;
    // No gamepad — and therefore no SDL — in the tests target, ever. Tests
    // exercise game logic, not controllers. Without this pin, the `.backend =
    // .null` swap above defeats `effectiveGamepad()`'s backend-aware default
    // (assembler#533): a bgfx project with `.gamepad` omitted resolves `.none`
    // for its GAME targets, but the tests target sees backend `.null` → `.auto`
    // → the staged backend dep gets `gamepad_enabled = true` and links SDL2 —
    // failing `zig build test` on any host without libsdl2 (bit FP's CI).
    // Applies to every backend: raylib/sokol tests shouldn't link SDL either.
    cfg.gamepad = .none;
    return cfg;
}

test "testsTargetConfig: never resolves gamepad .auto — tests must not link SDL (any backend)" {
    // bgfx (defaults .none) AND raylib/sokol (default .auto) all pin to .none
    // for the tests target; an explicit project-level .auto is overridden too.
    const backends = [_]config.Backend{ .bgfx, .raylib, .sokol };
    for (backends) |b| {
        const implicit = testsTargetConfig(.{ .name = "g", .backend = b });
        try std.testing.expectEqual(config.GamepadSource.none, implicit.effectiveGamepad());
        const explicit_auto = testsTargetConfig(.{ .name = "g", .backend = b, .gamepad = .auto });
        try std.testing.expectEqual(config.GamepadSource.none, explicit_auto.effectiveGamepad());
    }
    // And the other overrides hold: null backend, host platform.
    const c = testsTargetConfig(.{ .name = "g", .backend = .bgfx, .platform = .android });
    try std.testing.expectEqual(config.Backend.null, c.backend);
    try std.testing.expectEqual(config.Platform.desktop, c.platform);
}

/// Build the body of `__tests_root.zig`. One `_ = @import("tests/<stem>.zig");`
/// per discovered test file, all inside a single anonymous `test { }` block
/// so they're statically referenced from the test runner's root module.
fn generateTestsRoot(allocator: std.mem.Allocator, test_names: []const []const u8) ![]const u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();
    const w = &alloc_writer.writer;

    try w.writeAll(
        \\// Auto-generated by labelle-assembler. Do not edit.
        \\//
        \\// Pulls every `tests/**/*.zig` test file into a single test compile
        \\// unit rooted at the build directory, so relative `@import` paths
        \\// resolve against the same root the exe sees.
        \\
        \\test {
        \\
    );
    for (test_names) |stem| {
        try w.print("    _ = @import(\"tests/{s}.zig\");\n", .{stem});
    }
    try w.writeAll("}\n");

    var arr_list = alloc_writer.toArrayList();
    return arr_list.toOwnedSlice(allocator);
}

// ── Template loading (root/templates.zig) ───────────────────────────
pub const loadBackendTemplate = templates.loadBackendTemplate;
