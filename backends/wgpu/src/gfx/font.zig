/// Embedded 8x8 bitmap font + glyph-atlas text rendering for the WebGPU
/// backend. Text renders through the textured-sprite path: the font is
/// baked ONCE into an RGBA8 atlas texture (via `texture.uploadTexture`),
/// and each printable glyph is drawn as a single sampled sprite quad
/// appended to the shared sprite batch in `batch.zig`. Positions map to
/// NDC via `state.toNdcX/toNdcY` (camera + HiDPI aspect-fit aware).
const std = @import("std");

const log = std.log.scoped(.wgpu_gfx);

const types = @import("types.zig");
const state = @import("state.zig");
const batch = @import("batch.zig");
const texture = @import("texture.zig");

const Color = types.Color;
const SpriteVertex = types.SpriteVertex;

const toNdcX = state.toNdcX;
const toNdcY = state.toNdcY;

// ── Text rendering (bitmap font atlas) ─────────────────────────────────

/// Minimal 8x8 bitmap font for basic text rendering.
/// Each character is an 8x8 monospaced glyph stored as 8 bytes (1 bit per pixel, MSB-left).
/// Printable ASCII range: 0x20 (' ') through 0x7E ('~').
const FONT_GLYPH_W = 8;
const FONT_GLYPH_H = 8;

// Embedded 8x8 font data for printable ASCII (space through '~', 95 glyphs).
// Each glyph is 8 rows of 8 bits packed into u8.
const font_data = initFontData();

