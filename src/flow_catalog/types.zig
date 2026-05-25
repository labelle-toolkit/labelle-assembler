//! Flow-catalog data types — the on-disk shape emitted to
//! `flow_catalog.json` and consumed by the labelle-gui flow editor.
//!
//! Extracted from the original `src/flow_catalog.zig` as part of the
//! per-concern split (labelle-assembler#186). The discovery (AST walk
//! and source-text scans) lives in `discovery.zig`; the JSON writer +
//! sidecar emission live in `json_writer.zig`; the shared low-level
//! scanners live in `scanners.zig`.

const std = @import("std");

/// Filename emitted next to `main.zig` in the generated target dir.
pub const SIDECAR_FILENAME = "flow_catalog.json";

/// One pin on a `FlowNodeEntry`. Mirrors the editor's
/// `labelle-gui/src/flow_node_catalog.zig:Pin` shape so the loader can
/// round-trip into the same in-memory representation.
pub const PinDetail = struct {
    /// Identifier as it appears in the impl function's parameter list.
    name: []const u8,
    /// Display label — defaults to titlecased `name`, overridden by
    /// `.pins.<name> = .{ .label = "..." }` on the FlowNode config.
    label: []const u8,
    /// Zig source text of the parameter's type (`u32`, `f32`,
    /// `EntityId`, `*PhysicsBody`, …). For the implicit output pin on a
    /// reporter, this is the function's return-type source.
    zig_type: []const u8,
    /// `"input"` for impl parameters, `"output"` for the return-type
    /// derived pin on a reporter. JSON-friendly tagged form so the
    /// loader doesn't need a separate enum mapping.
    dir: []const u8,
    /// Author-supplied Zig source text of the pin's default, or `null`
    /// when none was declared. Carries through the FlowNode config's
    /// `.pins.<name> = .{ .default = "..." }` override.
    default: ?[]const u8,
};

/// One catalog entry — a plugin- or game-script-declared FlowNode with
/// every metadata field the editor consumes already resolved against
/// the source.
pub const FlowNodeEntry = struct {
    /// Dotted form (`"box2d.apply_impulse"`). The editor's on-disk
    /// `CustomNode.name` field uses the dotted form verbatim.
    qualified: []const u8,
    /// Palette section label — defaults to the contributing module's
    /// name. Plugins / scripts can override via `.category = "..."`.
    category: []const u8,
    /// Human-readable label for the palette + node body. Defaults to
    /// the bare decl name titlecased when no `.display_name = "..."`
    /// override is present.
    display_name: []const u8,
    /// Tooltip text (`.docs = "..."`). Empty string when absent.
    docs: []const u8,
    /// `"command"` (rectangular, exec flow) or `"reporter"` (rounded,
    /// data-only). Derived from return type when the FlowNode config
    /// doesn't pin `.kind` explicitly.
    kind: []const u8,
    /// Pin definitions in display order. Inputs first, the optional
    /// output pin (return value) last.
    pins: []const PinDetail,
    /// Zig source text of the impl's return type, or `null` when the
    /// impl returns `void`. The output pin is already folded into
    /// `pins`; this carries the type separately for the editor's
    /// constructor-node decisions (#O5 follow-up) and connector colour.
    return_type: ?[]const u8,
};

/// One per-type pin-display override discovered on a plugin / script
/// `pub const PinStyles` block. Keyed by Zig type name; the editor
/// merges these on top of its baked-in defaults.
pub const PinStyleEntry = struct {
    /// Zig type name as it appears in the source (the decl identifier).
    zig_type: []const u8,
    /// Display label — `.label = "..."` on the PinStyle literal.
    label: []const u8,
    /// 8-bit-per-channel RGB color the editor paints the pin in.
    /// Source: `.color = .{ .r = N, .g = N, .b = N, ... }`. Alpha is
    /// dropped because the editor treats pins as opaque.
    color: [3]u8,
};

