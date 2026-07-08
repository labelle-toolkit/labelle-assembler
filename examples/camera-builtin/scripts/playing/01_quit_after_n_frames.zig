//! Deterministic headless-runner driver (mirrors examples/null). Logs one
//! `[null] frame=N` line per tick so the smoke run can pin both the
//! iteration count and the clean exit. The null backend's generated main()
//! bounds the loop with LABELLE_NULL_FRAMES (default 5).

pub const game_states = .{"playing"};

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
    game.log.info("[null] frame={d}", .{state.frame});
}
