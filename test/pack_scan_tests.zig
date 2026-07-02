//! Pack dir-scan tests (Packs RFC §4, labelle-assembler#439).
//!
//! Two layers:
//!   1. `scanPack` — the filesystem copy/scan half. Given a pack directory
//!      laid out like the game root (`components/ events/ prefabs/`), assert
//!      it copies the files into `<target>/packs/<name>/…` and returns the
//!      scanned stems.
//!   2. Emission — set `main_template.pack_scans` to a hand-built `PackScan`
//!      and assert the generated `main.zig` actually REFERENCES the pack's
//!      component/event/prefab (the core "discarded names now reach the
//!      registries" fix). This is the golden-style assertion the ticket asks
//!      for, over the emitted registry/import/lifecycle blocks.

const std = @import("std");
const zspec = @import("zspec");
const generate = @import("generator");
const h = @import("helpers.zig");

const engine_template = h.engine_template;
const raylib_lifecycle = h.raylib_lifecycle;
const empty_names = h.empty_names;
const empty_entries = h.empty_entries;
const empty_scene_manifests = h.empty_scene_manifests;
const empty_plugin_events = h.empty_plugin_events;
const empty_plugin_flow_nodes = h.empty_plugin_flow_nodes;
const empty_plugin_pin_styles = h.empty_plugin_pin_styles;
const empty_plugin_coercions = h.empty_plugin_coercions;

const io = std.testing.io;

test {
    zspec.runAll(@This());
}

// ── Helpers ─────────────────────────────────────────────────────────