/// One `pub const <name> = labelle.flow.Coercion(.{ .impl = ... })`
/// decl inside a module's top-level `pub const Coercions` block
/// (RFC-FLOW-VOCABULARY §2 / O4 — plugin-declared coercions). The
/// editor consults `from_zig_type` / `to_zig_type` at wire-fit time
/// to accept an edge between two pins whose Zig types differ but for
/// which a registered coercion bridges; flow-codegen wraps the source
/// expression in a `<plugin>__<name>.convert(...)` call at the edge
/// site.
///
/// Mirrors the on-disk dotted form (`box2d.body_to_entity`) so the
/// editor + flow-codegen share one canonical lookup key.
pub const CoercionEntry = struct {
    /// Dotted form (`"box2d.body_to_entity"`). Matches the qualified
    /// emitted decl name on `PluginCoercions` (modulo `.` → `__`).
    qualified: []const u8,
    /// Bare coercion identifier (`"body_to_entity"`). Carried separately
    /// from `qualified` so the editor can render it under the
    /// contributing module's palette section.
    name: []const u8,
    /// Zig source text of the impl's single parameter type. Extracted
    /// verbatim from the impl function's prototype.
    from_zig_type: []const u8,
    /// Zig source text of the impl's return type. The catalog never
    /// emits a coercion whose return is `void` — the labelle-core
    /// factory rejects it at comptime.
    to_zig_type: []const u8,
    /// Tooltip text (`.docs = "..."` on the factory call). Empty when
    /// absent.
    docs: []const u8,
};

/// One `pub const <name> = struct {...}` decl inside a module's
/// top-level `pub const Events` block (labelle-engine#578 — engine
/// lifecycle events; RFC-PLUGIN-EVENTS phase 1 — plugin events).
/// The editor's palette renders these as Event-node variants under
/// the contributing module's section.
///
/// Mirrors the on-disk JSONC dot form (`engine.tick`) so a flow's
/// `Event` node `.name` field round-trips through the catalog.
pub const EventEntry = struct {
    /// Dotted form (`"engine.tick"`, `"box2d.collision_begin"`).
    /// Matches the `Event` node's on-disk `.name` value verbatim.
    qualified: []const u8,
    /// Bare event identifier (`"tick"`, `"collision_begin"`).
    /// Editor surfaces this as the node body label when no explicit
    /// display override is present.
    name: []const u8,
    /// Each payload struct field as a `PinDetail`. `dir` is always
    /// `"output"` — the on-disk Event-node form fans out the payload
    /// fields as data outputs that downstream `SetVariable` /
    /// `CustomNode` nodes consume.
    pins: []const PinDetail,
};

/// Per-module group of catalog entries. The editor renders one
/// collapsible palette section per group keyed by `name`.
pub const ModuleGroup = struct {
    name: []const u8,
    flow_nodes: []FlowNodeEntry,
    pin_styles: []PinStyleEntry,
    /// Events (labelle-engine#578) — fired through the buffered
    /// `Game.emit` path and listenable as `Event` nodes in flows.
    /// Defaults to an empty slice for modules that declare no
    /// `Events` block, so the JSON shape stays uniform.
    events: []EventEntry = &.{},
    /// Coercions (RFC-FLOW-VOCABULARY §2 / O4) — plugin-declared
    /// type-conversion bridges. The editor's wire-fit check accepts an
    /// edge whose `(from_zig_type, to_zig_type)` matches a registered
    /// coercion; flow-codegen wraps the source expression in
    /// `<qualified>.convert(...)` at the edge site. Defaults to an
    /// empty slice so the JSON shape stays uniform for modules without
    /// a `Coercions` block.
    coercions: []CoercionEntry = &.{},
};

/// The full catalog as it ends up on disk. Self-describes its source
/// timestamp so the editor can compare against a cached snapshot.
pub const Catalog = struct {
    /// ISO-8601-ish UTC timestamp the sidecar was generated. Format:
    /// `"YYYY-MM-DDTHH:MM:SSZ"` — minute-resolution is enough for the
    /// editor's mtime cache.
    generated_at: []const u8,
    /// One entry per module that contributed at least one FlowNode or
    /// PinStyle. Order matches discovery order (plugins first, then
    /// game scripts) — which matches the existing
    /// `discoverPluginFlowDecls` order, so the editor's palette is
    /// stable across regenerations.
    plugins: []ModuleGroup,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Catalog) void {
        // Strings + slices live in the catalog's arena (set up by
        // `discoverDetailedFlowCatalog`); freeing the arena drops
        // them all in one go. We keep an explicit `deinit` so the
        // surrounding `generate` flow doesn't need to know about
        // the arena.
        // No-op here: arena pointer is held by the caller via the
        // returned struct's allocator (the arena's child allocator).
        _ = self;
    }
};
