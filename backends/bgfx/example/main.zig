/// LaBelle v2 — bgfx Backend Demo
///
/// A comprehensive example showcasing all bgfx backend features:
/// gfx (shapes, polygons, text, camera), input (keyboard, mouse),
/// audio (sound effects, music), and window management.
///
/// Controls:
///   WASD / Arrow keys  — move player
///   Space              — play sound effect
///   M                  — toggle music playback
///   G                  — toggle gizmo overlay
///   R                  — reset camera zoom
///   Mouse wheel        — zoom in/out
///   Escape             — quit
const std = @import("std");
const gfx = @import("gfx");
const input = @import("input");
const audio = @import("audio");
const window = @import("window");
const gamepad_overlay = @import("gamepad_overlay.zig");

// ── GLFW key codes ─────────────────────────────────────────────────────

const KEY_W: u32 = 87;
const KEY_A: u32 = 65;
const KEY_S: u32 = 83;
const KEY_D: u32 = 68;
const KEY_R: u32 = 82;
const KEY_G: u32 = 71;
const KEY_M: u32 = 77;
const KEY_SPACE: u32 = 32;
const KEY_ESCAPE: u32 = 256;
const KEY_UP: u32 = 265;
const KEY_DOWN: u32 = 264;
const KEY_LEFT: u32 = 263;
const KEY_RIGHT: u32 = 262;

// ── Screen dimensions ──────────────────────────────────────────────────

const SCREEN_W: i32 = 800;
const SCREEN_H: i32 = 600;
const SCREEN_W_F: f32 = @floatFromInt(SCREEN_W);
const SCREEN_H_F: f32 = @floatFromInt(SCREEN_H);

// ── Entity state ───────────────────────────────────────────────────────

const Enemy = struct {
    x: f32,
    y: f32,
    patrol_cx: f32,
    patrol_cy: f32,
    patrol_rx: f32,
    patrol_ry: f32,
    phase: f32,
    speed: f32,
    radius: f32,
};

const Platform = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

// ── Application state ──────────────────────────────────────────────────

var player_x: f32 = 400.0;
var player_y: f32 = 300.0;
var player_vx: f32 = 0.0;
var player_vy: f32 = 0.0;
var player_moving: bool = false;
var player_color_phase: f32 = 0.0;

var enemies = [3]Enemy{
    .{ .x = 200, .y = 150, .patrol_cx = 200, .patrol_cy = 150, .patrol_rx = 80, .patrol_ry = 30, .phase = 0.0, .speed = 1.5, .radius = 20 },
    .{ .x = 600, .y = 200, .patrol_cx = 600, .patrol_cy = 200, .patrol_rx = 50, .patrol_ry = 60, .phase = 2.0, .speed = 1.0, .radius = 25 },
    .{ .x = 350, .y = 450, .patrol_cx = 350, .patrol_cy = 450, .patrol_rx = 100, .patrol_ry = 20, .phase = 4.0, .speed = 2.0, .radius = 15 },
};

var enemy_alpha_phase: f32 = 0.0;

const platforms = [_]Platform{
    .{ .x = 50, .y = 500, .w = 300, .h = 20 },
    .{ .x = 400, .y = 480, .w = 200, .h = 20 },
    .{ .x = 650, .y = 520, .w = 150, .h = 20 },
    .{ .x = 100, .y = 380, .w = 180, .h = 15 },
    .{ .x = 500, .y = 350, .w = 250, .h = 15 },
};

var hex_rotation: f32 = 0.0;
var hex_color_phase: f32 = 0.0;
const hex_cx: f32 = 600.0;
const hex_cy: f32 = 400.0;
const hex_radius: f32 = 40.0;

var orbiter_angle: f32 = 0.0;
const orbiter_radius: f32 = 100.0;
const orbiter_size: f32 = 12.0;

var camera = gfx.Camera2D{
    .offset = .{ .x = SCREEN_W_F / 2.0, .y = SCREEN_H_F / 2.0 },
    .target = .{ .x = 400.0, .y = 300.0 },
    .rotation = 0,
    .zoom = 1.0,
};

