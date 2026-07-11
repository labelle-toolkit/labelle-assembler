/// build.zig and build.zig.zon generators for the labelle-cli assembler.
///
/// ── Barrel ──────────────────────────────────────────────────────────
/// This file was a single ~1165-line module; it is now a thin barrel that
/// re-exports the public surface from focused sub-modules under
/// `build_files/` (behavior-preserving split, mirrors #539/#541). Every
/// symbol keeps its original name and identity so existing
/// `build_files.<Name>` call sites (root.zig) are unchanged:
///
///   - `build_files/build_zig.zig`     — `build.zig` generation
///                                       (`sanitizeExeName`, `BuildZigOptions`,
///                                       `generateBuildZig`, + the emit* helpers)
///   - `build_files/build_zig_zon.zig` — `build.zig.zon` generation
///                                       (`BuildZigZonOptions`, `generateBuildZigZon`,
///                                       the deps-link/fallback path, + the
///                                       `deps_linker` re-export)
const build_zig = @import("build_files/build_zig.zig");
const build_zig_zon = @import("build_files/build_zig_zon.zig");

// ── build.zig generator (build_files/build_zig.zig) ──────────────────
pub const sanitizeExeName = build_zig.sanitizeExeName;
pub const BuildZigOptions = build_zig.BuildZigOptions;
pub const PluginHook = build_zig.PluginHook;
pub const PluginBuildStepsWiring = build_zig.PluginBuildStepsWiring;
pub const generateBuildZig = build_zig.generateBuildZig;

// ── build.zig.zon generator (build_files/build_zig_zon.zig) ──────────
pub const deps_linker = build_zig_zon.deps_linker;
pub const BuildZigZonOptions = build_zig_zon.BuildZigZonOptions;
pub const generateBuildZigZon = build_zig_zon.generateBuildZigZon;

// Pull both sub-modules' analysis into `build_files.zig` so `zig build test`
// keeps compiling everything that used to live here.
test {
    _ = build_zig;
    _ = build_zig_zon;
}
