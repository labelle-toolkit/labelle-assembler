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
    return .{
        .name = name,
        .subpath = try std.fmt.allocPrint(allocator, "backends/{s}", .{name}),
        .zon_name = try std.fmt.allocPrint(allocator, "labelle_{s}", .{name}),
        .link_name = try std.fmt.allocPrint(allocator, "labelle-{s}", .{name}),
    };
}

/// Free the allocator-owned fields of an `info` returned by `lookup`.
/// (`name` is borrowed and is left untouched.)
pub fn free(allocator: std.mem.Allocator, info: BackendInfo) void {
    allocator.free(info.subpath);
    allocator.free(info.zon_name);
    allocator.free(info.link_name);
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
