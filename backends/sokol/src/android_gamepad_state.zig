//! Android analog gamepad STATE (labelle-assembler#250).
//!
//! sokol_app on Android drops controller input: gamepad `AKEYCODE_BUTTON_*` /
//! `AKEYCODE_DPAD_*` key events and `AINPUT_SOURCE_JOYSTICK` motion events
//! never surface as `sapp.Event`s. The labelle-toolkit sokol fork
//! (`feat/forward-android-gamepad-events`) instead forwards the *raw* Android
//! data to a registered C callback:
//!
//!   sapp_android_register_gamepad_callback(cb)
//!     cb(const sapp_android_gamepad_event*)   // device id + button OR axes
//!
//! This module owns the assembler side of that contract:
//!   1. registers the callback (the exported `androidGamepadCallback`),
//!   2. accumulates per-device button/axis state, keyed by Android device id,
//!   3. maps the raw Android codes → the engine's canonical raylib-compatible
//!      `GamepadButton` / `GamepadAxis` numbering (same values the iOS bridge
//!      and the raylib/sdl backends use),
//!   4. applies a small Unreal/Unity-style quirk table (sane defaults +
//!      per-device-name axis-routing overrides) for the handful of common pads
//!      that disagree on right-stick / trigger axis routing.
//!
//! ## Slot model
//!
//! The #248 detection registry (`labelle-core/src/gamepad_source/android.zig`)
//! emits hotplug events whose `.slot` is the **Android device id** (the value
//! `InputDevice.getId()` / `AInputEvent_getDeviceId()` returns). The engine
//! therefore queries the state poll methods with `gamepad_id == device_id`.
//! Device ids are sparse (not 0..3), so we keep a small fixed table of
//! `Device` records and look one up (or allocate it) by device id. First
//! sight of a device id (via the callback) allocates a record; the engine's
//! `isGamepadButtonDown(device_id, ...)` then resolves the same record.
//!
//! ## Threading
//!
//! The fork invokes the callback on sokol's Android input/Looper thread while
//! draining the AInputQueue. The engine polls on its update thread. Like the
//! detection registry, we guard the shared table with a mutex; the contention
//! is one short critical section per input event / per query, which is
//! negligible. Edge detection (`pressed`) is sampled at the frame boundary in
//! `newFrame`, matching the iOS bridge.
//!
//! ## Host / cross-compile
//!
//! All `extern` references to the fork's C symbol live behind `is_android`, so
//! on non-Android targets this module compiles to pure Zig with no unresolved
//! symbols — the pure mapping/quirk logic stays host-testable.

const std = @import("std");
const builtin = @import("builtin");

/// Per project convention there is no `Os.Tag.android`; detect via the abi.
pub const is_android = builtin.target.abi == .android or builtin.target.abi == .androideabi;

// ── Canonical engine numbering (raylib-compatible; input_types.zig) ─────────
pub const MAX_BUTTONS = 18; // GamepadButton range [0, 17]
pub const MAX_AXES = 6; // GamepadAxis range [0, 5] (LX, LY, RX, RY, LT, RT)

// Engine GamepadButton values (mirrors input_types.GamepadButton).
const BTN_LEFT_FACE_UP = 1;
const BTN_LEFT_FACE_RIGHT = 2;
const BTN_LEFT_FACE_DOWN = 3;
const BTN_LEFT_FACE_LEFT = 4;
const BTN_RIGHT_FACE_UP = 5;
const BTN_RIGHT_FACE_RIGHT = 6;
const BTN_RIGHT_FACE_DOWN = 7;
const BTN_RIGHT_FACE_LEFT = 8;
const BTN_LEFT_TRIGGER_1 = 9;
const BTN_LEFT_TRIGGER_2 = 10;
const BTN_RIGHT_TRIGGER_1 = 11;
const BTN_RIGHT_TRIGGER_2 = 12;
const BTN_MIDDLE_LEFT = 13;
const BTN_MIDDLE = 14;
const BTN_MIDDLE_RIGHT = 15;
const BTN_LEFT_THUMB = 16;
const BTN_RIGHT_THUMB = 17;

// Engine GamepadAxis values.
const AXIS_LEFT_X = 0;
const AXIS_LEFT_Y = 1;
const AXIS_RIGHT_X = 2;
const AXIS_RIGHT_Y = 3;
const AXIS_LEFT_TRIGGER = 4;
const AXIS_RIGHT_TRIGGER = 5;

