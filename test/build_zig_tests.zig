const std = @import("std");
const zspec = @import("zspec");
const generate = @import("generator");
const h = @import("helpers.zig");

const engine_template = h.engine_template;
const raylib_lifecycle = h.raylib_lifecycle;
const sokol_lifecycle = h.sokol_lifecycle;
const null_lifecycle = h.null_lifecycle;
const sokol_alloc_lifecycle = h.sokol_alloc_lifecycle;
const empty_names = h.empty_names;
const ScriptEntry = h.ScriptEntry;
const empty_entries = h.empty_entries;
const SceneManifest = h.SceneManifest;
const empty_scene_manifests = h.empty_scene_manifests;
const PluginEvent = h.PluginEvent;
const empty_plugin_events = h.empty_plugin_events;
const PluginFlowNode = h.PluginFlowNode;
const empty_plugin_flow_nodes = h.empty_plugin_flow_nodes;
const PluginPinStyle = h.PluginPinStyle;
const empty_plugin_pin_styles = h.empty_plugin_pin_styles;
const PluginCoercion = h.PluginCoercion;
const empty_plugin_coercions = h.empty_plugin_coercions;
const GlobalEntries = h.GlobalEntries;
const globalEntries = h.globalEntries;
const testGuiRenderInterface = h.testGuiRenderInterface;
const testGuiRawBackend = h.testGuiRawBackend;
const testGuiRawBackendNoBridge = h.testGuiRawBackendNoBridge;

test {
    zspec.runAll(@This());
}

// ── manifest-v2 desktop byte anchor (epic #453 item 3, PR 3, design §7) ──
// The critical proof-of-concept: the v2 desktop codegen path
// (`backend.manifest.v2.zon` → `manifest_v2_splice`) must generate a build.zig
// BYTE-IDENTICAL to the enum/v1-splice path for sokol-desktop. sokol-desktop is
// the one cell where the v1 splice already ships byte-identical to the enum path,
// so a 0-diff here proves the v2 machinery reproduces the established baseline.
// Varies the exact cfg inputs the declarative `dep_options` ValueSource predicates
// branch on (gamepad auto/off, hidapi on/off), each of which must stay 0-diff.
pub const MANIFEST_V2_DESKTOP_ANCHOR = struct {
    // #461: the enum/v1 codegen path is DELETED, so there is no live enum
    // baseline left to diff against. The desktop anchor therefore becomes a
    // committed golden snapshot (design §7): the golden was captured ONCE from
    // the v2 output while it was still proven byte-identical to the enum/v1
    // baseline, so it locks the exact bytes the anchor used to prove. Drift now
    // fails as a readable line delta.
    const golden_default = @embedFile("goldens/sokol_desktop_v2.build.zig");
    const golden_gamepad_off = @embedFile("goldens/sokol_desktop_v2_gamepad_off.build.zig");
    const golden_hidapi = @embedFile("goldens/sokol_desktop_v2_hidapi.build.zig");
    const golden_plugins = @embedFile("goldens/sokol_desktop_v2_plugins.build.zig");

    fn expectV2MatchesGolden(cfg: generate.ProjectConfig, golden: []const u8) !void {
        const v2_out = try h.genSokolBuildZigV2(std.testing.allocator, cfg, .{});
        defer std.testing.allocator.free(v2_out);
        try std.testing.expectEqualStrings(golden, v2_out);
    }

    test "golden: v2 desktop matches committed golden, default cfg (gamepad auto, no gui)" {
        try expectV2MatchesGolden(.{ .name = "anchor-game", .backend = .sokol, .ecs = .mock }, golden_default);
    }

    test "golden: v2 desktop matches committed golden, gamepad off" {
        try expectV2MatchesGolden(.{ .name = "anchor-game", .backend = .sokol, .ecs = .mock, .gamepad = .none }, golden_gamepad_off);
    }

    test "golden: v2 desktop matches committed golden, gamepad hidapi on" {
        try expectV2MatchesGolden(.{ .name = "anchor-game", .backend = .sokol, .ecs = .mock, .gamepad_hidapi = true }, golden_hidapi);
    }

    test "golden: v2 desktop matches committed golden, with plugins + zig_ecs (shared regions unaffected)" {
        // The backend-dep + link regions are the only v2-touched cells; wiring
        // plugins/ecs exercises that everything AROUND them stays identical too.
        // A REAL plugin entry is load-bearing here: plugin modules flow through
        // the core-diamond `overrideImport` region, so the anchor only exercises
        // the plugin-wiring path if a plugin is actually present. The plugin need
        // not resolve on disk — `generateBuildZig` emits the plugin dep/module
        // decls from the config alone (only build.zig.zon resolution touches
        // disk), so a plausible labelle-toolkit slug is enough.
        try expectV2MatchesGolden(.{
            .name = "anchor-game",
            .backend = .sokol,
            .ecs = .zig_ecs,
            .plugins = &.{
                .{ .name = "pathfinding", .repo = "github:labelle-toolkit/labelle-pathfinding", .version = "2.6.0" },
            },
        }, golden_plugins);
    }

    test "byte anchor: v2-only backend (no legacy manifest) reaches v2 == dual-manifest v2 (#453)" {
        // Regression proof for the manifest-v2 gate fix: `backends/sokol_v2only`
        // ships ONLY `backend.manifest.v2.zon` (no `backend.manifest.zon`). Before
        // the fix, the external-manifest requirement + desktop gate keyed off the
        // hardcoded legacy name, so this package hard-errored ExternalBackendNeeds-
        // Manifest and never reached `loadNamedManifest`. Keying off the requested
        // name lets it through the v2 path — and because the v2 manifest is a byte
        // copy of sokol's, the generated build.zig is IDENTICAL to the dual-manifest
        // sokol fixture's v2 output. (Also implicitly a 0-diff vs the enum baseline.)
        const cfg: generate.ProjectConfig = .{ .name = "anchor-game", .backend = .sokol, .ecs = .mock };
        const v2_dual = try h.genSokolBuildZigV2(std.testing.allocator, cfg, .{});
        defer std.testing.allocator.free(v2_dual);
        const v2_only = try h.genSokolV2OnlyBuildZig(std.testing.allocator, cfg, .{});
        defer std.testing.allocator.free(v2_only);
        try std.testing.expectEqualStrings(v2_dual, v2_only);
    }
};

// ── manifest-v2 sokol-android GOLDEN cell (epic #453 item 3, PR 5, design §7) ──
// Android is the first HOOK-BEARING conversion. Unlike the desktop byte anchor,
// this cannot be a 0-diff-vs-enum comparison: the residual (NDK sysroot detection,
// libc.txt, target resolution) moved into the imported `backend.hook.zig` and the
// unrolled core-diamond overrides became the generic `unifyCoreDiamond` loop, so
// the generated text legitimately DIFFERS from the enum `header_android`/
// `android_deps`/`backend_sokol_android`/`android_link` path. The gate is
// therefore a committed golden (reviewed by hand against the enum output for
// graph equivalence) PLUS the hook's own gates: `backend.hook.zig` is compiled as
// a test target in build.zig (typechecking `resolve_target`/`post_wire` against
// the real std.Build API) and unit-tests its pure decision helpers (arch select,
// NDK triple, required-SDK enforcement, libc.txt body). See design §7 for why the
// text golden alone is blind to the hook body.
pub const MANIFEST_V2_ANDROID_GOLDEN = struct {
    const golden = @embedFile("goldens/sokol_android_v2.build.zig");

    fn genAndroidV2() ![]const u8 {
        return h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "anchor-game",
            .backend = .sokol,
            .platform = .android,
            .ecs = .mock,
        }, .{});
    }

    test "golden: v2 sokol-android build.zig matches the committed golden" {
        const out = try genAndroidV2();
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(golden, out);
    }

    test "golden: v2 sokol-android build.zig is syntactically valid Zig" {
        const out = try genAndroidV2();
        defer std.testing.allocator.free(out);
        const dup = try std.testing.allocator.dupeZ(u8, out);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "v2 sokol-android imports the backend hook and calls BOTH phases (§4)" {
        const out = try genAndroidV2();
        defer std.testing.allocator.free(out);
        // resolve_target BEFORE any b.dependency (produces android_target).
        try std.testing.expect(std.mem.indexOf(u8, out, "@import(\"backend_build_hook.zig\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook.resolve_target(b, .{ .platform = .android }).target") != null);
        // post_wire AFTER wiring, carrying the REQUIRED android_target_sdk (34).
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook.post_wire(b, .{") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".android_target_sdk = 34,") != null);
        // The generic core-diamond walk (loop form) replaced the unrolled overrides.
        try std.testing.expect(std.mem.indexOf(u8, out, "fn unifyCoreDiamond(") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "unifyCoreDiamond(b.allocator, gfx_mod, core_mod, gfx_mod,") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "unifyGfxSubpackageCore(gfx_mod, core_mod)") == null);
        // Declarative graph: artifact link + NDK system libs + pic + link_libc.
        try std.testing.expect(std.mem.indexOf(u8, out, "lib.root_module.linkLibrary(sokol_clib)") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "sokol_clib.root_module.pic = true;") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "lib.root_module.linkSystemLibrary(\"GLESv3\", .{})") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "lib.root_module.link_libc = true;") != null);
        // APK packaging delegated to the shared packager (byte-identical section).
        try std.testing.expect(std.mem.indexOf(u8, out, "Package and sign Android APK") != null);
        // The enum-path inline NDK detection is GONE from the generated build.zig —
        // it lives in the hook now (the documented enum-vs-v2 boundary).
        try std.testing.expect(std.mem.indexOf(u8, out, "fn getAndroidNdkSysroot(") == null);
    }
};

// ── PR #466 Finding 1: promoted scripts must not leave `target` undefined ──
// The `android_target_alias`/`ios_target_alias` section (`const target =
// <platform>_target;`) was emitted only under `plugins|ecs|gui`, but
// `emitPromotedScriptModules` unconditionally emits `.target = target,`. A game
// with promoted (FlowNodes-bearing) scripts and NO plugins/ECS/GUI therefore
// referenced an UNDEFINED `target`. The guard now also fires on promoted scripts.
// This shared guard covers BOTH the v2 and enum android routes.
pub const PR466_FINDING1_TARGET_ALIAS = struct {
    const promoted = [_]generate.PromotedScript{
        .{ .module_name = "script__demo", .rel_path = "demo.zig" },
    };

    fn expectDefinesTarget(out: []const u8) !void {
        // The promoted-script module decl references `target`…
        try std.testing.expect(std.mem.indexOf(u8, out, ".target = target,") != null);
        // …and the alias that DEFINES it must now be present.
        try std.testing.expect(std.mem.indexOf(u8, out, "const target = android_target;") != null);
        // Sanity: the generated build.zig still parses.
        const dup = try std.testing.allocator.dupeZ(u8, out);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "v2 android: promoted scripts + no plugins/ecs/gui still defines `target`" {
        const out = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "anchor-game",
            .backend = .sokol,
            .platform = .android,
            .ecs = .mock,
        }, .{ .promoted_scripts = &promoted });
        defer std.testing.allocator.free(out);
        try expectDefinesTarget(out);
    }
};

