//! capabilities — the resolve-time capability-negotiation seam for the
//! pluggable-backends epic (#386, ecosystem-hardening #453; RFC "Opening the
//! ecosystem — Capability negotiation", §1645-1683).
//!
//! `@hasDecl`-gating answers "*can the backend's code call this?*" at comptime,
//! but the project author hits that as a DEEP compile error in generated
//! `main.zig`, long after the wrong provider was chosen. This module moves the
//! check FORWARD to resolve time with a project-level diagnostic:
//!
//!   1. `requiredCapabilities(cfg)` — the set the project needs, DERIVED from
//!      its platform / GUI / asset-compression selection PLUS the explicit
//!      `cfg.requires`.
//!   2. `validate(required, declared, provider_id)` — checks the required set
//!      against the resolved provider's DECLARED `.capabilities` and produces a
//!      readable project-level error naming the missing capability + provider.
//!
//! Back-compat gate: enforcement is OPT-IN. A provider that declares a
//! non-empty `.capabilities` set has its capabilities enforced (a missing
//! required capability is a hard error). A provider that declares NONE (an
//! old manifest that predates this field, or a built-in shipping no manifest)
//! is only WARNED about — never failed — so existing projects keep generating.
//! Required-capability enforcement becomes unconditional in a later release.

const std = @import("std");
const config = @import("config.zig");

const Capability = config.Capability;
const ProjectConfig = config.ProjectConfig;

/// The capabilities this project REQUIRES of its resolved backend provider.
///
/// Derived from the project selection, then unioned with the explicit
/// `cfg.requires`:
///   - `.platform = .android` ⇒ `.android` + `.surface_loss` (mobile GPU
///     surface destroy/recreate — RFC §1669).
///   - `.platform = .wasm`    ⇒ `.wasm`.
///   - `.platform = .ios`     ⇒ `.ios`.
///   - ASTC selected for the target platform (`asset_compression`) ⇒
///     `.compressed_textures` (the GPU-native upload path — #340).
///   - a resolved GUI plugin rendering in `raw_backend` mode AND satisfied by
///     the backend's OWN in-backend imgui adapter (no GUI bridge resolved for
///     this backend — `bridge_dir == null`) ⇒ `.raw_gui_adapter` (RFC Q#6). A
///     `raw_backend` GUI that a separate GUI-bridge plugin renders for this
///     backend (raylib → rlImGui; `bridge_dir != null`) does NOT require it —
///     the bridge, not the backend, supplies the adapter. This mirrors the
///     bridge-vs-in-backend split the codegen already makes in `build_files`
///     (`rendering == .raw_backend and bridge_dir != null` ⇒ wire the bridge).
///   - every capability in `cfg.requires` (the explicit half).
///
/// NOTE (deferred): a `--screenshot` run requires `.screenshots` (RFC §1671),
/// but that need is a CLI-flag/target concern not modeled on `ProjectConfig`
/// today, so it is surfaced ONLY via an explicit `.requires = &.{ .screenshots }`
/// until a screenshot target field exists. Documented rather than guessed.
///
/// Returns a de-duplicated, allocator-owned slice; caller frees it.
pub fn requiredCapabilities(allocator: std.mem.Allocator, cfg: ProjectConfig) ![]Capability {
    var set: std.ArrayList(Capability) = .empty;
    errdefer set.deinit(allocator);

    const add = struct {
        fn f(a: std.mem.Allocator, list: *std.ArrayList(Capability), cap: Capability) !void {
            for (list.items) |existing| {
                if (existing == cap) return; // de-dup
            }
            try list.append(a, cap);
        }
    }.f;

    switch (cfg.platform) {
        .android => {
            try add(allocator, &set, .android);
            try add(allocator, &set, .surface_loss);
        },
        .wasm => try add(allocator, &set, .wasm),
        .ios => try add(allocator, &set, .ios),
        .desktop => {},
    }

    if (cfg.asset_compression.formatFor(cfg.platform) == .astc) {
        try add(allocator, &set, .compressed_textures);
    }

    if (cfg.resolved_gui) |gui| {
        // Only the IN-BACKEND-adapter path requires the backend to declare
        // `.raw_gui_adapter`. A `raw_backend` GUI whose rendering is handled by
        // a resolved GUI-bridge plugin for this backend (raylib → rlImGui;
        // `bridge_dir != null`) is satisfied by the BRIDGE, not the backend, so
        // it must NOT require the capability — otherwise raylib (which has no
        // in-backend adapter and correctly omits `.raw_gui_adapter`) fails the
        // gate for every imgui project. `bridge_dir == null` on a `raw_backend`
        // GUI means no bridge was resolved for this backend, i.e. the backend's
        // own in-backend adapter renders it (sokol/bgfx) — that DOES require it.
        if (gui.rendering == .raw_backend and gui.bridge_dir == null)
            try add(allocator, &set, .raw_gui_adapter);
    }

    for (cfg.requires) |cap| try add(allocator, &set, cap);

    return set.toOwnedSlice(allocator);
}

