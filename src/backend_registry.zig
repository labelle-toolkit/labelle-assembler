//! backend_registry — the name→package-layout seam for the pluggable-backends
//! epic (#386, Phase 5).
//!
//! Every backend the assembler stages follows ONE uniform package-naming
//! convention, derived purely from its canonical name:
//!
//!   package dir : `backends/{name}`
//!   zon dep name: `labelle_{name}`
//!   link name   : `labelle-{name}`
//!
//! Before this module, ~8 splice/codegen sites re-derived these facts inline
//! from `@tagName(cfg.backend)` + `bufPrint`/`allocPrint`, each re-implementing
//! the convention and — crucially — keyed off a CLOSED `config.Backend` enum.
//! A third-party backend can't be an enum tag, so it could never resolve.
//!
//! This registry centralizes the convention in ONE place and keys it by a
//! plain string (`lookup(allocator, name)`), so a name that is NOT a built-in
//! enum tag still resolves to a valid `BackendInfo`. That string-keying is the
//! pluggability point — the seam that a future resolver (which parses an
//! arbitrary `.backend` name, the explicit follow-up) plugs into.
//!
//! NOTE: this is the NAME layer only. Selecting backend-specific *codegen*
//! (the behavioral `switch (cfg.backend)` sites in build_files.zig /
//! deps_linker.zig) is the manifest splice's job and is intentionally NOT
//! handled here.

const std = @import("std");
const config = @import("config.zig");
const cache = @import("cache.zig");

/// Package-layout facts for a single backend, derived from its canonical name.
/// The `subpath` / `zon_name` / `link_name` fields are allocator-owned (built
/// by `lookup`); free them with `free`.
pub const BackendInfo = struct {
    /// Canonical backend name, e.g. "bgfx". Borrowed — points at the caller's
    /// input string, NOT allocator-owned (so `free` leaves it alone).
    name: []const u8,
    /// Package directory under the staged assembler cache: `backends/{name}`.
    /// Allocator-owned.
    subpath: []const u8,
    /// ZON dependency identifier: `labelle_{name}`. Allocator-owned.
    zon_name: []const u8,
    /// build.zig link/module name: `labelle-{name}`. Allocator-owned.
    link_name: []const u8,
};

/// Resolve the package-layout facts for ANY backend name string.
///
/// Works for names that are NOT `config.Backend` enum tags — that is the whole
/// point: the convention is uniform string derivation, so the registry resolves
/// a plugin backend name exactly the way it resolves a built-in one. The
/// returned `BackendInfo`'s `subpath` / `zon_name` / `link_name` are
/// allocator-owned; free them with `free`. `name` borrows the caller's slice.
pub fn lookup(allocator: std.mem.Allocator, name: []const u8) !BackendInfo {
    // Allocate incrementally with errdefer so a mid-sequence OOM doesn't leak the
    // fields already allocated (the struct never returns, so callers never `free`).
    const subpath = try std.fmt.allocPrint(allocator, "backends/{s}", .{name});
    errdefer allocator.free(subpath);
    const zon_name = try std.fmt.allocPrint(allocator, "labelle_{s}", .{name});
    errdefer allocator.free(zon_name);
    const link_name = try std.fmt.allocPrint(allocator, "labelle-{s}", .{name});
    return .{ .name = name, .subpath = subpath, .zon_name = zon_name, .link_name = link_name };
}

/// Free the allocator-owned fields of an `info` returned by `lookup`.
/// (`name` is borrowed and is left untouched.)
pub fn free(allocator: std.mem.Allocator, info: BackendInfo) void {
    allocator.free(info.subpath);
    allocator.free(info.zon_name);
    allocator.free(info.link_name);
}

