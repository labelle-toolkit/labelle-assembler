//! Phase 4 audio decode surface (labelle-engine#447) — the OGG/WAV CPU
//! decoder the assembler's `writeAudioBackendWiring` codegen calls.
//!
//! The mixer + slot management + i16 PCM playback now live in the shared
//! `labelle-audio` package (Phase 2 fan-out); this file keeps ONLY the pure
//! CPU decode that the shared mixer does not provide. The shared mixer's
//! `loadSoundFromMemory` decodes WAV bytes (i16) but has no OGG path, while
//! the assembler's audio-asset wiring needs OGG (stb_vorbis) support — so the
//! `decodeAudio(file_type, data, alloc)` surface here (dr_wav + stb_vorbis →
//! interleaved i16 `DecodedAudio`) stays, and the resulting i16 PCM is handed
//! to the shared mixer via `loadSoundFromPcm` (see `audio.zig`'s `uploadSound`).
//!
//! Decode/upload split mirrors the gfx image + font paths: pure CPU decode
//! here (worker-thread safe — stb_vorbis / dr_wav only touch the input bytes +
//! the allocator-owned PCM buffer); audio-device-side registration on the main
//! thread lives in `audio.zig`'s `uploadSound` (shared-mixer slot insert).
const std = @import("std");

const drwav = @cImport({
    @cInclude("dr_wav.h");
});

// stb_vorbis is single-file (the .c IS the API + implementation). We pull just
// the prototypes for the handful of decode functions we call here through a
// hand-rolled header — `@cInclude("stb_vorbis.c")` would compile the
// implementation a second time and collide with the C-source-side translation
// unit on every `stb_vorbis_*` symbol.
const stbv = @cImport({
    @cInclude("stb_vorbis_decl.h");
});

/// CPU-decoded interleaved-PCM audio. Field layout matches
/// `labelle-engine/audio_backend/src/backend.zig`'s `DecodedAudio` so the
/// assembler's `writeAudioBackendWiring` field-by-field copy lands on a stable
/// shape (`samples` / `sample_rate` / `channels`).
pub const DecodedAudio = struct {
    /// Interleaved PCM samples. Length == `frame_count * channels`. Owned by
    /// the allocator passed to `decodeAudio`; the caller frees via that same
    /// allocator on both the success and discard paths.
    samples: []i16,
    sample_rate: u32,
    channels: u8,
};

/// Opaque sound handle for the Phase 4 loader. Kept as an `extern struct`
/// with the same `{ slot_index, generation }` shape (size 8, align 4) the
/// assembler's slot table marshals through — the test in `tests.zig` locks
/// this layout. `slot_index` now carries the shared mixer's slot id; the
/// `generation` field is retained for ABI stability (the assembler's adapter
/// tracks its own per-slot generation and ignores this one).
pub const Sound = extern struct {
    slot_index: u32,
    generation: u32,
};

/// Pure CPU decode — worker-thread safe.
///
/// Dispatches on `file_type`:
///   - "wav" → `dr_wav` (drwav_init_memory + drwav_read_pcm_frames_s16).
///     Handles every PCM bit-depth + IEEE float internally.
///   - "ogg" → `stb_vorbis` (open_memory + get_samples_short_interleaved).
///     Single-allocation streaming decode into a caller-owned i16 buffer.
///
/// The returned `samples` slice is from `allocator` — caller frees on BOTH
/// success and discard paths.
pub fn decodeAudio(
    file_type: [:0]const u8,
    data: []const u8,
    allocator: std.mem.Allocator,
) !DecodedAudio {
    if (data.len == 0) return error.AudioDecodeFailed;

    if (std.mem.eql(u8, file_type, "wav")) return decodeWav(data, allocator);
    if (std.mem.eql(u8, file_type, "ogg")) return decodeOgg(data, allocator);
    return error.UnsupportedAudioFormat;
}

