/// Raylib audio backend — satisfies the engine AudioInterface(Impl) contract
/// AND (as of Phase 4 of the Asset Streaming RFC, labelle-engine#447) the
/// `audio_backend.Backend(Impl)` decoder/loader contract used by the
/// assembler's `writeAudioBackendWiring` codegen.
///
/// Two surfaces coexist:
///   - Legacy path-based: `loadSound(path)` / `unloadSoundById(id)` / etc.
///     Backed by raylib's own file-loading APIs. Unchanged byte-for-byte
///     from the pre-Phase-4 raylib backend.
///   - Phase 4 catalog-shaped: `decodeAudio(file_type, data, allocator)` +
///     `uploadSound(decoded)` + `unloadSound(sound)`. Backed by
///     `dr_wav` (.wav) and `stb_vorbis` (.ogg) for the decode side;
///     `rl.loadSoundFromWave` for the upload side.
///
/// Both surfaces share the same `sounds` slot pool so an `unloadSound`
/// from the catalog tears down the same raylib `Sound` that a legacy
/// `playSound(id)` would see. Slot 0 is reserved as "no sound" for
/// both — matches the engine contract that treats id 0 as invalid.
const std = @import("std");
const rl = @import("raylib");
const slot_alloc = @import("slot_alloc.zig");

const MAX_SOUNDS = 256;
const MAX_MUSIC = 32;

var sounds: [MAX_SOUNDS]?rl.Sound = [_]?rl.Sound{null} ** MAX_SOUNDS;
var music: [MAX_MUSIC]?rl.Music = [_]?rl.Music{null} ** MAX_MUSIC;
var next_sound_id: u32 = 1;
var next_music_id: u32 = 1;

// ── Sound effects (legacy path-based) ──────────────────────────

pub fn loadSound(path: [:0]const u8) u32 {
    const snd = rl.loadSound(path);
    // `snd.stream.buffer` is `*rAudioBuffer` (non-optional) in
    // raylib-zig 5.6.0-dev, so a `== null` check fails to typecheck.
    // The canonical raylib API for "did the load succeed?" is
    // `IsSoundValid` (returns false when stream + sample data are
    // uninitialised, which is what raylib's C code does on failure).
    // Surfaced during labelle-assembler#112 review.
    if (!rl.isSoundValid(snd)) return 0;
    const id = slot_alloc.findFreeSlot(rl.Sound, &sounds, next_sound_id) orelse {
        rl.unloadSound(snd);
        return 0;
    };
    sounds[id] = snd;
    if (id == next_sound_id) next_sound_id += 1;
    return id;
}

/// Legacy path-based unload, paired with `loadSound(path)`. Renamed
/// from `unloadSound` so the Phase 4 catalog-shaped surface (which
/// requires `unloadSound(sound: Sound)` per the engine contract) can
/// take the bare name. Game code that was calling `audio.unloadSound(id)`
/// against the legacy API moves to this name; the catalog path uses
/// `unloadSound(sound)` further down.
pub fn unloadSoundById(id: u32) void {
    if (id < MAX_SOUNDS) {
        if (sounds[id]) |snd| {
            rl.unloadSound(snd);
            sounds[id] = null;
        }
    }
}

pub fn playSound(id: u32) void {
    if (id < MAX_SOUNDS) {
        if (sounds[id]) |snd| {
            rl.playSound(snd);
        }
    }
}

pub fn stopSound(id: u32) void {
    if (id < MAX_SOUNDS) {
        if (sounds[id]) |snd| {
            rl.stopSound(snd);
        }
    }
}

pub fn isSoundPlaying(id: u32) bool {
    if (id < MAX_SOUNDS) {
        if (sounds[id]) |snd| {
            return rl.isSoundPlaying(snd);
        }
    }
    return false;
}

pub fn setSoundVolume(id: u32, volume: f32) void {
    if (id < MAX_SOUNDS) {
        if (sounds[id]) |snd| {
            rl.setSoundVolume(snd, volume);
        }
    }
}

// ── Music (streaming) ──────────────────────────────────────

pub fn loadMusic(path: [:0]const u8) u32 {
    const mus = rl.loadMusicStream(path);
    // See `loadSound` above: `mus.stream.buffer` is now non-optional
    // in raylib-zig 5.6.0-dev. Use the canonical `IsMusicValid`.
    if (!rl.isMusicValid(mus)) return 0;
    const id = slot_alloc.findFreeSlot(rl.Music, &music, next_music_id) orelse {
        rl.unloadMusicStream(mus);
        return 0;
    };
    music[id] = mus;
    if (id == next_music_id) next_music_id += 1;
    return id;
}

pub fn unloadMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music[id]) |mus| {
            rl.unloadMusicStream(mus);
            music[id] = null;
        }
    }
}

pub fn playMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music[id]) |mus| {
            rl.playMusicStream(mus);
        }
    }
}