var show_gizmos: bool = false;
var gizmo_toggle_cooldown: f32 = 0.0;
var music_toggle_cooldown: f32 = 0.0;

var sound_id: u32 = 0;
var music_id: u32 = 0;
var music_playing: bool = false;
var sound_loaded: bool = false;
var music_loaded: bool = false;

var frame_count: u64 = 0;

// ── Helpers ────────────────────────────────────────────────────────────

const dt: f32 = 1.0 / 60.0;
const PLAYER_SPEED: f32 = 200.0;
const CAMERA_LERP: f32 = 0.08;

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn colorCycle(phase: f32) gfx.Color {
    const r: u8 = @intFromFloat((@sin(phase) * 0.5 + 0.5) * 255.0);
    const g: u8 = @intFromFloat((@sin(phase + 2.094) * 0.5 + 0.5) * 255.0);
    const b: u8 = @intFromFloat((@sin(phase + 4.189) * 0.5 + 0.5) * 255.0);
    return gfx.color(r, g, b, 255);
}

// ── In-memory WAV beep generator ───────────────────────────────────────
//
// `audio.loadSound` takes a file path, so to exercise the miniaudio
// device (#297) without shipping a binary asset we synthesize a short
// 440 Hz sine "beep" (0.5 s, 48 kHz, stereo i16), write a valid 44-byte
// WAV to a temp file, and load that. Uses libc `fopen`/`fwrite`/`fclose`
// to stay consistent with the backend's libc-based file IO and avoid
// threading an `Io` through (Zig 0.16 removed `std.fs.cwd()`).

const BEEP_SAMPLE_RATE: u32 = 48000;
const BEEP_CHANNELS: u16 = 2;
const BEEP_FREQ: f32 = 440.0;
const BEEP_SECONDS: f32 = 0.5;

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;

fn writeU32Le(buf: []u8, v: u32) void {
    std.mem.writeInt(u32, buf[0..4], v, .little);
}
fn writeU16Le(buf: []u8, v: u16) void {
    std.mem.writeInt(u16, buf[0..2], v, .little);
}

/// Generate a beep WAV in `out` and return the number of bytes written.
/// `out` must be large enough for the 44-byte header + PCM payload.
fn generateBeepWav(out: []u8) usize {
    const beep_frames: u32 = @intFromFloat(@as(f32, @floatFromInt(BEEP_SAMPLE_RATE)) * BEEP_SECONDS);
    const bytes_per_sample: u16 = 2; // i16
    const block_align: u16 = BEEP_CHANNELS * bytes_per_sample;
    const byte_rate: u32 = BEEP_SAMPLE_RATE * block_align;
    const data_size: u32 = beep_frames * block_align;

    // 44-byte canonical PCM WAV header.
    @memcpy(out[0..4], "RIFF");
    writeU32Le(out[4..8], 36 + data_size); // file size - 8
    @memcpy(out[8..12], "WAVE");
    @memcpy(out[12..16], "fmt ");
    writeU32Le(out[16..20], 16); // fmt chunk size
    writeU16Le(out[20..22], 1); // PCM
    writeU16Le(out[22..24], BEEP_CHANNELS);
    writeU32Le(out[24..28], BEEP_SAMPLE_RATE);
    writeU32Le(out[28..32], byte_rate);
    writeU16Le(out[32..34], block_align);
    writeU16Le(out[34..36], 16); // bits per sample
    @memcpy(out[36..40], "data");
    writeU32Le(out[40..44], data_size);

    // Interleaved-stereo i16 sine samples with a short linear fade so the
    // start/end don't click.
    var i: u32 = 0;
    var off: usize = 44;
    const two_pi: f32 = std.math.tau;
    const fade: u32 = BEEP_SAMPLE_RATE / 100; // ~10 ms
    while (i < beep_frames) : (i += 1) {
        const t: f32 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(BEEP_SAMPLE_RATE));
        var amp: f32 = 0.3;
        if (i < fade) amp *= @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(fade));
        if (i >= beep_frames - fade) amp *= @as(f32, @floatFromInt(beep_frames - i)) / @as(f32, @floatFromInt(fade));
        const s: f32 = @sin(two_pi * BEEP_FREQ * t) * amp * 32767.0;
        const sample: i16 = @intFromFloat(std.math.clamp(s, -32768.0, 32767.0));
        writeU16Le(out[off .. off + 2], @bitCast(sample));
        writeU16Le(out[off + 2 .. off + 4], @bitCast(sample));
        off += 4;
    }
    return off;
}

