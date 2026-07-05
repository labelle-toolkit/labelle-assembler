//! Game/pack realm struct parsing extracted from `manifest.zig`
//! (behavior-preserving split, labelle-assembler#442 follow-up).
//!
//! AST-walks a realm's `components/*.zig` and `events/*.zig` files into the
//! `StructDecl` / `Field` shapes the manifest writer surfaces (field schema
//! + `save` policy + `visibility`). Pure — allocator in, arena-owned data
//! out — with graceful degradation to a name-only decl when a file can't be
//! read/matched. Re-exported (indirectly) via the `manifest.zig` barrel; the
//! writer and orchestrator reach these through their own imports.

const std = @import("std");
const config = @import("../config.zig");
const idents = @import("../codegen/idents.zig");

/// One struct field: identifier + verbatim Zig source text of its type.
pub const Field = struct {
    name: []const u8,
    zig_type: []const u8,
};

/// One `pub const <Name> = struct { ... }` parsed from a game-root
/// `components/*.zig` or `events/*.zig` file. `save` is the policy enum
/// literal (`saveable` / `transient` / …) pulled from a member
/// `pub const save = ...Saveable(.<policy>, ...)` decl, or null when the
/// struct declares no save policy (every event, most plain components).
pub const StructDecl = struct {
    name: []const u8,
    save: ?[]const u8,
    /// The declared `pub const visibility = .<v>` enum literal (`global` /
    /// `pack`), or null when the struct declares none. Resolved to the
    /// engine default (`pack`) in the writer, not here — the parser reports
    /// only what the source declared (labelle-engine `scene/src/component.zig`).
    visibility: ?[]const u8,
    fields: []const Field,
};

/// Parse every `<game_dir>/<folder>/<name>.zig` file (one struct per
/// file by convention) into `StructDecl`s.
///
/// The decl the assembler actually registers is the *file-stem Pascal*
/// decl (`components/<name>.zig` → `pub const <pathToPascal(name)> =
/// struct {...}`), so this emits exactly that one decl per file — a
/// component/event file may also declare helper containers (a private
/// `const Options = struct {}` / `pub const Clip = enum {}`), and those
/// must NOT leak into the manifest as phantom components/events.
///
/// Read / parse failures degrade to a **name-only** `StructDecl` (the
/// file-stem Pascal name, empty fields) rather than dropping the entry:
/// the generated registries still import that file-stem decl from
/// `component_names` / `event_names`, so omitting it would wrongly report
/// an existing component/event as absent. `OutOfMemory` is the one error
/// that propagates — a real allocation failure must not masquerade as
/// graceful degradation.
pub fn parseStructDir(
    aa: std.mem.Allocator,
    game_dir: []const u8,
    folder: []const u8,
    names: []const []const u8,
) ![]const StructDecl {
    const io = config.globalIo();
    var list: std.ArrayList(StructDecl) = .empty;
    for (names) |name| {
        // The registry-visible decl name, matching how `blocks/registries`
        // names components (`velocity` → `Velocity`).
        var pascal_buf: [128]u8 = undefined;
        const decl_name = idents.pathToPascal(name, &pascal_buf);

        const rel = try std.fmt.allocPrint(aa, "{s}.zig", .{name});
        const path = try std.fs.path.join(aa, &.{ game_dir, folder, rel });

        const src = std.Io.Dir.cwd().readFileAlloc(io, path, aa, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try list.append(aa, try nameOnlyDecl(aa, decl_name));
                continue;
            },
        };
        // `parseStructFile` only fails with `OutOfMemory` — `std.zig.Ast`
        // captures syntax errors in the tree rather than returning them,
        // so a garbled file parses to an AST with no matching decl and is
        // handled by the name-only fallback below, not by a caught error.
        const decls = try parseStructFile(aa, src);

        // Emit only the file-stem decl; ignore any helper containers.
        var matched = false;
        for (decls) |d| {
            if (std.mem.eql(u8, d.name, decl_name)) {
                try list.append(aa, d);
                matched = true;
                break;
            }
        }
        // No decl matched the file stem (empty / garbled source, or an
        // unconventional decl name) — degrade to name-only so the manifest
        // still lists what the registry imports.
        if (!matched) try list.append(aa, try nameOnlyDecl(aa, decl_name));
    }
    return list.toOwnedSlice(aa);
}

/// A `StructDecl` carrying only the registry name — the graceful-degradation
/// stand-in for a component/event file the AST pass couldn't read or match.
fn nameOnlyDecl(aa: std.mem.Allocator, name: []const u8) !StructDecl {
    return .{ .name = try aa.dupe(u8, name), .save = null, .visibility = null, .fields = &.{} };
}

