/// Sokol audio backend — satisfies the engine AudioInterface(Impl) contract.
/// Implements a simple PCM mixer on top of sokol_audio's callback API.
/// Supports WAV file loading for both sound effects and music.
///
/// Thread safety: The audio callback (`audioCallback`) runs on a separate thread
/// managed by sokol_audio and reads shared state (`sounds`, `music_slots`, `voices`)
/// without synchronization primitives. Callers must not call `unloadSound` or
/// `unloadMusic` while the corresponding sound/music is actively playing, as the
/// callback may still be reading the sample buffer. The `deinit` function shuts
/// down the audio callback before freeing resources. TODO: add proper atomic or
/// mutex-based synchronization so unload is safe while audio is playing.
const std = @import("std");
const sokol = @import("sokol");
const saudio = sokol.audio;
const slots = @import("audio_slots.zig");

const SoundSlot = slots.SoundSlot;
const MusicSlot = slots.MusicSlot;
const MAX_SOUNDS = slots.MAX_SOUNDS;
const MAX_MUSIC = slots.MAX_MUSIC;
const MAX_ACTIVE_VOICES = 64;

// ── Sound slot storage ──────────────────────────────────────────

// Active voice for sound effect playback
const Voice = struct {
    sound_id: u32,
    position: usize,
    active: bool,
};

var sounds: slots.SoundSlots = slots.emptySoundSlots();
var music_slots: slots.MusicSlots = slots.emptyMusicSlots();
var voices: [MAX_ACTIVE_VOICES]Voice = [_]Voice{.{ .sound_id = 0, .position = 0, .active = false }} ** MAX_ACTIVE_VOICES;
var next_sound_id: u32 = 1;
var next_music_id: u32 = 1;
var master_volume: f32 = 1.0;
var audio_initialized: bool = false;

/// Thin wrappers over the helpers in `audio_slots.zig` so each call
/// site doesn't have to pass the module-level array explicitly.
fn activeSound(id: u32) ?*SoundSlot {
    return slots.activeSound(&sounds, id);
}

fn activeMusic(id: u32) ?*MusicSlot {
    return slots.activeMusic(&music_slots, id);
}

// ── Audio system init ──────────────────────────────────────────

fn ensureInit() void {
    if (audio_initialized) return;
    saudio.setup(.{
        .num_channels = 2,
        .sample_rate = 44100,
        .stream_cb = audioCallback,
        .logger = .{ .func = sokol.log.func },
    });
    if (saudio.isvalid()) {
        audio_initialized = true;
    }
}

/// Shut down the audio system and free all allocated sample buffers.
/// Must be called before program exit to avoid leaking memory.
pub fn deinit() void {
    if (!audio_initialized) return;

    // Stop the audio callback first so it no longer reads shared state.
    saudio.shutdown();

    // Free all sound sample buffers.
    for (&sounds) |*slot| {
        if (slot.*) |s| {
            std.heap.page_allocator.free(s.samples);
            slot.* = null;
        }
    }

    // Free all music sample buffers.
    for (&music_slots) |*slot| {
        if (slot.*) |s| {
            std.heap.page_allocator.free(s.samples);
            slot.* = null;
        }
    }

    // Reset all voices.
    for (&voices) |*voice| {
        voice.* = .{ .sound_id = 0, .position = 0, .active = false };
    }

    next_sound_id = 1;
    next_music_id = 1;
    master_volume = 1.0;
    audio_initialized = false;
}

