//! Resolve-time provider-contract checks, extracted from `root.zig`
//! (behavior-preserving split). Canonical provider identity, cross-provider
//! id collision, and capability negotiation — all read from the resolved
//! backend's manifest BEFORE the build graph is emitted. See RFC "Opening
//! the ecosystem" (§1616-1683) / ecosystem-hardening #453.

const std = @import("std");
const config = @import("../config.zig");
const backend_registry = @import("../backend_registry.zig");
const manifest_splice = @import("../codegen/manifest_splice.zig");
const manifest_v2 = @import("../codegen/manifest_v2.zig");
const capabilities = @import("../capabilities.zig");
const version_floors = @import("../version_floors.zig");
const manifest_v2_splice = @import("../codegen/manifest_v2_splice.zig");

const ProjectConfig = config.ProjectConfig;

/// One failed provider check: the error `generate` returns and the
/// diagnostic it prints (no trailing newline). `describe` reports the same
/// message as its `reason`.
pub const Problem = struct {
    err: anyerror,
    message: []const u8,
};

/// What `checkProvider` found. `problem == null` means `generate` passes
/// every provider check for this config.
pub const Verdict = struct {
    problem: ?Problem = null,
    /// A `backend.manifest.v2.zon` was found and parsed.
    manifest_loaded: bool = false,
    /// The provider's canonical id, once it passed the identity check: the
    /// manifest's `.id`, or `labelle.<name>` derived for an enum-shorthand
    /// built-in whose manifest omits it (as `validateProviderIdentity` does).
    /// Null when unknown or when the identity check failed.
    id: ?[]const u8 = null,
};

pub const CheckOptions = struct {
    /// The `.labelle/tests/` target: capabilities, the platform entry and the
    /// callback rule are not checked (see `validateProviderContracts`).
    is_tests_target: bool = false,
    /// Log the non-fatal findings (curated floors, a provider with no
    /// capabilities or no id, unsupported post-fx) as `generate` always has.
    /// `describe` passes false.
    emit_warnings: bool = true,
};

