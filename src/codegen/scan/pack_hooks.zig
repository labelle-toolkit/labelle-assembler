//! Pack hook-handler renaming extracted from `codegen/scan.zig`
//! (behavior-preserving split, labelle-assembler#534 follow-up).
//!
//! AST-level rewrite that renames a pack `hooks/*.zig` receiver's
//! bare-event handler decls to their `<pack>__`-prefixed tags so the
//! engine's dispatcher folds them into `GameEvents` correctly
//! (chatgpt-codex #3). Re-exported from the `scan.zig` barrel.

const std = @import("std");
const idents = @import("../idents.zig");

/// Rewrite a pack's copied `hooks/*.zig` source so a handler written with the
/// pack's BARE local event name receives its `<pack>__`-prefixed event
/// (chatgpt-codex finding #3).
///
/// The engine's hook dispatcher (`labelle-core/src/dispatcher.zig`) matches a
/// receiver's handler-fn NAME against the `GameEvents` variant tag. Pack
/// events are folded into `GameEvents` under the invisible `<pack>__<event>`
/// tag, so a pack hook's natural `pub fn worker_died(self, data)` would (a)
/// never receive `citizens__worker_died`, and worse (b) trip the dispatcher's
/// comptime guard — a 2-param handler whose name matches no variant is a hard
/// `@compileError`. To keep the prefix invisible, this renames each qualifying
/// handler's DECL to the prefixed tag (`worker_died` → `citizens__worker_died`)
/// in the copied source, exactly mirroring the JSONC key/prefab rewrite.
///
/// A handler qualifies only when it is a `pub fn`, takes exactly two
/// parameters (the `(self, data)` shape the dispatcher treats as a handler),
/// and its name equals the BASENAME/variant of one of the pack's own
/// `event_names` (`eventVariantName` — so a subdir event `combat/worker_died`
/// still matches a `pub fn worker_died`, since the emitted tag is
/// `<pack>__worker_died`) (chatgpt-codex L435). Handlers for engine / plugin /
/// game events (bare names that are already valid variant tags — e.g. `tick`,
/// `game_init`) are left untouched, so a pack hook keeps receiving those. Only
/// the declaration site is renamed; a pack that also calls its handler
/// internally by the bare name would surface a clean compile error rather than
/// a silent mis-dispatch.
///
/// **Receiver-scoped (CodeRabbit L435).** The rename is confined to the DIRECT
/// members of the hook file's receiver container — the `pub const <Pascal> =
/// struct { … }` whose name is `pathToPascal(hook_stem)` (the exact type the
/// generated `GameHooks` tuple references). Top-level `pub fn`s and unrelated
/// helper structs elsewhere in the file are never touched, so a helper API that
/// happens to share an event name (and arity) keeps its name and any internal
/// callers stay valid.
///
/// Returns an allocator-owned buffer; a content-preserving dupe when nothing
/// matches, so the caller frees unconditionally.
pub fn rewritePackHookHandlerNames(
    allocator: std.mem.Allocator,
    src: []const u8,
    event_names: []const []const u8,
    prefix: []const u8,
    hook_stem: []const u8,
) ![]u8 {
    if (event_names.len == 0) return allocator.dupe(u8, src);

    var receiver_buf: [128]u8 = undefined;
    const receiver = idents.pathToPascal(hook_stem, &receiver_buf);

    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    var ast = try std.zig.Ast.parse(allocator, src_z, .zig);
    defer ast.deinit(allocator);

    // Collect the byte offsets of every handler-fn name token to rename —
    // scoped to the receiver container so unrelated decls are never renamed.
    var sites: std.ArrayList(usize) = .empty;
    defer sites.deinit(allocator);
    try collectReceiverHandlerNameOffsets(allocator, &ast, ast.rootDecls(), receiver, event_names, &sites);

    if (sites.items.len == 0) return allocator.dupe(u8, src);
    std.mem.sort(usize, sites.items, {}, std.sort.asc(usize));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    for (sites.items) |off| {
        // Each recorded offset is the start of a bare event-name token. Emit
        // everything up to it, then the `<prefix>__` insertion; the original
        // name bytes follow untouched (cursor advances past the prefix only).
        try out.appendSlice(allocator, src[cursor..off]);
        try out.appendSlice(allocator, prefix);
        try out.appendSlice(allocator, "__");
        cursor = off;
    }
    try out.appendSlice(allocator, src[cursor..]);
    return out.toOwnedSlice(allocator);
}

