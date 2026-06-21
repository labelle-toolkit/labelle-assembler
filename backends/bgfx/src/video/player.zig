//! VideoPlayer — wires a video decoder to a bgfx dynamic texture
//! (FP#549 Path A: Half 2 decode → Half 1 display).
//!
//! Generic over the decoder so the same wiring drives either backend decoder:
//!   - desktop: `video/desktop.zig` (ffmpeg)
//!   - Android: `video/android.zig` (AMediaCodec)
//! A decoder just needs `width()`, `height()`, `decodeFrame([]u8) ?f64`, and
//! `deinit()`. `decodeFrame` fills the RGBA8 buffer and returns the decoded
//! frame's presentation timestamp in seconds (the PTS, used for A/V sync), or
//! `null` when no frame was produced / the stream ended. A decoder MAY also
//! expose optional `eof()` and `replay(allocator)` decls, which the player uses
//! via `@hasDecl` for end-of-stream detection and engine-driven looping. The
//! player owns the dynamic texture (`gfx/texture.zig`): it
//! creates one sized to the video, paces decoded frames to the clip fps, uploads
//! each via `updateTexture`, and draws it with `drawTexturePro`.

const std = @import("std");
const texture = @import("../gfx/texture.zig");
const types = @import("../gfx/types.zig");

/// Audio lifecycle injected by the game/example so the player can drive an audio
/// track (started with the video, ticked each frame, stopped on teardown)
/// WITHOUT `gfx` depending on the `audio` module. The caller wires these to
/// labelle's audio API (`playMusic`/`updateMusic`/`stopMusic`). Leave null for a
/// silent clip.
///
/// `clock` returns the audio device's current playback position in seconds — the
/// **master clock** for PTS-accurate A/V sync (wire it to
/// `audio.musicPositionSeconds`). When null, the player falls back to wall-clock
/// pacing off the per-frame `dt`.
pub const AudioHooks = struct {
    ctx: ?*anyopaque = null,
    start: ?*const fn (ctx: ?*anyopaque) void = null,
    update: ?*const fn (ctx: ?*anyopaque) void = null,
    stop: ?*const fn (ctx: ?*anyopaque) void = null,
    clock: ?*const fn (ctx: ?*anyopaque) f64 = null,
};

/// Cap on frames decoded-and-dropped in one `update` while catching up, so a
/// long stall can't trigger a decode spiral that stalls the render thread.
const MAX_CATCHUP_FRAMES = 4;