/// AST-walk one source buffer for top-level `pub const <Name> = struct
/// { ... }` declarations, pulling each struct's flat field list (name +
/// type source text) and — if present — its `save` policy.
pub fn parseStructFile(aa: std.mem.Allocator, src: []const u8) ![]const StructDecl {
    const src_z = try aa.dupeZ(u8, src);
    var ast = try std.zig.Ast.parse(aa, src_z, .zig);
    defer ast.deinit(aa);

    var decls: std.ArrayList(StructDecl) = .empty;
    for (ast.rootDecls()) |decl_idx| {
        const vd = ast.fullVarDecl(decl_idx) orelse continue;
        const init_node = vd.ast.init_node.unwrap() orelse continue;

        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const container = ast.fullContainerDecl(&buf, init_node) orelse continue;

        const name_tok = vd.ast.mut_token + 1;
        const name = ast.tokenSlice(name_tok);

        var fields: std.ArrayList(Field) = .empty;
        var save: ?[]const u8 = null;
        var visibility: ?[]const u8 = null;
        for (container.ast.members) |m| {
            if (ast.fullContainerField(m)) |fd| {
                const fname = ast.tokenSlice(fd.ast.main_token);
                const ftype_node = fd.ast.type_expr.unwrap() orelse continue;
                const ftype = ast.getNodeSource(ftype_node);
                try fields.append(aa, .{
                    .name = try aa.dupe(u8, fname),
                    .zig_type = try aa.dupe(u8, std.mem.trim(u8, ftype, " \t\r\n")),
                });
                continue;
            }
            // Not a field — look for the `pub const save = ...Saveable(.x, ...)`
            // and `pub const visibility = .<v>` decls the manifest surfaces.
            // `try` (not `catch null`): a null return means "no literal found"
            // and is expected, but an `OutOfMemory` must propagate rather than
            // be silently collapsed to "no policy / no visibility".
            if (ast.fullVarDecl(m)) |member_vd| {
                const mname = ast.tokenSlice(member_vd.ast.mut_token + 1);
                if (save == null and std.mem.eql(u8, mname, "save")) {
                    save = try extractSavePolicy(aa, ast.getNodeSource(m));
                } else if (visibility == null and std.mem.eql(u8, mname, "visibility")) {
                    // Handles both `pub const visibility = .pack;` and the
                    // typed `pub const visibility: Visibility = .pack;` — the
                    // `: Visibility` annotation sits before the `=`.
                    visibility = try extractEnumLiteralAfterEq(aa, ast.getNodeSource(m));
                }
            }
        }

        try decls.append(aa, .{
            .name = try aa.dupe(u8, name),
            .save = save,
            .visibility = visibility,
            .fields = try fields.toOwnedSlice(aa),
        });
    }
    return decls.toOwnedSlice(aa);
}

/// Pull the policy enum literal out of a `save` decl's source, e.g.
/// `...Saveable(.saveable, @This(), .{...})` → `"saveable"`. Returns null
/// when the marker / literal isn't found.
fn extractSavePolicy(aa: std.mem.Allocator, decl_src: []const u8) !?[]const u8 {
    const marker = "Saveable(";
    const at = std.mem.indexOf(u8, decl_src, marker) orelse return null;
    var i = at + marker.len;
    while (i < decl_src.len and (decl_src[i] == ' ' or decl_src[i] == '\t' or decl_src[i] == '\n' or decl_src[i] == '\r')) i += 1;
    if (i >= decl_src.len or decl_src[i] != '.') return null;
    i += 1;
    const start = i;
    while (i < decl_src.len and (std.ascii.isAlphanumeric(decl_src[i]) or decl_src[i] == '_')) i += 1;
    if (i == start) return null;
    return try aa.dupe(u8, decl_src[start..i]);
}

/// Pull the enum-literal RHS out of a simple `pub const <name> = .<lit>;`
/// (or the typed `pub const <name>: <T> = .<lit>;`) decl source — used for
/// `visibility`. The `: <T>` annotation, when present, precedes the `=`, so
/// splitting on the first `=` handles both forms. Returns null when no
/// `= .<ident>` follows (a non-literal RHS, or no assignment at all).
fn extractEnumLiteralAfterEq(aa: std.mem.Allocator, decl_src: []const u8) !?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, decl_src, '=') orelse return null;
    var i = eq + 1;
    while (i < decl_src.len and (decl_src[i] == ' ' or decl_src[i] == '\t' or decl_src[i] == '\n' or decl_src[i] == '\r')) i += 1;
    if (i >= decl_src.len or decl_src[i] != '.') return null;
    i += 1;
    const start = i;
    while (i < decl_src.len and (std.ascii.isAlphanumeric(decl_src[i]) or decl_src[i] == '_')) i += 1;
    if (i == start) return null;
    return try aa.dupe(u8, decl_src[start..i]);
}

// ─── Tests ──────────────────────────────────────────────────────────────