// ── Android AKEYCODE_* gamepad constants (android/keycodes.h) ───────────────
const AKEYCODE_DPAD_UP = 19;
const AKEYCODE_DPAD_DOWN = 20;
const AKEYCODE_DPAD_LEFT = 21;
const AKEYCODE_DPAD_RIGHT = 22;
const AKEYCODE_DPAD_CENTER = 23;
const AKEYCODE_BUTTON_A = 96;
const AKEYCODE_BUTTON_B = 97;
// const AKEYCODE_BUTTON_C = 98; // no canonical mapping
const AKEYCODE_BUTTON_X = 99;
const AKEYCODE_BUTTON_Y = 100;
// const AKEYCODE_BUTTON_Z = 101; // no canonical mapping
const AKEYCODE_BUTTON_L1 = 102;
const AKEYCODE_BUTTON_R1 = 103;
const AKEYCODE_BUTTON_L2 = 104;
const AKEYCODE_BUTTON_R2 = 105;
const AKEYCODE_BUTTON_THUMBL = 106;
const AKEYCODE_BUTTON_THUMBR = 107;
const AKEYCODE_BUTTON_START = 108;
const AKEYCODE_BUTTON_SELECT = 109;
const AKEYCODE_BUTTON_MODE = 110;

/// Map an Android keycode to a canonical `GamepadButton` index, or null if it
/// has no canonical equivalent (e.g. BUTTON_C/Z, DPAD_CENTER).
///
/// The Android → Standard Gamepad mapping follows Google's recommended layout
/// (developer.android.com "Handle controller actions"): BUTTON_A is the
/// bottom face, B the right, X the left, Y the top — same physical positions
/// the engine's raylib numbering names `right_face_*`.
pub fn keycodeToButton(keycode: i32) ?u32 {
    return switch (keycode) {
        AKEYCODE_DPAD_UP => BTN_LEFT_FACE_UP,
        AKEYCODE_DPAD_DOWN => BTN_LEFT_FACE_DOWN,
        AKEYCODE_DPAD_LEFT => BTN_LEFT_FACE_LEFT,
        AKEYCODE_DPAD_RIGHT => BTN_LEFT_FACE_RIGHT,
        AKEYCODE_BUTTON_A => BTN_RIGHT_FACE_DOWN,
        AKEYCODE_BUTTON_B => BTN_RIGHT_FACE_RIGHT,
        AKEYCODE_BUTTON_X => BTN_RIGHT_FACE_LEFT,
        AKEYCODE_BUTTON_Y => BTN_RIGHT_FACE_UP,
        AKEYCODE_BUTTON_L1 => BTN_LEFT_TRIGGER_1,
        AKEYCODE_BUTTON_R1 => BTN_RIGHT_TRIGGER_1,
        AKEYCODE_BUTTON_L2 => BTN_LEFT_TRIGGER_2,
        AKEYCODE_BUTTON_R2 => BTN_RIGHT_TRIGGER_2,
        AKEYCODE_BUTTON_THUMBL => BTN_LEFT_THUMB,
        AKEYCODE_BUTTON_THUMBR => BTN_RIGHT_THUMB,
        AKEYCODE_BUTTON_START => BTN_MIDDLE_RIGHT,
        AKEYCODE_BUTTON_SELECT => BTN_MIDDLE_LEFT,
        AKEYCODE_BUTTON_MODE => BTN_MIDDLE,
        else => null,
    };
}

// ── Forwarded-axis indices (mirror sapp_android_gamepad_event axis[]) ───────
// These match the SAPP_ANDROID_GAMEPAD_AXIS_* enum in the patched sokol_app.h.
pub const FA_X = 0;
pub const FA_Y = 1;
pub const FA_Z = 2;
pub const FA_RZ = 3;
pub const FA_RX = 4;
pub const FA_RY = 5;
pub const FA_LTRIGGER = 6;
pub const FA_RTRIGGER = 7;
pub const FA_GAS = 8;
pub const FA_BRAKE = 9;
pub const FA_HAT_X = 10;
pub const FA_HAT_Y = 11;
pub const FORWARDED_AXIS_COUNT = 12;

