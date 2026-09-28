//! Generated-code snippets for Android immersive mode
//! (`.android.immersive_mode`).
//!
//! Immersive mode moved out of labelle-engine (`src/android.zig`) into
//! labelle-android's `immersive` service (labelle-engine#902: the engine
//! carries no platform code). The generated `main.zig` reads the running
//! `ANativeActivity*` from labelle-core's backend seam
//! (`engine.core.android_backend`, labelle-core#310) and hands it to the
//! `android` plugin, which the project lists in `.plugins` for the
//! labelle-android provider and which the generated `main.zig` imports by
//! that name.
//!
//! The snippets stay compatible across the move, resolved at comptime in
//! the generated code:
//!
//!   - `android` plugin with `immersive` (labelle-android >= 0.3.0): the
//!     plugin's `immersive.enable` / `immersive.applyUiThread`.
//!   - otherwise (no plugin, or an older labelle-android): the engine's
//!     legacy `engine.android` entry points while the engine still has
//!     them, else a `@compileError` naming the fix.
//!
//! Both entry points are emitted inside a function body (`sokol_main()`
//! for sokol, `android_main` for the bgfx shell), so the helpers live in a
//! local `struct`.

const std = @import("std");
const config = @import("../../config.zig");

/// Which immersive entry point a backend shape calls.
pub const Entry = enum {
    /// sokol: `sokol_main()` runs on the UI thread before sokol registers
    /// its `ANativeActivityCallbacks`; the service installs its own hooks.
    sokol_enable,
    /// bgfx: native_app_glue owns the callbacks, so the shell calls a C
    /// function pointer on every UI-thread focus gain.
    bgfx_callback,
};

/// The name the generated `main.zig` imports labelle-android under: its
/// `plugin.labelle` `.name` (the `.plugins` entry name).
pub const android_plugin_name = "android";

pub fn hasAndroidPlugin(cfg: config.ProjectConfig) bool {
    for (cfg.plugins) |p| if (std.mem.eql(u8, p.name, android_plugin_name)) return true;
    return false;
}

const missing_plugin_error =
    "@compileError(\"`.android.immersive_mode` needs the `android` plugin " ++
    "(labelle-android >= 0.3.0) in `.plugins`: immersive mode moved out of " ++
    "labelle-engine (labelle-engine#902)\")";

/// The immersive snippet for `entry`, or "" when the project did not opt
/// in or does not build for Android.
pub fn snippet(cfg: config.ProjectConfig, entry: Entry) []const u8 {
    if (cfg.platform != .android) return "";
    const on = if (cfg.android) |a| a.immersive_mode else false;
    if (!on) return "";
    const plugin = hasAndroidPlugin(cfg);
    return switch (entry) {
        .sokol_enable => if (plugin) sokol_with_plugin else sokol_legacy,
        .bgfx_callback => if (plugin) bgfx_with_plugin else bgfx_legacy,
    };
}

const sokol_comment =
    \\    // Android immersive mode (project.labelle `.android.immersive_mode`):
    \\    // hide the status + navigation bars (immersive-sticky). Called from
    \\    // `sokol_main()` — the UI thread, before sokol registers its own
    \\    // ANativeActivity callbacks — so the hook catches the window's
    \\    // first focus and the bars are hidden at launch. The service only
    \\    // installs a UI-thread callback hook; the JNI decor-view call runs
    \\    // on the UI thread. See labelle-android src/immersive.zig.
    \\
;

const bgfx_comment =
    \\    // Android immersive mode (project.labelle `.android.immersive_mode`):
    \\    // register the UI-thread system-bar hide with the bgfx shell. The
    \\    // shell chains onWindowFocusChanged (a UI-thread framework callback)
    \\    // and invokes this on launch + every focus regain, so the bars hide at
    \\    // launch and re-hide after a swipe / returning from the shade. The
    \\    // hook-based `enable` can't work under native_app_glue. See
    \\    // labelle-android src/immersive.zig (applyUiThread) and
    \\    // backends/bgfx/src/android_app.zig (setImmersiveCallback / focusHook).
    \\
;

