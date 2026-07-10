//! One-language-per-project policy — e2e tests through the REAL `generate`
//! entry point (labelle-assembler#584, RFC-LANGUAGE-PLUGINS revs 8–9).
//!
//! The unit halves live inline in `src/language_policy.zig` (vocabulary /
//! singleton `.language` / `requires_language` matching / dir-scan
//! primitives) and `src/root/generate_phases.zig` (the
//! `validateLanguagePolicy` orchestrator over real manifests + pack
//! enumeration). These tests close the two gaps only the production entry
//! point can prove:
//!
//!   1. the gate is WIRED into `generate()` and fires BEFORE any target
//!      write (a violating project leaves no stale `.labelle/<target>/`);
//!   2. a clean project — no `.params.language`, no language dirs —
//!      generates byte-identical output (the no-behavior-change regression
//!      guard: the ticket is parse + validate ONLY).

const std = @import("std");
const zspec = @import("zspec");
const generate = @import("generator");
const h = @import("helpers.zig");

const io = std.testing.io;

test {
    zspec.runAll(@This());
}

fn writeFileIn(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(io, sub);
    var f = try dir.createFile(io, rel, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

/// The in-tree sokol backend fixture as an ABSOLUTE `local:` package. The
/// staged game projects below live in tmp dirs, so the repo-relative
/// `local:backends/sokol` spelling (resolved against game_dir, as
/// `h.sokol_fixture_package` assumes game_dir = ".") cannot work — anchor it
/// at the repo root (the tests' cwd) instead. Caller frees `repo`.
fn sokolFixtureAbs(allocator: std.mem.Allocator) !generate.PluginDep {
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, "backends/sokol", allocator);
    defer allocator.free(abs);
    const repo = try std.fmt.allocPrint(allocator, "local:{s}", .{abs});
    return .{ .name = "sokol", .repo = repo };
}

/// A staged tmp game project: `game/` (the project root, with a staged empty
/// `plugins/scripting/` dir so the scripting `.plugins` entry resolves
/// cleanly to "no plugin.labelle") and `out/` (the generate output dir).
const StagedProject = struct {
    tmp: std.testing.TmpDir,
    // `realPathFileAlloc` returns a SENTINEL-terminated slice; keep the
    // sentinel in the field type so `allocator.free` accounts for the extra
    // byte (a plain `[]const u8` field trips the DebugAllocator size check).
    game_abs: [:0]const u8,
    out_abs: [:0]const u8,

    fn init(allocator: std.mem.Allocator) !StagedProject {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "game/plugins/scripting");
        try tmp.dir.createDirPath(io, "out");
        const game_abs = try tmp.dir.realPathFileAlloc(io, "game", allocator);
        errdefer allocator.free(game_abs);
        const out_abs = try tmp.dir.realPathFileAlloc(io, "out", allocator);
        return .{ .tmp = tmp, .game_abs = game_abs, .out_abs = out_abs };
    }

    fn deinit(self: *StagedProject, allocator: std.mem.Allocator) void {
        allocator.free(self.game_abs);
        allocator.free(self.out_abs);
        self.tmp.cleanup();
    }

    fn game(self: *StagedProject) !std.Io.Dir {
        return self.tmp.dir.openDir(io, "game", .{});
    }
};

/// The scripting-plugin `.plugins` entry every staged project uses:
/// `.params = .{ .language = "lua" }` (the generic plugin-params bag, v1
/// slice), repo pointing at the staged empty local dir.
const scripting_lua = generate.PluginDep{
    .name = "labelle-scripting",
    .repo = "local:plugins/scripting",
    .params = .{ .language = "lua" },
};

