//! Flow catalog sidecar emitter — labelle-assembler#178 (deferred polish for
//! labelle-gui#170 phase 4).
//!
//! The static `flow_node_catalog.zig` in `labelle-gui` mirrors box2d's 14
//! FlowNodes by hand. That breaks for any other plugin a project pulls in,
//! and requires a labelle-gui release every time a plugin changes its
//! `FlowNodes` block.
//!
//! This module extends the existing phase 2 discovery (`PluginFlowDecls` in
//! `main_zig.zig`) with the additional reflection needed by the editor —
//! `display_name`, `docs`, `kind`, per-pin name/type/label/default, return
//! type, and pin-style color — then writes the result to
//! `<target_dir>/flow_catalog.json` so the editor can pick it up at
//! project-open time.
//!
//! ## What's emitted
//!
//! ```jsonc
//! {
//!   "generated_at": "2026-05-23T...",
//!   "plugins": [
//!     {
//!       "name": "box2d",
//!       "flow_nodes": [
//!         {
//!           "qualified": "box2d.apply_impulse",
//!           "display_name": "Apply Impulse",
//!           "category": "box2d",
//!           "docs": "...",
//!           "kind": "command",
//!           "pins": [
//!             { "name": "entity", "label": "Entity", "zig_type": "u32", "dir": "input" },
//!             { "name": "ix",     "label": "Impulse X", "zig_type": "f32", "dir": "input" },
//!             ...
//!           ],
//!           "return_type": null
//!         }
//!       ],
//!       "pin_styles": [
//!         { "zig_type": "BodyId", "label": "Body", "color": [80, 200, 200] }
//!       ]
//!     }
//!   ]
//! }
//! ```
//!
//! ## How discovery works
//!
//! For each plugin and game-script module we already parse with
//! `std.zig.Ast` in `discoverPluginFlowDecls`. Here we re-walk the same
//! sources and pull more out of each `FlowNodes` / `PinStyles` decl:
//!
//! - For a FlowNode (`pub const apply_impulse = labelle.FlowNode(.{ ... })`):
//!     1. `ast.getNodeSource(init_node)` gives the call's source text.
//!     2. Lightweight text scans pick out `.impl = <ident>`,
//!        `.docs = "..."`, `.kind = .command|.reporter`, and the
//!        `.pins = .{ .<name> = .{ .label = "..." } ... }` map of
//!        per-pin label overrides.
//!     3. The impl function (`<ident>`) is then resolved against the
//!        same source's root decls — `fullFnProto` gives the param
//!        names and types, the return-type source range gives the
//!        single output pin's type (if non-void).
//! - For a PinStyle (`pub const BodyId = labelle.PinStyle{ ... }`):
//!     just text-scan the init source for `.label = "..."` and
//!     `.color = .{ .r = N, .g = N, .b = N, ... }`.
//!
//! Anything we can't parse degrades to a default (pin label = titlecased
//! name, kind = command if no return type, etc.). The editor's existing
//! static catalog is the safety net — projects that haven't regenerated
//! since this lands still work.

const std = @import("std");
const config = @import("config.zig");
const cache = @import("cache.zig");
const script_scanner = @import("script_scanner.zig");
const main_zig = @import("main_zig.zig");

const ProjectConfig = config.ProjectConfig;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;

/// Filename emitted next to `main.zig` in the generated target dir.
pub const SIDECAR_FILENAME = "flow_catalog.json";

/// One pin on a `FlowNodeEntry`. Mirrors the editor's
/// `labelle-gui/src/flow_node_catalog.zig:Pin` shape so the loader can
/// round-trip into the same in-memory representation.
pub const PinDetail = struct {
    /// Identifier as it appears in the impl function's parameter list.
    name: []const u8,
    /// Display label — defaults to titlecased `name`, overridden by
    /// `.pins.<name> = .{ .label = "..." }` on the FlowNode config.
    label: []const u8,
    /// Zig source text of the parameter's type (`u32`, `f32`,
    /// `EntityId`, `*PhysicsBody`, …). For the implicit output pin on a
    /// reporter, this is the function's return-type source.
    zig_type: []const u8,
    /// `"input"` for impl parameters, `"output"` for the return-type
    /// derived pin on a reporter. JSON-friendly tagged form so the
    /// loader doesn't need a separate enum mapping.
    dir: []const u8,
    /// Author-supplied Zig source text of the pin's default, or `null`
    /// when none was declared. Carries through the FlowNode config's
    /// `.pins.<name> = .{ .default = "..." }` override.
    default: ?[]const u8,
};

/// One catalog entry — a plugin- or game-script-declared FlowNode with
/// every metadata field the editor consumes already resolved against
/// the source.
pub const FlowNodeEntry = struct {
    /// Dotted form (`"box2d.apply_impulse"`). The editor's on-disk
    /// `CustomNode.name` field uses the dotted form verbatim.
    qualified: []const u8,
    /// Palette section label — defaults to the contributing module's
    /// name. Plugins / scripts can override via `.category = "..."`.
    category: []const u8,
    /// Human-readable label for the palette + node body. Defaults to
    /// the bare decl name titlecased when no `.display_name = "..."`
    /// override is present.
    display_name: []const u8,
    /// Tooltip text (`.docs = "..."`). Empty string when absent.
    docs: []const u8,
    /// `"command"` (rectangular, exec flow) or `"reporter"` (rounded,
    /// data-only). Derived from return type when the FlowNode config
    /// doesn't pin `.kind` explicitly.
    kind: []const u8,
    /// Pin definitions in display order. Inputs first, the optional
    /// output pin (return value) last.
    pins: []const PinDetail,
    /// Zig source text of the impl's return type, or `null` when the
    /// impl returns `void`. The output pin is already folded into
    /// `pins`; this carries the type separately for the editor's
    /// constructor-node decisions (#O5 follow-up) and connector colour.
    return_type: ?[]const u8,
};