/// True if `cap` is in `declared`.
fn declares(declared: []const Capability, cap: Capability) bool {
    for (declared) |d| {
        if (d == cap) return true;
    }
    return false;
}

/// Check a project's `required` capabilities against a resolved provider's
/// `declared` set. `provider_id` names the provider in diagnostics (e.g.
/// `labelle.sokol`).
///
/// Back-compat gate:
///   - `declared.len == 0` — the provider ships no `.capabilities` (old
///     manifest, or a built-in with no manifest). Any missing required
///     capability is only WARNED, never failed. Returns ok.
///   - `declared.len > 0` — the provider OPTED IN. A missing required
///     capability is a hard `error.UnsupportedCapability`.
pub fn validate(
    required: []const Capability,
    declared: []const Capability,
    provider_id: []const u8,
) error{UnsupportedCapability}!void {
    // Collect the missing set (required but not declared).
    var missing_buf: [@typeInfo(Capability).@"enum".fields.len]Capability = undefined;
    var missing_len: usize = 0;
    for (required) |cap| {
        if (!declares(declared, cap)) {
            missing_buf[missing_len] = cap;
            missing_len += 1;
        }
    }
    if (missing_len == 0) return; // provider satisfies everything required

    const missing = missing_buf[0..missing_len];

    if (declared.len == 0) {
        // Back-compat: provider predates capability declarations. Warn, don't
        // fail — enforcement is opt-in until every provider declares a set.
        for (missing) |cap| {
            std.log.warn(
                "labelle-assembler: backend provider '{s}' declares no capabilities, so the project's required capability '{s}' cannot be verified (declare a `.capabilities` set in the provider's backend.manifest.zon to enable this check).",
                .{ provider_id, @tagName(cap) },
            );
        }
        return;
    }

    // Opted-in provider is missing a required capability — hard error with a
    // project-level diagnostic (RFC §1674), NOT a deep `@compileError`.
    // `std.debug.print` (not `std.log.err`) matches the existing manifest-
    // validation diagnostics and keeps the test runner from flagging the
    // intentional error-path tests as failures.
    for (missing) |cap| {
        std.debug.print(
            "labelle-assembler: backend provider '{s}' does not support capability '{s}' required by this project.\n  Choose a provider that advertises '{s}', or remove the requirement.\n",
            .{ provider_id, @tagName(cap), @tagName(cap) },
        );
    }
    return error.UnsupportedCapability;
}