pub const GENERATE_GATE = struct {
    test "a lua project with a rust/ file fails generate BEFORE any target write (#584)" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);

        var game = try staged.game();
        defer game.close(io);
        try writeFileIn(game, "rust/native/collision.rs", "pub fn solve() {}\n");

        const backend = try sokolFixtureAbs(allocator);
        defer allocator.free(backend.repo);
        const cfg = generate.ProjectConfig{
            .name = "lua-game",
            .backend = .sokol,
            .backend_package = backend,
            .ecs = .mock,
            .plugins = &.{scripting_lua},
        };
        try std.testing.expectError(
            error.ScriptLanguageMismatch,
            generate.generate(allocator, cfg, staged.out_abs, staged.game_abs, .{ .is_tests_target = true }),
        );
        // The gate runs beside the pack-graph gate, BEFORE the target dir is
        // created — a rejected build must leave no stale .labelle output.
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop", .{}),
        );
    }

    test "a pack requires_language mismatch fails generate naming the pack (#584)" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);

        var game = try staged.game();
        defer game.close(io);
        // A Ruby-scripted pack attached to a lua project (RFC rev 8's
        // "a Lua-scripted pack fails loudly in a Rust project", mirrored).
        try writeFileIn(game, "packs/dungeon/pack.labelle",
            \\.{
            \\    .name = "dungeon",
            \\    .manifest_version = 1,
            \\    .requires_language = "ruby",
            \\}
        );

        const backend = try sokolFixtureAbs(allocator);
        defer allocator.free(backend.repo);
        const cfg = generate.ProjectConfig{
            .name = "lua-game",
            .backend = .sokol,
            .backend_package = backend,
            .ecs = .mock,
            .plugins = &.{
                scripting_lua,
                .{ .name = "dungeon", .repo = "@packs/dungeon" },
            },
        };
        try std.testing.expectError(
            error.LanguageRequirementMismatch,
            generate.generate(allocator, cfg, staged.out_abs, staged.game_abs, .{ .is_tests_target = true }),
        );
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop", .{}),
        );
    }

    test "a pack requires_language MATCH generates to completion (#584)" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);

        var game = try staged.game();
        defer game.close(io);
        try writeFileIn(game, "packs/dungeon/pack.labelle",
            \\.{
            \\    .name = "dungeon",
            \\    .manifest_version = 1,
            \\    .requires_language = "lua",
            \\}
        );
        // A realistic light pack ships at least one convention dir (a pack
        // with ONLY a pack.labelle never materializes its target dir — a
        // pre-existing scanPack behavior unrelated to #584).
        try writeFileIn(game, "packs/dungeon/components/Room.zig", "pub const Room = struct { w: u8 = 1 };\n");
        // The pack's own lua/ scripts are the declared language — legal.
        try writeFileIn(game, "packs/dungeon/lua/room.lua", "return {}\n");

        const backend = try sokolFixtureAbs(allocator);
        defer allocator.free(backend.repo);
        const cfg = generate.ProjectConfig{
            .name = "lua-game",
            .backend = .sokol,
            .backend_package = backend,
            .ecs = .mock,
            .plugins = &.{
                scripting_lua,
                .{ .name = "dungeon", .repo = "@packs/dungeon" },
            },
        };
        try generate.generate(allocator, cfg, staged.out_abs, staged.game_abs, .{ .is_tests_target = true });
        // The target materialized normally.
        try staged.tmp.dir.access(io, "out/sokol_desktop/build.zig", .{});
    }
};

pub const CLEAN_PROJECT_BYTE_IDENTITY = struct {
    test "clean project (no .params.language, no language dirs): REAL generate output is byte-identical (#584)" {
        // The load-bearing no-behavior-change guard. `generateAndReadBuildZig`
        // drives the PRODUCTION `generate` (which now runs the #584 language
        // gate) over the repo root — a clean project: no `.plugins` entry
        // declares `.params.language`, no language convention dirs exist. The unit
        // helper calls `generateBuildZig` directly and NEVER runs the gate,
        // and its output is pinned to the committed pre-#584 golden by
        // MANIFEST_V2_DESKTOP_ANCHOR — so byte-equality here proves the gate
        // (and the new manifest/config fields) changed nothing in generation.
        const cfg = generate.ProjectConfig{ .name = "noop-game", .backend = .sokol, .ecs = .mock };
        const via_generate = try h.generateAndReadBuildZig(std.testing.allocator, cfg, h.sokol_fixture_package);
        defer std.testing.allocator.free(via_generate);
        const unit = try h.genSokolBuildZigV2(std.testing.allocator, cfg, .{ .is_tests_target = true });
        defer std.testing.allocator.free(unit);
        try std.testing.expectEqualStrings(unit, via_generate);
        // Belt-and-braces: no language wiring leaks into the emitted build.
        try std.testing.expect(std.mem.indexOf(u8, via_generate, "language") == null);
    }
};
