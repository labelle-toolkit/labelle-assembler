//! `generateMainZigFromTemplate` — the central main.zig codegen orchestrator.
//!
//! Extracted from `src/main_zig.zig` per step 9 (the final structural cut)
//! of the refactor plan in `docs/REFACTOR-PLAN-main-zig.md`
//! (labelle-assembler#183). This is the HIGHEST-risk move: the orchestrator
//! wires ~18 named template scalars to `tpl.renderDynamic`, each into its
//! own `Allocating` writer. Reordering slot emission, mutating any
//! `try w.writeAll(...)` string literal, or shuffling an allocator
//! lifetime would shift the generated `main.zig` — and any byte drift
//! breaks the bit-identical contract across every backend × platform.
//!
//! Pure move + re-export. Every helper this orchestrator calls was
//! extracted in a prior step (scan, idents, validate, asset_wiring,
//! scene_manifests, resource_loader, plugin_registries, preview,
//! lifecycle/loop, lifecycle/callback). Each is imported here by its
//! canonical path; `main_zig.zig` keeps re-export aliases for back-
//! compat callers (`root.zig`, `test/tests.zig`) but the orchestrator
//! itself no longer routes through the shim.
//!
//! The two tiny end-of-file helpers (`generateGameLayers`,
//! `generateResourceRegistry`) move with the orchestrator because they
//! are only ever called from inside `generateMainZigFromTemplate`.

const std = @import("std");
const tpl = @import("../template.zig");
const config = @import("../config.zig");
const script_scanner = @import("../script_scanner.zig");
const scene_manifest = @import("../scene_manifest.zig");
const tilemap_scan = @import("../tilemap_scan.zig");
const scan = @import("scan.zig");
const validate = @import("validate.zig");
const context = @import("context.zig");
const hooks_block = @import("blocks/hooks.zig");
const manifest_v2 = @import("manifest_v2.zig");

/// Manifest-driven run-loop splice (pluggable-backends RFC, assembler#378).
/// When non-null, the run-loop style was resolved from the backend manifest's
/// `loop_style` field and OVERRIDES the enum-based `use_callback_lifecycle`
/// selection in `generateMainZigFromTemplate`. `root.zig` sets this
/// immediately before the call and clears it after (so the override is scoped
/// to that one generation). Module-level rather than a positional param on the
/// ~130-arg generator purely to keep the splice's diff localized — a later
/// refactor can thread it as a proper argument. Null keeps the enum path
/// verbatim. For bgfx-desktop the manifest declares `.loop`, so the resolved
/// `use_callback_lifecycle` is false — identical to the enum path.
pub threadlocal var loop_style_override: ?manifest_v2.BackendManifestV2.PlatformEntry.LoopStyle = null;

/// Manifest-declared callback-lifecycle blocks (assembler#501). Set by
/// `root.zig` from the v2 manifest's `.platforms.<platform>.lifecycle` right
/// before the `generateMainZigFromTemplate` call and cleared after — the same
/// scoped-threadlocal pattern as `loop_style_override` (kept off the ~19-arg
/// generator signature). Non-null both lifts the callback-external rejection
/// AND drives the render shape for a declared third-party callback backend.
/// Null keeps the enum-predicate shape verbatim for every built-in.
pub threadlocal var lifecycle_override: ?manifest_v2.BackendManifestV2.PlatformEntry.Lifecycle = null;

/// Pack dir-scan results (Packs RFC §4, labelle-assembler#439). Each entry
/// carries one pack's scanned component/event/prefab stems + its
/// `import_prefix`, so the registry block-writers can register them into the
/// SAME registries the game root feeds (the unified set). `root.zig` sets
/// this immediately before the `generateMainZigFromTemplate` call and clears
/// it after — same module-level-var pattern as `loop_style_override`, chosen
/// to keep this diff off the generator's ~19 positional-arg signature (which
/// has 100+ call sites in the test suite). Empty (the default) → no packs,
/// every registry block emits its exact pre-pack shape.
pub threadlocal var pack_scans: []const scan.PackScan = &.{};

