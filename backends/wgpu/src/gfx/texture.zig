/// Texture storage + CPU image decoders (BMP / TGA / PNG) for the WebGPU
/// backend. Owns the texture-slot pool: decoded RGBA8 pixels are retained
/// here so the window submitter can lazily create + upload a wgpu texture
/// the first time an id is drawn (gfx loads pixels on a worker thread
/// before the GPU may be ready). No native wgpu dep is referenced — this
/// module is pure CPU and host-testable.
const std = @import("std");

const types = @import("types.zig");
const astc = @import("astc.zig");
const Texture = types.Texture;

// ── Texture storage ────────────────────────────────────────────────────

const MAX_TEXTURES = 256;

const TextureSlot = struct {
    /// Raw RGBA8 pixel data (owned), OR — for a GPU-compressed (ASTC)
    /// slot — the raw compressed block payload (also owned, see
    /// `compressed` below). null means the slot has no CPU-side bytes.
    pixels: ?[]u8 = null,
    width: i32 = 0,
    height: i32 = 0,
    active: bool = false,
    /// Set when this slot holds a GPU-compressed (ASTC) blob rather than
    /// decoded RGBA8. The window submitter reads it (via
    /// `getCompressedTexture`) to create the matching ASTC wgpu texture and
    /// `writeTexture` the blocks with the compressed data layout. null =
    /// ordinary RGBA8 texture (read via `getTexturePixels`).
    compressed: ?CompressedInfo = null,
};

/// ASTC block dimensions for a compressed slot. The submitter maps these to
/// the wgpu `TextureFormat` (4x4 / 6x6 / 8x8 / …) and derives the compressed
/// `bytes_per_row` / `rows_per_image`. The block payload itself lives in the
/// slot's `pixels` field (owned, uploaded verbatim).
const CompressedInfo = struct {
    block_x: u8,
    block_y: u8,
};

var textures: [MAX_TEXTURES]TextureSlot = [_]TextureSlot{.{}} ** MAX_TEXTURES;
var next_texture_id: u32 = 1;

// Zig 0.16 removed `std.fs.cwd()` in favour of `std.Io.Dir.cwd()`, which
// requires an `Io` parameter threaded through the call site. This is
// the legacy path-based texture loader — production texture loading
// goes through `decodeImage` + `uploadTexture` on caller-provided
// bytes and never touches the FS directly. Rather than thread `Io`
// through the backend for a one-shot loader, we use libc `fopen` /
// `fread` / `fclose` to keep the existing `(path) !Texture` signature.
// The `link_libc = true` flag on the gfx module (see
// backends/wgpu/build.zig) pulls libc in.
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
    const file_buf = allocator.alloc(u8, file_size) catch return error.LoadFailed;
    defer allocator.free(file_buf);

    const bytes_read = std.c.fread(file_buf.ptr, 1, file_size, file);
    if (bytes_read != file_size) return error.LoadFailed;

    const decoded = try decodeImage("", file_buf[0..bytes_read], allocator);
    defer allocator.free(decoded.pixels);
    return uploadTexture(decoded);
}

/// Pure CPU decode, safe from a worker thread. wgpu's backend ships
/// hand-rolled BMP, TGA and PNG decoders (no stb_image link). We sniff
/// the signature and dispatch: PNG first (it has an unambiguous 8-byte
/// magic), then BMP, then TGA (which has no magic, so it's the
/// last-resort fallback). The caller's allocator owns the returned
/// `pixels` buffer and frees it on both the success and the discard
/// paths.
pub fn decodeImage(
    _: [:0]const u8,
    data: []const u8,
    allocator: std.mem.Allocator,
) !DecodedImage {
    if (decodePng(data, allocator)) |img| return img;
    if (decodeBmp(data, allocator)) |img| return img;
    if (decodeTga(data, allocator)) |img| return img;
    return error.LoadFailed;
}

