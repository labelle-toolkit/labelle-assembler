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

/// Splice fixture matching `scripting_splice_tests.lua_splice` (stems
/// pre-sorted, one nested subdir).
const lua_splice = generate.scripting_splice.ScriptingSplice{
    .plugin_name = "scripting",
    .language = "lua",
    .extension = ".lua",
    .script_names = &.{"hunger"},
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
        _ = try indexOfOrFail(main_zig, "scripting.registerScript(\"hunger\", @embedFile(\"lua/hunger.lua\"));");
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
/// `game/` with `plugins/scripting/plugin.labelle`, a `lua/` script, and
/// `out/`.
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
        try writeFileIn(game, "lua/hunger.lua",
            \\local Hunger = labelle.component("Hunger", { level = 1.0, starving = false })
            \\function update(dt) end
        );
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

    /// Stage an executable fake declare runner printing `schema_json` and
    /// point `declare_tool_override` at it (caller clears the override).
    /// A `#!/bin/sh` stub, not a Zig exe: building the REAL tool here
    /// would fetch lua from the network — the exact non-hermetic step the
    /// override seam exists to bypass (see scripting_declare.zig).
    fn stageFakeRunner(self: *StagedProject, allocator: std.mem.Allocator, schema_json: []const u8) ![:0]const u8 {
        const body = try std.fmt.allocPrint(allocator, "#!/bin/sh\necho '{s}'\n", .{schema_json});
        defer allocator.free(body);
        var f = try self.tmp.dir.createFile(io, "fake-declare", .{ .permissions = .executable_file });
        defer f.close(io);
        try f.writeStreamingAll(io, body);
        return self.tmp.dir.realPathFileAlloc(io, "fake-declare", allocator);
    }

    fn config(self: *StagedProject, backend_repo: []const u8) generate.ProjectConfig {
        _ = self;
        return .{
            .name = "declare-game",
            .backend = .sokol,
            .backend_package = .{ .name = "sokol", .repo = backend_repo },
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "lua" } },
            },
        };
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
        var f = try staged.tmp.dir.createFile(io, "fake-declare", .{ .permissions = .executable_file });
        try f.writeStreamingAll(io, "#!/bin/sh\necho '{\"components\":[]}'\n");
        f.close(io);
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
        // though lua/hunger.lua carries a labelle.component declaration.
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
        var f = try staged.tmp.dir.createFile(io, "fake-declare", .{ .permissions = .executable_file });
        try f.writeStreamingAll(io, "#!/bin/sh\necho 'labelle-declare: lua/hunger.lua:1: bad spec' >&2\nexit 1\n");
        f.close(io);
        const fake = try staged.tmp.dir.realPathFileAlloc(io, "fake-declare", allocator);
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
};
