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

// ── Provider identity & collision (RFC §1616, ecosystem-hardening #453) ──
//
// Once `.backend_package = .{ .repo = "github:someone/labelle-vulkan" }` is
// legal, bare backend names collide across vendors. Each provider declares a
// canonical `<namespace>.<name>` ID in its manifest; the reserved `labelle.`
// namespace is the official-provider marker (the `labelle-toolkit` org owns
// it). These checks make that identity explicit and namespaced instead of
// assuming a closed enum — the provider-graph analog of the core-diamond
// unification check.
//
// The identity errors:
//   error.ReservedProviderNamespace — a third party claims a `labelle.*` ID
//                                       (namespace `labelle`, repo NOT under
//                                       github.com/labelle-toolkit/ and not a
//                                       trusted local dev checkout).
//   error.ProviderIdDrift           — a BUILT-IN enum-shorthand tag whose
//                                       manifest `.id` ≠ `labelle.<tag>`
//                                       (mirrors the `builtin_names` drift guard).
//   error.MalformedProviderId       — an `.id` with no `.` (not `<ns>.<name>`).
//   error.ProviderIdCollision       — two resolved providers share one ID.

/// True when a repo string denotes an OFFICIAL (labelle-toolkit-owned) source
/// or a trusted LOCAL dev checkout. Local (`local:` / `@`) repos are exempt
/// from the reserved-namespace rule so a `local:backends/sokol` dev override
/// can legitimately be `labelle.sokol`. A remote repo is official iff its URL
/// is under the `labelle-toolkit/` org.
fn repoIsOfficialOrLocal(repo: []const u8) bool {
    if (config.PluginDep.isLocal(.{ .name = "", .repo = repo })) return true;
    // A remote repo is official iff it is OWNED by the `labelle-toolkit` org —
    // i.e. its URL STARTS with one of the supported owner-prefixed forms. A bare
    // `indexOf("labelle-toolkit/")` was too loose: it also matched a hostile URL
    // that merely CONTAINS that path segment (e.g.
    // `https://evil.com/labelle-toolkit/x`), letting any repo claim the reserved
    // `labelle.*` namespace. Anchoring on the host+owner prefix closes that.
    const official_prefixes = [_][]const u8{
        "https://github.com/labelle-toolkit/",
        "git@github.com:labelle-toolkit/",
        "github:labelle-toolkit/",
        // Scheme-less form used by the enum-shorthand `builtinProvider` defaults.
        "github.com/labelle-toolkit/",
    };
    for (official_prefixes) |prefix| {
        if (std.mem.startsWith(u8, repo, prefix)) return true;
    }
    return false;
}

/// Validate the resolved backend provider's identity against `manifest_id`
/// (the `.id` from its `backend.manifest.zon`, or null when it ships none).
///
/// Rules (RFC §1629-1637):
///   - a third party claiming `labelle.*` → `error.ReservedProviderNamespace`.
///   - a built-in enum-shorthand tag (`.backend = .<tag>`, no explicit
///     `.backend_package`) whose `.id` ≠ `labelle.<tag>` → `error.ProviderIdDrift`.
///   - an `.id` that isn't `<namespace>.<name>` → `error.MalformedProviderId`.
///
/// Back-compat: `manifest_id == null` is NOT an error. A built-in derives
/// `labelle.<name>` silently; an external provider is WARNED (required-`.id`
/// enforcement lands in a later release). No-op for a bundled backend (no
/// provider package — none exist today).
pub fn validateProviderIdentity(cfg: config.ProjectConfig, manifest_id: ?[]const u8) !void {
    const bp = cfg.effectiveBackendPackage() orelse return; // bundled: no identity
    const name = cfg.backendName();
    // `.backend = .<tag>` with no explicit `.backend_package` is the enum
    // shorthand — the ONLY case the drift guard applies to (the tag pins the
    // expected `labelle.<tag>` ID).
    const is_enum_shorthand = cfg.backend_package == null;

    const id = manifest_id orelse {
        if (!is_enum_shorthand) {
            std.log.warn(
                "labelle-assembler: external backend '{s}' (backend_package) ships no `.id` in its backend.manifest.zon; deriving '{s}' for now (a future release will require an explicit canonical `<namespace>.<name>` id).",
                .{ name, name },
            );
        }
        // Built-in with no id → derive `labelle.<name>`, no error.
        return;
    };

    const dot = std.mem.indexOfScalar(u8, id, '.') orelse {
        std.debug.print(
            "labelle-assembler: backend provider id '{s}' is not a canonical '<namespace>.<name>' (e.g. 'labelle.sokol', 'acme.vulkan').\n",
            .{id},
        );
        return error.MalformedProviderId;
    };
    // A dot alone isn't enough: `.sokol` (empty namespace, dot == 0) and
    // `labelle.` (empty name, dot is the last byte) are BOTH malformed —
    // `<namespace>.<name>` requires a non-empty half on each side.
    if (dot == 0 or dot + 1 == id.len) {
        std.debug.print(
            "labelle-assembler: backend provider id '{s}' is not a canonical '<namespace>.<name>' — both the namespace and the name must be non-empty (e.g. 'labelle.sokol').\n",
            .{id},
        );
        return error.MalformedProviderId;
    }
    const namespace = id[0..dot];

    if (std.mem.eql(u8, namespace, "labelle") and !repoIsOfficialOrLocal(bp.repo)) {
        std.debug.print(
            "labelle-assembler: backend provider '{s}' claims the reserved 'labelle.*' namespace but resolves from '{s}',\n  which is not an official labelle-toolkit repo. The 'labelle.' namespace is reserved for official\n  providers; use a '<vendor>.<name>' id instead.\n",
            .{ id, bp.repo },
        );
        return error.ReservedProviderNamespace;
    }

    if (is_enum_shorthand) {
        // The enum tag is a shorthand for `labelle.<tag>` ONLY; a built-in
        // manifest whose id disagrees has drifted from its tag.
        const prefix = "labelle.";
        const matches = std.mem.startsWith(u8, id, prefix) and
            std.mem.eql(u8, id[prefix.len..], name);
        if (!matches) {
            std.debug.print(
                "labelle-assembler: built-in backend '{s}' (selected by enum tag) declares id '{s}',\n  but the tag is a shorthand for 'labelle.{s}'. Fix the provider's backend.manifest.zon `.id`.\n",
                .{ name, id, name },
            );
            return error.ProviderIdDrift;
        }
    }
}

