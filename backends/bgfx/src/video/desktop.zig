//! Desktop video decoder for the in-engine video path (FP#549 Path A Half 2).
//!
//! Spawns `ffmpeg` (via libc `popen`) to decode an H.264 mp4 into a stream of
//! raw RGBA8 frames. Same decoder *interface* as the Android `AMediaCodec`
//! decoder (`width`/`height`/`decodeFrame`/`deinit`) so the platform-agnostic
//! `VideoPlayer` (`player.zig`) can drive either — ffmpeg here, MediaCodec on
//! Android — feeding frames into the same bgfx dynamic texture.
//!
//! ffmpeg runs without `-re` (decodes ahead; the OS pipe provides backpressure),
//! so the caller paces reads with its own fps timer and the render loop never
//! blocks on the pipe. ffmpeg also does the YUV→RGBA conversion (`-pix_fmt rgba`).

const std = @import("std");

extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(stream: *anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn system(command: [*:0]const u8) c_int;

pub const VideoDecoder = struct {
    stream: *anyopaque, // libc FILE*
    w: u32,
    h: u32,
    frame_bytes: usize,

    /// Generate a self-contained H.264 test clip (so demos need no bundled asset).
    pub fn generateTestClip(allocator: std.mem.Allocator, path: []const u8, w: u32, h: u32) !void {
        const cmd = try std.fmt.allocPrintSentinel(allocator,
            "ffmpeg -hide_banner -loglevel error -y -f lavfi " ++
            "-i testsrc2=duration=6:size={d}x{d}:rate=24 " ++
            "-c:v libx264 -pix_fmt yuv420p {s}",
            .{ w, h, path }, 0);
        defer allocator.free(cmd);
        if (system(cmd.ptr) != 0) return error.FfmpegEncodeFailed;
    }

    /// Decode `path` into a looping RGBA8 frame stream at `w`×`h`.
    pub fn open(allocator: std.mem.Allocator, path: []const u8, w: u32, h: u32) !VideoDecoder {
        const cmd = try std.fmt.allocPrintSentinel(allocator,
            "ffmpeg -hide_banner -loglevel error -stream_loop -1 -i {s} " ++
            "-f rawvideo -pix_fmt rgba -s {d}x{d} pipe:1",
            .{ path, w, h }, 0);
        defer allocator.free(cmd);
        const stream = popen(cmd.ptr, "r") orelse return error.PopenFailed;
        return .{ .stream = stream, .w = w, .h = h, .frame_bytes = @as(usize, w) * h * 4 };
    }

    pub fn width(self: *const VideoDecoder) u32 {
        return self.w;
    }
    pub fn height(self: *const VideoDecoder) u32 {
        return self.h;
    }

    /// Read one RGBA8 frame into `buf` (width*height*4 bytes). False on stream end.
    pub fn decodeFrame(self: *VideoDecoder, buf: []u8) bool {
        if (buf.len != self.frame_bytes) return false;
        var off: usize = 0;
        while (off < buf.len) {
            const n = fread(buf.ptr + off, 1, buf.len - off, self.stream);
            if (n == 0) return false;
            off += n;
        }
        return true;
    }

    pub fn deinit(self: *VideoDecoder) void {
        _ = pclose(self.stream);
    }
};
