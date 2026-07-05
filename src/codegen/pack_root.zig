//! Per-pack module root generation — `__pack_root.zig` (assembler#498
//! PR 2, "wire the wall").
//!
//! A light pack's files used to be path-imported straight from the
//! generated `main.zig`, which put every pack `.zig` in the ROOT module
//! with its full import table — `game`, every sibling pack (via
//! relative paths), the whole tree. The only "these files may only
//! import X, Y, Z" mechanism Zig has is the module boundary, so each
//! pack becomes a real build-system module rooted at a generated
//! `<target>/packs/<name>/__pack_root.zig` (naming mirrors
//! `__tests_root.zig`) that re-exports every scanned file. The
//! generated `main.zig` then reaches pack contents EXCLUSIVELY through
//! `@import("pack__<prefix>")` — path-importing a pack file from the
//! root module after this would be the "file exists in modules 'root'
//! and 'pack__<prefix>'" compile error (the same dual-membership error
//! the FlowNodes script promotion documents in `registries.zig`).
//!
//! What the module's import table deliberately EXCLUDES is the wall:
//! no `game` shim, no sibling packs. It INCLUDES the shared substrate —
//! engine/core/gfx, the backend modules, and every decl-module plugin —
//! because plugins are the sanctioned inter-domain surface (FP's packs
//! route worker access through `worker_controller`'s citizens surface,
//! per the pack's own boundary docs), plus the implicit `contracts`
//! pack when the project declares one (`pack_validate.IMPLICIT_DEPS`).
//! The `@import("root")` Registry bridge + `@import("pack")`
//! self-import (PR 3) make `@import("pack").Registry` the sanctioned
//! string-keyed surface — see `docs/packs.md`. `depends_on` surface
//! modules land in PR 4.
//!
//! Prefab `.jsonc` files stay `@embedFile`d by path from `main.zig` —
//! data files have no module membership, and the embed path + the
//! `<pack>__<name>` registration key are the save contract.

const std = @import("std");
const scan = @import("scan.zig");
const idents = @import("idents.zig");

/// The build-graph identity of one pack module, threaded from
/// `generate()`'s `pack_scans` into `BuildZigOptions` so the generated
/// build.zig declares `pack__<prefix>_mod` and the target artifacts
/// `addImport` it. `prefix` is `scan.packNamespacePrefix(name)` — the
/// same sanitized ident every other `<pack>__` symbol uses.
pub const PackModule = struct {
    /// Manifest/plugin name, verbatim (directory name under `packs/`).
    name: []const u8,
    /// Sanitized `<pack>__` ident prefix (owned by the caller).
    prefix: []const u8,
    /// The manifest's `depends_on` (#498 PR 4): each entry that names a
    /// sibling PACK gets that pack's `__surface.zig` module wired under
    /// the dep's plain name; entries naming decl-module plugins are
    /// already in the table; `contracts` is the implicit full-module
    /// import. Aliases manifest-owned strings.
    depends_on: []const []const u8 = &.{},
};

/// The implicit shared-contracts pack name (`pack_validate.IMPLICIT_DEPS`):
/// when a project declares a pack with this name, every OTHER pack module
/// gets it wired as `@import("contracts")`.
pub const CONTRACTS_PACK_NAME = "contracts";

/// `packs/<name>/scripts/<rel>` → `<rel>`. Pack script entries carry a
/// full target-relative `rel_path` (labelle-assembler#487); inside the
/// pack MODULE the same file is `scripts/<rel>` relative to
/// `__pack_root.zig`. Falls back to the input when the shape is
/// unexpected (defensive — the scanner only ever produces the
/// `packs/<name>/scripts/` form for pack entries).
pub fn packRelScriptPath(rel_path: []const u8, pack_name: []const u8) []const u8 {
    var buf: [512]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "packs/{s}/scripts/", .{pack_name}) catch return rel_path;
    if (std.mem.startsWith(u8, rel_path, prefix)) return rel_path[prefix.len..];
    return rel_path;
}

