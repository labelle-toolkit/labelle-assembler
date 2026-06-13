/// Screen + camera state for the bgfx backend, plus the coordinate
/// helpers (`transformX`, `transformY`, `toNdcX`, `toNdcY`) every
/// draw primitive needs. Owns the mutable globals so all the other
/// submodules can stay state-free.
const types = @import("types.zig");

const Vector2 = types.Vector2;
const Camera2D = types.Camera2D;

// ── State ──────────────────────────────────────────────────────────────

// Physical framebuffer size (the real surface — desktop window or Android
// ANativeWindow). Set per-frame by the generated main via `setScreenSize`.
var screen_w: i32 = 800;
var screen_h: i32 = 600;
// Design (logical) canvas the game authors in (project.labelle width/height).
// Set by the generated main via `setDesignSize`. NDC is computed against
// THIS, then aspect-fit into the physical framebuffer — so an 800x600 game
// renders correctly (letterboxed) on any device surface, not just one that
// happens to equal 800x600. Previously absent, which is why bgfx content
// mis-mapped on every non-800x600 surface (all Android devices). Mirrors
// the sokol backend's state.zig.
var design_w: i32 = 800;
var design_h: i32 = 600;
// Aspect-preserving design→physical fit, recomputed on any size change.
var fit_scale_x: f32 = 1.0;
var fit_scale_y: f32 = 1.0;
var active_camera: ?Camera2D = null;

fn recomputeFitScale() void {
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const dw: f32 = @floatFromInt(design_w);
    const dh: f32 = @floatFromInt(design_h);
    if (sw <= 0 or sh <= 0 or dw <= 0 or dh <= 0) {
        fit_scale_x = 1.0;
        fit_scale_y = 1.0;
        return;
    }
    const s = @min(sw / dw, sh / dh);
    fit_scale_x = s * dw / sw;
    fit_scale_y = s * dh / sh;
}

/// Physical framebuffer size (real surface). Recomputes the fit scale.
pub fn setScreenSize(w: i32, h: i32) void {
    screen_w = @max(1, w);
    screen_h = @max(1, h);
    recomputeFitScale();
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

/// Convert a (camera-transformed) design-pixel X to NDC, then apply the
/// aspect-fit so the design canvas letterboxes into the physical surface.
pub fn toNdcX(px: f32) f32 {
    const raw = (px / @as(f32, @floatFromInt(design_w))) * 2.0 - 1.0;
    return raw * fit_scale_x;
}

pub fn toNdcY(px: f32) f32 {
    // Flip Y: screen top=0 maps to NDC +1
    const raw = 1.0 - (px / @as(f32, @floatFromInt(design_h))) * 2.0;
    return raw * fit_scale_y;
}

pub fn fitScaleX() f32 {
    return fit_scale_x;
}

pub fn fitScaleY() f32 {
    return fit_scale_y;
}

// ── Camera queries (used by drawCircle / drawLine / drawTexturePro) ──

/// Returns the active camera's zoom factor, or 1.0 if no camera is
/// active. Used by the shape draw paths to scale radii and line
/// thickness with the camera so visual size matches what game code
/// expects.
pub fn cameraZoom() f32 {
    return if (active_camera) |cam| cam.zoom else @as(f32, 1.0);
}

// Design-space dimensions — the denominators toNdc maps against. drawCircle
// reads these for its per-axis NDC radius (then multiplies by fitScale*).
pub fn screenWidth() i32 {
    return design_w;
}

pub fn screenHeight() i32 {
    return design_h;
}

// ── Public camera control / Backend-contract utilities ───────────────

pub fn beginMode2D(camera: Camera2D) void {
    active_camera = camera;
}

pub fn endMode2D() void {
    active_camera = null;
}

// Backend contract: return the DESIGN canvas so engine/camera math stays
// resolution-independent (matches the sokol backend). Physical size lives
// in screen_w/h and is used only for the fit scale.
pub fn getScreenWidth() i32 {
    return design_w;
}

pub fn getScreenHeight() i32 {
    return design_h;
}

/// Set the design (logical) canvas size — the resolution game code operates
/// in (project.labelle width/height). Recomputes the design→physical fit.
pub fn setDesignSize(w: i32, h: i32) void {
    design_w = @max(1, w);
    design_h = @max(1, h);
    recomputeFitScale();
}

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