pub fn stopMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music[id]) |mus| {
            rl.stopMusicStream(mus);
        }
    }
}

pub fn pauseMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music[id]) |mus| {
            rl.pauseMusicStream(mus);
        }
    }
}

pub fn resumeMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music[id]) |mus| {
            rl.resumeMusicStream(mus);
        }
    }
}

pub fn isMusicPlaying(id: u32) bool {
    if (id < MAX_MUSIC) {
        if (music[id]) |mus| {
            return rl.isMusicStreamPlaying(mus);
        }
    }
    return false;
}

pub fn setMusicVolume(id: u32, volume: f32) void {
    if (id < MAX_MUSIC) {
        if (music[id]) |mus| {
            rl.setMusicVolume(mus, volume);
        }
    }
}

pub fn updateMusic(id: u32) void {
    if (id < MAX_MUSIC) {
        if (music[id]) |mus| {
            rl.updateMusicStream(mus);
        }
    }
}

// ── Global ────────────────────────────────────────────────

pub fn setVolume(volume: f32) void {
    rl.setMasterVolume(volume);
}

// ── Phase 4 audio loader surface (labelle-engine#447) ─────────────────
//
// Decode/upload split mirrors the gfx image + font paths: pure CPU
// decode in `decodeAudio` (worker-thread safe — stb_vorbis / dr_wav
// only touch the input bytes + the allocator-owned PCM buffer),
// audio-device-side registration in `uploadSound` on the main thread
// (slot-pool insert).
//
// ADDITIVE: the path-based `loadSound`/`playSound`/`stopSound` above
// keeps working unchanged for games that use the runtime loader
// instead of the Phase 4 asset catalog. The two surfaces share the
// underlying `sounds` slot pool so an `unloadSound(Sound)` from the
// catalog path correctly tears down the same slot a `playSound(id)`
// from the legacy path would see.
//
// Divergence from the sokol blueprint: raylib's audio system (miniaudio
// internally) synchronizes `UnloadSound` against the playback thread for
// us — calling `rl.unloadSound(snd)` is safe even while a voice is
// active, and raylib drains any references before freeing. So the
// sokol "mark unloaded, defer free to deinit" pattern is not required
// here. We keep the generation-tagged `Sound` handle so stale-handle
// detection (catalog refcount drops to zero between two uploads of the
// same slot) behaves identically across backends.

const drwav = @cImport({
    @cInclude("dr_wav.h");
});

// stb_vorbis is single-file (the .c IS the API + implementation). We
// pull just the prototypes for the handful of decode functions we
// call here through a hand-rolled header — `@cInclude("stb_vorbis.c")`
// would compile the implementation a second time and collide with the
// C-source-side translation unit on every `stb_vorbis_*` symbol.
const stbv = @cImport({
    @cInclude("stb_vorbis_decl.h");
});

/// CPU-decoded interleaved-PCM audio. Field layout matches
/// `labelle-engine/audio_backend/src/backend.zig`'s `DecodedAudio`
/// so the assembler's `writeAudioBackendWiring` field-by-field copy
/// lands on a stable shape.
pub const DecodedAudio = struct {
    /// Interleaved PCM samples. Length == `frame_count * channels`.
    /// Owned by the allocator passed to `decodeAudio`; the caller
    /// frees via that same allocator on both the success and
    /// discard paths.
    samples: []i16,
    sample_rate: u32,
    channels: u8,
};

/// Opaque sound handle for the Phase 4 loader. Generation-tagged so
/// `unloadSound` can detect stale handles (the slot may have been
/// recycled by a subsequent upload between the catalog's read of
/// the handle and the unload call).
pub const Sound = extern struct {
    slot_index: u32,
    generation: u32,
};

/// Per-slot generation counter for the Phase 4 path. Distinct from
/// `next_sound_id` (legacy-path monotonic id) — we tag a generation
/// onto each `Sound` handle so `unloadSound` can fail-soft on stale
/// references (same trick the engine's `SoundId` uses on the public
/// side, hoisted here so callers that hold a `Sound` value across
/// an unload + re-upload don't accidentally tear down the new sound).
var sound_generations: [MAX_SOUNDS]u32 = [_]u32{0} ** MAX_SOUNDS;