pub fn Player(comptime Decoder: type) type {
    return struct {
        const Self = @This();

        decoder: Decoder,
        tex: types.Texture,
        pixels: []u8,
        allocator: std.mem.Allocator,
        audio: AudioHooks = .{},
        started: bool = false,
        // PTS-accurate sync state (all in seconds):
        play_time: f64 = 0, // master clock — driven by the audio device, or dt
        last_clock: f64 = 0, // previous audio-clock reading (for the delta)
        cur_pts: f64 = -1, // PTS of the frame currently on the texture
        ended: bool = false, // stream drained (set when the decoder reports eof)

        /// Take an already-opened decoder (opening is platform-specific), create
        /// a dynamic texture sized to it, decode the first frame, and upload it.
        pub fn init(allocator: std.mem.Allocator, decoder: Decoder, fps: f32) !Self {
            _ = fps; // pacing is now driven by frame PTS, not a fixed rate
            var dec = decoder;
            // `decoder` was moved into `dec`; if a fallible call below fails we'd
            // otherwise leak it (the caller hands ownership in). Release it on any
            // error path. Cancelled on success — the returned struct owns it and
            // `deinit` calls `decoder.deinit()`.
            errdefer dec.deinit();
            const w = dec.width();
            const h = dec.height();
            const tex = try texture.createDynamicTexture(w, h);
            errdefer texture.unloadTexture(tex);
            const pixels = try allocator.alloc(u8, @as(usize, w) * h * 4);

            var self: Self = .{ .decoder = dec, .tex = tex, .pixels = pixels, .allocator = allocator };
            if (self.decoder.decodeFrame(pixels)) |pts| {
                self.cur_pts = pts;
                texture.updateTexture(tex, pixels);
            }
            return self;
        }

        /// Attach an audio track (started/ticked/stopped with the video).
        pub fn setAudio(self: *Self, hooks: AudioHooks) void {
            self.audio = hooks;
        }

        /// PTS-accurate A/V sync. The audio device is the master clock: we
        /// advance `play_time` by the *audio clock's* elapsed delta (loop-safe —
        /// a negative delta at a loop boundary contributes zero), then present
        /// the video frame whose PTS the master clock has reached — decoding past
        /// (dropping) frames that are late and holding the current one when the
        /// next is still in the future. Without an audio clock it falls back to
        /// `dt` pacing, still selecting frames by PTS (so VFR is handled).
        pub fn update(self: *Self, dt: f32) void {
            if (!self.started) {
                self.started = true;
                if (self.audio.start) |f| f(self.audio.ctx);
                if (self.audio.clock) |c| self.last_clock = c(self.audio.ctx);
            }
            if (self.audio.update) |f| f(self.audio.ctx);

            // Advance the master clock.
            if (self.audio.clock) |c| {
                const now = c(self.audio.ctx);
                const delta = now - self.last_clock;
                self.last_clock = now;
                self.play_time += if (delta > 0) delta else 0; // skip loop-wrap/pause
            } else {
                self.play_time += dt;
            }

            // Present the frame the master clock has reached; drop late frames.
            var uploaded = false;
            var caught: u32 = 0;
            while (self.cur_pts < self.play_time and caught < MAX_CATCHUP_FRAMES) : (caught += 1) {
                const pts = self.decoder.decodeFrame(self.pixels) orelse break;
                self.cur_pts = pts;
                uploaded = true;
                // Caught up: this freshly decoded frame's PTS has reached (or
                // overshot) the clock. Upload it (it's the best available next
                // frame) but stop here — don't keep decoding into the future.
                if (pts >= self.play_time) break;
            }
            if (uploaded) texture.updateTexture(self.tex, self.pixels);

            // End-of-stream: the decoder drained (only meaningful for decoders
            // that report it; looping/never-ending sources never set it).
            if (comptime @hasDecl(Decoder, "eof")) {
                if (self.decoder.eof()) self.ended = true;
            }
        }

        /// True once the stream has played to the end (play-once clips). Loops are
        /// restarted by the engine via `replay` before this is observed.
        pub fn isEnded(self: *const Self) bool {
            return self.ended;
        }

        /// Restart playback from the beginning (engine-driven loop / replay).
        pub fn replay(self: *Self) void {
            if (comptime @hasDecl(Decoder, "replay")) self.decoder.replay(self.allocator);
            self.play_time = 0;
            self.last_clock = 0;
            self.cur_pts = -1;
            self.ended = false;
            self.started = false; // re-arm the audio start on the next update
            if (self.decoder.decodeFrame(self.pixels)) |pts| {
                self.cur_pts = pts;
                texture.updateTexture(self.tex, self.pixels);
            }
        }

        /// Draw the current video frame into `dest` (screen or world space, per
        /// the active camera mode).
        pub fn draw(self: *const Self, dest: types.Rectangle) void {
            const src = types.Rectangle{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(self.tex.width),
                .height = @floatFromInt(self.tex.height),
            };
            texture.drawTexturePro(self.tex, src, dest, .{ .x = 0, .y = 0 }, 0, types.white);
        }

        /// Draw a sub-region `src` (in texture pixels) of the current frame into
        /// `dest` — the seam for cover/contain fits (center-crop the source, or
        /// letterbox the dest).
        pub fn drawRegion(self: *const Self, src: types.Rectangle, dest: types.Rectangle) void {
            texture.drawTexturePro(self.tex, src, dest, .{ .x = 0, .y = 0 }, 0, types.white);
        }

        pub fn deinit(self: *Self) void {
            if (self.audio.stop) |f| f(self.audio.ctx);
            self.decoder.deinit();
            texture.unloadTexture(self.tex);
            self.allocator.free(self.pixels);
        }
    };
}