/// Main/GL-thread GPU upload. This wgpu backend currently retains its
/// decoded pixels in the texture slot (drawTexturePro uploads them
/// lazily via `wgpuQueueWriteTexture` — or a stub path, depending on
/// renderer state), so we COPY `decoded.pixels` into a fresh
/// page_allocator buffer that the slot owns. We do NOT free
/// `decoded.pixels` — the caller owns that buffer on both the success
/// and the discard paths.
pub fn uploadTexture(decoded: DecodedImage) !Texture {
    const id = next_texture_id;
    if (id >= MAX_TEXTURES) return error.LoadFailed;
    if (decoded.width == 0 or decoded.height == 0) return error.LoadFailed;

    const owned = std.heap.page_allocator.alloc(u8, decoded.pixels.len) catch return error.LoadFailed;
    @memcpy(owned, decoded.pixels);

    const w: i32 = @intCast(decoded.width);
    const h: i32 = @intCast(decoded.height);
    textures[id] = .{ .pixels = owned, .width = w, .height = h, .active = true };
    next_texture_id += 1;
    return Texture{ .id = id, .width = w, .height = h };
}

pub fn unloadTexture(texture: Texture) void {
    if (texture.id >= MAX_TEXTURES) return;
    const slot = &textures[texture.id];
    if (slot.pixels) |px| {
        std.heap.page_allocator.free(px);
    }
    slot.* = .{};
}

/// CPU-side description of a loaded texture's pixel data, used by the GPU
/// submitter (window.zig) to lazily create + upload a wgpu texture the
/// first time the texture id is drawn. The `pixels` slice is borrowed
/// (owned by the texture slot) and stays valid until `unloadTexture`.
pub const TexturePixels = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
};

/// Look up the RGBA8 pixel buffer for a texture id. Returns null for an
/// unknown / inactive id, OR for a GPU-compressed (ASTC) slot — those are
/// fetched via `getCompressedTexture` instead, so a compressed id never
/// reaches the RGBA8 upload path. The returned slice is borrowed (see above).
pub fn getTexturePixels(id: u32) ?TexturePixels {
    if (id == 0 or id >= MAX_TEXTURES) return null;
    const slot = &textures[id];
    if (!slot.active) return null;
    if (slot.compressed != null) return null; // compressed slots: see getCompressedTexture
    const px = slot.pixels orelse return null;
    return .{
        .pixels = px,
        .width = @intCast(slot.width),
        .height = @intCast(slot.height),
    };
}

// ── GPU-compressed textures (ASTC) ──────────────────────────────────────────
// The engine's `loadTextureFromMemory` seam (labelle-gfx) dispatches here when
// this backend exposes `isCompressed`/`uploadCompressed` and the blob is
// compressed, skipping the CPU PNG/BMP/TGA decode entirely (labelle-gfx#269 /
// #341). Unlike the bgfx backend — where `uploadCompressed` creates the GPU
// texture inline — this wgpu backend decouples CPU load from GPU upload (gfx
// loads bytes on a worker thread before the device may be ready). So
// `uploadCompressed` runs CPU-side: it validates + RETAINS the compressed
// block payload in a texture slot, and `window.zig`'s `getOrCreateGpuTexture`
// lazily creates the ASTC wgpu texture from it on the main thread (via
// `getCompressedTexture`), mirroring the RGBA8 lazy-upload path.

/// Block dimensions of a validated 2D ASTC blob, plus its (owned-by-caller)
/// compressed block payload. `block_x`/`block_y` map to the wgpu ASTC
/// `TextureFormat` in the submitter; `validateAstc` rejects anything we can't
/// hand straight to the GPU so the `isCompressed` probe and the actual upload
/// never disagree.
const AstcUpload = struct {
    block_x: u8,
    block_y: u8,
    width: u32,
    height: u32,
    blocks: []const u8,
};

/// True if `block_x`×`block_y` is one of the ASTC LDR block sizes the wgpu
/// `TextureFormat` enum exposes (the full 4x4…12x12 set). The submitter does
/// the actual enum mapping; we only need a yes/no here so the upload probe and
/// the upload agree on which blobs are acceptable.
fn astcBlockSupported(block_x: u8, block_y: u8) bool {
    return switch ((@as(u16, block_x) << 8) | block_y) {
        0x0404, 0x0504, 0x0505, 0x0605, 0x0606, 0x0805, 0x0806, 0x0808,
        0x0a05, 0x0a06, 0x0a08, 0x0a0a, 0x0c0a, 0x0c0c => true,
        else => false,
    };
}

