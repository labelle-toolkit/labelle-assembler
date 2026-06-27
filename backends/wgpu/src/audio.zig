/// WebGPU audio backend — satisfies the engine AudioInterface(Impl) contract.
///
/// Phase 2 of the pluggable-backends RFC (fan-out of the bgfx pilot): the WAV
/// decode + PCM mixer + slot management that this file used to reimplement
/// (~290 lines here, plus the ~415-line `wav_parser.zig`) now live in the
/// shared `labelle-audio` package. This file is a thin adapter.
///
/// WebGPU has no audio API and there is **no real OS playback device** behind
/// this backend — nothing pumps a device callback. So this adapter instantiates
/// the shared mixer over the shared `NullSink`:
///
///   * `Mixer(NullSink)` is fully usable software-pumped: `loadSoundFromMemory`
///     / `playSound` / `mix` etc. all work without a device thread. `NullSink`
///     records the mix callback (`ensureStarted`) but never invokes it, so the
///     host is responsible for pulling mixed samples — exactly the old wgpu
///     contract, where higher-level code fed mixed PCM to the real device.
///   * Every `pub fn` below forwards to `Audio.*`, preserving wgpu's public
///     audio API names + signatures verbatim (the engine/assembler call them by
///     name).
///   * The only wgpu-specific logic that remains is the libc file-read shim
///     behind the path-based `loadSound`/`loadMusic` and the f32 `mixOutput`
///     adapter (see below).
///
/// ## i16 vs f32
///
/// The shared mixer is **i16**; wgpu's old mixer was f32. wgpu's f32 mix output
/// was software-only and had **no consumer** anywhere in the assembler, the
/// templates, or the engine wiring (`mixOutput` is referenced nowhere outside
/// this file), so collapsing onto the i16 mixer loses nothing. To keep the
/// public `mixOutput(output: []f32, frame_count: usize)` signature byte-for-byte
/// (it's part of wgpu's exposed surface), the adapter mixes into a small i16
/// scratch buffer and converts to normalized [-1, 1] f32 — the same range the
/// old f32 mixer produced. If a future device path needs to consume mixed f32
/// directly at scale, lift the conversion into the shared mixer (see the
/// `TODO(f32)` in `labelle-audio/src/device_sink.zig`) rather than re-growing a
/// per-backend mixer here.
///
/// Thread-safety, the unload/mix UAF fix, the spinlock, mono→stereo
/// duplication, and the overflow-safe WAV decode are all provided by the shared
/// mixer (see `labelle-audio/src/mixer.zig` + `wav.zig`); nothing about that
/// behaviour changes here.
const std = @import("std");
const labelle_audio = @import("labelle-audio");

/// The shared PCM mixer, parameterized by the shared `NullSink` (wgpu has no
/// real OS device — it's software-pumped via `mixOutput`). Owns WAV decode +
/// slot arrays + the spinlock + the full AudioInterface surface; the public fns
/// below forward to it.
const Audio = labelle_audio.Mixer(labelle_audio.NullSink);

// ── Path-based file-read shim ────────────────────────────────────────
//
// The shared mixer is byte-buffer based (`loadSoundFromMemory`), but wgpu's
// public `loadSound`/`loadMusic` take a file path. Zig 0.16 removed
// `std.fs.cwd()` in favour of `std.Io.Dir.cwd()`, which requires an `Io`
// threaded through the call site. Rather than thread `Io` through the backend
// for a one-shot legacy loader, we read the file via libc `fopen`/`fread`/
// `fclose` — `link_libc = true` is set on the audio module (see
// backends/wgpu/build.zig), so libc is available at no extra cost. The decoded
// bytes are then handed to the shared mixer, which owns decode + ownership.

const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

/// Read an entire file into a freshly page-allocated buffer via libc. Returns
/// null on any IO error or short read (a short `fread` can occur on EOF
/// mid-read without setting an error flag, so we compare against the full
/// requested size). Caller owns the returned slice and frees it via
/// `std.heap.page_allocator`.
fn readFileBytes(path: [:0]const u8) ?[]u8 {
    const file = std.c.fopen(path.ptr, "rb") orelse return null;
    defer _ = std.c.fclose(file);

    if (fseek(file, 0, SEEK_END) != 0) return null;
    const file_size_signed = ftell(file);
    if (file_size_signed < 12) return null; // minimum RIFF/WAVE header
    if (fseek(file, 0, SEEK_SET) != 0) return null;
    const file_size: usize = @intCast(file_size_signed);

    const allocator = std.heap.page_allocator;
    const data = allocator.alloc(u8, file_size) catch return null;

    const bytes_read = std.c.fread(data.ptr, 1, file_size, file);
    if (bytes_read != file_size) {
        allocator.free(data);
        return null;
    }
    return data;
}

// ── Sound effects ──────────────────────────────────────────────────────

/// Load a WAV file from `path` and register it as a sound effect. Reads the
/// file via the libc shim, then hands the bytes to the shared mixer (which owns
/// decode + the PCM). Returns the sound id, or 0 on failure.
pub fn loadSound(path: [:0]const u8) u32 {
    const bytes = readFileBytes(path) orelse return 0;
    defer std.heap.page_allocator.free(bytes);
    return Audio.loadSoundFromMemory(bytes);
}

