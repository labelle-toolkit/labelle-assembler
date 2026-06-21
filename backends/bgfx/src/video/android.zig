//! Android H.264 decoder via the NDK Media APIs — Path A Half 2, Android target
//! (Flying-Platform/flying-platform-labelle#549).
//!
//! Uses `AMediaExtractor` (demux the mp4 container) + `AMediaCodec` (hardware
//! H.264 decode) rendering into an **`AImageReader` (YUV_420_888)**, then reads
//! the frame's Y/U/V planes via `AImage` and converts to RGBA8 (`video/yuv.zig`)
//! for the bgfx dynamic texture (`updateTexture`, Half 1) — the same sink the
//! desktop ffmpeg pipe feeds.
//!
//! Why ImageReader and not raw ByteBuffer: real devices emit a wide range of
//! `AMediaCodec` color formats — planar, semi-planar, and especially
//! `COLOR_FormatYUV420Flexible` / proprietary *tiled* layouts that aren't
//! CPU-readable as-is. Rendering into a YUV_420_888 `AImageReader` normalizes
//! all of them into Y/U/V planes with explicit row/pixel strides, so one
//! `yuv.yuv420ToRgba` converts every device. (A ByteBuffer/NV12-only path
//! worked on the emulator but would black-screen many real handsets.)
//!
//! These are pure C NDK APIs (no JNI/Java), so they're called from Zig via
//! `extern`. The decoder is **comptime-gated to the Android ABI**: off Android
//! it resolves to an `Unsupported` stub so host/desktop builds never reference
//! the NDK symbols.
//!
//! Verified on-device: the `apk/` NativeActivity harness decodes a real H.264
//! clip on a Pixel-7 API-34 emulator (arm64) — extract → AMediaCodec → AImage
//! YUV_420_888 → RGBA, 10 frames, RESULT PASS. (AMediaCodec needs a real app
//! process for its Binder/JVM context, which is why the bare-CLI harness can't
//! get past codec creation — see `apk/native.zig`.) The host-testable colour
//! conversion lives in `yuv.zig`.
//!
//! Known follow-ups (next slices):
//!   - crop rectangle (the AImage may be padded beyond w×h on some devices).
//!   - on a real handset (vs the emulator) confirm a Flexible/tiled clip; the
//!     plane-stride path is built for it but only emulator-verified so far.
//!   - audio-track decode (this is video-only) + AAudio output device (#306).

const std = @import("std");
const builtin = @import("builtin");
const yuv = @import("yuv.zig");

extern fn close(c_int) c_int;

const is_android = builtin.abi == .android or builtin.abi == .androideabi;

/// Public decoder type. Real implementation on Android; a stub elsewhere so the
/// engine compiles on every backend/target.
pub const VideoDecoder = if (is_android) AndroidVideoDecoder else UnsupportedDecoder;