/// One per-type pin-display override discovered on a plugin / script
/// `pub const PinStyles` block. Keyed by Zig type name; the editor
/// merges these on top of its baked-in defaults.
pub const PinStyleEntry = struct {
    /// Zig type name as it appears in the source (the decl identifier).
    zig_type: []const u8,
    /// Display label — `.label = "..."` on the PinStyle literal.
    label: []const u8,
    /// 8-bit-per-channel RGB color the editor paints the pin in.
    /// Source: `.color = .{ .r = N, .g = N, .b = N, ... }`. Alpha is
    /// dropped because the editor treats pins as opaque.
    color: [3]u8,
};

/// Per-module group of catalog entries. The editor renders one
/// collapsible palette section per group keyed by `name`.
pub const ModuleGroup = struct {
    name: []const u8,
    flow_nodes: []FlowNodeEntry,
    pin_styles: []PinStyleEntry,
};

/// The full catalog as it ends up on disk. Self-describes its source
/// timestamp so the editor can compare against a cached snapshot.
pub const Catalog = struct {
    /// ISO-8601-ish UTC timestamp the sidecar was generated. Format:
    /// `"YYYY-MM-DDTHH:MM:SSZ"` — minute-resolution is enough for the
    /// editor's mtime cache.
    generated_at: []const u8,
    /// One entry per module that contributed at least one FlowNode or
    /// PinStyle. Order matches discovery order (plugins first, then
    /// game scripts) — which matches the existing
    /// `discoverPluginFlowDecls` order, so the editor's palette is
    /// stable across regenerations.
    plugins: []ModuleGroup,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Catalog) void {
        // Strings + slices live in the catalog's arena (set up by
        // `discoverDetailedFlowCatalog`); freeing the arena drops
        // them all in one go. We keep an explicit `deinit` so the
        // surrounding `generate` flow doesn't need to know about
        // the arena.
        // No-op here: arena pointer is held by the caller via the
        // returned struct's allocator (the arena's child allocator).
        _ = self;
    }
};

/// Public entry point: discover every FlowNode + PinStyle in the
/// project's plugins and game scripts, then write
/// `<target_dir>/flow_catalog.json`.
///
/// Returns the number of FlowNode entries emitted. A return of 0
/// means no plugin or script declared any FlowNodes — the sidecar is
/// still written (with an empty `plugins` array) so the editor sees
/// "this project regenerated, just has nothing in its palette".
///
/// The caller is responsible for `target_dir` already existing.
pub fn emitFlowCatalogSidecar(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    project_dir: []const u8,
    target_dir: []const u8,
    scripts_root: []const u8,
    script_entries: []const ScriptEntry,
) !usize {
    // Build everything into one arena so the discovery + emission
    // ownership story is "free the arena, drop everything". The
    // emitted JSON itself comes back as a heap slice via the
    // top-level `allocator` so we can write it out and free it
    // without ripping the arena out from under in-flight strings.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var groups: std.ArrayList(ModuleGroup) = .empty;

    // ── Plugin pass ─────────────────────────────────────────────
    for (cfg.plugins) |plugin| {
        const plugin_dir = cache.resolvePlugin(aa, plugin, project_dir) catch continue;
        const root_path = try std.fs.path.join(aa, &.{ plugin_dir, "src", "root.zig" });

        const io = config.globalIo();
        const src = std.Io.Dir.cwd().readFileAlloc(io, root_path, aa, .limited(8 * 1024 * 1024)) catch continue;

        const group = try discoverInSource(aa, src, plugin.name) orelse continue;
        try groups.append(aa, group);
    }

    // ── Game-script pass ────────────────────────────────────────
    // Plugin-shipped scripts (entries with a non-null plugin_name) are
    // skipped here — they're already covered by their containing
    // plugin's `src/root.zig` walk above. Re-walking them as game
    // scripts would emit duplicate entries with mismatched qualified
    // names (the script's rel_path vs. the plugin's name) and confuse
    // the editor's palette.
    for (script_entries) |entry| {
        if (entry.plugin_name != null) continue;
        const script_path = try std.fs.path.join(aa, &.{ scripts_root, entry.rel_path });

        const io = config.globalIo();
        const src = std.Io.Dir.cwd().readFileAlloc(io, script_path, aa, .limited(8 * 1024 * 1024)) catch continue;

        // Game scripts are surfaced under a derived module name. The
        // rel_path (e.g. `flows/hit_counter.zig`) is what `@import`
        // sees; we strip the `.zig` suffix and the path separators get
        // joined with `.` so the editor's palette reads
        // `flows.hit_counter` not `flows/hit_counter`.
        const module_label = try scriptModuleLabel(aa, entry.rel_path);

        const group = try discoverInSource(aa, src, module_label) orelse continue;
        try groups.append(aa, group);
    }

    // ── Total node count (return value) ─────────────────────────
    var total: usize = 0;
    for (groups.items) |g| total += g.flow_nodes.len;

    // ── Build the JSON in `allocator` so it survives arena teardown ──
    // `Writer.Allocating.deinit` always frees the writer's internal
    // buffer; `toOwnedSlice` resets the buffer to empty + transfers the
    // bytes out. Order matters: take ownership first, then `deinit`
    // (which is now a no-op on the empty writer), then free the slice
    // after we've used it. Errors before `toOwnedSlice` are caught by
    // the `errdefer`.
    var alloc_writer: std.Io.Writer.Allocating = .init(allocator);
    {
        errdefer alloc_writer.deinit();
        try writeCatalogJson(&alloc_writer.writer, groups.items);
    }
    const json_bytes = try alloc_writer.toOwnedSlice();
    alloc_writer.deinit();
    defer allocator.free(json_bytes);

    // ── Write the sidecar ───────────────────────────────────────
    try writeSidecar(target_dir, json_bytes);

    return total;
}

/// Build a `<module>` label for a game-script `rel_path`. Strips a
/// trailing `.zig` and replaces `/` with `.` so a nested script reads
/// naturally as a palette section heading. `flows/hit_counter.zig`
/// becomes `flows.hit_counter`; the editor's `CustomNode.name`
/// references on disk match this dotted form prefix-wise.
fn scriptModuleLabel(aa: std.mem.Allocator, rel_path: []const u8) ![]const u8 {
    const stem = if (std.mem.endsWith(u8, rel_path, ".zig"))
        rel_path[0 .. rel_path.len - ".zig".len]
    else
        rel_path;
    var buf: std.ArrayList(u8) = .empty;
    for (stem) |c| {
        try buf.append(aa, if (c == '/' or c == '\\') '.' else c);
    }
    return buf.toOwnedSlice(aa);
}

