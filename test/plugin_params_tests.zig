//! Schema-declared plugin params — e2e tests through the REAL `generate`
//! entry point (labelle-assembler#591, epic labelle-engine#237).
//!
//! The unit halves live inline in `src/plugin_params.zig` (Zoir extraction /
//! sanitized-source blanking / schema parse / validation matrix / module
//! render golden) and `src/root/generate_phases.zig`. These tests close what
//! only the production pipeline can prove:
//!
//!   1. a plugin fixture declaring `.params_schema` + a project `.params`
//!      bag → the target holds the staged `plugin_<name>_params.zig` with
//!      the exact resolved comptime decls, and the generated build.zig
//!      wires it into the plugin module via `overrideImport` under the
//!      fixed `plugin_params` import name — including from a project
//!      .labelle SOURCE through the tolerant parse;
//!   2. missing-required and wrong-type params fail generate BEFORE any
//!      target write (no stale `.labelle/<target>/`), with the pointed
//!      error;
//!   3. the byte-identity half: a schema-less plugin carrying the legacy
//!      `.params = .{ .language = … }` — every published scripting pin —
//!      generates with ZERO #591 markers, exactly as on main (the committed
//!      goldens `sokol_desktop_v2_plugins.build.zig` + the language-policy
//!      byte-identity suite pin the params-less bytes; these tests add the
//!      explicit no-markers regression on the scripting shape).

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

/// The in-tree sokol backend fixture as an ABSOLUTE `local:` package —
/// staged game projects live in tmp dirs, so the repo-relative spelling
/// can't resolve. Caller frees `repo`. (Same shape as the #584 policy
/// suite's helper.)
fn sokolFixtureAbs(allocator: std.mem.Allocator) !generate.PluginDep {
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, "backends/sokol", allocator);
    defer allocator.free(abs);
    const repo = try std.fmt.allocPrint(allocator, "local:{s}", .{abs});
    return .{ .name = "sokol", .repo = repo };
}

/// A staged tmp game project: `game/` with a local `plugins/acme/` plugin
/// whose `plugin.labelle` declares a `.params_schema`, and `out/` for the
/// generate output. The schema exercises every param type: a required enum,
/// a defaulted i64/f64/bool, and an optional str with no default.
const StagedProject = struct {
    tmp: std.testing.TmpDir,
    game_abs: [:0]const u8,
    out_abs: [:0]const u8,

    const acme_manifest =
        \\.{
        \\    .name = "acme",
        \\    .manifest_version = 1,
        \\    .params_schema = .{
        \\        .{ .name = "grid_size", .type = .i64, .default = 32 },
        \\        .{ .name = "mode", .type = .@"enum", .values = .{ "platformer", "topdown" }, .required = true },
        \\        .{ .name = "gravity", .type = .f64, .default = 9.81 },
        \\        .{ .name = "debug_draw", .type = .bool, .default = false },
        \\        .{ .name = "label", .type = .str },
        \\    },
        \\}
    ;

    fn init(allocator: std.mem.Allocator) !StagedProject {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "game/plugins/acme");
        try tmp.dir.createDirPath(io, "out");
        {
            var f = try tmp.dir.createFile(io, "game/plugins/acme/plugin.labelle", .{});
            defer f.close(io);
            try f.writeStreamingAll(io, acme_manifest);
        }
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

    fn config(self: *StagedProject, backend: generate.PluginDep, plugins: []const generate.PluginDep) generate.ProjectConfig {
        _ = self;
        return .{
            .name = "params-game",
            .backend = .sokol,
            .backend_package = backend,
            .ecs = .mock,
            .plugins = plugins,
        };
    }

    fn readOut(self: *StagedProject, allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
        const full = try std.fs.path.join(allocator, &.{ "out", rel });
        defer allocator.free(full);
        return self.tmp.dir.readFileAlloc(io, full, allocator, .limited(1 << 20));
    }
};

/// The exact module the acme fixture + the `.params` bag below must stage —
/// the e2e delivery golden (the unit golden in plugin_params.zig covers the
/// renderer alone; this pins the whole resolve→render→stage path).
const expected_acme_module =
    \\//! Generated by labelle-assembler (#591) — resolved `.params` for plugin 'acme'.
    \\//! Comptime plugin configuration: the assembler injects this module into the
    \\//! plugin as `@import("plugin_params")`. Do not edit; regenerated every `labelle generate`.
    \\
    \\pub const grid_size: i64 = 64;
    \\
    \\pub const Mode = enum { platformer, topdown };
    \\pub const mode: Mode = .topdown;
    \\
    \\pub const gravity: f64 = 9.81;
    \\
    \\pub const debug_draw: bool = false;
    \\
