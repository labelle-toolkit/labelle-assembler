//! Builds the `labelle.hook-routes/v1` report from the data `generate`
//! has already scanned — labelle-assembler#724.
//!
//! ## The one rule this file exists to obey
//!
//! **Dispatch order is not derived here.** `buildReport` calls
//! `codegen/blocks/hooks.zig:buildReceiverPlan`, the SINGLE producer of
//! the receiver tuple (labelle-assembler#723,
//! `docs/design/hook-handler-ordering.md` §2.2), and reports its output
//! verbatim. That is what makes the issue's *"static route inspection
//! reports the same order used for dispatch"* true by construction rather
//! than by two algorithms agreeing today and drifting tomorrow. The
//! acceptance is guarded from the other side too: `test/hook_routes_tests.zig`
//! generates a `main.zig` through the real emitter and compares the
//! report's receiver sequence against the `MergeHooks(...)` tuple parsed
//! out of the emitted text.
//!
//! ## What IS derived here, and how honestly
//!
//! Three facts are not in any existing assembler structure, so this file
//! derives them — each with a resolution flag, because a confident empty
//! array is the failure mode an inspector must not have:
//!
//!   1. **Which events a receiver listens to.** labelle-core's
//!      `dispatcher.zig` dispatches to a receiver iff
//!      `@hasDecl(Receiver, @tagName(tag))` names a two-parameter
//!      function. So the source is AST-walked for `pub fn <name>(a, b)`
//!      members of the receiver's container decl. The compiler remains
//!      the authority — `MergeHooks` hard-errors on a handler matching no
//!      event — but the report can say so first, and in prose.
//!   2. **The engine's own `HookPayload` variants** (`game_init`,
//!      `frame_start`, `entity_created`, …). These are not scanned
//!      anywhere else in the assembler because codegen never needs to
//!      name them. Without them a perfectly valid `pub fn game_init`
//!      would be reported as a handler matching no event, which is the
//!      opposite of useful. Read from the resolved engine package;
//!      `Resolution.engine_hook_payload` records whether that worked.
//!   3. **Emission call sites.** A literal-call-site scan over the
//!      generated target tree, classifying `emit(` as buffered and
//!      `emitSync(` as synchronous — the issue's *"delivery mode is a
//!      property of the emission path, not necessarily one fixed property
//!      of an event"*. Dynamic emits are invisible to it, so an empty
//!      list means "no literal call site found", never "never emitted".
//!
//! Everything else — event names, ownership, pack qualification, elision
//! and force-keep status, payload schemas — is threaded in from the
//! scans codegen already ran, so those cannot drift either.

const std = @import("std");
const config = @import("../config.zig");
const scan = @import("../codegen/scan.zig");
const idents = @import("../codegen/idents.zig");
const hooks_block = @import("../codegen/blocks/hooks.zig");
const script_scanner = @import("../script_scanner.zig");
const scripting_declare = @import("../scripting_declare.zig");
const parse = @import("../manifest/parse.zig");
const model = @import("model.zig");

const ProjectConfig = config.ProjectConfig;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;
const Report = model.Report;

/// Everything `buildReport` needs, in the exact shapes `root.zig:generate`
/// already holds at the point it emits the other sidecars.
///
/// The five fields feeding `buildReceiverPlan` (`cfg`, `hook_names`,
/// `pack_scans`, `script_entries` — plus `cfg.hooks.order` inside it) are
/// deliberately the SAME slices the codegen orchestrator is handed, so
/// the plan built here and the plan built for emission are the same
/// function over the same inputs.
pub const Inputs = struct {
    cfg: ProjectConfig,
    /// The project root (holds `events/`, `components/`, …).
    game_dir: []const u8,
    /// The generated target root — `.labelle/<backend>_<platform>/`.
    /// Every receiver id and every emitted path in the report is relative
    /// to THIS, matching #723's identity definition.
    target_dir: []const u8,
    hook_names: []const []const u8 = &.{},
    pack_scans: []const scan.PackScan = &.{},
    script_entries: []const ScriptEntry = &.{},
    /// Game-root `events/*.zig` stems.
    event_names: []const []const u8 = &.{},
    /// Script-declared events (labelle-engine#772).
    declared_events: []const scripting_declare.DeclaredEvent = &.{},
    /// Plugin/engine events that SURVIVED the consumption filter (#630).
    plugin_events: []const scan.PluginEvent = &.{},
    /// Plugin/engine events discovered but dropped for want of a
    /// consumer. Reported with `status = elided` — the issue is explicit
    /// that an intentionally unobserved event is not an error.
    plugin_events_elided: []const scan.PluginEvent = &.{},
    /// Unconsumed but kept because the provider emits the tag ungated.
    plugin_events_force_kept: []const scan.PluginEvent = &.{},
    /// Resolved labelle-engine package directory, for the `HookPayload`
    /// variant scan. Null degrades gracefully (see `Resolution`).
    engine_dir: ?[]const u8 = null,
};

