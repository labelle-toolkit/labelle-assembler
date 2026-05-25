/// Phase 4 audio surface tests + #110/#111 slot-management regression
/// locks. Centralised here so the test wiring lives next to the
/// fixtures (`resetForTest`, `makeDecodedFor`) it needs.
const std = @import("std");
const slots = @import("../audio_slots.zig");
const state = @import("state.zig");
const system = @import("system.zig");
const legacy = @import("legacy.zig");
const phase4 = @import("phase4.zig");

const testing = std.testing;
const DecodedAudio = phase4.DecodedAudio;
const Sound = phase4.Sound;
const decodeAudio = phase4.decodeAudio;
const uploadSound = phase4.uploadSound;
const unloadSound = phase4.unloadSound;
const unloadSoundById = legacy.unloadSoundById;
const unloadMusic = legacy.unloadMusic;
const encodeLegacyId = legacy.encodeLegacyId;
const decodeLegacySlot = legacy.decodeLegacySlot;
const decodeLegacyGeneration = legacy.decodeLegacyGeneration;

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
    state.audio_initialized = true; // skip saudio.setup
    // Drain everything via the real deinit, then re-prime for the
    // next test segment.
    system.deinit();
    state.audio_initialized = true;
}

fn makeDecodedFor(allocator: std.mem.Allocator, frames: usize) !DecodedAudio {
    const samples = try allocator.alloc(i16, frames);
    for (samples, 0..) |*s, i| s.* = @intCast(@as(i32, @intCast(i)) & 0x7FFF);
    return .{ .samples = samples, .sample_rate = 44100, .channels = 1 };
}

test "uploadSound recycles slots through upload+unload cycles past MAX_SOUNDS (#110)" {
    resetForTest();
    defer {
        state.audio_initialized = true;
        system.deinit();
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
        state.audio_initialized = true;
        system.deinit();
    }

    const allocator = std.testing.allocator;

    // Simulate the legacy path with a hand-crafted slot insertion —
    // `loadSound` itself parses a WAV from disk which we don't want
    // to pull into the test. The collision case the issue documents
    // is purely about the slot index chosen, so we exercise the
    // shared allocator directly: claim a slot the way `loadSound`
    // now does, then upload a Phase 4 sound and assert the indices
    // differ.
    const legacy_id = slots.allocateSoundSlot(&state.sounds) orelse return error.NoSlot;
    const legacy_buf = try std.heap.page_allocator.alloc(f32, 2);
    state.sounds[legacy_id] = .{
        .samples = legacy_buf,
        .sample_count = legacy_buf.len,
        .channels = 1,
        .sample_rate = 44100,
        .volume = 1.0,
    };
    state.sound_generations[legacy_id] += 1;

    const decoded = try makeDecodedFor(allocator, 4);
    defer allocator.free(decoded.samples);
    const ph4 = try uploadSound(decoded);

    try testing.expect(ph4.slot_index != legacy_id);
    try testing.expect(ph4.slot_index != 0);

    // The legacy slot is still intact — the Phase 4 upload did not
    // clobber it (the pre-fix bug was the *opposite* direction, but
    // the symmetric check is the right invariant for the shared
    // allocator).
    try testing.expect(state.sounds[legacy_id] != null);
    try testing.expect(!state.sounds[legacy_id].?.unloaded);
    try testing.expectEqual(legacy_buf.len, state.sounds[legacy_id].?.sample_count);

    unloadSound(ph4);
}