/// Walk one source buffer for `pub const FlowNodes` + `pub const
/// PinStyles` blocks and return a `ModuleGroup`, or `null` when
/// neither block is present. All slices and strings in the result
/// live in `aa`.
fn discoverInSource(aa: std.mem.Allocator, src: []const u8, module_name: []const u8) !?ModuleGroup {
    const src_z = try aa.dupeZ(u8, src);

    var ast = try std.zig.Ast.parse(aa, src_z, .zig);
    defer ast.deinit(aa);

    var nodes: std.ArrayList(FlowNodeEntry) = .empty;
    var styles: std.ArrayList(PinStyleEntry) = .empty;

    var found_anything = false;
    const root_decls = ast.rootDecls();
    for (root_decls) |decl_idx| {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const vd = ast.fullVarDecl(decl_idx) orelse continue;
        if (vd.visib_token == null) continue;
        const name_tok = vd.ast.mut_token + 1;
        const decl_name = ast.tokenSlice(name_tok);

        const is_flow_nodes = std.mem.eql(u8, decl_name, "FlowNodes");
        const is_pin_styles = std.mem.eql(u8, decl_name, "PinStyles");
        if (!is_flow_nodes and !is_pin_styles) continue;

        const init_node = vd.ast.init_node.unwrap() orelse continue;
        const container = ast.fullContainerDecl(&buf, init_node) orelse continue;

        for (container.ast.members) |m| {
            const member_vd = ast.fullVarDecl(m) orelse continue;
            if (member_vd.visib_token == null) continue;
            const member_init = member_vd.ast.init_node.unwrap() orelse continue;
            const member_name_tok = member_vd.ast.mut_token + 1;
            const member_name = ast.tokenSlice(member_name_tok);

            if (is_flow_nodes) {
                const entry = extractFlowNodeEntry(
                    aa,
                    &ast,
                    member_name,
                    member_init,
                    module_name,
                ) catch continue;
                try nodes.append(aa, entry);
                found_anything = true;
            } else {
                const entry = extractPinStyleEntry(
                    aa,
                    &ast,
                    member_name,
                    member_init,
                ) catch continue;
                try styles.append(aa, entry);
                found_anything = true;
            }
        }
    }

    if (!found_anything) return null;
    return ModuleGroup{
        .name = try aa.dupe(u8, module_name),
        .flow_nodes = try nodes.toOwnedSlice(aa),
        .pin_styles = try styles.toOwnedSlice(aa),
    };
}

/// Pull out FlowNode metadata from a `labelle.FlowNode(.{...})` init
/// node — including walking back into the impl function's parameter
/// list for pin names and types.
fn extractFlowNodeEntry(
    aa: std.mem.Allocator,
    ast: *std.zig.Ast,
    decl_name: []const u8,
    init_node: std.zig.Ast.Node.Index,
    module_name: []const u8,
) !FlowNodeEntry {
    const init_src = ast.getNodeSource(init_node);

    // Try to find the inner struct literal `.{...}` source — that's the
    // FlowNode config. The init source is something like
    // `labelle.FlowNode(.{ .impl = ..., .docs = "..." })`; we only need
    // the bit between the outer parens.
    const cfg_src = innerCallArg(init_src);

    const impl_name = scanFieldIdent(cfg_src, ".impl") orelse "";
    const docs = scanFieldStringDup(aa, cfg_src, ".docs") catch null;
    const explicit_kind = scanFieldEnumLit(cfg_src, ".kind"); // ".command" or ".reporter" or null
    const display_name = scanFieldStringDup(aa, cfg_src, ".display_name") catch null;
    const category_override = scanFieldStringDup(aa, cfg_src, ".category") catch null;

    // ── Pins ──
    // Walk the impl function's parameter list (skip the first
    // `game: anytype` per RFC §1). Each remaining param becomes one
    // input pin. The return type, when non-void, becomes the output
    // pin appended after the inputs.
    var pin_list: std.ArrayList(PinDetail) = .empty;
    var return_type: ?[]const u8 = null;
    var has_return = false;

    if (impl_name.len > 0) {
        if (findFnByName(ast, impl_name)) |fn_node| {
            var fn_buf: [1]std.zig.Ast.Node.Index = undefined;
            if (ast.fullFnProto(&fn_buf, fn_node)) |fp| {
                var it = fp.iterate(ast);
                var idx: usize = 0;
                while (it.next()) |param| : (idx += 1) {
                    // Skip the implicit `game: anytype` (RFC §1).
                    if (idx == 0) continue;
                    const name_tok = param.name_token orelse continue;
                    const pname = ast.tokenSlice(name_tok);
                    const ptype_node = param.type_expr orelse continue;
                    const ptype = ast.getNodeSource(ptype_node);

                    const label = try resolvePinLabel(aa, cfg_src, pname);
                    const default = scanPinDefault(aa, cfg_src, pname) catch null;
                    try pin_list.append(aa, .{
                        .name = try aa.dupe(u8, pname),
                        .label = label,
                        .zig_type = try aa.dupe(u8, ptype),
                        .dir = "input",
                        .default = default,
                    });
                }

                if (fp.ast.return_type.unwrap()) |rt_node| {
                    const rt = ast.getNodeSource(rt_node);
                    // void / no-return-of-interest collapses to no output pin.
                    if (!std.mem.eql(u8, std.mem.trim(u8, rt, " \t\r\n"), "void")) {
                        return_type = try aa.dupe(u8, rt);
                        has_return = true;
                        // Add a single output pin named "result" by default —
                        // the editor's existing static catalog uses ad-hoc
                        // names (`x`/`y` for Vec2, `value` for a scalar,
                        // `entity` for an EntityId) because it was hand-
                        // written. The dynamic discovery here can't see
                        // *inside* a returned struct without much heavier
                        // type resolution, so we emit one pin sourcing the
                        // declared return type verbatim and let the editor
                        // surface struct destructuring in a follow-up.
                        try pin_list.append(aa, .{
                            .name = "result",
                            .label = "Result",
                            .zig_type = try aa.dupe(u8, rt),
                            .dir = "output",
                            .default = null,
                        });
                    }
                }
            }
        }
    }

    // ── Kind ──
    // Explicit `.kind = .command` / `.kind = .reporter` always wins.
    // Otherwise the FlowNode factory's runtime default kicks in:
    // `void`-returning impls are commands, everything else is a reporter.
    const kind: []const u8 = blk: {
        if (explicit_kind) |ek| {
            if (std.mem.eql(u8, ek, "command")) break :blk "command";
            if (std.mem.eql(u8, ek, "reporter")) break :blk "reporter";
        }
        break :blk if (has_return) "reporter" else "command";
    };

    // ── Display name ──
    // Falls back to the decl name titlecased
    // (`apply_impulse` → `Apply Impulse`) so the palette reads clean
    // without authors having to override it.
    const dn = display_name orelse try titlecaseFromIdent(aa, decl_name);

    // ── Qualified name ──
    // Dotted form, matching the editor's on-disk `CustomNode.name`
    // schema. Plugins use their project.labelle name; game scripts use
    // the dotted module-label form built by `scriptModuleLabel`.
    const qualified = try std.fmt.allocPrint(aa, "{s}.{s}", .{ module_name, decl_name });

    return .{
        .qualified = qualified,
        .category = category_override orelse try aa.dupe(u8, module_name),
        .display_name = dn,
        .docs = docs orelse try aa.dupe(u8, ""),
        .kind = kind,
        .pins = try pin_list.toOwnedSlice(aa),
        .return_type = return_type,
    };
}