/// Resolve the on-disk directory of the backend package for `cfg`, branching on
/// whether the backend is EXTERNAL (`cfg.isExternal()`) or built-in.
///
/// This is the single package-LOCATION seam every backend-package site routes
/// through (`manifest_splice.backendPackageDir`, `deps_linker`, the two
/// `loadBackendTemplate` dir resolutions). It decouples *where* the backend
/// package lives from *what convention names it* (`lookup`):
///
///   - external: located via the plugin-resolution infra
///     (`cache.resolvePlugin(cfg.backend_package.?, ..)`) — `local:`/`@libs`/
///     fetched repos all work, exactly as a plugin does.
///   - built-in: located in the assembler-bundled cache slot
///     (`cache.resolveBundledPackage(.., (lookup name).subpath)` →
///     `backends/{name}`), unchanged from before.
///
/// Caller owns the returned path (free with `allocator.free`).
pub fn resolveBackendPackage(
    allocator: std.mem.Allocator,
    cfg: config.ProjectConfig,
    project_dir: ?[]const u8,
) ![]const u8 {
    if (cfg.effectiveBackendPackage()) |bp| {
        // External: reuse the plugin resolver — same `local:`/`@`/fetched-repo
        // handling, no enum, no bundled cache slot. The package follows the
        // `backends/{name}` convention internally but the dir itself is the
        // plugin checkout root. `effectiveBackendPackage` also covers a built-in
        // enum tag that has been extracted to a provider (the Phase-5
        // enum-as-shorthand) — today that's only an explicit `.backend_package`.
        return cache.resolvePlugin(allocator, bp, project_dir);
    }
    const info = try lookup(allocator, cfg.backendName());
    defer free(allocator, info);
    return cache.resolveBundledPackage(
        allocator,
        cfg.labelle_version,
        cfg.assembler_version,
        project_dir,
        info.subpath,
    );
}

/// The built-in backend names, seeded directly from `config.Backend`'s tags so
/// the registry and the enum cannot silently drift: adding an enum variant
/// adds a name here automatically, and the drift-guard test cross-checks the
/// two sets in both directions.
pub const builtin_names = blk: {
    const fields = @typeInfo(config.Backend).@"enum".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| names[i] = f.name;
    const frozen = names;
    break :blk frozen;
};

/// True if `name` is one of the built-in backend names.
pub fn isBuiltin(name: []const u8) bool {
    for (builtin_names) |b| {
        if (std.mem.eql(u8, b, name)) return true;
    }
    return false;
}

// ── Tests ────────────────────────────────────────────────────────────

test "lookup derives the package convention for a built-in name" {
    const alloc = std.testing.allocator;
    const info = try lookup(alloc, "bgfx");
    defer free(alloc, info);

    try std.testing.expectEqualStrings("bgfx", info.name);
    try std.testing.expectEqualStrings("backends/bgfx", info.subpath);
    try std.testing.expectEqualStrings("labelle_bgfx", info.zon_name);
    try std.testing.expectEqualStrings("labelle-bgfx", info.link_name);
}

test "pluggability: lookup resolves a name with NO enum tag" {
    const alloc = std.testing.allocator;
    // "fictional" is not a config.Backend tag — this is the seam working.
    try std.testing.expect(!isBuiltin("fictional"));

    const info = try lookup(alloc, "fictional");
    defer free(alloc, info);

    try std.testing.expectEqualStrings("fictional", info.name);
    try std.testing.expectEqualStrings("backends/fictional", info.subpath);
    try std.testing.expectEqualStrings("labelle_fictional", info.zon_name);
    try std.testing.expectEqualStrings("labelle-fictional", info.link_name);
}

test "drift guard: builtin_names and config.Backend tags agree both ways" {
    // Every enum tag must be a builtin name…
    inline for (@typeInfo(config.Backend).@"enum".fields) |f| {
        try std.testing.expect(isBuiltin(f.name));
    }
    // …and every builtin name must be an enum tag.
    for (builtin_names) |name| {
        var found = false;
        inline for (@typeInfo(config.Backend).@"enum".fields) |f| {
            if (std.mem.eql(u8, f.name, name)) found = true;
        }
        try std.testing.expect(found);
    }
    // And the counts match (catches a stray addition on either side).
    try std.testing.expectEqual(
        @typeInfo(config.Backend).@"enum".fields.len,
        builtin_names.len,
    );
}

test "lookup matches the inline convention for all 6 built-ins" {
    const alloc = std.testing.allocator;
    for (builtin_names) |name| {
        const info = try lookup(alloc, name);
        defer free(alloc, info);

        const subpath = try std.fmt.allocPrint(alloc, "backends/{s}", .{name});
        defer alloc.free(subpath);
        const zon_name = try std.fmt.allocPrint(alloc, "labelle_{s}", .{name});
        defer alloc.free(zon_name);
        const link_name = try std.fmt.allocPrint(alloc, "labelle-{s}", .{name});
        defer alloc.free(link_name);

        try std.testing.expectEqualStrings(subpath, info.subpath);
        try std.testing.expectEqualStrings(zon_name, info.zon_name);
        try std.testing.expectEqualStrings(link_name, info.link_name);
    }
}

// ── External-backend (open-config) tests ─────────────────────────────
// The open-config seam (epic #386 Phase 5): a backend named by string +
// package (PluginDep) instead of the closed `config.Backend` enum.

