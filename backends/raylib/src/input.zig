/// Raylib input backend — satisfies the engine InputInterface(Impl) contract.
const std = @import("std");
const builtin = @import("builtin");
const rl = @import("raylib");
const core = @import("labelle-core");

// Desktop gamepad source toggle (core#28 slice 5), forwarded from the backend
// build.zig. When false (`.gamepad = .none` opt-out), the `sdl_gamepad` module
// is NOT in the build graph, so we must not `@import` it — and the gamepad
// surface below resolves to the truly-disabled path (no SDL, no GLFW-native
// fallback). When true (default), behavior is byte-identical to before.
const gamepad_enabled = @import("build_options").gamepad_enabled;
// Opt-in for HIDAPI raw-HID decode in the shared SDL gamepad source; OFF by
// default (HIDAPI's per-connect init stalls the render thread for seconds on
// some platforms). Pushed into the source before its lazy SDL init.
const gamepad_hidapi = @import("build_options").gamepad_hidapi;

// Shared windowless-SDL desktop gamepad source (core#28). On a DESKTOP target
// (and only when wired) the gamepad surface below routes to this instead of
// `rl.isGamepad*`: SDL's per-device HID drivers decode controllers (Nintendo
// Switch / 8BitDo raw-HID) that GLFW — the window/input library raylib bundles
// — cannot. The source gates all its SDL `extern`s behind its own comptime
// `is_desktop`, so on off-desktop targets it is pure-Zig no-ops and we keep
// raylib's behavior. The `@import` lives inside the taken comptime branch so it
// is NOT evaluated when the module is absent (opt-out).
// Mirrors `targetIsDesktop` in build.zig: the build wires the `sdl_gamepad`
// module ONLY when (gamepad_enabled AND desktop target), so the `@import` must
// be gated identically — importing it on a non-desktop target (where it isn't
// in the graph) is a compile error.
const target_is_desktop = blk: {
    const t = builtin.target;
    if (t.abi == .android or t.abi == .androideabi) break :blk false;
    if (t.cpu.arch.isWasm()) break :blk false;
    break :blk switch (t.os.tag) {
        .macos, .windows, .linux => true,
        else => false,
    };
};
// Linux desktop routes to labelle-core's kernel-native udev/evdev source
// instead of the SDL one (core#33 scope 2): same Source surface, no SDL2
// link. Mirrors `targetUsesCoreGamepad` in build.zig — there the build
// neither resolves `sdl_gamepad` nor links SDL2 on Linux, so the SDL
// `@import` below must exclude Linux identically.
const target_is_linux_desktop = target_is_desktop and builtin.target.os.tag == .linux;

const sdl_gp = if (gamepad_enabled and target_is_desktop and !target_is_linux_desktop) @import("sdl_gamepad") else struct {
    pub const is_desktop = false;
};

const GamepadEvent = core.GamepadEvent;
const GamepadDescription = core.GamepadDescription;

/// raylib supports at most 4 gamepads (MAX_GAMEPADS).
const MAX_GAMEPADS: u32 = 4;

/// Linux desktop: gamepad state/hotplug comes from labelle-core's
/// `gamepad_source` (the udev/evdev source — full Source parity with
/// sdl_gamepad, verified by core's uinput CI harness). Resolved at comptime;
/// on every other target `core.gamepad_source.Source` is a no-op fallback
/// and this flag is false, so the branch is eliminated.
const use_core_gamepad = gamepad_enabled and target_is_linux_desktop;

/// Non-Linux desktop (with the source wired): gamepad state/hotplug comes
/// from the shared SDL source; off desktop, keep raylib's GLFW-backed path.
/// Resolved at comptime so the unused branch (and its SDL / rl gamepad refs)
/// is eliminated per target. False whenever opted out.
const use_sdl_gamepad = gamepad_enabled and sdl_gp.is_desktop;

/// True when gamepad input is entirely disabled: the opt-out build with no SDL
/// source AND no GLFW-native fallback. In this mode every query short-circuits
/// to false/0/empty BEFORE touching `rl.isGamepad*`. (When `gamepad_enabled`
/// is true this is always false and the existing SDL/raylib routing stands.)
const gamepad_disabled = !gamepad_enabled;

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
    if (comptime gamepad_disabled) return false;
    if (comptime use_core_gamepad) return core.gamepad_source.Source.isAvailable(gamepad);
    if (comptime use_sdl_gamepad) return sdl_gp.Source.isAvailable(gamepad);
    return rl.isGamepadAvailable(@intCast(gamepad));
}

pub fn isGamepadButtonDown(gamepad: u32, button: u32) bool {
    if (comptime gamepad_disabled) return false;
    if (comptime use_core_gamepad) return core.gamepad_source.Source.isButtonDown(gamepad, button);
    if (comptime use_sdl_gamepad) return sdl_gp.Source.isButtonDown(gamepad, button);
    return rl.isGamepadButtonDown(@intCast(gamepad), @enumFromInt(button));
}

pub fn isGamepadButtonPressed(gamepad: u32, button: u32) bool {
    if (comptime gamepad_disabled) return false;
    if (comptime use_core_gamepad) return core.gamepad_source.Source.isButtonPressed(gamepad, button);
    if (comptime use_sdl_gamepad) return sdl_gp.Source.isButtonPressed(gamepad, button);
    return rl.isGamepadButtonPressed(@intCast(gamepad), @enumFromInt(button));
}

