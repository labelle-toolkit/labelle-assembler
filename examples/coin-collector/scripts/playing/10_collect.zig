//! Coin-collector gameplay loop. Each frame, in the "playing" state:
//!   1. locate the Player and its homing `speed`,
//!   2. snapshot every live Coin (id + position) into a fixed buffer,
//!   3. step the player toward the NEAREST coin (`getPosition` +
//!      `setPosition`),
//!   4. collect any coin now within pickup range (`destroyEntity`),
//!      bumping the score,
//!   5. log a deterministic `[collector] frame=N score=S coins_left=C`
//!      line, plus a one-shot `[collector] cleared` when the field empties.
//!
//! Renderer-agnostic — only ECS + the engine's Position / entity APIs —
//! so it runs identically headless on `.null` (fixed dt, frame-capped)
//! and on raylib / sokol / bgfx. Coins are snapshotted BEFORE any
//! destroy so the `view` is never mutated mid-iteration.

const std = @import("std");

const Player = @import("../../components/player.zig").Player;
const Coin = @import("../../components/coin.zig").Coin;

pub const game_states = .{"playing"};

/// The player's own pickup half-extent; added to each coin's `radius`
/// for the overlap test.
const PLAYER_RADIUS: f32 = 12;

/// Upper bound on coins tracked in one frame (scene ships 5).
const MAX_COINS: usize = 64;

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct {
        frame: u32 = 0,
        score: u32 = 0,
        cleared: bool = false,
    };
}

pub fn tick(game: anytype, state: anytype, _: anytype, dt: f32) void {
    state.frame += 1;

    const ecs = &game.active_world.ecs_backend;

    // 1. Player + speed.
    var player_id: ?@TypeOf(game.*).EntityType = null;
    var speed: f32 = 0;
    {
        var pv = ecs.view(.{Player}, .{});
        defer pv.deinit();
        if (pv.next()) |e| {
            player_id = e;
            if (ecs.getComponent(e, Player)) |p| speed = p.speed;
        }
    }
    const player = player_id orelse return;
    const ppos = game.getPosition(player);

    // 2. Snapshot live coins (id + position + pickup range).
    var ids: [MAX_COINS]@TypeOf(game.*).EntityType = undefined;
    var xs: [MAX_COINS]f32 = undefined;
    var ys: [MAX_COINS]f32 = undefined;
    var ranges: [MAX_COINS]f32 = undefined;
    var n: usize = 0;
    {
        var cv = ecs.view(.{Coin}, .{});
        defer cv.deinit();
        while (cv.next()) |e| {
            if (n >= MAX_COINS) break;
            const c = ecs.getComponent(e, Coin) orelse continue;
            const cp = game.getPosition(e);
            ids[n] = e;
            xs[n] = cp.x;
            ys[n] = cp.y;
            ranges[n] = c.radius + PLAYER_RADIUS;
            n += 1;
        }
    }

    // 3. Step toward the nearest coin.
    if (n > 0) {
        var best: usize = 0;
        var best_d2: f32 = std.math.floatMax(f32);
        for (0..n) |i| {
            const dx = xs[i] - ppos.x;
            const dy = ys[i] - ppos.y;
            const d2 = dx * dx + dy * dy;
            if (d2 < best_d2) {
                best_d2 = d2;
                best = i;
            }
        }
        const dx = xs[best] - ppos.x;
        const dy = ys[best] - ppos.y;
        const dist = @sqrt(dx * dx + dy * dy);
        const step = speed * dt;
        var np = ppos;
        if (dist > step and dist > 0) {
            np.x += dx / dist * step;
            np.y += dy / dist * step;
        } else {
            np.x = xs[best];
            np.y = ys[best];
        }
        game.setPosition(player, np);
    }

    // 4. Collect coins now in range (destroy AFTER the view is closed).
    const now = game.getPosition(player);
    for (0..n) |i| {
        const dx = xs[i] - now.x;
        const dy = ys[i] - now.y;
        if (dx * dx + dy * dy <= ranges[i] * ranges[i]) {
            game.destroyEntity(ids[i]);
            state.score += 1;
        }
    }

    // 5. Deterministic transcript.
    const coins_left = recount(ecs);
    game.log.info("[collector] frame={d} score={d} coins_left={d}", .{ state.frame, state.score, coins_left });
    if (coins_left == 0 and !state.cleared) {
        state.cleared = true;
        game.log.info("[collector] cleared", .{});
    }
}

fn recount(ecs: anytype) u32 {
    var count: u32 = 0;
    var cv = ecs.view(.{Coin}, .{});
    defer cv.deinit();
    while (cv.next()) |_| count += 1;
    return count;
}
