const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wgpu_dep = b.dependency("wgpu_native_zig", .{ .target = target, .optimize = optimize });
    const zglfw_dep = b.dependency("zglfw", .{ .target = target, .optimize = optimize });

    const wgpu_mod = wgpu_dep.module("wgpu");
    const zglfw_mod = zglfw_dep.module("root");
    const glfw_artifact = zglfw_dep.artifact("glfw");

    // ── Gfx backend module ──────────────────────────────────────────
    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
    });
    gfx_mod.addImport("wgpu", wgpu_mod);

    // ── Input backend module ────────────────────────────────────────
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("zglfw", zglfw_mod);

    // ── Audio backend module ────────────────────────────────────────
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = audio_mod; // No native audio dep — uses miniaudio or stub

    // ── Window backend module ───────────────────────────────────────
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_mod.addImport("zglfw", zglfw_mod);
    window_mod.addImport("wgpu", wgpu_mod);

    // ── Re-export native artifacts so consumers can link them ───────
    b.installArtifact(glfw_artifact);

    // ── Unit tests for the pure WAV parser ─────────────────────────
    // `wav_parser.zig` has no native deps, so its test binary builds
    // on any host without needing wgpu's native artifacts. This is
    // the regression lock for #12 (integer overflow in the WAV
    // chunk walker).
    const host_target = b.resolveTargetQuery(.{});
    const wav_parser_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wav_parser.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run wgpu backend unit tests");
    test_step.dependOn(&b.addRunArtifact(wav_parser_tests).step);
}
