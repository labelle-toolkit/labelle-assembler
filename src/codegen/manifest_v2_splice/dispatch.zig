//! Section dispatchers for the manifest-v2 codegen (behavior-preserving split of
//! `manifest_v2_splice.zig`). The two `switch (cfg.platform)` routers that fan the
//! backend-dep + link sections out to the per-platform emitters. Kept in their own
//! module (importing `common` + each platform) so the platform modules stay leaf
//! consumers of `common` with no cross-platform imports.

const std = @import("std");
const common = @import("common.zig");
const desktop = @import("desktop.zig");
const android = @import("android.zig");
const ios = @import("ios.zig");
const wasm = @import("wasm.zig");

const BackendManifestV2 = common.BackendManifestV2;
const ProjectConfig = common.ProjectConfig;

/// Renders the backend-dep section from typed v2 manifest data (the sole
/// backend-dep codegen path since the enum/v1 branch was removed in #461).
/// Dispatches on the target platform: DESKTOP (sokol byte anchor / generic
/// declarative), ANDROID, IOS, WASM golden cells.
pub fn renderBackendDepSectionV2(
    allocator: std.mem.Allocator,
    m: BackendManifestV2,
    cfg: ProjectConfig,
    w: anytype,
) !void {
    switch (cfg.platform) {
        // Desktop has TWO shapes: the sokol byte anchor (unrolled sokol residual,
        // §7) vs the fully-declarative generic path (loop-form walk, golden cells
        // like null/wgpu, PR 8). See `isDesktopByteAnchor`.
        .desktop => if (common.isDesktopByteAnchor(m))
            try desktop.renderDesktopBackendDepV2(allocator, m, cfg, w)
        else
            try desktop.renderDesktopBackendDepGenericV2(allocator, m, cfg, w),
        .android => try android.renderAndroidBackendDepV2(allocator, m, cfg, w),
        .ios => try ios.renderIosBackendDepV2(allocator, m, cfg, w),
        .wasm => try wasm.renderWasmBackendDepV2(allocator, m, cfg, w),
    }
}

/// Renders the link section from typed v2 manifest data (the sole link codegen
/// path since the enum/v1 branch was removed in #461). Dispatches on the target
/// platform: DESKTOP (byte anchor), ANDROID, IOS, WASM golden cells.
pub fn renderLinkSectionV2(
    allocator: std.mem.Allocator,
    m: BackendManifestV2,
    cfg: ProjectConfig,
    w: anytype,
) !void {
    switch (cfg.platform) {
        // Desktop: the sokol byte anchor (unrolled residual) vs the generic
        // declarative link (manifest-driven artifact + per-OS framework/syslib).
        .desktop => if (common.isDesktopByteAnchor(m))
            try desktop.renderDesktopLinkV2(m, w)
        else
            try desktop.renderDesktopLinkGenericV2(m, w),
        .android => try android.renderAndroidLinkV2(m, cfg, w),
        .ios => try ios.renderIosLinkV2(m, w),
        .wasm => try wasm.renderWasmLinkV2(m, cfg, w),
    }
    _ = allocator;
}
