const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;
const generator = @import("generator");
const script_scanner = generator.script_scanner;
const ScriptScanner = script_scanner.ScriptScanner;

test {
    zspec.runAll(@This());
}

pub const ExtractSortOrder = struct {
    test "extracts 1 from 01_foo.zig" {
        try expect.equal(script_scanner.extractSortOrder("01_foo.zig"), @as(?u32, 1));
    }
    test "extracts 12 from 12_bar.zig" {
        try expect.equal(script_scanner.extractSortOrder("12_bar.zig"), @as(?u32, 12));
    }
    test "extracts 99 from 99_baz.zig" {
        try expect.equal(script_scanner.extractSortOrder("99_baz.zig"), @as(?u32, 99));
    }
    test "returns null for foo.zig" {
        try expect.equal(script_scanner.extractSortOrder("foo.zig"), @as(?u32, null));
    }
    test "returns null for bar_baz.zig (not a prefix)" {
        try expect.equal(script_scanner.extractSortOrder("bar_baz.zig"), @as(?u32, null));
    }
    test "extracts 0 from 00_first.zig" {
        try expect.equal(script_scanner.extractSortOrder("00_first.zig"), @as(?u32, 0));
    }
};

pub const StripPrefixAndExtension = struct {
    test "strips prefix and extension from 01_foo.zig" {
        try std.testing.expectEqualStrings("foo", script_scanner.stripPrefixAndExtension("01_foo.zig"));
    }
    test "strips prefix from 01_pathfinder_bridge.zig" {
        try std.testing.expectEqualStrings("pathfinder_bridge", script_scanner.stripPrefixAndExtension("01_pathfinder_bridge.zig"));
    }
    test "strips only extension from camera_control.zig" {
        try std.testing.expectEqualStrings("camera_control", script_scanner.stripPrefixAndExtension("camera_control.zig"));
    }
    test "strips only extension from bar_baz.zig" {
        try std.testing.expectEqualStrings("bar_baz", script_scanner.stripPrefixAndExtension("bar_baz.zig"));
    }
    test "strips prefix and extension from 03_save_load.zig" {
        try std.testing.expectEqualStrings("save_load", script_scanner.stripPrefixAndExtension("03_save_load.zig"));
    }
};

pub const IsValidStateName = struct {
    test "accepts lowercase names" {
        try expect.toBeTrue(script_scanner.isValidStateName("playing"));
        try expect.toBeTrue(script_scanner.isValidStateName("menu"));
    }
    test "accepts underscores" {
        try expect.toBeTrue(script_scanner.isValidStateName("game_over"));
    }
    test "accepts digits" {
        try expect.toBeTrue(script_scanner.isValidStateName("level_2"));
    }
    test "rejects uppercase" {
        try expect.toBeFalse(script_scanner.isValidStateName("Playing"));
    }
    test "rejects spaces" {
        try expect.toBeFalse(script_scanner.isValidStateName("my state"));
    }
    test "rejects hyphens" {
        try expect.toBeFalse(script_scanner.isValidStateName("game-over"));
    }
    test "rejects empty string" {
        try expect.toBeFalse(script_scanner.isValidStateName(""));
    }
};

