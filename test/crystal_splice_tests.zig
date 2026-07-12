//! Crystal scripting splice (labelle-engine#741 slice 2, labelle-scripting
//! PR #19 / v0.7.0) — staged-project e2e over the REAL `generate`,
//! mirroring the rust suite (`test/native_splice_tests.zig`).
//!
//! The fixture MIRRORS the crystal manifest entry's shapes with zero
//! crystal dependency (the #586 trick, `zig build-obj` + `zig objcopy`
//! standing in for `crystal build` + the per-OS localization): a
//! two-step chain whose FIRST step is artifact-less (chained order only)
//! and whose per-OS localization variants carry the object artifact, the
//! `{crystal_env:CRYSTAL_LIBRARY_PATH}` library paths (resolved through
//! the test override seam — no crystal on the suite host), and per-OS
//! system libs. The REAL crystal path is the scripting repo's CI once
//! the held manifest entry lands.
//!
//! What only the production entry points can prove:
//!
//!   1. THE ACCEPTANCE: a crystal project generates end to end — the
//!      family-shared touchpoints (alias + flag, Controller.tick, drain
//!      tap) with NONE of the embed ones; `.language = .crystal` on the
//!      plugin dep; the game's `crystal/` linked over the staged
//!      `native-crystal/src/game` placeholder; declare skipped; exactly
//!      ONE per-OS localization step emitted (the host's); artifact-less
//!      chaining; resolved library paths. Then the #586 splice-run: the
//!      EMITTED two-step chain runs (build-obj → objcopy), the object
//!      links, the binary reaches the symbol.
//!   2. Per-OS selection through the seam (`GenerateOptions
//!      .plugin_build_os`): a macos generate emits the ld-shaped step
//!      only, a linux one the objcopy-shaped step only.
//!   3. The windows pointed failures: all-steps-gated → NoStepsForOs;
//!      intermediate-ungated → NoArtifactForOs (codex, PR #19 — never an
//!      artifact-less chain).
//!   4. `{crystal_target}` reaches the generated build.zig as the shared
//!      build-time triple const + argv slot (text pin — the command
//!      never runs in this suite).
//!   5. THE FORWARD-COMPAT PIN (the v0.84.0 re-break scenario): a
//!      manifest whose crystal entry carries a genuinely-unknown step
//!      key + a project that selected RUST → generate SUCCEEDS (warn
//!      only), rust wiring intact.

const std = @import("std");
const builtin = @import("builtin");
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

/// The crystal manifest entry, `zig`-flavored for a runnable suite: the
/// artifact-less "crystal-build" stand-in (`zig build-obj`) plus the two
/// per-OS localization stand-ins — `zig cc -r` for both, the clang
/// driver's RELOCATABLE LINK, which is literally the real macOS recipe's
/// `ld -r` mechanism and (unlike `zig objcopy`, ELF-only) handles the
/// host's object format on macOS and linux alike. The SHAPE under test
/// is the per-OS selection and chaining; the step names carry the per-OS
/// identity so the emission pins can tell the variants apart.
fn crystalManifest(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = "scripting",
        \\    .manifest_version = 1,
        \\    .params_schema = .{{
        \\        .{{ .name = "language", .type = .@"enum", .values = .{{ "lua", "ruby", "typescript", "rust", "crystal" }}, .required = true }},
        \\    }},
        \\    .language_builds = .{{
        \\        .{{
        \\            .language = "crystal",
        \\            .steps = .{{
        \\                .{{ .name = "crystal-build",
        \\                   .command = .{{ "{s}", "build-obj", "{{package}}/native-crystal/src/main.zig", "-femit-bin={{cache}}/labelle_crystal_scripts.o", "--cache-dir", "{{cache}}/zig-cache", "--global-cache-dir", "{{cache}}/zig-global", "-OReleaseSmall" }},
        \\                   .os = .{{ "macos", "linux" }},
        \\                   .platforms = .{{"desktop"}} }},
        \\                .{{ .name = "localize-main-macos",
        \\                   .command = .{{ "{s}", "cc", "-r", "{{cache}}/labelle_crystal_scripts.o", "-o", "{{cache}}/labelle_crystal_scripts_lib.o" }},
        \\                   .artifact = "{{cache}}/labelle_crystal_scripts_lib.o",
        \\                   .link = .object,
        \\                   .os = .{{"macos"}},
        \\                   .system_libs = .{{ .macos = .{{ "m" }} }},
        \\                   .library_paths = .{{"{{crystal_env:CRYSTAL_LIBRARY_PATH}}"}},
        \\                   .platforms = .{{"desktop"}} }},
        \\                .{{ .name = "localize-main-linux",
        \\                   .command = .{{ "{s}", "cc", "-r", "{{cache}}/labelle_crystal_scripts.o", "-o", "{{cache}}/labelle_crystal_scripts_lib.o" }},
        \\                   .artifact = "{{cache}}/labelle_crystal_scripts_lib.o",
        \\                   .link = .object,
        \\                   .os = .{{"linux"}},
        \\                   .system_libs = .{{ .linux = .{{ "m" }} }},
        \\                   .library_paths = .{{"{{crystal_env:CRYSTAL_LIBRARY_PATH}}"}},
        \\                   .platforms = .{{"desktop"}} }},
        \\            }},
        \\        }},
        \\    }},
        \\}}
    , .{ test_options.zig_exe, test_options.zig_exe, test_options.zig_exe });
}

