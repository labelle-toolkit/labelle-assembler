const std = @import("std");

/// Re-export raylib-zig's emsdk helpers so consumers (generated build.zig) can
/// use emccStep / emrunStep for WASM builds without a direct raylib-zig dep.
pub const emsdk = @import("raylib-zig").emsdk;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib-zig", .{ .target = target, .optimize = optimize });

    const raylib_mod = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

    // ── Gfx backend module ──────────────────────────────────────────
    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
    });
    gfx_mod.addImport("raylib", raylib_mod);

    // ── Input backend module ────────────────────────────────────────
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("raylib", raylib_mod);

    // ── Audio backend module ────────────────────────────────────────
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_mod.addImport("raylib", raylib_mod);

    // ── Window backend module ───────────────────────────────────────
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_mod.addImport("raylib", raylib_mod);

    // ── Re-export the native artifact so consumers can link it ──────
    b.installArtifact(raylib_artifact);

    // ── Unit tests for the pure slot allocator ────────────────────
    // `slot_alloc.zig` has no raylib import, so its test binary
    // builds without pulling in the native raylib library. This is
    // the regression lock for #11 (slot-reuse after unload).
    const host_target = b.resolveTargetQuery(.{});
    const slot_alloc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/slot_alloc.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run raylib backend unit tests");
    test_step.dependOn(&b.addRunArtifact(slot_alloc_tests).step);
}
