//! VideoBackend — satisfies labelle-core's VideoInterface (FP#549).
//!
//! A small handle pool over `VideoPlayer`: the engine/game calls `openVideo` by
//! resource name, and this resolves the name to a clip and builds the right
//! per-platform decoder + player. So a project plays a video with *just the
//! asset name* (a `VideoComponent` or `game.openVideo("intro")`), no path or
//! codec knowledge needed.
//!
//! Name resolution (until a generated catalog lands):
//!   - desktop: `assets/<name>` (probed for native size/fps via ffprobe).
//!   - Android: the `<name>` asset in the APK, via the bgfx shell's running
//!     NativeActivity AAssetManager.
//!
//! Audio note: in-engine audio for these players needs the audio *module*'s
//! mixer, which the gfx module must not import (it would fork a second mixer).
//! So this first cut is video-only; audio is wired via an injection seam (the
//! player's AudioHooks, fed by the assembler) in a follow-up. The decode/audio/
//! AAudio path is already proven in the example + bgfx-Android app.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("../gfx/types.zig");
const state = @import("../gfx/state.zig");
const player_mod = @import("player.zig");
const desktop = @import("desktop.zig");
const android = @import("android.zig");

const is_android = builtin.abi == .android or builtin.abi == .androideabi;
const Decoder = if (is_android) android.VideoDecoder else desktop.VideoDecoder;

// Android asset access: the bgfx Android shell exposes the running
// NativeActivity (C export); its AAssetManager resolves bundled clips by name.
extern fn labelle_bgfx_get_native_activity() ?*anyopaque;
const AAssetManager = opaque {};
const AAsset = opaque {};
extern fn AAssetManager_open(*AAssetManager, [*:0]const u8, c_int) ?*AAsset;
extern fn AAsset_openFileDescriptor64(*AAsset, *i64, *i64) c_int;
extern fn AAsset_close(*AAsset) void;
const AASSET_MODE_STREAMING: c_int = 2;

