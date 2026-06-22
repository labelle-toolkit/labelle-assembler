/// WebGPU gfx backend — satisfies the labelle-gfx Backend(Impl) contract.
/// Uses wgpu_native_zig (wgpu-native Zig bindings) for GPU rendering with
/// vertex batching.
///
/// This file is the public façade for the wgpu gfx backend. The
/// implementation is split across `gfx/` submodules to keep each concern
/// below the 1000-line ceiling enforced by labelle-assembler#188 (this
/// file was ~1710 lines before the split):
///
///   - `gfx/types.zig`     — value types (Texture, Color, …) + color
///                           constants + the ColorVertex/SpriteVertex
///                           vertex formats.
///   - `gfx/state.zig`     — screen / camera state + coordinate helpers.
///                           This is where the HiDPI/Retina TWO-SIZE
///                           model lives (physical `screen_w/h` vs. logical
///                           `design_w/h` + aspect-fit), ported from the
///                           bgfx backend (v0.42.0). `toNdcX/Y` map against
///                           the design canvas then aspect-fit into the
///                           physical framebuffer; `screenToDesign` maps
///                           physical input back to design space.
///   - `gfx/batch.zig`     — shape/sprite vertex+index batch state, the
///                           ordered draw-segment stream, and `consumeFrame`.
///   - `gfx/draw.zig`      — shape primitives (rect/circle/line/triangle/
///                           poly) + the textured-quad sprite draw.
///   - `gfx/texture.zig`   — texture-slot pool + image decode (PNG/BMP/TGA)
///                           + load/upload/unload + getTexturePixels.
///   - `gfx/font.zig`      — embedded 8x8 bitmap font + glyph atlas + drawText.
///
/// Submodules are private file-system neighbours. The public surface is
/// consumed via `b.dependency("labelle_wgpu", ...).module("gfx")`, which
/// still points at this file.
const std = @import("std");

const types = @import("gfx/types.zig");
const state = @import("gfx/state.zig");
const batch = @import("gfx/batch.zig");
const draw = @import("gfx/draw.zig");
const texture = @import("gfx/texture.zig");
const font = @import("gfx/font.zig");

// ── Backend types ──────────────────────────────────────────────────────

pub const Texture = types.Texture;
pub const Color = types.Color;
pub const Rectangle = types.Rectangle;
pub const Vector2 = types.Vector2;
pub const Camera2D = types.Camera2D;

// ── Color constants ────────────────────────────────────────────────────

pub const white = types.white;
pub const black = types.black;
pub const red = types.red;
pub const green = types.green;
pub const blue = types.blue;
pub const transparent = types.transparent;

pub const color = types.color;

// ── Vertex types (consumed by the window submitter) ────────────────────

pub const ColorVertex = types.ColorVertex;
pub const SpriteVertex = types.SpriteVertex;

// ── State / coordinate model (HiDPI two-size) ──────────────────────────

pub const setScreenSize = state.setScreenSize;
// Physical↔design coordinate conversion for HiDPI input mapping. The
// camera's `framebufferToWorld` calls `screenToDesign` (guarded by
// `@hasDecl`) so mouse in framebuffer pixels maps to design space.
pub const screenToDesign = state.screenToDesign;
pub const designToPhysical = state.designToPhysical;
pub const getDesignWidth = state.getDesignWidth;
pub const getDesignHeight = state.getDesignHeight;
pub const setDesignSize = state.setDesignSize;
pub const beginMode2D = state.beginMode2D;
pub const endMode2D = state.endMode2D;
pub const getScreenWidth = state.getScreenWidth;
pub const getScreenHeight = state.getScreenHeight;
pub const screenToWorld = state.screenToWorld;
pub const worldToScreen = state.worldToScreen;

// ── Batch / frame consumption (Backend contract) ───────────────────────

