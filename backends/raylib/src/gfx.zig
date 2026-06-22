/// Raylib gfx backend — satisfies the labelle-gfx Backend(Impl) contract.
const std = @import("std");
const rl = @import("raylib");
const astc = @import("astc.zig");

// ── Backend types ──────────────────────────────────────────────────────

pub const Texture = struct { id: u32, width: i32, height: i32 };

/// CPU-decoded image owned by the caller's allocator. See sokol's
/// `DecodedImage` doc-comment for why this is defined per-backend
/// instead of imported from labelle-gfx — same reasoning applies.
pub const DecodedImage = struct {
    pixels: []u8,
    width: u32,
    height: u32,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    fn toRl(c: Color) rl.Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
    }
};

pub const Rectangle = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    fn toRl(r: Rectangle) rl.Rectangle {
        return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
    }
};

pub const Vector2 = struct {
    x: f32,
    y: f32,

    fn toRl(v: Vector2) rl.Vector2 {
        return .{ .x = v.x, .y = v.y };
    }
};

pub const Camera2D = struct {
    offset: Vector2 = .{ .x = 0, .y = 0 },
    target: Vector2 = .{ .x = 0, .y = 0 },
    rotation: f32 = 0,
    zoom: f32 = 1,

    fn toRl(c: Camera2D) rl.Camera2D {
        return .{
            .offset = .{ .x = c.offset.x, .y = c.offset.y },
            .target = .{ .x = c.target.x, .y = c.target.y },
            .rotation = c.rotation,
            .zoom = c.zoom,
        };
    }
};

// ── Color constants ────────────────────────────────────────────────────

pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
pub const red = Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
pub const green = Color{ .r = 0, .g = 255, .b = 0, .a = 255 };
pub const blue = Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

// ── Draw primitives (Backend contract) ─────────────────────────────────

pub fn drawTexturePro(texture: Texture, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: f32, tint: Color) void {
    const rl_tex: rl.Texture = .{
        .id = @intCast(texture.id),
        .width = texture.width,
        .height = texture.height,
        .mipmaps = 1,
        .format = .uncompressed_r8g8b8a8,
    };
    rl.drawTexturePro(rl_tex, source.toRl(), dest.toRl(), origin.toRl(), rotation, tint.toRl());
}

pub fn drawRectangleRec(rec: Rectangle, tint: Color) void {
    rl.drawRectangleRec(rec.toRl(), tint.toRl());
}

pub fn drawCircle(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
    rl.drawCircleV(.{ .x = center_x, .y = center_y }, radius, tint.toRl());
}

pub fn drawRectangleLinesEx(rec: Rectangle, line_thick: f32, tint: Color) void {
    rl.drawRectangleLinesEx(rec.toRl(), line_thick, tint.toRl());
}

pub fn drawCircleLines(center_x: f32, center_y: f32, radius: f32, tint: Color) void {
    rl.drawCircleLinesV(.{ .x = center_x, .y = center_y }, radius, tint.toRl());
}

pub fn drawLine(start_x: f32, start_y: f32, end_x: f32, end_y: f32, thickness: f32, tint: Color) void {
    rl.drawLineEx(.{ .x = start_x, .y = start_y }, .{ .x = end_x, .y = end_y }, thickness, tint.toRl());
}

/// Filled triangle through the three absolute vertices. raylib's
/// `DrawTriangle` wants vertices in counter-clockwise winding;
/// `drawTriangleFan` would be needed for arbitrary winding, but the
/// retained-engine geometry is authored CCW so the direct call is fine.
pub fn drawTriangle(v1: Vector2, v2: Vector2, v3: Vector2, tint: Color) void {
    // raylib's DrawTriangle only fills vertices wound counter-clockwise in its
    // y-down screen space (signed cross < 0); a clockwise winding (cross > 0)
    // renders nothing. sokol/wgpu are winding-agnostic, so normalize here by
    // swapping v2/v3 when the input is clockwise — making the primitive
    // backend-consistent regardless of caller winding (e.g. the wgpu example's
    // decorative triangle + velocity arrowheads).
    const cross = (v2.x - v1.x) * (v3.y - v1.y) - (v2.y - v1.y) * (v3.x - v1.x);
    if (cross > 0) {
        rl.drawTriangle(v1.toRl(), v3.toRl(), v2.toRl(), tint.toRl());
    } else {
        rl.drawTriangle(v1.toRl(), v2.toRl(), v3.toRl(), tint.toRl());
    }
}

