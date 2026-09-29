//! `generate` is byte-stable and non-destructive (labelle-assembler#674).
//!
//! Two consecutive generates with unchanged inputs must leave the generated
//! tree untouched: identical bytes AND identical file identity (inode) and
//! mtime, including the staged `deps/` packages — Zig's cache and a
//! long-lived `zig build --watch` both key on the files, and a delete +
//! re-create of `deps/` drops `--watch`'s directory watches.
//!
//! Every test here asserts the MECHANISM (nothing was rewritten / relinked:
//! same inode, same mtime), not just equal bytes — equal bytes alone were
//! already true before #674, when every run wiped and re-created the tree.

const std = @import("std");
const zspec = @import("zspec");
const generate = @import("generator");
const deps_linker = generate.deps_linker;

const io = std.testing.io;

test {
    zspec.runAll(@This());
}

fn writeFileIn(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(io, sub);
    try dir.writeFile(io, .{ .sub_path = rel, .data = body });
}

/// A minimal Zig package: a zon (optionally with a relative `.path` dep, which
/// the staging rewrite re-anchors) plus one source file.
fn writePackage(dir: std.Io.Dir, root: []const u8, zon_body: []const u8) !void {
    var buf: [256]u8 = undefined;
    try writeFileIn(dir, try std.fmt.bufPrint(&buf, "{s}/build.zig.zon", .{root}), zon_body);
    try writeFileIn(dir, try std.fmt.bufPrint(&buf, "{s}/build.zig", .{root}), "// build\n");
    try writeFileIn(dir, try std.fmt.bufPrint(&buf, "{s}/src/root.zig", .{root}), "pub const x = 1;\n");
}

const plain_zon = ".{ .name = .pkg, .version = \"0.0.0\", .paths = .{\"\"} }\n";

/// A tmp workspace: fake core/gfx/engine + a local backend + a local plugin
/// whose zon has a relative `.path` dep (exercising the zon rewrite), a game
/// dir and an output dir. Every package pin is an ABSOLUTE `local:` path, so
/// nothing touches the package cache.
const Workspace = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    arena: std.heap.ArenaAllocator,

    fn init() !Workspace {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        for ([_][]const u8{ "core", "gfx", "engine", "backend" }) |p| try writePackage(tmp.dir, p, plain_zon);
        try writePackage(tmp.dir, "plugins/fsm",
            \\.{ .name = .fsm, .version = "0.0.0", .paths = .{""}, .dependencies = .{
            \\    .labelle_core = .{ .path = "../../core" },
            \\} }
            \\
        );
        try tmp.dir.createDirPath(io, "game");
        try tmp.dir.createDirPath(io, "out");
        const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
        defer std.testing.allocator.free(root);
        return .{
            .tmp = tmp,
            .root = try std.testing.allocator.dupe(u8, root),
            .arena = .init(std.testing.allocator),
        };
    }

    fn deinit(self: *Workspace) void {
        self.arena.deinit();
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn abs(self: *Workspace, rel: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.root, rel });
    }

    fn local(self: *Workspace, rel: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "local:{s}", .{try self.abs(rel)});
    }

    fn config(self: *Workspace) !generate.ProjectConfig {
        const a = self.arena.allocator();
        const plugins = try a.alloc(generate.PluginDep, 1);
        plugins[0] = .{ .name = "fsm", .repo = try self.local("plugins/fsm") };
        return .{
            .name = "stable-game",
            .backend = .null,
            .backend_package = .{ .name = "null", .repo = try self.local("backend") },
            .ecs = .mock,
            .plugins = plugins,
            .core_version = try self.local("core"),
            .gfx_version = try self.local("gfx"),
            .engine_version = try self.local("engine"),
            // A local assembler pin skips the bundled-slot probe.
            .assembler_version = try self.local("."),
        };
    }

    fn link(self: *Workspace, cfg: generate.ProjectConfig, opts: deps_linker.DepsLinkOptions) !void {
        const deps = try deps_linker.createDepsLinks(std.testing.allocator, cfg, try self.abs("out"), try self.abs("game"), opts);
        deps_linker.freeDepEntries(std.testing.allocator, deps);
    }

    fn stat(self: *Workspace, rel: []const u8) !std.Io.File.Stat {
        return self.tmp.dir.statFile(io, rel, .{});
    }

    fn read(self: *Workspace, rel: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(io, rel, self.arena.allocator(), .limited(1 << 20));
    }

    fn exists(self: *Workspace, rel: []const u8) bool {
        self.tmp.dir.access(io, rel, .{}) catch return false;
        return true;
    }
};

fn expectSameFile(before: std.Io.File.Stat, after: std.Io.File.Stat) !void {
    try std.testing.expectEqual(before.inode, after.inode);
    try std.testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
}