/// Synthesize the beep WAV and write it to `path`. Returns false on any
/// IO failure (caller treats audio as non-fatal).
fn writeBeepWavFile(path: [:0]const u8) bool {
    // 44-byte header + 0.5s * 48k frames * 4 bytes/frame ≈ 96 KB.
    const max_bytes: usize = 44 + @as(usize, @intFromFloat(@as(f32, @floatFromInt(BEEP_SAMPLE_RATE)) * BEEP_SECONDS)) * 4;
    const buf = std.heap.page_allocator.alloc(u8, max_bytes) catch return false;
    defer std.heap.page_allocator.free(buf);

    const n = generateBeepWav(buf);
    const file = fopen(path.ptr, "wb") orelse return false;
    defer _ = fclose(file);
    return fwrite(buf.ptr, 1, n, file) == n;
}

fn hexagonPoints(cx: f32, cy: f32, radius: f32, rotation_deg: f32) [6]gfx.Vector2 {
    var pts: [6]gfx.Vector2 = undefined;
    const rad = rotation_deg * (std.math.pi / 180.0);
    for (0..6) |i| {
        const angle = rad + @as(f32, @floatFromInt(i)) * (std.math.pi / 3.0);
        pts[i] = .{
            .x = cx + radius * @cos(angle),
            .y = cy + radius * @sin(angle),
        };
    }
    return pts;
}

// ── In-engine video via gfx.VideoPlayer (#549 Path A) ─────────────────────
//
// The backend now ships the whole decode→texture wiring: gfx.VideoPlayer owns a
// dynamic texture and a decoder, decodes frames, and uploads + draws them. Here
// we drive it with the desktop ffmpeg decoder; on Android the identical player
// drives gfx.AndroidVideoDecoder (hardware-verified, see src/video/apk/).

const DYN_W: u32 = 256;
const DYN_H: u32 = 192;
const VIDEO_FPS: f32 = 24.0;
const VIDEO_CLIP = "bgfx-video-test.mp4";

const VIDEO_AUDIO = "bgfx-video-audio.wav";
const DesktopPlayer = gfx.VideoPlayer(gfx.DesktopVideoDecoder);
var player: ?DesktopPlayer = null;
var vid_music_id: u32 = 0;

// Audio hooks: the VideoPlayer drives the clip's audio track through labelle's
// streaming-music API, started/ticked/stopped in lockstep with the video.
fn vidAudioStart(_: ?*anyopaque) void {
    if (vid_music_id != 0) audio.playMusic(vid_music_id);
}
fn vidAudioUpdate(_: ?*anyopaque) void {
    if (vid_music_id != 0) audio.updateMusic(vid_music_id);
}
fn vidAudioStop(_: ?*anyopaque) void {
    if (vid_music_id != 0) audio.stopMusic(vid_music_id);
}
/// Audio device playback position — the master clock for PTS-accurate A/V sync.
fn vidAudioClock(_: ?*anyopaque) f64 {
    return if (vid_music_id != 0) audio.musicPositionSeconds(vid_music_id) else 0;
}

/// Generate a self-contained H.264 clip (with audio), open the ffmpeg decoder,
/// hand it to a VideoPlayer, then extract the audio track to a WAV and attach it
/// via labelle's music API. Best-effort: missing ffmpeg → no video panel; no
/// audio device (Android #306) → silent but otherwise identical.
fn initVideo() void {
    const alloc = std.heap.page_allocator;
    gfx.DesktopVideoDecoder.generateTestClip(alloc, VIDEO_CLIP, DYN_W, DYN_H) catch return;
    const dec = gfx.DesktopVideoDecoder.open(alloc, VIDEO_CLIP, DYN_W, DYN_H, VIDEO_FPS) catch return;
    player = DesktopPlayer.init(alloc, dec, VIDEO_FPS) catch return;

    gfx.DesktopVideoDecoder.extractAudioWav(alloc, VIDEO_CLIP, VIDEO_AUDIO) catch return;
    vid_music_id = audio.loadMusic(VIDEO_AUDIO);
    if (vid_music_id != 0) {
        player.?.setAudio(.{
            .start = &vidAudioStart,
            .update = &vidAudioUpdate,
            .stop = &vidAudioStop,
            .clock = &vidAudioClock, // master clock → PTS-accurate sync
        });
    }
}