pub fn getGamepadAxisValue(gamepad: u32, axis: u32) f32 {
    if (comptime gamepad_disabled) return 0;
    if (comptime use_core_gamepad) return core.gamepad_source.Source.axisValue(gamepad, axis);
    if (comptime use_sdl_gamepad) return sdl_gp.Source.axisValue(gamepad, axis);
    return rl.getGamepadAxisMovement(@intCast(gamepad), @enumFromInt(axis));
}

/// Pump the desktop gamepad source once per frame: drains hotplug events and
/// refreshes the button-edge snapshot. No-op off desktop. The raylib desktop
/// template calls this at the top of its frame loop (the raylib backend has
/// no `newFrame` of its own — raylib's own gamepad state is pumped inside its
/// window's event poll). Mirrors how the sokol backend calls the source's
/// `update()` from its `newFrame`. On Linux this is the core udev/evdev
/// source (hotplug pump internally throttled to ~1/s); elsewhere the SDL one.
pub fn newFrame() void {
    if (comptime use_core_gamepad) return core.gamepad_source.Source.update();
    if (comptime use_sdl_gamepad) {
        sdl_gp.hidapi_enabled = gamepad_hidapi;
        sdl_gp.Source.update();
    }
}

/// One-time init for the desktop gamepad source (subsystem init + startup
/// controller enumeration). Safe to call repeatedly; no-op off desktop.
pub fn initGamepad() void {
    if (comptime use_core_gamepad) return core.gamepad_source.init();
    if (comptime use_sdl_gamepad) {
        sdl_gp.hidapi_enabled = gamepad_hidapi;
        sdl_gp.Source.init();
    }
}

/// Tear down the desktop gamepad source. No-op off desktop.
pub fn deinitGamepad() void {
    if (comptime use_core_gamepad) return core.gamepad_source.deinit();
    if (comptime use_sdl_gamepad) sdl_gp.Source.deinit();
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

/// Null-safe gamepad name lookup. The raylib-zig wrapper `rl.getGamepadName`
/// returns `[:0]const u8` by calling `std.mem.span` on the raw C pointer — but
/// the underlying `GetGamepadName` returns NULL when the driver exposes no name
/// for an otherwise-available pad (some SDL/GLFW backends), which would panic
/// the wrapper's `std.mem.span`. We call the C extern directly, null-check, and
/// fall back to "" so an unnamed-but-connected pad still emits a clean event.
fn gamepadName(slot: u32) [:0]const u8 {
    const ptr = rl.cdef.GetGamepadName(@intCast(slot));
    if (ptr == null) return "";
    return std.mem.span(ptr);
}

/// Drain raylib's gamepad hotplug transitions into `out`, returning the
/// number of events written (never more than `out.len`). Edge-detected
/// against the previous poll: a slot that flips available→true emits a
/// `connected` event (name + type_hint best-effort, guid=null,
/// source_class=.gamepad); available→false emits a `disconnected` event.
///
/// The internal `prev_available` snapshot is advanced for a slot only once its
/// transition has actually been written to `out`. If `out` fills up mid-drain,
/// the pending edge is left un-acked and re-fires on the next poll rather than
/// being lost. (Callers should still size `out` >= MAX_GAMEPADS so this never
/// triggers in practice.)
pub fn pollGamepadEvents(out: []GamepadEvent) usize {
    if (comptime gamepad_disabled) return 0;
    // On desktop, hotplug comes from the wired source's event ring (populated
    // in `newFrame`→`Source.update`), not raylib's poll-based availability
    // edge-detect. Both sources already emit core `GamepadEvent`s.
    if (comptime use_core_gamepad) return core.gamepad_source.pollEvents(out);
    if (comptime use_sdl_gamepad) return sdl_gp.Source.pollEvents(out);

    var count: usize = 0;
    var slot: u32 = 0;
    while (slot < MAX_GAMEPADS) : (slot += 1) {
        const now = rl.isGamepadAvailable(@intCast(slot));
        const was = prev_available[slot];
        if (now == was) continue;

        // Out of buffer space: leave prev_available unchanged so this edge
        // re-fires on the next drain instead of being silently dropped.
        if (count >= out.len) continue;

        if (now) {
            const name = gamepadName(slot);
            var ev = GamepadEvent.connected(slot, name);
            ev.source_class = .gamepad;
            ev.type_hint = typeHintFromName(name);
            out[count] = ev;
        } else {
            out[count] = GamepadEvent.disconnected(slot);
        }
        prev_available[slot] = now;
        count += 1;
    }
    return count;
}

/// Snapshot every currently-visible gamepad slot into `out` (state, not
/// deltas), returning the number written (<= `out.len`). Disconnected slots
/// are reported with `connected = false` and an empty name.
pub fn describeGamepads(out: []GamepadDescription) usize {
    if (comptime gamepad_disabled) return 0;
    if (comptime use_core_gamepad) return core.gamepad_source.describe(out);
    if (comptime use_sdl_gamepad) return sdl_gp.Source.describe(out);

    var count: usize = 0;
    var slot: u32 = 0;
    while (slot < MAX_GAMEPADS and count < out.len) : (slot += 1) {
        const available = rl.isGamepadAvailable(@intCast(slot));
        var desc = GamepadDescription{ .slot = slot, .connected = available };
        if (available) {
            const name = gamepadName(slot);
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
