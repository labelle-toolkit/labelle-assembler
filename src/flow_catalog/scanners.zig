//! Low-level AST helpers and source-text scanners shared by
//! `discovery.zig`. Extracted from the original `src/flow_catalog.zig`
//! as part of the per-concern split (labelle-assembler#186).
//!
//! The FlowNode + PinStyle config literals are tiny, deeply structured,
//! and stable in shape across the toolkit. A focused text scan keyed off
//! the field names is far less code than a full struct-init walk for
//! the depth we need, and degrades gracefully when a future field
//! migration moves things around (we just stop seeing the field and the
//! editor uses defaults).
//!
//! All scanners take a slice that's already known to be the source text
//! of a single struct-init literal — `getNodeSource(init_node)`, or its
//! inner-paren form for a `Foo(.{...})` call.

const std = @import("std");

// ─── AST helpers ────────────────────────────────────────────────────────

/// Find a top-level `fn <name>(...) ...` declaration in the parsed AST
/// and return its `fn_decl` node index. Returns `null` when the
/// function isn't visible at module scope — that's the case for impls
/// imported from a sibling file, which we surface as "no pin info" in
/// the catalog rather than failing the whole sidecar build.
pub fn findFnByName(ast: *std.zig.Ast, name: []const u8) ?std.zig.Ast.Node.Index {
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

/// Strip the outer `Foo(...)` so we end up with the call's first
/// argument's source. If the source doesn't look like a single-arg
/// call, return it unchanged — the field scanners are defensive.
pub fn innerCallArg(src: []const u8) []const u8 {
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
pub fn locateField(src: []const u8, field: []const u8) ?[]const u8 {
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
pub fn scanFieldIdent(src: []const u8, field: []const u8) ?[]const u8 {
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
pub fn scanFieldEnumLit(src: []const u8, field: []const u8) ?[]const u8 {
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
pub fn scanFieldStringDup(aa: std.mem.Allocator, src: []const u8, field: []const u8) !?[]const u8 {
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
pub fn scanColorTriple(src: []const u8) ?[3]u8 {
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
pub fn scanU8Field(src: []const u8, field: []const u8) ?u8 {
    const rhs = locateField(src, field) orelse return null;
    var end: usize = 0;
    while (end < rhs.len and rhs[end] >= '0' and rhs[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(u8, rhs[0..end], 10) catch null;
}

/// Resolve the display label for a pin: check the FlowNode config's
/// `.pins.<name>.label` override, else titlecase `pname`. Returns an
/// owned dupe in `aa`.
pub fn resolvePinLabel(aa: std.mem.Allocator, cfg_src: []const u8, pname: []const u8) ![]const u8 {
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
pub fn scanPinDefault(aa: std.mem.Allocator, cfg_src: []const u8, pname: []const u8) !?[]const u8 {
    const pins_rhs = locateField(cfg_src, ".pins") orelse return null;
    var field_buf: [128]u8 = undefined;
    const field = std.fmt.bufPrint(&field_buf, ".{s}", .{pname}) catch return null;
    const pin_rhs = locateField(pins_rhs, field) orelse return null;
    return try scanFieldStringDup(aa, pin_rhs, ".default");
}

/// Map an identifier like `apply_impulse` to a titlecased display form
/// (`Apply Impulse`). Splits on `_` and capitalises the first letter
/// of each component. Returns an owned dupe.
pub fn titlecaseFromIdent(aa: std.mem.Allocator, ident: []const u8) ![]const u8 {
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