pub const VideoBackend = struct {
    const Player = player_mod.Player(Decoder);
    const MAX = 8;

    const Slot = struct {
        player: Player = undefined,
        w: u32 = 0,
        h: u32 = 0,
        used: bool = false,
    };

    var slots: [MAX]Slot = [_]Slot{.{}} ** MAX;
    const alloc = std.heap.page_allocator;

    fn freeSlot() ?usize {
        for (&slots, 0..) |*s, i| if (!s.used) return i;
        return null;
    }
    fn slotPtr(id: u32) ?*Slot {
        if (id == 0 or id > MAX) return null;
        const s = &slots[id - 1];
        return if (s.used) s else null;
    }

    /// Open a video by resource name. `[]const u8` so a `VideoComponent` path
    /// from a scene/JSON string works directly; null-terminated here for the
    /// Android asset API. Returns a handle (0 = failure).
    pub fn openVideo(name: []const u8) u32 {
        const idx = freeSlot() orelse return 0;
        if (is_android) {
            const act = labelle_bgfx_get_native_activity() orelse return 0;
            // ANativeActivity field 8 is `assetManager` (callbacks, vm, env,
            // clazz, internalDataPath, externalDataPath, sdkVersion, instance,
            // assetManager…).
            const fields: [*]const ?*anyopaque = @ptrCast(@alignCast(act));
            const am: *AAssetManager = @ptrCast(fields[8] orelse return 0);
            var namebuf: [256]u8 = undefined;
            if (name.len >= namebuf.len) return 0;
            @memcpy(namebuf[0..name.len], name);
            namebuf[name.len] = 0;
            const namez: [:0]const u8 = namebuf[0..name.len :0];
            const asset = AAssetManager_open(am, namez.ptr, AASSET_MODE_STREAMING) orelse return 0;
            defer AAsset_close(asset);
            var start: i64 = 0;
            var len: i64 = 0;
            // `AAsset_openFileDescriptor64` returns an independent (dup'd) fd, so
            // closing the AAsset above is fine. Ownership of `fd` transfers to the
            // decoder in `openFd` — it `close()`s it in `deinit` (and on its own
            // error paths). We must NOT close `fd` here (no double close).
            const fd = AAsset_openFileDescriptor64(asset, &start, &len);
            if (fd < 0) return 0;
            var dec = android.VideoDecoder.openFd(alloc, fd, start, len) catch return 0;
            const w = dec.width();
            const h = dec.height();
            const pl = Player.init(alloc, dec, 24.0) catch {
                dec.deinit();
                return 0;
            };
            slots[idx] = .{ .player = pl, .w = w, .h = h, .used = true };
        } else {
            var pathbuf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&pathbuf, "assets/{s}", .{name}) catch return 0;
            const info = desktop.probe(alloc, path) orelse return 0;
            const dec = desktop.VideoDecoder.open(alloc, path, info.w, info.h, info.fps) catch return 0;
            const pl = Player.init(alloc, dec, info.fps) catch return 0;
            slots[idx] = .{ .player = pl, .w = info.w, .h = info.h, .used = true };
        }
        return @intCast(idx + 1);
    }

    pub fn updateVideo(id: u32, dt: f32) void {
        if (slotPtr(id)) |s| s.player.update(dt);
    }

    pub fn drawVideo(id: u32, x: f32, y: f32, w: f32, h: f32) void {
        if (slotPtr(id)) |s| s.player.draw(.{ .x = x, .y = y, .width = w, .height = h });
    }

    /// Fill the whole framebuffer with the current frame — a background.
    /// `fit_tag` matches core.VideoFit: 0=stretch, 1=cover, 2=contain. Drawn with
    /// the aspect-fit toggle off (edge-to-edge framebuffer, like a `screen_fill`
    /// sprite layer); the toggle is bracketed so other draws are unaffected.
    pub fn drawVideoFullscreen(id: u32, fit_tag: u8) void {
        const s = slotPtr(id) orelse return;
        const sw: f32 = @floatFromInt(state.getDesignWidth());
        const sh: f32 = @floatFromInt(state.getDesignHeight());
        const vw: f32 = @floatFromInt(s.w);
        const vh: f32 = @floatFromInt(s.h);
        const full_src = types.Rectangle{ .x = 0, .y = 0, .width = vw, .height = vh };
        const full_dst = types.Rectangle{ .x = 0, .y = 0, .width = sw, .height = sh };

        state.setApplyFit(false);
        defer state.setApplyFit(true);

        if (vw == 0 or vh == 0 or sw == 0 or sh == 0) {
            s.player.drawRegion(full_src, full_dst);
            return;
        }
        const screen_ar = sw / sh;
        const video_ar = vw / vh;
        switch (fit_tag) {
            1 => { // cover — center-crop the source to the screen aspect, fill
                var cw = vw;
                var ch = vh;
                if (video_ar > screen_ar) {
                    cw = vh * screen_ar; // too wide: crop sides
                } else {
                    ch = vw / screen_ar; // too tall: crop top/bottom
                }
                const src = types.Rectangle{ .x = (vw - cw) / 2, .y = (vh - ch) / 2, .width = cw, .height = ch };
                s.player.drawRegion(src, full_dst);
            },
            2 => { // contain — fit whole video inside, letterbox/pillarbox
                const scale = @min(sw / vw, sh / vh);
                const dw = vw * scale;
                const dh = vh * scale;
                const dst = types.Rectangle{ .x = (sw - dw) / 2, .y = (sh - dh) / 2, .width = dw, .height = dh };
                s.player.drawRegion(full_src, dst);
            },
            else => s.player.drawRegion(full_src, full_dst), // stretch
        }
    }

    pub fn isVideoPlaying(id: u32) bool {
        if (slotPtr(id)) |s| return !s.player.isEnded();
        return false;
    }

    /// Restart a finished clip from the beginning (engine-driven loop).
    pub fn replayVideo(id: u32) void {
        if (slotPtr(id)) |s| s.player.replay();
    }

    pub fn videoDimensions(id: u32) struct { w: u32, h: u32 } {
        if (slotPtr(id)) |s| return .{ .w = s.w, .h = s.h };
        return .{ .w = 0, .h = 0 };
    }

    pub fn closeVideo(id: u32) void {
        if (slotPtr(id)) |s| {
            s.player.deinit();
            s.used = false;
        }
    }
};
