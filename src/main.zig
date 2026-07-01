//! labelle-assembler — standalone binary entry point.
//!
//! Phase 1 of the assembler split (RFC #122 / PR #123). This binary
//! coexists with the in-process generator that the `labelle` CLI imports
//! as a Zig module via `b.dependency("generator", .{})`. Adding it here
//! is purely additive — no existing code path changes.
//!
//! The binary exposes a subprocess protocol the CLI launcher will adopt
//! in Phase 2 (opt-in via `LABELLE_ASSEMBLER` env var) and Phase 3
//! (project-pinned `assembler_version` in `project.labelle`).
//!
//! Cache: `generate` reads the local package cache (engine/core/gfx
//! packages where the generator expects them). The binary now owns cache
//! management itself via the `install`/`clean`/`upgrade` subcommands —
//! run `install` before `generate`, or let the `labelle` CLI orchestrate
//! it. Running the binary directly is intended for testing the
//! CLI ↔ assembler boundary and for power users who manage their own
//! cache.

const std = @import("std");
const gen = @import("root.zig");
const cache_cmd = @import("cache_cmd.zig");
const init_cmd = @import("init_cmd.zig");
const add_cmd = @import("add_cmd.zig");

/// Wire protocol version for CLI ↔ assembler subprocess communication.
/// Bump when the command surface or output format changes in a way the
/// CLI launcher needs to detect. The launcher reads this via
/// `labelle-assembler --protocol-version` before invoking any subcommand.
///
/// v2 (#217 phase 1): added the `install`, `clean`, `upgrade` cache
/// subcommands. The CLI delegates cache management to the binary instead
/// of running the in-process generator's cache helpers.
///
/// v3 (#217 phase 3): added the `init` subcommand. The CLI delegates
/// new-project scaffolding to the binary instead of its in-process
/// `cmdInit`.
///
/// v4 (Packs #271): added the `add` subcommand (`add pack <name>` /
/// `add feature <kind> <name>`). The CLI delegates pack/feature-unit
/// scaffolding to the binary.
pub const PROTOCOL_VERSION: u32 = 4;

const usage =
    \\labelle-assembler — code generator for the labelle game toolkit
    \\
    \\Usage:
    \\  labelle-assembler --protocol-version
    \\  labelle-assembler --help
    \\  labelle-assembler generate --project-root <path> [options]
    \\  labelle-assembler install [--project-root <path>] [pkg [version]]
    \\  labelle-assembler clean [--dry-run] [--project-root <path>]
    \\  labelle-assembler upgrade --project-root <path> [pkg [version]]
    \\  labelle-assembler init <name> [dir] [options]
    \\  labelle-assembler add pack <name>
    \\  labelle-assembler add feature <kind> <name>
    \\
    \\Subcommands:
    \\  generate    Materialize .labelle/<target>/ from project.labelle
    \\  install     Fetch packages into the local cache
    \\  clean       Prune unused cached package versions
    \\  upgrade     Bump version fields in project.labelle
    \\  init        Scaffold a new project directory
    \\  add         Scaffold a pack or a feature-unit (need/role/status)
    \\
    \\Generate options:
    \\  --project-root <path>   Path to game project (containing project.labelle)
    \\  --scene <name>          Override the initial prefab from project.labelle
    \\  --platform <name>       Override target platform (desktop, wasm, ios, android)
    \\  --backend <name>        Override graphics backend (raylib, sokol, sdl, bgfx, wgpu)
    \\
    \\Notes:
    \\  `generate` reads the local package cache; run `install` first (or
    \\  let the `labelle` CLI do it) to populate it. The `install`, `clean`,
    \\  and `upgrade` subcommands manage that cache directly.
    \\
    \\See: https://github.com/labelle-toolkit/labelle-assembler
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    gen.initGlobalIo(init.minimal);

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.skip(); // program name

    const first = args.next() orelse {
        writeStderr(io, usage);
        std.process.exit(2);
    };

    if (std.mem.eql(u8, first, "--protocol-version")) {
        // Protocol version goes to stdout so callers can capture it via
        // a normal pipe. Everything else goes to stderr.
        const stdout = std.Io.File.stdout();
        var buf: [16]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{d}\n", .{PROTOCOL_VERSION});
        try stdout.writeStreamingAll(io, msg);
        return;
    }

    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "help")) {
        writeStderr(io, usage);
        return;
    }

    if (std.mem.eql(u8, first, "generate")) {
        try cmdGenerate(allocator, io, &args);
        return;
    }

    if (std.mem.eql(u8, first, "install")) {
        try cache_cmd.cmdInstall(allocator, io, &args);
        return;
    }

    if (std.mem.eql(u8, first, "clean")) {
        try cache_cmd.cmdClean(allocator, io, &args);
        return;
    }

    if (std.mem.eql(u8, first, "upgrade")) {
        try cache_cmd.cmdUpgrade(allocator, io, &args);
        return;
    }

    if (std.mem.eql(u8, first, "init")) {
        try init_cmd.cmdInit(allocator, io, &args);
        return;
    }

    if (std.mem.eql(u8, first, "add")) {
        try add_cmd.cmdAdd(allocator, io, &args);
        return;
    }

    std.log.err("labelle-assembler: unknown subcommand '{s}'", .{first});
    writeStderr(io, "\n" ++ usage);
    std.process.exit(2);
}

