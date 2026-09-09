//! The hook-route inspector — labelle-assembler#724, child of the hooks
//! epic labelle-engine#854. Design note:
//! `docs/design/hook-route-inspection.md`.
//!
//! What these tests pin, and why each one matters:
//!
//!   * **The report cannot drift from dispatch.** `NO_DRIFT` builds a
//!     report AND generates a `main.zig` through the real emitter from
//!     the SAME inputs, then compares the report's receiver sequence
//!     against the `MergeHooks(AllHookPayloads, .{ … })` tuple parsed out
//!     of the emitted text, entry by entry. This is the acceptance the
//!     whole feature stands on — an inspector that reports an order the
//!     dispatcher does not use is worse than no inspector — and #723's
//!     handoff is explicit that #724 must consume `buildReceiverPlan`
//!     rather than re-derive. A second test asserts that a `.hooks.order`
//!     rank moves the report and the tuple TOGETHER, so the two could not
//!     pass by both being wrong in the same fixed way.
//!   * **Qualified listener mappings** for a root event, a pack-local
//!     event and a plugin event — the issue's first acceptance item. Pack
//!     events are matched under their `<pack>__` tag, which is what makes
//!     the report agree with the generated union rather than with the
//!     on-disk filename.
//!   * **Elision is distinguishable from silence.** A dropped plugin
//!     event and a live event nobody listens to must not read the same,
//!     because the issue says an unobserved event is not automatically an
//!     error while a dropped one has an explanation.
//!   * **Consumable semantics**, because on a consumable event order
//!     decides WHETHER a later listener runs, not merely when — the one
//!     place getting order wrong is silent.
//!   * **Delivery is per call site**: `emit` buffered, `emitSync`
//!     synchronous, on the same event.
//!   * **The JSON is a contract**: deterministic byte-for-byte across
//!     runs, and round-trippable through the typed model — which is what
//!     labelle-engine#858 will correlate its traces against.

const std = @import("std");
const zspec = @import("zspec");
const generator = @import("generator");

const hook_routes = generator.hook_routes;
const ScriptEntry = generator.script_scanner.ScriptScanner.ScriptEntry;
const ProjectConfig = generator.ProjectConfig;
const PackScan = generator.PackScan;
const PluginEvent = generator.main_zig.PluginEvent;

// ── Fixture ─────────────────────────────────────────────────────────────
//
// One project exercising every discovery group at once, because the
// interesting failures live at the seams: a pack hook promoted past a
// root hook, a flow handler in the same tuple, a pack event that must be
// matched under its namespaced tag, and one script emitting the same
// project both ways.

fn write(tmp: *std.testing.TmpDir, sub_dir: []const u8, name: []const u8, body: []const u8) !void {
    const io = std.testing.io;
    if (sub_dir.len > 0) try tmp.dir.createDirPath(io, sub_dir);
    var buf: [256]u8 = undefined;
    const rel = if (sub_dir.len > 0)
        try std.fmt.bufPrint(&buf, "{s}/{s}", .{ sub_dir, name })
    else
        name;
    try tmp.dir.writeFile(io, .{ .sub_path = rel, .data = body });
}

