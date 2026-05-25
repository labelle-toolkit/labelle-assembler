/// Phase 4 audio loader surface (labelle-engine#447).
///
/// Decode/upload split mirrors the gfx image + font paths: pure CPU
/// decode in `decodeAudio` (worker-thread safe — stb_vorbis / dr_wav
/// only touch the input bytes + the allocator-owned PCM buffer),
/// audio-device-side registration in `uploadSound` on the main thread
/// (slot-pool insert).
///
/// ADDITIVE: the path-based `loadSound`/`playSound`/`stopSound` in
/// `legacy.zig` keeps working unchanged for games that use the
/// runtime loader instead of the Phase 4 asset catalog. The two
/// surfaces share the underlying `audio_slots` storage so an
/// `unloadSound(Sound)` from the catalog path correctly tears down
/// the same slot a `playSound(id)` from the legacy path would see.
const std = @import("std");
const slots = @import("../audio_slots.zig");
const state = @import("state.zig");
const system = @import("system.zig");

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
///     more capable than the home-grown `parseWav` in `legacy.zig`,
///     which we keep for the legacy `loadSound` path so its behaviour
///     stays byte-for-byte equivalent.
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
    system.ensureInit();

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
    const slot_idx = slots.allocateSoundSlot(&state.sounds) orelse return error.AudioSlotsExhausted;

    const f32_samples = convertS16ToF32(decoded.samples) catch return error.OutOfMemory;
    errdefer std.heap.page_allocator.free(f32_samples);

    // If we're reusing a previously-unloaded slot, its old samples
    // buffer is still pinned by the deferred-free contract — we can't
    // free it here because the audio thread may have captured the
    // pointer before its containing voice went `active = false`. Park
    // it on `pending_sound_frees` and let `deinit` (which calls
    // `saudio.shutdown` first) release everything safely.
    if (state.sounds[slot_idx]) |old| {
        try state.pending_sound_frees.append(std.heap.page_allocator, old.samples);
    }

    state.sounds[slot_idx] = .{
        .samples = f32_samples,
        .sample_count = f32_samples.len,
        .channels = decoded.channels,
        .sample_rate = decoded.sample_rate,
        .volume = 1.0,
    };
    state.sound_generations[slot_idx] += 1;

    return .{ .slot_index = slot_idx, .generation = state.sound_generations[slot_idx] };
}

/// Counterpart to `uploadSound`. Validates the generation tag so a
/// stale handle (one whose slot has been recycled) is a no-op
/// rather than tearing down the live sound that now lives there.
pub fn unloadSound(sound: Sound) void {
    if (sound.slot_index == 0 or sound.slot_index >= slots.MAX_SOUNDS) return;
    if (state.sound_generations[sound.slot_index] != sound.generation) return;

    // Stop any voices playing this slot so the audio callback won't
    // chase a freed pointer between the markUnloaded below and the
    // shutdown-time free. Same ordering as the legacy
    // `unloadSoundById` path (see `legacy.zig`).
    for (&state.voices) |*voice| {
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
    slots.markSoundUnloaded(&state.sounds, sound.slot_index);
}
