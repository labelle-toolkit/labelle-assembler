const std = @import("std");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const Water = @import("../components/water_shader.zig").WaterShader;
const Fog = @import("../components/fog_shader.zig").FogShader;
const Lamp = @import("../components/lamp_shader.zig").LampShader;

test "water rejects bad impacts, clamps strength, and isolates instances" {
    var a = Water{};
    const b = Water{};
    try std.testing.expectError(error.RippleOutOfBounds, a.impact(-1, 1));
    try std.testing.expectError(error.RippleOutOfBounds, a.impact(93, 1));
    try std.testing.expectError(error.NonFiniteValue, a.impact(std.math.nan(f32), 1));
    try a.impact(92.999, 2);
    try equal(@as(f32, 1), a.ripples[0][2]);
    try equal(@as(usize, 0), b.ripple_count);
    try equal(b.water_level, a.water_level);
}

test "expiry boundary is permanent after duration shortens then lengthens" {
    var w = Water{};
    try w.impact(20, 1);
    try w.advance(0.5);
    try w.patch(.{ .ripple_duration_seconds = @as(f32, 0.5) });
    try equal(@as(usize, 0), w.ripple_count);
    try w.patch(.{ .ripple_duration_seconds = @as(f32, 2) });
    try equal(@as(usize, 0), w.ripple_count);
    try equal([4]f32{ 0, 0, 0, 0 }, w.ripples[0]);
}

test "passive expiry erases the slot, so lengthening cannot resurrect it" {
    var w = Water{};
    try w.impact(20, 1);
    // Time alone retires it: no patch, no shrink, no level change (#734).
    try w.advance(1.0);
    // Assert the RETAINED array, not a payload a filter could be hiding.
    try equal(@as(usize, 0), w.ripple_count);
    try equal([4]f32{ 0, 0, 0, 0 }, w.ripples[0]);
    try w.patch(.{ .ripple_duration_seconds = @as(f32, 5) });
    try equal(@as(usize, 0), w.ripple_count);
    try equal([4]f32{ 0, 0, 0, 0 }, w.ripples[0]);
    // A live impact under the longer window still works afterwards.
    try w.impact(20, 1);
    try w.advance(1.0);
    try equal(@as(usize, 1), w.ripple_count);
}

test "shrinking width retires only out of bounds impacts" {
    var w = Water{};
    try w.impact(12, 1);
    try w.impact(60, 1);
    try w.patch(.{ .logical_size = [2]f32{ 60, 6 } });
    try equal(@as(usize, 1), w.ripple_count);
    try equal(@as(f32, 12), w.ripples[0][0]);
    try w.patch(.{ .logical_size = [2]f32{ 93, 6 } });
    try equal(@as(usize, 1), w.ripple_count);
}

test "rebase preserves impact ages and pause never advances time" {
    var w = Water{ .time = 4095.75 };
    try w.impact(10, 1);
    try w.advance(0.5);
    try equal(@as(f32, 0), w.time);
    try equal(@as(f32, 0.5), w.time - w.ripples[0][1]);
    const before = w;
    try w.advance(0);
    try expect(std.meta.eql(before, w));
    try w.advance(0.4);
    try equal(@as(usize, 0), w.ripple_count);
}

test "oldest ripple replacement has deterministic tie breaks" {
    var w = Water{};
    for (0..8) |i| try w.impact(@floatFromInt(i), 1);
    try w.advance(0.1);
    try w.impact(30, 1);
    try equal(@as(f32, 30), w.ripples[0][0]);
    try w.impact(31, 1);
    try equal(@as(f32, 31), w.ripples[1][0]);
    try equal(@as(usize, 8), w.ripple_count);
}

test "empty water clears impacts and refill does not resurrect" {
    var w = Water{};
    try w.impact(3, 1);
    try w.setLevel(-1);
    try std.testing.expectError(error.EmptyReservoir, w.impact(3, 1));
    try w.setLevel(2);
    try equal(@as(f32, 1), w.water_level);
    try equal(@as(usize, 0), w.ripple_count);
}

test "invalid runtime edits and overflow leave previous state intact" {
    var w = Water{};
    try w.impact(20, 1);
    const before = w;
    try std.testing.expectError(error.InvalidPositiveSetting, w.patch(.{ .ripple_duration_seconds = @as(f32, 0) }));
    try std.testing.expectError(error.NonFiniteValue, w.advance(std.math.inf(f32)));
    try std.testing.expectError(error.NegativeDelta, w.advance(-1));
    try expect(std.meta.eql(before, w));
    w.time = std.math.floatMax(f32);
    try std.testing.expectError(error.NonFiniteValue, w.advance(std.math.floatMax(f32)));
    try equal(std.math.floatMax(f32), w.time);
}

test "partial optional patch inherits missing and preserves explicit zero false" {
    var w = Water{ .reflection_opacity = 0.7, .water_level = 0.5 };
    const Patch = struct { water_level: ?f32 = null, reflection_opacity: ?f32 = null, enabled: ?bool = null };
    try w.patch(Patch{ .reflection_opacity = 0, .enabled = false });
    try equal(@as(f32, 0.5), w.water_level);
    try equal(@as(f32, 0), w.reflection_opacity);
    try expect(!w.enabled);
}