fn writeFileIn(dir: std.Io.Dir, rel: []const u8, body: []const u8) !void {
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(io, sub);
    var f = try dir.createFile(io, rel, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ── scanPack: filesystem copy + scan ────────────────────────────────

pub const SCAN_PACK = struct {
    test "copies + scans a pack's components/events/prefabs into packs/<name>/" {
        const allocator = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        // Lay out a pack source dir: <tmp>/src/citizens/{components,events,prefabs}
        try tmp.dir.createDirPath(io, "src/citizens");
        var pack_src = try tmp.dir.openDir(io, "src/citizens", .{});
        defer pack_src.close(io);
        try writeFileIn(pack_src, "components/Worker.zig", "pub const Worker = struct { hp: u8 };\n");
        try writeFileIn(pack_src, "events/worker_died.zig", "pub const WorkerDied = struct { id: u64 };\n");
        try writeFileIn(pack_src, "prefabs/worker.jsonc", "{ \"children\": [] }\n");
        // hooks/ is now scanned too (#440) — the same copy/scan as the other
        // convention dirs, registered under the `<pack>__` ident prefix.
        try writeFileIn(pack_src, "hooks/overlay.zig", "pub const Overlay = struct {};\n");

        const pack_src_path = try tmp.dir.realPathFileAlloc(io, "src/citizens", allocator);
        defer allocator.free(pack_src_path);
        const target_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(target_path);

        var scan = try generate.scanPack(allocator, pack_src_path, target_path, "citizens");
        defer scan.deinit(allocator);

        try std.testing.expectEqualStrings("citizens", scan.name);
        try std.testing.expectEqualStrings("packs/citizens", scan.import_prefix);
        try std.testing.expectEqual(@as(usize, 1), scan.component_names.len);
        try std.testing.expectEqualStrings("Worker", scan.component_names[0]);
        try std.testing.expectEqual(@as(usize, 1), scan.event_names.len);
        try std.testing.expectEqualStrings("worker_died", scan.event_names[0]);
        try std.testing.expectEqual(@as(usize, 1), scan.prefab_names.len);
        try std.testing.expectEqualStrings("worker", scan.prefab_names[0]);
        try std.testing.expectEqual(@as(usize, 1), scan.hook_names.len);
        try std.testing.expectEqualStrings("overlay", scan.hook_names[0]);

        // The files were physically copied under packs/citizens/ in the target.
        try tmp.dir.access(io, "packs/citizens/components/Worker.zig", .{});
        try tmp.dir.access(io, "packs/citizens/events/worker_died.zig", .{});
        try tmp.dir.access(io, "packs/citizens/prefabs/worker.jsonc", .{});
        try tmp.dir.access(io, "packs/citizens/hooks/overlay.zig", .{});
    }

    test "rewrites a pack prefab's local component refs to the <pack>__ form" {
        const allocator = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(io, "src/citizens");
        var pack_src = try tmp.dir.openDir(io, "src/citizens", .{});
        defer pack_src.close(io);
        try writeFileIn(pack_src, "components/Worker.zig", "pub const Worker = struct { hp: u8 };\n");
        // The prefab references the pack's OWN `Worker` by local name, plus a
        // built-in engine component (`Position`) that must be left ALONE, and
        // a string VALUE `"Worker"` that must NOT be rewritten (only keys are).
        try writeFileIn(pack_src, "prefabs/worker.jsonc",
            \\{
            \\    "components": {
            \\        "Worker": { "hp": 3, "label": "Worker" },
            \\        "Position": { "x": 0, "y": 0 }
            \\    }
            \\}
        );

        const pack_src_path = try tmp.dir.realPathFileAlloc(io, "src/citizens", allocator);
        defer allocator.free(pack_src_path);
        const target_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(target_path);

        var scan = try generate.scanPack(allocator, pack_src_path, target_path, "citizens");
        defer scan.deinit(allocator);

        const rewritten = try tmp.dir.readFileAlloc(io, "packs/citizens/prefabs/worker.jsonc", allocator, .limited(64 * 1024));
        defer allocator.free(rewritten);

        // The pack's own component KEY was rewritten to the prefixed form …
        try std.testing.expect(contains(rewritten, "\"citizens__Worker\":"));
        // … the built-in `Position` was left untouched …
        try std.testing.expect(contains(rewritten, "\"Position\":"));
        try std.testing.expect(!contains(rewritten, "citizens__Position"));
        // … and the string VALUE `"Worker"` was NOT rewritten (keys only).
        try std.testing.expect(contains(rewritten, "\"label\": \"Worker\""));

        // End-to-end (#440): the SAME pack drives the component registry to the
        // prefixed field, so the rewritten JSONC key resolves against it.
        const main_zig = try genWithPack(component_tmpl, cfg_with_pack, scan);
        defer std.testing.allocator.free(main_zig);
        try std.testing.expect(contains(main_zig, ".citizens__Worker = @import(\"packs/citizens/components/Worker.zig\").Worker,"));
    }

    test "rewrites a pack prefab's same-pack prefab reference to the <pack>__ form (chatgpt-codex #1)" {
        const allocator = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(io, "src/citizens");
        var pack_src = try tmp.dir.openDir(io, "src/citizens", .{});
        defer pack_src.close(io);
        // Two same-pack prefabs: `squad` composes `worker` by local name.
        try writeFileIn(pack_src, "prefabs/worker.jsonc", "{ \"components\": {} }\n");
        try writeFileIn(pack_src, "prefabs/squad.jsonc",
            \\{
            \\    "children": [
            \\        { "prefab": "worker" },
            \\        { "prefab": "external" }
            \\    ]
            \\}
        );

        const pack_src_path = try tmp.dir.realPathFileAlloc(io, "src/citizens", allocator);
        defer allocator.free(pack_src_path);
        const target_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(target_path);

        var scan = try generate.scanPack(allocator, pack_src_path, target_path, "citizens");
        defer scan.deinit(allocator);

        const rewritten = try tmp.dir.readFileAlloc(io, "packs/citizens/prefabs/squad.jsonc", allocator, .limited(64 * 1024));
        defer allocator.free(rewritten);

        // The same-pack reference now resolves to the namespaced registration
        // key `addEmbeddedPrefab(&g, "citizens__worker", …)` uses …
        try std.testing.expect(contains(rewritten, "\"prefab\": \"citizens__worker\""));
        // … while a reference to a non-pack prefab is left bare.
        try std.testing.expect(contains(rewritten, "\"prefab\": \"external\""));
        try std.testing.expect(!contains(rewritten, "citizens__external"));
    }

    test "rewrites a pack hook's bare local event handler to the prefixed tag (chatgpt-codex #3)" {
        const allocator = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(io, "src/citizens");
        var pack_src = try tmp.dir.openDir(io, "src/citizens", .{});
        defer pack_src.close(io);
        // The pack owns event `worker_died`; the hook reacts to it with the
        // BARE local name, plus a built-in engine event (`tick`) that must
        // keep its bare name so it still matches the un-prefixed variant.
        try writeFileIn(pack_src, "events/worker_died.zig", "pub const WorkerDied = struct { id: u64 };\n");
        try writeFileIn(pack_src, "hooks/overlay.zig",
            \\pub const Overlay = struct {
            \\    pub fn worker_died(self: *Overlay, data: anytype) void {
            \\        _ = self;
            \\        _ = data;
            \\    }
            \\    pub fn tick(self: *Overlay, data: anytype) void {
            \\        _ = self;
            \\        _ = data;
            \\    }
            \\};
        );

        const pack_src_path = try tmp.dir.realPathFileAlloc(io, "src/citizens", allocator);
        defer allocator.free(pack_src_path);
        const target_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(target_path);

        var scan = try generate.scanPack(allocator, pack_src_path, target_path, "citizens");
        defer scan.deinit(allocator);

        const rewritten = try tmp.dir.readFileAlloc(io, "packs/citizens/hooks/overlay.zig", allocator, .limited(64 * 1024));
        defer allocator.free(rewritten);

        // The pack-event handler is renamed to the prefixed variant tag so the
        // engine dispatcher matches it against `citizens__worker_died` …
        try std.testing.expect(contains(rewritten, "pub fn citizens__worker_died("));
        try std.testing.expect(!contains(rewritten, "pub fn worker_died("));
        // … the engine-event handler keeps its bare name (still matches `tick`).
        try std.testing.expect(contains(rewritten, "pub fn tick("));
        try std.testing.expect(!contains(rewritten, "citizens__tick"));
    }

    test "tolerates a pack that ships only some convention dirs" {
        const allocator = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        // Only components/ — no events/, no prefabs/.
        try tmp.dir.createDirPath(io, "src/minimal");
        var pack_src = try tmp.dir.openDir(io, "src/minimal", .{});
        defer pack_src.close(io);
        try writeFileIn(pack_src, "components/Foo.zig", "pub const Foo = struct {};\n");

        const pack_src_path = try tmp.dir.realPathFileAlloc(io, "src/minimal", allocator);
        defer allocator.free(pack_src_path);
        const target_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(target_path);

        var scan = try generate.scanPack(allocator, pack_src_path, target_path, "minimal");
        defer scan.deinit(allocator);

        try std.testing.expectEqual(@as(usize, 1), scan.component_names.len);
        try std.testing.expectEqual(@as(usize, 0), scan.event_names.len);
        try std.testing.expectEqual(@as(usize, 0), scan.prefab_names.len);
    }
};

// ── Emission: pack items reach the generated registries ─────────────
//
// These use focused sub-templates (one placeholder + `{{lifecycle}}`), the
// same pattern the existing event tests in `main_zig_tests.zig` use — the
// shared minimal `engine_template` deliberately omits the event / jsonc-scene
// slots, so a per-concern template is how the codebase exercises them.

// A pack is consumed as a plugin (project.labelle `.plugins`), so declaring
// one drives the ComponentRegistryWithPlugins path — the unified registry a
// pack's components must land in.
const cfg_with_pack: generate.ProjectConfig = .{
    .y_axis = .up,
    .name = "test-game",
    .backend = .raylib,
    .ecs = .mock,
    .plugins = &.{.{ .name = "citizens", .repo = "@packs/citizens" }},
};

const component_tmpl = "{{component_registry_block}}\n{{lifecycle}}";
const events_tmpl = "{{event_imports_block}}\n{{game_events_block}}\n{{lifecycle}}";
const prefab_tmpl = "{{jsonc_scene_block}}\n{{lifecycle}}";
const hooks_tmpl = "{{hook_imports_block}}\n{{game_hooks_block}}\n{{hooks_init_block}}\n{{lifecycle}}";

fn genWithPack(tmpl: []const u8, cfg: generate.ProjectConfig, pack: generate.PackScan) ![]const u8 {
    generate.main_template.pack_scans = &.{pack};
    defer generate.main_template.pack_scans = &.{};

    return generate.generateMainZigFromTemplate(
        std.testing.allocator,
        tmpl,
        cfg,
        raylib_lifecycle,
        empty_entries,
        empty_names, // prefab_names (game root)
        empty_names, // jsonc_scene_names
        empty_scene_manifests,
        empty_names, // component_names (game root)
        empty_names, // hook_names
        empty_names, // event_names (game root)
        empty_names, // enum_names
        empty_names, // view_names
        empty_names, // gizmo_names
        empty_names, // animation_names
        empty_plugin_events,
        empty_plugin_flow_nodes,
        empty_plugin_pin_styles,
        empty_plugin_coercions,
    );
}

pub const PACK_EMISSION = struct {
    test "pack component lands in the unified Components registry" {
        const pack: generate.PackScan = .{
            .name = "citizens",
            .import_prefix = "packs/citizens",
            .component_names = &.{"Worker"},
            .event_names = &.{},
            .prefab_names = &.{},
        };
        const main_zig = try genWithPack(component_tmpl, cfg_with_pack, pack);
        defer std.testing.allocator.free(main_zig);

        // The unified registry is emitted (plugin present) and the pack's
        // component is a field in it under the invisible `<pack>__<Name>`
        // prefix (#440) — imported through the pack prefix, but the DECL
        // access stays bare (the component type's own `pub const Worker`).
        try std.testing.expect(contains(main_zig, "engine.ComponentRegistryWithPlugins(.{"));
        try std.testing.expect(contains(main_zig, ".citizens__Worker = @import(\"packs/citizens/components/Worker.zig\").Worker,"));
        // The bare (un-prefixed) field must NOT be emitted.
        try std.testing.expect(!contains(main_zig, ".Worker = @import(\"packs/citizens"));
    }

    test "pack event widens GameEvents and is imported through the pack prefix" {
        const pack: generate.PackScan = .{
            .name = "citizens",
            .import_prefix = "packs/citizens",
            .component_names = &.{},
            .event_names = &.{"worker_died"},
            .prefab_names = &.{},
        };
        const main_zig = try genWithPack(events_tmpl, cfg_with_pack, pack);
        defer std.testing.allocator.free(main_zig);

        // Imported through the pack prefix, aliased under `<pack>__` (#440) …
        try std.testing.expect(contains(main_zig, "const citizens__worker_died = @import(\"packs/citizens/events/worker_died.zig\");"));
        // … and folded into the GameEvents union as a prefixed variant, whose
        // type reference uses the same prefixed alias.
        try std.testing.expect(contains(main_zig, "citizens__worker_died: citizens__worker_died.WorkerDied,"));
    }

    test "pack prefab is embedded and registered from the pack prefix" {
        const pack: generate.PackScan = .{
            .name = "citizens",
            .import_prefix = "packs/citizens",
            .component_names = &.{},
            .event_names = &.{},
            .prefab_names = &.{"worker"},
        };
        const main_zig = try genWithPack(prefab_tmpl, cfg_with_pack, pack);
        defer std.testing.allocator.free(main_zig);

        // JsoncBridge is declared even though the game root has no scenes,
        // and the pack prefab is embedded from its prefixed path.
        try std.testing.expect(contains(main_zig, "JsoncBridge"));
        try std.testing.expect(contains(main_zig, "@embedFile(\"packs/citizens/prefabs/worker.jsonc\")"));

        // The prefab MUST be registered with the pack's own prefab root
        // (`packs/citizens/prefabs`), NOT the game's bare `"prefabs"` — the
        // engine uses this as the base dir for the prefab's JSONC `"include"`
        // / source-relative lookups, so a pack prefab has to resolve against
        // the copied pack dir (chatgpt-codex, #478).
        try std.testing.expect(contains(
            main_zig,
            "@embedFile(\"packs/citizens/prefabs/worker.jsonc\"), \"packs/citizens/prefabs\"",
        ));
        try std.testing.expect(!contains(
            main_zig,
            "@embedFile(\"packs/citizens/prefabs/worker.jsonc\"), \"prefabs\"",
        ));

        // The prefab is REGISTERED under the invisible `<pack>__<name>` key
        // (#440) so a pack + game root that both ship `worker` don't collide.
        try std.testing.expect(contains(main_zig, "addEmbeddedPrefab(&g, \"citizens__worker\","));
    }

    test "pack hook is imported, added to GameHooks, and instantiated under the <pack>__ prefix" {
        const pack: generate.PackScan = .{
            .name = "citizens",
            .import_prefix = "packs/citizens",
            .component_names = &.{},
            .event_names = &.{},
            .prefab_names = &.{},
            .hook_names = &.{"overlay"},
        };
        const main_zig = try genWithPack(hooks_tmpl, cfg_with_pack, pack);
        defer std.testing.allocator.free(main_zig);

        // Imported through the pack prefix, aliased under `<pack>__` (#440).
        try std.testing.expect(contains(main_zig, "const citizens__overlay = @import(\"packs/citizens/hooks/overlay.zig\");"));
        // Wired into the GameHooks receiver-type tuple …
        try std.testing.expect(contains(main_zig, "*citizens__overlay.Overlay,"));
        // … and instantiated + referenced in the receivers tuple (same order).
        try std.testing.expect(contains(main_zig, "var citizens__overlay_inst = citizens__overlay.Overlay{};"));
        try std.testing.expect(contains(main_zig, "&citizens__overlay_inst,"));
    }

    test "pack emits a PackView registry partition over its own component field names (#498)" {
        const pack: generate.PackScan = .{
            .name = "citizens",
            .import_prefix = "packs/citizens",
            .component_names = &.{ "Worker", "Home" },
            .event_names = &.{},
            .prefab_names = &.{},
        };
        const main_zig = try genWithPack(component_tmpl, cfg_with_pack, pack);
        defer std.testing.allocator.free(main_zig);

        // The per-pack partition is generated as a `PackView` over the single
        // full `Components` registry (a name lens, not a second registry) …
        try std.testing.expect(contains(main_zig, "pub const citizens_pack_view = engine.PackView(Components, &.{"));
        // … whose allow-list is EXACTLY the namespaced registry field names the
        // component block emitted (the serde/save keys), both entries present.
        try std.testing.expect(contains(main_zig, "    \"citizens__Worker\",\n"));
        try std.testing.expect(contains(main_zig, "    \"citizens__Home\",\n"));
    }

    test "pack view uses the sanitized <pack>__ prefix for a hyphenated pack name (#498)" {
        const pack: generate.PackScan = .{
            .name = "my-pack",
            .import_prefix = "packs/my-pack",
            .component_names = &.{"Worker"},
            .event_names = &.{},
            .prefab_names = &.{},
        };
        // A pack name is consumed as a plugin; declare the matching plugin so the
        // unified-registry path is taken (mirrors `cfg_with_pack`).
        const cfg: generate.ProjectConfig = .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{.{ .name = "my-pack", .repo = "@packs/my-pack" }},
        };
        const main_zig = try genWithPack(component_tmpl, cfg, pack);
        defer std.testing.allocator.free(main_zig);

        // The view decl name + its allow-list entry both use the sanitized
        // `my_pack__` prefix — byte-identical to the emitted registry field.
        try std.testing.expect(contains(main_zig, "pub const my_pack_pack_view = engine.PackView(Components, &.{"));
        try std.testing.expect(contains(main_zig, "    \"my_pack__Worker\",\n"));
    }

    test "a component-less pack emits no PackView (nothing to partition) (#498)" {
        const pack: generate.PackScan = .{
            .name = "citizens",
            .import_prefix = "packs/citizens",
            .component_names = &.{},
            .event_names = &.{"worker_died"},
            .prefab_names = &.{},
        };
        const main_zig = try genWithPack(events_tmpl, cfg_with_pack, pack);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(!contains(main_zig, "_pack_view"));
        try std.testing.expect(!contains(main_zig, "engine.PackView("));
    }

    test "no packs → component registry emission is unchanged (empty pack_scans is a no-op)" {
        const empty_pack_scans: []const generate.PackScan = &.{};
        generate.main_template.pack_scans = empty_pack_scans;
        defer generate.main_template.pack_scans = &.{};

        const main_zig = try generate.generateMainZigFromTemplate(
            std.testing.allocator,
            component_tmpl,
            .{ .y_axis = .up, .name = "test-game", .backend = .raylib, .ecs = .mock },
            raylib_lifecycle,
            empty_entries,
            empty_names,
            empty_names,
            empty_scene_manifests,
            empty_names,
            empty_names,
            empty_names,
            empty_names,
            empty_names,
            empty_names,
            empty_names,
            empty_plugin_events,
            empty_plugin_flow_nodes,
            empty_plugin_pin_styles,
            empty_plugin_coercions,
        );
        defer std.testing.allocator.free(main_zig);

        // Plugin-less, pack-less project keeps the plain ComponentRegistry and
        // never references a packs/ path — and emits no per-pack partition (#498).
        try std.testing.expect(contains(main_zig, "engine.ComponentRegistry(.{"));
        try std.testing.expect(!contains(main_zig, "packs/"));
        try std.testing.expect(!contains(main_zig, "_pack_view"));
    }
};

// ── #481: a light pack builds end-to-end (module-less, dir-scan only) ────
//
// A light pack is declared in `project.labelle` `.plugins` just like a real
// plugin, but it ships NO Zig module — only convention dirs. `generate()`
// therefore splits the declared `.plugins` list into decl-module plugins
// (which get `@import("<name>")` + a `b.dependency("labelle_<name>", …)`) and
// light packs (which contribute ONLY the already-scanned `pack_scans` registry
// entries). The split is `root.declModulePlugins`; these tests exercise that
// selection AND prove the two emission consequences: the pack is never
// imported / never a build dep, yet its items ARE registered.

pub const LIGHT_PACK_MODULE_FILTER = struct {
    test "declModulePlugins drops light packs and keeps decl-module plugins, order preserved" {
        const plugins = [_]generate.PluginDep{
            .{ .name = "physics", .repo = "github:x/physics" },
            .{ .name = "citizens", .repo = "@packs/citizens" }, // light pack
            .{ .name = "combat", .repo = "@libs/combat" },
            .{ .name = "biomes", .repo = "@packs/biomes" }, // light pack
        };
        const pack_names = [_][]const u8{ "citizens", "biomes" };

        const kept = try generate.declModulePlugins(std.testing.allocator, &plugins, &pack_names);
        defer std.testing.allocator.free(kept);

        try std.testing.expectEqual(@as(usize, 2), kept.len);
        try std.testing.expectEqualStrings("physics", kept[0].name);
        try std.testing.expectEqualStrings("combat", kept[1].name);
    }

    test "declModulePlugins is a no-op when there are no packs" {
        const plugins = [_]generate.PluginDep{
            .{ .name = "physics", .repo = "github:x/physics" },
        };
        const kept = try generate.declModulePlugins(std.testing.allocator, &plugins, &.{});
        defer std.testing.allocator.free(kept);
        try std.testing.expectEqual(@as(usize, 1), kept.len);
        try std.testing.expectEqualStrings("physics", kept[0].name);
    }

    test "declModulePlugins drops a game whose ONLY plugin is a light pack" {
        const plugins = [_]generate.PluginDep{
            .{ .name = "citizens", .repo = "@packs/citizens" },
        };
        const pack_names = [_][]const u8{"citizens"};
        const kept = try generate.declModulePlugins(std.testing.allocator, &plugins, &pack_names);
        defer std.testing.allocator.free(kept);
        try std.testing.expectEqual(@as(usize, 0), kept.len);
    }
};

pub const LIGHT_PACK_BUILDS_END_TO_END = struct {
    // A game declaring a decl-module plugin (`physics`) AND a light pack
    // (`citizens`). This mirrors the `project.labelle` `.plugins` list that
    // reaches `generate()`.
    const declared_plugins = [_]generate.PluginDep{
        .{ .name = "physics", .repo = "github:x/physics" },
        .{ .name = "citizens", .repo = "@packs/citizens" },
    };
    const pack_names = [_][]const u8{"citizens"};

    // The pack's scanned contribution (what #439/#440 produced from its
    // convention dirs). This is what a light pack adds to the build INSTEAD of
    // a module.
    const citizens_scan: generate.PackScan = .{
        .name = "citizens",
        .import_prefix = "packs/citizens",
        .component_names = &.{"Worker"},
        .event_names = &.{"worker_died"},
        .prefab_names = &.{"worker"},
        .hook_names = &.{},
    };

    // A main.zig template that emits every site that either (a) iterates the
    // plugin list to write `@import("<plugin>")` — the
    // ComponentRegistryWithPlugins / SystemRegistry args AND the
    // plugin-controllers `_plugin_mods` tuple — or (b) registers a pack's
    // scanned items (component registry field, event import, prefab embed).
    const registries_tmpl =
        "{{component_registry_block}}\n{{system_registry_block}}\n{{event_imports_block}}\n{{jsonc_scene_block}}\n{{lifecycle}}";

    test "main.zig imports the decl-module plugin but NOT the light pack, yet registers the pack's items" {
        // Run the SAME split `generate()` runs: declared `.plugins` → the
        // decl-module subset.
        const module_plugins = try generate.declModulePlugins(std.testing.allocator, &declared_plugins, &pack_names);
        defer std.testing.allocator.free(module_plugins);

        const cfg: generate.ProjectConfig = .{
            .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = module_plugins, // light pack already filtered out
        };

        const main_zig = try genWithPack(registries_tmpl, cfg, citizens_scan);
        defer std.testing.allocator.free(main_zig);

        // The decl-module plugin IS imported (registry args + controllers).
        try std.testing.expect(contains(main_zig, "@import(\"physics\")"));

        // The light pack is NEVER imported — a module-less pack has nothing to
        // `@import`. This is the core #481 fix: emitting `@import("citizens")`
        // here is exactly what broke `labelle build`.
        try std.testing.expect(!contains(main_zig, "@import(\"citizens\")"));

        // …yet the pack's component/event/prefab ARE compiled in, via the
        // dir-scan `pack_scans` path, under the invisible `<pack>__` namespace.
        try std.testing.expect(contains(main_zig, ".citizens__Worker = @import(\"packs/citizens/components/Worker.zig\").Worker,"));
        try std.testing.expect(contains(main_zig, "@import(\"packs/citizens/events/worker_died.zig\")"));
        try std.testing.expect(contains(main_zig, "@embedFile(\"packs/citizens/prefabs/worker.jsonc\")"));
    }

    test "build.zig wires a module dep for the decl-module plugin but NOT the light pack" {
        const module_plugins = try generate.declModulePlugins(std.testing.allocator, &declared_plugins, &pack_names);
        defer std.testing.allocator.free(module_plugins);

        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = module_plugins, // light pack already filtered out
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // The decl-module plugin gets its `b.dependency` + module decl…
        try std.testing.expect(contains(build_zig, "b.dependency(\"labelle_physics\""));
        try std.testing.expect(contains(build_zig, "plugin_physics_mod"));

        // …while the light pack has NO build dep / module wiring — a
        // module-less pack ships no `build.zig` for `b.dependency` to point at.
        try std.testing.expect(!contains(build_zig, "labelle_citizens"));
        try std.testing.expect(!contains(build_zig, "plugin_citizens_mod"));
    }
};

// ── #487: a pack's per-frame SYSTEM lives inside the pack ────────────────
//
// Before #487 a pack scanned components/events/prefabs/hooks but NOT
// scripts/, so a pack's per-frame system had to leak into the game root.
// Now the pack's `scripts/<state>/*.zig` is copied UNDER the pack dir
// (`packs/<name>/scripts/…`, beside its copied components/) and registered
// into the SAME per-state dispatch as game-root + plugin scripts. The
// under-the-pack placement is load-bearing: it preserves the script's own
// `../components/foo.zig` relative import, exactly as a game-root script
// reaches `components/` today.

pub const PACK_SCRIPTS = struct {
    test "scanPackScriptsDir registers a pack script into the per-state dispatch" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        // A pack shipping a component + a state-scoped script that reaches the
        // component by the SAME relative path a game-root script uses.
        try tmp.dir.createDirPath(io, "src/citizens");
        var pack_src = try tmp.dir.openDir(io, "src/citizens", .{});
        defer pack_src.close(io);
        try writeFileIn(pack_src, "components/Worker.zig", "pub const Worker = struct { hp: u8 };\n");
        try writeFileIn(pack_src, "scripts/playing/10_worker_tick.zig",
            \\const Worker = @import("../../components/Worker.zig").Worker;
            \\pub fn tick(game: anytype, dt: f32) void {
            \\    _ = game;
            \\    _ = dt;
            \\    _ = Worker;
            \\}
        );

        const pack_src_path = try tmp.dir.realPathFileAlloc(io, "src/citizens", alloc);
        const target_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);

        // scanPack copies the convention dirs (components/) under packs/.
        var scan = try generate.scanPack(alloc, pack_src_path, target_path, "citizens");
        defer scan.deinit(alloc);

        // The scripts subtree is copied under the pack dir — same path root.zig
        // lays down before calling scanPackScriptsDir.
        const scripts_src = try std.fs.path.join(alloc, &.{ pack_src_path, "scripts" });
        const scripts_dst = try std.fs.path.join(alloc, &.{ target_path, "packs", "citizens", "scripts" });
        const copied = try generate.scanner.copyAndScanAbs(alloc, scripts_src, scripts_dst, ".zig");
        _ = copied;

        // Layout invariant: the script and its `../../components/Worker.zig`
        // import target both exist at the offsets the source used.
        try tmp.dir.access(io, "packs/citizens/scripts/playing/10_worker_tick.zig", .{});
        try tmp.dir.access(io, "packs/citizens/components/Worker.zig", .{});

        // Register into the shared ScriptScanner under the pack namespace.
        const states = [_][]const u8{"playing"};
        var scanner = generate.script_scanner.ScriptScanner.init(alloc, &states);
        try scanner.scanPackScriptsDir(scripts_dst, "packs/citizens/scripts", "citizens");

        const entries = scanner.getEntries();
        try std.testing.expectEqual(@as(usize, 1), entries.len);
        const e = entries[0];
        try std.testing.expectEqualStrings("worker_tick", e.name);
        try std.testing.expectEqual(@as(?u32, 10), e.sort_order);
        try std.testing.expectEqualStrings("citizens", e.plugin_name.?);
        try std.testing.expectEqual(@as(usize, 1), e.states.len);
        try std.testing.expectEqualStrings("playing", e.states[0]);
        // Full target-relative rel_path + empty import_base → imported verbatim.
        try std.testing.expectEqualStrings("packs/citizens/scripts/playing/10_worker_tick.zig", e.rel_path);
        try std.testing.expectEqualStrings("", e.import_base);
    }

    test "scanPackScriptsDir no-ops on a pack with no scripts/ dir" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const states = [_][]const u8{"playing"};
        var scanner = generate.script_scanner.ScriptScanner.init(alloc, &states);
        // A path that doesn't exist — tolerated, contributes nothing.
        try scanner.scanPackScriptsDir("packs/does_not_exist/scripts", "packs/does_not_exist/scripts", "ghost");
        try std.testing.expectEqual(@as(usize, 0), scanner.getEntries().len);
    }

    test "AllScripts imports a pack script from packs/<name>/scripts, state-scoped" {
        const pack_entry: generate.script_scanner.ScriptScanner.ScriptEntry = .{
            .name = "worker_tick",
            .filename = "10_worker_tick.zig",
            .states = &.{"playing"},
            .sort_order = 10,
            .subdir = "playing",
            .rel_path = "packs/citizens/scripts/playing/10_worker_tick.zig",
            .plugin_name = "citizens",
            .plugin_index = 1,
            .import_base = "",
        };
        const entries: []const generate.script_scanner.ScriptScanner.ScriptEntry = &.{pack_entry};

        const main_zig = try generate.generateMainZigFromTemplate(
            std.testing.allocator,
            engine_template,
            .{ .y_axis = .up, .name = "test-game", .backend = .raylib, .ecs = .mock },
            raylib_lifecycle,
            entries,
            empty_names,
            empty_names,
            empty_scene_manifests,
            empty_names,
            empty_names,
            empty_names,
            empty_names,
            empty_names,
            empty_names,
            empty_names,
            empty_plugin_events,
            empty_plugin_flow_nodes,
            empty_plugin_pin_styles,
            empty_plugin_coercions,
        );
        defer std.testing.allocator.free(main_zig);

        // Imported verbatim from the copied pack subtree — NOT re-prefixed with
        // `scripts/`, so the pack script's own ../components imports resolve.
        try std.testing.expect(contains(main_zig, "@import(\"packs/citizens/scripts/playing/10_worker_tick.zig\")"));
        try std.testing.expect(!contains(main_zig, "@import(\"scripts/packs/citizens"));
        // State-scoped: the wrapper carries the pack's declared game_states.
        try std.testing.expect(contains(main_zig, "pub const game_states = .{"));
        try std.testing.expect(contains(main_zig, "\"playing\","));
    }

    test "game-root script import prefix is unchanged (regression guard)" {
        // A plain game-root entry keeps the default import_base ("scripts/").
        const game_entry: generate.script_scanner.ScriptScanner.ScriptEntry = .{
            .name = "hits",
            .filename = "hits.zig",
            .states = &.{},
            .sort_order = null,
            .subdir = null,
            .rel_path = "hits.zig",
        };
        const entries: []const generate.script_scanner.ScriptScanner.ScriptEntry = &.{game_entry};

        const main_zig = try generate.generateMainZigFromTemplate(
            std.testing.allocator,
            engine_template,
            .{ .y_axis = .up, .name = "test-game", .backend = .raylib, .ecs = .mock },
            raylib_lifecycle,
            entries,
            empty_names,
            empty_names,
            empty_scene_manifests,
            empty_names,
            empty_names,
            empty_names,
            empty_names,
            empty_names,
            empty_names,
            empty_names,
            empty_plugin_events,
            empty_plugin_flow_nodes,
            empty_plugin_pin_styles,
            empty_plugin_coercions,
        );
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(contains(main_zig, "@import(\"scripts/hits.zig\")"));
    }

    test "scanPackScriptsAt prunes a stale dest and registers nothing when the pack has no scripts/ (#496)" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        // A pack that ships components/ but NO scripts/ (upstream removed the
        // scripts/ it once had).
        try writeFileIn(tmp.dir, "src/citizens/components/Worker.zig", "pub const Worker = struct {};\n");

        // A STALE destination a PRIOR `generate` copied, back when the pack DID
        // ship scripts/. `copyAndScanAbs` no-ops on the missing source and never
        // touches this, so without the prune the scan would register it.
        try writeFileIn(tmp.dir, "packs/citizens/scripts/playing/00_stale.zig", "pub fn tick(_: anytype, _: f32) void {}\n");

        const pack_src_path = try tmp.dir.realPathFileAlloc(io, "src/citizens", alloc);
        const target_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);

        const states = [_][]const u8{"playing"};
        var scanner = generate.script_scanner.ScriptScanner.init(alloc, &states);

        const registered = try generate.scanPackScriptsAt(alloc, &scanner, pack_src_path, target_path, "citizens");

        // No source scripts/ → nothing registered, and the stale dest is gone.
        try std.testing.expect(!registered);
        try std.testing.expectEqual(@as(usize, 0), scanner.getEntries().len);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "packs/citizens/scripts", .{}));
    }

    test "scanPackScriptsAt propagates a non-FileNotFound probe error and does NOT prune (#500 codex)" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        // The pack's `scripts` path exists but is a FILE, not a directory —
        // `openDir` yields `error.NotDir`. That must PROPAGATE (mirroring
        // `copyAndScanAbs`, which tolerates only `FileNotFound`), NOT be
        // swallowed as "no scripts" + a prune of the generated copy.
        try writeFileIn(tmp.dir, "src/citizens/scripts", "this is a file, not a scripts/ dir\n");
        // A pre-existing generated copy that must survive (proving no prune).
        try writeFileIn(tmp.dir, "packs/citizens/scripts/playing/00_keep.zig", "pub fn tick(_: anytype, _: f32) void {}\n");

        const pack_src_path = try tmp.dir.realPathFileAlloc(io, "src/citizens", alloc);
        const target_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);

        const states = [_][]const u8{"playing"};
        var scanner = generate.script_scanner.ScriptScanner.init(alloc, &states);

        try std.testing.expectError(
            error.NotDir,
            generate.scanPackScriptsAt(alloc, &scanner, pack_src_path, target_path, "citizens"),
        );
        // The error propagated BEFORE any prune — the generated copy is intact.
        try tmp.dir.access(io, "packs/citizens/scripts/playing/00_keep.zig", .{});
    }

    test "scanPackScriptsAt registers a present pack script and returns true" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try writeFileIn(tmp.dir, "src/citizens/scripts/playing/10_worker_tick.zig",
            \\pub fn tick(_: anytype, _: f32) void {}
        );

        const pack_src_path = try tmp.dir.realPathFileAlloc(io, "src/citizens", alloc);
        const target_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);

        const states = [_][]const u8{"playing"};
        var scanner = generate.script_scanner.ScriptScanner.init(alloc, &states);

        const registered = try generate.scanPackScriptsAt(alloc, &scanner, pack_src_path, target_path, "citizens");

        try std.testing.expect(registered);
        const entries = scanner.getEntries();
        try std.testing.expectEqual(@as(usize, 1), entries.len);
        try std.testing.expectEqualStrings("citizens", entries[0].plugin_name.?);
        try std.testing.expectEqualStrings("packs/citizens/scripts/playing/10_worker_tick.zig", entries[0].rel_path);
    }

    test "a pack context.zig is imported via AllScripts and does NOT become the game context (#496)" {
        // A pack ships scripts/context.zig. It must be treated as an ordinary
        // pack script (imported through AllScripts, verbatim from the pack
        // subtree), NOT as the game's GameContext — otherwise the template
        // would emit @import("scripts/context.zig") for a game root that has
        // no such file, breaking the build.
        const pack_context: generate.script_scanner.ScriptScanner.ScriptEntry = .{
            .name = "context",
            .filename = "context.zig",
            .states = &.{},
            .sort_order = null,
            .subdir = null,
            .rel_path = "packs/media/scripts/context.zig",
            .plugin_name = "media",
            .plugin_index = 1,
            .import_base = "",
        };
        const entries: []const generate.script_scanner.ScriptScanner.ScriptEntry = &.{pack_context};

        const main_zig = try generate.generateMainZigFromTemplate(
            std.testing.allocator,
            engine_template,
            .{ .y_axis = .up, .name = "test-game", .backend = .raylib, .ecs = .mock },
            raylib_lifecycle,
            entries,
            empty_names,
            empty_names,
            empty_scene_manifests,
            empty_names,
            empty_names,
            empty_names,
            empty_names,
            empty_names,
            empty_names,
            empty_names,
            empty_plugin_events,
            empty_plugin_flow_nodes,
            empty_plugin_pin_styles,
            empty_plugin_coercions,
        );
        defer std.testing.allocator.free(main_zig);

        // Imported through AllScripts, verbatim from the copied pack subtree.
        try std.testing.expect(contains(main_zig, "@import(\"packs/media/scripts/context.zig\")"));
        // …but NOT wired as the game GameContext (the game root has none).
        try std.testing.expect(contains(main_zig, "const GameContext = struct {};"));
        try std.testing.expect(!contains(main_zig, "@import(\"scripts/context.zig\")"));
    }
};