/// Build the report. `aa` should be an arena — every string in the result
/// is allocated from it and nothing is individually freed.
pub fn buildReport(aa: std.mem.Allocator, in: Inputs) !Report {
    // ── Receivers: the shared plan, reported verbatim ────────────────
    var plan = try hooks_block.buildReceiverPlan(
        aa,
        in.cfg,
        in.hook_names,
        in.pack_scans,
        in.script_entries,
    );
    defer plan.deinit(aa);

    var receivers = try aa.alloc(model.Receiver, plan.receivers.len);
    var pascal_buf: [128]u8 = undefined;
    for (plan.receivers, 0..) |r, i| {
        const source = try std.fmt.allocPrint(aa, "{s}.zig", .{r.id});
        const container: []const u8 = switch (r.kind) {
            .root_hook => try aa.dupe(u8, idents.pathToPascal(in.hook_names[r.index], &pascal_buf)),
            .pack_hook => try aa.dupe(u8, idents.pathToPascal(in.pack_scans[r.pack_index].hook_names[r.index], &pascal_buf)),
            // Flow handlers are generated with a fixed container name;
            // `printFlowHandlerImport` appends `.FlowEventHandler` to
            // whichever of its three import shapes applies.
            .flow_handler => "FlowEventHandler",
        };
        const handlers = scanHandlerDecls(aa, in.target_dir, source, container) catch null;
        receivers[i] = .{
            .order = i,
            .id = try aa.dupe(u8, r.id),
            .kind = switch (r.kind) {
                .root_hook => .root_hook,
                .pack_hook => .pack_hook,
                .flow_handler => .flow_handler,
            },
            .pack = if (r.kind == .pack_hook) in.pack_scans[r.pack_index].name else null,
            .source = source,
            .zig_type = container,
            .rank = r.rank,
            .rank_declared = r.declared,
            .baseline = r.baseline,
            .handlers = handlers orelse &.{},
            .handlers_resolved = handlers != null,
        };
    }

    // ── Events ───────────────────────────────────────────────────────
    var events: std.ArrayList(model.Event) = .empty;
    try collectGameEvents(aa, in, &events);
    try collectPackEvents(aa, in, &events);
    try collectDeclaredEvents(aa, in, &events);
    try collectPluginEvents(aa, in, &events);
    const engine_resolved = try collectEngineHookEvents(aa, in, &events);

    // Deterministic across filesystems and platforms: the scan orders
    // above are already stable, but sorting by the FINAL tag means a
    // consumer diffing two reports never sees a reshuffle caused by a
    // pack being declared in a different position.
    std.mem.sort(model.Event, events.items, {}, struct {
        fn lessThan(_: void, a: model.Event, b: model.Event) bool {
            return std.mem.order(u8, a.tag, b.tag) == .lt;
        }
    }.lessThan);

    // ── Listeners: a FILTER over the one global receiver sequence ─────
    // Not a per-event ordering. `MergeHooks` walks one tuple for every
    // event (design doc §2.1), so each listener carries its GLOBAL index.
    for (events.items) |*ev| {
        var listeners: std.ArrayList(model.Listener) = .empty;
        for (receivers) |rc| {
            for (rc.handlers) |h| {
                if (std.mem.eql(u8, h, ev.tag)) {
                    try listeners.append(aa, .{ .receiver = rc.id, .order = rc.order });
                    break;
                }
            }
        }
        ev.listeners = try listeners.toOwnedSlice(aa);
    }

    // ── Handlers matching no enumerable event ────────────────────────
    var unmatched: std.ArrayList(model.UnmatchedHandler) = .empty;
    for (receivers) |rc| {
        for (rc.handlers) |h| {
            var found = false;
            for (events.items) |ev| {
                if (std.mem.eql(u8, h, ev.tag)) {
                    found = true;
                    break;
                }
            }
            if (found) continue;
            try unmatched.append(aa, .{
                .receiver = rc.id,
                .handler = h,
                // The distinction the issue asks for: a handler we cannot
                // match because we could not read the engine's payload
                // union is a GAP IN THIS REPORT, whereas one we cannot
                // match with the union in hand is a build-breaking typo
                // (`MergeHooks` compile-errors on it).
                .reason = if (engine_resolved) .unknown_event else .engine_payload_unresolved,
            });
        }
    }

    // ── Emission call sites ──────────────────────────────────────────
    var tags: std.ArrayList([]const u8) = .empty;
    for (events.items) |ev| try tags.append(aa, ev.tag);
    // The candidate set, in a deterministic order: every hook-receiver
    // source (dispatch order) followed by every scanned script entry
    // (scanner order). Both are already the caller's stable orders, and
    // deduping keeps a receiver that is ALSO a script entry — a flow
    // handler — from being read twice.
    var candidates: std.ArrayList([]const u8) = .empty;
    for (receivers) |rc| try candidates.append(aa, rc.source);
    for (in.script_entries) |e| {
        const rel = try std.fmt.allocPrint(aa, "{s}{s}", .{ e.import_base, e.rel_path });
        var seen = false;
        for (candidates.items) |c| {
            if (std.mem.eql(u8, c, rel)) seen = true;
        }
        if (!seen) try candidates.append(aa, rel);
    }
    const emit_scan = try scanEmitSites(aa, in.target_dir, candidates.items, tags.items);
    for (events.items, 0..) |*ev, i| {
        ev.emitters = emit_scan.per_tag[i];
    }

    return .{
        .assembler_version = config.ASSEMBLER_VERSION,
        .project = in.cfg.name,
        .ordering = .{ .declared = in.cfg.hooks.order.len > 0 },
        .resolution = .{
            .engine_hook_payload = engine_resolved,
            .emit_sites_scanned = true,
            .emit_sites_files_scanned = emit_scan.files_scanned,
            .emit_sites_truncated = emit_scan.truncated,
            .emit_sites_unreadable = emit_scan.unreadable,
        },
        .receivers = receivers,
        .events = try events.toOwnedSlice(aa),
        .unmatched_handlers = try unmatched.toOwnedSlice(aa),
    };
}

