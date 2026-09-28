//! `labelle-assembler describe` — argument parsing and output for the
//! backend/target query (labelle-cli RFC #471, item D1). The answer itself
//! lives in `describe.zig`; see that file for what it resolves and why.
//!
//! Exit codes: 0 whenever an answer was produced (including
//! `supported: false` — describe is a query, not a gate), 1 when
//! `project.labelle` cannot be read or parsed, 2 on a usage error.

const std = @import("std");
const gen = @import("root.zig");

const describe = gen.describe;

const usage =
    \\labelle-assembler describe — the backend/target facts of a project
    \\
    \\Usage:
    \\  labelle-assembler describe --project-root <path> --target <name> [--json]
    \\
    \\Options:
    \\  --project-root <path>   Path to the game project (containing project.labelle)
    \\  --target <name>         Target to describe (desktop, wasm, android, ios)
    \\  --json                  Machine-readable output (schema `labelle.describe/v1`)
    \\
    \\Prints the generated target dir, the resolved backend package (name, id,
    \\repo, version, local path), the package dir when it is installed, the
    \\asset format for the target, and whether the backend supports it (with a
    \\reason when it does not). Offline: reads project.labelle and, when the
    \\backend is installed, its manifest. Nothing is fetched or generated.
    \\
;

pub fn cmdDescribe(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var project_root: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var as_json = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--project-root")) {
            project_root = args.next() orelse return missing(io, "--project-root");
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else if (std.mem.eql(u8, arg, "--target")) {
            target = args.next() orelse return missing(io, "--target");
        } else if (std.mem.startsWith(u8, arg, "--target=")) {
            target = arg["--target=".len..];
        } else if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            writeStderr(io, usage);
            return;
        } else {
            std.log.err("labelle-assembler describe: unknown flag '{s}'", .{arg});
            writeStderr(io, "\n" ++ usage);
            std.process.exit(2);
        }
    }

    const root = project_root orelse {
        std.log.err("labelle-assembler describe: --project-root is required", .{});
        writeStderr(io, "\n" ++ usage);
        std.process.exit(2);
    };
    const tgt = target orelse {
        std.log.err("labelle-assembler describe: --target is required", .{});
        writeStderr(io, "\n" ++ usage);
        std.process.exit(2);
    };

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = readProjectConfig(arena, io, root) catch |err| {
        std.log.err("labelle-assembler describe: failed to read project.labelle in '{s}': {s}", .{ root, @errorName(err) });
        std.process.exit(1);
    };

    const d = describe.describe(arena, cfg, root, tgt) catch |err| {
        std.log.err("labelle-assembler describe: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    var buf: [4096]u8 = undefined;
    // Streaming, not positional: stdout may be a pipe or a file being appended to.
    var fw = std.Io.File.stdout().writerStreaming(io, &buf);
    if (as_json) {
        try describe.writeJson(&fw.interface, d);
    } else {
        try describe.writeText(&fw.interface, d);
    }
    try fw.interface.flush();
}

fn readProjectConfig(arena: std.mem.Allocator, io: std.Io, project_dir: []const u8) !gen.ProjectConfig {
    const path = try std.fs.path.join(arena, &.{ project_dir, "project.labelle" });
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024));
    return gen.plugin_params.parseProjectConfig(arena, try arena.dupeZ(u8, raw));
}

fn missing(io: std.Io, flag: []const u8) void {
    std.log.err("labelle-assembler describe: {s} requires a value", .{flag});
    writeStderr(io, "\n" ++ usage);
    std.process.exit(2);
}

fn writeStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}
