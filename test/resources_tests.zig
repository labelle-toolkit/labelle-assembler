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

pub const RESOURCES = struct {
    test "generates embedded atlas loading from resource config" {
        // Resources here are passed with explicit `lazy = false` so the
        // emitted code path uses `loadAtlasFromMemory` (eager). Without
        // the explicit override, ticket #48's default-flip pass would
        // resolve null → lazy and the emitted call site would be
        // `registerAtlasFromMemory`. That separate default-flip
        // behavior is covered by the LAZY_DEFAULTS test block below.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "characters", .json = "assets/characters.json", .texture = "assets/characters.png", .lazy = false },
                .{ .name = "tiles", .json = "assets/tiles.json", .texture = "assets/tiles.png", .lazy = false },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Resources are embedded via @embedFile + loadAtlasFromMemory
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadAtlasFromMemory(\"characters\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"assets/characters.json\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"assets/characters.png\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadAtlasFromMemory(\"tiles\"") != null);
        // No comptime ResourceRegistry
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "ResourceRegistry") == null);
    }

    test "omits atlas loading when no resources" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadAtlasFromMemory") == null);
    }

    test "explicit lazy=true emits registerAtlasFromMemory" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "characters", .json = "assets/characters.json", .texture = "assets/characters.png", .lazy = true },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerAtlasFromMemory(\"characters\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadAtlasFromMemory(\"characters\"") == null);
    }

    test "lazy=null falls back to eager at codegen time (matches back-compat rule)" {
        // When `generate()` hasn't run its default-inference pass (e.g.
        // a direct test call into `generateMainZigFromTemplate`), the
        // codegen fallback picks EAGER. This matches the back-compat
        // rule in `lazy_inference.resolveLazyDefaults`: a resource with
        // `lazy = null` that isn't referenced by any scene stays eager
        // so legacy projects keep decoding their atlases at startup.
        // Picking `lazy` here would silently break unmigrated projects.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "characters", .json = "assets/characters.json", .texture = "assets/characters.png" },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadAtlasFromMemory(\"characters\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerAtlasFromMemory(\"characters\"") == null);
    }
};

