const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zclay_dep = b.dependency("zclay", .{ .target = target, .optimize = optimize });
    const zclay_mod = zclay_dep.module("zclay");

    // iOS simulator: force Clay's scalar (non-SIMD) hash path.
    //
    // Clay's `Clay__HashData` uses ARM NEON intrinsics (`vdupq_n_u64`, ...) on
    // `__aarch64__`. Those `always_inline` intrinsics require CPU features
    // (`altnzcv`) that the aarch64 iOS *simulator* target is compiled without,
    // so `zig build -Dtarget=aarch64-ios-simulator` fails with:
    //   error: always_inline function 'vdupq_n_u64' requires target feature
    //   'altnzcv', but would be inlined into function 'Clay__HashData' ...
    // Clay guards every SIMD path behind `CLAY_DISABLE_SIMD` and ships a fully
    // supported scalar fallback, so defining it selects that path.
    //
    // The Clay C library is compiled inside zclay's own `build.zig` (as the
    // static lib named "clay" linked into the zclay module), so we reach that
    // Compile step through the module's link objects and set the macro on it.
    // Mirrors labelle-box2d's `BOX2D_DISABLE_SIMD` simulator/wasm fix. Gated
    // strictly on the iOS simulator triple; device / desktop keep native SIMD.
    if (target.result.os.tag == .ios and target.result.abi == .simulator) {
        for (zclay_mod.link_objects.items) |link_object| {
            switch (link_object) {
                .other_step => |compile| {
                    if (std.mem.eql(u8, compile.name, "clay")) {
                        compile.root_module.addCMacro("CLAY_DISABLE_SIMD", "1");
                    }
                },
                else => {},
            }
        }
    }

    const gui_mod = b.addModule("gui", .{
        .root_source_file = b.path("src/adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    gui_mod.addImport("zclay", zclay_mod);
}