/// Embedded-tilemap registrations (T2 Phase 4, tilemap epic). Each entry
/// becomes one `addEmbeddedTilemapAsset("<key>", @embedFile("<embed_path>"))`
/// call in the generated `init()` — the scene-referenced `.tmx` documents
/// plus their tileset images. `root.zig` sets this immediately before the
/// `generateMainZigFromTemplate` call and clears it after (same
/// scoped-threadlocal pattern as `pack_scans`, kept off the ~19-arg
/// generator signature). Empty (the default) → tilemap-free project, no
/// tilemap registrations emitted.
pub threadlocal var tilemap_registrations: []const tilemap_scan.Registration = &.{};

const ProjectConfig = config.ProjectConfig;
const LayerDef = config.LayerDef;
const ResourceDef = config.ResourceDef;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;
const SceneManifest = scene_manifest.SceneManifest;

// Scan types (function-parameter slice element types).
const PluginEvent = scan.PluginEvent;
const PluginFlowNode = scan.PluginFlowNode;
const PluginPinStyle = scan.PluginPinStyle;
const PluginCoercion = scan.PluginCoercion;

// Validation (pure helpers — not mixin-converted; see codegen/context.zig).
const checkBasenameCollisions = validate.checkBasenameCollisions;
const hasContextEntry = validate.hasContextEntry;
const validateResources = validate.validateResources;

const Codegen = context.Codegen;

// The per-block builders (imports, hooks, events, registries) and the
// stateful lifecycle render now live in codegen/blocks/*.zig and
// codegen/lifecycle/render.zig respectively, dispatched here through the
// `Codegen` mixin context (`ctx.writeXxxBlock(...)` / `ctx.renderLifecycle`).
// Preview-mode template literals + the bgfx-Android register snippet moved
// with the lifecycle render that consumes them.

/// Build one template scalar block: spin up an `Allocating` writer, run
/// `emitFn(ctx, writer, ident_buf)`, take ownership of the rendered
/// bytes, register them in `allocs` for cleanup, and return the slice.
/// Collapses the writer→`toOwnedSlice`→`appendAssumeCapacity` boilerplate
/// the orchestrator repeated once per block. `allocs` must have reserved
/// capacity for the append (the orchestrator pre-reserves
/// `ALLOCS_BLOCK_COUNT`). `emitFn` always takes the shared `ident_buf`;
/// writers that don't need it simply ignore the param.
fn block(
    allocator: std.mem.Allocator,
    allocs: *std.ArrayList([]const u8),
    comptime emitFn: anytype,
    ctx: *Codegen,
    ident_buf: *[256]u8,
) ![]const u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();
    try emitFn(ctx, &alloc_writer.writer, ident_buf);
    var arr_list = alloc_writer.toArrayList();
    // `toArrayList` moved the buffer out of `alloc_writer` (its errdefer above is
    // now a no-op), so guard `arr_list` until `toOwnedSlice` transfers ownership.
    errdefer arr_list.deinit(allocator);
    const out = try arr_list.toOwnedSlice(allocator);
    allocs.appendAssumeCapacity(out);
    return out;
}

// ── Template-based generation (engine provides main.zig.template) ────────