/// The audio callback invoked by sokol_audio to fill the output buffer.
/// Mixes all active voices and playing music into the output.
fn audioCallback(buffer: [*c]f32, num_frames: i32, num_channels: i32) callconv(.c) void {
    const frames: usize = @intCast(num_frames);
    const channels: usize = @intCast(num_channels);
    const total_samples = frames * channels;

    // Zero the output buffer
    for (0..total_samples) |i| {
        buffer[i] = 0;
    }

    // Mix active sound voices
    for (&voices) |*voice| {
        if (!voice.active) continue;
        const slot_ptr = activeSound(voice.sound_id) orelse {
            voice.active = false;
            continue;
        };
        const slot = slot_ptr.*;

        const vol = slot.volume * master_volume;
        var samples_written: usize = 0;

        while (samples_written < frames) {
            if (voice.position >= slot.sample_count) {
                voice.active = false;
                break;
            }

            const buf_idx = samples_written * channels;

            if (slot.channels == 1) {
                // Mono: duplicate to both channels
                const sample = slot.samples[voice.position] * vol;
                buffer[buf_idx] += sample;
                if (channels >= 2) buffer[buf_idx + 1] += sample;
                voice.position += 1;
            } else {
                // Stereo: copy left and right
                buffer[buf_idx] += slot.samples[voice.position] * vol;
                if (channels >= 2 and voice.position + 1 < slot.sample_count) {
                    buffer[buf_idx + 1] += slot.samples[voice.position + 1] * vol;
                }
                voice.position += 2;
            }
            samples_written += 1;
        }
    }

    // Mix music tracks
    for (&music_slots) |*maybe_slot| {
        if (maybe_slot.*) |*slot| {
            if (slot.unloaded) continue;
            if (!slot.playing or slot.paused) continue;

            // Guard: zero-length samples can't be played — stop to avoid infinite loop
            if (slot.sample_count == 0) {
                slot.playing = false;
                continue;
            }

            const vol = slot.volume * master_volume;
            var samples_written: usize = 0;

            while (samples_written < frames) {
                if (slot.position >= slot.sample_count) {
                    if (slot.looping) {
                        slot.position = 0;
                    } else {
                        slot.playing = false;
                        break;
                    }
                }

                const buf_idx = samples_written * channels;

                if (slot.channels == 1) {
                    const sample = slot.samples[slot.position] * vol;
                    buffer[buf_idx] += sample;
                    if (channels >= 2) buffer[buf_idx + 1] += sample;
                    slot.position += 1;
                } else {
                    buffer[buf_idx] += slot.samples[slot.position] * vol;
                    if (channels >= 2 and slot.position + 1 < slot.sample_count) {
                        buffer[buf_idx + 1] += slot.samples[slot.position + 1] * vol;
                    }
                    slot.position += 2;
                }
                samples_written += 1;
            }
        }
    }

    // Clamp output to [-1.0, 1.0]
    for (0..total_samples) |i| {
        buffer[i] = std.math.clamp(buffer[i], -1.0, 1.0);
    }
}

// ── WAV file parsing ──────────────────────────────────────────

const WavData = struct {
    samples: []f32,
    channels: u16,
    sample_rate: u32,
};

fn loadWavFile(path: [:0]const u8) ?WavData {
    const file = std.fs.cwd().openFileZ(path, .{}) catch return null;
    defer file.close();

    const stat = file.stat() catch return null;
    if (stat.size < 44 or stat.size > 256 * 1024 * 1024) return null;

    const data = file.readToEndAlloc(std.heap.page_allocator, @intCast(stat.size)) catch return null;
    defer std.heap.page_allocator.free(data);

    const wav = parseWav(data) orelse return null;
    if (wav.sample_rate != 44100) {
        std.log.warn("WAV sample rate {d}Hz does not match output rate 44100Hz: {s}", .{ wav.sample_rate, path });
    }
    return wav;
}

fn parseWav(data: []const u8) ?WavData {
    if (data.len < 44) return null;

    // Verify RIFF header
    if (!std.mem.eql(u8, data[0..4], "RIFF")) return null;
    if (!std.mem.eql(u8, data[8..12], "WAVE")) return null;

    // Find "fmt " chunk
    var offset: usize = 12;
    var fmt_found = false;
    var audio_format: u16 = 0;
    var num_channels: u16 = 0;
    var sample_rate: u32 = 0;
    var bits_per_sample: u16 = 0;

    while (offset + 8 <= data.len) {
        const chunk_id = data[offset..][0..4];
        const chunk_size: usize = @intCast(std.mem.readInt(u32, data[offset + 4 ..][0..4], .little));

        if (offset + 8 + chunk_size > data.len) return null;

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (chunk_size < 16 or offset + 8 + chunk_size > data.len) return null;
            const fmt = data[offset + 8 ..];
            audio_format = std.mem.readInt(u16, fmt[0..2], .little);
            num_channels = std.mem.readInt(u16, fmt[2..4], .little);
            sample_rate = std.mem.readInt(u32, fmt[4..8], .little);
            bits_per_sample = std.mem.readInt(u16, fmt[14..16], .little);
            fmt_found = true;
        }

        if (std.mem.eql(u8, chunk_id, "data") and fmt_found) {
            // Only support PCM (1) and IEEE float (3)
            if (audio_format != 1 and audio_format != 3) return null;
            if (num_channels == 0 or num_channels > 2) return null;

            const pcm_data = data[offset + 8 ..][0..chunk_size];
            return convertToF32(pcm_data, num_channels, sample_rate, bits_per_sample, audio_format);
        }

        offset += 8 + ((chunk_size + 1) & ~@as(usize, 1)); // chunks are word-aligned
    }

    return null;
}