// ── Quirk table (Unreal/Unity model: sane defaults + name overrides) ────────
//
// Android does NOT standardise which MotionEvent axis carries the right stick
// or the analog triggers — it varies by HID descriptor. The Google-recommended
// default is right-stick on Z/RZ and triggers on LTRIGGER/RTRIGGER, and that's
// what the vast majority of modern pads report, so it's our default `Quirk`.
//
// A few common families disagree; we keep a SMALL name-keyed override table
// (NOT a full SDL_GameControllerDB). Matching is a case-insensitive substring
// on `InputDevice.getName()`.
pub const RightStickSource = enum {
    z_rz, // AXIS_Z → right X, AXIS_RZ → right Y (default; Xbox, DualShock/Sense, most)
    rx_ry, // AXIS_RX → right X, AXIS_RY → right Y (some older / generic HID pads)
};

pub const TriggerSource = enum {
    ltrigger_rtrigger, // AXIS_LTRIGGER / AXIS_RTRIGGER (default; Xbox-style)
    z_rz, // AXIS_Z (L2) / AXIS_RZ (R2) — pads that publish triggers as Z/RZ
    gas_brake, // AXIS_GAS (R2) / AXIS_BRAKE (L2) — DualShock-family on some Android
};

pub const Quirk = struct {
    right_stick: RightStickSource = .z_rz,
    triggers: TriggerSource = .ltrigger_rtrigger,
};

const QuirkEntry = struct {
    /// Case-insensitive substring matched against InputDevice.getName().
    name_substr: []const u8,
    quirk: Quirk,
};

/// Small, deliberately short override table. Add entries only for pads
/// verified on-device to deviate from the Google default. Order matters:
/// first substring match wins.
const quirk_table = [_]QuirkEntry{
    // Xbox One / Series controllers report the standard layout already, but
    // pin it explicitly so a future default change can't silently move them.
    .{ .name_substr = "Xbox", .quirk = .{ .right_stick = .z_rz, .triggers = .ltrigger_rtrigger } },
    // Sony DualShock 4 / DualSense over Android: right stick on Z/RZ, but the
    // analog triggers commonly arrive on GAS (R2) / BRAKE (L2).
    .{ .name_substr = "DualSense", .quirk = .{ .right_stick = .z_rz, .triggers = .gas_brake } },
    .{ .name_substr = "DualShock", .quirk = .{ .right_stick = .z_rz, .triggers = .gas_brake } },
    .{ .name_substr = "Wireless Controller", .quirk = .{ .right_stick = .z_rz, .triggers = .gas_brake } },
    // Nintendo Switch Pro / 8BitDo in Android mode: standard right stick, but
    // several report L2/R2 on Z/RZ rather than the dedicated trigger axes.
    .{ .name_substr = "Pro Controller", .quirk = .{ .right_stick = .z_rz, .triggers = .z_rz } },
    .{ .name_substr = "8BitDo", .quirk = .{ .right_stick = .z_rz, .triggers = .z_rz } },
    // Generic/older HID gamepads that route the right stick onto RX/RY.
    .{ .name_substr = "Generic", .quirk = .{ .right_stick = .rx_ry, .triggers = .ltrigger_rtrigger } },
};

/// Resolve the quirk for a device name. Defaults when nothing matches.
pub fn quirkForName(name: []const u8) Quirk {
    for (quirk_table) |entry| {
        if (containsIgnoreCase(name, entry.name_substr)) return entry.quirk;
    }
    return .{};
}