fn drawVideo() void {
    if (player) |*p| {
        p.draw(.{ .x = 240, .y = 180, .width = 320, .height = 240 });
        const label: [:0]const u8 = if (vid_music_id != 0)
            "gfx.VideoPlayer: H.264 video + audio (#549)"
        else
            "gfx.VideoPlayer: H.264 video (no audio device) (#549)";
        gfx.drawText(label, 232, 164, 10, gfx.color(255, 255, 255, 220));
    }
}

// ── Update ─────────────────────────────────────────────────────────────

fn update() void {
    frame_count += 1;

    // -- Input: movement
    player_vx = 0;
    player_vy = 0;

    if (input.isKeyDown(KEY_W) or input.isKeyDown(KEY_UP)) player_vy = -PLAYER_SPEED;
    if (input.isKeyDown(KEY_S) or input.isKeyDown(KEY_DOWN)) player_vy = PLAYER_SPEED;
    if (input.isKeyDown(KEY_A) or input.isKeyDown(KEY_LEFT)) player_vx = -PLAYER_SPEED;
    if (input.isKeyDown(KEY_D) or input.isKeyDown(KEY_RIGHT)) player_vx = PLAYER_SPEED;

    player_moving = (player_vx != 0 or player_vy != 0);
    player_x += player_vx * dt;
    player_y += player_vy * dt;

    // Clamp player to a generous world area
    player_x = std.math.clamp(player_x, -200.0, 1000.0);
    player_y = std.math.clamp(player_y, -200.0, 800.0);

    // -- Input: sound
    if (input.isKeyDown(KEY_SPACE)) {
        if (sound_loaded) {
            audio.playSound(sound_id);
        }
    }

    // -- Input: music toggle (with cooldown to avoid rapid flicker)
    if (music_toggle_cooldown > 0) {
        music_toggle_cooldown -= dt;
    }
    if (input.isKeyDown(KEY_M) and music_toggle_cooldown <= 0) {
        music_toggle_cooldown = 0.3;
        if (music_loaded) {
            if (music_playing) {
                audio.pauseMusic(music_id);
                music_playing = false;
            } else {
                if (audio.isMusicPlaying(music_id)) {
                    audio.resumeMusic(music_id);
                } else {
                    audio.playMusic(music_id);
                }
                music_playing = true;
            }
        }
    }

    // -- Input: gizmo toggle
    if (gizmo_toggle_cooldown > 0) {
        gizmo_toggle_cooldown -= dt;
    }
    if (input.isKeyDown(KEY_G) and gizmo_toggle_cooldown <= 0) {
        gizmo_toggle_cooldown = 0.3;
        show_gizmos = !show_gizmos;
    }

    // -- Input: camera reset
    if (input.isKeyDown(KEY_R)) {
        camera.zoom = 1.0;
    }

    // -- Input: mouse wheel zoom
    const wheel = input.getMouseWheelMove();
    if (wheel != 0) {
        camera.zoom += wheel * 0.1;
        camera.zoom = std.math.clamp(camera.zoom, 0.25, 4.0);
    }

    // -- Animation: player color cycle when moving
    if (player_moving) {
        player_color_phase += 4.0 * dt;
    }

    // -- Animation: enemy patrol + alpha pulse
    enemy_alpha_phase += 3.0 * dt;
    for (&enemies) |*e| {
        e.phase += e.speed * dt;
        e.x = e.patrol_cx + e.patrol_rx * @cos(e.phase);
        e.y = e.patrol_cy + e.patrol_ry * @sin(e.phase);
    }

    // -- Animation: hexagon spin + color
    hex_rotation += 45.0 * dt;
    hex_color_phase += 2.0 * dt;

    // -- Animation: orbiter circular orbit around player
    orbiter_angle += 2.5 * dt;

    // -- Camera: smooth follow player
    camera.target.x = lerp(camera.target.x, player_x, CAMERA_LERP);
    camera.target.y = lerp(camera.target.y, player_y, CAMERA_LERP);

    // -- Music update (API compatibility call)
    if (music_loaded) {
        audio.updateMusic(music_id);
    }
}

