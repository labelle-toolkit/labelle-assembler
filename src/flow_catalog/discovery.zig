//! Source-walk discovery for the flow catalog: parse a plugin or
//! game-script source file with `std.zig.Ast`, walk its
//! `pub const FlowNodes / PinStyles / Events / Coercions` blocks, and
//! produce typed `ModuleGroup` entries. Extracted from the original
//! `src/flow_catalog.zig` as part of the per-concern split
//! (labelle-assembler#186).
//!
//! See the doc-comment on `src/flow_catalog.zig` for the discovery
//! algorithm overview; this module hosts the concrete `extract*` and
//! `discoverInSource` implementations.

const std = @import("std");
const types = @import("types.zig");
const scanners = @import("scanners.zig");

const PinDetail = types.PinDetail;
const FlowNodeEntry = types.FlowNodeEntry;
const PinStyleEntry = types.PinStyleEntry;
const CoercionEntry = types.CoercionEntry;
const EventEntry = types.EventEntry;
const ModuleGroup = types.ModuleGroup;

/// Build a `<module>` label for a game-script `rel_path`. Strips a
/// trailing `.zig` and replaces `/` with `.` so a nested script reads
/// naturally as a palette section heading. `flows/hit_counter.zig`
/// becomes `flows.hit_counter`; the editor's `CustomNode.name`
/// references on disk match this dotted form prefix-wise.
pub fn scriptModuleLabel(aa: std.mem.Allocator, rel_path: []const u8) ![]const u8 {
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
pub fn discoverInSource(aa: std.mem.Allocator, src: []const u8, module_name: []const u8) !?ModuleGroup {
    const src_z = try aa.dupeZ(u8, src);

    var ast = try std.zig.Ast.parse(aa, src_z, .zig);
    defer ast.deinit(aa);

    var nodes: std.ArrayList(FlowNodeEntry) = .empty;
    var styles: std.ArrayList(PinStyleEntry) = .empty;
    var events: std.ArrayList(EventEntry) = .empty;
    var coercions: std.ArrayList(CoercionEntry) = .empty;

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
        const is_events = std.mem.eql(u8, decl_name, "Events");
        const is_coercions = std.mem.eql(u8, decl_name, "Coercions");
        if (!is_flow_nodes and !is_pin_styles and !is_events and !is_coercions) continue;

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
            } else if (is_pin_styles) {
                const entry = extractPinStyleEntry(
                    aa,
                    &ast,
                    member_name,
                    member_init,
                ) catch continue;
                try styles.append(aa, entry);
                found_anything = true;
            } else if (is_events) {
                // Events block (labelle-engine#578). Only valid
                // shape is `pub const <name> = struct { ... };`.
                if (ast.fullContainerDecl(&buf, member_init) == null) continue;
                const entry = extractEventEntry(
                    aa,
                    &ast,
                    member_name,
                    member_init,
                    module_name,
                ) catch continue;
                try events.append(aa, entry);
                found_anything = true;
            } else {
                // Coercions block (RFC-FLOW-VOCABULARY §2 / O4). The
                // factory call shape is
                // `labelle.flow.Coercion(.{ .impl = <fn> })`. We pull
                // the impl name out of the call, then walk back to the
                // fn's parameter list + return type to capture
                // From/To Zig source text.
                const entry = extractCoercionEntry(
                    aa,
                    &ast,
                    member_name,
                    member_init,
                    module_name,
                ) catch continue;
                try coercions.append(aa, entry);
                found_anything = true;
            }
        }
    }

    if (!found_anything) return null;
    return ModuleGroup{
        .name = try aa.dupe(u8, module_name),
        .flow_nodes = try nodes.toOwnedSlice(aa),
        .pin_styles = try styles.toOwnedSlice(aa),
        .events = try events.toOwnedSlice(aa),
        .coercions = try coercions.toOwnedSlice(aa),
    };
}

/// Pull `from_zig_type` + `to_zig_type` + `docs` out of a
/// `labelle.flow.Coercion(.{ .impl = <ident>, .docs = "..." })` init.
/// `impl` is resolved through the same source's root decls; its single
/// parameter's type source and return-type source become `from` and
/// `to`. A non-resolvable `impl` (defined in a sibling file) degrades
/// to empty strings — the editor + flow-codegen fall back to refusing
/// the wire in that case, same shape as the FlowNode pin walk.
pub fn extractCoercionEntry(
    aa: std.mem.Allocator,
    ast: *std.zig.Ast,
    decl_name: []const u8,
    init_node: std.zig.Ast.Node.Index,
    module_name: []const u8,
) !CoercionEntry {
    const init_src = ast.getNodeSource(init_node);
    const cfg_src = scanners.innerCallArg(init_src);

    const impl_name = scanners.scanFieldIdent(cfg_src, ".impl") orelse "";
    const docs = scanners.scanFieldStringDup(aa, cfg_src, ".docs") catch null;

    var from: []const u8 = "";
    var to: []const u8 = "";

    if (impl_name.len > 0) {
        if (scanners.findFnByName(ast, impl_name)) |fn_node| {
            var fn_buf: [1]std.zig.Ast.Node.Index = undefined;
            if (ast.fullFnProto(&fn_buf, fn_node)) |fp| {
                // A coercion's impl takes a single value parameter
                // (the labelle-core factory rejects multi-param impls
                // at comptime). Capture the first param's type source.
                var it = fp.iterate(ast);
                if (it.next()) |param| {
                    if (param.type_expr) |ptype_node| {
                        from = try aa.dupe(u8, ast.getNodeSource(ptype_node));
                    }
                }
                if (fp.ast.return_type.unwrap()) |rt_node| {
                    to = try aa.dupe(u8, ast.getNodeSource(rt_node));
                }
            }
        }
    }

    return .{
        .qualified = try std.fmt.allocPrint(aa, "{s}.{s}", .{ module_name, decl_name }),
        .name = try aa.dupe(u8, decl_name),
        .from_zig_type = if (from.len == 0) try aa.dupe(u8, "") else from,
        .to_zig_type = if (to.len == 0) try aa.dupe(u8, "") else to,
        .docs = docs orelse try aa.dupe(u8, ""),
    };
}