/// Lay the project down. Both `game_dir` and `target_dir` point here —
/// in a real generate the target reaches the game's dirs through
/// symlinks, and a flat fixture is the same thing with the indirection
/// removed.
fn stageFixture(tmp: *std.testing.TmpDir) !void {
    // Game-root events. `urgent` is CONSUMABLE, which is the case where
    // receiver order decides whether a later listener runs at all.
    try write(tmp, "events", "pulse.zig",
        \\pub const Pulse = struct { n: i32 = 0 };
        \\
    );
    try write(tmp, "events", "urgent.zig",
        \\pub const Urgent = struct {
        \\    pub const consumable = true;
        \\    who: u32 = 0,
        \\};
        \\
    );

    // Two game-root hooks. `z_second` also handles the PACK event under
    // its namespaced tag, and the plugin event under its qualified tag.
    try write(tmp, "hooks", "a_first.zig",
        \\const Pulse = @import("../events/pulse.zig").Pulse;
        \\pub const AFirst = struct {
        \\    pub fn pulse(self: *const AFirst, ev: Pulse) void { _ = self; _ = ev; }
        \\    /// Not a handler: one parameter, so `MergeHooks` does not
        \\    /// treat it as a claim on an event named `helper`.
        \\    pub fn helper(self: *const AFirst) void { _ = self; }
        \\    /// Not a handler: private, so `@hasDecl` from the dispatcher
        \\    /// cannot see it.
        \\    fn hidden(self: *const AFirst, ev: Pulse) void { _ = self; _ = ev; }
        \\};
        \\
    );
    try write(tmp, "hooks", "z_second.zig",
        \\const Pulse = @import("../events/pulse.zig").Pulse;
        \\pub const ZSecond = struct {
        \\    pub fn pulse(self: *const ZSecond, ev: Pulse) void { _ = self; _ = ev; }
        \\    pub fn urgent(self: *const ZSecond, ev: anytype) bool { _ = self; _ = ev; return false; }
        \\    pub fn citizens__needs_low(self: *const ZSecond, ev: anytype) void { _ = self; _ = ev; }
        \\    pub fn box2d__collision_begin(self: *const ZSecond, ev: anytype) void { _ = self; _ = ev; }
        \\};
        \\
    );

    // A pack: one event, one hook. The hook handles its own pack event
    // under the namespaced tag the generated union carries.
    try write(tmp, "packs/citizens/events", "needs_low.zig",
        \\pub const NeedsLow = struct { level: f32 = 0 };
        \\
    );
    try write(tmp, "packs/citizens/hooks", "needs_hooks.zig",
        \\pub const NeedsHooks = struct {
        \\    pub fn citizens__needs_low(self: *const NeedsHooks, ev: anytype) void { _ = self; _ = ev; }
        \\};
        \\
    );

    // A flow handler — the third receiver group, in the same tuple.
    try write(tmp, "scripts/flows", "hit_counter.zig",
        \\pub const FlowEventHandler = struct {
        \\    pub fn pulse(self: *FlowEventHandler, ev: anytype) void { _ = self; _ = ev; }
        \\};
        \\
    );

    // One script emitting the SAME project's events both ways: `pulse`
    // buffered, `urgent` synchronously.
    try write(tmp, "scripts/playing", "10_emitter.zig",
        \\const Pulse = @import("../../events/pulse.zig").Pulse;
        \\pub fn tick(game: anytype, _: anytype, _: anytype, _: f32) void {
        \\    game.emit(.{ .pulse = Pulse{ .n = 1 } });
        \\    game.emitSync(.{ .urgent = .{ .who = 7 } });
        \\}
        \\
    );
}

const citizens_pack: PackScan = .{
    .name = "citizens",
    .import_prefix = "packs/citizens",
    .component_names = &.{},
    .event_names = &.{"needs_low"},
    .prefab_names = &.{},
    .hook_names = &.{"needs_hooks"},
};

fn flowEntry() ScriptEntry {
    return .{
        .name = "flows/hit_counter.zig",
        .filename = "flows/hit_counter.zig",
        .states = &.{},
        .sort_order = null,
        .subdir = null,
        .rel_path = "flows/hit_counter.zig",
        .has_event_handler = true,
    };
}

fn emitterEntry() ScriptEntry {
    return .{
        .name = "playing/10_emitter.zig",
        .filename = "playing/10_emitter.zig",
        .states = &.{"playing"},
        .sort_order = 10,
        .subdir = "playing",
        .rel_path = "playing/10_emitter.zig",
    };
}

const script_entries = [_]ScriptEntry{ flowEntry(), emitterEntry() };

/// Plugin events: one consumed, one elided. `box2d__collision_begin` is
/// handled by `hooks/z_second`; `box2d__collision_end` is not, and is
/// therefore the elided row whose status must not read like silence.
const plugin_kept = [_]PluginEvent{.{
    .plugin_import_name = "box2d",
    .plugin_sanitized = "box2d",
    .event_name = "collision_begin",
}};
const plugin_elided = [_]PluginEvent{.{
    .plugin_import_name = "box2d",
    .plugin_sanitized = "box2d",
    .event_name = "collision_end",
}};

