//! FlowNodes / PinStyles / Coercions discovery extracted from
//! `codegen/scan.zig` (behavior-preserving split, labelle-assembler#534
//! follow-up).
//!
//! RFC-FLOW-VOCABULARY phase 2: walks plugin `src/root.zig` and game
//! scripts for `pub const FlowNodes` / `PinStyles` / `Coercions` blocks,
//! collecting the `Plugin*` registry entries the editor and flow-codegen
//! consume. Re-exported from the `scan.zig` barrel.

const std = @import("std");
const config = @import("../../config.zig");
const cache = @import("../../cache.zig");
const script_scanner = @import("../../script_scanner.zig");
const scanners = @import("../../flow_catalog/scanners.zig");
const sanitize = @import("sanitize.zig");
const sanitizePluginIdent = sanitize.sanitizePluginIdent;
const pathToIdent = sanitize.pathToIdent;

const ProjectConfig = config.ProjectConfig;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;

// ── RFC-FLOW-VOCABULARY phase 2 — FlowNodes + PinStyles discovery ──────
//
// Walk each plugin's `src/root.zig` and each game-script `.zig` file for
// `pub const FlowNodes` and `pub const PinStyles` declarations. The
// convention parallels `Events` / `Components` / `Systems`:
//
//   pub const FlowNodes = struct {
//       pub const apply_impulse = labelle.FlowNode(.{ .impl = applyImpulseImpl });
//       pub const get_velocity  = labelle.FlowNode(.{ .impl = getVelocityImpl });
//   };
//
//   pub const PinStyles = struct {
//       pub const BodyId = labelle.PinStyle{ .label = "Body", .color = ... };
//   };
//
// Per RFC §5, any module under the project tree (plugins OR game
// scripts) that exports `FlowNodes` is a palette source. The
// emitted `PluginFlowNodes` registry the editor and flow-codegen
// (phase 3 `CustomNode` lowering) consume is keyed by a
// plugin-qualified identifier (`<module>__<name>`), same convention
// as `PluginEvents`, so a flow's on-disk dotted name
// (`box2d.apply_impulse`) maps to a Zig identifier
// (`box2d__apply_impulse`).
//
// Phase 5 (parallel ticket) adds the actual `FlowNodes` declarations
// to labelle-box2d; this discovery is the first real consumer.

/// One discovered `pub const <name> = labelle.FlowNode(...)` decl
/// inside a `pub const FlowNodes = struct { ... }` block. Both the
/// import path and the module-qualified identifier are kept so the
/// emitter can write the registry entry verbatim without re-deriving
/// either at codegen time.
pub const PluginFlowNode = struct {
    /// Identifier used by Zig's `@import(...)` for the source
    /// module. For plugins, this is the project.labelle `.name` (the
    /// same string `@import` resolves against in the generated
    /// main.zig). For game-script modules, this is the relative path
    /// under `scripts/` (e.g. `hits.zig` or `flows/hit_counter.zig`),
    /// emitted as `@import("scripts/<rel_path>")` to match how
    /// `all_scripts_block` already references game scripts.
    module_import_path: []const u8,
    /// Sanitized identifier form of the source module. For plugins
    /// this is the same `sanitizePluginIdent` output as
    /// `PluginEvent.plugin_sanitized` (e.g. `labelle-box2d` →
    /// `labelle_box2d`). For game-script modules this is
    /// `pathToIdent` of the rel_path (escaped per the standard
    /// path→ident mapping so `flows/hit_counter.zig` becomes
    /// `flows_s_hit_u_counter`). Used as the prefix in the qualified
    /// registry decl name `<module_sanitized>__<node_name>`.
    module_sanitized: []const u8,
    /// Bare node identifier as declared inside `FlowNodes` (e.g.
    /// `apply_impulse`).
    node_name: []const u8,
    /// `true` when the source is a game-script module; `false` for
    /// plugin modules. Drives which `@import` form the emitter
    /// writes — plugins resolve as `@import("<name>")`, scripts as
    /// `@import("scripts/<rel_path>")`.
    is_script: bool,
    /// `true` when the node's `impl` fn returns `void` — a **command**
    /// (RFC-FLOW-VOCABULARY §6). flow-codegen's `CustomNode` lowering
    /// emits a bare statement for commands and binds the result to
    /// `n<id>_value` for reporters (non-void). The assembler computes
    /// this once at discovery time so flow-codegen consumes the
    /// precomputed flag rather than re-reflecting the impl. An explicit
    /// `.kind = .command` / `.kind = .reporter` in the FlowNode factory
    /// call overrides the inferred return-type default — same rule the
    /// editor catalog applies in `flow_catalog/discovery.zig`.
    is_void: bool = true,
    /// Fully-qualified Zig type name the node constructs, captured
    /// from a `.constructs = "..."` field in the source `FlowNode`
    /// factory call, or `null` when the source omits it
    /// (RFC-FLOW-VOCABULARY §1, open question O5). The string is
    /// extracted textually from the init expression — the AST scan
    /// doesn't evaluate the factory call, so the source must spell
    /// the value as a literal `"..."` string. Threaded through to
    /// the editor (phase 4) so the palette can suggest constructor
    /// nodes for struct-typed `SetVariable` targets.
    constructs: ?[]const u8 = null,
};

