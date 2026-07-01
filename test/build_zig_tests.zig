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
    fn expectV2MatchesEnum(cfg: generate.ProjectConfig) !void {
        const enum_baseline = try h.genSokolBuildZig(std.testing.allocator, cfg, .{});
        defer std.testing.allocator.free(enum_baseline);
        const v2_out = try h.genSokolBuildZigV2(std.testing.allocator, cfg, .{});
        defer std.testing.allocator.free(v2_out);
        // Byte anchor: 0 diff. `expectEqualStrings` prints the first divergence,
        // so a regression in the v2 model surfaces as a readable line delta.
        try std.testing.expectEqualStrings(enum_baseline, v2_out);
    }

    test "byte anchor: v2 desktop == enum/v1, default cfg (gamepad auto, no gui)" {
        try expectV2MatchesEnum(.{ .name = "anchor-game", .backend = .sokol, .ecs = .mock });
    }

    test "byte anchor: v2 desktop == enum/v1, gamepad off" {
        try expectV2MatchesEnum(.{ .name = "anchor-game", .backend = .sokol, .ecs = .mock, .gamepad = .none });
    }

    test "byte anchor: v2 desktop == enum/v1, gamepad hidapi on" {
        try expectV2MatchesEnum(.{ .name = "anchor-game", .backend = .sokol, .ecs = .mock, .gamepad_hidapi = true });
    }

    test "byte anchor: v2 desktop == enum/v1, with plugins + zig_ecs (shared regions unaffected)" {
        // The backend-dep + link regions are the only v2-touched cells; wiring
        // plugins/ecs exercises that everything AROUND them stays identical too.
        // A REAL plugin entry is load-bearing here: plugin modules flow through
        // the core-diamond `overrideImport` region, so the byte anchor only
        // exercises the plugin-wiring path if a plugin is actually present. The
        // plugin need not resolve on disk — `generateBuildZig` emits the plugin
        // dep/module decls from the config alone (only build.zig.zon resolution
        // touches disk), so a plausible labelle-toolkit slug is enough.
        try expectV2MatchesEnum(.{
            .name = "anchor-game",
            .backend = .sokol,
            .ecs = .zig_ecs,
            .plugins = &.{
                .{ .name = "pathfinding", .repo = "github:labelle-toolkit/labelle-pathfinding", .version = "2.6.0" },
            },
        });
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

    test "enum android: promoted scripts + no plugins/ecs/gui still defines `target`" {
        const out = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "anchor-game",
            .backend = .sokol,
            .platform = .android,
            .ecs = .mock,
        }, .{ .promoted_scripts = &promoted });
        defer std.testing.allocator.free(out);
        try expectDefinesTarget(out);
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

pub const BUILD_ZIG = struct {
    test "links sokol_clib artifact" {
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .bgfx,
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
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkLibrary(bgfx_artifact)") != null);

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

    test "external backend matching its enum tag uses the enum path on non-desktop (#386)" {
        // bgfx extracted out-of-tree, selected via `.backend = .bgfx` while a
        // package resolves it (the post-flip shape). On ANDROID the desktop-only
        // manifest splice doesn't run, so the backend-dep section falls through
        // to the enum `switch (cfg.backend)` — which is correct, because the tag
        // is preserved and the android sections pull the backend from
        // `b.dependency("labelle_bgfx")` (resolving to the fetched package). It
        // must NOT raise ExternalBackendNeedsManifest. (Validated on-device: FP
        // builds + runs against the external bgfx; the build_files guard that
        // distinguishes "named by a tag" from "named only by string" is what
        // lets the android path through.)
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .bgfx,
            .platform = .android,
            .backend_package = .{ .name = "bgfx", .repo = "local:../bgfx" },
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.dependency(\"labelle_bgfx\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "backend_dep.module(\"android_app\")") != null);
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

    test "tag-matched external raylib on wasm uses the enum path — emits emsdk + emcc link (#386 regression)" {
        // Post-flip, `.backend = .raylib` resolves to labelle-raylib (external
        // by default), so on wasm the old `if (!cfg.isExternal())` gates skipped
        // the raylib emsdk/link sections AND the backend-dep switch hard-errored
        // with ExternalBackendNeedsManifest — breaking the existing raylib web
        // build. A tag-matched external on wasm must instead fall through to the
        // enum path (no manifest splice on wasm) and emit the wasm sections.
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .raylib,
            .platform = .wasm,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // emsdk helper import + the emcc link step must both be present.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "@import(\"labelle_raylib\").emsdk") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "emsdk.emccStep(b, raylib_artifact, wasm") != null);
    }

    test "tag-matched external sokol on wasm uses the enum path — emits sokol wasm dep + emLinkStep (#386 regression)" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .platform = .wasm,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // Wasm-specific sokol backend dep + the emcc emLinkStep wiring.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.dependency(\"labelle_sokol\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "sokol_em.emLinkStep(b, .{") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "wasm.root_module.linkLibrary(backend_dep.artifact(\"sokol_clib\"))") != null);
    }

    test "tag-matched external sokol on ios uses the enum path — emits sokol ios dep + framework link (#386 regression)" {
        const build_zig = try generate.generateBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .platform = .ios,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);

        // iOS sokol backend dep (dont_link_system_libs) + the manual framework link.
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "b.dependency(\"labelle_sokol\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, ".dont_link_system_libs = true") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "linkIosFrameworks(exe)") != null);
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "backend_input.import_table.get(\"labelle-core\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "overrideImport(backend_input, \"labelle-core\", core_mod)") != null);
    }

    test "resolved_gui wires gui_backend" {
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
        }, .{});
        defer std.testing.allocator.free(build_zig);
        try std.testing.expect(std.mem.indexOf(u8, build_zig, "gui_mod") == null);
    }

    test "emits test step rooted at __tests_root.zig wrapper" {
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
        const build_zig = try h.genSokolBuildZig(std.testing.allocator, .{
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