// ── PR #466 Finding 3: the v2 backend build hook is staged as a sibling ──
// The generated v2 android build.zig `@import`s `backend_build_hook.zig`; the
// generator must copy the manifest's `build_hook` file to that sibling name or a
// real build fails at import resolution.
pub const PR466_FINDING3_STAGE_HOOK = struct {
    test "stages manifest build_hook next to build.zig as backend_build_hook.zig" {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target_dir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
        defer std.testing.allocator.free(target_dir);

        var cfg: generate.ProjectConfig = .{
            .name = "anchor-game",
            .backend = .sokol,
            .platform = .android,
            .ecs = .mock,
        };
        cfg.backend_package = h.sokol_fixture_package;

        const staged = try generate.stageBackendBuildHook(
            std.testing.allocator,
            cfg,
            ".",
            "backend.manifest.v2.zon",
            target_dir,
        );
        try std.testing.expect(staged);

        // The sibling exists under the exact name the generated build.zig imports,
        // with the fixture hook's byte content.
        const got = try tmp.dir.readFileAlloc(io, generate.backend_build_hook_name, std.testing.allocator, .limited(256 * 1024));
        defer std.testing.allocator.free(got);
        const want = try std.Io.Dir.cwd().readFileAlloc(io, "backends/sokol/backend.hook.zig", std.testing.allocator, .limited(256 * 1024));
        defer std.testing.allocator.free(want);
        try std.testing.expectEqualStrings(want, got);
    }
};

// ── manifest-v2 sokol-ios GOLDEN cell (epic #453 item 3, PR 6, design §7) ──
// iOS is the second HOOK-BEARING conversion. Like android (and unlike the desktop
// byte anchor) this cannot be a 0-diff-vs-enum comparison: the residual (xcrun SDK
// discovery, device/simulator target resolution, `configureSdkPaths`/
// `addExeSdkPaths`) moved into the imported `backend.hook.zig` and the unrolled
// core-diamond overrides became the generic `unifyCoreDiamond` loop, so the
// generated text legitimately DIFFERS from the enum `header_ios`/`ios_deps`/
// `backend_sokol_ios`/`ios_link` path. The gate is a committed golden (reviewed by
// hand against the enum output for graph equivalence) PLUS the hook's own gates:
// `backend.hook.zig` is compiled as a test target in build.zig (typechecking
// `resolve_target`/`post_wire` against the real std.Build API) and unit-tests its
// pure decision helpers (SDK-name select, device/simulator target select, required
// SDK-path enforcement). The iOS `resolve_target` is DISTINCT from android's — it
// also returns the SDK path plugin b.dependency calls consume (design §4).
pub const MANIFEST_V2_IOS_GOLDEN = struct {
    const golden = @embedFile("goldens/sokol_ios_v2.build.zig");

    fn genIosV2() ![]const u8 {
        return h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "anchor-game",
            .backend = .sokol,
            .platform = .ios,
            .ecs = .mock,
        }, .{});
    }

    test "golden: v2 sokol-ios build.zig matches the committed golden" {
        const out = try genIosV2();
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(golden, out);
    }

    test "golden: v2 sokol-ios build.zig is syntactically valid Zig" {
        const out = try genIosV2();
        defer std.testing.allocator.free(out);
        const dup = try std.testing.allocator.dupeZ(u8, out);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "v2 sokol-ios imports the backend hook and calls BOTH phases (§4)" {
        const out = try genIosV2();
        defer std.testing.allocator.free(out);
        // resolve_target BEFORE any b.dependency — and it returns BOTH the ios
        // target AND the SDK path (plugin b.dependency calls consume it, §4).
        try std.testing.expect(std.mem.indexOf(u8, out, "@import(\"backend_build_hook.zig\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook.resolve_target(b, .{ .platform = .ios })") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "const sdk_path = ios_resolved.ios_sdk_path.?;") != null);
        // post_wire AFTER wiring, carrying the REQUIRED SDK path (android null).
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook.post_wire(b, .{") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".ios_sdk_path = sdk_path,") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".android_target_sdk = null,") != null);
        // The generic core-diamond walk (loop form) replaced the unrolled overrides.
        try std.testing.expect(std.mem.indexOf(u8, out, "fn unifyCoreDiamond(") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "unifyCoreDiamond(b.allocator, gfx_mod, core_mod, gfx_mod,") != null);
        // Declarative graph: artifact link + link_libc + the iOS frameworks
        // (`.frameworks.ios`) — replaces the enum `linkIosFrameworks` helper call.
        try std.testing.expect(std.mem.indexOf(u8, out, "exe.root_module.linkLibrary(sokol_clib)") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "exe.root_module.link_libc = true;") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "exe.root_module.linkFramework(\"Metal\", .{})") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "exe.root_module.linkFramework(\"GameController\", .{})") != null);
        // The enum-path inline xcrun SDK discovery + framework helper are GONE from
        // the generated build.zig — they live in the hook now (the enum-vs-v2 boundary).
        try std.testing.expect(std.mem.indexOf(u8, out, "fn getIosSdkPath(") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "fn linkIosFrameworks(") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "configureSdkPaths(") == null);
    }
};

// ── manifest-v2 sokol-wasm GOLDEN cell (epic #453 item 3, PR 7, design §7) ──
// wasm is the emcc residual (design §2 (c)) and the LAST sokol platform. Like
// android/ios (and unlike the desktop byte anchor) this cannot be a 0-diff-vs-enum
// comparison: the emcc `emLinkStep` (enum `.link_sokol_wasm`, which reaches emcc
// via `@import("labelle_sokol").emLinkStep`) moved into the imported std-only
// `backend.hook.zig` — reconstructed there from only `std.Build` + the emsdk
// dependency — and the unrolled core-diamond overrides became the generic
// `unifyCoreDiamond` loop. wasm has NO `resolve_target` (its target is the STATIC
// `.triple` "wasm32-emscripten", resolved inline). Because `post_wire` returns
// void it also owns the install/run wiring the enum `.wasm_footer` did (the enum
// `emcc_step` local cannot escape a void hook), so the wasm v2 path does NOT emit
// the `.wasm_footer`/packager `.web` block — the documented enum-vs-v2 boundary.
// The gate is a committed golden (reviewed by hand against the enum output for
// graph equivalence) PLUS the hook's own gates: `backend.hook.zig` is compiled as
// a test target in build.zig (typechecking `emLinkStep`/`post_wire` against the
// real std.Build API) and unit-tests its pure decision (the 512 KB stack arg). It
// ALSO asserts the generated build.zig.zon carries the emsdk root build dep
// (design §3 `RootBuildDep`, review #459 finding 2) — the hook's
// `b.dependency("emsdk", .{})` only resolves if the root zon declares it.
pub const MANIFEST_V2_WASM_GOLDEN = struct {
    const golden = @embedFile("goldens/sokol_wasm_v2.build.zig");

    const wasm_cfg: generate.ProjectConfig = .{
        .name = "anchor-game",
        .backend = .sokol,
        .platform = .wasm,
        .ecs = .mock,
    };

    fn genWasmV2() ![]const u8 {
        return h.genSokolBuildZigV2(std.testing.allocator, wasm_cfg, .{});
    }

    test "golden: v2 sokol-wasm build.zig matches the committed golden" {
        const out = try genWasmV2();
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(golden, out);
    }

    test "golden: v2 sokol-wasm build.zig is syntactically valid Zig" {
        const out = try genWasmV2();
        defer std.testing.allocator.free(out);
        const dup = try std.testing.allocator.dupeZ(u8, out);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "v2 sokol-wasm imports the hook; post_wire does the emcc step (§2 (c))" {
        const out = try genWasmV2();
        defer std.testing.allocator.free(out);
        // The hook is imported and post_wire is called for wasm — the emcc
        // link residual lives IN the hook, not inline in build.zig.
        try std.testing.expect(std.mem.indexOf(u8, out, "@import(\"backend_build_hook.zig\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook.post_wire(b, .{") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".platform = .wasm,") != null);
        // NO inline emLinkStep / provider import in the generated build.zig — the
        // std-only hook reconstructs emcc; the enum `@import("labelle_sokol")` +
        // `sokol_em.emLinkStep(...)` are GONE (the enum-vs-v2 boundary).
        try std.testing.expect(std.mem.indexOf(u8, out, "emLinkStep") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "@import(\"labelle_sokol\")") == null);
        // wasm has NO resolve_target CALL (static triple) — the target resolves
        // inline via resolveTargetQuery (the header comment mentions the phase name).
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook.resolve_target(") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".cpu_arch = .wasm32,") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "b.resolveTargetQuery(.{") != null);
        // The generic core-diamond walk (loop form) replaced the unrolled overrides.
        try std.testing.expect(std.mem.indexOf(u8, out, "fn unifyCoreDiamond(") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "unifyCoreDiamond(b.allocator, gfx_mod, core_mod, gfx_mod,") != null);
        // Declarative graph: the sokol_clib artifact is linked into the wasm lib
        // (emcc scans it as a transitive static dep in post_wire).
        try std.testing.expect(std.mem.indexOf(u8, out, "wasm.root_module.linkLibrary(sokol_clib)") != null);
        // post_wire owns install/run, so NO packager `.web` footer is emitted —
        // the enum `emcc_step` local is absent from the generated build.zig.
        try std.testing.expect(std.mem.indexOf(u8, out, "emcc_step") == null);
    }

    test "v2 sokol-wasm build.zig.zon carries the emsdk root build dep (§3 RootBuildDep)" {
        // The hook's `b.dependency("emsdk", .{})` only resolves if the generated
        // root zon declares emsdk. The manifest's `.platforms.wasm.root_build_deps`
        // = `.{ .name = "emsdk", .resolution = .builtin }` drives this; `.builtin`
        // reuses the pinned `dep_emsdk` section, so the emitted url is byte-identical
        // to the enum path.
        const zon = try generate.generateBuildZigZon(
            std.testing.allocator,
            wasm_cfg,
            null,
            null,
            ".",
            .{ .backend_manifest_name = "backend.manifest.v2.zon" },
        );
        defer std.testing.allocator.free(zon);
        try std.testing.expect(std.mem.indexOf(u8, zon, ".emsdk = .{") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "git+https://github.com/emscripten-core/emsdk#4.0.9") != null);
    }

    test "v2 sokol-wasm zon emsdk is byte-identical to the enum-path zon" {
        // `.builtin` reuses the enum path's pinned `dep_emsdk` section, so a v2 wasm
        // zon and the enum wasm zon agree on the emsdk entry (design §3).
        const v2_zon = try generate.generateBuildZigZon(
            std.testing.allocator,
            wasm_cfg,
            null,
            null,
            ".",
            .{ .backend_manifest_name = "backend.manifest.v2.zon" },
        );
        defer std.testing.allocator.free(v2_zon);
        const enum_zon = try generate.generateBuildZigZon(
            std.testing.allocator,
            wasm_cfg,
            null,
            null,
            ".",
            .{},
        );
        defer std.testing.allocator.free(enum_zon);
        try std.testing.expectEqualStrings(enum_zon, v2_zon);
    }

    // ── #468 finding 1: a v2 manifest that fails to load must error the ZON ──
    // generation, not silently fall back to enum output. The build.zig path
    // (`generateBuildZig`) already propagates the load error with `try`; the zon
    // path used to `catch null`, which could pair a build.zig that resolved its
    // hook deps against a v2 manifest with a build.zig.zon that fell back to enum
    // output — a divergent (broken) pair. The two generators must now AGREE:
    // both succeed, or both error, for the same manifest.
    const broken_cfg: generate.ProjectConfig = .{
        .name = "anchor-game",
        .backend = .sokol,
        .platform = .wasm,
        .ecs = .mock,
        .backend_package = h.sokol_v2broken_fixture_package,
    };

    test "v2 build.zig.zon errors when the v2 manifest fails to load (no enum fallback)" {
        try std.testing.expectError(error.BackendManifestParseError, generate.generateBuildZigZon(
            std.testing.allocator,
            broken_cfg,
            null,
            null,
            ".",
            .{ .backend_manifest_name = "backend.manifest.v2.zon" },
        ));
    }

    test "v2 build.zig ALSO errors on the same broken manifest (both paths agree)" {
        try std.testing.expectError(error.BackendManifestParseError, generate.generateBuildZig(
            std.testing.allocator,
            broken_cfg,
            .{ .project_dir = ".", .backend_manifest_name = "backend.manifest.v2.zon" },
        ));
    }
};

