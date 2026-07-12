//! Scripting codegen splice — emission tests (labelle-assembler#593, epic
//! labelle-engine#237).
//!
//! The detection unit tests live inline in `src/scripting_splice.zig`
//! (manifest-name match, `.params.language` parse reuse, embed-extension
//! table). These tests cover the EMISSION sites through the production
//! codegen entry points:
//!
//!   1. `generateMainZigFromTemplate` with `main_template.scripting_splice`
//!      set (the scoped threadlocal root.zig threads) — registration calls
//!      present + collection-ordered + before `PluginControllers.setup`,
//!      embed paths rooted at the `scripts/` convention dir (#237; the
//!      deprecated legacy dir on the grace fallback), ordering-prefix
//!      stems stripped, the module-scope `scripting` alias +
//!      `scripting_enabled` flag (the generated half of the backend
//!      templates' double-`@hasDecl` gate), and the per-frame
//!      `script_contract.drainEvents` tap between the plugin ticks and
//!      `g.dispatchEvents()` — on BOTH the loop and callback lifecycles.
//!   2. `generateBuildZig` with `BuildZigOptions.scripting` set — the
//!      scripting plugin's `b.dependency` args gain `.language = .<lang>`
//!      (the plugin's `-Dlanguage` option); sibling plugins stay untouched.
//!   3. The splice-less shapes stay marker-free — the byte-identity half is
//!      locked by the existing goldens (`sokol_desktop_v2_plugins.build.zig`,
//!      `acme_callback_main.zig`, the manifest-v2 anchors), which this
//!      change must not shift; these tests only add the explicit
//!      no-markers regression.

const std = @import("std");
const zspec = @import("zspec");
const generate = @import("generator");
const h = @import("helpers.zig");

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

/// The splice fixture root.zig would thread for a two-script lua project
/// on the `scripts/` convention (labelle-engine#237): entries pre-ordered
/// by the collection (numeric prefixes first, stripped from the registered
/// stem — `01_guard.lua` registers as "guard").
const lua_splice = generate.scripting_splice.ScriptingSplice{
    .plugin_name = "scripting",
    .language = "lua",
    .dir = "scripts",
    .extension = ".lua",
    .scripts = &.{
        .{ .name = "guard", .file = "01_guard.lua" },
        .{ .name = "player_ai", .file = "player_ai.lua" },
    },
};

/// The one-release grace twin: detect resolved the DEPRECATED lua/ dir —
/// pre-#237 semantics verbatim (recursive scan, plain sorted stems, no
/// prefix stripping, nested subdir joined with `/`).
const lua_legacy_splice = generate.scripting_splice.ScriptingSplice{
    .plugin_name = "scripting",
    .language = "lua",
    .dir = "lua",
    .legacy = true,
    .extension = ".lua",
    .scripts = &.{
        .{ .name = "ai/guard", .file = "ai/guard.lua" },
        .{ .name = "player_ai", .file = "player_ai.lua" },
    },
};

/// The typescript twin (labelle-scripting v0.3.0, quickjs-ng): same
/// scripts/ home as every language now (`ts/` is only the legacy grace
/// dir), embedding PLAIN `.js` (the TS→JS transpile hook is the #586 gap).
const ts_splice = generate.scripting_splice.ScriptingSplice{
    .plugin_name = "scripting",
    .language = "typescript",
    .dir = "scripts",
    .extension = ".js",
    .scripts = &.{
        .{ .name = "behavior", .file = "behavior.js" },
        .{ .name = "guard", .file = "guard.js" },
    },
};

/// The ruby twin (labelle-scripting v0.3.0, mruby 3.4.0), carrying the
/// ticket's ordering example: `10_spawner.rb` before `20_hunger.rb`, stems
/// "spawner"/"hunger" — prefix ordering + stripping ride the emission.
const ruby_splice = generate.scripting_splice.ScriptingSplice{
    .plugin_name = "scripting",
    .language = "ruby",
    .dir = "scripts",
    .extension = ".rb",
    .scripts = &.{
        .{ .name = "spawner", .file = "10_spawner.rb" },
        .{ .name = "hunger", .file = "20_hunger.rb" },
    },
};

