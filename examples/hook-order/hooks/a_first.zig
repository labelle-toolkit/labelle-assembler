//! Receiver id: `hooks/a_first`.
//!
//! By the DEFAULT ordering contract this hook runs FIRST: game-root
//! hooks come before pack hooks and flow handlers, and within the root
//! group stems are ordered lexicographically — `a_first` < `z_second`.
//! That default is discovery-driven, which is exactly the problem
//! labelle-assembler#723 addresses: nothing about "a" makes this hook
//! logically first, it just sorts earlier.
//!
//! `project.labelle`'s `.hooks.order` overrides it. See the README.

const std = @import("std");
const Pulse = @import("../events/pulse.zig").Pulse;

pub const AFirst = struct {
    pub fn pulse(self: *const AFirst, ev: Pulse) void {
        _ = self;
        std.log.info("[order] a_first n={d}", .{ev.n});
    }
};
