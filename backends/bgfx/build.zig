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
    // `link_libc = true` is required by `src/gfx/texture.zig`'s
    // libc-based file loader (post-0.16 swap from `std.fs.cwd()`).
    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
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
    // `link_libc = true` is required by `src/audio.zig`'s libc-based
    // WAV file loader (post-0.16 swap from `std.fs.cwd()`) AND by
    // miniaudio (its CoreAudio/ALSA/WASAPI backends are C and need the
    // C runtime).
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // ── miniaudio playback device (#297) ────────────────────────────
    // Compile miniaudio's implementation translation unit straight into
    // the audio module. `src/audio.zig` opens an `ma_device` in its
    // `ensureInit` lifecycle hook and drives the PCM mixer from the
    // device's data callback. Zig 0.16 moved `addCSourceFile` /
    // `addIncludePath` / `linkFramework` onto `*Build.Module`.
    audio_mod.addIncludePath(b.path("libs/miniaudio"));
    audio_mod.addCSourceFile(.{
        .file = b.path("libs/miniaudio/miniaudio.c"),
        .flags = &.{"-std=c99"},
    });
    // miniaudio's native backends need platform system libraries. Gate
    // them on the target OS so the backend still builds for Linux /
    // Windows (and cross-compiles) instead of hard-linking macOS-only
    // frameworks everywhere. These propagate to any consumer that
    // imports the `audio` module (e.g. the example exe), so the
    // example links them transitively without restating them.
    switch (target.result.os.tag) {
        .macos => {
            audio_mod.linkFramework("CoreAudio", .{});
            audio_mod.linkFramework("AudioToolbox", .{});
            audio_mod.linkFramework("CoreFoundation", .{});
        },
        .linux => {
            // miniaudio dlopen()s the ALSA/PulseAudio shared libs at
            // runtime, so only libdl/pthread/m are required at link
            // time (libc above covers pthread on glibc).
            audio_mod.linkSystemLibrary("dl", .{});
            audio_mod.linkSystemLibrary("pthread", .{});
            audio_mod.linkSystemLibrary("m", .{});
        },
        .windows => {
            // WASAPI/DirectSound are reached via Ole32 + the standard
            // Win32 libs; miniaudio loads the rest at runtime.
            audio_mod.linkSystemLibrary("ole32", .{});
            audio_mod.linkSystemLibrary("user32", .{});
        },
        else => {},
    }

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

    // ── Audio backend tests ─────────────────────────────────────────
    // Build + run the audio module's unit tests (spinlock, mixer, WAV
    // decode, unload ordering). The module carries miniaudio's C source,
    // include path, libc, and the per-OS framework/system-lib links, so
    // the test binary links the real device backend even though the
    // tests themselves never open a device. Run on the host (these are
    // executable native tests, not a cross-compile compile-check).
    const audio_tests = b.addTest(.{ .root_module = audio_mod });
    test_step.dependOn(&b.addRunArtifact(audio_tests).step);
}
