/// bgfx input backend — satisfies the engine InputInterface(Impl) contract.
/// Uses GLFW for input on desktop (bgfx doesn't provide input). On
/// Android zglfw isn't available, so the input functions are stubbed
/// (real touch input is phase 3, #302) and `glfw` resolves to an empty
/// namespace — every zglfw reference below is comptime-gated on
/// `is_android` so the module compiles for `aarch64-linux-android`.
const builtin = @import("builtin");

const is_android = builtin.target.os.tag == .linux and
    (builtin.target.abi == .android or builtin.target.abi == .androideabi);

const glfw = if (is_android) struct {} else @import("zglfw");

const MAX_KEYS = 512;
const MAX_MOUSE_BUTTONS = 8;

var keys_down: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS;
var keys_pressed: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS;
var keys_released: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS;

var mouse_down: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;
var mouse_pressed: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;
var mouse_released: [MAX_MOUSE_BUTTONS]bool = [_]bool{false} ** MAX_MOUSE_BUTTONS;

var mouse_x: f32 = 0;
var mouse_y: f32 = 0;
var mouse_wheel: f32 = 0;

// ── Android touch state ─────────────────────────────────────────────
// On Android there is no GLFW mouse — touch is the pointer. The
// NativeActivity glue (src/android_app.zig) feeds these from
// `AMotionEvent_*`. We model a single primary pointer mapped onto
// mouse button 0 + the mouse cursor position, so the engine's existing
// mouse-driven hit-testing/UI sees touch transparently. `touch_active`
// tracks whether a finger is currently on screen (drives `getTouchCount`).
var touch_active: bool = false;
var touch_x: f32 = 0;
var touch_y: f32 = 0;
var touch_id: u64 = 0;
var pointer_down: bool = false;
// Previous-frame down state so `newFrame` can derive press/release edges
// for mouse button 0 from the raw down signal the glue pushes.
var pointer_down_prev: bool = false;

var glfw_window: if (is_android) ?*anyopaque else ?*glfw.Window = null;

/// Bind to a GLFW window for input polling. Android has no GLFW window;
/// the type is `*anyopaque` there and `setWindow` is a no-op (touch
/// input is wired in phase 3, #302).
pub fn setWindow(win: if (is_android) *anyopaque else *glfw.Window) void {
    if (is_android) {
        glfw_window = win;
        return;
    }
    glfw_window = win;
    _ = win.setScrollCallback(scrollCallback);
}

fn scrollCallback(_: *glfw.Window, _: f64, yoffset: f64) callconv(.c) void {
    mouse_wheel = @floatCast(yoffset);
}

/// Call at the start of each frame to reset per-frame state and poll GLFW.
/// On Android the GLFW poll is skipped (no zglfw); touch state will be
/// fed by the NativeActivity glue in phase 3.
pub fn newFrame() void {
    keys_pressed = [_]bool{false} ** MAX_KEYS;
    keys_released = [_]bool{false} ** MAX_KEYS;
    mouse_pressed = [_]bool{false} ** MAX_MOUSE_BUTTONS;
    mouse_released = [_]bool{false} ** MAX_MOUSE_BUTTONS;
    mouse_wheel = 0;

    if (is_android) {
        // Map the touch pointer onto mouse button 0 + the mouse cursor.
        // The glue updates `pointer_down`/`touch_*` asynchronously between
        // frames; derive this-frame press/release edges and mirror the
        // pointer position into the mouse fields the engine already reads.
        mouse_x = touch_x;
        mouse_y = touch_y;
        if (pointer_down and !pointer_down_prev) mouse_pressed[0] = true;
        if (!pointer_down and pointer_down_prev) mouse_released[0] = true;
        mouse_down[0] = pointer_down;
        pointer_down_prev = pointer_down;
        return;
    }

    glfw.pollEvents();

    if (glfw_window) |win| {
        const pos = win.getCursorPos();
        mouse_x = @floatCast(pos[0]);
        mouse_y = @floatCast(pos[1]);
    }
}

// ── Keyboard ──────────────────────────────────────────────