/// Validate an ASTC blob for a 2D wgpu upload, or null if we can't take it
/// as-is: not ASTC, malformed/truncated, 3D (`depth`/`block_z != 1`), or an
/// unsupported block size. `isCompressed`/`uploadCompressed` share this so the
/// "can upload as-is" probe and the actual upload never disagree.
fn validateAstc(data: []const u8) ?AstcUpload {
    const hdr = astc.parse(data) orelse return null;
    if (hdr.depth != 1 or hdr.block_z != 1) return null; // 2D textures only
    if (!astcBlockSupported(hdr.block_x, hdr.block_y)) return null;
    return .{
        .block_x = hdr.block_x,
        .block_y = hdr.block_y,
        .width = hdr.width,
        .height = hdr.height,
        .blocks = hdr.blocks,
    };
}

/// True if `data` is a GPU-compressed blob this backend can upload as-is.
/// Consumed by labelle-gfx's `loadTextureFromMemory` seam via `@hasDecl`.
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

/// Retain a validated ASTC blob for a (later, main-thread) GPU upload — no CPU
/// decode. Runs on the gfx worker thread, so it does NOT touch the GPU: it
/// copies the compressed block payload into a slot-owned buffer and records the
/// block size; `window.zig` creates the ASTC wgpu texture lazily on first draw
/// (see `getCompressedTexture`). Mirrors `uploadTexture`'s slot ownership.
pub fn uploadCompressed(data: []const u8) !Texture {
    const info = validateAstc(data) orelse return error.LoadFailed;
    const id = next_texture_id;
    if (id >= MAX_TEXTURES) return error.LoadFailed;
    if (info.width == 0 or info.height == 0) return error.LoadFailed;

    const owned = std.heap.page_allocator.alloc(u8, info.blocks.len) catch return error.LoadFailed;
    @memcpy(owned, info.blocks);

    const w: i32 = @intCast(info.width);
    const h: i32 = @intCast(info.height);
    textures[id] = .{
        .pixels = owned,
        .width = w,
        .height = h,
        .active = true,
        .compressed = .{ .block_x = info.block_x, .block_y = info.block_y },
    };
    next_texture_id += 1;
    return Texture{ .id = id, .width = w, .height = h };
}

/// CPU-side description of a loaded GPU-compressed (ASTC) texture, used by the
/// window submitter to lazily create + upload the ASTC wgpu texture the first
/// time the id is drawn. `blocks` is borrowed (owned by the slot, valid until
/// `unloadTexture`); `block_x`/`block_y` select the wgpu ASTC `TextureFormat`
/// and the compressed `bytes_per_row` / `rows_per_image`.
pub const CompressedTexture = struct {
    blocks: []const u8,
    width: u32,
    height: u32,
    block_x: u8,
    block_y: u8,
};