/// A project.labelle plugin list carrying THE scripting plugin plus an
/// ordinary sibling — the sibling proves the splice never leaks onto other
/// plugins' wiring.
const scripting_plugins = [_]generate.PluginDep{
    .{ .name = "scripting", .repo = "github:labelle-toolkit/labelle-scripting", .version = "0.1.0", .params = .{ .language = "lua" } },
    .{ .name = "pathfinding", .repo = "github:labelle-toolkit/labelle-pathfinding", .version = "4.0.1" },
};

/// The typescript spelling of the same list.
const ts_scripting_plugins = [_]generate.PluginDep{
    .{ .name = "scripting", .repo = "github:labelle-toolkit/labelle-scripting", .version = "0.3.0", .params = .{ .language = "typescript" } },
    .{ .name = "pathfinding", .repo = "github:labelle-toolkit/labelle-pathfinding", .version = "4.0.1" },
};

/// The ruby spelling of the same list.
const ruby_scripting_plugins = [_]generate.PluginDep{
    .{ .name = "scripting", .repo = "github:labelle-toolkit/labelle-scripting", .version = "0.4.0", .params = .{ .language = "ruby" } },
    .{ .name = "pathfinding", .repo = "github:labelle-toolkit/labelle-pathfinding", .version = "4.0.1" },
};

/// Index of `needle` in `haystack`, failing the test with a readable message
/// when absent — every ordering assertion below builds on this.
fn indexOfOrFail(haystack: []const u8, needle: []const u8) !usize {
    return std.mem.indexOf(u8, haystack, needle) orelse {
        std.debug.print("expected to find:\n  {s}\nin generated output\n", .{needle});
        return error.MissingExpectedEmission;
    };
}

/// Run Zig's front-end (parse → AstGen) over `src` and fail on any parse or
/// AstGen-level compile error — the same gate `src/codegen/main_template.zig`
/// uses for its emitted fragments (it does NOT resolve `@import`s, so the
/// whole generated main checks without the engine present).
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

/// A loop-lifecycle fixture mirroring the bgfx desktop template's hole set
/// (`{{module_vars}}` + `{{hooks_init_block}}` + `{{setup_code}}` +
/// `{{tick_code}}`) — the shape the splice's demo backend consumes. The
/// trimmed `h.raylib_desktop_preview_lifecycle` fixture lacks
/// `{{hooks_init_block}}` (its `&hooks` reference is undeclared), so a
/// whole-main AstGen check needs this self-consistent one.
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