fn initFontData() [95][8]u8 {
    // Minimal embedded bitmap font (subset — uppercase letters, digits, punctuation).
    // Unset glyphs render as hollow rectangles.
    var data: [95][8]u8 = [_][8]u8{.{ 0, 0, 0, 0, 0, 0, 0, 0 }} ** 95;

    // Space (0x20) — blank
    // '!' (0x21)
    data[0x21 - 0x20] = .{ 0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00 };
    // '0' - '9'
    data[0x30 - 0x20] = .{ 0x3C, 0x66, 0x6E, 0x7E, 0x76, 0x66, 0x3C, 0x00 }; // 0
    data[0x31 - 0x20] = .{ 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00 }; // 1
    data[0x32 - 0x20] = .{ 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x30, 0x7E, 0x00 }; // 2
    data[0x33 - 0x20] = .{ 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00 }; // 3
    data[0x34 - 0x20] = .{ 0x0C, 0x1C, 0x3C, 0x6C, 0x7E, 0x0C, 0x0C, 0x00 }; // 4
    data[0x35 - 0x20] = .{ 0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00 }; // 5
    data[0x36 - 0x20] = .{ 0x1C, 0x30, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00 }; // 6
    data[0x37 - 0x20] = .{ 0x7E, 0x06, 0x0C, 0x18, 0x18, 0x18, 0x18, 0x00 }; // 7
    data[0x38 - 0x20] = .{ 0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00 }; // 8
    data[0x39 - 0x20] = .{ 0x3C, 0x66, 0x66, 0x3E, 0x06, 0x0C, 0x38, 0x00 }; // 9
    // A-Z
    data[0x41 - 0x20] = .{ 0x18, 0x3C, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x00 }; // A
    data[0x42 - 0x20] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00 }; // B
    data[0x43 - 0x20] = .{ 0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00 }; // C
    data[0x44 - 0x20] = .{ 0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00 }; // D
    data[0x45 - 0x20] = .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00 }; // E
    data[0x46 - 0x20] = .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x00 }; // F
    data[0x47 - 0x20] = .{ 0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3E, 0x00 }; // G
    data[0x48 - 0x20] = .{ 0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00 }; // H
    data[0x49 - 0x20] = .{ 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 }; // I
    data[0x4A - 0x20] = .{ 0x06, 0x06, 0x06, 0x06, 0x06, 0x66, 0x3C, 0x00 }; // J
    data[0x4B - 0x20] = .{ 0x66, 0x6C, 0x78, 0x70, 0x78, 0x6C, 0x66, 0x00 }; // K
    data[0x4C - 0x20] = .{ 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00 }; // L
    data[0x4D - 0x20] = .{ 0x63, 0x77, 0x7F, 0x6B, 0x63, 0x63, 0x63, 0x00 }; // M
    data[0x4E - 0x20] = .{ 0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66, 0x66, 0x00 }; // N
    data[0x4F - 0x20] = .{ 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 }; // O
    data[0x50 - 0x20] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00 }; // P
    data[0x51 - 0x20] = .{ 0x3C, 0x66, 0x66, 0x66, 0x6A, 0x6C, 0x36, 0x00 }; // Q
    data[0x52 - 0x20] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0x66, 0x00 }; // R
    data[0x53 - 0x20] = .{ 0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0x00 }; // S
    data[0x54 - 0x20] = .{ 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 }; // T
    data[0x55 - 0x20] = .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 }; // U
    data[0x56 - 0x20] = .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 }; // V
    data[0x57 - 0x20] = .{ 0x63, 0x63, 0x63, 0x6B, 0x7F, 0x77, 0x63, 0x00 }; // W
    data[0x58 - 0x20] = .{ 0x66, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00 }; // X
    data[0x59 - 0x20] = .{ 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x00 }; // Y
    data[0x5A - 0x20] = .{ 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x7E, 0x00 }; // Z
    // a-z (lowercase)
    data[0x61 - 0x20] = .{ 0x00, 0x00, 0x3C, 0x06, 0x3E, 0x66, 0x3E, 0x00 }; // a
    data[0x62 - 0x20] = .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x00 }; // b
    data[0x63 - 0x20] = .{ 0x00, 0x00, 0x3C, 0x66, 0x60, 0x66, 0x3C, 0x00 }; // c
    data[0x64 - 0x20] = .{ 0x06, 0x06, 0x3E, 0x66, 0x66, 0x66, 0x3E, 0x00 }; // d
    data[0x65 - 0x20] = .{ 0x00, 0x00, 0x3C, 0x66, 0x7E, 0x60, 0x3C, 0x00 }; // e
    data[0x66 - 0x20] = .{ 0x1C, 0x30, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x00 }; // f
    data[0x67 - 0x20] = .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x3C }; // g
    data[0x68 - 0x20] = .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 }; // h
    data[0x69 - 0x20] = .{ 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00 }; // i
    data[0x6A - 0x20] = .{ 0x0C, 0x00, 0x1C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38 }; // j
    data[0x6B - 0x20] = .{ 0x60, 0x60, 0x66, 0x6C, 0x78, 0x6C, 0x66, 0x00 }; // k
    data[0x6C - 0x20] = .{ 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 }; // l
    data[0x6D - 0x20] = .{ 0x00, 0x00, 0x76, 0x7F, 0x6B, 0x63, 0x63, 0x00 }; // m
    data[0x6E - 0x20] = .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 }; // n
    data[0x6F - 0x20] = .{ 0x00, 0x00, 0x3C, 0x66, 0x66, 0x66, 0x3C, 0x00 }; // o
    data[0x70 - 0x20] = .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60 }; // p
    data[0x71 - 0x20] = .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x06 }; // q
    data[0x72 - 0x20] = .{ 0x00, 0x00, 0x6C, 0x76, 0x60, 0x60, 0x60, 0x00 }; // r
    data[0x73 - 0x20] = .{ 0x00, 0x00, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x00 }; // s
    data[0x74 - 0x20] = .{ 0x30, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x1C, 0x00 }; // t
    data[0x75 - 0x20] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x3E, 0x00 }; // u
    data[0x76 - 0x20] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 }; // v
    data[0x77 - 0x20] = .{ 0x00, 0x00, 0x63, 0x6B, 0x7F, 0x7F, 0x36, 0x00 }; // w
    data[0x78 - 0x20] = .{ 0x00, 0x00, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x00 }; // x
    data[0x79 - 0x20] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x3C }; // y
    data[0x7A - 0x20] = .{ 0x00, 0x00, 0x7E, 0x0C, 0x18, 0x30, 0x7E, 0x00 }; // z
    // Common punctuation
    data[0x2E - 0x20] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00 }; // .
    data[0x2C - 0x20] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30 }; // ,
    data[0x3A - 0x20] = .{ 0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x00 }; // :
    data[0x3B - 0x20] = .{ 0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x30 }; // ;
    data[0x2D - 0x20] = .{ 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00 }; // -
    data[0x3D - 0x20] = .{ 0x00, 0x00, 0x7E, 0x00, 0x7E, 0x00, 0x00, 0x00 }; // =
    data[0x28 - 0x20] = .{ 0x0C, 0x18, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00 }; // (
    data[0x29 - 0x20] = .{ 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00 }; // )
    data[0x5B - 0x20] = .{ 0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00 }; // [
    data[0x5D - 0x20] = .{ 0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00 }; // ]
    data[0x2F - 0x20] = .{ 0x02, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x40, 0x00 }; // /
    data[0x3F - 0x20] = .{ 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x00, 0x18, 0x00 }; // ?

    return data;
}

