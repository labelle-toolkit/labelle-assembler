//! Windows `.ico` writer for the generated desktop exe (labelle-cli#359).
//!
//! The assembler already owns the app icon at generate time (`app_icon.zig`:
//! the project's `app_icon` PNG, or the bundled default). On Windows the exe's
//! icon — Explorer, taskbar, alt-tab — comes from an `ICON` resource compiled
//! into the binary, and that resource wants an `.ico`. So `generate` writes
//! `<target>/app_icon.ico` (+ the one-line `app_icon.rc` that names it) and
//! the generated `build.zig` adds the `.rc` on Windows targets only.
//!
//! ## Format choice: PNG-compressed entries
//!
//! An ICO is a tiny directory (`ICONDIR` + one `ICONDIRENTRY` per image)
//! followed by the image payloads. Since Windows Vista each payload may be a
//! complete PNG file instead of a DIB — that is how every 256×256 entry is
//! shipped, and every size works the same way. We use PNG payloads for ALL
//! entries: no DIB/AND-mask packing to get wrong, and the PNG encoder here is
//! ~40 lines over `std.compress.flate`. Windows XP is the only OS that cannot
//! read them, and it cannot run a Zig 0.16 binary either.
//!
//! ## Sizes: 256 / 48 / 32 / 16
//!
//! The set Explorer actually consults (extra-large, large, small, and the
//! title-bar/taskbar 16). Each is a proper area-averaged downscale of the
//! source; Windows would otherwise nearest-scale the one image it had. A
//! source smaller than 256 also contributes itself as the largest entry, and
//! nothing is ever upscaled. The `ICONDIRENTRY` width/height bytes hold the
//! size, with `0` meaning 256 (the byte cannot hold 256).
//!
//! ## Decoder scope + fallback
//!
//! The assembler has no stb_image (the CLI and the backends do), so the
//! decode is a small pure-Zig PNG reader: 8-bit (and 16-bit, high byte) in
//! every colour type (grey, RGB, palette + tRNS, grey+alpha, RGBA),
//! NON-interlaced. That covers what any icon tool emits. A PNG it cannot
//! decode (Adam7 interlace, a corrupt stream) still yields a VALID `.ico`:
//! a single entry whose payload is the source PNG verbatim — Windows reads
//! its dimensions from the PNG itself — so a generate does not fail over an
//! exotic icon. That fallback needs the DIRECTORY to stay truthful, though,
//! and an `ICONDIRENTRY` holds one byte per axis (0 = 256): an undecodable
//! image that is non-square or larger than 256 cannot be described and is
//! `error.IcoFallbackUnrepresentable` rather than a lying entry. Bytes that
//! are not a PNG at all are `error.NotPng`.

const std = @import("std");
const flate = std.compress.flate;

const png_magic = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

/// The entry sizes an `.ico` built here carries (largest first), when the
/// source is at least that big. See the module doc for why these four.
pub const ico_sizes = [_]u32{ 256, 48, 32, 16 };

/// Hard cap on a decoded icon: 4096² RGBA is 64 MiB, far beyond any icon
/// and enough to keep a hostile IHDR from asking for gigabytes.
pub const max_icon_edge: u32 = 4096;

// ── PNG reading ────────────────────────────────────────────────────────

pub const PngDims = struct { width: u32, height: u32 };

/// Width/height from the IHDR — the mandatory first chunk — or null when the
/// bytes are not a PNG. Cheap: no decode.
pub fn pngDimensions(png: []const u8) ?PngDims {
    if (png.len < 33) return null;
    if (!std.mem.eql(u8, png[0..8], &png_magic)) return null;
    if (!std.mem.eql(u8, png[12..16], "IHDR")) return null;
    const w = std.mem.readInt(u32, png[16..20], .big);
    const h = std.mem.readInt(u32, png[20..24], .big);
    if (w == 0 or h == 0) return null;
    return .{ .width = w, .height = h };
}

/// Tightly packed RGBA8, `pixels.len == width * height * 4`, owned by the
/// caller's allocator.
pub const Rgba = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: Rgba, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const DecodeError = error{
    /// Not a PNG at all (bad magic / no IHDR).
    NotPng,
    /// A PNG this reader deliberately does not handle: Adam7 interlace, or
    /// a bit depth / colour type outside the spec's table.
    Unsupported,
    /// Structurally broken: bad chunk layout, short stream, bad filter byte.
    Malformed,
    /// Dimensions above `max_icon_edge`.
    TooLarge,
    OutOfMemory,
};

