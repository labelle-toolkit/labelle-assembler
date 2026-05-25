/// Screen + camera state for the bgfx backend, plus the coordinate
/// helpers (`transformX`, `transformY`, `toNdcX`, `toNdcY`) every
/// draw primitive needs. Owns the mutable globals so all the other
/// submodules can stay state-free.
const types = @import("types.zig");

const Vector2 = types.Vector2;
const Camera2D = types.Camera2D;

// ── State ──────────────────────────────────────────────────────────────

var screen_w: i32 = 800;
var screen_h: i32 = 600;
var active_camera: ?Camera2D = null;

pub fn setScreenSize(w: i32, h: i32) void {
    screen_w = w;
    screen_h = h;
}

// ── Camera coordinate transform ────────────────────────────────────────

pub fn transformX(x: f32) f32 {
    if (active_camera) |cam| {
        return (x - cam.target.x) * cam.zoom + cam.offset.x;
    }
    return x;
}

pub fn transformY(y: f32) f32 {
    if (active_camera) |cam| {
        return (y - cam.target.y) * cam.zoom + cam.offset.y;
    }
    return y;
}

/// Convert screen-space pixel coordinate to NDC for the orthographic projection.
pub fn toNdcX(px: f32) f32 {
    return (px / @as(f32, @floatFromInt(screen_w))) * 2.0 - 1.0;
}

pub fn toNdcY(px: f32) f32 {
    // Flip Y: screen top=0 maps to NDC +1
    return 1.0 - (px / @as(f32, @floatFromInt(screen_h))) * 2.0;
}

// ── Camera queries (used by drawCircle / drawLine / drawTexturePro) ──

/// Returns the active camera's zoom factor, or 1.0 if no camera is
/// active. Used by the shape draw paths to scale radii and line
/// thickness with the camera so visual size matches what game code
/// expects.
pub fn cameraZoom() f32 {
    return if (active_camera) |cam| cam.zoom else @as(f32, 1.0);
}

pub fn screenWidth() i32 {
    return screen_w;
}

pub fn screenHeight() i32 {
    return screen_h;
}

// ── Public camera control / Backend-contract utilities ───────────────

pub fn beginMode2D(camera: Camera2D) void {
    active_camera = camera;
}

pub fn endMode2D() void {
    active_camera = null;
}

pub fn getScreenWidth() i32 {
    return screen_w;
}

pub fn getScreenHeight() i32 {
    return screen_h;
}

/// No-op: bgfx backend handles DPI scaling via its own screen size queries.
pub fn setDesignSize(_: i32, _: i32) void {}

pub fn screenToWorld(pos: Vector2, camera: Camera2D) Vector2 {
    return .{
        .x = (pos.x - camera.offset.x) / camera.zoom + camera.target.x,
        .y = (pos.y - camera.offset.y) / camera.zoom + camera.target.y,
    };
}

pub fn worldToScreen(pos: Vector2, camera: Camera2D) Vector2 {
    return .{
        .x = (pos.x - camera.target.x) * camera.zoom + camera.offset.x,
        .y = (pos.y - camera.target.y) * camera.zoom + camera.offset.y,
    };
}