// ── Draw ───────────────────────────────────────────────────────────────

fn draw() void {
    window.beginDrawing();
    window.clearBackground(30, 30, 46, 255);

    // Advance video playback (decodes + uploads a frame when due).
    if (player) |*p| p.update(dt);

    // ── World-space rendering (camera-transformed) ─────────────────
    gfx.beginMode2D(camera);

    // -- Ground platforms (gray rectangles)
    for (platforms) |p| {
        gfx.drawRectangleRec(.{ .x = p.x, .y = p.y, .width = p.w, .height = p.h }, gfx.color(100, 100, 110, 255));
    }

    // -- Enemies (red circles with alpha pulse)
    const alpha_pulse: u8 = @intFromFloat((@sin(enemy_alpha_phase) * 0.3 + 0.7) * 255.0);
    for (enemies) |e| {
        gfx.drawCircle(e.x, e.y, e.radius, gfx.color(220, 50, 50, alpha_pulse));
    }

    // -- Spinning hexagon (drawPolygon)
    const hex_pts = hexagonPoints(hex_cx, hex_cy, hex_radius, hex_rotation);
    const hex_col = colorCycle(hex_color_phase);
    gfx.drawPolygon(&hex_pts, hex_col);

    // -- Orbiter (blue circle on sin/cos path around player)
    const orb_x = player_x + orbiter_radius * @cos(orbiter_angle);
    const orb_y = player_y + orbiter_radius * @sin(orbiter_angle);
    gfx.drawCircle(orb_x, orb_y, orbiter_size, gfx.color(80, 140, 255, 220));

    // -- Player (green rectangle, color-cycles when moving)
    const player_col = if (player_moving) colorCycle(player_color_phase) else gfx.color(50, 220, 80, 255);
    gfx.drawRectangleRec(.{ .x = player_x - 30, .y = player_y - 30, .width = 60, .height = 60 }, player_col);

    // -- Gizmos (toggled with G)
    if (show_gizmos) {
        drawGizmos();
    }

    gfx.endMode2D();

    // ── Screen-space HUD (no camera transform) ────────────────────
    drawHud();

    // ── Video panel (screen-space, drawn on top) ──────────────────
    drawVideo();

    // ── Gamepad overlay (lights up live when a controller is connected) ──
    gamepad_overlay.draw(SCREEN_W_F, SCREEN_H_F);

    window.endDrawing();
}