/// Detect a canonical-ID collision across the full resolved provider set
/// (RFC §1634): two providers claiming the same `<namespace>.<name>` is a hard
/// error, not a silent last-wins. Today the provider set is effectively the
/// single render backend, so this is future-proofing for when plugins/audio
/// providers also carry identities — but it is the one place the whole set is
/// cross-checked, mirroring the core-diamond unification check.
/// Gate the PRIVILEGED callback-lifecycle blocks (#461). `preview =
/// .sokol_readback` and `android_register = .bgfx_shell` emit assembler-owned
/// Zig that references backend-PRIVATE symbols (sokol's GL/D3D11/Metal readback
/// externs; the bgfx NativeActivity-shell register). Selecting them moved from
/// the `cfg.backend` enum to manifest data (#461), so this restores the safety
/// the enum implicitly provided: only a reserved `labelle.*` provider may
/// declare them. `validateProviderIdentity` separately enforces `labelle.*` ⟹
/// official/local repo, so a namespace check here suffices — a hostile
/// `labelle.evil` from a non-official repo is rejected there, an `acme.*`
/// declaring a privileged block is rejected here. An unprivileged third-party
/// callback backend keeps the empty-preview / no-register / stub-dispatch
/// defaults and never trips this.
pub fn assertLifecyclePrivilege(
    cfg: config.ProjectConfig,
    declares_privileged: bool,
    manifest_id: ?[]const u8,
) !void {
    if (!declares_privileged) return;
    // Bundled built-in (no provider package): in-tree/trusted. None exist today,
    // but keep the shape parallel to validateProviderIdentity's early return.
    _ = cfg.effectiveBackendPackage() orelse return;
    const id = manifest_id orelse {
        std.debug.print(
            "labelle-assembler: a backend provider declares a PRIVILEGED lifecycle block " ++
                "(sokol readback / bgfx shell) but ships no canonical `.id`. Those blocks emit " ++
                "backend-private Zig and are reserved to the official `labelle.*` namespace.\n",
            .{},
        );
        return error.PrivilegedLifecycleRequiresReservedNamespace;
    };
    const dot = std.mem.indexOfScalar(u8, id, '.') orelse id.len;
    if (!std.mem.eql(u8, id[0..dot], "labelle")) {
        std.debug.print(
            "labelle-assembler: backend provider '{s}' declares a PRIVILEGED lifecycle block " ++
                "(`preview = .sokol_readback` or `android_register = .bgfx_shell`), but those emit " ++
                "backend-private Zig and are reserved to the official `labelle.*` namespace. A " ++
                "third-party callback backend uses the unprivileged defaults (empty preview, no " ++
                "Android register, input-dispatch stub).\n",
            .{id},
        );
        return error.PrivilegedLifecycleRequiresReservedNamespace;
    }
}

