const std = @import("std");

/// Re-export sokol's emscripten linker helpers so consumers (generated build.zig)
/// can use emLinkStep for WASM builds without a direct sokol dep.
pub const EmLinkOptions = @import("sokol").EmLinkOptions;
pub const emLinkStep = @import("sokol").emLinkStep;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Forward dont_link_system_libs for iOS builds — we link frameworks manually.
    const dont_link_system_libs = b.option(bool, "dont_link_system_libs", "Don't link system libraries (for iOS cross-compilation)") orelse false;

    // Opt-in `with_sokol_imgui` switch — only the imgui-plugin path
    // needs sokol_imgui.c compiled. Forcing it on for every project
    // breaks no-gui builds because sokol_imgui.c `#include`s
    // `cimgui.h`, which only the imgui bridge provides on the include
    // path. WASM-without-imgui was the canonical regression
    // (`sokol_imgui.c:8:10: error: 'cimgui.h' file not found`); session
    // smoke testing surfaced it.
    //
    // IMPORTANT: when `with_imgui=true`, the option set passed here
    // MUST match `labelle-imgui/bridges/sokol/build.zig` exactly. Zig
    // keys each `b.dependency("sokol", .{...})` resolution by the
    // option set, so mismatched options produce *two* separately
    // compiled `sokol_clib` artifacts in the same binary — and
    // therefore two copies of the `_sg` static state. Symptom: sgl
    // draws land in the IOSurface pass but simgui draws don't
    // (different state machines). Symmetric option list = one
    // artifact = one `_sg` (labelle-assembler#140). The assembler's
    // generated build.zig flips `with_imgui` on only when the project
    // has the imgui plugin in its gui config.
    //
    // `with_sokol_imgui_no_app` stays unconditional on every target
    // EXCEPT Android because sokol-zig gates its cflag on the outer
    // `with_sokol_imgui` already — it's a harmless no-op when imgui is
    // off, and keeps the option set identical to the bridge's when
    // imgui is on. Android is the exception: the device runs sokol_app
    // natively (no headless preview), and the freshly-fetched sokol-zig
    // hasn't been patched with the option, so passing it trips
    // `error: invalid option: -Dwith_sokol_imgui_no_app`. The matching
    // skip in `labelle-imgui/bridges/sokol/build.zig` keeps the option
    // sets symmetric on Android too (still one `sokol_clib` artifact,
    // one `_sg`). See labelle-assembler#146.
    const with_imgui = b.option(bool, "with_imgui", "Build sokol with sokol_imgui (must match imgui bridge if used)") orelse false;
    const is_android = target.result.abi == .android or target.result.abi == .androideabi;
    const sokol_dep = if (is_android)
        b.dependency("sokol", .{
            .target = target,
            .optimize = optimize,
            .with_sokol_imgui = with_imgui,
            .dont_link_system_libs = dont_link_system_libs,
        })
    else
        b.dependency("sokol", .{
            .target = target,
            .optimize = optimize,
            .with_sokol_imgui = with_imgui,
            .with_sokol_imgui_no_app = true,
            .dont_link_system_libs = dont_link_system_libs,
        });
    const sokol_mod = sokol_dep.module("sokol");
    const sokol_clib = sokol_dep.artifact("sokol_clib");

    // ── Gfx backend module ──────────────────────────────────────────
    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gfx_mod.addImport("sokol", sokol_mod);
    gfx_mod.addIncludePath(b.path("src"));

    // When cross-compiling to wasm32-emscripten the C compile of
    // `stb_image_impl.c` cannot find `<stdlib.h>` / `<stdio.h>`
    // because Zig does not ship libc headers for `wasm32-emscripten`
    // — they live in emsdk's sysroot. Plumb the emsdk sysroot include
    // path into the gfx module BEFORE adding the C sources so the
    // build graph has it attached when the consuming Compile step
    // collects translation units. Gated on `.emscripten` so the
    // desktop / mobile builds remain untouched (labelle-cli#197,
    // labelle-assembler#141).
    //
    // Note: this MUST run before `addCSourceFile` below. In testing,
    // setting it after the addCSourceFile calls caused emcc to bail
    // with `'stdio.h' file not found`. Mirrors sokol-zig's pattern
    // in `mod_sokol_clib`'s setup.
    if (target.result.os.tag == .emscripten) {
        if (b.lazyDependency("emsdk", .{})) |emsdk_dep| {
            gfx_mod.addSystemIncludePath(emsdk_dep.path("upstream/emscripten/cache/sysroot/include"));
        }
    }

    gfx_mod.addCSourceFile(.{ .file = b.path("src/stb_image_impl.c"), .flags = &.{} });
    // Phase 4 font baker (labelle-engine#448). stb_truetype lives next
    // to stb_image and is compiled in the same way — single-header C
    // lib, separate `_impl.c` translation unit defining the
    // implementation macro.
    gfx_mod.addCSourceFile(.{ .file = b.path("src/stb_truetype_impl.c"), .flags = &.{} });

    // ── Input backend module ────────────────────────────────────────
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("sokol", sokol_mod);

    // Android gamepad DETECTION glue (labelle-assembler#248). The JNI
    // bridge calls into Android's InputManager to detect controller
    // hotplug/identity; labelle-core's `gamepad_source/android.zig` declares
    // the `extern fn labelle_android_gamepad_init/_shutdown` entry points
    // this file defines, and the `export fn labelle_android_on_device_*`
    // callbacks it invokes. The C TU is wrapped in `#ifdef __ANDROID__`, so
    // it emits an empty object on every other target — safe to add
    // unconditionally. Compiling it requires libc (jni.h / NDK headers), so
    // gate `link_libc` on Android to keep desktop/wasm builds linker-free.
    if (is_android) {
        input_mod.link_libc = true;
        input_mod.addCSourceFile(.{
            .file = b.path("src/android_gamepad_jni.c"),
            .flags = &.{},
        });
    }

    // ── Audio backend module ────────────────────────────────────────
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    audio_mod.addImport("sokol", sokol_mod);
    audio_mod.addIncludePath(b.path("src"));

    // Mirror the emsdk sysroot include from gfx_mod: stb_vorbis and
    // dr_wav both pull in <stdlib.h> / <string.h> / <math.h> which
    // require emscripten's sysroot when cross-compiling to
    // wasm32-emscripten (labelle-cli#197, labelle-assembler#141). MUST
    // be set BEFORE the `addCSourceFile` calls below — see gfx_mod's
    // comment.
    if (target.result.os.tag == .emscripten) {
        if (b.lazyDependency("emsdk", .{})) |emsdk_dep| {
            audio_mod.addSystemIncludePath(emsdk_dep.path("upstream/emscripten/cache/sysroot/include"));
        }
    }

    // Phase 4 audio decoders (labelle-engine#447):
    //   - stb_vorbis.c is both the API *and* the implementation — it is
    //     a single .c file you compile directly, not a header + impl
    //     translation-unit pair.
    //   - dr_wav matches stb_image's split: header + an _impl.c TU
    //     that defines the implementation macro before including the
    //     header.
    audio_mod.addCSourceFile(.{ .file = b.path("src/stb_vorbis.c"), .flags = &.{} });
    audio_mod.addCSourceFile(.{ .file = b.path("src/dr_wav_impl.c"), .flags = &.{} });

    // ── Window backend module ───────────────────────────────────────
    // `link_libc = true` is required because `screenshot/bmp.zig` writes
    // the BMP file via libc `fopen` / `fwrite` / `fclose` — Zig 0.16
    // dropped the allocator-free `std.fs.cwd()` helper and threading an
    // `Io` through `takeScreenshot` (which is invoked from a deep
    // callback) wasn't worth it for a 60-line writer. See bmp.zig's
    // header comment and the matching libc shims in gfx/texture.zig and
    // audio/legacy.zig (PR #218).
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    window_mod.addImport("sokol", sokol_mod);

    // ── Re-export the native artifact so consumers can link it ──────
    b.installArtifact(sokol_clib);

    // ── Unit tests ──────────────────────────────────────────────────
    const test_step = b.step("test", "Run sokol backend unit tests");

    // Pure state-transition tests for audio_slots.zig. No sokol
    // import, so this runs anywhere — no libasound/libGL/libX11
    // system deps needed. This is the regression lock for the #10
    // unloaded-slot leak fix.
    const host_target = b.resolveTargetQuery(.{});
    const slots_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/audio_slots.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(slots_tests).step);

    // Compile-check audio.zig via a test binary off audio_mod. This
    // pulls in the full sokol module graph so it only works when the
    // host has sokol's system libs installed (libasound, libGL, libX11,
    // libXi, libXcursor on Linux). Depending on the compile step keeps
    // this useful for cross-compile (the binary doesn't need to run);
    // the host_audio_tests step below adds the run side for native.
    const audio_compile_check = b.addTest(.{ .root_module = audio_mod });
    test_step.dependOn(&audio_compile_check.step);

    // Compile-check gfx.zig — same trick as `audio_compile_check`.
    // Verifies the Phase 4 font surface (`FontAtlas`, `decodeFont`,
    // `uploadFontAtlas`, `unloadFontAtlas`) keeps compiling against
    // sokol_gfx + stb_truetype.
    const gfx_compile_check = b.addTest(.{ .root_module = gfx_mod });
    test_step.dependOn(&gfx_compile_check.step);

    // Compile-check input.zig — pulls in sokol_app + (on Android) the JNI
    // gamepad-detection C glue. Regression lock for labelle-assembler#248:
    // verifies the back-key policy compiles and, on the Android target, that
    // `android_gamepad_jni.c` links into the input module graph. Like the
    // other checks this only builds the binary (cross-compile safe).
    const input_compile_check = b.addTest(.{ .root_module = input_mod });
    test_step.dependOn(&input_compile_check.step);

    // Android gamepad STATE (labelle-assembler#250). The mapping table, quirk
    // routing, and the per-device state machine are pure Zig — host-runnable
    // with no sokol/JNI deps. Run them natively (unlike `input_compile_check`,
    // which only builds) so the canonical raylib button/axis numbering and the
    // quirk overrides stay locked. The Android-only `extern`/`@export` symbols
    // in input.zig are gated behind `is_android`, so this host build of the
    // standalone module never references them.
    const android_gp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/android_gamepad_state.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(android_gp_tests).step);

    // Compile-check window.zig — pulls in sokol + the per-backend
    // screenshot readback helpers (`screenshot/metal.zig`, `gl.zig`,
    // `d3d11.zig`, `bmp.zig`). Regression lock for the screenshot
    // implementation (labelle-assembler#213); without this the four
    // helper files were unreached by any test target.
    const window_compile_check = b.addTest(.{ .root_module = window_mod });
    test_step.dependOn(&window_compile_check.step);

    // ── Phase 4 host-native test runs ────────────────────────────────
    //
    // The compile-checks above only ensure the bytecode builds. The
    // Phase 4 decoder unit tests (decodeFont rejecting empty/garbage
    // input, decodeAudio dispatching on file_type, Sound layout
    // invariants) are pure-CPU and exercise no sokol API — they're
    // safe to run on the host target when the user explicitly asks
    // for it. Wired off a separate `test-host` step rather than
    // `test` so the default cross-compile flow stays linker-free.
    const test_host_step = b.step(
        "test-host",
        "Run Phase 4 decoder unit tests natively (needs sokol's system libs).",
    );
    test_host_step.dependOn(&b.addRunArtifact(audio_compile_check).step);
    test_host_step.dependOn(&b.addRunArtifact(gfx_compile_check).step);
    test_host_step.dependOn(&b.addRunArtifact(slots_tests).step);
}
