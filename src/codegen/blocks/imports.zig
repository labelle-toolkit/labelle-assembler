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

        /// External-backend contract-verification guard (epic #386 Phase 6b)
        /// plus per-sub-surface contract-VERSION asserts (contract versioning,
        /// labelle-assembler#453 item 1).
        ///
        /// Emitted at module root (right after the hook imports) ONLY for an
        /// external `backend_package`. A fetched out-of-tree backend has no
        /// enum-path codegen to vet it, so we assert its modules satisfy
        /// labelle-core's render / window / input contracts up front. A missing
        /// required decl then fails with a decl-naming message from
        /// `core.assert{Backend,Window,Input}` at the very start of the build,
        /// instead of surfacing as a deep error from inside engine wiring.
        ///
        /// On top of the shape check, each sub-surface gets a DIRECTIONAL
        /// version assert: a backend may publish `targets_<surface>_contract`
        /// (a `u32`) declaring which revision of that contract it was built
        /// against. We compare it to labelle-core's `<SURFACE>_CONTRACT_VERSION`
        /// and `@compileError` on ANY mismatch, naming which side to upgrade:
        ///   * backend N  >  core M  -> the backend was built against a newer
        ///     contract than this labelle-core provides -> upgrade labelle-core.
        ///   * backend N  <  core M  -> a breaking contract change landed in
        ///     labelle-core the backend hasn't adopted -> upgrade the backend.
        /// Both checks are wrapped in `@hasDecl(...)`, so a backend that hasn't
        /// adopted `targets_*` yet is completely unaffected -- the guarded body
        /// is not analyzed when the guard is comptime-false. This is the
        /// no-flag-day property: opting in is per-backend, per-surface.
        ///
        /// Built-in backends emit nothing here -- they're vetted by the enum path
        /// (and their own in-module asserts). (Post-#386 every backend resolves
        /// to an external provider package, so this branch always runs; the
        /// `isExternal()` gate is retained as defensive dead code.)
        ///
        /// `backend_gfx` / `backend_window` / `backend_input` / `backend_audio`
        /// and `labelle-core` are all root module deps of the generated
        /// `main.zig`, so the imports resolve without any extra wiring.
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
                \\
                \\    // --- Directional per-sub-surface contract-VERSION asserts (labelle-assembler#453) ---
                \\    // Each surface is checked only when the backend opts in by declaring
                \\    // `targets_<surface>_contract` (@hasDecl guard = no flag day). A mismatch in
                \\    // either direction @compileError's, naming which side to upgrade.
                \\    const _bc_gfx = @import("backend_gfx");
                \\    const _bc_window = @import("backend_window");
                \\    const _bc_input = @import("backend_input");
                \\    const _bc_audio = @import("backend_audio");
                \\
            );
            const Surface = struct {
                mod: []const u8,
                decl: []const u8,
                core: []const u8,
                human: []const u8,
            };
            const surfaces = [_]Surface{
                .{ .mod = "_bc_gfx", .decl = "targets_draw_contract", .core = "DRAW_CONTRACT_VERSION", .human = "draw" },
                .{ .mod = "_bc_gfx", .decl = "targets_loader_contract", .core = "LOADER_CONTRACT_VERSION", .human = "loader" },
                .{ .mod = "_bc_window", .decl = "targets_window_contract", .core = "WINDOW_CONTRACT_VERSION", .human = "window" },
                .{ .mod = "_bc_input", .decl = "targets_input_contract", .core = "INPUT_CONTRACT_VERSION", .human = "input" },
                .{ .mod = "_bc_audio", .decl = "targets_audio_playback_contract", .core = "AUDIO_PLAYBACK_CONTRACT_VERSION", .human = "audio-playback" },
                .{ .mod = "_bc_audio", .decl = "targets_audio_loader_contract", .core = "AUDIO_LOADER_CONTRACT_VERSION", .human = "audio-loader" },
            };
            for (surfaces) |s| {
                try w.print(
                    \\    if (@hasDecl({[mod]s}, "{[decl]s}")) {{
                    \\        if ({[mod]s}.{[decl]s} > _backend_contract_core.{[core]s})
                    \\            @compileError(std.fmt.comptimePrint("backend targets {[human]s}-contract v{{d}} but this labelle-core provides v{{d}} -- upgrade labelle-core", .{{ {[mod]s}.{[decl]s}, _backend_contract_core.{[core]s} }}));
                    \\        if ({[mod]s}.{[decl]s} < _backend_contract_core.{[core]s})
                    \\            @compileError(std.fmt.comptimePrint("backend targets {[human]s}-contract v{{d}} but this labelle-core expects v{{d}} -- a breaking {[human]s}-contract change landed; upgrade the backend", .{{ {[mod]s}.{[decl]s}, _backend_contract_core.{[core]s} }}));
                    \\    }}
                    \\
                , .{ .mod = s.mod, .decl = s.decl, .core = s.core, .human = s.human });
            }
            try w.writeAll(
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