fn convertToF32(pcm_data: []const u8, channels: u16, sample_rate: u32, bits: u16, format: u16) ?WavData {
    if (format == 3 and bits == 32) {
        // IEEE 32-bit float
        const num_samples = pcm_data.len / 4;
        const samples = std.heap.page_allocator.alloc(f32, num_samples) catch return null;
        for (0..num_samples) |i| {
            samples[i] = @bitCast(std.mem.readInt(u32, pcm_data[i * 4 ..][0..4], .little));
        }
        return .{ .samples = samples, .channels = channels, .sample_rate = sample_rate };
    }

    if (format == 1) {
        if (bits == 16) {
            const num_samples = pcm_data.len / 2;
            const samples = std.heap.page_allocator.alloc(f32, num_samples) catch return null;
            for (0..num_samples) |i| {
                const raw = std.mem.readInt(i16, pcm_data[i * 2 ..][0..2], .little);
                samples[i] = @as(f32, @floatFromInt(raw)) / 32768.0;
            }
            return .{ .samples = samples, .channels = channels, .sample_rate = sample_rate };
        }
        if (bits == 8) {
            const num_samples = pcm_data.len;
            const samples = std.heap.page_allocator.alloc(f32, num_samples) catch return null;
            for (0..num_samples) |i| {
                // 8-bit WAV is unsigned, 128 = silence
                samples[i] = (@as(f32, @floatFromInt(pcm_data[i])) - 128.0) / 128.0;
            }
            return .{ .samples = samples, .channels = channels, .sample_rate = sample_rate };
        }
        if (bits == 24) {
            const num_samples = pcm_data.len / 3;
            const samples = std.heap.page_allocator.alloc(f32, num_samples) catch return null;
            for (0..num_samples) |i| {
                const b0: i32 = pcm_data[i * 3];
                const b1: i32 = pcm_data[i * 3 + 1];
                const b2: i32 = @as(i32, @as(i8, @bitCast(pcm_data[i * 3 + 2])));
                const raw = b0 | (b1 << 8) | (b2 << 16);
                samples[i] = @as(f32, @floatFromInt(raw)) / 8388608.0;
            }
            return .{ .samples = samples, .channels = channels, .sample_rate = sample_rate };
        }
    }

    return null;
}

// ── Sound effects ──────────────────────────────────────────

pub fn loadSound(path: [:0]const u8) u32 {
    ensureInit();
    const wav = loadWavFile(path) orelse return 0;
    const id = next_sound_id;
    if (id >= MAX_SOUNDS) {
        std.heap.page_allocator.free(wav.samples);
        return 0;
    }
    sounds[id] = .{
        .samples = wav.samples,
        .sample_count = wav.samples.len,
        .channels = wav.channels,
        .sample_rate = wav.sample_rate,
        .volume = 1.0,
    };
    next_sound_id += 1;
    return id;
}

/// Legacy path-based unload, paired with `loadSound(path)`. Renamed
/// from `unloadSound` so the Phase 4 catalog-shaped surface (which
/// requires `unloadSound(sound: Sound)` per the engine contract) can
/// take the bare name. Game code that was calling `audio.unloadSound(id)`
/// against the legacy API moves to this name; the catalog path uses
/// `unloadSound(sound)` further down.
pub fn unloadSoundById(id: u32) void {
    if (activeSound(id) == null) return;
    // Stop any voices using this sound before flipping the unloaded
    // bit — the audio callback may still be iterating `voices` and
    // about to follow `sound_id` into this slot.
    for (&voices) |*voice| {
        if (voice.active and voice.sound_id == id) {
            voice.active = false;
        }
    }
    // Do NOT free samples here — the audio callback thread may still
    // be reading. `markSoundUnloaded` keeps the slot reachable via
    // `sounds[id]` so `deinit` can free it at shutdown. See #10 — the
    // pre-fix code nulled the whole optional and orphaned the buffer.
    slots.markSoundUnloaded(&sounds, id);
}

