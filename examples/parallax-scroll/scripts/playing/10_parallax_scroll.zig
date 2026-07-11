//! Per-frame parallax scroll driver. Runs in the "playing" state and
//! moves every entity carrying a `Parallax` component leftward at its
//! own `speed`, wrapping by one authored span so the two world-space
//! planes scroll forever. The sky (screen_fill) and HUD (screen) layers
//! carry no `Parallax`, so they stay put — that contrast is the whole
//! demonstration.
//!
//! Renderer-agnostic: it only touches ECS + the engine's Position API
//! (`getPosition` / `setPosition`), so it compiles and RUNS identically
//! on the headless `.null` backend (deterministic fixed dt, frame-capped
//! by `LABELLE_NULL_FRAMES`) and on raylib / sokol / bgfx. Mirrors the
//! proven `view(...)` + per-entity pattern from
//! examples/asset-streaming-smoke's `jump_animator.zig`.

const std = @import("std");

const Parallax = @import("../../components/parallax.zig").Parallax;

pub const game_states = .{"playing"};

/// Entities are authored across x ∈ [0, 960). When one scrolls past the
/// left margin we push it a full span to the right, so the finite set of
/// rectangles reads as an endless scroll.
const WRAP_MIN: f32 = -240;
const WRAP_SPAN: f32 = 960;

pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct {
        frame: u32 = 0,
    };
}

pub fn tick(game: anytype, state: anytype, _: anytype, dt: f32) void {
    state.frame += 1;

    var moved: u32 = 0;
    var v = game.active_world.ecs_backend.view(.{Parallax}, .{});
    defer v.deinit();
    while (v.next()) |entity| {
        const p = game.active_world.ecs_backend.getComponent(entity, Parallax) orelse continue;

        var pos = game.getPosition(entity);
        pos.x -= p.speed * dt;
        if (pos.x < WRAP_MIN) pos.x += WRAP_SPAN;
        game.setPosition(entity, pos);

        moved += 1;
    }

    // Deterministic transcript line — one per frame. A showcase-repo CI
    // step (or a human) can pin the scrolled-entity count the same way
    // examples/null asserts its `[null] frame=N` sequence.
    game.log.info("[parallax] frame={d} scrolled={d}", .{ state.frame, moved });
}