const ColorType = enum(u8) {
    grey = 0,
    rgb = 2,
    palette = 3,
    grey_alpha = 4,
    rgba = 6,

    fn channels(self: ColorType) u8 {
        return switch (self) {
            .grey, .palette => 1,
            .grey_alpha => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }
};

/// Decode a non-interlaced 8/16-bit PNG of any colour type to RGBA8.
pub fn decodePng(allocator: std.mem.Allocator, png: []const u8) DecodeError!Rgba {
    const dims = pngDimensions(png) orelse return error.NotPng;
    if (dims.width > max_icon_edge or dims.height > max_icon_edge) return error.TooLarge;
    const bit_depth = png[24];
    const color_type = std.enums.fromInt(ColorType, png[25]) orelse return error.Unsupported;
    const interlace = png[28];
    if (interlace != 0) return error.Unsupported;
    // Sub-byte grey/palette depths are legal PNG but no icon tool emits them.
    if (bit_depth != 8 and bit_depth != 16) return error.Unsupported;
    if (bit_depth == 16 and color_type == .palette) return error.Unsupported;

    // Walk the chunks: concatenate IDAT, remember PLTE/tRNS.
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);
    var plte: ?[]const u8 = null;
    var trns: ?[]const u8 = null;
    var pos: usize = 8;
    var saw_iend = false;
    while (pos + 12 <= png.len) {
        const len: usize = std.mem.readInt(u32, png[pos..][0..4], .big);
        const kind = png[pos + 4 ..][0..4];
        const data_start = pos + 8;
        const data_end = std.math.add(usize, data_start, len) catch return error.Malformed;
        if (data_end + 4 > png.len) return error.Malformed;
        const data = png[data_start..data_end];
        if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(allocator, data);
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            plte = data;
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            trns = data;
        } else if (std.mem.eql(u8, kind, "IEND")) {
            saw_iend = true;
            break;
        }
        pos = data_end + 4; // skip CRC
    }
    if (!saw_iend or idat.items.len == 0) return error.Malformed;
    if (color_type == .palette and plte == null) return error.Malformed;

    // Inflate the zlib stream into the raw filtered scanlines.
    const w: usize = dims.width;
    const h: usize = dims.height;
    const bytes_per_sample: usize = bit_depth / 8;
    const bpp: usize = @as(usize, color_type.channels()) * bytes_per_sample;
    const stride = w * bpp;
    const raw_len = (stride + 1) * h;

    var in: std.Io.Reader = .fixed(idat.items);
    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);
    var inflate: flate.Decompress = .init(&in, .zlib, window);
    // Exactly `raw_len` bytes are expected; a short stream is malformed. Any
    // trailing bytes past that are ignored (a lenient reader, like libpng).
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    inflate.reader.readSliceAll(raw) catch return error.Malformed;

    // Unfilter in place, row by row (each row's first byte is its filter).
    var prev_row: ?[]u8 = null;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        const row_start = y * (stride + 1);
        const filter = raw[row_start];
        const row = raw[row_start + 1 .. row_start + 1 + stride];
        try unfilterRow(filter, row, prev_row, bpp);
        prev_row = row;
    }

    // Expand to RGBA8. `trns_hi` indexes the byte of each big-endian tRNS
    // sample that matches our 8-bit value: the low byte at 8-bit depth, the
    // high byte at 16-bit (where we keep only the high byte of every sample).
    const trns_hi: usize = if (bit_depth == 8) 1 else 0;
    const out = try allocator.alloc(u8, w * h * 4);
    errdefer allocator.free(out);
    y = 0;
    while (y < h) : (y += 1) {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const src = row[x * bpp ..][0..bpp];
            const dst = out[(y * w + x) * 4 ..][0..4];
            // 16-bit: the high byte of each sample is the 8-bit value.
            const s = struct {
                fn at(buf: []const u8, i: usize, bps: usize) u8 {
                    return buf[i * bps];
                }
            };
            switch (color_type) {
                .grey => {
                    const g = s.at(src, 0, bytes_per_sample);
                    dst.* = .{ g, g, g, 255 };
                    // tRNS for greyscale: one big-endian 16-bit sample naming the
                    // transparent grey level (low byte at 8-bit, high at 16-bit).
                    if (trns) |t| if (t.len >= 2 and t[trns_hi] == g) {
                        dst[3] = 0;
                    };
                },
                .grey_alpha => {
                    const g = s.at(src, 0, bytes_per_sample);
                    dst.* = .{ g, g, g, s.at(src, 1, bytes_per_sample) };
                },
                .rgb => {
                    dst.* = .{ s.at(src, 0, bytes_per_sample), s.at(src, 1, bytes_per_sample), s.at(src, 2, bytes_per_sample), 255 };
                    // tRNS for RGB: three big-endian 16-bit samples — one colour key.
                    if (trns) |t| if (t.len >= 6) {
                        if (dst[0] == t[trns_hi] and dst[1] == t[2 + trns_hi] and dst[2] == t[4 + trns_hi]) dst[3] = 0;
                    };
                },
                .rgba => {
                    dst.* = .{ s.at(src, 0, bytes_per_sample), s.at(src, 1, bytes_per_sample), s.at(src, 2, bytes_per_sample), s.at(src, 3, bytes_per_sample) };
                },
                .palette => {
                    const idx: usize = src[0];
                    const p = plte.?;
                    if (idx * 3 + 2 >= p.len) return error.Malformed;
                    dst.* = .{ p[idx * 3], p[idx * 3 + 1], p[idx * 3 + 2], 255 };
                    if (trns) |t| if (idx < t.len) {
                        dst[3] = t[idx];
                    };
                },
            }
        }
    }
    return .{ .width = dims.width, .height = dims.height, .pixels = out };
}