pub const SegmentKind = batch.SegmentKind;
pub const DrawSegment = batch.DrawSegment;
pub const Frame = batch.Frame;
pub const resetShapeBatch = batch.resetShapeBatch;
pub const resetSpriteBatch = batch.resetSpriteBatch;
pub const consumeShapeBatch = batch.consumeShapeBatch;
pub const consumeSpriteBatch = batch.consumeSpriteBatch;
/// Backward-compatible alias for `consumeShapeBatch`.
pub const getShapeBatch = batch.consumeShapeBatch;
/// Backward-compatible alias for `consumeSpriteBatch`.
pub const getSpriteBatch = batch.consumeSpriteBatch;
pub const consumeFrame = batch.consumeFrame;

// ── Draw primitives (Backend contract) ─────────────────────────────────

pub const drawRectangleRec = draw.drawRectangleRec;
pub const drawCircle = draw.drawCircle;
pub const drawLine = draw.drawLine;
pub const drawTriangle = draw.drawTriangle;
pub const drawPolygon = draw.drawPolygon;
pub const drawPoly = draw.drawPoly;
pub const drawTexturePro = draw.drawTexturePro;

// ── Texture / Sprite rendering ─────────────────────────────────────────

pub const DecodedImage = texture.DecodedImage;
pub const TexturePixels = texture.TexturePixels;
pub const loadTexture = texture.loadTexture;
pub const decodeImage = texture.decodeImage;
pub const uploadTexture = texture.uploadTexture;
pub const unloadTexture = texture.unloadTexture;
pub const getTexturePixels = texture.getTexturePixels;
// GPU-compressed (ASTC) upload — the labelle-gfx `loadTextureFromMemory` seam
// dispatches to `isCompressed`/`uploadCompressed` via `@hasDecl` when the blob
// is compressed (#341). `getCompressedTexture` is read by the window submitter
// to build the ASTC wgpu texture lazily on the main thread.
pub const isCompressed = texture.isCompressed;
pub const uploadCompressed = texture.uploadCompressed;
// Header-only dims for the async asset-catalog adapter (engine#450), which
// splits worker-thread decode from main-thread upload and so can't use the
// synchronous seam — it reads dims here to set DecodedImage before upload.
pub const compressedDims = texture.compressedDims;
pub const CompressedTexture = texture.CompressedTexture;
pub const getCompressedTexture = texture.getCompressedTexture;

// ── Text rendering ─────────────────────────────────────────────────────

pub const drawText = font.drawText;

// ══════════════════════════════════════════════════════════════════════
// Tests — pure-CPU; no GPU needed. They drive the public façade surface so
// they exercise the same call paths real consumers use after the split.
// ══════════════════════════════════════════════════════════════════════

// Re-import the decode helpers + font internals the tests poke directly.
const decodePng = texture.decodePng;
const ensureFontAtlas = font.ensureFontAtlas;
const buildFontAtlasPixels = font.buildFontAtlasPixels;

// ── Ordered draw-segment tests ─────────────────────────────────────────
// Drive the draw API and assert consumeFrame() yields segments in
// submission order with correct index/quad ranges. No GPU needed.

