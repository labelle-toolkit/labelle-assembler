/// bgfx audio backend — satisfies the engine AudioInterface(Impl) contract.
/// bgfx has no audio of its own; this implements a minimal WAV decoder +
/// software PCM mixer (`mixAudio`) and drives it with a miniaudio
/// playback device (#297). The device is opened lazily by `ensureInit`
/// (called from the first `loadSound`/`loadMusic`/`playSound`/`playMusic`)
/// and closed by `deinit` (called by the host on shutdown).
///
/// Thread safety:
/// `mixAudio` runs on miniaudio's audio callback thread, concurrently with
/// game-thread calls to load/play/unload. All access to the shared `sounds`
/// and `music_slots` arrays is guarded by `slot_lock`, an atomic-flag
/// spinlock (acquire on enter / release on exit). Zig 0.16 removed
/// `std.Thread.Mutex`, so we use `std.atomic.Value(bool)` directly.
///
/// This fixes the former `unloadSound`/`unloadMusic` vs `mixAudio`
/// use-after-free race (#298): unload now takes `slot_lock`, so it cannot
/// free PCM data while the mixer is reading it. Critical sections are kept
/// tight — the mixer holds the lock only while touching slot state, and
/// the actual `free()` in unload happens after the slot has been detached
/// and the lock released.
///
/// Android (#306): the miniaudio playback device is desktop-only — its C
/// TU and the per-OS audio frameworks aren't built for Android (AAudio is
/// a later task). On Android the device backend is a no-op stub, so this
/// module is a *device-less* mixer: it decodes/loads/mixes exactly as on
/// desktop, but nothing pumps `mixAudio`, so audio is silent on-device
/// until the AAudio path lands. Selecting the backend at comptime
/// (`device_backend`) keeps every `miniaudio.h` reference out of the
/// Android build's semantic analysis.
const std = @import("std");
const builtin = @import("builtin");

const is_android = builtin.target.os.tag == .linux and
    (builtin.target.abi == .android or builtin.target.abi == .androideabi);

/// Device-less stub used on Android (and anywhere without a real output
/// device). Mirrors `audio_device.zig`'s control surface so `ensureInit`
/// / `deinit` call through it unchanged: starting is a no-op, stopping is
/// a no-op, and zero frames are ever mixed.
const NoopDevice = struct {
    pub const MixFn = *const fn (output: []i16, frames_requested: u32) void;
    pub fn ensureStarted(mix: MixFn) void {
        _ = mix; // no device drives the mixer on this target
    }
    pub fn stop() void {}
    pub fn framesMixed() u64 {
        return 0;
    }
};

// On Android the miniaudio `@cImport` (and `miniaudio.h` itself) must not
// be analyzed — the header isn't on the include path and the device libs
// aren't linked. `if (is_android)` is comptime, so only the taken branch
// is semantically analyzed per target.
const device_backend = if (is_android) NoopDevice else @import("audio_device.zig");

const MAX_SOUNDS = 256;
const MAX_MUSIC = 32;

// ── Slot-array spinlock (#298) ───────────────────────────────────────
//
// Guards `sounds` and `music_slots` against concurrent access by the
// game thread and miniaudio's audio callback thread. Zig 0.16 removed
// `std.Thread.Mutex`, so this is a hand-rolled test-and-test-and-set
// spinlock over an atomic bool with acquire/release ordering.
//
// Contention is effectively zero (the mixer holds it for microseconds
// per callback and game-thread audio calls are infrequent), so spinning
// is cheaper than a futex here and needs no OS primitive.
var slot_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn lockSlots() void {
    while (true) {
        // Fast path: try to flip false→true with acquire ordering.
        if (!slot_lock.swap(true, .acquire)) return;
        // Slow path: spin on a relaxed load until it looks free, then
        // retry the swap (test-and-test-and-set to avoid cache-line
        // ping-pong while contended).
        while (slot_lock.load(.monotonic)) {
            std.atomic.spinLoopHint();
        }
    }
}

fn unlockSlots() void {
    slot_lock.store(false, .release);
}

// ── WAV PCM data ─────────────────────────────────────────────────────

const PcmData = struct {
    samples: []const i16, // interleaved stereo PCM
    channels: u16,
    sample_rate: u32,
    frame_count: u32, // total frames (samples / channels)
    raw_alloc: []u8, // backing allocation for cleanup
};

// ── Sound state ──────────────────────────────────────────────────────

