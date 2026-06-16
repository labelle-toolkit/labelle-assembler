//! Gamepad overlay — a small screen-space panel that visualises the state of
//! the first connected controller: face buttons, d-pad, bumpers, both sticks,
//! and the analog triggers all light up live as they're pressed.
//!
//! Backend-agnostic by construction: it talks only to the `gfx` draw API and
//! the `input` gamepad getters, both of which the bgfx backend implements on
//! desktop (SDL gamepad source) and on Android (the shared `android_gamepad`
//! state fed by `onInputEvent`). The desktop demo (`main.zig`) calls `draw()`
//! from its screen-space HUD pass; the Android example shares this same file.
//!
//! The controller "slot" is the engine's gamepad id. On desktop that's 0; on
//! Android it's the *sparse* InputDevice id, so we scan a range and use the
//! first connected pad rather than assuming 0.

const builtin = @import("builtin");
const gfx = @import("gfx");
const input = @import("input");

// ── Engine canonical GamepadButton / GamepadAxis values (input_types.zig) ───
const BTN_DPAD_UP: u32 = 1;
const BTN_DPAD_RIGHT: u32 = 2;
const BTN_DPAD_DOWN: u32 = 3;
const BTN_DPAD_LEFT: u32 = 4;
const BTN_FACE_UP: u32 = 5; // Y / Triangle
const BTN_FACE_RIGHT: u32 = 6; // B / Circle
const BTN_FACE_DOWN: u32 = 7; // A / Cross
const BTN_FACE_LEFT: u32 = 8; // X / Square
const BTN_LB: u32 = 9;
const BTN_RB: u32 = 11;
const BTN_SELECT: u32 = 13;
const BTN_START: u32 = 15;
const BTN_L3: u32 = 16;
const BTN_R3: u32 = 17;

const AXIS_LEFT_X: u32 = 0;
const AXIS_LEFT_Y: u32 = 1;
const AXIS_RIGHT_X: u32 = 2;
const AXIS_RIGHT_Y: u32 = 3;
const AXIS_LEFT_TRIGGER: u32 = 4;
const AXIS_RIGHT_TRIGGER: u32 = 5;

const is_android = builtin.target.abi == .android or builtin.target.abi == .androideabi;

// How many gamepad ids to probe for a connected pad. On Android the engine's
// gamepad "slot" is the SPARSE InputDevice id, so we scan a wide range. On
// desktop the ids are dense and small, and the GLFW fallback path
// (`.gamepad = .none`) resolves `isGamepadAvailable` via `@enumFromInt(id)` on
// GLFW's 16-value joystick enum — so the desktop range MUST stay within
// [0, 15] to avoid an out-of-range enum. (The default SDL source bounds-checks
// at 4; this cap keeps the no-SDL fallback safe too.) A device id beyond the
// Android cap is not surfaced — acceptable for a demo overlay; a real app
// would learn ids from the `gamepad_connected` event instead.
const SCAN_MAX: u32 = if (is_android) 64 else 16;

// Colours.
const C_PANEL = gfx.Color{ .r = 0, .g = 0, .b = 0, .a = 150 };
const C_IDLE = gfx.Color{ .r = 70, .g = 70, .b = 82, .a = 255 };
const C_LIT = gfx.Color{ .r = 90, .g = 230, .b = 130, .a = 255 };
const C_TEXT = gfx.Color{ .r = 230, .g = 230, .b = 230, .a = 255 };
const C_DIM = gfx.Color{ .r = 150, .g = 150, .b = 160, .a = 255 };
const C_TRACK = gfx.Color{ .r = 40, .g = 40, .b = 50, .a = 220 };
const C_DOT = gfx.Color{ .r = 255, .g = 210, .b = 70, .a = 255 };

/// First connected gamepad id, scanning sparse Android device ids.
fn connectedId() ?u32 {
    var id: u32 = 0;
    while (id < SCAN_MAX) : (id += 1) {
        if (input.isGamepadAvailable(id)) return id;
    }
    return null;
}

fn down(id: u32, button: u32) bool {
    return input.isGamepadButtonDown(id, button);
}

fn btnColor(id: u32, button: u32) gfx.Color {
    return if (down(id, button)) C_LIT else C_IDLE;
}

