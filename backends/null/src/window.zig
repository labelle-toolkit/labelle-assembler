/// Null window backend — satisfies the engine windowing contract with
/// no-op implementations. Headless: there is no actual window, no draw
/// surface, no message pump. The generated null-backend `main()` does NOT
/// call `windowShouldClose` in its main loop — it bounds frames via a
/// fixed counter — so this module exists primarily to satisfy module
/// resolution for shared codegen / plugin code.
const std = @import("std");

pub const ConfigFlags = struct {
    window_hidden: bool = false,
};

pub fn setConfigFlags(flags: ConfigFlags) void {
    _ = flags;
}

var _width: i32 = 0;
var _height: i32 = 0;

pub fn initWindow(width_px: i32, height_px: i32, title: [:0]const u8) void {
    _ = title;
    _width = width_px;
    _height = height_px;
}

pub fn closeWindow() void {}

// ── Canonical window contract (labelle-core/src/window_contract.zig) ──────
// The uniform window surface the pluggable-backends contract standardizes on
// (labelle-assembler#386). The headless main loop never calls these (it bounds
// frames with a counter), but a conformant backend declares the canonical
// surface — `width`/`height`/`frameDuration`/`requestQuit` — so it satisfies
// `core.assertWindow`. The legacy `windowShouldClose`/`getFrameTime` names
// below are kept for the shared null-backend codegen that still references them.

/// Current framebuffer width (the value passed to `initWindow`).
pub fn width() i32 {
    return _width;
}
/// Current framebuffer height (the value passed to `initWindow`).
pub fn height() i32 {
    return _height;
}
/// Seconds elapsed for the last frame — the engine's `dt` source. Constant
/// 1/60 s for the headless backend (no real frame timing).
pub fn frameDuration() f64 {
    return 1.0 / 60.0;
}
/// Ask the window to end the run loop. No-op — the generated headless `main()`
/// ends via its frame counter, not a `shouldQuit` gate.
pub fn requestQuit() void {}

/// Always returns true so any consumer that does happen to call this on
/// the null backend exits its loop on the first iteration. The generated
/// null-backend main() doesn't use this — it caps frames with a counter.
pub fn windowShouldClose() bool {
    return true;
}

/// The null backend has no window, so it is never fullscreen. Provided for
/// parity with the real backends (sokol/raylib/bgfx/sdl/wgpu) so the engine's
/// fullscreen API links and compiles cleanly against the headless backend.
pub fn isFullscreen() bool {
    return false;
}

/// No-op: the null backend has no window to switch. Mirrors the other
/// backends' `setFullscreen` signature so the generated frame-loop drain
/// (`window.setFullscreen(on)`) resolves on the headless backend too.
pub fn setFullscreen(on: bool) void {
    _ = on;
}

pub fn setTargetFPS(fps: i32) void {
    _ = fps;
}

pub fn getFrameTime() f32 {
    return 1.0 / 60.0;
}

pub fn beginDrawing() void {}

pub fn endDrawing() void {}

pub fn clearBackground(r: u8, g: u8, b: u8, a: u8) void {
    _ = .{ r, g, b, a };
}

pub fn drawText(text: [:0]const u8, x: i32, y: i32, font_size: i32, r: u8, g: u8, b: u8, a: u8) void {
    _ = .{ text, x, y, font_size, r, g, b, a };
}

pub fn takeScreenshot(path: [:0]const u8) void {
    _ = path;
}

test "null window: lifecycle no-ops" {
    setConfigFlags(.{ .window_hidden = true });
    initWindow(320, 240, "test");
    defer closeWindow();
    setTargetFPS(60);
    try std.testing.expect(windowShouldClose());
    try std.testing.expectEqual(@as(f32, 1.0 / 60.0), getFrameTime());
}

test "null window: canonical window contract" {
    initWindow(320, 240, "test");
    try std.testing.expectEqual(@as(i32, 320), width());
    try std.testing.expectEqual(@as(i32, 240), height());
    try std.testing.expectEqual(@as(f64, 1.0 / 60.0), frameDuration());
    requestQuit(); // no-op, must compile + run
}
