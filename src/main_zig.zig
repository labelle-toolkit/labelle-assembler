/// main.zig generator — namespace re-export shim.
///
/// The structural refactor (labelle-assembler#183) split this file
/// into focused submodules under `src/codegen/`. The mixin-only
/// follow-up (labelle-assembler#206 cleanup) removed the per-fn
/// re-exports — every block writer now flows through `Codegen` from
/// `codegen/context.zig`. Callers reach the writers via
/// `ctx.writeXxx(...)` instead of the explicit-arg standalone form
/// they used pre-#206.
///
/// **The orchestrator itself** (`generateMainZigFromTemplate`) and
/// its two end-of-file helpers (`generateGameLayers`,
/// `generateResourceRegistry`) live in
/// `src/codegen/main_template.zig`.
///
/// What stays here: submodule namespace aliases (callers can still do
/// `main_zig.scan.PluginEvent` for the discovery types), the
/// `Codegen` alias itself, and a handful of types whose names live in
/// the scan/preview submodules. No standalone block-writer functions.

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
/// External callers that want to drive a block writer construct one
/// of these with the relevant slices populated; everything else stays
/// as `.{}` / `&.{}`. See `test/helpers.zig`'s `emptyCodegen` for the
/// minimal shape.
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
pub const PromotedScript = scan.PromotedScript;
/// Pack dir-scan result (Packs RFC §4, #439). Threaded into codegen via
/// `main_template.pack_scans` so the registry block-writers can register a
/// pack's components/events/prefabs into the unified game-root registries.
pub const PackScan = scan.PackScan;
pub const discoverPluginEvents = scan.discoverPluginEvents;
/// Consumption filter for discovered plugin events (labelle-assembler#630):
/// partitions the discovery list into consumed (folded into the generated
/// `PluginEvents`) and elided (no consumer found) entries.
pub const EventConsumption = scan.EventConsumption;
pub const filterConsumedEvents = scan.filterConsumedEvents;
pub const discoverPluginFlowDecls = scan.discoverPluginFlowDecls;
pub const collectPromotedScripts = scan.collectPromotedScripts;
pub const freePromotedScripts = scan.freePromotedScripts;
pub const dedupePinStyles = scan.dedupePinStyles;

// ── Resource loader: `LoadStyle` is part of the standalone helper's
//    public surface (passed to `emitResourceLoad` by lifecycle siblings
//    within codegen/). Re-exported for any future external caller that
//    wants to drive `ctx.emitResourceLoad(w, res, style)` — the mixin
//    method takes `style` explicitly since it's per-call, not per-ctx.
pub const LoadStyle = resource_loader.LoadStyle;

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
