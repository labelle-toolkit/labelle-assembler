/// Sokol input backend — satisfies the engine InputInterface(Impl) contract.
/// Uses sokol_app events for keyboard/mouse/touch state.
const builtin = @import("builtin");
const sokol = @import("sokol");
const sapp = sokol.app;

// ── iOS / tvOS gamepad bridge (labelle-assembler#251) ──────────────
//
// sokol_app has no gamepad pipeline of its own, so gamepad state on
// ios/tvos comes from Apple's GameController.framework. The objc bridge
// lives in labelle-core (`src/gamepad_source/ios.zig`) — it owns the single
// `GCController` connection, so there is exactly one set of live state.
//
// This backend module has no dependency edge to labelle-core, so we reach
// the GC state through a tiny exported C ABI rather than a Zig import: the
// core file `@export`s `labelle_gc_*` and we re-declare them `extern` here.
// Both sides are gated on ios/tvos, so on every other target these symbols
// never exist and are never referenced — the gamepad poll methods below fall
// back to the original "no gamepad" behavior.
//
// The exe links both labelle-core (which provides the symbols) and this
// `input` module (which consumes them), and GameController.framework is
// linked by the generated build.zig — so the link resolves on-device.
const gc_enabled = builtin.target.os.tag == .ios or builtin.target.os.tag == .tvos;

const gc = if (gc_enabled) struct {
    extern "c" fn labelle_gc_button_down(slot: u32, button: u32) bool;
    extern "c" fn labelle_gc_axis_value(slot: u32, axis: u32) f32;
    extern "c" fn labelle_gc_connected(slot: u32) bool;
} else struct {};

// ── State ─────────────────────────────────────────────────

var keys_down: [512]bool = [_]bool{false} ** 512;
var keys_pressed: [512]bool = [_]bool{false} ** 512;
var keys_released: [512]bool = [_]bool{false} ** 512;
var mouse_x: f32 = 0;
var mouse_y: f32 = 0;
var mouse_buttons_down: [3]bool = [_]bool{false} ** 3;
var mouse_buttons_pressed: [3]bool = [_]bool{false} ** 3;
var mouse_buttons_released: [3]bool = [_]bool{false} ** 3;
var mouse_wheel: f32 = 0;

const MAX_TOUCHES = 10;
var touch_count: u32 = 0;
var touch_xs: [MAX_TOUCHES]f32 = [_]f32{0} ** MAX_TOUCHES;
var touch_ys: [MAX_TOUCHES]f32 = [_]f32{0} ** MAX_TOUCHES;
var touch_ids: [MAX_TOUCHES]u64 = [_]u64{0} ** MAX_TOUCHES;

// ── Keyboard ──────────────────────────────────────────────

pub fn isKeyDown(key: u32) bool {
    if (key >= 512) return false;
    return keys_down[key];
}

pub fn isKeyPressed(key: u32) bool {
    if (key >= 512) return false;
    return keys_pressed[key];
}

pub fn isKeyReleased(key: u32) bool {
    if (key >= 512) return false;
    return keys_released[key];
}

// ── Mouse ─────────────────────────────────────────────────

pub fn getMouseX() f32 {
    return mouse_x;
}

pub fn getMouseY() f32 {
    return mouse_y;
}

pub fn isMouseButtonDown(btn: u32) bool {
    if (btn >= 3) return false;
    return mouse_buttons_down[btn];
}

pub fn isMouseButtonPressed(btn: u32) bool {
    if (btn >= 3) return false;
    return mouse_buttons_pressed[btn];
}

pub fn isMouseButtonReleased(btn: u32) bool {
    if (btn >= 3) return false;
    return mouse_buttons_released[btn];
}

pub fn getMouseWheelMove() f32 {
    return mouse_wheel;
}

// ── Touch ─────────────────────────────────────────────────

pub fn getTouchCount() u32 {
    return touch_count;
}

pub fn getTouchX(index: u32) f32 {
    if (index >= MAX_TOUCHES) return 0;
    return touch_xs[index];
}

pub fn getTouchY(index: u32) f32 {
    if (index >= MAX_TOUCHES) return 0;
    return touch_ys[index];
}

pub fn getTouchId(index: u32) u64 {
    if (index >= MAX_TOUCHES) return 0;
    return touch_ids[index];
}

