//! `labelle-assembler routes` — the hook-route inspector's CLI surface
//! (labelle-assembler#724). Design note:
//! `docs/design/hook-route-inspection.md`.
//!
//! ## Why `routes`, and why it only reads
//!
//! The issue names the command spelling as a proposal to decide during
//! implementation. This repo's surface is bare nouns and verbs —
//! `generate`, `install`, `clean`, `upgrade`, `init`, `check`, `add` — so
//! a flag-shaped or namespaced spelling (`--inspect-hooks`,
//! `hooks routes`) would have been the odd one out. `routes` is the noun
//! for the thing being shown, it does not collide with the existing
//! seven, and it leaves room for a sibling noun later without a
//! `hooks`-prefixed sub-namespace that would have exactly one member.
//!
//! The command **reads a sidecar `generate` wrote**; it does not re-scan
//! the project. That is the load-bearing decision, not an optimisation:
//! a `routes` that discovered the project itself would be a second
//! pipeline whose answer could disagree with the build's, and "the
//! inspector said X, the game did Y" is the one failure this feature
//! cannot have. It also means `routes` needs no populated package cache,
//! no backend template and no renderer — the issue's *"output works
//! without launching the renderer"* is structural here rather than
//! tested for.
//!
//! The cost is honest and stated in the output: the report is as old as
//! the last `generate`. A missing sidecar is not an error condition to
//! decode — it says to run `generate`.
//!
//! ## It inspects; it does not enforce
//!
//! `routes` exits 0 whenever it could produce a report, even when that
//! report lists a handler matching no event. Two reasons. The issue is
//! explicit that *"intentionally unobserved events are not automatically
//! errors"*, and this repo already has an enforcement command (`check`)
//! with an allowlist and a non-zero exit. An inspector that fails builds
//! would be a second, weaker lint. The one thing it does refuse to do is
//! render a report whose `schema` it does not recognise.

const std = @import("std");
const gen = @import("root.zig");

const hook_routes = gen.hook_routes;

const usage =
    \\labelle-assembler routes — show the generated hook event routes
    \\
    \\Usage:
    \\  labelle-assembler routes --project-root <path> [options]
    \\
    \\Options:
    \\  --project-root <path>   Path to the game project (containing project.labelle)
    \\  --json                  Emit the machine-readable report instead of the
    \\                          human one (schema `labelle.hook-routes/v1`)
    \\  --event <tag>           Show only this event's route, by its final
    \\                          generated union tag (`pulse`, `citizens__needs_low`)
    \\  --receiver <id>         Show only this receiver, by its id — its source
    \\                          path minus `.zig` (`hooks/animation_hooks`)
    \\
    \\Reads `<project>/.labelle/hook_routes.json`, written by `generate`. Run
    \\`generate` first; the report reflects that run, not the working tree.
    \\
;

pub fn cmdRoutes(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var project_root: ?[]const u8 = null;
    var as_json = false;
    var filter: hook_routes.Filter = .{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--project-root")) {
            project_root = args.next() orelse return missing(io, "--project-root");
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
        } else if (std.mem.eql(u8, arg, "--event")) {
            filter.event = args.next() orelse return missing(io, "--event");
        } else if (std.mem.startsWith(u8, arg, "--event=")) {
            filter.event = arg["--event=".len..];
        } else if (std.mem.eql(u8, arg, "--receiver")) {
            filter.receiver = args.next() orelse return missing(io, "--receiver");
        } else if (std.mem.startsWith(u8, arg, "--receiver=")) {
            filter.receiver = arg["--receiver=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeStderr(io, usage);
            return;
        } else {
            std.log.err("labelle-assembler routes: unknown flag '{s}'", .{arg});
            writeStderr(io, "\n" ++ usage);
            std.process.exit(2);
        }
    }

    const root = project_root orelse {
        std.log.err("labelle-assembler routes: --project-root is required", .{});
        writeStderr(io, "\n" ++ usage);
        std.process.exit(2);
    };

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const labelle_dir = try std.fs.path.join(arena, &.{ root, ".labelle" });

    const rendered = renderRoutes(arena, labelle_dir, as_json, filter) catch |err| switch (err) {
        error.SidecarMissing => {
            // Not a stack trace to decode — the fix, spelled out.
            std.log.err(
                "labelle-assembler routes: no hook-route report at '{s}/{s}'.\n" ++
                    "  Run `labelle-assembler generate --project-root {s}` first — the report is\n" ++
                    "  written by `generate`, from the same data that emits the receiver tuple.",
                .{ labelle_dir, hook_routes.ROUTES_FILENAME, root },
            );
            std.process.exit(1);
        },
        error.UnknownSchema => {
            std.log.err(
                "labelle-assembler routes: '{s}/{s}' does not carry schema '{s}'.\n" ++
                    "  It was written by a different assembler version. Re-run `generate`.",
                .{ labelle_dir, hook_routes.ROUTES_FILENAME, hook_routes.SCHEMA },
            );
            std.process.exit(1);
        },
        else => return err,
    };
    writeStdout(io, rendered);
}

