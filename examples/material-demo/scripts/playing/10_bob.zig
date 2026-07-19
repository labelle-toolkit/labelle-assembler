//! Bob every Orb on a sine path around its captured baseline Y. Keeps the
//! bright cores drifting so the bloom pass has moving highlights to catch —
//! the post-fx stack itself is entirely declarative (project.labelle
//! `.post_fx`); this script only animates the sources.

const std = @import("std");

const Orb = @import("../../components/orb.zig").Orb;

pub const game_states = .{"playing"};

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct {
        t: f32 = 0,
        frame: u32 = 0,
    };
}

pub fn tick(game: anytype, state: anytype, _: anytype, dt: f32) void {
    state.t += dt;
    state.frame += 1;
    const ecs = &game.active_world.ecs_backend;

    var v = ecs.view(.{Orb}, .{});
    defer v.deinit();
    while (v.next()) |e| {
        const orb = ecs.getComponent(e, Orb) orelse continue;
        var pos = game.getPosition(e);
        if (!orb.anchored) {
            orb.base_y = pos.y;
            orb.anchored = true;
        }
        pos.y = orb.base_y + orb.amplitude * @sin(state.t * 1.6 + orb.phase);
        game.setPosition(e, pos);
    }

    if (state.frame % 60 == 0) {
        game.log.info("[postfx] frame={d} — bloom+vignette+color_grade+crt active", .{state.frame});
    }
}
