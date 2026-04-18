const std = @import("std");

/// Null backend — headless test/CI backend with no graphics, audio, input,
/// or window subsystem. Every backend module exports the same surface area
/// the engine expects, but every operation is a silent no-op.
///
/// Use case: lifecycle / integration / determinism tests that don't exercise
/// rendering. The generated `main()` runs the tick loop for a bounded number
/// of frames (controlled by the LABELLE_NULL_FRAMES env var, default 5),
/// then exits cleanly. Removes the xvfb dependency for headless Linux CI.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Gfx backend module ──────────────────────────────────────────
    _ = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Input backend module ────────────────────────────────────────
    _ = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Audio backend module ────────────────────────────────────────
    _ = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Window backend module ───────────────────────────────────────
    _ = b.addModule("window", .{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Smoke tests for the no-op backend modules ──────────────────
    // Each module's import surface is exercised by a unit test so a
    // future change to the engine's contract is caught here rather
    // than only at link time inside a generated game binary.
    const test_step = b.step("test", "Run null backend unit tests");
    inline for (.{ "src/gfx.zig", "src/input.zig", "src/audio.zig", "src/window.zig" }) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