pub fn isKeyDown(key: u32) bool {
    if (is_android) return false; // no keyboard on Android (phase 3 touch)
    if (glfw_window) |win| {
        return win.getKey(@enumFromInt(key)) == .press;
    }
    return false;
}

pub fn isKeyPressed(key: u32) bool {
    return if (key < MAX_KEYS) keys_pressed[key] else false;
}

pub fn isKeyReleased(key: u32) bool {
    return if (key < MAX_KEYS) keys_released[key] else false;
}

// ── Mouse ─────────────────────────────────────────────────

pub fn getMouseX() f32 {
    return mouse_x;
}

pub fn getMouseY() f32 {
    return mouse_y;
}

pub fn isMouseButtonDown(button: u32) bool {
    if (is_android) {
        // Touch maps onto mouse button 0 (see the Android touch state).
        return button < MAX_MOUSE_BUTTONS and mouse_down[button];
    }
    if (glfw_window) |win| {
        return win.getMouseButton(@enumFromInt(button)) == .press;
    }
    return false;
}

pub fn isMouseButtonPressed(button: u32) bool {
    return if (button < MAX_MOUSE_BUTTONS) mouse_pressed[button] else false;
}

pub fn isMouseButtonReleased(button: u32) bool {
    return if (button < MAX_MOUSE_BUTTONS) mouse_released[button] else false;
}

pub fn getMouseWheelMove() f32 {
    return mouse_wheel;
}

// ── Touch ─────────────────────────────────────────────────
//
// Desktop (GLFW) has no touch — every getter returns the empty state.
// On Android the NativeActivity glue (src/android_app.zig) feeds the
// single primary pointer via the setters below; the getters then report
// it as touch index 0 (multi-touch is a later phase).

pub fn getTouchCount() u32 {
    if (is_android) return if (touch_active) 1 else 0;
    return 0; // GLFW desktop: no touch support
}

pub fn getTouchX(index: u32) f32 {
    if (is_android and index == 0 and touch_active) return touch_x;
    return 0;
}

pub fn getTouchY(index: u32) f32 {
    if (is_android and index == 0 and touch_active) return touch_y;
    return 0;
}

pub fn getTouchId(index: u32) u64 {
    if (is_android and index == 0 and touch_active) return touch_id;
    return 0;
}

// ── Android touch feed (called by the NativeActivity glue) ──────────
//
// These are the entry points `src/android_app.zig` calls from the glue's
// input callback. They only mutate state — the per-frame edge derivation
// (press/release on mouse button 0, mouse-position mirroring) happens in
// `newFrame`. Off Android they're inert (state is never read) but kept
// un-gated so the symbol is always present for the shell to reference.

/// Update the primary pointer's position + id (motion DOWN / MOVE).
pub fn setTouchPointer(index: u32, x: f32, y: f32, id: i32) void {
    if (index != 0) return; // single primary pointer for now
    touch_x = x;
    touch_y = y;
    touch_id = @intCast(id);
    touch_active = true;
}

/// Set whether a finger is currently down (drives mouse button 0).
pub fn setPointerDown(down: bool) void {
    pointer_down = down;
}

/// Clear the active touch (motion UP / CANCEL). Position is retained for
/// one more frame so a tap's final coordinate is observable; `touch_active`
/// goes false so `getTouchCount` reports 0.
pub fn clearTouch() void {
    touch_active = false;
}

// ── Gamepad ───────────────────────────────────────────────

pub fn isGamepadAvailable(gamepad: u32) bool {
    if (is_android) return false; // Android gamepads are a later phase
    return glfw.joystickPresent(@enumFromInt(gamepad));
}

pub fn isGamepadButtonDown(gamepad: u32, button: u32) bool {
    _ = gamepad;
    _ = button;
    return false; // TODO: GLFW joystick buttons
}

pub fn isGamepadButtonPressed(gamepad: u32, button: u32) bool {
    _ = gamepad;
    _ = button;
    return false;
}

pub fn getGamepadAxisValue(gamepad: u32, axis: u32) f32 {
    _ = gamepad;
    _ = axis;
    return 0;
}