/// THE provider/manifest validation `generate` runs before any codegen,
/// shared with `describe` (labelle-cli#471 D1) so the two cannot drift.
/// In `generate`'s order:
///
///   1. the backend package ships a manifest (`requireManifestIfExternal`);
///   2. version floors (`version_floors.verdict`, compile breaks refuse);
///   3. the manifest is the v2 build-graph manifest (a legacy-only package
///      cannot generate: `ExternalBackendNeedsManifest`) and it parses;
///   4. the provider contracts: lifecycle privilege, identity, id collision,
///      capabilities (skipped for the tests target);
///   5. the editor-preview wasm link path (only when preview is on);
///   6. the declared `.build_hook` file exists (staged into every target);
///   7. exe target only: the `.platforms.<platform>` entry
///      (`V2PlatformUnsupported`), its entry template file
///      (`TemplateNotFound`), its `.builtin` root build deps
///      (`UnknownBuiltinRootDep`), and the callback rule
///      (`ExternalCallbackBackendUnsupported`) — the checks the template
///      load, build.zig.zon emission and `main.zig` render also make later.
///
/// Every allocation is `arena`-owned. Returns an error only for a failure
/// to CHECK (OOM, an unresolvable package path); a failed check is a
/// `Verdict.problem`.
pub fn checkProvider(
    arena: std.mem.Allocator,
    cfg: ProjectConfig,
    game_dir: []const u8,
    opts: CheckOptions,
) !Verdict {
    var v: Verdict = .{};
    const name = cfg.backendName();

    // 1. A manifest at all.
    const pkg_dir = try backend_registry.resolveBackendPackage(arena, cfg, game_dir);
    const v2_path = try std.fs.path.join(arena, &.{ pkg_dir, manifest_v2.V2_MANIFEST_NAME });
    const legacy_path = try std.fs.path.join(arena, &.{ pkg_dir, manifest_splice.LEGACY_MANIFEST_NAME });
    const has_v2 = exists(v2_path);
    if (cfg.isExternal() and !has_v2 and !exists(legacy_path)) {
        v.problem = .{ .err = error.ExternalBackendNeedsManifest, .message = try std.fmt.allocPrint(arena, "labelle-assembler: external backend '{s}' (backend_package) ships no {s} — " ++
            "an external backend must declare its codegen via a manifest (the enum-path fallback no longer exists).", .{ name, manifest_v2.V2_MANIFEST_NAME }) };
        return v;
    }

    // 2. Version floors: config-only, but after the manifest check (#746).
    if (try floorProblem(arena, cfg, opts.emit_warnings)) |p| {
        v.problem = p;
        return v;
    }

    // 3. No v2 manifest: only a legacy `backend.manifest.zon` (or, for a
    // bundled backend, none). Its identity/capabilities slice is still
    // checked, as `validateProviderContracts` does, but the exe target
    // cannot generate from it: the entry template comes only from the v2
    // `.platforms.<p>.entry` (`templates.loadBackendTemplate`).
    if (!has_v2) {
        const pm = manifest_splice.loadProviderManifest(arena, cfg, game_dir) catch |err| {
            v.problem = .{ .err = err, .message = try std.fmt.allocPrint(arena, "labelle-assembler: backend '{s}': {s} at '{s}' could not be read ({s}).", .{ name, manifest_splice.LEGACY_MANIFEST_NAME, pkg_dir, @errorName(err) }) };
            return v;
        };
        if (try contractProblem(arena, cfg, .{
            .manifest_id = if (pm) |x| x.id else null,
            .declared = if (pm) |x| x.capabilities else &.{},
            .declares_privileged = false,
            .post_fx = if (pm) |x| x.post_fx_passes else null,
        }, opts)) |p| {
            v.problem = p;
            return v;
        }
        if (cfg.editor_preview) {
            v.problem = try editorPreviewProblem(arena, name);
            return v;
        }
        if (opts.is_tests_target) return v;
        v.problem = .{ .err = error.ExternalBackendNeedsManifest, .message = try std.fmt.allocPrint(arena, "labelle-assembler: backend '{s}' ships only the legacy {s} at '{s}'; generating needs {s} " ++
            "(the v1 codegen path is gone).", .{ name, manifest_splice.LEGACY_MANIFEST_NAME, pkg_dir, manifest_v2.V2_MANIFEST_NAME }) };
        return v;
    }

    // The v2 build-graph manifest, parsed.
    const m = manifest_v2.loadNamedManifest(arena, cfg, game_dir, manifest_v2.V2_MANIFEST_NAME) catch |err| {
        v.problem = .{ .err = err, .message = try std.fmt.allocPrint(arena, "labelle-assembler: backend '{s}': {s} at '{s}' could not be read ({s}).", .{ name, manifest_v2.V2_MANIFEST_NAME, pkg_dir, @errorName(err) }) };
        return v;
    };
    v.manifest_loaded = true;

    // 4. Provider contracts.
    if (try contractProblem(arena, cfg, .{
        .manifest_id = m.id,
        .declared = m.capabilities,
        .declares_privileged = m.declaresPrivilegedLifecycle(),
        .post_fx = m.post_fx_passes,
    }, opts)) |p| {
        v.problem = p;
        return v;
    }
    v.id = m.id orelse if (cfg.backend_package == null)
        try std.fmt.allocPrint(arena, "labelle.{s}", .{name})
    else
        null;

    // 5. Editor preview needs the v2 wasm link path.
    if (cfg.editor_preview and m.platforms.wasm == null) {
        v.problem = try editorPreviewProblem(arena, name);
        return v;
    }

    // The declared build hook is staged into every target
    // (`stageBackendBuildHook` reads it), the tests target included.
    if (m.build_hook) |hook_rel| {
        const hook_path = try std.fs.path.join(arena, &.{ pkg_dir, hook_rel });
        if (!exists(hook_path)) {
            v.problem = .{ .err = error.FileNotFound, .message = try std.fmt.allocPrint(arena, "labelle-assembler: backend '{s}' declares `.build_hook = \"{s}\"` but the package has no such file ('{s}').", .{ name, hook_rel, hook_path }) };
            return v;
        }
    }

    if (opts.is_tests_target) return v;

    // 7. The platform entry and what codegen reads from it.
    const entry = manifest_v2_splice.platformEntry(m, cfg.platform) orelse {
        v.problem = .{ .err = error.V2PlatformUnsupported, .message = try std.fmt.allocPrint(arena, "labelle: v2 backend '{s}' declares no `.platforms.{s}` entry — the platform is unsupported by this backend.", .{ name, @tagName(cfg.platform) }) };
        return v;
    };
    // The entry template `templates.loadBackendTemplate` reads.
    const tmpl_path = try std.fs.path.join(arena, &.{ pkg_dir, entry.entry });
    if (!exists(tmpl_path)) {
        v.problem = .{ .err = error.TemplateNotFound, .message = try std.fmt.allocPrint(arena, "labelle: could not read v2 entry template '{s}': FileNotFound", .{tmpl_path}) };
        return v;
    }
    // `emitRootBuildDepsV2`: `.builtin` resolves only `emsdk`.
    for (entry.root_build_deps) |dep| {
        if (dep.resolution == .builtin and !std.mem.eql(u8, dep.name, "emsdk")) {
            v.problem = .{ .err = error.UnknownBuiltinRootDep, .message = try std.fmt.allocPrint(arena, "labelle-assembler: backend '{s}' declares root build dep '{s}' with `.resolution = .builtin`, " ++
                "but the only builtin root dep is 'emsdk'.", .{ name, dep.name }) };
            return v;
        }
    }
    if (callbackBackendUnsupported(cfg, entry.loop_style, entry.lifecycle != null)) {
        v.problem = .{ .err = error.ExternalCallbackBackendUnsupported, .message = try std.fmt.allocPrint(arena, "labelle-assembler: external backend '{s}' declares a callback run-loop " ++
            "(loop_style = .callback) but does NOT declare its lifecycle blocks — " ++
            "add `.platforms.<platform>.lifecycle` to its backend.manifest.v2.zon so " ++
            "codegen knows which callback blocks its entry template consumes " ++
            "(assembler#501). Loop-style external backends need no such declaration.", .{name}) };
        return v;
    }
    return v;
}

