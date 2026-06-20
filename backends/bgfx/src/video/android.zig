//! Android H.264 decoder via the NDK Media APIs — Path A Half 2, Android target
//! (Flying-Platform/flying-platform-labelle#549).
//!
//! Uses `AMediaExtractor` (demux the mp4 container) + `AMediaCodec` (hardware
//! H.264 decode) in **ByteBuffer mode**, then converts the YUV output to RGBA8
//! (`video/yuv.zig`) and hands it to the bgfx dynamic texture (`updateTexture`,
//! Half 1) — the same sink the desktop ffmpeg pipe feeds.
//!
//! These are pure C NDK APIs (no JNI/Java), so they're called from Zig via
//! `extern`. The decoder is **comptime-gated to the Android ABI**: off Android
//! it resolves to an `Unsupported` stub so host/desktop builds never reference
//! the NDK symbols.
//!
//! Verified on-device: the `apk/` NativeActivity harness decodes a real H.264
//! clip on a Pixel-7 API-34 emulator (arm64) — extract → AMediaCodec decode →
//! YUV→RGBA, 10 frames, RESULT PASS. (AMediaCodec needs a real app process for
//! its Binder/JVM context, which is why the bare-CLI harness can't get past
//! codec creation — see `apk/native.zig`.) The host-testable colour conversion
//! lives in `yuv.zig`.
//!
//! Known follow-ups (next slices, deliberately out of this first cut):
//!   - `COLOR_FormatYUV420Flexible` / proprietary tiled vendor formats (need
//!     AImageReader or per-vendor layout); this cut handles the two standard
//!     planar/semi-planar formats.
//!   - crop rectangle + slice-height vs height (we read stride/slice-height
//!     when present).
//!   - Surface/OES zero-copy path (faster, but doesn't fit bgfx cleanly — see
//!     the #549 analysis); ByteBuffer is the portable first cut.

const std = @import("std");
const builtin = @import("builtin");
const yuv = @import("yuv.zig");

const is_android = builtin.abi == .android or builtin.abi == .androideabi;

/// Public decoder type. Real implementation on Android; a stub elsewhere so the
/// engine compiles on every backend/target.
pub const VideoDecoder = if (is_android) AndroidVideoDecoder else UnsupportedDecoder;

pub const Error = error{
    Unsupported,
    NoVideoTrack,
    UnsupportedColorFormat,
    DecoderInit,
    OutOfMemory,
};

/// Off-Android stub — keeps the call sites compiling on host/desktop/wasm.
const UnsupportedDecoder = struct {
    pub fn openFd(_: std.mem.Allocator, _: c_int, _: i64, _: i64) Error!UnsupportedDecoder {
        return error.Unsupported;
    }
    pub fn width(_: *const UnsupportedDecoder) u32 {
        return 0;
    }
    pub fn height(_: *const UnsupportedDecoder) u32 {
        return 0;
    }
    pub fn decodeFrame(_: *UnsupportedDecoder, _: []u8) bool {
        return false;
    }
    pub fn deinit(_: *UnsupportedDecoder) void {}
};

// ── NDK Media C ABI (subset) ─────────────────────────────────────────────
// Declared inside the Android impl so the externs are only analyzed when the
// Android type is actually instantiated (host builds pick the stub).