/// One discovered `pub const <TypeName> = labelle.PinStyle{ ... }`
/// decl inside a `pub const PinStyles = struct { ... }` block. The
/// editor merges these on top of `default_pin_styles`; per RFC §1,
/// later declarations win for duplicate type keys, so the assembler
/// dedups by `type_name` (last-write-wins) before emitting.
pub const PluginPinStyle = struct {
    /// Same shape as `PluginFlowNode.module_import_path`.
    module_import_path: []const u8,
    /// Same shape as `PluginFlowNode.module_sanitized`.
    module_sanitized: []const u8,
    /// Zig type name (e.g. `BodyId`). The emitted registry uses this
    /// verbatim as the decl name — duplicates across modules collapse
    /// to last-write-wins.
    type_name: []const u8,
    /// Same meaning as `PluginFlowNode.is_script`.
    is_script: bool,
};

/// One discovered `pub const <name> = labelle.flow.Coercion(...)` decl
/// inside a `pub const Coercions = struct { ... }` block
/// (RFC-FLOW-VOCABULARY §2 / O4). Same ownership pattern as
/// `PluginFlowNode` / `PluginPinStyle` — every string is a
/// heap-allocated dupe owned by the enclosing `PluginFlowDecls`.
///
/// The qualified emitted decl name is `<module_sanitized>__<name>`
/// matching the FlowNodes / Events convention.
pub const PluginCoercion = struct {
    /// Same shape as `PluginFlowNode.module_import_path`.
    module_import_path: []const u8,
    /// Same shape as `PluginFlowNode.module_sanitized`. Used as the
    /// `<module>__<name>` prefix on the emitted registry decl.
    module_sanitized: []const u8,
    /// Bare coercion identifier as declared inside `Coercions` (e.g.
    /// `body_to_entity`).
    name: []const u8,
    /// Same meaning as `PluginFlowNode.is_script`.
    is_script: bool,
};

/// Collection of discovered FlowNodes + PinStyles + Coercions with an
/// allocator-aware `deinit`. Same ownership story as `PluginEvents`
/// — every string field on every entry is a heap-allocated dupe so
/// callers need not keep source buffers alive.
pub const PluginFlowDecls = struct {
    flow_nodes: []PluginFlowNode,
    pin_styles: []PluginPinStyle,
    /// RFC-FLOW-VOCABULARY §2 / O4 — plugin-declared coercions. Empty
    /// when no module declares a `pub const Coercions` block; the
    /// emitter still writes an empty `PluginCoercions = struct {}`
    /// shell so downstream reflection (flow-codegen edge wrap) is
    /// uniform.
    coercions: []PluginCoercion,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PluginFlowDecls) void {
        for (self.flow_nodes) |fn_| {
            self.allocator.free(fn_.module_import_path);
            self.allocator.free(fn_.module_sanitized);
            self.allocator.free(fn_.node_name);
            if (fn_.constructs) |c| self.allocator.free(c);
        }
        self.allocator.free(self.flow_nodes);
        self.flow_nodes = &.{};
        for (self.pin_styles) |ps| {
            self.allocator.free(ps.module_import_path);
            self.allocator.free(ps.module_sanitized);
            self.allocator.free(ps.type_name);
        }
        self.allocator.free(self.pin_styles);
        self.pin_styles = &.{};
        for (self.coercions) |co| {
            self.allocator.free(co.module_import_path);
            self.allocator.free(co.module_sanitized);
            self.allocator.free(co.name);
        }
        self.allocator.free(self.coercions);
        self.coercions = &.{};
    }
};