const placeholder_game_cr =
    \\# Placeholder game module — REPLACED AT GENERATE.
    \\module Labelle
    \\  module Game
    \\    def self.register(scripts); end
    \\  end
    \\end
    \\
;

/// A staged tmp crystal game project mirroring `StagedRustProject`: the
/// manifest-bearing scripting plugin (with its `native-crystal/` crate,
/// shipped placeholder, and the declare-tool capability marker), a game
/// `crystal/` dir, the engine template fixture, and `out/`.
const StagedCrystalProject = struct {
    tmp: std.testing.TmpDir,
    game_abs: [:0]const u8,
    out_abs: [:0]const u8,

    fn init(allocator: std.mem.Allocator, opts: struct {
        manifest: ?[]const u8 = null,
        with_crystal_dir: bool = true,
    }) !StagedCrystalProject {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "out");
        try tmp.dir.createDirPath(io, "game");
        var game_root = try tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);

        if (opts.manifest) |m| {
            try writeFileIn(game_root, "plugins/scripting/plugin.labelle", m);
        } else {
            const m = try crystalManifest(allocator);
            defer allocator.free(m);
            try writeFileIn(game_root, "plugins/scripting/plugin.labelle", m);
        }
        // The plugin's native-crystal crate: main.zig is the zig stand-in
        // for main.cr (what the build-obj step compiles); game/game.cr is
        // the placeholder the game's crystal/ replaces.
        try writeFileIn(game_root, "plugins/scripting/native-crystal/src/main.zig",
            \\export fn labelle_cr_e2e_add(a: i32, b: i32) i32 {
            \\    return a + b;
            \\}
        );
        try writeFileIn(game_root, "plugins/scripting/native-crystal/src/game/game.cr", placeholder_game_cr);
        // The declare-tool capability marker: with it present, only the
        // native family's empty script set keeps the declare phase from
        // building the runner (the rust suite's pin, crystal twin).
        try writeFileIn(game_root, "plugins/scripting/tools/declare/declare.lua", "-- lua declare runner (fixture marker)\n");

        if (opts.with_crystal_dir) {
            try writeFileIn(game_root, "crystal/game.cr",
                \\require "./scripts/player"
                \\module Labelle
                \\  module Game
                \\    def self.register(scripts)
                \\    end
                \\  end
                \\end
                \\
            );
            try writeFileIn(game_root, "crystal/scripts/player.cr", "class Player\nend\n");
        }

        try writeFileIn(game_root, "engine-fixture/codegen/main.zig.template", h.engine_template);
        const game_abs = try tmp.dir.realPathFileAlloc(io, "game", allocator);
        errdefer allocator.free(game_abs);
        const out_abs = try tmp.dir.realPathFileAlloc(io, "out", allocator);
        return .{ .tmp = tmp, .game_abs = game_abs, .out_abs = out_abs };
    }

    fn deinit(self: *StagedCrystalProject, allocator: std.mem.Allocator) void {
        allocator.free(self.game_abs);
        allocator.free(self.out_abs);
        self.tmp.cleanup();
    }

    /// `language` is COMPTIME so the anonymous `.plugins` array literal is
    /// a static constant (the rust suite's dangling-frame lesson).
    fn configWithLanguage(self: *StagedCrystalProject, backend_repo: []const u8, comptime language: []const u8) generate.ProjectConfig {
        _ = self;
        return .{
            .name = "crystal-game",
            .backend = .sokol,
            .backend_package = .{ .name = "sokol", .repo = backend_repo },
            .ecs = .mock,
            .engine_version = "local:engine-fixture",
            .y_axis = .up,
            .plugins = &.{
                .{
                    .name = "scripting",
                    .repo = "local:plugins/scripting",
                    .params = .{ .language = language },
                },
            },
        };
    }

    fn config(self: *StagedCrystalProject, backend_repo: []const u8) generate.ProjectConfig {
        return self.configWithLanguage(backend_repo, "crystal");
    }
};

