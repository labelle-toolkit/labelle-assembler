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
        try std.testing.expect(contains(main_zig, ".citizens__Worker = @import(\"pack__citizens\").components.Worker.Worker,"));
    }

    test "rewrites a FLAT-shape pack prefab into the wrapped namespaced form (#513)" {
        const allocator = std.testing.allocator;

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(io, "src/citizens");
        var pack_src = try tmp.dir.openDir(io, "src/citizens", .{});
        defer pack_src.close(io);
        try writeFileIn(pack_src, "components/Worker.zig", "pub const Worker = struct { hp: u8 };\n");
        // RFC #596 FLAT shape (the engine's recommended one): PascalCase
        // component keys directly at entity scope, no wrapper — the exact
        // shape the FP pilot shipped (flying-platform-labelle#573). The copy
        // must come out WRAPPED: a namespaced flat key would start lowercase
        // and be silently dropped by the engine's case-based classification.
        try writeFileIn(pack_src, "prefabs/worker.jsonc",
            \\{
            \\    "Worker": { "hp": 3 },
            \\    "Position": { "x": 0, "y": 0 }
            \\}
        );
        // A composing prefab whose child is a flat prefab REFERENCE carrying
        // a pack component as its patch — the patch must wrap as `overrides`
        // (the engine's warning-free spelling for reference patches).
        try writeFileIn(pack_src, "prefabs/squad.jsonc",
            \\{
            \\    "children": [
            \\        { "prefab": "worker", "Worker": { "hp": 1 } }
            \\    ]
            \\}
        );

        const pack_src_path = try tmp.dir.realPathFileAlloc(io, "src/citizens", allocator);
        defer allocator.free(pack_src_path);
        const target_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(target_path);

        var scan = try generate.scanPack(allocator, pack_src_path, target_path, "citizens");
        defer scan.deinit(allocator);

        const worker = try tmp.dir.readFileAlloc(io, "packs/citizens/prefabs/worker.jsonc", allocator, .limited(64 * 1024));
        defer allocator.free(worker);
        // The inline flat entity was wrapped, the pack key namespaced, the
        // engine key moved in untouched, and no bare flat key survived.
        try std.testing.expect(contains(worker, "\"components\": {"));
        try std.testing.expect(contains(worker, "\"citizens__Worker\": { \"hp\": 3 }"));
        try std.testing.expect(contains(worker, "\"Position\": { \"x\": 0, \"y\": 0 }"));
        try std.testing.expect(!contains(worker, "citizens__Position"));
        try std.testing.expect(!contains(worker, "\"Worker\":"));

        const squad = try tmp.dir.readFileAlloc(io, "packs/citizens/prefabs/squad.jsonc", allocator, .limited(64 * 1024));
        defer allocator.free(squad);
        // The flat reference child: prefab VALUE namespaced, patch wrapped
        // as `overrides` (not `components`), pack key namespaced inside.
        try std.testing.expect(contains(squad, "\"prefab\": \"citizens__worker\""));
        try std.testing.expect(contains(squad, "\"overrides\": { \"citizens__Worker\": { \"hp\": 1 }"));
        try std.testing.expect(!contains(squad, "\"components\""));
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
        try std.testing.expect(contains(main_zig, ".citizens__Worker = @import(\"pack__citizens\").components.Worker.Worker,"));
        // The bare (un-prefixed) field must NOT be emitted.
        try std.testing.expect(!contains(main_zig, ".Worker = @import(\"pack__citizens"));
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
        try std.testing.expect(contains(main_zig, "const citizens__worker_died = @import(\"pack__citizens\").events.worker_u_died;"));
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
        try std.testing.expect(contains(main_zig, "const citizens__overlay = @import(\"pack__citizens\").hooks.overlay;"));
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
        try std.testing.expect(contains(main_zig, ".citizens__Worker = @import(\"pack__citizens\").components.Worker.Worker,"));
        try std.testing.expect(contains(main_zig, "@import(\"pack__citizens\").events.worker_u_died"));
        try std.testing.expect(contains(main_zig, "@embedFile(\"packs/citizens/prefabs/worker.jsonc\")"));
    }

    test "build.zig wires a module dep for the decl-module plugin but NOT the light pack" {
        const module_plugins = try generate.declModulePlugins(std.testing.allocator, &declared_plugins, &pack_names);
        defer std.testing.allocator.free(module_plugins);

        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
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

        // Reached through the pack MODULE's re-export (#498 PR 2) — the
        // accessor is `pathToIdent` of the scripts-relative path. Neither
        // the old direct path form nor a `scripts/`-prefixed one may
        // remain: the file belongs to the pack module now, so either
        // path import is the dual-module compile error.
        try std.testing.expect(contains(main_zig, "@import(\"pack__citizens\").scripts.playing_s_10_u_worker_u_tick"));
        try std.testing.expect(!contains(main_zig, "@import(\"packs/citizens/scripts/"));
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

        // Imported through AllScripts via the pack module's re-export (#498).
        try std.testing.expect(contains(main_zig, "@import(\"pack__media\").scripts.context"));
        // …but NOT wired as the game GameContext (the game root has none).
        try std.testing.expect(contains(main_zig, "const GameContext = struct {};"));
        try std.testing.expect(!contains(main_zig, "@import(\"scripts/context.zig\")"));
    }
};

