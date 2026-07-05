pub const Counter = struct {
    pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    n: i32 = 0,
};
