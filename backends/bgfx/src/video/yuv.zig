//! YUV → RGBA8 colour conversion for the in-engine video decode path
//! (Flying-Platform/flying-platform-labelle#549, Path A Half 2).
//!
//! Android's `AMediaCodec` ByteBuffer output is YUV, not RGBA — typically
//! `COLOR_FormatYUV420SemiPlanar` (NV12: Y plane + interleaved UV) or
//! `COLOR_FormatYUV420Planar` (I420: Y + U + V planes). bgfx draws RGBA8
//! textures, so the decoded frame must be converted before `updateTexture`.
//!
//! This module is **pure Zig with no NDK dependency**, so it builds and is
//! unit-tested on the host — the one piece of the Android decode path that is
//! verifiable without a device. The conversion uses the BT.601 limited-range
//! integer coefficients (the standard for SD/most MediaCodec output).
//!
//! Strides are explicit: MediaCodec output planes are frequently padded
//! (`stride >= width`), so the caller passes the real plane strides from the
//! output `AMediaFormat` rather than assuming tight packing.

const std = @import("std");

/// BT.601 limited-range YUV → RGB, integer math (matches the canonical
/// fixed-point coefficients). Inputs are the raw plane samples; output is a
/// clamped RGBA8 pixel.
inline fn yuvToRgba(y: u8, u: u8, v: u8, out: *[4]u8) void {
    const c: i32 = @as(i32, y) - 16;
    const d: i32 = @as(i32, u) - 128;
    const e: i32 = @as(i32, v) - 128;
    out[0] = clamp8((298 * c + 409 * e + 128) >> 8);
    out[1] = clamp8((298 * c - 100 * d - 208 * e + 128) >> 8);
    out[2] = clamp8((298 * c + 516 * d + 128) >> 8);
    out[3] = 255;
}

inline fn clamp8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// NV12 (`COLOR_FormatYUV420SemiPlanar`): full-res Y plane, then a half-res
/// interleaved UV plane (U,V,U,V…). `out` is width*height*4 RGBA8 bytes.
pub fn nv12ToRgba(
    y_plane: []const u8,
    uv_plane: []const u8,
    width: u32,
    height: u32,
    y_stride: u32,
    uv_stride: u32,
    out: []u8,
) void {
    std.debug.assert(out.len == @as(usize, width) * height * 4);
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            const y = y_plane[row * y_stride + col];
            // UV is sub-sampled 2×2: one (U,V) pair per 2×2 luma block.
            const uv_off = (row / 2) * uv_stride + (col / 2) * 2;
            const u = uv_plane[uv_off];
            const v = uv_plane[uv_off + 1];
            const o = (row * width + col) * 4;
            yuvToRgba(y, u, v, out[o..][0..4]);
        }
    }
}

/// I420 (`COLOR_FormatYUV420Planar`): full-res Y, then half-res U, then
/// half-res V planes. `out` is width*height*4 RGBA8 bytes.
pub fn i420ToRgba(
    y_plane: []const u8,
    u_plane: []const u8,
    v_plane: []const u8,
    width: u32,
    height: u32,
    y_stride: u32,
    uv_stride: u32,
    out: []u8,
) void {
    std.debug.assert(out.len == @as(usize, width) * height * 4);
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        var col: u32 = 0;
        while (col < width) : (col += 1) {
            const y = y_plane[row * y_stride + col];
            const chroma_off = (row / 2) * uv_stride + (col / 2);
            const u = u_plane[chroma_off];
            const v = v_plane[chroma_off];
            const o = (row * width + col) * 4;
            yuvToRgba(y, u, v, out[o..][0..4]);
        }
    }
}

// ── Tests (host-runnable — no NDK) ───────────────────────────────────────

test "nv12: neutral chroma maps Y=16→black, Y=235→white" {
    const w = 2;
    const h = 2;
    var out: [w * h * 4]u8 = undefined;

    // Y=16 everywhere, UV neutral (128,128) → black.
    const black_y = [_]u8{ 16, 16, 16, 16 };
    const neutral_uv = [_]u8{ 128, 128 }; // one pair covers the 2×2 block
    nv12ToRgba(&black_y, &neutral_uv, w, h, w, w, &out);
    for (0..w * h) |i| {
        try std.testing.expectEqual(@as(u8, 0), out[i * 4 + 0]);
        try std.testing.expectEqual(@as(u8, 0), out[i * 4 + 1]);
        try std.testing.expectEqual(@as(u8, 0), out[i * 4 + 2]);
        try std.testing.expectEqual(@as(u8, 255), out[i * 4 + 3]);
    }

    // Y=235 everywhere, neutral UV → white.
    const white_y = [_]u8{ 235, 235, 235, 235 };
    nv12ToRgba(&white_y, &neutral_uv, w, h, w, w, &out);
    for (0..w * h) |i| {
        try std.testing.expectEqual(@as(u8, 255), out[i * 4 + 0]);
        try std.testing.expectEqual(@as(u8, 255), out[i * 4 + 1]);
        try std.testing.expectEqual(@as(u8, 255), out[i * 4 + 2]);
    }
}

test "i420 matches nv12 for the same logical frame" {
    const w = 2;
    const h = 2;
    const y = [_]u8{ 120, 120, 120, 120 };
    // NV12 interleaved vs I420 planar — same U=100, V=200.
    const nv12_uv = [_]u8{ 100, 200 };
    const i420_u = [_]u8{100};
    const i420_v = [_]u8{200};

    var a: [w * h * 4]u8 = undefined;
    var b: [w * h * 4]u8 = undefined;
    nv12ToRgba(&y, &nv12_uv, w, h, w, w, &a);
    i420ToRgba(&y, &i420_u, &i420_v, w, h, w, w, &b);
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "stride padding is honoured (y_stride > width)" {
    const w = 2;
    const h = 2;
    const y_stride = 4; // 2px of row padding
    // Row 0: [10,20, pad,pad], Row 1: [30,40, pad,pad]
    const y = [_]u8{ 10, 20, 0, 0, 30, 40, 0, 0 };
    const uv = [_]u8{ 128, 128 };
    var out: [w * h * 4]u8 = undefined;
    nv12ToRgba(&y, &uv, w, h, y_stride, w, &out);
    // Just assert the padded bytes weren't sampled: pixel (1,1) uses y=40 not 0.
    var expect: [4]u8 = undefined;
    yuvToRgba(40, 128, 128, &expect);
    try std.testing.expectEqualSlices(u8, &expect, out[(3) * 4 ..][0..4]);
}
