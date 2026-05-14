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
var master_volume: f32 = 1.0;
var audio_initialized: bool = false;

// Deferred-free list for sample buffers whose slot has been recycled
// by a subsequent `loadSound` / `uploadSound`. We don't free these at
// the recycle site because the audio thread may still hold a stale
// pointer captured before `voice.active` was flipped to false; by the
// time the slot is reused, sokol_audio's buffer-period (10–20ms) has
// elapsed and a fresh `uploadSound` is fine to overwrite the slot
// fields — but the old `[]f32` allocation has to outlive the audio
// thread for the safety story to hold, so we park it here and free
// everything at `deinit` after `saudio.shutdown()` blocks the callback.
//
// This is the same trade-off `markSoundUnloaded` already encodes for
// non-recycled slots; we simply extend it across the recycle boundary.
var pending_sound_frees: std.ArrayList([]const f32) = .empty;
var pending_music_frees: std.ArrayList([]const f32) = .empty;

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
    // `isvalid()` guards against the test-host path where we flip
    // `audio_initialized` manually without ever calling `saudio.setup`
    // — `saudio.shutdown` asserts `setup_called` and would abort.
    if (saudio.isvalid()) saudio.shutdown();

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

    // Free every sample buffer whose slot was recycled during the run
    // (issue #110): these allocations were intentionally kept alive
    // past their `unloadSound` because the audio callback thread may
    // have still held a pointer to them. `saudio.shutdown()` above
    // joined that thread, so we can drop them now.
    for (pending_sound_frees.items) |buf| std.heap.page_allocator.free(buf);
    pending_sound_frees.deinit(std.heap.page_allocator);
    pending_sound_frees = .empty;
    for (pending_music_frees.items) |buf| std.heap.page_allocator.free(buf);
    pending_music_frees.deinit(std.heap.page_allocator);
    pending_music_frees = .empty;

    // Reset all voices.
    for (&voices) |*voice| {
        voice.* = .{ .sound_id = 0, .position = 0, .active = false };
    }

    // Reset per-slot generation counters too — otherwise stale
    // generations would survive across a deinit/init cycle and a
    // fresh `Sound` handle could collide with a stale held one.
    sound_generations = [_]u32{0} ** slots.MAX_SOUNDS;
    music_generations = [_]u32{0} ** slots.MAX_MUSIC;

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

// Legacy `u32` audio id encoding (#110 follow-up).
//
// Pre-fix, the legacy `loadSound`/`loadMusic` paths returned the slot
// index verbatim as `u32`. That worked when slots were never recycled
// — a stale id couldn't collide with a new occupant because the id
// allocator was monotonic. The slot-recycling fix changed that: a
// freed slot can be reused by the next `loadSound`, so a stale id
// stored by game code can now alias the new sound.
//
// `unloadSoundById(stale_id)` would tear down the live recycled
// occupant. To prevent that without changing the public `u32` type,
// we pack the slot's generation into the upper 16 bits of the
// returned id: `(generation & 0xFFFF) << 16 | (slot_idx & 0xFFFF)`.
//
// MAX_SOUNDS = 256 and MAX_MUSIC = 32, so the bottom 16 bits hold the
// index with room to spare. The Phase 4 `Sound` struct already does
// the same trick with explicit `slot_index`/`generation` fields; this
// is the legacy `u32`-shaped counterpart.
//
// Read consumers (`playSound`, `stopSound`, etc.) only decode the
// slot index — passing a stale id at those entry points would
// silently address the recycled slot (annoying but not destructive),
// mirroring v1 behaviour. The generation check is enforced where it
// matters: `unloadSoundById` / `unloadMusic`, which destroy state.
const SLOT_INDEX_MASK: u32 = 0xFFFF;
const GEN_SHIFT: u5 = 16;

fn encodeLegacyId(slot_idx: u32, generation: u32) u32 {
    return ((generation & 0xFFFF) << GEN_SHIFT) | (slot_idx & SLOT_INDEX_MASK);
}

fn decodeLegacySlot(id: u32) u32 {
    return id & SLOT_INDEX_MASK;
}

fn decodeLegacyGeneration(id: u32) u32 {
    return (id >> GEN_SHIFT) & 0xFFFF;
}