/// Extract the literal string value of a `.constructs = "..."` field
/// from the source text of a `FlowNode(.{...})` factory call
/// (RFC-FLOW-VOCABULARY §1 / O5). Returns an allocator-owned dupe of
/// the unescaped value, or `null` when the field is absent / not a
/// plain string literal.
///
/// Scan strategy is deliberately tolerant: walks the source byte by
/// byte while tracking whether we're inside a string or comment, so a
/// `.constructs` keyword appearing inside another string (e.g. as part
/// of `.docs`) doesn't trigger a false match. Stops at the first
/// match — multiple `.constructs` fields aren't valid Zig anyway, so
/// "last wins" never comes into play. A truly malformed factory call
/// surfaces as a Zig compile error at the consumer site, not here.
fn extractConstructsString(allocator: std.mem.Allocator, src: []const u8) ?[]u8 {
    const needle = ".constructs";
    var i: usize = 0;
    while (i + needle.len <= src.len) : (i += 1) {
        const c = src[i];
        // Skip over Zig string literals so a `.docs = ".constructs = ..."`
        // doesn't false-match. The scanner only handles the `"..."`
        // form (no `\\` multiline strings) — the factory's typical
        // usage stays well within that subset.
        if (c == '"') {
            i += 1;
            while (i < src.len) : (i += 1) {
                if (src[i] == '\\' and i + 1 < src.len) {
                    i += 1; // skip escaped char
                    continue;
                }
                if (src[i] == '"') break;
            }
            continue;
        }
        // Skip line comments.
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') : (i += 1) {}
            continue;
        }
        if (!std.mem.startsWith(u8, src[i..], needle)) continue;
        // Verify the byte before isn't an identifier char — otherwise
        // we'd match `.subconstructs` or `.foo_constructs`.
        if (i > 0) {
            const prev = src[i - 1];
            if ((prev >= 'a' and prev <= 'z') or (prev >= 'A' and prev <= 'Z') or
                (prev >= '0' and prev <= '9') or prev == '_')
            {
                continue;
            }
        }
        // Verify the byte after the keyword isn't an identifier char
        // either (so `.constructs_x` is rejected).
        const after_kw = i + needle.len;
        if (after_kw < src.len) {
            const next = src[after_kw];
            if ((next >= 'a' and next <= 'z') or (next >= 'A' and next <= 'Z') or
                (next >= '0' and next <= '9') or next == '_')
            {
                continue;
            }
        }
        // Skip whitespace and the `=`, expect a `"..."` literal.
        var j = after_kw;
        while (j < src.len and (src[j] == ' ' or src[j] == '\t' or src[j] == '\n' or src[j] == '\r')) : (j += 1) {}
        if (j >= src.len or src[j] != '=') return null;
        j += 1;
        while (j < src.len and (src[j] == ' ' or src[j] == '\t' or src[j] == '\n' or src[j] == '\r')) : (j += 1) {}
        if (j >= src.len or src[j] != '"') return null;
        const start = j + 1;
        var k = start;
        while (k < src.len) : (k += 1) {
            if (src[k] == '\\' and k + 1 < src.len) {
                k += 1;
                continue;
            }
            if (src[k] == '"') break;
        }
        if (k >= src.len) return null;
        return allocator.dupe(u8, src[start..k]) catch null;
    }
    return null;
}

