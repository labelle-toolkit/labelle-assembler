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

/// Single-quote a path for safe interpolation into a `/bin/sh` command, so paths
/// with spaces (or shell metacharacters) work and can't be an injection surface.
/// Wraps the whole path in `'…'` and escapes any embedded single quote as the
/// standard `'\''` sequence (close-quote, escaped quote, re-open-quote). Caller
/// owns the returned buffer.
fn shellQuote(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '\'');
    for (path) |c| {
        if (c == '\'') {
            try buf.appendSlice(allocator, "'\\''");
        } else {
            try buf.append(allocator, c);
        }
    }
    try buf.append(allocator, '\'');
    return buf.toOwnedSlice(allocator);
}

/// Probe a clip's native pixel dimensions + frame rate via `ffprobe`, so the
/// VideoBackend can open a video by name without the caller specifying a size.
/// Returns null if ffprobe is unavailable or the output can't be parsed.
pub const Info = struct { w: u32, h: u32, fps: f32 };
pub fn probe(allocator: std.mem.Allocator, path: []const u8) ?Info {
    const qpath = shellQuote(allocator, path) catch return null;
    defer allocator.free(qpath);
    const cmd = std.fmt.allocPrintSentinel(allocator,
        "ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate " ++
        "-of csv=p=0:s=x {s}",
        .{qpath}, 0) catch return null;
    defer allocator.free(cmd);
    const stream = popen(cmd.ptr, "r") orelse return null;
    defer _ = pclose(stream);
    var buf: [128]u8 = undefined;
    const n = fread(&buf, 1, buf.len - 1, stream);
    if (n == 0) return null;
    // Output like "1920x1080x24/1"
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, buf[0..n], " \n\r\t"), 'x');
    const w = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const h = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const rate = it.next() orelse return null; // "num/den"
    var rit = std.mem.splitScalar(u8, rate, '/');
    const num = std.fmt.parseFloat(f32, rit.next() orelse "24") catch 24;
    const den = std.fmt.parseFloat(f32, rit.next() orelse "1") catch 1;
    const fps = if (den > 0) num / den else 24;
    if (w == 0 or h == 0) return null;
    return .{ .w = w, .h = h, .fps = if (fps > 0) fps else 24 };
}

