const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
    const core_mod = core_dep.module("labelle-core");

    const gfx_dep = b.dependency("labelle_gfx", .{ .target = target, .optimize = optimize });
    const gfx_mod = gfx_dep.module("labelle-gfx");

    const engine_dep = b.dependency("engine", .{ .target = target, .optimize = optimize });
    const engine_mod = engine_dep.module("engine");

    // `game` module — local shim (game.zig) re-exporting engine's `Game`
    // and `EntityId` so generated flow files at `scripts/flows/*.zig`
    // can `@import("game")`. See labelle-assembler#116.
    const game_mod = b.createModule(.{
        .root_source_file = b.path("game.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "labelle-engine", .module = engine_mod },
        },
    });

    const backend_dep = b.dependency("labelle_bgfx", .{ .target = target, .optimize = optimize, .gui_enabled = false, .gamepad_enabled = true, .gamepad_hidapi = false });
    const backend_gfx = backend_dep.module("gfx");
    const backend_input = backend_dep.module("input");
    const backend_audio = backend_dep.module("audio");
    const backend_window = backend_dep.module("window");
    const bgfx = backend_dep.artifact("bgfx");
    const glfw = backend_dep.artifact("glfw");

    // Generic core+gfx-diamond unification (design §5) — the loop form of
    // the per-site overrideImport diamond (golden cell, not the desktop
    // byte-anchor's unrolled form). Rooted at each imported provider.
    var core_diamond_visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
    unifyCoreDiamond(b.allocator, gfx_mod, core_mod, gfx_mod, &core_diamond_visited);
    unifyCoreDiamond(b.allocator, engine_mod, core_mod, gfx_mod, &core_diamond_visited);
    unifyCoreDiamond(b.allocator, backend_gfx, core_mod, gfx_mod, &core_diamond_visited);
    unifyCoreDiamond(b.allocator, backend_input, core_mod, gfx_mod, &core_diamond_visited);
    unifyCoreDiamond(b.allocator, backend_audio, core_mod, gfx_mod, &core_diamond_visited);
    unifyCoreDiamond(b.allocator, backend_window, core_mod, gfx_mod, &core_diamond_visited);
    const exe = b.addExecutable(.{
        .name = "anchor-game",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-core", .module = core_mod },
                .{ .name = "labelle-gfx", .module = gfx_mod },
                .{ .name = "labelle-engine", .module = engine_mod },
                .{ .name = "backend_gfx", .module = backend_gfx },
                .{ .name = "backend_input", .module = backend_input },
                .{ .name = "backend_audio", .module = backend_audio },
                .{ .name = "backend_window", .module = backend_window },

                .{ .name = "game", .module = game_mod },

            },
        }),
    });

    exe.root_module.linkLibrary(bgfx);
    exe.root_module.linkLibrary(glfw);
    // ── Test step ──────────────────────────────────────────────────
    // Single test compile unit rooted at `__tests_root.zig` (generated
    // by labelle-assembler alongside main.zig). The wrapper imports
    // every `.zig` file under the project's `tests/` folder so their
    // `test "..." { }` blocks are pulled into this binary.
    //
    // Why a wrapper at the build root rather than per-file `addTest`:
    // Zig's "module path" is the directory of the module's root source
    // file. With this root at the build root, files under `tests/`,
    // `components/`, `scripts/`, etc. are all reachable via relative
    // `@import`, mirroring how the exe sees them — so test code can
    // `@import("../../components/worker.zig")` from `tests/components/`.
    const test_root = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("__tests_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-core", .module = core_mod },
                .{ .name = "labelle-gfx", .module = gfx_mod },
                .{ .name = "labelle-engine", .module = engine_mod },
                .{ .name = "backend_gfx", .module = backend_gfx },
                .{ .name = "backend_input", .module = backend_input },
                .{ .name = "backend_audio", .module = backend_audio },
                .{ .name = "backend_window", .module = backend_window },

                .{ .name = "game", .module = game_mod },

            },
        }),
    });
    const test_step = b.step("test", "Run game-side tests");
    test_step.dependOn(&b.addRunArtifact(test_root).step);

    test_root.root_module.linkLibrary(bgfx);
    test_root.root_module.linkLibrary(glfw);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the game");
    run_step.dependOn(&run_cmd.step);
}

/// Override a module import without leaking memory.
/// Zig's addImport always calls b.dupe(name), leaking the old key on replacement
/// and creating unnecessary allocations for new keys. This function accesses the
/// import_table directly: reuses existing keys and avoids b.dupe entirely.
fn overrideImport(m: *std.Build.Module, name: []const u8, module: *std.Build.Module) void {
    const gop = m.import_table.getOrPut(m.owner.allocator, name) catch @panic("OOM");
    if (!gop.found_existing) {
        // New import — store our key (string literal from generated code, lives forever)
        gop.key_ptr.* = name;
    }
    // Replace value (existing or new)
    gop.value_ptr.* = module;
}

/// Unify `labelle-core` onto gfx's sub-packages (`camera`, `spatial_grid`,
/// `tilemap`) so a `core.YAxis` produced inside `labelle-gfx` unifies with the
/// type each sub-package expects (gfx#276 passes `y_axis` into
/// `camera.CameraWith(...)`). Only overrides sub-packages that import core.
fn unifyGfxSubpackageCore(gfx_mod: *std.Build.Module, core_mod: *std.Build.Module) void {
    const sub_names = [_][]const u8{ "camera", "spatial_grid", "tilemap" };
    for (sub_names) |sub_name| {
        const sub = gfx_mod.import_table.get(sub_name) orelse continue;
        if (sub.import_table.get("labelle-core") != null) {
            overrideImport(sub, "labelle-core", core_mod);
        }
    }
}

/// Generic core+gfx-diamond unification (labelle-assembler#453, design §5).
/// Replaces the hand-written per-backend `overrideImport` sites AND the fixed
/// `engine_mod ← gfx` edge AND `unifyGfxSubpackageCore`. Walks the provider
/// module graph; overrides any labelle-core import onto `core_mod` and any
/// labelle-gfx import onto `gfx_mod` (preserving the key spelling); recurses
/// otherwise. Idempotent, bounded by `visited`. Only rewrites keys already
/// present in an import_table, so it can never inject a dead import (the old
/// `if`-guards are subsumed) and never grows a table mid-iteration.
fn unifyCoreDiamond(
    gpa: std.mem.Allocator,
    root: *std.Build.Module,
    core_mod: *std.Build.Module,
    gfx_mod: *std.Build.Module,
    visited: *std.AutoHashMapUnmanaged(*std.Build.Module, void),
) void {
    if (visited.contains(root)) return;
    visited.put(gpa, root, {}) catch @panic("OOM");
    var it = root.import_table.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "labelle-core") or std.mem.eql(u8, key, "labelle_core")) {
            overrideImport(root, key, core_mod);
        } else if (std.mem.eql(u8, key, "labelle-gfx") or std.mem.eql(u8, key, "labelle_gfx")) {
            overrideImport(root, key, gfx_mod);
        } else {
            unifyCoreDiamond(gpa, entry.value_ptr.*, core_mod, gfx_mod, visited);
        }
    }
}
