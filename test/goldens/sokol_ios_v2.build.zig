const std = @import("std");

const backend_build_hook = @import("backend_build_hook.zig");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // resolve_target (design §4) — the backend hook runs xcrun SDK discovery
    // + device/simulator selection, producing BOTH the ios target and the
    // SDK path plugin b.dependency calls consume, BEFORE any b.dependency.
    const ios_resolved = backend_build_hook.resolve_target(b, .{ .platform = .ios });
    const ios_target = ios_resolved.target;
    const sdk_path = ios_resolved.ios_sdk_path.?;

    const core_dep = b.dependency("labelle_core", .{ .target = ios_target, .optimize = optimize });
    const core_mod = core_dep.module("labelle-core");

    const gfx_dep = b.dependency("labelle_gfx", .{ .target = ios_target, .optimize = optimize });
    const gfx_mod = gfx_dep.module("labelle-gfx");

    const engine_dep = b.dependency("engine", .{ .target = ios_target, .optimize = optimize });
    const engine_mod = engine_dep.module("engine");

    // `game` module — see labelle-assembler#116. iOS-targeted variant.
    const game_mod = b.createModule(.{
        .root_source_file = b.path("game.zig"),
        .target = ios_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "labelle-engine", .module = engine_mod },
        },
    });

    const backend_dep = b.dependency("labelle_sokol", .{ .target = ios_target, .optimize = optimize, .with_imgui = false, .dont_link_system_libs = true });
    const backend_gfx = backend_dep.module("gfx");
    const backend_input = backend_dep.module("input");
    const backend_audio = backend_dep.module("audio");
    const backend_window = backend_dep.module("window");
    const sokol_clib = backend_dep.artifact("sokol_clib");

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
        .name = "game",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = ios_target,
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

    exe.root_module.linkLibrary(sokol_clib);
    exe.root_module.link_libc = true;
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.linkFramework("UIKit", .{});
    exe.root_module.linkFramework("Metal", .{});
    exe.root_module.linkFramework("MetalKit", .{});
    exe.root_module.linkFramework("AudioToolbox", .{});
    exe.root_module.linkFramework("AVFoundation", .{});
    exe.root_module.linkFramework("QuartzCore", .{});
    exe.root_module.linkFramework("GameController", .{});

    // post_wire (design §4) — iOS SDK include/lib/framework paths.
    backend_build_hook.post_wire(b, .{
        .manifest_version = 2,
        .backend_dep = backend_dep,
        .root_module = exe.root_module,
        .root_artifact = exe,
        .target = ios_target,
        .optimize = optimize,
        .platform = .ios,
        .ios_sdk_path = sdk_path,
        .android_target_sdk = null,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Build for iOS");
    run_step.dependOn(&exe.step);
}

/// Override a module import without leaking memory.
/// NOTE: Duplicated from .footer — each generated build.zig is standalone and
/// needs its own copy of this helper.
fn overrideImport(m: *std.Build.Module, name: []const u8, module: *std.Build.Module) void {
    const gop = m.import_table.getOrPut(m.owner.allocator, name) catch @panic("OOM");
    if (!gop.found_existing) {
        gop.key_ptr.* = name;
    }
    gop.value_ptr.* = module;
}

/// Unify `labelle-core` onto gfx's sub-packages (`camera`, `spatial_grid`,
/// `tilemap`) so a `core.YAxis` (and any other core type) produced inside the
/// `labelle-gfx` module unifies with the type the sub-package expects. gfx#276
/// crosses this boundary by passing the project `y_axis` into
/// `camera.CameraWith(...)`. Only override sub-packages that actually import
/// core (a no-op otherwise — keeps this resilient if gfx restructures).
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
