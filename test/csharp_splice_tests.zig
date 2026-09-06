//! C# scripting splice — the EMBED path (labelle-assembler#617, follow-up
//! to labelle-engine#743 / labelle-scripting#26) — staged-project e2e over
//! the REAL `generate`, mirroring the rust/crystal suites
//! (`test/native_splice_tests.zig`, `test/crystal_splice_tests.zig`).
//!
//! The fixture MIRRORS the shipped csharp manifest shapes with zero dotnet
//! dependency (the #586 trick): the `.languages` csharp row (`.kind =
//! .native`, `module_root = "Game.cs"`, `stage_subdir =
//! "native-csharp/src/game"` — the manifest-PRIMARY detect path; csharp has
//! NO frozen-table fallback row) plus a `.language_builds` csharp entry
//! whose single LINK-LESS step is a `zig run` stand-in for `dotnet publish
//! -o {cache}`: it writes `labelle_csharp_scripts.dll` (+ runtimeconfig/
//! deps.json twins) into `{cache}`, exactly the publish-output contract the
//! real step has. The REAL dotnet path is labelle-scripting's
//! csharp-example CI (and this repo's csharp job).
//!
//! What only the production entry points can prove:
//!
//!   1. THE #617 ACCEPTANCE: a csharp project generates end to end — the
//!      family-shared touchpoints with NONE of the embed ones;
//!      `.language = .csharp` on the plugin dep; `scripts/` live-linked
//!      over the staged `native-csharp/src/game` placeholder; the
//!      link-less publish step emitted with NO addObjectFile; AND the two
//!      runtime-output seams this ticket adds:
//!        * the InstallDir wiring staging `{cache}` beside the exe
//!          (`plugin_scripting_runtime_outputs`), reached from the default
//!          install step;
//!        * the run step's `LABELLE_CS_ASSEMBLY_DIR` env pointing at the
//!          publish dir (`zig build run` executes the CACHED binary).
//!      Then the #586-style splice-run: the emitted wiring RUNS — the
//!      stand-in publishes into `plugin-build/scripting/` and `zig build`
//!      lands the assembly files in `zig-out/bin/` beside the binary, no
//!      manual step, no env var.
//!   2. The toolchain probe (#617's doctor half): a csharp entry whose
//!      argv[0] is a bare missing tool fails generate pointedly
//!      (`error.PluginBuildToolMissing`) BEFORE any build — driven through
//!      the `path_override` seam so the suite never depends on the host's
//!      PATH contents.
//!   3. The rust/crystal invariant: a linked-artifact language never gets
//!      the runtime-output staging (covered by the crystal suite's golden
//!      + the emission unit tests; pinned here at the generate level by
//!      the probe fixture reusing the same project shape).

const std = @import("std");
const builtin = @import("builtin");
const zspec = @import("zspec");
const generate = @import("generator");
const h = @import("helpers.zig");
const test_options = @import("test_options");

const io = std.testing.io;

/// The host executable extension: `.exe` on Windows, empty elsewhere. The
/// spliced e2e projects install their binary as `zig-out/bin/e2e<ext>`, and
/// a hardcoded POSIX `e2e` simply is not there on Windows (#699). Spelled as
/// a comptime const rather than `builtin.target.exeFileExt()` inline, which
/// does not const-fold inside a `++`.
const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

test {
    zspec.runAll(@This());
}