/// Find the hook file's receiver container — the root-level
/// `const <receiver> = struct/union/enum { … }` whose name is the Pascal form
/// of the hook stem — and collect the byte offsets of its DIRECT handler-fn
/// name tokens into `sites`. Only that one container is walked, and its members
/// are NOT recursed into, so top-level helpers and unrelated helper structs are
/// never renamed (CodeRabbit L435). See `rewritePackHookHandlerNames`.
fn collectReceiverHandlerNameOffsets(
    allocator: std.mem.Allocator,
    ast: *std.zig.Ast,
    root_decls: []const std.zig.Ast.Node.Index,
    receiver: []const u8,
    event_names: []const []const u8,
    sites: *std.ArrayList(usize),
) !void {
    for (root_decls) |decl| {
        const vd = ast.fullVarDecl(decl) orelse continue;
        const name_tok = vd.ast.mut_token + 1;
        if (!std.mem.eql(u8, ast.tokenSlice(name_tok), receiver)) continue;
        const init_node = vd.ast.init_node.unwrap() orelse continue;
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const container = ast.fullContainerDecl(&buf, init_node) orelse continue;
        collectDirectHandlerNameOffsets(allocator, ast, container.ast.members, event_names, sites) catch |e| return e;
        // Exactly one receiver container matters; stop after the first match.
        return;
    }
}

/// Record the source byte offset of each qualifying `pub fn <event>(self, data)`
/// name token among `members` (the receiver's DIRECT members — no recursion).
/// A handler matches when its name equals the basename/variant of a pack event.
fn collectDirectHandlerNameOffsets(
    allocator: std.mem.Allocator,
    ast: *std.zig.Ast,
    members: []const std.zig.Ast.Node.Index,
    event_names: []const []const u8,
    sites: *std.ArrayList(usize),
) !void {
    for (members) |m| {
        var fn_buf: [1]std.zig.Ast.Node.Index = undefined;
        const fp = ast.fullFnProto(&fn_buf, m) orelse continue;
        if (fp.visib_token == null) continue;
        const nt = fp.name_token orelse continue;
        const name = ast.tokenSlice(nt);
        if (matchesEventBasename(event_names, name) and fnProtoParamCount(ast, fp) == 2) {
            // `tokenSlice` returns a sub-slice of `ast.source`; its pointer
            // offset is the byte position we splice at.
            const off = @intFromPtr(name.ptr) - @intFromPtr(ast.source.ptr);
            try sites.append(allocator, off);
        }
    }
}

/// True iff `handler_name` equals the emitted variant BASENAME of one of the
/// pack's `event_names` (`eventVariantName` strips any subdir + `.zig`), so a
/// handler `pub fn worker_died` matches a pack event scanned as
/// `combat/worker_died` (chatgpt-codex L435).
fn matchesEventBasename(event_names: []const []const u8, handler_name: []const u8) bool {
    for (event_names) |e| {
        if (std.mem.eql(u8, idents.eventVariantName(e), handler_name)) return true;
    }
    return false;
}

fn fnProtoParamCount(ast: *std.zig.Ast, fp: std.zig.Ast.full.FnProto) usize {
    var count: usize = 0;
    var it = fp.iterate(ast);
    while (it.next()) |_| count += 1;
    return count;
}

// ── Tests (moved verbatim from scan.zig) ─────────────────────────────