fn drawGizmos() void {
    const gizmo_col = gfx.color(255, 255, 0, 180);
    const label_col = gfx.color(255, 255, 255, 200);
    const arrow_col = gfx.color(0, 255, 200, 180);
    const grid_col = gfx.color(255, 255, 255, 30);

    // -- Grid overlay (100px spacing)
    const grid_start_x: f32 = -200.0;
    const grid_end_x: f32 = 1000.0;
    const grid_start_y: f32 = -200.0;
    const grid_end_y: f32 = 800.0;

    var gx: f32 = grid_start_x;
    while (gx <= grid_end_x) : (gx += 100.0) {
        gfx.drawLine(gx, grid_start_y, gx, grid_end_y, 1.0, grid_col);
    }
    var gy: f32 = grid_start_y;
    while (gy <= grid_end_y) : (gy += 100.0) {
        gfx.drawLine(grid_start_x, gy, grid_end_x, gy, 1.0, grid_col);
    }

    // -- Player bounding box + name label + velocity arrow
    const px = player_x - 30;
    const py = player_y - 30;
    const pw: f32 = 60;
    const ph: f32 = 60;
    // Bounding box (4 lines forming a rectangle)
    gfx.drawLine(px, py, px + pw, py, 1.5, gizmo_col);
    gfx.drawLine(px + pw, py, px + pw, py + ph, 1.5, gizmo_col);
    gfx.drawLine(px + pw, py + ph, px, py + ph, 1.5, gizmo_col);
    gfx.drawLine(px, py + ph, px, py, 1.5, gizmo_col);
    // Name label above entity
    gfx.drawText("Player", player_x - 20, player_y - 48, 10, label_col);
    // Velocity arrow
    if (player_moving) {
        const arrow_scale: f32 = 0.3;
        gfx.drawLine(player_x, player_y, player_x + player_vx * arrow_scale, player_y + player_vy * arrow_scale, 2.0, arrow_col);
        // Arrowhead (small triangle at tip)
        const tip_x = player_x + player_vx * arrow_scale;
        const tip_y = player_y + player_vy * arrow_scale;
        gfx.drawCircle(tip_x, tip_y, 4.0, arrow_col);
    }

    // -- Enemy bounding boxes + labels
    for (&enemies, 0..) |*e, idx| {
        const er = e.radius;
        gfx.drawLine(e.x - er, e.y - er, e.x + er, e.y - er, 1.0, gizmo_col);
        gfx.drawLine(e.x + er, e.y - er, e.x + er, e.y + er, 1.0, gizmo_col);
        gfx.drawLine(e.x + er, e.y + er, e.x - er, e.y + er, 1.0, gizmo_col);
        gfx.drawLine(e.x - er, e.y + er, e.x - er, e.y - er, 1.0, gizmo_col);

        const label: [:0]const u8 = switch (idx) {
            0 => "Enemy 0",
            1 => "Enemy 1",
            2 => "Enemy 2",
            else => "Enemy",
        };
        gfx.drawText(label, e.x - 20, e.y - er - 16, 10, label_col);
    }

    // -- Hexagon bounding box + label
    gfx.drawLine(hex_cx - hex_radius, hex_cy - hex_radius, hex_cx + hex_radius, hex_cy - hex_radius, 1.0, gizmo_col);
    gfx.drawLine(hex_cx + hex_radius, hex_cy - hex_radius, hex_cx + hex_radius, hex_cy + hex_radius, 1.0, gizmo_col);
    gfx.drawLine(hex_cx + hex_radius, hex_cy + hex_radius, hex_cx - hex_radius, hex_cy + hex_radius, 1.0, gizmo_col);
    gfx.drawLine(hex_cx - hex_radius, hex_cy + hex_radius, hex_cx - hex_radius, hex_cy - hex_radius, 1.0, gizmo_col);
    gfx.drawText("Hexagon", hex_cx - 24, hex_cy - hex_radius - 16, 10, label_col);

    // -- Orbiter label
    const orb_x = player_x + orbiter_radius * @cos(orbiter_angle);
    const orb_y = player_y + orbiter_radius * @sin(orbiter_angle);
    gfx.drawText("Orbiter", orb_x - 20, orb_y - orbiter_size - 16, 10, label_col);
}

