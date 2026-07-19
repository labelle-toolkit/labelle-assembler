//! Walk the island's path loop and follow with the camera.
//!
//! Each frame: step the Explorer entity toward its current waypoint (the
//! four corners of the path rectangle authored in assets/island.tmx),
//! advance to the next corner on arrival, then re-center the camera on
//! the explorer — clamped so the view never shows past the map edge.
//!
//! The camera half of this file is the camera-prefabs "soft ownership"
//! contract (engine#714): the scene's `Camera` component seeded
//! zoom/center once on load; the per-frame follow lives HERE, in game
//! code, via `getCamera().setPosition`.

const std = @import("std");

const Explorer = @import("../../components/explorer.zig").Explorer;

pub const game_states = .{"playing"};

/// Path-loop corners in world px — the centers of the path tiles at the
/// four corners of the rectangle drawn into island.tmx's ground layer
/// (tile coords (9,7) → (30,16), 16 px tiles).
const WAYPOINTS = [_][2]f32{
    .{ 152, 120 },
    .{ 488, 120 },
    .{ 488, 264 },
    .{ 152, 264 },
};

/// Map extents (40x24 tiles of 16 px) and view half-extents at the
/// scene's 2x zoom (640x360 window → 320x180 world px visible).
const MAP_W: f32 = 640;
const MAP_H: f32 = 384;
const HALF_VIEW_W: f32 = 160;
const HALF_VIEW_H: f32 = 90;

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct { frame: u32 = 0 };
}

pub fn tick(game: anytype, state: anytype, _: anytype, dt: f32) void {
    state.frame += 1;
    const ecs = &game.active_world.ecs_backend;

    var v = ecs.view(.{Explorer}, .{});
    defer v.deinit();
    const entity = v.next() orelse return;
    const explorer = ecs.getComponent(entity, Explorer) orelse return;

    // Step toward the current waypoint; snap + advance on arrival.
    var pos = game.getPosition(entity);
    const target = WAYPOINTS[explorer.waypoint % WAYPOINTS.len];
    const dx = target[0] - pos.x;
    const dy = target[1] - pos.y;
    const dist = @sqrt(dx * dx + dy * dy);
    const step = explorer.speed * dt;
    if (dist <= step or dist == 0) {
        pos.x = target[0];
        pos.y = target[1];
        explorer.waypoint = @intCast((explorer.waypoint + 1) % WAYPOINTS.len);
    } else {
        pos.x += dx / dist * step;
        pos.y += dy / dist * step;
    }
    game.setPosition(entity, pos);

    // Camera follow, clamped to the island map so the view edge never
    // leaves the tilemap. Guarded so the script still compiles on a
    // camera-less backend.
    if (comptime @hasDecl(@TypeOf(game.*), "getCamera")) {
        const cx = std.math.clamp(pos.x, HALF_VIEW_W, MAP_W - HALF_VIEW_W);
        const cy = std.math.clamp(pos.y, HALF_VIEW_H, MAP_H - HALF_VIEW_H);
        game.getCamera().setPosition(cx, cy);
    }

    // Deterministic once-a-second transcript for smoke runs.
    if (state.frame % 60 == 0) {
        game.log.info("[explorer] frame={d} x={d:.0} y={d:.0} waypoint={d}", .{ state.frame, pos.x, pos.y, explorer.waypoint });
    }
}
