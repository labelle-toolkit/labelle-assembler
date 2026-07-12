//! Native-language scripting splice (labelle-engine#741, rust first) —
//! staged-project e2e over the REAL `generate`, mirroring the typescript
//! splice suite (`test/scripting_splice_tests.zig`) and the #586
//! acceptance (`test/plugin_build_steps_tests.zig`).
//!
//! The fixture MIRRORS labelle-scripting PR #17's shapes without any
//! network or cargo dependency: a local scripting plugin whose
//! `plugin.labelle` carries `.language_builds` with a `zig build-lib`
//! step (always present via the build-options `zig_exe` — the #586
//! trick) producing a staticlib named through `{staticlib:NAME}`, plus
//! the shipped `native/src/game/mod.rs` placeholder the game's `scripts/`
//! sources (the #237 convention; legacy `rust/` rides the grace fallback)
//! are staged over. The REAL cargo path is the scripting repo's CI.
//!
//! What only the production entry points can prove:
//!
//!   1. THE ACCEPTANCE: a rust project generates end to end — the
//!      generated main carries the family-shared touchpoints (alias +
//!      `scripting_enabled` flag, `Controller.tick`, drainEvents tap) and
//!      NONE of the embed ones (no registerScript, no @embedFile); the
//!      generated build.zig carries `.language = .rust` + the
//!      `.language_builds` step wiring (staticlib b.fmt artifact, per-OS
//!      system-libs switch); the game's `scripts/` dir is LINKED over the
//!      staged package's placeholder (the linkAndScan primitive —
//!      scanner.linkDirAbs; `scripts/mod.rs` becomes the crate's
//!      game-module root). Then the #586 splice-run: the EMITTED wiring
//!      lines, spliced into a minimal build.zig, run the command,
//!      expand `{staticlib:NAME}` for the host OS, link the artifact, and
//!      the binary reaches the symbol.
//!   2. THE EDIT LOOP IS LIVE (codex P2): a `scripts/*.rs` edit after
//!      generate reaches the staged crate with no re-generate — the pin
//!      a copy-based staging fails.
//!   3. `.build` + `.language_builds` coexist: one chained sequence per
//!      plugin, language steps strictly AFTER plain steps.
//!   4. Zero-scripts shape: a Zig-only `scripts/` (or none) → the plugin
//!      still wires (flag/tick/tap), the placeholder survives, generate
//!      succeeds.
//!   5. The staging gates fire through generate: an empty LEGACY `rust/`
//!      dir is a pointed error (grace keeps the old semantics; the legacy
//!      dir with sources also stages verbatim); a `desktop`-allowlisted
//!      language step still passes a desktop generate while an
//!      android-only one fails it.
//!   6. Negative controls: no declared language → `.language_builds` is
//!      inert (no markers, no staging); a lua project over a rust-only
//!      list is equally inert (wrong-language ignored) while the lua
//!      embed splice keeps working.

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

/// Stage an executable fake declare PROBE beside the fixture and return its
/// absolute path (caller frees). Rust's runner runs a prebuilt probe binary
/// with NO arguments (the declarations are compiled in), so the fake just
/// prints the schema — a `#!/bin/sh` stub, not a real cargo build, exactly
/// like the lua/ruby `stageFakeRunner`: the assembler suite must never
/// depend on a `cargo` on PATH or a network crate fetch (the real generate
/// + build is labelle-scripting's `rust-example` CI). Pointed at
/// `scripting_declare.declare_probe_override` by the caller.
fn stageFakeProbe(tmp: std.testing.TmpDir, allocator: std.mem.Allocator, schema_json: []const u8) ![:0]const u8 {
    const body = try std.fmt.allocPrint(allocator, "#!/bin/sh\necho '{s}'\n", .{schema_json});
    defer allocator.free(body);
    var f = try tmp.dir.createFile(io, "fake-declare-rs", .{ .permissions = .executable_file });
    defer f.close(io);
    try f.writeStreamingAll(io, body);
    return tmp.dir.realPathFileAlloc(io, "fake-declare-rs", allocator);
}

