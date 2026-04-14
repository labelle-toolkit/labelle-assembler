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

    // Enable sokol-imgui — builds sokol with simgui_* support compiled in.
    // When true, the backend pulls cimgui (lazily) just to expose its
    // header search path to sokol_clib so sokol_imgui.h's IMPL can resolve
    // cimgui types. The cimgui artifact itself is provided by the GUI
    // plugin (labelle-imgui) and linked at the final exe step.
    const with_sokol_imgui = b.option(bool, "with_sokol_imgui", "Build sokol with simgui (sokol_imgui) support") orelse false;

    const sokol_dep = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .dont_link_system_libs = dont_link_system_libs,
        .with_sokol_imgui = with_sokol_imgui,
    });
    const sokol_mod = sokol_dep.module("sokol");
    const sokol_clib = sokol_dep.artifact("sokol_clib");

    if (with_sokol_imgui) {
        const cimgui_dep = b.lazyDependency("cimgui", .{
            .target = target,
            .optimize = optimize,
        }) orelse return;
        sokol_clib.root_module.addIncludePath(cimgui_dep.path("src"));
    }

    // ── Gfx backend module ──────────────────────────────────────────
    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gfx_mod.addImport("sokol", sokol_mod);
    gfx_mod.addIncludePath(b.path("src"));
    gfx_mod.addCSourceFile(.{ .file = b.path("src/stb_image_impl.c"), .flags = &.{} });

    // ── Input backend module ────────────────────────────────────────
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("sokol", sokol_mod);

    // ── Audio backend module ────────────────────────────────────────
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_mod.addImport("sokol", sokol_mod);

    // ── Window backend module ───────────────────────────────────────
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = optimize,
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
    // libXi, libXcursor on Linux). The test binary has no test blocks,
    // so the run step is a no-op — the point is to verify audio.zig
    // actually compiles against sokol after the refactor. Depends on
    // the compile step, not the run step, so cross-compile works too.
    const audio_compile_check = b.addTest(.{ .root_module = audio_mod });
    test_step.dependOn(&audio_compile_check.step);
}