// ── Event collection ────────────────────────────────────────────────────

/// Game-root `events/*.zig`. The generated union tag is the file stem
/// (`idents.eventVariantName`), exactly as `blocks/events.zig` emits it.
fn collectGameEvents(aa: std.mem.Allocator, in: Inputs, out: *std.ArrayList(model.Event)) !void {
    if (in.event_names.len == 0) return;
    const decls = try parse.parseStructDir(aa, in.game_dir, "events", in.event_names);
    var pascal_buf: [128]u8 = undefined;
    for (in.event_names, 0..) |name, i| {
        const pascal = idents.pathToPascal(name, &pascal_buf);
        const decl: ?parse.StructDecl = if (i < decls.len) decls[i] else null;
        try out.append(aa, .{
            .tag = try aa.dupe(u8, idents.eventVariantName(name)),
            .name = try aa.dupe(u8, idents.eventVariantName(name)),
            .owner = .game,
            .owner_name = "game",
            .source = try std.fmt.allocPrint(aa, "events/{s}.zig", .{name}),
            .payload = try payloadOf(aa, decl, try aa.dupe(u8, pascal)),
            .consumable = if (decl) |d| d.consumable else null,
        });
    }
}

/// Pack `events/*.zig` (Packs RFC §4, #439). The tag carries the
/// invisible `<pack>__` namespace prefix — the qualification the issue's
/// acceptance calls for, and the reason two packs shipping `hit.zig` do
/// not collide. Payloads are parsed from the STAGED copy under the target
/// root, which is the tree codegen imports.
fn collectPackEvents(aa: std.mem.Allocator, in: Inputs, out: *std.ArrayList(model.Event)) !void {
    var prefix_buf: [128]u8 = undefined;
    var pascal_buf: [128]u8 = undefined;
    for (in.pack_scans) |pack| {
        if (pack.event_names.len == 0) continue;
        const prefix = try aa.dupe(u8, scan.packNamespacePrefix(pack.name, &prefix_buf));
        const pack_root = try std.fs.path.join(aa, &.{ in.target_dir, pack.import_prefix });
        const decls = try parse.parseStructDir(aa, pack_root, "events", pack.event_names);
        for (pack.event_names, 0..) |name, i| {
            const bare = idents.eventVariantName(name);
            const pascal = idents.pathToPascal(name, &pascal_buf);
            const decl: ?parse.StructDecl = if (i < decls.len) decls[i] else null;
            try out.append(aa, .{
                .tag = try std.fmt.allocPrint(aa, "{s}__{s}", .{ prefix, bare }),
                .name = try aa.dupe(u8, bare),
                .owner = .pack,
                .owner_name = try aa.dupe(u8, pack.name),
                .source = try std.fmt.allocPrint(aa, "{s}/events/{s}.zig", .{ pack.import_prefix, name }),
                .payload = try payloadOf(aa, decl, try aa.dupe(u8, pascal)),
                .consumable = if (decl) |d| d.consumable else null,
            });
        }
    }
}

