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
    fps: f32,
    frame_index: u64 = 0, // for the nominal CFR presentation timestamp

    /// Generate a self-contained H.264 test clip *with an audio track* (a 440 Hz
    /// sine), so demos need no bundled asset and can exercise the audio path.
    pub fn generateTestClip(allocator: std.mem.Allocator, path: []const u8, w: u32, h: u32) !void {
        const cmd = try std.fmt.allocPrintSentinel(allocator,
            "ffmpeg -hide_banner -loglevel error -y " ++
            "-f lavfi -i testsrc2=duration=6:size={d}x{d}:rate=24 " ++
            "-f lavfi -i sine=frequency=440:duration=6 " ++
            "-c:v libx264 -pix_fmt yuv420p -c:a aac -shortest {s}",
            .{ w, h, path }, 0);
        defer allocator.free(cmd);
        if (system(cmd.ptr) != 0) return error.FfmpegEncodeFailed;
    }

    /// Extract the clip's audio track to a 48 kHz stereo s16 WAV — the format
    /// labelle's `audio.loadMusic` decodes. Returns error if the clip has no
    /// audio or ffmpeg fails. (Android's AMediaCodec path would decode the audio
    /// track in-process instead; see the #549 / #306 notes.)
    pub fn extractAudioWav(allocator: std.mem.Allocator, clip_path: []const u8, wav_path: []const u8) !void {
        const cmd = try std.fmt.allocPrintSentinel(allocator,
            "ffmpeg -hide_banner -loglevel error -y -i {s} " ++
            "-vn -ar 48000 -ac 2 -c:a pcm_s16le {s}",
            .{ clip_path, wav_path }, 0);
        defer allocator.free(cmd);
        if (system(cmd.ptr) != 0) return error.FfmpegAudioExtractFailed;
    }

    /// Decode `path` into a looping RGBA8 frame stream at `w`×`h`. `fps` is the
    /// clip's frame rate, used to derive each frame's presentation timestamp.
    pub fn open(allocator: std.mem.Allocator, path: []const u8, w: u32, h: u32, fps: f32) !VideoDecoder {
        const cmd = try std.fmt.allocPrintSentinel(allocator,
            "ffmpeg -hide_banner -loglevel error -stream_loop -1 -i {s} " ++
            "-f rawvideo -pix_fmt rgba -s {d}x{d} pipe:1",
            .{ path, w, h }, 0);
        defer allocator.free(cmd);
        const stream = popen(cmd.ptr, "r") orelse return error.PopenFailed;
        return .{ .stream = stream, .w = w, .h = h, .frame_bytes = @as(usize, w) * h * 4, .fps = fps };
    }

    pub fn width(self: *const VideoDecoder) u32 {
        return self.w;
    }
    pub fn height(self: *const VideoDecoder) u32 {
        return self.h;
    }

    /// Read one RGBA8 frame into `buf` (width*height*4 bytes). Returns the
    /// frame's presentation timestamp in seconds (nominal CFR: frame_index/fps),
    /// or null on stream end. ffmpeg rawvideo carries no timestamps, so for a
    /// constant-rate clip the index-derived PTS is exact; the A/V sync still
    /// runs off the audio master clock regardless.
    pub fn decodeFrame(self: *VideoDecoder, buf: []u8) ?f64 {
        if (buf.len != self.frame_bytes) return null;
        var off: usize = 0;
        while (off < buf.len) {
            const n = fread(buf.ptr + off, 1, buf.len - off, self.stream);
            if (n == 0) return null;
            off += n;
        }
        const pts = @as(f64, @floatFromInt(self.frame_index)) / @as(f64, self.fps);
        self.frame_index += 1;
        return pts;
    }

    pub fn deinit(self: *VideoDecoder) void {
        _ = pclose(self.stream);
    }
};
