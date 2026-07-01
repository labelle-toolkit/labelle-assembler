const std = @import("std");

const backend_build_hook = @import("backend_build_hook.zig");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // resolve_target (design §4) — the backend hook picks the android ABI
    // from -Demulator/-Dandroid_arch + host arch, BEFORE any b.dependency.
    const android_target = backend_build_hook.resolve_target(b, .{ .platform = .android }).target;

    const core_dep = b.dependency("labelle_core", .{ .target = android_target, .optimize = optimize });
    const core_mod = core_dep.module("labelle-core");

    const gfx_dep = b.dependency("labelle_gfx", .{ .target = android_target, .optimize = optimize });
    const gfx_mod = gfx_dep.module("labelle-gfx");

    const engine_dep = b.dependency("engine", .{ .target = android_target, .optimize = optimize });
    const engine_mod = engine_dep.module("engine");

    // `game` module — see labelle-assembler#116. Android-targeted variant.
    const game_mod = b.createModule(.{
        .root_source_file = b.path("game.zig"),
        .target = android_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "labelle-engine", .module = engine_mod },
        },
    });

    const backend_dep = b.dependency("labelle_bgfx", .{ .target = android_target, .optimize = optimize, .gui_enabled = false });
    const backend_gfx = backend_dep.module("gfx");
    const backend_input = backend_dep.module("input");
    const backend_audio = backend_dep.module("audio");
    const backend_window = backend_dep.module("window");
    const backend_app = backend_dep.module("android_app");
    const bgfx = backend_dep.artifact("bgfx");

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
    unifyCoreDiamond(b.allocator, backend_app, core_mod, gfx_mod, &core_diamond_visited);
    const lib = b.addLibrary(.{
        .name = "game",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = android_target,
            .optimize = optimize,
            .pic = true,
            .imports = &.{
                .{ .name = "labelle-core", .module = core_mod },
                .{ .name = "labelle-gfx", .module = gfx_mod },
                .{ .name = "labelle-engine", .module = engine_mod },
                .{ .name = "backend_gfx", .module = backend_gfx },
                .{ .name = "backend_input", .module = backend_input },
                .{ .name = "backend_audio", .module = backend_audio },
                .{ .name = "backend_window", .module = backend_window },

                .{ .name = "game", .module = game_mod },

                .{ .name = "backend_app", .module = backend_app },

            },
        }),
    });

    lib.root_module.linkLibrary(bgfx);
    lib.root_module.link_libc = true;
    lib.root_module.linkSystemLibrary("android", .{});
    lib.root_module.linkSystemLibrary("log", .{});
    lib.root_module.linkSystemLibrary("EGL", .{});
    lib.root_module.linkSystemLibrary("GLESv3", .{});
    lib.root_module.linkSystemLibrary("m", .{});
    lib.root_module.linkSystemLibrary("dl", .{});
    lib.root_module.linkSystemLibrary("mediandk", .{});
    lib.root_module.linkSystemLibrary("aaudio", .{});

    // post_wire (design §4) — NDK sysroot include/lib paths + libc.txt.
    backend_build_hook.post_wire(b, .{
        .manifest_version = 2,
        .backend_dep = backend_dep,
        .root_module = lib.root_module,
        .root_artifact = lib,
        .target = android_target,
        .optimize = optimize,
        .platform = .android,
        .ios_sdk_path = null,
        .android_target_sdk = 34,
    });
    // ── APK packaging step ──────────────────────────────────────────────
    // Copies the freshly built libgame.so into apk-staging and re-signs the APK.
    // Requires ANDROID_HOME and ~/.labelle/android-debug.keystore.
    {
        const io = b.graph.io;
        // ANDROID_HOME is read lazily — a missing value only fails when `zig build package` runs.
        const android_home = b.graph.environ_map.get("ANDROID_HOME") orelse "";
        const home = b.graph.environ_map.get("HOME") orelse
            b.graph.environ_map.get("USERPROFILE") orelse "";
        const keystore = b.pathJoin(&.{ if (home.len > 0) home else "/tmp", ".labelle", "android-debug.keystore" });

        // Find build-tools: prefer newest, then fall back
        const build_tools_dir = blk: {
            for (&[_][]const u8{ "36.0.0", "35.0.1", "35.0.0", "34.0.0" }) |ver| {
                const p = b.pathJoin(&.{ android_home, "build-tools", ver });
                if (std.Io.Dir.cwd().access(io, p, .{})) |_| break :blk p else |_| {}
            }
            break :blk b.pathJoin(&.{ android_home, "build-tools", "35.0.0" });
        };
        const apksigner = b.pathJoin(&.{ build_tools_dir, "apksigner" });

        // Derive ABI directory from the actual build target so emulator (x86_64) and device (arm64) both work.
        const abi_dir: []const u8 = switch (android_target.result.cpu.arch) {
            .aarch64 => "arm64-v8a",
            .x86_64  => "x86_64",
            .arm     => "armeabi-v7a",
            .x86     => "x86",
            else     => "arm64-v8a",
        };
        // "../apk-staging/..." installs relative to zig-out/, resolving to {project_root}/apk-staging/.
        const stage_lib = b.addInstallFile(lib.getEmittedBin(), b.fmt("../apk-staging/lib/{s}/libgame.so", .{abi_dir}));
        stage_lib.step.dependOn(&lib.step);

        // Repack APK from staging dir
        const pack = b.addSystemCommand(&.{ "sh", "-c",
            "cd \"$0\" && zip -r \"$1\" . -x '*.idsig'",
            b.pathFromRoot("apk-staging"),
            b.pathFromRoot("game_unsigned.apk"),
        });
        pack.step.dependOn(&stage_lib.step);

        // Sign
        const sign = b.addSystemCommand(&.{
            apksigner,        "sign",
            "--ks",           keystore,
            "--ks-pass",      "pass:android",
            "--key-pass",     "pass:android",
            "--min-sdk-version", "26",
            "--out",          b.pathFromRoot("game.apk"),
            b.pathFromRoot("game_unsigned.apk"),
        });
        sign.step.dependOn(&pack.step);

        const package_step = b.step("package", "Package and sign Android APK");
        package_step.dependOn(&sign.step);
    }

    b.installArtifact(lib);

    const run_step = b.step("run", "Build for Android");
    run_step.dependOn(&lib.step);
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