fn baseCfg(order: []const generator.HookOrderEntry) ProjectConfig {
    return .{
        .y_axis = .up,
        .name = "routes-fixture",
        .backend = .raylib,
        .ecs = .mock,
        .plugins = &.{
            .{ .name = "citizens", .repo = "@packs/citizens" },
            .{ .name = "box2d" },
        },
        .hooks = .{ .order = order },
    };
}

fn inputs(dir: []const u8, cfg: ProjectConfig) hook_routes.Inputs {
    return .{
        .cfg = cfg,
        .game_dir = dir,
        .target_dir = dir,
        .hook_names = &.{ "a_first", "z_second" },
        .pack_scans = &.{citizens_pack},
        .script_entries = &script_entries,
        .event_names = &.{ "pulse", "urgent" },
        .plugin_events = &plugin_kept,
        .plugin_events_elided = &plugin_elided,
        // No engine package in the fixture: the report must say so rather
        // than pretend the lifecycle union is empty.
        .engine_dir = null,
    };
}

/// Only the hook holes, matching `test/hook_ordering_tests.zig` — a
/// minimal template keeps the tuple unambiguous to locate.
const hooks_tmpl =
    \\const std = @import("std");
    \\{{hook_imports_block}}{{all_hook_payloads_block}}{{game_hooks_block}}const lifecycle_marker = struct {
    \\    pub fn main() !void {
    \\{{hooks_init_block}}
    \\    }
    \\};
    \\{{lifecycle}}
;

fn genMainZig(allocator: std.mem.Allocator, cfg: ProjectConfig) ![]const u8 {
    generator.main_template.pack_scans = &.{citizens_pack};
    defer generator.main_template.pack_scans = &.{};
    return generator.generateMainZigFromTemplate(
        allocator,
        hooks_tmpl,
        cfg,
        "// lifecycle\n",
        &script_entries,
        &.{}, // prefab_names
        &.{}, // jsonc_scene_names
        &.{}, // scene_manifests
        &.{}, // component_names
        &.{ "a_first", "z_second" },
        &.{ "pulse", "urgent" },
        &.{}, // enum_names
        &.{}, // view_names
        &.{}, // gizmo_names
        &.{}, // animation_names
        &.{}, // plugin_events
        &.{}, // plugin_flow_nodes
        &.{}, // plugin_pin_styles
        &.{}, // plugin_coercions
    );
}

/// The comma-separated entries of the emitted `MergeHooks(...)` receiver
/// tuple, in tuple position order — which IS dispatch order.
fn tupleEntries(allocator: std.mem.Allocator, main_zig: []const u8) ![][]const u8 {
    const open = "const GameHooks = engine.MergeHooks(AllHookPayloads, .{";
    const at = std.mem.indexOf(u8, main_zig, open) orelse return error.TupleNotFound;
    const body_start = at + open.len;
    const close = std.mem.indexOfPos(u8, main_zig, body_start, "});") orelse return error.TupleNotFound;
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, main_zig[body_start..close], ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t\n\r");
        if (t.len > 0) try out.append(allocator, t);
    }
    return out.toOwnedSlice(allocator);
}

fn buildIn(arena: std.mem.Allocator, dir: []const u8, cfg: ProjectConfig) !hook_routes.Report {
    return hook_routes.buildReport(arena, inputs(dir, cfg));
}

/// Assert one tuple slot is the receiver the report placed at that index.
///
/// The tuple carries MANGLED idents (`*a_u_first.AFirst`,
/// `*citizens__needs_u_hooks.NeedsHooks`, `*@import("scripts/flows/…")
/// .FlowEventHandler`), which is exactly why `Receiver.id` is derived
/// before mangling. The report's own `zig_type` is the container decl the
/// emitter names, so it is the honest cross-check; for flow handlers,
/// whose container name is the constant `FlowEventHandler`, the import
/// path stem disambiguates.
fn expectSlotMatches(r: hook_routes.Receiver, slot: []const u8, main_zig: []const u8) !void {
    const extra: []const u8 = if (r.kind == .flow_handler) std.fs.path.basename(r.id) else r.zig_type;
    std.testing.expect(std.mem.indexOf(u8, slot, r.zig_type) != null and
        std.mem.indexOf(u8, slot, extra) != null) catch |err| {
        std.debug.print("receiver [{d}] `{s}` (type `{s}`) vs tuple slot `{s}`\n--- main.zig ---\n{s}\n", .{ r.order, r.id, r.zig_type, slot, main_zig });
        return err;
    };
}

