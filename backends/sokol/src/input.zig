/// Sokol input backend — satisfies the engine InputInterface(Impl) contract.
/// Uses sokol_app events for keyboard/mouse/touch state.
const sokol = @import("sokol");
const sapp = sokol.app;

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

// ── Gamepad (not available via sokol_app — return defaults) ─

pub fn isGamepadAvailable(_: u32) bool {
    return false;
}

pub fn isGamepadButtonDown(_: u32, _: u32) bool {
    return false;
}

pub fn isGamepadButtonPressed(_: u32, _: u32) bool {
    return false;
}

pub fn getGamepadAxisValue(_: u32, _: u32) f32 {
    return 0;
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