test "open-config: an external backend config reports isExternal / backendName by string" {
    // A backend declared only by NAME + repo — no enum tag involved.
    const cfg = config.ProjectConfig{
        .name = "stubgame",
        .backend_package = .{ .name = "stubbackend", .repo = "local:../stub" },
    };
    try std.testing.expect(cfg.isExternal());
    // backendName comes from the package name, NOT @tagName(cfg.backend).
    try std.testing.expectEqualStrings("stubbackend", cfg.backendName());
    // And the registry resolves that string with no enum tag (name-keyed).
    try std.testing.expect(!isBuiltin("stubbackend"));
    const alloc = std.testing.allocator;
    const info = try lookup(alloc, cfg.backendName());
    defer free(alloc, info);
    try std.testing.expectEqualStrings("stubbackend", info.name);
    try std.testing.expectEqualStrings("labelle_stubbackend", info.zon_name);
    try std.testing.expectEqualStrings("labelle-stubbackend", info.link_name);
}

test "open-config: a BUNDLED built-in config is not external and names via the enum" {
    // sokol is the last still-bundled backend (raylib is now an extracted
    // provider — see the enum-as-shorthand test below), so it stays on the
    // non-external enum path.
    const cfg = config.ProjectConfig{ .name = "g", .backend = .sokol };
    try std.testing.expect(!cfg.isExternal());
    try std.testing.expectEqualStrings("sokol", cfg.backendName());
}

test "enum-as-shorthand: extracted backends resolve to their package; the rest stay bundled" {
    // The enum-as-shorthand seam (#386 Phase 5) routes `isExternal`/`backendName`
    // through `effectiveBackendPackage`. bgfx + wgpu + null + sdl + raylib are now
    // EXTRACTED (#386 Phase 6c): `.backend = .<tag>` resolves to the provider
    // package (external, named by the tag — preserved). sokol still ships bundled
    // (not external, no effective package, named by its enum tag). When the next
    // backend is extracted, its tag joins this set.
    inline for (@typeInfo(config.Backend).@"enum".fields) |f| {
        const cfg = config.ProjectConfig{ .name = "g", .backend = @field(config.Backend, f.name) };
        if (cfg.backend == .bgfx or cfg.backend == .wgpu or cfg.backend == .null or cfg.backend == .sdl or cfg.backend == .raylib) {
            try std.testing.expect(cfg.isExternal());
            try std.testing.expect(cfg.effectiveBackendPackage() != null);
            try std.testing.expectEqualStrings(f.name, cfg.backendName());
        } else {
            try std.testing.expect(!cfg.isExternal());
            try std.testing.expect(cfg.effectiveBackendPackage() == null);
            try std.testing.expectEqualStrings(f.name, cfg.backendName());
        }
    }
}

test "enum-as-shorthand: an explicit backend_package still wins (external) over the enum" {
    // `effectiveBackendPackage` prefers an explicit package; the enum tag is only
    // a fallback. (Proves the resolution order at the seam.)
    const cfg = config.ProjectConfig{
        .name = "g",
        .backend = .raylib, // the default enum tag, deliberately left set
        .backend_package = .{ .name = "stubbackend", .repo = "local:../stub" },
    };
    try std.testing.expect(cfg.isExternal());
    try std.testing.expectEqualStrings("stubbackend", cfg.backendName());
    const eff = cfg.effectiveBackendPackage().?;
    try std.testing.expectEqualStrings("stubbackend", eff.name);
}

test "open-config: resolveBackendPackage routes an external backend to its local checkout" {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A project dir with a sibling external-backend checkout next to it:
    //   tmp/project/      (project_dir)
    //   tmp/stubbackend/  (the external backend package)
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.createDirPath(std.testing.io, "stubbackend");

    const project_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "project", alloc);
    defer alloc.free(project_abs);
    const stub_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "stubbackend", alloc);
    defer alloc.free(stub_abs);

    const cfg = config.ProjectConfig{
        .name = "stubgame",
        .backend_package = .{ .name = "stubbackend", .repo = "local:../stubbackend" },
    };

    const resolved = try resolveBackendPackage(alloc, cfg, project_abs);
    defer alloc.free(resolved);

    // Routes through the PLUGIN resolver (local path), NOT the bundled
    // `backends/` cache slot — so it lands on the sibling checkout.
    try std.testing.expectEqualStrings(stub_abs, resolved);
    try std.testing.expect(std.mem.indexOf(u8, resolved, "/backends/") == null);
}
