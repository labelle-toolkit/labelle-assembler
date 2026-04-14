/// Sokol gfx backend — satisfies the labelle-gfx Backend(Impl) contract.
/// Uses sokol_gl for immediate-mode 2D drawing with real texture support.
const std = @import("std");
const sokol = @import("sokol");
const sgl = sokol.gl;
const sg = sokol.gfx;

// ── Backend types ──────────────────────────────────────────────────────

pub const Texture = struct {
    id: u32 = 0,
    img: sg.Image = .{},
    view: sg.View = .{},
    smp: sg.Sampler = .{},
    width: i32 = 0,
    height: i32 = 0,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

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

pub fn color(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

// ── Screen dimensions (set by the app's frame callback) ─────────────

var screen_w: i32 = 800;
var screen_h: i32 = 600;
var design_w: i32 = 800;
var design_h: i32 = 600;

// Aspect-preserving fit scale from design → physical, recomputed on any
// dimension change instead of per-vertex. Used by toNdcX/toNdcY and
// drawCircle to letterbox/pillarbox the design canvas inside the window.
var fit_scale_x: f32 = 1.0;
var fit_scale_y: f32 = 1.0;

// When false, toNdcX/toNdcY skip the fit_scale multiplication and the
// design canvas stretches to fill the entire physical framebuffer. The
// renderer toggles this around `screen_fill` layers so backdrops can
// cover the pillarbox bars while game content stays correctly fitted.
var fit_active: bool = true;

pub fn setApplyFit(active: bool) void {
    fit_active = active;
}

/// Convert a physical-pixel screen coordinate (e.g. a sokol_app touch
/// or mouse event in framebuffer pixels) to a design-pixel coordinate
/// inside the pillarboxed/letterboxed canvas.
///
/// Touch / mouse events arrive in raw framebuffer pixels, but
/// game-level math (`cam.screenToWorld`, sprite positions, etc.) all
/// works in design pixels. Without this conversion, a pinch midpoint
/// computed from two touches would be off by the pillarbox bar width
/// and a global zoom factor.
pub fn screenToDesign(px: f32, py: f32) struct { x: f32, y: f32 } {
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const dw: f32 = @floatFromInt(design_w);
    const dh: f32 = @floatFromInt(design_h);
    if (sw <= 0 or sh <= 0 or dw <= 0 or dh <= 0) {
        return .{ .x = px, .y = py };
    }
    // The design canvas is centered inside the physical framebuffer,
    // scaled by fit_scale_x/y in each axis. Inverse the mapping:
    // 1) subtract the bar offset, 2) divide by the fitted size,
    // 3) multiply by the design size.
    const fitted_w = sw * fit_scale_x;
    const fitted_h = sh * fit_scale_y;
    const bar_x = (sw - fitted_w) * 0.5;
    const bar_y = (sh - fitted_h) * 0.5;
    return .{
        .x = (px - bar_x) * dw / fitted_w,
        .y = (py - bar_y) * dh / fitted_h,
    };
}

/// Recompute the cached fit scale from screen_w/h and design_w/h.
/// Call after any change to those values.
fn recomputeFitScale() void {
    const dw: f32 = @floatFromInt(design_w);
    const dh: f32 = @floatFromInt(design_h);
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    if (sw <= 0 or sh <= 0 or dw <= 0 or dh <= 0) {
        fit_scale_x = 1;
        fit_scale_y = 1;
        return;
    }
    const design_aspect = dw / dh;
    const physical_aspect = sw / sh;
    if (physical_aspect > design_aspect) {
        // Wider than design → pillarbox (shrink X).
        fit_scale_x = design_aspect / physical_aspect;
        fit_scale_y = 1;
    } else {
        // Taller than design → letterbox (shrink Y).
        fit_scale_x = 1;
        fit_scale_y = physical_aspect / design_aspect;
    }
}

pub fn setScreenSize(w: i32, h: i32) void {
    screen_w = if (w > 0) w else 1;
    screen_h = if (h > 0) h else 1;
    // Keep design dims in sync with physical by default (backwards compat for
    // desktop where design == physical). Call setDesignSize after to override.
    design_w = screen_w;
    design_h = screen_h;
    recomputeFitScale();
}

/// Override design canvas dimensions for NDC mapping in screen-space mode.
/// Call after setScreenSize when design resolution differs from physical
/// (e.g. high_dpi=true on mobile where framebuffer is 2× the design size).
pub fn setDesignSize(w: i32, h: i32) void {
    design_w = if (w > 0) w else 1;
    design_h = if (h > 0) h else 1;
    recomputeFitScale();
}

// ── Camera state ────────────────────────────────────────────────────

var active_camera: Camera2D = .{};
var camera_active: bool = false;

// ── Coordinate helpers ──────────────────────────────────────────────

/// Convert screen-space pixel coordinates to NDC (-1..1) for sokol_gl.
/// Always maps against the design canvas (design_w/design_h), then applies
/// the cached aspect-preserving fit scale so the same game coordinates
/// produce correct, non-stretched NDC regardless of the physical
/// framebuffer size.
///
/// The camera's offset is produced by labelle-gfx's camera.toBackend() as
/// `{ getScreenWidth()/2, getScreenHeight()/2 }`; since getScreenWidth/Height
/// return the design dimensions, `cam.offset` is also in design pixels and
/// the division cancels correctly.
///
/// design_w/h are clamped ≥ 1 by setScreenSize/setDesignSize, so the
/// divisions below are guaranteed safe.
fn toNdcX(px: f32) f32 {
    const dw: f32 = @floatFromInt(design_w);
    const raw = if (!camera_active)
        (px / dw) * 2.0 - 1.0
    else blk: {
        const cam = active_camera;
        const screen_x = (px - cam.target.x) * cam.zoom + cam.offset.x;
        break :blk (screen_x / dw) * 2.0 - 1.0;
    };
    return if (fit_active) raw * fit_scale_x else raw;
}

fn toNdcY(py: f32) f32 {
    const dh: f32 = @floatFromInt(design_h);
    const raw = if (!camera_active)
        1.0 - (py / dh) * 2.0
    else blk: {
        const cam = active_camera;
        // Positions arrive in screen-space Y-down (Y-flipped by renderer.toScreenY).
        const screen_y = (py - cam.target.y) * cam.zoom + cam.offset.y;
        break :blk 1.0 - (screen_y / dh) * 2.0;
    };
    return if (fit_active) raw * fit_scale_y else raw;
}

// ── Draw primitives (Backend contract) ─────────────────────────────────

pub fn drawTexturePro(texture: Texture, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: f32, tint: Color) void {
    // Guard against division by zero
    if (texture.width == 0 or texture.height == 0) return;

    // Calculate UV coordinates from the source rectangle.
    //
    // Negative source.width / source.height are the labelle-gfx convention
    // for "flip horizontally / vertically" — the renderer negates the rect
    // dimensions when sprite.flip_x or sprite.flip_y is set. The atlas
    // region itself always lives at [source.x, source.x + |source.width|]
    // and [source.y, source.y + |source.height|], so we compute the UV
    // bounds from the absolute extents and then SWAP u0/u1 (or v0/v1) on
    // the flip path.
    //
    // The previous implementation used `(source.x + source.width)` directly,
    // which on a flip moved the sampling LEFT of source.x and read pixels
    // from a neighboring atlas region. On a packed atlas with hundreds of
    // sprites, that neighbor was usually some other character's frame —
    // hence the "characters wearing each other's animations" symptom in
    // flying-platform-labelle when workers turned around.
    const tex_width: f32 = @floatFromInt(texture.width);
    const tex_height: f32 = @floatFromInt(texture.height);

    const sw_abs = @abs(source.width);
    const sh_abs = @abs(source.height);
    const flip_x = source.width < 0;
    const flip_y = source.height < 0;

    const u_left = source.x / tex_width;
    const u_right = (source.x + sw_abs) / tex_width;
    const v_top = source.y / tex_height;
    const v_bottom = (source.y + sh_abs) / tex_height;

    const uv0 = if (flip_x) u_right else u_left;
    const uv1 = if (flip_x) u_left else u_right;
    const tv0 = if (flip_y) v_bottom else v_top;
    const tv1 = if (flip_y) v_top else v_bottom;

    // Tint as floats (0.0 - 1.0)
    const r: f32 = @as(f32, @floatFromInt(tint.r)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt(tint.g)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(tint.b)) / 255.0;
    const a: f32 = @as(f32, @floatFromInt(tint.a)) / 255.0;

    // Enable texturing and bind the image + sampler directly
    sgl.enableTexture();
    sgl.texture(texture.view, texture.smp);

    if (rotation != 0) {
        // Rotation path: translate to dest origin, rotate, draw at local coords
        const dx = dest.x;
        const dy = dest.y;
        const dw = dest.width;
        const dh = dest.height;

        // Convert to NDC for the pivot point
        const pivot_ndc_x = toNdcX(dx);
        const pivot_ndc_y = toNdcY(dy);
        // Calculate NDC scale factors using toNdcX/toNdcY difference so camera zoom applies consistently
        const ndc_w = toNdcX(dx + dw) - toNdcX(dx);
        const ndc_h = toNdcY(dy) - toNdcY(dy + dh); // positive height in NDC (Y flipped)
        const ndc_ox = toNdcX(dx + origin.x) - toNdcX(dx);
        const ndc_oy = toNdcY(dy) - toNdcY(dy + origin.y);

        sgl.pushMatrix();
        sgl.translate(pivot_ndc_x, pivot_ndc_y, 0);
        sgl.rotate(rotation * std.math.pi / 180.0, 0, 0, 1);
        sgl.translate(-ndc_ox, ndc_oy, 0); // Y flipped in NDC

        sgl.beginQuads();
        sgl.v2fT2fC4f(0, 0, uv0, tv0, r, g, b, a);
        sgl.v2fT2fC4f(ndc_w, 0, uv1, tv0, r, g, b, a);
        sgl.v2fT2fC4f(ndc_w, -ndc_h, uv1, tv1, r, g, b, a);
        sgl.v2fT2fC4f(0, -ndc_h, uv0, tv1, r, g, b, a);
        sgl.end();

        sgl.popMatrix();
    } else {
        // Fast path: no rotation, draw directly in NDC
        const dx = dest.x - origin.x;
        const dy = dest.y - origin.y;

        const x0 = toNdcX(dx);
        const y0 = toNdcY(dy);
        const x1 = toNdcX(dx + dest.width);
        const y1 = toNdcY(dy + dest.height);

        sgl.beginQuads();
        sgl.v2fT2fC4f(x0, y0, uv0, tv0, r, g, b, a);
        sgl.v2fT2fC4f(x1, y0, uv1, tv0, r, g, b, a);
        sgl.v2fT2fC4f(x1, y1, uv1, tv1, r, g, b, a);
        sgl.v2fT2fC4f(x0, y1, uv0, tv1, r, g, b, a);
        sgl.end();
    }

    sgl.disableTexture();
}

pub fn drawRectangleRec(rec: Rectangle, tint: Color) void {
    const x0 = toNdcX(rec.x);
    const y0 = toNdcY(rec.y);
    const x1 = toNdcX(rec.x + rec.width);
    const y1 = toNdcY(rec.y + rec.height);

    sgl.beginQuads();
    sgl.c4b(tint.r, tint.g, tint.b, tint.a);
    sgl.v2f(x0, y0);
    sgl.v2f(x1, y0);
    sgl.v2f(x1, y1);
    sgl.v2f(x0, y1);
    sgl.end();
}

/// Draw a rectangle outline. `line_thick` is accepted for API compatibility
/// with raylib's drawRectangleLinesEx but is ignored — sgl LINES always
/// render 1 pixel thick. For thicker outlines, the caller can compose four
/// drawRectangleRec bars instead.
pub fn drawRectangleLinesEx(rec: Rectangle, line_thick: f32, tint: Color) void {
    _ = line_thick;
    const x0 = toNdcX(rec.x);
    const y0 = toNdcY(rec.y);
    const x1 = toNdcX(rec.x + rec.width);
    const y1 = toNdcY(rec.y + rec.height);

    sgl.beginLineStrip();
    sgl.c4b(tint.r, tint.g, tint.b, tint.a);
    sgl.v2f(x0, y0);
    sgl.v2f(x1, y0);
    sgl.v2f(x1, y1);
    sgl.v2f(x0, y1);
    sgl.v2f(x0, y0);
    sgl.end();
}

pub fn drawCircle(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
    const segments = 32;
    const cx = toNdcX(center_x);
    const cy = toNdcY(center_y);
    // Convert radius to NDC scale using design dims so it matches toNdcX/Y.
    // In camera mode, scale by zoom so the circle grows/shrinks with the camera.
    // Apply the same cached aspect-preserving fit as toNdcX/Y so the circle
    // stays round under letterbox/pillarbox.
    const rw: f32 = @floatFromInt(design_w);
    const rh: f32 = @floatFromInt(design_h);
    const zoom: f32 = if (camera_active) active_camera.zoom else 1.0;
    const fx: f32 = if (fit_active) fit_scale_x else 1.0;
    const fy: f32 = if (fit_active) fit_scale_y else 1.0;
    const rx = (radius * zoom / rw) * 2.0 * fx;
    const ry = (radius * zoom / rh) * 2.0 * fy;

    sgl.beginTriangleStrip();
    sgl.c4b(tint.r, tint.g, tint.b, tint.a);
    for (0..segments + 1) |i| {
        const angle = @as(f32, @floatFromInt(i)) * (2.0 * 3.14159265) / @as(f32, @floatFromInt(segments));
        const next_angle = @as(f32, @floatFromInt(i + 1)) * (2.0 * 3.14159265) / @as(f32, @floatFromInt(segments));
        sgl.v2f(cx, cy);
        sgl.v2f(cx + @cos(angle) * rx, cy + @sin(angle) * ry);
        sgl.v2f(cx + @cos(next_angle) * rx, cy + @sin(next_angle) * ry);
    }
    sgl.end();
}

pub fn drawLine(start_x: f32, start_y: f32, end_x: f32, end_y: f32, _: f32, tint: Color) void {
    sgl.beginLines();
    sgl.c4b(tint.r, tint.g, tint.b, tint.a);
    sgl.v2f(toNdcX(start_x), toNdcY(start_y));
    sgl.v2f(toNdcX(end_x), toNdcY(end_y));
    sgl.end();
}

/// Draw text using an embedded bitmap font atlas.
/// Renders printable ASCII characters (32..126) as textured quads via sokol_gl.
/// The font is a simple 8x8 pixel monospaced bitmap font.
pub fn drawText(text: [:0]const u8, x: f32, y: f32, size: f32, tint: Color) void {
    if (text.len == 0) return;

    // Lazily initialize the font atlas on first use
    if (!font_initialized) {
        initFontAtlas();
        font_initialized = true;
    }

    // If font failed to initialize, skip rendering
    if (font_image.id == 0) return;

    const r: f32 = @as(f32, @floatFromInt(tint.r)) / 255.0;
    const g: f32 = @as(f32, @floatFromInt(tint.g)) / 255.0;
    const b: f32 = @as(f32, @floatFromInt(tint.b)) / 255.0;
    const a: f32 = @as(f32, @floatFromInt(tint.a)) / 255.0;

    // Scale factor: default font is 8px, scale to requested size
    const scale = size / 8.0;
    const char_w = 8.0 * scale;
    const char_h = 8.0 * scale;

    sgl.enableTexture();
    sgl.texture(font_view, font_sampler);

    sgl.beginQuads();

    var cursor_x = x;
    for (text) |ch| {
        if (ch == 0) break;
        // Only render printable ASCII (32..126)
        if (ch >= 32 and ch <= 126) {
            const glyph_index: u32 = @as(u32, ch) - 32;
            // Atlas is 16 columns x 6 rows of 8x8 glyphs in a 128x48 texture
            const col: f32 = @floatFromInt(glyph_index % 16);
            const row: f32 = @floatFromInt(glyph_index / 16);

            const uv0 =col * 8.0 / 128.0;
            const tv0 =row * 8.0 / 48.0;
            const uv1 =(col + 1.0) * 8.0 / 128.0;
            const tv1 =(row + 1.0) * 8.0 / 48.0;

            const x0 = toNdcX(cursor_x);
            const y0 = toNdcY(y);
            const x1 = toNdcX(cursor_x + char_w);
            const y1 = toNdcY(y + char_h);

            sgl.v2fT2fC4f(x0, y0, uv0, tv0, r, g, b, a);
            sgl.v2fT2fC4f(x1, y0, uv1, tv0, r, g, b, a);
            sgl.v2fT2fC4f(x1, y1, uv1, tv1, r, g, b, a);
            sgl.v2fT2fC4f(x0, y1, uv0, tv1, r, g, b, a);
        }
        cursor_x += char_w;
    }

    sgl.end();
    sgl.disableTexture();
}

const stbi = @cImport({
    @cInclude("stb_image.h");
});

pub fn loadTexture(path: [:0]const u8) !Texture {
    // Read the file from disk, then decode from memory
    const file = std.fs.cwd().openFileZ(path, .{}) catch return error.LoadFailed;
    defer file.close();

    const stat = file.stat() catch return error.LoadFailed;
    const file_size = stat.size;
    if (file_size == 0 or file_size > 256 * 1024 * 1024) return error.LoadFailed;

    const data = file.readToEndAlloc(std.heap.page_allocator, @intCast(file_size)) catch return error.LoadFailed;
    defer std.heap.page_allocator.free(data);

    return loadTextureFromMemoryData(data);
}

pub fn loadTextureFromMemory(_: [:0]const u8, data: []const u8) !Texture {
    return loadTextureFromMemoryData(data);
}

fn loadTextureFromMemoryData(data: []const u8) !Texture {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const pixels = stbi.stbi_load_from_memory(
        @ptrCast(data.ptr),
        @intCast(data.len),
        &width,
        &height,
        &channels,
        4, // force RGBA
    );
    if (pixels == null) return error.LoadFailed;
    defer stbi.stbi_image_free(pixels);

    const size: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    const pixel_data: []const u8 = @as([*]const u8, @ptrCast(pixels))[0..size];
    return createTextureFromRgba(pixel_data, width, height);
}

pub fn unloadTexture(texture: Texture) void {
    if (texture.view.id != 0) {
        sg.destroyView(texture.view);
    }
    if (texture.img.id != 0) {
        sg.destroyImage(texture.img);
    }
    if (texture.smp.id != 0) {
        sg.destroySampler(texture.smp);
    }
}

pub fn beginMode2D(camera: Camera2D) void {
    active_camera = camera;
    camera_active = true;
}

pub fn endMode2D() void {
    camera_active = false;
}

pub fn getScreenWidth() i32 {
    // Return the design canvas width so camera offset / viewport math works
    // in design pixels (resolution-independent). Physical framebuffer size is
    // tracked separately in screen_w/screen_h but isn't exposed here.
    return design_w;
}

pub fn getScreenHeight() i32 {
    return design_h;
}

pub fn screenToWorld(pos: Vector2, camera: Camera2D) Vector2 {
    return .{
        .x = (pos.x - camera.offset.x) / camera.zoom + camera.target.x,
        // Screen Y-down convention, same as raylib backend
        .y = (pos.y - camera.offset.y) / camera.zoom + camera.target.y,
    };
}

pub fn worldToScreen(pos: Vector2, camera: Camera2D) Vector2 {
    return .{
        .x = (pos.x - camera.target.x) * camera.zoom + camera.offset.x,
        // Screen Y-down convention, same as raylib backend
        .y = (pos.y - camera.target.y) * camera.zoom + camera.offset.y,
    };
}

// ── Texture creation helper ─────────────────────────────────────────────

fn createTextureFromRgba(pixels: []const u8, width: i32, height: i32) !Texture {
    var img_desc: sg.ImageDesc = .{
        .width = width,
        .height = height,
        .pixel_format = .RGBA8,
    };
    img_desc.data.mip_levels[0] = .{
        .ptr = pixels.ptr,
        .size = pixels.len,
    };

    const img = sg.makeImage(img_desc);
    if (img.id == 0) return error.LoadFailed;

    const smp = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });

    if (smp.id == 0) {
        sg.destroyImage(img);
        return error.LoadFailed;
    }

    const view = sg.makeView(.{ .texture = .{ .image = img } });
    if (view.id == 0) {
        sg.destroySampler(smp);
        sg.destroyImage(img);
        return error.LoadFailed;
    }

    return Texture{
        .id = img.id,
        .img = img,
        .view = view,
        .smp = smp,
        .width = width,
        .height = height,
    };
}

