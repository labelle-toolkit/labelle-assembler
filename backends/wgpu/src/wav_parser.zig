//! RIFF/WAVE parser for the wgpu audio backend.
//!
//! Extracted from `audio.zig` so the pure parsing step — which is
//! where the #12 integer-overflow bug lived — can be unit-tested with
//! crafted byte buffers instead of requiring real files on disk.
//!
//! Supports 16-bit PCM only (mono or stereo). Mono inputs are
//! duplicated to both output channels. Non-PCM formats, other bit
//! depths, and >2 channels are rejected with distinct error codes.
//!
//! The #12 fix: every `pos + size` / `offset + length` advance uses
//! `std.math.add(usize, ...)` plus a bounds check against the input
//! buffer. A malformed WAV that declares `chunk_size == 0xFFFFFFFF`
//! used to wrap `pos` on 32-bit hosts and either infinite-loop or
//! read out-of-bounds; it now returns `ChunkSizeOverflow` /
//! `ChunkExceedsBuffer`.
const std = @import("std");

pub const OUTPUT_CHANNELS: usize = 2;

pub const ParseError = error{
    /// Input too short to hold even the 12-byte RIFF/WAVE header.
    BufferTooSmall,
    /// First 4 bytes are not "RIFF".
    NotRiff,
    /// Bytes 8..12 are not "WAVE".
    NotWave,
    /// A chunk header's size + offset computation overflows `usize`.
    /// Regression guard for #12.
    ChunkSizeOverflow,
    /// A chunk header declares a size that runs past the end of the
    /// input buffer.
    ChunkExceedsBuffer,
    /// The "fmt " chunk is shorter than the 16 bytes we need.
    FmtChunkTooSmall,
    /// No "fmt " chunk was found before the end of the buffer.
    MissingFmtChunk,
    /// No "data" chunk was found before the end of the buffer.
    MissingDataChunk,
    /// Audio format is not PCM (WAVE format code 1).
    UnsupportedAudioFormat,
    /// Only 16-bit PCM is supported.
    UnsupportedBitDepth,
    /// Channel count is 0 or > 2.
    UnsupportedChannelCount,
    /// The allocator could not produce the output PCM buffer.
    OutOfMemory,
};