pub const RESOURCE_EMISSION = struct {
    test "atlas emission stays on the legacy loadAtlasFromMemory path" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "world", .json = "atlases/world.json", .texture = "atlases/world.png", .lazy = false },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadAtlasFromMemory(\"world\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"atlases/world.json\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@embedFile(\"atlases/world.png\")") != null);
    }

    test "image resource emits an AssetCatalog image registration + eager load (#675)" {
        // A loose PNG has no manifest and no sub-rects, so it never goes
        // near `loadAtlasFromMemory`. It is registered straight onto the
        // catalog under `LoaderKind.image` — the key the engine's `Image`
        // component resolves against — and, being eager, acquired at init
        // so the decode is enqueued without waiting for a scene's
        // `assets:` block to ask for it.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "portrait", .image = "assets/portrait.png", .lazy = false },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.assets.register(\"portrait\", .image, \".png\", @embedFile(\"assets/portrait.png\"))") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_ = try g.assets.acquire(\"portrait\");") != null);
        // The whole point of #675: no 1-sprite-atlas workaround is emitted.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "AtlasFromMemory(\"portrait\"") == null);
    }

    test "lazy image resource registers only — no eager acquire (#675)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "banner", .image = "assets/banner.png", .lazy = true },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.assets.register(\"banner\", .image, \".png\", @embedFile(\"assets/banner.png\"))") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.assets.acquire(\"banner\")") == null);
    }

    test "image resource on the sokol callback path panics instead of returning (#675)" {
        // The sokol init callback has no error channel, so the emitted
        // registration must not `return err` — same contract the other
        // three kinds honour via `.catch_panic_style`.
        h.setSokolLifecycle();
        defer h.clearLifecycleOverrides();
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "logo", .image = "assets/logo.png", .lazy = false },
            },
        }, sokol_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "@panic(\"failed to register image: logo\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "_ = g.assets.acquire(\"logo\") catch @panic(\"failed to acquire image: logo\");") != null);
    }

    test "image resource keeps its real extension in the emitted file_type (#675)" {
        // `.astc` / `.rgba` siblings carry their own container magic; the
        // emitted `file_type` must report what the bytes actually are
        // rather than a hard-coded ".png".
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "sky", .image = "assets/sky.astc", .lazy = true },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.assets.register(\"sky\", .image, \".astc\", @embedFile(\"assets/sky.astc\"))") != null);
    }

    test "atlas / sound / font emission is untouched by the image kind (#675)" {
        // #675 is purely additive: a project mixing all four kinds must
        // still emit the pre-existing three call shapes verbatim.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "world", .json = "atlases/world.json", .texture = "atlases/world.png", .lazy = false },
                .{ .name = "portrait", .image = "assets/portrait.png", .lazy = false },
                .{ .name = "click", .sound = "audio/click.wav", .lazy = false },
                .{ .name = "ui_font", .font = "fonts/ui.ttf", .lazy = false },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "try g.loadAtlasFromMemory(\"world\", @embedFile(\"atlases/world.json\"), @embedFile(\"atlases/world.png\"), \".png\");") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "try g.loadSoundFromMemory(\"click\", \"wav\", @embedFile(\"audio/click.wav\"));") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "try g.loadFontFromMemory(\"ui_font\", \"ttf\", @embedFile(\"fonts/ui.ttf\"), &ui_font_params);") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.assets.register(\"portrait\", .image,") != null);
    }

    test "validation rejects image resource with unsupported extension (#675)" {
        const result = generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "bad", .image = "assets/portrait.wav", .lazy = false },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        try std.testing.expectError(error.UnsupportedResourceExtension, result);
    }

    test "image resource lower-cases the emitted file_type (#675, copilot #676)" {
        // Extension validation is case-insensitive, so `Logo.PNG` is a
        // legal declaration — but the `file_type` contract is the
        // LOWER-CASE extension. Emitting ".PNG" would hand a
        // case-sensitive backend `decodeImage` a type it doesn't match.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "logo", .image = "assets/Logo.PNG", .lazy = true },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.assets.register(\"logo\", .image, \".png\", @embedFile(\"assets/Logo.PNG\"))") != null);
        // The PATH keeps its on-disk spelling — only the file_type is
        // normalised, or the generated `@embedFile` would not resolve.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "\".PNG\"") == null);
    }

    test "validation rejects two image resources sharing a name (#675, coderabbit #676)" {
        // The name is the asset-catalog key. The generated
        // registration swallows `AssetAlreadyRegistered`, so a
        // duplicate would silently keep the FIRST image and resolve
        // every `acquire` to the wrong asset — reject before emission.
        const result = generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "logo", .image = "assets/logo.png", .lazy = false },
                .{ .name = "logo", .image = "assets/logo_alt.png", .lazy = false },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        try std.testing.expectError(error.DuplicateResourceName, result);
    }

    test "validation rejects a duplicate name across resource kinds (#676)" {
        // Same catalog key, different kinds — an atlas and a loose
        // image both named "hero". Equally silent at runtime, equally
        // rejected. Also covers the game-vs-pack shape: a merged
        // `<pack>__<name>` entry is just another entry in this list.
        const result = generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "hero", .json = "assets/hero.json", .texture = "assets/hero.png", .lazy = false },
                .{ .name = "hero", .image = "assets/hero_portrait.png", .lazy = false },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        try std.testing.expectError(error.DuplicateResourceName, result);
    }

    test "distinct resource names with the same path are fine (#676)" {
        // The duplicate check keys on NAME, not path — two resources
        // pointing at one file is unusual but harmless (two catalog
        // entries, two registrations, no collision).
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "logo", .image = "assets/logo.png", .lazy = true },
                .{ .name = "logo_hud", .image = "assets/logo.png", .lazy = true },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.assets.register(\"logo\", .image,") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "g.assets.register(\"logo_hud\", .image,") != null);
    }

    test "validation rejects `.image` mixed with the atlas pair (#675)" {
        const result = generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "mixed", .image = "assets/tiles.png", .json = "assets/tiles.json" },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        try std.testing.expectError(error.InvalidResource, result);
    }

    test "sound resource emits loadSoundFromMemory with extension-derived file_type" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "boss_theme", .sound = "audio/boss.ogg", .lazy = false },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadSoundFromMemory(\"boss_theme\", \"ogg\", @embedFile(\"audio/boss.ogg\"))") != null);
        // Must NOT generate an atlas call for a sound resource.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadAtlasFromMemory(\"boss_theme\"") == null);
    }

    test "lazy sound resource emits registerSoundFromMemory" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "sfx_click", .sound = "audio/click.wav", .lazy = true },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerSoundFromMemory(\"sfx_click\", \"wav\", @embedFile(\"audio/click.wav\"))") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadSoundFromMemory(\"sfx_click\"") == null);
    }

    test "font resource emits FontBakeParams const + loadFontFromMemory" {
        const ranges = [_]generate.CodepointRange{
            .{ .first = 0x20, .last = 0x7F },
        };
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{
                    .name = "ui_font",
                    .font = "fonts/m5x7.ttf",
                    .font_params = .{ .pixel_height = 16, .ranges = &ranges, .atlas_width = 512, .atlas_height = 512 },
                    .lazy = false,
                },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Locally-materialised ranges array.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const ui_font_ranges = [_]engine.CodepointRange{") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".first = 0x20, .last = 0x7F") != null);
        // Locally-materialised params struct.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "const ui_font_params: engine.FontBakeParams = .{") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".pixel_height = 16") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".ranges = &ui_font_ranges") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".atlas_width = 512") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".atlas_height = 512") != null);
        // The load call passes the params pointer.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadFontFromMemory(\"ui_font\", \"ttf\", @embedFile(\"fonts/m5x7.ttf\"), &ui_font_params)") != null);
    }

    test "font resource without explicit font_params uses defaults" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                // No font_params — defaults pulled from FontBakeParams{}.
                .{ .name = "default_font", .font = "fonts/default.otf", .lazy = false },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // Default pixel_height = 16, atlas 512×512, ASCII printable range.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".pixel_height = 16") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".atlas_width = 512") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, ".first = 0x20, .last = 0x7F") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadFontFromMemory(\"default_font\", \"otf\"") != null);
    }

    test "sound file_type is lower-cased regardless of the path's casing (#680)" {
        // Extension validation is case-insensitive (`std.ascii.eqlIgnoreCase`
        // in `codegen/validate.zig`), so `audio/Track.WAV` is a legal
        // declaration — but the `file_type` contract is the LOWER-CASE
        // extension. The shared decoder dispatches with
        // `std.mem.eql(u8, file_type, "wav")` (labelle-audio
        // `src/decode.zig`), so an emitted "WAV" fails at runtime with
        // `error.AudioUnsupportedFormat`.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "track", .sound = "audio/Track.WAV", .lazy = false },
                .{ .name = "shout", .sound = "audio/Shout.Ogg", .lazy = true },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        // The PATH keeps its on-disk spelling — only the file_type is
        // normalised, or the generated `@embedFile` would not resolve.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadSoundFromMemory(\"track\", \"wav\", @embedFile(\"audio/Track.WAV\"))") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerSoundFromMemory(\"shout\", \"ogg\", @embedFile(\"audio/Shout.Ogg\"))") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "\"WAV\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "\"Ogg\"") == null);
    }

    test "font file_type is lower-cased regardless of the path's casing (#680)" {
        // Same contract as the sound arm. Both in-tree `decodeFont`
        // implementations discard `file_type` today, so this one is about
        // keeping the generated source honest to the documented contract
        // rather than fixing an observable runtime failure.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "ui_font", .font = "fonts/Font.TTF", .lazy = false },
                .{ .name = "alt_font", .font = "fonts/Alt.Otf", .lazy = true },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadFontFromMemory(\"ui_font\", \"ttf\", @embedFile(\"fonts/Font.TTF\"), &ui_font_params)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "registerFontFromMemory(\"alt_font\", \"otf\", @embedFile(\"fonts/Alt.Otf\"), &alt_font_params)") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "\"TTF\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "\"Otf\"") == null);
    }

    test "mixed resources emit one call per kind, in declared order" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "world", .json = "atlases/world.json", .texture = "atlases/world.png", .lazy = false },
                .{ .name = "boss", .sound = "audio/boss.ogg", .lazy = false },
                .{ .name = "ui_font", .font = "fonts/m5x7.ttf", .lazy = false },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        const world_pos = std.mem.indexOf(u8, main_zig, "loadAtlasFromMemory(\"world\"") orelse return error.AtlasMissing;
        const boss_pos = std.mem.indexOf(u8, main_zig, "loadSoundFromMemory(\"boss\"") orelse return error.SoundMissing;
        const font_pos = std.mem.indexOf(u8, main_zig, "loadFontFromMemory(\"ui_font\"") orelse return error.FontMissing;
        // Declared order preserved in emission — keeps the codegen
        // deterministic across runs and the per-resource constants
        // (e.g. `ui_font_ranges`) declared before their consumer.
        try std.testing.expect(world_pos < boss_pos);
        try std.testing.expect(boss_pos < font_pos);
    }

    test "validation rejects sound resource with unsupported extension" {
        const result = generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "bad", .sound = "audio/song.mp3", .lazy = false },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        try std.testing.expectError(error.UnsupportedResourceExtension, result);
    }

    test "validation rejects font resource with unsupported extension" {
        const result = generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "bad", .font = "fonts/wrong.png", .lazy = false },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        try std.testing.expectError(error.UnsupportedResourceExtension, result);
    }

    test "validation rejects no-path resource" {
        const result = generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "empty" },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        try std.testing.expectError(error.InvalidResource, result);
    }

    test "validation rejects atlas-incomplete resource" {
        const result = generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "half", .texture = "atlas.png" }, // missing .json
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        try std.testing.expectError(error.InvalidResource, result);
    }

    test "validation rejects multiple-path resource" {
        const result = generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "tangle", .sound = "x.wav", .font = "y.ttf" },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        try std.testing.expectError(error.InvalidResource, result);
    }

    test "validation rejects font resource name with hyphen (Bugbot finding on #105)" {
        // Cursor Bugbot flagged that `emitResourceLoad` for fonts
        // interpolates the resource name into Zig identifier positions
        // (`{name}_ranges`, `{name}_params`). Without this guard a
        // name like "ui-font" would generate `const ui-font_ranges = ...`
        // which is uncompilable. Validation rejects up front with a
        // clean diagnostic naming the bad resource.
        const result = generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "ui-font", .font = "fonts/ui.ttf" },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        try std.testing.expectError(error.InvalidFontResourceName, result);
    }

    test "validation rejects font resource name starting with digit" {
        const result = generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "8bit_font", .font = "fonts/8bit.ttf" },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        try std.testing.expectError(error.InvalidFontResourceName, result);
    }

    test "validation rejects font resource name with dot" {
        const result = generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "display.regular", .font = "fonts/display.ttf" },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        try std.testing.expectError(error.InvalidFontResourceName, result);
    }

    test "atlas + sound resources accept hyphenated names (only fonts need identifier safety)" {
        // Verify the identifier-safety check is scoped to fonts —
        // atlas and sound names only appear inside string literals
        // in the emitted code, so they accept any name. This guard
        // ensures we don't over-restrict.
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "boss-theme", .sound = "audio/boss.ogg" },
                .{ .name = "ui-atlas", .json = "atlases/ui.json", .texture = "atlases/ui.png" },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadSoundFromMemory(\"boss-theme\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "loadAtlasFromMemory(\"ui-atlas\"") != null);
    }
};