;

pub const DELIVERY = struct {
    test "schema + project .params → staged params module with exact comptime decls + build.zig injection (#591)" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);

        const backend = try sokolFixtureAbs(allocator);
        defer allocator.free(backend.repo);

        // Project sets an i64 + the required enum (via enum literal);
        // gravity/debug_draw fall to their schema defaults; label (optional,
        // no default) is omitted.
        const bag = [_]generate.plugin_params.Param{
            .{ .name = "grid_size", .value = .{ .int = 64 } },
            .{ .name = "mode", .value = .{ .enum_tag = "topdown" } },
        };
        const plugins = [_]generate.PluginDep{
            .{ .name = "acme", .repo = "local:plugins/acme", .params_bag = &bag },
        };
        const cfg = staged.config(backend, &plugins);
        try generate.generate(allocator, cfg, staged.out_abs, staged.game_abs, .{ .is_tests_target = true });

        // The staged module: exact bytes (resolve → render → stage golden).
        const module = try staged.readOut(allocator, "sokol_desktop/plugin_acme_params.zig");
        defer allocator.free(module);
        try std.testing.expectEqualStrings(expected_acme_module, module);

        // The generated build.zig wires it under the FIXED import name.
        const build_zig = try staged.readOut(allocator, "sokol_desktop/build.zig");
        defer allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "    const plugin_acme_params_mod = b.createModule(.{\n" ++
            "        .root_source_file = b.path(\"plugin_acme_params.zig\"),\n" ++
            "        .target = target,\n" ++
            "        .optimize = optimize,\n" ++
            "    });\n" ++
            "    overrideImport(plugin_acme_mod, \"plugin_params\", plugin_acme_params_mod);\n") != null);
    }

    test "the same delivery from a project.labelle SOURCE through the tolerant parse (#591)" {
        // Everything the previous test hand-built, driven from the actual
        // config text a user writes — proving source → Zoir extraction →
        // typed parse → generate end-to-end.
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);

        const backend = try sokolFixtureAbs(allocator);
        defer allocator.free(backend.repo);

        const source: [:0]const u8 =
            \\.{
            \\    .name = "params-game",
            \\    .plugins = .{
            \\        .{ .name = "acme", .repo = "local:plugins/acme", .params = .{
            \\            .grid_size = 64,
            \\            .mode = .topdown,
            \\        } },
            \\    },
            \\}
        ;
        // Arena for the parsed config (a full ProjectConfig is not
        // zon-freeable — the pre-existing repo pattern).
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var cfg = try generate.plugin_params.parseProjectConfig(arena.allocator(), source);
        cfg.backend = .sokol;
        cfg.backend_package = backend;
        cfg.ecs = .mock;

        try generate.generate(allocator, cfg, staged.out_abs, staged.game_abs, .{ .is_tests_target = true });

        const module = try staged.readOut(allocator, "sokol_desktop/plugin_acme_params.zig");
        defer allocator.free(module);
        try std.testing.expectEqualStrings(expected_acme_module, module);
    }
};