/// ASCII case-insensitive substring test (same heuristic as the iOS bridge).
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (lower(haystack[i + j]) != lower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Resolve a canonical `GamepadAxis` value to its raw forwarded-axis index,
/// honoring the device quirk. Returns the index into `forwarded_axis[]`.
pub fn axisToForwardedIndex(axis: u32, quirk: Quirk) ?u32 {
    return switch (axis) {
        AXIS_LEFT_X => FA_X,
        AXIS_LEFT_Y => FA_Y,
        AXIS_RIGHT_X => switch (quirk.right_stick) {
            .z_rz => FA_Z,
            .rx_ry => FA_RX,
        },
        AXIS_RIGHT_Y => switch (quirk.right_stick) {
            .z_rz => FA_RZ,
            .rx_ry => FA_RY,
        },
        AXIS_LEFT_TRIGGER => switch (quirk.triggers) {
            .ltrigger_rtrigger => FA_LTRIGGER,
            .z_rz => FA_Z,
            .gas_brake => FA_BRAKE, // L2 → BRAKE
        },
        AXIS_RIGHT_TRIGGER => switch (quirk.triggers) {
            .ltrigger_rtrigger => FA_RTRIGGER,
            .z_rz => FA_RZ,
            .gas_brake => FA_GAS, // R2 → GAS
        },
        else => null,
    };
}

// ── Per-device state table ──────────────────────────────────────────────────

const MAX_DEVICES = 8;

const Device = struct {
    active: bool = false,
    device_id: i32 = 0,
    buttons_down: [MAX_BUTTONS]bool = [_]bool{false} ** MAX_BUTTONS,
    prev_down: [MAX_BUTTONS]bool = [_]bool{false} ** MAX_BUTTONS,
    /// Raw forwarded axis snapshot, indexed by FA_*.
    forwarded_axis: [FORWARDED_AXIS_COUNT]f32 = [_]f32{0} ** FORWARDED_AXIS_COUNT,
    quirk: Quirk = .{},
};

/// Minimal test-and-set spinlock. The shared table is touched from two
/// threads — sokol's Android Looper thread (the forwarded-event callback) and
/// the engine update thread (state queries / newFrame) — but each critical
/// section is a handful of field stores/loads, and the event rate is at most a
/// few per frame. Zig 0.16's `std.Io.Mutex` needs an `Io` instance to lock,
/// which we don't have at this layer; a tiny atomic spinlock is the right tool
/// for a microsecond-scale section and stays dependency-free across targets.
const SpinLock = struct {
    flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *SpinLock) void {
        while (self.flag.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }
    fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

const Table = struct {
    devices: [MAX_DEVICES]Device = [_]Device{.{}} ** MAX_DEVICES,
    mutex: SpinLock = .{},

    fn find(self: *Table, device_id: i32) ?*Device {
        for (&self.devices) |*d| {
            if (d.active and d.device_id == device_id) return d;
        }
        return null;
    }

    /// Find an existing record for `device_id` or allocate a free slot for it.
    /// Returns null only when the table is full (8 simultaneous pads).
    fn findOrAlloc(self: *Table, device_id: i32) ?*Device {
        if (self.find(device_id)) |d| return d;
        for (&self.devices) |*d| {
            if (!d.active) {
                d.* = .{ .active = true, .device_id = device_id };
                return d;
            }
        }
        return null;
    }
};

var table: Table = .{};

// ── Quirk registration from the detection layer (optional) ──────────────────
//
// The detection registry knows the device name; the state callback only gets a
// device id. If the engine wires it, `setDeviceQuirk` lets detection seed the
// quirk before any input arrives. When unused, every device keeps the default
// quirk — still correct for the common case.

/// Set (or refresh) the axis-routing quirk for a device id, derived from its
/// `InputDevice.getName()`. Allocates the record if it does not exist yet.
pub fn setDeviceQuirkByName(device_id: i32, name: []const u8) void {
    table.mutex.lock();
    defer table.mutex.unlock();
    if (table.findOrAlloc(device_id)) |d| {
        d.quirk = quirkForName(name);
    }
}

/// Forget a device id (on disconnect), clearing any state so a later reconnect
/// of the same id starts fresh.
pub fn removeDevice(device_id: i32) void {
    table.mutex.lock();
    defer table.mutex.unlock();
    if (table.find(device_id)) |d| d.* = .{};
}

// ── C ABI for the detection JNI glue (android_gamepad_jni.c) ────────────────
//
// The #248 JNI glue (`android_gamepad_jni.c`) already resolves each device's
// `InputDevice.getName()` and id. It calls these two exports so the state
// module can (a) seed the axis-routing quirk from the device name before any
// input arrives, and (b) drop a device's state on removal. Both live in the
// same backend package as the JNI glue, so the link resolves on-device. The
// exports are gated on `is_android` (no symbol on other targets).

comptime {
    if (is_android) {
        @export(&onDeviceAddedC, .{ .name = "labelle_android_gamepad_state_added", .linkage = .strong });
        @export(&onDeviceRemovedC, .{ .name = "labelle_android_gamepad_state_removed", .linkage = .strong });
    }
}

fn onDeviceAddedC(device_id: i32, name_ptr: [*]const u8, name_len: usize) callconv(.c) void {
    if (comptime !is_android) return;
    setDeviceQuirkByName(device_id, name_ptr[0..name_len]);
}

fn onDeviceRemovedC(device_id: i32) callconv(.c) void {
    if (comptime !is_android) return;
    removeDevice(device_id);
}

// ── Callback ingestion (called from the fork's Looper-thread callback) ──────

/// Apply a forwarded KEY event.
pub fn applyKey(device_id: i32, keycode: i32, down: bool) void {
    const btn = keycodeToButton(keycode) orelse return;
    table.mutex.lock();
    defer table.mutex.unlock();
    if (table.findOrAlloc(device_id)) |d| {
        if (btn < MAX_BUTTONS) d.buttons_down[btn] = down;
    }
}

/// Apply a forwarded MOTION (axis snapshot) event. `axes` is indexed by FA_*.
pub fn applyMotion(device_id: i32, axes: [FORWARDED_AXIS_COUNT]f32) void {
    table.mutex.lock();
    defer table.mutex.unlock();
    if (table.findOrAlloc(device_id)) |d| {
        d.forwarded_axis = axes;
    }
}

// ── State queries (called from the engine update thread) ────────────────────

pub fn connected(device_id: u32) bool {
    table.mutex.lock();
    defer table.mutex.unlock();
    return table.find(@bitCast(device_id)) != null;
}

pub fn buttonDown(device_id: u32, button: u32) bool {
    if (button >= MAX_BUTTONS) return false;
    table.mutex.lock();
    defer table.mutex.unlock();
    const d = table.find(@bitCast(device_id)) orelse return false;
    return d.buttons_down[button];
}

pub fn buttonPressed(device_id: u32, button: u32) bool {
    if (button >= MAX_BUTTONS) return false;
    table.mutex.lock();
    defer table.mutex.unlock();
    const d = table.find(@bitCast(device_id)) orelse return false;
    return d.buttons_down[button] and !d.prev_down[button];
}

pub fn axisValue(device_id: u32, axis: u32) f32 {
    if (axis >= MAX_AXES) return 0;
    table.mutex.lock();
    defer table.mutex.unlock();
    const d = table.find(@bitCast(device_id)) orelse return 0;
    const fi = axisToForwardedIndex(axis, d.quirk) orelse return 0;
    return d.forwarded_axis[fi];
}

/// Snapshot button state at the frame boundary so `buttonPressed` can derive
/// the rising edge next frame. Mirrors the iOS bridge's `snapshotGamepadButtons`.
pub fn newFrame() void {
    table.mutex.lock();
    defer table.mutex.unlock();
    for (&table.devices) |*d| {
        if (d.active) d.prev_down = d.buttons_down;
    }
}

// ── Tests (host-runnable: pure mapping + quirk + state logic, no sokol) ─────

test "keycodeToButton maps face/dpad/shoulder/thumb/middle correctly" {
    try std.testing.expectEqual(@as(?u32, BTN_RIGHT_FACE_DOWN), keycodeToButton(AKEYCODE_BUTTON_A));
    try std.testing.expectEqual(@as(?u32, BTN_RIGHT_FACE_RIGHT), keycodeToButton(AKEYCODE_BUTTON_B));
    try std.testing.expectEqual(@as(?u32, BTN_RIGHT_FACE_LEFT), keycodeToButton(AKEYCODE_BUTTON_X));
    try std.testing.expectEqual(@as(?u32, BTN_RIGHT_FACE_UP), keycodeToButton(AKEYCODE_BUTTON_Y));
    try std.testing.expectEqual(@as(?u32, BTN_LEFT_FACE_UP), keycodeToButton(AKEYCODE_DPAD_UP));
    try std.testing.expectEqual(@as(?u32, BTN_LEFT_TRIGGER_1), keycodeToButton(AKEYCODE_BUTTON_L1));
    try std.testing.expectEqual(@as(?u32, BTN_RIGHT_TRIGGER_2), keycodeToButton(AKEYCODE_BUTTON_R2));
    try std.testing.expectEqual(@as(?u32, BTN_LEFT_THUMB), keycodeToButton(AKEYCODE_BUTTON_THUMBL));
    try std.testing.expectEqual(@as(?u32, BTN_MIDDLE_RIGHT), keycodeToButton(AKEYCODE_BUTTON_START));
    try std.testing.expectEqual(@as(?u32, BTN_MIDDLE), keycodeToButton(AKEYCODE_BUTTON_MODE));
}

test "keycodeToButton ignores non-canonical codes" {
    try std.testing.expectEqual(@as(?u32, null), keycodeToButton(98)); // BUTTON_C
    try std.testing.expectEqual(@as(?u32, null), keycodeToButton(101)); // BUTTON_Z
    try std.testing.expectEqual(@as(?u32, null), keycodeToButton(AKEYCODE_DPAD_CENTER));
    try std.testing.expectEqual(@as(?u32, null), keycodeToButton(0));
}

test "default quirk routes right stick to Z/RZ and triggers to L/RTRIGGER" {
    const q = Quirk{};
    try std.testing.expectEqual(@as(?u32, FA_Z), axisToForwardedIndex(AXIS_RIGHT_X, q));
    try std.testing.expectEqual(@as(?u32, FA_RZ), axisToForwardedIndex(AXIS_RIGHT_Y, q));
    try std.testing.expectEqual(@as(?u32, FA_X), axisToForwardedIndex(AXIS_LEFT_X, q));
    try std.testing.expectEqual(@as(?u32, FA_LTRIGGER), axisToForwardedIndex(AXIS_LEFT_TRIGGER, q));
    try std.testing.expectEqual(@as(?u32, FA_RTRIGGER), axisToForwardedIndex(AXIS_RIGHT_TRIGGER, q));
}

test "rx_ry quirk reroutes right stick" {
    const q = Quirk{ .right_stick = .rx_ry };
    try std.testing.expectEqual(@as(?u32, FA_RX), axisToForwardedIndex(AXIS_RIGHT_X, q));
    try std.testing.expectEqual(@as(?u32, FA_RY), axisToForwardedIndex(AXIS_RIGHT_Y, q));
}

test "gas_brake quirk maps triggers to GAS/BRAKE" {
    const q = Quirk{ .triggers = .gas_brake };
    try std.testing.expectEqual(@as(?u32, FA_BRAKE), axisToForwardedIndex(AXIS_LEFT_TRIGGER, q));
    try std.testing.expectEqual(@as(?u32, FA_GAS), axisToForwardedIndex(AXIS_RIGHT_TRIGGER, q));
}

test "quirkForName matches known families and defaults otherwise" {
    try std.testing.expectEqual(TriggerSource.gas_brake, quirkForName("Sony DualSense Wireless Controller").triggers);
    try std.testing.expectEqual(RightStickSource.rx_ry, quirkForName("Generic USB Gamepad").right_stick);
    try std.testing.expectEqual(TriggerSource.z_rz, quirkForName("Nintendo Switch Pro Controller").triggers);
    // Unknown → defaults.
    const def = quirkForName("Totally Unknown Pad");
    try std.testing.expectEqual(RightStickSource.z_rz, def.right_stick);
    try std.testing.expectEqual(TriggerSource.ltrigger_rtrigger, def.triggers);
}

test "state: key apply, query, edge detection, and removal" {
    // Isolate from any other test touching the module-global table.
    table = .{};
    const id: i32 = 42;
    const uid: u32 = @bitCast(id);

    try std.testing.expect(!connected(uid));
    applyKey(id, AKEYCODE_BUTTON_A, true);
    try std.testing.expect(connected(uid));
    try std.testing.expect(buttonDown(uid, BTN_RIGHT_FACE_DOWN));

    // Rising edge only on the first frame the button is held.
    try std.testing.expect(buttonPressed(uid, BTN_RIGHT_FACE_DOWN));
    newFrame();
    try std.testing.expect(!buttonPressed(uid, BTN_RIGHT_FACE_DOWN)); // still down, not "pressed"
    try std.testing.expect(buttonDown(uid, BTN_RIGHT_FACE_DOWN));

    applyKey(id, AKEYCODE_BUTTON_A, false);
    try std.testing.expect(!buttonDown(uid, BTN_RIGHT_FACE_DOWN));

    removeDevice(id);
    try std.testing.expect(!connected(uid));
}

test "state: axis snapshot honors the device quirk" {
    table = .{};
    const id: i32 = 7;
    const uid: u32 = @bitCast(id);
    setDeviceQuirkByName(id, "Generic USB Gamepad"); // rx_ry

    var axes = [_]f32{0} ** FORWARDED_AXIS_COUNT;
    axes[FA_RX] = 0.5;
    axes[FA_RY] = -0.25;
    axes[FA_Z] = 0.9; // would be right-X under default quirk; must be ignored here
    applyMotion(id, axes);

    try std.testing.expectEqual(@as(f32, 0.5), axisValue(uid, AXIS_RIGHT_X));
    try std.testing.expectEqual(@as(f32, -0.25), axisValue(uid, AXIS_RIGHT_Y));
}

test "out-of-range button/axis queries are safe" {
    table = .{};
    try std.testing.expect(!buttonDown(1, 999));
    try std.testing.expectEqual(@as(f32, 0), axisValue(1, 999));
}