pub fn unloadSound(id: u32) void {
    Audio.unloadSound(id);
}

pub fn playSound(id: u32) void {
    Audio.playSound(id);
}

pub fn stopSound(id: u32) void {
    Audio.stopSound(id);
}

pub fn isSoundPlaying(id: u32) bool {
    return Audio.isSoundPlaying(id);
}

pub fn setSoundVolume(id: u32, volume: f32) void {
    Audio.setSoundVolume(id, volume);
}

// ── Music (streaming) ──────────────────────────────────────────────────

/// Load a WAV file from `path` and register it as a looping music stream. Same
/// libc file-read shim as `loadSound`. Returns the music id, or 0 on failure.
pub fn loadMusic(path: [:0]const u8) u32 {
    const bytes = readFileBytes(path) orelse return 0;
    defer std.heap.page_allocator.free(bytes);
    return Audio.loadMusicFromMemory(bytes);
}

pub fn unloadMusic(id: u32) void {
    Audio.unloadMusic(id);
}

pub fn playMusic(id: u32) void {
    Audio.playMusic(id);
}

pub fn stopMusic(id: u32) void {
    Audio.stopMusic(id);
}

pub fn pauseMusic(id: u32) void {
    Audio.pauseMusic(id);
}

pub fn resumeMusic(id: u32) void {
    Audio.resumeMusic(id);
}

pub fn isMusicPlaying(id: u32) bool {
    return Audio.isMusicPlaying(id);
}

pub fn setMusicVolume(id: u32, volume: f32) void {
    Audio.setMusicVolume(id, volume);
}

pub fn updateMusic(id: u32) void {
    Audio.updateMusic(id);
}

// ── Global ────────────────────────────────────────────────────────────

pub fn setVolume(volume: f32) void {
    Audio.setVolume(volume);
}

/// Software mixer: mix all active sounds and music into an output buffer.
/// `output` is interleaved stereo f32, `frame_count` is the number of stereo
/// frames. Since wgpu has no real OS device, the host calls this on its own
/// tick to pull mixed samples (the old contract).
///
/// The shared mixer is i16, so we mix `frame_count` stereo frames into a small
/// i16 scratch buffer (chunked, so an arbitrarily large `frame_count` never
/// needs an unbounded stack/heap buffer) and convert each sample to normalized
/// [-1, 1] f32 — matching the range the old f32 mixer produced. `output` is
/// always written for `min(frame_count * 2, output.len)` samples; any tail is
/// left untouched (the old mixer only wrote `mix_samples` too).
pub fn mixOutput(output: []f32, frame_count: usize) void {
    const CHANNELS: usize = 2;
    // Clamp to whole stereo frames BEFORE multiplying — `frame_count * CHANNELS`
    // would overflow/trap for a huge caller value. Bounding frames by
    // `output.len / CHANNELS` first keeps the product ≤ output.len, and makes
    // `mix_samples` always an even (frame-aligned) count.
    const frames = @min(frame_count, output.len / CHANNELS);
    const mix_samples = frames * CHANNELS;

    // i16 scratch, processed in frame-aligned chunks so a huge `frame_count`
    // doesn't blow the stack. 1024 stereo frames = 2048 i16 = 4 KiB.
    var scratch: [2048]i16 = undefined;

    var done: usize = 0;
    while (done < mix_samples) {
        const remaining = mix_samples - done;
        // Keep the chunk frame-aligned (even sample count) so the mixer's
        // stereo interleave stays correct across chunk boundaries.
        var chunk: usize = @min(remaining, scratch.len);
        chunk -= chunk % CHANNELS;
        if (chunk == 0) break;

        Audio.mix(scratch[0..chunk], CHANNELS);
        for (0..chunk) |i| {
            output[done + i] = @as(f32, @floatFromInt(scratch[i])) / 32768.0;
        }
        done += chunk;
    }
    // No partial-tail handling needed: `mix_samples` is frame-aligned (even), so
    // the loop writes all of `[0..mix_samples]` with no early break, and the
    // caller owns `[mix_samples..]` per this fn's "only writes the frames asked
    // for" contract (Gemini's odd-sample break can't occur now that frames are
    // clamped before the multiply).
}

// ── Tests ─────────────────────────────────────────────────────────────
//
// The decode/mixer/spinlock/UAF behaviour is now tested in `labelle-audio`
// itself. These thin smoke tests confirm the wgpu adapter wires the shared
// mixer correctly (forwarding + the f32 `mixOutput` shim), exercised headlessly
// via `NullSink` (no device).

const testing = std.testing;

test "mixOutput clears output when nothing is playing" {
    Audio.resetForTest();
    var buf = [_]f32{ 0.5, -0.5, 0.25, -0.25 }; // 2 stereo frames
    mixOutput(&buf, 2);
    for (buf) |s| try testing.expectEqual(@as(f32, 0), s);
}

test "mixOutput only writes the frames it is asked for" {
    Audio.resetForTest();
    // Ask for 1 stereo frame into a 3-frame buffer; the tail is untouched.
    var buf = [_]f32{ 9, 9, 9, 9, 9, 9 };
    mixOutput(&buf, 1);
    try testing.expectEqual(@as(f32, 0), buf[0]);
    try testing.expectEqual(@as(f32, 0), buf[1]);
    try testing.expectEqual(@as(f32, 9), buf[2]);
}
