//! The two output forms of the hook-route inspector — labelle-assembler#724.
//!
//! One `Report`, two renderers, and the machine form is the primary one.
//!
//! **JSON** goes through `std.json.Stringify` over the `model` types, so
//! the key set, the key ORDER and the value spellings are the struct
//! definitions themselves. There is no hand-written writer that can fall
//! behind a field, and `hook_routes.parseReport` reflects over the same
//! types to read it back — which is what makes the round-trip test a real
//! contract check rather than a string comparison. Determinism comes from
//! three places: struct field order is fixed at comptime, `receivers` is
//! in dispatch order, and `events` is sorted by tag in `build.zig`.
//!
//! **Text** is rendered FROM THE PARSED MODEL, never from the builder's
//! intermediate state. That is deliberate: it makes the human report a
//! consumer of the same JSON that labelle-engine#858 will consume, so a
//! field the JSON fails to carry is immediately visible as a hole in the
//! text — the machine contract cannot silently become the weaker of the
//! two.

const std = @import("std");
const model = @import("model.zig");

/// Write the machine form. Indented rather than minified: this file is
/// read by humans in diffs and by `jq` at least as often as by a program,
/// and 2-space indent is what the sibling sidecars use.
pub fn writeJson(w: *std.Io.Writer, report: model.Report) !void {
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, w);
    try w.writeAll("\n");
}

/// Write the human form.
///
/// Three sections, in the order an author actually asks the questions:
///
///   1. **Dispatch order** — the one receiver tuple, because everything
///      else is a filter over it. Each row carries the rank and the
///      baseline, so the answer to "why is it here" is on the same line
///      as "where is it".
///   2. **Events** — for each event, who listens (in dispatch order) and
///      what emits it (with the delivery mode of that call site).
///   3. **Notes** — unmatched handlers and unresolved static information,
///      never folded into the sections above where they could read as
///      findings.
///
/// The guaranteed/incidental split from the ordering contract's §2.4 is
/// stated in the header rather than left for the reader to infer: an
/// undeclared project's order is exact but incidental, and printing it
/// without saying so is how an incidental order comes to be relied upon.
pub fn writeText(w: *std.Io.Writer, report: model.Report, filter: Filter) !void {
    try w.print("Hook routes for `{s}` (assembler {s})\n", .{ report.project, report.assembler_version });
    try w.writeAll("=" ** 70);
    try w.writeAll("\n\n");

    try writeOrderSection(w, report, filter);
    try writeEventSection(w, report, filter);
    try writeNotesSection(w, report, filter);
}

/// Narrows both sections to one event or one receiver. A filter never
/// changes a number: `order` stays the global tuple index and listeners
/// stay in global dispatch order, so a filtered view and the full view
/// can be read against each other.
pub const Filter = struct {
    event: ?[]const u8 = null,
    receiver: ?[]const u8 = null,
};

fn writeOrderSection(w: *std.Io.Writer, report: model.Report, filter: Filter) !void {
    try w.writeAll("DISPATCH ORDER\n");
    if (report.ordering.declared) {
        try w.writeAll(
            \\  Explicit: `project.labelle` declares `.hooks.order`, so this
            \\  sequence is authored. (*) marks a declared rank.
            \\
        );
    } else {
        try w.writeAll(
            \\  Default: nothing is declared, so this sequence is the
            \\  discovery-driven baseline — root hooks, then pack hooks, then
            \\  the flow tail. It is exact, but INCIDENTAL: two receivers
            \\  nobody ordered have no guaranteed order between them. Declare
            \\  `.hooks.order` for any pair whose order matters.
            \\
        );
    }
    try w.writeAll(
        \\  ONE tuple, walked in this order for EVERY event. On a consumable
        \\  event the first listener returning `true` stops the walk.
        \\  Contract: docs/design/hook-handler-ordering.md
        \\
        \\
    );

    if (report.receivers.len == 0) {
        try w.writeAll("  (no hook receivers)\n\n");
        return;
    }

    var shown: usize = 0;
    for (report.receivers) |r| {
        if (!receiverPasses(r, report, filter)) continue;
        shown += 1;
        var rank_buf: [16]u8 = undefined;
        const rank_str = try std.fmt.bufPrint(&rank_buf, "{d}", .{r.rank});
        try w.print("  [{d}] rank {s: >5} {s} {s}\n", .{
            r.order,
            rank_str,
            if (r.rank_declared) "*" else " ",
            r.id,
        });
        try w.print("        {s}  ·  {s}  ·  baseline {d}\n", .{
            @tagName(r.kind),
            r.source,
            r.baseline,
        });
        if (!r.handlers_resolved) {
            try w.writeAll("        handlers: UNRESOLVED (source unreadable or container decl not found)\n");
        } else if (r.handlers.len == 0) {
            try w.writeAll("        handlers: none\n");
        } else {
            try w.writeAll("        handlers:");
            for (r.handlers) |h| try w.print(" {s}", .{h});
            try w.writeAll("\n");
        }
    }
    if (shown == 0) try w.writeAll("  (no receivers match the filter)\n");
    try w.writeAll("\n");
}

