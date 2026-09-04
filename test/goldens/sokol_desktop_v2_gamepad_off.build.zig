const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
    const core_mod = core_dep.module("labelle-core");

    const gfx_dep = b.dependency("labelle_gfx", .{ .target = target, .optimize = optimize });
    const gfx_mod = gfx_dep.module("labelle-gfx");

    const engine_dep = b.dependency("engine", .{ .target = target, .optimize = optimize });
    const engine_mod = engine_dep.module("engine");

    // Deduplicate labelle-core across gfx and engine — ensures a single core
    // module in the build, preventing diamond dependency version mismatches.
    // Use overrideImport to avoid GPA leak from addImport key re-allocation.
    overrideImport(gfx_mod, "labelle-core", core_mod);
    overrideImport(engine_mod, "labelle-core", core_mod);
    overrideImport(engine_mod, "labelle-gfx", gfx_mod);

    // gfx ships its own sub-packages (`camera`, `spatial_grid`, `tilemap`),
    // each of which imports `labelle-core`. Before gfx#276 those imports were
    // internal-only, so a distinct core instance was harmless. gfx#276 threads
    // the project `y_axis` (a `core.YAxis`) from `gfx`'s renderer into
    // `camera.CameraWith(..., y_axis)`, so the sub-package's `labelle-core`
    // MUST be the same instance as `core_mod` — otherwise two `core.YAxis`
    // enums (gfx's `core_mod` vs the sub-package's own pinned core tarball)
    // don't unify and sema fails with "expected 'YAxis', found 'YAxis'".
    // Unify each sub-package that actually imports core onto `core_mod`.
    unifyGfxSubpackageCore(gfx_mod, core_mod);

    // `game` module — local shim (game.zig) re-exporting engine's `Game`
    // and `EntityId` so generated flow files at `scripts/flows/*.zig`
    // can `@import("game")`. See labelle-assembler#116.
    const game_mod = b.createModule(.{
        .root_source_file = b.path("game.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "labelle-engine", .module = engine_mod },
        },
    });

    // `with_imgui` flips sokol_imgui.c compilation on. MUST match the
    // imgui bridge's option set when the project includes imgui, or
    // Zig caches two `sokol_clib` artifacts (and two `_sg` states) —
    // see comment in `backends/sokol/build.zig` (labelle-assembler#140).
    const backend_dep = b.dependency("labelle_sokol", .{ .target = target, .optimize = optimize, .with_imgui = false, .gamepad_enabled = false, .gamepad_hidapi = false });
    const backend_gfx = backend_dep.module("gfx");
    const backend_input = backend_dep.module("input");
    const backend_audio = backend_dep.module("audio");
    const backend_window = backend_dep.module("window");
    const sokol_clib = backend_dep.artifact("sokol_clib");

    // Unify the app core onto the sokol `gfx` module. The material seam
    // (labelle-gfx#305) gave the backend's gfx module a DIRECT `labelle-core`
    // import for the contract's `MaterialEffect` / `PostPassKind` value types;
    // without unifying it onto the app core the two core instances yield
    // distinct `MaterialEffect` types and sema fails ("expected MaterialEffect,
    // found MaterialEffect"). This is the byte-anchor unroll of the generic
    // desktop path's `unifyCoreDiamond(backend_gfx, …)` edge. `if` guard: the
    // import only exists on a material-seam-carrying backend, so an older gfx
    // module is a harmless no-op. See labelle-assembler#611.
    if (backend_gfx.import_table.get("labelle-core")) |_| {
        overrideImport(backend_gfx, "labelle-core", core_mod);
    }

    // Unify the app core onto the transitive `sdl_gamepad` desktop gamepad
    // source — same diamond as `.backend_raylib` (see the note there). The
    // sokol `input` module reaches `GamepadEvent` through `sdl_gamepad`
    // (imported under the `labelle_core` underscore key) rather than a direct
    // core import, so the override target is the sdl_gamepad module, not
    // `input`. `if` guard: only desktop sokol wires sdl_gamepad in (Android/iOS
    // use their own gamepad paths; wasm has none). See labelle-assembler#271.
    if (backend_input.import_table.get("sdl_gamepad")) |sdl_gp_mod| {
        overrideImport(sdl_gp_mod, "labelle_core", core_mod);
    }

    // Linux desktop core gamepad route (core#33 scope 2): there the sokol
    // backend wires a DIRECT `labelle-core` import on `input` (reaching the
    // udev/evdev gamepad source) instead of `sdl_gamepad`. Unify the app
    // core onto it so gamepad state/event types match the engine's. `if`
    // guard: the import only exists on Linux desktop builds — adding the
    // override unconditionally would inject a dead import elsewhere (#258).
    if (backend_input.import_table.get("labelle-core")) |_| {
        overrideImport(backend_input, "labelle-core", core_mod);
    }

    const exe = b.addExecutable(.{
        .name = "anchor-game",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-core", .module = core_mod },
                .{ .name = "labelle-gfx", .module = gfx_mod },
                .{ .name = "labelle-engine", .module = engine_mod },
                .{ .name = "backend_gfx", .module = backend_gfx },
                .{ .name = "backend_input", .module = backend_input },
                .{ .name = "backend_audio", .module = backend_audio },
                .{ .name = "backend_window", .module = backend_window },

                .{ .name = "game", .module = game_mod },

            },
        }),
    });

    // Windows exe icon (labelle-cli#359): compile the assembler-written
    // app_icon.rc (`1 ICON "app_icon.ico"`) into the binary so Explorer and
    // the taskbar show the project's app_icon. Windows targets only.
    if (target.result.os.tag == .windows) {
        exe.root_module.addWin32ResourceFile(.{ .file = b.path("app_icon.rc") });
    }

    exe.root_module.linkLibrary(sokol_clib);

    // IOSurface + CoreFoundation are needed for the macOS preview-mode
    // IOSurface producer (labelle-assembler#121 + #125, labelle-
    // engine#547). The engine references `IOSurfaceCreate`,
    // `IOSurfaceLock`, `CFNumberCreate`, etc. via `@extern "c"` —
    // these symbols live in IOSurface.framework + CoreFoundation
    // .framework, and sokol's upstream linker line does not propagate
    // them. Same on iOS (the framework path is identical). Linux /
    // Windows / web have no macOS-specific symbols to resolve here,
    // so the framework links are gated on the Darwin target tags.
    switch (target.result.os.tag) {
        .macos, .ios => {
            exe.root_module.linkFramework("IOSurface", .{});
            exe.root_module.linkFramework("CoreFoundation", .{});
        },
        // NOTE: labelle-core's Linux gamepad-detection source
        // (gamepad_source/linux.zig, labelle-assembler#249) does NOT need a
        // build-time libudev link. As of labelle-core#20 it loads libudev at
        // RUNTIME via std.DynLib (dlopen of `libudev.so.1`) and degrades
        // gracefully when the library is absent — so the generated build must
        // not link `-ludev`, which would reintroduce a hard build/runtime
        // dependency. Runtime device-access setup (input group / udev
        // `uaccess` rule, Flatpak `--device=input`) is in docs/gamepad-linux.md.
        else => {},
    }

    // ── Test step ──────────────────────────────────────────────────
    // Single test compile unit rooted at `__tests_root.zig` (generated
    // by labelle-assembler alongside main.zig). The wrapper imports
    // every `.zig` file under the project's `tests/` folder so their
    // `test "..." { }` blocks are pulled into this binary.
    //
    // Why a wrapper at the build root rather than per-file `addTest`:
    // Zig's "module path" is the directory of the module's root source
    // file. With this root at the build root, files under `tests/`,
    // `components/`, `scripts/`, etc. are all reachable via relative
    // `@import`, mirroring how the exe sees them — so test code can
    // `@import("../../components/worker.zig")` from `tests/components/`.
    const test_root = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("__tests_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "labelle-core", .module = core_mod },
                .{ .name = "labelle-gfx", .module = gfx_mod },
                .{ .name = "labelle-engine", .module = engine_mod },
                .{ .name = "backend_gfx", .module = backend_gfx },
                .{ .name = "backend_input", .module = backend_input },
                .{ .name = "backend_audio", .module = backend_audio },
                .{ .name = "backend_window", .module = backend_window },

                .{ .name = "game", .module = game_mod },

            },
        }),
    });
    const test_step = b.step("test", "Run game-side tests");
    test_step.dependOn(&b.addRunArtifact(test_root).step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the game");
    run_step.dependOn(&run_cmd.step);
}

