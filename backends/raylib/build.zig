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
        .link_libc = true,
    });
    gfx_mod.addImport("raylib", raylib_mod);
    gfx_mod.addIncludePath(b.path("src"));
    // Phase 4 font baker (labelle-engine#448). stb_truetype is a
    // single-header C lib — separate `_impl.c` translation unit
    // defines the implementation macro before including the header.
    gfx_mod.addCSourceFile(.{ .file = b.path("src/stb_truetype_impl.c"), .flags = &.{} });

    // When cross-compiling to wasm32-emscripten the C compile of
    // `stb_truetype_impl.c` cannot find `<stdlib.h>` because Zig does
    // not ship libc headers for `wasm32-emscripten` — they live in
    // emsdk's sysroot. Mirror what sokol-zig does for its `_clib` and
    // plumb the emsdk sysroot include path. Gated on `.emscripten`
    // so the desktop / mobile / iOS builds remain untouched.
    if (target.result.os.tag == .emscripten) {
        if (b.lazyDependency("emsdk", .{})) |emsdk_dep| {
            gfx_mod.addSystemIncludePath(emsdk_dep.path("upstream/emscripten/cache/sysroot/include"));
        }
    }

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
        .link_libc = true,
    });
    audio_mod.addImport("raylib", raylib_mod);
    audio_mod.addIncludePath(b.path("src"));
    // Phase 4 audio decoders (labelle-engine#447):
    //   - stb_vorbis.c is both the API *and* the implementation — it
    //     is a single .c file you compile directly, not a header +
    //     impl translation-unit pair.
    //   - dr_wav matches stb_image's split: header + an _impl.c TU
    //     that defines the implementation macro before including the
    //     header.
    audio_mod.addCSourceFile(.{ .file = b.path("src/stb_vorbis.c"), .flags = &.{} });
    audio_mod.addCSourceFile(.{ .file = b.path("src/dr_wav_impl.c"), .flags = &.{} });

    // Mirror the emsdk sysroot include from gfx_mod: stb_vorbis and
    // dr_wav both pull in <stdlib.h> / <string.h> / <math.h> which
    // require emscripten's sysroot when cross-compiling to
    // wasm32-emscripten.
    if (target.result.os.tag == .emscripten) {
        if (b.lazyDependency("emsdk", .{})) |emsdk_dep| {
            audio_mod.addSystemIncludePath(emsdk_dep.path("upstream/emscripten/cache/sysroot/include"));
        }
    }

    // ── Window backend module ───────────────────────────────────────
    // `link_libc = true` is what makes `std.c.fopen` / `fwrite` / `fclose`
    // (used by `takeScreenshot` after #229) compile under sema even for
    // targets like `x86_64-windows-gnu`. raylib's own C artifact already
    // pulls libc in for runtime linking — this just lets the module
    // semantic-analyze cleanly without depending on transitive link
    // state.
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    window_mod.addImport("raylib", raylib_mod);

    // ── Re-export the native artifact so consumers can link it ──────
    b.installArtifact(raylib_artifact);

    // ── Unit tests ──────────────────────────────────────────────────
    //
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

    // ── Phase 4 host-native test runs ────────────────────────────────
    //
    // The Phase 4 decoder unit tests (decodeFont rejecting empty /
    // garbage input, decodeAudio dispatching on file_type, Sound
    // layout invariants) are pure-CPU and exercise no raylib API,
    // but the test binary itself imports `gfx.zig`/`audio.zig`,
    // which transitively pulls in raylib-zig + its C artifact. That
    // C link depends on host-side frameworks (Foundation, IOKit,
    // …) that the default `test` step shouldn't require — wiring
    // these off a separate `test-host` step keeps the default
    // cross-compile flow linker-free, matching sokol's split
    // (sokol's `test` works without a linker because sokol's C lib
    // has no host-framework dep; raylib's does, so we segregate).
    //
    // Both test modules are forced to `host_target` so that
    // `zig build -Dtarget=wasm32-emscripten test-host` still builds
    // and runs natively rather than trying to execute a wasm binary.
    // Mirror the same explicit host_target already used by slot_alloc_tests.
    const audio_host_mod = b.createModule(.{
        .root_source_file = b.path("src/audio.zig"),
        .target = host_target,
        .optimize = optimize,
        .link_libc = true,
    });
    audio_host_mod.addImport("raylib", raylib_mod);
    audio_host_mod.addIncludePath(b.path("src"));
    audio_host_mod.addCSourceFile(.{ .file = b.path("src/stb_vorbis.c"), .flags = &.{} });
    audio_host_mod.addCSourceFile(.{ .file = b.path("src/dr_wav_impl.c"), .flags = &.{} });

    const gfx_host_mod = b.createModule(.{
        .root_source_file = b.path("src/gfx.zig"),
        .target = host_target,
        .optimize = optimize,
        .link_libc = true,
    });
    gfx_host_mod.addImport("raylib", raylib_mod);
    gfx_host_mod.addIncludePath(b.path("src"));
    gfx_host_mod.addCSourceFile(.{ .file = b.path("src/stb_truetype_impl.c"), .flags = &.{} });

    const audio_compile_check = b.addTest(.{ .root_module = audio_host_mod });
    const gfx_compile_check = b.addTest(.{ .root_module = gfx_host_mod });

    const test_host_step = b.step(
        "test-host",
        "Run Phase 4 decoder unit tests natively (needs raylib's system libs).",
    );
    test_host_step.dependOn(&b.addRunArtifact(audio_compile_check).step);
    test_host_step.dependOn(&b.addRunArtifact(gfx_compile_check).step);
    test_host_step.dependOn(&b.addRunArtifact(slot_alloc_tests).step);
}
