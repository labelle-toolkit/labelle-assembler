/// Shared module-level state for the sokol audio backend.
///
/// Everything that the audio callback thread and the public-API
/// thread both touch lives here so the other submodules can pull a
/// single canonical handle to it. Each piece of state is documented
/// at its declaration with the thread-safety constraint that pins it
/// to this module.
const std = @import("std");
const slots = @import("../audio_slots.zig");

pub const SoundSlot = slots.SoundSlot;
pub const MusicSlot = slots.MusicSlot;
pub const MAX_SOUNDS = slots.MAX_SOUNDS;
pub const MAX_MUSIC = slots.MAX_MUSIC;
pub const MAX_ACTIVE_VOICES = 64;

// ── Sound slot storage ──────────────────────────────────────────

// Active voice for sound effect playback
pub const Voice = struct {
    sound_id: u32,
    position: usize,
    active: bool,
};

pub var sounds: slots.SoundSlots = slots.emptySoundSlots();
pub var music_slots: slots.MusicSlots = slots.emptyMusicSlots();
pub var voices: [MAX_ACTIVE_VOICES]Voice = [_]Voice{.{ .sound_id = 0, .position = 0, .active = false }} ** MAX_ACTIVE_VOICES;
pub var master_volume: f32 = 1.0;
pub var audio_initialized: bool = false;

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
pub var pending_sound_frees: std.ArrayList([]const f32) = .empty;
pub var pending_music_frees: std.ArrayList([]const f32) = .empty;

/// Per-slot generation counter for the legacy music path. Same
/// rationale as `sound_generations` (see #110 follow-up): the
/// encoded `u32` returned by `loadMusic` packs this so a stale id
/// across a recycle boundary is a no-op in `unloadMusic`.
pub var music_generations: [slots.MAX_MUSIC]u32 = [_]u32{0} ** slots.MAX_MUSIC;

/// Per-slot generation counter for the Phase 4 path. Distinct from
/// `next_sound_id` (legacy-path monotonic id) — we tag a generation
/// onto each `Sound` handle so `unloadSound` can fail-soft on stale
/// references (same trick the engine's `SoundId` uses on the public
/// side, hoisted here so callers that hold a `Sound` value across
/// an unload + re-upload don't accidentally tear down the new sound).
pub var sound_generations: [slots.MAX_SOUNDS]u32 = [_]u32{0} ** slots.MAX_SOUNDS;

/// Thin wrappers over the helpers in `audio_slots.zig` so each call
/// site doesn't have to pass the module-level array explicitly.
pub fn activeSound(id: u32) ?*SoundSlot {
    return slots.activeSound(&sounds, id);
}

pub fn activeMusic(id: u32) ?*MusicSlot {
    return slots.activeMusic(&music_slots, id);
}
