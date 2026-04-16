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
pub const game_states = .{"playing"};

pub fn tick(game: anytype, _: f32) void {
    if (game.isKeyPressed(.escape)) {
        game.quit();
    }
}
