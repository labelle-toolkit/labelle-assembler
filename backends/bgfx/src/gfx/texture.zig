/// Texture handle pool, image decode (BMP / TGA), GPU upload, and the
/// `drawTexturePro` primitive that samples the stored bgfx handle.
/// Owns the `texture_handles` / `texture_pixel_data` arrays —
/// `programs.shutdownPrograms` calls `destroyAllTextures` here on
/// teardown so the bgfx handles get released in the same pass as the
/// shader uniforms.
const std = @import("std");
const bgfx = @import("zbgfx").bgfx;
const types = @import("types.zig");
const state = @import("state.zig");
const programs = @import("programs.zig");
const astc = @import("astc.zig");

const Texture = types.Texture;
const Color = types.Color;
const Rectangle = types.Rectangle;
const Vector2 = types.Vector2;
const PosTexColorVertex = programs.PosTexColorVertex;

// ── Texture handle storage ────────────────────────────────────────────

/// Texture handle storage: maps our Texture.id to bgfx TextureHandle.
const MAX_TEXTURES = 512;
var texture_handles: [MAX_TEXTURES]bgfx.TextureHandle = [_]bgfx.TextureHandle{.{ .idx = std.math.maxInt(u16) }} ** MAX_TEXTURES;
/// Pixel data backing each texture (decoded RGBA8 pixels, owned).
/// Stored so we can free on unload/shutdown. null means no decoded data.
var texture_pixel_data: [MAX_TEXTURES]?[]u8 = [_]?[]u8{null} ** MAX_TEXTURES;

/// Find a free texture slot by scanning for invalid handles (supports reuse after unload).
fn findFreeTextureSlot() ?u32 {
    // Start from 1 (slot 0 is reserved/unused)
    for (1..MAX_TEXTURES) |i| {
        if (texture_handles[i].idx == std.math.maxInt(u16)) {
            return @intCast(i);
        }
    }
    return null;
}

/// Walk every texture slot, destroy its bgfx handle, and free any
/// retained pixel data. Called from `programs.shutdownPrograms` on
/// backend teardown so the bgfx context can finish cleanly. Pre-split
/// this loop was inline in `shutdownPrograms`; moving it next to the
/// state it walks keeps the texture pool's invariants local to this
/// file.
pub fn destroyAllTextures() void {
    for (0..MAX_TEXTURES) |i| {
        if (texture_handles[i].idx != std.math.maxInt(u16)) {
            bgfx.destroyTexture(texture_handles[i]);
            texture_handles[i] = .{ .idx = std.math.maxInt(u16) };
        }
        if (texture_pixel_data[i]) |px| {
            std.heap.page_allocator.free(px);
            texture_pixel_data[i] = null;
        }
    }
}

// Zig 0.16 removed `std.fs.cwd()` in favour of `std.Io.Dir.cwd()`, which
// requires an `Io` parameter threaded through the call site. This file
// is a demo/legacy convenience loader — production texture loading goes
// through `uploadTexture` + a caller-owned `decodeImage` (see the
// split-contract comment on `uploadTexture` below), which never touches
// the FS directly. Rather than thread `Io` through the backend for a
// one-shot loader, we use libc `fopen` / `fread` / `fclose` to keep the
// existing `(path) !Texture` signature. `link_libc = true` is set on
// the gfx module (see backends/bgfx/build.zig) so libc is available at
// link time at no extra cost (the bgfx backend has hand-rolled BMP/TGA
// decoders and does NOT link stb_image, so the libc link is added
// explicitly for this loader).
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