/// Generate main.zig using the engine's codegen template.
/// The template uses {{variable}} interpolation and {{#if}}/{{#each}} blocks.
/// All complex sections are pre-computed into scalar blocks by this function.
pub fn generateMainZigFromTemplate(
    allocator: std.mem.Allocator,
    engine_template: []const u8,
    cfg: ProjectConfig,
    lifecycle_tmpl: []const u8,
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
    // RFC-FLOW-VOCABULARY phase 2 — discovered FlowNodes/PinStyles from
    // plugin AND game-script modules. Both lists may be empty; the
    // emitter writes a `PluginFlowNodes = struct {}` / `PluginPinStyles
    // = struct {}` shell either way so downstream code paths
    // (flow-codegen phase 3, labelle-gui phase 4) can reflect uniformly.
    plugin_flow_nodes: []const PluginFlowNode,
    plugin_pin_styles: []const PluginPinStyle,
    /// RFC-FLOW-VOCABULARY §2 / O4 — plugin-declared coercions. Same
    /// shape contract as `plugin_flow_nodes` / `plugin_pin_styles`:
    /// emitter writes a `PluginCoercions = struct {}` shell when this
    /// slice is empty so downstream comptime reflection (flow-codegen
    /// edge wrap, labelle-gui wire-fit check) stays uniform.
    plugin_coercions: []const PluginCoercion,
) ![]const u8 {
    // Surface basename collisions at generate time, before any
    // code emission — otherwise two prefabs with the same filename
    // in different subfolders would both try to register the same
    // name and silently overwrite. Match the diagnostic style in
    // `main.zig:97` (`stderr().writeAll(...)`) instead of
    // `std.log.err` so the Zig test runner doesn't classify the
    // expected diagnostic as a logged-error test failure.
    if (try checkBasenameCollisions(allocator, prefab_names)) |msg| {
        defer allocator.free(msg);
        const prefix = "labelle-assembler: ";
        const io = config.globalIo();
        std.Io.File.stderr().writeStreamingAll(io, prefix) catch {};
        std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
        std.Io.File.stderr().writeStreamingAll(io, "\n") catch {};
        return error.PrefabBasenameCollision;
    }

    // Validate every resource entry before any codegen. Catches
    // half-declared atlases (only `.json` or only `.texture`),
    // multi-kind tangles (`.sound` + `.font` on the same entry),
    // unrecognised file extensions, and misplaced `.font_params`.
    // The diagnostic is written to stderr inside the helper so
    // each malformed entry surfaces its name and reason before bailout.
    try validateResources(cfg);

    // Shared codegen context (labelle-assembler#183 mixin conversion).
    // Borrows every slice passed in as positional args so the per-block
    // call sites below dispatch as `ctx.writeXxx(...)` instead of
    // re-threading the slices into every call. State + dispatch shape
    // models `labelle-engine/src/game.zig`'s Game + *_mixin.zig pairing.
    var ctx: Codegen = .{
        .allocator = allocator,
        .cfg = cfg,
        .script_entries = script_entries,
        .prefab_names = prefab_names,
        .jsonc_scene_names = jsonc_scene_names,
        .scene_manifests = scene_manifests,
        .component_names = component_names,
        .hook_names = hook_names,
        .event_names = event_names,
        .enum_names = enum_names,
        .view_names = view_names,
        .gizmo_names = gizmo_names,
        .animation_names = animation_names,
        .plugin_events = plugin_events,
        .plugin_flow_nodes = plugin_flow_nodes,
        .plugin_pin_styles = plugin_pin_styles,
        .plugin_coercions = plugin_coercions,
        // Packs (RFC §4, #439) — read from the module-level var set by
        // root.zig. Defaults to empty so every existing call site (tests,
        // preview) keeps its exact pre-pack emission.
        .pack_scans = pack_scans,
        // Embedded-tilemap registrations (T2 Phase 4) — read from the
        // module-level var set by root.zig. Empty for every existing call
        // site (tests, preview, tilemap-free projects), so those emit no
        // tilemap registrations.
        .tilemap_registrations = tilemap_registrations,
        // wasm-only: does the backend's lifecycle (wasm) template ship its own
        // `pub const panic`? If so, the assembler must NOT also emit its
        // stopgap panic shim (they would duplicate the root decl). Scanned from
        // the template text, so it's backend-agnostic (bgfx ships one, raylib
        // does not). Only consulted on wasm.
        .wasm_template_provides_panic = cfg.platform == .wasm and
            std.mem.indexOf(u8, lifecycle_tmpl, "pub const panic") != null,
    };

    var data = tpl.TemplateData{
        .scalars = std.StringHashMap([]const u8).init(allocator),
        .lists = std.StringHashMap([]const tpl.ListItem).init(allocator),
    };
    defer data.scalars.deinit();
    defer data.lists.deinit();

    // Track allocations for cleanup. Capacity is reserved up front for
    // every `appendAssumeCapacity` call site below — each emitted block
    // is appended at most once, so reserving the literal call-site count
    // is a safe upper bound. Reserving makes the appends infallible,
    // closing the OOM window where a `toOwnedSlice`'d block is owned but
    // not yet in this cleanup list (errdefer audit, #75).
    const ALLOCS_BLOCK_COUNT = 18;
    var allocs: std.ArrayList([]const u8) = .empty;
    defer {
        for (allocs.items) |s| allocator.free(s);
        allocs.deinit(allocator);
    }
    try allocs.ensureTotalCapacity(allocator, ALLOCS_BLOCK_COUNT);

    // ── Boolean flags ──
    try data.scalars.put("ecs_mode_mock", if (cfg.ecs == .mock) "1" else "");
    try data.scalars.put("has_gui", if (cfg.hasGui()) "1" else "");
    try data.scalars.put("has_context", if (hasContextEntry(script_entries)) "1" else "");

    // ── Pre-computed blocks ──
    var ident_buf: [256]u8 = undefined;

    // Import + JSONC-scene blocks (codegen/blocks/imports.zig). Each
    // writer fills its own `Allocating` block via the `block()` helper,
    // which owns the writer→owned-slice→cleanup-list dance the orchestrator
    // used to repeat inline per block.
    {
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, ib: *[256]u8) !void {
                try c.writeHookImportsBlock(w, ib);
                // External-backend contract guard (#386 Phase 6b) — emitted at
                // module root alongside the hook imports, no-op for built-ins.
                try c.writeBackendContractCheck(w);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("hook_imports_block", b);
    }
    {
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, _: *[256]u8) !void {
                try c.writeEventImportsBlock(w);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("event_imports_block", b);
    }
    {
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, ib: *[256]u8) !void {
                try c.writeEnumImportsBlock(w, ib);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("enum_imports_block", b);
    }
    {
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, ib: *[256]u8) !void {
                try c.writeJsoncSceneBlock(w, ib);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("jsonc_scene_block", b);
    }

    // Game layers block
    {
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, _: *[256]u8) !void {
                try generateGameLayers(c.cfg.layers, w);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("game_layers_block", b);
    }

    // Resource registry block — resources are now loaded at runtime via
    // @embedFile + loadAtlasFromMemory, so the comptime registry is empty.
    // The block is kept as an empty string for template compatibility.
    {
        const empty = try allocator.dupe(u8, "");
        allocs.appendAssumeCapacity(empty);
        try data.scalars.put("resource_registry_block", empty);
    }

    // AllHookPayloads block — merge engine payloads with game events
    // (`events/*.zig` scan, labelle-engine#422) and plugin events
    // (`pub const Events` on plugin modules, RFC-PLUGIN-EVENTS phase 1).
    // PluginEvents is always a union (possibly empty) when any plugin
    // exists, so it can sit inside the same `MergeHookPayloads` call —
    // game events stay on the same merged `AllHookPayloads` (no parallel
    // dispatcher, per RFC §2 "feed the existing pipeline").
    {
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, _: *[256]u8) !void {
                try c.writeAllHookPayloadsBlock(w);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("all_hook_payloads_block", b);
    }

    // Priority-aware ordering of the flow tail (RFC-PLUGIN-EVENTS phase
    // 4/7, labelle-assembler#175). `buildFlowOrder` returns indices into
    // `script_entries` for every `has_event_handler` flow — priority-set
    // entries first (descending), then the rest in scanner order. Owned
    // here so its lifetime is visible at the call site; both the
    // game-hooks and hooks-init writers consume the same slice so the
    // receiver-type order matches the receiver-pointer order
    // (`MergeHooks.emit` looks receivers up by tuple position). See
    // `codegen/blocks/hooks.zig` for the full rationale.
    var flow_order = try hooks_block.buildFlowOrder(allocator, script_entries);
    defer flow_order.deinit(allocator);
    ctx.flow_order = flow_order.items;

    // Game hooks block (codegen/blocks/hooks.zig).
    {
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, ib: *[256]u8) !void {
                try c.writeGameHooksBlock(w, ib, c.flow_order);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("game_hooks_block", b);
    }

    // Hooks init block (codegen/blocks/hooks.zig).
    {
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, ib: *[256]u8) !void {
                try c.writeHooksInitBlock(w, ib, c.flow_order);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("hooks_init_block", b);
    }

    // Game events + Plugin events block (codegen/blocks/events.zig).
    // Composes the game-side `events/*.zig` scan with plugin-side
    // discovery (events/flow-nodes/pin-styles/coercions); see that file
    // for the RFC-PLUGIN-EVENTS / RFC-FLOW-VOCABULARY rationale.
    {
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, _: *[256]u8) !void {
                try c.writeGameEventsBlock(w);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("game_events_block", b);
    }

    // Comptime registry blocks (codegen/blocks/registries.zig).
    {
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, _: *[256]u8) !void {
                try c.writePrefabRegistryBlock(w);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("prefab_registry_block", b);
    }
    {
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, _: *[256]u8) !void {
                try c.writeComponentRegistryBlock(w);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("component_registry_block", b);
    }
    {
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, _: *[256]u8) !void {
                try c.writeSystemRegistryBlock(w);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("system_registry_block", b);
    }
    {
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, ib: *[256]u8) !void {
                try c.writeAllScriptsBlock(w, ib);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("all_scripts_block", b);
    }
    {
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, ib: *[256]u8) !void {
                try c.writeViewRegistryBlock(w, ib);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("view_registry_block", b);
    }
    {
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, ib: *[256]u8) !void {
                try c.writeGizmoRegistryBlock(w, ib);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("gizmo_registry_block", b);
    }
    {
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, _: *[256]u8) !void {
                try c.writeAnimationRegistryBlock(w);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("animation_registry_block", b);
    }

    // ── Lifecycle section (rendered from backend template, same as procedural path) ──
    // Extracted to codegen/lifecycle/render.zig — the stateful per-backend
    // dispatch (sokol / raylib-wasm / bgfx-android callback paths + the loop
    // path for raylib-desktop / sdl / bgfx-desktop / wgpu). `hooks_init` is
    // the already-rendered `hooks_init_block` scalar the lifecycle templates
    // re-embed; the manifest-driven `loop_style_override` is read here and
    // passed by value so the render module stays free of the threadlocal.
    {
        ctx.lifecycle_tmpl = lifecycle_tmpl;
        ctx.hooks_init = data.scalars.get("hooks_init_block") orelse "    var hooks = GameHooks{};\n";
        ctx.loop_style_override = loop_style_override;
        ctx.lifecycle_override = lifecycle_override;
        const b = try block(allocator, &allocs, struct {
            fn emit(c: *Codegen, w: anytype, _: *[256]u8) !void {
                try c.renderLifecycle(w, c.lifecycle_tmpl, c.hooks_init, c.loop_style_override, c.lifecycle_override);
            }
        }.emit, &ctx, &ident_buf);
        try data.scalars.put("lifecycle", b);
    }

    // ── Render the engine template ──
    var output_alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer output_alloc_writer.deinit();
    try tpl.renderDynamic(engine_template, data, &output_alloc_writer.writer);
    var output_arr_list = output_alloc_writer.toArrayList();
    errdefer output_arr_list.deinit(allocator);
    const rendered = try output_arr_list.toOwnedSlice(allocator);
    defer allocator.free(rendered);

    // ── Thread the project Y-axis onto the generated game config ──
    // RFC-Y-AXIS-CONVENTION (epic labelle-engine#640), assembler #370.
    //
    // The engine `codegen/main.zig.template` (≥ v1.61.0, engine#642) declares a
    // single source-of-truth `const project_y_axis: engine.core.YAxis = .up;`
    // that feeds BOTH the renderer (`GfxRendererWith`) and `GameConfigWithYAxis`.
    // We override that const's value with the project's `.y_axis` so the
    // convention comes from `project.labelle`, not the engine default.
    // `requireYAxis` first enforces the unset-guard — an absent `.y_axis` is a
    // hard error so no existing game silently flips.
    const y_axis = try cfg.requireYAxis();
    return injectYAxis(allocator, rendered, y_axis);
}