pub const ManualEntries = struct {
    pub const with_ordering = struct {
        test "sorts global first, then numbered, then unnumbered" {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const states = [_][]const u8{ "menu", "playing", "paused" };
            var scanner = ScriptScanner.init(alloc, &states);

            // Global scripts (root)
            try scanner.addEntry("save_load.zig", null, &.{});
            try scanner.addEntry("debug_overlay.zig", null, &.{});

            // Playing scripts with order
            const playing = [_][]const u8{"playing"};
            try scanner.addEntry("03_production_system.zig", "playing", &playing);
            try scanner.addEntry("01_pathfinder_bridge.zig", "playing", &playing);
            try scanner.addEntry("02_worker_movement.zig", "playing", &playing);

            // Menu script
            const menu = [_][]const u8{"menu"};
            try scanner.addEntry("menu_system.zig", "menu", &menu);

            scanner.sortEntries();
            const entries = scanner.getEntries();

            try expect.equal(entries.len, @as(usize, 6));

            // Global scripts first (alphabetical)
            try std.testing.expectEqualStrings("debug_overlay", entries[0].name);
            try expect.toBeTrue(entries[0].subdir == null);
            try std.testing.expectEqualStrings("save_load", entries[1].name);
            try expect.toBeTrue(entries[1].subdir == null);

            // Then state-scoped, ordered by prefix
            try std.testing.expectEqualStrings("pathfinder_bridge", entries[2].name);
            try expect.equal(entries[2].sort_order, @as(?u32, 1));
            try std.testing.expectEqualStrings("worker_movement", entries[3].name);
            try expect.equal(entries[3].sort_order, @as(?u32, 2));
            try std.testing.expectEqualStrings("production_system", entries[4].name);
            try expect.equal(entries[4].sort_order, @as(?u32, 3));

            // Unnumbered state script last
            try std.testing.expectEqualStrings("menu_system", entries[5].name);
            try expect.toBeTrue(entries[5].sort_order == null);
        }
    };
};

pub const MultiStateDirectory = struct {
    test "parses multi-state directory entries" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const states = [_][]const u8{ "playing", "paused" };
        var scanner = ScriptScanner.init(alloc, &states);

        const both = [_][]const u8{ "playing", "paused" };
        try scanner.addEntry("camera_control.zig", "playing+paused", &both);

        const entries = scanner.getEntries();
        try expect.equal(entries.len, @as(usize, 1));
        try std.testing.expectEqualStrings("camera_control", entries[0].name);
        try expect.equal(entries[0].states.len, @as(usize, 2));
        try std.testing.expectEqualStrings("playing", entries[0].states[0]);
        try std.testing.expectEqualStrings("paused", entries[0].states[1]);
    }
};

pub const GetEntriesForState = struct {
    test "filters entries correctly by state" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const states = [_][]const u8{ "menu", "playing", "paused" };
        var scanner = ScriptScanner.init(alloc, &states);

        // Global
        try scanner.addEntry("save_load.zig", null, &.{});

        // Playing only
        const playing = [_][]const u8{"playing"};
        try scanner.addEntry("01_worker_movement.zig", "playing", &playing);
        try scanner.addEntry("02_production_system.zig", "playing", &playing);

        // Menu only
        const menu = [_][]const u8{"menu"};
        try scanner.addEntry("menu_system.zig", "menu", &menu);

        // Playing + paused
        const both = [_][]const u8{ "playing", "paused" };
        try scanner.addEntry("camera_control.zig", "playing+paused", &both);

        scanner.sortEntries();

        // Playing: save_load + worker_movement + production_system + camera_control
        const playing_scripts = try scanner.getEntriesForState("playing");
        try expect.equal(playing_scripts.len, @as(usize, 4));
        try std.testing.expectEqualStrings("save_load", playing_scripts[0].name);
        try std.testing.expectEqualStrings("worker_movement", playing_scripts[1].name);
        try std.testing.expectEqualStrings("production_system", playing_scripts[2].name);
        try std.testing.expectEqualStrings("camera_control", playing_scripts[3].name);

        // Menu: save_load + menu_system
        const menu_scripts = try scanner.getEntriesForState("menu");
        try expect.equal(menu_scripts.len, @as(usize, 2));
        try std.testing.expectEqualStrings("save_load", menu_scripts[0].name);
        try std.testing.expectEqualStrings("menu_system", menu_scripts[1].name);

        // Paused: save_load + camera_control
        const paused_scripts = try scanner.getEntriesForState("paused");
        try expect.equal(paused_scripts.len, @as(usize, 2));
        try std.testing.expectEqualStrings("save_load", paused_scripts[0].name);
        try std.testing.expectEqualStrings("camera_control", paused_scripts[1].name);
    }
};

