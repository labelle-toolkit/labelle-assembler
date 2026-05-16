/// Sokol window backend — windowing lifecycle via sokol_app.
const builtin = @import("builtin");
const sokol = @import("sokol");
const sapp = sokol.app;
const sg = sokol.gfx;
const sgl = sokol.gl;
const sglue = sokol.glue;
const slog = sokol.log;

pub const ConfigFlags = struct {
    window_hidden: bool = false,
};

/// Set config flags before initialization.
/// Note: sokol_app does not natively support hidden windows. This is a
/// no-op stub for API compatibility; the flag is stored but has no effect
/// on the sokol backend (sokol_app always shows the window).
pub fn setConfigFlags(_: ConfigFlags) void {}

/// sokol_gl pipeline with alpha blending enabled. The default sgl pipeline
/// has blend disabled, which makes atlas sprites render their transparent
/// pixels as opaque (the underlying layer doesn't show through). We create
/// this once in initGfx and load it on every beginFrame so all sgl draws —
/// textured sprites, rectangles, circles, text — get correct alpha blending.
var alpha_pipeline: sgl.Pipeline = .{};

pub fn initGfx() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    sgl.setup(.{
        .logger = .{ .func = slog.func },
    });
    alpha_pipeline = sgl.makePipeline(.{
        .colors = .{ .{ .blend = .{
            .enabled = true,
            .src_factor_rgb = .SRC_ALPHA,
            .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
            .src_factor_alpha = .ONE,
            .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        } }, .{}, .{}, .{}, .{}, .{}, .{}, .{} },
    });
}

pub fn shutdownGfx() void {
    sgl.destroyPipeline(alpha_pipeline);
    sgl.shutdown();
    sg.shutdown();
}

/// Request that the sokol_app event loop terminate on the next iteration.
/// Mirrors `rl.closeWindow` / `sdl.quit` — the generated frame callback
/// polls `g.isRunning()` and calls this when a script called `game.quit()`.
pub fn requestQuit() void {
    sapp.requestQuit();
}

pub fn width() i32 {
    return sapp.width();
}

pub fn height() i32 {
    return sapp.height();
}

/// Duration of the last frame in seconds.
/// Use this for dt in the frame callback instead of a hardcoded value.
pub fn frameDuration() f64 {
    return sapp.frameDuration();
}

pub fn beginFrame() sg.PassAction {
    sgl.defaults();
    // sgl.defaults() resets to the default non-blended pipeline; load our
    // alpha-blended pipeline so sprites render transparency correctly.
    sgl.loadPipeline(alpha_pipeline);
    var pass_action: sg.PassAction = .{};
    pass_action.colors[0] = .{
        .load_action = .CLEAR,
        // Match the raylib backend's default clear color (30, 30, 35) so
        // projects render the same backdrop regardless of backend.
        .clear_value = .{ .r = 30.0 / 255.0, .g = 30.0 / 255.0, .b = 35.0 / 255.0, .a = 1.0 },
    };
    return pass_action;
}

pub fn beginPass(pass_action: sg.PassAction) void {
    sg.beginPass(.{ .action = pass_action, .swapchain = sglue.swapchain() });
}

/// Flush queued sokol-gl primitives (sprites, gizmos, sgl-rendered text)
/// to the active sokol-gfx pass. The frame-loop template calls this
/// **between** scene rendering (`g.render()` / `g.renderGizmos()`) and
/// GUI rendering (`g.guiBegin()` / drawGui / `g.guiEnd()`), so sgl
/// primitives land in the framebuffer before any imgui draws are
/// emitted. The original `endFrame` flushed sgl AFTER `simgui.render()`
/// had already submitted the GUI's draw calls in the same pass — and
/// since draws are layered in submission order, the sprites painted on
/// top of the GUI and hid it entirely. See labelle-toolkit/labelle-imgui#4.
pub fn flushScene() void {
    sgl.draw();
}

pub fn endFrame() void {
    // No `sgl.draw()` here on purpose — `flushScene()` already drained
    // the queue between scene rendering and GUI rendering. Calling
    // `sgl.draw()` a second time would *re-submit* the same vertex /
    // command buffers (sokol-gl rewinds them on `sg_commit`, not on
    // `sgl_draw`), painting the sprites a second time on top of any
    // GUI submitted between the two flushes — which is exactly the
    // labelle-imgui#4 symptom this split fixes.
    sg.endPass();
    sg.commit();
}

