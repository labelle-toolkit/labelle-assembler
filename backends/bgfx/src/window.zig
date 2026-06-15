/// bgfx window backend — windowing lifecycle via GLFW + bgfx frame management.
const std = @import("std");
const builtin = @import("builtin");
const zbgfx = @import("zbgfx");
const bgfx = zbgfx.bgfx;
const platform = @import("platform.zig");

/// Android has no GLFW (zglfw is desktop-only). The Android windowing
/// path is fed an `ANativeWindow*` by the NativeActivity glue at runtime
/// (phase 3, #302) via `setAndroidNativeWindow`; on desktop we keep the
/// full GLFW lifecycle below. Every zglfw reference is comptime-gated on
/// this flag so the module compiles for `aarch64-linux-android` with no
/// zglfw import in the graph.
const is_android = builtin.target.os.tag == .linux and
    (builtin.target.abi == .android or builtin.target.abi == .androideabi);

/// zglfw is only imported on desktop targets. On Android `glfw` resolves
/// to an empty namespace so any accidental desktop-only reference fails
/// at compile time rather than dragging in the zglfw module.
const glfw = if (is_android) struct {} else @import("zglfw");

pub const ConfigFlags = struct {
    window_hidden: bool = false,
};

var glfw_window: if (is_android) ?*anyopaque else ?*glfw.Window = null;
var target_fps_val: i32 = 60;
var screen_w: i32 = 800;
var screen_h: i32 = 600;
/// Windowed-mode geometry, captured the moment we go fullscreen so
/// `setFullscreen(false)` restores the window to the same place + size
/// (GLFW's `setMonitor` needs explicit windowed coords on the way back).
var windowed_x: i32 = 0;
var windowed_y: i32 = 0;
var windowed_w: i32 = 800;
var windowed_h: i32 = 600;
/// VSYNC reset flag reused by `applyResize` — matches the value baked
/// into `init.resolution.reset` at window creation.
const RESET_VSYNC: u32 = 0x00000080;
var window_hidden: bool = false;
var clear_color: u32 = 0x1e1e2eff; // dark background RGBA

/// The current surface dimensions. After `initWindow` these hold the real
/// values — on Android that's the `ANativeWindow` size handed over at
/// `INIT_WINDOW`, which can differ from the project's configured default
/// (e.g. a 2000x1200 tablet surface vs. an 800x600 config). The generated
/// Android entry reads `getScreenHeight()` post-init so the engine's
/// coordinate mapping matches the actual surface rather than the config.
pub fn getScreenWidth() i32 {
    return screen_w;
}
pub fn getScreenHeight() i32 {
    return screen_h;
}

/// The native `ANativeWindow*` surface handed over by the NativeActivity
/// glue. bgfx's `PlatformData.nwh` is a `void*`, so we hold it as an
/// opaque pointer here and pass it straight through at init time. Set by
/// `setAndroidNativeWindow` before `initWindow` runs (phase 3 wires the
/// actual surfaceCreated/surfaceDestroyed lifecycle).
var android_native_window: ?*anyopaque = null;

/// Hand the bgfx backend the native `ANativeWindow*` for the current
/// surface. Called from the NativeActivity glue (phase 3, #302). No-op
/// builds that never call this leave `nwh` null, matching desktop's
/// pre-window-creation state.
pub fn setAndroidNativeWindow(handle: ?*anyopaque) void {
    android_native_window = handle;
}

pub fn setConfigFlags(flags: ConfigFlags) void {
    window_hidden = flags.window_hidden;
}

pub fn initWindow(width: i32, height: i32, title: [:0]const u8) void {
    screen_w = width;
    screen_h = height;

    if (is_android) {
        initWindowAndroid(width, height);
    } else {
        initWindowDesktop(width, height, title);
    }
}