/// Load the sidecar and render it. Split out from `cmdRoutes` so the
/// tests exercise the whole load → filter → render path without a
/// process exit in the middle.
pub fn renderRoutes(
    arena: std.mem.Allocator,
    labelle_dir: []const u8,
    as_json: bool,
    filter: hook_routes.Filter,
) ![]const u8 {
    const report = (try hook_routes.readSidecar(arena, labelle_dir)) orelse return error.SidecarMissing;
    if (!std.mem.eql(u8, report.schema, hook_routes.SCHEMA)) return error.UnknownSchema;

    var aw: std.Io.Writer.Allocating = .init(arena);
    if (as_json) {
        // Filters apply to JSON too, through the SAME writer — a
        // narrowed report is still a valid `labelle.hook-routes/v1`
        // document, so a tool can pipe `--event X --json` into the same
        // parser it uses for the whole file.
        try hook_routes.writeJson(&aw.writer, try applyFilter(arena, report, filter));
    } else {
        try hook_routes.writeText(&aw.writer, report, filter);
    }
    return aw.written();
}

/// Narrow a report to one event and/or one receiver.
///
/// Indices are NOT renumbered: a receiver keeps the `order` it holds in
/// the full tuple, and a listener keeps its global position. A filtered
/// view is a lens on the real sequence, not a re-derived smaller one —
/// renumbering would produce a document that looks authoritative and
/// disagrees with the build.
fn applyFilter(
    arena: std.mem.Allocator,
    report: hook_routes.Report,
    filter: hook_routes.Filter,
) !hook_routes.Report {
    if (filter.event == null and filter.receiver == null) return report;

    var events: std.ArrayList(hook_routes.Event) = .empty;
    for (report.events) |ev| {
        if (filter.event) |want| {
            if (!std.mem.eql(u8, want, ev.tag)) continue;
        }
        if (filter.receiver) |want| {
            var hit = false;
            for (ev.listeners) |l| {
                if (std.mem.eql(u8, l.receiver, want)) hit = true;
            }
            if (!hit) continue;
        }
        try events.append(arena, ev);
    }

    // RETAIN every receiver a retained event actually reaches, even one the
    // `--receiver` filter would otherwise exclude.
    //
    // The filter selects which EVENTS are shown; it does not rewrite what a
    // shown event's route IS. Previously `receivers[]` was filtered while
    // `Event.listeners[]` kept every entry, so a filtered document carried
    // listener rows naming receivers absent from `receivers[]` — a dangling
    // join key for any JSON consumer, and #858's tracing correlates on
    // exactly that key (#724 review).
    //
    // The alternative — filtering the listener rows to match — was
    // rejected: it makes a route look like it has one listener when it has
    // four, which is a worse lie for an inspector than showing an extra
    // receiver definition.
    var receivers: std.ArrayList(hook_routes.Receiver) = .empty;
    for (report.receivers) |r| {
        var referenced = false;
        for (events.items) |ev| {
            for (ev.listeners) |l| {
                if (std.mem.eql(u8, l.receiver, r.id)) referenced = true;
            }
        }
        if (!referenced) {
            // Not reached by any retained event. Keep it only when it IS
            // the receiver asked for, so `--receiver X` on a receiver that
            // listens to nothing still shows X rather than an empty report.
            if (filter.receiver) |want| {
                if (!std.mem.eql(u8, r.id, want)) continue;
            } else continue;
        }
        try receivers.append(arena, r);
    }

    var out = report;
    out.events = try events.toOwnedSlice(arena);
    out.receivers = try receivers.toOwnedSlice(arena);
    // A filtered document must not carry whole-project findings: an
    // unmatched handler on some other receiver is not part of this route.
    out.unmatched_handlers = &.{};
    return out;
}