pub const SCRIPTING_MAIN_SPLICE = struct {
    test "loop lifecycle: registrations ordered + before plugin setup, alias/flag emitted, drain between tick and dispatch" {
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

        // Module-scope decls (via {{module_vars}}): the plugin alias the
        // registrations call through + the flag backend templates gate their
        // `script_contract.bind` touchpoint on.
        _ = try indexOfOrFail(main_zig, "const scripting = @import(\"scripting\");");
        _ = try indexOfOrFail(main_zig, "const scripting_enabled = true;");

        // Registrations: collection-ordered entries, `scripts/`-rooted
        // embed paths (the FILE keeps its ordering prefix, the registered
        // stem drops it), and strictly BEFORE PluginControllers.setup
        // boots the VM.
        const reg_guard = try indexOfOrFail(main_zig, "scripting.registerScript(\"guard\", @embedFile(\"scripts/01_guard.lua\"));");
        const reg_player = try indexOfOrFail(main_zig, "scripting.registerScript(\"player_ai\", @embedFile(\"scripts/player_ai.lua\"));");
        const controllers_setup = try indexOfOrFail(main_zig, "PluginControllers.setup(&g)");
        try std.testing.expect(reg_guard < reg_player);
        try std.testing.expect(reg_player < controllers_setup);

        // VM tick: the scripting plugin's `Controller.tick` (inbox dispatch
        // + script `update(dt)`s) — spliced INSIDE the scaled_dt gate, after
        // the plugin systems. Nothing generic dispatches it (the plugin
        // ships no `Systems`; PluginControllers wires only setup/deinit), so
        // its absence would silently freeze every language script after
        // init.
        const plugin_tick = try indexOfOrFail(main_zig, "PluginSystems.postTick(&g, scaled_dt);");
        const vm_tick = try indexOfOrFail(main_zig, "scripting.Controller.tick(&g, scaled_dt);");
        try std.testing.expect(plugin_tick < vm_tick);

        // Drain tap: AFTER the plugin ticks (VM tick included — the scripts
        // have emitted), BEFORE g.dispatchEvents() — the engine contract's
        // load-bearing ordering — and engine-gated so pre-contract engines
        // still build.
        const drain = try indexOfOrFail(main_zig, "if (comptime @hasDecl(engine, \"script_contract\")) {");
        const drain_call = try indexOfOrFail(main_zig, "engine.script_contract.drainEvents(&g);");
        const dispatch = try indexOfOrFail(main_zig, "g.dispatchEvents();");
        try std.testing.expect(vm_tick < drain);
        try std.testing.expect(drain < drain_call);
        try std.testing.expect(drain_call < dispatch);

        // Controller teardown is arity-dispatched (labelle-assembler#593):
        // labelle-scripting's module-singleton `deinit()` takes no game.
        _ = try indexOfOrFail(main_zig, "if (comptime @typeInfo(@TypeOf(C.deinit)).@\"fn\".params.len == 0) C.deinit() else C.deinit(game);");

        // The whole generated main still passes Zig's front-end (parse +
        // AstGen — imports unresolved, so no engine checkout needed).
        try expectAstGenOk(main_zig);
    }

    test "callback lifecycle (bgfx-android shape): registrations + drain ride the same builders" {
        h.setBgfxAndroidLifecycle();
        defer h.clearLifecycleOverrides();
        generate.main_template.scripting_splice = lua_splice;
        defer generate.main_template.scripting_splice = null;

        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .bgfx,
            .platform = .android,
            .ecs = .mock,
            .plugins = &scripting_plugins,
        }, h.bgfx_android_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        _ = try indexOfOrFail(main_zig, "const scripting = @import(\"scripting\");");
        _ = try indexOfOrFail(main_zig, "const scripting_enabled = true;");

        const reg_guard = try indexOfOrFail(main_zig, "scripting.registerScript(\"guard\", @embedFile(\"scripts/01_guard.lua\"));");
        const reg_player = try indexOfOrFail(main_zig, "scripting.registerScript(\"player_ai\", @embedFile(\"scripts/player_ai.lua\"));");
        const controllers_setup = try indexOfOrFail(main_zig, "PluginControllers.setup(&g)");
        try std.testing.expect(reg_guard < reg_player);
        try std.testing.expect(reg_player < controllers_setup);

        const vm_tick = try indexOfOrFail(main_zig, "scripting.Controller.tick(&g, scaled_dt);");
        const drain_call = try indexOfOrFail(main_zig, "engine.script_contract.drainEvents(&g);");
        const dispatch = try indexOfOrFail(main_zig, "g.dispatchEvents();");
        try std.testing.expect(vm_tick < drain_call);
        try std.testing.expect(drain_call < dispatch);

        try expectAstGenOk(main_zig);
    }

    test "typescript loop lifecycle: scripts/-rooted .js embeds ride the same builders (never typescript/, never .ts)" {
        generate.main_template.scripting_splice = ts_splice;
        defer generate.main_template.scripting_splice = null;

        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &ts_scripting_plugins,
        }, loop_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        _ = try indexOfOrFail(main_zig, "const scripting = @import(\"scripting\");");
        _ = try indexOfOrFail(main_zig, "const scripting_enabled = true;");

        // Embed paths root at the shared `scripts/` convention dir with
        // the `.js` runtime extension; collection-ordered; strictly before
        // PluginControllers.setup.
        const reg_behavior = try indexOfOrFail(main_zig, "scripting.registerScript(\"behavior\", @embedFile(\"scripts/behavior.js\"));");
        const reg_guard = try indexOfOrFail(main_zig, "scripting.registerScript(\"guard\", @embedFile(\"scripts/guard.js\"));");
        const controllers_setup = try indexOfOrFail(main_zig, "PluginControllers.setup(&g)");
        try std.testing.expect(reg_behavior < reg_guard);
        try std.testing.expect(reg_guard < controllers_setup);

        // The language-keyed halves are untouched: VM tick + drain tap.
        _ = try indexOfOrFail(main_zig, "scripting.Controller.tick(&g, scaled_dt);");
        _ = try indexOfOrFail(main_zig, "engine.script_contract.drainEvents(&g);");

        // No `typescript/`- or `ts/`-rooted, no `.ts` embed anywhere.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"typescript/") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"ts/") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".ts\")") == null);

        try expectAstGenOk(main_zig);
    }

    test "ruby loop lifecycle: the ordering-prefix pin — 10_spawner before 20_hunger, stems stripped (scripts/ convention)" {
        generate.main_template.scripting_splice = ruby_splice;
        defer generate.main_template.scripting_splice = null;

        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &ruby_scripting_plugins,
        }, loop_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        _ = try indexOfOrFail(main_zig, "const scripting = @import(\"scripting\");");
        _ = try indexOfOrFail(main_zig, "const scripting_enabled = true;");

        // The ticket's exact wording: scripts/10_spawner.rb registers
        // BEFORE scripts/20_hunger.rb, with stems "spawner"/"hunger" —
        // the prefix orders and is stripped from the name, never from the
        // embed path.
        const reg_spawner = try indexOfOrFail(main_zig, "scripting.registerScript(\"spawner\", @embedFile(\"scripts/10_spawner.rb\"));");
        const reg_hunger = try indexOfOrFail(main_zig, "scripting.registerScript(\"hunger\", @embedFile(\"scripts/20_hunger.rb\"));");
        const controllers_setup = try indexOfOrFail(main_zig, "PluginControllers.setup(&g)");
        try std.testing.expect(reg_spawner < reg_hunger);
        try std.testing.expect(reg_hunger < controllers_setup);

        // The language-keyed halves are untouched: VM tick + drain tap.
        _ = try indexOfOrFail(main_zig, "scripting.Controller.tick(&g, scaled_dt);");
        _ = try indexOfOrFail(main_zig, "engine.script_contract.drainEvents(&g);");

        try expectAstGenOk(main_zig);
    }

    test "LEGACY lua/ splice (one release of grace): pre-#237 emission verbatim — lua/-rooted paths, plain stems" {
        generate.main_template.scripting_splice = lua_legacy_splice;
        defer generate.main_template.scripting_splice = null;

        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &scripting_plugins,
        }, loop_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Byte-identical to the pre-migration emission: nested stems keep
        // their `/`-joined names, nothing is prefix-stripped, and the
        // embed paths root at the deprecated dir.
        const reg_guard = try indexOfOrFail(main_zig, "scripting.registerScript(\"ai/guard\", @embedFile(\"lua/ai/guard.lua\"));");
        const reg_player = try indexOfOrFail(main_zig, "scripting.registerScript(\"player_ai\", @embedFile(\"lua/player_ai.lua\"));");
        try std.testing.expect(reg_guard < reg_player);

        try expectAstGenOk(main_zig);
    }

    test "an EMPTY script set still wires the plugin: alias + flag + drain, but no registerScript" {
        // Empty scripts/ (or none): the plugin is attached and the VM
        // boots, so the flag/alias/drain must be present — only the
        // registration block is elided.
        var empty_scripts = lua_splice;
        empty_scripts.scripts = &.{};
        generate.main_template.scripting_splice = empty_scripts;
        defer generate.main_template.scripting_splice = null;

        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &scripting_plugins,
        }, loop_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        _ = try indexOfOrFail(main_zig, "const scripting_enabled = true;");
        _ = try indexOfOrFail(main_zig, "scripting.Controller.tick(&g, scaled_dt);");
        _ = try indexOfOrFail(main_zig, "engine.script_contract.drainEvents(&g);");
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript") == null);
    }

    test "no splice → no scripting markers anywhere (plugins-bearing project stays clean)" {
        // The byte-identity guarantee is locked by the untouched goldens;
        // this is the explicit no-markers regression for a plugins-bearing
        // main generated WITHOUT the splice (the threadlocal at its null
        // default, as every pre-#593 call site leaves it).
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &scripting_plugins,
        }, loop_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "scripting_enabled") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "script_contract") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "Controller.tick") == null);
    }
};