/// The callback rule of `codegen/lifecycle/render.zig`: a callback-style
/// external backend is only renderable when it declares its lifecycle
/// blocks, or is a first-party (enum-tag-backed) backend on wasm, where the
/// generic emscripten path applies.
pub fn callbackBackendUnsupported(
    cfg: ProjectConfig,
    loop_style: manifest_v2.BackendManifestV2.PlatformEntry.LoopStyle,
    declares_lifecycle: bool,
) bool {
    const handled = declares_lifecycle or (cfg.platform == .wasm and cfg.isEnumTagBacked());
    return loop_style == .callback and cfg.isExternal() and !handled;
}

/// Version floors as a `Problem` (compile breaks) plus, when
/// `emit_warnings`, the curated-floor warnings `version_floors.enforce` logs.
pub fn floorProblem(arena: std.mem.Allocator, cfg: ProjectConfig, emit_warnings: bool) !?Problem {
    const ctx = "labelle-assembler generate";
    const fv = version_floors.verdict(cfg) catch |err| {
        return .{ .err = err, .message = try std.fmt.allocPrint(arena, "{s}: a version pin in project.labelle is not a semantic version ({s})", .{ ctx, @errorName(err) }) };
    };
    if (!fv.refused()) {
        if (emit_warnings) {
            if (fv.backend) |b| {
                var buf: [512]u8 = undefined;
                std.log.warn("{s}: {s}", .{ ctx, b.describe(&buf) });
            }
            if (fv.trio) |t| {
                var buf: [1024]u8 = undefined;
                std.log.warn("{s}: {s}", .{ ctx, t.describe(&buf) });
            }
        }
        return null;
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    if (fv.backend) |b| {
        var buf: [512]u8 = undefined;
        try out.writer.print("{s}: {s}", .{ ctx, b.describe(&buf) });
    }
    if (fv.trio) |t| {
        var buf: [1024]u8 = undefined;
        if (out.written().len != 0) try out.writer.writeAll("\n");
        try out.writer.print("{s}: {s}", .{ ctx, t.describe(&buf) });
    }
    return .{ .err = error.VersionFloorViolation, .message = out.written() };
}

fn editorPreviewProblem(arena: std.mem.Allocator, name: []const u8) !Problem {
    return .{ .err = error.EditorPreviewUnsupportedByBackend, .message = try std.fmt.allocPrint(arena, "labelle-assembler: editor-preview build requested (LABELLE_EDITOR_PREVIEW) but " ++
        "backend '{s}' does not take the manifest-v2 wasm build path — only the v2 wasm " ++
        "backend hook (post_wire) can thread the editor_* exports into the emcc link. " ++
        "Upgrade the backend package (labelle-bgfx >= 0.6.1) or build without editor preview", .{name}) };
}

fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(config.globalIo(), path, .{}) catch return false;
    return true;
}