/// Script-declared events (labelle-engine#772) — bus-identical to an
/// `events/*.zig` row, only the payload's home differs (the generated
/// `scripting_events.zig`). Converted straight from the typed schema, the
/// same no-drift path `manifest/emit.zig` takes.
fn collectDeclaredEvents(aa: std.mem.Allocator, in: Inputs, out: *std.ArrayList(model.Event)) !void {
    var pascal_buf: [128]u8 = undefined;
    for (in.declared_events) |de| {
        const fields = try aa.alloc(model.PayloadField, de.fields.len);
        for (de.fields, fields) |df, *f| f.* = .{
            .name = df.name,
            .zig_type = scripting_declare.zigFieldTypeName(df.default),
        };
        try out.append(aa, .{
            .tag = try aa.dupe(u8, de.name),
            .name = try aa.dupe(u8, de.name),
            .owner = .script,
            .owner_name = "script",
            .source = "scripting_events.zig",
            .payload = .{
                .zig_type = try aa.dupe(u8, idents.pathToPascal(de.name, &pascal_buf)),
                .fields = fields,
                .resolved = true,
            },
        });
    }
}

/// Plugin + engine `Events` blocks (RFC-PLUGIN-EVENTS phase 1;
/// labelle-engine#578 folds the engine in through the same pipeline).
///
/// All three consumption states are reported, because "the event is gone"
/// and "nothing listens to the event" are different answers and the issue
/// requires them to be distinguishable.
fn collectPluginEvents(aa: std.mem.Allocator, in: Inputs, out: *std.ArrayList(model.Event)) !void {
    const groups = [_]struct { list: []const scan.PluginEvent, status: model.EventStatus }{
        .{ .list = in.plugin_events, .status = .active },
        .{ .list = in.plugin_events_elided, .status = .elided },
        .{ .list = in.plugin_events_force_kept, .status = .force_kept },
    };
    for (groups) |g| {
        for (g.list) |pe| {
            // A force-kept entry is a SUBSET of the kept list (#630
            // follow-up), so it would otherwise appear twice. The
            // force-kept pass wins: it carries the more specific status.
            if (g.status == .active and containsEvent(in.plugin_events_force_kept, pe)) continue;
            const is_engine = std.mem.eql(u8, pe.plugin_import_name, "engine");
            const notes: []const []const u8 = switch (g.status) {
                .active => &.{},
                .elided => &.{
                    "Elided: no consumer was found, so the variant is not emitted into GameEvents (labelle-assembler#630). Not an error — an intentionally unobserved event is a normal state. Add a handler, or list it under `.plugin_events`, to keep it.",
                },
                .force_kept => &.{
                    "Force-kept: nothing consumes this event, but the providing plugin emits the tag with a raw union literal, so eliding it would break the provider's own compile (labelle-assembler#630).",
                },
            };
            try out.append(aa, .{
                .tag = try std.fmt.allocPrint(aa, "{s}__{s}", .{ pe.plugin_sanitized, pe.event_name }),
                .name = try aa.dupe(u8, pe.event_name),
                .owner = if (is_engine) .engine else .plugin,
                .owner_name = try aa.dupe(u8, pe.plugin_import_name),
                .source = null,
                // The payload struct lives in the provider's
                // `src/root.zig` `Events` block and is already published
                // per-plugin in `flow_catalog.json`. Point there instead
                // of re-walking it — and say `resolved = false` rather
                // than emitting an empty field list that reads as "no
                // fields".
                .payload = .{ .resolved = false },
                .status = g.status,
                .notes = if (notes.len > 0) notes else &.{
                    "Payload fields are declared in the provider's `pub const Events` block; see `.labelle/flow_catalog.json` for its schema.",
                },
            });
        }
    }
}