// ── #498 PR 2: per-pack module roots + build wiring ──────────────────
//
// The wall's mechanism: every pack's files belong to a `pack__<prefix>`
// module rooted at the generated `__pack_root.zig`, with a restricted
// import table (no `game` shim, no sibling packs — plugins/engine/core
// stay in, they're the shared substrate). These tests pin (a) the
// renderer's re-export shape (the accessor idents the main.zig emission
// sites print) and (b) the generated build.zig wiring: `createModule`
// per pack, `addImport` on every artifact, the restricted table, and
// the implicit `contracts` wiring direction.

pub const PACK_ROOT_RENDER = struct {
    test "renderPackRoot re-exports components/events/hooks/scripts under pathToIdent accessors" {
        const pack: generate.PackScan = .{
            .name = "citizens",
            .import_prefix = "packs/citizens",
            .component_names = &.{"worker_state"},
            .event_names = &.{"worker_died"},
            .prefab_names = &.{"worker"},
            .hook_names = &.{"overlay"},
        };
        const src = try generate.pack_root.renderPackRoot(
            std.testing.allocator,
            pack,
            &.{"playing/10_worker_tick.zig"},
        );
        defer std.testing.allocator.free(src);

        // Section decl names are `pathToIdent` of the stem — the exact
        // accessors `main.zig` prints after `@import("pack__citizens").`.
        try std.testing.expect(contains(src, "pub const components = struct {"));
        try std.testing.expect(contains(src, "pub const worker_u_state = @import(\"components/worker_state.zig\");"));
        try std.testing.expect(contains(src, "pub const events = struct {"));
        try std.testing.expect(contains(src, "pub const worker_u_died = @import(\"events/worker_died.zig\");"));
        try std.testing.expect(contains(src, "pub const hooks = struct {"));
        try std.testing.expect(contains(src, "pub const overlay = @import(\"hooks/overlay.zig\");"));
        try std.testing.expect(contains(src, "pub const scripts = struct {"));
        try std.testing.expect(contains(src, "pub const playing_s_10_u_worker_u_tick = @import(\"scripts/playing/10_worker_tick.zig\");"));
        // Prefabs are DATA — embedded by path from main.zig, never
        // re-exported here.
        try std.testing.expect(!contains(src, "worker.jsonc"));

        // Registry bridge (#498 PR 3): resolves the generated PackView
        // through @import("root") with a tests/preview fallback over the
        // pack's OWN components (namespaced fields = the serde keys).
        try std.testing.expect(contains(src, "pub const Registry = if (@hasDecl(root, \"citizens_pack_view\"))"));
        try std.testing.expect(contains(src, "root.citizens_pack_view"));
        try std.testing.expect(contains(src, ".citizens__WorkerState = components.worker_u_state.WorkerState,"));
    }

    test "renderPackRoot with no zig files emits only the header (prefab-only pack)" {
        const pack: generate.PackScan = .{
            .name = "props",
            .import_prefix = "packs/props",
            .component_names = &.{},
            .event_names = &.{},
            .prefab_names = &.{"crate"},
            .hook_names = &.{},
        };
        const src = try generate.pack_root.renderPackRoot(std.testing.allocator, pack, &.{});
        defer std.testing.allocator.free(src);

        try std.testing.expect(contains(src, "Module root of pack 'props'"));
        try std.testing.expect(!contains(src, "pub const components"));
        try std.testing.expect(!contains(src, "pub const events"));
        try std.testing.expect(!contains(src, "pub const hooks"));
        try std.testing.expect(!contains(src, "pub const scripts"));
        // The Registry bridge is unconditional — component-less packs get
        // the empty fallback so the authoring surface is uniform.
        try std.testing.expect(contains(src, "pub const Registry = if (@hasDecl(root, \"props_pack_view\"))"));
        try std.testing.expect(contains(src, "ComponentRegistry(.{});"));
    }

    test "packRelScriptPath strips the pack's scripts/ prefix and tolerates foreign shapes" {
        try std.testing.expectEqualStrings(
            "playing/10_worker_tick.zig",
            generate.pack_root.packRelScriptPath("packs/citizens/scripts/playing/10_worker_tick.zig", "citizens"),
        );
        // Defensive: unexpected shape passes through unchanged.
        try std.testing.expectEqualStrings(
            "hits.zig",
            generate.pack_root.packRelScriptPath("hits.zig", "citizens"),
        );
    }
};

