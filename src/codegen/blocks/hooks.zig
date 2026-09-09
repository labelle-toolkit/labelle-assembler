//! Hook-pipeline blocks for the generated `main.zig`:
//! `AllHookPayloads`, `GameHooks`, and the `hooks_init` body.
//!
//! Extracted from `main_template.zig`'s orchestrator (labelle-assembler
//! file-size refactor) following the `blocks/*.zig` mixin pattern.
//!
//! This file also owns THE hook ordering contract
//! (labelle-assembler#723, `docs/design/hook-handler-ordering.md`):
//! `buildReceiverPlan` is the single producer of dispatch order, and
//! both `writeGameHooksBlock` and `writeHooksInitBlock` emit by walking
//! its `[]Receiver`. The orchestrator builds that plan once (owning its
//! lifetime / `deinit`) and threads the slice into both. The
//! `AllHookPayloads` writer needs neither, only the event gates.
//!
//! The plan composes two levels: the legacy subgroup-scoped flow
//! priority (`buildFlowOrder`, RFC-PLUGIN-EVENTS phase 4/7) shapes the
//! BASELINE flow tail, and `project.labelle`'s opt-in `.hooks.order`
//! ranks the whole receiver list over that baseline.
//!
//! Reads `event_names`, `hook_names`, `script_entries`, `plugin_events`
//! from `self`; pure emit, no allocations beyond the caller's writer
//! (the flow-order array is the orchestrator's).

const std = @import("std");
const config = @import("../../config.zig");
const idents = @import("../idents.zig");
const scan = @import("../scan.zig");
const pack_root = @import("../pack_root.zig");
const registries = @import("registries.zig");
const script_scanner = @import("../../script_scanner.zig");

const pathToIdent = scan.pathToIdent;
const eventVariantName = idents.eventVariantName;
const pathToPascal = idents.pathToPascal;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;