// ── Specs ───────────────────────────────────────────────────────────────

pub const NO_DRIFT = struct {
    test "the reported receiver order IS the emitted MergeHooks tuple, entry by entry" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try stageFixture(&tmp);
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const cfg = baseCfg(&.{});
        const report = try buildIn(arena, dir, cfg);
        const main_zig = try genMainZig(allocator, cfg);
        defer allocator.free(main_zig);
        const entries = try tupleEntries(arena, main_zig);

        try std.testing.expectEqual(entries.len, report.receivers.len);
        // Index-by-index, not "both contain the same set": the whole
        // point is the ORDER.
        for (report.receivers, entries) |r, slot| try expectSlotMatches(r, slot, main_zig);
        // …and the pack hook is qualified in the tuple exactly as the
        // report qualifies its id, so a two-pack project cannot have its
        // same-named hooks confused with one another.
        const pack_slot = entries[report.receiverById("packs/citizens/hooks/needs_hooks").?.order];
        try std.testing.expect(std.mem.indexOf(u8, pack_slot, "citizens__") != null);
    }

    test "a `.hooks.order` rank moves the report and the tuple together" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try stageFixture(&tmp);
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Promote the PACK hook past both game-root hooks — the
        // cross-group case #723 made expressible.
        const cfg = baseCfg(&.{.{ .handler = "packs/citizens/hooks/needs_hooks", .rank = 100 }});
        const report = try buildIn(arena, dir, cfg);
        const main_zig = try genMainZig(allocator, cfg);
        defer allocator.free(main_zig);
        const entries = try tupleEntries(arena, main_zig);

        try std.testing.expectEqualStrings("packs/citizens/hooks/needs_hooks", report.receivers[0].id);
        try std.testing.expectEqual(@as(i32, 100), report.receivers[0].rank);
        try std.testing.expect(report.receivers[0].rank_declared);
        // …and it moved in the generated tuple too, at the same index.
        // The tuple's ident is MANGLED (`citizens__needs_u_hooks`), so the
        // check is on the emitted container type and the pack prefix, not
        // on the id text.
        try std.testing.expect(std.mem.indexOf(u8, entries[0], "NeedsHooks") != null);
        try std.testing.expect(std.mem.indexOf(u8, entries[0], "citizens__") != null);
        try std.testing.expectEqual(entries.len, report.receivers.len);
        for (report.receivers, entries) |r, slot| try expectSlotMatches(r, slot, main_zig);
    }

    test "the default report is the documented baseline: root, then pack, then flow" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try stageFixture(&tmp);
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const report = try buildIn(arena, dir, baseCfg(&.{}));
        try std.testing.expectEqualStrings("hooks/a_first", report.receivers[0].id);
        try std.testing.expectEqualStrings("hooks/z_second", report.receivers[1].id);
        try std.testing.expectEqualStrings("packs/citizens/hooks/needs_hooks", report.receivers[2].id);
        try std.testing.expectEqualStrings("scripts/flows/hit_counter", report.receivers[3].id);
        // An undeclared project is reported as such, so the human form can
        // say the sequence is exact but incidental (design doc §2.4).
        try std.testing.expect(!report.ordering.declared);
        try std.testing.expectEqualStrings("receiver", report.ordering.scope);
    }
};