fn writeEventSection(w: *std.Io.Writer, report: model.Report, filter: Filter) !void {
    const filtered = filter.event != null or filter.receiver != null;
    try w.writeAll("EVENTS\n\n");

    // An event with no listener and no emit site is a CATALOG row, not a
    // route: it says "this exists to subscribe to". A project inherits
    // dozens of them from the engine's own `Events` block and lifecycle
    // union, and printing each in full buries the two or three events the
    // author actually came to read. They are still listed — compactly,
    // grouped by WHY they are inert, with the explanation given once —
    // because "declared but dropped" versus "available but unhandled" is
    // exactly the distinction the issue requires to stay visible. An
    // explicit `--event` / `--receiver` always gets the full detail.
    var routed: usize = 0;
    var matched: usize = 0;
    for (report.events) |ev| {
        if (!eventPasses(ev, filter)) continue;
        matched += 1;
        if (!filtered and !isRoute(ev)) continue;
        routed += 1;
        try writeOneEvent(w, ev);
    }
    if (matched == 0) {
        try w.writeAll("  (no events match the filter)\n\n");
        return;
    }
    if (routed == 0 and !filtered) {
        try w.writeAll("  (no event in this project has a listener or a known emit site)\n\n");
    }
    if (filtered) return;

    try writeInertGroup(w, report, .elided,
        "ELIDED — declared, then dropped for want of a consumer",
        \\    Not errors. Each was declared by the engine or a plugin, nothing in this
        \\    project handles it, so the variant is not emitted into GameEvents
        \\    (labelle-assembler#630). Add a handler, or name it under
        \\    `.plugin_events`, to keep one.
        \\
    );
    try writeInertGroup(w, report, null,
        "AVAILABLE — in the dispatcher, with no listener and no known emit site",
        \\    Subscribe by declaring `pub fn <tag>(self: *Hooks, ev: <Payload>) void`
        \\    on a hook receiver. Engine lifecycle rows are dispatched by the engine
        \\    itself, so they never show a game-side emit site.
        \\
    );
}

/// A row worth printing in full: something listens to it, or something
/// visibly emits it.
fn isRoute(ev: model.Event) bool {
    return ev.listeners.len > 0 or ev.emitters.len > 0;
}

/// Print one compact bucket of inert events. `want_status` null means
/// "every status except elided", which is what separates *dropped* from
/// merely *unsubscribed*.
fn writeInertGroup(
    w: *std.Io.Writer,
    report: model.Report,
    want_status: ?model.EventStatus,
    heading: []const u8,
    body: []const u8,
) !void {
    var count: usize = 0;
    for (report.events) |ev| {
        if (isRoute(ev)) continue;
        if (inGroup(ev, want_status)) count += 1;
    }
    if (count == 0) return;
    try w.print("  {s} ({d})\n", .{ heading, count });
    try w.writeAll(body);
    for (report.events) |ev| {
        if (isRoute(ev)) continue;
        if (!inGroup(ev, want_status)) continue;
        try w.print("      {s}\n", .{ev.tag});
    }
    try w.writeAll("\n");
}

fn inGroup(ev: model.Event, want_status: ?model.EventStatus) bool {
    if (want_status) |st| return ev.status == st;
    return ev.status != .elided;
}

fn eventPasses(ev: model.Event, filter: Filter) bool {
    if (filter.event) |want| {
        if (!std.mem.eql(u8, want, ev.tag)) return false;
    }
    if (filter.receiver) |want| {
        for (ev.listeners) |l| {
            if (std.mem.eql(u8, l.receiver, want)) return true;
        }
        return false;
    }
    return true;
}

fn writeOneEvent(w: *std.Io.Writer, ev: model.Event) !void {
    try w.print("  {s}\n", .{ev.tag});
    try w.print("    owner: {s}", .{@tagName(ev.owner)});
    // The realm name only when it adds something — `owner: plugin
    // \`box2d\`` is worth a column, `owner: engine \`engine\`` is not.
    if (!std.mem.eql(u8, ev.owner_name, @tagName(ev.owner))) try w.print(" `{s}`", .{ev.owner_name});
    if (ev.source) |src| try w.print("  ·  {s}", .{src});
    try w.writeAll("\n");

    if (ev.status != .active) {
        try w.print("    status: {s}\n", .{@tagName(ev.status)});
    }
    try w.print("    delivery semantics: {s}\n", .{
        if (ev.consumable)
            "CONSUMABLE — the first listener returning `true` stops the walk, so order decides WHETHER a later listener runs"
        else
            "notification — every listener runs, so order decides only WHEN",
    });

    if (ev.payload.resolved) {
        if (ev.payload.fields.len == 0) {
            try w.print("    payload: {s} {{}}\n", .{ev.payload.zig_type orelse "?"});
        } else {
            try w.print("    payload: {s}\n", .{ev.payload.zig_type orelse "?"});
            for (ev.payload.fields) |f| try w.print("      {s}: {s}\n", .{ f.name, f.zig_type });
        }
    } else if (ev.payload.zig_type) |t| {
        try w.print("    payload: {s} (fields not statically resolved)\n", .{t});
    } else {
        try w.writeAll("    payload: not statically resolved\n");
    }

    if (ev.listeners.len == 0) {
        try w.writeAll("    listeners: none found\n");
    } else {
        try w.writeAll("    listeners (dispatch order):\n");
        for (ev.listeners) |l| try w.print("      [{d}] {s}\n", .{ l.order, l.receiver });
    }

    if (ev.emitters.len == 0) {
        try w.writeAll("    emitted from: no literal call site found (a computed or plugin-internal emit is invisible to this scan)\n");
    } else {
        try w.writeAll("    emitted from:\n");
        for (ev.emitters) |e| try w.print("      {s}  [{s}]\n", .{ e.site, @tagName(e.delivery) });
    }
    for (ev.notes) |n| try w.print("    note: {s}\n", .{n});
    try w.writeAll("\n");
}

fn writeNotesSection(w: *std.Io.Writer, report: model.Report, filter: Filter) !void {
    // A filtered view is a lens on one route, not a health report; the
    // whole-project notes below would be misleading noise there.
    if (filter.event != null or filter.receiver != null) return;

    if (report.unmatched_handlers.len > 0) {
        try w.writeAll("HANDLERS MATCHING NO EVENT\n");
        for (report.unmatched_handlers) |u| {
            try w.print("  {s}: `{s}` — {s}\n", .{
                u.receiver,
                u.handler,
                switch (u.reason) {
                    .unknown_event =>
                        "no event carries this tag. `MergeHooks` rejects this at compile time, so the generated game will not build.",
                    .engine_payload_unresolved =>
                        "could not be checked: the engine's HookPayload variant list was not readable, so a valid lifecycle handler looks the same as a typo here.",
                },
            });
        }
        try w.writeAll("\n");
    }

    try w.writeAll("WHAT THIS REPORT DOES NOT KNOW\n");
    if (!report.resolution.engine_hook_payload) {
        try w.writeAll("  · engine lifecycle events (game_init, frame_start, entity_created, …) are\n" ++
            "    ABSENT: `engine.HookPayload` could not be read from the resolved engine\n" ++
            "    package. Handlers for them appear above as unmatched.\n");
    }
    try w.print("  · emission sites come from a literal-call-site scan of {d} source file(s):\n" ++
        "    every hook receiver plus every scanned script. A computed emit, or one from\n" ++
        "    a plugin's own sources, is not listed — \"no call site found\" is not \"never emitted\".\n", .{report.resolution.emit_sites_files_scanned});
    try w.writeAll("  · listeners are read from `pub fn <tag>(self, payload)` declarations. The\n" ++
        "    compiler is the authority; this is what the source says.\n");
    if (!report.ordering.declared) {
        try w.writeAll("  · the order above is the default. It is what will run, but only a declared\n" ++
            "    `.hooks.order` makes a relative order a guarantee.\n");
    }
}

fn receiverPasses(r: model.Receiver, report: model.Report, filter: Filter) bool {
    if (filter.receiver) |want| {
        if (!std.mem.eql(u8, r.id, want)) return false;
    }
    if (filter.event) |want| {
        const ev = report.eventByTag(want) orelse return false;
        for (ev.listeners) |l| {
            if (std.mem.eql(u8, l.receiver, r.id)) return true;
        }
        return false;
    }
    return true;
}
