// Loading-state controller — the RFC-end-state form.
//
// Drives the asset-streaming pipeline using only the
// `game.assets.*` API + `game.setScene`'s Phase 2 manifest gate
// (labelle-engine #458). Every frame:
//
//   1. Draw the progress bar from `game.assets.progress(...)`.
//   2. Call `game.setScene("main")`. The first call acquires the
//      manifest (kicks off the worker decode); subsequent calls
//      return silently while assets are still decoding; the call
//      that lands once `allReady` is true performs the actual
//      swap.
//   3. Flip the state machine to "playing" so the playing-state
//      scripts pick up after the swap.
//
// No `loadAtlasIfNeeded`. No `isAtlasLoaded`. No
// `queueSceneChange`. The two-line shape the RFC promised.

const std = @import("std");

pub const game_states = .{"loading"};

pub fn tick(game: anytype, _: f32) void {
    const main_scene = game.scenes.get("main") orelse {
        std.log.err("loading_controller: scene 'main' not registered", .{});
        return;
    };
    const target_assets = main_scene.assets;

    // Draw the bar BEFORE the setScene call so the frame on which
    // setScene actually swaps shows a fully-filled bar briefly —
    // otherwise the user only ever sees fractions, never the
    // "complete" state, because the loading controller stops
    // running the moment the swap completes.
    drawProgressBar(game, game.assets.progress(target_assets));

    // Phase 2 manifest gate (labelle-engine #458): idempotent
    // acquire on the first call, silent return while decoding,
    // synchronous swap once `allReady`. The script is expected
    // to call this every frame. Bail early on error so we don't
    // leave the state machine in `playing` while the swap failed.
    game.setScene("main") catch |err| {
        std.log.err(
            "loading_controller: setScene('main') failed: {s}",
            .{@errorName(err)},
        );
        return;
    };

    // Bump the state machine to "playing" only after a successful
    // swap. Doing this BEFORE setScene risks orphaning the game in
    // `playing` if setScene errors during the swap — this
    // controller is bound to `loading` and would stop ticking, so
    // any retry path would be unreachable.
    if (game.assets.allReady(target_assets)) {
        game.setState("playing");
    }
}

/// Screen-space progress bar. Drawn entirely with gizmos so it
/// needs no atlas of its own (fits the "eager-preloaded, swap-in
/// instantly" loading-scene model). Colours are AARRGGBB —
/// drawGizmoRectScreen takes a packed `u32`.
fn drawProgressBar(game: anytype, fraction: f32) void {
    const bar_x: f32 = 200;
    const bar_y: f32 = 280;
    const bar_w: f32 = 400;
    const bar_h: f32 = 40;

    game.drawGizmoRectScreen(bar_x, bar_y, bar_w, bar_h, 0xFF404040);

    const fill_w = bar_w * std.math.clamp(fraction, 0.0, 1.0);
    if (fill_w > 0) {
        game.drawGizmoRectScreen(bar_x, bar_y, fill_w, bar_h, 0xFF40C040);
    }
}
