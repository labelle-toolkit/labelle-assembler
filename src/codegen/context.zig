//! `Codegen` — shared context for the main.zig codegen pipeline.
//!
//! Models the engine's `Game` ↔ `*_mixin.zig` pairing (see
//! `labelle-engine/src/game.zig` lines 23–110 and any of
//! `labelle-engine/src/game/*_mixin.zig`). `Codegen` is the runtime
//! struct that owns the shared state previously threaded through
//! `generateMainZigFromTemplate` as 19 positional args. Each block-
//! writer module exposes a `Mixin(Self)` factory that contributes a
//! method group; `Codegen` composes them and re-exports their methods
//! so the orchestrator can dispatch `ctx.writeImageBackendWiring(...)`
//! instead of `writeImageBackendWiring(w, "    ")`-style call sites
//! that re-thread the same allocator / cfg / scan results into every
//! block.
//!
//! Pure helpers (scan, idents, validate, preview) stay as plain
//! modules — they're stateless utility namespaces, adding `self` to
//! them would be ceremony with no benefit. Only the block writers +
//! lifecycle builders + orchestrator route through `Codegen`.
//!
//! Mixin-only surface (labelle-assembler#206 follow-up): the
//! standalone module-level functions in `scene_manifests.zig`,
//! `plugin_registries.zig`, `lifecycle/loop.zig`, and
//! `lifecycle/callback.zig` have been collapsed into their mixin
//! methods — every external caller (orchestrator + tests +
//! `root.zig:generateGameShim`) dispatches through a `Codegen` now.
//! The only standalone helpers that remain are in
//! `blocks/asset_wiring.zig` and `blocks/resource_loader.zig`; those
//! are pure `(writer, indent[, ...])` functions that `lifecycle/{loop,
//! callback}.zig` call directly from inside their mixin method bodies
//! — they're sibling-module utility, not part of the external
//! surface.

const std = @import("std");
const config = @import("../config.zig");
const script_scanner = @import("../script_scanner.zig");
const scene_manifest = @import("../scene_manifest.zig");
const scan = @import("scan.zig");
const manifest_splice = @import("manifest_splice.zig");

const asset_wiring = @import("blocks/asset_wiring.zig");
const scene_manifests_block = @import("blocks/scene_manifests.zig");
const resource_loader = @import("blocks/resource_loader.zig");
const plugin_registries = @import("blocks/plugin_registries.zig");
const imports_block = @import("blocks/imports.zig");
const hooks_block = @import("blocks/hooks.zig");
const events_block = @import("blocks/events.zig");
const registries_block = @import("blocks/registries.zig");
const lifecycle_loop = @import("lifecycle/loop.zig");
const lifecycle_callback = @import("lifecycle/callback.zig");
const lifecycle_render = @import("lifecycle/render.zig");

const ProjectConfig = config.ProjectConfig;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;
const SceneManifest = scene_manifest.SceneManifest;
const PluginEvent = scan.PluginEvent;
const PluginFlowNode = scan.PluginFlowNode;
const PluginPinStyle = scan.PluginPinStyle;
const PluginCoercion = scan.PluginCoercion;

