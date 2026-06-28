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
///     `uploadSound(decoded)` + `unloadSound(sound)`. Decode side now forwards
///     to the shared `labelle-audio-decode` module (pure-Zig WAV + stb_vorbis
///     OGG, issue #391) — this backend no longer ships its own dr_wav /
///     stb_vorbis copies; `rl.loadSoundFromWave` for the upload side.
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

/// raylib refuses to create/play any `Sound`/`Music` until the audio
/// device exists — without it `loadSoundFromWave` fails with "Failed to
/// create data conversion pipeline" / "Failed to create buffer". The
/// generated `main.zig` initializes the window but never the audio
/// device, so we lazily bring it up the first time a game actually
/// touches audio. Idempotent (guarded by `isAudioDeviceReady`) and
/// main-thread only — every caller below runs on the main thread.
fn ensureAudioDevice() void {
    if (!rl.isAudioDeviceReady()) rl.initAudioDevice();
}

// ── Sound effects (legacy path-based) ──────────────────────────

/// Load a sound effect from a filesystem path via raylib's own file loader.
///
/// FORMAT NOTE: the build disables raudio's OGG decoder to avoid a
/// `stb_vorbis` duplicate-symbol clash with the shared `labelle-audio-decode`
/// module (see `build.zig`). WAV is unaffected and works here. A `.ogg` path
/// will fail to decode and return `0` — load OGG through the asset catalog
/// (`loadSoundFromMemory` / declared `.sound` resources), which decodes OGG via
/// the shared decoder, not raudio.
pub fn loadSound(path: [:0]const u8) u32 {
    ensureAudioDevice();
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

/// Load a streaming music track from a filesystem path via raylib.
///
/// FORMAT NOTE: same as `loadSound` — raudio's OGG decoder is disabled, so a
/// `.ogg` path returns `0`. WAV streaming works. There is no catalog-side
/// streaming fallback for OGG music yet (the shared decoder is full-buffer, not
/// a stream), so OGG background music on raylib is currently unsupported.
pub fn loadMusic(path: [:0]const u8) u32 {
    ensureAudioDevice();
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
    // `SetMasterVolume` before `InitAudioDevice` is undefined behaviour in
    // raylib (it touches the uninitialised miniaudio context). A game may set
    // master volume before loading any sound, so bring the device up first —
    // idempotent, see `ensureAudioDevice`. (Review: gemini-code-assist, #393.)
    ensureAudioDevice();
    rl.setMasterVolume(volume);
}

// ── Phase 4 audio loader surface (labelle-engine#447) ─────────────────
//
// Decode/upload split mirrors the gfx image + font paths: pure CPU
// decode in `decodeAudio` (worker-thread safe — forwards to the shared
// `labelle-audio-decode` module, which only touches the input bytes +
// the allocator-owned PCM buffer), audio-device-side registration in
// `uploadSound` on the main thread (slot-pool insert).
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

const shared_decode = @import("labelle-audio-decode");

/// CPU-decoded interleaved-PCM audio. Re-exported from the shared
/// `labelle-audio-decode` module (issue #391) — `{ samples: []i16,
/// sample_rate: u32, channels: u8 }`, the same field layout the assembler's
/// `writeAudioBackendWiring` field-by-field copy expects.
pub const DecodedAudio = shared_decode.DecodedAudio;

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

/// Pure CPU decode — worker-thread safe. Forwards to the shared
/// `labelle-audio-decode` module (issue #391):
///   - "wav" → pure-Zig overflow-safe WAV decode (NO `dr_wav`).
///   - "ogg" → stb_vorbis.
///   - anything else → `error.AudioUnsupportedFormat`.
///
/// The returned `samples` slice is from `allocator` — caller frees on BOTH
/// success and discard paths.
pub fn decodeAudio(
    file_type: [:0]const u8,
    data: []const u8,
    allocator: std.mem.Allocator,
) !DecodedAudio {
    return shared_decode.decodeAudio(file_type, data, allocator);
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
    // Reject zero-channel inputs up-front. `decodeAudio` already
    // rejects them, but `uploadSound` is a public API that can be
    // called with a hand-constructed `DecodedAudio` (e.g. games that
    // synthesize PCM in-engine). Without this guard the
    // `@divTrunc(samples.len, channels)` below would panic in debug
    // and be UB in release.
    if (decoded.channels == 0) return error.AudioInvalidChannels;

    // Bring up the audio device on first use (see `ensureAudioDevice`).
    ensureAudioDevice();

    // Reject sample counts that aren't an integer multiple of
    // channels — `@divTrunc` below would silently drop the
    // remainder, producing a partial-frame upload with garbage at
    // the end. Caller bug surfaces here as a clean error instead of
    // a wave with mismatched frameCount vs underlying buffer length.
    // Bugbot finding on labelle-assembler#112 post-fix-agent review.
    if (decoded.samples.len % @as(usize, decoded.channels) != 0) return error.AudioMalformedFrameCount;

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
    try testing.expectError(error.AudioEmptyInput, decodeAudio("wav", &.{}, testing.allocator));
    try testing.expectError(error.AudioEmptyInput, decodeAudio("ogg", &.{}, testing.allocator));
}

test "decodeAudio rejects unknown file_type" {
    const fake = "anything";
    try testing.expectError(error.AudioUnsupportedFormat, decodeAudio("flac", fake, testing.allocator));
    try testing.expectError(error.AudioUnsupportedFormat, decodeAudio("mp3", fake, testing.allocator));
}

test "decodeAudio surfaces a parse error on garbage wav input" {
    // Not a RIFF header. The shared pure-Zig WAV decoder surfaces the precise
    // `wav.ParseError.NotRiff` (the old dr_wav path collapsed every failure to
    // `AudioDecodeFailed`); either way the assembler treats any decode error
    // the same. We only assert it errors cleanly without panicking.
    var fake: [1024]u8 = undefined;
    for (&fake, 0..) |*b, i| b.* = @truncate(i);
    try testing.expectError(error.NotRiff, decodeAudio("wav", &fake, testing.allocator));
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

// NOTE on `uploadSound` zero-channel coverage:
//
// The channel-zero guard in `uploadSound` (returning
// `error.AudioInvalidChannels` before `@divTrunc(.., channels)`) is
// the user-facing fix for the div-by-zero Cursor Bugbot flagged.
// We deliberately do NOT add a test that calls `uploadSound` from
// the host test target here: doing so forces the linker to resolve
// `rl.loadSoundFromWave` against `libraylib.a`, which embeds its own
// private copy of `stb_vorbis`. Since issue #391 the OGG decode comes
// from the shared `labelle-audio-decode` module, which compiles its own
// `stb_vorbis.c` translation unit — so a test that linked BOTH that TU
// and `libraylib.a`'s embedded `_stb_vorbis_*` symbols would risk
// duplicate-symbol link errors. (The dr_wav copy is gone: WAV now decodes
// in pure Zig.) The parallel sokol test exercises an equivalent guard at
// the unit level without that linker constraint.