pub const PACK_MODULE_BUILD = struct {
    const pack_modules = [_]generate.pack_root.PackModule{
        .{ .name = "citizens", .prefix = "citizens" },
        .{ .name = "production", .prefix = "production" },
    };

    /// The slice of `build_zig` between a pack module's `createModule`
    /// open and its closing `});` — the restricted import table under
    /// test. Returns null when the decl is absent.
    fn moduleSlice(build_zig: []const u8, decl: []const u8) ?[]const u8 {
        const start = std.mem.indexOf(u8, build_zig, decl) orelse return null;
        const end = std.mem.indexOfPos(u8, build_zig, start, "});") orelse return null;
        return build_zig[start..end];
    }

    test "each pack gets a createModule rooted at its __pack_root.zig, imported by exe AND test_root" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &.{.{ .name = "physics", .repo = "github:x/physics" }},
        }, .{ .pack_modules = &pack_modules });
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(contains(build_zig, "const pack__citizens_mod = b.createModule(.{"));
        try std.testing.expect(contains(build_zig, "b.path(\"packs/citizens/__pack_root.zig\")"));
        try std.testing.expect(contains(build_zig, "exe.root_module.addImport(\"pack__citizens\", pack__citizens_mod);"));
        try std.testing.expect(contains(build_zig, "test_root.root_module.addImport(\"pack__citizens\", pack__citizens_mod);"));
        try std.testing.expect(contains(build_zig, "const pack__production_mod = b.createModule(.{"));
        // Self-import (#498 PR 3): pack code reaches its own root — and
        // the Registry bridge — as @import("pack").
        try std.testing.expect(contains(build_zig, "overrideImport(pack__citizens_mod, \"pack\", pack__citizens_mod);"));
    }

    test "the pack module's import table is the wall: engine/core/plugins in, game + sibling packs OUT" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &.{.{ .name = "physics", .repo = "github:x/physics" }},
        }, .{ .pack_modules = &pack_modules });
        defer std.testing.allocator.free(build_zig);

        const slice = moduleSlice(build_zig, "const pack__citizens_mod = b.createModule(.{").?;
        // Shared substrate IS importable.
        try std.testing.expect(contains(slice, ".{ .name = \"labelle-engine\", .module = engine_mod },"));
        try std.testing.expect(contains(slice, ".{ .name = \"labelle-core\", .module = core_mod },"));
        try std.testing.expect(contains(slice, ".{ .name = \"physics\", .module = plugin_physics_mod },"));
        // The wall: no `game` shim, no sibling pack.
        try std.testing.expect(!contains(slice, "\"game\""));
        try std.testing.expect(!contains(slice, "production"));
    }

    test "an implicitly-shared contracts pack is wired into every other pack module, one direction only" {
        const with_contracts = [_]generate.pack_root.PackModule{
            .{ .name = "citizens", .prefix = "citizens" },
            .{ .name = "contracts", .prefix = "contracts" },
        };
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, .{ .pack_modules = &with_contracts });
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(contains(build_zig, "overrideImport(pack__citizens_mod, \"contracts\", pack__contracts_mod);"));
        // Direction check: contracts never imports a dependent and never
        // gets ITSELF wired as "contracts" (its own "pack" self-import is
        // fine — that's the PR 3 Registry bridge, every pack has one).
        try std.testing.expect(!contains(build_zig, "overrideImport(pack__contracts_mod, \"contracts\""));
        try std.testing.expect(!contains(build_zig, "overrideImport(pack__contracts_mod, \"citizens\""));
        try std.testing.expect(contains(build_zig, "overrideImport(pack__contracts_mod, \"pack\", pack__contracts_mod);"));
    }

    test "no packs → build.zig has zero pack-module wiring (byte-identity invariant)" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(!contains(build_zig, "pack__"));
        try std.testing.expect(!contains(build_zig, "__pack_root.zig"));
    }
};

