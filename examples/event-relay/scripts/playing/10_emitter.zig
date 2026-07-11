//! Per-frame emitter. Bumps a counter and emits a `Pulse` event carrying
//! it; the game-root hook `hooks/pulse_watcher.zig` receives it at this
//! frame's `dispatchEvents`. Logs `[relay] emit n=N` so the transcript
//! shows the emit paired with the hook's `[relay] pulse n=N`.
//!
//! Engine-level + backend-agnostic (no renderer, no ECS), so it runs
//! identically headless on `.null` (fixed dt, frame-capped) and on any
//! graphics backend.

const Pulse = @import("../../events/pulse.zig").Pulse;

pub const game_states = .{"playing"};

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct {
        n: i32 = 0,
    };
}

pub fn tick(game: anytype, state: anytype, _: anytype, _: f32) void {
    state.n += 1;
    game.log.info("[relay] emit n={d}", .{state.n});
    game.emit(.{ .pulse = Pulse{ .n = state.n } });
}
