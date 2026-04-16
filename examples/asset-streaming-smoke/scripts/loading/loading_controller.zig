// Loading-state controller — runs exclusively while `game_state ==
// "loading"`. Drives the per-frame lazy-atlas decode of every asset
// declared on the "main" scene's `assets:` manifest, renders a
// progress bar via screen-space gizmos, and flips to the "playing"
// state + "main" scene once every atlas has its texture on the GPU.
//
// ## Why this script exists (Asset Streaming RFC context)
//
// The asset-streaming RFC's end-state has `setScene("main")` block
// automatically on `game.assets.allReady(...)`, driven by an engine
// hook that walks `SceneEntry.assets` and calls `catalog.acquire`
// per asset. That hook is labelle-engine ticket #444, which is
// **not** merged as of this example's initial commit. On `main`,
// `game.assets` is not yet exposed as a Game field and
// `AssetCatalog.pump()` is a no-op; scene changes do not drive
// async decode.
//
// So on today's main the viable decode path is the legacy lazy-
// atlas API that shipped with labelle-engine #434:
//
//   * `registerAtlasFromMemory` parses the JSON eagerly and keeps
//     the PNG bytes alive for later decode.
//   * `loadAtlasIfNeeded(name)` synchronously decodes ONE atlas and
//     uploads it — returns `true` the frame it fires, `false` once
//     it's already loaded.
//   * `isAtlasLoaded(name)` is the "ready" gate.
//
// This controller calls `loadAtlasIfNeeded` for a single pending
// atlas per frame, so PNG decode is spread across frames and the
// progress bar animates between decodes. That's the pattern the
// ticket asks the smoke test to demonstrate — same user-visible
// shape the RFC targets, just via the legacy API until the async
// pump + `game.assets` wiring lands.
//
// When #444 and the `game.assets` accessor merge, this file flips to
// the two-line RFC form:
//
//   state.bar_scale = game.assets.progress(target.assets);
//   if (game.assets.allReady(target.assets)) game.setScene("main");
//
// and the per-frame `loadAtlasIfNeeded` fan-out disappears. The
// scene manifest consumed by `game.scenes.get("main").?.assets`
// stays identical, so the codegen contract exercised here is the
// same one the async path will use.

const std = @import("std");

pub fn tick(game: anytype, _: f32) void {
    // Look up the main scene's asset manifest. This is the exact
    // slice emitted by the assembler into `SceneAssetManifests.main`
    // — program-lifetime, safe to borrow here without a copy.
    const main_scene = game.scenes.get("main") orelse {
        std.log.err("loading_controller: scene 'main' not registered", .{});
        return;
    };
    const target_assets = main_scene.assets;

    // Count how many atlases are already decoded + uploaded. This
    // drives both the bar fill and the completion check. Tight loop,
    // no allocations — called every frame in the loading state.
    var ready_count: usize = 0;
    for (target_assets) |name| {
        if (game.isAtlasLoaded(name)) ready_count += 1;
    }

    // Decode exactly one pending atlas per frame so the main thread
    // returns to the event loop between PNGs. Returning early after
    // the first non-loaded atlas is what gives the bar its "tick"
    // shape — each frame advances `ready_count` by at most one.
    //
    // `loadAtlasIfNeeded` is synchronous today (decode + GPU upload
    // happen on this call), which means it blocks the main thread
    // for the duration of a single PNG. On small test atlases that
    // is cheap enough that the bar animates visibly between frames;
    // on a real game-sized atlas this is the pain point the async
    // worker (engine #442 pump) eventually solves.
    if (ready_count < target_assets.len) {
        for (target_assets) |name| {
            if (!game.isAtlasLoaded(name)) {
                _ = game.loadAtlasIfNeeded(name) catch |err| {
                    std.log.err(
                        "loading_controller: loadAtlasIfNeeded('{s}') failed: {s}",
                        .{ name, @errorName(err) },
                    );
                    return;
                };
                break;
            }
        }
    }

    // Draw the bar. Screen-space gizmos live until the end of the
    // frame (`Game.render` calls `clearGizmos` after `renderGizmos`),
    // so emitting them every tick gives a stable picture.
    drawProgressBar(game, ready_count, target_assets.len);

    // Flip to the main scene + playing state when every atlas is
    // ready. Use `queueSceneChange` rather than a direct `setScene`
    // so the transition fires on a clean frame boundary — the game
    // loop drains `pending_scene_change` right after tick.
    if (target_assets.len > 0 and ready_count == target_assets.len) {
        game.setState("playing");
        game.queueSceneChange("main");
    }
}

/// Screen-space progress bar + frame counter. Drawn entirely with
/// gizmos so it needs no atlas of its own (fits the "eager preload,
/// instant swap-in" loading-scene model even though the scene has
/// nothing to preload). Colours are AARRGGBB — drawGizmoRectScreen
/// takes a packed `u32`.
fn drawProgressBar(game: anytype, ready: usize, total: usize) void {
    const bar_x: f32 = 200;
    const bar_y: f32 = 280;
    const bar_w: f32 = 400;
    const bar_h: f32 = 40;

    // Track (dark grey).
    game.drawGizmoRectScreen(bar_x, bar_y, bar_w, bar_h, 0xFF404040);

    // Fill (green). `total == 0` is the "no assets to wait on"
    // edge case — we still draw the track for visual consistency
    // but skip the fill.
    if (total > 0) {
        const frac: f32 = @as(f32, @floatFromInt(ready)) /
            @as(f32, @floatFromInt(total));
        const fill_w = bar_w * frac;
        if (fill_w > 0) {
            game.drawGizmoRectScreen(bar_x, bar_y, fill_w, bar_h, 0xFF40C040);
        }
    }
}