// ── Gamepad back-button interception (Android, labelle-assembler#248) ─
//
// On Android the controller "B" button is reported by the system as
// `KEYCODE_BACK`. sokol_app's Android backend hard-consumes `AKEYCODE_BACK`
// in `_sapp_android_key_event` and calls `_sapp_android_shutdown()` directly
// — it never forwards a sokol event for it. So a player pressing B on a
// controller silently quits the game.
//
// We cannot intercept that from the Zig event callback for the *default*
// sokol build, because sokol consumes the key before our `event_cb` runs.
// What we CAN do here is provide the policy hook + state used by the
// interception path, and treat a forwarded BACK/B (when a sokol patch or a
// controller that does NOT alias B→BACK delivers it) as a gamepad button
// rather than a window-close. `consume_back` defaults true so games don't
// exit on B; flip it off if you want BACK to close the app.
//
// On-device wiring (PR checklist): the complete fix routes controller key
// events through the JNI glue's listener path and only forwards true
// navigation BACK (touch / system bar) to the quit path.
pub var consume_back: bool = true;

/// True if `keycode` is the Android BACK key — which is also what a
/// controller B reports on Android. 0x04 == AKEYCODE_BACK. We deliberately
/// do NOT include sokol's ESCAPE (256) here: on desktop, ESCAPE-to-quit is a
/// game-level policy driven by `g.isRunning()`, not a window-close, so
/// guarding it would silently break desktop quit handling.
pub fn isBackKey(keycode: i32) bool {
    return keycode == 0x04; // AKEYCODE_BACK
}

/// Whether a BACK/B key event should be swallowed (kept from quitting the
/// app). Returns true when interception is enabled. The event callback uses
/// this to decide whether to record the key vs. drop it.
pub fn shouldConsumeBack(keycode: i32) bool {
    return consume_back and isBackKey(keycode);
}

// ── Gamepad ───────────────────────────────────────────────
//
// On ios/tvos these forward to the GameController bridge in labelle-core
// (see the `gc` extern block above). On every other target sokol_app has no
// gamepad pipeline, so they return the original defaults.
//
// `isGamepadButtonPressed` needs a rising-edge: GameController is a pure
// state API (`isPressed`), with no "pressed-this-frame" flag. We derive the
// edge by comparing the current `down` state against the previous frame's,
// snapshotted in `newFrame`. Button/axis numbering follows the engine's
// canonical raylib-compatible `GamepadButton`/`GamepadAxis` enums — the same
// values the core bridge maps to GCExtendedGamepad elements.

const MAX_GAMEPADS = 4;
const MAX_GAMEPAD_BUTTONS = 18; // raylib GamepadButton range [0, 17]

// Previous-frame "down" snapshot, used to compute the rising edge in
// `isGamepadButtonPressed`. Updated once per frame in `newFrame`.
var gamepad_prev_down: [MAX_GAMEPADS][MAX_GAMEPAD_BUTTONS]bool =
    [_][MAX_GAMEPAD_BUTTONS]bool{[_]bool{false} ** MAX_GAMEPAD_BUTTONS} ** MAX_GAMEPADS;

pub fn isGamepadAvailable(gamepad_id: u32) bool {
    if (!gc_enabled) return false;
    return gc.labelle_gc_connected(gamepad_id);
}

pub fn isGamepadButtonDown(gamepad_id: u32, button: u32) bool {
    if (!gc_enabled) return false;
    return gc.labelle_gc_button_down(gamepad_id, button);
}

pub fn isGamepadButtonPressed(gamepad_id: u32, button: u32) bool {
    if (!gc_enabled) return false;
    const now = gc.labelle_gc_button_down(gamepad_id, button);
    if (gamepad_id >= MAX_GAMEPADS or button >= MAX_GAMEPAD_BUTTONS) {
        // Out of our edge-tracking range — best-effort "down" (no edge).
        return now;
    }
    return now and !gamepad_prev_down[gamepad_id][button];
}

pub fn getGamepadAxisValue(gamepad_id: u32, axis: u32) f32 {
    if (!gc_enabled) return 0;
    return gc.labelle_gc_axis_value(gamepad_id, axis);
}

/// Snapshot current gamepad button state so the next frame's
/// `isGamepadButtonPressed` can compute the rising edge. No-op off ios/tvos.
fn snapshotGamepadButtons() void {
    if (!gc_enabled) return;
    var g: u32 = 0;
    while (g < MAX_GAMEPADS) : (g += 1) {
        var btn: u32 = 0;
        while (btn < MAX_GAMEPAD_BUTTONS) : (btn += 1) {
            gamepad_prev_down[g][btn] = gc.labelle_gc_button_down(g, btn);
        }
    }
}

// ── Event handling ────────────────────────────────────────