/// Pull payload-field metadata out of an `Events` decl's struct
/// init: `pub const tick = struct { dt: f32 }`. Each field of the
/// inner struct becomes one output `PinDetail` so the editor's
/// `Event` node can route the field as a typed source pin.
pub fn extractEventEntry(
    aa: std.mem.Allocator,
    ast: *std.zig.Ast,
    decl_name: []const u8,
    init_node: std.zig.Ast.Node.Index,
    module_name: []const u8,
) !EventEntry {
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const container = ast.fullContainerDecl(&buf, init_node) orelse return error.NotAStruct;

    var pin_list: std.ArrayList(PinDetail) = .empty;
    for (container.ast.members) |m| {
        // Only field members count — skip nested decls (Zig allows
        // `pub const Foo = ...` inside a struct, but a payload that
        // declares nested types is not a flat field-bag and we
        // don't have a meaningful pin to emit for them).
        const fd = ast.fullContainerField(m) orelse continue;
        const fname_tok = fd.ast.main_token;
        const fname = ast.tokenSlice(fname_tok);
        const ftype_node = fd.ast.type_expr.unwrap() orelse continue;
        const ftype = ast.getNodeSource(ftype_node);

        const label = try scanners.titlecaseFromIdent(aa, fname);
        try pin_list.append(aa, .{
            .name = try aa.dupe(u8, fname),
            .label = label,
            .zig_type = try aa.dupe(u8, ftype),
            .dir = "output",
            .default = null,
        });
    }

    return .{
        .qualified = try std.fmt.allocPrint(aa, "{s}.{s}", .{ module_name, decl_name }),
        .name = try aa.dupe(u8, decl_name),
        .pins = try pin_list.toOwnedSlice(aa),
    };
}

/// Pull out FlowNode metadata from a `labelle.FlowNode(.{...})` init
/// node — including walking back into the impl function's parameter
/// list for pin names and types.
pub fn extractFlowNodeEntry(
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
    const cfg_src = scanners.innerCallArg(init_src);

    const impl_name = scanners.scanFieldIdent(cfg_src, ".impl") orelse "";
    const docs = scanners.scanFieldStringDup(aa, cfg_src, ".docs") catch null;
    const explicit_kind = scanners.scanFieldEnumLit(cfg_src, ".kind"); // ".command" or ".reporter" or null
    const display_name = scanners.scanFieldStringDup(aa, cfg_src, ".display_name") catch null;
    const category_override = scanners.scanFieldStringDup(aa, cfg_src, ".category") catch null;

    // ── Pins ──
    // Walk the impl function's parameter list (skip the first
    // `game: anytype` per RFC §1). Each remaining param becomes one
    // input pin. The return type, when non-void, becomes the output
    // pin appended after the inputs.
    var pin_list: std.ArrayList(PinDetail) = .empty;
    var return_type: ?[]const u8 = null;
    var has_return = false;

    if (impl_name.len > 0) {
        if (scanners.findFnByName(ast, impl_name)) |fn_node| {
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

                    const label = try scanners.resolvePinLabel(aa, cfg_src, pname);
                    const default = scanners.scanPinDefault(aa, cfg_src, pname) catch null;
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
    const dn = display_name orelse try scanners.titlecaseFromIdent(aa, decl_name);

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
pub fn extractPinStyleEntry(
    aa: std.mem.Allocator,
    ast: *std.zig.Ast,
    decl_name: []const u8,
    init_node: std.zig.Ast.Node.Index,
) !PinStyleEntry {
    const init_src = ast.getNodeSource(init_node);
    const label = (try scanners.scanFieldStringDup(aa, init_src, ".label")) orelse try aa.dupe(u8, decl_name);
    const color = scanners.scanColorTriple(init_src) orelse [3]u8{ 200, 200, 200 };
    return .{
        .zig_type = try aa.dupe(u8, decl_name),
        .label = label,
        .color = color,
    };
}
