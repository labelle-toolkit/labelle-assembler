/// Plugin manifest support — reads `plugin.labelle` from a plugin
/// directory, validates it against the project's plugin declaration,
/// and exposes the convention directories the generator should
/// copy/scan in addition to the hardcoded ones.
///
/// See `docs/RFC-plugin-manifest.md` for the design and rationale.
///
/// ── Barrel ──────────────────────────────────────────────────────────
/// This file was a single ~1350-line module; it is now a thin barrel that
/// re-exports the public surface from focused sub-modules under
/// `plugin_manifest/` (behavior-preserving split, mirrors #539). Every
/// symbol keeps its original name and identity so existing
/// `plugin_manifest.<Name>` call sites are unchanged:
///
///   - `plugin_manifest/common.zig` — shared version gate + reserved/safe
///                                    name checks (`SUPPORTED_MANIFEST_VERSION`,
///                                    `RESERVED_DIR_NAMES`, `isReservedDirName`,
///                                    `isSafeDirName`)
///   - `plugin_manifest/plugin.zig` — `plugin.labelle` schema + loaders
///                                    (`ConventionDir`, `PluginManifest`,
///                                    `loadOptional`, `loadFromDir`, …)
///   - `plugin_manifest/pack.zig`   — `pack.labelle` schema + loaders
///                                    (`PackManifest`, `PackExposes`,
///                                    `loadPackOptional`, `loadPackFromDir`,
///                                    `packDirHasDeclModuleContent`, …)
const common = @import("plugin_manifest/common.zig");
const plugin = @import("plugin_manifest/plugin.zig");
const pack = @import("plugin_manifest/pack.zig");

// ── Shared constants + name validation (plugin_manifest/common.zig) ──
pub const SUPPORTED_MANIFEST_VERSION = common.SUPPORTED_MANIFEST_VERSION;
pub const RESERVED_DIR_NAMES = common.RESERVED_DIR_NAMES;
pub const isReservedDirName = common.isReservedDirName;
pub const isSafeDirName = common.isSafeDirName;

// ── Plugin manifest (`plugin.labelle`) (plugin_manifest/plugin.zig) ──
pub const ConventionDirMode = plugin.ConventionDirMode;
pub const ConventionDir = plugin.ConventionDir;
pub const PluginManifest = plugin.PluginManifest;
pub const loadOptional = plugin.loadOptional;
pub const loadFromDir = plugin.loadFromDir;

// ── Pack manifest (`pack.labelle`) (plugin_manifest/pack.zig) ────────
pub const PackConventionMode = pack.PackConventionMode;
pub const PackExposes = pack.PackExposes;
pub const PackManifest = pack.PackManifest;
pub const loadPackOptional = pack.loadPackOptional;
pub const loadPackFromDir = pack.loadPackFromDir;
pub const packDirHasDeclModuleContent = pack.packDirHasDeclModuleContent;

// Pull every sub-module's tests into the `plugin_manifest.zig` analysis so
// `zig build test` keeps running the specs that used to live here.
test {
    _ = common;
    _ = plugin;
    _ = pack;
}