pub const SCRIPTING_BUILD_WIRING = struct {
    test "the scripting plugin's b.dependency gains .language; siblings stay untouched" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &scripting_plugins,
        }, .{
            .scripting = .{ .plugin_name = "scripting", .language = "lua" },
        });
        defer std.testing.allocator.free(build_zig);

        _ = try indexOfOrFail(build_zig, "const plugin_scripting_dep = b.dependency(\"labelle_scripting\", .{ .target = target, .optimize = optimize, .language = .lua });");
        _ = try indexOfOrFail(build_zig, "const plugin_pathfinding_dep = b.dependency(\"labelle_pathfinding\", .{ .target = target, .optimize = optimize });");
    }

    test "a typescript declaration passes .language = .typescript to the scripting dep" {
        // The plugin's `-Dlanguage` option (labelle-scripting v0.3.0:
        // lua|ruby|typescript) selects the quickjs-ng sub-module.
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &ts_scripting_plugins,
        }, .{
            .scripting = .{ .plugin_name = "scripting", .language = "typescript" },
        });
        defer std.testing.allocator.free(build_zig);

        _ = try indexOfOrFail(build_zig, "const plugin_scripting_dep = b.dependency(\"labelle_scripting\", .{ .target = target, .optimize = optimize, .language = .typescript });");
        _ = try indexOfOrFail(build_zig, "const plugin_pathfinding_dep = b.dependency(\"labelle_pathfinding\", .{ .target = target, .optimize = optimize });");
    }

    test "a ruby declaration passes .language = .ruby to the scripting dep" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &ruby_scripting_plugins,
        }, .{
            .scripting = .{ .plugin_name = "scripting", .language = "ruby" },
        });
        defer std.testing.allocator.free(build_zig);

        _ = try indexOfOrFail(build_zig, "const plugin_scripting_dep = b.dependency(\"labelle_scripting\", .{ .target = target, .optimize = optimize, .language = .ruby });");
        _ = try indexOfOrFail(build_zig, "const plugin_pathfinding_dep = b.dependency(\"labelle_pathfinding\", .{ .target = target, .optimize = optimize });");
    }

    test "no BuildZigOptions.scripting → no .language arg on any plugin dep" {
        // The default-null path — the byte anchor for this cell is the
        // committed `sokol_desktop_v2_plugins.build.zig` golden (which this
        // change must not shift); assert the marker's absence here so the
        // regression reads next to its positive twin.
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &scripting_plugins,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, ".language") == null);
    }
};