/// Filled convex polygon through the absolute rim vertices in `points`
/// (position + scale already applied by the caller). Slice/Color
/// signature matches the labelle-gfx Backend contract. Decomposed into a
/// triangle fan anchored at `points[0]` and routed through `drawTriangle`
/// so raylib's CCW-only winding requirement is normalized per-triangle —
/// no dependency on a `drawTriangleFan` binding that may be absent.
pub fn drawPolygon(points: []const Vector2, tint: Color) void {
    if (points.len < 3) return;
    var i: usize = 1;
    while (i + 1 < points.len) : (i += 1) {
        drawTriangle(points[0], points[i], points[i + 1], tint);
    }
}

pub fn drawText(text: [:0]const u8, x: f32, y: f32, size: f32, tint: Color) void {
    rl.drawText(text, @intFromFloat(x), @intFromFloat(y), @intFromFloat(size), tint.toRl());
}

pub fn color(r: u8, g: u8, b: u8, a: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

pub fn loadTexture(path: [:0]const u8) !Texture {
    const tex = rl.loadTexture(path) catch return error.LoadFailed;
    if (tex.id == 0) return error.LoadFailed;
    return .{ .id = @intCast(tex.id), .width = tex.width, .height = tex.height };
}

/// "LRGBA" + 3 padding bytes (8-byte alignment). Followed by u32 LE
/// width, u32 LE height, then width*height*4 bytes of RGBA pixels.
/// Produced by `labelle build --bake` (labelle-cli) to skip PNG decode
/// on cold start. See labelle-cli/src/cli/bake.zig.
const lrgba_magic = "LRGBA\x00\x00\x00";
const lrgba_header_len = lrgba_magic.len + 8;

/// Pure CPU decode, safe from a worker thread. Uses raylib's built-in
/// `loadImageFromMemory` (which calls stb_image internally), normalises
/// the result to RGBA8, copies the pixels into an allocator-owned buffer
/// and frees the raylib-owned image. The caller owns the returned
/// `pixels` slice and frees it on both the success and the discard path.
pub fn decodeImage(
    file_type: [:0]const u8,
    data: []const u8,
    allocator: std.mem.Allocator,
) !DecodedImage {
    // Fast path: pre-baked LRGBA container. No PNG decode needed —
    // the bake step already ran stb_image at build time.
    if (data.len >= lrgba_header_len and std.mem.eql(u8, data[0..lrgba_magic.len], lrgba_magic)) {
        const w = std.mem.readInt(u32, data[lrgba_magic.len..][0..4], .little);
        const h = std.mem.readInt(u32, data[lrgba_magic.len + 4 ..][0..4], .little);
        if (w == 0 or h == 0) return error.LoadFailed;
        // Checked arithmetic — see sokol gfx decodeImage for rationale.
        const wh = std.math.mul(usize, @as(usize, w), @as(usize, h)) catch return error.LoadFailed;
        const pixels_len = std.math.mul(usize, wh, 4) catch return error.LoadFailed;
        const end = std.math.add(usize, lrgba_header_len, pixels_len) catch return error.LoadFailed;
        if (data.len < end) return error.LoadFailed;
        const owned = try allocator.alloc(u8, pixels_len);
        @memcpy(owned, data[lrgba_header_len..end]);
        return .{ .pixels = owned, .width = w, .height = h };
    }

    var image = rl.loadImageFromMemory(file_type, data) catch return error.LoadFailed;
    defer rl.unloadImage(image);

    // Force RGBA8 so the caller can treat `pixels` as 4 bytes per pixel
    // without having to branch on raylib's PixelFormat enum.
    if (image.format != .uncompressed_r8g8b8a8) {
        rl.imageFormat(&image, .uncompressed_r8g8b8a8);
        if (image.format != .uncompressed_r8g8b8a8) return error.LoadFailed;
    }

    if (image.width <= 0 or image.height <= 0) return error.LoadFailed;

    const width: u32 = @intCast(image.width);
    const height: u32 = @intCast(image.height);
    const len: usize = @as(usize, width) * @as(usize, height) * 4;

    const owned = try allocator.alloc(u8, len);
    const src: [*]const u8 = @ptrCast(image.data);
    @memcpy(owned, src[0..len]);

    return .{
        .pixels = owned,
        .width = width,
        .height = height,
    };
}

/// Main/GL-thread GPU upload. Synthesises a raylib `Image` that points
/// into the caller's pixel buffer (raylib's `loadTextureFromImage` copies
/// the pixels to the GPU and does not retain ownership), then returns
/// the resulting texture. Does NOT free `decoded.pixels` — the caller
/// frees that buffer on both the success and the discard path.
pub fn uploadTexture(decoded: DecodedImage) !Texture {
    const image: rl.Image = .{
        .data = @ptrCast(@constCast(decoded.pixels.ptr)),
        .width = @intCast(decoded.width),
        .height = @intCast(decoded.height),
        .mipmaps = 1,
        .format = .uncompressed_r8g8b8a8,
    };
    const tex = rl.loadTextureFromImage(image) catch return error.LoadFailed;
    if (tex.id == 0) return error.LoadFailed;
    return .{ .id = @intCast(tex.id), .width = tex.width, .height = tex.height };
}

// ── GPU-compressed textures (ASTC) ──────────────────────────────────────────
// The engine's `loadTextureFromMemory` seam (labelle-gfx) dispatches here when
// the backend exposes `isCompressed`/`uploadCompressed` and the blob is
// compressed, skipping the CPU decode entirely (labelle-gfx#269/#341).
//
// raylib-zig exposes no `rlLoadTextureCompressed` wrapper, but raylib's
// `loadTextureFromImage` is the binding-native equivalent: it forwards the
// `Image.format`/`Image.data` straight to `rlLoadTexture`, which—for a
// compressed `PixelFormat`—uploads the verbatim block payload via
// `glCompressedTexImage2D` (no CPU decode). So we wrap the compressed blocks in
// an `Image` carrying the ASTC `PixelFormat` and reuse the same upload call as
// `uploadTexture`. raylib computes the GPU mip size itself from
// width/height/format (`rlGetPixelDataSize`); `mipmaps = 1` (mipmapCount=1).

/// Map an ASTC block size to the matching raylib `PixelFormat`, or null if
/// raylib/rlgl has no enum for it. raylib only ships the ASTC 4×4 and 8×8 LDR
/// RGBA formats (`RL_PIXELFORMAT_COMPRESSED_ASTC_4x4_RGBA` / `_8x8_RGBA`); every
/// other block size returns null so the caller falls back to a CPU decode.
fn astcFormat(block_x: u8, block_y: u8) ?rl.PixelFormat {
    return switch ((@as(u16, block_x) << 8) | block_y) {
        0x0404 => .compressed_astc_4x4_rgba,
        0x0808 => .compressed_astc_8x8_rgba,
        else => null,
    };
}

/// Everything needed to upload a validated 2D ASTC blob.
const AstcUpload = struct { fmt: rl.PixelFormat, width: i32, height: i32, blocks: []const u8 };

/// Validate an ASTC blob for a 2D raylib upload, or null if we can't take it
/// as-is: not ASTC, malformed/truncated, 3D, an unsupported block size, or
/// dimensions past `i32`. `isCompressed`/`uploadCompressed` share this so the
/// "can upload as-is" probe and the actual upload never disagree.
fn validateAstc(data: []const u8) ?AstcUpload {
    const hdr = astc.parse(data) orelse return null;
    if (hdr.depth != 1 or hdr.block_z != 1) return null; // raylib Image is 2D only
    const fmt = astcFormat(hdr.block_x, hdr.block_y) orelse return null;
    const w = std.math.cast(i32, hdr.width) orelse return null;
    const h = std.math.cast(i32, hdr.height) orelse return null;
    return .{ .fmt = fmt, .width = w, .height = h, .blocks = hdr.blocks };
}

/// True if `data` is a GPU-compressed blob this backend can upload as-is.
pub fn isCompressed(data: []const u8) bool {
    return validateAstc(data) != null;
}

/// Image dimensions of a compressed blob, read from the ASTC header without
/// decoding — lets the async asset-catalog adapter set a correct DecodedImage
/// width/height before upload. Null if not an ASTC blob we accept.
pub fn compressedDims(data: []const u8) ?struct { width: u32, height: u32 } {
    const info = validateAstc(data) orelse return null;
    return .{ .width = @intCast(info.width), .height = @intCast(info.height) };
}

/// Upload an ASTC blob straight to the GPU — no CPU decode. The compressed
/// blocks are handed to raylib's `loadTextureFromImage`, which copies them to
/// the GPU via `glCompressedTexImage2D` and does not retain the pointer, so the
/// caller's buffer can be freed immediately after this returns.
pub fn uploadCompressed(data: []const u8) !Texture {
    const info = validateAstc(data) orelse return error.LoadFailed;
    const image: rl.Image = .{
        .data = @ptrCast(@constCast(info.blocks.ptr)),
        .width = info.width,
        .height = info.height,
        .mipmaps = 1,
        .format = info.fmt,
    };
    const tex = rl.loadTextureFromImage(image) catch return error.LoadFailed;
    if (tex.id == 0) return error.LoadFailed;
    return .{ .id = @intCast(tex.id), .width = tex.width, .height = tex.height };
}

pub fn unloadTexture(texture: Texture) void {
    rl.unloadTexture(.{
        .id = @intCast(texture.id),
        .width = texture.width,
        .height = texture.height,
        .mipmaps = 1,
        .format = .uncompressed_r8g8b8a8,
    });
}

pub fn beginMode2D(camera: Camera2D) void {
    rl.beginMode2D(camera.toRl());
}

pub fn endMode2D() void {
    rl.endMode2D();
}

pub fn getScreenWidth() i32 {
    return rl.getScreenWidth();
}

pub fn getScreenHeight() i32 {
    return rl.getScreenHeight();
}

/// raylib handles DPI scaling internally — `getScreenWidth/Height`
/// already return logical (design) pixels in the common case. We
/// still record the design dims here so `getDesignWidth/Height`
/// has a stable answer regardless of the OS's window-size quirks
/// (multi-monitor moves, fullscreen toggles, etc.). When unset,
/// the getters fall back to the live screen size.
var design_w: i32 = 0;
var design_h: i32 = 0;

pub fn setDesignSize(w: i32, h: i32) void {
    design_w = if (w > 0) w else 0;
    design_h = if (h > 0) h else 0;
}

pub fn getDesignWidth() i32 {
    return if (design_w > 0) design_w else rl.getScreenWidth();
}

pub fn getDesignHeight() i32 {
    return if (design_h > 0) design_h else rl.getScreenHeight();
}

pub fn screenToWorld(pos: Vector2, camera: Camera2D) Vector2 {
    const result = rl.getScreenToWorld2D(pos.toRl(), camera.toRl());
    return .{ .x = result.x, .y = result.y };
}

pub fn worldToScreen(pos: Vector2, camera: Camera2D) Vector2 {
    const result = rl.getWorldToScreen2D(pos.toRl(), camera.toRl());
    return .{ .x = result.x, .y = result.y };
}

// ── Phase 4 font surface (labelle-gfx#259, labelle-engine#448) ──────────
//
// Decode/upload split mirrors the image path: pure CPU bake in `decodeFont`
// (worker-thread safe — stb_truetype only touches its own context + the
// allocator-owned bitmap buffer), GPU upload in `uploadFontAtlas` on the
// main thread (calls raylib's `loadTextureFromImage`).
//
// Types are `extern struct` so the assembler's `writeFontBackendWiring`
// field-by-field copy into `engine.DecodedFont` lands on a stable memory
// layout. Field shape is identical to `labelle-gfx`'s `backend.zig`
// definitions — the gfx wrapper exposes `FontAtlas` via `@hasDecl(Impl,
// "FontAtlas")`, so declaring these as top-level `pub` opts this backend
// in to the font traits.

const stbtt = @cImport({
    @cInclude("stb_truetype.h");
});

pub const CodepointRange = extern struct {
    first: u32,
    last: u32,
};

pub const Glyph = extern struct {
    u0: u16,
    v0: u16,
    u1: u16,
    v1: u16,
    xoff: f32,
    yoff: f32,
    advance: f32,
};

pub const CodepointEntry = extern struct {
    codepoint: u32,
    glyph_index: u32,
};

pub const KernPair = extern struct {
    first: u32,
    second: u32,
    advance: f32,
};

pub const FontBakeParams = struct {
    pixel_height: f32 = 16,
    ranges: []const CodepointRange = &.{.{ .first = 0x20, .last = 0x7F }},
    atlas_width: u32 = 512,
    atlas_height: u32 = 512,
};

/// CPU-decoded font atlas. All four slices are allocator-owned —
/// the caller frees them on BOTH success and discard paths (same
/// contract as `DecodedImage.pixels`). Field layout matches
/// `labelle-gfx`'s `DecodedFont` exactly so the assembler's
/// `writeFontBackendWiring` field-by-field copy lands cleanly.
pub const DecodedFont = struct {
    bitmap: []u8,
    width: u32,
    height: u32,
    glyphs: []Glyph,
    codepoint_index: []const CodepointEntry,
    ascent: f32,
    descent: f32,
    line_gap: f32,
    line_height: f32,
    kerning: []const KernPair,
};

/// GPU-side font atlas handle. The R8 alpha bitmap from `decodeFont`
/// becomes a single-channel `uncompressed_grayscale` raylib texture;
/// the renderer samples it with whatever sampler raylib's default
/// pipeline already configures. `width`/`height` are stored alongside
/// the texture so the renderer can compute normalised UVs from the
/// glyph's pixel-space rect without poking raylib for image metadata.
///
/// `extern struct` so the assembler's `writeFontBackendWiring`
/// field-by-field copy lands on the same stable C-ABI layout as
/// `CodepointRange`, `Glyph`, `CodepointEntry`, and `KernPair`.
pub const FontAtlas = extern struct {
    texture_id: u32,
    width: u32,
    height: u32,
};

/// Pure CPU bake — runs on the asset worker thread.
///
/// Design: `stbtt_PackBegin` + `stbtt_PackFontRange` (one call per
/// `CodepointRange`) + `stbtt_PackEnd`. We picked the pack API over
/// `stbtt_BakeFontBitmap` because the pack path:
///   1. Honors multiple non-contiguous codepoint ranges (e.g.
///      ASCII + Latin-1 supplement) without re-walking the font for
///      each range.
///   2. Uses skyline packing — denser than BakeFontBitmap's left-to-
///      right strip pack, which matters once a project bakes more
///      than a couple of ranges into one atlas.
///   3. Supports oversampling via `stbtt_PackSetOversampling` (we
///      leave it at the default 1× for now — a future PR can expose
///      it through `FontBakeParams`).
///
/// All four output slices (`bitmap`, `glyphs`, `codepoint_index`,
/// `kerning`) come from `allocator` so the caller can free them
/// through the same allocator on both success and discard.
pub fn decodeFont(
    file_type: [:0]const u8,
    data: []const u8,
    params: *const FontBakeParams,
    allocator: std.mem.Allocator,
) !DecodedFont {
    // stb_truetype handles both .ttf and .otf transparently — the
    // CFF (OTF) outline path was added upstream long ago. We accept
    // both extensions and don't dispatch on `file_type` further.
    _ = file_type;

    if (data.len == 0) return error.FontDecodeFailed;
    if (params.atlas_width == 0 or params.atlas_height == 0) return error.FontDecodeFailed;

    // Initialise the font info first — we need vertical metrics +
    // kerning out-of-band from the packed glyph data. `font_index = 0`
    // because TTC (font collection) support is not on the Phase 4 roadmap.
    var font_info: stbtt.stbtt_fontinfo = undefined;
    const offset = stbtt.stbtt_GetFontOffsetForIndex(@ptrCast(data.ptr), 0);
    if (offset < 0) return error.FontDecodeFailed;
    if (stbtt.stbtt_InitFont(&font_info, @ptrCast(data.ptr), offset) == 0) {
        return error.FontDecodeFailed;
    }

    // R8 alpha atlas — we upload it as `uncompressed_grayscale` on
    // the raylib side. Allocate the bitmap from `allocator` so the
    // caller frees it on both the success and discard paths
    // (mirroring `decodeImage`).
    const atlas_w: usize = params.atlas_width;
    const atlas_h: usize = params.atlas_height;
    // Guard against 32-bit (incl. wasm32) `usize` wraparound on the
    // bitmap size multiply — a wrap would alloc an undersized buffer
    // that the C packer happily writes past.
    const bitmap_len = std.math.mul(usize, atlas_w, atlas_h) catch return error.FontAtlasTooLarge;
    const bitmap = try allocator.alloc(u8, bitmap_len);
    errdefer allocator.free(bitmap);
    @memset(bitmap, 0);

    var pack_ctx: stbtt.stbtt_pack_context = undefined;
    if (stbtt.stbtt_PackBegin(
        &pack_ctx,
        bitmap.ptr,
        @intCast(atlas_w),
        @intCast(atlas_h),
        0, // stride = 0 → tightly packed
        1, // 1px padding for bilinear filtering safety
        null,
    ) == 0) {
        return error.FontDecodeFailed;
    }
    defer stbtt.stbtt_PackEnd(&pack_ctx);

    // Default oversampling. A future revision can expose this via
    // FontBakeParams; for now we match the engine's expectation of
    // crisp pixel-aligned glyphs at the requested pixel_height.
    stbtt.stbtt_PackSetOversampling(&pack_ctx, 1, 1);

    // Normalise the ranges slice: an empty slice means "default
    // ASCII printable" per the engine contract.
    const effective_ranges: []const CodepointRange = if (params.ranges.len == 0)
        &[_]CodepointRange{.{ .first = 0x20, .last = 0x7F }}
    else
        params.ranges;

    // Count total glyphs across all ranges so we can allocate the
    // dense `glyphs` and `codepoint_index` arrays up-front. Ranges
    // are half-open [first, last) per the labelle-gfx contract —
    // matching CodepointRange's documented shape (see
    // `labelle-gfx/src/backend.zig:33`).
    var total_glyphs: usize = 0;
    for (effective_ranges) |r| {
        if (r.last <= r.first) continue;
        total_glyphs += @intCast(r.last - r.first);
    }
    if (total_glyphs == 0) return error.FontDecodeFailed;

    // Temporary stbtt packed-char array shared across ranges — we
    // can pack each range straight into a contiguous block so the
    // unpack loop below maps 1:1 into our `Glyph` array.
    const packed_chars = try allocator.alloc(stbtt.stbtt_packedchar, total_glyphs);
    defer allocator.free(packed_chars);

    const glyphs = try allocator.alloc(Glyph, total_glyphs);
    errdefer allocator.free(glyphs);

    const codepoint_index = try allocator.alloc(CodepointEntry, total_glyphs);
    errdefer allocator.free(codepoint_index);

    var write_idx: usize = 0;
    for (effective_ranges) |r| {
        if (r.last <= r.first) continue;
        const count: c_int = @intCast(r.last - r.first);
        const ok = stbtt.stbtt_PackFontRange(
            &pack_ctx,
            @ptrCast(data.ptr),
            0,
            params.pixel_height,
            @intCast(r.first),
            count,
            &packed_chars[write_idx],
        );
        if (ok == 0) {
            // Partial-pack failures usually mean "atlas too small";
            // bubble it up as a decode error so the catalog reports
            // a clean error to the game. `glyphs` and `codepoint_index`
            // have `errdefer allocator.free(...)` at their alloc sites
            // (above) so we let those fire — manually freeing here
            // would double-free.
            return error.FontAtlasTooSmall;
        }
        write_idx += @intCast(count);
    }

    // Unpack stbtt_packedchar → our extern Glyph, and build the
    // codepoint_index in lock-step. Ranges are emitted in the order
    // the caller listed them; the codepoint_index needs to be
    // sorted by codepoint for the renderer's binary search. We
    // assume caller-supplied ranges are already sorted and
    // non-overlapping — matches the labelle-gfx default ranges + the
    // engine's own bake helpers, and a sort-by-codepoint here would
    // duplicate work for the common case.
    var idx: usize = 0;
    for (effective_ranges) |r| {
        if (r.last <= r.first) continue;
        const count: u32 = r.last - r.first;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const pc = packed_chars[idx];
            glyphs[idx] = .{
                .u0 = pc.x0,
                .v0 = pc.y0,
                .u1 = pc.x1,
                .v1 = pc.y1,
                .xoff = pc.xoff,
                .yoff = pc.yoff,
                .advance = pc.xadvance,
            };
            codepoint_index[idx] = .{
                .codepoint = r.first + i,
                .glyph_index = @intCast(idx),
            };
            idx += 1;
        }
    }

    // Vertical metrics — stbtt returns them in font design units;
    // multiply by the scale-for-pixel-height so the renderer can
    // use them directly in pixels at the baked size.
    var ascent_i: c_int = 0;
    var descent_i: c_int = 0;
    var line_gap_i: c_int = 0;
    stbtt.stbtt_GetFontVMetrics(&font_info, &ascent_i, &descent_i, &line_gap_i);
    const scale: f32 = stbtt.stbtt_ScaleForPixelHeight(&font_info, params.pixel_height);
    const ascent: f32 = @as(f32, @floatFromInt(ascent_i)) * scale;
    const descent: f32 = @as(f32, @floatFromInt(descent_i)) * scale;
    const line_gap: f32 = @as(f32, @floatFromInt(line_gap_i)) * scale;
    const line_height: f32 = ascent - descent + line_gap;

    // Kerning — extract the whole table in one pass via
    // `stbtt_GetKerningTable`. A naive double-loop over
    // `codepoint_index` calling `stbtt_GetCodepointKernAdvance` would
    // be N² (~9K calls for ASCII; quadratic for larger ranges). The
    // single-pass path is O(N + K) where N is the baked codepoint
    // set and K is the font's stored kerning pair count.
    //
    // The kerning table stores GLYPH INDICES, not codepoints, so we
    // build a `glyph_index → codepoint` map by walking the baked
    // codepoints once and resolving each via `stbtt_FindGlyphIndex`.
    // Pairs that reference glyphs outside the baked set are dropped.
    var kern_list = std.array_list.Aligned(KernPair, null).empty;
    errdefer kern_list.deinit(allocator);

    const pair_count_i = stbtt.stbtt_GetKerningTableLength(&font_info);
    if (pair_count_i > 0) {
        const pair_count: usize = @intCast(pair_count_i);

        // glyph-index → codepoint map for the baked set. Two parallel
        // slices sorted by glyph_index, queried with binary search so
        // per-pair lookup is O(log N) rather than O(N).
        const GlyphMapEntry = struct { glyph: i32, codepoint: u32 };
        const map = try allocator.alloc(GlyphMapEntry, codepoint_index.len);
        defer allocator.free(map);
        for (codepoint_index, 0..) |entry, mi| {
            const gi = stbtt.stbtt_FindGlyphIndex(&font_info, @intCast(entry.codepoint));
            map[mi] = .{ .glyph = gi, .codepoint = entry.codepoint };
        }
        std.mem.sort(GlyphMapEntry, map, {}, struct {
            fn lessThan(_: void, a: GlyphMapEntry, b: GlyphMapEntry) bool {
                return a.glyph < b.glyph;
            }
        }.lessThan);

        const lookup = struct {
            fn find(slice: []const GlyphMapEntry, glyph: i32) ?u32 {
                var lo: usize = 0;
                var hi: usize = slice.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (slice[mid].glyph < glyph) {
                        lo = mid + 1;
                    } else if (slice[mid].glyph > glyph) {
                        hi = mid;
                    } else {
                        return slice[mid].codepoint;
                    }
                }
                return null;
            }
        }.find;

        const table = try allocator.alloc(stbtt.stbtt_kerningentry, pair_count);
        defer allocator.free(table);
        const written = stbtt.stbtt_GetKerningTable(&font_info, table.ptr, @intCast(pair_count));
        const written_n: usize = if (written < 0) 0 else @intCast(written);
        for (table[0..written_n]) |entry| {
            if (entry.advance == 0) continue;
            const first_cp = lookup(map, entry.glyph1) orelse continue;
            const second_cp = lookup(map, entry.glyph2) orelse continue;
            try kern_list.append(allocator, .{
                .first = first_cp,
                .second = second_cp,
                .advance = @as(f32, @floatFromInt(entry.advance)) * scale,
            });
        }
    }
    const kerning = try kern_list.toOwnedSlice(allocator);

    return .{
        .bitmap = bitmap,
        .width = params.atlas_width,
        .height = params.atlas_height,
        .glyphs = glyphs,
        .codepoint_index = codepoint_index,
        .ascent = ascent,
        .descent = descent,
        .line_gap = line_gap,
        .line_height = line_height,
        .kerning = kerning,
    };
}