/// The identity/capability slice of a resolved manifest (v2 or legacy).
const ContractInput = struct {
    manifest_id: ?[]const u8,
    declared: []const config.Capability,
    declares_privileged: bool,
    post_fx: ?[]const config.PostFxKind,
};

/// The provider contracts, as a `Problem`: lifecycle privilege, identity,
/// id collision, then capability negotiation (not for the tests target).
fn contractProblem(arena: std.mem.Allocator, cfg: ProjectConfig, in: ContractInput, opts: CheckOptions) !?Problem {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    backend_registry.checkLifecyclePrivilege(cfg, in.declares_privileged, in.manifest_id, w) catch |err|
        return .{ .err = err, .message = out.written() };

    if (in.manifest_id) |id| {
        backend_registry.checkProviderIdentity(cfg, id, w) catch |err|
            return .{ .err = err, .message = out.written() };
        backend_registry.findProviderIdCollision(&.{id}, w) catch |err|
            return .{ .err = err, .message = out.written() };
    } else if (opts.emit_warnings) {
        // The missing-id warning (an external provider), exactly as generate logs it.
        backend_registry.validateProviderIdentity(cfg, null) catch {};
    }

    if (opts.is_tests_target) return null;
    const required = try capabilities.requiredCapabilities(arena, cfg);
    const provider_id = in.manifest_id orelse cfg.backendName();
    if (try capabilities.missingMessage(arena, required, in.declared, provider_id)) |msg|
        return .{ .err = error.UnsupportedCapability, .message = msg };
    if (opts.emit_warnings) {
        // Back-compat warnings for a provider declaring no capabilities, and
        // the post-fx notes: `validate` passes here and only logs.
        capabilities.validate(required, in.declared, provider_id) catch {};
        capabilities.warnUnsupportedPostFx(cfg.post_fx, in.post_fx, provider_id);
    }
    return null;
}