pub const LISTENER_MAPPING = struct {
    test "a root event, a pack event and a plugin event all map to qualified listeners" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try stageFixture(&tmp);
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const report = try buildIn(arena, dir, baseCfg(&.{}));

        // Root event: three listeners, in the global dispatch sequence.
        const pulse = report.eventByTag("pulse").?;
        try std.testing.expectEqual(@as(usize, 3), pulse.listeners.len);
        try std.testing.expectEqualStrings("hooks/a_first", pulse.listeners[0].receiver);
        try std.testing.expectEqualStrings("hooks/z_second", pulse.listeners[1].receiver);
        try std.testing.expectEqualStrings("scripts/flows/hit_counter", pulse.listeners[2].receiver);
        // The `order` on a listener is its position in the WHOLE tuple,
        // not a per-event rank — there is no per-event ordering to report.
        try std.testing.expectEqual(@as(usize, 0), pulse.listeners[0].order);
        try std.testing.expectEqual(@as(usize, 3), pulse.listeners[2].order);
        try std.testing.expectEqualStrings("events/pulse.zig", pulse.source.?);
        try std.testing.expectEqualStrings("Pulse", pulse.payload.zig_type.?);
        try std.testing.expect(pulse.payload.resolved);
        try std.testing.expectEqualStrings("n", pulse.payload.fields[0].name);
        try std.testing.expectEqualStrings("i32", pulse.payload.fields[0].zig_type);

        // Pack event: the tag is namespaced, and BOTH the pack's own hook
        // and a game-root hook listening across the boundary are found.
        const needs = report.eventByTag("citizens__needs_low").?;
        try std.testing.expectEqualStrings("needs_low", needs.name);
        try std.testing.expectEqualStrings("citizens", needs.owner_name);
        try std.testing.expectEqualStrings("packs/citizens/events/needs_low.zig", needs.source.?);
        try std.testing.expectEqual(@as(usize, 2), needs.listeners.len);
        try std.testing.expectEqualStrings("hooks/z_second", needs.listeners[0].receiver);
        try std.testing.expectEqualStrings("packs/citizens/hooks/needs_hooks", needs.listeners[1].receiver);

        // Plugin event: qualified `<plugin>__<event>`, one listener.
        const collide = report.eventByTag("box2d__collision_begin").?;
        try std.testing.expectEqualStrings("box2d", collide.owner_name);
        try std.testing.expectEqual(@as(usize, 1), collide.listeners.len);
        try std.testing.expectEqualStrings("hooks/z_second", collide.listeners[0].receiver);

        // The un-namespaced `needs_low` is NOT an event: a report keyed on
        // filenames instead of generated tags would have invented it.
        try std.testing.expect(report.eventByTag("needs_low") == null);
    }

    test "only public two-parameter fns count as handlers" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try stageFixture(&tmp);
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const report = try buildIn(arena, dir, baseCfg(&.{}));

        const a_first = report.receiverById("hooks/a_first").?;
        try std.testing.expect(a_first.handlers_resolved);
        // `helper` (one param) and `hidden` (not pub) are the two shapes
        // labelle-core's dispatcher ignores, so the report must too —
        // otherwise every hook file with a private helper would be
        // reported as claiming a phantom event.
        try std.testing.expectEqual(@as(usize, 1), a_first.handlers.len);
        try std.testing.expectEqualStrings("pulse", a_first.handlers[0]);
        try std.testing.expectEqualStrings("AFirst", a_first.zig_type);
        try std.testing.expectEqualStrings("hooks/a_first.zig", a_first.source);
    }
};

