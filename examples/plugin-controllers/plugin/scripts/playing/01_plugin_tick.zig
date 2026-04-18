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

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct {
        frame: u32 = 0,
    };
}

pub fn tick(game: anytype, state: anytype, _: anytype, _: f32) void {
    state.frame += 1;
    game.log.info("[demo-plugin] plugin-tick frame={d}", .{state.frame});
}
