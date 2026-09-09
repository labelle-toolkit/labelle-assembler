//! Static hook-route inspection — labelle-assembler#724, child of the
//! hooks epic labelle-engine#854. Design note:
//! `docs/design/hook-route-inspection.md`.
//!
//! ## The friction
//!
//! From the epic: *"Finding final event names, listeners and delivery
//! paths currently requires inspecting generated code or adding ad hoc
//! logging."* An author who wants to know which listeners `citizens__needs_low`
//! reaches, in what order, and whether an earlier one can consume it,
//! has to open `.labelle/<target>/main.zig` and read a `MergeHooks`
//! tuple against every hook file's decl list.
//!
//! ## The shape of the answer
//!
//! A **sidecar**, not a re-scan. `<game>/.labelle/hook_routes.json` is
//! written by `generate`, next to `manifest.json` and
//! `flow_catalog.json`, from the data that generate already holds — and
//! critically, from the SAME `buildReceiverPlan` call that produces the
//! receiver tuple in `main.zig`. `labelle-assembler routes` then reads
//! that file and renders it.
//!
//! That split is the whole design. The alternative — a `routes` command
//! that re-scans the project independently — would have been a second
//! discovery pipeline whose answer could differ from the build's, which
//! is precisely the failure an inspector must not have. Reading a
//! generate-time artifact means the report is a *record of what was
//! emitted*, and the command needs no package cache, no backend
//! template, and no renderer.
//!
//! The cost is stated rather than hidden: the report is as old as the
//! last `generate`. `routes` says so when the sidecar is missing, and the
//! sidecar carries the assembler version that wrote it.
//!
//! ## Layout
//!
//!   * `hook_routes/model.zig`  — the `labelle.hook-routes/v1` schema.
//!   * `hook_routes/build.zig`  — `buildReport`, over generate's scans.
//!   * `hook_routes/render.zig` — the JSON and human renderers.
//!
//! This barrel adds only the filesystem edges: write the sidecar, read it
//! back.

const std = @import("std");
const config = @import("config.zig");

pub const model = @import("hook_routes/model.zig");
pub const build = @import("hook_routes/build.zig");
pub const render = @import("hook_routes/render.zig");

pub const SCHEMA = model.SCHEMA;
pub const ROUTES_FILENAME = model.ROUTES_FILENAME;
pub const Report = model.Report;
pub const Receiver = model.Receiver;
pub const Event = model.Event;
pub const Listener = model.Listener;
pub const Emitter = model.Emitter;
pub const Inputs = build.Inputs;
pub const buildReport = build.buildReport;
pub const writeJson = render.writeJson;
pub const writeText = render.writeText;
pub const Filter = render.Filter;

/// Build the report and write `<labelle_dir>/hook_routes.json`.
///
/// Additive and best-effort at the call site, exactly like the manifest
/// and flow-catalog sidecars: `root.zig:generate` logs a failure and
/// carries on, because a missing inspection artifact must never fail a
/// build that would otherwise succeed.
pub fn emitSidecar(allocator: std.mem.Allocator, labelle_dir: []const u8, in: Inputs) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const report = try buildReport(aa, in);

    // Build in the arena, copy out for the write — the same lifetime
    // dance `manifest/emit.zig` uses.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeJson(&aw.writer, report);

    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, labelle_dir);
    var dir = try cwd.openDir(io, labelle_dir, .{});
    defer dir.close(io);
    // ATOMIC: write a temp beside the target, then rename over it.
    // `createFile` truncates the real sidecar immediately, so a writer that
    // failed part-way (disk full — which happened on this machine today —
    // a crash, a kill) left a TRUNCATED or half-written `hook_routes.json`
    // in place. `routes` would then either fail to parse it or, worse,
    // parse a prefix and present a partial route list as the current one
    // (#724 review). Rename is atomic on POSIX and on Windows via
    // `renameAt`, so the sidecar is either the previous complete file or
    // the new complete file, never a mixture.
    const tmp_name = ROUTES_FILENAME ++ ".tmp";
    {
        const file = try dir.createFile(io, tmp_name, .{});
        defer file.close(io);
        file.writeStreamingAll(io, aw.written()) catch |err| {
            // Do not leave the temp behind to be mistaken for a real file.
            dir.deleteFile(io, tmp_name) catch {};
            return err;
        };
    }
    dir.rename(tmp_name, dir, ROUTES_FILENAME, io) catch |err| {
        dir.deleteFile(io, tmp_name) catch {};
        return err;
    };
}

/// Read a sidecar back into the typed model.
///
/// `ignore_unknown_fields` is the schema's forward-compatibility promise:
/// an additive key in a later `labelle.hook-routes/v1` writer must not
/// break an older reader, so only a BREAKING change bumps the version
/// segment. A caller that cares should compare `report.schema` against
/// `SCHEMA` and say something useful; `routes` does.
///
/// Leaky by design — everything lands in the caller's arena.
pub fn parseReport(aa: std.mem.Allocator, bytes: []const u8) !Report {
    return std.json.parseFromSliceLeaky(Report, aa, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Read `<labelle_dir>/hook_routes.json`. Returns null when the sidecar
/// does not exist, which the caller turns into "run `generate` first"
/// rather than an unexplained error.
pub fn readSidecar(aa: std.mem.Allocator, labelle_dir: []const u8) !?Report {
    const io = config.globalIo();
    const path = try std.fs.path.join(aa, &.{ labelle_dir, ROUTES_FILENAME });
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        // Only a genuinely ABSENT sidecar is "run generate first". Mapping
        // every error to null turned a permissions problem, an I/O error or
        // an over-cap file into that same message, sending the reader to
        // re-run a generate that will not help (#724 review).
        error.FileNotFound => return null,
        else => return err,
    };
    return try parseReport(aa, bytes);
}

test {
    std.testing.refAllDecls(@This());
}