test "draw segments: shape -> sprite -> shape preserves submission order" {
    // Clear any state leaked from a prior test in this process.
    _ = consumeFrame();
    setScreenSize(800, 600);
    setDesignSize(800, 600);

    const tex = Texture{ .id = 1, .width = 16, .height = 16 };

    // Shape (rect = 6 indices), then sprite (1 quad = 6 indices), then shape.
    drawRectangleRec(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, white);
    drawTexturePro(tex, .{ .x = 0, .y = 0, .width = 16, .height = 16 }, .{ .x = 0, .y = 0, .width = 16, .height = 16 }, .{ .x = 0, .y = 0 }, 0, white);
    drawRectangleRec(.{ .x = 20, .y = 20, .width = 10, .height = 10 }, red);

    const frame = consumeFrame();

    try std.testing.expectEqual(@as(usize, 3), frame.segments.len);

    // Segment 0: shape, first 6 shape indices.
    try std.testing.expectEqual(SegmentKind.shape, frame.segments[0].kind);
    try std.testing.expectEqual(@as(u32, 0), frame.segments[0].index_start);
    try std.testing.expectEqual(@as(u32, 6), frame.segments[0].index_count);

    // Segment 1: sprite, first 6 sprite indices, quad 0.
    try std.testing.expectEqual(SegmentKind.sprite, frame.segments[1].kind);
    try std.testing.expectEqual(@as(u32, 0), frame.segments[1].index_start);
    try std.testing.expectEqual(@as(u32, 6), frame.segments[1].index_count);
    try std.testing.expectEqual(@as(u32, 0), frame.segments[1].quad_start);
    try std.testing.expectEqual(@as(u32, 1), frame.segments[1].quad_count);

    // Segment 2: shape, next 6 shape indices (offset 6, since the sprite
    // lives in a SEPARATE index buffer).
    try std.testing.expectEqual(SegmentKind.shape, frame.segments[2].kind);
    try std.testing.expectEqual(@as(u32, 6), frame.segments[2].index_start);
    try std.testing.expectEqual(@as(u32, 6), frame.segments[2].index_count);

    // Buffers: 2 shape rects = 8 verts / 12 indices; 1 sprite = 4 verts / 6
    // indices / 1 texture id.
    try std.testing.expectEqual(@as(usize, 8), frame.shape_vertices.len);
    try std.testing.expectEqual(@as(usize, 12), frame.shape_indices.len);
    try std.testing.expectEqual(@as(usize, 4), frame.sprite_vertices.len);
    try std.testing.expectEqual(@as(usize, 6), frame.sprite_indices.len);
    try std.testing.expectEqual(@as(usize, 1), frame.sprite_texture_ids.len);
    try std.testing.expectEqual(@as(u32, 1), frame.sprite_texture_ids[0]);
}

test "draw segments: consecutive same-kind draws coalesce into one segment" {
    _ = consumeFrame();
    setScreenSize(800, 600);
    setDesignSize(800, 600);

    const tex = Texture{ .id = 2, .width = 16, .height = 16 };

    // sprite, sprite, shape: the two sprites must merge into one segment.
    drawTexturePro(tex, .{ .x = 0, .y = 0, .width = 16, .height = 16 }, .{ .x = 0, .y = 0, .width = 16, .height = 16 }, .{ .x = 0, .y = 0 }, 0, white);
    drawTexturePro(tex, .{ .x = 0, .y = 0, .width = 16, .height = 16 }, .{ .x = 16, .y = 0, .width = 16, .height = 16 }, .{ .x = 0, .y = 0 }, 0, white);
    drawRectangleRec(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, white);

    const frame = consumeFrame();

    try std.testing.expectEqual(@as(usize, 2), frame.segments.len);

    // Segment 0: one sprite segment spanning both quads.
    try std.testing.expectEqual(SegmentKind.sprite, frame.segments[0].kind);
    try std.testing.expectEqual(@as(u32, 0), frame.segments[0].index_start);
    try std.testing.expectEqual(@as(u32, 12), frame.segments[0].index_count);
    try std.testing.expectEqual(@as(u32, 0), frame.segments[0].quad_start);
    try std.testing.expectEqual(@as(u32, 2), frame.segments[0].quad_count);

    // Segment 1: the trailing shape.
    try std.testing.expectEqual(SegmentKind.shape, frame.segments[1].kind);
    try std.testing.expectEqual(@as(u32, 0), frame.segments[1].index_start);
    try std.testing.expectEqual(@as(u32, 6), frame.segments[1].index_count);
}

