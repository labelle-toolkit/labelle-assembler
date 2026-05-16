//! Deterministic headless-runner driver. Logs one `[null] frame=N` line
//! per tick so the CI step (and `labelle-assembler#129`'s smoke run) can
//! pin both the iteration count and the clean exit.
//!
//! Exit strategy: the null backend's generated `main()` bounds the loop
//! with `LABELLE_NULL_FRAMES` (default 5) — we don't need to call
//! `game.quit()`. The frame counter exists purely so the log lines stop
//! if a CI run sets `LABELLE_NULL_FRAMES` higher than the canonical
//! count; the test asserts the first FRAMES_BEFORE_QUIT lines, not
//! every line, so the script stays well-defined for any cap.

pub const game_states = .{"playing"};

/// Frames the smoke run logs. Mirrors the null backend's default
/// `LABELLE_NULL_FRAMES` so a vanilla `./game` produces exactly this
/// many log lines before clean exit.
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