fn writeFileIn(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(io, sub);
    var f = try dir.createFile(io, rel, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

fn indexOfOrFail(haystack: []const u8, needle: []const u8) !usize {
    return std.mem.indexOf(u8, haystack, needle) orelse {
        std.debug.print("expected to find:\n  {s}\nin generated output\n", .{needle});
        return error.MissingExpectedEmission;
    };
}

/// The in-tree sokol backend fixture as an ABSOLUTE `local:` repo (staged
/// games live in tmp dirs, so the repo-relative spelling can't resolve).
fn sokolFixtureRepoAbs(allocator: std.mem.Allocator) ![]const u8 {
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, "backends/sokol", allocator);
    defer allocator.free(abs);
    return std.fmt.allocPrint(allocator, "local:{s}", .{abs});
}

/// The csharp manifest entry, `zig`-flavored for a runnable suite: the
/// `.languages` row is the SHIPPED spelling verbatim (manifest-PRIMARY
/// detect — csharp has no frozen fallback), and the `.language_builds`
/// step is a `zig run` publish stand-in with the real step's shape: ONE
/// link-less command whose `-o`-equivalent lands the runtime payload in
/// `{cache}`. `tool` parameterizes argv[0] so the probe tests can declare
/// a bare missing tool ("{s}" = the suite zig exe — absolute, probe-skipped).
fn csharpManifest(allocator: std.mem.Allocator, tool: []const u8) ![]const u8 {
    // `tool` is an ABSOLUTE path (the suite zig exe by default), and on
    // Windows that means backslashes: the `\U` in `C:\Users\...` is not a
    // valid Zig escape, so the manifest written below would not parse
    // (#708). Invisible on Linux and macOS, where there are no backslashes
    // to trip over.
    const tool_z = try generate.escapeZonString(allocator, tool);
    defer allocator.free(tool_z);
    return std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = "scripting",
        \\    .manifest_version = 1,
        \\    .params_schema = .{{
        \\        .{{ .name = "language", .type = .@"enum", .values = .{{ "lua", "ruby", "typescript", "rust", "crystal", "csharp" }}, .required = true }},
        \\    }},
        \\    .languages = .{{
        \\        .{{ .name = "csharp", .extensions = .{{".cs"}}, .kind = .native,
        \\           .module_root = "Game.cs",
        \\           .stage_subdir = "native-csharp/src/game" }},
        \\    }},
        \\    .language_builds = .{{
        \\        .{{
        \\            .language = "csharp",
        \\            .steps = .{{
        \\                .{{ .name = "dotnet-publish-scripts",
        \\                   .command = .{{ "{s}", "run", "--cache-dir", "{{cache}}/zig-cache", "--global-cache-dir", "{{cache}}/zig-global", "{{package}}/native-csharp/fake_publish.zig", "--", "{{cache}}" }},
        \\                   .platforms = .{{"desktop"}} }},
        \\            }},
        \\        }},
        \\    }},
        \\}}
    , .{tool_z});
}

/// The publish stand-in the fixture's step `zig run`s: writes the three
/// publish-output twins (`.dll` + runtimeconfig/deps json) into argv[1] —
/// the `{cache}` dir — exactly what `dotnet publish -o {cache}` leaves
/// behind for the InstallDir wiring to stage.
const fake_publish_zig =
    \\const std = @import("std");
    \\pub fn main(init: std.process.Init) !void {
    \\    const gpa = init.gpa;
    \\    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    \\    defer args.deinit();
    \\    _ = args.skip();
    \\    const out_dir_path = args.next() orelse return error.MissingOutDir;
    \\    const cwd = std.Io.Dir.cwd();
    \\    try cwd.createDirPath(init.io, out_dir_path);
    \\    var dir = try cwd.openDir(init.io, out_dir_path, .{});
    \\    defer dir.close(init.io);
    \\    const names = [_][]const u8{
    \\        "labelle_csharp_scripts.dll",
    \\        "labelle_csharp_scripts.runtimeconfig.json",
    \\        "labelle_csharp_scripts.deps.json",
    \\    };
    \\    for (names) |name| {
    \\        var f = try dir.createFile(init.io, name, .{});
    \\        defer f.close(init.io);
    \\        try f.writeStreamingAll(init.io, "fake-publish-output\n");
    \\    }
    \\}
;

const placeholder_game_cs =
    \\// REPLACED AT GENERATE: the assembler stages the game's scripts/ here.
    \\public static class Game
    \\{
    \\    public static void Register(Scripts scripts) { }
    \\}
;