/// Reverse one scanline's PNG filter in place. `prev` is the already
/// unfiltered row above (null on the first row, which the spec treats as
/// all-zero).
fn unfilterRow(filter: u8, row: []u8, prev: ?[]u8, bpp: usize) DecodeError!void {
    switch (filter) {
        0 => {},
        1 => { // Sub
            var i: usize = bpp;
            while (i < row.len) : (i += 1) row[i] +%= row[i - bpp];
        },
        2 => { // Up
            if (prev) |p| for (row, p) |*b, u| {
                b.* +%= u;
            };
        },
        3 => { // Average
            var i: usize = 0;
            while (i < row.len) : (i += 1) {
                const left: u16 = if (i >= bpp) row[i - bpp] else 0;
                const up: u16 = if (prev) |p| p[i] else 0;
                row[i] +%= @intCast((left + up) / 2);
            }
        },
        4 => { // Paeth
            var i: usize = 0;
            while (i < row.len) : (i += 1) {
                const a: i16 = if (i >= bpp) row[i - bpp] else 0;
                const b: i16 = if (prev) |p| p[i] else 0;
                const c: i16 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
                const p = a + b - c;
                const pa = @abs(p - a);
                const pb = @abs(p - b);
                const pc = @abs(p - c);
                const pred: i16 = if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
                row[i] +%= @intCast(pred);
            }
        },
        else => return error.Malformed,
    }
}

// ── PNG writing ────────────────────────────────────────────────────────

fn writeChunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(data.len), .big);
    try w.writeAll(&len_buf);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_buf, crc.final(), .big);
    try w.writeAll(&crc_buf);
}

/// Encode 8-bit samples of the given colour type as a non-interlaced PNG:
/// filter 0 on every row, zlib-deflated with `flate.Compress`. `samples` is
/// `w * h * channels(color_type)` bytes. Exposed so tests can produce
/// grey/RGB/palette inputs for the decoder; `encodePng` is the RGBA front.
pub fn encodePngRaw(
    allocator: std.mem.Allocator,
    samples: []const u8,
    w: u32,
    h: u32,
    color_type: u8,
    plte: ?[]const u8,
) ![]u8 {
    const ct = std.enums.fromInt(ColorType, color_type) orelse return error.Unsupported;
    const ch: usize = ct.channels();
    const stride = @as(usize, w) * ch;
    if (samples.len != stride * h) return error.InvalidDimensions;

    // Filtered scanlines: a 0 filter byte in front of each row.
    const raw = try allocator.alloc(u8, (stride + 1) * h);
    defer allocator.free(raw);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        raw[y * (stride + 1)] = 0;
        @memcpy(raw[y * (stride + 1) + 1 ..][0..stride], samples[y * stride ..][0..stride]);
    }

    // zlib-deflate the scanlines.
    var zout: std.Io.Writer.Allocating = try .initCapacity(allocator, 4096);
    defer zout.deinit();
    {
        const window = try allocator.alloc(u8, flate.max_window_len);
        defer allocator.free(window);
        var comp: flate.Compress = try .init(&zout.writer, window, .zlib, .default);
        try comp.writer.writeAll(raw);
        try comp.finish();
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const wr = &out.writer;
    try wr.writeAll(&png_magic);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = color_type;
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter method
    ihdr[12] = 0; // no interlace
    try writeChunk(wr, "IHDR", &ihdr);
    if (plte) |p| try writeChunk(wr, "PLTE", p);
    try writeChunk(wr, "IDAT", zout.written());
    try writeChunk(wr, "IEND", "");
    return out.toOwnedSlice();
}

/// Encode tightly packed RGBA8 as a PNG. Caller owns the bytes.
pub fn encodePng(allocator: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    return encodePngRaw(allocator, rgba, w, h, @intFromEnum(ColorType.rgba), null);
}

// ── Resampling ─────────────────────────────────────────────────────────

/// Round a non-negative channel value to the nearest `u8`, clamped.
fn quantizeChannel(v: f64) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0.0, 255.0)));
}

