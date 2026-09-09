//! The hook ordering contract — labelle-assembler#723, child of the
//! hooks epic labelle-engine#854. Design doc:
//! `docs/design/hook-handler-ordering.md`.
//!
//! What these tests pin, and why each matters downstream:
//!
//!   * **The default sequence is unchanged.** A project that declares no
//!     ordering must generate exactly what the pre-#723 assembler did.
//!     Proven two ways: against the documented baseline (root hooks →
//!     pack hooks → flow tail), and by BYTE-COMPARING a no-declaration
//!     generate against one whose `.hooks.order` assigns rank 0 — the
//!     opt-in must be a no-op at its neutral value.
//!   * **Ranks cross group boundaries.** A pack hook or a flow handler
//!     can be promoted ahead of a game-root hook. Without this the
//!     contract would be "priority within a subgroup", the exact thing
//!     the issue says not to ship silently.
//!   * **Declarations perturb, they do not reshuffle.** Undeclared
//!     receivers keep their relative order, so ordering two handlers of
//!     one event cannot reorder the handlers of an unrelated event.
//!   * **Types and instances stay index-aligned.** `MergeHooks.emit`
//!     looks each receiver up by tuple position, so the `GameHooks`
//!     type tuple and the `hooks_init` pointer tuple disagreeing would
//!     mis-dispatch every event.
//!   * **Bad declarations are hard errors**, not silent no-ops.
//!
//! Tests drive the real `generateMainZigFromTemplate` against a tiny
//! template carrying only the hook holes, and assert on the emitted
//! text — the same depth as `test/flow_scanner/handler_wiring_tests.zig`,
//! whose pre-existing flow-tail priority tests are this change's
//! regression proof for the baseline's group 3.

const std = @import("std");
const zspec = @import("zspec");
const generator = @import("generator");

const ScriptEntry = generator.script_scanner.ScriptScanner.ScriptEntry;
const ProjectConfig = generator.ProjectConfig;
const PackScan = generator.PackScan;

/// Only the hook holes — `game_hooks_block` (the `MergeHooks` type
/// tuple) and `hooks_init_block` (the instance + pointer tuple). Keeping
/// the template minimal makes `indexOf` assertions unambiguous.
const hooks_tmpl =
    \\const std = @import("std");
    \\{{hook_imports_block}}{{all_hook_payloads_block}}{{game_hooks_block}}const lifecycle_marker = struct {
    \\    pub fn main() !void {
    \\{{hooks_init_block}}
    \\    }
    \\};
    \\{{lifecycle}}
;

const tiny_lifecycle =
    \\// trailing — body is the embedded `lifecycle_marker.main`.
    \\
;

fn baseCfg() ProjectConfig {
    return .{
        .y_axis = .up,
        .name = "test-game",
        .backend = .raylib,
        .ecs = .mock,
        // A pack is consumed as a plugin, so the pack-hook cases need a
        // declared plugin for the pack to hang off.
        .plugins = &.{.{ .name = "citizens", .repo = "@packs/citizens" }},
    };
}

/// One flow handler entry. `has_event_handler` is what marks an entry as
/// contributing a `FlowEventHandler` receiver.
fn flowEntry(rel_path: []const u8, sort_order: ?u32, priority: ?i32) ScriptEntry {
    return .{
        .name = rel_path,
        .filename = rel_path,
        .states = &.{},
        .sort_order = sort_order,
        .subdir = null,
        .rel_path = rel_path,
        .has_event_handler = true,
        .event_priority = priority,
    };
}