pub fn loadTexture(path: [:0]const u8) !Texture {
    // Read the file from disk via libc. See the rationale block above.
    const file = std.c.fopen(path.ptr, "rb") orelse return error.LoadFailed;
    defer _ = std.c.fclose(file);

    if (fseek(file, 0, SEEK_END) != 0) return error.LoadFailed;
    const file_size_signed = ftell(file);
    if (file_size_signed < 18) return error.LoadFailed; // Too small for any image header
    if (fseek(file, 0, SEEK_SET) != 0) return error.LoadFailed;
    const file_size: usize = @intCast(file_size_signed);

    const allocator = std.heap.page_allocator;
    const data = allocator.alloc(u8, file_size) catch return error.LoadFailed;
    defer allocator.free(data);

    const bytes_read = std.c.fread(data.ptr, 1, file_size, file);
    if (bytes_read != file_size) {
        // `fread` can return short on EOF mid-read without setting an error
        // flag, so we must compare against the full requested size — not
        // just the minimum image header — or we'd silently decode a truncated
        // file. See PR #227 (cursor[bot] review).
        std.log.warn("texture: short read on {s} ({d}/{d} bytes)", .{ path, bytes_read, file_size });
        return error.LoadFailed;
    }
    if (bytes_read < 18) return error.LoadFailed;

    // GPU-compressed (ASTC) blobs upload as-is — no CPU decode.
    if (astc.isAstc(data[0..bytes_read])) return uploadCompressed(data[0..bytes_read]);

    const decoded = try decodeImage("", data[0..bytes_read], allocator);
    defer allocator.free(decoded.pixels);
    return uploadTexture(decoded);
}

/// Pure CPU decode, safe from a worker thread. The bgfx backend ships
/// hand-rolled BMP and TGA decoders (no stb_image link) — we try BMP
/// first, then fall back to TGA. The caller's allocator owns the
/// returned `pixels` buffer and frees it on both the success and the
/// discard paths.
pub fn decodeImage(
    _: [:0]const u8,
    data: []const u8,
    allocator: std.mem.Allocator,
) !DecodedImage {
    // TODO: Add PNG decoding (requires inflate/zlib decompression) or integrate stb_image
    if (tryDecodeBmp(data, allocator)) |img| return img;
    if (tryDecodeTga(data, allocator)) |img| return img;
    return error.LoadFailed;
}

/// Main/GL-thread GPU upload. bgfx copies the pixel buffer into its own
/// command queue via `bgfx.copy`, so we do NOT free `decoded.pixels` —
/// the caller owns it and frees it on both the success and the discard
/// paths. The backend retains its own copy via bgfx.copy's memcpy.
pub fn uploadTexture(decoded: DecodedImage) !Texture {
    if (decoded.width == 0 or decoded.height == 0) return error.LoadFailed;
    const id = findFreeTextureSlot() orelse return error.LoadFailed;

    const w: u16 = std.math.cast(u16, decoded.width) orelse return error.LoadFailed;
    const h: u16 = std.math.cast(u16, decoded.height) orelse return error.LoadFailed;

    const mem = bgfx.copy(decoded.pixels.ptr, @intCast(decoded.pixels.len));
    const handle = bgfx.createTexture2D(
        w,
        h,
        false,
        1,
        .RGBA8,
        bgfx.SamplerFlags_UClamp | bgfx.SamplerFlags_VClamp,
        mem,
        0,
    );
    if (handle.idx == std.math.maxInt(u16)) return error.LoadFailed;

    texture_handles[id] = handle;
    // The old loadTexture path cached the decoded bytes in
    // texture_pixel_data[id] so it could free them on unload; with the
    // new split contract the caller owns the bytes and bgfx.copy has
    // already taken its own copy, so we leave the slot null here.
    texture_pixel_data[id] = null;

    return .{ .id = id, .width = @intCast(decoded.width), .height = @intCast(decoded.height) };
}

// ── GPU-compressed textures (ASTC) ──────────────────────────────────────────
// The engine's `loadTextureFromMemory` seam (labelle-gfx) dispatches here when
// the backend exposes `isCompressed`/`uploadCompressed` and the blob is
// compressed, skipping the CPU decode entirely. bgfx has no PNG decoder, so for
// a 4K atlas this is also the only zero-cost upload path (labelle-gfx#269/#341).

