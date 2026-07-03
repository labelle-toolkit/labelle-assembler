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
pub const asset_validator = @import("asset_validator.zig");
pub const lazy_inference = @import("lazy_inference.zig");
pub const main_zig = @import("main_zig.zig");
pub const script_scanner = @import("script_scanner.zig");
pub const flow_scanner = @import("flow_scanner.zig");
pub const flow_catalog = @import("flow_catalog.zig");
pub const pack_manifest = @import("manifest.zig");
const build_files = @import("build_files.zig");
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
const idents = @import("codegen/idents.zig");

// Force test discovery for files that aren't transitively reached by
// any compiled function path during `addTest` runs.
test {
    _ = @import("config.zig");
    _ = @import("plugin_manifest.zig");
    _ = @import("pack_validate.zig");
    _ = @import("check.zig");
    _ = @import("scene_name_lint.zig");
    _ = @import("scene_manifest.zig");
    _ = @import("scene_manifest_test.zig");
    _ = @import("asset_validator.zig");
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
    _ = @import("capabilities.zig");
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

/// Static prelude of the per-project `game.zig` shim. Re-exports the
/// engine's default `Game` type and its associated `EntityId` so
/// generated flow files (emitted by `flow-codegen`) can satisfy
/// `@import("game")` with `Game` and `EntityId` decls at the module
/// root. Closes the remaining gap on labelle-gui#96 / labelle-assembler#116.
///
/// Limitation: this re-exports `engine.Game = GameWith(void)`, which
/// won't match the project's own `AssembledGame = engine.GameConfig(...)`
/// instantiation. Flow files compile in isolation (the `@import("game")`
/// resolves and `Game` / `EntityId` are valid decls), but a full
/// `zig build` will still fail when codegen emits bare identifiers like
/// `Position` that aren't in the flow file's lexical scope — that's a
/// separate codegen-side gap tracked on labelle-gui (see PR body).
///
/// `generateGameShim` (below) appends a `PluginEvents` re-export when
/// the project declares plugins; flow-codegen's new-form `OnEvent`
/// handler reflects against `@FieldType(game.PluginEvents, "<tag>")` to
/// derive the payload signature.
const game_shim_prelude =
    \\//! Generated by labelle-assembler — DO NOT EDIT.
    \\//! Re-exports engine types as `Game` and `EntityId` so generated
    \\//! flow files (`scripts/flows/*.zig`) resolve `@import("game")`.
    \\//! See labelle-assembler#116.
    \\
    \\const std = @import("std");
    \\const engine = @import("labelle-engine");
    \\
    \\/// Default engine game type. Codegen emits `game: *Game` parameters
    \\/// at hook entry points; the value passed at runtime is the
    \\/// project's `AssembledGame` instantiation (declared in main.zig).
    \\/// These two types are not identical — see the file header on
    \\/// labelle-assembler#116 for the documented limitation.
    \\pub const Game = engine.Game;
    \\
    \\/// Entity identifier type. Mirrors `Game.EntityType` so flow files
    \\/// can declare `entity: EntityId` parameters without reaching into
    \\/// the engine module directly.
    \\pub const EntityId = engine.Game.EntityType;
    \\
    \\
;

/// Static prelude of the `.labelle/tests/` `game.zig` shim
/// (labelle-assembler#275). Unlike the default prelude above — which
/// re-exports `engine.Game` (the mock-ECS / stub-render convenience
/// instantiation) — the tests target instantiates `Game` over the
/// project's REAL ECS backend (`@import("ecs_backend")`) so a
/// backend-agnostic `labelle test` can drive a plugin's systems
/// headless.
///
/// Why this is required, not just nicer: a plugin's ECS iteration
/// (e.g. `box2d`'s `iter.deinit(game.ecs_backend.alloc)`) is compiled
/// against the project's configured ECS backend, whose `QueryIterator`
/// `deinit` takes an allocator. The mock backend's `deinit` takes none,
/// so `box2d.Systems.tick(&g, dt)` fails to compile against `engine.Game`
/// even though the plugin's `labelle-core` is already unified onto
/// `core_mod` in the generated `build.zig`. Pointing the test game's
/// `ecs_backend` at the same `@import("ecs_backend")` module the plugin
/// resolves makes the iterator types — and the underlying core — match.
/// Closes labelle-assembler#275 (and the practical half of #116 for the
/// test target).
///
/// Everything else stays a stub: `StubRender` (no GPU; provides the
/// no-op `markPositionDirty` plugins call from `postTick`), `StubInput`
/// / `StubAudio` / `StubGui`, no hooks (`void`), and `void` `GameEvents`
/// (so a plugin's tolerant `emitGameEvent` folds to a no-op exactly as it
/// does for `engine.Game`). The empty `Components` registry is fine: the
/// engine's generic `addComponent`/`getComponent`/`query` are type-driven
/// and don't consult it.
const game_shim_tests_prelude_header =
    \\//! Generated by labelle-assembler — DO NOT EDIT.
    \\//! `.labelle/tests/` game shim (labelle-assembler#275). Instantiates
    \\//! `Game` over the project's REAL ECS backend so `labelle test` can
    \\//! drive plugin systems headless. See #275 / #116.
    \\
    \\const std = @import("std");
    \\const engine = @import("labelle-engine");
    \\
;

/// Body of the tests-target shim shared by every ECS choice: stub
/// renderer/input/audio/gui, no hooks, empty components, no game events.
/// `EcsBackend` (and its `Entity`) are declared by the caller-selected
/// header that precedes this block.
const game_shim_tests_prelude_body =
    \\
    \\const EmptyComponents = struct {
    \\    pub fn has(comptime _: []const u8) bool {
    \\        return false;
    \\    }
    \\    pub fn names() []const []const u8 {
    \\        return &.{};
    \\    }
    \\};
    \\
    \\/// The project's configured game, instantiated for headless tests:
    \\/// REAL ecs backend (matches the plugin's core) + stubs for render,
    \\/// input, audio, gui. See the file header / labelle-assembler#275.
    \\pub const Game = engine.GameConfig(
    \\    engine.core.StubRender(EcsBackend.Entity),
    \\    EcsBackend,
    \\    engine.StubInput,
    \\    engine.StubAudio,
    \\    engine.StubGui,
    \\    void,
    \\    engine.core.StubLogSink,
    \\    EmptyComponents,
    \\    &.{},
    \\    void,
    \\);
    \\
    \\/// Entity identifier type. Mirrors `Game.EntityType` so flow files
    \\/// can declare `entity: EntityId` parameters.
    \\pub const EntityId = Game.EntityType;
    \\
    \\
;

/// Generate the per-project `game.zig` shim. Caller owns the returned
/// bytes. Built from `game_shim_prelude` plus a `PluginEvents` block
/// (RFC-PLUGIN-EVENTS phase 3) when at least one plugin actually
/// declares events, so flow-codegen's new-form `OnEvent` handler can
/// resolve event names against `@FieldType(game.PluginEvents, "<tag>")`
/// through the same `@import("game")` flow files already use. The block
/// is identical to the one `main_zig.writePluginEventsBlock` emits into
/// `main.zig` — same assembler-time AST walk, same qualified variant
/// tags. The `overrideImport(game_mod, "<plugin>", ...)` calls in
/// `build_files.generateBuildZig` wire each plugin module into
/// `game_mod` so the `@import("<plugin>")` calls inside the block
/// resolve.
///
/// Caller passes the pre-computed `plugin_events` list (see
/// `main_zig.discoverPluginEvents`) so the discovery happens once per
/// `generate` invocation rather than twice (shim + main.zig). When the
/// list is empty (declared plugins but no `Events` decls) the shim
/// omits the block entirely — there's nothing for flow-codegen to
/// reflect against.
///
/// `plugin_flow_nodes` (labelle-assembler#240 Gap 1) is the same
/// discovered FlowNode list `main_zig.writePluginFlowNodesBlock` consumes
/// for `main.zig`. Generated flow files emit
/// `@import("game").PluginFlowNodes.<qualified>.impl(...)` for every
/// `CustomNode`, so the shim must expose a `PluginFlowNodes` block whose
/// decl names + `resolve`/`sanitizeModuleIdent` helpers are byte-identical
/// to main.zig's — otherwise the flow file fails to compile with
/// `struct 'game' has no member named 'PluginFlowNodes'`. The block is
/// emitted only when at least one node was discovered: with no flow nodes
/// no flow file references `game.PluginFlowNodes`, so the empty `struct {}`
/// shell would be dead weight (and game-script nodes additionally need the
/// named-module wiring in build.zig — Gap 2 — which `root.zig:generate`
/// emits in lockstep).
pub const GameShimOptions = struct {
    /// Emit the `.labelle/tests/` shim (labelle-assembler#275): `Game`
    /// instantiated over the project's real ECS backend instead of the
    /// default `engine.Game` re-export. `ecs` selects which backend the
    /// shim declares as `EcsBackend`.
    is_tests_target: bool = false,
    /// The project's configured ECS choice — only consulted when
    /// `is_tests_target` is set, to pick `@import("ecs_backend")` (real
    /// adapter) vs `engine.MockEcsBackend(u32)`.
    ecs: config.EcsChoice = .mock,
};

pub fn generateGameShim(
    allocator: std.mem.Allocator,
    plugin_events: []const main_zig.PluginEvent,
    plugin_flow_nodes: []const main_zig.PluginFlowNode,
    opts: GameShimOptions,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    if (opts.is_tests_target) {
        // labelle-assembler#275 — the tests target instantiates `Game`
        // over the real ECS backend so plugin systems compile + run
        // headless. The `EcsBackend` decl varies by ECS choice; the
        // rest of the prelude (stubs, `Game`, `EntityId`) is shared.
        try w.writeAll(game_shim_tests_prelude_header);
        if (opts.ecs == .mock) {
            try w.writeAll("const EcsBackend = engine.MockEcsBackend(u32);\n");
        } else {
            // The same module the plugins resolve via `@import("ecs_backend")`
            // (wired by `tests_ecs_import` in the generated build.zig), so the
            // test game's `ecs_backend` and the plugins' iterators share a type.
            try w.writeAll("const EcsBackend = @import(\"ecs_backend\");\n");
        }
        try w.writeAll(game_shim_tests_prelude_body);
    } else {
        try w.writeAll(game_shim_prelude);
    }

    if (plugin_events.len > 0 or plugin_flow_nodes.len > 0) {
        // Dispatch through a minimal `Codegen` context so the shim's
        // emission path matches the orchestrator's — `writePluginEventsBlock`
        // / `writePluginFlowNodesBlock` are mixin methods that read
        // `self.plugin_events` / `self.plugin_flow_nodes`. Mirrors
        // `main_template.zig`'s `ctx.writePluginXxxBlock(bw)` calls so the
        // shim's blocks are bit-identical to the ones emitted into main.zig.
        var ctx: main_zig.Codegen = .{
            .allocator = allocator,
            .cfg = .{ .name = "", .ecs = .mock },
            .script_entries = &.{},
            .prefab_names = &.{},
            .jsonc_scene_names = &.{},
            .scene_manifests = &.{},
            .component_names = &.{},
            .hook_names = &.{},
            .event_names = &.{},
            .enum_names = &.{},
            .view_names = &.{},
            .gizmo_names = &.{},
            .animation_names = &.{},
            .plugin_events = plugin_events,
            .plugin_flow_nodes = plugin_flow_nodes,
            .plugin_pin_styles = &.{},
            .plugin_coercions = &.{},
        };
        if (plugin_events.len > 0) try ctx.writePluginEventsBlock(w);
        // Gap 1 — surface `PluginFlowNodes` so flow files'
        // `@import("game").PluginFlowNodes.<qualified>.impl(...)` resolves.
        // Game-script nodes inside this block reference named modules
        // (`@import("script__<sanitized>")`); the matching
        // `overrideImport(game_mod, "script__<sanitized>", ...)` in
        // `build_files.generateBuildZig` makes them resolvable from the
        // `game` module.
        if (plugin_flow_nodes.len > 0) try ctx.writePluginFlowNodesBlock(w);
    }

    var arr_list = aw.toArrayList();
    return arr_list.toOwnedSlice(allocator);
}

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

/// Resolve-time provider-contract checks (RFC "Opening the ecosystem",
/// §1616-1683): canonical provider identity, cross-provider id collision, and
/// capability negotiation, all read from the resolved backend's
/// `backend.manifest.zon` BEFORE the build graph is emitted.
///
/// Reads the identity/capability slice via `loadProviderManifest`, which is
/// DECOUPLED from the desktop-only splice gate (`manifestPathEnabled`) — these
/// checks apply on every target (android/wasm/ios included). A provider that
/// ships no manifest yields a null slice: identity is derived, capabilities are
/// un-enforced (the back-compat path).
/// `is_tests_target` scopes the CAPABILITY gate OUT for the tests target
/// (issue #83): that target force-substitutes `cfg.backend = .null` as a
/// headless test HARNESS while keeping the rest of the project config (e.g.
/// `resolved_gui = imgui`), so `requiredCapabilities(cfg)` still derives the
/// REAL backend's needs (`.raw_gui_adapter`, …). The forced-null harness never
/// builds the real GUI/gamepad, so requiring it to satisfy those capabilities
/// is wrong — and now that null ships a v2 manifest declaring only `.headless`,
/// the opted-in gate would hard-fail `zig build test` for any GUI/gamepad
/// project. Identity + id-collision checks stay ON for the tests target (cheap
/// and still valid); only the capability REQUIREMENT check is skipped. The real
/// exe target (`is_tests_target = false`) is unaffected — a GUI project whose
/// chosen backend lacks `.raw_gui_adapter` must still fail.
pub fn validateProviderContracts(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    game_dir: []const u8,
    backend_manifest_name: ?[]const u8,
    is_tests_target: bool,
) !void {
    // ── manifest-v2 cutover (epic #453, closes #472 P2 finding 2) ──────
    // When `generate` auto-detected a v2 manifest, the provider identity +
    // capabilities live in the v2 `.id`/`.capabilities`. Read them off the v2
    // manifest and run the SAME contract checks. `backend_manifest_name` is null
    // when the package ships no v2 manifest, in which case the legacy provider
    // identity/capabilities slice (`loadProviderManifest`) is read below.
    if (backend_manifest_name) |name| {
        const m = try manifest_v2.loadNamedManifest(allocator, cfg, game_dir, name);
        defer std.zon.parse.free(allocator, m);
        // Privileged lifecycle blocks (sokol readback / bgfx shell) are reserved
        // to the `labelle.*` namespace (#461) — checked here, where the parsed
        // manifest's platforms are in scope.
        try backend_registry.assertLifecyclePrivilege(cfg, m.declaresPrivilegedLifecycle(), m.id);
        return validateProviderContractsInner(allocator, cfg, m.id, m.capabilities, is_tests_target);
    }

    const maybe_pm = try manifest_splice.loadProviderManifest(allocator, cfg, game_dir);
    const manifest_id: ?[]const u8 = if (maybe_pm) |pm| pm.id else null;
    const declared: []const config.Capability = if (maybe_pm) |pm| pm.capabilities else &.{};
    defer if (maybe_pm) |pm| manifest_splice.freeProviderManifest(allocator, pm);

    return validateProviderContractsInner(allocator, cfg, manifest_id, declared, is_tests_target);
}

/// The identity + capability contract checks, factored out so BOTH the legacy
/// (v1 provider manifest) and the v2 (auto-detected build-graph manifest) paths
/// run the exact same negotiation against whichever `.id`/`.capabilities` the
/// resolved manifest carries.
fn validateProviderContractsInner(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    manifest_id: ?[]const u8,
    declared: []const config.Capability,
    is_tests_target: bool,
) !void {
    // Provider identity: reserved-namespace + enum-shorthand drift.
    try backend_registry.validateProviderIdentity(cfg, manifest_id);

    // Cross-provider id collision over the full resolved provider set. Today
    // that set is the single render backend, so this is future-proofing (the
    // one place the whole set is cross-checked); plugins/audio providers join
    // it once they carry identities.
    if (manifest_id) |id| {
        try backend_registry.checkProviderIdCollisions(&.{id});
    }

    // Capability negotiation. Enforcement is OPT-IN: a provider declaring a
    // non-empty `.capabilities` set has missing requirements fail hard; a
    // provider declaring none is only warned (back-compat gate in `validate`).
    //
    // SKIPPED for the tests target (issue #83): its `cfg.backend` was
    // force-substituted to `.null` (a headless test harness) while the rest of
    // the config still describes the REAL backend's needs, so validating the
    // null harness against the project's real-backend capabilities is wrong.
    // Identity + collision checks above stay ON (cheap + still valid). The real
    // exe target still enforces the gate.
    if (is_tests_target) return;
    const required = try capabilities.requiredCapabilities(allocator, cfg);
    defer allocator.free(required);
    const provider_id = manifest_id orelse cfg.backendName();
    try capabilities.validate(required, declared, provider_id);
}

/// Auto-detect whether the resolved backend package ships a v2 build-graph
/// manifest (`backend.manifest.v2.zon`) and, if so, return its canonical
/// filename so `generate` drives the manifest-v2 codegen path (epic #453,
/// closing the #472 P2 gap). Returns `V2_MANIFEST_NAME` (a static string, so no
/// allocation to free) when the package ships one, else `null` → the v1/enum
/// path, unchanged.
///
/// LIVE AUTO-DETECTION (the #472 P2 cutover shipped): whether this fires on a
/// real `generate` depends ONLY on the resolved backend package shipping the
/// file — no caller opt-in. The in-tree sokol package (`local:backends/sokol`)
/// and the v2 fixtures ship one; a fetched provider repo opts in per-repo by
/// adding the file. When it fires, the detected name is threaded through every
/// downstream site (template selection, loop-style, build.zig/zon, hook staging)
/// — see test/build_zig_tests.zig `MANIFEST_V2_GENERATE_CUTOVER`. For a
/// dual-manifest backend the v2 DESKTOP build.zig stays byte-identical to the
/// v1/enum splice (the §7 anchor test).
///
/// GRACEFUL DEGRADATION: any probe I/O error (package resolution failure, a
/// missing dir, an access error, OOM building the path) falls back to null (the
/// v1/enum path) rather than crashing — mirroring the swallow-and-fall-back
/// discipline the rest of `generate`'s manifest probing uses
/// (`manifest_splice.manifestExists`). A genuine external-backend
/// misconfiguration is still surfaced separately by `requireManifestIfExternal`.
fn detectV2ManifestName(allocator: std.mem.Allocator, cfg: ProjectConfig, project_dir: []const u8) ?[]const u8 {
    const pkg_dir = backend_registry.resolveBackendPackage(allocator, cfg, project_dir) catch return null;
    defer allocator.free(pkg_dir);
    const manifest_path = std.fs.path.join(allocator, &.{ pkg_dir, manifest_v2.V2_MANIFEST_NAME }) catch return null;
    defer allocator.free(manifest_path);
    std.Io.Dir.cwd().access(config.globalIo(), manifest_path, .{}) catch return null;
    return manifest_v2.V2_MANIFEST_NAME;
}

/// Resolve the run-loop-style override for `main.zig` codegen from the v2 backend
/// manifest's PER-PLATFORM `.platforms[<platform>].loop_style` (bgfx-desktop is
/// `.loop`, bgfx-android `.callback` — the style MUST be per-platform). `null` →
/// no manifest name detected (the enum/v1 path is gone, so a backend that ships no
/// v2 manifest cannot generate). A load error is swallowed (fall back to null,
/// same probing discipline as the rest of the manifest detection).
pub fn resolveLoopStyleOverride(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    game_dir: []const u8,
    backend_manifest_name: ?[]const u8,
) !?manifest_v2.BackendManifestV2.PlatformEntry.LoopStyle {
    const name = backend_manifest_name orelse return null;
    const m = manifest_v2.loadNamedManifest(allocator, cfg, game_dir, name) catch return null;
    defer std.zon.parse.free(allocator, m);
    const entry = manifest_v2_splice.platformEntry(m, cfg.platform) orelse return null;
    return entry.loop_style;
}

/// Resolve the callback-lifecycle-blocks declaration for `main.zig` codegen from
/// the v2 backend manifest's `.platforms[<platform>].lifecycle` (assembler#501).
/// `null` → no declaration (built-ins keep the enum-predicate shape; an
/// UNDECLARED callback external is still rejected in `lifecycle/render.zig`).
///
/// Lifecycle blocks are a v2-ONLY concept — the v1 splice has no such field — so
/// this only inspects the detected named v2 manifest. Mirrors the `.v2` case of
/// `resolveLoopStyleOverride`; a load error is swallowed (fall back to null, same
/// probing discipline). The returned `Lifecycle` is a copy of trivial bool
/// flags, so it stays valid after the parsed manifest is freed.
pub fn resolveLifecycleOverride(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    game_dir: []const u8,
    backend_manifest_name: ?[]const u8,
) !?manifest_v2.BackendManifestV2.PlatformEntry.Lifecycle {
    const name = backend_manifest_name orelse return null;
    const m = manifest_v2.loadNamedManifest(allocator, cfg, game_dir, name) catch return null;
    defer std.zon.parse.free(allocator, m);
    const entry = manifest_v2_splice.platformEntry(m, cfg.platform) orelse return null;
    return entry.lifecycle;
}

/// Copy + scan one convention subdir of a pack into the generated target,
/// returning the sorted file stems. Source is `<pack_src_dir>/<subdir>`;
/// destination is `<dst_base>/<subdir>` (a generator-owned dir under
/// `<target>/packs/<name>/`). A missing source subdir is tolerated —
/// `copyAndScanAbs` returns an empty list — so a pack can ship, say,
/// `components/` + `events/` without a `prefabs/` and not error.
fn scanPackSubdir(
    allocator: std.mem.Allocator,
    pack_src_dir: []const u8,
    dst_base: []const u8,
    subdir: []const u8,
    ext: []const u8,
) ![][]const u8 {
    const src = try std.fs.path.join(allocator, &.{ pack_src_dir, subdir });
    defer allocator.free(src);
    const dst = try std.fs.path.join(allocator, &.{ dst_base, subdir });
    defer allocator.free(dst);
    return scanner.copyAndScanAbs(allocator, src, dst, ext);
}

/// Select the decl-module subset of `plugins` (labelle-assembler#481).
///
/// A game's `.plugins` list mixes two kinds of dependency:
///
///   - **decl-module plugins** — a real Zig package (`plugin.labelle` +
///     `src/root.zig` exports) that the generated build wires in as a module
///     and the generated `main.zig` reaches via `@import("<name>")`.
///   - **light packs** — module-less, directory-scanned convention bundles
///     (they carry `pack.labelle`, so their name appears in `pack_names`).
///     A light pack has NO `build.zig` and NO importable module; its entire
///     contribution is the already-scanned + `<pack>__`-namespaced registry
///     entries (#439/#440). Emitting `@import("<pack>")` or a
///     `b.dependency("labelle_<pack>", …)` for one fails to resolve and breaks
///     `labelle build` — the gap this ticket closes.
///
/// Returns the subset of `plugins` whose name is NOT in `pack_names`, i.e. the
/// plugins that DO ship an importable module. The order of `plugins` is
/// preserved. The returned slice is caller-owned (`allocator.free`); the
/// `PluginDep` elements are shallow copies that alias the input's strings.
pub fn declModulePlugins(
    allocator: std.mem.Allocator,
    plugins: []const config.PluginDep,
    pack_names: []const []const u8,
) ![]config.PluginDep {
    var out: std.ArrayList(config.PluginDep) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, plugins.len);
    for (plugins) |plugin| {
        var is_light_pack = false;
        for (pack_names) |pack_name| {
            if (std.mem.eql(u8, pack_name, plugin.name)) {
                is_light_pack = true;
                break;
            }
        }
        if (!is_light_pack) out.appendAssumeCapacity(plugin);
    }
    return out.toOwnedSlice(allocator);
}