/// Render the pack's `__pack_root.zig` source. `script_rels` are the
/// pack's script paths RELATIVE TO the pack's `scripts/` dir (see
/// `packRelScriptPath`); components/events/hooks come from the
/// `PackScan` stems. Every decl name is `scan.pathToIdent` of the
/// stem/rel-path — the exact accessor the main.zig emission sites
/// print after `@import("pack__<prefix>").<section>.`, so the two
/// sides can never drift.
///
/// Sections are emitted only when non-empty; a pack with only prefabs
/// produces a module with just the header + `Registry` (still a valid
/// module root — the build graph wires it unconditionally so the wiring
/// shape doesn't depend on which convention dirs a pack happens to use).
///
/// The tail is the `Registry` bridge (#498 PR 3): the pack's sanctioned
/// string-keyed registry, reached from pack code as
/// `@import("pack").Registry` (the self-import `emitPackModules`
/// wires). In a generated game it resolves — via `@import("root")`,
/// legal from any module, the `std_options` mechanism — to the
/// `<prefix>_pack_view` PackView main.zig emitted (PR 1): the pack's
/// own `<pack>__` names plus `.global`-visibility components;
/// foreign-private names `@compileError` in the engine's
/// `ComponentView`. Under a root module that carries no view (the
/// tests target's `__tests_root.zig`, editor preview shells), the
/// `@hasDecl` guard falls back to a registry of the pack's own
/// components only — no globals. Lazy decl analysis makes root↔pack
/// non-circular.
pub fn renderPackRoot(
    allocator: std.mem.Allocator,
    pack: scan.PackScan,
    script_rels: []const []const u8,
) ![]const u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();
    const w = &alloc_writer.writer;

    try w.print(
        \\//! Generated by labelle-assembler — DO NOT EDIT.
        \\//! Module root of pack '{s}' (assembler#498 "wire the wall").
        \\//!
        \\//! Everything the generated main.zig consumes from this pack is
        \\//! re-exported here; the pack's files belong to THIS module, so a
        \\//! path-import of any of them from another module is a compile
        \\//! error — that boundary is the pack isolation contract.
        \\
        \\
    , .{pack.name});

    var ident_buf: [256]u8 = undefined;

    if (pack.component_names.len > 0) {
        try w.writeAll("pub const components = struct {\n");
        for (pack.component_names) |stem| {
            const ident = scan.pathToIdent(stem, &ident_buf);
            try w.print("    pub const {s} = @import(\"components/{s}.zig\");\n", .{ ident, stem });
        }
        try w.writeAll("};\n\n");
    }

    if (pack.event_names.len > 0) {
        try w.writeAll("pub const events = struct {\n");
        for (pack.event_names) |stem| {
            const ident = scan.pathToIdent(stem, &ident_buf);
            try w.print("    pub const {s} = @import(\"events/{s}.zig\");\n", .{ ident, stem });
        }
        try w.writeAll("};\n\n");
    }

    if (pack.hook_names.len > 0) {
        try w.writeAll("pub const hooks = struct {\n");
        for (pack.hook_names) |stem| {
            const ident = scan.pathToIdent(stem, &ident_buf);
            try w.print("    pub const {s} = @import(\"hooks/{s}.zig\");\n", .{ ident, stem });
        }
        try w.writeAll("};\n\n");
    }

    if (script_rels.len > 0) {
        try w.writeAll("pub const scripts = struct {\n");
        for (script_rels) |rel| {
            const ident = scan.pathToIdent(rel, &ident_buf);
            try w.print("    pub const {s} = @import(\"scripts/{s}\");\n", .{ ident, rel });
        }
        try w.writeAll("};\n\n");
    }

    // Verb surfaces (RFC §6, #498 PR 4): raw re-exports for the pack's
    // OWN code; dependents get the `exposes`-narrowed `__surface.zig`.
    if (pack.has_queries) try w.writeAll("pub const queries = @import(\"queries.zig\");\n");
    if (pack.has_commands) try w.writeAll("pub const commands = @import(\"commands.zig\");\n");
    if (pack.has_queries or pack.has_commands) try w.writeAll("\n");

    // ── Registry bridge (#498 PR 3) ────────────────────────────────
    var prefix_buf: [128]u8 = undefined;
    const prefix = scan.packNamespacePrefix(pack.name, &prefix_buf);
    try w.writeAll("const root = @import(\"root\");\n");
    try w.writeAll("/// The pack's sanctioned string-keyed registry: this pack's own\n");
    try w.writeAll("/// `<pack>__` names + `.global`-visibility components. Any\n");
    try w.writeAll("/// foreign-private name is a comptime error (engine ComponentView).\n");
    try w.writeAll("/// Reach it as `@import(\"pack\").Registry` from pack code.\n");
    try w.print("pub const Registry = if (@hasDecl(root, \"{s}_pack_view\"))\n", .{prefix});
    try w.print("    root.{s}_pack_view\n", .{prefix});
    try w.writeAll("else\n");
    try w.writeAll("    // Root module without a generated view (tests target, preview\n");
    try w.writeAll("    // shells): the pack's own components only, no globals.\n");
    try w.writeAll("    @import(\"labelle-engine\").ComponentRegistry(.{");
    if (pack.component_names.len == 0) {
        try w.writeAll("});\n");
    } else {
        try w.writeAll("\n");
        var pascal_buf: [128]u8 = undefined;
        for (pack.component_names) |stem| {
            const ident = scan.pathToIdent(stem, &ident_buf);
            const pascal = idents.pathToPascal(stem, &pascal_buf);
            try w.print("        .{s}__{s} = components.{s}.{s},\n", .{ prefix, pascal, ident, pascal });
        }
        try w.writeAll("    });\n");
    }

    var arr_list = alloc_writer.toArrayList();
    // `toArrayList` resets the writer, so its errdefer no longer covers
    // the buffer — without this, an OOM inside `toOwnedSlice` leaks it
    // (no double-free: the reset writer's deinit is a no-op).
    errdefer arr_list.deinit(allocator);
    return arr_list.toOwnedSlice(allocator);
}