// ── manifest-v2 null GOLDEN cell (epic #453 item 3, PR 8, design §7) ──
// null is the FIRST fully-declarative, HOOKLESS backend converted to v2, and the
// simplest possible v2 cell: pure-Zig, zero native deps, headless, desktop-only.
// Unlike the sokol DESKTOP byte anchor (0-diff vs enum/v1 by unrolling the walk +
// keeping the sokol residual prose), null uses the GENERIC declarative desktop
// path — the loop-form `unifyCoreDiamond` walk replaces the enum `deps` unrolled
// overrides — so the generated text legitimately DIFFERS from the enum
// `deps`/`backend_null` path. The gate is a committed golden reviewed by hand
// against the enum output for graph equivalence (§7 tier-1: a loop emits different
// source than the unrolled form). NOTE: null's `.backend_null` enum section still
// exists in build_zig.txt, but a byte-anchor is NOT the gate here — the v2 path
// deliberately uses the generic loop form (not the enum's unrolled overrides), so
// the reviewed golden is the correct gate (see design §7). null is HOOKLESS: NO
// `backend_build_hook.zig` import, NO `resolve_target`/`post_wire` call.
pub const MANIFEST_V2_NULL_GOLDEN = struct {
    const golden = @embedFile("goldens/null_v2.build.zig");

    fn genNullV2() ![]const u8 {
        return h.genNullV2BuildZig(std.testing.allocator, .{
            .name = "anchor-game",
            .backend = .null,
            .ecs = .mock,
        }, .{});
    }

    test "golden: v2 null build.zig matches the committed golden" {
        const out = try genNullV2();
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(golden, out);
    }

    test "golden: v2 null build.zig is syntactically valid Zig" {
        const out = try genNullV2();
        defer std.testing.allocator.free(out);
        const dup = try std.testing.allocator.dupeZ(u8, out);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "v2 null is HOOKLESS and fully declarative (no hook import / phases)" {
        const out = try genNullV2();
        defer std.testing.allocator.free(out);
        // Hookless: NO backend hook import, NO resolve_target / post_wire calls.
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "resolve_target") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "post_wire") == null);
        // Declarative backend dep + the four provider modules under their aliases.
        try std.testing.expect(std.mem.indexOf(u8, out, "b.dependency(\"labelle_null\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "const backend_gfx = backend_dep.module(\"gfx\");") != null);
        // The generic core-diamond walk (loop form) replaced the unrolled overrides.
        try std.testing.expect(std.mem.indexOf(u8, out, "fn unifyCoreDiamond(") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "unifyCoreDiamond(b.allocator, gfx_mod, core_mod, gfx_mod,") != null);
        // No native artifact + no framework links (headless, pure Zig).
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_dep.artifact(") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "linkLibrary") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "linkFramework") == null);
    }
};

// ── manifest-v2 wgpu GOLDEN cell (epic #453 item 3, PR 8, design §7) ──
// wgpu is the second HOOKLESS desktop backend, exercising the GENERIC declarative
// desktop path PLUS per-OS framework emission: it links the `glfw` artifact and
// the macOS Metal/Foundation/QuartzCore frameworks (`.frameworks.desktop.macos`),
// the data form of the enum `link_wgpu`'s `switch (target.result.os.tag)` block.
// Like null (and unlike the sokol byte anchor) this uses the loop-form
// `unifyCoreDiamond` walk, so the text DIFFERS from the enum `deps`/`backend_wgpu`/
// `link_wgpu` path — the gate is a committed golden reviewed for graph equivalence
// (§7). wgpu's `.backend_wgpu`/`.link_wgpu` enum sections still exist in
// build_zig.txt, but a byte-anchor is NOT the gate (the v2 path uses the generic
// loop, not the enum unroll). wgpu is HOOKLESS: NO hook import / phases.
pub const MANIFEST_V2_WGPU_GOLDEN = struct {
    const golden = @embedFile("goldens/wgpu_v2.build.zig");

    fn genWgpuV2() ![]const u8 {
        return h.genWgpuV2BuildZig(std.testing.allocator, .{
            .name = "anchor-game",
            .backend = .wgpu,
            .ecs = .mock,
        }, .{});
    }

    test "golden: v2 wgpu build.zig matches the committed golden" {
        const out = try genWgpuV2();
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(golden, out);
    }

    test "golden: v2 wgpu build.zig is syntactically valid Zig" {
        const out = try genWgpuV2();
        defer std.testing.allocator.free(out);
        const dup = try std.testing.allocator.dupeZ(u8, out);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "v2 wgpu is HOOKLESS, links glfw + the macOS frameworks (declarative)" {
        const out = try genWgpuV2();
        defer std.testing.allocator.free(out);
        // Hookless: NO backend hook import, NO resolve_target / post_wire calls.
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "resolve_target") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "post_wire") == null);
        // Declarative backend dep + the glfw artifact + its link.
        try std.testing.expect(std.mem.indexOf(u8, out, "b.dependency(\"labelle_wgpu\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "const glfw = backend_dep.artifact(\"glfw\");") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "exe.root_module.linkLibrary(glfw);") != null);
        // The generic core-diamond walk (loop form) replaced the unrolled overrides.
        try std.testing.expect(std.mem.indexOf(u8, out, "fn unifyCoreDiamond(") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "unifyCoreDiamond(b.allocator, gfx_mod, core_mod, gfx_mod,") != null);
        // Per-OS framework block: the macOS Metal/Foundation/QuartzCore links.
        try std.testing.expect(std.mem.indexOf(u8, out, "switch (target.result.os.tag) {") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".macos => {") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "exe.root_module.linkFramework(\"Metal\", .{})") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "exe.root_module.linkFramework(\"Foundation\", .{})") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "exe.root_module.linkFramework(\"QuartzCore\", .{})") != null);
        // The SAME native linkage is mirrored onto `test_root` so `zig build
        // test` for a wgpu project links glfw + the macOS frameworks too (review
        // #469). The enum path links only exe; the generic desktop path links both.
        try std.testing.expect(std.mem.indexOf(u8, out, "test_root.root_module.linkLibrary(glfw);") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "test_root.root_module.linkFramework(\"Metal\", .{})") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "test_root.root_module.linkFramework(\"Foundation\", .{})") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "test_root.root_module.linkFramework(\"QuartzCore\", .{})") != null);
    }
};

// ── open config: a THIRD-PARTY backend, name+package only (epic #453 PR 11) ──
// The capstone of the pluggable-backends epic. `backends/acme_foo` is a
// HYPOTHETICAL third-party backend selected purely by NAME + package with NO
// matching `Backend` enum tag (its `cfg.backend` sits at the `.raylib` default)
// and a NON-`labelle.` canonical id (`acme.foo`). It must resolve + generate a
// valid build.zig entirely through `backend_registry` + its v2 manifest, never
// through the enum `switch (cfg.backend)`. PLUS: capability validation runs on
// the v2 path BEFORE any build-graph is emitted, so a project requiring a
// capability the backend does not declare fails with the readable project-level
// `error.UnsupportedCapability` — not a deep codegen/compile error.
pub const MANIFEST_V2_THIRD_PARTY_OPEN_CONFIG = struct {
    fn genAcmeFoo(cfg: generate.ProjectConfig) ![]const u8 {
        return h.genAcmeFooBuildZig(std.testing.allocator, cfg, .{});
    }

    test "open config: a name-only third-party backend (no enum tag) generates a valid build.zig via its v2 manifest" {
        // `cfg.backend` is left at its `.raylib` default — the ONLY selector is
        // `backend_package`. If routing leaked to the enum path this would emit
        // raylib-shaped wiring; instead it must emit the acme_foo dep from the
        // manifest and the generic loop-form core-diamond walk.
        const cfg = generate.ProjectConfig{ .name = "acme-game", .ecs = .mock };
        const out = try genAcmeFoo(cfg);
        defer std.testing.allocator.free(out);

        // Generated from the v2 manifest data — NOT the enum's raylib default.
        try std.testing.expect(std.mem.indexOf(u8, out, "b.dependency(\"acme_foo\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "b.dependency(\"labelle_raylib\"") == null);
        // Provider modules under their default `backend_<name>` aliases.
        try std.testing.expect(std.mem.indexOf(u8, out, "const backend_gfx = backend_dep.module(\"gfx\");") != null);
        // The generic (loop-form) core-diamond walk replaced the unrolled overrides.
        try std.testing.expect(std.mem.indexOf(u8, out, "fn unifyCoreDiamond(") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "unifyCoreDiamond(b.allocator, gfx_mod, core_mod, gfx_mod,") != null);
        // Hookless + no native deps (headless, pure Zig).
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_dep.artifact(") == null);
    }

    test "open config: the name-only third-party build.zig is syntactically valid Zig" {
        const cfg = generate.ProjectConfig{ .name = "acme-game", .ecs = .mock };
        const out = try genAcmeFoo(cfg);
        defer std.testing.allocator.free(out);
        const dup = try std.testing.allocator.dupeZ(u8, out);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "capability gate: a required capability the third-party backend does not declare errors BEFORE wiring" {
        // acme_foo advertises only `.headless`. A project explicitly requiring
        // `.screenshots` must fail at generation time with the project-level
        // `error.UnsupportedCapability` (capabilities.validate on the v2 path),
        // BEFORE any build-graph text is emitted — not a deep compile error.
        const cfg = generate.ProjectConfig{
            .name = "acme-game",
            .ecs = .mock,
            .requires = &.{.screenshots},
        };
        try std.testing.expectError(error.UnsupportedCapability, genAcmeFoo(cfg));
    }

    test "capability gate: a satisfied requirement (the declared .headless) generates fine" {
        // The complement of the gate: requiring exactly what the backend declares
        // must pass and produce a valid build.zig — proving the gate fires on the
        // MISSING capability, not on capability enforcement being on at all.
        const cfg = generate.ProjectConfig{
            .name = "acme-game",
            .ecs = .mock,
            .requires = &.{.headless},
        };
        const out = try genAcmeFoo(cfg);
        defer std.testing.allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "b.dependency(\"acme_foo\"") != null);
    }

    test "open config: build.zig.zon keys the backend dep by the manifest dep_name, matching build.zig (#472 P1)" {
        // Regression proof for #472 P1: the generated build.zig calls
        // `b.dependency("acme_foo", ..)` (the v2 manifest's `dep_name`), but the
        // zon generator used to derive the backend dependency key as
        // `labelle_<name>` → `.labelle_acme_foo`. build.zig and build.zig.zon then
        // disagreed and Zig could not resolve the backend dependency. The zon MUST
        // key the backend entry by `dep_name` (`acme_foo`) so the two files agree.
        const cfg = generate.ProjectConfig{ .name = "acme-game", .ecs = .mock };
        const zon = try h.genAcmeFooBuildZigZon(std.testing.allocator, cfg);
        defer std.testing.allocator.free(zon);

        // The backend dep is keyed exactly as `b.dependency("acme_foo")` expects.
        try std.testing.expect(std.mem.indexOf(u8, zon, ".acme_foo = .{") != null);
        // The stale `labelle_`-prefixed derivation must NOT appear.
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_acme_foo") == null);
    }
};