/// The in-tree sokol backend fixture as an ABSOLUTE `local:` repo (staged
/// games live in tmp dirs, so the repo-relative spelling can't resolve).
fn sokolFixtureRepoAbs(allocator: std.mem.Allocator) ![]const u8 {
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, "backends/sokol", allocator);
    defer allocator.free(abs);
    return std.fmt.allocPrint(allocator, "local:{s}", .{abs});
}

/// The PR #17 manifest, `zig build-lib`-flavored: `.params_schema` with
/// the four-language vocabulary, `.language_builds.rust` whose step
/// builds the plugin crate's `native/src/lib.zig` into
/// `{staticlib:labelle_rust_scripts}` under `{cache}`. `.system_libs`
/// declares only `m` on Linux — always linkable, so the splice-run works
/// on any CI host; the full gcc_s set is pinned by the emission golden in
/// `src/build_files/build_zig.zig`.
fn rustManifest(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = "scripting",
        \\    .manifest_version = 1,
        \\    .params_schema = .{{
        \\        .{{ .name = "language", .type = .@"enum", .values = .{{ "lua", "ruby", "typescript", "rust" }}, .required = true }},
        \\    }},
        \\    .language_builds = .{{
        \\        .{{
        \\            .language = "rust",
        \\            .steps = .{{
        \\                .{{ .name = "rust-scripts",
        \\                   .command = .{{ "{s}", "build-lib", "{{package}}/native/src/lib.zig", "-femit-bin={{cache}}/{{staticlib:labelle_rust_scripts}}", "--cache-dir", "{{cache}}/zig-cache", "--global-cache-dir", "{{cache}}/zig-global", "-OReleaseSmall" }},
        \\                   .artifact = "{{cache}}/{{staticlib:labelle_rust_scripts}}",
        \\                   .link = .static_lib,
        \\                   .system_libs = .{{ .linux = .{{ "m" }} }},
        \\                   .platforms = .{{"desktop"}} }},
        \\            }},
        \\        }},
        \\    }},
        \\}}
    , .{test_options.zig_exe});
}

const placeholder_mod_rs =
    \\//! Placeholder game module — REPLACED AT GENERATE.
    \\use crate::labelle::Scripts;
    \\pub fn register(_scripts: &mut Scripts) {}
    \\
;

