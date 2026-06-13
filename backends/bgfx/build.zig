const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const is_android = target.result.os.tag == .linux and
        (target.result.abi == .android or target.result.abi == .androideabi);

    const zbgfx_dep = b.dependency("zbgfx", .{ .target = target, .optimize = optimize });
    const zbgfx_mod = zbgfx_dep.module("zbgfx");
    const bgfx_artifact = zbgfx_dep.artifact("bgfx");

    // zglfw is desktop-only — it doesn't build for Android. Only fetch
    // the zglfw dependency (and its artifact) off the Android path so the
    // Android build graph never pulls it in. The window/input modules are
    // wired without the `zglfw` import for Android (they comptime-gate it
    // out; see src/window.zig + src/input.zig).
    const zglfw_dep = if (is_android) null else b.dependency("zglfw", .{ .target = target, .optimize = optimize });
    const zglfw_mod = if (zglfw_dep) |d| d.module("root") else null;
    const glfw_artifact = if (zglfw_dep) |d| d.artifact("glfw") else null;

    // ── Android: feed bgfx's C/C++ the NDK sysroot headers ──────────
    // Zig's bundled libc++ `stdlib.h` pulls in `ldiv_t`/`lldiv` from the
    // *system* C `stdlib.h`, which lives in the Android NDK sysroot — not
    // in Zig's tree. Without these include paths bx/bgfx/bimg fail to
    // compile for Android (`unknown type name 'ldiv_t'`). Mirror the
    // sokol-Android plumbing in `src/templates/build_zig.txt`. Gated on
    // the Android ABI so desktop/cross builds are untouched.
    //
    // The same `usr/include` path also exposes `android/native_window.h`
    // (for `ANativeWindow`) — phase 3 will compile the NativeActivity
    // glue against it. Phase 2 only needs the Zig modules to compile, and
    // they hand the surface across as an opaque `*anyopaque` (see
    // src/window.zig), so no C header is pulled in yet.
    //
    // `ndk` is non-null only for Android; the resolved sysroot include
    // paths are reused below to wire the Android gfx/window/input modules.
    const ndk: ?NdkPaths = if (is_android) resolveNdkPaths(b, target) else null;
    if (ndk) |n| {
        // zbgfx builds three separate static libs — `bx`, `bimg`, and
        // `bgfx` — each its own `*Compile` with its own `root_module`.
        // The consumer can only fetch the top-level `bgfx` artifact, but
        // bx/bimg are linked into it as `other_step` link objects. Walk
        // bgfx's link_objects to reach them, then apply the NDK sysroot
        // paths to every C/C++ module so all three find the Bionic
        // headers. (Include paths don't propagate across linkLibrary.)
        applyNdkSysroot(bgfx_artifact.root_module, n.inc_common, n.inc_arch, n.lib_path, n.android_api);
        for (bgfx_artifact.root_module.link_objects.items) |lo| {
            if (lo == .other_step) {
                applyNdkSysroot(lo.other_step.root_module, n.inc_common, n.inc_arch, n.lib_path, n.android_api);
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

    // ── Input backend module ────────────────────────────────────────
    // Desktop wires the `zglfw` import for GLFW polling; Android omits it
    // (zglfw is desktop-only) and `src/input.zig` comptime-gates every
    // zglfw reference behind `is_android`, stubbing input until the
    // touch path lands in phase 3 (#302).
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (zglfw_mod) |m| input_mod.addImport("zglfw", m);

    // ── Audio backend module ────────────────────────────────────────
    // `link_libc = true` is required by `src/audio.zig`'s libc-based
    // WAV file loader (post-0.16 swap from `std.fs.cwd()`) AND by
    // miniaudio (its CoreAudio/ALSA/WASAPI backends are C and need the
    // C runtime).
    //
    // Android audio (AAudio/OpenSL) is out of phase-2 scope — this phase
    // brings up gfx/window/input only (#301). Skip the audio module on
    // Android so miniaudio's implementation TU isn't dragged into the
    // Android build; it returns to the AAudio backend in a later phase.
    if (!is_android) {
        const audio_mod = b.addModule("audio", .{
            .root_source_file = b.path("src/audio.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

        // ── miniaudio playback device (#297) ────────────────────────
        // Compile miniaudio's implementation translation unit + its
        // per-OS system libs straight into the audio module (see
        // `wireMiniaudio`). `src/audio.zig` opens an `ma_device` in its
        // `ensureInit` lifecycle hook and drives the PCM mixer from the
        // device's data callback. The links propagate to any consumer
        // that imports the `audio` module (e.g. the example exe), so the
        // example links them transitively.
        wireMiniaudio(b, audio_mod, target.result.os.tag);
    }

    // ── Window backend module ───────────────────────────────────────
    // Desktop gets the `zglfw` import (GLFW lifecycle + native handle).
    // Android omits it: `src/window.zig` comptime-gates the GLFW path out
    // and instead reads an `ANativeWindow*` (handed over via
    // `setAndroidNativeWindow`) into `PlatformData.nwh` at bgfx init.
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (zglfw_mod) |m| window_mod.addImport("zglfw", m);
    window_mod.addImport("zbgfx", zbgfx_mod);
    window_mod.addImport("input", input_mod);

    // ── Re-export native artifacts so consumers can link them ───────
    // bgfx is always re-exported. glfw is desktop-only (Android has no
    // zglfw artifact), so only install it off the Android path.
    b.installArtifact(bgfx_artifact);
    if (glfw_artifact) |a| b.installArtifact(a);

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

    // ── Compile-check window.zig (+ input.zig via its import) ───────
    // window.zig does the real comptime dispatch on builtin.target — both
    // the per-OS desktop branches and the Android `is_android` path — so
    // compiling it with `-Dtarget=<os>` is the only way to catch branches
    // that don't build for a given target. Forcing a test binary off
    // window_mod pulls the full module graph (zbgfx + input, plus zglfw on
    // desktop) into the build and errors on any per-target breakage. For
    // `-Dtarget=aarch64-linux-android` this is the vehicle that proves
    // window/input compile with NO zglfw in the graph.
    //
    // Depend on the *compile* step, not a run step — we want this to
    // work under cross-compilation (`-Dtarget=x86_64-windows-gnu`,
    // `-Dtarget=aarch64-linux-android`, etc.) where the host can't
    // execute the produced binary.
    const window_tests = b.addTest(.{ .root_module = window_mod });
    test_step.dependOn(&window_tests.step);

    // ── Compile-check gfx.zig for the build target ──────────────────
    // gfx.zig imports only zbgfx (no zglfw), so it already compiled for
    // Android in phase 1 implicitly — but nothing in the test graph
    // forced it. Add an explicit compile-check so `zig build test
    // -Dtarget=aarch64-linux-android` covers all three Android modules
    // (gfx/window/input) as required by phase 2.
    const gfx_tests = b.addTest(.{ .root_module = gfx_mod });
    test_step.dependOn(&gfx_tests.step);

    // ── Android app-shell module (NativeActivity glue) ──────────────
    // Phase 3 (#302): the hand-rolled NativeActivity entry that sokol
    // hides inside sokol_app. Built ONLY for Android — it's the runtime
    // glue that drives the ANativeWindow surface (phases 1–2 plumbed) and
    // feeds touch into `input`. It compiles the NDK's
    // `android_native_app_glue.c` (which provides the app thread + looper
    // + `ANativeActivity_onCreate`) and exports our `android_main`.
    //
    // We build it as its OWN object compile-check rather than wiring it
    // into the gfx/window/input modules: the full `.so` link (EGL /
    // GLESv3 / libandroid / liblog) is phase 4 (#303), so here we only
    // prove the module + glue + touch wiring COMPILE for
    // aarch64-linux-android. The android libs the shell references
    // (`android`, `log`) are declared on the module so they're recorded
    // for the eventual link, but we depend on the *compile* step (object
    // emission), never a run/link step that would demand those libs be
    // present on the host.
    if (ndk) |n| {
        const android_app_mod = b.addModule("android_app", .{
            .root_source_file = b.path("src/android_app.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        // android_app drives window + input directly.
        android_app_mod.addImport("window", window_mod);
        android_app_mod.addImport("input", input_mod);
        android_app_mod.addImport("zbgfx", zbgfx_mod);

        // Vendor the NDK's native_app_glue: its include dir (for
        // <android_native_app_glue.h>) and its single C TU. The glue needs
        // the Bionic headers (android/native_window.h, looper.h, input.h),
        // which the NDK sysroot supplies — apply the same sysroot wiring
        // bgfx/bx/bimg use.
        applyNdkSysroot(android_app_mod, n.inc_common, n.inc_arch, n.lib_path, n.android_api);
        const glue_dir = androidNativeAppGlueDir(b) orelse
            @panic("Could not find native_app_glue in the NDK (sources/android/native_app_glue).");
        android_app_mod.addIncludePath(.{ .cwd_relative = glue_dir });
        android_app_mod.addCSourceFile(.{
            .file = .{ .cwd_relative = b.pathJoin(&.{ glue_dir, "android_native_app_glue.c" }) },
            .flags = &.{ "-std=c11", "-Wall" },
        });

        // Declare the android libs the shell references for the eventual
        // (phase-4) link. These are recorded on the module's link inputs;
        // the compile-check below depends only on object emission, so a
        // missing lib on the host can't break the build here.
        android_app_mod.linkSystemLibrary("android", .{});
        android_app_mod.linkSystemLibrary("log", .{});

        // Compile-check: a test binary off the android_app module pulls
        // the full graph (android_app + native_app_glue C + window/input,
        // no zglfw) and emits objects for aarch64-linux-android. We depend
        // on the *compile* step (`&t.step`), NOT a run step — the host
        // can't execute an aarch64-linux-android binary, and we explicitly
        // avoid a link that would need EGL/GLESv3 (phase 4).
        const android_app_tests = b.addTest(.{ .root_module = android_app_mod });
        test_step.dependOn(&android_app_tests.step);
    }

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

/// Resolved Android NDK sysroot include/library paths + API level for a
/// given target. Computed once in `build()` and threaded through
/// `applyNdkSysroot` for each C/C++ module that needs the Bionic headers.
const NdkPaths = struct {
    inc_common: []const u8,
    inc_arch: []const u8,
    lib_path: []const u8,
    android_api: []const u8,
};

/// Resolve the NDK sysroot paths for an Android `target`. Panics with an
/// actionable message if the NDK can't be found or the arch is
/// unsupported — the caller only invokes this when `is_android` is true.
fn resolveNdkPaths(b: *std.Build, target: std.Build.ResolvedTarget) NdkPaths {
    const ndk_sysroot = getAndroidNdkSysroot(b) orelse
        @panic("Could not find Android NDK. Set ANDROID_NDK_HOME or ANDROID_HOME.");
    const ndk_arch_triple: []const u8 = switch (target.result.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        .arm, .thumb => "arm-linux-androideabi",
        .x86 => "i686-linux-android",
        else => @panic("unsupported Android arch for bgfx"),
    };
    // Match the toolkit's default Android min_sdk (28, see
    // `src/config.zig`). Must be >= 23: bx's `file.cpp` references
    // `stdout`/`stderr`, which Bionic exposes as real symbols only from
    // API 23 (below that they alias `__sF[]`, marked `__REMOVED_IN(23)`
    // and rejected by clang availability).
    const android_api = "28";
    return .{
        .inc_common = b.pathJoin(&.{ ndk_sysroot, "usr/include" }),
        .inc_arch = b.pathJoin(&.{ ndk_sysroot, "usr/include", ndk_arch_triple }),
        .lib_path = b.pathJoin(&.{ ndk_sysroot, "usr/lib", ndk_arch_triple, android_api }),
        .android_api = android_api,
    };
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

/// Locate the NDK's `android_native_app_glue` source directory
/// (`<ndk>/sources/android/native_app_glue`), which ships
/// `android_native_app_glue.c` + `.h`. Resolves the NDK root the same way
/// `getAndroidNdkSysroot` does (ANDROID_NDK_HOME, then
/// ANDROID_HOME/ndk/<latest>) but returns the glue dir rather than the
/// sysroot. Returns null if it can't be found.
fn androidNativeAppGlueDir(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const rel = &.{ "sources", "android", "native_app_glue" };

    // 1. ANDROID_NDK_HOME
    if (b.graph.environ_map.get("ANDROID_NDK_HOME")) |ndk_home| {
        const dir = b.pathJoin(&.{ ndk_home, rel[0], rel[1], rel[2] });
        if (std.Io.Dir.cwd().access(io, dir, .{})) |_| return dir else |_| {}
    }

    // 2. ANDROID_HOME/ndk/<latest>
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
            const glue = b.pathJoin(&.{ ndk_dir, version, rel[0], rel[1], rel[2] });
            if (std.Io.Dir.cwd().access(io, glue, .{})) |_| return glue else |_| {}
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
