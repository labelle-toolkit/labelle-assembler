/// Null gfx backend — satisfies the labelle-gfx Backend(Impl) contract
/// with no-op implementations. No GPU resources, no draw calls, no GL
/// context. Designed for headless lifecycle / determinism / integration
/// tests where rendering is not exercised.
///
/// Texture handles are tracked through a fresh u32 counter so that
/// upload/unload pairs round-trip correctly through the engine's image
/// asset system, but no pixel data is retained beyond the allocator-owned
/// buffer the caller passes in.
const std = @import("std");

// ── Backend types ──────────────────────────────────────────────────────

pub const Texture = struct { id: u32, width: i32, height: i32 };

pub const DecodedImage = struct {
    pixels: []u8,
    width: u32,
    height: u32,
};

pub const Color = struct { r: u8, g: u8, b: u8, a: u8 };

pub const Rectangle = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const Vector2 = struct {
    x: f32,
    y: f32,
};

pub const Camera2D = struct {
    offset: Vector2 = .{ .x = 0, .y = 0 },
    target: Vector2 = .{ .x = 0, .y = 0 },
    rotation: f32 = 0,
    zoom: f32 = 1,
};

// ── Color constants ────────────────────────────────────────────────────

pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
pub const red = Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
pub const green = Color{ .r = 0, .g = 255, .b = 0, .a = 255 };
pub const blue = Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

// ── Draw primitives (no-op) ────────────────────────────────────────────

pub fn drawTexturePro(texture: Texture, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: f32, tint: Color) void {
    _ = .{ texture, source, dest, origin, rotation, tint };
}

pub fn drawRectangleRec(rec: Rectangle, tint: Color) void {
    _ = .{ rec, tint };
}

pub fn drawCircle(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
    _ = .{ center_x, center_y, radius, tint };
}

pub fn drawRectangleLinesEx(rec: Rectangle, line_thick: f32, tint: Color) void {
    _ = .{ rec, line_thick, tint };
}

pub fn drawCircleLines(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
    _ = .{ center_x, center_y, radius, tint };
}

pub fn drawLine(start_x: f32, start_y: f32, end_x: f32, end_y: f32, thickness: f32, tint: Color) void {
    _ = .{ start_x, start_y, end_x, end_y, thickness, tint };
}

pub fn drawText(text: [:0]const u8, x: f32, y: f32, size: f32, tint: Color) void {
    _ = .{ text, x, y, size, tint };
}

pub fn color(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

// ── Texture management ─────────────────────────────────────────────────
//
// Headless backend has no GPU, but the engine's asset pipeline still
// expects unique handles round-tripping through upload/unload. A simple
// monotonic counter is enough — the null backend isn't a leak target,
// and exhausting u32 in a CI run is not a realistic failure mode.

var next_texture_id: u32 = 1;

pub fn loadTexture(path: [:0]const u8) !Texture {
    _ = path;
    const id = next_texture_id;
    next_texture_id += 1;
    return .{ .id = id, .width = 1, .height = 1 };
}

/// CPU-only "decode" — returns a single fully-transparent pixel. The
/// engine's image asset pipeline owns the buffer through its allocator,
/// so the size and format match what every other backend produces.
pub fn decodeImage(
    file_type: [:0]const u8,
    data: []const u8,
    allocator: std.mem.Allocator,
) !DecodedImage {
    _ = .{ file_type, data };
    const owned = try allocator.alloc(u8, 4);
    @memset(owned, 0);
    return .{ .pixels = owned, .width = 1, .height = 1 };
}

pub fn uploadTexture(decoded: DecodedImage) !Texture {
    const id = next_texture_id;
    next_texture_id += 1;
    return .{
        .id = id,
        .width = @intCast(decoded.width),
        .height = @intCast(decoded.height),
    };
}

pub fn unloadTexture(texture: Texture) void {
    _ = texture;
}

// ── Camera / mode (no-op) ──────────────────────────────────────────────

pub fn beginMode2D(camera: Camera2D) void {
    _ = camera;
}

pub fn endMode2D() void {}

// ── Screen size ────────────────────────────────────────────────────────
//
// The null backend has no real screen, so report the design size set by
// the generated main(). Defaults to the project's configured width/height
// if `setDesignSize` is called; otherwise zero.

var design_w: i32 = 0;
var design_h: i32 = 0;

pub fn setDesignSize(w: i32, h: i32) void {
    design_w = if (w > 0) w else 0;
    design_h = if (h > 0) h else 0;
}

pub fn getDesignWidth() i32 {
    return design_w;
}

pub fn getDesignHeight() i32 {
    return design_h;
}

pub fn getScreenWidth() i32 {
    return design_w;
}

pub fn getScreenHeight() i32 {
    return design_h;
}

pub fn screenToWorld(pos: Vector2, camera: Camera2D) Vector2 {
    _ = camera;
    return pos;
}

pub fn worldToScreen(pos: Vector2, camera: Camera2D) Vector2 {
    _ = camera;
    return pos;
}

test "null gfx: texture upload/unload round-trips" {
    var pixels = [_]u8{ 0, 0, 0, 0 };
    const decoded: DecodedImage = .{ .pixels = &pixels, .width = 1, .height = 1 };
    const tex = try uploadTexture(decoded);
    try std.testing.expect(tex.id > 0);
    try std.testing.expectEqual(@as(i32, 1), tex.width);
    unloadTexture(tex);
}

test "null gfx: design size getters" {
    setDesignSize(320, 240);
    try std.testing.expectEqual(@as(i32, 320), getDesignWidth());
    try std.testing.expectEqual(@as(i32, 240), getDesignHeight());
    try std.testing.expectEqual(@as(i32, 320), getScreenWidth());
    try std.testing.expectEqual(@as(i32, 240), getScreenHeight());
}