/// A staged tmp rust game project mirroring `StagedTsProject`: the
/// manifest-bearing scripting plugin (with its `native/` crate, shipped
/// placeholder, and the declare-tool capability marker), game `scripts/`
/// sources (`scripts/mod.rs` — the #237 convention), the engine template
/// fixture, and `out/`.
const StagedRustProject = struct {
    tmp: std.testing.TmpDir,
    game_abs: [:0]const u8,
    out_abs: [:0]const u8,

    fn init(allocator: std.mem.Allocator, opts: struct {
        manifest: ?[]const u8 = null,
        with_rust_dir: bool = true,
        /// The declare-tool capability marker is only safe for fixtures
        /// whose declare phase SKIPS (native family / no scripts): a lua
        /// project with scripts would charge into `zig build
        /// labelle-declare` inside this build.zig-less fixture.
        with_declare_marker: bool = true,
    }) !StagedRustProject {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "out");
        try tmp.dir.createDirPath(io, "game");
        var game_root = try tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);

        if (opts.manifest) |m| {
            try writeFileIn(game_root, "plugins/scripting/plugin.labelle", m);
        } else {
            const m = try rustManifest(allocator);
            defer allocator.free(m);
            try writeFileIn(game_root, "plugins/scripting/plugin.labelle", m);
        }
        // The plugin's native crate: the zig stand-in for PR #17's cargo
        // crate — lib.zig is what the declared step compiles; game/mod.rs
        // is the placeholder the game's scripts/ sources replace.
        try writeFileIn(game_root, "plugins/scripting/native/src/lib.zig",
            \\export fn labelle_rs_e2e_add(a: i32, b: i32) i32 {
            \\    return a + b;
            \\}
        );
        try writeFileIn(game_root, "plugins/scripting/native/src/game/mod.rs", placeholder_mod_rs);
        // The declare-tool capability marker (labelle-scripting >= 0.2.0):
        // with it present, only the native family's empty script set
        // keeps the declare phase from building the runner — the pin that
        // the declare skip is real, not an accident of a bare fixture.
        if (opts.with_declare_marker) {
            try writeFileIn(game_root, "plugins/scripting/tools/declare/declare.lua", "-- lua declare runner (fixture marker)\n");
        }

        if (opts.with_rust_dir) {
            // The #237 convention: scripts/ holds the .rs sources at its
            // TOP LEVEL (subdir .rs is the resolve-time state-subdir
            // error), scripts/mod.rs is the crate's game-module root, and
            // a Zig script coexists in the same dir (extension-keyed).
            try writeFileIn(game_root, "scripts/mod.rs",
                \\mod player;
                \\use crate::labelle::Scripts;
                \\pub fn register(scripts: &mut Scripts) { let _ = scripts; }
                \\
            );
            try writeFileIn(game_root, "scripts/player.rs", "pub struct Player;\n");
            try writeFileIn(game_root, "scripts/01_move.zig", "pub fn tick() void {}\n");
        }

        try writeFileIn(game_root, "engine-fixture/codegen/main.zig.template", h.engine_template);
        const game_abs = try tmp.dir.realPathFileAlloc(io, "game", allocator);
        errdefer allocator.free(game_abs);
        const out_abs = try tmp.dir.realPathFileAlloc(io, "out", allocator);
        return .{ .tmp = tmp, .game_abs = game_abs, .out_abs = out_abs };
    }

    fn deinit(self: *StagedRustProject, allocator: std.mem.Allocator) void {
        allocator.free(self.game_abs);
        allocator.free(self.out_abs);
        self.tmp.cleanup();
    }

    /// `language` is COMPTIME so the anonymous `.plugins` array literal is
    /// a static constant: with a runtime parameter the `&.{ … }` would
    /// point into THIS function's dead frame once it returns (the borrow
    /// `generate` then walks — a garbage-length UB lottery).
    fn configWithLanguage(self: *StagedRustProject, backend_repo: []const u8, comptime language: ?[]const u8) generate.ProjectConfig {
        _ = self;
        return .{
            .name = "rust-game",
            .backend = .sokol,
            .backend_package = .{ .name = "sokol", .repo = backend_repo },
            .ecs = .mock,
            .engine_version = "local:engine-fixture",
            .y_axis = .up,
            .plugins = &.{
                .{
                    .name = "scripting",
                    .repo = "local:plugins/scripting",
                    .params = if (language) |l| .{ .language = l } else null,
                },
            },
        };
    }

    fn config(self: *StagedRustProject, backend_repo: []const u8) generate.ProjectConfig {
        return self.configWithLanguage(backend_repo, "rust");
    }
};