// ── typescript e2e: the REAL generate over a staged project ───────────
//
// The declare-phase e2e harness shape (`test/scripting_declare_tests.zig`
// StagedProject), typescript-flavored. Hermetic on the HAPPY path: the
// lua-only declare gate returns before any tool build, so no `zig` child
// process and no network — which is itself the pin: the staged plugin
// fixture SHIPS a `tools/declare/` dir (the capability probe would pass),
// so if the language gate were removed, generate would charge into
// `zig build labelle-declare` inside a build.zig-less fixture and fail —
// exactly the negative this test exists to catch.

const e2e_io = std.testing.io;

fn writeFileIn(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(e2e_io, sub);
    var f = try dir.createFile(e2e_io, rel, .{});
    defer f.close(e2e_io);
    try f.writeStreamingAll(e2e_io, body);
}

/// A staged tmp typescript game project: `game/` with a manifest-bearing
/// scripting plugin (plus its declare-tool marker), a `scripts/` dir
/// holding a runnable `.js` script AND the copied `labelle.d.ts` authoring
/// companion (the documented `// @ts-check` workflow — pinning that
/// declaration files never trip the transpile gate) beside a Zig script
/// (the #237 coexistence), the engine template fixture (exe main.zig
/// emission), and `out/`.
const StagedTsProject = struct {
    tmp: std.testing.TmpDir,
    game_abs: [:0]const u8,
    out_abs: [:0]const u8,

    fn init(allocator: std.mem.Allocator) !StagedTsProject {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(e2e_io, "out");
        try tmp.dir.createDirPath(e2e_io, "game");
        var game_root = try tmp.dir.openDir(e2e_io, "game", .{});
        defer game_root.close(e2e_io);
        try writeFileIn(game_root, "plugins/scripting/plugin.labelle",
            \\.{ .name = "scripting", .manifest_version = 1 }
        );
        // The declare-tool capability marker (labelle-scripting >= 0.2.0
        // ships tools/declare): with it present, ONLY the lua-only
        // language gate keeps the phase from building the runner here.
        try writeFileIn(game_root, "plugins/scripting/tools/declare/declare.lua", "-- lua declare runner (fixture marker)\n");
        try writeFileIn(game_root, "scripts/behavior.js",
            \\// @ts-check
            \\export function update(dt) {}
        );
        try writeFileIn(game_root, "scripts/labelle.d.ts", "declare const labelle: any;\n");
        // A Zig script sharing the dir — the ZIG scanner's file, invisible
        // to the language collection (extension-keyed coexistence).
        try writeFileIn(game_root, "scripts/01_move.zig", "pub fn tick() void {}\n");
        // Exe main.zig emission loads the engine's codegen template — the
        // unit-test fixture template staged as a `local:` engine package.
        try writeFileIn(game_root, "engine-fixture/codegen/main.zig.template", engine_template);
        const game_abs = try tmp.dir.realPathFileAlloc(e2e_io, "game", allocator);
        errdefer allocator.free(game_abs);
        const out_abs = try tmp.dir.realPathFileAlloc(e2e_io, "out", allocator);
        return .{ .tmp = tmp, .game_abs = game_abs, .out_abs = out_abs };
    }

    fn deinit(self: *StagedTsProject, allocator: std.mem.Allocator) void {
        allocator.free(self.game_abs);
        allocator.free(self.out_abs);
        self.tmp.cleanup();
    }

    fn config(self: *StagedTsProject, backend_repo: []const u8) generate.ProjectConfig {
        _ = self;
        return .{
            .name = "ts-game",
            .backend = .sokol,
            .backend_package = .{ .name = "sokol", .repo = backend_repo },
            .ecs = .mock,
            .engine_version = "local:engine-fixture",
            .y_axis = .up,
            .plugins = &.{
                .{ .name = "scripting", .repo = "local:plugins/scripting", .params = .{ .language = "typescript" } },
            },
        };
    }
};