/// Draw the overlay anchored at the bottom-right of a `screen_w` x `screen_h`
/// design-space surface. No-op label aside, when no pad is connected it shows a
/// dimmed "Gamepad: none" so the panel is discoverable.
pub fn draw(screen_w: f32, screen_h: f32) void {
    const pw: f32 = 250;
    const ph: f32 = 150;
    const px: f32 = screen_w - pw - 8;
    const py: f32 = screen_h - ph - 28; // clear of the demo's bottom info bar

    gfx.drawRectangleRec(.{ .x = px, .y = py, .width = pw, .height = ph }, C_PANEL);

    const maybe_id = connectedId();
    if (maybe_id == null) {
        gfx.drawText("Gamepad: none", px + 10, py + 8, 11, C_DIM);
        gfx.drawText("(connect a controller)", px + 10, py + 26, 9, C_DIM);
        return;
    }
    const id = maybe_id.?;
    gfx.drawText("Gamepad: connected", px + 10, py + 8, 11, C_TEXT);

    // ── Face buttons (diamond): Y top, A bottom, X left, B right ───────────
    const fcx = px + pw - 48;
    const fcy = py + 78;
    const fr: f32 = 13;
    const off: f32 = 22;
    gfx.drawCircle(fcx, fcy - off, fr, btnColor(id, BTN_FACE_UP)); // Y
    gfx.drawCircle(fcx, fcy + off, fr, btnColor(id, BTN_FACE_DOWN)); // A
    gfx.drawCircle(fcx - off, fcy, fr, btnColor(id, BTN_FACE_LEFT)); // X
    gfx.drawCircle(fcx + off, fcy, fr, btnColor(id, BTN_FACE_RIGHT)); // B
    gfx.drawText("Y", fcx - 3, fcy - off - 5, 9, C_DIM);
    gfx.drawText("A", fcx - 3, fcy + off - 5, 9, C_DIM);
    gfx.drawText("X", fcx - off - 3, fcy - 5, 9, C_DIM);
    gfx.drawText("B", fcx + off - 3, fcy - 5, 9, C_DIM);

    // ── D-pad (cross of squares) ───────────────────────────────────────────
    const dcx = px + 40;
    const dcy = py + 78;
    const ds: f32 = 16;
    const dgap: f32 = 17;
    drawCell(dcx, dcy - dgap, ds, btnColor(id, BTN_DPAD_UP));
    drawCell(dcx, dcy + dgap, ds, btnColor(id, BTN_DPAD_DOWN));
    drawCell(dcx - dgap, dcy, ds, btnColor(id, BTN_DPAD_LEFT));
    drawCell(dcx + dgap, dcy, ds, btnColor(id, BTN_DPAD_RIGHT));

    // ── Bumpers (LB / RB) ──────────────────────────────────────────────────
    drawLabeledBar(px + 12, py + 28, 48, 12, btnColor(id, BTN_LB), "LB");
    drawLabeledBar(px + pw - 60, py + 28, 48, 12, btnColor(id, BTN_RB), "RB");

    // ── Sticks (boxes with a dot at the stick position; ring = L3/R3) ──────
    drawStick(px + 30, py + ph - 34, id, AXIS_LEFT_X, AXIS_LEFT_Y, BTN_L3, "L");
    drawStick(px + 78, py + ph - 34, id, AXIS_RIGHT_X, AXIS_RIGHT_Y, BTN_R3, "R");

    // ── Triggers (LT / RT as fill bars; Android pulls 0..1) ────────────────
    drawTrigger(px + pw - 80, py + ph - 50, id, AXIS_LEFT_TRIGGER, "LT");
    drawTrigger(px + pw - 40, py + ph - 50, id, AXIS_RIGHT_TRIGGER, "RT");
}

fn drawCell(cx: f32, cy: f32, s: f32, c: gfx.Color) void {
    gfx.drawRectangleRec(.{ .x = cx - s / 2, .y = cy - s / 2, .width = s, .height = s }, c);
}

fn drawLabeledBar(x: f32, y: f32, w: f32, h: f32, c: gfx.Color, comptime label: [:0]const u8) void {
    gfx.drawRectangleRec(.{ .x = x, .y = y, .width = w, .height = h }, c);
    gfx.drawText(label, x + w / 2 - 6, y + 2, 9, C_TEXT);
}

fn drawStick(cx: f32, cy: f32, id: u32, ax: u32, ay: u32, click: u32, comptime label: [:0]const u8) void {
    const box: f32 = 36;
    gfx.drawRectangleRec(.{ .x = cx - box / 2, .y = cy - box / 2, .width = box, .height = box }, C_TRACK);
    // L3/R3 click tints the box border via an inset highlight.
    if (down(id, click)) {
        gfx.drawRectangleRec(.{ .x = cx - box / 2, .y = cy - box / 2, .width = box, .height = 3 }, C_LIT);
    }
    const half = box / 2 - 4;
    const dx = clampUnit(input.getGamepadAxisValue(id, ax)) * half;
    const dy = clampUnit(input.getGamepadAxisValue(id, ay)) * half;
    gfx.drawCircle(cx + dx, cy + dy, 4, C_DOT);
    gfx.drawText(label, cx - 3, cy + box / 2 + 2, 9, C_DIM);
}

fn drawTrigger(x: f32, y: f32, id: u32, axis: u32, comptime label: [:0]const u8) void {
    const w: f32 = 16;
    const h: f32 = 40;
    gfx.drawRectangleRec(.{ .x = x, .y = y, .width = w, .height = h }, C_TRACK);
    // Triggers arrive 0..1 on the backends this overlay actually ships on —
    // the SDL desktop source and the Android forwarded-axis state both
    // normalize triggers to [0, 1], so a direct clamp is the right fill. (Only
    // the no-SDL GLFW fallback, `.gamepad = .none`, reports raylib-style
    // [-1, 1] triggers; there the bar would track the upper half — an accepted
    // limitation of that non-default config, not the demo's target.)
    const t = clamp01(input.getGamepadAxisValue(id, axis));
    const fill = h * t;
    gfx.drawRectangleRec(.{ .x = x, .y = y + (h - fill), .width = w, .height = fill }, C_LIT);
    gfx.drawText(label, x + 1, y + h + 2, 9, C_DIM);
}

fn clampUnit(v: f32) f32 {
    return if (v < -1) -1 else if (v > 1) 1 else v;
}

fn clamp01(v: f32) f32 {
    return if (v < 0) 0 else if (v > 1) 1 else v;
}