pub const RealDirectoryScan = struct {
    test "scans filesystem directory structure" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.makeDir("scripts");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/save_load.zig", .data = "// global" });
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/debug.zig", .data = "// global" });

        try tmp_dir.dir.makeDir("scripts/playing");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/01_pathfinder.zig", .data = "" });
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/02_movement.zig", .data = "" });
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/03_production.zig", .data = "" });

        try tmp_dir.dir.makeDir("scripts/menu");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/menu/menu_ui.zig", .data = "" });

        try tmp_dir.dir.makeDir("scripts/playing+paused");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing+paused/camera.zig", .data = "" });

        const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");

        const states_list = [_][]const u8{ "menu", "playing", "paused" };
        var scanner = ScriptScanner.init(alloc, &states_list);
        try scanner.scanDir(scripts_path);

        const entries = scanner.getEntries();
        // 2 global + 3 playing + 1 menu + 1 playing+paused = 7
        try expect.equal(entries.len, @as(usize, 7));

        // Global scripts first
        try expect.toBeTrue(entries[0].subdir == null);
        try expect.toBeTrue(entries[1].subdir == null);

        // Playing: 2 global + 3 playing + 1 playing+paused = 6
        const playing_scripts = try scanner.getEntriesForState("playing");
        try expect.equal(playing_scripts.len, @as(usize, 6));

        // Menu: 2 global + 1 menu = 3
        const menu_scripts = try scanner.getEntriesForState("menu");
        try expect.equal(menu_scripts.len, @as(usize, 3));
    }

    test "ignores invalid state directories" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.makeDir("scripts");
        try tmp_dir.dir.makeDir("scripts/playing");
        try tmp_dir.dir.makeDir("scripts/NotAState");
        try tmp_dir.dir.makeDir("scripts/some-state");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/foo.zig", .data = "" });
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/NotAState/bar.zig", .data = "" });
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/some-state/baz.zig", .data = "" });

        const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");

        const states_list = [_][]const u8{"playing"};
        var scanner = ScriptScanner.init(alloc, &states_list);
        try scanner.scanDir(scripts_path);

        try expect.equal(scanner.getEntries().len, @as(usize, 1));
        try std.testing.expectEqualStrings("foo", scanner.getEntries()[0].name);
    }

    test "recursive subdirectories are organizational only" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.makeDir("scripts");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/save_load.zig", .data = "" });

        try tmp_dir.dir.makeDir("scripts/playing");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/01_pathfinder_bridge.zig", .data = "" });

        try tmp_dir.dir.makeDir("scripts/playing/navigation");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/navigation/02_navigation_orchestrator.zig", .data = "" });
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/navigation/03_worker_movement.zig", .data = "" });

        try tmp_dir.dir.makeDir("scripts/playing/production");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/production/04_workstation_readiness.zig", .data = "" });
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/production/05_production_system.zig", .data = "" });

        try tmp_dir.dir.makeDir("scripts/playing/gizmos");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/gizmos/tendable_gizmos.zig", .data = "" });
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/gizmos/item_gizmos.zig", .data = "" });

        const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");

        const states_list = [_][]const u8{ "playing", "paused" };
        var scanner = ScriptScanner.init(alloc, &states_list);
        try scanner.scanDir(scripts_path);

        const entries = scanner.getEntries();
        // 1 global + 7 playing (across root + 3 subdirs) = 8
        try expect.equal(entries.len, @as(usize, 8));

        // Global first
        try std.testing.expectEqualStrings("save_load", entries[0].name);
        try expect.toBeTrue(entries[0].subdir == null);

        // Then numbered playing scripts in order
        try std.testing.expectEqualStrings("pathfinder_bridge", entries[1].name);
        try expect.equal(entries[1].sort_order, @as(?u32, 1));

        try std.testing.expectEqualStrings("navigation_orchestrator", entries[2].name);
        try expect.equal(entries[2].sort_order, @as(?u32, 2));

        try std.testing.expectEqualStrings("worker_movement", entries[3].name);
        try expect.equal(entries[3].sort_order, @as(?u32, 3));

        try std.testing.expectEqualStrings("workstation_readiness", entries[4].name);
        try expect.equal(entries[4].sort_order, @as(?u32, 4));

        try std.testing.expectEqualStrings("production_system", entries[5].name);
        try expect.equal(entries[5].sort_order, @as(?u32, 5));

        // Unnumbered gizmo scripts last (alphabetical)
        try std.testing.expectEqualStrings("item_gizmos", entries[6].name);
        try expect.toBeTrue(entries[6].sort_order == null);

        try std.testing.expectEqualStrings("tendable_gizmos", entries[7].name);
        try expect.toBeTrue(entries[7].sort_order == null);

        // All playing scripts have the "playing" state
        for (entries[1..]) |e| {
            try expect.equal(e.states.len, @as(usize, 1));
            try std.testing.expectEqualStrings("playing", e.states[0]);
        }

        // Filter for playing: all 8
        const playing_scripts = try scanner.getEntriesForState("playing");
        try expect.equal(playing_scripts.len, @as(usize, 8));

        // Filter for paused: only global
        const paused_scripts = try scanner.getEntriesForState("paused");
        try expect.equal(paused_scripts.len, @as(usize, 1));
    }

    test "ignores directories not in valid states" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.makeDir("scripts");
        try tmp_dir.dir.makeDir("scripts/playing");
        try tmp_dir.dir.makeDir("scripts/loading");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/foo.zig", .data = "" });
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/loading/bar.zig", .data = "" });

        const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");

        const states_list = [_][]const u8{"playing"};
        var scanner = ScriptScanner.init(alloc, &states_list);
        try scanner.scanDir(scripts_path);

        try expect.equal(scanner.getEntries().len, @as(usize, 1));
        try std.testing.expectEqualStrings("foo", scanner.getEntries()[0].name);
    }
};