/// Pull out PinStyle metadata from a `labelle.PinStyle{...}` init
/// literal. Both the `label` string and the `.color = .{ .r = N, ... }`
/// fields are extracted via simple text scans against the source range.
fn extractPinStyleEntry(
    aa: std.mem.Allocator,
    ast: *std.zig.Ast,
    decl_name: []const u8,
    init_node: std.zig.Ast.Node.Index,
) !PinStyleEntry {
    const init_src = ast.getNodeSource(init_node);
    const label = (try scanFieldStringDup(aa, init_src, ".label")) orelse try aa.dupe(u8, decl_name);
    const color = scanColorTriple(init_src) orelse [3]u8{ 200, 200, 200 };
    return .{
        .zig_type = try aa.dupe(u8, decl_name),
        .label = label,
        .color = color,
    };
}

// ─── AST helpers ────────────────────────────────────────────────────────

/// Find a top-level `fn <name>(...) ...` declaration in the parsed AST
/// and return its `fn_decl` node index. Returns `null` when the
/// function isn't visible at module scope — that's the case for impls
/// imported from a sibling file, which we surface as "no pin info" in
/// the catalog rather than failing the whole sidecar build.
fn findFnByName(ast: *std.zig.Ast, name: []const u8) ?std.zig.Ast.Node.Index {
    const root_decls = ast.rootDecls();
    for (root_decls) |decl_idx| {
        var fn_buf: [1]std.zig.Ast.Node.Index = undefined;
        const fp = ast.fullFnProto(&fn_buf, decl_idx) orelse continue;
        const name_tok = fp.name_token orelse continue;
        if (std.mem.eql(u8, ast.tokenSlice(name_tok), name)) return decl_idx;
    }
    return null;
}

// ─── Source-text scanners ───────────────────────────────────────────────
//
// The FlowNode + PinStyle config literals are tiny, deeply structured,
// and stable in shape across the toolkit. A focused text scan keyed off
// the field names is far less code than a full struct-init walk for
// the depth we need, and degrades gracefully when a future field
// migration moves things around (we just stop seeing the field and the
// editor uses defaults).
//
// All scanners take a slice that's already known to be the source text
// of a single struct-init literal — `getNodeSource(init_node)`, or its
// inner-paren form for a `Foo(.{...})` call.

/// Strip the outer `Foo(...)` so we end up with the call's first
/// argument's source. If the source doesn't look like a single-arg
/// call, return it unchanged — the field scanners are defensive.
fn innerCallArg(src: []const u8) []const u8 {
    const lp = std.mem.indexOfScalar(u8, src, '(') orelse return src;
    // Match the closing paren at the same nesting depth.
    var depth: usize = 1;
    var i = lp + 1;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return src[lp + 1 .. i];
            },
            else => {},
        }
    }
    return src;
}

/// Locate `<field> = ` in `src` and return the slice starting just
/// after the `=` (with leading whitespace trimmed), or `null` when the
/// field isn't present. The match is whole-token: we require the
/// preceding byte to be `,`, `{`, or whitespace so `apply_impulse`'s
/// `.impl` doesn't accidentally hit the substring `.impl` inside
/// another field's value.
fn locateField(src: []const u8, field: []const u8) ?[]const u8 {
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, src, search_start, field)) |pos| {
        // Boundary check — the byte before `field` must be a separator
        // or the start of the slice. Without this, `.color` inside a
        // composite like `.color_default` would match `.color`.
        if (pos > 0) {
            const prev = src[pos - 1];
            switch (prev) {
                ',', '{', ' ', '\t', '\n', '\r' => {},
                else => {
                    search_start = pos + 1;
                    continue;
                },
            }
        }
        // The byte after `field` must be `=` (after optional whitespace).
        var after = pos + field.len;
        while (after < src.len and (src[after] == ' ' or src[after] == '\t')) after += 1;
        if (after >= src.len or src[after] != '=') {
            search_start = pos + 1;
            continue;
        }
        after += 1;
        while (after < src.len and (src[after] == ' ' or src[after] == '\t' or src[after] == '\n' or src[after] == '\r')) after += 1;
        return src[after..];
    }
    return null;
}

/// Extract a bare identifier as the right-hand side of `<field> = `.
/// Returns the identifier slice (borrowed from `src`) or `null` if no
/// identifier is present.
fn scanFieldIdent(src: []const u8, field: []const u8) ?[]const u8 {
    const rhs = locateField(src, field) orelse return null;
    var end: usize = 0;
    while (end < rhs.len) : (end += 1) {
        const c = rhs[end];
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) break;
    }
    if (end == 0) return null;
    return rhs[0..end];
}

