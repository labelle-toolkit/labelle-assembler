//! Editor-preview codegen snippets (labelle-studio Play mode, Phase 3).
//! Extracted from `preview.zig` (behavior-preserving).

// ============================================================
// Editor-preview codegen (labelle-studio Play mode, Phase 3)
// ============================================================
//
// Unlike the LABELLE_PREVIEW blocks above — emitted ALWAYS and gated at
// runtime — the editor-preview splice is emitted ONLY when the assembler
// ran an editor-preview generation (`LABELLE_EDITOR_PREVIEW=1` in the
// environment, or `--editor-preview`; wasm platform only). Two reasons:
//
//   1. It compiles against `engine.editor_api`, which only exists on
//      engines that ship the editor contract — an emit-always splice
//      would break every project on an older engine pin.
//   2. The matching `editor_*` C exports must be named in the emcc
//      link's `-sEXPORTED_FUNCTIONS` list, and emcc HARD-ERRORS on
//      exported symbols that don't exist ("wasm-ld: error: symbol
//      exported via --export not found", verified on emcc 4.0.x). So
//      exports and splice must toggle together — both keyed on the same
//      `cfg.editor_preview` (the build.zig side threads it into the
//      backend hook's `post_wire` as `.editor_preview`).
//
// The three snippets fill the `{{editor_bind}}` / `{{editor_sim_open}}` /
// `{{editor_sim_close}}` holes a backend's `templates/wasm.txt` declares
// (labelle-bgfx ≥ 0.6.1 first). Hole placement in the template is chosen
// so an EMPTY fill reproduces the pre-preview bytes exactly — non-preview
// output stays byte-identical (golden-locked).
//
// Engine contract (fixed; the engine implements exactly this):
//   - `bind(&g, &runner)`  — once at startup, right after game/runner
//     init + PluginControllers.setup, BEFORE emscripten_set_main_loop.
//   - `shouldTick() bool`  — gates the SIM half of `gameFrame`
//     (runner.tick / PluginSystems tick+postTick / dispatchEvents /
//     g.tick(dt)). The RENDER half runs unconditionally.
//   - `frame(&g)`          — right AFTER the (possibly skipped) sim
//     block, before render; per-frame editor sync (scene ops / pick /
//     camera).

/// `{{editor_bind}}` — inside the wasm `main()`, immediately after
/// `{{setup_code}}` (whose tail is runner.setup + PluginSystems/
/// PluginControllers.setup) and immediately before the
/// `emscripten_set_main_loop` call. `g` and `runner` are the wasm
/// template's module-scope vars, so their addresses are stable for the
/// program's lifetime.
///
/// The comptime `@hasDecl` guard turns a stale engine pin (no
/// `editor_api`) into an actionable message instead of a bare
/// "no member named 'editor_api'" naming generated code.
pub const EDITOR_PREVIEW_BIND =
    \\    // ── Editor preview (labelle-studio Play mode) ──────────────────────
    \\    // Bind the engine's editor API once at startup — after game/runner
    \\    // init + plugin setup above, BEFORE the emscripten main loop starts.
    \\    // The `editor_*` C exports this arms are kept alive by the emcc
    \\    // link's -sEXPORTED_FUNCTIONS list (backend hook, editor-preview arm).
    \\    comptime {
    \\        if (!@hasDecl(engine, "editor_api")) @compileError(
    \\            "editor-preview build: this labelle-engine does not ship `editor_api` — " ++
    \\                "upgrade the project's engine pin (LABELLE_EDITOR_PREVIEW requires an editor_api-capable engine)",
    \\        );
    \\    }
    \\    engine.editor_api.bind(&g, &runner);
    \\
;

/// `{{editor_sim_open}}` — opens the sim gate at the top of `gameFrame`'s
/// SIM half (right before `{{tick_code}}`). Paired with
/// `EDITOR_PREVIEW_SIM_CLOSE`; the wrapped block keeps its original
/// indentation (Zig doesn't care, and re-indenting template-injected
/// scalars would break the empty-fill byte-identity property).
pub const EDITOR_PREVIEW_SIM_OPEN =
    \\    // Editor preview: the editor gates the SIM half (pause / step);
    \\    // the render half below runs unconditionally.
    \\    if (engine.editor_api.shouldTick()) {
    \\
;

/// `{{editor_sim_close}}` — closes the sim gate right after `g.tick(dt);`
/// and runs the per-frame editor sync. `frame(&g)` sits AFTER the
/// (possibly skipped) sim block and BEFORE the render half — the
/// contract-specified placement (render-independent).
pub const EDITOR_PREVIEW_SIM_CLOSE =
    \\    }
    \\    // Editor preview: per-frame editor sync (scene ops / pick / camera).
    \\    engine.editor_api.frame(&g);
    \\
;