pub const GATED_ADAPTER_WIRING = struct {
    test "no audio/font resources → only image adapter wiring emitted (raylib setup path)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "world", .json = "atlases/world.json", .texture = "atlases/world.png" },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "ImageBackendAdapter") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "AudioBackendAdapter") == null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "FontBackendAdapter") == null);
    }

    test "sound resource → audio adapter wiring emitted (raylib setup path)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "boss_theme", .sound = "audio/boss.ogg" },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "AudioBackendAdapter") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.AudioLoader.setBackend(") != null);
        // Font adapter must NOT appear when only sound resources are declared.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "FontBackendAdapter") == null);
    }

    test "font resource → font adapter wiring emitted (raylib setup path)" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "ui_font", .font = "fonts/ui.ttf" },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "FontBackendAdapter") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "engine.FontLoader.setBackend(") != null);
        // Audio adapter must NOT appear when only font resources are declared.
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "AudioBackendAdapter") == null);
    }

    test "mixed resources → both audio and font adapters emitted" {
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .raylib,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "world", .json = "atlases/world.json", .texture = "atlases/world.png" },
                .{ .name = "boss_theme", .sound = "audio/boss.ogg" },
                .{ .name = "ui_font", .font = "fonts/ui.ttf" },
            },
        }, raylib_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "ImageBackendAdapter") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "AudioBackendAdapter") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "FontBackendAdapter") != null);

        // Ordering: image adapter first, then audio, then font, then
        // resource loads. Deterministic emit order keeps codegen
        // reproducible across runs.
        const img_pos = std.mem.indexOf(u8, main_zig, "ImageBackendAdapter") orelse return error.ImageMissing;
        const audio_pos = std.mem.indexOf(u8, main_zig, "AudioBackendAdapter") orelse return error.AudioMissing;
        const font_pos = std.mem.indexOf(u8, main_zig, "FontBackendAdapter") orelse return error.FontMissing;
        const load_pos = std.mem.indexOf(u8, main_zig, "loadAtlasFromMemory(\"world\"") orelse return error.LoadMissing;
        try std.testing.expect(img_pos < audio_pos);
        try std.testing.expect(audio_pos < font_pos);
        try std.testing.expect(font_pos < load_pos);
    }

    test "sokol callback path also gates audio/font adapters" {
        // Sokol/wasm uses buildCallbackInitCode rather than
        // buildSetupCode — the gating must hold there too.
        h.setSokolLifecycle();
        defer h.clearLifecycleOverrides();
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "boss_theme", .sound = "audio/boss.ogg" },
            },
        }, sokol_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "AudioBackendAdapter") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "FontBackendAdapter") == null);
    }

    test "sokol callback path: font-only project gets font adapter, not audio" {
        h.setSokolLifecycle();
        defer h.clearLifecycleOverrides();
        const main_zig = try generate.generateMainZigFromTemplate(std.testing.allocator, engine_template, .{ .y_axis = .up,
            .name = "test-game",
            .backend = .sokol,
            .ecs = .mock,
            .resources = &.{
                .{ .name = "ui_font", .font = "fonts/ui.ttf" },
            },
        }, sokol_lifecycle, empty_entries, empty_names, empty_names, empty_scene_manifests, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_names, empty_plugin_events, empty_plugin_flow_nodes, empty_plugin_pin_styles, empty_plugin_coercions);
        defer std.testing.allocator.free(main_zig);

        try std.testing.expect(std.mem.indexOf(u8, main_zig, "FontBackendAdapter") != null);
        try std.testing.expect(std.mem.indexOf(u8, main_zig, "AudioBackendAdapter") == null);
    }
};

