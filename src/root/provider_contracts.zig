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

const ProjectConfig = config.ProjectConfig;

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
        try backend_registry.assertLifecyclePrivilege(cfg, m.declaresPrivilegedLifecycle(), m.id);
        return validateProviderContractsInner(allocator, cfg, m.id, m.capabilities, is_tests_target);
    }

    const maybe_pm = try manifest_splice.loadProviderManifest(allocator, cfg, game_dir);
    const manifest_id: ?[]const u8 = if (maybe_pm) |pm| pm.id else null;
    const declared: []const config.Capability = if (maybe_pm) |pm| pm.capabilities else &.{};
    defer if (maybe_pm) |pm| manifest_splice.freeProviderManifest(allocator, pm);

    return validateProviderContractsInner(allocator, cfg, manifest_id, declared, is_tests_target);
}

/// The identity + capability contract checks, factored out so BOTH the legacy
/// (v1 provider manifest) and the v2 (auto-detected build-graph manifest) paths
/// run the exact same negotiation against whichever `.id`/`.capabilities` the
/// resolved manifest carries.
fn validateProviderContractsInner(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    manifest_id: ?[]const u8,
    declared: []const config.Capability,
    is_tests_target: bool,
) !void {
    // Provider identity: reserved-namespace + enum-shorthand drift.
    try backend_registry.validateProviderIdentity(cfg, manifest_id);

    // Cross-provider id collision over the full resolved provider set. Today
    // that set is the single render backend, so this is future-proofing (the
    // one place the whole set is cross-checked); plugins/audio providers join
    // it once they carry identities.
    if (manifest_id) |id| {
        try backend_registry.checkProviderIdCollisions(&.{id});
    }

    // Capability negotiation. Enforcement is OPT-IN: a provider declaring a
    // non-empty `.capabilities` set has missing requirements fail hard; a
    // provider declaring none is only warned (back-compat gate in `validate`).
    //
    // SKIPPED for the tests target (issue #83): its `cfg.backend` was
    // force-substituted to `.null` (a headless test harness) while the rest of
    // the config still describes the REAL backend's needs, so validating the
    // null harness against the project's real-backend capabilities is wrong.
    // Identity + collision checks above stay ON (cheap + still valid). The real
    // exe target still enforces the gate.
    if (is_tests_target) return;
    const required = try capabilities.requiredCapabilities(allocator, cfg);
    defer allocator.free(required);
    const provider_id = manifest_id orelse cfg.backendName();
    try capabilities.validate(required, declared, provider_id);
}