test "drawPolygon: fans rim points into shape indices" {
    _ = consumeFrame();
    setScreenSize(800, 600);
    setDesignSize(800, 600);

    // 5 rim points -> 5 shape verts, (5-2)=3 fan triangles -> 9 indices.
    const pts = [_]Vector2{
        .{ .x = 10, .y = 10 },
        .{ .x = 30, .y = 10 },
        .{ .x = 40, .y = 30 },
        .{ .x = 25, .y = 45 },
        .{ .x = 10, .y = 30 },
    };
    drawPolygon(&pts, white);

    const frame = consumeFrame();
    try std.testing.expectEqual(@as(usize, 1), frame.segments.len);
    try std.testing.expectEqual(SegmentKind.shape, frame.segments[0].kind);
    try std.testing.expectEqual(@as(u32, 9), frame.segments[0].index_count);
    try std.testing.expectEqual(@as(usize, 5), frame.shape_vertices.len);
    try std.testing.expectEqual(@as(usize, 9), frame.shape_indices.len);
}

test "draw segments: consumeFrame resets the segment list exactly once" {
    _ = consumeFrame();
    drawRectangleRec(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, white);
    const first = consumeFrame();
    try std.testing.expectEqual(@as(usize, 1), first.segments.len);

    // Next frame starts empty — no leakage.
    const second = consumeFrame();
    try std.testing.expectEqual(@as(usize, 0), second.segments.len);
    try std.testing.expectEqual(@as(usize, 0), second.shape_indices.len);
    try std.testing.expectEqual(@as(usize, 0), second.sprite_indices.len);
}

// ── HiDPI two-size coordinate-model tests ──────────────────────────────
// Verify the new design/physical aspect-fit: with design == physical and
// 1:1 aspect the fit scale is identity (so NDC math is unchanged from the
// old single-size model); a Retina-style 2x physical surface keeps the
// design mapping (fit scale stays identity when aspect ratios match) so
// content fills the framebuffer rather than the top-left quarter.

test "state: equal design/physical keeps identity NDC mapping" {
    setDesignSize(800, 600);
    setScreenSize(800, 600);
    // Design space getters report the LOGICAL canvas (resolution-independent).
    try std.testing.expectEqual(@as(i32, 800), getScreenWidth());
    try std.testing.expectEqual(@as(i32, 600), getScreenHeight());
    try std.testing.expectEqual(@as(i32, 800), getDesignWidth());
    try std.testing.expectEqual(@as(i32, 600), getDesignHeight());
    // A point at the design-canvas center maps to NDC origin.
    _ = consumeFrame();
    drawRectangleRec(.{ .x = 400, .y = 300, .width = 0, .height = 0 }, white);
    const frame = consumeFrame();
    // First vertex of the (degenerate) rect is at (400,300) -> NDC (0,0).
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), frame.shape_vertices[0].position[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), frame.shape_vertices[0].position[1], 1e-5);
}

test "state: Retina 2x physical surface keeps design mapping (no top-left quarter)" {
    // Logical 800x600 game on a 1600x1200 physical Retina framebuffer.
    // Aspect ratios match, so fit scale is identity and the design canvas
    // fills the whole framebuffer — the design-center still maps to NDC 0,
    // and the design corners map to the NDC corners (-1..1), NOT to the
    // top-left quarter as the old single-size model would have produced.
    setDesignSize(800, 600);
    setScreenSize(1600, 1200);
    _ = consumeFrame();
    // Design-space corners: top-left (0,0) and bottom-right (800,600).
    drawRectangleRec(.{ .x = 0, .y = 0, .width = 800, .height = 600 }, white);
    const frame = consumeFrame();
    // Vertex 0 = top-left (0,0) -> NDC (-1, +1); vertex 2 = bottom-right
    // (800,600) -> NDC (+1, -1). Full-screen coverage, not a quarter.
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), frame.shape_vertices[0].position[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), frame.shape_vertices[0].position[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), frame.shape_vertices[2].position[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), frame.shape_vertices[2].position[1], 1e-5);
}

