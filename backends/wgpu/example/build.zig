const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Fetch the WebGPU backend package (parent directory) ───────────
    const wgpu_backend = b.dependency("labelle_wgpu", .{
        .target = target,
        .optimize = optimize,
    });

    // ── Build the example executable ─────────────────────────────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("gfx", wgpu_backend.module("gfx"));
    exe_mod.addImport("input", wgpu_backend.module("input"));
    exe_mod.addImport("audio", wgpu_backend.module("audio"));
    exe_mod.addImport("window", wgpu_backend.module("window"));

    const exe = b.addExecutable(.{
        .name = "wgpu-demo",
        .root_module = exe_mod,
    });

    // Link native artifacts.
    // Zig 0.16 moved `linkLibrary` / `linkSystemLibrary` / `addLibraryPath`
    // (and friends like `addCSourceFile`, `addIncludePath`) from
    // `*Build.Step.Compile` onto the executable's `root_module`.
    //
    // The actual WebGPU runtime is the wgpu-native static library
    // (`libwgpu_native.a`), which `wgpu_native_zig` already embeds into its
    // `wgpu` module via `addObjectFile`. That module is imported by the
    // backend's `gfx`/`window` modules, so the native symbols travel into
    // this exe transitively — no explicit wgpu library link is needed here.
    // We only need the GLFW windowing artifact plus, on Apple platforms, the
    // system frameworks wgpu-native depends on (Metal/QuartzCore/Foundation),
    // which upstream links at the Compile step rather than on the module.
    exe.root_module.linkLibrary(wgpu_backend.artifact("glfw"));

    const target_result = target.result;
    if (target_result.os.tag == .macos or target_result.os.tag == .ios) {
        exe.root_module.linkFramework("Foundation", .{});
        exe.root_module.linkFramework("QuartzCore", .{});
        exe.root_module.linkFramework("Metal", .{});
    }

    b.installArtifact(exe);

    // ── Run step ─────────────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the WebGPU backend demo");
    run_step.dependOn(&run_cmd.step);
}
