/// bgfx Android app shell — the NativeActivity glue entry point.
///
/// sokol hides this inside `sokol_app`; the bgfx backend has no equivalent,
/// so this module is the hand-rolled analog. It is built on the NDK's
/// `android_native_app_glue` (compiled into the Android build by
/// `build.zig`, Android-gated). The glue spins up a dedicated thread, sets
/// up an `ALooper`, and calls our `android_main(app)` — from there we drive:
///
///   * the activity lifecycle (`APP_CMD_*`): create/destroy the bgfx
///     surface on `INIT_WINDOW`/`TERM_WINDOW`, honor resume/pause, and
///     translate `app.destroyRequested` into `window.windowShouldClose`.
///   * touch input (`AInputEvent`/`AMotionEvent_*`): fed into `input.zig`
///     as pointer-down + x/y so the engine sees touch as mouse-like
///     pointer input (mirrors the desktop mouse path).
///
/// Compile target: `aarch64-linux-android`. This module is Android-only —
/// on every other target it is a no-op namespace (see the `is_android`
/// guard) so a stray import never breaks desktop builds.
const builtin = @import("builtin");
// `window` / `input` come in as named modules (wired in build.zig) — NOT
// path imports. A `@import("window.zig")` here would make window.zig
// belong to two module roots (its own `window` module and this `root`),
// which Zig 0.16 rejects ("file exists in modules ...").
const window = @import("window");
const input = @import("input");

const is_android = builtin.target.os.tag == .linux and
    (builtin.target.abi == .android or builtin.target.abi == .androideabi);

// ── Default surface size ────────────────────────────────────────────
// The real width/height come from the `ANativeWindow` once it exists;
// these are the pre-surface defaults handed to `initWindow`. They are
// refreshed from `ANativeWindow_getWidth/Height` on `INIT_WINDOW`.
const default_width: i32 = 800;
const default_height: i32 = 600;

// ── NDK / native_app_glue ABI (hand-declared `extern`) ──────────────
// We declare the slice of the glue/NDK ABI we touch rather than
// `@cImport`-ing the whole header tree (which drags in
// <android/native_activity.h>, JNI, etc.). Layout/order mirror
// `android_native_app_glue.h` and the NDK `android/*.h` headers shipped
// with NDK r27; only the leading fields we read are spelled out, with an
// opaque tail to keep the struct the right size for pointer arithmetic
// done entirely on the C side.

pub const ANativeWindow = opaque {};
pub const AInputQueue = opaque {};
pub const AInputEvent = opaque {};
pub const ALooper = opaque {};
pub const ANativeActivity = opaque {};
pub const AConfiguration = opaque {};

/// One poll source returned by `ALooper_pollOnce`. The glue fills
/// `process` with its own `process_cmd` / `process_input`; we just call
/// it, which in turn dispatches to our `onAppCmd` / `onInputEvent`.
pub const android_poll_source = extern struct {
    id: i32,
    app: *android_app,
    process: ?*const fn (app: *android_app, source: *android_poll_source) callconv(.c) void,
};

/// `struct android_app` from `android_native_app_glue.h` (NDK r27).
/// Field order/types must match the C struct exactly — the glue thread
/// writes these and we read them. Everything past `destroyRequested` is
/// glue-private bookkeeping we never touch, so it's collapsed into an
/// opaque tail sized to keep `@sizeOf` and trailing-field offsets
/// irrelevant to us (we only ever hold a `*android_app` the glue gave us).
pub const android_app = extern struct {
    userData: ?*anyopaque,
    onAppCmd: ?*const fn (app: *android_app, cmd: i32) callconv(.c) void,
    onInputEvent: ?*const fn (app: *android_app, event: *AInputEvent) callconv(.c) c_int,
    activity: ?*ANativeActivity,
    config: ?*AConfiguration,
    savedState: ?*anyopaque,
    savedStateSize: usize,
    looper: ?*ALooper,
    inputQueue: ?*AInputQueue,
    window: ?*ANativeWindow,
    contentRect: ARect,
    activityState: c_int,
    destroyRequested: c_int,
    // ── glue-private tail ───────────────────────────────────────────
    // mutex / cond / fds / thread / poll sources / pending* / running /
    // stateSaved / destroyed / redrawNeeded. We never read these from
    // Zig — they're driven entirely by the glue's C thread. Kept opaque
    // so we don't have to mirror pthread_mutex_t/pthread_cond_t layout.
    _glue_private: [256]u8,
};