/// Area-average ("box") downscale of RGBA8, in PREMULTIPLIED alpha.
///
/// Each destination pixel covers the real-valued source footprint
/// `[dx·sw/dw, (dx+1)·sw/dw)` and weights every source pixel by its
/// FRACTIONAL overlap with it, so a non-integer ratio (e.g. the 256→48 an
/// icon build performs) blends instead of snapping edges to whole pixels;
/// integer ratios still give the exact block mean. RGB is accumulated
/// weighted by its own alpha and un-premultiplied at the end, so the
/// invisible colour of transparent pixels cannot halo the art; a fully
/// transparent destination pixel keeps the plain RGB average, having no
/// colour to recover. Downscale only.
///
/// Mirrors labelle-bgfx `window_icon.downscaleBox` — the two produce the
/// runtime window icon and the Windows exe icon from the same source, and
/// must not disagree.
pub fn downscaleBox(allocator: std.mem.Allocator, src: []const u8, sw: u32, sh: u32, dw: u32, dh: u32) ![]u8 {
    if (sw == 0 or sh == 0 or dw == 0 or dh == 0) return error.InvalidDimensions;
    if (dw > sw or dh > sh) return error.InvalidDimensions;
    if (src.len < @as(usize, sw) * sh * 4) return error.InvalidDimensions;
    const out = try allocator.alloc(u8, @as(usize, dw) * dh * 4);
    errdefer allocator.free(out);

    const x_step = @as(f64, @floatFromInt(sw)) / @as(f64, @floatFromInt(dw));
    const y_step = @as(f64, @floatFromInt(sh)) / @as(f64, @floatFromInt(dh));

    var dy: u32 = 0;
    while (dy < dh) : (dy += 1) {
        const y_lo = @as(f64, @floatFromInt(dy)) * y_step;
        const y_hi = y_lo + y_step;
        const y0: u32 = @intFromFloat(@floor(y_lo));
        const y1: u32 = @min(sh, @as(u32, @intFromFloat(@ceil(y_hi))));
        var dx: u32 = 0;
        while (dx < dw) : (dx += 1) {
            const x_lo = @as(f64, @floatFromInt(dx)) * x_step;
            const x_hi = x_lo + x_step;
            const x0: u32 = @intFromFloat(@floor(x_lo));
            const x1: u32 = @min(sw, @as(u32, @intFromFloat(@ceil(x_hi))));

            var acc_pre = [3]f64{ 0, 0, 0 };
            var acc_flat = [3]f64{ 0, 0, 0 };
            var acc_a: f64 = 0;
            var acc_w: f64 = 0;
            var sy = y0;
            while (sy < y1) : (sy += 1) {
                const wy = @min(y_hi, @as(f64, @floatFromInt(sy + 1))) -
                    @max(y_lo, @as(f64, @floatFromInt(sy)));
                if (wy <= 0) continue;
                var sx = x0;
                while (sx < x1) : (sx += 1) {
                    const wx = @min(x_hi, @as(f64, @floatFromInt(sx + 1))) -
                        @max(x_lo, @as(f64, @floatFromInt(sx)));
                    if (wx <= 0) continue;
                    const w = wx * wy;
                    const i = (@as(usize, sy) * sw + sx) * 4;
                    const a = @as(f64, @floatFromInt(src[i + 3]));
                    acc_w += w;
                    acc_a += a * w;
                    inline for (0..3) |c| {
                        const v = @as(f64, @floatFromInt(src[i + c]));
                        acc_pre[c] += v * a * w;
                        acc_flat[c] += v * w;
                    }
                }
            }

            const o = (@as(usize, dy) * dw + dx) * 4;
            if (acc_w <= 0) {
                @memset(out[o..][0..4], 0);
                continue;
            }
            out[o + 3] = quantizeChannel(acc_a / acc_w);
            if (acc_a > 0) {
                inline for (0..3) |c| out[o + c] = quantizeChannel(acc_pre[c] / acc_a);
            } else {
                inline for (0..3) |c| out[o + c] = quantizeChannel(acc_flat[c] / acc_w);
            }
        }
    }
    return out;
}

/// Centre-crop RGBA8 to its `min(w, h)` square. Returns a copy even when
/// already square, so the caller owns one buffer either way.
fn centreSquare(allocator: std.mem.Allocator, img: Rgba) ![]u8 {
    const edge = @min(img.width, img.height);
    const out = try allocator.alloc(u8, @as(usize, edge) * edge * 4);
    const ox = (img.width - edge) / 2;
    const oy = (img.height - edge) / 2;
    var y: u32 = 0;
    while (y < edge) : (y += 1) {
        const src_row = (@as(usize, oy + y) * img.width + ox) * 4;
        const dst_row = @as(usize, y) * edge * 4;
        @memcpy(out[dst_row .. dst_row + @as(usize, edge) * 4], img.pixels[src_row .. src_row + @as(usize, edge) * 4]);
    }
    return out;
}

// ── ICO container ──────────────────────────────────────────────────────

/// One image in the directory: its square edge and its PNG payload.
pub const Entry = struct {
    size: u32,
    png: []const u8,
};

pub const icondir_len: usize = 6;
pub const direntry_len: usize = 16;

