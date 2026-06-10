/// Raylib input backend — satisfies the engine InputInterface(Impl) contract.
const std = @import("std");
const rl = @import("raylib");
const core = @import("labelle-core");

const GamepadEvent = core.GamepadEvent;
const GamepadDescription = core.GamepadDescription;

/// raylib supports at most 4 gamepads (MAX_GAMEPADS).
const MAX_GAMEPADS: u32 = 4;

// ── Keyboard ──────────────────────────────────────────────

pub fn isKeyDown(key: u32) bool {
    return rl.isKeyDown(@enumFromInt(key));
}

pub fn isKeyPressed(key: u32) bool {
    return rl.isKeyPressed(@enumFromInt(key));
}

pub fn isKeyReleased(key: u32) bool {
    return rl.isKeyReleased(@enumFromInt(key));
}

// ── Mouse ─────────────────────────────────────────────────

pub fn getMouseX() f32 {
    return @floatFromInt(rl.getMouseX());
}

pub fn getMouseY() f32 {
    return @floatFromInt(rl.getMouseY());
}

pub fn isMouseButtonDown(button: u32) bool {
    return rl.isMouseButtonDown(@enumFromInt(button));
}

pub fn isMouseButtonPressed(button: u32) bool {
    return rl.isMouseButtonPressed(@enumFromInt(button));
}

pub fn isMouseButtonReleased(button: u32) bool {
    return rl.isMouseButtonReleased(@enumFromInt(button));
}

pub fn getMouseWheelMove() f32 {
    return rl.getMouseWheelMove();
}

// ── Touch ─────────────────────────────────────────────────

pub fn getTouchCount() u32 {
    const count = rl.getTouchPointCount();
    return if (count > 0) @intCast(count) else 0;
}

pub fn getTouchX(index: u32) f32 {
    // raylib's getTouchX/Y are no-arg shortcuts for touch 0; for
    // multi-touch the index-aware call is getTouchPosition(index).
    return rl.getTouchPosition(@intCast(index)).x;
}

pub fn getTouchY(index: u32) f32 {
    return rl.getTouchPosition(@intCast(index)).y;
}

pub fn getTouchId(index: u32) u64 {
    return @intCast(rl.getTouchPointId(@intCast(index)));
}

// ── Gamepad ───────────────────────────────────────────────

pub fn isGamepadAvailable(gamepad: u32) bool {
    return rl.isGamepadAvailable(@intCast(gamepad));
}

pub fn isGamepadButtonDown(gamepad: u32, button: u32) bool {
    return rl.isGamepadButtonDown(@intCast(gamepad), @enumFromInt(button));
}

pub fn isGamepadButtonPressed(gamepad: u32, button: u32) bool {
    return rl.isGamepadButtonPressed(@intCast(gamepad), @enumFromInt(button));
}

pub fn getGamepadAxisValue(gamepad: u32, axis: u32) f32 {
    return rl.getGamepadAxisMovement(@intCast(gamepad), @enumFromInt(axis));
}

// ── Gamepad hotplug (labelle-core#18) ─────────────────────
//
// raylib has no connection callback; hotplug is discovered by polling
// rl.isGamepadAvailable() each frame. We keep the previous availability
// snapshot module-level and edge-detect connect/disconnect transitions.

var prev_available: [MAX_GAMEPADS]bool = [_]bool{false} ** MAX_GAMEPADS;

