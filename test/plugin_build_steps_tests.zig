//! Plugin build-integration hooks (labelle-assembler#586) — staged-project
//! e2e over the REAL `generate`, extending the #585/#584 staging shape.
//!
//! The unit halves (strict `.build` parse, path/placeholder/link/platform
//! validation) live inline in `src/plugin_build_steps.zig`; the emission
//! goldens (argv/b.fmt/chaining bytes) inline in
//! `src/build_files/build_zig.zig`. These tests close what only the
//! production entry points can prove:
//!
//!   1. THE ACCEPTANCE: a plugin declaring a build step that runs a REAL
//!      command (`zig build-lib` — always present via the build-options
//!      `zig_exe`, never PATH — standing in for the POC's `cargo build`)
//!      gets its wiring emitted by `labelle generate`, and that EMITTED
//!      wiring, spliced verbatim into a minimal runnable build.zig,
//!      executes the command, produces the staticlib, links it, and the
//!      resulting binary reaches the symbol (`zig build` + run, exit 0).
//!      Splicing the marker lines (every functional emitted line carries
//!      `plugin_<name>_build`) proves the EMITTED BYTES work — not a
//!      hand-mirrored copy of the pattern — without needing the full
//!      engine/gfx/core dep graph a generated game's `zig build` pulls
//!      (network — the exact dependency this suite must not have).
//!   2. The additive no-op invariant: a plugin WITHOUT `.build` emits no
//!      marker, no `addSystemCommand`, no `plugin-build/` dir (negative
//!      control for every pin in 1).
//!   3. The platform gate: a step allowlisting only `android` fails a
//!      desktop generate with `error.PluginBuildUnsupportedPlatform`.
//!   4. The tests target stays byte-pure: `is_tests_target` skips
//!      discovery entirely (no exe to hang an artifact on).

const std = @import("std");
const zspec = @import("zspec");
const generate = @import("generator");
const h = @import("helpers.zig");
const test_options = @import("test_options");

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

/// A staged tmp game project (the #585 staging shape) with a
/// `plugins/buildsteps/` local plugin carrying a native source, plus the
/// engine template fixture the EXE target's main.zig emission needs.
const StagedProject = struct {
    tmp: std.testing.TmpDir,
    game_abs: [:0]const u8,
    out_abs: [:0]const u8,

    fn init(allocator: std.mem.Allocator, manifest: []const u8) !StagedProject {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "game/plugins/buildsteps/native");
        try tmp.dir.createDirPath(io, "out");
        var game = try tmp.dir.openDir(io, "game", .{});
        defer game.close(io);

        try writeFileIn(game, "plugins/buildsteps/plugin.labelle", manifest);
        // The native source the declared step compiles: one export the e2e
        // binary extern-calls. Deliberately trivial — the SEAM is under
        // test, not the toolchain.
        try writeFileIn(game, "plugins/buildsteps/native/adder.zig",
            \\export fn labelle_e2e_add(a: i32, b: i32) i32 {
            \\    return a + b;
            \\}
        );
        // The exe target emits main.zig from the engine template — stage
        // the unit-test fixture template as a `local:` engine package
        // (same trick as the #585 sidecar test).
        try writeFileIn(game, "engine-fixture/codegen/main.zig.template", h.engine_template);

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

    fn config(self: *StagedProject, backend_repo: []const u8) generate.ProjectConfig {
        _ = self;
        return .{
            .name = "buildsteps-game",
            .backend = .sokol,
            .backend_package = .{ .name = "sokol", .repo = backend_repo },
            .ecs = .mock,
            // The exe target emits main.zig, which requires the project's
            // declared y-axis convention (RFC-Y-AXIS-CONVENTION build guard).
            .y_axis = .up,
            .engine_version = "local:engine-fixture",
            .plugins = &.{
                .{ .name = "buildsteps", .repo = "local:plugins/buildsteps" },
            },
        };
    }
};

