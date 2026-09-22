const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // CLI version stamped into a freshly scaffolded project.labelle's
    // `.labelle_version`. Curated WITH the framework trio below (bump
    // together): it must be a real released CLI version — the release
    // workflow used to stamp the ASSEMBLER tag into this (and the trio),
    // scaffolding nonsense pins like `labelle_version = "0.91.0"`
    // (labelle-cli#322); release builds no longer override any of these.
    const cli_version: []const u8 = b.option([]const u8, "cli_version", "CLI version string") orelse "1.61.2";
    // Framework version defaults stamped into a freshly scaffolded
    // project.labelle by `init`. These MUST be real, fetchable release
    // versions — a fresh project has to build out of the box. They used to
    // fall back to `cli_version` ("dev" in a non-release build), which the
    // fetcher then mapped to a bogus `vdev` git ref (issue #159).
    // Keep this trio a MUTUALLY COMPATIBLE set: a fresh `labelle init` resolves
    // these defaults, so a mismatch fails `labelle build` before any user code.
    // Set verified end-to-end STANDALONE (init → install → generate → full
    // compile against the published release tarballs, scratch LABELLE_HOME,
    // no sibling checkouts) for core 2.0.0 / engine 3.0.0 / gfx 2.0.0 with
    // labelle-bgfx 0.21.0 on the bgfx_desktop target (PR #733), after the
    // 1.32.0 / 2.12.2 / 1.30.1 predecessor was verified the same way on
    // bgfx/null/raylib/sokol (#736). labelle-cli's `versions.zon` (the set
    // its `labelle upgrade all` writes) still says 1.28.0 / 2.12.2 / 1.30.1
    // through cli v1.67.0 — BEHIND this trio; bump the cli side to match.
    // Keep the two in step: when they drift, `init` scaffolds a project the
    // very next `upgrade` rewrites.
    //
    // The hard floor inside the trio (#679): gfx >= 1.30.0 re-exports
    // `core.TextureId` instead of declaring its own (labelle-gfx#328,
    // RFC-TEXTURE-ID-TYPING), and that type landed in core 1.28.0. The
    // assembler unifies every package onto the PROJECT's `core_version`, so a
    // gfx 1.30.x pin against core < 1.28.0 dies in the dependency itself:
    //   labelle-gfx/src/types.zig:41:27: error: root source file struct
    //   'root' has no member named 'TextureId'
    // Engine >= 2.12.1 is the matching half (`game.nativeTextureId` compiles
    // against the typed gfx surface, labelle-engine#813 phase 4).
    //
    // core 1.x + engine 2.x is the SUPPORTED pairing, not a mismatch: core has
    // never published a 2.x, and engine v2.0.0 was a break in its own scene
    // loader. See labelle-cli#358, which fixed the check that claimed
    // otherwise. Earlier floors still hold: engine >= 2.11.0 needs
    // core >= 1.27.0 (allocator-taking `ChildrenComponent`,
    // labelle-core#65/#66) — a real module dependency, so an older core
    // fails to compile — and gfx >= 1.28.0 for the post-fx driver. That
    // second one is a CURATED floor, not a compile break: the engine takes
    // no direct gfx dependency (the renderer arrives via `RenderImpl`) and
    // its post-fx passthrough is `@hasDecl`-gated, so an older gfx
    // "compiles to a no-op" (labelle-engine `src/game/post_fx_mixin.zig`)
    // — it BUILDS, and silently drops the post-fx stack. A curated set has
    // to be coherent, not merely compilable, so the trio test asserts it.
    //
    // (v0.96.0 bumped engine 2.7.0 → 2.11.0 while leaving core at 1.26.0, so
    // every fresh `labelle init` scaffold failed to compile.)
    //
    // core 2.0.0 / gfx 2.0.0 / engine 3.0.0 (PR #733, game-owned shader
    // materials): the builtin `.bgfx` provider default (`src/config.zig`
    // builtinProvider) is labelle-bgfx 0.21.0, the first contract-v2 backend.
    // It names core's `shader_material` contract UNGATED and its
    // `MATERIAL_CONTRACT_VERSION == 2`, both of which only core >= 2.0.0
    // declares — so its HARD core floor is 2.0.0 (a compile break inside the
    // backend on any older core), and the assembler's generated materials
    // module `@compileError`s on any core below it. gfx 2.0.0 and engine
    // 3.0.0 are the releases built against that core (their build.zig.zon
    // pins: gfx → core 2.0.0, engine → gfx 2.0.0); the specialized
    // PixelWater contract the 1.32.0 core carried is GONE in 2.0.0, so the
    // 1.x/2.12.x/1.30.x trio and bgfx 0.20.0 do not mix with any of these.
    // The four move TOGETHER (the #731 lesson: bumping the provider without
    // the core, or vice versa, ships a default that fails at the first
    // `labelle build`). `src/init_cmd.zig`'s `bgfx_core_floors` carries the
    // 0.21.0 → 2.0.0 floor and its "scaffold core default pairs with the
    // builtin bgfx provider" test asserts the pairing; `checkTrioFloors`
    // asserts the trio.
    // Bump all three together when moving the engine default (their
    // build.zig.zon pins/floors must agree — read them from the tags), and
    // keep `src/init_cmd.zig`'s "scaffold pins a MUTUALLY COMPATIBLE trio"
    // test satisfied — it encodes the floors below as assertions.
    const core_version: []const u8 = b.option([]const u8, "core_version", "Default core library version") orelse "2.0.0";
    const engine_version: []const u8 = b.option([]const u8, "engine_version", "Default engine library version") orelse "3.0.1";
    const gfx_version: []const u8 = b.option([]const u8, "gfx_version", "Default gfx library version") orelse "2.0.0";
    // Version this assembler binary stamps into a freshly scaffolded
    // project.labelle's `assembler_version` field.
    //
    // A RELEASE build gets it from the tag (`-Dassembler_version`, set by
    // .github/workflows/release.yml). Everything else is a dev build, and
    // says so.
    //
    // It used to fall back to `build.zig.zon`'s `.version`, which drifts:
    // that field read 0.77.0 while the released tag was v0.99.0 (#670).
    // A fresh `labelle-assembler init` therefore scaffolded
    // `assembler_version = "0.77.0"` — a real, ancient, resolvable release,
    // so the project built and quietly used a two-year-old assembler.
    // A plausible-but-wrong version is worse than an obviously-fake one:
    // `0.0.0-dev` fails to resolve loudly, which is the correct outcome for
    // a scaffold produced by an unreleased binary.
    const assembler_version: []const u8 = b.option([]const u8, "assembler_version", "Default assembler version for `init`") orelse "0.0.0-dev";

    const zspec_dep = b.dependency("zspec", .{ .target = target, .optimize = optimize });
    const flow_codegen_dep = b.dependency("flow_codegen", .{ .target = target, .optimize = optimize });
    const flow_codegen_module = flow_codegen_dep.module("flow_codegen");

    const options = b.addOptions();
    options.addOption([]const u8, "cli_version", cli_version);
    options.addOption([]const u8, "core_version", core_version);
    options.addOption([]const u8, "engine_version", engine_version);
    options.addOption([]const u8, "gfx_version", gfx_version);
    options.addOption([]const u8, "assembler_version", assembler_version);

    // Test-only options: the exact zig binary driving THIS build, so the
    // plugin-build-steps e2e (`test/plugin_build_steps_tests.zig`, #586) can
    // run a real `zig build` of a spliced project without assuming a `zig`
    // on PATH (the suite's hermeticity rule — see scripting_declare.zig).
    // Deliberately NOT on `options`: that module compiles into release
    // binaries, and a machine-local path must never be embedded there.
    const test_options = b.addOptions();
    test_options.addOption([]const u8, "zig_exe", b.graph.zig_exe);
    const test_options_module = test_options.createModule();

    const generator_module = b.addModule("generator", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    generator_module.addOptions("build_options", options);
    generator_module.addImport("flow_codegen", flow_codegen_module);

    // ── Assembler binary ───────────────────────────────────────────────
    const assembler_exe = b.addExecutable(.{
        .name = "labelle-assembler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    assembler_exe.root_module.addOptions("build_options", options);
    assembler_exe.root_module.addImport("flow_codegen", flow_codegen_module);
    // `src/flow_catalog/json_writer.zig` calls `std.posix.system.clock_gettime`
    // for the sidecar's `generated_at` timestamp. On Linux/macOS Zig finds
    // the libc symbols implicitly via the system loader, but Windows
    // cross-compiles require explicit `linkLibC()` (Zig 0.16's `std.time.timestamp`
    // was removed). Cheap addition for a build tool that already depends on
    // libc transparently.
    assembler_exe.root_module.link_libc = true;
    b.installArtifact(assembler_exe);

    const assembler_run = b.addRunArtifact(assembler_exe);
    if (b.args) |args| assembler_run.addArgs(args);
    const run_step = b.step("run", "Run the labelle-assembler binary");
    run_step.dependOn(&assembler_run.step);

    // ── Tests ───────────────────────────────────────────────────────────
    const test_step = b.step("test", "Run assembler tests");

    // Unit tests from src/
    const src_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    src_tests.root_module.addOptions("build_options", options);
    src_tests.root_module.addImport("flow_codegen", flow_codegen_module);
    src_tests.root_module.link_libc = true; // see assembler_exe comment above
    test_step.dependOn(&b.addRunArtifact(src_tests).step);

    // Subcommand tests — `src/main.zig` is the binary's root and reaches
    // the subcommand modules (`init_cmd`, `cache_cmd`) that `src/root.zig`
    // (the `generator` library) intentionally does not import.
    const bin_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bin_tests.root_module.addOptions("build_options", options);
    bin_tests.root_module.addImport("flow_codegen", flow_codegen_module);
    bin_tests.root_module.link_libc = true; // see assembler_exe comment above
    test_step.dependOn(&b.addRunArtifact(bin_tests).step);

    // ── `test-materials`: the materials pipeline, by EXPLICIT MODULE ────
    //
    // This used to be a `--test-filter` over `src/root.zig`:
    //
    //     .filters = &.{ "material_schema", "material_pipeline", "component_collisions" }
    //
    // and it selected ZERO material tests (#741). With `--test-filter`
    // active, `src/root.zig`'s named tests are dropped and only the
    // anonymous `test { _ = @import(...) }` discovery blocks survive
    // (`*.test_0` — those are never filtered). None of those blocks names a
    // material module, so `material_pipeline.zig` was never analyzed and its
    // tests never existed to be matched. NO filter string fixed it: even
    // `--test-filter "materials build emission"`, the literal name of a
    // `material_pipeline` test, still ran the same nine assertion-free
    // `test_0` blocks. Proof: force-failing that test left
    // `zig build test-materials` at "127/127 tests passed" while
    // `zig build test` went to "2915/2929 passed (2 failed)".
    //
    // An explicit test root cannot drift the way a name filter can, and
    // `assertMaterialTestRootCoverage` below fails configure if a new
    // `src/material_*.zig` is not imported by it.
    //
    // The SAME run artifact feeds `test-materials` and the full `test` step,
    // so the two can never disagree on the material test count.
    assertMaterialTestRootCoverage(b);
    const material_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/material_test_root.zig"), .target = target, .optimize = optimize }) });
    material_tests.root_module.addOptions("build_options", options);
    material_tests.root_module.addImport("flow_codegen", flow_codegen_module);
    material_tests.root_module.link_libc = true;
    const material_test_run = b.addRunArtifact(material_tests);
    const material_test_step = b.step("test-materials", "Validate material JSON, descriptor generation and build wiring");
    material_test_step.dependOn(&material_test_run.step);
    test_step.dependOn(&material_test_run.step);
    const shaderc_test_exe = b.option([]const u8, "shaderc", "Host shaderc for material integration tests") orelse b.graph.environ_map.get("LABELLE_SHADERC");
    const material_test_core = b.option([]const u8, "material-test-core", "Local core checkout for material integration test");
    const material_test_zbgfx = b.option([]const u8, "material-test-zbgfx", "Pinned zbgfx directory for material integration test");
    const material_integration = b.step("test-material-integration", "Compile shaders/descriptors and verify include cache invalidation with a real shaderc");
    if (shaderc_test_exe != null and material_test_core != null and material_test_zbgfx != null) {
        const python = b.option([]const u8, "python", "Python executable for integration tests") orelse (if (@import("builtin").os.tag == .windows) "py" else "python3");
        const integration = b.addSystemCommand(&.{python});
        if (@import("builtin").os.tag == .windows and std.mem.eql(u8, python, "py")) integration.addArg("-3");
        integration.addFileArg(b.path("test/material_pipeline_e2e.py"));
        integration.addArgs(&.{ "--zig", b.graph.zig_exe, "--shaderc", shaderc_test_exe.?, "--core", material_test_core.?, "--zbgfx", material_test_zbgfx.? });
        material_integration.dependOn(&integration.step);
    } else {
        material_integration.dependOn(&b.addFail("Supply -Dshaderc=PATH (or LABELLE_SHADERC), -Dmaterial-test-core=DIR and -Dmaterial-test-zbgfx=DIR").step);
    }

    // ── `test-cache`: the local-slot cache machinery, alone ─────────────
    //
    // The Windows CI job runs THIS, not `test`. `zig build test` on Windows
    // is red for ~33 pre-existing failures across the scripting-splice,
    // panel-validate and pack-check suites (path-separator handling), which
    // a Windows job added for #688 neither caused nor should be expected to
    // fix — see the tracking issue linked from that PR. A job that is red
    // for unrelated reasons guards nothing, so this step narrows to the
    // modules the cache work touches: `cache.local`, `cache.disk` and
    // `cache_cmd`.
    //
    // `cache.resolve` is deliberately NOT in the filter: two of its
    // worktree-path tests are among the pre-existing Windows failures, and
    // they predate and are untouched by the local-slot work. Add it back
    // when those are fixed.
    // `junction` joins them for #710: the junction code is Windows-ONLY, and
    // this job is the only place CI runs on Windows — the unfiltered `test`
    // step runs on ubuntu/macos, where those tests skip. Without the filter
    // the platform-specific code would have no automated execution anywhere.
    const cache_filters = [_][]const u8{ "cache.local", "cache.disk", "cache_cmd", "junction" };
    const test_cache_step = b.step("test-cache", "Run only the cache/local-slot tests");

    const cache_src_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &cache_filters,
    });
    cache_src_tests.root_module.addOptions("build_options", options);
    cache_src_tests.root_module.addImport("flow_codegen", flow_codegen_module);
    cache_src_tests.root_module.link_libc = true;
    test_cache_step.dependOn(&b.addRunArtifact(cache_src_tests).step);

    // `cache_cmd` is reachable only from the binary root.
    const cache_bin_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = &cache_filters,
    });
    cache_bin_tests.root_module.addOptions("build_options", options);
    cache_bin_tests.root_module.addImport("flow_codegen", flow_codegen_module);
    cache_bin_tests.root_module.link_libc = true;
    test_cache_step.dependOn(&b.addRunArtifact(cache_bin_tests).step);

    // The link-placement suite joins the Windows job too (#699 review). It
    // lives in `test/`, so it rides `zig build test` — which runs on
    // ubuntu/macos only. Yet it is precisely where the platform differs:
    // Windows takes the junction fallback that POSIX never reaches, and the
    // idempotence pin there is the one that catches a junction being rebuilt
    // on every generate. Left out, the Windows-only path would again have
    // Windows-only tests that no Windows job runs.
    const scanner_link_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/scanner_symlink_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "generator", .module = generator_module },
                .{ .name = "zspec", .module = zspec_dep.module("zspec") },
                .{ .name = "flow_codegen", .module = flow_codegen_module },
                .{ .name = "test_options", .module = test_options_module },
            },
        }),
    });
    scanner_link_tests.root_module.link_libc = true;
    test_cache_step.dependOn(&b.addRunArtifact(scanner_link_tests).step);

    // BDD-style tests from test/. Each test target gets `generator`,
    // `zspec`, and `flow_codegen` so any future test file can reach
    // them without further build.zig churn. flow_codegen is cheap to
    // attach (pure-Zig sub-package, no native deps) so the blanket
    // import isn't an unwanted runtime cost.
    const test_files = [_][]const u8{
        // BDD test suites previously concentrated in test/tests.zig
        // (3768 lines). Split by domain via #184. Shared fixtures live
        // in test/helpers.zig.
        "test/build_zig_zon_tests.zig",
        "test/build_zig_tests.zig",
        "test/main_zig_tests.zig",
        "test/scene_asset_manifests_tests.zig",
        // project.labelle `.post_fx` → gated setPostFx codegen (labelle-gfx#305
        // P2 Slice C): loop + callback emit the same `@hasDecl`-gated statement,
        // RFC §2.2 friendly-param → PostPassUniforms slot mapping.
        "test/post_fx_setup_tests.zig",
        "test/backend_wiring_tests.zig",
        // `FontBackendAdapter` vtable conformance (#700): the EXECUTION
        // acceptance for the font block. The emitted adapter is compiled
        // and RUN against a stub `engine.FontBackend` + both backend
        // shapes (font-capable and font-less), because the string pins in
        // `backend_wiring_tests.zig` passed for the entire time declaring
        // a `.font` resource failed to compile.
        "test/font_backend_signature_tests.zig",
        "test/scripts_prefabs_views_layers_tests.zig",
        "test/resources_tests.zig",
        "test/window_subfolders_imgui_tests.zig",
        "test/preview_mode_tests.zig",
        "test/script_scanner_tests.zig",
        "test/deps_linker_tests.zig",
        "test/template_dynamic_test.zig",
        "test/scanner_symlink_tests.zig",
        "test/scanner_orphan_tests.zig",
        // Nested-repository pruning (#692): a `git worktree` / submodule /
        // nested clone under ANY name is not this project's source, so no
        // scanner walk descends into it.
        "test/nested_checkout_scan_tests.zig",
        // In-project `@libs/` test fan-out (#691): the EXECUTION acceptance
        // — the emitted block is spliced into a runnable build.zig and
        // driven with no `zig` on PATH, so a lib whose test fails fails the
        // build and a lib whose test passes reports its counts.
        "test/lib_test_fanout_tests.zig",
        // Packs dir-scan (RFC §4, labelle-assembler#439): scanPack copy/scan
        // + emission assertions that pack components/events/prefabs reach the
        // generated registries.
        "test/pack_scan_tests.zig",
        // flow_scanner test shim — re-exports per-domain test sections
        // from `test/flow_scanner/*.zig` so a single zspec dispatcher
        // walks them all. The split was issue #185 (was 2445 lines).
        "test/flow_scanner_tests.zig",
        // labelle-engine#578 — engine-side extension to
        // `discoverPluginEvents` (engine pass walks
        // `labelle-engine/src/root.zig` for `pub const Events`).
        "test/engine_events_discovery_test.zig",
        // One-language-per-project policy (#584): e2e through the real
        // `generate` — the gate fires before any target write, and a clean
        // project generates byte-identical output.
        "test/language_policy_tests.zig",
        // Schema-declared plugin params (#591): e2e through the real
        // `generate` — schema + `.params` → staged params module + build.zig
        // injection; violations fail before any target write; params-less
        // and legacy-language projects stay byte-identical.
        "test/plugin_params_tests.zig",
        // Scripting codegen splice (#593): registerScript embedding +
        // scripting_enabled flag + drainEvents tap in the generated main,
        // and the -Dlanguage dep option in the generated build.zig.
        "test/scripting_splice_tests.zig",
        // Script-declared components (#585): registry emission with
        // declared_components threaded, plus the declare phase e2e through
        // the real `generate` (override runner seam).
        "test/scripting_declare_tests.zig",
        // TypeScript check+emit at generate (labelle-engine#745): the
        // transpile phase e2e through the real `generate` (fake-tsc
        // override seam) — materialized script dir, emitted embeds,
        // generated labelle-components.d.ts + tsconfig, the type-error
        // failure, and the js-only no-fetch skip.
        "test/scripting_transpile_tests.zig",
        // Plugin build-integration hooks (#586): plugin.labelle `.build`
        // steps through the real `generate` — wiring pins, the additive
        // no-op invariant, the platform gate, and a REAL command+link e2e
        // (`zig build-lib` → staticlib → extern symbol) via the spliced
        // emitted block.
        "test/plugin_build_steps_tests.zig",
        // Native-language scripting splice (labelle-engine#741, rust):
        // family-shared touchpoints without the embed ones, game rust/
        // staged over the plugin crate's placeholder, `.language_builds`
        // consumption ({staticlib:NAME} + per-OS system_libs) through the
        // real `generate`, plus the #586-style splice-run acceptance.
        "test/native_splice_tests.zig",
        // Crystal splice (labelle-engine#741 slice 2, scripting PR #19):
        // per-OS step selection + the windows pointed failures,
        // artifact-less chaining, {crystal_target}, resolved
        // .library_paths, and the forward-compat pin (non-selected
        // entries with unknown keys never re-break released assemblers).
        "test/crystal_splice_tests.zig",
        // C# EMBED path (labelle-assembler#617): the csharp native-family
        // splice through the real `generate` — link-less dotnet-publish
        // step, the runtime-output InstallDir staging beside the exe + the
        // run-step LABELLE_CS_ASSEMBLY_DIR env, a runnable publish-stand-in
        // splice, and the .NET-SDK-missing toolchain probe failure.
        "test/csharp_splice_tests.zig",
        // The PYTHON LITMUS (labelle-assembler#619, RFC-LANGUAGE-PLUGINS
        // §7): a fake "quokka" embedded language the assembler learns
        // ENTIRELY from a manifest `.languages` row generates end-to-end,
        // plus the META agnosticism proof that "quokka"/".qk" appear in no
        // src/**/*.zig — the acceptance that a language plugin is addable
        // with zero assembler changes.
        "test/quokka_litmus_tests.zig",
        // The HOOK ORDERING CONTRACT (labelle-assembler#723,
        // docs/design/hook-handler-ordering.md): the default sequence is
        // preserved (including a byte-identical proof that a rank-0
        // declaration is a no-op), `.hooks.order` ranks cross the
        // root/pack/flow group boundary, undeclared receivers keep their
        // relative order, the type tuple and the instance tuple stay
        // index-aligned, and a bad declaration is a hard error.
        "test/hook_ordering_tests.zig",
        "test/animation_assets_tests.zig",
        // The HOOK ROUTE INSPECTOR (labelle-assembler#724,
        // docs/design/hook-route-inspection.md). The load-bearing test
        // generates a `main.zig` through the real emitter and compares the
        // report's receiver sequence against the emitted `MergeHooks`
        // tuple entry-by-entry, so the inspector cannot silently drift
        // from dispatch. Also: qualified root/pack/plugin listener
        // mappings, elided-vs-unlistened, consumable semantics, per-call-
        // site delivery, and the JSON contract (round-trip + determinism).
        "test/hook_routes_tests.zig",
        // i18n sentinel contract (flying-platform#786 friction #3): the
        // generated module is COMPILED AND RUN (`zig test` via the #586
        // zig_exe seam) against comptime @TypeOf asserts + runtime
        // .ptr[len]==0 probes, so a `[:0]` regression in t/tf cannot land.
        "test/i18n_sentinel_tests.zig",
        // i18n device-language boot (flying-platform#917): the generated
        // module is compiled and run against `applySystemLocale` resolution
        // (region -> language fallback, POSIX spellings, setLocale wins).
        "test/i18n_system_locale_tests.zig",
    };

    for (test_files) |test_file| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "generator", .module = generator_module },
                    .{ .name = "zspec", .module = zspec_dep.module("zspec") },
                    .{ .name = "flow_codegen", .module = flow_codegen_module },
                    .{ .name = "test_options", .module = test_options_module },
                },
            }),
        });
        const run_test = b.addRunArtifact(t);
        test_step.dependOn(&run_test.step);
        if (std.mem.eql(u8, test_file, "test/build_zig_tests.zig") or std.mem.eql(u8, test_file, "test/build_zig_zon_tests.zig")) material_test_step.dependOn(&run_test.step);
        if (std.mem.eql(u8, test_file, "test/animation_assets_tests.zig")) {
            b.step("test-animation", "Test JSONC animation asset wiring").dependOn(&run_test.step);
        }
    }

    // manifest-v2 sokol backend HOOK (epic #453 item 3, PR 5 android + PR 6 ios).
    // The dedicated hook (`backends/sokol/backend.hook.zig`) is a std-only file the
    // generated v2 android/ios build.zig `@import`s and calls
    // (`resolve_target`/`post_wire`, design §4). Compiling it as its own test target
    // is the design §7 "run the hook in the gate" gate: it typechecks the residual
    // against the real `std.Build` API (addLibraryPath/setLibCFile/linkSystemLibrary/
    // addSystemFrameworkPath/resolveTargetQuery must stay valid) AND runs the hook's
    // pure-helper unit tests (android arch selection, NDK triple, required-SDK
    // enforcement, libc.txt body; ios SDK-name/target selection, required SDK-path
    // enforcement). It takes NO generator/zspec imports — a hook must make no
    // package-local import assumptions (§3).
    const hook_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("backends/sokol/backend.hook.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(hook_tests).step);

    // manifest-v2 raylib backend HOOK (epic #453 item 3, PR 9). raylib's dedicated
    // hook (`backends/raylib_v2/backend.hook.zig`) is a std-only file the generated
    // v2 WASM build.zig `@import`s and calls (`post_wire`, design §4 residual (c)).
    // Compiling it as its own test target is the design §7 "run the hook in the
    // gate": it typechecks the emcc `emLinkStep` reconstruction against the real
    // `std.Build` API (addSystemCommand/addArtifactArg/addInstallDirectory must
    // stay valid) AND runs the hook's pure decision tests (the raylib web emcc
    // args). Like sokol's hook it takes NO generator/zspec imports (§3).
    const raylib_hook_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("backends/raylib_v2/backend.hook.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(raylib_hook_tests).step);

    // manifest-v2 bgfx backend HOOK (epic #453 item 3, PR 10). bgfx's dedicated
    // hook (`backends/bgfx_v2/backend.hook.zig`) is a std-only file the generated v2
    // ANDROID build.zig `@import`s and calls (`resolve_target`/`post_wire`, design
    // §4). Compiling it as its own test target is the design §7 "run the hook in the
    // gate": it typechecks the android residual (addLibraryPath/setLibCFile/
    // resolveTargetQuery) against the real `std.Build` API AND runs the hook's pure
    // decision tests (arch selection, NDK triple, required-SDK enforcement, libc.txt
    // body). Like sokol/raylib's hooks it takes NO generator/zspec imports (§3).
    const bgfx_hook_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("backends/bgfx_v2/backend.hook.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(bgfx_hook_tests).step);
}

/// Configure-time guard for `zig build test-materials` (#741).
///
/// The step is only as good as `src/material_test_root.zig`'s import list, so
/// this fails the BUILD (not just the step) when that list drifts:
///
///   * a `src/material_*.zig` exists that the root does not `@import`, or
///   * the root's `covered_material_modules` list disagrees with either the
///     imports or the filesystem, in EITHER direction.
///
/// It reads the root's SOURCE rather than importing it, so it runs at
/// configure time on every `zig build`, before any test compiles — the one
/// place where a silently-excluded module is cheap to catch.
///
/// The scan itself lives in `src/material_root_scan.zig` (so it has unit
/// tests of its own, run by this very step) and is TOKENIZED rather than a
/// `std.mem.indexOf` substring search: a substring search matches inside
/// comments, so commenting out an import while leaving its coverage entry in
/// place kept the guard green while the module dropped out of the step — the
/// exact drift the guard exists to stop.
fn assertMaterialTestRootCoverage(b: *std.Build) void {
    const root_scan = @import("src/material_root_scan.zig");
    const root_rel = "src/material_test_root.zig";
    const io = b.graph.io;
    const source = b.build_root.handle.readFileAlloc(
        io,
        root_rel,
        b.allocator,
        .limited(1 << 20),
    ) catch |err| std.debug.panic("test-materials guard: cannot read {s}: {s}", .{ root_rel, @errorName(err) });

    const scan = root_scan.scan(b.allocator, source) catch @panic("OOM");

    var src_dir = b.build_root.handle.openDir(io, "src", .{ .iterate = true }) catch |err|
        std.debug.panic("test-materials guard: cannot open src/: {s}", .{@errorName(err)});
    defer src_dir.close(io);

    var on_disk: std.ArrayList([]const u8) = .empty;
    var it = src_dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("test-materials guard: cannot walk src/: {s}", .{@errorName(err)})) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "material_")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "material_test_root.zig")) continue;
        on_disk.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }

    for (on_disk.items) |name| {
        if (!root_scan.contains(scan.imports, name)) std.debug.panic(
            "test-materials guard: src/{s} is not imported by {s}, so `zig build test-materials` would not run its tests. Add `_ = @import(\"{s}\");` to the `test` block there (and to `covered_material_modules`). A COMMENTED-OUT import does not count — the guard tokenizes.",
            .{ name, root_rel, name },
        );
        if (!root_scan.contains(scan.listed, name)) std.debug.panic(
            "test-materials guard: src/{s} is imported by {s} but missing from its `covered_material_modules` list.",
            .{ name, root_rel },
        );
    }

    // The other direction: an entry naming a module that is gone, or one that
    // is listed but not actually imported, claims coverage the step does not
    // have — just as much a lie as a missing entry.
    for (scan.listed) |name| {
        if (!root_scan.contains(on_disk.items, name)) std.debug.panic(
            "test-materials guard: {s} lists `{s}` in `covered_material_modules`, but src/{s} does not exist (renamed or deleted?).",
            .{ root_rel, name, name },
        );
        if (!root_scan.contains(scan.imports, name)) std.debug.panic(
            "test-materials guard: {s} lists `{s}` in `covered_material_modules` but does not `@import` it from a `test` block — the entry claims coverage the step does not have.",
            .{ root_rel, name },
        );
    }

    if (on_disk.items.len == 0) std.debug.panic(
        "test-materials guard: no src/material_*.zig found — the guard has gone blind (was the materials pipeline renamed?).",
        .{},
    );
}