/// Android init path: no GLFW. The `ANativeWindow*` surface must have
/// been handed over via `setAndroidNativeWindow` (phase 3); without it
/// `nwh` is null and bgfx init will fail gracefully — phase 2 only proves
/// the plumbing compiles. bgfx selects the GLES/Vulkan renderer for
/// Android from `RendererType.Count` (auto).
fn initWindowAndroid(width: i32, height: i32) void {
    var init: bgfx.Init = undefined;
    bgfx.initCtor(&init);

    init.type = .Count; // auto-select renderer (GLES/Vulkan on Android)
    init.resolution.width = @intCast(width);
    init.resolution.height = @intCast(height);
    init.resolution.reset = 0x00000080; // BGFX_RESET_VSYNC

    // On Android the native window handle is the `ANativeWindow*` handed
    // over by the NativeActivity glue. `ndt` is unused (no display
    // connection like X11), and the handle type is the platform default.
    init.platformData.ndt = null;
    init.platformData.nwh = android_native_window;
    init.platformData.context = null;
    init.platformData.queue = null;
    init.platformData.backBuffer = null;
    init.platformData.backBufferDS = null;
    init.platformData.type = .Default;

    _ = bgfx.init(&init);

    bgfx.setViewClear(0, 0x0001 | 0x0002, clear_color, 1.0, 0);
    bgfx.setViewRect(0, 0, 0, @intCast(width), @intCast(height));
}

/// Desktop init path: GLFW window + bgfx, native handle per OS.
fn initWindowDesktop(width: i32, height: i32, title: [:0]const u8) void {
    glfw.init() catch return;

    // Tell GLFW not to create an OpenGL context — bgfx manages its own
    glfw.windowHint(.client_api, .no_api);

    glfw_window = glfw.createWindow(
        @intCast(width),
        @intCast(height),
        title,
        null,
        null,
    ) catch return;

    const win = glfw_window orelse return;

    // Initialize bgfx
    var init: bgfx.Init = undefined;
    bgfx.initCtor(&init);

    init.type = .Count; // auto-select renderer
    init.resolution.width = @intCast(width);
    init.resolution.height = @intCast(height);
    init.resolution.reset = 0x00000080; // BGFX_RESET_VSYNC

    // Fill in bgfx's native display type (ndt) and native window handle
    // (nwh) for the build target. See src/platform.zig for the source
    // mapping and its unit tests.
    switch (comptime platform.windowHandleSourceFor(builtin.target.os.tag)) {
        .cocoa => {
            init.platformData.ndt = null;
            init.platformData.nwh = glfw.getCocoaWindow(win);
        },
        .win32 => {
            init.platformData.ndt = null;
            init.platformData.nwh = glfw.getWin32Window(win);
        },
        .x11 => {
            init.platformData.ndt = glfw.getX11Display();
            const xid: u32 = glfw.getX11Window(win);
            init.platformData.nwh = @ptrFromInt(@as(usize, xid));
        },
        .wayland => {
            // Not currently selected — Linux/BSD map to .x11 in
            // platform.zig. Kept here so adding Wayland support in a
            // follow-up is a platform.zig change, not a window.zig one.
            init.platformData.ndt = glfw.getWaylandDisplay();
            init.platformData.nwh = glfw.getWaylandWindow(win);
        },
        .unsupported => @compileError("bgfx backend: unsupported OS for window handle"),
    }
    init.platformData.context = null;
    init.platformData.queue = null;
    init.platformData.backBuffer = null;
    init.platformData.backBufferDS = null;
    init.platformData.type = .Default;

    _ = bgfx.init(&init);

    bgfx.setViewClear(0, 0x0001 | 0x0002, clear_color, 1.0, 0);
    bgfx.setViewRect(0, 0, 0, @intCast(width), @intCast(height));

    const input = @import("input");
    input.setWindow(win);
}

pub fn closeWindow() void {
    bgfx.shutdown();
    if (is_android) {
        // No GLFW to tear down; the surface lifecycle is owned by the
        // NativeActivity glue (phase 3). Clear the native-window handle so
        // state is consistent after teardown.
        android_native_window = null;
        glfw_window = null;
        return;
    }
    if (glfw_window) |win| win.destroy();
    glfw.terminate();
    glfw_window = null;
}