// ── manifest-v2 PRODUCTION CUTOVER via the real `generate` (#453, closes #472 P2) ──
// The prior tests all drive the `generateBuildZig` UNIT helper, which takes
// `backend_manifest_name` EXPLICITLY — so they prove the v2 CODEGEN works when the
// caller opts in, but NOT that the production `generate` entry point auto-detects a
// v2 manifest on its own. This struct closes that gap: it drives the REAL `generate`
// (via `h.generateAndReadBuildZig`, which passes NO `backend_manifest_name` — that
// field doesn't exist on `GenerateOptions`) and asserts `generate` probed the
// resolved backend package, found `backend.manifest.v2.zon`, and drove the v2 path.
pub const MANIFEST_V2_GENERATE_CUTOVER = struct {
    test "generate AUTO-DETECTS a v2 backend and emits v2 build.zig (no caller opt-in)" {
        // acme_foo ships ONLY `backend.manifest.v2.zon` and has NO enum tag. Before
        // the cutover, `generate` passed a null manifest name → `requireManifestIf-
        // External` probed the absent legacy `backend.manifest.zon` and hard-errored
        // `ExternalBackendNeedsManifest`, never reaching v2 codegen. After the
        // cutover, `generate`'s probe finds the v2 manifest, threads its name through
        // every site, and emits the generic v2 desktop build.zig.
        const cfg = generate.ProjectConfig{ .name = "cutover-game", .ecs = .mock };
        const out = try h.generateAndReadBuildZig(std.testing.allocator, cfg, h.acme_foo_fixture_package);
        defer std.testing.allocator.free(out);

        // v2 output, generated from the manifest data — NOT the enum raylib default.
        try std.testing.expect(std.mem.indexOf(u8, out, "b.dependency(\"acme_foo\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "b.dependency(\"labelle_raylib\"") == null);
        // The v2 generic (loop-form) core-diamond walk — the unambiguous v2 marker.
        try std.testing.expect(std.mem.indexOf(u8, out, "fn unifyCoreDiamond(") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "unifyCoreDiamond(b.allocator, gfx_mod, core_mod, gfx_mod,") != null);
        // Sanity: the auto-detected v2 build.zig is syntactically valid Zig.
        const dup = try std.testing.allocator.dupeZ(u8, out);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "PRODUCTION cutover: a backend's auto-detected v2 output == the unit v2 helper" {
        // sokol ships a v2 manifest; `generate` auto-detecting v2 must match the
        // explicit-opt-in unit v2 helper for the SAME desktop build. This is the
        // production guarantee that the auto-detect path and the unit codegen path
        // agree byte-for-byte (both are v2 now that the enum/v1 path is deleted).
        const cfg = generate.ProjectConfig{ .name = "noop-game", .backend = .sokol, .ecs = .mock };
        const v2_auto = try h.generateAndReadBuildZig(std.testing.allocator, cfg, h.sokol_fixture_package);
        defer std.testing.allocator.free(v2_auto);
        // The unit v2 baseline for the SAME desktop build (tests-target shape, as
        // `generateAndReadBuildZig` emits).
        const v2_unit = try h.genSokolBuildZigV2(std.testing.allocator, cfg, .{ .is_tests_target = true });
        defer std.testing.allocator.free(v2_unit);
        try std.testing.expectEqualStrings(v2_unit, v2_auto);
    }

    test "generate CATCHES a capability mismatch on the auto-detected v2 manifest (#473 finding 2)" {
        // acme_foo advertises ONLY `.headless` in its v2 manifest and ships NO
        // legacy `backend.manifest.zon`. Before the finding-2 fix the resolve-time
        // `validateProviderContracts` read only the (absent) v1 provider manifest,
        // so the v2 `.capabilities` were ignored. A project requiring a capability
        // the v2 backend does NOT declare must now fail the REAL `generate` with the
        // readable project-level `error.UnsupportedCapability`.
        //
        // NOTE (issue #83): this drives the REAL exe target (`is_tests_target =
        // false`) — the tests target deliberately skips the capability gate (both
        // the root-level `validateProviderContracts` and `generateBuildZig`'s own
        // v2 check), so it can never surface a capability mismatch. The finding-2
        // catch is a resolve-time (`validateProviderContracts`) concern, which
        // fires BEFORE any main.zig/engine-template work, so the exe path errors
        // without needing a cached engine template.
        const cfg = generate.ProjectConfig{
            .name = "cutover-cap-game",
            .backend_package = h.acme_foo_fixture_package,
            .ecs = .mock,
            .requires = &.{.screenshots},
        };
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const out_abs = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(out_abs);
        try std.testing.expectError(
            error.UnsupportedCapability,
            generate.generate(std.testing.allocator, cfg, out_abs, ".", .{ .is_tests_target = false }),
        );
    }
};

// ── manifest-v2 cutover: `loadBackendTemplate` + `validateProviderContracts`
// honor the auto-detected `backend_manifest_name` (#473 findings 1 + 2). These
// drive the two internal seams `generate` threads the detected v2 name into
// DIRECTLY, proving each honors a v2 manifest without needing the full main.zig
// generation (which would require a cached engine template). `game_dir = "."`
// (repo root) so the `local:backends/<name>` fixtures resolve offline.
pub const MANIFEST_V2_CUTOVER_SEAMS = struct {
    // ── Finding 1: main-template loading resolves the v2 `.platforms[<p>].entry` ──

    test "loadBackendTemplate: a v2-only backend resolves its template from the v2 entry" {
        // sokol_v2only ships ONLY `backend.manifest.v2.zon` (no legacy manifest) +
        // its `templates/desktop.txt`. With the detected v2 name, loadBackendTemplate
        // must route to `.platforms.desktop.entry` and read that template — NOT fail
        // for lack of a legacy manifest / enum-path template.
        const cfg = generate.ProjectConfig{
            .name = "tmpl-game",
            .ecs = .mock,
            .backend_package = h.sokol_v2only_fixture_package,
        };
        const tmpl = try generate.loadBackendTemplate(std.testing.allocator, ".", cfg, "backend.manifest.v2.zon");
        defer std.testing.allocator.free(tmpl);
        // The desktop lifecycle template was found + read (non-empty content).
        try std.testing.expect(tmpl.len > 0);
    }

    test "loadBackendTemplate: the SAME v2-only backend errors WITHOUT the detected name (proves the v2 path is load-bearing)" {
        // The distinguishing proof for finding 1: a v2-only external backend passed a
        // null manifest name falls to the legacy requirement, which probes the absent
        // `backend.manifest.zon` and hard-errors `ExternalBackendNeedsManifest`. Only
        // threading the detected v2 name makes template loading succeed (test above).
        const cfg = generate.ProjectConfig{
            .name = "tmpl-game",
            .ecs = .mock,
            .backend_package = h.sokol_v2only_fixture_package,
        };
        try std.testing.expectError(
            error.ExternalBackendNeedsManifest,
            generate.loadBackendTemplate(std.testing.allocator, ".", cfg, null),
        );
    }

    // ── Finding 2: provider-contract validation reads the v2 `.id`/`.capabilities` ──

    test "validateProviderContracts: reads the v2 capabilities — a missing requirement errors" {
        // acme_foo's v2 manifest declares ONLY `.headless`. Requiring `.screenshots`
        // must fail via the v2 `.capabilities` (acme_foo ships no legacy manifest, so
        // the check keys off the v2 name it is passed).
        const cfg = generate.ProjectConfig{
            .name = "contract-game",
            .ecs = .mock,
            .requires = &.{.screenshots},
            .backend_package = h.acme_foo_fixture_package,
        };
        try std.testing.expectError(
            error.UnsupportedCapability,
            generate.validateProviderContracts(std.testing.allocator, cfg, ".", "backend.manifest.v2.zon", false),
        );
    }

    test "validateProviderContracts: a satisfied v2 requirement (the declared .headless) passes" {
        // The complement — requiring exactly what the v2 manifest declares proves the
        // gate fires on the MISSING capability, not on enforcement being on at all.
        const cfg = generate.ProjectConfig{
            .name = "contract-game",
            .ecs = .mock,
            .requires = &.{.headless},
            .backend_package = h.acme_foo_fixture_package,
        };
        try generate.validateProviderContracts(std.testing.allocator, cfg, ".", "backend.manifest.v2.zon", false);
    }

    test "validateProviderContracts: WITHOUT the detected v2 name the v2 capabilities are NOT enforced (proves the name is load-bearing)" {
        // The distinguishing proof for finding 2: passing null (the pre-fix behavior)
        // reads the absent legacy provider manifest → an empty declared set → the
        // back-compat gate leaves enforcement OFF, so the SAME `.screenshots`
        // requirement does NOT error. Only threading the detected v2 name enforces the
        // v2 `.capabilities` (test above).
        const cfg = generate.ProjectConfig{
            .name = "contract-game",
            .ecs = .mock,
            .requires = &.{.screenshots},
            .backend_package = h.acme_foo_fixture_package,
        };
        try generate.validateProviderContracts(std.testing.allocator, cfg, ".", null, false);
    }

    // ── Tests-target forced-null must NOT be capability-gated (issue #83) ──

    test "validateProviderContracts: the tests-target forced-null (null-v2) is NOT capability-gated even though the project derives .raw_gui_adapter" {
        // Reproduces the #83 CI break surfaced by the null→v2 flip: the tests
        // target force-substitutes `cfg.backend = .null` (a headless harness)
        // while KEEPING the project's `resolved_gui = imgui` (raw_backend), so
        // `requiredCapabilities(cfg)` still derives `.raw_gui_adapter`. null-v2
        // declares ONLY `.headless`. Before the fix the opted-in gate hard-failed
        // `error.UnsupportedCapability` for every GUI project's `zig build test`.
        //
        // Direction 1 (must PASS): is_tests_target = true skips the capability
        // requirement — the forced-null harness never builds the real GUI.
        const cfg = generate.ProjectConfig{
            .name = "gui-tests-game",
            .ecs = .mock,
            .resolved_gui = testGuiRawBackendNoBridge("imgui"), // in-backend adapter → derives .raw_gui_adapter
            .backend_package = h.null_v2_fixture_package, // declares only .headless
        };
        try generate.validateProviderContracts(std.testing.allocator, cfg, ".", "backend.manifest.v2.zon", true);
    }

    test "validateProviderContracts: the SAME GUI project's EXE target STILL fails when its backend lacks .raw_gui_adapter (issue #83)" {
        // Direction 2 (must FAIL): the exact same config validated as the REAL exe
        // target (is_tests_target = false) must still hard-error — a GUI project
        // whose chosen backend declares only `.headless` genuinely cannot satisfy
        // `.raw_gui_adapter`. This proves the tests-target skip did NOT weaken the
        // gate for the real backend selection.
        const cfg = generate.ProjectConfig{
            .name = "gui-tests-game",
            .ecs = .mock,
            .resolved_gui = testGuiRawBackendNoBridge("imgui"), // in-backend adapter → derives .raw_gui_adapter
            .backend_package = h.null_v2_fixture_package, // declares only .headless
        };
        try std.testing.expectError(
            error.UnsupportedCapability,
            generate.validateProviderContracts(std.testing.allocator, cfg, ".", "backend.manifest.v2.zon", false),
        );
    }

    // ── The SECOND gate: generateBuildZig's own v2 capability check (issue #83) ──
    // build_files.generateBuildZig runs its OWN v2 capability validation (added
    // in the #472 open-config PR), independent of the root-level
    // validateProviderContracts skip above. The tests target calls
    // generateBuildZig directly (via generateTestsTarget), so this gate must ALSO
    // skip the capability REQUIREMENT for the forced-null harness — otherwise
    // #474's gamepad example tests-target generate fails with UnsupportedCapability
    // even after the root-level fix. These drive generateBuildZig DIRECTLY (not
    // just validateProviderContracts) to lock the second skip.

    test "generateBuildZig: the tests-target forced-null (null-v2) is NOT capability-gated even though the project derives .raw_gui_adapter" {
        // Direction 1 (must PASS): is_tests_target = true skips generateBuildZig's
        // own capability requirement — the forced-null harness never builds the
        // real GUI. Mirrors the #474 gamepad example's tests-target generate.
        const cfg = generate.ProjectConfig{
            .name = "gui-tests-game",
            .ecs = .mock,
            .resolved_gui = testGuiRawBackendNoBridge("imgui"), // in-backend adapter → derives .raw_gui_adapter
        };
        const build_zig = try h.genNullV2BuildZig(std.testing.allocator, cfg, .{ .is_tests_target = true });
        std.testing.allocator.free(build_zig);
    }

    test "generateBuildZig: the SAME GUI project's EXE target STILL fails when its backend lacks .raw_gui_adapter (issue #83)" {
        // Direction 2 (must FAIL): the exact same config generated as the REAL exe
        // target (is_tests_target = false) must still hard-error in generateBuildZig
        // — null-v2 declares only `.headless` and genuinely cannot satisfy
        // `.raw_gui_adapter`. Proves the second skip did NOT weaken the gate for the
        // real backend selection.
        const cfg = generate.ProjectConfig{
            .name = "gui-tests-game",
            .ecs = .mock,
            .resolved_gui = testGuiRawBackendNoBridge("imgui"), // in-backend adapter → derives .raw_gui_adapter
        };
        try std.testing.expectError(
            error.UnsupportedCapability,
            h.genNullV2BuildZig(std.testing.allocator, cfg, .{ .is_tests_target = false }),
        );
    }

    // ── v2 loop_style resolution (the v1/legacy paths were removed in #461) ──

    test "resolveLoopStyleOverride: a v2-only backend resolves loop_style from its per-platform matrix (not the absent legacy manifest)" {
        // Distinguishing complement: sokol_v2only ships NO legacy
        // `backend.manifest.zon`, so had the code fallen to the legacy pass here
        // (`manifestPathEnabled` → absent file) the override would be null. Getting
        // a concrete `.callback` proves the `.v2` arm resolved it from the
        // per-platform matrix and `v2_resolved` correctly suppressed the legacy pass.
        const cfg = generate.ProjectConfig{
            .name = "loop-game",
            .ecs = .mock,
            .backend_package = h.sokol_v2only_fixture_package,
        };
        const override = try generate.resolveLoopStyleOverride(std.testing.allocator, cfg, ".", "backend.manifest.v2.zon");
        try std.testing.expect(override != null);
        try std.testing.expect(override.? == .callback); // sokol desktop entry = .callback
    }

    test "resolveLoopStyleOverride: reads the PER-PLATFORM v2 loop_style — bgfx desktop is .loop, android .callback" {
        // The reason loop_style MUST be per-platform, exercised end-to-end: the
        // SAME bgfx v2 manifest yields `.loop` on desktop (generated main drives
        // `while (!quit)`) and `.callback` on android (NativeActivity owns the loop).
        const desktop_cfg = generate.ProjectConfig{
            .name = "loop-game",
            .ecs = .mock,
            .backend = .bgfx,
            .platform = .desktop,
            .backend_package = h.bgfx_v2_fixture_package,
        };
        const desktop = try generate.resolveLoopStyleOverride(std.testing.allocator, desktop_cfg, ".", "backend.manifest.v2.zon");
        try std.testing.expect(desktop.? == .loop);

        const android_cfg = generate.ProjectConfig{
            .name = "loop-game",
            .ecs = .mock,
            .backend = .bgfx,
            .platform = .android,
            .backend_package = h.bgfx_v2_fixture_package,
        };
        const android = try generate.resolveLoopStyleOverride(std.testing.allocator, android_cfg, ".", "backend.manifest.v2.zon");
        try std.testing.expect(android.? == .callback);
    }
};

pub const BUILD_ZIG = struct {
    test "links sokol_clib artifact" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkLibrary") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "sokol_clib") != null);
    }

    test "sokol build does not link libudev — core dlopens it at runtime (#249)" {
        // labelle-core's Linux gamepad-detection source (gamepad_source/
        // linux.zig) loads libudev at RUNTIME via std.DynLib (dlopen of
        // `libudev.so.1`) as of labelle-core#20, degrading gracefully when
        // it is absent. So the generated sokol build must NOT emit a
        // build-time `linkSystemLibrary("udev", ...)` — doing so would
        // reintroduce a hard build/runtime dependency that defeats core's
        // graceful-degradation design. Runtime device-access setup lives in
        // docs/gamepad-linux.md.
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkSystemLibrary(\"udev\"") == null);
    }

    // NOTE: bgfx's desktop backend-dep codegen (the bgfx/glfw artifacts) is no
    // longer unit-tested here — bgfx is extracted out-of-tree (labelle-bgfx), so
    // its in-tree `backends/bgfx` is gone and there's no local package for a
    // unit test to resolve. That coverage now lives in labelle-bgfx's own CI +
    // the manifest-splice tests + the examples-integration `bgfx-external` step
    // (which fetches the package). The android codegen is still covered below
    // (it generates via the enum path on the preserved `.bgfx` tag, no package
    // resolution needed).

    test "bgfx android builds a NativeActivity shared library, not a glfw exe" {
        // Drives the v2 bgfx-Android codegen (the enum path is gone). The bgfx v2
        // fixture ships the android platform entry (`android_app` extra module
        // aliased to `backend_app`, the NDK system libs, apk packaging).
        const build_zig = try h.genBgfxV2BuildZig(std.testing.allocator, .{
            .name = "test-game",
            .platform = .android,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // Android-targeted bgfx (#303): fetch the backend for the android
        // target, pull the NativeActivity-glue `android_app` module, and
        // build a dynamic library — NOT the desktop glfw executable.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_bgfx") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, ".target = android_target") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "backend_dep.module(\"android_app\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, ".name = \"backend_app\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, ".linkage = .dynamic") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "lib.root_module.linkLibrary(bgfx)") != null);

        // NDK shell libs for the bgfx GLES renderer + NativeActivity glue.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkSystemLibrary(\"GLESv3\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkSystemLibrary(\"EGL\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkSystemLibrary(\"android\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkSystemLibrary(\"log\"") != null);

        // Desktop-only zglfw must NOT appear — it doesn't build for Android.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "glfw_artifact") == null);
        // And the APK packaging step is wired in.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "Package and sign Android APK") != null);
    }

    test "external backend named ONLY by string (no matching tag) still needs a manifest (#386)" {
        // A genuine third-party backend whose package name has no matching enum
        // tag (`cfg.backend` sits at its `.raylib` default) cannot use the enum
        // switch — that would emit raylib codegen. With no manifest splice
        // (project_dir null here), it must hard-error rather than mis-emit.
        try std.testing.expectError(error.ExternalBackendNeedsManifest, generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend_package = .{ .name = "thirdparty", .repo = "local:../tp" },
            .ecs = .mock,
        }, .{}));
    }

    test "non-tag-matched external on wasm still needs a manifest (#386)" {
        // A genuine third-party backend whose package name has no matching enum
        // tag cannot use the enum path on wasm — the `switch (cfg.backend)` would
        // emit raylib-default codegen. With no manifest splice it must hard-error.
        try std.testing.expectError(error.ExternalBackendNeedsManifest, generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .platform = .wasm,
            .backend_package = .{ .name = "thirdparty", .repo = "local:../tp" },
            .ecs = .mock,
        }, .{}));
    }

    // NOTE: wgpu's desktop backend-dep codegen (the labelle_wgpu / glfw_artifact
    // links) is no longer unit-tested here — wgpu is extracted out-of-tree
    // (labelle-wgpu), so its in-tree `backends/wgpu` is gone and there's no local
    // package for a unit test to resolve. That coverage now lives in labelle-wgpu's
    // own CI (its assembler-integration job generates a wgpu project through the
    // assembler + asserts the Foundation/QuartzCore/Metal framework links) + the
    // manifest-splice tests + the examples-integration `external-null` step.

    // NOTE: null's backend-dep codegen (modules wired, no artifact link) is no
    // longer unit-tested here — null is extracted out-of-tree (labelle-null), so
    // its in-tree `backends/null` is gone and there's no local package for a unit
    // test to resolve. That coverage now lives in labelle-null's CI + the
    // examples-integration null headless + plugin-controllers steps (which
    // generate + build + RUN a project on the fetched external null backend).

    test "deduplicates labelle-core across gfx and engine" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // gfx and engine must use the project-level core, not their own resolved version
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(gfx_mod, \"labelle-core\", core_mod)") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(engine_mod, \"labelle-core\", core_mod)") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(engine_mod, \"labelle-gfx\", gfx_mod)") != null);
    }

    test "unifies labelle-core onto gfx's sub-packages (camera/spatial_grid/tilemap) — gfx#276 diamond" {
        // gfx#276 threads the project `y_axis` (a core.YAxis) from the gfx
        // renderer into `camera.CameraWith(...)`. The camera/spatial_grid/
        // tilemap sub-packages pin their OWN labelle-core, so without unifying
        // them onto `core_mod` the two `core.YAxis` enums don't match and the
        // example fails to compile ("expected 'YAxis', found 'YAxis'").
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // The helper is defined and invoked from the deps section.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "fn unifyGfxSubpackageCore(") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "unifyGfxSubpackageCore(gfx_mod, core_mod);") != null);
        // It targets each of gfx's sub-packages by name.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "\"camera\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "\"spatial_grid\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "\"tilemap\"") != null);
    }

    // NOTE: "a self-contained (external) backend gets no backend_input core
    // override" was exercised via null, now extracted out-of-tree — no in-tree
    // package for a unit test to resolve. The self-contained → no-override
    // behavior is covered by the external-backend tests + the examples-integration
    // external-null/null steps; the IN-TREE core-import override paths
    // (raylib/sdl/sokol) are covered by the dedicated tests below.

    test "sokol emits a GUARDED backend_input core override (Linux core gamepad route)" {
        // On desktop Linux the sokol input module imports labelle-core
        // DIRECTLY to reach the udev/evdev gamepad source (core#33 scope 2);
        // on every other target that import is absent. The template therefore
        // emits the override behind an import_table.get guard so it fires
        // only when the import exists — asserting both halves here keeps the
        // guard from being "simplified" away into a dead-import injection
        // (#258) or dropped entirely (silent core type-split on Linux).
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "backend_input.import_table.get(\"labelle-core\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(backend_input, \"labelle-core\", core_mod)") != null);
    }

    test "resolved_gui wires gui_backend" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .resolved_gui = testGuiRenderInterface("clay"),
        }, .{});
        defer std.testing.allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "gui_mod") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_gui") != null);
    }

    test "resolved_gui raw_backend wires bridge artifact" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .resolved_gui = testGuiRawBackend("imgui"),
        }, .{});
        defer std.testing.allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "gui_bridge") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "gui_bridge_artifact") != null);
    }

    test "no gui omits gui_mod" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "gui_mod") == null);
    }

    test "emits test step rooted at __tests_root.zig wrapper" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // The test step is the entry point users invoke via `zig build test`.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.step(\"test\"") != null);
        // Single addTest rooted at the assembler-generated wrapper. The
        // wrapper at the build root is what lets test files reach
        // `components/`, `scripts/`, etc. via relative `@import`.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "addTest") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "__tests_root.zig") != null);
    }

    test "test step reuses exe module imports" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .zig_ecs,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // The exe and the test step both bind `ecs_backend` from `ecs_mod`,
        // so each appears twice in the rendered build.zig — once in the
        // exe imports list and once in the per-test addTest module.
        const exe_count = std.mem.count(u8, build_zig, "ecs_backend");
        try std.testing.expect(exe_count >= 2);
    }

    test "is_tests_target trims exe assembly + run step (issue #83)" {
        // The exe-trimming mechanism is backend-agnostic; use a bundled backend
        // (sokol) so the unit test needs no external resolution. (The real
        // tests-target forces null — now external — which the examples-integration
        // covers end-to-end.)
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, .{ .is_tests_target = true });
        defer std.testing.allocator.free(build_zig);

        // Test step is the only entry point — keep it.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.step(\"test\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "addTest") != null);

        // No exe assembly: `addExecutable`, `installArtifact(exe)`, the
        // run step, or `b.addRunArtifact(exe)` would all reference an
        // undefined `exe` symbol since we never declared one.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "addExecutable") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "installArtifact(exe)") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.step(\"run\"") == null);

        // overrideImport helper still emitted — the plugin/gfx/engine
        // module-graph wiring above the test step calls it.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "fn overrideImport(") != null);
    }

    test "names desktop exe after the sanitized project name (#362)" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "energy flow!",
            .backend = .sokol,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // The exe is named after the project so concurrent games are
        // distinguishable to `pgrep`; non-`[A-Za-z0-9_-]` bytes are dropped.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, ".name = \"energyflow\"") != null);
        // The hardcoded `bin/game` name is gone from the exe step.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "addExecutable") != null);
    }

    test "falls back to game when the sanitized exe name is empty (#362)" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "!!!",
            .backend = .sokol,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // The exe-name line (`.name = "game",` directly preceding the
        // `.root_module = b.createModule` of `addExecutable`) is distinct
        // from the `.{ .name = "game", .module = game_mod }` import line.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, ".name = \"game\",\n        .root_module") != null);
    }

    test "chains in-project @libs/ plugin test step into test step (issue #82)" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "pathfinder", .repo = "@libs/pathfinder" },
            },
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // Per-lib `zig build test` shelled out from the master test step.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "addSystemCommand(&.{ \"zig\", \"build\", \"test\" })") != null);
        // cwd points two levels up from the backend build dir into libs/.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.path(\"../../libs/pathfinder\")") != null);
        // The lib test is wired as a dependency of the `test` step.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "test_step.dependOn(&lib_test.step)") != null);
    }

    test "chains every @libs/ plugin into test step (issue #82)" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "pathfinder", .repo = "@libs/pathfinder" },
                .{ .name = "combat", .repo = "@libs/combat" },
            },
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.path(\"../../libs/pathfinder\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.path(\"../../libs/combat\")") != null);
        // One `addSystemCommand` per lib.
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, build_zig, "addSystemCommand(&.{ \"zig\", \"build\", \"test\" })"));
    }

    test "no @libs/ plugins emits no lib test chaining (issue #82)" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &.{},
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // No libs → no `zig build test` fan-out at all.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "\"zig\", \"build\", \"test\"") == null);
    }

    test "out-of-project local: plugins are not chained as libs (issue #82)" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &.{
                // local: paths can escape the project root — not part of
                // this project's test surface.
                .{ .name = "external", .repo = "local:../external" },
            },
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "\"zig\", \"build\", \"test\"") == null);
    }

    test "lib test chaining present in is_tests_target build (issue #82)" {
        // Lib-chaining is backend-agnostic; use a bundled backend (sokol) so the
        // unit test needs no external resolution (null is external post-#386).
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "pathfinder", .repo = "@libs/pathfinder" },
            },
        }, .{ .is_tests_target = true });
        defer std.testing.allocator.free(build_zig);

        // The tests-only target is the canonical `zig build test` entry
        // point, so it must also fan out to in-project libs.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.path(\"../../libs/pathfinder\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "test_step.dependOn(&lib_test.step)") != null);
    }
};

