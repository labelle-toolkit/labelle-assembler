//! Hook-pipeline blocks for the generated `main.zig`:
//! `AllHookPayloads`, `GameHooks`, and the `hooks_init` body.
//!
//! Extracted from `main_template.zig`'s orchestrator (labelle-assembler
//! file-size refactor) following the `blocks/*.zig` mixin pattern.
//!
//! These three blocks share the priority-aware flow-handler ordering
//! (`flow_order`, RFC-PLUGIN-EVENTS phase 4/7). The orchestrator builds
//! that order once via `buildFlowOrder` (so it owns the backing
//! `ArrayList`'s lifetime / `deinit`) and threads the resulting index
//! slice into `writeGameHooksBlock` + `writeHooksInitBlock`. The
//! `AllHookPayloads` writer needs neither, only the event gates.
//!
//! Reads `event_names`, `hook_names`, `script_entries`, `plugin_events`
//! from `self`; pure emit, no allocations beyond the caller's writer
//! (the flow-order array is the orchestrator's).

const std = @import("std");
const idents = @import("../idents.zig");
const scan = @import("../scan.zig");
const pack_root = @import("../pack_root.zig");
const script_scanner = @import("../../script_scanner.zig");

const pathToIdent = scan.pathToIdent;
const eventVariantName = idents.eventVariantName;
const pathToPascal = idents.pathToPascal;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;

/// Write the import expression that reaches a flow-handler script's
/// module: `@import("scripts/<rel>")` for game/plugin scripts, or the
/// pack MODULE's re-export (`@import("pack__<pfx>").scripts.<rel_ident>`)
/// for pack entries (`import_base == ""`, #498 PR 2 — pack files belong
/// to the pack module, so the old `@import("scripts/packs/…")` form was
/// both a wrong path AND a dual-module error). Shared by the
/// `GameHooks` receiver-type tuple and the `hooks_init` materialisation
/// so the two can never disagree on where a handler lives.
fn printFlowHandlerImport(w: anytype, entry: ScriptEntry) !void {
    if (entry.import_base.len == 0) {
        const pack_name = entry.plugin_name orelse return error.NameTooLong;
        var pfx_buf: [128]u8 = undefined;
        const pfx = scan.packNamespacePrefix(pack_name, &pfx_buf);
        var rel_ident_buf: [256]u8 = undefined;
        const rel_ident = pathToIdent(pack_root.packRelScriptPath(entry.rel_path, pack_name), &rel_ident_buf);
        try w.print("@import(\"pack__{s}\").scripts.{s}", .{ pfx, rel_ident });
    } else {
        try w.print("@import(\"scripts/{s}\")", .{entry.rel_path});
    }
}

/// Build the priority-aware ordering of the flow tail. Returns an
/// `ArrayList(usize)` holding indices into `script_entries` for every
/// entry with `has_event_handler == true`, in the order the receiver
/// tuple must emit them: priority-set entries first (descending), then
/// the rest in scanner order. A stable sort on (priority bucket,
/// scanner index) keeps everything deterministic — the input is already
/// in scanner order, so the tie-breaker is just "preserve relative
/// position".
///
/// Caller owns the returned list and must `deinit(allocator)` it. Kept
/// in the orchestrator (rather than a mixin method) so its lifetime is
/// visible at the call site, matching the original inline shape.
pub fn buildFlowOrder(
    allocator: std.mem.Allocator,
    script_entries: []const ScriptEntry,
) !std.ArrayList(usize) {
    var flow_handler_count: usize = 0;
    for (script_entries) |entry| {
        if (entry.has_event_handler) flow_handler_count += 1;
    }

    var flow_order: std.ArrayList(usize) = .empty;
    errdefer flow_order.deinit(allocator);
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
    return flow_order;
}