fn missing(io: std.Io, flag: []const u8) noreturn {
    std.log.err("labelle-assembler routes: {s} requires a value", .{flag});
    writeStderr(io, "\n" ++ usage);
    std.process.exit(2);
}

fn writeStdout(io: std.Io, msg: []const u8) void {
    std.Io.File.stdout().writeStreamingAll(io, msg) catch {};
}

fn writeStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

// ─── Tests ──────────────────────────────────────────────────────────────

test "renderRoutes: a missing sidecar is a nameable condition, not a raw error" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    // The whole point: `routes` on a project that has never been
    // generated must be able to say "run generate first" rather than
    // surfacing a FileNotFound the user has to interpret.
    try std.testing.expectError(error.SidecarMissing, renderRoutes(arena, dir, false, .{}));
}

test "renderRoutes: renders both forms, and a filter narrows without renumbering" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "hooks");
    try tmp.dir.writeFile(io, .{ .sub_path = "hooks/first.zig", .data = 
        \\pub const First = struct {
        \\    pub fn ping(self: *First, ev: anytype) void { _ = self; _ = ev; }
        \\};
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "hooks/second.zig", .data = 
        \\pub const Second = struct {
        \\    pub fn ping(self: *Second, ev: anytype) void { _ = self; _ = ev; }
        \\};
        \\
    });
    try tmp.dir.createDirPath(io, "events");
    try tmp.dir.writeFile(io, .{ .sub_path = "events/ping.zig", .data = 
        \\pub const Ping = struct { n: u8 = 0 };
        \\
    });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);

    const cfg: gen.ProjectConfig = .{ .y_axis = .up, .name = "routes-cmd", .backend = .raylib, .ecs = .mock };
    try hook_routes.emitSidecar(allocator, dir, .{
        .cfg = cfg,
        .game_dir = dir,
        .target_dir = dir,
        .hook_names = &.{ "first", "second" },
        .event_names = &.{"ping"},
    });

    const text = try renderRoutes(arena, dir, false, .{});
    try std.testing.expect(std.mem.indexOf(u8, text, "DISPATCH ORDER") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hooks/first") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "hooks/second") != null);

    const json = try renderRoutes(arena, dir, true, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, hook_routes.SCHEMA) != null);

    // A filtered JSON document is still a valid report — a tool can pipe
    // `--event … --json` into the same parser it uses for the whole file.
    const one = try renderRoutes(arena, dir, true, .{ .receiver = "hooks/second" });
    const parsed = try hook_routes.parseReport(arena, one);

    // THE JOIN MUST NOT DANGLE. A filtered document selects which EVENTS
    // appear; it does not rewrite what a shown event's route is. So every
    // `listeners[].receiver` has to resolve in `receivers[]` — including
    // receivers the filter itself would exclude, because the retained event
    // genuinely reaches them. Asserting only "receivers.len == 1" (as an
    // earlier revision did) encoded the dangling behaviour as correct
    // (#724 review).
    for (parsed.events) |ev| {
        for (ev.listeners) |l| {
            var found = false;
            for (parsed.receivers) |r| {
                if (std.mem.eql(u8, r.id, l.receiver)) found = true;
            }
            try std.testing.expect(found);
        }
    }

    // The receiver asked for is present…
    var has_second = false;
    for (parsed.receivers) |r| {
        if (std.mem.eql(u8, r.id, "hooks/second")) {
            has_second = true;
            // …and keeps the index it holds in the FULL tuple. Renumbering
            // to 0 would produce a document that looks authoritative and
            // disagrees with the build.
            try std.testing.expectEqual(@as(usize, 1), r.order);
        }
    }
    try std.testing.expect(has_second);
}