/// Look up the compressed (ASTC) blob for a texture id, or null for an
/// unknown / inactive / non-compressed id. The returned slice is borrowed.
pub fn getCompressedTexture(id: u32) ?CompressedTexture {
    if (id == 0 or id >= MAX_TEXTURES) return null;
    const slot = &textures[id];
    if (!slot.active) return null;
    const c = slot.compressed orelse return null;
    const blocks = slot.pixels orelse return null;
    return .{
        .blocks = blocks,
        .width = @intCast(slot.width),
        .height = @intCast(slot.height),
        .block_x = c.block_x,
        .block_y = c.block_y,
    };
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
pub fn decodeBmp(data: []const u8, allocator: std.mem.Allocator) ?DecodedImage {
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
    // Widen to usize before multiplying: a large `width` from an untrusted
    // header would overflow the u32 product to 0, yielding row_size 0 and a
    // corrupted decode (every row re-reads the same offset).
    const row_size = ((@as(usize, width) * @as(usize, bytes_per_pixel) + 3) / 4) * 4; // BMP rows are 4-byte aligned

    // `width`/`height` come straight from untrusted BMP headers, so the
    // size arithmetic uses checked ops — an overflowed product would
    // otherwise under-allocate `pixels` and let the copy loop write OOB.
    const out_size = std.math.mul(usize, std.math.mul(usize, width, height) catch return null, 4) catch return null;
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
pub fn decodeTga(data: []const u8, allocator: std.mem.Allocator) ?DecodedImage {
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

    // `width`/`height` come straight from untrusted TGA headers, so the
    // size arithmetic uses checked ops — an overflowed product would
    // otherwise under-allocate `pixels` and let the copy loop write OOB.
    const out_size = std.math.mul(usize, std.math.mul(usize, width, height) catch return null, 4) catch return null;
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

/// Decode a non-interlaced, 8-bit PNG to RGBA8.
///
/// Supported subset (returns `null` for anything outside it):
///   • Bit depth: 8 only (1/2/4/16 rejected).
///   • Interlace: 0 (none) only — Adam7 interlacing is rejected.
///   • Color types:
///       0  grayscale            → gray replicated to RGB, A = 255
///       2  truecolor (RGB)      → RGB, A = 255
///       3  indexed (palette)    → PLTE lookup, optional tRNS for alpha
///       4  grayscale+alpha      → gray replicated to RGB, A from sample
///       6  truecolor+alpha      → RGBA passthrough
///
/// PNG pipeline: validate the 8-byte signature, walk IHDR/PLTE/tRNS/IDAT/
/// IEND chunks, concatenate all IDAT data, zlib-inflate it (std
/// `compress.flate` — no DEFLATE is hand-rolled), then unfilter the
/// scanlines (filter types 0–4: None/Sub/Up/Average/Paeth) and expand
/// each pixel to RGBA8. Chunk CRCs are not verified (we trust the
/// inflate + structural checks). The caller's allocator owns the
/// returned `pixels`.
pub fn decodePng(data: []const u8, allocator: std.mem.Allocator) ?DecodedImage {
    const sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    if (data.len < sig.len or !std.mem.eql(u8, data[0..sig.len], &sig)) return null;

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var interlace: u8 = 0;
    var seen_ihdr = false;

    // Palette (color type 3): up to 256 RGB entries + optional per-index alpha.
    var palette: [256][3]u8 = undefined;
    var palette_alpha: [256]u8 = [_]u8{255} ** 256;
    var palette_len: usize = 0;

    // Concatenated IDAT payload (the zlib stream). Owned here, freed below.
    var idat: std.ArrayListUnmanaged(u8) = .empty;
    defer idat.deinit(allocator);

    // Walk chunks: 4-byte length, 4-byte type, length bytes data, 4-byte CRC.
    var pos: usize = sig.len;
    var saw_iend = false;
    while (data.len - pos >= 8) {
        const chunk_len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const ctype = data[pos + 4 ..][0..4];
        const body_start = pos + 8;
        // Bounds via subtraction so a malformed `chunk_len` (e.g.
        // 0xFFFFFFFF) can't overflow `usize` and bypass the check. We
        // need `chunk_len` body bytes plus a 4-byte trailing CRC.
        if (data.len - body_start < chunk_len) return null; // truncated body
        if (data.len - body_start - chunk_len < 4) return null; // missing CRC
        const body_end = body_start + chunk_len;
        const body = data[body_start..body_end];

        if (std.mem.eql(u8, ctype, "IHDR")) {
            if (chunk_len != 13) return null;
            width = std.mem.readInt(u32, body[0..4], .big);
            height = std.mem.readInt(u32, body[4..8], .big);
            bit_depth = body[8];
            color_type = body[9];
            // body[10] = compression (only 0 defined), body[11] = filter
            // method (only 0 defined), body[12] = interlace.
            interlace = body[12];
            seen_ihdr = true;
        } else if (std.mem.eql(u8, ctype, "PLTE")) {
            if (chunk_len % 3 != 0) return null;
            palette_len = chunk_len / 3;
            if (palette_len > 256) return null;
            var i: usize = 0;
            while (i < palette_len) : (i += 1) {
                palette[i] = .{ body[i * 3 + 0], body[i * 3 + 1], body[i * 3 + 2] };
            }
        } else if (std.mem.eql(u8, ctype, "tRNS")) {
            // For indexed images, tRNS is a list of per-index alpha values.
            // (We only support tRNS for color type 3; other types fall back
            // to opaque alpha, which is a documented limitation.)
            if (color_type == 3) {
                const n = @min(chunk_len, palette_alpha.len);
                var i: usize = 0;
                while (i < n) : (i += 1) palette_alpha[i] = body[i];
            }
        } else if (std.mem.eql(u8, ctype, "IDAT")) {
            idat.appendSlice(allocator, body) catch return null;
        } else if (std.mem.eql(u8, ctype, "IEND")) {
            saw_iend = true;
            break;
        }

        pos = body_end + 4; // skip CRC
    }

    if (!seen_ihdr or !saw_iend) return null;
    if (width == 0 or height == 0) return null;
    if (interlace != 0) return null; // Adam7 not supported
    if (bit_depth != 8) return null; // only 8-bit samples supported
    if (color_type == 3 and palette_len == 0) return null;

    // Samples (bytes) per pixel in the raw (filtered) scanline.
    const channels: usize = switch (color_type) {
        0 => 1, // grayscale
        2 => 3, // truecolor
        3 => 1, // indexed (1 byte = palette index)
        4 => 2, // grayscale + alpha
        6 => 4, // truecolor + alpha
        else => return null,
    };

    // Inflate the concatenated IDAT zlib stream. Each scanline is
    // prefixed by a 1-byte filter type, so raw size = h * (1 + w*channels).
    // `width`/`height` come straight from untrusted IHDR, so the size
    // arithmetic uses checked ops — an overflowed product would otherwise
    // under-allocate `raw` and let the unfilter loop write out of bounds.
    const stride = std.math.mul(usize, width, channels) catch return null; // bytes per row, no filter byte
    const row_len = std.math.add(usize, stride, 1) catch return null; // + filter byte
    const raw_size = std.math.mul(usize, height, row_len) catch return null;

    const raw = allocator.alloc(u8, raw_size) catch return null;
    defer allocator.free(raw);

    {
        var in_reader = std.Io.Reader.fixed(idat.items);
        var out_writer = std.Io.Writer.fixed(raw);
        // Empty window buffer = "direct" mode; flate reads straight from the
        // fixed input. `.zlib` container handles the 2-byte zlib header +
        // Adler-32 footer that wraps PNG's DEFLATE stream.
        var decompress = std.compress.flate.Decompress.init(&in_reader, .zlib, &.{});
        const n = decompress.reader.streamRemaining(&out_writer) catch return null;
        if (n != raw_size) return null; // wrong amount of data
    }

    // Output RGBA8 buffer. Checked arithmetic for the same untrusted-dims
    // overflow reason as `raw_size` above. (No `errdefer` here: this
    // function returns `?DecodedImage`, not an error union, so an errdefer
    // would never fire — the failure paths below free `pixels` manually.)
    const out_size = std.math.mul(usize, std.math.mul(usize, width, height) catch return null, 4) catch return null;
    const pixels = allocator.alloc(u8, out_size) catch return null;

    // Unfilter scanlines in place within `raw` (we overwrite the filtered
    // bytes with reconstructed ones, row by row, top to bottom).
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row_off = y * (1 + stride);
        const filter = raw[row_off];
        const cur = raw[row_off + 1 ..][0..stride];
        const prev: ?[]const u8 = if (y == 0)
            null
        else
            raw[(y - 1) * (1 + stride) + 1 ..][0..stride];

        var i: usize = 0;
        while (i < stride) : (i += 1) {
            const a: i32 = if (i >= channels) cur[i - channels] else 0; // left
            const b: i32 = if (prev) |p| p[i] else 0; // up
            const c: i32 = if (prev != null and i >= channels) prev.?[i - channels] else 0; // up-left
            const x: i32 = cur[i];
            const recon: i32 = switch (filter) {
                0 => x, // None
                1 => x + a, // Sub
                2 => x + b, // Up
                3 => x + @divFloor(a + b, 2), // Average
                4 => x + paeth(a, b, c), // Paeth
                else => {
                    allocator.free(pixels);
                    return null;
                },
            };
            cur[i] = @truncate(@as(u32, @bitCast(recon)));
        }

        // Expand this reconstructed scanline to RGBA8.
        var px: usize = 0;
        while (px < width) : (px += 1) {
            const dst = (y * @as(usize, width) + px) * 4;
            switch (color_type) {
                0 => { // grayscale
                    const g = cur[px];
                    pixels[dst + 0] = g;
                    pixels[dst + 1] = g;
                    pixels[dst + 2] = g;
                    pixels[dst + 3] = 255;
                },
                2 => { // truecolor RGB
                    const s = px * 3;
                    pixels[dst + 0] = cur[s + 0];
                    pixels[dst + 1] = cur[s + 1];
                    pixels[dst + 2] = cur[s + 2];
                    pixels[dst + 3] = 255;
                },
                3 => { // indexed
                    const idx = cur[px];
                    if (idx >= palette_len) {
                        allocator.free(pixels);
                        return null;
                    }
                    pixels[dst + 0] = palette[idx][0];
                    pixels[dst + 1] = palette[idx][1];
                    pixels[dst + 2] = palette[idx][2];
                    pixels[dst + 3] = palette_alpha[idx];
                },
                4 => { // grayscale + alpha
                    const s = px * 2;
                    const g = cur[s + 0];
                    pixels[dst + 0] = g;
                    pixels[dst + 1] = g;
                    pixels[dst + 2] = g;
                    pixels[dst + 3] = cur[s + 1];
                },
                6 => { // truecolor + alpha
                    const s = px * 4;
                    pixels[dst + 0] = cur[s + 0];
                    pixels[dst + 1] = cur[s + 1];
                    pixels[dst + 2] = cur[s + 2];
                    pixels[dst + 3] = cur[s + 3];
                },
                else => unreachable,
            }
        }
    }

    return DecodedImage{ .pixels = pixels, .width = width, .height = height };
}

/// PNG Paeth predictor (filter type 4). Operates on i32 to avoid the
/// wraparound that the spec's byte arithmetic would otherwise mask.
fn paeth(a: i32, b: i32, c: i32) i32 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

// ── ASTC seam tests (pure CPU; no wgpu) ─────────────────────────────────────
// Exercise the `isCompressed` / `uploadCompressed` / `getCompressedTexture`
// contract the labelle-gfx seam + window submitter rely on. The astc.zig
// parser has its own tests; these cover the wgpu-side validation + slot
// retention. They share the global slot table, so each grabs the id it just
// minted and unloads it to keep the pool clean for sibling tests.

fn makeAstc(buf: *[16 + 1024]u8, bx: u8, by: u8) void {
    // 64x64 @ 8x8 = 8*8 blocks * 16 bytes = 1024 block bytes (fits the buf).
    @memcpy(buf[0..4], &astc.MAGIC);
    buf[4] = bx;
    buf[5] = by;
    buf[6] = 1;
    std.mem.writeInt(u24, buf[7..10], 64, .little);
    std.mem.writeInt(u24, buf[10..13], 64, .little);
    std.mem.writeInt(u24, buf[13..16], 1, .little);
    @memset(buf[16..], 0xAB);
}

test "isCompressed: true for a supported ASTC blob, false otherwise" {
    var buf: [16 + 1024]u8 = undefined;
    makeAstc(&buf, 8, 8);
    try std.testing.expect(isCompressed(&buf));
    // A real PNG is NOT compressed-as-is (it routes through the CPU decoder).
    const not_astc = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expect(!isCompressed(&not_astc));
}

test "uploadCompressed: retains blocks + block size, readable via getCompressedTexture" {
    var buf: [16 + 1024]u8 = undefined;
    makeAstc(&buf, 8, 8);
    const tex = try uploadCompressed(&buf);
    defer unloadTexture(tex);

    try std.testing.expectEqual(@as(i32, 64), tex.width);
    try std.testing.expectEqual(@as(i32, 64), tex.height);

    const c = getCompressedTexture(tex.id) orelse return error.TestUnexpected;
    try std.testing.expectEqual(@as(u8, 8), c.block_x);
    try std.testing.expectEqual(@as(u8, 8), c.block_y);
    try std.testing.expectEqual(@as(u32, 64), c.width);
    try std.testing.expectEqual(@as(usize, 1024), c.blocks.len);
    try std.testing.expectEqual(@as(u8, 0xAB), c.blocks[0]);

    // A compressed slot must NOT surface through the RGBA8 path (or the
    // submitter would try to upload ASTC blocks as rgba8_unorm).
    try std.testing.expect(getTexturePixels(tex.id) == null);
}

test "uploadCompressed: rejects an unsupported block size" {
    var buf: [16 + 1024]u8 = undefined;
    makeAstc(&buf, 7, 7); // 7x7 is not an ASTC LDR block size
    try std.testing.expect(!isCompressed(&buf));
    try std.testing.expectError(error.LoadFailed, uploadCompressed(&buf));
}