/// Write the import expression that reaches a flow-handler script's
/// module. Three shapes, mirroring the `AllScripts` emitter exactly so
/// a handler file always lives in ONE module:
///   - pack entry (`import_base == ""`, #498 PR 2) → the pack MODULE's
///     re-export, `@import("pack__<pfx>").scripts.<rel_ident>` (the old
///     `@import("scripts/packs/…")` form was both a wrong path AND a
///     dual-module error);
///   - FlowNodes-promoted game script (#240 Gap 2) → its named module,
///     `@import("script__<ident>")` — a handler that ALSO exports
///     `FlowNodes` would otherwise be path-imported here while
///     `AllScripts` reaches it through the named module, the exact
///     dual-module error the promotion exists to prevent;
///   - everything else → `@import("scripts/<rel>")`.
/// Shared by the `GameHooks` receiver-type tuple and the `hooks_init`
/// materialisation so the two can never disagree on where a handler
/// lives.
fn printFlowHandlerImport(
    w: anytype,
    entry: ScriptEntry,
    flow_nodes: []const scan.PluginFlowNode,
) !void {
    if (entry.import_base.len == 0) {
        // `""` import_base is only ever set by `scanPackScriptsDir`,
        // which always stamps the owning pack — a null here is
        // scanner-invariant breakage.
        const pack_name = entry.plugin_name orelse return error.PackScriptMissingOwner;
        var pfx_buf: [128]u8 = undefined;
        const pfx = scan.packNamespacePrefix(pack_name, &pfx_buf);
        var rel_ident_buf: [256]u8 = undefined;
        const rel_ident = pathToIdent(pack_root.packRelScriptPath(entry.rel_path, pack_name), &rel_ident_buf);
        try w.print("@import(\"pack__{s}\").scripts.{s}", .{ pfx, rel_ident });
        return;
    }
    var ident_buf: [256]u8 = undefined;
    const ident = pathToIdent(entry.rel_path, &ident_buf);
    if (registries.isFlowNodeScript(flow_nodes, ident)) {
        try w.print("@import(\"script__{s}\")", .{ident});
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

// ── Receiver plan (labelle-assembler#723) ───────────────────────────────
//
// THE ordering contract. See `docs/design/hook-handler-ordering.md` for
// the full document; the short version:
//
//   * `MergeHooks` takes ONE receiver tuple and walks it in tuple order
//     for EVERY event, so ordering is per-RECEIVER and global across
//     events. There is no per-event receiver list to order.
//   * The DEFAULT ("baseline") sequence is unchanged: game-root hooks
//     (lexicographic stems) → pack hooks (pack scan order, lexicographic
//     stems within a pack) → flow handlers (`event_priority` set first,
//     descending; then scanner order).
//   * `project.labelle`'s `.hooks.order` assigns an `i32` rank to named
//     receivers. The resolved order is a STABLE sort on
//     `(rank descending, baseline index ascending)` — so an undeclared
//     project sorts to the identity and emits byte-identical output, and
//     a declaration moves only the receivers it names.
//
// One producer, two consumers: `buildReceiverPlan` is the single source
// of dispatch order, and BOTH the `GameHooks` type tuple and the
// `hooks_init` instance tuple are emitted by iterating the same slice.
// "Types and instances remain in matching order" is therefore structural,
// not a comment asking two loops to agree. labelle-assembler#724's route
// inspector and labelle-engine#858's tracing should key on
// `Receiver.id` — see `receiverId` for why that identity is the stable
// one.

/// Which discovery group a receiver came from. Carried through so the
/// emitters can pick the right import/ident shape, and so #724 can label
/// a route without re-deriving where the receiver lives.
pub const ReceiverKind = enum { root_hook, pack_hook, flow_handler };

/// One hook receiver in the generated tuple.
pub const Receiver = struct {
    kind: ReceiverKind,
    /// Stable, source-oriented identity: the receiver's source path
    /// relative to the generated target root, WITHOUT the `.zig`
    /// extension. `hooks/animation_hooks`,
    /// `packs/citizens/hooks/needs_hooks`, `scripts/flows/hit_counter`.
    ///
    /// This — not the tuple index, not the mangled Zig ident — is the
    /// identity `.hooks.order` names, diagnostics quote, #724 prints and
    /// #858 labels traces with. It is unique by construction (two
    /// receivers cannot share a source path), derived BEFORE ident
    /// mangling (`pathToIdent` / `pathToPascal` / `<pack>__`), and does
    /// not move when an unrelated hook file is added or removed.
    ///
    /// Allocator-owned by the `ReceiverPlan`.
    id: []const u8,
    /// Index into the owning group's source list: `hook_names` for
    /// `.root_hook`, `pack_scans[pack_index].hook_names` for
    /// `.pack_hook`, `script_entries` for `.flow_handler`.
    index: usize,
    /// Index into `pack_scans`; meaningful only for `.pack_hook`.
    pack_index: usize = 0,
    /// Resolved dispatch rank. Higher runs earlier; `0` is the
    /// undeclared bucket.
    rank: i32 = 0,
    /// True when a `.hooks.order` entry named this receiver. Lets a
    /// report distinguish "rank 0 because declared so" from "rank 0
    /// because nothing was declared".
    declared: bool = false,
    /// Position in the DEFAULT sequence, before ranks are applied. The
    /// sort's tie-breaker, and the thing that makes ranking a stable
    /// perturbation rather than a reshuffle.
    baseline: usize,
};

/// Owned result of `buildReceiverPlan`. `receivers` is in DISPATCH order.
pub const ReceiverPlan = struct {
    receivers: []Receiver,

    pub fn deinit(self: *ReceiverPlan, allocator: std.mem.Allocator) void {
        for (self.receivers) |r| allocator.free(r.id);
        allocator.free(self.receivers);
        self.receivers = &.{};
    }
};

/// Ordering-declaration failures. Both are hard errors raised BEFORE any
/// emission, with a source-oriented diagnostic on stderr (see
/// `reportOrderError`). There is deliberately no "cycle" arm: ranks are a
/// total order, so a cycle cannot be expressed (design doc §3).
pub const OrderError = error{
    UnknownHookOrderHandler,
    DuplicateHookOrderHandler,
};

/// A flow handler's receiver id: the generated `.zig`'s target-relative
/// path minus the extension. `import_base` is `"scripts/"` for game and
/// plugin scripts and `""` for pack scripts (whose `rel_path` is already
/// target-relative), which is exactly the pairing the `AllScripts` /
/// `printFlowHandlerImport` emitters use — so the id names the same file
/// the tuple imports.
fn flowReceiverId(allocator: std.mem.Allocator, entry: ScriptEntry) ![]const u8 {
    const rel = if (std.mem.endsWith(u8, entry.rel_path, ".zig"))
        entry.rel_path[0 .. entry.rel_path.len - ".zig".len]
    else
        entry.rel_path;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ entry.import_base, rel });
}

