//! Pre-emission validation helpers used by the main.zig generator
//! before any codegen output is produced.
//!
//! Extracted from `src/main_zig.zig` as the third step of the cut plan
//! in `docs/REFACTOR-PLAN-main-zig.md` (labelle-assembler#183). These
//! are pure validation predicates / passes — no template state, no
//! `try w.writeAll(...)` strings, no allocator-lifetime coupling to the
//! orchestrator. `checkBasenameCollisions` allocates one error message
//! that the caller owns; `validateResources` writes diagnostics to
//! stderr; `hasContextEntry` is a plain bool predicate. None of them
//! produce generated code.

const std = @import("std");
const config = @import("../config.zig");
const script_scanner = @import("../script_scanner.zig");
const idents = @import("idents.zig");

const ProjectConfig = config.ProjectConfig;
const ScriptEntry = script_scanner.ScriptScanner.ScriptEntry;
const extWithoutDot = idents.extWithoutDot;
const isValidZigIdentifier = idents.isValidZigIdentifier;

/// Validate that no two prefab paths collapse to the same basename.
/// Returns a heap-allocated error message on collision (caller
/// owns); returns `null` when the set is unambiguous. Quadratic
/// over the prefab list — fine for the expected ~10²-scale prefab
/// counts, no need for a HashSet.
pub fn checkBasenameCollisions(allocator: std.mem.Allocator, prefab_names: []const []const u8) !?[]const u8 {
    for (prefab_names, 0..) |a, i| {
        const a_base = std.fs.path.basename(a);
        for (prefab_names[i + 1 ..]) |b| {
            const b_base = std.fs.path.basename(b);
            if (std.mem.eql(u8, a_base, b_base)) {
                return try std.fmt.allocPrint(allocator, "duplicate prefab basename '{s}' (paths: '{s}', '{s}') — every prefab must have a unique filename across subfolders", .{ a_base, a, b });
            }
        }
    }
    return null;
}

/// True iff the GAME ROOT itself ships a `scripts/context.zig` — the sentinel
/// that makes the generated main import `GameContext` from
/// `scripts/context.zig`. Pack/plugin-shipped `context` scripts
/// (`plugin_name != null`) are EXCLUDED: they are ordinary lifecycle scripts
/// imported through `AllScripts`, not the game context. A pack's
/// `scripts/context.zig` must NOT flip this on, or the template would emit a
/// hard-coded `@import("scripts/context.zig")` for a game that has none —
/// breaking the build (labelle-assembler#496, codex review).
pub fn hasContextEntry(entries: []const ScriptEntry) bool {
    for (entries) |entry| {
        if (entry.plugin_name != null) continue;
        if (std.mem.eql(u8, entry.name, "context")) return true;
    }
    return false;
}

