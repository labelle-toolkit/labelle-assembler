//! Verification probe — and the CONTROL switch.
//!
//! The pixel-water effect degrades to the authored static reservoir sprite
//! when the shader program cannot link, so "it looked like water in a
//! screenshot" proves nothing at all. This script prints the two facts that
//! do, once each:
//!
//!   * whether the ENGINE created a gfx water instance for each reservoir
//!     (`game.waterInstance(entity)` — the id the sprite's draw resolves),
//!     and the level it is running at, and
//!   * `CONDENSER_WATER_OFF=1` sets both reservoirs to level 0, which is the
//!     shader's explicit "render no water" gate: the sprite reduces to the
//!     plain static art. That is the control run — the SAME binary, the same
//!     scene, the same sprites, with only the effect switched off — so a
//!     frame-to-frame diff over the reservoir band that is large with water
//!     on and ~0 with it off cannot be anything but the effect.
//!
//! The renderer-side half of the evidence is bgfx's own log line,
//! `bgfx: pixel-water program initialized (renderer: ...)`, and the absence
//! of `fs_pixel_water failed to link` / `pixel_water not supported` /
//! `no resolvable water instance`.

const std = @import("std");

const Reservoir = @import("../../components/reservoir.zig").Reservoir;

pub const game_states = .{"playing"};

fn envIsSet(comptime name: [:0]const u8) bool {
    const raw = std.c.getenv(name.ptr) orelse return false;
    const val = std.mem.span(raw);
    return val.len > 0 and !std.mem.eql(u8, val, "0");
}

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct {
        frame: u32 = 0,
        reported: bool = false,
        control_applied: bool = false,
    };
}

pub fn tick(game: anytype, state: anytype, _: anytype, _: f32) void {
    state.frame += 1;
    const ecs = &game.active_world.ecs_backend;
    const water_off = envIsSet("CONDENSER_WATER_OFF");

    var v = ecs.view(.{Reservoir}, .{});
    defer v.deinit();
    while (v.next()) |e| {
        const res = ecs.getComponent(e, Reservoir) orelse continue;

        if (water_off and !state.control_applied) {
            // Level 0 is the shader's explicit "no water" gate.
            game.setWaterLevel(e, 0.0) catch |err| {
                game.log.err("[condenser] control: setWaterLevel(0) failed: {s}", .{@errorName(err)});
            };
        }

        // The instance is created when the mask texture is resident, which
        // may be a frame or two after load; report once it has had the
        // chance rather than on frame 1, so a "no instance" line is a real
        // failure and not a race.
        if (state.reported or state.frame < 30) continue;
        const comp = game.pixelWater(e) orelse {
            game.log.err("[condenser] unit {d}: NO PixelWater component on the reservoir entity", .{res.unit});
            continue;
        };
        if (game.waterInstance(e)) |id| {
            game.log.info(
                "[condenser] unit {d}: water instance {any} LIVE — level={d:.4} mask='{s}' reflection='{s}' logical={d}x{d} grid={d}",
                .{ res.unit, id, comp.water_level, comp.mask, comp.reflection, comp.logical_size[0], comp.logical_size[1], comp.grid_pixels },
            );
        } else {
            game.log.err(
                "[condenser] unit {d}: PixelWater present but NO gfx water instance — the sprite is drawing the static art",
                .{res.unit},
            );
        }
    }

    if (water_off) state.control_applied = true;
    if (state.frame >= 30) state.reported = true;
}