/// Resolve a FlowNode's command-vs-reporter shape — `true` for a
/// `void`-returning (command) impl, `false` for a value-returning
/// (reporter) one. Mirrors the editor-catalog rule in
/// `flow_catalog/discovery.zig` so the two discovery paths agree:
///
///   1. An explicit `.kind = .command` / `.kind = .reporter` in the
///      `labelle.FlowNode(.{...})` factory call always wins.
///   2. Otherwise the impl's declared return type decides: `void` (or
///      an impl we can't resolve / that omits a return type) is a
///      command; anything else is a reporter.
///
/// `init_src` is the FlowNode factory call's source text; `ast` is the
/// already-parsed module AST so we can walk back to the impl fn's
/// prototype. A non-resolvable `impl` (defined in a sibling file)
/// degrades to `is_void = true` — the command shape — matching the
/// catalog's "no pin info" fallback, since we have no return type to
/// promote it to a reporter.
fn flowNodeIsVoid(ast: *std.zig.Ast, init_src: []const u8) bool {
    const cfg_src = scanners.innerCallArg(init_src);

    // Explicit `.kind` override — same precedence as the catalog.
    if (scanners.scanFieldEnumLit(cfg_src, ".kind")) |ek| {
        if (std.mem.eql(u8, ek, "command")) return true;
        if (std.mem.eql(u8, ek, "reporter")) return false;
    }

    // Infer from the impl's return type. Skip the implicit
    // `game: anytype` — we only care about the return, not the params.
    const impl_name = scanners.scanFieldIdent(cfg_src, ".impl") orelse return true;
    if (impl_name.len == 0) return true;
    const fn_node = scanners.findFnByName(ast, impl_name) orelse return true;
    var fn_buf: [1]std.zig.Ast.Node.Index = undefined;
    const fp = ast.fullFnProto(&fn_buf, fn_node) orelse return true;
    const rt_node = fp.ast.return_type.unwrap() orelse return true;
    const rt = std.mem.trim(u8, ast.getNodeSource(rt_node), " \t\r\n");
    // A fallible command (`!void` / `anyerror!void`) is still a command —
    // the error union adds no output pin. Kept in lock-step with the
    // editor-catalog inference in `flow_catalog/discovery.zig`.
    return std.mem.eql(u8, rt, "void") or std.mem.endsWith(u8, rt, "!void");
}

