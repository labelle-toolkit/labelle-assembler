/// main.zig generator — back-compat re-export shim.
///
/// The structural refactor (labelle-assembler#183) split this file
/// into ten focused submodules under `src/codegen/`. This shim keeps
/// every existing `@import("main_zig.zig").Foo` call site working —
/// `root.zig`, `test/tests.zig`, `flow_catalog.zig`, and any future
/// in-tree caller can keep reaching the original names without
/// knowing which submodule they now live in.
///
/// **The orchestrator itself** (`generateMainZigFromTemplate`) and
/// its two end-of-file helpers (`generateGameLayers`,
/// `generateResourceRegistry`) live in
/// `src/codegen/main_template.zig` as of step 9 of the cut plan in
/// `docs/REFACTOR-PLAN-main-zig.md`. See per-section comments below
/// for the canonical location of every extracted helper.
///
/// Pure re-exports — no logic, no allocations, no state. Adding a
/// new helper? Put it in the relevant submodule and add a `pub const`
/// alias here only if existing callers expect to find it on
/// `main_zig.zig`.

// ── Submodule namespaces (publicly re-exported so callers can do
//    e.g. `main_zig.validate.X` if they prefer the namespaced form) ──
pub const validate = @import("codegen/validate.zig");
pub const resource_loader = @import("codegen/blocks/resource_loader.zig");
pub const scene_manifests_block = @import("codegen/blocks/scene_manifests.zig");
pub const asset_wiring = @import("codegen/blocks/asset_wiring.zig");
pub const plugin_registries = @import("codegen/blocks/plugin_registries.zig");
pub const lifecycle_loop = @import("codegen/lifecycle/loop.zig");
pub const lifecycle_callback = @import("codegen/lifecycle/callback.zig");
pub const main_template = @import("codegen/main_template.zig");
pub const context = @import("codegen/context.zig");

/// Shared codegen context (labelle-assembler#183 mixin conversion).
/// Models the engine's `Game` ↔ `*_mixin.zig` pairing — holds the
/// state previously threaded through `generateMainZigFromTemplate` as
/// positional args, and composes each block writer's `Mixin(Self)`
/// factory into method-dispatch shape (`ctx.writeImageBackendWiring(...)`).
/// The orchestrator is the only consumer today; the re-export here is
/// for future call sites that want the dispatch shape.
pub const Codegen = context.Codegen;

const scan = @import("codegen/scan.zig");
const preview = @import("codegen/preview.zig");

// ── Scan: plugin discovery types + helpers (codegen/scan.zig) ────
pub const PluginEvent = scan.PluginEvent;
pub const PluginEvents = scan.PluginEvents;
pub const PluginFlowNode = scan.PluginFlowNode;
pub const PluginPinStyle = scan.PluginPinStyle;
pub const PluginCoercion = scan.PluginCoercion;
pub const PluginFlowDecls = scan.PluginFlowDecls;
pub const discoverPluginEvents = scan.discoverPluginEvents;
pub const discoverPluginFlowDecls = scan.discoverPluginFlowDecls;
pub const dedupePinStyles = scan.dedupePinStyles;

// ── Lifecycle builders (codegen/lifecycle/{loop,callback}.zig) ────
pub const buildSetupCode = lifecycle_loop.buildSetupCode;
pub const buildGuiDrawCode = lifecycle_loop.buildGuiDrawCode;
pub const buildCallbackInitCode = lifecycle_callback.buildCallbackInitCode;
pub const buildImmersiveEntryCode = lifecycle_callback.buildImmersiveEntryCode;
pub const buildCallbackCleanupCode = lifecycle_callback.buildCallbackCleanupCode;

// ── Asset-backend wiring (codegen/blocks/asset_wiring.zig) ────────
pub const writeImageBackendWiring = asset_wiring.writeImageBackendWiring;
pub const writeAudioBackendWiring = asset_wiring.writeAudioBackendWiring;
pub const writeFontBackendWiring = asset_wiring.writeFontBackendWiring;

