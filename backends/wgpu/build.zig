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

    // Shared audio engine (pluggable-backends RFC, Phase 2). `src/audio.zig`
    // now forwards to `labelle_audio.Mixer(NullSink)` — wgpu has no real OS
    // device, so it injects the shared `NullSink` and pumps the i16 mix manually
    // via `mixOutput`. Wired into the `audio` module (and the host audio test
    // module) under the `labelle-audio` import key. The mixer/decoder are pure
    // Zig, so this resolves on every target.
    const labelle_audio_dep = b.dependency("labelle_audio", .{ .target = target, .optimize = optimize });
    const labelle_audio_mod = labelle_audio_dep.module("labelle-audio");

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
    // `link_libc = true` so the path-based `loadSound`/`loadMusic` shim can
    // call libc `fopen` / `fread` / `fclose`. See the rationale block above
    // `readFileBytes` in src/audio.zig.
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Shared WAV decode + PCM mixer (Phase 2). `audio.zig` instantiates
    // `labelle_audio.Mixer(NullSink)` and forwards every public fn to it.
    // wgpu has no native audio device dep — the mix is software-pumped.
    audio_mod.addImport("labelle-audio", labelle_audio_mod);

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

    // ── Audio adapter smoke tests ──────────────────────────────────
    // The WAV decode / mixer / spinlock / UAF behaviour now lives in (and is
    // tested by) `labelle-audio` — the #12 overflow regression lock moved with
    // the parser into `labelle-audio/src/wav.zig`. These thin tests confirm the
    // wgpu adapter wires the shared `Mixer(NullSink)` correctly (the f32
    // `mixOutput` shim). They RUN (NullSink needs no device), so the test
    // module is pinned to `host_target`. The shared mixer is pure Zig, so it
    // resolves for the host without any native audio dep.
    const host_target = b.resolveTargetQuery(.{});
    const audio_test_mod = b.createModule(.{
        .root_source_file = b.path("src/audio.zig"),
        .target = host_target,
        .optimize = optimize,
        .link_libc = true,
    });
    const labelle_audio_host_dep = b.dependency("labelle_audio", .{ .target = host_target, .optimize = optimize });
    audio_test_mod.addImport("labelle-audio", labelle_audio_host_dep.module("labelle-audio"));
    const audio_tests = b.addTest(.{ .root_module = audio_test_mod });

    // ── Unit tests for the CPU image decoders (PNG/BMP/TGA) ─────────
    // gfx.zig only imports `std` (the `wgpu` import is gated behind the
    // native artifact and unused by the decode path), so its decode
    // tests build on any host. `link_libc = true` resolves the libc
    // FILE externs used by the legacy `loadTexture` path-loader.
    const gfx_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gfx.zig"),
            .target = host_target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // ── ASTC container-parsing tests (#341) ─────────────────────────
    // `gfx/astc.zig` is pure byte parsing with no wgpu dependency, so it
    // EXECUTES on the host (magic detection, block/image dims, ceil-to-block
    // payload sizing, truncation) — a verbatim port of the bgfx backend's
    // astc_run target. The wgpu-side seam tests (isCompressed /
    // uploadCompressed / getCompressedTexture) ride in `gfx_tests` above,
    // since they live in `gfx/texture.zig`.
    const astc_run = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gfx/astc.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run wgpu backend unit tests");
    test_step.dependOn(&b.addRunArtifact(audio_tests).step);
    test_step.dependOn(&b.addRunArtifact(gfx_tests).step);
    test_step.dependOn(&b.addRunArtifact(astc_run).step);

    // ── Compile-check window.zig ────────────────────────────────────
    // window.zig owns the GLFW window lifecycle + the fullscreen toggle
    // (GLFW setMonitor → wgpu surface reconfigure). It references
    // `wgpu.SurfaceConfiguration`, so it only compiles when the native
    // wgpu dep is materialized. Gate the compile-check on the lazy dep so
    // hosts without the wgpu artifact still build the rest of the test
    // step; depend on the compile step (not a run step) so it works under
    // cross-compilation where the produced binary can't be executed.
    if (wgpu_mod_opt != null) {
        const window_tests = b.addTest(.{ .root_module = window_mod });
        test_step.dependOn(&window_tests.step);
    }
}
