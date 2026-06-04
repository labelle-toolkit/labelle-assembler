//! Recursively scan `<game>/scripts/flows/**` for `*.flow.jsonc`, emit
//! Zig sources via the `flow_codegen` sub-package, and stitch the
//! emitted files into the existing script-registry pipeline.
//!
//! The output files are written to `<target>/scripts/flows/<rel>.zig`,
//! where `<rel>` mirrors the source file's path under `scripts/flows/`
//! (subdirectories preserved — RFC FLOWS-JSONC §5 makes flow discovery
//! a recursive scan). Because `<target>/scripts/` is a relative symlink
//! back into the game source tree (see `scanner.linkDir`), the
//! generated `.zig` ends up sitting next to its source `.flow.jsonc` on
//! disk — the same co-location convention plugin-shipped scripts use
//! today (RFC plugin controllers §2). Authors are expected to
//! `.gitignore` the emitted files; the assembler treats them as freshly
//! regenerated on every `zig build generate` pass.
//!
//! Errors from `flow_codegen.flow_io.parseFlow` / `codegen.renderFlowZig`
//! are surfaced as `flows/<rel>.flow.jsonc: <err>` lines written
//! directly to stderr (matching the existing `main_zig.checkBasenameCollisions`
//! diagnostic style) and the typed error is returned to the caller, so a
//! malformed flow fails `generate` with a non-zero exit instead of
//! silently producing a stale `.zig`. Writing to stderr rather than
//! `std.log.err` keeps the Zig test runner from classifying expected
//! diagnostics as logged-error test failures.

const std = @import("std");
const flow_codegen = @import("flow_codegen");
const script_scanner = @import("script_scanner.zig");
const config = @import("config.zig");
const scan = @import("codegen/scan.zig");
const discovery = @import("flow_catalog/discovery.zig");

const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;
const PluginFlowNode = scan.PluginFlowNode;
const CustomNodeRegistry = flow_codegen.codegen.CustomNodeRegistry;

/// File extension flow files carry on disk. RFC FLOWS-JSONC retires
/// `.flow.zon` in favour of `.flow.jsonc` — flows join scenes and
/// prefabs on the JSONC content side of the line.
const flow_ext = ".flow.jsonc";

/// Result of a flow scan. The arena owns every byte the synthetic
/// `ScriptEntry`s reference (their `filename` / `rel_path` slices),
/// so the caller's only cleanup responsibility is `deinit()`.
pub const FlowScanResult = struct {
    arena: std.heap.ArenaAllocator,
    /// Synthetic entries appended to the script scanner's existing
    /// list before `getEntries()` is captured. `rel_path` matches the
    /// on-disk layout `flows/<rel>.zig` so the existing AllScripts
    /// block emits `@import("scripts/flows/<rel>.zig")` unmodified.
    entries: []ScriptEntry,

    pub fn deinit(self: *FlowScanResult) void {
        self.arena.deinit();
    }
};

