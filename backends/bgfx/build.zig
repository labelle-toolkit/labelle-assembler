const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zbgfx_dep = b.dependency("zbgfx", .{ .target = target, .optimize = optimize });
    const zglfw_dep = b.dependency("zglfw", .{ .target = target, .optimize = optimize });

    const zbgfx_mod = zbgfx_dep.module("zbgfx");
    const zglfw_mod = zglfw_dep.module("root");
    const bgfx_artifact = zbgfx_dep.artifact("bgfx");
    const glfw_artifact = zglfw_dep.artifact("glfw");

    // ── Gfx backend module ──────────────────────────────────────────
    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
    });
    gfx_mod.addImport("zbgfx", zbgfx_mod);

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
    window_mod.addImport("zbgfx", zbgfx_mod);
    window_mod.addImport("input", input_mod);

    // ── Re-export native artifacts so consumers can link them ───────
    b.installArtifact(bgfx_artifact);
    b.installArtifact(glfw_artifact);

    // ── Unit tests for the platform-dispatch helper ─────────────────
    // Always build + run on the host — platform.zig is pure Zig with
    // no native deps, and pinning to the host keeps the tests
    // executable under `-Dtarget=...` cross-compilation of the rest
    // of the backend.
    const host_target = b.resolveTargetQuery(.{});
    const platform_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run bgfx backend unit tests");
    test_step.dependOn(&b.addRunArtifact(platform_tests).step);

    // ── Compile-check window.zig ────────────────────────────────────
    // window.zig does the real comptime dispatch on builtin.target.os.tag,
    // so compiling it with `-Dtarget=<os>` is the only way to catch
    // branches that don't build for a given OS. Forcing a test binary
    // off window_mod pulls the full module graph (zbgfx + zglfw + input)
    // into the build and errors on any per-OS breakage.
    //
    // Depend on the *compile* step, not a run step — we want this to
    // work under cross-compilation (`-Dtarget=x86_64-windows-gnu`,
    // etc.) where the host can't execute the produced binary.
    const window_tests = b.addTest(.{ .root_module = window_mod });
    test_step.dependOn(&window_tests.step);
}