/// Parse a RIFF/WAVE byte buffer and return a newly-allocated slice
/// of interleaved stereo f32 PCM. Caller owns the returned slice and
/// frees it with the same allocator.
pub fn parseWav(allocator: std.mem.Allocator, buf: []const u8) ParseError![]f32 {
    // RIFF/WAVE header = 12 bytes: "RIFF" + u32 size + "WAVE".
    if (buf.len < 12) return ParseError.BufferTooSmall;
    if (!std.mem.eql(u8, buf[0..4], "RIFF")) return ParseError.NotRiff;
    if (!std.mem.eql(u8, buf[8..12], "WAVE")) return ParseError.NotWave;

    // Walk chunks starting at offset 12. Each chunk header is 8 bytes
    // (4-byte id + 4-byte size). The size field doesn't include the
    // header itself and the next chunk is 2-byte aligned (a pad byte
    // is inserted if the chunk data ends on an odd offset).
    var num_channels: u16 = 0;
    var bits_per_sample: u16 = 0;
    var fmt_found = false;
    var data_offset: usize = 0;
    var data_size: u32 = 0;
    var data_found = false;

    var pos: usize = 12;
    while (true) {
        // Enough room for the 8-byte chunk header?
        const header_end = std.math.add(usize, pos, 8) catch return ParseError.ChunkSizeOverflow;
        if (header_end > buf.len) break;

        const chunk_id = buf[pos..][0..4];
        const chunk_size = std.mem.readInt(u32, buf[pos + 4 ..][0..4], .little);
        const chunk_data_start = pos + 8;

        // The chunk's data region must fit inside `buf`. This is the
        // #12 guard: a crafted huge chunk_size used to wrap `pos`
        // silently on 32-bit and cause an infinite loop or OOB read.
        const chunk_data_end = std.math.add(usize, chunk_data_start, chunk_size) catch
            return ParseError.ChunkSizeOverflow;
        if (chunk_data_end > buf.len) return ParseError.ChunkExceedsBuffer;

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (chunk_size < 16) return ParseError.FmtChunkTooSmall;
            const fmt = buf[chunk_data_start..];
            const audio_format = std.mem.readInt(u16, fmt[0..2], .little);
            if (audio_format != 1) return ParseError.UnsupportedAudioFormat;
            num_channels = std.mem.readInt(u16, fmt[2..4], .little);
            bits_per_sample = std.mem.readInt(u16, fmt[14..16], .little);
            fmt_found = true;
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            data_offset = chunk_data_start;
            data_size = chunk_size;
            data_found = true;
        }

        if (fmt_found and data_found) break;

        // Advance to the next chunk. Chunks are 2-byte aligned, so
        // insert a pad byte if the data ends on an odd offset. Use
        // checked arithmetic for the pad too — on any edge case
        // `pos` must never wrap.
        var next_pos = chunk_data_end;
        if (next_pos % 2 != 0) {
            next_pos = std.math.add(usize, next_pos, 1) catch
                return ParseError.ChunkSizeOverflow;
        }
        pos = next_pos;
    }

    if (!fmt_found) return ParseError.MissingFmtChunk;
    if (!data_found) return ParseError.MissingDataChunk;
    if (bits_per_sample != 16) return ParseError.UnsupportedBitDepth;
    if (num_channels == 0 or num_channels > 2) return ParseError.UnsupportedChannelCount;

    // Clamp declared data size to what's actually in the buffer. We
    // already checked `data_offset + data_size <= buf.len` inside the
    // loop, so the @min is belt-and-suspenders for defensive reasons.
    const remaining = buf.len - data_offset;
    const actual_data_size: usize = @min(@as(usize, data_size), remaining);
    const raw_buf = buf[data_offset .. data_offset + actual_data_size];

    const bytes_per_sample: usize = 2; // 16-bit
    const sample_count: usize = actual_data_size / bytes_per_sample;
    const frame_count = sample_count / @as(usize, num_channels);

    // Output buffer is always interleaved stereo f32.
    const out_samples = frame_count * OUTPUT_CHANNELS;
    const pcm = allocator.alloc(f32, out_samples) catch return ParseError.OutOfMemory;
    errdefer allocator.free(pcm);

    var i: usize = 0;
    while (i < frame_count) : (i += 1) {
        var left: f32 = 0;
        var right: f32 = 0;
        const src_idx = i * @as(usize, num_channels);

        if (src_idx < sample_count) {
            const byte_off = src_idx * bytes_per_sample;
            if (byte_off + 1 < raw_buf.len) {
                const s16 = std.mem.readInt(i16, raw_buf[byte_off..][0..2], .little);
                left = @as(f32, @floatFromInt(s16)) / 32768.0;
            }
        }

        if (num_channels >= 2 and (src_idx + 1) < sample_count) {
            const byte_off = (src_idx + 1) * bytes_per_sample;
            if (byte_off + 1 < raw_buf.len) {
                const s16 = std.mem.readInt(i16, raw_buf[byte_off..][0..2], .little);
                right = @as(f32, @floatFromInt(s16)) / 32768.0;
            }
        } else {
            right = left; // Mono → duplicate into both channels.
        }

        pcm[i * OUTPUT_CHANNELS + 0] = left;
        pcm[i * OUTPUT_CHANNELS + 1] = right;
    }

    return pcm;
}

// ── Test helpers ─────────────────────────────────────────────────────

const testing = std.testing;

