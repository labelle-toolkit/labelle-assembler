/// Null input backend — satisfies the engine InputInterface(Impl) contract
/// with no-op implementations. Every key is "up", every button is "released",
/// the mouse sits at (0,0). Any script that reads input on the null backend
/// observes a quiescent device — useful for deterministic tick-loop tests.
const std = @import("std");

// ── Keyboard ──────────────────────────────────────────────

pub fn isKeyDown(key: u32) bool {
    _ = key;
    return false;
}

pub fn isKeyPressed(key: u32) bool {
    _ = key;
    return false;
}

pub fn isKeyReleased(key: u32) bool {
    _ = key;
    return false;
}

// ── Mouse ─────────────────────────────────────────────────

pub fn getMouseX() f32 {
    return 0;
}

pub fn getMouseY() f32 {
    return 0;
}

pub fn isMouseButtonDown(button: u32) bool {
    _ = button;
    return false;
}

pub fn isMouseButtonPressed(button: u32) bool {
    _ = button;
    return false;
}

pub fn isMouseButtonReleased(button: u32) bool {
    _ = button;
    return false;
}

pub fn getMouseWheelMove() f32 {
    return 0;
}

// ── Touch ─────────────────────────────────────────────────

pub fn getTouchCount() u32 {
    return 0;
}

pub fn getTouchX(index: u32) f32 {
    _ = index;
    return 0;
}

pub fn getTouchY(index: u32) f32 {
    _ = index;
    return 0;
}

pub fn getTouchId(index: u32) u64 {
    _ = index;
    return 0;
}

// ── Gamepad ───────────────────────────────────────────────

pub fn isGamepadAvailable(gamepad: u32) bool {
    _ = gamepad;
    return false;
}

pub fn isGamepadButtonDown(gamepad: u32, button: u32) bool {
    _ = .{ gamepad, button };
    return false;
}

pub fn isGamepadButtonPressed(gamepad: u32, button: u32) bool {
    _ = .{ gamepad, button };
    return false;
}

pub fn getGamepadAxisValue(gamepad: u32, axis: u32) f32 {
    _ = .{ gamepad, axis };
    return 0;
}

test "null input: every read is quiescent" {
    try std.testing.expect(!isKeyDown(0));
    try std.testing.expect(!isMouseButtonDown(0));
    try std.testing.expectEqual(@as(f32, 0), getMouseX());
    try std.testing.expectEqual(@as(u32, 0), getTouchCount());
    try std.testing.expect(!isGamepadAvailable(0));
}