pub const Error = error{
    Unsupported,
    NoVideoTrack,
    UnsupportedColorFormat,
    DecoderInit,
    MissingDimensions,
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
    pub fn decodeFrame(_: *UnsupportedDecoder, _: []u8) ?f64 {
        return null;
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
    const ImageReader = opaque {};
    const Image = opaque {};
    const Window = opaque {};

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
    extern fn AMediaExtractor_getSampleTime(*Extractor) i64;
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

    // NDK ImageReader / Image (media/NdkImageReader.h, NdkImage.h). The decoder
    // renders into the reader's surface; `AImage` then exposes whatever the
    // device produced as YUV_420_888 Y/U/V planes with row + pixel strides — so
    // any vendor / `COLOR_FormatYUV420Flexible` / tiled layout reads uniformly.
    // This is the robustness fix vs the old ByteBuffer/NV12-only path.
    extern fn AImageReader_new(width: i32, height: i32, format: i32, max_images: i32, reader: *?*ImageReader) i32;
    extern fn AImageReader_getWindow(*ImageReader, window: *?*Window) i32;
    extern fn AImageReader_acquireLatestImage(*ImageReader, image: *?*Image) i32;
    extern fn AImageReader_delete(*ImageReader) void;
    const CropRect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
    extern fn AImage_getNumberOfPlanes(*const Image, num: *i32) i32;
    extern fn AImage_getPlaneData(*const Image, plane: i32, data: *?[*]u8, len: *i32) i32;
    extern fn AImage_getPlaneRowStride(*const Image, plane: i32, stride: *i32) i32;
    extern fn AImage_getPlanePixelStride(*const Image, plane: i32, stride: *i32) i32;
    extern fn AImage_getCropRect(*const Image, rect: *CropRect) i32;
    extern fn AImage_getTimestamp(*const Image, ts: *i64) i32;
    extern fn AImage_delete(*Image) void;

    const AMEDIA_OK: i32 = 0;
    const FLAG_EOS: u32 = 4; // AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM
    const INFO_TRY_AGAIN: isize = -1;
    const INFO_FORMAT_CHANGED: isize = -2;
    const INFO_BUFFERS_CHANGED: isize = -3;
    const FORMAT_YUV_420_888: i32 = 0x23; // AIMAGE_FORMAT_YUV_420_888

    // AMediaFormat keys.
    const KEY_MIME: [*:0]const u8 = "mime";
    const KEY_WIDTH: [*:0]const u8 = "width";
    const KEY_HEIGHT: [*:0]const u8 = "height";
    // Crop rectangle keys (present when the decoder pads the coded size up to a
    // hardware alignment, e.g. 1080 → 1088): the display frame is the *inclusive*
    // crop rect, so display_w = right - left + 1, display_h = bottom - top + 1.
    const KEY_CROP_LEFT: [*:0]const u8 = "crop-left";
    const KEY_CROP_TOP: [*:0]const u8 = "crop-top";
    const KEY_CROP_RIGHT: [*:0]const u8 = "crop-right";
    const KEY_CROP_BOTTOM: [*:0]const u8 = "crop-bottom";

    extractor: *Extractor,
    codec: *Codec,
    reader: *ImageReader,
    // The decoder OWNS this fd (handed over by `backend.zig` from
    // `AAsset_openFileDescriptor64`): it's `close()`d in `deinit` so loop/replay
    // can't leak a descriptor. `backend.zig` must NOT close it.
    fd: c_int,
    w: u32,
    h: u32,
    input_done: bool,

    /// Open a video stream from a file descriptor (the APK asset fd from
    /// `AAsset_openFileDescriptor`, with its offset/length). Selects the first
    /// `video/*` track and configures a hardware decoder in ByteBuffer mode.
    pub fn openFd(_: std.mem.Allocator, fd: c_int, offset: i64, length: i64) Error!AndroidVideoDecoder {
        // Ownership transfers here: the decoder now owns `fd`. On any error path
        // close it (the returned struct never gets built); on success the field
        // takes over and `deinit` closes it. backend.zig must not close it.
        errdefer _ = close(fd);
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
        while (track < n) : (track += 1) {
            const fmt = AMediaExtractor_getTrackFormat(ex, track) orelse continue;
            defer AMediaFormat_delete(fmt);
            var m: [*:0]const u8 = undefined;
            if (!AMediaFormat_getString(fmt, KEY_MIME, &m)) continue;
            const span = std.mem.span(m);
            if (!std.mem.startsWith(u8, span, "video/")) continue;
            if (span.len + 1 > mime_buf.len) continue;
            // Require real dimensions: a missing width/height key would leave
            // w/h at 0, giving a 1×1 ImageReader and a zero-sized texture.
            if (!AMediaFormat_getInt32(fmt, KEY_WIDTH, &w)) return error.MissingDimensions;
            if (!AMediaFormat_getInt32(fmt, KEY_HEIGHT, &h)) return error.MissingDimensions;
            @memcpy(mime_buf[0..span.len], span);
            mime_buf[span.len] = 0;
            mime_len = span.len;
            found = true;
            break;
        }
        if (!found) return error.NoVideoTrack;
        const mime: [*:0]const u8 = mime_buf[0..mime_len :0].ptr;
        if (AMediaExtractor_selectTrack(ex, track) != AMEDIA_OK) return error.DecoderInit;

        // Output to a YUV_420_888 ImageReader (format-agnostic, CPU-readable).
        var reader_opt: ?*ImageReader = null;
        if (AImageReader_new(@max(w, 1), @max(h, 1), FORMAT_YUV_420_888, 4, &reader_opt) != AMEDIA_OK)
            return error.DecoderInit;
        const reader = reader_opt orelse return error.DecoderInit;
        errdefer AImageReader_delete(reader);
        var window_opt: ?*Window = null;
        if (AImageReader_getWindow(reader, &window_opt) != AMEDIA_OK) return error.DecoderInit;
        const window = window_opt orelse return error.DecoderInit;

        const codec = AMediaCodec_createDecoderByType(mime) orelse return error.DecoderInit;
        errdefer AMediaCodec_delete(codec);
        const cfg_fmt = AMediaExtractor_getTrackFormat(ex, track) orelse return error.DecoderInit;
        defer AMediaFormat_delete(cfg_fmt);
        // Render into the ImageReader's surface (decoder normalizes its vendor
        // format to YUV_420_888 by the time AImage exposes the planes).
        if (AMediaCodec_configure(codec, cfg_fmt, @ptrCast(window), null, 0) != AMEDIA_OK)
            return error.DecoderInit;
        if (AMediaCodec_start(codec) != AMEDIA_OK) return error.DecoderInit;

        return .{
            .extractor = ex,
            .codec = codec,
            .reader = reader,
            .fd = fd,
            .w = @intCast(@max(w, 0)),
            .h = @intCast(@max(h, 0)),
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
    /// `out` (width*height*4 bytes). Returns the frame's presentation timestamp
    /// in seconds (for A/V sync), or null if no frame was produced this call.
    /// Feeds at most one input sample per call and drains one output buffer.
    pub fn decodeFrame(self: *AndroidVideoDecoder, out: []u8) ?f64 {
        if (out.len != @as(usize, self.w) * self.h * 4) return null;

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
                        // Tag the sample with the extractor's current presentation
                        // time (clamped ≥ 0) for PTS accuracy — read BEFORE advance.
                        const sample_us = AMediaExtractor_getSampleTime(self.extractor);
                        const time_us: u64 = @intCast(@max(sample_us, 0));
                        _ = AMediaCodec_queueInputBuffer(self.codec, idx, 0, @intCast(n), time_us, 0);
                        _ = AMediaExtractor_advance(self.extractor);
                    }
                }
            }
        }

        // -- Drain output → render decoded frames into the ImageReader surface.
        var info: BufferInfo = undefined;
        const out_idx = AMediaCodec_dequeueOutputBuffer(self.codec, &info, 2000);
        if (out_idx == INFO_FORMAT_CHANGED) {
            self.refreshFormat();
            return null;
        }
        if (out_idx >= 0) {
            // render = true: send the frame to the ImageReader's surface.
            _ = AMediaCodec_releaseOutputBuffer(self.codec, @intCast(out_idx), true);
        }

        // -- Acquire the most recent rendered frame as a YUV_420_888 AImage.
        // The render is asynchronous, so an image may not be ready every call;
        // the caller's catch-up loop retries.
        var img_opt: ?*Image = null;
        if (AImageReader_acquireLatestImage(self.reader, &img_opt) != AMEDIA_OK) return null;
        const img = img_opt orelse return null;
        defer AImage_delete(img);
        if (!self.convertImage(img, out)) return null;
        var ts_ns: i64 = 0;
        _ = AImage_getTimestamp(img, &ts_ns);
        return @as(f64, @floatFromInt(ts_ns)) / 1_000_000_000.0; // PTS seconds
    }

    /// Refresh w/h after an output-format change (emitted once before the first
    /// frame).
    ///
    /// Hardware decoders report the *aligned/coded* width/height in the output
    /// format — rounded up to a 16/32-pixel multiple (e.g. 1080 → 1088) — which
    /// is NOT the real display size. Overwriting `self.w`/`self.h` with those
    /// would mis-size the texture and corrupt rendering. So we only update the
    /// reported dimensions from the *crop rectangle* (the true display frame, an
    /// inclusive rect → w = right-left+1, h = bottom-top+1); absent a crop rect we
    /// KEEP the display dimensions read at `openFd` time. The aligned size still
    /// governs the plane strides used when reading the buffer, but `width()`/
    /// `height()` and the ImageReader/texture must stay the real video size.
    fn refreshFormat(self: *AndroidVideoDecoder) void {
        const fmt = AMediaCodec_getOutputFormat(self.codec) orelse return;
        defer AMediaFormat_delete(fmt);
        var left: i32 = 0;
        var top: i32 = 0;
        var right: i32 = 0;
        var bottom: i32 = 0;
        const have_crop = AMediaFormat_getInt32(fmt, KEY_CROP_LEFT, &left) and
            AMediaFormat_getInt32(fmt, KEY_CROP_TOP, &top) and
            AMediaFormat_getInt32(fmt, KEY_CROP_RIGHT, &right) and
            AMediaFormat_getInt32(fmt, KEY_CROP_BOTTOM, &bottom);
        if (have_crop and right >= left and bottom >= top) {
            self.w = @intCast(right - left + 1);
            self.h = @intCast(bottom - top + 1);
        }
        // No crop rect → keep the openFd display dimensions; do NOT adopt the
        // aligned width/height the format would otherwise report.
    }

    /// Convert a YUV_420_888 AImage to RGBA8. The plane row/pixel strides make
    /// this format-agnostic — planar, semi-planar, and vendor/Flexible layouts
    /// all read through the same `yuv.yuv420ToRgba`.
    fn convertImage(self: *AndroidVideoDecoder, img: *Image, out: []u8) bool {
        var num: i32 = 0;
        if (AImage_getNumberOfPlanes(img, &num) != AMEDIA_OK or num < 3) return false;

        var yd: ?[*]u8 = null;
        var ud: ?[*]u8 = null;
        var vd: ?[*]u8 = null;
        var yl: i32 = 0;
        var ul: i32 = 0;
        var vl: i32 = 0;
        if (AImage_getPlaneData(img, 0, &yd, &yl) != AMEDIA_OK) return false;
        if (AImage_getPlaneData(img, 1, &ud, &ul) != AMEDIA_OK) return false;
        if (AImage_getPlaneData(img, 2, &vd, &vl) != AMEDIA_OK) return false;
        const yp = yd orelse return false;
        const up = ud orelse return false;
        const vp = vd orelse return false;
        if (yl <= 0 or ul <= 0 or vl <= 0) return false;

        var y_row: i32 = 0;
        var uv_row: i32 = 0;
        var y_px: i32 = 0;
        var uv_px: i32 = 0;
        _ = AImage_getPlaneRowStride(img, 0, &y_row);
        _ = AImage_getPlaneRowStride(img, 1, &uv_row);
        _ = AImage_getPlanePixelStride(img, 0, &y_px);
        _ = AImage_getPlanePixelStride(img, 1, &uv_px);
        const ys: u32 = @intCast(@max(y_row, 1));
        const yx: u32 = @intCast(@max(y_px, 1));
        const us: u32 = @intCast(@max(uv_row, 1));
        const ux: u32 = @intCast(@max(uv_px, 1));

        // Crop rect: the buffer may be padded beyond the display frame (e.g.
        // 1080 → 1088). Offset each plane to the crop's top-left so we sample the
        // real frame, not alignment padding. Defaults to (0,0) when absent.
        var crop: CropRect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = AImage_getCropRect(img, &crop);
        const cl: u32 = @intCast(@max(crop.left, 0));
        const ct: u32 = @intCast(@max(crop.top, 0));
        const y_off: usize = @as(usize, ct) * ys + @as(usize, cl) * yx;
        const uv_off: usize = @as(usize, ct / 2) * us + @as(usize, cl / 2) * ux;
        const yl_u: usize = @intCast(yl);
        const ul_u: usize = @intCast(ul);
        const vl_u: usize = @intCast(vl);
        if (y_off >= yl_u or uv_off >= ul_u or uv_off >= vl_u) return false;

        yuv.yuv420ToRgba(
            yp[y_off..yl_u],
            ys,
            yx,
            up[uv_off..ul_u],
            vp[uv_off..vl_u],
            us,
            ux,
            self.w,
            self.h,
            out,
        );
        return true;
    }

    pub fn deinit(self: *AndroidVideoDecoder) void {
        _ = AMediaCodec_stop(self.codec);
        AMediaCodec_delete(self.codec);
        AImageReader_delete(self.reader);
        AMediaExtractor_delete(self.extractor);
        // The decoder owns the asset fd (see the struct field comment); release
        // it so loop/replay can't leak descriptors. backend.zig must not close it.
        _ = close(self.fd);
    }
};