/// Scan a pack's convention subdirs (Packs RFC §4, labelle-assembler#439).
///
/// Copies `<pack_src_dir>/{components,events,prefabs,hooks}/` into
/// `<target_dir>/packs/<pack_name>/{...}/` and collects the scanned stems
/// into a `PackScan` whose `import_prefix` is `packs/<pack_name>` — the path
/// the generated `main.zig` imports through. The returned `PackScan` owns
/// every string; the caller must `deinit` it.
///
/// After copying the pack's `prefabs/`, this rewrites each copied prefab's
/// local component references to the invisible `<pack>__<Name>` form (#440,
/// see `scan.rewritePackComponentKeys`) so a pack author's `.Worker` resolves
/// against the namespaced field the component registry emits. Only the pack's
/// OWN scanned components are rewritten; built-in/engine names are left alone.
///
/// Exposed publicly so tests can exercise the copy/scan without the full
/// cache-resolution + codegen pipeline.
/// Copy a light pack's `scripts/` subtree into `<target>/packs/<name>/scripts/`
/// and register it into `script_scan` (labelle-assembler#487). Call at the
/// pack's `.plugins` declaration-order position so the scanner's `plugin_index`
/// reflects that order (#494).
///
/// Pack scripts land UNDER the pack dir (NOT `scripts/.plugin_<name>/`) so a
/// pack script's own `@import("../components/foo.zig")` keeps resolving against
/// the pack's copied `components/`.
///
/// If the pack ships NO `scripts/` source, this prunes any STALE destination a
/// PRIOR `generate` copied (whose upstream `scripts/` has since been removed)
/// and registers nothing. Without the prune, `copyAndScanAbs` would no-op on
/// the missing source — leaving the stale copy in place — and the subsequent
/// `scanPackScriptsDir` would pick those leftovers up and compile them
/// (labelle-assembler#496, codex review). Returns true iff scripts were
/// registered.
pub fn scanPackScriptsAt(
    allocator: std.mem.Allocator,
    script_scan: *script_scanner.ScriptScanner,
    pack_src_dir: []const u8,
    target_dir: []const u8,
    pack_name: []const u8,
) !bool {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();

    const pack_scripts_src = try std.fs.path.join(allocator, &.{ pack_src_dir, "scripts" });
    defer allocator.free(pack_scripts_src);
    const pack_scripts_dst = try std.fs.path.join(allocator, &.{ target_dir, "packs", pack_name, "scripts" });
    defer allocator.free(pack_scripts_dst);

    // Probe the pack's source `scripts/` dir. Mirror `copyAndScanAbs`'s
    // source-root open EXACTLY (scanner.copyAndScanRecursive): tolerate ONLY
    // `error.FileNotFound` — the absent-directory case — and PROPAGATE every
    // other `openDir` failure. Swallowing e.g. `AccessDenied` (broken mount /
    // permissions) or `NotDir` (`scripts` is a file) as "no scripts" would
    // prune the generated copy and silently produce an incomplete build
    // instead of surfacing the real error (codex P2 on #500).
    var probe = cwd.openDir(io, pack_scripts_src, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            // No `scripts/` source → prune any stale dest a prior generate copied.
            cwd.deleteTree(io, pack_scripts_dst) catch {};
            return false;
        },
        else => return err,
    };
    probe.close(io);

    const names = try scanner.copyAndScanAbs(allocator, pack_scripts_src, pack_scripts_dst, ".zig");
    scanner.freeNames(allocator, names);
    // The generated `@import` base is the target-relative dir, mirroring
    // `PackScan.import_prefix` (`packs/<name>`) plus `/scripts`.
    const import_prefix = try std.fmt.allocPrint(allocator, "packs/{s}/scripts", .{pack_name});
    defer allocator.free(import_prefix);
    try script_scan.scanPackScriptsDir(pack_scripts_dst, import_prefix, pack_name);
    return true;
}

