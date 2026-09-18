const std = @import("std");
const engine = @import("labelle-engine");
const Water = @import("../components/water_shader.zig").WaterShader;
const Fog = @import("../components/fog_shader.zig").FogShader;
const Lamp = @import("../components/lamp_shader.zig").LampShader;

fn merged(comptime T: type, comptime file: []const u8, key: []const u8, patch: []const u8, allocator: std.mem.Allocator) !T {
    var base_parser = engine.jsonc_mod.JsoncParser.init(allocator, @embedFile(file));
    const base = try base_parser.parse();
    var patch_parser = engine.jsonc_mod.JsoncParser.init(allocator, patch);
    const override = try patch_parser.parse();
    const value = try engine.unified_format.mergedOverride(base.asObject(), key, override, allocator);
    return engine.jsonc_deserializer.deserialize(T, value, allocator) orelse error.InvalidComponent;
}

test "real prefab merge preserves water defaults and explicit zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const water = try merged(Water, "../prefabs/reservoir.jsonc", "WaterShader", "{\"water_level\":0,\"reflection_opacity\":0}", arena.allocator());
    try std.testing.expectEqual(@as(f32, 0), water.water_level);
    try std.testing.expectEqual(@as(f32, 0), water.reflection_opacity);
    try std.testing.expectEqual(@as(f32, 14), water.ripple_radius_pixels);
    try std.testing.expectEqualStrings("reservoir_mask", water.mask);
}

test "real fog and lamp prefab partial overrides retain omitted fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const fog = try merged(Fog, "../prefabs/fog.jsonc", "FogShader", "{\"opacity\":0,\"density\":0,\"wisp_size\":0,\"drift_velocity\":[0,0],\"enabled\":false}", arena.allocator());
    try std.testing.expect(!fog.enabled);
    try std.testing.expectEqual(@as(f32, 0), fog.opacity);
    try std.testing.expectEqual(@as(f32, 0), fog.density);
    try std.testing.expectEqual(@as(f32, 0.25), fog.turbulence);
    try std.testing.expectEqual([2]f32{ 0, 0 }, fog.drift_velocity);
    const lamp = try merged(Lamp, "../prefabs/lamp.jsonc", "LampShader", "{\"width\":0,\"reach_up\":0,\"glow\":0,\"softness\":0,\"falloff\":0}", arena.allocator());
    try std.testing.expectEqual(@as(f32, 0), lamp.width);
    try std.testing.expectEqual(@as(f32, 0), lamp.reach_up);
    try std.testing.expectEqual(@as(f32, 132), lamp.reach_down);
    try std.testing.expectEqual(@as(f32, 0), lamp.glow);
    try std.testing.expectEqual(@as(f32, 0), lamp.softness);
    try std.testing.expectEqual(@as(f32, 0), lamp.falloff);
}