/// The `ICONDIRENTRY` width/height byte: the size, with 0 standing for 256.
/// Anything larger cannot be represented and is also written as 0 (256) —
/// Windows reads the true size from the PNG payload's IHDR.
pub fn dirSizeByte(size: u32) u8 {
    return if (size >= 256) 0 else @intCast(size);
}

/// Lay out `ICONDIR` + `ICONDIRENTRY[]` + payloads. Pure bytes, no image
/// work — the unit the header test pins.
pub fn writeIcoContainer(allocator: std.mem.Allocator, entries: []const Entry) ![]u8 {
    if (entries.len == 0 or entries.len > std.math.maxInt(u16)) return error.InvalidEntryCount;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    // ICONDIR: reserved (0), type (1 = icon), count.
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 1, .little);
    try w.writeInt(u16, @intCast(entries.len), .little);

    var offset: u32 = @intCast(icondir_len + direntry_len * entries.len);
    for (entries) |e| {
        try w.writeByte(dirSizeByte(e.size)); // bWidth
        try w.writeByte(dirSizeByte(e.size)); // bHeight
        try w.writeByte(0); // bColorCount (0: not a palette image)
        try w.writeByte(0); // bReserved
        try w.writeInt(u16, 1, .little); // wPlanes
        try w.writeInt(u16, 32, .little); // wBitCount (RGBA)
        try w.writeInt(u32, @intCast(e.png.len), .little); // dwBytesInRes
        try w.writeInt(u32, offset, .little); // dwImageOffset
        offset = try std.math.add(u32, offset, @intCast(e.png.len));
    }
    for (entries) |e| try w.writeAll(e.png);
    return out.toOwnedSlice();
}

/// Build the `.ico` for a source PNG: `ico_sizes` (plus the native edge when
/// it is under 256), each an area-averaged downscale of the centred square,
/// PNG-encoded. Falls back to ONE entry carrying the source PNG verbatim when
/// the reader cannot decode it (see the module doc). `error.NotPng` when the
/// bytes are not a PNG at all.
pub fn buildIco(allocator: std.mem.Allocator, source_png: []const u8) ![]u8 {
    const dims = pngDimensions(source_png) orelse return error.NotPng;

    const img = decodePng(allocator, source_png) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotPng => return error.NotPng,
        // Undecodable here but a real PNG: ship it whole as the single entry —
        // but ONLY when the directory can describe it truthfully. An
        // `ICONDIRENTRY` carries one byte per axis (0 meaning 256), so a
        // non-square or >256 image cannot be stated: a 100x200 would be
        // advertised as 100x100 and a 512x512 as 256x256, leaving the
        // directory inconsistent with the payload's own IHDR — which lets
        // Windows (or the resource compiler) discard the icon we were trying
        // to preserve. A silently-wrong entry is worse than a clear refusal,
        // so those cases are an error the caller reports with the path.
        error.Unsupported, error.Malformed, error.TooLarge => {
            if (dims.width != dims.height or dims.width > 256) return error.IcoFallbackUnrepresentable;
            const one = [_]Entry{.{ .size = dims.width, .png = source_png }};
            return writeIcoContainer(allocator, &one);
        },
    };
    defer img.deinit(allocator);

    const square = try centreSquare(allocator, img);
    defer allocator.free(square);
    const edge = @min(img.width, img.height);

    var sizes_buf: [ico_sizes.len + 1]u32 = undefined;
    const sizes = entrySizes(edge, &sizes_buf);

    var entries: [ico_sizes.len + 1]Entry = undefined;
    var count: usize = 0;
    defer for (entries[0..count]) |e| allocator.free(e.png);
    for (sizes) |s| {
        const px = if (s == edge) square else try downscaleBox(allocator, square, edge, edge, s, s);
        defer if (s != edge) allocator.free(px);
        const png = try encodePng(allocator, px, s, s);
        entries[count] = .{ .size = s, .png = png };
        count += 1;
    }
    return writeIcoContainer(allocator, entries[0..count]);
}

