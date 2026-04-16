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
    // One-shot camera centering on the DESIGN canvas (the size
    // declared in project.labelle), not the physical framebuffer.
    // On Android the framebuffer is the tablet's native resolution
    // (e.g. 2000×1200 landscape), so `centerOnScreen` would put the
    // camera at (1000, 600) — miles outside the 800×600 design
    // canvas — and every sprite would render off-screen.
    if (!state.centered) {
        game.getCamera().centerOnDesign();
        state.centered = true;
    }

    state.frames += 1;

    // Backends that expose `takeScreenshot` (raylib desktop) save a
    // reproducible PNG 30 frames into "playing" and quit, so CI runs
    // and the human viewer get an artifact without needing a window
    // manager. Sokol (Android, WASM) has no `takeScreenshot` hook —
    // skip the artifact path and just loop forever so a user can
    // visually verify the animation on-device.
    if (@hasDecl(window, "takeScreenshot")) {
        if (!state.screenshotted and state.frames >= 30) {
            window.takeScreenshot("smoke-test.png");
            state.screenshotted = true;
            game.quit();
        }
    }

    if (game.isKeyPressed(.escape)) {
        game.quit();
    }
}