// ── Glyph atlas ────────────────────────────────────────────────────────
//
// Text renders through the textured-sprite path: the embedded 8x8 bitmap
// font is baked ONCE into an RGBA8 atlas texture, and each printable glyph
// is drawn as a single sampled sprite quad (vs. the old per-pixel solid
// shape-quad rasterizer). The atlas lays the 95 printable glyphs in a
// FONT_ATLAS_COLS x FONT_ATLAS_ROWS grid; each cell carries the 8x8 glyph
// plus FONT_ATLAS_PAD px of transparent padding on every side so nearest
// sampling at a quad edge can never bleed into a neighbouring cell.
//
// Per-texel encoding: white RGB (255,255,255) with alpha = coverage (255
// where the font bit is set, 0 where clear); padding texels are fully
// transparent (0,0,0,0). The sprite fragment shader computes `texel *
// vColor`, so a quad tinted by `tint` yields (tint.rgb, tint.a * coverage)
// — correctly tinted text with crisp edges under the nearest sampler.
const FONT_ATLAS_COLS = 16;
const FONT_ATLAS_ROWS = 6; // 16*6 = 96 cells >= 95 glyphs
const FONT_ATLAS_PAD = 1; // transparent border px around each glyph cell
const FONT_ATLAS_CELL_W = FONT_GLYPH_W + 2 * FONT_ATLAS_PAD; // 10
const FONT_ATLAS_CELL_H = FONT_GLYPH_H + 2 * FONT_ATLAS_PAD; // 10
const FONT_ATLAS_W = FONT_ATLAS_COLS * FONT_ATLAS_CELL_W; // 160
const FONT_ATLAS_H = FONT_ATLAS_ROWS * FONT_ATLAS_CELL_H; // 60

/// Texture id of the baked glyph atlas, or 0 = "not built yet". Texture id
/// 0 is never handed out (`next_texture_id` starts at 1), so it's a safe
/// sentinel. Built lazily on the first `drawText`.
var font_atlas_texture_id: u32 = 0;

/// Render the embedded bitmap font into an RGBA8 pixel buffer laid out as
/// the glyph atlas described above. White-RGB + alpha-coverage encoding;
/// padding texels are transparent.
pub fn buildFontAtlasPixels(buf: *[FONT_ATLAS_W * FONT_ATLAS_H * 4]u8) void {
    // Start fully transparent — this also covers all padding texels.
    @memset(buf, 0);
    for (font_data, 0..) |glyph, gi| {
        const cell_col = gi % FONT_ATLAS_COLS;
        const cell_row = gi / FONT_ATLAS_COLS;
        const origin_x = cell_col * FONT_ATLAS_CELL_W + FONT_ATLAS_PAD;
        const origin_y = cell_row * FONT_ATLAS_CELL_H + FONT_ATLAS_PAD;
        for (glyph, 0..) |row_bits, row| {
            var c: usize = 0;
            while (c < FONT_GLYPH_W) : (c += 1) {
                const set = (row_bits >> @intCast(FONT_GLYPH_W - 1 - c)) & 1 == 1;
                if (!set) continue; // leave transparent
                const px = origin_x + c;
                const py = origin_y + row;
                const idx = (py * FONT_ATLAS_W + px) * 4;
                buf[idx + 0] = 255; // R
                buf[idx + 1] = 255; // G
                buf[idx + 2] = 255; // B
                buf[idx + 3] = 255; // A = coverage
            }
        }
    }
}

/// Latched once the atlas upload fails (e.g. texture-pool exhaustion) so
/// `drawText` doesn't re-bake the 38 KB atlas and spam the log every call /
/// every frame thereafter.
var font_atlas_failed: bool = false;

/// Build + upload the glyph atlas texture if it hasn't been built yet.
/// Returns the texture id, or 0 on failure (upload error). The failure is
/// latched so subsequent calls return 0 immediately without re-baking.
pub fn ensureFontAtlas() u32 {
    if (font_atlas_texture_id != 0) return font_atlas_texture_id;
    if (font_atlas_failed) return 0;
    var pixels: [FONT_ATLAS_W * FONT_ATLAS_H * 4]u8 = undefined;
    buildFontAtlasPixels(&pixels);
    // uploadTexture COPIES the pixels into a slot it owns, so a stack
    // buffer that dies at return is fine.
    const tex = texture.uploadTexture(.{
        .pixels = pixels[0..],
        .width = FONT_ATLAS_W,
        .height = FONT_ATLAS_H,
    }) catch {
        log.warn("failed to upload glyph atlas; text will not render", .{});
        font_atlas_failed = true;
        return 0;
    };
    font_atlas_texture_id = tex.id;
    return font_atlas_texture_id;
}

