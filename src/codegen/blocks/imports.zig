//! Top-of-file `@import` blocks + the JSONC scene-loader block emitted
//! into the generated `main.zig`.
//!
//! Extracted from `main_template.zig`'s orchestrator (labelle-assembler
//! file-size refactor) following the `blocks/*.zig` mixin pattern. Each
//! writer consumes the scan slices already borrowed onto `Codegen`
//! (`hook_names`, `event_names`, `enum_names`, `jsonc_scene_names`,
//! `gizmo_names`) and the project `cfg`, then writes its block into the
//! caller's `Allocating` writer — no allocations, no template state,
//! byte-identical to the inline regions it replaces.
//!
//! The JSONC scene writer also calls back into the
//! `SceneManifestsMixin` methods (`writeSceneAssetManifests` /
//! `writeSceneInitialStateManifests`) via `self`, preserving the exact
//! emit order of the original inline block.

const std = @import("std");
const idents = @import("../idents.zig");
const scan = @import("../scan.zig");

const pathToIdent = scan.pathToIdent;
const eventVariantName = idents.eventVariantName;

/// Mixin factory for `Codegen`. Reads `hook_names`, `event_names`,
/// `enum_names`, `jsonc_scene_names`, `prefab_names`, `gizmo_names`,
/// and `cfg` from `self`.
pub fn Mixin(comptime Self: type) type {
    return struct {
        /// Hook imports block.
        ///
        /// The wasm32-emscripten panic-handler override
        /// (labelle-assembler#141) is emitted at the top of this block so
        /// the two `pub const` root declarations land near
        /// `const std = @import("std")` in the generated `main.zig`. They
        /// MUST appear at module root for Zig to honor them, and this
        /// block is rendered right after the stdlib imports in
        /// `labelle-engine/codegen/main.zig.template`.
        pub fn writeHookImportsBlock(self: *Self, w: anytype, ident_buf: *[256]u8) !void {
            const cfg = self.cfg;
            const hook_names = self.hook_names;
            if (cfg.platform == .wasm) {
                try w.writeAll(@import("../preview.zig").WASM_PANIC_WORKAROUND);
            }
            if (hook_names.len > 0) {
                try w.writeAll("\n// --- Hook imports ---\n");
                for (hook_names) |name| {
                    const ident = pathToIdent(name, ident_buf);
                    try w.print("const {s} = @import(\"hooks/{s}.zig\");\n", .{ ident, name });
                }
            }
        }

        /// External-backend contract-verification guard (epic #386 Phase 6b).
        ///
        /// Emitted at module root (right after the hook imports) ONLY for an
        /// external `backend_package`. A fetched out-of-tree backend has no
        /// enum-path codegen to vet it, so we assert its three modules satisfy
        /// labelle-core's render / window / input contracts up front. A missing
        /// required decl then fails with a decl-naming message from
        /// `core.assert{Backend,Window,Input}` at the very start of the build,
        /// instead of surfacing as a deep error from inside engine wiring.
        ///
        /// Built-in backends emit nothing here — they're vetted by the enum path
        /// (and their own in-module asserts), so generated output for every
        /// built-in backend is byte-identical to before.
        ///
        /// `backend_gfx` / `backend_window` / `backend_input` and `labelle-core`
        /// are all root module deps of the generated `main.zig`, so the imports
        /// resolve without any extra wiring.
        pub fn writeBackendContractCheck(self: *Self, w: anytype) !void {
            if (!self.cfg.isExternal()) return;
            try w.writeAll(
                \\
                \\// --- External backend contract verification (labelle-assembler#386 Phase 6b) ---
                \\// Assert the fetched out-of-tree backend satisfies labelle-core's render /
                \\// window / input contracts, naming any missing decl HERE rather than deep in
                \\// engine wiring. Built-in backends skip this (vetted by the enum path).
                \\comptime {
                \\    const _backend_contract_core = @import("labelle-core");
                \\    _backend_contract_core.assertBackend(@import("backend_gfx"));
                \\    _backend_contract_core.assertWindow(@import("backend_window"));
                \\    _backend_contract_core.assertInput(@import("backend_input"));
                \\}
                \\
            );
        }

        /// Event imports block.
        ///
        /// Use the file basename (no path escape) as the import alias so
        /// the alias matches the union variant name below, which in turn
        /// matches the user's handler function name. Plugin events use
        /// `pathToIdent` because plugin-namespaced names
        /// (`<plugin>__<event>`) need escapes for path safety; in-tree
        /// game events do not — the basename is already a valid Zig
        /// identifier (the user's handler references it).
        pub fn writeEventImportsBlock(self: *Self, w: anytype) !void {
            const event_names = self.event_names;
            if (event_names.len > 0) {
                try w.writeAll("\n// --- Event imports ---\n");
                for (event_names) |name| {
                    const ident = eventVariantName(name);
                    try w.print("const {s} = @import(\"events/{s}.zig\");\n", .{ ident, name });
                }
            }
        }

        /// Enum imports block.
        pub fn writeEnumImportsBlock(self: *Self, w: anytype, ident_buf: *[256]u8) !void {
            const enum_names = self.enum_names;
            if (enum_names.len > 0) {
                try w.writeAll("\n// --- Enum imports ---\n");
                for (enum_names) |name| {
                    const ident = pathToIdent(name, ident_buf);
                    try w.print("const {s} = @import(\"enums/{s}.zig\");\n", .{ ident, name });
                }
            }
        }

        /// JSONC scene block — embedded scene loaders + scene asset /
        /// initial-state manifests.
        pub fn writeJsoncSceneBlock(self: *Self, w: anytype, ident_buf: *[256]u8) !void {
            const jsonc_scene_names = self.jsonc_scene_names;
            const prefab_names = self.prefab_names;
            const gizmo_names = self.gizmo_names;
            if (jsonc_scene_names.len > 0 or prefab_names.len > 0) {
                try w.writeAll("\n// --- JSONC scene loaders (embedded) ---\n");
                if (gizmo_names.len > 0) {
                    try w.writeAll("const JsoncBridge = engine.JsoncSceneBridgeWithGizmos(AssembledGame, Components, Gizmos);\n");
                } else {
                    try w.writeAll("const JsoncBridge = engine.JsoncSceneBridge(AssembledGame, Components);\n");
                }
                for (jsonc_scene_names) |name| {
                    const ident = pathToIdent(name, ident_buf);
                    try w.print(
                        \\const jsonc_{s}_loader = struct {{
                        \\    const embedded_source = @embedFile("scenes/{s}.jsonc");
                        \\    fn load(game: *AssembledGame) anyerror!void {{
                        \\        return JsoncBridge.loadSceneFromSource(game, embedded_source, "prefabs");
                        \\    }}
                        \\}}.load;
                        \\
                    , .{ ident, name });
                }

                // ── Scene → assets map (Asset Streaming RFC, ticket #46) ────
                // Emit a comptime-visible struct that maps each scene's
                // assembler name to the `assets:` array declared at the top of
                // its .jsonc file. Empty arrays are emitted explicitly so the
                // labelle-engine consumer (issue #445) can iterate `entries`
                // without checking for missing keys. See also the upcoming
                // labelle-engine SceneEntry.assets field — this block is the
                // codegen contract that ticket reads.
                try self.writeSceneAssetManifests(w, ident_buf);

                // Same pattern for scene-declared `initial_state`
                // (labelle-engine#500) — emit only the scenes that opted in,
                // so the generated inline-for is a no-op for back-compat.
                try self.writeSceneInitialStateManifests(w);
            }
        }
    };
}