/// Recursively walk `<game_dir>/scripts/flows/**` for `*.flow.jsonc`
/// files. For each match: parse, codegen, write
/// `<target_dir>/scripts/flows/<rel>.zig`, and emit a `ScriptEntry`
/// pointing at it. The `<rel>` path mirrors the source's location under
/// `scripts/flows/`, so flows organised into subdirectories keep their
/// layout and never collide on the flat output name. Missing source
/// directory returns an empty result — projects without flows pay zero
/// cost.
pub fn scanAndEmit(
    allocator: std.mem.Allocator,
    game_dir: []const u8,
    target_dir: []const u8,
    flow_nodes: []const PluginFlowNode,
) !FlowScanResult {
    const io = config.globalIo();

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    // Build the `CustomNodeRegistry` flow-codegen consults to lower
    // `CustomNode` nodes (RFC-FLOW-VOCABULARY §1 + §5). Each discovered
    // plugin / game-script `FlowNode` maps its on-disk **dotted** name
    // (the `CustomNode.name` an author writes) → the qualified decl
    // (`<module>__<node>`) the assembler's `PluginFlowNodes` block
    // emits into `main.zig`. Without this every `CustomNode` reference
    // errors as `UnknownFlowNode` (labelle-assembler#238). The registry
    // + its key/value strings live in the result arena so they outlive
    // every `renderFlowZig` call below; the registry's own
    // `StringHashMap` allocates on the caller `allocator` and is freed
    // before return (the entries it borrows are arena-owned).
    var registry = CustomNodeRegistry.init(allocator);
    defer registry.deinit();
    for (flow_nodes) |fn_| {
        // Dotted name: plugins use their `module_import_path` verbatim
        // (already the dotted prefix, e.g. `box2d`); game scripts use
        // the `scriptModuleLabel` form (`flows/hit_counter.zig` →
        // `flows.hit_counter`) so the `<module>.<node>` key matches the
        // editor's on-disk `CustomNode.name`.
        const module_label = if (fn_.is_script)
            try discovery.scriptModuleLabel(arena_alloc, fn_.module_import_path)
        else
            fn_.module_import_path;
        const dotted = try std.fmt.allocPrint(arena_alloc, "{s}.{s}", .{ module_label, fn_.node_name });
        // Qualified decl name — bit-identical to what
        // `writePluginFlowNodesBlock` emits (`<module_sanitized>__<node>`)
        // so flow-codegen's `game_mod.PluginFlowNodes.<qualified>.impl`
        // call site resolves.
        const qualified = try std.fmt.allocPrint(arena_alloc, "{s}__{s}", .{ fn_.module_sanitized, fn_.node_name });
        try registry.add(dotted, .{ .qualified = qualified, .is_void = fn_.is_void });
    }

    var entries: std.ArrayList(ScriptEntry) = .empty;

    const src_flows = try std.fs.path.join(allocator, &.{ game_dir, "scripts", "flows" });
    defer allocator.free(src_flows);

    var src_dir = std.Io.Dir.cwd().openDir(io, src_flows, .{ .iterate = true }) catch |err| switch (err) {
        // Empty flows/ dir is the common case for projects that don't
        // use the editor — silently no-op rather than forcing every
        // project to materialise the directory.
        error.FileNotFound => return .{
            .arena = arena,
            .entries = try entries.toOwnedSlice(arena_alloc),
        },
        else => return err,
    };
    defer src_dir.close(io);

    // Output dir — same path through the scripts/ symlink. `makePath`
    // is idempotent and creates the `flows/` directory next to the
    // game's `.flow.jsonc` sources when missing.
    const dst_flows = try std.fs.path.join(allocator, &.{ target_dir, "scripts", "flows" });
    defer allocator.free(dst_flows);
    try std.Io.Dir.cwd().createDirPath(io, dst_flows);

    // Stable iteration order — collect relative paths first, sort, then
    // process. Matters because the codegen step is allowed to fail and
    // we want the error message to be reproducible across runs. Paths
    // are relative to `scripts/flows/`, using `/` separators.
    var rel_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (rel_paths.items) |p| allocator.free(p);
        rel_paths.deinit(allocator);
    }

    // `std.Io.Dir.walk` yields every file in the subtree with a path
    // relative to the opened directory — exactly the recursive `**`
    // scan RFC FLOWS-JSONC §5 calls for.
    var walker = try src_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, flow_ext)) continue;
        // `entry.path` may use the host separator on Windows; normalise
        // to `/` so emitted import paths and identifiers stay portable.
        const rel = try allocator.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
        try rel_paths.append(allocator, rel);
    }
    std.mem.sort([]const u8, rel_paths.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    for (rel_paths.items) |rel| {
        // `rel` is `<subdir>/.../<stem>.flow.jsonc` relative to
        // `scripts/flows/`. Strip the double extension to get the
        // logical flow path; the basename of that is the flow's
        // display name (RFC FLOWS-JSONC §5: effective name defaults
        // to the filename basename).
        const rel_stem = rel[0 .. rel.len - flow_ext.len];
        const display_name = std.fs.path.basename(rel_stem);

        // Numeric-prefix sort key, mirroring the convention in
        // `script_scanner.zig:3-13` and the resolution recorded as
        // RFC-PLUGIN-EVENTS O3: `01_input.flow.jsonc` runs before
        // `02_count.flow.jsonc`, unprefixed files sort alphabetically
        // in the tail. The previous `.sort_order = null` parked every
        // flow in the unnumbered tail and sorted by raw `rel` string,
        // which got `10_x` before `2_x`. Pulling the prefix out of the
        // *basename* (not the full `rel`) keeps the numeric range
        // per-flow rather than across subdirectories.
        //
        // `extractSortOrder` reads digits up to a single `_`
        // regardless of trailing extension, so feeding the
        // `display_name` (already `<stem>` minus `.flow.jsonc`) works
        // without a flow-specific variant of `stripPrefixAndExtension`
        // — `02_foo` returns 2 the same way `02_foo.zig` does.
        const sort_order = script_scanner.extractSortOrder(display_name);

        const src_path = try std.fs.path.join(allocator, &.{ src_flows, rel });
        defer allocator.free(src_path);

        var loaded = flow_codegen.flow_io.loadFromFile(io, allocator, src_path) catch |err| {
            reportFlowError(rel, err);
            return err;
        };
        defer loaded.deinit();

        const generated = flow_codegen.codegen.renderFlowZig(
            allocator,
            loaded.flow,
            .{ .flow_name = display_name, .custom_nodes = &registry },
        ) catch |err| {
            reportFlowError(rel, err);
            return err;
        };
        defer allocator.free(generated);

        // Write `<target>/scripts/flows/<rel_stem>.zig`, truncating an
        // earlier emission. The `<rel_stem>` is reconstituted in the
        // arena so the synthetic ScriptEntry can borrow stable lifetime
        // from it without juggling separate ownership of `rel` (which
        // lives on the scratch allocator).
        const rel_stem_owned = try arena_alloc.dupe(u8, rel_stem);
        const name_owned = try arena_alloc.dupe(u8, display_name);
        const out_rel_zig = try std.fmt.allocPrint(arena_alloc, "{s}.zig", .{rel_stem_owned});
        const rel_path = try std.fmt.allocPrint(arena_alloc, "flows/{s}", .{out_rel_zig});

        const dst_path = try std.fs.path.join(allocator, &.{ dst_flows, out_rel_zig });
        defer allocator.free(dst_path);

        // Nested flow sources need their mirrored output subdirectory
        // created before the write — flat flows hit a `makePath` no-op.
        if (std.fs.path.dirname(dst_path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst_path, .data = generated });

        // Flows aren't state-gated in v1 — they always run. Match the
        // global-script shape (`states = &.{}`, `subdir = null`) so
        // the existing AllScripts emit picks them up via the simple
        // import branch rather than the state-wrapper branch.
        //
        // `filename` is the display/debug field — use the full mirrored
        // relative path (`enemy/patrol.zig`, not the bare `patrol.zig`
        // basename) so two flows that share a stem across subdirectories
        // stay distinguishable in diagnostics.
        // Event-driven flows emit a `pub const FlowEventHandler` decl
        // (renderNewFormEventEntry in flow-codegen/src/codegen.zig).
        // Mark them so phase 4's assembler wiring (`main_zig.zig`
        // game_hooks/hooks_init blocks) can pick them out and append a
        // `*FlowEventHandler` into the `GameHooks` receiver tuple.
        // `OnCall` subgraph entry points keep the default `false` and
        // are skipped. Post Phase 6 (RFC-FLOW-VOCABULARY) the only way
        // to produce an `OnEvent` event is from an in-graph `Event`
        // node — the legacy header form (lifecycle + bare `OnEvent`)
        // is gone — so the `event == .OnEvent` check is now sufficient.
        const has_event_handler = loaded.flow.event == .OnEvent;

        // Lift the on-disk `priority` (RFC-PLUGIN-EVENTS O4 / phase 7,
        // labelle-core#16) onto the script entry so the receiver-tuple
        // sort in `main_zig.writeGameHooksAndInit` can find it without
        // re-parsing the flow. Post Phase 6, priority is unreachable
        // from `.flow.jsonc` (it lived on the retired `event:` header
        // — Event nodes don't carry a priority field), so this reads
        // `null` for every parsed flow today. The field is kept so the
        // tuple sort keeps working should priority gain a graph-form
        // expression later.
        const event_priority: ?i32 = if (loaded.flow.event == .OnEvent)
            loaded.flow.event.OnEvent.priority
        else
            null;

        try entries.append(arena_alloc, .{
            .name = name_owned,
            .filename = out_rel_zig,
            .states = &.{},
            .sort_order = sort_order,
            .subdir = null,
            .rel_path = rel_path,
            .plugin_name = null,
            .plugin_index = 0,
            .has_event_handler = has_event_handler,
            .event_priority = event_priority,
        });
    }

    // Sort by (sort_order numeric, then alphabetical fallback), so
    // numeric-prefixed flows fire in prefix order even when the
    // string-sorted `rel_paths` would otherwise put `10_foo` before
    // `2_foo`. Matches the script scanner's per-scope sort
    // (`script_scanner.zig:467-507`) but stripped to the columns flows
    // actually use — flows aren't state-gated and don't ship from
    // plugins today, so the plugin/subdir/state arms collapse.
    std.mem.sortUnstable(ScriptEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: ScriptEntry, b: ScriptEntry) bool {
            const a_has = a.sort_order != null;
            const b_has = b.sort_order != null;
            if (a_has != b_has) return a_has;
            if (a.sort_order) |ao| {
                if (b.sort_order) |bo| {
                    if (ao != bo) return ao < bo;
                }
            }
            return std.mem.order(u8, a.rel_path, b.rel_path) == .lt;
        }
    }.lessThan);

    return .{
        .arena = arena,
        .entries = try entries.toOwnedSlice(arena_alloc),
    };
}

/// Write a one-line diagnostic in the canonical `flows/<rel>: <err>`
/// shape directly to stderr. Best-effort — stderr write failures are
/// swallowed because there's nothing actionable a caller could do
/// about them, and the typed error is what actually fails the build.
///
/// `rel_path` comes from a recursive walk, so a deeply nested flow can
/// produce an arbitrarily long line — write the parts streamed rather
/// than formatting through a fixed stack buffer that a long path would
/// silently overflow (suppressing the diagnostic entirely).
fn reportFlowError(rel_path: []const u8, err: anyerror) void {
    const io = config.globalIo();
    const stderr = std.Io.File.stderr();
    stderr.writeStreamingAll(io, "flows/") catch {};
    stderr.writeStreamingAll(io, rel_path) catch {};
    stderr.writeStreamingAll(io, ": ") catch {};
    stderr.writeStreamingAll(io, @errorName(err)) catch {};
    stderr.writeStreamingAll(io, "\n") catch {};
}