/// Mixin factory for `Codegen`. Reads `event_names`, `hook_names`,
/// `script_entries`, `plugin_events` from `self`.
pub fn Mixin(comptime Self: type) type {
    return struct {
        /// AllHookPayloads block — merge engine payloads with game events
        /// (`events/*.zig` scan, labelle-engine#422) and plugin events
        /// (`pub const Events` on plugin modules, RFC-PLUGIN-EVENTS phase
        /// 1). PluginEvents is always a union (possibly empty) when any
        /// plugin exists, so it can sit inside the same
        /// `MergeHookPayloads` call — game events stay on the same merged
        /// `AllHookPayloads` (no parallel dispatcher, per RFC §2 "feed the
        /// existing pipeline").
        pub fn writeAllHookPayloadsBlock(self: *Self, w: anytype) !void {
            // Pack events (Packs RFC §4, #439) are dir-scanned like the game
            // root's, so they widen `GameEvents` — fold `GameEvents` into
            // `AllHookPayloads` even when a pack is the ONLY source of events.
            const has_game_events = self.event_names.len > 0 or self.hasPackEvents();
            // Gate on **discovered** events, not declared plugins — a project
            // can declare a plugin whose `Events` decl is empty (or absent, e.g.
            // the plugin-controllers demo plugin), in which case `PluginEvents`
            // is emitted as `void` and must NOT be folded into `GameEvents`
            // (`MergeHookPayloads` rejects `void` operands).
            const has_plugin_events = self.plugin_events.len > 0;
            // When plugins declare events, the assembler emits a widened
            // `GameEvents` that already folds in `PluginEvents` (see the
            // game_events_block emission below). So `AllHookPayloads` only
            // needs to merge `GameEvents` once — referencing `PluginEvents`
            // here too would re-emit every plugin variant twice and trip
            // `MergeHookPayloads`' duplicate-field check.
            if (!has_game_events and !has_plugin_events) {
                try w.writeAll("const AllHookPayloads = engine.HookPayload(EcsBackend.Entity);\n\n");
            } else {
                try w.writeAll("const AllHookPayloads = engine.core.MergeHookPayloads(.{ engine.HookPayload(EcsBackend.Entity)");
                if (has_game_events or has_plugin_events) try w.writeAll(", GameEvents");
                try w.writeAll(" });\n\n");
            }
        }

        /// Game hooks block — the `GameHooks = engine.MergeHooks(...)`
        /// receiver tuple. `flow_order` is the priority-aware index list
        /// from `buildFlowOrder`.
        pub fn writeGameHooksBlock(self: *Self, w: anytype, ident_buf: *[256]u8, flow_order: []const usize) !void {
            const hook_names = self.hook_names;
            const script_entries = self.script_entries;
            if (hook_names.len == 0 and flow_order.len == 0 and !self.hasPackHooks()) {
                try w.writeAll("const GameHooks = struct {};\n\n");
            } else {
                var pascal_buf: [128]u8 = undefined;
                try w.writeAll("const GameHooks = engine.MergeHooks(AllHookPayloads, .{");
                for (hook_names) |name| {
                    const ident = pathToIdent(name, ident_buf);
                    const pascal = pathToPascal(name, &pascal_buf);
                    try w.print(" *{s}.{s},", .{ ident, pascal });
                }
                // Pack hooks (#440) — receiver types after the game-root hooks,
                // before the flow-handler tail. Prefixed `<pack>__<ident>` to
                // match the import alias + `hooks_init` instance idents. The
                // ordering here MUST mirror `writeHooksInitBlock`'s tuple order.
                var pack_prefix_buf: [128]u8 = undefined;
                for (self.pack_scans) |pack| {
                    const prefix = scan.packNamespacePrefix(pack.name, &pack_prefix_buf);
                    for (pack.hook_names) |name| {
                        const ident = pathToIdent(name, ident_buf);
                        const pascal = pathToPascal(name, &pascal_buf);
                        try w.print(" *{s}__{s}.{s},", .{ prefix, ident, pascal });
                    }
                }
                // Flow handler receiver types — appended after hooks so the
                // scanner sort (flows-among-flows) sits inside a single
                // tail block, leaving the existing hook order at the head
                // unchanged. `rel_path` is e.g. `flows/hit_counter.zig`,
                // matching the on-disk layout the `AllScripts` block already
                // imports. Iteration order is `flow_order` — priority-set
                // flows first (desc), then scanner-sorted notification flows.
                for (flow_order) |i| {
                    const entry = script_entries[i];
                    try w.writeAll(" *");
                    try printFlowHandlerImport(w, entry);
                    try w.writeAll(".FlowEventHandler,");
                }
                try w.writeAll(" });\n\n");
            }
        }

        /// Hooks init block — instantiate individual hooks and wire into
        /// `GameHooks`. `flow_order` is the priority-aware index list from
        /// `buildFlowOrder`.
        pub fn writeHooksInitBlock(self: *Self, w: anytype, ident_buf: *[256]u8, flow_order: []const usize) !void {
            const hook_names = self.hook_names;
            const script_entries = self.script_entries;
            if (hook_names.len == 0 and flow_order.len == 0 and !self.hasPackHooks()) {
                try w.writeAll("    var hooks = GameHooks{};\n");
            } else {
                var pascal_buf: [128]u8 = undefined;
                for (hook_names) |name| {
                    const ident = pathToIdent(name, ident_buf);
                    const pascal = pathToPascal(name, &pascal_buf);
                    try w.print("    var {s}_inst = {s}.{s}{{}};\n", .{ ident, ident, pascal });
                }
                // Pack-hook instances (#440) — `<pack>__<ident>_inst`,
                // materialised after the game-root hooks and before the flow
                // handlers so the `.receivers` tuple below matches the
                // `GameHooks` receiver-type order exactly.
                var pack_prefix_buf: [128]u8 = undefined;
                for (self.pack_scans) |pack| {
                    const prefix = scan.packNamespacePrefix(pack.name, &pack_prefix_buf);
                    for (pack.hook_names) |name| {
                        const ident = pathToIdent(name, ident_buf);
                        const pascal = pathToPascal(name, &pascal_buf);
                        try w.print("    var {s}__{s}_inst = {s}__{s}.{s}{{}};\n", .{ prefix, ident, prefix, ident, pascal });
                    }
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
                for (flow_order) |i| {
                    const entry = script_entries[i];
                    const ident = pathToIdent(entry.rel_path, ident_buf);
                    try w.print("    var {s}_flow_handler: ", .{ident});
                    try printFlowHandlerImport(w, entry);
                    try w.writeAll(".FlowEventHandler = .{};\n");
                }
                try w.writeAll("    var hooks = GameHooks{ .receivers = .{");
                for (hook_names) |name| {
                    const ident = pathToIdent(name, ident_buf);
                    try w.print(" &{s}_inst,", .{ident});
                }
                // Pack-hook receiver pointers — same order as the type tuple.
                for (self.pack_scans) |pack| {
                    const prefix = scan.packNamespacePrefix(pack.name, &pack_prefix_buf);
                    for (pack.hook_names) |name| {
                        const ident = pathToIdent(name, ident_buf);
                        try w.print(" &{s}__{s}_inst,", .{ prefix, ident });
                    }
                }
                // The tuple-literal order MUST match the receiver-type
                // order in `GameHooks` above — `MergeHooks.emit` looks each
                // receiver up by its tuple position. Iterate `flow_order`
                // identically to the `game_hooks_block` loop.
                for (flow_order) |i| {
                    const entry = script_entries[i];
                    const ident = pathToIdent(entry.rel_path, ident_buf);
                    try w.print(" &{s}_flow_handler,", .{ident});
                }
                try w.writeAll(" } };\n");
            }
        }
    };
}