/// Call from the sokol event callback to feed input state.
pub fn handleEvent(ev: [*c]const sapp.Event) void {
    switch (ev.*.type) {
        .KEY_DOWN => {
            const ki: i32 = @intFromEnum(ev.*.key_code);
            // Intercept controller-B/BACK so it doesn't trigger an app quit.
            // When interception is enabled we drop the key entirely (do not
            // record it) so neither sokol nor game code treats it as a
            // window-close. See `shouldConsumeBack` for the sokol-level
            // limitation this works around.
            if (shouldConsumeBack(ki)) return;
            if (ki >= 0 and ki < 512) {
                const k: usize = @intCast(ki);
                keys_down[k] = true;
                keys_pressed[k] = true;
            }
        },
        .KEY_UP => {
            const ki: i32 = @intFromEnum(ev.*.key_code);
            // Symmetric with KEY_DOWN: if we swallow the press, we must also
            // swallow the release. Otherwise BACK/B records a `keys_released`
            // with no matching press, producing a spurious release event.
            if (shouldConsumeBack(ki)) return;
            if (ki >= 0 and ki < 512) {
                const k: usize = @intCast(ki);
                keys_down[k] = false;
                keys_released[k] = true;
            }
        },
        .MOUSE_MOVE => {
            mouse_x = ev.*.mouse_x;
            mouse_y = ev.*.mouse_y;
        },
        .MOUSE_DOWN => {
            const bi: i32 = @intFromEnum(ev.*.mouse_button);
            if (bi >= 0 and bi < 3) {
                const b: usize = @intCast(bi);
                mouse_buttons_down[b] = true;
                mouse_buttons_pressed[b] = true;
            }
        },
        .MOUSE_UP => {
            const bi: i32 = @intFromEnum(ev.*.mouse_button);
            if (bi >= 0 and bi < 3) {
                const b: usize = @intCast(bi);
                mouse_buttons_down[b] = false;
                mouse_buttons_released[b] = true;
            }
        },
        .MOUSE_SCROLL => {
            mouse_wheel = ev.*.scroll_y;
        },
        .TOUCHES_BEGAN, .TOUCHES_MOVED, .TOUCHES_ENDED, .TOUCHES_CANCELLED => {
            touch_count = @intCast(ev.*.num_touches);
            const n: usize = @intCast(ev.*.num_touches);
            // Zig 0.16: chained access like `ev.*.touches[i].field`
            // through a `[*c]` C pointer fails to resolve the field.
            // Copy the touches array to a local first, then index it.
            const touches: [8]sapp.Touchpoint = ev[0].touches;
            for (0..n) |i| {
                if (i >= MAX_TOUCHES) break;
                touch_xs[i] = touches[i].pos_x;
                touch_ys[i] = touches[i].pos_y;
                touch_ids[i] = @intCast(touches[i].identifier);
            }
            if (ev.*.type == .TOUCHES_ENDED or ev.*.type == .TOUCHES_CANCELLED) {
                touch_count = 0;
            }
        },
        else => {},
    }
}

/// Re-export Event type for consumers that need it (e.g., GUI adapters).
pub const Event = sapp.Event;

/// Clear per-frame state (call at start of each frame).
pub fn newFrame() void {
    keys_pressed = [_]bool{false} ** 512;
    keys_released = [_]bool{false} ** 512;
    mouse_buttons_pressed = [_]bool{false} ** 3;
    mouse_buttons_released = [_]bool{false} ** 3;
    mouse_wheel = 0;

    // Snapshot the gamepad button state at the frame boundary. Queries made
    // during this frame compare the (continuously-updated) live state against
    // this snapshot to derive `isGamepadButtonPressed`'s rising edge. Keyboard
    // and mouse edges are event-driven (set in `handleEvent`); GameController
    // has no event pipeline here, so the gamepad edge is sampled instead.
    snapshotGamepadButtons();
}

// ── Tests (pure back-key policy; no sokol calls) ──────────────────────────

const std = @import("std");

test "isBackKey matches Android AKEYCODE_BACK only" {
    try std.testing.expect(isBackKey(0x04)); // AKEYCODE_BACK / controller B
    try std.testing.expect(!isBackKey(256)); // ESCAPE — game-level quit, not guarded
    try std.testing.expect(!isBackKey(65)); // 'A'
}

test "shouldConsumeBack honors the consume_back flag" {
    const saved = consume_back;
    defer consume_back = saved;

    consume_back = true;
    try std.testing.expect(shouldConsumeBack(0x04));
    try std.testing.expect(!shouldConsumeBack(65));

    consume_back = false;
    try std.testing.expect(!shouldConsumeBack(0x04));
}