const StagedCsharpProject = struct {
    tmp: std.testing.TmpDir,
    game_abs: [:0]const u8,
    out_abs: [:0]const u8,

    fn init(allocator: std.mem.Allocator, opts: struct {
        /// argv[0] of the publish step; null = the suite zig exe
        /// (absolute — the PATH probe skips it, the step actually runs).
        tool: ?[]const u8 = null,
    }) !StagedCsharpProject {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "out");
        try tmp.dir.createDirPath(io, "game");
        var game_root = try tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);

        const m = try csharpManifest(allocator, opts.tool orelse test_options.zig_exe);
        defer allocator.free(m);
        try writeFileIn(game_root, "plugins/scripting/plugin.labelle", m);

        // The plugin's native-csharp crate: the publish stand-in beside the
        // game-module placeholder the game's scripts/ replace.
        try writeFileIn(game_root, "plugins/scripting/native-csharp/fake_publish.zig", fake_publish_zig);
        try writeFileIn(game_root, "plugins/scripting/native-csharp/src/game/Game.cs", placeholder_game_cs);
        // The dev-`.csproj` surface files the emitter references (#617's
        // IDE half — emitted paths, no read, but keep the package honest).
        try writeFileIn(game_root, "plugins/scripting/native-csharp/src/Labelle.cs", "// fixture Labelle surface\n");

        // The #237 convention: scripts/Game.cs is the CoreCLR game-module
        // root; a sibling script rides along.
        try writeFileIn(game_root, "scripts/Game.cs",
            \\public static class Game
            \\{
            \\    public static void Register(Scripts scripts) { Spawner.Register(scripts); }
            \\}
            \\
        );
        try writeFileIn(game_root, "scripts/Spawner.cs", "public static class Spawner { public static void Register(Scripts s) { } }\n");

        try writeFileIn(game_root, "engine-fixture/codegen/main.zig.template", h.engine_template);
        const game_abs = try tmp.dir.realPathFileAlloc(io, "game", allocator);
        errdefer allocator.free(game_abs);
        const out_abs = try tmp.dir.realPathFileAlloc(io, "out", allocator);
        return .{ .tmp = tmp, .game_abs = game_abs, .out_abs = out_abs };
    }

    fn deinit(self: *StagedCsharpProject, allocator: std.mem.Allocator) void {
        allocator.free(self.game_abs);
        allocator.free(self.out_abs);
        self.tmp.cleanup();
    }

    fn config(self: *StagedCsharpProject, backend_repo: []const u8) generate.ProjectConfig {
        _ = self;
        return .{
            .name = "csharp-game",
            .backend = .sokol,
            .backend_package = .{ .name = "sokol", .repo = backend_repo },
            .ecs = .mock,
            .engine_version = "local:engine-fixture",
            .y_axis = .up,
            .plugins = &.{
                .{
                    .name = "scripting",
                    .repo = "local:plugins/scripting",
                    .params = .{ .language = "csharp" },
                },
            },
        };
    }
};