/// Build a valid minimal RIFF/WAVE byte stream with a single `fmt ` chunk
/// and a single `data` chunk. Caller owns the returned slice.
fn buildWav(
    allocator: std.mem.Allocator,
    channels: u16,
    bits_per_sample: u16,
    audio_format: u16,
    pcm_bytes: []const u8,
) ![]u8 {
    const fmt_chunk_size: u32 = 16;
    const data_chunk_size: u32 = @intCast(pcm_bytes.len);
    const total_size: u32 = 4 + (8 + fmt_chunk_size) + (8 + data_chunk_size);

    var buf: std.ArrayList(u8) = .{};
    // errdefer — the happy path returns via `toOwnedSlice`, which
    // hands `buf`'s storage to the caller. Only clean up if an
    // earlier `try` bails out before that transfer.
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "RIFF");
    try appendU32(&buf, allocator, total_size);
    try buf.appendSlice(allocator, "WAVE");

    // "fmt " chunk
    try buf.appendSlice(allocator, "fmt ");
    try appendU32(&buf, allocator, fmt_chunk_size);
    try appendU16(&buf, allocator, audio_format);
    try appendU16(&buf, allocator, channels);
    try appendU32(&buf, allocator, 44100); // sample rate
    // Cast to u32 before multiplying — 44100 > u16 max, so doing
    // the math in u16 overflows. byte_rate = sample_rate * channels * bytes_per_sample.
    const bytes_per_sample: u32 = @as(u32, bits_per_sample) / 8;
    try appendU32(&buf, allocator, 44100 * @as(u32, channels) * bytes_per_sample); // byte rate
    try appendU16(&buf, allocator, @intCast(@as(u32, channels) * bytes_per_sample)); // block align
    try appendU16(&buf, allocator, bits_per_sample);

    // "data" chunk
    try buf.appendSlice(allocator, "data");
    try appendU32(&buf, allocator, data_chunk_size);
    try buf.appendSlice(allocator, pcm_bytes);

    return buf.toOwnedSlice(allocator);
}

fn appendU16(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, v, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn appendU32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, v, .little);
    try buf.appendSlice(allocator, &bytes);
}

// ── Tests ────────────────────────────────────────────────────────────

test "parseWav rejects buffers shorter than the 12-byte header" {
    try testing.expectError(ParseError.BufferTooSmall, parseWav(testing.allocator, ""));
    try testing.expectError(ParseError.BufferTooSmall, parseWav(testing.allocator, "RIFF\x00\x00\x00\x00"));
}

test "parseWav rejects non-RIFF magic" {
    const bogus = "ABCD\x00\x00\x00\x00WAVE";
    try testing.expectError(ParseError.NotRiff, parseWav(testing.allocator, bogus));
}

test "parseWav rejects non-WAVE format" {
    const bogus = "RIFF\x00\x00\x00\x00OGG ";
    try testing.expectError(ParseError.NotWave, parseWav(testing.allocator, bogus));
}

test "parseWav regression for #12: chunk_size that overflows usize returns error" {
    // Header + a bogus chunk where chunk_size = 0xFFFFFFFF. The old
    // code did `pos = chunk_data_start + chunk_size` without a
    // checked add; on 32-bit this wrapped `pos` and infinite-looped
    // (or read out of bounds). On 64-bit it produced a huge `pos`
    // that just early-exited the loop but left us in an error state
    // without a clear failure. Now it's an explicit error.
    var buf = [_]u8{0} ** 20;
    @memcpy(buf[0..4], "RIFF");
    buf[4] = 0x10;
    buf[5] = 0x00;
    buf[6] = 0x00;
    buf[7] = 0x00;
    @memcpy(buf[8..12], "WAVE");
    // bogus chunk: id "fmt " + size 0xFFFFFFFF
    @memcpy(buf[12..16], "fmt ");
    buf[16] = 0xFF;
    buf[17] = 0xFF;
    buf[18] = 0xFF;
    buf[19] = 0xFF;

    const result = parseWav(testing.allocator, &buf);
    // Either ChunkExceedsBuffer (the add didn't overflow but the
    // size pointed past the end) or ChunkSizeOverflow (the add
    // overflowed on a 32-bit host). Both are acceptable regressions
    // for the underlying bug.
    try testing.expect(result == ParseError.ChunkExceedsBuffer or
        result == ParseError.ChunkSizeOverflow);
}