/// Assert a resolved provider's DECLARED `.surface_loss` capability agrees with
/// whether its window backend ACTUALLY implements the surface-loss hooks. This
/// is the manifest<->decl consistency half that `validate` (required-vs-
/// declared) does NOT cover.
///
/// The `.surface_loss` manifest bit is the DECLARATIVE MIRROR of the
/// `@hasDecl`-gated `surfaceLost`/`surfaceRestored` window-contract hooks (see
/// labelle-core `window_contract.supportsSurfaceLoss` — "declares BOTH hooks",
/// #53). `supports` is that probe: pass the backend's
/// `core.Window(WindowImpl).supportsSurfaceLoss()` (equivalently
/// `@hasDecl(WindowImpl, "surfaceLost") and @hasDecl(WindowImpl,
/// "surfaceRestored")`). A drifted mirror silently mis-routes the resolve-time
/// gate, so — mirroring the way labelle-core's conformance suite asserts
/// probe-truthfulness on the backend side — this asserts it on the ASSEMBLER
/// side against the manifest.
///
/// DIRECTIONAL, both ways (the "and vice-versa"):
///   - declares `.surface_loss` but the hooks are ABSENT → the manifest
///     advertises a capability the backend can't back. An android project's
///     derived `.surface_loss` requirement would `validate` cleanly against
///     this manifest, then the backend no-ops the surface at runtime — a black
///     screen after resume, NOT a build-time error.
///   - hooks PRESENT but `.surface_loss` OMITTED → under-advertised. An android
///     project's derived `.surface_loss` requirement spuriously fails the
///     `validate` gate against a backend that actually supports surface loss.
///
/// Back-compat: a provider that declares NO capabilities at all
/// (`declared.len == 0`, a pre-capability manifest) is exempt — same opt-in
/// gate as `validate`; we only cross-check a provider that has OPTED IN to the
/// capability vocabulary. `supports` is comptime-known at the call site (it is
/// `@hasDecl`-derived), so this reads as a directional assert; the diagnostic
/// mirrors `validate`'s `std.debug.print` (not `std.log.err`) so the intentional
/// error-path test does not read as a runner failure.
pub fn validateSurfaceLossConsistency(
    supports_surface_loss: bool,
    declared: []const Capability,
    provider_id: []const u8,
) error{SurfaceLossManifestMismatch}!void {
    if (declared.len == 0) return; // opted out of the capability vocabulary — see validate.

    const declares_cap = declares(declared, .surface_loss);
    if (declares_cap == supports_surface_loss) return; // mirror agrees with the hooks.

    if (declares_cap) {
        std.debug.print(
            "labelle-assembler: backend provider '{s}' declares the '.surface_loss' capability but its window backend does not implement the surfaceLost/surfaceRestored hooks.\n  Either implement both hooks (labelle-core window contract) or drop '.surface_loss' from the provider's backend.manifest.zon `.capabilities`.\n",
            .{provider_id},
        );
    } else {
        std.debug.print(
            "labelle-assembler: backend provider '{s}' implements the surfaceLost/surfaceRestored hooks but its manifest omits the '.surface_loss' capability.\n  Add '.surface_loss' to the provider's backend.manifest.zon `.capabilities` so the resolve-time gate can advertise it.\n",
            .{provider_id},
        );
    }
    return error.SurfaceLossManifestMismatch;
}

/// Outcome of the resolve-time post-fx capability check — the testable core of
/// `warnUnsupportedPostFx`, split out so the behavior can be asserted directly
/// without capturing `std.log` output.
pub const PostFxReport = struct {
    /// The backend manifest ships NO `.post_fx_passes` field (null) — we can't
    /// know what it implements, so the check is a silent no-op.
    skipped: bool = false,
    /// The backend advertises the field but implements NONE (`.{}`) while the
    /// project declares at least one pass — the ENTIRE stack no-ops at runtime.
    whole_stack_inert: bool = false,
    /// Distinct declared pass-kinds the backend does not implement (a slice into
    /// the caller-provided buffer; de-duplicated so a kind declared twice warns
    /// once). Empty when everything declared is supported.
    unsupported: []const config.PostFxKind = &.{},

    /// True when nothing needs reporting (supported, empty, or skipped).
    pub fn isClean(self: PostFxReport) bool {
        return !self.whole_stack_inert and self.unsupported.len == 0;
    }
};