pub fn windowShouldClose() bool {
    if (is_android) {
        // The Android activity lifecycle (onDestroy) drives shutdown, not
        // a per-frame close flag. Phase 3 (#302) wires the real signal;
        // until then never request close — returning a "should close" here
        // (e.g. before the surface is handed over at startup, when the
        // handle is still null) would exit the main loop immediately.
        return false;
    }
    if (glfw_window) |win| return win.shouldClose();
    return true;
}

pub fn setTargetFPS(fps: i32) void {
    target_fps_val = fps;
}

/// Update the cached surface size and resize the bgfx backbuffer to
/// match. Called after a fullscreen/windowed switch changes the GLFW
/// framebuffer dimensions; without the `bgfx.reset` the swapchain stays
/// at the old size and the image stretches.
fn applyResize(w: i32, h: i32) void {
    screen_w = w;
    screen_h = h;
    // `.Count` = keep the current backbuffer format (no change).
    bgfx.reset(@intCast(w), @intCast(h), RESET_VSYNC, .Count);
    bgfx.setViewRect(0, 0, 0, @intCast(w), @intCast(h));
}

/// Query whether the window is currently fullscreen. Android is always
/// fullscreen; desktop asks GLFW whether the window is bound to a monitor.
pub fn isFullscreen() bool {
    if (is_android) return true;
    const win = glfw_window orelse return false;
    return win.getMonitor() != null;
}

/// Switch to fullscreen (`on=true`) or windowed (`on=false`). Desktop
/// only — Android is permanently fullscreen, so this is a no-op there.
/// GLFW has no toggle primitive: going fullscreen binds the window to the
/// primary monitor at its current video mode (saving the windowed
/// geometry first); going windowed restores the saved geometry. Either
/// way bgfx is reset to the new framebuffer size.
pub fn setFullscreen(on: bool) void {
    if (is_android) return;
    const win = glfw_window orelse return;
    const already = win.getMonitor() != null;
    if (already == on) return;
    if (on) {
        // Remember where the window was so we can come back to it.
        const pos = win.getPos();
        const size = win.getSize();
        windowed_x = pos[0];
        windowed_y = pos[1];
        windowed_w = size[0];
        windowed_h = size[1];
        const monitor = glfw.getPrimaryMonitor() orelse return;
        const mode = glfw.getVideoMode(monitor) catch return;
        win.setMonitor(monitor, 0, 0, mode.width, mode.height, mode.refresh_rate);
        applyResize(mode.width, mode.height);
    } else {
        win.setMonitor(null, windowed_x, windowed_y, windowed_w, windowed_h, 0);
        applyResize(windowed_w, windowed_h);
    }
}

pub fn beginDrawing() void {
    const input = @import("input");
    input.newFrame();
    bgfx.setViewRect(0, 0, 0, @intCast(screen_w), @intCast(screen_h));
    // Touch view 0 so bgfx ALWAYS clears + presents it, even on a frame
    // with zero draw calls. `setViewRect` alone does NOT do this — bgfx
    // only processes a view that has submitted draws or an explicit
    // `touch`. Without this, any frame that submits nothing to view 0
    // (e.g. a scene whose only content is still loading, or an empty
    // scene) is dropped entirely by bgfx: the clear never runs and the
    // back buffer is presented black. This was the real cause of the
    // "atlas blacks the screen" bug (#317) — loading an atlas left a
    // window of draw-less frames, and those frames went black instead of
    // showing the clear color. (The original comment here claimed to
    // touch the view but only set the rect.)
    bgfx.touch(0);
}

pub fn endDrawing() void {
    _ = bgfx.frame(0);
}

pub fn clearBackground(r: u8, g: u8, b: u8, a: u8) void {
    clear_color = @as(u32, r) << 24 | @as(u32, g) << 16 | @as(u32, b) << 8 | @as(u32, a);
    bgfx.setViewClear(0, 0x0001 | 0x0002, clear_color, 1.0, 0);
}

pub fn drawText(text: [:0]const u8, x: i32, y: i32, font_size: i32, r: u8, g: u8, b: u8, a: u8) void {
    _ = text;
    _ = x;
    _ = y;
    _ = font_size;
    _ = r;
    _ = g;
    _ = b;
    _ = a;
    // bgfx debug text could be used here but requires setDebug(BGFX_DEBUG_TEXT)
}
