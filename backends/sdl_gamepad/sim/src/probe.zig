//! Raw-SDL diagnostic: open the first game controller and dump exactly what
//! SDL reports — name, type, mapping string, and live button/axis state — so
//! we can see whether a discrepancy (e.g. buttons missing on a ViGEmBus pad)
//! originates in SDL itself or in the toolkit wrapper.
//!
//! The `SDL_HINT_JOYSTICK_HIDAPI` value is taken from the env var PROBE_HIDAPI
//! ("1" or "0") so we can A/B the HIDAPI vs XInput code path the toolkit forces
//! on ("1").

const std = @import("std");

const SDL_INIT_JOYSTICK: u32 = 0x00000200;
const SDL_INIT_GAMECONTROLLER: u32 = 0x00002000;

extern fn SDL_InitSubSystem(flags: u32) c_int;
extern fn SDL_SetHint(name: [*:0]const u8, value: [*:0]const u8) c_int;
extern fn SDL_NumJoysticks() c_int;
extern fn SDL_IsGameController(index: c_int) c_int;
extern fn SDL_GameControllerOpen(index: c_int) ?*anyopaque;
extern fn SDL_GameControllerName(ctrl: *anyopaque) ?[*:0]const u8;
extern fn SDL_GameControllerMapping(ctrl: *anyopaque) ?[*:0]const u8;
extern fn SDL_GameControllerGetType(ctrl: *anyopaque) c_int;
extern fn SDL_GameControllerUpdate() void;
extern fn SDL_GameControllerGetButton(ctrl: *anyopaque, button: c_int) u8;
extern fn SDL_GameControllerGetAxis(ctrl: *anyopaque, axis: c_int) i16;
extern fn SDL_Delay(ms: u32) void;
extern fn SDL_GetError() [*:0]const u8;
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const btn_names = [_][]const u8{
    "A", "B", "X", "Y", "Back", "Guide", "Start", "LStick", "RStick", "LShldr", "RShldr", "DpUp", "DpDn", "DpLf", "DpRt",
};
const axis_names = [_][]const u8{ "LX", "LY", "RX", "RY", "LT", "RT" };

pub fn main() void {
    const hidapi: [*:0]const u8 = getenv("PROBE_HIDAPI") orelse "1";
    // Default: disable RawInput + WGI so SDL drives the (emulated) XInput pad
    // through the plain XInput backend, whose button/stick correlation does
    // not depend on matching a separate RawInput HID device. Override each
    // via env (PROBE_RAWINPUT / PROBE_WGI) to A/B.
    const rawinput: [*:0]const u8 = getenv("PROBE_RAWINPUT") orelse "0";
    const wgi: [*:0]const u8 = getenv("PROBE_WGI") orelse "0";
    std.debug.print("== raw SDL probe (HIDAPI={s} RAWINPUT={s} WGI={s}) ==\n", .{ hidapi, rawinput, wgi });

    _ = SDL_SetHint("SDL_JOYSTICK_HIDAPI", hidapi);
    _ = SDL_SetHint("SDL_JOYSTICK_RAWINPUT", rawinput);
    _ = SDL_SetHint("SDL_JOYSTICK_WGI", wgi);
    if (SDL_InitSubSystem(SDL_INIT_GAMECONTROLLER | SDL_INIT_JOYSTICK) != 0) {
        std.debug.print("init failed: {s}\n", .{SDL_GetError()});
        return;
    }

    // Wait for a controller to appear.
    var tries: u32 = 0;
    var idx: c_int = -1;
    while (tries < 40) : (tries += 1) {
        SDL_GameControllerUpdate();
        const n = SDL_NumJoysticks();
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            if (SDL_IsGameController(i) != 0) {
                idx = i;
                break;
            }
        }
        if (idx >= 0) break;
        SDL_Delay(100);
    }
    if (idx < 0) {
        std.debug.print("no game controller found\n", .{});
        return;
    }

    const ctrl = SDL_GameControllerOpen(idx) orelse {
        std.debug.print("open failed: {s}\n", .{SDL_GetError()});
        return;
    };

    const name = SDL_GameControllerName(ctrl) orelse "?";
    std.debug.print("opened controller {d}: '{s}'  type={d}\n", .{ idx, name, SDL_GameControllerGetType(ctrl) });
    if (SDL_GameControllerMapping(ctrl)) |m| {
        std.debug.print("mapping: {s}\n", .{m});
    } else {
        std.debug.print("mapping: <none> ({s})\n", .{SDL_GetError()});
    }
    std.debug.print("\nwatching live state for ~14s...\n", .{});

    var prev_btns: u16 = 0;
    var prev_axis = [_]i16{0} ** axis_names.len;
    var t: u32 = 0;
    while (t < 140) : (t += 1) {
        SDL_GameControllerUpdate();

        var bits: u16 = 0;
        for (0..btn_names.len) |b| {
            if (SDL_GameControllerGetButton(ctrl, @intCast(b)) != 0) bits |= (@as(u16, 1) << @intCast(b));
        }
        if (bits != prev_btns) {
            std.debug.print("[{d:>4}ms] buttons:", .{t * 100});
            if (bits == 0) std.debug.print(" (none)", .{});
            for (0..btn_names.len) |b| {
                if (bits & (@as(u16, 1) << @intCast(b)) != 0) std.debug.print(" {s}", .{btn_names[b]});
            }
            std.debug.print("\n", .{});
            prev_btns = bits;
        }

        for (0..axis_names.len) |a| {
            const v = SDL_GameControllerGetAxis(ctrl, @intCast(a));
            const d = @as(i32, v) - @as(i32, prev_axis[a]);
            if (@abs(d) > 8000) {
                std.debug.print("[{d:>4}ms] axis {s} = {d}\n", .{ t * 100, axis_names[a], v });
                prev_axis[a] = v;
            }
        }

        SDL_Delay(100);
    }
    std.debug.print("\n== probe done ==\n", .{});
}
