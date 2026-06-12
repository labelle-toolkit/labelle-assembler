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

    // ── Android: feed bgfx's C/C++ the NDK sysroot headers ──────────
    // Zig's bundled libc++ `stdlib.h` pulls in `ldiv_t`/`lldiv` from the
    // *system* C `stdlib.h`, which lives in the Android NDK sysroot — not
    // in Zig's tree. Without these include paths bx/bgfx/bimg fail to
    // compile for Android (`unknown type name 'ldiv_t'`). Mirror the
    // sokol-Android plumbing in `src/templates/build_zig.txt`. Gated on
    // the Android ABI so desktop/cross builds are untouched. zglfw is
    // desktop-only, so this is phase 1 of bgfx-on-Android (#300) — the
    // glfw artifact + zglfw-dependent install is skipped below for
    // Android so we can prove the bgfx/bx/bimg C++ compiles in isolation.
    const is_android = target.result.os.tag == .linux and
        (target.result.abi == .android or target.result.abi == .androideabi);
    if (is_android) {
        const ndk_sysroot = getAndroidNdkSysroot(b) orelse
            @panic("Could not find Android NDK. Set ANDROID_NDK_HOME or ANDROID_HOME.");
        const ndk_arch_triple: []const u8 = switch (target.result.cpu.arch) {
            .aarch64 => "aarch64-linux-android",
            .x86_64 => "x86_64-linux-android",
            .arm => "arm-linux-androideabi",
            .x86 => "i686-linux-android",
            else => @panic("unsupported Android arch for bgfx"),
        };
        // Match the toolkit's default Android min_sdk (28, see
        // `src/config.zig`). Must be >= 23: bx's `file.cpp` references
        // `stdout`/`stderr`, which Bionic exposes as real symbols only
        // from API 23 (below that they alias `__sF[]`, marked
        // `__REMOVED_IN(23)` and rejected by clang availability).
        const android_api = "28";
        const inc_common = b.pathJoin(&.{ ndk_sysroot, "usr/include" });
        const inc_arch = b.pathJoin(&.{ ndk_sysroot, "usr/include", ndk_arch_triple });
        const lib_path = b.pathJoin(&.{ ndk_sysroot, "usr/lib", ndk_arch_triple, android_api });

        // zbgfx builds three separate static libs — `bx`, `bimg`, and
        // `bgfx` — each its own `*Compile` with its own `root_module`.
        // The consumer can only fetch the top-level `bgfx` artifact, but
        // bx/bimg are linked into it as `other_step` link objects. Walk
        // bgfx's link_objects to reach them, then apply the NDK sysroot
        // paths to every C/C++ module so all three find the Bionic
        // headers. (Include paths don't propagate across linkLibrary.)
        applyNdkSysroot(bgfx_artifact.root_module, inc_common, inc_arch, lib_path, android_api);
        for (bgfx_artifact.root_module.link_objects.items) |lo| {
            if (lo == .other_step) {
                applyNdkSysroot(lo.other_step.root_module, inc_common, inc_arch, lib_path, android_api);
            }
        }
    }

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

    // ── Android phase-1 isolation (#300) ────────────────────────────
    // The input/window modules + the glfw artifact depend on zglfw,
    // which is desktop-only (Android wiring is phase 2, #301). For an
    // Android target we install ONLY the bgfx artifact so the verifier
    // proves bx/bgfx/bimg compile cleanly, and skip everything that
    // would drag in zglfw. Desktop builds fall through unchanged.
    if (is_android) {
        b.installArtifact(bgfx_artifact);
        return;
    }

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
    // Compile miniaudio's implementation translation unit + its per-OS
    // system libs straight into the audio module (see `wireMiniaudio`).
    // `src/audio.zig` opens an `ma_device` in its `ensureInit` lifecycle
    // hook and drives the PCM mixer from the device's data callback. The
    // links propagate to any consumer that imports the `audio` module
    // (e.g. the example exe), so the example links them transitively.
    wireMiniaudio(b, audio_mod, target.result.os.tag);

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
    // decode, unload ordering). These RUN (they exercise the spinlock /
    // mixer logic), so the test module is pinned to `host_target` rather
    // than the build's `-Dtarget` — otherwise `zig build test
    // -Dtarget=<foreign>` would try to execute a foreign binary and fail
    // (same reasoning as `platform_tests`). It carries the same miniaudio
    // C source + host system libs so it links the real device backend,
    // even though the tests never open a device.
    const audio_test_mod = b.createModule(.{
        .root_source_file = b.path("src/audio.zig"),
        .target = host_target,
        .optimize = optimize,
        .link_libc = true,
    });
    wireMiniaudio(b, audio_test_mod, host_target.result.os.tag);
    const audio_tests = b.addTest(.{ .root_module = audio_test_mod });
    test_step.dependOn(&b.addRunArtifact(audio_tests).step);
}