/// Pure core of the post-fx capability check (labelle-gfx#305 Phase 3, RFC §4).
/// Compares the project's declared `.post_fx` passes against the backend's
/// advertised `.post_fx_passes` and reports what the runtime would silently skip.
///
/// `backend_post_fx` mirrors the manifest field's OPTIONAL shape:
///   - `null`    — no `.post_fx_passes` field (older backend / predates it):
///     unknown ⇒ `skipped` (never false-warn).
///   - `.{}`     — advertises the field but implements NONE: `whole_stack_inert`.
///   - non-empty — each declared kind absent from the set lands in `unsupported`.
///
/// De-duplicates by kind into `unsupported_buf` (size ≥ the number of
/// `PostFxKind` variants covers any input, since results are per-KIND).
pub fn checkPostFx(
    declared_passes: []const config.PostFxPass,
    backend_post_fx: ?[]const config.PostFxKind,
    unsupported_buf: []config.PostFxKind,
) PostFxReport {
    // Older backend: no `.post_fx_passes` field → unknown, skip silently.
    const supported = backend_post_fx orelse return .{ .skipped = true };
    if (declared_passes.len == 0) return .{}; // nothing declared → nothing to check.

    // Whole stack inert: the backend advertises the field but implements NONE.
    if (supported.len == 0) return .{ .whole_stack_inert = true };

    var n: usize = 0;
    outer: for (declared_passes) |pass| {
        const kind = std.meta.activeTag(pass);
        if (postFxSupported(supported, kind)) continue;
        // De-dup: a kind declared twice is reported once.
        for (unsupported_buf[0..n]) |seen| {
            if (seen == kind) continue :outer;
        }
        if (n == unsupported_buf.len) break; // full (unreachable at max width) — truncate.
        unsupported_buf[n] = kind;
        n += 1;
    }
    return .{ .unsupported = unsupported_buf[0..n] };
}

/// Resolve-time POST-FX capability check (labelle-gfx#305 Phase 3, RFC §4 —
/// the `.capabilities` manifest mirror). Cross-checks the project's declared
/// `.post_fx` passes against the resolved backend's advertised
/// `.post_fx_passes` and WARNS (never fails) about a pass the backend cannot do,
/// so the author learns at BUILD time instead of a silent per-frame runtime skip.
///
/// WARN-not-error is deliberate: the runtime degrades gracefully
/// (`postPassSupported` no-ops an unimplemented pass), so a declared-but-
/// unsupported pass must not break the build — it warns. See `checkPostFx` for
/// the OPTIONAL manifest-field semantics (null skips silently; `.{}` is a louder
/// whole-stack-inert warning).
pub fn warnUnsupportedPostFx(
    declared_passes: []const config.PostFxPass,
    backend_post_fx: ?[]const config.PostFxKind,
    provider_id: []const u8,
) void {
    var unsupported_buf: [@typeInfo(config.PostFxKind).@"enum".fields.len]config.PostFxKind = undefined;
    const report = checkPostFx(declared_passes, backend_post_fx, &unsupported_buf);
    if (report.skipped or report.isClean()) return;

    // Whole stack inert: one louder warning is clearer than one per pass —
    // EVERY declared pass will no-op at runtime on this backend.
    if (report.whole_stack_inert) {
        std.log.warn(
            "labelle-assembler: project.labelle .post_fx declares {d} pass(es) but the '{s}' backend implements NO post-fx passes — the entire post-fx stack will be skipped at runtime.",
            .{ declared_passes.len, provider_id },
        );
        return;
    }

    var list_buf: [128]u8 = undefined;
    const supported_list = formatKindList(&list_buf, backend_post_fx.?);
    for (report.unsupported) |kind| {
        std.log.warn(
            "labelle-assembler: project.labelle .post_fx declares '{s}' but the '{s}' backend does not implement it — it will be skipped at runtime. Supported: {s}.",
            .{ @tagName(kind), provider_id, supported_list },
        );
    }
}

