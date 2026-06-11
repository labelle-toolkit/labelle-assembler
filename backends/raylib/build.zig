const std = @import("std");
const builtin = @import("builtin");

/// True when `t` is a native desktop OS (matches the shared source's comptime
/// `is_desktop`): only there are the SDL `extern`s referenced and SDL must be
/// linked. Android/iOS/wasm are excluded.
fn targetIsDesktop(t: std.Target) bool {
    if (t.abi == .android or t.abi == .androideabi) return false;
    if (t.cpu.arch.isWasm()) return false;
    return switch (t.os.tag) {
        .macos, .windows, .linux => true,
        else => false,
    };
}

/// macOS Homebrew SDL2 library path for a NATIVE macOS host build (Zig does
/// not search Homebrew by default). Returns null when cross-compiling or on
/// Linux/Windows (system search resolves SDL2). No include path is needed.
fn sdlLibPath(target_os: std.Target.Os.Tag, host_os: std.Target.Os.Tag) ?[]const u8 {
    if (target_os != .macos or host_os != .macos) return null;
    if (dirExists("/opt/homebrew/lib")) return "/opt/homebrew/lib";
    if (dirExists("/usr/local/lib")) return "/usr/local/lib";
    return null;
}

fn dirExists(path: []const u8) bool {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

/// Re-export raylib-zig's emsdk helpers so consumers (generated build.zig) can
/// use emccStep / emrunStep for WASM builds without a direct raylib-zig dep.
pub const emsdk = @import("raylib-zig").emsdk;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const raylib_dep = b.dependency("raylib-zig", .{ .target = target, .optimize = optimize });

    const raylib_mod = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

    // labelle-core supplies the cross-backend gamepad event contract
    // (GamepadEvent / GamepadDescription) consumed by input.zig's
    // pollGamepadEvents / describeGamepads (labelle-core#18). Dependency
    // is path-pinned during local dev; consumers (the assembler) inject
    // the canonical labelle-core module via overrideImport, so this just
    // needs to resolve the `labelle-core` import for standalone builds.
    const core_dep = b.dependency("labelle-core", .{ .target = target, .optimize = optimize });
    const core_mod = core_dep.module("labelle-core");

    // Shared windowless-SDL desktop gamepad source (core#28). One copy lives
    // in `backends/sdl_gamepad/`; both raylib and sokol desktop backends route
    // their gamepad state/hotplug through it so the Switch/8BitDo raw-HID
    // handshake GLFW can't decode is handled once. Imported under the
    // `sdl_gamepad` key by `input.zig`. We unify labelle-core onto it (it
    // imports core under the `labelle_core` key) so the `GamepadEvent` types it
    // returns are the SAME instance `input.zig` and the engine see — without
    // this the `[]GamepadEvent` crossing the seam would not type-check.
    const sdl_gp_dep = b.dependency("labelle_sdl_gamepad", .{ .target = target, .optimize = optimize });
    const sdl_gp_mod = sdl_gp_dep.module("sdl_gamepad");
    sdl_gp_mod.addImport("labelle_core", core_mod);

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
    input_mod.addImport("labelle-core", core_mod);
    input_mod.addImport("sdl_gamepad", sdl_gp_mod);

    // Link SDL2 for the shared desktop gamepad source — DESKTOP targets only.
    // The source gates every SDL `extern` behind a comptime desktop check, so
    // Android/iOS/wasm builds reference no SDL symbols and must pull no SDL.
    // No `@cImport`/include path is needed (the source uses `extern fn`); only
    // the link + (on macOS Homebrew) the library path matters. raylib's render
    // backend does NOT itself link SDL, so this is the only SDL on the line.
    if (targetIsDesktop(target.result)) {
        input_mod.link_libc = true;
        if (sdlLibPath(target.result.os.tag, builtin.target.os.tag)) |p| {
            input_mod.addLibraryPath(.{ .cwd_relative = p });
        }
        input_mod.linkSystemLibrary("SDL2", .{});
    }

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

    // input.zig imports `raylib` (poll/describe gamepad helpers call into
    // rl.isGamepadAvailable) and `labelle-core` (GamepadEvent contract), so
    // its test binary links raylib's C artifact + host frameworks — same
    // reason it rides the host-native `test-host` step, not the linker-free
    // default `test` step.
    const input_host_mod = b.createModule(.{
        .root_source_file = b.path("src/input.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    input_host_mod.addImport("raylib", raylib_mod);
    input_host_mod.addImport("labelle-core", core_mod);
    input_host_mod.addImport("sdl_gamepad", sdl_gp_mod);
    input_host_mod.linkLibrary(raylib_artifact);
    // The host is a desktop target, so input.zig references the SDL externs —
    // link SDL2 (+ Homebrew lib path on macOS) so the test binary resolves.
    if (targetIsDesktop(host_target.result)) {
        input_host_mod.link_libc = true;
        if (sdlLibPath(host_target.result.os.tag, builtin.target.os.tag)) |p| {
            input_host_mod.addLibraryPath(.{ .cwd_relative = p });
        }
        input_host_mod.linkSystemLibrary("SDL2", .{});
    }

    const audio_compile_check = b.addTest(.{ .root_module = audio_host_mod });
    const gfx_compile_check = b.addTest(.{ .root_module = gfx_host_mod });
    const input_compile_check = b.addTest(.{ .root_module = input_host_mod });

    const test_host_step = b.step(
        "test-host",
        "Run Phase 4 decoder unit tests natively (needs raylib's system libs).",
    );
    test_host_step.dependOn(&b.addRunArtifact(audio_compile_check).step);
    test_host_step.dependOn(&b.addRunArtifact(gfx_compile_check).step);
    test_host_step.dependOn(&b.addRunArtifact(input_compile_check).step);
    test_host_step.dependOn(&b.addRunArtifact(slot_alloc_tests).step);
}