/// Map an ASTC block size to the matching bgfx `TextureFormat`, or null if bgfx
/// has no enum for it. Covers the full ASTC LDR block-size set bgfx exposes.
fn astcFormat(block_x: u8, block_y: u8) ?bgfx.TextureFormat {
    return switch ((@as(u16, block_x) << 8) | block_y) {
        0x0404 => .ASTC4x4,
        0x0504 => .ASTC5x4,
        0x0505 => .ASTC5x5,
        0x0605 => .ASTC6x5,
        0x0606 => .ASTC6x6,
        0x0805 => .ASTC8x5,
        0x0806 => .ASTC8x6,
        0x0808 => .ASTC8x8,
        0x0a05 => .ASTC10x5,
        0x0a06 => .ASTC10x6,
        0x0a08 => .ASTC10x8,
        0x0a0a => .ASTC10x10,
        0x0c0a => .ASTC12x10,
        0x0c0c => .ASTC12x12,
        else => null,
    };
}

/// Everything needed to upload a validated 2D ASTC blob.
const AstcUpload = struct { fmt: bgfx.TextureFormat, width: u16, height: u16, blocks: []const u8 };

/// Validate an ASTC blob for a 2D bgfx upload, or null if we can't take it
/// as-is: not ASTC, malformed/truncated, 3D, an unsupported block size, or
/// dimensions past `u16`. `isCompressed`/`uploadCompressed` share this so the
/// "can upload as-is" probe and the actual upload never disagree.
fn validateAstc(data: []const u8) ?AstcUpload {
    const hdr = astc.parse(data) orelse return null;
    if (hdr.depth != 1 or hdr.block_z != 1) return null; // bgfx createTexture2D is 2D only
    const fmt = astcFormat(hdr.block_x, hdr.block_y) orelse return null;
    const w = std.math.cast(u16, hdr.width) orelse return null;
    const h = std.math.cast(u16, hdr.height) orelse return null;
    return .{ .fmt = fmt, .width = w, .height = h, .blocks = hdr.blocks };
}

/// True if `data` is a GPU-compressed blob this backend can upload as-is.
pub fn isCompressed(data: []const u8) bool {
    return validateAstc(data) != null;
}

/// Upload an ASTC blob straight to the GPU — no CPU decode. The compressed
/// blocks are copied into bgfx's command queue (`bgfx.copy`), so the caller's
/// buffer can be freed immediately after this returns.
pub fn uploadCompressed(data: []const u8) !Texture {
    const info = validateAstc(data) orelse return error.LoadFailed;
    const id = findFreeTextureSlot() orelse return error.LoadFailed;

    const mem = bgfx.copy(info.blocks.ptr, @intCast(info.blocks.len));
    const handle = bgfx.createTexture2D(
        info.width,
        info.height,
        false,
        1,
        info.fmt,
        bgfx.SamplerFlags_UClamp | bgfx.SamplerFlags_VClamp,
        mem,
        0,
    );
    if (handle.idx == std.math.maxInt(u16)) return error.LoadFailed;
    texture_handles[id] = handle;
    texture_pixel_data[id] = null;
    return .{ .id = id, .width = @intCast(info.width), .height = @intCast(info.height) };
}

pub fn unloadTexture(texture: Texture) void {
    if (texture.id < MAX_TEXTURES) {
        const handle = texture_handles[texture.id];
        if (handle.idx != std.math.maxInt(u16)) {
            bgfx.destroyTexture(handle);
            texture_handles[texture.id] = .{ .idx = std.math.maxInt(u16) };
        }
        if (texture_pixel_data[texture.id]) |px| {
            std.heap.page_allocator.free(px);
            texture_pixel_data[texture.id] = null;
        }
    }
}

fn makeTexVertex(px: f32, py: f32, u: f32, v: f32, abgr: u32) PosTexColorVertex {
    return .{
        .x = state.toNdcX(px),
        .y = state.toNdcY(py),
        .u = u,
        .v = v,
        .abgr = abgr,
    };
}

