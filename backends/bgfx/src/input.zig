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

// ── Android analog gamepad state (#310 Stage 4 / #250) ──────────────
//
// The shared `android_gamepad` module (`../android_gamepad`, also used by the
// sokol backend) owns the per-device button/axis state: the Android-keycode →
// canonical `GamepadButton`/`GamepadAxis` mapping, the device-name axis-routing
// quirk table, and the mutex-guarded device table. The bgfx NativeActivity
// shell (`android_app.zig`) feeds it raw `AInputEvent` key/motion data; the
// engine's `(gamepad_id, button/axis)` queries below resolve against it, keyed
// by Android device id (the same id the #248 detection registry emits as its
// hotplug `.slot`). All `agp` references are gated behind `is_android`, so off
// Android the gamepad getters fall back to the GLFW desktop path.
//
// The module is imported on every target (its Android-only `extern`/`@export`
// symbols are gated internally), but its state is only read on Android.
const agp = @import("android_gamepad");

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

        // Snapshot gamepad button state at the frame boundary so the next
        // frame's `isGamepadButtonPressed` can derive the rising edge (#310
        // Stage 4). The shell feeds live key/motion state into `agp`
        // asynchronously between frames via the `applyGamepad*` entry points.
        agp.newFrame();
        return;
    }

    glfw.pollEvents();

    if (glfw_window) |win| {
        const pos = win.getCursorPos();
        mouse_x = @floatCast(pos[0]);
        mouse_y = @floatCast(pos[1]);
    }

    // Snapshot gamepad button edges for this frame's `isGamepadButtonPressed`.
    snapshotGamepads();
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

// ── Android gamepad feed (called by the NativeActivity glue) ────────
//
// The bgfx shell (`android_app.zig`) routes gamepad `AInputEvent`s here:
// key events (BUTTON_*/DPAD_*) via `applyGamepadKey`, and joystick/gamepad
// motion events (analog axes + hat) via `applyGamepadMotion`. Both forward
// into the shared `android_gamepad` state module (mapping + quirk + per-device
// table). The per-frame edge snapshot happens in `newFrame` (`agp.newFrame`).
// Off Android these are inert (the shell only calls them on Android) but kept
// un-gated so the symbol is always present for the shell to reference — `agp`'s
// apply* functions are pure-Zig no-op-safe on the host.

/// Number of forwarded analog axes the shell fills before calling
/// `applyGamepadMotion`. Re-exported from the shared state module so the shell
/// sizes its axis buffer correctly (indices are `agp.FA_*`).
pub const GAMEPAD_AXIS_COUNT = agp.FORWARDED_AXIS_COUNT;

/// Feed a gamepad KEY event (down/up) keyed by Android device id. `keycode`
/// is the raw `AKEYCODE_*` from `AKeyEvent_getKeyCode`.
pub fn applyGamepadKey(device_id: i32, keycode: i32, down: bool) void {
    agp.applyKey(device_id, keycode, down);
}

/// Feed a gamepad MOTION (analog axis snapshot) keyed by Android device id.
/// `axes` is indexed by `agp.FA_*` (X, Y, Z, RZ, RX, RY, LTRIGGER, RTRIGGER,
/// GAS, BRAKE, HAT_X, HAT_Y).
pub fn applyGamepadMotion(device_id: i32, axes: [agp.FORWARDED_AXIS_COUNT]f32) void {
    agp.applyMotion(device_id, axes);
}

// ── Gamepad ───────────────────────────────────────────────
//
// DESKTOP (GLFW): a controller is readable as a "gamepad" only when its GUID
// has an SDL gamecontroller mapping (`glfw.getGamepadState`). We translate the
// engine's canonical raylib-compatible numbering — buttons [0,17], axes [0,5]
// (LX, LY, RX, RY, LT, RT), matching `android_gamepad` + the raylib/sdl
// backends — to GLFW's standard layout. The two "trigger-as-button" canonical
// codes (LEFT/RIGHT_TRIGGER_2) are derived from the analog trigger axes.
//
// NOTE: a controller GLFW can't map (e.g. a Switch-mode Nintendo Pro
// Controller — only SDL's HIDAPI decodes those) reports *present*
// (`joystickPresent`) but yields no gamepad state, so its buttons/axes read as
// released/0. Use an X-input/Xbox pad, or the SDL backend, for those. On macOS,
// reading input also needs Input Monitoring permission for the host binary.
const MAX_GAMEPADS = 16; // GLFW joystick slots 0..15
const CANON_BUTTON_COUNT = 18; // canonical GamepadButton range [0,17]
// GLFW analog triggers rest at -1 and reach +1 fully pressed; treat past the
// midpoint as "down" for the digital LEFT/RIGHT_TRIGGER_2 buttons.
const TRIGGER_BUTTON_THRESHOLD: f32 = 0.0;

// Rising-edge bookkeeping for `isGamepadButtonPressed`, snapshotted in
// `newFrame` (mirrors the keyboard/mouse `*_pressed` pattern). Desktop-only;
// the Android path uses `agp`'s own edge state.
var gp_prev_down: [MAX_GAMEPADS][CANON_BUTTON_COUNT]bool =
    [_][CANON_BUTTON_COUNT]bool{[_]bool{false} ** CANON_BUTTON_COUNT} ** MAX_GAMEPADS;