pub fn playSound(id: u32) void {
    ensureInit();
    if (activeSound(id) == null) return;

    // Find a free voice slot
    for (&voices) |*voice| {
        if (!voice.active) {
            voice.* = .{ .sound_id = id, .position = 0, .active = true };
            return;
        }
    }
    // All voices busy: steal the oldest (first) voice
    voices[0] = .{ .sound_id = id, .position = 0, .active = true };
}

pub fn stopSound(id: u32) void {
    for (&voices) |*voice| {
        if (voice.active and voice.sound_id == id) {
            voice.active = false;
        }
    }
}

pub fn isSoundPlaying(id: u32) bool {
    for (&voices) |*voice| {
        if (voice.active and voice.sound_id == id) {
            return true;
        }
    }
    return false;
}

pub fn setSoundVolume(id: u32, volume: f32) void {
    if (activeSound(id)) |slot| {
        slot.volume = std.math.clamp(volume, 0.0, 1.0);
    }
}

// ── Music (streaming) ──────────────────────────────────────

pub fn loadMusic(path: [:0]const u8) u32 {
    ensureInit();
    const wav = loadWavFile(path) orelse return 0;
    const id = next_music_id;
    if (id >= MAX_MUSIC) {
        std.heap.page_allocator.free(wav.samples);
        return 0;
    }
    music_slots[id] = .{
        .samples = wav.samples,
        .sample_count = wav.samples.len,
        .channels = wav.channels,
        .sample_rate = wav.sample_rate,
        .volume = 1.0,
        .position = 0,
        .playing = false,
        .paused = false,
        .looping = true,
    };
    next_music_id += 1;
    return id;
}

pub fn unloadMusic(id: u32) void {
    // `markMusicUnloaded` stops playback and sets the flag; the slot
    // stays non-null so `deinit` can free the samples at shutdown.
    // See #10 and unloadSound above for the full reasoning.
    slots.markMusicUnloaded(&music_slots, id);
}

pub fn playMusic(id: u32) void {
    ensureInit();
    if (activeMusic(id)) |slot| {
        slot.playing = true;
        slot.paused = false;
        slot.position = 0;
    }
}

pub fn stopMusic(id: u32) void {
    if (activeMusic(id)) |slot| {
        slot.playing = false;
        slot.position = 0;
    }
}

pub fn pauseMusic(id: u32) void {
    if (activeMusic(id)) |slot| {
        slot.paused = true;
    }
}

pub fn resumeMusic(id: u32) void {
    if (activeMusic(id)) |slot| {
        slot.paused = false;
    }
}

pub fn isMusicPlaying(id: u32) bool {
    if (activeMusic(id)) |slot| {
        return slot.playing and !slot.paused;
    }
    return false;
}

pub fn setMusicVolume(id: u32, volume: f32) void {
    if (activeMusic(id)) |slot| {
        slot.volume = std.math.clamp(volume, 0.0, 1.0);
    }
}

pub fn updateMusic(_: u32) void {
    // No-op: music is streamed directly in the audio callback.
    // This function exists for API compatibility with backends that
    // require explicit buffer refills (e.g., raylib).
}

// ── Global ────────────────────────────────────────────────

