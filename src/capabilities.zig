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
///   - a resolved GUI plugin rendering in `raw_backend` mode ⇒
///     `.raw_gui_adapter` (the in-backend imgui adapter, RFC Q#6).
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
        if (gui.rendering == .raw_backend) try add(allocator, &set, .raw_gui_adapter);
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

test "requiredCapabilities: a raw_backend GUI derives .raw_gui_adapter" {
    const cfg = ProjectConfig{
        .name = "g",
        .resolved_gui = .{
            .name = "imgui",
            .rendering = .raw_backend,
            .plugin_dir = "x",
        },
    };
    const req = try requiredCapabilities(testing.allocator, cfg);
    defer testing.allocator.free(req);
    try testing.expect(hasCap(req, .raw_gui_adapter));
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

fn hasCap(caps: []const Capability, cap: Capability) bool {
    for (caps) |c| {
        if (c == cap) return true;
    }
    return false;
}