// TGA and BMP loaders removed — stb_image handles PNG (compiled with STBI_ONLY_PNG).

// ── Embedded bitmap font atlas ──────────────────────────────────────────

// 8x8 pixel monospaced bitmap font covering ASCII 32..126 (95 glyphs).
// Laid out in a 128x48 pixel atlas (16 columns x 6 rows).
// Each glyph is stored as 8 bytes (one byte per row, MSB = leftmost pixel).

var font_initialized: bool = false;
var font_image: sg.Image = .{ .id = 0 };
var font_view: sg.View = .{ .id = 0 };
var font_sampler: sg.Sampler = .{ .id = 0 };

// Compact 8x8 bitmap font data: 95 printable ASCII chars (space through tilde).
// Each glyph is 8 bytes; each byte is one row, MSB-first.
const font_glyphs: [95][8]u8 = .{
    // 32: space
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 33: !
    .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00 },
    // 34: "
    .{ 0x6C, 0x6C, 0x6C, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 35: #
    .{ 0x6C, 0x6C, 0xFE, 0x6C, 0xFE, 0x6C, 0x6C, 0x00 },
    // 36: $
    .{ 0x18, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x18, 0x00 },
    // 37: %
    .{ 0x00, 0xC6, 0xCC, 0x18, 0x30, 0x66, 0xC6, 0x00 },
    // 38: &
    .{ 0x38, 0x6C, 0x38, 0x76, 0xDC, 0xCC, 0x76, 0x00 },
    // 39: '
    .{ 0x18, 0x18, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 40: (
    .{ 0x0C, 0x18, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00 },
    // 41: )
    .{ 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00 },
    // 42: *
    .{ 0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00 },
    // 43: +
    .{ 0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00 },
    // 44: ,
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30 },
    // 45: -
    .{ 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00 },
    // 46: .
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00 },
    // 47: /
    .{ 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0x80, 0x00 },
    // 48: 0
    .{ 0x7C, 0xC6, 0xCE, 0xDE, 0xF6, 0xE6, 0x7C, 0x00 },
    // 49: 1
    .{ 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00 },
    // 50: 2
    .{ 0x7C, 0xC6, 0x06, 0x1C, 0x30, 0x66, 0xFE, 0x00 },
    // 51: 3
    .{ 0x7C, 0xC6, 0x06, 0x3C, 0x06, 0xC6, 0x7C, 0x00 },
    // 52: 4
    .{ 0x1C, 0x3C, 0x6C, 0xCC, 0xFE, 0x0C, 0x1E, 0x00 },
    // 53: 5
    .{ 0xFE, 0xC0, 0xFC, 0x06, 0x06, 0xC6, 0x7C, 0x00 },
    // 54: 6
    .{ 0x38, 0x60, 0xC0, 0xFC, 0xC6, 0xC6, 0x7C, 0x00 },
    // 55: 7
    .{ 0xFE, 0xC6, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00 },
    // 56: 8
    .{ 0x7C, 0xC6, 0xC6, 0x7C, 0xC6, 0xC6, 0x7C, 0x00 },
    // 57: 9
    .{ 0x7C, 0xC6, 0xC6, 0x7E, 0x06, 0x0C, 0x78, 0x00 },
    // 58: :
    .{ 0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x00 },
    // 59: ;
    .{ 0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x30 },
    // 60: <
    .{ 0x06, 0x0C, 0x18, 0x30, 0x18, 0x0C, 0x06, 0x00 },
    // 61: =
    .{ 0x00, 0x00, 0x7E, 0x00, 0x00, 0x7E, 0x00, 0x00 },
    // 62: >
    .{ 0x60, 0x30, 0x18, 0x0C, 0x18, 0x30, 0x60, 0x00 },
    // 63: ?
    .{ 0x7C, 0xC6, 0x0C, 0x18, 0x18, 0x00, 0x18, 0x00 },
    // 64: @
    .{ 0x7C, 0xC6, 0xDE, 0xDE, 0xDE, 0xC0, 0x78, 0x00 },
    // 65: A
    .{ 0x38, 0x6C, 0xC6, 0xFE, 0xC6, 0xC6, 0xC6, 0x00 },
    // 66: B
    .{ 0xFC, 0x66, 0x66, 0x7C, 0x66, 0x66, 0xFC, 0x00 },
    // 67: C
    .{ 0x3C, 0x66, 0xC0, 0xC0, 0xC0, 0x66, 0x3C, 0x00 },
    // 68: D
    .{ 0xF8, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0xF8, 0x00 },
    // 69: E
    .{ 0xFE, 0x62, 0x68, 0x78, 0x68, 0x62, 0xFE, 0x00 },
    // 70: F
    .{ 0xFE, 0x62, 0x68, 0x78, 0x68, 0x60, 0xF0, 0x00 },
    // 71: G
    .{ 0x3C, 0x66, 0xC0, 0xC0, 0xCE, 0x66, 0x3A, 0x00 },
    // 72: H
    .{ 0xC6, 0xC6, 0xC6, 0xFE, 0xC6, 0xC6, 0xC6, 0x00 },
    // 73: I
    .{ 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 },
    // 74: J
    .{ 0x1E, 0x0C, 0x0C, 0x0C, 0xCC, 0xCC, 0x78, 0x00 },
    // 75: K
    .{ 0xE6, 0x66, 0x6C, 0x78, 0x6C, 0x66, 0xE6, 0x00 },
    // 76: L
    .{ 0xF0, 0x60, 0x60, 0x60, 0x62, 0x66, 0xFE, 0x00 },
    // 77: M
    .{ 0xC6, 0xEE, 0xFE, 0xFE, 0xD6, 0xC6, 0xC6, 0x00 },
    // 78: N
    .{ 0xC6, 0xE6, 0xF6, 0xDE, 0xCE, 0xC6, 0xC6, 0x00 },
    // 79: O
    .{ 0x7C, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00 },
    // 80: P
    .{ 0xFC, 0x66, 0x66, 0x7C, 0x60, 0x60, 0xF0, 0x00 },
    // 81: Q
    .{ 0x7C, 0xC6, 0xC6, 0xC6, 0xD6, 0xDE, 0x7C, 0x06 },
    // 82: R
    .{ 0xFC, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0xE6, 0x00 },
    // 83: S
    .{ 0x7C, 0xC6, 0x60, 0x38, 0x0C, 0xC6, 0x7C, 0x00 },
    // 84: T
    .{ 0x7E, 0x7E, 0x5A, 0x18, 0x18, 0x18, 0x3C, 0x00 },
    // 85: U
    .{ 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00 },
    // 86: V
    .{ 0xC6, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x10, 0x00 },
    // 87: W
    .{ 0xC6, 0xC6, 0xD6, 0xFE, 0xFE, 0xEE, 0xC6, 0x00 },
    // 88: X
    .{ 0xC6, 0xC6, 0x6C, 0x38, 0x6C, 0xC6, 0xC6, 0x00 },
    // 89: Y
    .{ 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x3C, 0x00 },
    // 90: Z
    .{ 0xFE, 0xC6, 0x8C, 0x18, 0x32, 0x66, 0xFE, 0x00 },
    // 91: [
    .{ 0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00 },
    // 92: backslash
    .{ 0xC0, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x02, 0x00 },
    // 93: ]
    .{ 0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00 },
    // 94: ^
    .{ 0x10, 0x38, 0x6C, 0xC6, 0x00, 0x00, 0x00, 0x00 },
    // 95: _
    .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF },
    // 96: `
    .{ 0x30, 0x18, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00 },
    // 97: a
    .{ 0x00, 0x00, 0x78, 0x0C, 0x7C, 0xCC, 0x76, 0x00 },
    // 98: b
    .{ 0xE0, 0x60, 0x7C, 0x66, 0x66, 0x66, 0xDC, 0x00 },
    // 99: c
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC0, 0xC6, 0x7C, 0x00 },
    // 100: d
    .{ 0x1C, 0x0C, 0x7C, 0xCC, 0xCC, 0xCC, 0x76, 0x00 },
    // 101: e
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xFE, 0xC0, 0x7C, 0x00 },
    // 102: f
    .{ 0x38, 0x6C, 0x60, 0xF8, 0x60, 0x60, 0xF0, 0x00 },
    // 103: g
    .{ 0x00, 0x00, 0x76, 0xCC, 0xCC, 0x7C, 0x0C, 0xF8 },
    // 104: h
    .{ 0xE0, 0x60, 0x6C, 0x76, 0x66, 0x66, 0xE6, 0x00 },
    // 105: i
    .{ 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00 },
    // 106: j
    .{ 0x06, 0x00, 0x06, 0x06, 0x06, 0x66, 0x66, 0x3C },
    // 107: k
    .{ 0xE0, 0x60, 0x66, 0x6C, 0x78, 0x6C, 0xE6, 0x00 },
    // 108: l
    .{ 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 },
    // 109: m
    .{ 0x00, 0x00, 0xEC, 0xFE, 0xD6, 0xD6, 0xD6, 0x00 },
    // 110: n
    .{ 0x00, 0x00, 0xDC, 0x66, 0x66, 0x66, 0x66, 0x00 },
    // 111: o
    .{ 0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0x7C, 0x00 },
    // 112: p
    .{ 0x00, 0x00, 0xDC, 0x66, 0x66, 0x7C, 0x60, 0xF0 },
    // 113: q
    .{ 0x00, 0x00, 0x76, 0xCC, 0xCC, 0x7C, 0x0C, 0x1E },
    // 114: r
    .{ 0x00, 0x00, 0xDC, 0x76, 0x60, 0x60, 0xF0, 0x00 },
    // 115: s
    .{ 0x00, 0x00, 0x7E, 0xC0, 0x7C, 0x06, 0xFC, 0x00 },
    // 116: t
    .{ 0x30, 0x30, 0x7C, 0x30, 0x30, 0x36, 0x1C, 0x00 },
    // 117: u
    .{ 0x00, 0x00, 0xCC, 0xCC, 0xCC, 0xCC, 0x76, 0x00 },
    // 118: v
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x00 },
    // 119: w
    .{ 0x00, 0x00, 0xC6, 0xD6, 0xD6, 0xFE, 0x6C, 0x00 },
    // 120: x
    .{ 0x00, 0x00, 0xC6, 0x6C, 0x38, 0x6C, 0xC6, 0x00 },
    // 121: y
    .{ 0x00, 0x00, 0xC6, 0xC6, 0xC6, 0x7E, 0x06, 0xFC },
    // 122: z
    .{ 0x00, 0x00, 0xFE, 0x8C, 0x18, 0x32, 0xFE, 0x00 },
    // 123: {
    .{ 0x0E, 0x18, 0x18, 0x70, 0x18, 0x18, 0x0E, 0x00 },
    // 124: |
    .{ 0x18, 0x18, 0x18, 0x00, 0x18, 0x18, 0x18, 0x00 },
    // 125: }
    .{ 0x70, 0x18, 0x18, 0x0E, 0x18, 0x18, 0x70, 0x00 },
    // 126: ~
    .{ 0x76, 0xDC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
};