pub const RESOURCE_KINDS = struct {
    test "kind: atlas requires both json and texture" {
        const atlas: generate.ResourceDef = .{
            .name = "ok",
            .json = "atlas.json",
            .texture = "atlas.png",
        };
        try std.testing.expectEqual(generate.ResourceKind.atlas, atlas.kind());
        try std.testing.expectEqual(generate.ResourceValidationError.ok, atlas.validate());
    }

    test "kind: a lone `.image` classifies as image (#675)" {
        const img: generate.ResourceDef = .{
            .name = "portrait",
            .image = "assets/portrait.png",
        };
        try std.testing.expectEqual(generate.ResourceKind.image, img.kind());
        try std.testing.expectEqual(generate.ResourceValidationError.ok, img.validate());
    }

    test "validate: `.image` + `.json` reports multiple_paths, not atlas_incomplete (#675)" {
        // The atlas pair is the MANIFEST form of the same PNG, so an
        // entry carrying both forms is a mix — reporting
        // `atlas_incomplete` here would send the user off to write the
        // `.texture` half they never wanted.
        const mixed: generate.ResourceDef = .{
            .name = "confused",
            .image = "assets/tiles.png",
            .json = "assets/tiles.json",
        };
        try std.testing.expectEqual(generate.ResourceKind.invalid, mixed.kind());
        try std.testing.expectEqual(generate.ResourceValidationError.multiple_paths, mixed.validate());
    }

    test "validate: `.image` + `.texture` reports multiple_paths (#675)" {
        const mixed: generate.ResourceDef = .{
            .name = "confused",
            .image = "assets/tiles.png",
            .texture = "assets/tiles.png",
        };
        try std.testing.expectEqual(generate.ResourceKind.invalid, mixed.kind());
        try std.testing.expectEqual(generate.ResourceValidationError.multiple_paths, mixed.validate());
    }

    test "validate: `.image` + `.sound` reports multiple_paths (#675)" {
        const mixed: generate.ResourceDef = .{
            .name = "confused",
            .image = "assets/portrait.png",
            .sound = "audio/click.wav",
        };
        try std.testing.expectEqual(generate.ResourceKind.invalid, mixed.kind());
        try std.testing.expectEqual(generate.ResourceValidationError.multiple_paths, mixed.validate());
    }

    test "validate: font_params on an image resource reports font_params_misplaced (#675)" {
        const misplaced: generate.ResourceDef = .{
            .name = "typo",
            .image = "assets/portrait.png",
            .font_params = .{ .pixel_height = 24 },
        };
        try std.testing.expectEqual(generate.ResourceKind.image, misplaced.kind());
        try std.testing.expectEqual(generate.ResourceValidationError.font_params_misplaced, misplaced.validate());
    }

    test "kind: sound resource classifies as sound" {
        const sfx: generate.ResourceDef = .{
            .name = "boss_roar",
            .sound = "audio/boss.ogg",
        };
        try std.testing.expectEqual(generate.ResourceKind.sound, sfx.kind());
        try std.testing.expectEqual(generate.ResourceValidationError.ok, sfx.validate());
    }

    test "kind: font resource classifies as font" {
        const font: generate.ResourceDef = .{
            .name = "ui_font",
            .font = "fonts/m5x7.ttf",
            .font_params = .{ .pixel_height = 16 },
        };
        try std.testing.expectEqual(generate.ResourceKind.font, font.kind());
        try std.testing.expectEqual(generate.ResourceValidationError.ok, font.validate());
    }

    test "kind: font with omitted font_params still classifies (defaults kick in at emit)" {
        const font: generate.ResourceDef = .{
            .name = "title_font",
            .font = "fonts/title.ttf",
        };
        try std.testing.expectEqual(generate.ResourceKind.font, font.kind());
        try std.testing.expectEqual(generate.ResourceValidationError.ok, font.validate());
    }

    test "validate: empty resource reports no_path" {
        const empty: generate.ResourceDef = .{ .name = "ghost" };
        try std.testing.expectEqual(generate.ResourceKind.invalid, empty.kind());
        try std.testing.expectEqual(generate.ResourceValidationError.no_path, empty.validate());
    }

    test "validate: atlas with only texture reports atlas_incomplete" {
        const half: generate.ResourceDef = .{
            .name = "broken",
            .texture = "atlas.png",
        };
        try std.testing.expectEqual(generate.ResourceKind.invalid, half.kind());
        try std.testing.expectEqual(generate.ResourceValidationError.atlas_incomplete, half.validate());
    }

    test "validate: atlas with only json reports atlas_incomplete" {
        const half: generate.ResourceDef = .{
            .name = "broken",
            .json = "atlas.json",
        };
        try std.testing.expectEqual(generate.ResourceKind.invalid, half.kind());
        try std.testing.expectEqual(generate.ResourceValidationError.atlas_incomplete, half.validate());
    }

    test "validate: atlas + sound on same entry reports multiple_paths" {
        const tangle: generate.ResourceDef = .{
            .name = "confused",
            .json = "atlas.json",
            .texture = "atlas.png",
            .sound = "audio.wav",
        };
        try std.testing.expectEqual(generate.ResourceKind.invalid, tangle.kind());
        try std.testing.expectEqual(generate.ResourceValidationError.multiple_paths, tangle.validate());
    }

    test "validate: sound + font on same entry reports multiple_paths" {
        const tangle: generate.ResourceDef = .{
            .name = "confused",
            .sound = "audio.wav",
            .font = "font.ttf",
        };
        try std.testing.expectEqual(generate.ResourceKind.invalid, tangle.kind());
        try std.testing.expectEqual(generate.ResourceValidationError.multiple_paths, tangle.validate());
    }

    test "validate: font_params on a sound resource reports font_params_misplaced" {
        // Catches the typo where the user wrote `.sound = "..."` but
        // also pasted `.font_params = .{ ... }` (forgetting that
        // params only belong on font resources). Without this guard
        // the bake params would silently no-op.
        const misplaced: generate.ResourceDef = .{
            .name = "typo",
            .sound = "audio.wav",
            .font_params = .{ .pixel_height = 24 },
        };
        try std.testing.expectEqual(generate.ResourceKind.sound, misplaced.kind());
        try std.testing.expectEqual(generate.ResourceValidationError.font_params_misplaced, misplaced.validate());
    }

    test "FontBakeParams defaults match engine/gfx" {
        // Lock the shape: default 16 px pixel height, ASCII printable
        // range 0x20..0x7F, 512×512 atlas. Drift here would cause the
        // generated adapter to round-trip different defaults than the
        // engine + labelle-gfx ship, which silently changes the
        // baked atlas on projects that omit `font_params`.
        const params: generate.FontBakeParams = .{};
        try std.testing.expectEqual(@as(f32, 16), params.pixel_height);
        try std.testing.expectEqual(@as(u32, 512), params.atlas_width);
        try std.testing.expectEqual(@as(u32, 512), params.atlas_height);
        try std.testing.expectEqual(@as(usize, 1), params.ranges.len);
        try std.testing.expectEqual(@as(u32, 0x20), params.ranges[0].first);
        try std.testing.expectEqual(@as(u32, 0x7F), params.ranges[0].last);
    }
};
