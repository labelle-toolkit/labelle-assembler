//! Query actual generic material bindings, not game-side success flags.
const WaterShader = @import("../../components/water_shader.zig").WaterShader;
const FogShader = @import("../../components/fog_shader.zig").FogShader;
const LampShader = @import("../../components/lamp_shader.zig").LampShader;
const MistShader = @import("../../components/mist_shader.zig").MistShader;
pub const game_states = .{"playing"};
pub fn State(comptime EcsBackend: type) type {
    _ = EcsBackend;
    return struct { frame: u32 = 0 };
}
pub fn tick(game: anytype, state: anytype, _: anytype, _: f32) void {
    state.frame +%= 1;
    if (state.frame != 30 and state.frame % 600 != 0) return;
    const ecs = &game.active_world.ecs_backend;
    inline for (.{ WaterShader, FogShader, LampShader, MistShader }) |T| {
        var view = ecs.view(.{T}, .{});
        defer view.deinit();
        var live: u32 = 0;
        var total: u32 = 0;
        while (view.next()) |entity| {
            total += 1;
            if (game.shaderMaterial(entity) != null) live += 1;
        }
        game.log.info("[condenser] {s}: {d}/{d} generic materials live", .{ @typeName(T), live, total });
    }
}