fn containsEvent(list: []const scan.PluginEvent, needle: scan.PluginEvent) bool {
    for (list) |e| {
        if (std.mem.eql(u8, e.plugin_sanitized, needle.plugin_sanitized) and
            std.mem.eql(u8, e.event_name, needle.event_name)) return true;
    }
    return false;
}

/// The engine's own `HookPayload(Entity)` variants — the base union
/// `AllHookPayloads` merges everything else into. Returns whether the
/// scan succeeded; a false return is reported in `Resolution` and changes
/// how unmatched handlers are classified, rather than being swallowed.
fn collectEngineHookEvents(aa: std.mem.Allocator, in: Inputs, out: *std.ArrayList(model.Event)) !bool {
    const engine_dir = in.engine_dir orelse return false;
    const io = config.globalIo();
    const path = try std.fs.path.join(aa, &.{ engine_dir, "src", "hooks_types.zig" });
    const src = std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    const variants = try parseHookPayloadVariants(aa, src);
    if (variants.len == 0) return false;
    for (variants) |v| {
        try out.append(aa, .{
            .tag = v.name,
            .name = v.name,
            .owner = .engine_hook,
            .owner_name = "engine",
            .source = null,
            .payload = .{ .zig_type = v.zig_type, .resolved = false },
            .notes = &.{
                "Engine lifecycle hook: a variant of `engine.HookPayload(Entity)` (labelle-engine `src/hooks_types.zig`). Dispatched by the engine itself through `emitHook`, so it has no game-side emit call site.",
            },
        });
    }
    return true;
}

const HookVariant = struct { name: []const u8, zig_type: []const u8 };

