//! Plugin-shipped per-frame script (RFC-plugin-controllers §2, step-1 half 3).
//!
//! Lives under the plugin's root `scripts/` dir. The assembler auto-copies
//! it into `<target>/scripts/.plugin_demo_plugin/playing/…` (see
//! `src/root.zig::generate` — the scripts/ convention is reserved and
//! auto-discovered without a `plugin.labelle` entry).
//!
//! Numeric prefix `01_` places this ahead of any later plugin scripts in
//! the plugin's own namespace. Its game-state binding is `playing`, so
//! it fires from frame 1 onwards once the setup path has driven the
//! game into that state.
//!
//! Output format is pinned for the CI log-order assertion: a single
//! `[demo-plugin] plugin-tick frame=N` per tick, monotonic in N, matched
//! alongside `[game] game-tick frame=N` lines from the game's own script.
//! The game-tick line for frame N precedes this line because block-1 (game)
//! scripts run before block-2 (plugin) scripts inside the `playing` state.

pub const game_states = .{"playing"};

/// Mirrors the cap in the game's `scripts/playing/01_game_tick.zig`. The
/// null backend caps frames at `LABELLE_NULL_FRAMES` (default 5) — both
/// scripts use the same constant so the captured log stays deterministic
/// even if a CI job sets `LABELLE_NULL_FRAMES` higher than the default.
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
    game.log.info("[demo-plugin] plugin-tick frame={d}", .{state.frame});
}