pub fn drawTexturePro(texture: Texture, source: Rectangle, dest: Rectangle, origin: Vector2, rotation: f32, tint: Color) void {
    if (texture.id >= MAX_TEXTURES) return;
    const handle = texture_handles[texture.id];
    if (handle.idx == std.math.maxInt(u16)) return;

    const abgr = tint.toAbgr();
    const tw: f32 = @floatFromInt(texture.width);
    const th: f32 = @floatFromInt(texture.height);

    // Source rect to UV coordinates
    const uv0 = source.x / tw;
    const tv0 = source.y / th;
    const uv1 = (source.x + source.width) / tw;
    const tv1 = (source.y + source.height) / th;

    // Destination quad corners (before rotation)
    // Scale width, height, and origin by camera zoom for consistent coordinate space
    const zoom = state.cameraZoom();
    const scaled_ox = origin.x * zoom;
    const scaled_oy = origin.y * zoom;
    const dx = state.transformX(dest.x) - scaled_ox;
    const dy = state.transformY(dest.y) - scaled_oy;
    const dw = dest.width * zoom;
    const dh = dest.height * zoom;

    if (rotation == 0.0) {
        // Fast path: axis-aligned textured quad
        const vertices = [6]PosTexColorVertex{
            makeTexVertex(dx, dy, uv0, tv0, abgr),
            makeTexVertex(dx + dw, dy, uv1, tv0, abgr),
            makeTexVertex(dx + dw, dy + dh, uv1, tv1, abgr),
            makeTexVertex(dx, dy, uv0, tv0, abgr),
            makeTexVertex(dx + dw, dy + dh, uv1, tv1, abgr),
            makeTexVertex(dx, dy + dh, uv0, tv1, abgr),
        };
        programs.submitTexturedTriangles(&vertices, handle);
    } else {
        // Rotated quad: rotate corners around origin point
        const rad = rotation * (std.math.pi / 180.0);
        const cos_r = @cos(rad);
        const sin_r = @sin(rad);
        const ox = scaled_ox;
        const oy = scaled_oy;

        const corners = [4][2]f32{
            .{ 0, 0 },
            .{ dw, 0 },
            .{ dw, dh },
            .{ 0, dh },
        };

        var rotated: [4][2]f32 = undefined;
        for (corners, 0..) |corner, i| {
            const cx = corner[0] - ox;
            const cy = corner[1] - oy;
            rotated[i] = .{
                dx + ox + cx * cos_r - cy * sin_r,
                dy + oy + cx * sin_r + cy * cos_r,
            };
        }

        const uvs = [4][2]f32{ .{ uv0, tv0 }, .{ uv1, tv0 }, .{ uv1, tv1 }, .{ uv0, tv1 } };

        const vertices = [6]PosTexColorVertex{
            makeTexVertex(rotated[0][0], rotated[0][1], uvs[0][0], uvs[0][1], abgr),
            makeTexVertex(rotated[1][0], rotated[1][1], uvs[1][0], uvs[1][1], abgr),
            makeTexVertex(rotated[2][0], rotated[2][1], uvs[2][0], uvs[2][1], abgr),
            makeTexVertex(rotated[0][0], rotated[0][1], uvs[0][0], uvs[0][1], abgr),
            makeTexVertex(rotated[2][0], rotated[2][1], uvs[2][0], uvs[2][1], abgr),
            makeTexVertex(rotated[3][0], rotated[3][1], uvs[3][0], uvs[3][1], abgr),
        };
        programs.submitTexturedTriangles(&vertices, handle);
    }
}

// ── Image decoding helpers ─────────────────────────────────────────────

/// CPU-decoded image owned by the caller's allocator. See sokol's
/// `DecodedImage` doc-comment for why this is defined per-backend
/// instead of imported from labelle-gfx — same reasoning applies.
pub const DecodedImage = struct {
    pixels: []u8,
    width: u32,
    height: u32,
};