test "state: screenToDesign maps physical edges to design edges on HiDPI (#331)" {
    // 800x600 design on a 1600x1200 (2x) surface (fit==1, design fills it).
    // EDGES — not just the center — must map correctly: the old design-space
    // bar formula returned (-400,-300) for the top-left, drifting clicks.
    setDesignSize(800, 600);
    setScreenSize(1600, 1200);
    const tl = screenToDesign(0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tl.x, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tl.y, 1e-3);
    const br = screenToDesign(1600, 1200);
    try std.testing.expectApproxEqAbs(@as(f32, 800), br.x, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 600), br.y, 1e-3);
    const c = screenToDesign(800, 600);
    try std.testing.expectApproxEqAbs(@as(f32, 400), c.x, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 300), c.y, 1e-3);
}

test "state: screenToDesign and designToPhysical round-trip incl. letterbox (#331)" {
    setDesignSize(800, 600);
    setScreenSize(2000, 1000); // wider -> pillarbox; fit_x != fit_y; screen != design
    const samples = [_][2]f32{ .{ 0, 0 }, .{ 2000, 1000 }, .{ 1000, 500 }, .{ 500, 250 }, .{ 1750, 800 } };
    for (samples) |s| {
        const d = screenToDesign(s[0], s[1]);
        const p = designToPhysical(.{ .x = d.x, .y = d.y });
        try std.testing.expectApproxEqAbs(s[0], p.x, 1e-2);
        try std.testing.expectApproxEqAbs(s[1], p.y, 1e-2);
    }
}

// ── PNG decoder tests ──────────────────────────────────────────────────
// Each fixture is a real PNG (produced by zlib + the PNG spec, see the
// generator in PR #293's history) embedded as a byte array so the test
// is self-contained and exercises the full sniff → inflate → unfilter →
// RGBA8 pipeline.

test "decodePng: 2x2 truecolor+alpha (filter None)" {
    // Pixels (row-major): (255,0,0,255) (0,255,0,128) / (0,0,255,255) (255,255,0,64)
    const png_rgba_2x2 = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d, 0x24, 0x00, 0x00, 0x00, 0x16, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0xcf, 0xc0, 0xf0, 0x1f, 0x08, 0x1b, 0x18, 0x80, 0x34, 0x10, 0x30, 0x38, 0x00, 0x00, 0x42, 0x15, 0x07, 0xba, 0x58, 0x65, 0x3e, 0xfa, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
    const img = decodePng(&png_rgba_2x2, std.testing.allocator) orelse return error.DecodeFailed;
    defer std.testing.allocator.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);
    const want = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 255, 255, 0, 64 };
    try std.testing.expectEqualSlices(u8, &want, img.pixels);
}

test "decodePng: 3x1 truecolor RGB with Sub filter" {
    // Pixels: (10,20,30) (40,60,80) (200,100,50), all alpha padded to 255.
    const png_rgb_sub_3x1 = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x94, 0x82, 0x83, 0xe3, 0x00, 0x00, 0x00, 0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xe4, 0x12, 0x91, 0x93, 0xd3, 0x30, 0x5a, 0xa0, 0xf1, 0x08, 0x00, 0x07, 0x36, 0x02, 0x60, 0x4d, 0x9d, 0x20, 0xcd, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
    const img = decodePng(&png_rgb_sub_3x1, std.testing.allocator) orelse return error.DecodeFailed;
    defer std.testing.allocator.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 3), img.width);
    try std.testing.expectEqual(@as(u32, 1), img.height);
    const want = [_]u8{ 10, 20, 30, 255, 40, 60, 80, 255, 200, 100, 50, 255 };
    try std.testing.expectEqualSlices(u8, &want, img.pixels);
}