/// Resolve-time provider-contract checks (RFC "Opening the ecosystem",
/// §1616-1683): canonical provider identity, cross-provider id collision, and
/// capability negotiation, all read from the resolved backend's
/// `backend.manifest.zon` BEFORE the build graph is emitted.
///
/// Reads the identity/capability slice via `loadProviderManifest`, which is
/// DECOUPLED from the desktop-only splice gate (`manifestPathEnabled`) — these
/// checks apply on every target (android/wasm/ios included). A provider that
/// ships no manifest yields a null slice: identity is derived, capabilities are
/// un-enforced (the back-compat path).
/// `is_tests_target` scopes the CAPABILITY gate OUT for the tests target
/// (issue #83): that target force-substitutes `cfg.backend = .null` as a
/// headless test HARNESS while keeping the rest of the project config (e.g.
/// `resolved_gui = imgui`), so `requiredCapabilities(cfg)` still derives the
/// REAL backend's needs (`.raw_gui_adapter`, …). The forced-null harness never
/// builds the real GUI/gamepad, so requiring it to satisfy those capabilities
/// is wrong — and now that null ships a v2 manifest declaring only `.headless`,
/// the opted-in gate would hard-fail `zig build test` for any GUI/gamepad
/// project. Identity + id-collision checks stay ON for the tests target (cheap
/// and still valid); only the capability REQUIREMENT check is skipped. The real
/// exe target (`is_tests_target = false`) is unaffected — a GUI project whose
/// chosen backend lacks `.raw_gui_adapter` must still fail.
pub fn validateProviderContracts(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    game_dir: []const u8,
    backend_manifest_name: ?[]const u8,
    is_tests_target: bool,
) !void {
    // ── manifest-v2 cutover (epic #453, closes #472 P2 finding 2) ──────
    // When `generate` auto-detected a v2 manifest, the provider identity +
    // capabilities live in the v2 `.id`/`.capabilities`. Read them off the v2
    // manifest and run the SAME contract checks. `backend_manifest_name` is null
    // when the package ships no v2 manifest, in which case the legacy provider
    // identity/capabilities slice (`loadProviderManifest`) is read below.
    if (backend_manifest_name) |name| {
        const m = try manifest_v2.loadNamedManifest(allocator, cfg, game_dir, name);
        defer std.zon.parse.free(allocator, m);
        // Privileged lifecycle blocks (sokol readback / bgfx shell) are reserved
        // to the `labelle.*` namespace (#461) — checked here, where the parsed
        // manifest's platforms are in scope.
        return validateProviderContractsInner(allocator, cfg, m.id, m.capabilities, m.declaresPrivilegedLifecycle(), m.post_fx_passes, is_tests_target);
    }

    const maybe_pm = try manifest_splice.loadProviderManifest(allocator, cfg, game_dir);
    const manifest_id: ?[]const u8 = if (maybe_pm) |pm| pm.id else null;
    const declared: []const config.Capability = if (maybe_pm) |pm| pm.capabilities else &.{};
    // Post-fx passes the backend advertises — OPTIONAL: null = no manifest, or an
    // older manifest with no `.post_fx_passes` field, in which case the resolve-
    // time check skips silently. See `capabilities.warnUnsupportedPostFx`.
    const backend_post_fx: ?[]const config.PostFxKind = if (maybe_pm) |pm| pm.post_fx_passes else null;
    defer if (maybe_pm) |pm| manifest_splice.freeProviderManifest(allocator, pm);

    return validateProviderContractsInner(allocator, cfg, manifest_id, declared, false, backend_post_fx, is_tests_target);
}

/// Run `contractProblem` and report its problem the way these checks
/// always have (`std.debug.print`), for the `validateProviderContracts`
/// entry point.
fn validateProviderContractsInner(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    manifest_id: ?[]const u8,
    declared: []const config.Capability,
    declares_privileged: bool,
    backend_post_fx: ?[]const config.PostFxKind,
    is_tests_target: bool,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const p = (try contractProblem(arena_state.allocator(), cfg, .{
        .manifest_id = manifest_id,
        .declared = declared,
        .declares_privileged = declares_privileged,
        .post_fx = backend_post_fx,
    }, .{ .is_tests_target = is_tests_target })) orelse return;
    std.debug.print("{s}\n", .{p.message});
    return p.err;
}
