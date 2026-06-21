//! Minimal bgfx-Android video app (FP#549) — proves the VideoPlayer draws
//! through real bgfx on a device. Mirrors templates/android.txt's callback
//! shape (gameInit/gameFrame/android_main) but skips the engine: it just opens
//! the bundled intro.mp4 asset, decodes it with the Android AMediaCodec decoder,
//! and draws it fullscreen via gfx.VideoPlayer → bgfx dynamic texture.
//!
//! This is the "phase 4" full Android .so link the backend's compile-checks
//! deferred — built by the `android-app` step in build.zig.

const std = @import("std");
const android_app = @import("backend_app");
const gfx = @import("backend_gfx");
const window = @import("window");
const audio = @import("audio");
const android_audio = @import("android_audio");

pub const labelle_provides_android_main = true;

// NDK asset access (libandroid).
const AAssetManager = opaque {};
const AAsset = opaque {};
extern fn AAssetManager_open(*AAssetManager, [*:0]const u8, c_int) ?*AAsset;
extern fn AAsset_openFileDescriptor64(*AAsset, *i64, *i64) c_int;
extern fn AAsset_close(*AAsset) void;
const AASSET_MODE_STREAMING: c_int = 2;

var gpa = std.heap.DebugAllocator(.{}).init;

const Player = gfx.VideoPlayer(gfx.AndroidVideoDecoder);
var player: ?Player = null;
var asset_mgr: ?*AAssetManager = null;

// The clip's decoded audio track, loaded into labelle's streaming-music
// mixer. The VideoPlayer drives it via the audio hooks below; the `.clock`
// hook (audio device position) is the master clock that makes the SAME
// PTS-accurate A/V sync that runs on desktop run here on Android.
var vid_music_id: u32 = 0;

fn vidAudioStart(_: ?*anyopaque) void {
    if (vid_music_id != 0) audio.playMusic(vid_music_id);
}
fn vidAudioUpdate(_: ?*anyopaque) void {
    if (vid_music_id != 0) audio.updateMusic(vid_music_id);
}
fn vidAudioStop(_: ?*anyopaque) void {
    if (vid_music_id != 0) audio.stopMusic(vid_music_id);
}
/// Audio device playback position — the master clock for PTS-accurate sync.
fn vidAudioClock(_: ?*anyopaque) f64 {
    return if (vid_music_id != 0) audio.musicPositionSeconds(vid_music_id) else 0;
}

const screen_w: u32 = 1024;
const screen_h: u32 = 768;
const target_fps: u32 = 60;

/// Surface-ready: bgfx is live. Open the intro asset, decode, build the player.
fn gameInit() callconv(.c) void {
    const am = asset_mgr orelse return;
    const asset = AAssetManager_open(am, "intro.mp4", AASSET_MODE_STREAMING) orelse return;
    defer AAsset_close(asset);
    var start: i64 = 0;
    var len: i64 = 0;
    const fd = AAsset_openFileDescriptor64(asset, &start, &len);
    if (fd < 0) return;
    const dec = gfx.AndroidVideoDecoder.openFd(gpa.allocator(), fd, start, len) catch return;
    player = Player.init(gpa.allocator(), dec, 24.0) catch return;

    // ── Audio track → music mixer → VideoPlayer clock (PTS sync) ─────────
    // Re-open the asset for a FRESH fd: the video decoder owns the one above
    // (its AMediaExtractor keeps reading it), so the audio decoder needs its
    // own. Decode the whole AAC track to 48k stereo PCM, load it as music,
    // and attach the hooks so the player drives audio in lockstep and reads
    // its position as the master clock. Best-effort: a missing audio track or
    // no AAudio device leaves the demo video-only (vid_music_id stays 0).
    if (AAssetManager_open(am, "intro.mp4", AASSET_MODE_STREAMING)) |a_asset| {
        defer AAsset_close(a_asset);
        var a_start: i64 = 0;
        var a_len: i64 = 0;
        const a_fd = AAsset_openFileDescriptor64(a_asset, &a_start, &a_len);
        if (a_fd >= 0) {
            if (android_audio.decodeTrack(gpa.allocator(), a_fd, a_start, a_len)) |pcm| {
                var p = pcm;
                defer p.deinit(gpa.allocator());
                vid_music_id = audio.loadMusicFromPcm(p.samples, 2, 48000);
                if (vid_music_id != 0) {
                    player.?.setAudio(.{
                        .start = &vidAudioStart,
                        .update = &vidAudioUpdate,
                        .stop = &vidAudioStop,
                        .clock = &vidAudioClock, // master clock → PTS sync
                    });
                }
            } else |_| {}
        }
    }
}

/// Per-frame: advance + draw the video fullscreen through bgfx.
fn gameFrame() callconv(.c) void {
    const dt: f32 = @min(
        @as(f32, @floatCast(window.frameDuration())),
        4.0 / @as(f32, @floatFromInt(target_fps)),
    );
    gfx.setScreenSize(window.getScreenWidth(), window.getScreenHeight());
    gfx.setDesignSize(@intCast(screen_w), @intCast(screen_h));

    window.beginDrawing();
    window.clearBackground(10, 10, 16, 255);
    if (player) |*p| {
        p.update(dt);
        p.draw(.{ .x = 0, .y = 0, .width = @floatFromInt(screen_w), .height = @floatFromInt(screen_h) });
    }
    window.endDrawing();
}

// The input module's gamepad JNI glue calls these device-detection callbacks,
// which the engine normally implements. This engine-less demo doesn't use
// gamepads, so no-op stubs satisfy the dynamic linker (else dlopen of the .so
// fails on the undefined symbols).
export fn labelle_android_on_device_added(device_id: c_int, sources: c_int, name_ptr: ?[*]const u8, name_len: usize, desc_ptr: ?[*]const u8, desc_len: usize) callconv(.c) void {
    _ = .{ device_id, sources, name_ptr, name_len, desc_ptr, desc_len };
}
export fn labelle_android_on_device_removed(device_id: c_int) callconv(.c) void {
    _ = device_id;
}

export fn android_main(app: *android_app.android_app) callconv(.c) void {
    if (app.activity) |act| {
        // assetManager is the 8th field of ANativeActivity (after callbacks):
        // vm, env, clazz, internalDataPath, externalDataPath, sdkVersion(+pad),
        // instance, assetManager → tail index 7.
        asset_mgr = @ptrCast(act._tail[7]);
    }
    android_app.setInitCallback(&gameInit);
    android_app.setTickCallback(&gameFrame);
    android_app.run(app);
}
