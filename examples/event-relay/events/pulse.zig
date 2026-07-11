//! Custom game event. The assembler scans `events/*.zig` and folds each
//! `pub const <Name>` into the project's `GameEvents` union under the tag
//! matching this file's stem (`pulse`). `scripts/playing/10_emitter.zig`
//! emits it with `game.emit(.{ .pulse = .{ .n = ... } })`; the game-root
//! hook `hooks/pulse_watcher.zig` receives it at `dispatchEvents`.
pub const Pulse = struct {
    n: i32 = 0,
};