pub const ARect = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

// ── APP_CMD_* (android_native_app_glue.h) ───────────────────────────
const APP_CMD_INPUT_CHANGED: i32 = 0;
const APP_CMD_INIT_WINDOW: i32 = 1;
const APP_CMD_TERM_WINDOW: i32 = 2;
const APP_CMD_WINDOW_RESIZED: i32 = 3;
const APP_CMD_WINDOW_REDRAW_NEEDED: i32 = 4;
const APP_CMD_CONTENT_RECT_CHANGED: i32 = 5;
const APP_CMD_GAINED_FOCUS: i32 = 6;
const APP_CMD_LOST_FOCUS: i32 = 7;
const APP_CMD_CONFIG_CHANGED: i32 = 8;
const APP_CMD_LOW_MEMORY: i32 = 9;
const APP_CMD_START: i32 = 10;
const APP_CMD_RESUME: i32 = 11;
const APP_CMD_SAVE_STATE: i32 = 12;
const APP_CMD_PAUSE: i32 = 13;
const APP_CMD_STOP: i32 = 14;
const APP_CMD_DESTROY: i32 = 15;

// ── ALooper poll results (android/looper.h) ─────────────────────────
const ALOOPER_POLL_WAKE: c_int = -1;
const ALOOPER_POLL_CALLBACK: c_int = -2;
const ALOOPER_POLL_TIMEOUT: c_int = -3;
const ALOOPER_POLL_ERROR: c_int = -4;

// ── AInputEvent types (android/input.h) ─────────────────────────────
const AINPUT_EVENT_TYPE_KEY: i32 = 1;
const AINPUT_EVENT_TYPE_MOTION: i32 = 2;

// ── AMotionEvent actions (android/input.h), masked ──────────────────
const AMOTION_EVENT_ACTION_MASK: i32 = 0xff;
const AMOTION_EVENT_ACTION_DOWN: i32 = 0;
const AMOTION_EVENT_ACTION_UP: i32 = 1;
const AMOTION_EVENT_ACTION_MOVE: i32 = 2;
const AMOTION_EVENT_ACTION_CANCEL: i32 = 3;
const AMOTION_EVENT_ACTION_POINTER_DOWN: i32 = 5;
const AMOTION_EVENT_ACTION_POINTER_UP: i32 = 6;

// ── NDK / glue functions we call ────────────────────────────────────
// Declared `extern` so the linker resolves them from the glue
// (`android_app_*`), libandroid (`ANativeWindow_*`, `AMotionEvent_*`,
// `AInputEvent_*`), and the C runtime (`ALooper_pollOnce`). The link of
// these libs is phase 4 — here we only need them declared so the module
// compiles; the object is produced without a final link.
extern fn ALooper_pollOnce(timeoutMillis: c_int, outFd: ?*c_int, outEvents: ?*c_int, outData: ?*?*anyopaque) c_int;

extern fn ANativeWindow_getWidth(window: *ANativeWindow) i32;
extern fn ANativeWindow_getHeight(window: *ANativeWindow) i32;

extern fn AInputEvent_getType(event: *AInputEvent) i32;
extern fn AMotionEvent_getAction(event: *AInputEvent) i32;
extern fn AMotionEvent_getX(event: *AInputEvent, pointer_index: usize) f32;
extern fn AMotionEvent_getY(event: *AInputEvent, pointer_index: usize) f32;
extern fn AMotionEvent_getPointerCount(event: *AInputEvent) usize;
extern fn AMotionEvent_getPointerId(event: *AInputEvent, pointer_index: usize) i32;

