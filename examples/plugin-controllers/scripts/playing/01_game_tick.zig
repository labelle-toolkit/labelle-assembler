//! Game-owned per-frame script. Logs a `[game] game-tick frame=N` line
//! every tick. Numeric prefix `01_` keeps this ahead of any future game
//! scripts in the `playing` state.
//!
//! The plugin's `01_plugin_tick.zig` runs in a separate per-plugin block
//! (see `ScriptScanner.scanPluginDir` and the `PluginBlockOrdering` tests
//! in `test/script_scanner_tests.zig`), so there's no duplicate-prefix
//! collision between the two files.
//!
//! Exit strategy: raylib's main-loop guard is `window.windowShouldClose()`,
//! which only flips on ESC / user-initiated close. A hidden-window CI run
//! can't reach either, and `rl.closeWindow()` from inside tick() crashes
//! the same iteration's subsequent draw calls. The CI job wraps execution
//! in `timeout 3s` so the process is killed once we've emitted enough
//! interleaved log lines.
//!
//! Consequence: `[demo-plugin] deinit` is NOT expected in the runtime log
//! for this raylib example. The generated `defer PluginControllers.deinit(&g)`
//! IS still asserted — by the snapshot tests in `test/tests.zig`
//! (`PLUGIN_CONTROLLERS → plugins present wires controllers into setup_code`).
//! The runtime check covers the parts snapshots can't: that the generated
//! code compiles and that setup + tick order behave the same way a
//! consumer game would see them.
//!
//! Matching CI grep expects this canonical sequence in stderr:
//!   [demo-plugin] setup
//!   [game] game-tick frame=1
//!   [demo-plugin] plugin-tick frame=1
//!   [game] game-tick frame=2
//!   [demo-plugin] plugin-tick frame=2
//!   … (FRAMES_BEFORE_QUIT total interleaved game/plugin lines) …
//!
//! Interleaving comes from the engine's script execution order: within
//! the `playing` state, block-1 (game) scripts run before block-2 (plugin)
//! scripts each tick. `PluginControllers.setup` is called once during
//! setup_code before the tick loop starts.

pub const game_states = .{"playing"};

const FRAMES_BEFORE_QUIT: u32 = 5;

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct {
        frame: u32 = 0,
    };
}

pub fn tick(game: anytype, state: anytype, _: anytype, _: f32) void {
    // Under raylib, `game.quit()` doesn't break the main loop —
    // `windowShouldClose()` stays false for a hidden window — so ticks
    // keep firing past frame `FRAMES_BEFORE_QUIT` until the CI timeout
    // kills the process. Cap our log output so the captured stderr
    // stays deterministic: after FRAMES_BEFORE_QUIT ticks we stop
    // logging new frames. The CI grep keys on frames 1..FRAMES_BEFORE_QUIT
    // so the extra silent iterations don't change the asserted pattern.
    if (state.frame >= FRAMES_BEFORE_QUIT) return;

    state.frame += 1;
    game.log.info("[game] game-tick frame={d}", .{state.frame});

    if (state.frame >= FRAMES_BEFORE_QUIT) {
        // Flip the engine's `running` flag so sokol-style backends
        // (which do poll `g.isRunning()`) can exit cleanly if this
        // example is ever ported over. Raylib keeps looping until
        // timeout.
        game.quit();
    }
}