/// True if `kind` is in the backend's advertised `.post_fx_passes` set.
fn postFxSupported(supported: []const config.PostFxKind, kind: config.PostFxKind) bool {
    for (supported) |s| {
        if (s == kind) return true;
    }
    return false;
}

/// Render an advertised post-fx set as a comma-joined tag list into `buf`
/// (allocation-free — the kind set is tiny and the names are short). Truncates
/// rather than overflowing if the buffer is ever too small.
fn formatKindList(buf: []u8, kinds: []const config.PostFxKind) []const u8 {
    var len: usize = 0;
    for (kinds, 0..) |k, i| {
        const sep: []const u8 = if (i == 0) "" else ", ";
        const name = @tagName(k);
        if (len + sep.len + name.len > buf.len) break; // truncate, never overflow.
        @memcpy(buf[len..][0..sep.len], sep);
        len += sep.len;
        @memcpy(buf[len..][0..name.len], name);
        len += name.len;
    }
    return buf[0..len];
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "requiredCapabilities: a plain desktop project requires nothing" {
    const cfg = ProjectConfig{ .name = "g", .platform = .desktop };
    const req = try requiredCapabilities(testing.allocator, cfg);
    defer testing.allocator.free(req);
    try testing.expectEqual(@as(usize, 0), req.len);
}

test "requiredCapabilities: android derives .android + .surface_loss" {
    const cfg = ProjectConfig{ .name = "g", .platform = .android };
    const req = try requiredCapabilities(testing.allocator, cfg);
    defer testing.allocator.free(req);
    try testing.expect(hasCap(req, .android));
    try testing.expect(hasCap(req, .surface_loss));
}

test "requiredCapabilities: wasm derives .wasm, ios derives .ios" {
    {
        const cfg = ProjectConfig{ .name = "g", .platform = .wasm };
        const req = try requiredCapabilities(testing.allocator, cfg);
        defer testing.allocator.free(req);
        try testing.expect(hasCap(req, .wasm));
    }
    {
        const cfg = ProjectConfig{ .name = "g", .platform = .ios };
        const req = try requiredCapabilities(testing.allocator, cfg);
        defer testing.allocator.free(req);
        try testing.expect(hasCap(req, .ios));
    }
}

test "requiredCapabilities: ASTC selection derives .compressed_textures" {
    const cfg = ProjectConfig{
        .name = "g",
        .platform = .android,
        .asset_compression = .{ .android = .astc },
    };
    const req = try requiredCapabilities(testing.allocator, cfg);
    defer testing.allocator.free(req);
    try testing.expect(hasCap(req, .compressed_textures));
}

test "requiredCapabilities: a raw_backend GUI on the in-backend adapter (no bridge) derives .raw_gui_adapter" {
    // sokol/bgfx render imgui through their OWN in-backend adapter — no
    // GUI-bridge plugin is resolved for the backend, so `bridge_dir == null`.
    // That path DOES require the backend to declare `.raw_gui_adapter`.
    const cfg = ProjectConfig{
        .name = "g",
        .backend = .sokol,
        .resolved_gui = .{
            .name = "imgui",
            .rendering = .raw_backend,
            .plugin_dir = "x",
            .bridge_dir = null, // in-backend adapter — no separate bridge plugin
        },
    };
    const req = try requiredCapabilities(testing.allocator, cfg);
    defer testing.allocator.free(req);
    try testing.expect(hasCap(req, .raw_gui_adapter));
}

test "requiredCapabilities: a raw_backend GUI rendered by a bridge (raylib/rlImGui) does NOT derive .raw_gui_adapter" {
    // Regression for the raylib→v2 cutover gamepad failure (#477): raylib
    // renders imgui via the rlImGui BRIDGE (a separate plugin the assembler
    // wires — `bridge_dir` is set), NOT an in-backend raw adapter. raylib
    // legitimately omits `.raw_gui_adapter`, so deriving it here made every
    // raylib+imgui project fail the capability gate with UnsupportedCapability.
    const cfg = ProjectConfig{
        .name = "g",
        .backend = .raylib,
        .resolved_gui = .{
            .name = "imgui",
            .rendering = .raw_backend,
            .plugin_dir = "x",
            .bridge_dir = "/abs/plugins/imgui/bridges/raylib", // bridge resolved
            .bridge_artifact = "rlimgui_bridge",
        },
    };
    const req = try requiredCapabilities(testing.allocator, cfg);
    defer testing.allocator.free(req);
    // The bridge supplies the adapter — the backend must NOT be required to.
    try testing.expect(!hasCap(req, .raw_gui_adapter));
}

test "capability gate end-to-end: raylib+imgui (bridge) generates; sokol/bgfx+imgui (in-backend) still gated" {
    // Prove BOTH directions against the real backend-manifest capability sets:
    //   raylib_v2 declares NO `.raw_gui_adapter` (bridge case) — must pass.
    //   sokol/bgfx declare it (in-backend case) — the requirement is derived,
    //   and a manifest that omitted it would fail.
    const raylib_declared: []const Capability = &.{
        .screenshots, .compressed_textures, .fonts, .gamepad_polling, .wasm, .audio_ogg,
    };
    const in_backend_declared: []const Capability = &.{
        .screenshots, .compressed_textures, .fonts, .gamepad_polling, .raw_gui_adapter, .surface_loss,
    };

    // raylib + imgui via the rlImGui bridge — this is the #477 gamepad scenario
    // (raylib backend + imgui GUI, exe target). Must NOT require .raw_gui_adapter
    // and must validate cleanly against raylib's (adapter-less) declared set.
    {
        const cfg = ProjectConfig{
            .name = "example_gamepad",
            .backend = .raylib,
            .resolved_gui = .{
                .name = "imgui",
                .rendering = .raw_backend,
                .plugin_dir = "x",
                .bridge_dir = "/abs/plugins/imgui/bridges/raylib",
                .bridge_artifact = "rlimgui_bridge",
            },
        };
        const req = try requiredCapabilities(testing.allocator, cfg);
        defer testing.allocator.free(req);
        try testing.expect(!hasCap(req, .raw_gui_adapter));
        // No UnsupportedCapability against the real raylib manifest.
        try validate(req, raylib_declared, "labelle.raylib");
    }

    // sokol/bgfx + imgui via the in-backend adapter (no bridge) — STILL requires
    // .raw_gui_adapter; passes when the manifest declares it, fails when omitted.
    {
        const cfg = ProjectConfig{
            .name = "example_sokol_imgui",
            .backend = .sokol,
            .resolved_gui = .{
                .name = "imgui",
                .rendering = .raw_backend,
                .plugin_dir = "x",
                .bridge_dir = null,
            },
        };
        const req = try requiredCapabilities(testing.allocator, cfg);
        defer testing.allocator.free(req);
        try testing.expect(hasCap(req, .raw_gui_adapter));
        // Declared → validates. Omitted → hard UnsupportedCapability.
        try validate(req, in_backend_declared, "labelle.sokol");
        try testing.expectError(error.UnsupportedCapability, validate(
            req,
            &.{ .screenshots, .gamepad_polling }, // opted-in but omits .raw_gui_adapter
            "labelle.sokol",
        ));
    }
}

test "requiredCapabilities: explicit .requires are unioned in and de-duped" {
    const cfg = ProjectConfig{
        .name = "g",
        .platform = .android,
        // .android is already derived — declaring it again must not duplicate.
        .requires = &.{ .screenshots, .android },
    };
    const req = try requiredCapabilities(testing.allocator, cfg);
    defer testing.allocator.free(req);
    try testing.expect(hasCap(req, .screenshots));
    // .android appears exactly once despite being both derived and explicit.
    var android_count: usize = 0;
    for (req) |c| {
        if (c == .android) android_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), android_count);
}