/// Best-guess vendor family from raylib's gamepad name string. raylib does
/// not expose a stable GUID, so glyph selection has to lean on the name.
fn typeHintFromName(name: []const u8) core.gamepad.TypeHint {
    if (containsIgnoreCase(name, "xbox")) return .xbox;
    if (containsIgnoreCase(name, "playstation") or
        containsIgnoreCase(name, "dualsense") or
        containsIgnoreCase(name, "dualshock") or
        containsIgnoreCase(name, "wireless controller")) return .playstation;
    if (containsIgnoreCase(name, "nintendo") or
        containsIgnoreCase(name, "switch") or
        containsIgnoreCase(name, "joy-con") or
        containsIgnoreCase(name, "pro controller")) return .nintendo;
    if (name.len > 0) return .generic;
    return .unknown;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

/// Drain raylib's gamepad hotplug transitions into `out`, returning the
/// number of events written (never more than `out.len`). Edge-detected
/// against the previous poll: a slot that flips available→true emits a
/// `connected` event (name + type_hint best-effort, guid=null,
/// source_class=.gamepad); available→false emits a `disconnected` event.
///
/// The internal `prev_available` snapshot is always updated for every slot,
/// even when `out` is full — so a dropped event is not silently re-emitted
/// on the next poll. (Callers should size `out` >= MAX_GAMEPADS to avoid
/// losing transitions.)
pub fn pollGamepadEvents(out: []GamepadEvent) usize {
    var count: usize = 0;
    var slot: u32 = 0;
    while (slot < MAX_GAMEPADS) : (slot += 1) {
        const now = rl.isGamepadAvailable(@intCast(slot));
        const was = prev_available[slot];
        prev_available[slot] = now;
        if (now == was) continue;

        if (count >= out.len) continue;

        if (now) {
            const name = rl.getGamepadName(@intCast(slot));
            var ev = GamepadEvent.connected(slot, name);
            ev.source_class = .gamepad;
            ev.type_hint = typeHintFromName(name);
            out[count] = ev;
        } else {
            out[count] = GamepadEvent.disconnected(slot);
        }
        count += 1;
    }
    return count;
}

/// Snapshot every currently-visible gamepad slot into `out` (state, not
/// deltas), returning the number written (<= `out.len`). Disconnected slots
/// are reported with `connected = false` and an empty name.
pub fn describeGamepads(out: []GamepadDescription) usize {
    var count: usize = 0;
    var slot: u32 = 0;
    while (slot < MAX_GAMEPADS and count < out.len) : (slot += 1) {
        const available = rl.isGamepadAvailable(@intCast(slot));
        var desc = GamepadDescription{ .slot = slot, .connected = available };
        if (available) {
            const name = rl.getGamepadName(@intCast(slot));
            desc.setName(name);
            desc.source_class = .gamepad;
            desc.type_hint = typeHintFromName(name);
        }
        out[count] = desc;
        count += 1;
    }
    return count;
}

// ── Tests ─────────────────────────────────────────────────
//
// These exercise the pure name→type_hint classification logic, which is
// the only part of the gamepad hotplug path that doesn't need a live
// raylib window/device. pollGamepadEvents / describeGamepads call into
// rl.isGamepadAvailable which requires an initialized window, so they're
// out of scope for unit tests here.

test "typeHintFromName classifies known vendor families" {
    const TypeHint = core.gamepad.TypeHint;
    try std.testing.expectEqual(TypeHint.xbox, typeHintFromName("Xbox Wireless Controller"));
    try std.testing.expectEqual(TypeHint.xbox, typeHintFromName("XBOX 360 For Windows"));
    try std.testing.expectEqual(TypeHint.playstation, typeHintFromName("Sony DualSense Wireless Controller"));
    try std.testing.expectEqual(TypeHint.playstation, typeHintFromName("PLAYSTATION(R)3 Controller"));
    try std.testing.expectEqual(TypeHint.playstation, typeHintFromName("Wireless Controller"));
    try std.testing.expectEqual(TypeHint.nintendo, typeHintFromName("Nintendo Switch Pro Controller"));
    try std.testing.expectEqual(TypeHint.nintendo, typeHintFromName("Joy-Con (L)"));
    try std.testing.expectEqual(TypeHint.generic, typeHintFromName("Generic USB Joystick"));
    try std.testing.expectEqual(TypeHint.unknown, typeHintFromName(""));
}