pub const CSHARP_SPLICE_E2E = struct {
    test "acceptance (#617): csharp generate — native family, link-less publish step, runtime outputs installed beside the exe + run-step env, runnable splice" {
        const allocator = std.testing.allocator;
        var staged = try StagedCsharpProject.init(allocator, .{});
        defer staged.deinit(allocator);

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        // ── Generated main: family-shared in, embed out ──
        const main_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        _ = try indexOfOrFail(main_zig, "const scripting = @import(\"scripting\");");
        _ = try indexOfOrFail(main_zig, "const scripting_enabled = true;");
        _ = try indexOfOrFail(main_zig, "scripting.Controller.tick(&g, scaled_dt);");
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"scripts/") == null);

        // ── Generated build.zig ──
        const build_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1 << 20));
        defer allocator.free(build_zig);
        _ = try indexOfOrFail(build_zig, ".language = .csharp });");
        // Link-less publish: no artifact const, no addObjectFile — the exe
        // just depends on the step.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "plugin_scripting_build_artifact_0") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "addObjectFile(plugin_scripting_build_artifact") == null);
        _ = try indexOfOrFail(build_zig, "exe.step.dependOn(&plugin_scripting_build_step_0.step);");
        // THE #617 seams: the InstallDir staging {cache} beside the exe,
        // reached from the default install step…
        _ = try indexOfOrFail(build_zig, "const plugin_scripting_runtime_outputs = b.addInstallDirectory(.{");
        _ = try indexOfOrFail(build_zig, ".source_dir = .{ .cwd_relative = plugin_scripting_build_cache },");
        _ = try indexOfOrFail(build_zig, ".install_dir = .bin,");
        _ = try indexOfOrFail(build_zig, "plugin_scripting_runtime_outputs.step.dependOn(&plugin_scripting_build_step_0.step);");
        _ = try indexOfOrFail(build_zig, "b.getInstallStep().dependOn(&plugin_scripting_runtime_outputs.step);");
        // …and the run step's documented override pointing at the publish
        // dir, AFTER run_cmd exists and BEFORE the run step wires it.
        const env_at = try indexOfOrFail(build_zig, "run_cmd.setEnvironmentVariable(\"LABELLE_CS_ASSEMBLY_DIR\", plugin_scripting_build_cache);");
        const run_cmd_at = try indexOfOrFail(build_zig, "const run_cmd = b.addRunArtifact(exe);");
        const run_step_at = try indexOfOrFail(build_zig, "const run_step = b.step(\"run\", \"Run the game\");");
        try std.testing.expect(run_cmd_at < env_at and env_at < run_step_at);

        // ── Game-source staging: scripts/ live-linked over the placeholder ──
        const staged_game_cs = try staged.tmp.dir.readFileAlloc(io, "out/deps/labelle-scripting/native-csharp/src/game/Game.cs", allocator, .limited(4096));
        defer allocator.free(staged_game_cs);
        try std.testing.expect(std.mem.indexOf(u8, staged_game_cs, "REPLACED AT GENERATE") == null);
        _ = try indexOfOrFail(staged_game_cs, "Spawner.Register(scripts);");
        try staged.tmp.dir.access(io, "out/deps/labelle-scripting/native-csharp/src/game/Spawner.cs", .{});

        // ── The dev .csproj (the #617 IDE half) rides along ──
        try staged.tmp.dir.access(io, "game/csharp-game.csproj", .{});

        // ── The runnable proof: the emitted wiring RUNS — the stand-in
        // publishes into plugin-build/scripting/ and `zig build` stages the
        // assembly beside the binary. Extract the contiguous plugin block
        // (cache const → getInstallStep dependOn) — the install block is
        // multi-line, so a line filter would shear it.
        const begin = try indexOfOrFail(build_zig, "    const plugin_scripting_build_cache = b.pathFromRoot(");
        const end_needle = "    b.getInstallStep().dependOn(&plugin_scripting_runtime_outputs.step);\n";
        const end = (try indexOfOrFail(build_zig, end_needle)) + end_needle.len;
        const spliced = build_zig[begin..end];

        try staged.tmp.dir.createDirPath(io, "e2e/plugin-build/scripting");
        var e2e_dir = try staged.tmp.dir.openDir(io, "e2e", .{});
        defer e2e_dir.close(io);
        const e2e_build = try std.fmt.allocPrint(allocator,
            \\const std = @import("std");
            \\pub fn build(b: *std.Build) void {{
            \\    const target = b.standardTargetOptions(.{{}});
            \\    const optimize = b.standardOptimizeOption(.{{}});
            \\    const exe = b.addExecutable(.{{
            \\        .name = "e2e",
            \\        .root_module = b.createModule(.{{
            \\            .root_source_file = b.path("main.zig"),
            \\            .target = target,
            \\            .optimize = optimize,
            \\        }}),
            \\    }});
            \\{s}    b.installArtifact(exe);
            \\}}
        , .{spliced});
        defer allocator.free(e2e_build);
        try writeFileIn(e2e_dir, "build.zig", e2e_build);
        try writeFileIn(e2e_dir, "main.zig",
            \\pub fn main() !void {}
        );

        const e2e_abs = try staged.tmp.dir.realPathFileAlloc(io, "e2e", allocator);
        defer allocator.free(e2e_abs);
        {
            const result = try std.process.run(allocator, io, .{
                .argv = &.{ test_options.zig_exe, "build" },
                .cwd = .{ .path = e2e_abs },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            const ok = result.term == .exited and result.term.exited == 0;
            if (!ok) {
                std.debug.print("spliced `zig build` failed:\n{s}\n", .{result.stderr});
                return error.SplicedBuildFailed;
            }
        }
        // The publish stand-in ran into {cache}…
        try e2e_dir.access(io, "plugin-build/scripting/labelle_csharp_scripts.dll", .{});
        // …and the InstallDir staged the runtime payload BESIDE the binary —
        // the #617 acceptance: `zig build` alone, no manual dotnet step, no
        // env var, assembly next to the exe where hostfxr resolves it.
        try e2e_dir.access(io, "zig-out/bin/labelle_csharp_scripts.dll", .{});
        try e2e_dir.access(io, "zig-out/bin/labelle_csharp_scripts.runtimeconfig.json", .{});
        try e2e_dir.access(io, "zig-out/bin/labelle_csharp_scripts.deps.json", .{});
        // The installed exe carries the host's executable extension —
        // `e2e.exe` on Windows, bare `e2e` everywhere else. The three
        // runtime-payload assertions above already passed here, so the
        // build and the InstallDir staging both worked; only this
        // hardcoded POSIX name was wrong (#699).
        try e2e_dir.access(io, "zig-out/bin/e2e" ++ exe_suffix, .{});
    }

    test "toolchain probe (#617): a csharp generate without the publish tool on PATH fails pointedly at generate" {
        const allocator = std.testing.allocator;
        // A BARE argv[0] (PATH-resolved) that exists nowhere under the
        // override PATH — the probe must fail generate up front, never let
        // the user's `zig build` die on an opaque child-spawn error.
        var staged = try StagedCsharpProject.init(allocator, .{ .tool = "dotnet-missing-617" });
        defer staged.deinit(allocator);

        var empty_path_tmp = std.testing.tmpDir(.{});
        defer empty_path_tmp.cleanup();
        const empty_path = try empty_path_tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(empty_path);
        generate.scripting_csharp.path_override = empty_path;
        defer generate.scripting_csharp.path_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try std.testing.expectError(
            error.PluginBuildToolMissing,
            generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false }),
        );
    }
};
