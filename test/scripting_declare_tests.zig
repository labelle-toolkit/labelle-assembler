//! Script-declared components — emission + e2e tests (labelle-assembler#585,
//! RFC-LANGUAGE-PLUGINS revs 6-7, epic labelle-engine#237).
//!
//! The unit halves (schema parse, struct-file render golden + AstGen,
//! collision gate) live inline in `src/scripting_declare.zig`. These tests
//! close what only the production entry points can prove — extending the
//! #593 splice-test patterns (`test/scripting_splice_tests.zig`):
//!
//!   1. `generateMainZigFromTemplate` with `declared_components` threaded on
//!      the splice — the Components registry gains the
//!      `.Hunger = @import("scripting_components.zig").Hunger` field in the
//!      right position (after game/pack components, before the plugins
//!      tuple) and the whole main still passes AstGen; a splice WITHOUT
//!      declarations stays marker-free (the #593 goldens are the byte
//!      anchor — they run unchanged against this branch).
//!   2. The REAL `generate` runs the declare phase end to end via the
//!      `declare_tool_override` seam (a staged fake runner — the real
//!      tool's build needs a network lua fetch + a `zig` on PATH, which the
//!      suite must not depend on; the runner binary itself is pinned by
//!      labelle-scripting's own goldens): generated file written, stale
//!      file dropped on the no-declaration path, collisions fail generate,
//!      and a declaring run's build files carry no accidental new markers.
//!   3. The declared components' CROSS-PHASE consumers (PR #598 findings
//!      2+3): a script-declared `Tilemap` joins the built-in-override
//!      decision (the tilemap collection is ordered after the declare
//!      phase), and the exe-target manifest sidecar lists declared
//!      components in the game realm.

const std = @import("std");
const zspec = @import("zspec");
const generate = @import("generator");
const h = @import("helpers.zig");

const io = std.testing.io;

const engine_template = h.engine_template;
const empty_names = h.empty_names;
const empty_entries = h.empty_entries;
const empty_scene_manifests = h.empty_scene_manifests;
const empty_plugin_events = h.empty_plugin_events;
const empty_plugin_flow_nodes = h.empty_plugin_flow_nodes;
const empty_plugin_pin_styles = h.empty_plugin_pin_styles;
const empty_plugin_coercions = h.empty_plugin_coercions;

test {
    zspec.runAll(@This());
}

/// The ticket's pinned schema example — what the staged fake runner
/// prints and what the emission tests parse.
const hunger_schema =
    \\{"components":[{"name":"Hunger","persist":"persistent","fields":[{"name":"level","type":"f32","default":1.0},{"name":"starving","type":"bool","default":false}]}]}
;

/// Splice fixture matching `scripting_splice_tests.lua_splice` — the
/// scripts/ convention (#237).
const lua_splice = generate.scripting_splice.ScriptingSplice{
    .plugin_name = "scripting",
    .language = "lua",
    .dir = "scripts",
    .extension = ".lua",
    .scripts = &.{.{ .name = "hunger", .file = "scripts/hunger.lua" }},
};

const scripting_plugins = [_]generate.PluginDep{
    .{ .name = "scripting", .repo = "github:labelle-toolkit/labelle-scripting", .version = "0.1.0", .params = .{ .language = "lua" } },
    .{ .name = "pathfinding", .repo = "github:labelle-toolkit/labelle-pathfinding", .version = "4.0.1" },
};

fn indexOfOrFail(haystack: []const u8, needle: []const u8) !usize {
    return std.mem.indexOf(u8, haystack, needle) orelse {
        std.debug.print("expected to find:\n  {s}\nin generated output\n", .{needle});
        return error.MissingExpectedEmission;
    };
}

/// Find the realm object named `name` in a manifest `realms` array.
fn findJsonRealm(arr: std.json.Array, name: []const u8) ?std.json.ObjectMap {
    for (arr.items) |item| {
        const obj = item.object;
        if (std.mem.eql(u8, obj.get("name").?.string, name)) return obj;
    }
    return null;
}