pub const DEPS_NOT_WIPED = struct {
    test "a second staging pass keeps every staged file (same inode + mtime), incl. the rewritten zon" {
        var ws = try Workspace.init();
        defer ws.deinit();
        const cfg = try ws.config();

        try ws.link(cfg, .{});
        const core_src = try ws.stat("out/deps/labelle-core/src/root.zig");
        const fsm_zon = try ws.stat("out/deps/labelle-fsm/build.zig.zon");
        const fsm_zon_bytes = try ws.read("out/deps/labelle-fsm/build.zig.zon");
        // The plugin's relative dep was re-anchored for the deps location
        // (one level deeper than `plugins/fsm`), so the zon is a rewritten
        // copy — the case the old additive pass could not repeat safely.
        try std.testing.expect(std.mem.indexOf(u8, fsm_zon_bytes, "\"../../core\"") == null);

        try ws.link(cfg, .{});
        try expectSameFile(core_src, try ws.stat("out/deps/labelle-core/src/root.zig"));
        try expectSameFile(fsm_zon, try ws.stat("out/deps/labelle-fsm/build.zig.zon"));
        try std.testing.expectEqualStrings(fsm_zon_bytes, try ws.read("out/deps/labelle-fsm/build.zig.zon"));
        // The source package's zon is never written through the hardlink.
        try std.testing.expect(std.mem.indexOf(u8, try ws.read("plugins/fsm/build.zig.zon"), "\"../../core\"") != null);
    }

    test "the tests-target pass (prune = false) re-reconciles without double-rewriting the zon" {
        var ws = try Workspace.init();
        defer ws.deinit();
        const cfg = try ws.config();

        try ws.link(cfg, .{});
        const fsm_zon = try ws.stat("out/deps/labelle-fsm/build.zig.zon");
        const fsm_zon_bytes = try ws.read("out/deps/labelle-fsm/build.zig.zon");
        try ws.link(cfg, .{ .prune = false });
        try expectSameFile(fsm_zon, try ws.stat("out/deps/labelle-fsm/build.zig.zon"));
        try std.testing.expectEqualStrings(fsm_zon_bytes, try ws.read("out/deps/labelle-fsm/build.zig.zon"));
    }

    test "existing deps/ content survives: tool-created dirs, `keep` entries; only stale top-level deps go" {
        var ws = try Workspace.init();
        defer ws.deinit();
        const cfg = try ws.config();
        try ws.link(cfg, .{});

        // What other actors leave in deps/ between two generates.
        try writeFileIn(ws.tmp.dir, "out/deps/labelle-core/zig-pkg/fetched/x.zig", "// fetched by a zig build run in the stage\n");
        try writeFileIn(ws.tmp.dir, "out/deps/labelle-tests-only/build.zig", "// staged by the tests-target pass\n");
        try writeFileIn(ws.tmp.dir, "out/deps/labelle-dropped/build.zig", "// a plugin removed from project.labelle\n");
        const fetched = try ws.stat("out/deps/labelle-core/zig-pkg/fetched/x.zig");
        const kept = try ws.stat("out/deps/labelle-tests-only/build.zig");

        try ws.link(cfg, .{ .keep = &.{"labelle-tests-only"} });
        try expectSameFile(fetched, try ws.stat("out/deps/labelle-core/zig-pkg/fetched/x.zig"));
        try expectSameFile(kept, try ws.stat("out/deps/labelle-tests-only/build.zig"));
        try std.testing.expect(!ws.exists("out/deps/labelle-dropped"));

        // The tests-target pass never sweeps.
        try writeFileIn(ws.tmp.dir, "out/deps/labelle-dropped/build.zig", "// again\n");
        try ws.link(cfg, .{ .prune = false });
        try std.testing.expect(ws.exists("out/deps/labelle-dropped/build.zig"));
    }

    test "a changed source file reaches the stage; its unchanged siblings keep their identity" {
        var ws = try Workspace.init();
        defer ws.deinit();
        const cfg = try ws.config();
        try ws.link(cfg, .{});
        const sibling = try ws.stat("out/deps/labelle-core/build.zig");

        // Replace (new inode) the way `git checkout` does.
        try ws.tmp.dir.deleteFile(io, "core/src/root.zig");
        try writeFileIn(ws.tmp.dir, "core/src/root.zig", "pub const x = 2;\n");
        try ws.link(cfg, .{});

        try std.testing.expectEqualStrings("pub const x = 2;\n", try ws.read("out/deps/labelle-core/src/root.zig"));
        try expectSameFile(sibling, try ws.stat("out/deps/labelle-core/build.zig"));
    }
};

/// Every regular file under `root` (relative path → stat), for tree diffs.
fn snapshot(allocator: std.mem.Allocator, dir: std.Io.Dir) !std.StringArrayHashMapUnmanaged(std.Io.File.Stat) {
    var map: std.StringArrayHashMapUnmanaged(std.Io.File.Stat) = .empty;
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const st = try dir.statFile(io, entry.path, .{});
        try map.put(allocator, try allocator.dupe(u8, entry.path), st);
    }
    return map;
}