test "validate: a satisfied requirement set is accepted" {
    try validate(
        &.{ .screenshots, .android },
        &.{ .screenshots, .android, .surface_loss },
        "labelle.sokol",
    );
}

test "validate: a missing capability against an opted-in provider is a hard error" {
    try testing.expectError(error.UnsupportedCapability, validate(
        &.{.screenshots},
        &.{ .android, .surface_loss }, // declares SOMETHING but not screenshots
        "labelle.bgfx",
    ));
}

test "validate: back-compat — a provider declaring NO capabilities only warns" {
    // declared.len == 0 ⇒ the requirement can't be verified, but we don't fail
    // (old manifest / no-manifest built-in). Must return ok.
    try validate(&.{.screenshots}, &.{}, "labelle.legacy");
}

test "validate: no requirements is trivially ok even with no declarations" {
    try validate(&.{}, &.{}, "labelle.whatever");
}

test "validateSurfaceLossConsistency: manifest bit and hooks agree (both present)" {
    // A backend that implements the hooks (supports == true) AND advertises
    // `.surface_loss` is consistent — e.g. the bgfx/sokol mobile backends.
    try validateSurfaceLossConsistency(
        true,
        &.{ .surface_loss, .screenshots },
        "labelle.bgfx",
    );
}

test "validateSurfaceLossConsistency: manifest bit and hooks agree (both absent)" {
    // A desktop-only backend implements NO hooks (supports == false) and omits
    // `.surface_loss` — also consistent (the both-or-neither shape).
    try validateSurfaceLossConsistency(
        false,
        &.{ .screenshots, .fonts },
        "labelle.raylib",
    );
}