pub const NATIVE_SPLICE_E2E = struct {
    test "acceptance: rust generate — shared touchpoints in, embed touchpoints out, staging done, wiring emitted AND runnable" {
        const allocator = std.testing.allocator;
        var staged = try StagedRustProject.init(allocator, .{});
        defer staged.deinit(allocator);

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        // ── Generated main: the family-SHARED touchpoints ──
        const main_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        _ = try indexOfOrFail(main_zig, "const scripting = @import(\"scripting\");");
        _ = try indexOfOrFail(main_zig, "const scripting_enabled = true;");
        _ = try indexOfOrFail(main_zig, "scripting.Controller.tick(&g, scaled_dt);");
        _ = try indexOfOrFail(main_zig, "engine.script_contract.drainEvents(&g);");
        // …and NONE of the embed ones: nothing registers, nothing embeds.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript") == null);
        // Nothing embeds from the shared scripts/ dir either (the dir IS
        // linked in the target — for the ZIG scanner — but no language
        // embed path may reference it).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"scripts/") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"rust/") == null);

        // ── Generated build.zig: dep language + the language-build step ──
        const build_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1 << 20));
        defer allocator.free(build_zig);
        _ = try indexOfOrFail(build_zig, "const plugin_scripting_dep = b.dependency(\"labelle_scripting\", .{ .target = target, .optimize = optimize, .language = .rust });");
        // The .language_builds step rides the #586 wiring verbatim.
        _ = try indexOfOrFail(build_zig, "// .build step 'rust-scripts' of plugin 'scripting'");
        _ = try indexOfOrFail(build_zig, "const plugin_scripting_build_cache = b.pathFromRoot(\"plugin-build/scripting\");");
        // {staticlib:NAME}: shared prefix/ext consts + b.fmt in the argv
        // and the artifact path (windows `.lib` vs unix `lib….a`).
        _ = try indexOfOrFail(build_zig, "const plugin_build_lib_prefix: []const u8 = if (target.result.os.tag == .windows) \"\" else \"lib\";");
        _ = try indexOfOrFail(build_zig, "const plugin_build_lib_ext: []const u8 = if (target.result.os.tag == .windows) \".lib\" else \".a\";");
        _ = try indexOfOrFail(build_zig, "b.fmt(\"-femit-bin={s}/{s}labelle_rust_scripts{s}\", .{ plugin_scripting_build_cache, plugin_build_lib_prefix, plugin_build_lib_ext })");
        _ = try indexOfOrFail(build_zig, "const plugin_scripting_build_artifact_0 = b.path(b.fmt(\"plugin-build/scripting/{s}labelle_rust_scripts{s}\", .{ plugin_build_lib_prefix, plugin_build_lib_ext }));");
        _ = try indexOfOrFail(build_zig, "exe.root_module.addObjectFile(plugin_scripting_build_artifact_0);");
        _ = try indexOfOrFail(build_zig, "exe.step.dependOn(&plugin_scripting_build_step_0.step);");
        // The per-OS system-libs switch (declared: linux-only `m`).
        _ = try indexOfOrFail(build_zig, "    switch (target.result.os.tag) {\n" ++
            "        .linux => {\n" ++
            "            exe.root_module.linkSystemLibrary(\"m\", .{});\n" ++
            "        },\n" ++
            "        else => {},\n" ++
            "    }\n");
        // The {cache} work dir exists (a command's first write must not
        // hit a missing parent).
        try staged.tmp.dir.access(io, "out/sokol_desktop/plugin-build/scripting", .{});

        // ── Game-source staging: placeholder replaced by the dir link ──
        const staged_mod = try staged.tmp.dir.readFileAlloc(io, "out/deps/labelle-scripting/native/src/game/mod.rs", allocator, .limited(4096));
        defer allocator.free(staged_mod);
        try std.testing.expect(std.mem.indexOf(u8, staged_mod, "REPLACED AT GENERATE") == null);
        _ = try indexOfOrFail(staged_mod, "mod player;");
        try staged.tmp.dir.access(io, "out/deps/labelle-scripting/native/src/game/player.rs", .{});
        // The coexisting Zig script rides the link too — benign, rustc
        // compiles only what mod.rs declares (stageNativeSources doc).
        try staged.tmp.dir.access(io, "out/deps/labelle-scripting/native/src/game/01_move.zig", .{});
        // The GAME tree is untouched (staging links, never moves).
        try staged.tmp.dir.access(io, "game/scripts/mod.rs", .{});

        // ── Declare phase skipped (native family embeds nothing) ──
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop/scripting_components.zig", .{}),
        );

        // ── The runnable proof (#586 splice-run): the EMITTED lines,
        // spliced into a minimal build.zig, run the command, expand the
        // staticlib name for the HOST OS, link the artifact, reach the
        // symbol. The shared lib consts don't carry the per-plugin marker,
        // so the filter takes both vocabularies.
        var spliced: std.ArrayList(u8) = .empty;
        defer spliced.deinit(allocator);
        var lines = std.mem.splitScalar(u8, build_zig, '\n');
        while (lines.next()) |line| {
            const keep = std.mem.indexOf(u8, line, "plugin_scripting_build") != null or
                std.mem.indexOf(u8, line, "plugin_build_lib_") != null;
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
            \\extern fn labelle_rs_e2e_add(a: i32, b: i32) i32;
            \\pub fn main() !void {
            \\    if (labelle_rs_e2e_add(20, 22) != 42) return error.WrongSum;
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
        // The staticlib landed under its HOST-expanded name.
        const host_lib_name = if (builtin.os.tag == .windows)
            "plugin-build/scripting/labelle_rust_scripts.lib"
        else
            "plugin-build/scripting/liblabelle_rust_scripts.a";
        try e2e_dir.access(io, host_lib_name, .{});
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

    test "the edit loop is live: a scripts/*.rs edit AFTER generate reaches the staged crate without re-generating" {
        // The codex P2 pin: the staged package's native/src/game is the
        // linkAndScan primitive (a dir link back into the game), NOT a
        // generate-time copy — so `edit scripts/player.rs; zig build` runs
        // cargo over the CURRENT sources, exactly like editing
        // scripts/*.lua flows through the linked embed script dir. A copy
        // design goes silently stale here until the next generate.
        const allocator = std.testing.allocator;
        var staged = try StagedRustProject.init(allocator, .{});
        defer staged.deinit(allocator);

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        // Post-generate edit — no second generate follows.
        var game_root = try staged.tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        try writeFileIn(game_root, "scripts/player.rs", "pub struct Player { edited_after_generate: bool }\n");

        const staged_player = try staged.tmp.dir.readFileAlloc(io, "out/deps/labelle-scripting/native/src/game/player.rs", allocator, .limited(4096));
        defer allocator.free(staged_player);
        try std.testing.expect(std.mem.indexOf(u8, staged_player, "edited_after_generate") != null);

        // A brand-new script file appears in the staged crate too (the
        // link exposes the dir, not a snapshot of its file list).
        try writeFileIn(game_root, "scripts/enemy.rs", "pub struct Enemy;\n");
        try staged.tmp.dir.access(io, "out/deps/labelle-scripting/native/src/game/enemy.rs", .{});
    }

    test ".build + .language_builds coexist: one chained sequence, language steps strictly after plain steps" {
        const allocator = std.testing.allocator;
        const manifest =
            \\.{
            \\    .name = "scripting",
            \\    .manifest_version = 1,
            \\    .build = .{
            \\        .steps = .{
            \\            .{ .name = "gen", .command = .{ "true" } },
            \\        },
            \\    },
            \\    .language_builds = .{
            \\        .{
            \\            .language = "rust",
            \\            .steps = .{
            \\                .{ .name = "cargo-scripts",
            \\                   .command = .{ "cargo", "build", "--target-dir", "{cache}" },
            \\                   .artifact = "{cache}/release/{staticlib:labelle_rust_scripts}",
            \\                   .link = .static_lib },
            \\            },
            \\        },
            \\    },
            \\}
        ;
        var staged = try StagedRustProject.init(allocator, .{ .manifest = manifest });
        defer staged.deinit(allocator);

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        const build_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1 << 20));
        defer allocator.free(build_zig);

        // .build's step is index 0, the language step index 1 — and the
        // chain orders the language build AFTER the plain build.
        const gen_step = try indexOfOrFail(build_zig, "// .build step 'gen' of plugin 'scripting'");
        const cargo_step = try indexOfOrFail(build_zig, "// .build step 'cargo-scripts' of plugin 'scripting'");
        try std.testing.expect(gen_step < cargo_step);
        _ = try indexOfOrFail(build_zig, "plugin_scripting_build_step_1.step.dependOn(&plugin_scripting_build_step_0.step);");
        // The game artifact waits for the LAST (language) step.
        _ = try indexOfOrFail(build_zig, "exe.step.dependOn(&plugin_scripting_build_step_1.step);");
        _ = try indexOfOrFail(build_zig, "exe.root_module.addObjectFile(plugin_scripting_build_artifact_1);");
    }

    test "zero native scripts (Zig-only scripts/): the plugin still wires, the shipped placeholder survives" {
        const allocator = std.testing.allocator;
        var staged = try StagedRustProject.init(allocator, .{ .with_rust_dir = false });
        defer staged.deinit(allocator);
        // scripts/ EXISTS but is Zig-only — every plain Zig game's state;
        // must behave exactly like a missing dir for the native family
        // (no-op, no pointed error — that stays legacy-dir-only).
        var game_root = try staged.tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        try writeFileIn(game_root, "scripts/01_move.zig", "pub fn tick() void {}\n");

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        const main_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        _ = try indexOfOrFail(main_zig, "const scripting_enabled = true;");
        _ = try indexOfOrFail(main_zig, "scripting.Controller.tick(&g, scaled_dt);");
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript") == null);

        // The placeholder is the game module — it registers nothing.
        const staged_mod = try staged.tmp.dir.readFileAlloc(io, "out/deps/labelle-scripting/native/src/game/mod.rs", allocator, .limited(4096));
        defer allocator.free(staged_mod);
        _ = try indexOfOrFail(staged_mod, "REPLACED AT GENERATE");
    }

    test "an empty LEGACY rust/ dir fails generate pointedly (unlike a missing one — grace keeps the old error)" {
        const allocator = std.testing.allocator;
        var staged = try StagedRustProject.init(allocator, .{ .with_rust_dir = false });
        defer staged.deinit(allocator);
        var game_root = try staged.tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        try writeFileIn(game_root, "rust/.gitkeep", "");

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try std.testing.expectError(
            error.NativeScriptDirEmpty,
            generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false }),
        );
    }

    test "LEGACY rust/ sources stage verbatim through the REAL generate (one release of grace, nested modules kept)" {
        const allocator = std.testing.allocator;
        var staged = try StagedRustProject.init(allocator, .{ .with_rust_dir = false });
        defer staged.deinit(allocator);
        var game_root = try staged.tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        // The unmigrated layout, nested module dir included (legal in the
        // legacy dir; the scripts/ convention gates it at resolve).
        try writeFileIn(game_root, "rust/mod.rs",
            \\mod player;
            \\mod ai;
            \\use crate::labelle::Scripts;
            \\pub fn register(scripts: &mut Scripts) { let _ = scripts; }
            \\
        );
        try writeFileIn(game_root, "rust/player.rs", "pub struct Player;\n");
        try writeFileIn(game_root, "rust/ai/brain.rs", "pub fn think() {}\n");

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        // Staged over the placeholder, subtree intact — pre-#237 verbatim.
        const staged_mod = try staged.tmp.dir.readFileAlloc(io, "out/deps/labelle-scripting/native/src/game/mod.rs", allocator, .limited(4096));
        defer allocator.free(staged_mod);
        try std.testing.expect(std.mem.indexOf(u8, staged_mod, "REPLACED AT GENERATE") == null);
        try staged.tmp.dir.access(io, "out/deps/labelle-scripting/native/src/game/ai/brain.rs", .{});
    }

    test "a .language_builds step allowlisting only android fails a desktop generate (the #586 gate, labeled)" {
        const allocator = std.testing.allocator;
        const manifest =
            \\.{
            \\    .name = "scripting",
            \\    .manifest_version = 1,
            \\    .language_builds = .{
            \\        .{
            \\            .language = "rust",
            \\            .steps = .{
            \\                .{ .name = "ndk-cargo", .command = .{ "cargo" }, .platforms = .{"android"} },
            \\            },
            \\        },
            \\    },
            \\}
        ;
        var staged = try StagedRustProject.init(allocator, .{ .manifest = manifest });
        defer staged.deinit(allocator);

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try std.testing.expectError(
            error.PluginBuildUnsupportedPlatform,
            generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false }),
        );
    }

    test "negative control: no declared language → .language_builds is inert (no markers, no staging, no splice)" {
        const allocator = std.testing.allocator;
        // Schema-less manifest (a required-language schema would rightly
        // reject a language-less attach — #591); the .language_builds key
        // is present but must load nothing without a declaration.
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
            \\    },
            \\}
        ;
        var staged = try StagedRustProject.init(allocator, .{ .manifest = manifest, .with_rust_dir = false });
        defer staged.deinit(allocator);

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.configWithLanguage(backend_repo, null), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        const build_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1 << 20));
        defer allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "plugin_scripting_build") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, ".language") == null);

        const main_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "scripting_enabled") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "Controller.tick") == null);
    }

    test "negative control: a lua project over a rust-only .language_builds — wrong language ignored, embed splice untouched" {
        const allocator = std.testing.allocator;
        // No declare marker: a lua project with a script would otherwise
        // run the REAL declare-tool build inside this build.zig-less
        // fixture (the marker is the ts/rust "skip is real" pin only).
        var staged = try StagedRustProject.init(allocator, .{ .with_rust_dir = false, .with_declare_marker = false });
        defer staged.deinit(allocator);
        var game_root = try staged.tmp.dir.openDir(io, "game", .{});
        defer game_root.close(io);
        try writeFileIn(game_root, "lua/player.lua", "-- lua script\n");

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.configWithLanguage(backend_repo, "lua"), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        const build_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1 << 20));
        defer allocator.free(build_zig);
        // The rust entry is IGNORED for a lua project — no step wiring…
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "plugin_scripting_build") == null);
        // …while the embed splice works exactly as before (#593).
        _ = try indexOfOrFail(build_zig, "const plugin_scripting_dep = b.dependency(\"labelle_scripting\", .{ .target = target, .optimize = optimize, .language = .lua });");

        const main_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        _ = try indexOfOrFail(main_zig, "scripting.registerScript(\"player\", @embedFile(\"lua/player.lua\"));");
        // The lua project's staged plugin keeps its placeholder — native
        // staging is family-gated and never ran.
        const staged_mod = try staged.tmp.dir.readFileAlloc(io, "out/deps/labelle-scripting/native/src/game/mod.rs", allocator, .limited(4096));
        defer allocator.free(staged_mod);
        _ = try indexOfOrFail(staged_mod, "REPLACED AT GENERATE");
    }
};

