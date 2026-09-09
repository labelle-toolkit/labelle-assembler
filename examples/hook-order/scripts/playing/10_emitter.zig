//! Per-frame emitter. Bumps a counter and emits one `Pulse`; BOTH
//! game-root hooks receive it at this frame's `dispatchEvents`, in
//! receiver-tuple order. The `[order] emit n=N` line brackets each
//! frame's pair so the transcript is unambiguous.

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
    game.log.info("[order] emit n={d}", .{state.n});
    game.emit(.{ .pulse = Pulse{ .n = state.n } });
}
