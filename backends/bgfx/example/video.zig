//! Minimal desktop video decoder for the bgfx example — Path A "decode half"
//! (Flying-Platform/flying-platform-labelle#549).
//!
//! Spawns `ffmpeg` (via libc `popen`) to decode an H.264 mp4 into a stream of
//! raw RGBA8 frames on stdout, which the example feeds into the Half-1 dynamic
//! texture. This proves a real H.264 → RGBA → bgfx-texture path end-to-end on
//! desktop **without linking libav or writing a YUV→RGBA shader** — ffmpeg does
//! the demux, decode, and `-pix_fmt rgba` colour conversion.
//!
//! The production decoders (libavcodec on desktop, AMediaCodec on Android) feed
//! `updateTexture` the exact same way; only the frame *source* changes.
//!
//! libc `popen`/`fread` is used rather than `std.process.Child` because Zig
//! 0.16 threads its new `Io` interface through child-process spawn/kill/wait;
//! libc keeps this spike dependency-light (the example already links libc for
//! its WAV/texture file IO).
//!
//! Pacing: ffmpeg is launched WITHOUT `-re`, so it decodes ahead and the OS
//! pipe stays full (ffmpeg blocks on a full pipe — natural backpressure). The
//! caller paces reads with its own ~fps timer, so the 60 fps render loop never
//! blocks waiting on the pipe.

const std = @import("std");

// libc process/stream IO (the example already links libc).
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(stream: *anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn system(command: [*:0]const u8) c_int;

pub const VideoPipe = struct {
    stream: *anyopaque, // libc FILE*
    width: u32,
    height: u32,
    frame_bytes: usize,

    /// Generate a self-contained H.264 test clip at `path` so the example has
    /// real *encoded* video to decode without bundling a binary asset.
    /// Synchronous. Returns error if ffmpeg is missing or fails.
    pub fn generateTestClip(allocator: std.mem.Allocator, path: []const u8, w: u32, h: u32) !void {
        const cmd = try std.fmt.allocPrintSentinel(allocator,
            "ffmpeg -hide_banner -loglevel error -y -f lavfi " ++
            "-i testsrc2=duration=6:size={d}x{d}:rate=24 " ++
            "-c:v libx264 -pix_fmt yuv420p {s}",
            .{ w, h, path },
            0,
        );
        defer allocator.free(cmd);
        if (system(cmd.ptr) != 0) return error.FfmpegEncodeFailed;
    }

    /// Spawn ffmpeg to decode `path` into an endlessly-looping stream of RGBA8
    /// frames at `w`×`h`, delivered on the pipe. Caller reads via `readFrame`.
    pub fn open(allocator: std.mem.Allocator, path: []const u8, w: u32, h: u32) !VideoPipe {
        const cmd = try std.fmt.allocPrintSentinel(allocator,
            "ffmpeg -hide_banner -loglevel error -stream_loop -1 -i {s} " ++
            "-f rawvideo -pix_fmt rgba -s {d}x{d} pipe:1",
            .{ path, w, h },
            0,
        );
        defer allocator.free(cmd);

        const stream = popen(cmd.ptr, "r") orelse return error.PopenFailed;
        return .{
            .stream = stream,
            .width = w,
            .height = h,
            .frame_bytes = @as(usize, w) * @as(usize, h) * 4,
        };
    }

    /// Read exactly one RGBA8 frame into `buf` (must be width*height*4 bytes).
    /// Returns false on stream end / short read.
    pub fn readFrame(self: *VideoPipe, buf: []u8) bool {
        if (buf.len != self.frame_bytes) return false;
        var off: usize = 0;
        while (off < buf.len) {
            const n = fread(buf.ptr + off, 1, buf.len - off, self.stream);
            if (n == 0) return false; // EOF or error
            off += n;
        }
        return true;
    }

    pub fn deinit(self: *VideoPipe) void {
        _ = pclose(self.stream);
    }
};
