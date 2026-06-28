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

/// Desktop Linux (not Android) routes gamepad to labelle-core's kernel-native
/// udev/evdev source (core#33 scope 2): the `sdl_gamepad` module is not wired
/// and NO SDL2 is linked there. input.zig gates its `@import("sdl_gamepad")`
/// on the same predicate.
fn targetUsesCoreGamepad(t: std.Target) bool {
    if (t.abi == .android or t.abi == .androideabi) return false;
    return t.os.tag == .linux;
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

    // Desktop gamepad source toggle (core#28 slice 5). When true (default),
    // the shared windowless-SDL desktop gamepad source is wired into `input`
    // and SDL2 is linked on desktop; when false (opt-out, `.gamepad = .none`
    // in project.labelle), the `sdl_gamepad` import is absent, no SDL2 is
    // linked, and input.zig's gamepad queries resolve to the truly-disabled
    // path (no GLFW-native fallback). The assembler forwards this from the
    // generated build.zig via `b.dependency(..., .{ .gamepad_enabled = ... })`.
    const gamepad_enabled = b.option(bool, "gamepad_enabled", "Wire the shared SDL desktop gamepad source + link SDL2 (default true; false = opt out, no SDL)") orelse true;
    const gamepad_hidapi = b.option(bool, "gamepad_hidapi", "Opt the SDL gamepad source into HIDAPI raw-HID decode (Switch/8BitDo); default false — HIDAPI per-connect init stalls the render thread for seconds on some platforms") orelse false;

    // Disable ONLY raudio's bundled `stb_vorbis` (.ogg) decoder. The
    // worker-thread `decodeAudio` path links `stb_vorbis` via the shared
    // `labelle-audio-decode` module (#391), and raudio embeds its OWN copy for
    // file playback — two external definitions of every `stb_vorbis_*` symbol
    // → ~120 `lld-link: duplicate symbol` errors, failing any game that loads a
    // sound asset. (Invisible until then: otherwise `raudio.obj` is never pulled
    // from `raylib.lib`.) raylib's `config.h` `#ifndef`-guards each default, so
    // `-DSUPPORT_FILEFORMAT_OGG=0` suppresses the include while keeping raudio's
    // device + mixer (`InitAudioDevice`/`PlaySound`/`LoadSoundFromWave`) intact —
    // catalog playback uploads raw PCM via `loadSoundFromWave`, no file-format
    // support needed.
    //
    // WAV is deliberately LEFT ENABLED. `labelle-audio-decode` decodes WAV in
    // pure Zig (no `dr_wav`), so raudio's `dr_wav` collides with nothing —
    // disabling it bought no collision safety and only broke the legacy
    // path-based `loadSound("x.wav")` / `loadMusic("x.wav")` surface (which
    // routes through raylib's own file loaders). Keeping WAV on restores those.
    // The residual gap is legacy path-based *OGG* file loading, which raudio can
    // no longer decode; the asset catalog still loads OGG via the shared decoder.
    // See the loader notes in `src/audio.zig`. (Review: coderabbitai, #393.)
    const raylib_dep = b.dependency("raylib-zig", .{
        .target = target,
        .optimize = optimize,
        .config = @as([]const u8, "-DSUPPORT_FILEFORMAT_OGG=0"),
    });

    const raylib_mod = raylib_dep.module("raylib");
    const raylib_artifact = raylib_dep.artifact("raylib");

    // Shared multi-format CPU decoder (issue #391). `src/audio.zig`'s
    // `decodeAudio` forwards to `labelle-audio-decode` (pure-Zig WAV +
    // stb_vorbis OGG), replacing this backend's own dr_wav + stb_vorbis copies.
    // The module carries its own `stb_vorbis.c` + include path and declares
    // `link_libc = true` (propagates to whichever module imports it).
    const labelle_audio_dep = b.dependency("labelle_audio", .{ .target = target, .optimize = optimize });
    const audio_decode_mod = labelle_audio_dep.module("labelle-audio-decode");

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
    // Gated on `gamepad_enabled` AND a desktop target: when opted out OR on a
    // non-desktop target (Android/iOS/wasm), the sub-package is not resolved as
    // a dependency, so nothing pulls SDL into the graph and we don't require
    // `labelle_sdl_gamepad` to be staged where it's never used.
    // Linux desktop is additionally excluded (core#33 scope 2): it routes to
    // labelle-core's udev/evdev source instead, so SDL never enters the graph.
    const sdl_gp_mod: ?*std.Build.Module = if (gamepad_enabled and targetIsDesktop(target.result) and !targetUsesCoreGamepad(target.result)) blk: {
        const sdl_gp_dep = b.dependency("labelle_sdl_gamepad", .{ .target = target, .optimize = optimize });
        const m = sdl_gp_dep.module("sdl_gamepad");
        m.addImport("labelle_core", core_mod);
        break :blk m;
    } else null;

    // `build_options` carried into `input.zig` so its comptime gamepad routing
    // knows whether `sdl_gamepad` was wired. When false, input.zig does NOT
    // `@import("sdl_gamepad")` (the module is absent) and returns the disabled
    // path. Mirrored on the host test module below.
    const input_opts = b.addOptions();
    input_opts.addOption(bool, "gamepad_enabled", gamepad_enabled);
    input_opts.addOption(bool, "gamepad_hidapi", gamepad_hidapi);

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
    input_mod.addImport("build_options", input_opts.createModule());
    if (sdl_gp_mod) |m| input_mod.addImport("sdl_gamepad", m);

    // Link SDL2 for the shared desktop gamepad source — DESKTOP targets only,
    // and only when the gamepad source is wired (`gamepad_enabled`). The source
    // gates every SDL `extern` behind a comptime desktop check, so
    // Android/iOS/wasm builds reference no SDL symbols and must pull no SDL.
    // When opted out (`gamepad_enabled = false`) NO SDL is linked on any target.
    // No `@cImport`/include path is needed (the source uses `extern fn`); only
    // the link + (on macOS Homebrew) the library path matters. raylib's render
    // backend does NOT itself link SDL, so this is the only SDL on the line.
    if (gamepad_enabled and targetIsDesktop(target.result) and !targetUsesCoreGamepad(target.result)) {
        input_mod.link_libc = true;
        if (sdlLibPath(target.result.os.tag, builtin.target.os.tag)) |p| {
            input_mod.addLibraryPath(.{ .cwd_relative = p });
        }
        // Windows: Zig has no default SDL2 search path for the MinGW
        // (`windows-gnu`) toolchain, so honor `LABELLE_SDL2_LIB` — the dir
        // holding the import lib (`libSDL2.dll.a`) from the SDL2 MinGW devel
        // package. `SDL2.dll` must be on PATH (or beside the exe) at runtime.
        if (target.result.os.tag == .windows and builtin.target.os.tag == .windows) {
            if (b.graph.environ_map.get("LABELLE_SDL2_LIB")) |p| {
                input_mod.addLibraryPath(.{ .cwd_relative = p });
            }
        }
        input_mod.linkSystemLibrary("SDL2", .{});
    } else if (gamepad_enabled and targetUsesCoreGamepad(target.result)) {
        // Linux core route: no SDL, but core's udev source dlopens libudev at
        // runtime via std.DynLib, which needs real dlopen — link libc.
        input_mod.link_libc = true;
    }

    // ── Audio backend module ────────────────────────────────────────
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    audio_mod.addImport("raylib", raylib_mod);
    audio_mod.addImport("labelle-audio-decode", audio_decode_mod);

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

    // ── ASTC container-parsing tests (#341) ─────────────────────────
    // `src/astc.zig` is pure byte parsing with no raylib dependency, so it
    // EXECUTES on the host (magic detection, block/image dims, ceil-to-block
    // payload sizing, truncation). Pinned to `host_target` and run linker-free
    // — no raylib C artifact is pulled in — so it rides the default `test` step
    // alongside `slot_alloc_tests` (the compressed-upload glue in gfx.zig is
    // exercised by the `gfx_compile_check` under `test-host`).
    const astc_run = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/astc.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(astc_run).step);

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
    // Host test build resolves its own decode module instance against the host
    // target (mirrors slot_alloc_tests / the input host module pattern).
    audio_host_mod.addImport(
        "labelle-audio-decode",
        b.dependency("labelle_audio", .{ .target = host_target, .optimize = optimize }).module("labelle-audio-decode"),
    );

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
    input_host_mod.addImport("build_options", input_opts.createModule());
    // The host's gamepad route can differ from the target's (e.g. cross-
    // compiling to Linux from macOS), so the host test module resolves its
    // own sdl_gamepad instance under the HOST predicate instead of reusing
    // the target-gated `sdl_gp_mod`. Linux hosts take the core route and
    // import nothing.
    const host_uses_sdl = gamepad_enabled and targetIsDesktop(host_target.result) and !targetUsesCoreGamepad(host_target.result);
    if (host_uses_sdl) {
        const host_sdl_dep = b.dependency("labelle_sdl_gamepad", .{ .target = host_target, .optimize = optimize });
        const m = host_sdl_dep.module("sdl_gamepad");
        m.addImport("labelle_core", core_mod);
        input_host_mod.addImport("sdl_gamepad", m);
    }
    input_host_mod.linkLibrary(raylib_artifact);
    // The host is a desktop target, so input.zig references the SDL externs
    // when the gamepad source is wired — link SDL2 (+ Homebrew lib path on
    // macOS) so the test binary resolves. Skipped entirely on opt-out and on
    // Linux hosts (core route: libc only, for std.DynLib's dlopen).
    if (host_uses_sdl) {
        input_host_mod.link_libc = true;
        if (sdlLibPath(host_target.result.os.tag, builtin.target.os.tag)) |p| {
            input_host_mod.addLibraryPath(.{ .cwd_relative = p });
        }
        if (host_target.result.os.tag == .windows and builtin.target.os.tag == .windows) {
            if (b.graph.environ_map.get("LABELLE_SDL2_LIB")) |p| {
                input_host_mod.addLibraryPath(.{ .cwd_relative = p });
            }
        }
        input_host_mod.linkSystemLibrary("SDL2", .{});
    } else if (gamepad_enabled and targetUsesCoreGamepad(host_target.result)) {
        input_host_mod.link_libc = true;
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