/// Pull the field list out of `pub fn HookPayload(...) type { return
/// union(enum) { ... }; }`.
///
/// A brace-counted text scan rather than an AST walk: the union is a
/// return expression inside a function body, so `Ast.rootDecls` does not
/// reach it and the AST route would mean hand-walking statement nodes for
/// no extra precision. The shape is one declaration in one engine file;
/// a scan that stops finding fields degrades to `resolved = false`, which
/// the report states outright.
fn parseHookPayloadVariants(aa: std.mem.Allocator, src: []const u8) ![]const HookVariant {
    const fn_at = std.mem.indexOf(u8, src, "pub fn HookPayload(") orelse return &.{};
    const union_marker = "union(enum) {";
    const u_at = std.mem.indexOfPos(u8, src, fn_at, union_marker) orelse return &.{};
    var i = u_at + union_marker.len;
    var depth: usize = 1;
    var out: std.ArrayList(HookVariant) = .empty;
    while (i < src.len and depth > 0) {
        // One line at a time; `field: Type,` is the only shape the union
        // uses, and comments/blank lines are skipped by the match below.
        const line_end = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
        const line = std.mem.trim(u8, src[i..line_end], " \t\r");
        // Depth BEFORE this line's braces are counted. A union variant is a
        // DIRECT member, so it starts at depth 1 — including
        // `foo: struct {`, which opens a nested scope on the same line and
        // would be missed by testing depth after counting.
        const depth_at_line_start = depth;
        for (line) |c| {
            if (c == '{') depth += 1;
            if (c == '}') {
                if (depth > 0) depth -= 1;
            }
        }
        // `depth > 0` accepted ANY nested line, so the fields of a multiline
        // anonymous payload became phantom union variants — a route report
        // listing events that do not exist (#724 review).
        if (depth_at_line_start == 1 and line.len > 0 and !std.mem.startsWith(u8, line, "//")) {
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                const name = std.mem.trim(u8, line[0..colon], " \t");
                if (isIdent(name)) {
                    var type_txt = std.mem.trim(u8, line[colon + 1 ..], " \t");
                    if (std.mem.endsWith(u8, type_txt, ",")) type_txt = type_txt[0 .. type_txt.len - 1];
                    try out.append(aa, .{
                        .name = try aa.dupe(u8, name),
                        .zig_type = try aa.dupe(u8, std.mem.trim(u8, type_txt, " \t")),
                    });
                }
            }
        }
        i = line_end + 1;
    }
    return out.toOwnedSlice(aa);
}

fn isIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}


/// Convert an AST-parsed event struct into the report's payload shape.
///
/// `parseStructDir` degrades an unreadable or garbled file to a name-only
/// decl with an empty field list, and a legitimately field-less payload
/// (`struct {}`) parses to the same thing. Rather than invent a
/// distinction the parser cannot make, both report `resolved = true` with
/// an empty list — which is exactly what the generated union carries
/// either way. A NULL decl (the file was not in the parse set at all) is
/// the honest `resolved = false`.
fn payloadOf(aa: std.mem.Allocator, decl: ?parse.StructDecl, zig_type: []const u8) !model.Payload {
    const d = decl orelse return .{ .zig_type = zig_type, .resolved = false };
    const fields = try aa.alloc(model.PayloadField, d.fields.len);
    for (d.fields, fields) |src_f, *out_f| out_f.* = .{
        .name = src_f.name,
        .zig_type = src_f.zig_type,
    };
    // `resolved` means "we read this payload", not "a decl by this name
    // exists". A name-only degradation has zero fields because nothing was
    // parsed; reporting it resolved presented "no fields" as a fact about
    // the payload rather than a gap in the scan (#724 review).
    return .{ .zig_type = zig_type, .fields = fields, .resolved = d.parsed };
}

// ── Handler discovery ───────────────────────────────────────────────────

