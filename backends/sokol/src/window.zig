/// Sokol window backend — windowing lifecycle via sokol_app.
const builtin = @import("builtin");
const sokol = @import("sokol");
const sapp = sokol.app;
const sg = sokol.gfx;
const sgl = sokol.gl;
const sglue = sokol.glue;
const slog = sokol.log;

/// Re-export `sokol.gfx` so the generated `main.zig` (which only depends
/// on `backend_window`, not directly on `sokol`) can reach sg.Image,
/// sg.View, sg.Attachments, sg.makeImage, sg.makeView, sg.destroyImage,
/// sg.destroyView, sg.ImageDesc, etc. Used by the Path-A IOSurface ring
/// the Play-in-Editor preview producer builds at module scope — every
/// member of the ring is an sg-flavoured handle, so without this re-
/// export the codegen would either need a parallel `sokol` dep on the
/// root module (cross-cutting concern) or duplicate the type defs.
pub const gfx_types = sokol.gfx;

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

/// Quiet-exit handler for the upstream sokol-gfx SIGSEGV in
/// `_sg_mtl_garbage_collect` during `sg_shutdown` (labelle-assembler#140).
/// Bug lives in sokol-gfx's deferred-release queue, not our cleanup.
/// By the time the signal fires the game has already published its
/// last frame to the editor consumer, so an immediate `_exit(0)` keeps
/// the gui's preview state machine in a clean disconnect instead of
/// surfacing a crash dump.
fn quietExitOnShutdownCrash(_: std.posix.SIG, _: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    // _exit(2) bypasses atexit handlers — important because the
    // crash happens INSIDE sokol's teardown, and running more cleanup
    // would re-enter the broken state.
    std.c._exit(0);
}

const std = @import("std");

pub fn shutdownGfx() void {
    sgl.destroyPipeline(alpha_pipeline);
    sgl.shutdown();

    // labelle-assembler#140 workaround — install the quiet-exit handler
    // ONLY on the Darwin/Metal path where the upstream crash reproduces.
    // Linux/Windows/etc. take the normal sg.shutdown path and crash
    // legitimately on any real bug.
    if (builtin.target.os.tag == .macos or builtin.target.os.tag == .ios) {
        var sa: std.posix.Sigaction = .{
            .handler = .{ .sigaction = quietExitOnShutdownCrash },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO,
        };
        std.posix.sigaction(std.posix.SIG.SEGV, &sa, null);
        std.posix.sigaction(std.posix.SIG.BUS, &sa, null);
        std.posix.sigaction(std.posix.SIG.ABRT, &sa, null);
    }

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

/// Editor-mode override for the next `beginPass`. When non-null, `beginPass`
/// routes the game's render into these attachments (Path-A offscreen
/// IOSurface render target — labelle-assembler#133) instead of the
/// sokol_app swapchain. The override stays set across frames; the host
/// flips it on/off around each frame's render via `setEditorRenderTarget`
/// / `clearEditorRenderTarget`. Defaults to null so the standalone /
/// non-editor path renders to the swapchain as before.
var current_editor_render_target: ?sg.Attachments = null;

/// Route the next `beginPass` into these attachments instead of the
/// swapchain. The Path-A producer (Metal/IOSurface ring) populates one
/// `sg.Attachments` per ring slot during ring (re)negotiation, then on
/// each frame the host picks `_write_slot` and passes the corresponding
/// attachments through this shim before `g.render()`. The pass clears
/// to the same color the swapchain path uses.
pub fn setEditorRenderTarget(attachments: sg.Attachments) void {
    current_editor_render_target = attachments;
}

/// Clear the editor render-target override so the next `beginPass`
/// returns to the swapchain. Called after the host's frame body emits
/// `signalSlotReady` for the just-rendered slot — keeps the override
/// strictly one-frame scoped even if a later frame skips the
/// `setEditorRenderTarget` call (e.g. transient ring re-negotiation
/// or editor disconnect).
pub fn clearEditorRenderTarget() void {
    current_editor_render_target = null;
}

pub fn beginPass(pass_action: sg.PassAction) void {
    if (current_editor_render_target) |attachments| {
        sg.beginPass(.{ .action = pass_action, .attachments = attachments });
        return;
    }
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
/// macOS/iOS Path-A producer (labelle-assembler#131). Returns the same
/// device sokol acquires for the swapchain — safe to call any number
/// of times per frame. `null` on non-Metal builds and pre-init
/// (sapp not valid yet).
///
/// Path A wraps each IOSurface as an `MTLTexture` via
/// `[device newTextureWithDescriptor:iosurface:plane:]` — the device
/// pointer is the *only* sokol-side resource we still need. The
/// drawable accessor that the Path-B blit chain needed
/// (`sapp_metal_get_current_drawable`, lived on the
/// `feat/expose-cached-metal-drawable` sokol-zig fork) is gone from
/// the generated source. The fork itself is now vestigial — its
/// removal is a separate cleanup step.
pub fn metalDevice() ?*const anyopaque {
    if (comptime builtin.target.os.tag != .macos and builtin.target.os.tag != .ios) return null;
    return sapp.getEnvironment().metal.device;
}

/// Hide the sokol-app window from the screen (labelle-assembler#137).
///
/// Called by the generated `main.zig` once the Play-in-Editor preview
/// connection succeeds — the editor's Game View tab is the user-facing
/// surface in that mode, and the standalone sokol-app window is at
/// best redundant and at worst a foot-gun (closing it tears down the
/// whole preview subprocess).
///
/// Why "hide" not "never open": sokol-app insists on creating a real
/// platform window because the Metal swapchain (and the GL/D3D11
/// contexts) need an NSWindow / HWND attached at init time. The
/// cheapest reliable suppression is therefore post-creation — let
/// sokol bring the window up, then yank it off-screen before the user
/// ever sees it. `orderOut:` (macOS) / `ShowWindow(SW_HIDE)` (Win32)
/// are the platform-specific knobs for that; both leave the window
/// fully functional from a swapchain-lifecycle standpoint, just
/// invisible.
///
/// macOS-only for this slice. Windows D3D11 + Linux GL can land as
/// follow-ups; the call is a no-op on every other platform so callers
/// can invoke it unconditionally inside a comptime-agnostic block.
pub fn hideWindow() void {
    if (comptime builtin.target.os.tag != .macos) return;

    const nswin = sapp.macosGetWindow() orelse return;

    // libobjc primitives. Looked up on every call — single-shot path,
    // not hot. `sel_registerName` is idempotent / cached inside libobjc.
    const sel_registerName = @extern(
        *const fn (name: [*:0]const u8) callconv(.c) ?*anyopaque,
        .{ .name = "sel_registerName" },
    );
    // [NSWindow orderOut:nil] — single-arg `id` selector returning void.
    const msgSend_orderOut = @extern(
        *const fn (obj: ?*const anyopaque, sel: ?*anyopaque, sender: ?*anyopaque) callconv(.c) void,
        .{ .name = "objc_msgSend" },
    );

    const sel = sel_registerName("orderOut:") orelse return;
    msgSend_orderOut(nswin, sel, null);
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