fn gen(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    hook_names: []const []const u8,
    packs: []const PackScan,
    flows: []const ScriptEntry,
) ![]const u8 {
    generator.main_template.pack_scans = packs;
    defer generator.main_template.pack_scans = &.{};

    return generator.generateMainZigFromTemplate(
        allocator,
        hooks_tmpl,
        cfg,
        tiny_lifecycle,
        flows,
        &.{}, // prefab_names
        &.{}, // jsonc_scene_names
        &.{}, // scene_manifests
        &.{}, // component_names
        hook_names,
        &.{}, // event_names
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

/// Position of `needle` in `hay`; fails the test if absent, so a
/// missing receiver reads as a clear failure rather than an `orelse`
/// unwrap panic.
fn at(hay: []const u8, needle: []const u8) !usize {
    return std.mem.indexOf(u8, hay, needle) orelse {
        std.debug.print("expected to find `{s}` in:\n{s}\n", .{ needle, hay });
        return error.NotFound;
    };
}

const citizens_pack: PackScan = .{
    .name = "citizens",
    .import_prefix = "packs/citizens",
    .component_names = &.{},
    .event_names = &.{},
    .prefab_names = &.{},
    .hook_names = &.{"needs_hooks"},
};

pub const DEFAULT_ORDER = struct {
    test "no declaration → the documented baseline: root hooks, then pack hooks, then flows" {
        const allocator = std.testing.allocator;
        const main_zig = try gen(
            allocator,
            baseCfg(),
            // `linkAndScan` hands hook stems over already sorted; the
            // baseline promises that order is preserved.
            &.{ "animation_hooks", "ui_kit_hooks" },
            &.{citizens_pack},
            &.{flowEntry("flows/hit_counter.zig", null, null)},
        );
        defer allocator.free(main_zig);

        // Instance-pointer tuple: root → pack → flow.
        const anim = try at(main_zig, "&animation_u_hooks_inst,");
        const ui = try at(main_zig, "&ui_u_kit_u_hooks_inst,");
        const pack = try at(main_zig, "&citizens__needs_u_hooks_inst,");
        const flow = try at(main_zig, "&flows_s_hit_u_counter_flow_handler,");
        try std.testing.expect(anim < ui);
        try std.testing.expect(ui < pack);
        try std.testing.expect(pack < flow);

        // An undeclared project must NOT grow the order comment — that
        // suppression is what keeps its output byte-identical to the
        // pre-#723 assembler.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "Hook receiver dispatch order") == null);
    }

    test "a rank-0 declaration generates byte-identical output to declaring nothing" {
        // THE backward-compatibility proof. `.hooks.order` at its
        // neutral value is a pure no-op on the sequence: same bytes,
        // modulo the order comment the declaration itself asks for.
        const allocator = std.testing.allocator;
        const hooks: []const []const u8 = &.{ "animation_hooks", "ui_kit_hooks" };
        const flows: []const ScriptEntry = &.{flowEntry("flows/hit_counter.zig", null, null)};

        const undeclared = try gen(allocator, baseCfg(), hooks, &.{citizens_pack}, flows);
        defer allocator.free(undeclared);

        var cfg = baseCfg();
        cfg.hooks = .{ .order = &.{
            .{ .handler = "hooks/animation_hooks", .rank = 0 },
            .{ .handler = "packs/citizens/hooks/needs_hooks", .rank = 0 },
        } };
        const declared = try gen(allocator, cfg, hooks, &.{citizens_pack}, flows);
        defer allocator.free(declared);

        // Strip the rendered order comment (present only in the
        // declared build) and the two files must match byte for byte.
        const marker = "// Hook receiver dispatch order";
        const start = try at(declared, marker);
        const end_marker = "// (* = rank declared in project.labelle `.hooks.order`)\n";
        const end = (try at(declared, end_marker)) + end_marker.len;
        const stripped = try std.mem.concat(allocator, u8, &.{ declared[0..start], declared[end..] });
        defer allocator.free(stripped);

        try std.testing.expectEqualStrings(undeclared, stripped);
    }

    test "flow event_priority keeps its subgroup scope when nothing is declared" {
        // Regression guard for the composition rule (design doc §4.3):
        // `event_priority` shapes the BASELINE flow tail only. A flow
        // with priority 100 sorts ahead of other flows and still lands
        // behind every native hook — promoting it across the boundary is
        // `.hooks.order`'s job, not this field's.
        const allocator = std.testing.allocator;
        const main_zig = try gen(
            allocator,
            baseCfg(),
            &.{"animation_hooks"},
            &.{},
            &.{
                flowEntry("flows/01_low.zig", 1, 10),
                flowEntry("flows/02_high.zig", 2, 100),
                flowEntry("flows/notify.zig", null, null),
            },
        );
        defer allocator.free(main_zig);

        const hook = try at(main_zig, "&animation_u_hooks_inst,");
        const high = try at(main_zig, "&flows_s_02_u_high_flow_handler,");
        const low = try at(main_zig, "&flows_s_01_u_low_flow_handler,");
        const notify = try at(main_zig, "&flows_s_notify_flow_handler,");
        try std.testing.expect(hook < high); // subgroup scope, not global
        try std.testing.expect(high < low); // priority descending
        try std.testing.expect(low < notify); // priority-set before the tail
    }
};

pub const EXPLICIT_ORDER = struct {
    test "a positive rank promotes a pack hook ahead of the game-root hooks" {
        const allocator = std.testing.allocator;
        var cfg = baseCfg();
        cfg.hooks = .{ .order = &.{
            .{ .handler = "packs/citizens/hooks/needs_hooks", .rank = 100 },
        } };
        const main_zig = try gen(
            allocator,
            cfg,
            &.{ "animation_hooks", "ui_kit_hooks" },
            &.{citizens_pack},
            &.{},
        );
        defer allocator.free(main_zig);

        const pack = try at(main_zig, "&citizens__needs_u_hooks_inst,");
        const anim = try at(main_zig, "&animation_u_hooks_inst,");
        const ui = try at(main_zig, "&ui_u_kit_u_hooks_inst,");
        try std.testing.expect(pack < anim);
        // The two undeclared root hooks keep their baseline order.
        try std.testing.expect(anim < ui);
    }

    test "a negative rank demotes a game-root hook behind every undeclared receiver" {
        const allocator = std.testing.allocator;
        var cfg = baseCfg();
        cfg.hooks = .{ .order = &.{
            .{ .handler = "hooks/animation_hooks", .rank = -10 },
        } };
        const main_zig = try gen(
            allocator,
            cfg,
            &.{ "animation_hooks", "ui_kit_hooks" },
            &.{citizens_pack},
            &.{flowEntry("flows/hit_counter.zig", null, null)},
        );
        defer allocator.free(main_zig);

        const ui = try at(main_zig, "&ui_u_kit_u_hooks_inst,");
        const pack = try at(main_zig, "&citizens__needs_u_hooks_inst,");
        const flow = try at(main_zig, "&flows_s_hit_u_counter_flow_handler,");
        const anim = try at(main_zig, "&animation_u_hooks_inst,");
        try std.testing.expect(ui < pack);
        try std.testing.expect(pack < flow);
        try std.testing.expect(flow < anim); // demoted past the flow tail
    }

    test "mixed groups: a flow handler can be ranked ahead of root and pack hooks" {
        // The cross-group case `event_priority` structurally cannot
        // express — a flow handler winning first refusal on a consumable
        // event over a native hook.
        const allocator = std.testing.allocator;
        var cfg = baseCfg();
        cfg.hooks = .{ .order = &.{
            .{ .handler = "scripts/flows/hit_counter", .rank = 50 },
            .{ .handler = "packs/citizens/hooks/needs_hooks", .rank = 20 },
        } };
        const main_zig = try gen(
            allocator,
            cfg,
            &.{"animation_hooks"},
            &.{citizens_pack},
            &.{flowEntry("flows/hit_counter.zig", null, null)},
        );
        defer allocator.free(main_zig);

        const flow = try at(main_zig, "&flows_s_hit_u_counter_flow_handler,");
        const pack = try at(main_zig, "&citizens__needs_u_hooks_inst,");
        const anim = try at(main_zig, "&animation_u_hooks_inst,");
        try std.testing.expect(flow < pack); // 50 > 20
        try std.testing.expect(pack < anim); // 20 > 0
    }

    test "equal ranks fall back to baseline order" {
        const allocator = std.testing.allocator;
        var cfg = baseCfg();
        cfg.hooks = .{ .order = &.{
            // Declared in the REVERSE of baseline order, to prove the
            // tie-break is the baseline and not declaration order.
            .{ .handler = "hooks/zulu_hooks", .rank = 7 },
            .{ .handler = "hooks/alpha_hooks", .rank = 7 },
        } };
        const main_zig = try gen(allocator, cfg, &.{ "alpha_hooks", "zulu_hooks" }, &.{}, &.{});
        defer allocator.free(main_zig);

        const alpha = try at(main_zig, "&alpha_u_hooks_inst,");
        const zulu = try at(main_zig, "&zulu_u_hooks_inst,");
        try std.testing.expect(alpha < zulu);
    }

    test "declaring one receiver leaves every other pair's relative order intact" {
        // "Ordering handlers for one event does not unexpectedly reorder
        // unrelated events" — with a single global tuple the honest form
        // of that guarantee is minimal perturbation: only the named
        // receiver moves.
        const allocator = std.testing.allocator;
        const hooks: []const []const u8 = &.{ "a_hooks", "b_hooks", "c_hooks", "d_hooks" };
        var cfg = baseCfg();
        cfg.hooks = .{ .order = &.{.{ .handler = "hooks/d_hooks", .rank = 1 }} };
        const main_zig = try gen(allocator, cfg, hooks, &.{}, &.{});
        defer allocator.free(main_zig);

        const d = try at(main_zig, "&d_u_hooks_inst,");
        const a = try at(main_zig, "&a_u_hooks_inst,");
        const b = try at(main_zig, "&b_u_hooks_inst,");
        const c = try at(main_zig, "&c_u_hooks_inst,");
        try std.testing.expect(d < a);
        try std.testing.expect(a < b);
        try std.testing.expect(b < c);
    }

    test "the receiver-type tuple and the instance tuple stay index-aligned" {
        // `MergeHooks.emit` looks each receiver up by tuple position, so
        // the two tuples disagreeing would mis-dispatch every event.
        const allocator = std.testing.allocator;
        var cfg = baseCfg();
        cfg.hooks = .{ .order = &.{
            .{ .handler = "scripts/flows/hit_counter", .rank = 100 },
            .{ .handler = "hooks/animation_hooks", .rank = -1 },
        } };
        const main_zig = try gen(
            allocator,
            cfg,
            &.{ "animation_hooks", "ui_kit_hooks" },
            &.{citizens_pack},
            &.{flowEntry("flows/hit_counter.zig", null, null)},
        );
        defer allocator.free(main_zig);

        // Expected sequence: flow (100) → ui_kit (0) → pack (0) → animation (-1).
        const t_flow = try at(main_zig, "*@import(\"scripts/flows/hit_counter.zig\").FlowEventHandler,");
        const t_ui = try at(main_zig, "*ui_u_kit_u_hooks.UiKitHooks,");
        const t_pack = try at(main_zig, "*citizens__needs_u_hooks.NeedsHooks,");
        const t_anim = try at(main_zig, "*animation_u_hooks.AnimationHooks,");
        try std.testing.expect(t_flow < t_ui);
        try std.testing.expect(t_ui < t_pack);
        try std.testing.expect(t_pack < t_anim);

        const i_flow = try at(main_zig, "&flows_s_hit_u_counter_flow_handler,");
        const i_ui = try at(main_zig, "&ui_u_kit_u_hooks_inst,");
        const i_pack = try at(main_zig, "&citizens__needs_u_hooks_inst,");
        const i_anim = try at(main_zig, "&animation_u_hooks_inst,");
        try std.testing.expect(i_flow < i_ui);
        try std.testing.expect(i_ui < i_pack);
        try std.testing.expect(i_pack < i_anim);
    }

    test "the resolved order is rendered as a comment above GameHooks" {
        // The generated file explains itself: #724's inspector and a
        // reader of the generated code see the same sequence.
        const allocator = std.testing.allocator;
        var cfg = baseCfg();
        cfg.hooks = .{ .order = &.{.{ .handler = "packs/citizens/hooks/needs_hooks", .rank = 100 }} };
        const main_zig = try gen(allocator, cfg, &.{"animation_hooks"}, &.{citizens_pack}, &.{});
        defer allocator.free(main_zig);

        const comment = try at(main_zig, "// Hook receiver dispatch order");
        const decl = try at(main_zig, "const GameHooks = engine.MergeHooks(");
        try std.testing.expect(comment < decl);
        // Ranked entry first, flagged as declared; the undeclared root
        // hook follows at rank 0.
        const ranked = try at(main_zig, "//   [0] rank   100 * packs/citizens/hooks/needs_hooks\n");
        const plain = try at(main_zig, "//   [1] rank     0   hooks/animation_hooks\n");
        try std.testing.expect(ranked < plain);
    }
};

pub const RECEIVER_ID_TABLE = struct {
    test "hook_receiver_ids is index-aligned with the GameHooks tuple (#727)" {
        // THE deliverable of #727. `MergeHooks.emit` walks receivers by
        // TUPLE POSITION, so a tracer labelling frame `i` with
        // `hook_receiver_ids[i]` gets the same string the route inspector
        // prints — identity shared by construction rather than by two
        // derivations happening to agree.
        //
        // Asserting the ids exist is not enough: the alignment is the
        // contract, so this walks both lists together and compares
        // position by position.
        const allocator = std.testing.allocator;
        var cfg = baseCfg();
        // A declared rank, so the table has to follow the RESOLVED order
        // and not the discovery order — the case where a naive
        // implementation emits ids in the wrong sequence.
        cfg.hooks = .{ .order = &.{.{ .handler = "packs/citizens/hooks/needs_hooks", .rank = 100 }} };
        const main_zig = try gen(allocator, cfg, &.{"animation_hooks"}, &.{citizens_pack}, &.{});
        defer allocator.free(main_zig);

        const ids_at = try at(main_zig, "pub const hook_receiver_ids = [_][]const u8{");
        const tuple_at = try at(main_zig, "const GameHooks = engine.MergeHooks(");
        try std.testing.expect(tuple_at < ids_at);

        // The resolved order for this config: ranked pack hook first.
        const expected = [_][]const u8{
            "packs/citizens/hooks/needs_hooks",
            "hooks/animation_hooks",
        };
        // Ids appear in the table in exactly that sequence…
        var cursor = ids_at;
        for (expected) |want| {
            const quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{want});
            defer allocator.free(quoted);
            const found = std.mem.indexOfPos(u8, main_zig, cursor, quoted) orelse
                return error.IdMissingFromTable;
            cursor = found + quoted.len;
        }

        // …and the SAME sequence in the dispatch-order comment, which is
        // what the inspector reports. If these two ever disagree, a trace
        // and a route report label the same receiver differently.
        const ranked_comment = try at(main_zig, "//   [0] rank   100 * packs/citizens/hooks/needs_hooks\n");
        const plain_comment = try at(main_zig, "//   [1] rank     0   hooks/animation_hooks\n");
        try std.testing.expect(ranked_comment < plain_comment);
    }

    /// Everything between `.{` and `}` of the emitted `MergeHooks` call,
    /// split into one entry per receiver — the ACTUAL tuple, read out of
    /// the generated source.
    fn tupleEntries(aa: std.mem.Allocator, main_zig: []const u8) ![]const []const u8 {
        const marker = "const GameHooks = engine.MergeHooks(AllHookPayloads, .{";
        const start = (std.mem.indexOf(u8, main_zig, marker) orelse
            return error.TupleMissing) + marker.len;
        const end = std.mem.indexOfPos(u8, main_zig, start, "});") orelse
            return error.TupleUnterminated;
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, main_zig[start..end], ',');
        while (it.next()) |raw| {
            const e = std.mem.trim(u8, raw, " \t\r\n");
            if (e.len > 0) try out.append(aa, e);
        }
        return out.toOwnedSlice(aa);
    }

    /// The quoted strings of the emitted `hook_receiver_ids`, in order.
    fn tableEntries(aa: std.mem.Allocator, main_zig: []const u8) ![]const []const u8 {
        const marker = "pub const hook_receiver_ids = [_][]const u8{";
        const start = (std.mem.indexOf(u8, main_zig, marker) orelse
            return error.TableMissing) + marker.len;
        const end = std.mem.indexOfPos(u8, main_zig, start, "};") orelse
            return error.TableUnterminated;
        var out: std.ArrayList([]const u8) = .empty;
        var rest = main_zig[start..end];
        while (std.mem.indexOfScalar(u8, rest, '"')) |open| {
            const after = rest[open + 1 ..];
            const close = std.mem.indexOfScalar(u8, after, '"') orelse break;
            try out.append(aa, after[0..close]);
            rest = after[close + 1 ..];
        }
        return out.toOwnedSlice(aa);
    }

    /// `needs_hooks` -> `NeedsHooks`. The emitter's snake -> Pascal rule
    /// for a receiver's type name, reimplemented here on purpose: calling
    /// the production helper would make the test agree with the emitter by
    /// construction even if the rule itself drifted under both.
    fn pascalOf(aa: std.mem.Allocator, stem: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var upper_next = true;
        for (stem) |c| {
            if (c == '_') {
                upper_next = true;
                continue;
            }
            try out.append(aa, if (upper_next) std.ascii.toUpper(c) else c);
            upper_next = false;
        }
        return out.toOwnedSlice(aa);
    }

    test "the table is aligned with the EMITTED TUPLE, not merely with the order comment (#727)" {
        // The integration proof. The sibling test above compares the table
        // against the dispatch-order COMMENT, which is a second rendering
        // of the same resolved plan — so if tuple emission and table
        // emission ever diverged, the comment could still agree with the
        // table while the tuple, the thing `MergeHooks.emit` actually
        // walks, disagreed with both. That is the failure the engine would
        // then inherit: `hook_receiver_ids[i]` naming a different receiver
        // than tuple slot `i`.
        //
        // So this reads BOTH lists out of the generated source and matches
        // them position by position. No ordering comment is consulted.
        const allocator = std.testing.allocator;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var cfg = baseCfg();
        // A declared rank so resolved order differs from discovery order —
        // otherwise both lists could be emitted in discovery order and
        // still agree, proving nothing about alignment.
        cfg.hooks = .{ .order = &.{.{ .handler = "packs/citizens/hooks/needs_hooks", .rank = 100 }} };
        const main_zig = try gen(allocator, cfg, &.{"animation_hooks"}, &.{citizens_pack}, &.{});
        defer allocator.free(main_zig);

        const tuple = try tupleEntries(aa, main_zig);
        const table = try tableEntries(aa, main_zig);

        // A vacuous pass guard: with zero or one receiver, "aligned" is
        // true no matter what the emitter does.
        try std.testing.expect(tuple.len >= 2);
        try std.testing.expectEqual(tuple.len, table.len);

        for (tuple, table, 0..) |tuple_entry, id, i| {
            // The tuple entry is a type expression and the table entry is
            // the assembler's id — two spellings of one receiver:
            //
            //   table:  packs/citizens/hooks/needs_hooks
            //   tuple: *citizens__needs_u_hooks.NeedsHooks
            //
            // The MODULE ident is escaped (`_` becomes `_u_`, keeping the
            // path-to-ident mapping injective), so it is not a substring of
            // the id. The TYPE name is the stable link: the emitter derives
            // it from the same file stem by the snake -> Pascal rule, so
            // `.NeedsHooks` must terminate the tuple entry whose table id
            // ends in `needs_hooks`.
            const stem = if (std.mem.lastIndexOfScalar(u8, id, '/')) |slash|
                id[slash + 1 ..]
            else
                id;
            const pascal = try pascalOf(aa, stem);
            const want = try std.fmt.allocPrint(aa, ".{s}", .{pascal});
            if (!std.mem.endsWith(u8, tuple_entry, want)) {
                std.debug.print(
                    "slot {d}: table says `{s}` (expects tuple type `{s}`) but the tuple has `{s}`\n",
                    .{ i, id, want, tuple_entry },
                );
                return error.TableTupleMisaligned;
            }
        }

        // And the ranked receiver really did move: slot 0 is the pack hook,
        // which is NOT its discovery position. Without this the loop above
        // would pass on a build where ranking silently stopped working.
        try std.testing.expectEqualStrings("packs/citizens/hooks/needs_hooks", table[0]);
        try std.testing.expectEqualStrings("hooks/animation_hooks", table[1]);
    }

    test "a project with no hooks emits no table rather than an empty one" {
        const allocator = std.testing.allocator;
        const main_zig = try gen(allocator, baseCfg(), &.{}, &.{}, &.{});
        defer allocator.free(main_zig);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "hook_receiver_ids") == null);
    }
};