test "validateSurfaceLossConsistency: over-advertised — manifest declares .surface_loss but no hooks errors" {
    // Directional half 1: the manifest is a lie the resolver would trust — an
    // android project's derived `.surface_loss` requirement would `validate`
    // cleanly, then the backend no-ops the surface at runtime. Hard error.
    // (The `std.debug.print` diagnostic here is the intentional negative-test
    // log, not a runner failure — same discipline as the `validate` tests.)
    try testing.expectError(error.SurfaceLossManifestMismatch, validateSurfaceLossConsistency(
        false,
        &.{ .surface_loss, .screenshots },
        "labelle.bgfx",
    ));
}

test "validateSurfaceLossConsistency: under-advertised — hooks present but manifest omits .surface_loss errors" {
    // Directional half 2 (the "and vice-versa"): a backend that implements the
    // hooks but forgets the bit under-advertises, so an android project's
    // derived requirement spuriously fails the gate. Hard error.
    try testing.expectError(error.SurfaceLossManifestMismatch, validateSurfaceLossConsistency(
        true,
        &.{ .screenshots, .fonts },
        "labelle.sokol",
    ));
}

test "validateSurfaceLossConsistency: back-compat — a provider declaring NO capabilities is exempt" {
    // declared.len == 0 ⇒ pre-capability manifest / no-manifest built-in. Same
    // opt-in gate as `validate`: we only cross-check an opted-in provider, so a
    // hooks-implementing backend with an empty manifest must NOT error.
    try validateSurfaceLossConsistency(true, &.{}, "labelle.legacy");
    try validateSurfaceLossConsistency(false, &.{}, "labelle.legacy");
}

fn hasCap(caps: []const Capability, cap: Capability) bool {
    for (caps) |c| {
        if (c == cap) return true;
    }
    return false;
}

// ── Post-fx capability check (labelle-gfx#305 Phase 3) ────────────────

/// A stack buffer wide enough for any `checkPostFx` result (results are per
/// distinct KIND, so the enum-cardinality bound suffices).
fn postFxBuf() [@typeInfo(config.PostFxKind).@"enum".fields.len]config.PostFxKind {
    return undefined;
}