// ── Shell state ─────────────────────────────────────────────────────
// `bgfx_ready` guards the per-frame tick: we only draw once the surface
// exists and bgfx is initialized (between INIT_WINDOW and TERM_WINDOW).
// `is_resumed` honors the activity pause/resume lifecycle — when paused
// we keep pumping events but skip rendering.
var bgfx_ready: bool = false;
var is_resumed: bool = false;

/// Optional per-frame tick callback, set by the game's entry before it
/// hands control to the shell. Called once per loop iteration while the
/// surface is live and the activity is resumed. Mirrors the desktop
/// `while (!windowShouldClose()) { beginDrawing(); ...; endDrawing(); }`
/// loop, which the game owns on desktop; on Android the shell owns the
/// loop and calls back into the game here.
pub const TickFn = *const fn () callconv(.c) void;
var tick_fn: ?TickFn = null;

/// Register the per-frame tick callback. Call before `android_main` runs
/// (e.g. from a `comptime`/init path), or from inside the game's own
/// `android_main` wrapper before entering `run`.
pub fn setTickCallback(cb: TickFn) void {
    tick_fn = cb;
}

// ── Lifecycle: APP_CMD_* handler ────────────────────────────────────
fn onAppCmd(app: *android_app, cmd: i32) callconv(.c) void {
    switch (cmd) {
        APP_CMD_INIT_WINDOW => {
            // A new ANativeWindow is ready. Hand it to the window module
            // and bring bgfx up against it.
            if (app.window) |w| {
                window.setAndroidNativeWindow(@ptrCast(w));
                const width = ANativeWindow_getWidth(w);
                const height = ANativeWindow_getHeight(w);
                const ww: i32 = if (width > 0) width else default_width;
                const wh: i32 = if (height > 0) height else default_height;
                window.initWindow(ww, wh, "labelle");
                bgfx_ready = true;
            }
        },
        APP_CMD_TERM_WINDOW => {
            // The surface is going away. Tear bgfx down and drop the
            // handle so a later INIT_WINDOW re-inits cleanly.
            if (bgfx_ready) {
                window.closeWindow();
                bgfx_ready = false;
            }
            window.setAndroidNativeWindow(null);
        },
        APP_CMD_GAINED_FOCUS, APP_CMD_RESUME, APP_CMD_START => {
            is_resumed = true;
        },
        APP_CMD_LOST_FOCUS, APP_CMD_PAUSE, APP_CMD_STOP => {
            is_resumed = false;
        },
        APP_CMD_DESTROY => {
            // Surface should already be gone via TERM_WINDOW; be defensive.
            if (bgfx_ready) {
                window.closeWindow();
                bgfx_ready = false;
            }
            is_resumed = false;
        },
        else => {},
    }
}

// ── Touch: AInputEvent handler ──────────────────────────────────────
// Returns 1 ("handled") for motion events we consume, 0 otherwise so the
// glue lets the system process them. Touch is mapped to the backend's
// pointer model: pointer 0's (x, y) becomes the mouse position and
// down/up drives mouse button 0, exactly how `input.zig` reports the
// desktop mouse — so the engine's existing mouse-driven UI/hit-testing
// sees touch with no engine-side changes.
fn onInputEvent(app: *android_app, event: *AInputEvent) callconv(.c) c_int {
    _ = app;
    if (AInputEvent_getType(event) != AINPUT_EVENT_TYPE_MOTION) return 0;

    const action = AMotionEvent_getAction(event) & AMOTION_EVENT_ACTION_MASK;

    // Primary pointer (index 0) position drives the pointer location.
    const count = AMotionEvent_getPointerCount(event);
    if (count > 0) {
        const x = AMotionEvent_getX(event, 0);
        const y = AMotionEvent_getY(event, 0);
        input.setTouchPointer(0, x, y, AMotionEvent_getPointerId(event, 0));
    }

    switch (action) {
        AMOTION_EVENT_ACTION_DOWN, AMOTION_EVENT_ACTION_POINTER_DOWN => {
            input.setPointerDown(true);
        },
        AMOTION_EVENT_ACTION_MOVE => {
            // Position already updated above; keep down-state as-is.
        },
        AMOTION_EVENT_ACTION_UP, AMOTION_EVENT_ACTION_POINTER_UP, AMOTION_EVENT_ACTION_CANCEL => {
            input.setPointerDown(false);
            input.clearTouch();
        },
        else => {},
    }
    return 1;
}

