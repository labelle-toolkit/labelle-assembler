/// Legacy path-based audio API (loadSound/playSound/stopSound + the
/// matching music functions). Backs the runtime loader used by games
/// that have not migrated to the Phase 4 asset catalog.
///
/// The WAV parser here is intentionally distinct from `phase4`'s
/// `dr_wav` path — keeping the byte-for-byte behaviour of the
/// home-grown parser preserves the legacy contract while the Phase 4
/// surface uses the more capable upstream library.
const std = @import("std");
const slots = @import("../audio_slots.zig");
const state = @import("state.zig");
const system = @import("system.zig");

const MAX_SOUNDS = state.MAX_SOUNDS;
const MAX_MUSIC = state.MAX_MUSIC;

// ── WAV file parsing ──────────────────────────────────────────

pub const WavData = struct {
    samples: []f32,
    channels: u16,
    sample_rate: u32,
};

// Zig 0.16 removed `std.fs.cwd()` in favour of `std.Io.Dir.cwd()`, which
// requires an `Io` parameter threaded through the call site. This is
// the legacy path-based WAV loader — production audio loading goes
// through Phase 4's `dr_wav` + asset catalog path, which never touches
// the FS directly. Rather than thread `Io` through the backend for a
// one-shot legacy loader, we use libc `fopen` / `fread` / `fclose` to
// keep the existing `(path) ?WavData` signature. The `link_libc = true`
// flag on the audio module (see backends/sokol/build.zig) already pulls
// libc in for stb_vorbis / dr_wav, so this adds no new link-time cost.
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