pub const DIAGNOSTICS = struct {
    test "an unknown handler is a hard error, not a silent no-op" {
        // A silently ignored ordering declaration is the exact failure
        // this contract exists to remove: a hook file renamed out from
        // under an `.order` entry must stop the build.
        const allocator = std.testing.allocator;
        var cfg = baseCfg();
        cfg.hooks = .{ .order = &.{.{ .handler = "hooks/typo_hooks", .rank = 1 }} };
        try std.testing.expectError(
            error.UnknownHookOrderHandler,
            gen(allocator, cfg, &.{"animation_hooks"}, &.{}, &.{}),
        );
    }

    test "naming the same receiver twice is a hard error" {
        const allocator = std.testing.allocator;
        var cfg = baseCfg();
        cfg.hooks = .{ .order = &.{
            .{ .handler = "hooks/animation_hooks", .rank = 1 },
            .{ .handler = "hooks/animation_hooks", .rank = 2 },
        } };
        try std.testing.expectError(
            error.DuplicateHookOrderHandler,
            gen(allocator, cfg, &.{"animation_hooks"}, &.{}, &.{}),
        );
    }

    test "a project with no hook receivers at all rejects a declaration too" {
        const allocator = std.testing.allocator;
        var cfg = baseCfg();
        cfg.hooks = .{ .order = &.{.{ .handler = "hooks/anything", .rank = 1 }} };
        try std.testing.expectError(
            error.UnknownHookOrderHandler,
            gen(allocator, cfg, &.{}, &.{}, &.{}),
        );
    }
};