fn initFontAtlas() void {
    // Build a 128x48 RGBA atlas (16 cols x 6 rows of 8x8 glyphs)
    const atlas_w = 128;
    const atlas_h = 48;
    var pixels: [atlas_w * atlas_h * 4]u8 = undefined;
    @memset(&pixels, 0);

    for (0..95) |glyph_idx| {
        const col = glyph_idx % 16;
        const row = glyph_idx / 16;
        const glyph = font_glyphs[glyph_idx];

        for (0..8) |py| {
            const byte = glyph[py];
            for (0..8) |px| {
                const bit: u8 = @intCast((@as(u16, byte) >> @intCast(7 - px)) & 1);
                const ax = col * 8 + px;
                const ay = row * 8 + py;
                const idx = (ay * atlas_w + ax) * 4;
                pixels[idx + 0] = 255 * bit; // R
                pixels[idx + 1] = 255 * bit; // G
                pixels[idx + 2] = 255 * bit; // B
                pixels[idx + 3] = 255 * bit; // A
            }
        }
    }

    var img_desc: sg.ImageDesc = .{
        .width = atlas_w,
        .height = atlas_h,
        .pixel_format = .RGBA8,
    };
    img_desc.data.mip_levels[0] = .{
        .ptr = &pixels,
        .size = pixels.len,
    };

    font_image = sg.makeImage(img_desc);
    if (font_image.id == 0) return;

    font_view = sg.makeView(.{ .texture = .{ .image = font_image } });
    if (font_view.id == 0) {
        sg.destroyImage(font_image);
        font_image = .{ .id = 0 };
        return;
    }

    font_sampler = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });

    if (font_sampler.id == 0) {
        sg.destroyImage(font_image);
        font_image = .{ .id = 0 };
        return;
    }
}