pub const PLUGINS = struct {
    test "no plugins excludes pathfinding/physics from build.zig.zon" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{},
        }, null, null, null, .{});
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_pathfinding") == null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_physics") == null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_tasks") == null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_core") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_gfx") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "engine") != null);
    }

    test "no plugins excludes pathfinding/physics from build.zig" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &.{},
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_pathfinding") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_physics") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_tasks") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "pf_mod") == null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "physics_mod") == null);
    }

    test "plugins enabled includes pathfinding/physics in build.zig.zon" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "pathfinding", .repo = "github.com/labelle-toolkit/labelle-pathfinding", .version = "0.1.0" },
                .{ .name = "physics", .repo = "github.com/labelle-toolkit/labelle-physics", .version = "0.1.0" },
            },
        }, null, null, null, .{});
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_pathfinding") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_physics") != null);
    }

    test "plugins enabled includes pathfinding/physics in build.zig" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "pathfinding", .repo = "github.com/labelle-toolkit/labelle-pathfinding", .version = "0.1.0" },
                .{ .name = "physics", .repo = "github.com/labelle-toolkit/labelle-physics", .version = "0.1.0" },
            },
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_pathfinding") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "labelle_physics") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "plugin_pathfinding_mod") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "plugin_physics_mod") != null);
    }

    test "plugins receive all engine subsystem imports" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .zig_ecs,
            .plugins = &.{
                .{ .name = "physics", .repo = "github.com/labelle-toolkit/labelle-physics", .version = "0.1.0" },
            },
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // Core + gfx + engine (always injected)
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"labelle-core\", core_mod)") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"labelle-gfx\", gfx_mod)") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"labelle-engine\", engine_mod)") != null);

        // ECS backend (injected when ecs != mock)
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"ecs_backend\", ecs_mod)") != null);

        // Backend modules (always injected)
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"backend_gfx\", backend_gfx)") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"backend_input\", backend_input)") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"backend_audio\", backend_audio)") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"backend_window\", backend_window)") != null);
    }

    test "plugins with mock ecs omit ecs_backend import" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "physics", .repo = "github.com/labelle-toolkit/labelle-physics", .version = "0.1.0" },
            },
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // Should NOT have ecs_backend when using mock
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(\"ecs_backend\"") == null);
        // But should still have core, gfx, engine
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"labelle-core\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"labelle-engine\"") != null);
    }

    test "plugins receive gui_backend when gui is active" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .resolved_gui = testGuiRenderInterface("clay"),
            .plugins = &.{
                .{ .name = "physics", .repo = "github.com/labelle-toolkit/labelle-physics", .version = "0.1.0" },
            },
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(plugin_physics_mod, \"gui_backend\", gui_mod)") != null);
    }

    test "plugins omit gui_backend when no gui" {
        const build_zig = try h.genSokolBuildZigV2(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "physics", .repo = "github.com/labelle-toolkit/labelle-physics", .version = "0.1.0" },
            },
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(\"gui_backend\"") == null);
    }

    test "single plugin only includes that plugin" {
        const zon = try generate.generateBuildZigZon(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .plugins = &.{
                .{ .name = "pathfinding", .repo = "github.com/labelle-toolkit/labelle-pathfinding", .version = "0.1.0" },
            },
        }, null, null, null, .{});
        defer std.testing.allocator.free(zon);

        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_pathfinding") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "labelle_physics") == null);
    }
};