pub const DuplicateValidation = struct {
    test "duplicate sort order in same scope fails" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.makeDir("scripts");
        try tmp_dir.dir.makeDir("scripts/playing");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/02_foo.zig", .data = "" });
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/02_bar.zig", .data = "" });

        const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");

        const states_list = [_][]const u8{"playing"};
        var scanner = ScriptScanner.init(alloc, &states_list);
        try std.testing.expectError(error.DuplicateSortOrder, scanner.scanDir(scripts_path));
    }

    test "duplicate sort order across different scopes is ok" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.makeDir("scripts");
        try tmp_dir.dir.makeDir("scripts/playing");
        try tmp_dir.dir.makeDir("scripts/menu");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/01_movement.zig", .data = "" });
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/menu/01_menu_ui.zig", .data = "" });

        const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");

        const states_list = [_][]const u8{ "playing", "menu" };
        var scanner = ScriptScanner.init(alloc, &states_list);
        try scanner.scanDir(scripts_path);

        try expect.equal(scanner.getEntries().len, @as(usize, 2));
    }

    test "duplicate sort order across subdirs in same scope fails" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.makeDir("scripts");
        try tmp_dir.dir.makeDir("scripts/playing");
        try tmp_dir.dir.makeDir("scripts/playing/navigation");
        try tmp_dir.dir.makeDir("scripts/playing/production");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/navigation/02_movement.zig", .data = "" });
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/production/02_production.zig", .data = "" });

        const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");

        const states_list = [_][]const u8{"playing"};
        var scanner = ScriptScanner.init(alloc, &states_list);
        try std.testing.expectError(error.DuplicateSortOrder, scanner.scanDir(scripts_path));
    }
};