/// Pre-emission validation pass over `cfg.resources`. Surfaces every
/// malformed entry as a stderr diagnostic and returns `error.InvalidResource`
/// after the first one — the user sees the offending resource name and
/// what's wrong before any codegen happens. The CLI maps the structured
/// errors from `ResourceDef.validate()` to actionable hints.
///
/// Two passes: per-entry shape/extension checks first, then a
/// whole-list `checkDuplicateResourceNames` sweep for name collisions
/// (`error.DuplicateResourceName`).
pub fn validateResources(cfg: ProjectConfig) !void {
    const io = config.globalIo();
    for (cfg.resources) |res| {
        switch (res.validate()) {
            .ok => {},
            .no_path => {
                std.Io.File.stderr().writeStreamingAll(io, "labelle-assembler: resource '") catch {};
                std.Io.File.stderr().writeStreamingAll(io, res.name) catch {};
                std.Io.File.stderr().writeStreamingAll(io, "' declares no asset path. Set one of `.json`+`.texture` (atlas), `.image` (a loose image: .png/.jpg/.jpeg/.bmp/.tga, or a pre-converted .astc/.rgba), `.sound` (.wav/.ogg), or `.font` (.ttf/.otf).\n") catch {};
                return error.InvalidResource;
            },
            .multiple_paths => {
                std.Io.File.stderr().writeStreamingAll(io, "labelle-assembler: resource '") catch {};
                std.Io.File.stderr().writeStreamingAll(io, res.name) catch {};
                std.Io.File.stderr().writeStreamingAll(io, "' sets more than one asset path. A resource is exactly one of atlas (`.json`+`.texture`) / image (`.image`) / sound (`.sound`) / font (`.font`). `.image` is the LOOSE-IMAGE form (one .png/.jpg/.jpeg/.bmp/.tga/.astc/.rgba file, no manifest) — drop `.json`/`.texture` to keep it, or drop `.image` to keep the atlas.\n") catch {};
                return error.InvalidResource;
            },
            .atlas_incomplete => {
                std.Io.File.stderr().writeStreamingAll(io, "labelle-assembler: atlas resource '") catch {};
                std.Io.File.stderr().writeStreamingAll(io, res.name) catch {};
                std.Io.File.stderr().writeStreamingAll(io, "' is missing either `.json` or `.texture`. Both are required.\n") catch {};
                return error.InvalidResource;
            },
            .font_params_misplaced => {
                std.Io.File.stderr().writeStreamingAll(io, "labelle-assembler: resource '") catch {};
                std.Io.File.stderr().writeStreamingAll(io, res.name) catch {};
                std.Io.File.stderr().writeStreamingAll(io, "' sets `.font_params` but is not a font resource. Remove `.font_params` or change to `.font = \"...\"`.\n") catch {};
                return error.InvalidResource;
            },
        }
        // Extension sanity for a loose image (#675). Mirrors the
        // sound/font checks: the emitted `file_type` is derived from
        // this extension and handed to the backend's `decodeImage`, so
        // a wrong extension would otherwise only surface as a runtime
        // `error.LoadFailed` with no hint at which resource caused it.
        // The accepted set is what the bundled backends' `decodeImage`
        // handles (stb_image / raylib rasters) plus the toolkit's two
        // pre-converted containers — `.astc` (labelle astc) and `.rgba`
        // (labelle build --bake) — so a hand-pointed compressed blob
        // isn't rejected.
        if (res.kind() == .image) {
            const ext = extWithoutDot(res.image);
            const accepted = [_][]const u8{ "png", "jpg", "jpeg", "bmp", "tga", "astc", "rgba" };
            var ok = false;
            for (accepted) |a| {
                if (std.ascii.eqlIgnoreCase(ext, a)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) {
                std.Io.File.stderr().writeStreamingAll(io, "labelle-assembler: image resource '") catch {};
                std.Io.File.stderr().writeStreamingAll(io, res.name) catch {};
                std.Io.File.stderr().writeStreamingAll(io, "' has unsupported extension. Expected `.png` (or .jpg/.jpeg/.bmp/.tga, or a pre-converted .astc/.rgba). For a TexturePacker sprite sheet use `.json` + `.texture` instead.\n") catch {};
                return error.UnsupportedResourceExtension;
            }
        }
        // Extension sanity for sound/font — surfaces obviously-wrong
        // extensions (e.g. `.font = "x.png"`) at codegen time instead
        // of letting the generated `@embedFile` swallow it silently
        // alongside an empty file_type string.
        if (res.kind() == .sound) {
            const ext = extWithoutDot(res.sound);
            if (!std.ascii.eqlIgnoreCase(ext, "wav") and !std.ascii.eqlIgnoreCase(ext, "ogg")) {
                std.Io.File.stderr().writeStreamingAll(io, "labelle-assembler: sound resource '") catch {};
                std.Io.File.stderr().writeStreamingAll(io, res.name) catch {};
                std.Io.File.stderr().writeStreamingAll(io, "' has unsupported extension. Expected `.wav` or `.ogg`.\n") catch {};
                return error.UnsupportedResourceExtension;
            }
        }
        if (res.kind() == .font) {
            const ext = extWithoutDot(res.font);
            if (!std.ascii.eqlIgnoreCase(ext, "ttf") and !std.ascii.eqlIgnoreCase(ext, "otf")) {
                std.Io.File.stderr().writeStreamingAll(io, "labelle-assembler: font resource '") catch {};
                std.Io.File.stderr().writeStreamingAll(io, res.name) catch {};
                std.Io.File.stderr().writeStreamingAll(io, "' has unsupported extension. Expected `.ttf` or `.otf`.\n") catch {};
                return error.UnsupportedResourceExtension;
            }
            // Font emission interpolates `res.name` into Zig
            // identifier positions (`{name}_ranges`, `{name}_params`).
            // A hyphenated name like "ui-font" would otherwise produce
            // uncompilable `const ui-font_ranges = ...`. Atlas + sound
            // emissions don't have this constraint — those names only
            // appear in string literals.
            if (!isValidZigIdentifier(res.name)) {
                std.Io.File.stderr().writeStreamingAll(io, "labelle-assembler: font resource '") catch {};
                std.Io.File.stderr().writeStreamingAll(io, res.name) catch {};
                std.Io.File.stderr().writeStreamingAll(io, "' has a name that is not a valid Zig identifier. Font resource names must start with [A-Za-z_] and contain only [A-Za-z0-9_] thereafter (the codegen uses the name as a local const identifier for the bake params).\n") catch {};
                return error.InvalidFontResourceName;
            }
        }
    }
    try checkDuplicateResourceNames(cfg);
}

/// Reject two resources declaring the same `name`.
///
/// The name is the ASSET-CATALOG KEY: it is what every generated
/// `load*FromMemory` / `register*FromMemory` call registers under and
/// what `assets.acquire(name)` — and the engine's `Image` component —
/// looks the asset back up by. A collision therefore has no benign
/// reading. Worse, it fails SILENTLY: the catalog keeps whichever
/// entry registered first and every registration-side shim (engine
/// `register*FromMemory`, and the `.image` arm's emitted `catch`)
/// swallows `AssetAlreadyRegistered` to stay idempotent, so the
/// second resource's bytes are simply dropped and every reference to
/// that name resolves to the FIRST asset. The user sees the wrong
/// sprite, with nothing in the build or the logs pointing at why
/// (coderabbit review of #676).
///
/// Caught here, before emission, in the same stderr-diagnostic style
/// as the rest of this module — the message names the offending name
/// and both declared paths so the two colliding entries are findable
/// without bisecting `project.labelle`.
///
/// `cfg.resources` is the MERGED list by the time codegen runs
/// (`root.zig` assigns `mergePackResources`' output before calling
/// the template), so this covers a game resource colliding with
/// another game resource AND with a pack's namespaced
/// `<pack>__<name>` entry.
///
/// Quadratic, like `checkBasenameCollisions` — resource lists are
/// ~10² entries, nowhere near justifying a HashSet.
fn checkDuplicateResourceNames(cfg: ProjectConfig) !void {
    const io = config.globalIo();
    for (cfg.resources, 0..) |a, i| {
        for (cfg.resources[i + 1 ..]) |b| {
            if (!std.mem.eql(u8, a.name, b.name)) continue;
            std.Io.File.stderr().writeStreamingAll(io, "labelle-assembler: duplicate resource name '") catch {};
            std.Io.File.stderr().writeStreamingAll(io, a.name) catch {};
            std.Io.File.stderr().writeStreamingAll(io, "' (declared by '") catch {};
            std.Io.File.stderr().writeStreamingAll(io, declaredPath(a)) catch {};
            std.Io.File.stderr().writeStreamingAll(io, "' and '") catch {};
            std.Io.File.stderr().writeStreamingAll(io, declaredPath(b)) catch {};
            std.Io.File.stderr().writeStreamingAll(io, "'). A resource name is the asset-catalog key the generated loader registers and `acquire` looks up, so only the first entry would ever load — every reference to the name would silently resolve to it. Rename one entry or drop the duplicate. (Pack-shipped resources are namespaced `<pack>__<name>`; a game resource spelled that way collides with them.)\n") catch {};
            return error.DuplicateResourceName;
        }
    }
}

/// The asset path to quote for `res` in a diagnostic — the atlas
/// manifest for an atlas pair, otherwise the single populated path.
/// `.invalid` entries never reach here (the per-entry pass in
/// `validateResources` bails on them first), but map to a readable
/// placeholder rather than an empty string in case a future caller
/// reorders the passes.
fn declaredPath(res: config.ResourceDef) []const u8 {
    return switch (res.kind()) {
        .atlas => if (res.json.len > 0) res.json else res.texture,
        .image => res.image,
        .sound => res.sound,
        .font => res.font,
        .invalid => "<no asset path>",
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "hasContextEntry: a game-root context script is the game context" {
    const entries = [_]ScriptEntry{
        .{
            .name = "context",
            .filename = "context.zig",
            .states = &.{},
            .sort_order = null,
            .subdir = null,
            .rel_path = "context.zig",
        },
    };
    try testing.expect(hasContextEntry(&entries));
}

test "hasContextEntry: a pack's context script is NOT the game context (#496)" {
    // A pack ships `scripts/context.zig`; the scanner stamps it with a
    // `plugin_name`. It must not be treated as the game's GameContext sentinel
    // (which would emit a hard-coded `@import("scripts/context.zig")` for a
    // game root that has no such file) — codex review of #496.
    const entries = [_]ScriptEntry{
        .{
            .name = "context",
            .filename = "context.zig",
            .states = &.{},
            .sort_order = null,
            .subdir = null,
            .rel_path = "packs/media/scripts/context.zig",
            .plugin_name = "media",
            .plugin_index = 1,
            .import_base = "",
        },
    };
    try testing.expect(!hasContextEntry(&entries));
}
