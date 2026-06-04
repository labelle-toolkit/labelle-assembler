//! Plugin registry block writers extracted from `main_zig.zig`
//! (labelle-assembler#183, step 6 of the cut plan).
//!
//! Each method here emits one top-level registry block into the
//! generated `main.zig`: `PluginControllers`, `PluginEvents`,
//! `PluginFlowNodes`, `PluginPinStyles`, `PluginCoercions`. The shapes
//! mirror the RFC-PLUGIN-EVENTS / RFC-FLOW-VOCABULARY / RFC-plugin-
//! controllers contracts (see per-method doc comments below).
//!
//! ⚠️  Bit-identical contract: every `try bw.writeAll(...)` /
//! `try bw.print(...)` string literal here is a verbatim slice of the
//! generated `main.zig`. Any whitespace or punctuation drift surfaces
//! as a downstream backend recompile or behavior change. The
//! orchestrator's per-example bit-identical diff harness
//! (`scripts/gen_all_examples.sh`) is the contract enforcer.
//!
//! Dependency story: pure consumers of `scan.zig`'s already-extracted
//! discovery types (`PluginEvent`, `PluginFlowNode`, `PluginPinStyle`,
//! `PluginCoercion`) plus `config.ProjectConfig` for the controllers
//! variant. No ident helpers needed at this layer — the qualified
//! field names were sanitised upstream when `scan.zig` built the
//! discovery records.
//!
//! Mixin-only surface: the previous standalone `pub fn writeXxxBlock`
//! forms were collapsed into the mixin methods once every external
//! caller (orchestrator + tests + `root.zig:generateGameShim`) had
//! migrated to dispatch through a `Codegen` context. See the file
//! header on `codegen/context.zig` for the model.

const std = @import("std");
const config = @import("../../config.zig");
const scan = @import("../scan.zig");

const ProjectConfig = config.ProjectConfig;
const PluginEvent = scan.PluginEvent;
const PluginFlowNode = scan.PluginFlowNode;
const PluginPinStyle = scan.PluginPinStyle;
const PluginCoercion = scan.PluginCoercion;