test "decodePng: 2x2 indexed palette with tRNS alpha" {
    // Palette: idx0=red(255,0,0) a=255, idx1=green(0,255,0) a=128.
    // Indices row-major: 0,1 / 1,0
    const png_indexed_2x2 = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x03, 0x00, 0x00, 0x00, 0x45, 0x68, 0xfd, 0x16, 0x00, 0x00, 0x00, 0x06, 0x50, 0x4c, 0x54, 0x45, 0xff, 0x00, 0x00, 0x00, 0xff, 0x00, 0xd2, 0x87, 0xef, 0x71, 0x00, 0x00, 0x00, 0x02, 0x74, 0x52, 0x4e, 0x53, 0xff, 0x80, 0x08, 0x0f, 0xb3, 0x6a, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x60, 0x04, 0x42, 0x00, 0x00, 0x0c, 0x00, 0x03, 0x15, 0x9e, 0x18, 0xfc, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
    const img = decodePng(&png_indexed_2x2, std.testing.allocator) orelse return error.DecodeFailed;
    defer std.testing.allocator.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 2), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);
    const want = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 255, 0, 128, 255, 0, 0, 255 };
    try std.testing.expectEqualSlices(u8, &want, img.pixels);
}

test "decodePng: 1x2 grayscale+alpha with Up filter" {
    // Row0 (gray=100, a=255), Row1 (gray=50, a=128); row1 uses Up filter.
    const png_gray_alpha_up_1x2 = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x08, 0x04, 0x00, 0x00, 0x00, 0x33, 0x88, 0x7e, 0xac, 0x00, 0x00, 0x00, 0x0e, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x48, 0xf9, 0xcf, 0x74, 0xae, 0x11, 0x00, 0x08, 0x19, 0x02, 0xb5, 0xd5, 0xbb, 0x84, 0x9c, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
    const img = decodePng(&png_gray_alpha_up_1x2, std.testing.allocator) orelse return error.DecodeFailed;
    defer std.testing.allocator.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 1), img.width);
    try std.testing.expectEqual(@as(u32, 2), img.height);
    const want = [_]u8{ 100, 100, 100, 255, 50, 50, 50, 128 };
    try std.testing.expectEqualSlices(u8, &want, img.pixels);
}

test "decodePng: rejects non-PNG and routes through decodeImage" {
    const not_png = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    try std.testing.expect(decodePng(&not_png, std.testing.allocator) == null);

    // decodeImage should dispatch a real PNG to the PNG decoder.
    const png_rgba_2x2 = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x06, 0x00, 0x00, 0x00, 0x72, 0xb6, 0x0d, 0x24, 0x00, 0x00, 0x00, 0x16, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0xcf, 0xc0, 0xf0, 0x1f, 0x08, 0x1b, 0x18, 0x80, 0x34, 0x10, 0x30, 0x38, 0x00, 0x00, 0x42, 0x15, 0x07, 0xba, 0x58, 0x65, 0x3e, 0xfa, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
    const img = try decodeImage("", &png_rgba_2x2, std.testing.allocator);
    defer std.testing.allocator.free(img.pixels);
    try std.testing.expectEqual(@as(u32, 2), img.width);
}

// ── Glyph-atlas text tests ─────────────────────────────────────────────
// Pure-CPU: drive drawText and inspect the sprite batch / segments / atlas
// pixels. No GPU needed.

test "drawText: emits one sprite quad per non-space printable glyph" {
    _ = consumeFrame();
    setScreenSize(800, 600);
    setDesignSize(800, 600);

    const atlas_id = ensureFontAtlas();
    try std.testing.expect(atlas_id != 0);

    drawText("Hi", 10, 10, 16, white);

    const frame = consumeFrame();

    // "Hi" = 2 non-space printable glyphs -> 2 sprite quads (4 verts / 6
    // indices each), all tagged with the atlas texture id.
    try std.testing.expectEqual(@as(usize, 2), frame.sprite_texture_ids.len);
    try std.testing.expectEqual(atlas_id, frame.sprite_texture_ids[0]);
    try std.testing.expectEqual(atlas_id, frame.sprite_texture_ids[1]);
    try std.testing.expectEqual(@as(usize, 8), frame.sprite_vertices.len);
    try std.testing.expectEqual(@as(usize, 12), frame.sprite_indices.len);
    // Text emits zero shape geometry now.
    try std.testing.expectEqual(@as(usize, 0), frame.shape_vertices.len);

    // The two coalesce into a single ordered sprite segment.
    try std.testing.expectEqual(@as(usize, 1), frame.segments.len);
    try std.testing.expectEqual(SegmentKind.sprite, frame.segments[0].kind);
    try std.testing.expectEqual(@as(u32, 12), frame.segments[0].index_count);
    try std.testing.expectEqual(@as(u32, 2), frame.segments[0].quad_count);
}