/// The entry sizes for a square source of `edge`: every `ico_sizes` value
/// `<= edge`, with `edge` itself prepended when it is below 256 and not
/// already in the table — so the largest entry is always the best the source
/// can give, and nothing is upscaled.
pub fn entrySizes(edge: u32, buf: *[ico_sizes.len + 1]u32) []const u32 {
    var n: usize = 0;
    if (edge < ico_sizes[0]) {
        var in_table = false;
        for (ico_sizes) |s| {
            if (s == edge) in_table = true;
        }
        if (!in_table) {
            buf[n] = edge;
            n += 1;
        }
    }
    for (ico_sizes) |s| {
        if (s <= edge) {
            buf[n] = s;
            n += 1;
        }
    }
    return buf[0..n];
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Parse an `.ico` back into (size byte, payload) pairs for assertions.
const ParsedEntry = struct { size_byte: u8, planes: u16, bit_count: u16, payload: []const u8 };

fn parseIco(ico: []const u8, out: []ParsedEntry) ![]ParsedEntry {
    try testing.expect(ico.len >= icondir_len);
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, ico[0..2], .little));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ico[2..4], .little));
    const count = std.mem.readInt(u16, ico[4..6], .little);
    try testing.expect(count <= out.len);
    var expect_offset: usize = icondir_len + direntry_len * count;
    for (0..count) |i| {
        const e = ico[icondir_len + i * direntry_len ..][0..direntry_len];
        const bytes = std.mem.readInt(u32, e[8..12], .little);
        const offset = std.mem.readInt(u32, e[12..16], .little);
        // Payloads are contiguous, in directory order, right after the table.
        try testing.expectEqual(expect_offset, offset);
        try testing.expectEqual(e[0], e[1]); // square
        out[i] = .{
            .size_byte = e[0],
            .planes = std.mem.readInt(u16, e[4..6], .little),
            .bit_count = std.mem.readInt(u16, e[6..8], .little),
            .payload = ico[offset .. offset + bytes],
        };
        expect_offset += bytes;
    }
    try testing.expectEqual(ico.len, expect_offset);
    return out[0..count];
}

fn gradient(allocator: std.mem.Allocator, w: u32, h: u32) ![]u8 {
    const px = try allocator.alloc(u8, @as(usize, w) * h * 4);
    for (0..h) |y| for (0..w) |x| {
        const i = (y * w + x) * 4;
        px[i] = @intCast((x * 255) / @max(w - 1, 1));
        px[i + 1] = @intCast((y * 255) / @max(h - 1, 1));
        px[i + 2] = @intCast((x + y) % 256);
        px[i + 3] = if ((x + y) % 2 == 0) 255 else 40;
    };
    return px;
}

test "pngDimensions reads IHDR and rejects non-PNG bytes" {
    const png = try encodePng(testing.allocator, &[_]u8{0} ** (3 * 2 * 4), 3, 2);
    defer testing.allocator.free(png);
    const d = pngDimensions(png).?;
    try testing.expectEqual(@as(u32, 3), d.width);
    try testing.expectEqual(@as(u32, 2), d.height);
    try testing.expect(pngDimensions("definitely not a png, but long enough to have a header") == null);
    try testing.expect(pngDimensions(png[0..20]) == null);
}

test "encodePng → decodePng round-trips RGBA exactly" {
    const px = try gradient(testing.allocator, 7, 5);
    defer testing.allocator.free(px);
    const png = try encodePng(testing.allocator, px, 7, 5);
    defer testing.allocator.free(png);
    const img = try decodePng(testing.allocator, png);
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 7), img.width);
    try testing.expectEqual(@as(u32, 5), img.height);
    try testing.expectEqualSlices(u8, px, img.pixels);
}

test "decodePng expands grey, RGB and palette sources to RGBA" {
    // Grey 2×1.
    {
        const png = try encodePngRaw(testing.allocator, &.{ 10, 200 }, 2, 1, 0, null);
        defer testing.allocator.free(png);
        const img = try decodePng(testing.allocator, png);
        defer img.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, &.{ 10, 10, 10, 255, 200, 200, 200, 255 }, img.pixels);
    }
    // RGB 2×1.
    {
        const png = try encodePngRaw(testing.allocator, &.{ 1, 2, 3, 4, 5, 6 }, 2, 1, 2, null);
        defer testing.allocator.free(png);
        const img = try decodePng(testing.allocator, png);
        defer img.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 4, 5, 6, 255 }, img.pixels);
    }
    // Palette 3×1 with two colours.
    {
        const plte = [_]u8{ 255, 0, 0, 0, 0, 255 };
        const png = try encodePngRaw(testing.allocator, &.{ 0, 1, 0 }, 3, 1, 3, &plte);
        defer testing.allocator.free(png);
        const img = try decodePng(testing.allocator, png);
        defer img.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 255, 255, 255, 0, 0, 255 }, img.pixels);
    }
}

test "decodePng: every filter type unfilters (multi-row gradient survives zlib+filters)" {
    // Our encoder only writes filter 0; exercise the other four directly.
    // Sub: [5, +1, +1] with bpp 1 → 5, 6, 7.
    var sub = [_]u8{ 5, 1, 1 };
    try unfilterRow(1, &sub, null, 1);
    try testing.expectEqualSlices(u8, &.{ 5, 6, 7 }, &sub);
    // Up: adds the row above.
    var prev = [_]u8{ 10, 20, 30 };
    var up = [_]u8{ 1, 2, 3 };
    try unfilterRow(2, &up, &prev, 1);
    try testing.expectEqualSlices(u8, &.{ 11, 22, 33 }, &up);
    // Average: floor((left + up) / 2).
    var avg = [_]u8{ 0, 0, 0 };
    try unfilterRow(3, &avg, &prev, 1);
    // x0: (0 + 10)/2 = 5; x1: (5 + 20)/2 = 12; x2: (12 + 30)/2 = 21
    try testing.expectEqualSlices(u8, &.{ 5, 12, 21 }, &avg);
    // Paeth with a zero row above degenerates to Sub.
    var paeth = [_]u8{ 5, 1, 1 };
    var zero = [_]u8{ 0, 0, 0 };
    try unfilterRow(4, &paeth, &zero, 1);
    try testing.expectEqualSlices(u8, &.{ 5, 6, 7 }, &paeth);
    // An out-of-range filter byte is a malformed stream, not UB.
    var bad = [_]u8{0};
    try testing.expectError(error.Malformed, unfilterRow(9, &bad, null, 1));
}

