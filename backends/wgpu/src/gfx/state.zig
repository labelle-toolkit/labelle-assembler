/// Screen + camera state for the WebGPU backend, plus the coordinate
/// helpers (`transformX`, `transformY`, `toNdcX`, `toNdcY`) every draw
/// primitive needs. Owns the mutable globals so the draw/font submodules
/// can stay state-free.
///
/// This is the HiDPI/Retina two-size coordinate model, ported from the
/// bgfx backend (`backends/bgfx/src/gfx/state.zig`, v0.42.0). The wgpu
/// backend previously had a single-size model (`toNdc` mapped directly
/// against `screen_w`, `setDesignSize` was a no-op), which shoved content
/// into the top-left quarter on a Retina surface once the framebuffer was
/// rendered at physical pixels. The two-size model fixes that:
///
///   - `screen_w/h`  — PHYSICAL framebuffer size (the real GPU surface).
///   - `design_w/h`  — LOGICAL canvas the game authors in (project width/
///                     height). NDC is computed against THIS, then aspect-
///                     fit into the physical framebuffer, so an 800x600
///                     game renders correctly (letterboxed) on any surface.
const types = @import("types.zig");

const Vector2 = types.Vector2;
const Camera2D = types.Camera2D;

// ── State ──────────────────────────────────────────────────────────────

// Physical framebuffer size (the real surface — desktop GLFW framebuffer).
// Set by window.zig via `setScreenSize` at init + per-frame `ensureSurface`.
var screen_w: i32 = 800;
var screen_h: i32 = 600;
// Design (logical) canvas the game authors in (project width/height). Set
// by window.zig via `setDesignSize`. NDC is computed against THIS, then
// aspect-fit into the physical framebuffer — so the game renders correctly
// (letterboxed) on any device surface, not just one that happens to equal
// the design size. Mirrors the bgfx/sokol backends' state.zig.
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

/// Convert a physical-pixel screen coordinate (a GLFW mouse event in
/// framebuffer pixels) to a design-pixel coordinate inside the
/// pillarboxed/letterboxed canvas.
///
/// Input events arrive in raw framebuffer pixels (the wgpu `input` backend
/// scales GLFW's logical cursor by the framebuffer/window ratio), but
/// game-level math (`cam.screenToWorld`, sprite positions) works in design
/// pixels. The camera's `framebufferToWorld` calls this (guarded by
/// `@hasDecl`) so clicks land correctly on HiDPI/Retina; without it the
/// camera treats framebuffer pixels as design pixels and is off by the
/// pillarbox bars + the design→physical scale. Mirrors the bgfx/sokol
/// backends.
pub fn screenToDesign(px: f32, py: f32) Vector2 {
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const dw: f32 = @floatFromInt(design_w);
    const dh: f32 = @floatFromInt(design_h);
    if (sw <= 0 or sh <= 0 or dw <= 0 or dh <= 0) {
        return .{ .x = px, .y = py };
    }
    // Exact inverse of toNdc: physical framebuffer px → NDC (full-
    // framebuffer viewport) → design. The fitted content spans NDC
    // [-fit,+fit] = fit_scale*screen_w physical pixels (NOT design_w*fit),
    // so the inverse must go through NDC, not a design-space bar. (#331:
    // the old design-space bar was wrong whenever screen != design — i.e.
    // on HiDPI/Retina — clicks drifted toward the edges.)
    const ndc_x = (px / sw) * 2.0 - 1.0;
    const ndc_y = 1.0 - (py / sh) * 2.0;
    return .{
        .x = ((ndc_x / fit_scale_x) + 1.0) * 0.5 * dw,
        .y = (1.0 - ndc_y / fit_scale_y) * 0.5 * dh,
    };
}

/// Inverse of `screenToDesign`: design-pixel → physical-pixel inside the
/// fitted canvas. Kept for parity with the bgfx/sokol backends.
pub fn designToPhysical(pos: Vector2) Vector2 {
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const dw: f32 = @floatFromInt(design_w);
    const dh: f32 = @floatFromInt(design_h);
    if (sw <= 0 or sh <= 0 or dw <= 0 or dh <= 0) {
        return pos;
    }
    // Forward of toNdc: design → NDC → physical framebuffer px. Exact
    // inverse of screenToDesign (#331).
    const ndc_x = ((pos.x / dw) * 2.0 - 1.0) * fit_scale_x;
    const ndc_y = (1.0 - (pos.y / dh) * 2.0) * fit_scale_y;
    return .{
        .x = (ndc_x + 1.0) * 0.5 * sw,
        .y = (1.0 - ndc_y) * 0.5 * sh,
    };
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

/// Convert a design-pixel X to NDC, applying the active camera transform,
/// then the aspect-fit so the design canvas letterboxes into the physical
/// surface.
pub fn toNdcX(x: f32) f32 {
    const dw: f32 = @floatFromInt(design_w);
    const raw = (transformX(x) / dw) * 2.0 - 1.0;
    return raw * fit_scale_x;
}

/// Convert a design-pixel Y to NDC (flipped for the GPU), applying the
/// active camera transform, then the aspect-fit.
pub fn toNdcY(y: f32) f32 {
    const dh: f32 = @floatFromInt(design_h);
    const raw = 1.0 - (transformY(y) / dh) * 2.0;
    return raw * fit_scale_y;
}

pub fn fitScaleX() f32 {
    return fit_scale_x;
}

pub fn fitScaleY() f32 {
    return fit_scale_y;
}

// ── Public camera control / Backend-contract utilities ───────────────

pub fn beginMode2D(camera: Camera2D) void {
    active_camera = camera;
}

pub fn endMode2D() void {
    active_camera = null;
}

// Backend contract: return the DESIGN canvas so engine/camera math stays
// resolution-independent (matches the bgfx/sokol backends). Physical size
// lives in screen_w/h and is used only for the fit scale.
pub fn getScreenWidth() i32 {
    return design_w;
}

pub fn getScreenHeight() i32 {
    return design_h;
}

/// Set the design (logical) canvas size — the resolution game code operates
/// in (project width/height). Recomputes the design→physical fit. Real
/// implementation (replaces wgpu's former no-op); window.zig calls this at
/// init with the logical window size.
pub fn setDesignSize(w: i32, h: i32) void {
    design_w = @max(1, w);
    design_h = @max(1, h);
    recomputeFitScale();
}

/// Design (logical) canvas dimensions — parity with the bgfx/sokol
/// backends' public surface.
pub fn getDesignWidth() i32 {
    return design_w;
}

pub fn getDesignHeight() i32 {
    return design_h;
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