/// The in-tree sokol backend fixture as an ABSOLUTE `local:` repo (staged
/// games live in tmp dirs, so the repo-relative spelling can't resolve).
fn sokolFixtureRepoAbs(allocator: std.mem.Allocator) ![]const u8 {
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(e2e_io, "backends/sokol", allocator);
    defer allocator.free(abs);
    return std.fmt.allocPrint(allocator, "local:{s}", .{abs});
}

pub const TYPESCRIPT_SPLICE_E2E = struct {
    test "a scripts/behavior.js project generates end to end: scripts/-rooted embed, .typescript dep language, declare skipped" {
        const allocator = std.testing.allocator;
        var staged = try StagedTsProject.init(allocator);
        defer staged.deinit(allocator);

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        // Generated main: the registration embeds the linked scripts/
        // source (the SAME link the Zig scanner uses must resolve the
        // embed path), plus the module-scope alias + backend-gate flag.
        const main_zig = try staged.tmp.dir.readFileAlloc(e2e_io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        _ = try indexOfOrFail(main_zig, "scripting.registerScript(\"behavior\", @embedFile(\"scripts/behavior.js\"));");
        _ = try indexOfOrFail(main_zig, "const scripting = @import(\"scripting\");");
        _ = try indexOfOrFail(main_zig, "const scripting_enabled = true;");
        try staged.tmp.dir.access(e2e_io, "out/sokol_desktop/scripts/behavior.js", .{});
        // The d.ts authoring companion is NOT a script: no registration.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "labelle.d") == null);
        // The coexisting ZIG script never leaks into the language layer:
        // no registration for it (it rides the Zig scripts pipeline).
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript(\"move\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript(\"01_move\"") == null);

        // Generated build: the plugin dep selects the typescript sub-module.
        const build_zig = try staged.tmp.dir.readFileAlloc(e2e_io, "out/sokol_desktop/build.zig", allocator, .limited(1 << 20));
        defer allocator.free(build_zig);
        _ = try indexOfOrFail(build_zig, "const plugin_scripting_dep = b.dependency(\"labelle_scripting\", .{ .target = target, .optimize = optimize, .language = .typescript });");

        // Declare phase SKIPPED without error (lua-only v1): no generated
        // component file — even though the plugin fixture ships the
        // tools/declare capability marker, which is what makes this line a
        // real pin on the language gate (see the block comment above).
        try std.testing.expectError(
            error.FileNotFound,
            staged.tmp.dir.access(e2e_io, "out/sokol_desktop/scripting_components.zig", .{}),
        );
    }

    // The old `.ts fails generate with ScriptNeedsTranspile` pin lived
    // here while transpile was the #586 gap. The gate flipped to the real
    // TS 7 check+emit path (labelle-engine#745): every `.ts` shape —
    // transpile-and-embed (scripts/ AND the legacy grace dir), ordering
    // through emission, type-error relay, stem collisions, the js-only
    // no-fetch skip — is pinned in `test/scripting_transpile_tests.zig`.
    // The happy test above stays THE pin that a `.js`-only project's
    // splice layout is byte-identical to the pre-#745 one.

    test "LEGACY grace through the REAL generate: ts/ scripts still work — ts/-rooted embed (deprecation-note release)" {
        const allocator = std.testing.allocator;
        var staged = try StagedTsProject.init(allocator);
        defer staged.deinit(allocator);
        var game_root = try staged.tmp.dir.openDir(e2e_io, "game", .{});
        defer game_root.close(e2e_io);
        // Unmigrate the fixture: language files move back to ts/ (the
        // d.ts companion too — a scripts/-side d.ts is probe-exempt and
        // would be fine, but the pure legacy shape is the point here);
        // the Zig script stays in scripts/, as every real project's does.
        try game_root.deleteFile(e2e_io, "scripts/behavior.js");
        try game_root.deleteFile(e2e_io, "scripts/labelle.d.ts");
        try writeFileIn(game_root, "ts/behavior.js", "// @ts-check\nexport function update(dt) {}\n");
        try writeFileIn(game_root, "ts/labelle.d.ts", "declare const labelle: any;\n");

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });

        const main_zig = try staged.tmp.dir.readFileAlloc(e2e_io, "out/sokol_desktop/main.zig", allocator, .limited(1 << 20));
        defer allocator.free(main_zig);
        // Pre-#237 emission verbatim: ts/-rooted embed, plain stem.
        _ = try indexOfOrFail(main_zig, "scripting.registerScript(\"behavior\", @embedFile(\"ts/behavior.js\"));");
        try staged.tmp.dir.access(e2e_io, "out/sokol_desktop/ts/behavior.js", .{});
    }

    test "BOTH scripts/ and ts/ populated fails generate with the pointed conflict (no silent merge)" {
        const allocator = std.testing.allocator;
        var staged = try StagedTsProject.init(allocator);
        defer staged.deinit(allocator);
        var game_root = try staged.tmp.dir.openDir(e2e_io, "game", .{});
        defer game_root.close(e2e_io);
        // scripts/behavior.js is already staged; add a legacy straggler.
        try writeFileIn(game_root, "ts/old_behavior.js", "export function update(dt) {}\n");

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try std.testing.expectError(
            error.LegacyScriptDirConflict,
            generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false }),
        );
    }

    test "a language file in scripts/<state>/ fails generate pointedly (state subdirs are Zig-only for now)" {
        const allocator = std.testing.allocator;
        var staged = try StagedTsProject.init(allocator);
        defer staged.deinit(allocator);
        var game_root = try staged.tmp.dir.openDir(e2e_io, "game", .{});
        defer game_root.close(e2e_io);
        try writeFileIn(game_root, "scripts/playing/10_boss.js", "export function update(dt) {}\n");

        const backend_repo = try sokolFixtureRepoAbs(allocator);
        defer allocator.free(backend_repo);
        try std.testing.expectError(
            error.ScriptInStateSubdir,
            generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false }),
        );

        // Negative control: the same file as a ZIG script is the Zig
        // scanner's normal state-scoped shape — generate succeeds.
        try game_root.deleteFile(e2e_io, "scripts/playing/10_boss.js");
        try writeFileIn(game_root, "scripts/playing/10_boss.zig", "pub fn tick() void {}\n");
        try generate.generate(allocator, staged.config(backend_repo), staged.out_abs, staged.game_abs, .{ .is_tests_target = false });
        try staged.tmp.dir.access(e2e_io, "out/sokol_desktop/main.zig", .{});
    }
};
