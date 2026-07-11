//! Game-root native hook — the receiving half of the event-bus demo. The
//! assembler scans `hooks/*.zig` automatically (no project.labelle field)
//! and folds `PulseWatcher` into the generated
//! `GameHooks = engine.MergeHooks(...)` receiver tuple; `dispatchEvents`
//! then calls the method named after each `GameEvents` variant. So one
//! `game.emit(.{ .pulse = ... })` in the emitter script reaches this
//! method, natively, at the same frame's `dispatchEvents` (frame end) —
//! one bus, no glue.
//!
//! The token carries the payload (`[relay] pulse n=N`), proving the
//! emitted `Pulse` crossed the bus intact — CI pins its position in the
//! ordered transcript, interleaved with the emitter's `[relay] emit`.

const std = @import("std");
const Pulse = @import("../events/pulse.zig").Pulse;

pub const PulseWatcher = struct {
    // *const: this receiver is stateless (the dispatcher holds the pointer
    // and coerces). A hook that accumulates state would take `*PulseWatcher`.
    pub fn pulse(self: *const PulseWatcher, ev: Pulse) void {
        _ = self;
        std.log.info("[relay] pulse n={d}", .{ev.n});
    }
};