pub fn checkProviderIdCollisions(ids: []const []const u8) !void {
    for (ids, 0..) |a, i| {
        for (ids[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a, b)) {
                std.debug.print(
                    "labelle-assembler: two resolved providers claim the same canonical id '{s}'. Provider ids must be globally unique.\n",
                    .{a},
                );
                return error.ProviderIdCollision;
            }
        }
    }
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

test "open-config: the last extracted built-in (sokol) is external and names via its enum tag" {
    // sokol was the final still-bundled backend; as of #386 Phase 6c it is an
    // extracted provider too, so EVERY built-in `.backend` tag now resolves to
    // an external package while keeping its tag-spelled name.
    const cfg = config.ProjectConfig{ .name = "g", .backend = .sokol };
    try std.testing.expect(cfg.isExternal());
    try std.testing.expect(cfg.effectiveBackendPackage() != null);
    try std.testing.expectEqualStrings("sokol", cfg.backendName());
}

test "enum-as-shorthand: every built-in backend resolves to its provider package" {
    // The enum-as-shorthand seam (#386 Phase 5) routes `isExternal`/`backendName`
    // through `effectiveBackendPackage`. As of #386 Phase 6c ALL six built-ins
    // (bgfx/wgpu/null/sdl/raylib/sokol) are EXTRACTED: `.backend = .<tag>`
    // resolves to the provider package (external, named by the preserved tag).
    // There are no longer any bundled backends, so `builtinProvider` has no
    // `null` arms and production codegen is fully backend-agnostic.
    inline for (@typeInfo(config.Backend).@"enum".fields) |f| {
        const cfg = config.ProjectConfig{ .name = "g", .backend = @field(config.Backend, f.name) };
        try std.testing.expect(cfg.isExternal());
        try std.testing.expect(cfg.effectiveBackendPackage() != null);
        try std.testing.expectEqualStrings(f.name, cfg.backendName());
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

// ── Provider identity & collision tests (RFC §1616, #453) ────────────

test "identity: a third party claiming labelle.* is rejected" {
    // External backend_package resolving from a NON-labelle-toolkit remote repo
    // may not claim the reserved `labelle.` namespace.
    const cfg = config.ProjectConfig{
        .name = "g",
        .backend_package = .{ .name = "vulkan", .repo = "github:someone/labelle-vulkan" },
    };
    try std.testing.expectError(
        error.ReservedProviderNamespace,
        validateProviderIdentity(cfg, "labelle.vulkan"),
    );
}

test "identity: a local dev checkout may legitimately be labelle.*" {
    // The retained in-tree sokol fixture (`local:backends/sokol`) is
    // labelle.sokol — local repos are trusted dev overrides, exempt from the
    // reserved-namespace rule.
    const cfg = config.ProjectConfig{
        .name = "g",
        .backend = .sokol,
        .backend_package = .{ .name = "sokol", .repo = "local:backends/sokol" },
    };
    try validateProviderIdentity(cfg, "labelle.sokol");
}

test "identity: a third-party vendor namespace is accepted" {
    const cfg = config.ProjectConfig{
        .name = "g",
        .backend_package = .{ .name = "vulkan", .repo = "github:someone/labelle-vulkan" },
    };
    try validateProviderIdentity(cfg, "someone.vulkan");
}

test "identity: an enum-shorthand built-in whose id drifts from its tag errors" {
    // `.backend = .sokol` is a shorthand for `labelle.sokol`; a manifest id of
    // `labelle.bgfx` has drifted from the tag.
    const cfg = config.ProjectConfig{ .name = "g", .backend = .sokol };
    try std.testing.expectError(
        error.ProviderIdDrift,
        validateProviderIdentity(cfg, "labelle.bgfx"),
    );
}

test "identity: an enum-shorthand built-in with the matching id is accepted" {
    const cfg = config.ProjectConfig{ .name = "g", .backend = .sokol };
    try validateProviderIdentity(cfg, "labelle.sokol");
    // And every built-in tag agrees with its `labelle.<tag>` shorthand.
    inline for (@typeInfo(config.Backend).@"enum".fields) |f| {
        const c = config.ProjectConfig{ .name = "g", .backend = @field(config.Backend, f.name) };
        const expected = "labelle." ++ f.name;
        try validateProviderIdentity(c, expected);
    }
}

test "identity: a malformed id (no namespace) errors" {
    const cfg = config.ProjectConfig{ .name = "g", .backend = .sokol };
    try std.testing.expectError(
        error.MalformedProviderId,
        validateProviderIdentity(cfg, "sokolonly"),
    );
}

test "privilege: a third-party declaring a privileged lifecycle block is rejected (#461)" {
    // A non-`labelle.*` backend that declares `preview = .sokol_readback` or
    // `android_register = .bgfx_shell` (declares_privileged = true) would emit
    // backend-private Zig it can't satisfy — rejected at validation.
    const cfg = config.ProjectConfig{
        .name = "g",
        .backend_package = .{ .name = "vulkan", .repo = "github:someone/labelle-vulkan" },
    };
    try std.testing.expectError(
        error.PrivilegedLifecycleRequiresReservedNamespace,
        assertLifecyclePrivilege(cfg, true, "someone.vulkan"),
    );
    // ...and a privileged declaration with NO canonical id can't prove entitlement.
    try std.testing.expectError(
        error.PrivilegedLifecycleRequiresReservedNamespace,
        assertLifecyclePrivilege(cfg, true, null),
    );
    // An UNprivileged callback backend (declares_privileged = false) is always fine.
    try assertLifecyclePrivilege(cfg, false, "someone.vulkan");
}

test "privilege: a labelle.* provider may declare the privileged blocks (#461)" {
    // The built-in sokol/bgfx path: a reserved-namespace id (validated official/
    // local by `validateProviderIdentity`) is entitled to the privileged blocks.
    const cfg = config.ProjectConfig{
        .name = "g",
        .backend = .sokol,
        .backend_package = .{ .name = "sokol", .repo = "local:backends/sokol" },
    };
    try assertLifecyclePrivilege(cfg, true, "labelle.sokol");
}

test "identity: a spoof repo merely CONTAINING labelle-toolkit/ is rejected (#453 security)" {
    // `https://evil.com/labelle-toolkit/x` is NOT owned by the labelle-toolkit
    // org — it just embeds that path segment. It must not be able to claim the
    // reserved `labelle.*` namespace (the old `indexOf` let it through).
    const spoofs = [_][]const u8{
        "https://evil.com/labelle-toolkit/vulkan",
        "git@evil.com:labelle-toolkit/vulkan",
        "https://gitlab.com/notlabelle-toolkit/x", // owner isn't labelle-toolkit
    };
    inline for (spoofs) |repo| {
        const cfg = config.ProjectConfig{
            .name = "g",
            .backend_package = .{ .name = "vulkan", .repo = repo },
        };
        try std.testing.expectError(
            error.ReservedProviderNamespace,
            validateProviderIdentity(cfg, "labelle.vulkan"),
        );
    }
}

test "identity: the real labelle-toolkit owner forms may claim labelle.* (#453 security)" {
    // Every supported OWNER-prefixed remote form is accepted (so the official
    // providers and the scheme-less enum-shorthand defaults still pass).
    const official = [_][]const u8{
        "https://github.com/labelle-toolkit/labelle-vulkan",
        "git@github.com:labelle-toolkit/labelle-vulkan",
        "github:labelle-toolkit/labelle-vulkan",
        "github.com/labelle-toolkit/labelle-vulkan",
    };
    inline for (official) |repo| {
        const cfg = config.ProjectConfig{
            .name = "g",
            .backend_package = .{ .name = "vulkan", .repo = repo },
        };
        try validateProviderIdentity(cfg, "labelle.vulkan");
    }
}

test "identity: an id with an empty namespace or name is malformed (#453)" {
    const cfg = config.ProjectConfig{ .name = "g", .backend = .sokol };
    // Empty namespace (`.sokol`, dot == 0) and empty name (`labelle.`, dot is
    // the last byte) are both rejected — a lone dot is not `<ns>.<name>`.
    try std.testing.expectError(
        error.MalformedProviderId,
        validateProviderIdentity(cfg, ".sokol"),
    );
    try std.testing.expectError(
        error.MalformedProviderId,
        validateProviderIdentity(cfg, "labelle."),
    );
}

test "identity: back-compat — a built-in with no id derives silently (no error)" {
    const cfg = config.ProjectConfig{ .name = "g", .backend = .sokol };
    try validateProviderIdentity(cfg, null);
}

test "identity: back-compat — an external with no id warns but does not error" {
    const cfg = config.ProjectConfig{
        .name = "g",
        .backend_package = .{ .name = "vulkan", .repo = "github:someone/labelle-vulkan" },
    };
    try validateProviderIdentity(cfg, null);
}

test "collision: duplicate provider ids are a hard error, unique ids pass" {
    try checkProviderIdCollisions(&.{ "labelle.sokol", "labelle.miniaudio" });
    try std.testing.expectError(
        error.ProviderIdCollision,
        checkProviderIdCollisions(&.{ "labelle.sokol", "acme.thing", "labelle.sokol" }),
    );
    // Empty / single sets never collide.
    try checkProviderIdCollisions(&.{});
    try checkProviderIdCollisions(&.{"labelle.sokol"});
}