/// Plugin-shipped scripts (RFC-plugin-controllers §2).
///
/// A plugin can ship its own `scripts/` directory that the assembler copies
/// into the generated build alongside the game's own. Game scripts run in
/// block 1 (numeric-prefix ordered), plugin scripts run in block 2 (per
/// plugin, in `project.labelle` `.plugins` declaration order, then
/// numeric-prefix-ordered within each plugin's namespace).
pub const PluginBlockOrdering = struct {
    test "plugin scripts sort after game scripts" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        // Game block: one global script + one playing script.
        try tmp_dir.dir.makeDir("scripts");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/global.zig", .data = "" });
        try tmp_dir.dir.makeDir("scripts/playing");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/01_pathfinder.zig", .data = "" });

        // Plugin block: one plugin ships its own scripts.
        try tmp_dir.dir.makeDir("pathfinder_scripts");
        try tmp_dir.dir.writeFile(.{ .sub_path = "pathfinder_scripts/01_startup.zig", .data = "" });
        try tmp_dir.dir.makeDir("pathfinder_scripts/playing");
        try tmp_dir.dir.writeFile(.{ .sub_path = "pathfinder_scripts/playing/01_advance.zig", .data = "" });

        const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");
        const plugin_scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "pathfinder_scripts");

        const states_list = [_][]const u8{"playing"};
        var scanner = ScriptScanner.init(alloc, &states_list);
        try scanner.scanDir(scripts_path);
        try scanner.scanPluginDir(plugin_scripts_path, "pathfinder");

        const entries = scanner.getEntries();
        try expect.equal(entries.len, @as(usize, 4));

        // Block 1: game scripts first (global then numbered state script).
        try expect.toBeTrue(entries[0].plugin_name == null);
        try expect.toBeTrue(entries[1].plugin_name == null);

        // Block 2: pathfinder plugin scripts after the game block.
        try expect.toBeTrue(entries[2].plugin_name != null);
        try std.testing.expectEqualStrings("pathfinder", entries[2].plugin_name.?);
        try expect.toBeTrue(entries[3].plugin_name != null);
        try std.testing.expectEqualStrings("pathfinder", entries[3].plugin_name.?);
    }

    test "two plugins sort in scanPluginDir call order (project.labelle .plugins order)" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.makeDir("scripts");

        try tmp_dir.dir.makeDir("pathfinder_s");
        try tmp_dir.dir.writeFile(.{ .sub_path = "pathfinder_s/01_a.zig", .data = "" });

        try tmp_dir.dir.makeDir("scheduler_s");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scheduler_s/01_a.zig", .data = "" });

        const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");
        const pf_path = try tmp_dir.dir.realpathAlloc(alloc, "pathfinder_s");
        const sched_path = try tmp_dir.dir.realpathAlloc(alloc, "scheduler_s");

        const states_list = [_][]const u8{};
        var scanner = ScriptScanner.init(alloc, &states_list);
        try scanner.scanDir(scripts_path);
        // Scheduler declared before pathfinder in project.labelle.
        try scanner.scanPluginDir(sched_path, "scheduler");
        try scanner.scanPluginDir(pf_path, "pathfinder");

        const entries = scanner.getEntries();
        try expect.equal(entries.len, @as(usize, 2));
        try std.testing.expectEqualStrings("scheduler", entries[0].plugin_name.?);
        try std.testing.expectEqualStrings("pathfinder", entries[1].plugin_name.?);
    }

    test "same numeric prefix across two plugins is ok (separate namespaces)" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.makeDir("scripts");

        try tmp_dir.dir.makeDir("a_scripts");
        try tmp_dir.dir.makeDir("a_scripts/playing");
        try tmp_dir.dir.writeFile(.{ .sub_path = "a_scripts/playing/05_foo.zig", .data = "" });

        try tmp_dir.dir.makeDir("b_scripts");
        try tmp_dir.dir.makeDir("b_scripts/playing");
        try tmp_dir.dir.writeFile(.{ .sub_path = "b_scripts/playing/05_foo.zig", .data = "" });

        const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");
        const a_path = try tmp_dir.dir.realpathAlloc(alloc, "a_scripts");
        const b_path = try tmp_dir.dir.realpathAlloc(alloc, "b_scripts");

        const states_list = [_][]const u8{"playing"};
        var scanner = ScriptScanner.init(alloc, &states_list);
        try scanner.scanDir(scripts_path);
        // Duplicate 05_ prefix across two plugins — must not be an error.
        try scanner.scanPluginDir(a_path, "a");
        try scanner.scanPluginDir(b_path, "b");

        try expect.equal(scanner.getEntries().len, @as(usize, 2));
    }

    test "same numeric prefix within a single plugin is a build error" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.makeDir("scripts");

        try tmp_dir.dir.makeDir("a_scripts");
        try tmp_dir.dir.makeDir("a_scripts/playing");
        try tmp_dir.dir.writeFile(.{ .sub_path = "a_scripts/playing/05_foo.zig", .data = "" });
        try tmp_dir.dir.writeFile(.{ .sub_path = "a_scripts/playing/05_bar.zig", .data = "" });

        const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");
        const a_path = try tmp_dir.dir.realpathAlloc(alloc, "a_scripts");

        const states_list = [_][]const u8{"playing"};
        var scanner = ScriptScanner.init(alloc, &states_list);
        try scanner.scanDir(scripts_path);
        try std.testing.expectError(error.DuplicateSortOrder, scanner.scanPluginDir(a_path, "a"));
    }

    test "same numeric prefix in game vs plugin is ok (different blocks)" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.makeDir("scripts");
        try tmp_dir.dir.makeDir("scripts/playing");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/01_game.zig", .data = "" });

        try tmp_dir.dir.makeDir("plug_scripts");
        try tmp_dir.dir.makeDir("plug_scripts/playing");
        try tmp_dir.dir.writeFile(.{ .sub_path = "plug_scripts/playing/01_plug.zig", .data = "" });

        const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");
        const plug_path = try tmp_dir.dir.realpathAlloc(alloc, "plug_scripts");

        const states_list = [_][]const u8{"playing"};
        var scanner = ScriptScanner.init(alloc, &states_list);
        try scanner.scanDir(scripts_path);
        // Game has 01_game.zig at playing/ and plugin has 01_plug.zig at
        // playing/. Different namespaces — must NOT collide.
        try scanner.scanPluginDir(plug_path, "plug");

        try expect.equal(scanner.getEntries().len, @as(usize, 2));
    }

    test "scanDir ignores .plugin_<name> subdirs in the game scripts tree" {
        // The assembler copies plugin scripts into
        // `<target>/scripts/.plugin_<name>/…`. When `scanDir` walks the
        // game tree after the copy pass, it must skip those so they don't
        // double-register as both game and plugin scripts.
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.makeDir("scripts");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/game_global.zig", .data = "" });
        try tmp_dir.dir.makeDir("scripts/.plugin_pathfinder");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/.plugin_pathfinder/01_advance.zig", .data = "" });

        const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");

        const states_list = [_][]const u8{};
        var scanner = ScriptScanner.init(alloc, &states_list);
        try scanner.scanDir(scripts_path);

        // Only the game script should be picked up by scanDir.
        try expect.equal(scanner.getEntries().len, @as(usize, 1));
        try std.testing.expectEqualStrings("game_global", scanner.getEntries()[0].name);
    }
};