fn drawHud() void {
    const hud_bg = gfx.color(0, 0, 0, 140);
    const hud_text = gfx.color(230, 230, 230, 255);
    const hud_highlight = gfx.color(100, 220, 160, 255);

    // -- HUD background bar
    gfx.drawRectangleRec(.{ .x = 0, .y = 0, .width = SCREEN_W_F, .height = 56 }, hud_bg);

    // -- Title
    gfx.drawText("LaBelle v2 - bgfx Backend Demo", 10, 6, 14, hud_highlight);

    // -- Controls hint
    gfx.drawText("WASD:move  Space:sound  M:music  G:gizmos  R:reset  Scroll:zoom  Esc:quit", 10, 24, 10, hud_text);

    // -- Audio state
    const audio_label: [:0]const u8 = if (!sound_loaded and !music_loaded)
        "Audio: no files loaded"
    else if (music_playing)
        "Audio: music PLAYING"
    else
        "Audio: music paused";
    gfx.drawText(audio_label, 10, 40, 10, hud_text);

    // -- Gizmo state (right side)
    const gizmo_label: [:0]const u8 = if (show_gizmos) "Gizmos: ON" else "Gizmos: OFF";
    gfx.drawText(gizmo_label, 680, 40, 10, hud_text);

    // -- Bottom info bar
    gfx.drawRectangleRec(.{ .x = 0, .y = SCREEN_H_F - 22, .width = SCREEN_W_F, .height = 22 }, hud_bg);

    // -- Zoom display
    // Build a static label since we cannot do runtime format without allocator
    const zoom_label: [:0]const u8 = if (camera.zoom < 0.5)
        "Zoom: 0.25x"
    else if (camera.zoom < 0.75)
        "Zoom: 0.5x"
    else if (camera.zoom < 1.25)
        "Zoom: 1.0x"
    else if (camera.zoom < 1.75)
        "Zoom: 1.5x"
    else if (camera.zoom < 2.5)
        "Zoom: 2.0x"
    else
        "Zoom: 3.0x+";
    gfx.drawText(zoom_label, 10, SCREEN_H_F - 18, 10, hud_text);

    // -- Player position (approximate bucket)
    const pos_label: [:0]const u8 = if (player_x < 200)
        "Pos: left"
    else if (player_x < 600)
        "Pos: center"
    else
        "Pos: right";
    gfx.drawText(pos_label, 200, SCREEN_H_F - 18, 10, hud_text);

    // -- Decorative triangles in HUD corners
    gfx.drawTriangle(
        .{ .x = SCREEN_W_F - 30, .y = 4 },
        .{ .x = SCREEN_W_F - 4, .y = 4 },
        .{ .x = SCREEN_W_F - 4, .y = 30 },
        gfx.color(100, 220, 160, 120),
    );
    gfx.drawTriangle(
        .{ .x = SCREEN_W_F - 30, .y = SCREEN_H_F - 4 },
        .{ .x = SCREEN_W_F - 4, .y = SCREEN_H_F - 4 },
        .{ .x = SCREEN_W_F - 4, .y = SCREEN_H_F - 30 },
        gfx.color(100, 220, 160, 120),
    );
}

// ── Entry point ────────────────────────────────────────────────────────

pub fn main() void {
    // -- Window setup
    window.initWindow(SCREEN_W, SCREEN_H, "LaBelle v2 — bgfx Backend Demo");
    window.setTargetFPS(60);
    gfx.setScreenSize(SCREEN_W, SCREEN_H);

    // -- Dynamic-texture demo: one mutable texture, re-uploaded each frame.
    initVideo(); // gfx.VideoPlayer: ffmpeg decode → dynamic texture

    // -- Audio: synthesize a 440 Hz beep WAV to a temp file and load it.
    // This opens the miniaudio playback device (#297) on first load and
    // exercises the device callback → mixAudio path end to end. Loading
    // is non-fatal if the temp write or device open fails (e.g. headless
    // CI with no audio hardware).
    // Relative path so the demo also works on Windows (no `/tmp`); written
    // to the current working directory.
    const beep_path: [:0]const u8 = "bgfx-audio-beep.wav";
    if (writeBeepWavFile(beep_path)) {
        sound_id = audio.loadSound(beep_path);
        sound_loaded = (sound_id != 0);
        // Play once on startup so the device callback has something to mix.
        if (sound_loaded) audio.playSound(sound_id);
    }

    // -- Main loop
    while (!window.windowShouldClose()) {
        // Quit on escape
        if (input.isKeyDown(KEY_ESCAPE)) break;

        update();
        draw();
    }

    // -- Cleanup: unload (exercises the #298 unload-during-playback path)
    // then shut down the device. `audio.deinit` joins the callback thread
    // and frees any remaining PCM.
    if (sound_loaded) audio.unloadSound(sound_id);
    if (music_loaded) {
        audio.stopMusic(music_id);
        audio.unloadMusic(music_id);
    }
    audio.deinit();

    // -- Dynamic-texture cleanup
    if (player) |*p| p.deinit();

    window.closeWindow();
}
