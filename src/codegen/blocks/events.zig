//! Game-events + plugin-vocabulary registry block for the generated
//! `main.zig` (`GameEvents`, `PluginEvents`, `PluginFlowNodes`,
//! `PluginPinStyles`, `PluginCoercions`).
//!
//! Extracted from `main_template.zig`'s orchestrator (labelle-assembler
//! file-size refactor) following the `blocks/*.zig` mixin pattern. The
//! writer composes the game-side `events/*.zig` scan (labelle-engine#422)
//! with the plugin-side discovery (RFC-PLUGIN-EVENTS phase 1 +
//! RFC-FLOW-VOCABULARY phase 2 / §2 O4), delegating each plugin sub-block
//! to the `PluginRegistriesMixin` methods already on `Codegen`
//! (`writePluginEventsBlock`, `writePluginFlowNodesBlock`,
//! `writePluginPinStylesBlock`, `writePluginCoercionsBlock`) via `self`.
//!
//! Reads `event_names`, `plugin_events`, `plugin_pin_styles`, and
//! `allocator` from `self`. The only allocation is the deduped pin-style
//! slice, freed before return.

const std = @import("std");
const idents = @import("../idents.zig");
const scan = @import("../scan.zig");

const eventVariantName = idents.eventVariantName;
const pathToPascal = idents.pathToPascal;
const dedupePinStyles = scan.dedupePinStyles;

