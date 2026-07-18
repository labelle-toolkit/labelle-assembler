//! Discovery + scanning helpers extracted from `main_zig.zig`
//! (labelle-assembler#183, PoC slice).
//!
//! Owns the AST-walk that turns plugin / game-script source files into the
//! `PluginEvent` / `PluginFlowNode` / `PluginPinStyle` / `PluginCoercion`
//! data the orchestrator pours into the generated `main.zig` registries.
//! These functions are deliberately pure (allocator in / allocator-owned
//! data out) so they can be moved without touching the orchestrator's
//! template-slot wiring.
//!
//! ⚠️  Bit-identical contract: every string this module writes (the
//! sanitized plugin idents, the path-derived idents) feeds directly into
//! `main.zig` source. A typo here drifts the generated source for every
//! downstream backend. The orchestrator's tests already cover the
//! emission shape end-to-end; the helpers here also carry the
//! `pathToIdent` tests that were already in `main_zig.zig`.
//!
//! ── Barrel ──────────────────────────────────────────────────────────
//! This file was a single ~3300-line module; it is now a thin barrel that
//! re-exports the public surface from focused sub-modules under `scan/`
//! (behavior-preserving split, labelle-assembler#534 follow-up). Every
//! symbol keeps its original name and identity so existing `scan.<Name>`
//! call sites are unchanged:
//!
//!   - `scan/sanitize.zig`      — identifier sanitization (`sanitizePluginIdent`,
//!                                `pathToIdent`)
//!   - `scan/pack_refs.zig`     — pack-namespace JSONC rewriting
//!                                (`PackScan`, `rewritePackLocalRefs`, …)
//!   - `scan/pack_hooks.zig`    — pack hook-handler renaming
//!                                (`rewritePackHookHandlerNames`)
//!   - `scan/plugin_events.zig` — plugin/engine `Events` discovery
//!                                (`PluginEvent`, `discoverPluginEvents`, …)
//!   - `scan/flow_decls.zig`    — FlowNodes/PinStyles/Coercions discovery
//!                                (`PluginFlowNode`, `discoverPluginFlowDecls`, …)
//!   - `scan/promote.zig`       — game-script → named-module promotion
//!                                (`PromotedScript`, `collectPromotedScripts`, …)

const sanitize = @import("scan/sanitize.zig");
const pack_refs = @import("scan/pack_refs.zig");
const pack_hooks = @import("scan/pack_hooks.zig");
const plugin_events = @import("scan/plugin_events.zig");
const event_consumption = @import("scan/event_consumption.zig");
const flow_decls = @import("scan/flow_decls.zig");
const promote = @import("scan/promote.zig");

// ── Identifier sanitization (scan/sanitize.zig) ──────────────────────
pub const sanitizePluginIdent = sanitize.sanitizePluginIdent;
pub const pathToIdent = sanitize.pathToIdent;

// ── Pack-namespace JSONC rewriting (scan/pack_refs.zig) ──────────────
pub const PackScan = pack_refs.PackScan;
pub const packNamespacePrefix = pack_refs.packNamespacePrefix;
pub const rewritePackComponentKeys = pack_refs.rewritePackComponentKeys;
pub const rewritePackLocalRefs = pack_refs.rewritePackLocalRefs;
pub const bundleHeaderLegacyEntitiesOffset = pack_refs.bundleHeaderLegacyEntitiesOffset;

// ── Pack hook-handler renaming (scan/pack_hooks.zig) ─────────────────
pub const rewritePackHookHandlerNames = pack_hooks.rewritePackHookHandlerNames;

// ── Plugin / engine Events discovery (scan/plugin_events.zig) ────────
pub const PluginEvent = plugin_events.PluginEvent;
pub const PluginEvents = plugin_events.PluginEvents;
pub const discoverPluginEvents = plugin_events.discoverPluginEvents;

// ── Plugin-event consumption filter (scan/event_consumption.zig) ─────
pub const EventConsumption = event_consumption.EventConsumption;
pub const filterConsumedEvents = event_consumption.filterConsumedEvents;

// ── FlowNodes / PinStyles / Coercions discovery (scan/flow_decls.zig) ─
pub const PluginFlowNode = flow_decls.PluginFlowNode;
pub const PluginPinStyle = flow_decls.PluginPinStyle;
pub const PluginCoercion = flow_decls.PluginCoercion;
pub const PluginFlowDecls = flow_decls.PluginFlowDecls;
pub const discoverPluginFlowDecls = flow_decls.discoverPluginFlowDecls;
pub const dedupePinStyles = flow_decls.dedupePinStyles;

// ── Game-script promotion (scan/promote.zig) ─────────────────────────
pub const PromotedScript = promote.PromotedScript;
pub const promotedScriptModuleName = promote.promotedScriptModuleName;
pub const collectPromotedScripts = promote.collectPromotedScripts;
pub const freePromotedScripts = promote.freePromotedScripts;

// Pull every sub-module's tests into the `scan.zig` analysis so
// `zig build test` keeps running the specs that used to live here.
test {
    _ = sanitize;
    _ = pack_refs;
    _ = pack_hooks;
    _ = plugin_events;
    _ = event_consumption;
    _ = flow_decls;
    _ = promote;
}
