//! Comptime registry blocks emitted into the generated `main.zig`:
//! `Prefabs`, `Components`, `PluginSystems`/gizmo categories,
//! `AllScripts`, `Views`, `Gizmos`, and the animation defs.
//!
//! Extracted from `main_template.zig`'s orchestrator (labelle-assembler
//! file-size refactor) following the `blocks/*.zig` mixin pattern. Each
//! writer consumes the scan slices already borrowed onto `Codegen`
//! (`component_names`, `view_names`, `gizmo_names`, `animation_names`,
//! `script_entries`, `plugin_flow_nodes`) and the project `cfg`, then
//! writes its block into the caller's writer — byte-identical to the
//! inline regions it replaces. The system-registry writer delegates the
//! plugin-controllers scaffold to `PluginRegistriesMixin` via `self`.

const std = @import("std");
const idents = @import("../idents.zig");
const scan = @import("../scan.zig");

const pathToIdent = scan.pathToIdent;
const pathToPascal = idents.pathToPascal;
const PluginFlowNode = scan.PluginFlowNode;

/// True iff `ident` (a game script's `pathToIdent(rel_path)`) names a
/// game-script module that contributed at least one FlowNode and is
/// therefore promoted to a named build module (labelle-assembler#240
/// Gap 2). `module_sanitized` of an `is_script` flow node equals
/// `pathToIdent(rel_path)`, so the comparison is a direct string match.
/// Used by the `AllScripts` emitter to switch promoted scripts to the
/// `@import("script__<ident>")` form.
fn isFlowNodeScript(flow_nodes: []const PluginFlowNode, ident: []const u8) bool {
    for (flow_nodes) |fn_| {
        if (!fn_.is_script) continue;
        if (std.mem.eql(u8, fn_.module_sanitized, ident)) return true;
    }
    return false;
}