var gp_pressed: [MAX_GAMEPADS][CANON_BUTTON_COUNT]bool =
    [_][CANON_BUTTON_COUNT]bool{[_]bool{false} ** CANON_BUTTON_COUNT} ** MAX_GAMEPADS;

/// Canonical button → GLFW gamepad button, or null when the canonical code is
/// an analog-trigger button (10/12, derived from the axes) or has no GLFW
/// equivalent (0 = UNKNOWN).
fn canonToGlfwButton(button: u32) ?glfw.Gamepad.Button {
    return switch (button) {
        1 => .dpad_up,
        2 => .dpad_right,
        3 => .dpad_down,
        4 => .dpad_left,
        5 => .y, // RIGHT_FACE_UP
        6 => .b, // RIGHT_FACE_RIGHT
        7 => .a, // RIGHT_FACE_DOWN
        8 => .x, // RIGHT_FACE_LEFT
        9 => .left_bumper, // LEFT_TRIGGER_1
        11 => .right_bumper, // RIGHT_TRIGGER_1
        13 => .back, // MIDDLE_LEFT
        14 => .guide, // MIDDLE
        15 => .start, // MIDDLE_RIGHT
        16 => .left_thumb,
        17 => .right_thumb,
        else => null,
    };
}

/// Resolve a canonical button against an already-fetched GLFW gamepad state.
fn glfwButtonDown(state: glfw.Gamepad.State, button: u32) bool {
    if (button == 10) return state.axes[@intFromEnum(glfw.Gamepad.Axis.left_trigger)] > TRIGGER_BUTTON_THRESHOLD;
    if (button == 12) return state.axes[@intFromEnum(glfw.Gamepad.Axis.right_trigger)] > TRIGGER_BUTTON_THRESHOLD;
    const gb = canonToGlfwButton(button) orelse return false;
    return state.buttons[@intFromEnum(gb)] == .press;
}

/// Desktop: snapshot per-gamepad button edges for `isGamepadButtonPressed`.
/// One `getGamepadState` per slot per frame; derives all canonical buttons
/// from that single state. Called from `newFrame` after `glfw.pollEvents`.
fn snapshotGamepads() void {
    var g: u32 = 0;
    while (g < MAX_GAMEPADS) : (g += 1) {
        const state = glfw.getGamepadState(@enumFromInt(g)) catch {
            // Not a mapped gamepad (or disconnected): clear edges + prev.
            gp_pressed[g] = [_]bool{false} ** CANON_BUTTON_COUNT;
            gp_prev_down[g] = [_]bool{false} ** CANON_BUTTON_COUNT;
            continue;
        };
        var b: u32 = 0;
        while (b < CANON_BUTTON_COUNT) : (b += 1) {
            const now = glfwButtonDown(state, b);
            gp_pressed[g][b] = now and !gp_prev_down[g][b];
            gp_prev_down[g][b] = now;
        }
    }
}

pub fn isGamepadAvailable(gamepad: u32) bool {
    // Android (#310 Stage 4): resolve against the shared per-device state,
    // keyed by Android device id. Connection is established by the JNI
    // detection glue (InputManager enumeration) + first input event.
    if (comptime is_android) return agp.connected(gamepad);
    return glfw.joystickPresent(@enumFromInt(gamepad));
}

pub fn isGamepadButtonDown(gamepad: u32, button: u32) bool {
    if (comptime is_android) return agp.buttonDown(gamepad, button);
    if (gamepad >= MAX_GAMEPADS or button >= CANON_BUTTON_COUNT) return false;
    const state = glfw.getGamepadState(@enumFromInt(gamepad)) catch return false;
    return glfwButtonDown(state, button);
}

pub fn isGamepadButtonPressed(gamepad: u32, button: u32) bool {
    if (comptime is_android) return agp.buttonPressed(gamepad, button);
    // Rising edge computed in `newFrame` from the GLFW state snapshot.
    if (gamepad >= MAX_GAMEPADS or button >= CANON_BUTTON_COUNT) return false;
    return gp_pressed[gamepad][button];
}

pub fn getGamepadAxisValue(gamepad: u32, axis: u32) f32 {
    if (comptime is_android) return agp.axisValue(gamepad, axis);
    // Canonical axes 0..5 == GLFW axes 0..5 (LX, LY, RX, RY, LT, RT).
    if (gamepad >= MAX_GAMEPADS or axis >= glfw.Gamepad.Axis.count) return 0;
    const state = glfw.getGamepadState(@enumFromInt(gamepad)) catch return 0;
    return state.axes[axis];
}

/// bgfx Android backend adapter for labelle-core's backend-agnostic JNI seam
/// (labelle-core#310, Stage 4). Exposes `backendContext()`, which the generated
/// bgfx-Android `main.zig` registers with core
/// (`engine.core.registerAndroidBackend(...)`) so core's gamepad source and the
/// engine's immersive mode can reach the running ANativeActivity / InputManager
/// without core/engine linking any backend symbol directly. See `android.zig`.
//
// Android-only: the adapter imports `labelle-core` (for `AndroidBackendContext`)
// and binds the shell's `labelle_bgfx_get_native_activity` C symbol, neither of
// which is wired into the input module on desktop. Gate the re-export so
// `android.zig` is only analyzed on Android (where `build.zig` wires core in);
// on other targets it resolves to an empty namespace and is never compiled.
pub const android = if (is_android)
    @import("android.zig")
else
    struct {};
