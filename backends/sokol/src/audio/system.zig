/// Audio system lifecycle + the per-frame mixer callback.
///
/// `ensureInit` / `deinit` bracket sokol_audio's lifetime; everything
/// in between runs on the OS audio thread inside `audioCallback`,
/// which is why the shared mixer state in `state.zig` is read/written
/// here without locks (see that module's docstring for the
/// thread-safety contract).
const std = @import("std");
const sokol = @import("sokol");
const saudio = sokol.audio;
const slots = @import("../audio_slots.zig");
const state = @import("state.zig");

pub fn ensureInit() void {
    if (state.audio_initialized) return;
    saudio.setup(.{
        .num_channels = 2,
        .sample_rate = 44100,
        .stream_cb = audioCallback,
        .logger = .{ .func = sokol.log.func },
    });
    if (saudio.isvalid()) {
        state.audio_initialized = true;
    }
}

/// Shut down the audio system and free all allocated sample buffers.
/// Must be called before program exit to avoid leaking memory.
pub fn deinit() void {
    if (!state.audio_initialized) return;

    // Stop the audio callback first so it no longer reads shared state.
    // `isvalid()` guards against the test-host path where we flip
    // `audio_initialized` manually without ever calling `saudio.setup`
    // — `saudio.shutdown` asserts `setup_called` and would abort.
    if (saudio.isvalid()) saudio.shutdown();

    // Free all sound sample buffers.
    for (&state.sounds) |*slot| {
        if (slot.*) |s| {
            std.heap.page_allocator.free(s.samples);
            slot.* = null;
        }
    }

    // Free all music sample buffers.
    for (&state.music_slots) |*slot| {
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
    for (state.pending_sound_frees.items) |buf| std.heap.page_allocator.free(buf);
    state.pending_sound_frees.deinit(std.heap.page_allocator);
    state.pending_sound_frees = .empty;
    for (state.pending_music_frees.items) |buf| std.heap.page_allocator.free(buf);
    state.pending_music_frees.deinit(std.heap.page_allocator);
    state.pending_music_frees = .empty;

    // Reset all voices.
    for (&state.voices) |*voice| {
        voice.* = .{ .sound_id = 0, .position = 0, .active = false };
    }

    // Reset per-slot generation counters too — otherwise stale
    // generations would survive across a deinit/init cycle and a
    // fresh `Sound` handle could collide with a stale held one.
    state.sound_generations = [_]u32{0} ** slots.MAX_SOUNDS;
    state.music_generations = [_]u32{0} ** slots.MAX_MUSIC;

    state.master_volume = 1.0;
    state.audio_initialized = false;
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
    for (&state.voices) |*voice| {
        if (!voice.active) continue;
        const slot_ptr = state.activeSound(voice.sound_id) orelse {
            voice.active = false;
            continue;
        };
        const slot = slot_ptr.*;

        const vol = slot.volume * state.master_volume;
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
    for (&state.music_slots) |*maybe_slot| {
        if (maybe_slot.*) |*slot| {
            if (slot.unloaded) continue;
            if (!slot.playing or slot.paused) continue;

            // Guard: zero-length samples can't be played — stop to avoid infinite loop
            if (slot.sample_count == 0) {
                slot.playing = false;
                continue;
            }

            const vol = slot.volume * state.master_volume;
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

pub fn setVolume(volume: f32) void {
    state.master_volume = std.math.clamp(volume, 0.0, 1.0);
}