/// Mixin factory for `Codegen`. Reads `cfg`, `component_names`,
/// `view_names`, `gizmo_names`, `animation_names`, `script_entries`,
/// `plugin_flow_nodes` from `self`.
pub fn Mixin(comptime Self: type) type {
    return struct {
        /// Prefab registry block — JSONC prefabs are loaded at runtime via
        /// addEmbeddedPrefab, so the comptime registry is always empty.
        pub fn writePrefabRegistryBlock(_: *Self, w: anytype) !void {
            try w.writeAll("const Prefabs = engine.PrefabRegistry(.{});\n\n");
        }

        /// Component registry block.
        pub fn writeComponentRegistryBlock(self: *Self, w: anytype) !void {
            const cfg = self.cfg;
            const component_names = self.component_names;
            const has_plugins = cfg.plugins.len > 0;
            if (has_plugins) {
                try w.writeAll("const Components = engine.ComponentRegistryWithPlugins(.{\n");
            } else {
                try w.writeAll("const Components = engine.ComponentRegistry(.{\n");
            }
            // Built-in engine component available to every project's prefabs/scenes
            // (#549) — a `VideoComponent` can be declared in a prefab/scene `.jsonc`
            // like any game component (`{ "VideoComponent": { "path": "intro", … } }`)
            // and the engine's video system plays it at the entity's position.
            try w.writeAll("    .VideoComponent = engine.core.VideoComponent,\n");
            var pascal_buf: [128]u8 = undefined;
            for (component_names) |name| {
                const pascal = pathToPascal(name, &pascal_buf);
                try w.print("    .{s} = @import(\"components/{s}.zig\").{s},\n", .{ pascal, name, pascal });
            }
            // Pack components (Packs RFC §4, #439) land in the SAME registry
            // field-set as the game root — the "unified set" (§6-1b): they're
            // stored + serialized identically, no separate registry. Files
            // live under the pack's `import_prefix` (e.g. `packs/citizens`),
            // scanned/copied by `root.zig`. #440: the registry FIELD is the
            // invisible `<pack>__<Pascal>` (e.g. `.citizens__Worker`) so a pack
            // and the game root that both define `Worker` never collide — the
            // author still writes the bare local name in JSONC (rewritten by
            // `scanPack`). The imported DECL name stays bare — it's the
            // component type's own `pub const Worker` inside the pack file.
            var pack_prefix_buf: [128]u8 = undefined;
            for (self.pack_scans) |pack| {
                const prefix = scan.packNamespacePrefix(pack.name, &pack_prefix_buf);
                for (pack.component_names) |name| {
                    const pascal = pathToPascal(name, &pascal_buf);
                    try w.print("    .{s}__{s} = @import(\"{s}/components/{s}.zig\").{s},\n", .{ prefix, pascal, pack.import_prefix, name, pascal });
                }
            }
            if (has_plugins) {
                try w.writeAll("}, .{\n");
                try w.writeAll("    @import(\"labelle-gfx\"),\n");
                for (cfg.plugins) |plugin| {
                    try w.print("    @import(\"{s}\"),\n", .{plugin.name});
                }
                try w.writeAll("});\n\n");
            } else {
                try w.writeAll("});\n\n");
            }

            // Per-pack registry partition (labelle-engine#652, assembler#498).
            // Appended into the SAME `{{component_registry_block}}` scalar right
            // after `Components` — no new template placeholder — so the view
            // aliases sit beside the full registry they partition.
            try writePackViewsBlock(self, w);
        }

        /// Per-pack `PackView` partition aliases (Packs "wire the wall",
        /// labelle-assembler#498 / labelle-engine#652).
        ///
        /// For every pack with at least one component, emit
        ///
        /// ```zig
        /// pub const <pack>_pack_view = engine.PackView(Components, &.{
        ///     "<pack>__<Pascal>",
        ///     …
        /// });
        /// ```
        ///
        /// `Components` stays the SINGLE full registry (it feeds
        /// `GameConfigWithYAxis`, `JsoncBridge`, and the serializer); the view
        /// is a NAME LENS onto it — the pack's sanctioned string-keyed surface.
        /// `own_names` are the pack's **namespaced registry field names**
        /// (`<prefix>__<Pascal>`), byte-identical to the strings
        /// `writeComponentRegistryBlock` emitted as `Components` fields — which
        /// are also the serde/save keys, so the allow-list must match them
        /// exactly. The engine's `ComponentView` `@compileError`s on any
        /// foreign-private name resolved through the view.
        ///
        /// The `<pack>_pack_view` decl name mirrors the guide/ticket
        /// (`citizens_pack_view`). Pack code reaches its view via
        /// `@import("root").<pack>_pack_view` — the `@import("root")` bridge +
        /// self-import land with the per-pack module (assembler#498 PRs 2–3), so
        /// today these aliases are generated but not yet referenced by pack code
        /// (they compile: `engine` is imported and `Components` is in scope).
        ///
        /// Gated on pack presence AND per-pack on the pack owning ≥1 component:
        /// a pack-less project (or a component-less pack) emits nothing, keeping
        /// generation byte-identical for every project that isn't using packs.
        pub fn writePackViewsBlock(self: *Self, w: anytype) !void {
            if (self.pack_scans.len == 0) return;
            var pack_prefix_buf: [128]u8 = undefined;
            var pascal_buf: [128]u8 = undefined;
            for (self.pack_scans) |pack| {
                if (pack.component_names.len == 0) continue;
                const prefix = scan.packNamespacePrefix(pack.name, &pack_prefix_buf);
                try w.print(
                    "// Per-pack registry partition (labelle-engine#652).\npub const {s}_pack_view = engine.PackView(Components, &.{{\n",
                    .{prefix},
                );
                for (pack.component_names) |name| {
                    const pascal = pathToPascal(name, &pascal_buf);
                    try w.print("    \"{s}__{s}\",\n", .{ prefix, pascal });
                }
                try w.writeAll("});\n\n");
            }
        }

        /// System registry block + Plugin controllers block (appended into
        /// the same scalar so it slots into the existing
        /// `{{system_registry_block}}` placeholder in main.zig.template
        /// without needing a template update).
        ///
        /// The Plugin controllers scaffolding discovers `pub const
        /// Controller` in each plugin root module at comptime and emits a
        /// `setup` / `deinit` dispatcher the generated main calls on scene
        /// load / unload. Backward-compatible: plugins without a Controller
        /// export are silently skipped by the `@hasDecl` guard, so no
        /// runtime cost and no generate-time opt-in needed.
        ///
        /// See flying-platform-labelle#208 (RFC: Plugin-Exported
        /// Controllers) §1–§2.
        pub fn writeSystemRegistryBlock(self: *Self, w: anytype) !void {
            const cfg = self.cfg;
            if (cfg.plugins.len > 0) {
                try w.writeAll("const PluginSystems = engine.SystemRegistry(.{\n");
                try w.writeAll("    @import(\"labelle-gfx\"),\n");
                for (cfg.plugins) |plugin| {
                    try w.print("    @import(\"{s}\"),\n", .{plugin.name});
                }
                try w.writeAll("});\n\n");
                try w.writeAll("const DiscoveredGizmoCategories = PluginSystems.gizmoCategories();\n\n");

                try self.writePluginControllersBlock(w);
            } else {
                try w.writeAll("const GizmoCatEntry = struct { name: []const u8, id: u8 };\n");
                try w.writeAll("const DiscoveredGizmoCategories: []const GizmoCatEntry = &.{};\n\n");
            }
        }

        /// All scripts block — the `AllScripts` struct that imports every
        /// game script under a stable identifier.
        pub fn writeAllScriptsBlock(self: *Self, w: anytype, ident_buf: *[256]u8) !void {
            const script_entries = self.script_entries;
            const plugin_flow_nodes = self.plugin_flow_nodes;
            try w.writeAll("const AllScripts = struct {\n");
            for (script_entries) |entry| {
                // Skip the GAME's own `context` script — it's imported
                // separately as `GameContext`, not through `AllScripts`. A
                // pack/plugin-shipped `context` script (`plugin_name != null`)
                // is an ordinary script and MUST stay in `AllScripts`, or it's
                // silently dropped (labelle-assembler#496, codex review).
                if (entry.plugin_name == null and std.mem.eql(u8, entry.name, "context")) continue;
                const ident = pathToIdent(entry.rel_path, ident_buf);
                // labelle-assembler#240 Gap 2 — a game script that exports
                // `pub const FlowNodes` is promoted to a NAMED build module
                // (it's also reached by the `game` shim's `PluginFlowNodes`).
                // It MUST be `@import("script__<sanitized>")` here, not
                // `@import("scripts/<rel>")`, or the file lands in both the
                // root module (this block) and the `game` module → the
                // "file exists in modules 'root' and 'game'" error. The
                // sanitized prefix is byte-identical to `ident` because both
                // are `pathToIdent(rel_path)`, matching
                // `scan.promotedScriptModuleName`. Scripts without FlowNodes
                // keep the path import.
                const is_promoted = isFlowNodeScript(plugin_flow_nodes, ident);
                // Buffer the named module name so the import expr below is a
                // single `{s}` regardless of promotion. `script__` + `ident`.
                var named_buf: [256 + "script__".len]u8 = undefined;
                const import_target: []const u8 = if (is_promoted)
                    std.fmt.bufPrint(&named_buf, "script__{s}", .{ident}) catch return error.NameTooLong
                else
                    entry.rel_path;
                // `entry.import_base` is `"scripts/"` for game + plugin
                // scripts (rel_path relative to the generated scripts/ dir)
                // and `""` for pack scripts, whose rel_path is already a full
                // `packs/<name>/scripts/...` target-relative path
                // (labelle-assembler#487). A FlowNode-promoted game script
                // still imports through its named module, so it overrides
                // both to `""`.
                const import_prefix: []const u8 = if (is_promoted) "" else entry.import_base;
                if (entry.states.len == 0) {
                    try w.print("    pub const {s} = @import(\"{s}{s}\");\n", .{ ident, import_prefix, import_target });
                } else {
                    try w.print("    pub const {s} = struct {{\n", .{ident});
                    try w.print("        const _inner = @import(\"{s}{s}\");\n", .{ import_prefix, import_target });
                    try w.writeAll("        pub const game_states = .{\n");
                    for (entry.states) |state| {
                        try w.print("            \"{s}\",\n", .{state});
                    }
                    try w.writeAll("        };\n");
                    const decl_names = [_][]const u8{ "tick", "setup", "drawGui", "State" };
                    for (decl_names) |decl| {
                        try w.print("        pub const {s} = if (@hasDecl(_inner, \"{s}\")) _inner.{s} else {{}};\n", .{ decl, decl, decl });
                    }
                    try w.writeAll("    };\n");
                }
            }
            try w.writeAll("};\n\n");
        }

        /// View registry block.
        pub fn writeViewRegistryBlock(self: *Self, w: anytype, ident_buf: *[256]u8) !void {
            const view_names = self.view_names;
            if (view_names.len > 0) {
                try w.writeAll("const Views = engine.ViewRegistry(.{\n");
                for (view_names) |name| {
                    const ident = pathToIdent(name, ident_buf);
                    try w.print("    .{s} = @import(\"views/{s}.zon\"),\n", .{ ident, name });
                }
                try w.writeAll("});\n\n");
            } else {
                try w.writeAll("const Views = engine.EmptyViewRegistry;\n\n");
            }
        }

        /// Gizmo registry block.
        pub fn writeGizmoRegistryBlock(self: *Self, w: anytype, ident_buf: *[256]u8) !void {
            const gizmo_names = self.gizmo_names;
            if (gizmo_names.len > 0) {
                try w.writeAll("const Gizmos = engine.GizmoRegistry(.{\n");
                for (gizmo_names) |name| {
                    const ident = pathToIdent(name, ident_buf);
                    try w.print("    .{s} = @import(\"gizmos/{s}.zon\"),\n", .{ ident, name });
                }
                try w.writeAll("});\n\n");
            }
        }

        /// Animation registry block.
        pub fn writeAnimationRegistryBlock(self: *Self, w: anytype) !void {
            const animation_names = self.animation_names;
            if (animation_names.len > 0) {
                var anim_pascal_buf: [128]u8 = undefined;
                for (animation_names) |name| {
                    const pascal = pathToPascal(name, &anim_pascal_buf);
                    try w.print("const {s}Anim = engine.AnimationDef(@import(\"animations/{s}.zon\"));\n", .{ pascal, name });
                }
                try w.writeAll("\n");
            }
        }
    };
}
