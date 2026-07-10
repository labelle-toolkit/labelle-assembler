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
const manifest_splice = @import("codegen/manifest_splice.zig");
pub const manifest_v2 = @import("codegen/manifest_v2.zig");
const manifest_v2_splice = @import("codegen/manifest_v2_splice.zig");
const capabilities = @import("capabilities.zig");
pub const template = @import("template.zig");
pub const plugin_manifest = @import("plugin_manifest.zig");
pub const pack_validate = @import("pack_validate.zig");
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
    _ = @import("pack_validate.zig");
    _ = @import("check.zig");
    _ = @import("scene_name_lint.zig");
    _ = @import("scene_manifest.zig");
    _ = @import("scene_manifest_test.zig");
    _ = @import("tilemap_scan_test.zig"); // covers tilemap_scan + tilemap_scene_scan
    _ = @import("asset_validator.zig");
    _ = @import("pack_resources.zig");
    _ = @import("language_policy.zig");
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
};

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
// The supported-language table plus the `.language` / `requires_language` /
// script-dir checks. Wired into `generate()` via
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
    // Enforce the `.language` declaration rules (supported vocabulary, at
    // most ONE declaring plugin), every plugin/pack manifest's
    // `requires_language`, and the script-dir language scan (game root +
    // every pack source dir) — BEFORE the target dir is created, so a policy
    // violation rejects the build cheaply without leaving stale output,
    // exactly like the pack-graph gate above. Parse + validate ONLY: no
    // codegen consumes `.language` yet (the scripting plugin that does is a
    // separate ticket), so a clean project generates byte-identical output.
    try generate_phases.validateLanguagePolicy(allocator, pack_entries.items, cfg.plugins, game_dir);

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
    // rgba texture-path swaps above already ran on the game resources (their
    // `.astc`/`.rgba` siblings live in the game tree); pack resources ship
    // prebuilt and ride the plain `.png` path.
    var merged_resources = try pack_resources.mergePackResources(allocator, mutable_resources, resource_entries.items);
    defer merged_resources.deinit();
    cfg.resources = merged_resources.resources;

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
    try scanner.linkDir(allocator, game_dir, target_dir, "scripts");

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

    // Embedded-tilemap registrations (T2 Phase 4 + T3 #561/#562). AFTER
    // `loadPackScans` so the prefab scan (assembler#561) sees the staged pack
    // prefab JSONC and pack-registered `Tilemap` (assembler#562). See
    // tilemap_phase.
    const tilemap_registrations = try tilemap_phase.collectRegistrations(allocator, target_dir, scene_manifests, component_names, prefab_names, pack_scans.items);
    defer tilemap_scan.freeRegistrations(allocator, tilemap_registrations);

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
        // Manifest-driven backend splice (assembler#378): pass the project
        // root so the splice can locate `backend.manifest.zon` + fragments.
        // Only consulted when the gate (desktop + manifest present) fires.
        .project_dir = game_dir,
        // manifest-v2 cutover: the auto-detected v2 manifest name (null → v1/enum,
        // byte-unchanged). When a v2 manifest is present this routes the
        // backend-dep + link sections to the v2 codegen (`manifest_v2_splice`).
        .backend_manifest_name = backend_manifest_name,
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
    const game_shim = try generateGameShim(allocator, plugin_events.entries, plugin_flow_decls.flow_nodes, .{
        .is_tests_target = is_tests_target,
        .ecs = cfg.ecs,
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
            prefab_names,
            enum_names,
            event_names,
            hook_names,
            merged_entries,
            plugin_flow_decls.flow_nodes,
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
            plugin_events.entries,
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
    var cfg = cfg_in;
    cfg.backend = .null;
    // Force the host platform too. For wasm/ios/android projects, leaving
    // cfg.platform as-is would route the tests target through the
    // cross-compile build template (which omits the test step entirely),
    // producing a build.zig that builds cleanly but never runs tests. The
    // tests target is meant to run on the developer's host regardless of
    // what the exe target ships as.
    cfg.platform = .desktop;
    try generate(allocator, cfg, output_dir, game_dir, .{
        .target_name_override = "tests",
        .is_tests_target = true,
    });
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