// ── Plugin registry block writers (codegen/blocks/plugin_registries.zig) ──
pub const writePluginControllersBlock = plugin_registries.writePluginControllersBlock;
pub const writePluginEventsBlock = plugin_registries.writePluginEventsBlock;
pub const writePluginFlowNodesBlock = plugin_registries.writePluginFlowNodesBlock;
pub const writePluginPinStylesBlock = plugin_registries.writePluginPinStylesBlock;
pub const writePluginCoercionsBlock = plugin_registries.writePluginCoercionsBlock;

// ── Resource loader emit (codegen/blocks/resource_loader.zig) ─────
pub const LoadStyle = resource_loader.LoadStyle;
pub const emitResourceLoad = resource_loader.emitResourceLoad;

// ── Preview-mode templates (codegen/preview.zig) ──────────────────
pub const WASM_PANIC_WORKAROUND = preview.WASM_PANIC_WORKAROUND;
pub const PREVIEW_HELPERS = preview.PREVIEW_HELPERS;
pub const PREVIEW_READBACK_HELPERS = preview.PREVIEW_READBACK_HELPERS;
pub const PREVIEW_LOOP_SETUP = preview.PREVIEW_LOOP_SETUP;
pub const PREVIEW_READBACK_SETUP = preview.PREVIEW_READBACK_SETUP;
pub const PREVIEW_HEARTBEAT_LOOP = preview.PREVIEW_HEARTBEAT_LOOP;
pub const PREVIEW_INPUT_DISPATCH = preview.PREVIEW_INPUT_DISPATCH;
pub const PREVIEW_INPUT_DISPATCH_STUB = preview.PREVIEW_INPUT_DISPATCH_STUB;
pub const PREVIEW_READBACK_LOOP = preview.PREVIEW_READBACK_LOOP;
pub const PREVIEW_INIT_CALLBACK = preview.PREVIEW_INIT_CALLBACK;
pub const PREVIEW_CLEANUP_CALLBACK = preview.PREVIEW_CLEANUP_CALLBACK;
pub const PREVIEW_HEARTBEAT_CALLBACK = preview.PREVIEW_HEARTBEAT_CALLBACK;
pub const PREVIEW_READBACK_HELPERS_SOKOL = preview.PREVIEW_READBACK_HELPERS_SOKOL;
pub const PREVIEW_READBACK_INIT_SOKOL = preview.PREVIEW_READBACK_INIT_SOKOL;
pub const PREVIEW_READBACK_FRAME_SOKOL = preview.PREVIEW_READBACK_FRAME_SOKOL;
pub const PREVIEW_READBACK_CLEANUP_SOKOL = preview.PREVIEW_READBACK_CLEANUP_SOKOL;
pub const PREVIEW_READBACK_HELPERS_SOKOL_D3D11 = preview.PREVIEW_READBACK_HELPERS_SOKOL_D3D11;
pub const PREVIEW_READBACK_HELPERS_METAL_SOKOL = preview.PREVIEW_READBACK_HELPERS_METAL_SOKOL;
pub const PREVIEW_READBACK_INIT_SOKOL_D3D11 = preview.PREVIEW_READBACK_INIT_SOKOL_D3D11;
pub const PREVIEW_READBACK_INIT_METAL_SOKOL = preview.PREVIEW_READBACK_INIT_METAL_SOKOL;
pub const PREVIEW_READBACK_FRAME_SOKOL_D3D11 = preview.PREVIEW_READBACK_FRAME_SOKOL_D3D11;
pub const PREVIEW_PRE_RENDER_METAL_SOKOL = preview.PREVIEW_PRE_RENDER_METAL_SOKOL;
pub const PREVIEW_READBACK_FRAME_METAL_SOKOL = preview.PREVIEW_READBACK_FRAME_METAL_SOKOL;
pub const PREVIEW_READBACK_CLEANUP_SOKOL_D3D11 = preview.PREVIEW_READBACK_CLEANUP_SOKOL_D3D11;
pub const PREVIEW_READBACK_CLEANUP_METAL_SOKOL = preview.PREVIEW_READBACK_CLEANUP_METAL_SOKOL;

// ── Orchestrator + tiny end-of-file helpers (codegen/main_template.zig) ──
pub const generateMainZigFromTemplate = main_template.generateMainZigFromTemplate;
pub const generateGameLayers = main_template.generateGameLayers;
pub const generateResourceRegistry = main_template.generateResourceRegistry;
