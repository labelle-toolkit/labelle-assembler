const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.dependency("core", .{ .target = target, .optimize = optimize }).module("labelle-core");
    // GLSL profile + bgfx API of the BUILTIN bgfx provider's shaderc: CI's
    // material-pipeline-e2e job builds shaderc from that provider's zbgfx
    // pin (bgfx 0.30.0 -> API 161, GLSL 330; see material_schema.toolchain_api161).
    const materials = @import("material_build.zig").create(b, target, optimize, core, &.{ .{ .name = "fog", .json = @embedFile("materials/fog/material.json") }, .{ .name = "water", .json = @embedFile("materials/water/material.json") }, .{ .name = "lamp", .json = @embedFile("materials/lamp/material.json") } }, "desktop", "330", "161");
    const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("test.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "materials", .module = materials }, .{ .name = "labelle-core", .module = core } } }) });
    b.default_step.dependOn(&b.addRunArtifact(t).step);
}