test "parseStructFile: component fields + save policy" {
    const src =
        \\pub const Bed = struct {
        \\    pub const save = @import("labelle-core").Saveable(.saveable, @This(), .{
        \\        .entity_refs = &.{"sleeper"},
        \\    });
        \\    sleeper: ?u64 = null,
        \\    x: f32 = 0,
        \\    y: f32 = 0,
        \\};
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decls = try parseStructFile(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    try std.testing.expectEqualStrings("Bed", decls[0].name);
    try std.testing.expectEqualStrings("saveable", decls[0].save.?);
    try std.testing.expectEqual(@as(usize, 3), decls[0].fields.len);
    try std.testing.expectEqualStrings("sleeper", decls[0].fields[0].name);
    try std.testing.expectEqualStrings("?u64", decls[0].fields[0].zig_type);
    try std.testing.expectEqualStrings("x", decls[0].fields[1].name);
    try std.testing.expectEqualStrings("f32", decls[0].fields[1].zig_type);
}

test "parseStructFile: event payload (no save policy)" {
    const src =
        \\pub const WorkerSleepStart = struct {
        \\    worker_id: u64,
        \\    bed_id: u64,
        \\};
        \\
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decls = try parseStructFile(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), decls.len);
    try std.testing.expectEqualStrings("WorkerSleepStart", decls[0].name);
    try std.testing.expect(decls[0].save == null);
    try std.testing.expectEqual(@as(usize, 2), decls[0].fields.len);
    try std.testing.expectEqualStrings("worker_id", decls[0].fields[0].name);
    try std.testing.expectEqualStrings("u64", decls[0].fields[0].zig_type);
}

test "extractSavePolicy: pulls the policy enum literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = (try extractSavePolicy(arena.allocator(),
        \\pub const save = @import("labelle-core").Saveable(.transient, @This(), .{});
    )).?;
    try std.testing.expectEqualStrings("transient", p);
    try std.testing.expect((try extractSavePolicy(arena.allocator(), "pub const save = something_else;")) == null);
}

test "parseStructDir: name-only fallback for a missing file, helper decls excluded" {
    const aa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = config.globalIo();

    // `components/velocity.zig` declares the file-stem decl `Velocity`
    // plus a helper container that must NOT surface as its own component.
    try tmp.dir.createDirPath(io, "components");
    {
        var cdir = try tmp.dir.openDir(io, "components", .{});
        defer cdir.close(io);
        var f = try cdir.createFile(io, "velocity.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io,
            \\pub const Velocity = struct {
            \\    dx: f32 = 0,
            \\    dy: f32 = 0,
            \\};
            \\pub const Helper = struct { z: u8 = 0 };
            \\
        );
    }

    const dir = try tmp.dir.realPathFileAlloc(io, ".", aa);
    defer aa.free(dir);

    var arena = std.heap.ArenaAllocator.init(aa);
    defer arena.deinit();

    // `missing` has no backing file → name-only fallback (`Missing`).
    const decls = try parseStructDir(arena.allocator(), dir, "components", &.{ "velocity", "missing" });

    // Exactly two decls: the file-stem `Velocity` and the fallback
    // `Missing` — the `Helper` container is dropped.
    try std.testing.expectEqual(@as(usize, 2), decls.len);
    try std.testing.expectEqualStrings("Velocity", decls[0].name);
    try std.testing.expectEqual(@as(usize, 2), decls[0].fields.len);
    try std.testing.expectEqualStrings("dx", decls[0].fields[0].name);
    // Name-only fallback: registry name present, empty field set.
    try std.testing.expectEqualStrings("Missing", decls[1].name);
    try std.testing.expectEqual(@as(usize, 0), decls[1].fields.len);
    try std.testing.expect(decls[1].save == null);
}

test "parseStructFile: visibility (bare, typed, absent)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ag = arena.allocator();

    // Bare `pub const visibility = .global;`.
    {
        const decls = try parseStructFile(ag,
            \\pub const Worker = struct {
            \\    pub const visibility = .global;
            \\    hunger: f32 = 0,
            \\};
            \\
        );
        try std.testing.expectEqual(@as(usize, 1), decls.len);
        try std.testing.expectEqualStrings("global", decls[0].visibility.?);
    }
    // Typed `pub const visibility: Visibility = .pack;` — the annotation
    // precedes the `=`, so the extractor still lands on `.pack`.
    {
        const decls = try parseStructFile(ag,
            \\pub const Worker = struct {
            \\    pub const visibility: Visibility = .pack;
            \\    hunger: f32 = 0,
            \\};
            \\
        );
        try std.testing.expectEqual(@as(usize, 1), decls.len);
        try std.testing.expectEqualStrings("pack", decls[0].visibility.?);
    }
    // Absent → null (resolved to the `pack` default in the writer, not here).
    {
        const decls = try parseStructFile(ag,
            \\pub const Worker = struct { hunger: f32 = 0 };
            \\
        );
        try std.testing.expectEqual(@as(usize, 1), decls.len);
        try std.testing.expect(decls[0].visibility == null);
    }
}