/// Extract a leading enum literal like `.command` from
/// `<field> = .command,`. Returns the identifier after the `.` (or
/// `null` when the field isn't an enum literal). The leading `.` is
/// required to disambiguate enum literals from bare idents.
fn scanFieldEnumLit(src: []const u8, field: []const u8) ?[]const u8 {
    const rhs = locateField(src, field) orelse return null;
    if (rhs.len == 0 or rhs[0] != '.') return null;
    var end: usize = 1;
    while (end < rhs.len) : (end += 1) {
        const c = rhs[end];
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) break;
    }
    if (end == 1) return null;
    return rhs[1..end];
}

/// Extract a string literal as the right-hand side of `<field> = `.
/// Handles standard `"..."` strings with `\"` and `\\` escapes;
/// multi-line `\\` strings aren't supported (none of the toolkit's
/// FlowNode / PinStyle declarations use them). Returns an owned dupe
/// in `aa`, or `null` when the field is absent or not a string. The
/// `!` error union covers `aa.dupe` OOM only.
fn scanFieldStringDup(aa: std.mem.Allocator, src: []const u8, field: []const u8) !?[]const u8 {
    const rhs = locateField(src, field) orelse return null;
    if (rhs.len == 0 or rhs[0] != '"') return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(aa);
    var i: usize = 1;
    while (i < rhs.len) : (i += 1) {
        const c = rhs[i];
        if (c == '\\' and i + 1 < rhs.len) {
            const e = rhs[i + 1];
            try out.append(aa, switch (e) {
                '"' => '"',
                '\\' => '\\',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => e,
            });
            i += 1;
            continue;
        }
        if (c == '"') break;
        try out.append(aa, c);
    }
    return try out.toOwnedSlice(aa);
}

/// Scan a `.color = .{ .r = N, .g = N, .b = N, .a = N }` struct
/// literal and return the (r, g, b) triple. Defaults to `null` when
/// the field isn't present or doesn't look like a Color literal. Alpha
/// is intentionally dropped — the editor treats pins as opaque.
fn scanColorTriple(src: []const u8) ?[3]u8 {
    const rhs = locateField(src, ".color") orelse return null;
    // We need a `.{` next. Allow either `Color{` or `.{` — the toolkit
    // mixes both forms (labelle-box2d uses `core.flow.Color{ ... }`,
    // user code might use `.{ ... }`).
    var i: usize = 0;
    while (i < rhs.len and (rhs[i] == '.' or rhs[i] == ' ' or rhs[i] == '\t' or (rhs[i] >= 'A' and rhs[i] <= 'Z') or (rhs[i] >= 'a' and rhs[i] <= 'z') or rhs[i] == '_')) : (i += 1) {}
    if (i >= rhs.len or rhs[i] != '{') return null;
    // Find the matching '}'.
    var depth: usize = 1;
    var j = i + 1;
    while (j < rhs.len) : (j += 1) {
        switch (rhs[j]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) break;
            },
            else => {},
        }
    }
    if (depth != 0) return null;
    const body = rhs[i + 1 .. j];
    const r = scanU8Field(body, ".r") orelse return null;
    const g = scanU8Field(body, ".g") orelse return null;
    const b = scanU8Field(body, ".b") orelse return null;
    return [3]u8{ r, g, b };
}