// ── The declare phase for the NATIVE family (labelle-engine#774) ──────
//
// The native family DECLARES components/events in `.rs` the same way the
// embed family declares them in `.rb`/`.lua`; only the runner mechanism
// differs (a generated cargo probe vs a prebuilt exe). These pin the
// assembler's half — the collection + the cargo-probe wiring + the shared
// consumer path — through the real `generate`, with the cargo build itself
// bypassed by `declare_probe_override` (the real build is the scripting
// repo's `rust-example` CI, exactly as the lua/ruby tools' behavior is
// pinned by that repo's goldens, not here).
pub const NATIVE_DECLARE_E2E = struct {
    /// The pinned schema example — what the staged fake probe prints.
    const hunger_schema =
        \\{"components":[{"name":"Hunger","persist":"persistent","fields":[{"name":"level","type":"f32","default":1.0},{"name":"starving","type":"bool","default":false}]}]}
    ;

    test "a declaring RUST project generates scripting_components.zig (real generate, cargo-probe override)" {
        const allocator = std.testing.allocator;
        // No scripts/ dir: the declare phase is independent of the native
        // script staging (a 100% .rs-declarations game needs no behavior
        // scripts to declare components), so stageNativeSources no-ops and
        // the tests target needs no deps recreation.
        var staged = try StagedRustProject.init(allocator, .{ .with_rust_dir = false });
        defer staged.deinit(allocator);
        var game = try staged.tmp.dir.openDir(io, "game", .{});
        defer game.close(io);
        // The rust declaration file, where its KIND lives (#237) — beside
        // any Zig components. Its body is REAL but unread by the fake probe
        // (the macros' real behavior is the scripting repo's golden).
        try writeFileIn(game, "components/hunger.rs",
            \\use crate::labelle;
            \\labelle::component! { Hunger { level: f32 = 0.875, starving: bool = false } }
        );

        const fake = try stageFakeProbe(staged.tmp, allocator, hunger_schema);
        defer allocator.free(fake);
        generate.scripting_declare.declare_probe_override = fake;
        defer generate.scripting_declare.declare_probe_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = true });

        // The cargo-probe path fed the SAME consumer as lua/ruby: the
        // component codegenned into scripting_components.zig, canonical shape.
        const gen_src = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/scripting_components.zig", allocator, .limited(64 * 1024));
        defer allocator.free(gen_src);
        _ = try indexOfOrFail(gen_src, "pub const Hunger = struct {");
        // The fake prints hunger_schema (level 1.0 → `= 1`); the REAL macro's
        // 0.875 byte-parity is the scripting repo's cross-runner golden.
        _ = try indexOfOrFail(gen_src, "level: f32 = 1,");
    }

    test "no .rs declarations → the native declare phase is a silent no-op (no generated file)" {
        // The invariant the rust-example CI pins for a NON-declaring native
        // game: with no components/*.rs (and no events/*.rs) the phase
        // returns at its zero-files gate before touching the cargo probe —
        // no file, no note. (The override is set but never reached.)
        const allocator = std.testing.allocator;
        var staged = try StagedRustProject.init(allocator, .{ .with_rust_dir = false });
        defer staged.deinit(allocator);

        const fake = try stageFakeProbe(staged.tmp, allocator, hunger_schema);
        defer allocator.free(fake);
        generate.scripting_declare.declare_probe_override = fake;
        defer generate.scripting_declare.declare_probe_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = true });

        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop/scripting_components.zig", .{}),
        );
    }
};