test "rewritePackHookHandlerNames: bare pack-event handler is renamed to the prefixed tag (chatgpt-codex #3)" {
    const allocator = std.testing.allocator;
    // A pack hook: a handler for the pack's OWN event (`worker_died`, bare),
    // plus a handler for a built-in engine event (`tick`, must stay bare so it
    // keeps matching the un-prefixed engine variant), plus a private helper
    // that happens to share the event name (must NOT be renamed).
    const src =
        \\const std = @import("std");
        \\pub const Overlay = struct {
        \\    pub fn worker_died(self: *Overlay, data: anytype) void {
        \\        _ = self;
        \\        _ = data;
        \\    }
        \\    pub fn tick(self: *Overlay, data: anytype) void {
        \\        _ = self;
        \\        _ = data;
        \\    }
        \\    fn helper(self: *Overlay) void {
        \\        _ = self;
        \\    }
        \\};
    ;
    const out = try rewritePackHookHandlerNames(allocator, src, &.{"worker_died"}, "citizens", "overlay");
    defer allocator.free(out);

    // The pack-event handler DECL is renamed to the prefixed tag …
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn citizens__worker_died(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn worker_died(") == null);
    // … the engine-event handler keeps its bare name …
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn tick(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "citizens__tick") == null);
    // … the private helper (not a pack event) is untouched.
    try std.testing.expect(std.mem.indexOf(u8, out, "fn helper(") != null);
}

test "rewritePackHookHandlerNames: subdir pack event matches a bare handler (codex L435)" {
    const allocator = std.testing.allocator;
    // Pack event scanned as `combat/worker_died`; the emitted tag is
    // `citizens__worker_died`, so a `pub fn worker_died` must be renamed.
    const src =
        \\pub const Overlay = struct {
        \\    pub fn worker_died(self: *Overlay, data: anytype) void {
        \\        _ = self;
        \\        _ = data;
        \\    }
        \\};
    ;
    const out = try rewritePackHookHandlerNames(allocator, src, &.{"combat/worker_died"}, "citizens", "overlay");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn citizens__worker_died(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn worker_died(") == null);
}

test "rewritePackHookHandlerNames: a top-level helper fn is NOT renamed (CR L435)" {
    const allocator = std.testing.allocator;
    // A top-level `pub fn worker_died(_, _)` helper (2 params, name matches the
    // event) sits OUTSIDE the receiver container — it must be left alone. Only
    // the same-named method INSIDE the `Overlay` receiver is renamed.
    const src =
        \\pub fn worker_died(a: u32, b: u32) u32 {
        \\    return a + b;
        \\}
        \\pub const Overlay = struct {
        \\    pub fn worker_died(self: *Overlay, data: anytype) void {
        \\        _ = self;
        \\        _ = worker_died(1, 2);
        \\        _ = data;
        \\    }
        \\};
    ;
    const out = try rewritePackHookHandlerNames(allocator, src, &.{"worker_died"}, "citizens", "overlay");
    defer allocator.free(out);
    // The top-level helper decl keeps its bare name …
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn worker_died(a: u32, b: u32) u32") != null);
    // … the receiver method is renamed …
    try std.testing.expect(std.mem.indexOf(u8, out, "pub fn citizens__worker_died(self: *Overlay") != null);
    // … and the internal call to the helper still resolves (unchanged).
    try std.testing.expect(std.mem.indexOf(u8, out, "_ = worker_died(1, 2);") != null);
}

test "rewritePackHookHandlerNames: no pack events is a content-preserving dupe" {
    const allocator = std.testing.allocator;
    const src = "pub const H = struct { pub fn tick(self: *H, d: anytype) void { _ = self; _ = d; } };";
    const out = try rewritePackHookHandlerNames(allocator, src, &.{}, "citizens", "h");
    defer allocator.free(out);
    try std.testing.expectEqualStrings(src, out);
}
