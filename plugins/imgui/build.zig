const std = @import("std");
const cimgui = @import("cimgui");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_cimgui = b.dependency("cimgui", .{ .target = target, .optimize = optimize });

    const cimgui_conf = cimgui.getConfig(false);
    const cimgui_mod = dep_cimgui.module(cimgui_conf.module_name);

    // GUI adapter module — satisfies GuiInterface contract.
    // Module name must be `labelle_imgui` to match the assembler's
    // `gui_mod_name = "labelle_<gui.name>"` template (build_files.zig:87).
    // Mismatch was the historical cause of `gui_dep.module("labelle_imgui")`
    // panicking with "unable to find module" when the assembler-bundled
    // imgui plugin tried to be used as a `.gui = .{ .path = ... }` source.
    const gui_mod = b.addModule("labelle_imgui", .{
        .root_source_file = b.path("src/adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_mod.addImport("cimgui", cimgui_mod);

    // Re-export cimgui artifact so it can be linked into the final executable
    const cimgui_artifact = dep_cimgui.artifact(cimgui_conf.clib_name);
    b.installArtifact(cimgui_artifact);
}