const sokol_with_plugin = sokol_comment ++
    \\    const labelle_immersive = struct {
    \\        const android_pkg = @import("android");
    \\        fn enable() void {
    \\            if (comptime @hasDecl(android_pkg, "immersive")) {
    \\                const ctx = engine.core.android_backend.get() orelse return;
    \\                android_pkg.immersive.enable(ctx.get_native_activity());
    \\            } else if (comptime @hasDecl(engine, "android")) {
    \\                engine.android.enableImmersiveMode();
    \\            } else {
    \\
++ "                " ++ missing_plugin_error ++ ";\n" ++
    \\            }
    \\        }
    \\    };
    \\    labelle_immersive.enable();
    \\
;

const sokol_legacy = sokol_comment ++
    \\    if (comptime @hasDecl(engine, "android")) {
    \\        engine.android.enableImmersiveMode();
    \\    } else {
    \\
++ "        " ++ missing_plugin_error ++ ";\n" ++
    \\    }
    \\
;

const bgfx_with_plugin = bgfx_comment ++
    \\    const labelle_immersive = struct {
    \\        const android_pkg = @import("android");
    \\        fn apply() callconv(.c) void {
    \\            if (comptime @hasDecl(android_pkg, "immersive")) {
    \\                const ctx = engine.core.android_backend.get() orelse return;
    \\                android_pkg.immersive.applyUiThread(ctx.get_native_activity());
    \\            } else if (comptime @hasDecl(engine, "android")) {
    \\                engine.android.applyImmersiveUiThread();
    \\            } else {
    \\
++ "                " ++ missing_plugin_error ++ ";\n" ++
    \\            }
    \\        }
    \\    };
    \\    android_app.setImmersiveCallback(&labelle_immersive.apply);
    \\
;

const bgfx_legacy = bgfx_comment ++
    \\    const labelle_immersive = struct {
    \\        fn apply() callconv(.c) void {
    \\            if (comptime @hasDecl(engine, "android")) {
    \\                engine.android.applyImmersiveUiThread();
    \\            } else {
    \\
++ "                " ++ missing_plugin_error ++ ";\n" ++
    \\            }
    \\        }
    \\    };
    \\    android_app.setImmersiveCallback(&labelle_immersive.apply);
    \\
;

fn testCfg(immersive: bool, plugins: []const config.PluginDep) config.ProjectConfig {
    return .{
        .name = "g",
        .platform = .android,
        .android = .{ .immersive_mode = immersive },
        .plugins = plugins,
    };
}

const android_plugin = [_]config.PluginDep{.{ .name = "android", .repo = "github.com/labelle-toolkit/labelle-android", .version = "0.3.0" }};

test "immersive off or off Android emits nothing" {
    try std.testing.expectEqualStrings("", snippet(testCfg(false, &android_plugin), .sokol_enable));
    try std.testing.expectEqualStrings("", snippet(testCfg(false, &android_plugin), .bgfx_callback));
    var desktop = testCfg(true, &android_plugin);
    desktop.platform = .desktop;
    try std.testing.expectEqualStrings("", snippet(desktop, .sokol_enable));
}

test "with the android plugin the snippets call labelle-android's immersive service" {
    const s = snippet(testCfg(true, &android_plugin), .sokol_enable);
    try std.testing.expect(std.mem.indexOf(u8, s, "android_pkg.immersive.enable(ctx.get_native_activity());") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "labelle_immersive.enable();") != null);
    const b = snippet(testCfg(true, &android_plugin), .bgfx_callback);
    try std.testing.expect(std.mem.indexOf(u8, b, "android_pkg.immersive.applyUiThread(ctx.get_native_activity());") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "android_app.setImmersiveCallback(&labelle_immersive.apply);") != null);
}

test "without the android plugin the snippets fall back to the engine, then a clear error" {
    const s = snippet(testCfg(true, &.{}), .sokol_enable);
    try std.testing.expect(std.mem.indexOf(u8, s, "@import(\"android\")") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "engine.android.enableImmersiveMode();") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "needs the `android` plugin") != null);
    const b = snippet(testCfg(true, &.{}), .bgfx_callback);
    try std.testing.expect(std.mem.indexOf(u8, b, "engine.android.applyImmersiveUiThread();") != null);
    try std.testing.expect(std.mem.indexOf(u8, b, "needs the `android` plugin") != null);
}