/// The acceptance manifest: a real command (`zig build-lib`, absolute path
/// spliced from build options) producing a staticlib into `{cache}`,
/// consumed as `.static_lib`. Exercises `{package}` (generate-time
/// substitution), a mixed `-femit-bin={cache}/…` arg (build-time b.fmt),
/// bare `{cache}` args, and a declared cwd.
fn acceptanceManifest(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = "buildsteps",
        \\    .manifest_version = 1,
        \\    .build = .{{
        \\        .steps = .{{
        \\            .{{ .name = "adder-lib",
        \\               .command = .{{ "{s}", "build-lib", "{{package}}/native/adder.zig", "-femit-bin={{cache}}/libadder.a", "--cache-dir", "{{cache}}/zig-cache", "--global-cache-dir", "{{cache}}/zig-global", "-OReleaseSmall" }},
        \\               .cwd = "native",
        \\               .artifact = "{{cache}}/libadder.a",
        \\               .link = .static_lib }},
        \\        }},
        \\    }},
        \\}}
    , .{test_options.zig_exe});
}

const no_build_manifest =
    \\.{ .name = "buildsteps", .manifest_version = 1 }
;

pub const BUILD_STEPS_E2E = struct {
    test "acceptance: generate emits the wiring, and the emitted bytes run the command, link the staticlib, reach the symbol" {
        const allocator = std.testing.allocator;

        const manifest = try acceptanceManifest(allocator);
        defer allocator.free(manifest);
        var staged = try StagedProject.init(allocator, manifest);
        defer staged.deinit(allocator);

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        const build_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1024 * 1024));
        defer allocator.free(build_zig);

        // ── Wiring pins against the REAL generated build.zig ──
        // The {cache} const, resolved at build time against the build root.
        _ = try indexOfOrFail(build_zig, "const plugin_buildsteps_build_cache = b.pathFromRoot(\"plugin-build/buildsteps\");");
        // The system command carries the declared program (never a shell).
        const cmd_pin = try std.fmt.allocPrint(allocator, "const plugin_buildsteps_build_step_0 = b.addSystemCommand(&.{{ \"{s}\", \"build-lib\", ", .{test_options.zig_exe});
        defer allocator.free(cmd_pin);
        _ = try indexOfOrFail(build_zig, cmd_pin);
        // {package} substituted at generate time to the STAGED deps copy…
        const pkg_arg_pin = try std.fmt.allocPrint(allocator, "\"{s}/deps/labelle-buildsteps/native/adder.zig\"", .{staged.out_abs});
        defer allocator.free(pkg_arg_pin);
        _ = try indexOfOrFail(build_zig, pkg_arg_pin);
        // …a mixed {cache} arg becomes a build-time b.fmt…
        _ = try indexOfOrFail(build_zig, "b.fmt(\"-femit-bin={s}/libadder.a\", .{ plugin_buildsteps_build_cache })");
        // …cwd lands inside the staged package…
        const cwd_pin = try std.fmt.allocPrint(allocator, "plugin_buildsteps_build_step_0.setCwd(.{{ .cwd_relative = \"{s}/deps/labelle-buildsteps/native\" }});", .{staged.out_abs});
        defer allocator.free(cwd_pin);
        _ = try indexOfOrFail(build_zig, cwd_pin);
        // …and the artifact links onto the exe, ordered after the command.
        _ = try indexOfOrFail(build_zig, "const plugin_buildsteps_build_artifact_0 = b.path(\"plugin-build/buildsteps/libadder.a\");");
        _ = try indexOfOrFail(build_zig, "exe.root_module.addObjectFile(plugin_buildsteps_build_artifact_0);");
        _ = try indexOfOrFail(build_zig, "exe.step.dependOn(&plugin_buildsteps_build_step_0.step);");

        // The {cache} dir was created at generate (a command's first write
        // must not hit a missing parent).
        try staged.tmp.dir.access(io, "out/sokol_desktop/plugin-build/buildsteps", .{});

        // ── The runnable proof: splice the EMITTED lines into a minimal
        // build.zig and drive a real `zig build` + run. Every functional
        // emitted line carries the `plugin_buildsteps_build` marker; the
        // spliced block references only `b` and `exe`. b.path/b.pathFromRoot
        // resolve against the SPLICE project's own root — its
        // `plugin-build/buildsteps/` work dir — while the absolute
        // {package}/cwd paths keep pointing at the staged deps copy, exactly
        // as they would in the generated project.
        var spliced: std.ArrayList(u8) = .empty;
        defer spliced.deinit(allocator);
        var lines = std.mem.splitScalar(u8, build_zig, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "plugin_buildsteps_build") == null) continue;
            try spliced.appendSlice(allocator, line);
            try spliced.append(allocator, '\n');
        }
        try std.testing.expect(spliced.items.len > 0);

        try staged.tmp.dir.createDirPath(io, "e2e/plugin-build/buildsteps");
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
        , .{spliced.items});
        defer allocator.free(e2e_build);
        try writeFileIn(e2e_dir, "build.zig", e2e_build);
        // No build.zig.zon: a dep-less project doesn't need one, and a
        // synthetic manifest would need a VALID fingerprint (zig checks the
        // name-hash half — an arbitrary constant fails the build).
        try writeFileIn(e2e_dir, "main.zig",
            \\extern fn labelle_e2e_add(a: i32, b: i32) i32;
            \\pub fn main() !void {
            \\    if (labelle_e2e_add(20, 22) != 42) return error.WrongSum;
            \\}
        );

        const e2e_abs = try staged.tmp.dir.realPathFileAlloc(io, "e2e", allocator);
        defer allocator.free(e2e_abs);

        // `zig build`: the spliced block must run the declared command
        // (producing plugin-build/buildsteps/libadder.a) BEFORE linking it.
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
        // The staticlib landed where the artifact wiring expects it.
        try e2e_dir.access(io, "plugin-build/buildsteps/libadder.a", .{});

        // And the linked binary reaches the symbol (exit 0 ⇔ 20+22==42).
        {
            const exe_path = try std.fs.path.join(allocator, &.{ e2e_abs, "zig-out", "bin", "e2e" });
            defer allocator.free(exe_path);
            const result = try std.process.run(allocator, io, .{
                .argv = &.{exe_path},
                .cwd = .{ .path = e2e_abs },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            const ok = result.term == .exited and result.term.exited == 0;
            if (!ok) {
                std.debug.print("e2e binary failed:\n{s}\n", .{result.stderr});
                return error.SymbolNotReachable;
            }
        }
    }

    test "no .build block → no wiring, no plugin-build dir (additive byte-identity, negative control)" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator, no_build_manifest);
        defer staged.deinit(allocator);

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        const build_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1024 * 1024));
        defer allocator.free(build_zig);
        // Negative pins matching every acceptance pin's vocabulary.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "plugin_buildsteps_build") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "addSystemCommand") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "plugin-build") == null);
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop/plugin-build", .{}),
        );
    }

    test "a step allowlisting only android fails a desktop generate with a pointed error" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator,
            \\.{
            \\    .name = "buildsteps",
            \\    .manifest_version = 1,
            \\    .build = .{
            \\        .steps = .{
            \\            .{ .name = "ndk-only",
            \\               .command = .{ "true" },
            \\               .platforms = .{ "android" } },
            \\        },
            \\    },
            \\}
        );
        defer staged.deinit(allocator);

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try std.testing.expectError(
            error.PluginBuildUnsupportedPlatform,
            generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false }),
        );
    }

    test "a declared cwd missing from the staged package fails generate (pointed, not a mid-build spawn error)" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator,
            \\.{
            \\    .name = "buildsteps",
            \\    .manifest_version = 1,
            \\    .build = .{
            \\        .steps = .{
            \\            .{ .name = "mk",
            \\               .command = .{ "true" },
            \\               .cwd = "does-not-exist" },
            \\        },
            \\    },
            \\}
        );
        defer staged.deinit(allocator);

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try std.testing.expectError(
            error.PluginBuildMissingCwd,
            generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false }),
        );
    }

    test "the tests target skips build steps entirely (no exe to link into, byte-pure)" {
        const allocator = std.testing.allocator;
        const manifest = try acceptanceManifest(allocator);
        defer allocator.free(manifest);
        var staged = try StagedProject.init(allocator, manifest);
        defer staged.deinit(allocator);

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = true });

        const build_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1024 * 1024));
        defer allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "plugin_buildsteps_build") == null);
        // Discovery is gated too: no {cache} dir side effect.
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop/plugin-build", .{}),
        );
    }
};