pub const HONESTY = struct {
    test "elision is distinguishable from an event nobody listens to" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try stageFixture(&tmp);
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const report = try buildIn(arena, dir, baseCfg(&.{}));

        const dropped = report.eventByTag("box2d__collision_end").?;
        try std.testing.expectEqual(hook_routes.model.EventStatus.elided, dropped.status);
        try std.testing.expectEqual(@as(usize, 0), dropped.listeners.len);
        try std.testing.expect(dropped.notes.len > 0);

        // `urgent` survives (it is a game event, never filtered) and has a
        // listener; the third state — live, no listener — is the one that
        // must NOT be reported as elided.
        const kept = report.eventByTag("box2d__collision_begin").?;
        try std.testing.expectEqual(hook_routes.model.EventStatus.active, kept.status);
    }

    test "consumable resolves ONLY a literal true/false; anything else is unresolved" {
        // The regression this pins: `indexOf(src, "true")` matched `!true`,
        // `untrue`, an alias, and the word "true" in a comment — reporting
        // `consumable` with confidence while core's comptime check (which
        // accepts a literal `true` and nothing else) disagreed.
        const cases = [_]struct { src: []const u8, want: ?bool }{
            .{ .src = "pub const E = struct { pub const consumable = true; };\n", .want = true },
            .{ .src = "pub const E = struct { pub const consumable = false; };\n", .want = false },
            // Negation — the case Codex reproduced. Core sees false.
            .{ .src = "pub const E = struct { pub const consumable = !true; };\n", .want = null },
            .{ .src = "pub const E = struct { pub const consumable = !false; };\n", .want = null },
            // An alias the parser cannot follow.
            .{ .src = "pub const E = struct { pub const consumable = other_flag; };\n", .want = null },
            // A call expression.
            .{ .src = "pub const E = struct { pub const consumable = isConsumable(); };\n", .want = null },
            // A comptime conditional.
            .{ .src = "pub const E = struct { pub const consumable = if (x) true else false; };\n", .want = null },
            // Trailing comment containing the word — matched by the old
            // substring test, must not now.
            .{ .src = "pub const E = struct { pub const consumable = false; // not true\n };\n", .want = false },
            // Absent decl entirely.
            .{ .src = "pub const E = struct { a: u8 = 0 };\n", .want = null },
        };
        for (cases) |c| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const decls = try generator.pack_manifest.parse.parseStructFile(arena.allocator(), c.src);
            try std.testing.expectEqual(@as(usize, 1), decls.len);
            try std.testing.expectEqual(c.want, decls[0].consumable);
        }
    }

    test "an unresolved consumable renders as UNKNOWN, not as a notification" {
        // Saying "notification" for an expression we did not evaluate would
        // be a confident wrong answer on exactly the path where a consumable
        // event behaves unexpectedly.
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const decls = try generator.pack_manifest.parse.parseStructFile(arena.allocator(),
            "pub const E = struct { pub const consumable = !true; };\n");
        try std.testing.expectEqual(@as(?bool, null), decls[0].consumable);
    }

    test "consumable is read from the payload, and drives the order-matters claim" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try stageFixture(&tmp);
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const report = try buildIn(arena, dir, baseCfg(&.{}));

        try std.testing.expectEqual(@as(?bool, true), report.eventByTag("urgent").?.consumable);
        // No `consumable` decl at all — absent, therefore unresolved rather
        // than a confident `false` (#726 review).
        try std.testing.expectEqual(@as(?bool, null), report.eventByTag("pulse").?.consumable);

        var aw: std.Io.Writer.Allocating = .init(arena);
        try hook_routes.writeText(&aw.writer, report, .{ .event = "urgent" });
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "CONSUMABLE") != null);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "WHETHER a later listener runs") != null);
    }

    test "delivery mode is a property of the call site, not the event" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try stageFixture(&tmp);
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const report = try buildIn(arena, dir, baseCfg(&.{}));

        const pulse = report.eventByTag("pulse").?;
        try std.testing.expectEqual(@as(usize, 1), pulse.emitters.len);
        try std.testing.expectEqualStrings("scripts/playing/10_emitter.zig", pulse.emitters[0].site);
        try std.testing.expectEqual(hook_routes.model.Delivery.buffered, pulse.emitters[0].delivery);

        // Same file, same frame, different delivery — which is why the
        // mode lives on the emitter and not on the event.
        const urgent = report.eventByTag("urgent").?;
        try std.testing.expectEqual(@as(usize, 1), urgent.emitters.len);
        try std.testing.expectEqual(hook_routes.model.Delivery.sync, urgent.emitters[0].delivery);
    }

    test "unresolved static information is stated, not silently dropped" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try stageFixture(&tmp);
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const report = try buildIn(arena, dir, baseCfg(&.{}));

        // No engine package was given, so the lifecycle union is unread.
        // The report must SAY that rather than let a reader conclude the
        // engine declares no lifecycle events.
        try std.testing.expect(!report.resolution.engine_hook_payload);
        try std.testing.expect(report.resolution.emit_sites_scanned);

        // A plugin event's payload lives in the provider's `Events` block,
        // which this report does not walk — `resolved = false`, not an
        // empty field list that would read as "no fields".
        try std.testing.expect(!report.eventByTag("box2d__collision_begin").?.payload.resolved);

        var aw: std.Io.Writer.Allocating = .init(arena);
        try hook_routes.writeText(&aw.writer, report, .{});
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "WHAT THIS REPORT DOES NOT KNOW") != null);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "engine lifecycle events") != null);
    }
};

