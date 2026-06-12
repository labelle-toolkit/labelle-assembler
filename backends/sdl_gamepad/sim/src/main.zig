//! Gamepad simulation harness.
//!
//! Drives the toolkit's *real* shared gamepad source
//! (`labelle-assembler/backends/sdl_gamepad`) with a **simulated** controller:
//! an in-process SDL2 *virtual gamecontroller* (no driver, no admin, no
//! physical hardware). We press each button / move each axis on the virtual
//! pad, pump the source the same way a render backend does each frame, and
//! assert the source reports the input back through its public `Source` API
//! (`isAvailable` / `isButtonDown` / `axisValue`).

const std = @import("std");
const gp = @import("sdl_gamepad");
const Source = gp.Source;

// ── SDL2 virtual-joystick API (SDL 2.0.14+) ─────────────────────────────
// These let us create and feed a controller entirely in-process. SDL's
// virtual driver synthesizes a GameController mapping for a device attached
// with type == SDL_JOYSTICK_TYPE_GAMECONTROLLER and the standard 6-axis /
// 15-button layout, so the toolkit source (which uses the GameController API)
// picks it up exactly like a real Xbox/PS pad.
const SDL_JOYSTICK_TYPE_GAMECONTROLLER: c_int = 1;

extern fn SDL_JoystickAttachVirtual(kind: c_int, naxes: c_int, nbuttons: c_int, nhats: c_int) c_int;
extern fn SDL_JoystickDetachVirtual(device_index: c_int) c_int;
extern fn SDL_JoystickOpen(device_index: c_int) ?*anyopaque;
extern fn SDL_JoystickClose(joystick: *anyopaque) void;
extern fn SDL_JoystickSetVirtualButton(joystick: *anyopaque, button: c_int, value: u8) c_int;
extern fn SDL_JoystickSetVirtualAxis(joystick: *anyopaque, axis: c_int, value: i16) c_int;
extern fn SDL_NumJoysticks() c_int;
extern fn SDL_Delay(ms: u32) void;
extern fn SDL_GetError() [*:0]const u8;

// SDL_GameControllerButton enum values (SDL_gamecontroller.h).
const SdlButton = struct {
    idx: c_int,
    name: []const u8,
};
const sdl_buttons = [_]SdlButton{
    .{ .idx = 0, .name = "A (south)" },
    .{ .idx = 1, .name = "B (east)" },
    .{ .idx = 2, .name = "X (west)" },
    .{ .idx = 3, .name = "Y (north)" },
    .{ .idx = 4, .name = "Back" },
    .{ .idx = 5, .name = "Guide" },
    .{ .idx = 6, .name = "Start" },
    .{ .idx = 7, .name = "Left Stick" },
    .{ .idx = 8, .name = "Right Stick" },
    .{ .idx = 9, .name = "Left Shoulder" },
    .{ .idx = 10, .name = "Right Shoulder" },
    .{ .idx = 11, .name = "D-Pad Up" },
    .{ .idx = 12, .name = "D-Pad Down" },
    .{ .idx = 13, .name = "D-Pad Left" },
    .{ .idx = 14, .name = "D-Pad Right" },
};

// SDL_GameControllerAxis enum values.
const SDL_AXIS_LEFTX: c_int = 0;
const SDL_AXIS_LEFTY: c_int = 1;
const SDL_AXIS_RIGHTX: c_int = 2;
const SDL_AXIS_RIGHTY: c_int = 3;
const SDL_AXIS_TRIGGERLEFT: c_int = 4;
const SDL_AXIS_TRIGGERRIGHT: c_int = 5;

var passes: u32 = 0;
var fails: u32 = 0;

fn check(label: []const u8, ok: bool) void {
    if (ok) passes += 1 else fails += 1;
    std.debug.print("  [{s}] {s}\n", .{ if (ok) "PASS" else "FAIL", label });
}

/// Pump the source like a backend frame loop: one SDL/source update per "frame".
fn pump(frames: usize) void {
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        Source.update();
        SDL_Delay(8);
    }
}