test "decodePng refuses interlaced PNGs as Unsupported (not Malformed)" {
    var png = try encodePng(testing.allocator, &[_]u8{0} ** 16, 2, 2);
    defer testing.allocator.free(png);
    png[28] = 1; // IHDR interlace method = Adam7 (CRC now stale; we never check it)
    try testing.expectError(error.Unsupported, decodePng(testing.allocator, png));
}

test "entrySizes: the table below the source edge, plus a small native" {
    var buf: [ico_sizes.len + 1]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 256, 48, 32, 16 }, entrySizes(512, &buf));
    try testing.expectEqualSlices(u32, &.{ 256, 48, 32, 16 }, entrySizes(256, &buf));
    try testing.expectEqualSlices(u32, &.{ 100, 48, 32, 16 }, entrySizes(100, &buf));
    try testing.expectEqualSlices(u32, &.{ 48, 32, 16 }, entrySizes(48, &buf));
    try testing.expectEqualSlices(u32, &.{ 20, 16 }, entrySizes(20, &buf));
    try testing.expectEqualSlices(u32, &.{16}, entrySizes(16, &buf));
    try testing.expectEqualSlices(u32, &.{8}, entrySizes(8, &buf));
}

test "writeIcoContainer: ICONDIR + ICONDIRENTRY layout, 256 written as 0" {
    const a = "AAAA";
    const b = "bb";
    const ico = try writeIcoContainer(testing.allocator, &.{
        .{ .size = 256, .png = a },
        .{ .size = 16, .png = b },
    });
    defer testing.allocator.free(ico);
    try testing.expectEqual(icondir_len + 2 * direntry_len + a.len + b.len, ico.len);
    var buf: [2]ParsedEntry = undefined;
    const entries = try parseIco(ico, &buf);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(u8, 0), entries[0].size_byte);
    try testing.expectEqual(@as(u8, 16), entries[1].size_byte);
    try testing.expectEqual(@as(u16, 1), entries[0].planes);
    try testing.expectEqual(@as(u16, 32), entries[0].bit_count);
    try testing.expectEqualStrings(a, entries[0].payload);
    try testing.expectEqualStrings(b, entries[1].payload);
    try testing.expectError(error.InvalidEntryCount, writeIcoContainer(testing.allocator, &.{}));
}

test "buildIco on the bundled 512 default: 4 PNG entries at 256/48/32/16" {
    const default_icon = @embedFile("assets/default_icon.png");
    const ico = try buildIco(testing.allocator, default_icon);
    defer testing.allocator.free(ico);
    var buf: [8]ParsedEntry = undefined;
    const entries = try parseIco(ico, &buf);
    try testing.expectEqual(@as(usize, 4), entries.len);
    const want = [_]u32{ 256, 48, 32, 16 };
    for (entries, want) |e, s| {
        try testing.expectEqual(dirSizeByte(s), e.size_byte);
        const d = pngDimensions(e.payload) orelse return error.PayloadNotPng;
        try testing.expectEqual(s, d.width);
        try testing.expectEqual(s, d.height);
        // Every payload decodes with our own reader, too.
        const img = try decodePng(testing.allocator, e.payload);
        defer img.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, s) * s * 4, img.pixels.len);
    }
    // Deflated: the four entries together (≈206 KiB for this art) come in
    // under the 512 source PNG (≈430 KiB); stored blocks would be ≈300 KiB
    // for the 256 entry alone.
    try testing.expect(ico.len < default_icon.len);
}

test "buildIco on a small non-square source: centre-crops and keeps the native edge" {
    // 40 wide × 20 tall, all one colour → a 20-square: entries 20 + 16.
    const px = try testing.allocator.alloc(u8, 40 * 20 * 4);
    defer testing.allocator.free(px);
    for (0..40 * 20) |i| @memcpy(px[i * 4 ..][0..4], &[_]u8{ 9, 8, 7, 255 });
    const png = try encodePng(testing.allocator, px, 40, 20);
    defer testing.allocator.free(png);
    const ico = try buildIco(testing.allocator, png);
    defer testing.allocator.free(ico);
    var buf: [8]ParsedEntry = undefined;
    const entries = try parseIco(ico, &buf);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(u8, 20), entries[0].size_byte);
    try testing.expectEqual(@as(u8, 16), entries[1].size_byte);
    const small = try decodePng(testing.allocator, entries[1].payload);
    defer small.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 9, 8, 7, 255 }, small.pixels[0..4]);
}