/// Build the resolved dispatch order for every hook receiver in the
/// project. Caller owns the returned plan and must `deinit(allocator)`.
///
/// Steps, in order:
///   1. Lay down the BASELINE sequence (root hooks, pack hooks, flow tail
///      via `buildFlowOrder`) and stamp each entry's `baseline` index.
///   2. Apply `cfg.hooks.order`: match each declaration's `handler`
///      against a receiver id, erroring on an unknown or duplicated one.
///   3. Stable-sort on `(rank desc, baseline asc)`.
///
/// With no declarations every rank is `0` and step 3 is the identity, so
/// the emitted tuple is byte-identical to the pre-#723 assembler.
pub fn buildReceiverPlan(
    allocator: std.mem.Allocator,
    cfg: config.ProjectConfig,
    hook_names: []const []const u8,
    pack_scans: []const scan.PackScan,
    script_entries: []const ScriptEntry,
) !ReceiverPlan {
    var receivers: std.ArrayList(Receiver) = .empty;
    errdefer {
        for (receivers.items) |r| allocator.free(r.id);
        receivers.deinit(allocator);
    }

    // ── 1. Baseline ─────────────────────────────────────────────────
    // Group 1 — game-root `hooks/**/*.zig`, already lexicographically
    // sorted by `scanner.linkAndScan`.
    for (hook_names, 0..) |name, i| {
        const id = try std.fmt.allocPrint(allocator, "hooks/{s}", .{name});
        errdefer allocator.free(id);
        try receivers.append(allocator, .{
            .kind = .root_hook,
            .id = id,
            .index = i,
            .baseline = receivers.items.len,
        });
    }
    // Group 2 — pack hooks (#440), packs in scan order, stems sorted
    // within a pack. `import_prefix` (e.g. `packs/citizens`) is what
    // makes two packs shipping `overlay.zig` distinguishable by id.
    for (pack_scans, 0..) |pack, pi| {
        for (pack.hook_names, 0..) |name, i| {
            const id = try std.fmt.allocPrint(allocator, "{s}/hooks/{s}", .{ pack.import_prefix, name });
            errdefer allocator.free(id);
            try receivers.append(allocator, .{
                .kind = .pack_hook,
                .id = id,
                .index = i,
                .pack_index = pi,
                .baseline = receivers.items.len,
            });
        }
    }
    // Group 3 — the flow-handler tail, already shaped by the legacy
    // subgroup-scoped `event_priority` sort (`buildFlowOrder`). That
    // priority shapes the BASELINE; `.hooks.order` ranks over it. See
    // design doc §4.3 for why the two levels are not interchangeable.
    var flow_order = try buildFlowOrder(allocator, script_entries);
    defer flow_order.deinit(allocator);
    for (flow_order.items) |i| {
        const id = try flowReceiverId(allocator, script_entries[i]);
        errdefer allocator.free(id);
        try receivers.append(allocator, .{
            .kind = .flow_handler,
            .id = id,
            .index = i,
            .baseline = receivers.items.len,
        });
    }

    // ── 2. Apply declarations ───────────────────────────────────────
    for (cfg.hooks.order) |decl| {
        var matched: ?*Receiver = null;
        for (receivers.items) |*r| {
            if (std.mem.eql(u8, r.id, decl.handler)) {
                matched = r;
                break;
            }
        }
        const r = matched orelse {
            try reportOrderError(allocator, "unknown handler", decl.handler, receivers.items);
            return error.UnknownHookOrderHandler;
        };
        if (r.declared) {
            try reportOrderError(allocator, "duplicate handler", decl.handler, receivers.items);
            return error.DuplicateHookOrderHandler;
        }
        r.rank = decl.rank;
        r.declared = true;
    }

    // ── 3. Resolve ──────────────────────────────────────────────────
    // Stable sort on (rank desc, baseline asc). `baseline` is unique, so
    // the comparator is a strict total order and the result is
    // deterministic regardless of the sort's internal choices.
    std.mem.sort(Receiver, receivers.items, {}, struct {
        fn lessThan(_: void, a: Receiver, b: Receiver) bool {
            if (a.rank != b.rank) return a.rank > b.rank;
            return a.baseline < b.baseline;
        }
    }.lessThan);

    return .{ .receivers = try receivers.toOwnedSlice(allocator) };
}

