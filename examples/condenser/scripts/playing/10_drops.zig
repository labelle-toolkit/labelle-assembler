//! Condensation drops: fall, contact the reservoir's CURRENT water surface,
//! and emit exactly ONE ripple each through the engine's built-in
//! `game.addWaterRipple`.
//!
//! Nothing here animates water. The script's entire contact with the effect
//! is the single `addWaterRipple(reservoir, local_x, strength)` call below —
//! the surface, the wave, the ripple's shape and its decay are all
//! `fs_pixel_water` on the GPU, driven by the engine's water tick.
//!
//! "CURRENT surface" is meant literally: the surface Y is recomputed every
//! frame from the live `PixelWater.water_level` (`surface_y = 6 * (1 -
//! level)` on the measured 6-row basin), so the two reservoirs' different
//! fill levels are honoured by the same code, and a runtime
//! `game.setWaterLevel` would move the impact point with no change here.

const std = @import("std");

const Drop = @import("../../components/drop.zig").Drop;
const Reservoir = @import("../../components/reservoir.zig").Reservoir;

pub const game_states = .{"playing"};

/// Native art px per screen px — every sprite in this game is `scale 6`.
const SCALE: f32 = 6.0;
/// Measured reservoir rect on the native canvas: x 4, y 48, w 93, h 6.
const RESERVOIR_TOP_Y: f32 = 48.0;
const RESERVOIR_H: f32 = 6.0;
/// The drop trail is 5 native px tall with the bright head at the bottom.
const DROP_HEAD_OFFSET: f32 = 4.0;
/// Scene Y to park a waiting drop at — above the window, out of sight.
const PARKED_Y: f32 = -60.0;

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct {
        frame: u32 = 0,
        ripples: u32 = 0,
    };
}

pub fn tick(game: anytype, state: anytype, _: anytype, dt: f32) void {
    state.frame += 1;
    const ecs = &game.active_world.ecs_backend;

    // Resolve unit -> reservoir entity. Two units, so a fixed-size array
    // beats a map; a missing one simply parks its drops.
    const Entity = @TypeOf(game.*).EntityType;
    var basins: [2]?Entity = .{ null, null };
    {
        var rv = ecs.view(.{Reservoir}, .{});
        defer rv.deinit();
        while (rv.next()) |e| {
            const res = ecs.getComponent(e, Reservoir) orelse continue;
            if (res.unit < basins.len) basins[res.unit] = e;
        }
    }

    var v = ecs.view(.{Drop}, .{});
    defer v.deinit();
    while (v.next()) |e| {
        const drop = ecs.getComponent(e, Drop) orelse continue;

        if (!drop.started) {
            // Stagger the first release rather than dropping five at once.
            drop.t = -drop.phase;
            drop.started = true;
        }
        drop.t += dt;

        const basin = basins[@min(drop.unit, basins.len - 1)] orelse continue;

        // Waiting between drips: keep it off screen.
        if (drop.t < 0) {
            var p = game.getPosition(e);
            p.y = PARKED_Y;
            game.setPosition(e, p);
            continue;
        }

        // The LIVE fill level, read off the built-in component every frame.
        const water = game.pixelWater(basin) orelse continue;
        const level = std.math.clamp(water.water_level, 0.0, 1.0);
        const surface_native = RESERVOIR_TOP_Y + RESERVOIR_H * (1.0 - level);

        // Accelerating fall, in native art px.
        const y_native = drop.release_y + 0.5 * drop.gravity * drop.t * drop.t;
        const head_native = y_native + DROP_HEAD_OFFSET;

        if (!drop.rippled and head_native >= surface_native) {
            drop.rippled = true;
            // ONE ripple per fall. `strength` is a DIMENSIONLESS [0,1]
            // scale on the authored `ripple_strength_pixels`; a faster
            // drop hits harder, capped at 1.
            const speed = drop.gravity * drop.t;
            const strength = std.math.clamp(speed / 140.0, 0.35, 1.0);
            game.addWaterRipple(basin, drop.local_x, strength) catch |err| {
                game.log.err("[condenser] addWaterRipple(unit={d}, x={d}) failed: {s}", .{
                    drop.unit, drop.local_x, @errorName(err),
                });
                continue;
            };
            state.ripples += 1;
        }

        if (head_native >= surface_native) {
            // Impact consumed: hide and wait out the interval.
            drop.t = -drop.interval;
            drop.rippled = false;
            var p = game.getPosition(e);
            p.y = PARKED_Y;
            game.setPosition(e, p);
            continue;
        }

        var p = game.getPosition(e);
        p.y = y_native * SCALE;
        game.setPosition(e, p);
    }

    if (state.frame % 120 == 0) {
        game.log.info("[condenser] frame={d} ripples_emitted={d}", .{ state.frame, state.ripples });
    }
}
