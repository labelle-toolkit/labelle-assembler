//! Runtime controls. Numeric zero is a value, never an unset sentinel.
const std = @import("std");
const WaterShader = @import("../../components/water_shader.zig").WaterShader;
const FogShader = @import("../../components/fog_shader.zig").FogShader;
const LampShader = @import("../../components/lamp_shader.zig").LampShader;
const Reservoir = @import("../../components/reservoir.zig").Reservoir;
const MistShader = @import("../../components/mist_shader.zig").MistShader;
pub const game_states = .{"playing"};
pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct { initialized: bool = false, frame: u32 = 0 };
}
fn envEquals(comptime name: [:0]const u8, value: []const u8) bool {
    const raw = std.c.getenv(name.ptr) orelse return false;
    return std.mem.eql(u8, std.mem.span(raw), value);
}
fn envFloat(comptime name: [:0]const u8) ?f32 {
    const raw = std.c.getenv(name.ptr) orelse return null;
    const value = std.fmt.parseFloat(f32, std.mem.span(raw)) catch return null;
    return if (std.math.isFinite(value)) value else null;
}
pub fn tick(game: anytype, state: anytype, _: anytype, _: f32) void {
    state.frame +%= 1;
    const ecs = &game.active_world.ecs_backend;
    const test_all = state.frame == 60 and envEquals("CONDENSER_TEST_LEFT", "1");
    const change_level = game.isKeyPressed(.space) or test_all or (state.frame == 60 and envEquals("CONDENSER_TEST_CONTROL", "water"));
    const splash = game.isKeyPressed(.r);
    const toggle_fog = game.isKeyPressed(.f) or test_all or (state.frame == 60 and envEquals("CONDENSER_TEST_CONTROL", "fog"));
    const toggle_lamp = game.isKeyPressed(.l);
    const lamp_preset = game.isKeyPressed(.g) or test_all or (state.frame == 60 and envEquals("CONDENSER_TEST_CONTROL", "lamp"));
    const width_step: f32 = (if (game.isKeyPressed(.e)) @as(f32, 12) else 0) - (if (game.isKeyPressed(.q)) @as(f32, 12) else 0);
    const up_step: f32 = (if (game.isKeyPressed(.w)) @as(f32, 6) else 0) - (if (game.isKeyPressed(.s)) @as(f32, 6) else 0);
    const down_step: f32 = (if (game.isKeyPressed(.d)) @as(f32, 12) else 0) - (if (game.isKeyPressed(.a)) @as(f32, 12) else 0);
    var wv = ecs.view(.{ WaterShader, Reservoir }, .{});
    defer wv.deinit();
    while (wv.next()) |entity| {
        const water = ecs.getComponent(entity, WaterShader) orelse continue;
        const unit = (ecs.getComponent(entity, Reservoir) orelse continue).unit;
        if (!state.initialized) {
            if (envFloat("CONDENSER_WATER_LEVEL")) |v| water.setLevel(v) catch {};
            if (envFloat("CONDENSER_WATER_OFF")) |v| {
                if (v != 0) water.setLevel(0) catch {};
            }
        }
        if (unit == 0 and change_level) water.setLevel(if (water.water_level > 0.6) 0.5 else 0.8333) catch {};
        if (unit == 0 and splash) water.impact(water.logical_size[0] * 0.5, 1) catch {};
    }
    var fv = ecs.view(.{FogShader}, .{});
    defer fv.deinit();
    while (fv.next()) |entity| {
        const fog = ecs.getComponent(entity, FogShader) orelse continue;
        if (!state.initialized) {
            var candidate = fog.*;
            if (envFloat("CONDENSER_FOG_DENSITY")) |v| candidate.density = v;
            if (envFloat("CONDENSER_FOG_OPACITY")) |v| candidate.opacity = v;
            if (envFloat("CONDENSER_FOG_SPEED")) |v| candidate.speed = v;
            if (envFloat("CONDENSER_FOG_VARIATION")) |v| candidate.variation = v;
            if (envFloat("CONDENSER_FOG_WISP_SIZE")) |v| candidate.wisp_size = v;
            if (envFloat("CONDENSER_FOG_TURBULENCE")) |v| candidate.turbulence = v;
            if (envFloat("CONDENSER_FOG_DRIFT_X")) |v| candidate.drift_velocity[0] = v;
            if (envFloat("CONDENSER_FOG_DRIFT_Y")) |v| candidate.drift_velocity[1] = v;
            if (envFloat("CONDENSER_FOG_LIGHT")) |v| candidate.light_coupling = v;
            if (envFloat("CONDENSER_FOG_OFF")) |v| candidate.enabled = v == 0;
            candidate.validate() catch continue;
            fog.* = candidate;
        }
        if (fog.unit == 0 and toggle_fog) fog.enabled = !fog.enabled;
    }
    var lv = ecs.view(.{LampShader}, .{});
    defer lv.deinit();
    while (lv.next()) |entity| {
        const lamp = ecs.getComponent(entity, LampShader) orelse continue;
        if (!state.initialized) {
            var candidate = lamp.*;
            if (envFloat("CONDENSER_LAMP_WIDTH")) |v| candidate.width = v;
            if (envFloat("CONDENSER_LAMP_UP")) |v| candidate.reach_up = v;
            if (envFloat("CONDENSER_LAMP_DOWN")) |v| candidate.reach_down = v;
            if (envFloat("CONDENSER_LAMP_INTENSITY")) |v| candidate.intensity = v;
            if (envFloat("CONDENSER_LAMP_SPREAD")) |v| candidate.spread = v;
            if (envFloat("CONDENSER_LAMP_SOFTNESS")) |v| candidate.softness = v;
            if (envFloat("CONDENSER_LAMP_FALLOFF")) |v| candidate.falloff = v;
            if (envFloat("CONDENSER_LAMP_GLOW")) |v| candidate.glow = v;
            if (envFloat("CONDENSER_LAMP_FLICKER")) |v| candidate.flicker = v;
            if (envFloat("CONDENSER_LAMP_FLICKER_SPEED")) |v| candidate.flicker_speed = v;
            if (envFloat("CONDENSER_LAMP_OFF")) |v| candidate.enabled = v == 0;
            candidate.validate() catch continue;
            lamp.* = candidate;
        }
        if (lamp.unit == 0 and toggle_lamp) lamp.enabled = !lamp.enabled;
        if (lamp.unit == 0) {
            if (lamp_preset) {
                const narrow = lamp.width > 200;
                lamp.width = if (narrow) 120 else 348;
                lamp.reach_up = if (narrow) 0 else 12;
                lamp.reach_down = if (narrow) 66 else 132;
            }
            if (width_step != 0) lamp.width = std.math.clamp(lamp.width + width_step, 0, 618);
            if (up_step != 0) lamp.reach_up = std.math.clamp(lamp.reach_up + up_step, 0, 330);
            if (down_step != 0) lamp.reach_down = std.math.clamp(lamp.reach_down + down_step, 0, 330);
        }
    }
    var mv = ecs.view(.{MistShader}, .{});
    defer mv.deinit();
    while (mv.next()) |entity| {
        const mist = ecs.getComponent(entity, MistShader) orelse continue;
        if (!state.initialized) {
            if (envFloat("CONDENSER_MIST_OFF")) |v| mist.enabled = v == 0;
            if (envFloat("CONDENSER_MIST_OPACITY")) |v| {
                if (v >= 0 and v <= 1) mist.opacity = v;
            }
            if (envEquals("CONDENSER_MIST_FREEZE", "1")) mist.drift_velocity = .{ 0, 0 };
        }
        if (mist.unit == 0 and (game.isKeyPressed(.m) or (state.frame == 60 and envEquals("CONDENSER_TEST_CONTROL", "mist")))) mist.enabled = !mist.enabled;
    }
    state.initialized = true;
}