/// Source-oriented diagnostic for a bad `.hooks.order` entry. Names
/// `project.labelle`, quotes the offending handler string, and lists
/// every discovered receiver id in DEFAULT order so a typo is one glance
/// from its fix.
///
/// Written straight to stderr rather than through `std.log.err`, matching
/// `main_template.checkBasenameCollisions` — the Zig test runner fails
/// any test that logs at `.err`, and the tests here deliberately trigger
/// both diagnostics.
fn reportOrderError(
    allocator: std.mem.Allocator,
    reason: []const u8,
    handler: []const u8,
    receivers: []const Receiver,
) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.print(
        "labelle-assembler: project.labelle `.hooks.order`: {s} \"{s}\".\n",
        .{ reason, handler },
    );
    if (receivers.len == 0) {
        try w.writeAll("  This project has no hook receivers to order.\n");
    } else {
        try w.writeAll("  Known hook receivers, in default order:\n");
        // Print in BASELINE order, not current slice order — the
        // declarations are only half-applied at this point.
        var next: usize = 0;
        while (next < receivers.len) : (next += 1) {
            for (receivers) |r| {
                if (r.baseline == next) {
                    try w.print("    {s}\n", .{r.id});
                    break;
                }
            }
        }
    }
    const io = config.globalIo();
    std.Io.File.stderr().writeStreamingAll(io, aw.written()) catch {};
}