/// Mixin factory for `Codegen` (labelle-assembler#183, mixin conversion).
///
/// Reads `cfg`, `plugin_events`, `plugin_flow_nodes`, `plugin_coercions`
/// from `self` so the orchestrator dispatches `ctx.writePluginXxxBlock(w)`
/// instead of re-threading the discovered scan results into every call.
/// `writePluginPinStylesBlock` is the one exception — it takes the
/// deduped slice as an explicit arg because the orchestrator owns the
/// dedupe buffer's lifetime (an `allocator.alloc` temporary that doesn't
/// belong on `self`).
pub fn Mixin(comptime Self: type) type {
    return struct {
        /// Emit the `PluginControllers` comptime dispatcher that scans
        /// each plugin's root module for `pub const Controller = struct { ... }`
        /// and forwards `setup` / `deinit` lifecycle calls.
        ///
        /// Backward-compatible: the `@hasDecl` guard means plugins that
        /// don't opt in contribute nothing at comptime and generate no
        /// code.
        ///
        /// RFC: flying-platform-labelle#208 §1 (manifest contract) and §2
        /// (lifecycle wiring). This is the step-1 discovery: only `setup`
        /// and `deinit` are auto-wired; per-frame plugin work ships as
        /// plugin scripts (step 3).
        pub fn writePluginControllersBlock(self: *Self, bw: anytype) !void {
            const cfg = self.cfg;
            try bw.writeAll("// --- Plugin controllers (RFC-plugin-controllers §1–§2) ---\n");
            try bw.writeAll("// Discovers `pub const Controller` in each plugin root module at comptime\n");
            try bw.writeAll("// and dispatches `setup` / `deinit` on scene load / unload. Plugins without\n");
            try bw.writeAll("// a Controller export are silently skipped by the `@hasDecl` guard.\n");
            try bw.writeAll("const PluginControllers = struct {\n");
            try bw.writeAll("    const _plugin_mods = .{\n");
            for (cfg.plugins) |plugin| {
                try bw.print("        @import(\"{s}\"),\n", .{plugin.name});
            }
            try bw.writeAll("    };\n\n");
            try bw.writeAll("    /// Call Controller.setup(game) on every plugin that declares one.\n");
            try bw.writeAll("    /// Plugins whose root module does not export a `Controller` are silently skipped.\n");
            try bw.writeAll("    pub fn setup(game: anytype) !void {\n");
            try bw.writeAll("        inline for (_plugin_mods) |mod| {\n");
            try bw.writeAll("            if (@hasDecl(mod, \"Controller\")) {\n");
            try bw.writeAll("                const C = @field(mod, \"Controller\");\n");
            try bw.writeAll("                if (@hasDecl(C, \"setup\")) try C.setup(game);\n");
            try bw.writeAll("            }\n");
            try bw.writeAll("        }\n");
            try bw.writeAll("    }\n\n");
            try bw.writeAll("    /// Call Controller.deinit(game) on every plugin that declares one.\n");
            try bw.writeAll("    /// Mirrors setup(). Skips plugins without a Controller export or without a deinit.\n");
            try bw.writeAll("    pub fn deinit(game: anytype) void {\n");
            try bw.writeAll("        inline for (_plugin_mods) |mod| {\n");
            try bw.writeAll("            if (@hasDecl(mod, \"Controller\")) {\n");
            try bw.writeAll("                const C = @field(mod, \"Controller\");\n");
            try bw.writeAll("                if (@hasDecl(C, \"deinit\")) C.deinit(game);\n");
            try bw.writeAll("            }\n");
            try bw.writeAll("        }\n");
            try bw.writeAll("    }\n");
            try bw.writeAll("};\n\n");
        }

        /// Emit the `PluginEvents` tagged union (RFC-PLUGIN-EVENTS phase 1).
        ///
        /// Plugin events are discovered **at assembler time** by parsing
        /// each plugin's `src/root.zig` AST (see `discoverPluginEvents`)
        /// and folding every `pub const <name> = struct` inside the
        /// plugin's top-level `pub const Events = struct { … }` into a
        /// union variant with a plugin-qualified tag
        /// (`<plugin>__<event>`). `.` is not a valid Zig identifier
        /// character, so the on-disk JSONC dot form
        /// (`box2d.collision_begin`) resolves to the qualified tag
        /// (`box2d__collision_begin`) when flow-codegen consumes this in
        /// phase 3.
        ///
        /// Why a literal `union(enum) { … }` rather than the comptime
        /// `@Union(.auto, …)` builtin: `@Union` with zero fields returns
        /// an "uninstantiable" type. `std.ArrayList(T)`'s deinit path
        /// does `@memset(self.items, undefined)`, which the 0.16 compiler
        /// rejects for uninstantiable unions ("cannot coerce to
        /// uninstantiable type"). That manifests as the plugin-
        /// controllers CI failure on every post-`9f8c5fc` commit. Writing
        /// the union out as source bypasses the builtin entirely and, in
        /// the empty-discovery case, we emit `void` instead (the engine's
        /// `has_events = GameEvents != void` gate then elides the event
        /// buffer at type level).
        ///
        /// Plugins without a `pub const Events` struct contribute zero
        /// entries — that's the back-compat path every existing plugin
        /// (labelle-fsm, labelle-pathfinding, the demo plugin) takes.
        ///
        /// The plugin "name" prefix is the same string used in
        /// `@import("<name>")` (project.labelle's `.plugins[].name`),
        /// sanitized to a valid Zig identifier — non-`[A-Za-z0-9_]` bytes
        /// collapse to `_`. Two plugins whose sanitized name collide
        /// would produce duplicate variant names, which Zig rejects at
        /// the union declaration itself.
        pub fn writePluginEventsBlock(self: *Self, bw: anytype) !void {
            const plugin_events = self.plugin_events;
            try bw.writeAll("// --- Plugin events (RFC-PLUGIN-EVENTS phase 1) ---\n");
            try bw.writeAll("// Discovered at assembler time from `pub const Events` on each\n");
            try bw.writeAll("// plugin's `src/root.zig` — same convention as the comptime walk\n");
            try bw.writeAll("// (Components/Systems/GizmoCategories) but materialised statically\n");
            try bw.writeAll("// so the union is a real source-level type (the comptime `@Union`\n");
            try bw.writeAll("// builtin's zero-field result is uninstantiable in std.ArrayList).\n");
            try bw.writeAll("// Variant tag = `<plugin>__<event>` so a flow's dotted name\n");
            try bw.writeAll("// (`box2d.collision_begin`) maps to a Zig identifier.\n");
            if (plugin_events.len == 0) {
                // No plugin contributed an `Events` decl — emit `void` and let
                // `has_events = GameEvents != void` elide the event buffer.
                try bw.writeAll("pub const PluginEvents = void;\n\n");
                return;
            }
            try bw.writeAll("pub const PluginEvents = union(enum) {\n");
            for (plugin_events) |e| {
                // The engine is discovered alongside plugins (labelle-engine
                // #578) but its Zig module name is `labelle-engine`, not
                // `engine` (the latter is just the dotted-form prefix used in
                // the qualified variant tag and on-disk JSONC names). Special-
                // case the resolver so `@import("...").Events.<name>` lands on
                // the right module. Plugins keep their identity-mapped name.
                const import_name = if (std.mem.eql(u8, e.plugin_import_name, "engine"))
                    "labelle-engine"
                else
                    e.plugin_import_name;
                try bw.print(
                    "    {s}__{s}: @import(\"{s}\").Events.{s},\n",
                    .{ e.plugin_sanitized, e.event_name, import_name, e.event_name },
                );
            }
            try bw.writeAll("};\n\n");
        }

        /// Emit the `PluginFlowNodes` registry (RFC-FLOW-VOCABULARY phase 2).
        ///
        /// One `pub const <module>__<name>` entry per discovered FlowNode,
        /// aliased to the source-module decl so all metadata
        /// (display_name, category, docs, kind, pins) **and** the `impl`
        /// comptime decl survive intact for downstream reflection.
        /// Plugins and game scripts use different `@import` forms —
        /// plugins resolve as `@import("<plugin>")`, game scripts as
        /// `@import("scripts/<rel>")`.
        ///
        /// Plus a comptime `resolve` decl: given a dotted name like
        /// `"box2d.apply_impulse"`, returns the canonical qualified field
        /// name (`"box2d__apply_impulse"`) and a `@hasDecl(PluginFlowNodes,
        /// resolved)` check confirms membership. Mechanism mirrors how
        /// flow-codegen's RFC-PLUGIN-EVENTS phase 3 resolver looked up
        /// event names via `@FieldType(game.PluginEvents, "<tag>")`.
        /// Callers do `@field(PluginFlowNodes, resolved)` to reach the
        /// entry value.
        ///
        /// Empty discovery (no plugins/game scripts declare `FlowNodes`)
        /// emits a `void`-equivalent: an empty `struct {}` with a stub
        /// `resolve` that always returns `null`, so flow-codegen's
        /// eventual `CustomNode` lowering doesn't need a separate
        /// empty-case branch.
        pub fn writePluginFlowNodesBlock(self: *Self, bw: anytype) !void {
            const flow_nodes = self.plugin_flow_nodes;
            try bw.writeAll("// --- Plugin flow nodes (RFC-FLOW-VOCABULARY phase 2) ---\n");
            try bw.writeAll("// Discovered at assembler time from `pub const FlowNodes` on each\n");
            try bw.writeAll("// plugin's `src/root.zig` AND each game-script module under\n");
            try bw.writeAll("// `scripts/` (RFC §5: any module exporting FlowNodes contributes).\n");
            try bw.writeAll("// Each entry aliases the source decl directly so the FlowNode\n");
            try bw.writeAll("// factory's metadata + `impl` comptime decl pass through to\n");
            try bw.writeAll("// downstream consumers (flow-codegen `CustomNode` lowering in\n");
            try bw.writeAll("// phase 3, labelle-gui palette UI in phase 4).\n");
            try bw.writeAll("pub const PluginFlowNodes = struct {\n");
            for (flow_nodes) |fn_| {
                // RFC-FLOW-VOCABULARY §1 / O5 — surface the captured `.constructs`
                // hint as a doc-comment above the alias. The alias itself carries
                // the value through the FlowNode factory's struct field, so
                // downstream consumers can also read it via reflection
                // (`PluginFlowNodes.<qualified>.constructs`); the comment is a
                // human-readable signal for anyone reading the generated file.
                if (fn_.constructs) |c| {
                    try bw.print("    /// constructs: {s}\n", .{c});
                }
                if (fn_.is_script) {
                    // Game-script FlowNodes are promoted to NAMED build
                    // modules (`script__<module_sanitized>`,
                    // labelle-assembler#240 Gap 2) so the same file isn't
                    // a member of both the root module (via `AllScripts`
                    // in main.zig) and the `game` module (via the shim's
                    // copy of this block). A path `@import("scripts/<rel>")`
                    // would re-introduce the dual-module conflict
                    // ("file exists in modules 'root' and 'game'"). The
                    // `script__` prefix + `module_sanitized` are
                    // byte-identical to `scan.promotedScriptModuleName`,
                    // the single source of truth the build.zig wiring and
                    // `AllScripts` promotion path also use.
                    try bw.print(
                        "    pub const {s}__{s} = @import(\"script__{s}\").FlowNodes.{s};\n",
                        .{ fn_.module_sanitized, fn_.node_name, fn_.module_sanitized, fn_.node_name },
                    );
                } else {
                    try bw.print(
                        "    pub const {s}__{s} = @import(\"{s}\").FlowNodes.{s};\n",
                        .{ fn_.module_sanitized, fn_.node_name, fn_.module_import_path, fn_.node_name },
                    );
                }
            }
            // Name resolver — emitted unconditionally so callers can use a
            // single canonical entry point regardless of whether discovery
            // found anything. The implementation matches what
            // RFC-PLUGIN-EVENTS used for event-name resolution: split the
            // dotted form on `.`, swap to `__`, return the joined identifier
            // when it names a public decl on `PluginFlowNodes`. Pure comptime
            // — flow-codegen calls this during `CustomNode` lowering.
            try bw.writeAll("\n");
            try bw.writeAll("    /// Comptime name resolver for flow-codegen's `CustomNode`\n");
            try bw.writeAll("    /// lowering. Given a dotted node name (`\"box2d.apply_impulse\"`),\n");
            try bw.writeAll("    /// returns the canonical qualified identifier\n");
            try bw.writeAll("    /// (`\"box2d__apply_impulse\"`) iff a matching decl exists on\n");
            try bw.writeAll("    /// this struct, else `null`. Callers reach the entry value via\n");
            try bw.writeAll("    /// `@field(PluginFlowNodes, resolved)`.\n");
            try bw.writeAll("    ///\n");
            try bw.writeAll("    /// Module prefix is sanitised the same way `sanitizePluginIdent`\n");
            try bw.writeAll("    /// in the assembler shapes plugin names into the emitted decl\n");
            try bw.writeAll("    /// names — a leading digit (`3d_renderer`) gets an `_` prefix\n");
            try bw.writeAll("    /// and any non-identifier byte (`-`, `.`, `/`) collapses to `_`.\n");
            try bw.writeAll("    /// Without this, a digit-prefixed plugin name resolves to a\n");
            try bw.writeAll("    /// qualified identifier that the decl-emission side prefixed\n");
            try bw.writeAll("    /// with `_`, and the `@hasDecl` check would always miss\n");
            try bw.writeAll("    /// (labelle-assembler#212).\n");
            try bw.writeAll("    pub fn resolve(comptime dotted: []const u8) ?[]const u8 {\n");
            try bw.writeAll("        const dot = std.mem.indexOfScalar(u8, dotted, '.') orelse return null;\n");
            try bw.writeAll("        const module = dotted[0..dot];\n");
            try bw.writeAll("        const node = dotted[dot + 1 ..];\n");
            try bw.writeAll("        if (node.len == 0) return null;\n");
            try bw.writeAll("        const qualified = comptime sanitizeModuleIdent(module) ++ \"__\" ++ node;\n");
            try bw.writeAll("        if (!@hasDecl(@This(), qualified)) return null;\n");
            try bw.writeAll("        return qualified;\n");
            try bw.writeAll("    }\n");
            try bw.writeAll("\n");
            try bw.writeAll("    /// Mirror of the assembler's `sanitizePluginIdent` so a dotted\n");
            try bw.writeAll("    /// caller-supplied module name (`3d_renderer`, `labelle-box2d`)\n");
            try bw.writeAll("    /// maps to the same identifier shape the decl-emission side\n");
            try bw.writeAll("    /// produced. Comptime-only — no runtime overhead.\n");
            try bw.writeAll("    fn sanitizeModuleIdent(comptime name: []const u8) []const u8 {\n");
            try bw.writeAll("        comptime {\n");
            try bw.writeAll("            var out: []const u8 = \"\";\n");
            try bw.writeAll("            if (name.len > 0 and name[0] >= '0' and name[0] <= '9') out = out ++ \"_\";\n");
            try bw.writeAll("            for (name) |c| {\n");
            try bw.writeAll("                const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';\n");
            try bw.writeAll("                out = out ++ &[_]u8{ if (ok) c else '_' };\n");
            try bw.writeAll("            }\n");
            try bw.writeAll("            return out;\n");
            try bw.writeAll("        }\n");
            try bw.writeAll("    }\n");
            try bw.writeAll("};\n\n");
        }

        /// Emit the `PluginPinStyles` registry (RFC-FLOW-VOCABULARY phase 2).
        ///
        /// One `pub const <TypeName>` entry per discovered `PinStyle`,
        /// aliased to the source-module decl. Keyed by the Zig **type
        /// name** (e.g. `BodyId`), so two plugins both declaring a
        /// `BodyId` style would emit duplicate decls — the assembler
        /// deduplicates upstream (last-write-wins, matching the RFC §1
        /// contract) so the emitted block has at most one entry per type
        /// name.
        ///
        /// `pin_styles` arrives as an explicit arg (rather than read from
        /// `self.plugin_pin_styles`) because the orchestrator deduplicates
        /// them via an allocator-owned temporary slice before emission —
        /// keeping that allocation lifecycle in the orchestrator avoids
        /// stashing the dedupe buffer on `self`.
        ///
        /// Empty discovery emits an empty `struct { }` — same shape as
        /// the populated case so callers can iterate
        /// `@typeInfo(PluginPinStyles)` uniformly. The editor layers
        /// these on top of `default_pin_styles` (which already ship in
        /// `labelle-core`), so an empty plugin-side registry just means
        /// "no per-type overrides beyond the defaults".
        pub fn writePluginPinStylesBlock(_: *Self, bw: anytype, pin_styles: []const PluginPinStyle) !void {
            try bw.writeAll("// --- Plugin pin styles (RFC-FLOW-VOCABULARY phase 2) ---\n");
            try bw.writeAll("// Discovered at assembler time from `pub const PinStyles` on each\n");
            try bw.writeAll("// plugin's `src/root.zig` AND each game-script module under\n");
            try bw.writeAll("// `scripts/`. The editor layers these on top of\n");
            try bw.writeAll("// `labelle-core`'s `default_pin_styles` (primitives + EntityId).\n");
            try bw.writeAll("// Keyed by Zig type name; duplicates across modules are deduped\n");
            try bw.writeAll("// last-write-wins by the assembler before emission, matching\n");
            try bw.writeAll("// the RFC §1 contract.\n");
            try bw.writeAll("pub const PluginPinStyles = struct {\n");
            for (pin_styles) |ps| {
                if (ps.is_script) {
                    try bw.print(
                        "    pub const {s} = @import(\"scripts/{s}\").PinStyles.{s};\n",
                        .{ ps.type_name, ps.module_import_path, ps.type_name },
                    );
                } else {
                    try bw.print(
                        "    pub const {s} = @import(\"{s}\").PinStyles.{s};\n",
                        .{ ps.type_name, ps.module_import_path, ps.type_name },
                    );
                }
            }
            try bw.writeAll("};\n\n");
        }

        /// Emit the `PluginCoercions` registry (RFC-FLOW-VOCABULARY §2 / O4).
        ///
        /// One `pub const <module>__<name>` entry per discovered
        /// Coercion, aliased to the source-module decl so the `From` /
        /// `To` types and the `convert` function survive reflection.
        /// Plugins and game scripts use different `@import` forms —
        /// plugins resolve as `@import("<plugin>")`, game scripts as
        /// `@import("scripts/<rel>")`.
        ///
        /// Plus a comptime `resolve` decl: given a dotted name like
        /// `"box2d.body_to_entity"`, returns the canonical qualified
        /// field name (`"box2d__body_to_entity"`) and a
        /// `@hasDecl(PluginCoercions, resolved)` check confirms
        /// membership. Same shape as `PluginFlowNodes.resolve`.
        ///
        /// Plus a comptime `findByTypes(From, To)` helper: scans the
        /// registry for an entry whose `From` and `To` match the given
        /// types and returns its qualified name (or `null`). flow-
        /// codegen consumes this at edge emission to decide whether to
        /// wrap an expression in a `<plugin>__<name>.convert(...)` call.
        ///
        /// Empty discovery (no plugins/game scripts declare `Coercions`)
        /// emits a `struct {}` with the stub helpers, so downstream
        /// reflection doesn't need an empty-case branch.
        pub fn writePluginCoercionsBlock(self: *Self, bw: anytype) !void {
            const coercions = self.plugin_coercions;
            try bw.writeAll("// --- Plugin coercions (RFC-FLOW-VOCABULARY §2 / O4) ---\n");
            try bw.writeAll("// Discovered at assembler time from `pub const Coercions` on each\n");
            try bw.writeAll("// plugin's `src/root.zig` AND each game-script module under\n");
            try bw.writeAll("// `scripts/`. Each entry aliases the source decl directly so the\n");
            try bw.writeAll("// `From` / `To` comptime decls + `convert` function pass through\n");
            try bw.writeAll("// to flow-codegen's edge-wrap path (it consults `findByTypes` to\n");
            try bw.writeAll("// decide when to wrap an expression in `<qualified>.convert(...)`).\n");
            try bw.writeAll("pub const PluginCoercions = struct {\n");
            for (coercions) |co| {
                if (co.is_script) {
                    try bw.print(
                        "    pub const {s}__{s} = @import(\"scripts/{s}\").Coercions.{s};\n",
                        .{ co.module_sanitized, co.name, co.module_import_path, co.name },
                    );
                } else {
                    try bw.print(
                        "    pub const {s}__{s} = @import(\"{s}\").Coercions.{s};\n",
                        .{ co.module_sanitized, co.name, co.module_import_path, co.name },
                    );
                }
            }
            // Name resolver — same shape as `PluginFlowNodes.resolve` so flow-codegen's
            // CustomNode lowering and coercion wrap path share an identical pattern.
            try bw.writeAll("\n");
            try bw.writeAll("    /// Comptime name resolver — given a dotted coercion name\n");
            try bw.writeAll("    /// (`\"box2d.body_to_entity\"`), returns the canonical qualified\n");
            try bw.writeAll("    /// identifier (`\"box2d__body_to_entity\"`) iff a matching decl\n");
            try bw.writeAll("    /// exists on this struct, else `null`. Callers reach the entry\n");
            try bw.writeAll("    /// value via `@field(PluginCoercions, resolved)`.\n");
            try bw.writeAll("    ///\n");
            try bw.writeAll("    /// Module prefix is sanitised the same way the decl-emission\n");
            try bw.writeAll("    /// side shapes it — leading digits get an `_` prefix and any\n");
            try bw.writeAll("    /// non-identifier byte collapses to `_`. Without this, a digit-\n");
            try bw.writeAll("    /// prefixed plugin name (`3d_renderer`) misses the `@hasDecl`\n");
            try bw.writeAll("    /// check (labelle-assembler#212).\n");
            try bw.writeAll("    pub fn resolve(comptime dotted: []const u8) ?[]const u8 {\n");
            try bw.writeAll("        const dot = std.mem.indexOfScalar(u8, dotted, '.') orelse return null;\n");
            try bw.writeAll("        const module = dotted[0..dot];\n");
            try bw.writeAll("        const name = dotted[dot + 1 ..];\n");
            try bw.writeAll("        if (name.len == 0) return null;\n");
            try bw.writeAll("        const qualified = comptime sanitizeModuleIdent(module) ++ \"__\" ++ name;\n");
            try bw.writeAll("        if (!@hasDecl(@This(), qualified)) return null;\n");
            try bw.writeAll("        return qualified;\n");
            try bw.writeAll("    }\n");
            try bw.writeAll("\n");
            try bw.writeAll("    /// Mirror of the assembler's `sanitizePluginIdent` so the dotted\n");
            try bw.writeAll("    /// caller-supplied module name maps to the same identifier shape\n");
            try bw.writeAll("    /// the decl-emission side produced. Comptime-only.\n");
            try bw.writeAll("    fn sanitizeModuleIdent(comptime name: []const u8) []const u8 {\n");
            try bw.writeAll("        comptime {\n");
            try bw.writeAll("            var out: []const u8 = \"\";\n");
            try bw.writeAll("            if (name.len > 0 and name[0] >= '0' and name[0] <= '9') out = out ++ \"_\";\n");
            try bw.writeAll("            for (name) |c| {\n");
            try bw.writeAll("                const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';\n");
            try bw.writeAll("                out = out ++ &[_]u8{ if (ok) c else '_' };\n");
            try bw.writeAll("            }\n");
            try bw.writeAll("            return out;\n");
            try bw.writeAll("        }\n");
            try bw.writeAll("    }\n");
            // Type-keyed lookup — the wire-fit rule asks "is there a coercion for
            // (From, To)?". Scans all decls at comptime; tiny registries (≤ dozens)
            // mean linear walk is the right shape.
            try bw.writeAll("\n");
            try bw.writeAll("    /// Comptime type-keyed lookup — scans every entry on this\n");
            try bw.writeAll("    /// struct for one whose `.From == From` and `.To == To`. Returns\n");
            try bw.writeAll("    /// its qualified decl name (the same string `resolve` would\n");
            try bw.writeAll("    /// return) when found, else `null`. flow-codegen calls this at\n");
            try bw.writeAll("    /// edge-emission time to decide whether a wire across mismatched\n");
            try bw.writeAll("    /// types is accepted via a declared coercion (RFC §2 rule 3).\n");
            try bw.writeAll("    pub fn findByTypes(comptime From: type, comptime To: type) ?[]const u8 {\n");
            try bw.writeAll("        const decls = @typeInfo(@This()).@\"struct\".decls;\n");
            try bw.writeAll("        inline for (decls) |d| {\n");
            try bw.writeAll("            const entry = @field(@This(), d.name);\n");
            try bw.writeAll("            const ET = @TypeOf(entry);\n");
            try bw.writeAll("            // Skip non-coercion decls (e.g. the resolve/findByTypes fns\n");
            try bw.writeAll("            // themselves and any future helpers). A coercion entry is a\n");
            try bw.writeAll("            // struct value carrying the `__is_labelle_coercion` marker;\n");
            try bw.writeAll("            // anything else (functions, plain ints, etc.) is filtered.\n");
            try bw.writeAll("            if (@typeInfo(ET) != .@\"struct\") continue;\n");
            try bw.writeAll("            if (!@hasDecl(ET, \"__is_labelle_coercion\")) continue;\n");
            try bw.writeAll("            if (ET.From == From and ET.To == To) return d.name;\n");
            try bw.writeAll("        }\n");
            try bw.writeAll("        return null;\n");
            try bw.writeAll("    }\n");
            try bw.writeAll("};\n\n");
        }
    };
}