/// Metal device pointer (MTLDevice*) for the Play-in-Editor preview's
/// macOS/iOS readback path (labelle-assembler#125). Returns the same
/// device sokol acquires for the swapchain — safe to call any number
/// of times per frame. `null` on non-Metal builds and pre-init
/// (sapp not valid yet).
pub fn metalDevice() ?*const anyopaque {
    if (comptime builtin.target.os.tag != .macos and builtin.target.os.tag != .ios) return null;
    return sapp.getEnvironment().metal.device;
}

/// Metal drawable pointer (CAMetalDrawable*) for the current frame.
/// Currently a STUB returning `null`: sokol's `sapp_get_swapchain()`
/// calls `[CAMetalLayer nextDrawable]` internally, which acquires a
/// brand-new drawable each call. Sokol-gfx's `sglue_swapchain()`
/// already called it during `window.beginPass()`, so calling it again
/// here would hand us a fresh empty drawable rather than the one
/// sokol just rendered into — defeating the readback entirely.
///
/// The right fix lives in sokol-gfx / sokol-app: expose the
/// "currently-acquired drawable" from the per-frame cache (the
/// equivalent of the legacy `sapp_metal_get_current_drawable`
/// accessor that older sokol versions shipped). Filed upstream as
/// the engine-side gap labelle-assembler#125 documents in its PR body
/// — without it the generated readback gracefully no-ops on macOS
/// (the `?*anyopaque` orelse break gates the entire blit chain on
/// this returning non-null). All the wiring is in place; flipping
/// the stub to return the real drawable is a single-line change once
/// the upstream API lands.
pub fn metalCurrentDrawable() ?*const anyopaque {
    return null;
}

/// The sokol app descriptor type — re-exported so callers don't need to
/// import sokol directly (used by mobile sokol_main return type).
pub const Desc = sapp.Desc;

/// Build a sokol app descriptor without starting the event loop.
/// Used on mobile targets where sokol calls sokol_main() and reads its
/// return value as sapp_desc — the host must NOT call sapp_run() itself.
pub fn makeDesc(desc: struct {
    init_cb: *const fn () callconv(.c) void,
    frame_cb: *const fn () callconv(.c) void,
    cleanup_cb: *const fn () callconv(.c) void,
    event_cb: ?*const fn ([*c]const sapp.Event) callconv(.c) void = null,
    w: i32 = 800,
    h: i32 = 600,
    title: [:0]const u8 = "LaBelle v2",
}) sapp.Desc {
    // Android emulators typically support GLES 3.0 but not 3.1.
    // Sokol defaults to 3.1 on Android, which causes EGL_BAD_CONFIG on emulators.
    // Request 3.0 explicitly so the app works on both real devices and emulators.
    // std.Target.isAndroid() is not available in Zig 0.15.2; check ABI directly.
    // .android covers arm64/x86_64; .androideabi covers arm/x86.
    const is_android = comptime builtin.target.abi == .android or
        builtin.target.abi == .androideabi;
    return .{
        .init_cb = desc.init_cb,
        .frame_cb = desc.frame_cb,
        .cleanup_cb = desc.cleanup_cb,
        .event_cb = desc.event_cb orelse null,
        .width = desc.w,
        .height = desc.h,
        .window_title = desc.title,
        .gl = if (is_android) .{ .major_version = 3, .minor_version = 0 } else .{},
        .high_dpi = true,
        .logger = .{ .func = slog.func },
    };
}

/// Run the sokol application loop with callbacks. Forwards each field
/// explicitly because Zig treats `run`'s anon-struct parameter and
/// `makeDesc`'s anon-struct parameter as distinct types — passing one
/// to the other directly would fail to compile.
pub fn run(desc: struct {
    init_cb: *const fn () callconv(.c) void,
    frame_cb: *const fn () callconv(.c) void,
    cleanup_cb: *const fn () callconv(.c) void,
    event_cb: ?*const fn ([*c]const sapp.Event) callconv(.c) void = null,
    w: i32 = 800,
    h: i32 = 600,
    title: [:0]const u8 = "LaBelle v2",
}) void {
    sapp.run(makeDesc(.{
        .init_cb = desc.init_cb,
        .frame_cb = desc.frame_cb,
        .cleanup_cb = desc.cleanup_cb,
        .event_cb = desc.event_cb,
        .w = desc.w,
        .h = desc.h,
        .title = desc.title,
    }));
}
