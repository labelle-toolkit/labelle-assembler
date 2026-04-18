//! Game-owned per-frame script. Logs a `[game] game-tick frame=N` line
//! every tick. Numeric prefix `01_` keeps this ahead of any future game
//! scripts in the `playing` state.
//!
//! The plugin's `01_plugin_tick.zig` runs in a separate per-plugin block
//! (see `ScriptScanner.scanPluginDir` and the `PluginBlockOrdering` tests
//! in `test/script_scanner_tests.zig`), so there's no duplicate-prefix
//! collision between the two files.
//!
//! Exit strategy: the example runs on the *null* backend, whose generated
//! `main()` caps execution at `LABELLE_NULL_FRAMES` frames (default 5)
//! and then falls through to the `defer`-bound teardown. So the loop
//! exits cleanly without needing `game.quit()` or a SIGTERM from
//! `timeout`, and `[demo-plugin] deinit` is observed at the tail of the
//! captured log.
//!
//! The matching CI log assertion (now a `diff -u` against a fixed
//! expected file) expects this canonical sequence in stderr:
//!   [demo-plugin] setup
//!   [game] game-tick frame=1
//!   [demo-plugin] plugin-tick frame=1
//!   [game] game-tick frame=2
//!   [demo-plugin] plugin-tick frame=2
//!   … (FRAMES_BEFORE_QUIT total interleaved game/plugin lines) …
//!   [demo-plugin] deinit
//!
//! Interleaving comes from the engine's script execution order: within
//! the `playing` state, block-1 (game) scripts run before block-2 (plugin)
//! scripts each tick. `PluginControllers.setup` is called once during
//! setup_code before the tick loop starts; `deinit` runs once on shutdown
//! via the `defer` chain in the generated main.

pub const game_states = .{"playing"};

/// Cap the number of frames this script logs. Must stay in sync with
/// the default `LABELLE_NULL_FRAMES` value the null backend uses
/// (`backends/null/templates/desktop.txt` → `DEFAULT_NULL_FRAMES`).
/// If a CI run sets `LABELLE_NULL_FRAMES` higher, the extra ticks
/// silently no-op here so the canonical log sequence stays bounded.
const FRAMES_BEFORE_QUIT: u32 = 5;

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct {
        frame: u32 = 0,
    };
}

pub fn tick(game: anytype, state: anytype, _: anytype, _: f32) void {
    if (state.frame >= FRAMES_BEFORE_QUIT) return;

    state.frame += 1;
    game.log.info("[game] game-tick frame={d}", .{state.frame});
}