/// Pure CPU decode — worker-thread safe.
///
/// Dispatches on `file_type`:
///   - "wav" → `dr_wav` (drwav_init_memory + drwav_read_pcm_frames_s16).
///     Handles every PCM bit-depth + IEEE float internally — strictly
///     more capable than raylib's own `loadWaveFromMemory` path (which
///     would also work but pulls in raylib's audio device on the worker
///     thread, defeating the decode-off-main-thread point).
///   - "ogg" → `stb_vorbis` (open_memory + get_samples_short_interleaved).
///     Single-allocation streaming decode into a caller-owned i16
///     buffer.
///
/// The returned `samples` slice is from `allocator` — caller frees
/// on BOTH success and discard paths.
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
    // frame × channel multiply — a wrap would alloc an undersized
    // buffer that drwav happily writes past.
    const total_samples = std.math.mul(usize, total_frames, channels) catch return error.AudioTooLarge;
    const samples = try allocator.alloc(i16, total_samples);
    errdefer allocator.free(samples);

    const got = drwav.drwav_read_pcm_frames_s16(&wav, total_frames, samples.ptr);
    // Treat short reads as failures: the trailing samples are
    // uninitialised, so emitting the buffer would mix garbage into
    // the output. `errdefer` above frees the partial buffer.
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
    // frame × channel multiply — a wrap would alloc an undersized
    // buffer that stb_vorbis happily writes past.
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
    // Reject short and error reads — trailing samples would be
    // uninitialised garbage and we'd play it through the device.
    if (got <= 0) return error.AudioDecodeFailed;
    if (@as(usize, @intCast(got)) < total_frames) return error.AudioDecodeFailed;

    return .{
        .samples = samples,
        .sample_rate = sample_rate,
        .channels = channels,
    };
}

/// Main-thread audio-device registration. Wraps the decoded PCM in a
/// raylib `Wave` and calls `loadSoundFromWave`, which copies the
/// samples into raylib's mixer-owned buffer. Returns a
/// generation-tagged `Sound` handle.
///
/// Does NOT take ownership of `decoded.samples` — caller frees on
/// both the success and discard paths, same contract as
/// `uploadTexture` for `DecodedImage.pixels`. `loadSoundFromWave`
/// copies the samples, so the caller's buffer can be freed
/// immediately after this call returns.
pub fn uploadSound(decoded: DecodedAudio) !Sound {
    // Find a free slot. Walk from index 1 — id 0 is reserved as
    // "no sound" for the legacy `loadSound` path, which we preserve
    // to keep the two surfaces' semantics aligned.
    var slot_idx: u32 = 0;
    var i: u32 = 1;
    while (i < MAX_SOUNDS) : (i += 1) {
        if (sounds[i] == null) {
            slot_idx = i;
            break;
        }
    }
    if (slot_idx == 0) return error.AudioSlotsExhausted;

    // Wrap the decoded PCM in a raylib `Wave`. raylib copies the
    // samples internally during `loadSoundFromWave`, so the caller's
    // buffer stays caller-owned and can be freed after upload.
    const wave: rl.Wave = .{
        .frameCount = @intCast(@divTrunc(decoded.samples.len, @as(usize, decoded.channels))),
        .sampleRate = decoded.sample_rate,
        .sampleSize = 16, // i16 PCM
        .channels = decoded.channels,
        .data = @ptrCast(@constCast(decoded.samples.ptr)),
    };

    const snd = rl.loadSoundFromWave(wave);
    if (!rl.isSoundValid(snd)) return error.AudioUploadFailed;

    sounds[slot_idx] = snd;
    sound_generations[slot_idx] += 1;

    return .{ .slot_index = slot_idx, .generation = sound_generations[slot_idx] };
}

/// Counterpart to `uploadSound`. Validates the generation tag so a
/// stale handle (one whose slot has been recycled) is a no-op
/// rather than tearing down the live sound that now lives there.
///
/// Divergence from sokol: raylib's `UnloadSound` synchronizes against
/// the audio playback thread internally (miniaudio handles the drain),
/// so we can free eagerly here instead of deferring to a shutdown walk.
/// The slot is nulled so subsequent `uploadSound` calls can recycle
/// the index — same v1 behaviour as the legacy `unloadSoundById` path.
pub fn unloadSound(sound: Sound) void {
    if (sound.slot_index == 0 or sound.slot_index >= MAX_SOUNDS) return;
    if (sound_generations[sound.slot_index] != sound.generation) return;

    if (sounds[sound.slot_index]) |snd| {
        rl.unloadSound(snd);
        sounds[sound.slot_index] = null;
    }
}

// ── Phase 4 surface tests ─────────────────────────────────────────────

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

test "decodeAudio surfaces AudioDecodeFailed on garbage ogg input" {
    // Not an Ogg capture pattern — stb_vorbis_open_memory should return null.
    var fake: [1024]u8 = undefined;
    for (&fake, 0..) |*b, i| b.* = @truncate(i);
    try testing.expectError(error.AudioDecodeFailed, decodeAudio("ogg", &fake, testing.allocator));
}

test "Sound has stable extern layout" {
    // Locks the Phase 4 wire shape: the assembler's codegen does a
    // field-by-field copy through this struct, so size + alignment
    // need to stay invariant.
    try testing.expectEqual(@as(usize, 8), @sizeOf(Sound));
    try testing.expectEqual(@as(usize, 4), @alignOf(Sound));
}