/// Rendered dispatch-order comment, emitted immediately above
/// `const GameHooks` — but ONLY when the project actually declares
/// `.hooks.order`. Suppressing it otherwise is what keeps a
/// project that declares no ordering byte-identical to the
/// pre-#723 assembler, and it means the comment's presence is
/// itself the signal that the sequence below was authored rather
/// than discovered.
fn writeReceiverOrderComment(w: anytype, cfg: config.ProjectConfig, receivers: []const Receiver) !void {
    if (cfg.hooks.order.len == 0) return;
    try w.writeAll(
        \\// Hook receiver dispatch order (labelle-assembler#723). `.hooks.order` is
        \\// declared in project.labelle, so this sequence is explicit. ONE tuple,
        \\// walked in this order for EVERY event; on a consumable event the first
        \\// receiver that returns `true` stops the walk.
        \\
    );
    // The rank goes through a scratch buffer rather than a `{d:5}`
    // width spec: Zig's formatter emits an explicit `+` sign for a
    // SIGNED integer whenever a width is given (`+100`, `+0`), which
    // reads as noise in a generated comment. Format bare, pad as a
    // string.
    var rank_buf: [16]u8 = undefined;
    for (receivers, 0..) |r, i| {
        const rank_str = try std.fmt.bufPrint(&rank_buf, "{d}", .{r.rank});
        try w.print("//   [{d}] rank {s: >5} {s} {s}\n", .{
            i,
            rank_str,
            if (r.declared) "*" else " ",
            r.id,
        });
    }
    try w.writeAll("// (* = rank declared in project.labelle `.hooks.order`)\n");
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
            // Script-DECLARED events (labelle-engine#772) widen it the same
            // way — this gate must match `writeGameEventsBlock`'s exactly, or
            // a declared-events-only project would emit a `GameEvents` union
            // that never folds into the dispatcher.
            const has_game_events = self.event_names.len > 0 or self.hasPackEvents() or
                self.declaredEvents().len > 0;
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
        /// receiver tuple, emitted in the resolved dispatch order
        /// (labelle-assembler#723). `receivers` is `buildReceiverPlan`'s
        /// output: the baseline sequence (root hooks → pack hooks → flow
        /// tail) after `.hooks.order` ranks are applied.
        ///
        /// This loop and `writeHooksInitBlock`'s walk the SAME slice, so
        /// the receiver-type tuple and the receiver-pointer tuple agree
        /// index-by-index by construction — `MergeHooks.emit` looks each
        /// receiver up by its tuple position, so a disagreement would
        /// mis-dispatch every event.
        pub fn writeGameHooksBlock(self: *Self, w: anytype, ident_buf: *[256]u8, receivers: []const Receiver) !void {
            if (receivers.len == 0) {
                try w.writeAll("const GameHooks = struct {};\n\n");
                return;
            }
            var pascal_buf: [128]u8 = undefined;
            var pack_prefix_buf: [128]u8 = undefined;
            try writeReceiverOrderComment(w, self.cfg, receivers);
            try w.writeAll("const GameHooks = engine.MergeHooks(AllHookPayloads, .{");
            for (receivers) |r| switch (r.kind) {
                .root_hook => {
                    const name = self.hook_names[r.index];
                    const ident = pathToIdent(name, ident_buf);
                    const pascal = pathToPascal(name, &pascal_buf);
                    try w.print(" *{s}.{s},", .{ ident, pascal });
                },
                // Pack hooks (#440) — prefixed `<pack>__<ident>` to match
                // the import alias + `hooks_init` instance idents.
                .pack_hook => {
                    const pack = self.pack_scans[r.pack_index];
                    const prefix = scan.packNamespacePrefix(pack.name, &pack_prefix_buf);
                    const name = pack.hook_names[r.index];
                    const ident = pathToIdent(name, ident_buf);
                    const pascal = pathToPascal(name, &pascal_buf);
                    try w.print(" *{s}__{s}.{s},", .{ prefix, ident, pascal });
                },
                // Flow handlers — `rel_path` is e.g. `flows/hit_counter.zig`,
                // matching the on-disk layout the `AllScripts` block already
                // imports (`printFlowHandlerImport` picks the right of the
                // three module shapes).
                .flow_handler => {
                    try w.writeAll(" *");
                    try printFlowHandlerImport(w, self.script_entries[r.index], self.plugin_flow_nodes);
                    try w.writeAll(".FlowEventHandler,");
                },
            };
            try w.writeAll(" });\n\n");

            // ── Receiver identity table (#727) ───────────────────────────
            // Index-aligned with the tuple above. `MergeHooks.emit` walks
            // receivers BY TUPLE POSITION, so a tracer can label frame `i`
            // with `hook_receiver_ids[i]` and get the exact same string the
            // route inspector prints — shared identity by construction
            // rather than two derivations agreeing.
            //
            // Why a table and not a `pub const labelle_receiver_id` on each
            // receiver: the assembler does NOT generate hook receiver files.
            // `<target>/hooks` is a symlink to the user's own directory and
            // pack hooks are the pack author's files, so emitting a decl
            // into them would be a codemod over source we do not own. The
            // table lives in generated `main.zig`, which we do.
            //
            // Engine-side this is optional: a build that does not declare it
            // (a hand-wired game with no generated main) falls back to
            // deriving an id from `@typeName`.
            try w.writeAll("/// Receiver ids, index-aligned with the `GameHooks` tuple (#727).\n");
            try w.writeAll("pub const hook_receiver_ids = [_][]const u8{");
            for (receivers) |r| try w.print(" \"{s}\",", .{r.id});
            try w.writeAll(" };\n\n");
        }

        /// Hooks init block — instantiate every receiver and wire the
        /// pointers into `GameHooks`, in the same resolved dispatch order
        /// `writeGameHooksBlock` used.
        pub fn writeHooksInitBlock(self: *Self, w: anytype, ident_buf: *[256]u8, receivers: []const Receiver) !void {
            if (receivers.len == 0) {
                try w.writeAll("    var hooks = GameHooks{};\n");
                return;
            }
            var pascal_buf: [128]u8 = undefined;
            var pack_prefix_buf: [128]u8 = undefined;

            // Materialise each receiver so `&` has a stable address to
            // take. The `var` decls could be emitted in any order (each
            // names a unique identifier — `pathToIdent` is injective into
            // the Zig ident namespace, issue #173) but we follow dispatch
            // order for diff-readability: the `var`s appear in the same
            // order their `&` references do inside the tuple literal.
            //
            // `setHooks` walks the receiver tuple and injects
            // `*AssembledGame` into `game_ptr` for every receiver that
            // declares such a field (`labelle-engine/src/game.zig:419-429`),
            // so no extra init step is needed here.
            for (receivers) |r| switch (r.kind) {
                .root_hook => {
                    const name = self.hook_names[r.index];
                    const ident = pathToIdent(name, ident_buf);
                    const pascal = pathToPascal(name, &pascal_buf);
                    try w.print("    var {s}_inst = {s}.{s}{{}};\n", .{ ident, ident, pascal });
                },
                .pack_hook => {
                    const pack = self.pack_scans[r.pack_index];
                    const prefix = scan.packNamespacePrefix(pack.name, &pack_prefix_buf);
                    const name = pack.hook_names[r.index];
                    const ident = pathToIdent(name, ident_buf);
                    const pascal = pathToPascal(name, &pascal_buf);
                    try w.print("    var {s}__{s}_inst = {s}__{s}.{s}{{}};\n", .{ prefix, ident, prefix, ident, pascal });
                },
                .flow_handler => {
                    const entry = self.script_entries[r.index];
                    const ident = pathToIdent(entry.rel_path, ident_buf);
                    try w.print("    var {s}_flow_handler: ", .{ident});
                    try printFlowHandlerImport(w, entry, self.plugin_flow_nodes);
                    try w.writeAll(".FlowEventHandler = .{};\n");
                },
            };

            // The tuple-literal order MUST match the receiver-type order in
            // `GameHooks` above — same `receivers` slice, same walk.
            try w.writeAll("    var hooks = GameHooks{ .receivers = .{");
            for (receivers) |r| switch (r.kind) {
                .root_hook => {
                    const ident = pathToIdent(self.hook_names[r.index], ident_buf);
                    try w.print(" &{s}_inst,", .{ident});
                },
                .pack_hook => {
                    const pack = self.pack_scans[r.pack_index];
                    const prefix = scan.packNamespacePrefix(pack.name, &pack_prefix_buf);
                    const ident = pathToIdent(pack.hook_names[r.index], ident_buf);
                    try w.print(" &{s}__{s}_inst,", .{ prefix, ident });
                },
                .flow_handler => {
                    const ident = pathToIdent(self.script_entries[r.index].rel_path, ident_buf);
                    try w.print(" &{s}_flow_handler,", .{ident});
                },
            };
            try w.writeAll(" } };\n");
        }
    };
}