test "drawText: space emits no quad but advances the cursor" {
    _ = consumeFrame();
    setScreenSize(800, 600);
    setDesignSize(800, 600);
    _ = ensureFontAtlas();

    // NOTE: consumeFrame returns slices into the SAME global vertex buffer,
    // so a later drawText overwrites an earlier frame's slice. Capture the
    // few values we need immediately after each consume, before drawing again.

    // "AB" = 2 glyphs; "A B" = 3 chars but the space emits no quad -> still 2.
    drawText("AB", 0, 0, 16, white);
    const f1 = consumeFrame();
    try std.testing.expectEqual(@as(usize, 2), f1.sprite_texture_ids.len);
    // Both strings put glyph 'A' at x=0 (quad 0 TL = sprite_vertices[0]) and
    // 'B' at quad 1 TL = sprite_vertices[4]. Gap between them, in NDC.
    const a_left_f1 = f1.sprite_vertices[0].position[0];
    const gap_f1 = f1.sprite_vertices[4].position[0] - a_left_f1;

    drawText("A B", 0, 0, 16, white);
    const f2 = consumeFrame();
    try std.testing.expectEqual(@as(usize, 2), f2.sprite_texture_ids.len);
    const a_left_f2 = f2.sprite_vertices[0].position[0];
    const gap_f2 = f2.sprite_vertices[4].position[0] - a_left_f2;

    // 'A' starts at the same place in both strings.
    try std.testing.expectApproxEqAbs(a_left_f1, a_left_f2, 1e-5);
    // The space advanced the cursor: 'B' sits one extra glyph_w further
    // right in "A B" than in "AB", so the gap is exactly doubled. Ratio is
    // screen-size independent.
    try std.testing.expect(gap_f1 > 0);
    try std.testing.expectApproxEqAbs(2 * gap_f1, gap_f2, 1e-5);
}

test "buildFontAtlasPixels: coverage alpha set where glyph bit is set, padding transparent" {
    var pixels: [font.atlas_w * font.atlas_h * 4]u8 = undefined;
    buildFontAtlasPixels(&pixels);

    // 'A' (0x41) glyph row 0 = 0x18 = 0b00011000 -> set bits at columns 3,4.
    const gi: usize = 0x41 - 0x20;
    const cell_col = gi % font.atlas_cols;
    const cell_row = gi / font.atlas_cols;
    const ox = cell_col * font.atlas_cell_w + font.atlas_pad;
    const oy = cell_row * font.atlas_cell_h + font.atlas_pad;

    // Set texel (row 0, col 3): white RGB + alpha 255.
    {
        const idx = ((oy + 0) * font.atlas_w + (ox + 3)) * 4;
        try std.testing.expectEqual(@as(u8, 255), pixels[idx + 0]);
        try std.testing.expectEqual(@as(u8, 255), pixels[idx + 1]);
        try std.testing.expectEqual(@as(u8, 255), pixels[idx + 2]);
        try std.testing.expectEqual(@as(u8, 255), pixels[idx + 3]);
    }
    // Clear texel (row 0, col 0): fully transparent.
    {
        const idx = ((oy + 0) * font.atlas_w + (ox + 0)) * 4;
        try std.testing.expectEqual(@as(u8, 0), pixels[idx + 3]);
    }
    // Padding texel just left of the glyph's inner origin: fully transparent.
    {
        const idx = (oy * font.atlas_w + (ox - 1)) * 4;
        try std.testing.expectEqual(@as(u8, 0), pixels[idx + 0]);
        try std.testing.expectEqual(@as(u8, 0), pixels[idx + 3]);
    }
}
