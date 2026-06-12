//! Live gamepad monitor.
//!
//! Unlike `main.zig` (which fabricates an in-process SDL virtual joystick),
//! this program creates NO device of its own. It just brings up the toolkit's
//! gamepad `Source` and polls it like a render-backend frame loop, printing
//! every change it observes. Point a REAL OS-level controller at it — e.g. a
//! ViGEmBus virtual Xbox 360 pad driven by `feeder.py` — to verify the whole
//! OS-HID -> SDL -> toolkit path end to end.

const std = @import("std");
const gp = @import("sdl_gamepad");
const Source = gp.Source;

fn canonicalName(c: u32) []const u8 {
    return switch (c) {
        gp.Button.left_face_up => "D-Pad Up",
        gp.Button.left_face_right => "D-Pad Right",
        gp.Button.left_face_down => "D-Pad Down",
        gp.Button.left_face_left => "D-Pad Left",
        gp.Button.right_face_up => "Y (north)",
        gp.Button.right_face_right => "B (east)",
        gp.Button.right_face_down => "A (south)",
        gp.Button.right_face_left => "X (west)",
        gp.Button.left_trigger_1 => "Left Shoulder",
        gp.Button.left_trigger_2 => "Left Trigger (analog btn)",
        gp.Button.right_trigger_1 => "Right Shoulder",
        gp.Button.right_trigger_2 => "Right Trigger (analog btn)",
        gp.Button.middle_left => "Back",
        gp.Button.middle => "Guide",
        gp.Button.middle_right => "Start",
        gp.Button.left_thumb => "Left Stick",
        gp.Button.right_thumb => "Right Stick",
        else => "?",
    };
}

const axis_names = [_][]const u8{ "left_x", "left_y", "right_x", "right_y", "left_trigger", "right_trigger" };
const MAX_BTN: u32 = 17;

pub fn main() void {
    const seconds: u64 = 24;

    std.debug.print("== labelle gamepad monitor — watching toolkit Source for {d}s ==\n", .{seconds});
    std.debug.print("   (plug in / start a controller; ViGEmBus pad via feeder.py works)\n\n", .{});

    Source.init();

    var prev_avail = false;
    var prev_btn = [_]bool{false} ** (MAX_BTN + 1);
    var prev_axis = [_]f32{0} ** axis_names.len;

    const ticks = seconds * 10; // 100ms per tick
    var t: u64 = 0;
    while (t < ticks) : (t += 1) {
        Source.update();

        const avail = Source.isAvailable(0);
        if (avail != prev_avail) {
            std.debug.print("[{d:>5.1}s] slot0 {s}\n", .{ tenths(t), if (avail) "CONNECTED" else "disconnected" });
            prev_avail = avail;
            // reset edge state on (dis)connect
            prev_btn = [_]bool{false} ** (MAX_BTN + 1);
            prev_axis = [_]f32{0} ** axis_names.len;
        }

        if (avail) {
            var b: u32 = 1;
            while (b <= MAX_BTN) : (b += 1) {
                const down = Source.isButtonDown(0, b);
                if (down != prev_btn[b]) {
                    std.debug.print("[{d:>5.1}s] button {s:<26} {s}\n", .{ tenths(t), canonicalName(b), if (down) "DOWN" else "up" });
                    prev_btn[b] = down;
                }
            }
            for (axis_names, 0..) |name, i| {
                const v = Source.axisValue(0, @intCast(i));
                if (@abs(v - prev_axis[i]) >= 0.25) {
                    std.debug.print("[{d:>5.1}s] axis   {s:<26} {d: >5.2}\n", .{ tenths(t), name, v });
                    prev_axis[i] = v;
                }
            }
        }

        sdlDelay(100);
    }

    std.debug.print("\n== monitor done ==\n", .{});
}

fn tenths(t: u64) f64 {
    return @as(f64, @floatFromInt(t)) / 10.0;
}

extern fn SDL_Delay(ms: u32) void;
fn sdlDelay(ms: u32) void {
    SDL_Delay(ms);
}