test "uploadSound after unloadSound bumps generation so stale Sound handles fail-soft (#110)" {
    resetForTest();
    defer {
        state.audio_initialized = true;
        system.deinit();
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
    try testing.expect(state.sounds[second.slot_index] != null);
    try testing.expect(!state.sounds[second.slot_index].?.unloaded);

    // Real teardown via the fresh handle.
    unloadSound(second);
}

test "uploadSound rejects zero-channel DecodedAudio (#111 follow-up)" {
    resetForTest();
    defer {
        state.audio_initialized = true;
        system.deinit();
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
        state.audio_initialized = true;
        system.deinit();
    }

    // We can't drive `loadSound` from a test without a WAV on disk,
    // so we simulate the load+unload+load sequence using the same
    // primitives `loadSound`/`unloadSoundById` go through: shared
    // allocator → encoded id → generation bump.
    const first_slot = slots.allocateSoundSlot(&state.sounds) orelse return error.NoSlot;
    const first_buf = try std.heap.page_allocator.alloc(f32, 2);
    state.sounds[first_slot] = .{
        .samples = first_buf,
        .sample_count = first_buf.len,
        .channels = 1,
        .sample_rate = 44100,
        .volume = 1.0,
    };
    state.sound_generations[first_slot] += 1;
    const stale_id = encodeLegacyId(first_slot, state.sound_generations[first_slot]);

    // Unload puts the slot on the recycle list (markSoundUnloaded
    // sets the unloaded flag but keeps the optional non-null).
    unloadSoundById(stale_id);
    try testing.expect(state.sounds[first_slot].?.unloaded);

    // Simulate a fresh `loadSound` that recycles the same index. We
    // park the old buffer on the deferred-free list, the same way
    // the real `loadSound` does.
    const recycled_slot = slots.allocateSoundSlot(&state.sounds) orelse return error.NoSlot;
    try testing.expectEqual(first_slot, recycled_slot);
    if (state.sounds[recycled_slot]) |old| {
        try state.pending_sound_frees.append(std.heap.page_allocator, old.samples);
    }
    const new_buf = try std.heap.page_allocator.alloc(f32, 4);
    state.sounds[recycled_slot] = .{
        .samples = new_buf,
        .sample_count = new_buf.len,
        .channels = 1,
        .sample_rate = 44100,
        .volume = 1.0,
    };
    state.sound_generations[recycled_slot] += 1;
    const fresh_id = encodeLegacyId(recycled_slot, state.sound_generations[recycled_slot]);
    try testing.expect(stale_id != fresh_id);

    // The critical assertion: calling unloadSoundById with the stale
    // id must NOT mark the recycled occupant as unloaded.
    unloadSoundById(stale_id);
    try testing.expect(state.sounds[recycled_slot] != null);
    try testing.expect(!state.sounds[recycled_slot].?.unloaded);

    // The fresh id still works.
    unloadSoundById(fresh_id);
    try testing.expect(state.sounds[recycled_slot].?.unloaded);
}

test "unloadMusic ignores stale legacy id after slot recycle (#111)" {
    resetForTest();
    defer {
        state.audio_initialized = true;
        system.deinit();
    }

    const first_slot = slots.allocateMusicSlot(&state.music_slots) orelse return error.NoSlot;
    const first_buf = try std.heap.page_allocator.alloc(f32, 2);
    state.music_slots[first_slot] = .{
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
    state.music_generations[first_slot] += 1;
    const stale_id = encodeLegacyId(first_slot, state.music_generations[first_slot]);

    unloadMusic(stale_id);
    try testing.expect(state.music_slots[first_slot].?.unloaded);

    const recycled_slot = slots.allocateMusicSlot(&state.music_slots) orelse return error.NoSlot;
    try testing.expectEqual(first_slot, recycled_slot);
    if (state.music_slots[recycled_slot]) |old| {
        try state.pending_music_frees.append(std.heap.page_allocator, old.samples);
    }
    const new_buf = try std.heap.page_allocator.alloc(f32, 4);
    state.music_slots[recycled_slot] = .{
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
    state.music_generations[recycled_slot] += 1;
    const fresh_id = encodeLegacyId(recycled_slot, state.music_generations[recycled_slot]);
    try testing.expect(stale_id != fresh_id);

    unloadMusic(stale_id);
    try testing.expect(state.music_slots[recycled_slot] != null);
    try testing.expect(!state.music_slots[recycled_slot].?.unloaded);

    unloadMusic(fresh_id);
    try testing.expect(state.music_slots[recycled_slot].?.unloaded);
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