/// Find the component object named `name` in a realm's `components` array.
fn findJsonComponent(arr: std.json.Array, name: []const u8) ?std.json.ObjectMap {
    for (arr.items) |item| {
        const obj = item.object;
        if (std.mem.eql(u8, obj.get("name").?.string, name)) return obj;
    }
    return null;
}

/// parse → AstGen gate (the `main_template.zig` fragment check; imports
/// stay unresolved so no engine checkout is needed).
fn expectAstGenOk(src: []const u8) !void {
    const src_z = try std.testing.allocator.dupeZ(u8, src);
    defer std.testing.allocator.free(src_z);
    var ast = try std.zig.Ast.parse(std.testing.allocator, src_z, .zig);
    defer ast.deinit(std.testing.allocator);
    if (ast.errors.len != 0) {
        std.debug.print("expectAstGenOk: {d} parse error(s)\n", .{ast.errors.len});
        return error.AstGenParseError;
    }
    var zir = try std.zig.AstGen.generate(std.testing.allocator, ast);
    defer zir.deinit(std.testing.allocator);
    if (zir.hasCompileErrors()) {
        std.debug.print("expectAstGenOk: AstGen reported compile errors\n", .{});
        return error.AstGenCompileError;
    }
}

/// The self-consistent loop-lifecycle fixture from the #593 tests (the
/// trimmed preview fixture lacks `{{hooks_init_block}}`, so a whole-main
/// AstGen check needs this one).
const loop_lifecycle =
    \\const screen_w: u32 = {{width}};
    \\const screen_h: u32 = {{height}};
    \\const screen_title = "{{title}}";
    \\const target_fps: u32 = {{fps}};
    \\{{module_vars}}pub fn main() !void {
    \\    var gpa = std.heap.DebugAllocator(.{}).init;
    \\    defer _ = gpa.deinit();
    \\    const allocator = gpa.allocator();
    \\{{hidden_setup}}{{hooks_init_block}}
    \\    var g = AssembledGame.init(allocator);
    \\    defer g.deinit();
    \\    g.setHooks(&hooks);
    \\    g.setScreenHeight(@as(f32, @floatFromInt(screen_h)));
    \\{{preview_setup}}{{setup_code}}
    \\    while (!window.shouldQuit()) {
    \\        const dt: f32 = 0.016;
    \\{{preview_heartbeat}}{{tick_code}}        g.tick(dt);
    \\        g.render();
    \\{{gui_draw_code}}    }
    \\}
    \\
;

pub const DECLARED_COMPONENT_REGISTRY_EMISSION = struct {
    test "declared components land in the Components registry — positioned, named, AstGen-clean" {
        var schema = try generate.scripting_declare.parseSchema(std.testing.allocator, hunger_schema);
        defer schema.deinit();

        var splice = lua_splice;
        splice.declared_components = schema.components;
        generate.main_template.scripting_splice = splice;
        defer generate.main_template.scripting_splice = null;

        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &scripting_plugins,
        }, loop_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // The registry field: declared name on both sides of the `=` —
        // scenes instantiate `"Hunger"` through exactly this field, and the
        // script contract's by-name dispatch resolves the same key.
        const registry = try indexOfOrFail(main_zig, "const Components = engine.ComponentRegistryWithPlugins(.{");
        const video = try indexOfOrFail(main_zig, "    .VideoComponent = engine.core.VideoComponent,");
        const hunger = try indexOfOrFail(main_zig, "    .Hunger = @import(\"scripting_components.zig\").Hunger,");
        const plugins_tuple = try indexOfOrFail(main_zig, "}, .{");
        try std.testing.expect(registry < video);
        try std.testing.expect(video < hunger);
        try std.testing.expect(hunger < plugins_tuple);

        // The #593 splice halves still ride along (registration + flag).
        _ = try indexOfOrFail(main_zig, "scripting.registerScript(\"hunger\", @embedFile(\"scripts/hunger.lua\"));");
        _ = try indexOfOrFail(main_zig, "const scripting_enabled = true;");

        try expectAstGenOk(main_zig);
    }

    test "a splice WITHOUT declarations emits no component markers (the #593 shape, byte-anchored)" {
        // `declared_components` defaults empty — this is the exact splice
        // every #593 test drives, so those goldens pin the bytes; here we
        // pin the absence of the new markers explicitly.
        generate.main_template.scripting_splice = lua_splice;
        defer generate.main_template.scripting_splice = null;

        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &scripting_plugins,
        }, loop_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "scripting_components.zig") == null);
    }
};

