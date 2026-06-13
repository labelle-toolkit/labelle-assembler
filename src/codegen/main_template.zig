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
const scan = @import("scan.zig");
const idents = @import("idents.zig");
const validate = @import("validate.zig");
const preview = @import("preview.zig");
const context = @import("context.zig");

const ProjectConfig = config.ProjectConfig;
const PluginDep = config.PluginDep;
const LayerDef = config.LayerDef;
const ResourceDef = config.ResourceDef;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;
const SceneManifest = scene_manifest.SceneManifest;

// Scan types + helpers
const PluginEvent = scan.PluginEvent;
const PluginFlowNode = scan.PluginFlowNode;
const PluginPinStyle = scan.PluginPinStyle;
const PluginCoercion = scan.PluginCoercion;
const dedupePinStyles = scan.dedupePinStyles;
const pathToIdent = scan.pathToIdent;

/// True iff `ident` (a game script's `pathToIdent(rel_path)`) names a
/// game-script module that contributed at least one FlowNode and is
/// therefore promoted to a named build module (labelle-assembler#240
/// Gap 2). `module_sanitized` of an `is_script` flow node equals
/// `pathToIdent(rel_path)`, so the comparison is a direct string match.
/// Used by the `AllScripts` emitter to switch promoted scripts to the
/// `@import("script__<ident>")` form.
fn isFlowNodeScript(flow_nodes: []const PluginFlowNode, ident: []const u8) bool {
    for (flow_nodes) |fn_| {
        if (!fn_.is_script) continue;
        if (std.mem.eql(u8, fn_.module_sanitized, ident)) return true;
    }
    return false;
}

// Identifier helpers
const pathToPascal = idents.pathToPascal;
const eventVariantName = idents.eventVariantName;

// Validation (pure helpers — not mixin-converted; see codegen/context.zig).
const checkBasenameCollisions = validate.checkBasenameCollisions;
const hasContextEntry = validate.hasContextEntry;
const validateResources = validate.validateResources;

const Codegen = context.Codegen;