/// The `exposes` lists as the surface renderer consumes them — a
/// decoupled mirror of `plugin_manifest.PackExposes` so this module
/// never imports the manifest parser.
pub const SurfaceExposes = struct {
    queries: []const []const u8 = &.{},
    commands: []const []const u8 = &.{},
};

/// Render the pack's `__surface.zig` — the ONLY thing a dependent pack
/// can import (`@import("<dep>")` maps here, #498 PR 4). Its sole
/// import is the pack module itself (`@import("pack")`), and it
/// re-exports EXACTLY the manifest's `exposes` lists: a listed-but-
/// missing verb fails compilation with an error pointing at this file;
/// a `null`/empty `exposes` yields a header-only module — dependents
/// can call nothing, the correct default.
pub fn renderSurface(
    allocator: std.mem.Allocator,
    pack_name: []const u8,
    exposes: SurfaceExposes,
) ![]const u8 {
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer alloc_writer.deinit();
    const w = &alloc_writer.writer;

    try w.print(
        \\//! Generated by labelle-assembler — DO NOT EDIT.
        \\//! Public surface of pack '{s}' (`exposes`, RFC §6 / #498 PR 4).
        \\//!
        \\//! Dependent packs import THIS module under the pack's name; it
        \\//! re-exports exactly the manifest's `exposes` lists. Anything
        \\//! not listed here does not exist to dependents.
        \\
        \\
    , .{pack_name});

    if (exposes.queries.len > 0 or exposes.commands.len > 0) {
        try w.writeAll("const pack = @import(\"pack\");\n\n");
    }
    if (exposes.queries.len > 0) {
        try w.writeAll("pub const queries = struct {\n");
        for (exposes.queries) |name| {
            // @"" escaping: a manifest may expose a verb whose name is a
            // Zig keyword or needs escaping (declared as `pub fn @"…"`);
            // the escaped form is valid for plain identifiers too.
            try w.print("    pub const @\"{s}\" = pack.queries.@\"{s}\";\n", .{ name, name });
        }
        try w.writeAll("};\n");
    }
    if (exposes.commands.len > 0) {
        if (exposes.queries.len > 0) try w.writeAll("\n");
        try w.writeAll("pub const commands = struct {\n");
        for (exposes.commands) |name| {
            try w.print("    pub const @\"{s}\" = pack.commands.@\"{s}\";\n", .{ name, name });
        }
        try w.writeAll("};\n");
    }

    var arr_list = alloc_writer.toArrayList();
    // Same reset-writer rationale as `renderPackRoot`.
    errdefer arr_list.deinit(allocator);
    return arr_list.toOwnedSlice(allocator);
}