pub const GENERATE_GATE = struct {
    test "missing required param fails generate BEFORE any target write, naming plugin + param (#591)" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);

        const backend = try sokolFixtureAbs(allocator);
        defer allocator.free(backend.repo);

        // `mode` is `.required = true` in the fixture schema — a bag
        // without it must reject the build.
        const bag = [_]generate.plugin_params.Param{
            .{ .name = "grid_size", .value = .{ .int = 64 } },
        };
        const plugins = [_]generate.PluginDep{
            .{ .name = "acme", .repo = "local:plugins/acme", .params_bag = &bag },
        };
        const cfg = staged.config(backend, &plugins);
        try std.testing.expectError(
            error.MissingRequiredPluginParam,
            generate.generate(allocator, cfg, staged.out_abs, staged.game_abs, .{ .is_tests_target = true }),
        );
        // The gate runs beside the language-policy gate, BEFORE the target
        // dir is created — a rejected build leaves no stale output.
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop", .{}),
        );
    }

    test "wrong-typed param fails generate with the pointed error (#591)" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);

        const backend = try sokolFixtureAbs(allocator);
        defer allocator.free(backend.repo);

        // grid_size is .i64; a string is a type mismatch.
        const bag = [_]generate.plugin_params.Param{
            .{ .name = "mode", .value = .{ .str = "topdown" } },
            .{ .name = "grid_size", .value = .{ .str = "64" } },
        };
        const plugins = [_]generate.PluginDep{
            .{ .name = "acme", .repo = "local:plugins/acme", .params_bag = &bag },
        };
        const cfg = staged.config(backend, &plugins);
        try std.testing.expectError(
            error.PluginParamTypeMismatch,
            generate.generate(allocator, cfg, staged.out_abs, staged.game_abs, .{ .is_tests_target = true }),
        );
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop", .{}),
        );
    }

    test "out-of-vocabulary enum + unknown param each reject with their own error (#591)" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);

        const backend = try sokolFixtureAbs(allocator);
        defer allocator.free(backend.repo);

        const oov = [_]generate.plugin_params.Param{
            .{ .name = "mode", .value = .{ .enum_tag = "sideways" } },
        };
        const oov_plugins = [_]generate.PluginDep{
            .{ .name = "acme", .repo = "local:plugins/acme", .params_bag = &oov },
        };
        try std.testing.expectError(
            error.PluginParamInvalidEnumValue,
            generate.generate(allocator, staged.config(backend, &oov_plugins), staged.out_abs, staged.game_abs, .{ .is_tests_target = true }),
        );

        const unknown = [_]generate.plugin_params.Param{
            .{ .name = "mode", .value = .{ .enum_tag = "topdown" } },
            .{ .name = "grid_sise", .value = .{ .int = 64 } },
        };
        const unknown_plugins = [_]generate.PluginDep{
            .{ .name = "acme", .repo = "local:plugins/acme", .params_bag = &unknown },
        };
        try std.testing.expectError(
            error.UnknownPluginParam,
            generate.generate(allocator, staged.config(backend, &unknown_plugins), staged.out_abs, staged.game_abs, .{ .is_tests_target = true }),
        );

        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop", .{}),
        );
    }
};

pub const BYTE_IDENTITY = struct {
    test "schema-less plugin + legacy `.params.language` generates with ZERO #591 markers (#589 pins)" {
        // The native fast path: every published scripting pin — a plugin
        // whose plugin.labelle predates `.params_schema` — declaring
        // `.params = .{ .language = "lua" }` must generate exactly as on
        // main. The committed goldens pin the bytes; this test adds the
        // explicit no-markers regression through the REAL generate.
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "game/plugins/scripting");
        try tmp.dir.createDirPath(io, "out");
        // A manifest-LESS plugin dir (the #584 policy-suite staging shape).
        const game_abs = try tmp.dir.realPathFileAlloc(io, "game", allocator);
        defer allocator.free(game_abs);
        const out_abs = try tmp.dir.realPathFileAlloc(io, "out", allocator);
        defer allocator.free(out_abs);

        const backend = try sokolFixtureAbs(allocator);
        defer allocator.free(backend.repo);

        const plugins = [_]generate.PluginDep{
            .{ .name = "labelle-scripting", .repo = "local:plugins/scripting", .params = .{ .language = "lua" } },
        };
        const cfg = generate.ProjectConfig{
            .name = "lua-game",
            .backend = .sokol,
            .backend_package = backend,
            .ecs = .mock,
            .plugins = &plugins,
        };
        try generate.generate(allocator, cfg, out_abs, game_abs, .{ .is_tests_target = true });

        const build_zig = try tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1 << 20));
        defer allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "plugin_params") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "params_mod") == null);
        // No params module staged either.
        try std.testing.expectError(
            error.FileNotFound,
            tmp.dir.access(io, "out/sokol_desktop/plugin_labelle-scripting_params.zig", .{}),
        );
    }

    test "params-less plugin project: unit build.zig output carries no #591 wiring (golden anchor unchanged)" {
        // The committed `sokol_desktop_v2_plugins.build.zig` golden (the
        // params-less plugin-bearing pin) stays byte-identical — its suite
        // enforces equality; here the same emitter output is checked for
        // marker ABSENCE so a future default-on regression fails HERE with
        // a readable message rather than as a 400-line golden diff.
        const cfg = generate.ProjectConfig{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "physics", .repo = "github:x/physics", .version = "1.0.0" },
            },
        };
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, cfg, .{});
        defer std.testing.allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "plugin_params") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "params_mod") == null);
    }
};