/// The host's expected localization-step name — the fixture declares one
/// per OS and the generate must select exactly the host's.
const host_localize_name = switch (builtin.os.tag) {
    .macos => "localize-main-macos",
    .linux => "localize-main-linux",
    else => "localize-unsupported-host",
};
const other_localize_name = switch (builtin.os.tag) {
    .macos => "localize-main-linux",
    .linux => "localize-main-macos",
    else => "localize-unsupported-host",
};

pub const CRYSTAL_SPLICE_E2E = struct {
    test "acceptance: crystal generate — shared touchpoints, .language = .crystal, live-linked game.cr, one per-OS step, chained artifact-less build, resolved library paths, runnable" {
        const allocator = std.testing.allocator;
        var staged = try StagedCrystalProject.init(allocator, .{});
        defer staged.deinit(allocator);

        // The crystal-env seam: no crystal toolchain in the suite — the
        // override IS the `crystal env CRYSTAL_LIBRARY_PATH` output,
        // multi-entry + trailing newline (the split-trap shape).
        generate.plugin_build_steps.crystal_env_output_override = "/fake/liba:/fake/libb\n";
        defer generate.plugin_build_steps.crystal_env_output_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        // ── Generated main: family-shared in, embed out ──
        const main_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        _ = try indexOfOrFail(main_zig, "const scripting = @import(\"scripting\");");
        _ = try indexOfOrFail(main_zig, "const scripting_enabled = true;");
        _ = try indexOfOrFail(main_zig, "scripting.Controller.tick(&g, scaled_dt);");
        _ = try indexOfOrFail(main_zig, "engine.script_contract.drainEvents(&g);");
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"crystal/") == null);

        // ── Generated build.zig ──
        const build_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1 << 20));
        defer allocator.free(build_zig);
        _ = try indexOfOrFail(build_zig, "const plugin_scripting_dep = b.dependency(\"labelle_scripting\", .{ .target = target, .optimize = optimize, .language = .crystal });");
        // Exactly the HOST's localization step; the other OS's is absent.
        const host_pin = try std.fmt.allocPrint(allocator, "// .build step '{s}' of plugin 'scripting'", .{host_localize_name});
        defer allocator.free(host_pin);
        const other_pin = try std.fmt.allocPrint(allocator, "'{s}'", .{other_localize_name});
        defer allocator.free(other_pin);
        _ = try indexOfOrFail(build_zig, host_pin);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, other_pin) == null);
        // Artifact-less intermediate: step 0 links nothing; the (single)
        // localization step is index 1, chained after it, its object linked.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "plugin_scripting_build_artifact_0") == null);
        _ = try indexOfOrFail(build_zig, "plugin_scripting_build_step_1.step.dependOn(&plugin_scripting_build_step_0.step);");
        _ = try indexOfOrFail(build_zig, "const plugin_scripting_build_artifact_1 = b.path(\"plugin-build/scripting/labelle_crystal_scripts_lib.o\");");
        _ = try indexOfOrFail(build_zig, "exe.root_module.addObjectFile(plugin_scripting_build_artifact_1);");
        _ = try indexOfOrFail(build_zig, "exe.step.dependOn(&plugin_scripting_build_step_1.step);");
        // The resolved library paths: the {crystal_env:…} token became the
        // SPLIT entries (never one bogus whole-value path).
        const lp_a = try indexOfOrFail(build_zig, "exe.root_module.addLibraryPath(.{ .cwd_relative = \"/fake/liba\" });");
        const lp_b = try indexOfOrFail(build_zig, "exe.root_module.addLibraryPath(.{ .cwd_relative = \"/fake/libb\" });");
        try std.testing.expect(lp_a < lp_b);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "/fake/liba:/fake/libb") == null);
        // The per-OS system libs ride the switch emission.
        _ = try indexOfOrFail(build_zig, "exe.root_module.linkSystemLibrary(\"m\", .{});");

        // ── Game-source staging: game.cr live-linked over the placeholder ──
        const staged_game_cr = try staged.tmp.dir.readFileAlloc(io, "out/deps/labelle-scripting/native-crystal/src/game/game.cr", allocator, .limited(4096));
        defer allocator.free(staged_game_cr);
        try std.testing.expect(std.mem.indexOf(u8, staged_game_cr, "REPLACED AT GENERATE") == null);
        _ = try indexOfOrFail(staged_game_cr, "require \"./scripts/player\"");
        try staged.tmp.dir.access(io, "out/deps/labelle-scripting/native-crystal/src/game/scripts/player.cr", .{});
        // Live view (the rust suite's staleness pin, crystal twin).
        var game_root = try staged.tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        try writeFileIn(game_root, "crystal/scripts/player.cr", "class Player\n  # edited_after_generate\nend\n");
        const staged_player = try staged.tmp.dir.readFileAlloc(io, "out/deps/labelle-scripting/native-crystal/src/game/scripts/player.cr", allocator, .limited(4096));
        defer allocator.free(staged_player);
        try std.testing.expect(std.mem.indexOf(u8, staged_player, "edited_after_generate") != null);

        // ── Declare phase skipped ──
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop/scripting_components.zig", .{}),
        );

        // ── The runnable proof (#586 splice-run): the emitted two-step
        // chain runs in declared order, the object links, the symbol is
        // reachable. The addLibraryPath lines ride along (a nonexistent
        // search dir is legal for the linker).
        var spliced: std.ArrayList(u8) = .empty;
        defer spliced.deinit(allocator);
        var lines = std.mem.splitScalar(u8, build_zig, '\n');
        while (lines.next()) |line| {
            const keep = std.mem.indexOf(u8, line, "plugin_scripting_build") != null or
                std.mem.indexOf(u8, line, "addLibraryPath") != null;
            if (!keep) continue;
            try spliced.appendSlice(allocator, line);
            try spliced.append(allocator, '\n');
        }
        try std.testing.expect(spliced.items.len > 0);

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
        , .{spliced.items});
        defer allocator.free(e2e_build);
        try writeFileIn(e2e_dir, "build.zig", e2e_build);
        try writeFileIn(e2e_dir, "main.zig",
            \\extern fn labelle_cr_e2e_add(a: i32, b: i32) i32;
            \\pub fn main() !void {
            \\    if (labelle_cr_e2e_add(20, 22) != 42) return error.WrongSum;
            \\}
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
        try e2e_dir.access(io, "plugin-build/scripting/labelle_crystal_scripts_lib.o", .{});
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

    test "per-OS selection through the seam: a macos generate emits the ld-variant only, a linux one the objcopy-variant only" {
        const allocator = std.testing.allocator;
        var staged = try StagedCrystalProject.init(allocator, .{});
        defer staged.deinit(allocator);
        generate.plugin_build_steps.crystal_env_output_override = "/fake/liba\n";
        defer generate.plugin_build_steps.crystal_env_output_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);

        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false, .plugin_build_os = .macos });
        {
            const build_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1 << 20));
            defer allocator.free(build_zig);
            _ = try indexOfOrFail(build_zig, "// .build step 'localize-main-macos' of plugin 'scripting'");
            try std.testing.expect(std.mem.indexOf(u8, build_zig, "localize-main-linux") == null);
        }

        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false, .plugin_build_os = .linux });
        {
            const build_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1 << 20));
            defer allocator.free(build_zig);
            _ = try indexOfOrFail(build_zig, "// .build step 'localize-main-linux' of plugin 'scripting'");
            try std.testing.expect(std.mem.indexOf(u8, build_zig, "localize-main-macos") == null);
        }
    }

    test "a windows generate fails pointedly: all-gated → NoStepsForOs; ungated intermediate → NoArtifactForOs (never an artifact-less chain)" {
        const allocator = std.testing.allocator;
        const backend_repo_owned = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo_owned);

        // (a) Every step OS-gated (the canonical crystal entry): windows
        // filters ALL steps → no steps at all.
        {
            var staged = try StagedCrystalProject.init(allocator, .{});
            defer staged.deinit(allocator);
            try std.testing.expectError(
                error.PluginBuildNoStepsForOs,
                generate.generate(allocator, staged.config(backend_repo_owned), staged.out_abs, staged.game_abs, .{ .is_tests_target = false, .plugin_build_os = .windows }),
            );
        }

        // (b) The codex shape: an UNgated intermediate survives the filter
        // but no artifact step does — an artifact-less chain would "build"
        // and then die at link. The gate must fire instead.
        {
            const manifest =
                \\.{
                \\    .name = "scripting",
                \\    .manifest_version = 1,
                \\    .language_builds = .{
                \\        .{
                \\            .language = "crystal",
                \\            .steps = .{
                \\                .{ .name = "crystal-build", .command = .{ "crystal", "build" } },
                \\                .{ .name = "localize-main-macos",
                \\                   .command = .{ "ld", "-r" },
                \\                   .artifact = "{cache}/lib.o",
                \\                   .link = .object,
                \\                   .os = .{"macos"} },
                \\                .{ .name = "localize-main-linux",
                \\                   .command = .{ "objcopy" },
                \\                   .artifact = "{cache}/lib.o",
                \\                   .link = .object,
                \\                   .os = .{"linux"} },
                \\            },
                \\        },
                \\    },
                \\}
            ;
            var staged = try StagedCrystalProject.init(allocator, .{ .manifest = manifest });
            defer staged.deinit(allocator);
            try std.testing.expectError(
                error.PluginBuildNoArtifactForOs,
                generate.generate(allocator, staged.config(backend_repo_owned), staged.out_abs, staged.game_abs, .{ .is_tests_target = false, .plugin_build_os = .windows }),
            );
        }
    }

    test "{crystal_target} reaches the generated build.zig as the crystalTriple const + argv slot" {
        const allocator = std.testing.allocator;
        const manifest =
            \\.{
            \\    .name = "scripting",
            \\    .manifest_version = 1,
            \\    .language_builds = .{
            \\        .{
            \\            .language = "crystal",
            \\            .steps = .{
            \\                .{ .name = "crystal-build",
            \\                   .command = .{ "crystal", "build", "--cross-compile", "--target", "{crystal_target}", "-o", "{cache}/scripts" },
            \\                   .os = .{ "macos", "linux" } },
            \\                .{ .name = "localize",
            \\                   .command = .{ "objcopy", "{cache}/scripts.o", "{cache}/scripts_lib.o" },
            \\                   .artifact = "{cache}/scripts_lib.o",
            \\                   .link = .object,
            \\                   .os = .{ "macos", "linux" } },
            \\            },
            \\        },
            \\    },
            \\}
        ;
        var staged = try StagedCrystalProject.init(allocator, .{ .manifest = manifest });
        defer staged.deinit(allocator);

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        // Text pins only — the crystal command never runs at generate.
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false, .plugin_build_os = .macos });

        const build_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1 << 20));
        defer allocator.free(build_zig);
        _ = try indexOfOrFail(build_zig, "const plugin_build_crystal_target: []const u8 = switch (target.result.os.tag) {");
        _ = try indexOfOrFail(build_zig, ".aarch64 => \"aarch64-apple-darwin\",");
        _ = try indexOfOrFail(build_zig, ".x86_64 => \"x86_64-linux-gnu\",");
        _ = try indexOfOrFail(build_zig, "\"--target\", plugin_build_crystal_target,");
    }

    test "FORWARD-COMPAT (the v0.84.0 re-break): a crystal entry with an unknown step key + a RUST project → generate succeeds" {
        const allocator = std.testing.allocator;
        // The exact scenario that broke v0.84.0's rust-example CI job:
        // the manifest gains a crystal entry whose steps use features this
        // assembler doesn't know (posed as `.futureopt`), and a project
        // that selected a DIFFERENT language must be untouched — the
        // entry warns and is ignored, the rust wiring lands intact.
        const manifest =
            \\.{
            \\    .name = "scripting",
            \\    .manifest_version = 1,
            \\    .language_builds = .{
            \\        .{
            \\            .language = "rust",
            \\            .steps = .{
            \\                .{ .name = "cargo-scripts", .command = .{ "cargo", "build" } },
            \\            },
            \\        },
            \\        .{
            \\            .language = "crystal",
            \\            .steps = .{
            \\                .{ .name = "crystal-build", .command = .{ "crystal", "build" }, .futureopt = .{ "x" } },
            \\            },
            \\        },
            \\    },
            \\}
        ;
        var staged = try StagedCrystalProject.init(allocator, .{ .manifest = manifest, .with_crystal_dir = false });
        defer staged.deinit(allocator);
        // A rust project needs the rust crate's stage parent when it has
        // sources — it has none here (zero-scripts shape), so no native/
        // crate is required.

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.configWithLanguage(backend_repo, "rust"), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        const build_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1 << 20));
        defer allocator.free(build_zig);
        // The rust selection wired; the crystal entry stayed inert.
        _ = try indexOfOrFail(build_zig, "// .build step 'cargo-scripts' of plugin 'scripting'");
        _ = try indexOfOrFail(build_zig, "const plugin_scripting_dep = b.dependency(\"labelle_scripting\", .{ .target = target, .optimize = optimize, .language = .rust });");
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "crystal-build") == null);
    }
};