test "checkPostFx (a): declared bloom+crt against a backend advertising both — no warning" {
    const declared: []const config.PostFxPass = &.{
        .{ .bloom = .{ .threshold = 0.8 } },
        .{ .crt = .{ .curvature = 0.1 } },
    };
    const advertised: []const config.PostFxKind = &.{ .bloom, .vignette, .color_grade, .crt };
    var buf = postFxBuf();
    const report = checkPostFx(declared, advertised, &buf);
    try testing.expect(!report.skipped);
    try testing.expect(report.isClean());
    try testing.expectEqual(@as(usize, 0), report.unsupported.len);
}

test "checkPostFx (b): declared crt against a backend advertising only bloom — warns, names crt" {
    const declared: []const config.PostFxPass = &.{
        .{ .bloom = .{ .threshold = 0.8 } }, // supported
        .{ .crt = .{ .curvature = 0.1 } }, // NOT supported
    };
    const advertised: []const config.PostFxKind = &.{.bloom};
    var buf = postFxBuf();
    const report = checkPostFx(declared, advertised, &buf);
    try testing.expect(!report.isClean());
    try testing.expect(!report.whole_stack_inert);
    try testing.expectEqual(@as(usize, 1), report.unsupported.len);
    try testing.expectEqual(config.PostFxKind.crt, report.unsupported[0]);

    // The supported set is rendered for the diagnostic's "Supported: <list>" tail.
    var list_buf: [128]u8 = undefined;
    try testing.expectEqualStrings("bloom", formatKindList(&list_buf, advertised));
}

test "checkPostFx (c): a manifest with NO .post_fx_passes field — skipped, no warning" {
    const declared: []const config.PostFxPass = &.{
        .{ .crt = .{ .curvature = 0.1 } },
    };
    var buf = postFxBuf();
    const report = checkPostFx(declared, null, &buf); // null = field absent (older backend)
    try testing.expect(report.skipped);
    try testing.expect(report.isClean()); // skipped ⇒ nothing to warn about
}

test "checkPostFx: an empty advertised set (implements NONE) is whole-stack-inert" {
    const declared: []const config.PostFxPass = &.{
        .{ .bloom = .{} },
        .{ .vignette = .{} },
    };
    const advertised: []const config.PostFxKind = &.{}; // explicit empty = implements none
    var buf = postFxBuf();
    const report = checkPostFx(declared, advertised, &buf);
    try testing.expect(report.whole_stack_inert);
    try testing.expect(!report.isClean());
}

test "checkPostFx: no declared passes is trivially clean even when advertised is null" {
    var buf = postFxBuf();
    const report = checkPostFx(&.{}, null, &buf);
    try testing.expect(report.skipped); // null short-circuits first — still nothing to warn
    try testing.expect(report.isClean());
}

test "checkPostFx: a kind declared twice is reported once (de-dup)" {
    const declared: []const config.PostFxPass = &.{
        .{ .crt = .{} },
        .{ .crt = .{ .scanline = 0.5 } }, // same KIND, different params
    };
    const advertised: []const config.PostFxKind = &.{ .bloom, .vignette };
    var buf = postFxBuf();
    const report = checkPostFx(declared, advertised, &buf);
    try testing.expectEqual(@as(usize, 1), report.unsupported.len);
    try testing.expectEqual(config.PostFxKind.crt, report.unsupported[0]);
}

test "warnUnsupportedPostFx: the log wrapper is a no-op for the clean/skip paths" {
    // No assertion on log output — just exercise the wrapper across every arm to
    // prove it composes `checkPostFx` without tripping (the buffer-width bound,
    // the null skip, the inert path, and the per-kind path).
    warnUnsupportedPostFx(&.{}, null, "labelle.test"); // skip
    warnUnsupportedPostFx(&.{.{ .bloom = .{} }}, &.{.bloom}, "labelle.test"); // clean
    warnUnsupportedPostFx(&.{.{ .crt = .{} }}, &.{}, "labelle.test"); // inert (warns)
    warnUnsupportedPostFx(&.{.{ .crt = .{} }}, &.{.bloom}, "labelle.test"); // unsupported (warns)
}
