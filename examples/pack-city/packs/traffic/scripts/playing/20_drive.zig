//! Drive the cars left-to-right across the street, wrapping at the edge.
//!
//! Also the cross-pack CALL that proves the wall: it reads the building
//! count through the EXPOSED surface only — `@import("buildings").queries
//! .count(game)`. Reaching into buildings any other way (its files, its
//! `Building` component, the non-exposed nothing-else) is a compile error
//! (docs/packs.md; the packs-demo fixture probes each negative case). The
//! count is logged once so the transcript shows the two packs cooperating.

const buildings = @import("buildings");
const Car = @import("../../components/car.zig").Car;

pub const game_states = .{"playing"};

const WORLD_W: f32 = 480;

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct {
        frame: u32 = 0,
        logged: bool = false,
    };
}

pub fn tick(game: anytype, state: anytype, _: anytype, dt: f32) void {
    state.frame += 1;

    // Cross-pack call through the exposed query surface.
    if (!state.logged) {
        state.logged = true;
        const n = buildings.queries.count(game);
        game.log.info("[city] buildings standing: {d}", .{n});
    }

    var v = game.active_world.ecs_backend.view(.{Car}, .{});
    defer v.deinit();
    while (v.next()) |e| {
        const car = game.active_world.ecs_backend.getComponent(e, Car) orelse continue;
        var pos = game.getPosition(e);
        pos.x += car.speed * dt;
        if (pos.x > WORLD_W + 30) pos.x = -30;
        game.setPosition(e, pos);
    }
}