fn decodeWav(data: []const u8, allocator: std.mem.Allocator) !DecodedAudio {
    var wav: drwav.drwav = undefined;
    if (drwav.drwav_init_memory(&wav, data.ptr, data.len, null) == 0) {
        return error.AudioDecodeFailed;
    }
    defer _ = drwav.drwav_uninit(&wav);

    const total_frames: usize = @intCast(wav.totalPCMFrameCount);
    const channels: u8 = @intCast(wav.channels);
    if (total_frames == 0 or channels == 0) return error.AudioDecodeFailed;

    // Guard against 32-bit (incl. wasm32) `usize` wraparound on the
    // frame × channel multiply — a wrap would alloc an undersized buffer that
    // drwav happily writes past.
    const total_samples = std.math.mul(usize, total_frames, channels) catch return error.AudioTooLarge;
    const samples = try allocator.alloc(i16, total_samples);
    errdefer allocator.free(samples);

    const got = drwav.drwav_read_pcm_frames_s16(&wav, total_frames, samples.ptr);
    // Treat short reads as failures: the trailing samples are uninitialised, so
    // emitting the buffer would mix garbage into the output. `errdefer` above
    // frees the partial buffer.
    if (got < total_frames) return error.AudioDecodeFailed;

    return .{
        .samples = samples,
        .sample_rate = @intCast(wav.sampleRate),
        .channels = channels,
    };
}

fn decodeOgg(data: []const u8, allocator: std.mem.Allocator) !DecodedAudio {
    var err: c_int = 0;
    const vorbis = stbv.stb_vorbis_open_memory(
        data.ptr,
        @intCast(data.len),
        &err,
        null,
    );
    if (vorbis == null) return error.AudioDecodeFailed;
    defer stbv.stb_vorbis_close(vorbis);

    const info = stbv.stb_vorbis_get_info(vorbis);
    const channels: u8 = @intCast(info.channels);
    const sample_rate: u32 = @intCast(info.sample_rate);
    if (channels == 0) return error.AudioDecodeFailed;

    const total_samples_c = stbv.stb_vorbis_stream_length_in_samples(vorbis);
    const total_frames: usize = @intCast(total_samples_c);
    if (total_frames == 0) return error.AudioDecodeFailed;

    // Guard against 32-bit (incl. wasm32) `usize` wraparound on the
    // frame × channel multiply — a wrap would alloc an undersized buffer that
    // stb_vorbis happily writes past.
    const total_samples = std.math.mul(usize, total_frames, channels) catch return error.AudioTooLarge;
    const samples = try allocator.alloc(i16, total_samples);
    errdefer allocator.free(samples);

    // `get_samples_short_interleaved` takes (channels, dest, dest_len_in_shorts)
    // and returns the number of FRAMES decoded (or 0/negative on error).
    const got = stbv.stb_vorbis_get_samples_short_interleaved(
        vorbis,
        info.channels,
        samples.ptr,
        @intCast(total_samples),
    );
    // Reject short and error reads — trailing samples would be uninitialised
    // garbage and we'd play it through the device.
    if (got <= 0) return error.AudioDecodeFailed;
    if (@as(usize, @intCast(got)) < total_frames) return error.AudioDecodeFailed;

    return .{
        .samples = samples,
        .sample_rate = sample_rate,
        .channels = channels,
    };
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "decodeAudio rejects empty data" {
    try testing.expectError(error.AudioDecodeFailed, decodeAudio("wav", &.{}, testing.allocator));
    try testing.expectError(error.AudioDecodeFailed, decodeAudio("ogg", &.{}, testing.allocator));
}

test "decodeAudio rejects unknown file_type" {
    const fake = "anything";
    try testing.expectError(error.UnsupportedAudioFormat, decodeAudio("flac", fake, testing.allocator));
    try testing.expectError(error.UnsupportedAudioFormat, decodeAudio("mp3", fake, testing.allocator));
}

test "decodeAudio surfaces AudioDecodeFailed on garbage wav input" {
    // Not a RIFF header — dr_wav's init_memory should fail.
    var fake: [1024]u8 = undefined;
    for (&fake, 0..) |*b, i| b.* = @truncate(i);
    try testing.expectError(error.AudioDecodeFailed, decodeAudio("wav", &fake, testing.allocator));
}

test "Sound has stable extern layout" {
    // Locks the Phase 4 wire shape: the assembler's codegen does a field-by-
    // field copy through this struct, so size + alignment need to stay
    // invariant.
    try testing.expectEqual(@as(usize, 8), @sizeOf(Sound));
    try testing.expectEqual(@as(usize, 4), @alignOf(Sound));
}
