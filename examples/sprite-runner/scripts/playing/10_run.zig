//! The whole gameplay loop, and both animation tiers side by side.
//!
//! * The bot runs right at `Runner.speed`, wrapping off-screen; its run
//!   cycle comes from the comptime `AnimationDef` table
//!   (`animations/runner.zon` → `run/bot_0001..0006.png`). Playing a
//!   clip is just indexing the table and writing the returned STATIC
//!   name into the Sprite — no per-frame allocation, no name buffer.
//! * The coins spin via `SpriteAnimation` — attached ONCE as data on the
//!   first tick and advanced by the ENGINE (`setDriveSpriteAnimations`),
//!   so this script never touches their frames again.
//! * Clouds drift left and wrap; a coin the bot overlaps "respawns" one
//!   screen ahead and bumps the score (deterministic transcript line).

const std = @import("std");

const engine = @import("labelle-engine");
const Runner = @import("../../components/runner.zig").Runner;
const Coin = @import("../../components/coin.zig").Coin;
const Cloud = @import("../../components/cloud.zig").Cloud;
const SpriteAnimation = engine.SpriteAnimation;

const RunnerAnim = engine.AnimationDef(@import("../../animations/runner.zon"));

pub const game_states = .{"playing"};

const WORLD_W: f32 = 480;
/// Program-lifetime frame table for the coin spin — `SpriteAnimation`
/// borrows its `frames` slice, so it must outlive the entities.
const COIN_FRAMES = [_][]const u8{ "coin_0001.png", "coin_0002.png", "coin_0003.png", "coin_0004.png" };

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct {
        did_setup: bool = false,
        /// Run-clip clock, advanced at the .zon clip's `speed` (fps).
        clock: f32 = 0,
        score: u32 = 0,
        frame_no: u32 = 0,
    };
}

pub fn tick(game: anytype, state: anytype, _: anytype, dt: f32) void {
    const ecs = &game.active_world.ecs_backend;
    const Sprite = @TypeOf(game.*).SpriteComp;
    state.frame_no += 1;

    // One-shot: let the engine advance SpriteAnimations, and attach the
    // coin spin to every Coin entity (data, not per-frame code).
    if (!state.did_setup) {
        state.did_setup = true;
        game.setDriveSpriteAnimations(true);
        var cv = ecs.view(.{Coin}, .{});
        defer cv.deinit();
        while (cv.next()) |e| {
            game.addComponent(e, SpriteAnimation{ .frames = &COIN_FRAMES, .fps = 10 });
        }
    }

    // --- runner: move right, wrap, play the `run` clip from the def table.
    const run_meta = comptime RunnerAnim.clipMeta(.run);
    state.clock += dt * run_meta.speed;
    const frame: u8 = @intFromFloat(@mod(state.clock, @as(f32, run_meta.frame_count)));

    var runner_x: f32 = 0;
    {
        var rv = ecs.view(.{ Runner, Sprite }, .{});
        defer rv.deinit();
        while (rv.next()) |e| {
            const r = ecs.getComponent(e, Runner) orelse continue;
            var pos = game.getPosition(e);
            pos.x += r.speed * dt;
            if (pos.x > WORLD_W + 20) pos.x = -20;
            game.setPosition(e, pos);
            runner_x = pos.x;
            if (ecs.getComponent(e, Sprite)) |sprite| {
                sprite.sprite_name = RunnerAnim.spriteName(.run, .bot, frame);
            }
        }
    }

    // --- coins: pickup on overlap → respawn one screen ahead.
    {
        var cv = ecs.view(.{Coin}, .{});
        defer cv.deinit();
        while (cv.next()) |e| {
            const c = ecs.getComponent(e, Coin) orelse continue;
            var pos = game.getPosition(e);
            if (@abs(pos.x - runner_x) <= c.radius) {
                pos.x += WORLD_W;
                state.score += 1;
                game.log.info("[runner] coin {d} at frame={d}", .{ state.score, state.frame_no });
            }
            if (pos.x > WORLD_W + 40) pos.x -= WORLD_W + 80;
            game.setPosition(e, pos);
        }
    }

    // --- clouds: drift left, wrap.
    {
        var cl = ecs.view(.{Cloud}, .{});
        defer cl.deinit();
        while (cl.next()) |e| {
            const c = ecs.getComponent(e, Cloud) orelse continue;
            var pos = game.getPosition(e);
            pos.x -= c.drift * dt;
            if (pos.x < -30) pos.x = WORLD_W + 30;
            game.setPosition(e, pos);
        }
    }
}
