//! Pack/feature manifest emitter — labelle-assembler#442 (Packs
//! initiative; RFC Flying-Platform/flying-platform-labelle#561 §7;
//! umbrella labelle-engine#651).
//!
//! `flow_catalog.json` (RFC#178) already gives the *flow editor* its
//! palette (FlowNodes / PinStyles / Events / Coercions per plugin). The
//! **manifest** answers a different question — the one an *agent* (or a
//! human) asks before adding a feature: *which realm owns this · what
//! shapes do I touch · what already exists · what may I call across
//! packs · what's the recipe.* It's emitted alongside the flow catalog
//! as `<game>/.labelle/manifest.json`.
//!
//! ## Two-tier shape (RFC §7 — realm-structured + sliceable)
//!
//! ```jsonc
//! {
//!   "schema": "labelle.manifest/v1",
//!   "generated_at": "2026-...Z",
//!   "index": {                       // always loaded — the realm map
//!     "contracts": { "events": [...], "enums": [...], "registries": [] },
//!     "realms": [
//!       { "name": "game", "tier": "root",
//!         "owns": { "components": [...], "prefabs": [...], "scripts": [...],
//!                   "events": [...], "enums": [...], "hooks": [...] },
//!         "depends_on": ["box2d", ...],         // plugins the game pulls in
//!         "exposes": { "commands": [...], "queries": [...] },
//!         "recipes": [] },
//!       { "name": "box2d", "tier": "plugin", "version": "...",
//!         "owns": { "events": [...], "flow_nodes": [...] },
//!         "depends_on": [],
//!         "exposes": { "commands": [...], "queries": [...] },
//!         "recipes": [] }
//!     ]
//!   },
//!   "realms": [                      // per-realm detail — fetch the one in play
//!     { "name": "game", "tier": "root",
//!       "components": [ { "name": "Bed", "save": "saveable",
//!                         "fields": { "sleeper": "?u64", "x": "f32" } } ],
//!       "events":     [ { "name": "WorkerSleepStart",
//!                         "payload": { "worker_id": "u64", "bed_id": "u64" },
//!                         "emitted_by": [], "subscribed_by": [] } ],
//!       "scripts":    [ { "name": "00_spawn", "rel_path": "00_spawn.zig",
//!                         "order": 0, "states": [] } ],
//!       "enums": [...], "prefabs": [...], "recipes": [] },
//!     { "name": "box2d", "tier": "plugin",
//!       "events": [ { "name": "collision_begin" } ],   // payloads in flow_catalog.json
//!       "flow_nodes": [ { "name": "apply_impulse", "kind": "command" } ],
//!       "recipes": [] }
//!   ]
//! }
//! ```
//!
//! ## Derivation (RFC §7 — drift-free because generated)
//!
//! Everything except recipes is derived from the code the assembler has
//! already scanned, so the manifest can't drift from the source:
//!
//! - **Game realm** owns the project-root convention dirs. Component
//!   field schemas + save policy and event payloads are AST-parsed here
//!   (`parseStructFile`) from `<game>/components/*.zig` and
//!   `<game>/events/*.zig` — the realm an agent edits gets full detail.
//! - **Plugin / engine realms** surface names + the public verb surface
//!   (`exposes`) derived from the already-discovered FlowNodes
//!   (`PluginFlowNode`, command = void impl / query = reporter) and
//!   Events (`PluginEvent`). Plugin event *payloads* already live in
//!   `flow_catalog.json` per-plugin, so the manifest references plugins
//!   by name rather than re-walking them (minimality guardrail: read the
//!   realm you're changing, not every field of every dependency).
//! - `depends_on` for the game realm = the plugins declared in
//!   `project.labelle`.
//!
//! ## Deferred (called out, not silently dropped)
//!
//! - **`recipes`** — emitted as an empty array on every realm. The one
//!   *non-*derivable field; it shares the scaffold's template source
//!   (`labelle add <kind>`, cli #271/#scaffold) so recipe and scaffold
//!   stay a single definition. Forward-referenced here.
//! - **`emitted_by` / `subscribed_by`** event cross-refs — emitted as
//!   empty arrays. The AST emit/subscribe extraction across every script
//!   is a larger pass (the scanner doesn't track call sites yet); the
//!   shape is in place so a follow-up can fill it without a schema bump.
//!
//! ## Packs (#499 — the realm designed for LLM authors)
//!
//! A declared plugin that carries a `pack.labelle` (a *pack*) gets a
//! `tier: "pack"` realm with the SAME full detail the game root gets —
//! AST-parsed component field schemas + save policy + `visibility`
//! (`global`|`pack`, default `pack`), AST-parsed event payloads, prefabs,
//! hooks, and scripts — plus the pack-only bits: the invisible
//! `namespace_prefix` (`<pfx>__`), the registry `emitted_name` /
//! `emitted_tag` each contribution lands under, and the `exposes`
//! (`commands`/`queries`) + `depends_on` DAG surface read from
//! `pack.labelle`. Pack components/events are parsed from the STAGED copies
//! under `<target>/packs/<name>/` and pack events are added to
//! `contracts.events` realm-qualified (`citizens.Hit`). Emitted names are
//! derived through the SAME helpers codegen uses (`scan.packNamespacePrefix`,
//! `idents.pathToPascal`, `idents.eventVariantName`, `path.basename`) so the
//! manifest never drifts from the generated registry symbols.
//!
//! ```jsonc
//!   { "name": "citizens", "tier": "pack", "namespace_prefix": "citizens",
//!     "components": [ { "name": "Worker", "emitted_name": "citizens__Worker",
//!                       "save": "saveable", "visibility": "pack",
//!                       "fields": { "hunger": "f32" } } ],
//!     "events": [ { "name": "Hit", "emitted_tag": "citizens__hit",
//!                   "payload": { "attacker": "u64" },
//!                   "emitted_by": [], "subscribed_by": [] } ],
//!     "prefabs": [ { "name": "worker", "emitted_name": "citizens__worker" } ],
//!     "hooks": ["overlay"], "scripts": [ ... ],
//!     "depends_on": ["contracts"],
//!     "exposes": { "commands": ["assign_home"], "queries": ["worker_count"] },
//!     "recipes": [] }
//! ```
//!
//! ── Barrel ──────────────────────────────────────────────────────────
//! This file was a single ~1600-line module; it is now a thin barrel that
//! re-exports the public surface from focused sub-modules under `manifest/`
//! (behavior-preserving split, mirrors the `codegen/scan.zig` split in #539).
//! Every symbol keeps its original name and identity so existing
//! `manifest.<Name>` call sites are unchanged:
//!
//!   - `manifest/parse.zig` — game/pack realm struct parsing (`Field`,
//!                            `StructDecl`, `parseStructDir`, `parseStructFile`)
//!   - `manifest/json.zig`  — JSON emission (`ManifestData`, `PackRealm`,
//!                            `SCHEMA_VERSION`, `writeManifestJson`)
//!   - `manifest/emit.zig`  — orchestration (`MANIFEST_FILENAME`, `PackInput`,
//!                            `emitManifestSidecar`)

const parse = @import("manifest/parse.zig");
const json = @import("manifest/json.zig");
const emit = @import("manifest/emit.zig");

// ── JSON emission (manifest/json.zig) ────────────────────────────────
/// Schema version stamped into the emitted JSON so consumers can gate.
pub const SCHEMA_VERSION = json.SCHEMA_VERSION;

// ── Orchestration (manifest/emit.zig) ────────────────────────────────
/// Filename emitted next to `flow_catalog.json` in `<game>/.labelle/`.
pub const MANIFEST_FILENAME = emit.MANIFEST_FILENAME;
pub const PackInput = emit.PackInput;
pub const emitManifestSidecar = emit.emitManifestSidecar;

// Pull every sub-module's tests into the `manifest.zig` analysis so
// `zig build test` keeps running the specs that used to live here.
test {
    _ = parse;
    _ = json;
    _ = emit;
}