/// `ship_from_plugin` ConventionDirMode copies files from a plugin's cached
/// package into the generated build tree (RFC-plugin-controllers §2, step 1).
///
/// The assembler's top-level `generate` orchestrates this, but the actual
/// copy step goes through `scanner.copyAndScanAbs`, which takes two
/// fully-resolved absolute paths. The test fixture simulates a plugin
/// shipping a directory by writing files to a temp dir, then calling
/// `copyAndScanAbs` directly.
pub const ShipFromPlugin = struct {
    const scanner = generator.scanner;

    test "copyAndScanAbs copies and scans files end-to-end" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.makeDir("plugin_src");
        try tmp.dir.writeFile(.{ .sub_path = "plugin_src/01_startup.zig", .data = "pub fn setup() void {}" });
        try tmp.dir.writeFile(.{ .sub_path = "plugin_src/02_advance.zig", .data = "pub fn tick() void {}" });

        try tmp.dir.makeDir("target");

        const src_path = try tmp.dir.realpathAlloc(alloc, "plugin_src");
        const dst_path = try tmp.dir.realpathAlloc(alloc, "target");

        const names = try scanner.copyAndScanAbs(alloc, src_path, dst_path, ".zig");

        // Returned names are sorted stems (no extension).
        try expect.equal(names.len, @as(usize, 2));
        try std.testing.expectEqualStrings("01_startup", names[0]);
        try std.testing.expectEqualStrings("02_advance", names[1]);

        // Files are present at the destination.
        var dst_dir = try tmp.dir.openDir("target", .{});
        defer dst_dir.close();

        const startup_content = try dst_dir.readFileAlloc(alloc, "01_startup.zig", 1024);
        try std.testing.expectEqualStrings("pub fn setup() void {}", startup_content);

        const advance_content = try dst_dir.readFileAlloc(alloc, "02_advance.zig", 1024);
        try std.testing.expectEqualStrings("pub fn tick() void {}", advance_content);
    }

    test "copyAndScanAbs preserves subdirectory structure" {
        // Plugin scripts often ship state-scoped dirs (e.g. `playing/`); the
        // copy must preserve that nesting so the state-scoping semantics
        // carry through to the generated build.
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.makeDir("plugin_src");
        try tmp.dir.makeDir("plugin_src/playing");
        try tmp.dir.writeFile(.{ .sub_path = "plugin_src/playing/01_advance.zig", .data = "" });

        try tmp.dir.makeDir("target");

        const src_path = try tmp.dir.realpathAlloc(alloc, "plugin_src");
        const dst_path = try tmp.dir.realpathAlloc(alloc, "target");

        _ = try scanner.copyAndScanAbs(alloc, src_path, dst_path, ".zig");

        // Subdirectory preserved.
        var target_playing = try tmp.dir.openDir("target/playing", .{});
        target_playing.close();
    }
};