/// Override a module import without leaking memory.
/// Zig's addImport always calls b.dupe(name), leaking the old key on replacement
/// and creating unnecessary allocations for new keys. This function accesses the
/// import_table directly: reuses existing keys and avoids b.dupe entirely.
fn overrideImport(m: *std.Build.Module, name: []const u8, module: *std.Build.Module) void {
    const gop = m.import_table.getOrPut(m.owner.allocator, name) catch @panic("OOM");
    if (!gop.found_existing) {
        // New import — store our key (string literal from generated code, lives forever)
        gop.key_ptr.* = name;
    }
    // Replace value (existing or new)
    gop.value_ptr.* = module;
}

/// Unify `labelle-core` onto gfx's sub-packages (`camera`, `spatial_grid`,
/// `tilemap`) so a `core.YAxis` produced inside `labelle-gfx` unifies with the
/// type each sub-package expects (gfx#276 passes `y_axis` into
/// `camera.CameraWith(...)`). Only overrides sub-packages that import core.
fn unifyGfxSubpackageCore(gfx_mod: *std.Build.Module, core_mod: *std.Build.Module) void {
    const sub_names = [_][]const u8{ "camera", "spatial_grid", "tilemap" };
    for (sub_names) |sub_name| {
        const sub = gfx_mod.import_table.get(sub_name) orelse continue;
        if (sub.import_table.get("labelle-core") != null) {
            overrideImport(sub, "labelle-core", core_mod);
        }
    }
}