pub fn loadSound(path: [:0]const u8) u32 {
    ensureInit();
    const wav = loadWavFile(path) orelse return 0;
    // Route through the shared allocator so this legacy path can't
    // collide with the Phase 4 `uploadSound` (issue #110). The pre-fix
    // code blindly wrote to `sounds[next_sound_id]` which `uploadSound`
    // had no way to observe, silently leaking the Phase 4 slot's
    // converted-f32 buffer and stranding a stale `Sound` handle.
    const id = slots.allocateSoundSlot(&sounds) orelse {
        std.heap.page_allocator.free(wav.samples);
        return 0;
    };
    // If we're reusing an unloaded slot, park the old samples buffer
    // on the deferred-free list so deinit (which runs after the audio
    // thread has been joined) can release it. We can't free in place
    // because the audio callback may still hold a stale pointer.
    if (sounds[id]) |old| {
        pending_sound_frees.append(std.heap.page_allocator, old.samples) catch {
            // Append failed (OOM on the list growth): leak the buffer
            // rather than free-mid-runtime — same reasoning as above.
            // The slot itself still gets overwritten below.
        };
    }
    sounds[id] = .{
        .samples = wav.samples,
        .sample_count = wav.samples.len,
        .channels = wav.channels,
        .sample_rate = wav.sample_rate,
        .volume = 1.0,
    };
    // Bump the generation so any Phase 4 `Sound` handle held against
    // this slot index from a prior occupant becomes stale (its
    // generation check in `unloadSound` will now fail-soft), and so
    // the encoded legacy `u32` below stays unique across recycle
    // cycles.
    sound_generations[id] += 1;
    return encodeLegacyId(id, sound_generations[id]);
}

/// Legacy path-based unload, paired with `loadSound(path)`. Renamed
/// from `unloadSound` so the Phase 4 catalog-shaped surface (which
/// requires `unloadSound(sound: Sound)` per the engine contract) can
/// take the bare name. Game code that was calling `audio.unloadSound(id)`
/// against the legacy API moves to this name; the catalog path uses
/// `unloadSound(sound)` further down.
///
/// Validates the generation packed into the returned `u32` against
/// `sound_generations[slot]` so a stale id (held across an
/// upload/unload + recycle cycle) is a no-op rather than tearing down
/// the live recycled occupant. See `encodeLegacyId`.
pub fn unloadSoundById(id: u32) void {
    const slot_idx = decodeLegacySlot(id);
    const gen = decodeLegacyGeneration(id);
    if (slot_idx == 0 or slot_idx >= MAX_SOUNDS) return;
    // Generation mismatch ⇒ stale id from a previous occupant of this
    // slot. Refuse to tear down the live sound. We compare against
    // the low 16 bits since that's what the encoded id carries.
    if ((sound_generations[slot_idx] & 0xFFFF) != gen) return;
    if (activeSound(slot_idx) == null) return;
    // Stop any voices using this sound before flipping the unloaded
    // bit — the audio callback may still be iterating `voices` and
    // about to follow `sound_id` into this slot.
    for (&voices) |*voice| {
        if (voice.active and voice.sound_id == slot_idx) {
            voice.active = false;
        }
    }
    // Do NOT free samples here — the audio callback thread may still
    // be reading. `markSoundUnloaded` keeps the slot reachable via
    // `sounds[slot]` so `deinit` can free it at shutdown. See #10 — the
    // pre-fix code nulled the whole optional and orphaned the buffer.
    slots.markSoundUnloaded(&sounds, slot_idx);
}

pub fn playSound(id: u32) void {
    ensureInit();
    const slot_idx = decodeLegacySlot(id);
    if (activeSound(slot_idx) == null) return;

    // Find a free voice slot
    for (&voices) |*voice| {
        if (!voice.active) {
            voice.* = .{ .sound_id = slot_idx, .position = 0, .active = true };
            return;
        }
    }
    // All voices busy: steal the oldest (first) voice
    voices[0] = .{ .sound_id = slot_idx, .position = 0, .active = true };
}

pub fn stopSound(id: u32) void {
    const slot_idx = decodeLegacySlot(id);
    for (&voices) |*voice| {
        if (voice.active and voice.sound_id == slot_idx) {
            voice.active = false;
        }
    }
}

pub fn isSoundPlaying(id: u32) bool {
    const slot_idx = decodeLegacySlot(id);
    for (&voices) |*voice| {
        if (voice.active and voice.sound_id == slot_idx) {
            return true;
        }
    }
    return false;
}