pub const MACHINE_CONTRACT = struct {
    test "the JSON round-trips through the typed model" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try stageFixture(&tmp);
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const report = try buildIn(arena, dir, baseCfg(&.{.{ .handler = "hooks/z_second", .rank = 5 }}));
        var aw: std.Io.Writer.Allocating = .init(arena);
        try hook_routes.writeJson(&aw.writer, report);

        // This is the shape labelle-engine#858 will parse. Every join key
        // the trace needs must survive: receiver id + order, event tag,
        // and the listener edge between them.
        const back = try hook_routes.parseReport(arena, aw.written());
        try std.testing.expectEqualStrings(hook_routes.SCHEMA, back.schema);
        try std.testing.expectEqualStrings("routes-fixture", back.project);
        try std.testing.expectEqual(report.receivers.len, back.receivers.len);
        for (report.receivers, back.receivers) |a, b| {
            try std.testing.expectEqualStrings(a.id, b.id);
            try std.testing.expectEqual(a.order, b.order);
            try std.testing.expectEqual(a.rank, b.rank);
            try std.testing.expectEqual(a.rank_declared, b.rank_declared);
            try std.testing.expectEqual(a.baseline, b.baseline);
            try std.testing.expectEqual(a.kind, b.kind);
        }
        const pulse = back.eventByTag("pulse").?;
        try std.testing.expectEqual(@as(usize, 3), pulse.listeners.len);
        try std.testing.expectEqualStrings("hooks/z_second", back.receivers[0].id);

        // …and the human form renders from the PARSED model, so a field
        // the JSON failed to carry would show up as a hole in the text.
        var text: std.Io.Writer.Allocating = .init(arena);
        try hook_routes.writeText(&text.writer, back, .{});
        try std.testing.expect(std.mem.indexOf(u8, text.written(), "hooks/z_second") != null);
        try std.testing.expect(std.mem.indexOf(u8, text.written(), "citizens__needs_low") != null);
    }

    test "the JSON is byte-identical across builds of the same project" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try stageFixture(&tmp);
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const cfg = baseCfg(&.{});
        var first: std.Io.Writer.Allocating = .init(arena);
        try hook_routes.writeJson(&first.writer, try buildIn(arena, dir, cfg));
        var second: std.Io.Writer.Allocating = .init(arena);
        try hook_routes.writeJson(&second.writer, try buildIn(arena, dir, cfg));

        // No timestamp, no host paths, events sorted by tag: re-running
        // `generate` on unchanged input must not produce a diff, or the
        // sidecar becomes churn in every commit.
        try std.testing.expectEqualStrings(first.written(), second.written());
        try std.testing.expect(std.mem.indexOf(u8, first.written(), dir) == null);
    }

    test "the sidecar written by generate reads back through readSidecar" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try stageFixture(&tmp);
        const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(dir);

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        try hook_routes.emitSidecar(allocator, dir, inputs(dir, baseCfg(&.{})));
        const back = (try hook_routes.readSidecar(arena, dir)).?;
        try std.testing.expectEqualStrings(hook_routes.SCHEMA, back.schema);
        try std.testing.expectEqual(@as(usize, 4), back.receivers.len);
        try std.testing.expectEqualStrings("scripts/flows/hit_counter", back.receivers[3].id);

        // A missing sidecar is a null, not an error to decode — that is
        // what lets `routes` say "run generate first".
        var empty = std.testing.tmpDir(.{});
        defer empty.cleanup();
        const empty_dir = try empty.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        defer allocator.free(empty_dir);
        try std.testing.expect((try hook_routes.readSidecar(arena, empty_dir)) == null);
    }
};

// zspec drives the suites above; without this the nested `test` decls are
// never analyzed and the whole file passes vacuously.
test {
    zspec.runAll(@This());
}