/// Override the value of the engine template's single source-of-truth
/// `const project_y_axis: engine.core.YAxis = .up;` with the project's logical
/// Y-axis (RFC-Y-AXIS-CONVENTION / assembler #370). That const feeds BOTH the
/// renderer (`GfxRendererWith(..., project_y_axis)`) and the game config
/// (`GameConfigWithYAxis(..., project_y_axis)`), so overriding it once makes
/// output flip and input picking agree under the chosen convention. Caller owns
/// the returned bytes.
///
/// Anchors on the `const project_y_axis: engine.core.YAxis = ` declaration and
/// replaces the value token up to its `;`, independent of the template default.
/// (Earlier engine templates emitted a bare `engine.GameConfig(...)` call; that
/// form is gone as of engine#642 — overriding the const is the current seam.)
fn injectYAxis(
    allocator: std.mem.Allocator,
    rendered: []const u8,
    y_axis: config.YAxis,
) ![]const u8 {
    const anchor = "const project_y_axis: engine.core.YAxis = ";
    const anchor_at = std.mem.indexOf(u8, rendered, anchor) orelse {
        // No `project_y_axis` declaration — nothing to override, so hand back an
        // owned copy unchanged. The real engine template (≥ v1.61.0) always has
        // it; this branch covers minimal test fixtures. The unset-`.y_axis`
        // guard has already fired in the caller, so an absent key is still
        // rejected regardless of template shape.
        return allocator.dupe(u8, rendered);
    };

    const val_at = anchor_at + anchor.len; // first byte of the value token
    const semi_rel = std.mem.indexOfScalar(u8, rendered[val_at..], ';') orelse {
        const io = config.globalIo();
        std.Io.File.stderr().writeStreamingAll(
            io,
            "labelle-assembler: malformed `project_y_axis` declaration (no terminating `;`)\n",
        ) catch {};
        return error.YAxisConstMalformed;
    };
    const semi_at = val_at + semi_rel; // index of the ';'

    const y_tag = @tagName(y_axis);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    // [0, val_at) — everything up to and including "= "
    try w.writeAll(rendered[0..val_at]);
    // the project's axis, replacing the template default
    try w.print(".{s}", .{y_tag});
    // [semi_at, end) — from the ';' onward, verbatim
    try w.writeAll(rendered[semi_at..]);

    var arr = out.toArrayList();
    errdefer arr.deinit(allocator);
    return arr.toOwnedSlice(allocator);
}