/// Walk one `.zig` source buffer for `pub const FlowNodes`,
/// `pub const PinStyles`, and `pub const Coercions` decls, appending
/// each discovered nested member to the corresponding output list.
/// The three outputs share the same `module_import_path` /
/// `module_sanitized` / `is_script` values (passed in by the caller),
/// so the per-module identification is decided once at the call site
/// rather than re-derived per entry.
///
/// Buffer is the file contents; the caller owns it. The parsed AST
/// is local to this function; only `allocator.dupe`d strings outlive
/// the call.
fn scanFlowDeclsInSource(
    allocator: std.mem.Allocator,
    src: []const u8,
    module_import_path: []const u8,
    module_sanitized: []const u8,
    is_script: bool,
    flow_nodes_out: *std.ArrayList(PluginFlowNode),
    pin_styles_out: *std.ArrayList(PluginPinStyle),
    coercions_out: *std.ArrayList(PluginCoercion),
) !void {
    const src_z = try allocator.dupeZ(u8, src);
    defer allocator.free(src_z);

    var ast = try std.zig.Ast.parse(allocator, src_z, .zig);
    defer ast.deinit(allocator);

    const root_decls = ast.rootDecls();
    for (root_decls) |decl_idx| {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const vd = ast.fullVarDecl(decl_idx) orelse continue;
        // Non-pub helpers (e.g. an internal `const FlowNodes` used by
        // the module itself) are skipped silently — same precedent
        // `discoverPluginEvents` follows.
        if (vd.visib_token == null) continue;
        const name_tok = vd.ast.mut_token + 1;
        const decl_name = ast.tokenSlice(name_tok);

        const is_flow_nodes = std.mem.eql(u8, decl_name, "FlowNodes");
        const is_pin_styles = std.mem.eql(u8, decl_name, "PinStyles");
        const is_coercions = std.mem.eql(u8, decl_name, "Coercions");
        if (!is_flow_nodes and !is_pin_styles and !is_coercions) continue;

        const init_node = vd.ast.init_node.unwrap() orelse continue;
        const container = ast.fullContainerDecl(&buf, init_node) orelse continue;

        for (container.ast.members) |m| {
            const member_vd = ast.fullVarDecl(m) orelse continue;
            if (member_vd.visib_token == null) continue;
            // Skip non-value members defensively. The init token for a
            // `pub const apply_impulse = labelle.FlowNode(.{...})` is
            // always present; a `pub const X: T = …` (typed) decl also
            // exposes init_node. The `unwrap()` filter just ensures we
            // never trip on a malformed entry.
            const member_init = member_vd.ast.init_node.unwrap() orelse continue;

            const member_name_tok = member_vd.ast.mut_token + 1;
            const member_name = ast.tokenSlice(member_name_tok);

            if (is_flow_nodes) {
                // RFC-FLOW-VOCABULARY §1 / O5 — capture an optional
                // `.constructs = "..."` field from the factory call's
                // source text. The scanner doesn't evaluate the
                // expression (would require a full compile), so it
                // extracts the literal string verbatim. A non-string
                // `.constructs` (e.g. a comptime expression) is
                // silently ignored — that's a forward-compatible
                // refinement, not a contract worth enforcing here.
                const init_src = ast.getNodeSource(member_init);
                // Errdefer-per-allocation: `constructs_value` is an
                // optional dupe owned by `extractConstructsString`;
                // it leaks if any subsequent dupe or the `append`
                // fails. Each errdefer is cancelled once `append`
                // moves ownership into the entry.
                const constructs_value = extractConstructsString(allocator, init_src);
                errdefer if (constructs_value) |c| allocator.free(c);

                // Command-vs-reporter shape (RFC-FLOW-VOCABULARY §6).
                // Resolved once here so flow-codegen's `CustomNode`
                // lowering consumes the precomputed flag — no allocation,
                // borrows nothing past this loop iteration.
                const is_void = flowNodeIsVoid(&ast, init_src);

                const duped_path = try allocator.dupe(u8, module_import_path);
                errdefer allocator.free(duped_path);
                const duped_sanitized = try allocator.dupe(u8, module_sanitized);
                errdefer allocator.free(duped_sanitized);
                const duped_name = try allocator.dupe(u8, member_name);
                errdefer allocator.free(duped_name);

                try flow_nodes_out.append(allocator, .{
                    .module_import_path = duped_path,
                    .module_sanitized = duped_sanitized,
                    .node_name = duped_name,
                    .is_script = is_script,
                    .is_void = is_void,
                    .constructs = constructs_value,
                });
            } else if (is_pin_styles) {
                const duped_path = try allocator.dupe(u8, module_import_path);
                errdefer allocator.free(duped_path);
                const duped_sanitized = try allocator.dupe(u8, module_sanitized);
                errdefer allocator.free(duped_sanitized);
                const duped_name = try allocator.dupe(u8, member_name);
                errdefer allocator.free(duped_name);

                try pin_styles_out.append(allocator, .{
                    .module_import_path = duped_path,
                    .module_sanitized = duped_sanitized,
                    .type_name = duped_name,
                    .is_script = is_script,
                });
            } else {
                // Coercions block (RFC-FLOW-VOCABULARY §2 / O4).
                // Same shape as FlowNodes — each member is a
                // `labelle.flow.Coercion(.{ .impl = ... })` factory
                // call; the assembler doesn't need to peer inside the
                // call because the From/To types are resolved at
                // comptime in the emitted alias and surfaced via
                // reflection (`PluginCoercions.<qualified>.From` etc.).
                // The flow_catalog sidecar (parallel walk in
                // `flow_catalog.zig`) extracts the textual types for
                // the editor's wire-fit check.
                const duped_path = try allocator.dupe(u8, module_import_path);
                errdefer allocator.free(duped_path);
                const duped_sanitized = try allocator.dupe(u8, module_sanitized);
                errdefer allocator.free(duped_sanitized);
                const duped_name = try allocator.dupe(u8, member_name);
                errdefer allocator.free(duped_name);

                try coercions_out.append(allocator, .{
                    .module_import_path = duped_path,
                    .module_sanitized = duped_sanitized,
                    .name = duped_name,
                    .is_script = is_script,
                });
            }
        }
    }
}

