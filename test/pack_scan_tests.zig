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
        // never references a packs/ path.
        try std.testing.expect(contains(main_zig, "engine.ComponentRegistry(.{"));
        try std.testing.expect(!contains(main_zig, "packs/"));
    }
};