// ── manifest-v2 sdl + raylib GOLDEN cells (epic #453 item 3, PR 9, design §7) ──
// sdl and raylib are converted to v2 here. Both reuse the GENERIC declarative
// desktop path (loop-form `unifyCoreDiamond` walk) landed in PR 8; raylib adds a
// WASM cell (the emcc residual in a std-only hook, mirroring PR 7's sokol wasm).
//
//   - sdl_v2 (desktop): HOOKLESS, fully declarative, NO artifact / NO system_lib —
//     SDL2 is linked inside the backend package's own window module, so the v1
//     `link.txt` is EMPTY (design §2 classifies `.link_sdl` as "empty → nothing").
//   - raylib_v2 desktop: HOOKLESS, links the `raylib` artifact + the per-OS OpenGL
//     framework/syslib switch (macOS `OpenGL` framework, Linux `GL`, Windows
//     `opengl32`), mirrored onto `test_root` (PR-8 test_root fix, review #469).
//   - raylib_v2 wasm: imports the backend hook + calls `post_wire` for the emcc
//     link residual; the manifest's `.root_build_deps = emsdk` puts emsdk in the
//     generated build.zig.zon so the hook's `b.dependency("emsdk", .{})` resolves.
//
// The core-diamond covers raylib's transitive `sdl_gamepad` sub-package generically
// (design §5): the `unifyCoreDiamond` walk rooted at `backend_input` overrides its
// direct `labelle-core` (hyphen) onto `core_mod`, then recurses into the
// `sdl_gamepad` sub-import and overrides its `labelle_core` (underscore) too — the
// two hand-written overrides in raylib's `backend_dep.txt`, without a per-backend
// site. sdl's single underscore override is handled the same way.
pub const MANIFEST_V2_SDL_GOLDEN = struct {
    const golden = @embedFile("goldens/sdl_v2.build.zig");

    fn genSdlV2() ![]const u8 {
        return h.genSdlV2BuildZig(std.testing.allocator, .{
            .name = "anchor-game",
            .backend = .sdl,
            .ecs = .mock,
        }, .{});
    }

    test "golden: v2 sdl build.zig matches the committed golden" {
        const out = try genSdlV2();
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(golden, out);
    }

    test "golden: v2 sdl build.zig is syntactically valid Zig" {
        const out = try genSdlV2();
        defer std.testing.allocator.free(out);
        const dup = try std.testing.allocator.dupeZ(u8, out);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "v2 sdl is HOOKLESS and fully declarative (no hook / no artifact / no syslib)" {
        const out = try genSdlV2();
        defer std.testing.allocator.free(out);
        // Hookless: NO backend hook import, NO resolve_target / post_wire calls.
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "resolve_target") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "post_wire") == null);
        // Declarative backend dep (no gamepad/gui toggles) + the four modules.
        try std.testing.expect(std.mem.indexOf(u8, out, "b.dependency(\"labelle_sdl\", .{ .target = target, .optimize = optimize });") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "const backend_gfx = backend_dep.module(\"gfx\");") != null);
        // The generic core-diamond walk (loop form) replaced the underscore override.
        try std.testing.expect(std.mem.indexOf(u8, out, "fn unifyCoreDiamond(") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "unifyCoreDiamond(b.allocator, backend_input, core_mod, gfx_mod,") != null);
        // NO artifact, NO link, NO framework — SDL2 is linked by the backend package.
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_dep.artifact(") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "linkLibrary") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "linkSystemLibrary") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "linkFramework") == null);
    }
};

