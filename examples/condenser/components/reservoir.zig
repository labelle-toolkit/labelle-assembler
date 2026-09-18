//! Associates drops and WaterShader state with a condenser unit.
pub const Reservoir = struct {
    pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    unit: u32 = 0,
};