/// Write directly to stderr without a level prefix. Used for the usage
/// banner — `std.log.*` would prepend `info:`/`error:`, and `std.debug.print`
/// is intended for development-time printf debugging, not production output.
fn writeStderr(io: std.Io, msg: []const u8) void {
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

fn cmdGenerate(allocator: std.mem.Allocator, io: std.Io, args: *std.process.Args.Iterator) !void {
    var project_root: ?[]const u8 = null;
    var scene_override: ?[]const u8 = null;
    var platform_override: ?gen.Platform = null;
    var backend_override: ?gen.Backend = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--project-root")) {
            project_root = args.next() orelse {
                std.log.err("labelle-assembler: --project-root requires a value", .{});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--project-root=")) {
            project_root = arg["--project-root=".len..];
        } else if (std.mem.eql(u8, arg, "--scene")) {
            scene_override = args.next() orelse {
                std.log.err("labelle-assembler: --scene requires a value", .{});
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, arg, "--scene=")) {
            scene_override = arg["--scene=".len..];
        } else if (std.mem.eql(u8, arg, "--platform")) {
            const val = args.next() orelse {
                std.log.err("labelle-assembler: --platform requires a value", .{});
                std.process.exit(2);
            };
            platform_override = parsePlatform(val) orelse std.process.exit(2);
        } else if (std.mem.startsWith(u8, arg, "--platform=")) {
            platform_override = parsePlatform(arg["--platform=".len..]) orelse std.process.exit(2);
        } else if (std.mem.eql(u8, arg, "--backend")) {
            const val = args.next() orelse {
                std.log.err("labelle-assembler: --backend requires a value", .{});
                std.process.exit(2);
            };
            backend_override = parseBackend(val) orelse std.process.exit(2);
        } else if (std.mem.startsWith(u8, arg, "--backend=")) {
            backend_override = parseBackend(arg["--backend=".len..]) orelse std.process.exit(2);
        } else {
            std.log.err("labelle-assembler generate: unknown flag '{s}'", .{arg});
            std.process.exit(2);
        }
    }

    const root = project_root orelse {
        std.log.err("labelle-assembler generate: --project-root is required", .{});
        std.process.exit(2);
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var cfg = readProjectConfig(arena_alloc, io, root) catch |err| {
        std.log.err("labelle-assembler: failed to read project.labelle in '{s}': {s}", .{ root, @errorName(err) });
        std.process.exit(1);
    };

    cfg.normalizeInitialPrefab();
    if (scene_override) |s| cfg.initial_prefab = s;
    if (platform_override) |p| cfg.platform = p;
    if (backend_override) |b| cfg.backend = b;

    // Resolve GUI plugin (reads gui.labelle manifest from plugin directory)
    // and populates cfg.resolved_gui. Must run before gen.generate so the
    // generated build.zig/zon and main.zig include the GUI module wiring.
    gen.resolveGuiPlugin(arena_alloc, &cfg, root) catch |err| {
        std.log.err("labelle-assembler: failed to resolve GUI plugin: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    const output_dir = try std.fs.path.join(allocator, &.{ root, ".labelle" });
    defer allocator.free(output_dir);

    gen.generate(allocator, cfg, output_dir, root, .{}) catch |err| {
        std.log.err("labelle-assembler: generate failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    const target_name = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ cfg.backendName(), @tagName(cfg.platform) });
    defer allocator.free(target_name);
    std.log.info("labelle-assembler: generated .labelle/{s}/", .{target_name});

    // Issue #83: also emit a backend-agnostic test target at .labelle/tests/.
    // Uses the null backend so `zig build test` works on any host without
    // pulling in the chosen backend's native libs (X11/GL/Cocoa/etc.).
    gen.generateTestsTarget(allocator, cfg, output_dir, root) catch |err| {
        std.log.err("labelle-assembler: tests target generate failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    std.log.info("labelle-assembler: generated .labelle/tests/", .{});

    // NOTE: build.zig.zon's `.fingerprint` field is left at the placeholder
    // value emitted by the generator template. The CLI patches it via a
    // post-generate `runner.fixFingerprint` pass that runs `zig build`,
    // parses Zig's "use this value: 0x..." error from stderr, and rewrites
    // the field. Until Phase 2 wires the launcher to do that post-step
    // around the subprocess invocation, callers of this binary must run
    // an equivalent fixFingerprint pass before `zig build` will succeed
    // against the generated tree. Tracked for follow-up.
}

/// Comptime-built " name1 name2 ..." string for an enum's fields. Folds
/// to a single string literal in the binary; the `comptime blk:` form
/// (rather than a comptime-only function body) is what lets a runtime
/// caller obtain the value as if it were a string literal.
fn enumFieldList(comptime E: type) []const u8 {
    return comptime blk: {
        var out: []const u8 = "";
        for (@typeInfo(E).@"enum".fields) |f| out = out ++ " " ++ f.name;
        break :blk out;
    };
}

/// Parse a --platform value into the Platform enum, or log an error
/// listing accepted values and return null. Caller is expected to exit
/// with code 2 on null.
fn parsePlatform(val: []const u8) ?gen.Platform {
    if (std.meta.stringToEnum(gen.Platform, val)) |p| return p;
    std.log.err("labelle-assembler: unknown platform '{s}'\n  expected one of:{s}", .{ val, enumFieldList(gen.Platform) });
    return null;
}

/// Parse a --backend value into the Backend enum, or log an error
/// listing accepted values and return null. Caller is expected to exit
/// with code 2 on null.
fn parseBackend(val: []const u8) ?gen.Backend {
    if (std.meta.stringToEnum(gen.Backend, val)) |b| return b;
    std.log.err("labelle-assembler: unknown backend '{s}'\n  expected one of:{s}", .{ val, enumFieldList(gen.Backend) });
    return null;
}

/// Inline copy of `cli/config.zig:readProjectConfig`. Lives here so the
/// assembler binary doesn't pull in CLI-side modules. The CLI's version
/// will route through this binary in Phase 2; this duplication is
/// intentional and temporary.
fn readProjectConfig(allocator: std.mem.Allocator, io: std.Io, project_dir: []const u8) !gen.ProjectConfig {
    @setEvalBranchQuota(10000);
    const labelle_path = try std.fs.path.join(allocator, &.{ project_dir, "project.labelle" });
    defer allocator.free(labelle_path);

    const source_raw = try std.Io.Dir.cwd().readFileAlloc(io, labelle_path, allocator, .limited(1024 * 1024));
    defer allocator.free(source_raw);

    const source = try allocator.dupeZ(u8, source_raw);
    return try std.zon.parse.fromSliceAlloc(gen.ProjectConfig, allocator, source, null, .{});
}

// Pull in the subcommand modules' tests when this file is the test root.
test {
    std.testing.refAllDecls(@import("init_cmd.zig"));
    std.testing.refAllDecls(@import("cache_cmd.zig"));
    std.testing.refAllDecls(@import("add_cmd.zig"));
}
