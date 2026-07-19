//! One standing structure. Carried by every prefab in this pack; the
//! exposed `count` query (queries.zig) walks it.
pub const Building = struct {
    pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    /// How many citizens the structure houses — here just prefab-varied
    /// data proving component overrides flow through pack prefabs.
    capacity: i32 = 2,
};