pub fn loadWavFile(path: [:0]const u8) ?WavData {
    // Read the file from disk via libc. See the rationale block above.
    const file = std.c.fopen(path.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(file);

    if (fseek(file, 0, SEEK_END) != 0) return null;
    const file_size_signed = ftell(file);
    if (file_size_signed < 44) return null;
    if (fseek(file, 0, SEEK_SET) != 0) return null;
    const file_size: usize = @intCast(file_size_signed);
    if (file_size > 256 * 1024 * 1024) return null;

    const data = std.heap.page_allocator.alloc(u8, file_size) catch return null;
    defer std.heap.page_allocator.free(data);
    const read = std.c.fread(data.ptr, 1, file_size, file);
    if (read != file_size) return null;

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
pub const SLOT_INDEX_MASK: u32 = 0xFFFF;
pub const GEN_SHIFT: u5 = 16;

pub fn encodeLegacyId(slot_idx: u32, generation: u32) u32 {
    return ((generation & 0xFFFF) << GEN_SHIFT) | (slot_idx & SLOT_INDEX_MASK);
}

pub fn decodeLegacySlot(id: u32) u32 {
    return id & SLOT_INDEX_MASK;
}

pub fn decodeLegacyGeneration(id: u32) u32 {
    return (id >> GEN_SHIFT) & 0xFFFF;
}

pub fn loadSound(path: [:0]const u8) u32 {
    system.ensureInit();
    const wav = loadWavFile(path) orelse return 0;
    // Route through the shared allocator so this legacy path can't
    // collide with the Phase 4 `uploadSound` (issue #110). The pre-fix
    // code blindly wrote to `sounds[next_sound_id]` which `uploadSound`
    // had no way to observe, silently leaking the Phase 4 slot's
    // converted-f32 buffer and stranding a stale `Sound` handle.
    const id = slots.allocateSoundSlot(&state.sounds) orelse {
        std.heap.page_allocator.free(wav.samples);
        return 0;
    };
    // If we're reusing an unloaded slot, park the old samples buffer
    // on the deferred-free list so deinit (which runs after the audio
    // thread has been joined) can release it. We can't free in place
    // because the audio callback may still hold a stale pointer.
    if (state.sounds[id]) |old| {
        state.pending_sound_frees.append(std.heap.page_allocator, old.samples) catch {
            // Append failed (OOM on the list growth): leak the buffer
            // rather than free-mid-runtime — same reasoning as above.
            // The slot itself still gets overwritten below.
        };
    }
    state.sounds[id] = .{
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
    state.sound_generations[id] += 1;
    return encodeLegacyId(id, state.sound_generations[id]);
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
    if ((state.sound_generations[slot_idx] & 0xFFFF) != gen) return;
    if (state.activeSound(slot_idx) == null) return;
    // Stop any voices using this sound before flipping the unloaded
    // bit — the audio callback may still be iterating `voices` and
    // about to follow `sound_id` into this slot.
    for (&state.voices) |*voice| {
        if (voice.active and voice.sound_id == slot_idx) {
            voice.active = false;
        }
    }
    // Do NOT free samples here — the audio callback thread may still
    // be reading. `markSoundUnloaded` keeps the slot reachable via
    // `sounds[slot]` so `deinit` can free it at shutdown. See #10 — the
    // pre-fix code nulled the whole optional and orphaned the buffer.
    slots.markSoundUnloaded(&state.sounds, slot_idx);
}

pub fn playSound(id: u32) void {
    system.ensureInit();
    const slot_idx = decodeLegacySlot(id);
    if (state.activeSound(slot_idx) == null) return;

    // Find a free voice slot
    for (&state.voices) |*voice| {
        if (!voice.active) {
            voice.* = .{ .sound_id = slot_idx, .position = 0, .active = true };
            return;
        }
    }
    // All voices busy: steal the oldest (first) voice
    state.voices[0] = .{ .sound_id = slot_idx, .position = 0, .active = true };
}

pub fn stopSound(id: u32) void {
    const slot_idx = decodeLegacySlot(id);
    for (&state.voices) |*voice| {
        if (voice.active and voice.sound_id == slot_idx) {
            voice.active = false;
        }
    }
}

pub fn isSoundPlaying(id: u32) bool {
    const slot_idx = decodeLegacySlot(id);
    for (&state.voices) |*voice| {
        if (voice.active and voice.sound_id == slot_idx) {
            return true;
        }
    }
    return false;
}

pub fn setSoundVolume(id: u32, volume: f32) void {
    if (state.activeSound(decodeLegacySlot(id))) |slot| {
        slot.volume = std.math.clamp(volume, 0.0, 1.0);
    }
}

// ── Music (streaming) ──────────────────────────────────────

pub fn loadMusic(path: [:0]const u8) u32 {
    system.ensureInit();
    const wav = loadWavFile(path) orelse return 0;
    // Same pattern as `loadSound`: shared allocator + deferred free
    // for any recycled slot's old samples. See #110.
    const id = slots.allocateMusicSlot(&state.music_slots) orelse {
        std.heap.page_allocator.free(wav.samples);
        return 0;
    };
    if (state.music_slots[id]) |old| {
        state.pending_music_frees.append(std.heap.page_allocator, old.samples) catch {};
    }
    state.music_slots[id] = .{
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
    state.music_generations[id] += 1;
    return encodeLegacyId(id, state.music_generations[id]);
}

/// Validates the generation packed into the returned `u32` against
/// `music_generations[slot]` so a stale id (held across an
/// upload/unload + recycle cycle) is a no-op. See `encodeLegacyId`
/// and `unloadSoundById` for the full reasoning.
pub fn unloadMusic(id: u32) void {
    const slot_idx = decodeLegacySlot(id);
    const gen = decodeLegacyGeneration(id);
    if (slot_idx == 0 or slot_idx >= MAX_MUSIC) return;
    if ((state.music_generations[slot_idx] & 0xFFFF) != gen) return;
    // `markMusicUnloaded` stops playback and sets the flag; the slot
    // stays non-null so `deinit` can free the samples at shutdown.
    // See #10 and unloadSound above for the full reasoning.
    slots.markMusicUnloaded(&state.music_slots, slot_idx);
}

pub fn playMusic(id: u32) void {
    system.ensureInit();
    if (state.activeMusic(decodeLegacySlot(id))) |slot| {
        slot.playing = true;
        slot.paused = false;
        slot.position = 0;
    }
}

pub fn stopMusic(id: u32) void {
    if (state.activeMusic(decodeLegacySlot(id))) |slot| {
        slot.playing = false;
        slot.position = 0;
    }
}

pub fn pauseMusic(id: u32) void {
    if (state.activeMusic(decodeLegacySlot(id))) |slot| {
        slot.paused = true;
    }
}

pub fn resumeMusic(id: u32) void {
    if (state.activeMusic(decodeLegacySlot(id))) |slot| {
        slot.paused = false;
    }
}

pub fn isMusicPlaying(id: u32) bool {
    if (state.activeMusic(decodeLegacySlot(id))) |slot| {
        return slot.playing and !slot.paused;
    }
    return false;
}

pub fn setMusicVolume(id: u32, volume: f32) void {
    if (state.activeMusic(decodeLegacySlot(id))) |slot| {
        slot.volume = std.math.clamp(volume, 0.0, 1.0);
    }
}

pub fn updateMusic(_: u32) void {
    // No-op: music is streamed directly in the audio callback.
    // This function exists for API compatibility with backends that
    // require explicit buffer refills (e.g., raylib).
}
