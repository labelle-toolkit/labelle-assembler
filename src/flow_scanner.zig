//! Scan `<game>/scripts/flows/*.flow.zon`, emit Zig sources via the
//! `flow_codegen` sub-package, and stitch the emitted files into the
//! existing script-registry pipeline.
//!
//! The output files are written to `<target>/scripts/flows/<stem>.zig`.
//! Because `<target>/scripts/` is a relative symlink back into the
//! game source tree (see `scanner.linkDir`), the generated `.zig` ends
//! up sitting next to its source `.flow.zon` on disk — the same
//! co-location convention plugin-shipped scripts use today (RFC plugin
//! controllers §2). Authors are expected to `.gitignore` the emitted
//! files; the assembler treats them as freshly regenerated on every
//! `zig build generate` pass.
//!
//! Errors from `flow_codegen.flow_io.parseFlow` / `codegen.renderFlowZig`
//! are surfaced as `flows/<stem>.flow.zon: <err>` lines written
//! directly to stderr (matching the existing `main_zig.checkBasenameCollisions`
//! diagnostic style) and the typed error is returned to the caller, so a
//! malformed flow fails `generate` with a non-zero exit instead of
//! silently producing a stale `.zig`. Writing to stderr rather than
//! `std.log.err` keeps the Zig test runner from classifying expected
//! diagnostics as logged-error test failures.

const std = @import("std");
const flow_codegen = @import("flow_codegen");
const script_scanner = @import("script_scanner.zig");

const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;

/// Result of a flow scan. The arena owns every byte the synthetic
/// `ScriptEntry`s reference (their `filename` / `rel_path` slices),
/// so the caller's only cleanup responsibility is `deinit()`.
pub const FlowScanResult = struct {
    arena: std.heap.ArenaAllocator,
    /// Synthetic entries appended to the script scanner's existing
    /// list before `getEntries()` is captured. `rel_path` matches the
    /// on-disk layout `flows/<stem>.zig` so the existing AllScripts
    /// block emits `@import("scripts/flows/<stem>.zig")` unmodified.
    entries: []ScriptEntry,

    pub fn deinit(self: *FlowScanResult) void {
        self.arena.deinit();
    }
};

/// Walk `<game_dir>/scripts/flows/` (non-recursive — v1 keeps flows
/// flat) for `*.flow.zon` files. For each match: parse, codegen, write
/// `<target_dir>/scripts/flows/<stem>.zig`, and emit a `ScriptEntry`
/// pointing at it. Missing source directory returns an empty result —
/// projects without flows pay zero cost.
pub fn scanAndEmit(
    allocator: std.mem.Allocator,
    game_dir: []const u8,
    target_dir: []const u8,
) !FlowScanResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    var entries = std.ArrayList(ScriptEntry){};

    const src_flows = try std.fs.path.join(allocator, &.{ game_dir, "scripts", "flows" });
    defer allocator.free(src_flows);

    var src_dir = std.fs.cwd().openDir(src_flows, .{ .iterate = true }) catch |err| switch (err) {
        // Empty flows/ dir is the common case for projects that don't
        // use the editor — silently no-op rather than forcing every
        // project to materialise the directory.
        error.FileNotFound => return .{
            .arena = arena,
            .entries = try entries.toOwnedSlice(arena_alloc),
        },
        else => return err,
    };
    defer src_dir.close();

    // Output dir — same path through the scripts/ symlink. `makePath`
    // is idempotent and creates the `flows/` directory next to the
    // game's `.flow.zon` sources when missing.
    const dst_flows = try std.fs.path.join(allocator, &.{ target_dir, "scripts", "flows" });
    defer allocator.free(dst_flows);
    try std.fs.cwd().makePath(dst_flows);

    // Stable iteration order — collect filenames first, sort, then
    // process. Matters because the codegen step is allowed to fail
    // and we want the error message to be reproducible across runs.
    var filenames = std.ArrayList([]const u8){};
    defer {
        for (filenames.items) |n| allocator.free(n);
        filenames.deinit(allocator);
    }
    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".flow.zon")) continue;
        try filenames.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, filenames.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    for (filenames.items) |name| {
        const stem_view = flow_codegen.flow_io.displayNameFromPath(name);

        const src_path = try std.fs.path.join(allocator, &.{ src_flows, name });
        defer allocator.free(src_path);

        var loaded = flow_codegen.flow_io.loadFromFile(allocator, src_path) catch |err| {
            reportFlowError(name, err);
            return err;
        };
        defer loaded.deinit();

        const generated = flow_codegen.codegen.renderFlowZig(
            allocator,
            loaded.flow,
            .{ .flow_name = stem_view },
        ) catch |err| {
            reportFlowError(name, err);
            return err;
        };
        defer allocator.free(generated);

        // Write `<target>/scripts/flows/<stem>.zig`, truncating an
        // earlier emission. The `<stem>` is reconstituted in the
        // arena so the synthetic ScriptEntry can borrow stable
        // lifetime from it without juggling separate ownership of
        // `name` (which lives on the scratch allocator).
        const stem_owned = try arena_alloc.dupe(u8, stem_view);
        const out_filename = try std.fmt.allocPrint(arena_alloc, "{s}.zig", .{stem_owned});
        const rel_path = try std.fmt.allocPrint(arena_alloc, "flows/{s}", .{out_filename});

        const dst_path = try std.fs.path.join(allocator, &.{ dst_flows, out_filename });
        defer allocator.free(dst_path);

        var out_file = try std.fs.cwd().createFile(dst_path, .{ .truncate = true });
        defer out_file.close();
        try out_file.writeAll(generated);

        // Flows aren't state-gated in v1 — they always run. Match the
        // global-script shape (`states = &.{}`, `subdir = null`) so
        // the existing AllScripts emit picks them up via the simple
        // import branch rather than the state-wrapper branch.
        try entries.append(arena_alloc, .{
            .name = stem_owned,
            .filename = out_filename,
            .states = &.{},
            .sort_order = null,
            .subdir = null,
            .rel_path = rel_path,
            .plugin_name = null,
            .plugin_index = 0,
        });
    }

    return .{
        .arena = arena,
        .entries = try entries.toOwnedSlice(arena_alloc),
    };
}

/// Write a one-line diagnostic in the canonical `flows/<file>: <err>`
/// shape directly to stderr. Best-effort — stderr write failures are
/// swallowed because there's nothing actionable a caller could do
/// about them, and the typed error is what actually fails the build.
fn reportFlowError(filename: []const u8, err: anyerror) void {
    const stderr = std.fs.File.stderr();
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "flows/{s}: {s}\n", .{ filename, @errorName(err) }) catch return;
    stderr.writeAll(msg) catch {};
}