/// AST-walk one receiver's source for the event tags it handles.
///
/// The rule is labelle-core's, not an approximation of it:
/// `dispatcher.zig` invokes `@field(Base, @tagName(tag))` when
/// `@hasDecl(Base, name)` holds, and `MergeHooks`' comptime validation
/// treats a **two-parameter function declaration** as a handler claim.
/// `@hasDecl` from another file sees only `pub` decls, so both conditions
/// are applied here: `pub`, `fn`, exactly two parameters.
///
/// Returns null — NOT an empty list — when the file cannot be read or the
/// container decl is not found, so the caller can report
/// `handlers_resolved = false` instead of "listens to nothing".
/// Count a function's parameters — through the AST's own iterator, NOT
/// `proto.ast.params.len`.
///
/// `params` holds only parameters with a TYPE EXPRESSION node; `anytype`
/// (and `...`) are plain tokens and are absent from it. Counting the
/// slice therefore reads
/// `pub fn on_hit(self: *Hooks, ev: anytype) void` as a ONE-parameter
/// function and silently drops it — and `anytype` is the dominant shape
/// in generated flow handlers and in hooks written against pack events.
/// Every handler in such a file would vanish from the report while the
/// receiver still appeared, which is the worst kind of wrong: confidently
/// empty. `Iterator` exists precisely to abstract that over, and its doc
/// comment says so.
fn countParams(ast: *const std.zig.Ast, proto: *const std.zig.Ast.full.FnProto) usize {
    var it = proto.iterate(ast);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

fn scanHandlerDecls(
    aa: std.mem.Allocator,
    target_dir: []const u8,
    source_rel: []const u8,
    container_name: []const u8,
) !?[]const []const u8 {
    const io = config.globalIo();
    const path = try std.fs.path.join(aa, &.{ target_dir, source_rel });
    const src = std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const src_z = try aa.dupeZ(u8, src);
    var ast = try std.zig.Ast.parse(aa, src_z, .zig);
    defer ast.deinit(aa);

    for (ast.rootDecls()) |decl_idx| {
        const vd = ast.fullVarDecl(decl_idx) orelse continue;
        const init_node = vd.ast.init_node.unwrap() orelse continue;
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const container = ast.fullContainerDecl(&buf, init_node) orelse continue;
        if (!std.mem.eql(u8, ast.tokenSlice(vd.ast.mut_token + 1), container_name)) continue;

        var names: std.ArrayList([]const u8) = .empty;
        for (container.ast.members) |m| {
            var fn_buf: [1]std.zig.Ast.Node.Index = undefined;
            const proto = ast.fullFnProto(&fn_buf, m) orelse continue;
            if (proto.visib_token == null) continue;
            if (countParams(&ast, &proto) != 2) continue;
            const name_tok = proto.name_token orelse continue;
            try names.append(aa, try aa.dupe(u8, ast.tokenSlice(name_tok)));
        }
        return try names.toOwnedSlice(aa);
    }
    return null;
}

// ── Emission-site discovery ─────────────────────────────────────────────

/// Result of the emit scan: one emitter list per input tag, plus how many
/// files were read (surfaced in `Resolution` so an empty result is
/// attributable).
const EmitScan = struct {
    per_tag: []const []const model.Emitter,
    files_scanned: usize,
    /// The file cap was hit and the scan stopped early.
    truncated: bool = false,
    /// Files that could not be read (permissions, over the byte cap, a
    /// race). Each is a hole in the scan, not an absence of emits.
    unreadable: usize = 0,
};

/// Cap on files read by the emit scan. A bound keeps a pathological
/// project from turning a sidecar into a build cost; reaching it degrades
/// the scan, never the generate.
const EMIT_SCAN_FILE_LIMIT: usize = 4096;
const EMIT_SCAN_MAX_BYTES: usize = 2 * 1024 * 1024;

/// Scan a known, ordered set of source files for literal
/// `emit(.{ .<tag>` and `emitSync(.{ .<tag>` call sites.
///
/// **Why an explicit file list rather than a tree walk.** The generated
/// target root reaches the game's convention dirs through directory
/// SYMLINKS (`scanner.linkDirAbs`), so a recursive walk never descends
/// into `hooks/`, `scripts/` or `events/` — and `Dir.walk` documents its
/// entry order as undefined, which a deterministic sidecar cannot use.
/// The candidate list is instead built by the caller from the same scans
/// codegen ran: every hook-receiver source plus every scanned script
/// entry (game, pack and plugin scripts). Opening each by path follows
/// the symlinks, and the order is the caller's.
///
/// Delivery is read off the CALL, which is the issue's point that
/// delivery mode belongs to the emission path: `emit` buffers the event
/// for the end-of-frame `dispatchEvents` drain, `emitSync` dispatches
/// immediately on the caller's stack (labelle-engine
/// `game/events_mixin.zig`). One event emitted both ways therefore shows
/// two emitters with different `delivery`, rather than one averaged
/// claim.
///
/// Scope and blind spots, both stated in `Resolution` rather than
/// implied: it sees literal call sites in the scanned files only. A tag
/// computed at runtime, an event forwarded through a helper taking a
/// `GameEvents` value, or an emit from a plugin's own Zig source outside
/// the project tree does not appear — hence `Emitter`'s contract that an
/// empty list means "no literal call site found", never "never emitted".
fn scanEmitSites(
    aa: std.mem.Allocator,
    target_dir: []const u8,
    candidates: []const []const u8,
    tags: []const []const u8,
) !EmitScan {
    const lists = try aa.alloc(std.ArrayList(model.Emitter), tags.len);
    for (lists) |*l| l.* = .empty;

    const io = config.globalIo();
    var files: usize = 0;
    var truncated = false;
    var unreadable: usize = 0;
    for (candidates) |rel| {
        if (files >= EMIT_SCAN_FILE_LIMIT) {
            // The scan stopped early. Recorded rather than swallowed: a
            // report that lists "emitted from" is read as exhaustive, and a
            // silently truncated scan turns "no emit site found" into a
            // false negative that looks like an answer (#724 review).
            truncated = true;
            break;
        }
        const path = try std.fs.path.join(aa, &.{ target_dir, rel });
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(EMIT_SCAN_MAX_BYTES)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A file we could not read (permissions, a race, over the byte
            // cap) is a HOLE in the scan, not an absence of emits. Counted.
            else => {
                unreadable += 1;
                continue;
            },
        };
        files += 1;
        // The tokenizer needs a sentinel-terminated buffer (same shape
        // `manifest/parse.zig` uses).
        const src = try aa.dupeZ(u8, raw);
        try scanOneFileForEmits(aa, src, rel, tags, lists);
    }

    const out = try aa.alloc([]const model.Emitter, tags.len);
    for (lists, out) |*l, *o| o.* = try l.toOwnedSlice(aa);
    return .{
        .per_tag = out,
        .files_scanned = files,
        .truncated = truncated,
        .unreadable = unreadable,
    };
}

fn scanOneFileForEmits(
    aa: std.mem.Allocator,
    src: [:0]const u8,
    rel_path: []const u8,
    tags: []const []const u8,
    lists: []std.ArrayList(model.Emitter),
) !void {
    // TOKENS, not raw bytes. The previous byte scan matched `emit(` inside
    // a `//` comment and inside a string literal, so a commented-out call
    // or a doc example became a reported route — the report then named a
    // "site" that emits nothing (#724 review). The tokenizer drops comments
    // entirely and yields a string literal as ONE token, so neither can be
    // mistaken for a call. It also makes the identifier-boundary check
    // unnecessary: `reemit` is its own token.
    var tok = std.zig.Tokenizer.init(src);
    var prev_ident: ?[]const u8 = null;
    while (true) {
        const t_tok = tok.next();
        if (t_tok.tag == .eof) break;
        if (t_tok.tag == .identifier) {
            prev_ident = src[t_tok.loc.start..t_tok.loc.end];
            continue;
        }
        const ident = prev_ident orelse continue;
        prev_ident = null;
        if (t_tok.tag != .l_paren) continue;

        const delivery: model.Delivery = if (std.mem.eql(u8, ident, "emitSync"))
            .sync
        else if (std.mem.eql(u8, ident, "emit"))
            .buffered
        else
            continue;

        {
            const tag = emittedTagAt(src, t_tok.loc.end) orelse continue;
            for (tags, 0..) |t, i| {
                if (!std.mem.eql(u8, t, tag)) continue;
                // One entry per (file, tag, delivery) — a loop emitting
                // the same event twice is one route, not two.
                var dup = false;
                for (lists[i].items) |e| {
                    if (e.delivery == delivery and std.mem.eql(u8, e.site, rel_path)) dup = true;
                }
                if (!dup) try lists[i].append(aa, .{ .site = rel_path, .delivery = delivery });
            }
        }
    }
}

/// Read the union tag out of an emit argument: `(.{ .<tag> = ...` —
/// whitespace and newlines tolerated, since a multi-line payload literal
/// is the common shape. Returns null for anything else (a forwarded
/// variable, a computed union), which is exactly the case the report
/// declines to claim.
fn emittedTagAt(src: []const u8, start: usize) ?[]const u8 {
    var i = start;
    i = skipWs(src, i);
    if (i >= src.len or src[i] != '.') return null;
    i += 1;
    i = skipWs(src, i);
    if (i >= src.len or src[i] != '{') return null;
    i += 1;
    i = skipWs(src, i);
    if (i >= src.len or src[i] != '.') return null;
    i += 1;
    const begin = i;
    while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '_')) i += 1;
    if (i == begin) return null;
    return src[begin..i];
}

fn skipWs(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\n' or src[i] == '\r')) i += 1;
    return i;
}