pub const RECEIVER_IDENTITY = struct {
    test "buildReceiverPlan exposes the stable ids #724 and #858 key on" {
        // The identity contract, asserted directly on the exported API
        // rather than through emitted text: source-oriented paths, one
        // per group, in resolved dispatch order.
        const allocator = std.testing.allocator;
        var cfg = baseCfg();
        cfg.hooks = .{ .order = &.{.{ .handler = "scripts/flows/hit_counter", .rank = 5 }} };

        var plan = try generator.buildReceiverPlan(
            allocator,
            cfg,
            &.{"animation_hooks"},
            &.{citizens_pack},
            &.{flowEntry("flows/hit_counter.zig", null, null)},
        );
        defer plan.deinit(allocator);

        try std.testing.expectEqual(@as(usize, 3), plan.receivers.len);

        try std.testing.expectEqualStrings("scripts/flows/hit_counter", plan.receivers[0].id);
        try std.testing.expectEqual(generator.ReceiverKind.flow_handler, plan.receivers[0].kind);
        try std.testing.expectEqual(@as(i32, 5), plan.receivers[0].rank);
        try std.testing.expect(plan.receivers[0].declared);

        try std.testing.expectEqualStrings("hooks/animation_hooks", plan.receivers[1].id);
        try std.testing.expectEqual(generator.ReceiverKind.root_hook, plan.receivers[1].kind);
        try std.testing.expect(!plan.receivers[1].declared);

        try std.testing.expectEqualStrings("packs/citizens/hooks/needs_hooks", plan.receivers[2].id);
        try std.testing.expectEqual(generator.ReceiverKind.pack_hook, plan.receivers[2].kind);

        // `baseline` survives the sort, so a report can explain WHY a
        // receiver sits where it does — not just where it landed.
        try std.testing.expectEqual(@as(usize, 2), plan.receivers[0].baseline);
        try std.testing.expectEqual(@as(usize, 0), plan.receivers[1].baseline);
        try std.testing.expectEqual(@as(usize, 1), plan.receivers[2].baseline);
    }

    test "a nested hook stem keeps its subdirectory in the id" {
        // Ids are paths, so two hooks with the same basename in
        // different subdirs are distinguishable — the property that lets
        // `.hooks.order` name either one unambiguously.
        const allocator = std.testing.allocator;
        var plan = try generator.buildReceiverPlan(
            allocator,
            baseCfg(),
            &.{ "ui/toolbar", "world/toolbar" },
            &.{},
            &.{},
        );
        defer plan.deinit(allocator);

        try std.testing.expectEqualStrings("hooks/ui/toolbar", plan.receivers[0].id);
        try std.testing.expectEqualStrings("hooks/world/toolbar", plan.receivers[1].id);
    }
};

test {
    zspec.runAll(@This());
}