test "lamp width and asymmetric reaches are independent and cell aligned" {
    var l = Lamp{ .center = .{ 51, 51 }, .width = 60, .reach_up = 12, .reach_down = 60 };
    try expect(l.influence(.{ 51, 33 }) == 0);
    try expect(l.influence(.{ 51, 69 }) > 0);
    try equal(l.influence(.{ 49, 67 }), l.influence(.{ 53, 71 }));
    try expect(l.influence(.{ 87, 51 }) == 0);
    l.reach_down = 0;
    try expect(l.influence(.{ 51, 57 }) == 0);
    try expect(l.influence(.{ 51, 45 }) > 0);
    l.width = 0;
    try equal(@as(f32, 0), l.influence(.{ 51, 45 }));
    try l.validate();
}

test "fog zero speed pauses phase, wrap is bounded, invalid delta atomic" {
    var f = Fog{ .phase = 0.95, .speed = 0.1 };
    try f.advance(1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), f.phase, 0.00001);
    f.speed = 0;
    const before = f.phase;
    try f.advance(100);
    try equal(before, f.phase);
    try std.testing.expectError(error.InvalidDelta, f.advance(std.math.nan(f32)));
    try equal(before, f.phase);
    f.density = 0;
    f.light_coupling = 0;
    try f.validate();
}

test "malformed authored runtime water state reports errors before slicing" {
    var w = Water{ .ripple_count = 9 };
    try std.testing.expectError(error.InvalidRippleCount, w.advance(0));
    try std.testing.expectError(error.InvalidRippleCount, w.impact(1, 1));
    try std.testing.expectError(error.InvalidRippleCount, w.setLevel(0));
    w.ripple_count = 0;
    w.time = std.math.nan(f32);
    try std.testing.expectError(error.NonFiniteValue, w.impact(1, 1));
    w.time = 0;
    w.ripples[7][1] = std.math.inf(f32);
    try std.testing.expectError(error.NonFiniteValue, w.advance(0));
}

test "fog drift direction zero negative and zero wisp size are safe" {
    var f = Fog{ .speed = 1, .wisp_size = 48, .drift_velocity = .{ 0, 0 } };
    try f.advance(0.5);
    try equal([2]f32{ 0, 0 }, f.drift_phase);
    f.drift_velocity = .{ 12, -12 };
    try f.advance(1);
    try equal([2]f32{ 0.25, 0.75 }, f.drift_phase);
    f.wisp_size = 0;
    try f.advance(1);
    try equal([2]f32{ 0.25, 0.75 }, f.drift_phase);
    f.wisp_size = 48;
    f.speed = 0;
    const before = f;
    try f.advance(10);
    try expect(std.meta.eql(before, f));
    f.phase = std.math.nan(f32);
    try std.testing.expectError(error.InvalidPhase, f.advance(0));
}

test "lamp spread expands away from source, zero softness and falloff work" {
    var l = Lamp{ .center = .{ 51, 51 }, .width = 24, .reach_down = 60, .softness = 0, .falloff = 0 };
    try equal(@as(f32, 1), l.influence(.{ 51, 99 }));
    try equal(@as(f32, 0), l.influence(.{ 81, 99 }));
    l.spread = 48;
    try equal(@as(f32, 1), l.influence(.{ 81, 99 }));
    l.width = 0;
    try equal(@as(f32, 0), l.influence(.{ 51, 99 }));
    try l.validate();
}

test "lamp glow zero disables halo and flicker is bounded and paused" {
    var l = Lamp{ .flicker = 0.6, .flicker_speed = 1 };
    for (0..100) |_| {
        try l.advance(0.013);
        try expect(l.flickerFactor() >= 0.4 - 0.00001 and l.flickerFactor() <= 1);
    }
    l.flicker = 0;
    try equal(@as(f32, 1), l.flickerFactor());
    l.flicker_speed = 0;
    const before = l.phase;
    try l.advance(100);
    try equal(before, l.phase);
    l.glow = 0;
    try equal(@as(f32, 0), l.influence(.{ 309, 30 }));
    l.phase = std.math.inf(f32);
    try std.testing.expectError(error.InvalidPhase, l.advance(0));
}

const Mist = @import("../components/mist_shader.zig").MistShader;
test "mist anchors to live surface and has bounded independent signed motion" {
    try equal(@as(f32, 294), Mist.surfaceY(288, 36, 5.0 / 6.0));
    try equal(@as(f32, 306), Mist.surfaceY(288, 36, 0.5));
    var a = Mist{ .wisp_size = 96, .drift_velocity = .{ 12, -3 } };
    const b = a;
    try a.advance(8);
    try equal([2]f32{ 0, 0.75 }, a.phase);
    try equal([2]f32{ 0, 0 }, b.phase);
    a.drift_velocity = .{ 0, 0 };
    const before = a;
    try a.advance(100);
    try expect(std.meta.eql(before, a));
    try std.testing.expectError(error.InvalidDelta, a.advance(std.math.nan(f32)));
    try expect(std.meta.eql(before, a));
}
test "mist accepts explicit zero controls and rejects malformed state" {
    var m = Mist{ .height = 0, .density = 0, .opacity = 0, .light_coupling = 0 };
    try m.validate();
    m.wisp_size = 0;
    try std.testing.expectError(error.InvalidMistSetting, m.advance(1));
    m.wisp_size = 96;
    m.drift_velocity[0] = std.math.inf(f32);
    try std.testing.expectError(error.InvalidMistSetting, m.advance(1));
}