/// Main/GL-thread GPU upload. Wraps the 8-bit alpha bitmap in a
/// raylib `Image` with `uncompressed_grayscale` format and calls
/// `loadTextureFromImage` — raylib copies the bytes to the GPU and
/// does not retain ownership of the input pointer. Does NOT free
/// `decoded.bitmap` — caller owns it (same contract as
/// `uploadTexture` for `DecodedImage.pixels`).
pub fn uploadFontAtlas(decoded: DecodedFont) !FontAtlas {
    const image: rl.Image = .{
        .data = @ptrCast(@constCast(decoded.bitmap.ptr)),
        .width = @intCast(decoded.width),
        .height = @intCast(decoded.height),
        .mipmaps = 1,
        .format = .uncompressed_grayscale,
    };
    const tex = rl.loadTextureFromImage(image) catch return error.FontUploadFailed;
    if (tex.id == 0) return error.FontUploadFailed;
    return .{
        .texture_id = @intCast(tex.id),
        .width = decoded.width,
        .height = decoded.height,
    };
}

/// Counterpart to `uploadFontAtlas`. Idempotent on a zero handle so
/// the catalog's discard path can call it without checking.
pub fn unloadFontAtlas(atlas: FontAtlas) void {
    if (atlas.texture_id == 0) return;
    // Reconstruct a raylib `Texture` shell — raylib's `unloadTexture`
    // only consults `id` for the GPU teardown, so the other fields
    // need to be plausible but not exact. Use grayscale to mirror
    // `uploadFontAtlas`.
    rl.unloadTexture(.{
        .id = @intCast(atlas.texture_id),
        .width = @intCast(atlas.width),
        .height = @intCast(atlas.height),
        .mipmaps = 1,
        .format = .uncompressed_grayscale,
    });
}

// ── Font tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "decodeFont rejects empty data" {
    const empty: []const u8 = &.{};
    const params = FontBakeParams{};
    try testing.expectError(error.FontDecodeFailed, decodeFont("ttf", empty, &params, testing.allocator));
}

test "decodeFont rejects zero-sized atlas" {
    // Non-empty data so we exercise the dimensions check, not the
    // empty-data fast path. Bytes don't need to be a valid TTF — the
    // dimension guard fires before `stbtt_InitFont`.
    const fake = "not-a-real-ttf";
    const params = FontBakeParams{ .atlas_width = 0, .atlas_height = 128 };
    try testing.expectError(error.FontDecodeFailed, decodeFont("ttf", fake, &params, testing.allocator));
}

test "decodeFont surfaces FontDecodeFailed on garbage input" {
    // 1KB of random-ish bytes — `stbtt_InitFont` should reject the
    // missing TTF magic. This is the user-facing failure mode for
    // an asset with the wrong extension or a corrupted file.
    var fake: [1024]u8 = undefined;
    for (&fake, 0..) |*b, i| b.* = @truncate(i);
    const params = FontBakeParams{};
    try testing.expectError(error.FontDecodeFailed, decodeFont("ttf", &fake, &params, testing.allocator));
}
