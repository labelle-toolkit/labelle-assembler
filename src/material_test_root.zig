//! Dedicated test root for `zig build test-materials` (#741).
//!
//! WHY THIS FILE EXISTS
//!
//! The step used to be a `--test-filter` over `src/root.zig`:
//!
//!     .filters = &.{ "material_schema", "material_pipeline", "component_collisions" }
//!
//! and it ran ZERO material tests. Zig discovers a file's `test` decls only
//! once the file is ANALYZED, and `src/root.zig` reaches its sibling modules
//! lazily — the eager reference is the anonymous `test { _ = @import(...) }`
//! discovery block near the top of `root.zig`, which does not name the
//! material modules. `--test-filter` then removes every NAMED test, leaving
//! only the anonymous `*.test_0` discovery blocks (they are never filtered),
//! and none of those pulls in `material_pipeline.zig`. The result:
//!
//!     $ zig build test-materials --summary all
//!     Build Summary: ... 9/9 tests passed
//!     1/9 root.test_0...OK        <- assertion-free import blocks, all nine
//!
//! So the step named for the materials pipeline ran nine empty import blocks.
//! Force-failing a `material_pipeline` test left it green while the full
//! `zig build test` went red.
//!
//! An explicit root cannot drift the way a name filter can: a module either
//! is imported here or it is not, and `build.zig`'s configure-time guard
//! (`assertMaterialTestRootCoverage`) fails the build if a `src/material_*.zig`
//! exists that this file does not import.
//!
//! This root is wired into BOTH `test-materials` and the full `test` step via
//! the same run artifact, so the two can never report different material test
//! counts.

const std = @import("std");

test {
    _ = @import("material_pipeline.zig");
    _ = @import("material_schema.zig");
    _ = @import("material_build.zig");
    // Not a `material_*` module, but the materials work owns it: the
    // generated materials module collides with a plugin literally named
    // "materials", and the emitted comptime guard lives here. It was in the
    // old filter list; keep it covered.
    _ = @import("component_collisions.zig");
}

/// The `src/material_*.zig` modules the `test` block above imports.
///
/// Kept beside the imports on purpose, and cross-checked against BOTH of
/// them by `build.zig` at configure time — the list may not drift from the
/// imports, and neither may drift from what is on disk.
pub const covered_material_modules = [_][]const u8{
    "material_build.zig",
    "material_pipeline.zig",
    "material_schema.zig",
};

test "test-materials root imports every module it claims to cover (#741)" {
    // The build-time guard in `build.zig` is the load-bearing half (it sees
    // the filesystem). This is the cheap in-binary half: it proves the list
    // above is non-empty and sorted/unique, so the guard has something real
    // to compare against rather than silently passing on an empty set.
    try std.testing.expect(covered_material_modules.len >= 3);
    for (covered_material_modules[1..], 0..) |name, i| {
        try std.testing.expect(std.mem.order(u8, covered_material_modules[i], name) == .lt);
    }
}