pub fn scanPack(
    allocator: std.mem.Allocator,
    pack_src_dir: []const u8,
    target_dir: []const u8,
    pack_name: []const u8,
) !main_zig.PackScan {
    const import_prefix = try std.fmt.allocPrint(allocator, "packs/{s}", .{pack_name});
    errdefer allocator.free(import_prefix);
    const name_owned = try allocator.dupe(u8, pack_name);
    errdefer allocator.free(name_owned);

    const dst_base = try std.fs.path.join(allocator, &.{ target_dir, "packs", pack_name });
    defer allocator.free(dst_base);

    const component_names = try scanPackSubdir(allocator, pack_src_dir, dst_base, "components", ".zig");
    errdefer scanner.freeNames(allocator, component_names);
    const event_names = try scanPackSubdir(allocator, pack_src_dir, dst_base, "events", ".zig");
    errdefer scanner.freeNames(allocator, event_names);
    const prefab_names = try scanPackSubdir(allocator, pack_src_dir, dst_base, "prefabs", ".jsonc");
    errdefer scanner.freeNames(allocator, prefab_names);
    // hooks/ (#440): scanned + registered into the game-root hook pipeline
    // under the `<pack>__` ident prefix (see the hook block-writers).
    const hook_names = try scanPackSubdir(allocator, pack_src_dir, dst_base, "hooks", ".zig");
    errdefer scanner.freeNames(allocator, hook_names);

    // Local→prefixed ref rewrite (#440): rewrite the copied prefab JSONC so a
    // pack's own component references (`"Worker"`) and prefab compositions
    // (`{ "prefab": "worker" }`) become the namespaced forms
    // (`"citizens__Worker"` / `"citizens__worker"`). Done against the copied
    // (destination) files so the source pack tree is never mutated.
    try rewritePackPrefabRefs(allocator, dst_base, pack_name, component_names, prefab_names);
    // …and rewrite the copied hook sources so a handler written with the pack's
    // bare local event name receives its `<pack>__`-prefixed event (chatgpt-codex
    // #3). Same "mutate the copy, never the source" discipline.
    try rewritePackHookHandlers(allocator, dst_base, pack_name, event_names, hook_names);

    return .{
        .name = name_owned,
        .import_prefix = import_prefix,
        .component_names = component_names,
        .event_names = event_names,
        .prefab_names = prefab_names,
        .hook_names = hook_names,
    };
}

