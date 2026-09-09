//! The event both hooks listen to. Two receivers for ONE event is the
//! whole point: with a single listener, dispatch order is unobservable.
//!
//! The assembler scans `events/*.zig` and folds each `pub const <Name>`
//! into `GameEvents` under the tag matching this file's stem (`pulse`).
pub const Pulse = struct {
    n: i32 = 0,
};