// Regression tests for memory leaks (issue #78).
// These use std.testing.allocator directly (not arena) so the GPA
// detects any leaked allocations and fails the test.
pub const MemoryLeaks = struct {
    test "scanDir with state dirs does not leak (regression #78)" {
        const alloc = std.testing.allocator;

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.makeDir("scripts");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/global.zig", .data = "" });
        try tmp_dir.dir.makeDir("scripts/playing");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/01_movement.zig", .data = "" });
        try tmp_dir.dir.makeDir("scripts/playing/sub");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing/sub/02_ai.zig", .data = "" });
        try tmp_dir.dir.makeDir("scripts/menu");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/menu/ui.zig", .data = "" });
        try tmp_dir.dir.makeDir("scripts/playing+menu");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/playing+menu/camera.zig", .data = "" });

        const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");
        defer alloc.free(scripts_path);

        const states_list = [_][]const u8{ "playing", "menu" };
        var scanner = ScriptScanner.init(alloc, &states_list);
        defer scanner.deinit();
        try scanner.scanDir(scripts_path);

        // Verify scan worked
        try expect.equal(scanner.getEntries().len, @as(usize, 5));
        // If deinit doesn't free everything, std.testing.allocator will fail this test
    }

    test "scanDir with no state dirs does not leak" {
        const alloc = std.testing.allocator;

        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        try tmp_dir.dir.makeDir("scripts");
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/foo.zig", .data = "" });
        try tmp_dir.dir.writeFile(.{ .sub_path = "scripts/bar.zig", .data = "" });

        const scripts_path = try tmp_dir.dir.realpathAlloc(alloc, "scripts");
        defer alloc.free(scripts_path);

        const states_list = [_][]const u8{"playing"};
        var scanner = ScriptScanner.init(alloc, &states_list);
        defer scanner.deinit();
        try scanner.scanDir(scripts_path);

        try expect.equal(scanner.getEntries().len, @as(usize, 2));
    }
};