pub const VideoDecoder = struct {
    stream: *anyopaque, // libc FILE*
    w: u32,
    h: u32,
    frame_bytes: usize,
    fps: f32,
    frame_index: u64 = 0, // for the nominal CFR presentation timestamp
    eof_flag: bool = false, // set once the pipe drains (stream end)
    path_buf: [512]u8 = undefined, // stored for replay() (re-spawn)
    path_len: usize = 0,

    /// Generate a self-contained H.264 test clip *with an audio track* (a 440 Hz
    /// sine), so demos need no bundled asset and can exercise the audio path.
    pub fn generateTestClip(allocator: std.mem.Allocator, path: []const u8, w: u32, h: u32) !void {
        const qpath = try shellQuote(allocator, path);
        defer allocator.free(qpath);
        const cmd = try std.fmt.allocPrintSentinel(allocator,
            "ffmpeg -hide_banner -loglevel error -y " ++
            "-f lavfi -i testsrc2=duration=6:size={d}x{d}:rate=24 " ++
            "-f lavfi -i sine=frequency=440:duration=6 " ++
            "-c:v libx264 -pix_fmt yuv420p -c:a aac -shortest {s}",
            .{ w, h, qpath }, 0);
        defer allocator.free(cmd);
        if (system(cmd.ptr) != 0) return error.FfmpegEncodeFailed;
    }

    /// Extract the clip's audio track to a 48 kHz stereo s16 WAV — the format
    /// labelle's `audio.loadMusic` decodes. Returns error if the clip has no
    /// audio or ffmpeg fails. (Android's AMediaCodec path would decode the audio
    /// track in-process instead; see the #549 / #306 notes.)
    pub fn extractAudioWav(allocator: std.mem.Allocator, clip_path: []const u8, wav_path: []const u8) !void {
        const qclip = try shellQuote(allocator, clip_path);
        defer allocator.free(qclip);
        const qwav = try shellQuote(allocator, wav_path);
        defer allocator.free(qwav);
        const cmd = try std.fmt.allocPrintSentinel(allocator,
            "ffmpeg -hide_banner -loglevel error -y -i {s} " ++
            "-vn -ar 48000 -ac 2 -c:a pcm_s16le {s}",
            .{ qclip, qwav }, 0);
        defer allocator.free(cmd);
        if (system(cmd.ptr) != 0) return error.FfmpegAudioExtractFailed;
    }

    /// Decode the clip's audio track to in-memory 48 kHz stereo s16 PCM
    /// (interleaved) via ffmpeg — the format `audio.loadMusicFromPcm` wants.
    /// Returns null if the clip has no audio track or ffmpeg fails. Caller owns
    /// the returned slice. (Android decodes the track in-process with
    /// AMediaCodec instead — see video/android_audio.zig.)
    pub fn decodeAudioPcm(allocator: std.mem.Allocator, path: []const u8) ?[]i16 {
        const qpath = shellQuote(allocator, path) catch return null;
        defer allocator.free(qpath);
        const cmd = std.fmt.allocPrintSentinel(allocator,
            "ffmpeg -hide_banner -loglevel error -i {s} -vn -f s16le -ar 48000 -ac 2 pipe:1",
            .{qpath}, 0) catch return null;
        defer allocator.free(cmd);
        const stream = popen(cmd.ptr, "r") orelse return null;
        defer _ = pclose(stream);

        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(allocator);
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = fread(&buf, 1, buf.len, stream);
            if (n == 0) break;
            bytes.appendSlice(allocator, buf[0..n]) catch return null;
        }
        if (bytes.items.len < 2) return null; // no audio track decoded
        const n_samples = bytes.items.len / 2;
        const out = allocator.alloc(i16, n_samples) catch return null;
        @memcpy(std.mem.sliceAsBytes(out), bytes.items[0 .. n_samples * 2]);
        return out;
    }

    /// Decode `path` into a play-once RGBA8 frame stream at `w`×`h`. `fps` is the
    /// clip's frame rate, used to derive each frame's presentation timestamp.
    /// Plays once and reports end-of-stream (`eof`) so the engine can drive loop
    /// (via `replay`) or fire the finished event — rather than ffmpeg looping
    /// internally, which would hide the stream end.
    pub fn open(allocator: std.mem.Allocator, path: []const u8, w: u32, h: u32, fps: f32) !VideoDecoder {
        const stream = try spawn(allocator, path, w, h);
        var dec = VideoDecoder{ .stream = stream, .w = w, .h = h, .frame_bytes = @as(usize, w) * h * 4, .fps = fps };
        const n = @min(path.len, dec.path_buf.len);
        @memcpy(dec.path_buf[0..n], path[0..n]);
        dec.path_len = n;
        return dec;
    }

    fn spawn(allocator: std.mem.Allocator, path: []const u8, w: u32, h: u32) !*anyopaque {
        const qpath = try shellQuote(allocator, path);
        defer allocator.free(qpath);
        const cmd = try std.fmt.allocPrintSentinel(allocator,
            "ffmpeg -hide_banner -loglevel error -i {s} " ++
            "-f rawvideo -pix_fmt rgba -s {d}x{d} pipe:1",
            .{ qpath, w, h }, 0);
        defer allocator.free(cmd);
        return popen(cmd.ptr, "r") orelse error.PopenFailed;
    }

    pub fn eof(self: *const VideoDecoder) bool {
        return self.eof_flag;
    }

    /// Restart from the beginning by re-spawning ffmpeg (for engine-driven loop).
    pub fn replay(self: *VideoDecoder, allocator: std.mem.Allocator) void {
        const stream = spawn(allocator, self.path_buf[0..self.path_len], self.w, self.h) catch return;
        _ = pclose(self.stream);
        self.stream = stream;
        self.frame_index = 0;
        self.eof_flag = false;
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
            if (n == 0) {
                self.eof_flag = true;
                return null;
            }
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

test "decodeAudioPcm: decodes a clip's audio track to 48k stereo PCM" {
    const alloc = std.testing.allocator;
    const clip = "/tmp/labelle_audio_decode_test.mp4";
    // generateTestClip writes a 6 s clip with a 440 Hz sine audio track.
    try VideoDecoder.generateTestClip(alloc, clip, 320, 240);

    const pcm = VideoDecoder.decodeAudioPcm(alloc, clip) orelse return error.NoAudioDecoded;
    defer alloc.free(pcm);

    // ~6 s × 48000 × 2ch ≈ 576k samples — assert we got a substantial, even
    // (stereo-interleaved) buffer, not a stub/empty.
    try std.testing.expect(pcm.len > 48000);
    try std.testing.expectEqual(@as(usize, 0), pcm.len % 2);
    // The sine carries energy — it must not be all-silence.
    var nonzero: usize = 0;
    for (pcm) |s| {
        if (s != 0) nonzero += 1;
    }
    try std.testing.expect(nonzero > pcm.len / 4);
}