pub const ENUM_LITERAL_LANGUAGE = struct {
    test "a schema-declared enum `.language = .lua` reaches the policy AND the scripting splice (#591 P2)" {
        // The silent-failure gap: the policy gate and `scripting_splice
        // .detect` resolve the language through `PluginDep.declaredLanguage`
        // BEFORE param resolution runs. When the scripting plugin's schema
        // declares `language` as an enum and the project writes the natural
        // enum-literal spelling, a str-only accessor read "no declaration"
        // — one-language checks and the WHOLE splice silently skipped while
        // validateAndResolve happily accepted the value. This pins the
        // repaired path end to end from the project.labelle SOURCE: the
        // splice fires (the `-Dlanguage` dep arg is emitted) and the params
        // module still delivers the enum comptime.
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "game/plugins/scripting");
        try tmp.dir.createDirPath(io, "out");
        try writeFileIn(tmp.dir, "game/plugins/scripting/plugin.labelle",
            \\.{
            \\    .name = "scripting",
            \\    .manifest_version = 1,
            \\    .params_schema = .{
            \\        .{ .name = "language", .type = .@"enum", .values = .{ "lua", "typescript" }, .required = true },
            \\    },
            \\}
        );
        const game_abs = try tmp.dir.realPathFileAlloc(io, "game", allocator);
        defer allocator.free(game_abs);
        const out_abs = try tmp.dir.realPathFileAlloc(io, "out", allocator);
        defer allocator.free(out_abs);

        const backend = try sokolFixtureAbs(allocator);
        defer allocator.free(backend.repo);

        const source: [:0]const u8 =
            \\.{
            \\    .name = "enum-lang-game",
            \\    .plugins = .{
            \\        .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = .lua } },
            \\    },
            \\}
        ;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var cfg = try generate.plugin_params.parseProjectConfig(arena.allocator(), source);
        cfg.backend = .sokol;
        cfg.backend_package = backend;
        cfg.ecs = .mock;

        try generate.generate(allocator, cfg, out_abs, game_abs, .{ .is_tests_target = true });

        // The splice fired: the scripting plugin's b.dependency args carry
        // the `-Dlanguage` option — absent exactly when detect() silently
        // skipped (the pre-fix behavior).
        const build_zig = try tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1 << 20));
        defer allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, ".language = .lua") != null);

        // And the schema path still delivers the enum comptime.
        const module = try tmp.dir.readFileAlloc(io, "out/sokol_desktop/plugin_scripting_params.zig", allocator, .limited(1 << 20));
        defer allocator.free(module);
        try std.testing.expect(std.mem.indexOf(u8, module, "pub const Language = enum { lua, typescript };") != null);
        try std.testing.expect(std.mem.indexOf(u8, module, "pub const language: Language = .lua;") != null);
    }

    test "an enum-literal `.language` outside the POLICY vocabulary still fails the policy gate (#591 P2)" {
        // Defense in depth: a third-party schema could vocabulary a language
        // the toolkit doesn't support ("klingon") — validateAndResolve would
        // accept it, but the one-language policy stays authoritative and
        // rejects it (now that the enum spelling is visible to the gate at
        // all — before the fix this ALSO silently skipped).
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "game/plugins/scripting");
        try tmp.dir.createDirPath(io, "out");
        try writeFileIn(tmp.dir, "game/plugins/scripting/plugin.labelle",
            \\.{
            \\    .name = "scripting",
            \\    .manifest_version = 1,
            \\    .params_schema = .{
            \\        .{ .name = "language", .type = .@"enum", .values = .{ "klingon" } },
            \\    },
            \\}
        );
        const game_abs = try tmp.dir.realPathFileAlloc(io, "game", allocator);
        defer allocator.free(game_abs);
        const out_abs = try tmp.dir.realPathFileAlloc(io, "out", allocator);
        defer allocator.free(out_abs);

        const backend = try sokolFixtureAbs(allocator);
        defer allocator.free(backend.repo);

        const bag = [_]generate.plugin_params.Param{
            .{ .name = "language", .value = .{ .enum_tag = "klingon" } },
        };
        const plugins = [_]generate.PluginDep{
            .{ .name = "scripting", .repo = "local:plugins/scripting", .params_bag = &bag },
        };
        const cfg = generate.ProjectConfig{
            .name = "klingon-game",
            .backend = .sokol,
            .backend_package = backend,
            .ecs = .mock,
            .plugins = &plugins,
        };
        try std.testing.expectError(
            error.UnknownScriptLanguage,
            generate.generate(allocator, cfg, out_abs, game_abs, .{ .is_tests_target = true }),
        );
        try std.testing.expectError(
            error.FileNotFound,
            tmp.dir.access(io, "out/sokol_desktop", .{}),
        );
    }
};
