// Main-scene script — runs only in the "playing" state (after the
// loading controller has swapped the scene). The rendering of the
// sprites declared in `scenes/main.jsonc` is handled entirely by
// the generated gfx plugin (Sprite component -> atlas lookup -> draw),
// so there's no rendering work to do here. The script's only job is
// providing a clean exit path for interactive / timeout-driven runs.
//
// If you see two sprites drawn to the screen while the progress bar
// is gone, the streaming round-trip worked: lazy register -> per-
// frame decode -> GPU upload -> atlas sprite lookup -> draw.

// Bound to the "playing" state so the Escape handler doesn't fire
// during loading. The key check is harmless in other states, but
// adhering to the state-driven model keeps this script aligned with
// `loading_controller` and the convention the engine enforces for
// script binding.
const window = @import("backend_window");

pub const game_states = .{"playing"};

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct {
        centered: bool = false,
        frames: u32 = 0,
        screenshotted: bool = false,
    };
}

pub fn tick(game: anytype, state: anytype, _: anytype, _: f32) void {
    // One-shot camera centering — see comment in scenes/main.jsonc.
    if (!state.centered) {
        game.getCamera().centerOnScreen();
        state.centered = true;
    }

    state.frames += 1;
    // Take a screenshot 30 frames into "playing" so atlases are
    // decoded, sprites are uploaded, and at least one full render
    // cycle has flushed. Saves to /tmp/smoke-test.png and quits so
    // CI-style runs (and the human viewer) get a reproducible image.
    if (!state.screenshotted and state.frames >= 30) {
        window.takeScreenshot("smoke-test.png");
        state.screenshotted = true;
        game.quit();
    }

    if (game.isKeyPressed(.escape)) {
        game.quit();
    }
}
