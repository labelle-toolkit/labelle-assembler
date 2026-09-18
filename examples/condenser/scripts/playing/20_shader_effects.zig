//! Retry late assets and context restoration through the generic game facade.
const materials = @import("materials");
const WaterShader = @import("../../components/water_shader.zig").WaterShader;
const FogShader = @import("../../components/fog_shader.zig").FogShader;
const LampShader = @import("../../components/lamp_shader.zig").LampShader;
pub const game_states = .{"playing"};
pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct { frame: u32 = 0 };
}

pub fn tick(game: anytype, state: anytype, _: anytype, dt: f32) void {
    state.frame +%= 1;
    const ecs = &game.active_world.ecs_backend;
    var wv = ecs.view(.{WaterShader}, .{});
    defer wv.deinit();
    while (wv.next()) |entity| {
        const water = ecs.getComponent(entity, WaterShader) orelse continue;
        water.advance(dt) catch |err| {
            report(game, state.frame, "water state", err);
            continue;
        };
        bindWater(game, entity, water) catch |err| report(game, state.frame, "water material", err);
    }
    var lv = ecs.view(.{LampShader}, .{});
    defer lv.deinit();
    while (lv.next()) |entity| {
        const lamp = ecs.getComponent(entity, LampShader) orelse continue;
        lamp.advance(dt) catch |err| {
            report(game, state.frame, "lamp state", err);
            continue;
        };
        bindLamp(game, entity, lamp) catch |err| report(game, state.frame, "lamp material", err);
    }
    var fv = ecs.view(.{FogShader}, .{});
    defer fv.deinit();
    while (fv.next()) |entity| {
        const fog = ecs.getComponent(entity, FogShader) orelse continue;
        fog.advance(dt) catch |err| {
            report(game, state.frame, "fog state", err);
            continue;
        };
        var light = LampShader{ .enabled = false };
        var lights = ecs.view(.{LampShader}, .{});
        defer lights.deinit();
        while (lights.next()) |le| {
            const candidate = ecs.getComponent(le, LampShader) orelse continue;
            if (candidate.unit == fog.unit) {
                light = candidate.*;
                break;
            }
        }
        bindFog(game, entity, fog, light) catch |err| report(game, state.frame, "fog material", err);
    }
}

fn report(game: anytype, frame: u32, effect: []const u8, err: anyerror) void {
    if (err == error.TextureNotReady and frame <= 300) return;
    if (frame == 1 or frame % 120 == 0) game.log.err("[condenser] {s}: {s}", .{ effect, @errorName(err) });
}

pub fn lampParameters(lamp: LampShader) [20]f32 {
    return .{ lamp.center[0], lamp.center[1], lamp.width, lamp.intensity, lamp.reach_up, lamp.reach_down, lamp.grid_pixels, if (lamp.enabled) 1 else 0, lamp.color[0], lamp.color[1], lamp.color[2], 0, lamp.spread, lamp.softness, lamp.falloff, lamp.glow, lamp.flicker, lamp.phase, 0, 0 };
}

pub fn bindWater(game: anytype, entity: anytype, w: *WaterShader) !void {
    try w.validate();
    if (game.shaderMaterial(entity) == null) {
        try game.createShaderMaterial(entity, .{
            .label = "condenser_water",
            .shaders = materials.water.shaders,
            .parameters = &materials.water.parameters,
            .textures = &.{
                .{ .name = "s_water_mask", .texture = .{ .catalog = w.mask }, .sampler = .point },
                .{ .name = "s_water_reflect", .texture = .{ .catalog = w.reflection }, .sampler = .point },
            },
        });
    }
    try game.setShaderTexture(entity, "s_water_mask", w.mask);
    try game.setShaderTexture(entity, "s_water_reflect", w.reflection);
    try game.setShaderParameter(entity, "u_water_head", &.{ w.logical_size[0], w.logical_size[1], w.grid_pixels, @floatFromInt(w.ripple_count), 0, 1, 1, 0 });
    var colors: [12]f32 = undefined;
    @memcpy(colors[0..4], &w.deep_color);
    @memcpy(colors[4..8], &w.surface_color);
    @memcpy(colors[8..12], &w.highlight_color);
    try game.setShaderParameter(entity, "u_water_color", &colors);
    try game.setShaderParameter(entity, "u_water_params", &.{
        if (w.enabled) w.water_level else 0, w.time,               0,                         3,
        0,                                   w.reflection_opacity, w.ripple_duration_seconds, w.ripple_radius_pixels,
        w.ripple_strength_pixels,            0,                    0,                         0,
    });
    const ripples: *const [32]f32 = @ptrCast(&w.ripples);
    try game.setShaderParameter(entity, "u_water_ripples", ripples);
}

pub fn bindFog(game: anytype, entity: anytype, f: *FogShader, light: LampShader) !void {
    try f.validate();
    try light.validate();
    if (game.shaderMaterial(entity) == null) {
        try game.createShaderMaterial(entity, .{
            .label = "condenser_fog",
            .shaders = materials.fog.shaders,
            .parameters = &materials.fog.parameters,
            .textures = &.{
                .{ .name = "s_fog_clean", .texture = .{ .catalog = "fog_clean" }, .sampler = .point },
                .{ .name = "s_fog_mask", .texture = .{ .catalog = "fog_mask" }, .sampler = .point },
            },
        });
    }
    try game.setShaderParameter(entity, "u_fog", &.{ f.density, f.phase, f.variation, f.light_coupling });
    try game.setShaderParameter(entity, "u_fog_motion", &.{ f.wisp_size, f.turbulence, f.drift_phase[0], f.drift_phase[1] });
    try game.setShaderParameter(entity, "u_fog_opacity", &.{f.opacity});
    try game.setShaderParameter(entity, "u_fog_color", &f.color);
    try game.setShaderParameter(entity, "u_fog_grid", &.{ 618, 330, f.grid_pixels, if (f.enabled) 1 else 0 });
    try game.setShaderParameter(entity, "u_lamp", &lampParameters(light));
}

pub fn bindLamp(game: anytype, entity: anytype, light: *LampShader) !void {
    try light.validate();
    if (game.shaderMaterial(entity) == null) {
        try game.createShaderMaterial(entity, .{
            .label = "condenser_lamp",
            .shaders = materials.lamp.shaders,
            .parameters = &materials.lamp.parameters,
            .textures = &.{
                .{ .name = "s_lamp_clean", .texture = .{ .catalog = "lamp_clean" }, .sampler = .point },
                .{ .name = "s_lamp_mask", .texture = .{ .catalog = "lamp_mask" }, .sampler = .point },
            },
        });
    }
    try game.setShaderParameter(entity, "u_lamp", &lampParameters(light.*));
}