/// Mixin factory for `Codegen`. Reads `event_names`, `plugin_events`,
/// `plugin_pin_styles`, `allocator` from `self`.
pub fn Mixin(comptime Self: type) type {
    return struct {
        /// Game events + Plugin events block.
        ///
        /// `GameEvents` is the game-side scan of `events/*.zig`
        /// (labelle-engine#422 — shipped). `PluginEvents` is the
        /// plugin-side discovery added by RFC-PLUGIN-EVENTS phase 1: walks
        /// every plugin module with `@hasDecl(plugin, "Events")` at
        /// comptime — same convention as `Components`/`Systems`/
        /// `GizmoCategories` — and folds each `pub const <name> = struct`
        /// declaration into a single tagged union with plugin-qualified
        /// variant names (`<plugin>__<event>`). `.` is not a valid Zig
        /// identifier character, so the on-disk JSONC dot form
        /// (`box2d.collision_begin`) resolves to the qualified tag
        /// (`box2d__collision_begin`) when flow-codegen consumes this in
        /// phase 3.
        ///
        /// Both decls are `pub` so flow-codegen-emitted hook handler
        /// structs (phase 3) can reference them by name via the existing
        /// module-level import path. The resolver is the comptime
        /// reflection itself (option (a) — generated comptime decl rather
        /// than a JSON sidecar): `@FieldType(PluginEvents, "<tag>")` and
        /// `@typeInfo(...).@"struct".fields` give the payload field list
        /// without a separate registry file to keep in sync.
        ///
        /// **Phase 3 widening:** the engine's `Game.emit(event: GameEvents)`
        /// accepts a single union type, but plugins (RFC-PLUGIN-EVENTS phase
        /// 2, e.g. labelle-box2d 6c44691) now `game.emit(.{ .box2d__... = .{...} })`.
        /// So when plugins declare events, `GameEvents` is **widened** to the
        /// union of the game-side scan and `PluginEvents` — emitted via
        /// `pub const GameEvents = engine.core.MergeHookPayloads(.{ GameEventsRaw, PluginEvents })`
        /// — and `GameConfig(..., GameEvents)` (the existing engine template
        /// slot, unchanged) now sees the merged type. The raw game-side scan
        /// is kept under a private alias `GameEventsRaw` so the merge has a
        /// stable second operand even when `events/*.zig` is empty.
        ///
        /// No engine template change required: the `GameEvents,` token in
        /// `codegen/main.zig.template` keeps its v1 shape; only the
        /// **meaning** of `GameEvents` widens when plugins declare events.
        /// Every project without plugin events keeps the v1 semantics
        /// verbatim — `GameEvents` is either `void` or the events/*.zig
        /// union.
        pub fn writeGameEventsBlock(self: *Self, w: anytype) !void {
            const allocator = self.allocator;
            const event_names = self.event_names;
            const plugin_pin_styles = self.plugin_pin_styles;

            // Gate on **discovered** plugin events, not declared plugins —
            // a project can declare a plugin whose `Events` is empty/absent
            // (e.g. the plugin-controllers demo plugin), and in that case
            // we want the v1 emission shape verbatim ("no plugin events"),
            // not a `GameEvents = PluginEvents = void` path that would
            // confuse downstream consumers.
            const has_plugin_events_local = self.plugin_events.len > 0;
            // Pack events (Packs RFC §4, #439) are dir-scanned `events/*.zig`
            // exactly like the game root's, so they count as game events: they
            // widen `GameEvents` and fold into `AllHookPayloads` the same way.
            // Script-DECLARED events (labelle-engine#772) count the same way —
            // their payload structs live in the generated `scripting_events.zig`
            // instead of `events/*.zig`, but the union rows are bus-identical.
            const has_game_events_local = event_names.len > 0 or self.hasPackEvents() or
                self.declaredEvents().len > 0;

            // The raw game-side scan keeps its v1 shape; the alias is what
            // the merge feeds on when plugins are also in play. For
            // plugin-less projects with no game events, `GameEventsRaw` is
            // omitted and `GameEvents = void` is emitted directly (the
            // pre-RFC shape every shipped game already has).
            if (has_plugin_events_local) {
                // Need a name for the raw events to feed into the merge.
                // Without game events, the alias is `void` and we end up
                // with `GameEvents = PluginEvents` directly (skipping the
                // merge — `MergeHookPayloads` rejects `void`).
                if (has_game_events_local) {
                    try w.writeAll("pub const GameEventsRaw = union(enum) {\n");
                    var pascal_buf: [128]u8 = undefined;
                    for (event_names) |name| {
                        const ident = eventVariantName(name);
                        const pascal = pathToPascal(name, &pascal_buf);
                        try w.print("    {s}: {s}.{s},\n", .{ ident, ident, pascal });
                    }
                    try writePackEventVariants(self, w, &pascal_buf);
                    try writeDeclaredEventVariants(self, w, &pascal_buf);
                    try w.writeAll("};\n\n");
                }
                try self.writePluginEventsBlock(w);
                if (has_game_events_local) {
                    try w.writeAll("pub const GameEvents = engine.core.MergeHookPayloads(.{ GameEventsRaw, PluginEvents });\n\n");
                } else {
                    try w.writeAll("pub const GameEvents = PluginEvents;\n\n");
                }
            } else {
                // No plugins — the v1 emission verbatim, every shipped
                // pre-RFC game keeps its exact shape. One exception
                // (labelle-assembler#630): when discovery DID find plugin
                // events but the consumption filter elided every one of
                // them, this branch is also taken (no `PluginEvents` decl,
                // `GameEvents` keeps the v1 shape and the engine's
                // `has_events` gate elides the event buffer) — emit the
                // per-event elision comments here so the generated file
                // still explains where the variants went.
                for (self.plugin_events_elided) |e| {
                    try w.print("// elided (no consumer): {s}__{s}\n", .{ e.plugin_sanitized, e.event_name });
                }
                if (has_game_events_local) {
                    try w.writeAll("pub const GameEvents = union(enum) {\n");
                    var pascal_buf: [128]u8 = undefined;
                    for (event_names) |name| {
                        const ident = eventVariantName(name);
                        const pascal = pathToPascal(name, &pascal_buf);
                        try w.print("    {s}: {s}.{s},\n", .{ ident, ident, pascal });
                    }
                    try writePackEventVariants(self, w, &pascal_buf);
                    try writeDeclaredEventVariants(self, w, &pascal_buf);
                    try w.writeAll("};\n\n");
                } else {
                    try w.writeAll("pub const GameEvents = void;\n\n");
                }
            }

            // RFC-FLOW-VOCABULARY phase 2 — emit the PluginFlowNodes and
            // PluginPinStyles registries inside the same generated block so
            // the engine template stays unchanged. Both decls are always
            // emitted (empty `struct {}` when discovery found nothing) so
            // downstream consumers can do uniform reflection. See the
            // file header on `writePluginFlowNodesBlock` for the
            // mechanism + RFC §5 (game-script-as-source) for the scope.
            try self.writePluginFlowNodesBlock(w);
            const deduped_styles = try dedupePinStyles(allocator, plugin_pin_styles);
            defer allocator.free(deduped_styles);
            try self.writePluginPinStylesBlock(w, deduped_styles);
            // RFC-FLOW-VOCABULARY §2 / O4 — emit PluginCoercions next to
            // the other registries. The block carries its own `resolve` +
            // `findByTypes` helpers so flow-codegen + the editor can do
            // the wire-fit lookup without re-iterating the decls.
            try self.writePluginCoercionsBlock(w);
        }

        /// Emit `<pfx>__<ident>: <pfx>__<ident>.<Pascal>,` union variants for
        /// every pack event (Packs RFC §4, #439), matching the game-root event
        /// loop's shape but under the invisible `<pack>__` prefix (#440). The
        /// `<pfx>__<ident>` alias is defined by `writeEventImportsBlock` as
        /// `@import("<pack.import_prefix>/events/<name>.zig")`; the variant tag
        /// and the type reference both use it, so a pack and the game root that
        /// both name `hit.zig` no longer collide on the bare `hit`.
        fn writePackEventVariants(self: *Self, w: anytype, pascal_buf: *[128]u8) !void {
            var pack_prefix_buf: [128]u8 = undefined;
            for (self.pack_scans) |pack| {
                const prefix = scan.packNamespacePrefix(pack.name, &pack_prefix_buf);
                for (pack.event_names) |name| {
                    const ident = eventVariantName(name);
                    const pascal = pathToPascal(name, pascal_buf);
                    try w.print("    {s}__{s}: {s}__{s}.{s},\n", .{ prefix, ident, prefix, ident, pascal });
                }
            }
        }

        /// Emit `<name>: @import("scripting_events.zig").<Pascal>,` union
        /// variants for every script-declared event (labelle-engine#772).
        /// Bus-identical to a Zig-authored `events/<name>.zig` row — same
        /// bare variant tag (the user's hook handler references it by
        /// name), same PascalCase payload transform (`pathToPascal`, the
        /// exact transform game-event rows use) — only the payload's home
        /// differs: the declare phase's ONE generated file at the target
        /// root, imported inline (no module-scope alias, so a game event
        /// named anything at all can never collide with it). Collisions
        /// with game/pack event variants were rejected at generate time by
        /// `scripting_declare.checkEventCollisions`. Empty for every
        /// declaration-less project — the block stays byte-identical.
        fn writeDeclaredEventVariants(self: *Self, w: anytype, pascal_buf: *[128]u8) !void {
            for (self.declaredEvents()) |ev| {
                const pascal = pathToPascal(ev.name, pascal_buf);
                try w.print("    {s}: @import(\"scripting_events.zig\").{s},\n", .{ ev.name, pascal });
            }
        }
    };
}
