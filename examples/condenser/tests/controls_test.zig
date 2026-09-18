const std = @import("std");
const controls = @import("../scripts/playing/05_effect_settings.zig");
const Water = @import("../components/water_shader.zig").WaterShader;
const Fog = @import("../components/fog_shader.zig").FogShader;
const Lamp = @import("../components/lamp_shader.zig").LampShader;
const Reservoir = @import("../components/reservoir.zig").Reservoir;
const Key = enum { space, r, f, l, g, q, e, w, s, a, d };
const Ecs = struct {
    waters: [2]Water = .{ .{}, .{ .water_level = 0.5 } },
    fogs: [2]Fog = .{ .{}, .{ .unit = 1 } },
    lamps: [2]Lamp = .{ .{}, .{ .unit = 1 } },
    reservoirs: [2]Reservoir = .{ .{}, .{ .unit = 1 } },
    const View = struct {
        index: usize = 0,
        pub fn next(self: *@This()) ?usize {
            if (self.index == 2) return null;
            defer self.index += 1;
            return self.index;
        }
        pub fn deinit(_: *@This()) void {}
    };
    pub fn view(_: *@This(), comptime _: anytype, comptime _: anytype) View {
        return .{};
    }
    pub fn getComponent(self: *@This(), e: usize, comptime T: type) ?*T {
        if (T == Water) return &self.waters[e];
        if (T == Fog) return &self.fogs[e];
        if (T == Lamp) return &self.lamps[e];
        if (T == Reservoir) return &self.reservoirs[e];
        @compileError("unexpected component");
    }
};
const Game = struct {
    active_world: struct { ecs_backend: Ecs = .{} } = .{},
    key: Key = .space,
    pub fn isKeyPressed(self: *@This(), key: Key) bool {
        return self.key == key;
    }
};

test "real runtime keyboard paths change left only including lamp geometry" {
    var game = Game{};
    var state = controls.State(Ecs){ .initialized = true };
    const right_water = game.active_world.ecs_backend.waters[1];
    const right_fog = game.active_world.ecs_backend.fogs[1];
    const right_lamp = game.active_world.ecs_backend.lamps[1];
    for ([_]Key{ .space, .f, .g, .e, .w, .d }) |key| {
        game.key = key;
        controls.tick(&game, &state, {}, 0);
    }
    const ecs = &game.active_world.ecs_backend;
    try std.testing.expectEqual(@as(f32, 0.5), ecs.waters[0].water_level);
    try std.testing.expect(!ecs.fogs[0].enabled);
    try std.testing.expectEqual(@as(f32, 132), ecs.lamps[0].width);
    try std.testing.expectEqual(@as(f32, 6), ecs.lamps[0].reach_up);
    try std.testing.expectEqual(@as(f32, 78), ecs.lamps[0].reach_down);
    try std.testing.expect(std.meta.eql(right_water, ecs.waters[1]));
    try std.testing.expect(std.meta.eql(right_fog, ecs.fogs[1]));
    try std.testing.expect(std.meta.eql(right_lamp, ecs.lamps[1]));
}