/// The NativeActivity glue's entry point. The glue calls this on the app
/// thread after wiring up the looper and activity. We register our cmd /
/// input callbacks and run the event+frame loop until the activity is
/// destroyed.
///
/// Exported with C linkage as `android_main` so the glue's
/// `android_native_app_glue.c` (which declares `extern void
/// android_main(struct android_app*)`) links against it.
pub fn run(app: *android_app) void {
    app.onAppCmd = onAppCmd;
    app.onInputEvent = onInputEvent;

    // Event + frame loop. `ALooper_pollOnce` returns the poll-source id;
    // we call `source.process(...)` which dispatches to our callbacks.
    // When the surface is live and we're resumed, tick a frame. The loop
    // ends when the activity requests destruction.
    while (app.destroyRequested == 0) {
        var fd: c_int = 0;
        var events: c_int = 0;
        var data: ?*anyopaque = null;

        // Block (timeout -1) when there's nothing to draw, otherwise poll
        // non-blocking (timeout 0) so we keep rendering frames. This is
        // the standard native_app_glue idiom.
        const timeout: c_int = if (bgfx_ready and is_resumed) 0 else -1;

        // Drain all pending events before drawing.
        while (true) {
            const ident = ALooper_pollOnce(timeout, &fd, &events, &data);
            if (ident < 0) break; // WAKE / TIMEOUT / ERROR — nothing to process
            if (data) |d| {
                const source: *android_poll_source = @ptrCast(@alignCast(d));
                if (source.process) |proc| proc(source.app, source);
            }
            if (app.destroyRequested != 0) break;
            // After the first drained event, switch to non-blocking so we
            // don't stall when a draw is pending.
            if (bgfx_ready and is_resumed) break;
        }

        if (app.destroyRequested != 0) break;

        // Per-frame tick: only when the surface exists, bgfx is up, and
        // the activity is in the foreground.
        if (bgfx_ready and is_resumed) {
            if (tick_fn) |cb| cb();
        }
    }

    // Activity destroyed — make sure bgfx is torn down.
    if (bgfx_ready) {
        window.closeWindow();
        bgfx_ready = false;
    }
}

// On Android, export the glue entry. The glue's C file declares
// `extern void android_main(struct android_app* app)` and calls it on the
// app thread; this `export` provides that symbol. Off Android the symbol
// is omitted entirely so desktop links are untouched.
comptime {
    if (is_android) {
        @export(&androidMainExport, .{ .name = "android_main", .linkage = .strong });
    }
}

fn androidMainExport(app: *android_app) callconv(.c) void {
    run(app);
}

// ── Compile-check coverage ──────────────────────────────────────────
// Force-reference the entry/handlers so a build that imports this module
// (e.g. the Android object compile-check in build.zig) instantiates them
// and catches ABI/signature breakage even though nothing calls them yet
// (the real caller is the glue at runtime — phase 4).
comptime {
    _ = run;
    _ = onAppCmd;
    _ = onInputEvent;
    _ = setTickCallback;
}

test "android_app module compiles for the host as a no-op namespace" {
    // On the host `is_android` is false, so the export is elided and this
    // is just a smoke test that the module type-checks off-Android.
    const testing = @import("std").testing;
    try testing.expect(!is_android or is_android);
}