// ── e2e: the REAL generate, driven through the override seam ──────────

fn writeFileIn(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(io, sub);
    var f = try dir.createFile(io, rel, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

/// A staged tmp game project (the language-policy staging shape, plus a
/// MANIFEST-BEARING scripting plugin so `scripting_splice.detect` fires):
/// `game/` with `plugins/scripting/plugin.labelle`, a `scripts/*.lua`
/// script beside a Zig script (the #237 shared dir), and `out/`.
const StagedProject = struct {
    tmp: std.testing.TmpDir,
    game_abs: [:0]const u8,
    out_abs: [:0]const u8,

    fn init(allocator: std.mem.Allocator) !StagedProject {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "game/plugins/scripting");
        try tmp.dir.createDirPath(io, "out");
        var game = try tmp.dir.openDir(io, "game", .{});
        defer game.close(io);
        try writeFileIn(game, "plugins/scripting/plugin.labelle",
            \\.{ .name = "scripting", .manifest_version = 1 }
        );
        // The script whose chunk scope carries the declaration. Its content
        // is REAL but unread by the staged fake runner below — the runner
        // binary's own behavior is pinned by labelle-scripting's goldens.
        try writeFileIn(game, "scripts/hunger.lua",
            \\local Hunger = labelle.component("Hunger", { level = 1.0, starving = false })
            \\function update(dt) end
        );
        // A Zig script sharing scripts/ (#237 coexistence) — must never
        // reach the declare runner's argv (it collects only .lua files).
        try writeFileIn(game, "scripts/01_move.zig", "pub fn tick() void {}\n");
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

    /// Write an executable stub at `name` that prints `stdout_text`, writes
    /// `stderr_text` to stderr, and exits `code`. Returns its absolute path.
    ///
    /// A stub rather than the REAL tool because building that here would
    /// drag a lua/ruby toolchain into the test. It has to be a stub the HOST
    /// can execute, though, and a `#!/bin/sh` script is not that on Windows:
    /// there is no shebang, so `CreateProcess` fails with `error.InvalidExe`
    /// and the whole declare suite failed for a reason unrelated to what it
    /// tests (#699).
    ///
    /// Windows gets a `.cmd`, which Zig's spawn does run. The payload is
    /// `type`d out of a sidecar file rather than `echo`ed, because the
    /// schema is JSON and `cmd` mangles `"`, `<`, `>`, `&` and `|` — piping
    /// bytes through a file sidesteps batch quoting entirely.
    fn stageStub(
        self: *StagedProject,
        allocator: std.mem.Allocator,
        name: []const u8,
        stdout_text: []const u8,
        stderr_text: []const u8,
        code: u8,
        record_args: bool,
    ) ![:0]const u8 {
        const windows = @import("builtin").os.tag == .windows;
        const dir_abs = try self.tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(dir_abs);

        // Payload files, so neither shell has to quote the content.
        const out_name = try std.fmt.allocPrint(allocator, "{s}.out", .{name});
        defer allocator.free(out_name);
        try writeFileBytes(self.tmp.dir, out_name, stdout_text);
        const err_name = try std.fmt.allocPrint(allocator, "{s}.err", .{name});
        defer allocator.free(err_name);
        try writeFileBytes(self.tmp.dir, err_name, stderr_text);

        const script_name = if (windows)
            try std.fmt.allocPrint(allocator, "{s}.cmd", .{name})
        else
            try allocator.dupe(u8, name);
        defer allocator.free(script_name);

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);
        const w = body.writer(allocator);

        if (windows) {
            try w.writeAll("@echo off\r\n");
            if (record_args) {
                // Batch has no `printf "%s\n" "$@"`; walk argv with shift.
                try w.print("break > \"{s}\\recorded-args.txt\"\r\n", .{dir_abs});
                try w.writeAll(":labelle_loop\r\n");
                try w.writeAll("if \"%~1\"==\"\" goto labelle_done\r\n");
                try w.print("echo %~1>> \"{s}\\recorded-args.txt\"\r\n", .{dir_abs});
                try w.writeAll("shift\r\n");
                try w.writeAll("goto labelle_loop\r\n");
                try w.writeAll(":labelle_done\r\n");
            }
            if (stdout_text.len > 0) try w.print("type \"{s}\\{s}\"\r\n", .{ dir_abs, out_name });
            if (stderr_text.len > 0) try w.print("type \"{s}\\{s}\" 1>&2\r\n", .{ dir_abs, err_name });
            try w.print("exit /b {d}\r\n", .{code});
        } else {
            try w.writeAll("#!/bin/sh\n");
            if (record_args) {
                try w.print("printf '%s\\n' \"$@\" > \"{s}/recorded-args.txt\"\n", .{dir_abs});
            }
            if (stdout_text.len > 0) try w.print("cat \"{s}/{s}\"\n", .{ dir_abs, out_name });
            if (stderr_text.len > 0) try w.print("cat \"{s}/{s}\" 1>&2\n", .{ dir_abs, err_name });
            try w.print("exit {d}\n", .{code});
        }

        var f = try self.tmp.dir.createFile(io, script_name, .{ .permissions = .executable_file });
        defer f.close(io);
        try f.writeStreamingAll(io, body.items);

        return self.tmp.dir.realPathFileAlloc(io, script_name, allocator);
    }

    fn writeFileBytes(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
        var f = try dir.createFile(io, name, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
    }

    /// Prints `schema_json` and exits 0.
    fn stageFakeRunner(self: *StagedProject, allocator: std.mem.Allocator, schema_json: []const u8) ![:0]const u8 {
        return self.stageStub(allocator, "fake-declare", schema_json, "", 0, false);
    }

    /// The argv-RECORDING flavor: writes every script path it was invoked
    /// with (one per line) to `recorded-args.txt` beside the fixture, then
    /// prints the schema. Pins WHICH files reach the runner and in WHAT
    /// order — the components-first union contract.
    fn stageRecordingFakeRunner(self: *StagedProject, allocator: std.mem.Allocator, schema_json: []const u8) ![:0]const u8 {
        return self.stageStub(allocator, "fake-declare", schema_json, "", 0, true);
    }

    /// `language` is COMPTIME so the anonymous `.plugins` array literal is
    /// a static constant (the native suite's dangling-frame lesson).
    fn configWithLanguage(self: *StagedProject, backend_repo: []const u8, comptime language: []const u8) generate.ProjectConfig {
        _ = self;
        return .{
            .name = "declare-game",
            .backend = .sokol,
            .backend_package = .{ .name = "sokol", .repo = backend_repo },
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = language } },
            },
        };
    }

    fn config(self: *StagedProject, backend_repo: []const u8) generate.ProjectConfig {
        return self.configWithLanguage(backend_repo, "lua");
    }
};

