/// Texture loading + GPU upload for the sokol gfx backend.
/// stb_image is the decode path; sokol_gfx owns the device-side image.
const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;
const types = @import("types.zig");

const Texture = types.Texture;

// Both stb headers go through a tiny shim that empties out clang's
// nullability qualifiers before include. Zig 0.16's translate-c
// rejects `_Nonnull` on array parameters in Bionic's stdlib.h on the
// Android NDK 27 sysroot — see Flying-Platform/flying-platform-labelle#450.
// Macro-replacing `_Nonnull` / `_Nullable` to nothing makes the
// preprocessor strip them before translate-c sees the declarations.
pub const stbi = @cImport({
    @cInclude("stb_shim.h");
});

/// CPU-decoded image owned by the caller's allocator. Field layout
/// (`pixels: []u8`, `width: u32`, `height: u32`) mirrors labelle-gfx's
/// `DecodedImage` exactly — Zig's lazy comptime evaluation of the
/// generic `Backend(Impl)` wrapper means the `decodeImage`/`uploadTexture`
/// forwarders in the wrapper are never instantiated by the retained
/// engine (it only calls the synthesized `loadTextureFromMemory`
/// convenience wrapper, which stays in Impl-land and never crosses the
/// nominal-type boundary), so a structurally identical per-backend type
/// is sufficient to satisfy the `@hasDecl` contract without adding
/// labelle-gfx as a dependency of the backend package.
pub const DecodedImage = struct {
    pixels: []u8,
    width: u32,
    height: u32,
};

pub fn loadTexture(path: [:0]const u8) !Texture {
    // Read the file from disk, then decode from memory
    const file = std.fs.cwd().openFileZ(path, .{}) catch return error.LoadFailed;
    defer file.close();

    const stat = file.stat() catch return error.LoadFailed;
    const file_size = stat.size;
    if (file_size == 0 or file_size > 256 * 1024 * 1024) return error.LoadFailed;

    const data = file.readToEndAlloc(std.heap.page_allocator, @intCast(file_size)) catch return error.LoadFailed;
    defer std.heap.page_allocator.free(data);

    const decoded = try decodeImage("", data, std.heap.page_allocator);
    defer std.heap.page_allocator.free(decoded.pixels);
    return uploadTexture(decoded);
}

/// "LRGBA" + 3 padding bytes (8-byte alignment). Followed by u32 LE
/// width, u32 LE height, then width*height*4 bytes of RGBA pixels.
/// Produced by `labelle build --bake` (labelle-cli) to skip PNG decode
/// on cold start. See labelle-cli/src/cli/bake.zig.
const lrgba_magic = "LRGBA\x00\x00\x00";
const lrgba_header_len = lrgba_magic.len + 8;

/// Pure CPU decode: safe to call from a worker thread. Returns a
/// `DecodedImage` whose `pixels` buffer is allocated from `allocator` —
/// the caller owns it and MUST free it via the same allocator on both
/// the success and the discard paths (see `uploadTexture`).
pub fn decodeImage(
    _: [:0]const u8,
    data: []const u8,
    allocator: std.mem.Allocator,
) !DecodedImage {
    // Fast path: pre-baked LRGBA container. No PNG decode needed —
    // the bake step already ran stb_image at build time.
    if (data.len >= lrgba_header_len and std.mem.eql(u8, data[0..lrgba_magic.len], lrgba_magic)) {
        const w = std.mem.readInt(u32, data[lrgba_magic.len..][0..4], .little);
        const h = std.mem.readInt(u32, data[lrgba_magic.len + 4 ..][0..4], .little);
        if (w == 0 or h == 0) return error.LoadFailed;
        // Checked arithmetic — `w * h * 4` and `header + pixels_len`
        // could each overflow `usize` on 32-bit targets or with
        // adversarial dimensions; a silent wrap would let the
        // `data.len <` check pass incorrectly.
        const wh = std.math.mul(usize, @as(usize, w), @as(usize, h)) catch return error.LoadFailed;
        const pixels_len = std.math.mul(usize, wh, 4) catch return error.LoadFailed;
        const end = std.math.add(usize, lrgba_header_len, pixels_len) catch return error.LoadFailed;
        if (data.len < end) return error.LoadFailed;
        const owned = try allocator.alloc(u8, pixels_len);
        @memcpy(owned, data[lrgba_header_len..end]);
        return .{ .pixels = owned, .width = w, .height = h };
    }

    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const raw = stbi.stbi_load_from_memory(
        @ptrCast(data.ptr),
        @intCast(data.len),
        &width,
        &height,
        &channels,
        4, // force RGBA
    );
    if (raw == null) return error.LoadFailed;
    defer stbi.stbi_image_free(raw);

    if (width <= 0 or height <= 0) return error.LoadFailed;

    const len: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    const owned = try allocator.alloc(u8, len);
    @memcpy(owned, @as([*]const u8, @ptrCast(raw))[0..len]);

    return .{
        .pixels = owned,
        .width = @intCast(width),
        .height = @intCast(height),
    };
}

/// Main/GL-thread GPU upload. Does NOT free `decoded.pixels` — the
/// caller (the asset catalog, or the `loadTexture`/`loadTextureFromMemory`
/// helper) owns that buffer and frees it on both the success and the
/// discard paths.
pub fn uploadTexture(decoded: DecodedImage) !Texture {
    const w: i32 = @intCast(decoded.width);
    const h: i32 = @intCast(decoded.height);
    return createTextureFromRgba(decoded.pixels, w, h);
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