// ── Flow-handler import routing at the hook sites ─────────────────────
//
// `printFlowHandlerImport` must mirror the `AllScripts` emitter's three
// shapes exactly, or a handler file lands in two modules. The pack shape
// is covered by the wall's e2e fixture; these pin the game-script edges:
// a FlowNodes-PROMOTED handler routes through its named module (the
// pre-existing dual-module hole CodeRabbit flagged on #538), and a plain
// handler keeps the path import.

pub const FLOW_HANDLER_ROUTING = struct {
    const handler_entry: generate.script_scanner.ScriptScanner.ScriptEntry = .{
        .name = "counter",
        .filename = "counter.zig",
        .states = &.{},
        .sort_order = null,
        .subdir = null,
        .rel_path = "counter.zig",
        .has_event_handler = true,
    };

    fn gen(flow_nodes: []const h.PluginFlowNode) ![]const u8 {
        const entries: []const generate.script_scanner.ScriptScanner.ScriptEntry = &.{handler_entry};
        return generate.generateMainZigFromTemplate(
            std.testing.allocator,
            hooks_tmpl,
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
            flow_nodes,
            empty_plugin_pin_styles,
            empty_plugin_coercions,
        );
    }

    test "a FlowNodes-promoted flow handler is reached via its named module at BOTH hook sites" {
        const nodes = [_]h.PluginFlowNode{.{
            .module_import_path = "counter.zig",
            .module_sanitized = "counter",
            .node_name = "log",
            .is_script = true,
        }};
        const main_zig = try gen(&nodes);
        defer std.testing.allocator.free(main_zig);

        // Receiver-type tuple + hooks_init materialisation both route
        // through the named module …
        try std.testing.expect(contains(main_zig, "*@import(\"script__counter\").FlowEventHandler,"));
        try std.testing.expect(contains(main_zig, "var counter_flow_handler: @import(\"script__counter\").FlowEventHandler = .{};"));
        // … and the path form is fully gone (it would put the file in
        // both the root module and its own named module).
        try std.testing.expect(!contains(main_zig, "@import(\"scripts/counter.zig\")"));
    }

    test "a plain (unpromoted) flow handler keeps the scripts/ path import" {
        const main_zig = try gen(empty_plugin_flow_nodes);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(contains(main_zig, "*@import(\"scripts/counter.zig\").FlowEventHandler,"));
        try std.testing.expect(!contains(main_zig, "script__counter"));
    }
};

// ── #498 PR 4: exposes surfaces + depends_on wiring ──────────────────

