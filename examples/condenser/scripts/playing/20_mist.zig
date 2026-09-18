//! Drift the mist plume horizontally on its own sine.
//!
//! Its period (11 s by default) is deliberately unrelated to the water's
//! wave period (3 s) and to the drop intervals, so "the mist drifts
//! independently of the water" is visible as two motions that never lock
//! together — and a frame diff over the reservoir band is never explained
//! away by the mist, which lives on its own layer above it.

const std = @import("std");

const MistDrift = @import("../../components/mist_drift.zig").MistDrift;

pub const game_states = .{"playing"};

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct { t: f32 = 0 };
}

pub fn tick(game: anytype, state: anytype, _: anytype, dt: f32) void {
    state.t += dt;
    const ecs = &game.active_world.ecs_backend;

    var v = ecs.view(.{MistDrift}, .{});
    defer v.deinit();
    while (v.next()) |e| {
        const m = ecs.getComponent(e, MistDrift) orelse continue;
        const period = @max(m.period, 0.001);
        var p = game.getPosition(e);
        p.x = m.base_x + m.amplitude * @sin(std.math.tau * (state.t / period) + m.phase);
        game.setPosition(e, p);
    }
}