/// Discover `pub const FlowNodes` and `pub const PinStyles` decls
/// across both plugin modules and game-script modules.
///
/// **Plugins** are walked via `<plugin>/src/root.zig` (same convention
/// as `discoverPluginEvents`). Plugins without a `FlowNodes` or
/// `PinStyles` decl contribute zero entries — the back-compat path
/// every existing plugin takes today.
///
/// **Game scripts** are walked from `scripts_root`. Each
/// `ScriptEntry` whose `plugin_name == null` (i.e. game-owned, not a
/// plugin-shipped script) is parsed from
/// `<scripts_root>/<entry.rel_path>`. Per RFC §5, any module in the
/// project tree that exports `FlowNodes` is a palette source — the
/// canonical example is `bouncing-ball/scripts/hits.zig`.
///
/// Plugin-shipped scripts (those with `entry.plugin_name != null`,
/// which live under `<scripts_root>/.plugin_<name>/...`) are skipped
/// here: their containing plugin already gets walked at its
/// `src/root.zig` root decl level. Re-walking them as game scripts
/// would double-count entries and break the qualified-name
/// convention.
///
/// Missing source files / parse errors on individual modules are
/// skipped silently rather than failing the whole `generate` —
/// matches the `discoverPluginEvents` tolerance for plugins without
/// a `src/root.zig`. A genuinely broken script will surface its
/// error later when the generated `main.zig` tries to compile it.
pub fn discoverPluginFlowDecls(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    project_dir: []const u8,
    scripts_root: []const u8,
    script_entries: []const ScriptEntry,
) !PluginFlowDecls {
    var flow_nodes: std.ArrayList(PluginFlowNode) = .empty;
    errdefer {
        for (flow_nodes.items) |e| {
            allocator.free(e.module_import_path);
            allocator.free(e.module_sanitized);
            allocator.free(e.node_name);
            if (e.constructs) |c| allocator.free(c);
        }
        flow_nodes.deinit(allocator);
    }
    var pin_styles: std.ArrayList(PluginPinStyle) = .empty;
    errdefer {
        for (pin_styles.items) |e| {
            allocator.free(e.module_import_path);
            allocator.free(e.module_sanitized);
            allocator.free(e.type_name);
        }
        pin_styles.deinit(allocator);
    }
    var coercions: std.ArrayList(PluginCoercion) = .empty;
    errdefer {
        for (coercions.items) |e| {
            allocator.free(e.module_import_path);
            allocator.free(e.module_sanitized);
            allocator.free(e.name);
        }
        coercions.deinit(allocator);
    }

    // ── Plugin pass ─────────────────────────────────────────────
    for (cfg.plugins) |plugin| {
        const plugin_dir = cache.resolvePlugin(allocator, plugin, project_dir) catch continue;
        defer allocator.free(plugin_dir);

        const root_path = try std.fs.path.join(allocator, &.{ plugin_dir, "src", "root.zig" });
        defer allocator.free(root_path);

        const io = config.globalIo();
        // Plugins without a `src/root.zig` (or with an unreadable one) are
        // skipped per the back-compat policy. OOM is propagated rather
        // than masked as "this plugin contributes nothing" — same
        // rationale as `discoverEventsFromRoot`.
        const src = std.Io.Dir.cwd().readFileAlloc(io, root_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer allocator.free(src);

        var name_buf: [128]u8 = undefined;
        const sanitized = sanitizePluginIdent(plugin.name, &name_buf);

        scanFlowDeclsInSource(
            allocator,
            src,
            plugin.name,
            sanitized,
            false, // is_script
            &flow_nodes,
            &pin_styles,
            &coercions,
        ) catch |err| switch (err) {
            // OOM must stay a HARD failure — swallowing it (the old
            // `catch continue`) would silently leave the generated flow
            // registry incomplete → wrong codegen with no error. Note the
            // scan's inferred error set is *exactly* `error{OutOfMemory}`:
            // `std.zig.Ast.parse` records parse errors in the AST rather
            // than raising them, so there is no genuine per-plugin parse
            // failure to tolerate here. The exhaustive switch makes that
            // explicit — if the scan ever grows a tolerable error, this
            // stops compiling and forces a deliberate `else => continue`.
            error.OutOfMemory => return err,
        };
    }

    // ── Game-script pass (RFC §5) ───────────────────────────────
    // Only walks game-owned entries — plugin-shipped scripts are
    // already covered by their plugin's root.zig pass above. See
    // the function's doc-comment for the rationale.
    var ident_buf: [256]u8 = undefined;
    for (script_entries) |entry| {
        if (entry.plugin_name != null) continue;

        const script_path = try std.fs.path.join(allocator, &.{ scripts_root, entry.rel_path });
        defer allocator.free(script_path);

        const io = config.globalIo();
        // Unreadable / missing script source is treated as "contributes
        // nothing" — the generated `main.zig` will surface a clearer
        // error when it tries to compile the script. OOM stays a hard
        // failure rather than silently swallowing memory pressure.
        const src = std.Io.Dir.cwd().readFileAlloc(io, script_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer allocator.free(src);

        const sanitized = pathToIdent(entry.rel_path, &ident_buf);

        scanFlowDeclsInSource(
            allocator,
            src,
            entry.rel_path,
            sanitized,
            true, // is_script
            &flow_nodes,
            &pin_styles,
            &coercions,
        ) catch |err| switch (err) {
            // OOM must stay a HARD failure — see the plugin pass above for
            // why the scan's only error is `error.OutOfMemory` and why
            // this switch is intentionally exhaustive (no `else`).
            error.OutOfMemory => return err,
        };
    }

    // Each `toOwnedSlice` resets its source ArrayList to empty, so the
    // top-level errdefer chains above stop covering already-detached
    // slices the moment a *later* `toOwnedSlice` fails. Stage each
    // owned slice into a local first and guard it with a slice-shaped
    // errdefer so a mid-sequence OOM still frees everything cleanly
    // before the struct-return packages them up.
    const flow_nodes_slice = try flow_nodes.toOwnedSlice(allocator);
    errdefer {
        for (flow_nodes_slice) |e| {
            allocator.free(e.module_import_path);
            allocator.free(e.module_sanitized);
            allocator.free(e.node_name);
            if (e.constructs) |c| allocator.free(c);
        }
        allocator.free(flow_nodes_slice);
    }

    const pin_styles_slice = try pin_styles.toOwnedSlice(allocator);
    errdefer {
        for (pin_styles_slice) |e| {
            allocator.free(e.module_import_path);
            allocator.free(e.module_sanitized);
            allocator.free(e.type_name);
        }
        allocator.free(pin_styles_slice);
    }

    const coercions_slice = try coercions.toOwnedSlice(allocator);

    return .{
        .flow_nodes = flow_nodes_slice,
        .pin_styles = pin_styles_slice,
        .coercions = coercions_slice,
        .allocator = allocator,
    };
}

/// Deduplicate `PluginPinStyle` entries by `type_name`, keeping the
/// last occurrence (RFC §1: "later declarations win for any
/// duplicate type key"). Allocates a new slice owned by the caller;
/// strings inside are still borrowed from the input entries' lifetime
/// (the caller's `PluginFlowDecls`). Iteration over the input is
/// reverse: the first time we see a type name, we keep it (which
/// corresponds to the last-write in the input order); a second sight
/// is dropped.
///
/// Quadratic over the entry count — fine for the small registry
/// sizes (≤ a few dozen per typical project); a HashMap would be
/// overkill and would force a string allocation for every key.
pub fn dedupePinStyles(
    allocator: std.mem.Allocator,
    pin_styles: []const PluginPinStyle,
) ![]PluginPinStyle {
    var kept: std.ArrayList(PluginPinStyle) = .empty;
    errdefer kept.deinit(allocator);
    // Walk in reverse so the first time we see a name corresponds to
    // the last declaration in input order; later passes that already
    // recorded the name skip the entry.
    var i: usize = pin_styles.len;
    while (i > 0) {
        i -= 1;
        const ps = pin_styles[i];
        var already = false;
        for (kept.items) |k| {
            if (std.mem.eql(u8, k.type_name, ps.type_name)) {
                already = true;
                break;
            }
        }
        if (!already) try kept.append(allocator, ps);
    }
    // Reverse `kept` to restore source order (filtered).
    const out = try kept.toOwnedSlice(allocator);
    std.mem.reverse(PluginPinStyle, out);
    return out;
}

// ── Regression: OOM must propagate as a hard failure (#540) ──────────
//
// The plugin + game-script passes previously did
// `scanFlowDeclsInSource(...) catch continue`, which swallowed
// `error.OutOfMemory` and returned a SILENTLY INCOMPLETE flow registry
// (wrong codegen, no error). `std.zig.Ast.parse` never surfaces parse
// *errors* as Zig errors — it records them in the AST and returns
// normally — so `error.OutOfMemory` is in fact the ONLY error the scan
// can raise. Swallowing it therefore masked the single failure mode the
// module's design goal says must stay hard.
//
// This test drives `discoverPluginFlowDecls` over a game script that
// declares a real `FlowNodes` block through a `FailingAllocator` forced
// to fail at each allocation index in turn. Post-fix every forced
// failure must surface as `error.OutOfMemory` — never a value with a
// short/empty `flow_nodes` slice (which is exactly what the old
// `catch continue` produced). The allocator's freed/allocated tally is
// asserted balanced at every failure point to also cover the errdefer
// chains.
test "discoverPluginFlowDecls: OOM propagates, never a silent partial scan" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const script_src =
        \\const labelle = @import("labelle");
        \\pub const FlowNodes = struct {
        \\    pub const apply_impulse = labelle.FlowNode(.{ .impl = applyImpulseImpl });
        \\    pub const get_velocity = labelle.FlowNode(.{ .impl = getVelocityImpl });
        \\};
        \\fn applyImpulseImpl() void {}
        \\fn getVelocityImpl() f32 {
        \\    return 0;
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "hits.zig", .data = script_src });

    const scripts_root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(scripts_root);

    const cfg = ProjectConfig{ .name = "tmp" };
    const entries = [_]ScriptEntry{.{
        .name = "hits",
        .filename = "hits.zig",
        .states = &.{},
        .sort_order = null,
        .subdir = null,
        .rel_path = "hits.zig",
    }};

    // Success path: confirm the script's FlowNodes are actually
    // discovered (so a "silent partial" pre-fix would be observable) and
    // count the allocations.
    const total_allocs = blk: {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var decls = try discoverPluginFlowDecls(fa.allocator(), cfg, scripts_root, scripts_root, &entries);
        defer decls.deinit();
        try std.testing.expect(decls.flow_nodes.len == 2);
        break :blk fa.alloc_index;
    };

    // Force-fail each allocation index. The fixed scan raises
    // `error.OutOfMemory` at every point — it must never return a value
    // with a truncated node set.
    var i: usize = 0;
    while (i < total_allocs) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = i });
        const a = fa.allocator();
        if (discoverPluginFlowDecls(a, cfg, scripts_root, scripts_root, &entries)) |decls_val| {
            var decls = decls_val;
            defer decls.deinit();
            // A value at a forced-fail index is only acceptable if it is
            // the COMPLETE result (the failure landed after the last
            // allocation) — never a silently truncated scan.
            try std.testing.expect(decls.flow_nodes.len == 2);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        try std.testing.expectEqual(fa.allocated_bytes, fa.freed_bytes);
    }
}