/// Attach miniaudio's implementation TU + include path, and link the
/// per-OS system libraries its native backends need, to `mod`. Gated on
/// `os_tag` so the backend still builds for Linux / Windows (and
/// cross-compiles) instead of hard-linking macOS-only frameworks.
fn wireMiniaudio(b: *std.Build, mod: *std.Build.Module, os_tag: std.Target.Os.Tag) void {
    mod.addIncludePath(b.path("libs/miniaudio"));
    mod.addCSourceFile(.{
        .file = b.path("libs/miniaudio/miniaudio.c"),
        .flags = &.{"-std=c99"},
    });
    switch (os_tag) {
        .macos => {
            mod.linkFramework("CoreAudio", .{});
            mod.linkFramework("AudioToolbox", .{});
            mod.linkFramework("CoreFoundation", .{});
        },
        .linux => {
            // miniaudio dlopen()s the ALSA/PulseAudio shared libs at
            // runtime, so only libdl/pthread/m are needed at link time.
            mod.linkSystemLibrary("dl", .{});
            mod.linkSystemLibrary("pthread", .{});
            mod.linkSystemLibrary("m", .{});
        },
        .windows => {
            // WASAPI/DirectSound are reached via Ole32 + the standard
            // Win32 libs; miniaudio loads the rest at runtime.
            mod.linkSystemLibrary("ole32", .{});
            mod.linkSystemLibrary("user32", .{});
        },
        else => {},
    }
}

/// Add the Android NDK sysroot system-include paths, the arch/API
/// library path, and `__ANDROID_API__` to a single C/C++ module so its
/// translation units resolve the Bionic `<stdlib.h>` etc. that Zig's
/// bundled libc++ headers pull from the global namespace.
fn applyNdkSysroot(
    mod: *std.Build.Module,
    inc_common: []const u8,
    inc_arch: []const u8,
    lib_path: []const u8,
    android_api: []const u8,
) void {
    mod.addSystemIncludePath(.{ .cwd_relative = inc_common });
    mod.addSystemIncludePath(.{ .cwd_relative = inc_arch });
    mod.addLibraryPath(.{ .cwd_relative = lib_path });
    // bgfx + Bionic both gate Android-version behavior on __ANDROID_API__.
    mod.addCMacro("__ANDROID_API__", android_api);
    // Android .so consumers need PIC in every archived .o (see #147).
    mod.pic = true;
}

/// Locate the Android NDK sysroot, mirroring the sokol-Android path in
/// `src/templates/build_zig.txt`. Checks `ANDROID_NDK_HOME` first, then
/// `ANDROID_HOME/ndk/<latest>`. Returns null if neither resolves to an
/// existing sysroot.
///
/// Env lookups go through `b.graph.environ_map.get` and filesystem
/// checks through `std.Io.Dir.cwd().access(io, ...)` — Zig 0.16 removed
/// `std.process.getEnvVarOwned`, `std.posix.getenv`, and `std.fs.cwd()`.
fn getAndroidNdkSysroot(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    // 1. ANDROID_NDK_HOME env var
    if (b.graph.environ_map.get("ANDROID_NDK_HOME")) |ndk_home| {
        const sysroot = b.pathJoin(&.{ ndk_home, "toolchains", "llvm", "prebuilt", ndkHostTag(), "sysroot" });
        if (std.Io.Dir.cwd().access(io, sysroot, .{})) |_| {
            return sysroot;
        } else |_| {}
    }
    // 2. ANDROID_HOME/ndk/<latest>/
    if (b.graph.environ_map.get("ANDROID_HOME")) |home| {
        const ndk_dir = b.pathJoin(&.{ home, "ndk" });
        var dir = std.Io.Dir.cwd().openDir(io, ndk_dir, .{ .iterate = true }) catch return null;
        defer dir.close(io);
        var latest: ?[]const u8 = null;
        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind == .directory) {
                if (latest) |prev| {
                    if (std.mem.order(u8, entry.name, prev) == .gt) {
                        b.allocator.free(prev);
                        latest = b.allocator.dupe(u8, entry.name) catch null;
                    }
                } else {
                    latest = b.allocator.dupe(u8, entry.name) catch null;
                }
            }
        }
        if (latest) |version| {
            defer b.allocator.free(version);
            const sysroot = b.pathJoin(&.{ ndk_dir, version, "toolchains", "llvm", "prebuilt", ndkHostTag(), "sysroot" });
            if (std.Io.Dir.cwd().access(io, sysroot, .{})) |_| {
                return sysroot;
            } else |_| {}
        }
    }
    return null;
}

fn ndkHostTag() []const u8 {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .linux => "linux-x86_64",
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };
}