const AndroidVideoDecoder = struct {
    const Extractor = opaque {};
    const Codec = opaque {};
    const Format = opaque {};

    const BufferInfo = extern struct {
        offset: i32,
        size: i32,
        presentation_time_us: i64,
        flags: u32,
    };

    // media_status_t: AMEDIA_OK == 0.
    extern fn AMediaExtractor_new() ?*Extractor;
    extern fn AMediaExtractor_setDataSourceFd(*Extractor, fd: c_int, offset: i64, length: i64) i32;
    extern fn AMediaExtractor_getTrackCount(*Extractor) usize;
    extern fn AMediaExtractor_getTrackFormat(*Extractor, idx: usize) ?*Format;
    extern fn AMediaExtractor_selectTrack(*Extractor, idx: usize) i32;
    extern fn AMediaExtractor_readSampleData(*Extractor, buf: [*]u8, capacity: usize) isize;
    extern fn AMediaExtractor_advance(*Extractor) bool;
    extern fn AMediaExtractor_delete(*Extractor) void;

    extern fn AMediaFormat_getString(*Format, name: [*:0]const u8, out: *[*:0]const u8) bool;
    extern fn AMediaFormat_getInt32(*Format, name: [*:0]const u8, out: *i32) bool;
    extern fn AMediaFormat_delete(*Format) void;

    extern fn AMediaCodec_createDecoderByType(mime: [*:0]const u8) ?*Codec;
    extern fn AMediaCodec_configure(*Codec, fmt: *Format, surface: ?*anyopaque, crypto: ?*anyopaque, flags: u32) i32;
    extern fn AMediaCodec_start(*Codec) i32;
    extern fn AMediaCodec_stop(*Codec) i32;
    extern fn AMediaCodec_delete(*Codec) void;
    extern fn AMediaCodec_dequeueInputBuffer(*Codec, timeout_us: i64) isize;
    extern fn AMediaCodec_getInputBuffer(*Codec, idx: usize, out_size: *usize) ?[*]u8;
    extern fn AMediaCodec_queueInputBuffer(*Codec, idx: usize, offset: u32, size: usize, time_us: u64, flags: u32) i32;
    extern fn AMediaCodec_dequeueOutputBuffer(*Codec, info: *BufferInfo, timeout_us: i64) isize;
    extern fn AMediaCodec_getOutputBuffer(*Codec, idx: usize, out_size: *usize) ?[*]u8;
    extern fn AMediaCodec_getOutputFormat(*Codec) ?*Format;
    extern fn AMediaCodec_releaseOutputBuffer(*Codec, idx: usize, render: bool) i32;

    const AMEDIA_OK: i32 = 0;
    const FLAG_EOS: u32 = 4; // AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM
    const INFO_TRY_AGAIN: isize = -1;
    const INFO_FORMAT_CHANGED: isize = -2;
    const INFO_BUFFERS_CHANGED: isize = -3;

    // AMediaFormat keys.
    const KEY_MIME: [*:0]const u8 = "mime";
    const KEY_WIDTH: [*:0]const u8 = "width";
    const KEY_HEIGHT: [*:0]const u8 = "height";
    const KEY_COLOR_FORMAT: [*:0]const u8 = "color-format";
    const KEY_STRIDE: [*:0]const u8 = "stride";
    const KEY_SLICE_HEIGHT: [*:0]const u8 = "slice-height";

    // MediaCodec color formats we handle in ByteBuffer mode.
    const COLOR_I420: i32 = 19; // COLOR_FormatYUV420Planar
    const COLOR_NV12: i32 = 21; // COLOR_FormatYUV420SemiPlanar

    extractor: *Extractor,
    codec: *Codec,
    w: u32,
    h: u32,
    color_format: i32,
    input_done: bool,

    /// Open a video stream from a file descriptor (the APK asset fd from
    /// `AAsset_openFileDescriptor`, with its offset/length). Selects the first
    /// `video/*` track and configures a hardware decoder in ByteBuffer mode.
    pub fn openFd(_: std.mem.Allocator, fd: c_int, offset: i64, length: i64) Error!AndroidVideoDecoder {
        const ex = AMediaExtractor_new() orelse return error.DecoderInit;
        errdefer AMediaExtractor_delete(ex);
        if (AMediaExtractor_setDataSourceFd(ex, fd, offset, length) != AMEDIA_OK)
            return error.DecoderInit;

        const n = AMediaExtractor_getTrackCount(ex);
        var track: usize = 0;
        var found = false;
        // The mime string from AMediaFormat_getString is owned by the format
        // and freed by AMediaFormat_delete — copy it out before the format dies,
        // or createDecoderByType reads a dangling pointer.
        var mime_buf: [64]u8 = undefined;
        var mime_len: usize = 0;
        var w: i32 = 0;
        var h: i32 = 0;
        var color: i32 = COLOR_NV12;
        while (track < n) : (track += 1) {
            const fmt = AMediaExtractor_getTrackFormat(ex, track) orelse continue;
            defer AMediaFormat_delete(fmt);
            var m: [*:0]const u8 = undefined;
            if (!AMediaFormat_getString(fmt, KEY_MIME, &m)) continue;
            const span = std.mem.span(m);
            if (!std.mem.startsWith(u8, span, "video/")) continue;
            if (span.len + 1 > mime_buf.len) continue;
            _ = AMediaFormat_getInt32(fmt, KEY_WIDTH, &w);
            _ = AMediaFormat_getInt32(fmt, KEY_HEIGHT, &h);
            _ = AMediaFormat_getInt32(fmt, KEY_COLOR_FORMAT, &color);
            @memcpy(mime_buf[0..span.len], span);
            mime_buf[span.len] = 0;
            mime_len = span.len;
            found = true;
            break;
        }
        if (!found) return error.NoVideoTrack;
        const mime: [*:0]const u8 = mime_buf[0..mime_len :0].ptr;
        if (AMediaExtractor_selectTrack(ex, track) != AMEDIA_OK) return error.DecoderInit;

        const codec = AMediaCodec_createDecoderByType(mime) orelse return error.DecoderInit;
        errdefer AMediaCodec_delete(codec);
        const cfg_fmt = AMediaExtractor_getTrackFormat(ex, track) orelse return error.DecoderInit;
        defer AMediaFormat_delete(cfg_fmt);
        // surface = null -> ByteBuffer (CPU-readable YUV) output.
        if (AMediaCodec_configure(codec, cfg_fmt, null, null, 0) != AMEDIA_OK)
            return error.DecoderInit;
        if (AMediaCodec_start(codec) != AMEDIA_OK) return error.DecoderInit;

        return .{
            .extractor = ex,
            .codec = codec,
            .w = @intCast(@max(w, 0)),
            .h = @intCast(@max(h, 0)),
            .color_format = color,
            .input_done = false,
        };
    }

    pub fn width(self: *const AndroidVideoDecoder) u32 {
        return self.w;
    }
    pub fn height(self: *const AndroidVideoDecoder) u32 {
        return self.h;
    }

    /// Pump one decode step and, if a frame came out, convert it to RGBA8 into
    /// `out` (width*height*4 bytes). Returns true if `out` was filled. Feeds at
    /// most one input sample per call and drains one output buffer.
    pub fn decodeFrame(self: *AndroidVideoDecoder, out: []u8) bool {
        if (out.len != @as(usize, self.w) * self.h * 4) return false;

        // -- Feed input.
        if (!self.input_done) {
            const in_idx = AMediaCodec_dequeueInputBuffer(self.codec, 2000);
            if (in_idx >= 0) {
                const idx: usize = @intCast(in_idx);
                var cap: usize = 0;
                if (AMediaCodec_getInputBuffer(self.codec, idx, &cap)) |buf| {
                    const n = AMediaExtractor_readSampleData(self.extractor, buf, cap);
                    if (n < 0) {
                        _ = AMediaCodec_queueInputBuffer(self.codec, idx, 0, 0, 0, FLAG_EOS);
                        self.input_done = true;
                    } else {
                        _ = AMediaCodec_queueInputBuffer(self.codec, idx, 0, @intCast(n), 0, 0);
                        _ = AMediaExtractor_advance(self.extractor);
                    }
                }
            }
        }

        // -- Drain output.
        var info: BufferInfo = undefined;
        const out_idx = AMediaCodec_dequeueOutputBuffer(self.codec, &info, 2000);
        if (out_idx == INFO_FORMAT_CHANGED) {
            self.refreshFormat();
            return false;
        }
        if (out_idx < 0) return false; // TRY_AGAIN / BUFFERS_CHANGED — caller retries

        const idx: usize = @intCast(out_idx);
        var size: usize = 0;
        const got = if (AMediaCodec_getOutputBuffer(self.codec, idx, &size)) |buf|
            self.convert(buf[0..size], out)
        else
            false;
        _ = AMediaCodec_releaseOutputBuffer(self.codec, idx, false);
        return got;
    }

    /// Read the decoder's output format for stride/slice-height/color updates
    /// (emitted once via INFO_FORMAT_CHANGED before the first frame).
    fn refreshFormat(self: *AndroidVideoDecoder) void {
        const fmt = AMediaCodec_getOutputFormat(self.codec) orelse return;
        defer AMediaFormat_delete(fmt);
        var v: i32 = 0;
        if (AMediaFormat_getInt32(fmt, KEY_COLOR_FORMAT, &v)) self.color_format = v;
        if (AMediaFormat_getInt32(fmt, KEY_WIDTH, &v)) self.w = @intCast(@max(v, 0));
        if (AMediaFormat_getInt32(fmt, KEY_HEIGHT, &v)) self.h = @intCast(@max(v, 0));
    }

    /// Convert a decoded YUV buffer to RGBA8 using the negotiated color format.
    fn convert(self: *AndroidVideoDecoder, buf: []const u8, out: []u8) bool {
        const fmt = AMediaCodec_getOutputFormat(self.codec) orelse return false;
        defer AMediaFormat_delete(fmt);
        var stride: i32 = @intCast(self.w);
        var slice: i32 = @intCast(self.h);
        _ = AMediaFormat_getInt32(fmt, KEY_STRIDE, &stride);
        _ = AMediaFormat_getInt32(fmt, KEY_SLICE_HEIGHT, &slice);
        const y_stride: u32 = @intCast(@max(stride, @as(i32, @intCast(self.w))));
        const sh: u32 = @intCast(@max(slice, @as(i32, @intCast(self.h))));

        const y_size = @as(usize, y_stride) * sh;
        if (buf.len < y_size) return false;
        const y_plane = buf[0..y_size];
        const chroma_stride = y_stride; // half-width pairs == width bytes for NV12
        switch (self.color_format) {
            COLOR_NV12 => {
                if (buf.len < y_size + (y_size / 2)) return false;
                yuv.nv12ToRgba(y_plane, buf[y_size..], self.w, self.h, y_stride, chroma_stride, out);
                return true;
            },
            COLOR_I420 => {
                const c_size = (@as(usize, y_stride / 2)) * (sh / 2);
                if (buf.len < y_size + 2 * c_size) return false;
                const u = buf[y_size .. y_size + c_size];
                const v = buf[y_size + c_size ..];
                yuv.i420ToRgba(y_plane, u, v, self.w, self.h, y_stride, y_stride / 2, out);
                return true;
            },
            else => return false, // Flexible / vendor format — next slice
        }
    }

    pub fn deinit(self: *AndroidVideoDecoder) void {
        _ = AMediaCodec_stop(self.codec);
        AMediaCodec_delete(self.codec);
        AMediaExtractor_delete(self.extractor);
    }
};
