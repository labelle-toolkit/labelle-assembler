const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The fully-wired `sdl_gamepad` module (labelle_core already imported).
    const gp_dep = b.dependency("labelle_sdl_gamepad", .{ .target = target, .optimize = optimize });
    const gp_mod = gp_dep.module("sdl_gamepad");

    const exe = b.addExecutable(.{
        .name = "gamepad_sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sdl_gamepad", .module = gp_mod },
            },
        }),
    });
    exe.root_module.link_libc = true;

    // Same SDL2 discovery mechanism as the sokol/raylib backends on Windows.
    if (b.graph.environ_map.get("LABELLE_SDL2_LIB")) |p| {
        exe.root_module.addLibraryPath(.{ .cwd_relative = p });
    }
    exe.root_module.linkSystemLibrary("SDL2", .{});

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the gamepad simulator harness");
    run_step.dependOn(&run.step);

    // ── Live monitor: reads the toolkit Source, creates no device of its own.
    const monitor = b.addExecutable(.{
        .name = "gamepad_monitor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/monitor.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sdl_gamepad", .module = gp_mod },
            },
        }),
    });
    monitor.root_module.link_libc = true;
    if (b.graph.environ_map.get("LABELLE_SDL2_LIB")) |p| {
        monitor.root_module.addLibraryPath(.{ .cwd_relative = p });
    }
    monitor.root_module.linkSystemLibrary("SDL2", .{});
    b.installArtifact(monitor);

    const run_monitor = b.addRunArtifact(monitor);
    if (b.args) |args| run_monitor.addArgs(args);
    const monitor_step = b.step("monitor", "Watch a real controller through the toolkit Source");
    monitor_step.dependOn(&run_monitor.step);

    // ── Raw-SDL diagnostic probe (no toolkit wrapper). ──────────────────
    const probe = b.addExecutable(.{
        .name = "gamepad_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    probe.root_module.link_libc = true;
    if (b.graph.environ_map.get("LABELLE_SDL2_LIB")) |p| {
        probe.root_module.addLibraryPath(.{ .cwd_relative = p });
    }
    probe.root_module.linkSystemLibrary("SDL2", .{});
    b.installArtifact(probe);
}