pub fn setVolume(volume: f32) void {
    master_volume = std.math.clamp(volume, 0.0, 1.0);
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
// underlying `audio_slots` storage so an `unloadSound(Sound)` from
// the catalog path correctly tears down the same slot a `playSound(id)`
// from the legacy path would see.

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
var sound_generations: [slots.MAX_SOUNDS]u32 = [_]u32{0} ** slots.MAX_SOUNDS;

/// PCM samples staged for the audio callback. The legacy `SoundSlot`
/// in `audio_slots.zig` keeps samples as `[]const f32` because the
/// callback mixes in f32. We allocate the converted f32 buffer here
/// so the slot pool's existing shutdown walk frees it via
/// `page_allocator` (matching the legacy `loadSound` path's choice).
fn convertS16ToF32(samples: []const i16) ![]f32 {
    const out = try std.heap.page_allocator.alloc(f32, samples.len);
    for (samples, 0..) |s, i| {
        out[i] = @as(f32, @floatFromInt(s)) / 32768.0;
    }
    return out;
}

/// Pure CPU decode — worker-thread safe.
///
/// Dispatches on `file_type`:
///   - "wav" → `dr_wav` (drwav_init_memory + drwav_read_pcm_frames_s16).
///     Handles every PCM bit-depth + IEEE float internally — strictly
///     more capable than the home-grown `parseWav` above, which we
///     keep for the legacy `loadSound` path so its behaviour stays
///     byte-for-byte equivalent.
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

    const total_samples = total_frames * channels;
    const samples = try allocator.alloc(i16, total_samples);
    errdefer allocator.free(samples);

    const got = drwav.drwav_read_pcm_frames_s16(&wav, total_frames, samples.ptr);
    if (got == 0) return error.AudioDecodeFailed;

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

    const total_samples = total_frames * channels;
    const samples = try allocator.alloc(i16, total_samples);
    errdefer allocator.free(samples);

    // `get_samples_short_interleaved` takes (channels, dest, dest_len_in_shorts)
    // and returns the number of FRAMES decoded.
    const got = stbv.stb_vorbis_get_samples_short_interleaved(
        vorbis,
        info.channels,
        samples.ptr,
        @intCast(total_samples),
    );
    if (got <= 0) return error.AudioDecodeFailed;

    return .{
        .samples = samples,
        .sample_rate = sample_rate,
        .channels = channels,
    };
}

/// Main-thread audio-device registration. Allocates a converted f32
/// PCM buffer (sokol_audio mixes in f32) into the slot pool and
/// returns a generation-tagged `Sound` handle.
///
/// Does NOT take ownership of `decoded.samples` — caller frees on
/// both the success and discard paths, same contract as
/// `uploadTexture` for `DecodedImage.pixels`.
pub fn uploadSound(decoded: DecodedAudio) !Sound {
    ensureInit();

    // Find a free slot. Walk from index 1 — the legacy path reserves
    // id 0 for "not loaded", which we preserve to keep the two
    // surfaces' semantics aligned.
    var slot_idx: u32 = 0;
    var i: u32 = 1;
    while (i < slots.MAX_SOUNDS) : (i += 1) {
        if (sounds[i] == null) {
            slot_idx = i;
            break;
        }
    }
    if (slot_idx == 0) return error.AudioSlotsExhausted;

    const f32_samples = convertS16ToF32(decoded.samples) catch return error.OutOfMemory;
    errdefer std.heap.page_allocator.free(f32_samples);

    sounds[slot_idx] = .{
        .samples = f32_samples,
        .sample_count = f32_samples.len,
        .channels = decoded.channels,
        .sample_rate = decoded.sample_rate,
        .volume = 1.0,
    };
    sound_generations[slot_idx] += 1;

    return .{ .slot_index = slot_idx, .generation = sound_generations[slot_idx] };
}

/// Counterpart to `uploadSound`. Validates the generation tag so a
/// stale handle (one whose slot has been recycled) is a no-op
/// rather than tearing down the live sound that now lives there.
pub fn unloadSound(sound: Sound) void {
    if (sound.slot_index == 0 or sound.slot_index >= slots.MAX_SOUNDS) return;
    if (sound_generations[sound.slot_index] != sound.generation) return;

    // Stop any voices playing this slot so the audio callback won't
    // chase a freed pointer between the markUnloaded below and the
    // deinit-side free. Same ordering as the legacy unload(id) path.
    for (&voices) |*voice| {
        if (voice.active and voice.sound_id == sound.slot_index) {
            voice.active = false;
        }
    }
    slots.markSoundUnloaded(&sounds, sound.slot_index);

    // Eager free: unlike the legacy `unloadSound(id)` path — which
    // keeps the buffer reachable for `deinit` to free at shutdown —
    // Phase 4 callers churn loads/unloads at runtime (level
    // transitions, dynamic audio asset streaming). Holding every
    // ever-unloaded buffer until shutdown would balloon the slot
    // pool's residual memory. Voices for this slot are deactivated
    // above, so no audio-callback read can race the free here.
    if (sounds[sound.slot_index]) |s| {
        std.heap.page_allocator.free(s.samples);
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

test "Sound has stable extern layout" {
    // Locks the Phase 4 wire shape: the assembler's codegen does a
    // field-by-field copy through this struct, so size + alignment
    // need to stay invariant.
    try testing.expectEqual(@as(usize, 8), @sizeOf(Sound));
    try testing.expectEqual(@as(usize, 4), @alignOf(Sound));
}