/// Shared context for `generateMainZigFromTemplate`. Carries the
/// state every block writer + lifecycle builder previously took as
/// positional args. Fields are borrowed from the caller — `Codegen`
/// owns none of the slices, just references them.
pub const Codegen = struct {
    const Self = @This();

    // ── State ────────────────────────────────────────────────────────
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,

    // Scan results threaded through every block writer today.
    script_entries: []const ScriptEntry,
    prefab_names: []const []const u8,
    jsonc_scene_names: []const []const u8,
    scene_manifests: []const SceneManifest,
    component_names: []const []const u8,
    hook_names: []const []const u8,
    event_names: []const []const u8,
    enum_names: []const []const u8,
    view_names: []const []const u8,
    gizmo_names: []const []const u8,
    animation_names: []const []const u8,
    plugin_events: []const PluginEvent,
    plugin_flow_nodes: []const PluginFlowNode,
    plugin_pin_styles: []const PluginPinStyle,
    plugin_coercions: []const PluginCoercion,

    // Priority-aware flow-handler ordering (indices into `script_entries`),
    // built by `blocks/hooks.zig:buildFlowOrder`. Borrowed: the
    // orchestrator owns the backing `ArrayList`. Shared between the
    // game-hooks and hooks-init writers so the receiver-type order matches
    // the receiver-pointer order. Defaults to empty for callers
    // (`root.zig:generateGameShim`) that never wire flow handlers.
    flow_order: []const usize = &.{},

    // Lifecycle-section render inputs (codegen/lifecycle/render.zig). Set by
    // the orchestrator just before `renderLifecycle` so the (non-capturing)
    // block closure can reach them through `self`. `lifecycle_tmpl` is the
    // backend template text; `hooks_init` the already-rendered
    // `hooks_init_block` scalar; `loop_style_override` the manifest-driven
    // run-loop override (assembler#378), passed by value to keep the render
    // module decoupled from the orchestrator's `threadlocal`.
    lifecycle_tmpl: []const u8 = "",
    hooks_init: []const u8 = "",
    loop_style_override: ?manifest_splice.BackendManifest.LoopStyle = null,

    // ── Mixin types ──────────────────────────────────────────────────
    const AssetWiringMixin = asset_wiring.Mixin(Self);
    const SceneManifestsMixin = scene_manifests_block.Mixin(Self);
    const ResourceLoaderMixin = resource_loader.Mixin(Self);
    const PluginRegistriesMixin = plugin_registries.Mixin(Self);
    const ImportsMixin = imports_block.Mixin(Self);
    const HooksMixin = hooks_block.Mixin(Self);
    const EventsMixin = events_block.Mixin(Self);
    const RegistriesMixin = registries_block.Mixin(Self);
    const LifecycleLoopMixin = lifecycle_loop.Mixin(Self);
    const LifecycleCallbackMixin = lifecycle_callback.Mixin(Self);
    const LifecycleRenderMixin = lifecycle_render.Mixin(Self);

    // ── Re-exported mixin methods ────────────────────────────────────
    // Asset-backend wiring (codegen/blocks/asset_wiring.zig)
    pub const writeImageBackendWiring = AssetWiringMixin.writeImageBackendWiring;
    pub const writeAudioBackendWiring = AssetWiringMixin.writeAudioBackendWiring;
    pub const writeFontBackendWiring = AssetWiringMixin.writeFontBackendWiring;

    // Scene manifests (codegen/blocks/scene_manifests.zig)
    pub const writeSceneAssetManifests = SceneManifestsMixin.writeSceneAssetManifests;
    pub const writeSceneInitialStateManifests = SceneManifestsMixin.writeSceneInitialStateManifests;

    // Resource loader (codegen/blocks/resource_loader.zig)
    pub const emitResourceLoad = ResourceLoaderMixin.emitResourceLoad;

    // Plugin registries (codegen/blocks/plugin_registries.zig)
    pub const writePluginControllersBlock = PluginRegistriesMixin.writePluginControllersBlock;
    pub const writePluginEventsBlock = PluginRegistriesMixin.writePluginEventsBlock;
    pub const writePluginFlowNodesBlock = PluginRegistriesMixin.writePluginFlowNodesBlock;
    pub const writePluginPinStylesBlock = PluginRegistriesMixin.writePluginPinStylesBlock;
    pub const writePluginCoercionsBlock = PluginRegistriesMixin.writePluginCoercionsBlock;

    // Import + JSONC-scene blocks (codegen/blocks/imports.zig)
    pub const writeHookImportsBlock = ImportsMixin.writeHookImportsBlock;
    pub const writeEventImportsBlock = ImportsMixin.writeEventImportsBlock;
    pub const writeEnumImportsBlock = ImportsMixin.writeEnumImportsBlock;
    pub const writeJsoncSceneBlock = ImportsMixin.writeJsoncSceneBlock;

    // Hook-pipeline blocks (codegen/blocks/hooks.zig)
    pub const writeAllHookPayloadsBlock = HooksMixin.writeAllHookPayloadsBlock;
    pub const writeGameHooksBlock = HooksMixin.writeGameHooksBlock;
    pub const writeHooksInitBlock = HooksMixin.writeHooksInitBlock;

    // Game-events + plugin-vocabulary block (codegen/blocks/events.zig)
    pub const writeGameEventsBlock = EventsMixin.writeGameEventsBlock;

    // Comptime registry blocks (codegen/blocks/registries.zig)
    pub const writePrefabRegistryBlock = RegistriesMixin.writePrefabRegistryBlock;
    pub const writeComponentRegistryBlock = RegistriesMixin.writeComponentRegistryBlock;
    pub const writeSystemRegistryBlock = RegistriesMixin.writeSystemRegistryBlock;
    pub const writeAllScriptsBlock = RegistriesMixin.writeAllScriptsBlock;
    pub const writeViewRegistryBlock = RegistriesMixin.writeViewRegistryBlock;
    pub const writeGizmoRegistryBlock = RegistriesMixin.writeGizmoRegistryBlock;
    pub const writeAnimationRegistryBlock = RegistriesMixin.writeAnimationRegistryBlock;

    // Lifecycle builders (codegen/lifecycle/{loop,callback}.zig)
    pub const buildSetupCode = LifecycleLoopMixin.buildSetupCode;
    pub const buildGuiDrawCode = LifecycleLoopMixin.buildGuiDrawCode;
    pub const buildCallbackInitCode = LifecycleCallbackMixin.buildCallbackInitCode;
    pub const buildImmersiveEntryCode = LifecycleCallbackMixin.buildImmersiveEntryCode;
    pub const buildCallbackCleanupCode = LifecycleCallbackMixin.buildCallbackCleanupCode;

    // Lifecycle section render (codegen/lifecycle/render.zig)
    pub const renderLifecycle = LifecycleRenderMixin.renderLifecycle;
};