/// Read `<field> = NNN` as a `u8`. Returns `null` on parse failure.
fn scanU8Field(src: []const u8, field: []const u8) ?u8 {
    const rhs = locateField(src, field) orelse return null;
    var end: usize = 0;
    while (end < rhs.len and rhs[end] >= '0' and rhs[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(u8, rhs[0..end], 10) catch null;
}

/// Resolve the display label for a pin: check the FlowNode config's
/// `.pins.<name>.label` override, else titlecase `pname`. Returns an
/// owned dupe in `aa`.
fn resolvePinLabel(aa: std.mem.Allocator, cfg_src: []const u8, pname: []const u8) ![]const u8 {
    // Locate the `.pins = .{ ... }` block first.
    const pins_rhs = locateField(cfg_src, ".pins");
    if (pins_rhs) |rhs| {
        // Find the next `.<pname> = .{` inside the pins block.
        // We don't care about being precise about the block's bounds —
        // a stray `.<pname>` outside would only matter if the same
        // identifier is used as both a pin name and another field
        // label, which doesn't happen in any of the toolkit's
        // FlowNodes today.
        var field_buf: [128]u8 = undefined;
        const field = std.fmt.bufPrint(&field_buf, ".{s}", .{pname}) catch return titlecaseFromIdent(aa, pname);
        if (locateField(rhs, field)) |pin_rhs| {
            // pin_rhs starts at the `.{`. Scan ahead for `.label = "..."`.
            const lbl = scanFieldStringDup(aa, pin_rhs, ".label") catch null;
            if (lbl) |s| return s;
        }
    }
    return titlecaseFromIdent(aa, pname);
}

/// Extract the `.default = "..."` source-text override for one pin,
/// or `null` when not declared.
fn scanPinDefault(aa: std.mem.Allocator, cfg_src: []const u8, pname: []const u8) !?[]const u8 {
    const pins_rhs = locateField(cfg_src, ".pins") orelse return null;
    var field_buf: [128]u8 = undefined;
    const field = std.fmt.bufPrint(&field_buf, ".{s}", .{pname}) catch return null;
    const pin_rhs = locateField(pins_rhs, field) orelse return null;
    return try scanFieldStringDup(aa, pin_rhs, ".default");
}

/// Map an identifier like `apply_impulse` to a titlecased display form
/// (`Apply Impulse`). Splits on `_` and capitalises the first letter
/// of each component. Returns an owned dupe.
fn titlecaseFromIdent(aa: std.mem.Allocator, ident: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(aa);
    var capitalize_next = true;
    for (ident) |c| {
        if (c == '_') {
            try out.append(aa, ' ');
            capitalize_next = true;
            continue;
        }
        if (capitalize_next and c >= 'a' and c <= 'z') {
            try out.append(aa, c - 32);
        } else {
            try out.append(aa, c);
        }
        capitalize_next = false;
    }
    return out.toOwnedSlice(aa);
}

// ─── JSON writer ────────────────────────────────────────────────────────

/// Emit the full catalog as JSON. Hand-written for readability over the
/// stdlib's `std.json.Stringify` because the structure is small and
/// we want stable, pretty-printed output the user can diff and the
/// editor can hand-parse without a schema.
fn writeCatalogJson(w: *std.Io.Writer, groups: []const ModuleGroup) !void {
    // ISO-8601 timestamp at minute resolution. The editor uses
    // mtime-keyed caching (not this string) so the exact format isn't
    // critical, but a human-readable one helps debugging.
    var ts_buf: [32]u8 = undefined;
    const ts = formatTimestamp(&ts_buf);

    try w.writeAll("{\n");
    try w.print("  \"generated_at\": \"{s}\",\n", .{ts});
    try w.writeAll("  \"plugins\": [");
    if (groups.len == 0) {
        try w.writeAll("]\n}\n");
        return;
    }
    try w.writeAll("\n");
    for (groups, 0..) |g, gi| {
        try w.writeAll("    {\n");
        try w.print("      \"name\": ", .{});
        try writeJsonString(w, g.name);
        try w.writeAll(",\n");
        try w.writeAll("      \"flow_nodes\": [");
        if (g.flow_nodes.len == 0) {
            try w.writeAll("],\n");
        } else {
            try w.writeAll("\n");
            for (g.flow_nodes, 0..) |n, ni| {
                try writeFlowNodeJson(w, n);
                if (ni + 1 < g.flow_nodes.len) try w.writeAll(",");
                try w.writeAll("\n");
            }
            try w.writeAll("      ],\n");
        }
        try w.writeAll("      \"pin_styles\": [");
        if (g.pin_styles.len == 0) {
            try w.writeAll("]\n");
        } else {
            try w.writeAll("\n");
            for (g.pin_styles, 0..) |s, si| {
                try writePinStyleJson(w, s);
                if (si + 1 < g.pin_styles.len) try w.writeAll(",");
                try w.writeAll("\n");
            }
            try w.writeAll("      ]\n");
        }
        try w.writeAll("    }");
        if (gi + 1 < groups.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("  ]\n}\n");
}

fn writeFlowNodeJson(w: *std.Io.Writer, n: FlowNodeEntry) !void {
    try w.writeAll("        {\n");
    try w.writeAll("          \"qualified\": ");
    try writeJsonString(w, n.qualified);
    try w.writeAll(",\n          \"display_name\": ");
    try writeJsonString(w, n.display_name);
    try w.writeAll(",\n          \"category\": ");
    try writeJsonString(w, n.category);
    try w.writeAll(",\n          \"docs\": ");
    try writeJsonString(w, n.docs);
    try w.writeAll(",\n          \"kind\": ");
    try writeJsonString(w, n.kind);
    try w.writeAll(",\n          \"pins\": [");
    if (n.pins.len == 0) {
        try w.writeAll("],\n");
    } else {
        try w.writeAll("\n");
        for (n.pins, 0..) |p, pi| {
            try w.writeAll("            { \"name\": ");
            try writeJsonString(w, p.name);
            try w.writeAll(", \"label\": ");
            try writeJsonString(w, p.label);
            try w.writeAll(", \"zig_type\": ");
            try writeJsonString(w, p.zig_type);
            try w.writeAll(", \"dir\": ");
            try writeJsonString(w, p.dir);
            try w.writeAll(", \"default\": ");
            if (p.default) |d| try writeJsonString(w, d) else try w.writeAll("null");
            try w.writeAll(" }");
            if (pi + 1 < n.pins.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("          ],\n");
    }
    try w.writeAll("          \"return_type\": ");
    if (n.return_type) |rt| try writeJsonString(w, rt) else try w.writeAll("null");
    try w.writeAll("\n        }");
}

fn writePinStyleJson(w: *std.Io.Writer, s: PinStyleEntry) !void {
    try w.writeAll("        { \"zig_type\": ");
    try writeJsonString(w, s.zig_type);
    try w.writeAll(", \"label\": ");
    try writeJsonString(w, s.label);
    try w.print(", \"color\": [{d}, {d}, {d}] }}", .{ s.color[0], s.color[1], s.color[2] });
}

/// Write a JSON string literal — wraps in double quotes, escapes the
/// subset of bytes JSON requires (`"`, `\`, control chars below 0x20)
/// and pass-throughs everything else. UTF-8 source bytes ride along
/// unchanged because JSON is UTF-8 itself.
fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// Format the current UTC timestamp as `"YYYY-MM-DDTHH:MM:SSZ"`. Pure
/// epoch arithmetic so we don't depend on system locale settings or a
/// `strftime`-style call.
fn formatTimestamp(buf: *[32]u8) []const u8 {
    const epoch_secs: u64 = blk: {
        // `std.time.timestamp` was removed in 0.16; use `clock_gettime`
        // through libc the same way `tests.zig` does.
        var ts: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(.REALTIME, &ts);
        break :blk @intCast(ts.sec);
    };

    // Days since 1970-01-01 + seconds-of-day.
    const secs_per_day: u64 = 86400;
    const day = epoch_secs / secs_per_day;
    const sod = epoch_secs % secs_per_day;
    const hour: u32 = @intCast(sod / 3600);
    const minute: u32 = @intCast((sod % 3600) / 60);
    const second: u32 = @intCast(sod % 60);

    // Howard Hinnant's days-from-civil algorithm in reverse — Zig
    // stdlib has the same calculation behind `std.time.epoch` but the
    // shape moved between 0.15 and 0.16 enough that doing it inline
    // is the smallest dependency.
    var y: i64 = 1970;
    var d_remain: i64 = @intCast(day);
    while (true) {
        const days_in_year: i64 = if (isLeapYear(y)) 366 else 365;
        if (d_remain < days_in_year) break;
        d_remain -= days_in_year;
        y += 1;
    }
    var month: u32 = 1;
    const months = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    while (month <= 12) {
        const days_in_month: i64 = blk: {
            var dim: i64 = months[month - 1];
            if (month == 2 and isLeapYear(y)) dim += 1;
            break :blk dim;
        };
        if (d_remain < days_in_month) break;
        d_remain -= days_in_month;
        month += 1;
    }
    const day_of_month: u32 = @intCast(d_remain + 1);

    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ y, month, day_of_month, hour, minute, second }) catch "1970-01-01T00:00:00Z";
}

fn isLeapYear(y: i64) bool {
    if (@mod(y, 4) != 0) return false;
    if (@mod(y, 100) != 0) return true;
    return @mod(y, 400) == 0;
}

/// Write `<target_dir>/flow_catalog.json`. Mirrors the pattern other
/// generated artifacts (`main.zig`, `build.zig`) use.
fn writeSidecar(target_dir: []const u8, bytes: []const u8) !void {
    const io = config.globalIo();
    const cwd = std.Io.Dir.cwd();
    var dir = try cwd.openDir(io, target_dir, .{});
    defer dir.close(io);
    const file = try dir.createFile(io, SIDECAR_FILENAME, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

// Re-export the module-level types in case downstream tests want to
// reach them without going through `emitFlowCatalogSidecar`'s public
// surface.
pub const _testing = struct {
    pub const innerCallArg_ = innerCallArg;
    pub const scanFieldIdent_ = scanFieldIdent;
    pub const scanFieldStringDup_ = scanFieldStringDup;
    pub const scanFieldEnumLit_ = scanFieldEnumLit;
    pub const scanColorTriple_ = scanColorTriple;
    pub const titlecaseFromIdent_ = titlecaseFromIdent;
    pub const discoverInSource_ = discoverInSource;
    pub const writeCatalogJson_ = writeCatalogJson;
};

// ─── Tests ──────────────────────────────────────────────────────────────

test "innerCallArg returns the content between outer parens" {
    try std.testing.expectEqualStrings(".{ .impl = foo }", innerCallArg("Foo(.{ .impl = foo })"));
    try std.testing.expectEqualStrings("no parens at all", innerCallArg("no parens at all"));
}

test "scanFieldIdent: bare identifier RHS" {
    try std.testing.expectEqualStrings("foo", scanFieldIdent(".{ .impl = foo, .docs = \"x\" }", ".impl").?);
    try std.testing.expect(scanFieldIdent(".{ .docs = \"x\" }", ".impl") == null);
}

test "scanFieldIdent: respects token boundaries" {
    // `.imply` should not match `.impl`.
    try std.testing.expect(scanFieldIdent(".{ .imply = 1 }", ".impl") == null);
}

test "scanFieldEnumLit: leading dot is required" {
    try std.testing.expectEqualStrings("command", scanFieldEnumLit(".{ .kind = .command }", ".kind").?);
    // No leading dot → not an enum literal.
    try std.testing.expect(scanFieldEnumLit(".{ .kind = command }", ".kind") == null);
}

test "scanFieldStringDup: standard escape sequences" {
    const aa = std.testing.allocator;
    const a = (try scanFieldStringDup(aa, ".{ .docs = \"hello\\nworld\" }", ".docs")).?;
    defer aa.free(a);
    try std.testing.expectEqualStrings("hello\nworld", a);
}

test "scanColorTriple: parses an explicit Color{} literal" {
    const c = scanColorTriple(".{ .label = \"X\", .color = .{ .r = 12, .g = 34, .b = 56, .a = 255 } }").?;
    try std.testing.expectEqual(@as(u8, 12), c[0]);
    try std.testing.expectEqual(@as(u8, 34), c[1]);
    try std.testing.expectEqual(@as(u8, 56), c[2]);
}

test "titlecaseFromIdent: snake_case to Title Case" {
    const aa = std.testing.allocator;
    const s = try titlecaseFromIdent(aa, "apply_impulse");
    defer aa.free(s);
    try std.testing.expectEqualStrings("Apply Impulse", s);
}

test "discoverInSource: finds box2d-shaped FlowNodes + PinStyles" {
    // A small synthetic source that mimics labelle-box2d's shape.
    // Single FlowNode with an impl in the same source so the pin walk
    // resolves; one PinStyle with a color triple.
    const src =
        \\const flow = @import("flow");
        \\
        \\pub const FlowNodes = struct {
        \\    pub const apply_impulse = flow.FlowNode(.{
        \\        .impl = applyImpulseImpl,
        \\        .docs = "Apply a linear impulse.",
        \\        .pins = .{
        \\            .ix = .{ .label = "Impulse X" },
        \\            .iy = .{ .label = "Impulse Y" },
        \\        },
        \\    });
        \\};
        \\
        \\pub const PinStyles = struct {
        \\    pub const BodyId = flow.PinStyle{
        \\        .label = "Body",
        \\        .color = .{ .r = 80, .g = 200, .b = 200, .a = 255 },
        \\    };
        \\};
        \\
        \\fn applyImpulseImpl(game: anytype, entity: u32, ix: f32, iy: f32) void {
        \\    _ = game; _ = entity; _ = ix; _ = iy;
        \\}
        \\
    ;
    const aa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(aa);
    defer arena.deinit();
    const group = (try discoverInSource(arena.allocator(), src, "box2d")) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqualStrings("box2d", group.name);
    try std.testing.expectEqual(@as(usize, 1), group.flow_nodes.len);
    try std.testing.expectEqualStrings("box2d.apply_impulse", group.flow_nodes[0].qualified);
    try std.testing.expectEqualStrings("Apply Impulse", group.flow_nodes[0].display_name);
    try std.testing.expectEqualStrings("Apply a linear impulse.", group.flow_nodes[0].docs);
    try std.testing.expectEqualStrings("command", group.flow_nodes[0].kind);
    // Pin walk skipped `game: anytype` (first param) and surfaced 3 inputs.
    try std.testing.expectEqual(@as(usize, 3), group.flow_nodes[0].pins.len);
    try std.testing.expectEqualStrings("entity", group.flow_nodes[0].pins[0].name);
    try std.testing.expectEqualStrings("u32", group.flow_nodes[0].pins[0].zig_type);
    // Pin label override picked up from `.pins.ix = .{ .label = "Impulse X" }`.
    try std.testing.expectEqualStrings("ix", group.flow_nodes[0].pins[1].name);
    try std.testing.expectEqualStrings("Impulse X", group.flow_nodes[0].pins[1].label);
    try std.testing.expectEqualStrings("f32", group.flow_nodes[0].pins[1].zig_type);

    try std.testing.expectEqual(@as(usize, 1), group.pin_styles.len);
    try std.testing.expectEqualStrings("BodyId", group.pin_styles[0].zig_type);
    try std.testing.expectEqualStrings("Body", group.pin_styles[0].label);
    try std.testing.expectEqual(@as(u8, 80), group.pin_styles[0].color[0]);
    try std.testing.expectEqual(@as(u8, 200), group.pin_styles[0].color[1]);
    try std.testing.expectEqual(@as(u8, 200), group.pin_styles[0].color[2]);
}

test "discoverInSource: reporter (non-void return) gets an output pin and reporter kind" {
    const src =
        \\const flow = @import("flow");
        \\pub const FlowNodes = struct {
        \\    pub const get_mass = flow.FlowNode(.{
        \\        .impl = getMassImpl,
        \\    });
        \\};
        \\fn getMassImpl(game: anytype, entity: u32) f32 {
        \\    _ = game; _ = entity;
        \\    return 0;
        \\}
        \\
    ;
    const aa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(aa);
    defer arena.deinit();
    const group = (try discoverInSource(arena.allocator(), src, "box2d")).?;
    try std.testing.expectEqualStrings("reporter", group.flow_nodes[0].kind);
    // 1 input (entity) + 1 output (return type).
    try std.testing.expectEqual(@as(usize, 2), group.flow_nodes[0].pins.len);
    try std.testing.expectEqualStrings("input", group.flow_nodes[0].pins[0].dir);
    try std.testing.expectEqualStrings("output", group.flow_nodes[0].pins[1].dir);
    try std.testing.expectEqualStrings("f32", group.flow_nodes[0].pins[1].zig_type);
    try std.testing.expectEqualStrings("f32", group.flow_nodes[0].return_type.?);
}

test "discoverInSource: returns null when neither block is declared" {
    const src =
        \\pub fn helper() void {}
        \\
    ;
    const aa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(aa);
    defer arena.deinit();
    const result = try discoverInSource(arena.allocator(), src, "noop");
    try std.testing.expect(result == null);
}

test "JSON output round-trips through std.json.parse" {
    const aa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(aa);
    defer arena.deinit();
    const ag = arena.allocator();

    var pins: std.ArrayList(PinDetail) = .empty;
    try pins.append(ag, .{ .name = "entity", .label = "Entity", .zig_type = "u32", .dir = "input", .default = null });
    try pins.append(ag, .{ .name = "result", .label = "Result", .zig_type = "f32", .dir = "output", .default = null });

    var nodes: std.ArrayList(FlowNodeEntry) = .empty;
    try nodes.append(ag, .{
        .qualified = "box2d.get_mass",
        .category = "box2d",
        .display_name = "Get Mass",
        .docs = "Read the body's mass (kg).",
        .kind = "reporter",
        .pins = try pins.toOwnedSlice(ag),
        .return_type = "f32",
    });

    var styles: std.ArrayList(PinStyleEntry) = .empty;
    try styles.append(ag, .{ .zig_type = "BodyId", .label = "Body", .color = .{ 80, 200, 200 } });

    var groups: std.ArrayList(ModuleGroup) = .empty;
    try groups.append(ag, .{
        .name = "box2d",
        .flow_nodes = try nodes.toOwnedSlice(ag),
        .pin_styles = try styles.toOwnedSlice(ag),
    });

    var alloc_writer: std.Io.Writer.Allocating = .init(aa);
    defer alloc_writer.deinit();
    try writeCatalogJson(&alloc_writer.writer, groups.items);

    // Borrow the writer's internal buffer; `alloc_writer.deinit()`
    // above frees the storage at end-of-test so we don't need to
    // round-trip through `toArrayList` / `toOwnedSlice`.
    const json_bytes = alloc_writer.writer.buffer[0..alloc_writer.writer.end];

    // Round-trip — assert we get valid JSON back with the expected
    // shape. We only check a few load-bearing fields; the rest is
    // visually verified.
    var parsed = try std.json.parseFromSlice(std.json.Value, aa, json_bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.contains("generated_at"));
    const plugins_arr = root.get("plugins").?.array;
    try std.testing.expectEqual(@as(usize, 1), plugins_arr.items.len);
    const plugin0 = plugins_arr.items[0].object;
    try std.testing.expectEqualStrings("box2d", plugin0.get("name").?.string);
    const flow_nodes_arr = plugin0.get("flow_nodes").?.array;
    try std.testing.expectEqual(@as(usize, 1), flow_nodes_arr.items.len);
    const node0 = flow_nodes_arr.items[0].object;
    try std.testing.expectEqualStrings("box2d.get_mass", node0.get("qualified").?.string);
    try std.testing.expectEqualStrings("reporter", node0.get("kind").?.string);
    try std.testing.expectEqualStrings("f32", node0.get("return_type").?.string);
    const pins_arr = node0.get("pins").?.array;
    try std.testing.expectEqual(@as(usize, 2), pins_arr.items.len);
}

test "emitFlowCatalogSidecar: writes a sidecar that round-trips to a parseable file" {
    const aa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = config.globalIo();
    const target_dir = try tmp.dir.realPathFileAlloc(io, ".", aa);
    defer aa.free(target_dir);

    // Empty cfg, no plugins, no scripts → empty `plugins` array.
    const cfg = ProjectConfig{ .name = "tmp" };
    const total = try emitFlowCatalogSidecar(aa, cfg, target_dir, target_dir, target_dir, &.{});
    try std.testing.expectEqual(@as(usize, 0), total);

    const path = try std.fs.path.join(aa, &.{ target_dir, SIDECAR_FILENAME });
    defer aa.free(path);

    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, path, aa, .limited(1 << 20));
    defer aa.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.contains("generated_at"));
    try std.testing.expectEqual(@as(usize, 0), root.get("plugins").?.array.items.len);
}