// Preview-mode templates (extracted to codegen/preview.zig).
const WASM_PANIC_WORKAROUND = preview.WASM_PANIC_WORKAROUND;
const PREVIEW_HELPERS = preview.PREVIEW_HELPERS;
const PREVIEW_READBACK_HELPERS = preview.PREVIEW_READBACK_HELPERS;
const PREVIEW_LOOP_SETUP = preview.PREVIEW_LOOP_SETUP;
const PREVIEW_READBACK_SETUP = preview.PREVIEW_READBACK_SETUP;
const PREVIEW_HEARTBEAT_LOOP = preview.PREVIEW_HEARTBEAT_LOOP;
const PREVIEW_INPUT_DISPATCH = preview.PREVIEW_INPUT_DISPATCH;
const PREVIEW_INPUT_DISPATCH_STUB = preview.PREVIEW_INPUT_DISPATCH_STUB;
const PREVIEW_READBACK_LOOP = preview.PREVIEW_READBACK_LOOP;
const PREVIEW_INIT_CALLBACK = preview.PREVIEW_INIT_CALLBACK;
const PREVIEW_CLEANUP_CALLBACK = preview.PREVIEW_CLEANUP_CALLBACK;
const PREVIEW_HEARTBEAT_CALLBACK = preview.PREVIEW_HEARTBEAT_CALLBACK;
const PREVIEW_READBACK_HELPERS_SOKOL = preview.PREVIEW_READBACK_HELPERS_SOKOL;
const PREVIEW_READBACK_INIT_SOKOL = preview.PREVIEW_READBACK_INIT_SOKOL;
const PREVIEW_READBACK_FRAME_SOKOL = preview.PREVIEW_READBACK_FRAME_SOKOL;
const PREVIEW_READBACK_CLEANUP_SOKOL = preview.PREVIEW_READBACK_CLEANUP_SOKOL;
const PREVIEW_READBACK_HELPERS_SOKOL_D3D11 = preview.PREVIEW_READBACK_HELPERS_SOKOL_D3D11;
const PREVIEW_READBACK_HELPERS_METAL_SOKOL = preview.PREVIEW_READBACK_HELPERS_METAL_SOKOL;
const PREVIEW_READBACK_INIT_SOKOL_D3D11 = preview.PREVIEW_READBACK_INIT_SOKOL_D3D11;
const PREVIEW_READBACK_INIT_METAL_SOKOL = preview.PREVIEW_READBACK_INIT_METAL_SOKOL;
const PREVIEW_READBACK_FRAME_SOKOL_D3D11 = preview.PREVIEW_READBACK_FRAME_SOKOL_D3D11;
const PREVIEW_PRE_RENDER_METAL_SOKOL = preview.PREVIEW_PRE_RENDER_METAL_SOKOL;
const PREVIEW_READBACK_FRAME_METAL_SOKOL = preview.PREVIEW_READBACK_FRAME_METAL_SOKOL;
const PREVIEW_READBACK_CLEANUP_SOKOL_D3D11 = preview.PREVIEW_READBACK_CLEANUP_SOKOL_D3D11;
const PREVIEW_READBACK_CLEANUP_METAL_SOKOL = preview.PREVIEW_READBACK_CLEANUP_METAL_SOKOL;

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

    // Hook imports block
    //
    // The wasm32-emscripten panic-handler override (labelle-assembler#141)
    // is emitted at the top of this block so the two `pub const` root
    // declarations land near `const std = @import("std")` in the
    // generated `main.zig`. They MUST appear at module root for Zig to
    // honor them, and this block is rendered right after the stdlib
    // imports in `labelle-engine/codegen/main.zig.template`.
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (cfg.platform == .wasm) {
            try bw.writeAll(WASM_PANIC_WORKAROUND);
        }
        if (hook_names.len > 0) {
            try bw.writeAll("\n// --- Hook imports ---\n");
            for (hook_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print("const {s} = @import(\"hooks/{s}.zig\");\n", .{ ident, name });
            }
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("hook_imports_block", block);
    }

    // Event imports block
    //
    // Use the file basename (no path escape) as the import alias so the
    // alias matches the union variant name below, which in turn matches
    // the user's handler function name. Plugin events use `pathToIdent`
    // because plugin-namespaced names (`<plugin>__<event>`) need escapes
    // for path safety; in-tree game events do not — the basename is
    // already a valid Zig identifier (the user's handler references it).
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (event_names.len > 0) {
            try bw.writeAll("\n// --- Event imports ---\n");
            for (event_names) |name| {
                const ident = eventVariantName(name);
                try bw.print("const {s} = @import(\"events/{s}.zig\");\n", .{ ident, name });
            }
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("event_imports_block", block);
    }

    // Enum imports block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (enum_names.len > 0) {
            try bw.writeAll("\n// --- Enum imports ---\n");
            for (enum_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print("const {s} = @import(\"enums/{s}.zig\");\n", .{ ident, name });
            }
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("enum_imports_block", block);
    }

    // JSONC scene block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (jsonc_scene_names.len > 0 or prefab_names.len > 0) {
            try bw.writeAll("\n// --- JSONC scene loaders (embedded) ---\n");
            if (gizmo_names.len > 0) {
                try bw.writeAll("const JsoncBridge = engine.JsoncSceneBridgeWithGizmos(AssembledGame, Components, Gizmos);\n");
            } else {
                try bw.writeAll("const JsoncBridge = engine.JsoncSceneBridge(AssembledGame, Components);\n");
            }
            for (jsonc_scene_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print(
                    \\const jsonc_{s}_loader = struct {{
                    \\    const embedded_source = @embedFile("scenes/{s}.jsonc");
                    \\    fn load(game: *AssembledGame) anyerror!void {{
                    \\        return JsoncBridge.loadSceneFromSource(game, embedded_source, "prefabs");
                    \\    }}
                    \\}}.load;
                    \\
                    , .{ ident, name });
            }

            // ── Scene → assets map (Asset Streaming RFC, ticket #46) ────
            // Emit a comptime-visible struct that maps each scene's
            // assembler name to the `assets:` array declared at the top of
            // its .jsonc file. Empty arrays are emitted explicitly so the
            // labelle-engine consumer (issue #445) can iterate `entries`
            // without checking for missing keys. See also the upcoming
            // labelle-engine SceneEntry.assets field — this block is the
            // codegen contract that ticket reads.
            try ctx.writeSceneAssetManifests(bw, &ident_buf);

            // Same pattern for scene-declared `initial_state`
            // (labelle-engine#500) — emit only the scenes that opted in,
            // so the generated inline-for is a no-op for back-compat.
            try ctx.writeSceneInitialStateManifests(bw);
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("jsonc_scene_block", block);
    }

    // Game layers block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        try generateGameLayers(cfg.layers, bw);
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("game_layers_block", block);
    }

    // Resource registry block
    // Resource registry block — resources are now loaded at runtime via
    // @embedFile + loadAtlasFromMemory, so the comptime registry is empty.
    // The block is kept as an empty string for template compatibility.
    {
        const block = try allocator.dupe(u8, "");
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("resource_registry_block", block);
    }

    // AllHookPayloads block — merge engine payloads with game events
    // (`events/*.zig` scan, labelle-engine#422) and plugin events
    // (`pub const Events` on plugin modules, RFC-PLUGIN-EVENTS phase 1).
    // PluginEvents is always a union (possibly empty) when any plugin
    // exists, so it can sit inside the same `MergeHookPayloads` call —
    // game events stay on the same merged `AllHookPayloads` (no parallel
    // dispatcher, per RFC §2 "feed the existing pipeline").
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        // Gate on **discovered** events, not declared plugins — a project
        // can declare a plugin whose `Events` decl is empty (or absent, e.g.
        // the plugin-controllers demo plugin), in which case `PluginEvents`
        // is emitted as `void` and must NOT be folded into `GameEvents`
        // (`MergeHookPayloads` rejects `void` operands).
        const has_plugin_events = plugin_events.len > 0;
        // When plugins declare events, the assembler emits a widened
        // `GameEvents` that already folds in `PluginEvents` (see the
        // game_events_block emission below). So `AllHookPayloads` only
        // needs to merge `GameEvents` once — referencing `PluginEvents`
        // here too would re-emit every plugin variant twice and trip
        // `MergeHookPayloads`' duplicate-field check.
        if (event_names.len == 0 and !has_plugin_events) {
            try bw.writeAll("const AllHookPayloads = engine.HookPayload(EcsBackend.Entity);\n\n");
        } else {
            try bw.writeAll("const AllHookPayloads = engine.core.MergeHookPayloads(.{ engine.HookPayload(EcsBackend.Entity)");
            if (event_names.len > 0 or has_plugin_events) try bw.writeAll(", GameEvents");
            try bw.writeAll(" });\n\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("all_hook_payloads_block", block);
    }

    // Count + collect new-form flow handlers (RFC-PLUGIN-EVENTS phase 4,
    // labelle-assembler#175). flow-codegen emits `pub const FlowEventHandler`
    // for new-form `OnEvent` flows; flow_scanner flips
    // `ScriptEntry.has_event_handler` on those. We thread them into the
    // existing `GameHooks` receiver tuple — by default in the
    // scanner-sorted order `script_entries` arrives in
    // (numeric-prefix-then-alphabetical; `flow_scanner.zig:220-232`, O3
    // in the RFC).
    //
    // **Phase 7 layering (RFC-PLUGIN-EVENTS O4 / labelle-core#16).** A
    // flow listening to a consumable event sets `priority` in its
    // `.flow.jsonc`; `flow_scanner` lifts that onto
    // `ScriptEntry.event_priority`. Flows with a priority sort to the
    // front of the flow tail, priority descending; the rest stay on the
    // scanner sort. The runtime `MergeHooks.emit`
    // (`labelle-core/src/dispatcher.zig`) switches to the return-aware
    // path automatically when the variant's payload declares
    // `pub const consumable = true`, breaking the loop on the first
    // handler that returns `true` — so the highest-priority consumer
    // wins, which is the contract phase 7 promises.
    //
    // **Sort scope — whole flow tail, not per-event.** A single flow
    // handler struct currently subscribes to exactly one event (one
    // `OnEvent` per `.flow.jsonc`), but the assembler-side sort is
    // over the **whole flow tail**, not partitioned per event. The
    // reason: priority is only meaningful for consumable events, and a
    // notification handler's relative position in the tail doesn't
    // affect dispatch correctness (every notification listener runs
    // regardless of order). Front-loading the priority-set flows ahead
    // of notification flows is the simplest scope that satisfies the
    // consumable-flavor contract without re-keying the tuple by event
    // tag. If a future flow listens to multiple events (one consumable,
    // one notification, with different priorities each), the
    // single-priority shape no longer fits — that's the day a per-event
    // sort becomes load-bearing; not now.
    //
    // The handler module is referenced via an inline `@import("scripts/<rel_path>")`
    // because `AllScripts` (which holds these imports under stable
    // identifiers) is declared *after* `GameHooks` in the template
    // (`labelle-engine/codegen/main.zig.template:20` vs `:35`), so we
    // can't borrow the alias. Spelling the import inline keeps the
    // wiring local to these two blocks without adding a new template
    // slot ahead of `game_hooks_block`. An ident derived from `rel_path`
    // names the per-handler `var` declaration in `hooks_init_block`.
    var flow_handler_count: usize = 0;
    for (script_entries) |entry| {
        if (entry.has_event_handler) flow_handler_count += 1;
    }

    // Priority-aware ordering of the flow tail. The list holds indices
    // into `script_entries` for every entry with
    // `has_event_handler == true`, in the order the receiver tuple
    // must emit them: priority-set entries first (descending), then
    // the rest in scanner order. A stable sort on (priority bucket,
    // scanner index) keeps everything deterministic — the input is
    // already in scanner order, so the tie-breaker is just "preserve
    // relative position".
    var flow_order: std.ArrayList(usize) = .empty;
    defer flow_order.deinit(allocator);
    try flow_order.ensureTotalCapacity(allocator, flow_handler_count);
    for (script_entries, 0..) |entry, i| {
        if (entry.has_event_handler) flow_order.appendAssumeCapacity(i);
    }
    const FlowSortCtx = struct {
        entries: []const ScriptEntry,
        fn lessThan(self: @This(), a: usize, b: usize) bool {
            const ea = self.entries[a];
            const eb = self.entries[b];
            // Priority-set entries strictly precede priority-null
            // entries; among priority-set entries, higher value first.
            if (ea.event_priority != null and eb.event_priority == null) return true;
            if (ea.event_priority == null and eb.event_priority != null) return false;
            if (ea.event_priority) |pa| {
                if (eb.event_priority) |pb| {
                    if (pa != pb) return pa > pb;
                }
            }
            // Same bucket: preserve the input scanner-sort order.
            return a < b;
        }
    };
    std.mem.sort(usize, flow_order.items, FlowSortCtx{ .entries = script_entries }, FlowSortCtx.lessThan);

    // Game hooks block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (hook_names.len == 0 and flow_handler_count == 0) {
            try bw.writeAll("const GameHooks = struct {};\n\n");
        } else {
            var pascal_buf: [128]u8 = undefined;
            try bw.writeAll("const GameHooks = engine.MergeHooks(AllHookPayloads, .{");
            for (hook_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                const pascal = pathToPascal(name, &pascal_buf);
                try bw.print(" *{s}.{s},", .{ ident, pascal });
            }
            // Flow handler receiver types — appended after hooks so the
            // scanner sort (flows-among-flows) sits inside a single
            // tail block, leaving the existing hook order at the head
            // unchanged. `rel_path` is e.g. `flows/hit_counter.zig`,
            // matching the on-disk layout the `AllScripts` block already
            // imports. Iteration order is `flow_order` — priority-set
            // flows first (desc), then scanner-sorted notification flows.
            for (flow_order.items) |i| {
                const entry = script_entries[i];
                try bw.print(" *@import(\"scripts/{s}\").FlowEventHandler,", .{entry.rel_path});
            }
            try bw.writeAll(" });\n\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("game_hooks_block", block);
    }

    // Hooks init block — instantiate individual hooks and wire into GameHooks
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (hook_names.len == 0 and flow_handler_count == 0) {
            try bw.writeAll("    var hooks = GameHooks{};\n");
        } else {
            var pascal_buf: [128]u8 = undefined;
            for (hook_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                const pascal = pathToPascal(name, &pascal_buf);
                try bw.print("    var {s}_inst = {s}.{s}{{}};\n", .{ ident, ident, pascal });
            }
            // Materialise each flow handler so it has a stable address
            // the `&` operator can produce a pointer to. `pathToIdent`
            // makes the `rel_path` injective into the Zig identifier
            // namespace (issue #173), so multiple flows in subdirs
            // can't collide on the same `<ident>_flow_handler` name.
            // `setHooks` walks the receiver tuple and injects
            // `*AssembledGame` into `game_ptr` for every receiver that
            // declares such a field (`labelle-engine/src/game.zig:419-429`),
            // so no extra init step is needed here — the existing walk
            // reaches these entries the same way it does the hook ones.
            //
            // Note: the `var` decls below can be emitted in any order
            // (each one names a unique identifier) but we follow
            // `flow_order` for clean diff-readability — the `var`s
            // appear in the same order their `&` references will inside
            // the tuple literal.
            for (flow_order.items) |i| {
                const entry = script_entries[i];
                const ident = pathToIdent(entry.rel_path, &ident_buf);
                try bw.print(
                    "    var {s}_flow_handler: @import(\"scripts/{s}\").FlowEventHandler = .{{}};\n",
                    .{ ident, entry.rel_path },
                );
            }
            try bw.writeAll("    var hooks = GameHooks{ .receivers = .{");
            for (hook_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print(" &{s}_inst,", .{ident});
            }
            // The tuple-literal order MUST match the receiver-type
            // order in `GameHooks` above — `MergeHooks.emit` looks each
            // receiver up by its tuple position. Iterate `flow_order`
            // identically to the `game_hooks_block` loop.
            for (flow_order.items) |i| {
                const entry = script_entries[i];
                const ident = pathToIdent(entry.rel_path, &ident_buf);
                try bw.print(" &{s}_flow_handler,", .{ident});
            }
            try bw.writeAll(" } };\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("hooks_init_block", block);
    }

    // Game events + Plugin events block.
    //
    // `GameEvents` is the game-side scan of `events/*.zig`
    // (labelle-engine#422 — shipped). `PluginEvents` is the
    // plugin-side discovery added by RFC-PLUGIN-EVENTS phase 1: walks
    // every plugin module with `@hasDecl(plugin, "Events")` at
    // comptime — same convention as `Components`/`Systems`/
    // `GizmoCategories` — and folds each `pub const <name> = struct`
    // declaration into a single tagged union with plugin-qualified
    // variant names (`<plugin>__<event>`). `.` is not a valid Zig
    // identifier character, so the on-disk JSONC dot form
    // (`box2d.collision_begin`) resolves to the qualified tag
    // (`box2d__collision_begin`) when flow-codegen consumes this in
    // phase 3.
    //
    // Both decls are `pub` so flow-codegen-emitted hook handler
    // structs (phase 3) can reference them by name via the existing
    // module-level import path. The resolver is the comptime
    // reflection itself (option (a) — generated comptime decl rather
    // than a JSON sidecar): `@FieldType(PluginEvents, "<tag>")` and
    // `@typeInfo(...).@"struct".fields` give the payload field list
    // without a separate registry file to keep in sync.
    //
    // **Phase 3 widening:** the engine's `Game.emit(event: GameEvents)`
    // accepts a single union type, but plugins (RFC-PLUGIN-EVENTS phase
    // 2, e.g. labelle-box2d 6c44691) now `game.emit(.{ .box2d__... = .{...} })`.
    // So when plugins declare events, `GameEvents` is **widened** to the
    // union of the game-side scan and `PluginEvents` — emitted via
    // `pub const GameEvents = engine.core.MergeHookPayloads(.{ GameEventsRaw, PluginEvents })`
    // — and `GameConfig(..., GameEvents)` (the existing engine template
    // slot, unchanged) now sees the merged type. The raw game-side scan
    // is kept under a private alias `GameEventsRaw` so the merge has a
    // stable second operand even when `events/*.zig` is empty.
    //
    // No engine template change required: the `GameEvents,` token in
    // `codegen/main.zig.template` keeps its v1 shape; only the
    // **meaning** of `GameEvents` widens when plugins declare events.
    // Every project without plugin events keeps the v1 semantics
    // verbatim — `GameEvents` is either `void` or the events/*.zig
    // union.
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;

        // Gate on **discovered** plugin events, not declared plugins —
        // a project can declare a plugin whose `Events` is empty/absent
        // (e.g. the plugin-controllers demo plugin), and in that case
        // we want the v1 emission shape verbatim ("no plugin events"),
        // not a `GameEvents = PluginEvents = void` path that would
        // confuse downstream consumers.
        const has_plugin_events_local = plugin_events.len > 0;
        const has_game_events_local = event_names.len > 0;

        // The raw game-side scan keeps its v1 shape; the alias is what
        // the merge feeds on when plugins are also in play. For
        // plugin-less projects with no game events, `GameEventsRaw` is
        // omitted and `GameEvents = void` is emitted directly (the
        // pre-RFC shape every shipped game already has).
        if (has_plugin_events_local) {
            // Need a name for the raw events to feed into the merge.
            // Without game events, the alias is `void` and we end up
            // with `GameEvents = PluginEvents` directly (skipping the
            // merge — `MergeHookPayloads` rejects `void`).
            if (has_game_events_local) {
                try bw.writeAll("pub const GameEventsRaw = union(enum) {\n");
                var pascal_buf: [128]u8 = undefined;
                for (event_names) |name| {
                    const ident = eventVariantName(name);
                    const pascal = pathToPascal(name, &pascal_buf);
                    try bw.print("    {s}: {s}.{s},\n", .{ ident, ident, pascal });
                }
                try bw.writeAll("};\n\n");
            }
            try ctx.writePluginEventsBlock(bw);
            if (has_game_events_local) {
                try bw.writeAll("pub const GameEvents = engine.core.MergeHookPayloads(.{ GameEventsRaw, PluginEvents });\n\n");
            } else {
                try bw.writeAll("pub const GameEvents = PluginEvents;\n\n");
            }
        } else {
            // No plugins — the v1 emission verbatim, every shipped
            // pre-RFC game keeps its exact shape.
            if (has_game_events_local) {
                try bw.writeAll("pub const GameEvents = union(enum) {\n");
                var pascal_buf: [128]u8 = undefined;
                for (event_names) |name| {
                    const ident = eventVariantName(name);
                    const pascal = pathToPascal(name, &pascal_buf);
                    try bw.print("    {s}: {s}.{s},\n", .{ ident, ident, pascal });
                }
                try bw.writeAll("};\n\n");
            } else {
                try bw.writeAll("pub const GameEvents = void;\n\n");
            }
        }

        // RFC-FLOW-VOCABULARY phase 2 — emit the PluginFlowNodes and
        // PluginPinStyles registries inside the same generated block so
        // the engine template stays unchanged. Both decls are always
        // emitted (empty `struct {}` when discovery found nothing) so
        // downstream consumers can do uniform reflection. See the
        // file header on `writePluginFlowNodesBlock` for the
        // mechanism + RFC §5 (game-script-as-source) for the scope.
        try ctx.writePluginFlowNodesBlock(bw);
        const deduped_styles = try dedupePinStyles(allocator, plugin_pin_styles);
        defer allocator.free(deduped_styles);
        try ctx.writePluginPinStylesBlock(bw, deduped_styles);
        // RFC-FLOW-VOCABULARY §2 / O4 — emit PluginCoercions next to
        // the other registries. The block carries its own `resolve` +
        // `findByTypes` helpers so flow-codegen + the editor can do
        // the wire-fit lookup without re-iterating the decls.
        try ctx.writePluginCoercionsBlock(bw);

        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("game_events_block", block);
    }

    // Prefab registry block — JSONC prefabs are loaded at runtime via
    // addEmbeddedPrefab, so the comptime registry is always empty.
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        try bw.writeAll("const Prefabs = engine.PrefabRegistry(.{});\n\n");
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("prefab_registry_block", block);
    }

    // Component registry block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        const has_plugins = cfg.plugins.len > 0;
        if (has_plugins) {
            try bw.writeAll("const Components = engine.ComponentRegistryWithPlugins(.{\n");
        } else {
            try bw.writeAll("const Components = engine.ComponentRegistry(.{\n");
        }
        var pascal_buf: [128]u8 = undefined;
        for (component_names) |name| {
            const pascal = pathToPascal(name, &pascal_buf);
            try bw.print("    .{s} = @import(\"components/{s}.zig\").{s},\n", .{ pascal, name, pascal });
        }
        if (has_plugins) {
            try bw.writeAll("}, .{\n");
            try bw.writeAll("    @import(\"labelle-gfx\"),\n");
            for (cfg.plugins) |plugin| {
                try bw.print("    @import(\"{s}\"),\n", .{plugin.name});
            }
            try bw.writeAll("});\n\n");
        } else {
            try bw.writeAll("});\n\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("component_registry_block", block);
    }

    // System registry block + Plugin controllers block (appended into the
    // same scalar so it slots into existing `{{system_registry_block}}`
    // placeholder in main.zig.template without needing a template update).
    //
    // The Plugin controllers scaffolding discovers `pub const Controller` in
    // each plugin root module at comptime and emits a `setup` / `deinit`
    // dispatcher the generated main calls on scene load / unload.
    // Backward-compatible: plugins without a Controller export are silently
    // skipped by the `@hasDecl` guard, so no runtime cost and no
    // generate-time opt-in needed.
    //
    // See flying-platform-labelle#208 (RFC: Plugin-Exported Controllers) §1–§2.
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (cfg.plugins.len > 0) {
            try bw.writeAll("const PluginSystems = engine.SystemRegistry(.{\n");
            try bw.writeAll("    @import(\"labelle-gfx\"),\n");
            for (cfg.plugins) |plugin| {
                try bw.print("    @import(\"{s}\"),\n", .{plugin.name});
            }
            try bw.writeAll("});\n\n");
            try bw.writeAll("const DiscoveredGizmoCategories = PluginSystems.gizmoCategories();\n\n");

            try ctx.writePluginControllersBlock(bw);
        } else {
            try bw.writeAll("const GizmoCatEntry = struct { name: []const u8, id: u8 };\n");
            try bw.writeAll("const DiscoveredGizmoCategories: []const GizmoCatEntry = &.{};\n\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("system_registry_block", block);
    }

    // All scripts block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        try bw.writeAll("const AllScripts = struct {\n");
        for (script_entries) |entry| {
            if (std.mem.eql(u8, entry.name, "context")) continue;
            const ident = pathToIdent(entry.rel_path, &ident_buf);
            // labelle-assembler#240 Gap 2 — a game script that exports
            // `pub const FlowNodes` is promoted to a NAMED build module
            // (it's also reached by the `game` shim's `PluginFlowNodes`).
            // It MUST be `@import("script__<sanitized>")` here, not
            // `@import("scripts/<rel>")`, or the file lands in both the
            // root module (this block) and the `game` module → the
            // "file exists in modules 'root' and 'game'" error. The
            // sanitized prefix is byte-identical to `ident` because both
            // are `pathToIdent(rel_path)`, matching
            // `scan.promotedScriptModuleName`. Scripts without FlowNodes
            // keep the path import.
            const is_promoted = isFlowNodeScript(plugin_flow_nodes, ident);
            // Buffer the named module name so the import expr below is a
            // single `{s}` regardless of promotion. `script__` + `ident`.
            var named_buf: [256 + "script__".len]u8 = undefined;
            const import_target: []const u8 = if (is_promoted)
                std.fmt.bufPrint(&named_buf, "script__{s}", .{ident}) catch return error.NameTooLong
            else
                entry.rel_path;
            const import_prefix: []const u8 = if (is_promoted) "" else "scripts/";
            if (entry.states.len == 0) {
                try bw.print("    pub const {s} = @import(\"{s}{s}\");\n", .{ ident, import_prefix, import_target });
            } else {
                try bw.print("    pub const {s} = struct {{\n", .{ident});
                try bw.print("        const _inner = @import(\"{s}{s}\");\n", .{ import_prefix, import_target });
                try bw.writeAll("        pub const game_states = .{\n");
                for (entry.states) |state| {
                    try bw.print("            \"{s}\",\n", .{state});
                }
                try bw.writeAll("        };\n");
                const decl_names = [_][]const u8{ "tick", "setup", "drawGui", "State" };
                for (decl_names) |decl| {
                    try bw.print("        pub const {s} = if (@hasDecl(_inner, \"{s}\")) _inner.{s} else {{}};\n", .{ decl, decl, decl });
                }
                try bw.writeAll("    };\n");
            }
        }
        try bw.writeAll("};\n\n");
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("all_scripts_block", block);
    }

    // View registry block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (view_names.len > 0) {
            try bw.writeAll("const Views = engine.ViewRegistry(.{\n");
            for (view_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print("    .{s} = @import(\"views/{s}.zon\"),\n", .{ ident, name });
            }
            try bw.writeAll("});\n\n");
        } else {
            try bw.writeAll("const Views = engine.EmptyViewRegistry;\n\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("view_registry_block", block);
    }

    // Gizmo registry block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (gizmo_names.len > 0) {
            try bw.writeAll("const Gizmos = engine.GizmoRegistry(.{\n");
            for (gizmo_names) |name| {
                const ident = pathToIdent(name, &ident_buf);
                try bw.print("    .{s} = @import(\"gizmos/{s}.zon\"),\n", .{ ident, name });
            }
            try bw.writeAll("});\n\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("gizmo_registry_block", block);
    }

    // Animation registry block
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;
        if (animation_names.len > 0) {
            var anim_pascal_buf: [128]u8 = undefined;
            for (animation_names) |name| {
                const pascal = pathToPascal(name, &anim_pascal_buf);
                try bw.print("const {s}Anim = engine.AnimationDef(@import(\"animations/{s}.zon\"));\n", .{ pascal, name });
            }
            try bw.writeAll("\n");
        }
        var arr_list_b = alloc_writer_b.toArrayList();
        const block = try arr_list_b.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(block);
        try data.scalars.put("animation_registry_block", block);
    }

    // ── Lifecycle section (rendered from backend template, same as procedural path) ──
    {
        var alloc_writer_b: std.Io.Writer.Allocating = .init(allocator);
        errdefer alloc_writer_b.deinit();
        const bw = &alloc_writer_b.writer;

        const tick_code = if (cfg.plugins.len > 0)
            "        const scaled_dt = dt * g.time_scale;\n" ++
            "        if (scaled_dt > 0) {\n" ++
            "            runner.tick(&g, scaled_dt);\n" ++
            "            PluginSystems.tick(&g, scaled_dt);\n" ++
            "            PluginSystems.postTick(&g, scaled_dt);\n" ++
            "        }\n" ++
            "        g.dispatchEvents();\n" ++
            "        // Update profiling pointers (debug only)\n" ++
            "        if (comptime @TypeOf(runner).profiling_enabled) {\n" ++
            "            g.script_profile_ptr = @ptrCast(@alignCast(&runner.profile));\n" ++
            "            g.script_profile_count = @TypeOf(runner).script_count;\n" ++
            "        }\n" ++
            "        if (comptime PluginSystems.profiling_enabled) {\n" ++
            "            g.plugin_profile_ptr = @ptrCast(@alignCast(&PluginSystems.plugin_profile));\n" ++
            "            g.plugin_profile_count = PluginSystems.plugin_system_count;\n" ++
            "        }\n"
        else
            "        const scaled_dt = dt * g.time_scale;\n" ++
            "        if (scaled_dt > 0) {\n" ++
            "            runner.tick(&g, scaled_dt);\n" ++
            "        }\n" ++
            "        g.dispatchEvents();\n" ++
            "        if (comptime @TypeOf(runner).profiling_enabled) {\n" ++
            "            g.script_profile_ptr = @ptrCast(@alignCast(&runner.profile));\n" ++
            "            g.script_profile_count = @TypeOf(runner).script_count;\n" ++
            "        }\n";

        const gui_draw_code = try ctx.buildGuiDrawCode();
        defer allocator.free(gui_draw_code);

        var w_buf: [16]u8 = undefined;
        var h_buf: [16]u8 = undefined;
        var fps_buf: [16]u8 = undefined;
        const w_str = std.fmt.bufPrint(&w_buf, "{d}", .{cfg.width}) catch unreachable;
        const h_str = std.fmt.bufPrint(&h_buf, "{d}", .{cfg.height}) catch unreachable;
        const fps_str = std.fmt.bufPrint(&fps_buf, "{d}", .{cfg.target_fps}) catch unreachable;

        const hidden_setup: []const u8 = if (cfg.hidden)
            "    window.setConfigFlags(.{ .window_hidden = true });\n"
        else
            "";

        const hooks_init = data.scalars.get("hooks_init_block") orelse "    var hooks = GameHooks{};\n";

        // bgfx-on-Android (#303) inverts its desktop loop into the same
        // init/frame callback shape sokol/wasm use: the NativeActivity
        // shell (`backends/bgfx/src/android_app.zig`) owns the event+frame
        // loop and calls back into the game per-frame. So it shares the
        // callback-lifecycle path (module-scope `g`/`runner`, void-safe
        // `init_code` via `buildCallbackInitCode`) rather than the
        // procedural loop path the bgfx DESKTOP template uses.
        const is_bgfx_android = cfg.backend == .bgfx and cfg.platform == .android;
        const use_callback_lifecycle = cfg.backend == .sokol or cfg.platform == .wasm or is_bgfx_android;

        if (use_callback_lifecycle) {
            // Module-scope `runner` decl — needed by every callback-path
            // backend whose `init_code` ASSIGNS `runner = Runner.init(...)`
            // (sokol mobile/desktop and bgfx-android both split init from
            // the per-frame tick, so the runner can't be an init-scope
            // local like the loop path). Raylib-wasm takes the `else`
            // branch below and declares its own runner inside `main()`.
            const callback_runner: []const u8 = if (cfg.backend == .sokol or is_bgfx_android) "var runner: Runner = undefined;\n" else "";
            // Sokol-backend builds get ALL THREE readback helper blocks
            // emitted side-by-side:
            //   - GL PBO ring (labelle-assembler#122 slice 1, #124) —
            //     fires on Linux/Android via `_sokol_preview_gl_enabled`.
            //   - D3D11 staging-texture ring (labelle-assembler#126,
            //     slice 2 of #122) — fires on Windows via
            //     `_sokol_preview_d3d11_enabled`.
            //   - Metal/IOSurface ring (labelle-assembler#125, slice 3
            //     of #122) — fires on macOS/iOS via
            //     `_sokol_preview_metal_enabled`.
            // The three gates are mutually exclusive (Linux vs Windows
            // vs Darwin), so only one block's runtime code path is
            // reachable per target. The `else struct {}` branches in
            // each helper namespace keep unresolved-symbol references
            // off the link line on the inactive targets.
            // Emit-unconditional for `cfg.backend == .sokol` keeps the
            // generated source uniform across desktop / mobile
            // templates; wasm routes through the raylib branch below
            // and stays out of all three readback paths for now.
            const sokol_readback_helpers: []const u8 = if (cfg.backend == .sokol)
                try std.mem.concat(allocator, u8, &.{
                    PREVIEW_READBACK_HELPERS_SOKOL,
                    PREVIEW_READBACK_HELPERS_SOKOL_D3D11,
                    PREVIEW_READBACK_HELPERS_METAL_SOKOL,
                })
            else
                "";
            defer if (cfg.backend == .sokol) allocator.free(sokol_readback_helpers);
            // PREVIEW_INPUT_DISPATCH emits `extern fn imgui_bridge_mouse_*`
            // symbols, which only exist when the gui plugin is imgui. Gate
            // narrowly on plugin name — other gui plugins (clay, simple-raylib,
            // simple-sokol, …) would link-fail on these externs. The stub
            // variant provides safe no-ops for those projects.
            const input_dispatch_cb: []const u8 = if (cfg.resolved_gui) |gui|
                (if (std.mem.eql(u8, gui.name, "imgui")) PREVIEW_INPUT_DISPATCH else PREVIEW_INPUT_DISPATCH_STUB)
            else
                PREVIEW_INPUT_DISPATCH_STUB;
            const module_vars = try std.mem.concat(allocator, u8, &.{ callback_runner, PREVIEW_HELPERS, sokol_readback_helpers, input_dispatch_cb });
            defer allocator.free(module_vars);
            const init_code = try ctx.buildCallbackInitCode();
            defer allocator.free(init_code);

            const platform_comment: []const u8 = if (is_bgfx_android)
                "Android: the bgfx NativeActivity shell (android_app.zig) drives the lifecycle"
            else switch (cfg.platform) {
                .ios => "iOS: sokol bindings accessed through engine.sokol (no direct sokol import)",
                .android => "Android: sokol handles the app lifecycle via NativeActivity",
                .wasm => "WASM: Emscripten drives the main loop via callbacks",
                .desktop => "",
            };
            const entry_comment: []const u8 = if (is_bgfx_android)
                "Android entry — the game owns android_main; the bgfx shell runs the loop"
            else switch (cfg.platform) {
                .ios => "iOS entry — no main(), sokol handles the app lifecycle",
                .android => "Android entry — no main(), sokol handles the NativeActivity lifecycle",
                .wasm => "WASM entry — Emscripten drives the main loop via callbacks",
                .desktop => "",
            };

            if (cfg.backend == .sokol) {
                const cleanup_code = try ctx.buildCallbackCleanupCode();
                defer allocator.free(cleanup_code);
                const is_wasm = cfg.platform == .wasm;
                const allocator_decl: []const u8 = if (is_wasm)
                    "// Use c_allocator for Emscripten — delegates to emscripten's malloc/free\n// which respects ALLOW_MEMORY_GROWTH. GPA is incompatible with wasm32-emscripten.\nconst allocator = std.heap.c_allocator;"
                else
                    "var gpa = std.heap.DebugAllocator(.{}).init;";
                const allocator_expr: []const u8 = if (is_wasm) "std.heap.c_allocator" else "gpa.allocator()";
                const allocator_cleanup: []const u8 = if (is_wasm) "" else "    _ = gpa.deinit();\n";
                // For wasm, `allocator` is already declared at module scope
                // by `{{allocator_decl}}` above, so re-declaring it inside
                // `initInner` would trigger Zig's "local constant shadows
                // declaration" error (labelle-cli#198). For desktop, the
                // module scope only has `var gpa = ...`, so we still need
                // the inner alias.
                const allocator_local_decl: []const u8 = if (is_wasm) "" else "    const allocator = gpa.allocator();\n";

                // Wire the GUI bridge into sokol's event callback so widgets
                // see mouse / keyboard input. labelle-imgui's sokol bridge
                // exports `imgui_bridge_handle_event` for exactly this — when
                // a GUI plugin is configured we forward each event to it.
                // Without this hook simgui's IO state stays empty and ImGui
                // buttons/sliders never respond.
                const gui_event_extern: []const u8 = if (cfg.hasGui())
                    "extern fn imgui_bridge_handle_event(ev: [*c]const @import(\"backend_input\").Event) bool;\n\n"
                else
                    "";
                const gui_event_forward: []const u8 = if (cfg.hasGui())
                    "    _ = imgui_bridge_handle_event(ev);\n"
                else
                    "";

                // Readback hookups (labelle-assembler#122). Each
                // lifecycle slot gets ALL THREE backend variants
                // concatenated (GL slice 1 #124, D3D11 slice 2 #126,
                // Metal slice 3 #125):
                //   - init   : stash the allocator into the module-scope
                //              slot (idempotent across the three gates —
                //              exactly one branch fires per target)
                //   - frame  : pre-endFrame slot carries GL + D3D11
                //              (both rely on a flush-on-read primitive
                //              that's safe before `sg.commit()`); the
                //              Metal block runs in the post-endFrame
                //              slot because Metal needs `sg.commit()`
                //              to land the swapchain texture before our
                //              own command buffer can read it.
                //   - cleanup: endFrameStream + ring teardown for each,
                //              then the graceful `bye`. Buffer free
                //              guarded so the inactive blocks are
                //              no-ops.
                // The three paths evaporate on the non-matching OS via
                // their `_sokol_preview_{gl,d3d11,metal}_enabled` flags.
                //
                // Wasm-emscripten gate (labelle-assembler#141): preview
                // mode is useless in a browser tab (no `LABELLE_PREVIEW`
                // env, no TCP socket out), and `std.Io.Threaded.init` +
                // `.io()` instantiates the vtable that references
                // `childWaitPosix` → triggers the Zig 0.16
                // `Threaded.zig:15315` / `emscripten.zig:215` enum
                // mismatches. Emit empty strings for the preview slots
                // on wasm so the generated `main.zig` never references
                // `std.Io.Threaded`. See ziglang/zig#31849 + PR #31850
                // for the upstream fix; this is the workaround for now.
                const preview_setup_sokol = if (is_wasm)
                    try allocator.dupe(u8, "")
                else
                    try std.mem.concat(allocator, u8, &.{
                        PREVIEW_INIT_CALLBACK,
                        PREVIEW_READBACK_INIT_SOKOL,
                        PREVIEW_READBACK_INIT_SOKOL_D3D11,
                        PREVIEW_READBACK_INIT_METAL_SOKOL,
                    });
                defer allocator.free(preview_setup_sokol);
                // Wasm-emscripten gate (labelle-assembler#141, same
                // rationale as `preview_setup_sokol` above). Heartbeat
                // + readback + cleanup all touch `g.preview`'s public
                // methods, and Zig's lazy compilation may still pull
                // the `popInputEvent` / `tickHeartbeat` codepaths into
                // the wasm exe even when `g.preview` is statically
                // null. Emit empty strings so the generated `main.zig`
                // never references Preview's IO surface on wasm.
                const preview_readback_sokol = if (is_wasm)
                    try allocator.dupe(u8, "")
                else
                    try std.mem.concat(allocator, u8, &.{
                        PREVIEW_READBACK_FRAME_SOKOL,
                        PREVIEW_READBACK_FRAME_SOKOL_D3D11,
                        // Path A (#131): the Metal block no longer depends
                        // on a swapchain drawable, so it can run in the
                        // pre-endFrame slot alongside GL / D3D11. The
                        // `{{preview_readback_post}}` template hole gets
                        // an empty string below — kept in the template so
                        // existing test scaffolding still expands cleanly,
                        // but no longer carries any Metal payload.
                        PREVIEW_READBACK_FRAME_METAL_SOKOL,
                    });
                defer allocator.free(preview_readback_sokol);
                const preview_cleanup_sokol = if (is_wasm)
                    try allocator.dupe(u8, "")
                else
                    try std.mem.concat(allocator, u8, &.{
                        PREVIEW_READBACK_CLEANUP_SOKOL,
                        PREVIEW_READBACK_CLEANUP_SOKOL_D3D11,
                        PREVIEW_READBACK_CLEANUP_METAL_SOKOL,
                        PREVIEW_CLEANUP_CALLBACK,
                    });
                defer allocator.free(preview_cleanup_sokol);
                const preview_heartbeat_sokol: []const u8 = if (is_wasm) "" else PREVIEW_HEARTBEAT_CALLBACK;

                // `{{immersive_entry}}` — Android immersive-mode call,
                // emitted into `sokol_main()` (UI thread, pre-callback
                // registration) so the bars are hidden at launch. Empty
                // for non-Android / non-immersive projects; the shared
                // sokol `desktop.txt` has no such hole, so an empty
                // value there is a harmless no-op.
                const immersive_entry = try ctx.buildImmersiveEntryCode();
                defer allocator.free(immersive_entry);

                try tpl.render(lifecycle_tmpl, .{
                    .module_vars = module_vars,
                    .width = w_str,
                    .height = h_str,
                    .title = cfg.title,
                    .fps = fps_str,
                    .init_code = init_code,
                    .tick_code = tick_code,
                    .gui_draw_code = gui_draw_code,
                    .gui_event_extern = gui_event_extern,
                    .gui_event_forward = gui_event_forward,
                    .cleanup_code = cleanup_code,
                    .platform_comment = platform_comment,
                    .entry_comment = entry_comment,
                    .hidden_setup = hidden_setup,
                    .hooks_init_block = hooks_init,
                    .allocator_decl = allocator_decl,
                    .allocator_expr = allocator_expr,
                    .allocator_local_decl = allocator_local_decl,
                    .allocator_cleanup = allocator_cleanup,
                    // Preview-mode wiring (labelle-assembler#94,
                    // labelle-engine#520). `g.preview` is the canonical
                    // storage; init dials + assigns + seeds the PBO
                    // allocator, frame heartbeats + reads back pixels,
                    // cleanup tears down PBO state then emits the
                    // graceful `bye`, and `g.deinit` owns the socket +
                    // arena teardown.
                    .preview_setup = preview_setup_sokol,
                    .preview_heartbeat = preview_heartbeat_sokol,
                    // Path A render-target wiring (#133) — fires BEFORE
                    // `window.beginFrame()` so the swapchain-vs-offscreen
                    // decision is made before sokol-gfx commits to either.
                    // Empty under non-Darwin targets (the block is
                    // comptime-gated on `_sokol_preview_metal_enabled`).
                    // GL (#124) and D3D11 (#126) keep their existing
                    // pre-endFrame slot — their readback model is a
                    // post-commit copy, not a render redirect.
                    .preview_pre_render = PREVIEW_PRE_RENDER_METAL_SOKOL,
                    .preview_readback = preview_readback_sokol,
                    // Path A (#131): the Metal block is part of the
                    // pre-endFrame readback now, so the post-endFrame
                    // hole is empty. Kept in the template so the
                    // placeholder still expands cleanly; retiring it
                    // entirely is a separate cleanup step.
                    .preview_readback_post = "",
                    .preview_cleanup = preview_cleanup_sokol,
                    .immersive_entry = immersive_entry,
                }, bw);
            } else if (is_bgfx_android) {
                // bgfx-on-Android (#303): the generated game owns
                // `android_main` and registers an init + frame callback
                // with the bgfx NativeActivity shell, which drives the
                // event/frame loop. Holes mirror `backends/bgfx/templates/
                // android.txt`. `init_code` comes from the callback builder
                // (void-safe — the shell's callback is `callconv(.c) void`,
                // no error channel), `tick_code` is the shared engine-tick
                // block, and the preview-mode readback slots are empty:
                // bgfx has no on-device preview path yet (its desktop
                // readback is a separate, unshipped ticket like sdl/wgpu).
                try tpl.render(lifecycle_tmpl, .{
                    .module_vars = module_vars,
                    .width = w_str,
                    .height = h_str,
                    .title = cfg.title,
                    .fps = fps_str,
                    .init_code = init_code,
                    .tick_code = tick_code,
                    .gui_draw_code = gui_draw_code,
                    .hooks_init_block = hooks_init,
                    .platform_comment = platform_comment,
                    .entry_comment = entry_comment,
                    .preview_setup = "",
                    .preview_heartbeat = "",
                }, bw);
            } else {
                // Raylib wasm: emscripten-driven callback loop. Preview
                // setup runs once in main() before the loop is handed
                // to emscripten; heartbeats fire inside `gameFrame`.
                // No cleanup callback — emscripten keeps running after
                // main returns, and the editor reads EOF on tab close.
                //
                // Wasm-emscripten gate (labelle-assembler#141): preview
                // mode is useless in a browser tab, and the explicit
                // `std.Io.Threaded.init` in PREVIEW_INIT_CALLBACK pulls
                // the broken Zig 0.16 posix wrappers into the wasm exe
                // (Threaded.zig:15315 / emscripten.zig:215). Emit empty
                // strings on wasm. Both branches of this `if/else` land
                // on wasm in practice, but keep the gate explicit so
                // the intent is local.
                const is_wasm_raylib = cfg.platform == .wasm;
                try tpl.render(lifecycle_tmpl, .{
                    .width = w_str,
                    .height = h_str,
                    .title = cfg.title,
                    .fps = fps_str,
                    .setup_code = init_code,
                    .tick_code = tick_code,
                    .gui_draw_code = gui_draw_code,
                    .hidden_setup = hidden_setup,
                    .hooks_init_block = hooks_init,
                    .preview_setup = if (is_wasm_raylib) "" else PREVIEW_INIT_CALLBACK,
                    .preview_heartbeat = if (is_wasm_raylib) "" else PREVIEW_HEARTBEAT_CALLBACK,
                }, bw);
            }
        } else {
            const setup_code = try ctx.buildSetupCode();
            defer allocator.free(setup_code);

            // Raylib desktop gets the PBO async-readback block + the GL
            // externs that drive it (labelle-engine#544). The PoC at
            // imgui-preview-poc/src/game.zig is the reference shape.
            // Other loop backends (sdl/bgfx/wgpu) keep an empty readback
            // slot until their per-backend tickets land — sokol's readback
            // already runs through its own callback path. raylib WASM
            // takes the callback branch above, so this only fires for
            // raylib desktop.
            const is_raylib_desktop = cfg.backend == .raylib;
            // Preview mouse-input forwarding is sokol-only: the
            // `imgui_bridge_mouse_*` externs `PREVIEW_INPUT_DISPATCH`
            // declares are exported solely by the *sokol* imgui bridge
            // (`bridges/sokol`). The raylib imgui bridge (`bridges/raylib`,
            // rlImGui) does NOT export them — rlImGui reads raylib's own
            // input each frame — so a raylib+imgui build that emitted the
            // imgui dispatch failed to link with
            // `undefined symbol: _imgui_bridge_mouse_button`. This loop
            // lifecycle path is reached by raylib desktop (and other loop
            // backends), so it must always take the STUB; the imgui
            // dispatch lives on the sokol-callback site above.
            const input_dispatch: []const u8 = PREVIEW_INPUT_DISPATCH_STUB;
            const module_vars_loop = if (is_raylib_desktop)
                try std.mem.concat(allocator, u8, &.{ PREVIEW_HELPERS, PREVIEW_READBACK_HELPERS, input_dispatch })
            else
                try std.mem.concat(allocator, u8, &.{ PREVIEW_HELPERS, input_dispatch });
            defer allocator.free(module_vars_loop);
            const preview_setup_loop = if (is_raylib_desktop)
                try std.mem.concat(allocator, u8, &.{ PREVIEW_LOOP_SETUP, PREVIEW_READBACK_SETUP })
            else
                PREVIEW_LOOP_SETUP;
            defer if (is_raylib_desktop) allocator.free(preview_setup_loop);
            const readback_block = if (is_raylib_desktop) PREVIEW_READBACK_LOOP else "";

            try tpl.render(lifecycle_tmpl, .{
                .width = w_str,
                .height = h_str,
                .title = cfg.title,
                .fps = fps_str,
                .setup_code = setup_code,
                .tick_code = tick_code,
                .gui_draw_code = gui_draw_code,
                .hidden_setup = hidden_setup,
                .hooks_init_block = hooks_init,
                .module_vars = module_vars_loop,
                // Preview-mode wiring (labelle-assembler#94). Always
                // emitted; runtime parse returns null when the flag is
                // absent so the block is a no-op for non-preview runs.
                .preview_setup = preview_setup_loop,
                .preview_heartbeat = PREVIEW_HEARTBEAT_LOOP,
                .preview_readback = readback_block,
            }, bw);
        }

        var arr_list_l = alloc_writer_b.toArrayList();
        const lifecycle = try arr_list_l.toOwnedSlice(allocator);
        allocs.appendAssumeCapacity(lifecycle);
        try data.scalars.put("lifecycle", lifecycle);
    }

    // ── Render the engine template ──
    var output_alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer output_alloc_writer.deinit();
    try tpl.renderDynamic(engine_template, data, &output_alloc_writer.writer);
    var output_arr_list = output_alloc_writer.toArrayList();
    return output_arr_list.toOwnedSlice(allocator);
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
