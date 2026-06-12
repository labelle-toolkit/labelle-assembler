const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `wgpu_native_zig` is `lazy = true` in build.zig.zon. Zig 0.16
    // enforces this strictly — calling `b.dependency` on a lazy dep
    // panics with "must use the lazyDependency function instead".
    // Switch to `b.lazyDependency` and only wire wgpu-dependent
    // imports when the dep is materialized.
    //
    // KNOWN BLOCKER (out of scope for #220, see PR body): upstream
    // `apotema/wgpu_native_zig` @ fb54d9c8 is itself not yet Zig 0.16
    // compatible. Its own `build.zig` calls `linkFramework`,
    // `addLibraryPath`, `addObjectFile` directly on `*Compile`, which
    // 0.16 moved onto `*Build.Module`. The 0.16 build-runner compiles
    // every transitive `build.zig` upfront, so any `zig build` (or
    // even `zig build --help`) errors out on those upstream sites
    // until the fork is rebased. This patch keeps the assembler-side
    // surface consistent with PR #218's sweep so the migration is
    // ready to merge as soon as upstream catches up.
    const wgpu_dep_opt = b.lazyDependency("wgpu_native_zig", .{ .target = target, .optimize = optimize });
    const zglfw_dep = b.dependency("zglfw", .{ .target = target, .optimize = optimize });

    const wgpu_mod_opt: ?*std.Build.Module = if (wgpu_dep_opt) |d| d.module("wgpu") else null;
    const zglfw_mod = zglfw_dep.module("root");
    const glfw_artifact = zglfw_dep.artifact("glfw");

    // ── Gfx backend module ──────────────────────────────────────────
    // `link_libc = true` so the legacy `loadTexture` path-based loader
    // can call libc `fopen` / `fread` / `fclose`. See the rationale
    // block above `loadTexture` in src/gfx.zig.
    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (wgpu_mod_opt) |m| gfx_mod.addImport("wgpu", m);

    // ── Input backend module ────────────────────────────────────────
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("zglfw", zglfw_mod);

    // ── Audio backend module ────────────────────────────────────────
    // `link_libc = true` so the legacy `loadWav` path-based loader can
    // call libc `fopen` / `fread` / `fclose`. See the rationale block
    // above `loadWav` in src/audio.zig.
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    _ = audio_mod; // No native audio dep — uses miniaudio or stub

    // ── Window backend module ───────────────────────────────────────
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_mod.addImport("zglfw", zglfw_mod);
    if (wgpu_mod_opt) |m| window_mod.addImport("wgpu", m);
    // window.zig hands the created GLFW window to the input module
    // (`input.setWindow`) and pumps `input.newFrame()` per frame.
    window_mod.addImport("input", input_mod);
    // The render submitter in window.zig drains gfx.zig's shape batch
    // (consumeShapeBatch) and routes drawText into it.
    window_mod.addImport("gfx", gfx_mod);

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