const SoundSlot = struct {
    pcm: ?PcmData = null,
    playing: bool = false,
    position: u32 = 0, // current frame position
    volume: f32 = 1.0,
};

const MusicSlot = struct {
    pcm: ?PcmData = null,
    playing: bool = false,
    paused: bool = false,
    position: u32 = 0,
    volume: f32 = 1.0,
    looping: bool = true,
};

var sounds: [MAX_SOUNDS]SoundSlot = [_]SoundSlot{.{}} ** MAX_SOUNDS;
var music_slots: [MAX_MUSIC]MusicSlot = [_]MusicSlot{.{}} ** MAX_MUSIC;
var next_sound_id: u32 = 1;
var next_music_id: u32 = 1;
var master_volume: f32 = 1.0;

// ── Playback device (#297, #306) ─────────────────────────────────────
//
// The actual output device lives in `device_backend` (selected at
// comptime above): the real miniaudio playback device on desktop, a
// no-op stub on Android. `ensureInit` lazily starts it and wires
// `mixAudio` as the audio-thread fill callback; `deinit` stops it. All
// `ma_device` / `miniaudio.h` knowledge is confined to
// `audio_device.zig`, so this module compiles for Android unchanged.

/// Open the playback device on first use, driving `mixAudio` from its
/// audio-thread callback. Idempotent and cheap to call from every public
/// entry point that can start audio. On Android this is a no-op (no
/// device); the mixer state advances only when something pumps `mixAudio`.
pub fn ensureInit() void {
    device_backend.ensureStarted(&mixAudio);
}

/// Stop and close the playback device, then free all loaded PCM. Must be
/// called by the host on shutdown. On desktop `device_backend.stop` joins
/// the audio thread before returning, so after it the slots are no longer
/// touched by the callback and we can free them without taking
/// `slot_lock`. On Android `stop` is a no-op and no audio thread ever ran.
pub fn deinit() void {
    device_backend.stop();

    // Free any PCM the game didn't explicitly unload. The audio thread is
    // gone (or never existed, on Android), so no lock is needed.
    for (&sounds) |*slot| {
        if (slot.pcm) |pcm| {
            if (pcm.raw_alloc.len > 0) std.heap.page_allocator.free(pcm.raw_alloc);
        }
        slot.* = .{};
    }
    for (&music_slots) |*slot| {
        if (slot.pcm) |pcm| {
            if (pcm.raw_alloc.len > 0) std.heap.page_allocator.free(pcm.raw_alloc);
        }
        slot.* = .{};
    }
    next_sound_id = 1;
    next_music_id = 1;
    master_volume = 1.0;
}

// ── WAV decoder ──────────────────────────────────────────────────────

const WavHeader = extern struct {
    riff: [4]u8, // "RIFF"
    file_size: u32,
    wave: [4]u8, // "WAVE"
};

fn decodeWav(file_data: []const u8) ?PcmData {
    if (file_data.len < @sizeOf(WavHeader) + 8) return null;

    // Validate RIFF/WAVE header
    if (!std.mem.eql(u8, file_data[0..4], "RIFF")) return null;
    if (!std.mem.eql(u8, file_data[8..12], "WAVE")) return null;

    // Parse chunks to find fmt and data
    var channels: u16 = 0;
    var sample_rate: u32 = 0;
    var bits_per_sample: u16 = 0;
    var data_offset: usize = 0;
    var data_size: u32 = 0;
    var audio_format: u16 = 0;

    var offset: usize = 12; // skip RIFF header
    while (offset + 8 <= file_data.len) {
        const chunk_id = file_data[offset .. offset + 4];
        const chunk_size: usize = @intCast(std.mem.readInt(u32, file_data[offset + 4 ..][0..4], .little));

        // Validate chunk data fits within file bounds
        if (offset + 8 + chunk_size > file_data.len) break;

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (chunk_size < 16) return null;
            // Ensure fmt chunk has enough bytes for all fields we read (offset+24 from chunk start)
            if (offset + 24 > file_data.len) return null;
            audio_format = std.mem.readInt(u16, file_data[offset + 8 ..][0..2], .little);
            channels = std.mem.readInt(u16, file_data[offset + 10 ..][0..2], .little);
            sample_rate = std.mem.readInt(u32, file_data[offset + 12 ..][0..4], .little);
            bits_per_sample = std.mem.readInt(u16, file_data[offset + 22 ..][0..2], .little);
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            data_offset = offset + 8;
            data_size = @intCast(chunk_size);
        }

        const advance = 8 + chunk_size;
        if (offset + advance > file_data.len) break;
        offset += advance;
        // Chunks are 2-byte aligned
        if (chunk_size % 2 != 0) {
            if (offset + 1 > file_data.len) break;
            offset += 1;
        }
    }

    // Only support PCM format (1) with 16-bit samples
    if (audio_format != 1) return null;
    if (bits_per_sample != 16) return null;
    if (channels == 0 or channels > 2) return null;
    if (data_offset == 0 or data_size == 0) return null;
    if (data_offset + data_size > file_data.len) {
        // Clamp to available data
        data_size = @intCast(file_data.len - data_offset);
    }

    const data_size_usize: usize = @intCast(data_size);
    const sample_count: usize = data_size_usize / 2; // 16-bit samples
    const frame_count: u32 = @intCast(sample_count / channels);

    // Ensure PCM data is properly aligned for i16 before reinterpreting
    if (data_offset % @alignOf(i16) != 0) return null;

    // Reinterpret the raw bytes as i16 samples (WAV is always little-endian)
    const samples_ptr: [*]const i16 = @ptrCast(@alignCast(file_data[data_offset..].ptr));

    return PcmData{
        .samples = samples_ptr[0..sample_count],
        .channels = channels,
        .sample_rate = sample_rate,
        .frame_count = frame_count,
        .raw_alloc = &.{}, // will be set by caller
    };
}