/// Generate the GameLayers enum from project.labelle layer definitions.
pub fn generateGameLayers(layers: []const LayerDef, w: anytype) !void {
    try w.writeAll("const GameLayers = enum(u8) {\n");
    for (layers) |layer| {
        try w.print("    {s},\n", .{layer.name});
    }
    try w.writeAll("\n    pub fn config(self: GameLayers) gfx.LayerConfig {\n");
    try w.writeAll("        return switch (self) {\n");
    for (layers) |layer| {
        try w.print("            .{s} => .{{ .order = {d}, .space = .{s} }},\n", .{
            layer.name,
            layer.order,
            @tagName(layer.space),
        });
    }
    try w.writeAll("        };\n");
    try w.writeAll("    }\n");
    try w.writeAll("};\n");
}

/// Generate the ResourceRegistry from project.labelle resource definitions.
/// Each resource maps a name to a ComptimeAtlas loaded from a .zon frame file,
/// plus the texture path for the backend to load at runtime.
pub fn generateResourceRegistry(resources: []const ResourceDef, w: anytype) !void {
    try w.writeAll("const ResourceRegistry = struct {\n");
    for (resources) |res| {
        try w.print("    pub const {s} = engine.ComptimeAtlas(@import(\"{s}\"));\n", .{ res.name, res.json });
    }
    try w.writeAll("\n    pub const textures = .{\n");
    for (resources) |res| {
        try w.print("        .{s} = \"{s}\",\n", .{ res.name, res.texture });
    }
    try w.writeAll("    };\n");
    try w.print("\n    pub const names: [{d}][]const u8 = .{{\n", .{resources.len});
    for (resources) |res| {
        try w.print("        \"{s}\",\n", .{res.name});
    }
    try w.writeAll("    };\n");
    try w.writeAll("};\n");
}
