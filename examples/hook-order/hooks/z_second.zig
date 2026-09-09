//! Receiver id: `hooks/z_second`.
//!
//! Lexicographically last, so by default it runs after `hooks/a_first`.
//! `project.labelle` gives it `.rank = 100`, which promotes it to the
//! front of the receiver tuple — the whole receiver list, not just its
//! group. The transcript proves the promotion took effect at runtime,
//! not merely in the generated text.

const std = @import("std");
const Pulse = @import("../events/pulse.zig").Pulse;

pub const ZSecond = struct {
    pub fn pulse(self: *const ZSecond, ev: Pulse) void {
        _ = self;
        std.log.info("[order] z_second n={d}", .{ev.n});
    }
};