pub fn main() void {
    std.debug.print("== labelle gamepad simulation (SDL2 virtual gamecontroller) ==\n\n", .{});

    // 1) Bring up the toolkit's gamepad source (inits SDL joystick/gc subsystems).
    Source.init();

    // 2) Attach a simulated controller: standard 6 axes / 15 buttons / 0 hats.
    const dev = SDL_JoystickAttachVirtual(SDL_JOYSTICK_TYPE_GAMECONTROLLER, 6, 15, 0);
    if (dev < 0) {
        std.debug.print("FATAL: SDL_JoystickAttachVirtual failed: {s}\n", .{SDL_GetError()});
        std.process.exit(1);
    }
    const js = SDL_JoystickOpen(dev) orelse {
        std.debug.print("FATAL: SDL_JoystickOpen failed: {s}\n", .{SDL_GetError()});
        std.process.exit(1);
    };
    defer {
        SDL_JoystickClose(js);
        _ = SDL_JoystickDetachVirtual(dev);
    }
    std.debug.print("Attached virtual controller at device index {d} (SDL sees {d} joystick(s)).\n\n", .{ dev, SDL_NumJoysticks() });

    // 3) Pump until the source detects the connect (drains CONTROLLERDEVICEADDED).
    var f: usize = 0;
    while (f < 60 and !Source.isAvailable(0)) : (f += 1) pump(1);

    std.debug.print("Connect detection:\n", .{});
    check("source reports a controller available in slot 0", Source.isAvailable(0));
    std.debug.print("\n", .{});

    if (!Source.isAvailable(0)) {
        std.debug.print("Controller never became available; aborting input tests.\n", .{});
        std.process.exit(1);
    }

    // 4) Press every button on the simulated pad; assert the source maps it
    //    to the expected canonical button and reports it held.
    std.debug.print("Button input (press on virtual pad -> read via Source.isButtonDown):\n", .{});
    for (sdl_buttons) |btn| {
        const canonical = gp.sdlButtonToCanonical(btn.idx) orelse {
            std.debug.print("  [SKIP] {s}: no canonical mapping\n", .{btn.name});
            continue;
        };
        _ = SDL_JoystickSetVirtualButton(js, btn.idx, 1); // press
        pump(2);
        const down = Source.isButtonDown(0, canonical);
        _ = SDL_JoystickSetVirtualButton(js, btn.idx, 0); // release
        pump(2);
        const up = !Source.isButtonDown(0, canonical);

        var buf: [96]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s} -> canonical {d}: press={s} release={s}", .{
            btn.name, canonical, if (down) "down" else "MISS", if (up) "up" else "STUCK",
        }) catch btn.name;
        check(label, down and up);
    }
    std.debug.print("\n", .{});

    // 5) Move the axes; assert the source reports the normalized value.
    std.debug.print("Axis input (move on virtual pad -> read via Source.axisValue):\n", .{});
    testAxis(js, SDL_AXIS_LEFTX, 32767, gp.Axis.left_x, 1.0, "Left stick X full right -> +1.0");
    testAxis(js, SDL_AXIS_LEFTY, -32768, gp.Axis.left_y, -1.0, "Left stick Y full up -> -1.0");
    testAxis(js, SDL_AXIS_RIGHTX, -32768, gp.Axis.right_x, -1.0, "Right stick X full left -> -1.0");
    testAxis(js, SDL_AXIS_RIGHTY, 32767, gp.Axis.right_y, 1.0, "Right stick Y full down -> +1.0");
    testAxis(js, SDL_AXIS_TRIGGERLEFT, 32767, gp.Axis.left_trigger, 1.0, "Left trigger full -> 1.0");
    testAxis(js, SDL_AXIS_TRIGGERRIGHT, 32767, gp.Axis.right_trigger, 1.0, "Right trigger full -> 1.0");
    // Recenter sticks / release triggers.
    _ = SDL_JoystickSetVirtualAxis(js, SDL_AXIS_LEFTX, 0);
    _ = SDL_JoystickSetVirtualAxis(js, SDL_AXIS_LEFTY, 0);
    _ = SDL_JoystickSetVirtualAxis(js, SDL_AXIS_RIGHTX, 0);
    _ = SDL_JoystickSetVirtualAxis(js, SDL_AXIS_RIGHTY, 0);
    _ = SDL_JoystickSetVirtualAxis(js, SDL_AXIS_TRIGGERLEFT, 0);
    _ = SDL_JoystickSetVirtualAxis(js, SDL_AXIS_TRIGGERRIGHT, 0);
    pump(2);
    std.debug.print("\n", .{});

    // 6) Bonus: a full trigger pull should synthesize the analog-trigger button.
    std.debug.print("Synthesized analog-trigger button:\n", .{});
    _ = SDL_JoystickSetVirtualAxis(js, SDL_AXIS_TRIGGERRIGHT, 32767);
    pump(2);
    check("right trigger pull -> right_trigger_2 button down", Source.isButtonDown(0, gp.Button.right_trigger_2));
    _ = SDL_JoystickSetVirtualAxis(js, SDL_AXIS_TRIGGERRIGHT, 0);
    pump(2);
    std.debug.print("\n", .{});

    // 7) Multi-gamepad: a second simultaneous pad must land in the next free
    //    slot with fully independent state; detaching it must free its slot
    //    without disturbing the first pad; and a later pad must reuse the
    //    freed slot (lowest-free-slot policy). Pad 2 (not pad 1) is the one
    //    detached here so the deferred cleanup of `js`/`dev` stays valid.
    std.debug.print("Multi-gamepad (second simultaneous virtual pad):\n", .{});
    const dev2 = SDL_JoystickAttachVirtual(SDL_JOYSTICK_TYPE_GAMECONTROLLER, 6, 15, 0);
    if (dev2 < 0) {
        std.debug.print("FATAL: second SDL_JoystickAttachVirtual failed: {s}\n", .{SDL_GetError()});
        std.process.exit(1);
    }
    const js2 = SDL_JoystickOpen(dev2) orelse {
        std.debug.print("FATAL: second SDL_JoystickOpen failed: {s}\n", .{SDL_GetError()});
        std.process.exit(1);
    };

    f = 0;
    while (f < 60 and !Source.isAvailable(1)) : (f += 1) pump(1);
    check("second pad lands in slot 1", Source.isAvailable(1));
    check("slot 0 still available alongside slot 1", Source.isAvailable(0));

    // Button independence: press A on pad 2 only — down on slot 1, NOT slot 0.
    if (gp.sdlButtonToCanonical(0)) |a_canon| {
        _ = SDL_JoystickSetVirtualButton(js2, 0, 1);
        pump(2);
        check("A on pad 2 -> down on slot 1", Source.isButtonDown(1, a_canon));
        check("A on pad 2 -> NOT down on slot 0", !Source.isButtonDown(0, a_canon));
        _ = SDL_JoystickSetVirtualButton(js2, 0, 0);
        pump(2);
    }

    // Axis independence: full left-X on pad 2; slot 0 stays centered.
    _ = SDL_JoystickSetVirtualAxis(js2, SDL_AXIS_LEFTX, 32767);
    pump(2);
    check("left-X on pad 2 -> slot 1 reads +1.0", @abs(Source.axisValue(1, gp.Axis.left_x) - 1.0) < 0.1);
    check("left-X on pad 2 -> slot 0 stays centered", @abs(Source.axisValue(0, gp.Axis.left_x)) < 0.1);
    _ = SDL_JoystickSetVirtualAxis(js2, SDL_AXIS_LEFTX, 0);
    pump(2);

    // Detach pad 2: its slot frees, pad 1 keeps running.
    SDL_JoystickClose(js2);
    _ = SDL_JoystickDetachVirtual(dev2);
    f = 0;
    while (f < 60 and Source.isAvailable(1)) : (f += 1) pump(1);
    check("detaching pad 2 frees slot 1", !Source.isAvailable(1));
    check("slot 0 unaffected by pad 2 detach", Source.isAvailable(0));

    // Lowest-free-slot reuse: a third pad must take the freed slot 1.
    const dev3 = SDL_JoystickAttachVirtual(SDL_JOYSTICK_TYPE_GAMECONTROLLER, 6, 15, 0);
    if (dev3 >= 0) {
        if (SDL_JoystickOpen(dev3)) |js3| {
            f = 0;
            while (f < 60 and !Source.isAvailable(1)) : (f += 1) pump(1);
            check("third pad reuses freed slot 1", Source.isAvailable(1));
            SDL_JoystickClose(js3);
            _ = SDL_JoystickDetachVirtual(dev3);
            pump(2);
        } else {
            check("third pad opens", false);
        }
    } else {
        check("third pad attaches", false);
    }
    std.debug.print("\n", .{});

    std.debug.print("== Summary: {d} passed, {d} failed ==\n", .{ passes, fails });
    if (fails != 0) std.process.exit(1);
}

fn testAxis(js: *anyopaque, sdl_axis: c_int, raw: i16, canonical: u32, expected: f32, label: []const u8) void {
    _ = SDL_JoystickSetVirtualAxis(js, sdl_axis, raw);
    pump(2);
    const got = Source.axisValue(0, canonical);
    const ok = @abs(got - expected) < 0.1;
    var buf: [128]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s} (got {d:.2})", .{ label, got }) catch label;
    check(full, ok);
}