// Zig 0.16 removed `std.fs.cwd()` in favour of `std.Io.Dir.cwd()`, which
// requires an `Io` parameter threaded through the call site. This is
// the legacy path-based WAV loader — production audio loading goes
// through the higher-level asset pipeline and rarely (if ever) touches
// the FS directly through this entry point. Rather than thread `Io`
// through the backend for a one-shot legacy loader, we use libc
// `fopen` / `fread` / `fclose` to keep the existing
// `(path) ?struct{...}` signature. `link_libc = true` is set on the
// audio module (see backends/bgfx/build.zig) so libc is available at
// link time at no extra cost (the bgfx backend's audio module has no
// other C-library dependencies — see the audio module setup in
// build.zig for the explicit `link_libc = true`).
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

fn loadWavFile(path: [:0]const u8) ?struct { pcm: PcmData, alloc: []u8 } {
    // Read the file from disk via libc. See the rationale block above.
    const file = std.c.fopen(path.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(file);

    if (fseek(file, 0, SEEK_END) != 0) return null;
    const file_size_signed = ftell(file);
    if (file_size_signed < 44) return null; // minimum WAV size
    if (fseek(file, 0, SEEK_SET) != 0) return null;
    const file_size: usize = @intCast(file_size_signed);

    const allocator = std.heap.page_allocator;
    const data = allocator.alloc(u8, file_size) catch return null;

    const bytes_read = std.c.fread(data.ptr, 1, file_size, file);
    if (bytes_read != file_size) {
        // `fread` can return short on EOF mid-read without setting an error
        // flag, so we must compare against the full requested size — not
        // just the minimum WAV header — or we'd silently decode a truncated
        // file. See PR #227 (cursor[bot] review).
        std.log.warn("audio: short read on {s} ({d}/{d} bytes)", .{ path, bytes_read, file_size });
        allocator.free(data);
        return null;
    }
    if (bytes_read < 44) { // minimum WAV size
        allocator.free(data);
        return null;
    }

    var pcm = decodeWav(data[0..bytes_read]) orelse {
        allocator.free(data);
        return null;
    };

    // Reject empty PCM. A 0-frame buffer played with looping makes the
    // mixer's wrap math (`position % frame_count`) divide by zero / index
    // out of bounds on the audio thread, so refuse it at load time.
    if (pcm.frame_count == 0) {
        allocator.free(data);
        return null;
    }
    pcm.raw_alloc = data;

    return .{ .pcm = pcm, .alloc = data };
}

// ── Sound effects ──────────────────────────────────────────

/// Find a free sound slot, scanning for recycled (unloaded) slots first,
/// then falling back to the next unused ID.
fn findFreeSoundSlot() ?u32 {
    // Scan for recycled slots (start from 1; slot 0 is reserved/unused)
    for (1..next_sound_id) |i| {
        if (sounds[i].pcm == null) {
            return @intCast(i);
        }
    }
    // Fall back to the next never-used slot
    if (next_sound_id < MAX_SOUNDS) {
        const id = next_sound_id;
        next_sound_id += 1;
        return id;
    }
    return null;
}

pub fn loadSound(path: [:0]const u8) u32 {
    // Open the device on first load so playback works without the host
    // calling an explicit init.
    ensureInit();

    // Decode off-lock — file IO + allocation must not block the mixer.
    const result = loadWavFile(path) orelse return 0;

    lockSlots();
    const id = findFreeSoundSlot() orelse {
        unlockSlots();
        std.heap.page_allocator.free(result.alloc);
        return 0;
    };
    sounds[id] = .{
        .pcm = result.pcm,
        .playing = false,
        .position = 0,
        .volume = 1.0,
    };
    unlockSlots();
    return id;
}

pub fn unloadSound(id: u32) void {
    if (id >= MAX_SOUNDS) return;

    // Detach the slot under the lock so the mixer can't observe a
    // half-freed PcmData, then free the backing allocation after
    // releasing the lock — by which point the mixer no longer holds a
    // pointer into it (#298).
    lockSlots();
    const pcm = sounds[id].pcm;
    sounds[id] = .{};
    unlockSlots();

    if (pcm) |p| {
        if (p.raw_alloc.len > 0) std.heap.page_allocator.free(p.raw_alloc);
    }
}

pub fn playSound(id: u32) void {
    ensureInit();
    if (id >= MAX_SOUNDS) return;
    lockSlots();
    sounds[id].playing = true;
    sounds[id].position = 0;
    unlockSlots();
}

pub fn stopSound(id: u32) void {
    if (id >= MAX_SOUNDS) return;
    lockSlots();
    sounds[id].playing = false;
    sounds[id].position = 0;
    unlockSlots();
}

pub fn isSoundPlaying(id: u32) bool {
    if (id >= MAX_SOUNDS) return false;
    lockSlots();
    defer unlockSlots();
    return sounds[id].playing;
}

pub fn setSoundVolume(id: u32, volume: f32) void {
    if (id >= MAX_SOUNDS) return;
    lockSlots();
    sounds[id].volume = std.math.clamp(volume, 0.0, 1.0);
    unlockSlots();
}

// ── Music (streaming) ──────────────────────────────────────

/// Find a free music slot, scanning for recycled (unloaded) slots first,
/// then falling back to the next unused ID.
fn findFreeMusicSlot() ?u32 {
    for (1..next_music_id) |i| {
        if (music_slots[i].pcm == null) {
            return @intCast(i);
        }
    }
    if (next_music_id < MAX_MUSIC) {
        const id = next_music_id;
        next_music_id += 1;
        return id;
    }
    return null;
}

pub fn loadMusic(path: [:0]const u8) u32 {
    ensureInit();

    const result = loadWavFile(path) orelse return 0;

    lockSlots();
    const id = findFreeMusicSlot() orelse {
        unlockSlots();
        std.heap.page_allocator.free(result.alloc);
        return 0;
    };
    music_slots[id] = .{
        .pcm = result.pcm,
        .playing = false,
        .paused = false,
        .position = 0,
        .volume = 1.0,
        .looping = true,
    };
    unlockSlots();
    return id;
}

pub fn unloadMusic(id: u32) void {
    if (id >= MAX_MUSIC) return;

    // Same detach-then-free ordering as `unloadSound` so the mixer can't
    // UAF a music buffer mid-callback (#298).
    lockSlots();
    const pcm = music_slots[id].pcm;
    music_slots[id] = .{};
    unlockSlots();

    if (pcm) |p| {
        if (p.raw_alloc.len > 0) std.heap.page_allocator.free(p.raw_alloc);
    }
}

pub fn playMusic(id: u32) void {
    ensureInit();
    if (id >= MAX_MUSIC) return;
    lockSlots();
    music_slots[id].playing = true;
    music_slots[id].paused = false;
    music_slots[id].position = 0;
    unlockSlots();
}

pub fn stopMusic(id: u32) void {
    if (id >= MAX_MUSIC) return;
    lockSlots();
    music_slots[id].playing = false;
    music_slots[id].paused = false;
    music_slots[id].position = 0;
    unlockSlots();
}

pub fn pauseMusic(id: u32) void {
    if (id >= MAX_MUSIC) return;
    lockSlots();
    if (music_slots[id].playing) music_slots[id].paused = true;
    unlockSlots();
}

pub fn resumeMusic(id: u32) void {
    if (id >= MAX_MUSIC) return;
    lockSlots();
    if (music_slots[id].paused) music_slots[id].paused = false;
    unlockSlots();
}

pub fn isMusicPlaying(id: u32) bool {
    if (id >= MAX_MUSIC) return false;
    lockSlots();
    defer unlockSlots();
    return music_slots[id].playing and !music_slots[id].paused;
}

pub fn setMusicVolume(id: u32, volume: f32) void {
    if (id >= MAX_MUSIC) return;
    lockSlots();
    music_slots[id].volume = std.math.clamp(volume, 0.0, 1.0);
    unlockSlots();
}

pub fn updateMusic(id: u32) void {
    // Music playback position is advanced exclusively in `mixAudio`,
    // which is driven by the audio device callback. This function is
    // kept for API compatibility but intentionally does nothing to
    // avoid frame-rate-based timing drift and duplicate advancement.
    _ = id;
}

// ── PCM mixer ────────────────────────────────────────────────────────

/// Mix all active sounds and music into a stereo i16 output buffer.
/// Called by the device backend's audio-thread callback to fill the
/// output device (desktop). On Android nothing calls this yet (no device).
///
/// Takes `slot_lock` for the duration of the mix so the game thread
/// cannot free PCM data (`unloadSound`/`unloadMusic`) out from under it
/// (#298). The critical section only reads slot state + advances
/// positions; the buffer clear is done up front, outside the lock.
pub fn mixAudio(output: []i16, frames_requested: u32) void {
    const frame_count = @min(frames_requested, @as(u32, @intCast(output.len / 2)));

    // Clear output buffer (no shared state touched yet — keep it off-lock).
    const clear_len: usize = @as(usize, frame_count) * 2;
    @memset(output[0..clear_len], 0);

    lockSlots();
    defer unlockSlots();

    // Mix active sounds
    for (0..MAX_SOUNDS) |i| {
        var slot = &sounds[i];
        if (!slot.playing) continue;
        const pcm = slot.pcm orelse continue;

        const vol = slot.volume * master_volume;
        mixPcmInto(output, frame_count, pcm, &slot.position, vol, false);

        if (slot.position >= pcm.frame_count) {
            slot.playing = false;
            slot.position = 0;
        }
    }

    // Mix active music
    for (0..MAX_MUSIC) |i| {
        var slot = &music_slots[i];
        if (!slot.playing or slot.paused) continue;
        const pcm = slot.pcm orelse continue;

        const vol = slot.volume * master_volume;
        mixPcmInto(output, frame_count, pcm, &slot.position, vol, slot.looping);

        if (!slot.looping and slot.position >= pcm.frame_count) {
            slot.playing = false;
            slot.position = 0;
        }
    }
}

fn mixPcmInto(
    output: []i16,
    frame_count: u32,
    pcm: PcmData,
    position: *u32,
    volume: f32,
    looping: bool,
) void {
    var pos = position.*;
    var frame: u32 = 0;

    while (frame < frame_count) : (frame += 1) {
        if (pos >= pcm.frame_count) {
            if (looping) {
                pos = 0;
            } else {
                break;
            }
        }

        const sample_idx: usize = @as(usize, pos) * @as(usize, pcm.channels);
        const left: f32 = @floatFromInt(pcm.samples[sample_idx]);
        const right: f32 = if (pcm.channels >= 2)
            @floatFromInt(pcm.samples[sample_idx + 1])
        else
            left; // mono: duplicate to both channels

        const out_idx: usize = @as(usize, frame) * 2;
        const mixed_l = @as(f32, @floatFromInt(output[out_idx])) + left * volume;
        const mixed_r = @as(f32, @floatFromInt(output[out_idx + 1])) + right * volume;

        // Clamp to i16 range
        output[out_idx] = @intFromFloat(std.math.clamp(mixed_l, -32768.0, 32767.0));
        output[out_idx + 1] = @intFromFloat(std.math.clamp(mixed_r, -32768.0, 32767.0));

        pos += 1;
    }

    position.* = pos;
}

// ── Global ────────────────────────────────────────────────

pub fn setVolume(volume: f32) void {
    // Guarded too: the mixer reads `master_volume` under `slot_lock`.
    lockSlots();
    master_volume = std.math.clamp(volume, 0.0, 1.0);
    unlockSlots();
}

// ── Tests ─────────────────────────────────────────────────────────────
//
// These exercise the pure-Zig surface (spinlock, mixer, WAV decode,
// unload detach/free ordering) without opening a miniaudio device, so
// they run headlessly in CI. The device path is verified manually via
// the example (see PR notes).

const testing = std.testing;

fn resetStateForTest() void {
    sounds = [_]SoundSlot{.{}} ** MAX_SOUNDS;
    music_slots = [_]MusicSlot{.{}} ** MAX_MUSIC;
    next_sound_id = 1;
    next_music_id = 1;
    master_volume = 1.0;
}

test "spinlock is exclusive and re-acquirable" {
    try testing.expect(!slot_lock.load(.monotonic));
    lockSlots();
    try testing.expect(slot_lock.load(.monotonic));
    unlockSlots();
    try testing.expect(!slot_lock.load(.monotonic));
    // Re-acquire to prove release left it usable.
    lockSlots();
    unlockSlots();
}

test "mixAudio clears output when nothing is playing" {
    resetStateForTest();
    var buf = [_]i16{ 123, 45, -67, 89 }; // 2 stereo frames
    mixAudio(&buf, 2);
    for (buf) |s| try testing.expectEqual(@as(i16, 0), s);
}

test "mixAudio mixes a playing sound and stops at end" {
    resetStateForTest();
    // 2-frame stereo PCM: [L0,R0, L1,R1]
    const pcm_samples = [_]i16{ 100, 200, 300, 400 };
    sounds[1] = .{
        .pcm = .{
            .samples = &pcm_samples,
            .channels = 2,
            .sample_rate = 48000,
            .frame_count = 2,
            .raw_alloc = &.{}, // static backing — unload must not free it
        },
        .playing = true,
        .position = 0,
        .volume = 1.0,
    };

    var out = [_]i16{0} ** 4; // request 2 frames
    mixAudio(&out, 2);
    try testing.expectEqual(@as(i16, 100), out[0]);
    try testing.expectEqual(@as(i16, 200), out[1]);
    try testing.expectEqual(@as(i16, 300), out[2]);
    try testing.expectEqual(@as(i16, 400), out[3]);
    // Sound reached its end → auto-stopped.
    try testing.expect(!sounds[1].playing);
}

test "unloadSound detaches slot then frees its allocation" {
    resetStateForTest();
    // `unloadSound` frees `raw_alloc` via page_allocator, so allocate it
    // there. A double-free or use of the slot after free would trip the
    // allocator / sanitizer.
    const raw = try std.heap.page_allocator.alloc(u8, 8);
    const samples: [*]const i16 = @ptrCast(@alignCast(raw.ptr));
    sounds[1] = .{
        .pcm = .{
            .samples = samples[0..4],
            .channels = 2,
            .sample_rate = 48000,
            .frame_count = 2,
            .raw_alloc = raw,
        },
        .playing = true,
        .position = 0,
        .volume = 1.0,
    };

    unloadSound(1);
    // Slot fully reset and PCM detached (the buffer is now freed).
    try testing.expect(sounds[1].pcm == null);
    try testing.expect(!sounds[1].playing);
}

test "WAV decoder accepts a minimal stereo s16 buffer" {
    // Build a 44-byte-header WAV with one stereo frame.
    var wav: [44 + 4]u8 = undefined;
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 36 + 4, .little);
    @memcpy(wav[8..12], "WAVE");
    @memcpy(wav[12..16], "fmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, wav[22..24], 2, .little); // stereo
    std.mem.writeInt(u32, wav[24..28], 48000, .little);
    std.mem.writeInt(u32, wav[28..32], 48000 * 4, .little);
    std.mem.writeInt(u16, wav[32..34], 4, .little); // block align
    std.mem.writeInt(u16, wav[34..36], 16, .little); // bits
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], 4, .little);
    std.mem.writeInt(i16, wav[44..46], 111, .little);
    std.mem.writeInt(i16, wav[46..48], 222, .little);

    const pcm = decodeWav(&wav) orelse return error.DecodeFailed;
    try testing.expectEqual(@as(u16, 2), pcm.channels);
    try testing.expectEqual(@as(u32, 48000), pcm.sample_rate);
    try testing.expectEqual(@as(u32, 1), pcm.frame_count);
    try testing.expectEqual(@as(i16, 111), pcm.samples[0]);
    try testing.expectEqual(@as(i16, 222), pcm.samples[1]);
}

test "WAV decoder rejects non-RIFF data" {
    var junk = [_]u8{0xAB} ** 64;
    try testing.expect(decodeWav(&junk) == null);
}
