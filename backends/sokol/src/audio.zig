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
///
/// This file is the public façade for the sokol audio backend. The
/// implementation is split across `audio/` submodules to keep each
/// concern below the 1000-line ceiling enforced by labelle-assembler#188:
///
///   - `audio/state.zig`   — shared mixer state (sounds, music_slots, voices, generations)
///   - `audio/system.zig`  — ensureInit / deinit / audioCallback (the OS audio-thread side)
///   - `audio/legacy.zig`  — path-based loadSound/playSound/… + home-grown WAV parser
///   - `audio/phase4.zig`  — Phase 4 catalog surface (decodeAudio / uploadSound, dr_wav + stb_vorbis)
///   - `audio/tests.zig`   — Phase 4 surface tests + #110/#111 regression locks
///
/// Submodules are private file-system neighbours; consumers always
/// reach the backend through
/// `b.dependency("labelle_sokol", ...).module("audio")`, which still
/// points at this file.
const system = @import("audio/system.zig");
const legacy = @import("audio/legacy.zig");
const phase4 = @import("audio/phase4.zig");

// ── Audio system lifecycle ─────────────────────────────────────────────

pub const deinit = system.deinit;
pub const setVolume = system.setVolume;

// ── Legacy path-based sound effects ────────────────────────────────────

pub const loadSound = legacy.loadSound;
pub const unloadSoundById = legacy.unloadSoundById;
pub const playSound = legacy.playSound;
pub const stopSound = legacy.stopSound;
pub const isSoundPlaying = legacy.isSoundPlaying;
pub const setSoundVolume = legacy.setSoundVolume;

// ── Legacy path-based music (streaming) ────────────────────────────────

pub const loadMusic = legacy.loadMusic;
pub const unloadMusic = legacy.unloadMusic;
pub const playMusic = legacy.playMusic;
pub const stopMusic = legacy.stopMusic;
pub const pauseMusic = legacy.pauseMusic;
pub const resumeMusic = legacy.resumeMusic;
pub const isMusicPlaying = legacy.isMusicPlaying;
pub const setMusicVolume = legacy.setMusicVolume;
pub const updateMusic = legacy.updateMusic;

// ── Phase 4 audio loader surface (labelle-engine#447) ──────────────────

pub const DecodedAudio = phase4.DecodedAudio;
pub const Sound = phase4.Sound;
pub const decodeAudio = phase4.decodeAudio;
pub const uploadSound = phase4.uploadSound;
pub const unloadSound = phase4.unloadSound;

// ── Test aggregation ───────────────────────────────────────────────────
//
// The build.zig's `audio_compile_check` runs `b.addTest({ .root_module =
// audio_mod })` over this file. Pull in `tests.zig` (and indirectly
// every other submodule via its imports) so Zig's test discovery
// picks up all the Phase 4 + #110/#111 regression tests.
const std = @import("std");
test {
    std.testing.refAllDecls(@import("audio/tests.zig"));
}