pub const GENERATE_TWICE = struct {
    test "two REAL generates with unchanged inputs leave every generated + staged file untouched" {
        var ws = try Workspace.init();
        defer ws.deinit();
        const a = ws.arena.allocator();
        var cfg = try ws.config();
        // The in-tree null v2 backend fixture drives a full generate offline
        // (repo root = the tests' cwd).
        const fixture = try std.Io.Dir.cwd().realPathFileAlloc(io, "backends/null_v2", a);
        cfg.backend_package = .{ .name = "null_v2", .repo = try std.fmt.allocPrint(a, "local:{s}", .{fixture}) };

        const out = try ws.abs("out");
        const game = try ws.abs("game");
        try generate.generate(std.testing.allocator, cfg, out, game, .{ .is_tests_target = true });

        var out_dir = try ws.tmp.dir.openDir(io, "out", .{ .iterate = true });
        defer out_dir.close(io);
        const first = try snapshot(a, out_dir);
        // Guard against a vacuous pass: the tree has the generated sources
        // AND the staged deps.
        try std.testing.expect(first.contains(try std.fs.path.join(a, &.{ "null_v2_desktop", "build.zig" })));
        try std.testing.expect(first.contains(try std.fs.path.join(a, &.{ "null_v2_desktop", "build.zig.zon" })));
        try std.testing.expect(first.contains(try std.fs.path.join(a, &.{ "deps", "labelle-core", "src", "root.zig" })));

        try generate.generate(std.testing.allocator, cfg, out, game, .{ .is_tests_target = true });
        const second = try snapshot(a, out_dir);

        try std.testing.expectEqual(first.count(), second.count());
        var it = first.iterator();
        while (it.next()) |kv| {
            const after = second.get(kv.key_ptr.*) orelse {
                std.debug.print("#674: {s} disappeared on the second generate\n", .{kv.key_ptr.*});
                return error.TestUnexpectedResult;
            };
            if (kv.value_ptr.inode != after.inode or kv.value_ptr.mtime.nanoseconds != after.mtime.nanoseconds) {
                std.debug.print("#674: {s} was rewritten by an unchanged generate\n", .{kv.key_ptr.*});
                return error.TestUnexpectedResult;
            }
        }
    }
};

pub const MIN_ZIG_VERSION = struct {
    test "the generated zon's minimum_zig_version is the assembler's own (no hardcoded 0.15.2)" {
        var ws = try Workspace.init();
        defer ws.deinit();
        const cfg = try ws.config();
        const zon = try generate.generateBuildZigZon(std.testing.allocator, cfg, null, null, null, .{});
        defer std.testing.allocator.free(zon);
        const needle = try std.fmt.allocPrint(ws.arena.allocator(), ".minimum_zig_version = \"{s}\",", .{generate.MINIMUM_ZIG_VERSION});
        try std.testing.expect(std.mem.indexOf(u8, zon, needle) != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "0.15.2") == null);
        // Read from the assembler's own build.zig.zon — never older than the
        // Zig this suite is running on.
        const floor = try std.SemanticVersion.parse(generate.MINIMUM_ZIG_VERSION);
        try std.testing.expect(@import("builtin").zig_version.order(floor) != .lt);
    }
};

pub const FINGERPRINT = struct {
    test "the emitted fingerprint satisfies Zig's manifest rule, so no post-generate patch is needed" {
        // Mirrors the pinned compiler's `Package.Manifest` check (it lives in
        // the compiler, not std, so it cannot be called from here):
        //   (fingerprint >> 32) == Crc32(<.name>)  and the id half is neither
        //   0 ("unhashed") nor 0xffffffff ("opted out").
        // With this invariant the CLI's `zig build --list-steps` probe for
        // "use this value:" (labelle-cli `fixFingerprint`) never has
        // anything to patch.
        var ws = try Workspace.init();
        defer ws.deinit();
        for ([_][]const u8{ "stable-game", "a", "another project" }) |name| {
            var cfg = try ws.config();
            cfg.name = name;
            const zon = try generate.generateBuildZigZon(std.testing.allocator, cfg, null, null, null, .{});
            defer std.testing.allocator.free(zon);

            const name_key = ".name = .";
            const ns = (std.mem.indexOf(u8, zon, name_key) orelse return error.TestUnexpectedResult) + name_key.len;
            const ne = std.mem.indexOfScalarPos(u8, zon, ns, ',') orelse return error.TestUnexpectedResult;
            const pkg_name = zon[ns..ne];

            const fp_key = ".fingerprint = 0x";
            const fs = (std.mem.indexOf(u8, zon, fp_key) orelse return error.TestUnexpectedResult) + fp_key.len;
            const fe = std.mem.indexOfScalarPos(u8, zon, fs, ',') orelse return error.TestUnexpectedResult;
            const fp = try std.fmt.parseInt(u64, zon[fs..fe], 16);

            try std.testing.expectEqual(std.hash.Crc32.hash(pkg_name), @as(u32, @truncate(fp >> 32)));
            const id: u32 = @truncate(fp);
            try std.testing.expect(id != 0 and id != 0xffffffff);
        }
    }
};