/// Decode an uncompressed 24-bit or 32-bit BMP to RGBA8.
/// Handles BGR-to-RGB conversion, row padding, and top-down/bottom-up orientation.
fn tryDecodeBmp(data: []const u8, allocator: std.mem.Allocator) ?DecodedImage {
    if (data.len < 54) return null;
    if (data[0] != 'B' or data[1] != 'M') return null;

    const pixel_offset = std.mem.readInt(u32, data[10..14], .little);
    const w_signed = std.mem.readInt(i32, data[18..22], .little);
    const h_signed = std.mem.readInt(i32, data[22..26], .little);
    const bpp = std.mem.readInt(u16, data[28..30], .little);

    if (w_signed <= 0) return null;
    const width: u32 = @intCast(w_signed);
    // BMP height can be negative (top-down); handle both.
    const flip = h_signed > 0;
    const height: u32 = if (h_signed < 0) @intCast(-h_signed) else @intCast(h_signed);

    if (bpp != 24 and bpp != 32) return null; // Only uncompressed RGB/RGBA

    const bytes_per_pixel: u32 = @as(u32, bpp) / 8;
    const row_size = ((width * bytes_per_pixel + 3) / 4) * 4; // BMP rows are 4-byte aligned

    const out_size = @as(usize, width) * @as(usize, height) * 4;
    const pixels = allocator.alloc(u8, out_size) catch return null;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_y = if (flip) height - 1 - y else y;
        const row_off = @as(usize, pixel_offset) + @as(usize, src_y) * @as(usize, row_size);
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const src = row_off + @as(usize, x) * @as(usize, bytes_per_pixel);
            const dst = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 4;
            if (src + bytes_per_pixel > data.len or dst + 4 > pixels.len) {
                allocator.free(pixels);
                return null;
            }
            // BMP stores BGR(A)
            pixels[dst + 0] = data[src + 2]; // R
            pixels[dst + 1] = data[src + 1]; // G
            pixels[dst + 2] = data[src + 0]; // B
            pixels[dst + 3] = if (bytes_per_pixel == 4) data[src + 3] else 255;
        }
    }

    return DecodedImage{ .pixels = pixels, .width = width, .height = height };
}

/// Decode an uncompressed TGA (type 2) to RGBA8.
/// Handles 24/32-bit pixels, BGR-to-RGB conversion, and orientation via descriptor bit 5.
fn tryDecodeTga(data: []const u8, allocator: std.mem.Allocator) ?DecodedImage {
    if (data.len < 18) return null;

    const image_type = data[2];
    if (image_type != 2) return null; // Only uncompressed true-color

    const width: u32 = std.mem.readInt(u16, data[12..14], .little);
    const height: u32 = std.mem.readInt(u16, data[14..16], .little);
    const bpp = data[16];
    const descriptor = data[17];

    if (width == 0 or height == 0) return null;
    if (bpp != 24 and bpp != 32) return null;

    const id_len: usize = data[0];
    const pixel_offset: usize = 18 + id_len;
    const bytes_per_pixel: usize = @as(usize, bpp) / 8;
    // Bit 5 of descriptor: 0 = bottom-up (default TGA), 1 = top-down
    const top_down = (descriptor & 0x20) != 0;

    const out_size = @as(usize, width) * @as(usize, height) * 4;
    const pixels = allocator.alloc(u8, out_size) catch return null;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const src_y = if (!top_down) height - 1 - y else y;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const src = pixel_offset + (@as(usize, src_y) * @as(usize, width) + @as(usize, x)) * bytes_per_pixel;
            const dst = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 4;
            if (src + bytes_per_pixel > data.len or dst + 4 > pixels.len) {
                allocator.free(pixels);
                return null;
            }
            // TGA stores BGR(A)
            pixels[dst + 0] = data[src + 2]; // R
            pixels[dst + 1] = data[src + 1]; // G
            pixels[dst + 2] = data[src + 0]; // B
            pixels[dst + 3] = if (bytes_per_pixel == 4) data[src + 3] else 255;
        }
    }

    return DecodedImage{ .pixels = pixels, .width = width, .height = height };
}

// TODO: Add PNG decoding (requires inflate/zlib decompression) or integrate stb_image