test "buildIco falls back to one verbatim entry for a PNG it cannot decode" {
    var png = try encodePng(testing.allocator, &[_]u8{0} ** (2 * 2 * 4), 2, 2);
    defer testing.allocator.free(png);
    png[28] = 1; // interlaced → Unsupported
    const ico = try buildIco(testing.allocator, png);
    defer testing.allocator.free(ico);
    var buf: [2]ParsedEntry = undefined;
    const entries = try parseIco(ico, &buf);
    try testing.expectEqual(@as(usize, 1), entries.len);
    // The entry states the IHDR's OWN dimensions, so the directory and the
    // payload agree.
    try testing.expectEqual(@as(u8, 2), entries[0].size_byte);
    try testing.expectEqualSlices(u8, png, entries[0].payload);
}

test "the verbatim fallback refuses to describe an undecodable 512 or non-square PNG" {
    // An ICONDIRENTRY holds one byte per axis (0 = 256), so neither a 512
    // square nor a 100x200 can be stated truthfully. Emitting one anyway
    // would advertise 256x256 / 100x100 over a payload whose IHDR says
    // otherwise, and a reader that trusts the directory drops the icon.
    //
    // Fixture: a real 4x4 PNG whose IHDR is rewritten to the target size —
    // still a PNG (so `pngDimensions` reads it), no longer decodable (the
    // IDAT is 4x4), which is exactly the state the fallback exists for.
    inline for (.{ .{ 512, 512 }, .{ 100, 200 }, .{ 300, 300 } }) |dims| {
        var png = try encodePng(testing.allocator, &[_]u8{0} ** (4 * 4 * 4), 4, 4);
        defer testing.allocator.free(png);
        std.mem.writeInt(u32, png[16..20], dims[0], .big);
        std.mem.writeInt(u32, png[20..24], dims[1], .big);
        try testing.expectEqual(@as(u32, dims[0]), pngDimensions(png).?.width);
        try testing.expectError(error.IcoFallbackUnrepresentable, buildIco(testing.allocator, png));
    }

    // …while an undecodable image that IS representable still falls back: a
    // 256 square is the largest the directory can state (as the byte 0).
    var ok_png = try encodePng(testing.allocator, &[_]u8{0} ** (4 * 4 * 4), 4, 4);
    defer testing.allocator.free(ok_png);
    std.mem.writeInt(u32, ok_png[16..20], 256, .big);
    std.mem.writeInt(u32, ok_png[20..24], 256, .big);
    const ico = try buildIco(testing.allocator, ok_png);
    defer testing.allocator.free(ico);
    var buf: [2]ParsedEntry = undefined;
    const entries = try parseIco(ico, &buf);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(u8, 0), entries[0].size_byte); // 0 == 256
}

test "downscaleBox: fractional coverage is weighted, and alpha is premultiplied" {
    // Mirrors the labelle-bgfx tests for the same filter (bgfx#81 review).
    // 3x1 -> 2x1 at scale 1.5: footprints [0,1.5) and [1.5,3), so the middle
    // pixel is split — 30 and 50, not the 0/60 an integer-footprint filter
    // (which snapped the edge) produced.
    {
        const src = [_]u8{ 0, 0, 0, 255, 90, 90, 90, 255, 30, 30, 30, 255 };
        const out = try downscaleBox(testing.allocator, &src, 3, 1, 2, 1);
        defer testing.allocator.free(out);
        try testing.expectEqualSlices(u8, &.{ 30, 30, 30, 255 }, out[0..4]);
        try testing.expectEqualSlices(u8, &.{ 50, 50, 50, 255 }, out[4..8]);
    }
    // One opaque red among three fully transparent pixels stays PURE red at a
    // quarter alpha; straight RGBA averaging returns (64,0,0,64) — the halo.
    {
        const src = [_]u8{
            255, 0, 0, 255, 0, 0, 0, 0,
            0,   0, 0, 0,   0, 0, 0, 0,
        };
        const out = try downscaleBox(testing.allocator, &src, 2, 2, 1, 1);
        defer testing.allocator.free(out);
        try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 64 }, out);
    }
    // An integer ratio is still the exact block mean (the ICO's 256->128-ish
    // steps rely on this being unchanged).
    {
        const src = [_]u8{
            0,   0,   0,   255, 255, 255, 255, 255,
            255, 255, 255, 255, 0,   0,   0,   255,
        };
        const out = try downscaleBox(testing.allocator, &src, 2, 2, 1, 1);
        defer testing.allocator.free(out);
        try testing.expectEqualSlices(u8, &.{ 128, 128, 128, 255 }, out);
    }
}

test "buildIco rejects bytes that are not a PNG" {
    try testing.expectError(error.NotPng, buildIco(testing.allocator, "just some text that is long enough to not be short"));
}
