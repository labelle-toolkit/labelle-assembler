pub const Recipe = struct {
    pub const save = @import("labelle-core").Saveable(.saveable, @This(), .{});
    output: i32 = 0,
};