pub const PACK_SURFACE = struct {
    test "renderSurface re-exports exactly the exposes lists through @import(\"pack\")" {
        const src = try generate.pack_root.renderSurface(std.testing.allocator, "citizens", .{
            .queries = &.{ "find_idle_worker", "worker_count" },
            .commands = &.{"assign_job"},
        });
        defer std.testing.allocator.free(src);

        try std.testing.expect(contains(src, "const pack = @import(\"pack\");"));
        try std.testing.expect(contains(src, "pub const @\"find_idle_worker\" = pack.queries.@\"find_idle_worker\";"));
        try std.testing.expect(contains(src, "pub const @\"worker_count\" = pack.queries.@\"worker_count\";"));
        try std.testing.expect(contains(src, "pub const @\"assign_job\" = pack.commands.@\"assign_job\";"));
    }

    test "renderSurface with no exposes is a header-only module — dependents can call nothing" {
        const src = try generate.pack_root.renderSurface(std.testing.allocator, "props", .{});
        defer std.testing.allocator.free(src);

        try std.testing.expect(contains(src, "Public surface of pack 'props'"));
        try std.testing.expect(!contains(src, "@import(\"pack\")"));
        try std.testing.expect(!contains(src, "pub const queries"));
        try std.testing.expect(!contains(src, "pub const commands"));
    }

    test "checkExposesFiles: exposing verbs without the file is a generate-time error" {
        try generate.pack_validate.checkExposesFiles("citizens", 2, 0, true, false);
        try std.testing.expectError(
            error.PackExposesMissingFile,
            generate.pack_validate.checkExposesFiles("citizens", 2, 0, false, false),
        );
        try std.testing.expectError(
            error.PackExposesMissingFile,
            generate.pack_validate.checkExposesFiles("citizens", 0, 1, true, false),
        );
    }

    test "scanPack copies queries.zig/commands.zig and prunes stale copies" {
        const allocator = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.createDirPath(io, "src/citizens");
        var pack_src = try tmp.dir.openDir(io, "src/citizens", .{});
        defer pack_src.close(io);
        try writeFileIn(pack_src, "queries.zig", "pub fn find_idle(game: anytype) void { _ = game; }\n");

        const pack_src_path = try tmp.dir.realPathFileAlloc(io, "src/citizens", allocator);
        defer allocator.free(pack_src_path);
        const target_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(target_path);

        var scan1 = try generate.scanPack(allocator, pack_src_path, target_path, "citizens");
        defer scan1.deinit(allocator);
        try std.testing.expect(scan1.has_queries);
        try std.testing.expect(!scan1.has_commands);
        try tmp.dir.access(io, "packs/citizens/queries.zig", .{});

        // Source removed → the stale copy is pruned on the next scan.
        try pack_src.deleteFile(io, "queries.zig");
        var scan2 = try generate.scanPack(allocator, pack_src_path, target_path, "citizens");
        defer scan2.deinit(allocator);
        try std.testing.expect(!scan2.has_queries);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "packs/citizens/queries.zig", .{}));
    }

    test "build wiring: every pack gets a surface module importing ONLY its pack; depends_on maps the dep name onto the dep's SURFACE" {
        const pack_modules = [_]generate.pack_root.PackModule{
            .{ .name = "citizens", .prefix = "citizens" },
            .{ .name = "production", .prefix = "production", .depends_on = &.{"citizens"} },
        };
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, .{ .pack_modules = &pack_modules });
        defer std.testing.allocator.free(build_zig);

        // Surface module: rooted at __surface.zig, sole import = the pack.
        try std.testing.expect(contains(build_zig, "const pack_surface__citizens_mod = b.createModule(.{"));
        try std.testing.expect(contains(build_zig, "b.path(\"packs/citizens/__surface.zig\")"));
        try std.testing.expect(contains(build_zig, ".imports = &.{.{ .name = \"pack\", .module = pack__citizens_mod }},"));
        // Surface modules are DEMAND-driven: nothing depends_on
        // production, so declaring its surface would be an unused-const
        // compile error in the generated build.zig.
        try std.testing.expect(!contains(build_zig, "pack_surface__production_mod"));
        // depends_on: production reaches citizens ONLY through the surface…
        try std.testing.expect(contains(build_zig, "overrideImport(pack__production_mod, \"citizens\", pack_surface__citizens_mod);"));
        // … never the pack module itself, and never the reverse direction.
        try std.testing.expect(!contains(build_zig, "overrideImport(pack__production_mod, \"citizens\", pack__citizens_mod);"));
        try std.testing.expect(!contains(build_zig, "overrideImport(pack__citizens_mod, \"production\""));
    }
};