pub fn drawText(text: [:0]const u8, x: f32, y: f32, size: f32, tint: Color) void {
    const atlas_id = ensureFontAtlas();
    if (atlas_id == 0) return; // atlas build failed; nothing to draw

    const col = tint.toAbgr();
    const scale = size / @as(f32, FONT_GLYPH_H);
    const glyph_w: f32 = @as(f32, FONT_GLYPH_W) * scale;

    const atlas_w_f: f32 = @as(f32, FONT_ATLAS_W);
    const atlas_h_f: f32 = @as(f32, FONT_ATLAS_H);

    var cursor_x = x;
    for (text) |ch| {
        if (ch == 0) break; // NUL terminator
        // Printable, non-space glyphs emit one textured quad. Space (0x20)
        // and out-of-range chars emit nothing but still advance the cursor,
        // keeping metrics identical to the old rasterizer (width == n_chars
        // * glyph_w).
        if (ch > 0x20 and ch <= 0x7E) {
            if (!batch.hasSpriteCapacity(4, 6)) {
                log.warn("sprite batch full, dropping text glyphs", .{});
                return;
            }

            const gi: usize = ch - 0x20;
            const cell_col = gi % FONT_ATLAS_COLS;
            const cell_row = gi / FONT_ATLAS_COLS;
            // Inner 8x8 region (padding excluded) — UVs map exactly to it,
            // so nearest sampling never picks a padding/neighbour texel.
            const inner_x: f32 = @floatFromInt(cell_col * FONT_ATLAS_CELL_W + FONT_ATLAS_PAD);
            const inner_y: f32 = @floatFromInt(cell_row * FONT_ATLAS_CELL_H + FONT_ATLAS_PAD);
            const uv_x0 = inner_x / atlas_w_f;
            const uv_y0 = inner_y / atlas_h_f;
            const uv_x1 = (inner_x + @as(f32, FONT_GLYPH_W)) / atlas_w_f;
            const uv_y1 = (inner_y + @as(f32, FONT_GLYPH_H)) / atlas_h_f;

            // Screen rect for the whole glyph cell (same metrics as before).
            const gx0 = cursor_x;
            const gy0 = y;
            const gx1 = cursor_x + glyph_w;
            const gy1 = y + size;

            const seg_index_start: u32 = @intCast(batch.spriteIndexCount());
            const seg_quad_start: u32 = @intCast(batch.spriteQuadCount());

            batch.appendSpriteTextureId(atlas_id);

            const base: u32 = @intCast(batch.spriteVertexCount());
            // TL, TR, BR, BL — matches drawTexturePro winding/index pattern.
            batch.appendSpriteVertex(SpriteVertex.init(toNdcX(gx0), toNdcY(gy0), uv_x0, uv_y0, col));
            batch.appendSpriteVertex(SpriteVertex.init(toNdcX(gx1), toNdcY(gy0), uv_x1, uv_y0, col));
            batch.appendSpriteVertex(SpriteVertex.init(toNdcX(gx1), toNdcY(gy1), uv_x1, uv_y1, col));
            batch.appendSpriteVertex(SpriteVertex.init(toNdcX(gx0), toNdcY(gy1), uv_x0, uv_y1, col));

            batch.appendSpriteIndex(base + 0);
            batch.appendSpriteIndex(base + 1);
            batch.appendSpriteIndex(base + 2);
            batch.appendSpriteIndex(base + 0);
            batch.appendSpriteIndex(base + 2);
            batch.appendSpriteIndex(base + 3);

            batch.noteSpriteDraw(seg_index_start, 6, seg_quad_start);
        }
        cursor_x += glyph_w;
    }
}

// ── Atlas-dimension accessors (for tests) ──────────────────────────────

pub const atlas_w = FONT_ATLAS_W;
pub const atlas_h = FONT_ATLAS_H;
pub const atlas_cols = FONT_ATLAS_COLS;
pub const atlas_cell_w = FONT_ATLAS_CELL_W;
pub const atlas_cell_h = FONT_ATLAS_CELL_H;
pub const atlas_pad = FONT_ATLAS_PAD;
