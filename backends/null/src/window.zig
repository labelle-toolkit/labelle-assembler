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

pub fn initWindow(width: i32, height: i32, title: [:0]const u8) void {
    _ = .{ width, height, title };
}

pub fn closeWindow() void {}

/// Always returns true so any consumer that does happen to call this on
/// the null backend exits its loop on the first iteration. The generated
/// null-backend main() doesn't use this — it caps frames with a counter.
pub fn windowShouldClose() bool {
    return true;
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
