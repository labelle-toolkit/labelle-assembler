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
//!      present + sorted + before `PluginControllers.setup`, embed paths
//!      rooted at the copied `<language>/` dir, the module-scope
//!      `scripting` alias + `scripting_enabled` flag (the generated half of
//!      the backend templates' double-`@hasDecl` gate), and the per-frame
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

/// The splice fixture root.zig would thread for a two-script lua project:
/// stems pre-sorted (the `scanner.linkAndScan` contract), one nested subdir
/// so the `/`-joined name shape is exercised.
const lua_splice = generate.scripting_splice.ScriptingSplice{
    .plugin_name = "scripting",
    .language = "lua",
    .extension = ".lua",
    .script_names = &.{ "ai/guard", "player_ai" },
};

/// A project.labelle plugin list carrying THE scripting plugin plus an
/// ordinary sibling — the sibling proves the splice never leaks onto other
/// plugins' wiring.
const scripting_plugins = [_]generate.PluginDep{
    .{ .name = "scripting", .repo = "github:labelle-toolkit/labelle-scripting", .version = "0.1.0", .params = .{ .language = "lua" } },
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
    test "loop lifecycle: registrations sorted + before plugin setup, alias/flag emitted, drain between tick and dispatch" {
        generate.main_template.scripting_splice = lua_splice;
        defer generate.main_template.scripting_splice = null;

        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
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

        // Registrations: sorted stems, `<language>/`-rooted embed paths, and
        // strictly BEFORE PluginControllers.setup boots the VM.
        const reg_guard = try indexOfOrFail(main_zig, "scripting.registerScript(\"ai/guard\", @embedFile(\"lua/ai/guard.lua\"));");
        const reg_player = try indexOfOrFail(main_zig, "scripting.registerScript(\"player_ai\", @embedFile(\"lua/player_ai.lua\"));");
        const controllers_setup = try indexOfOrFail(main_zig, "PluginControllers.setup(&g)");
        try std.testing.expect(reg_guard < reg_player);
        try std.testing.expect(reg_player < controllers_setup);

        // Drain tap: AFTER the plugin ticks, BEFORE g.dispatchEvents() —
        // the engine contract's load-bearing ordering — and engine-gated so
        // pre-contract engines still build.
        const plugin_tick = try indexOfOrFail(main_zig, "PluginSystems.postTick(&g, scaled_dt);");
        const drain = try indexOfOrFail(main_zig, "if (comptime @hasDecl(engine, \"script_contract\")) {");
        const drain_call = try indexOfOrFail(main_zig, "engine.script_contract.drainEvents(&g);");
        const dispatch = try indexOfOrFail(main_zig, "g.dispatchEvents();");
        try std.testing.expect(plugin_tick < drain);
        try std.testing.expect(drain < drain_call);
        try std.testing.expect(drain_call < dispatch);

        // The whole generated main still passes Zig's front-end (parse +
        // AstGen — imports unresolved, so no engine checkout needed).
        try expectAstGenOk(main_zig);
    }

    test "callback lifecycle (bgfx-android shape): registrations + drain ride the same builders" {
        h.setBgfxAndroidLifecycle();
        defer h.clearLifecycleOverrides();
        generate.main_template.scripting_splice = lua_splice;
        defer generate.main_template.scripting_splice = null;

        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .bgfx,
            .platform = .android,
            .ecs = .mock,
            .plugins = &scripting_plugins,
        }, h.bgfx_android_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        _ = try indexOfOrFail(main_zig, "const scripting = @import(\"scripting\");");
        _ = try indexOfOrFail(main_zig, "const scripting_enabled = true;");

        const reg_guard = try indexOfOrFail(main_zig, "scripting.registerScript(\"ai/guard\", @embedFile(\"lua/ai/guard.lua\"));");
        const reg_player = try indexOfOrFail(main_zig, "scripting.registerScript(\"player_ai\", @embedFile(\"lua/player_ai.lua\"));");
        const controllers_setup = try indexOfOrFail(main_zig, "PluginControllers.setup(&g)");
        try std.testing.expect(reg_guard < reg_player);
        try std.testing.expect(reg_player < controllers_setup);

        const drain_call = try indexOfOrFail(main_zig, "engine.script_contract.drainEvents(&g);");
        const dispatch = try indexOfOrFail(main_zig, "g.dispatchEvents();");
        try std.testing.expect(drain_call < dispatch);

        try expectAstGenOk(main_zig);
    }

    test "an EMPTY script set still wires the plugin: alias + flag + drain, but no registerScript" {
        // Empty `lua/` dir (or none): the plugin is attached and the VM
        // boots, so the flag/alias/drain must be present — only the
        // registration block is elided.
        var empty_scripts = lua_splice;
        empty_scripts.script_names = &.{};
        generate.main_template.scripting_splice = empty_scripts;
        defer generate.main_template.scripting_splice = null;

        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &scripting_plugins,
        }, loop_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        _ = try indexOfOrFail(main_zig, "const scripting_enabled = true;");
        _ = try indexOfOrFail(main_zig, "engine.script_contract.drainEvents(&g);");
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript") == null);
    }

    test "no splice → no scripting markers anywhere (plugins-bearing project stays clean)" {
        // The byte-identity guarantee is locked by the untouched goldens;
        // this is the explicit no-markers regression for a plugins-bearing
        // main generated WITHOUT the splice (the threadlocal at its null
        // default, as every pre-#593 call site leaves it).
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &scripting_plugins,
        }, loop_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerScript") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "scripting_enabled") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "script_contract") == null);
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