/// The in-tree sokol backend fixture as an ABSOLUTE `local:` repo (staged
/// games live in tmp dirs, so the repo-relative spelling can't resolve).
fn sokolFixtureRepoAbs(allocator: std.mem.Allocator) ![]const u8 {
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, "backends/sokol", allocator);
    defer allocator.free(abs);
    return std.fmt.allocPrint(allocator, "local:{s}", .{abs});
}

pub const DECLARE_PHASE_E2E = struct {
    test "a declaring lua project generates scripting_components.zig (real generate, override runner)" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);

        const fake = try staged.stageFakeRunner(allocator, hunger_schema);
        defer allocator.free(fake);
        generate.scripting_declare.declare_tool_override = fake;
        defer generate.scripting_declare.declare_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = true });

        // The generated component file landed beside the build files and
        // carries the canonical struct shape (unit goldens pin the bytes;
        // here we pin placement + reachability).
        const gen_path = "out/sokol_desktop/scripting_components.zig";
        const gen_src = try staged.tmp.dir.readFileAlloc(io, gen_path, allocator, .limited(64 * 1024));
        defer allocator.free(gen_src);
        _ = try indexOfOrFail(gen_src, "pub const Hunger = struct {");
        _ = try indexOfOrFail(gen_src, "pub const save = @import(\"labelle-core\").Saveable(.saveable, @This(), .{});");
        _ = try indexOfOrFail(gen_src, "level: f32 = 1,");
        try expectAstGenOk(gen_src);
    }

    test "no declarations → no generated file, and a stale one is cleaned up (byte-identical no-op)" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);
        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);

        // Pass 1: a declaration exists → the file is generated.
        const fake_decl = try staged.stageFakeRunner(allocator, hunger_schema);
        defer allocator.free(fake_decl);
        generate.scripting_declare.declare_tool_override = fake_decl;
        defer generate.scripting_declare.declare_tool_override = null;
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = true });
        try staged.tmp.dir.access(io, "out/sokol_desktop/scripting_components.zig", .{});

        // Pass 2: the declarations were removed (empty schema) → the phase
        // is a no-op AND the stale generated file is deleted, so the
        // target matches a never-declared project.
        // Re-stage through the SAME helper so the override actually picks up
        // the new payload: on Windows it points at `fake-declare.cmd`, so
        // overwriting a bare `fake-declare` changed nothing (#699).
        const fake_empty = try staged.stageStub(allocator, "fake-declare", "{\"components\":[]}", "", 0, false);
        defer allocator.free(fake_empty);
        generate.scripting_declare.declare_tool_override = fake_empty;
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = true });
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop/scripting_components.zig", .{}),
        );

        // Belt: the build files carry no declare-phase markers either.
        const build_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1024 * 1024));
        defer allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "scripting_components") == null);
    }

    test "a scripting plugin without the declare tool skips the phase (old pin keeps generating)" {
        // NO declare_tool_override: the phase resolves the staged plugin
        // package for real. The fixture ships only plugin.labelle — like
        // labelle-scripting v0.1.0, no tools/declare — so the capability
        // probe must SKIP declaration rather than run `zig build
        // labelle-declare` into a hard failure (the exact break the
        // scripting-smoke example hit on CI: an assembler upgrade must
        // not fail projects holding an older scripting pin).
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);
        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);

        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = true });

        // Skipped means skipped: no generated component file, no registry
        // wiring — the target matches a never-declaring project even
        // though scripts/hunger.lua carries a labelle.component declaration.
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop/scripting_components.zig", .{}),
        );
        const build_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/build.zig", allocator, .limited(1024 * 1024));
        defer allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "scripting_components") == null);
    }

    test "a declared name colliding with a game component fails generate naming both providers" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);

        // The OTHER provider: a hand-written components/hunger.zig →
        // registry field `Hunger`, same as the declaration.
        var game = try staged.tmp.dir.openDir(io, "game", .{});
        defer game.close(io);
        try writeFileIn(game, "components/hunger.zig",
            \\pub const Hunger = struct {
            \\    pub const save = @import("labelle-core").Saveable(.saveable, @This(), .{});
            \\    level: f32 = 1.0,
            \\};
        );

        const fake = try staged.stageFakeRunner(allocator, hunger_schema);
        defer allocator.free(fake);
        generate.scripting_declare.declare_tool_override = fake;
        defer generate.scripting_declare.declare_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try std.testing.expectError(
            error.ScriptComponentCollision,
            generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = true }),
        );
    }

    test "a script-declared `Tilemap` overrides the built-in embed (declare runs BEFORE tilemap collection)" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);

        // A game-root prefab references the built-in `Tilemap` by asset_name,
        // but NO `assets/never_embedded.tmx` exists — if generate still tries
        // to embed it, tilemap collection fails (`TilemapAssetNotFound`). A
        // script-declared `Tilemap` must override the built-in (engine C2)
        // exactly like `components/Tilemap.zig`, which requires the declare
        // phase to have run BEFORE the tilemap phase decides (#598 finding 3
        // — pre-fix the collection ran first and this generate errored).
        var game = try staged.tmp.dir.openDir(io, "game", .{});
        defer game.close(io);
        try writeFileIn(game, "prefabs/room.jsonc",
            \\{ "components": { "Tilemap": { "asset_name": "never_embedded" } } }
        );

        const tilemap_schema =
            \\{"components":[{"name":"Tilemap","fields":[{"name":"asset_name","type":"str","default":""}]}]}
        ;
        const fake = try staged.stageFakeRunner(allocator, tilemap_schema);
        defer allocator.free(fake);
        generate.scripting_declare.declare_tool_override = fake;
        defer generate.scripting_declare.declare_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = true });

        // The declared component was generated (the override had a real
        // provider to defer to), and no embed was attempted for the prefab.
        const gen_src = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/scripting_components.zig", allocator, .limited(64 * 1024));
        defer allocator.free(gen_src);
        _ = try indexOfOrFail(gen_src, "pub const Tilemap = struct {");
    }

    test "the manifest sidecar lists a script-declared component in the game realm (exe target)" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);

        // The sidecar only emits on the EXE target, whose main.zig emission
        // needs an engine template — stage the unit-test fixture template as
        // a `local:` engine package inside the project so the full exe-path
        // generate runs hermetically.
        var game = try staged.tmp.dir.openDir(io, "game", .{});
        defer game.close(io);
        try writeFileIn(game, "engine-fixture/codegen/main.zig.template", engine_template);

        const fake = try staged.stageFakeRunner(allocator, hunger_schema);
        defer allocator.free(fake);
        generate.scripting_declare.declare_tool_override = fake;
        defer generate.scripting_declare.declare_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        var cfg = staged.config(backend_repo);
        cfg.engine_version = "local:engine-fixture";
        // The exe target emits main.zig, which requires the project's
        // declared y-axis convention (RFC-Y-AXIS-CONVENTION build guard).
        cfg.y_axis = .up;
        try generate.generate(allocator, cfg, staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        // manifest.json is project-level: `<game>/.labelle/manifest.json`.
        const bytes = try staged.tmp.dir.readFileAlloc(io, "game/.labelle/manifest.json", allocator, .limited(1 << 20));
        defer allocator.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        const root = parsed.value.object;

        // Detail realm: the declared component rides the game realm with the
        // codegen-exact save policy + field types (#598 finding 2 — pre-fix
        // the sidecar carried only `components/*.zig` scans and script
        // declarations were invisible to consumers).
        const realms = root.get("realms").?.array;
        const game_realm = findJsonRealm(realms, "game") orelse return error.MissingGameRealm;
        const comps = game_realm.get("components").?.array;
        const hunger = findJsonComponent(comps, "Hunger") orelse return error.MissingDeclaredComponent;
        try std.testing.expectEqualStrings("saveable", hunger.get("save").?.string);
        const fields = hunger.get("fields").?.object;
        try std.testing.expectEqualStrings("f32", fields.get("level").?.string);
        try std.testing.expectEqualStrings("bool", fields.get("starving").?.string);

        // Index realm: `owns.components` names it too.
        const realms_idx = root.get("index").?.object.get("realms").?.array;
        const game_idx = findJsonRealm(realms_idx, "game") orelse return error.MissingGameRealm;
        const owned = game_idx.get("owns").?.object.get("components").?.array;
        var found = false;
        for (owned.items) |item| {
            if (std.mem.eql(u8, item.string, "Hunger")) found = true;
        }
        try std.testing.expect(found);
    }

    test "a runner failure (malformed declaration) fails generate with the tool's exit relayed" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);

        // A fake runner that fails like the real one does on a malformed
        // spec: file-and-name-bearing message on stderr, exit 1.
        const fake = try staged.stageStub(allocator, "fake-declare", "", "labelle-declare: scripts/hunger.lua:1: bad spec\n", 1, false);
        defer allocator.free(fake);
        generate.scripting_declare.declare_tool_override = fake;
        defer generate.scripting_declare.declare_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try std.testing.expectError(
            error.ScriptDeclarationFailed,
            generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = true }),
        );
    }

    test "collection union: components/*.lua + in-script chunk-scope declarations BOTH reach the runner — components first (argv pin)" {
        // The #237 refinement's collection contract: `components/extra.lua`
        // (the canonical home) and `scripts/hunger.lua` (the shipped
        // in-script mechanism, still legal) feed ONE runner invocation, in
        // components-first order — the runner owns duplicate detection
        // with first-declared-in attribution across the two sources; the
        // assembler's half is exactly this argv.
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);
        var game = try staged.tmp.dir.openDir(io, "game", .{});
        defer game.close(io);
        try writeFileIn(game, "components/extra.lua",
            \\local Extra = labelle.component("Extra", { n = 1 })
        );
        // A Zig component beside it — invisible to the collection.
        try writeFileIn(game, "components/worker.zig", "pub const Worker = struct { id: u32 = 0 };\n");

        const fake = try staged.stageRecordingFakeRunner(allocator, hunger_schema);
        defer allocator.free(fake);
        generate.scripting_declare.declare_tool_override = fake;
        defer generate.scripting_declare.declare_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = true });

        const args = try staged.tmp.dir.readFileAlloc(io, "recorded-args.txt", allocator, .limited(1 << 16));
        defer allocator.free(args);
        // Both sources present, components/ first, the Zig files absent.
        const comp_arg = std.mem.indexOf(u8, args, "components/extra.lua") orelse return error.MissingComponentsArg;
        const script_arg = std.mem.indexOf(u8, args, "scripts/hunger.lua") orelse return error.MissingScriptArg;
        try std.testing.expect(comp_arg < script_arg);
        // The coexisting ZIG files never reach the runner (the argv paths
        // themselves live under .zig-cache/, so pin the FILENAMES).
        try std.testing.expect(std.mem.indexOf(u8, args, "worker.zig") == null);
        try std.testing.expect(std.mem.indexOf(u8, args, "01_move.zig") == null);
        // And the phase consumed the schema as usual.
        try staged.tmp.dir.access(io, "out/sokol_desktop/scripting_components.zig", .{});
    }

    test "RUBY declare e2e: components/hunger.rb declares through tools/declare-ruby — generated file, registry, registered BEFORE scripts" {
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);
        var game = try staged.tmp.dir.openDir(io, "game", .{});
        defer game.close(io);
        // Re-shape the staged game for ruby: the lua sources out, the
        // canonical ruby pair in — a components/ declaration and a plain
        // behavior script (feed_watcher-style).
        try game.deleteFile(io, "scripts/hunger.lua");
        try writeFileIn(game, "components/hunger.rb",
            \\Hunger = Labelle.component "Hunger", level: 0.875, starving: false
        );
        try writeFileIn(game, "scripts/feed.rb",
            \\def update(dt)
            \\end
        );
        // The per-row capability marker (labelle-scripting >= 0.9.0 ships
        // tools/declare-ruby): with it present, the override below is what
        // keeps the REAL `zig build labelle-declare-ruby` from running in
        // this build.zig-less fixture — the probe itself is exercised for
        // real by its absence twin below.
        try writeFileIn(game, "plugins/scripting/tools/declare-ruby/main.zig", "// ruby declare runner (fixture marker)\n");
        // The exe target emits main.zig (the registration-order surface) —
        // stage the engine template fixture (the sidecar test's pattern).
        try writeFileIn(game, "engine-fixture/codegen/main.zig.template", engine_template);

        const fake = try staged.stageRecordingFakeRunner(allocator, hunger_schema);
        defer allocator.free(fake);
        generate.scripting_declare.declare_tool_override = fake;
        defer generate.scripting_declare.declare_tool_override = null;

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        var cfg = staged.configWithLanguage(backend_repo, "ruby");
        cfg.engine_version = "local:engine-fixture";
        cfg.y_axis = .up;
        try generate.generate(allocator, cfg, staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        // The declaration reached the runner (components-first argv) and
        // codegen'd the component like the lua path does.
        const args = try staged.tmp.dir.readFileAlloc(io, "recorded-args.txt", allocator, .limited(1 << 16));
        defer allocator.free(args);
        const comp_arg = std.mem.indexOf(u8, args, "components/hunger.rb") orelse return error.MissingComponentsArg;
        const script_arg = std.mem.indexOf(u8, args, "scripts/feed.rb") orelse return error.MissingScriptArg;
        try std.testing.expect(comp_arg < script_arg);

        const gen_src = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/scripting_components.zig", allocator, .limited(64 * 1024));
        defer allocator.free(gen_src);
        _ = try indexOfOrFail(gen_src, "pub const Hunger = struct {");
        // The staged fake prints `hunger_schema` (level 1.0) — the REAL
        // ruby runner's 0.875 parity is the scripting repo's golden.
        _ = try indexOfOrFail(gen_src, "level: f32 = 1,");

        // The generated main: registry field + THE RUNTIME ORDERING PIN —
        // the components/ declaration registers BEFORE the script, so the
        // view constant exists when the script loads (ruby constants are
        // VM-global; per-script isolation deliberately scopes hooks, not
        // constants).
        const main_zig = try staged.tmp.dir.readFileAlloc(io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        _ = try indexOfOrFail(main_zig, ".Hunger = @import(\"scripting_components.zig\").Hunger,");
        const reg_comp = try indexOfOrFail(main_zig, "scripting.registerScript(\"hunger\", @embedFile(\"components/hunger.rb\"));");
        const reg_script = try indexOfOrFail(main_zig, "scripting.registerScript(\"feed\", @embedFile(\"scripts/feed.rb\"));");
        const controllers_setup = try indexOfOrFail(main_zig, "PluginControllers.setup(&g)");
        try std.testing.expect(reg_comp < reg_script);
        try std.testing.expect(reg_script < controllers_setup);
    }

    test "RUBY old-pin path: a scripting pin WITHOUT tools/declare-ruby skips declare gracefully — scripts still register" {
        // The generalization of the lua "no tools/declare skips" pin: the
        // capability probe is PER ROW, so a v0.3.0-era ruby pin (embed
        // support, no declare runner) keeps generating — components/*.rb
        // still embed + register (the runtime consumes the declaration),
        // nothing codegens. NO override: the probe runs for real.
        const allocator = std.testing.allocator;
        var staged = try StagedProject.init(allocator);
        defer staged.deinit(allocator);
        var game = try staged.tmp.dir.openDir(io, "game", .{});
        defer game.close(io);
        try game.deleteFile(io, "scripts/hunger.lua");
        try writeFileIn(game, "components/hunger.rb",
            \\Hunger = Labelle.component "Hunger", level: 0.875, starving: false
        );
        try writeFileIn(game, "scripts/feed.rb",
            \\def update(dt)
            \\end
        );
        // Deliberately NO tools/declare-ruby in the plugin fixture.

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.configWithLanguage(backend_repo, "ruby"), staged.out_abs, staged.game_abs, .{ .is_tests_target = true });

        // Skipped means skipped: no generated component file...
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(io, "out/sokol_desktop/scripting_components.zig", .{}),
        );
        // ...and the embeds still landed in the target through the links
        // (the tests target emits no main.zig; the link resolution is the
        // load-bearing half here).
        try staged.tmp.dir.access(io, "out/sokol_desktop/components/hunger.rb", .{});
        try staged.tmp.dir.access(io, "out/sokol_desktop/scripts/feed.rb", .{});
    }
};
