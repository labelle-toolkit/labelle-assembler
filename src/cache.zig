/// Package cache manager — resolves versioned dependencies to local paths.
///
/// Cache layout:
///   ~/.labelle/packages/
///     core/0.3.0/              (fetched from core repo)
///     engine/0.3.0/            (fetched from engine repo)
///     gfx/0.3.0/              (fetched from gfx repo)
///     plugins/{repo}/{version}/ (fetched from plugin repos)
///     cli/0.3.0/              (populated from CLI companion directory)
///       backends/sokol/
///       ecs/zig-ecs/
///
/// Overridable via LABELLE_HOME env var.
///
/// This file is the public façade for the cache. Implementation lives in
/// per-concern submodules under `src/cache/`:
///
///   * env.zig     — env-var lookup, `$LABELLE_HOME`/`$HOME`/`$TEMP` resolution,
///                   `~/.labelle/packages/` layout constants
///   * resolve.zig — pinned dep → on-disk cache path (pure path math + worktree
///                   linkfile handling for `local:` overrides)
///   * disk.zig    — populate, symlink, copy, and patch operations on the
///                   cache directory tree
///   * fetch.zig   — git-clone framework / plugin / GUI packages into the
///                   cache, plus `.url`+`hash` verification
///
/// Existing callers `@import("cache.zig")` and reach every name through this
/// file's re-exports, so no caller had to change during the split.
const env = @import("cache/env.zig");
const resolve = @import("cache/resolve.zig");
const disk = @import("cache/disk.zig");
const fetch = @import("cache/fetch.zig");

// ── env / layout ─────────────────────────────────────────────────────
pub const getCacheRoot = env.getCacheRoot;
pub const getPackagesDir = env.getPackagesDir;
pub const getTempPath = env.getTempPath;

// ── path resolution ──────────────────────────────────────────────────
pub const resolveFrameworkPackage = resolve.resolveFrameworkPackage;
pub const resolveAssemblerPackage = resolve.resolveAssemblerPackage;
pub const resolveBundledPackage = resolve.resolveBundledPackage;
pub const resolvePlugin = resolve.resolvePlugin;
pub const resolveGuiPackage = resolve.resolveGuiPackage;
pub const resolveGuiUrl = resolve.resolveGuiUrl;
pub const toMainCheckoutPath = resolve.toMainCheckoutPath;
pub const isFrameworkCached = resolve.isFrameworkCached;
pub const isAssemblerCached = resolve.isAssemblerCached;
pub const isPluginCached = resolve.isPluginCached;
pub const validateCache = resolve.validateCache;

// ── disk operations ──────────────────────────────────────────────────
pub const populateAssemblerCache = disk.populateAssemblerCache;
pub const populateFrameworkPackage = disk.populateFrameworkPackage;
pub const populatePlugin = disk.populatePlugin;
pub const patchCachedDeps = disk.patchCachedDeps;
pub const dirExists = disk.dirExists;
pub const isSymlink = disk.isSymlink;
pub const copyDirRecursive = disk.copyDirRecursive;

// ── remote fetching ──────────────────────────────────────────────────
pub const R2_BASE_URL = fetch.R2_BASE_URL;
pub const downloadFile = fetch.downloadFile;
pub const extractTarGz = fetch.extractTarGz;
pub const fetchFrameworkPackage = fetch.fetchFrameworkPackage;
pub const fetchPlugin = fetch.fetchPlugin;
pub const fetchAssemblerPackages = fetch.fetchAssemblerPackages;
pub const fetchGuiPackage = fetch.fetchGuiPackage;
pub const fetchGuiUrl = fetch.fetchGuiUrl;
pub const verifyGuiUrlHash = fetch.verifyGuiUrlHash;

test {
    // Pull in submodule tests when this façade is referenced from the
    // top-level test aggregator (root.zig's refAllDecls walk includes
    // `cache.zig` but does not descend into nested `@import`s).
    _ = env;
    _ = resolve;
    _ = disk;
    _ = fetch;
}