test "parseWav rejects chunk that runs past the end of the buffer" {
    var buf = [_]u8{0} ** 20;
    @memcpy(buf[0..4], "RIFF");
    buf[4] = 0x10;
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    // size = 1000 — well past the 20-byte buffer.
    buf[16] = 0xE8;
    buf[17] = 0x03;
    buf[18] = 0x00;
    buf[19] = 0x00;
    try testing.expectError(ParseError.ChunkExceedsBuffer, parseWav(testing.allocator, &buf));
}

test "parseWav rejects missing fmt chunk (only data present)" {
    // Valid header + data chunk with 0 bytes but no fmt chunk.
    var buf = [_]u8{0} ** 20;
    @memcpy(buf[0..4], "RIFF");
    buf[4] = 0x08;
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "data");
    buf[16] = 0x00; // size = 0
    try testing.expectError(ParseError.MissingFmtChunk, parseWav(testing.allocator, &buf));
}

test "parseWav rejects non-PCM audio format" {
    const wav = try buildWav(testing.allocator, 1, 16, 3, &[_]u8{}); // format 3 = IEEE float
    defer testing.allocator.free(wav);
    try testing.expectError(ParseError.UnsupportedAudioFormat, parseWav(testing.allocator, wav));
}

test "parseWav rejects 8-bit PCM" {
    const wav = try buildWav(testing.allocator, 1, 8, 1, &[_]u8{ 0x80, 0x80 });
    defer testing.allocator.free(wav);
    try testing.expectError(ParseError.UnsupportedBitDepth, parseWav(testing.allocator, wav));
}

test "parseWav rejects 24-bit PCM" {
    const wav = try buildWav(testing.allocator, 1, 24, 1, &[_]u8{ 0, 0, 0, 0, 0, 0 });
    defer testing.allocator.free(wav);
    try testing.expectError(ParseError.UnsupportedBitDepth, parseWav(testing.allocator, wav));
}

test "parseWav rejects zero channels" {
    const wav = try buildWav(testing.allocator, 0, 16, 1, &[_]u8{ 0, 0 });
    defer testing.allocator.free(wav);
    try testing.expectError(ParseError.UnsupportedChannelCount, parseWav(testing.allocator, wav));
}

test "parseWav rejects 5.1 channels" {
    const wav = try buildWav(testing.allocator, 6, 16, 1, &[_]u8{ 0, 0 });
    defer testing.allocator.free(wav);
    try testing.expectError(ParseError.UnsupportedChannelCount, parseWav(testing.allocator, wav));
}

test "parseWav accepts valid 16-bit mono and duplicates to stereo" {
    // Two mono samples: 16384 (~0.5) and -16384 (~-0.5).
    const pcm: [4]u8 = .{ 0x00, 0x40, 0x00, 0xC0 };
    const wav = try buildWav(testing.allocator, 1, 16, 1, &pcm);
    defer testing.allocator.free(wav);

    const out = try parseWav(testing.allocator, wav);
    defer testing.allocator.free(out);

    // 2 source samples → 2 stereo frames → 4 interleaved f32.
    try testing.expectEqual(@as(usize, 4), out.len);

    // First frame: mono sample 0x4000 = +16384 → +0.5
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[1], 0.0001);

    // Second frame: mono sample 0xC000 = -16384 → -0.5
    try testing.expectApproxEqAbs(@as(f32, -0.5), out[2], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -0.5), out[3], 0.0001);
}

test "parseWav accepts valid 16-bit stereo and keeps the channels separate" {
    // One stereo frame: L=16384 (+0.5), R=-16384 (-0.5).
    const pcm: [4]u8 = .{ 0x00, 0x40, 0x00, 0xC0 };
    const wav = try buildWav(testing.allocator, 2, 16, 1, &pcm);
    defer testing.allocator.free(wav);

    const out = try parseWav(testing.allocator, wav);
    defer testing.allocator.free(out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -0.5), out[1], 0.0001);
}