pub const MANIFEST_V2_RAYLIB_DESKTOP_GOLDEN = struct {
    const golden = @embedFile("goldens/raylib_v2_desktop.build.zig");

    fn genRaylibV2Desktop() ![]const u8 {
        return h.genRaylibV2BuildZig(std.testing.allocator, .{
            .name = "anchor-game",
            .backend = .raylib,
            .ecs = .mock,
        }, .{});
    }

    test "golden: v2 raylib-desktop build.zig matches the committed golden" {
        const out = try genRaylibV2Desktop();
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(golden, out);
    }

    test "golden: v2 raylib-desktop build.zig is syntactically valid Zig" {
        const out = try genRaylibV2Desktop();
        defer std.testing.allocator.free(out);
        const dup = try std.testing.allocator.dupeZ(u8, out);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "v2 raylib-desktop is HOOKLESS, links raylib + per-OS OpenGL on exe AND test_root" {
        const out = try genRaylibV2Desktop();
        defer std.testing.allocator.free(out);
        // Hookless desktop: NO hook import / phases.
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "resolve_target") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "post_wire") == null);
        // Declarative backend dep forwards the gamepad flags (default cfg: auto → true).
        try std.testing.expect(std.mem.indexOf(u8, out, "b.dependency(\"labelle_raylib\", .{ .target = target, .optimize = optimize, .gamepad_enabled = true, .gamepad_hidapi = false });") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "const raylib = backend_dep.artifact(\"raylib\");") != null);
        // Generic core-diamond walk (covers the transitive sdl_gamepad at build time).
        try std.testing.expect(std.mem.indexOf(u8, out, "fn unifyCoreDiamond(") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "unifyCoreDiamond(b.allocator, backend_input, core_mod, gfx_mod,") != null);
        // exe: link raylib + the per-OS OpenGL switch.
        try std.testing.expect(std.mem.indexOf(u8, out, "exe.root_module.linkLibrary(raylib);") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "exe.root_module.linkFramework(\"OpenGL\", .{});") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "exe.root_module.linkSystemLibrary(\"GL\", .{});") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "exe.root_module.linkSystemLibrary(\"opengl32\", .{});") != null);
        // test_root: the SAME native linkage (PR-8 test_root fix, review #469).
        try std.testing.expect(std.mem.indexOf(u8, out, "test_root.root_module.linkLibrary(raylib);") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "test_root.root_module.linkFramework(\"OpenGL\", .{});") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "test_root.root_module.linkSystemLibrary(\"GL\", .{});") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "test_root.root_module.linkSystemLibrary(\"opengl32\", .{});") != null);
    }
};

pub const MANIFEST_V2_RAYLIB_WASM_GOLDEN = struct {
    const golden = @embedFile("goldens/raylib_v2_wasm.build.zig");

    const wasm_cfg: generate.ProjectConfig = .{
        .name = "anchor-game",
        .backend = .raylib,
        .platform = .wasm,
        .ecs = .mock,
    };

    // The build.zig helper pins the v2 fixture internally (backend_package +
    // project_dir + manifest name). The ZON tests call `generateBuildZigZon`
    // directly, so they must pin `backend_package` to the raylib_v2 fixture
    // themselves — a bare cfg would resolve through the enum/provider `.raylib`
    // path (backends/raylib_v2/backend.manifest.v2.zon is never consulted),
    // making the emsdk root-build-dep coverage a false positive (PR #470
    // coderabbit finding). With the fixture pinned the emsdk emission is
    // genuinely the v2 manifest's `.platforms.wasm.root_build_deps` behavior.
    const wasm_v2_cfg: generate.ProjectConfig = blk: {
        var c = wasm_cfg;
        c.backend_package = h.raylib_v2_fixture_package;
        break :blk c;
    };

    fn genRaylibV2Wasm() ![]const u8 {
        return h.genRaylibV2BuildZig(std.testing.allocator, wasm_cfg, .{});
    }

    test "golden: v2 raylib-wasm build.zig matches the committed golden" {
        const out = try genRaylibV2Wasm();
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(golden, out);
    }

    test "golden: v2 raylib-wasm build.zig is syntactically valid Zig" {
        const out = try genRaylibV2Wasm();
        defer std.testing.allocator.free(out);
        const dup = try std.testing.allocator.dupeZ(u8, out);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "v2 raylib-wasm imports the hook; post_wire does the emcc step (§2 (c))" {
        const out = try genRaylibV2Wasm();
        defer std.testing.allocator.free(out);
        // The hook is imported and post_wire is called for wasm — the emcc link
        // residual lives IN the hook (std-only reconstruction), not inline.
        try std.testing.expect(std.mem.indexOf(u8, out, "@import(\"backend_build_hook.zig\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook.post_wire(b, .{") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".platform = .wasm,") != null);
        // NO inline emcc / provider import — the enum `@import("labelle_raylib")` +
        // `emsdk.emccStep(...)`/`emcc_step` are GONE (the enum-vs-v2 boundary).
        try std.testing.expect(std.mem.indexOf(u8, out, "emccStep") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "emcc_step") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "@import(\"labelle_raylib\")") == null);
        // wasm has NO resolve_target CALL (static triple) — resolves inline.
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook.resolve_target(") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".cpu_arch = .wasm32,") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "b.resolveTargetQuery(.{") != null);
        // Declarative graph: the raylib archive is linked into the wasm lib.
        try std.testing.expect(std.mem.indexOf(u8, out, "wasm.root_module.linkLibrary(raylib);") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "fn unifyCoreDiamond(") != null);
    }

    test "v2 raylib-wasm build.zig.zon carries the emsdk root build dep (§3 RootBuildDep)" {
        const zon = try generate.generateBuildZigZon(
            std.testing.allocator,
            wasm_v2_cfg,
            null,
            null,
            ".",
            .{ .backend_manifest_name = "backend.manifest.v2.zon" },
        );
        defer std.testing.allocator.free(zon);
        try std.testing.expect(std.mem.indexOf(u8, zon, ".emsdk = .{") != null);
        try std.testing.expect(std.mem.indexOf(u8, zon, "git+https://github.com/emscripten-core/emsdk#4.0.9") != null);
    }

    test "v2 raylib-wasm zon emsdk is byte-identical to the enum-path zon" {
        // `.builtin` reuses the enum path's pinned `dep_emsdk` section (design §3).
        // Both sides pin the raylib_v2 fixture so the ONLY axis under test is the
        // manifest-v2 opt-in (v2 side sets `.backend_manifest_name`, enum side
        // does not): the v2 manifest's `.root_build_deps` emsdk emission must be
        // byte-identical to the enum-fallback `dep_emsdk` section (PR #470
        // coderabbit finding — a bare cfg made the v2 side fall to the enum path
        // too, comparing enum-vs-enum).
        //
        // #472 P1: the emsdk section is this test's subject. The BACKEND dep key,
        // however, now legitimately differs between the two zons: the raylib_v2
        // FIXTURE's package name ("raylib_v2") differs from its manifest
        // `dep_name` ("labelle_raylib"), and the v2 build.zig resolves the backend
        // via `b.dependency("labelle_raylib", ..)`. The v2 zon therefore CORRECTLY
        // keys the backend dep `labelle_raylib` (matching build.zig), while the
        // enum-path zon still derives it from the package name. The emsdk block is
        // emitted after all path-deps and is unaffected — compare from there.
        const v2_zon = try generate.generateBuildZigZon(
            std.testing.allocator,
            wasm_v2_cfg,
            null,
            null,
            ".",
            .{ .backend_manifest_name = "backend.manifest.v2.zon" },
        );
        defer std.testing.allocator.free(v2_zon);
        const enum_zon = try generate.generateBuildZigZon(
            std.testing.allocator,
            wasm_v2_cfg,
            null,
            null,
            ".",
            .{},
        );
        defer std.testing.allocator.free(enum_zon);

        const v2_emsdk = v2_zon[std.mem.indexOf(u8, v2_zon, ".emsdk = .{").?..];
        const enum_emsdk = enum_zon[std.mem.indexOf(u8, enum_zon, ".emsdk = .{").?..];
        try std.testing.expectEqualStrings(enum_emsdk, v2_emsdk);

        // Lock in the P1 fix: the v2 zon keys the backend dep by `dep_name`
        // (`labelle_raylib`, matching `b.dependency("labelle_raylib")` in the v2
        // build.zig), NOT the package-name derivation (`labelle_raylib_v2`).
        try std.testing.expect(std.mem.indexOf(u8, v2_zon, ".labelle_raylib = .{") != null);
        try std.testing.expect(std.mem.indexOf(u8, v2_zon, "labelle_raylib_v2") == null);
    }
};

// ── PR 9: the raylib v2 backend build hook is staged as a sibling ──
// The generated v2 raylib-wasm build.zig `@import`s `backend_build_hook.zig`; the
// generator must copy the raylib_v2 manifest's `build_hook` to that sibling name.
pub const PR9_STAGE_RAYLIB_HOOK = struct {
    test "stages raylib_v2 build_hook next to build.zig as backend_build_hook.zig" {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const target_dir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
        defer std.testing.allocator.free(target_dir);

        var cfg: generate.ProjectConfig = .{
            .name = "anchor-game",
            .backend = .raylib,
            .platform = .wasm,
            .ecs = .mock,
        };
        cfg.backend_package = h.raylib_v2_fixture_package;

        const staged = try generate.stageBackendBuildHook(
            std.testing.allocator,
            cfg,
            ".",
            "backend.manifest.v2.zon",
            target_dir,
        );
        try std.testing.expect(staged);

        const got = try tmp.dir.readFileAlloc(io, generate.backend_build_hook_name, std.testing.allocator, .limited(256 * 1024));
        defer std.testing.allocator.free(got);
        const want = try std.Io.Dir.cwd().readFileAlloc(io, "backends/raylib_v2/backend.hook.zig", std.testing.allocator, .limited(256 * 1024));
        defer std.testing.allocator.free(want);
        try std.testing.expectEqualStrings(want, got);
    }
};