/// Rewrite every copied pack prefab JSONC in place so its local references
/// become the invisible `<pack>__…` form (#440). Two reference kinds are
/// rewritten (see `scan.rewritePackLocalRefs`):
///
///   - **Component keys** — Pascal forms of the pack's scanned component
///     stems, only in genuine component-declaration positions (context-aware,
///     chatgpt-codex #2). Payload-data keys that happen to share a component's
///     spelling are left alone. This covers BOTH authoring shapes (#513): the
///     wrapped `"components"`/`"overrides"` maps directly, and the flat
///     RFC #596 shape via a normalization pre-pass — a flat entity that
///     declares pack-local components is converted to the wrapped shape in
///     the copy, because a namespaced (lowercase-starting) key would be
///     silently dropped by the engine's case-based flat-key classification
///     (see `scan.wrapFlatEntityComponents`). All three engine-accepted
///     top-level FILE shapes are walked (#516): the plain entity object,
///     RFC #596 file-as-array bundles (only-`meta` header skipped), and
///     legacy `"root"`-wrapper files.
///   - **Prefab references** — a `"prefab": "worker"` value naming one of the
///     pack's OWN prefabs becomes `"prefab": "citizens__worker"`, matching the
///     namespaced registration key so a same-pack prefab composition resolves
///     (chatgpt-codex #1). A pack with prefabs that reference each other but
///     ships no components is still rewritten (the guard is on prefab count,
///     not component count).
fn rewritePackPrefabRefs(
    allocator: std.mem.Allocator,
    dst_base: []const u8,
    pack_name: []const u8,
    component_names: []const []const u8,
    prefab_names: []const []const u8,
) !void {
    // Nothing to walk without prefab files. Note the guard is intentionally
    // NOT gated on `component_names` — a component-less pack can still have
    // prefab-to-prefab references that need namespacing (chatgpt-codex #1).
    if (prefab_names.len == 0) return;

    var prefix_buf: [128]u8 = undefined;
    const prefix = scan.packNamespacePrefix(pack_name, &prefix_buf);

    // Build the Pascal-form key set once — this is the exact string a JSONC
    // component key uses and the exact field the registry emits.
    var keys: std.ArrayList([]const u8) = .empty;
    defer {
        for (keys.items) |k| allocator.free(k);
        keys.deinit(allocator);
    }
    try keys.ensureTotalCapacity(allocator, component_names.len);
    for (component_names) |stem| {
        var pascal_buf: [128]u8 = undefined;
        const pascal = idents.pathToPascal(stem, &pascal_buf);
        keys.appendAssumeCapacity(try allocator.dupe(u8, pascal));
    }

    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const prefabs_dir = try std.fs.path.join(allocator, &.{ dst_base, "prefabs" });
    defer allocator.free(prefabs_dir);

    for (prefab_names) |name| {
        const rel = try std.fmt.allocPrint(allocator, "{s}.jsonc", .{name});
        defer allocator.free(rel);
        const path = try std.fs.path.join(allocator, &.{ prefabs_dir, rel });
        defer allocator.free(path);

        const src = cwd.readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(src);

        const rewritten = try scan.rewritePackLocalRefs(allocator, src, keys.items, prefab_names, prefix);
        defer allocator.free(rewritten);

        // Generate-time net (#516): a component-declaration position that
        // still uses one of the pack's own BARE names after the rewrite will
        // NOT attach at load — warn now instead of failing silently there.
        warnLeftoverBareKeys(allocator, path, rewritten, keys.items);

        // Only rewrite the file when the content actually changed — avoids
        // churning mtimes (and the build cache) on prefabs with no local refs.
        if (std.mem.eql(u8, rewritten, src)) continue;
        var f = try cwd.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, rewritten);
    }
}

