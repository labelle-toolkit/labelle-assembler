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

pub fn tick(game: anytype, _: f32) void {
    if (game.isKeyPressed(.escape)) {
        game.quit();
    }
}