// ── manifest-v2 bgfx GOLDEN cells (epic #453 item 3, PR 10, design §7) ──
// bgfx is the LAST + HARDEST backend converted to v2 — the first needing BOTH
// per-platform `loop_style` (desktop `.loop`, android `.callback`) AND a
// platform-only `extra_modules` with a non-default `root_alias` (android's
// `android_app` → `backend_app`), both from ONE manifest. Two golden cells:
//
//   - bgfx_v2 DESKTOP: HOOKLESS, generic declarative path — the `bgfx` + `glfw`
//     artifacts linked onto exe AND test_root, the base `gui_enabled` + desktop
//     `gamepad_*` dep_options, the generic `unifyCoreDiamond` walk (which covers the
//     transitive `sdl_gamepad` sub-package at build time — the enum
//     `backend_bgfx` :162 override, without a per-backend site).
//   - bgfx_v2 ANDROID: HOOK-BEARING — `resolve_target` (ABI) BEFORE any
//     b.dependency + `post_wire` (the bgfx-Android NDK residual: addLibraryPath +
//     libc.txt). The `android_app` extra module is pulled and aliased to
//     `backend_app` (the load-bearing correctness bit, design §3 review-correction
//     #3 — a wrong alias breaks the generated main's `@import("backend_app")`
//     NativeActivity shell import). Declarative NDK system libs + link_libc, apk
//     packaging via the shared packager. Core-diamond covers android's direct
//     `labelle-core` (#310 vtable) import on `backend_input` generically.
//
// Like every hook-bearing/generic v2 cell this is a committed golden (reviewed by
// hand against the enum `backend_bgfx`/`link_bgfx`/`backend_bgfx_android`/
// `android_link_bgfx` output for graph equivalence) PLUS the hook's own gates:
// `backends/bgfx_v2/backend.hook.zig` is compiled as a test target in build.zig
// (typechecking `resolve_target`/`post_wire` against std.Build) and unit-tests its
// pure decision helpers. See design §7 for why the text golden alone is blind to
// the hook body.
pub const MANIFEST_V2_BGFX_DESKTOP_GOLDEN = struct {
    const golden = @embedFile("goldens/bgfx_v2_desktop.build.zig");

    fn genBgfxV2Desktop() ![]const u8 {
        return h.genBgfxV2BuildZig(std.testing.allocator, .{
            .name = "anchor-game",
            .backend = .bgfx,
            .ecs = .mock,
        }, .{});
    }

    test "golden: v2 bgfx-desktop build.zig matches the committed golden" {
        const out = try genBgfxV2Desktop();
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(golden, out);
    }

    test "golden: v2 bgfx-desktop build.zig is syntactically valid Zig" {
        const out = try genBgfxV2Desktop();
        defer std.testing.allocator.free(out);
        const dup = try std.testing.allocator.dupeZ(u8, out);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "v2 bgfx-desktop is HOOKLESS, links bgfx+glfw on exe AND test_root, generic diamond" {
        const out = try genBgfxV2Desktop();
        defer std.testing.allocator.free(out);
        // Hookless desktop: NO hook import / phases (desktop `.loop`, `.native`).
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "resolve_target") == null);
        try std.testing.expect(std.mem.indexOf(u8, out, "post_wire") == null);
        // Declarative backend dep forwards gui_enabled (base) + gamepad_* (desktop
        // append; default cfg: gamepad auto → true, hidapi false).
        try std.testing.expect(std.mem.indexOf(u8, out, "b.dependency(\"labelle_bgfx\", .{ .target = target, .optimize = optimize, .gui_enabled = false, .gamepad_enabled = true, .gamepad_hidapi = false });") != null);
        // BOTH artifacts declared.
        try std.testing.expect(std.mem.indexOf(u8, out, "const bgfx = backend_dep.artifact(\"bgfx\");") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "const glfw = backend_dep.artifact(\"glfw\");") != null);
        // Generic core-diamond walk (loop form) — covers the transitive sdl_gamepad.
        try std.testing.expect(std.mem.indexOf(u8, out, "fn unifyCoreDiamond(") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "unifyCoreDiamond(b.allocator, backend_input, core_mod, gfx_mod,") != null);
        // exe + test_root: link BOTH bgfx and glfw (no glfw-only, no frameworks).
        try std.testing.expect(std.mem.indexOf(u8, out, "exe.root_module.linkLibrary(bgfx);") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "exe.root_module.linkLibrary(glfw);") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "test_root.root_module.linkLibrary(bgfx);") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "test_root.root_module.linkLibrary(glfw);") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "linkFramework") == null);
    }
};

pub const MANIFEST_V2_BGFX_ANDROID_GOLDEN = struct {
    const golden = @embedFile("goldens/bgfx_v2_android.build.zig");

    fn genBgfxV2Android() ![]const u8 {
        return h.genBgfxV2BuildZig(std.testing.allocator, .{
            .name = "anchor-game",
            .backend = .bgfx,
            .platform = .android,
            .ecs = .mock,
        }, .{});
    }

    test "golden: v2 bgfx-android build.zig matches the committed golden" {
        const out = try genBgfxV2Android();
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(golden, out);
    }

    test "golden: v2 bgfx-android build.zig is syntactically valid Zig" {
        const out = try genBgfxV2Android();
        defer std.testing.allocator.free(out);
        const dup = try std.testing.allocator.dupeZ(u8, out);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "v2 bgfx-android: android_app aliased to backend_app (the load-bearing bit, §3)" {
        const out = try genBgfxV2Android();
        defer std.testing.allocator.free(out);
        // The extra module is pulled as `android_app` and published under the
        // alias `backend_app` — the DEFAULT alias would be `backend_android_app`,
        // which breaks the generated main's `@import("backend_app")` shell import.
        try std.testing.expect(std.mem.indexOf(u8, out, "const backend_app = backend_dep.module(\"android_app\");") != null);
        // …and it is imported into the .so root module under that exact alias.
        try std.testing.expect(std.mem.indexOf(u8, out, ".{ .name = \"backend_app\", .module = backend_app },") != null);
        // The wrong (default) alias never appears.
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_android_app") == null);
        // The extra module is walked by the generic core-diamond too (design §5).
        try std.testing.expect(std.mem.indexOf(u8, out, "unifyCoreDiamond(b.allocator, backend_app, core_mod, gfx_mod,") != null);
    }

    test "v2 bgfx-android imports the backend hook and calls BOTH phases (§4)" {
        const out = try genBgfxV2Android();
        defer std.testing.allocator.free(out);
        // resolve_target BEFORE any b.dependency (produces android_target).
        try std.testing.expect(std.mem.indexOf(u8, out, "@import(\"backend_build_hook.zig\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook.resolve_target(b, .{ .platform = .android }).target") != null);
        // post_wire AFTER wiring, carrying the REQUIRED android_target_sdk (34).
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook.post_wire(b, .{") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".android_target_sdk = 34,") != null);
        // Generic core-diamond walk (loop form) replaced the unrolled #310 override.
        try std.testing.expect(std.mem.indexOf(u8, out, "fn unifyCoreDiamond(") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "unifyCoreDiamond(b.allocator, backend_input, core_mod, gfx_mod,") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "unifyGfxSubpackageCore(gfx_mod, core_mod)") == null);
        // Declarative graph: bgfx artifact link + NDK system libs + link_libc.
        try std.testing.expect(std.mem.indexOf(u8, out, "lib.root_module.linkLibrary(bgfx)") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "lib.root_module.link_libc = true;") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "lib.root_module.linkSystemLibrary(\"mediandk\", .{})") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "lib.root_module.linkSystemLibrary(\"aaudio\", .{})") != null);
        // NO glfw on android (zglfw is desktop-only, #303).
        try std.testing.expect(std.mem.indexOf(u8, out, "artifact(\"glfw\")") == null);
        // APK packaging delegated to the shared packager (byte-identical section).
        try std.testing.expect(std.mem.indexOf(u8, out, "Package and sign Android APK") != null);
        // The enum-path inline NDK detection is GONE — it lives in the hook now.
        try std.testing.expect(std.mem.indexOf(u8, out, "fn getAndroidNdkSysroot(") == null);
    }
};



// ── manifest-v2 bgfx WASM GOLDEN cell (bgfx-wasm epic labelle-bgfx#8) ──
// The THIRD bgfx platform (after desktop PR 10 + android). wasm is the emcc
// residual (design §2 (c)): `post_wire`'s `.wasm` arm reconstructs the emcc
// `emLinkStep` (walking bgfx+bx+bimg) + owns the web install/run wiring, so the
// v2 wasm path emits NO packager `.web` footer. It has NO `resolve_target` — the
// target is the STATIC `.triple` "wasm32-emscripten", resolved inline. The
// declarative half (module/artifact decls + generic `unifyCoreDiamond` walk +
// `linkLibrary(bgfx)`) is emitted from the manifest; the emcc step is the hook's.
// Regression-locks the assembler-side fixes that made a first-party external
// CALLBACK backend buildable on wasm (the callback-lifecycle gate + the
// `{{module_vars}}` runner injection + the panic-shim de-dup live in the
// main.zig path; this golden pins the build.zig graph).
pub const MANIFEST_V2_BGFX_WASM_GOLDEN = struct {
    const golden = @embedFile("goldens/bgfx_v2_wasm.build.zig");

    fn genBgfxV2Wasm() ![]const u8 {
        return h.genBgfxV2BuildZig(std.testing.allocator, .{
            .name = "bgfxgame",
            .backend = .bgfx,
            .platform = .wasm,
        }, .{});
    }

    test "golden: v2 bgfx-wasm build.zig matches the committed golden" {
        const out = try genBgfxV2Wasm();
        defer std.testing.allocator.free(out);
        try std.testing.expectEqualStrings(golden, out);
    }

    test "golden: v2 bgfx-wasm build.zig is syntactically valid Zig" {
        const out = try genBgfxV2Wasm();
        defer std.testing.allocator.free(out);
        const dup = try std.testing.allocator.dupeZ(u8, out);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }

    test "v2 bgfx-wasm: static wasm32 target, imports hook, post_wire does the emcc step" {
        const out = try genBgfxV2Wasm();
        defer std.testing.allocator.free(out);
        // STATIC triple resolved inline — NO resolve_target hook (design §3).
        try std.testing.expect(std.mem.indexOf(u8, out, ".cpu_arch = .wasm32,") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".os_tag = .emscripten,") != null);
        // No `resolve_target` CALL (the static triple resolves inline; the phrase
        // appears only in the explanatory comment).
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook.resolve_target(") == null);
        // Backend hook imported + post_wire called for wasm (owns the emcc link).
        try std.testing.expect(std.mem.indexOf(u8, out, "backend_build_hook = @import(\"backend_build_hook.zig\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, ".platform = .wasm,") != null);
        // Declarative graph: the bgfx artifact is linked into the wasm lib (emcc
        // walks its transitive bgfx+bx+bimg deps in the hook).
        try std.testing.expect(std.mem.indexOf(u8, out, "wasm.root_module.linkLibrary(bgfx)") != null);
        // NO glfw on wasm (zglfw is desktop-only, like android).
        try std.testing.expect(std.mem.indexOf(u8, out, "artifact(\"glfw\")") == null);
        // Not the android residual — no NDK detection leaks here.
        try std.testing.expect(std.mem.indexOf(u8, out, "getAndroidNdkSysroot(") == null);
    }

    test "v2 bgfx-wasm: a NON-preview build.zig carries NO editor_preview field" {
        // Back-compat property (editor preview, labelle-studio Play mode):
        // normal builds must keep compiling against hooks that predate the
        // `editor_preview` HookContext field, so the generated post_wire
        // call omits it entirely. (Byte-locked by the golden above too —
        // this pins the WHY.)
        const out = try genBgfxV2Wasm();
        defer std.testing.allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "editor_preview") == null);
    }

    test "v2 bgfx-wasm: editor preview threads .editor_preview = true into post_wire" {
        // Editor-preview generation (LABELLE_EDITOR_PREVIEW=1 →
        // cfg.editor_preview): the emcc hook arm must learn preview is on so
        // it keeps the `_editor_*` exports alive (-sEXPORTED_FUNCTIONS
        // replaces the default list AND emcc hard-errors on missing exported
        // symbols, so the exports can only be added when the generated main
        // actually binds engine.editor_api).
        const out = try h.genBgfxV2BuildZig(std.testing.allocator, .{
            .name = "bgfxgame",
            .backend = .bgfx,
            .platform = .wasm,
            .editor_preview = true,
        }, .{});
        defer std.testing.allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, ".editor_preview = true,") != null);
        // Threaded into the post_wire context literal (inside the call).
        const post_wire_at = std.mem.indexOf(u8, out, "backend_build_hook.post_wire(b, .{").?;
        const field_at = std.mem.indexOf(u8, out, ".editor_preview = true,").?;
        try std.testing.expect(post_wire_at < field_at);

        // Still syntactically valid Zig.
        const dup = try std.testing.allocator.dupeZ(u8, out);
        defer std.testing.allocator.free(dup);
        var ast = try std.zig.Ast.parse(std.testing.allocator, dup, .zig);
        defer ast.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    }
};