/// Log the #516 generate-time net findings for one rewritten pack-prefab
/// copy: every component declaration still using one of the pack's own bare
/// Pascal names after `scan.rewritePackLocalRefs` (see
/// `scene_name_lint.findBareLocalRefs` for what a survivor means), plus a
/// bundle file-header that carries a legacy `"entities"` list (#521 codex
/// P2) — the engine consumes a header as metadata and extracts only its
/// `meta`, so such a list is dead data that never loads; the rewrite
/// correctly skips it verbatim (engine parity, see
/// `scan.bundleHeaderLegacyEntitiesOffset`), and this warning is what
/// surfaces the probable authoring mistake. Never fails the build — the
/// net is a diagnostic, not a gate (mirrors `scanScenesDir`'s posture);
/// allocation failure just drops the warning.
fn warnLeftoverBareKeys(
    allocator: std.mem.Allocator,
    path: []const u8,
    rewritten: []const u8,
    local_keys: []const []const u8,
) void {
    if (scan.bundleHeaderLegacyEntitiesOffset(rewritten)) |off| {
        const loc = scene_name_lint.locOf(rewritten, off);
        std.log.warn(
            "labelle-assembler: pack prefab copy '{s}':{d}:{d} — the bundle's file-header element carries a legacy \"entities\" list. The engine reads only `meta` from a bundle header (RFC #596), so those entities are dead data that never loads; move them out of the header into top-level bundle elements (ref labelle-assembler#521).",
            .{ path, loc.line, loc.col },
        );
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const refs = scene_name_lint.findBareLocalRefs(arena_state.allocator(), rewritten, local_keys) catch return;
    for (refs) |ref| {
        std.log.warn(
            "labelle-assembler: pack prefab copy '{s}':{d}:{d} still declares component '{s}' by its bare local name after the pack rewrite — it will NOT attach at load. Either the entity mixes a components/overrides wrapper with flat keys (RFC #596 hybrid — pick one shape), or the key sits where the engine never reads it, or the file's shape escaped the rewriter (ref labelle-assembler#516).",
            .{ path, ref.line, ref.col, ref.name },
        );
    }
}

/// Rewrite every copied pack `hooks/*.zig` in place so a handler written with
/// the pack's BARE local event name receives its `<pack>__`-prefixed event
/// (chatgpt-codex #3). Mirrors `rewritePackPrefabRefs` but over the hook
/// sources and the pack's own event names — see
/// `scan.rewritePackHookHandlerNames` for the match rule. A pack with no
/// events (nothing to prefix) or no hooks is a no-op.
fn rewritePackHookHandlers(
    allocator: std.mem.Allocator,
    dst_base: []const u8,
    pack_name: []const u8,
    event_names: []const []const u8,
    hook_names: []const []const u8,
) !void {
    if (event_names.len == 0 or hook_names.len == 0) return;

    var prefix_buf: [128]u8 = undefined;
    const prefix = scan.packNamespacePrefix(pack_name, &prefix_buf);

    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    const hooks_dir = try std.fs.path.join(allocator, &.{ dst_base, "hooks" });
    defer allocator.free(hooks_dir);

    for (hook_names) |name| {
        const rel = try std.fmt.allocPrint(allocator, "{s}.zig", .{name});
        defer allocator.free(rel);
        const path = try std.fs.path.join(allocator, &.{ hooks_dir, rel });
        defer allocator.free(path);

        const src = cwd.readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(src);

        // `name` is the hook file stem (`overlay` / `combat/overlay`); the
        // rewrite scopes the rename to that file's receiver container
        // (`pathToPascal(name)`), so unrelated helpers are never touched.
        const rewritten = try scan.rewritePackHookHandlerNames(allocator, src, event_names, prefix, name);
        defer allocator.free(rewritten);

        if (std.mem.eql(u8, rewritten, src)) continue;
        var f = try cwd.createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, rewritten);
    }
}

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
    if (cfg.platform != .wasm) {
        cfg.editor_preview = false;
    } else if (!cfg.editor_preview) {
        const environ = config.globalEnviron();
        if (environ.getAlloc(allocator, "LABELLE_EDITOR_PREVIEW")) |v| {
            defer allocator.free(v);
            cfg.editor_preview = config.editorPreviewEnvEnabled(v);
        } else |_| {}
    }
    if (cfg.editor_preview) {
        // Generate-time breadcrumb: the splice compiles only against an
        // engine that ships `editor_api` (the generated main.zig carries a
        // matching `@compileError` guard so a stale pin fails with a clear
        // message rather than a bare "no member named 'editor_api'").
        std.log.info(
            "labelle-assembler: editor-preview wasm build (LABELLE_EDITOR_PREVIEW) — requires a labelle-engine that ships `editor_api`",
            .{},
        );
    }

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
    const backend_manifest_name = detectV2ManifestName(allocator, cfg, game_dir);
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
    if (cfg.editor_preview) {
        const v2_wasm_link = blk: {
            const name = backend_manifest_name orelse break :blk false;
            const m = manifest_v2.loadNamedManifest(allocator, cfg, game_dir, name) catch break :blk false;
            defer std.zon.parse.free(allocator, m);
            break :blk m.platforms.wasm != null;
        };
        if (!v2_wasm_link) {
            // Silenced under test — the Zig test runner fails any test that
            // emits `std.log.err`, even when the error is the asserted
            // outcome (see cache/env.zig's HOME-missing log for the same gate).
            if (!builtin.is_test) {
                std.log.err(
                    "labelle-assembler: editor-preview build requested (LABELLE_EDITOR_PREVIEW) but " ++
                        "backend '{s}' does not take the manifest-v2 wasm build path — only the v2 wasm " ++
                        "backend hook (post_wire) can thread the editor_* exports into the emcc link. " ++
                        "Upgrade the backend package (labelle-bgfx >= 0.6.1) or build without editor preview",
                    .{cfg.backendName()},
                );
            }
            return error.EditorPreviewUnsupportedByBackend;
        }
    }

    // Swap `.texture = "...png"` to the pre-converted `.astc` sibling when the
    // target platform opts into ASTC (`asset_compression`) and `labelle astc`
    // produced one. The runtime detects the ASTC magic and uploads the
    // compressed blocks with zero CPU decode (labelle-gfx#269 / #340). Done
    // BEFORE the `.rgba` swap so ASTC wins (the bigger memory + load win); the
    // `.rgba` swap below then skips these (they no longer end in `.png`). Falls
    // back to the source PNG when no `.astc` sibling exists.
    var astc_path_allocs: std.ArrayList([]const u8) = .empty;
    defer {
        for (astc_path_allocs.items) |s| allocator.free(s);
        astc_path_allocs.deinit(allocator);
    }
    if (cfg.asset_compression.formatFor(cfg.platform) == .astc) {
        for (mutable_resources) |*res| {
            if (res.texture.len == 0) continue;
            if (!std.mem.endsWith(u8, res.texture, ".png")) continue;
            const astc_rel = try std.mem.concat(allocator, u8, &.{ res.texture[0 .. res.texture.len - 4], ".astc" });
            errdefer allocator.free(astc_rel);
            const abs = try std.fs.path.join(allocator, &.{ game_dir, astc_rel });
            defer allocator.free(abs);
            std.Io.Dir.cwd().access(io, abs, .{}) catch {
                allocator.free(astc_rel);
                continue;
            };
            try astc_path_allocs.append(allocator, astc_rel);
            res.texture = astc_rel;
        }
    }

    // Swap `.texture = "...png"` to the pre-baked `.rgba` sibling
    // when `labelle build --bake` produced one. The runtime decoder
    // detects the LRGBA magic and skips stb_image entirely. Leaves
    // the path untouched when no sibling exists, so fresh checkouts
    // (and builds without `--bake`) still embed the source PNG.
    var rgba_path_allocs: std.ArrayList([]const u8) = .empty;
    defer {
        for (rgba_path_allocs.items) |s| allocator.free(s);
        rgba_path_allocs.deinit(allocator);
    }
    for (mutable_resources) |*res| {
        if (res.texture.len == 0) continue;
        if (!std.mem.endsWith(u8, res.texture, ".png")) continue;
        const rgba_rel = try std.mem.concat(allocator, u8, &.{ res.texture[0 .. res.texture.len - 4], ".rgba" });
        errdefer allocator.free(rgba_rel);
        const abs = try std.fs.path.join(allocator, &.{ game_dir, rgba_rel });
        defer allocator.free(abs);
        std.Io.Dir.cwd().access(io, abs, .{}) catch {
            allocator.free(rgba_rel);
            continue;
        };
        try rgba_path_allocs.append(allocator, rgba_rel);
        res.texture = rgba_rel;
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
    const PackEntry = struct {
        plugin: config.PluginDep,
        manifest: plugin_manifest.PackManifest,
    };
    var pack_entries: std.ArrayList(PackEntry) = .empty;
    defer {
        for (pack_entries.items) |*e| e.manifest.deinit();
        pack_entries.deinit(allocator);
    }
    // Reserve one slot per declared plugin (upper bound — non-pack plugins are
    // skipped) so the append below cannot fail. This closes the window where a
    // parsed PackManifest is owned but not yet in `pack_entries`, so a mid-loop
    // OutOfMemory would leak it past the cleanup defer (Gemini review, #441).
    try pack_entries.ensureTotalCapacity(allocator, cfg.plugins.len);
    for (cfg.plugins) |plugin| {
        const pm = (try plugin_manifest.loadPackOptional(allocator, plugin, game_dir)) orelse continue;
        pack_entries.appendAssumeCapacity(.{ .plugin = plugin, .manifest = pm });
    }

    {
        var pack_deps: std.ArrayList(pack_validate.PackDep) = .empty;
        defer pack_deps.deinit(allocator);
        try pack_deps.ensureTotalCapacity(allocator, pack_entries.items.len);
        for (pack_entries.items) |e| {
            pack_deps.appendAssumeCapacity(.{ .name = e.manifest.name, .depends_on = e.manifest.depends_on });
        }

        // Legal depends_on targets = every plugin/pack declared in
        // project.labelle (plus the implicit `contracts`, handled inside).
        var declared_names: std.ArrayList([]const u8) = .empty;
        defer declared_names.deinit(allocator);
        try declared_names.ensureTotalCapacity(allocator, cfg.plugins.len);
        for (cfg.plugins) |plugin| declared_names.appendAssumeCapacity(plugin.name);

        try pack_validate.validate(allocator, pack_deps.items, declared_names.items);

        // Prefix-collision gate (#440 / CodeRabbit): a pack's name feeds
        // `scan.packNamespacePrefix` (codegen). Two packs whose names sanitize
        // to the same `<pack>__` prefix (e.g. `my-pack` and `my_pack`) would
        // emit duplicate namespaced symbols and break the generated
        // imports/registries/hook tuples. Check over the SAME name the pack-scan
        // loop feeds `scanPack` (`plugin.name` → `PackScan.name` → prefix), so
        // the gate matches the symbols actually emitted. Fails before any target
        // is written.
        var pack_names: std.ArrayList([]const u8) = .empty;
        defer pack_names.deinit(allocator);
        try pack_names.ensureTotalCapacity(allocator, pack_entries.items.len);
        for (pack_entries.items) |e| pack_names.appendAssumeCapacity(e.plugin.name);
        try pack_validate.checkPrefixCollisions(pack_names.items);
    }

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
    // the old always-eager behavior. Ticket #48.
    try lazy_inference.resolveLazyDefaults(allocator, mutable_resources, scene_manifests);

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
    // Each plugin in cfg.plugins may ship a `plugin.labelle` manifest at
    // its root that declares additional directories the CLI should copy
    // and/or scan from the game project. See
    // `docs/RFC-plugin-manifest.md` for the design.
    //
    // The manifest is read regardless of `plugin.states` (game-state
    // gating affects runtime, not generate-time layout). Missing source
    // directories are silently tolerated, matching the behavior of the
    // hardcoded scans above.
    //
    // Duplicate directory declarations across plugins are a hard error
    // (RFC E3). A single name can be claimed by exactly one plugin to
    // keep the "who owns this directory" story unambiguous and prevent
    // conflicting copy passes.
    //
    // All manifests are loaded first and kept alive until every copy
    // pass has run, so the duplicate-detection hash map (which stores
    // slices into parsed manifest memory) stays valid across plugins.
    //
    // Pre-reserve capacity up front so the per-plugin append cannot
    // fail. If we used a fallible append, a successful loadOptional
    // followed by an OOM-on-resize would leak the parsed manifest
    // (it wouldn't have made it into the cleanup list).
    var loaded_manifests: std.ArrayList(plugin_manifest.PluginManifest) = .empty;
    defer {
        for (loaded_manifests.items) |*m| m.deinit();
        loaded_manifests.deinit(allocator);
    }
    try loaded_manifests.ensureTotalCapacity(allocator, cfg.plugins.len);

    var owner_of_dir: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer owner_of_dir.deinit(allocator);

    for (cfg.plugins) |plugin| {
        const maybe_manifest = try plugin_manifest.loadOptional(allocator, plugin, game_dir);
        const manifest = maybe_manifest orelse continue;
        // Capacity was reserved above — this cannot fail, so there's
        // no window where `manifest` is owned but outside the cleanup
        // list's reach.
        loaded_manifests.appendAssumeCapacity(manifest);

        for (manifest.convention_dirs) |dir| {
            // Duplicate detection is *cross-plugin only*. A single plugin
            // is allowed to declare the same directory name in multiple
            // convention_dirs entries with different extensions — that's
            // the RFC Q3 multi-extension pattern (e.g. a plugin wanting
            // both .zig and .zon files under state_machines/). Only error
            // when a different plugin already claimed the name.
            if (owner_of_dir.get(dir.name)) |prev_owner| {
                if (!std.mem.eql(u8, prev_owner, plugin.name)) {
                    std.debug.print(
                        "labelle: two plugins want the same convention directory '{s}':\n  - plugin '{s}' already declared it\n  - plugin '{s}' is trying to declare it again\n  each plugin must use a unique directory name\n",
                        .{ dir.name, prev_owner, plugin.name },
                    );
                    return error.PluginManifestDuplicateDir;
                }
                // Same plugin re-declaring the name (multi-extension) —
                // don't overwrite the claim, just keep going and let the
                // copy pass below handle it.
            } else {
                try owner_of_dir.put(allocator, dir.name, plugin.name);
            }

            switch (dir.mode) {
                .copy_and_scan => {
                    // `extension` is required for copy_and_scan and is
                    // validated by plugin_manifest.loadFromDir at load
                    // time, so .? here is safe.
                    const ext = dir.extension.?;
                    const names = try scanner.linkAndScan(
                        allocator,
                        game_dir,
                        target_dir,
                        dir.name,
                        ext,
                    );
                    // v1: name list is computed but not exposed to codegen.
                    // Future RFC will decide how plugins drive main.zig
                    // generation from these names.
                    scanner.freeNames(allocator, names);
                },
                .copy_only => {
                    try scanner.linkDir(
                        allocator,
                        game_dir,
                        target_dir,
                        dir.name,
                    );
                },
                .ship_from_plugin => {
                    // Plugin-shipped content: source dir lives in the
                    // plugin's cached package rather than the consuming
                    // game. Resolves the plugin's path up-front because
                    // copyAndScan takes a base and a folder-under-base.
                    // Silently skips if the plugin doesn't actually ship
                    // the declared directory — matches copy_and_scan's
                    // missing-source tolerance so a plugin author can
                    // declare the convention eagerly and ship content
                    // incrementally.
                    const ext = dir.extension.?;
                    const plugin_src_dir = try cache.resolvePlugin(allocator, plugin, game_dir);
                    defer allocator.free(plugin_src_dir);
                    const names = try scanner.copyAndScan(
                        allocator,
                        plugin_src_dir,
                        target_dir,
                        dir.name,
                        ext,
                    );
                    scanner.freeNames(allocator, names);
                },
            }
        }
    }

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
    for (cfg.plugins) |plugin| {
        // A *light pack* is also a `.plugins` entry, but its scripts flow
        // through the pack dir-scan below (`scanPackScriptsDir`), landing
        // under `packs/<name>/scripts/` so their own `../components` relative
        // imports resolve — NOT under `scripts/.plugin_<name>/`. Skip packs
        // here so a pack that ships a `scripts/` dir isn't scanned twice
        // (labelle-assembler#487).
        const is_pack = blk: {
            for (pack_entries.items) |e| {
                if (std.mem.eql(u8, e.plugin.name, plugin.name)) break :blk true;
            }
            break :blk false;
        };
        if (is_pack) {
            // A *light pack's* per-frame system lives INSIDE the pack, at
            // `<pack>/scripts/<state>/*.zig`. Scan it HERE — at the pack's
            // declaration-order position within this `cfg.plugins` loop,
            // interleaved with the decl-module plugins — so the
            // `ScriptScanner`'s `plugin_index` (assigned in scan-call order)
            // reflects `.plugins` order. Scanning ALL packs in a SEPARATE
            // later loop would push a pack declared BEFORE a plugin behind it,
            // breaking the per-state script ordering contract
            // (labelle-assembler#494, codex review).
            const pack_src_dir = try cache.resolvePlugin(allocator, plugin, game_dir);
            defer allocator.free(pack_src_dir);
            _ = try scanPackScriptsAt(allocator, &script_scan, pack_src_dir, target_dir, plugin.name);
            continue;
        }

        // Plugin was already resolved during the manifest-loading loop
        // above; re-resolving here is infallible in practice. Use `try`
        // to match the manifest-load contract — a failure here is a
        // cache corruption, not a plugin configuration error, and
        // should fail the generate rather than silently skip.
        const plugin_src_dir = try cache.resolvePlugin(allocator, plugin, game_dir);
        defer allocator.free(plugin_src_dir);

        const plugin_scripts_src = try std.fs.path.join(allocator, &.{ plugin_src_dir, "scripts" });
        defer allocator.free(plugin_scripts_src);

        // Destination: `<target>/scripts/.plugin_<name>/`. The leading `.`
        // prevents accidental collision with a game state directory (states
        // must be lowercase alphanumeric + `_`, per `isValidStateName`, so
        // `.plugin_foo` can never be mistaken for a state dir by the
        // scanner).
        const plugin_dst_subdir = try std.fmt.allocPrint(allocator, ".plugin_{s}", .{plugin.name});
        defer allocator.free(plugin_dst_subdir);
        const plugin_scripts_dst = try std.fs.path.join(allocator, &.{ target_dir, "scripts", plugin_dst_subdir });
        defer allocator.free(plugin_scripts_dst);

        const names = try scanner.copyAndScanAbs(
            allocator,
            plugin_scripts_src,
            plugin_scripts_dst,
            ".zig",
        );
        scanner.freeNames(allocator, names);

        // Feed the plugin's scripts into the scanner as a new block,
        // isolated under the plugin's namespace so the duplicate-prefix
        // validator treats it independently of the game block.
        try script_scan.scanPluginDir(plugin_scripts_dst, plugin.name);
    }

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
    // the view is the pack's sanctioned string-keyed surface. STILL DEFERRED with
    // clean seams:
    //   * the per-pack Zig MODULE graph + the `@import("root")` bridge that wires
    //     pack code to its view (so a foreign name is a compile error, not a
    //     lint) — assembler#498 PRs 2–3.
    //   * `exposes` surface module / `depends_on` import narrowing (#440 / §6) —
    //     assembler#498 PR 4.
    //
    // The pack manifests reused below were parsed ONCE near the top of
    // `generate()` (`pack_entries`), where the dependency-validation gate AND
    // the sanitized-prefix collision gate both run — a bad `depends_on` graph
    // or two packs whose names sanitize to the same `<pack>__` prefix reject
    // the build before any target writes, rather than re-reading `pack.labelle`
    // here.
    var pack_scans: std.ArrayList(main_zig.PackScan) = .empty;
    defer {
        for (pack_scans.items) |*p| p.deinit(allocator);
        pack_scans.deinit(allocator);
    }
    try pack_scans.ensureTotalCapacity(allocator, pack_entries.items.len);
    for (pack_entries.items) |e| {
        // Reuse the manifest parsed above; only the source dir is resolved here.
        const pack_src_dir = try cache.resolvePlugin(allocator, e.plugin, game_dir);
        defer allocator.free(pack_src_dir);

        // ensureTotalCapacity above reserved pack_entries.len slots, so this
        // append cannot fail — no window where a scanned pack is owned but
        // outside the cleanup list's reach.
        const scanned = try scanPack(allocator, pack_src_dir, target_dir, e.plugin.name);
        pack_scans.appendAssumeCapacity(scanned);

        // NOTE: a pack's OWN per-frame SYSTEM (`<pack>/scripts/<state>/*.zig`,
        // labelle-assembler#487) is copied + registered by the `cfg.plugins`
        // script loop ABOVE, at the pack's `.plugins` declaration-order
        // position (interleaved with the decl-module plugins) so its
        // `plugin_index` reflects `.plugins` order. Doing it here — in a
        // pack-only loop that runs AFTER every plugin — would order all pack
        // scripts behind all plugin scripts regardless of declaration order
        // (labelle-assembler#494, codex review). Component/event/prefab/hook
        // copying stays here (order-independent).
    }

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

    // Generate build.zig
    // `cfg_modules` (not `cfg`): light packs get no `b.dependency` /
    // `overrideImport` module wiring — their contribution is dir-scan
    // registry entries, not an importable module (#481).
    const build_zig = try build_files.generateBuildZig(allocator, cfg_modules, .{
        .is_tests_target = is_tests_target,
        .promoted_scripts = promoted_scripts,
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
        const engine_template = try loadEngineTemplate(allocator, game_dir, cfg);
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

/// Load the engine's main.zig template from the codegen/ directory.
fn loadEngineTemplate(allocator: std.mem.Allocator, game_dir: []const u8, cfg: ProjectConfig) ![]const u8 {
    const engine_path = try cache.resolveFrameworkPackage(allocator, "engine", cfg.engine_version, game_dir);
    defer allocator.free(engine_path);

    const tmpl_path = try std.fs.path.join(allocator, &.{ engine_path, "codegen", "main.zig.template" });
    defer allocator.free(tmpl_path);

    return std.Io.Dir.cwd().readFileAlloc(config.globalIo(), tmpl_path, allocator, .limited(256 * 1024)) catch |err| {
        std.debug.print("labelle: could not read engine template '{s}': {any}\n", .{ tmpl_path, err });
        return error.EngineTemplateNotFound;
    };
}

/// Load the backend+platform lifecycle (entry-point) template from the CLI cache.
///
/// The enum/v1 template path is gone (#461): the entry-point template is resolved
/// EXCLUSIVELY from the v2 manifest's `.platforms[<platform>].entry` (design §3).
/// `backend_manifest_name` is the v2 filename `generate` auto-detected — null means
/// the backend ships no v2 manifest, which is no longer a supported codegen input.
pub fn loadBackendTemplate(allocator: std.mem.Allocator, game_dir: []const u8, cfg: ProjectConfig, backend_manifest_name: ?[]const u8) ![]const u8 {
    // Every backend generates via its manifest — fail loudly if one ships none.
    try manifest_splice.requireManifestIfExternal(allocator, cfg, game_dir, backend_manifest_name);

    const name = backend_manifest_name orelse return error.ExternalBackendNeedsManifest;
    const m = try manifest_v2.loadNamedManifest(allocator, cfg, game_dir, name);
    defer std.zon.parse.free(allocator, m);
    const entry = manifest_v2_splice.platformEntry(m, cfg.platform) orelse {
        std.log.warn(
            "labelle: v2 backend '{s}' declares no `.platforms.{s}` entry — the platform is unsupported by this backend.",
            .{ cfg.backendName(), @tagName(cfg.platform) },
        );
        return error.V2PlatformUnsupported;
    };
    const backend_path = try backend_registry.resolveBackendPackage(allocator, cfg, game_dir);
    defer allocator.free(backend_path);
    const tmpl_path = try std.fs.path.join(allocator, &.{ backend_path, entry.entry });
    defer allocator.free(tmpl_path);
    return std.Io.Dir.cwd().readFileAlloc(config.globalIo(), tmpl_path, allocator, .limited(64 * 1024)) catch |err| {
        std.log.warn("labelle: could not read v2 entry template '{s}': {any}", .{ tmpl_path, err });
        return error.TemplateNotFound;
    };
}
