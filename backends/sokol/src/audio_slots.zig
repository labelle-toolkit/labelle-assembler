//! Slot storage + transitions for the sokol audio backend.
//!
//! Factored out of `audio.zig` so the leak-fix invariants (#10) can
//! be unit-tested without pulling sokol's C artifact into the test
//! binary — the real `audio.zig` imports `sokol` which links against
//! `libasound`/`libGL`/`libX11` at build time.
//!
//! The important bit: `markSoundUnloaded` / `markMusicUnloaded` set a
//! flag instead of nulling the optional. The samples buffer stays
//! reachable via `slots[id]` so the caller's `deinit` loop — which
//! already walks every non-null slot and frees its samples — reaches
//! it. The pre-fix `audio.zig` nulled the whole optional on unload,
//! which orphaned the samples buffer and leaked it.
const std = @import("std");

pub const MAX_SOUNDS: u32 = 256;
pub const MAX_MUSIC: u32 = 32;

pub const SoundSlot = struct {
    samples: []const f32, // interleaved PCM
    sample_count: usize,
    channels: u16,
    sample_rate: u32,
    volume: f32,
    /// See the file-level comment and `markSoundUnloaded`.
    unloaded: bool = false,
};

pub const MusicSlot = struct {
    samples: []const f32,
    sample_count: usize,
    channels: u16,
    sample_rate: u32,
    volume: f32,
    position: usize,
    playing: bool,
    paused: bool,
    looping: bool,
    /// See the file-level comment and `markMusicUnloaded`.
    unloaded: bool = false,
};

pub const SoundSlots = [MAX_SOUNDS]?SoundSlot;
pub const MusicSlots = [MAX_MUSIC]?MusicSlot;

pub fn emptySoundSlots() SoundSlots {
    return [_]?SoundSlot{null} ** MAX_SOUNDS;
}

pub fn emptyMusicSlots() MusicSlots {
    return [_]?MusicSlot{null} ** MAX_MUSIC;
}

/// Returns a pointer to the sound slot at `id` only if it exists and
/// has not been unloaded. Any caller that previously wrote
/// `slots[id] != null` should use this helper so the `unloaded` check
/// stays honest in one place.
pub fn activeSound(slots: *SoundSlots, id: u32) ?*SoundSlot {
    if (id >= MAX_SOUNDS) return null;
    if (slots[id]) |*s| {
        if (s.unloaded) return null;
        return s;
    }
    return null;
}

/// See `activeSound`.
pub fn activeMusic(slots: *MusicSlots, id: u32) ?*MusicSlot {
    if (id >= MAX_MUSIC) return null;
    if (slots[id]) |*s| {
        if (s.unloaded) return null;
        return s;
    }
    return null;
}

/// Mark a sound slot unloaded. The slot stays non-null so the owning
/// module's shutdown walk can still free the samples buffer.
pub fn markSoundUnloaded(slots: *SoundSlots, id: u32) void {
    if (activeSound(slots, id)) |slot| slot.unloaded = true;
}

/// Mark a music slot unloaded. Also stops playback so the audio
/// callback will skip it on its next pass before the `unloaded` flag
/// is even observed.
pub fn markMusicUnloaded(slots: *MusicSlots, id: u32) void {
    if (activeMusic(slots, id)) |slot| {
        slot.playing = false;
        slot.unloaded = true;
    }
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

/// Fabricate a sound slot with caller-owned samples. Caller frees the
/// returned slice; the helper is just for test ergonomics.
fn makeTestSound(samples: []const f32) SoundSlot {
    return .{
        .samples = samples,
        .sample_count = samples.len,
        .channels = 1,
        .sample_rate = 44100,
        .volume = 1.0,
    };
}

fn makeTestMusic(samples: []const f32) MusicSlot {
    return .{
        .samples = samples,
        .sample_count = samples.len,
        .channels = 1,
        .sample_rate = 44100,
        .volume = 1.0,
        .position = 0,
        .playing = true,
        .paused = false,
        .looping = false,
    };
}

test "markSoundUnloaded keeps slot reachable (regression for #10)" {
    var slots = emptySoundSlots();
    const buf = try testing.allocator.alloc(f32, 4);
    defer testing.allocator.free(buf);

    slots[1] = makeTestSound(buf);
    try testing.expect(activeSound(&slots, 1) != null);

    markSoundUnloaded(&slots, 1);

    // The old buggy code nulled slots[1] here, orphaning `buf`. The
    // fix keeps the slot non-null so the owning module's deinit walk
    // can still find the buffer and free it.
    try testing.expect(slots[1] != null);
    try testing.expect(slots[1].?.unloaded);
    try testing.expectEqual(@as(usize, 4), slots[1].?.sample_count);
}

test "activeSound treats unloaded slots as absent" {
    var slots = emptySoundSlots();
    const buf = try testing.allocator.alloc(f32, 2);
    defer testing.allocator.free(buf);

    slots[2] = makeTestSound(buf);
    try testing.expect(activeSound(&slots, 2) != null);

    slots[2].?.unloaded = true;
    try testing.expect(activeSound(&slots, 2) == null);
}

test "activeSound returns null for out-of-range id" {
    var slots = emptySoundSlots();
    try testing.expect(activeSound(&slots, MAX_SOUNDS) == null);
    try testing.expect(activeSound(&slots, MAX_SOUNDS + 100) == null);
}

test "activeSound returns null for an empty slot" {
    var slots = emptySoundSlots();
    try testing.expect(activeSound(&slots, 5) == null);
}

test "markSoundUnloaded is a no-op on empty and already-unloaded slots" {
    var slots = emptySoundSlots();

    // Empty slot — no-op, no crash.
    markSoundUnloaded(&slots, 7);
    try testing.expect(slots[7] == null);

    const buf = try testing.allocator.alloc(f32, 1);
    defer testing.allocator.free(buf);

    slots[8] = makeTestSound(buf);
    slots[8].?.unloaded = true;

    // Already unloaded — markSoundUnloaded should not re-touch the
    // slot's public state.
    markSoundUnloaded(&slots, 8);
    try testing.expect(slots[8] != null);
    try testing.expect(slots[8].?.unloaded);
}

test "markMusicUnloaded stops playback, marks unloaded, keeps slot" {
    var slots = emptyMusicSlots();
    const buf = try testing.allocator.alloc(f32, 8);
    defer testing.allocator.free(buf);

    slots[1] = makeTestMusic(buf);
    slots[1].?.playing = true;

    try testing.expect(activeMusic(&slots, 1) != null);

    markMusicUnloaded(&slots, 1);

    try testing.expect(slots[1] != null);
    try testing.expect(slots[1].?.unloaded);
    try testing.expect(!slots[1].?.playing);
    try testing.expect(activeMusic(&slots, 1) == null);
}

test "activeMusic treats unloaded slots as absent" {
    var slots = emptyMusicSlots();
    const buf = try testing.allocator.alloc(f32, 2);
    defer testing.allocator.free(buf);

    slots[4] = makeTestMusic(buf);
    try testing.expect(activeMusic(&slots, 4) != null);

    slots[4].?.unloaded = true;
    try testing.expect(activeMusic(&slots, 4) == null);
}

test "activeMusic returns null for out-of-range id" {
    var slots = emptyMusicSlots();
    try testing.expect(activeMusic(&slots, MAX_MUSIC) == null);
    try testing.expect(activeMusic(&slots, MAX_MUSIC + 10) == null);
}