pub fn setSoundVolume(id: u32, volume: f32) void {
    if (activeSound(decodeLegacySlot(id))) |slot| {
        slot.volume = std.math.clamp(volume, 0.0, 1.0);
    }
}

// ── Music (streaming) ──────────────────────────────────────

/// Per-slot generation counter for the legacy music path. Same
/// rationale as `sound_generations` (see #110 follow-up): the
/// encoded `u32` returned by `loadMusic` packs this so a stale id
/// across a recycle boundary is a no-op in `unloadMusic`.
var music_generations: [slots.MAX_MUSIC]u32 = [_]u32{0} ** slots.MAX_MUSIC;

pub fn loadMusic(path: [:0]const u8) u32 {
    ensureInit();
    const wav = loadWavFile(path) orelse return 0;
    // Same pattern as `loadSound`: shared allocator + deferred free
    // for any recycled slot's old samples. See #110.
    const id = slots.allocateMusicSlot(&music_slots) orelse {
        std.heap.page_allocator.free(wav.samples);
        return 0;
    };
    if (music_slots[id]) |old| {
        pending_music_frees.append(std.heap.page_allocator, old.samples) catch {};
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
    music_generations[id] += 1;
    return encodeLegacyId(id, music_generations[id]);
}

/// Validates the generation packed into the returned `u32` against
/// `music_generations[slot]` so a stale id (held across an
/// upload/unload + recycle cycle) is a no-op. See `encodeLegacyId`
/// and `unloadSoundById` for the full reasoning.
pub fn unloadMusic(id: u32) void {
    const slot_idx = decodeLegacySlot(id);
    const gen = decodeLegacyGeneration(id);
    if (slot_idx == 0 or slot_idx >= MAX_MUSIC) return;
    if ((music_generations[slot_idx] & 0xFFFF) != gen) return;
    // `markMusicUnloaded` stops playback and sets the flag; the slot
    // stays non-null so `deinit` can free the samples at shutdown.
    // See #10 and unloadSound above for the full reasoning.
    slots.markMusicUnloaded(&music_slots, slot_idx);
}

pub fn playMusic(id: u32) void {
    ensureInit();
    if (activeMusic(decodeLegacySlot(id))) |slot| {
        slot.playing = true;
        slot.paused = false;
        slot.position = 0;
    }
}

pub fn stopMusic(id: u32) void {
    if (activeMusic(decodeLegacySlot(id))) |slot| {
        slot.playing = false;
        slot.position = 0;
    }
}

pub fn pauseMusic(id: u32) void {
    if (activeMusic(decodeLegacySlot(id))) |slot| {
        slot.paused = true;
    }
}

pub fn resumeMusic(id: u32) void {
    if (activeMusic(decodeLegacySlot(id))) |slot| {
        slot.paused = false;
    }
}

pub fn isMusicPlaying(id: u32) bool {
    if (activeMusic(decodeLegacySlot(id))) |slot| {
        return slot.playing and !slot.paused;
    }
    return false;
}

pub fn setMusicVolume(id: u32, volume: f32) void {
    if (activeMusic(decodeLegacySlot(id))) |slot| {
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

/// Main-thread audio-device registration. Allocates a converted f32
/// PCM buffer (sokol_audio mixes in f32) into the slot pool and
/// returns a generation-tagged `Sound` handle.
///
/// Does NOT take ownership of `decoded.samples` — caller frees on
/// both the success and discard paths, same contract as
/// `uploadTexture` for `DecodedImage.pixels`.
pub fn uploadSound(decoded: DecodedAudio) !Sound {
    ensureInit();

    // Reject zero-channel inputs up-front. `decodeAudio` already
    // rejects them, but `uploadSound` is a public API that can be
    // called with a hand-constructed `DecodedAudio` (e.g. games that
    // synthesize PCM in-engine). A zero `channels` would propagate
    // into `sample_count`/mixer-step arithmetic and the audio
    // callback's stride math; rejecting here keeps the slot pool's
    // invariants honest.
    if (decoded.channels == 0) return error.AudioInvalidChannels;

    // Shared slot allocator — accepts null OR unloaded slots, so this
    // path now recycles slots whose `unloadSound` already ran (issue
    // #110: pre-fix the scan looked only for `null`, and `markSoundUnloaded`
    // keeps the slot non-null, so the pool exhausted after MAX_SOUNDS
    // upload+unload cycles). Going through the shared helper also
    // means the legacy `loadSound` path can never collide on the same
    // index (the two used to disagree about what "free" meant).
    const slot_idx = slots.allocateSoundSlot(&sounds) orelse return error.AudioSlotsExhausted;

    const f32_samples = convertS16ToF32(decoded.samples) catch return error.OutOfMemory;
    errdefer std.heap.page_allocator.free(f32_samples);

    // If we're reusing a previously-unloaded slot, its old samples
    // buffer is still pinned by the deferred-free contract — we can't
    // free it here because the audio thread may have captured the
    // pointer before its containing voice went `active = false`. Park
    // it on `pending_sound_frees` and let `deinit` (which calls
    // `saudio.shutdown` first) release everything safely.
    if (sounds[slot_idx]) |old| {
        try pending_sound_frees.append(std.heap.page_allocator, old.samples);
    }

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
    // shutdown-time free. Same ordering as the legacy
    // `unloadSoundById` path (see this file, ~line 350).
    for (&voices) |*voice| {
        if (voice.active and voice.sound_id == sound.slot_index) {
            voice.active = false;
        }
    }
    // Do NOT free `s.samples` here. The audio callback runs on a
    // separate thread; even after we flip `active = false` on every
    // voice, a callback iteration that already captured the slot
    // pointer above can still be reading `slot.samples[position]`.
    // The previous eager free (`std.heap.page_allocator.free(s.samples)`
    // + `sounds[...] = null`) raced that read and was a use-after-free.
    //
    // We mirror the legacy `unloadSoundById` pattern: mark the slot
    // unloaded so `activeSound` returns null on subsequent passes,
    // and let `deinit` walk every non-null slot and free its samples
    // at shutdown. The buffer stays reachable via `sounds[slot]` so
    // it is not leaked. Slot reuse for fresh `uploadSound` calls is
    // gated on `sounds[i] == null`, matching the legacy behaviour —
    // unloaded slots are NOT reclaimed at runtime by design.
    slots.markSoundUnloaded(&sounds, sound.slot_index);
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

// ── Slot-management regression tests for #110 ─────────────────────────
//
// These exercise the upload + unload paths' interaction with the
// shared slot allocator without spinning up sokol's audio device. We
// flip `audio_initialized` to true so `ensureInit` is a no-op (it
// won't call `saudio.setup` and the OS audio thread never starts).
// All sample buffers are heap-allocated through `page_allocator` to
// match the runtime paths' allocator choice.

/// Reset the module's static state so each test starts from a clean
/// slate (deinit needs `audio_initialized = true` to actually run its
/// cleanup walk; the tests below assume that path).
fn resetForTest() void {
    audio_initialized = true; // skip saudio.setup
    // Drain everything via the real deinit, then re-prime for the
    // next test segment.
    deinit();
    audio_initialized = true;
}

fn makeDecodedFor(allocator: std.mem.Allocator, frames: usize) !DecodedAudio {
    const samples = try allocator.alloc(i16, frames);
    for (samples, 0..) |*s, i| s.* = @intCast(@as(i32, @intCast(i)) & 0x7FFF);
    return .{ .samples = samples, .sample_rate = 44100, .channels = 1 };
}

test "uploadSound recycles slots through upload+unload cycles past MAX_SOUNDS (#110)" {
    resetForTest();
    defer {
        audio_initialized = true;
        deinit();
    }

    const allocator = std.testing.allocator;

    // Run more cycles than slots exist. Pre-fix, `uploadSound` only
    // scanned for `null` slots and `unloadSound`/`markSoundUnloaded`
    // never nulled the slot — so the 256th cycle returned
    // `error.AudioSlotsExhausted`. With the recycle fix it must run
    // for arbitrarily many cycles.
    const cycles: usize = @as(usize, slots.MAX_SOUNDS) * 3;
    var i: usize = 0;
    while (i < cycles) : (i += 1) {
        const decoded = try makeDecodedFor(allocator, 4);
        defer allocator.free(decoded.samples);

        const sound = try uploadSound(decoded);
        try testing.expect(sound.slot_index != 0);
        unloadSound(sound);
    }

    // After all that churn the slot pool is still serviceable.
    const decoded = try makeDecodedFor(allocator, 4);
    defer allocator.free(decoded.samples);
    const final = try uploadSound(decoded);
    try testing.expect(final.slot_index != 0);
    unloadSound(final);
}

test "loadSound and uploadSound do not collide on the same slot (#110)" {
    resetForTest();
    defer {
        audio_initialized = true;
        deinit();
    }

    const allocator = std.testing.allocator;

    // Simulate the legacy path with a hand-crafted slot insertion —
    // `loadSound` itself parses a WAV from disk which we don't want
    // to pull into the test. The collision case the issue documents
    // is purely about the slot index chosen, so we exercise the
    // shared allocator directly: claim a slot the way `loadSound`
    // now does, then upload a Phase 4 sound and assert the indices
    // differ.
    const legacy_id = slots.allocateSoundSlot(&sounds) orelse return error.NoSlot;
    const legacy_buf = try std.heap.page_allocator.alloc(f32, 2);
    sounds[legacy_id] = .{
        .samples = legacy_buf,
        .sample_count = legacy_buf.len,
        .channels = 1,
        .sample_rate = 44100,
        .volume = 1.0,
    };
    sound_generations[legacy_id] += 1;

    const decoded = try makeDecodedFor(allocator, 4);
    defer allocator.free(decoded.samples);
    const phase4 = try uploadSound(decoded);

    try testing.expect(phase4.slot_index != legacy_id);
    try testing.expect(phase4.slot_index != 0);

    // The legacy slot is still intact — the Phase 4 upload did not
    // clobber it (the pre-fix bug was the *opposite* direction, but
    // the symmetric check is the right invariant for the shared
    // allocator).
    try testing.expect(sounds[legacy_id] != null);
    try testing.expect(!sounds[legacy_id].?.unloaded);
    try testing.expectEqual(legacy_buf.len, sounds[legacy_id].?.sample_count);

    unloadSound(phase4);
}

test "uploadSound after unloadSound bumps generation so stale Sound handles fail-soft (#110)" {
    resetForTest();
    defer {
        audio_initialized = true;
        deinit();
    }

    const allocator = std.testing.allocator;

    const decoded_a = try makeDecodedFor(allocator, 4);
    defer allocator.free(decoded_a.samples);
    const first = try uploadSound(decoded_a);

    unloadSound(first);

    // With slot 1 unloaded and every other slot empty, the shared
    // allocator's "first null or unloaded" scan returns slot 1 again
    // — exactly the recycle case we care about.
    const decoded_b = try makeDecodedFor(allocator, 4);
    defer allocator.free(decoded_b.samples);
    const second = try uploadSound(decoded_b);

    try testing.expectEqual(first.slot_index, second.slot_index);
    try testing.expect(second.generation != first.generation);

    // Calling `unloadSound(first)` now must be a no-op: the slot
    // belongs to `second`. Otherwise we'd tear down the live sound.
    unloadSound(first);
    try testing.expect(sounds[second.slot_index] != null);
    try testing.expect(!sounds[second.slot_index].?.unloaded);

    // Real teardown via the fresh handle.
    unloadSound(second);
}

test "uploadSound rejects zero-channel DecodedAudio (#111 follow-up)" {
    resetForTest();
    defer {
        audio_initialized = true;
        deinit();
    }

    const allocator = std.testing.allocator;
    const samples = try allocator.alloc(i16, 4);
    defer allocator.free(samples);
    const decoded: DecodedAudio = .{
        .samples = samples,
        .sample_rate = 44100,
        .channels = 0,
    };
    try testing.expectError(error.AudioInvalidChannels, uploadSound(decoded));
}

test "unloadSoundById ignores stale legacy id after slot recycle (#111)" {
    // The legacy `u32` returned by `loadSound` now packs the slot
    // generation in its high 16 bits. After a load + unload, a
    // subsequent load that recycles the same slot produces a fresh
    // generation; the OLD id is stale and must NOT tear down the
    // recycled occupant. Pre-fix, `unloadSoundById` took the bare
    // `u32` as a raw slot index and would have flipped the new
    // slot's `unloaded` bit.
    resetForTest();
    defer {
        audio_initialized = true;
        deinit();
    }

    // We can't drive `loadSound` from a test without a WAV on disk,
    // so we simulate the load+unload+load sequence using the same
    // primitives `loadSound`/`unloadSoundById` go through: shared
    // allocator → encoded id → generation bump.
    const first_slot = slots.allocateSoundSlot(&sounds) orelse return error.NoSlot;
    const first_buf = try std.heap.page_allocator.alloc(f32, 2);
    sounds[first_slot] = .{
        .samples = first_buf,
        .sample_count = first_buf.len,
        .channels = 1,
        .sample_rate = 44100,
        .volume = 1.0,
    };
    sound_generations[first_slot] += 1;
    const stale_id = encodeLegacyId(first_slot, sound_generations[first_slot]);

    // Unload puts the slot on the recycle list (markSoundUnloaded
    // sets the unloaded flag but keeps the optional non-null).
    unloadSoundById(stale_id);
    try testing.expect(sounds[first_slot].?.unloaded);

    // Simulate a fresh `loadSound` that recycles the same index. We
    // park the old buffer on the deferred-free list, the same way
    // the real `loadSound` does.
    const recycled_slot = slots.allocateSoundSlot(&sounds) orelse return error.NoSlot;
    try testing.expectEqual(first_slot, recycled_slot);
    if (sounds[recycled_slot]) |old| {
        try pending_sound_frees.append(std.heap.page_allocator, old.samples);
    }
    const new_buf = try std.heap.page_allocator.alloc(f32, 4);
    sounds[recycled_slot] = .{
        .samples = new_buf,
        .sample_count = new_buf.len,
        .channels = 1,
        .sample_rate = 44100,
        .volume = 1.0,
    };
    sound_generations[recycled_slot] += 1;
    const fresh_id = encodeLegacyId(recycled_slot, sound_generations[recycled_slot]);
    try testing.expect(stale_id != fresh_id);

    // The critical assertion: calling unloadSoundById with the stale
    // id must NOT mark the recycled occupant as unloaded.
    unloadSoundById(stale_id);
    try testing.expect(sounds[recycled_slot] != null);
    try testing.expect(!sounds[recycled_slot].?.unloaded);

    // The fresh id still works.
    unloadSoundById(fresh_id);
    try testing.expect(sounds[recycled_slot].?.unloaded);
}

test "unloadMusic ignores stale legacy id after slot recycle (#111)" {
    resetForTest();
    defer {
        audio_initialized = true;
        deinit();
    }

    const first_slot = slots.allocateMusicSlot(&music_slots) orelse return error.NoSlot;
    const first_buf = try std.heap.page_allocator.alloc(f32, 2);
    music_slots[first_slot] = .{
        .samples = first_buf,
        .sample_count = first_buf.len,
        .channels = 1,
        .sample_rate = 44100,
        .volume = 1.0,
        .position = 0,
        .playing = false,
        .paused = false,
        .looping = false,
    };
    music_generations[first_slot] += 1;
    const stale_id = encodeLegacyId(first_slot, music_generations[first_slot]);

    unloadMusic(stale_id);
    try testing.expect(music_slots[first_slot].?.unloaded);

    const recycled_slot = slots.allocateMusicSlot(&music_slots) orelse return error.NoSlot;
    try testing.expectEqual(first_slot, recycled_slot);
    if (music_slots[recycled_slot]) |old| {
        try pending_music_frees.append(std.heap.page_allocator, old.samples);
    }
    const new_buf = try std.heap.page_allocator.alloc(f32, 4);
    music_slots[recycled_slot] = .{
        .samples = new_buf,
        .sample_count = new_buf.len,
        .channels = 1,
        .sample_rate = 44100,
        .volume = 1.0,
        .position = 0,
        .playing = false,
        .paused = false,
        .looping = false,
    };
    music_generations[recycled_slot] += 1;
    const fresh_id = encodeLegacyId(recycled_slot, music_generations[recycled_slot]);
    try testing.expect(stale_id != fresh_id);

    unloadMusic(stale_id);
    try testing.expect(music_slots[recycled_slot] != null);
    try testing.expect(!music_slots[recycled_slot].?.unloaded);

    unloadMusic(fresh_id);
    try testing.expect(music_slots[recycled_slot].?.unloaded);
}

test "legacy id encode/decode roundtrip" {
    // Slot index in low 16 bits, generation in high 16 bits.
    try testing.expectEqual(@as(u32, 0x0001_002A), encodeLegacyId(42, 1));
    try testing.expectEqual(@as(u32, 42), decodeLegacySlot(0x0001_002A));
    try testing.expectEqual(@as(u32, 1), decodeLegacyGeneration(0x0001_002A));

    // Generation truncation past 16 bits — the decode reads only
    // the low 16, and the encode masks both halves.
    const id = encodeLegacyId(7, 0x1_FFFF);
    try testing.expectEqual(@as(u32, 7), decodeLegacySlot(id));
    try testing.expectEqual(@as(u32, 0xFFFF), decodeLegacyGeneration(id));
}
